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
       notifications = notifications ?? NativePushNotifications();
  final String origin;
  final http.Client _client;
  final DateTime Function() clock;
  final PushNotifications notifications;
  final Set<String> _handedOff = {};
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
    int expected,
  ) async {
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
            ..headers['Content-Type'] = 'application/jose'
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

  Future<String> register(PairedDelivery delivery) async {
    final token = await notifications.register();
    if (!RegExp(r'^[0-9a-f]{64,200}$').hasMatch(token)) {
      throw const GatewayError('notifications_unavailable');
    }
    final value = await _post(
      '/v1/routes',
      await delivery.registrationProof(origin, token),
      200,
    );
    if (value.length != 2 ||
        value['route'] is! String ||
        (value['route'] as String).length > 3000 ||
        value['expiresAt'] is! int ||
        value['expiresAt'] <= clock().millisecondsSinceEpoch ~/ 1000) {
      throw const GatewayError('relay_unavailable');
    }
    await delivery.saveRoute(origin, value['route'], value['expiresAt']);
    return value['route'];
  }

  Future<void> sync(PairedDelivery delivery, ReviewService review) async {
    if (!delivery.relayEnabled(origin)) return;
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
      await notifications.acknowledge(encoded);
    }
    final entries = (await review.entries())
        .where(
          (entry) =>
              entry.request.agentId == delivery.agentId &&
              entry.request.pairingEpoch ==
                  delivery.epoch(entry.request.agentId),
        )
        .toList();
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
