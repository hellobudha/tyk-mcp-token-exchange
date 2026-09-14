# The AI agent that can't exceed its user's permissions

A support rep asks an AI copilot to pull up a customer record. The copilot calls your API. Somewhere in that single hop, a question gets answered that most teams have never sat down and decided: whose permissions did that call run with?

The usual answer is the service account the agent was built with. Which means the new hire on their second day and the supervisor with refund authority are, as far as your API is concerned, the same caller. Everything the agent can reach, everyone who talks to the agent can reach.

I built this workshop to show a different answer, and to let you break it yourself.

You'll stand up a support copilot that calls APIs on behalf of a signed-in person, and watch the gateway swap that person's broad login token for a narrow one, minted per tool call, scoped to a single action, good for thirty seconds. The same refund request succeeds for one user and gets refused for another, with zero code change between them. The only difference is one attribute on one user.

It all runs locally in one Kubernetes cluster. Setup takes about fifteen minutes, most of it waiting for images to pull.

**Presenting this?** [`docs/presenting.md`](docs/presenting.md) is a 30-minute runbook with measured timings and what to say at each beat.

**Want the room to build it rather than watch it?** [agent-authorization-lab](https://github.com/hellobudha/agent-authorization-lab) is the two-hour hands-on version: the same system, in six labs, starting from an agent with no protection at all.

| If you want | Read |
|---|---|
| To run it | this file, top to bottom |
| The identity model: clients, scopes, mappers, users | [`docs/keycloak.md`](docs/keycloak.md) |
| The gateway config: two gates, the exchange, Operator gotchas | [`docs/tyk-config.md`](docs/tyk-config.md) |
| To change things while it runs | [`live-demo/README.md`](live-demo/README.md) |
| Traces and the two audit trails | [`docs/observability.md`](docs/observability.md) |
| What doesn't work, honestly | [`docs/limitations.md`](docs/limitations.md) |
| To present it | [`docs/presenting.md`](docs/presenting.md) |

---

## What you will build

```mermaid
flowchart LR
    subgraph acme["namespace: acme — the application"]
        BROWSER["Rep's browser"]
        CHAT["acme-chat<br/><i>the copilot</i>"]
        KC["acme-keycloak<br/><i>identity provider</i>"]
        MCP["acme-mcp-server<br/><i>the tools</i>"]
        UP["httpbin<br/><i>stands in for the real API</i>"]
    end

    subgraph tyk["namespace: tyk — the platform"]
        GW["Tyk Gateway<br/><b>gate 1</b> acme-mcp-proxy<br/><b>gate 2</b> acme-api"]
        DASH["Dashboard"]
        OP["Tyk Operator"]
    end

    BROWSER -->|1 · sign in| KC
    BROWSER -->|2 · run a tool| CHAT
    CHAT -->|3 · MCP call + login token| GW
    GW <-->|4 · exchange the token| KC
    GW -->|5 · narrowed token| MCP
    MCP -->|6 · call the API| GW
    GW -->|7 · forward| UP
    OP -->|config| DASH
    DASH -->|broadcast| GW
```

Every tool call crosses the gateway **twice**. That's deliberate, and it's the heart of the design. I explain why in [The two gates](#the-two-gates).

| Component | What it is | Its job |
|---|---|---|
| `acme-chat` | Small Go web app | The copilot. Signs the rep in and calls tools for them. |
| `acme-keycloak` | Keycloak 26 | Holds the users, issues tokens, performs the exchange. |
| `acme-mcp-proxy` | Tyk API definition | **Gate 1.** Checks the person may use this tool, then swaps their token. |
| `acme-mcp-server` | Go MCP server | Exposes one tool per operation in an OpenAPI file. Enforces nothing. |
| `acme-api` | Tyk API definition | **Gate 2.** Checks the arriving token is good for this exact operation. |
| `httpbin` | Test server | Stands in for the real API. Echoes requests back, so you can see the token. |
| `jaeger` | Tracing backend | Collects traces from the copilot and the gateway. |
| Tyk Operator | Kubernetes controller | Applies the Tyk configuration from Kubernetes objects. |

---

## Before you start

Three things:

- **Docker** running, with about 6 GB available to it
- **kind**, **kubectl** and **helm** on your PATH
- **A Tyk licence with an enterprise scope.** Token exchange is an enterprise feature. On a standard gateway the middleware does nothing and the workshop has nothing to show.

```bash
cp .env.example .env
# put your licence in .env as TYK_LICENSE=...
```

---

## Step 0 — one hosts entry

```bash
sudo ./scripts/00-hosts.sh
```

<details><summary><b>Why this is needed</b></summary>

Keycloak pins its issuer to `http://acme-keycloak:8280`, so every token it mints carries that issuer whatever network path reached it. Inside the cluster that name resolves through Kubernetes DNS. Your browser has to reach Keycloak at **the same URL**, or the login redirect points somewhere that exists only inside the cluster. Hence one line in `/etc/hosts` aimed at the port-forward.

This is the first thing most teams hit when they move an identity provider into a cluster: **the URL in the token stops being the URL anything dials.** Issuer identity and network reachability are separate concerns, and this is where you find that out.
</details>

---

## Step 1 — cluster and control plane

```bash
./scripts/01-create-cluster.sh
```

Creates a kind cluster, installs cert-manager (the Operator's admission webhook depends on it), then Redis, PostgreSQL, and the Tyk stack: Dashboard, Gateway, Pump and Operator. Give it 5 to 10 minutes on a first run.

None of this is workshop-specific. It's the platform everything else deploys onto, and it's idempotent, so re-run it if it stops halfway.

<details><summary><b>What it turns on, and why</b></summary>

- **The enterprise gateway image** (`tyk-gateway-ee`), because token exchange lives there.
- **OpenTelemetry export** to `jaeger.acme.svc:4317`, so the gateway's spans join the copilot's traces.
- **Audit logging with detailed recording**, so every configuration change the Operator makes is recorded with its request body.
- **The developer portal stays off.** The workshop has no use for it, and leaving it out saves a pod.

It finishes by restarting the gateway. That's superstition-free: the gateway registers with the Dashboard at boot, and if it wins that race it comes up having loaded zero APIs.
</details>

---

## Step 2 — deploy the workshop

```bash
./scripts/02-deploy.sh
```

Builds the two Go services, loads them into the cluster, and applies everything with `kubectl apply -k .`.

**Look at what this script never does:** it never calls the Tyk API. The gateway configuration gets applied exactly the way the Deployments do, as Kubernetes objects, and the Tyk Operator reconciles them into the Dashboard, which broadcasts to the gateways.

```mermaid
flowchart LR
    GIT["your edit<br/><i>a file in git</i>"] -->|kubectl apply| K8S["Kubernetes API<br/><i>ConfigMap + custom resource</i>"]
    K8S -->|watches| OP["Tyk Operator"]
    OP -->|pushes config| DASH["Dashboard"]
    DASH -->|broadcasts| GW["Gateways"]
    OP -.->|"compares desired vs actual, forever"| K8S
```

Three objects hold the entire security posture of this agent:

| Object | What it configures |
|---|---|
| `TykMcpProxyDefinition/acme-mcp-proxy` | Gate 1, the MCP front door, per-tool rules, and the exchange |
| `TykOasApiDefinition/acme-api` | Gate 2, the resource API and its per-operation scope checks |
| `SecurityPolicy/acme-demo-default` | Grants access to both, so JWT auth has a policy to attach |

```bash
kubectl get tykoasapidefinition,tykmcpproxydefinition,securitypolicy -n acme
```

---

## Step 3 — open the ports

```bash
./scripts/03-port-forward.sh --detach     # survives closing the terminal
```

Each forward is supervised and restarts on its own. `kubectl port-forward` exits for good the moment it loses its pod, whether that's a rollout, an eviction, or a laptop going to sleep. An unsupervised forward leaves you with a script that's still running and an endpoint that's quietly dead, which is a miserable thing to discover with an audience watching.

```bash
./scripts/03-port-forward.sh --status    # is each endpoint actually up?
./scripts/03-port-forward.sh --stop      # stop a detached run
```

Drop `--detach` for the old foreground behaviour, where ctrl-c stops everything.

| | |
|---|---|
| Copilot | <http://localhost:8095> |
| Keycloak admin | <http://acme-keycloak:8280> — `admin` / `admin` |
| Tyk Dashboard | <http://localhost:3000> — `admin@acme.example` / `Workshop-2026!` |
| Traces | <http://localhost:16686> |

> With `--detach` these survive both the terminal closing and a pod restarting. When the copilot stops responding mid-workshop, run `--status` first. It's usually the answer.

---

## Step 4 — prove it works

```bash
./scripts/04-test.sh
```

You want `10 passed, 0 failed`. It signs in as a genuine user, runs a genuine tool call through the gateway, decodes the token that arrived at the other end, and asserts the claims changed the way they should.

Run it before you present. It's the fastest way to know the whole chain is healthy.

---

## Now walk through it

Open <http://localhost:8095> and sign in. Three users, all with password `Acme-Demo-2026!`:

| User | Entitlements | Look up | Update | Refund |
|---|---|---|---|---|
| **alice** | `customers:read` | ✅ | ❌ | ❌ |
| **carol** | `customers:read customers:write` | ✅ | ✅ | ❌ |
| **bob** | `customers:read customers:write refunds:write` | ✅ | ✅ | ✅ |

### 1. As alice, look up a customer

It works. Now slow down and read the **Delegation inspector** on the right. This is the moment the whole workshop exists for.

| | alice's login token | what the API received |
|---|---|---|
| `sub` | alice | **alice — unchanged** |
| `aud` | tyk-mcp-gateway | **api.acme.internal** |
| `scope` | openid customers:all | **customers:read** |
| `azp` | acme-support-chat | **tyk-mcp-gateway** |

- **`sub` unchanged.** Her identity survived the hop, so your audit trail still names a human being.
- **`aud` re-pointed.** Exactly one API will accept this token.
- **`scope` narrowed.** From an umbrella down to the single action she asked for.
- **`azp` now the gateway.** The record of *which system* acted on her behalf.

Both raw JWTs sit in the inspector, click-to-select. When someone in the room looks sceptical, paste one into jwt.io and let them read it themselves.

### 2. As alice, issue a refund

`403`. And notice what the inspector leaves blank: there's no token pair, **because no token was ever minted**. `refunds:write` is missing from alice's entitlements, so gate 1 refused before Keycloak was ever contacted. The refund API never saw a request.

That's a preventive control. Most access control you meet in the wild is detective.

### 3. As bob, issue a refund

It succeeds, and the exchanged token now carries `refunds:write`, a different capability minted for that one call.

**Nothing in Tyk, the MCP server or the copilot changed between those two refunds.** One attribute on one user in the identity provider, and that's the whole difference.

---

## The two gates

The gateway checks twice, against two *different* claims. This is the part people miss, and it's worth dwelling on.

```mermaid
flowchart LR
    REQ["request<br/><i>login token</i>"] --> G1
    G1["<b>GATE 1</b><br/>acme-mcp-proxy<br/>May this <i>person</i><br/>use this tool?<br/>reads: entitlements"] --> EX["token<br/>exchange"]
    EX --> G2["<b>GATE 2</b><br/>acme-api<br/>May this <i>token</i><br/>do this operation?<br/>reads: scope"]
    G2 --> UP["upstream"]
    G1 -->|no| D1["403 — no token minted"]
    G2 -->|no| D2["403 — token insufficient"]
```

| Gate | Question | Claim it reads |
|---|---|---|
| `acme-mcp-proxy` | May this **person** use this tool? | `entitlements`, per person, stamped by the IdP |
| `acme-api` | May this **token** do this operation? | `scope`, per call, narrowed by the exchange |

**The question I get asked every single time:** *"Her token says `customers:all`. Why does a tool needing `customers:read` let her through?"*

Because gate 1 never looks at `scope`. `customers:all` is the umbrella the **application** requested at login. It describes what the app asked for, which has nothing to do with what the person is permitted. Gate 1 reads `entitlements`, which comes from her user record and which the app has no way to inflate. Keycloak then grants the narrow scope during the exchange because the gateway's own client is allowed to request it, and for no other reason.

---

## The flow, in order

```mermaid
sequenceDiagram
    participant C as Copilot
    participant G1 as Tyk · gate 1
    participant KC as Keycloak
    participant M as Tool server
    participant G2 as Tyk · gate 2

    C->>G1: tools/call "issue_refund" + login token
    G1->>G1: may this person? reads entitlements
    G1->>KC: RFC 8693 exchange — audience + one scope
    KC-->>G1: narrowed token, same sub
    G1->>M: run the tool, carrying the narrowed token
    M->>G2: POST /refunds, same token
    G2->>G2: may this token? reads scope
    G2-->>C: result travels back
```

The copilot never holds the narrowed token. It's minted inside the gateway, used for one hop, and cached there for thirty seconds at most.

---

## Change it live

This is why it runs on Kubernetes. Each of these is an edit to a file followed by `kubectl apply -k .`. Three of six are below. All six, with copy-paste JSON, are in [`live-demo/README.md`](live-demo/README.md), including **adding a user with a new permission tier**, which is the one that best shows where agent authorization belongs.

### Tighten a tool — no restart, ~20 seconds

In `data/acme-mcp-proxy.oas.json`, under `middleware.mcpTools`:

```json
"recent_orders": { "security": [{ "oauth2": ["customers:write"] }], ... }
```

```bash
kubectl apply -k .
```

Alice's **Recent orders**, which worked a minute ago, now returns `403`. Revert and it works again.

No pod restarted. Nobody logged into the Dashboard. And the change went through code review, because it was a file.

### Turn the exchange off — the sceptic's beat

```json
"tokenExchange": { "enabled": false, ... }
```

Apply, then run **Look up customer** as alice. Tyk forwards her raw login token to the resource API, which refuses it:

```json
{ "error": "insufficient_scope",
  "error_description": "token does not satisfy required scopes: customers:read" }
```

Her login token says `customers:all`, an umbrella the resource API has never heard of. Turn the exchange off and **no token anywhere in this system satisfies `customers:read`**. That one line of config is the entire mechanism, which is the point I want the sceptic to leave with.

### Add a tool from an OpenAPI file

The tools are generated from the contract, never hand-written. Add an operation to `data/acme-api.oas.json`, add a matching rule to `data/acme-mcp-proxy.oas.json`, then:

```bash
kubectl apply -k . && kubectl rollout restart deploy/acme-mcp-server -n acme
```

The copilot discovers tools over MCP, so the new one shows up as a button, already governed by both gates, with zero changes to the application. See [`live-demo/README.md`](live-demo/README.md) for the exact JSON.

---

## Who did what

Two different audit questions, and they have two different sources. Keeping them straight is worth your time.

```bash
./live-demo/activity.sh carol      # what this person's copilot did, refusals included
./live-demo/whoami.sh              # what each user's token actually claims
```

```
when      user      tool              outcome
16:19:25  carol     issue_refund      DENIED (insufficient scope)
16:17:28  carol     update_customer   allowed
16:17:28  carol     lookup_customer   allowed
```

> **Why this reads traces and skips analytics.** MCP proxy APIs emit no Tyk analytics records on 5.14 or 5.15, so the traffic log only sees calls that reached the *resource* API. It's blind to every refusal at gate 1, which is precisely the event you most want audited. The gateway's spans carry both the user and the tool name for allowed and denied calls alike, so the trace data is the complete record.

For configuration changes, the Dashboard's **Audit Logs** view records everything the Operator does. Filter the URL by `/api/mcps` to cut the noise. The actor is the Operator's Dashboard user, which leaves you with a useful division of labour: **Tyk's audit log says what changed and when; git says who asked and why.**

---

## Repository layout

```
├── data/                    the three documents that define everything
│   ├── realm-acme.json        users, clients, scopes, protocol mappers
│   ├── acme-api.oas.json      gate 2 + the source of the MCP tools
│   └── acme-mcp-proxy.oas.json  gate 1 + the exchange
├── k8s/                     Kubernetes manifests and the three Tyk resources
├── services/                the copilot and the MCP tool server (Go)
├── scripts/                 numbered, run in order
├── live-demo/               the six change-live exercises and audit helpers
├── docs/                    identity model, gateway config, observability,
│                              limitations, and the presenter runbook
├── platform/                redis + postgres for the control plane
└── kustomization.yaml       kubectl apply -k .
```

---

## Troubleshooting

Everything in this table has happened to me at least once.

| Symptom | Cause | Fix |
|---|---|---|
| Copilot or Dashboard unreachable | a forward died, or was never started | `./scripts/03-port-forward.sh --status`, then `--detach` |
| `403 Access disallowed` on everything | the policy didn't reconcile | check `.status.pol_id` on the SecurityPolicy; `02-deploy.sh` nudges it for you |
| Every route 404s | the gateway registered before the Dashboard was up | `kubectl rollout restart deploy/gateway-tyk-tyk-gateway -n tyk` |
| `ImagePullBackOff` on chat or mcp-server | images not on the node | re-run `./scripts/02-deploy.sh` |
| Login redirects somewhere unreachable | no hosts entry, or 8280 not forwarded | `sudo ./scripts/00-hosts.sh`, then re-run the port-forwards |
| A new user behaves like an existing one | `entitlements` written as multiple array elements | it must be **one space-separated string**. `./live-demo/whoami.sh` detects this |
| `403` everywhere after restarting Keycloak | realm signing key rotated, gateway holds a stale JWKS | shouldn't happen, the key is pinned in the realm. If it does, restart the gateway |
| API CR shows `latestTransaction.status: Failed` | the Dashboard rejected the document | read `.status.latestTransaction.error`, it names the field |

---

## What this does not do

I'd rather you hear these from me than find them yourself halfway through a demo. The full list, with the operational sharp edges, is in [`docs/limitations.md`](docs/limitations.md).

- **The tool list is not filtered per user.** `tools/list` returns every tool to alice, including `issue_refund`, which she cannot call. Enforcement happens when a tool is *invoked*, not when it's discovered. The catalogue describes the API surface; it makes no authorization decision. Filtering it would be a usability improvement rather than a security one, since hiding a tool the gateway already refuses buys obscurity and calls it a control.
- **This is impersonation, not delegation.** The exchanged token keeps the rep's `sub` and records the gateway only as `azp`. RFC 8693 also describes a formal actor chain via an `act` claim. Keycloak's standard token exchange mints no `act`, and neither do Okta or Auth0. Ping and Curity do. If your compliance model needs a cryptographic delegation chain, that's a choice of identity provider rather than a choice of gateway.
- **The identity provider sits on the critical path.** Keycloak goes down, tool calls fail. That's the honest trade for keeping zero long-lived credentials anywhere in the system, and you should make that trade deliberately.
- **Exchange-specific telemetry is thin.** The exchange middleware produces a timed span, with no provider, outcome or cache-hit attributes yet. Show the span; promise nothing beyond it.

---

## What I want you to take from this

Token exchange is the mechanism here, and it's the part that demos well. It's also the part I care about least.

The thing worth carrying out of this repo is where the answer lives. "What is this agent allowed to do?" is a question that, in most stacks I've seen, gets answered inside application code, or in a system prompt, or in somebody's browser tab at 4pm on a Friday. Here it's three Kubernetes resources under version control, and a controller that spends its life making the running gateway match them.

Change what the agent may reach and you've opened a pull request. There's a diff, an author, a reviewer, and a date. Six months later, when someone asks why an AI agent was able to issue that refund, you have an answer with a name on it.

---

## License

[Apache-2.0](LICENSE). Run it, fork it, adapt it, teach from it. That goes for the exercises, the Tyk and Keycloak configuration, and both Go services.

The credentials in this repository (`Acme-Demo-2026!`, `Workshop-2026!`, `acme-demo-exchange-secret`) are fixtures for a local kind cluster, published on purpose so the workshop runs with no setup. They're safe to read and useless anywhere else. Your Tyk licence is the one thing you supply yourself, in `.env`, which is gitignored.

---

## Tear it down

```bash
./scripts/99-teardown.sh             # remove the workshop, keep the cluster
./scripts/99-teardown.sh --cluster   # delete everything
```
