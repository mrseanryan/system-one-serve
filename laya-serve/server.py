"""
laya-serve: FastAPI REST wrapper for the laya System 1 decision engine.

Endpoints
---------
GET  /health              liveness probe
GET  /models              list available checkpoints
POST /predict             predict with explicit model or default (english)
POST /predict/route       predict with automatic language routing (Router)
"""
from __future__ import annotations

import os
import time
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional, Union

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class QuestionDef(BaseModel):
    type: str = Field(..., description="One of: 'choice', 'score', 'noul'")
    instructions: str = Field(..., description="Natural-language question to ask about the state")
    criteria: Optional[Union[Dict[str, Optional[str]], List[str]]] = Field(
        None,
        description=(
            "choice: dict of {label: description}  |  "
            "score: ordered list of level labels  |  "
            "noul: omit entirely"
        ),
    )


class PredictRequest(BaseModel):
    state: Union[str, Dict[str, Any], List[Any]] = Field(
        ..., description="Text, JSON object, or conversation list to evaluate"
    )
    questions: Dict[str, QuestionDef] = Field(
        ..., description="Map of question_id -> question definition"
    )
    model: Optional[str] = Field(
        None,
        description=(
            "Checkpoint to use: 'english' | 'multilingual' | 'typed-decisions'. "
            "Defaults to 'english'. Ignored by /predict/route."
        ),
    )


class HealthResponse(BaseModel):
    status: str
    loaded_models: List[str]
    device: str


class ModelsResponse(BaseModel):
    available: List[str]
    loaded: List[str]


# ---------------------------------------------------------------------------
# Global state – models are loaded lazily on first use to keep startup fast
# ---------------------------------------------------------------------------

_agents: Dict[str, Any] = {}          # alias -> Agent
_router: Any = None                    # laya.Router (created on demand)
_device: str = "auto"


def _get_device() -> str:
    return os.environ.get("LAYA_DEVICE", "auto") or "auto"


def _load_agent(alias: str) -> Any:
    """Load and cache a laya Agent by alias.  Thread-safe enough for dev use."""
    global _agents
    if alias in _agents:
        return _agents[alias]

    import laya

    ALIAS_MAP = {
        "english": ("convaiinnovations/laya", None),
        "multilingual": ("convaiinnovations/laya", "multilingual"),
        "typed-decisions": ("convaiinnovations/laya", "typed-decisions"),
    }
    if alias not in ALIAS_MAP:
        raise HTTPException(status_code=400, detail=f"Unknown model alias '{alias}'. Choose from {list(ALIAS_MAP)}")

    repo, subfolder = ALIAS_MAP[alias]
    device = _get_device()
    kw: Dict[str, Any] = {}
    if device != "auto":
        kw["device"] = device
    if subfolder:
        kw["subfolder"] = subfolder

    token = os.environ.get("HF_TOKEN")
    if token:
        kw["token"] = token

    try:
        agent = laya.load(repo, **kw)
        _agents[alias] = agent
        return agent
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"Failed to load model '{alias}': {exc}") from exc


def _get_router() -> Any:
    global _router
    if _router is None:
        import laya

        device = _get_device()
        kw: Dict[str, Any] = {}
        if device != "auto":
            kw["device"] = device
        token = os.environ.get("HF_TOKEN")
        if token:
            kw["token"] = token
        # Attach any already-loaded agents to avoid duplicate VRAM usage.
        _router = laya.Router(**kw)
        for alias, agent in _agents.items():
            try:
                _router.attach(alias, agent)
            except Exception:
                pass
    return _router


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Optionally pre-warm a model on startup via env var, e.g. LAYA_PRELOAD=english
    preload = os.environ.get("LAYA_PRELOAD", "").strip()
    if preload:
        for alias in [m.strip() for m in preload.split(",") if m.strip()]:
            print(f"[laya-serve] Pre-loading model '{alias}' …", flush=True)
            try:
                _load_agent(alias)
                print(f"[laya-serve] '{alias}' ready.", flush=True)
            except Exception as exc:
                print(f"[laya-serve] WARNING: could not pre-load '{alias}': {exc}", flush=True)
    yield
    # Cleanup (free memory) on shutdown
    _agents.clear()
    global _router
    _router = None


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="laya-serve",
    description=(
        "REST API wrapper for the laya System 1 decision engine. "
        "Supports typed decision questions: choice, score, noul."
    ),
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health", response_model=HealthResponse, tags=["admin"])
def health():
    """Liveness probe – always returns 200 if the server is running."""
    import torch
    device_str = "cuda" if torch.cuda.is_available() else "cpu"
    return HealthResponse(
        status="ok",
        loaded_models=list(_agents.keys()),
        device=device_str,
    )


@app.get("/models", response_model=ModelsResponse, tags=["admin"])
def models():
    """List available checkpoint aliases and which are currently loaded."""
    return ModelsResponse(
        available=["english", "multilingual", "typed-decisions"],
        loaded=list(_agents.keys()),
    )


@app.post("/predict", tags=["inference"])
def predict(req: PredictRequest):
    """
    Run typed decision questions against a state using a specific model checkpoint.

    - **state**: text string, JSON object, or conversation list
    - **questions**: map of `question_id` -> question definition
    - **model**: `english` (default) | `multilingual` | `typed-decisions`

    ### Question types

    | type | `criteria` | output field |
    |------|-----------|--------------|
    | `choice` | `{"label": "description", …}` | `choice`, `probabilities` |
    | `score` | `["level0", "level1", …]` | `score` (expected level), `probabilities` |
    | `noul` | *(omit)* | `noul` (P(true) 0–1) |
    """
    alias = (req.model or "english").lower()
    agent = _load_agent(alias)

    # Convert Pydantic models to plain dicts for the laya SDK
    questions_dict: Dict[str, Any] = {}
    for qid, qdef in req.questions.items():
        q: Dict[str, Any] = {"type": qdef.type, "instructions": qdef.instructions}
        if qdef.criteria is not None:
            q["criteria"] = qdef.criteria
        questions_dict[qid] = q

    t0 = time.perf_counter()
    try:
        result = agent.predict(req.state, questions_dict)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)

    result["latency_ms"] = elapsed_ms
    result["model_alias"] = alias
    return result


@app.post("/predict/route", tags=["inference"])
def predict_route(req: PredictRequest):
    """
    Run typed decision questions with **automatic language routing**.

    The built-in `Router` detects the script/language in <1 ms and dispatches
    to the appropriate checkpoint (english or multilingual) automatically.
    The `model` field in the request body is ignored; routing is always automatic.

    Returns the same shape as `/predict` plus a `routing` metadata field.
    """
    router = _get_router()

    questions_dict: Dict[str, Any] = {}
    for qid, qdef in req.questions.items():
        q: Dict[str, Any] = {"type": qdef.type, "instructions": qdef.instructions}
        if qdef.criteria is not None:
            q["criteria"] = qdef.criteria
        questions_dict[qid] = q

    t0 = time.perf_counter()
    try:
        result = router.predict(req.state, questions_dict)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)

    result["latency_ms"] = elapsed_ms
    return result


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    host = os.environ.get("LAYA_HOST", "0.0.0.0")
    port = int(os.environ.get("LAYA_PORT", "8000"))
    reload = os.environ.get("LAYA_RELOAD", "false").lower() == "true"

    print(f"[laya-serve] Starting on http://{host}:{port}", flush=True)
    print(f"[laya-serve] Docs: http://{host}:{port}/docs", flush=True)

    uvicorn.run(
        "server:app",
        host=host,
        port=port,
        reload=reload,
        log_level="info",
    )
