import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nymbot/state/app_controller.dart';

/// A pinned generator owns the model chip, so picking a chat model has to take
/// it back. Left pinned, the chip names a generator the next message will not
/// use, and only a round trip through Standard cleared it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
  });

  Map<String, dynamic> generator() => {
        'key': 'grok-video',
        'label': 'Grok Imagine Video',
        'kind': 'video',
        'credits': 30,
        'command': '?video --model grok-video',
        'proKey': 'opus',
      };

  Map<String, dynamic> chatModel() =>
      {'key': 'opus', 'label': 'Claude Opus 5', 'credits': 4, 'max': 40};

  // What the toolbar chip reads: the generator when one is pinned, the chat
  // model otherwise.
  String chip(AppController app) {
    final shown = app.activeMediaModel ?? app.activeModel;
    return shown == null ? 'Auto-routed' : shown['label'] as String;
  }

  test('picking a chat model unpins the generator', () async {
    final app = await AppController.boot();
    await app.setMediaModel(generator());
    expect(chip(app), 'Grok Imagine Video');

    await app.setProModel(chatModel());
    expect(chip(app), 'Claude Opus 5');
    expect(app.activeMediaModel, isNull);
    expect(app.proTier, isTrue);
  });

  test('going back to auto-routing unpins it too', () async {
    final app = await AppController.boot();
    await app.setMediaModel(generator());
    await app.setProModel(null);
    expect(chip(app), 'Auto-routed');
    expect(app.activeMediaModel, isNull);
    expect(app.proTier, isFalse);
  });

  test('a generator pinned to one chat is replaced there as well', () async {
    final app = await AppController.boot();
    await app.newConversation();
    await app.setMediaModel(generator(), forChat: true);
    expect(chip(app), 'Grok Imagine Video');

    await app.setProModel(chatModel(), forChat: true);
    expect(chip(app), 'Claude Opus 5');
    expect(app.activeMediaModel, isNull);
  });

  test('a generator pinned everywhere does not outlive a per-chat pick',
      () async {
    final app = await AppController.boot();
    await app.setMediaModel(generator());
    await app.newConversation();

    await app.setProModel(chatModel(), forChat: true);
    expect(app.activeMediaModel, isNull);
    expect(chip(app), 'Claude Opus 5');
  });

  test('switching to Standard still drops a Pro generator', () async {
    final app = await AppController.boot();
    await app.setMediaModel(generator());
    await app.dropProMedia();
    expect(app.activeMediaModel, isNull);
  });
}
