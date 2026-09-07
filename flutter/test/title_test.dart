import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/services/chat_engine.dart';

void main() {
  group('titleFor', () {
    test('names a chat after its first message', () {
      expect(ChatEngine.titleFor('why does the voucher retry give up early?'),
          'Why does the voucher retry give up early?');
    });

    test('drops a leading command when something follows it', () {
      expect(ChatEngine.titleFor('?ask what is ML-KEM'), 'What is ML-KEM');
    });

    test('keeps the command when nothing follows it', () {
      expect(ChatEngine.titleFor('?balance'), 'Balance');
    });

    test('drops the no-history marker', () {
      expect(ChatEngine.titleFor('! one-off question'), 'One-off question');
    });

    test('truncates on a word boundary', () {
      final title = ChatEngine.titleFor(
          'Explain the difference between a Chaumian blind signature and a '
          'plain blind signature in detail');
      expect(title.length, lessThanOrEqualTo(49));
      expect(title.endsWith('…'), isTrue);
      expect(title.contains('  '), isFalse);
    });

    test('strips code fences and links', () {
      expect(ChatEngine.titleFor('see https://example.com for context'),
          'See for context');
    });

    test('falls back when there is nothing to name it after', () {
      expect(ChatEngine.titleFor('   '), 'New chat');
    });
  });

  group('splitThinking', () {
    test('lifts a reasoning block off the front of a reply', () {
      final split = ChatEngine.splitThinking('<think>weighing it up</think>The answer.');
      expect(split.thinking, 'weighing it up');
      expect(split.body, 'The answer.');
    });

    test('leaves an ordinary reply alone', () {
      final split = ChatEngine.splitThinking('The answer.');
      expect(split.thinking, isNull);
      expect(split.body, 'The answer.');
    });
  });
}
