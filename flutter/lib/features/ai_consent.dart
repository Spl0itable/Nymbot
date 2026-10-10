import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'i18n/i18n.dart';
import 'nym_icons.dart';

const String kAiConsentPrivacyUrl = 'https://nymbot.ai/privacy/';

const Set<String> kAiConsentActions = {
  'pm',
  'pm-steer',
  'pm-answer',
  'pm-revert',
  'transcribe',
  'site-check',
  'runner-run',
  'mcp-probe',
  'git-apply',
  'git-branch',
  'schedule-put',
  'pr-watch-put',
  'pr-watch-peek',
  'pr-watch-fix',
};

enum AiConsentDecision { unset, allowed, declined }

class AiConsentStrings {
  AiConsentStrings._();

  static String get stepTitle => t('Nymbot uses AI services');

  static String get stepIntro => t(
      'Before you start, here is what Nymbot sends to answer you and who '
      'receives it.');

  static String get what => t(
      'What is sent: your messages and the earlier messages of that chat, the '
      'files, images and voice recordings you add, and the persona, '
      'instructions, memories and workspace files you use with it. When you '
      'connect a repository or a connector, Nymbot also receives its access '
      'token, and the files and tool results it reads go to the AI model.');

  static String get who => t(
      'Who receives it: the Nymbot service run by 21 Million LLC, which '
      'processes it on our servers. If you pick a Pro model or an image or '
      'video generator, it also goes to that model\'s maker, such as OpenAI, '
      'Anthropic, Google, xAI, Moonshot AI, Alibaba or MiniMax. Repositories '
      'and connectors you add are contacted on your behalf.');

  static String get later => t(
      'You can turn this off at any time in Settings → Privacy & Security.');

  static String get privacyLink => t('Privacy Policy');

  static String get accept => t('Allow and continue');

  static String get decline => t('Don\'t allow');

  static String get declinedTitle => t('Nymbot needs AI processing');

  static String get declinedBody => t(
      'Nymbot answers by sending your messages to AI services, so it cannot '
      'work until you allow that. Nothing has been sent. You can allow it '
      'whenever you are ready.');

  static String get offNotice => t(
      'Nothing was sent. Nymbot needs Nymbot AI processing to answer. Turn it '
      'on in Settings → Privacy & Security.');

  static String get section => t('Privacy & Security');

  static String get settingSwitch => t('Allow Nymbot AI processing');

  static List<String> get all => [
        stepTitle,
        stepIntro,
        what,
        who,
        later,
        privacyLink,
        accept,
        decline,
        declinedTitle,
        declinedBody,
        offNotice,
        section,
        settingSwitch,
      ];
}

class AiConsent extends ChangeNotifier {
  AiConsent._();

  static final AiConsent instance = AiConsent._();

  String Function()? scope;

  String? _key() {
    final pk = scope?.call() ?? '';
    if (pk.isEmpty) return null;
    final digest = crypto.sha256.convert(utf8.encode('nymbot-ai-consent|$pk'));
    return 'aiConsent.${digest.toString().substring(0, 32)}';
  }

  bool assumeAllowed = false;

  Future<AiConsentDecision> decision() async {
    if (assumeAllowed) return AiConsentDecision.allowed;
    final key = _key();
    if (key == null) return AiConsentDecision.unset;
    try {
      final prefs = await SharedPreferences.getInstance();
      switch (prefs.getString(key)) {
        case 'allowed':
          return AiConsentDecision.allowed;
        case 'declined':
          return AiConsentDecision.declined;
      }
    } catch (_) {}
    return AiConsentDecision.unset;
  }

  Future<bool> allowed() async =>
      await decision() == AiConsentDecision.allowed;

  Future<void> set(bool allow) async {
    final key = _key();
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, allow ? 'allowed' : 'declined');
    notifyListeners();
  }
}

