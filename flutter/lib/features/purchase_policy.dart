import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/conversation.dart';
import '../models/notice.dart';
import 'i18n/i18n.dart';

bool? debugPurchasesDisabledOverride;

/// iOS sells no credits (App Store 3.1.1): the notice must stay a plain statement with no tap target.
bool get creditPurchasesDisabled {
  final o = debugPurchasesDisabledOverride;
  if (o != null) return o;
  if (kIsWeb) return false;
  try {
    return Platform.isIOS;
  } catch (_) {
    return false;
  }
}

enum _Kind { reply, note, notice }

const String kIosNeedsCredits = 'That needs credits.';
const String kIosCreditsWork = 'Credits you already have work here as usual.';

const List<(String, String)> kIosBotBuyRewrites = [
  (
    '. Type ?buy and switch to Pro to top up, or ?model off for standard replies.',
    '. Type ?model off for standard replies.'
  ),
  ('. Type ?buy and switch to Pro to top up.', '.'),
  (' Type ?buy to top up, then ?model to pick the model that will read it.', ''),
  (' Type ?buy to top up.', ''),
  (
    ', or type ?buy for credits, which also unlock the sharper models, repositories, images and web search.',
    '. Credits also unlock the sharper models, repositories, images and web search.'
  ),
  (
    'Wait for it to finish, or type ?buy for credits to run up to 3 requests at once.',
    'Wait for it to finish.'
  ),
  ('Wait for it to finish, or type ?buy for more.', 'Wait for it to finish.'),
  ('Type ?buy to top up; ', ''),
  ('. Type ?buy for more.', '.'),
  (' Top up to clear what is owed first.', ''),
];

const List<(String, String)> kIosClientBuyRewrites = [
  (', or tap Buy for credits.', '.'),
  (
    ' — or tap Buy for credits, which also unlock the sharper models, repositories, images and web search.',
    '. Credits also unlock the sharper models, repositories, images and web search.'
  ),
  (
    '. Tap Buy for credits, which also unlock the sharper models, repositories, images and web search.',
    '. Credits also unlock the sharper models, repositories, images and web search.'
  ),
];

String iosBotBuyRewrite(String text) =>
    _iosRewrite(text, () => t('Credits you already have work here as usual.'));

String withoutBuyHints(String text) => _iosRewrite(
    text,
    () => _kNoCredits.hasMatch(text)
        ? t('That needs credits.')
        : t('Credits you already have work here as usual.'),
    kind: _Kind.note);

String shownContent(ChatMessage m) {
  if (!creditPurchasesDisabled || m.support) return m.content;
  return switch (m.role) {
    ChatRole.bot => iosBotBuyRewrite(m.content),
    ChatRole.note || ChatRole.error => withoutBuyHints(m.content),
    _ => m.content,
  };
}

String? iosThinkingRewrite(String? s) {
  if (s == null || !creditPurchasesDisabled) return s;
  final kept = _iosRewrite(s, () => '');
  return kept.isEmpty ? null : kept;
}

String? shownThinking(ChatMessage m) => m.support ? m.thinking : iosThinkingRewrite(m.thinking);

List<ChatMessage> shownMessages(List<ChatMessage> list) {
  if (!creditPurchasesDisabled) return list;
  return [
    for (final m in list)
      (shownContent(m) == m.content && shownThinking(m) == m.thinking)
          ? m
          : ChatMessage.fromJson({
              ...m.toJson(),
              'content': shownContent(m),
              'thinking': shownThinking(m),
            }),
  ];
}

final RegExp _kBuyLink = RegExp(
    r'[#?&/]buy\b|/credits?\b|pricing|/topup|top-?up|^lightning:|^bitcoin:',
    caseSensitive: false);

Notice? shownNotice(Notice n) {
  if (!creditPurchasesDisabled) return n;
  final title = _iosRewrite(n.title, () => '', kind: _Kind.notice);
  final body = _iosRewrite(n.body, () => '', kind: _Kind.notice);
  final label = n.linkLabel ?? '';
  final sold = title != n.title || body != n.body || _sells(label, _Kind.notice, '', _Doc(label, _Kind.notice));
  final url = n.url;
  final keep = url != null && !sold && !_kBuyLink.hasMatch(url);
  if (title.isEmpty && body.isEmpty && n.model == null) return null;
  if (title == n.title && body == n.body && (keep || url == null)) return n;
  return Notice(
    id: n.id,
    kind: n.kind,
    level: n.level,
    title: title,
    body: body,
    url: keep ? url : null,
    linkLabel: keep ? n.linkLabel : null,
    model: n.model,
    at: n.at,
    endsAt: n.endsAt,
  );
}

String _iosRewrite(String text, String Function() empty, {_Kind kind = _Kind.reply}) {
  if (!creditPurchasesDisabled || !_sellAny(text, kind)) return text;
  var s = text;
  for (final (from, to) in [...kIosBotBuyRewrites, ...kIosClientBuyRewrites]) {
    s = s.replaceAll(from, to);
  }
  if (_sellAny(s, kind)) s = _rewriteBuySentences(s, kind);
  if (s.trim().isNotEmpty) return s;
  return empty();
}

class _Doc {
  _Doc(this.whole, _Kind kind) : app = kind != _Kind.reply {
    final lines = whole.split('\n');
    final code = _codeLines(lines);
    fenced = [
      for (var i = 0; i < lines.length; i++)
        if (code[i] && !_kFence.hasMatch(lines[i]) && lines[i].trim().isNotEmpty && !_kCmdLine.hasMatch(lines[i])) i
    ].isNotEmpty;
    lnOk = !_kLnDev.hasMatch(whole) || _kNymbot.hasMatch(whole);
    otherBot = _kOtherBot.hasMatch(whole) || _kOwnBot.hasMatch(whole) || (_kBotAudience.hasMatch(whole) && !_kNymbot.hasMatch(whole));
    final cmds = _anchorText(lines, code, fenced || otherBot);
    final m = mask(cmds);
    pro = _kProNym.hasMatch(m);
    final core = pro || _kCore.hasMatch(m);
    credish = core || !_kForeign.hasMatch(whole);
    credits = credish && _kCreditNoun.hasMatch(m);
    nymbot = _kNymbot.hasMatch(whole);
    buyDoc = _kBuyAnchor.hasMatch(cmds);
  }

  final String whole;
  final bool app;
  late final bool fenced;
  late final bool otherBot;
  late final bool lnOk;
  late final bool pro;
  late final bool credish;
  late final bool credits;
  late final bool nymbot;
  late final bool buyDoc;
  final Map<String, String> _masked = {};
  final Map<String, String> _cmds = {};
  final Map<String, bool> _nym = {};

  String mask(String s) => _masked.putIfAbsent(s, () => _nymText(s));
  String cmds(String s) => _cmds.putIfAbsent(s, () => _cmdText(s, fenced || otherBot));
  bool get wide => credits || nymbot || pro;
  bool credNym(String s) => credish && _kCreditNoun.hasMatch(mask(s));
  bool balNym(String s) => credish && _kBalNym.hasMatch(mask(s));
  bool nymPara(String unit) => _nym.putIfAbsent(unit, () => _namesNymbot(cmds(unit), unit, this));
}

bool _namesNymbot(String text, String unit, _Doc d) {
  if (!d.otherBot && _kBuyCmd.hasMatch(text)) return true;
  if (_kNymOwn.hasMatch(text)) return true;
  if (!_kOwnApp.hasMatch(unit) && _kBuyButton.hasMatch(text) && !_otherProduct(text)) return true;
  for (final s in text.split(_kSentenceEnd)) {
    final m = d.mask(s);
    final tier = _kTierName.firstMatch(m);
    if (tier != null && !_tierOfOther(m, tier)) return true;
    if (_kNymbot.hasMatch(m) && (_kNymCredit.hasMatch(m) || _kNymGoods.hasMatch(m)) && !_kNegated.hasMatch(s)) return true;
  }
  return false;
}

bool _tierOfOther(String m, RegExpMatch tier) {
  final lead = m.substring(0, tier.start);
  return _otherProduct(lead) || _kBrandLead.hasMatch(lead) || _otherProduct(_kTierAt.firstMatch(m.substring(tier.end))?[0] ?? '');
}

List<bool> _codeLines(List<String> lines) {
  final code = List<bool>.filled(lines.length, false);
  for (final (a, b, _) in _fenceSpans(lines)) {
    for (var x = a; x <= b; x++) {
      code[x] = true;
    }
  }
  return code;
}

String _anchorText(List<String> lines, List<bool> code, bool fenced) {
  final out = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    var l = lines[i];
    if (code[i]) {
      if (!_kFence.hasMatch(l) && _kCmdLine.hasMatch(l)) out.writeln(l);
      continue;
    }
    for (final (a, b) in _codeSpans(l).reversed) {
      final inner = l.substring(a, b).replaceAll(_kTicks, '');
      l = l.replaceRange(a, b, !fenced && _kCmdLine.hasMatch(inner) ? inner : ' ');
    }
    out.writeln(l);
  }
  return out.toString();
}

String _nymText(String s) => s
    .replaceAll(_kNotNym, ' ')
    .replaceAllMapped(_kCreditVerb, (m) => _kNymTitles.contains(m[1]) ? m[0]! : ' ');

bool _payMeans(String s) =>
    _kPayVerb.hasMatch(s) && _kPayMeans.hasMatch(s) && !_kMerchant.hasMatch(s);

String _cmdText(String s, bool fenced) {
  var out = s;
  for (final (a, b) in _codeSpans(s).reversed) {
    final inner = s.substring(a, b).replaceAll(_kTicks, '');
    out = out.replaceRange(a, b, !fenced && _kCmdLine.hasMatch(inner) ? inner : ' ');
  }
  return out;
}

int _aim(String words) {
  var best = 0;
  if (_kPassiveBuy.hasMatch(words)) best = 2;
  for (final m in _kBuyVerb.allMatches(words)) {
    final tail = _kAimTail.firstMatch(words.substring(m.end));
    if (tail == null) continue;
    if (tail[1] != null) return 2;
    best = best < 1 ? 1 : best;
  }
  return best;
}

String? _getAim(String words) {
  for (final m in _kGetVerb.allMatches(words)) {
    final tail = _kAimTail.firstMatch(words.substring(m.end));
    if (tail == null) continue;
    final obj = tail[1];
    if (obj != null) return obj.trim().toLowerCase();
    if (_kRefill.hasMatch(m[0]!)) return '';
  }
  return null;
}

