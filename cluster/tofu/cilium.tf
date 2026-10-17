locals {
  # Capabilities needed for Cilium to function correctly
  # https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#without-kube-proxy-%2B-gateway-api-2
  cilium_values = {
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    ipam                 = { mode = "kubernetes" }
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    k8sServicePort       = 7445

    l2announcements = { enabled = true }
    gatewayAPI      = { enabled = true }

    encryption = {
      enabled   = true
      type      = "wireguard"
      wireguard = { userspaceFallback = false }
    }

    hubble = {
      enabled       = true
      listenAddress = ""
      tls           = { enabled = false }
    }

    resources = { requests = { cpu = "100m", memory = "256Mi" } }
    operator = {
      replicas  = length(local.control_plane_ips) > 1 ? 2 : 1
      resources = { requests = { cpu = "25m", memory = "64Mi" }, limits = { cpu = "500m", memory = "256Mi" } }
    }
  }
}

# Cilium is owned here and nowhere else. It is deliberately NOT an Argo Application:
# Argo runs on the network Cilium provides, so a selfHeal loop on the CNI can cut Argo's
# own connectivity and leave nothing able to repair it.
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.20.3"
  namespace  = "kube-system"

  atomic         = true
  take_ownership = true
  wait           = true
  wait_for_jobs  = true
  timeout        = 600

  values = [yamlencode(merge(local.cilium_values, var.cilium_extra_values))]

  depends_on = [kubectl_manifest.gateway_api_crds]
}
