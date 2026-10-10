import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentgateway/main.dart';
import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/domain/gateway_configuration.dart';
import 'package:agentgateway/screens/gateway_controller.dart';

import 'support/fakes.dart';

void main() {
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
      await tester.tap(find.text('Disconnect and revoke'));
      await tester.pumpAndSettle();
      expect(find.text('Gmail: not connected'), findsOneWidget);
      expect(controller.entries, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
