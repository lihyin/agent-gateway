import 'dart:async';

import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/connectors/gmail_sender.dart';
import 'package:agentgateway/domain/gateway_configuration.dart';
import 'package:agentgateway/domain/gateway_error.dart';
import 'package:agentgateway/domain/gmail_request.dart';
import 'package:agentgateway/main.dart';
import 'package:agentgateway/screens/gateway_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

import 'package:agentgateway/transport/paired_delivery.dart';

class _MuseDelivery extends PairedDelivery {
  _MuseDelivery(MemoryVault vault)
    : super(vault: vault, confirmation: FakeConfirmation());
  @override
  Future<void> initialize() async {}
  @override
  String get agentId => 'muse';
  @override
  String? epoch(String id) => id == 'muse' ? 'epoch' : null;
}

void main() {
  GmailSendRequest request(DateTime now, {String from = 'owner@example.com'}) =>
      GmailSendRequest(
        id: 'send-one',
        agentId: 'muse',
        pairingEpoch: 'epoch',
        purpose: 'Reply to invitation',
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
        from: from,
        to: ['to@example.com'],
        cc: ['cc@example.com'],
        bcc: ['bcc@example.com'],
        subject: 'Invitation response',
        body: 'Thank you. I will attend.',
      );
  ReviewService service(
    MemoryVault vault,
    DateTime now, {
    String? Function(String)? epoch,
  }) => ReviewService(
    vault: vault,
    source: FakeSource(() => now),
    confirmation: FakeConfirmation(),
    currentEpoch: epoch ?? (_) => 'epoch',
    clock: () => now,
  );

  test('send request survives persistence and cannot enter search or saved-rule approval', () async {
    final now = DateTime.now();
    final vault = MemoryVault();
    var review = service(vault, now);
    await review.initialize();
    final entry = await review.begin(request(now));
    await expectLater(
      review.approveAccess(entry.request.id, 0),
      throwsA(isA<GatewayError>()),
    );
    review = service(vault, now);
    await review.initialize();
    final restored = (await review.entries()).single;
    expect(restored.request, isA<GmailSendRequest>());
    expect(
      (restored.request as GmailSendRequest).body,
      'Thank you. I will attend.',
    );
    await review.denyAccess(restored.request.id, restored.revision);
    await expectLater(
      review.sendEmail(
        restored.request.id,
        restored.revision,
        (_, _) async => fail('Declined email sent'),
      ),
      throwsA(isA<GatewayError>()),
    );
  });

  test(
    'durable reservation prevents concurrent sends and retries after restart',
    () async {
      final now = DateTime.now();
      final vault = MemoryVault();
      final review = service(vault, now);
      await review.initialize();
      final entry = await review.begin(request(now));
      final entered = Completer<void>(), finish = Completer<String>();
      var sends = 0;
      final pending = review.sendEmail(entry.request.id, 0, (_, valid) async {
        sends++;
        expect(valid(), isTrue);
        entered.complete();
        return finish.future;
      });
      await entered.future;
      await expectLater(
        review.sendEmail(entry.request.id, 0, (_, _) async => 'duplicate'),
        throwsA(isA<GatewayError>()),
      );
      final restarted = service(vault, now);
      await restarted.initialize();
      expect((await restarted.entries()).single.state, ReviewState.failed);
      await expectLater(
        restarted.sendEmail(entry.request.id, 0, (_, _) async => 'duplicate'),
        throwsA(isA<GatewayError>()),
      );
      finish.complete('gmail-id');
      final sent = await pending;
      expect(sent.candidate, [
        {'id': 'gmail-id'},
      ]);
      expect(sends, 1);
      await expectLater(
        review.sendEmail(
          entry.request.id,
          sent.revision,
          (_, _) async => 'duplicate',
        ),
        throwsA(isA<GatewayError>()),
      );
    },
  );

  test(
    'failed/uncertain attempts cannot be retried with the same request',
    () async {
      final now = DateTime.now();
      final review = service(MemoryVault(), now);
      await review.initialize();
      final entry = await review.begin(request(now));
      await expectLater(
        review.sendEmail(
          entry.request.id,
          0,
          (_, _) async => throw const GatewayError('gmail_send_unknown'),
        ),
        throwsA(isA<GatewayError>()),
      );
      final failed = (await review.entries()).single;
      expect(failed.state, ReviewState.failed);
      await review.forRelease(
        failed.request.id,
        failed.revision,
        failed.candidateDigest,
      );
      await expectLater(
        review.sendEmail(
          entry.request.id,
          failed.revision,
          (_, _) async => 'duplicate',
        ),
        throwsA(isA<GatewayError>()),
      );
    },
  );

  test(
    'pairing revocation invalidates an in-flight send authorization',
    () async {
      final now = DateTime.now();
      String? epoch = 'epoch';
      final review = service(MemoryVault(), now, epoch: (_) => epoch);
      await review.initialize();
      final entry = await review.begin(request(now));
      await expectLater(
        review.sendEmail(entry.request.id, 0, (_, valid) async {
          epoch = null;
          expect(valid(), isFalse);
          throw const GatewayError('unpaired');
        }),
        throwsA(isA<GatewayError>()),
      );
    },
  );

  test(
    'connected-account mismatch blocks sending before device authentication',
    () async {
      final now = DateTime.now(), vault = MemoryVault();
      final review = service(vault, now);
      await review.initialize();
      final entry = await review.begin(request(now, from: 'other@example.com'));
      final session = GmailSession(
        vault,
        FakeOAuth(() => now, scopes: const [gmailReadScope, gmailSendScope]),
      );
      await session.connect();
      var posts = 0;
      final confirmation = FakeConfirmation();
      final sender = GmailSender(
        session,
        confirmation: confirmation,
        client: MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response('{"emailAddress":"owner@example.com"}', 200);
          }
          posts++;
          return http.Response('{"id":"must-not-send"}', 200);
        }),
      );
      final controller = GatewayController(
        session: session,
        review: review,
        gmailConfigured: true,
        gmailSender: sender,
      );
      addTearDown(controller.dispose);
      await controller.sendEmail(entry, () async {});
      expect(controller.error, 'gmail_sender_mismatch');
      expect(posts, 0);
      expect(confirmation.count, 0);
    },
  );

  test(
    'scope upgrade preserves pending send requests and durable reservations',
    () async {
      final now = DateTime.now(), vault = MemoryVault();
      final review = service(vault, now);
      await review.initialize();
      final entry = await review.begin(request(now));
      await review.retainSendRequestsForReconnect();
      expect(
        (await review.entries()).single.request.digest,
        entry.request.digest,
      );
      await review.sendEmail(
        entry.request.id,
        entry.revision,
        (_, _) async => 'sent-id',
      );
      await review.retainSendRequestsForReconnect();
      await expectLater(
        review.sendEmail(entry.request.id, 0, (_, _) async => 'duplicate'),
        throwsA(isA<GatewayError>()),
      );
    },
  );

  for (final allow in [false, true]) {
    testWidgets('Muse review displays complete message; Allow=$allow', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(430, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now(), vault = MemoryVault();
      final review = service(vault, now);
      await review.initialize();
      await review.begin(request(now));
      final session = GmailSession(
        vault,
        FakeOAuth(() => now, scopes: const [gmailReadScope, gmailSendScope]),
      );
      await session.connect();
      final confirmation = FakeConfirmation();
      var posts = 0;
      final sender = GmailSender(
        session,
        confirmation: confirmation,
        client: MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response('{"emailAddress":"owner@example.com"}', 200);
          }
          posts++;
          return http.Response('{"id":"sent-id"}', 200);
        }),
      );
      final controller = GatewayController(
        session: session,
        review: review,
        gmailConfigured: true,
        gmailSender: sender,
        delivery: _MuseDelivery(vault),
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
      expect(find.text('Compose email'), findsNothing);
      for (final text in [
        'From: owner@example.com',
        'To: to@example.com',
        'Cc: cc@example.com',
        'Bcc: bcc@example.com',
        'Subject: Invitation response',
        'Thank you. I will attend.',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      expect(posts, 0);
      final button = find.text(allow ? 'Allow' : 'Decline');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      // Flush controller/vault continuations before waiting for HTTP streams.
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(posts, allow ? 1 : 0);
      expect(confirmation.count, allow ? 1 : 0);
      expect(
        (await review.entries()).single.state,
        allow ? ReviewState.allowed : ReviewState.denied,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
