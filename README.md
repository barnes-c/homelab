# homelab

Talos Linux cluster on Raspberry Pi hardware, and everything running on it.

```txt
Makefile              tofu/talos            tofu/bootstrap        apps/
──────────            ──────────            ──────────────        ─────
Talos images    ──►   machine config  ──►   Cilium          ──►   apps-root Application
(factory +            bootstrap             ArgoCD                ArgoCD syncs apps/
 local build)         kubeconfig            apps-root
```

The split is deliberate: OpenTofu owns the cluster and the two things that must exist
before GitOps can work; ArgoCD owns everything after. Nothing is owned by both.

## Hardware

|    Node     |        Board         |       Role        |       IP       |                 Storage                  |
| ----------- | -------------------- | ----------------- | -------------- | ---------------------------------------- |
| —           | —                    | VIP (cluster API) | `192.168.1.10` | —                                        |
| rpi5b-cp-01 | Raspberry Pi 5 16GB  | Control plane     | `192.168.1.11` | SD (META+STATE) + 2× 2TB SATA SSD, RAID1 |
| rpi4b-wk-01 | Raspberry Pi 4B 8GB  | Worker            | `192.168.1.12` | SD + 500GB USB SSD                       |
| cm5-wk-01   | Raspberry Pi CM5 8GB | Worker            | `192.168.1.13` | 256GB NVMe                               |
| cm5-wk-02   | Raspberry Pi CM5 8GB | Worker            | `192.168.1.14` | 256GB NVMe                               |

## Step 1 — Images

Workers use stock Image Factory schematics. **There is deliberately no Pi 5 schematic** —
Image Factory can only layer extensions and overlay options onto a *published* Talos
release, and the Pi 5 needs `cb393a0d7` *"don't regenerate k8s certs on NTP spike status
changes"*, which is local-only and one commit past `v1.14.0-rc.2`. Without it the control
plane bounces roughly 1.2×/day. A schematic cannot express that, so the Pi 5 goes through
`profiles/` and a local imager instead.

Everything else the Pi 5 used to need — the macb EEE and TX-stall kernel patches, and the
DTB `msi-parent` fix that makes the SATA HAT work — landed upstream in `v1.14.0-rc.2` and
`sbc-raspberrypi` v0.2.1, so there is no custom kernel or overlay any more.

