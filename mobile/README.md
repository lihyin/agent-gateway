# Agent Gateway Mobile

Flutter Android/iOS foundation for the mobile-authoritative gateway. Run `flutter pub get`, `flutter analyze`, `flutter test`, and `flutter run` from this directory.

The app supports configured iOS Gmail sign-in and bounded device-local previews, with source-access consent and filtered Allow/Deny/Edit/Always review. Actual agent requests and transmission remain disabled. Configure the public `GOOGLE_IOS_CLIENT_ID` and native redirect as described in [Gmail setup](../docs/gmail-setup.md). Release configuration also uses `ENVIRONMENT`, `RELAY_URL`, and `RELEASE_SHA`. Native signing/distribution runs through Codemagic; see [production setup](../docs/production-setup.md).

The confirmed iOS bundle ID is `com.agentbrain.agentgateway`; its App Store Connect app and App Store provisioning profile must match. The Android application ID remains provisional as `com.deepshareai.agentgateway`, with distribution deferred. Android release builds require real keystore credentials and never fall back to debug signing.
