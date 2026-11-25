import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_ui.dart';
import 'transport_master_panel.dart';

/// Replace Trip (Daily Trips, a cancelled trip's Replace button): another
/// vehicle runs the cancelled trip, e.g. when its bus broke down. The new
/// trip has the same schedule, times, stops and riders (with the boarding
/// marked so far) and the other crew; the vehicle, driver and attender are
/// chosen here (tr_trip_replace). The cancelled trip stays, with its reason.
/// Pops with the chosen vehicle's code once replaced.
class TripReplaceDialog extends StatefulWidget {
  final Map<String, dynamic> trip;

  /// The trip's day (yyyy-mm-dd).
  final String date;

  /// "9:30 PM – 10:30 PM".
  final String times;
  final List<Map<String, dynamic>> vehicles;
  final List<Map<String, dynamic>> staff;
  final Future<void> Function(String date, Map<String, dynamic> row) replace;

  const TripReplaceDialog({
    super.key,
    required this.trip,
    required this.date,
    required this.times,
    required this.vehicles,
    required this.staff,
    required this.replace,
  });

  @override
  State<TripReplaceDialog> createState() => _TripReplaceDialogState();
}

class _TripReplaceDialogState extends State<TripReplaceDialog> {
  int? _vehicle;
  int? _driver;
  int? _attender;
  bool _saving = false;
  String? _error;

  Map<String, dynamic> get _t => widget.trip;

  int? _crew(String role) {
    for (final c in (_t['crew'] as List? ?? const [])) {
      if (c is Map && c['duty_role'] == role) return trId(c['staff_id']);
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // the cancelled trip's crew go along unless changed here
    _driver = _crew('DRIVER');
    _attender = _crew('ATTENDER');
  }

  int get _riders => (trId(_t['students']) ?? 0) + (trId(_t['staff']) ?? 0);

  int _seats(Map<String, dynamic> v) => (trId(v['seating_capacity']) ?? 0) + (trId(v['additional_capacity']) ?? 0);

  Map<String, dynamic>? get _chosen {
    for (final v in widget.vehicles) {
      if (trId(v['vehicle_id']) == _vehicle) return v;
    }
    return null;
  }

  /// In service, and not the cancelled trip's own.
  List<Map<String, dynamic>> get _offered => [
        for (final v in widget.vehicles)
          if (v['status'] == 'ACTIVE' && trId(v['vehicle_id']) != trId(_t['vehicle_id'])) v,
      ];

  List<(int?, String)> _people(String type, {bool none = false}) => [
        if (none) (null, 'None'),
        for (final s in widget.staff)
          if (s['staff_type'] == type && s['status'] == 'ACTIVE')
            (trId(s['staff_id']), '${trText(s['full_name'])} (${trText(s['staff_code'])})'),
      ];

  bool get _tooSmall => _chosen != null && _seats(_chosen!) < _riders;

  bool get _ready => _vehicle != null && _driver != null && !_tooSmall && !_saving;

  Future<void> _go() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.replace(widget.date, {
        'trip_id': trId(_t['trip_id']),
        'updated_at': _t['updated_at'],
        'vehicle_id': _vehicle,
        'driver_id': _driver,
        'attender_id': _attender,
      });
      if (mounted) Navigator.pop(context, trText(_chosen?['vehicle_code']));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e);
      });
    }
  }

  Widget _field<T>(Key key, String label, T? value, List<(T?, String)> items, ValueChanged<T?> onPick) => Padding(
        padding: EdgeInsets.only(bottom: 12.h),
        child: AppDropdownField<T?>(
          key: key,
          initialValue: items.any((o) => o.$1 == value) ? value : null,
          isExpanded: true,
          menuMaxHeight: 380,
          dropdownColor: AppColors.card,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          style: AppUI.fieldText(context),
          decoration: AppUI.field(context, label),
          items: [for (final o in items) DropdownMenuItem<T?>(value: o.$1, child: Text(o.$2, maxLines: 1, overflow: TextOverflow.ellipsis))],
          onChanged: _saving ? null : onPick,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final code = trText(_t['schedule_code']);
    final students = trId(_t['students']) ?? 0;
    final staff = trId(_t['staff']) ?? 0;
    final reason = trText(_t['cancel_reason']);
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(
              icon: 'arrow-swap-horizontal',
              title: 'Replace Trip $code · ${_t['direction'] == 'DROP' ? 'Drop' : 'Pickup'}',
              subtitle: '${formatDate(widget.date)} · ${trText(_t['route_code'])} · ${trText(_t['vehicle_code'])}'
                  '${reason.isEmpty ? '' : ', cancelled: $reason'}',
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                'Another vehicle runs this trip at the same time (${widget.times}), with the same stops and its '
                '$students student${students == 1 ? '' : 's'} and $staff staff. Boarding marked so far goes with them. '
                'The cancelled trip stays, with its reason.',
                style: AppUI.muted,
              ),
              SizedBox(height: 14.h),
              _field<int>(
                const ValueKey('dt-rep-vehicle'),
                'Vehicle *',
                _vehicle,
                [for (final v in _offered) (trId(v['vehicle_id']), '${trText(v['vehicle_code'])} · ${_seats(v)} seats')],
                (v) => setState(() => _vehicle = v),
              ),
              _field<int>(const ValueKey('dt-rep-driver'), 'Driver *', _driver, _people('DRIVER'), (v) => setState(() => _driver = v)),
              _field<int>(const ValueKey('dt-rep-attender'), 'Attender', _attender, _people('ATTENDER', none: true), (v) => setState(() => _attender = v)),
              if (_tooSmall)
                Text('${trText(_chosen!['vehicle_code'])} takes ${_seats(_chosen!)}, but the trip expects $_riders riders.',
                    style: AppUI.muted.copyWith(color: AppColors.error)),
              if (_error != null) Text(_error!, key: const ValueKey('dt-rep-error'), style: AppUI.muted.copyWith(color: AppColors.error)),
              SizedBox(height: 12.h),
            ]),
          ),
          AppFormFooter(
            onCancel: _saving ? null : () => Navigator.pop(context),
            cancelLabel: 'Close',
            actions: [
              ElevatedButton(
                key: const ValueKey('dt-rep-go'),
                onPressed: _ready ? _go : null,
                style: AppUI.primary(context),
                child: Text(_saving ? 'Replacing...' : 'Replace Trip'),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
