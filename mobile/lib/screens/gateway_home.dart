import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../approvals/review_service.dart';
import '../domain/gateway_configuration.dart';
import '../domain/muse_skill.dart';
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
  Timer? _expiry;
  Completer<void>? _resumed;
  bool _obscured = false;
  Future<void> _copyMuseMessage(String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: message));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copied. Paste into Muse, then return here.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not copy. Please try again.')),
      );
    }
  }

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
      _resumed ??= Completer<void>();
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _obscured = false);
      widget.controller.foreground = true;
      _resumed?.complete();
      _resumed = null;
      if (widget.controller.ready) widget.controller.reload();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _resumed?.complete();
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

  Future<bool> _confirmPairing() async {
    final pairing = widget.controller.pinPairing;
    if (pairing == null) return false;
    if (_obscured) {
      final remaining =
          pairing.exchange.expiresAt * 1000 -
          DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) return false;
      try {
        await (_resumed ??= Completer<void>()).future.timeout(
          Duration(milliseconds: remaining),
        );
      } on TimeoutException {
        return false;
      }
    }
    if (!mounted ||
        _obscured ||
        widget.controller.pinPairing != pairing ||
        pairing.status != 'confirming') {
      return false;
    }
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Allow this Muse client to pair?'),
            content: const Text(
              'The client proved it knows your one-time code. Continue only if you just gave the setup message to Muse. Gmail requests will still need your approval.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Deny'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Allow and authenticate'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _pairAndCopy(GatewayController c) async {
    if (c.pairingComplete) {
      final message = c.museSkill;
      if (message != null) await _copyMuseMessage(message);
      return;
    }
    if (c.pinPairing?.status != 'waiting') {
      await c.startPinPairing(_confirmPairing);
    }
    if (!mounted || _obscured || c.error != null) return;
    final pairing = c.pinPairing;
    if (pairing?.status == 'waiting') {
      await _copyMuseMessage(
        musePairingMessage(
          origin: pairing!.exchange.origin,
          setupLine: pairing.exchange.setupLine,
        ),
      );
    }
  }

  Widget _museCard(GatewayController c) {
    final pairing = c.pinPairing;
    final active =
        pairing != null && !['paired', 'failed'].contains(pairing.status);
    final canCopy = c.pairingComplete || pairing?.status == 'waiting';
    final status = c.pairingComplete
        ? 'Connected'
        : switch (pairing?.status) {
            'connecting' => 'Connecting...',
            'waiting' => 'Paste the copied message into Muse.',
            'authenticating' || 'offer' => 'Verifying Muse...',
            'confirming' => 'Confirm the connection on this iPhone.',
            'finishing' => 'Finishing pairing...',
            'failed' => _errorMessage(pairing?.error ?? 'pairing_failed'),
            _ => 'Pair once to receive Gmail requests.',
          };
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: const Text('Muse'),
            subtitle: Text(status),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed:
                      c.busy ||
                          !c.ready ||
                          c.relay == null ||
                          (active && !canCopy)
                      ? null
                      : () => _pairAndCopy(c),
                  icon: Icon(
                    c.pairingComplete || pairing?.status == 'waiting'
                        ? Icons.copy_rounded
                        : Icons.link_rounded,
                  ),
                  label: Text(
                    c.pairingComplete
                        ? 'Copy Muse setup'
                        : pairing?.status == 'waiting'
                        ? 'Copy setup message'
                        : 'Pair with Muse',
                  ),
                ),
                if (active)
                  TextButton(
                    onPressed: c.busy
                        ? null
                        : () async {
                            if (c.delivery?.agentId != null) {
                              await c.unpair();
                            } else {
                              c.cancelPinPairing();
                            }
                          },
                    child: const Text('Cancel pairing'),
                  ),
                if (c.pairingComplete)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: c.busy ? null : c.unpair,
                      child: const Text('Unpair Muse'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fieldLabel(String field) => switch (field) {
    'id' => 'Message ID',
    'date' => 'Date',
    'from' => 'Sender',
    'subject' => 'Subject',
    'snippet' => 'Preview',
    _ => field,
  };

  Widget _entry(ReviewEntry entry, bool busy) {
    if (!entry.request.expiresAt.isAfter(DateTime.now())) {
      return const SizedBox.shrink();
    }
    final dates = MaterialLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.request.purpose,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Search: ${entry.request.query}'),
            Text(
              '${dates.formatShortDate(entry.request.since.toLocal())} to ${dates.formatShortDate(entry.request.until.toLocal())}, up to ${entry.request.maxResults} emails',
            ),
            Text(entry.request.fields.map(_fieldLabel).join(', ')),
            if (entry.request.highRisk)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Device confirmation required'),
              ),
            if (entry.state == ReviewState.fetching)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
            if (entry.state == ReviewState.access) ...[
              const SizedBox(height: 16),
              const Text(
                'Allow Gmail access to prepare a preview? Nothing is shared yet.',
              ),
              const SizedBox(height: 8),
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
            if (entry.state == ReviewState.disclosure) ...[
              const SizedBox(height: 16),
              const Text('Review what Muse will receive.'),
              for (final message in entry.candidate)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final field in message.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: SelectableText(
                            '${_fieldLabel(field.key)}: ${field.value}',
                          ),
                        ),
                    ],
                  ),
                ),
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
                ],
              ),
            ],
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
      final pending = c.pendingEntries;
      final allSet = c.connected && c.pairingComplete && c.relayEnabled;
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
        appBar: AppBar(
          title: const Text('Agent Gateway'),
          centerTitle: false,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
          scrolledUnderElevation: 0,
        ),
        body: _obscured
            ? const Center(child: Icon(Icons.lock_outline_rounded, size: 48))
            : SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.mail_outline_rounded),
                            title: const Text('Gmail'),
                            subtitle: Text(
                              c.connected ? 'Connected' : 'Not connected',
                            ),
                            trailing: TextButton(
                              onPressed:
                                  c.busy || !c.ready || !c.gmailConfigured
                                  ? null
                                  : c.connected
                                  ? c.disconnect
                                  : c.connect,
                              child: Text(
                                c.connected
                                    ? 'Disconnect Gmail'
                                    : 'Connect Gmail',
                              ),
                            ),
                          ),
                        ),
                        if (!c.gmailConfigured)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'Gmail connection is not available in this version.',
                            ),
                          ),
                        if (c.delivery != null) _museCard(c),
                        if (c.pairingComplete && c.relay != null)
                          Card(
                            child: SwitchListTile(
                              secondary: const Icon(
                                Icons.notifications_none_rounded,
                              ),
                              title: const Text('Notifications'),
                              subtitle: const Text(
                                'Receive requests from Muse.',
                              ),
                              value: c.relayEnabled,
                              onChanged: c.busy ? null : c.enableRelay,
                            ),
                          ),
                        if (c.busy)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: LinearProgressIndicator(),
                          ),
                        if (c.error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _errorMessage(c.error!),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (!c.ready && !c.busy)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: c.initialize,
                              child: const Text('Retry'),
                            ),
                          ),
                        if (c.rules.isNotEmpty)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: c.busy ? null : c.clearSavedApprovals,
                              child: const Text('Reset saved approvals'),
                            ),
                          ),
                        const SizedBox(height: 24),
                        if (pending.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              'Needs your approval',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final entry in pending.reversed)
                            _entry(entry, c.busy),
                        ] else
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 32,
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  allSet
                                      ? Icons.check_circle_outline_rounded
                                      : Icons.shield_outlined,
                                  size: 36,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  allSet
                                      ? 'No requests to review'
                                      : 'Connect to get started',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  allSet
                                      ? 'Ask Muse about your Gmail. New requests will appear here.'
                                      : 'Connect Gmail, pair Muse and enable notifications.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
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
    'pairing_expired' =>
      'The pairing code expired. Tap Pair with Muse for a new code.',
    'pairing_failed' => 'The pairing attempt failed. Cancel and generate a fresh code on the iPhone.',
    'pairing_cancelled' =>
      'Pairing was declined. Generate a fresh code to try again.',
    'pairing_interrupted' => 'The connection ended. Check whether Muse paired; otherwise unpair and try a fresh code.',
    'pairing_unavailable' => 'Cannot reach pairing on the relay. Check connectivity and that the new relay version is deployed.',
    'invalid_pairing' => 'Pairing failed. Try a new setup message.',
    'invalid_envelope' =>
      'Encrypted transfer is invalid or exceeds its size limit.',
    'relay_unavailable' => 'Relay delivery is unavailable. Keep the app open to retry before the request expires.',
    'relay_configuration_required' =>
      'Relay delivery needs a configured HTTPS relay in this build.',
    'notifications_unavailable' => 'Enable notifications for Agent Gateway in iPhone Settings, then reopen the app.',
    'unpaired' => 'The request does not match the current paired agent.',
    'replay_changed_content' =>
      'This request identity was already used or its content changed.',
    _ =>
      'The operation could not complete safely. Try again or reconnect Gmail.',
  };
}