Future<void> _openPolicy() async {
  try {
    await launchUrl(Uri.parse(kAiConsentPrivacyUrl),
        mode: LaunchMode.externalApplication);
  } catch (_) {}
}

class AiConsentGate extends StatefulWidget {
  const AiConsentGate({super.key, required this.pubkey, required this.builder});

  final String pubkey;
  final WidgetBuilder builder;

  @override
  State<AiConsentGate> createState() => _AiConsentGateState();
}

class _AiConsentGateState extends State<AiConsentGate> {
  AiConsentDecision? _decision;
  int _loads = 0;

  @override
  void initState() {
    super.initState();
    AiConsent.instance.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(AiConsentGate old) {
    super.didUpdateWidget(old);
    if (old.pubkey != widget.pubkey) _load();
  }

  @override
  void dispose() {
    AiConsent.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final ticket = ++_loads;
    final d = await AiConsent.instance.decision();
    if (!mounted || ticket != _loads) return;
    setState(() => _decision = d);
  }

  @override
  Widget build(BuildContext context) {
    final d = _decision;
    if (d == null) return const Scaffold(body: SizedBox.expand());
    if (d == AiConsentDecision.allowed) return widget.builder(context);
    return AiConsentStep(declined: d == AiConsentDecision.declined);
  }
}

class AiConsentStep extends StatelessWidget {
  const AiConsentStep({super.key, this.declined = false});

  final bool declined;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium;
    final link = theme.colorScheme.primary;
    return Scaffold(
      key: Key(declined ? 'aiConsentDeclined' : 'aiConsentStep'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: NymbotMark(
                      size: 48,
                      color: declined ? theme.hintColor : link,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    declined
                        ? AiConsentStrings.declinedTitle
                        : AiConsentStrings.stepTitle,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    declined
                        ? AiConsentStrings.declinedBody
                        : AiConsentStrings.stepIntro,
                    style: body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Text(AiConsentStrings.what, style: body),
                  const SizedBox(height: 10),
                  Text(AiConsentStrings.who, style: body),
                  const SizedBox(height: 10),
                  Text(AiConsentStrings.later,
                      style: body?.copyWith(color: theme.hintColor)),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text.rich(
                      TextSpan(
                        text: AiConsentStrings.privacyLink,
                        style: body?.copyWith(
                          color: link,
                          decoration: TextDecoration.underline,
                          decorationColor: link,
                        ),
                        recognizer: TapGestureRecognizer()..onTap = _openPolicy,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('aiConsentAccept'),
                    onPressed: () => AiConsent.instance.set(true),
                    child: Text(AiConsentStrings.accept),
                  ),
                  if (!declined) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      key: const Key('aiConsentDecline'),
                      onPressed: () => AiConsent.instance.set(false),
                      child: Text(AiConsentStrings.decline),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AiConsentSettings extends StatefulWidget {
  const AiConsentSettings({super.key});

  @override
  State<AiConsentSettings> createState() => _AiConsentSettingsState();
}

class _AiConsentSettingsState extends State<AiConsentSettings> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    AiConsent.instance.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    AiConsent.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final d = await AiConsent.instance.decision();
    if (!mounted) return;
    setState(() => _on = d == AiConsentDecision.allowed);
  }

  Future<void> _set(bool v) async {
    setState(() => _on = v);
    await AiConsent.instance.set(v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = TextStyle(fontSize: 11, color: theme.hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(AiConsentStrings.section, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        SwitchListTile(
          key: const Key('aiConsentSwitch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _on,
          title: Text(AiConsentStrings.settingSwitch,
              style: const TextStyle(fontSize: 13)),
          onChanged: _set,
        ),
        Text(AiConsentStrings.what, style: hint),
        const SizedBox(height: 6),
        Text(AiConsentStrings.who, style: hint),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              text: AiConsentStrings.privacyLink,
              style: hint.copyWith(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: theme.colorScheme.primary,
              ),
              recognizer: TapGestureRecognizer()..onTap = _openPolicy,
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
