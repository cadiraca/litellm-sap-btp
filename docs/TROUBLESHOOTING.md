# Troubleshooting

Common issues and solutions when deploying LiteLLM on SAP BTP Cloud Foundry with SAP AI Core.

---

## Deployment Issues

### `cf push` fails: "Docker support is disabled"

**Error:**
```
Server error, status code: 503, error code: 300001,
message: Docker support is disabled. Contact your administrator.
```

**Cause:** Docker apps are disabled in your CF environment.

**Fix:** Enable Docker feature flag:
```bash
cf enable-feature-flag diego_docker
```
If you don't have admin rights, contact your BTP platform team.

---

### App crashes immediately after `cf push`

**Check logs:**
```bash
cf logs litellm-sap-btp --recent
```

**Common causes:**

1. **Missing environment variables** — LiteLLM fails to start without valid config.
   ```
   Error: LITELLM_MASTER_KEY not set
   ```
   Fix: `cf set-env litellm-sap-btp LITELLM_MASTER_KEY sk-your-key && cf restage litellm-sap-btp`

2. **Docker image not found** — Wrong image URL in `manifest.yml`.
   ```
   Failed to create container: docker pull failed
   ```
   Fix: Verify the image exists and CF has access to the registry.

3. **Port mismatch** — App not listening on CF's `$PORT`.
   ```
   Health check timed out
   ```
   Fix: Ensure `manifest.yml` has `PORT: "8080"` and the Dockerfile CMD uses `${PORT:-8080}`.

---

### Health check fails / App stuck in "starting"

**Error in `cf app`:**
```
#0   starting   2024-01-01T00:00:00Z   0.0%   0 of 1G
```

**Checks:**

```bash
# 1. Check if health endpoint exists
curl https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/health/liveliness

# 2. Increase timeout in manifest.yml
timeout: 300  # ← increase to 300s
health-check-invocation-timeout: 60

# 3. Check logs for startup errors
cf logs litellm-sap-btp --recent | grep -i error
```

---

### Private registry authentication fails

**Error:**
```
Error response from daemon: unauthorized: access to the requested resource is not authorized
```

**Fix:**
```bash
# Set CF docker credentials
cf set-env litellm-sap-btp CF_DOCKER_PASSWORD your-registry-token

# Update manifest.yml
docker:
  image: ghcr.io/your-org/litellm-sap-btp:latest
  username: your-username  # ← add this
```

---

## AI Core Authentication Issues

### 401 Unauthorized from AI Core

**Error in logs:**
```
LiteLLM: API Error - 401 - {"error":"unauthorized_client","error_description":"..."}
```

**Causes and fixes:**

1. **Token expired** — OAuth2 tokens last ~1 hour.
   ```bash
   # Refresh the token
   python3 scripts/aicore_token_helper.py
   TOKEN=$(python3 scripts/aicore_token_helper.py)
   cf set-env litellm-sap-btp AICORE_OAUTH_TOKEN "$TOKEN"
   cf restage litellm-sap-btp
   ```

2. **Wrong client credentials** — Double-check from service key.
   ```bash
   cf service-key litellm-aicore litellm-aicore-key | jq '{clientid, clientsecret}'
   ```

3. **Missing AI-Resource-Group header** — Ensure it's set in `litellm_config.yaml`.
   ```yaml
   extra_headers:
     AI-Resource-Group: os.environ/AICORE_RESOURCE_GROUP
   ```

---

### 404 Not Found from AI Core

**Error:**
```
LiteLLM: API Error - 404 - {"message":"Deployment not found"}
```

**Causes:**

1. **Wrong deployment ID** — Verify the deployment exists and is RUNNING:
   ```bash
   curl -s "${AICORE_BASE_URL}/v2/inference/deployments/${DEPLOYMENT_ID}" \
     -H "Authorization: Bearer $TOKEN" \
     -H "AI-Resource-Group: default" \
     | jq '{id, status}'
   ```

2. **Deployment not in RUNNING state** — Check status:
   ```bash
   curl -s "${AICORE_BASE_URL}/v2/inference/deployments" \
     -H "Authorization: Bearer $TOKEN" \
     -H "AI-Resource-Group: default" \
     | jq '.resources[] | {id, status}'
   ```
   A deployment must be `RUNNING` before it can serve requests.

3. **Wrong api_base URL** — The URL must end in `/v1`:
   ```
   # Correct:
   https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com/v2/inference/deployments/d1234.../v1
   
   # Wrong (missing /v1):
   https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com/v2/inference/deployments/d1234...
   ```

