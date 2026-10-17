# Agent Gateway

Agent Gateway lets Meta Muse request bounded Gmail data through one Cloudflare
relay. The relay sends a generic iPhone notification. You open the app, authorize
Gmail access, review a filtered preview, and approve or deny disclosure. The app
returns an encrypted result through the relay to Muse's outbound connection.

**No separately hosted bridge, callback server, extra domain, or always-on PC is
required.** Agent-side encryption/decryption runs inside Muse's existing runtime.
Gmail credentials and phone private keys stay on the iPhone. The relay cannot
fetch Gmail, read private payloads or grant approval.

The relay uses an internal Cloudflare Durable Object for bounded live connection
coordination, without an application database or request/result mailbox. This is
an explicit revision of the earlier strictly stateless/callback-only design.
Endpoints retain durable request/replay/result state and retry within five minutes.

Implemented: one-time-code pairing through the relay, nested JOSE encryption, device-local Gmail
OAuth/review, APNs notification transport, native iOS ciphertext inbox, signed
result return, outbound CLI and optional local stdio MCP. Real Muse account
installation, live APNs and physical-device acceptance remain unverified. Android
push is not implemented. The deployed release does not automatically acquire
these new changes until the tested revision is released and configured.

- [Relay-only setup](docs/remote-delivery.md)
- [Pair with Muse using a one-time code](docs/pin-pairing.md)
- [Architecture](docs/architecture.md)
- [API](docs/api.md)
- [Security](docs/security.md)
- [Pairing and manual fallback](docs/paired-delivery.md)
- [Gmail setup](docs/gmail-setup.md)
- [MCP usage](docs/mcp.md)
- [Muse compatibility](docs/meta-muse.md)
- [Acceptance checks](docs/foreground-acceptance.md)
- [Protocol](protocol/README.md)
- [Specification](SPEC.md), [plan](PLAN.md), [rules](RULE.md)
- [Production delivery](docs/production-setup.md), [historical Day 1 evidence](docs/day1-status.md)

## Development

Use Node 22, Flutter 3.47.6 and Docker Compose. Run `npm ci` and `npm run check`.
The Node suite includes a real local Worker-runtime encrypted WebSocket round trip
with mocked APNs. Its stable Miniflare runtime uses compatibility date 2026-08-06;
the deployed Worker targets 2026-10-01. The test does not establish live APNs.

From `mobile`, run `flutter pub get`, `flutter analyze`, and `flutter test`.
Native iOS compilation/signing requires macOS or the existing CI/Codemagic flow.
Codemagic uses `RELAY_URL`, `RELEASE_SHA`, `ENVIRONMENT` and the public
`GOOGLE_IOS_CLIENT_ID`. Private transport/provider secrets belong on the Worker.

`docker compose up --build --wait` and `node scripts/smoke.mjs` exercise local
health services. The mock/demo callback service is development scaffolding, not a
production dependency. GitHub Actions deploys tested relay revisions and
orchestrates signed iOS TestFlight builds. Android distribution remains deferred.
