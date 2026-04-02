# =============================================================================
# LiteLLM SAP BTP Gateway - Dockerfile
# =============================================================================
# Builds a LiteLLM proxy container with the SAP AI Core OAuth2 helper script.
# Designed for deployment on SAP BTP Cloud Foundry via Docker image.
#
# Build: docker build -t litellm-sap-btp .
# Run:   docker run -p 8080:8080 --env-file .env litellm-sap-btp
# =============================================================================

FROM docker.litellm.ai/berriai/litellm:main-stable

LABEL maintainer="SAP BTP Team"
LABEL description="LiteLLM AI Gateway for SAP BTP with SAP AI Core integration"
LABEL version="1.0.0"

WORKDIR /app

# Copy LiteLLM configuration
COPY litellm_config.yaml /app/config.yaml

# Copy the SAP AI Core token helper (used for dynamic OAuth2 token injection)
COPY scripts/aicore_token_helper.py /app/aicore_token_helper.py

# SAP BTP Cloud Foundry uses PORT env var (default 8080)
# LiteLLM proxy listens on this port
ENV PORT=8080
ENV LITELLM_LOG=INFO

# Expose the application port
EXPOSE 8080

# Health check — CF uses this to validate app health
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-8080}/health/liveliness')" || exit 1

# Start LiteLLM proxy
# PORT is set by CF; config.yaml references env vars via os.environ/ syntax
CMD litellm --config /app/config.yaml --port ${PORT:-8080} --host 0.0.0.0
