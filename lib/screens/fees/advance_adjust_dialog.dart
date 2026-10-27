import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';

/// PLAN how much of a student's advance goes against which pending demand.
///
/// This dialog WRITES NOTHING. Apply only hands the plan back to Fee
/// Collection, which shows it in the read-only Adjustment column and drops the
/// Collect Amounts to match. The whole thing is committed when the cashier hits
/// Proceed to Pay / Save — so one press settles the advance and takes the
/// remaining cash, and backing out before then leaves the advance untouched.
///
/// The commit itself is adjust_advance(): one transaction that raises a real
/// fee receipt per fee group (paymethod 'Advance Adjustment', payreference =
/// the advance number), settles each demand exactly as a counter collection
/// would, writes the advadjustment rows and draws the advance down.
///
/// COLOUR RULE, matching the collection screens: green carries the money that
/// is already in hand (the advance, what is left of it); blue carries the
/// controls — the ticks, the amount fields and the one button that commits.
///
/// Returns {adv_id, advno, lines:[{dem_id, amount}], total}, or null if the
/// cashier backed out.
Future<Map<String, dynamic>?> showAdvanceAdjustDialog(
  BuildContext context, {
  required Map<String, dynamic> student,
  required List<Map<String, dynamic>> advances,
  required List<Map<String, dynamic>> demands,
  Map<String, double> prefill = const {},
  Map<int, Map<String, double>> breakdown = const {},
  bool preAllocate = true,
  List<Map<String, dynamic>> Function(Map<String, dynamic> advance)? demandsFor,
  String Function(Map<String, dynamic> advance)? scopeOf,
  Map<int, Map<String, double>> initialDrafts = const {},
  int? initialAdvId,
  void Function(Map<String, dynamic> plan)? onApplied,
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AdvanceAdjustDialog(
      student: student,
      advances: advances,
      demands: demands,
      prefill: prefill,
      breakdown: breakdown,
      preAllocate: preAllocate,
      demandsFor: demandsFor,
      scopeOf: scopeOf,
      initialDrafts: initialDrafts,
      initialAdvId: initialAdvId,
      onApplied: onApplied,
    ),
  );
}

class _AdvanceAdjustDialog extends StatefulWidget {
  const _AdvanceAdjustDialog({
    required this.student,
    required this.advances,
    required this.demands,
    required this.prefill,
    required this.breakdown,
    required this.preAllocate,
    this.demandsFor,
    this.scopeOf,
    this.initialDrafts = const {},
    this.initialAdvId,
    this.onApplied,
  });

  final Map<String, dynamic> student;

  /// Advances with something left on them (balanceamount > 0).
  final List<Map<String, dynamic>> advances;

  /// The student's pending demands (balancedue > 0).
  final List<Map<String, dynamic>> demands;

  /// dem_id -> the amount the cashier already typed on the collection screen.
  final Map<String, double> prefill;

  /// adv_id -> {FEE TYPE (upper) -> amount} for an ADMISSION advance. Empty for
  /// a student advance.
  final Map<int, Map<String, double>> breakdown;

  /// The dues the SELECTED advance is allowed to settle.
  ///
  /// Money does not cross fee groups. A MESS advance is banked into the hostel
  /// account, so it can only come off HOSTEL FEES dues; a student or admission
  /// advance is banked into the college account and only comes off the college
  /// dues. Null -- every demand is eligible.
  final List<Map<String, dynamic>> Function(Map<String, dynamic> advance)?
      demandsFor;

  /// Names the group an advance is confined to ("HOSTEL FEES"), for the empty
  /// state. Only consulted when [demandsFor] filters everything out.
  final String Function(Map<String, dynamic> advance)? scopeOf;

  /// A plan already made on the collection screen: adv_id -> (dem_id ->
  /// amount), one entry per advance being spent.
  ///
  /// Reopening the dialog used to start from nothing, so "Change" meant
  /// "start again" -- the cashier lost the split they had just made and had
  /// to rebuild it from memory. With this the dialog opens ON the plan, every
  /// advance's share intact, ready to be adjusted.
  final Map<int, Map<String, double>> initialDrafts;

  /// The advance that plan was made against, so reopening lands on the same
  /// one rather than the oldest.
  final int? initialAdvId;

  /// Called when Apply is pressed, with the staged plan.
  ///
  /// When it is set the dialog STAYS OPEN afterwards -- the same way the Fee
  /// Definition dialog does -- so the cashier can stage another advance or
  /// correct a figure without reopening. Close is then the only way out.
  /// Without it the dialog keeps the old behaviour and pops with the plan.
  final void Function(Map<String, dynamic> plan)? onApplied;

