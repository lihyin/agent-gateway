import 'dart:math';

import 'package:flutter/foundation.dart';

import '../approvals/local_confirmation.dart';
import '../approvals/review_service.dart';
import '../connectors/gmail_auth.dart';
import '../connectors/gmail_connector.dart';
import '../domain/gateway_configuration.dart';
import '../domain/gateway_error.dart';
import '../domain/gmail_request.dart';
import '../vault/vault.dart';

class GatewayController extends ChangeNotifier {
  GatewayController({
    required this.session,
    required this.review,
    required this.gmailConfigured,
  });
  factory GatewayController.device(GatewayConfiguration configuration) {
    final vault = DeviceVault();
    final oauth = GmailOAuthConfiguration(configuration.googleIosClientId);
    final session = GmailSession(vault, NativeGmailOAuth(oauth));
    final review = ReviewService(
      vault: vault,
      source: GmailConnector(session),
      confirmation: DeviceConfirmation(),
      currentEpoch: (id) => id == 'device-owner' ? 'local-preview-v1' : null,
    );
    return GatewayController(
      session: session,
      review: review,
      gmailConfigured: oauth.isValid,
    );
  }
  final GmailSession session;
  final ReviewService review;
  final bool gmailConfigured;
  bool connected = false, busy = false, ready = false;
  String? error;
  List<ReviewEntry> entries = [];
  List<Map<String, dynamic>> rules = [];
  bool _disposed = false;
  Future<void> _run(Future<void> Function() task) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await task();
    } on GatewayError catch (e) {
      error = e.code;
      if (e.code == 'vault_unavailable' ||
          e.code == 'review_unavailable' ||
          e.code == 'review_state_invalid') {
        ready = false;
        entries = [];
        rules = [];
      }
    } catch (_) {
      error = 'operation_failed';
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _run(() async {
    await review.initialize();
    connected = await session.isConnected();
    ready = true;
    await _reload();
  });
  Future<void> _reload() async {
    entries = await review.entries();
    rules = await review.rules();
  }

  Future<void> reload() => _run(_reload);
  Future<void> connect() => _run(() async {
    await review.cancelAll();
    await session.connect();
    connected = true;
    await _reload();
  });
  Future<void> disconnect() => _run(() async {
    connected = false;
    entries = [];
    rules = [];
    await review.cancelAll();
    await session.disconnect();
  });
  Future<void> requestPreview(
    String query,
    String purpose, {
    bool includeSensitive = false,
  }) => _run(() async {
    if (!connected) throw const GatewayError('gmail_disconnected');
    final now = DateTime.now().toUtc();
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await review.begin(
      GmailRequest(
        id: id,
        agentId: 'device-owner',
        pairingEpoch: 'local-preview-v1',
        query: query,
        purpose: purpose,
        fields: {
          'id',
          'date',
          'subject',
          if (includeSensitive) 'from',
          if (includeSensitive) 'snippet',
        },
        since: now.subtract(const Duration(days: 7)),
        until: now,
        maxResults: 5,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
      ),
    );
    await _reload();
  });
  Future<void> access(ReviewEntry entry, bool allow) => _run(() async {
    if (allow) {
      await review.approveAccess(entry.request.id, entry.revision);
    } else {
      await review.denyAccess(entry.request.id, entry.revision);
    }
    await _reload();
  });
  Future<void> decide(
    ReviewEntry entry,
    ReviewAction action, {
    List<Map<String, dynamic>>? edited,
  }) => _run(() async {
    await review.decide(
      entry.request.id,
      entry.revision,
      entry.candidateDigest,
      action,
      edited: edited,
    );
    await _reload();
  });
  Future<void> revoke(String scope) => _run(() async {
    await review.revokeRule(scope);
    await _reload();
  });
  void obscure() {
    entries = [];
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
