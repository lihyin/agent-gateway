import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/gateway_error.dart';
import '../domain/gmail_request.dart';
import 'gmail_auth.dart';

class GmailRecord {
  const GmailRecord({
    required this.id,
    required this.date,
    required this.from,
    required this.subject,
    required this.snippet,
  });
  final String id, from, subject, snippet;
  final DateTime date;
}

abstract interface class GmailSource {
  Future<List<GmailRecord>> search(
    GmailRequest request,
    Future<void> Function() revalidate,
  );
}

class GmailConnector implements GmailSource {
  GmailConnector(this.session, {http.Client? client})
    : _client = client ?? http.Client();
  final GmailSession session;
  final http.Client _client;
  Future<Map<String, dynamic>> _get(
    Uri uri,
    Future<void> Function() revalidate,
  ) async {
    await revalidate();
    final generation = session.generation;
    final token = await session.accessToken();
    await revalidate();
    if (session.generation != generation) {
      throw const GatewayError('gmail_disconnected');
    }
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Accept'] = 'application/json';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(
          const Duration(seconds: 15),
        );
        throw const GatewayError('gmail_fetch_failed');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 131072) {
          throw const GatewayError('gmail_response_too_large');
        }
      }
      await revalidate();
      if (session.generation != generation) {
        throw const GatewayError('gmail_disconnected');
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on GatewayError {
      rethrow;
    } catch (_) {
      throw const GatewayError('gmail_fetch_failed');
    }
  }

  @override
  Future<List<GmailRecord>> search(
    GmailRequest request,
    Future<void> Function() revalidate,
  ) async {
    final start = DateTime.now();
    final records = <GmailRecord>[];
    final ids = <String>{};
    String? page;
    for (
      var pages = 0;
      pages < 3 && records.length < request.maxResults;
      pages++
    ) {
      if (DateTime.now().difference(start) > const Duration(seconds: 45)) {
        throw const GatewayError('gmail_timeout');
      }
      final listed = await _get(
        Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/messages', {
          'q':
              '(${request.query}) after:${request.since.millisecondsSinceEpoch ~/ 1000} before:${request.until.millisecondsSinceEpoch ~/ 1000}',
          'maxResults': '${request.maxResults - records.length}',
          'includeSpamTrash': 'false',
          'fields': 'messages(id),nextPageToken',
          'pageToken': ?page,
        }),
        revalidate,
      );
      final messages = listed['messages'] as List? ?? [];
      if (messages.length > 10) {
        throw const GatewayError('gmail_response_too_large');
      }
      for (final item in messages) {
        if (records.length >= request.maxResults) break;
        final id = (item as Map)['id'] as String;
        if (!RegExp(r'^[a-fA-F0-9]{1,64}$').hasMatch(id)) {
          throw const GatewayError('gmail_invalid_resource');
        }
        if (!ids.add(id)) continue;
        final detail = await _get(
          Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/messages/$id', {
            'format': 'metadata',
            'metadataHeaders': ['From', 'Subject'],
            'fields': 'id,internalDate,snippet,payload/headers',
          }),
          revalidate,
        );
        if (detail['id'] != id) {
          throw const GatewayError('gmail_invalid_resource');
        }
        final date = DateTime.fromMillisecondsSinceEpoch(
          int.parse(detail['internalDate'] as String),
          isUtc: true,
        );
        if (date.isBefore(request.since) || !date.isBefore(request.until)) {
          continue;
        }
        final headers = (detail['payload'] as Map?)?['headers'] as List? ?? [];
        String header(String name) {
          for (final h in headers) {
            if ((h['name'] as String).toLowerCase() == name) {
              return h['value'] as String;
            }
          }
          return '';
        }

        String bounded(String text, int max) =>
            text.length <= max ? text : text.substring(0, max);
        records.add(
          GmailRecord(
            id: id,
            date: date,
            from: bounded(header('from'), 512),
            subject: bounded(header('subject'), 512),
            snippet: bounded(detail['snippet'] as String? ?? '', 1024),
          ),
        );
      }
      page = listed['nextPageToken'] as String?;
      if (page == null) break;
    }
    return records;
  }
}
