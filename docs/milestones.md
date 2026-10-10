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
