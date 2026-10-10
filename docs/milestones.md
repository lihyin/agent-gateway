# Implementation status

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
