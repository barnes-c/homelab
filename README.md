# homelab

[![Talos](https://img.shields.io/badge/Talos-v1.15.0--beta.0-ff7300?logo=talos&logoColor=white)](https://github.com/siderolabs/talos/releases/tag/v1.15.0-beta.0)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.37.0-326ce5?logo=kubernetes&logoColor=white)](https://kubernetes.io/releases/)

Talos Linux cluster on Raspberry Pi hardware. OpenTofu bootstraps the cluster, ArgoCD runs everything on it.

|   Node    |        Board         |     Role      |
| --------- | -------------------- | ------------- |
| pi5-cp-01 | Raspberry Pi 5 16GB  | Control plane |
| pi4-wk-01 | Raspberry Pi 4B 8GB  | Worker        |
| cm5-cp-01 | Raspberry Pi CM5 8GB | Control plane |
| cm5-cp-02 | Raspberry Pi CM5 8GB | Control plane |

```txt
cluster/     Talos images (Makefile) and OpenTofu
apps/        ArgoCD Applications
manifests/   manifests those Applications deploy
```
