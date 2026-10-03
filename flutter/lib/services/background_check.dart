import 'package:flutter/services.dart';

import '../features/i18n/i18n.dart';
import '../state/identity.dart';
import '../state/store.dart';
import 'done_since.dart';
import 'nymbot_api.dart';
import 'reply_notify.dart';

class BackgroundCheck {
  BackgroundCheck._();

  static const channel = MethodChannel('ai.nymbot/check');

  static Future<int> run() async {
    try {
      final store = await Store.open();
      if (store.vault.locked) return 0;
      final settings = store.settings();
      if (!settings.replyNotify ||
          !DoneSince.wanted(
              backgroundJobs: settings.backgroundJobs,
              serverSchedules: settings.serverSchedules)) {
        return 0;
      }
      final identity = Identity(store);
      if (!await identity.restore() || !identity.hasNsec) return 0;
      await I18n.load(preferred: store.getString('lang'));
      final notify = ReplyNotifyChannel();
      final pushed = await notify.pushed();
      final found = await DoneSince.check(
        api: NymbotApi(),
        signer: identity.signer,
        store: store,
        pushed: pushed,
        prefs: settings.notify,
        post: (n) => notify.reply(
          chat: n.chat,
          title: n.title,
          body: n.body,
          channelName: t('Replies'),
          asked: n.asked,
        ),
      );
      return found.length;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> done() async {
    try {
      await channel.invokeMethod<Object?>('done');
    } catch (_) {}
  }
}
