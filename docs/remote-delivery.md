# Remote MCP and foreground relay setup

The agent bridge supports authenticated Streamable HTTP MCP at `/mcp` and a
separate `/transport/sync` endpoint for the relay. The mobile app polls every
15 seconds while open after the user enables relay delivery. No push or
background execution is implemented. Manual encrypted transfer still works.

First complete [pairing](paired-delivery.md). With the bridge stopped, run
`node agent-adapter/dist/src/cli.js transport-config` using the same
`GATEWAY_AGENT_STATE`. Save its public JSON output as the Worker's `PAIRING_CONFIG`
secret. Re-pairing requires updating this configuration; phone unpairing stops
local delivery immediately.

Configure the Worker with `RELAY_ORIGIN` (its exact public HTTPS origin),
`BRIDGE_ORIGIN` (the bridge's exact public HTTPS origin), `PAIRING_CONFIG`, and
`BRIDGE_RELAY_TOKEN`. Store these with Wrangler secrets for the target environment.
Without all four values the sync route stays disabled. No requests or results are
stored by the Worker. Use public DNS HTTPS origins without custom ports or paths.

On the agent host set:

- `GATEWAY_AGENT_STATE`: the private paired state file.
- `BRIDGE_ORIGIN` and `RELAY_ORIGIN`: the same origins configured on the Worker.
- `BRIDGE_RELAY_TOKEN`: the same randomly generated secret as the Worker.
- `MCP_ACCESS_TOKEN`: a different randomly generated secret for the MCP client.

Both tokens must have at least 32 characters; generate at least 32 random bytes
for each. Keep tokens out of source control, command history, logs, and mobile
builds. Build with `npm run build --workspace agent-adapter`, then start
`node agent-adapter/dist/src/remote-server.js`. The listener defaults to
`127.0.0.1:8789`; terminate TLS at a reverse proxy that preserves the configured
Host. Restrict proxy body sizes, connection rates and timeouts. One bridge process
owns the state file; stop the CLI/stdio bridge before starting it.

Configure a Streamable HTTP MCP client with `https://<bridge-host>/mcp` and
`Authorization: Bearer <MCP_ACCESS_TOKEN>`. Remote clients see
`gmail_request_preview` and `gateway_request_status`; ciphertext submission and
pairing remain operator/device operations. Requests return a pending job ID;
poll status for the approved result. Transport acceptance does not grant consent.
This single-operator bearer-token service does not implement OAuth account linking
or establish Meta Muse compatibility.

Build the phone with `RELAY_URL` set to the same relay origin. Connect Gmail, pair,
and enable **Relay delivery while app is open**, confirming on the device. Create
a preview through MCP, keep the phone open, authorize access, review and approve
or deny. Approved results are automatically encrypted and returned. Disconnect,
disable delivery or unpair to stop polling. Retry uses the original ID and expiry;
requests still expire after five minutes. The relay forwards short-lived
signed device proofs; it cannot decrypt content or authorize Gmail access.

Before production acceptance, validate TLS/proxy configuration, secret rotation,
the installed phone's foreground/resume behavior, approval/denial, network loss,
and expiry. This implementation does not deploy a bridge, provision secrets,
configure an MCP account, or establish physical-device acceptance.