List<String> _buyObjects(String words) {
  final out = <String>[];
  final p = _kPassiveBuy.firstMatch(words);
  if (p != null) out.add(p[1]!.toLowerCase());
  for (final m in _kBuyVerb.allMatches(words)) {
    final tail = _kAimTail.firstMatch(words.substring(m.end));
    if (tail == null) continue;
    final verb = m[0]!.toLowerCase();
    out.add(verb.startsWith('top') ? 'balance' : (tail[1] ?? '').trim().toLowerCase());
  }
  return out;
}

bool _nymPrice(String priced, String money) {
  if (!_kMoney.hasMatch(money)) return false;
  if (_kNymUnit.hasMatch(priced)) return true;
  if (_kCreditWord.hasMatch(priced) && _kSatsMoney.hasMatch(money)) return true;
  return _kNymbot.hasMatch(priced) && _kNymRate.hasMatch(priced);
}

bool _otherProduct(String unit) =>
    _kOtherSite.hasMatch(unit) || _kOtherBrand.hasMatch(unit);

bool _nymStoreIn(String plain, String unit) {
  for (final m in _kNymStoreStrict.allMatches(plain)) {
    if (_kNymbot.hasMatch(m[0]!)) return true;
    if (_kOfOther.hasMatch(plain.substring(m.end))) continue;
    if (!_otherProduct(plain)) return true;
  }
  return false;
}

bool _actIntl(String words) =>
    _kActIntl.hasMatch(words) || _kActSplit.hasMatch(words) || (_kAcquire.hasMatch(words) && _kCreditIntl.hasMatch(words));

bool _payOrBuy(String words) =>
    _kAct.hasMatch(words) || _actIntl(words) || _kPayNoun.hasMatch(words) || _kPayIntl.hasMatch(words);

String _plainWords(String s) {
  var plain = s;
  for (final (a, b) in _codeSpans(s).reversed) {
    plain = plain.replaceRange(a, b, ' ');
  }
  return plain;
}

bool _cantPayHere(String sentence, String unit, _Doc d) {
  if (d.fenced || _kOwnApp.hasMatch(unit)) return false;
  final plain = _plainWords(sentence);
  final words = plain.replaceAll(_kUrlOrName, ' ').replaceAll(_kEmph, '');
  return _payOrBuy(words) && !_kNoNeedToBuy.hasMatch(words) && _kHereIos.hasMatch(words) && !_nymStoreIn(plain, unit);
}

bool _storeNext(String sentence, String unit, _Doc d) {
  final plain = _plainWords(sentence);
  final words = plain.replaceAll(_kUrlOrName, ' ').replaceAll(_kEmph, '');
  return !_payOrBuy(words) && _nymStoreIn(plain, unit);
}

bool _replySells(String s, String unit, _Doc d) {
  if (!d.nymPara(unit)) return false;
  final spans = _codeSpans(s);
  bool inCode(int p) => spans.any((r) => p >= r.$1 && p < r.$2);
  if (!d.otherBot && _kBuyBare.allMatches(s).any((m) => !inCode(m.start))) return true;
  if (!d.fenced && !d.otherBot) {
    for (final (a, b) in spans) {
      if (_kBuyCode.hasMatch(s.substring(a, b).replaceAll(_kTicks, ''))) return true;
    }
  }
  var plain = s;
  for (final (a, b) in spans.reversed) {
    plain = plain.replaceRange(a, b, ' ');
  }
  final words = plain.replaceAll(_kUrlOrName, ' ').replaceAll(_kEmph, '');
  final here = d.cmds(s);
  final around = d.cmds(unit);
  final own = _kOwnApp.hasMatch(unit);
  final namedHere = _kNymAnchor.hasMatch(here);
  final named = namedHere || _kNymAnchor.hasMatch(around);
  final strongHere = _kNymStrong.hasMatch(here);
  final strong = strongHere || _kNymStrong.hasMatch(around);
  final buyCue = !own && (_kBuyAnchor.hasMatch(here) || _kBuyAnchor.hasMatch(around));
  final aim = _aim(words);
  final got = _getAim(words);
  final negated = _kNoBuy.hasMatch(words);
  final objs = _buyObjects(words);
  final credObj = !negated &&
      objs.any((o) => _kCredObj.hasMatch(o) || ((o.isEmpty || _kPronoun.hasMatch(o)) && _kCreditWord.hasMatch(around)));
  final topAim = aim == 2 || (aim == 1 && _kTopUpWord.hasMatch(words));
  final surfHere = !own && (_kBalSurface.hasMatch(words) || _kBalSurfaceIntl.hasMatch(words));
  final surfNear = !own && (_kBalSurface.hasMatch(around) || _kBalSurfaceIntl.hasMatch(around));
  if (strongHere && aim > 0) return true;
  if (namedHere && aim > 0 && credObj) return true;
  if (strong && topAim) return true;
  if (named && topAim && credObj) return true;
  if (surfHere && (aim > 0 || _actIntl(words) || _kPackStep.hasMatch(words))) return true;
  if (surfNear && _kPackStep.hasMatch(words)) return true;
  if (_actIntl(words) &&
      (strong || (named && _kCreditIntl.hasMatch(words) && !_kNoBuyIntl.hasMatch(words)))) {
    return true;
  }
  if (!own && !d.fenced && _payOrBuy(words) && !_kNoNeedToBuy.hasMatch(words) && _nymStoreIn(plain, unit)) return true;
  if (!own && aim > 0 && _kOwnCount.hasMatch(around) && !_otherProduct(around)) return true;
  if (!own && _kPayCue.hasMatch(words) && (surfNear || named || buyCue)) return true;
  if (!own &&
      (surfHere || _kNymOwn.hasMatch(around) || (!d.otherBot && _kBuyCmd.hasMatch(around))) &&
      (_kPaidIn.hasMatch(words) || _kPayGo.hasMatch(words) || _kPayIntl.hasMatch(words)) &&
      !_kZappy.hasMatch(words) &&
      !_kMerchant.hasMatch(words) &&
      !_kNoNeedToBuy.hasMatch(words) &&
      !_kNegated.hasMatch(words)) {
    return true;
  }
  final nymHere = _kNymbot.hasMatch(here) || _kNymbot.hasMatch(around);
  if ((_kObtainIntl.hasMatch(words) || (_kIntlThere.hasMatch(words) && _kCreditWord.hasMatch(words))) && nymHere) return true;
  if (got != null && _kCreditOrBalance.hasMatch(got) && (buyCue || (named && _kPayMeansWord.hasMatch(words)))) {
    return true;
  }
  if (aim > 0 || got != null) {
    final shopAt = _kNymShop.firstMatch(plain)?[0];
    final shop = shopAt != null && (_kNymbot.hasMatch(shopAt) || !_otherProduct(plain)) ? shopAt : null;
    final download = shop != null && _kDownloadShop.hasMatch(shop);
    if (shop != null && (aim > 0 || got != 'them' || !download)) return true;
    if ((aim > 0 || (got != null && got.isNotEmpty && got != 'them')) &&
        _kNymShopNear.hasMatch(unit) &&
        (_kNymbot.hasMatch(_kNymShopNear.firstMatch(unit)![0]!) || !_otherProduct(plain))) {
      return true;
    }
    if ((aim == 2 || (got != null && got.isNotEmpty)) && _kWebShop.hasMatch(plain)) return true;
  }
  if (!own && _kLabel.hasMatch(plain) && (buyCue || _kSurface.hasMatch(plain) || _kLabelGoal.hasMatch(words))) return true;
  if (!own && _kBuyFlow.hasMatch(plain) && (buyCue || d.buyDoc || surfNear || _kNymShop.hasMatch(plain))) return true;
  if (_kPaidIn.hasMatch(words) &&
      !_kZappy.hasMatch(words) &&
      (_kNymPayer.hasMatch(here) || (nymHere && _kCreditOrReply.hasMatch(words)))) {
    return true;
  }
  if (buyCue && _kPayStep.hasMatch(words) && !_kZappy.hasMatch(words)) return true;
  return _nymPrice(here, plain);
}

bool _storeOnly(String s) {
  if (!_kStorePtr.hasMatch(s)) return false;
  final rest = s.replaceAll(_kUrl, ' ').replaceAll(_kStorePtr, ' ').replaceAll(_kFiller, ' ');
  return !_kLetter.hasMatch(rest);
}

const Set<String> _kNymTitles = {'Standard', 'Pro', 'Nymbot'};
const String _kB = r'(?<!\p{L})';
const String _kE = r'(?!\p{L})';

RegExp _intl(String body, {bool caseSensitive = false}) =>
    RegExp('$_kB(?:$body)$_kE', caseSensitive: caseSensitive, unicode: true);

final RegExp _kSellAny = RegExp(
    r'\?buy|\bbuy|bought|purchas|top[ -]?ups?\b|\btops? up|topp(?:ed|ing) up|\brefill|\bsold\b|\bsells?\b|lightning|invoice|nymbot\.ai(?:/app\b|(?![/\w]))|web app|browser|google play|play store|zapstore|android app|\bsats?\b|satoshi|\bbtc\b|\busd\b|\$\s?\d|recharg|\breload|\bwallets?\b|\bQR\b|\bsafari\b|\bwebsite\b|\bbitcoin\b|kauf|compr|ach[eè]t|achat|recarg|aufladen|consegu|consig|obten|factur|rechnung|billetera|cartera|portefeuille|navegador|navigateur|app web|application web|\bcents?\b|\bpenn(?:y|ies)\b|\bdollars?\b|\beuros?\b|€|£|¢',
    caseSensitive: false);
final RegExp _kSellReply = RegExp(
    r'\btop(?:s|ped|ping)?\s+(?:them|it|yours|your(?:\s+\w+)?)\s+up\b|aufzulad|\bpacks?\b|how many credits|android-app|web-app|bezahl|app de android|aplicación de android|application android|\bpag(?:ar|as?|o)\b|\bpayer\b|\bpay(?:s|ing|ments?)?\b|adquier|adquirir|erwerb',
    caseSensitive: false);

bool _sellAny(String s, _Kind kind) =>
    _kSellAny.hasMatch(s) || (kind == _Kind.reply && (_kSellReply.hasMatch(s) || _kActSplit.hasMatch(s)));
final RegExp _kBuyBare =
    RegExp(r'(?<![\w/=&?#.])\?buy\b', caseSensitive: false);
