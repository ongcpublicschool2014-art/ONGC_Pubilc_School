import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/transport_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// ROUTES & STOPS -- one tree: route > stage > stop.
///
/// A route opens to show its stages in a box; each stage lists its stops in
/// pickup order on a timeline, with how many students get on or off there.
/// A stop has Edit and Delete on its row; a route or stage is edited from its
/// ... menu, and deleted in that edit dialog.
/// (Stage fares are left out for now; they stay in the database.)
class RoutesStopsScreen extends StatefulWidget {
  const RoutesStopsScreen({super.key});

  @override
  State<RoutesStopsScreen> createState() => _RoutesStopsScreenState();
}

/// One past the highest [key] in [rows] (the next stage or stop number).
int _next(Iterable<Map<String, dynamic>> rows, String key) =>
    rows.fold<int>(0, (m, r) {
      final v = trId(r[key]) ?? 0;
      return v > m ? v : m;
    }) +
    1;

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// One entry of a row's ⋯ menu.
typedef _Act = ({String icon, String label, VoidCallback onTap, bool danger});

class _RoutesStopsScreenState extends State<RoutesStopsScreen> {
  List<Map<String, dynamic>> _routes = const [];
  List<Map<String, dynamic>> _stages = const [];
  List<Map<String, dynamic>> _stops = const [];
  final Set<int> _open = {}; // routes shown open
  final Set<int> _closedStages = {}; // stages folded away (stages start open)
  bool _loading = true;
  String? _error;
  String _query = '';

  /// The active enrollments of each route opened, for the student counts;
  /// a route missing here is still loading (or its counts cannot be read).
  final Map<int, List<Map<String, dynamic>>> _enrolled = {};
  final Set<int> _enrolling = {};

  static const _routeFields = <TrField>[
    TrField('route_code', 'Route Code', kind: TrKind.upper, required: true, maxLength: 20, hint: 'e.g. R5'),
    TrField('route_name', 'Route Name', required: true, maxLength: 100, hint: 'e.g. North Line'),
    TrField('start_point', 'Start Point', maxLength: 150),
    TrField('end_point', 'End Point', maxLength: 150),
    TrField('total_distance_km', 'Total Distance (km)', kind: TrKind.decimal),
    TrField('est_duration_min', 'Duration (minutes)', kind: TrKind.integer),
    TrField('description', 'Description', kind: TrKind.multiline, full: true),
    TrField('is_active', 'Active', kind: TrKind.toggle),
  ];

  static const _stageFields = <TrField>[
    TrField('stage_no', 'Stage Number', kind: TrKind.integer, required: true),
    TrField('stage_name', 'Stage Name', required: true, maxLength: 100, hint: 'e.g. Up to 5 km'),
    TrField('from_km', 'From (km)', kind: TrKind.decimal),
    TrField('to_km', 'To (km)', kind: TrKind.decimal),
    TrField('is_active', 'Active', kind: TrKind.toggle),
  ];

