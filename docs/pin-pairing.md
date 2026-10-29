# Pair with Muse using a one-time code

The iPhone starts pairing and copies one complete setup
message for your trusted Muse chat. Muse and the phone exchange signed pairing
material through the existing Cloudflare relay. No additional server, public
hostname, callback service, or always-on PC is required.

## Use it

1. Install matching versions of the relay, Muse client and iPhone app. The relay
   needs the `PAIRINGS` binding, `v2-pairing` migration, and exact `RELAY_ORIGIN`.
   Pairing does not require APNs, Gmail, or the notification transport pins.
2. On an unpaired iPhone, tap **Pair with Muse**. This starts pairing and copies
   the setup prompt in one action.
3. Paste the copied message into your trusted Muse conversation.
   One message includes the setup line and a reusable Gmail SKILL bound to this
   app's relay origin. Return to Agent Gateway to confirm the pairing. Muse is
   instructed to discard the temporary setup line rather than save it in its skill.
   This message contains the temporary secret code. Do not post it publicly.
4. Inside Muse's existing runtime, with the existing private
   `GATEWAY_AGENT_STATE` selected, stop any MCP/CLI process using that same state
   file, then run:

   ```sh
   node agent-adapter/dist/src/cli.js pair
   ```

   Supply only the `AGW1.…` line on standard input, followed by a newline. The
   surrounding human instructions are not CLI input. Muse can extract that line
   from the copied message. Do not put it in command arguments, environment
   variables, shell history, or logs. Keep this process running while confirming.

5. The phone asks **Allow this Muse client to pair?** Allow only the attempt you
   just initiated, then authenticate with Face ID or the available device method.
   The client must prove knowledge of the code before this prompt appears.
6. The phone reports that both endpoints are paired after Muse verifies and saves
   the receipt. The CLI returns `status: paired` plus public transport configuration.

At the confirmation step, iOS also receives a local **Allow / Deny** notification.
Allow returns to the current pairing attempt and retains device authentication;
Deny cancels it. The matching dialog uses centered **Allow / Deny** buttons.
Notification permission is optional: the in-app dialog remains available if it is
denied. Notifications are bound to the live pairing session and expiry, contain
no PIN, and cannot confirm a cancelled or previous session. If iOS suspends the
app before it receives the pairing offer, return to the app to continue; this
local notification does not provide a background network service.

The code expires after at most thirty minutes and permits one attempt. There is no
numeric-code lookup: the setup line carries a random session address as well as
the code. This avoids exposing the authentication code to the relay. You do not
copy fingerprints, signed offers, or receipts during this flow.

The thirty-minute window requires matching updated phone, Muse client and relay
versions. Older Muse clients reject setup lines more than five minutes from expiry;
older relays close pairing sockets after five minutes. Gmail requests and disclosure
approvals still expire within five minutes; only the code-pairing window changed.

## Enable notification delivery separately

Pairing registers device-signed public transport identities in PairingRegistry.
Enable **Notifications** on the phone once and grant iOS permission.
The relay stores the encrypted push destination and selects it using the verified
pairing. No per-user secret edit, route copying or daily refresh is required.
The original setup prompt already contains the reusable Gmail skill.
See [relay setup](remote-delivery.md). Pairing itself sends no push.

## Request notifications

The Muse card confirms copying inline: “Copied the setup prompt. Paste it into
Muse's chatbox to continue”. No bottom copy-success banner is shown.

Request notifications say “An agent requests to access your data”. The iOS
notification category provides **Allow**, **Review**, and **Deny** actions.
Allow and Review open the matching request for the existing access and
disclosure confirmations; a generic notification never approves unseen data.
Deny opens the app and rejects the matching request without reading Gmail.

Foreground requests appear as banners and in Notification Center. Importing
ciphertext retains the notification until the request is handled or expires.
Push delivery sets a pending badge of 1; app synchronization reconciles the
actual pending-request count and clears it when none remain. Badge/notification
presentation still depends on the user's iOS notification settings.

Email previews use compact sender/avatar, subject, snippet and date rows. Only
requested fields appear. The card shows the email count; the request purpose,
query, limit and full disclosure are available under Details. Device confirmation
is still enforced for sensitive requests without a separate explanatory banner.

## Recovery

Ordinary users can unpair/disconnect and reconnect from the phone. Phone unpairing
revokes relay access but cannot delete the private state file in Muse's runtime.
A fresh phone setup prompt explicitly instructs the updated client to run
`pair --replace`. Muse stops the old MCP process and runs this itself; the user
does not need terminal commands, state-file deletion or relay configuration.
The old local pair remains until the new SRP exchange, device-signed receipt and
phone confirmation succeed. Failed/cancelled attempts retain it; successful
replacement preserves the agent identity and removes previous-epoch jobs/results.
Default `pair` still refuses to overwrite an existing pair without explicit intent.

Gmail connection is separate from pairing: disconnect/reconnect preserves the
existing pair. After phone unpairing and a new pairing, reconnect Gmail if needed
and explicitly enable **Notifications** for that new pair. The app shows
Gmail, Muse pairing and notification state and registers the new epoch's push
destination automatically. A rejected old relay pair is reported to CLI/MCP as
`relay_pairing_rejected`, not an indefinitely pending phone approval.

The home screen shows only connection controls and current requests needing
approval. Completed requests, fingerprints, transport details, local preview
tools and manual encrypted import/export are absent. Access and disclosure
approval remain separate. Protected protocol state needed for delivery retries
and replay prevention remains internal; there is no request-history screen.

