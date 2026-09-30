import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/crypto/schnorr.dart' as schnorr;
import '../models/nostr_event.dart';

const String kZapstoreRelay = 'wss://relay.zapstore.dev';

const int kZapstoreAssetKind = 3063;

const String kAndroidAppId = 'ai.nymbot';

const String kPlayInstaller = 'com.android.vending';

enum BuildIntegrityState {
  verified,
  mismatch,
  storeRepackaged,
  provenanceUnreachable,
  notPublished,
  unsupported,
}

@immutable
class NativeBuildInfo {
  const NativeBuildInfo({
    this.packageName,
    this.apkSha256,
    this.splitCount = 0,
    this.signerSha256,
    this.installer,
    this.versionName,
    this.versionCode,
  });

  factory NativeBuildInfo.fromMap(Map<Object?, Object?> map) {
    String? str(String key) {
      final v = map[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final code = map['versionCode'];
    return NativeBuildInfo(
      packageName: str('packageName'),
      apkSha256: str('apkSha256')?.toLowerCase(),
      splitCount: map['splitCount'] is int ? map['splitCount'] as int : 0,
      signerSha256: str('signerSha256')?.toLowerCase(),
      installer: str('installer'),
      versionName: str('versionName'),
      versionCode: code is int ? code : (code is num ? code.toInt() : null),
    );
  }

  final String? packageName;

  final String? apkSha256;

  final int splitCount;

  final String? signerSha256;

  final String? installer;

  final String? versionName;
  final int? versionCode;

  bool get isStoreRepackaged =>
      installer == kPlayInstaller || splitCount > 0;
}

@immutable
class PublishedBuild {
  const PublishedBuild({
    required this.version,
    this.versionCode,
    this.apkSha256 = '',
    this.certSha256,
    this.platform,
  });

  static PublishedBuild? fromEvent(NostrEvent event, {required String appId}) {
    if (event.kind != kZapstoreAssetKind) return null;
    String? first(String name) {
      for (final t in event.tags) {
        if (t.length > 1 && t[0] == name) return t[1];
      }
      return null;
    }

    if (first('i') != appId) return null;
    final x = first('x')?.toLowerCase();
    if (x == null || x.isEmpty) return null;
    final code = int.tryParse(first('version_code') ?? '');
    return PublishedBuild(
      version: first('version') ?? '',
      versionCode: code,
      apkSha256: x,
      certSha256: first('apk_certificate_hash')?.toLowerCase(),
      platform: first('f'),
    );
  }

  final String version;
  final int? versionCode;

  final String apkSha256;

  final String? certSha256;

  final String? platform;
}

@immutable
class BuildIntegrityResult {
  const BuildIntegrityResult({
    required this.state,
    this.info,
    this.published,
  });

  final BuildIntegrityState state;
  final NativeBuildInfo? info;
  final PublishedBuild? published;

  bool get isVerified => state == BuildIntegrityState.verified;
}

BuildIntegrityResult describeBuildIntegrity({
  required NativeBuildInfo? info,
  required bool provenanceOk,
  required List<PublishedBuild> builds,
}) {
  if (info == null || info.apkSha256 == null) {
    return const BuildIntegrityResult(state: BuildIntegrityState.unsupported);
  }
  if (info.isStoreRepackaged) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.storeRepackaged, info: info);
  }
  if (!provenanceOk) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.provenanceUnreachable, info: info);
  }

  for (final build in builds) {
    if (build.apkSha256 == info.apkSha256) {
      return BuildIntegrityResult(
        state: BuildIntegrityState.verified,
        info: info,
        published: build,
      );
    }
  }

  final sameVersion = builds
      .where((b) =>
          (b.version.isNotEmpty && b.version == info.versionName) ||
          (b.versionCode != null && b.versionCode == info.versionCode))
      .toList();
  if (sameVersion.isEmpty) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.notPublished, info: info);
  }
  return BuildIntegrityResult(
    state: BuildIntegrityState.mismatch,
    info: info,
    published: sameVersion.first,
  );
}

