import 'dart:async';
import 'dart:convert';

import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/connectors/gmail_sender.dart';
import 'package:agentgateway/domain/gateway_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

class _Confirmation extends FakeConfirmation {
  Future<void> Function()? during;
  @override
  Future<bool> confirm(String reason) async {
    count++;
    await during?.call();
    return allowed;
  }
}

Matcher code(String value) =>
    isA<GatewayError>().having((e) => e.code, 'code', value);

void main() {
  late DateTime now;
  late MemoryVault vault;
  late GmailSession session;
  late GmailSender sender;
  late GmailSendAccount account;
  late _Confirmation confirmation;
  late Future<http.Response> Function(http.Request) post;
  late int posts;
  late List<http.Request> requests;

  setUp(() async {
    now = DateTime.now().toUtc();
    vault = MemoryVault();
    session = GmailSession(
      vault,
      FakeOAuth(() => now, scopes: const [gmailReadScope, gmailSendScope]),
      clock: () => now,
    );
    await session.connect();
    confirmation = _Confirmation();
    posts = 0;
    requests = [];
    post = (_) async => http.Response('{"id":"sent-123"}', 200);
    sender = GmailSender(
      session,
      confirmation: confirmation,
      clock: () => now,
      client: MockClient((request) async {
        requests.add(request);
        expect(request.url.scheme, 'https');
        expect(request.url.host, 'gmail.googleapis.com');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer test-access-token');
        expect(request.url.toString(), isNot(contains('test-access-token')));
        if (request.method == 'GET') {
          expect(request.url.path, '/gmail/v1/users/me/profile');
          expect(request.url.queryParameters['fields'], 'emailAddress');
          return http.Response('{"emailAddress":"owner@example.com"}', 200);
        }
        expect(request.method, 'POST');
        expect(request.url.path, '/gmail/v1/users/me/messages/send');
        expect(confirmation.count, greaterThan(0));
        posts++;
        return post(request);
      }),
    );
    addTearDown(sender.close);
    account = await sender.loadAccount();
  });

  OutgoingEmail message({
    String subject = 'Hello 🌎',
    String body = 'Line one\nLine two',
  }) => OutgoingEmail(
    account: account,
    to: ['to@example.com'],
    cc: ['cc@example.com'],
    bcc: ['bcc@example.com'],
    subject: subject,
    body: body,
    now: now,
  );
  Future<String> send(OutgoingEmail email, {bool Function()? authorized}) =>
      sender.send(
        email,
        stillAuthorized: authorized ?? () => true,
        waitUntilResumed: () async {},
      );

  test(
    'reviewed immutable message sends once as bounded MIME directly to Gmail',
    () async {
      final email = message();
      expect(await send(email), 'sent-123');
      expect(posts, 1);
      expect(confirmation.count, 1);
      final json = jsonDecode(requests.last.body) as Map;
      expect(json.keys, ['raw']);
      final mime = utf8.decode(
        base64Url.decode(base64Url.normalize(json['raw'])),
      );
      expect(mime, contains('From: owner@example.com\r\n'));
      expect(mime, contains('To: to@example.com\r\n'));
      expect(mime, contains('Cc: cc@example.com\r\n'));
      expect(mime, contains('Bcc: bcc@example.com\r\n'));
      expect(mime, contains('Message-ID: <${email.id}@gateway.zerobox.ai>'));
      final encodedSubject = RegExp(r'\?B\?([^?]+)\?=')
          .firstMatch(mime)!
          .group(1)!;
      expect(utf8.decode(base64.decode(encodedSubject)), 'Hello 🌎');
      expect(
        utf8.decode(
          base64.decode(mime.split('\r\n\r\n').last.replaceAll('\r\n', '')),
        ),
        'Line one\r\nLine two',
      );
      expect(jsonEncode(vault.values), isNot(contains('Line one')));
      await expectLater(
        send(email),
        throwsA(code('gmail_send_already_attempted')),
      );
      expect(posts, 1);
    },
  );

  test(
    'long Unicode subjects use bounded encoded words and round-trip',
    () async {
      final subject = List.filled(190, '界').join();
      final mime = utf8.decode(
        base64Url.decode(base64Url.normalize(message(subject: subject).raw)),
      );
      final words = RegExp(r'=\?UTF-8\?B\?([^?]+)\?=')
          .allMatches(mime)
          .toList();
      expect(
        words.map((w) => utf8.decode(base64.decode(w.group(1)!))).join(),
        subject,
      );
      expect(words.every((word) => word.group(0)!.length <= 75), isTrue);
      expect(mime.split('\r\n').every((line) => line.length <= 998), isTrue);
    },
  );

  test('header injection, oversize input, and forged sender fail before authentication', () async {
    for (final bad in [
      message(subject: 'Subject\r\nBcc: attacker@example.com'),
      message(body: List.filled(65537, 'a').join()),
      OutgoingEmail(
        account: account,
        to: ['victim@example.com\r\nBcc:x@example.com'],
        subject: 'Hi',
        body: 'Body',
        now: now,
      ),
      OutgoingEmail(
        account: account,
        to: List.filled(21, 'to@example.com'),
        subject: 'Hi',
        body: 'Body',
        now: now,
      ),
    ]) {
      await expectLater(send(bad), throwsA(code('gmail_invalid_message')));
    }
    final forged = OutgoingEmail(
      account: GmailSendAccount('other@example.com', account.generation),
      to: ['to@example.com'],
      subject: 'Hi',
      body: 'Body',
      now: now,
    );
    await expectLater(send(forged), throwsA(code('gmail_profile_failed')));
    expect(confirmation.count, 0);
    expect(posts, 0);
  });

  test('authentication denial sends nothing', () async {
    confirmation.allowed = false;
    await expectLater(
      send(message()),
      throwsA(code('local_confirmation_required')),
    );
    expect(posts, 0);
  });

  for (final interruption in [
    'disconnect',
    'reconnect',
    'expired',
    'background',
  ]) {
    test('$interruption during authentication prevents submission', () async {
      final email = message();
      var foreground = true;
      confirmation.during = () async {
        if (interruption == 'disconnect') await session.disconnect();
        if (interruption == 'reconnect') await session.connect();
        if (interruption == 'expired') {
          now = now.add(const Duration(minutes: 6));
        }
        if (interruption == 'background') foreground = false;
      };
      await expectLater(
        send(email, authorized: () => foreground),
        throwsA(isA<GatewayError>()),
      );
      expect(posts, 0);
    });
  }

  test('concurrent Send is blocked while authentication is pending', () async {
    final entered = Completer<void>(), release = Completer<void>();
    confirmation.during = () async {
      entered.complete();
      await release.future;
    };
    final first = send(message());
    await entered.future;
    await expectLater(send(message()), throwsA(code('gmail_send_busy')));
    release.complete();
    expect(await first, 'sent-123');
    expect(posts, 1);
  });

  for (final outcome in ['network', 'server', 'redirect', 'invalid_response']) {
    test('$outcome does not automatically retry the send POST', () async {
      post = (_) async {
        if (outcome == 'network') {
          throw http.ClientException('connection ended');
        }
        if (outcome == 'server') return http.Response('unavailable', 503);
        if (outcome == 'redirect') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://attacker.example'},
          );
        }
        return http.Response('{}', 200);
      };
      final email = message();
      await expectLater(
        send(email),
        throwsA(
          code(
            outcome == 'redirect'
                ? 'gmail_send_rejected'
                : 'gmail_send_unknown',
          ),
        ),
      );
      await expectLater(
        send(email),
        throwsA(code('gmail_send_already_attempted')),
      );
      expect(posts, 1);
      expect(
        requests.every((request) => request.url.host == 'gmail.googleapis.com'),
        isTrue,
      );
    });
  }

  test('legacy read-only grants keep reading and cannot send', () async {
    final legacy = GmailSession(
      MemoryVault(),
      FakeOAuth(() => now),
      clock: () => now,
    );
    await legacy.connect();
    final readonly = GmailSender(
      legacy,
      confirmation: confirmation,
      client: MockClient(
        (_) async => throw StateError('no HTTP without send grant'),
      ),
    );
    addTearDown(readonly.close);
    await expectLater(
      readonly.loadAccount(),
      throwsA(code('gmail_send_permission_required')),
    );
    expect(await legacy.accessToken(), 'test-access-token');
    expect(await legacy.isConnected(), isTrue);
  });

  test(
    'a refreshed grant losing send permission preserves read access',
    () async {
      final scopes = [gmailReadScope, gmailSendScope];
      final scoped = GmailSession(
        MemoryVault(),
        FakeOAuth(() => now, scopes: scopes),
        clock: () => now,
      );
      await scoped.connect();
      scopes.remove(gmailSendScope);
      now = now.add(const Duration(hours: 2));
      await expectLater(
        scoped.accessToken(requiredScopes: {gmailReadScope, gmailSendScope}),
        throwsA(code('gmail_send_permission_required')),
      );
      expect(await scoped.accessToken(), 'test-access-token');
      expect(await scoped.isConnected(), isTrue);
    },
  );
}