  List<TrField> _stopFields(int routeId) => [
        const TrField('stop_seq', 'Stop Order', kind: TrKind.integer, required: true, hint: 'Order on the pickup run'),
        TrField('stage_id', 'Stage', kind: TrKind.choice, required: true, options: [
          for (final s in _stagesOf(routeId)) (trId(s['stage_id']), 'Stage ${trText(s['stage_no'])} - ${trText(s['stage_name'])}'),
        ]),
        const TrField('stop_name', 'Stop Name', required: true, maxLength: 150),
        const TrField('stop_code', 'Stop Code', kind: TrKind.upper, maxLength: 20),
        const TrField('latitude', 'Latitude', kind: TrKind.decimal, required: true, hint: 'e.g. 13.0827'),
        const TrField('longitude', 'Longitude', kind: TrKind.decimal, required: true, hint: 'e.g. 80.2707'),
        const TrField('geofence_radius_m', 'Arrival Radius (metres)', kind: TrKind.integer, hint: 'Blank uses the Transport Setup value'),
        const TrField('distance_from_school_km', 'Distance From School (km)', kind: TrKind.decimal),
        const TrField('landmark', 'Landmark', maxLength: 200, full: true),
        const TrField('address', 'Address', kind: TrKind.multiline, full: true),
        const TrField('is_active', 'Active', kind: TrKind.toggle),
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── data ───────────────────────────────────────────────────────────────────
  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        TransportService.list('route'),
        TransportService.list('stage'),
        TransportService.list('stop'),
      ]);
      if (!mounted) return;
      setState(() {
        _routes = r[0] as List<Map<String, dynamic>>;
        _stages = r[1] as List<Map<String, dynamic>>;
        _stops = r[2] as List<Map<String, dynamic>>;
        _loading = false;
        _error = null;
        _enrolled.clear(); // counted again when each route is opened
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  /// Loads [routeId]'s enrollments once, for the counts. A role that may not
  /// list them (or a failure) just shows no counts.
  void _wantCounts(int routeId) {
    if (_enrolled.containsKey(routeId) || _enrolling.contains(routeId)) return;
    _enrolling.add(routeId);
    TransportService.list('enrollment', filter: {'route_id': routeId}).then((rows) {
      if (!mounted) return;
      setState(() => _enrolled[routeId] = [for (final e in rows) if (trText(e['status']) == 'ACTIVE') e]);
    }, onError: (_) {}).whenComplete(() => _enrolling.remove(routeId));
  }

  /// The students who get on or off at any of [stopIds]; null while unknown.
  int? _studentsAt(int routeId, Set<int> stopIds) {
    final rows = _enrolled[routeId];
    if (rows == null) return null;
    return {
      for (final e in rows)
        if (stopIds.contains(trId(e['pickup_stop_id'])) || stopIds.contains(trId(e['drop_stop_id']))) trId(e['student_id']),
    }.length;
  }

  Future<void> _deleteStop(Map<String, dynamic> p) async {
    final id = trId(p['stop_id']), routeId = trId(p['route_id']);
    if (id == null) return;
    final ask = TrDelete('Delete stop ${trText(p['stop_name'])}?', 'The stop is switched off. A stop used by a student or schedule cannot be deleted.');
    if (!await trAskDelete(context, ask) || !mounted) return;
    try {
      await TransportService.remove('stop', id);
      if (!mounted) return;
      trSnack(context, 'Stop switched off.', AppColors.success);
      if (routeId != null) _open.add(routeId);
      await _load();
    } catch (e) {
      if (mounted) trSnack(context, AppText.couldNot('delete', friendlyError(e)), AppColors.error);
    }
  }

  List<Map<String, dynamic>> _stagesOf(int routeId) => [
        for (final s in _stages)
          if (trId(s['route_id']) == routeId) s
      ]..sort((a, b) => (trId(a['stage_no']) ?? 0).compareTo(trId(b['stage_no']) ?? 0));

  List<Map<String, dynamic>> _stopsOfRoute(int routeId) => [
        for (final p in _stops)
          if (trId(p['route_id']) == routeId) p
      ];

  List<Map<String, dynamic>> _stopsOfStage(int stageId) => [
        for (final p in _stops)
          if (trId(p['stage_id']) == stageId) p
      ]..sort((a, b) => (trId(a['stop_seq']) ?? 0).compareTo(trId(b['stop_seq']) ?? 0));

  // ── add / edit (and delete, in the edit dialog) ────────────────────────────
  /// [done] is said after a save; [deleted] after Delete (an edit with [delete]).
  Future<void> _form({
    required String entity,
    required String pk,
    required String title,
    required String icon,
    required List<TrField> fields,
    required String done,
    Map<String, dynamic> initial = const {},
    Map<String, dynamic> fixed = const {},
    int? routeId,
    TrDelete? delete,
    String deleted = '',
  }) async {
    final r = await showTrFormDialog(context,
        entity: entity, pk: pk, title: title, icon: icon, fields: fields, initial: initial, fixed: fixed, delete: delete);
    if (r == null || !mounted) return;
    trSnack(context, r.deleted == null ? done : deleted, AppColors.success);
    // keep the route the user is working in open
    _open.add(routeId ?? r.id);
    await _load();
  }

  void _addRoute() => _form(
        entity: 'route',
        pk: 'route_id',
        title: 'New route',
        icon: 'routing',
        fields: _routeFields,
        initial: const {'is_active': true},
        done: 'Route saved.',
      );

  void _editRoute(Map<String, dynamic> r) => _form(
        entity: 'route',
        pk: 'route_id',
        title: 'Edit route ${trText(r['route_code'])}',
        icon: 'routing',
        fields: _routeFields,
        initial: r,
        done: 'Route saved.',
        routeId: trId(r['route_id']),
        delete: TrDelete('Delete route ${trText(r['route_code'])}?',
            'The route is switched off and kept for past records. You can switch it on again by editing it.'),
        deleted: 'Route switched off.',
      );

  void _addStage(int routeId) => _form(
        entity: 'stage',
        pk: 'stage_id',
        title: 'Add fare stage',
        icon: 'layer',
        fields: _stageFields,
        initial: {'stage_no': _next(_stagesOf(routeId), 'stage_no'), 'is_active': true},
        fixed: {'route_id': routeId},
        done: 'Stage saved.',
        routeId: routeId,
      );

  void _editStage(Map<String, dynamic> s) {
    final routeId = trId(s['route_id'])!;
    _form(
      entity: 'stage',
      pk: 'stage_id',
      title: 'Edit stage ${trText(s['stage_no'])}',
      icon: 'layer',
      fields: _stageFields,
      initial: s,
      fixed: {'route_id': routeId},
      done: 'Stage saved.',
      routeId: routeId,
      delete: TrDelete('Delete stage ${trText(s['stage_no'])}?', 'The stage is switched off. A stage with active stops or students cannot be deleted.'),
      deleted: 'Stage switched off.',
    );
  }

  void _addStop(int routeId, int stageId) {
    _closedStages.remove(stageId); // show the stage the stop is going into
    _addStopForm(routeId, stageId);
  }

  void _addStopForm(int routeId, int stageId) => _form(
        entity: 'stop',
        pk: 'stop_id',
        title: 'Add pickup stop',
        icon: 'location',
        fields: _stopFields(routeId),
        // the order runs across the whole route, so the next number is route-wide
        initial: {'stage_id': stageId, 'stop_seq': _next(_stopsOfRoute(routeId), 'stop_seq'), 'is_active': true},
        fixed: {'route_id': routeId},
        done: 'Stop saved.',
        routeId: routeId,
      );

  void _editStop(Map<String, dynamic> p) {
    final routeId = trId(p['route_id'])!;
    _form(
      entity: 'stop',
      pk: 'stop_id',
      title: 'Edit stop',
      icon: 'location',
      fields: _stopFields(routeId),
      initial: p,
      fixed: {'route_id': routeId},
      done: 'Stop saved.',
      routeId: routeId,
      delete: TrDelete('Delete stop ${trText(p['stop_name'])}?', 'The stop is switched off. A stop used by a student or schedule cannot be deleted.'),
      deleted: 'Stop switched off.',
    );
  }

  // ── text helpers ───────────────────────────────────────────────────────────
  static String? _kmRange(Map<String, dynamic> s) {
    final from = trNumberText(s['from_km']), to = trNumberText(s['to_km']);
    if (from.isNotEmpty && to.isNotEmpty) return '$from–$to km';
    if (to.isNotEmpty) return 'up to $to km';
    if (from.isNotEmpty) return 'from $from km';
    return null;
  }

  bool _matches(Map<String, dynamic> route, String q) {
    final id = trId(route['route_id']);
    if ('${route['route_code']} ${route['route_name']}'.toLowerCase().contains(q)) return true;
    if (_stages.any((s) => trId(s['route_id']) == id && '${s['stage_name']}'.toLowerCase().contains(q))) return true;
    return _stops.any((p) => trId(p['route_id']) == id && '${p['stop_name']} ${p['stop_code']} ${p['landmark']}'.toLowerCase().contains(q));
  }

  // ── building blocks ────────────────────────────────────────────────────────
  Widget _menu(List<_Act> items, {String tooltip = 'More'}) => PopupMenuButton<int>(
        tooltip: tooltip,
        color: AppColors.card,
        position: PopupMenuPosition.under,
        onSelected: (i) => items[i].onTap(),
        itemBuilder: (_) => [
          for (var i = 0; i < items.length; i++)
            PopupMenuItem<int>(
              value: i,
              height: 38,
              child: Row(children: [
                AppIcon(items[i].icon, size: 16, color: items[i].danger ? AppColors.error : AppColors.ink2),
                const SizedBox(width: 10),
                Text(items[i].label, style: AppUI.body.copyWith(color: items[i].danger ? AppColors.error : AppColors.ink)),
              ]),
            ),
        ],
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.card,
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const AppIcon('more', size: 16, color: AppColors.ink2),
        ),
      );

  /// ▸ when closed, turning to ▾ when open.
  Widget _chevron(bool open, {double size = 20}) => AnimatedRotation(
        turns: open ? 0.25 : 0,
        duration: const Duration(milliseconds: 150),
        child: Icon(Icons.chevron_right_rounded, size: size, color: AppColors.ink2),
      );

  Widget _pill(String text, {required Color bg, required Color fg, double minWidth = 0}) => Container(
        constraints: BoxConstraints(minWidth: minWidth),
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 5.h),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text, maxLines: 1, style: AppUI.label.copyWith(color: fg)),
      );

  // ── tree ───────────────────────────────────────────────────────────────────
  Widget _routeTile(Map<String, dynamic> route, String q) {
    final id = trId(route['route_id'])!;
    final open = q.isNotEmpty || _open.contains(id);
    if (open) WidgetsBinding.instance.addPostFrameCallback((_) => _wantCounts(id));
    final stages = _stagesOf(id);
    final stopCount = _stopsOfRoute(id).length;
    final inactive = route['is_active'] == false;
    final ends = [trText(route['start_point']), trText(route['end_point'])].where((s) => s.isNotEmpty).join(' → ');
    final facts = [
      if (trNumberText(route['total_distance_km']).isNotEmpty) '${trNumberText(route['total_distance_km'])} km',
      if (trText(route['est_duration_min']).isNotEmpty) '${trText(route['est_duration_min'])} min',
    ].join(' · ');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: q.isNotEmpty ? null : () => setState(() => open ? _open.remove(id) : _open.add(id)),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Row(children: [
            _chevron(open),
            SizedBox(width: 12.w),
            _pill(trText(route['route_code']), bg: inactive ? AppColors.lineStrong : AppColors.primaryDark, fg: AppColors.onPrimary, minWidth: 84.w),
            SizedBox(width: 14.w),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(trText(route['route_name']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.body.copyWith(fontWeight: FontWeight.w700, color: inactive ? AppColors.ink3 : AppColors.ink)),
                SizedBox(height: 2.h),
                Text(
                  [_count(stages.length, 'stage'), _count(stopCount, 'pickup stop'), if (ends.isNotEmpty) ends].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppUI.muted,
                ),
              ]),
            ),
            if (inactive) ...[AppUI.chip('Inactive', AppStatus.neutral), SizedBox(width: 12.w)],
            if (facts.isNotEmpty) ...[
              const AppIcon('routing-2', size: 15, color: AppColors.ink3),
              SizedBox(width: 6.w),
              Text(facts, style: AppUI.muted),
              SizedBox(width: 14.w),
            ],
            _menu([
              (icon: 'edit-2', label: 'Edit route', onTap: () => _editRoute(route), danger: false),
              (icon: 'layer', label: 'Add stage', onTap: () => _addStage(id), danger: false),
            ]),
          ]),
        ),
      ),
      if (open)
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 14.h),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (stages.isEmpty)
              Padding(
                padding: EdgeInsets.only(left: 28.w, top: 4.h, bottom: 4.h),
                child: Text('No stages yet. Add the first stage, then its pickup stops.', style: AppUI.muted),
              )
            else
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(AppUI.cardRadius),
                  border: Border.all(color: AppColors.line),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < stages.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: AppColors.line),
                    _stageBlock(id, stages[i], q),
                  ],
                ]),
              ),
            Padding(
              padding: EdgeInsets.only(top: 10.h),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _addStage(id),
                  style: AppUI.secondary(context),
                  icon: AppIcon('layer', size: AppBtn.iconSize(context), color: AppColors.ink2),
                  label: const Text('Add stage'),
                ),
              ),
            ),
          ]),
        ),
    ]);
  }

  /// The timeline column: a dashed line down the middle and a ring at the
  /// row's middle. [first] starts the line at the ring; [end] (the "add" row)
  /// stops it there, with a hollow ring.
  // (a Column, not a LayoutBuilder: the rows size to their content)
  Widget _rail({bool first = false, bool end = false}) {
    Widget half(bool dashed) => Expanded(
          child: dashed ? const SizedBox(width: 4, child: CustomPaint(painter: _Dashes(AppColors.lineStrong))) : const SizedBox(width: 4),
        );
    return SizedBox(
      width: 36.w,
      child: Column(children: [
        half(!first),
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.card,
            border: Border.all(color: end ? AppColors.lineStrong : AppColors.primary, width: 2.5),
          ),
        ),
        half(!end),
      ]),
    );
  }

  /// "12 students", with the people icon.
  Widget _students(int? n) {
    if (n == null) return const SizedBox.shrink();
    return Tooltip(
      message: 'Active students who get on or off here',
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
        decoration: BoxDecoration(color: AppColors.tableHeader, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const AppIcon('people', size: 16, color: AppColors.ink2),
          SizedBox(width: 8.w),
          Text(_count(n, 'student'), style: AppUI.label.copyWith(fontWeight: FontWeight.w600, color: AppColors.ink)),
        ]),
      ),
    );
  }

  Widget _stageBlock(int routeId, Map<String, dynamic> s, String q) {
    final sid = trId(s['stage_id'])!;
    final stops = _stopsOfStage(sid);
    final inactive = s['is_active'] == false;
    final km = _kmRange(s);
    // a search keeps every stage open so matching stops stay visible
    final open = q.isNotEmpty || !_closedStages.contains(sid);
    final students = _studentsAt(routeId, {for (final p in stops) trId(p['stop_id'])!});
    final ink = inactive ? AppColors.ink3 : AppColors.ink;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Material(
        color: open ? AppColors.primaryTint : AppColors.tableHeader,
        child: InkWell(
          onTap: q.isNotEmpty ? null : () => setState(() => open ? _closedStages.add(sid) : _closedStages.remove(sid)),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
            child: Row(children: [
              SizedBox(
                width: 24,
                child: open
                    ? const Icon(Icons.expand_more_rounded, size: 22, color: AppColors.primaryDark)
                    : Center(
                        child: Transform.rotate(
                          angle: 0.785398, // a diamond
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                      ),
              ),
              SizedBox(width: 12.w),
              _pill('Stage ${trText(s['stage_no'])}',
                  bg: inactive ? AppColors.line : AppColors.primarySoft, fg: inactive ? AppColors.ink3 : AppColors.primaryText, minWidth: 74.w),
              SizedBox(width: 14.w),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: trText(s['stage_name']), style: AppUI.body.copyWith(fontWeight: FontWeight.w700, color: ink)),
                    if (km != null) TextSpan(text: '   •   $km', style: AppUI.muted),
                    TextSpan(text: '   •   ${_count(stops.length, 'stop')}', style: AppUI.muted),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (inactive) ...[AppUI.chip('Inactive', AppStatus.neutral), SizedBox(width: 10.w)],
              if (!open) ...[_students(students), SizedBox(width: 12.w)],
              _menu([
                (icon: 'edit-2', label: 'Edit stage', onTap: () => _editStage(s), danger: false),
                (icon: 'location-add', label: 'Add pickup stop', onTap: () => _addStop(routeId, sid), danger: false),
              ]),
              if (!open) ...[
                SizedBox(width: 8.w),
                const Icon(Icons.expand_more_rounded, size: 22, color: AppColors.ink2),
              ],
            ]),
          ),
        ),
      ),
      if (open) ...[
        for (var i = 0; i < stops.length; i++) ...[
          const Divider(height: 1, color: AppColors.line),
          _stopRow(stops[i], q, first: i == 0, routeId: routeId),
        ],
        const Divider(height: 1, color: AppColors.line),
        _addRow('Add pickup stop', () => _addStop(routeId, sid), first: stops.isEmpty),
      ],
    ]);
  }

  Widget _addRow(String label, VoidCallback onTap, {bool first = false}) => IntrinsicHeight(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.w),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: 44.w),
            first ? SizedBox(width: 36.w) : _rail(end: true),
            SizedBox(width: 12.w),
            Padding(
              padding: EdgeInsets.symmetric(vertical: 10.h),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: onTap,
                  style: AppUI.secondary(context),
                  icon: AppIcon('add', size: AppBtn.iconSize(context), color: AppColors.ink),
                  label: Text(label),
                ),
              ),
            ),
          ]),
        ),
      );

  Widget _stopRow(Map<String, dynamic> p, String q, {required bool first, required int routeId}) {
    final inactive = p['is_active'] == false;
    final hit = q.isNotEmpty && '${p['stop_name']} ${p['stop_code']} ${p['landmark']}'.toLowerCase().contains(q);
    final lat = trNumberText(p['latitude']), lon = trNumberText(p['longitude']);
    final detail = [
      trText(p['landmark']),
      trText(p['address']).replaceAll('\n', ', '),
      if (lat.isNotEmpty && lon.isNotEmpty) '$lat, $lon',
    ].where((x) => x.isNotEmpty).join(' · ');
    final code = trText(p['stop_code']);
    final ink = inactive ? AppColors.ink3 : AppColors.ink;

    return Container(
      color: hit ? AppColors.goldSoft : AppColors.card,
      padding: EdgeInsets.symmetric(horizontal: 16.w),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 44.w,
            child: Center(
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.tableHeader, shape: BoxShape.circle),
                child: Text('#${trText(p['stop_seq'])}', style: AppUI.label.copyWith(color: ink)),
              ),
            ),
          ),
          _rail(first: first),
          SizedBox(width: 12.w),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 10.h),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(trText(p['stop_name']),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.body.copyWith(fontWeight: FontWeight.w600, color: ink)),
                    ),
                    if (code.isNotEmpty) Text('  $code', style: AppUI.muted),
                    if (inactive) ...[SizedBox(width: 8.w), AppUI.chip('Inactive', AppStatus.neutral)],
                  ]),
                  if (detail.isNotEmpty) ...[
                    SizedBox(height: 2.h),
                    Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
                  ],
                ],
              ),
            ),
          ),
          Center(child: _students(_studentsAt(routeId, {trId(p['stop_id'])!}))),
          SizedBox(width: 16.w),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => _editStop(p),
              style: AppUI.secondary(context),
              icon: AppIcon('edit-2', size: AppBtn.iconSize(context), color: AppColors.ink),
              label: const Text('Edit'),
            ),
          ),
          if (!inactive) ...[
            SizedBox(width: 10.w),
            Center(
              child: OutlinedButton.icon(
                onPressed: () => _deleteStop(p),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.error, side: const BorderSide(color: AppColors.error)),
                icon: AppIcon('trash', size: AppBtn.iconSize(context), color: AppColors.error),
                label: const Text(AppText.delete),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Routes & Stops',
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
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? _routes
        : [
            for (final r in _routes)
              if (_matches(r, q)) r
          ];

    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 14.h),
          child: AppUI.cardHeader(
            icon: 'routing',
            title: 'Routes & Stops',
            subtitle: '${_count(_routes.length, 'route')} · ${_count(_stages.length, 'stage')} · ${_count(_stops.length, 'pickup stop')}',
            trailing: [
              SizedBox(
                width: 240.w,
                child: TrSearchField(hint: 'Route, stage or stop', onChanged: (v) => setState(() => _query = v)),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _load,
                icon: const AppIcon('refresh', size: 18, color: AppColors.ink2),
              ),
              ElevatedButton.icon(
                onPressed: _addRoute,
                style: AppUI.primary(context),
                icon: AppIcon('add', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
                label: const Text('New route'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: shown.isEmpty
              ? AppUI.empty(
                  title: _routes.isEmpty ? 'No routes yet' : 'No match for your search',
                  why: _routes.isEmpty ? 'Add your first route with New route, then its fare stages and stops.' : 'Try a different word.',
                  icon: 'routing',
                )
              : ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _routeTile(shown[i], q),
                ),
        ),
      ]),
    );
  }
}

/// A dashed vertical line down the middle of its box.
class _Dashes extends CustomPainter {
  final Color color;
  const _Dashes(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6;
    final x = size.width / 2;
    for (var y = 0.0; y < size.height; y += 7) {
      canvas.drawLine(Offset(x, y), Offset(x, (y + 4).clamp(0, size.height).toDouble()), paint);
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color;
}
