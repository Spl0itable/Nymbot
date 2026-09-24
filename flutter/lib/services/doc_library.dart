import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';

import '../core/crypto/keys.dart';
import '../features/i18n/i18n.dart';
import '../models/workspace.dart';
import '../state/store.dart';
import 'doc_search.dart';
import 'sandbox_host.dart';
import 'sandbox_protocol.dart';

class DocProblem implements Exception {
  const DocProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

class DocLibrary extends ChangeNotifier {
  DocLibrary._();

  static final DocLibrary instance = DocLibrary._();

  static const filesPerChat = 20;
  static const usageCap = 400;
  static const fileMaxBytes = 30 * 1024 * 1024;
  static const entryMaxBytes = 32 * 1024 * 1024;

  Store? _store;
  final Map<String, List<SearchDoc>> _cache = {};
  final Map<String, SearchDoc> _pending = {};
  Map<String, DocUsage>? _usage;

  static void bind(Store store) {
    instance._store = store;
  }

  bool _ghost(String convId) => _store?.isGhost(convId) ?? true;

  List<SearchDoc> list(String convId) {
    final hit = _cache[convId];
    if (hit != null) return hit;
    final store = _store;
    final raw = (store == null || _ghost(convId)) ? null : store.getString('docs_$convId');
    final out = <SearchDoc>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final e in jsonDecode(raw) as List) {
          if (e is Map) out.add(SearchDoc.fromJson(e.cast<String, dynamic>()));
        }
      } catch (_) {}
    }
    _cache[convId] = out;
    return out;
  }

  List<SearchDoc> searchable(String convId) => list(convId).where((d) => d.searchable).toList();

  Future<void> _save(String convId) async {
    final store = _store;
    if (store == null || _ghost(convId)) return;
    final docs = list(convId);
    if (docs.isEmpty) {
      await store.remove('docs_$convId');
    } else {
      await store.setString('docs_$convId', jsonEncode(docs.map((d) => d.toJson()).toList()));
    }
  }

  List<SearchDoc> _docsFor(String? convId, List<Attachment> attachments) {
    final out = <SearchDoc>[];
    final seen = <String>{};
    if (convId != null) {
      for (final d in searchable(convId)) {
        if (seen.add(d.id)) out.add(d);
      }
    }
    for (final a in attachments) {
      final d = _pending[a.id];
      if (a.searched && d != null && seen.add(d.id)) out.add(d);
    }
    return out;
  }

  String wireFor(String? convId, String question, List<Attachment> attachments) =>
      DocSearch.wireFor(_docsFor(convId, attachments), question);

  List<DocUsage> usageFor(String? convId, String question, List<Attachment> attachments) =>
      DocSearch.usage(_docsFor(convId, attachments), question);

  Map<String, DocUsage> _usageMap() {
    final held = _usage;
    if (held != null) return held;
    final out = <String, DocUsage>{};
    final raw = _store?.getString('doc_usage');
    if (raw != null && raw.isNotEmpty) {
      try {
        (jsonDecode(raw) as Map).forEach((k, v) {
          if (v is Map) out['$k'] = DocUsage.fromJson(v.cast<String, dynamic>());
        });
      } catch (_) {}
    }
    _usage = out;
    return out;
  }

  List<DocUsage> usageOf(String messageId) {
    final map = _usageMap();
    return [
      for (final e in map.entries)
        if (e.key == messageId || e.key.startsWith('$messageId:')) e.value,
    ];
  }

  Future<void> recordUsage(String messageId, List<DocUsage> used) async {
    if (used.isEmpty) return;
    final map = _usageMap();
    for (var i = 0; i < used.length; i++) {
      map['$messageId:$i'] = used[i];
    }
    while (map.length > usageCap) {
      map.remove(map.keys.first);
    }
    await _store?.setString('doc_usage', jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))));
    notifyListeners();
  }

  Future<void> keep(String convId, List<Attachment> attachments) async {
    final current = [...list(convId)];
    var changed = false;
    for (final a in attachments) {
      if (current.any((d) => d.id == a.id)) continue;
      final pending = _pending.remove(a.id);
      if (a.searched && pending != null) {
        current.add(pending);
        changed = true;
      } else if (a.kind == AttachmentKind.text && a.text != null && !a.searched) {
        current.add(SearchDoc(
          id: a.id,
          name: a.name,
          mime: a.mime,
          size: a.size,
          format: 'file',
          raw: a.text,
          searchable: false,
        ));
        changed = true;
      }
    }
    if (!changed) return;
    final kept = current.length > filesPerChat ? current.sublist(current.length - filesPerChat) : current;
    _cache[convId] = kept;
    await _save(convId);
    notifyListeners();
  }

  Future<void> remove(String convId, String id) async {
    _cache[convId] = list(convId).where((d) => d.id != id).toList();
    await _save(convId);
    notifyListeners();
  }

  Future<void> forget(String convId) async {
    _cache.remove(convId);
    await _store?.remove('docs_$convId');
    notifyListeners();
  }

  void dropPending(String id) => _pending.remove(id);

  List<SandboxFile> files(String? convId) {
    if (convId == null) return const [];
    return [
      for (final d in list(convId))
        if (d.raw != null)
          SandboxFile(name: d.name, text: d.raw)
        else
          SandboxFile(
            name: d.name.toLowerCase().endsWith('.txt') ? d.name : '${d.name}.txt',
            text: d.chunks.map((c) => c.t).join('\n\n'),
          ),
    ];
  }

  static String _ext(String name) {
    final at = name.lastIndexOf('.');
    return at == -1 ? '' : name.substring(at + 1).toLowerCase();
  }

  static bool handles(String name, int size, {required bool textual, required int textMax}) {
    final ext = _ext(name);
    if (ext == 'pdf' || ext == 'docx') return true;
    return textual && size > textMax;
  }

  static String label(SearchDoc doc) => doc.paged
      ? t('{n} pages · searched', {'n': doc.pages})
      : t('{n} parts · searched', {'n': doc.pages});

  Attachment _attachDoc(SearchDoc doc) {
    _pending[doc.id] = doc;
    return Attachment(
      id: doc.id,
      kind: AttachmentKind.text,
      name: doc.name,
      mime: doc.mime,
      size: doc.size,
      searched: true,
      label: label(doc),
    );
  }

  static Attachment _inline(String id, String name, String mime, int size, String text) => Attachment(
        id: id,
        kind: AttachmentKind.text,
        name: name,
        mime: mime,
        size: size,
        lines: '\n'.allMatches(text).length + 1,
        text: text,
      );

  Future<Attachment> intake(String name, Uint8List bytes) async {
    if (bytes.length > fileMaxBytes) {
      throw DocProblem(t('That document is too large — 30 MB is the limit.'));
    }
    final id = bytesToHex(randomBytes(8));
    final ext = _ext(name);
    if (ext == 'pdf') {
      if (!SandboxHost.supported) throw DocProblem(t('PDFs can be read in the Android and iOS apps.'));
      ({List<String> pages, List<({String title, int page})> headings}) got;
      try {
        got = await SandboxHost.instance.pdfText(bytes);
      } catch (_) {
        throw DocProblem(t('That PDF could not be read. It may be damaged or password-protected.'));
      }
      if (!got.pages.any((p) => p.trim().isNotEmpty)) {
        throw DocProblem(t('That PDF has no text in it — it looks like a scan, which cannot be read on this device.'));
      }
      final built = DocSearch.fromPages(
        id: id,
        name: name,
        mime: 'application/pdf',
        size: bytes.length,
        pages: got.pages,
        headings: [for (final h in got.headings) DocHeading(h.title, h.page)],
      );
      if (built.doc != null) return _attachDoc(built.doc!);
      return _inline(id, name, 'application/pdf', bytes.length, built.text ?? '');
    }
    if (ext == 'docx') {
      final xml = kIsWeb ? null : unzipEntry(bytes, 'word/document.xml');
      if (xml == null) throw DocProblem(t('That Word document could not be read.'));
      final text = DocSearch.docxText(utf8.decode(xml, allowMalformed: true));
      if (text.trim().isEmpty) throw DocProblem(t('That Word document has no text in it.'));
      if (text.length > DocSearch.docMaxChars) {
        throw DocProblem(t('That document is too large to read on this device — 8 MB of text is the limit.'));
      }
      const mime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      if (DocSearch.wireCost(text) <= DocSearch.inlineMax) return _inline(id, name, mime, bytes.length, text);
      return _attachDoc(DocSearch.fromText(id: id, name: name, text: text, mime: mime, size: bytes.length));
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      throw DocProblem(t('That file could not be read as text.'));
    }
    if (text.length > DocSearch.docMaxChars) {
      throw DocProblem(t('That document is too large to read on this device — 8 MB of text is the limit.'));
    }
    return _attachDoc(DocSearch.fromText(id: id, name: name, text: text, size: bytes.length));
  }

  static Uint8List? unzipEntry(Uint8List bytes, String wanted,
      {int maxBytes = entryMaxBytes}) {
    if (bytes.length < 22) return null;
    final view = ByteData.sublistView(bytes);
    var end = -1;
    final floor = bytes.length - 65557 < 0 ? 0 : bytes.length - 65557;
    for (var i = bytes.length - 22; i >= floor; i--) {
      if (view.getUint32(i, Endian.little) == 0x06054b50) {
        end = i;
        break;
      }
    }
    if (end < 0) return null;
    final count = view.getUint16(end + 10, Endian.little);
    var at = view.getUint32(end + 16, Endian.little);
    for (var k = 0; k < count && at + 46 <= bytes.length; k++) {
      if (view.getUint32(at, Endian.little) != 0x02014b50) break;
      final method = view.getUint16(at + 10, Endian.little);
      final size = view.getUint32(at + 20, Endian.little);
      final full = view.getUint32(at + 24, Endian.little);
      final nameLen = view.getUint16(at + 28, Endian.little);
      final extraLen = view.getUint16(at + 30, Endian.little);
      final commentLen = view.getUint16(at + 32, Endian.little);
      final local = view.getUint32(at + 42, Endian.little);
      if (at + 46 + nameLen > bytes.length) return null;
      final entry = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLen), allowMalformed: true);
      if (entry == wanted) {
        if (full > maxBytes) throw DocProblem(t('That document is too large to read on this device.'));
        if (local + 30 > bytes.length) return null;
        if (view.getUint32(local, Endian.little) != 0x04034b50) return null;
        final start = local + 30 + view.getUint16(local + 26, Endian.little) + view.getUint16(local + 28, Endian.little);
        if (start > bytes.length || start + size > bytes.length) return null;
        final data = Uint8List.sublistView(bytes, start, start + size);
        if (method == 0) {
          if (size > maxBytes) throw DocProblem(t('That document is too large to read on this device.'));
          return Uint8List.fromList(data);
        }
        if (method == 8) return inflateCapped(data, maxBytes);
        return null;
      }
      at += 46 + nameLen + extraLen + commentLen;
    }
    return null;
  }

  static Uint8List? inflateCapped(Uint8List data, int maxBytes) {
    final out = _CappedSink(maxBytes);
    try {
      final sink = ZLibDecoder(raw: true).startChunkedConversion(out);
      const step = 16 * 1024;
      for (var i = 0; i < data.length; i += step) {
        sink.add(Uint8List.sublistView(data, i, i + step > data.length ? data.length : i + step));
      }
      sink.close();
    } on _TooLarge {
      throw DocProblem(t('That document is too large to read on this device.'));
    } catch (_) {
      return null;
    }
    return out.bytes.takeBytes();
  }
}

class _TooLarge implements Exception {
  const _TooLarge();
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.max);

  final int max;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > max) throw const _TooLarge();
    bytes.add(data);
  }

  @override
  void close() {}
}
