import 'dart:convert';

import 'package:agentgateway/vault/vault.dart';
import 'package:agentgateway/connectors/gmail_auth.dart';
import 'package:agentgateway/connectors/gmail_connector.dart';
import 'package:agentgateway/domain/gmail_request.dart';
import 'package:agentgateway/approvals/local_confirmation.dart';

class MemoryVault implements Vault {
  final values = <String, Map<String, dynamic>>{};
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    if (fail) throw StateError('locked');
    final v = values[key];
    return v == null ? null : jsonDecode(jsonEncode(v));
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (fail) throw StateError('locked');
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> delete(String key) async {
    if (fail) throw StateError('locked');
    values.remove(key);
  }
}

class FakeOAuth implements GmailOAuthProvider {
  FakeOAuth(this.now);
  final DateTime Function() now;
  int refreshCount = 0, revokeCount = 0;
  bool failRefresh = false, failRevoke = false;
  Future<void> Function()? beforeRefresh, beforeAuthorize;
  GmailTokens tokens() => GmailTokens(
    accessToken: 'test-access-token',
    refreshToken: 'test-refresh-token',
    expiresAt: now().add(const Duration(hours: 1)),
    scopes: [gmailReadScope],
  );
  @override
  Future<GmailTokens> authorize() async {
    await beforeAuthorize?.call();
    return tokens();
  }

  @override
  Future<GmailTokens> refresh(GmailTokens current) async {
    refreshCount++;
    await beforeRefresh?.call();
    if (failRefresh) throw StateError('revoked');
    return tokens();
  }

  @override
  Future<void> revoke(GmailTokens current) async {
    revokeCount++;
    if (failRevoke) throw StateError('offline');
  }
}

class FakeConfirmation implements LocalConfirmation {
  bool allowed = true;
  int count = 0;
  @override
  Future<bool> confirm(String reason) async {
    count++;
    return allowed;
  }
}

class FakeSource implements GmailSource {
  FakeSource(this.now);
  final DateTime Function() now;
  int fetches = 0;
  Future<void> Function()? duringFetch;
  @override
  Future<List<GmailRecord>> search(
    GmailRequest request,
    Future<void> Function() revalidate,
  ) async {
    fetches++;
    await revalidate();
    await duringFetch?.call();
    await revalidate();
    return [
      GmailRecord(
        id: 'abc123',
        date: now().subtract(const Duration(days: 1)),
        from: 'Test <person@example.com>',
        subject: 'Invoice for person@example.com',
        snippet: 'Call +1 555 123 4567; ssn: 123-45-6789',
      ),
    ];
  }
}