  /// Spread the advance over the dues the moment the dialog opens.
  ///
  /// False at the collection counter: the cashier decides which dues the money
  /// goes against, and a dialog that had already spent it for them was being
  /// accepted as-is. They can still press Auto-fill to get the old behaviour.
  final bool preAllocate;

  @override
  State<_AdvanceAdjustDialog> createState() => _AdvanceAdjustDialogState();
}

class _AdvanceAdjustDialogState extends State<_AdvanceAdjustDialog> {
  final _ctrls = <String, TextEditingController>{};
  final _picked = <String>{};
  final _vScroll = ScrollController();

  late Map<String, dynamic> _advance;
  String? _error;

  /// Something has been staged from this dialog, so Close means "done", not
  /// "cancel". Mirrors _savedAny in the Fee Definition dialog.
  bool _applied = false;

  /// What the last Apply staged, for the confirmation strip.
  String _appliedNote = '';

  /// adv_id -> what the cashier typed against THAT advance.
  ///
  /// The dialog applies one advance at a time, so the grid can only ever show
  /// one advance's amounts. Without this, clicking another receipt to look at
  /// it threw away the split just made -- and the amounts could not simply be
  /// left in place, because they would then be applied to whichever advance
  /// happened to be selected. Each advance keeps its own draft instead, and
  /// coming back restores it.
  final Map<int, Map<String, double>> _drafts = {};

  int get _advId => (_advance['adv_id'] as num?)?.toInt() ?? -1;

  /// Remember the grid as it stands, against the advance it belongs to.
  void _stashDraft() {
    final m = <String, double>{};
    for (final k in _picked) {
      final v = _amt(k);
      if (v > 0) m[k] = v;
    }
    _drafts[_advId] = m;
  }

  /// The dues the advance now selected may be spent on -- see
  /// [_AdvanceAdjustDialog.demandsFor]. Everything the cashier sees, ticks and
  /// applies goes through this, so an advance can never settle a due that
  /// belongs to another fee group.
  List<Map<String, dynamic>> get _demands =>
      widget.demandsFor?.call(_advance) ?? widget.demands;

  @override
  void initState() {
    super.initState();
    _advance = widget.initialAdvId == null
        ? widget.advances.first
        : widget.advances.firstWhere(
            (a) => (a['adv_id'] as num?)?.toInt() == widget.initialAdvId,
            orElse: () => widget.advances.first);
    for (final d in widget.demands) {
      _ctrls[_key(d)] = TextEditingController(text: '0');
    }
    _drafts.addAll({
      for (final e in widget.initialDrafts.entries)
        e.key: Map<String, double>.from(e.value),
    });
    final mine = _drafts[_advId];
    if (mine == null || mine.isEmpty) {
      _allocate();
    } else {
      // Reopened on a plan: restore it exactly, rather than re-spreading the
      // advance and quietly producing a different split.
      for (final e in mine.entries) {
        final c = _ctrls[e.key];
        if (c == null || e.value <= 0) continue;
        c.text = _plain(e.value);
        _picked.add(e.key);
      }
    }
  }

  /// The fee-type breakdown of the selected advance, if it is an ADMISSION
  /// advance. Empty means "a plain amount, spend it oldest-first".
  Map<String, double> get _breakdown =>
      widget.breakdown[(_advance['adv_id'] as num?)?.toInt() ?? -1] ?? const {};

  static String _ft(Map<String, dynamic> d) =>
      (d['demfeetype']?.toString() ?? '').trim().toUpperCase();

  /// Fill the Adjust column for the selected advance.
  ///
  /// ADMISSION advance — the money was collected AGAINST NAMED FEE TYPES, so it
  /// settles those: the TUITION FEE it was taken for goes to the TUITION FEE
  /// demand, not to whatever happens to be oldest. Anything the breakdown
  /// cannot place (a fee type with no matching demand) is left for the cashier
  /// to assign by hand — see _unmatched.
  ///
  /// STUDENT advance — a single amount with nothing to match on, so it fills
  /// the dues oldest-first, which is what the list is already sorted by.
  void _allocate({bool force = false}) {
    for (final d in widget.demands) {
      _ctrls[_key(d)]!.text = '0';
    }
    _picked.clear();
    // Nothing is spent until the cashier says so.
    if (!widget.preAllocate && !force) return;

    var left = _balance(_advance);
    final byType = _breakdown;

    if (byType.isNotEmpty) {
      // Per fee type, so one type's money can never leak into another's demand.
      final pool = Map<String, double>.from(byType);
      for (final d in _demands) {
        if (left <= 0) break;
        final k = _key(d);
        final avail = pool[_ft(d)] ?? 0;
        if (avail <= 0) continue;
        // _capFor, not _due: another advance may already be covering part of
        // this row, and filling to the full due is how a plan ended up giving
        // one fee more than it owes.
        final take = [avail, _capFor(d), left].reduce((a, b) => a < b ? a : b);
        if (take <= 0) continue;
        _ctrls[k]!.text = _plain(take);
        _picked.add(k);
        pool[_ft(d)] = avail - take;
        left -= take;
      }
      return;
    }

    for (final d in _demands) {
      if (left <= 0) break;
      final k = _key(d);
      final cap = _capFor(d);
      final want = (widget.prefill[k] ?? cap).clamp(0.0, cap);
      if (want <= 0) continue;
      final take = want <= left ? want : left;
      _ctrls[k]!.text = _plain(take);
      _picked.add(k);
      left -= take;
    }
  }

