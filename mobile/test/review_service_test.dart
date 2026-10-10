import 'package:flutter_test/flutter_test.dart';
import 'package:agentgateway/approvals/review_service.dart';
import 'package:agentgateway/domain/gmail_request.dart';

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late MemoryVault vault;
  late FakeSource source;
  late FakeConfirmation confirmation;
  late ReviewService service;
  String? epoch;
  GmailRequest request({
    String id = 'request-1',
    String agent = 'agent',
    String pairing = 'epoch',
    String query = 'subject:invoice',
    String purpose = 'Find receipt',
    Set<String> fields = const {'subject'},
    int max = 5,
    DateTime? since,
    DateTime? until,
    DateTime? issued,
    DateTime? expires,
  }) => GmailRequest(
    id: id,
    agentId: agent,
    pairingEpoch: pairing,
    query: query,
    purpose: purpose,
    fields: fields,
    since: since ?? now.subtract(const Duration(days: 7)),
    until: until ?? now,
    maxResults: max,
    issuedAt: issued ?? now,
    expiresAt: expires ?? now.add(const Duration(minutes: 5)),
  );
  setUp(() async {
    now = DateTime.utc(2026, 10, 10, 12);
    epoch = 'epoch';
    vault = MemoryVault();
    source = FakeSource(() => now);
    confirmation = FakeConfirmation();
    service = ReviewService(
      vault: vault,
      source: source,
      confirmation: confirmation,
      currentEpoch: (agent) => agent == 'agent' ? epoch : null,
      clock: () => now,
    );
    await service.initialize();
  });
  Future<ReviewEntry> candidate(GmailRequest r) async {
    final e = await service.begin(r);
    return service.approveAccess(r.id, e.revision);
  }

  test(
    'access denial never fetches and final denial has no candidate',
    () async {
      var e = await service.begin(request());
      expect(source.fetches, 0);
      e = await service.denyAccess(e.request.id, e.revision);
      expect(e.state, ReviewState.denied);
      expect(source.fetches, 0);
      e = await candidate(request(id: 'second'));
      expect(e.candidate.single.keys, {'subject'});
      expect(e.candidate.single['subject'], 'Invoice for [redacted]');
      e = await service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.deny,
      );
      expect(e.candidate, isEmpty);
      expect(e.state, ReviewState.denied);
    },
  );
  test(
    'allow once is bound to revision and digest; duplicate decisions fail',
    () async {
      final e = await candidate(request());
      await expectLater(
        service.decide(
          e.request.id,
          e.revision,
          'different',
          ReviewAction.allow,
        ),
        throwsA(anything),
      );
      final allowed = await service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.allow,
      );
      expect(allowed.state, ReviewState.allowed);
      await expectLater(
        service.decide(
          e.request.id,
          e.revision,
          e.candidateDigest,
          ReviewAction.allow,
        ),
        throwsA(anything),
      );
    },
  );
  test('expiry and pairing revocation after fetch reject decisions', () async {
    final e = await candidate(request());
    now = now.add(const Duration(minutes: 5));
    await expectLater(
      service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.allow,
      ),
      throwsA(anything),
    );
    now = now.subtract(const Duration(minutes: 5));
    epoch = null;
    await expectLater(
      service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.allow,
      ),
      throwsA(anything),
    );
  });
  test(
    'expiry during retrieval never produces a disclosure candidate',
    () async {
      source.duringFetch = () async {
        now = now.add(const Duration(minutes: 5));
      };
      final e = await service.begin(request());
      await expectLater(
        service.approveAccess(e.request.id, e.revision),
        throwsA(anything),
      );
      expect((await service.entries()).single.candidate, isEmpty);
    },
  );
  test('revocation during retrieval fails closed', () async {
    source.duringFetch = () async {
      epoch = null;
    };
    final e = await service.begin(request());
    await expectLater(
      service.approveAccess(e.request.id, e.revision),
      throwsA(anything),
    );
    expect((await service.entries()).single.candidate, isEmpty);
  });
  test(
    'persistent replay rejects changed content and never repeats retrieval',
    () async {
      final e = await candidate(request());
      service = ReviewService(
        vault: vault,
        source: source,
        confirmation: confirmation,
        currentEpoch: (_) => epoch,
        clock: () => now,
      );
      await service.initialize();
      expect(
        (await service.begin(request())).candidateDigest,
        e.candidateDigest,
      );
      expect(source.fetches, 1);
      await expectLater(
        service.begin(request(query: 'different')),
        throwsA(anything),
      );
      await expectLater(
        service.approveAccess(e.request.id, 0),
        throwsA(anything),
      );
    },
  );
  test(
    'interrupted retrieval after restart is failed, never repeated',
    () async {
      final r = request();
      vault.values['review.state'] = {
        'version': 1,
        'data': null,
        'entries': [
          ReviewEntry(
            request: r,
            state: ReviewState.fetching,
            revision: 1,
          ).toJson(),
        ],
        'rules': [],
        'audit': [],
      };
      await service.initialize();
      expect((await service.entries()).single.state, ReviewState.failed);
      await expectLater(service.approveAccess(r.id, 0), throwsA(anything));
      expect(source.fetches, 0);
    },
  );
  test('safe edits shorten text; fields and values cannot widen', () async {
    var e = await candidate(request());
    await expectLater(
      service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.edit,
        edited: [
          {'subject': 'Invoice', 'body': 'private'},
        ],
      ),
      throwsA(anything),
    );
    await expectLater(
      service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.edit,
        edited: [
          {'subject': 'Some unrelated new content'},
        ],
      ),
      throwsA(anything),
    );
    e = await service.decide(
      e.request.id,
      e.revision,
      e.candidateDigest,
      ReviewAction.edit,
      edited: [
        {'subject': 'Invoice'},
      ],
    );
    expect(e.candidate.single['subject'], 'Invoice');
  });
  test(
    'Always is exact scope and revocable, never grants source access',
    () async {
      var e = await candidate(request());
      await service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.always,
      );
      e = await service.begin(request(id: 'same-scope'));
      expect(e.state, ReviewState.access);
      e = await service.approveAccess(e.request.id, e.revision);
      expect(e.state, ReviewState.allowed);
      e = await candidate(request(id: 'broader', query: 'other'));
      expect(e.state, ReviewState.disclosure);
      await service.revokeRule((await service.rules()).single['scope']);
      e = await candidate(request(id: 'after-revoke'));
      expect(e.state, ReviewState.disclosure);
    },
  );
  test('high risk requires authentication for access and final approval; Always denied', () async {
    var e = await service.begin(request(fields: {'snippet'}));
    confirmation.allowed = false;
    await expectLater(
      service.approveAccess(e.request.id, e.revision),
      throwsA(anything),
    );
    expect(source.fetches, 0);
    confirmation.allowed = true;
    e = await service.approveAccess(e.request.id, e.revision);
    expect(e.candidate.single['snippet'], isNot(contains('555')));
    await expectLater(
      service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.always,
      ),
      throwsA(anything),
    );
    confirmation.allowed = false;
    await expectLater(
      service.decide(
        e.request.id,
        e.revision,
        e.candidateDigest,
        ReviewAction.allow,
      ),
      throwsA(anything),
    );
  });
  test(
    'cancel during retrieval prevents candidate and clears local rules',
    () async {
      source.duringFetch = service.cancelAll;
      final e = await service.begin(request());
      await expectLater(
        service.approveAccess(e.request.id, e.revision),
        throwsA(anything),
      );
      expect(await service.entries(), isEmpty);
    },
  );
  test(
    'audit contains only metadata, no query, tokens, or mail content',
    () async {
      await candidate(request());
      final text = (await service.audit()).toString();
      expect(text, isNot(contains('invoice')));
      expect(text, isNot(contains('example.com')));
      expect(text, isNot(contains('token')));
    },
  );
  test('unavailable or unknown-version vault cannot initialize', () async {
    vault.fail = true;
    await expectLater(service.initialize(), throwsA(anything));
    vault.fail = false;
    vault.values['review.state'] = {'version': 99};
    await expectLater(service.initialize(), throwsA(anything));
  });
  test(
    'failed replay reservation disables transitions until successful reload',
    () async {
      final r = request();
      vault.fail = true;
      await expectLater(service.begin(r), throwsA(anything));
      vault.fail = false;
      await expectLater(service.approveAccess(r.id, 0), throwsA(anything));
      expect(source.fetches, 0);
      await service.initialize();
      expect(await service.entries(), isEmpty);
    },
  );
  final invalid = <String, GmailRequest Function()>{
    'unknown agent': () => request(agent: 'stranger'),
    'wrong epoch': () => request(pairing: 'other'),
    'empty query': () => request(query: ''),
    'blank query': () => request(query: '   '),
    'wildcard': () => request(query: '*'),
    'date override': () => request(query: 'before:2026/01/01'),
    'missing purpose': () => request(purpose: ''),
    'blank purpose': () => request(purpose: ' '),
    'unknown field': () => request(fields: {'body'}),
    'empty fields': () => request(fields: {}),
    'zero limit': () => request(max: 0),
    'excess limit': () => request(max: 11),
    'future issued': () => request(issued: now.add(const Duration(seconds: 1))),
    'expired': () => request(expires: now),
    'overlong ttl': () => request(expires: now.add(const Duration(minutes: 6))),
    'inverted ttl': () =>
        request(expires: now.subtract(const Duration(seconds: 1))),
    'zero window': () => request(since: now),
    'inverted window': () => request(since: now.add(const Duration(days: 1))),
    'wide window': () => request(since: now.subtract(const Duration(days: 31))),
    'future until': () => request(until: now.add(const Duration(days: 1))),
    'long query': () => request(query: 'x' * 201),
    'long purpose': () => request(purpose: 'x' * 201),
  };
  for (final value in invalid.entries) {
    test('policy denies ${value.key} before source access', () async {
      await expectLater(service.begin(value.value()), throwsA(anything));
      expect(source.fetches, 0);
    });
  }
}
