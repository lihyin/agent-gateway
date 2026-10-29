import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../approvals/local_confirmation.dart';
import '../approvals/review_service.dart';
import '../domain/gateway_error.dart';
import '../domain/gmail_request.dart';
import '../vault/vault.dart';
import 'crypto.dart';

class PairedDelivery {
  PairedDelivery({
    required this.vault,
    required this.confirmation,
    DateTime Function()? clock,
    Future<Map<String, dynamic>> Function()? keyGenerator,
  }) : clock = clock ?? DateTime.now,
       keyGenerator = keyGenerator ?? (() => compute(generateIdentity, 0));
  final Vault vault;
  final LocalConfirmation confirmation;
  final DateTime Function() clock;
  final Future<Map<String, dynamic>> Function() keyGenerator;
  final _serial = SerialExecutor();
  Map<String, dynamic>? _identity, _pair;
  Map<String, dynamic>? _relay;
  Map<String, dynamic> _replay = {};
  bool _ready = false;
  String? epoch(String id) =>
      _ready && (_pair?['agentId']) == id ? (_pair?['epoch'] as String?) : null;
  String? get agentId => _ready ? (_pair?['agentId'] as String?) : null;
  bool get pairingConfirmed => agentId != null && _pair?['confirmed'] != false;
  String? get agentFingerprint =>
      _ready && _pair != null ? hash(_pair!['identity']) : null;
  String? get deviceFingerprint =>
      _ready ? hash(publicIdentity(_identity!)) : null;
  bool relayEnabled(String origin) =>
      _ready &&
      _pair != null &&
      _relay?['epoch'] == _pair?['epoch'] &&
      _relay?['origin'] == origin;
  Future<void> initialize() => _serial.run(() async {
    _ready = false;
    _identity = await vault.read('transport.identity');
    if (_identity == null) {
      _identity = await keyGenerator();
      await vault.write('transport.identity', _identity!);
    }
    validatePublicIdentity(publicIdentity(_identity!));
    _pair = await vault.read('transport.pair');
    if (_pair != null) {
      validatePublicIdentity(Map<String, dynamic>.from(_pair!['identity']));
      if (_pair!['agentId'] !=
          identityId(Map<String, dynamic>.from(_pair!['identity']))) {
        throw const GatewayError('invalid_pairing');
      }
    }
    _replay = await vault.read('transport.replay') ?? {};
    _relay = await vault.read('transport.relay');
    final expired = _replay.keys
        .where(
          (id) =>
              clock().millisecondsSinceEpoch ~/ 1000 >
              (_replay[id]['context']['expiresAt'] as int) + 86400,
        )
        .toList();
    for (final id in expired) {
      await vault.delete('transport.result.$id');
      _replay.remove(id);
    }
    await vault.write('transport.replay', _replay);
    _ready = true;
  });
  void _check() {
    if (!_ready) throw const GatewayError('vault_unavailable');
  }

  Future<void> _save(String key, Map<String, dynamic> value) async {
    try {
      await vault.write(key, value);
    } catch (_) {
      _ready = false;
      rethrow;
    }
  }

