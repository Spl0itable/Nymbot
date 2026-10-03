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
import 'sheet.dart';

const String kAboutVersion = 'v1.0.7';
const String kLiveVersionUrl = 'https://nymbot.ai/app/version.json';
const String kRepoUrl = 'https://github.com/Spl0itable/Nymbot';
const String kDocsUrl = 'https://nymbot.ai/docs/';
const String kTermsUrl = 'https://nymbot.ai/terms/';
const String kPrivacyUrl = 'https://nymbot.ai/privacy/';
const String kDmcaUrl = 'https://nymbot.ai/dmca/';
const String kLicenseUrl = 'https://github.com/Spl0itable/Nymbot/blob/main/LICENSE';
const String kCopyrightUrl = 'https://nostrservices.com';
const String kAboutCopyright = '© 21 Million LLC';

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

bool _buildSupported() => BuildIntegrityService.isSupported;

class AboutSources {
  const AboutSources({
    this.canary = fetchCanary,
    this.version = fetchLiveVersion,
    this.build = _measureBuild,
    this.buildSupported = _buildSupported,
  });

  final Future<CanaryResult> Function() canary;
  final Future<String?> Function() version;
  final Future<BuildIntegrityResult> Function() build;
  final bool Function() buildSupported;
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

Color buildIntegrityColor(ThemeData theme, BuildIntegrityState state) =>
    switch (state) {
      BuildIntegrityState.verified => theme.colorScheme.primary,
      BuildIntegrityState.mismatch => NymbotColors.danger,
      BuildIntegrityState.provenanceUnreachable ||
      BuildIntegrityState.notPublished ||
      BuildIntegrityState.storeRepackaged =>
        NymbotColors.lightning,
      BuildIntegrityState.unsupported => theme.colorScheme.onSurface,
    };

Future<void> showAboutSheet(BuildContext context, {bool contact = false}) =>
    showNymSheet<void>(context, (_) => _AboutSheet(contact: contact));

class _AboutSheet extends StatefulWidget {
  const _AboutSheet({this.contact = false});

  final bool contact;

  @override
  State<_AboutSheet> createState() => _AboutSheetState();
}

class _AboutSheetState extends State<_AboutSheet> {
  final _message = TextEditingController();
  final _messageFocus = FocusNode();
  final _contactKey = GlobalKey();
  String _topic = kContactTopics.first;
  String? _status;
  String? _statusKind;
  bool _sending = false;
  CanaryResult? _canary;
  bool _canaryFailed = false;
  String _version = _liveVersionCache ?? kAboutVersion;
  BuildIntegrityResult? _build;
  late final bool _buildSupported = aboutSources.buildSupported();

