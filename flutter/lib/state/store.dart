import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';

/// Everything the app keeps on the device.
///
/// Secrets — the identity key, the post-quantum root, the anonymous-mode state
/// and the git access token — go to the platform keystore. Conversations and
/// preferences go to shared preferences: they are already encrypted to the key
/// on the relays, and keeping them out of the keystore keeps its surface to the
/// things that must not be readable at rest.
class Store {
  Store(this._prefs);

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final SharedPreferences _prefs;

  static Future<Store> open() async => Store(await SharedPreferences.getInstance());

  // --- secrets ---------------------------------------------------------------

  Future<String?> secret(String key) => _secure.read(key: key);
  Future<void> setSecret(String key, String value) =>
      _secure.write(key: key, value: value);
  Future<void> dropSecret(String key) => _secure.delete(key: key);

  // --- preferences -----------------------------------------------------------

  String? getString(String key) => _prefs.getString(key);
  Future<void> setString(String key, String value) => _prefs.setString(key, value);
  bool getBool(String key, {bool fallback = false}) =>
      _prefs.getBool(key) ?? fallback;
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
  Future<void> remove(String key) => _prefs.remove(key);

  // --- conversations ---------------------------------------------------------

  List<Conversation> conversations() =>
      Conversation.decodeList(_prefs.getString('conversations'));

  Future<void> saveConversations(List<Conversation> list) =>
      _prefs.setString('conversations', Conversation.encodeList(list.take(200).toList()));

  List<ChatMessage> messages(String convId) =>
      ChatMessage.decodeList(_prefs.getString('msgs_$convId'));

  Future<void> saveMessages(String convId, List<ChatMessage> list) {
    // Capped so one long conversation cannot fill the store and start failing
    // the writes it needs to make.
    final kept = list.length > 400 ? list.sublist(list.length - 400) : list;
    return _prefs.setString('msgs_$convId', ChatMessage.encodeList(kept));
  }

  /// The wrap ids this conversation is made of, newest last.
  List<String> thread(String convId) =>
      _prefs.getStringList('thread_$convId') ?? const [];

  Future<void> setThread(String convId, List<String> ids) {
    final kept = ids.length > 40 ? ids.sublist(ids.length - 40) : ids;
    return _prefs.setStringList('thread_$convId', kept);
  }

  Future<void> dropConversation(String convId) async {
    await _prefs.remove('msgs_$convId');
    await _prefs.remove('thread_$convId');
  }

  /// Everything, gone. Not a logout: there is nothing on a server to log out
  /// of, so this is the only kind of deletion there is.
  Future<void> wipe() async {
    await _prefs.clear();
    await _secure.deleteAll();
  }
}
