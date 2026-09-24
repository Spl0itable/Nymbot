class Nickname {
  const Nickname._();

  static const int max = 32;

  static final RegExp _breaks = RegExp(r'[\t\n\v\f\r\u0085\u2028\u2029]');

  static final RegExp _invisible = RegExp(
      r'[\u0000-\u001F\u007F-\u009F\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5'
      r'\u180B-\u180F\u200B-\u200F\u2028-\u202E\u2060-\u206F\u3164\uFEFF\uFFA0'
      r'\uFFF9-\uFFFB\u{E0000}-\u{E007F}]',
      unicode: true);

  static final RegExp _space = RegExp(r'\s+', unicode: true);

  static String clean(Object? value) {
    final text = (value is String ? value : '')
        .replaceAll(_breaks, ' ')
        .replaceAll(_invisible, '')
        .replaceAll(_space, ' ')
        .trim();
    return String.fromCharCodes(text.runes.take(max)).trim();
  }
}
