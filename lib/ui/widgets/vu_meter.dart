import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Horizontal stereo output-level meter (L / R), drawn with a single
/// [CustomPaint]. Renders ONLY when new level data arrives (driven by the
/// parent's ValueListenableBuilder at the audio emit rate) — no continuous
/// ticker, which would compete with the audio feed on the shared Dart thread.
class VuMeter extends StatelessWidget {
  final double levelL; // 0.0–1.0
  final double levelR; // 0.0–1.0
  const VuMeter({required this.levelL, required this.levelR, super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: const Size(double.infinity, 64),
        painter: _VuPainter(levelL, levelR),
      ),
    );
  }
}

class _VuPainter extends CustomPainter {
  final double l, r;
  _VuPainter(this.l, this.r);

  static const _fill = LinearGradient(
    colors: [
      Color(0xFF22C55E),
      Color(0xFF84CC16),
      Color(0xFFF97316),
      Color(0xFFE8445A),
    ],
    stops: [0.0, 0.6, 0.85, 1.0],
  );

  // Peak amplitude → dB.
  static double _dbVal(double level) =>
      20 * (math.log(level.clamp(0.00002, 1.0)) / math.ln10);

  // dB readout text.
  static String _db(double level) {
    final db = _dbVal(level);
    return db <= -54 ? '−∞' : '${db.round()}';
  }

  // Bar fill 0..1 on a −54 dB → 0 dB scale (reads like a DAW meter, not linear).
  static double _norm(double level) =>
      ((_dbVal(level) + 54) / 54).clamp(0.0, 1.0);

  void _text(Canvas c, String s, Offset at, TextStyle style,
      {bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, right ? at.translate(-tp.width, 0) : at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const labelW = 16.0, dbW = 36.0, gap = 8.0, trackH = 10.0, rowH = 26.0;

    _text(canvas, 'OUTPUT LEVEL', Offset.zero,
        const TextStyle(fontSize: 9, letterSpacing: 1.5, color: Mix2GoTheme.textMuted));

    final trackLeft = labelW + gap;
    final trackW = size.width - trackLeft - gap - dbW;

    void row(double y, String ch, double level) {
      final cy = y + (rowH - trackH) / 2;
      _text(canvas, ch, Offset(0, cy - 1),
          const TextStyle(
              fontFamily: Mix2GoTheme.displayFont,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: Mix2GoTheme.gradStart));

      final base = RRect.fromRectAndRadius(
          Rect.fromLTWH(trackLeft, cy, trackW, trackH), const Radius.circular(5));
      canvas.drawRRect(base, Paint()..color = Mix2GoTheme.borderDim);

      final w = trackW * _norm(level);
      if (w > 1) {
        canvas.save();
        canvas.clipRRect(base);
        canvas.drawRect(
            Rect.fromLTWH(trackLeft, cy, w, trackH),
            Paint()
              ..shader = _fill.createShader(
                  Rect.fromLTWH(trackLeft, cy, trackW, trackH)));
        canvas.restore();
      }

      _text(canvas, _db(level), Offset(size.width, cy - 1),
          const TextStyle(
              fontFamily: 'monospace', fontSize: 10, color: Mix2GoTheme.textMuted),
          right: true);
    }

    row(18, 'L', l);
    row(18 + rowH, 'R', r);
  }

  @override
  bool shouldRepaint(covariant _VuPainter old) => old.l != l || old.r != r;
}
