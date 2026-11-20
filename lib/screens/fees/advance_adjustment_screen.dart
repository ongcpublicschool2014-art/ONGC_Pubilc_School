import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_dropdown_field.dart';

/// Advance Adjustment (Fees → Advance Adjustment).
///
/// Applies ADMISSION advances against ONE fee type, for a single student or a
/// whole class at once.
///
/// An admission advance is taken from a student joining the next academic year,
/// against named fee types. When that year's demands are raised, somebody has
/// to apply each student's advance to the fee it was collected for. Doing that
/// one student at a time on the Fee Collection screen is fine for a walk-in and
/// hopeless for two hundred admissions, which is what this screen is for.
///
/// It REDUCES THE FEE, it does not pay it: feeamount comes down, paidamount is
/// untouched. That is what adjust_advance does for advtype 'A' — this screen
/// only chooses the rows and calls it once per advance.
///
/// STUDENT advances are deliberately absent. They settle a balance as a
/// payment, belong with the cash at the counter, and are applied from the Fee
/// Collection screen where the cashier can see what is owed.
class AdvanceAdjustmentScreen extends StatefulWidget {
  const AdvanceAdjustmentScreen({super.key});

  @override
  State<AdvanceAdjustmentScreen> createState() => _AdvanceAdjustmentScreenState();
}

/// One applicable pairing: this student's advance, against this demand.
///
/// A student with two admission advances gets two rows — each maps to exactly
/// one adjust_advance call, so nothing has to be guessed about which advance
/// paid for what.
class _AdjRow {
  _AdjRow({
    required this.stuId,
    required this.regNo,
    required this.name,
    required this.className,
    required this.advId,
    required this.advNo,
    required this.advBalance,
    required this.feeType,
    this.demId,
    this.demTerm = '',
    this.demBalance = 0,
    this.heldForType = 0,
  });

  final int stuId;
  final String regNo;
  final String name;
  final String className;
  final int advId;
  final String advNo;
  final double advBalance;

  /// The fee type this row settles — one row per line of the advance's
  /// breakdown, so an advance taken for three fees produces three rows.
  final String feeType;

  /// What this advance was collected for under that fee type (advance_detail).
  final double heldForType;

  /// The demand this row would reduce. NULL when no fee type is chosen yet, or
  /// when the student has an advance but nothing pending for that fee — the row
  /// is still listed, so "has an advance" and "can be adjusted" stay visibly
  /// different things.
  final int? demId;
  final String demTerm;
  final double demBalance;

  final TextEditingController amount = TextEditingController();

  /// The most this row may reduce: limited by what the advance holds for this
  /// fee type, by what is left on the advance overall, and by what is still
  /// billed on the demand.
  double get cap {
    if (demId == null) return 0;
    final v = [heldForType, advBalance, demBalance].reduce((a, b) => a < b ? a : b);
    return v > 0 ? v : 0;
  }

  double get entered => double.tryParse(amount.text.trim()) ?? 0;

  String get key => '$advId-$feeType-${demId ?? 0}';
}

class _AdvanceAdjustmentScreenState extends State<AdvanceAdjustmentScreen> {
  // ---- masters -------------------------------------------------------------
  List<Map<String, dynamic>> _courseList = [];
  List<Map<String, dynamic>> _classList = [];

  String? _course;
  String? _className;

  // ---- rows ----------------------------------------------------------------
  List<_AdjRow> _rows = [];
  final _picked = <String>{};
  final _search = TextEditingController();
  final _vScroll = ScrollController();

  bool _loading = true;
  bool _finding = false;
  bool _applying = false;
  String? _loadError;
  String? _notice;

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  @override
  void initState() {
    super.initState();
    // Load the masters, then list whatever advances are outstanding — the
    // screen opens with something on it rather than an empty grid.
    _loadMasters().then((_) {
      if (mounted && _loadError == null) _find();
    });
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.amount.dispose();
    }
    _search.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  // ===========================================================================
  // Loading
  // ===========================================================================

  Future<void> _loadMasters() async {
    final auth = context.read<AuthProvider>();
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final insId = auth.insId ?? 1;
      final res = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course')
            .select('cour_id, courname, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('ordid', ascending: true),
        SupabaseService.fromSchema('class')
            .select('claname, cour_id, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('ordid', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(res[0] as List);
        _classList = List<Map<String, dynamic>>.from(res[1] as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = friendlyError(e);
      });
    }
  }

