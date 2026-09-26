import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/sandbox_host.dart';
import 'code_highlight.dart';
import 'i18n/i18n.dart';

Future<void> showCodePreview(BuildContext context, String code, String lang) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CodePreviewScreen(code: code, lang: lang),
      fullscreenDialog: true,
    ));

class CodePreviewScreen extends StatelessWidget {
  const CodePreviewScreen({super.key, required this.code, required this.lang});

  final String code;
  final String lang;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('Preview'))),
        body: ArtifactWebPreview(
          body: code,
          lang: lang.trim().toLowerCase(),
          fallback: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: HighlightedCode(code: code, language: lang),
            ),
          ),
        ),
      );
}

class ArtifactPreview {
  const ArtifactPreview._();

  static const policy = "default-src 'none'; "
      "script-src 'unsafe-inline' 'unsafe-eval' https: data: blob:; "
      "style-src 'unsafe-inline' https: data: blob:; "
      'img-src https: data: blob:; font-src https: data: blob:; media-src https: data: blob:; '
      'connect-src https: data: blob:; worker-src blob: data:; child-src blob:; '
      "frame-src 'none'; object-src 'none'; "
      "base-uri https:; form-action 'none'";

  static const codeLanguages = {'html', 'htm', 'svg'};

  static bool codePreviewable(String lang) => codeLanguages.contains(lang.trim().toLowerCase());

  static const _meta =
      '<meta http-equiv="Content-Security-Policy" content="$policy">';

  static const _viewport =
      '<meta name="viewport" content="width=device-width, initial-scale=1">';

  static const _prologue = '<!doctype html><html><head>$_meta$_viewport';

  static String document(String body, String lang) {
    final kind = lang.toLowerCase();
    if (kind == 'svg' || kind == 'xml') {
      return '$_prologue<style>body{margin:0;display:flex;justify-content:center}'
          'svg{max-width:100%;height:auto}</style></head><body>$body</body></html>';
    }
    return '$_prologue$body';
  }

  static bool allowedNavigation(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    return u.scheme == 'about';
  }
}

class ArtifactWebPreview extends StatefulWidget {
  const ArtifactWebPreview({
    super.key,
    required this.body,
    required this.lang,
    required this.fallback,
  });

  final String body;
  final String lang;
  final Widget fallback;

  @override
  State<ArtifactWebPreview> createState() => _ArtifactWebPreviewState();
}

class _ArtifactWebPreviewState extends State<ArtifactWebPreview> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    if (!SandboxHost.supported || WebViewPlatform.instance == null) return;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) =>
            ArtifactPreview.allowedNavigation(req.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
      ));
    _controller = c;
    _load();
  }

  void _load() {
    _controller?.loadHtmlString(
        ArtifactPreview.document(widget.body, widget.lang));
  }

  @override
  void didUpdateWidget(ArtifactWebPreview old) {
    super.didUpdateWidget(old);
    if (old.body != widget.body || old.lang != widget.lang) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return widget.fallback;
    return WebViewWidget(controller: c);
  }
}
