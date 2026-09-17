import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'compose_controller.dart';

class CodeFrame extends StatefulWidget {
  const CodeFrame({
    super.key,
    required this.controller,
    required this.scroll,
    required this.child,
  });

  final MarkdownEditingController controller;
  final ScrollController scroll;
  final Widget child;

  @override
  State<CodeFrame> createState() => _CodeFrameState();
}

class _CodeFrameState extends State<CodeFrame> {
  final _paintKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      key: _paintKey,
      foregroundPainter: _CodeFramePainter(
        controller: widget.controller,
        scroll: widget.scroll,
        host: _paintKey,
        fill: scheme.onSurface.withValues(alpha: 0.06),
        line: scheme.outline.withValues(alpha: 0.45),
      ),
      child: widget.child,
    );
  }
}

class _CodeFramePainter extends CustomPainter {
  _CodeFramePainter({
    required this.controller,
    required this.scroll,
    required this.host,
    required this.fill,
    required this.line,
  }) : super(repaint: Listenable.merge([controller, scroll]));

  final MarkdownEditingController controller;
  final ScrollController scroll;
  final GlobalKey host;
  final Color fill;
  final Color line;

  static RenderEditable? _editable(RenderObject? node) {
    if (node == null) return null;
    if (node is RenderEditable) return node;
    RenderEditable? found;
    node.visitChildren((child) {
      found ??= _editable(child);
    });
    return found;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final blocks = controller.blocks;
    final spans = controller.codeSpans;
    if (blocks.isEmpty && spans.isEmpty) return;
    final box = host.currentContext?.findRenderObject();
    final editable = _editable(box);
    if (box == null || editable == null || !editable.hasSize) return;
    final length = controller.text.length;
    final transform = editable.getTransformTo(box);
    final fillPaint = Paint()..color = fill;
    final linePaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.save();
    canvas.clipRect(
        MatrixUtils.transformRect(transform, Offset.zero & editable.size));
    canvas.transform(transform.storage);

    for (final b in blocks) {
      if (b.start > length || b.end > length) continue;
      final top =
          editable.getLocalRectForCaret(TextPosition(offset: b.start)).top;
      final bottom =
          editable.getLocalRectForCaret(TextPosition(offset: b.end)).bottom;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(0.5, top - 1, editable.size.width - 0.5, bottom + 1),
        const Radius.circular(6),
      );
      canvas.drawRRect(rect, fillPaint);
      canvas.drawRRect(rect, linePaint);
    }

    void pill(Rect r) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(r.left - 2, r.top - 0.5, r.right + 2, r.bottom + 0.5),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, fillPaint);
      canvas.drawRRect(rect, linePaint);
    }

    for (final c in spans) {
      if (c.start > length || c.end > length) continue;
      Rect? run;
      for (final tb in editable.getBoxesForSelection(
        TextSelection(baseOffset: c.start, extentOffset: c.end),
      )) {
        final r = tb.toRect();
        if (run == null) {
          run = r;
        } else if ((r.top - run.top).abs() < 1) {
          run = run.expandToInclude(r);
        } else {
          pill(run);
          run = r;
        }
      }
      if (run != null) pill(run);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CodeFramePainter old) =>
      old.controller != controller ||
      old.scroll != scroll ||
      old.fill != fill ||
      old.line != line;
}