List<PublishedBuild> zapstoreAssets(
  Iterable<NostrEvent> events, {
  required String publisherPubkey,
  String appId = kAndroidAppId,
}) {
  final out = <PublishedBuild>[];
  for (final event in events) {
    if (event.pubkey != publisherPubkey) continue;
    try {
      if (!schnorr.verifyEvent(event)) continue;
    } catch (_) {
      continue;
    }
    final build = PublishedBuild.fromEvent(event, appId: appId);
    if (build != null) out.add(build);
  }
  return out;
}

typedef ZapstoreSocketFactory = WebSocketChannel Function(Uri url);

Future<List<NostrEvent>> fetchZapstoreAssets({
  required String publisherPubkey,
  String appId = kAndroidAppId,
  String relay = kZapstoreRelay,
  ZapstoreSocketFactory? socketFactory,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final open = socketFactory ?? WebSocketChannel.connect;
  WebSocketChannel? channel;
  try {
    channel = open(Uri.parse(relay));
    final subId = 'nymbot-bi-${DateTime.now().microsecondsSinceEpoch}';
    final events = <NostrEvent>[];
    final done = Completer<void>();

    final sub = channel.stream.listen(
      (raw) {
        try {
          final msg = jsonDecode(raw as String);
          if (msg is! List || msg.isEmpty) return;
          if (msg[0] == 'EVENT' && msg.length > 2 && msg[1] == subId) {
            events.add(
                NostrEvent.fromJson(msg[2] as Map<String, dynamic>));
          } else if (msg[0] == 'EOSE' && msg.length > 1 && msg[1] == subId) {
            if (!done.isCompleted) done.complete();
          }
        } catch (_) {}
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );

    channel.sink.add(jsonEncode([
      'REQ',
      subId,
      {
        'kinds': [kZapstoreAssetKind],
        'authors': [publisherPubkey],
        '#i': [appId],
        'limit': 50,
      }
    ]));

    await done.future.timeout(timeout, onTimeout: () {});
    await sub.cancel();
    return events;
  } catch (_) {
    return const [];
  } finally {
    try {
      await channel?.sink.close();
    } catch (_) {}
  }
}

class BuildIntegrityService {
  BuildIntegrityService({
    MethodChannel? channel,
    this.relay = kZapstoreRelay,
    this.appId = kAndroidAppId,
    this.socketFactory,
    required this.publisherPubkey,
  }) : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'ai.nymbot/build_integrity';

  final MethodChannel _channel;
  final String relay;
  final String appId;
  final ZapstoreSocketFactory? socketFactory;

  final String publisherPubkey;

  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  bool get isConfigured => publisherPubkey.length == 64;

  Future<NativeBuildInfo?> measure() async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('inspect');
      return raw == null ? null : NativeBuildInfo.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  Future<List<PublishedBuild>> fetchPublished() async {
    final events = await fetchZapstoreAssets(
      publisherPubkey: publisherPubkey,
      appId: appId,
      relay: relay,
      socketFactory: socketFactory,
    );
    return zapstoreAssets(events,
        publisherPubkey: publisherPubkey, appId: appId);
  }

  Future<BuildIntegrityResult> run() async {
    if (!isSupported) {
      return const BuildIntegrityResult(state: BuildIntegrityState.unsupported);
    }
    final info = await measure();
    if (info != null && info.isStoreRepackaged) {
      return BuildIntegrityResult(
          state: BuildIntegrityState.storeRepackaged, info: info);
    }
    if (!isConfigured) {
      return BuildIntegrityResult(
          state: BuildIntegrityState.provenanceUnreachable, info: info);
    }
    final builds = await fetchPublished();
    return describeBuildIntegrity(
      info: info,
      provenanceOk: builds.isNotEmpty,
      builds: builds,
    );
  }
}