  List<String> get _courseNames => _courseList
      .map((e) => e['courname']?.toString().trim() ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> _classesFor(String? course) {
    if (course == null) {
      return classGroupPartition(
          _classList
              .map((e) => e['claname']?.toString().trim() ?? '')
              .where((s) => s.isNotEmpty)
              .toSet(),
          (s) => s);
    }
    final c = _courseList.firstWhere(
        (e) => (e['courname']?.toString().trim() ?? '') == course,
        orElse: () => const {});
    final id = c['cour_id'];
    if (id == null) return const [];
    // Keeps the existing order within each group and sends the TC batches to
    // the foot of the list (utils/class_sort.dart).
    return classGroupPartition(
        _classList
            .where((cl) => cl['cour_id'] == id)
            .map((e) => e['claname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty),
        (s) => s);
  }

  /// Find every admission advance that still holds money for the chosen fee
  /// type, and pair it with that student's pending demand for the same fee.
  ///
  /// Four reads rather than a join: PostgREST cannot join across these, and
  /// each is a narrow indexed lookup.
  /// List every outstanding ADMISSION advance in the chosen course/class, one
  /// row per fee type it was collected for, paired with that student's pending
  /// demand for the same fee.
  ///
  /// There is no fee-type filter: an advance is normally taken for several fees
  /// at once, and making the user adjust them one fee at a time turned a single
  /// admission into four passes over the same list. The fee type is a COLUMN,
  /// and every line is filled in ready to apply.
  Future<void> _find() async {
    setState(() {
      _finding = true;
      _notice = null;
    });
    try {
      final insId = _insId;

      // 1. Admission advances with something left on them.
      final advs = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('advance_collection')
          .select('adv_id, advno, stu_id, stuadmno, stuname, stuclass, courname, balanceamount')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('paystatus', 'C')
          .eq('advtype', 'A')
          .gt('balanceamount', 0));
      var advList = advs.map((e) => Map<String, dynamic>.from(e)).toList();

      if (_course != null) {
        advList = advList
            .where((a) => (a['courname']?.toString().trim() ?? '') == _course)
            .toList();
      }
      if (_className != null) {
        advList = advList
            .where((a) => (a['stuclass']?.toString().trim() ?? '') == _className)
            .toList();
      }
      if (advList.isEmpty) {
        if (!mounted) return;
        _replaceRows([]);
        setState(() {
          _finding = false;
          _notice = schoolTerm('No admission advance is outstanding for that course/class.');
        });
        return;
      }

      final advIds = advList.map((a) => (a['adv_id'] as num).toInt()).toList();
      final stuIds = advList.map((a) => (a['stu_id'] as num).toInt()).toSet().toList();

      // 2. Every fee type each advance was collected for, LESS whatever has
      //    already been applied from it.
      //
      //    advance_detail holds the ORIGINAL amounts and is never written back
      //    to, so on its own it reports an advance as still holding money it
      //    has already spent — an advance with 6,300 left was showing 37,000
      //    across its fee types. advadjustment is the record of what went out,
      //    so netting it off per fee type is what makes HELD mean "left".
      final det = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('advance_detail')
          .select('adv_id, feetype, amount')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .inFilter('adv_id', advIds));
      final heldByAdv = <int, Map<String, double>>{};
      for (final r in det) {
        final id = (r['adv_id'] as num?)?.toInt();
        final ft = (r['feetype']?.toString().trim() ?? '');
        if (id == null || ft.isEmpty) continue;
        final m = heldByAdv[id] ??= <String, double>{};
        m[ft] = (m[ft] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
      }
      try {
        final used = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('advadjustment')
            .select('adv_id, demfeetype, adjustamount')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .inFilter('adv_id', advIds));
        for (final r in used) {
          final id = (r['adv_id'] as num?)?.toInt();
          final ft = (r['demfeetype']?.toString().trim() ?? '');
          if (id == null || ft.isEmpty) continue;
          final m = heldByAdv[id];
          if (m == null) continue;
          // Match on the same upper-cased name the pairing below uses, so a
          // difference in stored case cannot leave the amount un-netted.
          final key = m.keys.firstWhere(
              (k) => k.toUpperCase() == ft.toUpperCase(),
              orElse: () => '');
          if (key.isEmpty) continue;
          m[key] = (m[key] ?? 0) - ((r['adjustamount'] as num?)?.toDouble() ?? 0);
        }
      } catch (_) {
        // No advadjustment table yet — HELD then shows the original amounts.
      }

      // 3. Their pending demands, any fee type.
      final dems = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feedemand')
          .select('dem_id, stu_id, demfeeterm, demfeetype, balancedue, duedate')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('paidstatus', 'U')
          .gt('balancedue', 0)
          .inFilter('stu_id', stuIds)
          .order('duedate', ascending: true));
      // stu_id -> FEE TYPE (upper) -> oldest pending demand for it.
      final demByStuType = <int, Map<String, Map<String, dynamic>>>{};
      for (final d in dems) {
        final sid = (d['stu_id'] as num?)?.toInt();
        final ft = (d['demfeetype']?.toString().trim().toUpperCase() ?? '');
        if (sid == null || ft.isEmpty) continue;
        final m = demByStuType[sid] ??= <String, Map<String, dynamic>>{};
        // Ordered by due date, so the first one seen is the oldest.
        m.putIfAbsent(ft, () => Map<String, dynamic>.from(d));
      }

      // 4. One row per (advance, fee type). The advance's REMAINING balance is
      //    spent across its own rows in order, so several fee types can never
      //    between them promise more than the advance still holds.
      final built = <_AdjRow>[];
      for (final a in advList) {
        final advId = (a['adv_id'] as num).toInt();
        final stuId = (a['stu_id'] as num).toInt();
        var left = (a['balanceamount'] as num?)?.toDouble() ?? 0;
        final held = heldByAdv[advId] ?? const <String, double>{};
        final byType = demByStuType[stuId] ?? const <String, Map<String, dynamic>>{};

        // A fee type whose share is spent has nothing left to offer, so it is
        // not listed. An advance still carrying a balance always has at least
        // one type with something left.
        final types = held.keys.where((k) => (held[k] ?? 0) > 0.005).toList()..sort();
        for (final ft in types) {
          final d = byType[ft.toUpperCase()];
          final row = _AdjRow(
            stuId: stuId,
            regNo: a['stuadmno']?.toString() ?? '',
            name: a['stuname']?.toString() ?? '',
            className: a['stuclass']?.toString() ?? '',
            advId: advId,
            advNo: a['advno']?.toString() ?? '',
            advBalance: left,
            feeType: ft,
            heldForType: held[ft] ?? 0,
            demId: d == null ? null : (d['dem_id'] as num).toInt(),
            demTerm: d?['demfeeterm']?.toString() ?? '',
            demBalance: (d?['balancedue'] as num?)?.toDouble() ?? 0,
          );
          final take = row.cap;
          row.amount.text = take > 0 ? _plain(take) : '0';
          left -= take;
          built.add(row);
        }
      }
      built.sort((x, y) {
        final r = x.regNo.compareTo(y.regNo);
        return r != 0 ? r : x.feeType.compareTo(y.feeType);
      });

      final adjustable = built.where((r) => r.cap > 0).length;
      if (!mounted) return;
      _replaceRows(built);
      setState(() {
        _picked
          ..clear()
          ..addAll(built.where((r) => r.cap > 0).map((r) => r.key));
        _finding = false;
        _notice = adjustable == 0
            ? 'These advances have nothing to adjust — no pending demand matches '
                'the fee types they were collected for.'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _finding = false;
        _notice = friendlyError(e);
      });
    }
  }


