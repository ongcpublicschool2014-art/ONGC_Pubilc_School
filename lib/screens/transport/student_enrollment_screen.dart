import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/transport_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// STUDENT ENROLLMENT -- which students travel on a route, and where they get
/// on and off (tr_student_enrollment). Pick the route at the top: its stops
/// are on the left, by stage, and its students on the right with admission
/// number, name, class, trip type (both ways, pickup only or drop only), fee
/// stage, pickup and drop stops, start and end dates, and status.
///
/// Add Students picks any number of the year's students at once. A stop is
/// given by dragging it from the left: onto a student (admission number, name
/// or class) for both stops, or onto the Pickup or Drop column for that one;
/// with students ticked, one drop sets all of them. Every cell also has its
/// dropdown, and the ticked students can be set together from the bar above
/// the list. The changes are saved together (tr_save 'enrollment').
///
/// The fee stage is the stage of the farther stop; the server works it out.
/// A student who stops travelling is Cancelled, never deleted. Each day's
/// trips expect the active students (transport_core.fn_generate_trips).
class StudentEnrollmentScreen extends StatefulWidget {
  const StudentEnrollmentScreen({super.key});

  @override
  State<StudentEnrollmentScreen> createState() => _StudentEnrollmentScreenState();
}

const _tripTypes = <(String, String)>[('BOTH', 'Both'), ('PICKUP', 'Pickup'), ('DROP', 'Drop')];
const _statuses = <(String, String)>[('ACTIVE', 'Active'), ('SUSPENDED', 'Suspended'), ('CANCELLED', 'Cancelled'), ('COMPLETED', 'Completed')];

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String? _isoDate(dynamic v) {
  final s = trText(v);
  return s.length >= 10 ? s.substring(0, 10) : null;
}

List<Map<String, dynamic>> _maps(dynamic v) => [
      for (final x in (v is List ? v : const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];

class _StudentEnrollmentScreenState extends State<StudentEnrollmentScreen> {
  List<Map<String, dynamic>> _routes = const [];
  List<Map<String, dynamic>> _stages = const [];
  List<Map<String, dynamic>> _stops = const [];
  List<Map<String, dynamic>> _students = const [];
  List<Map<String, dynamic>> _enrollments = const [];
  String? _yearFrom, _yearTo;
  int? _routeId;
  bool _loading = true;
  bool _loadingRoute = false;
  String? _error;
  String? _routeError;

  /// The board has changes that are not saved yet.
  bool _dirty = false;

  /// Bumped to put the route picker back on the open route.
  int _pickerKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The routes, their stages and stops, and the year's students; then the
  /// open route's students (the first route in use, at first).
  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        TransportService.list('route'),
        TransportService.list('stage'),
        TransportService.list('stop'),
        TransportService.students(),
      ]);
      final routes = r[0] as List<Map<String, dynamic>>;
      final st = r[3] as Map<String, dynamic>;
      var routeId = _routeId;
      if (!routes.any((x) => trId(x['route_id']) == routeId)) {
        final inUse = routes.where((x) => x['is_active'] != false);
        routeId = trId((inUse.isNotEmpty ? inUse.first : (routes.isEmpty ? null : routes.first))?['route_id']);
      }
      final enrollments = routeId == null ? <Map<String, dynamic>>[] : await TransportService.list('enrollment', filter: {'route_id': routeId});
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _stages = r[1] as List<Map<String, dynamic>>;
        _stops = r[2] as List<Map<String, dynamic>>;
        _students = _maps(st['students']);
        _yearFrom = _isoDate(st['year_from']);
        _yearTo = _isoDate(st['year_to']);
        _routeId = routeId;
        _enrollments = enrollments;
        _loading = false;
        _error = null;
        _routeError = null;
        _dirty = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _load();
  }

  Future<void> _refresh() async {
    if (_dirty && !await _discard()) return;
    await _reload();
  }

  Future<void> _openRoute(int? id) async {
    if (id == null || id == _routeId) return;
    if (_dirty && !await _discard()) {
      setState(() => _pickerKey++); // the picker shows the open route again
      return;
    }
    setState(() {
      _routeId = id;
      _loadingRoute = true;
      _routeError = null;
      _dirty = false;
    });
    await _loadRoute();
  }

  Future<void> _loadRoute() async {
    final id = _routeId;
    if (id == null) return;
    try {
      final rows = await TransportService.list('enrollment', filter: {'route_id': id});
      if (!mounted || id != _routeId) return;
      setState(() {
        _enrollments = rows;
        _loadingRoute = false;
        _routeError = null;
      });
    } catch (e) {
      if (!mounted || id != _routeId) return;
      setState(() {
        _loadingRoute = false;
        _routeError = friendlyError(e);
      });
    }
  }

  /// Saves the board's changed rows, then shows what the server has now (the
  /// new rows' ids, and the routes the students are on).
  Future<void> _save(List<Map<String, dynamic>> rows) async {
    final id = _routeId!;
    await TransportService.save('enrollment', {'route_id': id, 'rows': rows});
    final r = await Future.wait<dynamic>([
      TransportService.list('enrollment', filter: {'route_id': id}),
      TransportService.students(),
    ]);
    if (!mounted) return;
    final st = r[1] as Map<String, dynamic>;
    setState(() {
      _enrollments = r[0] as List<Map<String, dynamic>>;
      _students = _maps(st['students']);
      _dirty = false;
    });
  }

  Future<bool> _discard() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard the changes?'),
          content: const Text('Some changes on this route are not saved yet. They are lost if you go on.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Editing')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.danger(ctx), child: const Text('Discard')),
          ],
        ),
      ) ==
      true;

  Widget _routePicker() => AppDropdownField<int?>(
        key: ValueKey('enr-route-$_routeId-$_pickerKey'),
        initialValue: _routeId,
        isExpanded: true,
        menuMaxHeight: 420,
        dropdownColor: AppColors.card,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', filled: _routeId != null),
        hint: Text('Choose the route', style: AppUI.muted),
        items: [
          for (final r in _routes)
            DropdownMenuItem<int?>(
              value: trId(r['route_id']),
              child: Text(
                '${trText(r['route_code'])} · ${trText(r['route_name'])}${r['is_active'] == false ? ' (switched off)' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _openRoute,
      );

  Widget _body(Map<String, dynamic>? route) {
    if (route == null) {
      return AppUI.empty(title: 'No routes yet', why: 'Add a route, its stages and its stops in Routes & Stops first.', icon: 'routing');
    }
    if (_loadingRoute) return const AppLoading();
    if (_routeError != null) {
      return AppUI.empty(
        title: 'Could not load the students of this route',
        why: _routeError,
        icon: 'info-circle',
        action: OutlinedButton(
          onPressed: () {
            setState(() => _loadingRoute = true);
            _loadRoute();
          },
          style: AppUI.secondary(context),
          child: const Text('Retry'),
        ),
      );
    }
    final rid = trId(route['route_id']);
    return EnrollmentBoard(
      key: ValueKey('enr-board-$rid'),
      route: route,
      stages: [for (final g in _stages) if (trId(g['route_id']) == rid) g],
      stops: [for (final p in _stops) if (trId(p['route_id']) == rid) p],
      enrollments: _enrollments,
      students: _students,
      yearFrom: _yearFrom,
      yearTo: _yearTo,
      onSave: _save,
      onDirtyChanged: (v) => _dirty = v,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Student Enrollment',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton(onPressed: _reload, style: AppUI.secondary(context), child: const Text('Retry')),
      );
    }
    Map<String, dynamic>? route;
    for (final r in _routes) {
      if (trId(r['route_id']) == _routeId) route = r;
    }
    return Container(
      decoration: AppUI.card(),
      padding: EdgeInsets.all(AppUI.cardPad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'people',
          title: 'Student Enrollment',
          subtitle: 'The students on each route, and where they get on and off.',
          trailing: [
            if (_routes.isNotEmpty) SizedBox(width: 340.w, child: _routePicker()),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refresh,
              icon: const AppIcon('refresh', size: 18, color: AppColors.ink2),
            ),
          ],
        ),
        SizedBox(height: 14.h),
        Expanded(child: _body(route)),
      ]),
    );
  }
}

