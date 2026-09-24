import 'dart:convert';

class PendingInvoice {
  PendingInvoice({
    required this.id,
    required this.pr,
    required this.tier,
    required this.anon,
    required this.credits,
    required this.sats,
    DateTime? createdAt,
    this.paid = false,
  }) : createdAt = createdAt ?? DateTime.now();

  static const kept = Duration(hours: 24);

  final String id;
  final String pr;
  final String tier;
  final bool anon;
  final int credits;
  final int sats;
  final DateTime createdAt;
  bool paid;

  bool get stale => !paid && DateTime.now().difference(createdAt) > kept;

  Map<String, dynamic> toJson() => {
        'invoiceId': id,
        'pr': pr,
        'tier': tier,
        'anon': anon,
        'credits': credits,
        'sats': sats,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'paid': paid,
      };

  String encode() => jsonEncode(toJson());

  static PendingInvoice? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final id = j['invoiceId'];
      final pr = j['pr'];
      if (id is! String || id.isEmpty || pr is! String) return null;
      return PendingInvoice(
        id: id,
        pr: pr,
        tier: j['tier'] == 'pro' ? 'pro' : 'standard',
        anon: j['anon'] == true,
        credits: (j['credits'] as num?)?.toInt() ?? 0,
        sats: (j['sats'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
        paid: j['paid'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
