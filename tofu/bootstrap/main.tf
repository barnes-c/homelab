locals {
  # Talos specifics, all of them required:
  #   - securityContext.capabilities: Talos has no privileged containers, so the agent's
  #     capabilities have to be enumerated.
  #   - cgroup.autoMount disabled: the root filesystem is read-only; Talos already mounts
  #     cgroup2 at /sys/fs/cgroup.
  #   - k8sServiceHost/Port: KubePrism, so the agent reaches the API server without needing
  #     kube-proxy to exist first. machine.features.kubePrism must be on.
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

    # WireGuard offloads to the kernel module; the Pi kernels have it built in.
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

  # apps-root cannot ride along in the ArgoCD release via extraObjects: the Helm provider
  # REST-maps every object in the release manifest client-side *before* applying anything,
  # so an Application fails with "no matches for kind Application in version
  # argoproj.io/v1alpha1 / ensure CRDs are installed first" when the CRD ships in that same
  # release. Helm's kind ordering does not help -- it only applies after that mapping step.
  # It is a separate kubectl_manifest below, which resolves at apply time. The built-in
  # kubernetes_manifest is not an option either: it needs the CRD at *plan* time.
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

    # The chart ships both of these disabled, which produced a silent, self-inflicted
    # outage: dex opens its OIDC connectors once at startup and does not retry. It started
    # while auth.barnes.biz was still behind Cloudflare's proxy, got a 525, and gave up.
    # With no readiness probe the pod still reported 1/1 Ready, so the Service routed
    # traffic to a port nothing was listening on -- ArgoCD logged "connection refused" --
    # and with no liveness probe nothing ever restarted it. It sat wedged for 22h with
    # RESTARTS=0. Enabling both means a wedged dex is taken out of the Service and
    # restarted instead of quietly blackholing every login.
    dex = {
      livenessProbe  = { enabled = true }
      readinessProbe = { enabled = true }
    }
  }
}

# Gateway API CRDs must exist BEFORE Cilium installs, which is why they live here rather
# than in an Argo Application. Cilium reads them at two points, both one-shot:
#
#   1. cilium-operator checks for the required GVKs once at startup. Missing => it disables
#      the Gateway controller entirely and only logs it.
#   2. The chart's GatewayClass template is guarded by gatewayClass.create=auto, which fires
#      only if .Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1/GatewayClass" at
#      install time. Missing => Helm SILENTLY omits the GatewayClass; the release still
#      reports success.
#
# Installed by ArgoCD (as it was) both of those lose the race, and the symptom is a Gateway
# stuck at PROGRAMMED=Unknown with "Waiting for controller" and no GatewayClass anywhere.
#
# Experimental channel, not standard: Cilium watches TLSRoute (v1alpha2), which standard
# does not ship. Without it the operator logs "no kind is registered for the type
# v1alpha2.TLSRouteList" continuously. Pinned to the same bundle version that was vendored
# before (v1.4.1) -- the channel is the fix here, a version bump is a separate change.
data "kubectl_file_documents" "gateway_api_crds" {
  content = file("${path.module}/gateway-api/experimental-install.yaml")
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = data.kubectl_file_documents.gateway_api_crds.manifests

  yaml_body = each.value

  # These CRDs exceed the 256KB annotation limit that client-side apply relies on.
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
  # Literal, not a variable: Renovate's terraform manager only detects chart versions
  # written inline on the helm_release. `version = var.x` silently stops updates.
  version   = "1.19.4"
  namespace = "kube-system"

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
  version          = "9.4.5"
  namespace        = "argocd"
  create_namespace = true

  atomic  = true
  wait    = true
  timeout = 600

  values = [yamlencode(merge(local.argocd_values, var.argocd_extra_values))]

  depends_on = [helm_release.cilium]
}

# App-of-apps root. Everything past this point is ArgoCD's, not tofu's.
# depends_on guarantees the Application CRD exists before this applies.
resource "kubectl_manifest" "apps_root" {
  yaml_body = yamlencode(local.apps_root)

  depends_on = [helm_release.argocd]
}