// ── board ────────────────────────────────────────────────────────────────────
/// A student on the board: a saved enrollment, or one added here and not
/// saved yet, with the values the board shows now.
class _Row {
  _Row({
    required this.key,
    required this.saved,
    required this.studentId,
    required this.admNo,
    required this.name,
    required this.cls,
    required this.type,
    required this.status,
    this.start,
  });

  factory _Row.saved(Map<String, dynamic> e) => _Row(
        key: 'e${trId(e['enrollment_id'])}',
        saved: e,
        studentId: trId(e['student_id'])!,
        admNo: trText(e['stuadmno']),
        name: trText(e['stuname']),
        cls: trText(e['stuclass']),
        type: 'BOTH',
        status: 'ACTIVE',
      )..undo();

  factory _Row.added(Map<String, dynamic> s, String start) => _Row(
        key: 's${trId(s['stu_id'])}',
        saved: null,
        studentId: trId(s['stu_id'])!,
        admNo: trText(s['stuadmno']),
        name: trText(s['stuname']),
        cls: trText(s['stuclass']),
        type: 'BOTH',
        status: 'ACTIVE',
        start: start,
      );

  /// "e9" for a saved enrollment, "s483" for a student added here.
  final String key;

  /// The enrollment as listed; null for a student added here.
  final Map<String, dynamic>? saved;
  final int studentId;
  final String admNo, name, cls;
  String type;
  int? pickup, drop;
  String? start, end;
  String status;

  bool get isNew => saved == null;
  bool get usesPickup => type != 'DROP';
  bool get usesDrop => type != 'PICKUP';

  /// The stops the trip type uses. A stop it does not use is kept, in case
  /// the type changes back, but it is not saved.
  int? get pickupNow => usesPickup ? pickup : null;
  int? get dropNow => usesDrop ? drop : null;

  /// The student has left the school (not active in the year's students).
  bool get left => saved != null && saved!['stu_status'] != null && trId(saved!['stu_status']) != 1;

  static String _or(dynamic v, String fallback) => trText(v).isEmpty ? fallback : trText(v);

  bool get changed {
    final s = saved;
    if (s == null) return true;
    return type != _or(s['service_type'], 'BOTH') ||
        pickupNow != trId(s['pickup_stop_id']) ||
        dropNow != trId(s['drop_stop_id']) ||
        start != _isoDate(s['start_date']) ||
        end != _isoDate(s['end_date']) ||
        status != _or(s['status'], 'ACTIVE');
  }

  /// Back to what is saved.
  void undo() {
    final s = saved;
    if (s == null) return;
    type = _or(s['service_type'], 'BOTH');
    pickup = trId(s['pickup_stop_id']);
    drop = trId(s['drop_stop_id']);
    start = _isoDate(s['start_date']);
    end = _isoDate(s['end_date']);
    status = _or(s['status'], 'ACTIVE');
  }

  /// The row as the server takes it.
  Map<String, dynamic> toSave() => {
        if (saved != null) ...{'enrollment_id': trId(saved!['enrollment_id']), 'updated_at': saved!['updated_at']},
        'student_id': studentId,
        'service_type': type,
        'pickup_stop_id': pickupNow,
        'drop_stop_id': dropNow,
        'start_date': start,
        'end_date': end,
        'status': status,
      };
}

/// One route's board, given the lists, so it can be shown without a server:
/// its stops on the left, its students on the right. [onSave] gets the
/// changed rows as the server takes them and throws when they are refused.
class EnrollmentBoard extends StatefulWidget {
  final Map<String, dynamic> route;

  /// This route's stages and stops.
  final List<Map<String, dynamic>> stages;
  final List<Map<String, dynamic>> stops;

  /// This route's enrollments, as tr_list 'enrollment' gives them.
  final List<Map<String, dynamic>> enrollments;

  /// The year's active students, in class order (tr_students).
  final List<Map<String, dynamic>> students;

  /// The academic year's first and last day (yyyy-mm-dd).
  final String? yearFrom, yearTo;
  final Future<void> Function(List<Map<String, dynamic>> rows) onSave;
  final ValueChanged<bool>? onDirtyChanged;

  /// Today; the computer's date when null.
  final DateTime? today;

  const EnrollmentBoard({
    super.key,
    required this.route,
    required this.stages,
    required this.stops,
    required this.enrollments,
    required this.students,
    this.yearFrom,
    this.yearTo,
    required this.onSave,
    this.onDirtyChanged,
    this.today,
  });

  @override
  State<EnrollmentBoard> createState() => _EnrollmentBoardState();
}

class _EnrollmentBoardState extends State<EnrollmentBoard> {
  List<_Row> _rows = [];
  final Set<String> _ticked = {};
  final _hScroll = ScrollController();

  /// The students' list, up and down: its scrollbar always shows, at the
  /// panel's right edge (see _table).
  final _vScroll = ScrollController();
  String _query = '';

  /// The left panel's search: only the stops it matches are listed.
  String _stopQuery = '';

