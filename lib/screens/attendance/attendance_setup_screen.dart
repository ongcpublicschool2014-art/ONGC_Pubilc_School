import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/attendance_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_search_pick.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/pill_tab.dart';
import 'attendance_common.dart';

/// ATTENDANCE SETUP (school_attendance_api.sql, 'Attendance Setup' menu):
///   Year & Terms       the school's streams (CBSE / State Board ...) with
///                      this year's dates, and each stream's terms
///   Attendance Staff   the staff who take attendance this year (<year>.att_staff,
///                      each one of Staff Details' list) with their roles --
///                      principal, division in-charge (the second leave
///                      approval), teacher (user 2026-11-24: "bring attendance
///                      staff roles into this"); the teacher pickers offer only them
///   Sections           which sections take attendance: stream, class
///                      teacher (class in-charge), room
///   Calendar           holidays, half days, weekly offs (a Sunday with no
///                      entry is a weekly off; any other day works)
///   Who Marks          the first-hour teacher of FN / AN for each weekday
///   Settings           the school's rules. The marks are fixed: P, A, L, OD, LT
///                      (the Status Codes card was removed, user 2026-11-24)
class AttendanceSetupScreen extends StatefulWidget {
  const AttendanceSetupScreen({super.key});

  static const tabLabels = ['Year & Terms', 'Attendance Staff', 'Sections', 'Calendar', 'Who Marks', 'Settings'];
  static const _icons = ['calendar-1', 'people', 'teacher', 'calendar-2', 'user-tick', 'setting-2'];

  @override
  State<AttendanceSetupScreen> createState() => _AttendanceSetupScreenState();
}

class _AttendanceSetupScreenState extends State<AttendanceSetupScreen> {
  int _tab = 0;
  Map<String, dynamic>? _l;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await AttendanceService.lookups();
      if (mounted) {
        setState(() {
          _l = l;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Wrap(spacing: PillTab.gap(context), runSpacing: 8, children: [
          for (var i = 0; i < AttendanceSetupScreen.tabLabels.length; i++)
            PillTab(
              key: ValueKey('att-setup-tab-$i'),
              icon: AttendanceSetupScreen._icons[i],
              label: AttendanceSetupScreen.tabLabels[i],
              selected: _tab == i,
              onTap: () => setState(() => _tab = i),
            ),
        ]),
      ),
      SizedBox(height: 6.h),
      Expanded(
        child: _error != null
            ? Container(decoration: AppUI.card(), child: AppUI.empty(title: 'Could not load Attendance Setup', why: _error, icon: 'warning-2'))
            : l == null
                ? Container(decoration: AppUI.card(), child: const AppLoading())
                : switch (_tab) {
                    0 => _YearTermsTab(l: l, reload: _load),
                    1 => _AttStaffTab(l: l, reload: _load),
                    2 => _SectionsTab(key: ValueKey('sec-${l.hashCode}'), l: l, reload: _load),
                    3 => _CalendarTab(l: l, reload: _load),
                    4 => _WhoMarksTab(key: ValueKey('who-${l.hashCode}'), l: l, reload: _load),
                    _ => _StatusSettingsTab(key: ValueKey('set-${l.hashCode}'), l: l, reload: _load),
                  },
      ),
    ]);
  }
}

