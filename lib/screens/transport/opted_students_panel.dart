import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// True for a student whose transport mode is BUS. Imported data has it with
/// stray spaces and in either case (' BUS').
bool trOptedBus(Map<String, dynamic> s) => trText(s['transportmode']).toUpperCase() == 'BUS';

/// OPTED STUDENTS (the left tab of Student Enrollment) -- the year's active
/// students who chose the school bus (students.transportmode = 'BUS'), in
/// class order: S.No, class, admission number and name.
///
/// Add Students ticks any number of the other students; they join the list
/// marked "Not saved", and Save sets their transport mode to BUS. Only the
/// students opted here can be added to a route in Student Enrollment.
class OptedStudentsPanel extends StatefulWidget {
  /// Where the year's active students come from; the tests give their own.
  final Future<List<Map<String, dynamic>>> Function()? load;

  /// Sets the transport mode of these students to BUS; the tests give their own.
  final Future<void> Function(List<int> studentIds)? save;

  /// The ids of the opted students, after each load (so after each save).
  final ValueChanged<Set<int>>? onOptedChanged;
  const OptedStudentsPanel({super.key, this.load, this.save, this.onOptedChanged});

  /// The session year's active students, in class order, each with its
  /// transport mode.
  static Future<List<Map<String, dynamic>>> fetch() => SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
      .select('stu_id, stuadmno, stuname, stuclass, cla_id, transportmode')
      .eq('activestatus', 1)
      .eq('preadmission', 0)
      .order('cla_id')
      .order('stuname')
      .order('stu_id'));

  static Future<void> _saveBus(List<int> ids) async {
    for (final id in ids) {
      await SupabaseService.updateStudent(id, {'transportmode': 'BUS'});
    }
  }

  @override
  State<OptedStudentsPanel> createState() => _OptedStudentsPanelState();
}

class _OptedStudentsPanelState extends State<OptedStudentsPanel> {
  /// The year's active students, in class order.
  List<Map<String, dynamic>> _all = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String _query = '';
  String? _class;

