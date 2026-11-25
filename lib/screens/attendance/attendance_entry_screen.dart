import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/attendance_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'attendance_common.dart';

/// ATTENDANCE ENTRY -- the office register (school_attendance_api.sql:
/// att_register_day / att_register_get / att_register_save / att_register_clear).
///
/// Left: the date and every section taking attendance, each with its FN and
/// AN register (not entered / draft / submitted, and the counts). Right: one
/// section's register for the date and session -- a status for every student
/// (suggested from approved leave and out-passes), remarks, All Present,
/// Save Draft / Submit. A submitted register changes only with a reason
/// (kept in the audit log). The server decides what can be entered: a
/// working session, inside a term, not in the future, not older than the
/// school's back-dating limit.
class AttendanceEntryScreen extends StatefulWidget {
  const AttendanceEntryScreen({super.key});

  @override
  State<AttendanceEntryScreen> createState() => _AttendanceEntryScreenState();
}

class _AttendanceEntryScreenState extends State<AttendanceEntryScreen> {
  DateTime _date = attOnly(DateTime.now());
  DateTime? _today;
  List<Map<String, dynamic>> _statuses = const [];

  Map<String, dynamic>? _day;
  bool _dayLoading = true;
  String? _dayError;

  int? _cla;
  String _session = 'FN';
  Map<String, dynamic>? _reg;
  bool _regLoading = false;
  String? _regError;

