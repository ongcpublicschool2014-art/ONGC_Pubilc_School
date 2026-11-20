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

/// GPS MAPPING -- which GPS device is on each vehicle, as a grid: one row per
/// vehicle with its device and the day it went on. Change the device or the
/// date in as many rows as needed, then save them together (tr_save
/// 'vehicle_gps'), so a device can move to another vehicle, or two vehicles
/// can swap devices, in one go. Nothing is overwritten: every change is kept
/// as history in tr_vehicle_gps_device, which the clock button shows.
class GpsMappingPanel extends StatefulWidget {
  /// Told when the grid gets, or loses, changes that are not saved yet.
  final ValueChanged<bool>? onDirtyChanged;
  const GpsMappingPanel({super.key, this.onDirtyChanged});

  @override
  State<GpsMappingPanel> createState() => _GpsMappingPanelState();
}

class _GpsMappingPanelState extends State<GpsMappingPanel> {
  List<Map<String, dynamic>> _vehicles = const [];
  List<Map<String, dynamic>> _devices = const [];
  List<Map<String, dynamic>> _links = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The vehicles, the devices, and every device change so far.
  Future<void> _load() async {
    try {
      final r = await Future.wait([
        TransportService.list('vehicle'),
        TransportService.list('gps_device'),
        TransportService.list('vehicle_gps'),
      ]);
      if (!mounted) return;
      setState(() {
        _vehicles = r[0];
        _devices = r[1];
        _links = r[2];
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

  Future<void> _save(List<Map<String, dynamic>> changes) async {
    await TransportService.save('vehicle_gps', {'changes': changes});
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open GPS Mapping',
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
    return GpsMappingGrid(
      vehicles: _vehicles,
      devices: _devices,
      links: _links,
      onSave: _save,
      onDirtyChanged: widget.onDirtyChanged,
    );
  }
}

/// A GPS device as the grid names it: its IMEI (or "Device #3"), its kind,
/// and its SIM number when there is one.
String gpsDeviceName(Map<String, dynamic> d) {
  final imei = trText(d['imei']);
  final sim = trText(d['sim_no']);
  return '${imei.isEmpty ? 'Device #${trText(d['device_id'])}' : imei}'
      ' · ${d['device_type'] == 'MOBILE_APP' ? 'Mobile App' : 'Hardware'}'
      '${sim.isEmpty ? '' : ' · SIM $sim'}';
}

/// What saving a row will do.
enum GpsChange { none, putOn, takeOff, replace, fixDate }

/// A row's change, waiting for Save: the device the vehicle has from [date]
/// (null: none).
class _Edit {
  final int? device;
  final String date;
  const _Edit(this.device, this.date);
}

/// The grid itself, given the lists, so it can be shown without a server.
/// [onSave] gets the changed rows as the server takes them and throws when
/// they are refused.
class GpsMappingGrid extends StatefulWidget {
  final List<Map<String, dynamic>> vehicles;
  final List<Map<String, dynamic>> devices;

  /// tr_vehicle_gps_device rows, latest first for each vehicle.
  final List<Map<String, dynamic>> links;
  final Future<void> Function(List<Map<String, dynamic>> changes) onSave;
  final ValueChanged<bool>? onDirtyChanged;

  /// Today; the computer's date when null.
  final DateTime? today;

  const GpsMappingGrid({
    super.key,
    required this.vehicles,
    required this.devices,
    required this.links,
    required this.onSave,
    this.onDirtyChanged,
    this.today,
  });

  @override
  State<GpsMappingGrid> createState() => _GpsMappingGridState();
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String? _isoDate(dynamic v) {
  final s = trText(v);
  return s.length >= 10 ? s.substring(0, 10) : null;
}

const _statusNames = {'ACTIVE': 'Active', 'UNDER_REPAIR': 'Under Repair', 'INACTIVE': 'Inactive', 'SOLD': 'Sold', 'SCRAPPED': 'Scrapped'};

class _GpsMappingGridState extends State<GpsMappingGrid> {
  /// Vehicle id -> its change, only for rows that differ from what is saved.
  final Map<int, _Edit> _edits = {};
  String _query = '';
  bool _saving = false;
  bool _wasDirty = false;

  Map<int, Map<String, dynamic>> _deviceById = const {};

  /// Vehicle id -> its code.
  Map<int, String> _codes = const {};

  /// Vehicle id -> the history row of the device on it now.
  Map<int, Map<String, dynamic>> _onNow = const {};

  @override
  void initState() {
    super.initState();
    _index();
  }

  @override
  void didUpdateWidget(GpsMappingGrid old) {
    super.didUpdateWidget(old);
    if (old.vehicles != widget.vehicles || old.devices != widget.devices || old.links != widget.links) _index();
  }

  void _index() {
    _deviceById = {
      for (final d in widget.devices)
        if (trId(d['device_id']) != null) trId(d['device_id'])!: d,
    };
    _codes = {
      for (final v in widget.vehicles)
        if (trId(v['vehicle_id']) != null) trId(v['vehicle_id'])!: trText(v['vehicle_code']),
    };
    _onNow = {
      for (final l in widget.links)
        if (l['removed_on'] == null && trId(l['vehicle_id']) != null) trId(l['vehicle_id'])!: l,
    };
  }

  String get _today => _iso(widget.today ?? DateTime.now());

  int? _savedDevice(int vid) => trId(_onNow[vid]?['device_id']);
  String? _savedDate(int vid) => _isoDate(_onNow[vid]?['installed_on']);

  /// The device and date the row shows: its change, or what is saved.
  int? _device(int vid) => _edits.containsKey(vid) ? _edits[vid]!.device : _savedDevice(vid);
  String? _date(int vid) => _edits[vid]?.date ?? _savedDate(vid);

  GpsChange _change(int vid) {
    final e = _edits[vid];
    if (e == null) return GpsChange.none;
    final was = _savedDevice(vid);
    if (e.device == was) return e.date == _savedDate(vid) ? GpsChange.none : GpsChange.fixDate;
    if (was == null) return GpsChange.putOn;
    return e.device == null ? GpsChange.takeOff : GpsChange.replace;
  }

  int get _changeCount => _edits.keys.where((vid) => _change(vid) != GpsChange.none).length;

  void _dirty() {
    final now = _changeCount > 0;
    if (now != _wasDirty) {
      _wasDirty = now;
      widget.onDirtyChanged?.call(now);
    }
  }

  /// Vehicles in use, and any other vehicle that still has a device on it
  /// (so it can be taken off). Sold, scrapped and inactive ones are left out.
  List<Map<String, dynamic>> get _rows => [
        for (final v in widget.vehicles)
          if (trId(v['vehicle_id']) != null &&
              (v['status'] == 'ACTIVE' || v['status'] == 'UNDER_REPAIR' || _savedDevice(trId(v['vehicle_id'])!) != null))
            v,
      ];

  void _setDevice(int vid, int? device) {
    setState(() {
      final saved = _savedDevice(vid);
      if (device == saved) {
        _edits.remove(vid); // back to what is saved
      } else {
        // a date picked for an earlier device change stays; otherwise today
        final e = _edits[vid];
        _edits[vid] = _Edit(device, e != null && e.device != saved ? e.date : _today);
      }
    });
    _dirty();
  }

  void _setDate(int vid, String date) {
    setState(() {
      final device = _device(vid);
      if (device == _savedDevice(vid) && date == _savedDate(vid)) {
        _edits.remove(vid);
      } else {
        _edits[vid] = _Edit(device, date);
      }
    });
    _dirty();
  }

  void _undo([int? vid]) {
    setState(() => vid == null ? _edits.clear() : _edits.remove(vid));
    _dirty();
  }

  Future<void> _pickDate(int vid, String code) async {
    final today = DateTime.parse(_today);
    final first = DateTime(2000);
    var initial = DateTime.tryParse(_date(vid) ?? '') ?? today;
    if (initial.isAfter(today)) initial = today;
    if (initial.isBefore(first)) initial = first;
    final picked = await trPickDate(
      context,
      initialDate: initial,
      firstDate: first,
      lastDate: today,
      helpText: 'GPS date for $code',
    );
    if (picked == null || !mounted) return;
    _setDate(vid, _iso(picked));
  }

  /// What the server would refuse anyway, said before sending; null if fine.
  String? _problem() {
    for (final e in _edits.entries) {
      final change = _change(e.key);
      if (change == GpsChange.none) continue;
      final code = _codes[e.key] ?? '';
      if (e.value.date.compareTo(_today) > 0) return 'The date for $code cannot be in the future.';
      final since = _savedDate(e.key);
      if ((change == GpsChange.takeOff || change == GpsChange.replace) && since != null && e.value.date.compareTo(since) < 0) {
        return 'The date for $code cannot be before ${formatDate(since)}, the day its GPS device went on.';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final changes = [
      for (final e in _edits.entries)
        if (_change(e.key) != GpsChange.none)
          {'vehicle_id': e.key, 'device_id': e.value.device, 'was_device_id': _savedDevice(e.key), 'date': e.value.date},
    ];
    if (changes.isEmpty) return;
    final problem = _problem();
    if (problem != null) {
      trSnack(context, problem, AppColors.warning);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(changes);
      if (!mounted) return;
      setState(() {
        _edits.clear();
        _saving = false;
      });
      _dirty();
      trSnack(context, changes.length == 1 ? 'Saved 1 change.' : 'Saved ${changes.length} changes.', AppColors.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  // ── cells ──────────────────────────────────────────────────────────────────
  Widget _vehicleCell(Map<String, dynamic> v) {
    final type = trText(v['vehicle_type']).replaceAll('_', ' ');
    final detail = [trText(v['registration_no']), if (type.isNotEmpty) type[0] + type.substring(1).toLowerCase()].where((s) => s.isNotEmpty).join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(trText(v['vehicle_code']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label.copyWith(color: AppColors.ink)),
      if (detail.isNotEmpty) Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
    ]);
  }

  Widget _statusCell(dynamic status) {
    final s = trText(status);
    return AppUI.chip(_statusNames[s] ?? (s.isEmpty ? '-' : s),
        s == 'ACTIVE' ? AppStatus.success : (s == 'UNDER_REPAIR' ? AppStatus.warning : AppStatus.neutral));
  }

  /// The device picker. A switched-off device is offered only to the vehicle
  /// that has it; a device chosen on another row says where, and cannot be
  /// picked until it is taken off there. [heldBy]: device id -> vehicle id.
  Widget _devicePicker(int vid, Map<int, int> heldBy) {
    final value = _device(vid);
    final saved = _savedDevice(vid);
    return AppDropdownField<int?>(
      key: ValueKey('gps-device-$vid-$value'),
      initialValue: value,
      isExpanded: true,
      menuMaxHeight: 360,
      dropdownColor: AppColors.card,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      style: AppUI.fieldText(context),
      decoration: AppUI.field(context, '', dense: true, filled: value != null),
      items: [
        DropdownMenuItem<int?>(value: null, child: Text('No device', style: AppUI.muted)),
        for (final e in _deviceById.entries)
          if (e.value['is_active'] != false || e.key == saved || e.key == value)
            _deviceItem(e.key, e.value, heldBy[e.key] == null || heldBy[e.key] == vid ? null : _codes[heldBy[e.key]]),
      ],
      onChanged: _saving ? null : (v) => _setDevice(vid, v),
    );
  }

  /// [elsewhere]: the code of the other vehicle the device is on, if any.
  DropdownMenuItem<int?> _deviceItem(int id, Map<String, dynamic> d, String? elsewhere) => DropdownMenuItem<int?>(
        value: id,
        enabled: elsewhere == null,
        child: Text(
          '${gpsDeviceName(d)}${d['is_active'] == false ? ' · Switched off' : ''}${elsewhere == null ? '' : ' · on $elsewhere'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: elsewhere == null ? null : AppUI.muted,
        ),
      );

  Widget _dateCell(int vid, String code, GpsChange change) {
    final date = _date(vid);
    final hasDevice = _device(vid) != null || _savedDevice(vid) != null;
    final tip = switch (change) {
      GpsChange.putOn => 'The day the device goes on',
      GpsChange.takeOff => 'The day the device comes off',
      GpsChange.replace => 'The day the old device comes off and the new one goes on',
      GpsChange.fixDate => 'The corrected day the device went on',
      GpsChange.none => hasDevice ? 'The day the device went on. Pick another day to correct it.' : '',
    };
    final field = InkWell(
      onTap: !_saving && hasDevice ? () => _pickDate(vid, code) : null,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: InputDecorator(
        decoration: AppUI.field(context, '', dense: true, filled: hasDevice && date != null, leadingIcon: 'calendar'),
        child: Text(
          hasDevice && date != null ? formatDate(date) : '–',
          maxLines: 1,
          style: hasDevice && date != null ? AppUI.fieldText(context) : AppUI.muted,
        ),
      ),
    );
    return tip.isEmpty ? field : Tooltip(message: tip, child: field);
  }

  Widget _changeCell(int vid, GpsChange change) {
    if (change == GpsChange.none) return const SizedBox.shrink();
    final (text, status) = switch (change) {
      GpsChange.putOn => ('Put On', AppStatus.info),
      GpsChange.takeOff => ('Take Off', AppStatus.danger),
      GpsChange.replace => ('Replace', AppStatus.warning),
      _ => ('Fix Date', AppStatus.info),
    };
    return Row(children: [
      Flexible(child: AppUI.chip(text, status)),
      IconButton(
        tooltip: 'Undo this row',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        onPressed: _saving ? null : () => _undo(vid),
        icon: const AppIcon('rotate-left', size: 16, color: AppColors.ink2),
      ),
    ]);
  }

  // ── history ────────────────────────────────────────────────────────────────
  void _history(Map<String, dynamic> v) {
    final vid = trId(v['vehicle_id']);
    final rows = [for (final l in widget.links) if (trId(l['vehicle_id']) == vid) l];
    final today = DateTime.parse(_today);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
          child: Padding(
            padding: EdgeInsets.all(AppUI.cardPad),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AppUI.cardHeader(icon: 'clock', title: 'GPS history: ${trText(v['vehicle_code'])}', subtitle: trText(v['registration_no'])),
              SizedBox(height: 14.h),
              if (rows.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 24.h),
                  child: Text('No GPS device has been on this vehicle yet.', textAlign: TextAlign.center, style: AppUI.muted),
                )
              else
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.line),
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Container(
                        decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
                        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                        child: Row(children: [
                          Expanded(flex: 5, child: Text('DEVICE', style: AppUI.tableHead)),
                          Expanded(flex: 2, child: Text('WENT ON', style: AppUI.tableHead)),
                          Expanded(flex: 2, child: Text('CAME OFF', style: AppUI.tableHead)),
                          Expanded(flex: 1, child: Text('DAYS', textAlign: TextAlign.right, style: AppUI.tableHead)),
                        ]),
                      ),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: rows.length,
                          itemBuilder: (_, i) {
                            final l = rows[i];
                            final d = _deviceById[trId(l['device_id'])];
                            final on = DateTime.tryParse(_isoDate(l['installed_on']) ?? '');
                            final off = DateTime.tryParse(_isoDate(l['removed_on']) ?? '');
                            final days = on == null ? null : (off ?? today).difference(on).inDays;
                            return Container(
                              decoration: BoxDecoration(color: i.isEven ? AppColors.card : AppColors.surface, border: const Border(bottom: BorderSide(color: AppColors.divider))),
                              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                              child: Row(children: [
                                Expanded(
                                  flex: 5,
                                  child: Text(d == null ? 'Device #${trText(l['device_id'])}' : gpsDeviceName(d),
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
                                ),
                                Expanded(flex: 2, child: Text(formatDate(_isoDate(l['installed_on'])), style: AppUI.cell)),
                                Expanded(
                                  flex: 2,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: off == null ? AppUI.chip('On Now', AppStatus.success) : Text(formatDate(_isoDate(l['removed_on'])), style: AppUI.cell),
                                  ),
                                ),
                                Expanded(flex: 1, child: Text(days == null ? '-' : '$days', textAlign: TextAlign.right, style: AppUI.cell)),
                              ]),
                            );
                          },
                        ),
                      ),
                    ]),
                  ),
                ),
              SizedBox(height: 12.h),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppText.close)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── grid ───────────────────────────────────────────────────────────────────
  static const double _statusWidth = 120;
  static const double _dateWidth = 170;
  static const double _changeWidth = 140;
  static const double _historyWidth = 40;

  Widget _headCell(String text, {int? flex, double? width}) {
    final t = Padding(padding: EdgeInsets.only(right: 10.w), child: Text(text, style: AppUI.tableHead, maxLines: 1));
    return flex != null ? Expanded(flex: flex, child: t) : SizedBox(width: width, child: t);
  }

  Widget _table(List<Map<String, dynamic>> rows, Map<int, int> heldBy) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 44.h,
        padding: EdgeInsets.symmetric(horizontal: 12.w),
        decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
        child: Row(children: [
          _headCell('VEHICLE', flex: 3),
          _headCell('STATUS', width: _statusWidth),
          _headCell('GPS DEVICE', flex: 5),
          _headCell('SINCE / DATE', width: _dateWidth),
          _headCell('CHANGE', width: _changeWidth),
          const SizedBox(width: _historyWidth),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final v = rows[i];
            final vid = trId(v['vehicle_id'])!;
            final code = trText(v['vehicle_code']);
            final change = _change(vid);
            return Container(
              key: ValueKey('gps-row-$vid'),
              constraints: BoxConstraints(minHeight: 48.h),
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 5.h),
              decoration: BoxDecoration(color: change != GpsChange.none ? AppColors.accent.withValues(alpha: 0.045) : (i.isEven ? Colors.white : AppColors.surface), border: const Border(bottom: BorderSide(color: AppColors.divider))),
              child: Row(children: [
                Expanded(flex: 3, child: Padding(padding: EdgeInsets.only(right: 10.w), child: _vehicleCell(v))),
                SizedBox(
                  width: _statusWidth,
                  child: Padding(padding: EdgeInsets.only(right: 10.w), child: Align(alignment: Alignment.centerLeft, child: _statusCell(v['status']))),
                ),
                Expanded(flex: 5, child: Padding(padding: EdgeInsets.only(right: 10.w), child: _devicePicker(vid, heldBy))),
                SizedBox(width: _dateWidth, child: Padding(padding: EdgeInsets.only(right: 10.w), child: _dateCell(vid, code, change))),
                SizedBox(width: _changeWidth, child: _changeCell(vid, change)),
                SizedBox(
                  width: _historyWidth,
                  child: IconButton(
                    tooltip: 'GPS history',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    onPressed: () => _history(v),
                    icon: const AppIcon('clock', size: 16, color: AppColors.ink2),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    ]);
  }

  /// Counts for the whole fleet as the grid shows it, unsaved changes included.
  Widget _summary(List<Map<String, dynamic>> rows, Map<int, int> heldBy, int changes) {
    final withDevice = rows.where((v) => _device(trId(v['vehicle_id'])!) != null).length;
    final free = widget.devices.where((d) => d['is_active'] != false && !heldBy.containsKey(trId(d['device_id']))).length;
    final parts = [
      '${rows.length} vehicle${rows.length == 1 ? '' : 's'}',
      '$withDevice with a GPS device',
      '${rows.length - withDevice} without',
      '$free device${free == 1 ? '' : 's'} not on any vehicle',
    ];
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: parts.join(' · '), style: AppUI.muted),
        if (changes > 0)
          TextSpan(
            text: '   ·   $changes change${changes == 1 ? '' : 's'} not saved',
            style: AppUI.muted.copyWith(color: AppColors.goldDark, fontWeight: FontWeight.w700),
          ),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    // device id -> the vehicle it is on, as the grid stands
    final heldBy = <int, int>{};
    for (final v in rows) {
      final vid = trId(v['vehicle_id'])!;
      final d = _device(vid);
      if (d != null) heldBy[d] = vid;
    }
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? rows
        : [
            for (final v in rows)
              if ('${v['vehicle_code']} ${v['registration_no']} ${_deviceById[_device(trId(v['vehicle_id'])!)]?['imei'] ?? ''}'.toLowerCase().contains(q)) v,
          ];
    final changes = _changeCount;
    final noDevices = widget.devices.isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppUI.cardHeader(
        icon: 'link',
        title: 'GPS Mapping',
        subtitle: noDevices
            ? 'Add the GPS devices in the GPS Devices tab first.'
            : 'Which GPS device is on each vehicle. Change devices or dates, then save them together.',
        trailing: [
          SizedBox(width: 220.w, child: TrSearchField(hint: AppText.search, onChanged: (v) => setState(() => _query = v))),
          OutlinedButton.icon(
            onPressed: changes == 0 || _saving ? null : () => _undo(),
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
        ],
      ),
      SizedBox(height: 10.h),
      _summary(rows, heldBy, changes),
      SizedBox(height: 10.h),
      Expanded(
        child: Container(
          decoration: AppUI.card(),
          clipBehavior: Clip.antiAlias,
          child: rows.isEmpty
              ? AppUI.empty(title: 'No vehicles in use', why: 'Add the vehicles in the Vehicles tab first.', icon: 'bus')
              : shown.isEmpty
                  ? AppUI.empty(title: 'No match for your search', why: 'Try a different word.', icon: 'link')
                  : _table(shown, heldBy),
        ),
      ),
    ]);
  }
}
