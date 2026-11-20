import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/transport_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// TRIP SCHEDULES -- the timetable a bus runs on one route: pickup or drop,
/// the vehicle, the start and end time, the days it runs, and when it reaches
/// each stop. The stops are the route's own (Routes & Stops, tr_stop), in
/// pickup order, or the other way round for a drop; Reverse order turns them
/// round for a route numbered from the school outward. A schedule and its stops
/// are saved together (tr_trip_schedule + tr_trip_schedule_stop); each day's
/// trip and its stops (tr_trip, tr_trip_stop) are made from them by
/// transport_core.fn_generate_trips.
class TripSchedulesScreen extends StatefulWidget {
  const TripSchedulesScreen({super.key});

  @override
  State<TripSchedulesScreen> createState() => _TripSchedulesScreenState();
}

const _directions = <(Object?, String)>[('PICKUP', 'Pickup (to school)'), ('DROP', 'Drop (from school)')];
const _vehicleStatus = {'UNDER_REPAIR': 'Under Repair', 'INACTIVE': 'Inactive', 'SOLD': 'Sold', 'SCRAPPED': 'Scrapped'};

String _today() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _TripSchedulesScreenState extends State<TripSchedulesScreen> {
  List<Map<String, dynamic>> _routes = const [];
  List<Map<String, dynamic>> _stops = const [];
  List<Map<String, dynamic>> _vehicles = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The routes, stops and vehicles the schedules pick from.
  Future<void> _load() async {
    try {
      final r = await Future.wait([
        TransportService.list('route'),
        TransportService.list('stop'),
        TransportService.list('vehicle'),
      ]);
      if (!mounted) return;
      setState(() {
        _routes = r[0];
        _stops = r[1];
        _vehicles = r[2];
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

  static Map<String, dynamic>? _find(List<Map<String, dynamic>> rows, String key, dynamic id) {
    final want = trId(id);
    for (final r in rows) {
      if (trId(r[key]) == want) return r;
    }
    return null;
  }

  String _routeText(dynamic id) {
    final r = _find(_routes, 'route_id', id);
    return r == null ? '-' : '${trText(r['route_code'])} · ${trText(r['route_name'])}';
  }

  String _vehicleText(dynamic id) => trText(_find(_vehicles, 'vehicle_id', id)?['vehicle_code']);

  /// Why a schedule cannot be added yet, or null.
  String? get _blocked {
    final routeWithStops = _routes.any((r) =>
        r['is_active'] != false && _stops.any((p) => trId(p['route_id']) == trId(r['route_id']) && p['is_active'] != false));
    if (!routeWithStops) return 'Add a route and its stops in Routes & Stops first.';
    if (!_vehicles.any((v) => v['status'] == 'ACTIVE')) return 'Add an active vehicle in Vehicles first.';
    return null;
  }

  /// Active, Upcoming (starts later), Ended (past its last day) or Inactive,
  /// with the dates on hover.
  Widget _status(Map<String, dynamic> r) {
    final from = r['effective_from'] as String?, to = r['effective_to'] as String?;
    final (text, status) = r['is_active'] == false
        ? ('Inactive', AppStatus.neutral)
        : (trDaysLeft(to) ?? 0) < 0
            ? ('Ended', AppStatus.neutral)
            : (trDaysLeft(from) ?? 0) > 0
                ? ('Upcoming', AppStatus.info)
                : ('Active', AppStatus.success);
    final dates = to == null ? 'From ${formatDate(from)}' : '${formatDate(from)} to ${formatDate(to)}';
    return Tooltip(message: dates, child: AppUI.chip(text, status));
  }

  Future<TrEdit?> _edit(Map<String, dynamic>? row, List<Map<String, dynamic>> rows) => showDialog<TrEdit>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => TripScheduleDialog(initial: row, routes: _routes, stops: _stops, vehicles: _vehicles),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Trip Schedules',
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
      );
    }
    return Container(
      decoration: AppUI.card(),
      padding: EdgeInsets.all(AppUI.cardPad),
      child: TrPanel(
        key: ValueKey('schedules-${_routes.length}-${_stops.length}-${_vehicles.length}'),
        entity: 'schedule',
        pk: 'schedule_id',
        title: 'Trip Schedules',
        subtitle: 'The timetable each bus runs on a route. Each day\'s trips are made from these.',
        icon: 'timer-1',
        noun: 'schedule',
        emptyWhy: 'Add a schedule: the route, pickup or drop, the vehicle, and the time the bus reaches each stop.',
        addBlockedReason: _blocked,
        columns: [
          TrColumn('Code', flex: 2, text: (r) => trText(r['schedule_code']), mono: true),
          TrColumn('Schedule', flex: 4, text: (r) => trText(r['schedule_name'])),
          TrColumn('Route', flex: 4, text: (r) => _routeText(r['route_id'])),
          TrColumn('Direction', flex: 2, text: (r) => r['direction'] == 'DROP' ? 'Drop' : 'Pickup'),
          TrColumn('Vehicle', flex: 2, text: (r) => _vehicleText(r['vehicle_id']), mono: true),
          TrColumn('Time', flex: 3, text: (r) => '${trTimeText(r['planned_start'])} – ${trTimeText(r['planned_end'])}'),
          TrColumn('Days', flex: 2, text: (r) => trDaysText(r['run_days'])),
          TrColumn('Stops', flex: 1, text: (r) => '${(r['stops'] as List?)?.length ?? 0}', align: TextAlign.right),
          TrColumn('Status', flex: 2, cell: _status),
        ],
        searchText: (r) => '${r['schedule_code']} ${r['schedule_name']} ${_routeText(r['route_id'])} ${_vehicleText(r['vehicle_id'])}',
        fields: (_) => const [],
        editor: _edit,
      ),
    );
  }
}

// ── add / edit ───────────────────────────────────────────────────────────────
/// One stop of the route in the schedule dialog: whether the schedule serves
/// it, when the bus reaches it, and how long the bus waits there.
class _StopLine {
  final Map<String, dynamic> stop;
  bool on;
  String? time; // "07:05"
  String halt; // minutes, as typed
  _StopLine(this.stop, {this.on = false, this.time, this.halt = '1'});

  int get id => trId(stop['stop_id'])!;
  String get name => trText(stop['stop_name']);
  bool get switchedOff => stop['is_active'] == false;

  /// Blank means the usual one minute.
  int? get haltMinutes => int.tryParse(halt.trim().isEmpty ? '1' : halt.trim());
}

/// Add or edit one schedule with its stops (null [initial] = a new one); an
/// existing one can also be deleted (switched off) here. Pops with what it
/// did ([TrEdit]). [routes], [stops] and [vehicles] are the lists it picks
/// from, as tr_list returns them.
class TripScheduleDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final List<Map<String, dynamic>> routes, stops, vehicles;
  const TripScheduleDialog({super.key, required this.initial, required this.routes, required this.stops, required this.vehicles});

  @override
  State<TripScheduleDialog> createState() => _TripScheduleDialogState();
}

