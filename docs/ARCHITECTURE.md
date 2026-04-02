# Architecture

## Overview

This project deploys **LiteLLM Proxy** as a Docker-based application on **SAP BTP Cloud Foundry**, acting as a unified OpenAI-compatible AI gateway backed by **SAP AI Core**'s Generative AI Hub.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        SAP BTP Cloud Foundry Space                     │
│                                                                        │
│   ┌──────────────────────────────────────────────────────────────┐    │
│   │              LiteLLM Proxy (Docker App)                      │    │
│   │              litellm-sap-btp.cfapps.*.hana.ondemand.com      │    │
│   │                                                              │    │
│   │  ┌─────────────────┐   ┌──────────────────────────────────┐ │    │
│   │  │  OpenAI-compat  │   │       litellm_config.yaml        │ │    │
│   │  │  REST API        │   │  model_list:                     │ │    │
│   │  │  :8080/v1/       │   │    - gpt-4o → deployment/d123   │ │    │
│   │  │  chat/completions│   │    - claude-3-5-sonnet → d456   │ │    │
│   │  │  embeddings      │   │    - gemini-1-5-pro → d789      │ │    │
│   │  │  models          │   │    - mistral-large → d012       │ │    │
│   │  └────────┬─────────┘   └──────────────────────────────────┘ │    │
│   │           │                                                    │    │
│   │           │  Route + Auth Token injection                      │    │
│   │           │                                                    │    │
│   │  ┌────────▼──────────────────────────────────────────────┐   │    │
│   │  │            LiteLLM Router / Load Balancer              │   │    │
│   │  │  - Model alias → AI Core deployment URL mapping        │   │    │
│   │  │  - Retry logic (3 retries, fallback chains)            │   │    │
│   │  │  - Rate limiting per virtual key                       │   │    │
│   │  │  - Request/response logging                            │   │    │
│   │  └────────┬──────────────────────────────────────────────┘   │    │
│   └───────────┼────────────────────────────────────────────────────┘   │
│               │ HTTPS + Bearer {oauth2_token}                           │
│               │ AI-Resource-Group: {resource_group}                     │
└───────────────┼────────────────────────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────────────────────┐
│                         SAP AI Core                                    │
│                                                                        │
│   ┌─────────────────────────────────────────────────────────────────┐ │
│   │  Generative AI Hub Inference API                                │ │
│   │  {AI_API_URL}/v2/inference/deployments/{deployment_id}/v1/     │ │
│   │                                                                 │ │
│   │  Deployments (each has a unique ID):                            │ │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │ │
│   │  │  GPT-4o      │  │ Claude 3.5   │  │  Gemini 1.5 Pro      │ │ │
│   │  │  (Azure OAI) │  │ Sonnet (AWS) │  │  (Google Vertex)     │ │ │
│   │  └──────────────┘  └──────────────┘  └──────────────────────┘ │ │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │ │
│   │  │  Mistral     │  │ Llama 3.1    │  │  Text Embeddings     │ │ │
│   │  │  Large       │  │ 70B Instruct │  │  Ada 002             │ │ │
│   │  └──────────────┘  └──────────────┘  └──────────────────────┘ │ │
│   └─────────────────────────────────────────────────────────────────┘ │
│                                                                        │
│   ┌─────────────────────────────────────────────────────────────────┐ │
│   │  XSUAA (OAuth2)                                                 │ │
│   │  {url}/oauth/token  ←  client_credentials grant                │ │
│   │  Issues Bearer tokens (JWT, ~1hr expiry)                       │ │
│   └─────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘

              ▲ Clients
              │
