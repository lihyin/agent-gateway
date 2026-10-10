# Meta Muse integration gate

Reviewed October 10, 2026. Target: Meta's personal Muse agent, pending user
confirmation. A local [stdio MCP server](mcp.md) and foreground encrypted
pairing/delivery are implemented. This is not a hosted personal-Muse connector;
no real Muse account connection is claimed.

## Supported interface

Meta's [Muse Connector Platform guidelines](https://muse.ai/platform/docs)
accept API or MCP documentation, endpoint authentication details, tool scopes,
status/error handling, and dedicated reviewer test accounts. Submission includes
business verification, privacy/terms information, and review. These guidelines
do not establish a public encryption interface, callback contract, or tool-call
timeout for our use case; those details require platform testing.

[Meta AI Connectors](https://dev.meta.ai/products/connectors) describes API/MCP
onboarding and OAuth account linking. Its early-access program is separate from
evidence that a particular Muse account can connect to Agent Gateway.

Muse Code and the Meta Model API are separate products. Model API access alone
does not connect the personal Muse agent to this app.

## Decision

Use an agent-side API/MCP bridge after the gateway's encrypted delivery pipeline
is implemented. The bridge is the paired agent: it signs/encrypts requests,
receives encrypted results, verifies/decrypts them, and exposes only approved
disclosures to Muse. The Cloudflare Worker remains stateless ciphertext routing.
Google OAuth stays on the iPhone. Muse account-linking credentials must authorize
the bridge, not provide access to the phone's Gmail token or private keys.

Muse permissions supplement device authorization. Neither Muse's Always setting
nor bridge authentication can bypass phone consent, expiry, filtering, pairing,
or device confirmation. The phone must identify the actual disclosure recipient.

## Current blockers

- Pairing and protected device keys support manual encrypted foreground transfer;
  a hosted bridge/automatic transport is not yet implemented.
- Relay request delivery/push, encrypted result handoff, and authenticated agent
  callbacks are not implemented. The demo adapter exposes health only.
- Muse connector authentication, asynchronous completion, timeout, cancellation,
  and account isolation require validation with a real test account.
- Platform publication requires the owner's business information, terms/privacy
  policy, dedicated test account, and any required developer access.

Do not register the production health URL as a working Gmail connector. No live
integration or connector submission has been performed. Existing demo scaffolding
and device-local Gmail review remain the supported baseline.

## Bridge contract and remaining Muse integration

1. A bounded Gmail preview tool accepts query, purpose, requested fields, date
   range, maximum results, and expiry. It never accepts Google credentials,
   replacement recipient keys, arbitrary callbacks, or approval overrides.
2. The authenticated bridge binds the caller to a verified pairing and sends a
   protocol-v1 encrypted request with a stable request ID.
3. Pending human review is reported as pending, never as an empty successful
   search. If supported, a separate status operation uses an opaque handle tied
   to the authenticated caller. Request tracking belongs on the agent side.
4. Only a verified, unexpired result for the pinned pairing becomes a tool result.
   Denial, expiry, disconnect, unavailable device, and uncertain delivery remain
   explicit outcomes. Retrying must reuse the request identity.
5. Tool classifications and disclosure side effects must be confirmed during
   platform review; a Gmail read must not conceal a separate sharing operation.

## Acceptance before enabling live Gmail

- Run the demo agent through real pairing and encrypted phone delivery first.
- Test phone Allow, Deny, Edit, high-risk confirmation, expiry, and revocation end
  to end, including duplicate messages, restart, tampering, and wrong agent keys.
- Validate the actual Muse account's supported authentication and async interface
  with synthetic data; confirm pending/denied outcomes and cross-account isolation.
- Verify no Google credentials, phone keys, plaintext previews, or route secrets
  enter relay logs, push alerts, or connector descriptions.
- Test a dedicated Gmail account on a physical iPhone before enabling real users.

See [protocol](../protocol/README.md), [security](security.md), and
[Gmail acceptance](gmail-setup.md). Automatic transport and hosted connector
authentication remain prerequisites for connector publication. See
[foreground pairing/delivery](paired-delivery.md).