  Future<String> pair(
    String offer,
    String expectedFingerprint, {
    bool Function()? stillAuthorized,
    String? confirmationReason,
    bool pendingConfirmation = false,
  }) => _serial.run(() async {
    _check();
    if (_pair != null || offer.length > 5000) {
      throw const GatewayError('invalid_pairing');
    }
    try {
      final parts = offer.split('.');
      protectedHeader(offer, 3);
      final candidate = Map<String, dynamic>.from(
        jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        ),
      );
      exactKeys(candidate, {
        'version',
        'kind',
        'nonce',
        'identity',
        'issuedAt',
        'expiresAt',
      });
      final public = Map<String, dynamic>.from(candidate['identity']);
      validatePublicIdentity(public);
      final verified = await verifyObject(
        Map<String, dynamic>.from(public['signing']),
        offer,
        'agw+pairing',
      );
      final now = clock().millisecondsSinceEpoch ~/ 1000;
      if (canonical(verified) != canonical(candidate) ||
          candidate['version'] != 1 ||
          candidate['kind'] != 'offer' ||
          candidate['nonce'] is! String ||
          !RegExp(r'^[0-9a-f-]{36}$').hasMatch(candidate['nonce']) ||
          candidate['issuedAt'] is! int ||
          candidate['expiresAt'] is! int ||
          candidate['issuedAt'] > now ||
          candidate['expiresAt'] <= now ||
          candidate['expiresAt'] <= candidate['issuedAt'] ||
          candidate['expiresAt'] - candidate['issuedAt'] > 300 ||
          hash(public) != expectedFingerprint.trim().toLowerCase()) {
        throw const GatewayError('invalid_pairing');
      }
      if (!await confirmation.confirm(
        confirmationReason ?? 'Pair with agent fingerprint ${hash(public)}',
      )) {
        throw const GatewayError('local_confirmation_required');
      }
      if (candidate['expiresAt'] <= clock().millisecondsSinceEpoch ~/ 1000 ||
          (stillAuthorized != null && !stillAuthorized())) {
        throw const GatewayError('invalid_pairing');
      }
      final epoch = uuid();
      final receipt = signObject(_identity!, {
        'version': 1,
        'kind': 'accept',
        'nonce': candidate['nonce'],
        'offerDigest': hash(offer),
        'agentId': identityId(public),
        'identity': publicIdentity(_identity!),
        'epoch': epoch,
        'issuedAt': clock().millisecondsSinceEpoch ~/ 1000,
        'expiresAt': candidate['expiresAt'],
      }, 'agw+pairing');
      final pair = {
        'agentId': identityId(public),
        'identity': public,
        'epoch': epoch,
        if (pendingConfirmation) 'confirmed': false,
      };
      await _save('transport.pair', pair);
      _pair = pair;
      return receipt;
    } on GatewayError {
      rethrow;
    } catch (_) {
      throw const GatewayError('invalid_pairing');
    }
  });
  Future<void> confirmPairing(String epoch) => _serial.run(() async {
    _check();
    if (_pair == null || _pair!['epoch'] != epoch) {
      throw const GatewayError('invalid_pairing');
    }
    final confirmed = {..._pair!, 'confirmed': true};
    await _save('transport.pair', confirmed);
    _pair = confirmed;
  });

  Future<void> unpair() => _serial.run(() async {
    _check();
    _pair = null; // Local revocation precedes storage I/O, including failure.
    _relay = null;
    try {
      await vault.delete('transport.relay');
      await vault.delete('transport.pair');
    } catch (_) {
      _ready = false;
      rethrow;
    }
  });
  Future<void> enableRelay(String origin, bool enabled) =>
      _serial.run(() async {
        _check();
        if (!enabled) {
          _relay = null;
          await vault.delete('transport.relay');
          return;
        }
        if (!pairingConfirmed) throw const GatewayError('unpaired');
        if (!await confirmation.confirm(
          'Enable encrypted relay delivery to the paired agent? Allowed results will be sent automatically while this app is open.',
        )) {
          throw const GatewayError('local_confirmation_required');
        }
        final value = {'epoch': _pair!['epoch'], 'origin': origin};
        await _save('transport.relay', value);
        _relay = value;
      });
  // Self-registration frame for the relay's PairingRegistry: the pair
  // record (public transport configuration) plus a device-signed proof
  // (typ agw+pair-register) binding the record's IDs and epoch to this
  // device. Sent on the pairing socket right after the pairing receipt
  // (see PinPairing), so the relay stores the record at pairing time and
  // no per-user PAIRING_CONFIG step is needed on the relay.
  Future<Map<String, dynamic>> pairRegistration(String origin) =>
      _serial.run(() async {
        _check();
        if (_pair == null) throw const GatewayError('unpaired');
        final now = clock().millisecondsSinceEpoch ~/ 1000;
        final record = {
          'deviceSigningKey': Map<String, dynamic>.from(
            publicIdentity(_identity!)['signing'],
          ),
          'agentSigningKey': Map<String, dynamic>.from(
            _pair!['identity']['signing'],
          ),
          'deviceId': identityId(_identity!),
          'agentId': _pair!['agentId'],
          'pairingEpoch': _pair!['epoch'],
        };
        return {
          'kind': 'pairing_record',
          'record': record,
          'proof': signObject(_identity!, {
            'version': 1,
            'audience': origin,
            'deviceId': record['deviceId'],
            'agentId': record['agentId'],
            'pairingEpoch': record['pairingEpoch'],
            'issuedAt': now,
            'expiresAt': now + 30,
          }, 'agw+pair-register'),
        };
      });
  Future<int> _nextRoutingUpdate() async {
    final time = clock().millisecondsSinceEpoch;
    final previous =
        (await vault.read('transport.routing-clock'))?['updatedAt'] as int? ??
        0;
    final next = time > previous ? time : previous + 1;
    await _save('transport.routing-clock', {'updatedAt': next});
    return next;
  }

  Future<String> registrationProof(String origin, String pushToken) =>
      _serial.run(() async {
        _check();
        if (!relayEnabled(origin)) throw const GatewayError('unpaired');
        final now = clock().millisecondsSinceEpoch ~/ 1000;
        return signObject(_identity!, {
          'version': 1,
          'audience': origin,
          'deviceId': identityId(_identity!),
          'agentId': _pair!['agentId'],
          'pairingEpoch': _pair!['epoch'],
          'issuedAt': now,
          'expiresAt': now + 30,
          'pushToken': pushToken,
          'updatedAt': await _nextRoutingUpdate(),
        }, 'agw+register');
      });
  Future<String> controlProof(String origin, String type) =>
      _serial.run(() async {
        _check();
        if (_pair == null) throw const GatewayError('unpaired');
        final now = clock().millisecondsSinceEpoch ~/ 1000;
        return signObject(_identity!, {
          'version': 1,
          'audience': origin,
          'deviceId': identityId(_identity!),
          'agentId': _pair!['agentId'],
          'pairingEpoch': _pair!['epoch'],
          'issuedAt': now,
          'expiresAt': now + 30,
          'updatedAt': await _nextRoutingUpdate(),
        }, type);
      });
  Future<String> resultProof(String origin, Map<String, dynamic> envelope) =>
      _serial.run(() async {
        _check();
        if (!relayEnabled(origin) ||
            envelope['context']['pairingEpoch'] != _pair!['epoch']) {
          throw const GatewayError('unpaired');
        }
        final now = clock().millisecondsSinceEpoch ~/ 1000;
        return signObject(_identity!, {
          'version': 1,
          'audience': origin,
          'issuedAt': now,
          'expiresAt': now + 30,
          'envelope': envelope,
        }, 'agw+result');
      });
  Future<void> importRequest(String encoded, ReviewService review) =>
      _serial.run(() async {
        _check();
        if (_pair == null || utf8.encode(encoded).length > 3500) {
          throw const GatewayError('invalid_envelope');
        }
        try {
          final envelope = Map<String, dynamic>.from(jsonDecode(encoded));
          final context = Map<String, dynamic>.from(envelope['context']);
          validateContext(context, clock());
          if (context['direction'] != 'request' ||
              context['sender'] != _pair!['agentId'] ||
              context['recipient'] != identityId(_identity!) ||
              context['pairingEpoch'] != _pair!['epoch']) {
            throw const GatewayError('unpaired');
          }
          final payload = await decryptEnvelope(
            _identity!,
            Map<String, dynamic>.from(_pair!['identity']),
            envelope,
            context,
            clock(),
          );
          exactKeys(payload, {
            'source',
            'operation',
            'query',
            'purpose',
            'fields',
            'since',
            'until',
            'maxResults',
          });
          if (utf8.encode(jsonEncode(payload)).length > 1200 ||
              payload['source'] != 'gmail' ||
              payload['operation'] != 'search' ||
              payload['since'] is! int ||
              payload['until'] is! int ||
              payload['maxResults'] is! int ||
              payload['fields'] is! List ||
              payload['fields'].length != payload['fields'].toSet().length) {
            throw const GatewayError('invalid_envelope');
          }
          final request = GmailRequest(
            id: context['requestId'],
            agentId: context['sender'],
            pairingEpoch: context['pairingEpoch'],
            query: payload['query'],
            purpose: payload['purpose'],
            fields: Set<String>.from(payload['fields']),
            since: DateTime.fromMillisecondsSinceEpoch(
              payload['since'] * 1000,
              isUtc: true,
            ),
            until: DateTime.fromMillisecondsSinceEpoch(
              payload['until'] * 1000,
              isUtc: true,
            ),
            maxResults: payload['maxResults'],
            issuedAt: DateTime.fromMillisecondsSinceEpoch(
              context['issuedAt'] * 1000,
              isUtc: true,
            ),
            expiresAt: DateTime.fromMillisecondsSinceEpoch(
              context['expiresAt'] * 1000,
              isUtc: true,
            ),
          );
          request.validate(clock());
          final id = request.id;
          final existing = _replay[id];
          if (existing != null && existing['digest'] != hash(envelope)) {
            throw const GatewayError('replay_changed_content');
          }
          if (existing != null &&
              !(await review.entries()).any((e) => e.request.id == id)) {
            throw const GatewayError('replay_changed_content');
          }
          if (existing == null) {
            if (_replay.length >= 20) {
              throw const GatewayError('review_capacity');
            }
            _replay[id] = {'digest': hash(envelope), 'context': context};
            await _save('transport.replay', _replay);
          }
          await review.begin(
            request,
          ); // Reservation is durable before any connector execution.
        } on GatewayError {
          rethrow;
        } catch (_) {
          throw const GatewayError('invalid_envelope');
        }
      });
  Future<String> exportResult(ReviewEntry visible, ReviewService review) =>
      _serial.run(() async {
        _check();
        final entry = await review.forRelease(
          visible.request.id,
          visible.revision,
          visible.candidateDigest,
        );
        if (_pair == null ||
            entry.request.agentId != _pair!['agentId'] ||
            entry.request.pairingEpoch != _pair!['epoch']) {
          throw const GatewayError('unpaired');
        }
        final record = _replay[entry.request.id];
        if (record == null) throw const GatewayError('invalid_envelope');
        final saved = await vault.read('transport.result.${entry.request.id}');
        if (saved != null) return jsonEncode(saved);
        final requestContext = Map<String, dynamic>.from(record['context']);
        final context = {
          ...requestContext,
          'direction': 'result',
          'sender': requestContext['recipient'],
          'recipient': requestContext['sender'],
        };
        final payload = {
          'status': entry.state == ReviewState.allowed ? 'allowed' : 'denied',
          'messages': entry.state == ReviewState.allowed ? entry.candidate : [],
        };
        if (utf8.encode(jsonEncode(payload)).length > 50000) {
          throw const GatewayError('invalid_envelope');
        }
        final envelope = encryptEnvelope(
          _identity!,
          Map<String, dynamic>.from(_pair!['identity']),
          context,
          payload,
        );
        await review.forRelease(
          entry.request.id,
          entry.revision,
          entry.candidateDigest,
        );
        await _save('transport.result.${entry.request.id}', envelope);
        return jsonEncode(envelope);
      });
}
