import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/excel_theme.dart';
import '../../utils/friendly_error.dart';
import '../../utils/save_path.dart';
import '../../widgets/app_ui.dart';

/// Shared by the ATTENDANCE screens (Attendance Entry, Leave & Out-pass,
/// Attendance Report, Attendance Setup): dates, status colours, the reason
/// prompt, snack bars, card shells and the Excel export.

const kAttMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const kAttWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// What each kind of calendar day is called.
const kAttDayTypes = {
  'WORKING': 'Working day',
  'HOLIDAY': 'Holiday',
  'WEEKEND': 'Weekly off',
  'HALF_DAY': 'Half day',
  'EXAM': 'Exam day',
  'EVENT': 'Event day',
  'OUTSIDE_YEAR': 'Outside the year',
};

/// One colour per kind of day (user, 2026-11-24: "use different colours"),
/// the same in the calendar, its list and the day dialog.
Color attDayColor(String type) => switch (type) {
      'HOLIDAY' => AppColors.error, // coral red
      'HALF_DAY' => AppColors.goldDark, // amber
      'EXAM' => AppColors.info, // purple
      'EVENT' => AppColors.teal, // blue
      'WEEKEND' => AppColors.ink3, // grey
      _ => AppColors.primary, // a working day
    };

const kAttLeaveTypes = {'MEDICAL': 'Medical', 'FAMILY': 'Family', 'BEREAVEMENT': 'Bereavement', 'OTHER': 'Other'};

const kAttLeaveStatus = {
  'DRAFT': 'Draft',
  'PENDING_CLASS_INCHARGE': 'With class in-charge',
  'PENDING_DIVISION_INCHARGE': 'With division in-charge',
  'APPROVED': 'Approved',
  'REJECTED': 'Rejected',
  'CANCELLED': 'Cancelled',
};

const kAttOutpassReasons = {'SICKNESS': 'Sickness', 'FAMILY': 'Family', 'EMERGENCY': 'Emergency', 'OTHER': 'Other'};

/// "24-Nov-2026"
String attDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${kAttMonths[d.month - 1]}-${d.year}';

/// "Tue, 24-Nov-2026"
String attDayLabel(DateTime d) => '${kAttWeekdays[d.weekday - 1]}, ${attDate(d)}';

/// A server date ("2026-11-24", or with a time) as a date, or null.
DateTime? attParse(dynamic v) {
  final s = '${v ?? ''}'.trim();
  if (s.isEmpty || s == 'null') return null;
  final d = DateTime.tryParse(s);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// A server date shown as "24-Nov-2026" ('-' when blank).
String attShow(dynamic v) {
  final d = attParse(v);
  return d == null ? '-' : attDate(d);
}

DateTime attOnly(DateTime d) => DateTime(d.year, d.month, d.day);

int attInt(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
int? attIntOrNull(dynamic v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
String attText(dynamic v) => v == null ? '' : '$v'.trim();

/// The colour stored on a status ('#2E7D32'), else a sensible one.
Color attStatusColor(Map<String, dynamic>? status) {
  final hex = attText(status?['display_color']).replaceFirst('#', '');
  final v = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
  if (v != null) return Color(v);
  return status?['counts_as_present'] == true ? AppColors.primary : AppColors.error;
}

Future<DateTime?> pickAttDate(BuildContext context, DateTime initial, {DateTime? first, DateTime? last}) {
  final f = first ?? DateTime(initial.year - 1);
  final l = last ?? DateTime(initial.year + 1, 12, 31);
  final i = initial.isBefore(f) ? f : (initial.isAfter(l) ? l : initial);
  return showDatePicker(context: context, initialDate: i, firstDate: f, lastDate: l);
}

void attSnack(BuildContext context, String msg, {bool error = false}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? AppColors.error : AppColors.success,
  ));
}

void attError(BuildContext context, Object e) => attSnack(context, friendlyError(e), error: true);

/// Asks for a short reason (a change to a submitted register, a rejection).
/// Null when cancelled.
Future<String?> askAttReason(BuildContext context, {required String title, String? message, String hint = 'Reason'}) =>
    showDialog<String>(context: context, builder: (_) => _ReasonDialog(title: title, message: message, hint: hint));

/// Owns its text controller, so it lives as long as the dialog (closing
/// animation included).
class _ReasonDialog extends StatefulWidget {
  final String title;
  final String? message;
  final String hint;
  const _ReasonDialog({required this.title, this.message, required this.hint});

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.message != null) ...[Text(widget.message!, style: AppUI.muted), const SizedBox(height: 12)],
            TextField(
              key: const ValueKey('att-reason'),
              controller: _c,
              autofocus: true,
              maxLength: 300,
              maxLines: 2,
              style: AppUI.fieldText(context),
              decoration: AppUI.field(context, widget.hint),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(AppText.cancel)),
          ElevatedButton(
            style: AppUI.primary(context),
            onPressed: () {
              if (_c.text.trim().isEmpty) return;
              Navigator.pop(context, _c.text.trim());
            },
            child: const Text('OK'),
          ),
        ],
      );
}

