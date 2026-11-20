import 'package:flutter/material.dart';

/// [DropdownButtonFormField] that shows the field's placeholder (the
/// `hint` widget [AppUI.field] puts in the decoration) inside the dropdown,
/// so it sits centred like a text field's placeholder. Flutter only does
/// this for a plain `hintText`; a hint widget is left on the baseline, low
/// in the box.
class AppDropdownField<T> extends DropdownButtonFormField<T> {
  AppDropdownField({
    super.key,
    required super.items,
    super.selectedItemBuilder,
    // ignore: deprecated_member_use
    T? value,
    T? initialValue,
    Widget? hint,
    super.disabledHint,
    required super.onChanged,
    super.onTap,
    super.elevation,
    super.style,
    super.icon,
    super.iconDisabledColor,
    super.iconEnabledColor,
    super.iconSize,
    super.isDense,
    super.isExpanded,
    super.itemHeight,
    super.focusColor,
    super.focusNode,
    super.autofocus,
    super.dropdownColor,
    InputDecoration? decoration,
    super.onSaved,
    super.validator,
    super.errorBuilder,
    super.forceErrorText,
    super.autovalidateMode,
    super.menuMaxHeight,
    super.enableFeedback,
    super.alignment,
    super.borderRadius,
    super.padding,
  }) : super(
          initialValue: initialValue ?? value,
          decoration: decoration,
          hint: hint ?? decoration?.hint,
        );
}
