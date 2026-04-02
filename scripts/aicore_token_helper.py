#!/usr/bin/env python3
"""
SAP AI Core OAuth2 Token Helper
================================
Fetches a fresh OAuth2 Bearer token from SAP XSUAA and writes it to the
AICORE_OAUTH_TOKEN environment variable file that LiteLLM reads on startup.

Usage (standalone):
    python3 aicore_token_helper.py

Usage (as a pre-start hook in Cloud Foundry):
    Add to Dockerfile CMD or a shell wrapper that sources the token before
    starting LiteLLM. See docs/SETUP.md for the full pattern.

Environment Variables Required:
    AICORE_AUTH_URL      - Full OAuth2 token URL
                           e.g. https://subdomain.authentication.us10.hana.ondemand.com/oauth/token
    AICORE_CLIENT_ID     - OAuth2 client ID from AI Core service key
    AICORE_CLIENT_SECRET - OAuth2 client secret from AI Core service key
    AICORE_BASE_URL      - AI Core API base URL
                           e.g. https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com

Output:
    Prints the Bearer token to stdout (for shell eval or piping).
    Writes deployment API base URLs to /tmp/aicore_env.sh (sourced by entrypoint).

SAP AI Core Inference URL Pattern:
    {AICORE_BASE_URL}/v2/inference/deployments/{deployment_id}/v1
"""

import json
import os
import sys
import urllib.request
import urllib.parse
import urllib.error
import base64
import time