The two paths must stay in sync on system extensions. A schematic names them and lets the
factory resolve versions; a profile has to pin image refs. Both currently carry
`iscsi-tools` (Longhorn's v1 engine attaches volumes over iSCSI) and `util-linux-tools`
(`nsenter`, `fstrim`, `blkid`). Any node running Longhorn — replicas or just pods with a
Longhorn PVC — needs both, and Talos has no way to add them after the fact.

```sh
gmake schematics images                      # workers, via factory.talos.dev
gmake rpi5b-image rpi5b-installer            # Pi 5, built locally
```

`gmake`, not `make`: macOS ships GNU Make 3.81 and these need 4.0+.

The Pi 5 build reads `~/Code/siderolabs/talos` at branch
`fix/no-cert-regen-on-ntp-spike-rc2`. It refuses to run on a dirty tree, because the image
tag comes from `git describe` and a `-dirty` tag is not reproducible.

Two Pi 5 artifacts, and they are not interchangeable:

- `images/talos-rpi5b.raw.xz` — bootable SD image, initial flash only
- `installer:<tag>` pushed to the registry — what `machine.install.image` points at, and
  what every later `talosctl upgrade` uses

## Step 2 — Flash

```sh
xz -d images/talos-<node>.raw.xz
diskutil info /dev/diskN | grep -E "Disk Size|Media Name|Removable"   # verify EVERY time
diskutil unmountDisk /dev/diskN
sudo dd if=images/talos-<node>.raw of=/dev/rdiskN bs=4M
diskutil eject /dev/diskN
```

The device node moves between reboots and the cards swap places — match on size, never on
number. For the CM5s, hold **BOOT** on the NanoCluster adapter, connect USB-C, run
`sudo rpiboot`, and the eMMC/NVMe appears as mass storage.

A **steady-dark ACT LED means it never booted** — don't debug the network.

## Step 3 — Provision

```sh
cd tofu/talos
tofu init && tofu apply
tofu output -raw kubeconfig  > ~/.kube/config
tofu output -raw talosconfig > ~/.talos/config
```

Before the first apply, fill in the real disk selectors. They are CEL over Talos'
`DiskSpec`, and device names are not stable — pin by `wwid` when disks are identical:

```sh
talosctl -n 192.168.1.11 --insecure get disks
```

Two layout decisions are fixed at creation and **cannot be changed on a provisioned node**
(`machinery/config/types/block/volume_config.go`):

- `ETCD`/`CRI`/`KUBELET`/`LOG` are directories under `EPHEMERAL`, not dedicated
  partitions. On mirrored SSDs that isolation isn't worth a re-provision.
- `EPHEMERAL` lands on the SSD array, not the SD card, so etcd never touches SD. The SD
  keeps only `META` (1MB) and `STATE` (105MB).

## Re-provisioning an existing node

⚠ **`--wipe-mode system-disk` leaves these Pis unbootable.** The system disk *is* the boot
medium, so wiping it erases the bootloader, and there is no PXE fallback — the node goes
dark and needs a reflash. That is survivable, but only if the image already exists:

```sh
gmake rpi5b-image        # BEFORE the reset, not after
talosctl reset --graceful=false --reboot --wipe-mode system-disk -n <ip>
# node will NOT return on its own -- reflash per Step 2, then Step 3
```

`--graceful=false` is required on a single control-plane node; a graceful reset tries to
leave etcd and hangs with one member.

**Never use `--wipe-mode all` or `user-disks` on rpi5b-cp-01.** Both reach `sda`/`sdb` and
destroy the mdadm superblocks. Talos discovers mdraid arrays but has no controller that
creates them, and ships no `mdadm`, so `md127` would have to be rebuilt from a rescue
environment. `system-disk` leaves the array untouched.

To re-provision while keeping the mirror: reset `system-disk`, reflash, then clear the
array's partition table separately. Wiping `md127` does not destroy the array — the
superblocks live on `sda`/`sdb`, outside the md data area.

## Step 4 — Bootstrap

```sh
cd tofu/bootstrap
tofu init && tofu apply
```

Installs Cilium, then ArgoCD, then the `apps-root` Application. ArgoCD takes over.

Cilium is **not** an ArgoCD Application. ArgoCD runs on the network Cilium provides, so a
selfHeal loop on the CNI can cut ArgoCD's own connectivity and leave nothing able to
repair it. Upgrade Cilium by bumping `cilium_version` and re-applying.

## Layout

```txt
Makefile              image builds
schematics/           Image Factory schematics (workers)
profiles/             imager profiles (Pi 5) — *.tmpl, rendered by the Makefile
tofu/talos/           machine config, bootstrap, kubeconfig
tofu/bootstrap/       Cilium, ArgoCD, apps-root
apps/                 ArgoCD Applications
manifests/            raw manifests referenced by those Applications
```

## Notes

- **The Talos provider must match the cluster's minor version.** Talos v1.14 decomposed
  `v1alpha1` into standalone documents (`UnattendedInstallConfig`, `HostnameConfig`,
  `KubeletConfig`, `ResolverConfig`, `KubeNodeConfig`, ...). Provider `0.11.0` bundles
  machinery `v1.13.0` and rejects them with `"UnattendedInstallConfig" "v1alpha1": not
  registered`; `0.12.0-beta.0` bundles `v1.14.0-rc.2`. Setting a field in both v1alpha1 and
  its document fails validation with `X is already set in v1alpha1 config`, so
  `tofu/talos/main.tf` deliberately keeps only what has no document equivalent.
- **The OpenTofu registry cannot install `0.12.0-beta.0`** — it fails with
  `authentication signature from unknown issuer`. Install it as a filesystem mirror:

  ```sh
  V=0.12.0-beta.0
  DIR=~/.terraform.d/plugins/registry.opentofu.org/siderolabs/talos/$V/darwin_arm64
  mkdir -p "$DIR"
  curl -fL "https://github.com/siderolabs/terraform-provider-talos/releases/download/v$V/terraform-provider-talos_${V}_darwin_arm64.zip" -o /tmp/p.zip
  unzip -o /tmp/p.zip -d "$DIR"
  ```

- **Validate patches before applying.** A bad patch costs a failed apply and a round trip:

  ```sh
  tofu -chdir=tofu/talos plan -out=/tmp/p.bin
  tofu -chdir=tofu/talos show -json /tmp/p.bin \
    | jq -r '.planned_values.root_module.resources[]
             | select(.type=="talos_machine_configuration_apply")
             | .values.config_patches | to_entries[] | "\(.key)\t\(.value|@base64)"'
  # write each entry to its own file -- concatenating them silently drops all but the
  # first document -- then: talosctl machineconfig patch <cfg> --patch @f && talosctl validate
  ```

- `talosctl` must match the cluster's minor version to parse machine config. A v1.13
  client fails with `error decoding document v1alpha1/DiscoveryServiceConfig/default:
  not registered`. A matching client lives at `~/Code/siderolabs/talosctl-rc2`.
- The local registry `192.168.1.18:5005` is the Mac. Nodes cannot pull the Pi 5 installer
  while it is off, which blocks upgrades but not running workloads. Moving the installer
  to `ghcr.io/barnes-c` (private, with `machine.registries.config` credentials) would
  remove that dependency.
- Useful: `talosctl get volumestatus` (where volumes actually landed),
  `talosctl read /proc/mdstat` (RAID health), `talosctl wipe disk|md` (before re-provision).
