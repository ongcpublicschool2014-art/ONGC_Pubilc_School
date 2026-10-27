import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../utils/app_theme.dart';
import 'app_icon.dart';

/// Shared card-header title block — plain accent icon beside a bold title.
/// Used as the standard header pattern across every card/section in the
/// project (Fee Master, Master Data, Admission Master, Admin Creation, Fee
/// Concession, etc.).
class CardTitleBlock extends StatelessWidget {
  final String icon;
  final String title;
  final double iconSize;

  const CardTitleBlock({
    super.key,
    required this.icon,
    required this.title,
    // Accepted for call-site compatibility; no longer rendered.
    String? subtitle,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // Icon in a soft accent-tinted chip — the standard modern section-header
      // affordance, applied everywhere CardTitleBlock is used.
      Container(
        width: iconSize + 14,
        height: iconSize + 14,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: AppIcon.linear(icon, size: iconSize, color: AppColors.accent),
      ),
      SizedBox(width: 10.w),
      // Flexible so a long title wraps / ellipsizes to the card width instead
      // of overflowing (e.g. "Admission Number Sequencing" in a narrow panel).
      Flexible(
        child: Text(title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 17.sp,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
    ]);
  }
}
