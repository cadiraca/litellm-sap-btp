#!/usr/bin/env bash
# =============================================================================
# setup-ai-core.sh
# =============================================================================
# Automates the setup of SAP AI Core service instance and service key on
# SAP BTP Cloud Foundry, then injects credentials into the CF app.
#
# Usage:
#   chmod +x scripts/setup-ai-core.sh
#   ./scripts/setup-ai-core.sh
#
# Prerequisites:
#   - CF CLI installed and logged in (cf login -a <api> -o <org> -s <space>)
#   - jq installed (brew install jq / apt install jq)
#   - The litellm-sap-btp app already deployed (cf push)
#
# What this script does:
#   1. Creates a SAP AI Core service instance (if not exists)
#   2. Creates a service key for it
#   3. Extracts credentials from the service key
#   4. Sets all required CF environment variables on the app
#   5. Builds deployment API base URLs from deployment IDs
#   6. Triggers a restage
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
APP_NAME="${APP_NAME:-litellm-sap-btp}"
AICORE_SERVICE_NAME="${AICORE_SERVICE_NAME:-aicore}"
AICORE_PLAN="${AICORE_PLAN:-extended}"             # or: sap-internal, standard
AICORE_INSTANCE="${AICORE_INSTANCE:-litellm-aicore}"
AICORE_KEY_NAME="${AICORE_KEY_NAME:-litellm-aicore-key}"
AICORE_RESOURCE_GROUP="${AICORE_RESOURCE_GROUP:-default}"

# Master key for LiteLLM proxy — override or will be auto-generated
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Preflight checks --------------------------------------------------------
command -v cf  >/dev/null 2>&1 || error "CF CLI not found. Install from https://docs.cloudfoundry.org/cf-cli/install-go-cli.html"
command -v jq  >/dev/null 2>&1 || error "jq not found. Install with: brew install jq / apt install jq"

info "Checking CF login status..."
cf target >/dev/null 2>&1 || error "Not logged in to CF. Run: cf login -a <api-endpoint>"
success "CF login OK"
cf target

echo ""

# --- Step 1: Create AI Core service instance ---------------------------------
info "Checking for AI Core service instance: ${AICORE_INSTANCE}"
if cf service "${AICORE_INSTANCE}" >/dev/null 2>&1; then
    success "Service instance '${AICORE_INSTANCE}' already exists."
else
    info "Creating AI Core service instance..."
    info "  Service: ${AICORE_SERVICE_NAME}"
    info "  Plan:    ${AICORE_PLAN}"
    info "  Name:    ${AICORE_INSTANCE}"
    cf create-service "${AICORE_SERVICE_NAME}" "${AICORE_PLAN}" "${AICORE_INSTANCE}" \
        || error "Failed to create AI Core service instance. Check that '${AICORE_SERVICE_NAME}/${AICORE_PLAN}' is available in your space."
    success "AI Core service instance created."
    info "Waiting for service to be ready..."
    sleep 5
fi

# --- Step 2: Create service key ----------------------------------------------
info "Checking for service key: ${AICORE_KEY_NAME}"
if cf service-key "${AICORE_INSTANCE}" "${AICORE_KEY_NAME}" >/dev/null 2>&1; then
    success "Service key '${AICORE_KEY_NAME}' already exists."
else
    info "Creating service key..."
    cf create-service-key "${AICORE_INSTANCE}" "${AICORE_KEY_NAME}" \
        || error "Failed to create service key."
    success "Service key created."
fi

# --- Step 3: Extract credentials from service key ---------------------------
info "Extracting credentials from service key..."
SERVICE_KEY_JSON=$(cf service-key "${AICORE_INSTANCE}" "${AICORE_KEY_NAME}" | tail -n +2)

# Parse credentials
AICORE_CLIENT_ID=$(echo "${SERVICE_KEY_JSON}" | jq -r '.clientid // .credentials.clientid')
AICORE_CLIENT_SECRET=$(echo "${SERVICE_KEY_JSON}" | jq -r '.clientsecret // .credentials.clientsecret')
AICORE_AUTH_URL=$(echo "${SERVICE_KEY_JSON}" | jq -r '(.url // .credentials.url) + "/oauth/token"')
AICORE_BASE_URL=$(echo "${SERVICE_KEY_JSON}" | jq -r '.serviceurls.AI_API_URL // .credentials.serviceurls.AI_API_URL')

[[ -z "${AICORE_CLIENT_ID}"     ]] && error "Could not extract clientid from service key."
[[ -z "${AICORE_CLIENT_SECRET}" ]] && error "Could not extract clientsecret from service key."
[[ -z "${AICORE_AUTH_URL}"      ]] && error "Could not extract auth URL from service key."
[[ -z "${AICORE_BASE_URL}"      ]] && error "Could not extract AI_API_URL from service key."

success "Credentials extracted:"
info "  Auth URL:   ${AICORE_AUTH_URL}"
info "  Base URL:   ${AICORE_BASE_URL}"
info "  Client ID:  ${AICORE_CLIENT_ID:0:20}..."

# --- Step 4: Generate LiteLLM master key if not set --------------------------
if [[ -z "${LITELLM_MASTER_KEY}" ]]; then
    LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 48 | head -n 1)"
    warn "Generated LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY}"
    warn "Save this key — you'll need it to call the proxy admin API!"
