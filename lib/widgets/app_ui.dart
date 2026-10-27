import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../utils/app_text.dart';
import '../utils/app_theme.dart';
import 'app_icon.dart';

/// The design system in one place: every screen builds its fields, buttons,
/// cards, headers, tables, chips, KPI tiles and empty states from here so no
/// two screens differ.
///
///   page #F4F6FA · cards white, 1px #E4E7EC, radius 16 · text #101828 /
///   muted #667085 · accent #2450E6 · controls 44px (40 on <= 1366), radius
///   10, 2px focus ring · Manrope with tabular figures · 4/8 spacing grid,
///   20px between cards, 32px page padding.
class AppUI {
  AppUI._();

  // ── spacing / radius ───────────────────────────────────────────────────
  static const double cardRadius = 16;
  static const double controlRadius = 10;
  static double get gap => 20.w; // between cards
  static double get pagePad => 32.w;
  static double get cardPad => 20.w;

  static bool compact(BuildContext context) => MediaQuery.of(context).size.width <= 1366;
  static double controlHeight(BuildContext context) => compact(context) ? 40 : 44;

  // ── type scale ─────────────────────────────────────────────────────────
  static TextStyle get pageTitle => TextStyle(fontSize: 26.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: -0.3);
  static TextStyle get cardTitle => TextStyle(fontSize: 17.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary);
  static TextStyle get body => TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary);
  static TextStyle get muted => TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textLight);
  static TextStyle get label => TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
  static TextStyle get caps => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textLight, letterSpacing: 0.6);
  static TextStyle get tableHead => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.4);
  static TextStyle get cell => TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary);
  static TextStyle get money => TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);

  // ── surfaces ───────────────────────────────────────────────────────────
  static BoxDecoration card({Color? color, double? radius}) => AppCard.decoration(color: color, borderRadius: radius ?? cardRadius);

  /// The tinted bar above a table / card section.
  static BoxDecoration get tableHeadBar => const BoxDecoration(color: AppColors.tableHeadBg);

  // ── fields ─────────────────────────────────────────────────────────────
  /// The one input decoration. [filled] = the field holds a value (accent
  /// edge), [leadingIcon] an AppIcon name, [label] floats above.
  static InputDecoration field(
    BuildContext context,
    String hint, {
    bool filled = false,
    String? leadingIcon,
    String? label,
    Widget? suffix,
    bool dense = false,
  }) {
    final c = compact(context);
    final rest = filled ? AppColors.primary.withValues(alpha: 0.55) : AppColors.border;
    OutlineInputBorder b(Color col, double w) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(controlRadius), borderSide: BorderSide(color: col, width: w));
    return InputDecoration(
      hintText: hint.isEmpty ? null : hint,
      labelText: label,
      hintStyle: TextStyle(fontSize: c ? 12.5 : 14, fontWeight: FontWeight.w500, color: AppColors.textLight),
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      constraints: BoxConstraints(minHeight: dense ? 36 : controlHeight(context)),
      contentPadding: EdgeInsets.symmetric(horizontal: c ? 12 : 14, vertical: dense ? 8 : (c ? 10 : 12)),
      prefixIcon: leadingIcon == null
          ? null
          : Padding(
              padding: EdgeInsets.only(left: c ? 10 : 12, right: 8),
              child: AppIcon.linear(leadingIcon, size: c ? 15 : 17, color: filled ? AppColors.primary : AppColors.textLight),
            ),
      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      suffixIcon: suffix,
      border: b(rest, 1),
      enabledBorder: b(rest, 1),
      disabledBorder: b(AppColors.cardBorder, 1),
      focusedBorder: b(AppColors.primary, 2),
      errorBorder: b(AppColors.error, 1),
      focusedErrorBorder: b(AppColors.error, 2),
    );
  }

  /// Text style for the value inside a field.
  static TextStyle fieldText(BuildContext context, {bool filled = false}) => TextStyle(
        fontSize: compact(context) ? 12.5 : 14,
        fontWeight: FontWeight.w600,
        color: filled ? AppColors.primary : AppColors.textPrimary,
      );

  /// A label above a field: "Section *" / "Remarks (optional)".
  static Widget fieldLabel(String text, {bool required = false, bool optional = false}) => Padding(
        padding: EdgeInsets.only(bottom: 6.h),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: text, style: label),
          if (required) const TextSpan(text: ' *', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w800)),
          if (optional) TextSpan(text: ' (optional)', style: muted),
        ])),
      );

  // ── buttons (the theme already gives 44px / radius 10 / focus ring) ─────
  static ButtonStyle primary(BuildContext context) => ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: Size(0, controlHeight(context)),
      );
  static ButtonStyle secondary(BuildContext context) => OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        minimumSize: Size(0, controlHeight(context)),
      );
  static ButtonStyle danger(BuildContext context) => ElevatedButton.styleFrom(
        backgroundColor: AppColors.error,
        foregroundColor: Colors.white,
        minimumSize: Size(0, controlHeight(context)),
      );

  /// "* Required fields" -- shown near the submit button of every data-entry
  /// form that has required (*) fields.
  static Widget requiredNote() => Text.rich(TextSpan(children: [
        const TextSpan(text: '* ', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w800)),
        TextSpan(text: 'Required fields', style: muted),
      ]));

  // ── page / card headers ────────────────────────────────────────────────
  /// Icon tile + title (17/800) + optional muted subtitle + trailing widgets.
  static Widget cardHeader({required String icon, required String title, String? subtitle, List<Widget> trailing = const []}) => Row(children: [
        iconTile(icon),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (subtitle != null) ...[SizedBox(height: 2.h), Text(subtitle, style: muted, maxLines: 2, overflow: TextOverflow.ellipsis)],
          ]),
        ),
        for (final w in trailing) ...[SizedBox(width: 10.w), w],
      ]);

  static Widget iconTile(String icon, {Color color = AppColors.primary, double size = 20}) => Container(
        width: size + 20,
        height: size + 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(controlRadius)),
        child: AppIcon.linear(icon, size: size, color: color),
      );

  /// SMALL CAPS group heading above a set of fields.
  static Widget sectionLabel(String text) => Padding(
        padding: EdgeInsets.only(bottom: 10.h, top: 4.h),
        child: Text(text.toUpperCase(), style: caps),
      );

  // ── status chip (colour + text, never colour alone) ─────────────────────
  static Widget chip(String text, AppStatus status) {
    final (fg, bg) = switch (status) {
      AppStatus.success => (AppColors.success, AppColors.successBg),
      AppStatus.warning => (AppColors.warning, AppColors.warningBg),
      AppStatus.danger => (AppColors.error, AppColors.errorBg),
      AppStatus.info => (AppColors.info, AppColors.infoBg),
      AppStatus.neutral => (AppColors.textSecondary, AppColors.tableHeadBg),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  // ── KPI tile ───────────────────────────────────────────────────────────
  static Widget kpi({required String icon, required String label, required String value, String? sub, Color tint = AppColors.primary}) => Container(
        padding: EdgeInsets.all(16.w),
        decoration: card(),
        child: Row(children: [
          iconTile(icon, color: tint),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label.toUpperCase(), style: caps, maxLines: 1, overflow: TextOverflow.ellipsis),
              SizedBox(height: 4.h),
              // long rupee figures shrink rather than get cut off
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary), maxLines: 1),
              ),
              if (sub != null) ...[SizedBox(height: 2.h), Text(sub, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis)],
            ]),
          ),
        ]),
      );

  // ── table helpers ──────────────────────────────────────────────────────
  static Widget th(String text, {int flex = 1, TextAlign align = TextAlign.left}) =>
      Expanded(flex: flex, child: Text(text.toUpperCase(), textAlign: align, style: tableHead));

  /// "Showing 1–25 of 273"
  static String showing(int from, int to, int total) => total == 0 ? 'Nothing to show' : 'Showing $from–$to of $total';

  // ── empty state ────────────────────────────────────────────────────────
  static Widget empty({required String title, String? why, String icon = 'document-text', Widget? action}) => Center(
        child: Padding(
          padding: EdgeInsets.all(24.w),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(cardRadius)),
              child: AppIcon.linear(icon, size: 28, color: AppColors.primary),
            ),
            SizedBox(height: 14.h),
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            if (why != null) ...[SizedBox(height: 6.h), Text(why, textAlign: TextAlign.center, style: muted)],
            if (action != null) ...[SizedBox(height: 16.h), action],
          ]),
        ),
      );
}