List<Map<String, dynamic>> _list(Map<String, dynamic> l, String k) => [
      for (final x in (l[k] as List? ?? const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];

/// The active attendance staff for the teacher pickers (class teacher, Who
/// Marks, Staff Roles): name, with the employee code and designation (both
/// searched too). The value is the staff member's staf_id.
List<AppSearchPickItem<num>> _staffPicks(Map<String, dynamic> l) => [
      for (final s in _list(l, 'att_staff'))
        if (s['staf_id'] is num && s['is_active'] != false)
          AppSearchPickItem<num>(s['staf_id'] as num, attText(s['full_name']),
              detail: [attText(s['emp_code']), attText(s['designation'])].where((x) => x.isNotEmpty).join(' · ')),
    ];

const _kNoAttStaff = 'No attendance staff yet (Attendance Staff tab)';

/// The streams that have this year's dates (academic_year_id).
List<Map<String, dynamic>> _streamYears(Map<String, dynamic> l) => [
      for (final s in _list(l, 'streams'))
        if (attIntOrNull(s['academic_year_id']) != null) s
    ];

Widget _dialogField(String label, Widget field, {bool required = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [AppUI.fieldLabel(label, required: required), field]),
    );

Widget _drop<T>(BuildContext context,
        {required T? value, required List<(T, String)> items, required ValueChanged<T?> onChanged, String hint = 'Select', Key? key}) =>
    AppDropdownField<T>(
      key: key,
      initialValue: items.any((i) => i.$1 == value) ? value : null,
      isExpanded: true,
      decoration: AppUI.field(context, hint, filled: value != null, dense: true),
      style: AppUI.fieldText(context),
      items: [for (final i in items) DropdownMenuItem(value: i.$1, child: Text(i.$2, overflow: TextOverflow.ellipsis))],
      onChanged: onChanged,
    );

// ── Year & Terms ─────────────────────────────────────────────────────────────
class _YearTermsTab extends StatefulWidget {
  final Map<String, dynamic> l;
  final Future<void> Function() reload;
  const _YearTermsTab({required this.l, required this.reload});

  @override
  State<_YearTermsTab> createState() => _YearTermsTabState();
}

class _YearTermsTabState extends State<_YearTermsTab> {
  int? _stream;

  List<Map<String, dynamic>> get _streams => _list(widget.l, 'streams');

  Map<String, dynamic>? get _current {
    for (final s in _streams) {
      if (attInt(s['stream_id']) == _stream) return s;
    }
    return _streams.isEmpty ? null : _streams.first;
  }

  Future<void> _editStream([Map<String, dynamic>? s]) async {
    final year = widget.l['year'] is Map ? Map<String, dynamic>.from(widget.l['year'] as Map) : const <String, dynamic>{};
    final code = TextEditingController(text: attText(s?['stream_code']));
    final name = TextEditingController(text: attText(s?['stream_name']));
    DateTime? from = attParse(s?['start_date']) ?? attParse(year['start']);
    DateTime? to = attParse(s?['end_date']) ?? attParse(year['end']);
    var status = attText(s?['status']).isEmpty ? 'OPEN' : attText(s?['status']);
    var active = s?['is_active'] != false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(s == null ? 'Add Stream' : 'Edit Stream'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('A board the school teaches (CBSE, State Board, Matric ...) and this year\'s dates for it.', style: AppUI.muted),
                const SizedBox(height: 12),
                _dialogField(
                    'Code',
                    TextField(
                        key: const ValueKey('stream-code'),
                        controller: code,
                        maxLength: 20,
                        style: AppUI.fieldText(ctx),
                        textCapitalization: TextCapitalization.characters,
                        decoration: AppUI.field(ctx, 'e.g. CBSE').copyWith(counterText: '')),
                    required: true),
                _dialogField(
                    'Name',
                    TextField(
                        key: const ValueKey('stream-name'),
                        controller: name,
                        maxLength: 100,
                        style: AppUI.fieldText(ctx),
                        decoration: AppUI.field(ctx, 'e.g. CBSE').copyWith(counterText: '')),
                    required: true),
                Row(children: [
                  Expanded(child: _dialogField('Year starts', AttDateField(value: from, onPicked: (d) => set(() => from = d)), required: true)),
                  const SizedBox(width: 12),
                  Expanded(child: _dialogField('Year ends', AttDateField(value: to, onPicked: (d) => set(() => to = d)), required: true)),
                ]),
                _dialogField(
                    'Year status',
                    _drop<String>(ctx,
                        value: status,
                        items: const [('OPEN', 'Open'), ('PLANNED', 'Planned'), ('CLOSED', 'Closed')],
                        onChanged: (v) => set(() => status = v ?? 'OPEN'))),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: active,
                  onChanged: (v) => set(() => active = v),
                  title: Text('Active', style: AppUI.body),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
            ElevatedButton(style: AppUI.primary(ctx), onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await AttendanceService.saveStream({
        if (s != null) 'stream_id': attInt(s['stream_id']),
        'stream_code': code.text.trim(),
        'stream_name': name.text.trim(),
        'start_date': from == null ? null : AttendanceService.day(from!),
        'end_date': to == null ? null : AttendanceService.day(to!),
        'status': status,
        'is_active': active,
      });
      if (!mounted) return;
      attSnack(context, 'Stream saved.');
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  /// The term is picked from the Term master (Fee Master -> Term,
  /// <year>.semester; user 2026-11-24: "term drop down from term table"); its
  /// dates fill From / To and can be changed for this stream.
  Future<void> _editTerm(Map<String, dynamic> stream, [Map<String, dynamic>? t]) async {
    final used = {
      for (final x in _list(widget.l, 'terms'))
        if (attInt(x['academic_year_id']) == attInt(stream['academic_year_id']) && attInt(x['term_id']) != attInt(t?['term_id'])) attIntOrNull(x['sem_id']),
    };
    final masters = [
      for (final m in _list(widget.l, 'semesters'))
        if (!used.contains(attInt(m['sem_id']))) m
    ];
    int? sem = attIntOrNull(t?['sem_id']);
    final days = TextEditingController(text: attText(t?['planned_working_days']));
    DateTime? from = attParse(t?['start_date']);
    DateTime? to = attParse(t?['end_date']);
    final first = attParse(stream['start_date']);
    final last = attParse(stream['end_date']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(t == null ? 'Add Term' : 'Edit Term'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              _dialogField(
                  'Term',
                  masters.isEmpty && sem == null
                      ? Text('No term left to add. Terms are made in Fee Master -> Term.', style: AppUI.muted)
                      : _drop<int>(ctx,
                          key: const ValueKey('term-pick'),
                          value: sem,
                          hint: 'Select term',
                          items: [
                            for (final m in masters) (attInt(m['sem_id']), attText(m['semname'])),
                            // a term saved before the master changed still shows
                            if (sem != null && !masters.any((m) => attInt(m['sem_id']) == sem)) (sem!, attText(t?['term_name'])),
                          ],
                          onChanged: (v) => set(() {
                                sem = v;
                                final m = masters.where((m) => attInt(m['sem_id']) == v).firstOrNull;
                                from = attParse(m?['semstart']) ?? from;
                                to = attParse(m?['semend']) ?? to;
                              })),
                  required: true),
              Row(children: [
                Expanded(
                    child: _dialogField('From', AttDateField(value: from, first: first, last: last, onPicked: (d) => set(() => from = d)), required: true)),
                const SizedBox(width: 12),
                Expanded(child: _dialogField('To', AttDateField(value: to, first: first, last: last, onPicked: (d) => set(() => to = d)), required: true)),
              ]),
              _dialogField(
                  'Planned working days (as published)',
                  TextField(
                      controller: days,
                      style: AppUI.fieldText(ctx),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: AppUI.field(ctx, 'Optional'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
            ElevatedButton(
                key: const ValueKey('term-save'),
                style: AppUI.primary(ctx),
                onPressed: sem == null ? null : () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await AttendanceService.saveTerm({
        if (t != null) 'term_id': attInt(t['term_id']),
        'academic_year_id': attInt(stream['academic_year_id']),
        'sem_id': sem,
        'start_date': from == null ? null : AttendanceService.day(from!),
        'end_date': to == null ? null : AttendanceService.day(to!),
        'planned_working_days': days.text.trim(),
      });
      if (!mounted) return;
      attSnack(context, 'Term saved.');
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  Future<void> _deleteTerm(Map<String, dynamic> t) async {
    if (!await confirmAtt(context, title: 'Remove ${attText(t['term_name'])}?', message: 'The term is removed from this stream.', ok: 'Remove', danger: true)) {
      return;
    }
    try {
      await AttendanceService.deleteTerm(attInt(t['term_id']));
      if (!mounted) return;
      attSnack(context, 'Term removed.');
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final terms = cur == null
        ? const <Map<String, dynamic>>[]
        : [
            for (final t in _list(widget.l, 'terms'))
              if (attInt(t['academic_year_id']) == attInt(cur['academic_year_id'])) t
          ];
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        flex: 5,
        child: AttCard(
          icon: 'book-1',
          title: 'Streams',
          subtitle: 'Boards and this year\'s dates for each',
          trailing: [
            ElevatedButton.icon(
              key: const ValueKey('att-add-stream'),
              style: AppUI.primary(context),
              onPressed: () => _editStream(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Stream'),
            ),
          ],
          child: _streams.isEmpty
              ? AppUI.empty(title: 'No streams yet', why: 'Add the board the school teaches (e.g. CBSE) with this year\'s start and end dates.', icon: 'book-1')
              : ListView(children: [
                  attHeadRow([
                    AppUI.th('Code', flex: 2),
                    AppUI.th('Name', flex: 3),
                    AppUI.th('This year', flex: 4),
                    AppUI.th('Status', flex: 2),
                    const SizedBox(width: 40)
                  ]),
                  for (final s in _streams)
                    InkWell(
                      onTap: () => setState(() => _stream = attInt(s['stream_id'])),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                        color: identical(s, cur) || attInt(s['stream_id']) == attInt(cur?['stream_id']) ? AppColors.primarySoft : Colors.white,
                        child: Row(children: [
                          Expanded(flex: 2, child: Text(attText(s['stream_code']), style: AppUI.label)),
                          Expanded(flex: 3, child: Text(attText(s['stream_name']), style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                          Expanded(
                              flex: 4,
                              child: Text(
                                  attIntOrNull(s['academic_year_id']) == null ? 'Dates not set' : '${attShow(s['start_date'])} to ${attShow(s['end_date'])}',
                                  style: AppUI.cell)),
                          Expanded(
                              flex: 2,
                              child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: AppUI.chip(s['is_active'] == false ? 'Inactive' : (attText(s['status']).isEmpty ? '-' : attText(s['status'])),
                                      s['is_active'] == false ? AppStatus.neutral : AppStatus.success))),
                          SizedBox(
                            width: 40,
                            child: IconButton(tooltip: 'Edit', onPressed: () => _editStream(s), icon: const Icon(Icons.edit_outlined, size: 18)),
                          ),
                        ]),
                      ),
                    ),
                ]),
        ),
      ),
      SizedBox(width: AppUI.gap),
      Expanded(
        flex: 6,
        child: AttCard(
          icon: 'calendar-1',
          title: cur == null ? 'Terms' : 'Terms of ${attText(cur['stream_code'])}',
          subtitle: "Picked from Fee Master -> Term, with this stream's dates -- every date that takes attendance is inside a term",
          trailing: [
            if (cur != null && attIntOrNull(cur['academic_year_id']) != null)
              ElevatedButton.icon(
                key: const ValueKey('att-add-term'),
                style: AppUI.primary(context),
                onPressed: () => _editTerm(cur),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Term'),
              ),
          ],
          child: cur == null
              ? AppUI.empty(title: 'Add a stream first', icon: 'calendar-1')
              : terms.isEmpty
                  ? AppUI.empty(title: 'No terms yet', why: 'Add the terms of this stream\'s year.', icon: 'calendar-1')
                  : ListView(children: [
                      attHeadRow([
                        AppUI.th('No.'),
                        AppUI.th('Term', flex: 3),
                        AppUI.th('From', flex: 2),
                        AppUI.th('To', flex: 2),
                        AppUI.th('Planned days', flex: 2),
                        AppUI.th('Registers', flex: 2),
                        const SizedBox(width: 96),
                      ]),
                      for (final t in terms)
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                          child: Row(children: [
                            Expanded(child: Text('${attInt(t['term_seq'])}', style: AppUI.cell)),
                            Expanded(flex: 3, child: Text(attText(t['term_name']), style: AppUI.label)),
                            Expanded(flex: 2, child: Text(attShow(t['start_date']), style: AppUI.cell)),
                            Expanded(flex: 2, child: Text(attShow(t['end_date']), style: AppUI.cell)),
                            Expanded(
                                flex: 2, child: Text(attText(t['planned_working_days']).isEmpty ? '-' : attText(t['planned_working_days']), style: AppUI.cell)),
                            Expanded(flex: 2, child: Text('${attInt(t['sheets'])}', style: AppUI.cell)),
                            SizedBox(
                              width: 96,
                              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                IconButton(tooltip: 'Edit', onPressed: () => _editTerm(cur, t), icon: const Icon(Icons.edit_outlined, size: 18)),
                                if (attInt(t['sheets']) == 0)
                                  IconButton(
                                      tooltip: 'Remove',
                                      onPressed: () => _deleteTerm(t),
                                      icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.error)),
                              ]),
                            ),
                          ]),
                        ),
                    ]),
        ),
      ),
    ]);
  }
}

// ── Attendance Staff ─────────────────────────────────────────────────────────
/// The staff who take attendance this year (user, 2026-11-24: "this table is
/// missing ... single screen to add the attendance staff"): <year>.att_staff,
/// each one of Staff Details' year list. Code and name come from Staff
/// Details; mobile and e-mail default to it.
class _AttStaffTab extends StatefulWidget {
  final Map<String, dynamic> l;
  final Future<void> Function() reload;
  const _AttStaffTab({required this.l, required this.reload});

  @override
  State<_AttStaffTab> createState() => _AttStaffTabState();
}

class _AttStaffTabState extends State<_AttStaffTab> {
  num? _staf;
  int? _editId;
  bool _active = true;
  bool _saving = false;

  /// The staff member's roles: (role_code, div_id). [_role] / [_div] is the one
  /// being picked; Save includes it too.
  final List<(String, int?)> _roles = [];
  String? _role;
  int? _div;
  final _mobile = TextEditingController();
  final _email = TextEditingController();

  @override
  void dispose() {
    _mobile.dispose();
    _email.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _rows => _list(widget.l, 'att_staff');

  /// This year's staff not on the list yet.
  List<AppSearchPickItem<num>> get _candidates {
    final on = {for (final r in _rows) attIntOrNull(r['staf_id'])};
    return [
      for (final s in _list(widget.l, 'staff'))
        if (s['staf_id'] is num && !on.contains(attInt(s['staf_id'])))
          AppSearchPickItem<num>(s['staf_id'] as num, attText(s['stafname']),
              detail: [attText(s['emp_code']), attText(s['designation'])].where((x) => x.isNotEmpty).join(' · ')),
    ];
  }

  Map<String, dynamic>? get _editing => _rows.where((r) => attInt(r['staff_id']) == _editId).firstOrNull;

  void _clear() {
    _editId = null;
    _staf = null;
    _active = true;
    _mobile.clear();
    _email.clear();
    _roles.clear();
    _role = null;
    _div = null;
  }

  void _edit(Map<String, dynamic> r) => setState(() {
        _clear();
        _editId = attInt(r['staff_id']);
        _staf = r['staf_id'] as num?;
        _active = r['is_active'] != false;
        _mobile.text = attText(r['mobile_no']);
        _email.text = attText(r['email']);
        for (final x in (r['roles'] as List? ?? const [])) {
          if (x is Map) _roles.add((attText(x['role_code']), attIntOrNull(x['div_id'])));
        }
      });

  String _divName(int? id) {
    if (id == null) return 'All divisions';
    for (final d in _list(widget.l, 'divisions')) {
      if (attInt(d['div_id']) == id) return attText(d['divname']);
    }
    return '';
  }

  String _roleText((String, int?) r) =>
      '${_kRoles[r.$1] ?? r.$1}${r.$2 == null ? '' : ' (${_divName(r.$2)})'}';

  /// The role being picked is complete (a division in-charge has a division).
  bool get _pickedOk => _role != null && (_role != 'DIVISION_INCHARGE' || _div != null);

  void _addPicked() {
    if (!_pickedOk) return;
    final r = (_role!, _div);
    if (!_roles.contains(r)) _roles.add(r);
    _role = null;
    _div = null;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _addPicked();
      await AttendanceService.saveAttStaff({
        if (_editId != null) 'staff_id': _editId else 'staf_id': _staf,
        'mobile_no': _mobile.text.trim(),
        'email': _email.text.trim(),
        if (_editId != null) 'is_active': _active,
        'roles': [for (final r in _roles) {'role_code': r.$1, 'div_id': r.$2}],
      });
      if (!mounted) return;
      attSnack(context, _editId == null ? 'Added to the attendance staff.' : 'Saved.');
      setState(_clear);
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addAll() async {
    try {
      final n = await AttendanceService.addAllAttStaff();
      if (!mounted) return;
      attSnack(context, n == 0 ? 'Everyone on this year\'s staff is already here.' : '$n added.');
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  Future<void> _remove(Map<String, dynamic> r) async {
    if (!await confirmAtt(context,
        title: 'Remove ${attText(r['full_name'])}?', message: 'They are taken off the attendance staff. Staff Details is not changed.', ok: 'Remove', danger: true)) {
      return;
    }
    try {
      await AttendanceService.deleteAttStaff(attInt(r['staff_id']));
      if (!mounted) return;
      if (_editId == attInt(r['staff_id'])) setState(_clear);
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  /// "Class teacher of 4 · Who Marks 6"
  static String _uses(Map<String, dynamic> r) => [
        if (attInt(r['class_teacher_of']) > 0) 'Class teacher of ${attInt(r['class_teacher_of'])}',
        if (attInt(r['marks_sessions']) > 0) 'Who Marks ${attInt(r['marks_sessions'])}',
      ].join(' · ');

  /// "Division in-charge (PRIMARY), Teacher"
  String _rolesOf(Map<String, dynamic> r) => [
        for (final x in (r['roles'] as List? ?? const []))
          if (x is Map) _roleText((attText(x['role_code']), attIntOrNull(x['div_id']))),
      ].join(', ');

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final candidates = _candidates;
    final editing = _editing;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 380.w,
        child: AttCard(
          icon: _editId == null ? 'profile-add' : 'user-edit',
          title: _editId == null ? 'Add Attendance Staff' : 'Edit Attendance Staff',
          subtitle: 'From this year\'s staff (Staff Details)',
          padding: EdgeInsets.all(AppUI.cardPad),
          // the fields scroll; Cancel / Save stay at the bottom of the card
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _dialogField(
                  'Staff',
                  editing != null
                      ? Text('${attText(editing['full_name'])} (${attText(editing['emp_code'])})', style: AppUI.label)
                      : AppSearchPickField<num>(
                          key: const ValueKey('attstaff-staff'),
                          value: _staf,
                          items: candidates,
                          hint: candidates.isEmpty ? 'Everyone is already added' : 'Search staff',
                          title: 'Staff',
                          dense: false,
                          // mobile and e-mail as Staff Details has them (user, 2026-11-24)
                          onChanged: (v) => setState(() {
                                _staf = v;
                                final st = _list(widget.l, 'staff').where((x) => attIntOrNull(x['staf_id']) == attIntOrNull(v)).firstOrNull;
                                _mobile.text = attText(st?['mobile_no']);
                                _email.text = attText(st?['email']);
                              })),
                  required: true),
              _dialogField(
                  'Mobile',
                  TextField(
                    key: const ValueKey('attstaff-mobile'),
                    controller: _mobile,
                    maxLength: 10,
                    style: AppUI.fieldText(context),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: AppUI.field(context, '10 digits (from Staff Details)').copyWith(counterText: ''),
                  )),
              _dialogField(
                  'E-mail',
                  TextField(
                    controller: _email,
                    maxLength: 120,
                    style: AppUI.fieldText(context),
                    decoration: AppUI.field(context, 'From Staff Details').copyWith(counterText: ''),
                  )),
              AppUI.fieldLabel('Roles'),
              if (_roles.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final r in _roles)
                      InputChip(
                        key: ValueKey('attstaff-role-${r.$1}-${r.$2}'),
                        label: Text(_roleText(r)),
                        onDeleted: () => setState(() => _roles.remove(r)),
                      ),
                  ]),
                ),
              _drop<String>(context,
                  key: const ValueKey('attstaff-role'),
                  value: _role,
                  hint: _roles.isEmpty ? 'Select role (optional)' : 'Add another role',
                  items: [for (final e in _kRoles.entries) (e.key, e.value)],
                  onChanged: (v) => setState(() {
                        _role = v;
                        final divs = _list(widget.l, 'divisions');
                        if (v == 'DIVISION_INCHARGE' && _div == null && divs.length == 1) _div = attInt(divs.first['div_id']);
                      })),
              if (_role != null) ...[
                const SizedBox(height: 8),
                _drop<int?>(context,
                    key: const ValueKey('attstaff-division'),
                    value: _div,
                    hint: 'Select division',
                    items: [
                      if (_role != 'DIVISION_INCHARGE') (null, 'All divisions'),
                      for (final d in _list(widget.l, 'divisions')) (attInt(d['div_id']), attText(d['divname'])),
                    ],
                    onChanged: (v) => setState(() => _div = v)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('attstaff-add-role'),
                    onPressed: _pickedOk ? () => setState(_addPicked) : null,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Role'),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text('A division in-charge gives the second approval of a leave for the students of that division.', style: AppUI.muted),
              ),
              if (_editId != null)
                SwitchListTile(
                  key: const ValueKey('attstaff-active'),
                  contentPadding: EdgeInsets.zero,
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                  title: Text('Active', style: AppUI.body),
                  subtitle: Text('Only active attendance staff can be picked as class teacher or in Who Marks, or give leave approvals.', style: AppUI.muted),
                ),
            ]),
              ),
            ),
            SizedBox(height: 12.h),
              Row(children: [
                if (_editId != null) ...[
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('attstaff-cancel'),
                      style: AppUI.secondary(context),
                      onPressed: _saving ? null : () => setState(_clear),
                      child: const Text(AppText.cancel),
                    ),
                  ),
                  SizedBox(width: 10.w),
                ],
                Expanded(
                  child: ElevatedButton.icon(
                    key: const ValueKey('attstaff-save'),
                    style: AppUI.primary(context),
                    onPressed: (_editId == null && _staf == null) || (_role != null && !_pickedOk) || _saving ? null : _save,
                    icon: Icon(_editId == null ? Icons.add : Icons.check, size: 16),
                    label: Text(_editId == null ? 'Add' : 'Save'),
                  ),
                ),
              ]),
          ]),
        ),
      ),
      SizedBox(width: AppUI.gap),
      Expanded(
        child: AttCard(
          icon: 'people',
          title: 'Attendance Staff',
          subtitle: '${rows.length} this year · the class teacher and Who Marks are picked from these',
          trailing: [
            OutlinedButton.icon(
              key: const ValueKey('attstaff-add-all'),
              style: AppUI.secondary(context),
              onPressed: candidates.isEmpty ? null : _addAll,
              icon: const Icon(Icons.group_add_outlined, size: 16),
              label: Text('Add All Staff (${candidates.length})'),
            ),
          ],
          child: rows.isEmpty
              ? AppUI.empty(title: 'No attendance staff yet', why: 'Add them one by one, or Add All Staff from this year\'s list.', icon: 'people')
              : ListView(children: [
                  attHeadRow([
                    AppUI.th('Code', flex: 2),
                    AppUI.th('Name', flex: 4),
                    AppUI.th('Mobile', flex: 2),
                    AppUI.th('Role', flex: 3),
                    AppUI.th('Used as', flex: 3),
                    AppUI.th('Status', flex: 2),
                    const SizedBox(width: 96),
                  ]),
                  for (final r in rows)
                    Container(
                      color: attInt(r['staff_id']) == _editId ? AppColors.goldSoft : null,
                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 5.h),
                      child: Row(children: [
                        Expanded(flex: 2, child: Text(attText(r['emp_code']), style: AppUI.mono)),
                        Expanded(
                          flex: 4,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(attText(r['full_name']), style: AppUI.label, overflow: TextOverflow.ellipsis),
                            if (attText(r['designation']).isNotEmpty) Text(attText(r['designation']), style: AppUI.muted),
                          ]),
                        ),
                        Expanded(flex: 2, child: Text(attText(r['mobile_no']).isEmpty ? '-' : attText(r['mobile_no']), style: AppUI.cell)),
                        Expanded(
                            flex: 3,
                            child: Text(_rolesOf(r).isEmpty ? '-' : _rolesOf(r), style: AppUI.cell, maxLines: 2, overflow: TextOverflow.ellipsis)),
                        Expanded(flex: 3, child: Text(_uses(r).isEmpty ? '-' : _uses(r), style: AppUI.muted, maxLines: 2, overflow: TextOverflow.ellipsis)),
                        Expanded(
                          flex: 2,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: AppUI.chip(r['is_active'] == false ? 'Inactive' : 'Active', r['is_active'] == false ? AppStatus.neutral : AppStatus.success),
                          ),
                        ),
                        SizedBox(
                          width: 96,
                          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            IconButton(
                                key: ValueKey('attstaff-edit-${attInt(r['staff_id'])}'),
                                tooltip: 'Edit',
                                onPressed: () => _edit(r),
                                icon: const Icon(Icons.edit_outlined, size: 18)),
                            IconButton(
                                key: ValueKey('attstaff-remove-${attInt(r['staff_id'])}'),
                                tooltip: 'Remove',
                                onPressed: () => _remove(r),
                                icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.error)),
                          ]),
                        ),
                      ]),
                    ),
                ]),
        ),
      ),
    ]);
  }
}

