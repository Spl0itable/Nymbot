import 'package:flutter/material.dart';

class NymAvatar extends StatelessWidget {
  const NymAvatar({super.key, required this.seed, this.size = 30, this.bot = false});

  final String seed;
  final double size;
  final bool bot;

  @override
  Widget build(BuildContext context) {
    if (bot) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.16),
        ),
        alignment: Alignment.center,
        child: Text(
          'n',
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            fontSize: size * 0.52,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    return ClipOval(
      child: CustomPaint(
        size: Size.square(size),
        painter: _IdenticonPainter(seed),
      ),
    );
  }
}

class _IdenticonPainter extends CustomPainter {
  _IdenticonPainter(this.seed);

  final String seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rand = NymIdentity.rng(NymIdentity.fnv(seed));
    final hue = (rand() * 360).floor().toDouble();
    final sat = (60 + (rand() * 25).floor()) / 100;
    final light = (50 + (rand() * 15).floor()) / 100;
    final fg = HSLColor.fromAHSL(1, hue, sat, light).toColor();
    final bg = HSLColor.fromAHSL(1, (hue + 180) % 360, 0.25, 0.18).toColor();

    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    const cols = 5;
    const rows = 5;
    final cell = size.width / cols;
    final paint = Paint()..color = fg;
    const half = 3;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < half; x++) {
        if (rand() < 0.5) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
          final mirror = cols - 1 - x;
          if (mirror != x) {
            canvas.drawRect(
                Rect.fromLTWH(mirror * cell, y * cell, cell, cell), paint);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) => old.seed != seed;
}

class NymIdentity {
  const NymIdentity._();

  static const adjectives = [
    'quantum', 'neon', 'cyber', 'shadow', 'plasma',
    'echo', 'nexus', 'void', 'flux', 'ghost',
    'phantom', 'stealth', 'cryptic', 'dark', 'neural',
    'binary', 'matrix', 'digital', 'virtual', 'zero',
    'null', 'anon', 'masked', 'hidden', 'cipher',
    'enigma', 'spectral', 'rogue', 'omega', 'alpha',
    'delta', 'sigma', 'vortex', 'turbo', 'razor',
    'blade', 'frost', 'storm', 'glitch', 'pixel',
    'hyper', 'proto', 'nano', 'micro', 'ultra',
    'silent', 'feral', 'lucid', 'primal', 'astral',
    'cobalt', 'onyx', 'crimson', 'obsidian', 'iron',
    'solar', 'lunar', 'stellar', 'cosmic', 'atomic',
    'toxic', 'rapid', 'swift', 'fierce',
  ];

  static const nouns = [
    'ghost', 'nomad', 'drift', 'pulse', 'wave',
    'spark', 'node', 'byte', 'mesh', 'link',
    'runner', 'hacker', 'coder', 'agent', 'proxy',
    'daemon', 'virus', 'worm', 'bot', 'droid',
    'reaper', 'shadow', 'wraith', 'specter', 'shade',
    'entity', 'unit', 'core', 'nexus', 'cypher',
    'breach', 'exploit', 'overflow', 'inject', 'root',
    'kernel', 'shell', 'terminal', 'console', 'script',
    'raven', 'wolf', 'viper', 'hawk', 'lynx',
    'phantom', 'signal', 'cipher', 'vector', 'forge',
    'circuit', 'photon', 'glider', 'shard', 'vault',
    'beacon', 'torrent', 'crypt', 'grid', 'orbit',
  ];

  static const colours = [
    Color(0xFFFF6B35), Color(0xFFF7931A), Color(0xFFFFD200), Color(0xFFCCCCCC),
    Color(0xFF1E90FF), Color(0xFF8A2BE2), Color(0xFFC40233), Color(0xFFFF1493),
  ];

  static int fnv(String key) {
    var h = 2166136261;
    for (var i = 0; i < key.length; i++) {
      h ^= key.codeUnitAt(i);
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return h;
  }

  static double Function() rng(int seed) {
    var s = (seed == 0 ? 1 : seed) & 0xFFFFFFFF;
    return () {
      s = (s + 0x6D2B79F5) & 0xFFFFFFFF;
      var x = ((s ^ (s >> 15)) * (1 | s)) & 0xFFFFFFFF;
      x = (((x + (((x ^ (x >> 7)) * (61 | x)) & 0xFFFFFFFF)) & 0xFFFFFFFF) ^ x) &
          0xFFFFFFFF;
      return ((x ^ (x >> 14)) & 0xFFFFFFFF) / 4294967296;
    };
  }

  static String name(String pubkey) {
    final rand = rng(fnv(pubkey));
    final adj = adjectives[(rand() * adjectives.length).floor() % adjectives.length];
    final noun = nouns[(rand() * nouns.length).floor() % nouns.length];
    return '${adj}_$noun';
  }

  static String suffix(String pubkey) => pubkey.length >= 4
      ? pubkey.substring(pubkey.length - 4)
      : '${fnv(pubkey).toRadixString(16)}0000'.substring(0, 4);

  static Color colour(String pubkey) => colours[fnv(pubkey) % colours.length];

  static String handle(String pubkey) => '${name(pubkey)}#${suffix(pubkey)}';
}
