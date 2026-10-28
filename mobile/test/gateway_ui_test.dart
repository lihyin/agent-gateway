import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentgateway/main.dart';
import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/domain/gateway_configuration.dart';
import 'package:agentgateway/screens/gateway_controller.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
import 'package:agentgateway/transport/foreground_relay.dart';
import 'package:agentgateway/transport/pin_pairing.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'pairing shows one-time setup and keeps manual pairing advanced',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now();
      final vault = MemoryVault();
      final fixture = jsonDecode(
        File('../protocol/fixtures/pairing.json').readAsStringSync(),
      );
      final delivery = PairedDelivery(
        vault: vault,
        confirmation: FakeConfirmation(),
        keyGenerator: () async => Map<String, dynamic>.from(fixture['device']),
      );
      final controller = GatewayController(
        session: GmailSession(vault, FakeOAuth(() => now)),
        review: ReviewService(
          vault: vault,
          source: FakeSource(() => now),
          confirmation: FakeConfirmation(),
          currentEpoch: (_) => null,
        ),
        gmailConfigured: true,
        delivery: delivery,
        relay: ForegroundRelay('https://relay.example.com'),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        GatewayApp(
          configuration: const GatewayConfiguration(
            environment: 'test',
            revision: 'test',
            relayUrl: 'https://relay.example.com',
          ),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pair with Muse'), findsOneWidget);
      expect(find.text('Advanced: manual pairing'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Signed agent pairing offer'),
        findsNothing,
      );
      final exchange = PinExchange('https://relay.example.com');
      controller.pinPairing = PinPairing(
        exchange,
        delivery,
        changed: () {},
        confirm: () async => true,
      )..status = 'waiting';
      await controller.reload();
      await tester.pumpAndSettle();
      expect(find.text('Copy pairing + Gmail skill'), findsOneWidget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('Copy pairing + Gmail skill'));
      await tester.pumpAndSettle();
      expect(copied, contains(exchange.setupLine));
      expect(copied, contains('SKILL: Agent Gateway Gmail'));
      expect(copied, contains('RELAY_URL: https://relay.example.com'));
      expect(
        find.textContaining('Copied. Paste into your trusted'),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.pinPairing, isNotNull);
      expect(delivery.agentId, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.text(
          '${exchange.code.substring(0, 4)} ${exchange.code.substring(4)}',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel pairing'));
      await tester.pumpAndSettle();
      expect(find.text('Copy pairing + Gmail skill'), findsNothing);
      expect(controller.pinPairing, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Gmail UI connects, requires fetch consent, shows filtered preview and allows once',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now().toUtc();
      final vault = MemoryVault();
      final source = FakeSource(() => now);
      final session = GmailSession(vault, FakeOAuth(() => now));
      final review = ReviewService(
        vault: vault,
        source: source,
        confirmation: FakeConfirmation(),
        currentEpoch: (id) => id == 'device-owner' ? 'local-preview-v1' : null,
      );
      final controller = GatewayController(
        session: session,
        review: review,
        gmailConfigured: true,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        GatewayApp(
          configuration: const GatewayConfiguration(
            environment: 'test',
            revision: 'test',
            relayUrl: '',
          ),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect Gmail'));
      await tester.pumpAndSettle();
      expect(find.text('Gmail: connected'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), 'subject:invoice');
      await tester.enterText(find.byType(TextField).at(1), 'Find receipt');
      await tester.tap(find.text('Request local preview'));
      await tester.pumpAndSettle();
      expect(source.fetches, 0);
      expect(find.text('Allow Gmail access'), findsOneWidget);
      await tester.tap(find.text('Allow Gmail access'));
      await tester.pumpAndSettle();
      expect(source.fetches, 1);
      expect(find.textContaining('Invoice for [redacted]'), findsOneWidget);
      expect(find.textContaining('person@example.com'), findsNothing);
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Approved locally. No data has been transmitted to an agent.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Disconnect Gmail'));
      await tester.pumpAndSettle();
      expect(find.text('Gmail: not connected'), findsOneWidget);
      expect(controller.entries, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
