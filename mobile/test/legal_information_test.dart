import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/domain/gateway_configuration.dart';
import 'package:agentgateway/main.dart';
import 'package:agentgateway/screens/gateway_controller.dart';
import 'package:agentgateway/screens/legal_information.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _CountingOAuth extends FakeOAuth {
  _CountingOAuth() : super(DateTime.now);
  int signIns = 0;
  @override
  Future<GmailTokens> authorize() {
    signIns++;
    return super.authorize();
  }
}

void main() {
  testWidgets('legal links open the public dedicated policy pages', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LegalLinks(
            openUrl: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terms of Use'));
    await tester.pumpAndSettle();
    expect(opened.map((url) => url.toString()), [
      'https://gateway.zerobox.ai/privacy/',
      'https://gateway.zerobox.ai/terms/',
    ]);
  });

  testWidgets('failed browser launch leaves a readable policy address', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LegalLinks(
            openUrl: (_) async => throw StateError('browser unavailable'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('https://gateway.zerobox.ai/privacy/'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('policies are visible before sign-in and OAuth needs Continue', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final vault = MemoryVault();
    final oauth = _CountingOAuth();
    final controller = GatewayController(
      session: GmailSession(vault, oauth),
      review: ReviewService(
        vault: vault,
        source: FakeSource(DateTime.now),
        confirmation: FakeConfirmation(),
        currentEpoch: (_) => null,
      ),
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
    for (final label in ['Privacy Policy', 'Terms of Use']) {
      expect(find.text(label), findsOneWidget);
      expect(
        tester.getCenter(find.text(label)).dy,
        lessThan(tester.getCenter(find.text('Connect Gmail')).dy),
      );
    }
    await tester.ensureVisible(find.text('Connect Gmail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Gmail'));
    await tester.pumpAndSettle();
    expect(find.text('Before connecting Gmail'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(LegalLinks),
      ),
      findsOneWidget,
    );
    expect(oauth.signIns, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(oauth.signIns, 0);
    expect(controller.connected, isFalse);
    await tester.ensureVisible(find.text('Connect Gmail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Gmail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue to Google'));
    await tester.pumpAndSettle();
    expect(oauth.signIns, 1);
    expect(controller.connected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
