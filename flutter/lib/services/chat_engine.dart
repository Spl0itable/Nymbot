import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../config.dart';
import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../models/bot.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/nostr_event.dart';
import '../models/workspace.dart';
import '../state/identity.dart';
import 'anon.dart';
import 'memory_keeper.dart';
import 'nostr/event_signer.dart';
import 'nymbot_api.dart';
import 'pq_announce.dart';
import 'repo_map.dart';
import 'free_tier.dart';
import 'relay_pool.dart';
import 'wire_limits.dart';
import '../features/i18n/i18n.dart';

class ChatFailure implements Exception {
  ChatFailure(this.message,
      {this.noCredits = false,
      this.pro = false,
      this.balance = 0,
      this.cancelled = false,
      this.free});

  final String message;
  final bool noCredits;
  final bool pro;
  final int balance;
  final bool cancelled;

  /// Present when it was the day's free allowance that ran out rather than a
  /// balance, which is a time rather than a wall.
  final FreeAllowance? free;

  @override
  String toString() => message;
}

typedef TurnResult = ({
  String reply,
  String? thinking,
  int cost,
  int? balance,
  bool pro,
  int modelCalls,
  bool lowBalance,
  List<String> repos,
  List<Map<String, dynamic>> sources,
  /// What the day's free allowance has left, when this reply came out of it
  /// rather than out of a balance.
  FreeAllowance? free,
  // Set when the run stopped at its tool-call cap with work left. The token
  // buys one more leg; the caller decides whether to spend it.
  bool truncated,
  String? resumeToken,
  int nextReserve,
  /// What this reply changed in a repository, and where the branch stood
  /// before it did, so the run can be put back.
  Map<String, dynamic>? checkpoint,
  String eventId,
});

/// One thing the running turn reported doing.
typedef TurnStep = ({
  int n,
  String kind,
  String text,
  String tool,
  int call,
  int of,
  /// The one yes/no a step carries — today, whether a picture is what sent the
  /// message somewhere other than the route the question picked.
  bool flag,
});

typedef CostEstimate = ({String tier, int low, int high});

/// One turn, end to end: seal, publish, ask the worker, open the reply.
class ChatEngine {
  ChatEngine({
    required this.identity,
    required this.relays,
    required this.pq,
    required this.api,
    required this.anon,
    this.maps,
  });

  final Identity identity;
  final RelayPool relays;
  final PqAnnounce pq;
  final NymbotApi api;
  final AnonMode anon;

  final RepoMap? maps;

  void Function(String? status)? onStatus;

  bool _cancelled = false;
  bool sending = false;

  void abort() {
    _cancelled = true;
    sending = false;
  }

  static ({String? thinking, String body}) splitThinking(String text) {
    for (final tag in const ['think', 'thinking', 'reasoning']) {
      final m = RegExp(r'^\s*<' '$tag' r'>([\s\S]*?)</' '$tag' r'>\s*',
              caseSensitive: false)
          .firstMatch(text);
      if (m != null) {
        return (thinking: m.group(1)!.trim(), body: text.substring(m.end));
      }
    }
    return (thinking: null, body: text);
  }

  static CostEstimate estimate(String text, Map<String, dynamic>? model,
      {Conversation? conv, bool hasRepos = false, String wireText = ''}) {
    // A question too long for one wrap travels as several, and each extra one
    // is a credit. Splitting is a transport detail, but the input it carries is
    // real and the published price has never charged for input.
    final extra =
        WireLimits.partSurcharge(wireText.isEmpty ? text : wireText);
    if (model == null) {
      return (tier: 'standard', low: 1 + extra, high: 1 + extra);
    }
    final bump = text.length > 4000 ? 2 : text.length > 1200 ? 1 : 0;
    // A repo task loops on a budget of its own and ignores the effort level.
    final calls = hasRepos ? 1 : effortCalls(conv);
    final low = ((model['credits'] as num?)?.toInt() ?? 1) * calls + extra;
    final max = (model['max'] as num?)?.toInt() ?? 1;
    final scaled = (max + bump) * calls + extra;
    final high = scaled < low ? low : scaled;
    return (tier: 'pro', low: low, high: high);
  }

