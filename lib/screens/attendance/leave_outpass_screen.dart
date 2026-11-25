import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/attendance_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/pill_tab.dart';
import 'attendance_common.dart';

/// LEAVE & OUT-PASS (school_attendance_api.sql, 'Leave & Out-pass' menu).
///
/// Leave: a student's long leave (medical, family ...), entered by the office
/// for the parent, approved by the class in-charge and then -- when the
/// student's division has one -- the division in-charge; the office records
/// each step. An approved leave turns the student's Absent into Leave on the
/// registers already entered, and is suggested on new ones.
///
/// Out-pass: a student taken home during the day, with who took them. A
/// student out before the AN start is suggested Absent for AN.
class LeaveOutpassScreen extends StatefulWidget {
  const LeaveOutpassScreen({super.key});

  @override
  State<LeaveOutpassScreen> createState() => _LeaveOutpassScreenState();
}

class _LeaveOutpassScreenState extends State<LeaveOutpassScreen> {
  int _tab = 0;
  List<Map<String, dynamic>>? _students;

  Future<List<Map<String, dynamic>>> _studentList() async => _students ??= await AttendanceService.students();

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(spacing: PillTab.gap(context), children: [
            PillTab(key: const ValueKey('lo-tab-leave'), icon: 'calendar-remove', label: 'Leave', selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
            PillTab(key: const ValueKey('lo-tab-outpass'), icon: 'logout', label: 'Out-pass', selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
          ]),
        ),
        SizedBox(height: 6.h),
        Expanded(child: _tab == 0 ? _LeaveTab(students: _studentList) : _OutpassTab(students: _studentList)),
      ]);
}

/// Picks a student by name or admission number.
class _StudentField extends StatelessWidget {
  final List<Map<String, dynamic>> students;
  final Map<String, dynamic>? value;
  final ValueChanged<Map<String, dynamic>> onPicked;
  const _StudentField({required this.students, required this.value, required this.onPicked});

  static String label(Map<String, dynamic> s) =>
      '${attText(s['stuname'])} (${attText(s['stuadmno'])})${attText(s['stuclass']).isEmpty ? '' : ' · ${attText(s['stuclass'])}'}';

  @override
  Widget build(BuildContext context) => RawAutocomplete<Map<String, dynamic>>(
        initialValue: TextEditingValue(text: value == null ? '' : label(value!)),
        displayStringForOption: label,
        optionsBuilder: (v) {
          final q = v.text.trim().toLowerCase();
          if (q.isEmpty) return const [];
          return students.where((s) => '${s['stuname']} ${s['stuadmno']}'.toLowerCase().contains(q)).take(30);
        },
        onSelected: onPicked,
        fieldViewBuilder: (ctx, c, f, _) => TextField(
          key: const ValueKey('lo-student'),
          controller: c,
          focusNode: f,
          style: AppUI.fieldText(ctx, filled: value != null),
          decoration: AppUI.field(ctx, 'Type a name or admission no.', filled: value != null, leadingIcon: 'search-normal'),
        ),
        optionsViewBuilder: (ctx, onSel, opts) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280, maxWidth: 440),
              child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                for (final o in opts) ListTile(dense: true, title: Text(label(o), style: AppUI.body), onTap: () => onSel(o)),
              ]),
            ),
          ),
        ),
      );
}

Widget _field(String label, Widget child, {bool required = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [AppUI.fieldLabel(label, required: required), child]),
    );

Widget _drop<T>(BuildContext context, T? value, List<(T, String)> items, ValueChanged<T?> onChanged, {String hint = 'Select', Key? key}) => AppDropdownField<T>(
      key: key,
      initialValue: items.any((i) => i.$1 == value) ? value : null,
      isExpanded: true,
      decoration: AppUI.field(context, hint, filled: value != null, dense: true),
      style: AppUI.fieldText(context),
      items: [for (final i in items) DropdownMenuItem(value: i.$1, child: Text(i.$2, overflow: TextOverflow.ellipsis))],
      onChanged: onChanged,
    );

