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

The default [pairing flow](pin-pairing.md) uses a thirty-minute, single-attempt
eight-digit PIN with library SRP-6a, followed by role/session/origin/expiry-bound
JOSE records carrying the existing signed offer and receipt. Device confirmation
and local authentication precede pinning. A random session address, separate from
the PIN, enters relay URLs. The trusted Muse setup message contains the PIN;
it must not enter logs, shell arguments or public chat. The relay never receives
the PIN, verifier, shared key or private endpoint keys. Manual full-fingerprint
comparison remains an advanced fallback.

`PairingChannel` adds bounded live forwarding inside the existing relay, with
two sockets, at most five 8192-byte frames per peer and a thirty-minute timer.
No Storage API, hibernation attachment or durable pairing mailbox is used. The
phone independently enforces one proof/sequence/expiry against a malicious relay.
Resets and disconnects need a fresh code; interrupted final handoff may require
unpairing both endpoints. Pairing sends no push and grants no Gmail access.
Device-signed pair records register automatically in PairingRegistry. Global abuse
quotas and physical-device acceptance remain operational checks. No audit is claimed.

## Relay-only transport

PairingRegistry is the sole transport authority for all users; there is no
single-pair secret fallback. The phone signs 30-second `agw+register` proofs
binding its APNs token, relay audience, both IDs, epoch and millisecond `updatedAt`.
The registry accepts only strictly newer updates, including across disabling
notifications; replays cannot restore a previous destination. The phone persists
its update clock and refreshes registration on startup/resume, token-change
notification, and at most once a minute during foreground polling.
Before its first push registration in a process, the phone also submits the same
device-signed pair record over HTTPS. This supports manual pairing and lost-frame
recovery without operator credentials; retired epochs remain rejected.

Destinations are encrypted at rest with the relay-only 32-byte AES-256-GCM
routing key. No route capability leaves the relay and no daily expiry/copy step
exists. The key cannot decrypt private request/results. A verified agent request
contains only the encrypted envelope plus common transport claims; the relay
resolves the destination for the verified pair, never a caller-chosen recipient.
There is a durable limit of ten delivery attempts per pair per minute, including
retries; this does not replace account-wide Cloudflare abuse controls.

Device-signed `agw+route-disable` clears the destination while retaining its
update high-water mark. Device-signed `agw+unpair` deletes the pair and destination.
The app requires a successful online relay response before completing disable or
unpair; on failure it reports an error and preserves the pairing for retry.
Re-pairing clears the old destination and retires the previous epoch. Retired
epoch records prevent old registration proofs from restoring revoked pairs.
A device cannot overwrite a different device's agent ID. Existing pairs retain
their destination on an identical pair registration. Retired epoch records retain
public pairing metadata to authenticate idempotent revocation retries; they never
authorize transport and currently have no automatic pruning.

Self-registration remains open to any valid device-signed pair; signup gating
and global quotas are deployment policy, not implied by per-pair authentication.
Private payload encryption and phone authorization are unchanged. The device
independently authenticates/decrypts before review. The device signs encrypted
result submissions as `agw+result`. The relay matches full context to the active
Muse connection; the Muse-side client verifies/decrypts and durably saves results.
Unknown fields, algorithms, versions, keys, epochs, audiences, future issuance,
expired proofs and oversized data fail closed. Transport proofs last at most
30 seconds; original requests at most five minutes. Retries do not extend expiry.

A Cloudflare Durable Object inside the relay coordinates a live receive-only
WebSocket per request. There is no request/result database, durable queue or result-polling mailbox.
Only PairingRegistry persists pairing identities, encrypted push destinations,
update clocks, rate counters and revoked epochs. Attachments contain authenticated
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

The user-initiated Muse clipboard handoff combines a temporary pairing setup line
with reusable Gmail instructions. The instructions require discarding the code,
preserving private agent state, phone consent and verified results. Subsequent
skill copies contain no pairing code and omit expired delivery routes. Enabling
notifications or refreshing a route copies the skill and sealed route together;
clipboard success is confirmed only after the write completes. These messages
belong only in the user's trusted Muse chat. Clipboard/chat retention is outside
the vault's protection; the app does not automatically paste or send to Muse.
The skill is guidance, not authorization or evidence of runtime installation.

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
