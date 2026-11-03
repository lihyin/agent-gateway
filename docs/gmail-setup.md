# Device-local Gmail and review

This build supports iOS Gmail sign-in, local previews, and fingerprint-paired
agent requests through manual foreground encrypted transfer. Approved results
can be exported encrypted for that agent. Configured relay routes support APNs notifications and encrypted result return over Muse outbound connections.
See [paired delivery](paired-delivery.md). Live provider/device acceptance remains
required; mocked tests use synthetic agents/data.

## Google setup

1. Enable Gmail API in the Google Cloud project you own.
2. Configure the OAuth consent screen and add the intended Gmail test accounts.
3. Create an **iOS** OAuth client for `com.agentbrain.agentgateway`. Do not use a
   web client or embed a client secret. Google may require its public app/team
   identifiers as described in its native-app setup instructions.
4. Add the public `GOOGLE_IOS_CLIENT_ID` to Codemagic's `production_mobile` group.
   `scripts/configure-ios-oauth.dart` derives its reversed client scheme and updates
   `CFBundleURLTypes` before the IPA build; Dart receives the same client ID.
   For a local Mac build, run that script with the environment variable, then
   `flutter run --dart-define=GOOGLE_IOS_CLIENT_ID=<public-client-id>` from `mobile`.
5. Use the native browser consent flow. AppAuth generates and validates PKCE and
   OAuth state, exchanges codes with the exact configured redirect, and provides
   refresh tokens. Cancelled/error responses are sanitized in the app.

The app requests `gmail.readonly` for bounded searches and `gmail.send` for
Muse-composed outgoing email. Metadata-only scope does not permit search
queries. Existing read-only grants remain usable for searches; reconnect and
consent to sending before allowing send requests. Google classifies read-only as
restricted and send as sensitive; configure both in the consent screen and
complete the applicable verification before public distribution.

Muse submits encrypted requests with From, To, Cc, Bcc, subject, and plain-text body. The complete
message is reviewed, then Allow and device authentication authorize one submission
directly to Gmail. Data-search approval never authorizes sending. No attachments,
Gmail drafts, or modification/deletion of existing mail are implemented. Requests
remain in secure device review storage with bounded retention. An
uncertain send is not retried automatically; check Gmail Sent first.
No Gmail credential is sent to Cloudflare, Codemagic, or an agent.

Muse uses MCP `gmail_request_send`, or CLI `relay-request` with the send payload.
Supply source `gmail`, operation `send`, purpose, from (matching connected Gmail),
to/cc/bcc arrays, subject, and body. The entire request payload must fit 1200 UTF-8
bytes under the existing encrypted notification budget. At most 20 recipients
total; no silent truncation. A fresh UUID identifies a new user-authorized request;
transport retries reuse the same UUID and exact content. Gateway persists a send
reservation before authentication/submission. Restarted, failed, or uncertain
attempts are never retried. Only an allowed result with a Gmail message ID confirms
submission; an error or expiry requires checking Gmail Sent before a new request.

Sources: [Google native OAuth](https://developers.google.com/identity/protocols/oauth2/native-app),
[Gmail list API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list),
[AppAuth](https://pub.dev/packages/flutter_appauth).

## Review flow

Connect Gmail, enter a bounded query and purpose, and request a local preview.
The app limits the preview to five messages in the last seven days. You must
approve source access before the connector can run. Optional sender/snippet
fields require device authentication before access and before final approval.
Provider calls go directly from the device to fixed Google HTTPS endpoints, never
follow redirects, and have bounded response size, pagination, and timeouts.

The preview includes only requested metadata fields; email addresses, numeric
phone/payment-like identifiers, SSN, IBAN-like and labeled account/medical
identifiers are filtered. This is deterministic best-effort filtering, not an
assurance that all sensitive information is recognized. Review the preview.

- **Allow once** approves this candidate version locally.
- **Deny** retains no candidate and authorizes no disclosure.
- Initial **Allow** retrieves and shares once without a preview; **Preview** lets
  you inspect before allowing disclosure. The current UI provides no Edit action.
- Previously saved exact-scope disclosure rules expire within 24 hours and can be
  reset. They never approve sending. Send requests always show the exact email
  for Allow/Decline and require device authentication; they have no Always action.

Requests expire after five minutes. Approval checks request identity, epoch,
revision, and candidate digest again after asynchronous device authentication.
Replay state survives restart; interrupted fetches fail rather than rerun.
Expired candidates are cleared. Replay/inbox records are retained at most 24
hours, with at most 20 entries; minimal audit is capped at 100 events/seven days.
Secure-state write failure disables further transitions until successful reload.

## Device acceptance still required

Tokens and review state use Keychain `unlocked_this_device`, without iCloud
synchronization; Android backup is disabled. Android sign-in is intentionally
disabled until its own supported Google client/native flow is configured.
TestFlight/native signing must include the configured Keychain entitlement.
The iOS shared disk HTTP cache is disabled; private preview content is obscured
when the app becomes inactive.

On the iPhone verify browser redirect/cancellation, token survival after restart,
locked-device vault behavior, revoked grants, offline disconnect, Face ID/passcode
confirmation and cancellation, and privacy in the app switcher. Provider revocation
can fail offline: local credentials are still deleted, and the app instructs the
user to remove the grant in Google account settings. No live provider/device
acceptance is claimed from mocked tests.

Automatic notification delivery uses the configured relay transport; see [relay-only setup](remote-delivery.md). Manual encrypted transfer uses the same domain
pipeline. No plaintext upload, server OAuth vault, or web approval authority is
provided.
