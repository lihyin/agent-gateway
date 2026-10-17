# Relay-only Muse setup

There is one server deployment: the existing Cloudflare relay. No bridge host,
public callback URL, extra domain, or always-on Windows PC is required.

## 1. Install the outbound client in Muse's runtime

Meta documents custom connectors for APIs/CLIs in its existing runtime. The
provided Node client can run there; actual availability and installation in your
personal Muse account must be tested. This repository does not claim a completed
Muse connector installation or publication.

Use Node 22+, install this repository's dependencies with `npm ci`, and build with
`npm run build --workspace agent-adapter`. Set `GATEWAY_AGENT_STATE` to a private,
backup-excluded path inside Muse's runtime. On the iPhone tap **Pair with Muse**,
copy its setup message to your trusted Muse conversation, then run:

```sh
node agent-adapter/dist/src/cli.js pair
```

Provide the message's `AGW1.…` line on standard input. Approve the pairing on the
phone and authenticate. The one-time code expires within five minutes, permits
one attempt and is never sent to the relay. No fingerprint/receipt copying is
needed. See [code pairing](pin-pairing.md), including interrupted-pair recovery.
The [manual fallback](paired-delivery.md) remains available. No source credentials
enter Muse's runtime. Pairing uses foreground sockets and does not send a push.

With the client stopped, export the public transport pins:

```sh
node agent-adapter/dist/src/cli.js transport-config
```

Only public signing keys, endpoint IDs and the pairing epoch are printed. Do not
upload the private agent state file to Cloudflare or share it in chat.

## 2. Configure the existing relay

The Wrangler configuration binds `CHANNELS` to `RequestChannel` and `PAIRINGS` to
`PairingChannel`, with `v1-channels` and `v2-pairing` class migrations for all environments.
It stores no request/result mailbox and uses no application database.

Set these Worker secrets separately for each environment, using Wrangler or the
Cloudflare dashboard:

| Name                | Value                                                                            |
| ------------------- | -------------------------------------------------------------------------------- |
| `RELAY_ORIGIN`      | Exact public HTTPS origin for that environment.                                  |
| `PAIRING_CONFIG`    | Public JSON from `transport-config`, including both signing keys.                |
| `RELAY_ROUTING_KEY` | 32 cryptographically random bytes encoded as unpadded base64url (43 characters). |
| `APNS_KEY_ID`       | Apple push signing key ID.                                                       |
| `APNS_TEAM_ID`      | Apple developer team ID.                                                         |
| `APNS_PRIVATE_KEY`  | Apple push `.p8` private key, entered directly as a secret.                      |
| `APNS_TOPIC`        | `com.agentbrain.agentgateway`.                                                   |
| `APNS_ENVIRONMENT`  | `production` for TestFlight; `sandbox` for development-signed device builds.     |

For example, `npx wrangler secret put PAIRING_CONFIG --config relay/wrangler.toml
--env staging` prompts for the value. Do not put secret values in shell arguments,
source control, chat, logs, URLs or mobile Dart defines. The relay-only runtime
requires no `BRIDGE_ORIGIN`, `BRIDGE_RELAY_TOKEN` or `MCP_ACCESS_TOKEN`; remove those
obsolete secrets during migration. The old `/v1/device/sync` endpoint is removed.

Unconfigured transport fails closed. Validate staging before production. Use the
existing release pipeline to deploy an immutable tested revision, including the
Durable Object migration, and build the matching phone app.

## 3. Enable iPhone notifications and get a route

Enable Push Notifications for the Apple App ID and regenerate/select a matching
provisioning profile in Codemagic. TestFlight uses the production APNs environment;
the native debug configuration uses development APNs. Missing entitlements or
profiles are provider setup blockers, not something an unsigned test can establish.

Install the new app, connect Gmail and complete pairing. Enable **Relay
notifications** and confirm locally, then accept iOS notification permission. The
phone registers its current APNs token and displays an opaque delivery route in
the copyable transfer field. Transfer only that route to the Muse-side client.
Use **Refresh and copy Muse delivery route** after token changes, app restoration,
or the 24-hour route expiry. Give the refreshed route to Muse. Automatic delivery
of route replacements to Muse is not implemented.

## 4. Request, review and return

On the Muse-side client set `RELAY_URL` to the production relay origin and
`RELAY_ROUTE` to the sealed route. Prepare `request.json` with a fresh UUID
`requestId`, `source: gmail`, `operation: search`, bounded `query`, `purpose`,
`fields`, current Unix-second `since`/`until`, and `maxResults`. Supported fields
are id/date/subject/from/snippet, at most ten messages over at most thirty days.

```sh
node agent-adapter/dist/src/cli.js relay-request request.json
```

The CLI opens an outbound authenticated WebSocket to `/v1/requests`, sends the
request through APNs, and waits until approval, denial or expiry. It opens no
HTTP listener. Retries use the same `requestId`, arguments and encrypted envelope.
The phone notification opens the app: approve access, review the filtered preview,
then Allow once, Deny, Edit or create a bounded rule. Approved/denied outcomes
return encrypted through `/v1/results` to the waiting Muse connection. Only the
Muse-side client decrypts and prints the verified outcome. No Gmail token is sent.

For stdio MCP inside the agent runtime, launch `dist/src/mcp-server.js` with the
same state path, `RELAY_URL` and `RELAY_ROUTE`. Requests return pending IDs promptly;
the process maintains outbound connections and `gateway_request_status` returns
verified outcomes. Keep that process alive while awaiting review. Repeating an
identical request restarts an interrupted transport without repeating Gmail access.
A personal Muse account's supported custom connector interface must be validated;
this is not a remotely hosted MCP endpoint or a public connector listing.

## 5. Accept the delivery

Run the [device checklist](foreground-acceptance.md) with synthetic test messages.
Verify notification tap/resume, access and disclosure approval, denial, editing,
network interruption, original expiry and unpairing. Native signing, live APNs,
and real Muse execution require physical/provider validation. Unit tests and the
local Worker-runtime encrypted round trip do not establish those external checks.

References: [Meta runtime/custom connectors](https://research.meta.ai/blog/security-and-safety-for-ai-agents-our-approach-with-muse),
[Apple push requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[Cloudflare WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).
