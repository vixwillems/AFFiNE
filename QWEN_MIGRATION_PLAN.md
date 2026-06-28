# Qwen AI Migration Plan

> Self-host AFFiNe with Qwen2.5-VL-7B (quantized INT4 ~4.5GB) via LiteLLM proxy
> on a separate VM (192.168.0.253, RTX 3050 8GB, Ryzen 5 3600).
> Embeddings via nomic-embed-text (Ollama).
> Image generation (FAL) and transcribing (Gemini) stay as-is.

---

## Architecture

```
AFFiNe Server (Docker)
  │
  │  GraphQL / copilot plugin
  │
  ├── Chat / Text / Actions ──→ LiteLLM (proxy on VM, port 1234)
  │                              │
  │                              ├── ollama/qwen2.5:7b-instruct-q4_K_M
  │                              ├── ollama/nomic-embed-text
  │                              └── model name translations
  │
  ├── Embedding (nomic-embed-text)
  │     └──→ modified routing: goes through OpenAI provider → LiteLLM
  │
  ├── Reranking
  │     └──→ gpt-4o-mini name preserved → LiteLLM routes to Qwen
  │
  ├── Image Generation (unaltered)
  │     └──→ FAL provider (fal.ai)
  │
  └── Transcribing (unaltered)
        └──→ Gemini provider
```

### Model Name Mapping (LiteLLM config)

```yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
  - model_name: gpt-4o-mini
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
  - model_name: o3
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
  - model_name: claude-sonnet-4@20250514
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
  - model_name: text-embedding-3-large
    litellm_params:
      model: ollama/nomic-embed-text
      api_base: http://localhost:11434
```

---

## Phases

### Phase 1: Chat/Text Provider — LiteLLM Compatibility

**Changes required: 4 files**

#### 1.1 Enable `oldApiStyle` on default OpenAI config

**File:** `packages/backend/server/src/plugins/copilot/config.ts:248-252`

```diff
  'providers.openai': {
    default: {
      apiKey: '',
      baseURL: 'https://api.openai.com/v1',
+     oldApiStyle: true,
    },
  },
```

**Why:** Without `oldApiStyle: true`, the OpenAI provider resolves to the `openai_responses` backend kind (uses `/v1/responses` API). LiteLLM only supports `/v1/chat/completions` (the `openai_chat` backend kind).

#### 1.2 Add `oldApiStyle` to BYOK OpenAI profile config

**File:** `packages/backend/server/src/plugins/copilot/byok/service.ts:596-610`

```diff
  private providerConfig(
    provider: ByokProvider,
    encryptedApiKey: string,
    endpoint: string | null
  ) {
    const apiKey = this.crypto.decrypt(encryptedApiKey);
    switch (provider) {
      case ByokProvider.openai:
      case ByokProvider.gemini:
      case ByokProvider.anthropic:
-       return { apiKey, ...(endpoint ? { baseURL: endpoint } : {}) };
+       return {
+         apiKey,
+         ...(endpoint ? { baseURL: endpoint } : {}),
+         ...(provider === ByokProvider.openai ? { oldApiStyle: true } : {}),
+       };
```

**Why:** BYOK profiles bypass the server config. Without `oldApiStyle`, BYOK OpenAI profiles use the new `openai_responses` backend kind which doesn't work with LiteLLM.

#### 1.3 Expose `oldApiStyle` in BYOK OpenAPI types (if needed)

If the BYOK config schema (`config.ts` or the GraphQL input types) doesn't allow `oldApiStyle` to be set per-config, it may need adding. However, since we're hardcoding `true` for all BYOK OpenAI profiles in 1.2, this is unnecessary.

#### 1.4 Enable custom endpoints by default for selfhosted

**File:** `packages/backend/server/src/plugins/copilot/config.ts:230-234`

The `byok.allowCustomEndpoint` default is `false`. Check if it needs to be `true` when selfhosted. The BYOK service already respects `env.selfhosted` for `customEndpointSupported`, but the config gate `byok.allowCustomEndpoint` might block it.

```diff
  'byok.allowCustomEndpoint': {
    desc: 'Whether workspace BYOK custom endpoints are accepted.',
-   default: false,
+   default: true,
    shape: z.boolean(),
  },
```

---

### Phase 1b: Embedding — Route through OpenAI/LiteLLM

**Changes required: 2-3 files**

#### The Problem

`task-policy.ts:16-18` hardcodes `gemini-embedding-001` for embeddings. This goes through the Gemini provider's native Rust dispatch (`llmEmbeddingDispatch` with Gemini auth), not through OpenAI/LiteLLM. Even if LiteLLM could proxy it, the auth and protocol are Gemini-specific.

#### Approach A (Recommended): Change default embedding model to an OpenAI-compatible one

**File:** `packages/backend/server/src/plugins/copilot/runtime/task-policy.ts:6-7`

```diff
- export const DEFAULT_EMBEDDING_MODEL = 'gemini-embedding-001';
+ export const DEFAULT_EMBEDDING_MODEL = 'text-embedding-3-large';

- export const DEFAULT_RERANK_MODEL = 'gpt-4o-mini';
+ export const DEFAULT_RERANK_MODEL = 'gpt-4o-mini'; // unchanged
```

**Why:** `text-embedding-3-large` IS registered in the native Rust model registry for OpenAI. The OpenAI provider can resolve it, build an embedding request, and dispatch it to the OpenAI backend (LiteLLM). LiteLLM then maps `text-embedding-3-large` → `nomic-embed-text` via Ollama.

This change alone may be sufficient because:
1. The embedding client (`embedding/client.ts:48`) calls `this.runtime.embed(modelId, input, options)` 
2. The `CapabilityRuntime` resolves the provider for the embedding model via `CopilotProviderFactory.prepareEmbeddingRoutes()`
3. The OpenAI provider handles embedding for models it knows about

