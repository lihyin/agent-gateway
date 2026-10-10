# ADR 002: Standard nested JOSE messages

Status: selected and cross-runtime fixture verified; transport integration is a
later milestone. No custom encryption construction is introduced.

Use RFC 7515 compact JWS (`ES256`) as plaintext of RFC 7516 compact JWE
(`RSA-OAEP-256`, `A256GCM`). TypeScript uses `jose`; Flutter uses `jose` backed by
PointyCastle. These libraries support the same algorithms. Encryption keys are
RSA 2048-bit minimum, distinct from P-256 signing keys. No `none`, symmetric
signature, RSA1_5, algorithm fallback, compression, remote key URL, or embedded
untrusted key is accepted. Implementations must explicitly enforce algorithm
allowlists and pinned keys, not just accept any algorithm a library supports.

JWS protected headers require `alg: ES256`, `typ: agw+jws`, and the pinned signing
`kid`. JWE protected headers require `alg: RSA-OAEP-256`, `enc: A256GCM`,
`cty: agw+jws`, and the pinned recipient encryption `kid`. Standard JOSE library
randomness supplies the content key and fresh 96-bit GCM IV on every encryption.
Never seed production randomness from fixtures. JWS uses the standard JOSE raw
64-byte ECDSA signature representation; no manual DER conversion is implemented.

Sign UTF-8 JSON `{context, payload}` and encrypt the exact compact JWS bytes.
Verify pinned recipient/header algorithms, decrypt, verify the pinned sender
signature, validate the closed payload schema, compare all authenticated context,
check pairing epoch and expiry, then persist replay reservation before policy.
Authenticated context includes direction to prevent request/result reflection.
Key IDs are RFC 7638 public JWK SHA-256 thumbprints. The user verifies the full
pairing fingerprint out of band; neither a relay response nor an imported key is
trusted automatically. Rotation creates a new confirmed pairing epoch and
invalidates outstanding local approvals/rules. Private keys stay in the device
vault; the relay has only its independent routing-signature and provider keys.

RSA wrapping increases request size; the 1,200-byte request plaintext limit and
3,500-byte envelope budget are tested against an actual encrypted fixture.
Final APNs/FCM byte size must still be checked after wrapping. RSA provides no
forward secrecy after recipient private-key compromise; changing to HPKE or
ECDH requires a new version and verified library interoperability. Native key
availability while locked and physical-device storage behavior remain required
acceptance checks, not guarantees inferred from Dart tests.

References: https://www.rfc-editor.org/rfc/rfc7515,
https://www.rfc-editor.org/rfc/rfc7516,
https://www.rfc-editor.org/rfc/rfc7518,
https://www.rfc-editor.org/rfc/rfc7638.