  /// Fee types the advance carries that no pending demand matches, with what is
  /// left of each. Shown so a part of the advance going unapplied is explained
  /// rather than silently missing.
  Map<String, double> get _unmatched {
    final byType = _breakdown;
    if (byType.isEmpty) return const {};
    final pool = Map<String, double>.from(byType);
    for (final d in _demands) {
      final k = _key(d);
      final ft = _ft(d);
      if (!pool.containsKey(ft)) continue;
      pool[ft] = (pool[ft] ?? 0) - _amt(k);
    }
    return {
      for (final e in pool.entries)
        if (e.value > 0.005) e.key: e.value
    };
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _vScroll.dispose();
    super.dispose();
  }

  static String _key(Map<String, dynamic> d) => d['dem_id'].toString();

  static double _due(Map<String, dynamic> d) =>
      (d['balancedue'] as num?)?.toDouble() ?? 0;

  static double _balance(Map<String, dynamic> a) =>
      (a['balanceamount'] as num?)?.toDouble() ?? 0;

  static String _plain(num v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  static String _dmy(String ymd) {
    final p = ymd.split('-');
    return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : ymd;
  }

  static String _advDate(Object? v) {
    final s = v?.toString() ?? '';
    final d = DateTime.tryParse(s);
    if (d == null) return s.length >= 10 ? _dmy(s.substring(0, 10)) : s;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  double _amt(String k) => double.tryParse(_ctrls[k]?.text.trim() ?? '') ?? 0;

  double get _total {
    var sum = 0.0;
    for (final k in _picked) {
      sum += _amt(k);
    }
    return sum;
  }

  double get _available => _balance(_advance);

  // ---- responsiveness ----------------------------------------------------
  //
  // The dialog is opened on everything from a 1366x768 laptop to a 4K counter
  // screen, and it used to be a fixed 880x660 box with fixed column widths: on
  // a small window it ran off the bottom, and the summary and footer rows
  // overflowed sideways. Everything below is driven by the live viewport
  // instead.

  /// The window is too narrow for the full-width layout.
  bool get _narrow => MediaQuery.of(context).size.width < 1100;

  /// Column widths, tighter when the window is.
  double get _wDate => _narrow ? 86.w : 110.w;
  double get _wBal => _narrow ? 84.w : 104.w;
  double get _wAdj => _narrow ? 104.w : 132.w;

  /// What the OTHER advances in this plan have already put on one row.
  double _stagedElsewhereOn(String k) {
    var sum = 0.0;
    for (final e in _drafts.entries) {
      if (e.key == _advId) continue;
      sum += e.value[k] ?? 0;
    }
    return sum;
  }

  /// The most THIS advance may still put on a row: what it owes, less what the
  /// other advances are already giving it.
  double _capFor(Map<String, dynamic> d) {
    final left = _due(d) - _stagedElsewhereOn(_key(d));
    return left > 0 ? left : 0;
  }

  /// Everything staged across ALL advances -- what Apply will actually write.
  ///
  /// [_total] is only the advance on screen. With a draft parked on another
  /// receipt, Apply has real work to do even when this grid is empty, and the
  /// button must not sit disabled over it.
  double get _plannedTotal {
    var sum = _total;
    for (final e in _drafts.entries) {
      if (e.key == _advId) continue;
      for (final v in e.value.values) {
        sum += v;
      }
    }
    return sum;
  }

  /// How many advances the plan spends, counting the one on screen.
  int get _plannedCount {
    var n = _total > 0 ? 1 : 0;
    for (final e in _drafts.entries) {
      if (e.key == _advId) continue;
      if (e.value.values.any((v) => v > 0)) n++;
    }
    return n;
  }

  /// An ADMISSION advance was taken from a student joining NEXT year, so there
  /// was no bill to settle at the time. Applying it REDUCES the fee rather than
  /// paying it — feeamount comes down and paidamount is left alone. Only the
  /// wording changes here; the amounts the cashier enters are the same.
  bool get _isAdmission => (_advance['advtype']?.toString() ?? 'S') == 'A';

  /// Re-tick and re-fill from scratch against the advance now selected — each
  /// advance brings its own breakdown, so the split has to be redone.
  void _onAdvanceChanged(Map<String, dynamic> a) {
    if (a['adv_id'] == _advance['adv_id']) return;
    setState(() {
      _stashDraft();
      _advance = a;
      for (final d in widget.demands) {
        _ctrls[_key(d)]?.text = '0';
      }
      _picked.clear();
      final saved = _drafts[_advId];
      if (saved != null && saved.isNotEmpty) {
        for (final e in saved.entries) {
          final c = _ctrls[e.key];
          if (c == null || e.value <= 0) continue;
          c.text = _plain(e.value);
          _picked.add(e.key);
        }
      } else {
        _allocate();
      }
    });
  }

  /// Validate and hand the plan back. Nothing is written here — see the class
  /// doc; the commit happens on Proceed to Pay.
  /// Cut any row the whole plan overpays back to what it owes.
  ///
  /// Reached when two advances were filled independently -- Auto-fill on one,
  /// a figure typed on the other, or a plan restored from the collection
  /// screen. Rather than refusing Apply and leaving the cashier to work out
  /// WHICH receipt to open, the later advances' shares are trimmed and the
  /// dialog says what it changed. Earlier advances in the list keep their
  /// share, so the result is the same however many times it runs.
  ///
  /// Returns one sentence per trim, empty when the plan was already sound.
  List<String> _trimOverAllocations() {
    final notes = <String>[];
    final used = <String, double>{};
    for (final a in widget.advances) {
      final id = (a['adv_id'] as num?)?.toInt() ?? -1;
      final draft = _drafts[id];
      if (draft == null || draft.isEmpty) continue;
      for (final k in draft.keys.toList()) {
        final amt = draft[k] ?? 0;
        if (amt <= 0) continue;
        final d = widget.demands.firstWhere((x) => _key(x) == k,
            orElse: () => const <String, dynamic>{});
        if (d.isEmpty) continue;
        final room = _due(d) - (used[k] ?? 0);
        final keep = amt <= room ? amt : (room > 0 ? room : 0.0);
        if (keep < amt - 0.005) {
          notes.add(
              '${a['advno']}: ${d['demfeetype'] ?? ''} cut from ${formatIndianNumber(amt)} '
              'to ${formatIndianNumber(keep)} — the rest is already covered.');
          if (keep <= 0) {
            draft.remove(k);
          } else {
            draft[k] = keep;
          }
        }
        used[k] = (used[k] ?? 0) + keep;
      }
    }
    return notes;
  }

  /// Put the selected advance's draft back on screen after a trim.
  void _redrawFromDraft() {
    final mine = _drafts[_advId] ?? const <String, double>{};
    for (final d in widget.demands) {
      final k = _key(d);
      final v = mine[k] ?? 0;
      _ctrls[k]?.text = v > 0 ? _plain(v) : '0';
      if (v > 0) {
        _picked.add(k);
      } else {
        _picked.remove(k);
      }
    }
  }

  /// Hand back EVERY advance that has something staged against it, not just
  /// the one on screen.
  ///
  /// Two advances can legitimately pay one bill -- a 5,000 and a 500 against a
  /// 5,500 due -- and the cashier stages them by switching between the two
  /// receipts. Returning only the selected one silently dropped the other.
  void _apply() {
    _stashDraft();
    // Make the plan possible before judging it: the per-row check below is now
    // a backstop, not the thing the cashier has to satisfy by hand.
    final trims = _trimOverAllocations();
    if (trims.isNotEmpty) _redrawFromDraft();
    debugPrint('ADJUST APPLY: drafts='
        '${_drafts.map((k, v) => MapEntry(k, v.length))} '
        'demands=${widget.demands.length}');

    // dem_id -> what the whole plan puts on that row, for the per-row ceiling
    // below: no ROW may take more than it owes, however many advances are
    // sharing it.
    final perRow = <String, double>{};
    final plans = <Map<String, dynamic>>[];
    var grand = 0.0;

    for (final a in widget.advances) {
      final id = (a['adv_id'] as num?)?.toInt() ?? -1;
      final draft = _drafts[id];
      if (draft == null || draft.isEmpty) continue;

      final lines = <Map<String, dynamic>>[];
      var total = 0.0;
      for (final e in draft.entries) {
        if (e.value <= 0) continue;
        final d = widget.demands.firstWhere((x) => _key(x) == e.key,
            orElse: () => const <String, dynamic>{});
        if (d.isEmpty) {
          debugPrint('ADJUST APPLY: draft row ${e.key} is not in the demand '
              'list any more - dropped');
          continue;
        }
        perRow[e.key] = (perRow[e.key] ?? 0) + e.value;
        if (perRow[e.key]! > _due(d) + 0.005) {
          // Name WHO is giving what. The grid shows one advance at a time, so
          // "2,700 on a 2,200 row" is unactionable on its own -- the other
          // contribution is on a receipt the cashier is not looking at.
          final who = <String>[];
          for (final b in widget.advances) {
            final bid = (b['adv_id'] as num?)?.toInt() ?? -1;
            final amt = _drafts[bid]?[e.key] ?? 0;
            if (amt > 0) {
              who.add('${b['advno']} ${formatIndianNumber(amt)}');
            }
          }
          setState(() => _error =
              '"${d['demfeetype'] ?? ''}" owes ${formatIndianNumber(_due(d))} but the plan '
              'gives it ${formatIndianNumber(perRow[e.key]!)} — ${who.join(' + ')}. '
              'Open the receipt that is overpaying it and lower that figure.');
          return;
        }
        lines.add({'dem_id': d['dem_id'], 'amount': e.value});
        total += e.value;
      }
      if (lines.isEmpty) continue;

      if (total > _balance(a) + 0.005) {
        setState(() => _error =
            'Adjusting ${formatIndianNumber(total)} is more than the ${formatIndianNumber(_balance(a))} left on ${a['advno']}.');
        return;
      }
      plans.add({
        'adv_id': a['adv_id'],
        'advno': a['advno']?.toString() ?? '',
        'lines': lines,
        'total': total,
      });
      grand += total;
    }

    if (plans.isEmpty) {
      debugPrint('ADJUST APPLY: nothing to apply');
      setState(() => _error = 'Tick at least one demand and enter an amount.');
      return;
    }
    debugPrint('ADJUST APPLY: popping ${plans.length} plan(s), total $grand');

    final result = <String, dynamic>{'plans': plans, 'total': grand};

    if (widget.onApplied == null) {
      Navigator.of(context).pop(result);
      return;
    }

    // Staged, not written -- and the dialog stays open so the next advance can
    // be staged without reopening. The collection screen has the plan already:
    // its Adjustment column and its Collect Amounts have moved.
    widget.onApplied!(result);
    setState(() {
      _error = null;
      _applied = true;
      _appliedNote =
          'Staged ${formatIndianNumber(grand)} from ${plans.length == 1 ? plans.first['advno'] : '${plans.length} advances'}. '
          'Nothing is written until you take the payment. Adjust and press Apply again, or Close.'
          '${trims.isEmpty ? '' : '\n${trims.join('\n')}'}';
    });
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final remaining = _available - _total;
    final view = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: EdgeInsets.symmetric(
          horizontal: _narrow ? 12.w : 32.w, vertical: _narrow ? 12.h : 28.h),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      child: ConstrainedBox(
        // Never taller or wider than the window it is opened in: a fixed box
        // put the Apply button off-screen on a laptop, which is how "it does
        // not close" can look from the counter.
        constraints: BoxConstraints(
          maxWidth: 880.w < view.width - 24 ? 880.w : view.width - 24,
          maxHeight: 660.h < view.height - 24 ? 660.h : view.height - 24,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _header(),
          Padding(
            padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 14.h),
            child: _advancePicker(),
          ),
          if (_breakdown.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 12.h),
              child: _breakdownStrip(),
            ),
          Flexible(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: _grid(),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20.w, 14.h, 20.w, 0),
            child: _summary(remaining),
          ),
          if (_applied && _error == null)
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 0),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10.r),
                  border:
                      Border.all(color: AppColors.success.withValues(alpha: 0.30)),
                ),
                child: Row(children: [
                  Icon(Icons.check_circle_outline,
                      size: 15.sp, color: AppColors.success),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(_appliedNote,
                        style: TextStyle(
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                  ),
                ]),
              ),
            ),
          if (_error != null)
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 0),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(color: AppColors.error.withValues(alpha: 0.28)),
                ),
                child: Row(children: [
                  Icon(Icons.error_outline, size: 15.sp, color: AppColors.error),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            fontSize: 12.sp, color: AppColors.error, height: 1.35)),
                  ),
                ]),
              ),
            ),
          _footer(remaining),
        ]),
      ),
    );
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(20.w, 18.h, 12.w, 16.h),
        child: Row(children: [
          AppUI.iconTile('empty-wallet-add', color: AppColors.success),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_isAdmission ? 'Apply Admission Advance' : 'Adjust Advance',
                      style: AppUI.cardTitle),
                  SizedBox(height: 2.h),
                  Text(
                    '${widget.student['stuadmno'] ?? ''}  •  ${widget.student['stuname'] ?? ''}',
                    style: AppUI.muted,
                  ),
                ]),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close, size: 21.sp, color: AppColors.textSecondary),
          ),
        ]),
      );

  /// The advance being spent. Green, because this is money already in hand.
  Widget _advanceStrip(Map<String, dynamic> a, {bool selectable = false}) {
    final on = a['adv_id'] == _advance['adv_id'];
    final body = Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: on ? 0.07 : 0.03),
        borderRadius: BorderRadius.circular(11.r),
        border: Border.all(
            color: AppColors.success.withValues(alpha: on ? 0.38 : 0.18),
            width: on ? 1.3 : 1),
      ),
      child: Row(children: [
        if (selectable) ...[
          Icon(on ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16.sp, color: on ? AppColors.success : AppColors.textLight),
          SizedBox(width: 9.w),
        ] else ...[
          const AppIcon('empty-wallet-add', size: 17, color: AppColors.success),
          SizedBox(width: 10.w),
        ],
        Text(a['advno']?.toString() ?? '',
            style: TextStyle(
                fontSize: 13.5.sp,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        SizedBox(width: _narrow ? 10.w : 16.w),
        // The middle of the strip is the first thing to give on a narrow
        // window: the receipt number, the money left and the scope chip are
        // what the cashier picks by.
        if (!_narrow) ...[
          Text('taken ${formatIndianNumber((a['transtotalamount'] as num?) ?? 0)}',
              style: TextStyle(fontSize: 12.5.sp, color: AppColors.textSecondary)),
          SizedBox(width: 12.w),
          Flexible(
            child: Text('on ${_advDate(a['advdate'])}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5.sp, color: AppColors.textSecondary)),
          ),
        ] else
          const Spacer(),
        SizedBox(width: 12.w),
        Text('${formatIndianNumber(_balance(a))} available',
            style: TextStyle(
                fontSize: 14.sp, fontWeight: FontWeight.w800, color: AppColors.success)),
        // Which dues this one is allowed to settle. Without it, a mess advance
        // and a student advance look identical in the picker.
        if (widget.scopeOf != null) ...[
          SizedBox(width: 10.w),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6.r),
            ),
            child: Text(widget.scopeOf!(a),
                style: TextStyle(
                    fontSize: 10.5.sp,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: AppColors.success)),
          ),
        ],
      ]),
    );
    if (!selectable) return body;
    return InkWell(
      onTap: () => _onAdvanceChanged(a),
      borderRadius: BorderRadius.circular(11.r),
      child: body,
    );
  }

  Widget _advancePicker() {
    if (widget.advances.length == 1) return _advanceStrip(_advance);
    // More than one open advance: spend one at a time, oldest first by default.
    return Column(
      children: [
        for (final a in widget.advances) ...[
          _advanceStrip(a, selectable: true),
          if (a != widget.advances.last) SizedBox(height: 7.h),
        ],
      ],
    );
  }

  /// An ADMISSION advance was collected against named fee types. Showing them
  /// makes the split below self-explanatory, and names anything that could not
  /// be placed — a fee type with no pending demand — instead of leaving the
  /// cashier to work out why part of the advance was not applied.
  Widget _breakdownStrip() {
    final unmatched = _unmatched;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 13.w, vertical: 11.h),
      decoration: BoxDecoration(
        color: AppColors.demand.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(11.r),
        border: Border.all(color: AppColors.demand.withValues(alpha: 0.22)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const AppIcon('tag', size: 14, color: AppColors.demand),
          SizedBox(width: 8.w),
          Text('COLLECTED AGAINST',
              style: TextStyle(
                  fontSize: 10.5.sp,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: AppColors.demand)),
        ]),
        SizedBox(height: 8.h),
        Wrap(
          spacing: 8.w,
          runSpacing: 6.h,
          children: [
            for (final e in _breakdown.entries)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 5.h),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20.r),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text('${e.key}  ${formatIndianNumber(e.value)}',
                    style: TextStyle(
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
              ),
          ],
        ),
        if (unmatched.isNotEmpty) ...[
          SizedBox(height: 9.h),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14.sp, color: AppColors.warning),
            SizedBox(width: 7.w),
            Expanded(
              child: Text(
                'No pending demand for '
                '${unmatched.entries.map((e) => '${e.key} (${formatIndianNumber(e.value)})').join(', ')}'
                ' — assign it by hand if it should still be used.',
                style: TextStyle(
                    fontSize: 11.sp, color: AppColors.textSecondary, height: 1.35),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _grid() {
    if (_demands.isEmpty) {
      // Two different situations, and the cashier has to be able to tell them
      // apart: nothing is due at all, or nothing is due IN THE GROUP this
      // advance belongs to.
      final scope = widget.demands.isEmpty ? null : widget.scopeOf?.call(_advance);
      return AppUI.empty(
        title: 'Nothing to adjust against',
        icon: 'empty-wallet-add',
        why: scope == null
            ? 'This student has no pending demand to adjust against.'
            : 'This advance can only be adjusted against $scope — '
                'nothing is pending there.',
      );
    }
    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.fromLTRB(14.w, 11.h, 14.w, 11.h),
          child: Row(children: [
            SizedBox(width: 34.w),
            Expanded(flex: 3, child: _h(schoolTerm('SEMESTER'))),
            Expanded(flex: 5, child: _h('FEE TYPE')),
            SizedBox(width: _wDate, child: _h('DUE DATE')),
            SizedBox(width: _wBal, child: _h('BALANCE (₹)', right: true)),
            SizedBox(
              width: _wAdj,
              child: _h(_isAdmission ? 'REDUCE BY (₹)' : 'ADJUST (₹)', center: true)),
          ]),
        ),
        Flexible(
          // Its own attached controller, or the scrollbar is not draggable.
          child: Scrollbar(
            controller: _vScroll,
            thumbVisibility: _demands.length > 5,
            child: ListView.builder(
              controller: _vScroll,
              shrinkWrap: true,
              itemCount: _demands.length,
              itemBuilder: (_, i) => _row(_demands[i], i),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _h(String t, {bool right = false, bool center = false}) => Text(
        t,
        textAlign: right ? TextAlign.right : (center ? TextAlign.center : TextAlign.left),
        style: AppUI.tableHead,
      );

  Widget _row(Map<String, dynamic> d, int i) {
    final k = _key(d);
    final on = _picked.contains(k);
    final due = d['duedate']?.toString() ?? '';
    return Container(
      padding: EdgeInsets.fromLTRB(14.w, 7.h, 14.w, 7.h),
      decoration: BoxDecoration(
        color: Colors.white,
        border: i == _demands.length - 1
            ? null
            : const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        SizedBox(
          width: 34.w,
          child: Transform.scale(
            scale: 1.05,
            child: Checkbox(
              value: on,
              activeColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5.r)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => setState(() {
                        if (v == true) {
                          _picked.add(k);
                          // The room LEFT on the row: another advance may
                          // already be covering part of it, and filling the
                          // whole due would overshoot between them.
                          if (_amt(k) <= 0) _ctrls[k]!.text = _plain(_capFor(d));
                        } else {
                          _picked.remove(k);
                          _ctrls[k]!.text = '0';
                        }
                      }),
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(d['demfeeterm']?.toString() ?? '-',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5.sp,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
        ),
        Expanded(
          flex: 5,
          child: Builder(builder: (_) {
            final fromAdvance = _breakdown[_ft(d)];
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(d['demfeetype']?.toString() ?? '-',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12.5.sp, color: AppColors.textPrimary)),
                  // Only on an admission advance, and only where the fee type
                  // actually matches — it explains where the figure came from.
                  if (fromAdvance != null && fromAdvance > 0)
                    Text('advance holds ${formatIndianNumber(fromAdvance)} for this',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.sp,
                            fontWeight: FontWeight.w600,
                            color: AppColors.demand)),
                ]);
          }),
        ),
        SizedBox(
          width: _wDate,
          child: Text(due.length >= 10 ? _dmy(due.substring(0, 10)) : due,
              style: TextStyle(fontSize: 12.5.sp, color: AppColors.textSecondary)),
        ),
        SizedBox(
          width: _wBal,
          child: Text(formatIndianNumber(_due(d)),
              textAlign: TextAlign.right,
              style: AppUI.money),
        ),
        SizedBox(
          width: _wAdj,
          child: Padding(
            padding: EdgeInsets.only(left: 16.w),
            child: TextField(
              controller: _ctrls[k],
              enabled: on,
              textAlign: TextAlign.right,
              style: AppUI.fieldText(context, filled: on)
                  .copyWith(color: on ? null : AppColors.textLight),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: AppUI.field(context, '', filled: on, dense: true)
                  .copyWith(fillColor: on ? Colors.white : AppColors.surface),
              onChanged: (_) => setState(() {
                // Caught at Apply before, which is late: the cashier had typed
                // a whole split by then. Cap here and say why.
                final cap = _capFor(d);
                if (_amt(k) > cap + 0.005) {
                  _ctrls[k]!.text = _plain(cap);
                  _ctrls[k]!.selection =
                      TextSelection.collapsed(offset: _ctrls[k]!.text.length);
                  final other = _stagedElsewhereOn(k);
                  _error = other > 0
                      ? 'Only ${formatIndianNumber(cap)} is left on "${d['demfeetype'] ?? ''}" — '
                          '${formatIndianNumber(other)} of it is already coming from another advance.'
                      : 'Only ${formatIndianNumber(cap)} is due on "${d['demfeetype'] ?? ''}".';
                } else {
                  _error = null;
                }
              }),
            ),
          ),
        ),
      ]),
    );
  }

  /// Running totals. "Left on …" is the number the cashier is really watching,
  /// so it stays green until the adjustment would overspend the advance.
  Widget _summary(double remaining) {
    final over = remaining < -0.005;

    // Sized, not Expanded: these sit in a Wrap now, and "Staged elsewhere"
    // appears only sometimes -- with Expanded cells a fourth column pushed the
    // row off its own edge.
    Widget cell(String label, String value, Color color) => ConstrainedBox(
          constraints: BoxConstraints(minWidth: _narrow ? 118.w : 150.w),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                SizedBox(height: 4.h),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: _narrow ? 17.sp : 20.sp,
                        fontWeight: FontWeight.w800,
                        color: color)),
              ]),
        );

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 18.w, vertical: 14.h),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Wrap(
        spacing: 18.w,
        runSpacing: 12.h,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
        cell(_isAdmission ? 'Total Reducing' : 'Total Adjusting', '₹${_plain(_total)}',
            over ? AppColors.error : AppColors.textPrimary),
        // Staged on the other receipts and not visible in this grid. Without
        // it the totals here look like the whole plan, and they are not.
        if (_plannedTotal - _total > 0.005)
          cell('Staged elsewhere', '₹${_plain(_plannedTotal - _total)}',
              AppColors.demand),
        cell('Left on ${_advance['advno']}', '₹${_plain(remaining < 0 ? 0 : remaining)}',
            over ? AppColors.error : AppColors.success),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: _narrow ? 190.w : 260.w),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 13.w, vertical: 11.h),
            decoration: BoxDecoration(
              color: (over ? AppColors.error : AppColors.success).withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(10.r),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(over ? Icons.error_outline : Icons.pie_chart_outline,
                  size: 17.sp, color: over ? AppColors.error : AppColors.success),
              SizedBox(width: 9.w),
              Flexible(
                child: Text(
                  over
                      ? 'That is more than this advance has left.'
                      : (_isAdmission
                          ? 'Fees below will be REDUCED\nby these amounts.'
                          : 'Advance will be adjusted\nagainst the selected dues.'),
                  style: TextStyle(
                      fontSize: 11.5.sp,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                      color: over ? AppColors.error : AppColors.textPrimary),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _footer(double remaining) {
    final over = remaining < -0.005;
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 16.h, 20.w, 18.h),
      // Wrap, not Row: Auto-fill / Clear on the left and Cancel / Apply on the
      // right no longer fit one line on a narrow window, and the Apply button
      // is the one control that must never be pushed out of reach.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8.w,
        runSpacing: 10.h,
        children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        // The old behaviour, on request rather than by default: spend the
        // advance down the dues, oldest first.
        TextButton.icon(
          onPressed: () => setState(() {
            _allocate(force: true);
            _stashDraft();
            if (_trimOverAllocations().isNotEmpty) _redrawFromDraft();
          }),
          icon: Icon(Icons.auto_fix_high, size: 16.sp),
          label: const Text('Auto-fill'),
        ),
        SizedBox(width: 8.w),
        TextButton.icon(
          onPressed: () => setState(() {
            for (final d in widget.demands) {
              _ctrls[_key(d)]!.text = '0';
            }
            _picked.clear();
          }),
          icon: Icon(Icons.clear_all, size: 16.sp),
          label: const Text('Clear'),
        ),
        ]),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12.w, children: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_applied ? 'Close' : 'Cancel'),
        ),
        SizedBox(width: 12.w),
        ElevatedButton.icon(
          onPressed: (over || _plannedTotal <= 0) ? null : _apply,
          icon: Icon(Icons.check, size: AppBtn.iconSize(context)),
          label: Text(_isAdmission
              ? 'Reduce Fees by ₹${_plain(_plannedTotal)}'
              : 'Apply ₹${_plain(_plannedTotal)}'
                  '${_plannedCount > 1 ? ' · $_plannedCount advances' : ''}'),
        ),
        ]),
      ]),
    );
  }
}
