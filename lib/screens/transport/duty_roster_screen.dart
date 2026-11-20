import 'package:flutter/material.dart';

import '../../services/transport_service.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// DUTY ROSTER -- who drives and who attends each trip schedule, from a date
/// (to a date; an open end runs on). Each day's trip takes that day's duties
/// as its crew (tr_duty_assignment -> tr_trip_staff, made by
/// transport_core.fn_generate_trips). The server refuses a duty that clashes:
/// a second driver on a schedule, the same person twice on it, a Driver duty
/// for someone who is not a driver, or one person on two schedules that run
/// at the same time.
class DutyRosterScreen extends StatefulWidget {
  const DutyRosterScreen({super.key});

  @override
  State<DutyRosterScreen> createState() => _DutyRosterScreenState();
}

const _roles = <(Object?, String)>[
  ('DRIVER', 'Driver'),
  ('ATTENDER', 'Attender'),
  ('CONDUCTOR', 'Conductor'),
  ('SUPERVISOR', 'Supervisor'),
];
const _staffStatus = {'ON_LEAVE': 'On Leave', 'SUSPENDED': 'Suspended', 'RELIEVED': 'Relieved'};

String _today() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String _roleText(dynamic v) {
  for (final r in _roles) {
    if (r.$1 == v) return r.$2;
  }
  return trText(v);
}

