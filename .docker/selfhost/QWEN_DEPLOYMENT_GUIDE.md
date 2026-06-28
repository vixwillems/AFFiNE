# Qwen AI — Selfhost Deployment Guide

> Deploy AFFiNE fork with Qwen2.5-VL-7B via LiteLLM + Ollama.

## Architecture

```
AFFiNE Server (Docker)              VM 192.168.0.253 (RTX 3050)
  │                                       │
  ├── Chat / Actions ──→ LiteLLM (:1234) ─┤
  ├── Embedding        ──→ LiteLLM (:1234) ─┤
  ├── Rerank           ──→ LiteLLM (:1234) ─┤
  │                                       ├── Ollama (qwen2.5:7b-instruct-q4_K_M)
  │                                       ├── Ollama (nomic-embed-text)
  ├── Image Gen        ──→ FAL (unchanged) │
  └── Transcribing     ──→ Gemini (unchanged)
```

## Required Code Changes (already in fork)

| PR | Branch | Files Changed | Purpose |
|----|--------|--------------|---------|
| [#1](https://github.com/vixwillems/AFFiNE/pull/1) | `qwen/phase-1-chat-provider` | `config.ts`, `byok/service.ts` | `oldApiStyle: true`, custom endpoint support |
| [#2](https://github.com/vixwillems/AFFiNE/pull/2) | `qwen/phase-1b-embedding` | `task-policy.ts`, `copilot.ts` | OpenAI embedding model, 768-dim vectors |

## Quick Start

### 1. LiteLLM + Ollama on VM

```bash
# On 192.168.0.253

# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull models
ollama pull qwen2.5:7b-instruct-q4_K_M
ollama pull nomic-embed-text

# Ensure Ollama listens on all interfaces for LiteLLM
# sudo systemctl edit ollama
# [Service]
# Environment="OLLAMA_HOST=0.0.0.0"

# Start Ollama (if not already running)
ollama serve
```

### 2. LiteLLM Proxy

```bash
# On 192.168.0.253

# LiteLLM config at ~/.litellm/config.yaml
cat > ~/.litellm/config.yaml << 'EOF'
model_list:
  - model_name: gpt-4o
    litellm_params: { model: ollama/qwen2.5:7b-instruct-q4_K_M, api_base: http://localhost:11434, max_tokens: 8192 }
  - model_name: gpt-4o-mini
    litellm_params: { model: ollama/qwen2.5:7b-instruct-q4_K_M, api_base: http://localhost:11434, max_tokens: 8192 }
  - model_name: o3
    litellm_params: { model: ollama/qwen2.5:7b-instruct-q4_K_M, api_base: http://localhost:11434, max_tokens: 8192 }
  - model_name: claude-sonnet-4@20250514
    litellm_params: { model: ollama/qwen2.5:7b-instruct-q4_K_M, api_base: http://localhost:11434, max_tokens: 8192 }
  - model_name: text-embedding-3-large
    litellm_params: { model: ollama/nomic-embed-text, api_base: http://localhost:11434 }

litellm_settings:
  drop_params: true
  set_verbose: true

general_settings:
  master_key: sk-liteLLM-proxy-key
EOF

# Run LiteLLM
docker run -d --name litellm --restart unless-stopped \
  -p 1234:4000 \
  -v ~/.litellm/config.yaml:/app/config.yaml \
  ghcr.io/berriai/litellm:main \
  --config /app/config.yaml --port 4000
```

### 3. Build AFFiNE Fork Image

```bash
# On your build machine (clone of vixwillems/AFFiNE with all changes merged)

IMAGE_TAG=vixwillems/affine:canary bash .docker/selfhost/build-fork.sh
# For multi-arch: PLATFORMS=linux/amd64,linux/arm64 IMAGE_TAG=... bash .docker/selfhost/build-fork.sh

# Push to registry (optional, for deployment)
docker push vixwillems/affine:canary
```

### 4. Deploy with Docker Compose

```bash
# On the server running AFFiNE

cd .docker/selfhost

# Copy env template and edit
cp env.qwen.example .env
# Edit .env with your settings (DB passwords, etc.)

# Deploy with Qwen override
docker compose -f compose.yml -f compose.qwen-override.yml up -d
```

## Env Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DEPLOYMENT_TYPE` | yes | — | Must be `selfhosted` for BYOK features |
| `COPILOT_OPENAI_API_KEY` | yes | — | LiteLLM master key (any non-empty value) |
| `COPILOT_OPENAI_BASE_URL` | yes | — | `http://192.168.0.253:1234/v1` |
| `COPILOT_BYOK_ALLOW_CUSTOM_ENDPOINT` | no | `true` | Allow custom endpoints in BYOK UI |
| `AFFINE_REVISION` | no | `stable` | Set to `canary` for fork builds |

## Architecture Notes

### Why model names stay as stock names

AFFiNE's native Rust model registry (`llm_adapter` crate) only knows about stock models
(gpt-4o, gpt-4o-mini, text-embedding-3-large, etc.). Rather than forking the Rust crate,
we keep these names and let LiteLLM translate them to Qwen models. This requires zero
changes to the native model validation layer.

### Why oldApiStyle is required

LiteLLM and Ollama only support the standard OpenAI `/v1/chat/completions` endpoint.
AFFiNE's newer `openai_responses` backend uses `/v1/responses`, which is OpenAI-specific.
Setting `oldApiStyle: true` forces the `openai_chat` backend protocol.

### Embedding dimension change

`nomic-embed-text` outputs 768-dimensional vectors, while AFFiNE's default
`EMBEDDING_DIMENSIONS` was 1024. The constant was changed to 768 to match,
preventing dimension mismatch errors in vector storage and retrieval.
