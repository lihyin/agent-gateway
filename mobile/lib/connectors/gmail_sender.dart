import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../approvals/local_confirmation.dart';
import '../domain/gateway_error.dart';
import 'gmail_auth.dart';

bool validEmailAddress(String value) {
  if (value.length > 254 || value.contains(RegExp(r'[\x00-\x20\x7f]'))) {
    return false;
  }
  final parts = value.split('@');
  return parts.length == 2 &&
      parts.first.length <= 64 &&
      !parts.first.startsWith('.') &&
      !parts.first.endsWith('.') &&
      !parts.first.contains('..') &&
      RegExp(r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$").hasMatch(parts.first) &&
      parts.last.split('.').length >= 2 &&
      parts.last
          .split('.')
          .every(
            (label) =>
                RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')
                    .hasMatch(label),
          );
}

class GmailSendAccount {
  const GmailSendAccount(this.address, this.generation);
  final String address;
  final int generation;
}

class OutgoingEmail {
  OutgoingEmail({
    required this.account,
    required List<String> to,
    List<String> cc = const [],
    List<String> bcc = const [],
    required this.subject,
    required this.body,
    DateTime? now,
  }) : to = List.unmodifiable(to),
       cc = List.unmodifiable(cc),
       bcc = List.unmodifiable(bcc),
       createdAt = now ?? DateTime.now(),
       id = List.generate(
         16,
         (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
       ).join();
  final GmailSendAccount account;
  final List<String> to, cc, bcc;
  final String subject, body, id;
  final DateTime createdAt;

  void validate(DateTime now) {
    final recipients = [...to, ...cc, ...bcc];
    if (!validEmailAddress(account.address) ||
        to.isEmpty ||
        recipients.length > 20 ||
        recipients.any((email) => !validEmailAddress(email)) ||
        subject.trim().isEmpty ||
        subject.runes.length > 200 ||
        subject.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        body.trim().isEmpty ||
        utf8.encode(body).length > 65536) {
      throw const GatewayError('gmail_invalid_message');
    }
    if (now.isBefore(createdAt) ||
        now.difference(createdAt) >= const Duration(minutes: 5)) {
      throw const GatewayError('gmail_send_expired');
    }
  }

  String get raw {
    // Keep encoded words within RFC 2047's limit, without splitting UTF-8 runes.
    final words = <String>[];
    var bytes = <int>[];
    for (final rune in subject.runes) {
      final next = utf8.encode(String.fromCharCode(rune));
      if (bytes.length + next.length > 42) {
        words.add('=?UTF-8?B?${base64.encode(bytes)}?=');
        bytes = [];
      }
      bytes.addAll(next);
    }
    if (bytes.isNotEmpty) words.add('=?UTF-8?B?${base64.encode(bytes)}?=');
    final encodedBody = base64.encode(
      utf8.encode(body.replaceAll(RegExp(r'\r\n?|\n'), '\r\n')),
    );
    final bodyLines = <String>[];
    for (var i = 0; i < encodedBody.length; i += 76) {
      bodyLines.add(encodedBody.substring(i, min(i + 76, encodedBody.length)));
    }
    final mime = [
      'From: ${account.address}',
      'To: ${to.join(',\r\n ')}',
      if (cc.isNotEmpty) 'Cc: ${cc.join(',\r\n ')}',
      if (bcc.isNotEmpty) 'Bcc: ${bcc.join(',\r\n ')}',
      'Subject: ${words.join('\r\n ')}',
      'Date: ${HttpDate.format(createdAt.toUtc())}',
      'Message-ID: <$id@gateway.zerobox.ai>',
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      '',
      ...bodyLines,
      '',
    ].join('\r\n');
    return base64Url.encode(utf8.encode(mime)).replaceAll('=', '');
  }
}

class GmailSender {
  GmailSender(
    this.session, {
    required this.confirmation,
    http.Client? client,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       clock = clock ?? DateTime.now;
  final GmailSession session;
  final LocalConfirmation confirmation;
  final http.Client _client;
  final DateTime Function() clock;
  final _attempted = <String>{};
  bool _sending = false;
  GmailSendAccount? _loadedAccount;

  void _checkAccount(GmailSendAccount account) {
    if (session.generation != account.generation) {
      throw const GatewayError('gmail_disconnected');
    }
  }

  Future<Map<String, dynamic>> _response(http.StreamedResponse response) async {
    if ((response.contentLength ?? 0) > 65536) {
      await response.stream.listen(null).cancel();
      throw const FormatException('Oversize response');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) {
        throw const FormatException('Oversize response');
      }
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  Future<GmailSendAccount> loadAccount() async {
    final generation = session.generation;
    final token = await session.accessToken(
      requiredScopes: {gmailReadScope, gmailSendScope},
    );
    final account = GmailSendAccount('', generation);
    _checkAccount(account);
    try {
      final request =
          http.Request(
              'GET',
              Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/profile', {
                'fields': 'emailAddress',
              }),
            )
            ..followRedirects = false
            ..headers['Authorization'] = 'Bearer $token';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw const GatewayError('gmail_profile_failed');
      }
      final profile = await _response(response);
      _checkAccount(account);
      final address = profile['emailAddress'];
      if (address is! String || !validEmailAddress(address)) {
        throw const FormatException('Invalid account');
      }
      return _loadedAccount = GmailSendAccount(address, generation);
    } on GatewayError {
      rethrow;
    } catch (_) {
      throw const GatewayError('gmail_profile_failed');
    }
  }

  Future<String> send(
    OutgoingEmail message, {
    required bool Function() stillAuthorized,
    required Future<void> Function() waitUntilResumed,
  }) async {
    if (_sending) throw const GatewayError('gmail_send_busy');
    if (_attempted.contains(message.id) || _attempted.length >= 1000) {
      throw const GatewayError('gmail_send_already_attempted');
    }
    _sending = true;
    try {
      void check() {
        message.validate(clock());
        _checkAccount(message.account);
        if (_loadedAccount?.address != message.account.address ||
            _loadedAccount?.generation != message.account.generation) {
          throw const GatewayError('gmail_profile_failed');
        }
        if (!stillAuthorized()) {
          throw const GatewayError('gmail_send_cancelled');
        }
      }

      check();
      await session.accessToken(
        requiredScopes: {gmailReadScope, gmailSendScope},
      );
      check();
      if (!await confirmation.confirm(
        'Send this email to the reviewed recipients?',
      )) {
        throw const GatewayError('local_confirmation_required');
      }
      await waitUntilResumed();
      check();
      final token = await session.accessToken(
        requiredScopes: {gmailReadScope, gmailSendScope},
      );
      check();
      final request =
          http.Request(
              'POST',
              Uri.https(
                'gmail.googleapis.com',
                '/gmail/v1/users/me/messages/send',
              ),
            )
            ..followRedirects = false
            ..headers['Authorization'] = 'Bearer $token'
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode({'raw': message.raw});
      // Gmail provides no send idempotency key. Never retry an attempted POST.
      _attempted.add(message.id);
      try {
        final response = await _client
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          if (response.statusCode >= 500) {
            throw const GatewayError('gmail_send_unknown');
          }
          throw const GatewayError('gmail_send_rejected');
        }
        final result = await _response(response);
        final id = result['id'];
        if (id is! String || id.isEmpty || id.length > 128) {
          throw const FormatException('Missing message ID');
        }
        return id;
      } on GatewayError {
        rethrow;
      } catch (_) {
        throw const GatewayError('gmail_send_unknown');
      }
    } finally {
      _sending = false;
    }
  }

  void close() => _client.close();
}
