import 'dart:convert';

import 'package:share_plus/share_plus.dart';

typedef ShareSink = Future<void> Function(
    String body, String name, String mime, String? subject);

class ShareFile {
  const ShareFile._();

  static ShareSink sink = _platform;

  static Future<void> _platform(
      String body, String name, String mime, String? subject) async {
    await Share.shareXFiles(
      [XFile.fromData(utf8.encode(body), mimeType: mime, name: name)],
      fileNameOverrides: [name],
      subject: subject,
    );
  }

  static Future<void> text(
    String body, {
    required String name,
    required String mime,
    String? subject,
  }) =>
      sink(body, name, mime, subject);
}
