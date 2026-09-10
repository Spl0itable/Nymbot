import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../models/artifact.dart';
import '../models/conversation.dart';
import '../models/workspace.dart';
import 'artifact_screen.dart';
import 'citation_cards.dart';
import 'sheets/cost_sheet.dart';
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
  remember,
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
    this.selfName,
    this.selfPicture = '',
    this.grouped = false,
    this.speaking = false,
    this.highlighted = false,
    this.artifacts = const [],
    this.onOpenArtifact,
    this.onUndoCheckpoint,
    this.actionsOpen = false,
    this.onToggleActions,
  });

  /// Puts back what a repo run changed. Absent when there is nothing to put
  /// back, which is what decides whether the card offers a way.
  final Future<void> Function()? onUndoCheckpoint;

  final ChatMessage message;
  final String selfPubkey;

  /// A published kind-0 name and picture, when the account has them and the
  /// chat is not anonymous.
  final String? selfName;
  final String selfPicture;
  final AppSettings settings;
  final void Function(MessageAction action, ChatMessage message) onAction;
  final bool grouped;
  final bool speaking;
  final bool highlighted;
  final List<Artifact> artifacts;
  final void Function(Artifact artifact)? onOpenArtifact;

  /// There is no hover on a phone, so the action row is revealed by tapping
  /// the bubble. Held by the list rather than the bubble so only one is ever
  /// open at a time.
  final bool actionsOpen;
  final VoidCallback? onToggleActions;

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
            : NymAvatar(
                seed: widget.selfPubkey,
                size: 30,
                picture: widget.selfPicture,
              ))
        : const SizedBox(width: 30, height: 0);

    final bubble = Flexible(
      child: Column(
        crossAxisAlignment:
            self && settings.bubbles ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!widget.grouped) _author(context, m, self),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onToggleActions,
            child: _content(context, m, self, theme),
          ),
          if (widget.actionsOpen) _actions(context, m),
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
    final published = widget.selfName;
    final name = bot
        ? 'Nymbot'
        : (published != null && published.isNotEmpty)
            ? published
            : NymIdentity.name(widget.selfPubkey);
    final suffix = bot ? 'nymbot' : widget.selfPubkey;
    final showSuffix = bot || published == null || published.isEmpty;
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
          if (showSuffix)
            Text(
              '#${bot ? _botSuffix : NymIdentity.suffix(widget.selfPubkey)}',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w300,
                color: (bot ? theme.colorScheme.primary : NymIdentity.colour(suffix))
                    .withValues(alpha: 0.7),
              ),
            ),
          // Which tier wrote this.
          if (bot) _tierBadge(theme, m),
          if (bot && m.model != null)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 5),
                child: Text(m.model!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
              ),
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

  /// PRO or STD, from what the worker said answered the message.
  Widget _tierBadge(ThemeData theme, ChatMessage m) {
    final isPro = m.pro ?? (m.model != null);
    final colour = isPro ? theme.colorScheme.secondary : theme.hintColor;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: isPro
            ? t('A frontier model you picked wrote this, charged to your Pro balance.')
            : t('Nymbot routed this to the model that suited it, charged to your standard balance.'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
          decoration: BoxDecoration(
            border: Border.all(color: colour.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            isPro ? t('PRO') : t('STD'),
            style: TextStyle(
              fontSize: 8,
              height: 1.4,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: colour,
            ),
          ),
        ),
      ),
    );
  }

  /// The price of a reply belongs on the bubble's footer, to the right of the
  /// time, rather than trailing the words it charged for.
  Widget _cost(BuildContext context, ChatMessage m) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => showCostSheet(context, m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(
                color: NymbotColors.lightning.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bolt, size: 11, color: NymbotColors.lightning),
              Text('${m.cost}',
                  style: const TextStyle(
                      fontSize: 10, color: NymbotColors.lightning)),
            ],
          ),
        ),
      );

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
            // Your own messages render the same way the replies do. Typing a
            // fenced block and watching it come out as literal backticks is
            // the wrong answer to "can I paste code in here".
            if (m.role == ChatRole.bot || m.role == ChatRole.self)
              MarkdownBody(
                m.content,
                monospace: settings.monospaceReplies,
                media: m.task,
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
            if (m.checkpoint != null) _checkpoint(context, m),
            for (final a in widget.artifacts)
              ArtifactCard(
                artifact: a,
                onOpen: () => widget.onOpenArtifact?.call(a),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (settings.timestamps)
                    Text(
                      _time(m.at),
                      style: TextStyle(fontSize: 10, color: theme.hintColor),
                    ),
                  if (m.cost > 0) ...[
                    const SizedBox(width: 6),
                    _cost(context, m),
                  ],
                ],
              ),
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

  Widget _sources(BuildContext context, ChatMessage m) =>
      CitationCards(sources: m.sources);

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
                const Icon(Icons.psychology_outlined, size: 12),
                const SizedBox(width: 3),
                Text(t('Reasoning'), style: const TextStyle(fontSize: 10.5)),
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

  /// What a repo run changed, and the way back. Turning writes on is a promise
  /// you can take back, so what it touched is stated rather than left in prose.
  Widget _checkpoint(BuildContext context, ChatMessage m) {
    final theme = Theme.of(context);
    final mark = m.checkpoint!;
    final paths = (mark['paths'] as List?)?.cast<String>() ?? const <String>[];
    final branches = (mark['branches'] as List?)?.cast<String>() ?? const <String>[];
    final pulls = (mark['pulls'] as List?)?.length ?? 0;
    final undone = mark['undone'] == true;
    final undoable = mark['undoable'] == true && paths.isNotEmpty;

    final bits = <String>[
      if (paths.length == 1)
        t('1 file changed')
      else if (paths.isNotEmpty)
        t('{n} files changed', {'n': paths.length}),
      for (final b in branches) t('branch {name}', {'name': b}),
      if (pulls == 1) t('1 pull request') else if (pulls > 1) t('{n} pull requests', {'n': pulls}),
    ];

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: undone ? theme.dividerColor : NymbotColors.lightning,
            width: 2,
          ),
          top: BorderSide(color: theme.dividerColor),
          right: BorderSide(color: theme.dividerColor),
          bottom: BorderSide(color: theme.dividerColor),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Opacity(
        opacity: undone ? 0.7 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_tree_outlined, size: 13),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    '${mark['repo']}${mark['branch'] == null ? '' : ' · ${mark['branch']}'}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: theme.hintColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(bits.join(' · '), style: const TextStyle(fontSize: 12.5)),
            if (paths.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(paths.join(', '),
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: theme.hintColor)),
            ],
            const SizedBox(height: 6),
            if (undone)
              Text(t('Put back.'),
                  style: TextStyle(fontSize: 11, color: theme.hintColor))
            else if (!undoable)
              // Say why rather than showing a button that cannot work.
              Text(
                t('This one cannot be undone from here — no commit was '
                    'recorded to read the old files back from.'),
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              )
            else ...[
              OutlinedButton(
                onPressed: widget.onUndoCheckpoint,
                child: Text(t('Undo these changes')),
              ),
              if (branches.isNotEmpty || pulls > 0) ...[
                const SizedBox(height: 4),
                Text(
                  t('Files only. A branch or pull request it opened is left '
                      'where it is.'),
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context, ChatMessage m) {
    final self = m.role == ChatRole.self;
    final bot = m.role == ChatRole.bot;
    final buttons = <Widget>[];

    // A long-press tooltip is no use when the row itself had to be tapped
    // open, so each action wears its label rather than hiding it.
    void add(IconData icon, String tip, MessageAction action, {bool on = false}) {
      final colour = on
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).hintColor;
      buttons.add(Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => widget.onAction(action, m),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: colour),
                const SizedBox(width: 3),
                Text(tip, style: TextStyle(fontSize: 10.5, color: colour)),
              ],
            ),
          ),
        ),
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
      add(Icons.edit_outlined, t('Ask this differently'), MessageAction.edit);
      add(Icons.send_outlined, t('Send again'), MessageAction.resend);
    }
    add(m.pinned ? Icons.star : Icons.star_border, t('Save this message'),
        MessageAction.pin,
        on: m.pinned);
    add(Icons.psychology_outlined, t('Remember this'), MessageAction.remember);
    add(Icons.close, t('Delete'), MessageAction.delete);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        alignment: self && widget.settings.bubbles
            ? WrapAlignment.end
            : WrapAlignment.start,
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
  const TypingIndicator({
    super.key,
    required this.label,
    this.showAvatar = true,
    this.steps = const [],
  });

  final String label;
  final bool showAvatar;

  /// What the worker has reported doing, newest last. Shown under the label
  /// rather than instead of it: the spinner is still the answer to "is it
  /// working", and these are the answer to "on what".
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = steps.length > 4 ? steps.sublist(steps.length - 4) : steps;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: theme.dividerColor.withValues(alpha: 0.9),
                // Every corner the same.
                borderRadius: BorderRadius.circular(16),
              ),
              // Centred: this is a status, not a message, and the lines under it
              // change length every couple of seconds — ragged against a left
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (showAvatar) ...[
                        const NymAvatar(seed: 'nymbot', size: 18, bot: true),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(label,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5, color: theme.hintColor)),
                      ),
                      const SizedBox(width: 8),
                      const _Dot(0),
                      const _Dot(150),
                      const _Dot(300),
                    ],
                  ),
                  for (final step in recent)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        step,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: theme.hintColor.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                ],
              ),
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
