# Exercises — changing the running system

Six exercises, each one an edit to a file followed by `kubectl apply -k .`. Every one was run end to end against this repo; the timings are what they actually took.

Keep the repo open in an editor with a terminal beside it. Your escape hatch at any point:

```bash
git checkout data/ && kubectl apply -k .
```

| # | Exercise | Restart? | Time |
|---|---|---|---|
| [1](#1--tighten-a-tools-scope) | Tighten a tool's scope | no | ~20s |
| [2](#2--add-a-user-with-a-new-permission-tier) | Add a user with a new permission tier | Keycloak | ~40s |
| [3](#3--turn-the-exchange-off) | Turn the exchange off | no | ~20s |
| [4](#4--add-a-tool-from-an-openapi-file) | Add a tool from an OpenAPI file | MCP server | ~30s |
| [5](#5--rate-limit-the-agent) | Rate limit the agent | no | ~20s |
| [6](#6--read-the-audit-trail) | Read the audit trail | no | ~1m |

---

## 1 · Tighten a tool's scope

The cheapest exercise, and the one that shows reconciliation most directly.

In `data/acme-mcp-proxy.oas.json`, under `x-tyk-api-gateway.middleware.mcpTools`:

```json
"recent_orders": { "security": [{ "oauth2": ["customers:write"] }], ... }
```

```bash
kubectl apply -k .
```

Alice's **Recent orders** — which worked a minute ago — now returns `403`. Revert and it works again.

Watch it land:

```bash
kubectl get tykmcpproxydefinition acme-mcp-proxy -n acme -o jsonpath='{.status.latestTransaction}' | jq
kubectl logs -n tyk deploy/tyk-tyk-operator-controller-manager -f
```

**The point:** no pod restarted, nobody logged into the Dashboard, and the change was a file — so it went through code review. Say that sentence out loud; it is the argument.

---

## 2 · Add a user with a new permission tier

The workshop ships three tiers. This adds a fourth: someone who can issue refunds but cannot change customer records — a refunds specialist.

Paste into the `users` array in `data/realm-acme.json`. Copy the `credentials` block from alice so the password is `Acme-Demo-2026!`:

```json
{
  "username": "dave",
  "enabled": true,
  "createdTimestamp": 1772451000000,
  "email": "dave@acme.example",
  "emailVerified": true,
  "firstName": "Dave",
  "lastName": "Acme",
  "credentials": [ <<< copy alice's credentials block >>> ],
  "groups": ["/acme-support"],
  "attributes": { "entitlements": ["customers:read refunds:write"] }
}
```

> ### The mistake everyone makes
>
> `entitlements` is an array containing **exactly one space-separated string**, not a list of separate scopes. The realm's mapper is single-valued (`jsonType.label: String`, no `multivalued` flag), so Keycloak keeps only the **first** array element and silently drops the rest:
>
> ```json
> "entitlements": ["customers:read", "refunds:write"]   // WRONG — dave gets customers:read only
> "entitlements": ["customers:read refunds:write"]      // right
> ```
>
> The failure is quiet and looks exactly like a restart that did not happen: dave imports, signs in, and behaves like alice. Lint it before you restart anything:
>
> ```bash
> ./live-demo/whoami.sh
> ```

Then:

```bash
kubectl apply -k .
kubectl rollout restart deploy/acme-keycloak -n acme
kubectl rollout status  deploy/acme-keycloak -n acme
./scripts/03-port-forward.sh --status     # the Keycloak forward dies with the pod
```

The supervisor restarts that forward on its own, but there is a few-second gap while the new pod becomes ready. If a command fails with *"could not sign in"* immediately after the restart, wait for Keycloak to serve and try again:

```bash
until curl -sf http://acme-keycloak:8280/realms/acme/.well-known/openid-configuration >/dev/null; do sleep 3; done
```

<details><summary><b>Why a restart is needed, and why that is safe</b></summary>

Keycloak imports the realm at startup and only against an empty database. This deployment gives it no persistent volume, so a new pod means a new database, which means the realm is re-imported from the ConfigMap.

That would normally be dangerous: a fresh database also means **new realm signing keys**, and the gateway would still be holding the old JWKS — every user would start failing with `403` and `no matching KID found in any JWKs`. The realm pins a static RSA key (`acme-static-rsa` in `components`) precisely so the `kid` survives restarts. Do not remove it.
</details>

Sign in as dave and run all four tools. The verified result:

| user | lookup | update | refund |
|---|---|---|---|
| alice | 200 | 403 | 403 |
| carol | 200 | 200 | 403 |
| **dave** | **200** | **403** | **200** |
| bob | 200 | 200 | 200 |

**The point:** nothing in Tyk changed. No tool was redefined, no policy edited, no gateway reloaded. A whole new tier of agent access is one attribute on one user in the identity provider — which is exactly where it belongs, and who should own it.

---

## 3 · Turn the exchange off

The exercise for a sceptical engineer: prove the exchange does real work rather than decorating the request.

In `data/acme-mcp-proxy.oas.json`:

```json
"tokenExchange": { "enabled": false, ... }
```

Apply, then run **Look up customer** as alice. Tyk now forwards her raw login token to the resource API, which refuses it:

```json
{ "error": "insufficient_scope",
  "error_description": "token does not satisfy required scopes: customers:read",
  "scope": "customers:read" }
```

Her login token carries `scope: openid customers:all` — an umbrella the resource API has never heard of. **Without the exchange there is no token in the system that satisfies `customers:read`**, so the call dies at the back gate. Re-enable, apply, it works.

---

## 4 · Add a tool from an OpenAPI file

Shows the connector story: the MCP surface is generated from the API contract you already publish.

Add the operation to `data/acme-api.oas.json` under `paths`:

```json
"/anything/customers/{customer_id}/notes": {
  "get": {
    "operationId": "customerNotes",
    "summary": "Recent support notes for a customer",
    "parameters": [{ "name": "customer_id", "in": "path", "required": true,
                     "schema": { "type": "string" },
                     "description": "Acme customer reference, e.g. C-1024" }],
    "security": [{ "oauth2": ["customers:read"] }],
    "responses": { "200": { "description": "ok" } }
  }
}
```

…and its scope check in the same file, under `x-tyk-api-gateway.middleware.operations`:

```json
"customerNotes": { "scopeCheck": { "enabled": true } }
```

Then the matching tool rule in `data/acme-mcp-proxy.oas.json`, under `middleware.mcpTools`:

```json
"customer_notes": {
  "security": [{ "oauth2": ["customers:read"] }],
  "scopeCheck": { "enabled": true },
  "exchange": { "enabled": true }
}
```

```bash
kubectl apply -k .
kubectl rollout restart deploy/acme-mcp-server -n acme   # tools are read from the spec at boot
```

Three things worth pointing out:

- **The tool name is derived, not declared.** `customerNotes` → `customer_notes`, snake_case of the `operationId`. The `mcpTools` key must match that derivation exactly or the gateway will not gate the tool.
- **`parameters` becomes the tool's input schema.** That is what the agent sees when it decides how to call it.
- **Both files are needed.** `acme-api.oas.json` creates the tool *and* the governed upstream route; `acme-mcp-proxy.oas.json` is what makes gate 1 check entitlements and mint a narrowed token for it. Skip the second and the tool exists ungoverned.

**The copilot picks it up on its own.** It renders one button per tool returned by MCP `tools/list`, and builds the arguments from each tool's advertised schema — so a new operation appears as a new button with no change to the application. Reload and **Customer notes** is there, already gated.

```bash
./live-demo/list-tools.sh alice customer_notes
```

---

## 5 · Rate limit the agent

The policy is a Kubernetes object too. Append to `spec` in `k8s/tyk-security-policy.yaml`:

```yaml
  rate: 3
  per: 10
  quota_max: -1
```

Apply, then click chat buttons quickly — `429` almost immediately.

> Say it accurately: Tyk's limiter is a leaky bucket, so `rate: 3 / per: 10` means roughly one call every three seconds, not a burst of three then a failure. Describe it as "a rapid burst gets rate limited", not "the fourth call fails" — someone will count.

---

## 6 · Read the audit trail

Two different questions, two different sources. Do not conflate them.

**What did this person's copilot do?**

```bash
./live-demo/activity.sh carol
```

```
when      user      tool              outcome
16:19:25  carol     issue_refund      DENIED (insufficient scope)
16:17:28  carol     update_customer   allowed
16:17:28  carol     lookup_customer   allowed
```

This reads **traces, not analytics**, and the reason matters: MCP proxy APIs emit no Tyk analytics records on 5.14 or 5.15. The traffic log only sees calls that reached the *resource* API, so it is blind to every refusal at gate 1 — exactly the event you most want audited. The gateway's spans carry both `tyk.api.apikey.alias` (who) and `mcp.tool.name` (which tool) for allowed *and* denied calls.

**What configuration changed, and when?**

Tyk Dashboard → **Audit Logs**. Put `/api/mcps` in the URL filter first, or the Dashboard's own polling drowns it. After exercise 1 you will see:

| User | Action | Method | IP |
|---|---|---|---|
| admin@acme.example | **Update MCP Proxy** | PUT | `10.244.0.x` |

Click **Details** for the full record. Because detailed recording is on, `request_dump` contains the exact document the Operator sent — including the scope you just changed.

Two things to point at:

- **The IP tells you who acted.** The Operator's pod IP versus `127.0.0.1` for a human clicking in the Dashboard. You can separate reconciliation from hand-editing at a glance.
- **The actor is the Operator's Dashboard user**, not the engineer. So: **Tyk's audit log says what changed and when; git says who asked and why.** Neither is sufficient alone, and together they answer the question the workshop opened with.

---


Recovery meant deleting and recreating the CR, which then blocked on the `SecurityPolicy` reference. Leave this one out.