  // Project knowledge is retrieved per message rather than poured into the
  // first one. The old caps sent up to 90,000 characters in turn one, where the
  // worker cut it to 1000 the moment it became history — so a workspace stopped
  // applying after a single reply. A few relevant passages, sent every turn,
  // are both smaller on the wire and actually there when the question needs
  // them.
  // How hard a reply is asked to think, as the number of model calls it takes.
  // A careful reply plans before it answers; a deep one also reads its answer
  // back against the question before sending it. Both are charged as what they
  // are — more model calls — so the price says what the work was.
  static const effortLevels = {'normal': 1, 'careful': 2, 'deep': 3};

  static const busyWaits = [
    Duration(seconds: 4),
    Duration(seconds: 9),
    Duration(seconds: 16),
  ];

  static String effortOf(Conversation? conv) {
    final name = conv?.effort ?? 'normal';
    return effortLevels.containsKey(name) ? name : 'normal';
  }

  static int effortCalls(Conversation? conv) =>
      effortLevels[effortOf(conv)] ?? 1;

  static const knowledgeChunkMax = 1200;
  static const knowledgeSendCap = 5000;
  static const knowledgeFileCap = 24000;

  /// Marks where the context repeated every turn ends and the message begins,
  /// so the worker can drop the repeats from historical turns. A block of
  /// knowledge has blank lines in it, so the boundary cannot be found by
  /// looking — it has to be written down.
  static const standingEnd = '[end of standing context]';

  static const _stopWords = {
    'a', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'can', 'could',
    'did', 'do', 'does', 'for', 'from', 'had', 'has', 'have', 'how', 'i', 'if',
    'in', 'is', 'it', 'its', 'me', 'my', 'not', 'of', 'on', 'or', 'our', 'so',
    'than', 'that', 'the', 'their', 'them', 'then', 'there', 'these', 'they',
    'this', 'to', 'was', 'we', 'were', 'what', 'when', 'where', 'which', 'who',
    'why', 'will', 'with', 'would', 'you', 'your',
  };

  static List<String> _terms(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 1 && !_stopWords.contains(w))
      .toList();

  /// Splits one file into retrievable passages, on blank lines and headings,
  /// each under a ceiling. A markdown heading is carried onto the passages
  /// beneath it, so a passage still says what it is about once it has been
  /// lifted out of the file it came from.
  static List<KnowledgeChunk> chunkFile(KnowledgeFile file) {
    final body = file.body.length > knowledgeFileCap
        ? file.body.substring(0, knowledgeFileCap)
        : file.body;
    final name = file.name.isEmpty ? 'untitled' : file.name;
    final chunks = <KnowledgeChunk>[];
    var heading = '';
    var buffer = <String>[];
    var at = 0;

    void flush() {
      final text = buffer.join('\n\n').trim();
      buffer = [];
      if (text.isEmpty) return;
      chunks.add(KnowledgeChunk(
          file: name, at: at++, heading: heading, text: text));
    }

    for (final para in body.split(RegExp(r'\n\s*\n'))) {
      final block = para.trim();
      if (block.isEmpty) continue;
      final head =
          RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(block.split('\n').first);
      if (head != null) {
        flush();
        heading = head.group(2)!.trim();
      }
      // A single paragraph over the ceiling is cut into pieces rather than
      // dropped: a long table or code block is often the answer.
      if (block.length > knowledgeChunkMax) {
        flush();
        for (var i = 0; i < block.length; i += knowledgeChunkMax) {
          final end = i + knowledgeChunkMax;
          buffer.add(block.substring(i, end > block.length ? block.length : end));
          flush();
        }
        continue;
      }
      if (buffer.join('\n\n').length + block.length > knowledgeChunkMax) {
        flush();
      }
      buffer.add(block);
    }
    flush();
    return chunks;
  }