enum AppStatus { success, warning, danger, info, neutral }

/// The one master-detail layout: a searchable, filterable LIST card on the
/// left and the FORM / DETAIL card on the right, [AppUI.gap] apart.
///
/// Narrower than [stackBelow] (tablet) it shows one pane at a time: the list,
/// or -- when [showDetail] is true -- the detail with a Back bar that calls
/// [onBack]. Both panes are given full height; each scrolls on its own.
///
///   AppMasterDetail(
///     listTitle: 'Students', listIcon: 'people',
///     search: AppSearchField(...), filters: [classDrop, sectionDrop],
///     list: ListView(...), footer: Text(AppUI.showing(1, 25, n), style: AppUI.muted),
///     detail: _selected == null ? null : _detailCard(),
///     emptyDetail: AppUI.empty(title: 'Select a student', why: 'Pick someone on the left to see their fees.'),
///     showDetail: _selected != null, onBack: () => setState(() => _selected = null),
///   )
class AppMasterDetail extends StatelessWidget {
  final String listTitle;
  final String listIcon;
  final String? listSubtitle;
  final List<Widget> listActions;
  final Widget? search;
  final List<Widget> filters;
  final Widget list;
  final Widget? footer;
  final Widget? detail;
  final Widget? emptyDetail;
  final bool showDetail;
  final VoidCallback? onBack;
  final double listWidth;
  final double stackBelow;

