#!/bin/bash
# Two checks that between them explain every "my realm edit didn't work":
#   1. lints data/realm-acme.json for the multi-element entitlements mistake
#   2. prints the entitlements claim each user's token actually carries
# Requires port-forward.sh to be running for step 2.
# Usage: ./whoami.sh [user...]        (default: every user in the realm)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REALM="$here/../data/realm-acme.json"
KC="${KC:-http://acme-keycloak:8280}"

echo "1. Realm file: $REALM"
lint=$(python3 - "$REALM" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for u in d.get("users", []):
    ent = u.get("attributes", {}).get("entitlements")
    if isinstance(ent, list) and len(ent) > 1:
        bad.append((u["username"], ent))
for name, ent in bad:
    print(f"   BAD  {name}: {json.dumps(ent)}")
    print(f"        -> should be {json.dumps([' '.join(ent)])}")
print("   users declared:", ", ".join(u["username"] for u in d.get("users", [])))
sys.exit(1 if bad else 0)
EOF
)
status=$?
echo "$lint"
if [ $status -ne 0 ]; then
  cat <<'EOF'
   The mapper is single-valued (jsonType.label: String, no multivalued flag), so
   Keycloak keeps ONLY the first array element and silently drops the rest. The
   user still imports and still signs in - they just get fewer permissions than
   you wrote. Fix the file, apply, and restart Keycloak.
EOF
else
  echo "   OK - every entitlements attribute is a single space-separated string"
fi

echo
echo "2. Live token claims"
# bash 3.2 (macOS default) has no mapfile, so build the list portably
users=""
if [ "$#" -gt 0 ]; then
  users="$*"
else
  users=$(python3 -c "
import json
print(' '.join(u['username'] for u in json.load(open('$REALM')).get('users',[])))")
fi

printf '   %-8s %-10s %s\n' USER STATUS "ENTITLEMENTS CLAIM"
printf '   %s\n' "-------------------------------------------------------------"
for u in $users; do
  body=$(curl -s --max-time 10 -X POST "$KC/realms/acme/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=acme-support-chat \
    -d "username=$u" -d 'password=Acme-Demo-2026!' -d scope='openid customers:all')
  USER_NAME="$u" python3 - "$body" <<'EOF'
import sys, os, json, base64
u = os.environ["USER_NAME"]
try: d = json.loads(sys.argv[1])
except Exception:
    print(f"   {u:<8} {'UNREACHABLE':<10} is port-forward.sh running?"); raise SystemExit
t = d.get("access_token")
if not t:
    err = d.get("error_description", d.get("error", "unknown"))
    hint = " - realm not re-imported? restart acme-keycloak" if "credential" in str(err).lower() else ""
    print(f"   {u:<8} {'NO TOKEN':<10} {err}{hint}")
    raise SystemExit
p = t.split(".")[1]; p += "=" * (-len(p) % 4)
ent = json.loads(base64.urlsafe_b64decode(p)).get("entitlements")
print(f"   {u:<8} {'OK':<10} " + (f'"{ent}"' if ent is not None
      else "claim absent - is the entitlements scope on the client?"))
EOF
done
echo
echo "   Compare column 3 against the realm file. A user whose claim is SHORTER"
echo "   than what you wrote hit the multi-element mistake above."
