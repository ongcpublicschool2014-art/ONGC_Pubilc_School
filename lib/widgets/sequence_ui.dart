import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../utils/app_text.dart';
import '../utils/app_theme.dart';
import '../utils/master_usage.dart';
import 'app_icon.dart';
import 'app_ui.dart';
import 'card_title_block.dart';
import 'sequence_type_field.dart';

/// One row of a sequence list.
class SeqRow {
  const SeqRow({
    required this.name,
    this.sub,
    required this.prefix,
    required this.next,
    required this.lastIssued,
    this.selected = false,
    this.onEdit,
    this.onDelete,
  });

  final String name;

  /// Second line under the name (e.g. the division), or null.
  final String? sub;
  final String prefix;

  /// The number the series issues next; null = not set up yet.
  final String? next;
  final String lastIssued;
  final bool selected;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
}

/// One design for every number-sequence screen -- Register / TC, Demand /
/// Concession / Refund / Advance Receipt and Receipt No. (user, 2026-11-13).
/// The cards and the list rows are the same as the other masters (Fee Type,
/// Fee Group ...): form card on the left, list card with S NO. and ACTION on
/// the right, zebra rows.
class SequenceUI {
  SequenceUI._();

  static const _icon = 'hashtag';

  static Widget layout({required Widget form, required Widget list}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Scrolls on a short screen instead of running past the bottom.
          SizedBox(width: 340.w, child: SingleChildScrollView(child: form)),
          SizedBox(width: AppUI.gap),
          Expanded(child: list),
        ],
      );

  /// Left card: title, Sequence Type (inside Sequence Master), [fields],
  /// the preview, the button and the required-fields note.
  static Widget formCard({
    required String title,
    String? subtitle,
    required List<Widget> fields,
    required String? preview,
    String previewHint = 'Enter a prefix to see the preview',
    required Widget button,
    VoidCallback? onCancel,
  }) =>
      Container(
        padding: EdgeInsets.all(AppUI.cardPad),
        decoration: AppUI.card(),
        child: FocusTraversalGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              CardTitleBlock(icon: _icon, title: title, subtitle: subtitle),
              SizedBox(height: 20.h),
              const SequenceTypeField(),
              ...fields,
              SizedBox(height: 16.h),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                ),
                child: Row(children: [
                  Text('Preview:  ', style: AppUI.muted),
                  Expanded(
                    child: preview == null
                        ? Text(previewHint, style: AppUI.muted, overflow: TextOverflow.ellipsis)
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(preview,
                                maxLines: 1, softWrap: false, style: AppUI.money.copyWith(color: AppColors.primary)),
                          ),
                  ),
                ]),
              ),
              SizedBox(height: 18.h),
              if (onCancel == null)
                SizedBox(width: double.infinity, child: button)
              else
                Row(children: [
                  Expanded(child: button),
                  SizedBox(width: 8.w),
                  OutlinedButton(onPressed: onCancel, child: const Text(AppText.cancel)),
                ]),
              SizedBox(height: 10.h),
              AppUI.requiredNote(),
            ],
          ),
        ),
      );

  static Widget saveButton({required bool saving, bool editing = false, VoidCallback? onPressed}) =>
      ElevatedButton.icon(
        onPressed: saving ? null : onPressed,
        icon: saving
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(editing ? Icons.save_rounded : Icons.add, size: 16),
        label: Text(editing ? AppText.update : AppText.save),
      );

  /// '<affix><number>' (or '<number><affix>' for a suffix) of the number the
  /// series issues next.
  static String nextNumber({required String affix, bool suffix = false, required int current, required int start, required int width}) {
    final n = (current <= 0 || current < start ? start : current + 1).toString().padLeft(width, '0');
    return suffix ? '$n$affix' : '$affix$n';
  }

  static String lastIssued({required int current, required int start}) =>
      issued(current: current, start: start) ? '$current' : '—';

  /// The series has handed out at least one number.
  static bool issued({required int current, required int start}) => current > 0 && current >= start;

  /// Delete rule for every series: refused once it has issued numbers
  /// (a new series would start over and repeat numbers already printed on
  /// documents), otherwise asked. True = go ahead.
  static Future<bool> confirmDelete(BuildContext context,
      {required String name, required int current, required int start}) async {
    if (issued(current: current, start: start)) {
      await showMasterInUseDialog(context,
          name: name,
          count: current,
          noun: 'number',
          detail: 'has already issued numbers, up to $current.',
          fix: 'Deleting it would let a new series start over and hand out '
              'numbers that are already printed on issued documents.');
      return false;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Sequence'),
        content: Text('Delete the sequence "$name"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(AppText.delete, style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    return ok == true;
  }

  /// Right card -- same as the other masters' lists.
  static Widget listCard({
    required String title,
    required bool loading,
    required List<SeqRow> rows,
    int? count,
    required String emptyTitle,
    String emptyWhy = 'Add one with the form on the left.',
    String? hint,
  }) {
    final h = AppUI.tableHead;
    final c = AppUI.cell;
    final n = count ?? rows.length;
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 12.h),
            child: Row(children: [
              CardTitleBlock(icon: _icon, title: title),
              SizedBox(width: 10.w),
              AppUI.chip('$n sequence${n == 1 ? '' : 's'}', AppStatus.info),
              const Spacer(),
              if (hint != null) Text(hint, style: AppUI.muted),
            ]),
          ),
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                children: [
                  Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    child: Row(children: [
                      SizedBox(width: 50.w, child: Text('S NO.', style: h)),
                      // Equal widths for the four data columns (user, 2026-11-13).
                      Expanded(child: Text('SEQUENCE', style: h)),
                      Expanded(child: Text('PREFIX', style: h)),
                      Expanded(child: Text('NEXT NO.', style: h)),
                      Expanded(child: Text('LAST ISSUED', style: h)),
                      SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: h)),
                    ]),
                  ),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator())
                        : rows.isEmpty
                            ? AppUI.empty(title: emptyTitle, why: emptyWhy, icon: _icon)
                            : ListView.separated(
                                itemCount: rows.length,
                                separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                                itemBuilder: (_, i) {
                                  final r = rows[i];
                                  return InkWell(
                                    onTap: r.onEdit,
                                    child: Container(
                                      color: r.selected ? AppColors.primaryLight : (i.isEven ? Colors.white : AppColors.surface),
                                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                                      child: Row(children: [
                                        SizedBox(width: 50.w, child: Text('${i + 1}', style: c)),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(r.name,
                                                  style: r.selected ? c.copyWith(fontWeight: FontWeight.w700) : c,
                                                  overflow: TextOverflow.ellipsis),
                                              if (r.sub != null && r.sub!.isNotEmpty)
                                                Text(r.sub!, style: AppUI.muted, overflow: TextOverflow.ellipsis),
                                            ],
                                          ),
                                        ),
                                        Expanded(child: Text(r.prefix.isEmpty ? '—' : r.prefix, style: c, overflow: TextOverflow.ellipsis)),
                                        Expanded(
                                          child: r.next == null
                                              ? Align(alignment: Alignment.centerLeft, child: AppUI.chip('Not set', AppStatus.warning))
                                              : Text(r.next!, style: c, overflow: TextOverflow.ellipsis),
                                        ),
                                        Expanded(child: Text(r.lastIssued, style: c)),
                                        SizedBox(
                                          width: 90.w,
                                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                            if (r.onEdit != null)
                                              InkWell(
                                                onTap: r.onEdit,
                                                child: Padding(
                                                    padding: EdgeInsets.all(4.w),
                                                    child: const AppIcon('edit-2', size: 16, color: AppColors.primary)),
                                              ),
                                            if (r.onEdit != null && r.onDelete != null) SizedBox(width: 8.w),
                                            if (r.onDelete != null)
                                              InkWell(
                                                onTap: r.onDelete,
                                                child: Padding(
                                                    padding: EdgeInsets.all(4.w),
                                                    child: const AppIcon('trash', size: 16, color: AppColors.error)),
                                              ),
                                          ]),
                                        ),
                                      ]),
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
