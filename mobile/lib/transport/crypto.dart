import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jose/jose.dart';

import '../domain/gateway_error.dart';

String canonical(dynamic value) {
  if (value is List) return '[${value.map(canonical).join(',')}]';
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}

String hash(dynamic value) =>
    sha256.convert(utf8.encode(canonical(value))).toString();
String uuid() {
  final r = Random.secure();
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final s = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

Map<String, dynamic> generateIdentity(int _) {
  Map<String, dynamic> normalized(JsonWebKey key) {
    final value = Map<String, dynamic>.from(key.toJson());
    for (final k in ['x', 'y', 'd', 'n', 'e', 'p', 'q', 'dp', 'dq', 'qi']) {
      if (value[k] is String) {
        List<int> bytes = base64Url.decode(base64Url.normalize(value[k]));
        if (value['kty'] == 'EC' && ['x', 'y', 'd'].contains(k)) {
          bytes = [...List.filled(32 - bytes.length, 0), ...bytes];
        }
        value[k] = base64Url.encode(bytes).replaceAll('=', '');
      }
    }
    return value;
  }

  return {
    'signing': normalized(JsonWebKey.generate('ES256')),
    'encryption': normalized(
      JsonWebKey.generate('RSA-OAEP-256', keyBitLength: 2048),
    ),
  };
}

Map<String, dynamic> publicIdentity(Map<String, dynamic> identity) => {
  'signing': {
    for (final k in ['kty', 'crv', 'x', 'y']) k: identity['signing'][k],
  },
  'encryption': {
    for (final k in ['kty', 'n', 'e']) k: identity['encryption'][k],
  },
};
String identityId(Map<String, dynamic> identity) => base64Url
    .encode(
      sha256
          .convert(utf8.encode(canonical(publicIdentity(identity)['signing'])))
          .bytes,
    )
    .replaceAll('=', '');
void exactKeys(Map value, Set<String> keys) {
  if (value.length != keys.length || !keys.containsAll(value.keys)) {
    throw const GatewayError('invalid_envelope');
  }
}

void validatePublicIdentity(Map<String, dynamic> identity) {
  exactKeys(identity, {'signing', 'encryption'});
  final s = identity['signing'] as Map, e = identity['encryption'] as Map;
  exactKeys(s, {'kty', 'crv', 'x', 'y'});
  exactKeys(e, {'kty', 'n', 'e'});
  if (s['kty'] != 'EC' ||
      s['crv'] != 'P-256' ||
      e['kty'] != 'RSA' ||
      e['e'] != 'AQAB') {
    throw const GatewayError('invalid_envelope');
  }
  for (final v in [s['x'], s['y'], e['n']]) {
    if (v is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v)) {
      throw const GatewayError('invalid_envelope');
    }
  }
  if (base64Url.decode(base64Url.normalize(s['x'])).length != 32 ||
      base64Url.decode(base64Url.normalize(s['y'])).length != 32 ||
      base64Url.decode(base64Url.normalize(e['n'])).length != 256) {
    throw const GatewayError('invalid_envelope');
  }
  JsonWebKey.fromJson(identity['signing']);
  JsonWebKey.fromJson(identity['encryption']);
}

Map<String, dynamic> protectedHeader(String compact, int segments) {
  final parts = compact.split('.');
  if (parts.length != segments ||
      parts.any((p) => p.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(p))) {
    throw const GatewayError('invalid_envelope');
  }
  return Map<String, dynamic>.from(
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts.first)))),
  );
}

String signObject(
  Map<String, dynamic> identity,
  Map<String, dynamic> value,
  String type,
) {
  final builder = JsonWebSignatureBuilder()
    ..content = jsonEncode(value)
    ..setProtectedHeader('typ', type)
    ..addRecipient(
      JsonWebKey.fromJson(identity['signing']),
      algorithm: 'ES256',
    );
  return builder.build().toCompactSerialization();
}

