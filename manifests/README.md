# Manifests

Raw Kubernetes manifests managed by ArgoCD Applications defined in `apps/`.

Each subdirectory is referenced by an ArgoCD Application as a `path` source.

## Structure

- `cert-manager/` — ClusterIssuer, TLS certificate, and sealed Cloudflare API token.
- `gateway/` — Gateway API infrastructure: Cilium LB-IPAM pool, L2 announcement policy,
  shared HTTP Gateway, and per-app HTTPRoutes.
- `monitoring/` — Per-component Helm values and chart metadata for the monitoring ApplicationSet.

## Adding a New Route

Create an HTTPRoute in `manifests/gateway/`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app-namespace
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: main
      namespace: gateway
  hostnames:
    - my-app.barnes.biz
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: my-app-service
          port: 80
          weight: 1
```