  /// Ranks passages against the question with BM25 over plain terms.
  ///
  /// Deliberately not embeddings: this runs on the device, for every message,
  /// with no model to call and nothing downloaded. Term overlap is weaker than
  /// a vector search and enormously better than sending the first 90,000
  /// characters and hoping.
  static List<KnowledgeChunk> rankChunks(
      List<KnowledgeChunk> chunks, String query) {
    final want = _terms(query).toSet();
    if (want.isEmpty || chunks.isEmpty) return const [];
    const k = 1.2;
    const b = 0.75;
    final docs = chunks.map((c) => _terms('${c.heading} ${c.text}')).toList();
    final lengths = docs.map((d) => d.length).toList();
    final avg = lengths.isEmpty
        ? 1.0
        : lengths.reduce((x, y) => x + y) / lengths.length;
    final df = <String, int>{};
    for (final doc in docs) {
      for (final term in doc.toSet()) {
        df[term] = (df[term] ?? 0) + 1;
      }
    }
    final scored = <({KnowledgeChunk chunk, double score})>[];
    for (var i = 0; i < chunks.length; i++) {
      final freq = <String, int>{};
      for (final term in docs[i]) {
        freq[term] = (freq[term] ?? 0) + 1;
      }
      var score = 0.0;
      for (final term in want) {
        final tf = freq[term] ?? 0;
        if (tf == 0) continue;
        final n = df[term] ?? 0;
        final idf = math.log(1 + (chunks.length - n + 0.5) / (n + 0.5));
        score += idf *
            (tf * (k + 1)) /
            (tf + k * (1 - b + b * (avg == 0 ? 1 : docs[i].length / avg)));
      }
      if (score > 0) scored.add((chunk: chunks[i], score: score));
    }
    scored.sort((x, y) => y.score.compareTo(x.score));
    return scored.map((x) => x.chunk).toList();
  }

  /// Puts a repo run back: each path the run wrote is read at the commit the
  /// branch stood on before it and committed as it was. A revert, not a
  /// rewrite — what the model did stays in the history, it is simply no longer
  /// the state of the branch. Costs nothing: it touches no model.
  Future<Map<String, dynamic>> revert({
    required GitRepo repo,
    required Map<String, dynamic> checkpoint,
    required EventSigner signer,
  }) async {
    final res = await api.call('pm-revert', signer, extra: {
      'git': repo.toPayload(),
      'checkpoint': {
        'repo': checkpoint['repo'],
        'branch': checkpoint['branch'],
        'baseSha': checkpoint['baseSha'],
        'paths': checkpoint['paths'] ?? const [],
        'branches': checkpoint['branches'] ?? const [],
        'pulls': checkpoint['pulls'] ?? const [],
      },
    });
    final data = res.data;
    if (data['error'] != null) {
      throw ChatFailure(data['error'] as String);
    }
    return data;
  }

  /// The passages of the workspace's files that bear on this question, plus the
  /// names of every file so the model knows what else it could be told about.
  /// When nothing matches, the opening of each file goes instead — enough to
  /// say what the project is rather than nothing at all.
  static String knowledgeBlock(Workspace? space, [String query = '']) {
    final files = space?.files ?? const <KnowledgeFile>[];
    if (files.isEmpty) return '';
    final chunks = <KnowledgeChunk>[];
    for (final file in files) {
      chunks.addAll(chunkFile(file));
    }
    if (chunks.isEmpty) return '';

    var budget = knowledgeSendCap;
    final picked = <KnowledgeChunk>[];
    void take(KnowledgeChunk chunk) {
      if (picked.contains(chunk) || chunk.text.length > budget) return;
      budget -= chunk.text.length;
      picked.add(chunk);
    }

    for (final hit in rankChunks(chunks, query)) {
      take(hit);
    }
    if (picked.isEmpty) {
      for (final file in files) {
        final name = file.name.isEmpty ? 'untitled' : file.name;
        for (final chunk in chunks) {
          if (chunk.file == name) {
            take(chunk);
            break;
          }
        }
      }
    }
    if (picked.isEmpty) return '';

    // Back into document order, so passages from one file read forwards.
    picked.sort((a, b) {
      final byFile = a.file.compareTo(b.file);
      return byFile != 0 ? byFile : a.at.compareTo(b.at);
    });
    final names =
        files.map((f) => f.name.isEmpty ? 'untitled' : f.name).join(', ');
    final parts = <String>[];
    String? last;
    for (final chunk in picked) {
      final label =
          chunk.heading.isEmpty ? chunk.file : '${chunk.file} — ${chunk.heading}';
      if (label != last) parts.add('--- $label ---');
      last = label;
      parts.add(chunk.text);
    }
    final partial = picked.length < chunks.length;
    return '[project knowledge]\n'
        'Files in this workspace: $names.\n'
        '${partial ? 'The passages below are the parts that match this question.\n' : ''}'
        '${parts.join('\n\n')}';
  }

