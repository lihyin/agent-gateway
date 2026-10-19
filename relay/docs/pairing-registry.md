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
  The relay reads those IDs from the _unverified_ token purely as a lookup
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

## Provisioning (open question)

This sketch includes one concrete path: `POST /v1/pairings` with
`Authorization: Bearer <PROVISIONING_SECRET>` and a pair record as the body
(validated before storing). Disabled unless `PROVISIONING_SECRET` is set.
Alternatives to decide before production:

1. Provisioning endpoint (as sketched) — simple, but adds an internet-facing
   write path guarded by a bearer secret.
2. Self-registration during pairing — the `PairingChannel` writes the record
   when a pairing completes; no standing write endpoint. More moving parts
   in the pairing flow, best long-term ergonomics.
3. Operator-only writes (wrangler CLI against the DO) — no new attack
   surface, worst ergonomics.

## Migration sketch

1. Deploy with the registry bound but empty; `PAIRING_CONFIG` still serves
   the existing user via fallback.
2. Provision existing pair(s) into the registry.
3. Remove `PAIRING_CONFIG` once the registry is the source of truth
   (guard already accepts registry-only configuration).

## Known sketch-level gaps

- No admin/list/delete HTTP surface beyond the DO's internal DELETE.
- Registry reads are per-request (no caching); fine at expected scale.
- `registry.ts` imports validation from `direct.ts` and vice versa
  (deferred runtime calls only); a shared `pair.ts` module would tidy this.
