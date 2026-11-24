import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/transport_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// VEHICLE ALLOTMENT -- which vehicle each student of a route travels in, one
/// way at a time. Pick the route, and Pickup or Drop, at the top. The
/// vehicles of that route's trips that way (its trip schedules) are shown as
/// buses with their seats taken and free; the students with no vehicle yet
/// are listed on the left; the open vehicle is on the right, seen from above
/// with a student on each seat and their details below.
///
/// Drag students onto a vehicle (one, or all the ticked ones), or a seat back
/// to the list, then save the changes together (tr_save 'allotment'). A
/// vehicle never takes more students than its capacity, here or on the
/// server: its seats plus its additional capacity for small children (e.g.
/// three small children on two seats is 1 more), both set in Vehicles.
/// The vehicle is kept on the enrollment as pickup_schedule_id or
/// drop_schedule_id; each day's trip then expects only its own students
/// (transport_core.fn_generate_trips). A student with no vehicle yet is
/// expected on every trip of the route that way.
///
/// The route's staff (tr_staff_enrollment) take seats with its students: they
/// are listed and moved the same way, marked "Staff · designation", and saved
/// in the same batch (see allotmentRiders and allotmentPayload).
class VehicleAllotmentScreen extends StatefulWidget {
  const VehicleAllotmentScreen({super.key});

  @override
  State<VehicleAllotmentScreen> createState() => _VehicleAllotmentScreenState();
}

/// The board's riders for one route: the students as tr_list 'allotment'
/// gives them, then the staff ('staff_allotment'). Staff enrollments are
/// numbered apart from the students', so a staff row gets a negative id (its
/// own stays in staff_enrollment_id) and shows its employee code, name and
/// "Staff · designation" where a student's admission number, name and class go.
List<Map<String, dynamic>> allotmentRiders(List<Map<String, dynamic>> students, List<Map<String, dynamic>> staff) => [
      ...students,
      for (final s in staff)
        if (trId(s['enrollment_id']) != null)
          {
            ...s,
            'enrollment_id': -trId(s['enrollment_id'])!,
            'staff_enrollment_id': trId(s['enrollment_id']),
            'is_staff': true,
            'stuadmno': s['emp_code'],
            'stuname': s['stafname'],
            'stuclass': trText(s['designation']).isEmpty ? 'Staff' : 'Staff · ${trText(s['designation'])}',
          },
    ];

/// The board's changed rows as tr_save 'allotment' takes them: the students'
/// as "rows", the staff's (negative ids) as "staff_rows" under their own ids.
Map<String, dynamic> allotmentPayload(int routeId, String direction, List<Map<String, dynamic>> rows) => {
      'route_id': routeId,
      'direction': direction,
      'rows': [
        for (final r in rows)
          if ((trId(r['enrollment_id']) ?? 0) > 0) r,
      ],
      'staff_rows': [
        for (final r in rows)
          if ((trId(r['enrollment_id']) ?? 0) < 0) {...r, 'enrollment_id': -trId(r['enrollment_id'])!},
      ],
    };

class _VehicleAllotmentScreenState extends State<VehicleAllotmentScreen> {
  List<Map<String, dynamic>> _routes = const [];
  List<Map<String, dynamic>> _stops = const [];
  List<Map<String, dynamic>> _schedules = const [];
  List<Map<String, dynamic>> _vehicles = const [];
  List<Map<String, dynamic>> _enrollments = const [];
  int? _routeId;
  String _dir = 'PICKUP';
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

  /// The routes, stops, trips and vehicles; then the open route's students
  /// (the first route in use, at first).
  Future<void> _load() async {
    try {
      final r = await Future.wait([
        TransportService.list('route'),
        TransportService.list('stop'),
        TransportService.list('schedule'),
        TransportService.list('vehicle'),
      ]);
      final routes = r[0];
      var routeId = _routeId;
      if (!routes.any((x) => trId(x['route_id']) == routeId)) {
        final inUse = routes.where((x) => x['is_active'] != false);
        routeId = trId((inUse.isNotEmpty ? inUse.first : (routes.isEmpty ? null : routes.first))?['route_id']);
      }
      final rows = routeId == null ? <Map<String, dynamic>>[] : await _routeRiders(routeId);
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _stops = r[1];
        _schedules = r[2];
        _vehicles = r[3];
        _routeId = routeId;
        _enrollments = rows;
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

  /// The route's students and staff, for the board.
  static Future<List<Map<String, dynamic>>> _routeRiders(int id) async {
    final r = await Future.wait([
      TransportService.list('allotment', filter: {'route_id': id}),
      TransportService.list('staff_allotment', filter: {'route_id': id}),
    ]);
    return allotmentRiders(r[0], r[1]);
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
      final rows = await _routeRiders(id);
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

  Future<void> _setDir(String dir) async {
    if (dir == _dir) return;
    if (_dirty && !await _discard()) return;
    setState(() {
      _dir = dir;
      _dirty = false;
    });
  }

  /// Saves the board's changes, then shows what the server has now.
  Future<void> _save(List<Map<String, dynamic>> rows) async {
    final id = _routeId!;
    await TransportService.save('allotment', allotmentPayload(id, _dir, rows));
    final fresh = await _routeRiders(id);
    if (!mounted) return;
    setState(() {
      _enrollments = fresh;
      _dirty = false;
    });
  }

  Future<bool> _discard() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard the changes?'),
          content: const Text('Some changes are not saved yet. They are lost if you go on.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Editing')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.danger(ctx), child: const Text('Discard')),
          ],
        ),
      ) ==
      true;

  Widget _routePicker() => AppDropdownField<int?>(
        key: ValueKey('al-route-$_routeId-$_pickerKey'),
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

  /// Pickup | Drop as one switch: a track with the chosen way filled in the
  /// app colour. Pickup heads to school, Drop heads home.
  Widget _dirPicker() => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.segmentBg,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.fieldBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _dirOption('PICKUP', 'Pickup', 'building'),
          _dirOption('DROP', 'Drop', 'home'),
        ]),
      );

  Widget _dirOption(String value, String label, String icon) {
    final on = _dir == value;
    final fg = on ? AppColors.onPrimary : AppColors.ink2;
    return Material(
      key: ValueKey('al-dir-$value'),
      color: on ? AppColors.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(AppUI.controlRadius - 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius - 3),
        onTap: on ? null : () => _setDir(value),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14.w),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(icon, size: 15, color: on ? AppColors.onPrimary : AppColors.ink3),
            SizedBox(width: 6.w),
            Text(label, style: AppUI.label.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }

  /// The route, the way and Refresh in one row, all the route picker's height.
  Widget _controls() => IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_routes.isNotEmpty) ...[
            SizedBox(width: 300.w, child: _routePicker()),
            SizedBox(width: 10.w),
            _dirPicker(),
            SizedBox(width: 10.w),
          ],
          AspectRatio(
            aspectRatio: 1,
            child: Tooltip(
              message: 'Refresh',
              child: OutlinedButton(
                onPressed: _refresh,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: AppColors.card,
                  side: const BorderSide(color: AppColors.fieldBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.controlRadius)),
                ),
                child: const AppIcon('refresh', size: 17, color: AppColors.ink2),
              ),
            ),
          ),
        ]),
      );

  Widget _body(Map<String, dynamic>? route) {
    if (route == null) {
      return AppUI.empty(title: 'No routes yet', why: 'Add a route and its stops in Routes & Stops first.', icon: 'routing');
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
    return AllotmentBoard(
      key: ValueKey('al-board-$rid-$_dir'),
      route: route,
      direction: _dir,
      trips: [
        for (final s in _schedules)
          if (trId(s['route_id']) == rid && s['direction'] == _dir && s['is_active'] != false) s,
      ],
      otherTrips: [
        for (final s in _schedules)
          if (trId(s['route_id']) == rid && s['direction'] == (_dir == 'PICKUP' ? 'DROP' : 'PICKUP')) s,
      ],
      vehicles: _vehicles,
      stops: [for (final p in _stops) if (trId(p['route_id']) == rid) p],
      enrollments: _enrollments,
      onSave: _save,
      onDirtyChanged: (v) => _dirty = v,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Vehicle Allotment',
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
          icon: 'bus',
          title: 'Vehicle Allotment',
          subtitle: 'Which vehicle each student and staff member travels in, within its seats.',
          trailing: [_controls()],
        ),
        SizedBox(height: 14.h),
        Expanded(child: _body(route)),
      ]),
    );
  }
}

