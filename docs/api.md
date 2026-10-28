# Relay transport API

The relay handles only encrypted transport. Gmail credentials, connector access,
policy, reviews and approvals are phone-owned. No additional server is deployed.
All routes require the configured exact HTTPS origin and reject browser Origin
headers and URL query parameters. Private routes fail closed when unconfigured.

Pairing adds `GET /v1/pairing/<session>/device` and `/agent`, WebSocket upgrades
only. The session is 64 lowercase hex characters from 32 random bytes, distinct
from the secret PIN. These paths require `PAIRINGS` and `RELAY_ORIGIN`, but do not
require per-user operator secrets. With PAIRINGS_REGISTRY bound, the phone also
sends a device-signed pair record that the relay stores. One phone and one agent exchange public SRP
values and encrypted signed offers/receipts for at most thirty minutes. Endpoints,
not the relay, authenticate the code and approve pairing. See the full
[PIN protocol](pin-pairing.md). Invalid upgrades/Origin/query return 400;
missing/used rooms or duplicate peers return 409; disabled/malformed paths return 404. Excess frames, binary/oversize frames, disconnect or expiry close both
sockets. There is no reconnect/resume, polling or offline pairing queue.

| Endpoint           | Authentication and behavior                                                                                                                                                                                                                                                                     |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /health`      | Existing public service/environment/revision health; `sourceAccessEnabled` remains false because the relay cannot access sources.                                                                                                                                                               |
| `POST /v1/routes`  | `Content-Type: application/jose`, 30-second device ES256 proof of type `agw+register`. Registers the current APNs token with a strictly increasing millisecond `updatedAt`; returns `{status: registered}`. The destination is encrypted in PairingRegistry and is not returned to Muse.        |
| `GET /v1/requests` | WebSocket upgrade with `Authorization: Bearer <agw+request JWS>`. Proof binds audience, short transport lifetime, encrypted request envelope. Relay verifies registry pins and resolves the registered destination, forwards generic alert plus ciphertext to APNs and opens the return socket. |
| `POST /v1/results` | `Content-Type: application/jose`, device proof of type `agw+result` binding audience, 30-second transport lifetime and encrypted result envelope. Returns HTTP 202 `{status: handed_off}` only after handing ciphertext to the matching live agent socket; otherwise HTTP 503 `agent_offline`.  |

Request/result envelope format remains protocol v1 nested signed JWS/encrypted
JWE. Transport proofs have version 1, `audience`, integer UTC `issuedAt` and
`expiresAt`. Unknown fields/types, wrong keys/epoch/audience, future-issued or
expired proofs, and a transport lifetime over 30 seconds fail authentication.

Registration additionally binds `deviceId`, `agentId`, `pairingEpoch` and a
hexadecimal `pushToken` and integer millisecond `updatedAt`. Agent request proofs carry only `envelope`
beyond common fields. Result proofs carry only `envelope` beyond common fields.
Neither payload contains a caller-selected callback address. Request proofs are
limited to 16,000 header bytes; POST proofs to 92,000 bytes. Request envelopes
remain at most 3500 bytes, result envelopes 65,536, and the complete APNs payload 4096. The original request's exclusive expiry is at most five minutes.

A `RequestChannel` Durable Object inside the same relay coordinates the live
connection. No Storage API, request/result database, durable queue or polling
mailbox is used. Socket metadata is context plus a ciphertext digest. A same-ID
reconnect must preserve context and ciphertext while that channel is live; durable
endpoint replay ledgers remain authoritative across relay resets. Duplicate
result handoffs are allowed; only endpoints can establish verified receipt.

Errors are fixed JSON codes: `unauthorized` (401), `oversize` (413),
`websocket_required` (426), `rate_limited` (429; ten delivery attempts per pair/minute), `replay` (409), `transport_unavailable` or `agent_offline`
(503), and disabled/unknown routes (404). No provider body, credentials, token,
plaintext request or approved content enters an error response or relay logging.
Push acceptance, review, disclosure approval and verified agent receipt are distinct.

Removed: `/v1/device/sync` and all separate hosted-bridge configuration.
See [setup](remote-delivery.md), [architecture](architecture.md) and
[protocol](../protocol/README.md).

Device control endpoints use application/jose and the same 30-second common claims,
plus deviceId, agentId, pairingEpoch and updatedAt:

- POST /v1/routes/disable: device signature, typ agw+route-disable; clears the destination.
- POST /v1/pairings/revoke: device signature, typ agw+unpair; retires the epoch and removes the pair/destination.

Both return HTTP 200 {status: revoked}. Disabling retains the update high-water
mark; old registration proofs cannot re-enable notifications.

`POST /v1/pairings/register` accepts `application/json` containing the same
`{kind: pairing_record, record, proof}` frame used during code pairing. Its
device-signed `agw+pair-register` proof binds the public record's IDs/epoch and
relay audience. This supports manual pairing and recovery after a lost pairing
registration frame. Identical records are idempotent; retired epochs and agent-ID
collisions across devices are rejected. Returns `{status: registered}`.
