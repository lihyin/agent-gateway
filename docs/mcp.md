# Agent Gateway MCP server

Implemented using the official TypeScript MCP SDK over local stdio. All tools use
the paired bridge and the phone's encrypted consent/review pipeline. The server
does not fetch Gmail directly, accept Google credentials, or run on the relay.
Remote HTTP hosting, account linking and personal-Muse publication remain incomplete.

## Connect

Complete [operator pairing](paired-delivery.md) with the CLI first. Stop the CLI,
then build/start the server with the same private state file:

```powershell
npm ci
npm run build --workspace agent-adapter
$env:GATEWAY_AGENT_STATE = "$PWD\.tools\local-agent\state.json"
node agent-adapter/dist/src/mcp-server.js
```

The process waits for an MCP client on stdin, not interactive shell commands.
A stdio-capable client's configuration can use absolute paths:

```json
{
  "mcpServers": {
    "agent-gateway": {
      "command": "node",
      "args": ["C:/path/to/agent-gateway/agent-adapter/dist/src/mcp-server.js"],
      "env": { "GATEWAY_AGENT_STATE": "C:/private/agent-gateway/state.json" }
    }
  }
}
```

Use Node 22+, an absolute executable if needed, and the state file already paired.
Launch Node directly: npm wrappers may print banners into protocol stdout.
Only JSON-RPC goes to stdout; sanitized diagnostics use stderr. One process holds
the state lock. Stop it normally before using the CLI to unpair or generate offers.

## Tools

| Tool                              | Inputs                                                                                    | Behavior                                                                                                                                                   |
| --------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gmail_request_preview`           | UUID `requestId`, `query`, `purpose`, `fields`, Unix-second `since`/`until`, `maxResults` | Saves a pending job and encrypted request. Does not fetch Gmail. Same ID/arguments return identical ciphertext; changed arguments fail.                    |
| `gateway_request_status`          | `requestId`                                                                               | Returns pending with original envelope, expiry, or verified outcome. Does not repeat retrieval.                                                            |
| `gateway_submit_encrypted_result` | `envelope`: ciphertext JSON string                                                        | Verifies the phone's signed encrypted result against the pending request and stores/returns the approved result. Rejects plaintext and approval overrides. |

Only Gmail search is supported: id/date/subject/from/snippet, at most ten messages,
a thirty-day window, and 200-character query/purpose. Wildcards, date overrides
and future end dates fail. The phone independently enforces consent, filtering,
and authentication for sender/snippet. No body/attachment retrieval is implemented.

Requests expire in five minutes, including review and transfer. At most 20 jobs
are retained and purged 24 hours after expiry on new requests. Pending is not a
completed search or proof of device receipt. Identical request/result retries are
idempotent, conflicting outcomes fail, and retries do not extend expiry.

## Reproducible test

1. Pair the iPhone, start the server through your MCP client, and verify exactly
   the three tools above are listed. No pairing, source-token or approval tool exists.
2. Call `gmail_request_preview` with a fresh UUID, `subject:AGWTEST`, purpose
   `Test invoice preview`, fields `["id","date","subject"]`, a current seven-day
   window and `maxResults: 5`. Expect `pending_device_review` and an envelope.
3. Repeat identical arguments: expect identical ciphertext. Change purpose under
   the same ID: expect a replay error.
4. Transfer just the envelope into **Import encrypted request** on the phone.
   Allow Gmail access, review the filtered preview, then Allow once or Deny.
5. Export the encrypted result. Call `gateway_submit_encrypted_result` with that
   serialized JSON string. Expect only approved data, or denied with no messages.
6. Check `gateway_request_status` and repeat submission to verify idempotence.
   After five minutes expect expired without messages. Forged/plaintext results,
   unrequested fields and unrelated IDs must fail.

Transfer remains manual and foreground-only. Unattended personal-Muse use needs
a hosted authenticated bridge and automatic transport. The relay's health URL is
not an MCP endpoint. No Meta Muse account integration is claimed.

## Security and verification

The OS user authorizes launching this stdio process; it opens no HTTP listener.
Use separate private state/OS accounts for different users. The paired agent can
retain approved data after decryption but receives no phone source credentials or
private keys. Pairing/trust changes require the operator CLI and phone confirmation.

Closed schemas, a 128-KiB JSON-RPC line limit, bounded tool elements/envelopes and
fixed sanitized errors limit input handling. Job creation/result submission mutate
bridge state and are annotated accordingly; status is read-only. Tool annotations
do not grant device authorization. Avoid copying approved MCP output into unrelated
telemetry or model sessions.

Tests cover official SDK client tool calls, idempotence, scope/forgery/expiry checks,
and a real stdio subprocess. Physical-device Gmail acceptance and real Muse account
connection are not established by mocked tests.

References: [official MCP SDK server guidance](https://ts.sdk.modelcontextprotocol.io/server)
and [Muse compatibility](meta-muse.md).