┌─────────────┼──────────────────────────────────────┐
│             │  OpenAI SDK / curl / any HTTP client  │
│                                                      │
│  openai.OpenAI(                                      │
│    base_url="https://litellm-sap-btp.cfapps.../v1", │
│    api_key="sk-your-litellm-key"                     │
│  )                                                   │
└──────────────────────────────────────────────────────┘
```

---

## Authentication Flow

### 1. Client → LiteLLM Proxy

Clients authenticate with a **LiteLLM virtual key** (`sk-...`):

```
Authorization: Bearer sk-your-litellm-virtual-key
```

The proxy validates this key against:
- The master key (`LITELLM_MASTER_KEY`) for admin access
- Virtual keys (stored in PostgreSQL if `DATABASE_URL` is configured)
- Or no key required if `general_settings.master_key` is not set (open proxy)

### 2. LiteLLM Proxy → SAP AI Core

The proxy authenticates to SAP AI Core using **OAuth2 Client Credentials**:

```
┌────────────────────────────────────────────────────────────┐
│                  OAuth2 Token Flow                          │
│                                                            │
│  1. LiteLLM reads AICORE_CLIENT_ID + AICORE_CLIENT_SECRET  │
│     (set via cf set-env from AI Core service key)          │
│                                                            │
│  2. POST {AICORE_AUTH_URL}                                 │
│     grant_type=client_credentials                          │
│     → Bearer JWT token (~1 hour expiry)                    │
│                                                            │
│  3. Every AI Core request:                                 │
│     Authorization: Bearer {token}                          │
│     AI-Resource-Group: {resource_group}                    │
│                                                            │
│  4. Token renewal: aicore_token_helper.py handles          │
│     refresh before each LiteLLM startup                   │
└────────────────────────────────────────────────────────────┘
```

### 3. Service Key Structure

When you create an SAP AI Core service key, you get:

```json
{
  "clientid": "sb-xxxxxxxx!tNNNNN|aicore!bNNNNN",
  "clientsecret": "xxxxxxxxxxxxxx=",
  "identityzone": "your-subaccount",
  "url": "https://your-subaccount.authentication.us10.hana.ondemand.com",
  "serviceurls": {
    "AI_API_URL": "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com"
  }
}
```

These map to environment variables:

| Service Key Field | Environment Variable |
|---|---|
| `clientid` | `AICORE_CLIENT_ID` |
| `clientsecret` | `AICORE_CLIENT_SECRET` |
| `url` + `/oauth/token` | `AICORE_AUTH_URL` |
| `serviceurls.AI_API_URL` | `AICORE_BASE_URL` |

---

## SAP AI Core Inference URL Pattern

For each deployed model in AI Core, the inference endpoint follows:

```
{AICORE_BASE_URL}/v2/inference/deployments/{deployment_id}/v1/chat/completions
```

LiteLLM is configured with `api_base` pointing to:
```
{AICORE_BASE_URL}/v2/inference/deployments/{deployment_id}/v1
```

LiteLLM then appends `/chat/completions`, `/embeddings`, etc. automatically.

### Required Headers

Every request to SAP AI Core must include:

| Header | Value | Purpose |
|---|---|---|
| `Authorization` | `Bearer {oauth2_token}` | Authentication |
| `AI-Resource-Group` | `default` (or custom) | Tenant/workspace isolation |
| `Content-Type` | `application/json` | Standard |

---

## Deployment Model

```
┌─────────────────────────────────────────────────────────┐
│  CF App: litellm-sap-btp                                │
│                                                          │
│  Runtime: Docker container                              │
│  Image: ghcr.io/your-org/litellm-sap-btp:latest        │
│  Memory: 1G                                              │
│  Instances: 1 (scale to N for HA)                       │
│  Port: 8080 (set by CF PORT env var)                    │
│                                                          │
│  Health check: GET /health/liveliness (HTTP)            │
│  Startup timeout: 180s (Docker pull can be slow)        │
│                                                          │
│  Config: litellm_config.yaml (baked into image)         │
│  Secrets: cf set-env (never in manifest.yml)            │
└─────────────────────────────────────────────────────────┘
```

### Why Docker (not Buildpack)?

SAP BTP CF supports both buildpack and Docker-based apps. We use Docker because:

1. **LiteLLM has complex Python dependencies** — the official image handles this correctly
2. **Reproducible builds** — same image runs locally and in CF
3. **Version pinning** — `litellm:main-stable` gives a known-good version
4. **No buildpack compatibility issues** — Python buildpack versions can lag

### Scaling

For production horizontal scaling:

```bash
cf scale litellm-sap-btp -i 3
```

For multi-instance rate limiting, enable Redis:
```yaml
# litellm_config.yaml
router_settings:
  redis_host: os.environ/REDIS_HOST
  redis_password: os.environ/REDIS_PASSWORD
  redis_port: 6379
```

---

## Security Layers

| Layer | Mechanism |
|---|---|
| **Network** | CF routing — HTTPS only via CF GoRouter |
| **App authentication** | LiteLLM virtual keys (`sk-...`) |
| **AI Core authentication** | OAuth2 client credentials (JWT) |
| **Secret management** | `cf set-env` — secrets never in source |
| **XSUAA (optional)** | `xs-security.json` for SSO/role-based access |
| **Rate limiting** | LiteLLM `rpm`/`tpm` limits per model/key |

---

## Token Refresh Strategy

OAuth2 tokens from SAP XSUAA expire in ~3600 seconds (1 hour). Options:

### Option A: Startup-only (Simple, current default)
`aicore_token_helper.py` fetches a token at container startup.
- ✅ Simple, no moving parts
- ⚠️ Token expires after 1 hour if app runs without restart
- Suitable for: dev/test, batch workloads, short-lived containers

### Option B: Periodic refresh via CF task (Recommended for prod)
Schedule a CF task every 45 minutes to refresh the token:
```bash
cf run-task litellm-sap-btp \
  "python3 /app/aicore_token_helper.py && cf set-env litellm-sap-btp AICORE_OAUTH_TOKEN \$(cat /tmp/token)" \
  --name token-refresh
```

### Option C: Custom LiteLLM auth handler (Advanced)
Implement a `custom_auth.py` that fetches a fresh token per-request.
See [LiteLLM custom auth docs](https://docs.litellm.ai/docs/proxy/custom_auth).
