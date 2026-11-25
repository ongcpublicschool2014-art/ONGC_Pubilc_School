import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/attendance_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/pill_tab.dart';
import 'attendance_common.dart';

/// ATTENDANCE REPORT (school_attendance_api.sql, 'Attendance Report' menu),
/// from submitted registers only:
///   Summary           each student's working / present days and % for a term
///                     or the whole year; Shortage only = below the school's
///                     minimum %
///   Absentees         every session missed between two dates, with the
///                     parent's mobile
///   Monthly Register  one section's month: FN / AN marks per day
/// Each exports to Excel.
class AttendanceReportScreen extends StatefulWidget {
  const AttendanceReportScreen({super.key});

  @override
  State<AttendanceReportScreen> createState() => _AttendanceReportScreenState();
}

class _AttendanceReportScreenState extends State<AttendanceReportScreen> {
  int _tab = 0;
  Map<String, dynamic>? _l;
  String? _error;

  @override
  void initState() {
    super.initState();
    AttendanceService.lookups().then((l) {
      if (mounted) setState(() => _l = l);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = friendlyError(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Wrap(spacing: PillTab.gap(context), children: [
          PillTab(key: const ValueKey('rep-tab-0'), icon: 'chart-1', label: 'Summary', selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
          PillTab(key: const ValueKey('rep-tab-1'), icon: 'user-remove', label: 'Absentees', selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
          PillTab(key: const ValueKey('rep-tab-2'), icon: 'grid-1', label: 'Monthly Register', selected: _tab == 2, onTap: () => setState(() => _tab = 2)),
        ]),
      ),
      SizedBox(height: 6.h),
      Expanded(
        child: _error != null
            ? Container(decoration: AppUI.card(), child: AppUI.empty(title: 'Could not load the report', why: _error, icon: 'warning-2'))
            : l == null
                ? Container(decoration: AppUI.card(), child: const AppLoading())
                : switch (_tab) {
                    0 => _SummaryTab(l: l),
                    1 => _AbsenteesTab(l: l),
                    _ => _RegisterTab(l: l),
                  },
      ),
    ]);
  }
}

List<Map<String, dynamic>> _list(Map<String, dynamic> l, String k) => [
      for (final x in (l[k] as List? ?? const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];

List<Map<String, dynamic>> _setUpSections(Map<String, dynamic> l) => [for (final s in _list(l, 'sections')) if (s['set_up'] == true) s];

Widget _drop<T>(BuildContext context, T? value, List<(T, String)> items, ValueChanged<T?> onChanged, {String hint = 'Select', Key? key}) => AppDropdownField<T>(
      key: key,
      initialValue: items.any((i) => i.$1 == value) ? value : null,
      isExpanded: true,
      decoration: AppUI.field(context, hint, filled: value != null, dense: true),
      style: AppUI.fieldText(context),
      items: [for (final i in items) DropdownMenuItem(value: i.$1, child: Text(i.$2, overflow: TextOverflow.ellipsis))],
      onChanged: onChanged,
    );

Widget _exportButton(BuildContext context, bool enabled, Future<String?> Function() run) => OutlinedButton.icon(
      style: AppUI.secondary(context),
      onPressed: !enabled
          ? null
          : () async {
              try {
                final p = await run();
                if (p != null && context.mounted) attSnack(context, 'Saved to $p');
              } catch (e) {
                if (context.mounted) attError(context, e);
              }
            },
      icon: const Icon(Icons.download, size: 16),
      label: const Text('Excel'),
    );

// ── Summary ──────────────────────────────────────────────────────────────────
class _SummaryTab extends StatefulWidget {
  final Map<String, dynamic> l;
  const _SummaryTab({required this.l});

  @override
  State<_SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<_SummaryTab> {
  int? _term;
  int? _cla;
  bool _shortOnly = false;
  List<Map<String, dynamic>> _rows = const [];
  double _min = 75;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await AttendanceService.summary(termId: _term, claId: _cla);
      if (!mounted) return;
      setState(() {
        _rows = [for (final x in (r['rows'] as List? ?? const [])) if (x is Map) Map<String, dynamic>.from(x)];
        _min = double.tryParse('${r['min_pct']}') ?? 75;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  double _pct(Map<String, dynamic> r) => double.tryParse('${r['attendance_pct']}') ?? 0;

  @override
  Widget build(BuildContext context) {
    final streams = {for (final s in _list(widget.l, 'streams')) attInt(s['academic_year_id']): attText(s['stream_code'])};
    final terms = [
      (null as int?, 'Whole year'),
      for (final t in _list(widget.l, 'terms')) (attInt(t['term_id']) as int?, '${attText(t['term_name'])} (${streams[attInt(t['academic_year_id'])] ?? ''})'),
    ];
    final secs = [(null as int?, 'All sections'), for (final s in _setUpSections(widget.l)) (attInt(s['cla_id']) as int?, attText(s['claname']))];
    final rows = _shortOnly ? _rows.where((r) => _pct(r) < _min).toList() : _rows;
    final below = _rows.where((r) => _pct(r) < _min).length;
    final avg = _rows.isEmpty ? 0.0 : _rows.fold<double>(0, (a, r) => a + _pct(r)) / _rows.length;
    return AttCard(
      icon: 'chart-1',
      title: 'Attendance Summary',
      subtitle: 'From submitted registers. Minimum ${_min.toStringAsFixed(_min % 1 == 0 ? 0 : 2)}% (Attendance Setup -> Settings).',
      trailing: [
        SizedBox(width: 200.w, child: _drop<int?>(context, _term, terms, (v) {
          setState(() => _term = v);
          _load();
        }, key: const ValueKey('rep-term'))),
        SizedBox(width: 160.w, child: _drop<int?>(context, _cla, secs, (v) {
          setState(() => _cla = v);
          _load();
        }, key: const ValueKey('rep-section'))),
        FilterChip(
          key: const ValueKey('rep-short'),
          label: Text('Shortage only ($below)'),
          selected: _shortOnly,
          onSelected: (v) => setState(() => _shortOnly = v),
        ),
        _exportButton(
            context,
            rows.isNotEmpty,
            () => exportAttTable('Attendance Summary', [
                  'S.No', 'Adm No', 'Student', 'Section', 'Working days', 'Present days', 'Absent sessions', 'Leave sessions', 'Attendance %',
                ], [
                  for (var i = 0; i < rows.length; i++)
                    [
                      i + 1,
                      attText(rows[i]['stuadmno']),
                      attText(rows[i]['stuname']),
                      attText(rows[i]['claname']),
                      double.tryParse('${rows[i]['working_days']}'),
                      double.tryParse('${rows[i]['present_days']}'),
                      attInt(rows[i]['absent_sessions']),
                      attInt(rows[i]['leave_sessions']),
                      _pct(rows[i]),
                    ],
                ])),
      ],
      child: _loading
          ? const AppLoading()
          : _error != null
              ? AppUI.empty(title: 'Could not load the summary', why: _error, icon: 'warning-2')
              : _rows.isEmpty
                  ? AppUI.empty(title: 'Nothing submitted yet', why: 'The summary counts submitted registers.', icon: 'chart-1')
                  : Column(children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 10.h),
                        child: Wrap(spacing: 8.w, runSpacing: 8.h, children: [
                          attCount('Students', _rows.length, AppColors.ink2),
                          attCount('Average', '${avg.toStringAsFixed(1)}%', AppColors.primary),
                          attCount('Below minimum', below, AppColors.error),
                        ]),
                      ),
                      attHeadRow([
                        AppUI.th('S.No'),
                        AppUI.th('Adm No', flex: 2),
                        AppUI.th('Student', flex: 4),
                        AppUI.th('Section', flex: 2),
                        AppUI.th('Working days', flex: 2, align: TextAlign.right),
                        AppUI.th('Present days', flex: 2, align: TextAlign.right),
                        AppUI.th('Absent', flex: 2, align: TextAlign.right),
                        AppUI.th('Leave', flex: 2, align: TextAlign.right),
                        AppUI.th('%', flex: 2, align: TextAlign.right),
                      ]),
                      Expanded(
                        child: ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (_, i) {
                            final r = rows[i];
                            final low = _pct(r) < _min;
                            return Container(
                              color: low ? AppColors.errorBg : (i.isEven ? Colors.white : AppColors.surface),
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                              child: Row(children: [
                                Expanded(child: Text('${i + 1}', style: AppUI.cell)),
                                Expanded(flex: 2, child: Text(attText(r['stuadmno']), style: AppUI.mono)),
                                Expanded(flex: 4, child: Text(attText(r['stuname']), style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                                Expanded(flex: 2, child: Text(attText(r['claname']), style: AppUI.cell)),
                                Expanded(flex: 2, child: Text(attText(r['working_days']), textAlign: TextAlign.right, style: AppUI.money)),
                                Expanded(flex: 2, child: Text(attText(r['present_days']), textAlign: TextAlign.right, style: AppUI.money)),
                                Expanded(flex: 2, child: Text('${attInt(r['absent_sessions'])}', textAlign: TextAlign.right, style: AppUI.money)),
                                Expanded(flex: 2, child: Text('${attInt(r['leave_sessions'])}', textAlign: TextAlign.right, style: AppUI.money)),
                                Expanded(
                                  flex: 2,
                                  child: Text('${_pct(r).toStringAsFixed(2)}%',
                                      textAlign: TextAlign.right, style: AppUI.money.copyWith(color: low ? AppColors.error : AppColors.primary)),
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

// ── Absentees ────────────────────────────────────────────────────────────────
class _AbsenteesTab extends StatefulWidget {
  final Map<String, dynamic> l;
  const _AbsenteesTab({required this.l});

  @override
  State<_AbsenteesTab> createState() => _AbsenteesTabState();
}

class _AbsenteesTabState extends State<_AbsenteesTab> {
  late DateTime _from = attParse(widget.l['today']) ?? attOnly(DateTime.now());
  late DateTime _to = _from;
  int? _cla;
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await AttendanceService.absentees(_from, _to, claId: _cla);
      if (mounted) {
        setState(() {
          _rows = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final secs = [(null as int?, 'All sections'), for (final s in _setUpSections(widget.l)) (attInt(s['cla_id']) as int?, attText(s['claname']))];
    return AttCard(
      icon: 'user-remove',
      title: 'Absentees',
      subtitle: 'Every session missed (absent, leave ...) in submitted registers -- at most three months at a time',
      trailing: [
        SizedBox(width: 160.w, child: AttDateField(key: const ValueKey('abs-from'), value: _from, onPicked: (d) {
          setState(() {
            _from = d;
            if (_to.isBefore(d)) _to = d;
          });
          _load();
        })),
        Text('to', style: AppUI.muted),
        SizedBox(width: 160.w, child: AttDateField(value: _to, first: _from, onPicked: (d) {
          setState(() => _to = d);
          _load();
        })),
        SizedBox(width: 160.w, child: _drop<int?>(context, _cla, secs, (v) {
          setState(() => _cla = v);
          _load();
        })),
        _exportButton(
            context,
            _rows.isNotEmpty,
            () => exportAttTable('Absentees', ['Date', 'Session', 'Adm No', 'Student', 'Section', 'Status', 'Remarks', 'Parent mobile'], [
                  for (final r in _rows)
                    [attShow(r['att_date']), attText(r['session_code']), attText(r['stuadmno']), attText(r['stuname']), attText(r['claname']),
                      attText(r['status_name']), attText(r['remarks']), attText(r['mobile'])],
                ])),
      ],
      child: _loading
          ? const AppLoading()
          : _error != null
              ? AppUI.empty(title: 'Could not load absentees', why: _error, icon: 'warning-2')
              : _rows.isEmpty
                  ? AppUI.empty(title: 'Nobody missed a session on these dates', icon: 'user-remove')
                  : Column(children: [
                      attHeadRow([
                        AppUI.th('Date', flex: 2),
                        AppUI.th('Session'),
                        AppUI.th('Adm No', flex: 2),
                        AppUI.th('Student', flex: 4),
                        AppUI.th('Section', flex: 2),
                        AppUI.th('Status', flex: 3),
                        AppUI.th('Remarks', flex: 3),
                        AppUI.th('Parent mobile', flex: 2),
                      ]),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _rows.length,
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            return Container(
                              color: i.isEven ? Colors.white : AppColors.surface,
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                              child: Row(children: [
                                Expanded(flex: 2, child: Text(attShow(r['att_date']), style: AppUI.cell)),
                                Expanded(child: Text(attText(r['session_code']), style: AppUI.cell)),
                                Expanded(flex: 2, child: Text(attText(r['stuadmno']), style: AppUI.mono)),
                                Expanded(flex: 4, child: Text(attText(r['stuname']), style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                                Expanded(flex: 2, child: Text(attText(r['claname']), style: AppUI.cell)),
                                Expanded(flex: 3, child: Text(attText(r['status_name']), style: AppUI.cell)),
                                Expanded(flex: 3, child: Text(attText(r['remarks']), style: AppUI.muted, overflow: TextOverflow.ellipsis)),
                                Expanded(flex: 2, child: Text(attText(r['mobile']), style: AppUI.mono)),
                              ]),
                            );
                          },
                        ),
                      ),
                    ]),
    );
  }
}

// ── Monthly Register ─────────────────────────────────────────────────────────
class _RegisterTab extends StatefulWidget {
  final Map<String, dynamic> l;
  const _RegisterTab({required this.l});

  @override
  State<_RegisterTab> createState() => _RegisterTabState();
}

class _RegisterTabState extends State<_RegisterTab> {
  int? _cla;
  late DateTime _month;
  Map<String, dynamic>? _r;
  bool _loading = false;
  String? _error;
  final _h = ScrollController();

  @override
  void initState() {
    super.initState();
    final t = attParse(widget.l['today']) ?? DateTime.now();
    _month = DateTime(t.year, t.month);
    final secs = _setUpSections(widget.l);
    if (secs.isNotEmpty) {
      _cla = attInt(secs.first['cla_id']);
      _load();
    }
  }

  @override
  void dispose() {
    _h.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cla = _cla;
    if (cla == null) return;
    setState(() => _loading = true);
    try {
      final r = await AttendanceService.monthRegister(cla, _month);
      if (mounted) {
        setState(() {
          _r = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _days => [for (final d in (_r?['days'] as List? ?? const [])) if (d is Map) Map<String, dynamic>.from(d)];
  List<Map<String, dynamic>> get _students => [for (final s in (_r?['students'] as List? ?? const [])) if (s is Map) Map<String, dynamic>.from(s)];

  String _mark(Map<String, dynamic> s, DateTime d, String ses) {
    final m = s['marks'] is Map ? s['marks'] as Map : const {};
    return attText(m['${AttendanceService.day(d)} $ses']);
  }

  Future<String?> _export() {
    final days = _days;
    final sec = _setUpSections(widget.l).firstWhere((s) => attInt(s['cla_id']) == _cla, orElse: () => const {});
    return exportAttTable('Register ${attText(sec['claname'])} ${kAttMonths[_month.month - 1]} ${_month.year}', [
      'S.No', 'Adm No', 'Student',
      for (final d in days) ...['${attParse(d['date'])!.day} FN', '${attParse(d['date'])!.day} AN'],
      'Working sessions', 'Present sessions',
    ], [
      for (var i = 0; i < _students.length; i++)
        [
          i + 1,
          attText(_students[i]['stuadmno']),
          attText(_students[i]['stuname']),
          for (final d in days) ...[_mark(_students[i], attParse(d['date'])!, 'FN'), _mark(_students[i], attParse(d['date'])!, 'AN')],
          attInt(_students[i]['working_sessions']),
          attInt(_students[i]['present_sessions']),
        ],
    ]);
  }

  Widget _cell(String code, bool working) {
    final s = _statusOf(code);
    return Container(
      width: 22,
      height: 18,
      alignment: Alignment.center,
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: !working ? AppColors.surface : (code.isEmpty ? Colors.transparent : attStatusColor(s).withValues(alpha: code == 'P' ? 0.10 : 0.85)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(code, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: code == 'P' ? AppColors.primary : Colors.white)),
    );
  }

  Map<String, dynamic>? _statusOf(String code) {
    for (final s in _list(widget.l, 'statuses')) {
      if (s['status_code'] == code) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final secs = _setUpSections(widget.l);
    final days = _days;
    final students = _students;
    const nameW = 220.0, colW = 48.0, totW = 70.0;
    return AttCard(
      icon: 'grid-1',
      title: 'Monthly Register',
      subtitle: '${kAttMonths[_month.month - 1]} ${_month.year} -- FN on top, AN below; grey = not a working session',
      trailing: [
        SizedBox(width: 160.w, child: _drop<int>(context, _cla, [for (final s in secs) (attInt(s['cla_id']), attText(s['claname']))], (v) {
          setState(() => _cla = v);
          _load();
        }, key: const ValueKey('reg-section'))),
        IconButton(tooltip: 'Previous month', onPressed: () {
          setState(() => _month = DateTime(_month.year, _month.month - 1));
          _load();
        }, icon: const Icon(Icons.chevron_left)),
        IconButton(tooltip: 'Next month', onPressed: () {
          setState(() => _month = DateTime(_month.year, _month.month + 1));
          _load();
        }, icon: const Icon(Icons.chevron_right)),
        _exportButton(context, students.isNotEmpty, _export),
      ],
      child: secs.isEmpty
          ? AppUI.empty(title: 'No sections take attendance yet', icon: 'grid-1')
          : _loading
              ? const AppLoading()
              : _error != null
                  ? AppUI.empty(title: 'Could not load the register', why: _error, icon: 'warning-2')
                  : students.isEmpty
                      ? AppUI.empty(title: 'No students', icon: 'grid-1')
                      : Scrollbar(
                          controller: _h,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _h,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: nameW + days.length * colW + totW * 2 + 32,
                              child: Column(children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  decoration: AppUI.tableHeadBar,
                                  child: Row(children: [
                                    SizedBox(width: nameW, child: Text('STUDENT', style: AppUI.tableHead)),
                                    for (final d in days)
                                      SizedBox(
                                        width: colW,
                                        child: Column(children: [
                                          Text('${attParse(d['date'])!.day}', style: AppUI.tableHead),
                                          Text(kAttWeekdays[attParse(d['date'])!.weekday - 1].substring(0, 2), style: AppUI.tableHead.copyWith(fontSize: 9)),
                                        ]),
                                      ),
                                    SizedBox(width: totW, child: Text('WORKED', textAlign: TextAlign.right, style: AppUI.tableHead)),
                                    SizedBox(width: totW, child: Text('PRESENT', textAlign: TextAlign.right, style: AppUI.tableHead)),
                                  ]),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    itemCount: students.length,
                                    itemBuilder: (_, i) {
                                      final s = students[i];
                                      return Container(
                                        color: i.isEven ? Colors.white : AppColors.surface,
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                                        child: Row(children: [
                                          SizedBox(
                                            width: nameW,
                                            child: Text('${attText(s['stuname'])} (${attText(s['stuadmno'])})',
                                                style: AppUI.cell, maxLines: 1, overflow: TextOverflow.ellipsis),
                                          ),
                                          for (final d in days)
                                            SizedBox(
                                              width: colW,
                                              child: Column(children: [
                                                _cell(_mark(s, attParse(d['date'])!, 'FN'), d['fn_working'] == true),
                                                _cell(_mark(s, attParse(d['date'])!, 'AN'), d['an_working'] == true),
                                              ]),
                                            ),
                                          SizedBox(width: totW, child: Text('${attInt(s['working_sessions'])}', textAlign: TextAlign.right, style: AppUI.money)),
                                          SizedBox(width: totW, child: Text('${attInt(s['present_sessions'])}', textAlign: TextAlign.right, style: AppUI.money)),
                                        ]),
                                      );
                                    },
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
    );
  }
}