class _DutyRosterScreenState extends State<DutyRosterScreen> {
  List<Map<String, dynamic>> _schedules = const [];
  List<Map<String, dynamic>> _staff = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The schedules and staff the duties pick from.
  Future<void> _load() async {
    try {
      final r = await Future.wait([
        TransportService.list('schedule'),
        TransportService.list('staff'),
      ]);
      if (!mounted) return;
      setState(() {
        _schedules = r[0];
        _staff = r[1];
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

  Map<String, dynamic>? _schedule(dynamic id) => _find(_schedules, 'schedule_id', id);
  Map<String, dynamic>? _person(dynamic id) => _find(_staff, 'staff_id', id);

  String _scheduleText(dynamic id) {
    final s = _schedule(id);
    return s == null ? '-' : '${trText(s['schedule_code'])} · ${trText(s['schedule_name'])}';
  }

  String _timeText(dynamic id) {
    final s = _schedule(id);
    return s == null ? '-' : '${trTimeText(s['planned_start'])} – ${trTimeText(s['planned_end'])}';
  }

  String _staffText(dynamic id) {
    final p = _person(id);
    return p == null ? '-' : '${trText(p['full_name'])} (${trText(p['staff_code'])})';
  }

  /// Why a duty cannot be added yet, or null.
  String? get _blocked {
    if (!_schedules.any((s) => s['is_active'] != false)) return 'Add a trip schedule in Trip Schedules first.';
    if (!_staff.any((p) => p['status'] == 'ACTIVE')) return 'Add your drivers and attenders in Transport Staff first.';
    return null;
  }

  /// Ended, a reason the day's trips leave the duty out (the staff member is
  /// not active, or the schedule is switched off), Upcoming or Active; the
  /// dates or the reason on hover.
  Widget _status(Map<String, dynamic> r) {
    final from = r['effective_from'] as String?, to = r['effective_to'] as String?;
    final dates = to == null ? 'From ${formatDate(from)}' : '${formatDate(from)} to ${formatDate(to)}';
    final p = _person(r['staff_id']), s = _schedule(r['schedule_id']);
    final (text, status, tip) = (trDaysLeft(to) ?? 0) < 0
        ? ('Ended', AppStatus.neutral, dates)
        : p != null && p['status'] != 'ACTIVE'
            ? (_staffStatus[p['status']] ?? trText(p['status']), AppStatus.warning, 'The staff member is not active, so the day\'s trips leave them out.')
            : s != null && s['is_active'] == false
                ? ('Schedule Off', AppStatus.neutral, 'The schedule is switched off, so it makes no trips.')
                : (trDaysLeft(from) ?? 0) > 0
                    ? ('Upcoming', AppStatus.info, dates)
                    : ('Active', AppStatus.success, dates);
    return Tooltip(message: tip, child: AppUI.chip(text, status));
  }

  /// The form. Switched-off schedules and staff who are not active are left
  /// out, except those a duty already has, so an old duty still opens. The
  /// staff list follows the duty: only drivers for Driver, only attenders for
  /// Attender, and so on; changing the duty clears a staff member who no
  /// longer fits.
  List<TrField> _fields(List<Map<String, dynamic>> rows) {
    final usedSchedules = {for (final r in rows) trId(r['schedule_id'])};
    final usedStaff = {for (final r in rows) trId(r['staff_id'])};
    return [
      TrField('schedule_id', 'Schedule', kind: TrKind.choice, required: true, full: true, options: [
        for (final s in _schedules)
          if (s['is_active'] != false || usedSchedules.contains(trId(s['schedule_id'])))
            (
              trId(s['schedule_id']),
              '${trText(s['schedule_code'])} - ${trText(s['schedule_name'])}: ${s['direction'] == 'DROP' ? 'Drop' : 'Pickup'}, '
                  '${trTimeText(s['planned_start'])} – ${trTimeText(s['planned_end'])}, ${trDaysText(s['run_days'])}'
                  '${s['is_active'] == false ? ' (switched off)' : ''}',
            ),
      ]),
      const TrField('duty_role', 'Duty', kind: TrKind.choice, required: true, options: _roles),
      TrField('staff_id', 'Staff Member', kind: TrKind.choice, required: true, hint: 'Staff of the chosen duty', optionsFor: (v) => [
        for (final p in _staff)
          if (p['staff_type'] == v['duty_role'] && (p['status'] == 'ACTIVE' || usedStaff.contains(trId(p['staff_id']))))
            (
              trId(p['staff_id']),
              '${trText(p['full_name'])} (${trText(p['staff_code'])})'
                  '${p['status'] == 'ACTIVE' ? '' : ' - ${_staffStatus[p['status']] ?? trText(p['status'])}'}',
            ),
      ]),
      const TrField('effective_from', 'Effective From', kind: TrKind.date, required: true),
      const TrField('effective_to', 'Effective To', kind: TrKind.date),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Duty Roster',
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
        key: ValueKey('duty-${_schedules.length}-${_staff.length}'),
        entity: 'duty',
        pk: 'duty_id',
        title: 'Duty Roster',
        subtitle: 'Who drives and who attends each trip schedule. Each day\'s trips take their crew from here.',
        icon: 'user-tick',
        noun: 'duty',
        deleteNote: 'The duty is removed from the roster. Trips already made keep their crew. '
            'To end a duty from a date and keep its record, edit it and set Effective To instead.',
        emptyWhy: 'Add the driver and the attenders of each trip schedule.',
        addBlockedReason: _blocked,
        columns: [
          TrColumn('Schedule', flex: 4, text: (r) => _scheduleText(r['schedule_id'])),
          TrColumn('Time', flex: 3, text: (r) => _timeText(r['schedule_id'])),
          TrColumn('Days', flex: 2, text: (r) => trDaysText(_schedule(r['schedule_id'])?['run_days'])),
          TrColumn('Duty', flex: 2, text: (r) => _roleText(r['duty_role'])),
          TrColumn('Staff', flex: 4, text: (r) => _staffText(r['staff_id'])),
          TrColumn('Mobile', flex: 3, text: (r) => trText(_person(r['staff_id'])?['mobile']), mono: true),
          TrColumn('From', flex: 2, text: (r) => formatDate(r['effective_from'] as String?)),
          TrColumn('To', flex: 2, text: (r) => r['effective_to'] == null ? 'Open' : formatDate(r['effective_to'] as String?)),
          TrColumn('Status', flex: 2, cell: _status),
        ],
        searchText: (r) => '${_scheduleText(r['schedule_id'])} ${_staffText(r['staff_id'])} ${_roleText(r['duty_role'])} '
            '${trText(_person(r['staff_id'])?['mobile'])}',
        newValues: (_) => {'duty_role': 'DRIVER', 'effective_from': _today()},
        fields: _fields,
      ),
    );
  }
}
