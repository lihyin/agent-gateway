import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/connectors/gmail_connector.dart';
import 'package:agentgateway/domain/gmail_request.dart';

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late GmailSession session;
  GmailRequest request() => GmailRequest(
    id: 'test',
    agentId: 'agent',
    pairingEpoch: 'epoch',
    query: 'subject:invoice',
    purpose: 'Find receipt',
    fields: {'subject'},
    since: now.subtract(const Duration(days: 7)),
    until: now,
    maxResults: 1,
    issuedAt: now,
    expiresAt: now.add(const Duration(minutes: 5)),
  );
  setUp(() async {
    now = DateTime.utc(2026, 10, 10);
    session = GmailSession(
      MemoryVault(),
      FakeOAuth(() => now),
      clock: () => now,
    );
    await session.connect();
  });
  test('bounded list and metadata calls use only Google HTTPS and bearer headers', () async {
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      expect(r.url.host, 'gmail.googleapis.com');
      expect(r.url.scheme, 'https');
      expect(r.headers['Authorization'], 'Bearer test-access-token');
      expect(r.followRedirects, isFalse);
      expect(r.url.toString(), isNot(contains('test-access-token')));
      if (r.url.path.endsWith('/messages')) {
        expect(r.url.queryParameters['maxResults'], '1');
        expect(r.url.queryParameters['q'], contains('after:'));
        return http.Response(
          jsonEncode({
            'messages': [
              {'id': 'abc123'},
            ],
            'nextPageToken': 'ignored',
          }),
          200,
        );
      }
      expect(r.url.queryParameters['format'], 'metadata');
      return http.Response(
        jsonEncode({
          'id': 'abc123',
          'internalDate':
              '${now.subtract(const Duration(days: 1)).millisecondsSinceEpoch}',
          'payload': {
            'headers': [
              {'name': 'Subject', 'value': 'Invoice'},
              {'name': 'From', 'value': 'test@example.com'},
            ],
            'body': {'data': 'never requested'},
          },
          'snippet': 'text',
        }),
        200,
      );
    });
    final records = await GmailConnector(
      session,
      client: client,
    ).search(request(), () async {});
    expect(records.length, 1);
    expect(records.single.subject, 'Invoice');
    expect(calls, 2);
  });
  test(
    'missing access authorization prevents even the first provider call',
    () async {
      var calls = 0;
      final connector = GmailConnector(
        session,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        connector.search(request(), () async {
          throw StateError('denied');
        }),
        throwsA(anything),
      );
      expect(calls, 0);
    },
  );
  for (final status in [302, 401, 403, 429, 500]) {
    test(
      'provider HTTP $status fails without exposing response content',
      () async {
        final connector = GmailConnector(
          session,
          client: MockClient(
            (_) async => http.Response('private provider error', status),
          ),
        );
        try {
          await connector.search(request(), () async {});
          fail('accepted failure');
        } catch (e) {
          expect(e.toString(), isNot(contains('private')));
        }
      },
    );
  }
  test('oversize JSON and malformed message identifiers fail closed', () async {
    for (final body in [
      'x' * 131073,
      jsonEncode({
        'messages': [
          {'id': '../../evil'},
        ],
      }),
    ]) {
      final connector = GmailConnector(
        session,
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        connector.search(request(), () async {}),
        throwsA(anything),
      );
    }
  });
  test(
    'disconnect while request is in flight invalidates the response',
    () async {
      final connector = GmailConnector(
        session,
        client: MockClient((_) async {
          await session.disconnect();
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        connector.search(request(), () async {}),
        throwsA(anything),
      );
    },
  );
}
