# cert-manager-webhook-porkbun

ACME DNS-01 solver for Porkbun. cert-manager has no built-in Porkbun provider, and
`*.barnes.biz` is a wildcard, so DNS-01 is the only option — HTTP-01 cannot validate a
wildcard.

Vendored from [pabloa/cert-manager-webhook-porkbun](https://github.com/pabloa/cert-manager-webhook-porkbun)
v1.1.3, rendered from `charts/cert-manager-webhook-porkbun` rather than consumed as a
chart, so the RBAC and pod hardening below can diverge from upstream.

## Divergences from the upstream chart

| Change | Reason |
| ------ | ------ |
| `secret-reader` is a namespaced `Role` over `resourceNames: [porkbun-api-key]` | Upstream binds a `ClusterRole` granting `get/watch/list` on secrets in *every* namespace. The solver does one `Get` of one secret. See barnes-c/homelab-issues#26 |
| `groupName: acme.barnes.biz` | Upstream defaults to the author's domain. The value is arbitrary but must match in three places: `GROUP_NAME`, the `APIService` name, and the ClusterIssuer's `webhook.groupName` |
| `domain-solver` ClusterRole over `resources: [porkbun]` | Upstream grants `*` in the group. The resource is the ClusterIssuer's `solverName` |
| Listens on 8443 (`--secure-port`) | Upstream binds 443, a privileged port. The Service still exposes 443 |
| Image pinned by digest | Chart default is `:latest` |
| `runAsNonRoot`, `readOnlyRootFilesystem`, dropped capabilities, resource limits | Chart ships empty `securityContext` and `resources`. See barnes-c/homelab-issues#12, barnes-c/homelab-issues#13 |

## Upgrading

Re-render from upstream and re-apply the table above — the diff is small but the RBAC
narrowing is silently lost if you copy the chart output verbatim:

```sh
helm template cert-manager-webhook-porkbun \
  https://github.com/pabloa/cert-manager-webhook-porkbun/releases/download/v<ver>/cert-manager-webhook-porkbun-<ver>.tgz \
  --namespace cert-manager --set groupName=acme.barnes.biz
```

## Notes

- The solver hardcodes `ttl: 60` on the challenge TXT record. Porkbun's docs and several
  client libraries claim a 600s floor, but the API accepts and stores 60 — verified
  against the live zone, so retried challenges are not slowed by a stale TTL.
- `Present` creates a record and `CleanUp` deletes only the one whose content matches the
  challenge key, so the two concurrent TXT records at `_acme-challenge.barnes.biz` (one
  for `barnes.biz`, one for `*.barnes.biz`) do not clobber each other.
