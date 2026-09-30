import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/workspace.dart';
import 'chat_engine.dart';

class MemoryProposal {
  const MemoryProposal({required this.text, required this.topic});

  final String text;
  final String topic;
}

/// Proposes memories and picks relevant ones to send; never saves on its own.
class MemoryKeeper {
  const MemoryKeeper._();

  /// Context budget for memory, in characters.
  static const sendCap = 1200;
  static const maxSent = 8;

  /// Deliberately narrow: only present-tense statements about the speaker.
  static final _rules = <(RegExp, String)>[
    (RegExp(r"\b(?:call me|my name(?:'s| is)|i(?:'m| am) called)\s+([^.,;!?\n]{2,60})",
        caseSensitive: false), 'Name'),
    (RegExp(r'\bi (?:work|am employed) (?:at|for)\s+([^.,;!?\n]{2,60})',
        caseSensitive: false), 'Work'),
    (RegExp(r"\bi(?:'m| am) an?\s+([^.,;!?\n]{2,60}?)\s+(?:by trade|by profession|developer|engineer|designer|writer)\b",
        caseSensitive: false), 'Work'),
    (RegExp(r'\bi (?:use|write|code) (?:in\s+)?([^.,;!?\n]{2,60}?)\s+(?:every day|at work|for everything|mostly)\b',
        caseSensitive: false), 'Tools'),
    (RegExp(r'\bi (?:prefer|always want|would rather have)\s+([^.,;!?\n]{2,80})',
        caseSensitive: false), 'Preference'),
    (RegExp(r'\b(?:please )?(?:always|never)\s+([^.,;!?\n]{4,80}?)\s+(?:when you (?:answer|reply)|in your (?:answers|replies))',
        caseSensitive: false), 'How to answer'),
    (RegExp(r'\bmy (?:timezone|time zone) is\s+([^.,;!?\n]{2,40})',
        caseSensitive: false), 'Timezone'),
    (RegExp(r"\bi(?:'m| am) (?:based|living|located) in\s+([^.,;!?\n]{2,60})",
        caseSensitive: false), 'Where'),
  ];

  static final _asking = RegExp(
      r'^\s*(?:what|who|when|where|why|how|which|can|could|would|should|does|do|did|is|are|was|were|will)\b',
      caseSensitive: false);

  static List<MemoryProposal> propose(String text, Conversation? conv) {
    final body = text.trim();
    if (body.isEmpty || body.length > 2000) return const [];
    if (conv != null && conv.ephemeral) return const [];
    final out = <MemoryProposal>[];
    for (final line in body.split(RegExp(r'[\n.!?]+'))) {
      final sentence = line.trim();
      if (sentence.isEmpty || _asking.hasMatch(sentence)) continue;
      for (final rule in _rules) {
        final hit = rule.$1.firstMatch(sentence);
        if (hit == null) continue;
        final kept =
            sentence.length > 200 ? hit.group(0)!.trim() : sentence;
        if (out.any((o) => o.text.toLowerCase() == kept.toLowerCase())) break;
        out.add(MemoryProposal(text: kept, topic: rule.$2));
        break;
      }
      if (out.length >= 2) break;
    }
    return out;
  }

  /// Global entries plus this workspace's; a ghost chat sees none.
  static List<Memory> forConv(List<Memory> all, Conversation? conv) {
    if (conv == null || conv.ephemeral) return const [];
    return all
        .where((m) => m.scope == null || m.scope == conv.workspaceId)
        .toList();
  }

  /// Relevant entries plus the always-on ones about who you are and how to answer.
  static String block(List<Memory> all, Conversation? conv, String query) {
    final mine = forConv(all, conv);
    if (mine.isEmpty) return '';
    final always = mine
        .where((m) => m.topic == 'How to answer' || m.topic == 'Name')
        .toList();
    final rest = mine.where((m) => !always.contains(m)).toList();
    // Ranked like workspace files; the chunk position maps a hit back to its entry.
    final ranked = ChatEngine.rankChunks(
      [
        for (var i = 0; i < rest.length; i++)
          KnowledgeChunk(
              file: 'memory',
              at: i,
              heading: rest[i].topic,
              text: rest[i].text)
      ],
      query,
    );
    final ordered = <Memory>[...always, for (final hit in ranked) rest[hit.at]];
    final picked = <Memory>[];
    var budget = sendCap;
    for (final entry in ordered) {
      if (picked.length >= maxSent || entry.text.length > budget) continue;
      budget -= entry.text.length;
      picked.add(entry);
    }
    if (picked.isEmpty) return '';
    final lines = picked
        .map((m) => '- ${m.topic.isEmpty ? '' : '${m.topic}: '}${m.text}')
        .join('\n');
    return '[remembered about you]\n$lines\n'
        'These were saved from earlier conversations. Treat them as true '
        'unless this conversation says otherwise, and never repeat them back '
        'as a list unless asked.';
  }
}
