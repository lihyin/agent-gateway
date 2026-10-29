import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:jose/jose.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';
import 'package:pointycastle/srp/srp6_server.dart';
import 'package:pointycastle/srp/srp6_standard_groups.dart';
import 'package:pointycastle/srp/srp6_util.dart';
import 'package:pointycastle/srp/srp6_verifier_generator.dart';

import '../domain/gateway_error.dart';
import 'crypto.dart';
import 'paired_delivery.dart';

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

String _hex(List<int> bytes) =>
    bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

// dart:io WebSocket.connect follows HTTP redirects. Perform the standard upgrade
// with redirects disabled, then hand framing to the platform WebSocket library.
Future<WebSocket> connectPairingSocket(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final deadline = Timer(
    const Duration(seconds: 15),
    () => client.close(force: true),
  );
  try {
    final request = await client.getUrl(
      uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http'),
    );
    request.followRedirects = false;
    final nonce = base64.encode(_randomBytes(16));
    request.headers
      ..set('Connection', 'Upgrade')
      ..set('Upgrade', 'websocket')
      ..set('Sec-WebSocket-Key', nonce)
      ..set('Sec-WebSocket-Version', '13');
    final response = await request.close();
    final expected = base64.encode(
      crypto.sha1
          .convert(utf8.encode('${nonce}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
          .bytes,
    );
    if (response.statusCode != 101 ||
        response.headers.value('upgrade')?.toLowerCase() != 'websocket' ||
        response.headers.value('sec-websocket-accept') != expected) {
      throw const GatewayError('pairing_unavailable');
    }
    final socket = await response.detachSocket();
    return WebSocket.fromUpgradedSocket(socket, serverSide: false);
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}

// The phone is the SRP server. PIN, verifier and ephemeral secrets never leave it.
class PinExchange {
  PinExchange(this.origin, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now {
    final uri = Uri.parse(origin);
    if (uri.scheme != 'https' ||
        uri.origin != origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !RegExp(
          r'^[a-z0-9.-]+\.[a-z]{2,}$',
          caseSensitive: false,
        ).hasMatch(uri.host)) {
      throw const GatewayError('relay_configuration_required');
    }
    code = Random.secure().nextInt(100000000).toString().padLeft(8, '0');
    session = _hex(_randomBytes(32));
    expiresAt = this.clock().millisecondsSinceEpoch ~/ 1000 + 1800;
    final group = SRP6StandardGroups.rfc5054_2048;
    final salt = _randomBytes(32);
    final verifier = SRP6VerifierGenerator(group: group, digest: SHA256Digest())
        .generateVerifier(
          salt,
          Uint8List.fromList(utf8.encode('agw-pin-v1:$origin:$session')),
          Uint8List.fromList(utf8.encode(code)),
        );
    _server = SRP6Server(
      group: group,
      v: verifier,
      digest: SHA256Digest(),
      random: FortunaRandom()..seed(KeyParameter(_randomBytes(32))),
    );
    challenge = {
      'kind': 'challenge',
      'salt': _hex(salt),
      'B': _server
          .generateServerCredentials()!
          .toRadixString(16)
          .padLeft(512, '0'),
      'expiresAt': expiresAt,
    };
  }
  final String origin;
  final DateTime Function() clock;
  late final String code, session;
  late final int expiresAt;
  late final Map<String, dynamic> challenge;
  late SRP6Server _server;
  Uint8List? _key;
  bool _attempted = false, _closed = false;
  String get setupLine =>
      'AGW1.${base64Url.encode(utf8.encode(jsonEncode({'origin': origin, 'session': session, 'code': code, 'expiresAt': expiresAt}))).replaceAll('=', '')}';
  void check() {
    if (_closed || expiresAt <= clock().millisecondsSinceEpoch ~/ 1000) {
      throw const GatewayError('pairing_expired');
    }
  }

  void authenticate(Map<String, dynamic> proof) {
    check();
    if (_attempted) throw const GatewayError('pairing_failed');
    _attempted = true;
    try {
      exactKeys(proof, {'kind', 'A', 'M1'});
      if (proof['kind'] != 'proof' ||
          proof['A'] is! String ||
          proof['M1'] is! String ||
          !RegExp(r'^[a-f0-9]{512}$').hasMatch(proof['A']) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(proof['M1'])) {
        throw const GatewayError('pairing_failed');
      }
      final a = BigInt.parse(proof['A'], radix: 16);
      if (a <= BigInt.zero || a >= _server.N) {
        throw const GatewayError('pairing_failed');
      }
      _server.calculateSecret(a);
      if (!_server.verifyClientEvidenceMessage(
        BigInt.parse(proof['M1'], radix: 16),
      )) {
        throw const GatewayError('pairing_failed');
      }
      // The encrypted ready record supplies server key confirmation, rather than
      // exchanging library-specific M2 encodings. Both libraries derive K=SHA256(PAD(S)).
      _server.calculateServerEvidenceMessage();
      _key = SRP6Util.getPadded(_server.calculateSessionKey()!, 32);
    } catch (_) {
      close();
      throw const GatewayError('pairing_failed');
    }
  }

  String seal(String kind, [Map<String, dynamic> data = const {}]) {
    check();
    if (_key == null) throw const GatewayError('pairing_failed');
    final builder = JsonWebEncryptionBuilder()
      ..content = jsonEncode({
        'version': 1,
        'origin': origin,
        'session': session,
        'expiresAt': expiresAt,
        'kind': kind,
        ...data,
      })
      ..encryptionAlgorithm = 'A256GCM'
      ..setProtectedHeader('typ', 'agw+pin')
      ..addRecipient(
        JsonWebKey.fromJson({
          'kty': 'oct',
          'k': base64Url.encode(_key!).replaceAll('=', ''),
        }),
        algorithm: 'dir',
      );
    return builder.build().toCompactSerialization();
  }

  Future<Map<String, dynamic>> open(String compact, String kind) async {
    check();
    if (_key == null || compact.length > 8192) {
      throw const GatewayError('pairing_failed');
    }
    final parts = compact.split('.');
    if (parts.length != 5 ||
        parts[1].isNotEmpty ||
        [
          parts[0],
          parts[2],
          parts[3],
          parts[4],
        ].any((p) => !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(p))) {
      throw const GatewayError('pairing_failed');
    }
    final header = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0])))),
    );
    exactKeys(header, {'alg', 'enc', 'typ'});
    if (header['alg'] != 'dir' ||
        header['enc'] != 'A256GCM' ||
        header['typ'] != 'agw+pin') {
      throw const GatewayError('pairing_failed');
    }
    final keys = JsonWebKeyStore()
      ..addKey(
        JsonWebKey.fromJson({
          'kty': 'oct',
          'k': base64Url.encode(_key!).replaceAll('=', ''),
        }),
      );
    final payload = await JsonWebEncryption.fromCompactSerialization(compact)
        .getPayload(keys);
    final value = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(payload.data)),
    );
    exactKeys(value, {
      'version',
      'origin',
      'session',
      'expiresAt',
      'kind',
      if (kind == 'offer') 'offer',
      if (kind == 'receipt') ...['receipt', 'fingerprint'],
    });
    check();
    if (value['version'] != 1 ||
        value['origin'] != origin ||
        value['session'] != session ||
        value['expiresAt'] != expiresAt ||
        value['kind'] != kind) {
      throw const GatewayError('pairing_failed');
    }
    return value;
  }

  void close() {
    _closed = true;
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
  }
}

