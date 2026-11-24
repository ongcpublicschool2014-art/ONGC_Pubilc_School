import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/pill_tab.dart';
import 'transport_master_panel.dart';

/// A day's trip's students and staff, in the order the bus reaches their
/// stops (the server's), with the boarding entry (Daily Trips, each row's
/// Riders button): Present (the server keeps it as BOARDED on a pickup and
/// ALIGHTED on a drop), Absent (ABSENT), Parent pickup (PARENT_PICKUP,
/// students only). Tapping the chosen one again clears it (not marked).
/// Add Student / Add Staff puts a rider of the same route on this trip, e.g.
/// one who missed their own vehicle (marked Present here, Absent on their own
/// trip if not marked there yet); one already present on another trip cannot
/// be added. An added rider can be taken off again. All of it is saved
/// together. Entry is open from the trip's day on, and not for a cancelled
/// trip (the server's can_mark).
class TripRidersDialog extends StatefulWidget {
  final Map<String, dynamic> trip;

  /// The trip's day (yyyy-mm-dd).
  final String date;
  final Future<Map<String, dynamic>> Function(String date, int tripId) load;
  final Future<void> Function(String date, int tripId, List<Map<String, dynamic>> students, List<Map<String, dynamic>> staff) save;

  /// The route's riders that way on the day who are not on this trip
  /// (tr_trip_rider_options), for Add Student / Add Staff; none: no Add.
  final Future<Map<String, dynamic>> Function(String date, int tripId)? options;

  const TripRidersDialog({super.key, required this.trip, required this.date, required this.load, required this.save, this.options});

  @override
  State<TripRidersDialog> createState() => _TripRidersDialogState();
}

class _TripRidersDialogState extends State<TripRidersDialog> {
  List<Map<String, dynamic>> _students = const [];
  List<Map<String, dynamic>> _staff = const [];
  bool _canMark = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// "s9" / "f4" (a student's / staff member's enrollment id) -> the choice
  /// made here: PRESENT, ABSENT, PARENT_PICKUP or EXPECTED (not marked).
  final Map<String, String> _now = {};

  /// Riders added here, not saved yet.
  final List<Map<String, dynamic>> _addStudents = [];
  final List<Map<String, dynamic>> _addStaff = [];

  /// Riders added before (is_extra), to be taken off on Save.
  final Set<String> _off = {};

  /// The open tab: false Students, true Staff.
  bool _staffTab = false;