  const AppMasterDetail({
    super.key,
    required this.listTitle,
    required this.listIcon,
    this.listSubtitle,
    this.listActions = const [],
    this.search,
    this.filters = const [],
    required this.list,
    this.footer,
    this.detail,
    this.emptyDetail,
    this.showDetail = false,
    this.onBack,
    this.listWidth = 380,
    this.stackBelow = 1100,
  });

  Widget _listPane() => Container(
        decoration: AppUI.card(),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              AppUI.cardHeader(icon: listIcon, title: listTitle, subtitle: listSubtitle, trailing: listActions),
              if (search != null) ...[SizedBox(height: 14.h), search!],
              for (final f in filters) ...[SizedBox(height: 10.h), f],
            ]),
          ),
          const Divider(height: 1),
          // rows and pager are picked with the mouse: Tab skips them (the
          // app's rule -- Tab walks the input fields, not the buttons)
          Expanded(child: _mouseOnly(list)),
          if (footer != null) ...[
            const Divider(height: 1),
            Padding(padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 10.h), child: _mouseOnly(footer!)),
          ],
        ]),
      );

  Widget _detailPane() => Container(
        decoration: AppUI.card(),
        clipBehavior: Clip.antiAlias,
        // one traversal group: Tab finishes the form before leaving it
        child: FocusTraversalGroup(
          child: detail ?? emptyDetail ?? AppUI.empty(title: 'Nothing selected', why: 'Pick an item on the left.'),
        ),
      );

  /// Clickable, but out of the Tab order (still focusable by click).
  static Widget _mouseOnly(Widget child) =>
      Focus(canRequestFocus: false, skipTraversal: true, descendantsAreTraversable: false, child: child);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (MediaQuery.of(context).size.width <= stackBelow) {
        if (!showDetail || detail == null) return _listPane();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (onBack != null)
            Padding(
              padding: EdgeInsets.only(bottom: 10.h),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(onPressed: onBack, icon: const Icon(Icons.arrow_back, size: 16), label: Text('Back to $listTitle')),
              ),
            ),
          Expanded(child: _detailPane()),
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: listWidth.w.clamp(300.0, c.maxWidth * 0.45), child: _listPane()),
        SizedBox(width: AppUI.gap),
        Expanded(child: _detailPane()),
      ]);
    });
  }
}

/// A form's footer bar: muted note on the left, Cancel + primary on the
/// right (the primary is usually Save / Next).
class AppFormFooter extends StatelessWidget {
  final String? note;
  final VoidCallback? onCancel;
  final String cancelLabel;
  final List<Widget> actions;
  const AppFormFooter({super.key, this.note, this.onCancel, this.cancelLabel = 'Cancel', required this.actions});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.divider))),
        child: Row(children: [
          if (note == AppText.requiredNote)
            Expanded(child: Align(alignment: Alignment.centerLeft, child: AppUI.requiredNote()))
          else if (note != null)
            Expanded(child: Text(note!, style: AppUI.muted, maxLines: 2, overflow: TextOverflow.ellipsis))
          else
            const Spacer(),
          if (onCancel != null) ...[SizedBox(width: 12.w), OutlinedButton(onPressed: onCancel, child: Text(cancelLabel))],
          for (final a in actions) ...[SizedBox(width: 10.w), a],
        ]),
      );
}

/// Multi-step form indicator: numbered steps, the current one in accent,
/// done ones ticked.
class AppStepper extends StatelessWidget {
  final List<String> steps;
  final int current; // 0-based
  const AppStepper({super.key, required this.steps, required this.current});

  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) Expanded(child: Container(height: 2, margin: EdgeInsets.symmetric(horizontal: 10.w), color: i <= current ? AppColors.primary : AppColors.divider)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: i < current ? AppColors.primary : (i == current ? AppColors.primaryLight : Colors.white),
                shape: BoxShape.circle,
                border: Border.all(color: i <= current ? AppColors.primary : AppColors.border, width: 1.5),
              ),
              child: i < current
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : Text('${i + 1}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: i == current ? AppColors.primary : AppColors.textLight)),
            ),
            SizedBox(width: 8.w),
            Text(steps[i], style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: i <= current ? AppColors.textPrimary : AppColors.textLight)),
          ]),
        ],
      ]);
}
