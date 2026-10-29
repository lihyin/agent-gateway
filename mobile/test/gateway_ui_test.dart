import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentgateway/main.dart';
import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/domain/gateway_configuration.dart';
import 'package:agentgateway/domain/gmail_request.dart';
import 'package:agentgateway/screens/gateway_controller.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
import 'package:agentgateway/transport/foreground_relay.dart';
import 'package:agentgateway/transport/pin_pairing.dart';

import 'support/fakes.dart';

class _PairingController extends GatewayController {
  _PairingController({
    required super.session,
    required super.review,
    required super.gmailConfigured,
    required super.delivery,
    required super.relay,
  });
  int starts = 0;
  Future<bool> Function()? confirmation;
  @override
  Future<void> startPinPairing(Future<bool> Function() confirm) async {
    confirmation = confirm;
    starts++;
    pinPairing = PinPairing(
      PinExchange(relay!.origin),
      delivery!,
      changed: notifyListeners,
      confirm: confirm,
    )..status = 'waiting';
    notifyListeners();
  }
}

class _ReadyDelivery extends PairedDelivery {
  _ReadyDelivery(MemoryVault vault)
    : super(vault: vault, confirmation: FakeConfirmation());
  @override
  Future<void> initialize() async {}
  @override
  String get agentId => 'test-agent';
  @override
  String? epoch(String id) => id == agentId ? 'test-epoch' : null;
}

const configuration = GatewayConfiguration(
  environment: 'test',
  revision: 'test',
  relayUrl: 'https://relay.example.com',
);

void expectMinimalScreen() {
  for (final text in [
    'Request local preview',
    'Import encrypted request',
    'Export encrypted result',
    'Advanced: manual pairing',
    'Copy Gmail skill',
    'Copy pairing + Gmail skill',
    'Saved local rules',
  ]) {
    expect(find.text(text), findsNothing);
  }
  expect(find.textContaining('fingerprint'), findsNothing);
  expect(find.textContaining('Release:'), findsNothing);
  expect(find.textContaining('Environment:'), findsNothing);
  expect(find.byType(TextField), findsNothing);
}

