import '../models/conversation.dart';
import '../models/workspace.dart';

class Transcript {
  const Transcript._();

  static String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String markdown(
    Conversation conv,
    List<ChatMessage> messages, {
    List<GitRepo> repos = const [],
  }) {
    final out = <String>[];
    out.add('# ${conv.title.isEmpty ? 'New chat' : conv.title}');
    out.add('');
    out.add('_${_stamp(conv.createdAt)} — ${_stamp(conv.updatedAt)}_');
    if (conv.anon) {
      out.add('');
      out.add('> This conversation ran on a throwaway key.');
    }
    if (conv.systemPrompt.isNotEmpty) {
      out.add('');
      out.add('## Custom instructions');
      out.add('');
      out.add(conv.systemPrompt);
    }
    if (repos.isNotEmpty) {
      out.add('');
      out.add('## Repositories');
      out.add('');
      for (final r in repos) {
        out.add('- `${r.repo}`'
            '${r.branch.isEmpty ? '' : ' (${r.branch})'} — ${r.provider}'
            '${r.allowWrites ? ', writes on' : ''}');
      }
    }
    out.add('');
    out.add('---');
    for (final m in messages) {
      out.add('');
      final who = switch (m.role) {
        ChatRole.self => 'You',
        ChatRole.bot => 'Nymbot',
        ChatRole.error => 'Error',
        ChatRole.note => 'Note',
      };
      final meta = <String>[];
      if (m.model != null) meta.add(m.model!);
      if (m.cost > 0) meta.add('${m.cost} credits');
      meta.add(_stamp(m.at));
      out.add('### $who — ${meta.join(' · ')}');
      out.add('');
      final thinking = m.thinking;
      if (thinking != null && thinking.isNotEmpty) {
        out.add('<details><summary>Reasoning</summary>');
        out.add('');
        out.add(thinking);
        out.add('');
        out.add('</details>');
        out.add('');
      }
      out.add(m.content);
      for (final a in m.attachments) {
        out.add('');
        out.add('**Attached:** `${a.name}`');
      }
    }
    out.add('');
    return out.join('\n');
  }

  static String plain(Conversation conv, List<ChatMessage> messages) {
    final out = <String>[conv.title.isEmpty ? 'New chat' : conv.title, ''];
    for (final m in messages) {
      final who = switch (m.role) {
        ChatRole.self => 'you',
        ChatRole.bot => 'Nymbot',
        ChatRole.error => 'error',
        ChatRole.note => 'note',
      };
      out.add('[$who] ${m.content}');
      out.add('');
    }
    return out.join('\n');
  }
}
