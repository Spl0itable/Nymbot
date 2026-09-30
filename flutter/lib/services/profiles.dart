import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/crypto/schnorr.dart' as schnorr;
import '../features/nym_avatar.dart';
import '../models/nostr_event.dart';
import '../state/store.dart';
import 'relay_pool.dart';
import 'storage_sync.dart';

class NostrProfile {
  const NostrProfile({
    this.name = '',
    this.about = '',
    this.nip05 = '',
    this.picture = '',
    this.lud16 = '',
    this.fetchedAt = 0,
  });

  final String name;
  final String about;
  final String nip05;
  final String picture;
  final String lud16;
  final int fetchedAt;

  bool get isEmpty => name.isEmpty && picture.isEmpty;

  Map<String, dynamic> toJson() => {
        'name': name,
        'about': about,
        'nip05': nip05,
        'picture': picture,
        'lud16': lud16,
        'fetchedAt': fetchedAt,
      };

  static NostrProfile fromJson(Map<String, dynamic> j) => NostrProfile(
        name: j['name'] as String? ?? '',
        about: j['about'] as String? ?? '',
        nip05: j['nip05'] as String? ?? '',
        picture: j['picture'] as String? ?? '',
        lud16: j['lud16'] as String? ?? '',
        fetchedAt: (j['fetchedAt'] as num?)?.toInt() ?? 0,
      );
}

/// The published kind-0 profile when there is one, else the generated nym.
class DisplayIdentity {
  const DisplayIdentity({
    required this.pubkey,
    required this.name,
    required this.nip05,
    required this.picture,
    required this.hasProfile,
  });

  final String pubkey;
  final String name;
  final String nip05;
  final String picture;
  final bool hasProfile;
}

class Profiles extends ChangeNotifier {
  Profiles(this._store, this._relays, this._storage);

  static const _maxAge = Duration(hours: 6);
  static final _safeImage = RegExp(r'^https://[^\s"' "'" r'<>]+$');

  final Store _store;
  final RelayPool _relays;
  final StorageSync _storage;
  final Map<String, NostrProfile> _cache = {};
  final Set<String> _inflight = {};
  bool _loaded = false;

  void _hydrate() {
    if (_loaded) return;
    _loaded = true;
    final raw = _store.getString('profiles');
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      j.forEach((k, v) {
        if (v is Map<String, dynamic>) _cache[k] = NostrProfile.fromJson(v);
      });
    } catch (_) {}
  }

  Future<void> _persist() {
    final j = <String, dynamic>{};
    _cache.forEach((k, v) => j[k] = v.toJson());
    return _store.setString('profiles', jsonEncode(j));
  }

  DisplayIdentity of(String pubkey) {
    _hydrate();
    final hit = _cache[pubkey];
    return DisplayIdentity(
      pubkey: pubkey,
      name: (hit != null && hit.name.isNotEmpty) ? hit.name : NymIdentity.name(pubkey),
      nip05: hit?.nip05 ?? '',
      picture: hit?.picture ?? '',
      hasProfile: hit != null && !hit.isEmpty,
    );
  }

  /// The D1 mirror is asked before relays; neither is trusted, the signed event decides.
  Future<NostrProfile?> _fromD1(String pubkey) async {
    Map<String, NostrEvent>? events;
    try {
      events = await _storage.profileEvents([pubkey]);
    } catch (_) {
      return null;
    }
    final event = events?[pubkey];
    if (event == null || !_authentic(event, pubkey)) return null;
    return _read(event.content);
  }

  bool _authentic(NostrEvent event, String pubkey) {
    if (event.kind != 0 || event.pubkey != pubkey) return false;
    if (event.id.isEmpty) return false;
    return schnorr.verifyEvent(event);
  }

  /// Only the relay half needs a socket; the mirror is a single worker request.
  Future<void> _whenConnected() async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (_relays.connected == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Reads kind 0 from the D1 mirror, then relays; [mirrorOnly] stops at the mirror and does not cache a miss.
  Future<void> load(String pubkey,
      {bool force = false, bool mirrorOnly = false}) async {
    _hydrate();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey)) return;
    final hit = _cache[pubkey];
    final age = DateTime.now().millisecondsSinceEpoch - (hit?.fetchedAt ?? 0);
    if (!force && hit != null && age < _maxAge.inMilliseconds) return;
    if (_inflight.contains(pubkey)) return;
    _inflight.add(pubkey);

    try {
      var parsed = await _fromD1(pubkey);
      if (parsed == null) {
        if (mirrorOnly) return;
        await _whenConnected();
        final events = await _relays.fetch(
          {'kinds': [0], 'authors': [pubkey], 'limit': 4},
          timeout: const Duration(seconds: 4),
        );
        final mine = events.where((e) => _authentic(e, pubkey)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        parsed = mine.isEmpty ? null : _read(mine.first.content);
      }
      _cache[pubkey] = parsed ??
          NostrProfile(fetchedAt: DateTime.now().millisecondsSinceEpoch);
      await _persist();
      notifyListeners();
    } catch (_) {
      // A slow relay is not a visible failure; the generated nym is a complete fallback.
    } finally {
      _inflight.remove(pubkey);
    }
  }

  NostrProfile? _read(String content) {
    Map<String, dynamic> meta;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) return null;
      meta = decoded;
    } catch (_) {
      return null;
    }
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = meta[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return '';
    }

    String cap(String v, int n) => v.length > n ? v.substring(0, n) : v;
    final picture = pick(['picture', 'image']);
    return NostrProfile(
      name: cap(pick(['display_name', 'displayName', 'name']), 60),
      about: cap(pick(['about']), 400),
      nip05: cap(pick(['nip05']), 120),
      picture: _safeImage.hasMatch(picture) ? picture : '',
      lud16: cap(pick(['lud16', 'lud06']), 120),
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void forget(String pubkey) {
    _cache.remove(pubkey);
    _persist();
    notifyListeners();
  }
}
