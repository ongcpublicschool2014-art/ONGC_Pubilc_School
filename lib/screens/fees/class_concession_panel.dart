import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/class_sort.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';

/// Section-wise concession (school), as the old product's Cons_FeeInfo +
/// sp_concessprocess: for a section and a concession CATEGORY set the
/// concession per fee line once (rupees, or a percent of each student's own
/// fee), then Apply -- every student of that section whose category matches
/// gets their own concession voucher (CON0001 ...), exactly as a
/// single-student concession would make it. Laid out like the Single Student
/// view: numbered step cards, KPI cards, bordered tables, a footer bar.
class ClassConcessionPanel extends StatefulWidget {
  const ClassConcessionPanel({super.key});

  @override
  State<ClassConcessionPanel> createState() => _ClassConcessionPanelState();
}

class _Rate {
  final Map<String, dynamic> line; // term, feetype, fee_id, sem_id, feeamount
  final TextEditingController amt = TextEditingController();
  int nob = 3, bgb = 3, dhb = 3;
  String type = 'A'; // 'A' rupees, 'P' percent of each student's own fee
  _Rate(this.line);
  bool get arrear => '${line['seqtype']}' == 'ARREAR';
  double get value => double.tryParse(amt.text.trim()) ?? 0;
  double get rupees => type == 'P' ? ((line['feeamount'] as num?)?.toDouble() ?? 0) * value / 100 : value;
}

class _ClassConcessionPanelState extends State<ClassConcessionPanel> {
  List<Map<String, dynamic>> _classes = [], _courses = [], _cats = [];
  int? _cour, _cla, _con;
  final List<_Rate> _rates = [];
  List<Map<String, dynamic>> _preview = [];
  int _withCat = 0, _inSection = 0;
  bool _loading = true, _busy = false, _loaded = false;

  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static String _money(double v) {
    final s = v.toStringAsFixed(2);
    final dot = s.indexOf('.');
    return '${formatIndianNumber(int.parse(s.substring(0, dot)))}${s.substring(dot)}';
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  bool get _hasRates => _rates.any((r) => r.value > 0);
  List<Map<String, dynamic>> get _todo => _preview.where((p) => p['status'] == 'APPLY').toList();
  double get _todoTotal => _todo.fold<double>(0, (t, p) => t + _num(p['apply']));
  String get _catName => '${_cats.firstWhere((c) => _id(c['con_id']) == _con, orElse: () => const {})['condesc'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _loadMasters();
  }

