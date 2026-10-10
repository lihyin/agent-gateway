import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jose/jose.dart';

void main() {
  test('TypeScript JOSE fixture decrypts and verifies in Dart; reverse fixture generated', () async {
    final fixture = jsonDecode(
      File('../protocol/fixtures/crypto.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final encryptionKeys = JsonWebKeyStore()
      ..addKey(JsonWebKey.fromJson(fixture['encryptionPrivate']));
    final signingKeys = JsonWebKeyStore()
      ..addKey(JsonWebKey.fromJson(fixture['signingPublic']));
    final envelope = fixture['envelope'] as Map<String, dynamic>;
    expect(utf8.encode(jsonEncode(envelope)).length, lessThan(3500));
    final jwe = JsonWebEncryption.fromCompactSerialization(envelope['jwe']);
    final decrypted = await jwe.getPayload(encryptionKeys);
    final jws = JsonWebSignature.fromCompactSerialization(
      utf8.decode(decrypted.data),
    );
    final verified = await jws.getPayload(signingKeys);
    expect(jsonDecode(utf8.decode(verified.data)), {
      'context': envelope['context'],
      'payload': fixture['payload'],
    });
    final signature = JsonWebSignatureBuilder()
      ..content = jsonEncode({
        'context': envelope['context'],
        'payload': fixture['payload'],
      })
      ..setProtectedHeader('typ', 'agw+jws')
      ..addRecipient(
        JsonWebKey.fromJson(fixture['signingPrivate']),
        algorithm: 'ES256',
      );
    final encrypted = JsonWebEncryptionBuilder()
      ..content = signature.build().toCompactSerialization()
      ..encryptionAlgorithm = 'A256GCM'
      ..setProtectedHeader('cty', 'agw+jws')
      ..addRecipient(
        JsonWebKey.fromJson(fixture['encryptionPublic']),
        algorithm: 'RSA-OAEP-256',
      );
    File('.dart_tool/crypto-interop.json').writeAsStringSync(
      jsonEncode({'jwe': encrypted.build().toCompactSerialization()}),
    );
  });
}
