#!/bin/bash
# Opens the port-forwards the demo needs. Runs in the foreground; ctrl-c stops all.
#
# acme-keycloak MUST be forwarded on 8280 and reached by that hostname: the realm
# pins the issuer to http://acme-keycloak:8280, so the browser has to use the same
# URL the cluster does. `sudo ./scripts/00-hosts.sh` adds it.
set -euo pipefail
TYK_NAMESPACE="${TYK_NAMESPACE:-tyk}"
ACME_NAMESPACE="${ACME_NAMESPACE:-acme}"

grep -q 'acme-keycloak' /etc/hosts || {
  echo "ERROR: no 'acme-keycloak' entry in /etc/hosts - run: sudo ./scripts/00-hosts.sh" >&2
  exit 1
}

pids=()
cleanup() { echo; echo "Stopping port-forwards"; for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

fwd() {
  echo "  $3 -> $1/$2"
  kubectl port-forward -n "$1" "svc/$2" "$3" >/dev/null 2>&1 &
  pids+=($!)
}

echo "Port-forwarding:"
fwd "$ACME_NAMESPACE" acme-keycloak 8280:8280
fwd "$ACME_NAMESPACE" acme-chat     8095:8095
fwd "$TYK_NAMESPACE"  gateway-svc-tyk-tyk-gateway   8080:8080
fwd "$TYK_NAMESPACE"  dashboard-svc-tyk-tyk-dashboard 3000:3000
fwd "$ACME_NAMESPACE" jaeger        16686:16686

echo
echo "Copilot chat : http://localhost:8095   (alice / bob, password Acme-Demo-2026!)"
echo "Keycloak     : http://acme-keycloak:8280 (admin/admin)"
echo "Tyk Dashboard: http://localhost:3000"
echo "Traces       : http://localhost:16686  (Jaeger)"
echo
echo "Ctrl-C to stop."
wait
