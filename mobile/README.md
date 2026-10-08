# Agent Gateway Mobile

Flutter Android/iOS foundation for the mobile-authoritative gateway. Run `flutter pub get`, `flutter analyze`, `flutter test`, and `flutter run` from this directory.

The Day 1 shell cannot connect sources or approve agent requests. Release configuration uses `ENVIRONMENT`, `RELAY_URL`, and `RELEASE_SHA` Dart defines. Signing/distribution runs through the repository-root Codemagic workflows; see [production setup](../docs/production-setup.md).

The confirmed iOS bundle ID is `com.agentbrain.agentgateway`; its App Store Connect app and App Store provisioning profile must match. The Android application ID remains provisional as `com.deepshareai.agentgateway`, with distribution deferred. Android release builds require real keystore credentials and never fall back to debug signing.
