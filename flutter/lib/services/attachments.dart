import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../core/crypto/keys.dart';
import '../models/workspace.dart';
import '../features/i18n/i18n.dart';
import 'doc_library.dart';

class Attachments {
  const Attachments._();

  static const maxTextBytes = 96 * 1024;
  static const maxImageBytes = 4 * 1024 * 1024;
  static const maxImageEdge = 1280;

  static const _textual = {
    'txt', 'md', 'markdown', 'json', 'jsonl', 'yaml', 'yml', 'toml', 'ini',
    'cfg', 'conf', 'env', 'csv', 'tsv', 'log', 'sql', 'sh', 'bash', 'zsh',
    'fish', 'ps1', 'bat', 'js', 'mjs', 'cjs', 'jsx', 'ts', 'tsx', 'dart', 'py',
    'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift', 'c', 'h', 'cc', 'cpp',
    'hpp', 'cs', 'php', 'lua', 'r', 'scala', 'clj', 'ex', 'exs', 'erl', 'hs',
    'ml', 'vue', 'svelte', 'html', 'htm', 'xml', 'svg', 'css', 'scss', 'less',
    'gradle', 'properties', 'lock', 'diff', 'patch',
  };

  static const _images = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'heic', 'heif',
  };

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
    if (result == null) return (files: <Attachment>[], problems: <String>[]);
    return intake([
      for (final f in result.files) (name: f.name, bytes: f.bytes),
    ]);
  }

  static Future<({List<Attachment> files, List<String> problems})> pickPictures(
      {bool camera = false}) async {
    final picker = ImagePicker();
    final picked = <XFile>[];
    if (camera) {
      final shot = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: maxImageEdge.toDouble(),
        maxHeight: maxImageEdge.toDouble(),
        imageQuality: 85,
      );
      if (shot != null) picked.add(shot);
    } else {
      picked.addAll(await picker.pickMultiImage(
        maxWidth: maxImageEdge.toDouble(),
        maxHeight: maxImageEdge.toDouble(),
        imageQuality: 85,
      ));
    }
    return intake([
      for (final f in picked) (name: f.name, bytes: await f.readAsBytes()),
    ]);
  }

  static Future<({List<Attachment> files, List<String> problems})> intake(
      List<({String name, Uint8List? bytes})> picked) async {
    final files = <Attachment>[];
    final problems = <String>[];
    for (final f in picked) {
      final bytes = f.bytes;
      if (bytes == null) {
        problems.add(t('{name} (could not be read)', {'name': f.name}));
        continue;
      }
      if (DocLibrary.handles(f.name, bytes.length,
          textual: _textual.contains(_ext(f.name)), textMax: maxTextBytes)) {
        try {
          files.add(await DocLibrary.instance.intake(f.name, bytes));
        } on DocProblem catch (e) {
          problems.add('${f.name} (${e.message})');
        } catch (_) {
          problems.add(t('{name} (could not be read)', {'name': f.name}));
        }
        continue;
      }
      final built = await fromBytes(f.name, bytes);
      final file = built.file;
      if (file == null) {
        problems.add('${f.name} (${built.problem})');
      } else {
        files.add(file);
      }
    }
    return (files: files, problems: problems);
  }

  static bool isImage(String name) => _images.contains(_ext(name));

  static Future<({Attachment? file, String? problem})> fromBytes(
      String name, Uint8List bytes) async {
    final ext = _ext(name);
    if (_images.contains(ext)) return image(name, bytes);
    if (!_textual.contains(ext)) {
      return (
        file: null,
        problem: t('only text, code, document and image files can be attached'),
      );
    }
    if (bytes.length > maxTextBytes) {
      return (
        file: null,
        problem: t('too large — 96 KB is the limit for a file in a message'),
      );
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      return (file: null, problem: t('not readable as text'));
    }
    return (
      file: Attachment(
        id: bytesToHex(randomBytes(8)),
        kind: AttachmentKind.text,
        name: name,
        mime: 'text/plain',
        size: bytes.length,
        lang: _langs[ext] ?? '',
        text: text,
      ),
      problem: null,
    );
  }

  static String _mimeOf(String ext) => switch (ext) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'heic' || 'heif' => 'image/heic',
        _ => 'image/$ext',
      };

  static Attachment _picture(String name, String mime, Uint8List bytes) =>
      Attachment(
        id: bytesToHex(randomBytes(8)),
        kind: AttachmentKind.image,
        name: name,
        mime: mime,
        size: bytes.length,
        bytesBase64: base64Encode(bytes),
      );

  static Future<({Attachment? file, String? problem})> image(
      String name, Uint8List bytes) async {
    final ext = _ext(name);
    final foreign = ext == 'heic' || ext == 'heif';
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? frame;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      final edge = math.max(width, height);
      if (!foreign && bytes.length <= maxImageBytes && edge <= maxImageEdge) {
        return (file: _picture(name, _mimeOf(ext), bytes), problem: null);
      }
      final scale = edge > maxImageEdge ? maxImageEdge / edge : 1.0;
      final w = math.max(1, (width * scale).round());
      final h = math.max(1, (height * scale).round());
      codec = await descriptor.instantiateCodec(targetWidth: w, targetHeight: h);
      frame = (await codec.getNextFrame()).image;
      if (ext == 'png') {
        final png = await frame.toByteData(format: ui.ImageByteFormat.png);
        if (png != null && png.lengthInBytes <= maxImageBytes) {
          return (
            file: _picture(name, 'image/png', png.buffer.asUint8List()),
            problem: null,
          );
        }
      }
      final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) throw const FormatException('no pixels');
      final jpeg = Uint8List.fromList(img.encodeJpg(
        img.Image.fromBytes(
          width: frame.width,
          height: frame.height,
          bytes: rgba.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        ),
        quality: 85,
      ));
      if (jpeg.length > maxImageBytes) {
        return (file: null, problem: t('too large — 4 MB is the limit for a picture'));
      }
      final dot = name.lastIndexOf('.');
      final base = dot == -1 ? name : name.substring(0, dot);
      return (file: _picture('$base.jpg', 'image/jpeg', jpeg), problem: null);
    } catch (_) {
      return (
        file: null,
        problem: foreign
            ? t('this HEIC picture could not be converted here — pick it from '
                'Photos instead')
            : t('not a picture this device can read'),
      );
    } finally {
      frame?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
