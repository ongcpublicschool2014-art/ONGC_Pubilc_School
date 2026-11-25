import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import 'package:url_launcher/url_launcher.dart';

import '../../services/supabase_service.dart';
import '../../services/transport_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'stop_map_picker.dart';

/// Shared parts of the transport master screens: a field-driven form
/// ([TrFormBody], [showTrFormDialog]) whose edit dialog also deletes, a
/// searchable table that opens it ([TrPanel]), and the date picker
/// ([trPickDate]).

// ── value helpers ────────────────────────────────────────────────────────────
int? trId(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}'.trim());
String trText(dynamic v) => v == null ? '' : '$v'.trim();

/// A number as the user would type it: 5000.0 -> "5000", 12.5 -> "12.5".
String trNumberText(dynamic v) {
  if (v == null) return '';
  final n = v is num ? v : num.tryParse('$v');
  if (n == null) return '$v';
  return n == n.truncate() ? n.truncate().toString() : n.toString();
}

/// Days from [today] until an ISO date; null when there is no date.
int? trDaysLeft(String? iso, {DateTime? today}) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return null;
  final t = today ?? DateTime.now();
  return DateTime(d.year, d.month, d.day).difference(DateTime(t.year, t.month, t.day)).inDays;
}

/// A time of day as the forms keep it, "07:05", from what the server sends
/// ("07:05:00") or a form value; null when there is none.
String? trTimeValue(dynamic v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(trText(v));
  return m == null ? null : '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}';
}

/// Minutes after midnight for a time of day, or null.
int? trMinutes(dynamic v) {
  final t = trTimeValue(v);
  return t == null ? null : int.parse(t.substring(0, 2)) * 60 + int.parse(t.substring(3));
}

/// Minutes after midnight -> "07:05".
String trHhmm(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// A time of day as people read it: "07:05:00" -> "7:05 AM".
String trTimeText(dynamic v) {
  final m = trMinutes(v);
  if (m == null) return '';
  final h = m ~/ 60;
  return '${h % 12 == 0 ? 12 : h % 12}:${(m % 60).toString().padLeft(2, '0')} ${h < 12 ? 'AM' : 'PM'}';
}

/// Weekday names for ISO day numbers 1 (Monday) .. 7 (Sunday).
const trWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// ISO weekdays (1 = Monday .. 7 = Sunday) from a list, sorted, each once.
List<int> trDayList(dynamic v) =>
    v is List ? ({for (final d in v) trId(d)}.whereType<int>().where((d) => d >= 1 && d <= 7).toList()..sort()) : <int>[];

/// Weekdays as a short phrase: [1..6] -> "Mon–Sat", [1, 3, 5] -> "Mon, Wed, Fri".
String trDaysText(dynamic v) {
  final days = trDayList(v);
  if (days.isEmpty) return '-';
  if (days.length == 7) return 'Every day';
  final run = days.length >= 3 && days.last - days.first == days.length - 1;
  return run ? '${trWeekdays[days.first - 1]}–${trWeekdays[days.last - 1]}' : days.map((d) => trWeekdays[d - 1]).join(', ');
}

/// EXPIRED / "12 DAYS LEFT" / VALID for a document's expiry date.
(String, AppStatus) trExpiryStatus(String? iso, {int warnDays = 30, DateTime? today}) {
  final left = trDaysLeft(iso, today: today);
  if (left == null) return ('No Expiry', AppStatus.neutral);
  if (left < 0) return ('Expired', AppStatus.danger);
  if (left <= warnDays) return ('$left Days Left', AppStatus.warning);
  return ('Valid', AppStatus.success);
}

void trSnack(BuildContext context, String message, Color color) {
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
}

// ── date picker ──────────────────────────────────────────────────────────────
/// The date picker of every transport screen. A date is typed as
/// dd/mm/yyyy ("-" or "." also work), and the header reads "Wed, 1 Apr":
/// the app's built-in English would take mm/dd/yyyy.
Future<DateTime?> trPickDate(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
}) =>
    showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: helpText,
      builder: (ctx, child) => Localizations.override(context: ctx, delegates: const [_DmyDelegate()], child: child),
    );

/// The built-in English, with dates written and typed day first.
class _DmyLocalizations extends DefaultMaterialLocalizations {
  const _DmyLocalizations();

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  String formatCompactDate(DateTime date) => '${_two(date.day)}/${_two(date.month)}/${date.year.toString().padLeft(4, '0')}';

  @override
  DateTime? parseCompactDate(String? inputString) {
    final m = RegExp(r'^\s*(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})\s*$').firstMatch(inputString ?? '');
    if (m == null) return null;
    final day = int.parse(m.group(1)!), month = int.parse(m.group(2)!), year = int.parse(m.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > DateUtils.getDaysInMonth(year, month)) return null;
    return DateTime(year, month, day);
  }

  @override
  String get dateHelpText => 'dd/mm/yyyy';

  @override
  String formatMediumDate(DateTime date) => '${_weekday(date)}, ${date.day} ${_month(date)}';

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _weekday(DateTime d) => _weekdays[d.weekday - 1];
  static String _month(DateTime d) => _months[d.month - 1];
}

class _DmyDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _DmyDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) => SynchronousFuture<MaterialLocalizations>(const _DmyLocalizations());

  @override
  bool shouldReload(_DmyDelegate old) => false;
}

// ── where records come from ──────────────────────────────────────────────────
/// How a [TrPanel] and its edit dialog list, save and delete records: the
/// transport functions by default ([TrSource.transport]); another module
/// passes its own, e.g. Staff Details.
class TrSource {
  final Future<List<Map<String, dynamic>>> Function(Map<String, dynamic> filter) list;

  /// Inserts when the row has no key, updates otherwise. Returns the row's id.
  final Future<int?> Function(Map<String, dynamic> row) save;

