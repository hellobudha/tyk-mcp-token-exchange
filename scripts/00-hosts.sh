#!/bin/bash
# Step 0 — add the hosts entry the browser needs.
#
# Keycloak pins its issuer to http://acme-keycloak:8280 so that every token
# carries the same issuer no matter which network path reached it. Inside the
# cluster that name resolves via Kubernetes DNS; on your laptop it needs a hosts
# entry pointing at the port-forward.
#
#   sudo ./scripts/00-hosts.sh
set -euo pipefail
ENTRY="127.0.0.1	acme-keycloak"
HOSTS=/etc/hosts

if grep -qE '^\s*127\.0\.0\.1\s+acme-keycloak\s*$' "$HOSTS"; then
  echo "Already present in $HOSTS — nothing to do."
  exit 0
fi
[ "$(id -u)" -eq 0 ] || { echo "Needs root: sudo $0" >&2; exit 1; }

cp "$HOSTS" "$HOSTS.acme-workshop.bak"
printf '\n# added by acme-copilot-workshop\n%s\n' "$ENTRY" >> "$HOSTS"
echo "Added:   $ENTRY"
echo "Backup:  $HOSTS.acme-workshop.bak"
