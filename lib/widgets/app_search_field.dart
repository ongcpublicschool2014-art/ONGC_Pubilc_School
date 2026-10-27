import 'package:flutter/material.dart';
import 'app_ui.dart';

/// Search input with leading magnifier icon, drawn with the kit field.
/// Used in place of raw TextField+InputDecoration for a consistent look
/// across all screens. Compacts at width <= 1366 to match the project's
/// responsive action-button spec.
class AppSearchField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final double? width;

  /// Optional height override. When null (the default), the field uses
  /// the theme control height (44 px, 40 px at <= 1366) so it lines up with
  /// action buttons.
  final double? height;

  final FocusNode? focusNode;
  final bool autofocus;
  final Widget? suffixIcon;

  const AppSearchField({
    super.key,
    this.controller,
    this.hintText,
    this.onChanged,
    this.width,
    this.height,
    this.focusNode,
    this.autofocus = false,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    // The kit field: white, 1px border, radius 10, 2px focus ring, control
    // height (44 / 40 on <= 1366) so it lines up with action buttons.
    return SizedBox(
      width: width,
      height: height ?? AppUI.controlHeight(context),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        style: AppUI.fieldText(context),
        decoration: AppUI.field(
          context,
          hintText ?? '',
          leadingIcon: 'search-normal',
          suffix: suffixIcon,
        ).copyWith(
          suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        ),
      ),
    );
  }
}