final RegExp _kBuyCode =
    RegExp(r'^\s*\?buy(?:\s[\s\S]*)?$', caseSensitive: false);
final RegExp _kCmdLine = RegExp(r'^\s*\?[a-z]+(?:\s.*)?$', caseSensitive: false);
final RegExp _kTicks = RegExp(r'^`+|`+$');
final RegExp _kBuyInList =
    RegExp(r'(?<=\?[\w-]+)\s+\?buy(?=\s+\?[\w-])', caseSensitive: false);
final RegExp _kAct = RegExp(
    r'\b(?:buy|buying|bought|purchas\w*(?!\s+(?:records?|history))|top[ -]?ups?|tops? up|topp(?:ed|ing) up|refill(?:ed|ing|s)?(?=\s+(?:your|the|my|it|some)\b)|sold|sells?)\b',
    caseSensitive: false);
final RegExp _kActIntl = _intl(
    'kaufen|kaufst|kauft|kaufe|gekauft|kauf|aufladen|aufgeladen|aufzuladen|comprar|compra|compras|compran|comprarlos|comprarlas|compre|recargar|recarga|recargas|cómpralos|cómpralas|cómpralo|cómprala|acheter|achète|achètes|achetez|achètent|achat|achats|recharger|rechargez|recharge(?=[ \\t]+(?:ton|ta|tes|votre|vos|le|la|les|des|du|mon|ma|mes|un|une)[ \\t]+(?:\\p{L}+[ \\t]+)?(?:solde|compte|crédits?)(?!\\p{L}))');
final RegExp _kAcquire = _intl('adquiere|adquirir|nachkaufen|einkaufen|erwerben');
final RegExp _kActSplit = RegExp(
    '(?<!\\p{L})lad(?:e|en|et|st)?[ \\t]+(?:(?:es|sie|ihn)(?!\\p{L})|(?:[^.!?\\n]|\\.(?=\\S)){0,40}?(?:guthaben|credits?)(?!\\p{L}))(?:[^.!?\\n]|\\.(?=\\S)){0,60}?(?<!\\p{L})auf(?=[ \\t]*(?:[.!?…]|\$))'
    '|(?<!\\p{L})hol(?:e|t)?[ \\t]+(?:dir|euch|sie)(?!\\p{L})(?:[^.!?\\n]|\\.(?=\\S)){0,40}?(?:guthaben|credits?)(?!\\p{L})',
    caseSensitive: false,
    unicode: true);
final RegExp _kPayGo = RegExp(r'\b(?:pay|pays|paying)\b(?!\s+(?:attention|off|back|respects?|tribute|close|heed)\b)', caseSensitive: false);
final RegExp _kNymbot = RegExp(r'\bnymbot\b', caseSensitive: false);
final RegExp _kPay =
    RegExp(r'\bpa(?:y|ys|id|ying|yment|yments)\b|\binvoices?\b', caseSensitive: false);
final RegExp _kPayIntl =
    _intl(r'bezahl\w*|zahl(?:e|st|t|en)|pag(?:a|ar|as|ue|o|ado)|payer|payez|paie|paiement');
final RegExp _kPaying =
    RegExp(r'\bpa(?:id|ying|yments?)\b', caseSensitive: false);
final RegExp _kLightning = RegExp(r'\blightning\b', caseSensitive: false);
final RegExp _kInvoice = RegExp(r'\binvoices?\b', caseSensitive: false);
final RegExp _kInvoiceIntl = _intl(r'rechnung(?:en)?|facturas?|factures?');
final RegExp _kReplies = RegExp(r'\brepl(?:y|ies)\b|\bcredits?\b|\bnymbot\b',
    caseSensitive: false);
final RegExp _kRepliesWord = RegExp(r'\breplies\b', caseSensitive: false);
final RegExp _kStore = RegExp(
    r'nymbot\.ai(?:/app\b|(?![/\w]))|\bweb app\b|\bbrowser\b|google play|play store|zapstore|android app',
    caseSensitive: false);
final RegExp _kStoreIntl = _intl(
    'app web|application web|app de android|application android|android-app|web-app|aplicación web|aplicación de android|navegador|navigateur');
final RegExp _kNymStore = RegExp(
    '$_kB(?:nymbot\\.ai|web ?app|android app|zapstore|app web|application web|app de android|application android|android-app|web-app|aplicación web|aplicación de android|nymbot (?:for|on|para|pour|für) (?:android|ios|iphone|the web))$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kStorePtr = RegExp(
    '\\bhttps?://(?:www\\.)?nymbot\\.ai\\S*|nymbot\\.ai(?:/app)?|$_kB(?:(?:the|our|la|el|l\')[ \\t]*)?(?:web ?app|android app|google play|play store|zapstore|app web|application web|app de android|application android|android-app|web-app|aplicación web|aplicación de android)$_kE|$_kB(?:nymbot (?:for|on|para|pour|für) (?:android|ios|iphone|the web)|(?:on|in|at) the web)$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kFiller = _intl(
    'where|at|on|in|or|and|the|from|via|also|both|either|just|a|an|of|to|too|for|through|web|get|it|them|you|can|here|there|en|la|el|o|y|sur|ou|dans|l|und|oder|im|auf|der|die|das|también|desde|aussi|bien|sowie|available|now');
final RegExp _kUrl = RegExp(r'\bhttps?://\S+', caseSensitive: false);
final RegExp _kWhereQ = RegExp('${_kB}where[ \\t]*\\?', caseSensitive: false, unicode: true);
final RegExp _kSurface = _intl('toolbar|credits sheet|chat header');
final RegExp _kShopNoLn = RegExp(
    r'nymbot\.ai(?:/app\b|(?![/\w]))|\bweb app\b|google play|play store|zapstore|android app|\binvoices?\b',
    caseSensitive: false);
final RegExp _kUrlOrName = RegExp(r'\b(?:https?://|www\.)\S+|“[^”\n]*”', caseSensitive: false);
final RegExp _kQuotedName = RegExp(
    '(?<![\\p{L}\\p{N}])\'[^\'\\n]{1,80}\'(?![\\p{L}\\p{N}])|"[^"\\n]{1,80}"|‘[^’\\n]{1,80}’',
    unicode: true);
final RegExp _kNoteName = RegExp(r'^(\s*(?:Filed in|Persona set to|Theme set to)\s+)(.+?)(\.?\s*)$');
final RegExp _kLabel = RegExp(
    r'''(?:\b[Tt]ap|\b[Pp]ress|\b[Cc]lick|\b[Hh]it|\b[Ss]elect|\b[Cc]hoose|\b[Oo]pen)\s+(?:on\s+)?(?:the\s+)?[*_"“‘']*(?:Buy|Top[ -]up|Create invoice|Get credits)\b|[*_"“‘']+(?:Buy|Top[ -]up)\b[^*_"”’'\n]{0,20}[*_"”’']+\s+(?:button|tab|sheet|chip|row|link)\b''');
final RegExp _kObtain = RegExp(
    r'\b(?:add|adds|adding|added|get|gets|getting|grab|grabs|grabbing|fund|funds|funding|funded)\s+(?:some\s+more|more|some|them|credits?|your\s+balance)\b(?!\s+(?:out|done|than|of|detail|details|context|info|information|time|help|examples?)\b)|\b(?:recharg|reload|refill)\w*|\btop(?:s|ped|ping)?[ -]?ups?\b',
    caseSensitive: false);
final RegExp _kObtainIntl = _intl(
    'conseguir|consigue|consigues|consíguelos|obtener|obtén|obtenir|obtenez|obtiens|bekommen|bekommst|erhalten|erhältst|holen|holst');
final RegExp _kViaNoLn = RegExp(
    r'nymbot\.ai|\bweb ?app\b|\bsafari\b|\bbrowser\b|\bwebsite\b|\bandroid app\b|google play|play store|zapstore|\bwallets?\b|\bQR\b|\binvoices?\b',
    caseSensitive: false);
final RegExp _kViaIntl = _intl(
    'navegador|navigateur|app web|application web|app de android|application android|android-app|web-app|aplicación web|billetera|cartera|monedero|portefeuille|factura|facture|rechnung');
final RegExp _kScanQr = RegExp(r'\bscan\w*\b[^.!?\n]*\bQR\b|\bQR\b[^.!?\n]*\bscan', caseSensitive: false);
final RegExp _kWalletish = _intl(
    r'wallets?|lightning|bitcoin|btc|sats?|invoices?|billetera|cartera|portefeuille|rechnung|factura|facture');
final RegExp _kPayWord = RegExp(r'\bpa(?:y|ys|id|ying)\b', caseSensitive: false);
final RegExp _kPayCue = RegExp(
    r'\bpayments?\s+(?:is|are)\s+(?:made\s+|done\s+|taken\s+|only\s+)?(?:in|over|via|with|through|by)\s+(?:bitcoin|btc|lightning|sats)\b',
    caseSensitive: false);
final RegExp _kPayVerb = _intl(
    r'pay|pays|paid|paying|payments?|takes|take|accepts?|accepted|top(?:s|ped|ping)?[ -]?ups?|recharg\w*|refill\w*|bezahl\w*|zahl(?:e|st|t|en)|pag(?:a|ar|as|ue|o|ado)|payer|payez|paie|paiement|compr\w*|ach[eè]t\w*|achats?|kauf\w*');
final RegExp _kPayMeans = RegExp(
    '$_kB(?:with|in|over|via|using|through|mit|über|con|en|avec|par)[ \\t]+(?:the[ \\t]+|der[ \\t]+|el[ \\t]+|le[ \\t]+)?(?:bitcoin|btc|sats?|satoshis?|lightning)$_kE'
    '|$_kB(?:bitcoin|btc|sats|lightning)(?:[ \\t]+network)?[ \\t]+only$_kE'
    '|$_kB(?:takes|accepts?|nimmt|acepta|accepte)[ \\t]+(?:only[ \\t]+|nur[ \\t]+|solo[ \\t]+|seulement[ \\t]+)?(?:bitcoin|btc|sats|lightning)$_kE'
    '|$_kB(?:from|with|using)[ \\t]+(?:any|your|a|an)[ \\t]+(?:lightning|bitcoin)(?:[ \\t-]+wallet)?$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kMerchant = _intl(
    'shops?|merchants?|caf[eé]s?|restaurants?|vendors?|businesses|bars?|retailers?|el salvador');
final RegExp _kInvoiceAct =
    RegExp(r'\bpa(?:y|ys|id|ying)\b|\bscan\b|\bQR\b|\bwallets?\b|\bcreate\b|\bopen\b|\bget\b', caseSensitive: false);
