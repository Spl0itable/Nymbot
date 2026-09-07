import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../models/workspace.dart';
import 'i18n/i18n.dart';
import 'markdown_body.dart';
import 'nym_avatar.dart';

enum MessageAction {
  copy,
  speak,
  regenerate,
  resend,
  edit,
  quote,
  fork,
  rateUp,
  rateDown,
  pin,
  retry,
  delete,
}

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.selfPubkey,
    required this.settings,
    required this.onAction,
    this.grouped = false,
    this.speaking = false,
    this.highlighted = false,
  });

  final ChatMessage message;
  final String selfPubkey;
  final AppSettings settings;
  final void Function(MessageAction action, ChatMessage message) onAction;
  final bool grouped;
  final bool speaking;
  final bool highlighted;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool? _reasoningOpen;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final theme = Theme.of(context);
    final self = m.role == ChatRole.self;
    final system = m.role == ChatRole.note || m.role == ChatRole.error;
    final settings = widget.settings;

    final gap = switch (settings.density) {
      ChatDensity.compact => 3.0,
      ChatDensity.roomy => 12.0,
      ChatDensity.comfortable => 6.0,
    };

    if (system) {
      return Padding(
        padding: EdgeInsets.only(bottom: gap, top: 2),
        child: _systemCard(context, m),
      );
    }

    final avatar = settings.avatars && !widget.grouped
        ? (m.role == ChatRole.bot
            ? const NymAvatar(seed: 'nymbot', size: 30, bot: true)
            : NymAvatar(seed: widget.selfPubkey, size: 30))
        : const SizedBox(width: 30, height: 0);

    final bubble = Flexible(
      child: Column(
        crossAxisAlignment:
            self && settings.bubbles ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!widget.grouped) _author(context, m, self),
          _content(context, m, self, theme),
          _actions(context, m),
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: Row(
        textDirection: self && settings.bubbles ? TextDirection.rtl : TextDirection.ltr,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (settings.avatars && !(self && settings.bubbles))
            Padding(
              padding: const EdgeInsets.only(right: 7),
              child: avatar,
            ),
          bubble,
        ],
      ),
    );
  }

  Widget _author(BuildContext context, ChatMessage m, bool self) {
    final theme = Theme.of(context);
    final bot = m.role == ChatRole.bot;
    final name = bot ? 'nymbot' : NymIdentity.name(widget.selfPubkey);
    final suffix = bot ? 'nymbot' : widget.selfPubkey;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: bot ? theme.colorScheme.primary : NymIdentity.colour(suffix),
            ),
          ),
          Text(
            '#${bot ? _botSuffix : NymIdentity.suffix(widget.selfPubkey)}',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w300,
              color: (bot ? theme.colorScheme.primary : NymIdentity.colour(suffix))
                  .withValues(alpha: 0.7),
            ),
          ),
          if (bot)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Icon(Icons.verified,
                  size: 11, color: theme.colorScheme.secondary),
            ),
          if (bot && m.model != null)
            Padding(
              padding: const EdgeInsets.only(left: 5),
              child: Text(m.model!,
                  style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
            ),
          if (m.edited)
            Padding(
              padding: const EdgeInsets.only(left: 5),
              child: Text(t('edited'),
                  style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
            ),
        ],
      ),
    );
  }

  static const _botSuffix = '4bb2';

  Widget _content(BuildContext context, ChatMessage m, bool self, ThemeData theme) {
    final settings = widget.settings;
    final bubbles = settings.bubbles;
    final background = self
        ? theme.colorScheme.primary.withValues(alpha: 0.10)
        : theme.dividerColor.withValues(alpha: 0.9);

    final radius = bubbles
        ? BorderRadius.only(
            topLeft: Radius.circular(self || widget.grouped ? 16 : 4),
            topRight: Radius.circular(self && !widget.grouped ? 4 : 16),
            bottomLeft: const Radius.circular(16),
            bottomRight: const Radius.circular(16),
          )
        : BorderRadius.circular(12);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: bubbles ? MediaQuery.of(context).size.width * 0.82 : double.infinity,
      ),
      child: Container(
        width: bubbles ? null : double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: radius,
          border: widget.highlighted
              ? Border.all(color: NymbotColors.lightning, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.attachments.isNotEmpty) _attachments(context, m),
            if (m.repos.isNotEmpty)
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final r in m.repos) _chip(context, r, NymbotColors.lightning),
                ],
              ),
            if (m.quote != null && m.quote!.isNotEmpty) _quoted(context, m.quote!),
            if (m.thinking != null) _reasoning(context, m),
            if (m.role == ChatRole.bot)
              MarkdownBody(
                m.content,
                monospace: settings.monospaceReplies,
              )
            else
              SelectableText(
                m.content,
                style: TextStyle(
                  fontSize: 14.5,
                  fontFamily: settings.monospaceReplies ? 'monospace' : null,
                ),
              ),
            if (m.sources.isNotEmpty) _sources(context, m),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (m.cost > 0)
                  Container(
                    margin: const EdgeInsets.only(right: 6, top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: NymbotColors.lightning.withValues(alpha: 0.4)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('⚡ ${m.cost}',
                        style: const TextStyle(
                            fontSize: 10, color: NymbotColors.lightning)),
                  ),
                if (settings.timestamps)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _time(m.at),
                      style: TextStyle(fontSize: 10, color: theme.hintColor),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, Color colour) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        margin: const EdgeInsets.only(bottom: 5),
        decoration: BoxDecoration(
          border: Border.all(color: colour.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: TextStyle(fontSize: 10, color: colour)),
      );

  Widget _attachments(BuildContext context, ChatMessage m) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final a in m.attachments)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      a.kind == AttachmentKind.image
                          ? Icons.image_outlined
                          : Icons.description_outlined,
                      size: 13,
                    ),
                    const SizedBox(width: 4),
                    Text('${a.name} · ${a.humanSize}',
                        style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _quoted(BuildContext context, String quote) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.only(left: 8),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Theme.of(context).colorScheme.secondary, width: 2),
          ),
        ),
        child: Text(
          quote,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      );

  Widget _sources(BuildContext context, ChatMessage m) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (final s in m.sources.take(8))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${s['title'] ?? s['url'] ?? 'source'}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
          ],
        ),
      );

  Widget _reasoning(BuildContext context, ChatMessage m) {
    final open = _reasoningOpen ?? widget.settings.showReasoningByDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => setState(() => _reasoningOpen = !open),
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('💭 ${t('Reasoning')}', style: const TextStyle(fontSize: 10.5)),
                Icon(open ? Icons.expand_less : Icons.expand_more, size: 13),
              ],
            ),
          ),
        ),
        if (open)
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: Theme.of(context).dividerColor, width: 2),
              ),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                m.thinking!,
                style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
              ),
            ),
          ),
      ],
    );
  }

  Widget _systemCard(BuildContext context, ChatMessage m) {
    final theme = Theme.of(context);
    final error = m.role == ChatRole.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: error ? NymbotColors.danger : theme.dividerColor,
          style: error ? BorderStyle.solid : BorderStyle.solid,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            m.content,
            style: TextStyle(
              fontSize: 13,
              color: error ? NymbotColors.danger : theme.hintColor,
            ),
          ),
          if (error && m.retry != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => widget.onAction(MessageAction.retry, m),
                child: Text(t('Try again')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, ChatMessage m) {
    final self = m.role == ChatRole.self;
    final bot = m.role == ChatRole.bot;
    final buttons = <Widget>[];

    void add(IconData icon, String tip, MessageAction action, {bool on = false}) {
      buttons.add(IconButton(
        icon: Icon(icon, size: 15),
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 26),
        color: on ? Theme.of(context).colorScheme.primary : Theme.of(context).hintColor,
        onPressed: () => widget.onAction(action, m),
      ));
    }

    add(Icons.copy_all_outlined, t('Copy'), MessageAction.copy);
    if (bot) {
      add(Icons.refresh, t('Ask again'), MessageAction.regenerate);
      add(widget.speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
          t('Read aloud'), MessageAction.speak, on: widget.speaking);
      add(Icons.call_split, t('Branch from here'), MessageAction.fork);
      add(Icons.format_quote, t('Quote'), MessageAction.quote);
      add(Icons.thumb_up_outlined, t('Good reply'), MessageAction.rateUp,
          on: m.rating == 1);
      add(Icons.thumb_down_outlined, t('Poor reply'), MessageAction.rateDown,
          on: m.rating == -1);
    }
    if (self) {
      add(Icons.edit_outlined, t('Edit and resend'), MessageAction.edit);
      add(Icons.send_outlined, t('Send again'), MessageAction.resend);
    }
    add(m.pinned ? Icons.star : Icons.star_border, t('Save this message'),
        MessageAction.pin,
        on: m.pinned);
    add(Icons.close, t('Delete'), MessageAction.delete);

    return SizedBox(
      height: 26,
      child: ListView(
        scrollDirection: Axis.horizontal,
        reverse: self && widget.settings.bubbles,
        shrinkWrap: true,
        children: buttons,
      ),
    );
  }

  String _time(DateTime at) {
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final mm = at.minute.toString().padLeft(2, '0');
    return '$h:$mm ${at.hour < 12 ? 'AM' : 'PM'}';
  }
}

class TypingIndicator extends StatelessWidget {
  const TypingIndicator({super.key, required this.label, this.showAvatar = true});

  final String label;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          if (showAvatar) ...[
            const NymAvatar(seed: 'nymbot', size: 30, bot: true),
            const SizedBox(width: 7),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: theme.dividerColor.withValues(alpha: 0.9),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: 12.5, color: theme.hintColor)),
                const SizedBox(width: 8),
                const _Dot(0),
                const _Dot(150),
                const _Dot(300),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot(this.delayMs);

  final int delayMs;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _c.repeat();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final v = _c.value;
        final lift = v < 0.3 ? (v / 0.3) * 5 : v < 0.6 ? (1 - (v - 0.3) / 0.3) * 5 : 0.0;
        return Padding(
          padding: EdgeInsets.only(right: 3, bottom: lift),
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).hintColor,
            ),
          ),
        );
      },
    );
  }
}
