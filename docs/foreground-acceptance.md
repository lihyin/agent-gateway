# Relay-only acceptance

The implementation has changed from separate hosted-bridge polling to direct
Muse-runtime outbound WebSocket transport through the Cloudflare relay and APNs.
Earlier deployments such as `6af1f5e` do not prove this new implementation is live.
The latest prior signed release failed TestFlight post-processing; distribution
must be retried only after provider errors and push-signing prerequisites are fixed.

## Automated evidence

Tests cover signed route issuance and sealing, wrong keys/epoch/audience/expiry,
route tampering, notification size/generic text/fixed provider, and a real local
Cloudflare Worker-runtime encrypted request/result WebSocket round trip with
mocked APNs. The local stable runtime uses compatibility date 2026-08-06, while
production Wrangler targets 2026-10-01. Flutter tests cover notification import
without source access, disclosure filtering/encryption, registration/revocation,
provider failures and the existing approval/replay pipeline.

These tests establish neither live Apple delivery nor a real Muse installation.
Native Swift compilation requires macOS/CI; device behavior requires an iPhone.
See the final implementation report for commands actually run.

## Provider setup still required

- Enable Apple Push Notifications for `com.agentbrain.agentgateway` and select
  matching provisioning profiles. Set production APNs credentials on the relay.
- Deploy the tested relay revision with the `CHANNELS` binding/class migration,
  routing key and public pairing configuration.
- Install the client inside the existing personal Muse runtime and complete real
  [code pairing](pin-pairing.md). No separate server/domain is a prerequisite.
- Install a matching signed iPhone build, connect Gmail, enable notifications,
  and transfer its sealed delivery route to Muse.

## Physical iPhone and Muse checks

Record app revision/build, device/iOS version, date and outcome. Every row is
currently pending physical/provider acceptance.

| Check               | Expected behavior                                                                                                                                                                                                                                                                |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Install/configure   | Signed app launches; Gmail redirect and push registration work.                                                                                                                                                                                                                  |
| Pair                | Setup message reaches trusted Muse; phone approval/authentication and mutual pairing succeed. Wrong code, duplicate join, cancellation, expiry and relay restart fail closed; background resume never approves pairing automatically. Manual fingerprint fallback remains valid. |
| Notify              | Muse's outbound client receives upgrade acceptance; generic alert arrives without private fields.                                                                                                                                                                                |
| Tap/resume          | App imports a protected ciphertext request; Gmail fetch count remains zero before consent.                                                                                                                                                                                       |
| Allow               | Access consent precedes fetch; disclosure approval precedes only filtered data returning to Muse.                                                                                                                                                                                |
| Deny/edit           | Denial returns no messages; edits cannot widen scope and are filtered again.                                                                                                                                                                                                     |
| Offline/reconnect   | Same ID/ciphertext retries; no duplicate fetch; saved encrypted result can be handed off again.                                                                                                                                                                                  |
| Expiry              | Late notification/result fails; retries do not extend the original five minutes.                                                                                                                                                                                                 |
| Restart/lock        | Ciphertext receipt survives restart after receipt; source access requires unlocked app and domain consent.                                                                                                                                                                       |
| Disable/unpair      | Local acceptance/release stops; replacing relay pins invalidates the old route.                                                                                                                                                                                                  |
| Token/route refresh | New device token obtains a new route; expired/stale routes fail; operator conveys replacement to Muse.                                                                                                                                                                           |
| Agent receipt       | Verified Muse-side result differs from relay transport acceptance; no source token reaches Muse.                                                                                                                                                                                 |

Use a dedicated synthetic Gmail test account. Record outcome metadata, not email
content, credentials, private keys, route tokens or authenticated proofs.
