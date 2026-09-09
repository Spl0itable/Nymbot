import 'dart:async';

import '../core/crypto/bech32_codec.dart';
import '../features/i18n/i18n.dart';
import '../models/nostr_event.dart';
import '../models/workspace.dart';
import 'relay_pool.dart';

/// Repositories announced on Nostr (NIP-34).
class Ngit {
  const Ngit(this.relays);

  final RelayPool relays;

  static const int kindRepo = 30617;
  static const int kindState = 30618;

  /// The relays an address does not name.
  static const List<String> fallbackRelays = [
    'wss://relay.ngit.dev',
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
  ];

  static String _withScheme(String host) =>
      RegExp(r'^wss?://', caseSensitive: false).hasMatch(host)
          ? host
          : 'wss://$host';

  static String? _toPubkey(String who) {
    if (RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(who)) {
      return who.toLowerCase();
    }
    if (who.toLowerCase().startsWith('npub1')) {
      try {
        return decodeNpub(who);
      } catch (_) {
        return null;
      }
    }
    // A NIP-05 name needs a lookup this service does not do; the caller is told
    // what is missing rather than handed a silent failure.
    return null;
  }

  /// Reads whatever somebody pasted: an naddr, a `nostr://` clone URL, or the
  /// npub-and- identifier the URL is made of.
  static NgitAddress? parseAddress(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;

    final bare = RegExp(r'^(?:nostr:)?(naddr1[0-9a-z]+)$', caseSensitive: false)
        .firstMatch(text);
    if (bare != null) return _fromNaddr(bare.group(1)!);

    final wrapped =
        RegExp(r'^nostr://(naddr1[0-9a-z]+)/?$', caseSensitive: false)
            .firstMatch(text);
    if (wrapped != null) return _fromNaddr(wrapped.group(1)!);

    final url = RegExp(r'^nostr://(.+)$', caseSensitive: false).firstMatch(text);
    if (url != null) {
      final parts = url
          .group(1)!
          .split('/')
          .where((p) => p.isNotEmpty)
          .map(Uri.decodeComponent)
          .toList();
      if (parts.length < 2) return null;
      final pubkey = _toPubkey(parts.first);
      if (pubkey == null) return null;
      return NgitAddress(
        pubkey: pubkey,
        identifier: parts.last,
        relays: parts.length > 2 ? [_withScheme(parts[1])] : const [],
      );
    }
    return null;
  }

  static NgitAddress? _fromNaddr(String naddr) {
    final ref = decodeNostrRef(naddr);
    if (ref == null || ref.kind != NostrRefKind.addr) return null;
    if (ref.eventKind != kindRepo) return null;
    return NgitAddress(
      pubkey: ref.pubkey,
      identifier: ref.identifier,
      relays: ref.relays.map(_withScheme).toList(),
    );
  }

