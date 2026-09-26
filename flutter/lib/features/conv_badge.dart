import 'package:flutter/material.dart';

import 'i18n/i18n.dart';

class AnonBadge extends StatelessWidget {
  const AnonBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.secondary;
    return Container(
      key: const Key('anonBadge'),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        t('anon'),
        style: TextStyle(fontSize: 10, height: 1.4, color: color),
      ),
    );
  }
}
