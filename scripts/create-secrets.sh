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
    read -r -s -p "$prompt_text: " "${var?}"; echo
  else
    read -r -p "$prompt_text: " "${var?}"
  fi
}

echo "=== Generating random secrets ==="

IMMICH_DB_USER=$(rand32)
IMMICH_DB_PASS=$(rand32)
AUTHENTIK_DB_PASS=$(rand32)
AUTHENTIK_SECRET_KEY=$(rand32)
AUTHENTIK_BOOTSTRAP_PASSWORD=$(rand32)
GOATCOUNTER_ADMIN_PASSWORD=$(rand32)

echo "=== Prompting for external credentials ==="

prompt PORKBUN_API_KEY         "Porkbun API key (pk1_...)"
prompt PORKBUN_SECRET_API_KEY  "Porkbun secret API key (sk1_...)"
prompt SMTP_USER             "SMTP username (barnes-biz)" false
prompt SMTP_PASS             "SMTP password (barnes-biz)"
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

seal cert-manager porkbun-api-key \
  "$MANIFESTS/cert-manager/porkbun-api-key.yaml" \
  --from-literal=api-key="$PORKBUN_API_KEY" \
  --from-literal=secret-api-key="$PORKBUN_SECRET_API_KEY"

# Same keys, sealed again for the ddns namespace. SealedSecrets are namespace-scoped by
# default, so the ciphertext is not portable between namespaces.
seal ddns porkbun-api-key \
  "$MANIFESTS/ddns/porkbun-api-key.yaml" \
  --from-literal=api-key="$PORKBUN_API_KEY" \
  --from-literal=secret-api-key="$PORKBUN_SECRET_API_KEY"

seal barnes-biz smtp-credentials \
  "$MANIFESTS/barnes-biz/smtp-credentials.yaml" \
  --from-literal=SMTP_USER="$SMTP_USER" \
  --from-literal=SMTP_PASS="$SMTP_PASS"

seal authentik smtp-credentials \
  "$MANIFESTS/authentik/smtp-credentials.yaml" \
  --from-literal=AUTHENTIK_EMAIL__USERNAME="$SMTP_USER" \
  --from-literal=AUTHENTIK_EMAIL__PASSWORD="$SMTP_PASS"

seal blog-barnes-biz remark42-credentials \
  "$MANIFESTS/blog-barnes-biz/remark42-credentials.yaml" \
  --from-literal=SMTP_USERNAME="$SMTP_USER" \
  --from-literal=SMTP_PASSWORD="$SMTP_PASS"

seal blog-barnes-biz goatcounter-admin \
  "$MANIFESTS/blog-barnes-biz/goatcounter-admin.yaml" \
  --from-literal=password="$GOATCOUNTER_ADMIN_PASSWORD"

echo ""
echo "Done. Review the files, then commit and push."
echo ""
echo "=== Authentik akadmin bootstrap password (save this) ==="
echo "$AUTHENTIK_BOOTSTRAP_PASSWORD"
