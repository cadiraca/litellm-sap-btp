#!/usr/bin/env bash
# =============================================================================
# deploy.sh
# =============================================================================
# Full deployment automation for LiteLLM SAP BTP Gateway.
# Builds the Docker image, pushes to a registry, then deploys to CF.
#
# Usage:
#   export DOCKER_REGISTRY=ghcr.io/your-org
#   export DOCKER_USERNAME=your-username
#   export DOCKER_TOKEN=your-token
#   ./scripts/deploy.sh [--build] [--push] [--cf-push] [--all]
#
# Flags:
#   --build    Build the Docker image locally
#   --push     Push the image to the registry
#   --cf-push  Deploy to Cloud Foundry (cf push)
#   --all      Do all of the above (default if no flags given)
#
# Prerequisites:
#   - Docker installed and running
#   - CF CLI installed and logged in
#   - .env file with required variables (or env vars already exported)
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
APP_NAME="${APP_NAME:-litellm-sap-btp}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/your-org}"
IMAGE_NAME="${IMAGE_NAME:-litellm-sap-btp}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Parse flags -------------------------------------------------------------
DO_BUILD=false
DO_PUSH=false
DO_CF_PUSH=false

if [[ $# -eq 0 ]]; then
    DO_BUILD=true; DO_PUSH=true; DO_CF_PUSH=true
fi

for arg in "$@"; do
    case "$arg" in
        --build)   DO_BUILD=true ;;
        --push)    DO_PUSH=true ;;
        --cf-push) DO_CF_PUSH=true ;;
        --all)     DO_BUILD=true; DO_PUSH=true; DO_CF_PUSH=true ;;
        --help|-h)
            echo "Usage: $0 [--build] [--push] [--cf-push] [--all]"
            exit 0
            ;;
        *)
            warn "Unknown flag: $arg"
            ;;
    esac
done

# --- Preflight ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

info "Repository root: ${REPO_ROOT}"
info "Docker image:    ${FULL_IMAGE}"
info "CF app name:     ${APP_NAME}"
echo ""

# Load .env if present (but don't override existing env vars)
if [[ -f ".env" ]]; then
    info "Loading .env file..."
    # shellcheck disable=SC2046
    export $(grep -v '^#' .env | grep -v '^$' | xargs -d '\n') 2>/dev/null || true
fi

# --- Step 1: Build Docker image ----------------------------------------------
if [[ "${DO_BUILD}" == "true" ]]; then
    info "Building Docker image: ${FULL_IMAGE}"
    command -v docker >/dev/null 2>&1 || error "Docker not found."

    docker build \
        --platform linux/amd64 \
        --tag "${FULL_IMAGE}" \
        --label "build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --label "build.commit=$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
        .

    success "Docker image built: ${FULL_IMAGE}"
fi

# --- Step 2: Push to registry ------------------------------------------------
if [[ "${DO_PUSH}" == "true" ]]; then
    info "Pushing Docker image to registry..."

    if [[ -n "${DOCKER_TOKEN:-}" && -n "${DOCKER_USERNAME:-}" ]]; then
        info "Logging in to registry: ${DOCKER_REGISTRY%%/*}"
        echo "${DOCKER_TOKEN}" | docker login "${DOCKER_REGISTRY%%/*}" \
            -u "${DOCKER_USERNAME}" --password-stdin
    else
        warn "DOCKER_TOKEN/DOCKER_USERNAME not set — assuming already logged in."
    fi

    docker push "${FULL_IMAGE}"
    success "Image pushed: ${FULL_IMAGE}"
fi

# --- Step 3: Update manifest.yml with image ----------------------------------
if [[ "${DO_CF_PUSH}" == "true" ]]; then
    command -v cf >/dev/null 2>&1 || error "CF CLI not found."
    cf target >/dev/null 2>&1 || error "Not logged in to CF. Run: cf login"

    # Patch the docker image in manifest.yml if DOCKER_REGISTRY is set
    if [[ "${DOCKER_REGISTRY}" != "ghcr.io/your-org" ]]; then
        info "Patching manifest.yml with image: ${FULL_IMAGE}"
        # Use sed to update the image line in manifest.yml
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s|image: .*|image: ${FULL_IMAGE}|" manifest.yml
        else
            sed -i "s|image: .*|image: ${FULL_IMAGE}|" manifest.yml
        fi
        success "manifest.yml updated."
    fi

    info "Deploying to Cloud Foundry..."
    cf push

    success "Deployment complete!"

    APP_URL=$(cf app "${APP_NAME}" 2>/dev/null | grep -E "routes:" | awk '{print $2}' || echo "unknown")
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN} Deployed: ${APP_NAME}${NC}"
    echo -e "  URL: https://${APP_URL}"
    echo -e ""
    echo -e "  Next step — inject AI Core credentials:"
    echo -e "  ./scripts/setup-ai-core.sh"
    echo -e "${GREEN}============================================================${NC}"
fi