  final Map<int, String> _marks = {};
  final Map<int, TextEditingController> _remarks = {};
  bool _dirty = false;
  bool _saving = false;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _search.dispose();
    for (final c in _remarks.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final l = await AttendanceService.lookups();
      _statuses = [
        for (final s in (l['statuses'] as List? ?? const []))
          if (s is Map) Map<String, dynamic>.from(s),
      ];
      final t = attParse(l['today']);
      if (t != null) {
        _today = t;
        _date = t;
      }
    } catch (e) {
      if (mounted) setState(() => _dayError = friendlyError(e));
    }
    await _loadDay();
  }

  List<Map<String, dynamic>> get _activeStatuses => [for (final s in _statuses) if (s['is_active'] != false) s];

  Map<String, dynamic>? _status(String code) {
    for (final s in _statuses) {
      if (s['status_code'] == code) return s;
    }
    return null;
  }

  List<Map<String, dynamic>> get _sections => [
        for (final s in (_day?['sections'] as List? ?? const []))
          if (s is Map) Map<String, dynamic>.from(s),
      ];

  Map<String, dynamic>? get _section {
    for (final s in _sections) {
      if (attInt(s['cla_id']) == _cla) return s;
    }
    return null;
  }

  // ── loading ──────────────────────────────────────────────────────────────
  Future<void> _loadDay({bool keepRegister = false}) async {
    setState(() {
      _dayLoading = true;
      _dayError = null;
    });
    try {
      final d = await AttendanceService.registerDay(_date);
      if (!mounted) return;
      setState(() {
        _day = d;
        _today = attParse(d['today']) ?? _today;
        _dayLoading = false;
        if (_cla == null || _section == null) {
          _cla = _sections.isEmpty ? null : attInt(_sections.first['cla_id']);
        }
      });
      if (!keepRegister) {
        _pickWorkingSession();
        await _loadRegister();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _dayLoading = false;
          _dayError = friendlyError(e);
        });
      }
    }
  }

  /// FN unless only AN works that day.
  void _pickWorkingSession() {
    final s = _section;
    if (s == null) return;
    if (_session == 'FN' && s['fn_working'] != true && s['an_working'] == true) _session = 'AN';
    if (_session == 'AN' && s['an_working'] != true && s['fn_working'] == true) _session = 'FN';
  }

  Future<void> _loadRegister() async {
    final cla = _cla;
    if (cla == null) {
      setState(() => _reg = null);
      return;
    }
    setState(() {
      _regLoading = true;
      _regError = null;
    });
    try {
      final r = await AttendanceService.register(cla, _date, _session);
      if (!mounted) return;
      _take(r);
      setState(() => _regLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _regLoading = false;
          _regError = friendlyError(e);
          _reg = null;
        });
      }
    }
  }

  /// The register as the server sent it: marks and remarks from it.
  void _take(Map<String, dynamic> r) {
    for (final c in _remarks.values) {
      c.dispose();
    }
    _remarks.clear();
    _marks.clear();
    for (final s in _students(r)) {
      final id = attInt(s['stu_id']);
      _marks[id] = attText(s['status_code']).isEmpty ? 'P' : attText(s['status_code']);
      _remarks[id] = TextEditingController(text: attText(s['remarks']));
    }
    _reg = r;
    _dirty = false;
  }

  List<Map<String, dynamic>> _students(Map<String, dynamic>? r) => [
        for (final s in (r?['students'] as List? ?? const []))
          if (s is Map) Map<String, dynamic>.from(s),
      ];

  // ── moving around ────────────────────────────────────────────────────────
  Future<bool> _leaveOk() async {
    if (!_dirty) return true;
    return confirmAtt(context,
        title: 'Discard changes?', message: 'The marks on this register are not saved yet.', ok: 'Discard', danger: true);
  }

  Future<void> _goDate(DateTime d) async {
    if (!await _leaveOk()) return;
    _date = attOnly(d);
    await _loadDay();
  }

  Future<void> _goSection(int cla) async {
    if (cla == _cla || !await _leaveOk()) return;
    setState(() => _cla = cla);
    _pickWorkingSession();
    await _loadRegister();
  }

  Future<void> _goSession(String s) async {
    if (s == _session || !await _leaveOk()) return;
    setState(() => _session = s);
    await _loadRegister();
  }

  // ── saving ───────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _entries() => [
        for (final s in _students(_reg))
          {
            'stu_id': attInt(s['stu_id']),
            'status_code': _marks[attInt(s['stu_id'])] ?? 'P',
            'remarks': _remarks[attInt(s['stu_id'])]?.text.trim() ?? '',
          },
      ];

  Future<void> _save({required bool submit}) async {
    final cla = _cla;
    if (cla == null || _reg == null) return;
    String? reason;
    if (_reg!['needs_reason'] == true) {
      reason = await askAttReason(context,
          title: 'Change a submitted register',
          message: 'This register was already submitted. Why is it being changed? The reason is kept with the change.');
      if (reason == null) return;
    } else if (submit) {
      final absent = _marks.values.where((m) => _status(m)?['counts_as_present'] != true).length;
      final ok = await confirmAtt(context,
          title: 'Submit the $_session register?',
          message: '${_section?['claname'] ?? ''}, ${attDayLabel(_date)}: ${_marks.length} students, $absent not present. '
              'After submitting, a change needs a reason.',
          ok: 'Submit');
      if (!ok) return;
    }
    setState(() => _saving = true);
    try {
      final r = await AttendanceService.saveRegister(cla, _date, _session, _entries(), submit: submit, reason: reason);
      if (!mounted) return;
      setState(() => _take(r));
      if (!mounted) return;
      attSnack(context, submit ? '$_session register submitted.' : (reason != null ? 'Changes saved.' : 'Draft saved.'));
      await _loadDay(keepRegister: true);
    } catch (e) {
      if (mounted) attError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    final cla = _cla;
    if (cla == null || _reg?['sheet'] == null) return;
    String? reason;
    if (_reg!['needs_reason'] == true) {
      reason = await askAttReason(context,
          title: 'Remove this register',
          message: 'This register was already submitted. Why is it being removed? The marks and the reason are kept in the audit log.');
      if (reason == null) return;
    } else {
      final ok = await confirmAtt(context,
          title: 'Remove this register?', message: 'Every mark on the $_session register of this section for this date is removed.', ok: 'Remove', danger: true);
      if (!ok) return;
    }
    setState(() => _saving = true);
    try {
      final r = await AttendanceService.clearRegister(cla, _date, _session, reason: reason);
      if (!mounted) return;
      setState(() => _take(r));
      if (!mounted) return;
      attSnack(context, 'Register removed.');
      await _loadDay(keepRegister: true);
    } catch (e) {
      if (mounted) attError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _allPresent() {
    setState(() {
      for (final s in _students(_reg)) {
        final id = attInt(s['stu_id']);
        // a student on leave / out-pass keeps the suggested mark
        if (attText(s['note']).isEmpty) _marks[id] = 'P';
      }
      _dirty = true;
    });
  }

  // ── left: the date and the sections ──────────────────────────────────────
  Widget _rail() {
    final secs = _sections;
    int entered(String k) => secs.where((s) => s[k] is Map && (s[k] as Map)['status'] == 'SUBMITTED').length;
    int working(String k) => secs.where((s) => s['${k}_working'] == true).length;
    final isToday = _today != null && _date == _today;
    return Container(
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 8.h),
          child: AppUI.cardHeader(icon: 'calendar-tick', title: 'Attendance Entry'),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 14.w),
          child: Row(children: [
            IconButton(
              key: const ValueKey('att-prev-day'),
              tooltip: 'Previous day',
              onPressed: _dayLoading ? null : () => _goDate(_date.subtract(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: AttDateField(
                key: const ValueKey('att-date'),
                value: _date,
                last: _today,
                onPicked: _goDate,
              ),
            ),
            IconButton(
              key: const ValueKey('att-next-day'),
              tooltip: 'Next day',
              onPressed: _dayLoading || (_today != null && !_date.isBefore(_today!)) ? null : () => _goDate(_date.add(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_right),
            ),
          ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(18.w, 4.h, 14.w, 8.h),
          child: Row(children: [
            Expanded(child: Text(attDayLabel(_date), style: AppUI.label)),
            if (!isToday && _today != null)
              TextButton(onPressed: () => _goDate(_today!), child: const Text('Today')),
          ]),
        ),
        if (secs.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(14.w, 0, 14.w, 10.h),
            child: Wrap(spacing: 8.w, runSpacing: 6.h, children: [
              attCount('FN submitted', '${entered('fn')}/${working('fn')}', AppColors.primary),
              attCount('AN submitted', '${entered('an')}/${working('an')}', AppColors.primary),
            ]),
          ),
        const Divider(height: 1, color: AppColors.divider),
        Expanded(
          child: _dayLoading
              ? const AppLoading()
              : _dayError != null
                  ? Padding(padding: EdgeInsets.all(16.w), child: Text(_dayError!, style: AppUI.muted))
                  : secs.isEmpty
                      ? AppUI.empty(
                          title: 'No sections take attendance yet',
                          why: 'Add a stream, its terms, and the sections in Attendance Setup.',
                          icon: 'calendar-tick')
                      : ListView(
                          padding: EdgeInsets.fromLTRB(10.w, 10.h, 10.w, 10.h),
                          children: [for (final s in secs) _sectionTile(s)],
                        ),
        ),
      ]),
    );
  }

  Widget _sessionBadge(Map<String, dynamic> s, String k) {
    final working = s['${k}_working'] == true;
    final sheet = s[k] is Map ? Map<String, dynamic>.from(s[k] as Map) : null;
    final label = k.toUpperCase();
    final (Color c, String text) = !working
        ? (AppColors.ink3, '$label off')
        : sheet == null
            ? (AppColors.error, '$label -')
            : sheet['status'] == 'SUBMITTED' || sheet['status'] == 'LOCKED'
                ? (AppColors.primary, '$label ${attInt(sheet['present'])}/${attInt(sheet['total'])}')
                : (AppColors.goldDark, '$label draft');
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(6.r)),
      child: Text(text, style: TextStyle(fontSize: 10.5.sp, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _sectionTile(Map<String, dynamic> s) {
    final id = attInt(s['cla_id']);
    final selected = id == _cla;
    const c = AppColors.accent;
    return Padding(
      padding: EdgeInsets.only(bottom: 6.h),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('att-section-$id'),
          borderRadius: BorderRadius.circular(10.r),
          onTap: () => _goSection(id),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
            decoration: BoxDecoration(
              color: selected ? c.withValues(alpha: 0.10) : Colors.white,
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(color: selected ? c.withValues(alpha: 0.55) : AppColors.border, width: selected ? 1.4 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(attText(s['claname']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.sp, fontWeight: selected ? FontWeight.w700 : FontWeight.w600, color: selected ? c : AppColors.textPrimary)),
                ),
                Text('${attInt(s['strength'])}', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                SizedBox(width: 2.w),
                const AppIcon.linear('people', size: 12, color: AppColors.textSecondary),
              ]),
              SizedBox(height: 4.h),
              Wrap(spacing: 6.w, runSpacing: 4.h, children: [_sessionBadge(s, 'fn'), _sessionBadge(s, 'an')]),
            ]),
          ),
        ),
      ),
    );
  }

  // ── right: the register ──────────────────────────────────────────────────
  /// A status as the dropdown shows it: the code on its colour, then the name
  /// -- in the field only the part before any brackets ("On duty", not "On
  /// duty (school event / sports)"), the whole of it on hover and in the list.
  Widget _statusLabel(Map<String, dynamic> st, {bool muted = false, bool short = false}) {
    final full = attText(st['status_name']);
    final name = short ? full.split(' (').first.trim() : full;
    final row = Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          constraints: const BoxConstraints(minWidth: 30),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: muted ? AppColors.ink3 : attStatusColor(st), borderRadius: BorderRadius.circular(5)),
          child: Text(attText(st['status_code']),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(name,
              maxLines: short ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: AppUI.fieldText(context, filled: true)),
        ),
      ]);
    return short && name != full ? Tooltip(message: full, child: row) : row;
  }

  /// The student's mark as a dropdown (user, 2026-11-24: "into drop down").
  Widget _statusDrop(int id, bool editable) {
    final current = _marks[id] ?? 'P';
    final saved = _status(current);
    final options = <Map<String, dynamic>>[
      ..._activeStatuses,
      // a mark saved with a status since switched off still shows
      if (saved != null && !_activeStatuses.any((x) => x['status_code'] == current)) saved,
    ];
    return AppDropdownField<String>(
      key: ValueKey('att-status-$id'),
      initialValue: current,
      isExpanded: true,
      isDense: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(10),
      decoration: AppUI.field(context, '', filled: true, dense: true),
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      items: [
        for (final st in options) DropdownMenuItem(value: attText(st['status_code']), child: _statusLabel(st)),
      ],
      selectedItemBuilder: (_) => [
        for (final st in options) Align(alignment: Alignment.centerLeft, child: _statusLabel(st, muted: !editable, short: true)),
      ],
      onChanged: !editable
          ? null
          : (v) => setState(() {
                if (v == null) return;
                _marks[id] = v;
                _dirty = true;
              }),
    );
  }

  Widget _studentRow(Map<String, dynamic> s, int i, bool editable) {
    final id = attInt(s['stu_id']);
    final note = attText(s['note']);
    return Container(
      key: ValueKey('att-row-$id'),
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
      color: i.isEven ? Colors.white : AppColors.surface,
      child: Row(children: [
        SizedBox(width: 44.w, child: Text('${i + 1}', style: AppUI.cell)),
        Expanded(flex: 2, child: Text(attText(s['stuadmno']), style: AppUI.mono)),
        Expanded(
          flex: 4,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(attText(s['stuname']), style: AppUI.cell, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (note.isNotEmpty) Text(note, style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: AppColors.goldDark)),
          ]),
        ),
        Expanded(flex: 4, child: _statusDrop(id, editable)),
        SizedBox(width: 10.w),
        Expanded(
          flex: 3,
          child: TextField(
            controller: _remarks[id],
            enabled: editable,
            maxLength: 200,
            style: AppUI.fieldText(context),
            onChanged: (_) {
              if (!_dirty) setState(() => _dirty = true);
            },
            decoration: AppUI.field(context, 'Remarks', dense: true).copyWith(counterText: ''),
          ),
        ),
      ]),
    );
  }

  Widget _register() {
    final sec = _section;
    if (_dayLoading && _reg == null) return Container(decoration: AppUI.card(), child: const AppLoading());
    if (sec == null) {
      return Container(
        decoration: AppUI.card(),
        child: AppUI.empty(
          title: _dayError ?? 'Pick a section',
          why: _dayError == null ? 'The sections taking attendance are on the left.' : null,
          icon: 'calendar-tick',
        ),
      );
    }
    final reg = _reg;
    final sheet = reg?['sheet'] is Map ? Map<String, dynamic>.from(reg!['sheet'] as Map) : null;
    final editable = reg?['editable'] == true && !_saving;
    final submitted = sheet?['status'] == 'SUBMITTED' || sheet?['status'] == 'LOCKED';
    final students = _students(reg);
    final q = _search.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? students
        : students.where((s) => '${s['stuname']} ${s['stuadmno']}'.toLowerCase().contains(q)).toList();
    int count(bool Function(String) f) => _marks.values.where(f).length;
    final present = count((m) => _status(m)?['counts_as_present'] == true);
    final absent = count((m) => m == 'A');
    final leave = count((m) => m == 'L');
    final subtitle = [
      if (attText(sec['courname']).isNotEmpty) 'Standard ${attText(sec['courname'])}',
      if (attText(sec['stream_code']).isNotEmpty) attText(sec['stream_code']),
      if (attText(sec['class_teacher']).isNotEmpty) 'Class teacher: ${attText(sec['class_teacher'])}',
      if (attText(reg?['term_name']).isNotEmpty) attText(reg?['term_name']),
    ].join('  ·  ');
    return AttCard(
      icon: 'teacher',
      title: '${attText(sec['claname'])} · ${attDayLabel(_date)}',
      subtitle: subtitle,
      trailing: [
        SegmentedButton<String>(
          key: const ValueKey('att-session'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'FN', label: const Text('FN'), enabled: sec['fn_working'] == true),
            ButtonSegment(value: 'AN', label: const Text('AN'), enabled: sec['an_working'] == true),
          ],
          selected: {_session},
          onSelectionChanged: (v) => _goSession(v.first),
        ),
        if (sheet == null)
          AppUI.chip('Not entered', AppStatus.neutral)
        else if (submitted)
          AppUI.chip(sheet['status'] == 'LOCKED' ? 'Locked' : 'Submitted', AppStatus.success)
        else
          AppUI.chip('Draft', AppStatus.warning),
      ],
      child: _regLoading
          ? const AppLoading()
          : _regError != null
              ? AppUI.empty(title: 'Could not load the register', why: _regError, icon: 'warning-2')
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (reg?['editable'] != true && attText(reg?['why_locked']).isNotEmpty)
                    Container(
                      margin: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 0),
                      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                      decoration: BoxDecoration(color: AppColors.goldSoft, borderRadius: BorderRadius.circular(10.r)),
                      child: Row(children: [
                        const AppIcon.linear('info-circle', size: 16, color: AppColors.goldDark),
                        SizedBox(width: 8.w),
                        Expanded(child: Text(attText(reg?['why_locked']), style: AppUI.body)),
                      ]),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 8.h),
                    child: Wrap(spacing: 8.w, runSpacing: 8.h, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      attCount('Total', students.length, AppColors.ink2),
                      attCount('Present', present, AppColors.primary),
                      attCount('Absent', absent, AppColors.error),
                      attCount('Leave', leave, AppColors.goldDark),
                      SizedBox(
                        width: 220.w,
                        child: AppSearchField(controller: _search, hintText: 'Search student', onChanged: (_) => setState(() {})),
                      ),
                      if (editable)
                        OutlinedButton.icon(
                          key: const ValueKey('att-all-present'),
                          style: AppUI.secondary(context),
                          onPressed: students.isEmpty ? null : _allPresent,
                          icon: const Icon(Icons.done_all, size: 16),
                          label: const Text('All Present'),
                        ),
                    ]),
                  ),
                  attHeadRow([
                    SizedBox(width: 44.w, child: Text('S.NO', style: AppUI.tableHead)),
                    AppUI.th('Adm No', flex: 2),
                    AppUI.th('Student', flex: 4),
                    AppUI.th('Status', flex: 4),
                    SizedBox(width: 10.w),
                    AppUI.th('Remarks', flex: 3),
                  ]),
                  Expanded(
                    child: students.isEmpty
                        ? AppUI.empty(title: 'No students in this section on this date', icon: 'people')
                        : ListView.builder(
                            itemCount: shown.length,
                            itemBuilder: (_, i) => _studentRow(shown[i], students.indexOf(shown[i]), editable),
                          ),
                  ),
                  const Divider(height: 1, color: AppColors.divider),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                    child: Row(children: [
                      Expanded(
                        child: Text(
                          sheet == null
                              ? 'Not entered yet.'
                              : 'Last saved by ${attText(sheet['marked_by_name']).isEmpty ? '-' : attText(sheet['marked_by_name'])}'
                                  '${sheet['submitted_at'] != null ? ' · submitted ${attShow(sheet['submitted_at'])}' : ''}',
                          style: AppUI.muted,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (sheet != null && reg?['editable'] == true)
                        TextButton(
                          key: const ValueKey('att-clear'),
                          onPressed: _saving ? null : _clear,
                          child: const Text('Remove Register', style: TextStyle(color: AppColors.error)),
                        ),
                      SizedBox(width: 8.w),
                      if (editable && !submitted)
                        OutlinedButton(
                          key: const ValueKey('att-save-draft'),
                          style: AppUI.secondary(context),
                          onPressed: students.isEmpty ? null : () => _save(submit: false),
                          child: const Text('Save Draft'),
                        ),
                      SizedBox(width: 8.w),
                      if (editable)
                        ElevatedButton(
                          key: const ValueKey('att-submit'),
                          style: AppUI.primary(context),
                          onPressed: students.isEmpty || (submitted && !_dirty) ? null : () => _save(submit: !submitted),
                          child: Text(submitted ? 'Save Changes' : 'Submit'),
                        ),
                    ]),
                  ),
                ]),
    );
  }

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 290.w, child: _rail()),
        SizedBox(width: AppUI.gap),
        Expanded(child: _register()),
      ]);
}