// ── board ────────────────────────────────────────────────────────────────────
/// One route and direction, given the lists, so it can be shown without a
/// server. [onSave] gets the changed rows as the server takes them and
/// throws when they are refused.
class AllotmentBoard extends StatefulWidget {
  final Map<String, dynamic> route;

  /// PICKUP or DROP.
  final String direction;

  /// This route's trip schedules that way, switched on.
  final List<Map<String, dynamic>> trips;

  /// This route's trip schedules the OTHER way (any), to find the vehicle a
  /// student has that way for Copy from Drop / Pickup.
  final List<Map<String, dynamic>> otherTrips;
  final List<Map<String, dynamic>> vehicles;

  /// This route's stops.
  final List<Map<String, dynamic>> stops;

  /// This route's enrollments, as tr_list 'allotment' gives them.
  final List<Map<String, dynamic>> enrollments;
  final Future<void> Function(List<Map<String, dynamic>> rows) onSave;
  final ValueChanged<bool>? onDirtyChanged;

  const AllotmentBoard({
    super.key,
    required this.route,
    required this.direction,
    required this.trips,
    this.otherTrips = const [],
    required this.vehicles,
    required this.stops,
    required this.enrollments,
    required this.onSave,
    this.onDirtyChanged,
  });

  @override
  State<AllotmentBoard> createState() => _AllotmentBoardState();
}

class _AllotmentBoardState extends State<AllotmentBoard> {
  /// The students who travel this way (active, Both or this direction), by
  /// enrollment id.
  Map<int, Map<String, dynamic>> _riders = {};

  /// Enrollment id -> its trip (schedule) as saved, and as the board shows it now.
  Map<int, int?> _saved = {};
  Map<int, int?> _now = {};

  Map<int, Map<String, dynamic>> _vehicleById = const {};
  Map<int, Map<String, dynamic>> _stopById = const {};

  /// The trips by start time.
  List<Map<String, dynamic>> _trips = const [];

  /// The trip whose vehicle is open on the right.
  int? _open;
  final Set<int> _ticked = {};
  String _query = '';
  bool _saving = false;
  bool _wasDirty = false;

  String get _col => widget.direction == 'PICKUP' ? 'pickup_schedule_id' : 'drop_schedule_id';
  String get _stopCol => widget.direction == 'PICKUP' ? 'pickup_stop_id' : 'drop_stop_id';
  String get _way => widget.direction == 'PICKUP' ? 'pickup' : 'drop';

  @override
  void initState() {
    super.initState();
    _index();
    _fresh();
  }

  @override
  void didUpdateWidget(AllotmentBoard old) {
    super.didUpdateWidget(old);
    _index();
    if (old.enrollments != widget.enrollments) {
      // saved: start again from what the server has now
      _fresh();
      _ticked.clear();
      _wasDirty = false;
    }
  }

  void _index() {
    _vehicleById = {
      for (final v in widget.vehicles)
        if (trId(v['vehicle_id']) != null) trId(v['vehicle_id'])!: v,
    };
    _stopById = {
      for (final p in widget.stops)
        if (trId(p['stop_id']) != null) trId(p['stop_id'])!: p,
    };
    _trips = [
      for (final t in widget.trips)
        if (trId(t['schedule_id']) != null) t,
    ]..sort((a, b) {
        final c = trText(a['planned_start']).compareTo(trText(b['planned_start']));
        return c != 0 ? c : trText(a['schedule_code']).compareTo(trText(b['schedule_code']));
      });
    if (!_trips.any((t) => trId(t['schedule_id']) == _open)) _open = _trips.isEmpty ? null : trId(_trips.first['schedule_id']);
  }

  void _fresh() {
    _riders = {
      for (final e in widget.enrollments)
        if (trId(e['enrollment_id']) != null && e['status'] == 'ACTIVE' && (e['service_type'] == 'BOTH' || e['service_type'] == widget.direction))
          trId(e['enrollment_id'])!: e,
    };
    _saved = {for (final e in _riders.entries) e.key: trId(e.value[_col])};
    _now = Map.of(_saved);
  }

  Set<int> get _tripIds => {for (final t in _trips) trId(t['schedule_id'])!};

  Map<String, dynamic>? _trip(int? id) {
    for (final t in _trips) {
      if (trId(t['schedule_id']) == id) return t;
    }
    return null;
  }

  Map<String, dynamic>? _vehicleOf(int? tripId) => _vehicleById[trId(_trip(tripId)?['vehicle_id'])];
  /// The students the vehicle of [tripId] may take: its seats plus its
  /// additional capacity. Every count of seats on this screen uses it.
  int _seats(int tripId) => _seatsOnly(tripId) == 0 ? 0 : _seatsOnly(tripId) + _extra(tripId);
  int _seatsOnly(int tripId) => trId(_vehicleOf(tripId)?['seating_capacity']) ?? 0;
  int _extra(int tripId) => math.max(0, trId(_vehicleOf(tripId)?['additional_capacity']) ?? 0);

  String _busName(int tripId) {
    final code = trText(_vehicleOf(tripId)?['vehicle_code']);
    return code.isEmpty ? 'This vehicle' : code;
  }

  Map<String, dynamic>? _stopOf(int id) => _stopById[trId(_riders[id]?[_stopCol])];
  String _stopName(int id) => trText(_stopOf(id)?['stop_name']);