class PinPairing {
  PinPairing(
    this.exchange,
    this.delivery, {
    required this.changed,
    required this.confirm,
  });
  final PinExchange exchange;
  final PairedDelivery delivery;
  final void Function() changed;
  final Future<bool> Function() confirm;
  WebSocket? _socket;
  Timer? _timer;
  String status = 'connecting';
  String? error;
  bool _closed = false;
  Future<void> _tail = Future.value();
  int _received = 0;
  String? _savedEpoch;
  Future<void> start() async {
    try {
      final connection = connectPairingSocket(
        Uri.parse(
          '${exchange.origin.replaceFirst('https:', 'wss:')}/v1/pairing/${exchange.session}/device',
        ),
      );
      connection.then((socket) {
        if (_closed) socket.close();
      }, onError: (Object _) {});
      _socket = await connection.timeout(const Duration(seconds: 15));
      if (_closed) {
        await _socket!.close();
        return;
      }
      status = 'waiting';
      _timer = Timer(
        Duration(
          milliseconds: max(
            0,
            exchange.expiresAt * 1000 - DateTime.now().millisecondsSinceEpoch,
          ),
        ),
        () => _fail('pairing_expired'),
      );
      _socket!.listen(
        (data) {
          if (_closed) return;
          if (++_received > 4 ||
              data is! String ||
              utf8.encode(data).length > 8192) {
            _fail('pairing_failed');
            return;
          }
          _tail = _tail
              .then((_) => _message(data))
              .catchError((Object _) => _fail('pairing_failed'));
        },
        onDone: () {
          if (!_closed) _fail('pairing_interrupted');
        },
        onError: (Object _) => _fail('pairing_unavailable'),
      );
      changed();
    } catch (_) {
      _fail('pairing_unavailable');
    }
  }