---

### Token Fetch Fails: "Cannot reach XSUAA"

**Error from `aicore_token_helper.py`:**
```
[aicore_token_helper] ERROR: Cannot reach XSUAA: <urlopen error [Errno -2]>
```

**Causes:**
- `AICORE_AUTH_URL` is wrong or incomplete
- Network connectivity issue from CF to XSUAA

**Fix:**
```bash
# Test the token URL manually
curl -v -X POST "$AICORE_AUTH_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "$AICORE_CLIENT_ID:$AICORE_CLIENT_SECRET" \
  -d "grant_type=client_credentials"

# Verify the URL format (must include /oauth/token)
echo $AICORE_AUTH_URL
# Should look like: https://your-subaccount.authentication.us10.hana.ondemand.com/oauth/token
```

---

## LiteLLM Configuration Issues

### Model not found: "No models with name X"

**Error:**
```json
{"error": {"message": "No models with name 'gpt-4o' found in config"}}
```

**Fix:** The model must be defined in `litellm_config.yaml`. Check that:
1. The `model_name` in config matches exactly what the client sends
2. The `api_base` environment variable is set for that model
3. The container was rebuilt/restarted after config changes

```bash
# Verify model is loaded
curl https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com/v1/models \
  -H "Authorization: Bearer sk-your-key"
```

---

### Environment variable not found in config

**Error:**
```
litellm.exceptions.BadRequestError: os.environ/AICORE_GPT4O_API_BASE not set
```

**Fix:** Set the missing env var:
```bash
cf set-env litellm-sap-btp AICORE_GPT4O_API_BASE "https://..."
cf restage litellm-sap-btp
```

Verify all required env vars are set:
```bash
cf env litellm-sap-btp
```

---

### Request Timeout

**Error:**
```json
{"error": {"message": "LiteLLM Timeout: Request timed out after 600s"}}
```

**Fix:** Adjust timeouts in `litellm_config.yaml`:
```yaml
litellm_settings:
  request_timeout: 600   # increase for very long completions
router_settings:
  timeout: 600
```

Then rebuild and redeploy the Docker image.

---

## CF Environment Issues

### "cf set-env" changes not applied

After `cf set-env`, changes only take effect after **restage** (for environment changes) or **restart** (for config changes without Dockerfile rebuild):

```bash
# For environment variable changes:
cf restage litellm-sap-btp

# For Docker image changes (new build pushed):
cf restart litellm-sap-btp
```

---

### App running out of memory

**Symptoms:** App crashes with exit code 137 (OOM killed)

**Fix in `manifest.yml`:**
```yaml
memory: 2G   # ← increase from 1G
disk_quota: 1G
```
Then `cf push` again.

---

### Multiple instances with stale tokens

If you scale to multiple instances (`cf scale -i 3`), each instance has its own `AICORE_OAUTH_TOKEN` state. After a token refresh:

```bash
# Rolling restart applies new env to all instances
cf set-env litellm-sap-btp AICORE_OAUTH_TOKEN "Bearer $NEW_TOKEN"
cf restart litellm-sap-btp --strategy rolling
```

---

## Useful Diagnostic Commands

```bash
# Full app status
cf app litellm-sap-btp

# All environment variables (check for missing ones)
cf env litellm-sap-btp

# Recent logs (last 100 lines)
cf logs litellm-sap-btp --recent

# Live log stream
cf logs litellm-sap-btp

# SSH into running container (if enabled)
cf ssh litellm-sap-btp

# Check LiteLLM health endpoints
APP_URL=https://litellm-sap-btp.cfapps.us10-001.hana.ondemand.com
curl $APP_URL/health/liveliness
curl $APP_URL/health/readiness
curl $APP_URL/v1/models -H "Authorization: Bearer sk-your-key"

# Test AI Core connectivity directly (from your laptop)
python3 scripts/aicore_token_helper.py
```

---

## Getting Help

1. **LiteLLM docs:** https://docs.litellm.ai
2. **LiteLLM GitHub issues:** https://github.com/BerriAI/litellm/issues
3. **SAP AI Core help:** https://help.sap.com/docs/sap-ai-core
4. **SAP Community (AI/ML):** https://community.sap.com/t5/artificial-intelligence/ct-p/artificial-intelligence
5. **CF CLI reference:** https://docs.cloudfoundry.org/cf-cli/cf-help.html
