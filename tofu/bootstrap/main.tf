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

    hubble    = { enabled = false }
    resources = { requests = { cpu = "100m", memory = "256Mi" } }
    operator = {
      replicas  = var.control_plane_count > 1 ? 2 : 1
      resources = { requests = { cpu = "25m", memory = "64Mi" }, limits = { cpu = "500m", memory = "256Mi" } }
    }
  }

  apps_root = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "apps-root"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.apps_repo
        targetRevision = var.apps_revision
        path           = var.apps_path
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
        retry = {
          limit   = 5
          backoff = { duration = "5s", factor = 2, maxDuration = "3m" }
        }
      }
    }
  }

  argocd_values = {
    configs = { params = { "server.insecure" = true } }
    server  = { service = { type = "ClusterIP" } }

    # Enable for self-healing
    dex = {
      livenessProbe  = { enabled = true }
      readinessProbe = { enabled = true }
    }
  }
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = file("${path.module}/gateway-api/experimental-install.yaml")
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = data.kubectl_file_documents.gateway_api_crds.manifests

  yaml_body = each.value

  server_side_apply = true
  force_conflicts   = true
  wait              = true
}

# Cilium is owned here and nowhere else. It is deliberately NOT an Argo Application:
# Argo runs on the network Cilium provides, so a selfHeal loop on the CNI can cut Argo's
# own connectivity and leave nothing able to repair it.
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.20.1"
  namespace  = "kube-system"

  atomic         = true
  take_ownership = true
  wait           = true
  wait_for_jobs  = true
  timeout        = 600

  values = [yamlencode(merge(local.cilium_values, var.cilium_extra_values))]

  depends_on = [kubectl_manifest.gateway_api_crds]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.8.0"
  namespace        = "argocd"
  create_namespace = true

  atomic  = true
  wait    = true
  timeout = 600

  values = [yamlencode(merge(local.argocd_values, var.argocd_extra_values))]

  depends_on = [helm_release.cilium]
}

# Hand of to ArgoCD
resource "kubectl_manifest" "apps_root" {
  yaml_body = yamlencode(local.apps_root)

  depends_on = [helm_release.argocd]
}