  /// By the student's stop in route order, then by name.
  int _byStop(int a, int b) {
    final c = (trId(_stopOf(a)?['stop_seq']) ?? 1 << 20).compareTo(trId(_stopOf(b)?['stop_seq']) ?? 1 << 20);
    return c != 0 ? c : trText(_riders[a]?['stuname']).compareTo(trText(_riders[b]?['stuname']));
  }

  /// The students in the vehicle of [tripId], as the board stands.
  List<int> _in(int tripId) => [
        for (final e in _now.entries)
          if (e.value == tripId) e.key,
      ]..sort(_byStop);

  /// The students with no vehicle (or one whose trip is no longer listed).
  List<int> get _waiting {
    final trips = _tripIds;
    return [
      for (final e in _now.entries)
        if (e.value == null || !trips.contains(e.value)) e.key,
    ]..sort(_byStop);
  }

  bool _isStaff(int id) => _riders[id]?['is_staff'] == true;

  /// Who the Not Allotted list shows: ALL, STUDENTS or STAFF.
  String _who = 'ALL';

  bool _whoShows(int id) => _who == 'ALL' || (_who == 'STAFF') == _isStaff(id);

  List<int> get _waitingShown {
    final q = _query.trim().toLowerCase();
    return [
      for (final id in _waiting)
        if (_whoShows(id) &&
            (q.isEmpty ||
                '${_riders[id]?['stuadmno']} ${_riders[id]?['stuname']} ${_riders[id]?['stuclass']} ${_stopName(id)}'.toLowerCase().contains(q)))
          id,
    ];
  }

  /// All / Students / Staff, with how many of each have no vehicle. Ticks
  /// stay only on the rows still shown, so a drag never moves hidden ones.
  Widget _whoPicker(List<int> waiting) {
    final staff = waiting.where(_isStaff).length;
    Widget chip(String value, String label, int n) => ChoiceChip(
          key: ValueKey('al-who-$value'),
          label: Text('$label · $n'),
          selected: _who == value,
          onSelected: _saving
              ? null
              : (_) => setState(() {
                    _who = value;
                    final shown = _waitingShown.toSet();
                    _ticked.retainWhere(shown.contains);
                  }),
        );
    return Wrap(spacing: 6.w, runSpacing: 6.h, children: [
      chip('ALL', 'All', waiting.length),
      chip('STUDENTS', 'Students', waiting.length - staff),
      chip('STAFF', 'Staff', staff),
    ]);
  }

  int get _changeCount => _now.entries.where((e) => e.value != _saved[e.key]).length;

  void _dirty() {
    final now = _changeCount > 0;
    if (now != _wasDirty) {
      _wasDirty = now;
      widget.onDirtyChanged?.call(now);
    }
  }

  void _edit(VoidCallback change) {
    setState(change);
    _dirty();
  }

  /// Whether [ids] fit in the free seats of the vehicle of [tripId].
  bool _fits(List<int> ids, int tripId) => ids.where((id) => _now[id] != tripId).length <= _seats(tripId) - _in(tripId).length;

  /// Puts students into the vehicle of trip [to], or takes them out (null),
  /// if its seats allow; otherwise says how many fit and changes nothing.
  void _move(List<int> ids, int? to) {
    final moving = [
      for (final id in ids)
        if (_now.containsKey(id) && _now[id] != to) id,
    ];
    if (moving.isEmpty) return;
    if (to != null) {
      final free = _seats(to) - _in(to).length;
      if (moving.length > free) {
        final bus = _busName(to);
        trSnack(
          context,
          free <= 0
              ? '$bus is full: all ${_seats(to)} seats are taken.'
              : '$bus has $free free seat${free == 1 ? '' : 's'}, not ${moving.length}. Tick fewer students, or use another vehicle.',
          AppColors.warning,
        );
        return;
      }
    }
    _edit(() {
      for (final id in moving) {
        _now[id] = to;
      }
      _ticked.removeAll(moving);
    });
  }

  /// A student dragged from the list: all the ticked ones when it is ticked.
  List<int> _dragIds(int id) => _ticked.contains(id) ? [for (final x in _waiting) if (_ticked.contains(x)) x] : [id];

  // ── copy from the other way ────────────────────────────────────────────────
  String get _otherCol => widget.direction == 'PICKUP' ? 'drop_schedule_id' : 'pickup_schedule_id';
  String get _otherWay => widget.direction == 'PICKUP' ? 'drop' : 'pickup';

  /// What Copy from the other way would do. Only a student who travels BOTH
  /// ways is copied: into this way's trip run by the vehicle they have the
  /// other way (as saved), when exactly one such trip runs on the route and
  /// it has a free seat. A student who travels this way only is left as is
  /// (one who travels the other way only is not on this board at all). One
  /// already in another vehicle this way moves only when [replace].
  _CopyPlan _copyPlan({required bool replace}) {
    final p = _CopyPlan();
    final listed = _tripIds;
    final tripsOfVehicle = <int, List<int>>{};
    for (final t in _trips) {
      final v = trId(t['vehicle_id']);
      if (v != null) tripsOfVehicle.putIfAbsent(v, () => []).add(trId(t['schedule_id'])!);
    }
    final vehicleOfOther = <int, int?>{
      for (final t in widget.otherTrips)
        if (trId(t['schedule_id']) != null) trId(t['schedule_id'])!: trId(t['vehicle_id']),
    };
    final free = {for (final id in listed) id: _seats(id) - _in(id).length};
    for (final id in _riders.keys.toList()..sort(_byStop)) {
      final e = _riders[id]!;
      if (e['service_type'] != 'BOTH') {
        p.oneWay++;
        continue;
      }
      final other = trId(e[_otherCol]);
      if (other == null) {
        p.noVehicle++;
        continue;
      }
      final vehicle = vehicleOfOther[other];
      final targets = vehicle == null ? const <int>[] : (tripsOfVehicle[vehicle] ?? const <int>[]);
      if (targets.isEmpty) {
        p.noTrip++;
        continue;
      }
      if (targets.length > 1) {
        p.manyTrips++;
        continue;
      }
      final to = targets.single;
      final now = _now[id];
      if (now == to) {
        p.same++;
        continue;
      }
      final from = now != null && listed.contains(now) ? now : null;
      if (from != null) {
        p.elsewhere++;
        if (!replace) continue;
      }
      if (free[to]! <= 0) {
        p.full++;
        continue;
      }
      free[to] = free[to]! - 1;
      if (from != null) free[from] = free[from]! + 1;
      p.moves[id] = to;
    }
    return p;
  }

