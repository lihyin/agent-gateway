import 'package:flutter_test/flutter_test.dart';
import 'package:agentgateway/domain/muse_skill.dart';

void main() {
  const origin = 'https://paired-relay.example';
  test('one paste includes pairing and reusable Gmail instructions', () {
    const setup = 'AGW1.private-single-use-code';
    final message = musePairingMessage(origin: origin, setupLine: setup);
    expect(setup.allMatches(message), hasLength(1));
    expect(message, contains('standard input'));
    expect(message, contains('RELAY_URL: $origin'));
    expect(message, contains('SKILL: Agent Gateway Gmail (v1)'));
    expect(message, contains('Delivery route: not supplied yet'));
    expect(message, contains('PAIRING_CONFIG'));
    expect(message, contains('Pending review is not a successful search'));
  });
  test(
    'existing pairing gets usable route configuration without a new code',
    () {
      final message = museGmailSkill(origin: origin, route: 'sealed-route');
      expect(message, contains('RELAY_ROUTE: sealed-route'));
      expect(message, contains('relay-request request.json'));
      expect(message, contains('gateway_request_status'));
      expect(message, isNot(contains('AGW1.')));
      expect(message, isNot(contains('Delivery route: not supplied yet')));
      expect(message, contains('only verified, phone-approved results'));
    },
  );
}