  /// Returns what happened: DELETED, INACTIVE or RELIEVED.
  final Future<String> Function(int id) remove;
  const TrSource({required this.list, required this.save, required this.remove});

  factory TrSource.transport(String entity) => TrSource(
        list: (filter) => TransportService.list(entity, filter: filter),
        save: (row) => TransportService.save(entity, row),
        remove: (id) => TransportService.remove(entity, id),
      );
}

// ── add / edit result, and delete ────────────────────────────────────────────
/// What an add / edit dialog did: saved the record [id], or, when [deleted]
/// is set, deleted it instead ([deleted] is what the server did: DELETED,
/// INACTIVE when switched off, RELIEVED ...).
class TrEdit {
  final int id;
  final String? deleted;
  const TrEdit(this.id, {this.deleted});

  /// What to tell the user once the dialog has closed.
  String get message => switch (deleted) {
        null => 'Saved.',
        'DELETED' => 'Deleted.',
        'RELIEVED' => 'Marked Relieved.',
        _ => 'Switched off.',
      };
}

/// Delete in an edit dialog: the question asked first, and what it explains
/// (e.g. that a route is only switched off).
class TrDelete {
  final String title;
  final String note;
  const TrDelete(this.title, this.note);
}

/// Asks [del]'s question; true when the user chose Delete.
Future<bool> trAskDelete(BuildContext context, TrDelete del) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(del.title),
        content: Text(del.note),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.danger(ctx), child: const Text(AppText.delete)),
        ],
      ),
    ) ==
    true;

/// The footer of an add / edit dialog: Delete (an existing record only, set
/// apart on the left), then Cancel and Save.
Widget trFormFooter(
  BuildContext context, {
  required bool saving,
  required bool deleting,
  required VoidCallback onSave,
  VoidCallback? onDelete,
}) {
  final busy = saving || deleting;
  return AppFormFooter(
    note: AppText.requiredNote,
    actions: [
      if (onDelete != null) ...[
        OutlinedButton.icon(
          onPressed: busy ? null : onDelete,
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.error, side: const BorderSide(color: AppColors.error)),
          icon: AppIcon('trash', size: AppBtn.iconSize(context), color: AppColors.error),
          label: Text(deleting ? 'Deleting...' : AppText.delete),
        ),
        SizedBox(width: 18.w),
      ],
      OutlinedButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text(AppText.cancel)),
      ElevatedButton(
        onPressed: busy ? null : onSave,
        style: AppUI.primary(context),
        child: Text(saving ? 'Saving...' : AppText.save),
      ),
    ],
  );
}

/// The name to show for an uploaded file: the original name kept after the
/// upload stamp, e.g. ".../1731300000000000_RC_Book.pdf" -> "RC_Book.pdf".
String trFileName(String url) {
  final uri = Uri.tryParse(url);
  final last = uri != null && uri.pathSegments.isNotEmpty ? uri.pathSegments.last : url.split('/').last;
  return last.replaceFirst(RegExp(r'^\d{10,}_'), '');
}

/// Opens an attachment in the default browser or viewer.
Future<void> trOpenFile(BuildContext context, String url) async {
  try {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) trSnack(context, 'Could not open the file.', AppColors.error);
  } catch (e) {
    if (context.mounted) trSnack(context, AppText.couldNot('open the file', friendlyError(e)), AppColors.error);
  }
}

/// A table cell: a paperclip that opens the row's attachment, or "-".
Widget trAttachmentCell(BuildContext context, dynamic url) {
  final u = trText(url);
  if (u.isEmpty) return Text('-', style: AppUI.cell);
  return IconButton(
    tooltip: 'Open ${trFileName(u)}',
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    onPressed: () => trOpenFile(context, u),
    icon: const AppIcon('paperclip-2', size: 16, color: AppColors.primary),
  );
}

// ── form ─────────────────────────────────────────────────────────────────────
/// A [TrKind.photo] field is not placed in the flow of fields: it sits in the
/// form's top-right corner, beside the first group, like the photo on an ID
/// card. Its place in the field list does not matter.
/// A [TrKind.file] field is an attachment (PDF, JPG or PNG) with View.
/// A [TrKind.time] field is a time of day, kept as "07:05". A [TrKind.days]
/// field picks weekdays, kept as ISO numbers [1 (Monday) .. 7 (Sunday)].
/// [TrKind.display] is read-only: it shows [TrField.displayFor] and is never saved.
/// The "Add New ..." item of a choice with [TrField.onAdd] (never a value).
class _TrAddNew {
  const _TrAddNew();
}

const _kTrAddNew = _TrAddNew();

/// [password]: typed hidden, never shown back (the form starts it empty).
/// [digits]: digits only, kept as text (a phone number's leading 0 stays).
/// [suggest]: typed text that lists [TrField.suggestions] as it is typed (as
/// Admission Entry's City / Religion / Nationality), without limiting to them.
enum TrKind { text, multiline, upper, integer, decimal, mobile, date, time, days, toggle, choice, photo, file, display, map, password, digits, suggest }

/// Where [TrKind.photo] and [TrKind.file] uploads go: the app's public image
/// bucket, under [TrField.folder]. The server accepts only links into its
/// transport/ folder.
const _uploadBucket = 'InstitutionLogos';
const _photoMaxBytes = 2 * 1024 * 1024;
const _fileMaxBytes = 5 * 1024 * 1024;

/// Width of the corner photo column; the picture is passport-shaped (7:9).
const double _photoWidth = 144;

class TrField {
  final String key;
  final String label;
  final TrKind kind;
  final bool required;
  final String? hint;
  final int? maxLength;

  /// Takes the form's whole width instead of half.
  final bool full;

  /// Starts a new group of fields under this small heading.
  final String? section;

  /// For [TrKind.choice]: (value, label).
  final List<(Object?, String)> options;

