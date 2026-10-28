import 'dart:convert';
import 'dart:io';

import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/screens/gateway_controller.dart';
import 'package:agentgateway/transport/crypto.dart';
import 'package:agentgateway/transport/foreground_relay.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
import 'package:agentgateway/transport/push_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

class _Push implements PushNotifications {
  @override
  Future<String> register() async => 'a' * 64;
  @override
  Future<List<String>> pending() async => [];
  @override
  Future<void> acknowledge(String envelope) async {}
}

void main() {
  test('ordinary controls reconnect Gmail and re-pair with a fresh push registration', () async {
    final f = jsonDecode(
      File('../protocol/fixtures/pairing.json').readAsStringSync(),
    );
    final now = DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true);
    final vault = MemoryVault();
    final confirmation = FakeConfirmation();
    final delivery = PairedDelivery(
      vault: vault,
      confirmation: confirmation,
      clock: () => now,
      keyGenerator: () async => Map<String, dynamic>.from(f['device']),
    );
    final source = FakeSource(() => now);
    final registrations = <String>[];
    final revocations = <String>[];
    final relay = ForegroundRelay(
      'https://relay.example.com',
      clock: () => now,
      notifications: _Push(),
      client: MockClient((request) async {
        if (request.url.path == '/v1/pairings/register') {
          return http.Response(jsonEncode({'status': 'registered'}), 200);
        }
        final type = request.url.path == '/v1/routes'
            ? 'agw+register'
            : 'agw+unpair';
        final proof = await verifyObject(
          Map<String, dynamic>.from(
            publicIdentity(Map<String, dynamic>.from(f['device']))['signing'],
          ),
          request.body,
          type,
        );
        if (type == 'agw+register') {
          registrations.add(proof['pairingEpoch'] as String);
        } else {
          revocations.add(proof['pairingEpoch'] as String);
        }
        return http.Response(
          jsonEncode({
            'status': type == 'agw+register' ? 'registered' : 'revoked',
          }),
          200,
        );
      }),
    );
    final controller = GatewayController(
      session: GmailSession(vault, FakeOAuth(() => now), clock: () => now),
      review: ReviewService(
        vault: vault,
        source: source,
        confirmation: confirmation,
        currentEpoch: delivery.epoch,
        clock: () => now,
      ),
      gmailConfigured: true,
      delivery: delivery,
      relay: relay,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect();
    await delivery.pair(f['offer'], f['fingerprint']);
    await controller.reload();
    await controller.enableRelay(true);
    expect(controller.error, isNull);
    final agent = delivery.agentId!;
    final firstEpoch = delivery.epoch(agent)!;
    expect(registrations, [firstEpoch]);

    await controller.disconnect();
    expect(controller.connected, isFalse);
    expect(
      delivery.epoch(agent),
      firstEpoch,
    ); // Gmail and pairing are independent.
    await controller.connect();
    expect(controller.connected, isTrue);
    expect(controller.pairingComplete, isTrue);
    expect(controller.relayEnabled, isTrue);

    await controller.unpair();
    await controller.disconnect();
    expect(revocations, [firstEpoch]);
    expect(delivery.agentId, isNull);
    expect(controller.relayEnabled, isFalse);

    await controller.connect();
    await delivery.pair(f['offer'], f['fingerprint']);
    await controller.reload();
    final secondEpoch = delivery.epoch(delivery.agentId!)!;
    expect(secondEpoch, isNot(firstEpoch));
    expect(controller.pairingComplete, isTrue);
    expect(
      controller.relayEnabled,
      isFalse,
    ); // Each new pair needs explicit opt-in.
    await controller.enableRelay(true);
    expect(controller.error, isNull);
    expect(controller.connected, isTrue);
    expect(controller.relayEnabled, isTrue);
    expect(registrations, [firstEpoch, secondEpoch]);
    expect(
      source.fetches,
      0,
    ); // Reconnecting/pairing does not authorize Gmail reads.
  });
}
