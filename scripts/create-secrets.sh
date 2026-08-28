#!/usr/bin/env bash
set -euo pipefail

# Generates and seals all cluster secrets.
# Prerequisites: kubectl, kubeseal (connected to cluster)

MANIFESTS="$(cd "$(dirname "$0")/../manifests" && pwd)"

rand32() {
  openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32
}

seal() {
  local namespace="$1"
  local name="$2"
  local outfile="$3"
  shift 3
  kubectl create secret generic "$name" \
    --namespace "$namespace" \
    --dry-run=client -o yaml \
    "$@" \
    | kubeseal --format yaml \
    --controller-namespace sealed-secrets \
    > "$outfile"
  echo "  -> $outfile"
}


prompt() {
  local var="$1"
  local prompt_text="$2"
  local silent="${3:-true}"
  if [[ "$silent" == "true" ]]; then
    read -r -s -p "$prompt_text: " "$var"; echo
  else
    read -r -p "$prompt_text: " "$var"
  fi
}

echo "=== Generating random secrets ==="

IMMICH_DB_USER=$(rand32)
IMMICH_DB_PASS=$(rand32)
AUTHENTIK_DB_PASS=$(rand32)
AUTHENTIK_SECRET_KEY=$(rand32)
AUTHENTIK_BOOTSTRAP_PASSWORD=$(rand32)
ARGOCD_CLIENT_ID=$(rand32)
ARGOCD_CLIENT_SECRET=$(rand32)
GRAFANA_CLIENT_ID=$(rand32)
GRAFANA_CLIENT_SECRET=$(rand32)
IMMICH_CLIENT_ID=$(rand32)
IMMICH_CLIENT_SECRET=$(rand32)

echo "=== Prompting for external credentials ==="

prompt CF_API_TOKEN        "Cloudflare API token (cert-manager)"
prompt SMTP_USER             "SMTP username (barnes-biz)" false
prompt SMTP_PASS             "SMTP password (barnes-biz)"
prompt STRAVA_CLIENT_SECRET   "Strava client secret (account 115101)"
prompt STRAVA_REFRESH_TOKEN   "Strava refresh token (account 115101)"
prompt STRAVA2_CLIENT_SECRET  "Strava client secret (account 196370)"
prompt STRAVA2_REFRESH_TOKEN  "Strava refresh token (account 196370)"

echo ""
echo "=== Sealing secrets ==="


seal immich immich-postgres-credentials \
  "$MANIFESTS/immich/immich-postgres-credentials.yaml" \
  --from-literal=DB_USERNAME="$IMMICH_DB_USER" \
  --from-literal=DB_PASSWORD="$IMMICH_DB_PASS"

seal authentik authentik-credentials \
  "$MANIFESTS/authentik/authentik-credentials.yaml" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$AUTHENTIK_DB_PASS" \
  --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$AUTHENTIK_BOOTSTRAP_PASSWORD"

seal authentik authentik-oidc-clients \
  "$MANIFESTS/authentik/authentik-oidc-clients.yaml" \
  --from-literal=ARGOCD_CLIENT_ID="$ARGOCD_CLIENT_ID" \
  --from-literal=ARGOCD_CLIENT_SECRET="$ARGOCD_CLIENT_SECRET" \
  --from-literal=GRAFANA_CLIENT_ID="$GRAFANA_CLIENT_ID" \
  --from-literal=GRAFANA_CLIENT_SECRET="$GRAFANA_CLIENT_SECRET" \
  --from-literal=IMMICH_CLIENT_ID="$IMMICH_CLIENT_ID" \
  --from-literal=IMMICH_CLIENT_SECRET="$IMMICH_CLIENT_SECRET"

_immich_config_tmp=$(mktemp)
cat > "$_immich_config_tmp" <<EOF
{
  "oauth": {
    "enabled": true,
    "issuerUrl": "https://authentik.barnes.biz/application/o/immich/",
    "clientId": "$IMMICH_CLIENT_ID",
    "clientSecret": "$IMMICH_CLIENT_SECRET",
    "callbackUrl": "https://img.barnes.biz/auth/login",
    "scope": "openid email profile",
    "signingAlgorithm": "RS256",
    "storageLabelClaim": "preferred_username",
    "buttonText": "Login with Authentik",
    "autoRegister": true,
    "autoLaunch": false,
    "mobileOverrideEnabled": false,
    "mobileRedirectUri": ""
  },
  "passwordLogin": {
    "enabled": true
  },
  "machineLearning": {
    "enabled": false
  },
  "server": {
    "externalDomain": "https://img.barnes.biz",
    "loginPageMessage": ""
  },
  "storageTemplate": {
    "enabled": true,
    "template": "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}"
  }
}
EOF
kubectl create secret generic immich-config \
  --namespace immich \
  --dry-run=client -o yaml \
  --from-file=immich.json="$_immich_config_tmp" \
  | kubeseal --format yaml \
    --controller-namespace sealed-secrets \
  > "$MANIFESTS/immich/immich-config.yaml"
rm "$_immich_config_tmp"
echo "  -> $MANIFESTS/immich/immich-config.yaml"

seal cert-manager cloudflare-api-token \
  "$MANIFESTS/cert-manager/cloudflare-api-token.yaml" \
  --from-literal=api-token="$CF_API_TOKEN"

# Same token, sealed again for the ddns namespace. SealedSecrets are namespace-scoped by
# default, so the ciphertext is not portable between namespaces.
seal ddns cloudflare-api-token \
  "$MANIFESTS/ddns/cloudflare-api-token.yaml" \
  --from-literal=api-token="$CF_API_TOKEN"




seal barnes-biz smtp-credentials \
  "$MANIFESTS/barnes-biz/smtp-credentials.yaml" \
  --from-literal=SMTP_USER="$SMTP_USER" \
  --from-literal=SMTP_PASS="$SMTP_PASS"

seal authentik smtp-credentials \
  "$MANIFESTS/authentik/smtp-credentials.yaml" \
  --from-literal=AUTHENTIK_EMAIL__USERNAME="$SMTP_USER" \
  --from-literal=AUTHENTIK_EMAIL__PASSWORD="$SMTP_PASS"

seal monitoring grafana-oidc \
  "$MANIFESTS/monitoring/grafana-oidc.yaml" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID="$GRAFANA_CLIENT_ID" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="$GRAFANA_CLIENT_SECRET"

seal argocd argocd-oidc \
  "$MANIFESTS/argocd/argocd-oidc.yaml" \
  --from-literal=dex.authentik.clientID="$ARGOCD_CLIENT_ID" \
  --from-literal=dex.authentik.clientSecret="$ARGOCD_CLIENT_SECRET"
# ArgoCD requires this label to read the secret from dex.config
python3 - "$MANIFESTS/argocd/argocd-oidc.yaml" <<'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
if 'app.kubernetes.io/part-of: argocd' not in content:
    content = re.sub(
        r'(  template:\n    metadata:\n      name: argocd-oidc\n      namespace: argocd\n)',
        r'\1      labels:\n        app.kubernetes.io/part-of: argocd\n',
        content
    )
    open(path, 'w').write(content)
PYEOF

echo ""
echo "Done. Review the files, then commit and push."
echo ""
echo "=== Authentik akadmin bootstrap password (save this) ==="
echo "$AUTHENTIK_BOOTSTRAP_PASSWORD"
