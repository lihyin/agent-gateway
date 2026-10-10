import '../connectors/gmail_connector.dart';
import '../domain/gmail_request.dart';

class PrivacyFilter {
  static final _patterns = <RegExp>[
    RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false),
    RegExp(r'(?<!\w)(?:\+?\d[\d ()-]{7,}\d)(?!\w)'),
    RegExp(r'\b\d{3}-\d{2}-\d{4}\b'),
    RegExp(r'\b(?:[A-Z]{2}\d{2})(?:[ ]?[A-Z0-9]){11,30}\b'),
    RegExp(
      r'\b(?:ssn|account|patient|medical record|mrn|diagnosis)\s*[:#=]\s*[^\n,;]+',
      caseSensitive: false,
    ),
  ];
  String redact(String text) {
    for (final pattern in _patterns) {
      text = text.replaceAll(pattern, '[redacted]');
    }
    return text;
  }

  Map<String, dynamic> filter(Map<String, dynamic> value) => value.map(
    (key, value) =>
        MapEntry(key, value is String && key != 'id' ? redact(value) : value),
  );
  List<Map<String, dynamic>> minimize(
    GmailRequest request,
    List<GmailRecord> records,
  ) => records
      .where(
        (r) =>
            !r.date.isBefore(request.since) && r.date.isBefore(request.until),
      )
      .take(request.maxResults)
      .map(
        (record) => filter({
          if (request.fields.contains('id')) 'id': record.id,
          if (request.fields.contains('date'))
            'date': record.date.millisecondsSinceEpoch ~/ 1000,
          if (request.fields.contains('from')) 'from': record.from,
          if (request.fields.contains('subject')) 'subject': record.subject,
          if (request.fields.contains('snippet')) 'snippet': record.snippet,
        }),
      )
      .toList();
}
