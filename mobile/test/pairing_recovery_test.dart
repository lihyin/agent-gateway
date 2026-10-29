import 'dart:convert';
import 'dart:io';

import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/screens/gateway_controller.dart';
import 'package:agentgateway/transport/foreground_relay.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
import 'package:agentgateway/transport/pin_pairing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';
import 'foreground_relay_test.dart' show FakePush;

class _WaitingPairing extends PinPairing {
  _WaitingPairing(
    super.exchange,
    super.delivery, {
    required super.changed,
    required super.confirm,
  });
  @override
  Future<void> start() async {
    status = 'waiting';
    changed();
  }
}

void main() {
  final fixture = jsonDecode(
    File('../protocol/fixtures/pairing.json').readAsStringSync(),
  );
  final now = DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true);

  for (final scenario in ['failed', 'legacy', 'restarted']) {
    final restarted = scenario == 'restarted';
    for (final relayKnowsPair in [false, true]) {
      test(
        'retry clears interrupted local pair; scenario=$scenario relayKnowsPair=$relayKnowsPair',
        () async {
          final vault = MemoryVault();
          PairedDelivery makeDelivery() => PairedDelivery(
            vault: vault,
            confirmation: FakeConfirmation(),
            clock: () => now,
            keyGenerator: () async =>
                Map<String, dynamic>.from(fixture['device']),
          );
          var delivery = makeDelivery();
          await delivery.initialize();
          await delivery.pair(
            fixture['offer'],
            fixture['fingerprint'],
            pendingConfirmation: scenario != 'legacy',
          );
          final oldAgent = delivery.agentId!;
          final oldEpoch = delivery.epoch(oldAgent)!;
          if (restarted) {
            delivery = makeDelivery();
            await delivery.initialize();
          }
          expect(delivery.pairingConfirmed, scenario == 'legacy');
          if (scenario != 'legacy') {
            await expectLater(
              delivery.enableRelay('https://relay.example.com', true),
              throwsA(anything),
            );
            expect(delivery.relayEnabled('https://relay.example.com'), isFalse);
          }
          var revocations = 0, starts = 0;
          final source = FakeSource(() => now);
          final relay = ForegroundRelay(
            'https://relay.example.com',
            notifications: FakePush(),
            client: MockClient((request) async {
              expect(request.url.path, '/v1/pairings/revoke');
              revocations++;
              return http.Response(
                jsonEncode({'status': 'revoked'}),
                relayKnowsPair ? 200 : 401,
              );
            }),
          );
          final controller = GatewayController(
            session: GmailSession(vault, FakeOAuth(() => now)),
            review: ReviewService(
              vault: vault,
              source: source,
              confirmation: FakeConfirmation(),
              currentEpoch: delivery.epoch,
              clock: () => now,
            ),
            gmailConfigured: true,
            delivery: delivery,
            relay: relay,
            pairingFactory:
                (exchange, delivery, {required changed, required confirm}) {
                  starts++;
                  return _WaitingPairing(
                    exchange,
                    delivery,
                    changed: changed,
                    confirm: confirm,
                  );
                },
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          String? oldSession;
          if (!restarted) {
            final failed =
                PinPairing(
                    PinExchange(relay.origin),
                    delivery,
                    changed: () {},
                    confirm: () async => false,
                  )
                  ..status = 'failed'
                  ..error = 'pairing_interrupted';
            oldSession = failed.exchange.session;
            controller.pinPairing = failed;
          }
          expect(controller.pairingComplete, isFalse);
          await controller.startPinPairing(() async => true);
          expect(controller.error, isNull);
          expect(controller.pinPairing!.status, 'waiting');
          expect(controller.pinPairing!.error, isNull);
          expect(controller.pinPairing!.exchange.session, isNot(oldSession));
          expect(delivery.agentId, isNull);
          expect(delivery.epoch(oldAgent), isNull);
          expect(revocations, 1);
          expect(starts, 1);
          expect(source.fetches, 0);
          await delivery.pair(
            fixture['offer'],
            fixture['fingerprint'],
            pendingConfirmation: true,
          );
          final freshEpoch = delivery.epoch(delivery.agentId!)!;
          expect(freshEpoch, isNot(oldEpoch));
          await expectLater(
            delivery.confirmPairing(oldEpoch),
            throwsA(anything),
          );
          expect(delivery.pairingConfirmed, isFalse);
          await delivery.confirmPairing(freshEpoch);
          expect(delivery.pairingConfirmed, isTrue);
        },
      );
    }
  }
  test('a completed pairing is preserved when start is called again', () async {
    final vault = MemoryVault();
    final delivery = PairedDelivery(
      vault: vault,
      confirmation: FakeConfirmation(),
      clock: () => now,
      keyGenerator: () async => Map<String, dynamic>.from(fixture['device']),
    );
    final relay = ForegroundRelay(
      'https://relay.example.com',
      notifications: FakePush(),
      client: MockClient(
        (_) async => throw StateError('must not revoke a completed pair'),
      ),
    );
    final controller = GatewayController(
      session: GmailSession(vault, FakeOAuth(() => now)),
      review: ReviewService(
        vault: vault,
        source: FakeSource(() => now),
        confirmation: FakeConfirmation(),
        currentEpoch: delivery.epoch,
        clock: () => now,
      ),
      gmailConfigured: true,
      delivery: delivery,
      relay: relay,
      pairingFactory: (
        exchange,
        delivery, {
        required changed,
        required confirm,
      }) => throw StateError('must not replace completed pair'),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await delivery.pair(fixture['offer'], fixture['fingerprint']);
    final agent = delivery.agentId!;
    final epoch = delivery.epoch(agent);
    await controller.startPinPairing(() async => true);
    expect(controller.error, 'pairing_already_complete');
    expect(delivery.agentId, agent);
    expect(delivery.epoch(agent), epoch);
    expect(controller.pairingComplete, isTrue);
  });
}