final RegExp _kTopUpAny =
    RegExp(r'\btop(?:s|ped|ping)?[ -]?ups?\b|\brefill\w*', caseSensitive: false);
final RegExp _kImperative = RegExp(
    r'^\W*(?:(?:then|or|just|please|so)\s+)?(?:buy|purchase|top[ -]?up|refill|recharge)\b',
    caseSensitive: false);
final RegExp _kNoCredits = RegExp(
    r'\?buy\b|\btop[ -]?ups?\b|\btops? up\b|\b(?:out of|no|not enough|needs?|insufficient|ran out|run out|used|empty|low|owed)\b[^.!?\n]{0,40}\b(?:credits?|balance|free repl\w*)\b|\b(?:credits?|balance)\b[^.!?\n]{0,40}\b(?:empty|zero|low|owed|used up|ran out|run out)\b',
    caseSensitive: false);
final RegExp _kGetMore = RegExp(
    r'\bget(?:ting|s)?\s+(?:some\s+)?(?:more(?:\s+credits?)?|credits?)(?=\s*[:.,!?;]|\s*$|\s+(?:is|are|from|at|on|in|here|now|by|with|via|through|over)\b)',
    caseSensitive: false);
final RegExp _kPurchaseFlow = RegExp(r'\bpurchase flow\b', caseSensitive: false);
final RegExp _kPricedWord = _intl(r'tokens?|repl(?:y|ies)|nymbot|respuestas?|réponses?|antworten?');
final RegExp _kPriceWord = _intl(
    'price|prices|pricing|cost|costs|precio|precios|preis|preise|prix|coût|coûts|costo|costos|kosten|tarif|tarifa|tarifs');
final RegExp _kMoney = RegExp(
    '\\d[\\d,.]*[ \\t]*(?:sats?|satoshis?|btc|usd|eur|cents?)$_kE'
    '|\\\$[ \\t]?\\d|[€£][ \\t]?\\d|\\d[ \\t]?[€£¢]'
    '|$_kB(?:sats?|satoshis?|penn(?:y|ies)|dollars?|euros?)$_kE'
    '|(?<!per )${_kB}cents?$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kNotNym = RegExp(
    '${_kB}credit[ -]?(?:cards?|hours?|unions?|memos?|notes?|scores?|limits?|lines?|ratings?|reports?|checks?|history|bureaus?|risk|sales?|terms|facilit(?:y|ies)|default|swaps?)$_kE'
    '|$_kB(?:tax|store|travel|carbon|course|college|semester|class|degree|elective|end|opening|closing|film|movie|photo|cloud|aws|azure|gcp|startup|promo|promotional|airline|hotel|energy|solar|renewable|offset|emissions?|child|research|vendor|academic|university)[ -]credits?$_kE'
    '|$_kB(?:post|mid|pre)-credits?$_kE'
    '|$_kB(?:lines?|letters?) of credit$_kE'
    '|${_kB}on credit$_kE'
    '|$_kB(?:through|after|during|before|until|till|past) the (?:end |closing |final |opening )?credits$_kE'
    '|${_kB}credits (?:roll|rolled|rolling|scenes?)$_kE'
    '|tarjetas? de crédito|cartes? de crédit|crédits? d\'impôts?|kreditkarten?'
    '|$_kB(?:bank|account|checking|savings|trial|channel|wallet|card|loan|opening|closing|outstanding|statement|cash|inbound|outbound|local|remote|on-chain|onchain)[ -]balances?$_kE'
    '|${_kB}balances? (?:due|transfers?|sheets?|owed|forward)$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kCreditVerb = RegExp('$_kB[Cc]redit(?:s|ed|ing)?[ \\t]+(?:to[ \\t]+)?(?:the[ \\t]+)?(\\p{Lu}\\p{Ll}+)', unicode: true);
final RegExp _kForeign = RegExp(
    '$_kB(?:debit\\w*|ledgers?|journal entr\\w*|accounts? (?:payable|receivable)|bookkeeping|revenue|inventory|graduat\\w*|semesters?|tuition|universit\\w*|colleges?|transcripts?|gpa|imax|movies?|films?|cinemas?|soundtracks?|carbon|emissions?|co2|offsets?|aws|azure|gcp|startups?|accelerators?|apr|mortgages?|loans?|banks?|banking|irs|tax|taxes|airlines?|hotels?|stripe|shopify|paypal|mastercard|amex)$_kE'
    '|(?<!of )${_kB}courses?$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kCore = RegExp(
    '${_kB}nymbot$_kE'
    '|(?<![\\w/=&?#.])\\?(?:buy|balance|gift|transfer|model|image|speak|ask|help)(?![\\w-])'
    '|${_kB}free (?:daily )?(?:repl(?:y|ies)|messages)$_kE'
    '|today[\'’]s free'
    '|gratis-antworten|gratis-nachrichten|respuestas gratis|mensajes gratis|réponses gratuites|respostas grátis'
    '|${_kB}standard[ -](?:credits?|repl(?:y|ies)|balance|route)$_kE'
    '|${_kB}crédit(?:o|os|s)? (?:estándar|standard)$_kE'
    '|$_kB(?:credits sheet|zapstore)$_kE'
    '|$_kB(?:more|sharper) (?:repl(?:y|ies)|messages)$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kProNym = RegExp(
    '(?<!(?:iPhone|iPad|MacBook|AirPods|Watch|Galaxy|Pixel|Surface)[ \\d.]{0,6})${_kB}Pro[ -](?:[Cc]redits?|[Bb]alance|[Rr]epl(?:y|ies)|[Rr]oute|[Mm]odels?|[Tt]ier)$_kE'
    '|$_kB[Ss]tandard (?:or|and|vs\\.?|oder|o|ou|y|et|und) Pro$_kE'
    '|$_kB[Ss]witch(?:es|ed|ing)? to Pro$_kE'
    '|$_kB(?:Nymbot|[Cc]rédito|[Cc]rédit|[Cc]redit) Pro$_kE'
    '|${_kB}Pro-Credits?$_kE',
    unicode: true);
final RegExp _kCreditNoun = RegExp(
    '$_kB(?:credits|créditos|crédits|crédito|crédit)$_kE'
    '|$_kB(?:standard|pro|nymbot|paid)[ -]credit$_kE'
    '|$_kB(?:a|one|per|1|each|every|no|any)[ \\t]+credit$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kBalNym = RegExp(
    '$_kB(?:your|my|paid|pro|standard)[ \\t]+balance$_kE'
    '|${_kB}balance[ \\t]+(?:is|was)[ \\t]+(?:empty|0|zero|low)$_kE'
    '|${_kB}guthaben$_kE'
    '|$_kB(?:tu|el|su|mi)[ \\t]+saldo$_kE'
    '|$_kB(?:votre|ton|le|mon)[ \\t]+solde$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kLnDev = _intl(
    r'cables?|ports?|connectors?|chargers?|charging|adapters?|usb-?c|usb|earpods|docks?|channels?|nodes?|liquidity|splic\w*|lncli|lnd|cln|lnurl|bolt ?1[12]|peers?|routing|htlcs?|api|sdk|webhooks?|testnet|regtest|signet');
final RegExp _kSpaces = RegExp(r'\s+');
final RegExp _kGift = RegExp(r'\?gift\b|\?transfer\b|\bgifts?\b|\bvouchers?\b', caseSensitive: false);
final RegExp _kShortQuestion = RegExp('\\?[*_)"”’»]*\$');
final RegExp _kLeadEnd = RegExp(r':[*_]*\s*$');
final RegExp _kRow = RegExp(r'^\s*\|');
final RegExp _kHeading = RegExp(r'^\s{0,3}(#{1,6})\s');
final RegExp _kTableSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)*\|?\s*$');
final RegExp _kNumItem = RegExp(r'^(\s*)(\d{1,9})(?=[.)]\s)');
final RegExp _kClause = RegExp(r'[,;]\s+or\s+');
final RegExp _kStop = RegExp('[.!?…]+(?=[)\\]"\'”’»]*\$)');
final RegExp _kListItem = RegExp(r'^\s*(?:[-*+]|\d{1,9}[.)])\s');
final RegExp _kIndented = RegExp(r'^\s');
final RegExp _kFence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final RegExp _kLinePrefix =
    RegExp(r'^\s*(?:>\s?)*(?:[-*+]\s+|\d{1,9}[.)]\s+)?(?:#{1,6}\s+)?');
final RegExp _kLetter = RegExp(r'\p{L}', unicode: true);
final RegExp _kLower = RegExp(r'^\p{Ll}', unicode: true);
const String _kEnds = '.!?…';
const String _kWideEnds = '。！？';
const String _kClosers = ')]"\'”’»';
const Set<String> _kNeverEnds = {
  'mr', 'mrs', 'ms', 'dr', 'st', 'prof', 'sr', 'jr', 'vs', 'e.g', 'i.e'
};
final RegExp _kWordChar = RegExp(r'[A-Za-z.]');
final RegExp _kWrapEnd = RegExp(r'[,;–—(]\s*$');
final RegExp _kBlockStart =
    RegExp(r'^\s*(?:$|>|[-*+]\s|\d{1,9}[.)]\s|#{1,6}\s|\||`{3,}|~{3,})');
const String _kTier =
    '(?<!(?:iPhone|iPad|MacBook|AirPods|Watch|Galaxy|Pixel|Surface)[ \\d.]{0,6})$_kB(?:standard|pro|nymbot)[ -](?:credits?|repl(?:y|ies)|balance|route)$_kE(?![ \\t-]+(?:cards?|hours?|scores?|limits?|unions?|lines?|notes?|memos?))'
    '|${_kB}cr[ée]dit(?:o|os|s)? (?:est[áa]ndar|standard|pro|nymbot)$_kE'
    '|$_kB(?:respuestas?|réponses?) (?:est[áa]ndar|standard|pro)$_kE'
    '|$_kB(?:standard|pro|nymbot)-(?:antworten?|guthaben)$_kE';