  void _replaceRows(List<_AdjRow> next) {
    for (final r in _rows) {
      r.amount.dispose();
    }
    _rows = next;
  }

  static String _plain(num v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  List<_AdjRow> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows
        .where((r) =>
            '${r.regNo} ${r.name} ${r.advNo} ${r.feeType}'.toLowerCase().contains(q))
        .toList();
  }

  double get _total {
    var sum = 0.0;
    for (final r in _rows) {
      if (_picked.contains(r.key)) sum += r.entered;
    }
    return sum;
  }

  int get _pickedCount => _rows.where((r) => _picked.contains(r.key)).length;

  // ===========================================================================
  // Apply
  // ===========================================================================

  /// Apply every ticked line.
  ///
  /// Grouped by ADVANCE, so one advance covering three fee types is a single
  /// adjust_advance call carrying three lines — one transaction, one document,
  /// and the per-advance balance guard is checked once against the whole set.
  ///
  /// Advances are NOT wrapped together: one refusing (a demand someone just
  /// collected at the counter) must not undo the advances already applied. The
  /// summary names what failed.
  Future<void> _apply() async {
    final todo = _rows.where((r) => _picked.contains(r.key) && r.entered > 0).toList();
    if (todo.isEmpty) {
      setState(() => _notice = 'Tick at least one line with an amount.');
      return;
    }
    for (final r in todo) {
      if (r.entered > r.cap + 0.005) {
        setState(() => _notice =
            '${r.regNo} ${r.name} · ${r.feeType}: ${formatIndianNumber(r.entered)} is more '
            'than the ${formatIndianNumber(r.cap)} available.');
        return;
      }
    }

    final byAdv = <int, List<_AdjRow>>{};
    for (final r in todo) {
      (byAdv[r.advId] ??= []).add(r);
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Adjust ${byAdv.length} Advance${byAdv.length == 1 ? '' : 's'}?'),
        content: Text(
          '${todo.length} fee line${todo.length == 1 ? '' : 's'} · '
          '${formatIndianNumber(_total)} will come off the matching demands.\n\n'
          'This reduces the fee — it is not recorded as a payment and no '
          'receipt is raised. It cannot be undone from this screen.',
          style: AppUI.body.copyWith(color: AppColors.textSecondary, height: 1.45),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply Adjustment'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final auth = context.read<AuthProvider>();
    setState(() {
      _applying = true;
      _notice = null;
    });

    var done = 0;
    var applied = 0.0;
    final failures = <String>[];
    for (final entry in byAdv.entries) {
      final rows = entry.value;
      try {
        await SupabaseService.client.rpc('adjust_advance', params: {
          'p_token': auth.sessionToken,
          'p_adv_id': entry.key,
          'p_lines': [
            for (final r in rows) {'dem_id': r.demId, 'amount': r.entered}
          ],
          'p_created_by': auth.userName,
          // No p_pay_id: an admission advance is not a payment. It rides on no
          // cash receipt and raises none of its own -- the fee simply comes
          // down, and advadjustment is the record.
        });
        done++;
        for (final r in rows) {
          applied += r.entered;
        }
      } catch (e) {
        final r = rows.first;
        failures.add('${r.advNo} — ${r.regNo} ${r.name}: ${friendlyError(e)}');
      }
    }

    if (!mounted) return;
    setState(() => _applying = false);
    if (failures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$done advance${done == 1 ? '' : 's'} adjusted — '
            '${formatIndianNumber(applied)} off the fees.'),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 5),
      ));
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$done Adjusted, ${failures.length} Not Adjusted'),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 320.h, maxWidth: 460.w),
            child: SingleChildScrollView(
              child: Text(failures.join('\n\n'),
                  style: AppUI.body.copyWith(color: AppColors.textSecondary, height: 1.4)),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      );
    }
    await _find();
  }


  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return AppUI.empty(
        title: 'Could not load advance adjustments.',
        why: '$_loadError',
        icon: 'danger',
        action: OutlinedButton(onPressed: _loadMasters, child: const Text('Retry')),
      );
    }
    return Padding(
      padding: EdgeInsets.all(12.w),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: AppUI.card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(),
          const Divider(height: 1, color: AppColors.divider),
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14.h, AppUI.cardPad, 12.h),
            child: _filters(),
          ),
          if (_notice != null)
            Padding(
              padding: EdgeInsets.fromLTRB(AppUI.cardPad, 0, AppUI.cardPad, 10.h),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                decoration: BoxDecoration(
                  color: AppColors.warningBg,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 15.sp, color: AppColors.warning),
                  SizedBox(width: 8.w),
                  Expanded(
                      child: Text(_notice!, style: AppUI.body)),
                ]),
              ),
            ),
          Expanded(child: _grid()),
          const Divider(height: 1, color: AppColors.divider),
          _footer(),
        ]),
      ),
    );
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14.h, AppUI.cardPad, 14.h),
        child: AppUI.cardHeader(
          icon: 'empty-wallet-change',
          title: 'Advance Adjustment',
          subtitle: 'Apply admission advances against one fee type',
        ),
      );

  Widget _filters() => Wrap(spacing: 12.w, runSpacing: 10.h, children: [
        SizedBox(
            width: 210.w,
            child: _labeled(
                schoolTerm('Course'),
                AppDropdownField<String>(
                  key: ValueKey('adjc-${_course ?? ''}'),
                  initialValue: _courseNames.contains(_course) ? _course : null,
                  isExpanded: true,
                  style: _txt,
                  decoration: _dec(schoolTerm('All courses')),
                  items: [
                    DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All courses'))),
                    ..._courseNames.map((s) => DropdownMenuItem(
                        value: s, child: Text(s, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: _applying
                      ? null
                      : (v) {
                          setState(() {
                            _course = v;
                            _className = null;
                          });
                          _find();
                        },
                ))),
        SizedBox(
            width: 190.w,
            child: _labeled(
                schoolTerm('Class'),
                AppDropdownField<String>(
                  key: ValueKey('adjcl-${_course ?? ''}-${_className ?? ''}'),
                  initialValue:
                      _classesFor(_course).contains(_className) ? _className : null,
                  isExpanded: true,
                  style: _txt,
                  decoration: _dec(schoolTerm('All classes')),
                  items: [
                    DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All classes'))),
                    ..._classesFor(_course).map((s) => DropdownMenuItem(
                        value: s, child: Text(s, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: _applying
                      ? null
                      : (v) {
                          setState(() => _className = v);
                          _find();
                        },
                ))),
        // Typed, not a button. The list already reloads whenever Course or
        // Class changes, so 'Find Students' only ever repeated what had just
        // happened; what was missing was a way to pick ONE student out of it.
        SizedBox(
            width: 260.w,
            child: _labeled(
                'Student',
                TextField(
                  controller: _search,
                  style: _txt,
                  decoration: AppUI.field(
                    context,
                    schoolTerm('Search by register no., name, advance no. or fee type'),
                    leadingIcon: 'search-normal',
                    filled: _search.text.isNotEmpty,
                    suffix: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.close,
                                size: 15.sp, color: AppColors.textLight),
                            splashRadius: 14,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ))),
        if (_finding)
          Padding(
            padding: EdgeInsets.only(top: 26.h),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.primary)),
              SizedBox(width: 8.w),
              Text('Searching…', style: AppUI.muted),
            ]),
          ),
      ]);

  Widget _grid() {
    final rows = _visible;
    if (rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to adjust',
        why: 'No student here is holding an admission advance.',
        icon: 'empty-wallet-change',
      );
    }

    final allPicked = rows.every((r) => _picked.contains(r.key));
    return Column(children: [
      Container(
        decoration: AppUI.tableHeadBar,
        padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 10.h),
        child: Row(children: [
          SizedBox(
            width: 34.w,
            child: Checkbox(
              value: allPicked,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: _applying
                  ? null
                  : (v) => setState(() {
                        for (final r in rows) {
                          if (v == true && r.cap > 0) {
                            _picked.add(r.key);
                          } else {
                            _picked.remove(r.key);
                          }
                        }
                      }),
            ),
          ),
          SizedBox(width: 108.w, child: _th(schoolTerm('REGISTER NO.'))),
          Expanded(flex: 3, child: _th('STUDENT')),
          SizedBox(width: 104.w, child: _th(schoolTerm('CLASS'))),
          SizedBox(width: 98.w, child: _th('ADVANCE NO.')),
          Expanded(flex: 3, child: _th('FEE TYPE')),
          SizedBox(width: 96.w, child: _th('ADVANCE (₹)', right: true)),
          SizedBox(width: 96.w, child: _th('DEMAND (₹)', right: true)),
          SizedBox(width: 124.w, child: _th('ADJUST (₹)', center: true)),
          SizedBox(width: 110.w, child: _th('NEW DEMAND (₹)', right: true)),
        ]),
      ),
      Expanded(
        child: Scrollbar(
          controller: _vScroll,
          thumbVisibility: true,
          child: ListView.builder(
            controller: _vScroll,
            itemCount: rows.length,
            itemBuilder: (_, i) => _row(rows[i], i),
          ),
        ),
      ),
    ]);
  }

  Widget _row(_AdjRow r, int i) {
    final on = _picked.contains(r.key);
    final blocked = r.cap <= 0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 7.h),
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        SizedBox(
          width: 34.w,
          child: Checkbox(
            value: on,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (_applying || blocked)
                ? null
                : (v) => setState(() {
                      if (v == true) {
                        _picked.add(r.key);
                        if (r.entered <= 0) r.amount.text = _plain(r.cap);
                      } else {
                        _picked.remove(r.key);
                      }
                    }),
          ),
        ),
        SizedBox(
          width: 108.w,
          child: Text(r.regNo, style: AppUI.cell.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          flex: 3,
          child: Text(r.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUI.cell),
        ),
        SizedBox(
          width: 104.w,
          child: Text(r.className,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
        ),
        SizedBox(
          width: 98.w,
          child: Text(r.advNo,
              style: AppUI.cell.copyWith(fontWeight: FontWeight.w700, color: AppColors.success)),
        ),
        Expanded(
          flex: 3,
          child: Text(r.feeType,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: AppColors.demand)),
        ),
        SizedBox(
          width: 96.w,
          child: Text(r.heldForType > 0 ? formatIndianNumber(r.heldForType) : '—',
              textAlign: TextAlign.right,
              style: AppUI.money.copyWith(fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
        ),
        SizedBox(
          width: 96.w,
          child: Text(r.demId == null ? '—' : formatIndianNumber(r.demBalance),
              textAlign: TextAlign.right,
              style: AppUI.money.copyWith(
                  color: r.demId == null ? AppColors.textLight : AppColors.textPrimary)),
        ),
        SizedBox(
          width: 124.w,
          child: Padding(
            padding: EdgeInsets.only(left: 14.w),
            child: TextField(
              controller: r.amount,
              enabled: !_applying && on && !blocked,
              textAlign: TextAlign.right,
              style: AppUI.fieldText(context, filled: on && !blocked).copyWith(fontWeight: FontWeight.w700),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: AppUI.field(context, '', filled: on, dense: true).copyWith(
                fillColor: (on && !blocked) ? Colors.white : AppColors.surface,
                contentPadding: EdgeInsets.symmetric(horizontal: 9.w, vertical: 9),
              ),
              onChanged: (_) {
                // Clamp to what is actually available, so a typo cannot be sent
                // to the server only to be refused row by row.
                final v = double.tryParse(r.amount.text.trim()) ?? 0;
                if (v > r.cap + 0.005) {
                  final t = _plain(r.cap);
                  r.amount.value = TextEditingValue(
                      text: t, selection: TextSelection.collapsed(offset: t.length));
                }
                setState(() {});
              },
            ),
          ),
        ),
        // What the demand will stand at once this adjustment is applied. The
        // cashier was working it out in their head from two other columns,
        // which is exactly where a fee gets reduced by the wrong amount.
        SizedBox(
          width: 110.w,
          child: Text(
              r.demId == null
                  ? '—'
                  : formatIndianNumber(
                      (r.demBalance - r.entered) < 0 ? 0 : r.demBalance - r.entered),
              textAlign: TextAlign.right,
              style: AppUI.money.copyWith(
                  color: r.demId == null
                      ? AppColors.textLight
                      : (r.entered > 0 ? AppColors.success : AppColors.textPrimary))),
        ),
      ]),
    );
  }

  Widget _footer() {
    final ready = !_applying && _pickedCount > 0 && _total > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(AppUI.cardPad, 12.h, AppUI.cardPad, 12.h),
      child: Row(children: [
        Icon(Icons.check_circle,
            size: 17.sp,
            color: _pickedCount > 0 ? AppColors.primary : AppColors.textLight),
        SizedBox(width: 7.w),
        Text('$_pickedCount of ${_rows.length} fee lines selected', style: AppUI.label),
        const Spacer(),
        Container(
          height: AppUI.controlHeight(context),
          padding: EdgeInsets.symmetric(horizontal: 16.w),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.demand.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.demand.withValues(alpha: 0.30)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const AppIcon('tag', size: 15, color: AppColors.demand),
            SizedBox(width: 8.w),
            Text('Adjusting: ', style: AppUI.caps.copyWith(color: AppColors.textPrimary)),
            Text('₹${_total.toStringAsFixed(0)}',
                style: AppUI.money.copyWith(fontWeight: FontWeight.w800, color: AppColors.demand)),
          ]),
        ),
        SizedBox(width: 12.w),
        ElevatedButton.icon(
          onPressed: ready ? _apply : null,
          icon: _applying
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(Icons.check, size: 17.sp),
          label: Text(_applying ? 'Applying…' : 'Apply Adjustment'),
        ),
      ]),
    );
  }

  // ---- small shared bits ----------------------------------------------------

  TextStyle get _txt => AppUI.fieldText(context);

  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.fieldLabel(label),
          child,
        ],
      );

  Widget _th(String t, {bool right = false, bool center = false}) => Text(
        t.toUpperCase(),
        textAlign: right ? TextAlign.right : (center ? TextAlign.center : TextAlign.left),
        style: AppUI.tableHead,
      );

  InputDecoration _dec(String hint) => AppUI.field(context, hint);
}
