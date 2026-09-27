import 'package:url_launcher/url_launcher.dart';

const Set<String> _allowedSchemes = {'http', 'https', 'mailto'};

final RegExp _stripRe = RegExp(
    '[\\u0000-\\u0020\\u00a0\\u1680\\u2000-\\u200d'
    '\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]');

Uri? safeExternalUri(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url.replaceAll(_stripRe, ''));
  if (uri == null || !uri.hasScheme) return null;
  if (!_allowedSchemes.contains(uri.scheme.toLowerCase())) return null;
  final exact = Uri.tryParse(url);
  if (exact == null || exact.scheme.toLowerCase() != uri.scheme.toLowerCase()) return uri;
  return exact;
}

Future<bool> launchSafeUrl(String? url,
    {LaunchMode mode = LaunchMode.externalApplication}) async {
  final uri = safeExternalUri(url);
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: mode);
  } catch (_) {
    return false;
  }
}
