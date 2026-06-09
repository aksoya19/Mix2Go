import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Paints the Mix2Go app mark — a rounded-square waveform logo with a signal
/// dot — matched 1:1 to assets/branding/mix2go_icon.svg (1024² coordinate
/// space, scaled to the given [Size]).
class Mix2GoIconPainter extends CustomPainter {
  /// When false, skips the dark rounded-square background (e.g. when the icon
  /// sits on an already-dark surface like the app bar).
  final bool drawBackground;
  const Mix2GoIconPainter({this.drawBackground = true});

  // Source SVG bars: x, y(top), height  (width = 80, fully rounded ends).
  static const _bars = <List<double>>[
    [168, 546, 170],
    [296, 426, 360],
    [424, 290, 520],
    [552, 370, 420],
    [680, 460, 250],
    [808, 550, 110],
  ];
  static const _barOpacity = [0.45, 0.65, 1.0, 0.82, 0.60, 0.38];
  static const _barW = 80.0;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 1024.0; // scale from SVG space

    ui.Gradient grad(Rect r, [double opacity = 1.0]) => ui.Gradient.linear(
          r.topLeft,
          r.bottomRight,
          [
            Mix2GoTheme.gradStart.withValues(alpha: opacity),
            Mix2GoTheme.gradMid.withValues(alpha: opacity),
            Mix2GoTheme.gradEnd.withValues(alpha: opacity),
          ],
          const [0.0, 0.5, 1.0],
        );

    if (drawBackground) {
      final bgRect = Offset.zero & size;
      canvas.drawRRect(
        RRect.fromRectAndRadius(bgRect, Radius.circular(230 * s)),
        Paint()
          ..shader = ui.Gradient.linear(
            bgRect.topLeft,
            bgRect.bottomRight,
            const [Color(0xFF1E1014), Color(0xFF0E0E16)],
          ),
      );
    }

    // Waveform bars.
    for (var i = 0; i < _bars.length; i++) {
      final b = _bars[i];
      final r = Rect.fromLTWH(b[0] * s, b[1] * s, _barW * s, b[2] * s);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, Radius.circular(_barW / 2 * s)),
        Paint()..shader = grad(r, _barOpacity[i]),
      );
    }

    // Signal dot + soft glow (top-right).
    final dot = Offset(856 * s, 230 * s);
    canvas.drawCircle(
      dot, 110 * s,
      Paint()..color = Mix2GoTheme.gradStart.withValues(alpha: 0.12),
    );
    final dotRect = Rect.fromCircle(center: dot, radius: 72 * s);
    canvas.drawCircle(dot, 72 * s, Paint()..shader = grad(dotRect));
  }

  @override
  bool shouldRepaint(covariant Mix2GoIconPainter oldDelegate) =>
      oldDelegate.drawBackground != drawBackground;
}