  /// The context that holds for every message in a chat: who the bot is being,
  /// what it can read, and the part of the workspace that bears on what was
  /// just asked.
  ///
  /// Sent on every message rather than only the first. It used to go once, at
  /// the top of turn one, and the worker cut that turn to 1000 characters the
  /// moment it became history — so instructions and project knowledge stopped
  /// applying after a single reply, silently. The worker strips these blocks
  /// from historical turns, so repeating them costs one copy, not twenty.
  static List<String> standingContext(
    Conversation conv,
    List<GitRepo> repos,
    Persona? persona,
    Workspace? space,
    Bot? bot,
    String query,
    List<Memory> memories, {
    String repoFiles = '',
  }) {
    final parts = <String>[];
    final instructions = [
      bot?.instructions ?? '',
      persona?.instructions ?? '',
      space?.instructions ?? '',
      conv.systemPrompt,
    ].where((x) => x.trim().isNotEmpty).join('\n\n').trim();
    if (instructions.isNotEmpty) {
      parts.add('[custom instructions]\n$instructions');
    }
    if (repos.length > 1) {
      final lines = <String>[];
      for (var i = 0; i < repos.length; i++) {
        final r = repos[i];
        final branch = r.branch.isEmpty ? '' : '@${r.branch}';
        final access = r.allowWrites ? ', writable' : ', read-only';
        final paths = r.paths.isEmpty ? '' : ' paths: ${r.paths}';
        lines.add('${i + 1}. ${r.repo}$branch (${r.provider}$access)$paths');
      }
      parts.add('[repositories in scope]\n${lines.join('\n')}\n'
          'Refer to a repository by its name when you cite a file.');
    }
    if (repoFiles.isNotEmpty) parts.add(repoFiles);
    final knowledge = knowledgeBlock(space, query);
    if (knowledge.isNotEmpty) parts.add(knowledge);
    final remembered = MemoryKeeper.block(memories, conv, query);
    if (remembered.isNotEmpty) parts.add(remembered);
    return parts;
  }

  static String preamble(
    Conversation conv,
    List<GitRepo> repos,
    Persona? persona, [
    Workspace? space,
    Bot? bot,
    String query = '',
    List<Memory> memories = const [],
    String repoFiles = '',
  ]) {
    final standing = standingContext(
        conv, repos, persona, space, bot, query, memories,
        repoFiles: repoFiles);
    final parts = <String>[];
    if (standing.isNotEmpty) {
      parts.add('${standing.join('\n\n')}\n\n$standingEnd');
    }
    // Past the marker, because nothing re-sends it: the client clears the seed
    // after the first message, so stripping it from history would lose what
    // the branch was branched from.
    final seed = conv.seed;
    if (seed != null && seed.isNotEmpty) {
      parts.add('[earlier in this conversation]\n$seed');
    }
    return parts.isEmpty ? '' : '${parts.join('\n\n')}\n\n';
  }

