# Relay-only Muse delivery

The production topology has three participants: Meta Muse, the existing Cloudflare
relay, and the iPhone. No separately hosted bridge, callback server, extra domain,
or always-on personal PC is required. Agent-side code runs as an outbound client
inside Muse's existing runtime. The local stdio MCP adapter is optional.

```text
Muse runtime -- encrypted request / outbound WebSocket --> Cloudflare relay
                                                            |
                                                     APNs notification
                                                            v
                                                         iPhone
                                                            |
                                             review access, fetch Gmail directly,
                                             filter, approve disclosure
                                                            |
Muse runtime <-- encrypted result on same WebSocket ----- relay
```

## Waiting without a mailbox

A Cloudflare Durable Object coordinates each live request connection inside the
relay deployment. It uses no Storage API or application database. Socket
attachments contain only authenticated context and a ciphertext digest, never
request/result bodies, push tokens, Gmail data or keys. Requests are forwarded
directly into APNs; results are forwarded to the live Muse socket.

This deliberately revises the earlier strictly stateless/callback-only design:
the relay has transient connection coordination, but no durable request/result
mailbox. A timer bounds the socket to the original request's five-minute expiry.
Process replacement or connection loss can interrupt delivery. Muse retains its
request and retries the same ID and ciphertext; the phone retains its protected
review, replay ledger and encrypted result. No relay memory is needed for recovery.
There is no status-polling database on the relay. MCP status reads agent-owned
state inside Muse's runtime.

## Authentication and routing

The phone and Muse-side client generate separate signing and encryption keys and
complete [one-time-code pairing](pin-pairing.md), with full-fingerprint comparison as an advanced fallback. A separate live PairingChannel inside the same relay forwards public SRP values and encrypted signed offers/receipts for at most thirty minutes, without storage, payload attachments, or endpoint secrets. Resets require a fresh code. The phone registers its device-signed public pair record in PairingRegistry.
The registry supports multiple users and is the sole transport authority.
Private keys stay at the endpoints.

The phone registers its APNs token with a short-lived signed proof. The relay
persists only an encrypted destination bound to the pair and automatically looks
it up after verifying each agent request. No daily route handoff is needed.
Token updates are automatic while the app runs and on resume. Disabling delivery
or unpairing revokes server state with a device signature; re-pairing retires the
old epoch and clears its destination. See [security](security.md).

## Device behavior

APNs receives a generic alert and a bounded encrypted envelope, at most 4096
bytes including wrappers. Source, query, purpose and data never appear in alert
text. APNs is best effort, not authorization or a guaranteed offline mailbox.

Native iOS code receives foreground alerts and notification taps. It also reads
already delivered notifications when the app resumes. A bounded, backup-excluded,
protected local ciphertext inbox survives process restart after receipt. The app
imports requests only while open, connected to Gmail and opted into this pairing.
Nothing in notification receipt or tapping fetches Gmail or approves disclosure.

The app evaluates policy and requests access consent before Gmail retrieval,
fetches directly using its Keychain credentials, minimizes and filters results,
then obtains disclosure approval. Sender/snippet fields require local confirmation.
Allow/Deny/Edit/Always and final expiry/epoch/revision checks remain in the common
domain pipeline. The app sends encrypted outcomes while open and retries failed
handoffs within original expiry. Background Gmail execution is not implemented.

## Deployment and verification

Only the Cloudflare Worker and its internal live-channel binding are deployed as
a server. GitHub Actions and Codemagic remain build/distribution services. APNs
credentials and routing secrets belong in Worker secrets, never in Muse or phone
builds. Source OAuth credentials remain exclusively on the phone.

See [setup](remote-delivery.md), [API](api.md), [security](security.md),
[protocol](../protocol/README.md) and [acceptance](foreground-acceptance.md).
Android/FCM transport and real personal-Muse installation remain unverified.
