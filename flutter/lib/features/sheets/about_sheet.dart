import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../services/build_integrity.dart';
import '../../services/canary.dart';
import '../../services/dev_contact.dart';
import '../i18n/i18n.dart';
import '../nym_icons.dart';
import 'sheet.dart';

const String kAboutVersion = 'v1.0.7';
const String kLiveVersionUrl = 'https://nymbot.ai/app/version.json';
const String kRepoUrl = 'https://github.com/Spl0itable/Nymbot';
const String kDocsUrl = 'https://nymbot.ai/docs/';
const String kTermsUrl = 'https://nymbot.ai/terms/';
const String kPrivacyUrl = 'https://nymbot.ai/privacy/';
const String kDmcaUrl = 'https://nymbot.ai/dmca/';

String? _liveVersionCache;

String? parseLiveVersion(List<int> body) {
  try {
    final doc = jsonDecode(utf8.decode(body, allowMalformed: true));
    if (doc is! Map) return null;
    final v = doc['version'];
    if (v is String && RegExp(r'^v?[0-9][0-9A-Za-z.\-]{1,31}$').hasMatch(v)) {
      return v;
    }
  } catch (_) {}
  return null;
}

Future<String?> fetchLiveVersion({http.Client? client}) async {
  final cached = _liveVersionCache;
  if (cached != null) return cached;
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(Uri.parse(kLiveVersionUrl))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final v = parseLiveVersion(res.bodyBytes);
    if (v != null) _liveVersionCache = v;
    return v;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

Future<BuildIntegrityResult> _measureBuild() =>
    BuildIntegrityService(publisherPubkey: kDeveloperPubkey).run();

class AboutSources {
  const AboutSources({
    this.canary = fetchCanary,
    this.version = fetchLiveVersion,
    this.build = _measureBuild,
  });

  final Future<CanaryResult> Function() canary;
  final Future<String?> Function() version;
  final Future<BuildIntegrityResult> Function() build;
}

AboutSources aboutSources = const AboutSources();

(String, String) buildIntegrityCopy(BuildIntegrityState state) {
  switch (state) {
    case BuildIntegrityState.verified:
      return (
        t('Verified official build'),
        t('The APK installed on this device hashes to the value in the '
            'developer\'s signed Zapstore release event. Anyone can repeat the '
            'check: download the published APK, hash it, and verify that event '
            'against the developer key.'),
      );
    case BuildIntegrityState.mismatch:
      return (
        t('Unrecognized build'),
        t('The APK installed on this device does not match any hash the '
            'developer\'s signed release events carry for this version. It was '
            'modified after publication, or built by someone else.'),
      );
    case BuildIntegrityState.storeRepackaged:
      return (
        t('Installed from Google Play'),
        t('Google Play re-signs the upload with its own key and builds a '
            'separate APK for each device, so what is installed here is not the '
            'file the developer published and its hash matches nothing. To '
            'check a build yourself, install the APK published on Zapstore and '
            'open this panel again.'),
      );
    case BuildIntegrityState.provenanceUnreachable:
      return (
        t('Provenance unreachable'),
        t('The signed release events could not be fetched, or none of them '
            'checked out against the developer key. Nothing is wrong with the '
            'app as far as this panel can tell; it simply has nothing '
            'trustworthy to compare against right now.'),
      );
    case BuildIntegrityState.notPublished:
      return (
        t('No published hash yet'),
        t('The developer has released other versions but none matching this '
            'one, so there is nothing to compare the installed APK against. '
            'This is what a build newer than the published listing looks '
            'like.'),
      );
    case BuildIntegrityState.unsupported:
      return (
        t('Not verifiable on this platform'),
        t('This app cannot check itself here: what runs is compiled code, not '
            'the source, and iOS re-signs and encrypts each download so a hash '
            'computed on the device matches nothing published. Verify the '
            'release you installed against the published build instead, or use '
            'the web app, which re-hashes every file it runs against the '
            'repository\'s signed attestations.'),
      );
  }
}

Future<void> showAboutSheet(BuildContext context) =>
    showNymSheet<void>(context, (_) => const _AboutSheet());

class _AboutSheet extends StatefulWidget {
  const _AboutSheet();

  @override
  State<_AboutSheet> createState() => _AboutSheetState();
}

class _AboutSheetState extends State<_AboutSheet> {
  final _message = TextEditingController();
  String _topic = kContactTopics.first;
  String? _status;
  bool _statusOk = false;
  bool _sending = false;
  CanaryResult? _canary;
  bool _canaryFailed = false;
  String _version = _liveVersionCache ?? kAboutVersion;
  BuildIntegrityResult? _build;

  @override
  void initState() {
    super.initState();
    final sources = aboutSources;
    _loadCanary(sources);
    _loadVersion(sources);
    if (BuildIntegrityService.isSupported) _loadBuild(sources);
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _loadCanary(AboutSources sources) async {
    CanaryResult? result;
    var failed = false;
    try {
      result = await sources.canary();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _canary = result;
      _canaryFailed = failed;
    });
  }

  Future<void> _loadVersion(AboutSources sources) async {
    String? v;
    try {
      v = await sources.version();
    } catch (_) {
      v = null;
    }
    if (!mounted || v == null || v == _version) return;
    setState(() => _version = v!);
  }

  Future<void> _loadBuild(AboutSources sources) async {
    BuildIntegrityResult result;
    try {
      result = await sources.build();
    } catch (_) {
      result = const BuildIntegrityResult(
          state: BuildIntegrityState.provenanceUnreachable);
    }
    if (!mounted) return;
    setState(() => _build = result);
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() {
        _status = t('Please enter a message.');
        _statusOk = false;
      });
      return;
    }
    if (text.length > kContactMaxChars) {
      setState(() {
        _status = t('Keep it under {n} characters.', {'n': kContactMaxChars});
        _statusOk = false;
      });
      return;
    }
    final app = AppScope.read(context);
    if (app.relays.connected == 0) {
      setState(() {
        _status = t('Not connected to a relay. Try again once connected.');
        _statusOk = false;
      });
      return;
    }
    setState(() {
      _sending = true;
      _status = t('Sending…');
      _statusOk = true;
    });
    final outcome = await app.contactDeveloper(_topic, text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (outcome == ContactOutcome.sent) {
        _status = t('Message sent. Thanks for reaching out!');
        _statusOk = true;
        _message.clear();
      } else {
        _status = t('Failed to send. Please try again.');
        _statusOk = false;
      }
    });
  }

  String _topicLabel(String topic) => switch (topic) {
        'Bug report' => t('Bug report'),
        'Feature request' => t('Feature request'),
        'Question' => t('Question'),
        _ => t('General feedback'),
      };

  Widget _link(String label, String url) => InkWell(
        onTap: () => _open(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.secondary)),
        ),
      );

  Widget _panel({
    required String label,
    required String status,
    required Color statusColor,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(fontSize: 12, color: theme.hintColor)),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  status,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: statusColor),
                ),
              ),
            ],
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: Theme.of(context).hintColor)),
      );

  Widget _hash(String label, String hex) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor)),
            SelectableText(hex,
                style: const TextStyle(
                    fontSize: 10,
                    height: 1.4,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback)),
          ],
        ),
      );

  Widget _buildPanel() {
    final theme = Theme.of(context);
    final result = _build;
    final pending = result == null && BuildIntegrityService.isSupported;
    final state = result?.state ?? BuildIntegrityState.unsupported;
    final copy = buildIntegrityCopy(state);
    final measured = result?.info;
    return _panel(
      label: t('Build integrity'),
      status: pending ? t('Checking…') : copy.$1,
      statusColor: pending
          ? theme.hintColor
          : switch (state) {
              BuildIntegrityState.verified => theme.colorScheme.primary,
              BuildIntegrityState.mismatch => NymbotColors.danger,
              _ => theme.colorScheme.onSurface,
            },
      children: [
        if (!pending) _note(copy.$2),
        if (measured?.apkSha256 != null)
          _hash(t('Installed APK'), measured!.apkSha256!),
        if (measured?.signerSha256 != null)
          _hash(t('Signing certificate'), measured!.signerSha256!),
        Wrap(
          spacing: 14,
          children: [
            _link(t('Source'), kRepoUrl),
            _link(t('Build provenance'), '$kRepoUrl/actions'),
            _link(t('How to verify'), '$kRepoUrl#verify-build'),
          ],
        ),
      ],
    );
  }

  String _day(DateTime? d) =>
      d == null ? '' : d.toUtc().toIso8601String().substring(0, 10);

  Widget _canaryPanel() {
    final theme = Theme.of(context);
    final r = _canary;
    String status;
    Color color;
    var note = '';
    if (_canaryFailed) {
      status = t('Unavailable offline');
      color = theme.hintColor;
    } else if (r == null) {
      status = t('Checking…');
      color = theme.hintColor;
    } else {
      switch (r.state) {
        case CanaryState.ok:
          status = t('All clear');
          color = theme.colorScheme.primary;
          note = r.statement.isNotEmpty
              ? r.statement
              : t('No secret government requests have been received.');
        case CanaryState.stale:
          status = r.overdue ? t('Update overdue') : t('Not all clear');
          color = NymbotColors.lightning;
          note = t('The canary has not been refreshed on schedule or no longer '
              'says all clear, so a silenced request (an NSL or FISA order) '
              'cannot be ruled out.');
        case CanaryState.gone:
          status = t('Canary removed');
          color = NymbotColors.danger;
          note = t('The signed canary is no longer published. Treat this as a '
              'serious warning.');
        case CanaryState.forged:
          status = t('Signature invalid');
          color = NymbotColors.danger;
          note = t('The canary signature does not match the Nymbot developer '
              'key. Do not trust this canary.');
        case CanaryState.unsigned:
          status = t('Unsigned');
          color = theme.hintColor;
          note = t('The canary has not been signed yet, so its statement '
              'cannot be verified.');
      }
    }
    final meta = <Widget>[_link(t('canary'), kCanaryPageUrl)];
    if (r != null && !_canaryFailed && r.signed) {
      meta.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(t('signature verified'),
            style: TextStyle(
                fontSize: 11,
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                color: theme.colorScheme.primary)),
      ));
      if (r.id.isNotEmpty) {
        meta.add(_link(t('nostr event'), 'https://njump.me/${r.id}'));
      }
      if (r.btcBlockHeight != null) {
        meta.add(_link(t('btc block {height}', {'height': r.btcBlockHeight}),
            'https://mempool.space/block/${r.btcBlockHash ?? ''}'));
      }
      final updated = _day(r.updatedAt);
      final due = _day(r.dueBy);
      final dates = [
        if (updated.isNotEmpty) t('updated {date}', {'date': updated}),
        if (due.isNotEmpty) t('due {date}', {'date': due}),
      ].join(' · ');
      if (dates.isNotEmpty) {
        meta.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(dates,
              style: TextStyle(
                  fontSize: 11,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  color: theme.hintColor)),
        ));
      }
    }
    return _panel(
      label: t('Warrant canary'),
      status: status,
      statusColor: color,
      children: [
        if (note.isNotEmpty) _note(note),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: meta,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const NymbotMark(size: 28),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Nymbot',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(_version,
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t('A private AI assistant. No account, end-to-end encrypted, paid '
                'in sats.'),
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          _buildPanel(),
          const SizedBox(height: 10),
          _canaryPanel(),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            children: [
              _link(t('Docs'), kDocsUrl),
              _link('GitHub', kRepoUrl),
              _link(t('Terms'), kTermsUrl),
              _link(t('Privacy'), kPrivacyUrl),
              _link('DMCA', kDmcaUrl),
            ],
          ),
          const Divider(height: 28),
          Text(t('Contact the developer'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            t('Send feedback, a question, or a bug report. It is delivered as '
                'an end-to-end encrypted private message from your nym to the '
                'Nymbot developer, never from an anonymous key.'),
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final topic in kContactTopics)
                ChoiceChip(
                  label: Text(_topicLabel(topic)),
                  selected: _topic == topic,
                  onSelected: (_) => setState(() => _topic = topic),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _message,
            minLines: 3,
            maxLines: 6,
            maxLength: kContactMaxChars,
            scrollPadding: textAreaScrollPadding(context, 6),
            decoration: InputDecoration(hintText: t('Write your message…')),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _status!,
                style: TextStyle(
                  fontSize: 12,
                  color: _statusOk
                      ? theme.colorScheme.primary
                      : NymbotColors.danger,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _sending ? null : _send,
              child: Text(_sending ? t('Sending…') : t('Send')),
            ),
          ),
        ],
      ),
    );
  }
}