class _TripScheduleDialogState extends State<TripScheduleDialog> {
  final _form = GlobalKey<TrFormBodyState>();

  /// The record being edited, or a new one's starting values.
  late final Map<String, dynamic> _start = widget.initial ??
      {
        'direction': 'PICKUP',
        'run_days': const [1, 2, 3, 4, 5, 6],
        'effective_from': _today(),
        'is_active': true,
      };
  late final List<TrField> _fields = _buildFields();

  /// What the form holds now (route, direction, times ...).
  late Map<String, dynamic> _values = Map.of(_start);

  /// The chosen route's stops in the route's own (pickup) order.
  late List<_StopLine> _lines = _linesFor(trId(_start['route_id']), keepSaved: true);

  /// Reverse order is on: the route's stops are numbered from the school
  /// outward, so they run the other way from the usual. An existing schedule
  /// opens the way its stops were saved.
  late bool _reversed = _savedReversed();
  bool _saving = false, _deleting = false;
  bool get _busy => _saving || _deleting;

  int? get _id => trId(widget.initial?['schedule_id']);
  bool get _drop => _values['direction'] == 'DROP';

  /// The stops in the order the bus reaches them: a pickup runs the route's
  /// order and a drop runs it backwards, the other way round with [_reversed].
  List<_StopLine> get _visit => _drop != _reversed ? _lines.reversed.toList() : _lines;

  /// Whether the saved schedule's stops (in visit order) run against the
  /// usual order for its direction.
  bool _savedReversed() {
    final saved = [
      for (final s in (widget.initial?['stops'] as List?) ?? const [])
        if (s is Map) trId(s['stop_id']),
    ];
    if (saved.length < 2) return false;
    int? seqOf(int? id) => trId(_TripSchedulesScreenState._find(widget.stops, 'stop_id', id)?['stop_seq']);
    final first = seqOf(saved.first), last = seqOf(saved.last);
    if (first == null || last == null || first == last) return false;
    return (first > last) != (_start['direction'] == 'DROP');
  }

