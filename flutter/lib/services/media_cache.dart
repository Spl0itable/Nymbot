import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class MediaCache {
  MediaCache({
    Future<Directory> Function()? directory,
    http.Client? client,
    DateTime Function()? now,
    this.maxAge = const Duration(days: 7),
    this.immutableAge = const Duration(days: 30),
    this.revalidateAfter = const Duration(days: 1),
    this.maxEntries = 600,
    this.maxBytes = 100 * 1024 * 1024,
    this.entryMaxBytes = 25 * 1024 * 1024,
  })  : _directory = directory ?? _appCacheDirectory,
        _client = client,
        _now = now ?? DateTime.now;

  static MediaCache instance = MediaCache();

  final Duration maxAge;
  final Duration immutableAge;
  final Duration revalidateAfter;
  final int maxEntries;
  final int maxBytes;
  final int entryMaxBytes;

  final Future<Directory> Function() _directory;
  final http.Client? _client;
  final DateTime Function() _now;
  Future<Directory>? _dir;
  final Map<String, Future<Uint8List>> _inflight = {};
  int _generation = 0;
  bool _pruned = false;
  Future<void>? _pruning;
  bool _pruneAgain = false;

  static final _contentHash =
      RegExp(r'/([0-9a-f]{64})(?:\.[a-z0-9]{1,8})?$', caseSensitive: false);
  static final _mediaType = RegExp(r'^(?:image|video|audio)/', caseSensitive: false);

  static Future<Directory> _appCacheDirectory() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/nymbot-media');

  static String keyOf(String url) => sha256.convert(utf8.encode(url)).toString();

  static String contentHashOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return '';
    final m = _contentHash.firstMatch(u.path);
    if (m != null) return m.group(1)!.toLowerCase();
    final inner = u.path == '/api/proxy' ? u.queryParameters['url'] : null;
    if (inner == null || u.queryParameters.containsKey('action')) return '';
    final target = Uri.tryParse(inner);
    final n = target == null ? null : _contentHash.firstMatch(target.path);
    return n == null ? '' : n.group(1)!.toLowerCase();
  }

  Future<Directory?> _root() async {
    try {
      final dir = await (_dir ??= _directory());
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      _dir = null;
      return null;
    }
  }

  Future<File?> _entry(String url) async {
    final dir = await _root();
    if (dir == null) return null;
    final key = keyOf(url);
    for (final suffix in const ['i', 'm']) {
      final f = File('${dir.path}/$key.$suffix');
      if (await f.exists()) return f;
    }
    return null;
  }

  Duration _limit(File f) => f.path.endsWith('.i') ? immutableAge : maxAge;

  Future<T> load<T>(String url, Future<T> Function(Uint8List bytes) use,
      {void Function(int received, int? total)? progress}) async {
    if (!_pruned) {
      _pruned = true;
      unawaited(trim());
    }
    File? hit;
    try {
      hit = await _entry(url);
    } catch (_) {
      hit = null;
    }
    Uint8List? stale;
    if (hit != null) {
      try {
        final stamp = await hit.lastModified();
        final age = _now().difference(stamp);
        final bytes = await hit.readAsBytes();
        if (age < _limit(hit) && !age.isNegative) {
          final out = await use(bytes);
          if (!hit.path.endsWith('.i') && age > revalidateAfter) {
            unawaited(_refresh(url));
          }
          return out;
        }
        stale = bytes;
      } catch (_) {
        await _drop(hit);
      }
    }
    final int generation = _generation;
    final Uint8List bytes;
    try {
      bytes = await _fetch(url, progress);
    } catch (_) {
      if (stale != null) return use(stale);
      rethrow;
    }
    final out = await use(bytes);
    await _store(url, bytes, generation);
    return out;
  }

  Future<void> _refresh(String url) async {
    final int generation = _generation;
    try {
      final bytes = await _fetch(url, null);
      await ui.instantiateImageCodec(bytes).then((c) => c.dispose());
      await _store(url, bytes, generation);
    } catch (_) {}
  }

  Future<Uint8List> _fetch(String url, void Function(int, int?)? progress) {
    final running = _inflight[url];
    if (running != null) return running;
    final run = _download(url, progress).whenComplete(() {
      _inflight.remove(url);
    });
    _inflight[url] = run;
    return run;
  }

  Future<Uint8List> _download(String url, void Function(int, int?)? progress) async {
    final client = _client ?? http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      final type = resp.headers['content-type'] ?? '';
      if (resp.statusCode != 200 || !_mediaType.hasMatch(type)) {
        unawaited(resp.stream.listen(null).cancel());
        throw MediaCacheException(url, resp.statusCode, type);
      }
      final total = resp.contentLength;
      if (total != null && total > entryMaxBytes) {
        unawaited(resp.stream.listen(null).cancel());
        throw MediaCacheException(url, resp.statusCode, type);
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.stream) {
        builder.add(chunk);
        if (builder.length > entryMaxBytes) {
          throw MediaCacheException(url, resp.statusCode, type);
        }
        progress?.call(builder.length, total);
      }
      return builder.takeBytes();
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<void> _store(String url, Uint8List bytes, int generation) async {
    if (generation != _generation || bytes.isEmpty || bytes.length > entryMaxBytes) return;
    try {
      final dir = await _root();
      if (dir == null || generation != _generation) return;
      final hash = contentHashOf(url);
      final immutable = hash.isNotEmpty && sha256.convert(bytes).toString() == hash;
      final key = keyOf(url);
      final target = File('${dir.path}/$key.${immutable ? 'i' : 'm'}');
      final other = File('${dir.path}/$key.${immutable ? 'm' : 'i'}');
      final temp = File('${dir.path}/$key.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.setLastModified(_now());
      if (generation != _generation) {
        await _drop(temp);
        return;
      }
      await temp.rename(target.path);
      await _drop(other);
      if (generation != _generation) {
        await _drop(target);
        return;
      }
      await trim();
    } catch (_) {}
  }

  Future<void> _drop(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> trim() {
    final running = _pruning;
    if (running != null) {
      _pruneAgain = true;
      return running;
    }
    final run = () async {
      try {
        do {
          _pruneAgain = false;
          await _prune();
        } while (_pruneAgain);
      } catch (_) {}
    }();
    _pruning = run.whenComplete(() {
      _pruning = null;
    });
    return _pruning!;
  }

  Future<void> _prune() async {
    final dir = await _root();
    if (dir == null) return;
    final now = _now();
    final live = <({File file, DateTime at, int size})>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final path = e.path;
      if (path.endsWith('.tmp')) {
        final stat = await e.stat();
        if (now.difference(stat.modified) > const Duration(hours: 1)) await _drop(e);
        continue;
      }
      if (!path.endsWith('.i') && !path.endsWith('.m')) continue;
      final stat = await e.stat();
      final age = now.difference(stat.modified);
      if (age.isNegative || age >= _limit(e)) {
        await _drop(e);
        continue;
      }
      live.add((file: e, at: stat.modified, size: stat.size));
    }
    live.sort((a, b) => a.at.compareTo(b.at));
    var count = live.length;
    var bytes = live.fold<int>(0, (n, x) => n + x.size);
    for (final x in live) {
      if (count <= maxEntries && bytes <= maxBytes) break;
      await _drop(x.file);
      count--;
      bytes -= x.size;
    }
  }

  Future<void> clear() async {
    _generation++;
    _inflight.clear();
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    } catch (_) {}
    try {
      final dir = await (_dir ??= _directory());
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      _dir = null;
    }
  }
}

