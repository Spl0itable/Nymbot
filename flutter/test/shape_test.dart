import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/core/theme/theme.dart';

/// Material 3's default for a button is a stadium — a pill. Nymchat squares its
/// own controls off at 8, and a chat with Nymbot is the same chat in either
/// app, so these pin the shape rather than trusting the framework default.
void main() {
  double? cornerOf(OutlinedBorder? shape) {
    if (shape is StadiumBorder) return double.infinity;
    if (shape is RoundedRectangleBorder) {
      final radius = shape.borderRadius.resolve(TextDirection.ltr);
      return radius.topLeft.x;
    }
    return null;
  }

  for (final brightness in Brightness.values) {
    final theme = nymbotTheme(brightness);
    final name = brightness.name;

    test('$name: every button is squared off, not a pill', () {
      final styles = <String, ButtonStyle?>{
        'filled': theme.filledButtonTheme.style,
        'outlined': theme.outlinedButtonTheme.style,
        'text': theme.textButtonTheme.style,
        'elevated': theme.elevatedButtonTheme.style,
        'segmented': theme.segmentedButtonTheme.style,
      };
      for (final entry in styles.entries) {
        final shape = entry.value?.shape?.resolve(const {});
        expect(cornerOf(shape), NymbotColors.buttonRadius,
            reason: '${entry.key} button');
      }
    });

    test('$name: a chip matches the buttons beside it', () {
      expect(cornerOf(theme.chipTheme.shape), NymbotColors.buttonRadius);
    });
  }

  test('the tier switch nests concentrically', () {
    // 10 outside, 7 inside, at the switch's 2px padding: 7 + 2 ≈ 10 is what
    // makes the track follow the tab rather than bulge around it.
    expect(NymbotColors.switchRadius - NymbotColors.switchTabRadius, 3.0);
    expect(NymbotColors.switchRadius, greaterThan(NymbotColors.buttonRadius));
  });

  testWidgets('a rendered FilledButton is not a stadium', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: nymbotTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: FilledButton(onPressed: () {}, child: const Text('Sign in')),
        ),
      ),
    ));
    final material = tester.widget<Material>(find.descendant(
      of: find.byType(FilledButton),
      matching: find.byType(Material),
    ));
    expect(cornerOf(material.shape as OutlinedBorder?), NymbotColors.buttonRadius);
  });
}
