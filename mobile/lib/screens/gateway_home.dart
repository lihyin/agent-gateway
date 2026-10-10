import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../approvals/review_service.dart';
import '../domain/gateway_configuration.dart';
import 'gateway_controller.dart';

class GatewayHome extends StatefulWidget {
  const GatewayHome({
    super.key,
    required this.configuration,
    required this.controller,
  });
  final GatewayConfiguration configuration;
  final GatewayController controller;
  @override
  State<GatewayHome> createState() => _GatewayHomeState();
}

class _GatewayHomeState extends State<GatewayHome> with WidgetsBindingObserver {
  final _query = TextEditingController(), _purpose = TextEditingController();
  Timer? _expiry;
  bool _sensitive = false, _obscured = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.initialize();
    _expiry = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_obscured && widget.controller.ready && !widget.controller.busy) {
        widget.controller.reload();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      setState(() => _obscured = true);
      widget.controller.obscure();
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _obscured = false);
      if (widget.controller.ready) widget.controller.reload();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _query.dispose();
    _purpose.dispose();
    super.dispose();
  }

  Future<void> _edit(ReviewEntry entry) async {
    final fields = entry.candidate
        .map(
          (item) =>
              TextEditingController(text: item['subject'] as String? ?? ''),
        )
        .toList();
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reduce the disclosure'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Shorten or remove subjects. Edits cannot widen scope.',
              ),
              for (var i = 0; i < fields.length; i++)
                TextField(
                  controller: fields[i],
                  decoration: InputDecoration(labelText: 'Subject ${i + 1}'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve edited preview'),
          ),
        ],
      ),
    );
    if (yes == true) {
      final edited = entry.candidate
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      for (var i = 0; i < fields.length; i++) {
        if (edited[i].containsKey('subject')) {
          edited[i]['subject'] = fields[i].text;
        }
      }
      await widget.controller.decide(entry, ReviewAction.edit, edited: edited);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final field in fields) {
      field.dispose();
    }
  }

  Future<void> _always(ReviewEntry entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save a scoped rule?'),
        content: const Text(
          'For 24 hours, allow this exact query, purpose, fields, date window, and result limit for this device preview. Gmail access still needs consent. Revoke the rule below.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save rule'),
          ),
        ],
      ),
    );
    if (yes == true) await widget.controller.decide(entry, ReviewAction.always);
  }

  Widget _entry(ReviewEntry entry, bool busy) {
    final expired = !entry.request.expiresAt.isAfter(DateTime.now());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Device-owner preview',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text('Purpose: ${entry.request.purpose}'),
            Text('Query: ${entry.request.query}'),
            Text(
              'Fields: ${entry.request.fields.join(', ')} • Up to ${entry.request.maxResults} messages • Last 7 days',
            ),
            Text(
              'Risk: ${entry.request.highRisk ? 'high — device confirmation required' : 'metadata review'}',
            ),
            Text('Expires: ${entry.request.expiresAt.toLocal()}'),
            Text('Status: ${expired ? 'expired' : entry.state.name}'),
            if (!expired && entry.candidate.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Minimized and filtered preview'),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(entry.candidate),
              ),
            ],
            if (!expired && entry.state == ReviewState.access) ...[
              const Text(
                'Allow this bounded Gmail fetch? This does not approve disclosure.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => widget.controller.access(entry, true),
                    child: const Text('Allow Gmail access'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => widget.controller.access(entry, false),
                    child: const Text('Deny'),
                  ),
                ],
              ),
            ],
            if (!expired && entry.state == ReviewState.disclosure)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => widget.controller.decide(
                            entry,
                            ReviewAction.allow,
                          ),
                    child: const Text('Allow once'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => widget.controller.decide(
                            entry,
                            ReviewAction.deny,
                          ),
                    child: const Text('Deny'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => _edit(entry),
                    child: const Text('Edit'),
                  ),
                  TextButton(
                    onPressed: busy || entry.request.highRisk
                        ? null
                        : () => _always(entry),
                    child: const Text('Always (24 hours)'),
                  ),
                ],
              ),
            if (entry.state == ReviewState.allowed && !expired)
              const Text(
                'Approved locally. No data has been transmitted to an agent.',
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, child) {
      final c = widget.controller;
      return Scaffold(
        appBar: AppBar(title: const Text('Agent Gateway')),
        body: _obscured
            ? const Center(child: Icon(Icons.lock, size: 64))
            : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Icon(Icons.shield_outlined, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      'Your data stays under your control',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Connect Gmail to review a bounded preview on this device. Agent pairing and transmission are not available yet.',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Gmail: ${c.connected ? 'connected' : 'not connected'}',
                    ),
                    if (!c.gmailConfigured)
                      const Text(
                        'Gmail sign-in requires the Google iOS client configuration in the next signed build.',
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed:
                              c.busy ||
                                  !c.ready ||
                                  !c.gmailConfigured ||
                                  c.connected
                              ? null
                              : c.connect,
                          child: const Text('Connect Gmail'),
                        ),
                        TextButton(
                          onPressed: c.busy || !c.ready || !c.connected
                              ? null
                              : c.disconnect,
                          child: const Text('Disconnect and revoke'),
                        ),
                      ],
                    ),
                    if (c.busy) const LinearProgressIndicator(),
                    if (c.error != null)
                      Text(
                        _errorMessage(c.error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (!c.ready && !c.busy)
                      TextButton(
                        onPressed: c.initialize,
                        child: const Text('Retry secure storage'),
                      ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _query,
                      decoration: const InputDecoration(
                        labelText: 'Gmail query',
                        hintText: 'subject:invoice',
                      ),
                      maxLength: 200,
                    ),
                    TextField(
                      controller: _purpose,
                      decoration: const InputDecoration(labelText: 'Purpose'),
                      maxLength: 200,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Include sender and snippet'),
                      subtitle: const Text(
                        'Requires local device authentication',
                      ),
                      value: _sensitive,
                      onChanged: c.busy
                          ? null
                          : (value) => setState(() => _sensitive = value),
                    ),
                    FilledButton(
                      onPressed: c.busy || !c.ready || !c.connected
                          ? null
                          : () => c.requestPreview(
                              _query.text,
                              _purpose.text,
                              includeSensitive: _sensitive,
                            ),
                      child: const Text('Request local preview'),
                    ),
                    for (final entry in c.entries.reversed)
                      _entry(entry, c.busy),
                    if (c.rules.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text('Saved local rules'),
                      for (final rule in c.rules)
                        ListTile(
                          title: const Text('Exact-scope preview rule'),
                          subtitle: Text('Expires ${rule['expiresAt']}'),
                          trailing: TextButton(
                            onPressed: c.busy
                                ? null
                                : () => c.revoke(rule['scope']),
                            child: const Text('Revoke'),
                          ),
                        ),
                    ],
                    const SizedBox(height: 24),
                    const Text(
                      'Filtering is best effort. Review every preview; uncommon identifiers may remain.',
                    ),
                    Text('Environment: ${widget.configuration.environment}'),
                    Text('Release: ${widget.configuration.revision}'),
                  ],
                ),
              ),
      );
    },
  );
  String _errorMessage(String code) => switch (code) {
    'gmail_cancelled' => 'Gmail connection was cancelled.',
    'gmail_configuration_required' =>
      'Gmail sign-in is not configured for this device.',
    'gmail_reconnect_required' =>
      'Reconnect Gmail: authorization expired or was revoked.',
    'gmail_revocation_pending' => 'Local credentials were removed. Remove access in Google account settings to complete revocation.',
    'vault_unavailable' =>
      'Secure storage is unavailable. Unlock the device and try again.',
    'local_confirmation_required' => 'Device authentication was not completed.',
    'edit_scope_denied' =>
      'Edits may only remove fields or shorten existing text.',
    'invalid_or_expired_request' =>
      'Use a bounded query and purpose; this request may have expired.',
    'query_scope_denied' =>
      'Wildcards and query-supplied date overrides are not supported.',
    _ =>
      'The operation could not complete safely. Try again or reconnect Gmail.',
  };
}
