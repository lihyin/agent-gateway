# Protocol v1

This contract is a design gate. The production relay remains health-only until
pairing, protected replay persistence, transport, and the mobile authorization
pipeline are connected and validated.

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

Route claims are signed separately with a relay-only key. They contain verified
HTTPS callback origin, registered push destination, pinned endpoint IDs, epoch,
and a maximum 24-hour expiry. Issuance requires device key ownership and verified
callback ownership. Caller-supplied callback addresses never override a route.
Routes do not grant Gmail access; local unpairing is immediately authoritative.

Acknowledgments confirm encrypted transport handoff only, not device execution,
approval, or recipient receipt. Denials/errors contain no source data and are
encrypted like successful results. Unknown versions, expiry, authentication,
oversize data, replay, revoked pairing, invalid scope, and callback failure have
fixed error codes. Raw provider errors are never returned.