  /// Shows what Copy from the other way would do; on Copy, puts the students
  /// in on the board (not saved until Save, like a drag).
  Future<void> _copy() async {
    final other = _otherWay;
    final otherTitle = other == 'drop' ? 'Drop' : 'Pickup';
    var replace = false;
    final plan = await showDialog<_CopyPlan>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) {
          final p = _copyPlan(replace: replace);
          Widget line(String label, int n, {bool strong = false, Color? color}) => Padding(
                padding: EdgeInsets.only(top: 6.h),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Text(label,
                        style: strong ? AppUI.label.copyWith(color: color ?? AppColors.ink) : AppUI.muted.copyWith(color: color)),
                  ),
                  SizedBox(width: 12.w),
                  Text('$n', style: AppUI.label.copyWith(color: color ?? AppColors.ink)),
                ]),
              );
          return AlertDialog(
            title: Text('Copy from $otherTitle'),
            content: SizedBox(
              width: 460,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'Each student who travels both ways goes into the vehicle they have for the $other. '
                  'Students who travel the $_way only are left as they are.',
                  style: AppUI.muted,
                ),
                SizedBox(height: 8.h),
                line('Put in their $other vehicle', p.moves.length, strong: true),
                if (p.same > 0) line('Already in the same vehicle', p.same),
                if (p.oneWay > 0) line('Travel the $_way only: left as they are', p.oneWay),
                if (p.noVehicle > 0) line('No $other vehicle yet', p.noVehicle),
                if (p.noTrip > 0) line('Their $other vehicle runs no $_way trip on this route', p.noTrip),
                if (p.manyTrips > 0) line('Their $other vehicle runs more than one $_way trip here: put them in by hand', p.manyTrips),
                if (p.full > 0) line('No free seat left in the vehicle', p.full, color: AppColors.error),
                if (p.elsewhere > 0) ...[
                  SizedBox(height: 8.h),
                  CheckboxListTile(
                    key: const ValueKey('al-copy-replace'),
                    value: replace,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text('Also move the ${p.elsewhere} already in a different $_way vehicle'),
                    onChanged: (v) => setInner(() => replace = v == true),
                  ),
                ],
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppText.cancel)),
              ElevatedButton(
                key: const ValueKey('al-copy-go'),
                onPressed: p.moves.isEmpty ? null : () => Navigator.pop(ctx, p),
                style: AppUI.primary(ctx),
                child: Text(p.moves.isEmpty ? 'Nothing to Copy' : 'Copy ${p.moves.length}'),
              ),
            ],
          );
        },
      ),
    );
    if (plan == null || !mounted) return;
    _edit(() {
      _now.addAll(plan.moves);
      _ticked.removeAll(plan.moves.keys);
    });
    final n = plan.moves.length;
    trSnack(context, '$n student${n == 1 ? '' : 's'} put in their $other vehicle. Check, then Save.', AppColors.success);
  }

  void _undoAll() => _edit(() {
        _now = Map.of(_saved);
        _ticked.clear();
      });

  Future<void> _save() async {
    final rows = [
      for (final e in _now.entries)
        if (e.value != _saved[e.key]) {'enrollment_id': e.key, 'schedule_id': e.value, 'updated_at': _riders[e.key]?['updated_at']},
    ];
    if (rows.isEmpty) return;
    // a vehicle that gets students must have seats for them all
    final targets = {for (final r in rows) if (r['schedule_id'] != null) r['schedule_id'] as int};
    for (final t in targets) {
      final n = _in(t).length;
      if (n > _seats(t)) {
        trSnack(context, '${_busName(t)} has $n students for ${_seats(t)} seats. Take some out first.', AppColors.warning);
        return;
      }
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(rows);
      if (!mounted) return;
      setState(() => _saving = false);
      _dirty();
      trSnack(context, rows.length == 1 ? 'Saved 1 change.' : 'Saved ${rows.length} changes.', AppColors.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  // ── pieces ─────────────────────────────────────────────────────────────────
  Widget _dragChip(String text) => Material(
        elevation: 6,
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const AppIcon('people', size: 16, color: AppColors.onPrimary),
            const SizedBox(width: 6),
            Text(text, style: AppUI.label.copyWith(color: AppColors.onPrimary)),
          ]),
        ),
      );

  /// Red when over the seats, gold when nearly full, else the app colour.
  Color _fillColor(int taken, int seats) {
    final share = seats <= 0 ? 0.0 : taken / seats;
    return taken > seats ? AppColors.error : (share >= 0.9 ? AppColors.goldDark : AppColors.primary);
  }

  Widget _seatBar(int taken, int seats, {double height = 6}) {
    final share = seats <= 0 ? 0.0 : (taken / seats).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
          value: share, minHeight: height, backgroundColor: AppColors.line, valueColor: AlwaysStoppedAnimation(_fillColor(taken, seats))),
    );
  }

  String _seatText(int taken, int seats) {
    if (seats <= 0) return 'Vehicle not found';
    final free = seats - taken;
    return '$taken of $seats seats · ${free < 0 ? '${-free} over' : '$free free'}';
  }

  // ── vehicles (top) ─────────────────────────────────────────────────────────
  /// A vehicle of the route that way: its picture, number, trip, times and
  /// seats filled. A click opens it on the right; students can be dropped on
  /// it too.
  Widget _tripCard(Map<String, dynamic> t) {
    final id = trId(t['schedule_id'])!;
    final v = _vehicleOf(id);
    final code = trText(v?['vehicle_code']);
    final seats = _seats(id), taken = _in(id).length;
    final open = _open == id;
    return DragTarget<List<int>>(
      key: ValueKey('al-trip-$id'),
      onWillAcceptWithDetails: (_) => !_saving,
      onAcceptWithDetails: (d) => _move(d.data, id),
      builder: (context, over, _) {
        final held = over.isEmpty ? null : over.first;
        final fits = held == null || _fits(held, id);
        final edge = held != null ? (fits ? AppColors.primary : AppColors.error) : (open ? AppColors.primary : AppColors.line);
        return Material(
          color: held != null && !fits ? AppColors.error.withValues(alpha: 0.06) : (open || held != null ? AppColors.primarySoft : AppColors.card),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: edge, width: open || held != null ? 2 : 1)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => _open = id),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 7.h),
              child: SizedBox(
                width: 196,
                child: Row(children: [
                  SizedBox(width: 50, height: 23, child: CustomPaint(painter: VehiclePainter(type: trText(v?['vehicle_type'])))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: code.isEmpty ? '-' : code, style: AppUI.label.copyWith(color: AppColors.ink)),
                              TextSpan(
                                  text: '   ${trText(t['schedule_code'])}',
                                  style: AppUI.label.copyWith(fontWeight: FontWeight.w600, color: AppColors.ink2)),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message: _seatText(taken, seats),
                          child: Text(seats <= 0 ? '$taken/–' : '$taken/$seats',
                              style: AppUI.cell.copyWith(
                                  fontSize: 12.sp,
                                  fontWeight: FontWeight.w700,
                                  color: taken > seats || seats <= 0 ? AppColors.error : (taken >= seats * 0.9 ? AppColors.goldDark : AppColors.ink2))),
                        ),
                      ]),
                      Text('${trTimeText(t['planned_start'])} – ${trTimeText(t['planned_end'])}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
                      SizedBox(height: 4.h),
                      _seatBar(taken, seats, height: 3),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _strip() {
    if (_trips.isEmpty) {
      return Container(
        padding: EdgeInsets.all(14.w),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.line)),
        child: Text(
          'No $_way trip runs on this route yet. Add one in Trip Schedules: the vehicle that runs it appears here.',
          style: AppUI.muted,
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < _trips.length; i++) ...[
          if (i > 0) SizedBox(width: 12.w),
          _tripCard(_trips[i]),
        ],
      ]),
    );
  }

  // ── not allotted (left) ────────────────────────────────────────────────────
  Widget _waitingRow(int id, int i) {
    final e = _riders[id]!;
    final ticked = _ticked.contains(id);
    // saved on a trip that is not listed any more (switched off)
    final stale = _now[id] != null && !_tripIds.contains(_now[id]);
    final row = Container(
      key: ValueKey('al-wait-$id'),
      decoration: BoxDecoration(color: ticked ? AppColors.primarySoft : (i.isEven ? Colors.white : AppColors.surface), border: const Border(bottom: BorderSide(color: AppColors.divider))),
      padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 3.h),
      child: Row(children: [
        Checkbox(
          value: ticked,
          onChanged: _saving
              ? null
              : (v) => setState(() {
                    if (v == true) {
                      _ticked.add(id);
                    } else {
                      _ticked.remove(id);
                    }
                  }),
        ),
        const Icon(Icons.drag_indicator, size: 18, color: AppColors.ink3),
        const SizedBox(width: 4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(trText(e['stuname']),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label.copyWith(color: AppColors.ink)),
            Text(
              [trText(e['stuadmno']), trText(e['stuclass']), _stopName(id)].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUI.muted,
            ),
            if (stale) Text('Its trip is switched off', style: AppUI.muted.copyWith(color: AppColors.error)),
          ]),
        ),
      ]),
    );
    if (_saving) return row;
    final ids = _dragIds(id);
    return Draggable<List<int>>(
      data: ids,
      feedback: _dragChip(ids.length == 1 ? trText(e['stuname']) : '${ids.length} students'),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }

  Widget _waitingPanel() {
    final waiting = _waiting;
    final shown = _waitingShown;
    final all = shown.isNotEmpty && shown.every(_ticked.contains);
    final some = shown.any(_ticked.contains);
    return DragTarget<List<int>>(
      key: const ValueKey('al-waiting'),
      onWillAcceptWithDetails: (d) => !_saving && d.data.any((id) => _tripIds.contains(_now[id])),
      onAcceptWithDetails: (d) => _move(d.data, null),
      builder: (context, over, _) => Container(
        width: _sideW,
        decoration: over.isEmpty ? AppUI.card() : AppUI.card().copyWith(border: Border.all(color: AppColors.primary, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _panelHead(
            'NOT ALLOTTED · ${waiting.length}',
            _riders.isEmpty
                ? 'No student travels the $_way on this route.'
                : waiting.isEmpty
                    ? 'Every student has a vehicle for the $_way.'
                    : 'Drag onto a vehicle. Tick several to move them together.',
            more: 'Until a student has a vehicle, they are expected on every $_way trip of the route. '
                'Students join the route in Student Enrollment.',
            below: [
              if (waiting.isNotEmpty) ...[
                // students and staff: pick which the list shows
                if (_staffCount > 0) ...[SizedBox(height: 10.h), _whoPicker(waiting)],
                SizedBox(height: 10.h),
                TrSearchField(
                  hint: _staffCount > 0 ? 'Adm no, emp code, name or stop' : 'Adm no, name, class or stop',
                  onChanged: (v) => setState(() => _query = v),
                ),
              ],
            ],
          ),
          if (shown.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4.w),
              child: Row(children: [
                Checkbox(
                  tristate: true,
                  value: all ? true : (some ? null : false),
                  onChanged: _saving
                      ? null
                      : (_) => setState(() {
                            if (all) {
                              _ticked.removeAll(shown);
                            } else {
                              _ticked.addAll(shown);
                            }
                          }),
                ),
                Expanded(child: Text(all ? 'Untick all' : 'Tick all shown', style: AppUI.muted)),
                if (_ticked.isNotEmpty) Text('${_ticked.length} ticked', style: AppUI.muted.copyWith(fontWeight: FontWeight.w700)),
                SizedBox(width: 8.w),
              ]),
            ),
          Expanded(
            child: shown.isNotEmpty
                ? ListView.builder(itemCount: shown.length, itemBuilder: (_, i) => _waitingRow(shown[i], i))
                : _riders.isEmpty
                    ? _emptyNote('people', 'No students', 'Add students or staff to this route in Student/Staff Enrollment.')
                    : waiting.isEmpty
                        ? _emptyNote('tick-circle', 'All allotted', 'Every student has a vehicle for the $_way.')
                        : _emptyNote(
                            'search-normal',
                            _who == 'STAFF' ? 'No staff member matches' : (_who == 'STUDENTS' ? 'No student matches' : 'Nobody matches'),
                            _who == 'ALL' ? 'Try another search.' : 'Try another search, or All.',
                            color: AppColors.ink3,
                          ),
          ),
        ]),
      ),
    );
  }

  /// The head of a side list, like a table head: the small-caps title with
  /// its count, a one-line hint (more on the info icon), then [below].
  Widget _panelHead(String title, String hint, {Color? hintColor, String? more, List<Widget> below = const []}) => Container(
        decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
        padding: EdgeInsets.fromLTRB(14.w, 11.h, 14.w, 11.h),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text(title, style: AppUI.tableHead)),
            if (more != null)
              Tooltip(
                message: more,
                child: const AppIcon('info-circle', size: 15, color: AppColors.ink3),
              ),
          ]),
          SizedBox(height: 3.h),
          Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppUI.muted.copyWith(color: hintColor)),
          ...below,
        ]),
      );

  /// A quiet empty state inside a panel: an icon tile, a title and why.
  Widget _emptyNote(String icon, String title, String why, {Color color = AppColors.primary}) => Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(20.w),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AppUI.iconTile(icon, color: color, size: 18),
            SizedBox(height: 10.h),
            Text(title, textAlign: TextAlign.center, style: AppUI.label),
            SizedBox(height: 3.h),
            Text(why, textAlign: TextAlign.center, style: AppUI.muted),
          ]),
        ),
      );

  // ── the open vehicle (right) ───────────────────────────────────────────────
  static const double _seatW = 58, _seatH = 42, _gap = 5, _aisle = 18;

  /// The width of the two side lists: Not Allotted, and In This Vehicle.
  static const double _sideW = 310;
  static const _shell = Color(0xFFE2A93B);
  static const _floor = Color(0xFFFFFBF1);
  static const _glass = Color(0xFF557385);

  /// A seat: the student on it (drag it back to the list, or to another
  /// vehicle), or Free. A seat past the vehicle's seats shows in red.
  Widget _seat(int no, int? id, {required bool over}) {
    if (id == null) {
      // a free seat: only its number, quiet, as on a seat map
      return Container(
        key: ValueKey('al-free-$no'),
        width: _seatW,
        height: _seatH,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9), border: Border.all(color: AppColors.lineStrong)),
        child: Text('$no', style: AppUI.cell.copyWith(fontSize: 11.5, color: AppColors.ink3)),
      );
    }
    final e = _riders[id]!;
    final changed = _now[id] != _saved[id];
    final tile = Container(
      key: ValueKey('al-seat-$id'),
      width: _seatW,
      height: _seatH,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: over ? AppColors.error.withValues(alpha: 0.10) : (changed ? AppColors.goldSoft : AppColors.primarySoft),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: over ? AppColors.error : (changed ? AppColors.gold : AppColors.primary), width: 1.2),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text('$no',
            style: AppUI.cell.copyWith(fontSize: 10, color: over ? AppColors.error : (changed ? AppColors.goldInk : AppColors.primaryText))),
        Text(trText(e['stuname']).split(' ').first,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label.copyWith(fontSize: 11, color: AppColors.ink)),
      ]),
    );
    final tip = Tooltip(
      message: [trText(e['stuadmno']), trText(e['stuname']), trText(e['stuclass']), _stopName(id)].where((s) => s.isNotEmpty).join(' · '),
      child: tile,
    );
    if (_saving) return tip;
    return Draggable<List<int>>(
      data: [id],
      feedback: _dragChip(trText(e['stuname'])),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tip,
    );
  }

  /// The colour key of the seats: taken, moved but not saved, free (and over
  /// the seats, only when some are).
  Widget _seatKey({required bool over}) {
    Widget item(String label, Color fill, Color edge) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(3), border: Border.all(color: edge)),
          ),
          const SizedBox(width: 5),
          Text(label, style: AppUI.muted.copyWith(fontSize: 11.5.sp)),
        ]);
    return Wrap(spacing: 12, runSpacing: 4, children: [
      item('Allotted', AppColors.primarySoft, AppColors.primary),
      item('Not saved', AppColors.goldSoft, AppColors.gold),
      item('Free', Colors.white, AppColors.lineStrong),
      if (over) item('Over seats', AppColors.error.withValues(alpha: 0.10), AppColors.error),
    ]);
  }

  /// The vehicle seen from above, lying on its side so it fits the bay's
  /// width without scrolling: the front (windscreen, driver, door) on the
  /// right, then columns of seats going back to the left (2 + 2 across the
  /// aisle, or 2 + 1 for a small vehicle). Seat 1 is just behind the driver;
  /// the seats fill with its students in stop order. Students dropped on it
  /// go into it. The bay scales it down when the window is small.
  Widget _topView(int tripId, List<int> inside, int seats) {
    final total = math.max(seats, inside.length);
    final perCol = seats <= 16 ? 3 : 4;
    final cols = (total / perCol).ceil();
    // the height of a column of seats: two, the aisle, then one or two
    final colH = _seatH * perCol + _gap * (perCol - 2) + _aisle;
    Widget seatAt(int n) {
      if (n >= total) return const SizedBox(width: _seatW, height: _seatH);
      return _seat(n + 1, n < inside.length ? inside[n] : null, over: n >= seats);
    }

    Widget column(int c) => Column(mainAxisSize: MainAxisSize.min, children: [
          seatAt(c * perCol),
          const SizedBox(height: _gap),
          seatAt(c * perCol + 1),
          const SizedBox(height: _aisle),
          for (var k = 2; k < perCol; k++) ...[
            if (k > 2) const SizedBox(height: _gap),
            seatAt(c * perCol + k),
          ],
        ]);

    return DragTarget<List<int>>(
      key: const ValueKey('al-bus'),
      onWillAcceptWithDetails: (_) => !_saving,
      onAcceptWithDetails: (d) => _move(d.data, tripId),
      builder: (context, over, _) {
        final held = over.isEmpty ? null : over.first;
        final fits = held == null || _fits(held, tripId);
        final body = Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: held == null ? _floor : (fits ? AppColors.primarySoft : AppColors.error.withValues(alpha: 0.06)),
            border: Border.all(color: held == null ? _shell : (fits ? AppColors.primary : AppColors.error), width: 3),
            // the back square-ish on the left, the rounded front on the right
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(16), right: Radius.circular(46)),
            boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, 4))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (total == 0)
              SizedBox(
                width: 240,
                height: colH,
                child: Center(
                  child: Text('This vehicle has no seats set. Set its seating capacity in Vehicles.',
                      textAlign: TextAlign.center, style: AppUI.muted),
                ),
              ),
            // the back of the vehicle on the left, seat 1 at the front
            for (var c = cols - 1; c >= 0; c--) ...[
              column(c),
              if (c > 0) const SizedBox(width: _gap),
            ],
            const SizedBox(width: 10),
            Container(width: 1, height: colH, color: AppColors.line),
            const SizedBox(width: 10),
            // the driver at the front, the door below
            SizedBox(
              height: colH,
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Container(
                  width: _seatW,
                  height: 50,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: AppColors.lineStrong),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const AppIcon('driver', size: 16, color: AppColors.ink2),
                    const SizedBox(height: 2),
                    Text('Driver', maxLines: 1, style: AppUI.muted.copyWith(fontSize: 11)),
                  ]),
                ),
                Container(
                  width: _seatW,
                  height: 46,
                  decoration: BoxDecoration(
                    border: Border.all(color: _shell, width: 1.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text('DOOR', style: AppUI.cell.copyWith(fontSize: 10, color: AppColors.goldDark, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            const SizedBox(width: 10),
            // the windscreen
            Container(
              width: 9,
              height: colH - 50,
              decoration: BoxDecoration(color: _glass, borderRadius: BorderRadius.circular(6)),
            ),
          ]),
        );
        // the line under it keeps its room, so the scaled bus does not jump
        // when a drag over it does not fit
        return Column(mainAxisSize: MainAxisSize.min, children: [
          body,
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Visibility.maintain(
              visible: held != null && !fits,
              child: Text('Not enough free seats', style: AppUI.muted.copyWith(color: AppColors.error, fontWeight: FontWeight.w700)),
            ),
          ),
        ]);
      },
    );
  }

  /// A student in the open vehicle, set out like a Not Allotted row: the seat,
  /// the name, then adm no · class · stop, and Take Out. Drag it back to Not
  /// Allotted or onto another vehicle.
  Widget _insideRow(int id, int i, int seats) {
    final e = _riders[id]!;
    final over = i >= seats;
    final changed = _now[id] != _saved[id];
    final row = Container(
      key: ValueKey('al-in-$id'),
      decoration: BoxDecoration(color: i.isEven ? Colors.white : AppColors.surface, border: const Border(bottom: BorderSide(color: AppColors.divider))),
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
      child: Row(children: [
        // the seat, coloured like its tile in the vehicle
        Container(
          width: 30,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: over ? AppColors.error.withValues(alpha: 0.10) : (changed ? AppColors.goldSoft : AppColors.primarySoft),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: over ? AppColors.error : (changed ? AppColors.gold : AppColors.primary)),
          ),
          child: Text('${i + 1}',
              style: AppUI.cell.copyWith(
                  fontSize: 11, fontWeight: FontWeight.w700, color: over ? AppColors.error : (changed ? AppColors.goldInk : AppColors.primaryText))),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.drag_indicator, size: 18, color: AppColors.ink3),
        const SizedBox(width: 4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(trText(e['stuname']),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label.copyWith(color: AppColors.ink)),
            Text(
              [trText(e['stuadmno']), trText(e['stuclass']), _stopName(id)].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUI.muted,
            ),
          ]),
        ),
        IconButton(
          tooltip: 'Take out',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: _saving ? null : () => _move([id], null),
          icon: const AppIcon.linear('close-circle', size: 16, color: AppColors.error),
        ),
      ]),
    );
    if (_saving) return row;
    return Draggable<List<int>>(
      data: [id],
      feedback: _dragChip(trText(e['stuname'])),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }

  /// The students in the open vehicle, in seat order, beside the vehicle:
  /// a head like Not Allotted's, the rows scrolling under it. Students
  /// dropped on it go into this vehicle, as on the vehicle itself.
  Widget _insideList(int tripId, List<int> inside, int seats) {
    return DragTarget<List<int>>(
      key: const ValueKey('al-inside'),
      onWillAcceptWithDetails: (_) => !_saving,
      onAcceptWithDetails: (d) => _move(d.data, tripId),
      builder: (context, over, _) {
        final held = over.isEmpty ? null : over.first;
        final fits = held == null || _fits(held, tripId);
        final otherTitle = _otherWay == 'drop' ? 'Drop' : 'Pickup';
        return Container(
          color: held == null ? null : (fits ? AppColors.primaryTint : AppColors.errorTint),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _panelHead(
              'IN THIS VEHICLE · ${inside.length}',
              held != null && !fits
                  ? 'Not enough free seats'
                  : inside.isEmpty
                      ? 'Drop students here or on the seats.'
                      : 'In seat order. Drag one back to Not Allotted, or onto another vehicle.',
              hintColor: held != null && !fits ? AppColors.error : null,
            ),
            Expanded(
              child: inside.isEmpty
                  ? _emptyNote('people', 'No students yet', 'Drag students here from Not Allotted, or use Copy from $otherTitle.')
                  : ListView.builder(itemCount: inside.length, itemBuilder: (_, i) => _insideRow(inside[i], i, seats)),
            ),
          ]),
        );
      },
    );
  }

  /// A registration number set out like a number plate.
  Widget _plate(String reg) => Container(
        padding: EdgeInsets.symmetric(horizontal: 7.w, vertical: 2.h),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.ink2, width: 1.2),
        ),
        child: Text(reg, maxLines: 1, style: AppUI.cell.copyWith(fontSize: 11.5.sp, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: 0.6)),
      );

  /// A detail of the trip with its icon: code, times, days.
  Widget _meta(String icon, String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AppIcon(icon, size: 14, color: AppColors.ink3),
      SizedBox(width: 5.w),
      Text(text, style: AppUI.muted),
    ]);
  }

  Widget _busPanel() {
    final id = _open;
    if (id == null) {
      return Container(
        decoration: AppUI.card(),
        child: AppUI.empty(title: 'No vehicle to show', why: 'Add a $_way trip for this route in Trip Schedules.', icon: 'bus'),
      );
    }
    final t = _trip(id)!;
    final v = _vehicleOf(id);
    final seats = _seats(id);
    final inside = _in(id);
    final code = trText(v?['vehicle_code']), reg = trText(v?['registration_no']);
    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 12.h),
          child: Row(children: [
            // the vehicle's picture on a small tile
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: AppColors.sunken,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.line),
              ),
              child: SizedBox(width: 64, height: 29, child: CustomPaint(painter: VehiclePainter(type: trText(v?['vehicle_type'])))),
            ),
            SizedBox(width: 14.w),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Flexible(
                    child: Text(code.isEmpty ? '-' : code,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.ink)),
                  ),
                  if (reg.isNotEmpty) ...[SizedBox(width: 8.w), _plate(reg)],
                ]),
                SizedBox(height: 4.h),
                Wrap(spacing: 14.w, runSpacing: 2.h, children: [
                  _meta('routing', trText(t['schedule_code'])),
                  _meta('clock', '${trTimeText(t['planned_start'])} – ${trTimeText(t['planned_end'])}'),
                  _meta('calendar', trDaysText(t['run_days'])),
                  if (_extra(id) > 0) _meta('people', '${_seatsOnly(id)} seats + ${_extra(id)} additional'),
                ]),
              ]),
            ),
            SizedBox(width: 12.w),
            SizedBox(
              width: 170,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                Text(_seatText(inside.length, seats),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label.copyWith(color: AppColors.ink)),
                SizedBox(height: 5.h),
                _seatBar(inside.length, seats),
              ]),
            ),
          ]),
        ),
        const Divider(height: 1),
        // the vehicle in a soft bay with its key, taking the free width; its
        // students beside it, as wide as the Not Allotted list
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Container(
                color: AppColors.sunken,
                padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 10.h),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(child: _seatKey(over: inside.length > seats)),
                  SizedBox(height: 8.h),
                  // the whole vehicle always in view: never scrolls, shrinks to fit
                  Expanded(
                    child: Center(
                      child: FittedBox(fit: BoxFit.scaleDown, child: _topView(id, inside, seats)),
                    ),
                  ),
                ]),
              ),
            ),
            const VerticalDivider(width: 1, color: AppColors.line),
            SizedBox(width: _sideW, child: _insideList(id, inside, seats)),
          ]),
        ),
      ]),
    );
  }

  /// A count pill of the summary: a coloured dot, the number, what it counts.
  Widget _stat(int n, String label, Color dot, {bool warn = false}) => Container(
        padding: EdgeInsets.symmetric(horizontal: 11.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: warn ? AppColors.goldSoft : AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: warn ? AppColors.goldLine : AppColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          SizedBox(width: 7.w),
          Text('$n', style: AppUI.label.copyWith(color: warn ? AppColors.goldInk : AppColors.ink)),
          SizedBox(width: 4.w),
          Text(label, style: AppUI.muted.copyWith(color: warn ? AppColors.goldInk : null)),
        ]),
      );

  /// The staff among the riders (see allotmentRiders).
  int get _staffCount => _riders.values.where((e) => e['is_staff'] == true).length;

  Widget _toolbar(int changes) {
    final waiting = _waiting.length;
    return Row(children: [
      Expanded(
        child: Wrap(spacing: 8.w, runSpacing: 6.h, children: [
          _stat(_riders.length - _staffCount, _riders.length - _staffCount == 1 ? 'student' : 'students', AppColors.ink3),
          if (_staffCount > 0) _stat(_staffCount, 'staff', AppColors.ink3),
          _stat(_riders.length - waiting, 'allotted', AppColors.primary),
          _stat(waiting, 'not allotted', waiting > 0 ? AppColors.gold : AppColors.ink3),
          if (changes > 0) _stat(changes, changes == 1 ? 'change not saved' : 'changes not saved', AppColors.goldDark, warn: true),
        ]),
      ),
      SizedBox(width: 10.w),
      Tooltip(
        message: 'Put each student who travels both ways in the vehicle they have for the $_otherWay',
        child: OutlinedButton.icon(
          key: const ValueKey('al-copy'),
          onPressed: _saving || _trips.isEmpty || _riders.isEmpty ? null : _copy,
          style: AppUI.secondary(context),
          icon: AppIcon('copy', size: AppBtn.iconSize(context), color: AppColors.primaryText),
          label: Text('Copy from ${_otherWay == 'drop' ? 'Drop' : 'Pickup'}'),
        ),
      ),
      // Undo All only while there is something to undo: quieter than Save
      if (changes > 0) ...[
        SizedBox(width: 6.w),
        TextButton.icon(
          onPressed: _saving ? null : _undoAll,
          style: TextButton.styleFrom(foregroundColor: AppColors.ink2, minimumSize: Size(0, AppUI.buttonHeight(context))),
          icon: AppIcon('rotate-left', size: AppBtn.iconSize(context), color: AppColors.ink2),
          label: const Text('Undo All'),
        ),
      ],
      SizedBox(width: 10.w),
      ElevatedButton.icon(
        onPressed: changes == 0 || _saving ? null : _save,
        style: AppUI.primary(context),
        icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
        label: Text(_saving ? 'Saving...' : (changes == 0 ? AppText.save : 'Save $changes Change${changes == 1 ? '' : 's'}')),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final changes = _changeCount;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _toolbar(changes),
      SizedBox(height: 10.h),
      _strip(),
      SizedBox(height: 12.h),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _waitingPanel(),
          SizedBox(width: 14.w),
          Expanded(child: _busPanel()),
        ]),
      ),
    ]);
  }
}

