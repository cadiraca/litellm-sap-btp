# SAP AI Core — Available Models & Deployment Mapping

SAP AI Core's **Generative AI Hub** provides access to a curated set of foundation models from major providers. Each model must be **deployed** (creating a unique deployment ID) before it can be called.

---

## How Models Work in SAP AI Core

```
Model (scenario/version) → Create Deployment → Deployment ID → Inference URL
                                                    ↓
                              {BASE_URL}/v2/inference/deployments/{ID}/v1
```

Each deployment:
- Gets a unique **Deployment ID** (e.g., `d1a2b3c4d5e6f789`)
- Has a **status**: `RUNNING`, `STOPPED`, `UNKNOWN`
- Belongs to a **resource group** (for tenant isolation)
- Maps to a specific model version

---

## Available Foundation Models (Generative AI Hub)

> **Note:** SAP adds new models regularly. Always check AI Launchpad or the API for the current list in your landscape.

### OpenAI Models (via Azure)

| LiteLLM Alias | SAP AI Core Scenario | Model Version | Context | Notes |
|---|---|---|---|---|
| `gpt-4o` | `foundation-models` | `gpt-4o` | 128K | Latest GPT-4o |
| `gpt-4o-mini` | `foundation-models` | `gpt-4o-mini` | 128K | Fast & cheap |
| `gpt-4` | `foundation-models` | `gpt-4` | 8K | Legacy |
| `gpt-4-32k` | `foundation-models` | `gpt-4-32k` | 32K | Legacy |
| `gpt-35-turbo` | `foundation-models` | `gpt-35-turbo` | 16K | GPT-3.5 Turbo |

### Anthropic Claude Models

| LiteLLM Alias | SAP AI Core Scenario | Model Version | Context | Notes |
|---|---|---|---|---|
| `claude-3-5-sonnet` | `anthropic-claude-3` | `anthropic--claude-3-5-sonnet` | 200K | Best for most tasks |
| `claude-3-opus` | `anthropic-claude-3` | `anthropic--claude-3-opus` | 200K | Most capable |
| `claude-3-haiku` | `anthropic-claude-3` | `anthropic--claude-3-haiku` | 200K | Fastest/cheapest |
| `claude-3-sonnet` | `anthropic-claude-3` | `anthropic--claude-3-sonnet` | 200K | Balanced |

### Google Gemini Models

| LiteLLM Alias | SAP AI Core Scenario | Model Version | Context | Notes |
|---|---|---|---|---|
| `gemini-1-5-pro` | `google-gemini-1.5` | `gemini-1.5-pro` | 1M | Best Google model |
| `gemini-1-5-flash` | `google-gemini-1.5` | `gemini-1.5-flash` | 1M | Fast & cheap |

### Mistral Models

| LiteLLM Alias | SAP AI Core Scenario | Model Version | Context | Notes |
|---|---|---|---|---|
| `mistral-large` | `mistralai-mistral-large` | `mistralai--mistral-large-latest` | 128K | Best Mistral |
| `mistral-small` | `mistralai-mistral-small` | `mistralai--mistral-small-latest` | 32K | — |

### Meta Llama Models

| LiteLLM Alias | SAP AI Core Scenario | Model Version | Context | Notes |
|---|---|---|---|---|
| `llama-3-1-70b` | `meta-llama3.1` | `meta--llama3-70b-instruct` | 128K | Open source |
| `llama-3-1-8b` | `meta-llama3.1` | `meta--llama3-8b-instruct` | 128K | Fastest Llama |

### Embedding Models

| LiteLLM Alias | SAP AI Core Scenario | Model Version | Dimensions | Notes |
|---|---|---|---|---|
| `text-embedding-ada-002` | `foundation-models` | `text-embedding-ada-002` | 1536 | OpenAI |
| `text-embedding-3-small` | `foundation-models` | `text-embedding-3-small` | 1536 | OpenAI |
| `text-embedding-3-large` | `foundation-models` | `text-embedding-3-large` | 3072 | OpenAI |

---

## Deploying a Model in SAP AI Core

### Via AI Launchpad (UI)