  /// A conversation is named after the first thing you say in it. Done here, on
  /// the device: the worker is never asked to summarise anything, and never
  /// sees the title.
  static String titleFor(String text) {
    var t = text
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'[`*_>#|]'), '')
        .replaceAll(RegExp(r'https?://\S+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.isEmpty) return 'New chat';
    final cmd = RegExp(r'^\?(\w+)\s*(.*)$').firstMatch(t);
    if (cmd != null) {
      final rest = cmd.group(2)!.trim();
      t = rest.isEmpty ? cmd.group(1)! : rest;
    }
    t = t.replaceFirst(RegExp(r'^[!\s]+'), '');
    if (t.length <= 48) return t[0].toUpperCase() + t.substring(1);
    final cut = t.substring(0, 48);
    final space = cut.lastIndexOf(' ');
    final trimmed = space > 24 ? cut.substring(0, space) : cut;
    return '${trimmed.replaceFirst(RegExp(r'[,;:.\-]$'), '')}…';
  }

  Future<void> _wait(Duration total) async {
    const slice = Duration(milliseconds: 250);
    var left = total;
    while (left > Duration.zero && !_cancelled) {
      final step = left < slice ? left : slice;
      await Future<void>.delayed(step);
      left -= step;
    }
  }

  String _sharedId() => bytesToHex(randomBytes(32));

  /// Publishes the message and collects the reply.
  Future<TurnResult> send({
    required Conversation conv,
    required String text,
    Map<String, dynamic>? proModel,
    List<GitRepo> repos = const [],
    Persona? persona,
    Workspace? workspace,
    Bot? bot,
    /// The standing facts this chat may see. Passed in rather than read here,
    /// so a caller that must not use memory simply does not hand any over.
    List<Memory> memories = const [],
    /// Continues a run parked by an earlier truncated turn.
    String? resume,
    /// Called with the turn's own event id as soon as it is published, so a
    /// watcher can start before the answer comes back.
    void Function(String eventId)? onTurn,
    List<Attachment> attachments = const [],
    String? quote,
    bool webSearch = false,
    bool firstTurn = true,
    /// Answers the message outside the conversation, the way a '!' question is answered.
    bool fresh = false,
    required void Function(List<String> ids) onThreadIds,
  }) async {
    final rootId = conv.rootId;
    final anonymous = conv.anon;
    _cancelled = false;
    sending = true;
    if (pq.botKey == null) {
      try {
        await pq.resolveBot();
      } catch (_) {}
    }
    if (relays.connected == 0) {
      throw ChatFailure(
          t('Not connected to any relay yet — your message cannot be published.'));
    }

    // Anonymous mode: the throwaway key signs the rumor, the seal and the
    // request, and the reply comes back to it. The account key signs nothing in
    // this conversation at all.
    final useAnon = anonymous && anon.ready;
    final signer = useAnon ? await anon.signer() : identity.signer;
    final senderSk = signer.privkey;
    final selfKem = useAnon
        ? anon.kemOf(await anon.ensure())?.publicKey
        : identity.kemPublicKey;

    final freshTurn = fresh || RegExp(r'^\s*!\s*\S').hasMatch(text);
    final reader = maps;
    var repoFiles = '';
    if (reader != null && repos.isNotEmpty && proModel != null) {
      if (!reader.knows(repos)) {
        onStatus?.call(t('Nymbot is reading your repositories'));
      }
      try {
        await reader.ready(repos);
      } catch (_) {}
      repoFiles = reader.block(repos, text);
    }
    final quoted = (quote == null || quote.isEmpty)
        ? ''
        : '> ${quote.replaceAll('\n', '\n> ')}\n\n';
    final attached = attachments.map((a) => a.wireBlock).join();
    String assemble(String files) {
      final head = preamble(
          conv, repos, persona, workspace, bot, text, memories, files);
      return '$head$quoted$text$attached';
    }

    var wireText = assemble(repoFiles);
    if (repoFiles.isNotEmpty &&
        WireLimits.split(wireText).length > WireLimits.partsMax) {
      repoFiles = '';
      wireText = assemble('');
    }

    // NIP-44 refuses a plaintext over 65535 bytes, and a gift wrap nests two
    // of them, so a long question does not fit in one event. It travels as
    // several instead — each saying where it sits, all sharing one message id
    // — and the worker puts them back together. What stays capped is how many.
    final bodies = WireLimits.split(wireText);
    if (bodies.length > WireLimits.partsMax) {
      throw ChatFailure(WireLimits.overLimitMessage(wireText));
    }
    final msgId = _sharedId();

    // A ghost chat publishes nothing it does not have to. The wrap to the bot
    // is how the message gets there at all; the archive copy and the reply's
    // re-publish are for restoring a conversation later, which is exactly what
    // a ghost chat is refusing.
    final ghost = conv.ephemeral;
    final botKem = pq.botKey?.pk;
    final partIds = <String>[];
    NostrEvent? wrap;
    for (var i = 0; i < bodies.length; i++) {
      final rumor = UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 14,
        tags: [
          ['p', NymbotConfig.botPubkey],
          ['x', msgId],
          ['ms', '${DateTime.now().millisecondsSinceEpoch}'],
          if (bodies.length > 1) ['part', '${i + 1}', '${bodies.length}'],
          ['nymthread', rootId],
        ],
        content: bodies[i],
      );
      wrap = await _wrap(rumor, senderSk, NymbotConfig.botPubkey, botKem);
      final accepted =
          await relays.publish(wrap, timeout: const Duration(seconds: 5));
      if (accepted == 0) {
        throw ChatFailure(
            t('No relay accepted your message. Check your connection and try again.'));
      }
      partIds.add(wrap.id);

      // Our own copy, so the conversation restores on another device.
      if (!ghost) {
        try {
          final selfWrap = await _wrap(rumor, senderSk, signer.pubkey, selfKem);
          unawaited(relays.publish(selfWrap, timeout: const Duration(seconds: 3)));
        } catch (_) {
          // The archive copy is best effort.
        }
      }
    }

    // The turn is now identifiable, so anything watching it can start before
    // the answer comes back.
    if (onTurn != null) {
      try {
        onTurn(wrap!.id);
      } catch (_) {}
    }

    final announcement =
        useAnon ? await anon.announcement() : pq.selfAnnouncement;
    final extra = <String, dynamic>{
      'eventId': wrap!.id,
      'fresh': freshTurn,
      // Every event the question was split across, in order. The last is
      // `eventId`, which is what a message that fits has always sent.
      if (partIds.length > 1) 'parts': partIds,
      if (resume != null && resume.isNotEmpty) 'resume': resume,
      if (announcement != null) 'pqAnnouncement': announcement.toJson(),
      if (webSearch) 'web': true,
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toPayload()).toList(),
      if (proModel != null) 'proModel': proModel['key'],
      // How hard this chat asked the reply to think. Only meaningful on Pro,
      // and only outside a repo task, which loops on a budget of its own.
      if (proModel != null && repos.isEmpty && effortOf(conv) != 'normal')
        'effort': effortOf(conv),
      if (proModel != null && repos.isNotEmpty) 'git': repos.first.toPayload(),
      if (proModel != null && repos.isNotEmpty)
        'repos': repos.map((r) => r.toPayload()).toList(),
    };

    // `pending` means an earlier attempt at this same message is still
    // generating. Asking again with the same event id collects that reply
    // rather than paying for a second one.
    ApiResult res;
    var held = 0;
    var waited = 0;
    while (true) {
      if (_cancelled) throw ChatFailure(t('Stopped.'), cancelled: true);
      res = await api.call('pm', signer,
          extra: extra, timeout: NymbotConfig.pmTimeout);
      if (res.data['pending'] == true && held++ < 5) {
        onStatus?.call(t('Still working on that one…'));
        await _wait(const Duration(seconds: 3));
        continue;
      }
      final failed = res.status >= 400 || res.data['error'] != null;
      if (failed &&
          res.data['noCredits'] != true &&
          waited < busyWaits.length &&
          NymbotApi.busy(res.status, res.data)) {
        final wait = busyWaits[waited++];
        onStatus?.call(t(
            'Too many requests just now — waiting {n} seconds rather than asking again straight away.',
            {'n': wait.inSeconds}));
        await _wait(wait);
        continue;
      }
      break;
    }
    if (_cancelled) throw ChatFailure(t('Stopped.'), cancelled: true);
    final data = res.data;

    if (data['pending'] == true) {
      throw ChatFailure((data['message'] as String?) ??
          'Nymbot is still working on that message — its reply will arrive shortly.');
    }
    if (data['noCredits'] == true) {
      throw ChatFailure(
        (data['error'] as String?) ??
            (data['pro'] == true
                ? t('You are out of Pro credits.')
                : t('You are out of credits.')),
        noCredits: true,
        pro: data['pro'] == true,
        balance: (data['balance'] as num?)?.toInt() ?? 0,
        free: FreeAllowance.fromJson(data['free']),
      );
    }
    if (res.status >= 400 || data['error'] != null) {
      throw ChatFailure((data['error'] as String?) ?? 'The request failed.');
    }
    final eventJson = data['event'];
    if (eventJson is! Map<String, dynamic>) {
      throw ChatFailure(t('Nymbot sent no reply.'));
    }

    // Both copies go to the relays: the reply so it restores like any other
    // message, and the bot's self-addressed copy so the worker can re-read its
    // own turn as context next time.
    final replyEvent = NostrEvent.fromJson(eventJson);
    if (!ghost) {
      unawaited(relays.publish(replyEvent, timeout: const Duration(seconds: 3)));
    }
    final selfJson = data['selfEvent'];
    NostrEvent? selfEvent;
    if (selfJson is Map<String, dynamic>) {
      selfEvent = NostrEvent.fromJson(selfJson);
      if (!ghost) {
        unawaited(relays.publish(selfEvent, timeout: const Duration(seconds: 3)));
      }
    }

    final recipient = useAnon ? await anon.recipient() : identity.pqIdentity;
    final opened = await giftwrap.unwrapGiftWrap(replyEvent, [
      (
        sk: senderSk,
        bitchat: false,
        kemSk: recipient?.kemSecretKey,
        kemPk: recipient?.kemPublicKey,
      ),
    ]);
    if (opened == null) {
      throw ChatFailure(t('Nymbot replied, but this device could not decrypt it.'));
    }

    // A '!' question is answered without the conversation and stays out of it,
    // on this side as on the worker's: it was asked that way so it would not
    // become context. The chat still shows it.
    if (!freshTurn) {
      onThreadIds([wrap.id, if (selfEvent != null) selfEvent.id]);
    }

    final mark = data['checkpoint'];
    if (reader != null && mark is Map && mark['repo'] is String) {
      for (final r in repos.where((r) => r.repo == mark['repo'])) {
        await reader.forget(r);
      }
    }

    final split = splitThinking(opened.rumor['content'] as String? ?? '');
    return (
      reply: split.body,
      thinking: split.thinking,
      cost: (data['cost'] as num?)?.toInt() ?? 0,
      balance: (data['balance'] as num?)?.toInt(),
      pro: data['pro'] == true,
      modelCalls: (data['modelCalls'] as num?)?.toInt() ?? 1,
      lowBalance: data['lowBalance'] == true,
      free: FreeAllowance.fromJson(data['free']),
      repos: repos.map((r) => r.repo).toList(),
      sources: (data['sources'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
          const <Map<String, dynamic>>[],
      truncated: data['truncated'] == true,
      resumeToken: data['resumeToken'] as String?,
      nextReserve: (data['nextReserve'] as num?)?.toInt() ?? 0,
      checkpoint: data['checkpoint'] as Map<String, dynamic>?,
      eventId: wrap.id,
    );
  }

  /// What the turn answering [eventId] is doing. Purely advisory: a failure
  /// returns nothing rather than disturbing the turn.
  Future<List<TurnStep>> progress(
    EventSigner signer,
    String eventId, {
    int after = 0,
  }) async {
    try {
      final res = await api.call(
        'pm-progress',
        signer,
        extra: {'eventId': eventId, 'after': after},
        timeout: const Duration(seconds: 8),
      );
      final steps = (res.data['steps'] as List?) ?? const [];
      return steps.whereType<Map<String, dynamic>>().map((s) => (
            n: (s['n'] as num?)?.toInt() ?? 0,
            kind: s['kind'] as String? ?? '',
            // One field for "the thing this step is about", whichever name the
            // worker gave it — the tool's own name stays separate so a tool
            // step can say both what it did and what it touched.
            text: (s['text'] ??
                    s['query'] ??
                    s['target'] ??
                    s['model'] ??
                    s['url'] ??
                    s['stage'] ??
                    s['task'] ??
                    '')
                .toString(),
            tool: s['tool'] as String? ?? '',
            call: (s['call'] as num?)?.toInt() ??
                (s['images'] as num?)?.toInt() ??
                (s['turns'] as num?)?.toInt() ??
                0,
            of: (s['of'] as num?)?.toInt() ?? 0,
            flag: s['seeing'] == true,
          )).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<NostrEvent> _wrap(UnsignedEvent rumor, Uint8List senderSk,
      String recipientPubkey, Uint8List? kemPk) {
    if (kemPk == null) {
      return Future.value(giftwrap.nip59Wrap(
        rumor: rumor,
        senderPrivkey: senderSk,
        recipientPubkey: recipientPubkey,
      ));
    }
    return giftwrap.pq2Nip59Wrap(
      rumor: rumor,
      senderPrivkey: senderSk,
      recipientPubkey: recipientPubkey,
      recipientKemPublicKey: kemPk,
    );
  }
}
