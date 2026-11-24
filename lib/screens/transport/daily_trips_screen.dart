import 'package:flutter/material.dart';
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
import 'trip_replace_dialog.dart';
import 'trip_riders_dialog.dart';

/// DAILY TRIPS -- the trips of one day, made from the trip schedules the
/// evening before (21:00, pg_cron: transport_core.generate_next_day_trips),
/// each with its route, vehicle, crew and the students and staff it expects.
/// A scheduled trip of today or later can change its vehicle, driver and
/// attender for that day only, or be cancelled with a reason (and restored)
/// (tr_trip_save); the schedules and the duty roster stay as they are. Make
/// Trips makes a day's trips now. Each row's Riders button lists the trip's
/// students and staff for the boarding entry (Present / Absent / Parent
/// pickup; on a drop Dropped / Not boarded / Parent pickup). A cancelled trip
/// of today or later (e.g. a bus broken down) can be replaced: another
/// vehicle runs it with its stops and riders (Replace, tr_trip_replace).
class DailyTripsScreen extends StatefulWidget {
  /// The server calls; the tests give their own.
  final Future<Map<String, dynamic>> Function(String date)? loadDay;
  final Future<List<Map<String, dynamic>>> Function()? loadVehicles;
  final Future<List<Map<String, dynamic>>> Function()? loadStaff;
  final Future<int> Function(String date)? makeTrips;
  final Future<void> Function(String date, List<Map<String, dynamic>> trips)? saveTrips;
  final Future<Map<String, dynamic>> Function(String date, int tripId)? loadRiders;
  final Future<void> Function(String date, int tripId, List<Map<String, dynamic>> students, List<Map<String, dynamic>> staff)? saveBoarding;
  final Future<void> Function(String date, Map<String, dynamic> row)? replaceTrip;
  final Future<Map<String, dynamic>> Function(String date, int tripId)? loadRiderOptions;

  /// Today; the computer's date when null.
  final DateTime? today;

  const DailyTripsScreen({
    super.key,
    this.loadDay,
    this.loadVehicles,
    this.loadStaff,
    this.makeTrips,
    this.saveTrips,
    this.loadRiders,
    this.saveBoarding,
    this.replaceTrip,
    this.loadRiderOptions,
    this.today,
  });

  @override
  State<DailyTripsScreen> createState() => _DailyTripsScreenState();
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "7:05 AM" from a timestamp, in this computer's time.
String _clock(dynamic v) {
  final t = DateTime.tryParse(trText(v))?.toLocal();
  if (t == null) return '–';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// What the office changed on one trip: null keeps the trip's own value.
class _Change {
  int? vehicle, driver;

  /// The attender chosen; [attenderSet] tells "none" from "not changed".
  int? attender;
  bool attenderSet = false;

  /// SCHEDULED or CANCELLED (with [reason]); null: not changed.
  String? status;
  String? reason;
}

class _DailyTripsScreenState extends State<DailyTripsScreen> {
  late DateTime _date = _today;
  List<Map<String, dynamic>> _trips = const [];
  List<Map<String, dynamic>> _vehicles = const [];
  List<Map<String, dynamic>> _staff = const [];
  final Map<int, _Change> _changes = {};
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String _query = '';

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  bool get _pastDay => _date.isBefore(_today);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Future.wait<dynamic>([
        (widget.loadDay ?? TransportService.dailyTrips)(_iso(_date)),
        (widget.loadVehicles ?? () => TransportService.list('vehicle'))(),
        (widget.loadStaff ?? () => TransportService.list('staff'))(),
      ]);
      if (!mounted) return;
      final day = r[0] as Map<String, dynamic>;
      setState(() {
        _trips = [
          for (final x in (day['trips'] as List? ?? const []))
            if (x is Map && trId(x['trip_id']) != null) Map<String, dynamic>.from(x),
        ];
        _vehicles = r[1] as List<Map<String, dynamic>>;
        _staff = r[2] as List<Map<String, dynamic>>;
        _changes.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<bool> _discardOk() async {
    if (_changeCount == 0) return true;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Discard the changes?'),
            content: const Text('Some trip changes are not saved yet. They are lost if you go on.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Editing')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.danger(ctx), child: const Text('Discard')),
            ],
          ),
        ) ==
        true;
  }

