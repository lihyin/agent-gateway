import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/domain/gmail_request.dart';
import 'package:agentgateway/screens/gateway_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final scenario in [
    'success',
    'access_denied',
    'disclosure_denied',
    'fetch_failed',
    'cancelled',
    'expired',
  ]) {
    test('direct Allow preserves safeguards: $scenario', () async {
      var now = DateTime.now().toUtc();
      final vault = MemoryVault();
      final confirmation = FakeConfirmation();
      final source = FakeSource(() => now);
      final review = ReviewService(
        vault: vault,
        source: source,
        confirmation: confirmation,
        currentEpoch: (_) => 'epoch',
        clock: () => now,
      );
      final controller = GatewayController(
        session: GmailSession(vault, FakeOAuth(() => now)),
        review: review,
        gmailConfigured: true,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.connect();
      final request = GmailRequest(
        id: 'direct-request',
        agentId: 'agent',
        pairingEpoch: 'epoch',
        query: 'subject:invoice',
        purpose: 'Find my invoice',
        fields: {'id', 'subject', 'snippet'},
        since: now.subtract(const Duration(days: 7)),
        until: now,
        maxResults: 1,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      final entry = await review.begin(request);
      if (scenario == 'access_denied') confirmation.allowed = false;
      source.duringFetch = () async {
        if (scenario == 'disclosure_denied') confirmation.allowed = false;
        if (scenario == 'fetch_failed') throw StateError('offline');
        if (scenario == 'cancelled') await review.cancelAll();
        if (scenario == 'expired') now = now.add(const Duration(minutes: 6));
      };
      await controller.allowOnce(entry);
      final entries = await review.entries();
      expect(source.fetches, scenario == 'access_denied' ? 0 : 1);
      expect(await review.rules(), isEmpty);
      if (scenario == 'success') {
        expect(controller.error, isNull);
        expect(entries.single.state, ReviewState.allowed);
        expect(confirmation.count, 2);
        expect(
          entries.single.candidate.single['subject'],
          'Invoice for [redacted]',
        );
        expect(
          entries.single.candidate.single['snippet'],
          isNot(contains('123-45-6789')),
        );
        expect(controller.pendingEntries, isEmpty);
        // Reusing the original UI entry cannot fetch or approve it again.
        await controller.allowOnce(entry);
        expect(source.fetches, 1);
        expect(controller.error, 'stale_review');
      } else {
        expect(controller.error, isNotNull);
        expect(
          entries.where((entry) => entry.state == ReviewState.allowed),
          isEmpty,
        );
        if (scenario == 'disclosure_denied') {
          expect(
            controller.entries.single.state,
            ReviewState.disclosure,
          );
          expect(
            controller.entries.single.revision,
            greaterThan(entry.revision),
          );
        }
      }
    });
  }
}