Future<bool> confirmAtt(BuildContext context, {required String title, required String message, String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 420, child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
        ElevatedButton(
          style: danger ? AppUI.danger(ctx) : AppUI.primary(ctx),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

/// A card with the standard header and a body that fills the rest.
class AttCard extends StatelessWidget {
  final String icon;
  final String title;
  final String? subtitle;
  final List<Widget> trailing;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  const AttCard({super.key, required this.icon, required this.title, this.subtitle, this.trailing = const [], required this.child, this.padding});

  @override
  Widget build(BuildContext context) => Container(
        decoration: AppUI.card(),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14.h, AppUI.cardPad, 10.h),
            child: AppUI.cardHeader(icon: icon, title: title, subtitle: subtitle, trailing: trailing),
          ),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(child: Padding(padding: padding ?? EdgeInsets.zero, child: child)),
        ]),
      );
}

/// A date shown as a field with a calendar button; tap to pick.
class AttDateField extends StatelessWidget {
  final DateTime? value;
  final String hint;
  final ValueChanged<DateTime> onPicked;
  final DateTime? first;
  final DateTime? last;
  final bool enabled;
  const AttDateField({super.key, required this.value, required this.onPicked, this.hint = 'Pick date', this.first, this.last, this.enabled = true});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: !enabled
            ? null
            : () async {
                final d = await pickAttDate(context, value ?? DateTime.now(), first: first, last: last);
                if (d != null) onPicked(attOnly(d));
              },
        child: InputDecorator(
          decoration: AppUI.field(context, hint, filled: value != null, leadingIcon: 'calendar-1'),
          child: Text(value == null ? '' : attDate(value!), style: AppUI.fieldText(context, filled: value != null)),
        ),
      );
}

/// A table header bar: [cells] are [AppUI.th] widgets.
Widget attHeadRow(List<Widget> cells) => Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
      decoration: AppUI.tableHeadBar,
      child: Row(children: cells),
    );

/// A small coloured count: "Present 28".
Widget attCount(String label, Object value, Color color) => Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 5.h),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8.r)),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '$label ', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.ink2)),
        TextSpan(text: '$value', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: color)),
      ])),
    );

/// Saves [rows] under [headers] to an .xlsx the user picks. Returns the path,
/// or null when cancelled.
Future<String?> exportAttTable(String name, List<String> headers, List<List<Object?>> rows) async {
  final path = await pickSavePath(
    dialogTitle: 'Save $name',
    fileName: '${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (path == null) return null;
  final book = xl.Excel.createExcel();
  final sheet = book[name.length > 31 ? name.substring(0, 31) : name];
  final head = xl.CellStyle(bold: true, backgroundColorHex: XlTheme.headerBg, fontColorHex: XlTheme.headerFg);
  for (var i = 0; i < headers.length; i++) {
    final c = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    c.value = xl.TextCellValue(headers[i]);
    c.cellStyle = head;
    sheet.setColumnWidth(i, headers[i].length < 10 ? 14 : headers[i].length + 6);
  }
  for (var r = 0; r < rows.length; r++) {
    for (var i = 0; i < rows[r].length; i++) {
      final v = rows[r][i];
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: r + 1)).value = v == null
          ? null
          : v is int
              ? xl.IntCellValue(v)
              : v is num
                  ? xl.DoubleCellValue(v.toDouble())
                  : xl.TextCellValue('$v');
    }
  }
  if (book.sheets.containsKey('Sheet1') && name != 'Sheet1') book.delete('Sheet1');
  final bytes = book.encode();
  if (bytes != null) File(path).writeAsBytesSync(bytes);
  return path;
}
