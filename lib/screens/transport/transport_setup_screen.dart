import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/transport_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// TRANSPORT SETUP -- the school's location and the limits that later GPS and
/// document alerts work from. One record per school.
class TransportSetupScreen extends StatefulWidget {
  const TransportSetupScreen({super.key});

  @override
  State<TransportSetupScreen> createState() => _TransportSetupScreenState();
}

class _TransportSetupScreenState extends State<TransportSetupScreen> {
  final _form = GlobalKey<TrFormBodyState>();
  Map<String, dynamic>? _settings;
  String? _error;
  bool _saving = false;
  int _nonce = 0;

  static const _fields = <TrField>[
    TrField('school_latitude', 'School Latitude', kind: TrKind.decimal, section: 'School Location', hint: 'e.g. 13.0827'),
    TrField('school_longitude', 'School Longitude', kind: TrKind.decimal, hint: 'e.g. 80.2707'),
    TrField('school_geofence_m', 'School Arrival Radius (metres)', kind: TrKind.integer, required: true),
    TrField('default_geofence_m', 'Stop Arrival Radius (metres)', kind: TrKind.integer, required: true),
    TrField('overspeed_kmph', 'Overspeed Limit (km/h)', kind: TrKind.integer, required: true, section: 'Trip Limits'),
    TrField('long_halt_minutes', 'Long Halt After (minutes)', kind: TrKind.integer, required: true),
    TrField('gps_ping_interval_sec', 'GPS Update Every (seconds)', kind: TrKind.integer, required: true),
    TrField('auto_start_trip', 'Start Trips Automatically From GPS', kind: TrKind.toggle),
    TrField('doc_expiry_alert_days', 'Warn Before Document Expiry (days)', kind: TrKind.integer, required: true, section: 'Documents'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await TransportService.settings();
      if (!mounted) return;
      setState(() {
        _settings = s;
        _error = null;
        _nonce++;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _save() async {
    final row = _form.currentState?.collect();
    if (row == null) return;
    setState(() => _saving = true);
    try {
      await TransportService.saveSettings(row);
      if (!mounted) return;
      trSnack(context, 'Transport settings saved.', AppColors.success);
      await _load();
    } catch (e) {
      if (mounted) trSnack(context, AppText.couldNot('save the settings', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Transport Setup',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton(onPressed: _load, style: AppUI.secondary(context), child: const Text('Retry')),
      );
    }
    final s = _settings;
    if (s == null) return const AppLoading();
    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
          child: AppUI.cardHeader(
            icon: 'setting-2',
            title: 'Transport Setup',
            subtitle: 'The school location and the limits used for trips and document alerts.',
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(AppUI.cardPad),
            child: KeyedSubtree(key: ValueKey('setup-$_nonce'), child: TrFormBody(key: _form, fields: _fields, initial: s, enabled: !_saving)),
          ),
        ),
        AppFormFooter(
          note: AppText.requiredNote,
          actions: [
            ElevatedButton(onPressed: _saving ? null : _save, style: AppUI.primary(context), child: Text(_saving ? 'Saving...' : AppText.save)),
          ],
        ),
      ]),
    );
  }
}
