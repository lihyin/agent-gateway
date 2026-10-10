import 'dart:io';

String configureIosOAuth(String client, String plist) {
  if (client.isNotEmpty &&
      !RegExp(r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$')
          .hasMatch(client)) {
    throw const FormatException('Invalid Google iOS OAuth client ID');
  }
  final scheme = client.isEmpty
      ? 'com.agentbrain.agentgateway.oauth-disabled'
      : client.split('.').reversed.join('.');
  final entry = RegExp(
    r'(<key>CFBundleURLSchemes</key>\s*<array>\s*<string>)[^<]*(</string>)',
  );
  if (entry.allMatches(plist).length != 1) {
    throw const FormatException('Expected one native OAuth redirect scheme');
  }
  return plist.replaceFirstMapped(
    entry,
    (match) => '${match[1]}$scheme${match[2]}',
  );
}

void main() {
  final client = Platform.environment['GOOGLE_IOS_CLIENT_ID'] ?? '';
  final file = File('mobile/ios/Runner/Info.plist');
  file.writeAsStringSync(configureIosOAuth(client, file.readAsStringSync()));
  stdout.writeln(
    client.isEmpty
        ? 'Gmail OAuth disabled: no iOS client configured'
        : 'Gmail native OAuth configured',
  );
}
