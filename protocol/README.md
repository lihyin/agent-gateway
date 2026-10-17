# Protocol v1

Pairing and nested JOSE now support relay-only APNs delivery and encrypted return
over a Muse-runtime outbound connection. See [transport API](../docs/api.md),
[architecture](../docs/architecture.md) and [setup](../docs/remote-delivery.md).

All times are integer UTC Unix seconds. IDs are opaque UUIDs. Unknown fields and
versions are rejected. Request lifetime is at most 300 seconds; expiry is exclusive.
Request plaintext is at most 1,200 UTF-8 bytes. Envelopes are at most 3,500 UTF-8
bytes for requests and 65,536 bytes for results; the final push wrapper must be at
most 4,096 bytes. Routing capabilities travel in the HTTPS submission, never in
the push payload. Results are bounded to 10 messages and 50,000 plaintext bytes.

See [cryptographic decision](../docs/crypto-design.md) and the closed JSON schemas
in `schemas/`. `fixtures/crypto.json` contains public test-only keys and a standard
nested JWS/JWE sample, never production credentials.

An envelope's `context` occurs identically inside the signed payload. Both the
outer context and signed context must match. It binds `version`, `direction`,
`requestId`, `sender`, `recipient`, `pairingEpoch`, `issuedAt`, and `expiresAt`.
Source, operation, query, purpose, requested fields, status, and returned data are
inside ciphertext. A result uses the same request ID, epoch, and expiry, with
sender/recipient swapped. Only locally pinned keys may verify/decrypt a message.

Persist `(sender, pairingEpoch, requestId)` and the envelope digest before
execution. A changed envelope under a reserved ID is rejected. Identical retries
return the saved encrypted outcome, never repeat retrieval. Keep replay records
beyond expiry (24 hours); a restart cannot reopen completed requests.

Routing capabilities are sealed with relay-only dir/A256GCM JWE. They bind the
relay audience, registered APNs token, paired IDs/epoch and a 24-hour expiry.
Issuance requires a pinned-device ES256 ownership proof. Agent submission and
device result proofs are separately signed and last at most 30 seconds. Neither
caller-supplied callbacks nor replacement recipient keys are accepted. An internal
live connection object routes ciphertext to the original Muse socket without
persisting request/result bodies. Endpoints own recovery and durable replay state.

Acknowledgments confirm encrypted transport handoff only, not device execution,
approval, or recipient receipt. Denials/errors contain no source data and are
encrypted like successful results. Unknown versions, expiry, authentication,
oversize data, replay, revoked pairing, invalid scope, and live-channel failure have
fixed error codes. Raw provider errors are never returned.
