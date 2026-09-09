import 'package:flutter/material.dart';

/// A vendor tile for the model picker: the initials on the house colour.
/// Deliberately a monogram rather than a traced trademark — it scans at 22px,
/// needs no network asset, and is nobody's logo but ours.
class BrandTile extends StatelessWidget {
  const BrandTile({super.key, required this.slug, this.size = 22});

  final String slug;
  final double size;

  static const Map<String, (String, int)> _brands = {
    'anthropic': ('A', 0xFFD97757),
    'openai': ('AI', 0xFF10A37F),
    'google': ('G', 0xFF4285F4),
    'xai': ('X', 0xFF111827),
    'moonshotai': ('K', 0xFF6D28D9),
    'minimax': ('M', 0xFFE11D48),
    'alibaba': ('Q', 0xFFF97316),
    'deepseek': ('DS', 0xFF4D6BFE),
    'meta': ('M', 0xFF0064E0),
    'mistralai': ('M', 0xFFFF7000),
    'black-forest-labs': ('BF', 0xFF0EA5E9),
    'bytedance': ('BD', 0xFF325AB4),
    'recraft': ('R', 0xFF7C3AED),
    'pixverse': ('P', 0xFFDB2777),
    'lightricks': ('LT', 0xFF0891B2),
    'vidu': ('V', 0xFF16A34A),
    'runwayml': ('RW', 0xFF111827),
    'cohere': ('C', 0xFF39594D),
    'microsoft': ('MS', 0xFF0078D4),
    'nvidia': ('N', 0xFF76B900),
    'stabilityai': ('S', 0xFF7C3AED),
    'perplexity': ('P', 0xFF20808D),
  };

  @override
  Widget build(BuildContext context) {
    final key = slug.toLowerCase();
    final hit = _brands[key];
    final text = hit?.$1 ??
        (key.replaceAll(RegExp(r'[^a-z]'), '').padRight(1, '?').substring(0, 1).toUpperCase());
    final fill = Color(hit?.$2 ?? 0xFF4B5563);
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(size * 0.27),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white,
              fontSize: text.length > 1 ? size * 0.38 : size * 0.46,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
