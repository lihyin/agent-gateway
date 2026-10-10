# Security boundaries

## Trust model

Foreground pairing/delivery now pins one agent's signing/encryption keys after
full fingerprint comparison and device authentication. The agent verifies the
phone's signed receipt against its offer nonce/digest and a separately compared
device fingerprint. Device keys/replay state stay in the device-only vault; agent
keys use owner-restricted files and an exclusive process lock.

Manual transfer uses exact-header ES256 JWS inside RSA-OAEP-256/A256GCM JWE.
Pinned identities/epoch, signed/outer context, direction, sizes and expiry are
checked before review. Durable reservation precedes execution; changed same-ID
ciphertext and disconnected review reopening fail closed. Export rechecks current
approval revision/digest, pairing and expiry; retries return saved ciphertext.
The agent verifies results against its pending request. No automatic push,
route issuance, callback forwarding, or hardware-backed key operations are
claimed. See [paired delivery](paired-delivery.md) for physical-device checks.

The mobile domain layer enforces private-source access independently from UI widgets. Source tokens, device private keys, policies, pending approvals, replay history, and audit records remain on-device.

The Worker and push providers are untrusted for payload confidentiality and authorization. They observe routing metadata and can disrupt delivery. A compromised relay must not decrypt payloads, impersonate paired identities, substitute recipient keys, change requests undetected, or authorize disclosure. The agent can retain data after decrypting an approved result; approval UI must make this disclosure boundary clear.

## Required controls

- Authenticate pairing and pin keys. Use reviewed encryption/signature libraries and bind message direction, version, identities, request ID, and expiry.
- Perform OAuth and refresh locally with PKCE, state, validated redirects, and minimum scopes. Never send source tokens through the relay.
- Protect mobile secrets using platform secure storage. Define locked-device behavior, backup exclusions, rotation, source disconnect, and unpairing. Verify hardware-backed capabilities instead of assuming every key supports them.
- Evaluate deterministic default-deny policy before connector access. Obtain consent for sensitive retrieval and review final filtered disclosures where required.
- Restrict edits to authorized scope and rerun filtering. Bound and revoke Always rules; require explicit local confirmation for high risk.
- Recheck expiry and pairing before source access and release. Persist replay protection across restarts and prevent duplicate/conflicting disclosures.
- Use encrypted push envelopes and generic alerts. Display private details only inside the app after appropriate authentication.
- Validate/authenticate bounded Worker envelopes and expiring routing capabilities. Restrict callbacks to verified HTTPS origins and block SSRF/unsafe redirects. Durable distributed rate limiting requires an explicit review of its state/metadata footprint; Worker memory is insufficient.
- Store APNs/FCM and routing secrets through deployment secret management. They must not decrypt payloads. Redact capabilities, tokens, secrets, and payloads from telemetry.
- Keep scoped Cloudflare deployment and Codemagic orchestration credentials in GitHub Actions secrets; keep Android/Apple signing and distribution credentials in Codemagic managed secret groups. Untrusted PR jobs cannot access release secrets. Deploy/build the verified commit, validate orchestration callback origin/authentication and revision correlation, and exclude secrets from logs/artifacts. Compose uses mock credentials and does not mount production signing secrets or device vaults.
- Audit minimal metadata locally with retention controls. Deterministic PII filtering has incomplete coverage; do not promise perfect redaction.

## Failures and limitations

Unknown agents/scopes, tampering, wrong keys, replay, stale pairing, expired approvals, unsupported versions, and oversize envelopes fail closed. Offline/delayed push cannot trigger relay-side source access. Denials and errors are encrypted. The app owns bounded retries; the agent owns timeout and receipt state.

Local unpairing immediately denies access on-device, but stateless routing cannot instantly revoke previously issued transport capabilities globally. Short capability lifetimes limit that window. Device loss requires re-pairing and reconnecting sources; the relay cannot recover payload private keys.

## Required verification

The protocol design gate selects nested ES256 JWS inside RSA-OAEP-256/A256GCM
JWE, with separate signing/encryption keys and pinned identities. Public test-only
fixtures exercise TypeScript-to-Dart and Dart-to-TypeScript interoperability.
Closed schemas reject unknown fields/versions and bound payload sizes/expiry.
See [ADR 002](crypto-design.md) for algorithm restrictions, key rotation, and the
absence of forward secrecy. Pairing and protected foreground replay/key storage
are implemented separately; fixture success does not establish native-device
acceptance or automatic transport.

Test cross-agent/device access, key substitution, context tampering, reflection, replay after restart, revoked pairing, expired approvals, Edit/Always escalation, connector bounds, PII/credential leakage, OAuth redirects/state, callback SSRF, and push/log content. Add cross-runtime crypto fixtures and physical iOS/Android checks for locked/killed apps, secure storage, push delays/duplicates, and biometrics.

The relay still exposes health only and rejects unfinished routes; the demo
adapter does not accept callbacks. Mobile supports configured iOS Gmail OAuth,
local previews and paired foreground requests. Native AppAuth owns PKCE/state
and redirect validation; Google credentials and pending reviews live in
device-only unlocked Keychain storage. Requests are bounded/default-deny, checked
before and during retrieval and after device confirmation, then minimized and
filtered. Allow/Deny/Edit/Always bind candidate revision/digest and current epoch.
State-write failure fails closed; replay survives restart and interrupted fetches
do not repeat. Exact-scope rules expire after 24 hours and cannot bypass source
consent or high-risk confirmation. Explicit encrypted export delivers approved
results to the pinned agent. Automatic push/relay handoff remains incomplete.
See [Gmail setup](gmail-setup.md) for scope, retention, provider configuration,
filtering coverage, and outstanding physical-device acceptance.

Release Gradle configuration requires actual signing credentials with no
debug-key fallback. CI has read-only repository permissions; production secrets
belong only to trusted release jobs and provider settings. The complete agent
private-data security pipeline is not yet implemented or independently audited.
