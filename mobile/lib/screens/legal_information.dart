import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final privacyPolicyUrl = Uri.parse('https://gateway.zerobox.ai/privacy/');
final termsOfUseUrl = Uri.parse('https://gateway.zerobox.ai/terms/');

Future<bool> _openInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key, this.openUrl = _openInBrowser});

  final Future<bool> Function(Uri) openUrl;

  Future<void> _open(BuildContext context, Uri url) async {
    try {
      if (await openUrl(url)) return;
    } catch (_) {
      // Keep the public address available when no browser can be opened.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: SelectableText('Open this page in your browser: $url')),
    );
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      TextButton(
        onPressed: () => _open(context, privacyPolicyUrl),
        child: const Text('Privacy Policy'),
      ),
      TextButton(
        onPressed: () => _open(context, termsOfUseUrl),
        child: const Text('Terms of Use'),
      ),
    ],
  );
}

class GmailPrivacyCard extends StatelessWidget {
  const GmailPrivacyCard({super.key});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Gmail access & privacy',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Read selected email details and review messages composed by Muse. '
            'Preview data requests or allow sharing once. Outgoing email '
            'always has a separate send review.',
          ),
          const SizedBox(height: 8),
          Text(
            'Policies updated November 2, 2026',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const LegalLinks(),
        ],
      ),
    ),
  );
}

Future<bool> showGmailPrivacyNotice(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Before connecting Gmail'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Agent Gateway by Zerobox requests Gmail read-only and send permissions to '
                'search selected message IDs, dates, senders, subjects, and '
                'snippets for requests from your paired Muse client. '
                'Muse can also compose plain-text email with To, Cc, Bcc, '
                'subject, and message fields and submit an encrypted send request. The app reads your Gmail sender '
                'address, then shows the complete email for review and requires '
                'Allow and device authentication before sending directly through Gmail. Decline sends nothing. '
                'It does not manage Gmail drafts, change or delete existing email, '
                'or retrieve attachments or full message bodies from searches.',
              ),
              SizedBox(height: 12),
              Text(
                'Gmail tokens stay on your iPhone. Choose Preview to review '
                'a filtered result before sharing, Allow to fetch and share '
                'once without a preview, or Deny to reject a request. '
                'Approved results go to your paired Muse client through '
                'the encrypted Cloudflare relay. The recipient can retain '
                'shared information. Outgoing email goes directly to Google and '
                'your addressed recipients, who may retain or forward it. '
                'Muse already knows the email it composed. Requests are kept in secure '
                'device review storage under bounded retention; sent copies are held by Gmail and recipients. '
                'A data-request Allow never authorizes sending an email.',
              ),
              SizedBox(height: 12),
              Text(
                'Google Workspace data is not used to develop, improve, or '
                'train non-personalized AI or machine-learning models. '
                'You can disconnect Gmail and revoke Google access at any time.',
              ),
              LegalLinks(),
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
            child: const Text('Continue to Google'),
          ),
        ],
      ),
    ) ??
    false;