  @override
  void dispose() {
    for (final r in _rates) {
      r.amt.dispose();
    }
    super.dispose();
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  // ── data ────────────────────────────────────────────────────────────────
  Future<void> _loadMasters() async {
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('concessioncategory').select('con_id, condesc, ordid').eq('ins_id', _insId).eq('activestatus', 1),
      ]);
      if (!mounted) return;
      setState(() {
        _classes = List<Map<String, dynamic>>.from((r[0] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => classCompare('${a['claname']}', '${b['claname']}'));
        _courses = List<Map<String, dynamic>>.from((r[1] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => (_id(a['ordid']) ?? 999).compareTo(_id(b['ordid']) ?? 999));
        _cats = List<Map<String, dynamic>>.from((r[2] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => (_id(a['ordid']) ?? 999).compareTo(_id(b['ordid']) ?? 999));
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Could not load. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  Future<void> _load() async {
    if (_cla == null || _con == null) return;
    setState(() {
      _busy = true;
      _preview = [];
    });
    try {
      final res = await SupabaseService.client.rpc('class_concession_get',
          params: {'p_token': SupabaseService.sessionToken, 'p_cla_id': _cla, 'p_con_id': _con});
      final m = Map<String, dynamic>.from(res as Map);
      final saved = [for (final x in (m['rates'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
      for (final r in _rates) {
        r.amt.dispose();
      }
      _rates.clear();
      for (final x in (m['fee_lines'] as List? ?? const [])) {
        final line = Map<String, dynamic>.from(x as Map);
        final rate = _Rate(line);
        final s = saved.where((v) =>
            ('${v['seqtype'] ?? 'REGULAR'}' == 'ARREAR') == rate.arrear &&
            '${v['term']}'.toUpperCase() == '${line['term']}'.toUpperCase() &&
            '${v['feetype']}'.toUpperCase() == '${line['feetype']}'.toUpperCase());
        if (s.isNotEmpty) {
          final a = _num(s.first['amount']);
          rate.amt.text = a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
          rate.type = '${s.first['type'] ?? 'A'}' == 'P' ? 'P' : 'A';
          rate.nob = _id(s.first['nob']) ?? 3;
          rate.bgb = _id(s.first['bgb']) ?? 3;
          rate.dhb = _id(s.first['dhb']) ?? 3;
        }
        _rates.add(rate);
      }
      setState(() {
        _withCat = _id(m['students_with_category']) ?? 0;
        _inSection = _id(m['students_in_section']) ?? 0;
        _loaded = true;
      });
    } catch (e) {
      _snack('Could not load. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _saveRates({bool quiet = false}) async {
    if (_rates.any((r) => r.type == 'P' && r.value > 100)) {
      _snack('A percentage concession cannot be more than 100%.', AppColors.error);
      return false;
    }
    setState(() => _busy = true);
    try {
      await SupabaseService.client.rpc('save_class_concession', params: {
        'p_token': SupabaseService.sessionToken,
        'p_cla_id': _cla,
        'p_con_id': _con,
        'p_lines': [
          for (final r in _rates)
            if (r.value > 0)
              {
                'seqtype': r.arrear ? 'ARREAR' : 'REGULAR',
                'term': r.line['term'],
                'feetype': r.line['feetype'],
                'fee_id': r.line['fee_id'],
                'sem_id': r.line['sem_id'],
                'amount': r.value,
                'type': r.type,
                'nob': r.nob,
                'bgb': r.bgb,
                'dhb': r.dhb,
              },
        ],
      });
      if (!quiet) _snack('Concession rates saved for this ${schoolTerm('class')} and category.', AppColors.success);
      return true;
    } catch (e) {
      _snack('Save failed. ${friendlyError(e)}', AppColors.error);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doPreview() async {
    if (!_hasRates) {
      _snack('Enter a concession for at least one fee line, then Preview.', AppColors.warning);
      return;
    }
    if (!await _saveRates(quiet: true)) return;
    setState(() => _busy = true);
    try {
      final res = await SupabaseService.client.rpc('class_concession_preview',
          params: {'p_token': SupabaseService.sessionToken, 'p_cla_id': _cla, 'p_con_id': _con});
      setState(() => _preview = [for (final x in (res as List)) Map<String, dynamic>.from(x as Map)]);
      if (_preview.isEmpty) {
        _snack(
            _withCat == 0
                ? 'No student of this ${schoolTerm('class')} has this concession category.'
                : 'No student of this category fits these lines -- check the New/Old, Boy/Girl and Day/Hostel choices.',
            AppColors.warning);
      }
    } catch (e) {
      _snack('Preview failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static int _count(Map<String, dynamic> m, String type) => [
        for (final x in (m['items'] as List? ?? const []))
          if ((x as Map)['error'] == null && '${x['seqtype'] ?? 'REGULAR'}' == type) x,
      ].length;

  Future<void> _apply() async {
    final todo = _todo;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply concession'),
        content: Text('Give ${todo.length} student(s) of category $_catName a concession of ₹${_money(_todoTotal)} in total?\n\n'
            'Each student gets their own voucher -- CON... for the regular fees, AC... for arrears -- the same as a single-student concession.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: _solidBtn(), child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await SupabaseService.client.rpc('apply_class_concession',
          params: {'p_token': SupabaseService.sessionToken, 'p_cla_id': _cla, 'p_con_id': _con});
      final m = Map<String, dynamic>.from(res as Map);
      final fails = [for (final x in (m['items'] as List? ?? const [])) if ((x as Map)['error'] != null) x];
      _snack(
          '${_count(m, 'REGULAR')} concession (CON) + ${_count(m, 'ARREAR')} arrear concession (AC) voucher(s) made, ₹${_money(_num(m['total']))}'
          '${fails.isEmpty ? '' : ' -- ${fails.length} failed: ${fails.map((f) => '${f['stuadmno']}: ${f['error']}').join('; ')}'}',
          fails.isEmpty ? AppColors.success : AppColors.warning);
      await _doPreview();
    } catch (e) {
      _snack('Apply failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── style (same as the Single Student view) ──────────────────────────────
  InputDecoration _fieldDec(String hint) => AppUI.field(context, hint);

  TextStyle _fieldText() => AppUI.fieldText(context);

  ButtonStyle _solidBtn() => AppUI.primary(context);

  ButtonStyle _outlineBtn() => AppUI.secondary(context);

  Widget _stepBadge(int n, String title) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 20.w,
          height: 20.w,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
          child: Text('$n', style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        SizedBox(width: 8.w),
        Text(title, style: AppUI.label),
      ]);

  Widget _filterCol(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        AppUI.fieldLabel(label),
        child,
      ]);

  Widget _drop<T>(String hint, T? value, List<(T, String)> items, ValueChanged<T?> onChanged) => DropdownButtonFormField<T>(
        key: ValueKey('$hint-$value-${items.length}'),
        initialValue: items.any((e) => e.$1 == value) ? value : null,
        isExpanded: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        style: _fieldText(),
        decoration: _fieldDec(hint),
        items: [for (final e in items) DropdownMenuItem(value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis))],
        onChanged: _busy ? null : onChanged,
      );

  Widget _kpiCard({required String icon, required Color tint, required String value, required String label, String? sub}) =>
      AppUI.kpi(icon: icon, label: label, value: value, sub: sub, tint: tint);

  /// A titled, bordered table card (title bar, grey header row).
  Widget _tableCard({required String icon, required String title, String? trailing, required Widget head, required List<Widget> rows, Widget? total}) =>
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: AppUI.card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h),
            child: AppUI.cardHeader(
              icon: icon,
              title: title,
              trailing: [
                if (trailing != null) Flexible(child: Text(trailing, style: AppUI.muted, textAlign: TextAlign.right)),
              ],
            ),
          ),
          Container(
            decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(top: BorderSide(color: AppColors.divider))),
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 11.h),
            child: head,
          ),
          ...rows,
          if (total != null)
            Container(
              decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(top: BorderSide(color: AppColors.divider))),
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 11.h),
              child: total,
            ),
        ]),
      );

  Widget _h(String t, int flex, {TextAlign align = TextAlign.left}) => AppUI.th(t, flex: flex, align: align);

  Widget _hw(String t, double w, {TextAlign align = TextAlign.left}) => SizedBox(
        width: w,
        child: Text(t.toUpperCase(), textAlign: align, style: AppUI.tableHead),
      );

  Widget _flag(int v, ValueChanged<int> on, List<String> names) => SizedBox(
        width: 120.w,
        child: DropdownButtonFormField<int>(
          initialValue: v,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          style: _fieldText(),
          decoration: _fieldDec(''),
          items: [
            const DropdownMenuItem(value: 3, child: Text('Both')),
            DropdownMenuItem(value: 1, child: Text(names[0])),
            DropdownMenuItem(value: 2, child: Text(names[1])),
          ],
          onChanged: _busy ? null : (x) => setState(() => on(x ?? 3)),
        ),
      );

  // ── UI ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 12.h),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _selectCard(),
            SizedBox(height: AppUI.gap),
            if (!_loaded)
              _hint()
            else ...[
              _kpis(),
              SizedBox(height: AppUI.gap),
              _ratesTable(),
              if (_preview.isNotEmpty) ...[SizedBox(height: AppUI.gap), _studentsTable()],
            ],
          ]),
        ),
      ),
      if (_loaded) _footer(),
    ]);
  }

  Widget _selectCard() {
    final sections = [
      for (final c in _classes)
        if (_cour == null || _id(c['cour_id']) == _cour) (_id(c['cla_id'])!, '${c['claname']}'),
    ];
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 5,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _stepBadge(1, schoolTerm('Select Class')),
            SizedBox(height: 10.h),
            Row(children: [
              Expanded(
                child: _filterCol(schoolTerm('Course'), _drop<int>(schoolTerm('Select Course'), _cour, [for (final c in _courses) (_id(c['cour_id'])!, '${c['courname']}')], (v) => setState(() {
                      _cour = v;
                      _cla = null;
                      _loaded = false;
                      _preview = [];
                    }))),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: _filterCol(schoolTerm('Class'), _drop<int>(schoolTerm('Select Class'), _cla, sections, (v) {
                  setState(() => _cla = v);
                  _load();
                })),
              ),
            ]),
          ]),
        ),
        SizedBox(width: 18.w),
        Expanded(
          flex: 4,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _stepBadge(2, 'Concession Category'),
            SizedBox(height: 10.h),
            _filterCol('Category', _drop<int>('Select Category', _con, [for (final c in _cats) (_id(c['con_id'])!, '${c['condesc']}')], (v) {
              setState(() => _con = v);
              _load();
            })),
          ]),
        ),
      ]),
    );
  }

  Widget _hint() => Container(
        padding: EdgeInsets.symmetric(vertical: 36.h),
        decoration: AppUI.card(),
        child: AppUI.empty(
          icon: 'discount-shape',
          title: schoolTerm('Choose the class and the concession category'),
          why: "Each student's category is set on the student (Admission / Student Details).",
        ),
      );

  Widget _kpis() {
    final perStudent = _rates.fold<double>(0, (t, r) => t + r.rupees);
    return Row(children: [
      Expanded(child: _kpiCard(icon: 'people', tint: AppColors.primary, value: '$_inSection', label: 'Students in ${schoolTerm('class')}')),
      SizedBox(width: 12.w),
      Expanded(child: _kpiCard(icon: 'profile-tick', tint: AppColors.demand, value: '$_withCat', label: 'With category', sub: _catName)),
      SizedBox(width: 12.w),
      Expanded(child: _kpiCard(icon: 'discount-shape', tint: AppColors.success, value: '₹${_money(perStudent)}', label: 'Concession per student', sub: 'before New/Old etc.')),
      SizedBox(width: 12.w),
      Expanded(
        child: _kpiCard(
            icon: 'wallet-money',
            tint: AppColors.warning,
            value: _preview.isEmpty ? '—' : '₹${_money(_todoTotal)}',
            label: 'To apply',
            sub: _preview.isEmpty ? 'press Preview' : '${_todo.length} student(s)'),
      ),
    ]);
  }

  Widget _ratesTable() => _tableCard(
        icon: 'receipt-discount',
        title: 'Concession per fee line',
        trailing: "₹ = fixed amount  ·  % = of each student's fee  ·  arrear lines get their own AC voucher",
        head: Row(children: [
          _h(schoolTerm('Term'), 2),
          _h('Fee type', 3),
          _h('Fee (₹)', 2, align: TextAlign.right),
          SizedBox(width: 18.w),
          _hw('Concession', 220.w),
          SizedBox(width: 10.w),
          _hw('New / Old', 120.w),
          SizedBox(width: 8.w),
          _hw('Boy / Girl', 120.w),
          SizedBox(width: 8.w),
          _hw('Day / Hostel', 120.w),
        ]),
        rows: [
          if (_rates.isEmpty)
            Padding(
              padding: EdgeInsets.all(16.w),
              child: Text('This ${schoolTerm('class')} has no fee lines yet (Section Fee Demand / demands).',
                  style: AppUI.muted),
            ),
          for (var i = 0; i < _rates.length; i++) _rateRow(_rates[i], i),
        ],
      );

  Widget _rateRow(_Rate r, int i) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
        child: Row(children: [
          Expanded(
            flex: 2,
            child: Row(children: [
              Flexible(child: Text('${r.line['term']}', overflow: TextOverflow.ellipsis, style: AppUI.cell)),
              if (r.arrear) ...[
                SizedBox(width: 6.w),
                Tooltip(
                  message: 'Arrear from ${r.line['feeyear'] ?? 'a previous year'} -- given on its own AC voucher',
                  child: AppUI.chip('ARREAR ${r.line['feeyear'] ?? ''}'.trim(), AppStatus.warning),
                ),
              ],
            ]),
          ),
          Expanded(flex: 3, child: Text('${r.line['feetype']}', style: AppUI.cell.copyWith(fontWeight: FontWeight.w600))),
          Expanded(flex: 2, child: Text(_money(_num(r.line['feeamount'])), textAlign: TextAlign.right, style: AppUI.money)),
          SizedBox(width: 18.w),
          SizedBox(
            width: 220.w,
            child: Row(children: [
              SizedBox(
                width: 64.w,
                child: DropdownButtonFormField<String>(
                  initialValue: r.type,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  style: _fieldText(),
                  decoration: _fieldDec(''),
                  items: const [DropdownMenuItem(value: 'A', child: Text('₹')), DropdownMenuItem(value: 'P', child: Text('%'))],
                  onChanged: _busy ? null : (v) => setState(() => r.type = v ?? 'A'),
                ),
              ),
              SizedBox(width: 6.w),
              Expanded(
                child: TextField(
                  controller: r.amt,
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                  textAlign: TextAlign.right,
                  style: AppUI.fieldText(context, filled: true),
                  onChanged: (_) => setState(() {}),
                  decoration: _fieldDec('0').copyWith(
                    suffixText: r.type == 'P' ? '%' : null,
                    helperText: r.type == 'P' && r.value > 0 ? '= ₹${_money(r.rupees)}' : null,
                    helperStyle: TextStyle(fontSize: 10.sp, color: AppColors.textLight, height: 0.8),
                  ),
                ),
              ),
            ]),
          ),
          SizedBox(width: 10.w),
          _flag(r.nob, (x) => r.nob = x, const ['New', 'Old']),
          SizedBox(width: 8.w),
          _flag(r.bgb, (x) => r.bgb = x, const ['Boy', 'Girl']),
          SizedBox(width: 8.w),
          _flag(r.dhb, (x) => r.dhb = x, const ['Dayscholar', 'Hostler']),
        ]),
      );

  Widget _studentsTable() {
    final willApply = _todo.length;
    return _tableCard(
      icon: 'people',
      title: 'Students (${_preview.length})',
      trailing: '$willApply of ${_preview.length} will get a voucher',
      head: Row(children: [
        _h(schoolTerm('Roll No'), 2),
        _h('Student', 4),
        _h('Concession lines', 6),
        _h('Concession (₹)', 2, align: TextAlign.right),
        _h('Status', 2, align: TextAlign.right),
      ]),
      rows: [
        for (var i = 0; i < _preview.length; i++) _studentRow(_preview[i], i),
      ],
      total: Row(children: [
        _h('Total', 12),
        Expanded(
          flex: 2,
          child: Text(_money(_todoTotal), textAlign: TextAlign.right, style: AppUI.money.copyWith(fontWeight: FontWeight.w800, color: AppColors.primary)),
        ),
        const Expanded(flex: 2, child: SizedBox()),
      ]),
    );
  }

  Widget _studentRow(Map<String, dynamic> p, int i) {
    final (label, status) = switch ('${p['status']}') {
      'APPLY' => ('Will apply', AppStatus.success),
      'DONE' => ('Already given', AppStatus.neutral),
      'NOT_ENOUGH' => ('Fee already paid', AppStatus.warning),
      _ => ('No demand', AppStatus.neutral),
    };
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
      child: Row(children: [
        Expanded(flex: 2, child: Text('${p['stuadmno']}', style: AppUI.cell)),
        Expanded(flex: 4, child: Text('${p['stuname']}', overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(fontWeight: FontWeight.w600))),
        Expanded(
          flex: 6,
          child: Text(
            [for (final l in (p['lines'] as List? ?? const [])) '${(l as Map)['seqtype'] == 'ARREAR' ? 'Arrear ' : ''}${l['term']} ${l['feetype']} ₹${_money(_num(l['new']))}'].join('  ·  '),
            overflow: TextOverflow.ellipsis,
            style: AppUI.muted,
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(_num(p['apply']) > 0 ? _money(_num(p['apply'])) : '—', textAlign: TextAlign.right, style: AppUI.money),
        ),
        Expanded(
          flex: 2,
          child: Align(
            alignment: Alignment.centerRight,
            child: AppUI.chip(label, status),
          ),
        ),
      ]),
    );
  }

  Widget _footer() => Container(
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.cardBorder))),
        child: Row(children: [
          Icon(Icons.info_outline, size: 18.sp, color: AppColors.primary),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              'Save Rates keeps them for this ${schoolTerm('class')} and category -- apply again later for a late admission. '
              'Students already given it are skipped.',
              style: AppUI.muted,
            ),
          ),
          SizedBox(width: 12.w),
          OutlinedButton.icon(
            onPressed: _busy || !_hasRates ? null : () => _saveRates(),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save Rates'),
            style: _outlineBtn(),
          ),
          SizedBox(width: 10.w),
          OutlinedButton.icon(
            onPressed: _busy ? null : _doPreview,
            icon: const Icon(Icons.preview_outlined, size: 18),
            label: const Text('Preview Students'),
            style: _outlineBtn(),
          ),
          SizedBox(width: 10.w),
          ElevatedButton.icon(
            onPressed: _busy || _todo.isEmpty ? null : _apply,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.done_all, size: 18),
            label: Text(_todo.isEmpty ? 'Apply Concession' : 'Apply to ${_todo.length}  ·  ₹${_money(_todoTotal)}'),
            style: _solidBtn(),
          ),
        ]),
      );
}