  /// The stop picked on the left: only its students are shown.
  int? _atStop;
  bool _showEnded = false;
  bool _saving = false;
  bool _wasDirty = false;

  /// Bumped to put the bar's pickers back to their hint after use.
  int _barKey = 0;

  Map<int, Map<String, dynamic>> _stopById = const {};
  Map<int, Map<String, dynamic>> _stageById = const {};

  /// The route's stops in route order.
  List<Map<String, dynamic>> _ordered = const [];

  /// Student id -> place in the year's class order.
  Map<int, int> _order = const {};

  @override
  void initState() {
    super.initState();
    _index();
    _rows = _fresh();
  }

  @override
  void didUpdateWidget(EnrollmentBoard old) {
    super.didUpdateWidget(old);
    _index();
    if (old.enrollments != widget.enrollments) {
      // saved: start again from what the server has now
      _rows = _fresh();
      _ticked.clear();
      _wasDirty = false;
    }
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  void _index() {
    _stopById = {
      for (final p in widget.stops)
        if (trId(p['stop_id']) != null) trId(p['stop_id'])!: p,
    };
    _stageById = {
      for (final g in widget.stages)
        if (trId(g['stage_id']) != null) trId(g['stage_id'])!: g,
    };
    _ordered = [..._stopById.values]..sort((a, b) => (trId(a['stop_seq']) ?? 0).compareTo(trId(b['stop_seq']) ?? 0));
    _order = {
      for (var i = 0; i < widget.students.length; i++)
        if (trId(widget.students[i]['stu_id']) != null) trId(widget.students[i]['stu_id'])!: i,
    };
  }

  List<_Row> _fresh() => [
        for (final e in widget.enrollments)
          if (trId(e['enrollment_id']) != null && trId(e['student_id']) != null) _Row.saved(e),
      ];

  int get _routeId => trId(widget.route['route_id'])!;
  String get _routeText => '${trText(widget.route['route_code'])} · ${trText(widget.route['route_name'])}';
  bool get _routeOn => widget.route['is_active'] != false;
  String get _today => _iso(widget.today ?? DateTime.now());

  /// Today, kept within the academic year: a new student's start date.
  String get _defaultStart {
    var d = _today;
    final from = widget.yearFrom, to = widget.yearTo;
    if (from != null && d.compareTo(from) < 0) d = from;
    if (to != null && d.compareTo(to) > 0) d = to;
    return d;
  }

  /// The fee stage the server will give the row: the stage of its farther stop.
  Map<String, dynamic>? _stageOf(_Row r) {
    Map<String, dynamic>? best;
    for (final id in [r.pickupNow, r.dropNow]) {
      final g = _stageById[trId(_stopById[id]?['stage_id'])];
      if (g != null && (best == null || (trId(g['stage_no']) ?? 0) > (trId(best['stage_no']) ?? 0))) best = g;
    }
    return best;
  }

  bool _ended(_Row r) => r.status == 'CANCELLED' || r.status == 'COMPLETED';

  /// Students added here first, then by class (the year's order) and name.
  List<_Row> get _sorted => [..._rows]..sort((a, b) {
      if (a.isNew != b.isNew) return a.isNew ? -1 : 1;
      final c = (_order[a.studentId] ?? 1 << 30).compareTo(_order[b.studentId] ?? 1 << 30);
      return c != 0 ? c : a.name.compareTo(b.name);
    });

  /// The rows the filters leave: ended ones only with Show Ended (or while
  /// changed), the stop picked on the left, and the search.
  List<_Row> get _shown {
    final q = _query.trim().toLowerCase();
    return [
      for (final r in _sorted)
        if ((_showEnded || !_ended(r) || r.changed) &&
            (_atStop == null || r.pickupNow == _atStop || r.dropNow == _atStop) &&
            (q.isEmpty || '${r.admNo} ${r.name} ${r.cls}'.toLowerCase().contains(q)))
          r,
    ];
  }

  /// A filter changed: the ticks stay only on rows still shown.
  void _filter(VoidCallback change) => setState(() {
        change();
        final keys = {for (final r in _shown) r.key};
        _ticked.retainWhere(keys.contains);
      });

  int get _changeCount => _rows.where((r) => r.changed).length;

  void _dirty() {
    final now = _changeCount > 0;
    if (now != _wasDirty) {
      _wasDirty = now;
      widget.onDirtyChanged?.call(now);
    }
  }

  /// Changes rows, then tells the screen whether anything waits to be saved.
  void _edit(VoidCallback change) {
    setState(change);
    _dirty();
  }

  /// The row, or every ticked row when it is one of them.
  List<_Row> _targets(_Row r) => _ticked.contains(r.key) ? [for (final x in _rows) if (_ticked.contains(x.key)) x] : [r];

  /// A stop dropped on a row: as its [pickup] and/or [drop] stop, each only
  /// where the trip type uses it.
  void _putStop(_Row r, int stop, {required bool pickup, required bool drop}) => _edit(() {
        for (final t in _targets(r)) {
          if (pickup && t.usesPickup) t.pickup = stop;
          if (drop && t.usesDrop) t.drop = stop;
        }
      });

  void _undoRow(_Row r) => _edit(() {
        if (r.isNew) {
          _rows.remove(r);
          _ticked.remove(r.key);
        } else {
          r.undo();
        }
      });

  void _undoAll() => _edit(() {
        _rows.removeWhere((r) => r.isNew);
        for (final r in _rows) {
          r.undo();
        }
        _ticked.clear();
      });

  Future<void> _addStudents() async {
    final here = {for (final r in _rows) r.studentId};
    final picked = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => _AddStudentsDialog(students: widget.students, here: here, routeId: _routeId, routeText: _routeText),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final start = _defaultStart;
    var added = 0;
    _edit(() {
      for (final s in picked) {
        final id = trId(s['stu_id']);
        if (id == null || here.contains(id)) continue;
        _rows.add(_Row.added(s, start));
        added++;
      }
      _atStop = null; // a stop filter would hide them
    });
    trSnack(context, '$added student${added == 1 ? '' : 's'} added. Give them their stops, then save.', AppColors.success);
  }

  /// A day within the academic year, starting at [current].
  Future<String?> _pickDay(String? current, String help) async {
    final from = DateTime.tryParse(widget.yearFrom ?? '') ?? DateTime(2000);
    final to = DateTime.tryParse(widget.yearTo ?? '') ?? DateTime(2100);
    var initial = DateTime.tryParse(current ?? '') ?? DateTime.parse(_defaultStart);
    if (initial.isBefore(from)) initial = from;
    if (initial.isAfter(to)) initial = to;
    final picked = await trPickDate(context, initialDate: initial, firstDate: from, lastDate: to, helpText: help);
    return picked == null ? null : _iso(picked);
  }

  /// What the server would refuse anyway, said before sending; null if fine.
  String? _problem(List<_Row> rows) {
    final from = widget.yearFrom, to = widget.yearTo;
    final seen = <int>{};
    for (final r in rows) {
      final who = '${r.admNo} ${r.name}'.trim();
      if (!seen.add(r.studentId)) return '$who is listed twice. Keep one row for each student.';
      if (r.usesPickup && r.pickup == null) return 'Choose the pickup stop of $who.';
      if (r.usesDrop && r.drop == null) return 'Choose the drop stop of $who.';
      final start = r.start, end = r.end;
      if (start == null) return 'Choose the start date of $who.';
      if (end != null && end.compareTo(start) < 0) return 'The end date of $who cannot be before the start date.';
      if ((from != null && start.compareTo(from) < 0) || (to != null && (start.compareTo(to) > 0 || (end != null && end.compareTo(to) > 0)))) {
        return 'The dates of $who must be within the academic year (${formatDate(from)} to ${formatDate(to)}).';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final changed = [for (final r in _rows) if (r.changed) r];
    if (changed.isEmpty) return;
    final problem = _problem(changed);
    if (problem != null) {
      trSnack(context, problem, AppColors.warning);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave([for (final r in changed) r.toSave()]);
      if (!mounted) return;
      setState(() => _saving = false);
      _dirty();
      trSnack(context, changed.length == 1 ? 'Saved 1 student.' : 'Saved ${changed.length} students.', AppColors.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  // ── stops (left) ───────────────────────────────────────────────────────────
  // the counts sit under each stop's name, so the panel leaves the room to the table
  static const double _panelWidth = 224;

  Widget _dragChip(String name) => Material(
        elevation: 6,
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const AppIcon('location', size: 16, color: AppColors.onPrimary),
            const SizedBox(width: 6),
            Text(name, style: AppUI.label.copyWith(color: AppColors.onPrimary)),
          ]),
        ),
      );

  /// A stop to drag onto the students; a click shows only its students.
  Widget _stopTile(Map<String, dynamic> p, int ups, int downs) {
    final id = trId(p['stop_id'])!;
    final off = p['is_active'] == false;
    final picked = _atStop == id;
    final name = trText(p['stop_name']);
    final tile = Material(
      color: picked ? AppColors.primarySoft : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey('enr-stop-$id'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _filter(() => _atStop = picked ? null : id),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 7.h),
          child: Row(children: [
            Icon(Icons.drag_indicator, size: 18, color: off ? AppColors.line : AppColors.ink3),
            const SizedBox(width: 4),
            SizedBox(width: 22, child: Text(trText(p['stop_seq']), style: AppUI.muted)),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  off ? '$name (switched off)' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppUI.label.copyWith(color: off ? AppColors.ink3 : AppColors.ink),
                ),
                Tooltip(
                  message: '$ups picked up here, $downs dropped here (active students)',
                  child: Text('↑$ups  ↓$downs', style: AppUI.muted.copyWith(color: AppColors.ink2)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
    if (off || _saving) return tile;
    return Draggable<int>(
      data: id,
      feedback: _dragChip(name),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }

  /// The route's stops in route order, as many as the search leaves.
  Widget _stopsPanel() {
    // how many active students get on and off at each stop, as the board stands
    final ups = <int, int>{}, downs = <int, int>{};
    for (final r in _rows) {
      if (r.status != 'ACTIVE') continue;
      final p = r.pickupNow, d = r.dropNow;
      if (p != null) ups[p] = (ups[p] ?? 0) + 1;
      if (d != null) downs[d] = (downs[d] ?? 0) + 1;
    }
    final q = _stopQuery.trim().toLowerCase();
    final stops = [
      for (final p in _ordered)
        if (q.isEmpty || '${p['stop_name']} ${p['stop_code'] ?? ''} ${p['landmark'] ?? ''}'.toLowerCase().contains(q)) p,
    ];
    return Container(
      width: _panelWidth,
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
          padding: EdgeInsets.fromLTRB(12.w, 10.h, 12.w, 10.h),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('STOPS', style: AppUI.tableHead),
            SizedBox(height: 2.h),
            Text('Drag a stop onto a student. Click one to see only its students.', style: AppUI.muted),
            SizedBox(height: 8.h),
            TrSearchField(
              key: const ValueKey('enr-stop-search'),
              hint: 'Search stops',
              onChanged: (v) => setState(() => _stopQuery = v),
            ),
          ]),
        ),
        Expanded(
          child: stops.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(16.w),
                  child: Text('No stop matches.', textAlign: TextAlign.center, style: AppUI.muted),
                )
              : ListView(
                  padding: EdgeInsets.all(8.w),
                  children: [
                    for (final p in stops) _stopTile(p, ups[trId(p['stop_id'])] ?? 0, downs[trId(p['stop_id'])] ?? 0),
                  ],
                ),
        ),
      ]),
    );
  }

  // ── students (right) ───────────────────────────────────────────────────────
  static const double _wCheck = 40, _wStage = 70, _wAct = 40;

  // Sized to their text, so nothing is cut short: measured from the field
  // text, the choices, the admission numbers shown and this route's stop
  // names (a stop name may take two lines, so its column only has to fit the
  // longest word). Set by [_fitColumns] before the table is built.
  // [_wName] is the least the name column takes: its longest word (a name may
  // take two lines); it has the rest of the width.
  double _wAdm = 90, _wName = 110, _wTrip = 110, _wStop = 160, _wStart = 122, _wEnd = 144, _wStatus = 132;
  double get _minWidth => _wCheck + _wAdm + _wName + _wTrip + _wStage + _wStop * 2 + _wStart + _wEnd + _wStatus + _wAct + 24;

  double _textWidth(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  void _fitColumns(List<_Row> shown) {
    final style = AppUI.fieldText(context);
    // around the text of a field in a cell: the cell's gap, the field's own
    // left + right padding (AppUI.field), and a little to spare
    final chrome = 8.w + (AppUI.compact(context) ? 24 : 28) + 3;
    const arrow = 24.0; // a dropdown's arrow
    double widest(Iterable<String> texts, [TextStyle? s]) =>
        texts.fold(0.0, (m, t) => t.isEmpty ? m : (m > _textWidth(t, s ?? style) ? m : _textWidth(t, s ?? style)));
    _wAdm = ((widest(shown.map((r) => r.admNo), AppUI.cell) > widest(['ADM NO'], AppUI.tableHead)
                ? widest(shown.map((r) => r.admNo), AppUI.cell)
                : widest(['ADM NO'], AppUI.tableHead)) +
            8.w + 3)
        .clamp(72.0, 140.0)
        .ceilToDouble();
    final words = RegExp(r'\s+');
    _wName = (widest(shown.expand((r) => r.name.split(words)), AppUI.cell) + 8.w + 6).clamp(96.0, 180.0).ceilToDouble();
    final names = [for (final p in _ordered) trText(p['stop_name'])];
    // a word is never split over two lines: its whole width, a little to spare
    final word = widest(names.expand((n) => n.split(words))) + 6;
    final half = widest(names) / 2;
    final line = (word > half ? word : half).clamp(96.0, 176.0);
    _wStop = (line + chrome + arrow).ceilToDouble();
    _wTrip = (widest(_tripTypes.map((t) => t.$2)) + chrome + arrow).ceilToDouble();
    _wStatus = (widest(_statuses.map((t) => t.$2)) + chrome + arrow).ceilToDouble();
    _wStart = (widest(['00-00-0000', 'Set date']) + chrome).ceilToDouble();
    _wEnd = _wStart + 22; // and the clear (x) button of a set end date
  }

  Widget _cell(double width, Widget child) =>
      SizedBox(width: width, child: Padding(padding: EdgeInsets.only(right: 8.w), child: Align(alignment: Alignment.centerLeft, child: child)));

  /// Where a stop dragged from the left can be dropped on a row: the
  /// student's own cells take it as both stops, the Pickup and Drop columns
  /// as that one. It lights up while a stop is held over it.
  Widget _zone(_Row r, {required Key key, required bool pickup, required bool drop, required Widget child}) => DragTarget<int>(
        key: key,
        onWillAcceptWithDetails: (_) => !_saving && _targets(r).any((t) => (pickup && t.usesPickup) || (drop && t.usesDrop)),
        onAcceptWithDetails: (d) => _putStop(r, d.data, pickup: pickup, drop: drop),
        builder: (context, over, _) => Container(
          decoration: BoxDecoration(
            color: over.isNotEmpty ? AppColors.primarySoft : Colors.transparent,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: over.isNotEmpty ? AppColors.primary : Colors.transparent, width: 1.5),
          ),
          child: child,
        ),
      );

  Widget _studentCells(_Row r) => Row(children: [
        SizedBox(
          width: _wAdm,
          child: Padding(
            padding: EdgeInsets.only(right: 8.w),
            child: Text(r.admNo, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
          ),
        ),
        // the name (two lines when long) with the class under it
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: 8.w),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppUI.cell),
                ),
                if (r.isNew) ...[SizedBox(width: 6.w), AppUI.chip('New', AppStatus.info)],
                if (r.left) ...[
                  SizedBox(width: 6.w),
                  Tooltip(message: 'Not an active student any more', child: AppUI.chip('Left', AppStatus.warning)),
                ],
              ]),
              if (r.cls.isNotEmpty) Text(r.cls, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
            ]),
          ),
        ),
      ]);

  Widget _pick(Key key, String value, List<(String, String)> items, ValueChanged<String> onPick) => AppDropdownField<String>(
        key: key,
        initialValue: value,
        isExpanded: true,
        dropdownColor: AppColors.card,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', dense: true, filled: true),
        items: [for (final o in items) DropdownMenuItem<String>(value: o.$1, child: Text(o.$2, maxLines: 1, overflow: TextOverflow.ellipsis))],
        onChanged: _saving
            ? null
            : (v) {
                if (v != null) onPick(v);
              },
      );

  Widget _stopPick(_Row r, {required bool pickup}) {
    if (!(pickup ? r.usesPickup : r.usesDrop)) {
      return Tooltip(
        message: pickup ? 'A drop-only student has no pickup stop.' : 'A pickup-only student has no drop stop.',
        child: Padding(padding: EdgeInsets.only(left: 12.w), child: Text('–', style: AppUI.muted)),
      );
    }
    final value = pickup ? r.pickup : r.drop;
    final options = [
      for (final p in _ordered)
        if (p['is_active'] != false || trId(p['stop_id']) == value) p,
    ];
    final known = options.any((p) => trId(p['stop_id']) == value);
    String label(Map<String, dynamic> p) => '${trText(p['stop_name'])}${p['is_active'] == false ? ' (switched off)' : ''}';
    // one line high like the other fields, two when the name needs it
    Widget shown(Widget child) => ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 24),
          child: Align(alignment: Alignment.centerLeft, child: child),
        );
    return AppDropdownField<int?>(
      key: ValueKey('enr-${pickup ? 'pick' : 'drop'}-${r.key}-$value'),
      initialValue: known ? value : null,
      isExpanded: true,
      // not dense, so a long stop name can take a second line in the box
      isDense: false,
      menuMaxHeight: 380,
      dropdownColor: AppColors.card,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      style: AppUI.fieldText(context),
      decoration: AppUI.field(context, '', dense: true, filled: known),
      hint: shown(Text(pickup ? 'Pickup stop' : 'Drop stop', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted)),
      // only the chosen stop is laid out in the box, so the row is as tall as
      // its own stop name needs (the box sizes to the tallest entry it holds)
      selectedItemBuilder: (_) => [
        for (final p in options)
          trId(p['stop_id']) == value
              ? shown(Tooltip(message: label(p), child: Text(label(p), maxLines: 2, overflow: TextOverflow.ellipsis)))
              : const SizedBox.shrink(),
      ],
      items: [
        for (final p in options)
          DropdownMenuItem<int?>(
            value: trId(p['stop_id']),
            child: Text(label(p), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _saving
          ? null
          : (v) => _edit(() {
                if (pickup) {
                  r.pickup = v;
                } else {
                  r.drop = v;
                }
              }),
    );
  }

  Widget _stageCell(_Row r) {
    final g = _stageOf(r);
    if (g == null) return Text('–', style: AppUI.muted);
    return Tooltip(
      message: '${trText(g['stage_name'])}: the fee stage, from the farther stop',
      child: Text('Stage ${trText(g['stage_no'])}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
    );
  }

  Widget _dateCell(_Row r, {required bool end}) {
    final v = end ? r.end : r.start;
    return InkWell(
      key: ValueKey('enr-${end ? 'end' : 'start'}-${r.key}'),
      onTap: _saving
          ? null
          : () async {
              final d = await _pickDay(v ?? (end ? widget.yearTo : null), '${end ? 'End' : 'Start'} date: ${r.name}');
              if (d == null || !mounted) return;
              _edit(() {
                if (end) {
                  r.end = d;
                } else {
                  r.start = d;
                }
              });
            },
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: InputDecorator(
        decoration: AppUI.field(
          context,
          '',
          dense: true,
          filled: v != null,
          suffix: end && v != null && !_saving
              ? Tooltip(
                  message: 'No end date',
                  child: InkWell(onTap: () => _edit(() => r.end = null), child: const Icon(Icons.close, size: 14, color: AppColors.ink2)),
                )
              : null,
        ),
        // a date a few pixels wider than its box shrinks a little instead of
        // ending in "..."
        child: AppFitText(
          v == null ? (end ? 'Open' : 'Set date') : formatDate(v),
          style: v == null ? AppUI.muted : AppUI.fieldText(context),
        ),
      ),
    );
  }

  Widget _rowAction(_Row r) {
    if (!r.isNew && !r.changed) return const SizedBox.shrink();
    return IconButton(
      tooltip: r.isNew ? 'Take this student off the list (not saved yet)' : 'Undo the changes in this row',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      onPressed: _saving ? null : () => _undoRow(r),
      icon: r.isNew
          ? const AppIcon.linear('close-circle', size: 16, color: AppColors.error)
          : const AppIcon('rotate-left', size: 16, color: AppColors.ink2),
    );
  }

  Widget _row(_Row r, int i) {
    final ticked = _ticked.contains(r.key);
    return Container(
      key: ValueKey('enr-row-${r.key}'),
      constraints: BoxConstraints(minHeight: 48.h),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 4.h),
      decoration: BoxDecoration(color: ticked ? AppColors.primarySoft : (r.changed ? AppColors.accent.withValues(alpha: 0.045) : (i.isEven ? Colors.white : AppColors.surface)), border: const Border(bottom: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        SizedBox(
          width: _wCheck,
          child: Checkbox(
            value: ticked,
            onChanged: _saving
                ? null
                : (v) => setState(() {
                      if (v == true) {
                        _ticked.add(r.key);
                      } else {
                        _ticked.remove(r.key);
                      }
                    }),
          ),
        ),
        // the student's own cells take a dropped stop as both stops
        Expanded(child: _zone(r, key: ValueKey('enr-who-${r.key}'), pickup: true, drop: true, child: _studentCells(r))),
        _cell(_wTrip, _pick(ValueKey('enr-trip-${r.key}-${r.type}'), r.type, _tripTypes, (v) => _edit(() => r.type = v))),
        _cell(_wStage, _stageCell(r)),
        _cell(_wStop, _zone(r, key: ValueKey('enr-pickzone-${r.key}'), pickup: true, drop: false, child: _stopPick(r, pickup: true))),
        _cell(_wStop, _zone(r, key: ValueKey('enr-dropzone-${r.key}'), pickup: false, drop: true, child: _stopPick(r, pickup: false))),
        _cell(_wStart, _dateCell(r, end: false)),
        _cell(_wEnd, _dateCell(r, end: true)),
        _cell(_wStatus, _pick(ValueKey('enr-status-${r.key}-${r.status}'), r.status, _statuses, (v) => _edit(() => r.status = v))),
        SizedBox(width: _wAct, child: _rowAction(r)),
      ]),
    );
  }

  Widget _head(List<_Row> shown) {
    final all = shown.isNotEmpty && shown.every((r) => _ticked.contains(r.key));
    final some = shown.any((r) => _ticked.contains(r.key));
    Widget h(String text, double width) => _cell(width, Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.tableHead));
    return Container(
      height: 44.h,
      padding: EdgeInsets.symmetric(horizontal: 12.w),
      decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        SizedBox(
          width: _wCheck,
          child: Tooltip(
            message: all ? 'Untick all' : 'Tick all shown',
            child: Checkbox(
              tristate: true,
              value: all ? true : (some ? null : false),
              onChanged: shown.isEmpty || _saving
                  ? null
                  : (_) => setState(() {
                        for (final r in shown) {
                          if (all) {
                            _ticked.remove(r.key);
                          } else {
                            _ticked.add(r.key);
                          }
                        }
                      }),
            ),
          ),
        ),
        Expanded(
          child: Row(children: [
            h('ADM NO', _wAdm),
            Expanded(child: Padding(padding: EdgeInsets.only(right: 8.w), child: Text('NAME · CLASS', style: AppUI.tableHead))),
          ]),
        ),
        h('TRIP', _wTrip),
        h('STAGE', _wStage),
        h('PICKUP STOP', _wStop),
        h('DROP STOP', _wStop),
        h('START', _wStart),
        h('END', _wEnd),
        h('STATUS', _wStatus),
        const SizedBox(width: _wAct),
      ]),
    );
  }

  /// The list, scrolling sideways when the panel is narrower than its columns.
  /// Both scrollbars always show at the panel's own edges: the up-and-down
  /// one sits on the panel's right, not at the far end of the wide table
  /// where it would be out of sight.
  Widget _table(List<_Row> shown) => LayoutBuilder(builder: (context, c) {
        _fitColumns(shown);
        final width = c.maxWidth < _minWidth ? _minWidth : c.maxWidth;
        final table = SizedBox(
          width: width,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _head(shown),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('enr-rows'),
                controller: _vScroll,
                itemCount: shown.length,
                itemBuilder: (_, i) => _row(shown[i], i),
              ),
            ),
          ]),
        );
        final body = width <= c.maxWidth
            ? table
            : Scrollbar(
                controller: _hScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(controller: _hScroll, scrollDirection: Axis.horizontal, child: table),
              );
        // no automatic scrollbars underneath: these two are the ones shown
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            key: const ValueKey('enr-vbar'),
            controller: _vScroll,
            thumbVisibility: true,
            trackVisibility: true,
            // the list's own scrolling, also from inside the sideways scroll
            notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
            child: body,
          ),
        );
      });

  /// Set the ticked students together.
  Widget _bar() {
    final ticked = [for (final r in _rows) if (_ticked.contains(r.key)) r];
    final stops = [
      for (final p in _ordered)
        if (p['is_active'] != false) (trId(p['stop_id'])!, trText(p['stop_name'])),
    ];
    Widget pick<T>(String hint, List<(T, String)> items, void Function(_Row r, T v) apply, double width) => SizedBox(
          width: width,
          child: AppDropdownField<T>(
            key: ValueKey('enr-bar-$hint-$_barKey'),
            isExpanded: true,
            menuMaxHeight: 380,
            dropdownColor: AppColors.card,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            style: AppUI.fieldText(context),
            decoration: AppUI.field(context, '', dense: true),
            hint: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
            items: [for (final o in items) DropdownMenuItem<T>(value: o.$1, child: Text(o.$2, maxLines: 1, overflow: TextOverflow.ellipsis))],
            onChanged: _saving
                ? null
                : (v) {
                    if (v == null) return;
                    _edit(() {
                      for (final r in ticked) {
                        apply(r, v);
                      }
                      _barKey++;
                    });
                  },
          ),
        );
    Widget day(String label, {required bool end}) => OutlinedButton.icon(
          onPressed: _saving
              ? null
              : () async {
                  final d = await _pickDay(end ? widget.yearTo : null, '$label: ${ticked.length} students');
                  if (d == null || !mounted) return;
                  _edit(() {
                    for (final r in ticked) {
                      if (end) {
                        r.end = d;
                      } else {
                        r.start = d;
                      }
                    }
                  });
                },
          style: AppUI.secondary(context),
          icon: AppIcon('calendar', size: AppBtn.iconSize(context), color: AppColors.primaryText),
          label: Text(label),
        );
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(AppUI.controlRadius)),
      child: Wrap(spacing: 10.w, runSpacing: 8.h, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${ticked.length} ticked: set', style: AppUI.label.copyWith(color: AppColors.primaryText)),
        pick<String>('Trip type', _tripTypes, (r, v) => r.type = v, 130),
        pick<int>('Pickup stop', stops, (r, v) {
          if (r.usesPickup) r.pickup = v;
        }, 190),
        pick<int>('Drop stop', stops, (r, v) {
          if (r.usesDrop) r.drop = v;
        }, 190),
        day('Start Date', end: false),
        day('End Date', end: true),
        pick<String>('Status', _statuses, (r, v) => r.status = v, 130),
        TextButton(onPressed: () => setState(_ticked.clear), child: const Text('Untick All')),
      ]),
    );
  }

  Widget _toolbar(int changes) {
    final stop = _atStop == null ? null : _stopById[_atStop];
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10.w,
      runSpacing: 8.h,
      children: [
        Wrap(spacing: 10.w, runSpacing: 8.h, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 240.w, child: TrSearchField(hint: 'Adm no, name or class', onChanged: (v) => _filter(() => _query = v))),
          FilterChip(
            label: const Text('Show Ended'),
            tooltip: 'Show cancelled and completed students too',
            selected: _showEnded,
            onSelected: (v) => _filter(() => _showEnded = v),
          ),
          if (stop != null) InputChip(label: Text('At ${trText(stop['stop_name'])}'), onDeleted: () => _filter(() => _atStop = null)),
        ]),
        Wrap(spacing: 10.w, runSpacing: 8.h, children: [
          Tooltip(
            message: _routeOn ? 'Pick students of the year to add to this route' : 'This route is switched off',
            child: OutlinedButton.icon(
              onPressed: _saving || !_routeOn ? null : _addStudents,
              style: AppUI.secondary(context),
              icon: AppIcon('user-add', size: AppBtn.iconSize(context), color: AppColors.primaryText),
              label: const Text('Add Students'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: changes == 0 || _saving ? null : _undoAll,
            style: AppUI.secondary(context),
            icon: AppIcon('rotate-left', size: AppBtn.iconSize(context), color: AppColors.primaryText),
            label: const Text('Undo All'),
          ),
          ElevatedButton.icon(
            onPressed: changes == 0 || _saving ? null : _save,
            style: AppUI.primary(context),
            icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
            label: Text(_saving ? 'Saving...' : (changes == 0 ? AppText.save : 'Save $changes Change${changes == 1 ? '' : 's'}')),
          ),
        ]),
      ],
    );
  }

  Widget _summary(int changes) {
    final active = _rows.where((r) => r.status == 'ACTIVE').length;
    final noStop = _rows.where((r) => r.status == 'ACTIVE' && ((r.usesPickup && r.pickup == null) || (r.usesDrop && r.drop == null))).length;
    final parts = [
      '$active active student${active == 1 ? '' : 's'}',
      if (noStop > 0) '$noStop without a stop',
    ];
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: parts.join(' · '), style: AppUI.muted),
        if (changes > 0)
          TextSpan(
            text: '   ·   $changes change${changes == 1 ? '' : 's'} not saved',
            style: AppUI.muted.copyWith(color: AppColors.goldDark, fontWeight: FontWeight.w700),
          ),
        TextSpan(
          text: '   ·   Drag a stop onto a student for both stops, or onto Pickup or Drop for one; ticked students all take it.',
          style: AppUI.muted,
        ),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stops.isEmpty) {
      return AppUI.empty(title: 'This route has no stops yet', why: 'Add its stages and stops in Routes & Stops first.', icon: 'location');
    }
    final changes = _changeCount;
    final shown = _shown;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _stopsPanel(),
      SizedBox(width: 14.w),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _toolbar(changes),
          SizedBox(height: 8.h),
          _summary(changes),
          if (_ticked.isNotEmpty) ...[SizedBox(height: 8.h), _bar()],
          SizedBox(height: 10.h),
          Expanded(
            child: Container(
              decoration: AppUI.card(),
              clipBehavior: Clip.antiAlias,
              child: shown.isEmpty
                  ? AppUI.empty(
                      title: _rows.isEmpty ? 'No students on this route yet' : 'No student matches',
                      why: _rows.isEmpty
                          ? 'Use Add Students, then drag each student\'s stop onto them.'
                          : 'Try another search or stop, or Show Ended.',
                      icon: 'people',
                    )
                  : _table(shown),
            ),
          ),
        ]),
      ),
    ]);
  }
}