def get_oauth_token(auth_url: str, client_id: str, client_secret: str) -> dict:
    """
    Fetch an OAuth2 client credentials token from SAP XSUAA.

    Returns:
        dict with keys: access_token, token_type, expires_in
    """
    credentials = base64.b64encode(
        f"{client_id}:{client_secret}".encode("utf-8")
    ).decode("utf-8")

    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
    }).encode("utf-8")

    req = urllib.request.Request(
        url=auth_url,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Basic {credentials}",
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"[aicore_token_helper] ERROR: HTTP {e.code} from XSUAA: {body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"[aicore_token_helper] ERROR: Cannot reach XSUAA: {e.reason}", file=sys.stderr)
        sys.exit(1)


def build_deployment_api_base(base_url: str, deployment_id: str) -> str:
    """
    Build the full SAP AI Core inference API base URL for a deployment.

    Pattern: {base_url}/v2/inference/deployments/{deployment_id}/v1
    """
    base_url = base_url.rstrip("/")
    return f"{base_url}/v2/inference/deployments/{deployment_id}/v1"


def parse_vcap_services() -> dict:
    """
    Parse VCAP_SERVICES to extract AI Core credentials if bound as a service.
    Supports both 'aicore' and 'sap-aicore' service names.

    Returns dict with keys: auth_url, client_id, client_secret, base_url
    or empty dict if not found.
    """
    vcap_raw = os.environ.get("VCAP_SERVICES", "")
    if not vcap_raw:
        return {}

    try:
        vcap = json.loads(vcap_raw)
    except json.JSONDecodeError:
        return {}

    # Try both common service names
    for service_name in ("aicore", "sap-aicore", "ai-core"):
        instances = vcap.get(service_name, [])
        if instances:
            creds = instances[0].get("credentials", {})
            service_urls = creds.get("serviceurls", creds.get("service_urls", {}))
            return {
                "auth_url": creds.get("url", "") + "/oauth/token",
                "client_id": creds.get("clientid", ""),
                "client_secret": creds.get("clientsecret", ""),
                "base_url": service_urls.get("AI_API_URL", ""),
            }

    return {}


def main():
    print("[aicore_token_helper] Starting SAP AI Core OAuth2 token refresh...", file=sys.stderr)

    # Try VCAP_SERVICES first (CF service binding), fall back to env vars
    vcap_creds = parse_vcap_services()

    auth_url = vcap_creds.get("auth_url") or os.environ.get("AICORE_AUTH_URL", "")
    client_id = vcap_creds.get("client_id") or os.environ.get("AICORE_CLIENT_ID", "")
    client_secret = vcap_creds.get("client_secret") or os.environ.get("AICORE_CLIENT_SECRET", "")
    base_url = vcap_creds.get("base_url") or os.environ.get("AICORE_BASE_URL", "")

    if not all([auth_url, client_id, client_secret, base_url]):
        print(
            "[aicore_token_helper] ERROR: Missing required credentials.\n"
            "  Set AICORE_AUTH_URL, AICORE_CLIENT_ID, AICORE_CLIENT_SECRET, AICORE_BASE_URL\n"
            "  or bind an AI Core service instance.",
            file=sys.stderr
        )
        sys.exit(1)

    # Fetch the token
    print(f"[aicore_token_helper] Fetching token from: {auth_url}", file=sys.stderr)
    token_data = get_oauth_token(auth_url, client_id, client_secret)
    access_token = token_data.get("access_token", "")
    expires_in = token_data.get("expires_in", 3600)

    if not access_token:
        print("[aicore_token_helper] ERROR: Empty access_token in response.", file=sys.stderr)
        sys.exit(1)

    expires_at = int(time.time()) + expires_in
    print(
        f"[aicore_token_helper] Token obtained. Expires in {expires_in}s "
        f"(at {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(expires_at))})",
        file=sys.stderr
    )

    # Build deployment API base URLs from deployment IDs
    deployment_env_vars = {
        "AICORE_GPT4O_DEPLOYMENT_ID": "AICORE_GPT4O_API_BASE",
        "AICORE_GPT4O_MINI_DEPLOYMENT_ID": "AICORE_GPT4O_MINI_API_BASE",
        "AICORE_CLAUDE_35_SONNET_DEPLOYMENT_ID": "AICORE_CLAUDE_35_SONNET_API_BASE",
        "AICORE_CLAUDE_3_HAIKU_DEPLOYMENT_ID": "AICORE_CLAUDE_3_HAIKU_API_BASE",
        "AICORE_GEMINI_15_PRO_DEPLOYMENT_ID": "AICORE_GEMINI_15_PRO_API_BASE",
        "AICORE_MISTRAL_LARGE_DEPLOYMENT_ID": "AICORE_MISTRAL_LARGE_API_BASE",
        "AICORE_LLAMA_31_70B_DEPLOYMENT_ID": "AICORE_LLAMA_31_70B_API_BASE",
        "AICORE_TEXT_EMBEDDING_DEPLOYMENT_ID": "AICORE_TEXT_EMBEDDING_API_BASE",
    }

    env_exports = [f"export AICORE_OAUTH_TOKEN='Bearer {access_token}'"]
    env_exports.append(f"export AICORE_BASE_URL='{base_url}'")
    env_exports.append(f"export AICORE_AUTH_URL='{auth_url}'")
    env_exports.append(f"export AICORE_CLIENT_ID='{client_id}'")

    for id_var, base_var in deployment_env_vars.items():
        deployment_id = os.environ.get(id_var, "")
        if deployment_id:
            api_base = build_deployment_api_base(base_url, deployment_id)
            env_exports.append(f"export {base_var}='{api_base}'")
            print(f"[aicore_token_helper] {base_var} = {api_base}", file=sys.stderr)
        else:
            # Check if already set as direct URL
            existing = os.environ.get(base_var, "")
            if existing:
                env_exports.append(f"export {base_var}='{existing}'")
                print(f"[aicore_token_helper] {base_var} = {existing} (from env)", file=sys.stderr)

    # Write to /tmp/aicore_env.sh for sourcing by entrypoint
    env_script = "\n".join(env_exports) + "\n"
    env_file = "/tmp/aicore_env.sh"
    with open(env_file, "w") as f:
        f.write("#!/bin/sh\n# Auto-generated by aicore_token_helper.py\n")
        f.write(env_script)
    os.chmod(env_file, 0o600)

    print(f"[aicore_token_helper] Environment written to {env_file}", file=sys.stderr)
    print(f"[aicore_token_helper] Done. Source with: . {env_file}", file=sys.stderr)

    # Also print the token to stdout for shell capture
    print(f"Bearer {access_token}")


if __name__ == "__main__":
    main()
