import 'dart:convert';
import 'dart:io';

import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/transport/crypto.dart';
import 'package:agentgateway/transport/foreground_relay.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
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
  test('opt-in relay authenticates polling, imports without fetching, and returns only an approved encrypted result', () async {
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
    var calls = 0;
    final relay = ForegroundRelay(
      origin,
      clock: () => now,
      client: MockClient((request) async {
        calls++;
        expect(request.url.toString(), '$origin/v1/device/sync');
        expect(request.followRedirects, false);
        expect(request.headers['Content-Type'], 'application/jose');
        final proof = await verifyObject(
          Map<String, dynamic>.from(publicIdentity(device)['signing']),
          request.body,
          'agw+sync',
        );
        expect(proof['audience'], origin);
        expect(proof['pairingEpoch'], delivery.epoch(identityId(agent)));
        if (calls == 1) {
          expect(proof['result'], isNull);
          return http.Response(
            jsonEncode({'acknowledged': null, 'envelope': envelope}),
            200,
          );
        }
        if (calls == 2) {
          expect(proof['knownRequests'], [context['requestId']]);
          expect(proof['result'], isNull);
          return http.Response(
            jsonEncode({'acknowledged': null, 'envelope': null}),
            200,
          );
        }
        if (calls == 3) {
          final result = Map<String, dynamic>.from(proof['result']);
          expect(result.keys.toSet(), {'context', 'jwe'});
          final expected = {
            ...context,
            'direction': 'result',
            'sender': context['recipient'],
            'recipient': context['sender'],
          };
          final payload = await decryptEnvelope(
            agent,
            publicIdentity(device),
            result,
            expected,
            now,
          );
          expect(payload['status'], 'allowed');
          expect(jsonEncode(payload), isNot(contains('person@example.com')));
          return http.Response(
            jsonEncode({
              'acknowledged': context['requestId'],
              'envelope': null,
            }),
            200,
          );
        }
        expect(proof['result'], isNull);
        return http.Response(
          jsonEncode({'acknowledged': null, 'envelope': null}),
          200,
        );
      }),
    );
    addTearDown(relay.close);
    await relay.sync(delivery, review);
    expect(calls, 0);
    await delivery.enableRelay(origin, true);
    await relay.sync(delivery, review);
    expect(source.fetches, 0);
    await relay.sync(delivery, review);
    expect(source.fetches, 0);
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
    await delivery.enableRelay(origin, false);
    await relay.sync(delivery, review);
    expect(calls, 4);
  });
  test('cancelled opt-in and unpairing prevent signed network access; consent survives restart for the same epoch only', () async {
    confirmation.allowed = false;
    await expectLater(delivery.enableRelay(origin, true), throwsA(anything));
    expect(delivery.relayEnabled(origin), false);
    confirmation.allowed = true;
    await delivery.enableRelay(origin, true);
    await delivery.initialize();
    expect(delivery.relayEnabled(origin), true);
    expect(delivery.relayEnabled('https://other.example.com'), false);
    final proof = await delivery.syncProof(origin, [], null);
    final decoded = await verifyObject(
      Map<String, dynamic>.from(publicIdentity(device)['signing']),
      proof,
      'agw+sync',
    );
    expect(decoded['expiresAt'] - decoded['issuedAt'], 30);
    // Disposable fixture consumed by the TypeScript relay test when present.
    File('.dart_tool/foreground-sync.json').writeAsStringSync(
      jsonEncode({'proof': proof, 'epoch': delivery.epoch(identityId(agent))}),
    );
    await delivery.unpair();
    expect(delivery.relayEnabled(origin), false);
    await expectLater(delivery.syncProof(origin, [], null), throwsA(anything));
  });
  test(
    'network errors and plaintext replies do not approve or fetch Gmail',
    () async {
      await delivery.enableRelay(origin, true);
      for (final response in [
        http.Response('unavailable', 503),
        http.Response(jsonEncode({'messages': []}), 200),
        http.Response('x' * 8193, 200),
      ]) {
        final relay = ForegroundRelay(
          origin,
          clock: () => now,
          client: MockClient((_) async => response),
        );
        await expectLater(relay.sync(delivery, review), throwsA(anything));
        relay.close();
      }
      expect(source.fetches, 0);
      expect(await review.entries(), isEmpty);
    },
  );
}
