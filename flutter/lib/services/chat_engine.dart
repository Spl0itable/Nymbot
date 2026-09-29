import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../config.dart';
import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../core/crypto/schnorr.dart' as schnorr;
import '../models/bot.dart';
import '../models/connector.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/nostr_event.dart';
import '../models/workspace.dart';
import '../state/identity.dart';
import 'anon.dart';
import 'connectors.dart';
import 'doc_library.dart';
import 'memory_keeper.dart';
import 'nostr/event_signer.dart';
import 'nymbot_api.dart';
import 'pq_announce.dart';
import 'free_tier.dart';
import 'git_review.dart';
import 'relay_pool.dart';
import 'research.dart';
import 'server_runs.dart';
import 'team.dart';
import 'wire_limits.dart';
import '../features/i18n/i18n.dart';

class ChatFailure implements Exception {
  ChatFailure(this.message,
      {this.noCredits = false,
      this.pro = false,
      this.balance = 0,
      this.cancelled = false,
      this.resumeToken,
      this.free,
      this.capExceeded = false,
      this.required = 0,
      this.team = false,
      this.retryable = false});

  final String message;
  final bool noCredits;
  final bool pro;
  final double balance;
  final bool cancelled;

  final String? resumeToken;

  /// Present when it was the day's free allowance that ran out rather than a
  /// balance, which is a time rather than a wall.
  final FreeAllowance? free;

  final bool capExceeded;
  final double required;
  final bool team;
  final bool retryable;

  @override
  String toString() => message;
}

