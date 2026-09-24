import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../services/doc_library.dart';
import '../services/sandbox_host.dart';
import '../services/sandbox_protocol.dart';
import '../services/server_runs.dart';
import 'i18n/i18n.dart';

class RunOutputs {
  RunOutputs._();

  static final ValueNotifier<String?> toComposer = ValueNotifier<String?>(null);

  static String composerText(SandboxResult r, {bool server = false}) {
    final body = SandboxProtocol.outputText(
      r,
      chartsLabel: t('Charts drawn: {n}', {'n': r.images.length}),
      filesLabel: t('Files written: {names}', {'names': r.files.map((f) => f.name).join(', ')}),
    );
    final lead = server
        ? t('Here is the output of that code, run on a Nymbot server:')
        : t('Here is the output of that code, run on my device:');
    return '$lead\n```text\n$body\n```';
  }
}

class RunCodeController extends ChangeNotifier {
  RunCodeController(this.language, {this.serverLanguage});

  final String? language;
  final String? serverLanguage;
  bool running = false;
  String? status;
  SandboxResult? result;
  bool onServer = false;
  int? exitCode;
  bool timedOut = false;
  double? charged;

  void _resetServer(bool server) {
    onServer = server;
    exitCode = null;
    timedOut = false;
    charged = null;
  }

  Future<ServerRunResponse> runOnServer(
    Future<ServerRunResponse> Function() start, {
    void Function(ServerRunState state)? onCharged,
  }) async {
    if (running) return const ServerRunResponse(status: 409, error: {'busy': true});
    running = true;
    result = null;
    _resetServer(true);
    status = t('Starting on a Nymbot server…');
    notifyListeners();
    final res = await start();
    final events = res.events;
    if (events == null) {
      running = false;
      status = null;
      onServer = false;
      notifyListeners();
      return res;
    }
    final state = ServerRunState();
    try {
      await for (final e in events) {
        state.take(e);
        if (e.type == 'start') status = t('Running on a Nymbot server…');
        result = state.result();
        exitCode = state.exitCode;
        timedOut = state.timedOut;
        notifyListeners();
      }
    } catch (_) {
      state.error ??= t('The connection to the server run was lost.');
    }
    if (!state.done && state.error == null && state.exitCode == null) {
      state.error = t('The connection to the server run was lost.');
    }
    running = false;
    status = null;
    result = state.result();
    exitCode = state.exitCode;
    timedOut = state.timedOut;
    charged = state.charged;
    notifyListeners();
    if (state.done) onCharged?.call(state);
    return res;
  }

  Future<void> run(String code, String? convId) async {
    final language = this.language;
    if (running || language == null) return;
    running = true;
    result = null;
    _resetServer(false);
    status = language == 'python' && !SandboxHost.instance.loadedOnce
        ? t('Loading Python on your device — about 14 MB the first time, plus any libraries the code imports. Nothing runs on a server.')
        : t('Starting…');
    notifyListeners();
    final got = await SandboxHost.instance.run(
      code,
      language,
      files: DocLibrary.instance.files(convId),
      convId: convId,
      onRunning: () {
        status = t('Running on your device…');
        notifyListeners();
      },
    );
    running = false;
    status = null;
    result = got;
    notifyListeners();
  }

  void clear() {
    result = null;
    _resetServer(false);
    notifyListeners();
  }
}

class RunButton extends StatelessWidget {
  const RunButton({super.key, required this.controller, required this.code});

  final RunCodeController controller;
  final String code;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => IconButton(
          icon: controller.running && !controller.onServer
              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.play_arrow_rounded, size: 17, color: Theme.of(context).colorScheme.primary),
          tooltip: t('Run this on your device'),
          onPressed: controller.running
              ? null
              : () => controller.run(code, AppScope.read(context).current?.id),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
        ),
      );
}

class RunOutputView extends StatelessWidget {
  const RunOutputView({super.key, required this.controller});

