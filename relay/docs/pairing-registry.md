# PairingRegistry — multi-pair relay design (sketch)

Status: **design sketch / draft PR**. Not deployed; production still uses the
single-pair `PAIRING_CONFIG` secret.

## Problem

`PAIRING_CONFIG` holds exactly one pairing (one phone + one agent + one
epoch). Every relay operation validates against that single pair, so one
Worker deployment serves one app user, and every re-pair (new epoch) means a
manual secret edit.

## Proposal

Store pair records in a dedicated Durable Object, `PairingRegistry`
(binding `PAIRINGS_REGISTRY`, SQLite storage — the same `new_sqlite_classes`
pattern as `RequestChannel`/`PairingChannel`).

- **Record**: the exact object `PAIRING_CONFIG` holds today —
  `deviceSigningKey`, `agentSigningKey`, `deviceId`, `agentId`,
  `pairingEpoch`. Public keys and IDs only; no secrets, no payloads. The
  relay stays "live transport only" for message data.
- **Schema**: `pairs(agent_id PRIMARY KEY, device_id UNIQUE, record, updated_at)`,
  one global instance (`idFromName("global")`).
- **Lookup**: request/result/registration tokens carry their claimed IDs.
  The relay reads those IDs from the *unverified* token purely as a lookup
  hint (`decodeJwt`), loads the matching record, validates it
  (`validatePairRecord`: exact keys + JWK thumbprints match the IDs), then
  verifies the token signature against the record's keys and runs every
  existing equality check. A forged hint can only select the wrong record
  and fail verification.
- **Fallback**: if no registry record matches (or no registry is bound),
  `configuration()` falls back to `PAIRING_CONFIG`, so existing single-user
  deployments keep working unchanged. The `directFetch` configuration guard
  accepts either source.
- **Why DO storage, not KV/D1**: strongly consistent — a re-pair is
  effective immediately, with no propagation window where a freshly
  re-paired user is still rejected. Single-writer serialization avoids
  write races. D1 remains an option later if cross-user admin queries are
  needed.

## Provisioning (decided 2026-10-18: self-registration)

The operator step this design exists to remove is per-user (and per
re-pair) provisioning, so the primary path is **self-registration during
pairing** — no standing operator action, no secret edit, no redeploy:

- As part of the live pairing, the phone sends one extra cleartext frame
  on its pairing socket: `{ kind: "pairing_record", record, proof }`,
  where `record` is its transportConfiguration and `proof` is an ES256
  JWS (typ `agw+pair-register`) signed with the **device** signing key,
  over exactly `{ version, audience, deviceId, agentId, pairingEpoch,
  issuedAt, expiresAt }` (window ≤ 300s; `issuedAt` may lead the relay
  clock by up to 30s, the same peer clock-skew allowance the agent
  applies to pairing receipts).
- The `PairingChannel` intercepts the frame: it is consumed by the relay
  and never forwarded to the agent. It counts toward the existing
  per-socket frame bound (the phone sends at most challenge, ready,
  receipt, pairing_record). Verification and storage finish under
  `waitUntil`, so closing the pairing sockets cannot lose the write.
- Validation, in order: `validatePairRecord` (exact shape; JWK
  thumbprints must equal the claimed IDs), then the proof signature
  against the record's device key, then payload equality with the record
  (IDs, epoch, audience, timing). Any failure with a registry bound fails
  the pairing session closed, like other protocol violations.
- Why the device signature is sufficient authority: the phone is the
  trust root of a pairing. Registering a rogue agent against someone
  else's deviceId would require that device's private key, because the
  proof key is bound to the claimed deviceId by thumbprint. Registering
  your *own* pair is the intended multi-user flow, so no operator secret
  is involved. A record signed by the same device key replaces that
  device's previous record, so a re-pair (new agent and/or new epoch)
  supersedes the old row atomically.
- If no registry is bound, the frame is ignored and the deployment is
  unchanged (PAIRING_CONFIG / endpoint provisioning still apply).

The bearer-guarded provisioning endpoint (`POST /v1/pairings`,
`PROVISIONING_SECRET`, disabled unless set) is retained as the operator
bootstrap/recovery path — e.g. for provisioning an existing pair without
re-pairing — not as the per-user flow. Operator-only writes via wrangler
remain possible in an emergency and need no code path.

## Migration sketch

1. Deploy with the registry bound but empty; `PAIRING_CONFIG` still serves
   the existing user via fallback.
2. Provision existing pair(s) into the registry via the endpoint, or let
   each pair self-register at its next re-pair once the app ships the
   `pairing_record` frame.
3. Remove `PAIRING_CONFIG` once the registry is the source of truth
   (guard already accepts registry-only configuration).

## Known sketch-level gaps

- Client support has landed in the app (same branch): `PinPairing` sends
  the `pairing_record` frame right after the pairing receipt, built by
  `PairedDelivery.pairRegistration` (record + device-signed proof), and
  treats registration as best-effort so it can never fail a pairing. The
  agent needs no change. Nothing is deployed yet, though: until the relay
  and app changes ship, production still relies on `PAIRING_CONFIG` /
  endpoint provisioning.
- Self-registration is intentionally permissionless for valid pairs (any
  completed pairing may register). If open sign-up ever needs gating,
  layer an account/invite check at registration time rather than
  returning to per-user operator provisioning.
- No admin/list/delete HTTP surface beyond the DO's internal DELETE.
- Registry reads are per-request (no caching); fine at expected scale.
- `registry.ts` imports validation from `direct.ts` and vice versa
  (deferred runtime calls only); a shared `pair.ts` module would tidy this.
