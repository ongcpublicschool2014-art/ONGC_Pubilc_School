import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../utils/app_theme.dart';
import 'app_icon.dart';

/// Shared "no data" placeholder — a soft icon chip, a title and an optional
/// subtitle (and optional action). Use this in place of ad-hoc `Text('No data')`
/// so empty states look consistent and modern across every list/table.
class EmptyState extends StatelessWidget {
  final String icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final double iconSize;

  const EmptyState({
    super.key,
    this.icon = 'document-text',
    required this.title,
    this.subtitle,
    this.action,
    this.iconSize = 30,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.w),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: iconSize + 32,
              height: iconSize + 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(16),
              ),
              child: AppIcon.linear(icon, size: iconSize, color: AppColors.accent),
            ),
            SizedBox(height: 14.h),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            if (subtitle != null) ...[
              SizedBox(height: 5.h),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textLight),
              ),
            ],
            if (action != null) ...[
              SizedBox(height: 16.h),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Shared centred loading indicator with an optional label. Spinner colour comes
/// from the app theme (primary).
class AppLoading extends StatelessWidget {
  final String? label;
  const AppLoading({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 30, height: 30, child: CircularProgressIndicator(strokeWidth: 3)),
          if (label != null) ...[
            SizedBox(height: 12.h),
            Text(label!, style: TextStyle(fontSize: 12.5.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          ],
        ],
      ),
    );
  }
}
