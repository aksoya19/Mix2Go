import 'package:flutter/material.dart';
import '../audio/audio_manager.dart';

/// Mix2Go design tokens — dark studio aesthetic with an orange→pink→purple
/// accent gradient. Single source of truth for colours, gradients and fonts.
class Mix2GoTheme {
  // ── Surfaces ───────────────────────────────────────────────────────────
  static const bg        = Color(0xFF0C0C0E);
  static const surface1  = Color(0xFF141416);
  static const surface2  = Color(0xFF1A1A1E);
  static const surface3  = Color(0xFF222228);

  // ── Borders ────────────────────────────────────────────────────────────
  static const borderDim  = Color(0x12FFFFFF); // 7% white
  static const borderNorm = Color(0x21FFFFFF); // 13% white

  // ── Text ───────────────────────────────────────────────────────────────
  static const textPrim  = Color(0xEBFFFFFF); // 92%
  static const textMuted  = Color(0x61FFFFFF); // 38%
  static const textDim   = Color(0x24FFFFFF); // 14%

  // ── Accent gradient (orange → pink → purple) ───────────────────────────
  static const gradStart = Color(0xFFF97316);
  static const gradMid   = Color(0xFFE8445A);
  static const gradEnd   = Color(0xFFC026D3);

  static const LinearGradient accentGradient = LinearGradient(
    colors: [gradStart, gradMid, gradEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── State colours ──────────────────────────────────────────────────────
  static const stateStreaming = Color(0xFF22C55E);
  static const stateSearching = Color(0xFFF97316);
  static const stateBuffering = Color(0xFFFBBF24);
  static const stateError     = Color(0xFFF87171);
  static const stateStopped   = Color(0x3FFFFFFF);

  static Color stateColor(AudioState state) => switch (state) {
        AudioState.stopped   => stateStopped,
        AudioState.buffering => stateBuffering,
        AudioState.playing   => stateStreaming,
        AudioState.error     => stateError,
      };

  // ── Typography ─────────────────────────────────────────────────────────
  static const String displayFont = 'BarlowCondensed';

  static const TextStyle eyebrow = TextStyle(
    fontSize: 9,
    height: 1.2,
    letterSpacing: 1.5,
    fontWeight: FontWeight.w500,
    color: textMuted,
  );

  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: textPrim,
  );
}
