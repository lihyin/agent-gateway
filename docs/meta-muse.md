# Meta Muse compatibility

The target is Meta's personal Muse agent. The production topology is Muse's
existing runtime, the Cloudflare relay and the iPhone. No hosted bridge, callback
server, public MCP domain, or always-on personal computer is required.

Meta's [technical overview](https://research.meta.ai/blog/security-and-safety-for-ai-agents-our-approach-with-muse)
describes a dedicated runtime that can execute tools and create custom API/CLI
connectors. This supports investigating an outbound client installed in that
runtime. It does not establish that this exact client is installed, approved or
usable in a particular personal Muse account. Muse Code and Model API access are
not substitutes for acceptance in the personal Muse runtime.

The provided Node CLI signs/encrypts a bounded Gmail request and opens an outbound
WebSocket to the relay. The relay sends a generic APNs alert containing ciphertext.
The user opens the iPhone app, authorizes Gmail access, reviews filtered data and
approves/denies disclosure. The app sends an authenticated encrypted result through
the relay to the same Muse connection. The client verifies/decrypts and returns
only the approved outcome to Muse. It never receives Gmail credentials or phone
private keys. The stdio MCP adapter can provide prompt pending-job responses and
agent-local status while maintaining outbound sockets; it opens no HTTP listener.

Required real-account validation: ability to install/run the client with Node 22,
maintain outbound authenticated WebSockets, retain private agent state, finish
one-time-code pairing, provide bounded request IDs/arguments and resume status after
human review. Lost sockets retry the original envelope before five-minute expiry.
Muse's permissions supplement phone approval and cannot bypass it.

No real personal-Muse connection, business verification, connector submission or
publication is claimed. [Connector platform guidance](https://platform.muse.ai/docs)
requires documented endpoints, authentication, scopes, status/errors and reviewer
access for platform submission. The runtime-client approach and a published
platform connector are distinct. If a personal account cannot run this client,
record that external blocker rather than introducing another server or weakening
encryption.

See [relay-only setup](remote-delivery.md), [MCP](mcp.md),
[pairing](paired-delivery.md) and [acceptance](foreground-acceptance.md).