typedef TurnResult = ({
  String reply,
  String? thinking,
  double cost,
  double? balance,
  bool pro,
  int modelCalls,
  bool lowBalance,
  List<String> repos,
  List<Map<String, dynamic>> sources,
  List<String> followUps,
  /// What the day's free allowance has left, when this reply came out of it
  /// rather than out of a balance.
  FreeAllowance? free,
  // Set when the run stopped at its tool-call cap with work left. The token
  // buys one more leg; the caller decides whether to spend it.
  bool truncated,
  bool capStopped,
  String? resumeToken,
  int nextReserve,
  /// What this reply changed in a repository, and where the branch stood
  /// before it did, so the run can be put back.
  Map<String, dynamic>? checkpoint,
  Map<String, dynamic>? pendingTool,
  Map<String, dynamic>? staged,
  bool stalled,
  int retryAfterMs,
  String eventId,
  double serverRunCredits,
  List<Map<String, dynamic>> serverRuns,
  Map<String, dynamic>? team,
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

typedef CostEstimate = ({
  String tier,
  double low,
  double high,
  double max,
  bool metered,
  bool unpriced
});

typedef EstTurnText = ({bool bot, String text});

class TurnControl {
  TurnControl({this.onStatus});

  void Function(String? status)? onStatus;
  bool cancelled = false;

  void cancel() => cancelled = true;

  void say(String? status) => onStatus?.call(status);
}

/// One turn, end to end: seal, publish, ask the worker, open the reply.
class ChatEngine {
  ChatEngine({
    required this.identity,
    required this.relays,
    required this.pq,
    required this.api,
    required this.anon,
    this.botPubkey = NymbotConfig.botPubkey,
  });

  final String botPubkey;
  final Identity identity;
  final RelayPool relays;
  final PqAnnounce pq;
  final NymbotApi api;
  final AnonMode anon;

  static const heldMax = 8;
  static const heldSend = 4;
  static const heldBytes = 96 * 1024;
  final Map<String, List<NostrEvent>> _held = {};

  void holdWraps(String convId, List<NostrEvent> events) {
    final list = [...?_held[convId], ...events];
    _held[convId] =
        list.length > heldMax ? list.sublist(list.length - heldMax) : list;
  }

  List<NostrEvent> heldHistory(String convId) {
    final list = _held[convId] ?? const <NostrEvent>[];
    final out = <NostrEvent>[];
    var bytes = 0;
    for (var i = list.length - 1; i >= 0 && out.length < heldSend; i--) {
      bytes += list[i].content.length;
      if (bytes > heldBytes) break;
      out.insert(0, list[i]);
    }
    return out;
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

  static const int estTypicalOut = 400;
  static const int estLongOut = 1600;

  static const int nominalTurnIn = 3000;
  static const int nominalTurnOut = 700;

  static double? estMeteredCredits(Map<String, dynamic> model, int inTok,
      int outTok, int calls, double usdPerCredit) {
    final pin = (model['inUsdPerMTok'] as num?)?.toDouble() ?? 0;
    final pout = (model['outUsdPerMTok'] as num?)?.toDouble() ?? 0;
    if (pin <= 0 || pout <= 0 || usdPerCredit <= 0) return null;
    final cached = (model['cacheReadUsdPerMTok'] as num?)?.toDouble() ?? 0;
    final pcr = cached > 0 ? cached : pin * 0.1;
    final legs = calls < 1 ? 1 : calls;
    final usd = (inTok * pin + inTok * (legs - 1) * pcr + outTok * legs * pout) /
        1e6;
    return usd / usdPerCredit;
  }

  static double? nominalTurnCredits(
      Map<String, dynamic> model, Map<String, dynamic>? pricing) {
    final usd = (pricing?['usdPerCredit'] as num?)?.toDouble() ?? 0;
    final spend =
        estMeteredCredits(model, nominalTurnIn, nominalTurnOut, 1, usd);
    if (spend == null) return null;
    final floor = (pricing?['minChargeCredits'] as num?)?.toDouble() ?? 0;
    return spend < floor ? floor : spend;
  }

  static (double, double)? nominalTurnRange(
      Map<String, dynamic> model, Map<String, dynamic>? pricing) {
    final usd = (pricing?['usdPerCredit'] as num?)?.toDouble() ?? 0;
    final low = estMeteredCredits(model, nominalTurnIn, estTypicalOut, 1, usd);
    final high = estMeteredCredits(model, nominalTurnIn, estLongOut, 1, usd);
    if (low == null || high == null) return null;
    final floor = (pricing?['minChargeCredits'] as num?)?.toDouble() ?? 0;
    return (low < floor ? floor : low, high < floor ? floor : high);
  }

  static int _estInt(Object? v) => v is num ? v.toInt() : 0;

  static Map<String, dynamic> _estMap(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  static Map<String, dynamic> estBudgets(Map<String, dynamic>? pricing) =>
      _estMap(pricing?['estimate']);

  static int estTokens(num chars, Map<String, dynamic> b) {
    final per = _estInt(b['charsPerToken']) > 0 ? _estInt(b['charsPerToken']) : 4;
    return chars <= 0 ? 0 : (chars / per).ceil();
  }

  static List<EstTurnText> estHistoryOf(List<ChatMessage> list) => [
        for (final m in list)
          if ((m.role == ChatRole.self || m.role == ChatRole.bot) &&
              m.content.isNotEmpty)
            (bot: m.role == ChatRole.bot, text: m.content),
      ];

  static ({int chars, List<EstTurnText> kept, int dropped}) estWindow(
      List<EstTurnText> history, Map<String, dynamic> b) {
    final h = _estMap(b['history']);
    if (h.isEmpty) {
      return (
        chars: history.fold(0, (n, x) => n + x.text.length),
        kept: history,
        dropped: 0
      );
    }
    final turns = _estInt(h['turns']);
    final recent = history.length > turns
        ? history.sublist(history.length - turns)
        : history;
    var budget = _estInt(h['chars']);
    var chars = 0;
    final kept = <EstTurnText>[];
    for (var i = recent.length - 1; i >= 0; i--) {
      if (budget < _estInt(h['turnMinChars'])) break;
      final len = math.min(recent[i].text.length,
          math.min(_estInt(h['turnChars']), budget));
      budget -= len;
      chars += len;
      kept.insert(0, recent[i]);
    }
    return (chars: chars, kept: kept, dropped: history.length - kept.length);
  }

  static RegExp? _estPattern(Map<String, dynamic> b, String name) {
    final src = _estMap(b['patterns'])[name];
    return src is String && src.isNotEmpty
        ? RegExp(src, caseSensitive: false)
        : null;
  }

  static List<String> estUrls(String text, Map<String, dynamic> b, String bare,
      String attached, int max) {
    final out = <String>[];
    void add(String? u) {
      if (u != null && !out.contains(u) && out.length < max) out.add(u);
    }

    for (final m in _estPattern(b, attached)?.allMatches(text) ??
        const <RegExpMatch>[]) {
      add(m.group(1));
    }
    for (final m
        in _estPattern(b, bare)?.allMatches(text) ?? const <RegExpMatch>[]) {
      add(m.group(0));
    }
    return out;
  }

  static int estLinks(String text, Map<String, dynamic> b) {
    final all = _estPattern(b, 'link');
    final skip = _estPattern(b, 'linkSkip');
    final max = _estInt(_estMap(b['links'])['pages']);
    final out = <String>[];
    for (final m in all?.allMatches(text) ?? const <RegExpMatch>[]) {
      if (out.length >= max) break;
      final url = m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
      if (skip != null && skip.hasMatch(url)) continue;
      if (!out.contains(url)) out.add(url);
    }
    return out.length;
  }

  static ({int images, int videos}) estMedia(String wire, List<EstTurnText> kept,
      Map<String, dynamic>? model, Map<String, dynamic> b) {
    final canSee = model == null || model['vision'] == true;
    if (!canSee) return (images: 0, videos: 0);
    final maxImages = _estInt(b['maxImages']);
    final video = _estMap(b['video']);
    final maxVideos = _estInt(video['max']);
    final shown = estUrls(wire, b, 'image', 'attachedImage', maxImages).length;
    final clips = estUrls(wire, b, 'video', 'attachedVideo', maxVideos).length;
    final watches = model != null && model['video'] == true;
    final frames = !watches && clips > 0
        ? math.min(_estInt(video['frames']), maxImages - shown)
        : 0;
    var room = maxImages - shown - frames;
    var videoRoom = watches ? maxVideos - clips : 0;
    var images = shown + frames;
    var videos = watches ? clips : 0;
    final asked = kept.where((h) => !h.bot).toList();
    final turns = _estInt(b['visionHistoryTurns']);
    final recent = (asked.length > turns
            ? asked.sublist(asked.length - turns)
            : asked)
        .reversed
        .toList();
    for (var i = 0; i < recent.length && (room > 0 || videoRoom > 0); i++) {
      final pics = math.min(room,
          estUrls(recent[i].text, b, 'image', 'attachedImage', maxImages).length);
      final films = math.min(
          videoRoom,
          watches
              ? estUrls(recent[i].text, b, 'video', 'attachedVideo', maxVideos)
                  .length
              : 0);
      room -= pics;
      videoRoom -= films;
      images += pics;
      videos += films;
    }
    return (images: images, videos: videos);
  }

  static ({int tokens, int dropped}) estInput(String wire,
      List<EstTurnText> history, Map<String, dynamic>? model, bool web,
      Map<String, dynamic> b) {
    final tier = model == null ? 'standard' : 'pro';
    final win = estWindow(history, b);
    final media = estMedia(wire, win.kept, model, b);
    final video = _estMap(b['video']);
    final recall = _estMap(b['recall']);
    final index = model != null && win.dropped > 0
        ? math.min(win.dropped, _estInt(recall['indexMax'])) *
            _estInt(recall['lineChars'])
        : 0;
    final tokens = _estInt(_estMap(b['systemTokens'])[tier]) +
        _estInt(b['scaffoldTokens']) +
        estTokens(wire.length + win.chars + index, b) +
        media.images * _estInt(b['imageTokens']) +
        media.videos *
            _estInt(video['seconds']) *
            _estInt(video['tokensPerSecond']) +
        estLinks(wire, b) * estTokens(_estInt(_estMap(b['links'])['chars']), b) +
        (web ? _estInt(_estMap(b['webTokens'])[tier]) : 0);
    return (tokens: tokens, dropped: win.dropped);
  }

  static double? estPrice(Map<String, dynamic> rates, int inTok, int outTok,
      int legs, bool cached) {
    final pin = (rates['inUsdPerMTok'] as num?)?.toDouble() ?? 0;
    final pout = (rates['outUsdPerMTok'] as num?)?.toDouble() ?? 0;
    if (pin <= 0 || pout <= 0) return null;
    final read = (rates['cacheReadUsdPerMTok'] as num?)?.toDouble() ?? 0;
    final pcr = read > 0 ? read : pin * 0.1;
    final n = legs < 1 ? 1 : legs;
    return (inTok * pin +
            inTok * (n - 1) * (cached ? pcr : pin) +
            outTok * n * pout +
            outTok * n * (n - 1) / 2 * pin) /
        1e6;
  }

  static ({double low, double high, double max})? estTurn(
      {required String wire,
      required List<EstTurnText> history,
      Map<String, dynamic>? model,
      bool web = false,
      int calls = 1,
      bool agent = false,
      Map<String, dynamic>? pricing}) {
    final b = estBudgets(pricing);
    final cached = model != null && model['cachesLegs'] == true;
    final floor = (pricing?['minChargeCredits'] as num?)?.toDouble() ?? 0;
    final input = estInput(wire, history, model, web, b);
    final agentBudget = _estMap(b['agent']);
    int typicalOf(bool reasons, int ceiling) => math.min(
        ceiling,
        reasons
            ? _estInt(b['reasoningOutTokens'])
            : _estInt(b['typicalOutTokens']));
    int longOf(bool reasons, int ceiling) {
      final long = reasons
          ? _estInt(b['reasoningLongOutTokens'])
          : _estInt(b['longOutTokens']);
      return math.min(
          ceiling, long > 0 ? long : typicalOf(reasons, ceiling));
    }

    if (model == null) {
      final usd = (pricing?['standardUsdPerCredit'] as num?)?.toDouble() ?? 0;
      final routes = [
        for (final r in (pricing?['standardRoutes'] as List?) ?? const [])
          if (r is Map && estPrice(_estMap(r), 1, 1, 1, false) != null)
            _estMap(r),
      ];
      if (routes.isEmpty || usd <= 0) return null;
      final general = routes.where((r) => r['task'] == 'general').toList();
      final usual = general.isNotEmpty ? general : routes;
      double priced(Map<String, dynamic> r, int out) =>
          estPrice(r, input.tokens, out, 1, false)! / usd;
      final low = math.max(
          floor,
          usual
              .map((r) => priced(
                  r, typicalOf(r['reasoning'] == true, _estInt(r['maxTokens']))))
              .reduce(math.min));
      final high = math.max(
          low,
          usual
              .map((r) => priced(
                  r, longOf(r['reasoning'] == true, _estInt(r['maxTokens']))))
              .reduce(math.max));
      final max = math.max(
          high,
          routes
              .map((r) => priced(r, _estInt(r['maxTokens'])))
              .reduce(math.max));
      return (low: low, high: high, max: max);
    }
    final usd = (pricing?['usdPerCredit'] as num?)?.toDouble() ?? 0;
    if (usd <= 0 || estPrice(model, 1, 1, 1, false) == null) return null;
    final ceiling = _estInt(model['outTokens']) > 0
        ? _estInt(model['outTokens'])
        : _estInt(b['typicalOutTokens']);
    final reasons = model['reasoning'] == true;
    int legsOf(String key) =>
        _estInt(agentBudget[key]) > 0 ? _estInt(agentBudget[key]) : 1;
    final lowLegs = agent ? legsOf('typicalCalls') : calls;
    final longLegs = agent
        ? (_estInt(agentBudget['longCalls']) > 0
            ? _estInt(agentBudget['longCalls'])
            : lowLegs)
        : calls;
    final maxLegs = agent
        ? legsOf('calls')
        : calls +
            (input.dropped > 0 ? _estInt(_estMap(b['recall'])['calls']) : 0);
    final workIn = input.tokens +
        (agent
            ? _estInt(agentBudget['toolTokens']) +
                _estInt(agentBudget['treeTokens'])
            : 0);
    final low = math.max(
        floor,
        estPrice(model, workIn, typicalOf(reasons, ceiling), lowLegs, cached)! /
            usd);
    final high = math.max(
        low,
        estPrice(model, workIn, longOf(reasons, ceiling), longLegs, cached)! /
            usd);
    final max = math.max(
        high,
        estPrice(
                model,
                input.tokens + (agent ? _estInt(agentBudget['inTokens']) : 0),
                ceiling,
                maxLegs,
                cached)! /
            usd);
    return (low: low, high: high, max: max);
  }

  static String estimateLine(CostEstimate e) {
    final pro = e.tier == 'pro';
    if (e.unpriced) {
      return pro
          ? t('— Pro credits (price unavailable right now)')
          : t('— standard credits (price unavailable right now)');
    }
    if (!e.metered) {
      if (pro) {
        final low = creditAmount(e.low, false);
        final high = creditAmount(e.high, false);
        return low == high
            ? t('About {n} Pro credits', {'n': low})
            : t('About {low}–{high} Pro credits', {'low': low, 'high': high});
      }
      return e.low == 1
          ? t('1 standard credit')
          : t('{n} standard credits', {'n': figure(e.low.round())});
    }
    final low = creditAmount(e.low, true);
    final high = creditAmount(e.high, true);
    final max = creditAmount(e.max >= 1 ? e.max.ceilToDouble() : e.max, true);
    final same = low == high;
    if (max == high) {
      if (pro) {
        return same
            ? t('About {n} Pro credits', {'n': low})
            : t('About {low}–{high} Pro credits', {'low': low, 'high': high});
      }
      return same
          ? t('{n} standard credits', {'n': low})
          : t('About {low}–{high} standard credits', {'low': low, 'high': high});
    }
    if (pro) {
      return same
          ? t('About {n} Pro credits (up to {max})', {'n': low, 'max': max})
          : t('About {low}–{high} Pro credits (up to {max})',
              {'low': low, 'high': high, 'max': max});
    }
    return same
        ? t('About {n} standard credits (up to {max})', {'n': low, 'max': max})
        : t('About {low}–{high} standard credits (up to {max})',
            {'low': low, 'high': high, 'max': max});
  }

  static bool fromBot(NostrEvent seal, Map<String, dynamic> rumor,
          {String bot = NymbotConfig.botPubkey}) =>
      seal.pubkey == bot &&
      seal.kind == 13 &&
      rumor['pubkey'] == seal.pubkey &&
      schnorr.verifyEvent(seal);

  static CostEstimate generatorEstimate(Map<String, dynamic> media) {
    final credits = (media['credits'] as num?)?.toDouble() ?? 0;
    final max = (media['max'] as num?)?.toDouble() ?? credits;
    final high = max < credits ? credits : max;
    return (
      tier: 'pro',
      low: credits,
      high: high,
      max: high,
      metered: false,
      unpriced: false
    );
  }

  static CostEstimate estimate(String text, Map<String, dynamic>? model,
      {Conversation? conv,
      bool hasRepos = false,
      String wireText = '',
      List<EstTurnText> history = const [],
      bool web = false,
      Map<String, dynamic>? pricing}) {
    // A question too long for one wrap travels as several, and each extra one
    // is a credit. Splitting is a transport detail, but the input it carries is
    // real and the published price has never charged for input.
    final wire = wireText.isEmpty ? text : wireText;
    final extra = WireLimits.partSurcharge(wire);
    final unpriced = pricing?['priceUnavailable'] == true;
    if (model == null) {
      final std = unpriced
          ? null
          : estTurn(wire: wire, history: history, web: web, pricing: pricing);
      if (std != null) {
        return (
          tier: 'standard',
          low: std.low + extra,
          high: std.high + extra,
          max: std.max + extra,
          metered: true,
          unpriced: false
        );
      }
      return (
        tier: 'standard',
        low: 1.0 + extra,
        high: 1.0 + extra,
        max: 1.0 + extra,
        metered: false,
        unpriced: unpriced
      );
    }
    final calls = hasRepos ? 1 : effortCalls(conv);
    final pro = unpriced
        ? null
        : estTurn(
            wire: wire,
            history: history,
            model: model,
            web: web,
            calls: calls,
            agent: hasRepos,
            pricing: pricing);
    if (pro != null) {
      return (
        tier: 'pro',
        low: pro.low + extra,
        high: pro.high + extra,
        max: pro.max + extra,
        metered: true,
        unpriced: false
      );
    }
    final bump = text.length > 4000 ? 2 : text.length > 1200 ? 1 : 0;
    final chatBase = (model['credits'] as num?)?.toInt() ?? 1;
    final chatMax = (model['max'] as num?)?.toInt() ?? chatBase;
    final base = hasRepos
        ? ((model['repoCredits'] as num?)?.toInt() ?? chatBase)
        : chatBase;
    final max =
        hasRepos ? ((model['repoMax'] as num?)?.toInt() ?? chatMax) : chatMax;
    final low = (base * calls + extra).toDouble();
    final scaled = ((max + bump) * calls + extra).toDouble();
    final high = scaled < low ? low : scaled;
    return (
      tier: 'pro',
      low: low,
      high: high,
      max: high,
      metered: false,
      unpriced: unpriced
    );
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

  static const reconnects = 2;

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

  Future<Map<String, dynamic>> applyStaged({
    required GitRepo repo,
    required Map<String, dynamic> staged,
    required EventSigner signer,
  }) async {
    final res = await api.call('git-apply', signer, extra: {
      'git': repo.toPayload(),
      'staged': stagedRequest(staged),
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
    List<Memory> memories,
  ) {
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
  ]) {
    final standing =
        standingContext(conv, repos, persona, space, bot, query, memories);
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

  Future<void> _wait(Duration total, TurnControl control) async {
    const slice = Duration(milliseconds: 250);
    var left = total;
    while (left > Duration.zero && !control.cancelled) {
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
    List<McpConnector> connectors = const [],
    String? mcpApprove,
    String? mcpDecline,
    bool serverRuns = false,
    String? runApprove,
    String? runDecline,
    Duration? timeout,
    Persona? persona,
    Workspace? workspace,
    Bot? bot,
    /// The standing facts this chat may see. Passed in rather than read here,
    /// so a caller that must not use memory simply does not hand any over.
    List<Memory> memories = const [],
    /// Continues a run parked by an earlier truncated turn.
    String? resume,
    double? maxCost,
    /// Called with the turn's own event id as soon as it is published, so a
    /// watcher can start before the answer comes back.
    void Function(String eventId)? onTurn,
    void Function(Map<String, dynamic> step)? onStep,
    List<Attachment> attachments = const [],
    String? quote,
    bool webSearch = false,
    bool firstTurn = true,
    /// Answers the message outside the conversation, the way a '!' question is answered.
    bool fresh = false,
    Object? research,
    Map<String, dynamic>? team,
    required void Function(List<String> ids) onThreadIds,
    TurnControl? control,
  }) async {
    final rootId = conv.rootId;
    final anonymous = conv.anon;
    final turn = control ?? TurnControl();
    if (pq.botKey == null) {
      try {
        await pq.resolveBot();
      } catch (_) {}
    }
    // Anonymous mode: the throwaway key signs the rumor, the seal and the
    // request, and the reply comes back to it. The account key signs nothing in
    // this conversation at all.
    final useAnon = anonymous && anon.ready;
    final EventSigner signer = useAnon ? await anon.signer() : identity.signer;
    final selfKem = useAnon
        ? anon.kemOf(await anon.ensure())?.publicKey
        : (identity.rootLocked ? null : identity.kemPublicKey);

    final freshTurn = fresh || RegExp(r'^\s*!\s*\S').hasMatch(text);
    final head =
        preamble(conv, repos, persona, workspace, bot, text, memories);
    final quoted = (quote == null || quote.isEmpty)
        ? ''
        : '> ${quote.replaceAll('\n', '\n> ')}\n\n';
    final attached = attachments.map((a) => a.wireBlock).join();
    final searched = DocLibrary.instance.wireFor(conv.id, text, attachments);
    final wireText = '$head$quoted$text$attached$searched';

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
    if (onStep != null) {
      try {
        onStep({'kind': 'stage', 'stage': 'encrypting', 'local': true});
      } catch (_) {}
    }
    final partIds = <String>[];
    final partWraps = <NostrEvent>[];
    NostrEvent? wrap;
    for (var i = 0; i < bodies.length; i++) {
      final rumor = UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 14,
        tags: [
          ['p', botPubkey],
          ['x', msgId],
          ['ms', '${DateTime.now().millisecondsSinceEpoch}'],
          if (bodies.length > 1) ['part', '${i + 1}', '${bodies.length}'],
          ['nymthread', rootId],
        ],
        content: bodies[i],
      );
      wrap = await _wrap(rumor, signer, botPubkey, botKem);
      unawaited(relays.publish(wrap, timeout: const Duration(seconds: 5)));
      partIds.add(wrap.id);
      partWraps.add(wrap);

      // Our own copy, so the conversation restores on another device.
      if (!ghost) {
        try {
          final selfWrap = await _wrap(rumor, signer, signer.pubkey, selfKem);
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
    final handed = freshTurn ? const <NostrEvent>[] : heldHistory(conv.id);
    final extra = <String, dynamic>{
      'eventId': wrap!.id,
      'wrap': wrap.toJson(),
      'fresh': freshTurn,
      'followUps': true,
      'draft': true,
      if (handed.isNotEmpty) 'history': [for (final w in handed) w.toJson()],
      // Every event the question was split across, in order. The last is
      // `eventId`, which is what a message that fits has always sent.
      if (partIds.length > 1) 'parts': partIds,
      if (partIds.length > 1)
        'wraps': [for (final w in partWraps) w.toJson()],
      if (resume != null && resume.isNotEmpty) 'resume': resume,
      if (maxCost != null && maxCost > 0) 'maxCost': maxCost,
      if (announcement != null) 'pqAnnouncement': announcement.toJson(),
      if (announcement == null &&
          !useAnon &&
          (identity.rootLocked || identity.kem == null))
        'pqClassical': true,
      if (webSearch) 'web': true,
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toPayload()).toList(),
      if (proModel != null) 'proModel': proModel['key'],
      // How hard this chat asked the reply to think. Only meaningful on Pro,
      // and only outside a repo task, which loops on a budget of its own.
      if (proModel != null &&
          repos.isEmpty &&
          connectors.isEmpty &&
          effortOf(conv) != 'normal')
        'effort': effortOf(conv),
      if (proModel != null && repos.isNotEmpty) 'git': repos.first.toPayload(),
      if (proModel != null && repos.isNotEmpty)
        'repos': repos.map((r) => r.toPayload()).toList(),
      if (proModel != null && research != null) 'research': research,
      if (proModel != null && team != null) 'team': team,
      if (connectors.isNotEmpty)
        'mcp': connectors.map((c) => c.toPayload()).toList(),
      if (mcpApprove != null && mcpApprove.isNotEmpty) 'mcpApprove': mcpApprove,
      if (mcpDecline != null && mcpDecline.isNotEmpty) 'mcpDecline': mcpDecline,
      if (proModel != null && repos.isNotEmpty && serverRuns) 'serverRuns': true,
      if (runApprove != null && runApprove.isNotEmpty) 'runApprove': runApprove,
      if (runDecline != null && runDecline.isNotEmpty) 'runDecline': runDecline,
    };

    // `pending` means an earlier attempt at this same message is still
    // generating. Asking again with the same event id collects that reply
    // rather than paying for a second one.
    ApiResult res;
    var held = 0;
    var waited = 0;
    var lost = 0;
    while (true) {
      if (turn.cancelled) throw ChatFailure(t('Stopped.'), cancelled: true);
      res = await api.call('pm', signer,
          extra: extra, timeout: timeout ?? NymbotConfig.pmTimeout);
      if (res.status == 0 && lost++ < reconnects) {
        await _wait(const Duration(seconds: 2), turn);
        continue;
      }
      if (res.data['pending'] == true && held++ < 5) {
        turn.say(t('Still working on that one…'));
        await _wait(const Duration(seconds: 3), turn);
        continue;
      }
      final failed = res.status >= 400 || res.data['error'] != null;
      if (failed &&
          res.data['noCredits'] != true &&
          waited < busyWaits.length &&
          NymbotApi.busy(res.status, res.data)) {
        final wait = busyWaits[waited++];
        turn.say(t(
            'Too many requests just now — waiting {n} seconds rather than asking again straight away.',
            {'n': wait.inSeconds}));
        await _wait(wait, turn);
        continue;
      }
      break;
    }
    if (turn.cancelled) throw ChatFailure(t('Stopped.'), cancelled: true);
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
        balance: (data['balanceCredits'] as num?)?.toDouble()
            ?? (data['balance'] as num?)?.toDouble() ?? 0,
        free: FreeAllowance.fromJson(data['free']),
        team: data['team'] == true,
        required: (data['required'] as num?)?.toDouble() ?? 0,
      );
    }
    if (res.status >= 400 || data['error'] != null) {
      throw ChatFailure((data['error'] as String?) ?? 'The request failed.',
          resumeToken: data['resumable'] == true
              ? data['resumeToken'] as String?
              : null,
          capExceeded: data['capExceeded'] == true,
          pro: data['pro'] == true,
          required: (data['required'] as num?)?.toDouble() ?? 0,
          team: data['team'] == true,
          retryable: data['retryable'] == true);
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

    final anonKem = useAnon ? anon.kemOf(await anon.ensure()) : null;
    final kems = useAnon
        ? <giftwrap.KemPair>[
            if (anonKem != null)
              (kemSk: anonKem.secretKey, kemPk: anonKem.publicKey),
          ]
        : identity.kemCandidates();
    final opened = await giftwrap.unwrapWith(replyEvent, signer, kems);
    if (opened == null) {
      throw ChatFailure(t('Nymbot replied, but this device could not decrypt it.'));
    }
    if (!fromBot(opened.seal, opened.rumor, bot: botPubkey)) {
      throw ChatFailure(t('A reply arrived that Nymbot did not sign, so it was not shown.'));
    }

    // A '!' question is answered without the conversation and stays out of it,
    // on this side as on the worker's: it was asked that way so it would not
    // become context. The chat still shows it.
    if (!freshTurn) {
      onThreadIds([wrap.id, if (selfEvent != null) selfEvent.id]);
      holdWraps(conv.id, [...partWraps, if (selfEvent != null) selfEvent]);
    }

    final split = splitThinking(opened.rumor['content'] as String? ?? '');
    return (
      reply: split.body,
      thinking: split.thinking,
      cost: (data['costCredits'] as num?)?.toDouble()
          ?? (data['cost'] as num?)?.toDouble() ?? 0,
      balance: (data['balanceCredits'] as num?)?.toDouble()
          ?? (data['balance'] as num?)?.toDouble(),
      pro: data['pro'] == true,
      modelCalls: (data['modelCalls'] as num?)?.toInt() ?? 1,
      lowBalance: data['lowBalance'] == true,
      free: FreeAllowance.fromJson(data['free']),
      repos: repos.map((r) => r.repo).toList(),
      sources: (data['sources'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
          const <Map<String, dynamic>>[],
      followUps: ChatMessage.followUpsOf(data['followUps']),
      truncated: data['truncated'] == true,
      capStopped: data['capStopped'] == true,
      resumeToken: data['resumeToken'] as String?,
      nextReserve: (data['nextReserve'] as num?)?.toInt() ?? 0,
      checkpoint: data['checkpoint'] as Map<String, dynamic>?,
      pendingTool: Connectors.pendingFrom(data),
      staged: data['staged'] is Map<String, dynamic>
          ? data['staged'] as Map<String, dynamic>
          : null,
      stalled: data['stalled'] == true,
      retryAfterMs: (data['retryAfterMs'] as num?)?.toInt() ?? 0,
      eventId: wrap.id,
      serverRunCredits: (data['serverRunCredits'] as num?)?.toDouble() ?? 0,
      serverRuns: ServerRuns.runsOf(data['serverRuns']),
      team: data['team'] is Map && (data['team'] as Map)['workers'] is List
          ? (data['team'] as Map).cast<String, dynamic>()
          : null,
    );
  }

  /// What the turn answering [eventId] is doing. Purely advisory: a failure
  /// returns nothing rather than disturbing the turn.
  Future<List<TurnStep>> progress(
    EventSigner signer,
    String eventId, {
    int after = 0,
  }) async =>
      steps(await progressRaw(signer, eventId, after: after));

  static List<TurnStep> steps(List<Map<String, dynamic>> raw) {
    try {
      return raw.map(turnStep).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> progressRaw(
    EventSigner signer,
    String eventId, {
    int after = 0,
    int draftAfter = 0,
    void Function(String text, int seq)? onDraft,
  }) async {
    try {
      final res = await api.call(
        'pm-progress',
        signer,
        extra: {'eventId': eventId, 'after': after, 'draftAfter': draftAfter},
        timeout: const Duration(seconds: 8),
      );
      final draft = res.data['draft'];
      if (onDraft != null && draft is Map && draft['text'] is String) {
        final seq = (draft['seq'] as num?)?.toInt() ?? 0;
        if (seq > 0) onDraft(draft['text'] as String, seq);
      }
      final steps = (res.data['steps'] as List?) ?? const [];
      return steps.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }

  static TurnStep turnStep(Map<String, dynamic> s) =>
      s['kind'] == 'research' ? Research.stepOf(s) : s['kind'] == 'team' ? Team.stepOf(s) : Connectors.step(s) ?? (
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
            of: (s['of'] as num?)?.toInt() ?? (s['team'] as num?)?.toInt() ?? 0,
            flag: s['seeing'] == true,
          );

  Future<NostrEvent> _wrap(UnsignedEvent rumor, EventSigner signer,
          String recipientPubkey, Uint8List? kemPk) =>
      giftwrap.sealAndWrap(
        rumor: rumor,
        signer: signer,
        recipientPubkey: recipientPubkey,
        recipientKemPublicKey: kemPk,
      );
}