fi

# --- Step 5: Fetch initial OAuth2 token for AI Core --------------------------
info "Fetching initial OAuth2 token from XSUAA..."
TOKEN_RESPONSE=$(curl -s -X POST "${AICORE_AUTH_URL}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -u "${AICORE_CLIENT_ID}:${AICORE_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" \
    2>/dev/null) || error "Failed to fetch OAuth2 token."

AICORE_OAUTH_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')
[[ -z "${AICORE_OAUTH_TOKEN}" ]] && error "Failed to extract access_token. Response: ${TOKEN_RESPONSE}"
success "OAuth2 token obtained."

# --- Step 6: Set environment variables on CF app ----------------------------
info "Setting environment variables on CF app: ${APP_NAME}"

cf set-env "${APP_NAME}" AICORE_BASE_URL        "${AICORE_BASE_URL}"
cf set-env "${APP_NAME}" AICORE_AUTH_URL        "${AICORE_AUTH_URL}"
cf set-env "${APP_NAME}" AICORE_CLIENT_ID       "${AICORE_CLIENT_ID}"
cf set-env "${APP_NAME}" AICORE_CLIENT_SECRET   "${AICORE_CLIENT_SECRET}"
cf set-env "${APP_NAME}" AICORE_RESOURCE_GROUP  "${AICORE_RESOURCE_GROUP}"
cf set-env "${APP_NAME}" AICORE_OAUTH_TOKEN     "Bearer ${AICORE_OAUTH_TOKEN}"
cf set-env "${APP_NAME}" LITELLM_MASTER_KEY     "${LITELLM_MASTER_KEY}"

success "Core environment variables set."

# --- Step 7: Set deployment API base URLs ------------------------------------
echo ""
info "=== AI Core Model Deployments ==="
info "You need to provide deployment IDs for each model you want to expose."
info "Find them in SAP AI Launchpad > ML Operations > Deployments"
info "Or via API: GET ${AICORE_BASE_URL}/v2/inference/deployments"
echo ""

set_deployment() {
    local env_var="$1"
    local model_name="$2"
    local api_base_var="$3"

    local deployment_id="${!env_var:-}"
    if [[ -n "${deployment_id}" ]]; then
        local api_base="${AICORE_BASE_URL}/v2/inference/deployments/${deployment_id}/v1"
        cf set-env "${APP_NAME}" "${api_base_var}" "${api_base}"
        success "${model_name}: ${api_base}"
    else
        warn "${model_name}: Skipped (set ${env_var} to configure)"
    fi
}

# Set deployment URLs for each model (read from caller's environment)
set_deployment "AICORE_GPT4O_DEPLOYMENT_ID"           "GPT-4o"              "AICORE_GPT4O_API_BASE"
set_deployment "AICORE_GPT4O_MINI_DEPLOYMENT_ID"      "GPT-4o Mini"         "AICORE_GPT4O_MINI_API_BASE"
set_deployment "AICORE_CLAUDE_35_SONNET_DEPLOYMENT_ID" "Claude 3.5 Sonnet"  "AICORE_CLAUDE_35_SONNET_API_BASE"
set_deployment "AICORE_CLAUDE_3_HAIKU_DEPLOYMENT_ID"  "Claude 3 Haiku"      "AICORE_CLAUDE_3_HAIKU_API_BASE"
set_deployment "AICORE_GEMINI_15_PRO_DEPLOYMENT_ID"   "Gemini 1.5 Pro"      "AICORE_GEMINI_15_PRO_API_BASE"
set_deployment "AICORE_MISTRAL_LARGE_DEPLOYMENT_ID"   "Mistral Large"       "AICORE_MISTRAL_LARGE_API_BASE"
set_deployment "AICORE_LLAMA_31_70B_DEPLOYMENT_ID"    "Llama 3.1 70B"       "AICORE_LLAMA_31_70B_API_BASE"
set_deployment "AICORE_TEXT_EMBEDDING_DEPLOYMENT_ID"  "Text Embedding Ada"  "AICORE_TEXT_EMBEDDING_API_BASE"

# --- Step 8: Restage the app -------------------------------------------------
echo ""
info "Restaging ${APP_NAME} to apply new environment..."
cf restage "${APP_NAME}"

success "Setup complete!"
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} LiteLLM SAP BTP Gateway is ready!${NC}"
echo ""
APP_URL=$(cf app "${APP_NAME}" | grep -E "routes:" | awk '{print $2}')
echo -e "  App URL:      https://${APP_URL}"
echo -e "  Health check: https://${APP_URL}/health/liveliness"
echo -e "  Models list:  https://${APP_URL}/v1/models"
echo ""
echo -e "  LiteLLM Master Key: ${LITELLM_MASTER_KEY}"
echo -e "  (Store this securely — needed for admin API calls)"
echo ""
echo -e "  Test call:"
echo -e "  curl https://${APP_URL}/v1/chat/completions \\"
echo -e "    -H 'Authorization: Bearer ${LITELLM_MASTER_KEY}' \\"
echo -e "    -H 'Content-Type: application/json' \\"
echo -e "    -d '{\"model\": \"gpt-4o\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
echo -e "${GREEN}============================================================${NC}"
