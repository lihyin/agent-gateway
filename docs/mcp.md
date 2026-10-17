# Agent-local MCP client for relay-only delivery

The official-SDK MCP adapter runs over stdio inside the existing agent runtime.
It opens no HTTP listener and requires no separately hosted bridge. A CLI client
is also available; see [Muse setup](remote-delivery.md).

Complete [fingerprint pairing](paired-delivery.md) and phone notification route
registration first. Install dependencies and build `agent-adapter`. Start
`node agent-adapter/dist/src/mcp-server.js` with:

- `GATEWAY_AGENT_STATE`: the private paired agent state file inside Muse's runtime.
- `RELAY_URL`: exact HTTPS relay origin.
- `RELAY_ROUTE`: the current sealed delivery route copied from the phone.

Both relay variables are required together. Node 22+ is required. Keep the stdio
process alive during review; do not run the operator CLI concurrently on its
locked state file. Only JSON-RPC goes to stdout, sanitized diagnostics to stderr.
Source credentials and phone private keys are never accepted.

| Tool                     | Behavior                                                                                                                                                                                                    |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gmail_request_preview`  | Accepts a UUID `requestId`, query, purpose, fields, Unix-second since/until and maxResults. Durably creates a bounded encrypted job, starts an outbound relay connection and returns a pending ID promptly. |
| `gateway_request_status` | Reads agent-owned state. Returns pending, original expiry or a verified approved/denied outcome. Pending does not mean device receipt or approval.                                                          |

At most ten messages and thirty days are supported, with id/date/subject/from/snippet
fields and 200-character query/purpose limits. The phone independently checks
scope and consent, filters data, and requires local confirmation for sensitive
fields. Original requests expire after five minutes, including review time.
Status polling is local to the agent process; there is no relay status database.

The user receives a generic APNs alert, opens the iPhone app, authorizes access,
reviews the filtered preview and approves/denies. A signed encrypted outcome
returns over the relay to the waiting outbound socket; the client verifies and
saves it before exposing approved data through status. Identical request retries
reuse ciphertext and restart interrupted transport; changed arguments fail.
Connection loss and provider outages may cause expiry. A relay handoff is not
verified receipt. Caller cancellation/process shutdown aborts sockets without
creating an approval or extending expiry. To resume after process restart,
repeat the original request ID and arguments before expiry.

## Manual fallback

Without either relay variable, the stdio adapter retains the three manual tools:
preview, status, and `gateway_submit_encrypted_result`. Pending includes the
original encrypted request for clipboard transfer. Submit verifies exported phone
ciphertext; it accepts no plaintext or approval overrides. Both modes use the
same bridge encryption, job persistence, scope checks and mobile review pipeline.

No remote `/mcp` endpoint, bearer-token bridge server, account linking or published
personal-Muse connector is provided. Personal Muse installation must validate its
actual custom CLI/MCP support; see [compatibility](meta-muse.md).

Tests cover SDK discovery/calls, stdio subprocesses, bounded scopes, expiry,
forgery/deduplication, device proofs and local Worker-runtime socket forwarding.
Physical iPhone/APNs and real personal-Muse acceptance remain separate.
