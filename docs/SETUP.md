# Setup Guide

Step-by-step instructions to deploy LiteLLM as an AI Gateway on SAP BTP Cloud Foundry with SAP AI Core.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| CF CLI | v8+ | [docs.cloudfoundry.org](https://docs.cloudfoundry.org/cf-cli/install-go-cli.html) |
| Docker | 20.10+ | [docker.com](https://www.docker.com/get-started) |
| jq | any | `brew install jq` / `apt install jq` |
| curl | any | Pre-installed on most systems |
| git | any | Pre-installed or [git-scm.com](https://git-scm.com) |

**SAP BTP access required:**
- A BTP subaccount with Cloud Foundry enabled
- A CF space to deploy into
- An SAP AI Core service entitlement (`aicore` / `extended` plan or higher)
- Permission to create service instances and service keys

---

## Step 1 — Clone and Configure

```bash
git clone https://github.com/cadiraca/litellm-sap-btp.git
cd litellm-sap-btp

# Copy the env template
cp .env.example .env
```

Open `.env` and fill in your values. At minimum you need:
- `LITELLM_MASTER_KEY` — the admin key for your proxy (must start with `sk-`)

The AI Core credentials will be filled in after Step 3.

---

## Step 2 — Log in to Cloud Foundry

```bash
# Find your API endpoint in BTP Cockpit → Cloud Foundry → Overview
cf login -a https://api.cf.us10-001.hana.ondemand.com \
         -o "your-org" \
         -s "your-space"
```

Verify:
```bash
cf target
```

---

## Step 3 — Build and Push the Docker Image

You need a container registry accessible from SAP BTP CF.
Options: Docker Hub, GitHub Container Registry (GHCR), SAP Container Registry.

### Option A: GitHub Container Registry (GHCR)

```bash
# Log in to GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

# Build for linux/amd64 (required for CF)
docker build --platform linux/amd64 \
  -t ghcr.io/YOUR_ORG/litellm-sap-btp:latest .

# Push
docker push ghcr.io/YOUR_ORG/litellm-sap-btp:latest
```

### Option B: Docker Hub

```bash
docker login
docker build --platform linux/amd64 -t YOUR_DOCKERHUB_USER/litellm-sap-btp:latest .
docker push YOUR_DOCKERHUB_USER/litellm-sap-btp:latest
```

### Option C: Use deploy.sh

```bash
export DOCKER_REGISTRY=ghcr.io/your-org
export DOCKER_USERNAME=your-username
export DOCKER_TOKEN=your-token
./scripts/deploy.sh --build --push
```

---

## Step 4 — Update manifest.yml

Edit `manifest.yml` and set your Docker image URL:

```yaml
applications:
  - name: litellm-sap-btp
    docker:
      image: ghcr.io/YOUR_ORG/litellm-sap-btp:latest  # ← update this
```

If your registry is **private**, also add credentials:
```yaml
    docker:
      image: ghcr.io/YOUR_ORG/litellm-sap-btp:latest
      username: YOUR_USERNAME    # or use a bot account
```
Then set the password:
```bash
cf set-env litellm-sap-btp CF_DOCKER_PASSWORD your-registry-token
```

---

## Step 5 — First Deploy (No Secrets Yet)

```bash
cf push
```

The app will start but fail health checks until credentials are set.
That's fine — we'll inject them next.

```bash
# Check app status
cf app litellm-sap-btp

# View logs
cf logs litellm-sap-btp --recent
```

---

## Step 6 — Create SAP AI Core Service Instance

If you don't already have an AI Core service instance:

```bash
# List available AI Core plans
cf marketplace -e aicore

# Create service instance (use the plan available in your subaccount)
cf create-service aicore extended litellm-aicore

# Create a service key
cf create-service-key litellm-aicore litellm-aicore-key

# View the service key (contains credentials)
cf service-key litellm-aicore litellm-aicore-key
```

The output looks like:
```json
{
  "clientid": "sb-xxxxxxxx!tNNNNN|aicore!bNNNNN",
  "clientsecret": "xxxxxxxxxxxxxxxx=",
  "url": "https://your-subaccount.authentication.us10.hana.ondemand.com",
  "serviceurls": {
    "AI_API_URL": "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com"
  }
}
```

---

## Step 7 — Get AI Core Deployment IDs

In SAP AI Launchpad (or via API), find your deployed model IDs:

### Via SAP AI Launchpad
1. Open [AI Launchpad](https://ai-launchpad.cfapps.us10.hana.ondemand.com)
2. Go to **ML Operations → Deployments**
3. For each active deployment, note the **Deployment ID** (e.g., `d1a2b3c4d5e6f789`)

### Via AI Core API

First get a token:
```bash
# From your service key values:
TOKEN=$(curl -s -X POST \
  "https://YOUR-SUBACCOUNT.authentication.us10.hana.ondemand.com/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "YOUR_CLIENT_ID:YOUR_CLIENT_SECRET" \
  -d "grant_type=client_credentials" \
  | jq -r '.access_token')

# List all deployments
curl -s \
  "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com/v2/inference/deployments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" \
  | jq '.resources[] | {id: .id, model: .details.resources.backendDetails.modelName, status: .status}'
```

---

## Step 8 — Inject All Credentials

Use `setup-ai-core.sh` (recommended) or set env vars manually.

### Automated (recommended)

```bash
# Export your deployment IDs (skip any you don't have)
export AICORE_GPT4O_DEPLOYMENT_ID=d1a2b3c4d5e6f789
export AICORE_CLAUDE_35_SONNET_DEPLOYMENT_ID=d2b3c4d5e6f78901
export AICORE_GEMINI_15_PRO_DEPLOYMENT_ID=d3c4d5e6f7890123
# ... etc

./scripts/setup-ai-core.sh
```

The script will:
1. Create the service instance and key (if not exists)
2. Extract credentials automatically
3. Set all `cf set-env` variables
4. Fetch an initial OAuth2 token
5. Restage the app

### Manual

```bash
# Core credentials (from your service key)
cf set-env litellm-sap-btp AICORE_BASE_URL     "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com"
cf set-env litellm-sap-btp AICORE_AUTH_URL     "https://your-subaccount.authentication.us10.hana.ondemand.com/oauth/token"
cf set-env litellm-sap-btp AICORE_CLIENT_ID    "sb-xxxxxxxx!tNNNNN|aicore!bNNNNN"
cf set-env litellm-sap-btp AICORE_CLIENT_SECRET "your-client-secret"
cf set-env litellm-sap-btp AICORE_RESOURCE_GROUP "default"

# LiteLLM master key (generate your own)
cf set-env litellm-sap-btp LITELLM_MASTER_KEY "sk-your-secure-key-here"

# Deployment API base URLs (pattern: {BASE_URL}/v2/inference/deployments/{ID}/v1)
cf set-env litellm-sap-btp AICORE_GPT4O_API_BASE \
  "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com/v2/inference/deployments/YOUR_GPT4O_ID/v1"

cf set-env litellm-sap-btp AICORE_CLAUDE_35_SONNET_API_BASE \
  "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com/v2/inference/deployments/YOUR_CLAUDE_ID/v1"

# ... repeat for each model

# Fetch initial token
TOKEN=$(python3 scripts/aicore_token_helper.py)
cf set-env litellm-sap-btp AICORE_OAUTH_TOKEN "$TOKEN"

# Apply all changes
cf restage litellm-sap-btp
```

---

## Step 9 — Verify the Deployment

```bash
# Check app status
cf app litellm-sap-btp

# Stream live logs
cf logs litellm-sap-btp

# Health check
curl https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/health/liveliness

# List available models
curl https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1/models \
  -H "Authorization: Bearer sk-your-master-key"

# Test a completion
curl -X POST \
  https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1/chat/completions \
  -H "Authorization: Bearer sk-your-master-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello! What models do you know?"}]
  }'
```

---

## Step 10 — Use with OpenAI SDK

Any OpenAI-compatible client works with zero code changes:

### Python
```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1",
    api_key="sk-your-litellm-key"
)

response = client.chat.completions.create(
    model="gpt-4o",          # or "claude-3-5-sonnet", "gemini-1-5-pro", etc.
    messages=[
        {"role": "user", "content": "Explain SAP AI Core in one paragraph."}
    ]
)
print(response.choices[0].message.content)
```

### Node.js
```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1',
  apiKey: 'sk-your-litellm-key'
});

const response = await client.chat.completions.create({
  model: 'claude-3-5-sonnet',
  messages: [{ role: 'user', content: 'Hello!' }]
});
```

### curl
```bash
curl -X POST https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1/chat/completions \
  -H "Authorization: Bearer sk-your-litellm-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "mistral-large", "messages": [{"role": "user", "content": "Hi"}]}'
```

---

## Token Refresh (Production)

OAuth2 tokens expire after ~1 hour. For production, set up periodic refresh:

### Option A: CF Scheduled Task (Recommended)

Create a shell script that refreshes the token and restarts the app:

```bash
#!/bin/bash
# refresh-token.sh — run this on a schedule (e.g., every 45 minutes via cron)
cf login -a "$CF_API" -u "$CF_USER" -p "$CF_PASSWORD" -o "$CF_ORG" -s "$CF_SPACE"

NEW_TOKEN=$(python3 scripts/aicore_token_helper.py)
cf set-env litellm-sap-btp AICORE_OAUTH_TOKEN "$NEW_TOKEN"
cf restart litellm-sap-btp --strategy rolling
```

### Option B: Custom LiteLLM Auth Handler

For zero-downtime token refresh, implement `custom_auth.py`:

```python
# custom_auth.py — place in /app/ and reference in litellm_config.yaml
import os
import time
import requests

_token_cache = {"token": None, "expires_at": 0}

def fetch_token():
    resp = requests.post(
        os.environ["AICORE_AUTH_URL"],
        data={"grant_type": "client_credentials"},
        auth=(os.environ["AICORE_CLIENT_ID"], os.environ["AICORE_CLIENT_SECRET"])
    )
    resp.raise_for_status()
    data = resp.json()
    _token_cache["token"] = f"Bearer {data['access_token']}"
    _token_cache["expires_at"] = time.time() + data.get("expires_in", 3600) - 60
    return _token_cache["token"]

def get_token():
    if time.time() > _token_cache["expires_at"]:
        return fetch_token()
    return _token_cache["token"]
```

Then in `litellm_config.yaml`, use a custom hook to inject the token per-request.
