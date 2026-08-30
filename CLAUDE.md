# homelab

Talos Linux cluster on Raspberry Pi hardware. See `README.md` for provisioning steps.

## Ownership

OpenTofu owns the cluster and the two things that must exist before GitOps can work (Cilium,
ArgoCD, `apps-root`). ArgoCD owns everything after. Nothing is owned by both.

- `apps/` — ArgoCD `Application` definitions. `apps-root` watches this directory.
- `manifests/` — the raw manifests those Applications point at.

## Talos images

Two build paths, and they must stay in sync on system extensions — both carry `iscsi-tools`
(Longhorn attaches over iSCSI) and `util-linux-tools`. Talos cannot add extensions after
provisioning.

```sh
gmake schematics images             # Pi 4B / CM5, via factory.talos.dev
gmake rpi5b-image rpi5b-installer   # Pi 5, built locally
```

**Workers** — `schematics/*.yaml` are POSTed to Image Factory, which returns an ID; the
image is then downloaded per `TALOS_VERSION`. The factory resolves extension versions itself.

**Pi 5** — a local imager build, because Image Factory can only layer onto a published
release (see #47). It builds `installer-base` + `imager` from `TALOS_SRC`
(`~/Code/siderolabs/talos`, branch `fix/no-cert-regen-on-ntp-spike-rc2`) and pushes them to
the local registry at `REGISTRY` (`192.168.1.18:5005`) under `talos/`. A profile has to pin
extension image refs by tag, unlike a schematic.

Two artifacts, not interchangeable:

|              Artifact               |                          Use                          |
| ----------------------------------- | ----------------------------------------------------- |
| `images/talos-rpi5b.raw.xz`         | bootable SD image, initial flash only                 |
| `$(REGISTRY)/talos/installer:<tag>` | `machine.install.image`, and every `talosctl upgrade` |

Gotchas:

- **`profiles/*.yaml` are generated** from the `.tmpl` files via `envsubst`. Edit the
  template; the generated file is overwritten and `gmake clean` deletes it.
- **Build the SD image *before* resetting a node.** `--wipe-mode system-disk` erases the
  bootloader and there is no PXE fallback.
- `check-clean` refuses to build on a dirty `TALOS_SRC` tree — `TALOS_TAG` comes from
  `git describe --dirty` and a `-dirty` tag is not reproducible. Untracked files are ignored.
- The imager build needs the real **docker** CLI with buildx (`DOCKER` is pinned to
  `/opt/homebrew/bin/docker`), not podman's alias. Running the imager and pushing use
  **podman** and **crane**, both with TLS verification off for the plaintext local registry.
- `INSTALLER_ARCH=targetarch` is required; the default `all` pulls `pkg-kernel-amd64`.

## Conventions

- **Sync waves** order deployment; see the table in `apps/README.md`. Storage-dependent apps
  go at wave 1.
- **HTTPRoutes live beside their app** (`manifests/immich/immich-route.yaml`,
  `manifests/monitoring/grafana-route.yaml`), not in `manifests/gateway/`. The instruction in
  `manifests/README.md` is out of date.
- **Two Gateways**: `main` (`192.168.1.201`, public) and `internal` (`192.168.1.202`, LAN-only
  — the Freebox forwards 80/443 to `.201` only). Admin surfaces attach to `internal`.
- **Secrets** are sealed by `scripts/create-secrets.sh`. SealedSecrets are namespace-scoped,
  so a value used in two namespaces is sealed twice (see the Cloudflare token).
- **`gmake`, not `make`** — macOS ships GNU Make 3.81; the Makefile needs 4.0+.

## Where decision context lives

Conclusion in the code, reasoning in the issue.

|                      Kind                       |                          Home                          |
| ----------------------------------------------- | ------------------------------------------------------ |
| Invariant — "this cannot work because…"         | One-line comment stating the conclusion, plus `See #N` |
| Temporal — "disabled until…", "re-enable when…" | Issue; one-line comment pointing to it                 |
| Dead or commented-out config                    | Issue only; delete it from the file                    |

A comment should state the fact, not just point — a bare `See #N` forces a round-trip to
find out whether you cared.

Anything that can be *closed* is an issue, not a comment. "Re-enable once a node is labelled"
in a YAML comment is invisible: it never appears in `gh issue list` and nothing can close it.

At the start of a task, check `gh issue list` and the project board for current state.

## Working in issues

Track progress in the issue itself, not only in commits. Comment as the work proceeds, so the
current state is visible without reading the diff.

When something turns out to be wrong, **add a comment saying what changed and why — do not
edit the earlier comment or rewrite the body to match**. A superseded assumption is part of
the record: erasing it means the next person re-derives the same dead end, and hides that the
conclusion moved at all. The body may carry current state (a checklist, the agreed approach);
the reasoning trail lives in comments and is append-only.
