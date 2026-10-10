import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../connectors/gmail_connector.dart';
import '../domain/gateway_error.dart';
import '../domain/gmail_request.dart';
import '../privacy/minimizer.dart';
import '../vault/vault.dart';
import 'local_confirmation.dart';

enum ReviewState {
  access,
  fetching,
  disclosure,
  allowed,
  denied,
  expired,
  failed,
}

enum ReviewAction { allow, deny, edit, always }

class ReviewEntry {
  ReviewEntry({
    required this.request,
    required this.state,
    List<Map<String, dynamic>> candidate = const [],
    this.revision = 0,
  }) : candidate = List.unmodifiable(
         candidate.map((m) => Map<String, dynamic>.unmodifiable(m)),
       );
  final GmailRequest request;
  final ReviewState state;
  final List<Map<String, dynamic>> candidate;
  final int revision;
  String get candidateDigest =>
      sha256.convert(utf8.encode(jsonEncode(candidate))).toString();
  Map<String, dynamic> toJson() => {
    'request': request.toJson(),
    'state': state.name,
    'candidate': candidate,
    'revision': revision,
  };
  factory ReviewEntry.fromJson(Map<String, dynamic> j) => ReviewEntry(
    request: GmailRequest.fromJson(j['request']),
    state: ReviewState.values.byName(j['state']),
    candidate: (j['candidate'] as List)
        .map((m) => Map<String, dynamic>.from(m))
        .toList(),
    revision: j['revision'],
  );
}

