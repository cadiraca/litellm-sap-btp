# SAP AI Core — Model Deployments & Endpoint Patterns

## Verified Deployments (dev-uat, US10)

| Model | Deployment ID | Provider | Endpoint Path | Status |
|-------|--------------|----------|---------------|--------|
| gpt-4.1 | `def4a837c37158f9` | OpenAI | `/v1/chat/completions` | ✅ Verified |
| gpt-5 (2025-08-07) | `dbbd709716d5e3e2` | OpenAI | `/v1/chat/completions` | ✅ Verified (reasoning model) |
| claude-4.5-sonnet | `d955f96663d5e62a` | Anthropic | `/invoke` | ✅ Verified |
| claude-4.5-haiku | `d826e8baca49c5f9` | Anthropic | `/invoke` | ✅ Verified |
| gemini-2.5-pro | `d1a4ec86b5abc63f` | Google | `/models/gemini-2.5-pro:generateContent` | ✅ Verified |
| sonar (perplexity) | `d50ba3b92a3cd426` | Perplexity | `/chat/completions` | ✅ Verified |
| sap-rpt-1-small | `db8f88681b7cb15f` | SAP | TBD | ⚠️ Not tested |
| orchestration | `da9d38433b578ce1` | SAP | `/completion` | ⚠️ Requires templating config |

## Critical: Endpoint Patterns Differ by Provider!

SAP AI Core does **NOT** use a unified endpoint. Each provider has its own path:

### OpenAI Models (GPT-4.1, GPT-5)
```
POST {AI_API_URL}/v2/inference/deployments/{deployment_id}/v1/chat/completions
Authorization: Bearer {oauth2_token}
AI-Resource-Group: default

{
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 100            // GPT-4.1
  "max_completion_tokens": 100  // GPT-5 (reasoning model!)
}
```

> ⚠️ **GPT-5 is a reasoning model.** It uses `max_completion_tokens` (not `max_tokens`) and consumes reasoning tokens internally. Budget ~5-10x more tokens than GPT-4.1 for the same output.

### Anthropic Models (Claude)
```
POST {AI_API_URL}/v2/inference/deployments/{deployment_id}/invoke
Authorization: Bearer {oauth2_token}
AI-Resource-Group: default

{
  "anthropic_version": "bedrock-2023-05-31",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 100
}
```

> Note: Uses Anthropic's native Messages API format, NOT OpenAI format. The `anthropic_version` field is **required**.

### Google Gemini Models
```
POST {AI_API_URL}/v2/inference/deployments/{deployment_id}/models/gemini-2.5-pro:generateContent
Authorization: Bearer {oauth2_token}
AI-Resource-Group: default

{
  "contents": [{"role": "user", "parts": [{"text": "Hello"}]}]
}
```

> Note: Uses Google's native Gemini API format. Response is in `candidates[0].content.parts[0].text`.

### Perplexity Sonar
```
POST {AI_API_URL}/v2/inference/deployments/{deployment_id}/chat/completions
Authorization: Bearer {oauth2_token}
AI-Resource-Group: default

{
  "model": "sonar",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 100
}
```

> Note: Uses `/chat/completions` (no `/v1` prefix). Response includes `citations` and `search_results` arrays.

## How LiteLLM Handles This

LiteLLM normalizes all these behind a single OpenAI-compatible endpoint:

```bash
# All of these work through the LiteLLM proxy:
curl http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer sk-your-master-key" \
  -d '{"model": "gpt-4.1", "messages": [{"role": "user", "content": "Hello"}]}'

curl http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer sk-your-master-key" \
  -d '{"model": "claude-4.5-sonnet", "messages": [{"role": "user", "content": "Hello"}]}'

curl http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer sk-your-master-key" \
  -d '{"model": "gemini-2.5-pro", "messages": [{"role": "user", "content": "Hello"}]}'
```

The proxy translates to the correct provider-specific format automatically.

## OAuth2 Token

All requests require a Bearer token from SAP XSUAA:

```bash
curl -X POST "${AUTH_URL}/oauth/token" \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" \
  -d "grant_type=client_credentials"
```

Tokens expire (typically 12h). Use `scripts/aicore_token_helper.py` to refresh.

## Finding Your Deployment IDs

```bash
# List all running deployments
curl -s "${AI_API_URL}/v2/lm/deployments?status=RUNNING" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "AI-Resource-Group: default" | jq '.resources[] | {id, model: .details.resources.backend_details.model}'
```
