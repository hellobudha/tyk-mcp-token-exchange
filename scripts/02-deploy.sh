#!/bin/bash
# Step 2 — deploy the workshop application and its Tyk configuration.
#
# Builds the two Go services, loads them into the cluster, then applies
# everything with `kubectl apply -k`. The Tyk configuration is applied the same
# way as the Deployments — this script never calls the Tyk API.
#
#   ./scripts/02-deploy.sh
#
# Safe to re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CLUSTER="${CLUSTER:-acme-workshop}"
TYK_NS="${TYK_NS:-tyk}"
ACME_NS="${ACME_NS:-acme}"
CHAT_IMAGE="acme-chat:1.0.0"
MCP_IMAGE="acme-mcp-server:1.0.0"

log()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

log "Checking the control plane"
kubectl get crd tykmcpproxydefinitions.tyk.tyk.io >/dev/null 2>&1 \
  || die "Tyk Operator CRDs not found. Run ./scripts/01-create-cluster.sh first."
gw_image=$(kubectl get deploy -n "$TYK_NS" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | grep tyk-gateway || true)
case "$gw_image" in
  *tyk-gateway-ee*) info "gateway image: $gw_image" ;;
  "") die "No Tyk gateway found in namespace '$TYK_NS'" ;;
  *) die "Token exchange needs the enterprise gateway image. Found: $gw_image" ;;
esac

log "Building the application images"
docker build -q -t "$CHAT_IMAGE" services/chat  >/dev/null && info "built $CHAT_IMAGE"
docker build -q -t "$MCP_IMAGE"  services/mcp-server >/dev/null && info "built $MCP_IMAGE"

# kind nodes have their own image store. Side-loading fails on some multi-arch
# manifests, so fall back to pulling directly on the node.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "Loading images into kind cluster '$CLUSTER'"
  kind load docker-image "$CHAT_IMAGE" "$MCP_IMAGE" --name "$CLUSTER" 2>&1 | sed 's/^/   /' || \
    die "kind load failed — see README troubleshooting"
else
  info "Not a kind cluster: ensure $CHAT_IMAGE and $MCP_IMAGE are pullable by the nodes"
fi

log "Applying manifests"
kubectl apply -k . | sed 's/^/   /'

log "Waiting for the application"
kubectl wait --for=condition=Available deploy --all -n "$ACME_NS" --timeout=420s | sed 's/^/   /'

log "Waiting for the Operator to reconcile the Tyk configuration"
wait_cr() {
  local kind=$1 name=$2 deadline=$((SECONDS+240)) status
  while [ $SECONDS -lt $deadline ]; do
    status=$(kubectl get "$kind" "$name" -n "$ACME_NS" -o jsonpath='{.status.latestTransaction.status}' 2>/dev/null || true)
    [ "$status" = "Successful" ] && { info "$kind/$name: Successful"; return 0; }
    [ "$status" = "Failed" ] && info "$kind/$name: $(kubectl get "$kind" "$name" -n "$ACME_NS" -o jsonpath='{.status.latestTransaction.error}' 2>/dev/null)"
    sleep 3
  done
  die "$kind/$name did not reconcile. Check: kubectl logs -n $TYK_NS deploy/tyk-tyk-operator-controller-manager"
}
wait_cr tykoasapidefinition   acme-api
wait_cr tykmcpproxydefinition acme-mcp-proxy

# The SecurityPolicy references both APIs, so its first reconcile can run before
# they exist on Tyk and fail with "Resource not found". controller-runtime
# retries with backoff; nudging the object makes the retry immediate.
deadline=$((SECONDS+240))
while [ -z "$(kubectl get securitypolicy acme-demo-default -n "$ACME_NS" -o jsonpath='{.status.pol_id}' 2>/dev/null)" ]; do
  [ $SECONDS -lt $deadline ] || die "SecurityPolicy did not reconcile"
  kubectl annotate securitypolicy acme-demo-default -n "$ACME_NS" \
    tyk.tyk.io/nudge="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  sleep 5
done
info "securitypolicy/acme-demo-default: $(kubectl get securitypolicy acme-demo-default -n "$ACME_NS" -o jsonpath='{.status.pol_id}')"

cat <<EOF

Workshop deployed.

  next step  : ./scripts/03-port-forward.sh     (leave it running)
  then       : ./scripts/04-test.sh             (proves the whole flow headlessly)
  then       : open http://localhost:8095       (alice / bob / carol — Acme-Demo-2026!)

EOF
