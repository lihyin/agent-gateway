import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:agentgateway/domain/gateway_configuration.dart';
import 'package:agentgateway/main.dart';
import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/screens/gateway_controller.dart';

import 'support/fakes.dart';

class _DelayedReview extends ReviewService {
  _DelayedReview(MemoryVault vault)
    : super(
        vault: vault,
        source: FakeSource(DateTime.now),
        confirmation: FakeConfirmation(),
        currentEpoch: (_) => null,
      );
  Completer<void>? hold;
  int initializations = 0, reads = 0;
  @override
  Future<void> initialize() async {
    initializations++;
    await super.initialize();
  }

  @override
  Future<List<ReviewEntry>> entries() async {
    reads++;
    await hold?.future;
    return super.entries();
  }
}

void main() {
  testWidgets('automatic refresh stays quiet and preserves user actions', (
    tester,
  ) async {
    final vault = MemoryVault();
    final review = _DelayedReview(vault);
    final controller = GatewayController(
      session: GmailSession(vault, FakeOAuth(DateTime.now)),
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
    final reads = review.reads;
    review.hold = Completer<void>();
    final refresh = controller.reload();
    await tester.pump();
    expect(controller.busy, isFalse);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Connect Gmail'))
          .onPressed,
      isNotNull,
    );
    // Timer ticks must not start overlapping background refreshes.
    await tester.pump(const Duration(seconds: 15));
    expect(review.reads, reads + 1);
    await tester.tap(find.text('Connect Gmail'));
    await tester.pump();
    expect(controller.connected, isFalse);
    review.hold!.complete();
    await refresh;
    await tester.pumpAndSettle();
    expect(controller.connected, isTrue);
    expect(controller.error, isNull);
    await controller.initialize();
    await tester.pumpAndSettle();
    expect(review.initializations, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unconfigured app keeps Gmail sign-in and agent access disabled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const configuration = GatewayConfiguration(
        environment: 'test',
        revision: 'tested-revision',
        relayUrl: 'https://relay.test',
      );
      expect(configuration.sourceAccessEnabled, isFalse);
      final vault = MemoryVault();
      final now = DateTime.now();
      final controller = GatewayController(
        session: GmailSession(vault, FakeOAuth(() => now)),
        review: ReviewService(
          vault: vault,
          source: FakeSource(() => now),
          confirmation: FakeConfirmation(),
          currentEpoch: (_) => null,
        ),
        gmailConfigured: false,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        GatewayApp(configuration: configuration, controller: controller),
      );
      expect(find.text('Agent Gateway'), findsOneWidget);
      expect(find.text('Release: tested-revision'), findsNothing);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Connect Gmail'),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('Gmail connection is not available'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