final RegExp _kBuyCmd = RegExp(r'(?<![\w/=&?#.])\?buy(?![\w-])', caseSensitive: false);
final RegExp _kNymOwn = RegExp(
    'nymbot\\.ai'
    '|${_kB}credits[ \\t]+sheet$_kE'
    '|$_kB(?:balance|credits)$_kE[^.!?\\n]{0,40}${_kB}chat[ \\t]+header$_kE'
    '|${_kB}chat[ \\t]+header$_kE[^.!?\\n]{0,40}$_kB(?:balance|credits)$_kE'
    '|${_kB}balance[ \\t]+(?:in|at|on)[ \\t]+the[ \\t]+top[ \\t]+of[ \\t]+the[ \\t]+chat$_kE'
    '|${_kB}nymbot[ \\t]+(?:pro|standard)$_kE'
    '|${_kB}guthaben[ \\t]+in[ \\t]+der[ \\t]+kopfzeile$_kE'
    '|${_kB}saldo[ \\t]+en[ \\t]+la[ \\t]+cabecera$_kE'
    '|${_kB}solde[ \\t]+en[ \\t]+haut[ \\t]+de[ \\t]+la[ \\t]+conversation$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kBuyButton = RegExp(
    r'''(?:\b[Tt]ap|\b[Pp]ress|\b[Cc]lick|\b[Hh]it|\b[Ss]elect|\b[Cc]hoose|\b[Oo]pen)\s+(?:on\s+)?(?:the\s+)?[*_"“‘']*Buy\b|\b[Bb]uy[*_"”’']*\s+button\b|\bBuy[*_"”’']*\s+sheet\b''');