// ── leave ────────────────────────────────────────────────────────────────────
class _LeaveTab extends StatefulWidget {
  final Future<List<Map<String, dynamic>>> Function() students;
  const _LeaveTab({required this.students});

  @override
  State<_LeaveTab> createState() => _LeaveTabState();
}

class _LeaveTabState extends State<_LeaveTab> {
  String? _status = 'PENDING';
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  String? _error;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await AttendanceService.leaves(status: _status);
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

  Future<void> _edit([Map<String, dynamic>? l]) async {
    List<Map<String, dynamic>> students;
    try {
      students = await widget.students();
    } catch (e) {
      if (mounted) attError(context, e);
      return;
    }
    if (!mounted) return;
    Map<String, dynamic>? student = l == null ? null : {'stu_id': l['stu_id'], 'stuname': l['stuname'], 'stuadmno': l['stuadmno'], 'stuclass': l['claname']};
    var type = attText(l?['leave_type']).isEmpty ? 'MEDICAL' : attText(l?['leave_type']);
    DateTime? from = attParse(l?['from_date']) ?? attOnly(DateTime.now());
    DateTime? to = attParse(l?['to_date']) ?? from;
    var fs = attText(l?['from_session']).isEmpty ? 'FN' : attText(l?['from_session']);
    var ts = attText(l?['to_session']).isEmpty ? 'AN' : attText(l?['to_session']);
    final reason = TextEditingController(text: attText(l?['reason']));
    final by = TextEditingController(text: attText(l?['requested_by_name']));
    var cert = l == null ? true : l['certificate_required'] == true;
    const sessions = [('FN', 'FN (forenoon)'), ('AN', 'AN (afternoon)')];
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(l == null ? 'New Leave' : 'Edit Leave'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _field('Student', l != null ? Text(_StudentField.label(student!), style: AppUI.label)
                    : _StudentField(students: students, value: student, onPicked: (s) => set(() => student = s)), required: true),
                _field('Kind of leave', _drop<String>(ctx, type, [for (final e in kAttLeaveTypes.entries) (e.key, e.value)], (v) => set(() {
                      type = v ?? type;
                      cert = type == 'MEDICAL';
                    })), required: true),
                Row(children: [
                  Expanded(flex: 3, child: _field('From', AttDateField(value: from, onPicked: (d) => set(() {
                        from = d;
                        if (to != null && to!.isBefore(d)) to = d;
                      })), required: true)),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: _field('', _drop<String>(ctx, fs, sessions, (v) => set(() => fs = v ?? fs)))),
                ]),
                Row(children: [
                  Expanded(flex: 3, child: _field('To', AttDateField(value: to, first: from, onPicked: (d) => set(() => to = d)), required: true)),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: _field('', _drop<String>(ctx, ts, sessions, (v) => set(() => ts = v ?? ts)))),
                ]),
                _field('Reason', TextField(key: const ValueKey('leave-reason'), controller: reason, maxLines: 2, style: AppUI.fieldText(ctx),
                    decoration: AppUI.field(ctx, 'e.g. Fever, doctor advised rest')), required: true),
                _field('Asked by (parent / guardian)', TextField(controller: by, maxLength: 120, style: AppUI.fieldText(ctx),
                    decoration: AppUI.field(ctx, 'Name').copyWith(counterText: ''))),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: cert,
                  onChanged: (v) => set(() => cert = v ?? false),
                  title: Text('A certificate is needed', style: AppUI.body),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppText.cancel)),
            if (l == null) OutlinedButton(style: AppUI.secondary(ctx), onPressed: () => Navigator.pop(ctx, 'draft'), child: const Text('Save as Draft')),
            ElevatedButton(
              key: const ValueKey('leave-save'),
              style: AppUI.primary(ctx),
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: Text(l == null ? 'Save & Send for Approval' : 'Save'),
            ),
          ],
        ),
      ),
    );
    if (r == null) return;
    if (student == null) {
      if (mounted) attSnack(context, 'Pick the student.', error: true);
      return;
    }
    try {
      await AttendanceService.saveLeave({
        if (l != null) 'leave_id': attInt(l['leave_id']),
        'stu_id': attInt(student!['stu_id']),
        'leave_type': type,
        'from_date': from == null ? null : AttendanceService.day(from!),
        'from_session': fs,
        'to_date': to == null ? null : AttendanceService.day(to!),
        'to_session': ts,
        'reason': reason.text.trim(),
        'requested_by_name': by.text.trim(),
        'certificate_required': cert,
        'draft': r == 'draft',
      });
      if (!mounted) return;
      attSnack(context, r == 'draft' ? 'Leave saved as a draft.' : 'Leave saved.');
      await _load();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  Future<void> _act(Map<String, dynamic> l, String action) async {
    String? remarks;
    if (action == 'REJECT' || action == 'RETURN') {
      remarks = await askAttReason(context, title: action == 'REJECT' ? 'Reject this leave' : 'Return for correction');
      if (remarks == null) return;
    } else if (action == 'CANCEL') {
      if (!await confirmAtt(context, title: 'Cancel this leave?', message: '${attText(l['stuname'])}: ${_dates(l)}', ok: 'Cancel Leave', danger: true)) return;
    }
    try {
      final s = await AttendanceService.actOnLeave(attInt(l['leave_id']), action, remarks: remarks);
      if (!mounted) return;
      attSnack(context, 'Leave: ${kAttLeaveStatus[s] ?? s}.');
      await _load();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  static String _dates(Map<String, dynamic> l) {
    final f = '${attShow(l['from_date'])} ${attText(l['from_session'])}';
    final t = '${attShow(l['to_date'])} ${attText(l['to_session'])}';
    return f == t ? f : '$f to $t';
  }

  AppStatus _look(String s) => switch (s) {
        'APPROVED' => AppStatus.success,
        'REJECTED' || 'CANCELLED' => AppStatus.danger,
        'DRAFT' => AppStatus.neutral,
        _ => AppStatus.warning,
      };

  Widget _actions(Map<String, dynamic> l) {
    final s = attText(l['status']);
    final pending = s.startsWith('PENDING');
    final approvals = (l['approvals'] as List? ?? const []).where((a) => a is Map && a['action'] == 'APPROVED').length;
    return Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
      if (pending)
        ElevatedButton(
          key: ValueKey('leave-approve-${l['leave_id']}'),
          style: AppUI.primary(context),
          onPressed: () => _act(l, 'APPROVE'),
          child: const Text('Approve'),
        ),
      if (s == 'DRAFT') OutlinedButton(style: AppUI.secondary(context), onPressed: () => _act(l, 'SUBMIT'), child: const Text('Send')),
      PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (a) => a == 'EDIT' ? _edit(l) : _act(l, a),
        itemBuilder: (_) => [
          if ((s == 'DRAFT' || s == 'PENDING_CLASS_INCHARGE') && approvals == 0) const PopupMenuItem(value: 'EDIT', child: Text('Edit')),
          if (pending) const PopupMenuItem(value: 'REJECT', child: Text('Reject')),
          if (pending) const PopupMenuItem(value: 'RETURN', child: Text('Return for correction')),
          if (s != 'CANCELLED' && s != 'REJECTED') const PopupMenuItem(value: 'CANCEL', child: Text('Cancel leave')),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final rows = q.isEmpty ? _rows : _rows.where((r) => '${r['stuname']} ${r['stuadmno']} ${r['claname']}'.toLowerCase().contains(q)).toList();
    return AttCard(
      icon: 'calendar-remove',
      title: 'Leave Applications',
      subtitle: 'Class in-charge, then division in-charge (when the division has one)',
      trailing: [
        SizedBox(width: 220.w, child: AppSearchField(controller: _search, hintText: 'Search student', onChanged: (_) => setState(() {}))),
        SizedBox(
          width: 200.w,
          child: _drop<String?>(context, _status, [
            ('PENDING', 'Waiting for approval'),
            ('APPROVED', 'Approved'),
            ('DRAFT', 'Drafts'),
            ('REJECTED', 'Rejected'),
            ('CANCELLED', 'Cancelled'),
            (null, 'All'),
          ], (v) {
            setState(() => _status = v);
            _load();
          }, key: const ValueKey('leave-filter')),
        ),
        ElevatedButton.icon(
          key: const ValueKey('leave-new'),
          style: AppUI.primary(context),
          onPressed: () => _edit(),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('New Leave'),
        ),
      ],
      child: _loading
          ? const AppLoading()
          : _error != null
              ? AppUI.empty(title: 'Could not load leave', why: _error, icon: 'warning-2')
              : rows.isEmpty
                  ? AppUI.empty(title: 'No leave here', why: 'New Leave enters one for a parent.', icon: 'calendar-remove')
                  : Column(children: [
                      attHeadRow([
                        AppUI.th('Student', flex: 4),
                        AppUI.th('Leave', flex: 4),
                        AppUI.th('Reason', flex: 3),
                        AppUI.th('Status', flex: 4),
                        AppUI.th('', flex: 4),
                      ]),
                      Expanded(
                        child: ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                          itemBuilder: (_, i) {
                            final l = rows[i];
                            final approvals = [
                              for (final a in (l['approvals'] as List? ?? const []))
                                if (a is Map)
                                  '${a['approval_level'] == 1 ? 'Class' : 'Division'}: ${attText(a['action']).toLowerCase()}'
                                      '${attText(a['remarks']).isEmpty ? '' : ' (${attText(a['remarks'])})'}',
                            ];
                            return Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                              child: Row(children: [
                                Expanded(
                                  flex: 4,
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(attText(l['stuname']), style: AppUI.label),
                                    Text('${attText(l['stuadmno'])} · ${attText(l['claname'])}', style: AppUI.muted),
                                  ]),
                                ),
                                Expanded(
                                  flex: 4,
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(kAttLeaveTypes[l['leave_type']] ?? attText(l['leave_type']), style: AppUI.cell),
                                    Text(_dates(l), style: AppUI.muted),
                                  ]),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(attText(l['reason']), style: AppUI.cell, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    if (attText(l['requested_by_name']).isNotEmpty) Text('Asked by ${attText(l['requested_by_name'])}', style: AppUI.muted),
                                  ]),
                                ),
                                Expanded(
                                  flex: 4,
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    AppUI.chip(kAttLeaveStatus[l['status']] ?? attText(l['status']), _look(attText(l['status']))),
                                    if (approvals.isNotEmpty) Text(approvals.join(' · '), style: AppUI.muted, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  ]),
                                ),
                                Expanded(flex: 4, child: _actions(l)),
                              ]),
                            );
                          },
                        ),
                      ),
                    ]),
    );
  }
}

