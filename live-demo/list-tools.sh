#!/bin/bash
# Lists the MCP tools the gateway exposes, and calls one as a chosen user.
# Requires port-forward.sh to be running.   Usage: ./list-tools.sh [user] [tool]
set -uo pipefail
KC="${KC:-http://acme-keycloak:8280}"
MCP="${MCP:-http://localhost:8080/acme-mcp/mcp}"
USER_NAME="${1:-alice}"
TOOL="${2:-}"

T=$(curl -s -X POST "$KC/realms/acme/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=acme-support-chat \
  -d "username=$USER_NAME" -d 'password=Acme-Demo-2026!' -d scope='openid customers:all' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
[ -n "$T" ] || { echo "could not sign in as $USER_NAME - is port-forward.sh running?"; exit 1; }

hdr=(-H "Authorization: Bearer $T" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
SID=$(curl -s -D- -o /dev/null -X POST "$MCP" "${hdr[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"list-tools","version":"1"}}}' \
  | grep -i '^Mcp-Session-Id' | tr -d '\r' | awk '{print $2}')
curl -s -o /dev/null -X POST "$MCP" "${hdr[@]}" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "Tools the gateway exposes to $USER_NAME:"
curl -s -X POST "$MCP" "${hdr[@]}" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | sed -n 's/^data: //p' \
  | python3 -c 'import sys,json;[print("  ",t["name"]) for t in json.load(sys.stdin)["result"]["tools"]]'

[ -n "$TOOL" ] || exit 0
echo
echo "Calling $TOOL as $USER_NAME:"
HTTP=$(curl -s -o /tmp/lt.json -w '%{http_code}' -X POST "$MCP" "${hdr[@]}" -H "Mcp-Session-Id: $SID" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":{\"customer_id\":\"C-1024\",\"amount\":49.99,\"email\":\"x@acme.example\"}}}")
if [ "$HTTP" != "200" ]; then echo "  HTTP $HTTP - denied at the MCP proxy, no token minted"; exit 0; fi
sed -n 's/^data: //p' /tmp/lt.json | python3 -c '
import sys,json,base64
sc=json.load(sys.stdin)["result"]["structuredContent"]
tok=[v for k,v in sc["upstream"]["headers"].items() if k.lower()=="authorization"][0].replace("Bearer ","")
p=tok.split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print("  upstream status :", sc["status"])
print("  upstream url    :", sc["upstream"]["url"])
print("  exchanged scope :", c["scope"].strip(), "| aud:", c["aud"], "| azp:", c["azp"])'
