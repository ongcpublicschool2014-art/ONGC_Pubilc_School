import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../utils/app_menu.dart';
import '../utils/app_theme.dart';
import 'app_dropdown_field.dart';
import 'app_icon.dart';
import 'app_ui.dart';

/// Set by Sequence Master around the series' panel: which series is showing
/// and how to switch. Panels opened anywhere else have none.
class SequenceTypeScope extends InheritedWidget {
  const SequenceTypeScope({super.key, required this.label, required this.onChanged, required super.child});

  /// The kSequenceTypes label (tab key) on show.
  final String label;
  final ValueChanged<String> onChanged;

  static SequenceTypeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SequenceTypeScope>();

  @override
  bool updateShouldNotify(SequenceTypeScope old) => old.label != label;
}

/// The "Sequence Type" dropdown, first field of every sequence form
/// (user, 2026-11-13). Nothing when the form isn't inside Sequence Master.
class SequenceTypeField extends StatelessWidget {
  const SequenceTypeField({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = SequenceTypeScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final types = visibleSequenceTypes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Sequence Type', style: AppUI.label),
        SizedBox(height: 6.h),
        AppDropdownField<String>(
          key: ValueKey('seqtype-${scope.label}'),
          initialValue: types.any((t) => t.label == scope.label) ? scope.label : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          style: AppUI.fieldText(context),
          icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          decoration: AppUI.field(context, 'Select sequence type', filled: true),
          items: [
            for (final t in types)
              DropdownMenuItem(
                value: t.label,
                child: Row(children: [
                  AppIcon(t.icon, size: 16, color: AppColors.primary),
                  SizedBox(width: 10.w),
                  Flexible(child: Text(t.navTitle, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context))),
                ]),
              ),
          ],
          onChanged: (v) {
            if (v != null && v != scope.label) scope.onChanged(v);
          },
        ),
        SizedBox(height: 16.h),
      ],
    );
  }
}