1. Open [SAP AI Launchpad](https://ai-launchpad.cfapps.us10.hana.ondemand.com)
2. Navigate to **ML Operations → Configurations**
3. Create a configuration for the model scenario
4. Go to **ML Operations → Deployments → Create**
5. Select your configuration and create the deployment
6. Wait for status `RUNNING` (~1-2 minutes)
7. Copy the **Deployment ID** from the details page

### Via API

```bash
# Prerequisites: TOKEN and BASE_URL set (see SETUP.md)

# Step 1: List available scenarios (model families)
curl -s "${BASE_URL}/v2/lm/scenarios" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" | jq '.resources[].id'

# Step 2: Get versions for a scenario
curl -s "${BASE_URL}/v2/lm/scenarios/foundation-models/versions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" | jq '.'

# Step 3: Create a configuration
curl -s -X POST "${BASE_URL}/v2/lm/configurations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "gpt-4o-config",
    "executableId": "azure-openai",
    "scenarioId": "foundation-models",
    "versionId": "0.0.1",
    "parameterBindings": [
      {"key": "modelName", "value": "gpt-4o"},
      {"key": "modelVersion", "value": "latest"}
    ]
  }' | jq '{id: .id, name: .name}'

# Step 4: Create a deployment
CONFIGURATION_ID="your-config-id-from-step-3"
curl -s -X POST "${BASE_URL}/v2/inference/deployments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" \
  -H "Content-Type: application/json" \
  -d "{\"configurationId\": \"${CONFIGURATION_ID}\"}" \
  | jq '{id: .id, status: .status}'

# Step 5: Wait and check status
DEPLOYMENT_ID="your-deployment-id"
curl -s "${BASE_URL}/v2/inference/deployments/${DEPLOYMENT_ID}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" \
  | jq '{id: .id, status: .status, url: .deploymentUrl}'
```

---

## Checking Active Deployments

```bash
# List all running deployments with their model names
curl -s "${BASE_URL}/v2/inference/deployments?status=RUNNING" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" \
  | jq '.resources[] | {
      id: .id,
      status: .status,
      model: (.details.resources.backendDetails.modelName // "unknown"),
      scenario: .scenarioId,
      created: .createdAt
    }'
```

---

## Mapping Deployments to LiteLLM Config

Once you have deployment IDs, they become the `api_base` in `litellm_config.yaml`:

```yaml
model_list:
  - model_name: gpt-4o           # ← name your clients use
    litellm_params:
      model: openai/gpt-4o       # ← openai/ prefix = OpenAI-compat protocol
      api_base: https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com/v2/inference/deployments/d1a2b3c4d5e6/v1
      api_key: os.environ/AICORE_OAUTH_TOKEN
      extra_headers:
        AI-Resource-Group: default
```

The environment variable approach in this repo makes this dynamic:

```bash
# Set deployment IDs, let setup-ai-core.sh build the full URLs
export AICORE_GPT4O_DEPLOYMENT_ID=d1a2b3c4d5e6f789
./scripts/setup-ai-core.sh
# → sets AICORE_GPT4O_API_BASE=https://.../v2/inference/deployments/d1a2b3c4.../v1
```

---

## Model Alias Recommendations

Use simple, provider-agnostic aliases in LiteLLM — your clients won't need to change when SAP updates the underlying deployment:

| Client sends | LiteLLM routes to |
|---|---|
| `gpt-4o` | SAP AI Core → GPT-4o deployment |
| `claude-3-5-sonnet` | SAP AI Core → Claude 3.5 Sonnet deployment |
| `fast` | Load-balanced across GPT-4o-mini + Claude Haiku |
| `embedding` | Text Embedding Ada 002 deployment |

This decoupling is the main value of the gateway — swap models without touching client code.

---

## Rate Limits and Quotas

SAP AI Core enforces rate limits at the service level. In `litellm_config.yaml` you can also set soft limits:

```yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      # ... 
      rpm: 60      # requests per minute (LiteLLM-level enforcement)
      tpm: 100000  # tokens per minute
```

Check your actual limits in BTP Cockpit → AI Core → Service Details.
