import 'package:flutter/material.dart';

import '../app.dart';
import '../services/doc_library.dart';
import '../services/sandbox_protocol.dart';
import '../services/server_runs.dart';
import 'i18n/i18n.dart';
import 'run_output.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/sheet.dart';
import 'nym_glyph.dart';

typedef ServerRunChoice = ({int timeoutSec, bool withFiles, double maxCost});

typedef ServerRunPrice = ({int timeoutSec, double credits});

Future<ServerRunChoice?> showServerRunSheet(
  BuildContext context, {
  required RunnerImage image,
  int fileCount = 0,
  int? timeoutSec,
  bool withFiles = false,
  ServerRunPrice? changed,
}) =>
    showNymSheet<ServerRunChoice>(
      context,
      (_) => ServerRunSheet(
        image: image,
        fileCount: fileCount,
        timeoutSec: timeoutSec,
        withFiles: withFiles,
        changed: changed,
      ),
    );

class ServerRunSheet extends StatefulWidget {
  const ServerRunSheet({
    super.key,
    required this.image,
    this.fileCount = 0,
    this.timeoutSec,
    this.withFiles = false,
    this.changed,
  });

  final RunnerImage image;
  final int fileCount;
  final int? timeoutSec;
  final bool withFiles;
  final ServerRunPrice? changed;

  @override
  State<ServerRunSheet> createState() => _ServerRunSheetState();
}

class _ServerRunSheetState extends State<ServerRunSheet> {
  late int _timeout = ServerRuns.clampTimeout(widget.timeoutSec ?? 60, widget.image);
  late bool _files = widget.withFiles && widget.fileCount > 0;

  double get _price {
    final base = ServerRuns.maxCredits(widget.image, _timeout);
    final changed = widget.changed;
    if (changed != null && changed.timeoutSec == _timeout && changed.credits > base) {
      return changed.credits;
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    final changed = widget.changed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Run on a Nymbot server'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              t('The code runs in a fresh container on a Nymbot server, paid from your Pro balance for the time it takes. Only the code, and any files you choose to add, leave this device.'),
              style: hint,
            ),
            const SizedBox(height: 12),
            Text(t('Image: {image}', {'image': widget.image.label}),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            Text(t('Time limit'), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                for (final sec in ServerRuns.timeoutsFor(widget.image))
                  ChoiceChip(
                    key: ValueKey('timeout-$sec'),
                    label: Text(ServerRuns.minutes(sec)),
                    selected: _timeout == sec,
                    onSelected: (_) => setState(() => _timeout = sec),
                  ),
              ],
            ),
            if (widget.fileCount > 0)
              SwitchListTile(
                key: const ValueKey('server-run-files'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _files,
                onChanged: (on) => setState(() => _files = on),
                title: Text(t('Include this chat\'s attached files'),
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                    widget.fileCount == 1
                        ? t('1 file')
                        : t('{n} files', {'n': widget.fileCount}),
                    style: hint),
              ),
            if (changed != null && changed.timeoutSec == _timeout) ...[
              const SizedBox(height: 8),
              Text(
                t('The price has changed to {credits} Pro credits. Run it at that price?',
                    {'credits': ServerRuns.credits(_price)}),
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              t('Up to {credits} Pro credits', {'credits': ServerRuns.credits(_price)}),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            Text(t('You pay for the time it actually runs, never more than this.'), style: hint),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t('Cancel')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('server-run-go'),
                  onPressed: () => Navigator.pop<ServerRunChoice>(
                      context, (timeoutSec: _timeout, withFiles: _files, maxCost: _price)),
                  child: Text(t('Run')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ServerRunButton extends StatelessWidget {
  const ServerRunButton({super.key, required this.controller, required this.code});

  final RunCodeController controller;
  final String code;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => IconButton(
          key: const ValueKey('server-run'),
          icon: controller.running && controller.onServer
              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
              : NymGlyph('server-runs', size: 16, color: Theme.of(context).colorScheme.primary),
          tooltip: t('Run on a Nymbot server'),
          onPressed: controller.running ? null : () => runCodeOnServer(context, controller, code),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
        ),
      );
}

String serverRunProblem(int status, Map<String, dynamic> error) {
  final said = error['error'] is String && (error['error'] as String).isNotEmpty
      ? error['error'] as String
      : null;
  return switch (status) {
    409 => said ?? t('Another server run of yours is still going. Wait for it to finish, then try again.'),
    429 => said ?? t('Slow down — too many requests. Try again in a minute.'),
    503 => t('Server runs are not available right now.'),
    _ => said ?? t('The server run could not start.'),
  };
}

Future<void> runCodeOnServer(
    BuildContext context, RunCodeController controller, String code) async {
  final language = controller.serverLanguage;
  if (language == null) return;
  final app = AppScope.read(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text, {bool buy = false}) => messenger?.showSnackBar(SnackBar(
        content: Text(text),
        action: buy && context.mounted
            ? SnackBarAction(label: t('Buy'), onPressed: () => showCreditsSheet(context))
            : null,
      ));
  final info = await app.refreshRunner();
  final image = info.image(ServerRuns.imageFor(language));
  if (!info.available || image == null) {
    say(t('Server runs are not available right now.'));
    return;
  }
  final conv = app.current;
  final files =
      conv == null || conv.anon ? const <SandboxFile>[] : DocLibrary.instance.files(conv.id);
  int? timeout;
  var withFiles = false;
  ServerRunPrice? changed;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (!context.mounted) return;
    final choice = await showServerRunSheet(context,
        image: image,
        fileCount: files.length,
        timeoutSec: timeout,
        withFiles: withFiles,
        changed: changed);
    if (choice == null) return;
    timeout = choice.timeoutSec;
    withFiles = choice.withFiles;
    if (!await app.serverRunCapGate(conv, choice.maxCost)) return;
    final res = await controller.runOnServer(
      () => app.startServerRun(conv, {
        'image': image.name,
        'code': code,
        'language': language,
        'timeoutSec': choice.timeoutSec,
        'maxCost': choice.maxCost,
        if (choice.withFiles && files.isNotEmpty) 'files': ServerRuns.filesPayload(files),
      }),
      onCharged: (state) => app.serverRunCharged(conv, state),
    );
    if (res.events != null) return;
    final error = res.error;
    if (res.status == 402 && error['error'] == 'price-changed' && error['maxCredits'] is num) {
      changed = (timeoutSec: choice.timeoutSec, credits: (error['maxCredits'] as num).toDouble());
      continue;
    }
    if (res.status == 402 && error['noCredits'] == true) {
      say(await app.serverRunNoCredits(conv, error), buy: true);
      return;
    }
    if (res.status == 503 && error['available'] == false) await app.refreshRunner();
    say(serverRunProblem(res.status, error));
    return;
  }
}
