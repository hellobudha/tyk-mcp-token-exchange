# Observability and audit

Four surfaces, four different questions. Knowing which answers what saves hunting mid-workshop.

| Where | Answers | URL |
|---|---|---|
| **Delegation inspector** | What did the exchange do to the token? | in the copilot, right-hand side |
| **Jaeger** | What happened, in what order, how long did it take? | <http://localhost:16686> |
| **Log Browser** | What exactly did one call send and receive? | Dashboard → Log Browser |
| **Audit Logs** | Who changed the configuration, and when? | Dashboard → Audit Logs |

---

## Traces

`k8s/observability.yaml` runs **Jaeger all-in-one** in the `acme` namespace. It speaks OTLP natively, so no separate collector is needed: the gateway exports over gRPC (4317), the copilot over HTTP (4318), and both land in one trace. Storage is in-memory — traces are lost on restart, which is right for a workshop and wrong for anything else.

The gateway side is switched on by `01-create-cluster.sh`:

```
--set tyk-gateway.gateway.opentelemetry.enabled=true
--set tyk-gateway.gateway.opentelemetry.exporter=grpc
--set tyk-gateway.gateway.opentelemetry.endpoint=jaeger.acme.svc:4317
```

The copilot side is `OTEL_EXPORTER_OTLP_ENDPOINT` on its Deployment.

### One tool call is one trace

Pick service `acme-support-chat`, newest trace — about 140 spans. What to point at:

| Span | Why it matters |
|---|---|
| `mcp lookup_customer` | the agent's own span, from the copilot |
| `POST /json-rpc-method:tools/call` | the gateway understands MCP as a protocol, not opaque POSTs |
| `POST /mcp-tool:lookup_customer` | **a span per tool**, tagged `tyk.api.name=acme-mcp-proxy` |
| `MCPAccessControlMiddleware` | gate 1 — the per-tool entitlement check |
| `OAuth2TokenExchangeMiddleware` | the RFC 8693 exchange, timed |
| `GET /anything/customers/C-1024` | gate 2 — the second gateway hop, narrowed token |

The trace is continuous because the copilot injects W3C context into **both** the HTTP `traceparent` header and the MCP body's `params._meta`. That second channel is what lets the tool server join the same trace rather than starting its own.

> **One caveat, stated precisely.** The `OAuth2TokenExchangeMiddleware` span exists and is timed, but carries no exchange-specific attributes — no provider, outcome or cache-hit status, and no `tyk_oauth2_exchange_*` metrics. Still true on 5.15. Show the span; do not promise the attributes.

---

## What the agent did — the runtime audit

```bash
./live-demo/activity.sh              # everyone, last 30 minutes
./live-demo/activity.sh carol        # one person
./live-demo/activity.sh carol 120    # one person, last two hours
```

```
when      user      tool              outcome                       trace
16:19:25  carol     issue_refund      DENIED (insufficient scope)   53dc9c1389e8321e
16:17:28  carol     update_customer   allowed                       2d7fb06673bd4d36
16:17:28  carol     lookup_customer   allowed                       fdcba28d66c2451b
```

### Why this reads traces and not analytics

> **MCP proxy APIs emit no Tyk analytics records — on 5.14 or 5.15.** Verified by counting `tyk_analytics` rows across a denied call: zero new records. Only the downstream `acme-api` hop is recorded, so the traffic log shows the *successes* that reached the resource API and is blind to every refusal at gate 1 — which is exactly the event you most want audited.
>
> The gateway's spans carry both `tyk.api.apikey.alias` (who) and `mcp.tool.name` (which tool) for allowed *and* denied calls, so the trace data is the complete record.

`identityBaseField: preferred_username` on both APIs is what makes the alias read `carol` rather than a `sub` UUID. See [tyk-config.md](tyk-config.md#inside-gate-1--dataacme-mcp-proxyoasjson).

### The successes, in full detail

For calls that did reach the resource API, the Dashboard's **Log Browser** has everything: request and response dumps, the policy and API tags, and a `trace-id-…` tag linking the log line to its Jaeger trace.

Because `detailedActivityLogs` is on, the request dump includes the **exchanged token that was actually presented** — the narrowed one, not the rep's login token. That is a strong thing to point at: the evidence of least privilege is in the log itself.

Directly from Postgres, if you prefer a terminal:

```bash
PGPASS=workshop
kubectl exec -n tyk deploy/tyk-postgres -- env PGPASSWORD="$PGPASS" \
  psql -U postgres -d tyk_analytics -c \
  "SELECT timestamp, alias AS who, method, path, responsecode
     FROM tyk_analytics ORDER BY timestamp DESC LIMIT 10;"
```

---

## What changed — the configuration audit

Audit logging is enabled by `01-create-cluster.sh`, with detailed recording on, stored in Postgres. Every change the Operator makes to the Dashboard is recorded: create, update and delete of APIs, MCP proxies and policies, with timestamp, method, URL and status.

**Dashboard → Audit Logs.** Put `/api/mcps` in the URL filter first — unfiltered, the Dashboard's own polling drowns everything else.

| User | Action | Method | URL | IP |
|---|---|---|---|---|
| admin@acme.example | **Update MCP Proxy** | PUT | `/api/mcps/YWNtZS9hY21lLW1jcC1wcm94eQ` | `10.244.0.12` |

Click **Details** for the full record, including `request_dump` — the exact document the Operator sent.

Two things to say while it is on screen:

- **The IP tells you who acted.** The Operator's pod IP versus `127.0.0.1` for a human clicking in the Dashboard. You can separate reconciliation from hand-editing at a glance.
- **The actor is the Operator's Dashboard user, not the engineer.** So: **Tyk's audit log says what changed and when; git says who asked and why.** Neither is sufficient alone. For sharper attribution, give the Operator its own Dashboard user so its changes are distinguishable from a human's.

From a terminal:

```bash
kubectl exec -n tyk deploy/tyk-postgres -- env PGPASSWORD=workshop \
  psql -U postgres -d tyk_analytics -c \
  "SELECT date, \"user\", action, method, status FROM audit_records
     ORDER BY timestamp DESC LIMIT 10;"
```

---

## The distinction, in one table

| Question | Source | How |
|---|---|---|
| What did carol's copilot do? | gateway traces | `./live-demo/activity.sh carol` |
| What exactly did one call send? | analytics + detailed logs | Dashboard → Log Browser |
| What configuration changed? | Dashboard audit log | Dashboard → Audit Logs |
| Who asked for that change, and why? | **git** | `git log data/` |

The last row is the one people forget, and it is the only one that answers *why*.