#### Approach B (Fallback): If embedding dispatch still goes through Gemini provider

If the native `llmResolveModelRegistryVariant` returns `text-embedding-3-large` but routes it through the Gemini backend (unlikely since it's an OpenAI model in the registry), we may need to:

**File:** `packages/backend/server/src/plugins/copilot/embedding/client.ts`

Modify `resolveEmbeddingModelId()` resolution to prefer the OpenAI provider when selfhosted, or add a middleware that rewrites the model name.

#### 1b.2 Rerank: Ensure clean routing

The rerank default `gpt-4o-mini` is already an OpenAI model. The OpenAI provider supports reranking via its driver spec. LiteLLM maps it to Qwen. **No changes needed** unless testing reveals issues.

---

### Phase 2: Exclude Image Gen and Transcribing from Qwen Migration

**No code changes required.** These features use separate providers:

- **Image generation**: Uses the `FAL` provider type (`CopilotProviderType.FAL`). Only activates if `FAL_API_KEY` is configured. Just don't configure it, or keep it pointing to fal.ai.
- **Transcribing**: Uses the `Gemini` provider type (`CopilotProviderType.Gemini`). Only activates if `GEMINI_API_KEY` is configured. Just don't configure it, or keep it pointing to Google.

In the BYOK admin UI, users add keys per provider type. Only OpenAI BYOK key is needed for Qwen.

---

### Phase 3: Docker Build & Deployment

#### 3.1 Building fork Docker images

The selfhost `compose.yml` (`.docker/selfhost/compose.yml`) references:
```yaml
image: ghcr.io/toeverything/affine:${AFFINE_REVISION:-stable}
```

For the fork, build custom images:
```bash
# Build the server image from fork
docker build -t vixwillems/affine:canary -f .docker/selfhost/Dockerfile .
```

Or use `yarn affine @affine/server build` and package manually.

#### 3.2 Required env vars for deployment

```bash
# Deployment mode (critical!)
DEPLOYMENT_TYPE=selfhosted

# Copilot configuration
COPILOT_ENABLED=true
COPILOT_OPENAI_API_KEY=sk-liteLM-proxy-key   # any non-empty value
COPILOT_OPENAI_BASE_URL=http://192.168.0.253:1234/v1

# BYOK settings
COPILOT_BYOK_ALLOW_CUSTOM_ENDPOINT=true

# Optional: disable other providers
# COPILOT_GEMINI_API_KEY=       # leave empty to disable
# COPILOT_FAL_API_KEY=          # leave empty to disable
```

#### 3.3 LiteLLM config on VM (192.168.0.253)

```yaml
# ~/.litellm/config.yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
      max_tokens: 8192
  - model_name: gpt-4o-mini
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
      max_tokens: 8192
  - model_name: o3
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
      max_tokens: 8192
  - model_name: claude-sonnet-4@20250514
    litellm_params:
      model: ollama/qwen2.5:7b-instruct-q4_K_M
      api_base: http://localhost:11434
      max_tokens: 8192
  - model_name: text-embedding-3-large
    litellm_params:
      model: ollama/nomic-embed-text
      api_base: http://localhost:11434

litellm_settings:
  drop_params: true
  set_verbose: true

general_settings:
  master_key: sk-liteLM-proxy-key
```

Run LiteLLM:
```bash
docker run -d --name litellm \
  -p 1234:4000 \
  -v ~/.litellm/config.yaml:/app/config.yaml \
  ghcr.io/berriai/litellm:main \
  --config /app/config.yaml --port 4000
```

#### 3.4 Ollama on VM

```bash
# Pull models
ollama pull qwen2.5:7b-instruct-q4_K_M
ollama pull nomic-embed-text

# Serve
ollama serve
```

---

## Testing Checklist

| Feature | Expected Behavior | Test Method |
|---------|------------------|-------------|
| Chat (text) | Responds from Qwen | Use AFFiNe chat UI |
| AI Actions | Qwen executes actions | Try /ai actions |
| Embedding | nomic-embed-text generates vectors | Workspace indexing works |
| Rerank | Qwen-based similarity scoring | Search relevance |
| Image Gen | Uses FAL (unchanged) | /ai image generation |
| Audio Transcript | Uses Gemini (unchanged) | Audio upload & transcribe |
| BYOK UI | Add OpenAI key with custom endpoint | Workspace settings → AI |

---

## Git Workflow

```bash
# Branch naming convention
qwen/phase-1-chat-provider    # oldApiStyle + BYOK changes
qwen/phase-1b-embedding       # embedding model change
qwen/phase-3-docker           # Docker build tweaks if needed

# Commit style: conventional commits
feat(server): add oldApiStyle to BYOK OpenAI provider profiles
feat(server): set oldApiStyle default for OpenAI provider
feat(server): switch default embedding model for selfhosted

# Each phase → one PR into vixwillems/affine:canary
```

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Native Rust model registry rejects model | Chat/embedding fails | Use registry-registered names + LiteLLM mapping |
| `oldApiStyle` not passed to native dispatch | Uses wrong API path | Verified in `openai.ts:44-48` — `resolveModelBackendKind` reads from config |
| Embedding still routes through Gemini | Embedding broken | Change `task-policy.ts` default; if that's insufficient, modify `CapabilityRuntime` |
| LiteLLM model name translation fails | Requests fail | `drop_params: true` in LiteLLM config handles unknown params |
| VRAM insufficient for Qwen2.5-VL-7B | OOM/crash | Using INT4 quantized model (~4.5GB); RTX 3050 has 8GB — margin of ~3.5GB |
