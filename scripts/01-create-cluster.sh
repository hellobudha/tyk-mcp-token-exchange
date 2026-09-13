#!/bin/bash
# Step 1 — create the cluster and install the Tyk control plane.
#
# Creates a local kind cluster, installs cert-manager (the Tyk Operator's
# admission webhook needs it), then the Tyk stack: Redis, PostgreSQL, Dashboard,
# Gateway and Operator. Nothing here is specific to the workshop app — this is
# the platform the workshop then deploys onto.
#
# Needs a Tyk licence with an enterprise scope: token exchange is an enterprise
# feature, and on a standard gateway the middleware is a no-op.
#
#   export TYK_LICENSE=...        (or put it in .env as TYK_LICENSE=...)
#   ./scripts/01-create-cluster.sh
#
# Safe to re-run: every step is idempotent.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CLUSTER="${CLUSTER:-acme-workshop}"
TYK_NS="${TYK_NS:-tyk}"
TYK_VERSION="${TYK_VERSION:-v5.15.0}"
CHART_VERSION="${CHART_VERSION:-5.3.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.4}"

log()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- licence ----
[ -f .env ] && set -a && . ./.env && set +a
[ -n "${TYK_LICENSE:-}" ] || die "TYK_LICENSE is not set. Export it, or create a .env file containing TYK_LICENSE=..."

licence_scope=$(printf '%s' "${TYK_LICENSE}" | cut -d. -f2 | python3 -c '
import sys, base64, json
s = sys.stdin.read().strip(); s += "=" * (-len(s) % 4)
try:
    print(json.loads(base64.urlsafe_b64decode(s)).get("scope", ""))
except Exception:
    print("")')
case ",$licence_scope," in
  *,streams,*|*,enterprise,*) info "Licence scope: $licence_scope" ;;
  *) die "This licence has scope '$licence_scope'. Token exchange needs an enterprise-scoped licence." ;;
esac

# ------------------------------------------------------------- toolchain ----
log "Checking tools"
for t in kind kubectl helm docker; do
  command -v "$t" >/dev/null || die "$t not found"
  info "$(command -v "$t")"
done
docker info >/dev/null 2>&1 || die "Docker is not running"

# --------------------------------------------------------------- cluster ----
log "Cluster: $CLUSTER"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  info "already exists — reusing it"
else
  kind create cluster --name "$CLUSTER" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null
info "kubectl context: kind-$CLUSTER"

# ---------------------------------------------------------- cert-manager ----
log "cert-manager (required by the Tyk Operator's webhook)"
if kubectl get deploy cert-manager -n cert-manager >/dev/null 2>&1; then
  info "already installed"
else
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
  info "waiting for cert-manager to become ready"
  kubectl wait --for=condition=Available deploy --all -n cert-manager --timeout=300s >/dev/null
fi
info "ready"

# ------------------------------------------------------------ tyk secret ----
log "Tyk namespace and secrets"
kubectl create namespace "$TYK_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic tyk-conf -n "$TYK_NS" \
  --from-literal=APISecret="$(openssl rand -hex 16)" \
  --from-literal=AdminSecret="$(openssl rand -hex 16)" \
  --from-literal=DashLicense="$TYK_LICENSE" \
  --from-literal=OperatorLicense="$TYK_LICENSE" \
  --from-literal=adminUserEmail="admin@acme.example" \
  --from-literal=adminUserPassword="Workshop-2026!" \
  --from-literal=adminUserFirstName="Workshop" \
  --from-literal=adminUserLastName="Admin" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
info "tyk-conf secret written"

# ----------------------------------------------------------- tyk install ----
log "Tyk Helm repository"
helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/ >/dev/null 2>&1 || true
helm repo update tyk-helm >/dev/null 2>&1 || helm repo update >/dev/null

log "Redis and PostgreSQL"
kubectl apply -f platform/datastores.yaml >/dev/null
kubectl rollout status deploy/tyk-redis    -n "$TYK_NS" --timeout=300s | sed 's/^/   /'
kubectl rollout status deploy/tyk-postgres -n "$TYK_NS" --timeout=300s | sed 's/^/   /'

kubectl create secret generic tyk-db -n "$TYK_NS" \
  --from-literal=connectionString="host=tyk-postgres port=5432 user=postgres password=workshop database=tyk_analytics sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Installing the Tyk stack (chart $CHART_VERSION, images $TYK_VERSION)"
# The workshop needs the Dashboard, one Gateway, the Pump (for analytics) and
# the Operator. The developer portal is not used, so it stays off.
helm upgrade --install tyk tyk-helm/tyk-stack -n "$TYK_NS" --version "$CHART_VERSION" \
  --set global.license.dashboard="$TYK_LICENSE" \
  --set global.license.operator="$TYK_LICENSE" \
  --set global.adminUser.useSecretName=tyk-conf \
  --set global.secrets.useSecretName=tyk-conf \
  --set global.storageType=postgres \
  --set global.postgres.connectionStringSecret.name=tyk-db \
  --set global.postgres.connectionStringSecret.keyName=connectionString \
  --set global.redis.addrs[0]=tyk-redis:6379 \
  --set global.redis.pass="" \
  --set global.components.devPortal=false \
  --set global.components.pump=true \
  --set global.components.operator=true \
  --set global.components.bootstrap=true \
  --set tyk-dashboard.dashboard.image.tag="$TYK_VERSION" \
  --set tyk-dashboard.dashboard.auditLogs.enabled=true \
  --set tyk-dashboard.dashboard.auditLogs.type=db \
  --set tyk-dashboard.dashboard.auditLogs.enableDetailedRecording=true \
  --set tyk-gateway.gateway.image.repository=tykio/tyk-gateway-ee \
  --set tyk-gateway.gateway.image.tag="$TYK_VERSION" \
  --set tyk-gateway.gateway.opentelemetry.enabled=true \
  --set tyk-gateway.gateway.opentelemetry.exporter=grpc \
  --set tyk-gateway.gateway.opentelemetry.endpoint=jaeger.acme.svc:4317 \
  --timeout 15m >/dev/null
info "helm release installed"

log "Waiting for the control plane"
kubectl rollout status deploy/dashboard-tyk-tyk-dashboard -n "$TYK_NS" --timeout=600s | sed 's/^/   /'
kubectl rollout status deploy/gateway-tyk-tyk-gateway   -n "$TYK_NS" --timeout=600s | sed 's/^/   /'
kubectl rollout status deploy/tyk-tyk-operator-controller-manager -n "$TYK_NS" --timeout=600s | sed 's/^/   /'

# The gateway registers with the Dashboard at boot. If it started first it will
# be running with no APIs loaded, so restart it now that the Dashboard is up.
log "Restarting the gateway so it registers against a live Dashboard"
kubectl rollout restart deploy/gateway-tyk-tyk-gateway -n "$TYK_NS" >/dev/null
kubectl rollout status  deploy/gateway-tyk-tyk-gateway -n "$TYK_NS" --timeout=300s | sed 's/^/   /'

kubectl get crd tykmcpproxydefinitions.tyk.tyk.io >/dev/null 2>&1 \
  || die "TykMcpProxyDefinition CRD missing — the Operator version is too old for this workshop (need 1.4+)"

cat <<EOF

Control plane ready.

  cluster      : kind-$CLUSTER
  Tyk version  : $TYK_VERSION
  Dashboard    : admin@acme.example / Workshop-2026!
  next step    : ./scripts/02-deploy.sh

EOF
