import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../utils/app_theme.dart';
import 'app_ui.dart';

/// Said before any money is taken: this fee group has no receipt number series
/// yet, and exactly where to create it. Shared by Fee Collection, Miscellaneous
/// Collection and Advance Fee Collection (user, 2026-11-18).
Future<void> showMissingSequenceDialog(BuildContext context,
    {required String group, bool advance = false, bool arrear = false, bool misc = false}) {
  final name = group.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  final kind = advance
      ? 'Advance Receipt'
      : arrear
          ? 'Arrear Receipt'
          : (misc ? 'Miscellaneous Receipt' : 'Receipt');
  final what = '${kind.toLowerCase()} sequence';
  final tab = '$kind No.';
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      title: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
        SizedBox(width: 10.w),
        Expanded(child: Text('Create the $kind Sequence', style: AppUI.cardTitle)),
      ]),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$name has no $what, so this collection cannot be saved. Nothing has been collected.', style: AppUI.body),
          SizedBox(height: 12.h),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
            decoration: BoxDecoration(
              color: AppColors.warningBg,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
            ),
            child: Text('Create it in Setup → Sequence Master → $tab, for $name.', style: AppUI.label),
          ),
          SizedBox(height: 10.h),
          Text('If you cannot open Setup, ask your administrator.', style: AppUI.muted),
        ]),
      ),
      actions: [
        ElevatedButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
      ],
    ),
  );
}
