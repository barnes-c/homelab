#!/usr/bin/env bash
set -euo pipefail

# Records the connections pods in a namespace open and accept, from Hubble on every node,
# and prints each distinct one with a count. Input for writing its network policy.
# Usage: scripts/hubble-flows.sh <namespace> [seconds, default 600]

ns="$1"
secs="${2:-600}"

tmp="$(mktemp -d)"
trap 'jobs -p | xargs kill 2>/dev/null || true; rm -rf "$tmp"' EXIT

for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$pod" -- \
    hubble observe --namespace "$ns" --follow --type trace --type drop -o jsonpb \
    > "$tmp/${pod##*/}.json" 2>/dev/null &
done

echo "Recording $ns for ${secs}s..." >&2
sleep "$secs"
jobs -p | xargs kill 2>/dev/null || true
wait 2>/dev/null || true

# One line per connection: replies are dropped, and for TCP only the opening SYN counts.
cat "$tmp"/*.json | jq -r '
  def f(o; a; b): o[a] // o[b];
  def ep(e; ip; names):
    (if e.namespace then
       "\(e.namespace)/\(e.workloads[0].name // f(e; "pod_name"; "podName"))"
     elif ((e.labels // []) | map(select(startswith("reserved:"))) | length) > 0 then
       (e.labels | map(select(startswith("reserved:"))) | join(","))
       + (if (e.labels | index("reserved:world")) then " \(ip)" else "" end)
     else ip end)
    + (if ((names // []) | length) > 0 then " (\(names | join(",")))" else "" end);
  .flow
  | select((f(.; "is_reply"; "isReply") // false) == false)
  | select(.l4.UDP or (.l4.TCP.flags.SYN == true and (.l4.TCP.flags.ACK // false) == false))
  | (.l4.TCP // .l4.UDP) as $l4
  | "\(ep(.source; .IP.source; f(.; "source_names"; "sourceNames")))"
    + " -> \(ep(.destination; .IP.destination; f(.; "destination_names"; "destinationNames")))"
    + ":\(f($l4; "destination_port"; "destinationPort"))/\(if .l4.UDP then "udp" else "tcp" end)"
    + "  \(.verdict)"
' | sort | uniq -c | sort -rn
