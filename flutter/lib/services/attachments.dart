import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../core/crypto/keys.dart';
import '../models/workspace.dart';

class Attachments {
  const Attachments._();

  static const maxTextBytes = 96 * 1024;
  static const maxImageBytes = 4 * 1024 * 1024;

  static const _textual = {
    'txt', 'md', 'markdown', 'json', 'jsonl', 'yaml', 'yml', 'toml', 'ini',
    'cfg', 'conf', 'env', 'csv', 'tsv', 'log', 'sql', 'sh', 'bash', 'zsh',
    'fish', 'ps1', 'bat', 'js', 'mjs', 'cjs', 'jsx', 'ts', 'tsx', 'dart', 'py',
    'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift', 'c', 'h', 'cc', 'cpp',
    'hpp', 'cs', 'php', 'lua', 'r', 'scala', 'clj', 'ex', 'exs', 'erl', 'hs',
    'ml', 'vue', 'svelte', 'html', 'htm', 'xml', 'svg', 'css', 'scss', 'less',
    'gradle', 'properties', 'lock', 'diff', 'patch',
  };

  static const _images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'heic'};

  static const _langs = {
    'js': 'js', 'mjs': 'js', 'cjs': 'js', 'jsx': 'jsx', 'ts': 'ts', 'tsx': 'tsx',
    'dart': 'dart', 'py': 'py', 'rb': 'ruby', 'go': 'go', 'rs': 'rust',
    'java': 'java', 'kt': 'kotlin', 'swift': 'swift', 'c': 'c', 'h': 'c',
    'cc': 'cpp', 'cpp': 'cpp', 'hpp': 'cpp', 'cs': 'csharp', 'php': 'php',
    'lua': 'lua', 'sh': 'sh', 'bash': 'sh', 'zsh': 'sh', 'sql': 'sql',
    'json': 'json', 'yml': 'yaml', 'yaml': 'yaml', 'toml': 'toml',
    'md': 'markdown', 'markdown': 'markdown', 'html': 'html', 'htm': 'html',
    'xml': 'xml', 'svg': 'svg', 'css': 'css', 'scss': 'scss', 'less': 'less',
    'csv': 'csv', 'diff': 'diff', 'patch': 'diff', 'vue': 'html', 'svelte': 'html',
  };

  // A wall of pasted text is a document, not a sentence. Past this it goes in
  // as an attachment rather than filling the composer, so the question you are
  // asking about it stays readable.
  static const pasteAsFileChars = 1500;
  static const pasteAsFileLines = 30;

  static bool pasteIsLong(String text) =>
      text.length >= pasteAsFileChars ||
      '\n'.allMatches(text).length + 1 >= pasteAsFileLines;

  /// Wraps pasted text as an attachment. Named rather than guessed at: calling
  /// it a .txt it never was would be worse than saying where it came from.
  static Attachment fromText(String text, {String? name, required String id}) {
    final kept =
        text.length > maxTextBytes ? text.substring(0, maxTextBytes) : text;
    return Attachment(
      id: id,
      kind: AttachmentKind.text,
      name: name ?? 'Pasted text',
      mime: 'text/plain',
      size: kept.length,
      lines: '\n'.allMatches(kept).length + 1,
      text: kept,
    );
  }

  static String _ext(String name) {
    final at = name.lastIndexOf('.');
    return at == -1 ? '' : name.substring(at + 1).toLowerCase();
  }

  static Future<({List<Attachment> files, List<String> problems})> pick() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    final files = <Attachment>[];
    final problems = <String>[];
    if (result == null) return (files: files, problems: problems);

    for (final f in result.files) {
      final bytes = f.bytes;
      if (bytes == null) {
        problems.add(f.name);
        continue;
      }
      final built = fromBytes(f.name, bytes);
      if (built == null) {
        problems.add(f.name);
      } else {
        files.add(built);
      }
    }
    return (files: files, problems: problems);
  }

  static Attachment? fromBytes(String name, Uint8List bytes) {
    final ext = _ext(name);
    if (_images.contains(ext)) {
      if (bytes.length > maxImageBytes) return null;
      return Attachment(
        id: bytesToHex(randomBytes(8)),
        kind: AttachmentKind.image,
        name: name,
        mime: ext == 'png' ? 'image/png' : 'image/${ext == 'jpg' ? 'jpeg' : ext}',
        size: bytes.length,
        bytesBase64: base64Encode(bytes),
      );
    }
    if (!_textual.contains(ext)) return null;
    if (bytes.length > maxTextBytes) return null;
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      return null;
    }
    return Attachment(
      id: bytesToHex(randomBytes(8)),
      kind: AttachmentKind.text,
      name: name,
      mime: 'text/plain',
      size: bytes.length,
      lang: _langs[ext] ?? '',
      text: text,
    );
  }
}
