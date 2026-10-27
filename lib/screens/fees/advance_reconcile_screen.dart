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
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';

/// Advance Adjustment on a SCHOOL ("Advance Reconcile"): the advance fees a
/// student paid LAST year (Advance Fee Collection) are settled against THIS
/// year's fee demands.
///
/// Pick a section -> last year's open advance receipts of its students ->
/// the receipt's lines (term, fee type, advance, reconciled so far) beside the
/// student's open demands this year. Auto Reconcile matches the same term +
/// fee type first; Reconcile pays the demands with an 'Advance Adjustment'
/// receipt (reconcile_previous_advance) and draws the old advance down.
/// Reverse (under Reconciled) undoes it.
class AdvanceReconcileScreen extends StatefulWidget {
  const AdvanceReconcileScreen({super.key});

  @override
  State<AdvanceReconcileScreen> createState() => _AdvanceReconcileScreenState();
}

class _DemLine {
  final Map<String, dynamic> row;
  final TextEditingController rec = TextEditingController();
  _DemLine(this.row);
  double get amount => double.tryParse(rec.text.trim()) ?? 0;
}

class _AdvanceReconcileScreenState extends State<AdvanceReconcileScreen> {
  // masters
  List<Map<String, dynamic>> _classes = [];
  List<Map<String, dynamic>> _courseList = [];
  int? _fCour, _fCla;
  final _searchCtrl = TextEditingController();

  // last year's receipts
  String _curYear = '', _prevYear = '';
  bool _prevFound = true;
  int _pendingCarry = 0, _carried = 0; // last year's receipts not carried yet / carried
  List<Map<String, dynamic>> _receipts = [];

  // the receipt on screen
  Map<String, dynamic>? _sel; // receipt row
  Map<String, dynamic>? _advance, _studentRow;
  String? _studentPhoto; // students.stuphoto of _studentRow, looked up on open
  List<Map<String, dynamic>> _advLines = [];
  final List<_DemLine> _demands = [];

