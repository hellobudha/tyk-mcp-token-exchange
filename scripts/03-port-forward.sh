#!/bin/bash
# Opens the port-forwards the demo needs, and keeps them open.
#
#   ./scripts/03-port-forward.sh            # foreground; ctrl-c stops everything
#   ./scripts/03-port-forward.sh --detach   # survives closing the terminal
#   ./scripts/03-port-forward.sh --status   # is each endpoint actually up?
#   ./scripts/03-port-forward.sh --stop     # stop a detached run
#
# Each forward is supervised independently. `kubectl port-forward` exits for
# good when it loses its pod — a rollout, an eviction, a laptop sleeping — so a
# plain `kubectl port-forward &` leaves you with a script that is still running
# and an endpoint that is silently dead. That is the failure you do not want to
# find mid-demo, so every forward is restarted on exit until you stop it.
#
# acme-keycloak MUST be forwarded on 8280 and reached by that hostname: the realm
# pins the issuer to http://acme-keycloak:8280, so the browser has to use the same
# URL the cluster does. `sudo ./scripts/00-hosts.sh` adds it.
set -uo pipefail

TYK_NAMESPACE="${TYK_NAMESPACE:-tyk}"
ACME_NAMESPACE="${ACME_NAMESPACE:-acme}"

RUNDIR="${TMPDIR:-/tmp}/acme-workshop-pf"
PIDFILE="$RUNDIR/supervisor.pid"
KIDFILE="$RUNDIR/children"
STOPFLAG="$RUNDIR/stopping"
LOG="$RUNDIR/port-forward.log"

# label | namespace | service | localPort:remotePort
FORWARDS=(
  "copilot  |$ACME_NAMESPACE|acme-chat|8095:8095"
  "keycloak |$ACME_NAMESPACE|acme-keycloak|8280:8280"
  "gateway  |$TYK_NAMESPACE|gateway-svc-tyk-tyk-gateway|8080:8080"
  "dashboard|$TYK_NAMESPACE|dashboard-svc-tyk-tyk-dashboard|3000:3000"
  "traces   |$ACME_NAMESPACE|jaeger|16686:16686"
)

field() { printf '%s' "$1" | cut -d'|' -f"$2" | sed 's/ *$//'; }

port_up() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ status ----
show_status() {
  local running="no"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    running="yes (pid $(cat "$PIDFILE"))"
  fi
  echo "Supervisor detached: $running"
  echo
  printf '  %-11s %-7s %s\n' "WHAT" "PORT" "STATE"
  local down=0
  for f in "${FORWARDS[@]}"; do
    local label port
    label=$(field "$f" 1)
    port=${f##*|}; port=${port%%:*}
    if port_up "$port"; then
      printf '  %-11s %-7s up\n' "$label" "$port"
    else
      printf '  %-11s %-7s DOWN\n' "$label" "$port"
      down=$((down+1))
    fi
  done
  echo
  [ -f "$LOG" ] && echo "Log: $LOG"
  [ "$down" -eq 0 ] || echo "$down endpoint(s) down."
  return 0
}

# -------------------------------------------------------------------- stop ----
stop_all() {
  touch "$STOPFLAG" 2>/dev/null || true
  local n=0
  if [ -f "$KIDFILE" ]; then
    while read -r p; do
      [ -n "$p" ] && kill "$p" 2>/dev/null && n=$((n+1))
    done < "$KIDFILE"
  fi
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  # Anything this workshop started that outlived its supervisor.
  pkill -f 'kubectl port-forward -n (acme|tyk) ' 2>/dev/null || true
  rm -f "$KIDFILE" "$STOPFLAG"
  echo "Stopped ($n forward(s) signalled)."
}

# --------------------------------------------------------------- supervise ----
# One forward, restarted until the stop flag appears.
supervise() {
  local label=$1 ns=$2 svc=$3 ports=$4 attempt=0
  while [ ! -f "$STOPFLAG" ]; do
    kubectl port-forward -n "$ns" "svc/$svc" "$ports" >>"$LOG" 2>&1 &
    local kpid=$!
    echo "$kpid" >> "$KIDFILE"
    wait "$kpid"
    [ -f "$STOPFLAG" ] && break
    attempt=$((attempt+1))
    echo "$(date '+%H:%M:%S') [$label] forward exited — restart #$attempt" >> "$LOG"
    # Brief, capped backoff: a rolling pod is back in seconds, but a service
    # that never comes back should not spin.
    sleep $(( attempt > 5 ? 5 : 1 ))
  done
}

run_supervisor() {
  mkdir -p "$RUNDIR"
  rm -f "$STOPFLAG" "$KIDFILE"
  : > "$LOG"

  local pids=()
  cleanup() {
    touch "$STOPFLAG"
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    if [ -f "$KIDFILE" ]; then
      while read -r k; do [ -n "$k" ] && kill "$k" 2>/dev/null; done < "$KIDFILE"
    fi
    rm -f "$KIDFILE" "$STOPFLAG" "$PIDFILE"
  }
  trap cleanup EXIT INT TERM

  for f in "${FORWARDS[@]}"; do
    supervise "$(field "$f" 1)" "$(field "$f" 2)" "$(field "$f" 3)" "${f##*|}" &
    pids+=($!)
  done
  wait
}

# -------------------------------------------------------------------- main ----
case "${1:-}" in
  --status|-s) show_status; exit $? ;;
  --stop)      stop_all;    exit 0  ;;
  --supervisor)                      # internal: the detached worker
    echo $$ > "$PIDFILE"
    run_supervisor
    exit 0 ;;
  --detach|-d) DETACH=1 ;;
  "")          DETACH=0 ;;
  *) echo "usage: $0 [--detach|--status|--stop]" >&2; exit 2 ;;
esac

grep -q 'acme-keycloak' /etc/hosts || {
  echo "ERROR: no 'acme-keycloak' entry in /etc/hosts - run: sudo ./scripts/00-hosts.sh" >&2
  exit 1
}

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "A detached supervisor is already running (pid $(cat "$PIDFILE"))."
  echo "Use --status to check it, or --stop to stop it."
  exit 0
fi

mkdir -p "$RUNDIR"

if [ "$DETACH" = "1" ]; then
  nohup "$0" --supervisor >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "Port-forwards started in the background. They survive closing this terminal."
  # Give them a moment so --status reports the truth rather than a race.
  for _ in $(seq 1 20); do
    port_up 8095 && port_up 3000 && break
    sleep 0.5
  done
  echo
  show_status
  echo
  echo "Copilot chat : http://localhost:8095   (alice / bob, password Acme-Demo-2026!)"
  echo "Keycloak     : http://acme-keycloak:8280 (admin/admin)"
  echo "Tyk Dashboard: http://localhost:3000"
  echo "Traces       : http://localhost:16686  (Jaeger)"
  echo
  echo "Stop with: $0 --stop"
  exit 0
fi

echo "Port-forwarding (auto-restarting; ctrl-c stops all):"
for f in "${FORWARDS[@]}"; do
  port=${f##*|}; port=${port%%:*}
  echo "  $(field "$f" 1)  ->  $port"
done
echo
echo "Copilot chat : http://localhost:8095   (alice / bob, password Acme-Demo-2026!)"
echo "Keycloak     : http://acme-keycloak:8280 (admin/admin)"
echo "Tyk Dashboard: http://localhost:3000"
echo "Traces       : http://localhost:16686  (Jaeger)"
echo
echo "Tip: --detach keeps these alive after this terminal closes."
echo "Ctrl-C to stop."
echo $$ > "$PIDFILE"
run_supervisor