final RegExp _kTierName = RegExp(_kTier, caseSensitive: false, unicode: true);
final RegExp _kNymCredit = _intl('credits?|créditos?|crédits?|guthaben|saldo|solde');
final RegExp _kNymGoods = RegExp(
    "${_kB}nymbot(?:['’]s)?[ \\t-]+(?:(?:credit|pro|standard|paid|prepaid)[ \\t-]+)?(?:balance|packs?|plans?|paquetes?|pakete?|planes?|tarife?|forfaits?)$_kE"
    '|$_kB(?:balance|packs?|plans?|paquetes?|pakete?|planes?|tarife?|forfaits?)[ \\t]+(?:on|in|for|from|of|at|with|de|del|von|vom|bei|chez|en|für|pour|du)[ \\t]+nymbot$_kE'
    '|$_kB(?:packs?|plans?|paquetes?|pakete?|planes?|tarife?|forfaits?)[ \\t]+nymbot$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kSentenceEnd = RegExp(r'(?<=[.!?…])\s+|\n');
final RegExp _kTierAt = RegExp(r'^[ \t]+(?:on|in|at|from|for|with|of|en|de|del|du|chez|avec|bei|von|vom|für|con)[ \t]+(?:the[ \t]+)?[^\s,;:!?]+(?=[\s,;:!?]|$)(?![ \t]+(?:repl(?:y|ies)|answers?|messages?|chats?|models?|tokens?|requests?|prompts?)(?![\w]))');
final RegExp _kBrandLead = RegExp(
    r"^[^\p{L}\p{N}]*(?!(?:Nymbot|Nymchat|Standard|Pro|Android|Web|Mac|Lightning|Bitcoin|Google|Apple|Zapstore|Your|Yours|The|A|An|My|Our|Their|His|Her|Its|This|That|These|Those|Each|Every|Any|Some|No|All|Both|More|Extra|Free|New|Paid|Unused|Remaining|Leftover|Spare|Bonus|Daily|Monthly|Buy|Get|Use|Add|Grab|Earn|Spend|Need|Want|Got|Have|Keep|Save|Check|Top|Refill|Using|Buying|Getting|Spending|With|Without|For|From|On|In|At|Of|To|And|Or|Plus|Only|Just|Also|Then|So|But|If|When|Once|After|Before|Unlike|Like|Many|Few|Several|One|Two|Three|Four|Five|Ten|I|You|We|They|It|Sorry|Yes|Yeah|Sure|Note|Tip|Okay|OK|Hey|Hi|Hello|Great|Ein|Eine|Einen|Einem|Einer|Dein|Deine|Deinen|Deinem|Deiner|Mein|Meine|Meinen|Ihr|Ihre|Ihren|Unser|Unsere|Die|Der|Das|Den|Dem|Des|Mehr|Neue|Neuen|Weitere|Mit|Ohne|Für|Kauf|Kaufe|Hol|Nutze|Alle|Jede|Jeder|Jedes|Keine|Ja|Gern|Klar|Un|Una|Unos|Unas|El|La|Los|Las|Lo|Tu|Tus|Mi|Mis|Su|Sus|Nuestro|Nuestra|Nuestros|Nuestras|Este|Esta|Estos|Estas|Cada|Más|Con|Sin|Para|Compra|Usa|Une|Le|Les|Ton|Ta|Tes|Mon|Ma|Mes|Votre|Vos|Notre|Nos|Ce|Cet|Cette|Ces|Chaque|Du|Avec|Sans|Pour|Achète|Utilise|Tous|Toutes|Leur|Leurs|Oui)(?:['’]s)?[^\p{L}\p{N}]*$)\p{Lu}[\p{L}\p{N}-]*(?:['’]s)?[^\p{L}\p{N}]*$",
    unicode: true);
final RegExp _kNegated = RegExp(
    "$_kB(?:not|no|never|cannot|nicht|nichts|kein\\w*|nunca|pas|jamais)$_kE|n['’]t$_kE",
    caseSensitive: false,
    unicode: true);
final RegExp _kNymAnchor = RegExp(
    '${_kB}nymbot$_kE'
    '|(?<![\\w/=&?#.])\\?(?:buy|balance|gift|transfer|model|image|speak|video|research|help|commands|anon|git|compare)(?![\\w-])'
    '|$_kTier'
    '|${_kB}standard (?:or|and|vs\\.?|oder|o|ou|y|et|und) pro$_kE'
    '|${_kB}switch(?:es|ed|ing)? to pro$_kE'
    '|${_kB}credits sheet$_kE'
    '|${_kB}free (?:daily )?(?:repl(?:y|ies)|messages|allowance)$_kE'
    '|today[\'’]s free'
    '|$_kB(?:more|sharper) (?:free )?(?:repl(?:y|ies)|messages)$_kE'
    '|gratis-antworten|gratis-nachrichten|respuestas gratis|mensajes gratis|réponses gratuites|respostas grátis',
    caseSensitive: false,
    unicode: true);
final RegExp _kNymStrong = RegExp(
    '(?<![\\w/=&?#.])\\?(?:buy|balance|gift|transfer|model|image|speak|video|research|help|commands|anon|git|compare)(?![\\w-])'
    '|$_kTier'
    '|${_kB}standard (?:or|and|vs\\.?|oder|o|ou|y|et|und) pro$_kE'
    '|${_kB}switch(?:es|ed|ing)? to pro$_kE'
    '|${_kB}credits sheet$_kE'
    '|${_kB}free (?:daily )?(?:repl(?:y|ies)|messages|allowance)$_kE'
    '|today[\'’]s free'
    '|$_kB(?:more|sharper) (?:free )?(?:repl(?:y|ies)|messages)$_kE'
    '|gratis-antworten|gratis-nachrichten|respuestas gratis|mensajes gratis|réponses gratuites|respostas grátis',
    caseSensitive: false,
    unicode: true);
final RegExp _kNoBuy = RegExp(
    r"\b(?:can['’]?t|cannot|can\s+not|couldn['’]?t|won['’]?t|doesn['’]?t|don['’]?t|didn['’]?t|(?:am|is|are)\s+not\s+able\s+to|(?:isn|aren)['’]t\s+able\s+to|unable\s+to|not\s+able\s+to|never)\s+(?:\w+\s+){0,3}?(?:buy|purchase|make\s+(?:any\s+)?purchases|place\s+(?:an?\s+)?orders?|order|shop|sell)\b",
    caseSensitive: false);
final RegExp _kNoBuyIntl = _intl(
    r'kann\s+(?:ich\s+)?(?:nichts|nicht|keine)|no\s+(?:puedo|puede|puedes|podemos)|ne\s+(?:peux|peut|pouvons)\s+pas');
final RegExp _kCreditIntl = _intl('credits?|créditos?|crédits?|guthaben|saldo|solde');
final RegExp _kCredObj = RegExp(r'credit|balance|pack|\bpro\b|standard|more', caseSensitive: false);
final RegExp _kPronoun = RegExp(r'^(?:them|those|these|they|some|it)$', caseSensitive: false);
final RegExp _kBalSurface = RegExp(
    r'\b(?:tap|taps|tapped|tapping|press|pressing|click|clicking|hit|hitting)\s+(?:on\s+)?(?:your|the|their|my)\s+(?:(?:nymbot|credit)\s+)?(?:balance|credits)\b'
    r'|\bbalance\s+(?:in|at|on)\s+(?:the\s+)?(?:top|(?:chat\s+)?header|top\s+bar|toolbar)\b'
    r'|\bchat\s+header\b',
    caseSensitive: false);
final RegExp _kBalSurfaceIntl = _intl(
    r'tipp\w*\s+(?:auf\s+)?(?:dein|deinen|ihr|ihren|das)\s+guthaben|guthaben\s+in\s+der\s+kopfzeile'
    r'|(?:toca|tocar|pulsa|pulsar)\s+(?:en\s+)?(?:tu|el|su)\s+saldo|saldo\s+en\s+la\s+cabecera'
    r'|(?:touche|touchez|toucher|appuie|appuyez)\s+(?:sur\s+)?(?:ton|votre|le)\s+solde');
final RegExp _kPackStep = RegExp(
    r'\b(?:pick|choose|select)\s+(?:a|one|your)\s+(?:credit\s+)?pack\b|\b(?:pick|choose|select)\s+how\s+many\s+credits\b',
    caseSensitive: false);
final RegExp _kOwnApp = RegExp(
    r"\byour\s+(?:own\s+)?(?:[\w-]+\s+){0,2}?(?:app|apps|shop|store|site|website|saas|product|platform|backend|server|game|bot)\b|\bapp['’]s\b|\bstripe\b|\bcheckout\b|\bwebhooks?\b|\bwidgets?\b|\bcomponents?\b|\bflutter\b|\breact\b|\bswiftui\b|\bmodal\b|\bbottom\s+sheet\b|\bcart\b|\bproduct\s+(?:page|card|image|screen)\b|\bcustomers?\b|\bbackend\b",
    caseSensitive: false);
final RegExp _kOtherSite = RegExp(
    r'(?<![\w.@/-])(?!nymbot\.ai\b|nymchat\.app\b)[a-z0-9][a-z0-9-]*\.(?:com|org|net|io|co|app|ai|dev|me|tv|store|shop)\b',
    caseSensitive: false);
final RegExp _kOtherBrand = RegExp(
    r"(?<=[\p{Ll}\p{N},;:—–]\s)(?!(?:Nymbot|Nymchat|Apple|Google|Android|Lightning|Bitcoin)['’]s)\p{Lu}[\p{L}\p{N}]+['’]s(?![\p{L}])"
    r'|(?<![\p{L}])(?!(?:iPhone|iPad|iOS|iPadOS|macOS|watchOS|visionOS|Nymbot|Nymchat)(?![\p{L}]))\p{Ll}*\p{Lu}[\p{Ll}\p{N}]+\p{Lu}[\p{L}\p{N}]*'
    r'|(?<=[\p{Ll}\p{N},;:—–]\s)(?!(?:Nymbot|Nymchat|Android|Web|Website|iOS|iPhone|iPad|Mac|Safari|Chrome|Firefox|Google|Play|Store|Zapstore|Apple|App|Lightning|Bitcoin|Pro|Standard|Credits?|Buy|Settings|UTC|PM|AM|OK|USD|EUR|BTC|QR|API|URL|FAQ|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December)(?![\p{L}\p{N}]))\p{Lu}[\p{L}\p{N}]+',
    unicode: true);
final RegExp _kNymStoreStrict = RegExp(
    'nymbot\\.ai|$_kB(?:nymbot[ \\t]+(?:for|on|para|pour|für)[ \\t]+(?:android|ios|iphone|the[ \\t]+web|web))$_kE'
    "|$_kB(?:the|our|nymbot['’]?s?)[ \\t]+(?:nymbot[ \\t]+)?(?:web[ \\t]?app|android[ \\t]+app)$_kE"
    '|$_kB(?:app web|application web|app de android|aplicación de android|aplicación web|application android|android-app|web-app)$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kNoNeedToBuy = RegExp(
    r"\b(?:nothing\s+to\s+(?:buy|pay)|no\s+need\s+to\s+(?:buy|pay)|without\s+(?:buying|paying)|(?:don['’]t|doesn['’]t|won['’]t|never)\s+(?:have\s+to\s+|need\s+to\s+)?(?:buy|pay)(?:\s+for)?\s+(?:anything|the\s+app|it)\s+to\s+(?:download|install|use|try)|free\s+to\s+(?:download|install))\b",
    caseSensitive: false);
final RegExp _kOfOther = RegExp(r'^\s+(?:de|del|des|du|von|vom|der|of)\s+(?!nymbot)', caseSensitive: false);
final RegExp _kPayNoun = RegExp(r'\bpa(?:y|ys|id|ying|yments?)\b', caseSensitive: false);
final RegExp _kHereIos = RegExp(r'\b(?:ios|iphone|ipad|mac|here|this\s+app|the\s+app|in-app)\b', caseSensitive: false);
final RegExp _kOwnCount = RegExp(
    r"\byou(?:['’]ve|\s+have)\s+(?:only\s+|just\s+)?[\d,.]+\s+(?:(?:standard|pro|free)\s+)?credits?\s+(?:left|remaining)\b",
    caseSensitive: false);
final RegExp _kNymRate = _intl(
    r'(?:per|a|an|each|every)[ \t]+(?:[\w-]+[ \t]+){0,2}?(?:credits?|repl(?:y|ies)|messages?|answers?|images?|tokens?|créditos?|crédits?|respuestas?|réponses?|antworten?)|each|apiece|costs?|costing|priced|prices?|pricing|charges?|charged|metered|cuesta|cuestan|coûte|coûtent|kostet|kosten');
final RegExp _kOtherBot = RegExp(r'\b(?:discord|telegram|slack|twitch|cogs?)\b', caseSensitive: false);
final RegExp _kOwnBot = RegExp(
    r'\byour\s+(?:own\s+)?(?:(?!(?:ai|chat|helper|assistant|friendly|helpful|personal|favou?rite)\b)[\w-]+\s+){0,2}?bot\b',
    caseSensitive: false);
final RegExp _kBotAudience = RegExp(
    r'''\b(?:members|users|players|viewers|subscribers|followers|customers|people|everyone|anyone)\s+(?:can\s+|just\s+|then\s+|simply\s+|will\s+)?(?:type|send|use|run|enter)\s+[`'"“*]*\?[a-z]''',
    caseSensitive: false);
final RegExp _kBuyAnchor = RegExp(
    '(?<![\\w/=&?#.])\\?buy(?![\\w-])'
    '|$_kB(?:credits|buy) sheet$_kE'
    '|${_kB}standard (?:or|and|vs\\.?) pro$_kE'
    '|$_kTier'
    '|${_kB}switch(?:es|ed|ing)? to pro$_kE'
    '|${_kB}credits? (?:show(?:s)? up|lands?|arrives?|appears?|are added|get added)$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kPassiveBuy = RegExp(
    r"\b(credits?|they|these|those|packs?)\b(?:['’]re|\s+(?:are|is|were|can|can['’]t|cannot|could|must|will|may|get))(?:\s+(?:only|also|not|be|now|still|just|easily))*\s+(?:bought|sold|purchased|topped up|available|on sale)\b",
    caseSensitive: false);
final RegExp _kBuyVerb = RegExp(
    r'\b(?:buy|buys|buying|purchase|purchases|purchasing|sell|sells|selling|top[ -]?up|tops[ -]up|topp(?:ed|ing)[ -]up)\b'
    r'|\btop(?:s|ped|ping)?\s+(?:them|it|yours|your\s+(?:(?:pro|standard)\s+)?(?:balance|credits))\s+up\b',
    caseSensitive: false);
final RegExp _kTopUpWord = RegExp(r'\btop(?:s|ped|ping)?[ -]?(?:\w+\s+)?up\b', caseSensitive: false);
final RegExp _kGetVerb = RegExp(
    r'\b(?:get|gets|getting|add|adds|adding|grab|grabs|fund|funds|refill|refills|recharge|recharges|reload|reloads|stock\s+up\s+on)\b',
    caseSensitive: false);
final RegExp _kRefill = RegExp(r'^(?:refill|recharge|reload)', caseSensitive: false);
final RegExp _kAimTail = RegExp(
    r'^(?:\s+((?:(?:some|a\s+few|a\s+little)\s+)?more(?:\s+(?:(?:nymbot|standard|pro)\s+)?credits?)?|some(?:\s+(?:(?:nymbot|standard|pro)\s+)?credits?)?|them|those|(?:the\s+same|your|new|extra|additional|any)\s+(?:(?:nymbot|standard|pro)\s+)?credits?|(?:nymbot|standard|pro)\s+credits?|credits?|(?:a\s+|more\s+)?(?:credit\s+)?packs?|your\s+(?:(?:pro|standard)\s+)?balance|pro|standard)\b)?'
    r'(?=\s*(?:$|[.,;:!?…)\]—–]|(?:to|and|or|now|here|there|anytime|any\s+time|with|from|on|in|at|via|through|using|first|again|today|right|if|when|so|then|for|before|after|while|too|inside|instead|whenever|once|later|is|are|online|by)\b))',
    caseSensitive: false);
final RegExp _kNymShop = RegExp(
    r"nymbot\.ai|\b(?:the|our|nymbot['’]?s?)\s+(?:nymbot\s+)?(?:web\s?app|android\s+app)\b|\b(?:our|nymbot['’]?s?|the\s+nymbot)\s+(?:web)?site\b|\bgoogle\s+play\b(?!\s+(?:billing|console|services|developer|policy|policies|protect|gift|balance))|\bplay\s+store\b|\bzapstore\b|\bnymbot\s+(?:for|on)\s+(?:android|ios|iphone|the\s+web)\b",
    caseSensitive: false);
final RegExp _kDownloadShop = RegExp(r'google|play|zapstore', caseSensitive: false);
final RegExp _kNymShopNear = RegExp(
    r"nymbot\.ai|\b(?:the|our|nymbot['’]?s?)\s+(?:nymbot\s+)?(?:web\s?app|android\s+app)\b|\b(?:our|nymbot['’]?s?|the\s+nymbot)\s+(?:web)?site\b",
    caseSensitive: false);
final RegExp _kWebShop = RegExp(
    r'\bon\s+the\s+web\b|\bin\s+(?:your|a|the)\s+(?:web\s+)?browser\b|\b(?:in|via|with|from)\s+safari\b',
    caseSensitive: false);
final RegExp _kLabelGoal = RegExp(
    r'\b(?:to\s+get|for|get)\s+(?:some\s+)?(?:more|credits?)\b|\bto\s+top[ -]?up\b|\bcredits?\b|\bbalance\b',
    caseSensitive: false);
final RegExp _kBuyFlow = RegExp(r'\b(?:purchase|payment|buy)\s+(?:flow|sheet|screen)\b', caseSensitive: false);
final RegExp _kNymPayer = RegExp(
    '${_kB}nymbot$_kE|$_kTier|(?<![\\w/=&?#.])\\?buy(?![\\w-])',
    caseSensitive: false,
    unicode: true);
final RegExp _kPaidIn = RegExp(
    '$_kB(?:pa(?:y|ys|id|ying|yment|yments)|takes|take|accepts?|accepted|bought|sold|charged|priced|bezahlt|bezahlen|paga|pagan|pagar|pagas|payé|payés|payer|paie)$_kE'
    '(?:[ \\t]+(?:for|only|is|are|in|with|over|via|using|through|by|exclusively|just|ausschließlich|nur|mit|con|solo|en|avec|par|seulement)){0,4}'
    '[ \\t]+(?:bitcoin|btc|lightning|sats|satoshis)$_kE',
    caseSensitive: false,
    unicode: true);
final RegExp _kZappy = RegExp(r'\b(?:zaps?|zapping|zapped|tips?|tipping|podcasts?)\b', caseSensitive: false);
final RegExp _kPayStep = RegExp(
    r'\bpa(?:y|ys|id|ying)\b[^.!?\n]*\b(?:invoices?|wallets?|qr|lightning|bitcoin|sats)\b'
    r'|\b(?:invoices?|wallets?|qr|lightning|bitcoin|sats)\b[^.!?\n]*\bpa(?:y|ys|id|ying)\b'
    r'|\bscan\w*\b[^.!?\n]*\bqr\b|\bqr\b[^.!?\n]*\bscan'
    r"|^\W*(?:after|once|when|as\s+soon\s+as)\s+(?:paying|you\s+pay|you['’]ve\s+paid|you\s+paid|the\s+payment|payment)\b",
    caseSensitive: false);
final RegExp _kNymUnit = RegExp(
    '$_kTier|(?<![\\w/=&?#.])\\?(?:image|speak|video|research|model|compare|git|ask)(?![\\w-])',
    caseSensitive: false,
    unicode: true);
final RegExp _kCreditWord = _intl('credits?|créditos?|crédits?');
final RegExp _kSatsMoney = _intl('sats?|satoshis?');
final RegExp _kCreditOrReply = _intl('credits?|repl(?:y|ies)|créditos?|crédits?|respuestas?|réponses?|antworten?');
final RegExp _kEmph = RegExp(r'[*_]{1,3}');
final RegExp _kIntlThere = _intl('gibt es|gibt’s');
final RegExp _kCreditOrBalance = RegExp(r'credit|balance', caseSensitive: false);
final RegExp _kPayMeansWord = RegExp(r'\b(?:lightning|bitcoin|btc|sats|wallets?|invoices?|payments?)\b', caseSensitive: false);

bool _sells(String s, _Kind kind, String unit, _Doc d) =>
    kind == _Kind.reply ? _replySells(s, unit, d) : _appSells(s, kind, unit, d);

bool _appSells(String s, _Kind kind, String unit, _Doc d) {
  final spans = _codeSpans(s);
  bool inCode(int p) => spans.any((r) => p >= r.$1 && p < r.$2);
  if (_kBuyBare.allMatches(s).any((m) => !inCode(m.start))) return true;
  for (final (a, b) in spans) {
    if (_kBuyCode.hasMatch(s.substring(a, b).replaceAll(_kTicks, ''))) return true;
  }
  var plain = s;
  for (final (a, b) in spans.reversed) {
    plain = plain.replaceRange(a, b, ' ');
  }
  var words = plain.replaceAll(_kUrlOrName, ' ');
  if (kind == _Kind.note) {
    words = words
        .replaceAll(_kQuotedName, ' ')
        .replaceAllMapped(_kNoteName, (m) => '${m[1]} ${m[3]}');
    plain = words;
  }
  final forced = kind == _Kind.notice ||
      (kind == _Kind.note && (_kTopUpAny.hasMatch(words) || _kImperative.hasMatch(words)));
  final ctx = forced ||
      d.credNym(unit) ||
      d.balNym(unit) ||
      _kNymbot.hasMatch(unit) ||
      _kRepliesWord.hasMatch(unit) ||
      _kProNym.hasMatch(unit);
  final credits = d.credNym(plain);
  final credit = credits || d.balNym(plain);
  final nymbot = _kNymbot.hasMatch(plain);
  final store = _kStore.hasMatch(plain) || _kStoreIntl.hasMatch(plain);
  final lightning = d.lnOk && _kLightning.hasMatch(plain);
  final act = _kAct.hasMatch(words) || _kActIntl.hasMatch(words);
  final obtain = _kObtain.hasMatch(words) || _kObtainIntl.hasMatch(words);
  final payWord = _kPayWord.hasMatch(plain) || _kPayIntl.hasMatch(plain);
  final invoice = _kInvoice.hasMatch(words) || _kInvoiceIntl.hasMatch(words);
  if (_kLabel.hasMatch(plain)) return true;
  if (act && (ctx || credit || nymbot || store || lightning)) return true;
  if (_kPurchaseFlow.hasMatch(plain)) return true;
  if (lightning && (_kPay.hasMatch(plain) || _kPayIntl.hasMatch(plain)) && (ctx || _kReplies.hasMatch(plain))) {
    return true;
  }
  if (invoice &&
      (kind == _Kind.notice ||
          credits ||
          nymbot ||
          (lightning && payWord && (ctx || d.wide)) ||
          (_kInvoiceAct.hasMatch(words) &&
              (d.credNym(unit) || d.credits || d.nymbot || _kProNym.hasMatch(unit))))) {
    return true;
  }
  if (_kPaying.hasMatch(plain) && credits) return true;
  if (store && credit) return true;
  if (obtain && _kNymStore.hasMatch(plain)) return true;
  if (obtain &&
      (_kViaNoLn.hasMatch(plain) || _kViaIntl.hasMatch(plain) || lightning) &&
      (ctx || d.wide || credit || nymbot)) {
    return true;
  }
  final payStep = (_kScanQr.hasMatch(plain) && _kWalletish.hasMatch(plain)) || (payWord && lightning);
  if ((payStep || _kPayCue.hasMatch(plain)) &&
      (ctx || d.wide || (_kPayCue.hasMatch(d.whole) && _kScanQr.hasMatch(d.whole)))) {
    return true;
  }
  if (d.lnOk && _payMeans(plain)) return true;
  final around = '$unit\n$plain';
  if (_kGetMore.hasMatch(plain) &&
      (_kShopNoLn.hasMatch(around) || (d.lnOk && _kLightning.hasMatch(around)))) {
    return true;
  }
  if (_storeOnly(plain) && (d.credits || d.pro || _kWhereQ.hasMatch(d.whole))) return true;
  return (_kPricedWord.hasMatch(plain) || credits || _kProNym.hasMatch(plain)) && _kMoney.hasMatch(plain);
}

bool _wraps(String line, String next) =>
    _kWrapEnd.hasMatch(line) &&
    !_kBlockStart.hasMatch(next) &&
    !RegExp(r'^\s*(?:#{1,6}\s|\|)').hasMatch(line);

List<(int, int, bool)> _fenceSpans(List<String> lines) {
  final out = <(int, int, bool)>[];
  String? fence;
  var open = 0;
  for (var i = 0; i < lines.length; i++) {
    final f = _kFence.firstMatch(lines[i])?.group(1);
    if (fence == null) {
      if (f != null) {
        fence = f;
        open = i;
      }
    } else if (f != null && f[0] == fence[0] && f.length >= fence.length && lines[i].trim() == f) {
      out.add((open, i, true));
      fence = null;
    }
  }
  if (fence != null) out.add((open, lines.length - 1, false));
  return out;
}

List<String> _units(List<String> lines, List<bool> code) {
  final unit = List<String>.filled(lines.length, '');
  bool prose(int k) => k < lines.length && !code[k] && lines[k].trim().isNotEmpty;
  var i = 0;
  while (i < lines.length) {
    if (!prose(i)) {
      i++;
      continue;
    }
    var j = i;
    while (true) {
      while (prose(j + 1)) {
        j++;
      }
      var k = j + 1;
      while (k < lines.length && !code[k] && lines[k].trim().isEmpty) {
        k++;
      }
      final joins = prose(k) &&
          _kListItem.hasMatch(lines[k]) &&
          (_kListItem.hasMatch(lines[j]) || _kIndented.hasMatch(lines[j]) || _kLeadEnd.hasMatch(lines[j]));
      if (!joins) break;
      j = k;
    }
    final text = lines.sublist(i, j + 1).join('\n');
    for (var x = i; x <= j; x++) {
      unit[x] = text;
    }
    i = j + 1;
  }
  return unit;
}

void _dropLeadIn(List<String> out) {
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  if (out.isEmpty || !_kLeadEnd.hasMatch(out.last)) return;
  final rest = _withoutLastSentence(out.removeLast());
  if (rest != null) {
    out.add(rest);
    return;
  }
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
}

List<String>? _keptRows(List<String> rows, List<String> out, _Kind kind, _Doc d) {
  if (!_sellAny(rows.join('\n'), kind)) return null;
  final head = rows.length > 1 && _kTableSep.hasMatch(rows[1]) ? 2 : 0;
  final lead = out.lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  final ctx = [lead, ...rows.take(head)].join('\n');
  final body = [for (final r in rows.skip(head)) if (!_rowSells(r, ctx, kind, d)) r];
  if (body.length == rows.length - head) return null;
  return body.isEmpty ? <String>[] : [...rows.take(head), ...body];
}

bool _rowSells(String row, String ctx, _Kind kind, _Doc d) {
  final unit = '$ctx\n$row';
  for (final cell in row.split('|')) {
    if (cell.trim().isNotEmpty &&
        _sellAny(cell, kind) &&
        _rewriteBuyProse(cell, kind, unit, d) != cell) {
      return true;
    }
  }
  if (kind == _Kind.reply) return d.nymPara(unit) && _nymPrice(d.cmds(unit), row);
  if (!_kMoney.hasMatch(row)) return false;
  return _kPricedWord.hasMatch(unit) || d.credNym(unit) || _kProNym.hasMatch(unit) || _kPriceWord.hasMatch(unit);
}

void _dropOrphans(List<String> out, Set<int> lostAt) {
  for (var i = out.length - 1; i >= 0; i--) {
    final line = out[i];
    final head = _kHeading.firstMatch(line);
    if (head == null && !_kLeadEnd.hasMatch(line)) continue;
    var n = i + 1;
    while (n < out.length && out[n].trim().isEmpty) {
      n++;
    }
    final end = n >= out.length;
    if (!lostAt.any((v) => v > i && (end || v <= n))) continue;
    final next = end ? null : out[n];
    final bool orphan;
    if (head != null) {
      final after = next == null ? null : _kHeading.firstMatch(next);
      orphan = next == null || (after != null && after[1]!.length <= head[1]!.length);
    } else {
      orphan = next == null ||
          !(_kListItem.hasMatch(next) || _kRow.hasMatch(next) || _kFence.hasMatch(next) || _kIndented.hasMatch(next));
    }
    if (!orphan) continue;
    final rest = head == null ? _withoutLastSentence(line) : null;
    if (rest != null) {
      out[i] = rest;
      continue;
    }
    out.removeAt(i);
    while (i < out.length && out[i].trim().isEmpty && (i == 0 || out[i - 1].trim().isEmpty)) {
      out.removeAt(i);
    }
  }
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
}

void _renumber(List<String> out) {
  int? prev;
  var indent = '';
  for (var i = 0; i < out.length; i++) {
    final line = out[i];
    final m = _kNumItem.firstMatch(line);
    if (m == null) {
      if (line.trim().isNotEmpty && !_kIndented.hasMatch(line)) prev = null;
      continue;
    }
    final n = int.parse(m[2]!);
    if (prev != null && m[1] == indent && n > prev + 1) {
      prev = prev + 1;
      out[i] = '${m[1]}$prev${line.substring(m.end)}';
    } else {
      prev = n;
      indent = m[1]!;
    }
  }
}

String _rewriteBuySentences(String text, _Kind kind) {
  final d = _Doc(text, kind);
  final lines = text.split('\n');
  final fences = {for (final (a, b, closed) in _fenceSpans(lines)) a: (b, closed)};
  final code = _codeLines(lines);
  final units = _units(lines, code);
  final out = <String>[];
  var dropped = false;
  var skip = false;
  var skippedBlank = false;
  var renumber = false;
  final lostAt = <int>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final span = fences[i];
    if (span != null) {
      final (end, closed) = span;
      final inner = lines.sublist(i + 1, closed ? end : end + 1);
      final kept = [for (final l in inner) if (d.otherBot || !_kBuyCode.hasMatch(l)) l];
      final emptied = kept.length < inner.length && kept.every((l) => l.trim().isEmpty);
      if (skip || emptied) {
        if (!skip) _dropLeadIn(out);
        lostAt.add(out.length);
        dropped = true;
      } else {
        out
          ..add(line)
          ..addAll(kept);
        if (closed) out.add(lines[end]);
        dropped = false;
      }
      skip = false;
      i = end;
      continue;
    }
    if (skip) {
      if (line.trim().isEmpty || _kListItem.hasMatch(line) || _kIndented.hasMatch(line)) {
        if (_kListItem.hasMatch(line) && _kGift.hasMatch(line) && !_sells(line, kind, units[i], d)) {
          out.add(line);
          dropped = false;
          skippedBlank = false;
          renumber = true;
          continue;
        }
        skippedBlank = line.trim().isEmpty;
        if (!skippedBlank) lostAt.add(out.length);
        continue;
      }
      skip = false;
      if (skippedBlank && out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
    }
    if (!code[i] && _kRow.hasMatch(line) && (i == 0 || code[i - 1] || !_kRow.hasMatch(lines[i - 1]))) {
      var j = i;
      while (j + 1 < lines.length && !code[j + 1] && _kRow.hasMatch(lines[j + 1])) {
        j++;
      }
      final rows = lines.sublist(i, j + 1);
      i = j;
      final kept = _keptRows(rows, out, kind, d);
      if (kept == null) {
        out.addAll(rows);
        dropped = false;
      } else if (kept.isEmpty) {
        _dropLeadIn(out);
        lostAt.add(out.length);
        dropped = true;
      } else {
        out.addAll(kept);
        dropped = false;
      }
      continue;
    }
    var end = i;
    while (end + 1 < lines.length && _wraps(lines[end], lines[end + 1])) {
      end++;
    }
    final block = lines.sublist(i, end + 1).join('\n');
    final unit = units[i];
    var next = end + 1;
    while (next < lines.length && !code[next] && lines[next].trim().isEmpty) {
      next++;
    }
    final leadIn = _kLeadEnd.hasMatch(block) &&
        next < lines.length &&
        (code[next] || _kListItem.hasMatch(lines[next]));
    i = end;
    if (!_sellAny(unit, kind)) {
      if (dropped && block.trim().isEmpty && (out.isEmpty || out.last.trim().isEmpty)) {
        continue;
      }
      out.add(block);
      if (block.trim().isNotEmpty) dropped = false;
      continue;
    }
    final kept = _rewriteBuyLine(block, kind, unit, d);
    if (leadIn && (kept == null || !_kLeadEnd.hasMatch(kept))) {
      skip = true;
      skippedBlank = false;
    }
    if (kept == null) {
      lostAt.add(out.length);
      dropped = true;
      renumber = true;
      continue;
    }
    out.add(kept);
    dropped = false;
  }
  if (dropped || skip) {
    while (out.isNotEmpty && out.last.trim().isEmpty) {
      out.removeLast();
    }
  }
  if (renumber) _renumber(out);
  if (lostAt.isNotEmpty) _dropOrphans(out, lostAt);
  return out.join('\n');
}

bool _continuesAfter(String body, int at, String run, int next) {
  if (next >= body.length) return false;
  var w = at;
  while (w > 0 && _kWordChar.hasMatch(body[w - 1])) {
    w--;
  }
  final word = body.substring(w, at).toLowerCase();
  if (run == '.' && _kNeverEnds.contains(word)) return true;
  final trailing =
      run.contains('…') || run.contains('..') || (run == '.' && word == 'etc');
  return trailing && _kLower.hasMatch(body[next]);
}

String? _rewriteBuyLine(String line, _Kind kind, String unit, _Doc d) {
  final prefix = _kLinePrefix.firstMatch(line)!.group(0)!;
  final kept = _rewriteBuyProse(line.substring(prefix.length), kind, unit, d);
  return kept == null ? null : prefix + kept;
}

String? _withoutLastSentence(String line) {
  final prefix = _kLinePrefix.firstMatch(line)!.group(0)!;
  final (lead, sentences) = _split(line.substring(prefix.length));
  if (sentences.length < 2) return null;
  return prefix + _join(lead, sentences.sublist(0, sentences.length - 1), '');
}

String _join(String lead, List<(String, String)> kept, String trailing) {
  final out = StringBuffer(lead);
  for (var k = 0; k < kept.length; k++) {
    out.write(kept[k].$1);
    out.write(k == kept.length - 1 ? trailing : kept[k].$2);
  }
  return out.toString();
}

bool _isSpace(String ch) => ch.trim().isEmpty;

List<(int, int)> _codeSpans(String s) {
  final out = <(int, int)>[];
  int runAt(int i) {
    var r = 0;
    while (i + r < s.length && s[i + r] == '`') {
      r++;
    }
    return r;
  }

  var i = 0;
  while (i < s.length) {
    if (s[i] != '`') {
      i++;
      continue;
    }
    final run = runAt(i);
    var j = i + run;
    var close = -1;
    while (j < s.length) {
      if (s[j] != '`') {
        j++;
        continue;
      }
      final r = runAt(j);
      if (r == run) {
        close = j;
        break;
      }
      j += r;
    }
    if (close < 0) {
      i += run;
      continue;
    }
    out.add((i, close + run));
    i = close + run;
  }
  return out;
}

(String, List<(String, String)>) _split(String body) {
  final spans = {for (final (a, b) in _codeSpans(body)) a: b};
  final n = body.length;
  var i = 0;
  while (i < n && _isSpace(body[i])) {
    i++;
  }
  final lead = body.substring(0, i);
  final sentences = <(String, String)>[];
  var start = i;
  while (i < n) {
    final end = spans[i];
    if (end != null) {
      i = end;
      continue;
    }
    final ch = body[i];
    final wide = _kWideEnds.contains(ch);
    if (!wide && !_kEnds.contains(ch)) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < n && (_kEnds.contains(body[j]) || _kWideEnds.contains(body[j]))) {
      j++;
    }
    final run = body.substring(i, j);
    while (j < n && _kClosers.contains(body[j])) {
      j++;
    }
    if (j >= n) {
      i = n;
      break;
    }
    if (!wide && !_isSpace(body[j])) {
      i = j;
      continue;
    }
    var k = j;
    while (k < n && _isSpace(body[k])) {
      k++;
    }
    if (!wide && _continuesAfter(body, i, run, k)) {
      i = k;
      continue;
    }
    sentences.add((body.substring(start, j), body.substring(j, k)));
    start = k;
    i = k;
  }
  if (start < n) {
    final rest = body.substring(start);
    final kept = rest.trimRight();
    sentences.add((kept, rest.substring(kept.length)));
  }
  return (lead, sentences);
}

