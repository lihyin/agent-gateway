# Device-local Gmail and review

This build adds iOS Gmail sign-in and a user-initiated, device-local review flow.
It does not yet receive agent requests or transmit approved data. Production relay
routes remain health-only. The verified-pairing resolver is a dependency boundary;
the shipped app recognizes only its device-owner preview identity, never network
claims about an agent. Mock tests use synthetic agents/data.

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

Only `gmail.readonly` is requested: Gmail search queries need this scope;
`gmail.metadata` does not permit `q`. No sending, modification, deletion,
attachments, or body retrieval is implemented. Google classifies this as a
restricted scope; provider verification requirements depend on distribution.
No Gmail credential is sent to Cloudflare, Codemagic, or an agent.

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
- **Edit** permits field removal and text shortening, then filters again. Values,
  identities, and scope cannot be widened.
- **Always** stores an exact query/purpose/fields/time-window/result-limit rule
  for 24 hours. It still requires consent before fetching. High-risk fields cannot
  use Always. Revoke rules in the app; disconnect removes all source review state.

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

To enable actual agent delivery, finish authenticated pairing, protected device
keys/replay persistence, stateless encrypted transport/push, and encrypted result
handoff, then exercise the same domain pipeline. No fallback plaintext upload,
server OAuth vault, or web approval authority is provided.
