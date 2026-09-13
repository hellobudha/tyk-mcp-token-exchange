#!/bin/bash
# "What has this person's copilot actually done?"
#
# One line per MCP tool call: who ran it, which tool, allowed or denied.
# Source is the gateway's OpenTelemetry spans, NOT Tyk analytics — MCP proxy
# APIs emit no analytics records on 5.14, so denials at the MCP gate exist
# only in trace data. See README "Auditing what the agent did".
#
# Requires port-forward.sh (Jaeger on 16686).
# Usage: ./activity.sh [user] [minutes]     e.g. ./activity.sh carol 30
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export JAEGER="${JAEGER:-http://localhost:16686}"
export WHO="${1:-}"
export MINS="${2:-30}"

# Jaeger's HTTP API ignores `lookback` (that is a UI parameter) — the window has
# to be given as explicit start/end microsecond timestamps.
now_us=$(python3 -c 'import time; print(int(time.time()*1_000_000))')
start_us=$(python3 -c "print($now_us - $MINS*60*1_000_000)")

curl -s --max-time 20 "$JAEGER/api/traces?service=tyk&limit=400&start=${start_us}&end=${now_us}" \
  | python3 "$here/_activity.py"
