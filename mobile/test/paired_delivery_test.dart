import 'dart:convert';
import 'dart:io';

import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/transport/crypto.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('real device key generation produces working separate signing and encryption keys', () async {
    final identity = generateIdentity(0);
    validatePublicIdentity(publicIdentity(identity));
    final signed = signObject(identity, {'proof': 'ownership'}, 'agw+pairing');
    expect(
      await verifyObject(
        Map<String, dynamic>.from(publicIdentity(identity)['signing']),
        signed,
        'agw+pairing',
      ),
      {'proof': 'ownership'},
    );
  });
  final f = jsonDecode(
    File('../protocol/fixtures/pairing.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final agent = Map<String, dynamic>.from(f['agent']),
      device = Map<String, dynamic>.from(f['device']);
  late DateTime now;
  late MemoryVault vault;
  late FakeConfirmation confirmation;
  late PairedDelivery delivery;
  late ReviewService review;
  late FakeSource source;
  PairedDelivery create() => PairedDelivery(
    vault: vault,
    confirmation: confirmation,
    clock: () => now,
    keyGenerator: () async => device,
  );
  setUp(() async {
    now = DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true);
    vault = MemoryVault();
    confirmation = FakeConfirmation();
    delivery = create();
    await delivery.initialize();
    source = FakeSource(
      () =>
          now.add(const Duration(days: 1)).subtract(const Duration(seconds: 1)),
    );
    review = ReviewService(
      vault: vault,
      source: source,
      confirmation: confirmation,
      currentEpoch: delivery.epoch,
      clock: () => now,
    );
    await review.initialize();
  });
  Future<String> pair() => delivery.pair(f['offer'], f['fingerprint']);
  Map<String, dynamic> request({
    String? id,
    Map<String, dynamic>? payload,
    Map<String, dynamic>? changes,
  }) {
    final context = {
      ...Map<String, dynamic>.from(f['context']),
      'requestId': id ?? uuid(),
      'pairingEpoch': delivery.epoch(identityId(agent)),
      ...?changes,
    };
    return encryptEnvelope(
      agent,
      publicIdentity(device),
      context,
      payload ?? Map<String, dynamic>.from(f['payload']),
    );
  }

  Future<ReviewEntry> approve(Map<String, dynamic> envelope) async {
    await delivery.importRequest(jsonEncode(envelope), review);
    final e = (await review.entries()).last;
    final preview = await review.approveAccess(e.request.id, e.revision);
    return review.decide(
      preview.request.id,
      preview.revision,
      preview.candidateDigest,
      ReviewAction.allow,
    );
  }

  test(
    'Node request decrypts in Dart with exact context and algorithms',
    () async {
      expect(
        await decryptEnvelope(
          device,
          publicIdentity(agent),
          Map<String, dynamic>.from(f['envelope']),
          Map<String, dynamic>.from(f['context']),
          now,
        ),
        f['payload'],
      );
    },
  );
  test(
    'pairing requires matching fingerprint and device authentication',
    () async {
      await expectLater(delivery.pair(f['offer'], '0' * 64), throwsA(anything));
      expect(confirmation.count, 0);
      confirmation.allowed = false;
      await expectLater(pair(), throwsA(anything));
      expect(delivery.agentId, isNull);
      confirmation.allowed = true;
      await pair();
      expect(delivery.agentId, identityId(agent));
      expect(delivery.agentFingerprint, f['fingerprint']);
      await expectLater(pair(), throwsA(anything));
    },
  );
  test('expired offers and substituted encryption keys fail', () async {
    now = now.add(const Duration(seconds: 300));
    await expectLater(pair(), throwsA(anything));
    now = now.subtract(const Duration(seconds: 300));
    final altered = {
      'version': 1,
      'kind': 'offer',
      'nonce': uuid(),
      'identity': publicIdentity(device),
      'issuedAt': 100,
      'expiresAt': 400,
    };
    await expectLater(
      delivery.pair(
        signObject(agent, altered, 'agw+pairing'),
        hash(publicIdentity(device)),
      ),
      throwsA(anything),
    );
  });
  test('pending review cannot export; allowed filtered result is encrypted and retry-stable', () async {
    final receipt = await pair();
    final envelope = request();
    await delivery.importRequest(jsonEncode(envelope), review);
    var e = (await review.entries()).single;
    await expectLater(delivery.exportResult(e, review), throwsA(anything));
    expect(source.fetches, 0);
    final preview = await review.approveAccess(e.request.id, e.revision);
    e = await review.decide(
      preview.request.id,
      preview.revision,
      preview.candidateDigest,
      ReviewAction.allow,
    );
    final result = await delivery.exportResult(e, review);
    expect(result, isNot(contains('Invoice')));
    expect(await delivery.exportResult(e, review), result);
    final c = Map<String, dynamic>.from(envelope['context']);
    final expected = {
      ...c,
      'direction': 'result',
      'sender': c['recipient'],
      'recipient': c['sender'],
    };
    final payload = await decryptEnvelope(
      agent,
      publicIdentity(device),
      Map<String, dynamic>.from(jsonDecode(result)),
      expected,
      now,
    );
    expect(payload['status'], 'allowed');
    expect(payload['messages'][0]['subject'], 'Invoice for [redacted]');
    File('.dart_tool/pairing-interop.json').writeAsStringSync(
      jsonEncode({
        'receipt': receipt,
        'request': envelope,
        'result': jsonDecode(result),
        'deviceFingerprint': delivery.deviceFingerprint,
      }),
    );
  });
  test('wrong agent, recipient, epoch, direction and tampered ciphertext never fetch', () async {
    await pair();
    for (final changes in [
      {'sender': identityId(device)},
      {'recipient': identityId(agent)},
      {'pairingEpoch': uuid()},
    ]) {
      await expectLater(
        delivery.importRequest(jsonEncode(request(changes: changes)), review),
        throwsA(anything),
      );
    }
    final envelope = request();
    envelope['jwe'] =
        '${envelope['jwe'].substring(0, envelope['jwe'].length - 5)}AAAAA';
    await expectLater(
      delivery.importRequest(jsonEncode(envelope), review),
      throwsA(anything),
    );
    expect(source.fetches, 0);
  });
  test('restart deduplicates requests and preserves pairing; changed same-ID ciphertext fails', () async {
    await pair();
    final envelope = request();
    final e = await approve(envelope);
    final result = await delivery.exportResult(e, review);
    delivery = create();
    await delivery.initialize();
    await review.initialize();
    await delivery.importRequest(jsonEncode(envelope), review);
    expect(source.fetches, 1);
    expect(
      await delivery.exportResult((await review.entries()).single, review),
      result,
    );
    await expectLater(
      delivery.importRequest(jsonEncode(request(id: e.request.id)), review),
      throwsA(anything),
    );
  });
  test('disconnect cleanup does not reopen old request IDs', () async {
    await pair();
    final envelope = request();
    await approve(envelope);
    await review.cancelAll();
    await expectLater(
      delivery.importRequest(jsonEncode(envelope), review),
      throwsA(anything),
    );
    expect(source.fetches, 1);
  });
  test(
    'denial emits no source data; expiry and unpairing block release',
    () async {
      await pair();
      final envelope = request();
      await delivery.importRequest(jsonEncode(envelope), review);
      var e = (await review.entries()).single;
      e = await review.denyAccess(e.request.id, e.revision);
      final result = jsonDecode(
        await delivery.exportResult(e, review),
      ) as Map<String, dynamic>;
      final c = Map<String, dynamic>.from(envelope['context']);
      expect(
        await decryptEnvelope(agent, publicIdentity(device), result, {
          ...c,
          'direction': 'result',
          'sender': c['recipient'],
          'recipient': c['sender'],
        }, now),
        {'status': 'denied', 'messages': []},
      );
      expect(source.fetches, 0);
      now = now.add(const Duration(seconds: 300));
      await expectLater(delivery.exportResult(e, review), throwsA(anything));
      now = now.subtract(const Duration(seconds: 300));
      await delivery.unpair();
      await expectLater(delivery.exportResult(e, review), throwsA(anything));
      await expectLater(
        delivery.importRequest(jsonEncode(envelope), review),
        throwsA(anything),
      );
    },
  );
  test('reservation write failure stops request admission', () async {
    await pair();
    final envelope = request();
    vault.fail = true;
    await expectLater(
      delivery.importRequest(jsonEncode(envelope), review),
      throwsA(anything),
    );
    vault.fail = false;
    await expectLater(
      delivery.importRequest(jsonEncode(envelope), review),
      throwsA(anything),
    );
    expect(source.fetches, 0);
  });
  test('rejects extra fields, unsupported scopes, oversize and changed protected headers', () async {
    await pair();
    for (final p in [
      {...Map<String, dynamic>.from(f['payload']), 'token': 'secret'},
      {
        ...Map<String, dynamic>.from(f['payload']),
        'fields': ['body'],
      },
      {
        ...Map<String, dynamic>.from(f['payload']),
        'fields': ['id', 'id'],
      },
      {...Map<String, dynamic>.from(f['payload']), 'operation': 'get'},
    ]) {
      await expectLater(
        delivery.importRequest(jsonEncode(request(payload: p)), review),
        throwsA(anything),
      );
    }
    await expectLater(
      delivery.importRequest('x' * 3501, review),
      throwsA(anything),
    );
    final envelope = request();
    envelope['extra'] = true;
    await expectLater(
      delivery.importRequest(jsonEncode(envelope), review),
      throwsA(anything),
    );
    expect(source.fetches, 0);
  });
}
