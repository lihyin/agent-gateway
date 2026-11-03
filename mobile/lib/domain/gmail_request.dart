import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'gateway_error.dart';
import '../connectors/gmail_sender.dart';

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
  factory GmailRequest.fromJson(Map<String, dynamic> j) =>
      j['operation'] == 'send'
      ? GmailSendRequest.fromJson(j)
      : GmailRequest(
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

class GmailSendRequest extends GmailRequest {
  GmailSendRequest({
    required super.id,
    required super.agentId,
    required super.pairingEpoch,
    required super.purpose,
    required super.issuedAt,
    required super.expiresAt,
    required this.from,
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required this.subject,
    required this.body,
  }) : to = List.unmodifiable(to),
       cc = List.unmodifiable(cc),
       bcc = List.unmodifiable(bcc),
       super(
         query: '',
         fields: const {},
         since: issuedAt,
         until: issuedAt,
         maxResults: 0,
       );
  final String from, subject, body;
  final List<String> to, cc, bcc;
  @override
  bool get highRisk => true;
  @override
  void validate(DateTime now) {
    if (id.isEmpty ||
        id.length > 128 ||
        agentId.isEmpty ||
        pairingEpoch.isEmpty ||
        purpose.trim().isEmpty ||
        purpose.length > 200 ||
        issuedAt.isAfter(now) ||
        !expiresAt.isAfter(now) ||
        !expiresAt.isAfter(issuedAt) ||
        expiresAt.difference(issuedAt) > const Duration(minutes: 5)) {
      throw const GatewayError('invalid_or_expired_request');
    }
    message(GmailSendAccount(from, 0)).validate(now);
  }

  OutgoingEmail message(GmailSendAccount account) => OutgoingEmail(
    account: account,
    to: to,
    cc: cc,
    bcc: bcc,
    subject: subject,
    body: body,
    now: issuedAt,
  );
  @override
  Map<String, dynamic> toJson() => {
    'operation': 'send',
    'id': id,
    'agentId': agentId,
    'pairingEpoch': pairingEpoch,
    'purpose': purpose,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'from': from,
    'to': to,
    'cc': cc,
    'bcc': bcc,
    'subject': subject,
    'body': body,
  };
  factory GmailSendRequest.fromJson(Map<String, dynamic> j) => GmailSendRequest(
    id: j['id'],
    agentId: j['agentId'],
    pairingEpoch: j['pairingEpoch'],
    purpose: j['purpose'],
    issuedAt: DateTime.parse(j['issuedAt']),
    expiresAt: DateTime.parse(j['expiresAt']),
    from: j['from'],
    to: List<String>.from(j['to']),
    cc: List<String>.from(j['cc']),
    bcc: List<String>.from(j['bcc']),
    subject: j['subject'],
    body: j['body'],
  );
}
