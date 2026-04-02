# LiteLLM SAP BTP Gateway

Deploy [LiteLLM Proxy](https://docs.litellm.ai) as a unified AI gateway on **SAP BTP Cloud Foundry**, backed by **SAP AI Core**'s Generative AI Hub. Expose GPT-4o, Claude 3.5 Sonnet, Gemini 1.5 Pro, Mistral, Llama, and more — all through a single OpenAI-compatible endpoint.

```
Your App (OpenAI SDK)
       ↓  sk-your-litellm-key
LiteLLM Proxy (SAP BTP CF)       ← this repo
       ↓  Bearer {oauth2_token} + AI-Resource-Group
SAP AI Core (Generative AI Hub)
       ↓
GPT-4o / Claude / Gemini / Mistral / Llama ...
```

---

## Features

- **Single endpoint** for all models — point your OpenAI SDK at this gateway, done
- **SAP AI Core auth** — handles OAuth2 client credentials automatically
- **Model aliases** — `gpt-4o`, `claude-3-5-sonnet`, `mistral-large`, etc.
- **CF-native** — deploys with `cf push` using a standard `manifest.yml`
- **No MTA, no MBT** — Docker image + CF manifest, that's it
- **Secrets-safe** — credentials via `cf set-env`, nothing in source control
- **Fallback chains** — if one model fails, retry on another
- **Rate limiting** — per-model RPM/TPM limits
- **OpenAI SDK compatible** — zero client code changes needed

---

## Repository Structure

```
litellm-sap-btp/
├── README.md                    # This file
├── Dockerfile                   # LiteLLM proxy container
├── manifest.yml                 # CF push manifest (no MTA needed)
├── litellm_config.yaml          # LiteLLM proxy configuration
├── xs-security.json             # XSUAA security descriptor (optional SSO)
├── .env.example                 # Environment variables template
├── .gitignore
├── scripts/
│   ├── aicore_token_helper.py   # OAuth2 token fetcher (pure stdlib Python)
│   ├── setup-ai-core.sh         # Automated setup: service key → cf set-env
│   └── deploy.sh                # Build + push image + cf push automation
└── docs/
    ├── ARCHITECTURE.md          # System design, auth flow, diagrams
    ├── SETUP.md                 # Step-by-step setup guide
    ├── TROUBLESHOOTING.md       # Common issues and fixes
    └── SAP-AI-CORE-MODELS.md   # Available models and deployment mapping
```

---

## Quick Start

### Prerequisites

- [CF CLI v8+](https://docs.cloudfoundry.org/cf-cli/install-go-cli.html) logged in to your BTP CF space
- [Docker](https://www.docker.com/get-started) (to build and push the image)
- SAP AI Core service instance with at least one active deployment
- A container registry (Docker Hub, GHCR, or similar)

### 1. Clone

```bash
git clone https://github.com/cadiraca/litellm-sap-btp.git
cd litellm-sap-btp
```

### 2. Build and push the Docker image

```bash
# Build for linux/amd64 (required for CF)
docker build --platform linux/amd64 \
  -t ghcr.io/YOUR_ORG/litellm-sap-btp:latest .

# Push to your registry
docker push ghcr.io/YOUR_ORG/litellm-sap-btp:latest
```

### 3. Update `manifest.yml`

```yaml
docker:
  image: ghcr.io/YOUR_ORG/litellm-sap-btp:latest  # ← your image
```

### 4. Deploy to CF

```bash
cf push
```

### 5. Inject credentials

```bash
# Set your AI Core service key values
cf set-env litellm-sap-btp AICORE_BASE_URL     "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com"
cf set-env litellm-sap-btp AICORE_AUTH_URL     "https://YOUR-SUBACCOUNT.authentication.us10.hana.ondemand.com/oauth/token"
cf set-env litellm-sap-btp AICORE_CLIENT_ID    "sb-xxxxxxxx!tNNNNN|aicore!bNNNNN"
cf set-env litellm-sap-btp AICORE_CLIENT_SECRET "your-client-secret"

# Set the LiteLLM master key (admin API key)
cf set-env litellm-sap-btp LITELLM_MASTER_KEY  "sk-your-secure-key"

# Set deployment API base URLs (one per model you want to expose)
# Pattern: {AICORE_BASE_URL}/v2/inference/deployments/{DEPLOYMENT_ID}/v1
cf set-env litellm-sap-btp AICORE_GPT4O_API_BASE \
  "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com/v2/inference/deployments/YOUR_GPT4O_ID/v1"

# Fetch initial OAuth2 token and inject it
TOKEN=$(python3 scripts/aicore_token_helper.py)
cf set-env litellm-sap-btp AICORE_OAUTH_TOKEN "$TOKEN"

# Apply all env changes
cf restage litellm-sap-btp
```

Or use the automated script (reads your service key automatically):

```bash
./scripts/setup-ai-core.sh
```

### 6. Test it

```bash
APP_URL=https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com

# Health check
curl $APP_URL/health/liveliness

# List models
curl $APP_URL/v1/models -H "Authorization: Bearer sk-your-key"

# Chat completion
curl -X POST $APP_URL/v1/chat/completions \
  -H "Authorization: Bearer sk-your-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4o", "messages": [{"role": "user", "content": "Hello!"}]}'
```

---

## Supported Models

All models route through SAP AI Core's Generative AI Hub.
Each model requires an active deployment in your AI Core instance.

| Model Alias | Provider | Notes |
|---|---|---|
| `gpt-4o` | OpenAI via Azure | Default flagship model |
| `gpt-4o-mini` | OpenAI via Azure | Fast, cost-effective |
| `claude-3-5-sonnet` | Anthropic | Best for reasoning |
| `claude-3-haiku` | Anthropic | Fastest Claude |
| `gemini-1-5-pro` | Google | 1M token context |
| `mistral-large` | Mistral AI | Strong European model |
| `llama-3-1-70b` | Meta | Open source |
| `text-embedding-ada-002` | OpenAI | Embeddings |

See [docs/SAP-AI-CORE-MODELS.md](docs/SAP-AI-CORE-MODELS.md) for the full list and how to deploy each model.

---

## Using the Gateway

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1",
    api_key="sk-your-litellm-key"
)

# Use any configured model
response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Explain SAP BTP in one sentence."}]
)
print(response.choices[0].message.content)

# Embeddings work too
embedding = client.embeddings.create(
    model="text-embedding-ada-002",
    input="Hello SAP AI Core"
)
```

### Node.js

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1',
  apiKey: 'sk-your-litellm-key'
});

const chat = await client.chat.completions.create({
  model: 'claude-3-5-sonnet',
  messages: [{ role: 'user', content: 'Hello!' }]
});
```

### curl

```bash
curl -X POST https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1/chat/completions \
  -H "Authorization: Bearer sk-your-litellm-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-large",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

---

## Environment Variables Reference

Set all secrets via `cf set-env`. **Never commit credentials to source control.**

| Variable | Required | Description |
|---|---|---|
| `LITELLM_MASTER_KEY` | ✅ | Admin key for LiteLLM proxy (must start with `sk-`) |
| `AICORE_BASE_URL` | ✅ | AI Core API base URL from service key |
| `AICORE_AUTH_URL` | ✅ | XSUAA OAuth2 token URL (`{url}/oauth/token`) |
| `AICORE_CLIENT_ID` | ✅ | OAuth2 client ID from service key |
| `AICORE_CLIENT_SECRET` | ✅ | OAuth2 client secret from service key |
| `AICORE_OAUTH_TOKEN` | ✅ | Current Bearer token (refresh every ~50 min) |
| `AICORE_RESOURCE_GROUP` | ✅ | AI Core resource group (default: `default`) |
| `AICORE_GPT4O_API_BASE` | ⚡ | Deployment URL for GPT-4o |
| `AICORE_GPT4O_MINI_API_BASE` | ⚡ | Deployment URL for GPT-4o Mini |
| `AICORE_CLAUDE_35_SONNET_API_BASE` | ⚡ | Deployment URL for Claude 3.5 Sonnet |
| `AICORE_CLAUDE_3_HAIKU_API_BASE` | ⚡ | Deployment URL for Claude 3 Haiku |
| `AICORE_GEMINI_15_PRO_API_BASE` | ⚡ | Deployment URL for Gemini 1.5 Pro |
| `AICORE_MISTRAL_LARGE_API_BASE` | ⚡ | Deployment URL for Mistral Large |
| `AICORE_LLAMA_31_70B_API_BASE` | ⚡ | Deployment URL for Llama 3.1 70B |
| `AICORE_TEXT_EMBEDDING_API_BASE` | ⚡ | Deployment URL for Text Embedding Ada 002 |
| `DATABASE_URL` | ➖ | PostgreSQL URL for virtual keys & spend tracking |
| `LITELLM_LOG` | ➖ | Log level: `DEBUG`, `INFO`, `WARNING` (default: `INFO`) |

> ⚡ = Set at least one model deployment URL, or the gateway has nothing to route to.

---

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full system diagram, auth flow, and design decisions.

---

## Token Refresh

SAP AI Core OAuth2 tokens expire in ~1 hour. The `aicore_token_helper.py` script fetches a fresh token:

```bash
# Refresh manually
TOKEN=$(python3 scripts/aicore_token_helper.py)
cf set-env litellm-sap-btp AICORE_OAUTH_TOKEN "$TOKEN"
cf restage litellm-sap-btp
```

For production, automate this on a 45-minute schedule. See [docs/SETUP.md](docs/SETUP.md#token-refresh-production) for options.

---

## Scaling

```bash
# Scale horizontally
cf scale litellm-sap-btp -i 3

# Scale memory
cf scale litellm-sap-btp -m 2G
```

For multi-instance deployments, add Redis to `litellm_config.yaml` for shared rate limit state. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#scaling).

---

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues:
- App crashes on startup
- 401 from AI Core (expired token)
- 404 deployment not found
- Health check timeouts
- Missing environment variables

---

## Security Notes

- **No secrets in source** — all credentials via `cf set-env`
- **Master key** — required for admin API; use virtual keys for end users
- **XSUAA** — `xs-security.json` provides optional SSO/RBAC integration
- **HTTPS only** — CF GoRouter enforces TLS termination
- **Token rotation** — `AICORE_OAUTH_TOKEN` should be refreshed every 45-50 minutes

---

## Documentation

| Doc | Description |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, auth flows, diagrams |
| [SETUP.md](docs/SETUP.md) | Full step-by-step setup guide |
| [SAP-AI-CORE-MODELS.md](docs/SAP-AI-CORE-MODELS.md) | Model list, deployment IDs, API patterns |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues and fixes |

---

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.

---

*Built with [LiteLLM](https://github.com/BerriAI/litellm) · Runs on [SAP BTP Cloud Foundry](https://www.sap.com/products/technology-platform.html) · Powered by [SAP AI Core](https://help.sap.com/docs/sap-ai-core)*
