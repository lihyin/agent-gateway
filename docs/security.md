# Security boundaries

## Authorities and secrets

The iPhone owns Gmail OAuth, connector execution, default-deny policy, access
consent, minimization, deterministic PII filtering, disclosure approval and audit.
Muse receives only approved data. Neither push delivery nor Muse-side permission
can bypass phone authorization. Gmail tokens and phone private keys never leave
the device-only vault. Muse-side keys and verified results remain inside Muse's
runtime, under its account. No separately hosted bridge is required or supported.

The relay and APNs are untrusted for payload confidentiality and authorization.
They observe transport metadata and can delay, duplicate or disrupt delivery.
Nested ES256 JWS inside RSA-OAEP-256/A256GCM JWE pins signing/encryption identities,
epoch, direction, request ID and original timestamps. Durable endpoint replay
reservation precedes retrieval. Changed ciphertext under one ID fails closed.
Release rechecks approval revision/digest, pairing and expiry. Retries reuse saved
encrypted results and cannot repeat source access.

## One-time-code pairing

The default [pairing flow](pin-pairing.md) uses a five-minute, single-attempt
eight-digit PIN with library SRP-6a, followed by role/session/origin/expiry-bound
JOSE records carrying the existing signed offer and receipt. Device confirmation
and local authentication precede pinning. A random session address, separate from
the PIN, enters relay URLs. The trusted Muse setup message contains the PIN;
it must not enter logs, shell arguments or public chat. The relay never receives
the PIN, verifier, shared key or private endpoint keys. Manual full-fingerprint
comparison remains an advanced fallback.

`PairingChannel` adds bounded live forwarding inside the existing relay, with
two sockets, at most five 8192-byte frames per peer and a five-minute timer.
No Storage API, hibernation attachment or durable pairing mailbox is used. The
phone independently enforces one proof/sequence/expiry against a malicious relay.
Resets and disconnects need a fresh code; interrupted final handoff may require
unpairing both endpoints. Pairing sends no push and grants no Gmail access.
Operator `PAIRING_CONFIG` and sealed route setup remain separate. Global abuse
quotas and physical-device acceptance remain operational checks. No audit is claimed.

## Relay-only transport

The operator pins one paired device/agent's public signing keys and epoch in
`PAIRING_CONFIG`. The device signs 30-second `agw+register` proofs containing its
APNs token. The relay seals 24-hour routing capabilities using a separate
32-byte AES-256-GCM routing key. This key never decrypts private request/results.
Routes bind relay audience, both IDs, epoch and push destination. Tokens are
replaced on APNs refresh/expiry and must be conveyed to Muse's runtime. Automatic
route replacement distribution is not implemented.

The agent signs `agw+request` proofs carrying the sealed route and encrypted
request. The relay verifies them before APNs or socket allocation. The device
independently authenticates/decrypts before review. The device signs encrypted
result submissions as `agw+result`. The relay matches full context to the active
Muse connection; the Muse-side client verifies/decrypts and durably saves results.
Unknown fields, algorithms, versions, keys, epochs, audiences, future issuance,
expired proofs and oversized data fail closed. Transport proofs last at most
30 seconds; original requests at most five minutes. Retries do not extend expiry.

A Cloudflare Durable Object inside the relay coordinates a live receive-only
WebSocket per request. There is no application database, Storage API usage,
durable queue or result-polling mailbox. Attachments contain authenticated
context and a ciphertext digest only. Ciphertext and APNs tokens are not retained
in attachments. A timer bounds connection life to the original expiry. Relay
resets/disconnections fail closed; endpoint state is authoritative for recovery.
This transient coordination explicitly replaces the earlier strictly stateless
callback architecture. No callback URLs, outbound arbitrary origins, hosted MCP
endpoint, bridge bearer tokens or plaintext relay processing remain.

The only provider destination is the configured production/sandbox Apple APNs
host. Redirects are manual and non-success responses fail; arbitrary callback
SSRF is eliminated. Provider calls time out. Request envelope size is 3500 bytes,
complete push 4096, result envelope 65,536 and POST proof 92,000. Error responses
are fixed sanitized codes. Disable header/body logging and tracing that would
capture authorization proofs, sealed routes, APNs tokens or payloads. Platform
abuse controls beyond authentication, bounded inputs and connection expiry need
operational validation; no distributed rate-limit guarantee is claimed.

## Phone receipt and approval

Notifications contain generic alert text and ciphertext, never source/query,
purpose, preview, approval actions or credentials. Native code receives alerts,
taps and already delivered notifications on resume. It stores at most 20 encrypted
envelopes in an atomic backup-excluded Application Support file protected until
first unlock after boot. This inbox contains no decrypted payloads or keys;
Keychain remains the protected authority for reviews, source tokens and keys.
Expiry prunes the native inbox; successful domain import is acknowledged before
removing the notification. Native storage failure grants nothing: Muse retries.

Notification receipt/tap never executes Gmail. Imports happen in the foreground
after local opt-in for the current epoch/origin and Gmail connection. Policy and
access consent precede direct Google requests. Sensitive fields require local
authentication. Filtering and user disclosure approval precede encrypted release.
Edit cannot widen scope and is filtered again. Exact-scope Always rules last at
most 24 hours and cannot bypass source consent, high risk or expiry. Disconnect
cancels local reviews; unpair immediately stops local acceptance/release.

Approved or denied encrypted outcomes are sent while the app is open. Failed
handoffs retry on foreground refresh within original expiry. HTTP 202 means
socket handoff, not verified agent receipt. Restart can repeat a handoff; the agent
deduplicates and checks original scope. A verified recipient can retain disclosed
data; already released data cannot be revoked.

## Other controls and limitations

Native AppAuth owns PKCE/state and validated redirects. Only Gmail read-only is
requested, with no credential export. Device-only unlocked Keychain stores
credentials/reviews; Android backup is disabled. The iOS shared HTTP disk cache is
disabled, and previews are obscured in the app switcher. High-risk release requires
local confirmation. PII filtering is deterministic and incomplete; users must
review proposed disclosure. Key generation uses JOSE libraries; hardware-backed
private-key operations and forward secrecy are not claimed.

Local unpairing immediately revokes data access. Updating relay pins/epoch revokes
old transport routes globally; without that update a valid old route can still
send notifications until expiry. Missing notifications, offline phones, dropped
connections and provider failures may cause request expiry. No durable offline
mailbox or guaranteed background execution is promised. Android/FCM, live APNs,
physical iPhone behavior and real Muse installation require separate acceptance.

GitHub release secrets belong only to trusted environment jobs, and Codemagic
holds signing credentials. Local Compose uses mock data. Native push capability,
entitlements, signing profiles and APNs environment must agree. Missing account
configuration is a release blocker. The app is not independently security-audited.

See [architecture](architecture.md), [setup](remote-delivery.md),
[crypto decision](crypto-design.md) and [acceptance](foreground-acceptance.md).
