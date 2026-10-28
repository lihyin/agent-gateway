import 'dart:convert';
import 'dart:io';

import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/transport/crypto.dart';
import 'package:agentgateway/transport/foreground_relay.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
import 'package:agentgateway/transport/push_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

void main() {
  final f = jsonDecode(
    File('../protocol/fixtures/pairing.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final agent = Map<String, dynamic>.from(f['agent']);
  final device = Map<String, dynamic>.from(f['device']);
  const origin = 'https://relay.example.com';
  late DateTime now;
  late MemoryVault vault;
  late FakeConfirmation confirmation;
  late PairedDelivery delivery;
  late ReviewService review;
  late FakeSource source;
  setUp(() async {
    now = DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true);
    vault = MemoryVault();
    confirmation = FakeConfirmation();
    delivery = PairedDelivery(
      vault: vault,
      confirmation: confirmation,
      clock: () => now,
      keyGenerator: () async => device,
    );
    await delivery.initialize();
    await delivery.pair(f['offer'], f['fingerprint']);
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

  test('push imports ciphertext without Gmail access and returns only an approved encrypted outcome', () async {
    final context = {
      ...Map<String, dynamic>.from(f['context']),
      'requestId': uuid(),
      'pairingEpoch': delivery.epoch(identityId(agent)),
    };
    final envelope = encryptEnvelope(
      agent,
      publicIdentity(device),
      context,
      Map<String, dynamic>.from(f['payload']),
    );
    final notifications = FakePush()..queue.add(jsonEncode(envelope));
    var calls = 0;
    final relay = ForegroundRelay(
      origin,
      clock: () => now,
      notifications: notifications,
      client: MockClient((request) async {
        if (request.url.path == '/v1/pairings/register') {
          expect(request.headers['content-type'], 'application/json');
          final frame = jsonDecode(request.body) as Map<String, dynamic>;
          final proof = await verifyObject(
            Map<String, dynamic>.from(publicIdentity(device)['signing']),
            frame['proof'] as String,
            'agw+pair-register',
          );
          expect(proof['deviceId'], identityId(device));
          expect(frame['record']['deviceId'], identityId(device));
          return http.Response(jsonEncode({'status': 'registered'}), 200);
        }
        calls++;
        expect(request.followRedirects, false);
        expect(request.url.path, '/v1/results');
        final proof = await verifyObject(
          Map<String, dynamic>.from(publicIdentity(device)['signing']),
          request.body,
          'agw+result',
        );
        expect(proof['audience'], origin);
        File('.dart_tool/direct-result.json').writeAsStringSync(
          jsonEncode({
            'proof': request.body,
            'epoch': delivery.epoch(identityId(agent)),
          }),
        );
        final result = Map<String, dynamic>.from(proof['envelope']);
        expect(result.keys.toSet(), {'context', 'jwe'});
        final payload = await decryptEnvelope(
          agent,
          publicIdentity(device),
          result,
          {
            ...context,
            'direction': 'result',
            'sender': context['recipient'],
            'recipient': context['sender'],
          },
          now,
        );
        expect(payload['status'], 'allowed');
        expect(jsonEncode(payload), isNot(contains('person@example.com')));
        return http.Response(jsonEncode({'status': 'handed_off'}), 202);
      }),
    );
    addTearDown(relay.close);
    await relay.sync(delivery, review);
    expect(notifications.queue, hasLength(1));
    await delivery.enableRelay(origin, true);
    await relay.sync(delivery, review);
    expect(notifications.queue, isEmpty);
    expect(source.fetches, 0);
    expect(calls, 0);
    final entry = (await review.entries()).single;
    final preview = await review.approveAccess(
      entry.request.id,
      entry.revision,
    );
    await review.decide(
      preview.request.id,
      preview.revision,
      preview.candidateDigest,
      ReviewAction.allow,
    );
    await relay.sync(delivery, review);
    await relay.sync(delivery, review);
    expect(source.fetches, 1);
    expect(calls, 1);
  });
  test('registration uses device proof, survives restart, and is revoked by unpairing', () async {
    await delivery.enableRelay(origin, true);
    final relay = ForegroundRelay(
      origin,
      clock: () => now,
      notifications: FakePush(),
      client: MockClient((request) async {
        if (request.url.path == '/v1/pairings/register') {
          expect(request.headers['content-type'], 'application/json');
          final frame = jsonDecode(request.body) as Map<String, dynamic>;
          final proof = await verifyObject(
            Map<String, dynamic>.from(publicIdentity(device)['signing']),
            frame['proof'] as String,
            'agw+pair-register',
          );
          expect(proof['deviceId'], identityId(device));
          expect(frame['record']['deviceId'], identityId(device));
          return http.Response(jsonEncode({'status': 'registered'}), 200);
        }
        expect(request.url.path, '/v1/routes');
        final proof = await verifyObject(
          Map<String, dynamic>.from(publicIdentity(device)['signing']),
          request.body,
          'agw+register',
        );
        expect(proof['deviceId'], identityId(device));
        expect(proof['pushToken'], 'a' * 64);
        expect(proof['expiresAt'] - proof['issuedAt'], 30);
        File('.dart_tool/direct-register.json').writeAsStringSync(
          jsonEncode({
            'proof': request.body,
            'epoch': delivery.epoch(identityId(agent)),
          }),
        );
        return http.Response(jsonEncode({'status': 'registered'}), 200);
      }),
    );
    addTearDown(relay.close);
    await relay.register(delivery);
    await delivery.initialize();
    expect(delivery.relayEnabled(origin), isTrue);
    now = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
    expect(delivery.relayEnabled(origin), isTrue);
    await delivery.unpair();
    expect(delivery.relayEnabled(origin), isFalse);
    await expectLater(
      delivery.registrationProof(origin, 'a' * 64),
      throwsA(anything),
    );
  });
  test('registration refreshes automatically without exporting a route; control updates are signed and monotonic', () async {
    await delivery.enableRelay(origin, true);
    final updates = <int>[];
    final paths = <String>[];
    final relay = ForegroundRelay(
      origin,
      clock: () => now,
      notifications: FakePush(),
      client: MockClient((request) async {
        if (request.url.path == '/v1/pairings/register') {
          expect(request.headers['content-type'], 'application/json');
          final frame = jsonDecode(request.body) as Map<String, dynamic>;
          final proof = await verifyObject(
            Map<String, dynamic>.from(publicIdentity(device)['signing']),
            frame['proof'] as String,
            'agw+pair-register',
          );
          expect(proof['deviceId'], identityId(device));
          expect(frame['record']['deviceId'], identityId(device));
          return http.Response(jsonEncode({'status': 'registered'}), 200);
        }
        paths.add(request.url.path);
        final type = switch (request.url.path) {
          '/v1/routes/disable' => 'agw+route-disable',
          '/v1/pairings/revoke' => 'agw+unpair',
          _ => 'agw+register',
        };
        final proof = await verifyObject(
          Map<String, dynamic>.from(publicIdentity(device)['signing']),
          request.body,
          type,
        );
        expect(proof['deviceId'], identityId(device));
        expect(proof['agentId'], identityId(agent));
        expect(proof['pairingEpoch'], delivery.epoch(identityId(agent)));
        expect(proof.containsKey('route'), isFalse);
        updates.add(proof['updatedAt'] as int);
        return http.Response(
          jsonEncode({
            'status': type == 'agw+register' ? 'registered' : 'revoked',
          }),
          200,
        );
      }),
    );
    addTearDown(relay.close);
    await relay.refreshRegistration(delivery);
    await relay.refreshRegistration(delivery);
    expect(paths, ['/v1/routes']);
    now = now.add(const Duration(days: 2));
    await relay.refreshRegistration(delivery);
    relay.invalidateRegistration(); // Resume or native APNs token-change event.
    await relay.refreshRegistration(delivery);
    await relay.disable(delivery);
    await delivery.initialize(); // High-water mark survives process restart.
    await relay.revoke(delivery);
    expect(paths, [
      '/v1/routes',
      '/v1/routes',
      '/v1/routes',
      '/v1/routes/disable',
      '/v1/pairings/revoke',
    ]);
    for (var index = 1; index < updates.length; index++) {
      expect(updates[index], greaterThan(updates[index - 1]));
    }
    expect(source.fetches, 0);
  });
  test('denied local confirmation, invalid push and provider failures grant no Gmail access', () async {
    confirmation.allowed = false;
    await expectLater(delivery.enableRelay(origin, true), throwsA(anything));
    confirmation.allowed = true;
    await delivery.enableRelay(origin, true);
    final notifications = FakePush()..queue.add(jsonEncode({'messages': []}));
    final relay = ForegroundRelay(
      origin,
      clock: () => now,
      notifications: notifications,
      client: MockClient((_) async => http.Response('failure', 503)),
    );
    addTearDown(relay.close);
    await expectLater(relay.sync(delivery, review), throwsA(anything));
    expect(notifications.queue, isEmpty);
    await expectLater(relay.register(delivery), throwsA(anything));
    expect(source.fetches, 0);
    expect(await review.entries(), isEmpty);
  });
}

class FakePush implements PushNotifications {
  final List<String> queue = [];
  @override
  Future<String> register() async => 'a' * 64;
  @override
  Future<List<String>> pending() async => List.of(queue);
  @override
  Future<void> acknowledge(String envelope) async {
    queue.remove(envelope);
  }
}
