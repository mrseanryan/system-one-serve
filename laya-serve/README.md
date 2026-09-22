# laya-serve

REST API wrapper for [laya](https://github.com/NandhaKishorM/laya) — a fast, non-autoregressive System 1 decision engine. Exposes `choice`, `score`, and `noul` typed decisions over HTTP using FastAPI.

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| Windows 11 (64-bit) | |
| Python 3.10 – 3.13 | 3.12 recommended |
| ~4 GB RAM (CPU) / ~2 GB VRAM (GPU) | `laya` (English) is 421M params; `laya-multilingual` is 322M |
| Hugging Face internet access | Models are downloaded automatically on first use |

> **GPU optional.** The server runs fine on CPU (~200–500 ms per request instead of ~35 ms on a T4).

---

## Setup on Windows 11

### 1. Clone or copy the repo

```bash
# In Git Bash
git clone <this-repo-url>
cd laya-serve
```

### 2. Create a Python virtual environment

```bash
python -m venv .venv
source .venv/Scripts/activate   # Git Bash
```

> If you use PowerShell instead:
> ```powershell
> .venv\Scripts\Activate.ps1
> ```

### 3. Install dependencies

```bash
pip install -r requirements.txt
```

> **CUDA (optional):** If you have an NVIDIA GPU, replace the `torch` line with a CUDA-enabled
> build before installing:
> ```bash
> pip install torch --index-url https://download.pytorch.org/whl/cu121
> pip install -r requirements.txt
> ```
> The server detects CUDA automatically; no config change needed.

### 4. (Optional) Set a Hugging Face token

The `convaiinnovations/laya` model is public, so no token is required. If you work behind a
proxy that blocks anonymous HF downloads, create a token at <https://huggingface.co/settings/tokens>
and export it:

```bash
export HF_TOKEN=hf_...
```

### 5. Start the server

```bash
python server.py
```

The first run downloads the `laya` checkpoint (~1.7 GB). Subsequent starts use the local cache.

Expected output:

```
[laya-serve] Starting on http://0.0.0.0:8000
[laya-serve] Docs: http://0.0.0.0:8000/docs
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

Open <http://localhost:8000/docs> for the interactive Swagger UI.

---

## Configuration (environment variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `LAYA_HOST` | `0.0.0.0` | Bind address |
| `LAYA_PORT` | `8000` | TCP port |
| `LAYA_DEVICE` | `auto` | Force device: `cpu`, `cuda`, `mps` |
| `LAYA_PRELOAD` | *(empty)* | Comma-separated model aliases to warm up at startup, e.g. `english,multilingual` |
| `LAYA_RELOAD` | `false` | Enable uvicorn hot-reload (development only) |
| `HF_TOKEN` | *(empty)* | Hugging Face API token (public models do not require this) |

Example — preload the English model at startup and pin to CPU:

```bash
LAYA_PRELOAD=english LAYA_DEVICE=cpu python server.py
```

---

## API reference

### `GET /health`

Liveness probe. Always returns `200 OK` while the server is running.

```json
{
  "status": "ok",
  "loaded_models": ["english"],
  "device": "cpu"
}
```

### `GET /models`

Lists available and currently loaded checkpoint aliases.

```json
{
  "available": ["english", "multilingual", "typed-decisions"],
  "loaded": ["english"]
}
```

### `POST /predict`

Run typed questions against a state using a specific checkpoint.

**Request body**

```json
{
  "state": "<text or JSON object>",
  "questions": {
    "<question_id>": {
      "type": "choice | score | noul",
      "instructions": "Natural-language question",
      "criteria": "<see table below>"
    }
  },
  "model": "english"
}
```

| Question type | `criteria` field | Output field |
|---------------|-----------------|--------------|
| `choice` | `{"label": "description", …}` | `choice`, `probabilities` |
| `score` | `["level 0", "level 1", …]` (ordered) | `score` (expected level index), `probabilities` |
| `noul` | omit | `noul` (P(true) 0.0–1.0) |

**Response**

```json
{
  "model": "laya-rl-agent",
  "model_alias": "english",
  "answers": {
    "<question_id>": {
      "type": "choice",
      "choice": "billing",
      "probabilities": {"billing": 0.94, "technical": 0.04, "other": 0.02},
      "confidence": 0.94,
      "action": {"act_probability": 0.91}
    }
  },
  "usage": {"input_tokens": 128, "output_tokens": 0},
  "latency_ms": 312.5
}
```

### `POST /predict/route`

Same as `/predict` but uses the built-in `Router` for automatic language detection. The `model`
field in the request is ignored. A `routing` field is added to the response describing which
checkpoint was chosen and why.

---

## Available models

| Alias | HF checkpoint | Context | Best for |
|-------|--------------|---------|----------|
| `english` | `convaiinnovations/laya` | 512 | English text |
| `multilingual` | `convaiinnovations/laya` (subfolder `multilingual`) | 1024 | 100+ languages, 2× faster |
| `typed-decisions` | `convaiinnovations/laya` (subfolder `typed-decisions`) | 1024 | Fine-tuned typed-decisions workflows |

---

## Test scripts

See the `tests/` directory for Git Bash test scripts covering all three question types.

```bash
# Run all tests (server must already be running)
bash tests/test_all.sh

# Or run individual suites
bash tests/test_noul.sh
bash tests/test_choice.sh
bash tests/test_score.sh
```

---

## Troubleshooting

**`ModuleNotFoundError: No module named 'laya'`**  
The virtual environment is not activated. Run `source .venv/Scripts/activate` (Git Bash) or
`.venv\Scripts\Activate.ps1` (PowerShell).

**Model download hangs / times out**  
Check your firewall or proxy settings. You may need to set `HF_TOKEN` and/or configure
`HF_ENDPOINT` to a mirror.

**`RuntimeError: CUDA error: no kernel image is available`**  
Your GPU's CUDA compute capability is not supported by the installed PyTorch build.  
Install a nightly build:
```bash
pip install --pre torch --index-url https://download.pytorch.org/whl/nightly/cu128
```

**Server is slow (~300–500 ms per request)**  
The model is running on CPU. This is expected without a GPU. Response times of 200–500 ms are
normal on CPU; latency drops to ~35 ms on a T4 GPU.

**Port 8000 already in use**  
```bash
LAYA_PORT=8001 python server.py
```
