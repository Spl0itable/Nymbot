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

  static const policy = "default-src 'none'; img-src data: blob:; "
      "style-src 'unsafe-inline' https:; font-src https: data:; "
      "script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'";

  static const codeLanguages = {'html', 'htm', 'svg'};

  static bool codePreviewable(String lang) => codeLanguages.contains(lang.trim().toLowerCase());

  static const _meta =
      '<meta http-equiv="Content-Security-Policy" content="$policy">';

  static String document(String body, String lang) {
    final kind = lang.toLowerCase();
    if (kind == 'svg' || kind == 'xml') {
      return '<!doctype html><html><head>$_meta'
          '<meta name="viewport" content="width=device-width, initial-scale=1">'
          '<style>body{margin:0;display:flex;justify-content:center}'
          'svg{max-width:100%;height:auto}</style></head><body>$body</body></html>';
    }
    final head = RegExp(r'<head(\s[^>]*)?>', caseSensitive: false).firstMatch(body);
    if (head != null) {
      return body.replaceRange(head.end, head.end, _meta);
    }
    final html = RegExp(r'<html(\s[^>]*)?>', caseSensitive: false).firstMatch(body);
    if (html != null) {
      return body.replaceRange(html.end, html.end, '<head>$_meta</head>');
    }
    return '<!doctype html><html><head>$_meta'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '</head><body>$body</body></html>';
  }

  static bool allowedNavigation(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    return u.scheme == 'about' || u.scheme == 'data';
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