class MediaCacheException implements Exception {
  MediaCacheException(this.url, this.status, this.type);

  final String url;
  final int status;
  final String type;

  @override
  String toString() => 'MediaCacheException($status, $type)';
}

@immutable
class CachedMediaImage extends ImageProvider<CachedMediaImage> {
  const CachedMediaImage(this.url, {this.scale = 1.0, this.cache});

  final String url;
  final double scale;
  final MediaCache? cache;

  @override
  Future<CachedMediaImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedMediaImage>(this);

  @override
  ImageStreamCompleter loadImage(CachedMediaImage key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, chunks, decode),
      chunkEvents: chunks.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedMediaImage>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _load(CachedMediaImage key, StreamController<ImageChunkEvent> chunks,
      ImageDecoderCallback decode) async {
    try {
      return await (key.cache ?? MediaCache.instance).load<ui.Codec>(
        key.url,
        (bytes) async => decode(await ui.ImmutableBuffer.fromUint8List(bytes)),
        progress: (got, total) {
          if (!chunks.isClosed) {
            chunks.add(ImageChunkEvent(
                cumulativeBytesLoaded: got, expectedTotalBytes: total));
          }
        },
      );
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      unawaited(chunks.close());
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CachedMediaImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => '${objectRuntimeType(this, 'CachedMediaImage')}("$url", scale: $scale)';
}
