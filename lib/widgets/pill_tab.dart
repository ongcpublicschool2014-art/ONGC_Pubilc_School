import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import 'app_icon.dart';
import 'app_ui.dart';

/// Pill-style tab button used across the app's screens (Fee Collection,
/// Reports, Master Data, Bank Reconciliation, Settings, Transactions).
/// Sizing collapses at width <= 1366 to keep the row compact on common
/// laptop screens while staying full-size on 1920x1080 and above.
class PillTab extends StatelessWidget {
  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const PillTab({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  /// Spacing to insert between adjacent pills (matches the pill's own
  /// breakpoint so the row breathes the same way it shrinks).
  static double gap(BuildContext context) =>
      MediaQuery.of(context).size.width <= 1366 ? 6.0 : 8.0;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final hPad = compact ? 14.0 : 18.0;
    final vPad = compact ? 8.0 : 10.0;
    final iconSize = compact ? 14.0 : 16.0;
    final textSize = compact ? 12.0 : 13.0;
    final innerGap = compact ? 6.0 : 8.0;
    final fg = selected ? AppColors.textOnPrimary : AppColors.textSecondary;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        decoration: BoxDecoration(
          color: selected ? AppColors.tabSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: iconSize, color: fg),
            SizedBox(width: innerGap),
            Text(
              label,
              style: TextStyle(
                fontSize: textSize,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