  /// Added here and not saved yet.
  final Set<int> _pending = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = [
        for (final r in await (widget.load ?? OptedStudentsPanel.fetch)())
          if (trId(r['stu_id']) != null) r,
      ];
      if (!mounted) return;
      setState(() {
        _all = rows;
        // gone from the year, or opted meanwhile
        _pending.removeWhere((id) => !rows.any((r) => trId(r['stu_id']) == id && !trOptedBus(r)));
        _loading = false;
        _error = null;
      });
      widget.onOptedChanged?.call({
        for (final r in rows)
          if (trOptedBus(r)) trId(r['stu_id'])!,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  void _reload() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
  }

  bool _isPending(Map<String, dynamic> s) => _pending.contains(trId(s['stu_id']));

  /// The opted students and the ones added but not saved, in class order.
  List<Map<String, dynamic>> get _listed => [
        for (final s in _all)
          if (trOptedBus(s) || _isPending(s)) s,
      ];

  List<Map<String, dynamic>> _shown(List<Map<String, dynamic>> listed) {
    final q = _query.trim().toLowerCase();
    return [
      for (final s in listed)
        if ((_class == null || trText(s['stuclass']) == _class) && (q.isEmpty || '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q))) s,
    ];
  }

  Future<void> _addStudents() async {
    final picked = await showDialog<List<int>>(
      context: context,
      builder: (_) => _PickStudentsDialog(students: [
        for (final s in _all)
          if (!trOptedBus(s) && !_isPending(s)) s,
      ]),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      _pending.addAll(picked);
      _class = null; // a class filter could hide them
    });
    trSnack(context, '${picked.length} student${picked.length == 1 ? '' : 's'} added. Save to opt them for the bus.', AppColors.success);
  }

  Future<void> _save() async {
    final ids = _pending.toList();
    if (ids.isEmpty) return;
    setState(() => _saving = true);
    try {
      await (widget.save ?? OptedStudentsPanel._saveBus)(ids);
      if (!mounted) return;
      _pending.clear();
      trSnack(context, '${ids.length} student${ids.length == 1 ? '' : 's'} opted for the bus.', AppColors.success);
    } catch (e) {
      if (mounted) trSnack(context, AppText.couldNot('save the students', friendlyError(e)), AppColors.error);
    }
    // what the server has now: after a failure part-way, the saved ones show as opted
    await _load();
    if (mounted) setState(() => _saving = false);
  }

  Widget _toolbar(List<String> classes) => Row(children: [
        Expanded(child: TrSearchField(hint: 'Adm no or name', onChanged: (v) => setState(() => _query = v))),
        SizedBox(width: 12.w),
        SizedBox(
          width: 210,
          child: AppDropdownField<String?>(
            key: ValueKey('opted-class-$_class-${classes.length}'),
            initialValue: classes.contains(_class) ? _class : null,
            isExpanded: true,
            menuMaxHeight: 400,
            dropdownColor: AppColors.card,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            style: AppUI.fieldText(context),
            decoration: AppUI.field(context, '', filled: _class != null),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All classes')),
              for (final c in classes) DropdownMenuItem<String?>(value: c, child: Text(c, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _class = v),
          ),
        ),
      ]);

  Widget _head() => Container(
        decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
        child: Row(children: [
          SizedBox(width: 70, child: Text('S.NO', style: AppUI.tableHead)),
          SizedBox(width: 150, child: Text('CLASS', style: AppUI.tableHead)),
          SizedBox(width: 160, child: Text('ADMISSION NO', style: AppUI.tableHead)),
          Expanded(child: Text('STUDENT NAME', style: AppUI.tableHead)),
          const SizedBox(width: 170),
        ]),
      );

  Widget _row(Map<String, dynamic> s, int i) {
    final id = trId(s['stu_id'])!;
    final fresh = _pending.contains(id);
    return Container(
      key: ValueKey('opted-$id'),
      decoration: BoxDecoration(
        color: fresh ? AppColors.primarySoft : (i.isEven ? Colors.white : AppColors.surface),
        border: const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 12.w),
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(children: [
        SizedBox(width: 70, child: Text('${i + 1}', style: AppUI.cell)),
        SizedBox(width: 150, child: Text(trText(s['stuclass']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
        SizedBox(width: 160, child: Text(trText(s['stuadmno']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
        Expanded(child: Text(trText(s['stuname']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
        SizedBox(
          width: 170,
          child: !fresh
              ? null
              : Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  AppUI.chip('Not saved', AppStatus.warning),
                  IconButton(
                    tooltip: 'Take off the list',
                    visualDensity: VisualDensity.compact,
                    onPressed: _saving ? null : () => setState(() => _pending.remove(id)),
                    icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.ink3),
                  ),
                ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Opted Students',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton(onPressed: _reload, style: AppUI.secondary(context), child: const Text('Retry')),
      );
    }
    final listed = _listed;
    final shown = _shown(listed);
    final classes = {
      for (final s in listed)
        if (trText(s['stuclass']).isNotEmpty) trText(s['stuclass']),
    }.toList();
    final n = _pending.length;
    // no card of its own: it sits inside the Student Enrollment card
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppUI.cardHeader(
        icon: 'bus',
        title: 'Opted Students',
        subtitle: 'Students who chose the school bus. Only these can be added to a route.',
        trailing: [
          ElevatedButton(
            onPressed: _saving ? null : _addStudents,
            style: AppUI.primary(context),
            child: const Text('Add Students'),
          ),
          Tooltip(
            message: 'Reload',
            child: IconButton(onPressed: _saving ? null : _reload, icon: const Icon(Icons.refresh_rounded, color: AppColors.primary)),
          ),
        ],
      ),
      SizedBox(height: 12.h),
      _toolbar(classes),
      SizedBox(height: 10.h),
      _head(),
      Expanded(
        child: listed.isEmpty
            ? AppUI.empty(
                title: 'No student has opted for the bus',
                why: 'Use Add Students to pick the students who travel by the school bus.',
                icon: 'bus',
              )
            : shown.isEmpty
                ? AppUI.empty(title: 'No student matches', why: 'Try another class or search.', icon: 'people')
                : ListView.builder(itemCount: shown.length, itemBuilder: (_, i) => _row(shown[i], i)),
      ),
      AppFormFooter(
        note: '${n == 0 ? '' : '$n not saved · '}${AppUI.showing(shown.isEmpty ? 0 : 1, shown.length, listed.length)}',
        actions: [
          ElevatedButton(
            onPressed: n == 0 || _saving ? null : _save,
            style: AppUI.primary(context),
            child: Text(_saving ? 'Saving...' : (n == 0 ? AppText.save : 'Save $n Student${n == 1 ? '' : 's'}')),
          ),
        ],
      ),
    ]);
  }
}

/// Picks any number of the students who have not opted for the bus: tick
/// them, narrowing by class or search. Pops with the ticked students' ids.
class _PickStudentsDialog extends StatefulWidget {
  final List<Map<String, dynamic>> students;
  const _PickStudentsDialog({required this.students});

  @override
  State<_PickStudentsDialog> createState() => _PickStudentsDialogState();
}

class _PickStudentsDialogState extends State<_PickStudentsDialog> {
  String _query = '';
  String? _class;
  final Set<int> _picked = {};

  late final List<String> _classes = {
    for (final s in widget.students)
      if (trText(s['stuclass']).isNotEmpty) trText(s['stuclass']),
  }.toList();

  List<Map<String, dynamic>> get _shown {
    final q = _query.trim().toLowerCase();
    return [
      for (final s in widget.students)
        if ((_class == null || trText(s['stuclass']) == _class) && (q.isEmpty || '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q))) s,
    ];
  }

  void _tick(int id, bool on) => setState(() => on ? _picked.add(id) : _picked.remove(id));

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final ids = [for (final s in shown) trId(s['stu_id'])!];
    final all = ids.isNotEmpty && ids.every(_picked.contains);
    final some = ids.any(_picked.contains);
    final n = _picked.length;
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 660),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(
              icon: 'user-add',
              title: 'Add students',
              subtitle: 'Tick the students who travel by the school bus.',
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad),
            child: Row(children: [
              Expanded(child: TrSearchField(hint: 'Adm no or name', onChanged: (v) => setState(() => _query = v))),
              SizedBox(width: 12.w),
              SizedBox(
                width: 210,
                child: AppDropdownField<String?>(
                  key: const ValueKey('opted-add-class'),
                  initialValue: _class,
                  isExpanded: true,
                  menuMaxHeight: 400,
                  dropdownColor: AppColors.card,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, '', filled: _class != null),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All classes')),
                    for (final c in _classes) DropdownMenuItem<String?>(value: c, child: Text(c, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _class = v),
                ),
              ),
            ]),
          ),
          SizedBox(height: 10.h),
          Container(
            decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 2.h),
            child: Row(children: [
              SizedBox(
                width: 44,
                child: Tooltip(
                  message: all ? 'Untick all shown' : 'Tick all shown',
                  child: Checkbox(
                    key: const ValueKey('opted-add-all'),
                    tristate: true,
                    value: all ? true : (some ? null : false),
                    onChanged: ids.isEmpty ? null : (_) => setState(() => all ? _picked.removeAll(ids) : _picked.addAll(ids)),
                  ),
                ),
              ),
              SizedBox(width: 130, child: Text('CLASS', style: AppUI.tableHead)),
              SizedBox(width: 140, child: Text('ADMISSION NO', style: AppUI.tableHead)),
              Expanded(child: Text('STUDENT NAME', style: AppUI.tableHead)),
            ]),
          ),
          Expanded(
            child: shown.isEmpty
                ? AppUI.empty(
                    title: widget.students.isEmpty ? 'Every student has opted already' : 'No student matches',
                    why: widget.students.isEmpty ? null : 'Try another class or search.',
                    icon: 'people',
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final s = shown[i];
                      final id = trId(s['stu_id'])!;
                      final on = _picked.contains(id);
                      return InkWell(
                        key: ValueKey('opted-add-$id'),
                        onTap: () => _tick(id, !on),
                        child: Container(
                          decoration: BoxDecoration(
                            color: on ? AppColors.primarySoft : (i.isEven ? Colors.white : AppColors.surface),
                            border: const Border(bottom: BorderSide(color: AppColors.divider)),
                          ),
                          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 1.h),
                          child: Row(children: [
                            SizedBox(width: 44, child: Checkbox(value: on, onChanged: (v) => _tick(id, v == true))),
                            SizedBox(width: 130, child: Text(trText(s['stuclass']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                            SizedBox(width: 140, child: Text(trText(s['stuadmno']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                            Expanded(child: Text(trText(s['stuname']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          AppFormFooter(
            note: '$n ticked · ${shown.length} of ${widget.students.length} shown',
            onCancel: () => Navigator.pop(context),
            actions: [
              ElevatedButton(
                onPressed: n == 0 ? null : () => Navigator.pop(context, _picked.toList()),
                style: AppUI.primary(context),
                child: Text(n == 0 ? 'Add Students' : 'Add $n Student${n == 1 ? '' : 's'}'),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
