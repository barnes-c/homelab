# Plan: consistent node names, three schedulable control planes

Status: plan only — nothing applied.

## Target

| Today         | New         | Board  | Role          | IP             |
| ------------- | ----------- | ------ | ------------- | -------------- |
| `rpi5b-cp-01` | `pi5-cp-01` | Pi 5   | control plane | `192.168.1.11` |
| `rpi4b-wk-01` | `pi4-cp-01` | Pi 4B  | control plane | `192.168.1.12` |
| `cm5-wk-01`   | `cm5-cp-01` | CM5    | control plane | `192.168.1.13` |
| `cm5-wk-02`   | `cm5-wk-01` | CM5    | worker        | `192.168.1.14` |

Scheme: `<board>-<role>-<nn>`, no `rpi` prefix. All control planes are schedulable
(`schedulable_patches` already strips the NoSchedule taint). Makefile targets
(`rpi5b-image`, schematics) name boards, not hosts, and stay as they are.

## Pitfalls this plan works around

1. **A key change in `var.nodes` resets the node.** `talos_machine_configuration_apply`
   has `on_destroy = { reset = true, graceful = false }`. Renaming `rpi5b-cp-01` without a
   `moved` block wipes the only control plane.
2. **The bootstrap node is picked by map order.** `local.control_plane_ips[0]` is the
   alphabetically first control plane. Today `rpi5b-cp-01`; after the change `cm5-cp-01`.
   That replaces `talos_machine_bootstrap` and `talos_cluster_kubeconfig`. Pin both to
   the Pi 5 explicitly before adding control planes.
3. **Talos can't turn a worker into a control plane in place.** The Pi 4B must be reset
   and reflashed.
4. **A rename is a new Kubernetes and Longhorn node.** The old `Node` stays behind as
   NotReady. Longhorn has no node rename. The `persistent` disk, and every
   single-replica volume on it, belongs to `rpi5b-cp-01`.
5. **etcd with 2 members is worse than with 1.** Losing either one stops it. Add the
   second and third control planes back to back.
6. **The Pi 4B's etcd would sit on the T7** (EPHEMERAL is there), and the T7 dropped off
   USB in homelab-issues#54. You chose this. If the T7 drops again, that etcd member dies.
   Quorum survives as long as the other two are up.

## Steps

### 0. Prerequisites

- [ ] Backups (homelab-issues#32): sealed-secrets keys, `talosctl -n 192.168.1.11 etcd snapshot`,
      tofu state, and anything on Longhorn `persistent` that can't be lost.
- [ ] `gmake rpi5b-image`, and worker images for `rpi4b` and `cm5`.
- [ ] Read the CM5 disk selectors in maintenance mode (`talosctl get disks --insecure`).
- [ ] Check free space: can a CM5's 256GB NVMe hold a second copy of every `persistent`
      volume (immich library + postgres)? Step 2 depends on it.

### 1. Onboard `cm5-wk-01` (192.168.1.14) as a worker

Low risk: a new node, no quorum change. Flash, add it to `var.nodes`, `tofu apply`.

### 2. Move the Pi 5 data off its node name

Choose one:

- **a) Second replica (if step 0 says it fits).** Temporarily tag the `cm5-wk-01` disk
  `persistent`, and raise the replica count to 2 on the affected volumes. Wait for them
  to rebuild. After the rename, the old Longhorn node drops out and the volumes run on
  the CM5 copy. Then let Longhorn rebuild on `pi5-cp-01`, and go back to 1 replica.
- **b) Downtime.** Scale immich/authentik/etc. to 0 and restore from backup after the
  rename. Only possible once #32 exists.

Unverified: whether Longhorn reuses the existing `/var/mnt/longhorn` data for a node with a
new name, or rejects the disk because its UUID belongs to the old node. Test this before
counting on it.

### 3. Rename the Pi 5 (while it is the only control plane)

- [ ] In `talos.tf`, pin `talos_machine_bootstrap` and `talos_cluster_kubeconfig` to
      `192.168.1.11` instead of `local.control_plane_ips[0]`.
- [ ] Rename the key in `var.nodes` and add:

  ```hcl
  moved {
    from = talos_machine_configuration_apply.node["rpi5b-cp-01"]
    to   = talos_machine_configuration_apply.node["pi5-cp-01"]
  }
  ```

- [ ] `tofu plan` must show an in-place update only, with no destroy. Apply.
- [ ] Update the hostname pins in `manifests/workloads/immich/values.yaml` (×2) and
      `postgres.yaml`.
- [ ] `kubectl delete node rpi5b-cp-01`. Remove the old Longhorn node.
- [ ] Check that etcd has one healthy member (`talosctl etcd members`). Its member name may
      still be the old hostname. That is cosmetic.

### 4. Reset the Pi 4B

- [ ] Drain `rpi4b-wk-01`. Its Longhorn data is `scratch` and can be lost.
- [ ] `talosctl reset --wipe-mode system-disk -n 192.168.1.12` and reflash the SD card.
- [ ] `kubectl delete node rpi4b-wk-01`. `tofu state rm 'talos_machine_configuration_apply.node["rpi4b-wk-01"]'`
      (so tofu does not try to reset it again).
- [ ] Add `pi4-cp-01` with `role = "controlplane"`. Keep its labels, annotations and
      selectors from today.

### 5. Add both new control planes together

- [ ] Flash `cm5-cp-01` (192.168.1.13).
- [ ] `tofu apply` with both `pi4-cp-01` and `cm5-cp-01`. etcd goes from 1 to 3 members.
- [ ] Check: `talosctl etcd members`, the VIP moves between nodes, and
      `kubectl get nodes` shows no NoSchedule taints.

### 6. Clean up

- [ ] Update the node table in `cluster/README.md`
      and the comment in `manifests/infrastructure/longhorn/values.yaml`.
- [ ] Rename issues/titles that use old hostnames (#47, #54), or note the new names in them.
- [ ] Optional: let all three control planes be talosconfig endpoints (already the case
      through `local.control_plane_ips`).
