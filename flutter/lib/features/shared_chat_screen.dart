import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/chat_share.dart';
import 'i18n/i18n.dart';
import 'markdown_body.dart';

Future<void> showSharedChat(BuildContext context, String link,
        {http.Client? client}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SharedChatScreen(link: link, client: client),
    ));

class SharedChatScreen extends StatefulWidget {
  const SharedChatScreen({super.key, required this.link, this.client});

  final String link;
  final http.Client? client;

  @override
  State<SharedChatScreen> createState() => _SharedChatScreenState();
}

class _SharedChatScreenState extends State<SharedChatScreen> {
  late final Future<Map<String, dynamic>> _load = _open();

  Future<Map<String, dynamic>> _open() async {
    final ShareRef ref;
    try {
      ref = ChatShare.parse(widget.link);
    } catch (_) {
      throw const _Problem('incomplete');
    }
    try {
      return await ChatShare.fetch(ref, client: widget.client);
    } on ShareFailure catch (e) {
      if (e.gone) throw const _Problem('gone');
      if (e.message.startsWith('HTTP')) throw const _Problem('offline');
      throw const _Problem('key');
    } on http.ClientException {
      throw const _Problem('offline');
    } on TimeoutException {
      throw const _Problem('offline');
    } catch (_) {
      throw const _Problem('key');
    }
  }

  (String, String) _explain(Object? error) => switch (
          error is _Problem ? error.kind : 'offline') {
        'incomplete' => (
            t('This link is incomplete'),
            t('The part after the # is missing or damaged. Ask whoever sent '
                'it for the whole link, copied in one piece.'),
          ),
        'gone' => (
            t('This chat is no longer shared'),
            t('Whoever shared it stopped sharing, or the host let it expire.'),
          ),
        'key' => (
            t('This link does not open this chat'),
            t('The key in the link does not match what is stored. Ask '
                'whoever sent it for the whole link.'),
          ),
        _ => (
            t('The shared chat could not be loaded'),
            t('Check your connection and try again.'),
          ),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t('Shared chat'))),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(child: Text(t('Opening the shared chat…')));
          }
          final data = snap.data;
          if (snap.hasError || data == null) {
            final (title, body) = _explain(snap.error);
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(body),
              ],
            );
          }
          final messages = (data['messages'] as List)
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList();
          final title = '${data['title'] ?? ''}'.trim();
          return SelectionArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(title.isEmpty ? t('Shared chat') : title,
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                for (final m in messages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m['role'] == 'user' ? t('User') : 'Nymbot',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: m['role'] == 'user'
                                  ? theme.hintColor
                                  : theme.colorScheme.primary),
                        ),
                        const SizedBox(height: 4),
                        MarkdownBody('${m['content']}'),
                      ],
                    ),
                  ),
                Text(
                  t('Read-only copy. It was encrypted on the sender’s device, '
                      'and the key never left this link.'),
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Problem implements Exception {
  const _Problem(this.kind);

  final String kind;
}