  Future<void> _message(dynamic data) async {
    if (_closed) return;
    exchange.check();
    if (data is! String || utf8.encode(data).length > 8192) {
      throw const GatewayError('pairing_failed');
    }
    final frame = Map<String, dynamic>.from(jsonDecode(data));
    if (status == 'waiting' && frame.length == 1 && frame['kind'] == 'joined') {
      status = 'authenticating';
      _socket!.add(jsonEncode(exchange.challenge));
    } else if (status == 'authenticating') {
      exchange.authenticate(frame);
      status = 'offer';
      _socket!.add(jsonEncode({'jwe': exchange.seal('ready')}));
    } else if (status == 'offer') {
      exactKeys(frame, {'jwe'});
      final offer = await exchange.open(frame['jwe'] as String, 'offer');
      status = 'confirming';
      changed();
      if (!await confirm()) {
        _fail('pairing_cancelled');
        return;
      }
      if (_closed) return;
      exchange.check();
      // The offer is authenticated by the PAKE channel; existing signed pairing
      // validation and local biometric confirmation remain authoritative.
      final compact = offer['offer'] as String;
      protectedHeader(compact, 3);
      final payload = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(compact.split('.')[1])),
        ),
      );
      final receipt = await delivery.pair(
        compact,
        hash(payload['identity']),
        confirmationReason: 'Pair with Muse using the verified one-time code',
        pendingConfirmation: true,
        stillAuthorized: () =>
            !_closed &&
            exchange.expiresAt > DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      _savedEpoch = delivery.epoch(delivery.agentId!);
      if (_closed) return;
      exchange.check();
      status = 'finishing';
      _socket!.add(
        jsonEncode({
          'jwe': exchange.seal('receipt', {
            'receipt': receipt,
            'fingerprint': delivery.deviceFingerprint,
          }),
        }),
      );
      // Self-registration: present the pair record to the relay's
      // PairingRegistry with a device-signed proof, so the relay stores
      // the record without per-user operator setup. This is best-effort:
      // enabling notifications also registers the signed record over HTTPS
      // to recover a lost final frame without repeating pairing.
      try {
        _socket!.add(
          jsonEncode(await delivery.pairRegistration(exchange.origin)),
        );
      } catch (_) {
        // Notification setup retries registration over HTTPS.
      }
    } else if (status == 'finishing') {
      exactKeys(frame, {'jwe'});
      await exchange.open(frame['jwe'] as String, 'complete');
      if (_closed) return;
      exchange.check();
      await delivery.confirmPairing(_savedEpoch!);
      if (_closed) return;
      status = 'paired';
      close();
    } else {
      throw const GatewayError('pairing_failed');
    }
    changed();
  }

  void _fail(String code) {
    if (_closed) return;
    error = code;
    status = 'failed';
    close();
    changed();
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    exchange.close();
    _socket?.close();
  }
}
