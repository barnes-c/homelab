#!/usr/bin/env bash
set -euo pipefail

# Reports upstream state for things this homelab is waiting on, and comments on the
# tracking issue when the report changes. Run by .github/workflows/upstream-watch.yaml.
# Prerequisites: git, gh (GH_TOKEN), jq. DRY_RUN=1 prints the report without commenting.

ISSUE="${ISSUE:?set ISSUE to the tracking issue number}"
REPO="${GITHUB_REPOSITORY:-barnes-c/homelab}"
MARKER="<!-- upstream-watch -->"

# Tree-only shallow fetch: enough to test whether a path exists, without downloading blobs.
kernel_has() {
  local url="$1" ref="$2" path="$3" dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  if ! git -C "$dir" fetch -q --depth=1 --filter=blob:none "$url" "$ref"; then
    echo "fetch of $url $ref failed" >&2
    exit 1
  fi
  if git -C "$dir" cat-file -e "FETCH_HEAD:$path" 2>/dev/null; then
    echo "**present**"
  else
    echo "absent"
  fi
  rm -rf "$dir"
}

gh_file() {
  gh api -H "Accept: application/vnd.github.raw" "repos/$1/contents/$2?ref=$3"
}

KORG=https://git.kernel.org/pub/scm/linux/kernel/git
DRIVER=drivers/pwm/pwm-rp1.c

pwm_tree="$(kernel_has "$KORG/ukleinek/linux.git" pwm/for-next "$DRIVER")"
next="$(kernel_has "$KORG/next/linux-next.git" master "$DRIVER")"
mainline="$(kernel_has "$KORG/torvalds/linux.git" master "$DRIVER")"

pkgs_rp1="$(gh_file siderolabs/pkgs kernel/build/config-arm64 main | grep -iE '^CONFIG_PWM[A-Z_]*RP1=' || true)"
pkgs_kernel="$(gh_file siderolabs/pkgs Pkgfile main | awk '/linux_version:/ {print $2}')"

talos_pkgs="$(gh_file siderolabs/talos Makefile main | awk '/^PKGS \?=/ {print $3}')"
talos_kernel="$(gh_file siderolabs/pkgs Pkgfile "${talos_pkgs##*-g}" | awk '/linux_version:/ {print $2}')"
talos_release="$(gh release list -R siderolabs/talos --limit 1 --json tagName --jq '.[0].tagName')"

report="$(cat <<EOF
$MARKER
### Raspberry Pi 5 RP1 PWM (fan)

| Where | \`$DRIVER\` |
| ----- | ----------- |
| PWM tree \`pwm/for-next\` | $pwm_tree |
| linux-next | $next |
| mainline | $mainline |
| pkgs \`main\` arm64 config | ${pkgs_rp1:-absent} |

### Talos

| | |
| - | - |
| Latest release | \`$talos_release\` |
| Talos \`main\` kernel | \`$talos_kernel\` (pkgs \`$talos_pkgs\`) |
| pkgs \`main\` kernel | \`$pkgs_kernel\` |
EOF
)"

echo "$report"
[[ "${DRY_RUN:-}" == 1 ]] && exit 0

last="$(gh api "repos/$REPO/issues/$ISSUE/comments" --paginate --slurp |
  jq -r --arg m "$MARKER" '[.[][] | select(.body | startswith($m))] | last | .body // ""')"

if [[ "$last" == "$report" ]]; then
  echo "unchanged"
else
  gh issue comment "$ISSUE" -R "$REPO" --body "$report"
fi
