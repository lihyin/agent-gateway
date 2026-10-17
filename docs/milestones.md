# Implementation status

One-time-code pairing is implemented with Node/Dart SRP interoperability, a
bounded `PairingChannel` inside the existing relay, phone confirmation and local
authentication. Signed offers/receipts transfer automatically; manual pairing
remains advanced fallback. See [PIN pairing](pin-pairing.md). Deploy the migration
and matching app/client before use. Operator transport pins and route transfer
remain separate; physical iPhone/Muse acceptance requires live verification.

## Meta Muse compatibility gate

An official-SDK stdio MCP server exposes bounded preview requests, status and
verified encrypted-result submission through the same agent bridge. Pairing is
operator-managed. SDK client tests cover discovery, idempotence, expiry,
scope/forgery rejection and a real subprocess. See [MCP setup](mcp.md).
Relay-only APNs and outbound Muse-client transport replace separately hosted MCP/foreground polling. No bridge host is required. See [setup](remote-delivery.md) and [acceptance](foreground-acceptance.md). A real personal-Muse connection remains unverified.

Pairing and encrypted manual foreground delivery are implemented; see
[paired delivery](paired-delivery.md). Protected device keys, pinned agent epochs,
durable request reservations and approval-bound encrypted result export have
cross-runtime and negative security tests. Live provider push acceptance and
physical-device acceptance remain incomplete.

Official connector guidance supports API/MCP integrations, but the current
gateway has an authenticated relay-only notification pipeline awaiting provider/device acceptance. The compatibility
decision and remaining prerequisites are recorded in [Meta Muse](meta-muse.md).
No live connector, submission, or end-to-end Muse validation is claimed.

## PR02: protocol and crypto design

Protocol v1 has closed JSON schemas, strict TypeScript validation, bounded
lifetimes and encoded sizes, separate transport acknowledgments, and fixed error
codes. The crypto decision selects standard nested JOSE with separate signing
and encryption keys. Shared disposable key fixtures have been decrypted and
verified in Dart, then regenerated in Dart and decrypted/verified in TypeScript.
CI runs both directions. This is a completed design gate, not a claim that
production transport or device pairing is implemented.

The user reports successful TestFlight installation of the Day 1 app. Native
secure storage, OAuth, pairing, push, and biometrics need their own physical-device
acceptance as implemented. Android distribution remains deferred.

## Next authorized scope

The user authorized device-local Gmail access and approval after the protocol
commit. Live sign-in needs a provider-owned iOS OAuth client ID, enabled Gmail
API, and configured OAuth test users. Implementation and mock tests can proceed
without those public configuration values. Agent disclosure remains disabled
until authenticated pairing, encrypted transport, replay persistence, and result
handoff are connected and verified.

## Gmail and approval implementation

Implemented native iOS AppAuth sign-in/refresh/revocation, device-only secure
vault, bounded direct Gmail metadata search, access consent, minimization/PII
filtering, persistent replay/review state, Allow/Deny/Edit/Always with exact-scope
revocable rules, high-risk local authentication, and a mobile review UI.
The UI is explicitly device-owner preview mode; actual agents cannot initiate
retrieval or receive data. Negative tests cover policy bounds, revocation/expiry,
disconnect races, replay/restart, stale actions, edits, and rule escalation.
Live Google client configuration, iOS native build, and physical-device checks
remain required before live acceptance. See [setup and acceptance](gmail-setup.md).