  @override
  void initState() {
    super.initState();
    final sources = aboutSources;
    _loadCanary(sources);
    _loadVersion(sources);
    if (_buildSupported) _loadBuild(sources);
    if (widget.contact) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusContact());
    }
  }

  Future<void> _focusContact() async {
    final target = _contactKey.currentContext;
    if (!mounted || target == null) return;
    _messageFocus.requestFocus();
    await Scrollable.ensureVisible(target,
        duration: const Duration(milliseconds: 250));
  }

  @override
  void dispose() {
    _message.dispose();
    _messageFocus.dispose();
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

  void _say(String? text, [String? kind]) => setState(() {
        _status = text;
        _statusKind = kind;
      });

  Future<void> _send() async {
    if (_sending) return;
    final text = _message.text.trim();
    if (text.isEmpty) {
      _say(t('Write a message first.'), 'warn');
      return;
    }
    if (text.length > kContactMaxChars) {
      _say(t('That is over 2000 characters. Shorten it and send it again.'),
          'warn');
      return;
    }
    final app = AppScope.read(context);
    if (app.relays.connected == 0) {
      _say(t('Not connected to a relay. Try again once connected.'), 'warn');
      return;
    }
    setState(() => _sending = true);
    _say(t('Sending…'));
    final outcome = await app.contactDeveloper(_topic, text);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (outcome) {
      case ContactOutcome.sent:
        _message.clear();
        _say(t('Message sent. Thanks for reaching out.'), 'ok');
      case ContactOutcome.refused:
        _say(t('No relay took the message. Try again.'), 'warn');
      case ContactOutcome.empty:
        _say(t('Write a message first.'), 'warn');
      case ContactOutcome.tooLong:
        _say(t('That is over 2000 characters. Shorten it and send it again.'),
            'warn');
      case ContactOutcome.failed:
        _say(t('Could not send the message. Try again.'), 'warn');
    }
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

  Widget _creditLink(String label, String url) => Semantics(
        link: true,
        linkUrl: Uri.parse(url),
        child: _link(label, url),
      );

  Widget _panel({
    required Key key,
    required String label,
    required String status,
    required Color statusColor,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
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
    final pending = result == null && _buildSupported;
    final state = result?.state ?? BuildIntegrityState.unsupported;
    final copy = buildIntegrityCopy(state);
    final measured = result?.info;
    return _panel(
      key: const ValueKey('about-build'),
      label: t('Build integrity'),
      status: pending ? t('Verifying…') : copy.$1,
      statusColor: pending ? theme.hintColor : buildIntegrityColor(theme, state),
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
            _link(t('Build provenance'),
                '$kRepoUrl/actions/workflows/build-provenance.yml'),
            _link(t('How to verify'), '$kRepoUrl#verify-build'),
          ],
        ),
      ],
    );
  }

  String _day(DateTime? d) =>
      d == null ? '' : d.toUtc().toIso8601String().substring(0, 10);

  Widget _meta(String text, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                color: color)),
      );

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
          if (r.overdue) {
            status = t('Update overdue');
            color = NymbotColors.lightning;
            note = t('The canary was not refreshed on schedule, so a silenced '
                'request such as a National Security Letter or FISA order '
                'cannot be ruled out.');
          } else {
            status = t('Not all clear');
            color = NymbotColors.danger;
            note = t('The developer no longer states that no secret government '
                'request has been received.');
          }
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
          status = t('Not signed yet');
          color = NymbotColors.lightning;
          note = t('The canary has not been signed by the Nymbot developer '
              'yet, so it does not vouch for anything.');
      }
    }
    final meta = <Widget>[_link(t('Canary file'), kCanaryPageUrl)];
    if (r != null && !_canaryFailed && r.state != CanaryState.gone) {
      if (r.signed) {
        meta.add(_meta(t('signature valid'), theme.colorScheme.primary));
      } else if (r.state == CanaryState.forged) {
        meta.add(_meta(t('signature invalid'), NymbotColors.danger));
      } else {
        meta.add(_meta(t('unsigned'), theme.hintColor));
      }
      if (r.signed && r.id.isNotEmpty) {
        meta.add(_link(t('Nostr event'), 'https://njump.me/${r.id}'));
      }
      final hash = r.btcBlockHash;
      if (r.btcBlockHeight != null &&
          hash != null &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        meta.add(_link(
            t('Bitcoin block {height}', {'height': figure(r.btcBlockHeight)}),
            'https://mempool.space/block/$hash'));
      }
      final updated = _day(r.updatedAt);
      final due = _day(r.dueBy);
      final dates = [
        if (updated.isNotEmpty) t('updated {date}', {'date': updated}),
        if (due.isNotEmpty) t('due {date}', {'date': due}),
      ].join(' · ');
      if (dates.isNotEmpty) meta.add(_meta(dates, theme.hintColor));
    }
    return _panel(
      key: const ValueKey('about-canary'),
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
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('Nymbot', style: theme.textTheme.titleMedium),
              const SizedBox(width: 6),
              Flexible(
                child: Text(_version,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                        color: theme.hintColor)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t('Private AI chat with no account, end-to-end encrypted, and paid '
                'per reply in Bitcoin over Lightning.'),
            style: TextStyle(fontSize: 12, height: 1.45, color: theme.hintColor),
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
          Padding(
            key: const ValueKey('about-license'),
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _creditLink(kAboutCopyright, kCopyrightUrl),
                Text(' · ',
                    style: TextStyle(fontSize: 12, color: theme.hintColor)),
                _creditLink(t('Licensed under AGPL-3.0'), kLicenseUrl),
              ],
            ),
          ),
          const Divider(height: 28),
          Text(t('Contact the developer'),
              key: _contactKey, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            t('Send feedback, a question or a bug report. It goes to the '
                'Nymbot developer as an end-to-end encrypted private message '
                'from your own key, never from a throwaway one.'),
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
          const SizedBox(height: 10),
          Text(t('Topic'),
              style: TextStyle(fontSize: 12, color: theme.hintColor)),
          const SizedBox(height: 4),
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
            key: const ValueKey('contact-message'),
            controller: _message,
            focusNode: _messageFocus,
            minLines: 3,
            maxLines: 6,
            maxLength: kContactMaxChars,
            scrollPadding: textAreaScrollPadding(context, 6),
            decoration: InputDecoration(hintText: t('Write your message')),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _status!,
                style: TextStyle(
                  fontSize: 12,
                  color: switch (_statusKind) {
                    'ok' => theme.colorScheme.primary,
                    'warn' => NymbotColors.danger,
                    _ => theme.hintColor,
                  },
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _sending ? null : _send,
              child: Text(t('Send message')),
            ),
          ),
        ],
      ),
    );
  }
}