  Future<void> _goTo(DateTime d) async {
    final day = DateTime(d.year, d.month, d.day);
    if (day == _date || !await _discardOk()) return;
    setState(() => _date = day);
    await _load();
  }

  Future<void> _pickDate() async {
    final d = await trPickDate(context,
        initialDate: _date, firstDate: DateTime(_today.year - 1), lastDate: DateTime(_today.year + 1, 12, 31), helpText: 'Trips of the day');
    if (d != null && mounted) await _goTo(d);
  }

  Future<void> _make() async {
    if (!await _discardOk()) return;
    setState(() => _busy = true);
    try {
      final n = await (widget.makeTrips ?? TransportService.makeTrips)(_iso(_date));
      if (!mounted) return;
      trSnack(context, n == 0 ? 'No new trips: the day already has its trips.' : 'Made $n trip${n == 1 ? '' : 's'}.', AppColors.success);
      await _load();
    } catch (e) {
      if (mounted) trSnack(context, AppText.couldNot('make the trips', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── a trip as the screen shows it ─────────────────────────────────────────
  int _id(Map<String, dynamic> t) => trId(t['trip_id'])!;

  List<Map<String, dynamic>> _crew(Map<String, dynamic> t, String role) => [
        for (final c in (t['crew'] as List? ?? const []))
          if (c is Map && c['duty_role'] == role) Map<String, dynamic>.from(c),
      ];

  int? _savedVehicle(Map<String, dynamic> t) => trId(t['vehicle_id']);
  int? _savedDriver(Map<String, dynamic> t) {
    final d = _crew(t, 'DRIVER');
    return d.isEmpty ? null : trId(d.first['staff_id']);
  }

  int? _savedAttender(Map<String, dynamic> t) {
    final a = _crew(t, 'ATTENDER');
    return a.isEmpty ? null : trId(a.first['staff_id']);
  }

  int? _vehicleNow(Map<String, dynamic> t) => _changes[_id(t)]?.vehicle ?? _savedVehicle(t);
  int? _driverNow(Map<String, dynamic> t) => _changes[_id(t)]?.driver ?? _savedDriver(t);
  int? _attenderNow(Map<String, dynamic> t) {
    final c = _changes[_id(t)];
    return c != null && c.attenderSet ? c.attender : _savedAttender(t);
  }

  String _statusNow(Map<String, dynamic> t) => _changes[_id(t)]?.status ?? trText(t['status']);

  bool _changed(Map<String, dynamic> t) =>
      _vehicleNow(t) != _savedVehicle(t) ||
      _driverNow(t) != _savedDriver(t) ||
      _attenderNow(t) != _savedAttender(t) ||
      _statusNow(t) != trText(t['status']);

  /// Cancelled, of today or later, and not replaced: it can be restored, or replaced.
  bool _restorable(Map<String, dynamic> t) => t['status'] == 'CANCELLED' && !_pastDay && trId(t['replaced_by_trip_id']) == null;

  /// Replace Trip: another vehicle runs the cancelled trip; unsaved changes go first.
  Future<void> _replace(Map<String, dynamic> t) async {
    if (!await _discardOk() || !mounted) return;
    final by = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TripReplaceDialog(
        trip: t,
        date: _iso(_date),
        times: '${_clock(t['planned_start_at'])} – ${_clock(t['planned_end_at'])}',
        vehicles: _vehicles,
        staff: _staff,
        replace: (date, row) async {
          await (widget.replaceTrip ?? TransportService.replaceTrip)(date, row);
        },
      ),
    );
    if (by == null || !mounted) return;
    trSnack(context, 'Trip ${trText(t['schedule_code'])} replaced: $by runs it.', AppColors.success);
    await _load();
  }

  /// Scheduled -> Cancelled asks the reason first; Cancelled -> Scheduled restores.
  Future<void> _setStatus(Map<String, dynamic> t, String? to) async {
    if (to == null || to == _statusNow(t)) return;
    String? reason;
    if (to == 'CANCELLED') {
      reason = await _askReason(trText(t['schedule_code']));
      if (reason == null || !mounted) {
        setState(() {}); // the picker shows the trip's status again
        return;
      }
    }
    _set(t, (c) {
      c.status = to == trText(t['status']) ? null : to;
      c.reason = reason;
    });
  }

  Future<String?> _askReason(String code) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Cancel trip $code?'),
          content: SizedBox(
            width: 420,
            child: TextField(
              key: const ValueKey('dt-reason'),
              controller: ctl,
              autofocus: true,
              maxLength: 200,
              decoration: AppUI.field(ctx, 'Reason (e.g. bus breakdown, holiday)'),
              onChanged: (_) => setLocal(() {}),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep the Trip')),
            ElevatedButton(
              onPressed: ctl.text.trim().isEmpty ? null : () => Navigator.pop(ctx, ctl.text.trim()),
              style: AppUI.danger(ctx),
              child: const Text('Cancel Trip'),
            ),
          ],
        ),
      ),
    );
  }

