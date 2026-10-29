# cluster

Talos images and the OpenTofu root that provisions the cluster.

|   Node    |        Board         |     Role      |       IP       |
| --------- | -------------------- | ------------- | -------------- |
| —         | —                    | VIP           | `192.168.1.10` |
| pi5-cp-01 | Raspberry Pi 5 16GB  | Control plane | `192.168.1.11` |
| pi4-cp-01 | Raspberry Pi 4B 8GB  | Control plane | `192.168.1.12` |
| cm5-cp-01 | Raspberry Pi CM5 8GB | Control plane | `192.168.1.13` |
| cm5-wk-01 | Raspberry Pi CM5 8GB | Worker        | `192.168.1.14` |

All control planes are schedulable.

## 1. Build images

```sh
gmake schematics images             # Pi 4B / CM5, via factory.talos.dev
gmake rpi5b-image rpi5b-installer   # Pi 5, built locally
```

## 2. Flash

```sh
xz -d images/talos-<node>.raw.xz
diskutil list                       # match the card by size, not number
diskutil unmountDisk /dev/diskN
sudo dd if=images/talos-<node>.raw of=/dev/rdiskN bs=4M
```

## 3. Provision

```sh
cd tofu
tofu init
tofu apply -target=talos_cluster_kubeconfig.cluster
tofu output -raw kubeconfig  > ~/.kube/config
tofu output -raw talosconfig > ~/.talos/config
```

## 4. Bootstrap

On a rebuild, restore the sealed-secrets keys first, or no SealedSecret in git can be
decrypted:

```sh
kubectl create namespace sealed-secrets
kubectl apply -f sealed-secrets-keys.json
```

Then install Cilium, ArgoCD and `apps-root`:

```sh
tofu apply
```

## Re-provisioning

`--wipe-mode system-disk` erases the bootloader. Build the SD image **before** resetting,
and never use `all` or `user-disks` on pi5-cp-01 — they destroy the RAID1 mirror.

```sh
gmake rpi5b-image
talosctl reset --graceful=false --reboot --wipe-mode system-disk -n <ip>
```
