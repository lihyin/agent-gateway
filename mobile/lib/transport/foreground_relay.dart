import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../approvals/review_service.dart';
import '../domain/gateway_error.dart';
import 'paired_delivery.dart';

class ForegroundRelay {
  ForegroundRelay(String url, {http.Client? client, DateTime Function()? clock})
    : origin = _origin(url),
      _client = client ?? http.Client(),
      clock = clock ?? DateTime.now;
  final String origin;
  final http.Client _client;
  final DateTime Function() clock;
  final Set<String> _acknowledged = {};
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

  Future<void> sync(PairedDelivery delivery, ReviewService review) async {
    if (!delivery.relayEnabled(origin)) return;
    final entries = (await review.entries())
        .where(
          (entry) =>
              entry.request.agentId == delivery.agentId &&
              entry.request.pairingEpoch ==
                  delivery.epoch(entry.request.agentId),
        )
        .toList();
    final ids = entries.map((entry) => entry.request.id).toList();
    _acknowledged.removeWhere((id) => !ids.contains(id));
    Map<String, dynamic>? result;
    for (final entry in entries) {
      if (!_acknowledged.contains(entry.request.id) &&
          entry.request.expiresAt.isAfter(clock()) &&
          [ReviewState.allowed, ReviewState.denied].contains(entry.state)) {
        result = Map<String, dynamic>.from(
          jsonDecode(await delivery.exportResult(entry, review)),
        );
        break;
      }
    }
    final proof = await delivery.syncProof(origin, ids, result);
    try {
      final request = http.Request('POST', Uri.parse('$origin/v1/device/sync'))
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/jose'
        ..body = proof;
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 || (response.contentLength ?? 0) > 8192) {
        await response.stream.listen(null).cancel();
        throw const GatewayError('relay_unavailable');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 12),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 8192) throw const GatewayError('relay_unavailable');
      }
      final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (value.length != 2 ||
          !value.containsKey('acknowledged') ||
          !value.containsKey('envelope')) {
        throw const GatewayError('relay_unavailable');
      }
      // An unpair/disable while the network request was pending cannot import data.
      if (!delivery.relayEnabled(origin)) return;
      final acknowledged = value['acknowledged'];
      if (acknowledged != null) {
        if (result == null || acknowledged != result['context']['requestId']) {
          throw const GatewayError('relay_unavailable');
        }
        _acknowledged.add(acknowledged as String);
      }
      if (value['envelope'] != null) {
        await delivery.importRequest(jsonEncode(value['envelope']), review);
      }
    } on GatewayError {
      rethrow;
    } catch (_) {
      throw const GatewayError('relay_unavailable');
    }
  }

  void close() => _client.close();
}