  int get _changeCount => _trips.where(_changed).length;

  int _riders(Map<String, dynamic> t) => (trId(t['students']) ?? 0) + (trId(t['staff']) ?? 0);

  Map<String, dynamic>? _vehicle(int? id) {
    for (final v in _vehicles) {
      if (trId(v['vehicle_id']) == id) return v;
    }
    return null;
  }

  int _capacity(int? vehicleId, Map<String, dynamic> t) {
    final v = _vehicle(vehicleId);
    if (v == null) return trId(t['capacity']) ?? 0;
    return (trId(v['seating_capacity']) ?? 0) + (trId(v['additional_capacity']) ?? 0);
  }

  void _set(Map<String, dynamic> t, void Function(_Change c) change) => setState(() {
        final c = _changes.putIfAbsent(_id(t), _Change.new);
        change(c);
        if (!_changed(t)) _changes.remove(_id(t));
      });

  /// The changed trips as the server takes them: only what changed.
  List<Map<String, dynamic>> get _payload => [
        for (final t in _trips)
          if (_changed(t))
            {
              'trip_id': _id(t),
              'updated_at': t['updated_at'],
              if (_vehicleNow(t) != _savedVehicle(t)) 'vehicle_id': _vehicleNow(t),
              if (_driverNow(t) != _savedDriver(t)) 'driver_id': _driverNow(t),
              if (_attenderNow(t) != _savedAttender(t)) 'attender_id': _attenderNow(t),
              if (_statusNow(t) != trText(t['status'])) ...{
                'status': _statusNow(t),
                if (_statusNow(t) == 'CANCELLED') 'cancel_reason': _changes[_id(t)]?.reason,
              },
            },
      ];

