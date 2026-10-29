import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../approvals/review_service.dart';
import '../domain/gateway_error.dart';
import 'paired_delivery.dart';
import 'push_notifications.dart';

class ForegroundRelay {
  ForegroundRelay(
    String url, {
    http.Client? client,
    DateTime Function()? clock,
    PushNotifications? notifications,
  }) : origin = _origin(url),
       _client = client ?? http.Client(),
       clock = clock ?? DateTime.now,
       notifications = notifications ?? NativePushNotifications() {
    if (this.notifications is NativePushNotifications) {
      (this.notifications as NativePushNotifications).onTokenChanged =
          invalidateRegistration;
      (this.notifications as NativePushNotifications).onAction = () =>
          onAction?.call();
    }
  }
  DateTime? _registeredAt;
  String? _registeredAgent;
  String? _enrolledEpoch;
  void invalidateRegistration() => _registeredAt = null;
  Future<void> refreshRegistration(PairedDelivery delivery) async {
    if (_registeredAt != null &&
        _registeredAgent == delivery.agentId &&
        clock().difference(_registeredAt!) < const Duration(minutes: 1)) {
      return;
    }
    await register(delivery);
  }

  final String origin;
  final http.Client _client;
  final DateTime Function() clock;
  final PushNotifications notifications;
  final Set<String> _handedOff = {};
  String? selectedRequestId;
  void Function()? onAction;
  static String _origin(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(
          r'^[a-z][a-z0-9.-]+\.[a-z]{2,}$',
          caseSensitive: false,
        ).hasMatch(uri.host) ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const GatewayError('relay_configuration_required');
    }
    return uri.origin;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    String proof,
    int expected, {
    String contentType = 'application/jose',
  }) async {
    final abort = Completer<void>();
    final deadline = Timer(const Duration(seconds: 12), () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse('$origin$path'),
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..headers['Content-Type'] = contentType
            ..body = proof;
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != expected ||
          (response.contentLength ?? 0) > 4096) {
        await response.stream.listen(null).cancel();
        throw const GatewayError('relay_unavailable');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 12),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 4096) throw const GatewayError('relay_unavailable');
      }
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)));
    } on GatewayError {
      rethrow;
    } catch (_) {
      throw const GatewayError('relay_unavailable');
    } finally {
      deadline.cancel();
    }
  }

  Future<void> register(PairedDelivery delivery) async {
    final epoch = delivery.agentId == null
        ? null
        : delivery.epoch(delivery.agentId!);
    if (_enrolledEpoch != epoch || epoch == null) {
      final enrolled = await _post(
        '/v1/pairings/register',
        jsonEncode(await delivery.pairRegistration(origin)),
        200,
        contentType: 'application/json',
      );
      if (enrolled['status'] != 'registered') {
        throw const GatewayError('relay_unavailable');
      }
      _enrolledEpoch = epoch;
    }
    final token = await notifications.register();
    if (!RegExp(r'^[0-9a-f]{64,200}$').hasMatch(token)) {
      throw const GatewayError('notifications_unavailable');
    }
    final value = await _post(
      '/v1/routes',
      await delivery.registrationProof(origin, token),
      200,
    );
    if (value.length != 1 || value['status'] != 'registered') {
      throw const GatewayError('relay_unavailable');
    }
    _registeredAt = clock();
    _registeredAgent = delivery.agentId;
  }

  Future<void> disable(PairedDelivery delivery) async {
    await _post(
      '/v1/routes/disable',
      await delivery.controlProof(origin, 'agw+route-disable'),
      200,
    );
    invalidateRegistration();
    await clearNotifications();
  }

  Future<void> revoke(PairedDelivery delivery) async {
    await _post(
      '/v1/pairings/revoke',
      await delivery.controlProof(origin, 'agw+unpair'),
      200,
    );
    invalidateRegistration();
    await clearNotifications();
  }

  Future<void> clearNotifications() async {
    for (final encoded in await notifications.pending()) {
      await notifications.acknowledge(encoded);
    }
    for (final action in await notifications.actions()) {
      await notifications.acknowledgeAction(action);
    }
    selectedRequestId = null;
    await notifications.setBadgeCount(0);
  }

  Future<void> sync(PairedDelivery delivery, ReviewService review) async {
    if (!delivery.relayEnabled(origin)) return;
    final imported = <String, String>{};
    // Notifications only deliver ciphertext. Import never grants Gmail access.
    for (final encoded in await notifications.pending()) {
      if (!delivery.relayEnabled(origin)) return;
      try {
        await delivery.importRequest(encoded, review);
      } on GatewayError catch (error) {
        if ([
          'invalid_envelope',
          'unpaired',
          'replay_changed_content',
          'invalid_or_expired_request',
        ].contains(error.code)) {
          await notifications.acknowledge(encoded);
        }
        rethrow;
      }
      imported[encoded] =
          (jsonDecode(encoded)['context']['requestId']) as String;
    }
    for (final action in await notifications.actions()) {
      final matching = (await review.entries()).where(
        (entry) =>
            entry.request.id == action.requestId &&
            entry.request.agentId == delivery.agentId &&
            entry.request.pairingEpoch ==
                delivery.epoch(entry.request.agentId) &&
            entry.request.expiresAt.isAfter(clock()),
      );
      if (matching.isNotEmpty) {
        final entry = matching.single;
        if (action.action == 'deny') {
          if (entry.state == ReviewState.access) {
            await review.denyAccess(entry.request.id, entry.revision);
          } else if (entry.state == ReviewState.disclosure) {
            await review.decide(
              entry.request.id,
              entry.revision,
              entry.candidateDigest,
              ReviewAction.deny,
            );
          }
        } else if (['approve', 'review'].contains(action.action)) {
          // A generic notification cannot replace inspecting the disclosure.
          // Both actions open the authenticated request for in-app approval.
          selectedRequestId = entry.request.id;
        }
      }
      await notifications.acknowledgeAction(action);
    }
    final entries = (await review.entries())
        .where(
          (entry) =>
              entry.request.agentId == delivery.agentId &&
              entry.request.pairingEpoch ==
                  delivery.epoch(entry.request.agentId),
        )
        .toList();
    final pendingIds = entries
        .where(
          (entry) =>
              entry.request.expiresAt.isAfter(clock()) &&
              [
                ReviewState.access,
                ReviewState.fetching,
                ReviewState.disclosure,
              ].contains(entry.state),
        )
        .map((entry) => entry.request.id)
        .toSet();
    await notifications.setBadgeCount(pendingIds.length);
    // Importing ciphertext is not user review: retain its notification until
    // the request is allowed, denied, expired or otherwise no longer pending.
    for (final item in imported.entries) {
      if (!pendingIds.contains(item.value)) {
        await notifications.acknowledge(item.key);
      }
    }
    _handedOff.removeWhere(
      (id) => !entries.any((entry) => entry.request.id == id),
    );
    for (final entry in entries) {
      if (_handedOff.contains(entry.request.id) ||
          !entry.request.expiresAt.isAfter(clock()) ||
          ![ReviewState.allowed, ReviewState.denied].contains(entry.state)) {
        continue;
      }
      final envelope = Map<String, dynamic>.from(
        jsonDecode(await delivery.exportResult(entry, review)),
      );
      final proof = await delivery.resultProof(origin, envelope);
      if (!delivery.relayEnabled(origin)) return;
      final value = await _post('/v1/results', proof, 202);
      if (value.length != 1 || value['status'] != 'handed_off') {
        throw const GatewayError('relay_unavailable');
      }
      // Transport handoff is distinct from verified Muse receipt.
      _handedOff.add(entry.request.id);
    }
  }

  void close() => _client.close();
}