String? _rewriteBuyProse(String body, _Kind kind, String unit, _Doc d) {
  final (lead, sentences) = _split(body);
  if (sentences.isEmpty) return body;
  final trailing = sentences.last.$2;
  final shown = [for (final (sentence, _) in sentences) _rewriteBuySentence(sentence, kind, unit, d)];
  for (var k = shown.length - 2; k >= 0; k--) {
    final q = shown[k];
    if (q != null &&
        shown[k + 1] == null &&
        _kShortQuestion.hasMatch(q.trimRight()) &&
        q.trim().split(_kSpaces).length <= 5) {
      shown[k] = null;
    }
  }
  if (kind == _Kind.reply) {
    for (var k = 0; k + 1 < shown.length; k++) {
      if (shown[k] != null &&
          shown[k + 1] != null &&
          d.nymPara(unit) &&
          _cantPayHere(sentences[k].$1, unit, d) &&
          _storeNext(sentences[k + 1].$1, unit, d)) {
        shown[k] = null;
        shown[k + 1] = null;
      }
    }
  }
  if (kind == _Kind.reply && shown.contains(null)) {
    for (var k = 0; k < shown.length; k++) {
      if (shown[k] case final s? when _storeOnly(s)) shown[k] = null;
    }
  }
  final kept = <(String, String)>[
    for (var k = 0; k < sentences.length; k++)
      if (shown[k] case final s?) (s, sentences[k].$2)
  ];
  if (kept.isEmpty) return null;
  return _join(lead, kept, trailing);
}

