import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../utils/app_theme.dart';
import 'app_icon.dart';
import 'app_ui.dart';

/// A titled panel grouping a set of form fields.
///
/// One implementation for every admission form, so Student Transfer and
/// Transfer Certificate cannot drift apart. They had two near-identical
/// helpers before: one drew a tinted header BAND with a bare icon, the other
/// an icon TILE with no band, and the two screens looked subtly unlike each
/// other for no reason anyone intended.
///
/// The header is a tinted band carrying a rounded icon tile and the title; the
/// body is the plain kit card. The band is what lets a long form read as a few
/// named sections rather than one run of rows.
class FormSectionPanel extends StatelessWidget {
  const FormSectionPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.compact = false,
  });

  final String title;

  /// Icon name from the linear set (see [AppIcon]).
  final String icon;

  final Widget child;

  /// Tightens padding for 1366px-wide laptops, matching the forms' own
  /// `compact` breakpoint.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: (compact ? 12 : 16).w,
              vertical: (compact ? 9 : 11).h,
            ),
            decoration: const BoxDecoration(
              color: AppColors.tableHeadBg,
              border: Border(bottom: BorderSide(color: AppColors.divider)),
            ),
            child: Row(
              children: [
                AppUI.iconTile(icon, size: compact ? 14 : 16),
                SizedBox(width: 10.w),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.label,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              (compact ? 12 : 16).w,
              (compact ? 12 : 16).h,
              (compact ? 12 : 16).w,
              (compact ? 12 : 16).h,
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// A field's label — small icon, bold caption — above its input.
///
/// Also shared, for the same reason: the two screens labelled their fields
/// differently, one with an icon and one without.
class FormFieldLabel extends StatelessWidget {
  const FormFieldLabel({
    super.key,
    required this.label,
    required this.child,
    this.icon,
  });

  final String label;
  final String? icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: 6.h, left: 2.w),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                AppIcon.linear(icon!, size: 13, color: AppColors.primary),
                SizedBox(width: 6.w),
              ],
              Text(label, style: AppUI.label),
            ],
          ),
        ),
        child,
      ],
    );
  }
}
