import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import 'i18n/i18n.dart';

class AnonBadge extends StatelessWidget {
  const AnonBadge({super.key});

  @override
  Widget build(BuildContext context) =>
      _Pill(boxKey: const Key('anonBadge'), label: t('Anon'));
}

class SupportBadge extends StatelessWidget {
  const SupportBadge({super.key});

  @override
  Widget build(BuildContext context) =>
      _Pill(
          boxKey: const Key('supportBadge'),
          label: t('Support'),
          color: NymbotColors.lightning);
}

class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: t('{n} unread', {'n': count}),
      child: Container(
        key: const Key('supportUnread'),
        constraints: const BoxConstraints(minWidth: 16),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: NymbotColors.lightning,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          count > 99 ? '99+' : '$count',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: NymbotColors.bgDark,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.boxKey, required this.label, this.color});

  final Key boxKey;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.secondary;
    return Container(
      key: boxKey,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        strutStyle: const StrutStyle(
          fontSize: 10,
          height: 1.2,
          forceStrutHeight: true,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          leadingDistribution: TextLeadingDistribution.even,
          color: color,
        ),
      ),
    );
  }
}
