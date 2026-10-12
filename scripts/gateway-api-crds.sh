#!/usr/bin/env bash
set -euo pipefail

# Checks that the vendored Gateway API CRDs match the version Cilium is built against.
# With older CRDs the Cilium operator disables its Gateway controller, and every HTTPS
# listener loses its certificate.
#
# Usage: scripts/gateway-api-crds.sh            check (CI)
#        scripts/gateway-api-crds.sh --update   download the required CRDs

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_TF="$ROOT/cluster/tofu/bootstrap/main.tf"
CRDS="$ROOT/cluster/tofu/bootstrap/gateway-api/experimental-install.yaml"

cilium=$(awk '/resource "helm_release" "cilium"/,/^}/' "$MAIN_TF" | sed -n 's/^ *version *= *"\(.*\)"$/\1/p')
[ -n "$cilium" ] || { echo "error: no Cilium version found in $MAIN_TF" >&2; exit 1; }

# Cilium's go.mod pins the Gateway API module it is built and tested against. Some releases
# pin a pre-release (1.19.4: v1.4.0-rc.2); its release counterpart is the requirement.
gomod=$(curl -fsSL "https://raw.githubusercontent.com/cilium/cilium/v${cilium}/go.mod" |
  awk '$1 == "sigs.k8s.io/gateway-api" { print $2 }')
required="${gomod%%-*}"
[[ "$required" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$required" != "v0.0.0" ] || {
  echo "error: cannot derive a Gateway API release from Cilium v${cilium} go.mod (got '${gomod}')" >&2
  exit 1
}

if [ "${1:-}" = "--update" ]; then
  curl -fsSL -o "$CRDS" \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${required}/experimental-install.yaml"
  echo "updated $CRDS to Gateway API ${required} (Cilium ${cilium})"
  exit 0
fi

vendored=$(sed -n 's|^ *gateway\.networking\.k8s\.io/bundle-version: *\(v[^ ]*\)$|\1|p' "$CRDS" | sort -u)
[ "$(echo "$vendored" | wc -l)" -eq 1 ] && [ -n "$vendored" ] || {
  echo "error: expected one bundle-version in $CRDS, got: $(echo "$vendored" | tr '\n' ' ')" >&2
  exit 1
}

# Same minor as Cilium's, and at least its patch: a newer minor is not known to work yet.
if [ "${vendored%.*}" != "${required%.*}" ] ||
  [ "$(printf '%s\n%s\n' "$required" "$vendored" | sort -V | head -1)" != "$required" ]; then
  echo "error: Cilium ${cilium} needs Gateway API ${required}, vendored CRDs are ${vendored}." >&2
  echo "       Run scripts/gateway-api-crds.sh --update and commit the result." >&2
  exit 1
fi

echo "ok: Gateway API ${vendored} matches Cilium ${cilium} (needs ${required})"