// ── add students ─────────────────────────────────────────────────────────────
/// The year's students to add to the route: tick any number, by class or by
/// search. A student already on this route, or active on another one, is
/// shown but cannot be ticked. Pops with the ticked students.
class _AddStudentsDialog extends StatefulWidget {
  final List<Map<String, dynamic>> students;

  /// Students the board already has on this route.
  final Set<int> here;
  final int routeId;
  final String routeText;
  const _AddStudentsDialog({required this.students, required this.here, required this.routeId, required this.routeText});

  @override
  State<_AddStudentsDialog> createState() => _AddStudentsDialogState();
}

class _AddStudentsDialogState extends State<_AddStudentsDialog> {
  String _query = '';
  String? _class;
  final Set<int> _picked = {};

  /// The row the keyboard is on, or -1: Down / Up move it, Space or Enter
  /// ticks it (a student who cannot be added stays unticked).
  int _cursor = -1;

  /// Holds the keyboard while no field has it, so the arrows work as soon as
  /// the dialog opens; the search field gives it up on Down / Up.
  final FocusNode _keys = FocusNode(debugLabel: 'enr-add-keys', skipTraversal: true);
  final GlobalKey _cursorRow = GlobalKey();

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  /// Down / Up: the next / previous row, kept in view.
  void _moveCursor(int by) {
    final n = _shown.length;
    if (n == 0) return;
    setState(() => _cursor = _cursor < 0 ? (by > 0 ? 0 : n - 1) : (_cursor + by).clamp(0, n - 1));
    // out of the search field, so Space ticks rather than types
    if (!_keys.hasPrimaryFocus) _keys.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _cursorRow.currentContext;
      if (row == null || !mounted) return;
      Scrollable.ensureVisible(
        row,
        duration: const Duration(milliseconds: 80),
        alignmentPolicy: by > 0 ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  /// Space / Enter: tick or untick the row the keyboard is on.
  void _tickCursor() {
    final shown = _shown;
    if (_cursor < 0 || _cursor >= shown.length) return;
    final s = shown[_cursor];
    final id = trId(s['stu_id']);
    if (id == null || _why(s) != null) return;
    _tick(id, !_picked.contains(id));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _moveCursor(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _moveCursor(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      // only while the keyboard is on the rows: in the search field a space
      // is a space, and a focused button (Add, Cancel) still presses
      if (!_keys.hasPrimaryFocus || _cursor < 0 || e is KeyRepeatEvent) return KeyEventResult.ignored;
      _tickCursor();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The classes, in the year's order.
  late final List<String> _classes = {
    for (final s in widget.students)
      if (trText(s['stuclass']).isNotEmpty) trText(s['stuclass']),
  }.toList();

  /// Why a student cannot be ticked, or null.
  String? _why(Map<String, dynamic> s) {
    if (widget.here.contains(trId(s['stu_id']))) return 'On this route';
    final rid = trId(s['route_id']);
    if (rid != null && rid != widget.routeId) return 'On ${trText(s['route_code'])}';
    return null;
  }

  List<Map<String, dynamic>> get _shown {
    final q = _query.trim().toLowerCase();
    return [
      for (final s in widget.students)
        if ((_class == null || trText(s['stuclass']) == _class) && (q.isEmpty || '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q))) s,
    ];
  }

  void _tick(int id, bool on) => setState(() {
        if (on) {
          _picked.add(id);
        } else {
          _picked.remove(id);
        }
      });

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final free = [
      for (final s in shown)
        if (_why(s) == null && trId(s['stu_id']) != null) trId(s['stu_id'])!,
    ];
    final all = free.isNotEmpty && free.every(_picked.contains);
    final some = free.any(_picked.contains);
    final n = _picked.length;
    final dialog = Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 660),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(
              icon: 'user-add',
              title: 'Add students',
              subtitle: 'To route ${widget.routeText}. Tick any number; give them their stops on the board.',
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad),
            child: Row(children: [
              Expanded(
                child: TrSearchField(
                  hint: 'Adm no or name',
                  onChanged: (v) => setState(() {
                    _query = v;
                    _cursor = -1;
                  }),
                ),
              ),
              SizedBox(width: 12.w),
              SizedBox(
                width: 210,
                child: AppDropdownField<String?>(
                  key: const ValueKey('enr-add-class'),
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
                  onChanged: (v) => setState(() {
                    _class = v;
                    _cursor = -1;
                  }),
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
                  message: all ? 'Untick all shown' : 'Tick all shown that can be added',
                  child: Checkbox(
                    tristate: true,
                    value: all ? true : (some ? null : false),
                    onChanged: free.isEmpty
                        ? null
                        : (_) => setState(() {
                              if (all) {
                                _picked.removeAll(free);
                              } else {
                                _picked.addAll(free);
                              }
                            }),
                  ),
                ),
              ),
              SizedBox(width: 110, child: Text('ADM NO', style: AppUI.tableHead)),
              Expanded(child: Text('NAME', style: AppUI.tableHead)),
              SizedBox(width: 120, child: Text('CLASS', style: AppUI.tableHead)),
              SizedBox(width: 130, child: Text('TRANSPORT', style: AppUI.tableHead)),
            ]),
          ),
          Expanded(
            child: shown.isEmpty
                ? AppUI.empty(title: 'No student matches', why: 'Try another class or search.', icon: 'people')
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final s = shown[i];
                      final id = trId(s['stu_id'])!;
                      final why = _why(s);
                      final on = why == null && _picked.contains(id);
                      final here = i == _cursor; // the keyboard's row
                      void tap(bool v) {
                        setState(() => _cursor = i);
                        _keys.requestFocus(); // so Space ticks the next one
                        if (why == null) _tick(id, v);
                      }

                      return InkWell(
                        key: ValueKey('enr-add-$id'),
                        onTap: () => tap(!on),
                        child: Container(
                          key: here ? _cursorRow : null,
                          foregroundDecoration: here ? BoxDecoration(border: Border.all(color: AppColors.primary, width: 1.5)) : null,
                          decoration: BoxDecoration(color: on ? AppColors.primarySoft : (here ? AppColors.primaryTint : (i.isEven ? Colors.white : AppColors.surface)), border: const Border(bottom: BorderSide(color: AppColors.divider))),
                          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 1.h),
                          child: Row(children: [
                            SizedBox(width: 44, child: Checkbox(value: on, onChanged: why != null ? null : (v) => tap(v == true))),
                            SizedBox(width: 110, child: Text(trText(s['stuadmno']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                            Expanded(
                              child: Text(trText(s['stuname']),
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: why == null ? AppUI.cell : AppUI.muted),
                            ),
                            SizedBox(width: 120, child: Text(trText(s['stuclass']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                            SizedBox(
                              width: 130,
                              child: why == null ? const SizedBox.shrink() : Align(alignment: Alignment.centerLeft, child: AppUI.chip(why, AppStatus.neutral)),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          AppFormFooter(
            note: '$n ticked · ${free.length} of ${shown.length} shown can be added · ↑ ↓ move, Space ticks',
            onCancel: () => Navigator.pop(context),
            actions: [
              ElevatedButton(
                onPressed: n == 0
                    ? null
                    : () => Navigator.pop(context, [
                          for (final s in widget.students)
                            if (_picked.contains(trId(s['stu_id']))) s,
                        ]),
                style: AppUI.primary(context),
                child: Text(n == 0 ? 'Add Students' : 'Add $n Student${n == 1 ? '' : 's'}'),
              ),
            ],
          ),
        ]),
      ),
    );
    // Down / Up move along the rows, Space or Enter ticks: from the search
    // field too (see _onKey)
    return Focus(focusNode: _keys, autofocus: true, onKeyEvent: _onKey, child: dialog);
  }
}