  final RunCodeController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final status = controller.status;
          final r = controller.result;
          if (status == null && r == null) return const SizedBox.shrink();
          final theme = Theme.of(context);
          final hint = TextStyle(fontSize: 11, color: theme.hintColor);
          const mono = TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 12);
          final danger = mono.copyWith(color: theme.colorScheme.error);
          if (r == null) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Text(status ?? '', style: hint),
            );
          }
          final server = controller.onServer;
          final String heading;
          if (server && controller.running) {
            heading = status ?? t('Running on a Nymbot server…');
          } else if (server) {
            heading = r.error != null
                ? t('Ran on a Nymbot server — failed')
                : t('Ran on a Nymbot server in {ms} ms', {'ms': r.ms});
          } else {
            heading = r.error != null
                ? t('Ran on your device — failed')
                : t('Ran on your device in {ms} ms', {'ms': r.ms});
          }
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: r.error != null ? theme.colorScheme.error : theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(heading, style: hint)),
                    if (!controller.running) ...[
                      TextButton(
                        onPressed: () =>
                            RunOutputs.toComposer.value = RunOutputs.composerText(r, server: server),
                        child: Text(t('Send output to Nymbot'), style: const TextStyle(fontSize: 12)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 15),
                        tooltip: t('Clear'),
                        onPressed: controller.clear,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
                if (r.stdout.isNotEmpty) SelectableText(r.stdout, style: mono),
                if (r.value != null) SelectableText(r.value!, style: mono),
                if (r.table != null) _table(context, r.table!),
                for (final src in r.images)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Image.memory(base64Decode(src.substring(src.indexOf(',') + 1)), gaplessPlayback: true),
                  ),
                if (r.files.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final f in r.files)
                        f.data == null
                            ? Text(t('{name} is too large to hand back.', {'name': f.name}), style: hint)
                            : ActionChip(
                                label: Text(t('Save {name}', {'name': f.name})),
                                onPressed: () => _save(f),
                              ),
                    ],
                  ),
                if (r.stderr.isNotEmpty) SelectableText(r.stderr, style: danger),
                if (r.error != null) SelectableText(r.error!, style: danger),
                if (r.truncated) Text(t('The output was cut short.'), style: hint),
                if (r.empty && !controller.running) Text(t('It ran, and printed nothing.'), style: hint),
                if (server && controller.exitCode != null)
                  Text(t('Exit code {code}', {'code': controller.exitCode}), style: hint),
                if (server && controller.timedOut)
                  Text(t('Stopped at the time limit.'), style: hint),
                const SizedBox(height: 4),
                if (server) ...[
                  Text(t('Ran on a Nymbot server'), style: hint),
                  if (controller.charged != null)
                    Text(t('Charged {credits} Pro credits', {'credits': ServerRuns.credits(controller.charged!)}),
                        style: hint),
                ] else
                  Text(t('Runs on your device in a sandbox with no access to your keys, your chats or the network.'),
                      style: hint),
              ],
            ),
          );
        },
      );

  Widget _table(BuildContext context, SandboxTable table) {
    const mono = TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 11.5);
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 28,
            dataRowMinHeight: 24,
            dataRowMaxHeight: 28,
            columnSpacing: 14,
            columns: [
              const DataColumn(label: Text('', style: mono)),
              for (final c in table.columns) DataColumn(label: Text(c, style: mono)),
            ],
            rows: [
              for (var i = 0; i < table.rows.length; i++)
                DataRow(cells: [
                  DataCell(Text(i < table.index.length ? table.index[i] : '$i', style: mono)),
                  for (var k = 0; k < table.columns.length; k++)
                    DataCell(Text(k < table.rows[i].length ? table.rows[i][k] : '', style: mono)),
                ]),
            ],
          ),
        ),
        if ((table.totalRows ?? 0) > table.rows.length)
          Text(t('Showing {rows} of {total} rows.', {'rows': table.rows.length, 'total': table.totalRows}),
              style: hint),
      ],
    );
  }

  Future<void> _save(SandboxFile f) async {
    final data = f.data;
    if (data == null) return;
    final safe = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File('${Directory.systemTemp.path}/$safe');
    await file.writeAsBytes(base64Decode(data));
    await Share.shareXFiles([XFile(file.path)]);
  }
}

class SandboxView extends StatelessWidget {
  const SandboxView({super.key});

  @override
  Widget build(BuildContext context) {
    if (!SandboxHost.supported) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: ListenableBuilder(
        listenable: SandboxHost.instance,
        builder: (context, _) {
          final c = SandboxHost.instance.controller;
          if (c == null) return const SizedBox.shrink();
          return IgnorePointer(
            child: ExcludeSemantics(
              child: Opacity(opacity: 0, child: WebViewWidget(controller: c)),
            ),
          );
        },
      ),
    );
  }
}
