import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agentgateway/domain/gateway_error.dart';
import 'package:agentgateway/transport/crypto.dart';
import 'package:agentgateway/transport/paired_delivery.dart';
import 'package:agentgateway/transport/pin_pairing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _PairingSocket extends Stream<dynamic> implements WebSocket {
  final incoming = StreamController<dynamic>();
  final sent = StreamController<dynamic>();
  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void add(dynamic data) => sent.add(data);
  @override
  Future<void> close([int? code, String? reason]) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CompletionExchange extends PinExchange {
  _CompletionExchange(this.offer) : super('https://relay.example.com');
  final String offer;
  final completing = Completer<void>();
  final finish = Completer<void>();
  @override
  void authenticate(Map<String, dynamic> proof) {}
  @override
  String seal(String kind, [Map<String, dynamic> data = const {}]) => kind;
  @override
  Future<Map<String, dynamic>> open(String compact, String kind) async {
    if (kind == 'complete') {
      completing.complete();
      await finish.future;
    }
    return {'offer': offer};
  }
}

void main() {
  for (final completes in [true, false]) {
    test('socket close drains final frame; completes=$completes', () async {
      final fixture = jsonDecode(
        File('../protocol/fixtures/pairing.json').readAsStringSync(),
      );
      final delivery = PairedDelivery(
        vault: MemoryVault(),
        confirmation: FakeConfirmation(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        keyGenerator: () async => Map<String, dynamic>.from(fixture['device']),
      );
      await delivery.initialize();
      final socket = _PairingSocket();
      final exchange = _CompletionExchange(fixture['offer']);
      final finished = Completer<void>();
      late PinPairing pairing;
      pairing = PinPairing(
        exchange,
        delivery,
        connect: (_) async => socket,
        confirm: () async => true,
        changed: () {
          if (['paired', 'failed'].contains(pairing.status) &&
              !finished.isCompleted) {
            finished.complete();
          }
        },
      );
      addTearDown(pairing.close);
      final outgoing = StreamIterator(socket.sent.stream);
      addTearDown(outgoing.cancel);
      await pairing.start();
      socket.incoming.add(jsonEncode({'kind': 'joined'}));
      await outgoing.moveNext(); // challenge
      socket.incoming.add('{}');
      await outgoing.moveNext(); // ready
      socket.incoming.add(jsonEncode({'jwe': 'offer'}));
      await outgoing.moveNext(); // receipt
      if (completes) {
        socket.incoming.add(jsonEncode({'jwe': 'complete'}));
        await exchange.completing.future;
      }
      await socket.incoming.close();
      await Future<void>.delayed(Duration.zero);
      if (completes) {
        expect(pairing.status, 'finishing');
        exchange.finish.complete();
      }
      await finished.future.timeout(const Duration(seconds: 5));
      expect(pairing.status, completes ? 'paired' : 'failed');
      expect(pairing.error, completes ? isNull : 'pairing_interrupted');
      expect(delivery.pairingConfirmed, completes);
    });
  }

  test('pairing WebSocket upgrade works and rejects redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var redirected = false;
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/target');
        await request.response.close();
      } else if (request.uri.path == '/target') {
        redirected = true;
        await request.response.close();
      } else {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((data) => socket.add(data));
      }
    });
    addTearDown(() => server.close(force: true));
    final origin = 'ws://127.0.0.1:${server.port}';
    await expectLater(
      connectPairingSocket(Uri.parse('$origin/redirect')),
      throwsA(isA<GatewayError>()),
    );
    expect(redirected, isFalse);
    final socket = await connectPairingSocket(Uri.parse('$origin/open'));
    socket.add('test');
    expect(await socket.first.timeout(const Duration(seconds: 5)), 'test');
    await socket.close();
  });
  test(
    'random codes/session addresses expire, cancel and cannot be used twice',
    () {
      var now = DateTime.now();
      final exchange = PinExchange(
        'https://relay.example.com',
        clock: () => now,
      );
      final other = PinExchange('https://relay.example.com');
      expect(exchange.code, matches(RegExp(r'^\d{8}$')));
      expect(exchange.session, hasLength(64));
      expect(exchange.session, isNot(other.session));
      expect(exchange.challenge.containsKey('code'), isFalse);
      expect(exchange.challenge.containsKey('verifier'), isFalse);
      expect(exchange.expiresAt, now.millisecondsSinceEpoch ~/ 1000 + 1800);
      now = now.add(const Duration(minutes: 29, seconds: 59));
      exchange.check();
      now = now.add(const Duration(seconds: 1));
      expect(exchange.check, throwsA(isA<GatewayError>()));
      other.close();
      expect(other.check, throwsA(isA<GatewayError>()));
      expect(
        () => PinExchange('http://relay.example.com'),
        throwsA(isA<GatewayError>()),
      );
    },
  );

  for (final wrongCode in [false, true]) {
    test(
      'Dart phone and Node Muse perform real SRP and signed pairing; wrongCode=$wrongCode',
      () async {
        final exchange = PinExchange('https://relay.example.com');
        final process = await Process.start(
          Platform.environment['AGW_TEST_NODE'] ?? 'node',
          ['--import', 'tsx', 'scripts/pin-pairing-peer.mjs'],
          workingDirectory: '..',
        );
        final errors = process.stderr.transform(utf8.decoder).join();
        final lines = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        addTearDown(() async {
          exchange.close();
          process.kill();
          await lines.cancel();
        });
        void send(Map<String, dynamic> value) =>
            process.stdin.writeln(jsonEncode(value));
        Future<Map<String, dynamic>> read() async {
          if (!await lines.moveNext().timeout(const Duration(seconds: 20))) {
            fail('Node peer ended: ${await errors}');
          }
          return Map<String, dynamic>.from(jsonDecode(lines.current));
        }

        send({
          'line': exchange.setupLine,
          'challenge': exchange.challenge,
          'wrongCode': wrongCode,
        });
        final proof = await read();
        if (wrongCode) {
          expect(
            () => exchange.authenticate(proof),
            throwsA(isA<GatewayError>()),
          );
          expect(
            () => exchange.authenticate(proof),
            throwsA(isA<GatewayError>()),
          );
          expect(() => exchange.seal('ready'), throwsA(isA<GatewayError>()));
          return;
        }
        exchange.authenticate(proof);
        expect(
          () => exchange.authenticate(proof),
          throwsA(isA<GatewayError>()),
        );
        send({'jwe': exchange.seal('ready')});
        final offerFrame = await read();
        final offer = await exchange.open(offerFrame['jwe'], 'offer');
        await expectLater(
          exchange.open(offerFrame['jwe'], 'receipt'),
          throwsA(isA<GatewayError>()),
        );
        final f = jsonDecode(
          File('../protocol/fixtures/pairing.json').readAsStringSync(),
        );
        final confirmation = FakeConfirmation();
        final delivery = PairedDelivery(
          vault: MemoryVault(),
          confirmation: confirmation,
          keyGenerator: () async => Map<String, dynamic>.from(f['device']),
        );
        await delivery.initialize();
        final compact = offer['offer'] as String;
        final public = jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(compact.split('.')[1])),
          ),
        )['identity'];
        final receipt = await delivery.pair(compact, hash(public));
        expect(delivery.agentId, isNotNull);
        send({
          'jwe': exchange.seal('receipt', {
            'receipt': receipt,
            'fingerprint': delivery.deviceFingerprint,
          }),
        });
        final complete = await read();
        await exchange.open(complete['jwe'], 'complete');
        expect(complete['paired'], isTrue);
        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: await errors,
        );
      },
    );
  }
}
