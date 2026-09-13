#!/bin/bash
# Remove the workshop. By default this removes only the application and its Tyk
# configuration, leaving the cluster and control plane in place so you can
# redeploy quickly.
#
#   ./scripts/99-teardown.sh            # remove the workshop app
#   ./scripts/99-teardown.sh --cluster  # also delete the whole kind cluster
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CLUSTER="${CLUSTER:-acme-workshop}"
ACME_NS="${ACME_NS:-acme}"

echo "Removing the workshop application (the Operator will delete the APIs from Tyk)"
# The Operator refuses to delete an API while a SecurityPolicy still references
# it, so remove the policy first and let its finalizer clear.
kubectl delete securitypolicy acme-demo-default -n "$ACME_NS" --ignore-not-found --timeout=120s || true
kubectl delete -k . --ignore-not-found=true --timeout=300s || true

if [ "${1:-}" = "--cluster" ]; then
  echo "Deleting kind cluster '$CLUSTER'"
  kind delete cluster --name "$CLUSTER"
fi
echo "Done."