  /// For [TrKind.choice]: the options as they depend on what the form holds
  /// (e.g. only the staff of the chosen duty), used instead of [options]. A
  /// value that is no longer among them is cleared.
  final List<(Object?, String)> Function(Map<String, dynamic> values)? optionsFor;

  /// Shown only when this returns true. A hidden field is saved as empty.
  final bool Function(Map<String, dynamic> values)? visibleWhen;

  /// For [TrKind.suggest]: the values offered (already used ones, say).
  final List<String> suggestions;

  /// For a typed field: checked on save when it is filled; returns the
  /// message to show, or null when the value is fine.
  final String? Function(String text)? check;

  /// For [TrKind.choice]: a last item ([addLabel], e.g. "Add New Designation")
  /// that calls this. The value it returns is chosen (null: cancelled); by
  /// then the screen has put it among the options.
  final Future<Object?> Function()? onAdd;
  final String? addLabel;

  /// For [TrKind.photo]: the storage folder, e.g. 'transport/staff'.
  final String folder;

  /// For [TrKind.display]: the text to show, worked out from what the form
  /// holds (e.g. the fuel of the chosen vehicle). Empty shows [hint].
  final String Function(Map<String, dynamic> values)? displayFor;

  /// [TrKind.map]: the other points to show, and the two decimal fields of
  /// the same form the map fills (never saved itself).
  final List<TrMapPoint> mapPoints;
  final String latKey;
  final String lonKey;

  const TrField(
    this.key,
    this.label, {
    this.kind = TrKind.text,
    this.required = false,
    this.hint,
    this.maxLength,
    this.full = false,
    this.section,
    this.options = const [],
    this.optionsFor,
    this.visibleWhen,
    this.onAdd,
    this.addLabel,
    this.suggestions = const [],
    this.check,
    this.folder = 'transport',
    this.displayFor,
    this.mapPoints = const [],
    this.latKey = 'latitude',
    this.lonKey = 'longitude',
  });
}

/// The fields of one record. Keep a GlobalKey to call [TrFormBodyState.collect].
class TrFormBody extends StatefulWidget {
  final List<TrField> fields;
  final Map<String, dynamic> initial;
  final bool enabled;

  /// Called with everything the form holds after the user changes a field.
  final ValueChanged<Map<String, dynamic>>? onChanged;
  const TrFormBody({super.key, required this.fields, this.initial = const {}, this.enabled = true, this.onChanged});

  @override
  State<TrFormBody> createState() => TrFormBodyState();
}

