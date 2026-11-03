# Google OAuth privacy information

Updated November 2, 2026 against Google's [App Privacy Policy guidance](https://support.google.com/cloud/answer/13806988).

Public URLs verified as HTTP 200:

- Homepage: https://gateway.zerobox.ai/
- Privacy Policy: https://gateway.zerobox.ai/privacy/
- Terms of Use: https://gateway.zerobox.ai/terms/
- Contact: https://gateway.zerobox.ai/contact/

The root `PRIVACY_POLICY.txt` and `TERMS_OF_SERVICE.txt` generate dedicated
HTML legal pages through `website/build.mjs`. The homepage navigation, footer,
and Gmail data-use notice link to them. The mobile home screen displays both
links above Connect Gmail, including when not signed in. A disclosure before
Google OAuth repeats the links and explains the actual access and sharing flow.
Policy updates are dated on both the pages and the in-app notice.

## Common findings addressed

| Google finding                   | Implementation                                                                                                                                                                                                                 |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Missing or hard-to-find policy   | Named links in homepage navigation and Gmail notice, mobile home card, and pre-OAuth dialog.                                                                                                                                   |
| Unsupported document format      | Dedicated HTML page body; plain-text downloads are optional alternatives. No embedded document or iframe is required.                                                                                                          |
| Homepage reused as policy URL    | Distinct `/privacy/` URL on the same `gateway.zerobox.ai` domain.                                                                                                                                                              |
| App or operator unclear          | Both documents identify Agent Gateway, Zerobox, and `hello@zerobox.ai`.                                                                                                                                                        |
| Accessed Google data unclear     | Policy lists OAuth tokens, Gmail read-only and send scopes, sender address, selected message fields, outgoing recipients/content, and search context; explains why metadata-only scope cannot support the implemented queries. |
| Use or sharing unclear           | Policy distinguishes Google connection, Preview, direct Allow, Deny, paired Muse, Cloudflare relay, Apple notifications, and separately reviewed outgoing email delivered directly through Gmail.                              |
| Security omitted                 | Device-only Keychain, endpoint encryption, protected inbox, and limitations are described.                                                                                                                                     |
| Retention or deletion omitted    | Local expiry and cleanup, audit limits, persistent revocation records, disconnect/unpair, Google revocation, and operator deletion requests are described.                                                                     |
| Prohibited AI or other uses      | Explicit prohibition on developing, improving, or training non-personalized AI/ML models and on advertising, resale, and credit/lending uses; Limited Use statement and links.                                                 |
| Outdated description of behavior | Removed preview-edit claims; documented optional preview and direct one-time Allow, plus notification defaults.                                                                                                                |

## Deployment and Google Console checks

Publish the generated website and ship the app update before representing the
new notices as live. Configure the OAuth Branding homepage, Privacy Policy,
and Terms URLs to the public URLs above, using the same Agent Gateway identity.
Verify ownership of the authorized domain `zerobox.ai` in the Google project;
public HTTP availability does not establish Search Console ownership.

Google verification submission, authorization-screen branding, ownership,
reviewer access, and any restricted-scope assessment requirements must be
checked separately. These repository changes do not submit verification,
prove approval, or certify a third-party agent's data handling. Ensure the paired
AI service's configuration and terms support the policy's data-use restrictions.

Sending requires adding https://www.googleapis.com/auth/gmail.send alongside the existing read-only scope in Google OAuth configuration and verification. Old read-only grants require reconnecting before sending. The app uses no gmail.compose scope or Gmail draft storage. Test real-device authentication and Gmail delivery before release; mocked tests do not establish provider acceptance.