class ReviewService {
  ReviewService({
    required this.vault,
    required this.source,
    required this.confirmation,
    required this.currentEpoch,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final Vault vault;
  final GmailSource source;
  final LocalConfirmation confirmation;
  // Only a trusted pairing service may supply this resolver. The shipped UI uses
  // a device-owner preview identity; no network agent is accepted.
  final String? Function(String agentId) currentEpoch;
  final DateTime Function() clock;
  final _serial = SerialExecutor();
  final _privacy = PrivacyFilter();
  Map<String, ReviewEntry> _entries = {};
  List<Map<String, dynamic>> _rules = [];
  List<Map<String, dynamic>> _audit = [];
  bool _ready = false;
  int _generation = 0;

  Future<void> initialize() => _serial.run(() async {
    _ready = false;
    _entries = {};
    _rules = [];
    _audit = [];
    final saved = await vault.read('review.state');
    if (saved != null) {
      try {
        if (saved['version'] != 1) throw const GatewayError('review_version');
        _entries = {
          for (final value in saved['entries'] as List)
            (value['request']['id'] as String): ReviewEntry.fromJson(
              Map<String, dynamic>.from(value),
            ),
        };
        _rules = (saved['rules'] as List)
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        _audit = (saved['audit'] as List)
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      } catch (_) {
        throw const GatewayError('review_state_invalid');
      }
    }
    // Never repeat interrupted retrieval after process termination.
    _entries = _entries.map(
      (id, e) => MapEntry(
        id,
        e.state == ReviewState.fetching
            ? ReviewEntry(
                request: e.request,
                state: ReviewState.failed,
                revision: e.revision + 1,
              )
            : e,
      ),
    );
    _ready = true;
    _cleanup();
    await _save();
  });
  void _check(GmailRequest request) {
    if (!_ready) throw const GatewayError('review_unavailable');
    request.validate(clock());
    if (currentEpoch(request.agentId) != request.pairingEpoch) {
      throw const GatewayError('unpaired');
    }
  }

  void _cleanup() {
    final now = clock();
    _entries.removeWhere(
      (_, e) => now.difference(e.request.expiresAt) > const Duration(hours: 24),
    );
    _entries = _entries.map(
      (id, e) => MapEntry(
        id,
        !e.request.expiresAt.isAfter(now)
            ? ReviewEntry(
                request: e.request,
                state: ReviewState.expired,
                revision: e.revision + 1,
              )
            : e,
      ),
    );
    _rules.removeWhere((r) => DateTime.parse(r['expiresAt']).isBefore(now));
    _audit.removeWhere(
      (a) => now.difference(DateTime.parse(a['at'])) > const Duration(days: 7),
    );
    if (_audit.length > 100) _audit = _audit.sublist(_audit.length - 100);
  }

  Future<void> _save() async {
    if (!_ready) throw const GatewayError('review_unavailable');
    try {
      await vault.write('review.state', {
        'version': 1,
        'entries': _entries.values.map((e) => e.toJson()).toList(),
        'rules': _rules,
        'audit': _audit,
      });
    } catch (_) {
      _ready = false;
      throw const GatewayError('vault_unavailable');
    }
  }

  void _record(ReviewEntry e, String event) {
    _audit.add({
      'id': e.request.id,
      'agent': e.request.agentId,
      'event': event,
      'at': clock().toUtc().toIso8601String(),
      'count': e.candidate.length,
    });
    if (_audit.length > 100) _audit.removeAt(0);
  }

  Future<List<ReviewEntry>> entries() => _serial.run(() async {
    if (!_ready) throw const GatewayError('review_unavailable');
    _cleanup();
    await _save();
    return List.unmodifiable(_entries.values);
  });
  Future<List<Map<String, dynamic>>> rules() => _serial.run(() async {
    _cleanup();
    await _save();
    return List.unmodifiable(
      _rules.map((r) => Map<String, dynamic>.unmodifiable(r)),
    );
  });
  Future<List<Map<String, dynamic>>> audit() => _serial.run(
    () async => List.unmodifiable(
      _audit.map((a) => Map<String, dynamic>.unmodifiable(a)),
    ),
  );
  Future<ReviewEntry> begin(GmailRequest request) => _serial.run(() async {
    _check(request);
    _cleanup();
    final existing = _entries[request.id];
    if (existing != null) {
      if (existing.request.digest != request.digest) {
        throw const GatewayError('replay_changed_content');
      }
      return existing;
    }
    if (_entries.length >= 20) throw const GatewayError('review_capacity');
    final entry = ReviewEntry(request: request, state: ReviewState.access);
    _entries[request.id] = entry;
    _record(entry, 'access_requested');
    await _save();
    return entry;
  });
  ReviewEntry _pending(String id, ReviewState state, int revision) {
    final entry = _entries[id];
    if (entry == null || entry.state != state || entry.revision != revision) {
      throw const GatewayError('stale_review');
    }
    _check(entry.request);
    return entry;
  }

  Future<ReviewEntry> approveAccess(String id, int revision) async {
    final captured = await _serial.run(
      () async => _pending(id, ReviewState.access, revision),
    );
    final generation = _generation;
    if (captured.request.highRisk &&
        !await confirmation.confirm(
          'Confirm access to Gmail sender or snippet data',
        )) {
      throw const GatewayError('local_confirmation_required');
    }
    await _serial.run(() async {
      _pending(id, ReviewState.access, revision);
      if (generation != _generation) {
        throw const GatewayError('review_cancelled');
      }
      _entries[id] = ReviewEntry(
        request: captured.request,
        state: ReviewState.fetching,
        revision: revision + 1,
      );
      _record(_entries[id]!, 'access_allowed');
      await _save();
    });
    Future<void> revalidate() => _serial.run(() async {
      _pending(id, ReviewState.fetching, revision + 1);
      if (generation != _generation) {
        throw const GatewayError('review_cancelled');
      }
    });
    try {
      final records = await source
          .search(captured.request, revalidate)
          .timeout(const Duration(seconds: 60));
      return await _serial.run(() async {
        _pending(id, ReviewState.fetching, revision + 1);
        if (generation != _generation) {
          throw const GatewayError('review_cancelled');
        }
        final candidate = _privacy.minimize(captured.request, records);
        final always =
            !captured.request.highRisk &&
            _rules.any(
              (r) =>
                  r['scope'] == captured.request.ruleScope &&
                  DateTime.parse(r['expiresAt']).isAfter(clock()),
            );
        final entry = ReviewEntry(
          request: captured.request,
          state: always ? ReviewState.allowed : ReviewState.disclosure,
          candidate: candidate,
          revision: revision + 2,
        );
        _entries[id] = entry;
        _record(entry, always ? 'rule_allowed' : 'disclosure_requested');
        await _save();
        return entry;
      });
    } catch (_) {
      await _serial.run(() async {
        final current = _entries[id];
        if (current?.state == ReviewState.fetching) {
          final entry = ReviewEntry(
            request: captured.request,
            state: ReviewState.failed,
            revision: revision + 2,
          );
          _entries[id] = entry;
          _record(entry, 'retrieval_failed');
          await _save();
        }
      });
      throw const GatewayError('gmail_retrieval_failed');
    }
  }

  Future<ReviewEntry> decide(
    String id,
    int revision,
    String digest,
    ReviewAction action, {
    List<Map<String, dynamic>>? edited,
  }) async {
    final captured = await _serial.run(
      () async => _pending(id, ReviewState.disclosure, revision),
    );
    final generation = _generation;
    if (captured.candidateDigest != digest) {
      throw const GatewayError('candidate_changed');
    }
    if (action == ReviewAction.always && captured.request.highRisk) {
      throw const GatewayError('high_risk_rule_denied');
    }
    if (action != ReviewAction.deny &&
        captured.request.highRisk &&
        !await confirmation.confirm('Confirm this Gmail disclosure preview')) {
      throw const GatewayError('local_confirmation_required');
    }
    return _serial.run(() async {
      final current = _pending(id, ReviewState.disclosure, revision);
      if (generation != _generation || current.candidateDigest != digest) {
        throw const GatewayError('candidate_changed');
      }
      var candidate = current.candidate;
      if (action == ReviewAction.edit) {
        if (edited == null || edited.length > candidate.length) {
          throw const GatewayError('edit_scope_denied');
        }
        for (var i = 0; i < edited.length; i++) {
          final original = candidate[i];
          for (final field in edited[i].entries) {
            if (!original.containsKey(field.key)) {
              throw const GatewayError('edit_scope_denied');
            }
            final before = original[field.key];
            final after = field.value;
            if (before is String && after is String && field.key != 'id') {
              if (after.length > before.length ||
                  !(before.contains(after) || after == '[redacted]')) {
                throw const GatewayError('edit_scope_denied');
              }
            } else if (before != after) {
              throw const GatewayError('edit_scope_denied');
            }
          }
        }
        candidate = edited.map(_privacy.filter).toList();
      }
      if (action == ReviewAction.always) {
        _rules.removeWhere((r) => r['scope'] == current.request.ruleScope);
        if (_rules.length >= 20) throw const GatewayError('rule_capacity');
        _rules.add({
          'scope': current.request.ruleScope,
          'agent': current.request.agentId,
          'epoch': current.request.pairingEpoch,
          'expiresAt': clock()
              .add(const Duration(hours: 24))
              .toUtc()
              .toIso8601String(),
        });
      }
      final entry = ReviewEntry(
        request: current.request,
        state: action == ReviewAction.deny
            ? ReviewState.denied
            : ReviewState.allowed,
        candidate: action == ReviewAction.deny ? [] : candidate,
        revision: revision + 1,
      );
      _entries[id] = entry;
      _record(entry, action.name);
      await _save();
      return entry;
    });
  }

  Future<ReviewEntry> denyAccess(String id, int revision) =>
      _serial.run(() async {
        final current = _pending(id, ReviewState.access, revision);
        final entry = ReviewEntry(
          request: current.request,
          state: ReviewState.denied,
          revision: revision + 1,
        );
        _entries[id] = entry;
        _record(entry, 'access_denied');
        await _save();
        return entry;
      });
  Future<void> revokeRule(String scope) => _serial.run(() async {
    _rules.removeWhere((r) => r['scope'] == scope);
    await _save();
  });
  Future<void> cancelAll() {
    _generation++;
    return _serial.run(() async {
      _entries = {};
      _rules = [];
      _audit = [];
      await vault.delete('review.state');
    });
  }
}
