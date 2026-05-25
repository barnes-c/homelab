locals {
  cilium_default_values = {
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
    l2announcements      = { enabled = true }
    gatewayAPI           = { enabled = true }
    resources            = { requests = { cpu = "100m", memory = "256Mi" } }
    operator = {
      replicas  = 1
      resources = { requests = { cpu = "25m", memory = "64Mi" }, limits = { cpu = "500m", memory = "256Mi" } }
    }
    hubble = { enabled = false }
    encryption = {
      enabled  = true
      type     = "wireguard"
      wireguard = {
        userspaceFallback = false
      }
    }
  }

  argocd_default_values = {
    configs = {
      params = { "server.insecure" = true }
    }
    server = { service = { type = "ClusterIP" } }
  }
}

resource "helm_release" "cilium" {
  atomic         = true
  take_ownership = true

  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.19.4"
  namespace  = "kube-system"

  wait          = true
  wait_for_jobs = true
  timeout       = 600

  values = [yamlencode(merge(local.cilium_default_values, var.cilium_values))]

  lifecycle {
    ignore_changes = all
  }
}

resource "helm_release" "argocd" {
  atomic = true

  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.4.5"

  wait    = true
  timeout = 600

  values = [yamlencode(merge(local.argocd_default_values, var.argocd_values))]

  depends_on = [helm_release.cilium]

  lifecycle {
    ignore_changes = all
  }
}

resource "kubectl_manifest" "apps_root" {
  yaml_body = yamlencode({
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
        repoURL        = var.argocd_apps_repo
        targetRevision = var.argocd_apps_revision
        path           = var.argocd_apps_path
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        retry = {
          limit = 5
          backoff = {
            duration    = "5s"
            factor      = 2
            maxDuration = "3m"
          }
        }
      }
    }
  })

  depends_on = [helm_release.argocd]
}