// ── out-pass ─────────────────────────────────────────────────────────────────
class _OutpassTab extends StatefulWidget {
  final Future<List<Map<String, dynamic>>> Function() students;
  const _OutpassTab({required this.students});

  @override
  State<_OutpassTab> createState() => _OutpassTabState();
}

class _OutpassTabState extends State<_OutpassTab> {
  DateTime _from = attOnly(DateTime.now());
  DateTime _to = attOnly(DateTime.now());
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
      final r = await AttendanceService.outpasses(from: _from, to: _to);
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

  static String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _show(dynamic t) {
    final p = attText(t).split(':');
    if (p.length < 2) return attText(t);
    final h = int.tryParse(p[0]) ?? 0;
    return '${h % 12 == 0 ? 12 : h % 12}:${p[1]} ${h < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _edit([Map<String, dynamic>? o]) async {
    List<Map<String, dynamic>> students;
    try {
      students = await widget.students();
    } catch (e) {
      if (mounted) attError(context, e);
      return;
    }
    if (!mounted) return;
    Map<String, dynamic>? student = o == null ? null : {'stu_id': o['stu_id'], 'stuname': o['stuname'], 'stuadmno': o['stuadmno'], 'stuclass': o['claname']};
    DateTime date = attParse(o?['out_date']) ?? attOnly(DateTime.now());
    final p = attText(o?['out_time']).split(':');
    var time = p.length > 1 ? TimeOfDay(hour: int.tryParse(p[0]) ?? 0, minute: int.tryParse(p[1]) ?? 0) : TimeOfDay.now();
    var cat = attText(o?['reason_category']).isEmpty ? 'SICKNESS' : attText(o?['reason_category']);
    var sess = attText(o?['leave_session']).isEmpty ? 'AN' : attText(o?['leave_session']);
    final reason = TextEditingController(text: attText(o?['reason']));
    final name = TextEditingController(text: attText(o?['picked_up_by_name']));
    final rel = TextEditingController(text: attText(o?['picked_up_by_relation']));
    final mob = TextEditingController(text: attText(o?['picked_up_by_mobile']));
    final proof = TextEditingController(text: attText(o?['id_proof_ref']));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(o == null ? 'New Out-pass' : 'Edit Out-pass ${attText(o['outpass_no'])}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _field('Student', o != null ? Text(_StudentField.label(student!), style: AppUI.label)
                    : _StudentField(students: students, value: student, onPicked: (s) => set(() => student = s)), required: true),
                Row(children: [
                  Expanded(child: _field('Date', AttDateField(value: date, last: attOnly(DateTime.now()), onPicked: (d) => set(() => date = d)), required: true)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                        'Time out',
                        InkWell(
                          onTap: () async {
                            final t = await showTimePicker(context: ctx, initialTime: time);
                            if (t != null) set(() => time = t);
                          },
                          child: InputDecorator(
                              decoration: AppUI.field(ctx, '', filled: true, leadingIcon: 'clock'),
                              child: Text(time.format(ctx), style: AppUI.fieldText(ctx, filled: true))),
                        ),
                        required: true),
                  ),
                ]),
                Row(children: [
                  Expanded(child: _field('Reason', _drop<String>(ctx, cat, [for (final e in kAttOutpassReasons.entries) (e.key, e.value)], (v) => set(() => cat = v ?? cat)),
                      required: true)),
                  const SizedBox(width: 12),
                  Expanded(child: _field('Leaves during', _drop<String>(ctx, sess, const [('FN', 'FN (forenoon)'), ('AN', 'AN (afternoon)')], (v) => set(() => sess = v ?? sess)))),
                ]),
                _field('Details', TextField(controller: reason, maxLength: 500, style: AppUI.fieldText(ctx), decoration: AppUI.field(ctx, 'Optional').copyWith(counterText: ''))),
                _field('Taken by', TextField(key: const ValueKey('op-name'), controller: name, maxLength: 120, style: AppUI.fieldText(ctx),
                    decoration: AppUI.field(ctx, 'Name').copyWith(counterText: '')), required: true),
                Row(children: [
                  Expanded(child: _field('Relation', TextField(controller: rel, maxLength: 40, style: AppUI.fieldText(ctx), decoration: AppUI.field(ctx, 'e.g. Father').copyWith(counterText: '')))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field('Mobile', TextField(controller: mob, maxLength: 10, style: AppUI.fieldText(ctx),
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: AppUI.field(ctx, '10 digits').copyWith(counterText: ''))),
                  ),
                ]),
                _field('ID proof', TextField(controller: proof, maxLength: 60, style: AppUI.fieldText(ctx), decoration: AppUI.field(ctx, 'e.g. Aadhaar last 4 digits').copyWith(counterText: ''))),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
            ElevatedButton(key: const ValueKey('op-save'), style: AppUI.primary(ctx), onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (student == null) {
      if (mounted) attSnack(context, 'Pick the student.', error: true);
      return;
    }
    try {
      final r = await AttendanceService.saveOutpass({
        if (o != null) 'outpass_id': attInt(o['outpass_id']),
        'stu_id': attInt(student!['stu_id']),
        'out_date': AttendanceService.day(date),
        'out_time': _hm(time),
        'reason_category': cat,
        'reason': reason.text.trim(),
        'picked_up_by_name': name.text.trim(),
        'picked_up_by_relation': rel.text.trim(),
        'picked_up_by_mobile': mob.text.trim(),
        'id_proof_ref': proof.text.trim(),
        'leave_session': sess,
      });
      if (!mounted) return;
      attSnack(context, 'Out-pass ${attText(r['outpass_no'])} saved.');
      await _load();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  Future<void> _cancel(Map<String, dynamic> o) async {
    if (!await confirmAtt(context, title: 'Cancel out-pass ${attText(o['outpass_no'])}?', message: attText(o['stuname']), ok: 'Cancel Out-pass', danger: true)) return;
    try {
      await AttendanceService.cancelOutpass(attInt(o['outpass_id']));
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) attError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AttCard(
        icon: 'logout',
        title: 'Out-pass',
        subtitle: 'Students taken home during the day',
        trailing: [
          SizedBox(width: 160.w, child: AttDateField(value: _from, onPicked: (d) {
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
          ElevatedButton.icon(
            key: const ValueKey('op-new'),
            style: AppUI.primary(context),
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('New Out-pass'),
          ),
        ],
        child: _loading
            ? const AppLoading()
            : _error != null
                ? AppUI.empty(title: 'Could not load out-passes', why: _error, icon: 'warning-2')
                : _rows.isEmpty
                    ? AppUI.empty(title: 'No out-passes on these dates', icon: 'logout')
                    : Column(children: [
                        attHeadRow([
                          AppUI.th('No.', flex: 2),
                          AppUI.th('When', flex: 3),
                          AppUI.th('Student', flex: 4),
                          AppUI.th('Taken by', flex: 4),
                          AppUI.th('Reason', flex: 3),
                          AppUI.th('Status', flex: 2),
                          AppUI.th('', flex: 2),
                        ]),
                        Expanded(
                          child: ListView.separated(
                            itemCount: _rows.length,
                            separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                            itemBuilder: (_, i) {
                              final o = _rows[i];
                              final issued = o['status'] == 'ISSUED';
                              return Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                                child: Row(children: [
                                  Expanded(flex: 2, child: Text(attText(o['outpass_no']), style: AppUI.mono)),
                                  Expanded(flex: 3, child: Text('${attShow(o['out_date'])}\n${_show(o['out_time'])}', style: AppUI.cell)),
                                  Expanded(
                                    flex: 4,
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(attText(o['stuname']), style: AppUI.label),
                                      Text('${attText(o['stuadmno'])} · ${attText(o['claname'])}', style: AppUI.muted),
                                    ]),
                                  ),
                                  Expanded(
                                    flex: 4,
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(attText(o['picked_up_by_name']), style: AppUI.cell),
                                      Text([attText(o['picked_up_by_relation']), attText(o['picked_up_by_mobile'])].where((x) => x.isNotEmpty).join(' · '),
                                          style: AppUI.muted),
                                    ]),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                        '${kAttOutpassReasons[o['reason_category']] ?? attText(o['reason_category'])}'
                                        '${attText(o['reason']).isEmpty ? '' : ': ${attText(o['reason'])}'}',
                                        style: AppUI.cell,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: AppUI.chip(issued ? 'Issued' : 'Cancelled', issued ? AppStatus.success : AppStatus.danger))),
                                  Expanded(
                                    flex: 2,
                                    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                      if (issued) IconButton(tooltip: 'Edit', onPressed: () => _edit(o), icon: const Icon(Icons.edit_outlined, size: 18)),
                                      if (issued)
                                        IconButton(tooltip: 'Cancel', onPressed: () => _cancel(o), icon: const Icon(Icons.block, size: 18, color: AppColors.error)),
                                    ]),
                                  ),
                                ]),
                              );
                            },
                          ),
                        ),
                      ]),
      );
}