  List<TrField> _buildFields() {
    final route = trId(_start['route_id']), vehicle = trId(_start['vehicle_id']);
    return [
      const TrField('schedule_code', 'Schedule Code', kind: TrKind.upper, required: true, maxLength: 20, hint: 'e.g. R5-AM', section: 'Schedule'),
      const TrField('schedule_name', 'Schedule Name', required: true, maxLength: 100, hint: 'e.g. R5 Morning Pickup'),
      TrField('route_id', 'Route', kind: TrKind.choice, required: true, options: [
        // switched-off routes are left out, except the one the schedule has
        for (final r in widget.routes)
          if (r['is_active'] != false || trId(r['route_id']) == route)
            (trId(r['route_id']), '${trText(r['route_code'])} - ${trText(r['route_name'])}${r['is_active'] == false ? ' (switched off)' : ''}'),
      ]),
      const TrField('direction', 'Direction', kind: TrKind.choice, required: true, options: _directions),
      TrField('vehicle_id', 'Vehicle', kind: TrKind.choice, required: true, options: [
        // only vehicles in service, except the one the schedule has
        for (final v in widget.vehicles)
          if (v['status'] == 'ACTIVE' || trId(v['vehicle_id']) == vehicle)
            (
              trId(v['vehicle_id']),
              '${trText(v['vehicle_code'])} - ${trText(v['registration_no'])}, ${trText(v['seating_capacity'])} seats'
                  '${v['status'] == 'ACTIVE' ? '' : ' (${_vehicleStatus[v['status']] ?? trText(v['status'])})'}',
            ),
      ]),
      const TrField('is_active', 'Active', kind: TrKind.toggle),
      const TrField('planned_start', 'Start Time', kind: TrKind.time, required: true, section: 'Timing'),
      const TrField('planned_end', 'End Time', kind: TrKind.time, required: true),
      const TrField('effective_from', 'Effective From', kind: TrKind.date, required: true),
      const TrField('effective_to', 'Effective To', kind: TrKind.date),
      const TrField('run_days', 'Run Days', kind: TrKind.days, required: true),
    ];
  }

  /// The stops of [routeId] in the route's order. Switched-off stops are left
  /// out unless the schedule already has them. With [keepSaved] the stops the
  /// schedule has are ticked, with their times, and the others are not; else
  /// (a new schedule, or a newly chosen route) every stop is ticked, no times.
  List<_StopLine> _linesFor(int? routeId, {required bool keepSaved}) {
    if (routeId == null) return [];
    final saved = <int?, Map>{
      if (keepSaved)
        for (final s in (widget.initial?['stops'] as List?) ?? const [])
          if (s is Map) trId(s['stop_id']): s,
    };
    final stops = [
      for (final p in widget.stops)
        if (trId(p['route_id']) == routeId && (p['is_active'] != false || saved.containsKey(trId(p['stop_id'])))) p,
    ]..sort((a, b) => (trId(a['stop_seq']) ?? 0).compareTo(trId(b['stop_seq']) ?? 0));
    final tickAll = !keepSaved || widget.initial == null;
    return [
      for (final p in stops)
        if (saved[trId(p['stop_id'])] case final Map s)
          _StopLine(p, on: true, time: trTimeValue(s['planned_time']), halt: trText(s['halt_minutes']))
        else
          _StopLine(p, on: tickAll),
    ];
  }

  void _changed(Map<String, dynamic> v) {
    final route = trId(v['route_id']);
    setState(() {
      if (route != trId(_values['route_id'])) {
        // back on the schedule's own route, its saved stops come back
        _lines = _linesFor(route, keepSaved: route == trId(widget.initial?['route_id']));
      }
      _values = v;
    });
  }

