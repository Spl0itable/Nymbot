import '../config.dart';
import '../features/i18n/i18n.dart';
import '../models/bot.dart';
import '../models/conversation.dart';

typedef CapLimits = ({
  int? total,
  int? perReply,
  bool totalFromBot,
  bool perReplyFromBot,
});

typedef CapCheck = ({
  String state,
  String? reason,
  double spent,
  double high,
  bool pro,
  double? room,
  CapLimits limits,
});

typedef CapPrompt = ({String title, String body, bool sendOnce});

class SpendCaps {
  static const totalKey = 'capSats';
  static const perReplyKey = 'askAboveSats';
  static const spentKey = 'sats';

  static int? positive(Object? v) => v is num && v > 0 ? v.floor() : null;

  static int? stricter(int? a, int? b) {
    final x = positive(a);
    final y = positive(b);
    if (x == null) return y;
    if (y == null) return x;
    return x < y ? x : y;
  }

  static double rate(bool pro) =>
      (NymbotConfig.satsPerCredit[pro ? 'pro' : 'standard'] ?? 10).toDouble();

  static double satsFor(double credits, bool pro) => credits * rate(pro);

  static bool _isPro(ChatMessage m) => m.pro ?? (m.model != null);

  static CapLimits limits(Conversation conv, Bot? bot) {
    final total = stricter(conv.capSats, bot?.capSats);
    final perReply = stricter(conv.askAboveSats, bot?.askAboveSats);
    return (
      total: total,
      perReply: perReply,
      totalFromBot: total != null && positive(conv.capSats) != total,
      perReplyFromBot: perReply != null && positive(conv.askAboveSats) != perReply,
    );
  }

  static bool any(Conversation conv, Bot? bot) {
    final lim = limits(conv, bot);
    return lim.total != null || lim.perReply != null;
  }

  static double legacySpent(Conversation conv, List<ChatMessage> messages) {
    if (conv.creditsSpent <= 0) return 0;
    var sats = 0.0;
    var paid = 0.0;
    for (final m in messages) {
      if (m.role != ChatRole.bot || m.cost <= 0) continue;
      sats += satsFor(m.cost, _isPro(m));
      paid += m.cost;
    }
    final perCredit = paid > 0 ? sats / paid : rate(false);
    return conv.creditsSpent * perCredit;
  }

  static double spent(Conversation conv, List<ChatMessage> messages) =>
      conv.satsSpent ?? legacySpent(conv, messages);

  static double nextSpent(Conversation conv, List<ChatMessage> messages,
          double cost, bool pro) =>
      ((spent(conv, messages) + satsFor(cost, pro)) * 1000).round() / 1000;

  static double? room(
      Conversation conv, Bot? bot, List<ChatMessage> messages) {
    final lim = limits(conv, bot);
    if (lim.total == null) return null;
    final left = lim.total! - spent(conv, messages);
    return left < 0 ? 0 : left;
  }

  static CapCheck check(Conversation conv, Bot? bot,
      List<ChatMessage> messages, {required bool pro, required double high}) {
    final lim = limits(conv, bot);
    final used = spent(conv, messages);
    final highSats = satsFor(high, pro);
    final left = lim.total == null
        ? null
        : (lim.total! - used < 0 ? 0.0 : lim.total! - used);
    var state = 'ok';
    String? reason;
    if (lim.total != null && used >= lim.total!) {
      state = 'block';
      reason = 'total';
    } else if (lim.total != null && used + highSats > lim.total!) {
      state = 'ask';
      reason = 'total';
    } else if (lim.perReply != null && highSats > lim.perReply!) {
      state = 'ask';
      reason = 'reply';
    }
    return (
      state: state,
      reason: reason,
      spent: used,
      high: highSats,
      pro: pro,
      room: left,
      limits: lim,
    );
  }

  static double? maxCost(Conversation conv, Bot? bot,
      List<ChatMessage> messages, {required bool pro, int share = 1}) {
    final lim = limits(conv, bot);
    double? sats = lim.perReply?.toDouble();
    if (lim.total != null) {
      var left = lim.total! - spent(conv, messages);
      if (left < 0) left = 0;
      if (share > 1) left = left / share;
      sats = sats == null ? left : (left < sats ? left : sats);
    }
    if (sats == null) return null;
    final credits = (sats / rate(pro) * 1000).floor() / 1000;
    return credits < 0.001 ? 0.001 : credits;
  }

  static String _whole(num v) => figure(v.round());

  static String usedLine(
      Conversation conv, Bot? bot, List<ChatMessage> messages) {
    final lim = limits(conv, bot);
    if (lim.total == null) return '';
    return t('{n} of {m} sats used', {
      'n': _whole(spent(conv, messages)),
      'm': figure(lim.total!),
    });
  }

  static String roomLine(
      Conversation conv, Bot? bot, List<ChatMessage> messages) {
    final left = room(conv, bot, messages);
    if (left == null) return '';
    return left <= 0
        ? t('this chat is at its cap')
        : t('{n} sats left under this chat\'s cap', {'n': figure(left.floor())});
  }

  static CapPrompt prompt(CapCheck check, {required double credits}) {
    if (check.state == 'block') {
      return (
        title: t('This chat has reached its cap'),
        body: t('It has used {spent} of the {cap} sats you set for it. Raise the cap to keep going.', {
          'spent': _whole(check.spent),
          'cap': figure(check.limits.total ?? 0),
        }),
        sendOnce: false,
      );
    }
    final estimate = t('{sats} sats ({n} {tier} credits)', {
      'sats': figure(check.high.ceil()),
      'n': creditFigure(credits),
      'tier': check.pro ? t('Pro') : t('standard'),
    });
    return (
      title: t('Over this chat\'s cap?'),
      body: check.reason == 'total'
          ? t('This reply could cost up to {estimate}. The chat has used {spent} of its {cap} sat cap, so it could go past it.', {
              'estimate': estimate,
              'spent': _whole(check.spent),
              'cap': figure(check.limits.total ?? 0),
            })
          : t('This reply could cost up to {estimate}, more than the {cap} sats you asked to be warned above.', {
              'estimate': estimate,
              'cap': figure(check.limits.perReply ?? 0),
            }),
      sendOnce: true,
    );
  }

  static CapPrompt refusal(double required, bool pro, {bool team = false}) {
    final vars = {
      'sats': figure(satsFor(required, pro).ceil()),
      'n': creditFigure(required),
      'tier': pro ? t('Pro') : t('standard'),
    };
    return (
      title: t('Over this chat\'s cap?'),
      body: team
          ? t('Team mode holds up to {sats} sats ({n} {tier} credits) for this reply, more than the cap allows. Nothing was sent to a model and nothing was charged. Raise the cap, use fewer or cheaper workers, or send it once anyway.', vars)
          : t('Nymbot holds up to {sats} sats ({n} {tier} credits) for this reply, more than the cap allows. Nothing was charged.', vars),
      sendOnce: true,
    );
  }
}