  /// Which forge a clone URL points at, and what to call the repo there.
  static NgitForge? forgeFor(String cloneUrl) {
    Uri parsed;
    try {
      parsed = Uri.parse(cloneUrl.replaceFirst(RegExp(r'^git\+'), ''));
    } catch (_) {
      return null;
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
    final host = parsed.host.toLowerCase();
    if (host.isEmpty) return null;
    final path = parsed.path
        .replaceAll(RegExp(r'^/+|/+$'), '')
        .replaceFirst(RegExp(r'\.git$', caseSensitive: false), '');
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;

    if (host == 'github.com' || host == 'www.github.com') {
      return NgitForge(
          provider: 'github', host: 'github.com', repo: segments.take(2).join('/'));
    }
    if (host == 'gitlab.com' || host == 'www.gitlab.com') {
      // GitLab allows nested groups, which the worker accepts up to four.
      return NgitForge(
          provider: 'gitlab', host: 'gitlab.com', repo: segments.take(4).join('/'));
    }
    if (host == 'codeberg.org') {
      return NgitForge(
          provider: 'gitea', host: 'codeberg.org', repo: segments.take(2).join('/'));
    }
    // Self-hosted.
    final provider = host.contains('gitlab') ? 'gitlab' : 'gitea';
    return NgitForge(
      provider: provider,
      host: host,
      repo: segments.take(provider == 'gitlab' ? 4 : 2).join('/'),
      guessed: true,
    );
  }

  static List<String> _tagValues(NostrEvent event, String name) {
    final out = <String>[];
    for (final tag in event.tags) {
      if (tag.isEmpty || tag[0] != name) continue;
      for (var i = 1; i < tag.length; i++) {
        if (tag[i].isNotEmpty) out.add(tag[i]);
      }
    }
    return out;
  }

  static String _firstTag(NostrEvent event, String name) {
    final all = _tagValues(event, name);
    return all.isEmpty ? '' : all.first;
  }

  static NostrEvent? _newest(List<NostrEvent> events) {
    NostrEvent? best;
    for (final ev in events) {
      if (best == null || ev.createdAt > best.createdAt) best = ev;
    }
    return best;
  }

  /// Looks an announcement up and reads everything off it, or throws with a
  /// reason a person can act on.
  Future<NgitRepo> resolve(String input) async {
    final address = parseAddress(input);
    if (address == null) {
      throw NgitFailure(t('That is not a repository address. Paste an naddr, or a nostr:// URL from the repository page.'));
    }
    final where = {...address.relays, ...fallbackRelays}.toList();
    final filter = {
      'kinds': [kindRepo],
      'authors': [address.pubkey],
      '#d': [address.identifier],
      'limit': 4,
    };
    // Both: the pool for anything mirrored to the usual relays, and the
    // announcement's own for anything that is not.
    final events = [
      ...await relays.fetch(filter, timeout: const Duration(seconds: 5)),
      ...await relays.fetchFrom(where, filter, timeout: const Duration(seconds: 6)),
    ];
    final announcement = _newest(events);
    if (announcement == null) {
      throw NgitFailure(t('No repository announcement was found at that address. It may be on relays this app is not connected to.'));
    }

    final clone = _tagValues(announcement, 'clone');
    final announcedRelays = _tagValues(announcement, 'relays');
    NgitForge? forge;
    for (final url in clone) {
      final got = forgeFor(url);
      if (got == null) continue;
      forge = got;
      if (!got.guessed) break;
    }

    final state = await _state(address, announcedRelays);
    return NgitRepo(
      address: address,
      naddr: naddrFor(address),
      repoId: address.identifier,
      owner: address.pubkey,
      name: _firstTag(announcement, 'name').isNotEmpty
          ? _firstTag(announcement, 'name')
          : address.identifier,
      description: _firstTag(announcement, 'description'),
      web: _tagValues(announcement, 'web'),
      clone: clone,
      relays: announcedRelays,
      maintainers: _tagValues(announcement, 'maintainers'),
      euc: announcement.tags
              .where((tag) => tag.length > 2 && tag[0] == 'r' && tag[2] == 'euc')
              .map((tag) => tag[1])
              .firstOrNull ??
          '',
      forge: forge,
      head: state.head,
      refs: state.refs,
    );
  }

  /// The branch the repository says is current, from its kind-30618.
  Future<({String head, Map<String, String> refs})> _state(
      NgitAddress address, List<String> extraRelays) async {
    final where = {...address.relays, ...extraRelays, ...fallbackRelays}.toList();
    final filter = {
      'kinds': [kindState],
      'authors': [address.pubkey],
      '#d': [address.identifier],
      'limit': 4,
    };
    List<NostrEvent> events;
    try {
      events = [
        ...await relays.fetch(filter, timeout: const Duration(seconds: 4)),
        ...await relays.fetchFrom(where, filter, timeout: const Duration(seconds: 5)),
      ];
    } catch (_) {
      events = const [];
    }
    final state = _newest(events);
    if (state == null) return (head: '', refs: <String, String>{});
    final refs = <String, String>{};
    for (final tag in state.tags) {
      if (tag.length > 1 && tag[0].startsWith('refs/') && tag[1].isNotEmpty) {
        refs[tag[0]] = tag[1];
      }
    }
    final named = RegExp(r'^ref:\s*refs/heads/(.+)$')
        .firstMatch(_firstTag(state, 'HEAD'));
    return (head: named?.group(1)?.trim() ?? '', refs: refs);
  }

  static String naddrFor(NgitAddress address) {
    try {
      return encodeNaddr(
        identifier: address.identifier,
        pubkey: address.pubkey,
        kind: kindRepo,
        relays: address.relays.take(3).toList(),
      );
    } catch (_) {
      return '';
    }
  }
}

class NgitAddress {
  const NgitAddress({
    required this.pubkey,
    required this.identifier,
    this.relays = const [],
  });

  final String pubkey;
  final String identifier;
  final List<String> relays;
}

class NgitForge {
  const NgitForge({
    required this.provider,
    required this.host,
    required this.repo,
    this.guessed = false,
  });

  final String provider;
  final String host;
  final String repo;

  /// True when the provider was inferred from a self-hosted hostname rather than known.
  final bool guessed;
}

class NgitRepo {
  const NgitRepo({
    required this.address,
    required this.naddr,
    required this.repoId,
    required this.owner,
    required this.name,
    required this.description,
    required this.web,
    required this.clone,
    required this.relays,
    required this.maintainers,
    required this.euc,
    required this.forge,
    required this.head,
    required this.refs,
  });

  final NgitAddress address;
  final String naddr;
  final String repoId;
  final String owner;
  final String name;
  final String description;
  final List<String> web;
  final List<String> clone;
  final List<String> relays;
  final List<String> maintainers;
  final String euc;
  final NgitForge? forge;
  final String head;
  final Map<String, String> refs;

  NgitOrigin get origin => NgitOrigin(
        naddr: naddr,
        repoId: repoId,
        name: name,
        web: web.isEmpty ? '' : web.first,
        relays: relays.take(6).toList(),
        maintainers: maintainers.take(8).toList(),
        euc: euc,
      );
}

class NgitFailure implements Exception {
  NgitFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
