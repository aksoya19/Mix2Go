import 'package:flutter/material.dart';
import '../theme.dart';

/// A labelled row with a gradient on/off pill toggle (Metrics / Network panels).
class ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final VoidCallback onTap;

  const ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: Mix2GoTheme.surface1,
          border: Border.all(color: Mix2GoTheme.borderDim),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: Mix2GoTheme.textMuted),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Mix2GoTheme.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            _pill(),
          ],
        ),
      ),
    );
  }

  Widget _pill() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: 34,
      height: 19,
      decoration: BoxDecoration(
        gradient: value ? Mix2GoTheme.accentGradient : null,
        color: value ? null : Mix2GoTheme.surface3,
        borderRadius: BorderRadius.circular(99),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          width: 14,
          height: 14,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