/// What Copy from the other way would do on the board, and why the students
/// it leaves out are left out.
class _CopyPlan {
  /// Enrollment id -> this way's trip to put the student in.
  final Map<int, int> moves = {};
  int same = 0; // already in that vehicle
  int oneWay = 0; // travel this way only
  int noVehicle = 0; // no vehicle the other way yet
  int noTrip = 0; // that vehicle runs no trip this way on the route
  int manyTrips = 0; // ... or more than one, so which is not known
  int full = 0; // no free seat left in it
  int elsewhere = 0; // in another vehicle this way (moved only when asked)
}

// ── picture ──────────────────────────────────────────────────────────────────
/// A side view of a vehicle, only as a picture beside its numbers: a school
/// bus, or a shorter round-nosed van for a van, car, auto or other kind. It
/// faces right, with its windscreen and door at the front.
class VehiclePainter extends CustomPainter {
  final String type;
  const VehiclePainter({required this.type});

  static const _body = Color(0xFFF4B740);
  static const _edge = Color(0xFFCF8F1C);
  static const _glass = Color(0xFF3E5A6B);
  static const _shine = Color(0xFF9DBACB);
  static const _tyre = Color(0xFF2B3238);
  static const _hub = Color(0xFFC3CCD1);

  bool get _small => type == 'VAN' || type == 'CAR' || type == 'AUTO' || type == 'OTHER';

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final small = _small;
    final mini = type == 'MINI_BUS';
    final bottom = h * 0.80;
    final top = h * 0.06;

