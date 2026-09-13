"""Render copilot activity from the gateway's OpenTelemetry spans.

Reads a Jaeger trace payload on stdin and prints one line per MCP tool call:
who ran it, which tool, and whether the gateway allowed or denied it.

Traces are the source rather than Tyk analytics because MCP proxy APIs emit no
analytics records on 5.14 or 5.15 — so a denial at the MCP gate exists only here.

Called by activity.sh; not meant to be run directly.
"""
import sys, os, json, datetime

who_filter = os.environ.get("WHO", "")
mins = os.environ.get("MINS", "30")
jaeger = os.environ.get("JAEGER", "http://localhost:16686")

try:
    data = json.load(sys.stdin).get("data") or []
except Exception:
    print("Could not read Jaeger — is port-forward.sh running?")
    sys.exit(1)

rows = []
for trace in data:
    user = tool = outcome = None
    start = min(s["startTime"] for s in trace["spans"])
    tool_status = jsonrpc_status = outer_status = None
    for span in trace["spans"]:
        tags = {x["key"]: x["value"] for x in span["tags"]}
        name = span["operationName"]
        user = tags.get("tyk.api.apikey.alias", user)
        tool = tags.get("mcp.tool.name", tool)
        rc = tags.get("http.response.status_code")
        # Prefer the status of the span that IS the tool call. A trace can also
        # carry the session handshake and close, whose statuses say nothing
        # about whether the tool was allowed.
        if name.startswith("POST /mcp-tool:"):
            tool_status = rc or tool_status
        elif name.startswith("POST /json-rpc-method:tools/call"):
            jsonrpc_status = rc or jsonrpc_status
        elif name.startswith("POST /acme-mcp/mcp"):
            outer_status = rc or outer_status
    outcome = tool_status or jsonrpc_status or outer_status
    if not tool:
        continue                      # initialize / notifications, not a tool call
    if who_filter and user != who_filter:
        continue
    rows.append((start, user, tool, outcome, trace["traceID"]))

rows.sort(reverse=True)

if not rows:
    extra = " for " + who_filter if who_filter else ""
    print("No tool calls in the last " + mins + " minutes" + extra)
    sys.exit(0)

title = "Copilot activity — last " + mins + " minutes"
if who_filter:
    title += " — " + who_filter
print(title)
print("=" * len(title))
print("{:<10}{:<10}{:<18}{:<26}{}".format("when", "user", "tool", "outcome", "trace"))
print("-" * 94)

VERDICT = {200: "allowed", 403: "DENIED (insufficient scope)", 401: "DENIED (not authenticated)"}
for start, user, tool, rc, tid in rows:
    when = datetime.datetime.fromtimestamp(start / 1_000_000).strftime("%H:%M:%S")
    if rc is None:
        verdict = "—"
    else:
        verdict = VERDICT.get(int(rc), "HTTP " + str(rc))
    shown = str(user)
    if len(shown) > 9:
        shown = shown[:8] + "\u2026"       # raw sub UUIDs, from before identityBaseField was set
    print("{:<10}{:<10}{:<18}{:<26}{}".format(when, shown, tool, verdict, tid[:16]))

print()
print("Open a trace:  " + jaeger + "/trace/<trace-id>")