class TrFormBodyState extends State<TrFormBody> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, dynamic> _values = {};

  /// The photo field being uploaded, if any. Saving waits for it.
  String? _uploading;

  /// Bumped after an "Add New ..." item is picked, so the dropdown shows the
  /// field's value again instead of that item.
  int _addTick = 0;

  Future<void> _addOption(TrField f) async {
    final v = await f.onAdd!();
    if (!mounted) return;
    _addTick++;
    _set(f.key, v ?? _values[f.key]);
  }

  static bool _isText(TrKind k) =>
      k == TrKind.text || k == TrKind.multiline || k == TrKind.upper || k == TrKind.integer || k == TrKind.decimal || k == TrKind.mobile ||
      k == TrKind.password || k == TrKind.digits || k == TrKind.suggest;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final v = widget.initial[f.key];
      if (_isText(f.kind)) {
        final numeric = f.kind == TrKind.integer || f.kind == TrKind.decimal;
        _text[f.key] = TextEditingController(text: f.kind == TrKind.password ? '' : (numeric ? trNumberText(v) : trText(v)));
      } else if (f.kind == TrKind.date) {
        final s = trText(v);
        _values[f.key] = s.length >= 10 ? s.substring(0, 10) : null;
      } else if (f.kind == TrKind.time) {
        _values[f.key] = trTimeValue(v);
      } else if (f.kind == TrKind.days) {
        _values[f.key] = trDayList(v);
      } else if (f.kind == TrKind.toggle) {
        _values[f.key] = v == true;
      } else {
        _values[f.key] = v;
      }
    }
    _dropStale();
  }

  /// The suggestion fields' focus (RawAutocomplete needs one that lasts).
  final Map<String, FocusNode> _focus = {};

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  /// Everything the form holds right now, for [TrField.visibleWhen].
  Map<String, dynamic> get _current => {..._values, for (final e in _text.entries) e.key: e.value.text.trim()};

  bool _visible(TrField f) => f.visibleWhen == null || f.visibleWhen!(_current);

  /// A non-text field's new value, passed on to [TrFormBody.onChanged].
  void _set(String key, dynamic value) {
    setState(() {
      _values[key] = value;
      _dropStale();
    });
    widget.onChanged?.call(_current);
  }

  /// A choice field's options now.
  List<(Object?, String)> _options(TrField f) => f.optionsFor?.call(_current) ?? f.options;

  /// Clears a choice whose value has dropped out of its [TrField.optionsFor],
  /// so the form never sends a value it no longer shows.
  void _dropStale() {
    for (final f in widget.fields) {
      if (f.kind != TrKind.choice || f.optionsFor == null) continue;
      final v = _values[f.key];
      if (v != null && !_options(f).any((o) => o.$1 == v)) _values[f.key] = null;
    }
  }

  /// The row to save, or null after telling the user what is missing. Numbers
  /// go as the text typed, so an amount is never rounded on the way.
  Map<String, dynamic>? collect() {
    if (_uploading != null) return _missing('Wait for the photo to finish uploading.');
    final row = <String, dynamic>{};
    final current = _current;
    for (final f in widget.fields) {
      if (f.kind == TrKind.display || f.kind == TrKind.map) continue;  // shown only, never saved
      if (!_visible(f)) {
        row[f.key] = null;
        continue;
      }
      if (_isText(f.kind)) {
        final t = _text[f.key]!.text.trim();
        if (t.isEmpty) {
          if (f.required) return _missing('Enter the ${f.label.toLowerCase()}.');
          row[f.key] = null;
          continue;
        }
        if (f.kind == TrKind.integer && !RegExp(r'^\d+$').hasMatch(t)) {
          return _missing('${f.label} must be a whole number.');
        }
        if (f.kind == TrKind.decimal && !RegExp(r'^-?\d+(\.\d+)?$').hasMatch(t)) {
          return _missing('${f.label} must be a number.');
        }
        if (f.kind == TrKind.mobile && !RegExp(r'^\+?\d{10,14}$').hasMatch(t)) {
          return _missing('${f.label}: enter a valid 10-digit number.');
        }
        final problem = f.check?.call(t);
        if (problem != null) return _missing(problem);
        row[f.key] = t;
      } else {
        final v = current[f.key];
        final empty = v == null || (v is List && v.isEmpty);
        if (f.required && f.kind != TrKind.toggle && empty) {
          return _missing('${f.kind == TrKind.date || f.kind == TrKind.time ? 'Select' : 'Choose'} the ${f.label.toLowerCase()}.');
        }
        row[f.key] = empty ? null : v;
      }
    }
    return row;
  }

  Map<String, dynamic>? _missing(String message) {
    trSnack(context, message, AppColors.warning);
    return null;
  }

  Future<void> _pickDate(TrField f) async {
    final now = DateTime.now();
    final current = DateTime.tryParse('${_values[f.key] ?? ''}');
    final picked = await trPickDate(
      context,
      initialDate: current ?? now,
      firstDate: DateTime(1950),
      lastDate: DateTime(now.year + 30),
      helpText: f.label,
    );
    if (picked == null || !mounted) return;
    _set(f.key, '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
  }

  /// Typed as hours and minutes (quicker than the dial for a timetable);
  /// an empty field starts at 7:00 AM.
  Future<void> _pickTime(TrField f) async {
    final m = trMinutes(_values[f.key]) ?? 7 * 60;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
      initialEntryMode: TimePickerEntryMode.input,
      helpText: f.label,
    );
    if (picked == null || !mounted) return;
    _set(f.key, trHhmm(picked.hour * 60 + picked.minute));
  }

  /// Seven day switches in a row, Mon .. Sun.
  Widget _days(TrField f) {
    final days = trDayList(_values[f.key]);
    return SizedBox(
      height: AppUI.controlHeight(context),
      child: Row(children: [
        for (var d = 1; d <= 7; d++) ...[
          if (d > 1) SizedBox(width: 6.w),
          Expanded(
            child: Material(
              color: days.contains(d) ? AppColors.primary : AppColors.fieldBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                side: BorderSide(color: days.contains(d) ? AppColors.primary : AppColors.fieldBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.enabled ? () => _set(f.key, days.contains(d) ? (List<int>.of(days)..remove(d)) : trDayList([...days, d])) : null,
                child: Center(
                  child: Text(trWeekdays[d - 1],
                      style: AppUI.label.copyWith(color: days.contains(d) ? AppColors.onPrimary : AppColors.ink2)),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  /// A file name made safe for a storage key, without its extension.
  static String _safeName(String name) {
    final dot = name.lastIndexOf('.');
    var base = (dot > 0 ? name.substring(0, dot) : name).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');
    if (base.length > 60) base = base.substring(0, 60);
    return base.isEmpty ? 'file' : base;
  }

  /// Pick a file, upload it under [TrField.folder], and keep its public URL as
  /// the field value; the record itself is saved with the form's Save.
  /// Photo: PNG/JPG up to 2 MB. File: PDF/PNG/JPG up to 5 MB, keeping the
  /// original name after a unique stamp.
  Future<void> _upload(TrField f) async {
    final photo = f.kind == TrKind.photo;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: photo ? ['png', 'jpg', 'jpeg'] : ['pdf', 'png', 'jpg', 'jpeg'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null || !mounted) return;
    var ext = (file.extension ?? '').toLowerCase();
    if (ext == 'jpeg') ext = 'jpg';
    final type = switch (ext) { 'pdf' when !photo => 'application/pdf', 'jpg' => 'image/jpeg', 'png' => 'image/png', _ => null };
    if (type == null) {
      trSnack(context, photo ? 'Choose a JPG or PNG image.' : 'Choose a PDF, JPG or PNG file.', AppColors.warning);
      return;
    }
    setState(() => _uploading = f.key);
    try {
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      final max = photo ? _photoMaxBytes : _fileMaxBytes;
      if (bytes.length > max) {
        if (mounted) trSnack(context, 'The file is larger than ${max ~/ (1024 * 1024)} MB. Choose a smaller file.', AppColors.warning);
        return;
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final path = photo ? '${f.folder}/$stamp.$ext' : '${f.folder}/${stamp}_${_safeName(file.name)}.$ext';
      final bucket = SupabaseService.client.storage.from(_uploadBucket);
      await bucket.uploadBinary(path, bytes, fileOptions: FileOptions(contentType: type));
      if (mounted) _set(f.key, bucket.getPublicUrl(path));
    } catch (e) {
      if (mounted) trSnack(context, AppText.couldNot(photo ? 'upload the photo' : 'upload the file', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  /// An attachment: its name with View and Remove, and Attach File / Replace.
  Widget _file(TrField f) {
    final url = trText(_values[f.key]);
    final busy = _uploading == f.key;
    final canAct = widget.enabled && _uploading == null;
    // Small buttons, so the field stays as tall as the others.
    ButtonStyle small([Color color = AppColors.primaryText]) => TextButton.styleFrom(
          foregroundColor: color,
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 30),
          padding: EdgeInsets.symmetric(horizontal: 10.w),
        );
    return InputDecorator(
      decoration: AppUI.field(context, '', filled: url.isNotEmpty, leadingIcon: 'paperclip-2'),
      child: Row(children: [
        Expanded(
          child: busy
              ? Text('Uploading...', style: AppUI.muted)
              : url.isEmpty
                  ? Text('No file attached. PDF, JPG or PNG, max 5 MB.', style: AppUI.muted, overflow: TextOverflow.ellipsis)
                  : Text(trFileName(url), style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis),
        ),
        if (url.isNotEmpty && !busy) ...[
          TextButton(onPressed: () => trOpenFile(context, url), style: small(), child: const Text('View')),
          TextButton(
            onPressed: canAct ? () => _set(f.key, null) : null,
            style: small(AppColors.error),
            child: const Text('Remove'),
          ),
        ],
        TextButton(onPressed: canAct ? () => _upload(f) : null, style: small(), child: Text(url.isEmpty ? 'Attach File' : 'Replace')),
      ]),
    );
  }

  /// The picture (click it to choose an image), then Upload / Change, and
  /// Remove once there is a photo. Laid out for the narrow corner column.
  Widget _photo(TrField f) {
    final url = trText(_values[f.key]);
    final busy = _uploading == f.key;
    final canAct = widget.enabled && _uploading == null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      AspectRatio(
        aspectRatio: 7 / 9,
        child: Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            side: const BorderSide(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: canAct ? () => _upload(f) : null,
            child: busy
                ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                : url.isEmpty
                    ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const AppIcon.linear('gallery-add', size: 28, color: AppColors.ink2),
                        SizedBox(height: 6.h),
                        Text('Add photo', style: AppUI.muted),
                      ])
                    : Image.network(
                        url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(child: AppIcon.linear('gallery-slash', size: 28, color: AppColors.ink2)),
                      ),
          ),
        ),
      ),
      SizedBox(height: 8.h),
      OutlinedButton(
        onPressed: canAct ? () => _upload(f) : null,
        style: AppUI.secondary(context),
        child: FittedBox(fit: BoxFit.scaleDown, child: Text(busy ? 'Uploading...' : (url.isEmpty ? 'Upload Photo' : 'Change Photo'))),
      ),
      if (url.isNotEmpty && !busy)
        TextButton(
          onPressed: canAct ? () => _set(f.key, null) : null,
          style: TextButton.styleFrom(foregroundColor: AppColors.error, visualDensity: VisualDensity.compact),
          child: const Text('Remove Photo'),
        ),
      SizedBox(height: 4.h),
      Text('PNG or JPG, max 2 MB', textAlign: TextAlign.center, style: AppUI.muted),
    ]);
  }

  /// A typed field listing [TrField.suggestions]: all of them when it is
  /// empty, those containing what is typed otherwise.
  Widget _suggest(TrField f) {
    final c = _text[f.key]!;
    final hint = f.hint ?? '';
    return LayoutBuilder(
      builder: (context, box) => RawAutocomplete<String>(
        textEditingController: c,
        focusNode: _focus.putIfAbsent(f.key, () => FocusNode()),
        optionsBuilder: (v) {
          final q = v.text.trim().toLowerCase();
          if (q.isEmpty) return f.suggestions;
          return f.suggestions.where((o) => o.toLowerCase().contains(q) && o.toLowerCase() != q);
        },
        onSelected: (_) {
          setState(() {});
          widget.onChanged?.call(_current);
        },
        fieldViewBuilder: (context, ctrl, focus, _) => TextField(
          controller: ctrl,
          focusNode: focus,
          enabled: widget.enabled,
          inputFormatters: [if (f.maxLength != null) LengthLimitingTextInputFormatter(f.maxLength)],
          textCapitalization: TextCapitalization.words,
          style: AppUI.fieldText(context),
          decoration: AppUI.field(context, '', filled: ctrl.text.trim().isNotEmpty).copyWith(hintText: hint.isEmpty ? null : hint),
          onChanged: (_) {
            setState(() {});
            widget.onChanged?.call(_current);
          },
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 240, maxWidth: box.maxWidth),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, i) {
                  final o = options.elementAt(i);
                  return ListTile(dense: true, title: Text(o, style: AppUI.fieldText(context)), onTap: () => onSelected(o));
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _input(TrField f) {
    final hint = f.hint ?? '';
    switch (f.kind) {
      case TrKind.photo:
        return _photo(f);
      case TrKind.file:
        return _file(f);
      case TrKind.days:
        return _days(f);
      case TrKind.suggest:
        return _suggest(f);
      case TrKind.map:
        final lat = _text[f.latKey], lon = _text[f.lonKey];
        if (lat == null || lon == null) return const SizedBox.shrink();
        return StopMapPicker(lat: lat, lon: lon, others: f.mapPoints, enabled: widget.enabled,
            onChanged: () => widget.onChanged?.call(_current));
      case TrKind.display:
        final shown = f.displayFor?.call(_current) ?? '';
        return InputDecorator(
          decoration: AppUI.field(context, '', filled: shown.isNotEmpty),
          child: Text(shown.isEmpty ? (hint.isEmpty ? '-' : hint) : shown,
              overflow: TextOverflow.ellipsis, style: shown.isEmpty ? AppUI.muted : AppUI.fieldText(context)),
        );
      case TrKind.toggle:
        return SizedBox(
          height: AppUI.controlHeight(context),
          child: Row(children: [
            Switch(
              value: _values[f.key] == true,
              activeTrackColor: AppColors.primary,
              activeThumbColor: Colors.white,
              onChanged: widget.enabled ? (v) => _set(f.key, v) : null,
            ),
            SizedBox(width: 6.w),
            Expanded(child: Text(_values[f.key] == true ? 'Yes' : 'No', style: AppUI.body)),
          ]),
        );
      case TrKind.choice:
        final value = _values[f.key];
        final options = _options(f);
        final known = options.any((o) => o.$1 == value);
        return AppDropdownField<Object?>(
          key: ValueKey(_addTick == 0 ? 'tr-${f.key}-$value' : 'tr-${f.key}-$value-$_addTick'),
          initialValue: known ? value : null,
          isExpanded: true,
          dropdownColor: AppColors.card,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          style: AppUI.fieldText(context),
          // A plain hint here: the shrink-to-fit hint of AppUI.field fails a
          // layout check inside a dropdown.
          decoration: AppUI.field(context, '', filled: value != null),
          hint: Text(hint.isEmpty ? 'Select' : hint, overflow: TextOverflow.ellipsis, style: AppUI.muted),
          items: [
            if (!f.required) DropdownMenuItem<Object?>(value: null, child: Text('None', style: AppUI.muted)),
            for (final o in options) DropdownMenuItem<Object?>(value: o.$1, child: Text(o.$2, overflow: TextOverflow.ellipsis)),
            if (f.onAdd != null)
              DropdownMenuItem<Object?>(
                value: _kTrAddNew,
                child: Row(children: [
                  const AppIcon('add-circle', size: 16, color: AppColors.primary),
                  SizedBox(width: 8.w),
                  Flexible(
                    child: Text(f.addLabel ?? 'Add New',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
          ],
          onChanged: widget.enabled
              ? (v) {
                  if (identical(v, _kTrAddNew)) {
                    _addOption(f);
                  } else {
                    _set(f.key, v);
                  }
                }
              : null,
        );
      case TrKind.date:
        final iso = _values[f.key] as String?;
        return InkWell(
          onTap: widget.enabled ? () => _pickDate(f) : null,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          child: InputDecorator(
            decoration: AppUI.field(
              context,
              '',
              filled: iso != null,
              leadingIcon: 'calendar',
              suffix: iso == null || f.required || !widget.enabled
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => _set(f.key, null),
                    ),
            ),
            child: Text(iso == null ? 'DD-MM-YYYY' : formatDate(iso), style: iso == null ? AppUI.muted : AppUI.fieldText(context)),
          ),
        );
      case TrKind.time:
        final hhmm = _values[f.key] as String?;
        return InkWell(
          onTap: widget.enabled ? () => _pickTime(f) : null,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          child: InputDecorator(
            decoration: AppUI.field(
              context,
              '',
              filled: hhmm != null,
              leadingIcon: 'clock',
              suffix: hhmm == null || f.required || !widget.enabled
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => _set(f.key, null),
                    ),
            ),
            child: Text(hhmm == null ? '--:-- --' : trTimeText(hhmm), style: hhmm == null ? AppUI.muted : AppUI.fieldText(context)),
          ),
        );
      default:
        final c = _text[f.key]!;
        final secret = f.kind == TrKind.password;
        return TextField(
          controller: c,
          enabled: widget.enabled,
          obscureText: secret,
          autocorrect: !secret,
          enableSuggestions: !secret,
          minLines: f.kind == TrKind.multiline ? 2 : 1,
          maxLines: f.kind == TrKind.multiline ? 3 : 1,
          textCapitalization: f.kind == TrKind.upper
              ? TextCapitalization.characters
              : (secret ? TextCapitalization.none : TextCapitalization.sentences),
          keyboardType: f.kind == TrKind.integer || f.kind == TrKind.decimal || f.kind == TrKind.mobile || f.kind == TrKind.digits
              ? TextInputType.number
              : null,
          inputFormatters: [
            if (f.kind == TrKind.integer || f.kind == TrKind.digits) FilteringTextInputFormatter.digitsOnly,
            if (f.kind == TrKind.decimal) FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
            if (f.kind == TrKind.mobile) FilteringTextInputFormatter.allow(RegExp(r'[+0-9]')),
            if (f.maxLength != null) LengthLimitingTextInputFormatter(f.maxLength),
          ],
          style: AppUI.fieldText(context),
          // A plain hint here too, for the same layout check as the dropdown.
          decoration: AppUI.field(context, '', filled: c.text.trim().isNotEmpty).copyWith(hintText: hint.isEmpty ? null : hint),
          onChanged: (_) {
            setState(_dropStale);
            widget.onChanged?.call(_current);
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final gap = 14.w;

      // The fields in groups, each (heading, its visible fields). Photo
      // fields stay out of the groups: they go in the top-right corner.
      final groups = <(String?, List<TrField>)>[];
      final photos = <TrField>[];
      for (final f in widget.fields) {
        if (f.kind == TrKind.photo) {
          if (_visible(f)) photos.add(f);
          continue;
        }
        if (f.section != null || groups.isEmpty) groups.add((f.section, <TrField>[]));
        if (_visible(f)) groups.last.$2.add(f);
      }

      Widget fieldsIn(List<TrField> fields, double width, {double oneColumnBelow = 520}) {
        final half = width < oneColumnBelow ? width : (width - gap) / 2;
        return Wrap(spacing: gap, runSpacing: 12.h, children: [
          for (final f in fields)
            SizedBox(
              width: f.full ? width : half,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                AppUI.fieldLabel(f.label, required: f.required),
                _input(f),
              ]),
            ),
        ]);
      }

      Widget photoColumn() => SizedBox(
            width: _photoWidth,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < photos.length; i++) ...[
                if (i > 0) SizedBox(height: 12.h),
                AppUI.fieldLabel(photos[i].label, required: photos[i].required),
                _photo(photos[i]),
              ],
            ]),
          );

      // The room left of the photo. On a very narrow form the photo goes
      // above the fields instead, still on the right.
      final besideWidth = c.maxWidth - _photoWidth - gap;
      final children = <Widget>[];
      if (groups.isEmpty && photos.isNotEmpty) {
        children.add(Align(alignment: Alignment.centerRight, child: photoColumn()));
      }
      for (var i = 0; i < groups.length; i++) {
        final (heading, fields) = groups[i];
        final withPhoto = i == 0 && photos.isNotEmpty;
        if (heading == null && fields.isEmpty && !withPhoto) continue;
        if (children.isNotEmpty) children.add(SizedBox(height: 16.h));
        if (heading != null) children.add(AppUI.sectionLabel(heading));
        if (withPhoto && besideWidth >= 320) {
          children.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: fieldsIn(fields, besideWidth, oneColumnBelow: 400)),
            SizedBox(width: gap),
            photoColumn(),
          ]));
        } else if (withPhoto) {
          children.add(Align(alignment: Alignment.centerRight, child: photoColumn()));
          if (fields.isNotEmpty) children.addAll([SizedBox(height: 12.h), fieldsIn(fields, c.maxWidth)]);
        } else if (fields.isNotEmpty) {
          children.add(fieldsIn(fields, c.maxWidth));
        }
      }
      return FocusTraversalGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
      );
    });
  }
}

/// Add or edit one record in a dialog. Returns what it did ([TrEdit]), or
/// null if the user cancelled. [fixed] goes with the row without being shown
/// (e.g. the route a stop belongs to). With [delete], editing an existing
/// record also offers Delete, which asks [delete]'s question first.
Future<TrEdit?> showTrFormDialog(
  BuildContext context, {
  required String entity,
  required String pk,
  required String title,
  required String icon,
  required List<TrField> fields,
  Map<String, dynamic> initial = const {},
  Map<String, dynamic> fixed = const {},
  TrDelete? delete,
  TrSource? source,
}) {
  return showDialog<TrEdit>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TrFormDialog(
        source: source ?? TrSource.transport(entity), pk: pk, title: title, icon: icon, fields: fields, initial: initial, fixed: fixed, delete: delete),
  );
}

class _TrFormDialog extends StatefulWidget {
  final TrSource source;
  final String pk, title, icon;
  final List<TrField> fields;
  final Map<String, dynamic> initial, fixed;
  final TrDelete? delete;
  const _TrFormDialog({
    required this.source,
    required this.pk,
    required this.title,
    required this.icon,
    required this.fields,
    required this.initial,
    required this.fixed,
    this.delete,
  });

  @override
  State<_TrFormDialog> createState() => _TrFormDialogState();
}

class _TrFormDialogState extends State<_TrFormDialog> {
  final _form = GlobalKey<TrFormBodyState>();
  bool _saving = false, _deleting = false;

  int? get _id => trId(widget.initial[widget.pk]);

  Future<void> _save() async {
    final row = _form.currentState?.collect();
    if (row == null) return;
    final id = _id;
    setState(() => _saving = true);
    try {
      final saved = await widget.source.save({...row, ...widget.fixed, if (id != null) widget.pk: id}) ?? id;
      if (mounted) Navigator.pop(context, saved == null ? null : TrEdit(saved));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  Future<void> _delete(int id) async {
    if (!await trAskDelete(context, widget.delete!) || !mounted) return;
    setState(() => _deleting = true);
    try {
      final what = await widget.source.remove(id);
      if (mounted) Navigator.pop(context, TrEdit(id, deleted: what));
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      trSnack(context, AppText.couldNot('delete', friendlyError(e)), AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(icon: widget.icon, title: widget.title),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(AppUI.cardPad),
              child: TrFormBody(key: _form, fields: widget.fields, initial: widget.initial, enabled: !_saving && !_deleting),
            ),
          ),
          trFormFooter(
            context,
            saving: _saving,
            deleting: _deleting,
            onSave: _save,
            onDelete: widget.delete != null && _id != null ? () => _delete(_id!) : null,
          ),
        ]),
      ),
    );
  }
}

/// The transport screens' search box. AppSearchField's shrink-to-fit hint
/// fails layout here and leaves the whole page blank, so this uses a plain hint.
class TrSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const TrSearchField({super.key, required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) => TextField(
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', leadingIcon: 'search-normal').copyWith(hintText: hint),
        onChanged: onChanged,
      );
}

// ── table ────────────────────────────────────────────────────────────────────
class TrColumn {
  final String label;
  final int flex;
  final String Function(Map<String, dynamic> row)? text;

  /// A custom cell, such as a status stamp, instead of [text].
  final Widget Function(Map<String, dynamic> row)? cell;
  /// A right-aligned [mono] column is an amount, in the money style; any other
  /// column (codes, mobiles, numbers) is in the table font, as on the other modules.
  final bool mono;
  final TextAlign align;
  const TrColumn(this.label, {this.flex = 2, this.text, this.cell, this.mono = false, this.align = TextAlign.left});
}

class TrRowAction {
  final String icon;
  final String tooltip;
  final void Function(Map<String, dynamic> row) onTap;
  const TrRowAction({required this.icon, required this.tooltip, required this.onTap});
}

/// A searchable table of one entity, with add and edit. Delete is in the
/// edit dialog, not on the rows.
class TrPanel extends StatefulWidget {
  final String entity, pk;
  final String title, icon, noun;
  final String? subtitle;
  final Map<String, dynamic> filter;

  /// Sent with every save, not shown on the form.
  final Map<String, dynamic> fixed;
  final List<TrColumn> columns;
  final List<TrField> Function(List<Map<String, dynamic>> rows) fields;

  /// The starting values of a new record.
  final Map<String, dynamic> Function(List<Map<String, dynamic>> rows)? newValues;
  final String Function(Map<String, dynamic> row) searchText;
  final List<TrRowAction> rowActions;

  /// Explains Delete in the edit dialog, e.g. that a route is only switched off.
  final String deleteNote;
  final String emptyWhy;

  /// Add is off, with this reason, until something else exists first.
  final String? addBlockedReason;
  final VoidCallback? onChanged;

  /// Opens the screen's own add / edit dialog instead of the [fields] form
  /// (row is null for a new record), e.g. for a record saved together with
  /// its child rows; that dialog offers Delete itself. Returns what it did,
  /// or null when the user cancelled.
  final Future<TrEdit?> Function(Map<String, dynamic>? row, List<Map<String, dynamic>> rows)? editor;

  /// Where the records come from; the transport functions for [entity] when null.
  final TrSource? source;

  const TrPanel({
    super.key,
    required this.entity,
    required this.pk,
    required this.title,
    required this.icon,
    required this.noun,
    this.subtitle,
    this.filter = const {},
    this.fixed = const {},
    required this.columns,
    required this.fields,
    this.newValues,
    required this.searchText,
    this.rowActions = const [],
    this.deleteNote = '',
    this.emptyWhy = '',
    this.addBlockedReason,
    this.onChanged,
    this.editor,
    this.source,
  });

  @override
  State<TrPanel> createState() => _TrPanelState();
}

class _TrPanelState extends State<TrPanel> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await (widget.source ?? TrSource.transport(widget.entity)).list(widget.filter);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _edit(Map<String, dynamic>? row) async {
    final editor = widget.editor;
    final TrEdit? done;
    if (editor != null) {
      done = await editor(row, _rows);
    } else {
      done = await showTrFormDialog(
        context,
        entity: widget.entity,
        pk: widget.pk,
        icon: widget.icon,
        title: row == null ? 'Add ${widget.noun}' : 'Edit ${widget.noun}',
        fields: widget.fields(_rows),
        initial: row ?? widget.newValues?.call(_rows) ?? const {},
        fixed: widget.fixed,
        source: widget.source,
        delete: TrDelete('Delete this ${widget.noun}?', widget.deleteNote.isEmpty ? 'This cannot be undone.' : widget.deleteNote),
      );
    }
    if (done == null || !mounted) return;
    trSnack(context, done.message, AppColors.success);
    await _load();
    widget.onChanged?.call();
  }

  Widget _iconButton(String icon, String tip, VoidCallback onTap, {Color color = AppColors.ink2}) => IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        onPressed: onTap,
        icon: AppIcon(icon, size: 16, color: color),
      );

  double get _actionsWidth => 34.0 * (1 + widget.rowActions.length) + 8;

  Widget _table(List<Map<String, dynamic>> rows) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 44.h,
        padding: EdgeInsets.symmetric(horizontal: 12.w),
        decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
        child: Row(children: [
          for (final col in widget.columns)
            Expanded(
              flex: col.flex,
              child: Padding(
                padding: EdgeInsets.only(right: 8.w),
                child: Text(col.label.toUpperCase(), textAlign: col.align, style: AppUI.tableHead),
              ),
            ),
          SizedBox(width: _actionsWidth),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final r = rows[i];
            return Container(
              constraints: BoxConstraints(minHeight: 36.h),
              padding: EdgeInsets.symmetric(horizontal: 12.w),
              decoration: BoxDecoration(color: i.isEven ? Colors.white : AppColors.surface, border: const Border(bottom: BorderSide(color: AppColors.divider))),
              child: Row(children: [
                for (final col in widget.columns)
                  Expanded(
                    flex: col.flex,
                    child: Padding(
                      padding: EdgeInsets.only(right: 8.w),
                      child: col.cell != null
                          ? Align(alignment: Alignment.centerLeft, child: col.cell!(r))
                          : Text(col.text?.call(r) ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: col.align,
                              style: col.mono && col.align == TextAlign.right ? AppUI.money : AppUI.cell),
                    ),
                  ),
                SizedBox(
                  width: _actionsWidth,
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    for (final a in widget.rowActions) _iconButton(a.icon, a.tooltip, () => a.onTap(r)),
                    _iconButton('edit-2', 'Edit', () => _edit(r), color: AppColors.primary),
                  ]),
                ),
              ]),
            );
          },
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final rows = q.isEmpty ? _rows : [for (final r in _rows) if (widget.searchText(r).toLowerCase().contains(q)) r];
    final blocked = widget.addBlockedReason;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppUI.cardHeader(
        icon: widget.icon,
        title: widget.title,
        subtitle: blocked ?? widget.subtitle,
        trailing: [
          SizedBox(
            width: 220.w,
            child: TrSearchField(hint: AppText.search, onChanged: (v) => setState(() => _query = v)),
          ),
          ElevatedButton.icon(
            onPressed: blocked != null || _loading || _error != null ? null : () => _edit(null),
            style: AppUI.primary(context),
            icon: AppIcon('add-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
            label: Text('Add ${widget.noun}'),
          ),
        ],
      ),
      SizedBox(height: 14.h),
      Expanded(
        child: Container(
          decoration: AppUI.card(),
          clipBehavior: Clip.antiAlias,
          child: _loading
              ? const AppLoading()
              : _error != null
                  ? AppUI.empty(
                      title: 'Could not load this list',
                      why: _error,
                      icon: 'info-circle',
                      action: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });
                          _load();
                        },
                        style: AppUI.secondary(context),
                        child: const Text('Retry'),
                      ),
                    )
                  : rows.isEmpty
                      ? AppUI.empty(
                          title: _rows.isEmpty ? 'Nothing added yet' : 'No match for your search',
                          why: _rows.isEmpty ? widget.emptyWhy : 'Try a different word.',
                          icon: widget.icon,
                        )
                      : _table(rows),
        ),
      ),
    ]);
  }
}

/// ACTIVE / INACTIVE stamp for an is_active column.
Widget trActiveChip(Map<String, dynamic> row) =>
    row['is_active'] == false ? AppUI.chip('Inactive', AppStatus.neutral) : AppUI.chip('Active', AppStatus.success);

/// A document list (vehicle or staff) in its own dialog.
Future<void> showTrPanelDialog(BuildContext context, TrPanel panel) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 620),
        child: Padding(
          padding: EdgeInsets.all(AppUI.cardPad),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: panel),
            SizedBox(height: 12.h),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppText.close)),
            ),
          ]),
        ),
      ),
    ),
  );
}
