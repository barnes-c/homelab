# homelab

Talos Linux cluster on Raspberry Pi hardware. Provisioning steps: `README.md`.

## Ownership

OpenTofu (`cluster/tofu/`) owns the cluster, Cilium and `apps-root`. It installs ArgoCD once;
after that `apps/infrastructure/argocd.yaml` manages it (`helm_release.argocd` ignores value and
version changes). ArgoCD owns everything else. Nothing is owned by both.

- `apps/{infrastructure,workloads}/` — ArgoCD `Application`s; `apps/projects/` — `AppProject`s.
  `apps-root` watches `apps/` recursively.
- `manifests/{infrastructure,workloads}/<app>/` — what those Applications point at.

## Talos images

Both build paths must carry the same extensions (`iscsi-tools` for Longhorn, `util-linux-tools`);
Talos cannot add extensions after provisioning.

- **Pi 4B / CM5** — Image Factory. `cluster/tofu/schematics/*.yaml`, picked per node by name in
  `var.nodes`. `tf output disk_images` gives SD image URLs. A schematic change only changes
  `machine.install.image`; the node picks it up at its next `talosctl upgrade`.
- **Pi 5** — local imager build (`cluster/Makefile`: `gmake pi5-image pi5-installer`), because it
  needs a custom kernel with the RP1 PWM fan driver (barnes-c/homelab-issues#8). Built from
  `~/Code/siderolabs/talos` and the kernel from `~/Code/siderolabs/pkgs` (branch
  `feat/pwm-rp1-fan-*`). Profiles pin extension images by tag.

`images/talos-pi5.raw.xz` is for the initial SD flash only; `ghcr.io/barnes-c/talos/installer:<tag>`
is for `machine.install.image` and every upgrade.

Gotchas:

- Push Pi 5 images to ghcr.io only — never a local registry (barnes-c/homelab-issues#66). The
  ghcr packages must be public; flip new ones in package settings.
- `profiles/*.yaml` are generated from `.tmpl` via `envsubst`. Edit the template.
- Build the SD image *before* resetting a node: `--wipe-mode system-disk` erases the bootloader.
- `check-clean` refuses a dirty `TALOS_SRC` (untracked files are fine).
- Imager build needs real docker + buildx (`/opt/homebrew/bin/docker`); run/push use podman and
  crane. ghcr login needs a classic PAT with `write:packages`, always passed via
  `--password-stdin` — otherwise crane writes an empty password and pushes fail with `DENIED`.
- `INSTALLER_ARCH=targetarch` is required (`all` pulls the amd64 kernel).
- Kernel build needs ≥ 45 GB free in the podman VM (`podman machine ssh -- df -h /`); it fails
  only at the final copy after ~40 min. Prune BuildKit cache via `buildx_buildkit_local0 buildctl`.
- Upgrade the Pi 5 with `talosctl upgrade --reboot-mode powercycle`; kexec hangs it
  (barnes-c/homelab-issues#47).

## Conventions

- **Sync waves**: -3 AppProjects; -2 storage/CSR (longhorn, snapshot-controller,
  kubelet-csr-approver); -1 platform (cert-manager, external-secrets, sealed-secrets, gateway,
  policies); 0 other infrastructure; 1 workloads and anything needing storage.
- **Finalizers**: every app gets `resources-finalizer.argocd.argoproj.io`, except `argocd`,
  `longhorn`, `cert-manager`, `external-secrets`, `sealed-secrets`, `gateway`. The `longhorn`
  StorageClass is `Retain`; `longhorn-scratch` is `Delete`.
- **Helm values** live in `manifests/<group>/<app>/values.yaml` via a `$values` source (multi-chart
  apps: `<app>/<chart>/values.yaml`). If the app also syncs that directory, add
  `directory.exclude: values.yaml`.
- **HTTPRoutes** live beside their app (`<app>-route.yaml`), not in `gateway/`.
- **Gateways**: `main` (`192.168.1.201`, public) and `internal` (`192.168.1.202`, LAN-only).
  Admin surfaces attach to `internal`.
- **Secrets** are sealed by `scripts/create-secrets.sh`; SealedSecrets are namespace-scoped, so a
  value used in two namespaces is sealed twice.
- **DNS is Porkbun** (ACME DNS-01 webhook + ddns CronJob), not Cloudflare.
- **`gmake`, not `make`** — the Makefile needs GNU Make 4+.

## Agent access (read-only, LAN-only)

- **Kubernetes** — ServiceAccount `agent-access/claude` (`view` + `agent-readonly`; no Secrets,
  exec or writes — keep it that way). The environment already points kubectl at it: run plain
  `kubectl`, unsandboxed. To rotate the kubeconfig (admin needed), rebuild
  `~/.config/homelab/agent.kubeconfig` from Secret `agent-access/claude-token` (`ca.crt`, `token`),
  server `https://192.168.1.10:6443`; deleting the Secret revokes the old token.
- **Talos** — `os:reader` client cert pinned by `TALOSCONFIG` in user settings. Never override it
  or read `~/.talos`. Certs can't be revoked, so keep the TTL short:
  `talosctl config new --roles os:reader --crt-ttl 720h ~/.config/homelab/agent.talosconfig`.
- **Grafana** — `grafana` MCP server (`.mcp.json`), service account `Claude` (Editor), token from
  `GRAFANA_SERVICE_ACCOUNT_TOKEN` in the environment, never in this repo. Dashboards in git are
  the source of truth: hand-built ones in `barnes-c/dashboard-as-code`, gnetId ones in
  `values.yaml`. UI edits to provisioned dashboards are lost on restart.

## Decision context

Conclusion in the code, reasoning in the issue. Issues live in the **private**
`barnes-c/homelab-issues` (this repo is public); check `gh issue list -R barnes-c/homelab-issues`
at the start of a task.

- Invariant ("can't work because…") → one-line comment stating the fact, plus `See #N`.
- Temporal ("disabled until…") or anything closable → issue, with a one-line pointer comment.
- Dead or commented-out config → issue only; delete it from the file.

Comment on the issue as work proceeds. Comments are append-only: when something turns out wrong,
add a comment saying what changed and why — don't edit earlier comments. The body may hold
current state.
