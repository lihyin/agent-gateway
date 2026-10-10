import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late MemoryVault vault;
  late FakeOAuth oauth;
  late GmailSession session;
  setUp(() {
    now = DateTime.utc(2026, 10, 10);
    vault = MemoryVault();
    oauth = FakeOAuth(() => now);
    session = GmailSession(vault, oauth, clock: () => now);
  });
  test('native configuration derives exact reversed client scheme and rejects invalid IDs', () {
    const config = GmailOAuthConfiguration(
      '123-abc.apps.googleusercontent.com',
    );
    expect(config.isValid, isTrue);
    expect(
      config.redirectUri,
      'com.googleusercontent.apps.123-abc:/oauthredirect',
    );
    for (final id in [
      '',
      'https://evil.test',
      '123-ABC.apps.googleusercontent.com',
    ]) {
      expect(GmailOAuthConfiguration(id).isValid, isFalse);
    }
  });
  test(
    'tokens persist across sessions without appearing in toString',
    () async {
      await session.connect();
      expect(await session.isConnected(), isTrue);
      session = GmailSession(vault, oauth, clock: () => now);
      expect(await session.accessToken(), 'test-access-token');
      expect(oauth.tokens().toString(), isNot(contains('test-access')));
    },
  );
  test(
    'concurrent refresh is serialized and refresh token is retained',
    () async {
      await session.connect();
      now = now.add(const Duration(hours: 2));
      final tokens = await Future.wait([
        session.accessToken(),
        session.accessToken(),
        session.accessToken(),
      ]);
      expect(tokens.toSet(), {'test-access-token'});
      expect(oauth.refreshCount, 1);
    },
  );
  test('refresh failure removes tokens and requires reconnect', () async {
    await session.connect();
    now = now.add(const Duration(hours: 2));
    oauth.failRefresh = true;
    await expectLater(session.accessToken(), throwsA(anything));
    expect(await vault.read('gmail.tokens'), isNull);
    expect(await session.isConnected(), isFalse);
  });
  test('disconnect during refresh cannot recreate credentials', () async {
    await session.connect();
    now = now.add(const Duration(hours: 2));
    final entered = Completer<void>(), release = Completer<void>();
    oauth.beforeRefresh = () async {
      entered.complete();
      await release.future;
    };
    final access = session.accessToken();
    final expected = expectLater(access, throwsA(anything));
    await entered.future;
    final disconnect = session.disconnect();
    release.complete();
    await expected;
    await disconnect;
    expect(await vault.read('gmail.tokens'), isNull);
    expect(await session.isConnected(), isFalse);
  });
  test('disconnect during browser authorization revokes new grant instead of storing it', () async {
    final entered = Completer<void>(), release = Completer<void>();
    oauth.beforeAuthorize = () async {
      entered.complete();
      await release.future;
    };
    final connect = session.connect();
    final expected = expectLater(connect, throwsA(anything));
    await entered.future;
    final disconnect = session.disconnect();
    release.complete();
    await expected;
    await disconnect;
    expect(await vault.read('gmail.tokens'), isNull);
    expect(oauth.revokeCount, 1);
  });
  test(
    'offline revocation still deletes credentials and review state locally',
    () async {
      await session.connect();
      await vault.write('review.state', {'private': 'test'});
      oauth.failRevoke = true;
      await expectLater(session.disconnect(), throwsA(anything));
      expect(await vault.read('gmail.tokens'), isNull);
      expect(await vault.read('review.state'), isNull);
      expect(await session.isConnected(), isFalse);
    },
  );
}
