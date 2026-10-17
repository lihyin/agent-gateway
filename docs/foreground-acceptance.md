# Foreground delivery acceptance record

Release candidate: `6af1f5e7678f205ad1db1e2e1df74c4ced6993de`.

Local verification passed: repository checks (format, configuration, lint,
TypeScript type checks, tests and builds); Flutter analysis and 70 mobile tests.
These checks do not establish deployed delivery or physical-device acceptance.

- [CI](https://github.com/lihyin/agent-gateway/actions/runs/39058450281)
- [Production delivery](https://github.com/lihyin/agent-gateway/actions/runs/39058457583)
- [Previous iOS inspection](https://github.com/lihyin/agent-gateway/actions/runs/39058366102)

The previous signed iOS build `6acab70c546ce6236ced5af4` completed archive and
publishing steps, but its TestFlight post-processing status is `failed`.
It is not accepted as completed distribution.

## Verified relay deployment

On October 17, 2026, staging and production independently returned the exact
release candidate from `/health`, with the expected environment and
`sourceAccessEnabled: false`. Both returned HTTP 404 for an unconfigured
POST `/v1/device/sync`, as required.

- Staging: `https://agent-gateway-relay-staging.agentbrain.workers.dev`
- Production: `https://agent-gateway-relay-production.agentbrain.workers.dev`

Signed iOS delivery is still running; this record does not claim TestFlight
distribution completion.

## Required operator inputs

The persistent bridge host, public HTTPS origin, and host access method have not
been supplied. No paired agent state file was found in the workspace's local
tool directories. Do not create a fixture pairing or upload private agent state
to the Worker. The phone and operator must complete real fingerprint verification.

Once a host is selected, deploy the tested bridge under its operator account,
generate separate random MCP/relay secrets, configure TLS, and complete pairing.
Install the public transport configuration and relay secret in the selected
Worker environment using [remote setup](remote-delivery.md). Keep the route
unconfigured until these prerequisites exist.

## Physical iPhone checks

Record the installed app revision, build number, iOS version, date and outcome
for each row. All rows below are currently **pending**, not passed.

| Check                | Expected evidence                                                                              |
| -------------------- | ---------------------------------------------------------------------------------------------- |
| Install and launch   | TestFlight build matches the release candidate; Gmail configuration is available.              |
| Pair fingerprints    | Trusted terminal and phone fingerprints match; rejected confirmation does not pair.            |
| Opt in               | Device confirmation enables foreground delivery for this epoch and relay origin only.          |
| Receive preview      | MCP job appears while app is open; Gmail is not fetched before access consent.                 |
| Allow                | Review filtered fields, approve once, and verify only the approved result at MCP status.       |
| Deny                 | Reject access/disclosure and verify denial without source messages at MCP status.              |
| Edit                 | Remove/change allowed preview fields; verify filtering and the edited disclosure.              |
| Retry/offline        | Disable connectivity, restore before expiry; same job/result does not fetch or disclose twice. |
| Expiry               | Leave a job pending past five minutes; no fetch or result release occurs afterward.            |
| Background/resume    | Polling stops when app is obscured; foreground resume retries within original expiry.          |
| Disable/unpair       | No further signed polling; old epoch requests fail after re-pairing.                           |
| Locked/restarted app | No source access while locked; protected state and deduplication survive restart.              |

Use synthetic messages in a dedicated test Gmail account. Record only outcomes
and identifiers in acceptance evidence, without message content, tokens, private
keys, or access capabilities. Background push and Muse account integration remain
outside this foreground acceptance scope.
