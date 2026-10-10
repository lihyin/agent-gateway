import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../scripts/configure-ios-oauth.dart';

void main() {
  test('build redirect matches Dart OAuth configuration and preserves native plist', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final configured = configureIosOAuth(
      '123-abc.apps.googleusercontent.com',
      plist,
    );
    expect(
      configured,
      contains('<string>com.googleusercontent.apps.123-abc</string>'),
    );
    expect(configured, contains('NSFaceIDUsageDescription'));
    expect(
      configureIosOAuth('', configured),
      contains('com.agentbrain.agentgateway.oauth-disabled'),
    );
    expect(
      () => configureIosOAuth('invalid<script>', plist),
      throwsFormatException,
    );
    expect(() => configureIosOAuth('', '<plist/>'), throwsFormatException);
  });
}