- Wrong code, expiry, network loss or relay restart ends the attempt. Moving to the
  background can interrupt the socket on iOS; brief app switching may work, but confirmation waits for foreground resume. If interrupted, generate a new code.
- Cancellation or rejected device authentication grants no new pairing. A late
  authentication result cannot commit after session cancellation or expiry.
- An interrupted final receipt/acknowledgment can leave one endpoint paired.
  Unpair the phone and copy a fresh setup prompt; the updated Muse client uses
  `pair --replace` to recover. This is explicit recovery, not automatic rollback
  of a saved identity. Older clients can recover with CLI `unpair` before `pair`;
  these commands are run by Muse in its runtime, not by the phone user.
- Existing identities and the private agent state file are preserved. Do not
  delete state files or generate replacement keys just to retry pairing.
- **Advanced: manual pairing** retains the full-fingerprint fallback. Cancel the
  code session before using it. Neither method bypasses local authentication.

## Protocol and security

`AGW1.` is followed by unpadded base64url JSON with exactly `origin`, `session`,
`code`, and integer `expiresAt`. The session is 32 random bytes encoded as 64
lowercase hex characters; the independently generated code is eight decimal
digits, including leading zeros. Encoding is not encryption. Only the session
address enters relay URLs. Codes, SRP verifiers, session keys and endpoint private
keys never enter relay messages or storage.

The phone uses PointyCastle 4.0.0 `SRP6Server`/`SRP6VerifierGenerator`; Node uses
fast-srp-hap 2.0.4 `SrpClient` with its non-HomeKit evidence mode. Parameters are
the fixed RFC 5054 2048-bit group (`g=2`), SHA-256, fresh 32-byte salt, and fresh
ephemeral secrets. The identity is UTF-8
`agw-pin-v1:<exact HTTPS origin>:<session>`. No peer-selected group or hash is
accepted. This is an application SRP-6a exchange, not TLS-SRP or HomeKit pairing.

| Direction     | Record                                                                               |
| ------------- | ------------------------------------------------------------------------------------ |
| Relay → phone | `{kind: joined}` after the sole Muse socket joins                                    |
| Phone → Muse  | `{kind: challenge, salt, B, expiresAt}`                                              |
| Muse → phone  | `{kind: proof, A, M1}`                                                               |
| Phone → Muse  | Authenticated encrypted `ready` record                                               |
| Muse → phone  | Authenticated encrypted `offer` record containing the existing signed offer          |
| Phone → Muse  | After confirmation/authentication, encrypted `receipt` record and device fingerprint |
| Muse → phone  | After receipt verification and durable save, encrypted `complete` record             |

`A`/`B` are exactly 256-byte lowercase hex integers in `1..N-1`; salt is 32 bytes
and M1 is 32 bytes. Library evidence is `M1=SHA256(PAD(A)||PAD(B)||PAD(S))`.
The phone permits one proof, verifies it, and derives
`K=SHA256(PAD(S))` through the library. Server key confirmation is the `ready`
JWE under K, rather than the libraries' differing M2 representations. No offer
is sent or accepted until that confirmation succeeds.

Subsequent frames are exactly `{jwe: compact}`. JOSE libraries implement
`dir`/`A256GCM` with exact protected `{alg,enc,typ: agw+pin}` headers and fresh IVs.
Every encrypted record binds version 1, exact origin, session, original expiry
and expected message kind. This authenticates both endpoint identities inside the
existing signed offer/receipt flow. Wrong roles, modified records, replay into a
different session, expired exchanges and invalid signatures fail closed.

Relay endpoints are `GET /v1/pairing/<session>/device` and `/agent`, WebSocket
upgrades only. Origin headers and query parameters are rejected. One live phone,
one joining agent, at most five frames per peer, 8192 UTF-8 bytes per frame, and
thirty-minute relay timers bound resources. The phone additionally enforces exactly
the expected sequence and one authentication attempt, even against a malicious
relay. A relay reset loses the room, never recreates endpoint secrets.

The `PairingChannel` Durable Object uses ordinary live sockets and transient
memory only: no Storage API, hibernation attachments, durable mailbox, OAuth,
Gmail data, or approval authority. It forwards public SRP values and encrypted
records; it cannot perform passive offline PIN guessing from these messages.
An active attacker gets at most one online guess per phone session and can still
deny service. Codes must be delivered through a trusted Muse conversation.
Anyone who receives the setup prompt knows the code; the phone confirmation
protects against unsolicited pairing but cannot distinguish two holders of it.

Fresh public session addresses prevent enumeration, but do not authenticate room
creation or provide global quota protection. Configure operational Cloudflare
abuse controls for the pairing paths. No distributed rate-limit guarantee or
independent security audit is claimed. Managed runtimes cannot guarantee erasure
of all PIN/BigInt copies; derived byte keys are cleared and sessions are not saved.

Tests cover real Dart↔Node SRP/signed receipt interoperability, wrong codes,
zero public values, message tampering/context mismatch, expiry/cancellation,
redirect rejection, and actual Worker-runtime single-use forwarding. Physical
iPhone/Muse acceptance and signed release distribution still require verification.

References: [SRP group specification](https://www.rfc-editor.org/rfc/rfc5054.html),
[PointyCastle implementation](https://github.com/bcgit/pc-dart),
[Node implementation](https://github.com/homebridge/fast-srp).
