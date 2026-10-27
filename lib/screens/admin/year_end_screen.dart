import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';

/// Year End Process (school) -- the old product's "Year End Processing":
/// opened in the year that is ending, into the next registered year.
/// Preview (nothing written) -> untick detained students, confirm the next
/// year's receipt prefixes -> Run (once per year): students promoted, fee
/// demands raised from the students' advance demands, unpaid balances
/// carried as arrears, receipt series created, advances carried forward.
/// In the NEW year the same screen offers "Sync from <old year>" (the old
/// "After Year End Process Updation").
class YearEndScreen extends StatefulWidget {
  const YearEndScreen({super.key});

  @override
  State<YearEndScreen> createState() => _YearEndScreenState();
}

class _YearEndScreenState extends State<YearEndScreen> {
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _preview;
  String? _target;
  final Set<int> _detained = {};
  final Map<int, TextEditingController> _prefix = {}; // seq_id -> next year prefix
  String _filter = '';
  String? _filterSection;
  bool _loading = true, _busy = false;

  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static String _money(double v) {
    final s = v.toStringAsFixed(2);
    final dot = s.indexOf('.');
    return '${formatIndianNumber(int.parse(s.substring(0, dot)))}${s.substring(dot)}';
  }

  static String _dmy(dynamic v) {
    final x = DateTime.tryParse('${v ?? ''}');
    return x == null ? '-' : '${x.day.toString().padLeft(2, '0')}/${x.month.toString().padLeft(2, '0')}/${x.year}';
  }

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    for (final c in _prefix.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String msg, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: c));
  }

  Future<void> _loadStatus() async {
    setState(() => _loading = true);
    try {
      final res = await SupabaseService.client.rpc('year_end_status', params: {'p_token': SupabaseService.sessionToken});
      if (!mounted) return;
      final m = Map<String, dynamic>.from(res as Map);
      final next = [for (final y in (m['next_years'] as List? ?? const [])) '$y'];
      setState(() {
        _status = m;
        _target ??= next.isNotEmpty ? next.first : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Could not load. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  Future<void> _loadPreview() async {
    final t = _target;
    if (t == null) return;
    setState(() => _busy = true);
    try {
      final res = await SupabaseService.client.rpc('year_end_preview',
          params: {'p_token': SupabaseService.sessionToken, 'p_target': t, 'p_detained': _detained.toList()});
      if (!mounted) return;
      final m = Map<String, dynamic>.from(res as Map);
      for (final s in (m['sequences'] as List? ?? const [])) {
        final id = _id((s as Map)['seq_id']);
        if (id != null && !_prefix.containsKey(id)) _prefix[id] = TextEditingController(text: '${s['new_prefix'] ?? ''}');
      }
      setState(() => _preview = m);
    } catch (e) {
      _snack('Preview failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _students =>
      List<Map<String, dynamic>>.from((_preview?['students'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

  void _toggleDetain(Map<String, dynamic> s, bool promote) {
    final id = _id(s['stu_id']);
    if (id == null) return;
    setState(() => promote ? _detained.remove(id) : _detained.add(id));
    _loadPreview(); // the next section and the counts follow
  }

  Future<void> _run() async {
    final p = _preview;
    if (p == null) return;
    final c = Map<String, dynamic>.from(p['counts'] as Map? ?? const {});
    final carried = (_id(c['promote']) ?? 0) + (_id(c['detain']) ?? 0) + (_id(c['preadmission']) ?? 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Run Year End Process ${p['from']} → ${p['to']}?'),
        content: Text('$carried students go to ${p['to']} with their fees, arrears, receipt series and advances.\n\n'
            'This can be done ONLY ONCE for ${p['from']}. Later changes in ${p['from']} are brought over with '
            '"Sync from ${p['from']}" in ${p['to']}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: _solidBtn(), child: const Text('Run Year End')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await SupabaseService.client.rpc('run_year_end_process', params: {
        'p_token': SupabaseService.sessionToken,
        'p_target': _target,
        'p_detained': _detained.toList(),
        'p_prefixes': [
          for (final e in _prefix.entries) {'seq_id': e.key, 'prefix': e.value.text.trim()},
        ],
      });
      if (!mounted) return;
      await _showSummary('Year End Process done', Map<String, dynamic>.from(res as Map));
      _preview = null;
      await _loadStatus();
    } catch (e) {
      _snack('Year End Process failed -- nothing was changed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      final res = await SupabaseService.client.rpc('year_end_sync', params: {'p_token': SupabaseService.sessionToken});
      final m = Map<String, dynamic>.from(res as Map);
      final na = Map<String, dynamic>.from(m['new_arrears'] as Map? ?? const {});
      final nd = Map<String, dynamic>.from(m['new_demands'] as Map? ?? const {});
      final adv = Map<String, dynamic>.from(m['advances'] as Map? ?? const {});
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Synced from ${m['from']}'),
          content: Text([
            '${_id(m['arrears_changed']) ?? 0} arrear(s) changed by payments / cancellations made in ${m['from']}.',
            '${_id(na['count']) ?? 0} new arrear(s) carried (₹${_money(_num(na['amount']))}).',
            '${_id(nd['count']) ?? 0} new demand(s) from advance demands (₹${_money(_num(nd['amount']))}).',
            '${_id(adv['added']) ?? 0} advance line(s) added, ${_id(adv['updated']) ?? 0} changed, ${_id(adv['removed']) ?? 0} removed.',
            if ((_id(adv['reversed']) ?? 0) > 0) '${adv['reversed']} advance reconcile(s) undone -- the advance behind them was cancelled.',
            if ((_id(m['overpaid']) ?? 0) > 0)
              '${m['overpaid']} arrear(s) were paid in BOTH years -- check them for a refund.',
          ].join('\n')),
          actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), style: _solidBtn(), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      _snack('Sync failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showSummary(String title, Map<String, dynamic> m) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 520.w, child: _summaryGrid(m)),
          actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), style: _solidBtn(), child: const Text('OK'))],
        ),
      );

  // ── UI ──────────────────────────────────────────────────────────────────
  bool get _compact => MediaQuery.of(context).size.width <= 1366;
  BoxDecoration get _cardDec => AppUI.card();

  ButtonStyle _solidBtn() => AppUI.primary(context);

  ButtonStyle _outlineBtn() => AppUI.secondary(context);

  @override
  Widget build(BuildContext context) {
    if (!isSchool) {
      return AppUI.empty(title: 'Year End Process is used on the school database only.', icon: 'calendar-tick');
    }
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    final st = _status ?? const {};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(decoration: _cardDec, padding: EdgeInsets.all(AppUI.cardPad), child: _header(st)),
      SizedBox(height: AppUI.gap),
      if (st['prev_year'] != null) ...[_syncCard(st), SizedBox(height: AppUI.gap)],
      Expanded(child: _body(st)),
    ]);
  }

  Widget _header(Map st) {
    final next = [for (final y in (st['next_years'] as List? ?? const [])) '$y'];
    final done = st['done'] == true;
    return Row(children: [
      AppUI.iconTile('calendar-tick'),
      SizedBox(width: 12.w),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Year End Process', style: AppUI.cardTitle),
          SizedBox(height: 2.h),
          Text(
              done
                  ? '${st['year']} was closed into ${st['done_to']} on ${_dmy(st['done_at'])} by ${st['done_by'] ?? '-'}'
                  : 'Close ${st['year']} and open the next academic year -- students, fees, arrears, receipt series and advances',
              style: AppUI.muted),
        ]),
      ),
      if (!done && next.isNotEmpty) ...[
        Text('To year  ', style: AppUI.label),
        SizedBox(
          width: 150.w,
          child: DropdownButtonFormField<String>(
            initialValue: next.contains(_target) ? _target : null,
            isExpanded: true,
            decoration: AppUI.field(context, '', filled: _target != null),
            items: [for (final y in next) DropdownMenuItem(value: y, child: Text(y, style: AppUI.fieldText(context, filled: true)))],
            onChanged: _busy
                ? null
                : (v) => setState(() {
                      _target = v;
                      _preview = null;
                    }),
          ),
        ),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
          onPressed: _busy || _target == null ? null : _loadPreview,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.preview_outlined, size: 18),
          label: Text(_preview == null ? 'Preview' : 'Refresh Preview'),
          style: _solidBtn(),
        ),
      ],
    ]);
  }

  Widget _syncCard(Map st) => Container(
        decoration: _cardDec,
        padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h),
        child: Row(children: [
          const Icon(Icons.sync_alt_rounded, color: AppColors.accent),
          SizedBox(width: 12.w),
          Expanded(
            child: Text(
                '${st['year']} was opened from ${st['prev_year']} by Year End Process on ${_dmy(st['prev_done_at'])}. '
                'Payments, cancellations and advances entered in ${st['prev_year']} since then are brought here with Sync.',
                style: AppUI.body),
          ),
          SizedBox(width: 12.w),
          OutlinedButton.icon(
            onPressed: _busy ? null : _sync,
            icon: const Icon(Icons.sync, size: 18),
            label: Text('Sync from ${st['prev_year']}'),
            style: _outlineBtn(),
          ),
        ]),
      );

  Widget _body(Map st) {
    if (st['done'] == true) {
      final sum = Map<String, dynamic>.from(st['summary'] as Map? ?? const {});
      return Container(
        decoration: _cardDec,
        padding: EdgeInsets.all(AppUI.cardPad),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Year End Process done', style: AppUI.cardTitle),
            SizedBox(height: 4.h),
            Text('Work continues in ${st['done_to']}. Log in to ${st['done_to']} and use "Sync from ${st['year']}" there to bring over anything entered here later.',
                style: AppUI.muted),
            SizedBox(height: 16.h),
            _summaryGrid(sum),
          ]),
        ),
      );
    }
    final next = st['next_years'] as List? ?? const [];
    if (next.isEmpty) {
      return Container(
        decoration: _cardDec,
        alignment: Alignment.center,
        child: AppUI.empty(
          title: 'No next academic year registered',
          why: 'Register the next year with its licence key first; then run Year End Process here.',
          icon: 'calendar-1',
        ),
      );
    }
    final p = _preview;
    if (p == null) {
      return Container(
        decoration: _cardDec,
        alignment: Alignment.center,
        child: AppUI.empty(
          title: 'Choose the year and press Preview -- nothing is changed until you Run.',
          icon: 'calendar-tick',
        ),
      );
    }
    return Container(
      decoration: _cardDec,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ListView(padding: EdgeInsets.all(AppUI.cardPad), children: [
            _tiles(p),
            ..._warnings(p),
            SizedBox(height: AppUI.gap),
            _sequenceCard(p),
            SizedBox(height: AppUI.gap),
            _studentTable(),
          ]),
        ),
        Container(
          padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
          child: Row(children: [
            Icon(Icons.info_outline, size: 18.sp, color: AppColors.accent),
            SizedBox(width: 8.w),
            Expanded(
              child: Text('Untick a student to keep them in the same ${schoolTerm('class')} (detained). Year End runs only once for ${p['from']}.',
                  style: AppUI.muted),
            ),
            ElevatedButton.icon(
              onPressed: _busy || p['already_done'] != null ? null : _run,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: Text('Run Year End  ${p['from']} → ${p['to']}'),
              style: _solidBtn(),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _tile(String label, String value, {Color? color, String? sub}) => Container(
        width: _compact ? 150.w : 170.w,
        padding: EdgeInsets.all(16.w),
        decoration: AppUI.card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: AppUI.caps, maxLines: 1, overflow: TextOverflow.ellipsis),
          SizedBox(height: 4.h),
          Text(value, style: TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w800, color: color ?? AppColors.textPrimary)),
          if (sub != null) Text(sub, style: AppUI.muted),
        ]),
      );

  Widget _tiles(Map p) {
    final c = Map<String, dynamic>.from(p['counts'] as Map? ?? const {});
    final arr = Map<String, dynamic>.from(p['arrears'] as Map? ?? const {});
    return Wrap(spacing: 12.w, runSpacing: 12.h, children: [
      _tile('Promoted', '${c['promote'] ?? 0}', color: AppColors.success),
      _tile('Detained', '${c['detain'] ?? 0}', color: AppColors.warning),
      _tile('Pre-admissions', '${c['preadmission'] ?? 0}'),
      _tile('Passing out', '${c['passout'] ?? 0}', color: AppColors.textSecondary),
      _tile('No next ${schoolTerm('class')}', '${c['no_section'] ?? 0}', color: AppColors.error, sub: 'not carried'),
      _tile('Arrears', '₹${_money(_num(arr['amount']))}', color: AppColors.warning, sub: '${arr['students'] ?? 0} students'),
      _tile("Next year's demands", '₹${_money(_num(p['advance_demand_amount']))}', sub: "${p['advance_demands'] ?? 0} from advance demands"),
      _tile('Advance receipts', '${p['advance_receipts'] ?? 0}', sub: 'carried for reconcile'),
    ]);
  }

  List<Widget> _warnings(Map p) {
    final c = Map<String, dynamic>.from(p['counts'] as Map? ?? const {});
    final left = Map<String, dynamic>.from(p['left_dues'] as Map? ?? const {});
    final tgt = Map<String, dynamic>.from(p['target_now'] as Map? ?? const {});
    Widget warn(String t, Color col) => Container(
          margin: EdgeInsets.only(top: 12.h),
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          decoration: BoxDecoration(
              color: col == AppColors.error ? AppColors.errorBg : AppColors.warningBg,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: col.withValues(alpha: 0.3))),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, color: col, size: 20),
            SizedBox(width: 10.w),
            Expanded(child: Text(t, style: AppUI.body.copyWith(fontSize: 13.sp, fontWeight: FontWeight.w600))),
          ]),
        );
    return [
      if (p['already_done'] != null) warn('Year End Process for ${p['from']} was already done (to ${p['already_done']}).', AppColors.error),
      if ((_id(c['no_section']) ?? 0) > 0)
        warn(
            '${c['no_section']} students have no ${schoolTerm('section')} in the next ${schoolTerm('standard')} and will NOT be carried. '
            'Add the ${schoolTerm('sections')} (e.g. "III A") in the master, or set Section Matching, then Refresh Preview.',
            AppColors.error),
      if ((_id(left['students']) ?? 0) > 0)
        warn('${left['students']} students who are not carried still owe ₹${_money(_num(left['amount']))} -- collect it in ${p['from']}.', AppColors.warning),
      if ((_id(tgt['students']) ?? 0) > 0 || (_id(tgt['demands']) ?? 0) > 0)
        warn('${p['to']} already has ${tgt['students']} students and ${tgt['demands']} demands -- they are kept; students already there are skipped.',
            AppColors.warning),
    ];
  }

  Widget _sequenceCard(Map p) {
    final seqs = (p['sequences'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Text('${p['to']} receipt & number series', style: AppUI.cardTitle),
        ),
        for (final s in seqs)
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
            child: Row(children: [
              Expanded(flex: 3, child: Text('${s['seqname'] ?? s['actname']}', style: AppUI.cell.copyWith(fontWeight: FontWeight.w600))),
              Expanded(flex: 2, child: Text('now ${s['prefix']}', style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
              Expanded(
                flex: 3,
                child: s['continues'] == true
                    ? Text('continues (${s['prefix']} ${s['curno']} →)', style: AppUI.cell.copyWith(color: AppColors.textSecondary))
                    : TextField(
                        controller: _prefix[_id(s['seq_id'])],
                        style: AppUI.fieldText(context, filled: true),
                        decoration: AppUI.field(context, '', label: 'next year prefix', filled: true, dense: true),
                      ),
              ),
            ]),
          ),
      ]),
    );
  }

  static const _actionLabel = {
    'PROMOTE': 'Promote',
    'DETAIN': 'Detained',
    'PREADMISSION': 'Pre-admission',
    'PASSOUT': 'Passing out',
    'NO_SECTION': 'No next section',
    'EXISTS': 'Already there',
  };

  AppStatus _actionStatus(String a) => switch (a) {
        'PROMOTE' => AppStatus.success,
        'DETAIN' => AppStatus.warning,
        'NO_SECTION' => AppStatus.danger,
        'PASSOUT' || 'EXISTS' => AppStatus.neutral,
        _ => AppStatus.info,
      };

  Widget _studentTable() {
    final all = _students;
    final sections = {for (final s in all) '${s['cur_section'] ?? ''}'}.toList()..sort();
    final q = _filter.trim().toLowerCase();
    final rows = all
        .where((s) =>
            (_filterSection == null || s['cur_section'] == _filterSection) &&
            (q.isEmpty || '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q)))
        .toList();
    Widget h(String t, int f) => AppUI.th(t, flex: f);
    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Row(children: [
            Text('Students (${rows.length} of ${all.length})', style: AppUI.cardTitle),
            const Spacer(),
            SizedBox(
              width: 160.w,
              child: DropdownButtonFormField<String?>(
                initialValue: _filterSection,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: _filterSection != null),
                decoration: AppUI.field(context, schoolTerm('All classes'), filled: _filterSection != null),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(schoolTerm('All classes'))),
                  for (final s in sections) DropdownMenuItem<String?>(value: s, child: Text(s)),
                ],
                onChanged: (v) => setState(() => _filterSection = v),
              ),
            ),
            SizedBox(width: 10.w),
            SizedBox(
              width: 220.w,
              child: TextField(
                onChanged: (v) => setState(() => _filter = v),
                style: AppUI.fieldText(context),
                decoration: AppUI.field(context, 'Adm No / Name', leadingIcon: 'search-normal', filled: _filter.isNotEmpty),
              ),
            ),
          ]),
        ),
        Container(
          decoration: AppUI.tableHeadBar,
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
          child: Row(children: [
            SizedBox(width: 96.w, child: Text('PROMOTE', style: AppUI.tableHead)),
            h(schoolTerm('Roll No'), 2),
            h('Student', 4),
            h('Now', 2),
            h('Next year', 2),
            h('Action', 2),
            AppUI.th('DUES (₹)', flex: 2, align: TextAlign.right),
          ]),
        ),
        for (final s in rows)
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 4.h),
            child: Row(children: [
              SizedBox(
                width: 96.w,
                child: Align(
                  alignment: Alignment.centerLeft,
                  // A pre-admission is CARRIED (already placed in next year's
                  // section): ticked and locked, not an empty box that reads
                  // as "left behind".
                  child: Tooltip(
                    message: s['action'] == 'PREADMISSION'
                        ? 'Pre-admission: joins ${s['next_section'] ?? '-'} in ${_preview?['to'] ?? 'next year'} as a regular student'
                        : '',
                    child: Checkbox(
                      value: s['action'] == 'PROMOTE' || s['action'] == 'PREADMISSION',
                      activeColor: s['action'] == 'PREADMISSION' ? AppColors.accent.withValues(alpha: 0.55) : AppColors.accent,
                      fillColor: s['action'] == 'PREADMISSION'
                          ? WidgetStatePropertyAll(AppColors.accent.withValues(alpha: 0.55))
                          : null,
                      onChanged: _busy || !(s['action'] == 'PROMOTE' || s['action'] == 'DETAIN') ? null : (v) => _toggleDetain(s, v == true),
                    ),
                  ),
                ),
              ),
              Expanded(flex: 2, child: Text('${s['stuadmno']}', style: AppUI.cell)),
              Expanded(flex: 4, child: Text('${s['stuname']}', overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(fontWeight: FontWeight.w600))),
              Expanded(flex: 2, child: Text('${s['cur_section'] ?? '-'}', style: AppUI.cell)),
              Expanded(
                  flex: 2,
                  child: Text('${s['next_section'] ?? '-'}',
                      style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: s['next_section'] == null ? AppColors.textLight : AppColors.accent))),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AppUI.chip(_actionLabel['${s['action']}'] ?? '${s['action']}', _actionStatus('${s['action']}')),
                ),
              ),
              Expanded(
                  flex: 2,
                  child: Text(_num(s['dues']) > 0 ? _money(_num(s['dues'])) : '—',
                      textAlign: TextAlign.right,
                      style: AppUI.money.copyWith(color: _num(s['dues']) > 0 ? AppColors.warning : AppColors.textLight))),
            ]),
          ),
      ]),
    );
  }

  Widget _summaryGrid(Map<String, dynamic> m) {
    final arr = Map<String, dynamic>.from(m['arrears'] as Map? ?? const {});
    final adv = Map<String, dynamic>.from(m['advances'] as Map? ?? const {});
    final items = <(String, String)>[
      ('Students carried', '${m['students'] ?? 0}'),
      ('Promoted / detained / pre-admission', '${m['promoted'] ?? 0} / ${m['detained'] ?? 0} / ${m['preadmissions'] ?? 0}'),
      ('Passed out', '${m['passed_out'] ?? 0}'),
      ('Not carried (no next section)', '${m['no_section'] ?? 0}'),
      ("Demands from advance demands", '${m['advance_demand_changes'] ?? 0}'),
      ("Demands from the new year's Section Fee Demand", '${m['demands'] ?? 0}'),
      ('Arrears carried', '${arr['count'] ?? 0}  (₹${_money(_num(arr['amount']))})'),
      ('Advance lines carried', '${adv['added'] ?? 0}'),
      ('Receipt / number series created', '${m['sequences'] ?? 0}'),
    ];
    return Column(children: [
      for (final it in items)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 5.h),
          child: Row(children: [
            Expanded(child: Text(it.$1, style: AppUI.body.copyWith(color: AppColors.textSecondary))),
            Text(it.$2, textAlign: TextAlign.right, style: AppUI.money),
          ]),
        ),
    ]);
  }
}