// ── Sections ─────────────────────────────────────────────────────────────────
class _SectionsTab extends StatefulWidget {
  final Map<String, dynamic> l;
  final Future<void> Function() reload;
  const _SectionsTab({super.key, required this.l, required this.reload});

  @override
  State<_SectionsTab> createState() => _SectionsTabState();
}

class _SectionsTabState extends State<_SectionsTab> {
  /// cla_id -> the row being edited.
  final Map<int, Map<String, dynamic>> _rows = {};
  final Map<int, TextEditingController> _rooms = {};
  final Set<int> _changed = {};
  bool _saving = false;
  int? _bulkYear;

  @override
  void initState() {
    super.initState();
    for (final s in _list(widget.l, 'sections')) {
      final id = attInt(s['cla_id']);
      _rows[id] = s;
      _rooms[id] = TextEditingController(text: attText(s['room_no']));
    }
  }

  @override
  void dispose() {
    for (final c in _rooms.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(int id, String k, Object? v) => setState(() {
        _rows[id]![k] = v;
        if (k == 'academic_year_id' && v != null && _rows[id]!['set_up'] != true) _rows[id]!['is_active'] = true;
        _changed.add(id);
      });

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await AttendanceService.saveSections([
        for (final id in _changed)
          {
            'cla_id': id,
            'academic_year_id': _rows[id]!['academic_year_id'],
            'class_teacher_staf_id': _rows[id]!['class_teacher_staf_id'],
            'room_no': _rooms[id]!.text.trim(),
            'is_active': _rows[id]!['is_active'] != false,
          },
      ]);
      if (!mounted) return;
      attSnack(context, 'Sections saved.');
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final years = _streamYears(widget.l);
    final staff = _staffPicks(widget.l);
    final yearItems = <(int?, String)>[(null, 'No attendance'), for (final y in years) (attInt(y['academic_year_id']), attText(y['stream_code']))];
    final staffPicks = _staffPicks(widget.l);
    final ids = _rows.keys.toList();
    return AttCard(
      icon: 'teacher',
      title: 'Sections',
      subtitle: 'The stream, class teacher (class in-charge) and room of each section this year',
      trailing: [
        if (years.isNotEmpty) ...[
          SizedBox(
            width: 170.w,
            child: _drop<int>(context,
                value: _bulkYear,
                hint: 'Stream for all',
                items: [for (final y in yearItems.skip(1)) (y.$1!, y.$2)],
                onChanged: (v) => setState(() => _bulkYear = v)),
          ),
          OutlinedButton(
            style: AppUI.secondary(context),
            onPressed: _bulkYear == null
                ? null
                : () {
                    for (final id in ids) {
                      if (_rows[id]!['set_up'] != true || attInt(_rows[id]!['sheets']) == 0) _set(id, 'academic_year_id', _bulkYear);
                    }
                  },
            child: const Text('Apply to All'),
          ),
        ],
        ElevatedButton(
          key: const ValueKey('att-sections-save'),
          style: AppUI.primary(context),
          onPressed: _changed.isEmpty || _saving ? null : _save,
          child: Text(_changed.isEmpty ? 'Saved' : 'Save (${_changed.length})'),
        ),
      ],
      child: years.isEmpty
          ? AppUI.empty(
              title: 'Add a stream first', why: 'Year & Terms: add the board with this year\'s dates, then pick it for each section here.', icon: 'teacher')
          : Column(children: [
              attHeadRow([
                AppUI.th('Section', flex: 2),
                AppUI.th('Standard', flex: 2),
                AppUI.th('Division', flex: 2),
                AppUI.th('Students', flex: 1),
                AppUI.th('Stream', flex: 3),
                AppUI.th('Class teacher', flex: 4),
                AppUI.th('Room', flex: 2),
                AppUI.th('Active', flex: 1),
              ]),
              Expanded(
                child: ListView.builder(
                  itemCount: ids.length,
                  itemBuilder: (_, i) {
                    final id = ids[i];
                    final r = _rows[id]!;
                    final on = attIntOrNull(r['academic_year_id']) != null;
                    return Container(
                      color: _changed.contains(id) ? AppColors.goldSoft : (i.isEven ? Colors.white : AppColors.surface),
                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                      child: Row(children: [
                        Expanded(flex: 2, child: Text(attText(r['claname']), style: AppUI.label)),
                        Expanded(flex: 2, child: Text(attText(r['courname']), style: AppUI.cell)),
                        Expanded(flex: 2, child: Text(attText(r['divname']).isEmpty ? '-' : attText(r['divname']), style: AppUI.cell)),
                        Expanded(flex: 1, child: Text('${attInt(r['strength'])}', style: AppUI.cell)),
                        Expanded(
                          flex: 3,
                          child: Padding(
                            padding: EdgeInsets.only(right: 8.w),
                            child: _drop<int?>(context,
                                key: ValueKey('sec-stream-$id'),
                                value: attIntOrNull(r['academic_year_id']),
                                items: yearItems,
                                onChanged: (v) => _set(id, 'academic_year_id', v)),
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Padding(
                            padding: EdgeInsets.only(right: 8.w),
                            child: AppSearchPickField<num>(
                                key: ValueKey('sec-teacher-$id'),
                                value: r['class_teacher_staf_id'] as num?,
                                items: staffPicks,
                                hint: staff.isEmpty ? _kNoAttStaff : 'Search teacher',
                                title: 'Class teacher of ${attText(r['claname'])}',
                                noneLabel: '-',
                                onChanged: (v) => _set(id, 'class_teacher_staf_id', v)),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Padding(
                            padding: EdgeInsets.only(right: 8.w),
                            child: TextField(
                              controller: _rooms[id],
                              enabled: on,
                              maxLength: 20,
                              style: AppUI.fieldText(context),
                              onChanged: (_) => setState(() => _changed.add(id)),
                              decoration: AppUI.field(context, '', dense: true).copyWith(counterText: ''),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Switch(value: on && r['is_active'] != false, onChanged: on ? (v) => _set(id, 'is_active', v) : null),
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ]),
    );
  }
}

// ── Calendar ─────────────────────────────────────────────────────────────────
class _CalendarTab extends StatefulWidget {
  final Map<String, dynamic> l;
  final Future<void> Function() reload;
  const _CalendarTab({required this.l, required this.reload});

  @override
  State<_CalendarTab> createState() => _CalendarTabState();
}

class _CalendarTabState extends State<_CalendarTab> {
  int? _ay;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _days = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final ys = _streamYears(widget.l);
    if (ys.isNotEmpty) {
      _ay = attInt(ys.first['academic_year_id']);
      final today = attParse(widget.l['today']) ?? DateTime.now();
      final s = attParse(ys.first['start_date']);
      final e = attParse(ys.first['end_date']);
      if (s != null && e != null && (today.isBefore(s) || today.isAfter(e))) _month = DateTime(s.year, s.month);
      _load();
    }
  }

  Map<String, dynamic>? get _year {
    for (final y in _streamYears(widget.l)) {
      if (attInt(y['academic_year_id']) == _ay) return y;
    }
    return null;
  }

  Future<void> _load() async {
    final ay = _ay;
    if (ay == null) return;
    setState(() => _loading = true);
    try {
      final d = await AttendanceService.calendar(ay);
      if (mounted) setState(() => _days = d);
    } catch (e) {
      if (mounted) attError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The stream-wide calendar row of a date, if any.
  Map<String, dynamic>? _row(DateTime d) {
    for (final r in _days) {
      if (attParse(r['cal_date']) == d && r['div_id'] == null) return r;
    }
    return null;
  }

  List<Map<String, dynamic>> _divRows(DateTime d) => [
        for (final r in _days)
          if (attParse(r['cal_date']) == d && r['div_id'] != null) r
      ];

  (String, Color) _look(DateTime d) {
    final r = _row(d);
    final type = r == null ? (d.weekday == 7 ? 'WEEKEND' : 'WORKING') : attText(r['day_type']);
    return (type, attDayColor(type));
  }

  /// "Half day (FN)" says which session works.
  static String _typeText(String type, Map<String, dynamic>? r) =>
      type == 'HALF_DAY' && r != null ? 'Half day (${r['fn_working'] == true ? 'FN' : 'AN'})' : (kAttDayTypes[type] ?? type);

  /// The kinds of day, each in its own colour (the one picked filled).
  static const _kinds = ['HOLIDAY', 'HALF_DAY', 'EXAM', 'EVENT', 'WEEKEND', 'WORKING'];

  Widget _kindChips(String value, ValueChanged<String> onPick) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final k in _kinds)
          InkWell(
            key: ValueKey('cal-kind-$k'),
            borderRadius: BorderRadius.circular(20),
            onTap: () => onPick(k),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: value == k ? attDayColor(k) : attDayColor(k).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: attDayColor(k).withValues(alpha: value == k ? 1 : 0.45)),
              ),
              child:
                  Text(kAttDayTypes[k] ?? k, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: value == k ? Colors.white : attDayColor(k))),
            ),
          ),
      ]);

  /// The colour key above the calendar.
  Widget _legend() => Wrap(spacing: 14.w, runSpacing: 6.h, children: [
        for (final k in _kinds)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: k == 'WORKING' ? Colors.white : attDayColor(k).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: k == 'WORKING' ? AppColors.line : attDayColor(k)),
              ),
            ),
            const SizedBox(width: 5),
            Text(kAttDayTypes[k] ?? k, style: AppUI.muted),
          ]),
      ]);

  /// [row]: a calendar entry picked in the list (a division's own too);
  /// else the date's stream-wide entry, if any.
  Future<void> _editDay(DateTime d, {Map<String, dynamic>? row}) async {
    final y = _year;
    if (y == null) return;
    final existing = row ?? _row(d);
    var type = existing == null ? 'HOLIDAY' : attText(existing['day_type']);
    var half = existing != null && existing['an_working'] == true && existing['fn_working'] != true ? 'AN' : 'FN';
    DateTime? to = d;
    int? div = attIntOrNull(existing?['div_id']);
    final remarks = TextEditingController(text: attText(existing?['remarks']));
    final divisions = _list(widget.l, 'divisions');
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(attDayLabel(d)),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              _dialogField('This day is', _kindChips(type, (k) => set(() => type = k))),
              if (type == 'HALF_DAY')
                _dialogField(
                    'The session that works',
                    _drop<String>(ctx,
                        value: half, items: const [('FN', 'FN (forenoon)'), ('AN', 'AN (afternoon)')], onChanged: (v) => set(() => half = v ?? 'FN'))),
              _dialogField(
                  'Till (for more than one day)', AttDateField(value: to, first: d, last: attParse(y['end_date']), onPicked: (v) => set(() => to = v))),
              if (divisions.isNotEmpty)
                _dialogField(
                    'Only for a division',
                    _drop<int?>(ctx,
                        value: div,
                        items: [
                          (null, 'Whole stream'),
                          for (final dv in divisions) (attInt(dv['div_id']), attText(dv['divname'])),
                        ],
                        onChanged: (v) => set(() => div = v))),
              _dialogField(
                  'Note',
                  TextField(
                      key: const ValueKey('cal-note'),
                      controller: remarks,
                      maxLength: 200,
                      style: AppUI.fieldText(ctx),
                      decoration: AppUI.field(ctx, 'e.g. Diwali').copyWith(counterText: ''))),
            ]),
          ),
          actions: [
            if (existing != null)
              TextButton(onPressed: () => Navigator.pop(ctx, 'reset'), child: const Text('Back to normal', style: TextStyle(color: AppColors.error))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppText.cancel)),
            ElevatedButton(style: AppUI.primary(ctx), onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    try {
      if (r == 'reset' && existing != null) {
        await AttendanceService.deleteCalendarDay(attInt(existing['calendar_day_id']));
      } else if (r == 'save') {
        await AttendanceService.saveCalendar({
          'academic_year_id': _ay,
          'from_date': AttendanceService.day(d),
          'to_date': AttendanceService.day(to ?? d),
          'div_id': div,
          'day_type': type,
          'working_session': half,
          'remarks': remarks.text.trim(),
        });
      } else {
        return;
      }
      if (!mounted) return;
      attSnack(context, 'Calendar saved.');
      await _load();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  Future<void> _weeklyOffs() async {
    var sunday = true, saturday = false;
    final sats = <int>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Weekly Offs'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Marked for the whole of this stream\'s year. Days already in the calendar, or already entered, are left as they are.', style: AppUI.muted),
              CheckboxListTile(
                  contentPadding: EdgeInsets.zero, value: sunday, onChanged: (v) => set(() => sunday = v ?? false), title: const Text('Every Sunday')),
              CheckboxListTile(
                  contentPadding: EdgeInsets.zero, value: saturday, onChanged: (v) => set(() => saturday = v ?? false), title: const Text('Every Saturday')),
              if (!saturday)
                Wrap(spacing: 8, children: [
                  for (final n in [1, 2, 3, 4, 5])
                    FilterChip(
                      label: Text('$n${n == 1 ? 'st' : n == 2 ? 'nd' : n == 3 ? 'rd' : 'th'} Saturday'),
                      selected: sats.contains(n),
                      onSelected: (v) => set(() => v ? sats.add(n) : sats.remove(n)),
                    ),
                ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
            ElevatedButton(style: AppUI.primary(ctx), onPressed: () => Navigator.pop(ctx, true), child: const Text('Mark')),
          ],
        ),
      ),
    );
    if (ok != true || _ay == null) return;
    try {
      final n = await AttendanceService.markWeekends(_ay!, [if (sunday) 7, if (saturday) 6], saturday ? const [] : (sats.toList()..sort()));
      if (!mounted) return;
      attSnack(context, n == 0 ? 'Nothing new to mark.' : '$n weekly offs marked.');
      await _load();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  Widget _grid() {
    final first = DateTime(_month.year, _month.month);
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = first.weekday - 1;
    final y = _year;
    final ys = attParse(y?['start_date']);
    final ye = attParse(y?['end_date']);
    return Column(children: [
      Padding(padding: EdgeInsets.fromLTRB(4.w, 0, 4.w, 8.h), child: Align(alignment: Alignment.centerLeft, child: _legend())),
      Row(children: [
        for (final w in kAttWeekdays)
          Expanded(
              child: Padding(padding: EdgeInsets.symmetric(vertical: 6.h), child: Text(w.toUpperCase(), textAlign: TextAlign.center, style: AppUI.tableHead))),
      ]),
      Expanded(
        child: GridView.count(
          crossAxisCount: 7,
          childAspectRatio: 1.45,
          padding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox(),
            for (var d = 1; d <= days; d++)
              Builder(builder: (_) {
                final date = DateTime(_month.year, _month.month, d);
                final inYear = ys != null && ye != null && !date.isBefore(ys) && !date.isAfter(ye);
                final (type, c) = _look(date);
                final r = _row(date);
                final divs = _divRows(date);
                return Padding(
                  padding: const EdgeInsets.all(3),
                  child: InkWell(
                    key: ValueKey('cal-day-$d'),
                    borderRadius: BorderRadius.circular(8.r),
                    onTap: inYear ? () => _editDay(date) : null,
                    child: Container(
                      padding: EdgeInsets.all(6.w),
                      decoration: BoxDecoration(
                        color: !inYear ? AppColors.surface : (type == 'WORKING' ? Colors.white : c.withValues(alpha: 0.10)),
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: type == 'WORKING' || !inYear ? AppColors.line : c.withValues(alpha: 0.5)),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('$d', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: inYear ? AppColors.ink : AppColors.ink3)),
                        if (inYear && type != 'WORKING')
                          Text(_typeText(type, r),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w700, color: c)),
                        if (inYear && attText(r?['remarks']).isNotEmpty)
                          Text(attText(r?['remarks']), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.sp, color: AppColors.ink2)),
                        if (divs.isNotEmpty) Text('+${divs.length} division', maxLines: 1, style: TextStyle(fontSize: 9.5.sp, color: AppColors.teal)),
                      ]),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final years = _streamYears(widget.l);
    if (years.isEmpty) {
      return Container(
          decoration: AppUI.card(),
          child: AppUI.empty(title: 'Add a stream first', why: 'Year & Terms: add the board with this year\'s dates.', icon: 'calendar-2'));
    }
    final special = [
      for (final r in _days)
        if (attText(r['day_type']) != 'WEEKEND') r,
    ];
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        flex: 7,
        child: AttCard(
          icon: 'calendar-2',
          title: '${kAttMonths[_month.month - 1]} ${_month.year}',
          subtitle: 'Tap a day to make it a holiday, a half day ... A Sunday with no entry is a weekly off.',
          trailing: [
            SizedBox(
              width: 140.w,
              child:
                  _drop<int>(context, value: _ay, items: [for (final y in years) (attInt(y['academic_year_id']), attText(y['stream_code']))], onChanged: (v) {
                setState(() => _ay = v);
                _load();
              }),
            ),
            IconButton(
                tooltip: 'Previous month',
                onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                icon: const Icon(Icons.chevron_left)),
            IconButton(
                tooltip: 'Next month',
                onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
                icon: const Icon(Icons.chevron_right)),
            OutlinedButton(key: const ValueKey('att-weekly-offs'), style: AppUI.secondary(context), onPressed: _weeklyOffs, child: const Text('Weekly Offs')),
          ],
          padding: EdgeInsets.all(12.w),
          child: _loading ? const AppLoading() : _grid(),
        ),
      ),
      SizedBox(width: AppUI.gap),
      Expanded(
        flex: 4,
        child: AttCard(
          icon: 'calendar-remove',
          title: 'Holidays & Special Days',
          subtitle: '${special.length} this year (weekly offs not listed)',
          child: special.isEmpty
              ? AppUI.empty(title: 'None yet', why: 'Tap a day on the calendar.', icon: 'calendar-remove')
              : ListView.separated(
                  itemCount: special.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                  itemBuilder: (_, i) {
                    final r = special[i];
                    final d = attParse(r['cal_date'])!;
                    final type = attText(r['day_type']);
                    final c = attDayColor(type);
                    return ListTile(
                      key: ValueKey('cal-list-${attInt(r['calendar_day_id'])}'),
                      dense: true,
                      // opens the day to change it (and shows its month)
                      onTap: () {
                        setState(() => _month = DateTime(d.year, d.month));
                        _editDay(d, row: r);
                      },
                      leading: Container(width: 5, height: 34, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
                      minLeadingWidth: 5,
                      title: Text.rich(TextSpan(children: [
                        TextSpan(text: '${attDayLabel(d)}  ', style: AppUI.label),
                        TextSpan(text: _typeText(type, r), style: AppUI.label.copyWith(color: c)),
                      ])),
                      subtitle: Text(
                          [if (attText(r['remarks']).isNotEmpty) attText(r['remarks']), if (attText(r['divname']).isNotEmpty) 'Only ${attText(r['divname'])}']
                              .join(' · '),
                          style: AppUI.muted),
                      trailing: IconButton(
                        tooltip: 'Back to normal',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () async {
                          try {
                            await AttendanceService.deleteCalendarDay(attInt(r['calendar_day_id']));
                            await _load();
                          } catch (e) {
                            if (context.mounted) attError(context, e);
                          }
                        },
                      ),
                    );
                  },
                ),
        ),
      ),
    ]);
  }
}

// ── Who Marks ────────────────────────────────────────────────────────────────
class _WhoMarksTab extends StatefulWidget {
  final Map<String, dynamic> l;
  final Future<void> Function() reload;
  const _WhoMarksTab({super.key, required this.l, required this.reload});

  @override
  State<_WhoMarksTab> createState() => _WhoMarksTabState();
}

class _WhoMarksTabState extends State<_WhoMarksTab> {
  int? _cla;

  /// "weekday-session" -> staf_id
  final Map<String, num?> _plan = {};
  bool _dirty = false;
  bool _saving = false;

  List<Map<String, dynamic>> get _sections => [
        for (final s in _list(widget.l, 'sections'))
          if (s['set_up'] == true) s
      ];

  @override
  void initState() {
    super.initState();
    if (_sections.isNotEmpty) _pick(attInt(_sections.first['cla_id']));
  }

  void _pick(int cla) {
    _cla = cla;
    _plan.clear();
    for (final t in _list(widget.l, 'session_teachers')) {
      if (attInt(t['cla_id']) == cla) _plan['${attInt(t['weekday'])}-${t['session_code']}'] = t['staf_id'] as num?;
    }
    _dirty = false;
  }

  Future<void> _save() async {
    final cla = _cla;
    if (cla == null) return;
    setState(() => _saving = true);
    try {
      await AttendanceService.saveSessionTeachers(cla, [
        for (var w = 1; w <= 7; w++)
          for (final s in const ['FN', 'AN']) {'weekday': w, 'session_code': s, 'staf_id': _plan['$w-$s']},
      ]);
      if (!mounted) return;
      attSnack(context, 'Saved. It applies from today.');
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final secs = _sections;
    if (secs.isEmpty) {
      return Container(
          decoration: AppUI.card(), child: AppUI.empty(title: 'No sections take attendance yet', why: 'Set them up under Sections.', icon: 'user-tick'));
    }
    final staffPicks = _staffPicks(widget.l);
    final sec = secs.where((x) => attInt(x['cla_id']) == _cla).firstOrNull;
    final teacher = sec?['class_teacher_staf_id'] as num?;
    return AttCard(
      icon: 'user-tick',
      title: 'Who Marks',
      subtitle: 'The first-hour teacher of each session marks the register in the teacher app. The office can always enter it here.',
      trailing: [
        SizedBox(
          width: 170.w,
          child: _drop<int>(context, value: _cla, items: [for (final s in secs) (attInt(s['cla_id']), attText(s['claname']))], onChanged: (v) async {
            if (v == null) return;
            if (_dirty && !await confirmAtt(context, title: 'Discard changes?', message: 'This section\'s week is not saved yet.', ok: 'Discard', danger: true)) {
              return;
            }
            setState(() => _pick(v));
          }),
        ),
        // the same teachers on every working day
        OutlinedButton(
          key: const ValueKey('who-copy-monday'),
          style: AppUI.secondary(context),
          onPressed: () => setState(() {
            for (var w = 2; w <= 6; w++) {
              for (final x in const ['FN', 'AN']) {
                _plan['$w-$x'] = _plan['1-$x'];
              }
            }
            _dirty = true;
          }),
          child: const Text('Same as Monday'),
        ),
        if (teacher != null)
          OutlinedButton(
            key: const ValueKey('who-class-teacher'),
            style: AppUI.secondary(context),
            onPressed: () => setState(() {
              for (var w = 1; w <= 6; w++) {
                _plan['$w-FN'] = teacher;
              }
              _dirty = true;
            }),
            child: const Text('Class Teacher for FN'),
          ),
        ElevatedButton(style: AppUI.primary(context), onPressed: !_dirty || _saving ? null : _save, child: const Text('Save')),
      ],
      child: ListView(children: [
        attHeadRow([AppUI.th('Day', flex: 2), AppUI.th('FN (forenoon)', flex: 4), SizedBox(width: 16.w), AppUI.th('AN (afternoon)', flex: 4)]),
        for (var w = 1; w <= 7; w++)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
            child: Row(children: [
              Expanded(flex: 2, child: Text(kAttWeekdays[w - 1], style: AppUI.label)),
              for (final s in const ['FN', 'AN']) ...[
                Expanded(
                  flex: 4,
                  child: AppSearchPickField<num>(
                      key: ValueKey('who-$_cla-$w-$s'),
                      value: _plan['$w-$s'],
                      items: staffPicks,
                      hint: 'Search teacher',
                      title: '${kAttWeekdays[w - 1]} $s',
                      noneLabel: 'Nobody',
                      onChanged: (v) => setState(() {
                            _plan['$w-$s'] = v;
                            _dirty = true;
                          })),
                ),
                if (s == 'FN') SizedBox(width: 16.w),
              ],
            ]),
          ),
      ]),
    );
  }
}

// ── role names ───────────────────────────────────────────────────────────────
const _kRoles = {
  'PRINCIPAL': 'Principal',
  'DIVISION_INCHARGE': 'Division in-charge',
  'TEACHER': 'Teacher',
  'OFFICE_ADMIN': 'Office admin',
};

// ── Settings ─────────────────────────────────────────────────────────────────
class _StatusSettingsTab extends StatefulWidget {
  final Map<String, dynamic> l;
  final Future<void> Function() reload;
  const _StatusSettingsTab({super.key, required this.l, required this.reload});

  @override
  State<_StatusSettingsTab> createState() => _StatusSettingsTabState();
}

class _StatusSettingsTabState extends State<_StatusSettingsTab> {
  late final Map<String, dynamic> _s = widget.l['settings'] is Map ? Map<String, dynamic>.from(widget.l['settings'] as Map) : <String, dynamic>{};
  late final Map<String, TextEditingController> _n = {
    for (final k in const ['allow_backdated_days', 'min_attendance_pct', 'absent_sms_delay_minutes', 'teacher_edit_window_minutes'])
      k: TextEditingController(text: attText(_s[k])),
  };
  bool _saving = false;

  @override
  void dispose() {
    for (final c in _n.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _time(String k) {
    final t = attText(_s[k]);
    final p = t.split(':');
    if (p.length < 2) return t;
    final h = int.tryParse(p[0]) ?? 0;
    return '${(h % 12 == 0 ? 12 : h % 12)}:${p[1]} ${h < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _pickTime(String k) async {
    final p = attText(_s[k]).split(':');
    final t =
        await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.tryParse(p.first) ?? 9, minute: p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0));
    if (t == null) return;
    setState(() => _s[k] = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00');
  }

  Future<void> _saveSettings() async {
    setState(() => _saving = true);
    try {
      await AttendanceService.saveSettings({
        for (final k in const ['fn_start_time', 'an_start_time', 'auto_lock_time']) k: _s[k],
        for (final e in _n.entries) e.key: e.value.text.trim(),
      });
      if (!mounted) return;
      attSnack(context, 'Settings saved.');
      await widget.reload();
    } catch (e) {
      if (mounted) attError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _setting(String label, String help, Widget field) => Padding(
        padding: EdgeInsets.only(bottom: 14.h),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppUI.label),
              SizedBox(height: 2.h),
              Text(help, style: AppUI.muted),
            ]),
          ),
          SizedBox(width: 12.w),
          SizedBox(width: 150.w, child: field),
        ]),
      );

  Widget _timeField(String k) => InkWell(
        onTap: () => _pickTime(k),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: InputDecorator(
            decoration: AppUI.field(context, '', filled: true, leadingIcon: 'clock'), child: Text(_time(k), style: AppUI.fieldText(context, filled: true))),
      );

  Widget _numField(String k, {bool decimal = false}) => TextField(
        key: ValueKey('setting-$k'),
        controller: _n[k],
        style: AppUI.fieldText(context, filled: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimal ? r'[0-9.]' : r'[0-9]'))],
        decoration: AppUI.field(context, '', filled: true),
      );

  @override
  Widget build(BuildContext context) {
    return AttCard(
      icon: 'setting-2',
      title: 'Settings',
      subtitle: 'The school\'s attendance rules',
      trailing: [
        ElevatedButton(
            key: const ValueKey('att-settings-save'), style: AppUI.primary(context), onPressed: _saving ? null : _saveSettings, child: const Text('Save')),
      ],
      padding: EdgeInsets.all(AppUI.cardPad),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: ListView(children: [
            _setting('FN starts', 'The forenoon register is taken in the first hour.', _timeField('fn_start_time')),
            _setting('AN starts', 'A student who leaves on an out-pass before this is suggested Absent for AN.', _timeField('an_start_time')),
            _setting('Days back the office can enter', 'The office can enter or correct a register this many days back (0 = today only).',
                _numField('allow_backdated_days')),
            _setting('Minimum attendance %', 'Below this a student is on the shortage list (CBSE: 75 for the board exams).',
                _numField('min_attendance_pct', decimal: true)),
            _setting('Wait before the absent SMS (minutes)',
                'After a register is submitted, so a teacher\'s mistake can be corrected before the parent is told.', _numField('absent_sms_delay_minutes')),
            _setting('Teacher can correct for (minutes)', 'In the teacher app, after submitting.', _numField('teacher_edit_window_minutes')),
            _setting('Registers lock at', 'In the teacher app, the day\'s registers close at this time.', _timeField('auto_lock_time')),
          ]),
        ),
      ),
    );
  }
}