Future<Map<String, dynamic>> verifyObject(
  Map<String, dynamic> signing,
  String compact,
  String type,
) async {
  if (canonical(protectedHeader(compact, 3)) !=
      canonical({'alg': 'ES256', 'typ': type})) {
    throw const GatewayError('invalid_envelope');
  }
  final keys = JsonWebKeyStore()..addKey(JsonWebKey.fromJson(signing));
  final payload = await JsonWebSignature.fromCompactSerialization(compact)
      .getPayload(keys);
  return Map<String, dynamic>.from(jsonDecode(utf8.decode(payload.data)));
}

void validateContext(Map<String, dynamic> c, DateTime now) {
  exactKeys(c, {
    'version',
    'direction',
    'requestId',
    'sender',
    'recipient',
    'pairingEpoch',
    'issuedAt',
    'expiresAt',
  });
  final u = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  final id = RegExp(r'^[A-Za-z0-9_-]{43}$');
  final seconds = now.millisecondsSinceEpoch ~/ 1000;
  if (c['version'] != 1 ||
      !['request', 'result'].contains(c['direction']) ||
      c['requestId'] is! String ||
      !u.hasMatch(c['requestId']) ||
      c['pairingEpoch'] is! String ||
      !u.hasMatch(c['pairingEpoch']) ||
      c['sender'] is! String ||
      !id.hasMatch(c['sender']) ||
      c['recipient'] is! String ||
      !id.hasMatch(c['recipient']) ||
      c['issuedAt'] is! int ||
      c['expiresAt'] is! int ||
      c['issuedAt'] < 0 ||
      c['issuedAt'] > seconds ||
      c['expiresAt'] <= seconds ||
      c['expiresAt'] <= c['issuedAt'] ||
      c['expiresAt'] - c['issuedAt'] > 300) {
    throw const GatewayError('invalid_or_expired_request');
  }
}

Map<String, dynamic> encryptEnvelope(
  Map<String, dynamic> identity,
  Map<String, dynamic> recipient,
  Map<String, dynamic> context,
  Map<String, dynamic> payload,
) {
  final signature = signObject(identity, {
    'context': context,
    'payload': payload,
  }, 'agw+jws');
  final builder = JsonWebEncryptionBuilder()
    ..content = signature
    ..encryptionAlgorithm = 'A256GCM'
    ..setProtectedHeader('cty', 'agw+jws')
    ..addRecipient(
      JsonWebKey.fromJson(recipient['encryption']),
      algorithm: 'RSA-OAEP-256',
    );
  final envelope = {
    'context': context,
    'jwe': builder.build().toCompactSerialization(),
  };
  if (utf8.encode(jsonEncode(envelope)).length >
      (context['direction'] == 'request' ? 3500 : 65536)) {
    throw const GatewayError('invalid_envelope');
  }
  return envelope;
}

Future<Map<String, dynamic>> decryptEnvelope(
  Map<String, dynamic> identity,
  Map<String, dynamic> sender,
  Map<String, dynamic> envelope,
  Map<String, dynamic> expected,
  DateTime now,
) async {
  exactKeys(envelope, {'context', 'jwe'});
  validateContext(Map<String, dynamic>.from(envelope['context']), now);
  if (canonical(envelope['context']) != canonical(expected) ||
      utf8.encode(jsonEncode(envelope)).length >
          (expected['direction'] == 'request' ? 3500 : 65536)) {
    throw const GatewayError('invalid_envelope');
  }
  final jwe = envelope['jwe'] as String;
  if (canonical(protectedHeader(jwe, 5)) !=
      canonical({'alg': 'RSA-OAEP-256', 'enc': 'A256GCM', 'cty': 'agw+jws'})) {
    throw const GatewayError('invalid_envelope');
  }
  final keys = JsonWebKeyStore()
    ..addKey(JsonWebKey.fromJson(identity['encryption']));
  final clear = await JsonWebEncryption.fromCompactSerialization(jwe)
      .getPayload(keys);
  final signed = await verifyObject(
    Map<String, dynamic>.from(sender['signing']),
    utf8.decode(clear.data),
    'agw+jws',
  );
  exactKeys(signed, {'context', 'payload'});
  if (canonical(signed['context']) != canonical(expected)) {
    throw const GatewayError('invalid_envelope');
  }
  return Map<String, dynamic>.from(signed['payload']);
}