    // the body, rounded at the front (right); a van has a rounder nose
    final body = RRect.fromRectAndCorners(
      Rect.fromLTRB(w * 0.02, top, w * 0.98, bottom),
      topLeft: const Radius.circular(5),
      bottomLeft: const Radius.circular(4),
      topRight: Radius.circular(h * (small ? 0.42 : 0.20)),
      bottomRight: const Radius.circular(5),
    );
    canvas.drawRRect(body, Paint()..color = _body);
    canvas.drawRRect(
        body,
        Paint()
          ..color = _edge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);

    // a stripe along the side
    canvas.drawLine(Offset(w * 0.03, bottom - h * 0.15), Offset(w * 0.97, bottom - h * 0.15), Paint()
      ..color = _edge
      ..strokeWidth = 1.6);

    // the side windows, each with a glint
    final glass = Paint()..color = _glass;
    final shine = Paint()
      ..color = _shine
      ..strokeWidth = 1.2;
    final count = small ? 2 : (mini ? 3 : 5);
    final left = w * 0.07, right = small ? w * 0.56 : w * 0.73;
    final gap = w * 0.025;
    final ww = (right - left - gap * (count - 1)) / count;
    final wTop = h * 0.16, wBottom = h * 0.43;
    for (var i = 0; i < count; i++) {
      final x = left + i * (ww + gap);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x, wTop, x + ww, wBottom), const Radius.circular(2.5)), glass);
      canvas.drawLine(Offset(x + ww * 0.18, wTop + 2.2), Offset(x + ww * 0.5, wTop + 2.2), shine);
    }

    // the door and the windscreen at the front
    final doorLeft = small ? w * 0.60 : w * 0.765;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(doorLeft, wTop, doorLeft + w * 0.07, bottom - h * 0.05), const Radius.circular(2)),
      Paint()..color = _glass.withValues(alpha: 0.85),
    );
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(small ? w * 0.70 : w * 0.86, wTop, w * 0.965, wBottom + h * 0.03),
        topRight: Radius.circular(h * (small ? 0.30 : 0.15)),
        topLeft: const Radius.circular(2),
        bottomLeft: const Radius.circular(2),
        bottomRight: const Radius.circular(2),
      ),
      glass,
    );

    // the head lamp and the tail lamp
    canvas.drawCircle(Offset(w * 0.952, bottom - h * 0.08), h * 0.04, Paint()..color = const Color(0xFFFFF3C4));
    canvas.drawRect(Rect.fromLTWH(w * 0.02, bottom - h * 0.13, w * 0.014, h * 0.07), Paint()..color = const Color(0xFFE0533D));

    // the wheels
    final r = h * 0.13;
    for (final cx in [w * 0.22, w * (small ? 0.76 : 0.79)]) {
      final c = Offset(cx, bottom);
      canvas.drawCircle(c, r + 1.2, Paint()..color = _edge);
      canvas.drawCircle(c, r, Paint()..color = _tyre);
      canvas.drawCircle(c, r * 0.42, Paint()..color = _hub);
    }
  }

  @override
  bool shouldRepaint(VehiclePainter old) => old.type != type;
}