  /// The time picker starts at this stop's time, else at the time of the
  /// stop before it, else at the schedule's start time.
  Future<void> _pickTime(_StopLine l) async {
    var guess = trMinutes(l.time);
    if (guess == null) {
      for (final x in _visit) {
        if (identical(x, l)) break;
        if (x.on && x.time != null) guess = trMinutes(x.time);
      }
      guess ??= trMinutes(_values['planned_start']) ?? 7 * 60;
    }
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: guess ~/ 60, minute: guess % 60),
      initialEntryMode: TimePickerEntryMode.input,
      helpText: l.name,
    );
    if (picked == null || !mounted) return;
    setState(() => l.time = trHhmm(picked.hour * 60 + picked.minute));
  }

  /// Every ticked stop gets a time spread evenly between the start and end
  /// time. On a pickup the first stop is at the start (the school comes at
  /// the end); on a drop the bus leaves school at the start and reaches the
  /// last stop at the end.
  Future<void> _spread() async {
    final start = trMinutes(_values['planned_start']), end = trMinutes(_values['planned_end']);
    if (start == null || end == null || end <= start) {
      trSnack(context, 'Set the start and end time first, with the end after the start.', AppColors.warning);
      return;
    }
    final on = [for (final l in _visit) if (l.on) l];
    if (on.isEmpty) {
      trSnack(context, 'Tick the stops first.', AppColors.warning);
      return;
    }
    if (on.any((l) => l.time != null)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace the stop times?'),
          content: const Text('Every ticked stop gets a time spread evenly between the start and end time. The times already set are replaced.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.cancel)),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.primary(ctx), child: const Text('Replace')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      for (var i = 0; i < on.length; i++) {
        on[i].time = trHhmm(start + ((end - start) * (_drop ? i + 1 : i) / on.length).round());
      }
    });
  }

  /// The first thing to put right before saving, or null. The server checks
  /// the same rules; this names the stop.
  String? _problem(Map<String, dynamic> row) {
    final start = trMinutes(row['planned_start']), end = trMinutes(row['planned_end']);
    if (start != null && end != null && end <= start) return 'The end time must be after the start time.';
    final from = row['effective_from'] as String?, to = row['effective_to'] as String?;
    if (from != null && to != null && to.compareTo(from) < 0) return 'The Effective To date cannot be before the Effective From date.';
    final on = [for (final l in _visit) if (l.on) l];
    if (on.isEmpty) return _lines.isEmpty ? 'This route has no stops yet. Add them in Routes & Stops.' : 'Tick at least one stop.';
    int? prev;
    for (final l in on) {
      if (l.switchedOff) return '${l.name} is switched off. Untick it, or switch it on in Routes & Stops.';
      final t = trMinutes(l.time);
      if (t == null) return 'Set the time the bus reaches ${l.name}.';
      if (start != null && end != null && (t < start || t > end)) return '${l.name}: the time must be between the start and end time.';
      if (prev != null && t < prev) return '${l.name} is earlier than the stop above it. Stop times must go in visit order.';
      final h = l.haltMinutes;
      if (h == null || h > 60) return '${l.name}: the halt must be 0 to 60 minutes.';
      prev = t;
    }
    return null;
  }

  Future<void> _save() async {
    final row = _form.currentState?.collect();
    if (row == null) return;
    final problem = _problem(row);
    if (problem != null) {
      trSnack(context, problem, AppColors.warning);
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await TransportService.save('schedule', {
        ...row,
        if (_id != null) 'schedule_id': _id,
        // in visit order; the server numbers them
        'stops': [
          for (final l in _visit)
            if (l.on) {'stop_id': l.id, 'planned_time': l.time, 'halt_minutes': l.haltMinutes},
        ],
      }) ?? _id;
      if (mounted) Navigator.pop(context, id == null ? null : TrEdit(id));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  /// Switches the schedule off (the server refuses while students are enrolled on it).
  Future<void> _delete(int id) async {
    const note = 'The schedule is switched off and kept for past trips. A schedule with students enrolled on it cannot be deleted.';
    if (!await trAskDelete(context, TrDelete('Delete schedule ${trText(widget.initial?['schedule_code'])}?', note)) || !mounted) return;
    setState(() => _deleting = true);
    try {
      final what = await TransportService.remove('schedule', id);
      if (mounted) Navigator.pop(context, TrEdit(id, deleted: what));
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      trSnack(context, AppText.couldNot('delete', friendlyError(e)), AppColors.error);
    }
  }

  // ── stops ──────────────────────────────────────────────────────────────────
  Widget _stopsSection() {
    final visit = _visit;
    final ticked = visit.where((l) => l.on).length;
    final String note;
    if (trId(_values['route_id']) == null) {
      note = 'Choose the route to list its stops.';
    } else if (visit.isEmpty) {
      note = 'This route has no stops yet. Add them in Routes & Stops.';
    } else {
      note = '${_drop ? 'Drop' : 'Pickup'}: the route\'s stops ${_drop != _reversed ? 'from the last to the first' : 'in order'}. '
          'Tick the stops this schedule serves and set when the bus reaches each one. $ticked of ${visit.length} ticked.';
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: AppUI.sectionLabel('Stops')),
        if (visit.length > 1)
          Tooltip(
            message: 'Turn the stop list round, for a route whose stops are numbered from the school outward.',
            child: TextButton.icon(
              // the times stay with their stops; Spread times evenly redoes them
              onPressed: _busy ? null : () => setState(() => _reversed = !_reversed),
              icon: AppIcon('arrange-square', size: AppBtn.iconSize(context), color: AppColors.primaryText),
              label: const Text('Reverse order'),
            ),
          ),
        if (visit.isNotEmpty)
          TextButton.icon(
            onPressed: _busy ? null : _spread,
            icon: AppIcon('magicpen', size: AppBtn.iconSize(context), color: AppColors.primaryText),
            label: const Text('Spread times evenly'),
          ),
      ]),
      Text(note, style: AppUI.muted),
      if (visit.isNotEmpty) ...[SizedBox(height: 10.h), _stopsTable(visit)],
    ]);
  }

  Widget _stopsTable(List<_StopLine> visit) {
    final all = visit.every((l) => l.on), none = !visit.any((l) => l.on);
    var seq = 0;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
          child: Row(children: [
            SizedBox(
              width: 40,
              child: Tooltip(
                message: all ? 'Untick all' : 'Tick all',
                child: Checkbox(
                  tristate: true,
                  value: all ? true : (none ? false : null),
                  onChanged: _busy
                      ? null
                      : (_) => setState(() {
                            for (final l in _lines) {
                              l.on = !all;
                            }
                          }),
                ),
              ),
            ),
            SizedBox(width: 36, child: Text('#', style: AppUI.tableHead)),
            Expanded(child: Text('STOP', style: AppUI.tableHead)),
            SizedBox(width: 150, child: Text('REACHES AT', style: AppUI.tableHead)),
            SizedBox(width: 12.w),
            SizedBox(width: 90, child: Text('HALT (MIN)', style: AppUI.tableHead)),
          ]),
        ),
        for (var i = 0; i < visit.length; i++) _stopRow(visit[i], visit[i].on ? ++seq : null, i),
      ]),
    );
  }

  /// [seq] is the stop's place in the visit order, or null when it is not ticked.
  Widget _stopRow(_StopLine l, int? seq, int i) {
    final code = trText(l.stop['stop_code']);
    final detail = [if (l.switchedOff) 'Switched off', trText(l.stop['landmark'])].where((s) => s.isNotEmpty).join(' · ');
    final ink = l.on ? AppColors.ink : AppColors.ink3;
    return Container(
      // keyed, so a row keeps its halt field when a drop turns the order round
      key: ValueKey('stop-${l.id}'),
      decoration: BoxDecoration(color: i.isEven ? AppColors.card : AppColors.surface, border: const Border(bottom: BorderSide(color: AppColors.divider))),
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
      child: Row(children: [
        SizedBox(
          width: 40,
          child: Checkbox(value: l.on, onChanged: _busy ? null : (v) => setState(() => l.on = v ?? false)),
        ),
        SizedBox(
          width: 36,
          child: Text(seq == null ? '–' : '$seq', style: AppUI.label.copyWith(color: ink)),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(text: l.name, style: AppUI.label.copyWith(color: ink)),
                if (code.isNotEmpty) TextSpan(text: '  $code', style: AppUI.muted),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (detail.isNotEmpty)
              Text(detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppUI.muted.copyWith(color: l.switchedOff ? AppColors.error : null)),
          ]),
        ),
        SizedBox(width: 150, child: _timeField(l)),
        SizedBox(width: 12.w),
        SizedBox(
          width: 90,
          child: TextFormField(
            initialValue: l.halt,
            enabled: !_busy && l.on,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
            style: AppUI.fieldText(context),
            decoration: AppUI.field(context, '', dense: true, filled: l.halt.trim().isNotEmpty),
            onChanged: (v) => l.halt = v,
          ),
        ),
      ]),
    );
  }

  Widget _timeField(_StopLine l) {
    final t = l.time;
    return InkWell(
      onTap: !_busy && l.on ? () => _pickTime(l) : null,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: InputDecorator(
        decoration: AppUI.field(context, '', dense: true, filled: t != null && l.on, leadingIcon: 'clock'),
        child: Text(
          t != null ? trTimeText(t) : (l.on ? 'Set time' : '–'),
          maxLines: 1,
          style: t != null && l.on ? AppUI.fieldText(context) : AppUI.muted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(
              icon: 'timer-1',
              title: _id == null ? 'Add schedule' : 'Edit schedule ${trText(widget.initial?['schedule_code'])}',
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(AppUI.cardPad),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TrFormBody(key: _form, fields: _fields, initial: _start, enabled: !_busy, onChanged: _changed),
                SizedBox(height: 20.h),
                _stopsSection(),
              ]),
            ),
          ),
          trFormFooter(
            context,
            saving: _saving,
            deleting: _deleting,
            onSave: _save,
            onDelete: _id == null ? null : () => _delete(_id!),
          ),
        ]),
      ),
    );
  }
}
