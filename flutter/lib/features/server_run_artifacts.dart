import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'i18n/i18n.dart';
import 'markdown_body.dart';

class ServerRunArtifacts extends StatelessWidget {
  const ServerRunArtifacts({super.key, required this.artifacts, this.truncated = false});

  final List<Map<String, dynamic>> artifacts;
  final bool truncated;

  static const _images = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};

  @override
  Widget build(BuildContext context) {
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    final shots = <Widget>[];
    final saves = <Widget>[];
    for (final a in artifacts) {
      final name = '${a['name'] ?? ''}';
      final type = '${a['type'] ?? ''}';
      final url = a['url'] is String ? a['url'] as String : null;
      final data = a['data'] is String ? a['data'] as String : null;
      if (name.isEmpty || (url == null && data == null)) continue;
      if (_images.contains(type)) {
        shots.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (url != null)
                MediaBlock(url: url, image: true)
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 384),
                  child: Image.memory(base64Decode(data!),
                      key: ValueKey('artifact-image-$name'), gaplessPlayback: true, fit: BoxFit.contain),
                ),
              Text(name, style: hint),
            ],
          ),
        ));
      } else {
        saves.add(ActionChip(
          label: Text(t('Save {name}', {'name': name})),
          onPressed: () => url != null ? _open(url) : _save(name, data!),
        ));
      }
    }
    if (shots.isEmpty && saves.isEmpty && !truncated) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('server-run-artifacts'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...shots,
        if (saves.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: saves),
          ),
        if (truncated)
          Text(t('Some screenshots or reports were left out: there were too many, or they were too large.'),
              style: hint),
      ],
    );
  }

  static Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  static Future<void> _save(String name, String data) async {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File('${Directory.systemTemp.path}/$safe');
    await file.writeAsBytes(base64Decode(data));
    await Share.shareXFiles([XFile(file.path)]);
  }
}

List<Widget> serverRunSurchargeLines(BuildContext context, double perMinute, {double size = 12}) {
  final theme = Theme.of(context);
  return [
    Text(t('Includes a browser surcharge'),
        key: const ValueKey('server-run-surcharge'),
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, color: theme.colorScheme.primary)),
    Text(t('{credits} Pro credits a minute', {'credits': decimalFigure(perMinute, 3)}),
        style: TextStyle(fontSize: size, color: theme.hintColor)),
  ];
}