  Future<void> _save() async {
    // said before sending what the server would refuse anyway
    for (final t in _trips.where(_changed)) {
      // the seats are checked when the vehicle changes (as the server does); a cancelled trip takes nobody
      if (_vehicleNow(t) == _savedVehicle(t) || _statusNow(t) == 'CANCELLED') continue;
      final seats = _capacity(_vehicleNow(t), t);
      if (_riders(t) > seats) {
        trSnack(context, '${trText(_vehicle(_vehicleNow(t))?['vehicle_code'])} takes $seats, but trip ${trText(t['schedule_code'])} expects ${_riders(t)} riders.',
            AppColors.warning);
        return;
      }
    }
    final rows = _payload;
    if (rows.isEmpty) return;
    setState(() => _busy = true);
    try {
      await (widget.saveTrips ?? TransportService.saveTrips)(_iso(_date), rows);
      if (!mounted) return;
      trSnack(context, rows.length == 1 ? 'Saved 1 trip.' : 'Saved ${rows.length} trips.', AppColors.success);
      await _load();
    } catch (e) {
      if (mounted) trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── pieces ─────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> get _shown {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _trips;
    return [
      for (final t in _trips)
        if ([
          t['schedule_code'], t['schedule_name'], t['route_code'], t['route_name'], _vehicle(_vehicleNow(t))?['vehicle_code'] ?? t['vehicle_code'],
          for (final c in (t['crew'] as List? ?? const [])) if (c is Map) c['full_name'],
        ].map(trText).join(' ').toLowerCase().contains(q))
          t,
    ];
  }

  Widget _pick<T>(Key key, T? value, List<(T?, String)> items, ValueChanged<T?>? onPick, {String hint = ''}) => AppDropdownField<T?>(
        key: key,
        initialValue: items.any((o) => o.$1 == value) ? value : null,
        isExpanded: true,
        menuMaxHeight: 380,
        dropdownColor: AppColors.card,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', dense: true, filled: value != null),
        hint: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
        items: [for (final o in items) DropdownMenuItem<T?>(value: o.$1, child: Text(o.$2, maxLines: 1, overflow: TextOverflow.ellipsis))],
        onChanged: onPick,
      );

  /// The vehicles in service, and the trip's own even if it is not.
  List<(int?, String)> _vehicleItems(Map<String, dynamic> t) => [
        for (final v in _vehicles)
          if (v['status'] == 'ACTIVE' || trId(v['vehicle_id']) == _vehicleNow(t) || trId(v['vehicle_id']) == _savedVehicle(t))
            (
              trId(v['vehicle_id']),
              '${trText(v['vehicle_code'])} · ${(trId(v['seating_capacity']) ?? 0) + (trId(v['additional_capacity']) ?? 0)} seats',
            ),
        // a vehicle not in the list (e.g. another school's view of it): still shown
        if (!_vehicles.any((v) => trId(v['vehicle_id']) == _savedVehicle(t))) (_savedVehicle(t), trText(t['vehicle_code'])),
      ];

  /// Active staff of [type], and whoever the trip has now.
  List<(int?, String)> _staffItems(Map<String, dynamic> t, String type, int? now, {bool none = false}) => [
        if (none) (null, 'None'),
        for (final s in _staff)
          if ((s['staff_type'] == type && s['status'] == 'ACTIVE') || trId(s['staff_id']) == now)
            (trId(s['staff_id']), '${trText(s['full_name'])} (${trText(s['staff_code'])})'),
      ];

  Widget _cell(int flex, Widget child) => Expanded(
        flex: flex,
        child: Padding(padding: EdgeInsets.only(right: 8.w), child: Align(alignment: Alignment.centerLeft, child: child)),
      );

  Widget _head() => Container(
        height: 42.h,
        padding: EdgeInsets.symmetric(horizontal: 12.w),
        decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
        child: Row(children: [
          for (final (label, flex) in const [
            // STATUS wide enough for "Scheduled" / "Cancelled" in full
            ('TIME', 3), ('TRIP', 4), ('ROUTE', 2), ('VEHICLE', 4), ('DRIVER', 4), ('ATTENDER', 4), ('RIDERS', 3), ('STATUS', 5),
          ])
            _cell(flex, Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.tableHead)),
          const SizedBox(width: _wActions),
        ]),
      );

  /// The row's last column: Riders, and Undo when the row has changes.
  static const double _wActions = 88;

  bool get _future => _date.isAfter(_today);

  /// What a trip's status can be set to here (its own among them); fewer
  /// than two: shown only. A scheduled trip is cancelled (today or later) or
  /// completed (on its day or after, a past day's too); a running one
  /// completed; a cancelled one restored; one completed by mistake set back
  /// to Scheduled (not on a past day).
  List<(String?, String)> _statusItems(Map<String, dynamic> t) {
    const sched = ('SCHEDULED', 'Scheduled'), cancel = ('CANCELLED', 'Cancelled'), done = ('COMPLETED', 'Completed');
    return switch (trText(t['status'])) {
      'SCHEDULED' => [sched, if (!_pastDay) cancel, if (!_future) done],
      'IN_PROGRESS' => [('IN_PROGRESS', 'Running'), done],
      'CANCELLED' when _restorable(t) => [sched, cancel],
      'COMPLETED' when !_pastDay => [sched, done],
      _ => const [],
    };
  }

  Widget _status(Map<String, dynamic> t) {
    final id = _id(t);
    final now = _statusNow(t);
    final reason = now == 'CANCELLED' ? (_changes[id]?.reason ?? trText(t['cancel_reason'])) : '';
    final items = _statusItems(t);
    final Widget top;
    if (!_busy && items.length > 1) {
      top = _pick<String>(ValueKey('dt-status-$id-$now'), now, items, (v) => _setStatus(t, v));
    } else {
      final (text, st) = switch (now) {
        'SCHEDULED' => ('Scheduled', AppStatus.info),
        'IN_PROGRESS' => ('Running', AppStatus.warning),
        'COMPLETED' => ('Completed', AppStatus.success),
        'CANCELLED' => ('Cancelled', AppStatus.neutral),
        'ABORTED' => ('Aborted', AppStatus.danger),
        _ => (now, AppStatus.neutral),
      };
      top = AppUI.chip(text, st);
    }
    final by = trText(t['replaced_by_vehicle_code']);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      top,
      if (reason.isNotEmpty) Tooltip(message: reason, child: Text(reason, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted)),
      if (trId(t['replaced_by_trip_id']) != null)
        Text('Replaced: ${by.isEmpty ? 'another vehicle' : by} runs it',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700)),
    ]);
  }

  Future<void> _openRiders(Map<String, dynamic> t) => showDialog<bool>(
        context: context,
        builder: (_) => TripRidersDialog(
          trip: t,
          date: _iso(_date),
          load: widget.loadRiders ?? TransportService.tripRiders,
          save: widget.saveBoarding ?? TransportService.saveBoarding,
          options: widget.loadRiderOptions ?? TransportService.tripRiderOptions,
        ),
      );

  Widget _row(Map<String, dynamic> t, int i) {
    final id = _id(t);
    final edit = t['editable'] == true && !_busy;
    final changed = _changed(t);
    final riders = _riders(t);
    final seats = _capacity(_vehicleNow(t), t);
    final over = riders > seats;
    final others = [
      for (final c in (t['crew'] as List? ?? const []))
        if (c is Map && c['duty_role'] != 'DRIVER' && c['duty_role'] != 'ATTENDER') '${trText(c['full_name'])} (${trText(c['duty_role']).toLowerCase()})',
    ];
    final subs = [
      for (final c in (t['crew'] as List? ?? const []))
        if (c is Map && c['is_substitute'] == true) trText(c['full_name']),
    ];
    String text(dynamic v) => trText(v).isEmpty ? '–' : trText(v);
    return Container(
      key: ValueKey('dt-row-$id'),
      constraints: BoxConstraints(minHeight: 44.h),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 3.h),
      decoration: BoxDecoration(
        color: changed ? AppColors.accent.withValues(alpha: 0.06) : (i.isEven ? Colors.white : AppColors.surface),
        border: const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        _cell(3, Text('${_clock(t['planned_start_at'])} – ${_clock(t['planned_end_at'])}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
        _cell(
          4,
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text(t['schedule_code']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
            if (trId(t['replaces_trip_id']) != null)
              Text('${t['direction'] == 'DROP' ? 'Drop' : 'Pickup'} · Replaces ${text(t['replaces_vehicle_code'])}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted.copyWith(color: AppColors.goldDark, fontWeight: FontWeight.w700))
            else
              Text('${t['direction'] == 'DROP' ? 'Drop' : 'Pickup'} · ${text(t['schedule_name'])}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
          ]),
        ),
        _cell(2, Text(text(t['route_code']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
        _cell(
          4,
          edit
              ? _pick<int>(ValueKey('dt-veh-$id-${_vehicleNow(t)}'), _vehicleNow(t), _vehicleItems(t), (v) => _set(t, (c) => c.vehicle = v))
              : Text(text(t['vehicle_code']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
        ),
        _cell(
          4,
          edit
              ? _pick<int>(ValueKey('dt-drv-$id-${_driverNow(t)}'), _driverNow(t), _staffItems(t, 'DRIVER', _driverNow(t)),
                  (v) => _set(t, (c) => c.driver = v), hint: 'Driver')
              : Text(_crew(t, 'DRIVER').map((c) => trText(c['full_name'])).join(', ').isEmpty ? '–' : _crew(t, 'DRIVER').map((c) => trText(c['full_name'])).join(', '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
        ),
        _cell(
          4,
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            edit
                ? _pick<int>(ValueKey('dt-att-$id-${_attenderNow(t)}'), _attenderNow(t), _staffItems(t, 'ATTENDER', _attenderNow(t), none: true),
                    (v) => _set(t, (c) {
                          c.attender = v;
                          c.attenderSet = true;
                        }),
                    hint: 'None')
                : Text(_crew(t, 'ATTENDER').map((c) => trText(c['full_name'])).join(', ').isEmpty ? '–' : _crew(t, 'ATTENDER').map((c) => trText(c['full_name'])).join(', '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
            if (others.isNotEmpty) Text(others.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
          ]),
        ),
        _cell(
          3,
          Tooltip(
            message: '${trId(t['students']) ?? 0} students and ${trId(t['staff']) ?? 0} staff expected, $seats seats',
            child: Text('${trId(t['students']) ?? 0} + ${trId(t['staff']) ?? 0} / $seats',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: over ? AppUI.cell.copyWith(color: AppColors.error, fontWeight: FontWeight.w700) : AppUI.cell),
          ),
        ),
        _cell(
          5,
          Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: _status(t)),
            if (subs.isNotEmpty) ...[
              SizedBox(width: 4.w),
              Tooltip(message: 'Substitute: ${subs.join(', ')}', child: const Icon(Icons.swap_horiz, size: 16, color: AppColors.goldDark)),
            ],
          ]),
        ),
        SizedBox(
          width: _wActions,
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (changed && !_busy)
              IconButton(
                tooltip: 'Undo the changes in this trip',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _changes.remove(id)),
                icon: const AppIcon('rotate-left', size: 16, color: AppColors.ink2),
              ),
            if (!changed && _restorable(t))
              IconButton(
                key: ValueKey('dt-replace-$id'),
                tooltip: 'Replace this trip: another vehicle runs it, with its stops and riders',
                visualDensity: VisualDensity.compact,
                onPressed: _busy ? null : () => _replace(t),
                icon: const AppIcon('arrow-swap-horizontal', size: 18, color: AppColors.goldDark),
              ),
            IconButton(
              key: ValueKey('dt-riders-$id'),
              tooltip: 'Students and staff of this trip: who boarded',
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : () => _openRiders(t),
              icon: const AppIcon('edit-2', size: 18, color: AppColors.primary),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _dayBar() {
    final today = _today;
    Widget day(String label, DateTime d) => ChoiceChip(
          key: ValueKey('dt-day-$label'),
          label: Text(label),
          selected: _date == d,
          onSelected: _busy ? null : (_) => _goTo(d),
        );
    return Wrap(spacing: 8.w, runSpacing: 6.h, crossAxisAlignment: WrapCrossAlignment.center, children: [
      IconButton(
        tooltip: 'The day before',
        onPressed: _busy ? null : () => _goTo(_date.subtract(const Duration(days: 1))),
        icon: const Icon(Icons.chevron_left),
      ),
      OutlinedButton.icon(
        key: const ValueKey('dt-date'),
        onPressed: _busy ? null : _pickDate,
        style: AppUI.secondary(context),
        icon: AppIcon('calendar', size: AppBtn.iconSize(context), color: AppColors.primaryText),
        label: Text(formatDate(_iso(_date))),
      ),
      IconButton(
        tooltip: 'The next day',
        onPressed: _busy ? null : () => _goTo(_date.add(const Duration(days: 1))),
        icon: const Icon(Icons.chevron_right),
      ),
      day('Today', today),
      day('Tomorrow', today.add(const Duration(days: 1))),
    ]);
  }

  Widget _toolbar(int changes) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10.w,
        runSpacing: 8.h,
        children: [
          SizedBox(width: 260.w, child: TrSearchField(hint: 'Trip, route, vehicle or crew', onChanged: (v) => setState(() => _query = v))),
          Wrap(spacing: 10.w, runSpacing: 8.h, children: [
            Tooltip(
              message: _pastDay ? 'Trips are not made for a past day' : 'Make the trips of this day from the schedules now (the nightly run does it at 9 PM)',
              child: OutlinedButton.icon(
                key: const ValueKey('dt-make'),
                onPressed: _busy || _pastDay ? null : _make,
                style: AppUI.secondary(context),
                icon: AppIcon('calendar-add', size: AppBtn.iconSize(context), color: AppColors.primaryText),
                label: const Text('Make Trips'),
              ),
            ),
            OutlinedButton.icon(
              onPressed: changes == 0 || _busy ? null : () => setState(_changes.clear),
              style: AppUI.secondary(context),
              icon: AppIcon('rotate-left', size: AppBtn.iconSize(context), color: AppColors.primaryText),
              label: const Text('Undo All'),
            ),
            ElevatedButton.icon(
              onPressed: changes == 0 || _busy ? null : _save,
              style: AppUI.primary(context),
              icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
              label: Text(_busy ? 'Saving...' : (changes == 0 ? AppText.save : 'Save $changes Change${changes == 1 ? '' : 's'}')),
            ),
          ]),
        ],
      );

  Widget _body() {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not load the trips',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton(onPressed: _load, style: AppUI.secondary(context), child: const Text('Retry')),
      );
    }
    if (_trips.isEmpty) {
      return AppUI.empty(
        title: 'No trips on ${formatDate(_iso(_date))}',
        why: _pastDay
            ? 'No trips were made for this day.'
            : 'Trips are made at 9 PM the evening before. Use Make Trips to make this day\'s trips now.',
        icon: 'bus',
      );
    }
    final shown = _shown;
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth < 1100 ? 1100.0 : c.maxWidth;
      final table = SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head(),
          Expanded(
            child: shown.isEmpty
                ? AppUI.empty(title: 'No trip matches', why: 'Try another search.', icon: 'search-normal')
                : ListView.builder(itemCount: shown.length, itemBuilder: (_, i) => _row(shown[i], i)),
          ),
        ]),
      );
      return width <= c.maxWidth ? table : SingleChildScrollView(scrollDirection: Axis.horizontal, child: table);
    });
  }

  @override
  Widget build(BuildContext context) {
    final changes = _changeCount;
    int count(String status) => _trips.where((t) => t['status'] == status).length;
    final running = count('SCHEDULED');
    final completed = count('COMPLETED');
    final cancelled = count('CANCELLED');
    return Container(
      decoration: AppUI.card(),
      padding: EdgeInsets.all(AppUI.cardPad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'calendar-tick',
          title: 'Daily Trips',
          subtitle: 'Each day\'s trips, made at 9 PM the evening before. Change a trip\'s vehicle or crew for that day only.',
          trailing: [_dayBar()],
        ),
        SizedBox(height: 12.h),
        _toolbar(changes),
        SizedBox(height: 8.h),
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: '${_trips.length} trip${_trips.length == 1 ? '' : 's'} · $running scheduled'
                  '${completed > 0 ? ' · $completed completed' : ''}${cancelled > 0 ? ' · $cancelled cancelled' : ''}',
              style: AppUI.muted,
            ),
            if (changes > 0)
              TextSpan(
                text: '   ·   $changes change${changes == 1 ? '' : 's'} not saved',
                style: AppUI.muted.copyWith(color: AppColors.goldDark, fontWeight: FontWeight.w700),
              ),
            if (_pastDay) TextSpan(text: '   ·   A past day: a trip still scheduled can only be marked Completed.', style: AppUI.muted),
          ]),
        ),
        SizedBox(height: 10.h),
        Expanded(
          child: Container(decoration: AppUI.card(), clipBehavior: Clip.antiAlias, child: _body()),
        ),
      ]),
    );
  }
}
