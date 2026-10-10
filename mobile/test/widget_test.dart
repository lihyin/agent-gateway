import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:agentgateway/domain/gateway_configuration.dart';
import 'package:agentgateway/main.dart';
import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/screens/gateway_controller.dart';

import 'support/fakes.dart';

void main() {
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
      expect(find.text('Release: tested-revision'), findsOneWidget);
      expect(
        find.textContaining(
          'Agent pairing and transmission are not available yet.',
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Connect Gmail'),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('Google iOS client configuration'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