void main() {
  setUpAll(() async {
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    final fonts = '$sdk/bin/cache/artifacts/material_fonts';
    // Real fonts improve local screenshots; widget assertions also run with
    // Flutter's test font on SDK installations without these optional assets.
    if (!File('$fonts/roboto-regular.ttf').existsSync() ||
        !File('$fonts/roboto-medium.ttf').existsSync() ||
        !File('$fonts/roboto-bold.ttf').existsSync() ||
        !File('$fonts/materialicons-regular.otf').existsSync()) {
      return;
    }
    final text = FontLoader('Roboto');
    for (final font in [
      'roboto-regular.ttf',
      'roboto-medium.ttf',
      'roboto-bold.ttf',
    ]) {
      text.addFont(
        File('$fonts/$font')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)),
      );
    }
    await text.load();
    await (FontLoader('MaterialIcons')..addFont(
          File('$fonts/materialicons-regular.otf')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)),
        ))
        .load();
  });
  testWidgets(
    'one pairing button starts pairing and copies the complete setup prompt',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
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
      final controller = _PairingController(
        session: GmailSession(vault, FakeOAuth(() => now)),
        review: ReviewService(
          vault: vault,
          source: FakeSource(() => now),
          confirmation: FakeConfirmation(),
          currentEpoch: delivery.epoch,
        ),
        gmailConfigured: true,
        delivery: delivery,
        relay: ForegroundRelay(configuration.relayUrl),
      );
      addTearDown(controller.dispose);
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
      const capture = ValueKey('screen');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: GatewayApp(
            configuration: configuration,
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectMinimalScreen();
      expect(find.text('Pair with Muse'), findsOneWidget);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('.dart_tool/minimal-home.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('Pair with Muse'));
      await tester.pumpAndSettle();
      expect(controller.starts, 1);
      expect(copied, contains(controller.pinPairing!.exchange.setupLine));
      expect(copied, contains('SKILL: Agent Gateway Gmail'));
      expect(copied, contains('pair --replace'));
      expect(find.text('Copy setup prompt'), findsOneWidget);
      expect(
        find.text(
          "Copied the setup prompt. Paste it into Muse's chatbox to continue",
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.textContaining(controller.pinPairing!.exchange.code),
        findsNothing,
      );
      expectMinimalScreen();
      await tester.tap(find.text('Copy setup prompt'));
      await tester.pumpAndSettle();
      expect(controller.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('Copy setup prompt'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Copy setup prompt'), findsOneWidget);
      await tester.tap(find.text('Cancel pairing'));
      await tester.pumpAndSettle();
      expect(controller.pinPairing, isNull);
      expect(find.text('Pair with Muse'), findsOneWidget);
      await tester.tap(find.text('Pair with Muse'));
      await tester.pumpAndSettle();
      const pushChannel = MethodChannel('agent_gateway/push');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pushChannel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pushChannel,
          null,
        ),
      );
      controller.pinPairing!.status = 'confirming';
      final answer = controller.confirmation!();
      await tester.pumpAndSettle();
      expect(find.text('Allow and authenticate'), findsNothing);
      expect(find.text('Allow'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).actionsAlignment,
        MainAxisAlignment.center,
      );
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(await answer, isFalse);
      controller.cancelPinPairing();
      await tester.pumpAndSettle();
      var notificationAnswer = Completer<bool?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pushChannel,
        (call) async {
          if (call.method == 'pairingPrompt') {
            expect(
              (call.arguments as Map)['session'],
              controller.pinPairing!.exchange.session,
            );
            return notificationAnswer.future;
          }
          return null;
        },
      );
      await tester.tap(find.text('Pair with Muse'));
      await tester.pumpAndSettle();
      controller.pinPairing!.status = 'confirming';
      final allowed = controller.confirmation!();
      await tester.pumpAndSettle();
      notificationAnswer.complete(true);
      await tester.pumpAndSettle();
      expect(await allowed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      controller.cancelPinPairing();
      notificationAnswer = Completer<bool?>();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair with Muse'));
      await tester.pumpAndSettle();
      controller.pinPairing!.status = 'confirming';
      final cancelled = controller.confirmation!();
      await tester.pumpAndSettle();
      controller.cancelPinPairing();
      await tester.pumpAndSettle();
      notificationAnswer.complete(true);
      await tester.pumpAndSettle();
      expect(await cancelled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'remote requests retain access and disclosure approval but completed history is hidden',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final vault = MemoryVault();
      final now = DateTime.now().toUtc();
      final delivery = _ReadyDelivery(vault);
      final source = FakeSource(() => now);
      final review = ReviewService(
        vault: vault,
        source: source,
        confirmation: FakeConfirmation(),
        currentEpoch: delivery.epoch,
      );
      final controller = GatewayController(
        session: GmailSession(vault, FakeOAuth(() => now)),
        review: review,
        gmailConfigured: true,
        delivery: delivery,
      );
      await controller.initialize();
      await controller.connect();
      addTearDown(controller.dispose);
      GmailRequest request(String id, String purpose) => GmailRequest(
        id: id,
        agentId: delivery.agentId,
        pairingEpoch: delivery.epoch(delivery.agentId)!,
        query: 'subject:invoice',
        purpose: purpose,
        fields: {'id', 'date', 'subject'},
        since: now.subtract(const Duration(days: 7)),
        until: now,
        maxResults: 1,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      await review.begin(request('remote-one', 'Find my invoice'));
      const previewCapture = ValueKey('request-preview');
      await tester.pumpWidget(
        RepaintBoundary(
          key: previewCapture,
          child: GatewayApp(
            configuration: configuration,
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectMinimalScreen();
      expect(source.fetches, 0);
      expect(find.text('Paired'), findsOneWidget);
      expect(find.text('Unpair'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('Copy Muse setup'), findsNothing);
      expect(find.text('Unpair Muse'), findsNothing);
      expect(find.text('Disconnect Gmail'), findsNothing);
      expect(
        tester.getCenter(find.text('Gmail')).dy,
        tester.getCenter(find.text('Connected')).dy,
      );
      expect(find.textContaining('Search:'), findsNothing);
      await tester.ensureVisible(find.text('Preview'));
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(source.fetches, 1);
      expect(find.textContaining('Invoice for [redacted]'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
      await tester.ensureVisible(find.text('Share once'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(previewCapture),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('.dart_tool/request-preview.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(find.textContaining('person@example.com'), findsNothing);
      expect(find.text('1 email'), findsOneWidget);
      expect(find.text('1 email to share'), findsNothing);
      expect(find.text('Needs your approval'), findsNothing);
      expect(find.text('Device confirmation required'), findsNothing);
      expect(find.text('Find my invoice'), findsNothing);
      expect(find.textContaining('Message ID:'), findsNothing);
      await tester.ensureVisible(find.text('Details'));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('Search: subject:invoice'), findsOneWidget);
      expect(find.textContaining('Message ID:'), findsOneWidget);
      await tester.ensureVisible(find.text('Details'));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Share once'));
      await tester.tap(find.text('Share once'));
      await tester.pumpAndSettle();
      expect((await review.entries()).single.state, ReviewState.allowed);
      expect(find.text('Find my invoice'), findsNothing);
      expect(find.textContaining('Invoice for [redacted]'), findsNothing);
      await review.begin(request('remote-two', 'Another request'));
      await controller.reload();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Deny'));
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(source.fetches, 1);
      expect(find.text('Another request'), findsNothing);
      expect(controller.pendingEntries, isEmpty);
      await tester.ensureVisible(find.text('Disconnect'));
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(controller.connected, isFalse);
      expectMinimalScreen();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
