import '../features/i18n/i18n.dart';
import '../models/workspace.dart';

class PictureEdit {
  static final RegExp _command = RegExp(r'^\s*\?(?:image|imagine)\b([\s\S]*)$', caseSensitive: false);
  static final RegExp _flag = RegExp(r'(?:^|\s)(?:--model|-m)[\s=]+\S+', caseSensitive: false);
  static final RegExp _lists = RegExp(r'^models?$', caseSensitive: false);

  static bool hasPicture(List<Attachment> attachments) =>
      attachments.any((a) => a.kind == AttachmentKind.image);

  static String? typedCommand(String text) {
    final m = _command.firstMatch(text);
    if (m == null) return null;
    final rest = m.group(1)!.replaceAll(_flag, ' ').trim();
    if (_lists.hasMatch(rest)) return null;
    return rest;
  }

  static bool pinnedImage(Map<String, dynamic>? media) =>
      media != null && media['kind'] == 'image' && media['command'] != null;

  static bool editing(String text, List<Attachment> attachments, Map<String, dynamic>? media) {
    if (!hasPicture(attachments)) return false;
    final raw = text.trim();
    if (typedCommand(raw) != null) return true;
    if (raw.startsWith('?') || raw.startsWith('!') || raw.startsWith('@')) return false;
    return pinnedImage(media);
  }

  static String instruction(String text) => typedCommand(text) ?? text.trim();

  static String hint() => t('Describe how to change the picture');
}
