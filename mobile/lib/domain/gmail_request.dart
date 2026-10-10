import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'gateway_error.dart';

const allowedGmailFields = {'id', 'date', 'from', 'subject', 'snippet'};

class GmailRequest {
  GmailRequest({
    required this.id,
    required this.agentId,
    required this.pairingEpoch,
    required this.query,
    required this.purpose,
    required Set<String> fields,
    required this.since,
    required this.until,
    required this.maxResults,
    required this.issuedAt,
    required this.expiresAt,
  }) : fields = Set.unmodifiable(fields);
  final String id, agentId, pairingEpoch, query, purpose;
  final Set<String> fields;
  final DateTime since, until, issuedAt, expiresAt;
  final int maxResults;
  bool get highRisk => fields.contains('snippet') || fields.contains('from');
  void validate(DateTime now) {
    if (id.isEmpty ||
        id.length > 128 ||
        agentId.isEmpty ||
        pairingEpoch.isEmpty ||
        query.trim().isEmpty ||
        query.length > 200 ||
        purpose.trim().isEmpty ||
        purpose.length > 200 ||
        fields.isEmpty ||
        !allowedGmailFields.containsAll(fields) ||
        maxResults < 1 ||
        maxResults > 10 ||
        !since.isBefore(until) ||
        until.isAfter(issuedAt) ||
        until.difference(since) > const Duration(days: 30) ||
        issuedAt.isAfter(now) ||
        !expiresAt.isAfter(now) ||
        expiresAt.difference(issuedAt) > const Duration(minutes: 5) ||
        !expiresAt.isAfter(issuedAt)) {
      throw const GatewayError('invalid_or_expired_request');
    }
    // No unconstrained wildcard searches or query-supplied field/time overrides.
    if (query.contains('*') ||
        RegExp(
          r'(^|\s)(after|before|newer|older|newer_than|older_than):',
          caseSensitive: false,
        ).hasMatch(query)) {
      throw const GatewayError('query_scope_denied');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'agentId': agentId,
    'pairingEpoch': pairingEpoch,
    'query': query,
    'purpose': purpose,
    'fields': fields.toList()..sort(),
    'since': since.toUtc().toIso8601String(),
    'until': until.toUtc().toIso8601String(),
    'maxResults': maxResults,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
  factory GmailRequest.fromJson(Map<String, dynamic> j) => GmailRequest(
    id: j['id'],
    agentId: j['agentId'],
    pairingEpoch: j['pairingEpoch'],
    query: j['query'],
    purpose: j['purpose'],
    fields: Set<String>.from(j['fields']),
    since: DateTime.parse(j['since']),
    until: DateTime.parse(j['until']),
    maxResults: j['maxResults'],
    issuedAt: DateTime.parse(j['issuedAt']),
    expiresAt: DateTime.parse(j['expiresAt']),
  );
  String get digest =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
  String get ruleScope {
    final scope = toJson()
      ..remove('id')
      ..remove('issuedAt')
      ..remove('expiresAt');
    return sha256.convert(utf8.encode(jsonEncode(scope))).toString();
  }
}
