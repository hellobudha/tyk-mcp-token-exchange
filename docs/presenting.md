# Presenting this — a 30-minute runbook

> **This one is for whoever is at the front of the room.** It carries timings, the lines I actually say, and the things that go wrong. If you're following along with the demo or working through it on your own, you want [walkthrough.md](walkthrough.md) instead — same material, written for you rather than for the presenter.

Six segments to thirty minutes. Everything here has been run; the timings are real.

| | | |
|---|---|---|
| [1](#0000--0300--two-questions-not-one) | 00:00 | Two questions, not one |
| [2](#0300--0700--keycloak-identity-from-a-file) | 03:00 | Keycloak: identity from a file |
| [3](#0700--1200--tyk-configuration-as-kubernetes-objects) | 07:00 | Tyk config as Kubernetes objects |
| [4](#1200--1800--run-it-live) | 12:00 | Run it live — three moves |
| [5](#1800--2700--change-it-live) | 18:00 | Change it live ×3 |
| [6](#2700--3000--close) | 27:00 | Close |

---

## Pre-flight — 10 minutes before

```bash
./scripts/03-port-forward.sh --detach
./scripts/04-test.sh                     # expect 10 passed, 0 failed
./live-demo/whoami.sh                    # expect three users, claims intact
```

Have these tabs open: copilot `localhost:8095`, traces `localhost:16686`, Dashboard `localhost:3000`, Keycloak `acme-keycloak:8280`. Plus two terminals — one for `kubectl`, one tailing the Operator for segment 5 — and the repo open in an editor.

> **Two things that will bite you.** Access tokens live **300 seconds**: if you have been talking a while, re-run a read before the refund so nobody reads an expiry as a bug. And `--detach` keeps the forwards alive across pod restarts, but run `--status` if anything looks dead before assuming worse.

---

## 00:00 – 03:00 · Two questions, not one

Open on a terminal, not the app.

> **Say:** "A support rep asks an AI copilot to look up a customer, and the copilot calls your APIs. Everyone asks the first question: *whose* permissions does that call run with? Almost nobody asks the second: *who gets to change the answer*, and how would you audit it six months later?"

```bash
kubectl get pods -n acme
kubectl get tykoasapidefinition,tykmcpproxydefinition,securitypolicy -n acme
```

> **Say:** "Three resources. That is the entire security posture of this AI agent — who it can act for, which tools it exposes, and what each tool may reach. They are in git, they go through review, and a controller is continuously making the gateway match them."

**Promise three things:** the same request will succeed for one user and fail for another with no code change; you will show the before/after token so nobody takes it on faith; and you will change what a tool is allowed to do live, from a text file.

---

## 03:00 – 07:00 · Keycloak: identity from a file

<http://acme-keycloak:8280>, realm **acme**. Say once that none of this was clicked — the realm is a ConfigMap the pod imports at startup — then walk the console. Full detail in [keycloak.md](keycloak.md).

**Three stops, about a minute each:**

1. **Clients.** Three, and only one is an app. Point at `tyk-mcp-gateway` → **Standard token exchange: enabled**, the toggle that permits everything. Then the oddity: `api.acme.internal` is a client that never logs anyone in — it exists purely to *be* an audience, because Keycloak has no separate concept of a resource.
2. **Users → alice → Attributes.** One custom attribute, `entitlements = "customers:read"`. Bob has read, write and refunds. *This* is what gets enforced, not the groups.
3. **Why the issuer is a hostname you cannot reach normally.** 45 seconds, and it earns them: `KC_HOSTNAME` pins the issuer, so the URL in the token stops being the URL anything dials. Every team hits this when an IdP moves into a cluster.

> **Anticipate:** Keycloak's exchange only accepts a subject token whose `aud` already includes the exchanging client, and only mints an audience its own scopes can produce — hence the two audience mappers. Skip either and you get `Client is not within the token audience`, which does not say which one.

---

## 07:00 – 12:00 · Tyk configuration as Kubernetes objects

The heart of this version. Detail in [tyk-config.md](tyk-config.md).

> **Say:** "In the Docker Compose version of this demo, a bootstrap script creates the APIs, creates a policy, reads back the generated ids and patches them into the APIs. All of that is gone. The custom resource says what should exist; the Operator makes it so, and keeps making it so."

Show the two gates as a table — `acme-mcp-proxy` reads `entitlements`, `acme-api` reads `scope` — then open `data/acme-mcp-proxy.oas.json` and point at four things: the JWKS block, `claimNames: ["entitlements"]`, the `tokenExchange` provider, and the per-tool `mcpTools` map.

**The question you will get:** *"Her token says `customers:all`. Why does a tool needing `customers:read` let her through?"* The answer is in [tyk-config.md](tyk-config.md#the-two-gates) — have it ready, because it is the moment the design either lands or does not.

---

## 12:00 – 18:00 · Run it live

`localhost:8095`, Delegation inspector open. Do not rush the token diff — it is what people remember.

**Move 1 · alice, allowed (3 min).** Sign in as alice, customer `C-1024`, **Look up customer**. Read the inspector's two cards slowly:

| | login token | what the API received |
|---|---|---|
| `sub` | alice | **alice — unchanged** |
| `aud` | tyk-mcp-gateway | **api.acme.internal** |
| `scope` | openid customers:all | **customers:read** |
| `azp` | acme-support-chat | **tyk-mcp-gateway** |

> **Say:** "Same `sub` — her identity survived the hop, so the audit log still names a human. New `aud` — this token is only good at one API. Narrowed `scope` — only the action she asked for. And `azp` now names the gateway: the auditable record of which client acted on her behalf."

Both raw JWTs are click-to-select. If the room is sceptical, paste one into jwt.io.

**Move 2 · alice, denied (2 min).** **Issue refund** → `403`, with the `WWW-Authenticate` challenge and *no token pair*.

> **The subtle bit:** there is no token pair to show **because no token was ever minted**. `refunds:write` is not in alice's entitlements, so Tyk refused at the front gate — the IdP was never contacted and the refund API never saw a request. The cheapest possible denial, and nothing downstream had to be trusted.

**Move 3 · bob, allowed (1 min).** Sign out, sign in as bob, **Issue refund** — succeeds, exchanged `scope` is now `refunds:write`.

> **Land it:** nothing in Tyk, the MCP server or the copilot changed between those two refunds. The only difference is one attribute on one user.

---

## 18:00 – 27:00 · Change it live

The payoff for Kubernetes. Have the Operator log tailing somewhere visible:

```bash
kubectl logs -n tyk deploy/tyk-tyk-operator-controller-manager -f
```

Full copy-paste material in [the exercises](../live-demo/README.md). **A, B and C are the prescribed set** (~7 minutes, leaving slack); D and E are swap-ins for a more technical room.

**A · Tighten a tool's scope** *(no restart, ~2 min)* — change `recent_orders` to require `customers:write`, apply, alice's Recent orders now 403s. Revert.

> **Say:** "No pod restarted. Nobody logged into the Dashboard. I edited a file and the running gateway changed what an AI agent may reach. Now reverse the sentence: that change had to pass through git. There is a commit, an author, a reviewer and a diff — for a change to an agent's permissions."

**B · Add a user with a new tier** *(Keycloak restart, ~3 min)* — paste `dave` into the realm, apply, `kubectl rollout restart deploy/acme-keycloak -n acme`. Four tiers now.

> **Say:** "Nothing in Tyk changed. A whole new tier of agent access is one attribute on one user in the identity provider — which is exactly where it belongs, and who should own it."
>
> **Watch for:** the `entitlements` array mistake (one space-separated string, not a list). `./live-demo/whoami.sh` lints it *before* you restart. And the Keycloak forward dies with the pod — `--status` after.

**C · Turn the exchange off** *(no restart, ~2 min)* — the sceptic's beat. Set `tokenExchange.enabled: false`, apply, run a lookup as alice. The resource API refuses her raw login token with `insufficient_scope`.

> **Say:** "Her login token says `customers:all` — an umbrella the resource API has never heard of. With the exchange off there is no token anywhere in this system that satisfies `customers:read`. That one line of config is the whole mechanism."

**Close the segment:**

> In most agent stacks, "what is this agent allowed to do?" lives in application code, a system prompt, or somebody's console session. Here it is a reviewed artifact in version control, and a controller enforces it continuously. **Agent authorization becomes a change-management problem you already know how to solve.**

> **Do not demo drift repair.** Deleting an API in the Dashboard and waiting for the Operator to restore it does not work reliably — see [the exercises](../live-demo/README.md#do-not-demo-drift-repair).

---

## 27:00 – 30:00 · Close

**Volunteer the caveat before someone finds it:**

> This is RFC 8693 **impersonation**, not delegation. No actor token, no `act` claim — the exchanged token keeps the rep's `sub` and records the gateway only as `azp`. Keycloak, Okta and Auth0 behave this way; Ping and Curity do mint `act`. A cryptographic delegation chain is a choice of identity provider, not of gateway.

**Then prove it does not depend on the browser:**

```bash
./scripts/04-test.sh
```

**Then one trace** at `localhost:16686` — service `acme-support-chat`, newest trace, ~140 spans for a single tool call:

```
acme-support-chat  mcp lookup_customer              the agent's own span
  tyk              POST /json-rpc-method:tools/call MCP understood as a protocol
  tyk              POST /mcp-tool:lookup_customer   a span per tool
  tyk              MCPAccessControlMiddleware       gate 1
  tyk              OAuth2TokenExchangeMiddleware    the exchange, timed
  tyk              GET /anything/customers/C-1024   gate 2
```

> **Say:** "One trace, both gateway hops, and the gateway names the tool rather than logging an opaque POST. You can answer 'which tool is slow, and which agent called it' without instrumenting the agent."
>
> **Be precise:** that exchange span carries no provider, outcome or cache-hit attributes yet. Show the span, do not promise the detail. See [limitations.md](limitations.md).

**Three takeaways:**

> The agent gained no privileges of its own. The rep's identity reached the API intact, so your audit trail still names a person. And every token on the wire was good for one action, one audience, thirty seconds. None of it is application code — it is three Kubernetes resources under review.

---

## If you are short on time

- **Compress segment 2** to the `entitlements` attribute and skip the issuer-pinning stop — fascinating for a platform team, less so for everyone else.
- **In segment 5**, drop to beats A and C: four minutes, no restarts.
- **Never cut** the alice-denied move in segment 4, or segment 5 entirely. The denial and the live change are what people remember.

## Other formats

- **12 minutes:** segments 1, 4 and beat A.
- **45 minutes:** add [keycloak.md](keycloak.md) in full, and exercise D (adding a tool from OpenAPI).
- **Hands-on workshop:** attendees run `scripts/01`–`04` themselves; budget 20 minutes for setup on conference wifi, and warn them the first image build is the slow part.