  int get _tripId => trId(widget.trip['trip_id'])!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.load(widget.date, _tripId);
      if (!mounted) return;
      setState(() {
        _students = _maps(r['students']);
        _staff = _maps(r['staff']);
        _canMark = r['can_mark'] == true;
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

  static List<Map<String, dynamic>> _maps(dynamic v) => [
        for (final x in (v is List ? v : const []))
          if (x is Map && trId(x['enrollment_id']) != null) Map<String, dynamic>.from(x),
      ];

  String _key(bool staff, Map<String, dynamic> r) => '${staff ? 'f' : 's'}${trId(r['enrollment_id'])}';

  /// The choice a status shows as: boarded or got off (alighted) is
  /// present; a no-show is absent.
  static String _choice(String status) => switch (status) {
        'BOARDED' || 'ALIGHTED' || 'PRESENT' => 'PRESENT',
        'ABSENT' || 'NO_SHOW' => 'ABSENT',
        '' => 'EXPECTED',
        _ => status,
      };
  String _saved(Map<String, dynamic> r) => _choice(trText(r['status']));
  String _status(bool staff, Map<String, dynamic> r) => _now[_key(staff, r)] ?? _saved(r);

  bool _pending(Map<String, dynamic> r) => r['_pending'] == true;

  /// Added to this trip: here (not saved yet), or before (is_extra).
  bool _extra(Map<String, dynamic> r) => _pending(r) || r['is_extra'] == true;
  bool _isOff(bool staff, Map<String, dynamic> r) => _off.contains(_key(staff, r));

  /// The tab's riders as shown: the trip's, then those added here.
  List<Map<String, dynamic>> _list(bool staff) => [...(staff ? _staff : _students), ...(staff ? _addStaff : _addStudents)];

  /// Those travelling: not taken off.
  List<Map<String, dynamic>> _riding(bool staff) => [
        for (final r in _list(staff))
          if (!_isOff(staff, r)) r,
      ];

  /// Marked before the trip without anyone here: the parents told it (a day exception).
  bool _toldBefore(bool staff, Map<String, dynamic> r) =>
      !_now.containsKey(_key(staff, r)) && _saved(r) != 'EXPECTED' && trText(r['mark_method']).isEmpty;

  void _put(bool staff, Map<String, dynamic> r, String choice) {
    if (choice == _saved(r)) {
      _now.remove(_key(staff, r));
    } else {
      _now[_key(staff, r)] = choice;
    }
  }

  void _set(bool staff, Map<String, dynamic> r, String choice) => setState(() => _put(staff, r, choice));

  int get _changes => {
        ..._now.keys,
        for (final r in _addStudents) _key(false, r),
        for (final r in _addStaff) _key(true, r),
        ..._off,
      }.length;

  List<Map<String, dynamic>> get _open => _riding(_staffTab);

  /// Everyone of the open tab not marked yet: Present.
  void _restPresent() => setState(() {
        for (final r in _open) {
          if (_status(_staffTab, r) == 'EXPECTED') _put(_staffTab, r, 'PRESENT');
        }
      });

  /// Everyone of the open tab: not marked.
  void _deselectAll() => setState(() {
        for (final r in _open) {
          _put(_staffTab, r, 'EXPECTED');
        }
      });

  /// How many of [list] are marked.
  int _marked(bool staff, List<Map<String, dynamic>> list) => list.where((r) => _status(staff, r) != 'EXPECTED').length;

  /// An added rider off this trip (one added here simply goes), or kept on it again.
  void _takeOff(bool staff, Map<String, dynamic> r) => setState(() {
        final k = _key(staff, r);
        if (_pending(r)) {
          (staff ? _addStaff : _addStudents).removeWhere((x) => _key(staff, x) == k);
          _now.remove(k);
        } else if (!_off.remove(k)) {
          _off.add(k);
          _now.remove(k);
        }
      });

  /// Add Student / Add Staff: riders of the route from its other trips.
  Future<void> _add() async {
    final staff = _staffTab;
    final picked = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => _AddRidersDialog(
        staff: staff,
        drop: _drop,
        code: trText(widget.trip['schedule_code']),
        load: () => widget.options!(widget.date, _tripId),
        skip: {for (final r in staff ? _addStaff : _addStudents) trId(r['enrollment_id'])},
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      for (final p in picked) {
        final r = <String, dynamic>{...p, 'status': 'EXPECTED', 'mark_method': null, 'is_extra': true, '_pending': true};
        (staff ? _addStaff : _addStudents).add(r);
        _now[_key(staff, r)] = 'PRESENT'; // they came on this vehicle
      }
    });
  }

  Future<void> _save() async {
    List<Map<String, dynamic>> rows(bool staff) => [
          for (final r in staff ? _staff : _students)
            if (_off.contains(_key(staff, r)))
              {'enrollment_id': trId(r['enrollment_id']), 'status': 'REMOVE'}
            else if (_now.containsKey(_key(staff, r)))
              {'enrollment_id': trId(r['enrollment_id']), 'status': _now[_key(staff, r)]},
          for (final r in staff ? _addStaff : _addStudents)
            {'enrollment_id': trId(r['enrollment_id']), 'status': _status(staff, r), 'add': true},
        ];
    final n = _changes;
    setState(() => _saving = true);
    try {
      await widget.save(widget.date, _tripId, rows(false), rows(true));
      if (!mounted) return;
      trSnack(context, n == 1 ? 'Saved 1 boarding entry.' : 'Saved $n boarding entries.', AppColors.success);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  /// A drop (school to the stops) is marked in its own words: Dropped, Not
  /// boarded; a pickup: Present, Absent.
  bool get _drop => widget.trip['direction'] == 'DROP';
  String get _presentLabel => _drop ? 'Dropped' : 'Present';

  Widget _chips(bool staff, Map<String, dynamic> r) {
    final now = _status(staff, r);
    final id = _key(staff, r);
    final off = _isOff(staff, r);
    final options = _drop
        ? [
            ('PRESENT', 'Dropped', 'Got off the bus at the stop', AppColors.success),
            ('ABSENT', 'Not boarded', 'Did not take the bus home', AppColors.error),
            if (!staff) ('PARENT_PICKUP', 'Parent pickup', 'Taken from school by the parents', AppColors.goldDark),
          ]
        : [
            ('PRESENT', 'Present', 'Boarded the bus at the stop', AppColors.success),
            ('ABSENT', 'Absent', 'Did not board the bus', AppColors.error),
            if (!staff) ('PARENT_PICKUP', 'Parent pickup', 'Brought to school by the parents', AppColors.goldDark),
          ];
    return Wrap(spacing: 6.w, runSpacing: 4.h, children: [
      for (final (value, label, tip, color) in options)
        ChoiceChip(
          key: ValueKey('dt-board-$id-$value'),
          label: Text(label),
          tooltip: tip,
          selected: !off && now == value,
          selectedColor: color.withValues(alpha: 0.18),
          visualDensity: VisualDensity.compact,
          // the chosen one tapped again: not marked
          onSelected: !_canMark || _saving || off ? null : (on) => _set(staff, r, on ? value : 'EXPECTED'),
        ),
    ]);
  }

  static const double _wTake = 40;

  Widget _row(bool staff, Map<String, dynamic> r, int i) {
    final key = _key(staff, r);
    final off = _isOff(staff, r);
    final added = _extra(r);
    return Opacity(
      opacity: off ? 0.55 : 1,
      child: Container(
        key: ValueKey('dt-rider-$key'),
        padding: EdgeInsets.only(left: 12.w, right: 4.w, top: 4.h, bottom: 4.h),
        decoration: BoxDecoration(
          color: _now.containsKey(key) || _pending(r) || off
              ? AppColors.accent.withValues(alpha: 0.06)
              : (i.isEven ? Colors.white : AppColors.surface),
          border: const Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(children: [
          SizedBox(
            width: 100,
            child: Text(trText(r[staff ? 'emp_code' : 'stuadmno']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
          ),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(trText(r[staff ? 'stafname' : 'stuname']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
                ),
                if (added) ...[
                  SizedBox(width: 6.w),
                  Tooltip(
                    message: off
                        ? 'Taken off this trip when saved'
                        : (_pending(r) ? 'Added to this trip; saved with Save' : 'Added to this trip from another vehicle of the route'),
                    child: AppUI.chip(off ? 'Taken off' : 'Added', off ? AppStatus.danger : AppStatus.info),
                  ),
                ] else if (_toldBefore(staff, r)) ...[
                  SizedBox(width: 6.w),
                  Tooltip(message: 'The parents told the school beforehand', child: AppUI.chip('Told before', AppStatus.neutral)),
                ],
              ]),
              Text(trText(r[staff ? 'designation' : 'stuclass']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
            ]),
          ),
          SizedBox(width: 150, child: Text(trText(r['stop_name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted)),
          SizedBox(width: staff ? 200 : 320, child: _chips(staff, r)),
          SizedBox(
            width: _wTake,
            child: added && _canMark
                ? IconButton(
                    key: ValueKey('dt-takeoff-$key'),
                    tooltip: off ? 'Keep on this trip' : 'Take off this trip',
                    visualDensity: VisualDensity.compact,
                    onPressed: _saving ? null : () => _takeOff(staff, r),
                    icon: AppIcon(off ? 'rotate-left' : 'close-circle', size: 18, color: off ? AppColors.ink2 : AppColors.error),
                  )
                : null,
          ),
        ]),
      ),
    );
  }

  /// Students / Staff, each with how many it has and how many are marked;
  /// Add Student / Add Staff for the open one.
  Widget _tabs() {
    Widget tab(bool staff, String label, String icon) {
      final list = _riding(staff);
      return PillTab(
        key: ValueKey('dt-tab-${staff ? 'staff' : 'students'}'),
        icon: icon,
        label: '$label · ${list.length}${list.isEmpty ? '' : '  (${_marked(staff, list)} marked)'}',
        selected: _staffTab == staff,
        onTap: () => setState(() => _staffTab = staff),
      );
    }

    return Row(children: [
      tab(false, 'Students', 'people'),
      SizedBox(width: PillTab.gap(context)),
      tab(true, 'Staff', 'teacher'),
      const Spacer(),
      if (_canMark && widget.options != null)
        Tooltip(
          message: 'A ${_staffTab ? 'staff member' : 'student'} of this route who missed their own vehicle and came on this one',
          child: OutlinedButton.icon(
            key: const ValueKey('dt-add-riders'),
            onPressed: _saving ? null : _add,
            style: AppUI.secondary(context),
            icon: AppIcon('user-add', size: AppBtn.iconSize(context), color: AppColors.primaryText),
            label: Text(_staffTab ? 'Add Staff' : 'Add Student'),
          ),
        ),
    ]);
  }

  /// The open tab's list: a head, then its rows.
  Widget _body() {
    final staff = _staffTab;
    final list = _list(staff);
    if (list.isEmpty) {
      return AppUI.empty(title: staff ? 'No staff on this trip' : 'No students on this trip', icon: 'people');
    }
    Widget head(String text, double? width) {
      final t = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.tableHead);
      return width == null ? Expanded(child: t) : SizedBox(width: width, child: t);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: AppColors.tableHeadBg,
        padding: EdgeInsets.only(left: 12.w, right: 4.w, top: 8.h, bottom: 8.h),
        child: Row(children: [
          head(staff ? 'EMP CODE' : 'ADM NO', 100),
          head(staff ? 'NAME · DESIGNATION' : 'NAME · CLASS', null),
          head('STOP', 150),
          head(_drop ? 'DROP-OFF' : 'BOARDING', staff ? 200 : 320),
          const SizedBox(width: _wTake),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          key: ValueKey('dt-list-${staff ? 'staff' : 'students'}'),
          itemCount: list.length,
          itemBuilder: (_, i) => _row(staff, list[i], i),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trip;
    final riding = [..._riding(false).map((r) => _status(false, r)), ..._riding(true).map((r) => _status(true, r))];
    final marked = riding.where((s) => s != 'EXPECTED').length;
    final total = riding.length;
    final how = !_canMark && !_loading
        ? 'Boarding can be entered from the trip\'s day on, and not for a cancelled trip.'
        : _drop
            ? 'Mark each one Dropped (got off at the stop), Not boarded, or Parent pickup (taken from school by the parents).'
            : 'Mark each one Present (boarded), Absent, or Parent pickup (brought to school by the parents).';
    final open = _open;
    final openMarked = _marked(_staffTab, open);
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 700),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(
              icon: 'people',
              title: 'Trip ${trText(t['schedule_code'])} · ${t['direction'] == 'DROP' ? 'Drop' : 'Pickup'}',
              subtitle: '${formatDate(widget.date)} · ${trText(t['route_code'])} · ${trText(t['vehicle_code'])}. $how',
            ),
          ),
          if (!_loading && _error == null)
            Padding(padding: EdgeInsets.fromLTRB(AppUI.cardPad, 0, AppUI.cardPad, 10.h), child: _tabs()),
          Expanded(
            child: _loading
                ? const AppLoading()
                : _error != null
                    ? AppUI.empty(title: 'Could not load the riders', why: _error, icon: 'info-circle')
                    : _body(),
          ),
          AppFormFooter(
            note: _loading || _error != null ? null : '$marked of $total marked${_changes > 0 ? ' · $_changes not saved' : ''}',
            onCancel: () => Navigator.pop(context),
            cancelLabel: 'Close',
            actions: [
              if (_canMark)
                OutlinedButton(
                  key: const ValueKey('dt-deselect-all'),
                  onPressed: _saving || openMarked == 0 ? null : _deselectAll,
                  style: AppUI.secondary(context),
                  child: const Text('Deselect All'),
                ),
              if (_canMark)
                OutlinedButton(
                  key: const ValueKey('dt-rest-present'),
                  onPressed: _saving || openMarked == open.length ? null : _restPresent,
                  style: AppUI.secondary(context),
                  child: Text('Rest $_presentLabel'),
                ),
              if (_canMark)
                ElevatedButton(
                  onPressed: _saving || _changes == 0 ? null : _save,
                  style: AppUI.primary(context),
                  child: Text(_saving ? 'Saving...' : (_changes == 0 ? AppText.save : 'Save $_changes')),
                ),
            ],
          ),
        ]),
      ),
    );
  }
}

/// Add Student / Add Staff: the route's riders travelling the trip's way on
/// the day who are not on it, each with the trip they are on and how they are
/// marked there (or no vehicle allotted). One already present on another
/// trip cannot be chosen. Pops with the ones chosen.
class _AddRidersDialog extends StatefulWidget {
  final bool staff;
  final bool drop;

  /// The trip's code, for the title.
  final String code;
  final Future<Map<String, dynamic>> Function() load;

  /// Already added in the Riders window: not offered again.
  final Set<int?> skip;

  const _AddRidersDialog({required this.staff, required this.drop, required this.code, required this.load, required this.skip});

  @override
  State<_AddRidersDialog> createState() => _AddRidersDialogState();
}

class _AddRidersDialogState extends State<_AddRidersDialog> {
  List<Map<String, dynamic>> _all = const [];
  bool _loading = true;
  String? _error;
  String _q = '';
  final Set<int> _ticked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.load();
      if (!mounted) return;
      setState(() {
        _all = [
          for (final x in _TripRidersDialogState._maps(r[widget.staff ? 'staff' : 'students']))
            if (!widget.skip.contains(trId(x['enrollment_id']))) x,
        ];
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

  bool _present(Map<String, dynamic> r) => r['present'] == true;

  /// Where they are today: "On KLM-D · VAN-02 · not marked", or no vehicle.
  String _where(Map<String, dynamic> r) {
    final code = trText(r['on_trip_code']);
    if (code.isEmpty) return 'No vehicle allotted';
    if (_present(r)) return 'Already ${widget.drop ? 'dropped by' : 'present on'} $code · ${trText(r['on_vehicle_code'])}';
    final how = switch (trText(r['on_status'])) {
      'ABSENT' || 'NO_SHOW' => widget.drop ? 'not boarded' : 'absent',
      'PARENT_PICKUP' => 'parent pickup',
      _ => 'not marked',
    };
    final cancelled = r['on_trip_status'] == 'CANCELLED' ? ' (cancelled)' : '';
    return 'On $code$cancelled · ${trText(r['on_vehicle_code'])} · $how';
  }

  List<Map<String, dynamic>> get _shown {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _all;
    final s = widget.staff;
    return [
      for (final r in _all)
        if ([r[s ? 'emp_code' : 'stuadmno'], r[s ? 'stafname' : 'stuname'], r[s ? 'designation' : 'stuclass'], r['stop_name']]
            .map(trText)
            .join(' ')
            .toLowerCase()
            .contains(q))
          r,
    ];
  }

  Widget _row(Map<String, dynamic> r, int i) {
    final s = widget.staff;
    final id = trId(r['enrollment_id'])!;
    final present = _present(r);
    final on = _ticked.contains(id);
    void toggle() => setState(() => on ? _ticked.remove(id) : _ticked.add(id));
    return InkWell(
      onTap: present ? null : toggle,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
        decoration: BoxDecoration(
          color: on ? AppColors.accent.withValues(alpha: 0.08) : (i.isEven ? Colors.white : AppColors.surface),
          border: const Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(children: [
          Checkbox(key: ValueKey('dt-pick-$id'), value: on, onChanged: present ? null : (_) => toggle()),
          SizedBox(width: 100, child: Text(trText(r[s ? 'emp_code' : 'stuadmno']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trText(r[s ? 'stafname' : 'stuname']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
              Text(trText(r[s ? 'designation' : 'stuclass']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
            ]),
          ),
          SizedBox(width: 150, child: Text(trText(r['stop_name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted)),
          SizedBox(
            width: 230,
            child: Text(_where(r),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: present ? AppUI.muted.copyWith(color: AppColors.error, fontWeight: FontWeight.w700) : AppUI.muted),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.staff ? 'staff' : 'students';
    final shown = _shown;
    final n = _ticked.length;
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 620),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 10.h),
            child: AppUI.cardHeader(
              icon: 'user-add',
              title: 'Add ${widget.staff ? 'Staff' : 'Students'} to Trip ${widget.code}',
              subtitle: 'The route\'s $who travelling this way that day who are not on this trip. Those added are marked '
                  '${widget.drop ? 'Dropped' : 'Present'} here, and ${widget.drop ? 'Not boarded' : 'Absent'} on their own trip if not marked there yet. '
                  'One already ${widget.drop ? 'dropped' : 'present'} on another trip cannot be added.',
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, 0, AppUI.cardPad, 8.h),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 320,
                child: TrSearchField(
                  hint: widget.staff ? 'Emp code, name or stop' : 'Adm no, name, class or stop',
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const AppLoading()
                : _error != null
                    ? AppUI.empty(title: 'Could not load the route\'s $who', why: _error, icon: 'info-circle')
                    : _all.isEmpty
                        ? AppUI.empty(title: 'No one else to add', why: 'All the route\'s $who travelling this way that day are on this trip.', icon: 'people')
                        : shown.isEmpty
                            ? AppUI.empty(title: 'No one matches', why: 'Try another search.', icon: 'search-normal')
                            : ListView.builder(
                                key: const ValueKey('dt-pick-list'),
                                itemCount: shown.length,
                                itemBuilder: (_, i) => _row(shown[i], i),
                              ),
          ),
          AppFormFooter(
            note: n == 0 ? null : '$n chosen',
            onCancel: () => Navigator.pop(context),
            cancelLabel: 'Close',
            actions: [
              ElevatedButton(
                key: const ValueKey('dt-pick-add'),
                onPressed: n == 0 ? null : () => Navigator.pop(context, [for (final r in _all) if (_ticked.contains(trId(r['enrollment_id']))) r]),
                style: AppUI.primary(context),
                child: Text(n == 0 ? 'Add' : 'Add $n'),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
