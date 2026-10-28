import 'dart:async';

import 'package:flutter/foundation.dart';

import '../approvals/local_confirmation.dart';
import '../approvals/review_service.dart';
import '../connectors/gmail_auth.dart';
import '../connectors/gmail_connector.dart';
import '../domain/gateway_configuration.dart';
import '../domain/gateway_error.dart';
import '../domain/muse_skill.dart';
import '../transport/paired_delivery.dart';
import '../transport/foreground_relay.dart';
import '../transport/pin_pairing.dart';
import '../vault/vault.dart';

class GatewayController extends ChangeNotifier {
  GatewayController({
    required this.session,
    required this.review,
    required this.gmailConfigured,
    this.delivery,
    this.relay,
  });
  factory GatewayController.device(GatewayConfiguration configuration) {
    final vault = DeviceVault();
    final oauth = GmailOAuthConfiguration(configuration.googleIosClientId);
    final session = GmailSession(vault, NativeGmailOAuth(oauth));
    final delivery = PairedDelivery(
      vault: vault,
      confirmation: DeviceConfirmation(),
    );
    final review = ReviewService(
      vault: vault,
      source: GmailConnector(session),
      confirmation: DeviceConfirmation(),
      currentEpoch: delivery.epoch,
    );
    return GatewayController(
      session: session,
      review: review,
      gmailConfigured: oauth.isValid,
      delivery: delivery,
      relay: configuration.relayUrl.isEmpty
          ? null
          : ForegroundRelay(configuration.relayUrl),
    );
  }
  final GmailSession session;
  final ReviewService review;
  final bool gmailConfigured;
  final PairedDelivery? delivery;
  final ForegroundRelay? relay;
  PinPairing? pinPairing;
  Future<void> startPinPairing(Future<bool> Function() confirm) =>
      _run(() async {
        if (relay == null || delivery == null || delivery!.agentId != null) {
          throw const GatewayError('relay_configuration_required');
        }
        pinPairing?.close();
        final pairing = PinPairing(
          PinExchange(relay!.origin),
          delivery!,
          changed: _notify,
          confirm: confirm,
        );
        pinPairing = pairing;
        await pairing.start();
      });
  void cancelPinPairing() {
    pinPairing?.close();
    pinPairing = null;
    _notify();
  }

  bool foreground = true;
  bool get relayEnabled =>
      relay != null && (delivery?.relayEnabled(relay!.origin) ?? false);
  bool get pairingComplete =>
      delivery?.agentId != null &&
      (pinPairing == null || pinPairing!.status == 'paired');
  String? get museSkill => relay == null || delivery?.agentId == null
      ? null
      : museGmailSkill(
          origin: relay!.origin,
          notificationsEnabled: relayEnabled,
        );
  bool connected = false, busy = false, ready = false;
  String? error;
  List<ReviewEntry> entries = [];
  List<ReviewEntry> get pendingEntries => entries
      .where(
        (entry) =>
            entry.request.agentId == delivery?.agentId &&
            delivery?.epoch(entry.request.agentId) ==
                entry.request.pairingEpoch &&
            entry.request.expiresAt.isAfter(DateTime.now()) &&
            [
              ReviewState.access,
              ReviewState.fetching,
              ReviewState.disclosure,
            ].contains(entry.state),
      )
      .toList(growable: false);
  List<Map<String, dynamic>> rules = [];
  bool _disposed = false;
  Completer<void>? _operation;
  Future<void> _run(
    Future<void> Function() task, {
    bool background = false,
  }) async {
    if (_disposed) return;
    final active = _operation;
    if (active != null) {
      if (background || busy) return;
      // A user action waits for an in-flight sync rather than being dropped.
      await active.future;
      return _run(task);
    }
    final operation = Completer<void>();
    _operation = operation;
    busy = !background;
    error = null;
    if (!background) _notify();
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
      _operation = null;
      operation.complete();
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (!ready) {
      await _run(() async {
        await delivery?.initialize();
        await review.initialize();
        connected = await session.isConnected();
        await _reload();
        ready = true;
      });
    }
    // Render saved local state immediately; network sync is unobtrusive.
    if (ready) unawaited(reload());
  }

  Future<void> _reload() async {
    entries = (await review.entries())
        .where(
          (entry) => [
            ReviewState.access,
            ReviewState.fetching,
            ReviewState.disclosure,
          ].contains(entry.state),
        )
        .toList(growable: false);
    rules = await review.rules();
  }

  Future<void> _sync() async {
    if (foreground && relayEnabled) await relay!.refreshRegistration(delivery!);
    if (foreground && connected && relayEnabled) {
      await relay!.sync(delivery!, review);
      await _reload();
    }
  }

  Future<void> reload() => _run(() async {
    await _reload();
    await _sync();
  }, background: true);
  Future<void> enableRelay(bool enabled) => _run(() async {
    if (relay == null || delivery == null) {
      throw const GatewayError('relay_configuration_required');
    }
    if (!enabled) await relay!.disable(delivery!);
    await delivery!.enableRelay(relay!.origin, enabled);
    if (enabled) await relay!.register(delivery!);
    await _sync();
  });
  Future<void> connect() => _run(() async {
    await review.cancelAll();
    await session.connect();
    connected = true;
    await _reload();
    await _sync();
  });
  Future<void> disconnect() => _run(() async {
    connected = false;
    entries = [];
    rules = [];
    await review.cancelAll();
    await session.disconnect();
  });
  Future<void> access(ReviewEntry entry, bool allow) => _run(() async {
    if (allow) {
      await review.approveAccess(entry.request.id, entry.revision);
    } else {
      await review.denyAccess(entry.request.id, entry.revision);
    }
    await _reload();
    await _sync();
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
    await _sync();
  });
  Future<void> clearSavedApprovals() => _run(() async {
    for (final rule in await review.rules()) {
      await review.revokeRule(rule['scope'] as String);
    }
    await _reload();
  });
  void obscure() {
    foreground = false;
    relay?.invalidateRegistration();
    entries = [];
    _notify();
  }

  Future<void> unpair() => _run(() async {
    cancelPinPairing();
    if (relay != null && delivery?.agentId != null) {
      await relay!.revoke(delivery!);
    }
    await delivery?.unpair();
    await review.cancelAll();
    await _reload();
  });
  @override
  void dispose() {
    _disposed = true;
    pinPairing?.close();
    super.dispose();
    relay?.close();
  }
}
