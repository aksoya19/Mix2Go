import 'package:flutter/material.dart';
import '../../audio/audio_manager.dart';
import '../theme.dart';

/// Circular status indicator. A STATIC glow (no continuous animation) — on the
/// Dart-fed audio architecture a running animation here would compete with the
/// audio feed callback and cause underruns. State is shown by colour + label;
/// the moving VU meter provides the "live" feel.
class StatusOrb extends StatelessWidget {
  final AudioState state;
  final int buffered;     // shown as "n/target" while buffering
  final int targetBuffer; // pre-buffer target

  const StatusOrb({
    required this.state,
    this.buffered = 0,
    this.targetBuffer = 6,
    super.key,
  });

  bool get _active =>
      state == AudioState.playing || state == AudioState.buffering;

  String get _label => switch (state) {
        AudioState.playing   => 'LIVE',
        AudioState.buffering => '$buffered/$targetBuffer',
        AudioState.error     => '!',
        AudioState.stopped   => '—',
      };

  String get _hint => switch (state) {
        AudioState.playing   => 'STEREO',
        AudioState.buffering => 'BUFFERING',
        AudioState.error     => 'NO SIGNAL',
        AudioState.stopped   => 'STANDBY',
      };

  @override
  Widget build(BuildContext context) {
    final color = Mix2GoTheme.stateColor(state);
    return SizedBox(
      width: 220,
      height: 220,
      child: Center(
        child: Container(
          width: 124,
          height: 124,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Mix2GoTheme.surface1,
            border: Border.all(
              color: _active ? color.withValues(alpha: 0.5) : Mix2GoTheme.borderNorm,
              width: 1.2,
            ),
            boxShadow: _active
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.22),
                      blurRadius: 40,
                      spreadRadius: 4,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _label,
                style: TextStyle(
                  fontFamily: Mix2GoTheme.displayFont,
                  fontWeight: FontWeight.w700,
                  fontSize: 36,
                  letterSpacing: 1,
                  color: state == AudioState.stopped
                      ? Mix2GoTheme.textMuted
                      : color,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _hint,
                style: const TextStyle(
                  fontSize: 8.5,
                  letterSpacing: 2.5,
                  fontWeight: FontWeight.w600,
                  color: Mix2GoTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
