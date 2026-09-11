import 'package:flutter/material.dart';

import 'nym_glyphs.dart';

class NymGlyph extends StatelessWidget {
  const NymGlyph(
    this.name, {
    super.key,
    this.size = 16,
    this.color,
    this.filled = false,
    this.weight = 2,
  });

  final String name;
  final double size;
  final Color? color;

  final bool filled;

  final double weight;

  @override
  Widget build(BuildContext context) {
    final key = kNymGlyphFor[name] ?? name;
    final solid = filled ? kNymGlyphFilled[key] : null;
    final body = solid ??
        kNymGlyphStroke[key] ??
        kNymGlyphShell[key] ??
        kNymGlyphStroke['robot']!;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GlyphPainter(
          body: body,
          solid: solid != null,
          color: color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF),
          weight: weight,
        ),
      ),
    );
  }

  static bool has(String name) {
    final key = kNymGlyphFor[name] ?? name;
    return kNymGlyphStroke.containsKey(key) || kNymGlyphShell.containsKey(key);
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter({
    required this.body,
    required this.solid,
    required this.color,
    required this.weight,
  });

  final String body;
  final bool solid;
  final Color color;
  final double weight;

  static final Map<String, Path> _cache = <String, Path>{};

  @override
  void paint(Canvas canvas, Size size) {
    final path = _cache.putIfAbsent(body, () => parseGlyphBody(body));
    final scale = size.shortestSide / 24.0;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()..color = color;
    if (solid) {
      paint.style = PaintingStyle.fill;
    } else {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = weight
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
    }
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.body != body ||
      old.solid != solid ||
      old.color != color ||
      old.weight != weight;
}

final RegExp _element = RegExp(r'<(\w+)([^>]*)>');
final RegExp _attribute = RegExp(r'([a-zA-Z][a-zA-Z0-9-]*)="([^"]*)"');
final RegExp _number = RegExp(r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?');
final RegExp _commandOrNumber =
    RegExp(r'([MmLlHhVvCcSsQqTtAaZz])|([-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?)');

Path parseGlyphBody(String body) {
  final path = Path();
  for (final match in _element.allMatches(body)) {
    final tag = match.group(1)!;
    final attrs = <String, String>{};
    for (final a in _attribute.allMatches(match.group(2) ?? '')) {
      attrs[a.group(1)!] = a.group(2)!;
    }
    switch (tag) {
      case 'path':
        _appendPathData(path, attrs['d'] ?? '');
        break;
      case 'circle':
        path.addOval(Rect.fromCircle(
          center: Offset(_num(attrs['cx']), _num(attrs['cy'])),
          radius: _num(attrs['r']),
        ));
        break;
      case 'line':
        path.moveTo(_num(attrs['x1']), _num(attrs['y1']));
        path.lineTo(_num(attrs['x2']), _num(attrs['y2']));
        break;
      case 'rect':
        final rect = Rect.fromLTWH(_num(attrs['x']), _num(attrs['y']),
            _num(attrs['width']), _num(attrs['height']));
        final rx = _num(attrs['rx']);
        final ry = attrs.containsKey('ry') ? _num(attrs['ry']) : rx;
        if (rx > 0 || ry > 0) {
          path.addRRect(RRect.fromRectXY(rect, rx, ry));
        } else {
          path.addRect(rect);
        }
        break;
      case 'polyline':
      case 'polygon':
        final points = _number
            .allMatches(attrs['points'] ?? '')
            .map((m) => double.parse(m.group(0)!))
            .toList();
        for (var i = 0; i + 1 < points.length; i += 2) {
          if (i == 0) {
            path.moveTo(points[0], points[1]);
          } else {
            path.lineTo(points[i], points[i + 1]);
          }
        }
        if (tag == 'polygon' && points.length >= 6) path.close();
        break;
      default:
        throw FormatException('nym_glyph: unsupported SVG element <$tag>');
    }
  }
  return path;
}

double _num(String? raw) => raw == null ? 0 : (double.tryParse(raw.trim()) ?? 0);

void _appendPathData(Path path, String d) {
  final tokens = _commandOrNumber.allMatches(d).toList();
  var i = 0;
  var command = '';
  var current = Offset.zero;
  var start = Offset.zero;
  var control = Offset.zero;

  double next() {
    while (i < tokens.length && tokens[i].group(2) == null) {
      i++;
    }
    if (i >= tokens.length) {
      throw const FormatException('nym_glyph: path data ended mid-command');
    }
    return double.parse(tokens[i++].group(2)!);
  }

  while (i < tokens.length) {
    final letter = tokens[i].group(1);
    if (letter != null) {
      command = letter;
      i++;
      if (command == 'Z' || command == 'z') {
        path.close();
        current = start;
        control = current;
        continue;
      }
    } else if (command.isEmpty) {
      throw const FormatException('nym_glyph: path data starts with a number');
    } else if (command == 'M') {
      command = 'L';
    } else if (command == 'm') {
      command = 'l';
    }

    final relative = command == command.toLowerCase();
    final origin = relative ? current : Offset.zero;

    switch (command.toUpperCase()) {
      case 'M':
        current = Offset(next(), next()) + origin;
        path.moveTo(current.dx, current.dy);
        start = current;
        control = current;
        break;
      case 'L':
        current = Offset(next(), next()) + origin;
        path.lineTo(current.dx, current.dy);
        control = current;
        break;
      case 'H':
        current = Offset(next() + origin.dx, current.dy);
        path.lineTo(current.dx, current.dy);
        control = current;
        break;
      case 'V':
        current = Offset(current.dx, next() + origin.dy);
        path.lineTo(current.dx, current.dy);
        control = current;
        break;
      case 'C':
        final c1 = Offset(next(), next()) + origin;
        final c2 = Offset(next(), next()) + origin;
        current = Offset(next(), next()) + origin;
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, current.dx, current.dy);
        control = c2;
        break;
      case 'S':
        final c1 = current * 2 - control;
        final c2 = Offset(next(), next()) + origin;
        current = Offset(next(), next()) + origin;
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, current.dx, current.dy);
        control = c2;
        break;
      case 'Q':
        final c = Offset(next(), next()) + origin;
        current = Offset(next(), next()) + origin;
        path.quadraticBezierTo(c.dx, c.dy, current.dx, current.dy);
        control = c;
        break;
      case 'T':
        final c = current * 2 - control;
        current = Offset(next(), next()) + origin;
        path.quadraticBezierTo(c.dx, c.dy, current.dx, current.dy);
        control = c;
        break;
      case 'A':
        final rx = next();
        final ry = next();
        final rotation = next();
        final largeArc = next() != 0;
        final sweep = next() != 0;
        current = Offset(next(), next()) + origin;
        path.arcToPoint(
          current,
          radius: Radius.elliptical(rx, ry),
          rotation: rotation,
          largeArc: largeArc,
          clockwise: sweep,
        );
        control = current;
        break;
      default:
        throw FormatException('nym_glyph: unsupported path command $command');
    }

  }
}
