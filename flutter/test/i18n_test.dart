import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/features/i18n/i18n.dart';

void main() {
  test('a string with no pack comes back as it went in', () {
    expect(t('Sign in'), 'Sign in');
    expect(t('{n} relays', {'n': 3}), '3 relays');
  });

  test('placeholders are filled, and only the ones passed', () {
    expect(t('{standard} standard · {pro} Pro', {'standard': 2, 'pro': 0}),
        '2 standard · 0 Pro');
    // A name the caller did not pass stays as it is: printing `null` into a
    // sentence is worse than printing the placeholder.
    expect(t('{a} and {b}', {'a': 'x'}), 'x and {b}');
  });

  test('a language with no pack in the bundle stays English', () async {
    await I18n.load(preferred: 'es');
    expect(I18n.lang, 'en');
    expect(t('Sign in'), 'Sign in');
    expect(I18n.isRtl, isFalse);
  });

  test('a language option shows its own name', () {
    expect(const LanguageOption(code: 'ja', name: 'Japanese', native: '日本語').label,
        '日本語');
    expect(const LanguageOption(code: 'ja', name: 'Japanese').label, 'Japanese');
  });
}