  bool _loading = true, _busy = false, _detailLoading = false;

  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  /// 4,000.00 / 1,00,000.00 -- Indian grouping, always two decimals.
  static String _money(double v) {
    final s = v.toStringAsFixed(2);
    final dot = s.indexOf('.');
    return '${formatIndianNumber(int.parse(s.substring(0, dot)))}${s.substring(dot)}';
  }
  int get _insId => context.read<AuthProvider>().insId ?? 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _disposeDemands();
    super.dispose();
  }

  void _disposeDemands() {
    for (final d in _demands) {
      d.rec.dispose();
    }
    _demands.clear();
  }

  void _snack(String msg, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: c));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.client.rpc('advance_reconcile_receipts', params: {'p_token': SupabaseService.sessionToken}),
      ]);
      if (!mounted) return;
      final res = Map<String, dynamic>.from(r[2] as Map);
      setState(() {
        _classes = List<Map<String, dynamic>>.from((r[0] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => classCompare('${a['claname']}', '${b['claname']}'));
        _courseList = List<Map<String, dynamic>>.from((r[1] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => (_id(a['ordid']) ?? 9999).compareTo(_id(b['ordid']) ?? 9999));
        _curYear = '${res['cur_year'] ?? ''}';
        _prevYear = '${res['prev_year'] ?? ''}';
        _prevFound = res['prev_found'] == true;
        _pendingCarry = _id(res['pending_carry']) ?? 0;
        _carried = _id(res['carried']) ?? 0;
        _receipts = List<Map<String, dynamic>>.from((res['receipts'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        _loading = false;
      });
      // keep the open receipt in step (its balance moved)
      final sel = _sel;
      if (sel != null) {
        final again = _receipts.where((x) => _id(x['adv_id']) == _id(sel['adv_id'])).toList();
        if (again.isEmpty) {
          _clearSelection();
        } else {
          await _open(again.first);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Failed to load. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  void _clearSelection() => setState(() {
        _sel = null;
        _advance = null;
        _studentRow = null;
        _studentPhoto = null;
        _advLines = [];
        _disposeDemands();
      });

  Future<void> _open(Map<String, dynamic> rcpt) async {
    setState(() {
      _sel = rcpt;
      _detailLoading = true;
    });
    try {
      final res = await SupabaseService.client
          .rpc('advance_reconcile_detail', params: {'p_token': SupabaseService.sessionToken, 'p_adv_id': rcpt['adv_id']});
      if (!mounted) return;
      final m = Map<String, dynamic>.from(res as Map);
      setState(() {
        _advance = Map<String, dynamic>.from(m['advance'] as Map);
        _studentRow = Map<String, dynamic>.from(m['student'] as Map);
        _studentPhoto = _studentRow!['stuphoto']?.toString();
        _advLines = List<Map<String, dynamic>>.from((m['lines'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        _disposeDemands();
        _demands.addAll((m['demands'] as List? ?? const []).map((e) => _DemLine(Map<String, dynamic>.from(e as Map))));
        _detailLoading = false;
      });
      if (!(_studentRow?.containsKey('stuphoto') ?? true)) _loadStudentPhoto(_studentRow!);
    } catch (e) {
      if (mounted) {
        setState(() => _detailLoading = false);
        _snack('Could not open ${rcpt['advno']}. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  /// The reconcile detail carries no photo; look it up for this one student
  /// (by adm no, which is stable across years). A failure just leaves the
  /// initial showing.
  Future<void> _loadStudentPhoto(Map<String, dynamic> stu) async {
    final admno = stu['stuadmno']?.toString().trim() ?? '';
    if (admno.isEmpty) return;
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stuphoto')
          .eq('ins_id', _insId)
          .eq('stuadmno', admno)
          .limit(1);
      if (!mounted || !identical(_studentRow, stu)) return;
      final list = rows as List;
      if (list.isEmpty) return;
      setState(() => _studentPhoto = (list.first as Map)['stuphoto']?.toString());
    } catch (_) {}
  }

  // ── amounts ─────────────────────────────────────────────────────────────
  double _avail(Map<String, dynamic> l) => (_num(l['amount']) - _num(l['reconciled'])).clamp(0, double.infinity).toDouble();
  double get _advTotal => _advLines.fold(0, (t, l) => t + _num(l['amount']));
  double get _advReconciled => _advLines.fold(0, (t, l) => t + _num(l['reconciled']));

  /// What can still be reconciled: the lines' remainder, never more than the
  /// receipt's balance (a refund also comes off that).
  double get _available {
    final lines = _advLines.fold<double>(0, (t, l) => t + _avail(l));
    final bal = _num(_advance?['balance']);
    return _advLines.isEmpty ? bal : (lines < bal ? lines : bal);
  }

  double get _recTotal => _demands.fold(0, (t, d) => t + d.amount);
  double get _demBalance => _demands.fold(0, (t, d) => t + _num(d.row['balancedue']));

  static String _k(dynamic s) => '${s ?? ''}'.trim().toUpperCase();

  /// An old year's ARREAR carried by Year End. The advance was collected for
  /// THIS year's fees, so Auto Reconcile never puts it on an arrear (it can
  /// still be typed in by hand).
  static bool _isArrear(Map<String, dynamic> d) => _k(d['demseqtype']) == 'ARREAR';

  /// Same term + fee type first, then the same fee type, then anything --
  /// the order both Auto Reconcile and the save use.
  int _rank(Map<String, dynamic> adv, Map<String, dynamic> dem) {
    final sameType = _k(adv['feetype']) == _k(dem['demfeetype']);
    final sameTerm = _k(adv['term']) == _k(dem['demfeeterm']);
    if (sameType && sameTerm) return 0;
    if (sameType) return 1;
    return 2;
  }

  void _autoReconcile() {
    final pool = {for (final l in _advLines) _id(l['ac_id']) ?? -1: _avail(l)};
    var left = _available;
    final put = List<double>.filled(_demands.length, 0);
    for (var pass = 0; pass < 3 && left > 0.004; pass++) {
      for (final l in _advLines) {
        final key = _id(l['ac_id']) ?? -1;
        for (var i = 0; i < _demands.length && left > 0.004; i++) {
          if ((pool[key] ?? 0) <= 0.004) break;
          if (_isArrear(_demands[i].row)) continue;
          if (_rank(l, _demands[i].row) != pass) continue;
          final room = _num(_demands[i].row['balancedue']) - put[i];
          if (room <= 0.004) continue;
          var x = pool[key]!;
          if (x > room) x = room;
          if (x > left) x = left;
          put[i] += x;
          pool[key] = pool[key]! - x;
          left -= x;
        }
      }
    }
    // A receipt without lines (an older plain advance): fill in demand order.
    if (_advLines.isEmpty) {
      for (var i = 0; i < _demands.length && left > 0.004; i++) {
        if (_isArrear(_demands[i].row)) continue;
        var x = _num(_demands[i].row['balancedue']);
        if (x > left) x = left;
        put[i] = x;
        left -= x;
      }
    }
    setState(() {
      for (var i = 0; i < _demands.length; i++) {
        _demands[i].rec.text = put[i] > 0 ? put[i].toStringAsFixed(2) : '';
      }
    });
    if (put.every((x) => x <= 0)) _snack('Nothing to match: no open demand this year for these fees.', AppColors.warning);
  }

  /// The amounts entered per demand, split over the advance lines (same
  /// order as Auto Reconcile) -> [{ac_id, dem_id, amount}].
  List<Map<String, dynamic>> _buildLines() {
    final pool = {for (final l in _advLines) _id(l['ac_id']) ?? -1: _avail(l)};
    final out = <Map<String, dynamic>>[];
    for (final d in _demands) {
      var need = d.amount;
      if (need <= 0) continue;
      if (_advLines.isEmpty) {
        out.add({'ac_id': null, 'dem_id': d.row['dem_id'], 'amount': need});
        continue;
      }
      for (var pass = 0; pass < 3 && need > 0.004; pass++) {
        for (final l in _advLines) {
          final key = _id(l['ac_id']) ?? -1;
          if (need <= 0.004) break;
          if (_rank(l, d.row) != pass || (pool[key] ?? 0) <= 0.004) continue;
          final x = pool[key]! < need ? pool[key]! : need;
          out.add({'ac_id': l['ac_id'], 'dem_id': d.row['dem_id'], 'amount': double.parse(x.toStringAsFixed(2))});
          pool[key] = pool[key]! - x;
          need -= x;
        }
      }
    }
    return out;
  }

  Future<void> _reconcile() async {
    final total = _recTotal;
    if (total <= 0) {
      _snack('Enter the amounts to reconcile, or use Auto Reconcile.', AppColors.warning);
      return;
    }
    for (final d in _demands) {
      if (d.amount > _num(d.row['balancedue']) + 0.004) {
        _snack('${d.row['demfeeterm']} ${d.row['demfeetype']}: more than the ₹${_money(_num(d.row['balancedue']))} due.', AppColors.error);
        return;
      }
    }
    if (total > _available + 0.004) {
      _snack('Reconciling ₹${_money(total)} is more than the ₹${_money(_available)} left on ${_advance?['advno']}.', AppColors.error);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reconcile advance'),
        content: Text(
            'Settle ₹${_money(total)} of ${_studentRow?['stuname']}\'s $_prevYear advance (${_advance?['advno']}) against $_curYear fees?\n\n'
            'No receipt is issued -- the fees are marked paid from the advance (as the old Advance Reconcile). Reverse it later from Reconciled if needed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: _solidBtn(), child: const Text('Reconcile')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await SupabaseService.client.rpc('reconcile_previous_advance', params: {
        'p_token': SupabaseService.sessionToken,
        'p_adv_id': _advance!['adv_id'],
        'p_lines': _buildLines(),
      });
      final m = Map<String, dynamic>.from(res as Map);
      _snack('Reconciled ₹${_money(_num(m['reconciled']))} from ${m['advno'] ?? _advance?['advno']} -- the fees are marked paid.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Reconcile failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openHistory() async {
    final stuId = _studentRow?['stu_id'];
    if (stuId == null) return;
    List<Map<String, dynamic>> rows;
    try {
      final res = await SupabaseService.client
          .rpc('advance_reconcile_history', params: {'p_token': SupabaseService.sessionToken, 'p_stu_id': stuId});
      rows = List<Map<String, dynamic>>.from((res as List).map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (e) {
      _snack('Could not load. ${friendlyError(e)}', AppColors.error);
      return;
    }
    if (!mounted) return;
    var changed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Reconciled -- ${_studentRow?['stuname']}', style: AppUI.cardTitle),
          content: SizedBox(
            width: 640.w,
            child: rows.isEmpty
                ? Padding(
                    padding: EdgeInsets.symmetric(vertical: 24.h),
                    child: Text('Nothing reconciled for this student in $_curYear yet.', textAlign: TextAlign.center, style: AppUI.muted),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      final active = r['active'] == true;
                      final lines = (r['lines'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map));
                      return Padding(
                        padding: EdgeInsets.symmetric(vertical: 10.h),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Text('${r['advno']}', style: AppUI.label.copyWith(color: active ? AppColors.textPrimary : AppColors.textLight)),
                                SizedBox(width: 8.w),
                                Text('(${r['prev_year']})  ·  reconciled ${_dmy(r['date'])} by ${r['by'] ?? '-'}', style: AppUI.muted),
                                if (!active) ...[
                                  SizedBox(width: 8.w),
                                  AppUI.chip('REVERSED', AppStatus.danger),
                                ],
                              ]),
                              SizedBox(height: 4.h),
                              for (final l in lines)
                                Text('${l['term']}  ${l['feetype']}  ₹${_money(_num(l['amount']))}', style: AppUI.muted),
                            ]),
                          ),
                          Text('₹${_money(_num(r['amount']))}', style: AppUI.money.copyWith(color: active ? AppColors.primary : AppColors.textLight)),
                          SizedBox(width: 12.w),
                          if (active)
                            OutlinedButton(
                              onPressed: () async {
                                if (await _reverse(r)) {
                                  changed = true;
                                  setD(() => r['active'] = false);
                                }
                              },
                              style: OutlinedButton.styleFrom(foregroundColor: AppColors.error, side: const BorderSide(color: AppColors.error)),
                              child: const Text('Reverse'),
                            ),
                        ]),
                      );
                    },
                  ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      ),
    );
    if (changed) await _load();
  }

  Future<bool> _reverse(Map<String, dynamic> r) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reverse this reconcile?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('The $_curYear fees are owed again and ₹${_money(_num(r['amount']))} goes back to ${r['advno']}.'),
          SizedBox(height: 12.h),
          TextField(controller: reason, style: AppUI.fieldText(context), decoration: AppUI.field(context, '', label: 'Reason')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: AppUI.danger(context),
            child: const Text('Reverse'),
          ),
        ],
      ),
    );
    final why = reason.text.trim();
    reason.dispose();
    if (ok != true) return false;
    try {
      await SupabaseService.client.rpc('reverse_previous_advance',
          params: {'p_token': SupabaseService.sessionToken, 'p_adv_id': r['adv_id'], 'p_batch_id': r['batch_id'], 'p_reason': why.isEmpty ? null : why});
      _snack('Reconcile of ₹${_money(_num(r['amount']))} reversed -- ${r['advno']} has it back.', AppColors.success);
      return true;
    } catch (e) {
      _snack('Reverse failed. ${friendlyError(e)}', AppColors.error);
      return false;
    }
  }

  static String _dmy(dynamic v) {
    final x = DateTime.tryParse('${v ?? ''}');
    return x == null ? '-' : '${x.day.toString().padLeft(2, '0')}/${x.month.toString().padLeft(2, '0')}/${x.year}';
  }

  // ── UI ──────────────────────────────────────────────────────────────────
  bool get _compact => MediaQuery.of(context).size.width <= 1366;
  BoxDecoration get _cardDec => AppUI.card();

  ButtonStyle _solidBtn() => AppUI.primary(context);

  ButtonStyle _outlineBtn() => AppUI.secondary(context);

  InputDecoration _inputDec(String hint, {bool filled = false, Widget? prefix}) {
    final d = AppUI.field(context, hint, filled: filled);
    return prefix == null ? d : d.copyWith(prefixIcon: prefix);
  }

  Widget _filterDrop(String hint, int? value, List<(int, String)> items, ValueChanged<int?> onChanged) {
    return DropdownButtonFormField<int>(
      key: ValueKey('$hint-$value-${items.length}'),
      initialValue: items.any((e) => e.$1 == value) ? value : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12.r),
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      decoration: _inputDec(hint, filled: value != null),
      hint: Text(hint, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)),
      items: [
        for (final e in items)
          DropdownMenuItem(value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context))),
      ],
      selectedItemBuilder: (_) => [
        for (final e in items)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(e.$2, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)),
          ),
      ],
      onChanged: onChanged,
    );
  }

  // ── table building blocks: bordered cells, as the mockup ────────────────
  // Amount tones: what is still left (warning) / what has been reconciled (success).
  static const _orange = AppColors.warning;
  static const _green = AppColors.success;

  TextStyle get _headStyle => AppUI.tableHead;
  TextStyle _cellStyle({Color? color, FontWeight weight = FontWeight.w500}) =>
      AppUI.cell.copyWith(fontWeight: weight, color: color ?? AppColors.textPrimary);

  Widget _cell(Widget child, int flex, {TextAlign align = TextAlign.left}) => Expanded(
        flex: flex,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14.w),
          child: Align(
            alignment: align == TextAlign.right
                ? Alignment.centerRight
                : align == TextAlign.center
                    ? Alignment.center
                    : Alignment.centerLeft,
            child: child,
          ),
        ),
      );

  Widget _text(String t, int flex, {TextAlign align = TextAlign.left, TextStyle? style}) =>
      _cell(Text(t, textAlign: align, overflow: TextOverflow.ellipsis, style: style ?? _cellStyle()), flex, align: align);

  /// One table row: cells separated by thin vertical rules.
  Widget _tr(List<Widget> cells, {Color? color, bool top = true}) => Container(
        decoration: BoxDecoration(
          color: color ?? Colors.white,
          border: top ? const Border(top: BorderSide(color: AppColors.divider)) : null,
        ),
        height: 50.h,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < cells.length; i++) ...[
            if (i > 0) const VerticalDivider(width: 1, thickness: 1, color: AppColors.divider),
            cells[i],
          ],
        ]),
      );

  Widget _table({required String title, required String icon, required List<Widget> rows}) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: AppUI.card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppColors.divider))),
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 13.h),
            child: AppUI.cardHeader(icon: icon, title: title),
          ),
          ...rows,
        ]),
      );

  List<Map<String, dynamic>> get _visibleReceipts {
    final q = _searchCtrl.text.trim().toLowerCase();
    final secs = _fCour == null ? null : {for (final c in _classes) if (_id(c['cour_id']) == _fCour) _id(c['cla_id'])};
    return _receipts.where((r) {
      final cla = _id(r['cla_id']);
      if (_fCla != null && cla != _fCla) return false;
      if (secs != null && !secs.contains(cla)) return false;
      if (q.isEmpty) return true;
      return '${r['advno']} ${r['stuadmno']} ${r['stuname']}'.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (!isSchool) {
      return Center(child: Text('Advance reconcile is used on the school database only.', style: AppUI.muted));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(decoration: _cardDec, padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h), child: _header()),
      SizedBox(height: AppUI.gap),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : !_prevFound
                ? _noPrevYear()
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_pendingCarry > 0) ...[
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                        decoration: BoxDecoration(
                          color: AppColors.warningBg,
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                          border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.info_outline, color: AppColors.warning, size: 20),
                          SizedBox(width: 10.w),
                          Expanded(
                            child: Text(
                                '$_pendingCarry advance receipt${_pendingCarry == 1 ? '' : 's'} of $_prevYear ${_pendingCarry == 1 ? 'is' : 'are'} not carried into $_curYear yet. '
                                'Press Carry Forward (Year End Process) to bring ${_pendingCarry == 1 ? 'it' : 'them'} here for reconciling.',
                                style: AppUI.body.copyWith(fontWeight: FontWeight.w600)),
                          ),
                        ]),
                      ),
                      SizedBox(height: 12.h),
                    ],
                    Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SizedBox(width: _compact ? 390.w : 450.w, child: _receiptList()),
                    SizedBox(width: AppUI.gap),
                    Expanded(child: _detail()),
                  ])),
                  ]),
      ),
    ]);
  }

  // ── header: title, Standard, Section, search, Refresh, Clear ────────────
  Widget _header() => Row(children: [
        AppUI.iconTile('empty-wallet-change'),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Advance Adjustment', style: AppUI.cardTitle),
            SizedBox(height: 2.h),
            Text(_prevYear.isEmpty ? 'Reconcile last year\'s advance fees' : 'Reconcile $_prevYear advance fees against $_curYear fees',
                overflow: TextOverflow.ellipsis, style: AppUI.muted),
          ]),
        ),
        SizedBox(
          width: _compact ? 150.w : 180.w,
          child: _filterDrop(schoolTerm('Select Course'), _fCour, [for (final c in _courseList) (_id(c['cour_id'])!, '${c['courname']}')],
              (v) => setState(() {
                    _fCour = v;
                    _fCla = null;
                  })),
        ),
        SizedBox(width: 10.w),
        SizedBox(
          width: _compact ? 150.w : 180.w,
          child: _filterDrop(
              schoolTerm('Select Class'),
              _fCla,
              [
                for (final c in _classes)
                  if (_fCour == null || _id(c['cour_id']) == _fCour) (_id(c['cla_id'])!, '${c['claname']}'),
              ],
              (v) => setState(() => _fCla = v)),
        ),
        SizedBox(width: 10.w),
        SizedBox(
          width: _compact ? 220.w : 280.w,
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            style: AppUI.fieldText(context, filled: _searchCtrl.text.isNotEmpty),
            decoration: AppUI.field(context, 'Receipt / Adm No / Name', filled: _searchCtrl.text.isNotEmpty, leadingIcon: 'search-normal-1'),
          ),
        ),
        SizedBox(width: 10.w),
        Tooltip(
          message: 'Year End Process: bring $_prevYear advance receipts into $_curYear (run again to pick up new advances, refunds and cancellations)',
          child: OutlinedButton.icon(
            onPressed: _busy || !_prevFound ? null : _carryForward,
            icon: const Icon(Icons.move_down_rounded, size: 18),
            label: Text(_pendingCarry > 0 ? 'Carry Forward ($_pendingCarry)' : 'Carry Forward'),
            style: _outlineBtn(),
          ),
        ),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh, size: 17),
          label: const Text('Refresh'),
          style: _solidBtn(),
        ),
        SizedBox(width: 10.w),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () {
                  _searchCtrl.clear();
                  setState(() {
                    _fCour = null;
                    _fCla = null;
                  });
                  _clearSelection();
                },
          icon: const Icon(Icons.close, size: 17),
          label: const Text('Clear'),
          style: _outlineBtn(),
        ),
      ]);

  Widget _noPrevYear() => Container(
        decoration: _cardDec,
        alignment: Alignment.center,
        child: AppUI.empty(
          icon: 'calendar-1',
          title: 'No $_prevYear academic year on this database',
          why: 'Advance fees collected in $_curYear are reconciled here once the next academic year is opened.',
        ),
      );

  // ── left: last year's advance receipts ───────────────────────────────────
  Widget _receiptList() {
    final rows = _visibleReceipts;
    Widget head(String t, int flex, {TextAlign align = TextAlign.left}) => AppUI.th(t, flex: flex, align: align);
    return Container(
      decoration: _cardDec,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 16.h, 16.w, 14.h),
          child: AppUI.cardHeader(
            icon: 'receipt-item',
            title: 'Advance Receipts - $_prevYear',
            trailing: [AppUI.chip('${rows.length}', AppStatus.info)],
          ),
        ),
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Row(children: [
            head('Receipt No', 4),
            head(schoolTerm('Roll No'), 4),
            head('Student Name', 5),
            head('Balance', 4, align: TextAlign.right),
          ]),
        ),
        Expanded(
          child: rows.isEmpty
              ? SingleChildScrollView(
                  child: AppUI.empty(
                    icon: 'receipt-item',
                    title: 'No advance receipts',
                    why: _carried == 0
                        ? 'No $_prevYear advances carried into $_curYear yet -- press Carry Forward (Year End Process).'
                        : _receipts.isEmpty
                            ? 'No $_prevYear advance left to reconcile.'
                            : schoolTerm('No advance receipt for this class.'),
                  ),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final on = _id(_sel?['adv_id']) == _id(r['adv_id']);
                    return InkWell(
                      onTap: _busy ? null : () => _open(r),
                      child: Container(
                        decoration: BoxDecoration(
                          color: on ? AppColors.primaryLight : Colors.white,
                          border: Border(
                            left: BorderSide(color: on ? AppColors.primary : Colors.transparent, width: 3),
                            bottom: const BorderSide(color: AppColors.divider),
                          ),
                        ),
                        padding: EdgeInsets.fromLTRB(13.w, 13.h, 16.w, 13.h),
                        child: Row(children: [
                          Expanded(
                            flex: 4,
                            child: Text('${r['advno']}',
                                overflow: TextOverflow.ellipsis,
                                style: AppUI.cell.copyWith(fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? AppColors.primary : AppColors.textPrimary)),
                          ),
                          Expanded(
                            flex: 4,
                            child: Text('${r['stuadmno']}', overflow: TextOverflow.ellipsis, style: AppUI.cell),
                          ),
                          Expanded(
                            flex: 5,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${r['stuname']}', overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(fontWeight: FontWeight.w600)),
                              SizedBox(height: 2.h),
                              Text('${r['stuclass'] ?? ''}', overflow: TextOverflow.ellipsis, style: AppUI.muted),
                            ]),
                          ),
                          Expanded(
                            flex: 4,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text('₹${_money(_num(r['balance']))}',
                                  maxLines: 1, softWrap: false, textAlign: TextAlign.right, style: AppUI.money.copyWith(color: _orange)),
                            ),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: EdgeInsets.all(12.w),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
          child: ElevatedButton.icon(
            onPressed: _busy || rows.isEmpty ? null : () => _bulkReconcile(rows),
            icon: const Icon(Icons.playlist_add_check_rounded, size: 20),
            label: Text('Reconcile ${_scopeName()} (${rows.length})', overflow: TextOverflow.ellipsis),
            style: _solidBtn(),
          ),
        ),
      ]),
    );
  }

  /// "LKG A", "LKG", "search results" or "all" -- what the list is showing.
  String _scopeName() {
    if (_fCla != null) {
      return '${_classes.firstWhere((c) => _id(c['cla_id']) == _fCla, orElse: () => const {})['claname'] ?? ''}';
    }
    if (_fCour != null) {
      return '${_courseList.firstWhere((c) => _id(c['cour_id']) == _fCour, orElse: () => const {})['courname'] ?? ''}';
    }
    return _searchCtrl.text.trim().isEmpty ? 'All' : 'Listed';
  }

  /// Year End Process for advances, as the old product: copy last year's
  /// advance receipts into this year (only those copies are reconciled here),
  /// and re-sync what changed in last year since -- a refund lowers the
  /// carried amount, a cancelled / bounced advance is removed and any
  /// reconcile made from it is undone (the fees are owed again).
  Future<void> _carryForward() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Carry Forward advances'),
        content: Text('Bring the $_prevYear advance receipts into $_curYear (Year End Process).\n\n'
            'Running it again also picks up advances collected since, refunds, and cancelled or bounced advances. '
            'If a cancelled advance had already been reconciled, that reconcile is undone and the fees are owed again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: _solidBtn(), child: const Text('Carry Forward')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final res = await SupabaseService.client.rpc('carry_forward_advances', params: {'p_token': SupabaseService.sessionToken});
      final m = Map<String, dynamic>.from(res as Map);
      final added = _id(m['added']) ?? 0, upd = _id(m['updated']) ?? 0, del = _id(m['removed']) ?? 0;
      final rev = _id(m['reversed']) ?? 0, skip = _id(m['not_in_year']) ?? 0;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Carry Forward done'),
          content: Text([
            '$added advance line${added == 1 ? '' : 's'} carried into $_curYear.',
            if (upd > 0) '$upd changed by a refund in $_prevYear.',
            if (del > 0) '$del removed (cancelled / bounced in $_prevYear).',
            if (rev > 0) '$rev reconcile${rev == 1 ? '' : 's'} undone -- the advance behind ${rev == 1 ? 'it' : 'them'} is gone; those fees are owed again.',
            if (skip > 0) '$skip advance${skip == 1 ? '' : 's'} not carried: the student is not in $_curYear.',
            if (added + upd + del + rev == 0) 'Everything was already up to date.',
          ].join('\n')),
          actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), style: _solidBtn(), child: const Text('OK'))],
        ),
      );
      _clearSelection();
      await _load();
    } catch (e) {
      _snack('Carry Forward failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── class-wise reconcile: preview, confirm, result ──────────────────────
  Future<void> _bulkReconcile(List<Map<String, dynamic>> rows) async {
    final ids = [for (final r in rows) r['adv_id']];
    setState(() => _busy = true);
    Map<String, dynamic> plan;
    try {
      final res = await SupabaseService.client.rpc('reconcile_advances_bulk',
          params: {'p_token': SupabaseService.sessionToken, 'p_adv_ids': ids, 'p_apply': false});
      plan = Map<String, dynamic>.from(res as Map);
    } catch (e) {
      _snack('Could not prepare the reconcile. ${friendlyError(e)}', AppColors.error);
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (mounted) setState(() => _busy = false);
    final items = List<Map<String, dynamic>>.from((plan['items'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final willDo = items.where((i) => _num(i['amount']) > 0).toList();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _bulkDialog(
        ctx,
        title: 'Reconcile ${_scopeName()} -- preview',
        subtitle: willDo.isEmpty
            ? 'Nothing to reconcile: none of these students has an open $_curYear demand for this money.'
            : '${willDo.length} of ${items.length} receipts will be reconciled with Auto Reconcile (same ${schoolTerm('semester')} and fee type first). No receipts are issued -- the fees are marked paid from each advance.',
        items: items,
        done: false,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton.icon(
            onPressed: willDo.isEmpty ? null : () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.save, size: 18),
            label: Text('Reconcile ${willDo.length} receipt${willDo.length == 1 ? '' : 's'}  ·  ₹${_money(_num(plan['total']))}'),
            style: _solidBtn(),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    Map<String, dynamic> out;
    try {
      final res = await SupabaseService.client.rpc('reconcile_advances_bulk',
          params: {'p_token': SupabaseService.sessionToken, 'p_adv_ids': [for (final i in willDo) i['adv_id']], 'p_apply': true});
      out = Map<String, dynamic>.from(res as Map);
    } catch (e) {
      _snack('Reconcile failed. ${friendlyError(e)}', AppColors.error);
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (mounted) setState(() => _busy = false);
    final done = _id(out['done']) ?? 0, failed = _id(out['failed']) ?? 0;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _bulkDialog(
        ctx,
        title: failed == 0 ? 'Reconciled' : 'Reconciled with errors',
        subtitle: '$done receipt${done == 1 ? '' : 's'} reconciled for ₹${_money(_num(out['total']))}'
            '${failed > 0 ? ' -- $failed could not be (see below); the rest are saved.' : '.'}',
        items: List<Map<String, dynamic>>.from((out['items'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map))),
        done: true,
        actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), style: _solidBtn(), child: const Text('Done'))],
      ),
    );
    _clearSelection();
    await _load();
  }

  Widget _bulkDialog(BuildContext ctx,
      {required String title, required String subtitle, required List<Map<String, dynamic>> items, required bool done, required List<Widget> actions}) {
    Widget h(String t, int f, {TextAlign a = TextAlign.left}) => AppUI.th(t, flex: f, align: a);
    Widget c(String t, int f, {TextAlign a = TextAlign.left, Color? color, FontWeight w = FontWeight.w500}) => Expanded(
        flex: f,
        child: Text(t, textAlign: a, overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(fontWeight: w, color: color ?? AppColors.textPrimary)));
    return AlertDialog(
      titlePadding: EdgeInsets.fromLTRB(24.w, 20.h, 24.w, 4.h),
      title: Text(title, style: AppUI.cardTitle),
      content: SizedBox(
        width: 820.w,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(subtitle, style: AppUI.muted),
          SizedBox(height: 14.h),
          Container(
            decoration: AppUI.card(radius: 12),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
                child: Row(children: [
                  h('Receipt', 3),
                  h(schoolTerm('Roll No'), 3),
                  h('Student', 4),
                  h(schoolTerm('Class'), 2),
                  h('Left (₹)', 3, a: TextAlign.right),
                  h(done ? 'Result' : 'Reconcile (₹)', 4, a: TextAlign.right),
                ]),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: 380.h),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final it = items[i];
                    final amt = _num(it['amount']);
                    final err = it['error'];
                    final String result;
                    final Color color;
                    if (err != null) {
                      result = '$err';
                      color = AppColors.error;
                    } else if (amt <= 0) {
                      result = 'Nothing to match';
                      color = AppColors.textLight;
                    } else if (done) {
                      result = '₹${_money(amt)} reconciled';
                      color = _green;
                    } else {
                      result = _money(amt);
                      color = AppColors.primary;
                    }
                    return Container(
                      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
                      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                      child: Row(children: [
                        c('${it['advno']}', 3, w: FontWeight.w600),
                        c('${it['stuadmno']}', 3),
                        c('${it['stuname']}', 4),
                        c('${it['stuclass'] ?? ''}', 2, color: AppColors.textSecondary),
                        c(_money(_num(it['left'])), 3, a: TextAlign.right, color: _orange),
                        Expanded(
                          flex: 4,
                          child: Tooltip(
                            message: result,
                            child: Text(result, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis,
                                style: AppUI.money.copyWith(color: color)),
                          ),
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ]),
          ),
        ]),
      ),
      actions: actions,
    );
  }

  // ── right: student, the two tables, footer ───────────────────────────────
  Widget _detail() {
    if (_sel == null) {
      return Container(
        decoration: _cardDec,
        alignment: Alignment.center,
        child: AppUI.empty(
          icon: 'search-normal-1',
          title: schoolTerm('Choose a class and an advance receipt to reconcile'),
        ),
      );
    }
    if (_detailLoading || _advance == null) {
      return Container(decoration: _cardDec, child: const Center(child: CircularProgressIndicator(color: AppColors.primary)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(decoration: _cardDec, padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h), child: _studentStrip()),
      SizedBox(height: AppUI.gap),
      Expanded(
        child: Container(
          decoration: _cardDec,
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: ListView(padding: EdgeInsets.all(AppUI.cardPad), children: [
                _advanceTable(),
                SizedBox(height: AppUI.gap),
                _demandTable(),
              ]),
            ),
            _footer(),
          ]),
        ),
      ),
    ]);
  }

  Widget _studentStrip() {
    final s = _studentRow!;
    Widget sep() => Container(width: 1, height: 40.h, margin: EdgeInsets.symmetric(horizontal: 18.w), color: AppColors.divider);
    Widget info(String icon, String label, String value, {Color? color, double? size}) => Row(children: [
          AppIcon.linear(icon, size: 22, color: AppColors.primary),
          SizedBox(width: 10.w),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: AppUI.muted),
              SizedBox(height: 3.h),
              // never cut off: a long value shrinks to fit its block
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: size ?? 13.5.sp, fontWeight: FontWeight.w700, color: color ?? AppColors.textPrimary)),
              ),
            ]),
          ),
        ]);
    return Row(children: [
      StudentAvatar(photoUrl: _studentPhoto, name: '${s['stuname'] ?? ''}', size: 52),
      SizedBox(width: 14.w),
      Expanded(
        flex: 3,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('${s['stuname'] ?? ''}', overflow: TextOverflow.ellipsis, style: AppUI.cardTitle),
          SizedBox(height: 3.h),
          Text('${schoolTerm('Roll No')}: ${s['stuadmno']}', style: AppUI.muted),
        ]),
      ),
      sep(),
      Expanded(flex: 2, child: info('teacher', schoolTerm('Class'), '${s['stuclass'] ?? '-'}')),
      sep(),
      Expanded(flex: 4, child: info('receipt-item', 'Advance Receipt', '${_advance!['advno']}  •  ${_dmy(_advance!['advdate'])}')),
      sep(),
      Expanded(flex: 2, child: info('wallet-money', 'Left Amount', '₹${_money(_available)}', color: _orange, size: 16.sp)),
      SizedBox(width: 14.w),
      OutlinedButton.icon(
        onPressed: _busy ? null : _openHistory,
        icon: const Icon(Icons.check_circle, size: 17),
        label: const Text('Reconciled'),
        style: _outlineBtn(),
      ),
    ]);
  }

  Widget _advanceTable() {
    final rows = <Widget>[
      _tr(top: false, color: AppColors.tableHeadBg, [
        _text(schoolTerm('Semester').toUpperCase(), 2, style: _headStyle),
        _text('FEE TYPE', 3, style: _headStyle),
        _text('ADVANCE AMOUNT (₹)', 3, align: TextAlign.right, style: _headStyle),
        _text('RECONCILED (₹)', 3, align: TextAlign.right, style: _headStyle),
        _text('LEFT (₹)', 3, align: TextAlign.right, style: _headStyle),
      ]),
    ];
    for (final l in _advLines) {
      final rec = _num(l['reconciled']);
      rows.add(_tr([
        _text('${l['term'] ?? '-'}', 2),
        _text('${l['feetype']}', 3),
        _text(_money(_num(l['amount'])), 3, align: TextAlign.right),
        _text(rec > 0 ? _money(rec) : '—', 3, align: TextAlign.right, style: _cellStyle(color: rec > 0 ? _green : AppColors.textLight)),
        _text(_money(_avail(l)), 3, align: TextAlign.right, style: _cellStyle(color: _orange)),
      ]));
    }
    if (_advLines.isEmpty) {
      rows.add(_tr([
        _text('This advance has no fee lines -- ₹${_money(_num(_advance!['balance']))} can be reconciled against any fee.', 1,
            style: _cellStyle(color: AppColors.textSecondary)),
      ]));
    }
    final refunded = _num(_advance!['refunded']);
    rows.add(_tr(color: AppColors.tableHeadBg, [
      _text(refunded > 0 ? 'Total  (refunded ₹${_money(refunded)})' : 'Total', 5, style: _cellStyle(weight: FontWeight.w700)),
      _text(_money(_advTotal), 3, align: TextAlign.right, style: _cellStyle(weight: FontWeight.w700)),
      _text(_money(_advReconciled), 3, align: TextAlign.right, style: _cellStyle(color: _green, weight: FontWeight.w700)),
      _text(_money(_available), 3, align: TextAlign.right, style: _cellStyle(color: _orange, weight: FontWeight.w700)),
    ]));
    return _table(title: 'Advance Fee Collection during $_prevYear', icon: 'empty-wallet-add', rows: rows);
  }

  Widget _numField(TextEditingController ctrl, double max) {
    final filled = ctrl.text.trim().isNotEmpty;
    final over = (double.tryParse(ctrl.text.trim()) ?? 0) > max + 0.004;
    OutlineInputBorder errB(double w) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppUI.controlRadius), borderSide: BorderSide(color: AppColors.error, width: w));
    final dec = AppUI.field(context, '0.00', filled: filled, dense: true);
    return SizedBox(
      height: 38.h,
      child: TextField(
        controller: ctrl,
        enabled: !_busy,
        onChanged: (_) => setState(() {}),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
        textAlign: TextAlign.right,
        style: AppUI.fieldText(context, filled: filled).copyWith(color: over ? AppColors.error : null),
        decoration: over ? dec.copyWith(border: errB(1), enabledBorder: errB(1), focusedBorder: errB(2)) : dec,
      ),
    );
  }

  Widget _demandTable() {
    final rows = <Widget>[
      _tr(top: false, color: AppColors.tableHeadBg, [
        _text(schoolTerm('Semester').toUpperCase(), 2, style: _headStyle),
        _text('FEE TYPE', 3, style: _headStyle),
        _text('DUE DATE', 2, style: _headStyle),
        _text('FEE AMT (₹)', 2, align: TextAlign.right, style: _headStyle),
        _text('PAID (₹)', 2, align: TextAlign.right, style: _headStyle),
        _text('BAL. AMT (₹)', 2, align: TextAlign.right, style: _headStyle),
        _text('REC. AMOUNT (₹)', 3, align: TextAlign.center, style: _headStyle),
      ]),
    ];
    var fee = 0.0, paid = 0.0;
    for (final d in _demands) {
      final r = d.row;
      final bal = _num(r['balancedue']);
      final p = _num(r['paidamount']);
      fee += _num(r['feeamount']);
      paid += p;
      rows.add(_tr([
        _text(_isArrear(r) ? '${r['demfeeterm'] ?? '-'} · ${r['demfeeyear'] ?? ''} arrear' : '${r['demfeeterm'] ?? '-'}', 2,
            style: _isArrear(r) ? _cellStyle(color: AppColors.textSecondary) : null),
        _text('${r['demfeetype']}', 3),
        _text(_dmy(r['duedate']), 2),
        _text(_money(_num(r['feeamount'])), 2, align: TextAlign.right),
        _text(p > 0 ? _money(p) : '—', 2, align: TextAlign.right, style: _cellStyle(color: p > 0 ? _green : AppColors.textLight)),
        _text(_money(bal), 2, align: TextAlign.right, style: _cellStyle(color: _orange, weight: FontWeight.w600)),
        Expanded(flex: 3, child: Padding(padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h), child: Center(child: _numField(d.rec, bal)))),
      ]));
    }
    if (_demands.isEmpty) {
      rows.add(_tr([
        _text('No open fee demand for this student in $_curYear -- raise the Section Fee Demand first.', 1, style: _cellStyle(color: AppColors.textSecondary)),
      ]));
    }
    rows.add(_tr(color: AppColors.tableHeadBg, [
      _text('Total', 7, style: _cellStyle(weight: FontWeight.w700)),
      _text(_money(fee), 2, align: TextAlign.right, style: _cellStyle(weight: FontWeight.w700)),
      _text(_money(paid), 2, align: TextAlign.right, style: _cellStyle(color: _green, weight: FontWeight.w700)),
      _text(_money(_demBalance), 2, align: TextAlign.right, style: _cellStyle(color: _orange, weight: FontWeight.w700)),
      _text(_money(_recTotal), 3, align: TextAlign.right, style: _cellStyle(color: AppColors.primary, weight: FontWeight.w700)),
    ]));
    return _table(title: 'Fee Structure - $_curYear', icon: 'document-text', rows: rows);
  }

  Widget _footer() {
    final total = _recTotal;
    final over = total > _available + 0.004;
    final can = !_busy && total > 0 && !over && _demands.isNotEmpty;
    final h = AppUI.controlHeight(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        Container(
          width: 32.w,
          height: 32.w,
          decoration: BoxDecoration(shape: BoxShape.circle, color: over ? AppColors.errorBg : AppColors.primaryLight),
          child: Icon(over ? Icons.error_outline : Icons.info_outline, size: 18.sp, color: over ? AppColors.error : AppColors.primary),
        ),
        SizedBox(width: 10.w),
        Expanded(
          child: over
              ? Text('More than the ₹${_money(_available)} left on this advance.',
                  style: AppUI.muted.copyWith(fontWeight: FontWeight.w600, color: AppColors.error))
              : Text.rich(
                  TextSpan(style: AppUI.muted.copyWith(height: 1.4), children: [
                    const TextSpan(text: 'Auto Reconcile', style: TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(text: ' matches the same ${schoolTerm('semester')} and fee type first.\n'),
                    const TextSpan(text: 'Reconcile', style: TextStyle(fontWeight: FontWeight.w700)),
                    const TextSpan(text: ' marks the fees paid from the advance -- no receipt is issued.'),
                  ]),
                ),
        ),
        SizedBox(width: 12.w),
        Container(
          height: h,
          padding: EdgeInsets.symmetric(horizontal: 18.w),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.primaryLight,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('RECONCILE: ', style: AppUI.label.copyWith(letterSpacing: 0.3)),
            Text('₹${_money(total)}', style: AppUI.money.copyWith(fontSize: 15.sp, color: AppColors.primary)),
          ]),
        ),
        SizedBox(width: 12.w),
        OutlinedButton.icon(
          onPressed: _busy || _demands.isEmpty || _available <= 0 ? null : _autoReconcile,
          icon: const Icon(Icons.auto_fix_high, size: 18),
          label: const Text('Auto Reconcile'),
          style: _outlineBtn(),
        ),
        SizedBox(width: 10.w),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    for (final d in _demands) {
                      d.rec.clear();
                    }
                  }),
          style: _outlineBtn(),
          child: const Text('Clear'),
        ),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
          onPressed: can ? _reconcile : null,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save, size: 18),
          label: const Text('Reconcile'),
          style: _solidBtn(),
        ),
      ]),
    );
  }
}
