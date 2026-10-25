locals {
  apps_root = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "apps-root"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.apps_repo
        targetRevision = var.apps_revision
        path           = var.apps_path
        directory      = { recurse = true }
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
    configs = {
      params = { "server.insecure" = true }
      cm = {
        "resource.customizations.health.argoproj.io_Application" = <<-EOT
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.health ~= nil then
              hs.status = obj.status.health.status
              if obj.status.health.message ~= nil then
                hs.message = obj.status.health.message
              end
            end
          end
          return hs
        EOT
      }
    }
    server = { service = { type = "ClusterIP" } }
    dex    = { enabled = false }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.1"
  namespace        = "argocd"
  create_namespace = true

  atomic  = true
  wait    = true
  timeout = 600

  values = [yamlencode(merge(local.argocd_values, var.argocd_extra_values))]

  lifecycle {
    ignore_changes = [values, version]
  }

  depends_on = [helm_release.cilium]
}

# Hand off to ArgoCD
resource "kubectl_manifest" "apps_root" {
  yaml_body = yamlencode(local.apps_root)

  depends_on = [helm_release.argocd]
}