String? _rewriteBuySentence(String sentence, _Kind kind, String unit, _Doc d) {
  final s = d.otherBot ? sentence : sentence.replaceAll(_kBuyInList, '');
  if (!_sells(s, kind, unit, d)) return s;
  final spanEnds = {for (final (a, b) in _codeSpans(s)) a: b};
  final groups = <(int, int)>[];
  var depth = 0;
  var open = -1;
  for (var i = 0; i < s.length; i++) {
    final spanEnd = spanEnds[i];
    if (spanEnd != null) {
      i = spanEnd - 1;
      continue;
    }
    if (s[i] == '(') {
      if (depth == 0) open = i;
      depth++;
    } else if (s[i] == ')' && depth > 0) {
      depth--;
      if (depth == 0) groups.add((open, i + 1));
    }
  }
  final hit = [
    for (final g in groups)
      if (_sells(s.substring(g.$1, g.$2), kind, unit, d)) g
  ];
  if (hit.isNotEmpty) {
    var kept = s;
    for (final (a, b) in hit.reversed) {
      var from = a;
      while (from > 0 && _isSpace(kept[from - 1])) {
        from--;
      }
      kept = kept.substring(0, from) + kept.substring(b);
    }
    if (_kLetter.hasMatch(kept) && !_sells(kept, kind, unit, d)) return kept;
  }
  for (final c in _kClause.allMatches(s).toList().reversed) {
    final head = s.substring(0, c.start);
    if (_kLetter.hasMatch(head) &&
        !_sells(head, kind, unit, d) &&
        _sells(s.substring(c.end), kind, unit, d)) {
      return head + (_kStop.firstMatch(s.trimRight())?.group(0) ?? '.');
    }
  }
  return null;
}
