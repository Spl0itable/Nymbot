/// One model's answer in a side-by-side comparison. Nothing here has touched
/// the conversation yet: a run is only folded in when you keep it.
class CompareRun {
  const CompareRun({
    required this.model,
    this.reply = '',
    this.thinking,
    this.cost = 0,
    this.sources = const [],
    this.error,
  });

  final Map<String, dynamic> model;
  final String reply;
  final String? thinking;
  final int cost;
  final List<Map<String, dynamic>> sources;
  final String? error;

  bool get ok => error == null;
  String get label => model['label'] as String? ?? model['key'] as String? ?? '';
  int get price => (model['credits'] as num?)?.toInt() ?? 1;
}
