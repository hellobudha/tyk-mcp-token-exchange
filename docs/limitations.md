# What this does not do

Every item here was hit while building and verifying this workshop. Say them before someone in the room finds them — a group that spots you glossing over a limitation stops trusting the rest.

---

## Impersonation is not delegation

The exchanged token keeps the rep's `sub` and records the gateway only as `azp`. RFC 8693 also describes **delegation**, where the new token carries a separate `act` ("actor") claim naming the acting party in a formal, nestable chain.

**Keycloak's standard token exchange does not mint `act`.** Neither do Okta or Auth0. Ping and Curity do.

This matters more than it sounds. With `azp` you can say *"the gateway acted, and here is the person it acted for."* With `act` you can prove a chain cryptographically, which is what some compliance models want. If that is your requirement, it is a choice of identity provider — not something a gateway can add.

---

## The identity provider is on the critical path

If Keycloak is down, tool calls fail. The exchange happens inline, per tool call.

That is the honest trade for having no long-lived credentials anywhere in the system. The 30-second derived cache absorbs bursts, not outages. If you need to survive IdP downtime you are choosing between availability and standing access, and you should make that choice deliberately rather than discovering it.

---

## Exchange-specific telemetry is thin

`OAuth2TokenExchangeMiddleware` produces a timed span, so you can see the exchange happen and how long it took. It carries **no** provider, outcome or cache-hit attributes, and there are no `tyk_oauth2_exchange_*` metrics.

Still true on 5.15. You can show the span. Do not promise the detail.

---

## MCP proxy APIs emit no analytics records

Verified by counting `tyk_analytics` rows across a denied call: zero new records, on both 5.14 and 5.15.

Only the downstream `acme-api` hop is recorded, which means **the traffic log is blind to every refusal at gate 1** — the event you most want audited. This is why [`activity.sh`](../live-demo/activity.sh) reads traces instead. It works, and it is a workaround.

---

## Drift is not repaired

The Operator does not reliably restore an API deleted out of band.

Observed on this stack: an MCP proxy was deleted directly in the Dashboard, the custom resource continued reporting `Successful` because the Operator's cached spec hash still matched what it believed it had written, and it was never recreated. An annotation nudge does not help — `TykMcpProxyDefinition` ignores metadata-only changes.

Recovery meant deleting and recreating the CR, which then blocked on the `SecurityPolicy` reference and required removing that reference first.

**Do not demo this.** "Delete it in the console and watch it come back" is a great operator beat and it will not work here.

---

## Operator CR-level override fields are broken for this combination

On Operator v1.4.2 against Dashboard v5.14/5.15:

- `spec.jwtAuth.defaultPoliciesRef` on `TykOasApiDefinition` → the Dashboard rejects the document with `Missing required Security Scheme 'keycloakJwt' in Components.SecuritySchemes`. The schemes are demonstrably present in the ConfigMap; the document the Operator re-serialises loses them.
- `spec.customDomain` → `x-tyk-api-gateway.server.customDomain.certificates: Invalid type. Expected: array, given: null`.

Both settings work fine when declared inside the OAS document instead, which is what this repo does. Worth reporting upstream.

---

## `TykMcpProxyDefinition` has no `jwtAuth` field

Unlike `TykOasApiDefinition`, the MCP resource's spec is only a ConfigMap reference — there is no way to reference a `SecurityPolicy` from the custom resource.

The workaround is sound but worth understanding: the policy carries an explicit `id`, both documents name it in `defaultPolicies`, and the gateway runs with `allow_explicit_policy_id`. See [tyk-config.md](tyk-config.md#1--how-the-policy-gets-bound).

---

## Operational sharp edges

These are not product limitations, but they will ruin a session if you meet them cold.

| | |
|---|---|
| **The gateway/Dashboard startup race** | A gateway that boots before the Dashboard registers no APIs and 404s everything. `01-create-cluster.sh` restarts it deliberately at the end. Expect this after any `helm upgrade` too. |
| **`kind load` fails on multi-arch manifests** | `content digest ... not found`. Pull on the node instead: `docker exec <cluster>-control-plane crictl pull <image>`. |
| **Keycloak restarts rotate signing keys** | Unless pinned — which this realm does, via `acme-static-rsa`. Remove it and every user starts failing with `no matching KID found in any JWKs`. |
| **`entitlements` as a multi-element array** | Keycloak silently keeps only the first element. The user imports, signs in, and has fewer permissions than you wrote. `./live-demo/whoami.sh` lints for it. |
| **Access tokens live 300 seconds** | Long segments outlive them. Re-run a read before a refund. |
| **Bitnami images are gone from Docker Hub** | Which is why `platform/datastores.yaml` uses plain manifests on official images rather than community Helm charts. |

---

## Things this workshop deliberately does not cover

- **Refresh tokens and long-running agents.** Everything here is a synchronous tool call within one short-lived session. An agent working for hours needs a refresh strategy this does not demonstrate.
- **Multi-tenancy.** One realm, one org, one gateway.
- **Agent-to-agent delegation.** One agent calling another, each narrowing further, is where `act` chains earn their keep — and where Keycloak's limitation above starts to hurt.
- **Prompt injection.** Nothing here stops an agent being *tricked* into calling a tool. It ensures that when it does, the call carries only the permissions of the person it is acting for. That is a containment control, not a prevention one — and it is worth saying plainly, because it is the most common misreading of the demo.
