#!/bin/bash
# Headless proof of the demo, run against the port-forwarded endpoints.
# Requires ./port-forward.sh to be running in another terminal.
#
# Asserts: alice's read succeeds and the token that reached the API kept her sub
# while its aud, azp and scope were re-pointed; alice's refund is rejected before
# any token is minted; bob's refund succeeds with refunds:write.
set -uo pipefail

KC="${KC:-http://acme-keycloak:8280}"
GW="${GW:-http://localhost:8080}"
MCP="$GW/acme-mcp/mcp"
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

token_for() {
  curl -s -X POST "$KC/realms/acme/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=acme-support-chat \
    -d "username=$1" -d 'password=Acme-Demo-2026!' -d scope='openid customers:all' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'
}

mcp_session() {
  curl -s -D- -o /dev/null -X POST "$MCP" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test.sh","version":"1"}}}' \
  | grep -i '^Mcp-Session-Id' | tr -d '\r' | awk '{print $2}'
}

call_tool() { # bearer session name args -> body on stdout, http code in $HTTP
  HTTP=$(curl -s -o /tmp/tx-tool.json -w '%{http_code}' -X POST "$MCP" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $2" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":$4}}")
  sed -n 's/^data: //p' /tmp/tx-tool.json
}

echo "Acme Support Copilot - token exchange tests"

echo; echo "alice (entitlements: customers:read)"
ALICE=$(token_for alice)
[ -n "$ALICE" ] && ok "signed in" || { bad "could not sign in - is port-forward.sh running?"; exit 1; }
SID=$(mcp_session "$ALICE")
[ -n "$SID" ] && ok "MCP session established through Tyk" || bad "no MCP session"
curl -s -o /dev/null -X POST "$MCP" -H "Authorization: Bearer $ALICE" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

call_tool "$ALICE" "$SID" lookup_customer '{"customer_id":"C-1024"}' > /tmp/tx-read.json
ALICE="$ALICE" python3 - <<'EOF'
import json,base64,os,sys
def claims(t):
    p=t.split('.')[1]; p+='='*(-len(p)%4)
    return json.loads(base64.urlsafe_b64decode(p))
try:
    sc=json.load(open('/tmp/tx-read.json'))['result']['structuredContent']
    up=sc['upstream']
    tok=[v for k,v in up['headers'].items() if k.lower()=='authorization'][0].replace('Bearer ','')
except Exception as e:
    print(f"  FAIL  lookup_customer did not return an upstream echo ({e})"); sys.exit(1)
sso, ex = claims(os.environ['ALICE']), claims(tok)
checks = [
    ("read allowed (HTTP %s)" % up.get('status', sc.get('status')), sc.get('status')==200),
    ("sub preserved across the exchange", sso['sub']==ex['sub']),
    ("aud re-pointed to api.acme.internal", ex['aud']=='api.acme.internal'),
    ("azp records the gateway client", ex['azp']=='tyk-mcp-gateway'),
    ("scope narrowed to customers:read", ex['scope'].strip()=='customers:read'),
    ("broad customers:all did not leak downstream", 'customers:all' not in ex['scope']),
]
for msg, good in checks:
    print(("  PASS  " if good else "  FAIL  ")+msg)
sys.exit(0 if all(g for _,g in checks) else 1)
EOF
[ $? -eq 0 ] && PASS=$((PASS+6)) || FAIL=$((FAIL+1))

call_tool "$ALICE" "$SID" issue_refund '{"customer_id":"C-1024","amount":49.99}' >/dev/null
if [ "$HTTP" == "403" ]; then ok "refund rejected with 403 before any exchange"; else bad "refund returned $HTTP, expected 403"; fi

echo; echo "bob (entitlements: customers:read customers:write refunds:write)"
BOB=$(token_for bob)
BSID=$(mcp_session "$BOB")
curl -s -o /dev/null -X POST "$MCP" -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $BSID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
call_tool "$BOB" "$BSID" issue_refund '{"customer_id":"C-1024","amount":49.99}' > /tmp/tx-refund.json
python3 - <<'EOF'
import json,base64,sys
try:
    sc=json.load(open('/tmp/tx-refund.json'))['result']['structuredContent']
    tok=[v for k,v in sc['upstream']['headers'].items() if k.lower()=='authorization'][0].replace('Bearer ','')
    p=tok.split('.')[1]; p+='='*(-len(p)%4)
    c=json.loads(base64.urlsafe_b64decode(p))
except Exception as e:
    print(f"  FAIL  refund did not return an upstream echo ({e})"); sys.exit(1)
good = sc.get('status')==200 and c['scope'].strip()=='refunds:write'
print(("  PASS  " if good else "  FAIL  ")+f"refund allowed, scope={c['scope'].strip()}")
sys.exit(0 if good else 1)
EOF
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
