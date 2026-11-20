import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/formatters.dart';
import '../../utils/receipt_pdf.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/missing_sequence_dialog.dart';
import '../../services/supabase_service.dart';
import '../../services/paytm_service.dart';
import '../../widgets/paytm_checkout_dialog.dart';
import '../../services/online_payment_service.dart';
import '../../widgets/gateway_checkout_dialog.dart';
import '../../utils/payment_gateways.dart';
import '../../widgets/receipt_widget.dart';
import '../../widgets/receipt_preview.dart';
import 'student_fee_definition_dialog.dart';
import 'advance_adjust_dialog.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';
import '../../widgets/focusable_tap.dart';
import '../../utils/class_sort.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../utils/save_path.dart';
// Class ordering (course, then year) lives in utils/class_sort.dart -> classCompare.

const _termOrder = [
  'I TERM', 'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER',
  'II TERM', 'NOVEMBER', 'DECEMBER', 'JANUARY', 'FEBRUARY',
  'III TERM', 'III term', 'MARCH', 'APRIL', 'April',
];

int _termIndex(String t) {
  final idx = _termOrder.indexWhere((x) => x.toLowerCase() == t.toLowerCase());
  return idx >= 0 ? idx : _termOrder.length;
}

class StudentFeeCollectionScreen extends StatefulWidget {
  final VoidCallback? onNavigateToTransactions;
  const StudentFeeCollectionScreen({super.key, this.onNavigateToTransactions});

  @override
  State<StudentFeeCollectionScreen> createState() =>
      _StudentFeeCollectionScreenState();
}

class _StudentFeeCollectionScreenState
    extends State<StudentFeeCollectionScreen> {
  final _admNoController = TextEditingController();
  final _nameController = TextEditingController();
  final _classController = TextEditingController();
  final _remarksController = TextEditingController();
  final _chequeNoController = TextEditingController();
  final _upiRefController = TextEditingController();
  // Cash mode: cashier enters the tender amount; refund is computed.
  final _tenderAmountController = TextEditingController();
  double? _cashTenderAmount;
  double? _cashRefundAmount;
  final _chequeDateController = TextEditingController();
  final _bankNameController = TextEditingController();
  DateTime? _chequeDate;
  List<Map<String, dynamic>> _studentSuggestions = [];
  final LayerLink _admSearchLink = LayerLink();
  List<String> _courseList = [];
  String? _selectedCourse;
  List<String> _classList = [];
  List<String> _allClasses = [];
  Map<String, int> _classOrdid = {}; // claname(upper) -> course.ordid*N + class.ordid
  Map<String, List<String>> _courseClassMap = {};
  String? _selectedClass;
  List<Map<String, dynamic>> _classSuggestions = [];

  /// stu_id -> total outstanding across that student's active fee demands.
  /// 0 means billed but fully paid (shown as PAID in the lookup); a missing
  /// entry means their demands haven't been loaded yet.
  final Map<int, double> _balanceByStu = {};


  bool _searching = false;
  String? _errorMsg;

  /// dem_id -> the amount of an advance the cashier has PLANNED against this
  /// demand but not yet committed. Filled by the Adjust Advance dialog, shown
  /// in the Adjustment column, and written by adjust_advance the moment they
  /// press Proceed to Pay / Save. Abandoning the screen leaves the advance
  /// untouched, which is the point of planning rather than writing on Apply.
  final Map<String, double> _pendingAdjust = {};
  /// The advances this plan spends, in the order the dialog returned them.
  ///
  /// Two advances can legitimately share one bill -- 5,000 from one and 500
  /// from another against a 5,500 due -- so the plan is a LIST. Each is
  /// committed on its own adjust_advance call and gets its own adjustment
  /// receipt, exactly as a single one always did.
  final List<_PlannedAdvance> _pendingPlans = [];

  /// The first staged advance, for the routing question "which of today's
  /// receipts does this adjustment belong on".
  int? get _pendingAdvId =>
      _pendingPlans.isEmpty ? null : _pendingPlans.first.advId;

  /// All staged receipt numbers, for the banner and the row tooltips.
  String get _pendingAdvNo => _pendingPlans.map((p) => p.advNo).join(', ');


  /// True while the plan is spending an ADMISSION advance, which reduces the
  /// fee instead of paying it (see adjust_advance).
  ///
  /// It decides more than wording: an admission advance is written on its own
  /// document BEFORE the cash is taken, while a student advance attaches to the
  /// cash receipt afterwards. Both leave balancedue lower by the same amount,
  /// so the Collect Amount arithmetic is identical either way.
  bool get _pendingAdvIsAdmission {
    if (_pendingPlans.isEmpty) return false;
    for (final a in _advances) {
      if ((a['adv_id'] as num?)?.toInt() == _pendingAdvId) {
        return (a['advtype']?.toString() ?? 'S') == 'A';
      }
    }
    return false;
  }

  double get _pendingAdjustTotal {
    var sum = 0.0;
    for (final v in _pendingAdjust.values) {
      sum += v;
    }
    return sum;
  }

  /// dem_id -> how much of THIS demand has already been PAID out of a STUDENT
  /// advance. Read-only: it is written by adjust_advance, never typed. A demand
  /// only appears in the pending list while something is still owed on it, so a
  /// figure here means the advance covered part of the row.
  ///
  /// An ADMISSION advance is deliberately excluded. It does not settle the
  /// balance, it REDUCES the bill -- feeamount comes down and the smaller
  /// figure is already on screen in FEE AMT. Showing it here as well said the
  /// same money twice: a 42,500 fee with 5,000 still owed listed a 40,000
  /// ADJUSTMENT beside it, as though 45,000 had been dealt with.
  final Map<String, double> _adjustedByDem = {};

  /// Advances this student still has money left on (balanceamount > 0), newest
  /// first. Non-empty => the banner above the demands list lights up and the
  /// cashier can spend it here. Money taken on the Advance Collection screen
  /// is only ever SPENT from here, manually.
  List<Map<String, dynamic>> _advances = [];

  /// ADMISSION advances this student still has money left on. Shown here as a
  /// notice only — it is NOT spendable at this counter. An admission advance
  /// reduces the fee itself rather than paying a demand, so it is applied on
  /// the Advance Adjustment screen; leaving it out of _advances keeps the
  /// cashier from treating it as money toward today's bill.
  List<Map<String, dynamic>> _admissionAdvances = [];

  Map<String, dynamic>? _student;
  Map<String, dynamic>? _parent;

  List<Map<String, dynamic>> _allDemands = [];
  bool _loadingDemands = false;

  String? _selectedTerm; // null = All
  // Arrear-only: collect one arrear YEAR at a time (null = all arrear years).
  // Scopes the list, selection, totals and the receipt to the chosen year.
  String? _selectedArrearYear;

  // Regular vs Arrear collection. Students pay arrear and regular fees on
  // SEPARATE receipts, so the pending list, selection, totals and payment are
  // all scoped to one demseqtype at a time. Default 'REGULAR' (covers
  // demseqtype REGULAR/DEMAND/blank); switch to 'ARREAR' via the header toggle.
  String _seqType = 'REGULAR';
  // Utilities setting (fee_collection_arrear_first): when true, a student with
  // arrear dues opens on Arrear so arrears are cleared before regular fees.
  bool _arrearFirst = true;

  bool _isArrear(Map<String, dynamic> d) =>
      (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
  bool get _hasArrear => _allDemands.any(_isArrear);
  bool get _hasRegular => _allDemands.any((d) => !_isArrear(d));
  // The student still owes arrear (any arrear demand with a positive balance).
  bool get _arrearOutstanding => _allDemands.any(
      (d) => _isArrear(d) && ((d['balancedue'] as num?)?.toDouble() ?? 0) > 0);
  // Regular collection is locked while arrear is unpaid, when the arrear-first
  // Utilities toggle is on.
  bool get _regularLocked => _arrearFirst && _arrearOutstanding;
  bool _matchesSeqType(Map<String, dynamic> d) =>
      _seqType == 'ARREAR' ? _isArrear(d) : !_isArrear(d);
  List<Map<String, dynamic>> get _currentTypeDemands {
    var list = _allDemands.where(_matchesSeqType);
    // In Arrear mode, optionally scope to one selected year so that year's
    // collection (and its receipt) covers just that year.
    if (_seqType == 'ARREAR' && _selectedArrearYear != null) {
      final y = _selectedArrearYear;
      list = list.where((d) => (d['demfeeyear']?.toString() ?? '') == y);
    }
    return list.toList();
  }

  /// Distinct arrear years (demfeeyear) for the current student, oldest first —
  /// drives the Arrear-mode Year dropdown.
  List<String> get _arrearYears {
    final seen = <String>{};
    for (final d in _allDemands) {
      if (!_isArrear(d)) continue;
      final y = (d['demfeeyear']?.toString() ?? '').trim();
      if (y.isNotEmpty) seen.add(y);
    }
    return seen.toList()..sort();
  }

  /// Pick an arrear year (null = all years); re-scopes selection + Col Amounts
  /// to the chosen year, mirroring _switchSeqType.
  void _selectArrearYear(String? year) {
    setState(() {
      _selectedArrearYear = year;
      _selectedTerm = null;
      _selected.clear();
      for (final d in _allDemands) {
        final k = _demKey(d);
        final inScope = _matchesSeqType(d) &&
            _inPayGroup(d) &&
            (year == null || (d['demfeeyear']?.toString() ?? '') == year);
        final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
        _conCtrl[k]?.text = (inScope && bal > 0) ? bal.toStringAsFixed(0) : '0';
        if (inScope && bal > 0) _selected.add(k);
      }
    });
  }
  // Payment mode — null = nothing selected yet. The cashier picks one via
  // the inline chips in the bottom bar before the action button is enabled.
  String? _paymentMode;

  /// The school's gateway from Setup > Payment Gateways, or null when none is
  /// set up. When there is one, 'Online' replaces the old Paytm mode.
  OnlineGateway? _onlineGateway;

  /// Paytm and the Setup gateways both open a gateway window.
  bool get _isGatewayMode => _paymentMode == 'Paytm' || _paymentMode == 'Online';

  // Fee-group lookup for the demand table's group headers (see
  // _loadFeeGroupMap): fee type name -> fg_id, fg_id -> fee group name.
  final Map<String, int> _fgOfFeeType = {};
  final Map<int, String> _fgName = {};
  // fg_id -> can this group actually be collected? A group with no bank
  // account mapped, or no payment sequence, is refused by _ensureSequencesExist
  // the moment a mode is picked -- and it refuses the WHOLE collection, other
  // groups included. The card says so up front instead.
  final Set<int> _fgWithoutBank = {};
  final Set<int> _fgWithoutSeq = {};
  // School: arrear fees are receipted from their own series, one per group.
  final Set<int> _fgWithoutArrearSeq = {};

  /// The fee group cannot be receipted for the kind of fee on screen.
  bool _seqMissing(int fg) =>
      isSchool && _seqType == 'ARREAR' ? _fgWithoutArrearSeq.contains(fg) : _fgWithoutSeq.contains(fg);

  /// Fee groups that have an arrear receipt series (division 'FG:<fg_id>').
  static Set<int> _arrearSeriesGroups(List rows) => {
        for (final q in rows)
          if (q['actname'] == 'ARRFEENO') int.tryParse('${q['division'] ?? ''}'.replaceFirst('FG:', '')) ?? -1,
      };
  // fg_id -> the bank account the group is mapped to. Also names the Paytm
  // merchant an online payment of that group settles into (bank.paytm_mid).
  final Map<int, int> _fgBankId = {};

  /// Institution settings, for the per-fee-group receipt letterhead: a hostel
  /// receipt is issued by the hostel, not by the college.
  Map<String, String> _settings = const {};
  /// The fee group being collected RIGHT NOW. One payment settles one group:
  /// process_grouped_payment raises a receipt per group, from that group's own
  /// sequence and into that group's bank account, and an online payment can
  /// only be signed with one merchant. So the counter collects a group at a
  /// time -- college first, then hostel -- instead of quietly splitting one
  /// tender across two receipts and two accounts.
  int? _payFgId;

  // Per-row controllers: keyed by dem_id
  final Map<String, TextEditingController> _fineCtrl = {};
  final Map<String, TextEditingController> _conCtrl = {};
  // Persistent FocusNodes per row so a setState that rebuilds the row table
  // doesn't make the active TextField lose focus mid-typing.
  final Map<String, FocusNode> _fineFocus = {};
  final Map<String, FocusNode> _conFocus = {};
  // Debounce the auto-check setState — pure typing within a row shouldn't
  // rebuild the table on every keystroke (which loses focus). A short pause
  // (~350ms) after the last digit triggers the actual selection flip.
  final Map<String, Timer> _conFlipTimers = {};
  // Debounces the student search so we don't fire 2 DB round-trips per keystroke.
  Timer? _searchDebounce;
  final _HeldAwareSet _selected = _HeldAwareSet();
  List<Map<String, dynamic>> _fineRules = [];

  /// Session token for gating the payment write RPCs. Null before the security
  /// migrations are run (→ helpers fall back to the legacy RPCs, non-breaking).
  String? get _sessionToken {
    try { return context.read<AuthProvider>().sessionToken; } catch (_) { return null; }
  }

  // Cached in didChangeDependencies so dispose() — where the element is
  // deactivated and context lookups throw "deactivated widget's ancestor" —
  // can still reach institution id / token for the fine-reset-on-exit.
  int? _cachedInsId;
  String? _cachedToken;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      final auth = context.read<AuthProvider>();
      _cachedInsId = auth.insId;
      _cachedToken = auth.sessionToken;
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _fetchClasses();
    _loadFineRules();
    _sweepOrphanedPayments();
    _loadOnlineGateway();
    _loadUtilSettings();
    _loadFeeGroupMap();
  }

  /// Fee type -> fee group, and fee group -> name/order.
  ///
  /// The demand rows carry only demfeetype, but college and hostel fees are
  /// collected separately: process_grouped_payment raises ONE payment per fee
  /// group, numbered from that group's own sequence and stamped with that
  /// group's bank account. The table says so up front by breaking the rows
  /// under a header per group, so the cashier sees the two receipts coming
  /// before they save, not after.
  Future<void> _loadFeeGroupMap() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    try {
      _settings = await SupabaseService.getInstitutionSettings(insId);
      final groups = await SupabaseService.fromSchema('feegroup')
          .select('fg_id, fgdesc, ban_id')
          .eq('ins_id', insId);
      final seqs = await SupabaseService.fromSchema('sequence')
          .select('fg_id, actname, division')
          .eq('ins_id', insId)
          .eq('activestatus', 1) // a deleted series does not count
          .neq('actname', 'REGNO');
      final types = await SupabaseService.fromSchema('feetype')
          .select('feedesc, fg_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      if (!mounted) return;
      setState(() {
        _fgName
          ..clear()
          ..addEntries([
            for (final g in (groups as List))
              if (g['fg_id'] is int)
                MapEntry(g['fg_id'] as int,
                    (g['fgdesc']?.toString() ?? '').trim().toUpperCase()),
          ]);
        final seqFgIds = {
          for (final q in (seqs as List))
            if (q['fg_id'] is int) q['fg_id'] as int,
        };
        _fgBankId
          ..clear()
          ..addEntries([
            for (final g in (groups as List))
              if (g['fg_id'] is int && g['ban_id'] is int)
                MapEntry(g['fg_id'] as int, g['ban_id'] as int),
          ]);
        _fgWithoutBank
          ..clear()
          ..addAll([
            for (final g in (groups as List))
              if (g['fg_id'] is int && g['ban_id'] == null) g['fg_id'] as int,
          ]);
        _fgWithoutSeq
          ..clear()
          ..addAll([
            for (final g in (groups as List))
              if (g['fg_id'] is int && !seqFgIds.contains(g['fg_id']))
                g['fg_id'] as int,
          ]);
        final arrearFgs = _arrearSeriesGroups(seqs);
        _fgWithoutArrearSeq
          ..clear()
          ..addAll([
            for (final g in groups)
              if (g['fg_id'] is int && !arrearFgs.contains(g['fg_id'])) g['fg_id'] as int,
          ]);
        _fgOfFeeType
          ..clear()
          ..addEntries([
            for (final t in (types as List))
              if (t['fg_id'] is int)
                MapEntry((t['feedesc']?.toString() ?? '').trim().toUpperCase(),
                    t['fg_id'] as int),
          ]);
      });
    } catch (_) {
      // Grouping is presentation only -- a failed lookup just shows one
      // "OTHER FEES" block, it never blocks a collection.
    }
  }

  /// One fee group's card: its own heading, its own column header, its own
  /// rows and its own subtotal. The cashier sees the receipts they are about
  /// to raise, one card each, before any money is taken.
  Widget _buildGroupCard(_FgBlock b) {
    final color = b.color;
    final payable = b.rows.where((d) => _collectCap(d) > 0).toList();
    final allSelected = payable.isNotEmpty &&
        payable.every((d) => _selected.contains(_demKey(d)));
    // Is this the group being collected? Only one card is live at a time --
    // one payment, one receipt, one bank account.
    final live = _payFgId == null || b.fgId == _payFgId;

    return Container(
      margin: EdgeInsets.only(bottom: 14.h),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppUI.controlRadius + 2),
        // The live card is outlined in its own colour and lifted; a waiting
        // one is flat and grey, so which group the money is going to is
        // obvious from across the counter.
        border: Border.all(
            color: live ? color : AppColors.border,
            width: live ? 1.4 : 1),
        boxShadow: live
            ? [
                BoxShadow(
                    color: color.withValues(alpha: 0.10),
                    blurRadius: 10,
                    offset: const Offset(0, 2)),
              ]
            : null,
      ),
      child: Column(
        children: [
          // ---- heading: which group, how many dues, what it comes to -------
          Container(
            color: live
                ? color.withValues(alpha: 0.10)
                : AppColors.surface,
            padding: EdgeInsets.fromLTRB(12.w, 9.h, 14.w, 9.h),
            child: Row(
              children: [
                Container(
                  width: 28.w,
                  height: 28.w,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(7.r),
                    border: Border.all(color: color.withValues(alpha: 0.35)),
                  ),
                  child: AppIcon(b.icon,
                      size: 15.sp, color: live ? color : AppColors.textLight),
                ),
                SizedBox(width: 10.w),
                Text(b.label,
                    style: TextStyle(
                        fontSize: 13.5.sp,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color: live ? color : AppColors.textSecondary)),
                SizedBox(width: 6.w),
                Text('(${b.rows.length} item${b.rows.length == 1 ? '' : 's'})',
                    style: TextStyle(
                        fontSize: 11.5.sp,
                        fontWeight: FontWeight.w600,
                        color: live
                            ? color.withValues(alpha: 0.75)
                            : AppColors.textLight)),
                SizedBox(width: 10.w),
                if (live)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6.r),
                    ),
                    child: Text('COLLECTING NOW',
                        style: TextStyle(
                            fontSize: 9.5.sp,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                            color: Colors.white)),
                  )
                else
                  // Switching is explicit, and it says what it costs: the
                  // other group's staged amounts go. Nothing is taken twice
                  // and nothing is silently carried across.
                  OutlinedButton.icon(
                    onPressed: () => _switchPayGroup(b.fgId, selectAll: true),
                    icon: Icon(Icons.swap_horiz, size: 14.sp),
                    label: Text('Collect This Group',
                        style: TextStyle(
                            fontSize: 11.sp, fontWeight: FontWeight.w700)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: color,
                      side: BorderSide(color: color.withValues(alpha: 0.45)),
                      backgroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.symmetric(horizontal: 10.w),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7.r)),
                    ),
                  ),
                // Told here, not by a snackbar after a mode is picked: no
                // receipt sequence stops the collection; no bank account
                // leaves Cash only.
                if (_fgWithoutBank.contains(b.fgId) ||
                    _seqMissing(b.fgId)) ...[
                  SizedBox(width: 10.w),
                  Tooltip(
                    message: _fgWithoutBank.contains(b.fgId)
                        ? 'No bank account is mapped to ${b.label}, so only Cash can be collected. '
                            'Map one in Setup → Fee Master → Fee Group '
                            'for UPI, Online, Cheque or DD.'
                        : isSchool && _seqType == 'ARREAR'
                            ? 'No arrear receipt sequence for ${b.label}. Create one in '
                                'Setup → Sequence Master → Arrear Receipt No.'
                            : 'No receipt sequence for ${b.label}. Create one in '
                                'Setup → Sequence Master → Receipt No.',
                    child: Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
                      decoration: BoxDecoration(
                        color: AppColors.warningBg,
                        borderRadius: BorderRadius.circular(6.r),
                        border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.45)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 13.sp, color: AppColors.warning),
                        SizedBox(width: 4.w),
                        Text(
                            _fgWithoutBank.contains(b.fgId)
                                ? 'No Bank Account · Cash Only'
                                : '${isSchool && _seqType == 'ARREAR' ? 'No Arrear Receipt Sequence' : 'No Receipt Sequence'} · Create in Sequence Master',
                            style: TextStyle(
                                fontSize: 10.sp,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                                color: AppColors.warning)),
                      ]),
                    ),
                  ),
                ],
                const Spacer(),
                Text('Balance ',
                    style: TextStyle(
                        fontSize: 11.5.sp, color: AppColors.textLight)),
                Text('₹${formatIndianNumber(b.balance)}',
                    style: TextStyle(
                        fontSize: 12.5.sp,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
                SizedBox(width: 16.w),
                // Ticks up as the cashier types -- this is what THIS group's
                // receipt will be raised for.
                ListenableBuilder(
                  listenable: Listenable.merge([
                    for (final d in b.rows) ...[
                      if (_conCtrl[_demKey(d)] != null) _conCtrl[_demKey(d)]!,
                      if (_fineCtrl[_demKey(d)] != null) _fineCtrl[_demKey(d)]!,
                    ],
                  ]),
                  builder: (_, __) {
                    final net = b.rows.fold<double>(
                        0,
                        (s, d) => s +
                            (_selected.contains(_demKey(d)) ? _netAmt(d) : 0));
                    return Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('Collecting ',
                          style: TextStyle(
                              fontSize: 11.5.sp, color: AppColors.textLight)),
                      Text('₹${formatIndianNumber(net)}',
                          style: TextStyle(
                              fontSize: 13.sp,
                              fontWeight: FontWeight.w700,
                              color: net > 0 ? color : AppColors.textLight)),
                    ]);
                  },
                ),
              ],
            ),
          ),

          // ---- column header, with a select-all for THIS group only --------
          Container(
            color: AppColors.tableHeadBg,
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
            child: Row(
              children: [
                SizedBox(
                  width: 32.w,
                  child: Checkbox(
                    value: live && allSelected,
                    onChanged: !live
                        ? (_) => _switchPayGroup(b.fgId, selectAll: true)
                        : (v) => setState(() {
                      for (final d in b.rows) {
                        final k = _demKey(d);
                        if (v == true) {
                          // Cap, not balance: a row the advance already covers
                          // must not be refilled with cash.
                          final cap = _collectCap(d);
                          if (cap > 0) {
                            _selected.add(k);
                            _conCtrl[k]?.text = cap.toStringAsFixed(0);
                          } else {
                            _selected.remove(k);
                            _conCtrl[k]?.text = '0';
                          }
                        } else {
                          // Rows the advance is paying for stay in -- clearing
                          // the selection must not quietly strand the plan.
                          if ((_pendingAdjust[k] ?? 0) > 0) continue;
                          _selected.remove(k);
                          _conCtrl[k]?.text = '0';
                        }
                      }
                          }),
                    fillColor: WidgetStateProperty.resolveWith((st) =>
                        st.contains(WidgetState.selected)
                            ? color
                            : Colors.transparent),
                    side: BorderSide(color: AppColors.border),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                _THCell(schoolTerm('Semester'), flex: 2),
                const _THCell('Fee Type', flex: 3),
                const _THCell('Due Date', flex: 2),
                // The rupee sign belongs in the heading, not repeated down
                // every cell of a money column.
                const _THCell('Fee Amount (₹)', flex: 2, textAlign: TextAlign.right),
                const _THCell('Balance Amount (₹)', flex: 2, textAlign: TextAlign.right),
                // Read-only: filled in by adjust_advance when an advance is
                // applied, never typed here. School settles advances on the
                // Advance Adjustment screen, so it has no such column.
                if (!isSchool) const _THCell('Adjustment (₹)', flex: 2, textAlign: TextAlign.right),
                const _THCell('Collect Amount (₹)', flex: 3, textAlign: TextAlign.center),
                const _THCell('Fine (₹)', flex: 2, textAlign: TextAlign.center),
                const _THCell('Net Amount (₹)', flex: 2, textAlign: TextAlign.right),
              ],
            ),
          ),

          // ---- the dues themselves ----------------------------------------
          // A waiting group still shows every due and its balance -- the
          // cashier has to see what is left -- but faded, and its fields are
          // dead until the group is collected.
          Opacity(
            opacity: live ? 1 : 0.55,
            child: Column(children: [
              for (var i = 0; i < b.rows.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: AppColors.divider),
                _buildDemandRow(b.rows[i], i),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  /// This row belongs to the group being collected.
  bool _inPayGroup(Map<String, dynamic> d) =>
      _payFgId == null || (_fgIdOf(d) ?? -1) == _payFgId;

  /// Rows of the active group, within the active Regular/Arrear scope.
  List<Map<String, dynamic>> get _payGroupDemands =>
      _currentTypeDemands.where(_inPayGroup).toList();

  /// Dues still owed in the OTHER groups, for the footer's note. A cashier who
  /// cannot see them would think the student is settled.
  Map<String, double> get _otherGroupsOutstanding {
    final out = <String, double>{};
    for (final d in _currentTypeDemands) {
      if (_inPayGroup(d)) continue;
      final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
      if (bal <= 0) continue;
      final g = _fgLabelOf(d);
      out[g] = (out[g] ?? 0) + bal;
    }
    return out;
  }

  /// Collect a different group. Everything staged for the previous one is
  /// dropped: its Collect Amounts, its ticks and any advance planned against
  /// its rows -- a plan is made against the rows on screen, and carrying it
  /// over would settle one group's dues from another group's money.
  void _switchPayGroup(int? fgId, {bool selectAll = false}) {
    if (_payFgId == fgId && !selectAll) return;
    setState(() {
      if (_payFgId != fgId) _clearPendingAdjust();
      _payFgId = fgId;
      for (final d in _allDemands) {
        final k = _demKey(d);
        final mine = (_fgIdOf(d) ?? -1) == fgId;
        if (!mine) {
          _selected.remove(k);
          _conCtrl[k]?.text = '0';
          continue;
        }
        if (!selectAll || !_matchesSeqType(d)) continue;
        final cap = _collectCap(d);
        if (cap > 0) {
          _selected.add(k);
          _conCtrl[k]?.text = cap.toStringAsFixed(0);
        }
      }
    });
  }

  /// The group the counter should open on: the first one, lowest fg_id, with
  /// something payable in the active scope.
  int? _firstPayableFg() {
    final ids = <int>[];
    for (final d in _allDemands) {
      if (!_matchesSeqType(d)) continue;
      if (((d['balancedue'] as num?)?.toDouble() ?? 0) <= 0) continue;
      final fg = _fgIdOf(d);
      if (fg != null && !ids.contains(fg)) ids.add(fg);
    }
    if (ids.isEmpty) return null;
    ids.sort();
    return ids.first;
  }

  /// This demand belongs to the hostel side of the ledger.
  bool _isHostelDemand(Map<String, dynamic> d) {
    final g = _fgLabelOf(d);
    return g.contains('HOSTEL') || g.contains('MESS');
  }

  /// The fee group an advance may be spent on.
  ///
  /// A MESS advance was collected into the HOSTEL account and a student
  /// advance into the college one; adjusting either against the other side's
  /// dues would settle a fee with money that is sitting in the wrong bank.
  /// So a mess advance clears hostel dues and nothing else, and a student
  /// advance clears everything else.
  bool _advanceIsMess(Map<String, dynamic> a) =>
      (a['advtype']?.toString().toUpperCase() ?? 'S') == 'M';

  List<Map<String, dynamic>> _demandsForAdvance(
          Map<String, dynamic> a, List<Map<String, dynamic>> rows) =>
      _advanceIsMess(a)
          ? rows.where(_isHostelDemand).toList()
          : rows.where((d) => !_isHostelDemand(d)).toList();

  /// What the advance picker prints beside each advance.
  String _advanceScope(Map<String, dynamic> a) =>
      _advanceIsMess(a) ? 'HOSTEL FEES ONLY' : 'COLLEGE FEES ONLY';

  /// fg_id of a demand row, or null when its fee type isn't in the master.
  int? _fgIdOf(Map<String, dynamic> d) =>
      _fgOfFeeType[(d['demfeetype']?.toString() ?? '').trim().toUpperCase()];

  String _fgLabelOf(Map<String, dynamic> d) {
    final id = _fgIdOf(d);
    final name = id == null ? null : _fgName[id];
    return (name == null || name.isEmpty) ? 'OTHER FEES' : name;
  }

  /// [demands] split into fee-group blocks, lowest fg_id first (fee types the
  /// master doesn't know sort last). Each block is one card, and one receipt.
  List<_FgBlock> _fgBlocks(List<Map<String, dynamic>> demands) {
    final order = <int>[];
    final byFg = <int, List<Map<String, dynamic>>>{};
    for (final d in demands) {
      final fg = _fgIdOf(d) ?? 1 << 30; // unmapped sorts last
      if (!byFg.containsKey(fg)) {
        byFg[fg] = [];
        order.add(fg);
      }
      byFg[fg]!.add(d);
    }
    order.sort();
    return [
      for (final fg in order)
        _FgBlock(
          fgId: fg,
          label: _fgLabelOf(byFg[fg]!.first),
          rows: byFg[fg]!,
          balance: byFg[fg]!.fold<double>(
              0, (s, d) => s + ((d['balancedue'] as num?)?.toDouble() ?? 0)),
        ),
    ];
  }

  /// Loads the arrear-first Utilities toggle for this institution.
  Future<void> _loadUtilSettings() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    final s = await SupabaseService.getInstitutionSettings(insId);
    if (!mounted) return;
    setState(() {
      _arrearFirst = (s['fee_collection_arrear_first'] ?? 'true').toLowerCase() != 'false';
    });
  }

  Future<void> _loadOnlineGateway() async {
    OnlineGateway? g;
    try {
      g = await OnlinePaymentService.gatewayFor();
    } catch (e) {
      // Could not tell (network, session). Offer the server's online mode
      // anyway -- it decides at payment time -- and never the older Paytm path.
      debugPrint('gateway lookup failed: $e');
      g = const OnlineGateway(0, '', 'Online', '');
    }
    if (mounted) setState(() => _onlineGateway = g);
  }

  Future<void> _sweepOrphanedPayments() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 15)).toIso8601String();
      // 'F' IS SWEPT TOO, not just 'I'.
      //
      // A payment written off as failed used to be the end of it: nothing in
      // the app ever looked at an 'F' again. That is how JAYASURYA's Rs 2,000
      // and Rs 1,600 of 30-09-2026 ended up on the failed list -- the money was
      // debited, Paytm captured it around midnight, and by then the old
      // 15-minute sweep had already marked the row failed. Only the webhook
      // revisits an 'F', and the webhook may not even be registered.
      //
      // Re-asking costs nothing and can only ever turn a wrongly-failed
      // payment back into a receipt: a row that already HAS a paynumber is
      // excluded, so a genuine completed payment is never touched, and the
      // 7-day window keeps this to a handful of rows.
      final failedFrom = DateTime.now()
          .subtract(const Duration(days: 7))
          .toIso8601String();
      final orphans = await SupabaseService.fromSchema('payment')
          .select('pay_id, payorderid, payitems, ban_id, paystatus, createdat')
          .eq('ins_id', insId)
          .inFilter('paystatus', ['I', 'F'])
          .isFilter('paynumber', null)
          // Orders of the Setup gateways are settled on the server
          // (pay-status / pay-webhook / pay-sweep), never here.
          .isFilter('pg_id', null)
          .lt('createdat', cutoff)
          .gte('createdat', failedFrom);
      for (final p in (orphans as List)) {
        final payId = p['pay_id'] as int;
        final orderId = p['payorderid']?.toString();
        String? paymentId;
        bool captured = false;
        // Only an explicit TXN_FAILURE from Paytm may fail a row. Pending, "no
        // record", and a verify call that threw are all UNDECIDED.
        bool gatewaySaysFailed = false;
        if (orderId != null && orderId.isNotEmpty) {
          try {
            // Ask THE MERCHANT THE ORDER WAS CREATED WITH. Orders are signed
            // per fee group now, so a hostel payment lives under the hostel
            // merchant: asking the default one returns "no such order" and
            // this sweep would mark a captured payment failed. ban_id is the
            // group's bank, stamped on the row when it was raised.
            final routing = await SupabaseService.resolvePaytmRouting(
                insId: insId, banId: p['ban_id'] as int?);
            final s = await PaytmService.verifyPayment(orderId,
                mid: routing.ok ? routing.mid : null);
            if (s.isCaptured && s.paymentId != null) {
              captured = true;
              paymentId = s.paymentId;
            }
            gatewaySaysFailed = s.isFailed;
          } catch (_) {}
        }
        if (captured) {
          List<dynamic> items = [];
          final raw = p['payitems']?.toString();
          if (raw != null && raw.isNotEmpty) {
            try { items = jsonDecode(raw) as List<dynamic>; } catch (_) {}
          }

          // payitems empty? The fee lines are still in PAYMENTDETAILS.
          //
          // Desktop-initiated rows often carry no payitems, but the detail rows
          // were written when the attempt was created -- which is why
          // webhook_complete_payment can rebuild from them and the sweep could
          // not. Rebuilding here turns "needs a human" back into an ordinary
          // recovery for exactly the rows that stranded Rs 56,500 since
          // September.
          if (items.isEmpty) {
            try {
              final det = await SupabaseService.fromSchema('paymentdetails')
                  .select('dem_id, transtotalamount')
                  .eq('pay_id', payId)
                  .eq('activestatus', 1);
              final demIds = (det as List)
                  .map((d) => (d['dem_id'] as num?)?.toInt())
                  .whereType<int>()
                  .toList();
              if (demIds.isNotEmpty) {
                final fd = await SupabaseService.fromSchema('feedemand')
                    .select('dem_id, demfeetype')
                    .inFilter('dem_id', demIds);
                final typeOf = <int, String>{
                  for (final f in (fd as List))
                    if ((f['dem_id'] as num?) != null)
                      (f['dem_id'] as num).toInt():
                          f['demfeetype']?.toString() ?? '',
                };
                items = [
                  for (final d in det)
                    {
                      'dem_id': (d['dem_id'] as num).toInt(),
                      'amount': (d['transtotalamount'] as num?)?.toDouble() ?? 0,
                      'demfeetype':
                          typeOf[(d['dem_id'] as num).toInt()] ?? '',
                    }
                ];
                debugPrint('sweep $payId: rebuilt ${items.length} item(s) '
                    'from paymentdetails');
              }
            } catch (e) {
              debugPrint('sweep $payId: could not read paymentdetails: $e');
            }
          }

          // STILL NO ITEMS, NO COMPLETION.
          //
          // complete_payment_grouped treats an empty p_items as "finalise the
          // row in place": it sets paystatus='C' and paydate=NOW() and stops --
          // no receipt number drawn, no demand credited. Calling it here turned
          // two genuinely captured September payments into rows that READ as
          // collected while the student still owed the money and no receipt
          // existed. That is worse than leaving them failed, because a failed
          // row is visibly unresolved and this one is not.
          //
          // Without payitems there is no record of WHICH fees the money was
          // for, so no receipt can be raised correctly. Leave the row alone and
          // make it visible instead -- it needs a person.
          if (items.isEmpty) {
            try {
              await SupabaseService.client.rpc('webhook_record_refusal', params: {
                'p_order_id': orderId ?? 'pay_id:$payId',
                'p_reason': 'Paytm captured this, but the attempt has no record '
                    'of which fees it was for - needs a receipt raised by hand',
                'p_ins_id': insId,
                'p_pay_id': payId,
              });
            } catch (e) {
              debugPrint('could not record refusal for $payId: $e');
            }
            continue;
          }

          try {
            await SupabaseService.completePaymentGrouped(
              token: _sessionToken, payId: payId, payMethod: 'online',
              payReference: paymentId, items: items, insId: insId, status: 'C');

            // Keep the day the MONEY WAS TAKEN. complete_payment_grouped
            // stamps NOW(), which is right when a payment completes normally
            // and wrong for one recovered hours later: a capture just after
            // midnight, receipted next morning, would leave the previous day's
            // collection short and never tying against the Paytm report. The
            // date is the 'I' row's createdat -- stamped by the server when the
            // payment was initiated, never a workstation clock.
            final startedAt = p['createdat']?.toString();
            if (orderId != null && orderId.isNotEmpty &&
                startedAt != null && startedAt.isNotEmpty) {
              try {
                await SupabaseService.client
                    .rpc('backdate_recovered_payment', params: {
                  'p_ins_id': insId,
                  'p_order_id': orderId,
                  'p_when': startedAt,
                });
              } catch (e) {
                debugPrint('backdate_recovered_payment $orderId: $e');
              }
            }
          } catch (e) {
            debugPrint('Recovery complete failed for pay_id=$payId: $e');
          }
        } else if (gatewaySaysFailed) {
          // A real decline. Safe to close the row.
          await SupabaseService.updatePayment(payId, {'paystatus': 'F'});
        }
        // Otherwise UNDECIDED -- still pending at the bank, or Paytm could not
        // be reached. Leave the row 'I' and let a later sweep decide.
        //
        // This branch used to mark every non-captured row 'F' after fifteen
        // minutes, which is how payments were lost: a UPI or netbanking payment
        // still settling was written off, then the money arrived and nothing
        // revisited an 'F' row, so no receipt was ever raised. It also undid
        // the collection screen's own rule (see "never write off an undecided
        // payment" below) fifteen minutes after that code had carefully left
        // the row alone. Observed on 2026-10-01: the app showed three payments
        // Failed while the Paytm dashboard still showed all three PENDING.
        //
        // An unresolved 'I' row is recoverable -- the sweep and the webhook
        // both revisit it. A wrongly failed one is not.
      }
    } catch (e) {
      debugPrint('Orphaned payment sweep failed: $e');
    }
  }

  Future<void> _loadFineRules() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    debugPrint('FINE: Loading fine rules for insId=$insId, schema=${SupabaseService.currentSchema}');
    if (insId == null) return;
    try {
      final result = await SupabaseService.fromSchema('finerule')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('from_days');
      _fineRules = List<Map<String, dynamic>>.from(result);
      debugPrint('FINE: Loaded ${_fineRules.length} rules: $_fineRules');
    } catch (e) {
      debugPrint('FINE: Error loading fine rules: $e');
    }
  }

  double _calculateFine(Map<String, dynamic> demand) {
    if (_fineRules.isEmpty) return 0;
    final dueDateStr = demand['duedate']?.toString();
    if (dueDateStr == null || dueDateStr.isEmpty) return 0;

    DateTime dueDate;
    try { dueDate = DateTime.parse(dueDateStr); } catch (_) { return 0; }

    final today = DateTime.now();
    if (!today.isAfter(dueDate)) return 0; // Not overdue

    final overdueDays = today.difference(dueDate).inDays;
    final feeType = demand['demfeetype']?.toString() ?? '';
    final feeAmount = (demand['feeamount'] as num?)?.toDouble() ?? 0;

    // Find matching rule (fee-type specific first, then ALL)
    Map<String, dynamic>? matchedRule;
    for (final rule in _fineRules) {
      final ruleType = rule['feetype']?.toString() ?? 'ALL';
      final fromDays = (rule['from_days'] as num?)?.toInt() ?? 0;
      final toDays = rule['to_days'] as num?;

      final daysMatch = overdueDays >= fromDays && (toDays == null || overdueDays <= toDays.toInt());
      if (!daysMatch) continue;

      if (ruleType == feeType) { matchedRule = rule; break; } // Exact match
      if (ruleType == 'ALL' && matchedRule == null) matchedRule = rule; // ALL fallback
    }

    if (matchedRule == null) return 0;

    final fineType = matchedRule['fine_type']?.toString() ?? 'FIXED';
    final fineValue = (matchedRule['fine_value'] as num?)?.toDouble() ?? 0;

    if (fineType == 'PERCENT') return (feeAmount * fineValue / 100);
    return fineValue;
  }

  Future<void> _fetchClasses() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    // Course/Class dropdown options. Source these from the STUDENTS table
    // (one row per student, just 2 columns) rather than the entire feedemand
    // table (many rows per student, every column) — far fewer rows and payload.
    // The actual per-class student lookup (_searchByClass) is already scoped.
    try {
      final results = await Future.wait([
        SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select('courname, stuclass')
            .eq('ins_id', insId)
            .eq('activestatus', 1)),
        SupabaseService.getClassOrder(insId),
      ]);
      final rows = results[0] as List<Map<String, dynamic>>;
      _classOrdid = results[1] as Map<String, int>;
      final cmp = classOrdidComparator(_classOrdid); // order by class-master ordid
      final courseSet = <String>{};
      final mapping = <String, Set<String>>{};
      for (final d in rows) {
        final course = d['courname']?.toString() ?? '';
        final cls = d['stuclass']?.toString() ?? '';
        if (course.isNotEmpty) courseSet.add(course);
        if (course.isNotEmpty && cls.isNotEmpty) {
          mapping.putIfAbsent(course, () => <String>{}).add(cls);
        }
      }
      final allClasses = mapping.values.expand((s) => s).toSet().toList()..sort(cmp);
      final courseClassMap = <String, List<String>>{ for (final e in mapping.entries) e.key: e.value.toList()..sort(cmp) };
      final courseList = courseSet.toList()..sort();
      if (mounted) setState(() {
        _courseList = courseList;
        _courseClassMap = courseClassMap;
        _allClasses = allClasses;
        _classList = allClasses;
      });
    } catch (e) { debugPrint('Error loading course-class from students: $e'); }
  }

  Future<void> _searchByClass(String className) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Step 1: gather every student in this class+course who has been billed
      // (has at least one fee demand), together with their outstanding total.
      // Fully-paid students are kept in the list and flagged PAID rather than
      // hidden, so a cashier can confirm someone has already settled up.
      // Both queries are paged — PostgREST caps a response at 1000 rows and
      // truncates silently, which for a large class would drop students from
      // the lookup with no error shown.
      final demRows = await SupabaseService.fetchAll(() {
        var q = SupabaseService.fromSchema('feedemand')
            .select('stu_id, balancedue')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('collectible', true) // ignore non-collectible demands in the owing flag
            .eq('stuclass', className);
        if (_selectedCourse != null) q = q.eq('courname', _selectedCourse!);
        return q;
      });
      final balances = <int, double>{};
      for (final r in demRows) {
        final id = r['stu_id'];
        if (id is! int) continue;
        balances[id] = (balances[id] ?? 0) + ((r['balancedue'] as num?)?.toDouble() ?? 0);
      }
      _balanceByStu.addAll(balances);

      // Step 2: the whole class roster. Students with no demands are listed
      // too (just without a status badge) — hiding them made the lookup look
      // broken when a class hadn't been billed yet.
      final rows = await SupabaseService.fetchAll(() {
        // activestatus is NOT filtered: a student who has been issued a TC
        // still has to be findable -- their dues are looked up, printed and
        // argued over long after they leave. What changes is that the screen
        // will not take money from them; see _studentHasTc.
        var q = SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname, activestatus')
            .eq('ins_id', insId)
            .eq('preadmission', 0)
            .eq('stuclass', className);
        if (_selectedCourse != null) q = q.eq('courname', _selectedCourse!);
        return q.order('stuname', ascending: true);
      });
      setState(() => _classSuggestions = rows);
    } catch (_) {}
  }

  /// Demands whose fine has actually been collected in this session.
  ///
  /// dispose() must not reset these. The paidstatus check in _resetFinesOnExit
  /// reads _allDemands, which still holds the PRE-payment snapshot where
  /// paidstatus is 'U' -- so leaving the screen after a successful collection
  /// wiped feedemand.fineamount on the very demand just paid. paidamount kept
  /// the fine (25,100 = 25,000 + 100) but fineamount went to 0, so receipts
  /// could no longer split the fine out and the dashboard's Fine Collected
  /// summed to zero.
  final Set<int> _paidFineDemIds = <int>{};

  @override
  void dispose() {
    // If the cashier is leaving without a completed payment, reset fineamount
    // to 0 on every unpaid demand currently loaded. Fine should only persist
    // on the DB after a successful payment, not just because a cashier viewed
    // the student.
    _resetFinesOnExit();
    _admNoController.dispose();
    _nameController.dispose();
    _classController.dispose();
    _remarksController.dispose();
    _chequeNoController.dispose();
    _upiRefController.dispose();
    _tenderAmountController.dispose();
    _chequeDateController.dispose();
    _bankNameController.dispose();
    for (final c in _fineCtrl.values) c.dispose();
    for (final c in _conCtrl.values) c.dispose();
    for (final f in _fineFocus.values) f.dispose();
    for (final f in _conFocus.values) f.dispose();
    for (final t in _conFlipTimers.values) t.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _resetFinesOnExit() {
    if (_allDemands.isEmpty) return;
    // Use the values cached in didChangeDependencies — dispose() must not touch
    // context (the element is already deactivated).
    final insId = _cachedInsId;
    if (insId == null) return;
    // Fire-and-forget — dispose can't await.
    for (final d in _allDemands) {
      final demId = d['dem_id'];
      final paidStatus = d['paidstatus']?.toString() ?? 'U';
      if (demId == null) continue;
      if (paidStatus == 'P') continue; // don't wipe historical paid fines
      // ...nor a fine collected in this session: _allDemands is the snapshot
      // from before the payment, so paidStatus above is still 'U' for it.
      if (demId is int && _paidFineDemIds.contains(demId)) continue;
      SupabaseService.setDemandFine(token: _cachedToken, demId: demId, fineamount: 0)
          .then((_) {}, onError: (e) => debugPrint('Fine reset on exit failed for dem_id=$demId: $e'));
    }
  }

  void _clear() {
    for (final c in _fineCtrl.values) c.dispose();
    for (final c in _conCtrl.values) c.dispose();
    for (final f in _fineFocus.values) f.dispose();
    for (final f in _conFocus.values) f.dispose();
    _fineCtrl.clear();
    _conCtrl.clear();
    _fineFocus.clear();
    _conFocus.clear();
    setState(() {
      _admNoController.clear();
      _nameController.clear();
      _classController.clear();
      _remarksController.clear();
      _studentSuggestions = [];
      _classSuggestions = [];
      _selectedCourse = null;
      _selectedClass = null;
      _classList = List<String>.from(_allClasses);
      _student = null;
      _parent = null;
      _allDemands = [];
      _advances = [];
      _admissionAdvances = [];
      _adjustedByDem.clear();
      _clearPendingAdjust();
      _errorMsg = null;
      _selectedTerm = null;
      _seqType = 'REGULAR';
      _selected.clear();
      _paymentMode = null;
      _chequeNoController.clear();
      _chequeDateController.clear();
      _bankNameController.clear();
      _upiRefController.clear();
      _chequeDate = null;
    });
  }

  Future<void> _searchByAdmNo(String admno) async {
    if (admno.trim().length < 2) {
      setState(() => _studentSuggestions = []);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, activestatus')
          .eq('ins_id', insId)
          .eq('preadmission', 0)
          .ilike('stuadmno', '${admno.trim()}%')
          .limit(10);
      setState(() => _studentSuggestions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _searchByName(String name) async {
    if (name.trim().length < 2) {
      setState(() => _studentSuggestions = []);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, activestatus')
          .eq('ins_id', insId)
          .eq('preadmission', 0)
          .ilike('stuname', '%${name.trim()}%')
          .limit(10);
      setState(() => _studentSuggestions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  /// Debounces keystrokes so the search (2 DB round-trips) fires at most once
  /// every 300ms after the user stops typing, instead of on every character.
  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    if (v.trim().length < 2) {
      // Short/empty term → clear immediately, no round-trip.
      if (_studentSuggestions.isNotEmpty) setState(() => _studentSuggestions = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _searchByAdmNoOrName(v);
    });
  }

  /// Combined suggestion search — matches Roll No (prefix) OR Student Name
  /// (substring) so the single search field works for both.
  Future<void> _searchByAdmNoOrName(String q) async {
    final term = q.trim();
    if (term.length < 2) {
      setState(() => _studentSuggestions = []);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Scope the search to the selected course / class when chosen, so the
      // cashier only matches students within the picked course + class.
      var query = SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, activestatus')
          .eq('ins_id', insId)
          .eq('preadmission', 0);
      if (_selectedCourse != null && _selectedCourse!.isNotEmpty) {
        query = query.eq('courname', _selectedCourse!);
      }
      if (_selectedClass != null && _selectedClass!.isNotEmpty) {
        query = query.eq('stuclass', _selectedClass!);
      }
      final rows = await query
          .or('stuadmno.ilike.$term%,stuname.ilike.%$term%')
          .limit(10);
      final list = List<Map<String, dynamic>>.from(rows);
      setState(() => _studentSuggestions = list);
      // Load outstanding totals so the lookup can flag PAID here too.
      await _loadBalancesFor(
        list.map((s) => s['stu_id']).whereType<int>(),
        insId,
      );
    } catch (_) {}
  }

  /// Fill [_balanceByStu] for the given students by summing their active
  /// demands' balancedue. Students with demands but nothing owing land on 0.
  Future<void> _loadBalancesFor(Iterable<int> stuIds, int insId) async {
    final ids = stuIds.toSet().toList();
    if (ids.isEmpty) return;
    try {
      final rows = await SupabaseService.fromSchema('feedemand')
          .select('stu_id, balancedue')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('collectible', true) // ignore non-collectible demands in the owing flag
          .inFilter('stu_id', ids);
      final totals = <int, double>{};
      for (final r in (rows as List)) {
        final id = (r['stu_id'] as num?)?.toInt();
        if (id == null) continue;
        totals[id] = (totals[id] ?? 0) + ((r['balancedue'] as num?)?.toDouble() ?? 0);
      }
      if (!mounted) return;
      setState(() {
        for (final id in ids) {
          // Absent from `totals` = no demands at all; leave unset so the row
          // shows no badge rather than claiming the student has paid.
          if (totals.containsKey(id)) _balanceByStu[id] = totals[id]!;
        }
      });
    } catch (_) {}
  }

  void _selectSuggestion(Map<String, dynamic> student) {
    _admNoController.text = student['stuadmno']?.toString() ?? '';
    _nameController.text = student['stuname']?.toString() ?? '';
    _classController.text = student['stuclass']?.toString() ?? '';
    setState(() {
      _studentSuggestions = [];
      _classSuggestions = [];
    });
    _search();
  }

  Future<void> _search() async {
    final admNo = _admNoController.text.trim();
    if (admNo.isEmpty) return;

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    // Dispose old controllers + focus nodes from any previous search
    for (final c in _fineCtrl.values) c.dispose();
    for (final c in _conCtrl.values) c.dispose();
    for (final f in _fineFocus.values) f.dispose();
    for (final f in _conFocus.values) f.dispose();
    _fineCtrl.clear();
    _conCtrl.clear();
    _fineFocus.clear();
    _conFocus.clear();

    setState(() {
      _searching = true;
      _errorMsg = null;
      _student = null;
      _parent = null;
      _allDemands = [];
      _advances = [];
      _admissionAdvances = [];
      _adjustedByDem.clear();
      _clearPendingAdjust();
      _selected.clear();
      _selectedTerm = null;
    });

    try {
      // The combined search field accepts a Roll No OR a Student Name. Try
      // exact roll-no match first; if nothing, fall back to a name search
      // and use the first match (e.g. user typed a full name and hit Enter
      // without clicking a suggestion).
      var studentRows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, stugender, stumobile, stuphoto, courname, activestatus')
          .eq('ins_id', insId)
          .eq('preadmission', 0)
          .eq('stuadmno', admNo)
          .limit(1);

      if ((studentRows as List).isEmpty) {
        studentRows = await SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, stugender, stumobile, stuphoto, courname, activestatus')
            .eq('ins_id', insId)
            .eq('preadmission', 0)
            .ilike('stuname', '%$admNo%')
            .limit(1);
      }

      if ((studentRows as List).isEmpty) {
        setState(() {
          _errorMsg = 'No student found for "$admNo". ${schoolTerm('Check the register no. or name and try again.')}';
          _searching = false;
        });
        return;
      }

      final student = Map<String, dynamic>.from(studentRows.first as Map);
      final stuId = student['stu_id'] as int;
      // Use the resolved student's actual roll number for downstream lookups
      // (the search field may now hold the student name, not the admno).
      final stuAdmno = student['stuadmno']?.toString() ?? '';

      _nameController.text = student['stuname']?.toString() ?? '';
      _classController.text = student['stuclass']?.toString() ?? '';
      // Show the student name in the combined search field once a match is
      // resolved — easier to read than the raw roll no.
      _admNoController.text = student['stuname']?.toString() ?? '';
      final stuClass = student['stuclass']?.toString();
      final stuCourse = student['courname']?.toString();

      setState(() {
        _student = student;
        _searching = false;
        _loadingDemands = true;
        _studentSuggestions = [];
        if (stuCourse != null && stuCourse.isNotEmpty && _courseList.contains(stuCourse)) {
          _selectedCourse = stuCourse;
          if (_courseClassMap.containsKey(stuCourse)) {
            _classList = List<String>.from(_courseClassMap[stuCourse]!)
              ..sort(classOrdidComparator(_classOrdid));
          }
        }
        if (stuClass != null && _classList.contains(stuClass)) {
          _selectedClass = stuClass;
        }
      });

      // Fine is NOT persisted to feedemand.fineamount at search time — it is
      // only written after a successful payment (see _processPayment). The
      // cashier sees the calculated fine via _calculateFine below; if they
      // abandon without paying, the DB column stays empty.

      // Fetch parent and demands in parallel — use the resolved student's
      // actual stuadmno so the join works even when the user searched by
      // student name in the combined search field.
      final parentFuture = SupabaseService.getStudentParent(stuId, stuadmno: stuAdmno);
      // What has already been taken off this student's demands out of an
      // advance. Drives the read-only ADJUSTMENT column.
      final adjustedFuture = SupabaseService.fromSchema('advadjustment')
          .select('dem_id, adv_id, adjustamount')
          .eq('ins_id', insId)
          .eq('stu_id', stuId)
          .eq('activestatus', 1);
      // Which of this student's advances are ADMISSION advances. What those
      // took off a demand is a reduction of the bill, not a payment against it,
      // so it is dropped from the ADJUSTMENT column below.
      final admissionAdvFuture = SupabaseService.fromSchema('advance_collection')
          .select('adv_id, advno, advdate, balanceamount, activestatus')
          .eq('ins_id', insId)
          .eq('stu_id', stuId)
          .eq('advtype', 'A');
      // STUDENT and MESS advances. An ADMISSION advance reduces a fee rather
      // than paying it, is normally applied to a whole intake at once, and is
      // handled on the Advance Adjustment screen — offering it at the counter
      // invited the cashier to treat it as money toward today's bill.
      //
      // A MESS advance ('M') is money banked into the HOSTEL account, so it is
      // offered here but confined to the hostel dues — see _demandsForAdvance.
      final advanceFuture = SupabaseService.fromSchema('advance_collection')
          .select('adv_id, advno, advdate, advtype, transtotalamount, adjustedamount, balanceamount, paymethod, remarks')
          .eq('ins_id', insId)
          .inFilter('advtype', ['S', 'M'])
          .eq('stu_id', stuId)
          .eq('activestatus', 1)
          .gt('balanceamount', 0)
          .order('adv_id', ascending: true);
      // Fee lines with a concession waiting in Concession Approval are held:
      // they cannot be ticked or collected until it is approved or rejected
      // (user, 2026-11-14; school_concession_approval.sql).
      final held = <String>{};
      try {
        final pend = await SupabaseService.client.rpc('concession_pending_lines',
            params: {'p_token': SupabaseService.sessionToken, 'p_stu_id': stuId});
        for (final x in (pend as List? ?? const [])) {
          final id = (x as Map)['dem_id'];
          if (id != null) held.add('$id');
        }
      } catch (_) {
        // college / older database: no approval step
      }
      _selected.held = held;
      _selected.removeAll(held);
      final demandsFuture = SupabaseService.fromSchema('feedemand')
          .select(
              'dem_id, demno, demseqtype, yr_id, demfeeyear, demfeetype, demfeeterm, feeamount, conamount, balancedue, paidamount, fineamount, duedate, paidstatus, stuclass, collectible')
          .eq('ins_id', insId)
          .eq('stuadmno', stuAdmno)
          .eq('paidstatus', 'U')
          .gt('balancedue', 0)
          .eq('collectible', true) // only collectible demands are payable here
          .order('duedate', ascending: true);

      final parent = await parentFuture;
      final demandList =
          List<Map<String, dynamic>>.from((await demandsFuture) as List);
      // A failed advance lookup must not block a collection: the cashier can
      // still take money, they just won't be offered the advance.
      List<Map<String, dynamic>> advanceList = [];
      try {
        advanceList = List<Map<String, dynamic>>.from((await advanceFuture) as List);
      } catch (_) {
        advanceList = [];
      }
      // Same rule: an unreadable adjustment history leaves the column blank
      // rather than stopping the collection.
      _adjustedByDem.clear();
      // Unreadable => the column shows every adjustment, as it used to. Better
      // an over-inclusive column than a collection the cashier cannot take.
      final admissionAdvIds = <int>{};
      // The ones with money left drive the notice above the demands. The ID set
      // stays complete — a spent admission advance must still be kept out of
      // the ADJUSTMENT column.
      final admissionAdvLeft = <Map<String, dynamic>>[];
      try {
        for (final r
            in List<Map<String, dynamic>>.from((await admissionAdvFuture) as List)) {
          final id = (r['adv_id'] as num?)?.toInt();
          if (id == null) continue;
          admissionAdvIds.add(id);
          final bal = (r['balanceamount'] as num?)?.toDouble() ?? 0;
          final live = ((r['activestatus'] as num?)?.toInt() ?? 1) == 1;
          if (live && bal > 0) admissionAdvLeft.add(r);
        }
      } catch (_) {}
      try {
        for (final r in List<Map<String, dynamic>>.from((await adjustedFuture) as List)) {
          final id = r['dem_id']?.toString();
          if (id == null || id.isEmpty) continue;
          final advId = (r['adv_id'] as num?)?.toInt();
          if (advId != null && admissionAdvIds.contains(advId)) continue;
          _adjustedByDem[id] =
              (_adjustedByDem[id] ?? 0) + ((r['adjustamount'] as num?)?.toDouble() ?? 0);
        }
      } catch (_) {
        _adjustedByDem.clear();
      }

      // Sort by due date (oldest first) so cashiers collect overdue fees first.
      demandList.sort((a, b) {
        final da = a['duedate']?.toString() ?? '';
        final db = b['duedate']?.toString() ?? '';
        if (da.isEmpty && db.isEmpty) return 0;
        if (da.isEmpty) return 1;
        if (db.isEmpty) return -1;
        return da.compareTo(db);
      });

      _allDemands = demandList;

      // Per-row controllers: prefer the server-computed fineamount column;
      // fall back to client-side rule calculation if server hasn't populated it.
      // Default behaviour on student search: every demand row is pre-checked
      // and Col Amount is pre-filled with the balance — cashier just tweaks
      // values then hits Proceed to Pay.
      _selected.clear();
      _selectedTerm = null;
      // Arrear-first (Utilities): when enabled and the student has arrear dues,
      // open on Arrear so arrears are cleared before regular. Otherwise default
      // to Regular when present. Only the ACTIVE type is pre-selected/pre-filled
      // so the first receipt is single-type — the other type shows Col Amount 0.
      _seqType = (_arrearFirst && _hasArrear)
          ? 'ARREAR'
          : (_hasRegular ? 'REGULAR' : 'ARREAR');
      // ONE GROUP AT A TIME: open on the first group with something payable
      // and pre-fill only its rows. Pre-filling every group would stage a
      // tender that cannot be taken as one payment.
      _payFgId = _firstPayableFg();
      // Fine already COLLECTED on each demand (receipt lines keep their own
      // fine since 2026-11-05). Without this, a part payment that took the
      // fine offered the same fine again on the next visit.
      final fineCollected = <int, double>{};
      try {
        final ids = demandList.map((d) => d['dem_id']).whereType<int>().toList();
        if (ids.isNotEmpty) {
          final rows = await SupabaseService.fetchAll(() => SupabaseService.fromSchema('paymentdetails')
              .select('dem_id, fineamount')
              .inFilter('dem_id', ids)
              .eq('activestatus', 1)
              .gt('fineamount', 0));
          for (final r in rows) {
            final id = (r['dem_id'] as num?)?.toInt();
            if (id == null) continue;
            fineCollected[id] = (fineCollected[id] ?? 0) + ((r['fineamount'] as num?)?.toDouble() ?? 0);
          }
        }
      } catch (e) {
        debugPrint('collected fines unavailable: $e');
      }
      // The fine still due on each fee, from the server (fee_fine_quote:
      // Fine Rules, the fee type's Fine Applicable switch, a fine set by the
      // office, less fines already collected) -- the same figure the parent
      // app charges. Worked out here only if the server cannot be reached.
      Map<String, dynamic>? fineQuote;
      try {
        final q = await SupabaseService.client.rpc('fee_fine_quote',
            params: {'p_token': SupabaseService.sessionToken, 'p_stu_id': stuId});
        if (q is Map) fineQuote = Map<String, dynamic>.from(q);
      } catch (e) {
        debugPrint('fine quote unavailable, using local rules: $e');
      }
      for (final d in demandList) {
        final key = d['dem_id']?.toString() ?? '';
        if (key.isNotEmpty) {
          final double fine;
          if (fineQuote != null) {
            fine = (fineQuote[key] as num?)?.toDouble() ?? 0;
          } else {
            final serverFine = (d['fineamount'] as num?)?.toDouble() ?? 0;
            final fineDue = serverFine > 0 ? serverFine : _calculateFine(d);
            final paidFine = fineCollected[(d['dem_id'] as num?)?.toInt() ?? -1] ?? 0;
            fine = fineDue - paidFine > 0.004 ? fineDue - paidFine : 0.0;
          }
          final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
          final active = _matchesSeqType(d) && _inPayGroup(d);
          _fineCtrl[key] = TextEditingController(text: fine > 0 ? fine.toStringAsFixed(0) : '');
          _conCtrl[key] = TextEditingController(text: (active && bal > 0) ? bal.toStringAsFixed(0) : '0');
          if (active && bal > 0) _selected.add(key);
        }
      }

      setState(() {
        _parent = parent;
        _advances = advanceList;
        _admissionAdvances = admissionAdvLeft;
        _loadingDemands = false;
      });
    } catch (e) {
      setState(() {
        _errorMsg = friendlyError(e);
        _searching = false;
        _loadingDemands = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredDemands {
    var list = _currentTypeDemands;
    if (_selectedTerm != null) {
      list = list
          .where((d) => (d['demfeetype']?.toString() ?? '') == _selectedTerm)
          .toList();
    }
    return list;
  }

  /// Unique Fee Type values across the current student's demands OF THE ACTIVE
  /// type (regular/arrear). Used by the in-table filter dropdown ("Fee Type").
  List<String> get _terms {
    final seen = <String>[];
    for (final d in _currentTypeDemands) {
      final t = d['demfeetype']?.toString() ?? '';
      if (t.isNotEmpty && !seen.contains(t)) seen.add(t);
    }
    return seen;
  }

  String _demKey(Map<String, dynamic> d) =>
      d['dem_id']?.toString() ?? '';

  double _fine(String key) =>
      double.tryParse(_fineCtrl[key]?.text ?? '') ?? 0;

  /// The loaded student has been issued a Transfer Certificate.
  ///
  /// students.activestatus is what the TC screen writes when a certificate is
  /// issued (2 Discontinued, 3 Transferred, 4 Completed, 5 Others, 9
  /// Terminated) and sets back to 1 when one is cancelled. They stay findable
  /// here -- their dues are looked up long after they leave -- but no money is
  /// taken from them at this counter: a receipt raised against a student who
  /// has left is one that has to be cancelled afterwards.
  bool get _studentHasTc =>
      _student != null && ((_student!['activestatus'] as num?)?.toInt() ?? 1) != 1;

  /// Total still unspent across this student's advances.
  double get _advanceAvailable {
    var sum = 0.0;
    for (final a in _advances) {
      sum += (a['balanceamount'] as num?)?.toDouble() ?? 0;
    }
    return sum;
  }

  /// Total left on this student's ADMISSION advances. Notice only — see
  /// [_admissionAdvances].
  double get _admissionAdvanceAvailable {
    var sum = 0.0;
    for (final a in _admissionAdvances) {
      sum += (a['balanceamount'] as num?)?.toDouble() ?? 0;
    }
    return sum;
  }

  double _con(String key) =>
      double.tryParse(_conCtrl[key]?.text ?? '') ?? 0;

  double _netAmt(Map<String, dynamic> d) {
    // Net the cashier is actually collecting = Col Amount + Fine. When
    // nothing's typed in Col Amount the row contributes 0 so the cashier
    // sees exactly what they will collect.
    final key = _demKey(d);
    return _con(key) + _fine(key);
  }

  double get _totalNetSelected {
    // Bottom NET AMOUNT = sum of every TICKED row's actual NET AMT (col + fine).
    // Stays in lockstep with the per-row column so a row with Col Amount = 0
    // contributes 0 to the total even if the checkbox is still ticked.
    // Scoped to the ACTIVE type so regular and arrear totals never mix, and to
    // _selected so an un-ticked row can't contribute: fines are seeded from
    // feedemand.fineamount and are NOT cleared on un-tick (that would discard a
    // real persisted fine), so an un-ticked row can still hold a fine value.
    // Counting it here would inflate the cash tendered above what the receipt
    // records — the cashier would take money no demand ever receives.
    var sum = 0.0;
    for (final d in _currentTypeDemands) {
      if (!_selected.contains(_demKey(d))) continue;
      sum += _netAmt(d);
    }
    return sum;
  }

  /// Switch between collecting Regular and Arrear fees. Resets the fee-type
  /// filter and re-scopes the selection + Col Amounts to the chosen type so a
  /// receipt only ever contains one type.
  void _switchSeqType(String t) {
    if (_seqType == t) return;
    if (t == 'REGULAR' && _regularLocked) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Clear the arrear dues before collecting regular fees.'),
        backgroundColor: AppColors.warning,
      ));
      return;
    }
    setState(() {
      _seqType = t;
      _selectedTerm = null;
      _selectedArrearYear = null;
      _selected.clear();
      // The other scope may not contain the group being collected, so the
      // group is re-chosen for it.
      _payFgId = _firstPayableFg();
      for (final d in _allDemands) {
        final k = _demKey(d);
        final active = _matchesSeqType(d) && _inPayGroup(d);
        final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
        _conCtrl[k]?.text = (active && bal > 0) ? bal.toStringAsFixed(0) : '0';
        if (active && bal > 0) _selected.add(k);
      }
    });
  }

  Widget _buildSeqTypeToggle() {
    Widget seg(String label, String value, IconData icon) {
      final active = _seqType == value;
      final locked = value == 'REGULAR' && _regularLocked;
      final fg = active ? Colors.white : (locked ? AppColors.textLight : AppColors.textSecondary);
      final content = InkWell(
        onTap: () => _switchSeqType(value),
        borderRadius: BorderRadius.circular(8.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(locked ? Icons.lock_outline : icon, size: 15, color: fg),
              SizedBox(width: 6.w),
              Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: fg)),
            ],
          ),
        ),
      );
      return locked ? Tooltip(message: 'Clear arrear dues first', child: content) : content;
    }

    return Container(
      padding: EdgeInsets.all(3.w),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('Regular', 'REGULAR', Icons.receipt_long_rounded),
          seg('Arrear', 'ARREAR', Icons.history_rounded),
        ],
      ),
    );
  }

  /// Static badge shown when the student has demands of ONLY one type, so the
  /// cashier can still tell at a glance whether they're collecting a Regular or
  /// an Arrear demand (the Regular/Arrear toggle only appears when both exist).
  Widget _buildSingleTypeBadge(String type) {
    final isArrear = type == 'ARREAR';
    final color = isArrear ? AppColors.warning : AppColors.primary;
    final bg = isArrear ? AppColors.warningBg : AppColors.primaryLight;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isArrear ? Icons.history_rounded : Icons.receipt_long_rounded, size: 15, color: color),
          SizedBox(width: 6.w),
          Text(isArrear ? 'Arrear' : 'Regular',
              style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Top: Student Lookup (horizontal) ──
            Container(
              decoration: AppUI.card(),
              padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 16),
              child: _buildStudentLookupContent(),
            ),
            SizedBox(height: AppUI.gap),
            // Body
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_student != null) ...[
                    Container(
                      decoration: AppUI.card(),
                      padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14),
                      child: _buildStudentCardContent(),
                    ),
                    SizedBox(height: AppUI.gap),
                  ],
                  // ── Demands ──
                  Expanded(child: _buildDemandsPanel()),
                ],
              ),
            ),
          ],
        ),
        // Floating suggestions popup anchored under the search field — matches
        // the Fee Concession concession-popup style: UPPERCASE name + adm no +
        // class on a single line, first row tinted, hover in accent.
        if (_studentSuggestions.isNotEmpty || _classSuggestions.isNotEmpty)
          Positioned(
            width: _compactCtx ? 340.w : 480.w,
            child: CompositedTransformFollower(
              link: _admSearchLink,
              showWhenUnlinked: false,
              // Anchor to the search field's right edge so the (now wider) popup
              // grows leftward into the empty space instead of off-screen.
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 6),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12.r),
                color: Colors.white,
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 480.h),
                  child: Builder(builder: (_) {
                    final source = _studentSuggestions.isNotEmpty ? _studentSuggestions : _classSuggestions;
                    return ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.symmetric(vertical: 4.h),
                      itemCount: source.length,
                      itemBuilder: (_, i) {
                        final s = source[i];
                        final name = (s['stuname']?.toString() ?? '').toUpperCase();
                        final admno = s['stuadmno']?.toString() ?? '';
                        final cls = s['stuclass']?.toString().trim() ?? '';
                        final selected = i == 0;
                        return InkWell(
                          onTap: () => _selectSuggestion(s),
                          hoverColor: AppColors.primary.withValues(alpha: 0.06),
                          child: Container(
                            decoration: BoxDecoration(
                              color: selected ? AppColors.tableHeadBg : Colors.transparent,
                              border: i < source.length - 1
                                  ? const Border(bottom: BorderSide(color: AppColors.divider))
                                  : null,
                            ),
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                            // Uniform 3-column layout: Roll No | Name | Status,
                            // each a fixed slot so they line up down the list.
                            child: Row(children: [
                              // Roll No / Admn No (single identifier column)
                              SizedBox(
                                width: _compactCtx ? 110.w : 132.w,
                                child: Text(
                                  admno,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: _compactCtx ? 10 : 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                              SizedBox(width: 14.w),
                              // Name, with the class beneath it. Two students
                              // often share a name across classes, so the class
                              // is what tells them apart before you commit to a
                              // selection.
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: _compactCtx ? 11 : 14,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textPrimary,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                    if (cls.isNotEmpty)
                                      Padding(
                                        padding: EdgeInsets.only(top: 2.h),
                                        child: Text(
                                          cls,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: _compactCtx ? 9 : 11,
                                            fontWeight: FontWeight.w500,
                                            color: AppColors.textLight,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              SizedBox(width: 14.w),
                              // Status (fixed column so PAID/PENDING align across rows)
                              SizedBox(
                                width: _compactCtx ? 74.w : 88.w,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Builder(builder: (_) {
                                    final id = s['stu_id'];
                                    // A student who has left is flagged ahead
                                    // of their balance: it is the part that
                                    // decides whether to serve them at all.
                                    final hasTc =
                                        ((s['activestatus'] as num?)?.toInt() ?? 1) != 1;
                                    if (hasTc) {
                                      return Container(
                                        padding: EdgeInsets.symmetric(
                                            horizontal: 8.w, vertical: 2.h),
                                        decoration: BoxDecoration(
                                          color: AppColors.error.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(999),
                                          border: Border.all(
                                              color: AppColors.error.withValues(alpha: 0.35)),
                                        ),
                                        child: Text(
                                          'TC ISSUED',
                                          style: TextStyle(
                                            fontSize: _compactCtx ? 9 : 11,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.error,
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                      );
                                    }
                                    if (id is! int || !_balanceByStu.containsKey(id)) {
                                      return const SizedBox.shrink();
                                    }
                                    final bal = _balanceByStu[id]!;
                                    final paid = bal <= 0;
                                    final color = paid ? AppColors.success : AppColors.warning;
                                    return Container(
                                      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(color: color.withValues(alpha: 0.35)),
                                      ),
                                      child: Text(
                                        paid ? 'PAID' : 'PENDING',
                                        style: TextStyle(
                                          fontSize: _compactCtx ? 9 : 11,
                                          fontWeight: FontWeight.w800,
                                          color: color,
                                          letterSpacing: 0.3,
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            ]),
                          ),
                        );
                      },
                    );
                  }),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Student Lookup ──
  Widget _buildStudentLookupContent() {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Single-line bar matching the Fee Collection reference: icon +
          // title + subtitle on the left, then Course/Class dropdowns +
          // search + Clear button all inline on the right.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppUI.iconTile('receipt-2'),
              SizedBox(width: 12.w),
              Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Fee Collection', style: AppUI.cardTitle),
                    SizedBox(height: 2.h),
                    Text('Collect fees and view receipts for a student', style: AppUI.muted),
                  ]),
              const Spacer(),
              SizedBox(
                width: _compactCtx ? 150.w : 180.w,
                child: AppDropdownField<String>(
                  value: _selectedCourse,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12.r),
                  elevation: 6,
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _inputDec(schoolTerm('Select course'), filled: _selectedCourse != null),
                  style: _ddTextStyle(),
                  hint: _fitLine(schoolTerm('Select course'),
                      AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)),
                  items: _courseList.map((c) => DropdownMenuItem(value: c, child: Text(c, style: _ddItemStyle()))).toList(),
                  selectedItemBuilder: (context) => _courseList.map((c) => _fitLine(c, AppUI.fieldText(context, filled: true))).toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedCourse = val;
                      _selectedClass = null;
                      _classSuggestions = [];
                      if (val != null && _courseClassMap.containsKey(val)) {
                        _classList = List<String>.from(_courseClassMap[val]!);
                      } else if (val != null) {
                        _classList = List<String>.from(_allClasses);
                      } else {
                        _classList = List<String>.from(_allClasses);
                      }
                      _classList.sort(classOrdidComparator(_classOrdid));
                    });
                  },
                ),
              ),
              SizedBox(width: 10.w),
              SizedBox(
                width: _compactCtx ? 150.w : 180.w,
                child: Builder(builder: (_) {
                  final seen = <String>{};
                  final items = <DropdownMenuItem<String>>[];
                  for (final c in _classList) {
                    if (c.isEmpty || !seen.add(c)) continue;
                    items.add(DropdownMenuItem(value: c, child: Text(c, style: _ddItemStyle())));
                  }
                  final value = seen.contains(_selectedClass) ? _selectedClass : null;
                  return AppDropdownField<String>(
                    key: ValueKey(_selectedCourse),
                    value: value,
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12.r),
                    elevation: 6,
                    icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                    decoration: _inputDec(schoolTerm('Select class'), filled: value != null),
                    style: _ddTextStyle(),
                    hint: _fitLine(schoolTerm('Select class'),
                        AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)),
                    items: items,
                    selectedItemBuilder: (context) => items.map((m) => _fitLine((m.child as Text).data ?? '', AppUI.fieldText(context, filled: true))).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedClass = val;
                        _classController.text = val ?? '';
                        _classSuggestions = [];
                      });
                      if (val != null) _searchByClass(val);
                    },
                  );
                }),
              ),
              SizedBox(width: 10.w),
              CompositedTransformTarget(
                link: _admSearchLink,
                child: SizedBox(
                  width: _compactCtx ? 260.w : 340.w,
                  child: TextField(
                    controller: _admNoController,
                    onSubmitted: (_) => _search(),
                    onChanged: (v) { setState(() {}); _onSearchChanged(v); },
                    decoration: _inputDec(schoolTerm('Search by register no. or name'), filled: _admNoController.text.trim().isNotEmpty).copyWith(
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(left: 12, right: 8),
                        child: Icon(Icons.search, size: 18, color: AppColors.textLight),
                      ),
                    ),
                    style: AppUI.fieldText(context, filled: _admNoController.text.trim().isNotEmpty),
                  ),
                ),
              ),
              SizedBox(width: 10.w),
              ElevatedButton.icon(
                onPressed: _clear,
                icon: Icon(Icons.refresh, size: AppBtn.iconSize(context)),
                label: const Text('Clear'),
              ),
            ],
          ),
          if (_errorMsg != null) ...[
            SizedBox(height: 10.h),
            Container(
              padding: EdgeInsets.all(10.w),
              decoration: BoxDecoration(
                color: AppColors.errorBg,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(
                    color: AppColors.error.withValues(alpha: 0.3)),
              ),
              child: Text(_errorMsg!,
                  style: AppUI.body.copyWith(color: AppColors.error)),
            ),
          ],
        ],
      );
  }

  // ── Student Card ──
  Widget _buildStudentCardContent() {
    final name = _student!['stuname']?.toString() ?? '-';
    final admNo = _student!['stuadmno']?.toString() ?? '-';
    final className = _student!['stuclass']?.toString() ?? '-';
    final fatherName = _parent?['fathername']?.toString() ?? '-';
    final courseName = _student!['courname']?.toString() ?? '-';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        StudentAvatar(
          photoUrl: _student!['stuphoto']?.toString(),
          name: name,
          size: 44,
        ),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: AppUI.body.copyWith(fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis),
              SizedBox(height: 2.h),
              Text('${schoolTerm('Roll Number')}: $admNo', style: AppUI.muted),
            ],
          ),
        ),
        SizedBox(width: 16.w),
        Container(width: 1, height: 36.h, color: AppColors.divider),
        SizedBox(width: 16.w),
        Expanded(child: _detailRow('user', 'Father', fatherName)),
        SizedBox(width: 16.w),
        Container(width: 1, height: 36.h, color: AppColors.divider),
        SizedBox(width: 16.w),
        Expanded(child: _detailRow('book-1', schoolTerm('Course'), courseName)),
        SizedBox(width: 16.w),
        Container(width: 1, height: 36.h, color: AppColors.divider),
        SizedBox(width: 16.w),
        Expanded(child: _detailRow('teacher', schoolTerm('Class'), className)),
        SizedBox(width: 12.w),
        OutlinedButton.icon(
          onPressed: _openStudentReceipts,
          icon: Icon(Icons.receipt_long_outlined, size: AppBtn.iconSize(context)),
          label: const Text('Receipts'),
        ),
        SizedBox(width: 8.w),
        ElevatedButton.icon(
          onPressed: _openFeeDefinition,
          icon: Icon(Icons.fact_check_outlined, size: AppBtn.iconSize(context)),
          label: const Text('Fee Definition'),
        ),
      ],
    );
  }

  /// Open the per-student fee definition (opt the student in/out of each fee).
  Future<void> _openFeeDefinition() async {
    final s = _student;
    if (s == null) return;
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StudentFeeDefinitionDialog(
        insId: insId,
        stuAdmno: s['stuadmno']?.toString() ?? '',
        stuName: s['stuname']?.toString() ?? '',
        admName: s['admname']?.toString() ?? '',
        readOnly: _studentHasTc,
      ),
    );
    if (saved == true) {
      // Reload demands so newly-opted fees appear. _search() resolves by the
      // search field, which after the previous search holds the student NAME
      // (a fuzzy name match could land on a different student). Restore the
      // exact roll no first so _search's exact stuadmno lookup re-resolves
      // THIS student.
      _admNoController.text = s['stuadmno']?.toString() ?? '';
      _search();
    }
  }

  String _fmtReceiptDate(dynamic v) {
    if (v == null) return '-';
    final dt = DateTime.tryParse(v.toString());
    if (dt == null) return v.toString();
    return formatDmy(dt.toLocal());
  }

  /// Show the selected student's receipts with a per-row delete (void) option.
  Future<void> _openStudentReceipts() async {
    final s = _student;
    if (s == null) return;
    final stuId = s['stu_id'] as int?;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (stuId == null || insId == null) return;

    Future<List<Map<String, dynamic>>> load() async {
      final rows = await SupabaseService.fromSchema('payment')
          .select('pay_id, paynumber, paydate, createdat, transtotalamount, paymethod, recon_status')
          .eq('ins_id', insId)
          .eq('stu_id', stuId)
          .eq('activestatus', 1)
          .eq('paystatus', 'C')
          .order('createdat', ascending: false);
      final payments = List<Map<String, dynamic>>.from(rows as List);
      if (payments.isEmpty) return payments;

      // Attach each receipt's fee-line breakdown (paymentdetails -> feedemand).
      final payIds = payments.map((p) => p['pay_id']).whereType<int>().toList();
      final detRows = await SupabaseService.fromSchema('paymentdetails')
          .select('pay_id, dem_id, transtotalamount')
          .inFilter('pay_id', payIds)
          .eq('activestatus', 1);
      final dets = List<Map<String, dynamic>>.from(detRows as List);
      final demIds = dets.map((d) => d['dem_id']).whereType<int>().toSet().toList();
      final demInfo = <int, Map<String, dynamic>>{};
      if (demIds.isNotEmpty) {
        final demRows = await SupabaseService.fromSchema('feedemand')
            .select('dem_id, demfeetype, demfeeterm')
            .inFilter('dem_id', demIds);
        for (final d in List<Map<String, dynamic>>.from(demRows as List)) {
          final id = d['dem_id'] as int?;
          if (id != null) demInfo[id] = d;
        }
      }
      final byPay = <int, List<Map<String, dynamic>>>{};
      for (final d in dets) {
        final pid = d['pay_id'] as int?;
        if (pid == null) continue;
        final info = demInfo[d['dem_id'] as int?];
        byPay.putIfAbsent(pid, () => []).add({
          'type': info?['demfeetype']?.toString() ?? 'Fee',
          'term': info?['demfeeterm']?.toString() ?? '',
          'amount': (d['transtotalamount'] as num?)?.toDouble() ?? 0,
        });
      }
      for (final p in payments) {
        p['_details'] = byPay[p['pay_id'] as int?] ?? const [];
      }
      return payments;
    }

    await showDialog<void>(
      context: context,
      builder: (dctx) {
        return StatefulBuilder(builder: (dctx, setDlg) {
          // Small chip that identifies the tender used for a receipt.
          Widget methodChip(String methodRaw) {
            final m = methodRaw.toLowerCase();
            IconData ic;
            Color c;
            if (m.contains('cash')) {
              ic = Icons.payments_rounded; c = AppColors.success;
            } else if (m.contains('upi') || m.contains('qr')) {
              ic = Icons.qr_code_2_rounded; c = AppColors.accent;
            } else if (m.contains('cheque') || m.contains('dd')) {
              ic = Icons.description_rounded; c = AppColors.warning;
            } else if (m.contains('razor') || m.contains('online') || m.contains('net')) {
              ic = Icons.public_rounded; c = AppColors.accent;
            } else {
              ic = Icons.account_balance_wallet_rounded; c = AppColors.textSecondary;
            }
            return Container(
              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6.r),
                border: Border.all(color: c.withValues(alpha: 0.30)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(ic, size: 12, color: c),
                SizedBox(width: 4.w),
                Text(methodRaw.isEmpty ? '—' : methodRaw.toUpperCase(),
                    style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w700, color: c, letterSpacing: 0.2)),
              ]),
            );
          }

          Widget iconBtn({required IconData icon, required Color color, required String tip, VoidCallback? onTap}) {
            final enabled = onTap != null;
            return Tooltip(
              message: tip,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(9.r),
                child: Container(
                  padding: EdgeInsets.all(8.w),
                  decoration: BoxDecoration(
                    color: enabled ? color.withValues(alpha: 0.10) : AppColors.border.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(9.r),
                    border: Border.all(color: enabled ? color.withValues(alpha: 0.40) : AppColors.border),
                  ),
                  child: Icon(icon, size: 16, color: enabled ? color : AppColors.textLight),
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            titlePadding: EdgeInsets.fromLTRB(20.w, 18.h, 16.w, 6.h),
            contentPadding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 4.h),
            actionsPadding: EdgeInsets.fromLTRB(20.w, 0, 16.w, 14.h),
            title: Row(children: [
              AppUI.iconTile('receipt-2'),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Receipts', style: AppUI.cardTitle),
                  SizedBox(height: 2.h),
                  Text(
                    '${s['stuname'] ?? ''}'
                    '${(s['stuadmno']?.toString() ?? '').isNotEmpty ? '  •  ${s['stuadmno']}' : ''}',
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.muted,
                  ),
                ]),
              ),
            ]),
            content: SizedBox(
              width: 560.w,
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: load(),
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator()));
                  }
                  final receipts = snap.data ?? [];
                  if (receipts.isEmpty) {
                    return AppUI.empty(
                      title: 'No receipts yet',
                      why: 'Collected payments for this student will appear here.',
                      icon: 'receipt-2',
                    );
                  }
                  final grandTotal = receipts.fold<double>(
                      0, (t, p) => t + ((p['transtotalamount'] as num?)?.toDouble() ?? 0));
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(bottom: 8.h),
                        child: Row(children: [
                          Text('${receipts.length} receipt${receipts.length == 1 ? '' : 's'}',
                              style: AppUI.label.copyWith(color: AppColors.textSecondary)),
                          const Spacer(),
                          Text('Total  ', style: AppUI.muted),
                          Text('₹${formatIndianNumber(grandTotal)}',
                              style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
                        ]),
                      ),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: 400.h),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: receipts.length,
                            itemBuilder: (_, i) {
                              final p = receipts[i];
                              final no = p['paynumber']?.toString() ?? '-';
                              final method = (p['paymethod']?.toString() ?? '').toLowerCase();
                              final recon = p['recon_status']?.toString() ?? 'P';
                              final locked = recon == 'R' && method != 'cash';
                              final amt = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
                              final date = _fmtReceiptDate(p['paydate'] ?? p['createdat']);
                              final details = (p['_details'] as List?) ?? const [];
                              return Container(
                                margin: EdgeInsets.only(bottom: 10.h),
                                decoration: AppUI.card(radius: 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // ── Receipt header ──
                                    Padding(
                                      padding: EdgeInsets.fromLTRB(12.w, 11.h, 10.w, 11.h),
                                      child: Row(children: [
                                        Expanded(
                                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                            Row(children: [
                                              Flexible(
                                                child: Text(no,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                                              ),
                                              if (locked) ...[
                                                SizedBox(width: 8.w),
                                                Container(
                                                  padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
                                                  decoration: BoxDecoration(
                                                    color: AppColors.success.withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(5.r),
                                                  ),
                                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                    Icon(Icons.verified_rounded, size: 11, color: AppColors.success),
                                                    SizedBox(width: 3.w),
                                                    Text('RECONCILED',
                                                        style: TextStyle(fontSize: 9.sp, fontWeight: FontWeight.w800, color: AppColors.success, letterSpacing: 0.3)),
                                                  ]),
                                                ),
                                              ],
                                            ]),
                                            SizedBox(height: 5.h),
                                            Row(children: [
                                              Icon(Icons.event_rounded, size: 12, color: AppColors.textLight),
                                              SizedBox(width: 4.w),
                                              Text(date, style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                                              SizedBox(width: 8.w),
                                              methodChip(p['paymethod']?.toString() ?? ''),
                                            ]),
                                          ]),
                                        ),
                                        SizedBox(width: 10.w),
                                        Text('₹${formatIndianNumber(amt)}',
                                            style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
                                        SizedBox(width: 12.w),
                                        iconBtn(
                                          icon: Icons.print_rounded,
                                          color: AppColors.accent,
                                          tip: 'View / print receipt',
                                          onTap: () {
                                            final pid = (p['pay_id'] as num?)?.toInt();
                                            Navigator.pop(dctx);
                                            if (pid != null) _downloadReceipt(pid, no);
                                          },
                                        ),
                                        // Delete removed: receipts are cancelled from
                                        // Fees → Fee Cancel Receipt, not from here.
                                      ]),
                                    ),
                                    // ── Fee breakdown ──
                                    if (details.isNotEmpty)
                                      Container(
                                        width: double.infinity,
                                        padding: EdgeInsets.fromLTRB(12.w, 8.h, 12.w, 9.h),
                                        decoration: BoxDecoration(
                                          color: AppColors.surface,
                                          borderRadius: BorderRadius.only(
                                            bottomLeft: Radius.circular(11.r),
                                            bottomRight: Radius.circular(11.r),
                                          ),
                                          border: const Border(top: BorderSide(color: AppColors.divider)),
                                        ),
                                        child: Column(
                                          children: [
                                            for (final d in details)
                                              Padding(
                                                padding: EdgeInsets.symmetric(vertical: 2.5.h),
                                                child: Row(children: [
                                                  Container(width: 4.w, height: 4.w, margin: EdgeInsets.only(right: 8.w),
                                                      decoration: BoxDecoration(color: AppColors.textLight, shape: BoxShape.circle)),
                                                  Expanded(
                                                    child: Text(
                                                      (d['term']?.toString() ?? '').isNotEmpty
                                                          ? '${d['type']} — ${d['term']}'
                                                          : '${d['type']}',
                                                      style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary),
                                                    ),
                                                  ),
                                                  Text('₹${formatIndianNumber((d['amount'] as num?)?.toDouble() ?? 0)}',
                                                      style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                                ]),
                                              ),
                                            Padding(
                                              padding: EdgeInsets.only(top: 6.h),
                                              child: Row(children: [
                                                Expanded(child: Container(height: 1, color: AppColors.divider)),
                                              ]),
                                            ),
                                            Padding(
                                              padding: EdgeInsets.only(top: 6.h),
                                              child: Row(children: [
                                                Text('Total', style: TextStyle(fontSize: 11.5.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                                                const Spacer(),
                                                Text('₹${formatIndianNumber(amt)}',
                                                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                                              ]),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: const Text('Close'),
              ),
            ],
          );
        });
      },
    );
    // A delete restores demands to pending — refresh the page for this student.
    if (mounted) {
      _admNoController.text = s['stuadmno']?.toString() ?? '';
      _search();
    }
  }

  // ── Term Filter ──
  Widget _buildTermFilterContent() {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.fieldLabel('Filter by Term'),
          AppDropdownField<String?>(
            value: _selectedTerm,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            decoration: AppUI.field(context, '', filled: _selectedTerm != null),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text('All', style: AppUI.fieldText(context))),
              ..._terms.map((t) => DropdownMenuItem<String?>(value: t, child: Text(t, style: AppUI.fieldText(context)))),
            ],
            selectedItemBuilder: (context) => [
              Align(alignment: Alignment.centerLeft, child: Text('All', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
              ..._terms.map((t) => Align(alignment: Alignment.centerLeft, child: Text(t, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
            ],
            onChanged: (v) => setState(() => _selectedTerm = v),
          ),
        ],
      );
  }


  // ── Demands Panel ──
  Widget _buildDemandsPanel() {
    return Container(
      decoration: AppUI.card(),
      child: Column(
        children: [
          // Panel header
          Container(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14, AppUI.cardPad, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                AppUI.iconTile('document-text', size: 18),
                SizedBox(width: 12.w),
                Text('Pending Fee Demands', style: AppUI.cardTitle),
                if (_allDemands.isNotEmpty) ...[
                  SizedBox(width: 8.w),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: 8.w, vertical: 2.h),
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${_filteredDemands.length} of ${_currentTypeDemands.length} items',
                      style: TextStyle(
                          fontSize: 12.sp,
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
                const Spacer(),
                if (_student != null && _hasRegular && _hasArrear) ...[
                  _buildSeqTypeToggle(),
                  SizedBox(width: 12.w),
                ] else if (_student != null && _allDemands.isNotEmpty) ...[
                  _buildSingleTypeBadge(_hasArrear ? 'ARREAR' : 'REGULAR'),
                  SizedBox(width: 12.w),
                ],
                // Arrear-only: pick which arrear YEAR to collect (each year =
                // its own receipt). "All Years" collects across years.
                if (_student != null && _seqType == 'ARREAR' && _arrearYears.isNotEmpty) ...[
                  Text('Arrear Year:', style: AppUI.label),
                  SizedBox(width: 8.w),
                  SizedBox(
                    width: 150.w,
                    child: AppDropdownField<String?>(
                      value: _selectedArrearYear,
                      isExpanded: true,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      style: AppUI.fieldText(context),
                      icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                      decoration: _headerDropdownDec(filled: _selectedArrearYear != null),
                      items: [
                        DropdownMenuItem<String?>(value: null, child: Text('All Years', style: AppUI.fieldText(context))),
                        ..._arrearYears.map((y) => DropdownMenuItem<String?>(value: y, child: Text(y, style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis))),
                      ],
                      selectedItemBuilder: (context) => [
                        Align(alignment: Alignment.centerLeft, child: Text('All Years', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                        ..._arrearYears.map((y) => Align(alignment: Alignment.centerLeft, child: Text(y, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                      ],
                      onChanged: (v) => _selectArrearYear(v),
                    ),
                  ),
                  SizedBox(width: 12.w),
                ],
                if (_student != null && _terms.isNotEmpty) ...[
                  Text('Fee Type:', style: AppUI.label),
                  SizedBox(width: 8.w),
                  SizedBox(
                    width: 200.w,
                    child: AppDropdownField<String?>(
                      value: _selectedTerm,
                      isExpanded: true,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      style: AppUI.fieldText(context),
                      icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                      decoration: _headerDropdownDec(filled: _selectedTerm != null),
                      items: [
                        DropdownMenuItem<String?>(value: null, child: Text('All Fee Types', style: AppUI.fieldText(context))),
                        ..._terms.map((t) => DropdownMenuItem<String?>(value: t, child: Text(t, style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis))),
                      ],
                      selectedItemBuilder: (context) => [
                        Align(alignment: Alignment.centerLeft, child: Text('All Fee Types', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                        ..._terms.map((t) => Align(alignment: Alignment.centerLeft, child: Text(t, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                      ],
                      onChanged: (v) => setState(() => _selectedTerm = v),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Student is holding unused advance money — say so loudly, right
          // above the demands the cashier is about to collect.
          // The student has left. Said before anything else on the panel,
          // because everything below it is a fee the counter will not take.
          if (_studentHasTc) _buildTcNotice(),

          // Both advances share ONE row, split down the middle: the student
          // advance (spendable here, RED) on the left, the admission advance
          // (not spendable here, AMBER) on the right. Two colours because they
          // behave differently -- one pays a demand, the other shrinks it --
          // and a cashier reading a single stripe of colour would treat them
          // the same. Either half takes the whole row when the other is absent.
          if (_student != null &&
              (_advances.isNotEmpty || _admissionAdvances.isNotEmpty))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_advances.isNotEmpty)
                      Expanded(child: _buildAdvanceBanner()),
                    if (_advances.isNotEmpty && _admissionAdvances.isNotEmpty)
                      SizedBox(width: 12.w),
                    if (_admissionAdvances.isNotEmpty)
                      Expanded(child: _buildAdmissionAdvanceNotice()),
                  ],
                ),
              ),
            ),

          // Content
          Expanded(child: _buildDemandsContent()),
        ],
      ),
    );
  }

  /// The highlight: this student has an advance with money left on it.
  ///
  /// Nothing is applied automatically. The cashier opens the dialog and
  /// decides which demands the advance pays and by how much.
  Widget _buildAdvanceBanner() {
    final planned = _pendingAdjust.isNotEmpty;
    final avail = _advanceAvailable;
    final nos = _advances.map((a) => a['advno']?.toString() ?? '').where((n) => n.isNotEmpty).join(', ');
    // Red: this is the notice that must stop the cashier before they take
    // cash, so it carries the loudest colour on the screen. Amber while a plan
    // is waiting to be written — the cashier must be able to tell at a glance
    // that the advance has NOT been spent yet.
    final tint = planned ? AppColors.warning : AppColors.error;
    // The sidebar navy, not a pale tint of the status colour: this panel sits
    // above a white grid, and a wash the same weight as the rows around it is
    // what let a cashier take cash from a student who was already in credit.
    // The margin belongs to the row that lays the two halves out.
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: tint, width: 1.4),
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(children: [
        AppIcon(planned ? 'empty-wallet-time' : 'empty-wallet-add', size: 18, color: tint),
        SizedBox(width: 10.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(
              planned
                  ? (_pendingAdvIsAdmission
                      ? 'Admission advance: ${formatIndianNumber(_pendingAdjustTotal)} will be taken off the fees, from $_pendingAdvNo'
                      : '${_pendingPlans.length > 1 ? '${_pendingPlans.length} advances' : 'Student advance'}: '
                          '${formatIndianNumber(_pendingAdjustTotal)} will be adjusted from $_pendingAdvNo')
                  : 'Student Advance: ₹${formatIndianNumber(avail)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5.sp, fontWeight: FontWeight.w700, color: AppColors.textOnPrimary),
            ),
            SizedBox(height: 2.h),
            Text(
              planned
                  ? (_pendingAdvIsAdmission
                      ? 'Admission advance: it reduces the fee rather than paying it. '
                          'Not saved yet. It is saved when you press the button below.'
                      : 'Not saved yet. It is written when you press the button below, along with any cash.')
                  : (_advances.length == 1
                      ? '$nos · Pays a fee demand like cash. Adjust it below instead of collecting money.'
                      : '${_advances.length} advances ($nos) · They pay a fee demand like cash. Adjust them below instead of collecting money.'),
              style: TextStyle(fontSize: 11.5.sp, color: AppColors.sidebarText),
            ),
          ]),
        ),
        SizedBox(width: 12.w),
        if (planned) ...[
          TextButton.icon(
            onPressed: () => setState(_clearPendingAdjust),
            icon: Icon(Icons.undo, size: 15.sp),
            label: const Text('Undo'),
            style: TextButton.styleFrom(foregroundColor: AppColors.sidebarText),
          ),
          SizedBox(width: 6.w),
        ],
        ElevatedButton.icon(
          onPressed: (_loadingDemands || _studentHasTc) ? null : _openAdvanceAdjust,
          icon: const Icon(Icons.call_made, size: 16),
          label: Text(planned ? 'Change' : 'Adjust'),
          // Status colour on purpose: red = unspent advance, amber = plan staged.
          style: ElevatedButton.styleFrom(backgroundColor: tint),
        ),
      ]),
    );
  }

  /// The student is holding an ADMISSION advance with money left on it.
  ///
  /// Read-only on purpose. An admission advance reduces the fee itself rather
  /// than paying a demand, which changes what the bill says — so it is applied
  /// on Fees -> Advance Adjustment, not at the collection counter. Without this
  /// notice the cashier would take cash for a fee that is about to shrink.
  /// "TC ISSUED" -- the student has left, so nothing here can be collected.
  Widget _buildTcNotice() {
    const tint = AppColors.error;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Row(children: [
        Icon(Icons.block, size: 18.sp, color: Colors.white),
        SizedBox(width: 10.w),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('TC Issued: Fees Cannot Be Collected',
                    style: TextStyle(
                        fontSize: 13.5.sp,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                        color: Colors.white)),
                SizedBox(height: 2.h),
                Text(
                  'This student has been issued a Transfer Certificate (TC). The dues '
                  'below are for reference only; no fee, advance or adjustment can '
                  'be collected. To collect, reactivate the student in TC → '
                  'Transfer Certificate Entry first.',
                  style: TextStyle(
                      fontSize: 11.5.sp, color: Colors.white.withValues(alpha: 0.92)),
                ),
              ]),
        ),
      ]),
    );
  }

  Widget _buildAdmissionAdvanceNotice() {
    // Amber, against the red of the student advance beside it. Both say "this
    // student already has money on them"; the colour says which kind, and the
    // one that CANNOT be spent at this counter is the one that is not red.
    const tint = AppColors.warning;
    final avail = _admissionAdvanceAvailable;
    final nos = _admissionAdvances
        .map((a) => a['advno']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .join(', ');
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: tint, width: 1.4),
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(children: [
        const AppIcon('empty-wallet-tick', size: 18, color: tint),
        SizedBox(width: 10.w),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Admission Advance: ₹${formatIndianNumber(avail)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13.5.sp,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textOnPrimary),
                ),
                SizedBox(height: 2.h),
                Text(
                  '${nos.isEmpty ? '' : '$nos · '}Reduces the fee rather than '
                  'paying it, so it cannot be adjusted here. Apply it in '
                  'Fees → Advance Reconcile.',
                  style: TextStyle(fontSize: 11.5.sp, color: AppColors.sidebarText),
                ),
              ]),
        ),
      ]),
    );
  }

  /// Spend part (or all) of the advance on this student's pending demands.
  ///
  /// The dialog does the write via adjust_advance, which settles the demands
  /// and raises a real fee receipt in one transaction. Afterwards the screen
  /// is re-searched so balances, the banner and the pending list all reflect
  /// what actually happened.
  Future<void> _openAdvanceAdjust() async {
    final student = _student;
    if (student == null || _advances.isEmpty) return;

    // What is planned right now, if anything. Taken BEFORE the reset below,
    // because reopening ("Change") has to show the plan the cashier made --
    // it used to open empty, which made Change mean "start again". One entry
    // per advance, so a plan spending two of them comes back whole.
    final planned = <int, Map<String, double>>{
      for (final pl in _pendingPlans) pl.advId: Map<String, double>.from(pl.lines),
    };
    final plannedSnapshot = List<_PlannedAdvance>.from(_pendingPlans);
    final plannedAdvId = _pendingAdvId;
    // Set by the Apply callback below; tells a plain Close from a Close that
    // followed an Apply.
    var staged = false;

    // Re-planning starts from a clean slate: restore every Collect Amount to
    // its full balance first, so a second pass through the dialog splits the
    // balance again rather than compounding on the previous split.
    _clearPendingAdjust();

    // Offer the demands the cashier is looking at (active type + filters), so
    // the dialog matches the list on screen.
    final rows = _filteredDemands
        .where((d) => ((d['balancedue'] as num?)?.toDouble() ?? 0) > 0)
        .toList();
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nothing pending to adjust the advance against.'),
        backgroundColor: AppColors.warning,
      ));
      return;
    }
    final prefill = <String, double>{
      for (final d in rows) _demKey(d): (d['balancedue'] as num?)?.toDouble() ?? 0,
    };

    final res = await showAdvanceAdjustDialog(
      context,
      student: student,
      advances: _advances,
      demands: rows,
      prefill: prefill,
      // Open EMPTY. The cashier picks the dues and the amounts; the dialog
      // pre-spending the advance for them is how money ended up against rows
      // nobody chose.
      preAllocate: false,
      // No breakdown: only STUDENT and MESS advances reach this screen, and
      // both are a plain amount. The dialog spends them oldest-due first.
      //
      // Each advance sees only the dues of the group it was banked into, so a
      // mess advance cannot be spent on tuition, nor tuition money on mess.
      demandsFor: (a) => _demandsForAdvance(a, rows),
      scopeOf: _advanceScope,
      initialDrafts: planned,
      initialAdvId: plannedAdvId,
      // Apply stages the plan and the dialog STAYS OPEN, the way the Fee
      // Definition dialog stays open after Save. The plan lands here the
      // moment Apply is pressed, so the Adjustment column and the Collect
      // Amounts move behind the still-open dialog.
      onApplied: (r) {
        staged = true;
        _stagePlan(r);
      },
    );
    if (!mounted) return;

    // Closed without applying anything: put back whatever was staged before,
    // so opening the dialog to look at it is not a way to lose it.
    if (!staged && planned.isNotEmpty) {
      _stagePlan(<String, dynamic>{
        'plans': [
          for (final pl in plannedSnapshot)
            {
              'adv_id': pl.advId,
              'advno': pl.advNo,
              'lines': [
                for (final e in pl.lines.entries)
                  {'dem_id': int.tryParse(e.key) ?? e.key, 'amount': e.value},
              ],
            },
        ],
      });
    }

    // Nothing has been written. Hold the plan, show it in the Adjustment
    // column, and drop each Collect Amount to whatever cash is still owed.
    if (res != null) _stagePlan(res);
  }

  /// Hold a plan the dialog handed back: nothing is written, the Adjustment
  /// column shows it, and each Collect Amount drops to whatever cash is still
  /// owed after it.
  void _stagePlan(Map<String, dynamic> res) {
    final plans = (res['plans'] as List?) ?? const [];
    setState(() {
      _pendingPlans.clear();
      _pendingAdjust.clear();
      for (final p in plans) {
        final m = p as Map;
        final advId = (m['adv_id'] as num?)?.toInt();
        if (advId == null) continue;
        final lines = <String, double>{};
        for (final l in (m['lines'] as List? ?? const [])) {
          final lm = l as Map;
          final k = lm['dem_id']?.toString() ?? '';
          final amt = (lm['amount'] as num?)?.toDouble() ?? 0;
          if (k.isEmpty || amt <= 0) continue;
          lines[k] = (lines[k] ?? 0) + amt;
          // The ADJUSTMENT column and every cash cap read this aggregate: a
          // row shared by two advances must show what BOTH put on it.
          _pendingAdjust[k] = (_pendingAdjust[k] ?? 0) + amt;
        }
        if (lines.isEmpty) continue;
        _pendingPlans.add(_PlannedAdvance(
            advId: advId, advNo: m['advno']?.toString() ?? '', lines: lines));
      }
      _applyPendingToCollectAmounts();
    });
  }

  /// The most CASH this row can still take: its balance less anything the
  /// planned advance adjustment will settle.
  ///
  /// Every place that fills or clamps a Collect Amount goes through this. They
  /// used to use the raw balance, so ticking a checkbox after planning an
  /// adjustment refilled the row with the full balance and the student was
  /// charged for the same money twice — once from the advance, once in cash.
  double _collectCap(Map<String, dynamic> d) {
    final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
    final adj = _pendingAdjust[_demKey(d)] ?? 0;
    final left = bal - adj;
    return left > 0 ? left : 0;
  }

  /// Collect Amount = what is STILL owed in CASH after the planned adjustment.
  ///
  /// A row the advance covers in full drops to 0 but STAYS TICKED: the tick
  /// means "this demand is part of this transaction", not "this demand is being
  /// paid in cash". Keeping it ticked is what puts it on the same receipt as
  /// the cash rows — the payment builder already skips any row whose net is 0,
  /// so it costs the cashier nothing, and the advance settles it on attach.
  void _applyPendingToCollectAmounts() {
    for (final d in _allDemands) {
      final k = _demKey(d);
      final ctrl = _conCtrl[k];
      if (ctrl == null) continue;
      if (!_matchesSeqType(d)) continue;
      final remaining = _collectCap(d);
      final adjusted = (_pendingAdjust[k] ?? 0) > 0;
      ctrl.text = remaining > 0 ? remaining.toStringAsFixed(0) : '0';
      if (remaining > 0 || adjusted) {
        _selected.add(k);
      } else {
        _selected.remove(k);
      }
    }
  }

  /// Forget the plan and put every Collect Amount back to the full balance.
  void _clearPendingAdjust() {
    if (_pendingAdjust.isEmpty && _pendingPlans.isEmpty) return;
    _pendingAdjust.clear();
    _pendingPlans.clear();
    for (final d in _allDemands) {
      final k = _demKey(d);
      final ctrl = _conCtrl[k];
      if (ctrl == null) continue;
      final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
      final active = _matchesSeqType(d);
      ctrl.text = (active && bal > 0) ? bal.toStringAsFixed(0) : '0';
      if (active && bal > 0) {
        _selected.add(k);
      } else {
        _selected.remove(k);
      }
    }
  }

  /// Write the planned adjustment.
  ///
  /// [payId] is the receipt the cashier just raised for the cash half. Passing
  /// it makes adjust_advance ATTACH to that receipt — one receipt number, one
  /// row in Transactions, and a total that reads cash + advance. Without it
  /// (the advance covered everything, so there is no cash receipt) the RPC
  /// raises its own.
  ///
  /// Returns false, with the reason on screen, if the server refused.
  Future<bool> _commitPendingAdjust({int? payId}) async {
    if (_pendingAdjust.isEmpty || _pendingPlans.isEmpty) return true;
    final auth = context.read<AuthProvider>();
    try {
      // ONE CALL PER ADVANCE. adjust_advance spends a single advance, and each
      // one has its own balance to draw down and its own adjustment receipt --
      // so a plan that spends two is two calls, not one merged list.
      final nosAll = <String>[];
      var adjusted = 0.0;
      for (final plan in _pendingPlans) {
        final lines = plan.lines.entries
            .where((e) => e.value > 0)
            .map((e) =>
                {'dem_id': int.tryParse(e.key) ?? e.key, 'amount': e.value})
            .toList();
        if (lines.isEmpty) continue;
        final res = await SupabaseService.client.rpc('adjust_advance', params: {
          'p_token': auth.sessionToken,
          'p_adv_id': plan.advId,
          'p_lines': lines,
          'p_created_by': auth.userName,
          if (payId != null) 'p_pay_id': payId,
        });
        final receipts =
            (res is Map ? res['receipts'] as List? : null) ?? const [];
        nosAll.addAll(receipts
            .map((r) => (r as Map)['paynumber']?.toString() ?? '')
            .where((n) => n.isNotEmpty));
        adjusted += (res is Map ? (res['adjusted'] as num?)?.toDouble() : null) ??
            plan.lines.values.fold<double>(0, (a, b) => a + b);
      }
      final nos = nosAll.join(', ');
      if (mounted && payId == null) {
        // Standalone only. When it attaches, the payment's own success dialog
        // already names the receipt — two toasts for one action is noise.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(nos.isEmpty
              ? '${formatIndianNumber(adjusted)} adjusted from $_pendingAdvNo.'
              : '${formatIndianNumber(adjusted)} adjusted from $_pendingAdvNo — receipt $nos.'),
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 5),
        ));
      }
      // Committed: the plan is now history, so it must not be written twice.
      _pendingPlans.clear();
      _pendingAdjust.clear();

      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Advance not adjusted. ${friendlyError(e)}'),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 6),
        ));
      }
      return false;
    }
  }

  /// The footer's single action.
  ///
  /// CASH FIRST, then the advance attaches to the receipt it produced — that
  /// ordering is what gives one receipt for the whole settlement. The payment
  /// path calls _attachPendingAdjust once it has a pay_id, before it shows the
  /// success dialog, so the printed receipt already carries the advance.
  ///
  /// With no cash to take (the advance covers everything) there is no receipt
  /// to attach to, so the adjustment is written standalone. A STUDENT advance
  /// raises its own receipt then, because it settles the demand like cash; an
  /// admission advance raises none, because it reduces the bill instead.
  Future<void> _onFooterAction() async {
    // An ADMISSION advance reduces the fee; it is not a payment, so it is
    // written FIRST and on its own document, never folded into the cash
    // receipt. Reducing first also leaves the cash payment settling the
    // already-reduced balance.
    if (_pendingAdjust.isNotEmpty && _pendingAdvIsAdmission) {
      final ok = await _commitPendingAdjust();
      if (!ok || !mounted) return;
      if (_totalNetSelected <= 0 || _paymentMode == null) {
        await _search();
        return;
      }
      // Fall through: take the remaining cash on its own receipt.
    }

    if (_totalNetSelected > 0 && _paymentMode != null) {
      if (_paymentMode == 'Cash') {
        await _saveCashPayment();
      } else {
        await _onCollectAndReceipt();
      }
      return;
    }
    if (_pendingAdjust.isEmpty) return;
    final ok = await _commitPendingAdjust();
    if (!ok || !mounted) return;
    // Re-read so balances and the banner catch up.
    await _search();
  }

  /// Which of today's receipts the planned advance belongs on.
  ///
  /// The RPC raises ONE PAYMENT PER FEE GROUP, so a cashier taking college
  /// fees in cash while settling the mess due from a mess advance ends up with
  /// two receipts. Attaching the adjustment to whichever came back first would
  /// credit the college receipt with money that came out of the hostel
  /// account. Match the advance's own side of the ledger instead, falling back
  /// to [fallback] when no receipt carries an fg_id to match on.
  int? _payIdForPendingAdvance(List<dynamic> receipts, int? fallback) {
    if (_pendingAdvId == null || receipts.isEmpty) return fallback;
    final adv = _advances.firstWhere(
        (a) => (a['adv_id'] as num?)?.toInt() == _pendingAdvId,
        orElse: () => const <String, dynamic>{});
    if (adv.isEmpty) return fallback;
    final wantHostel = _advanceIsMess(adv);
    final hostelFgIds = <int>{
      for (final e in _fgName.entries)
        if (e.value.contains('HOSTEL') || e.value.contains('MESS')) e.key,
    };
    for (final r in receipts) {
      if (r is! Map) continue;
      final fg = (r['fg_id'] as num?)?.toInt();
      final raw = r['pay_id'];
      final payId = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
      if (fg == null || payId == null) continue;
      if (hostelFgIds.contains(fg) == wantHostel) return payId;
    }
    return fallback;
  }

  /// Called from inside the payment path the moment a pay_id exists and before
  /// the receipt is built. Failure here must NOT fail the payment — the cash is
  /// already taken and recorded; the advance simply stays unspent and the
  /// cashier is told so.
  Future<void> _attachPendingAdjust(int? payId) async {
    if (payId == null || _pendingAdjust.isEmpty) return;
    // An admission advance is already written by _onFooterAction, on its own
    // document. Attaching it here would add money to a cash receipt that never
    // received it.
    if (_pendingAdvIsAdmission) return;
    final ok = await _commitPendingAdjust(payId: payId);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'The cash was collected, but the advance could not be adjusted. '
            'It is still available — apply it again.'),
        backgroundColor: AppColors.warning,
        duration: Duration(seconds: 6),
      ));
    }
  }

  /// One demand row inside its fee group's card. [i] is the row's position
  /// WITHIN the group, so the zebra striping restarts in every card.
  Widget _buildDemandRow(Map<String, dynamic> d, int i) {
              final key = _demKey(d);
              // A row outside the group being collected is read-only: its tick
              // and its amount fields are dead. Money for it is taken on its
              // own receipt, after this one.
              final inGroup = _inPayGroup(d);
              final isSelected = _selected.contains(key);
              final feeAmt =
                  (d['feeamount'] as num?)?.toDouble() ?? 0;
              final bal =
                  (d['balancedue'] as num?)?.toDouble() ?? 0;
              // ADJUSTMENT means one thing only: how much of THIS row the
              // advance will settle when the cashier saves. It used to add in
              // what an earlier adjustment had already settled, which reads as
              // an adjustment nobody made -- and is double counting besides,
              // because a past adjustment is already inside Bal. Amt. The past
              // figure is still here, in the row's tooltip.
              final adjustedSaved = _adjustedByDem[key] ?? 0;
              final adjustedPlanned = _pendingAdjust[key] ?? 0;
              // An advance is earmarked against this row in THIS transaction,
              // so its tick is locked (see the checkbox below).
              final hasAdjustment = adjustedPlanned > 0;
              final dueDate = d['duedate']?.toString() ?? '-';
              final shortDate = dueDate.length >= 10
                  ? _formatDate(dueDate.substring(0, 10))
                  : dueDate;

              return FocusTraversalGroup(child: Container(
                key: ValueKey('row-$key'),
                // Proper zebra: alternate white / warm stone by row parity,
                // independent of selection (surface #F9F8F4 was too close to
                // white to read).
                color: i.isEven ? Colors.white : AppColors.accent.withValues(alpha: 0.05),
                padding: EdgeInsets.symmetric(
                    horizontal: 12.w, vertical: 10.h),
                child: Row(
                  children: [
                    SizedBox(
                      width: 32.w,
                      child: Tooltip(
                        message: [
                          if (hasAdjustment)
                            '${formatIndianNumber(adjustedPlanned)} '
                                '${_pendingAdvIsAdmission ? 'will reduce this fee' : 'will settle this row'} '
                                'from advance $_pendingAdvNo. Not saved yet. '
                                'Use Undo or Change on the banner above.',
                          if (adjustedSaved > 0)
                            '${formatIndianNumber(adjustedSaved)} was settled from an '
                                'advance earlier. It is already deducted from the balance '
                                'amount. To reverse it, cancel its receipt in '
                                'Fee Cancel Receipt.',
                        ].join('\n\n'),
                        child: _selected.held.contains(key)
                            ? Tooltip(
                                message: 'A concession on this fee is waiting in Fees → Concession Approval. '
                                    'It can be collected once that is approved or rejected.',
                                child: Icon(Icons.hourglass_top_rounded, size: 18.sp, color: AppColors.warning),
                              )
                            : Checkbox(
                        value: isSelected,
                        // LOCKED while an advance is earmarked against this row.
                        // The plan is made in one place — the Adjust Advance
                        // dialog — and a stray click here would either strand
                        // the advance or drop a demand the advance is paying
                        // for. Undo / Change on the banner is the way out.
                        onChanged: (!hasAdjustment && inGroup)
                            ? (v) {
                                // Checking auto-fills Col Amount with what is
                                // still owed IN CASH; unchecking resets it to 0
                                // so it doesn't reach any subsequent total.
                                final colCtrl = _conCtrl[key];
                                final cap = _collectCap(d);
                                setState(() {
                                  if (v == true) {
                                    _selected.add(key);
                                    if (colCtrl != null) {
                                      colCtrl.text = cap > 0 ? cap.toStringAsFixed(0) : '0';
                                    }
                                  } else {
                                    _selected.remove(key);
                                    if (colCtrl != null) colCtrl.text = '0';
                                  }
                                });
                              }
                            : null,
                        fillColor: WidgetStateProperty.resolveWith((s) =>
                            s.contains(WidgetState.selected)
                                ? AppColors.accent
                                : null),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      ),
                    ),
                    _TDCell(d['demfeeterm']?.toString() ?? '-',
                        flex: 2,
                        style: AppUI.cell),
                    _TDCell(d['demfeetype']?.toString() ?? '-',
                        flex: 3,
                        style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
                    _TDCell(shortDate,
                        flex: 2,
                        style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
                    _TDCell(formatIndianNumber(feeAmt),
                        flex: 2,
                        textAlign: TextAlign.right,
                        style: AppUI.money.copyWith(fontWeight: FontWeight.w500)),
                    _TDCell(formatIndianNumber(bal),
                        flex: 2,
                        textAlign: TextAlign.right,
                        style: AppUI.money.copyWith(color: AppColors.warning)),
                    // Already settled out of an advance. A dash, not a 0, when
                    // nothing was adjusted — a column of zeroes reads as if
                    // every row had been touched and came to nothing.
                    if (!isSchool) _TDCell(
                        adjustedPlanned > 0
                            ? formatIndianNumber(adjustedPlanned)
                            : '—',
                        flex: 2,
                        textAlign: TextAlign.right,
                        style: AppUI.money.copyWith(
                            fontWeight: adjustedPlanned > 0
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: adjustedPlanned > 0
                                ? AppColors.warning
                                : AppColors.textLight)),
                    // Col Amount editable — clamp to balance due. Typing a
                    // positive amount auto-checks the row; clearing it back
                    // to 0 / empty auto-unchecks. setState is gated so it
                    // only fires when the selection actually flips (or on
                    // clamp), so the TextField keeps focus on every
                    // keystroke within the same state. The selected-tint and
                    // NET AMOUNT total still refresh on those flips.
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4.w),
                        child: _numField(
                            // Nothing to type: the advance covers the row in
                            // full, so the cash cap is 0 and every keystroke
                            // would snap straight back.
                            enabled: inGroup && !(hasAdjustment && _collectCap(d) <= 0),
                            _conCtrl[key], () {
                          final ctrl = _conCtrl[key];
                          double entered = 0;
                          bool clamped = false;
                          if (ctrl != null) {
                            entered = double.tryParse(ctrl.text) ?? 0;
                            // Cap on the CASH still owed, not the raw balance:
                            // with an advance planned against this row, the
                            // difference is already being settled from the
                            // advance and must not be collected again.
                            final cap = _collectCap(d);
                            if (entered > cap) {
                              final clampedText = cap.toStringAsFixed(0);
                              ctrl.value = TextEditingValue(
                                text: clampedText,
                                selection: TextSelection.collapsed(offset: clampedText.length),
                              );
                              entered = cap;
                              clamped = true;
                              if (mounted) {
                                final planned = _pendingAdjust[key] ?? 0;
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(
                                      content: Text(planned > 0
                                          ? 'Only ${formatIndianNumber(cap)} is payable in cash — '
                                              '${formatIndianNumber(planned)} of this row is being adjusted from the advance.'
                                          : 'Collect amount cannot be more than the balance due (₹${formatIndianNumber(bal)}).'),
                                      backgroundColor: AppColors.error,
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                              }
                            }
                          }
                          // Debounce the auto-check setState — keystrokes
                          // within the same row reset a 350ms timer. The
                          // setState fires only once after typing pauses, so
                          // the user can type 5000 without losing focus per
                          // digit. Clamp errors are surfaced immediately,
                          // since those require a snackbar.
                          if (clamped) {
                            setState(() {});
                          }
                          _conFlipTimers[key]?.cancel();
                          _conFlipTimers[key] = Timer(const Duration(milliseconds: 350), () {
                            if (!mounted) return;
                            final c = _conCtrl[key];
                            if (c == null) return;
                            final v = double.tryParse(c.text) ?? 0;
                            final shouldSelect = v > 0;
                            final isAlready = _selected.contains(key);
                            if (shouldSelect == isAlready) return;
                            // Capture focus before the rebuild and re-grab
                            // it afterwards. Without this the row's
                            // selection-state rebuild can drop focus on the
                            // Col Amount field — particularly when the user
                            // is back-spacing the value down to 0.
                            final node = _conCtrl[key] != null ? _conFocus[key] : null;
                            final hadFocus = node?.hasFocus ?? false;
                            setState(() {
                              if (shouldSelect) {
                                _selected.add(key);
                              } else {
                                _selected.remove(key);
                              }
                            });
                            if (hadFocus && node != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted && !node.hasFocus) node.requestFocus();
                              });
                            }
                          });
                        }, fieldKey: 'col-$key', focusNode: _conFocus.putIfAbsent(key, () => FocusNode())),
                      ),
                    ),
                    // Fine editable — only when the row is checked. The
                    // cashier has to tick the row (or type a Col Amount that
                    // auto-checks it) before adjusting the fine.
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4.w),
                        child: _numField(_fineCtrl[key], () => setState(() {}), maxLength: 4, fieldKey: 'fine-$key', focusNode: _fineFocus.putIfAbsent(key, () => FocusNode()), enabled: isSelected && inGroup),
                      ),
                    ),
                    // Net Amt — listens to the row's Col + Fine controllers
                    // so it refreshes on every keystroke instead of waiting
                    // for the debounce-driven setState.
                    Expanded(
                      flex: 2,
                      child: ListenableBuilder(
                        listenable: Listenable.merge([
                          if (_conCtrl[key] != null) _conCtrl[key]!,
                          if (_fineCtrl[key] != null) _fineCtrl[key]!,
                        ]),
                        builder: (_, __) {
                          final live = _netAmt(d);
                          // Same 6.w gutter every other cell carries, so the
                          // figure does not sit hard against the table edge.
                          return Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6.w),
                            child: Text(
                            formatIndianNumber(live),
                            textAlign: TextAlign.right,
                            style: AppUI.money.copyWith(
                                color: live > 0
                                    ? AppColors.error
                                    : AppColors.textPrimary),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ));
  }

  Widget _buildDemandsContent() {
    if (_loadingDemands) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }

    if (_student == null) {
      return AppUI.empty(
        title: 'Search for a student to view pending fees',
        why: schoolTerm('Select a course and class, or search by register no. or name above.'),
        icon: 'search-normal-1',
      );
    }

    if (_filteredDemands.isEmpty) {
      return AppUI.empty(
        title: 'No pending fee demands',
        why: 'Nothing is outstanding for this student under the current selection.',
        icon: 'tick-circle',
      );
    }

    final demands = _filteredDemands;
    // One block per fee group -- one receipt per block.
    final blocks = _fgBlocks(demands);

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius + 2),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Column(
      children: [
        // One card per fee group. College and hostel fees are collected on
        // SEPARATE receipts, from separate sequences, into separate bank
        // accounts -- so they are never drawn as one merged table.
        Expanded(
          child: AppVerticalScrollbar(
            builder: (context, controller) => FocusTraversalGroup(
              child: ListView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12.w, 12.h, 12.w, 6.h),
                itemCount: blocks.length,
                itemBuilder: (context, gi) => _buildGroupCard(blocks[gi]),
              ),
            ),
          ),
        ),

        // Footer
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
          decoration: BoxDecoration(
            color: Colors.white,
            border: const Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle,
                  size: 17.sp,
                  color: _selected.isEmpty ? AppColors.textLight : AppColors.accent),
              SizedBox(width: 7.w),
              Text(
                '${_selected.length} of ${_payGroupDemands.length} selected'
                '${_payFgId == null ? '' : ' in ${_fgName[_payFgId] ?? ''}'}',
                style: AppUI.label,
              ),
              // What this payment does NOT cover. Without it the cashier reads
              // a settled student off a screen that is only showing one group.
              if (_otherGroupsOutstanding.isNotEmpty) ...[
                SizedBox(width: 10.w),
                // Most of the free space (the Spacer after it keeps only a
                // little), up to two lines, and the whole text on hover --
                // a half-hidden "Still due" defeats its purpose.
                Flexible(
                  flex: 6,
                  child: Builder(builder: (context) {
                    final dues = _otherGroupsOutstanding.entries
                        .map((e) => '${e.key} ₹${formatIndianNumber(e.value)}')
                        .join(', ');
                    final text = 'Still due: $dues. Collect it separately (own receipt).';
                    return Tooltip(
                      message: text,
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5.sp,
                            fontWeight: FontWeight.w600,
                            color: AppColors.warning),
                      ),
                    );
                  }),
                ),
              ],
              const Spacer(),
              if (_selected.isNotEmpty) ...[
                Container(
                  height: AppUI.controlHeight(context),
                  padding: EdgeInsets.symmetric(horizontal: 16.w),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // Tinted, not solid: the figure reads as information, while
                    // the solid blue is reserved for the one button that acts.
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.30)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Net Amount: ',
                          style: AppUI.label.copyWith(letterSpacing: 0.3)),
                      // Live total — subscribes to every visible row's
                      // col/fine controller so it ticks per keystroke
                      // without rebuilding the TextField (which would steal
                      // focus mid-typing).
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          ..._conCtrl.values,
                          ..._fineCtrl.values,
                        ]),
                        builder: (_, __) => Text(
                          '${formatIndianNumber(_totalNetSelected)}',
                          style: AppUI.money.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 14.w),
              ],
              SizedBox(width: 6.w),
              // Payment-mode dropdown — sits just before the Save / Proceed
              // to Pay button so the cashier picks the mode and commits in
              // one motion.
              // Wrap a borderless DropdownButton in the same padded
              // container shape as the NET AMOUNT pill so the two visually
              // match in height + corner radius.
              // The payment mode is offered only while NET AMOUNT is above
              // zero. With nothing to collect there is no money to attribute to
              // a mode, and a settlement the advance covers in full is saved
              // without one -- picking CASH there would label a payment that
              // never happened. Rebuilt on the same controllers as the NET
              // AMOUNT pill beside it, so it greys out on the keystroke that
              // clears the last Col Amount rather than on the next rebuild.
              ListenableBuilder(
                listenable: Listenable.merge([
                  ..._conCtrl.values,
                  ..._fineCtrl.values,
                ]),
                builder: (_, __) {
                  final modeEnabled = _totalNetSelected > 0 && !_studentHasTc;
                  // The group being collected has no bank account: Cash only.
                  final cashOnly = _payFgId != null && _fgWithoutBank.contains(_payFgId);
                  if (cashOnly && _paymentMode != null && _paymentMode != 'Cash') _paymentMode = null;
                  Widget modeText(String t) => Text(cashOnly ? '$t - needs a bank account' : t,
                      overflow: TextOverflow.ellipsis,
                      style: cashOnly ? TextStyle(color: AppColors.textLight, fontWeight: FontWeight.w500, fontSize: 12.sp) : null);
                  final field = Container(
                    width: 160.w,
                    height: AppUI.controlHeight(context),
                    padding: EdgeInsets.symmetric(horizontal: 12.w),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      // White until a mode is picked, then outlined in accent — the
                      // field shows at a glance whether the cashier still has to
                      // choose. Same treatment as Advance / Misc Collection.
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                      border: Border.all(
                          color: (!modeEnabled || _paymentMode == null)
                              ? AppColors.border
                              : AppColors.primary.withValues(alpha: 0.55)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: modeEnabled ? _paymentMode : null,
                        isExpanded: true,
                        isDense: false,
                        hint: Text('Select payment mode', style: AppUI.fieldText(context).copyWith(color: AppColors.textLight, letterSpacing: 0.3)),
                        icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        style: AppUI.fieldText(context, filled: true).copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3),
                        items: [
                          const DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                          DropdownMenuItem(value: 'QR/UPI', enabled: !cashOnly, child: modeText('QR / UPI')),
                          if (_onlineGateway != null)
                            DropdownMenuItem(
                                value: 'Online',
                                enabled: !cashOnly,
                                child: modeText(_onlineGateway!.provider.isEmpty
                                    ? 'Online'
                                    : 'Online (${pgProvider(_onlineGateway!.provider)?.name ?? _onlineGateway!.name})')),
                          // No gateway in Setup > Payment Gateways: no online mode. (The
                          // old Paytm mode recorded payments from this PC through
                          // database functions now closed to the app.)
                          DropdownMenuItem(value: 'Cheque', enabled: !cashOnly, child: modeText('Cheque')),
                          DropdownMenuItem(value: 'DD', enabled: !cashOnly, child: modeText('DD')),
                        ],
                        onChanged: modeEnabled
                            ? (v) => setState(() => _paymentMode = v)
                            : null,
                      ),
                    ),
                  );
                  return modeEnabled
                      ? field
                      : Tooltip(
                          message: _pendingAdjust.isNotEmpty
                              ? 'The advance covers the whole amount. Save the adjustment; no payment mode is needed.'
                              : 'Tick a fee and enter a collect amount first.',
                          child: field);
                },
              ),
              SizedBox(width: 10.w),
              // Match the NET AMOUNT pill + Mode dropdown visually: same
              // accent-tinted fill, same border, same height, same corner
              // radius. Keeps the three footer elements as a unified triple.
              SizedBox(
                child: Tooltip(
                  message: _studentHasTc
                      ? 'This student has been issued a transfer certificate.'
                      : _selected.isEmpty
                          ? 'Tick at least one due.'
                          : (_totalNetSelected > 0 && _paymentMode == null)
                              ? 'Select a payment mode first.'
                              : '',
                  child: ElevatedButton.icon(
                  // A pure adjustment (advance covers everything) needs no
                  // payment mode — no cash is changing hands. Cash still does.
                  onPressed: (_studentHasTc ||
                          (_totalNetSelected > 0
                              ? (_selected.isEmpty || _paymentMode == null)
                              : _pendingAdjust.isEmpty))
                      ? null
                      : _onFooterAction,
                  icon: Icon(
                      _totalNetSelected <= 0 && _pendingAdjust.isNotEmpty
                          ? Icons.check
                          : (_isGatewayMode ? Icons.open_in_new : Icons.send),
                      size: AppBtn.iconSize(context)),
                  label: Text(_totalNetSelected <= 0 && _pendingAdjust.isNotEmpty
                      ? 'Save Adjustment'
                      : (_paymentMode == 'Cash' ? 'Save & Collect' : 'Proceed to Pay')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
        ),
      ),
    );
  }

  bool _processing = false;

  /// Save a Cash payment. Runs the sequence pre-check then shows a small
  /// dialog asking for the tender amount; the refund (change) is computed
  /// live as the cashier types. Both values are stored on the payment row.
  Future<void> _saveCashPayment() async {
    final ok = await _ensureSequencesExist(needBank: false);
    if (!ok) return;
    _paymentMode = 'Cash';
    final total = _totalNetSelected;
    _tenderAmountController.text = total.toStringAsFixed(0);
    _cashTenderAmount = total;
    _cashRefundAmount = 0;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        void recompute() {
          final t = double.tryParse(_tenderAmountController.text) ?? 0;
          setSt(() {
            _cashTenderAmount = t;
            _cashRefundAmount = (t - total).clamp(0, double.infinity).toDouble();
          });
        }
        return Dialog(
          backgroundColor: Colors.white,
          insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420.w),
            child: Padding(
              padding: EdgeInsets.all(22.w),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cash Payment', style: AppUI.cardTitle),
                  SizedBox(height: 12.h),
                  _cashRow('Net Amount', '${formatIndianNumber(total)}', highlight: true),
                  SizedBox(height: 14.h),
                  AppUI.fieldLabel('Cash Received', required: true),
                  TextField(
                    controller: _tenderAmountController,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
                    onChanged: (_) => recompute(),
                    decoration: AppUI.field(context, 'Enter cash received', filled: _tenderAmountController.text.trim().isNotEmpty),
                    style: AppUI.fieldText(context, filled: _tenderAmountController.text.trim().isNotEmpty),
                  ),
                  if ((_cashTenderAmount ?? 0) < total && (_cashTenderAmount ?? 0) > 0) ...[
                    SizedBox(height: 6.h),
                    Text(
                      'Cash received must be at least ₹${formatIndianNumber(total)}.',
                      style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600),
                    ),
                  ],
                  SizedBox(height: 14.h),
                  _cashRow('Change to Return', '${formatIndianNumber(_cashRefundAmount ?? 0)}'),
                  SizedBox(height: 20.h),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AppUI.requiredNote(),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      SizedBox(width: 8.w),
                      Builder(builder: (_) {
                        final t = double.tryParse(_tenderAmountController.text) ?? 0;
                        final canConfirm = t >= total && total > 0;
                        return ElevatedButton(
                          onPressed: !canConfirm
                              ? null
                              : () {
                                  _cashTenderAmount = t;
                                  _cashRefundAmount = (t - total).clamp(0, double.infinity).toDouble();
                                  Navigator.pop(ctx, true);
                                },
                          child: const Text('Confirm'),
                        );
                      }),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
    if (confirmed != true) return;
    await _processPayment();
  }

  Widget _cashRow(String label, String value, {bool highlight = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppUI.muted),
        Text(value,
            style: AppUI.money.copyWith(
              fontSize: highlight ? 16.sp : 14.sp,
              fontWeight: highlight ? FontWeight.w800 : FontWeight.w700,
              color: highlight ? AppColors.primary : AppColors.textPrimary,
            )),
      ],
    );
  }

  /// Shared pre-check: every fee group in the selected demands must have
  ///   (a) a payment sequence configured AND
  ///   (b) a bank account mapped (feegroup.ban_id) -- [needBank]: only for a
  ///       mode other than Cash (user, 2026-11-14: "other than cash required
  ///       bank"); cash is taken at the counter.
  /// Returns false (with a snackbar) on the first missing requirement so the
  /// caller can abort the collection.
  Future<bool> _ensureSequencesExist({bool needBank = true}) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return true;
    try {
      final sequences = await SupabaseService.fromSchema('sequence')
          .select('fg_id, actname, division')
          .eq('ins_id', insId)
          .eq('activestatus', 1) // a deleted series does not count
          .neq('actname', 'REGNO'); // exclude register-number sequences
      final seqFgIds = (sequences as List).map((s) => s['fg_id']).toSet();
      final arrearFgs = _arrearSeriesGroups(sequences);
      final feeGroups = await SupabaseService.fromSchema('feegroup')
          .select('fg_id, fgdesc, ban_id')
          .eq('ins_id', insId);
      final fgInfo = <int, Map<String, dynamic>>{
        for (final g in (feeGroups as List))
          (g['fg_id'] as int): Map<String, dynamic>.from(g as Map),
      };
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final demfeetype = d['demfeetype']?.toString() ?? '';
        final ftResult = await SupabaseService.fromSchema('feetype')
            .select('fg_id')
            .eq('feedesc', demfeetype)
            .eq('activestatus', 1)
            .limit(1)
            .maybeSingle();
        final fgId = ftResult?['fg_id'];
        if (fgId == null) continue;
        final fgRow = fgInfo[fgId];
        final fgName = fgRow?['fgdesc']?.toString() ?? 'this fee group';
        // An arrear fee is numbered from the group's arrear receipt series.
        final arrear = isSchool && _isArrear(d);
        if (!(arrear ? arrearFgs.contains(fgId) : seqFgIds.contains(fgId))) {
          if (mounted) await showMissingSequenceDialog(context, group: fgName, arrear: arrear);
          return false;
        }
        if (needBank && fgRow?['ban_id'] == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('No bank account mapped to "$fgName", so only Cash can be collected. Assign one in Setup → Fee Master → Fee Group for UPI, Online, Cheque or DD.'),
                backgroundColor: AppColors.error,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return false;
        }
      }
    } catch (_) {}
    return true;
  }

  Future<void> _onCollectAndReceipt() async {
    // Same pre-flight as Cash: every selected fee group must have BOTH a
    // payment sequence AND a bank account mapped in feegroup.ban_id.
    final ok = await _ensureSequencesExist();
    if (!ok) return;

    final totalNet = _totalNetSelected;
    // _paymentMode is already set by the inline chips in the bottom bar — don't
    // reset it to Cash here; preserve the user's choice (QR/UPI / Online / Cheque).
    _chequeNoController.clear();
    _chequeDateController.clear();
    _bankNameController.clear();
    _upiRefController.clear();
    _chequeDate = null;

    String? upiErr;
    String? chequeNoErr;
    String? chequeDateErr;
    String? bankNameErr;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          elevation: 0,
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 470.w),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 22.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppUI.cardRadius),
                border: Border.all(
                  color: AppColors.cardBorder,
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.textPrimary.withValues(alpha: 0.08),
                    blurRadius: 60,
                    spreadRadius: 4,
                    offset: const Offset(0, 24),
                  ),
                  BoxShadow(
                    color: AppColors.textPrimary.withValues(alpha: 0.04),
                    blurRadius: 16,
                    spreadRadius: 0,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: FocusTraversalGroup(child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: FocusableTap(
                        onTap: () => Navigator.of(context).pop(),
                        child: AppIcon.linear('close-circle', size: 18, color: AppColors.textSecondary),
                      ),
                    ),
                    SizedBox(height: 14.h),
                    Text(
                      '${_paymentMode == 'QR/UPI' ? 'UPI' : (_paymentMode ?? '')} Payment Details',
                      style: AppUI.cardTitle,
                    ),
                    SizedBox(height: 8.h),
                    Text(
                      'Student: ${_student!['stuname']} (${_student!['stuadmno']})',
                      style: AppUI.body.copyWith(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: 6.h),
                    Text(
                      'Demands selected: ${_selected.length}',
                      style: AppUI.body.copyWith(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: 12.h),
                    Text(
                      'Total: ${formatIndianNumber(totalNet)}',
                      style: AppUI.money.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 16.sp,
                        color: AppColors.primary,
                      ),
                    ),
                    SizedBox(height: 18.h),
                    const Divider(color: AppColors.divider, height: 1),
                    SizedBox(height: 18.h),
                    // Payment mode is selected via the inline chips in the
                    // bottom bar before opening this dialog — so we don't
                    // re-show the mode picker here; only the inputs for the
                    // already-chosen mode appear below.
                    if (_paymentMode == 'QR/UPI') ...[
                      Container(
                        padding: EdgeInsets.all(12.w),
                        decoration: BoxDecoration(
                          color: AppColors.infoBg,
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                          border: Border.all(
                            color: AppColors.info.withValues(alpha: 0.16),
                          ),
                        ),
                        child: Row(
                          children: [
                            AppIcon.linear('info-circle',
                              size: 16,
                              color: AppColors.info,
                            ),
                            SizedBox(width: 8.w),
                            Expanded(
                              child: Text(
                                'Enter the UPI Transaction ID shared by the student',
                                style: TextStyle(fontSize: 11.sp, color: AppColors.info),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 14.h),
                      _buildDialogInput(
                        label: 'UPI Transaction ID *',
                        child: TextField(
                          controller: _upiRefController,
                          onChanged: (_) {
                            setDialogState(() { if (upiErr != null) upiErr = null; });
                          },
                          decoration: _dialogInputDec(hint: 'e.g. 412345678901', prefix: AppIcon('receipt-2', size: 18, color: AppColors.accent), filled: _upiRefController.text.trim().isNotEmpty).copyWith(errorText: upiErr, errorMaxLines: 2),
                          style: _dialogInputStyle(filled: _upiRefController.text.trim().isNotEmpty),
                        ),
                      ),
                    ],
                    if (_paymentMode == 'Cheque' || _paymentMode == 'DD') ...[
                      SizedBox(height: 18.h),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildDialogInput(
                              label: '${_paymentMode == 'DD' ? 'DD' : 'Cheque'} No *',
                              child: TextField(
                                controller: _chequeNoController,
                                onChanged: (_) {
                                  setDialogState(() { if (chequeNoErr != null) chequeNoErr = null; });
                                },
                                decoration: _dialogInputDec(hint: 'Enter ${_paymentMode == 'DD' ? 'DD' : 'cheque'} number', filled: _chequeNoController.text.trim().isNotEmpty).copyWith(errorText: chequeNoErr, errorMaxLines: 2),
                                style: _dialogInputStyle(filled: _chequeNoController.text.trim().isNotEmpty),
                              ),
                            ),
                          ),
                          SizedBox(width: 12.w),
                          Expanded(
                            child: _buildDialogInput(
                              label: '${_paymentMode == 'DD' ? 'DD' : 'Cheque'} Date *',
                              child: TextField(
                                controller: _chequeDateController,
                                readOnly: true,
                                onTap: () async {
                                  final picked = await showDatePicker(
                                    context: ctx,
                                    initialDate: DateTime.now(),
                                    firstDate: DateTime(2020),
                                    lastDate: DateTime(2030),
                                  );
                                  if (picked != null) {
                                    _chequeDate = picked;
                                    _chequeDateController.text =
                                        formatDmy(picked);
                                    setDialogState(() => chequeDateErr = null);
                                  }
                                },
                                decoration: _dialogInputDec(hint: 'Select ${_paymentMode == 'DD' ? 'DD' : 'cheque'} date (${AppText.dateHint})', filled: _chequeDateController.text.trim().isNotEmpty).copyWith(
                                  suffixIcon: Padding(
                                    padding: EdgeInsets.only(right: 8.w),
                                    child: AppIcon.linear('calendar', size: 16, color: AppColors.accent),
                                  ),
                                  suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                                  errorText: chequeDateErr,
                                  errorMaxLines: 2,
                                ),
                                style: _dialogInputStyle(filled: _chequeDateController.text.trim().isNotEmpty),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 14.h),
                      _buildDialogInput(
                        label: 'Bank Name *',
                        child: TextField(
                          controller: _bankNameController,
                          onChanged: (_) {
                            setDialogState(() { if (bankNameErr != null) bankNameErr = null; });
                          },
                          decoration: _dialogInputDec(hint: 'Enter bank name', filled: _bankNameController.text.trim().isNotEmpty).copyWith(errorText: bankNameErr, errorMaxLines: 2),
                          style: _dialogInputStyle(filled: _bankNameController.text.trim().isNotEmpty),
                        ),
                      ),
                    ],
                    SizedBox(height: 22.h),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (!_isGatewayMode) AppUI.requiredNote(),
                        const Spacer(),
                        OutlinedButton(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            // Reset fineamount to 0 on all selected demands
                            // so no stale fine stays in the DB.
                            final auth = context.read<AuthProvider>();
                            final insId = auth.insId;
                            if (insId == null) return;
                            for (final key in _selected) {
                              final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
                              final demId = d['dem_id'];
                              if (demId == null) continue;
                              try {
                                await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: 0);
                              } catch (e) {
                                debugPrint('Fine reset error for dem_id=$demId: $e');
                              }
                            }
                          },
                          child: const Text('Cancel'),
                        ),
                        SizedBox(width: 10.w),
                        ElevatedButton(
                          onPressed: () {
                            if (_paymentMode == 'QR/UPI') {
                              if (_upiRefController.text.trim().isEmpty) {
                                setDialogState(() => upiErr = 'Enter the UPI Transaction ID');
                                return;
                              }
                            }
                            if (_paymentMode == 'Cheque' || _paymentMode == 'DD') {
                              final doc = _paymentMode == 'DD' ? 'DD' : 'Cheque';
                              final no = _chequeNoController.text.trim().isEmpty;
                              final dt = _chequeDateController.text.trim().isEmpty;
                              final bk = _bankNameController.text.trim().isEmpty;
                              if (no || dt || bk) {
                                setDialogState(() {
                                  chequeNoErr = no ? '$doc number is required' : null;
                                  chequeDateErr = dt ? '$doc date is required' : null;
                                  bankNameErr = bk ? 'Bank name is required' : null;
                                });
                                return;
                              }
                            }
                            Navigator.pop(ctx);
                            _processPayment();
                          },
                          child: Text(
                            _isGatewayMode ? 'Confirm Payment' : 'Save',
                          ),
                        ),
                      ],
                    ),
                  ],
                )),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDialogInput({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label.endsWith(' *')
            ? AppUI.fieldLabel(label.substring(0, label.length - 2), required: true)
            : AppUI.fieldLabel(label),
        child,
      ],
    );
  }

  Future<void> _processPayment() async {
    if (_processing || _student == null) return;
    if (_paymentMode == 'Paytm') {
      await _processPaytmPayment();
    } else if (_paymentMode == 'Online') {
      await _processGatewayPayment();
    } else {
      await _processDirectPayment();
    }
  }

  // ── Show success dialog ──
  void _showSuccessDialog(String payNumber, double totalNet, {int? payId}) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('tick-circle', color: AppColors.success, size: 56.sp),
            SizedBox(height: 12.h),
            Text('Payment Successful', style: AppUI.cardTitle),
            SizedBox(height: 8.h),
            Text('Receipt No.: $payNumber', style: AppUI.muted),
            Text('Amount: ${formatIndianNumber(totalNet)}', style: AppUI.money.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.primary)),
            Text('${AppText.paymentMode}: $_paymentMode', style: AppUI.muted),
            SizedBox(height: 16.h),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _clear();
                if (payId != null) _downloadReceipt(payId, payNumber);
              },
              icon: AppIcon('document-download', size: AppBtn.iconSize(context)),
              label: const Text('Download Receipt'),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _clear();
            },
            child: const Text(AppText.close),
          ),
        ],
      ),
    );
  }

  /// Explain why an online payment cannot be taken. A dialog rather than a
  /// snackbar on purpose: this stops a collection at the counter with a student
  /// waiting, so it has to be read and acknowledged, not glanced at as it fades.
  void _showPaytmRoutingError(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.account_balance_outlined, color: AppColors.warning),
          SizedBox(width: 8.w),
          Expanded(
            child: Text('Cannot Route This Payment', style: AppUI.cardTitle),
          ),
        ]),
        content: SizedBox(
          width: 420.w,
          child: Text(message, style: AppUI.body.copyWith(height: 1.45)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _downloadReceipt(int payId, String payNumber) async {
    if (!mounted) return;
    // Show a non-dismissable spinner while we fetch + render the receipt data.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    ReceiptData? receiptData;
    try {
      receiptData = await _fetchReceiptData(payId, payNumber);
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // close spinner
    if (receiptData == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load receipt details.'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (!mounted) return;
    _showReceiptPreviewDialog(receiptData);
  }

  /// Receipt preview dialog matching the Daily Collection look — header with
  /// Download / Print / close, then the rendered ReceiptWidget below.
  void _showReceiptPreviewDialog(ReceiptData receiptData) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 620,
          height: 920,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          final pdf = await buildReceiptPdf(receiptData);
                          final bytes = await pdf.save();
                          final defaultName = 'Receipt_${receiptData.receiptNo.replaceAll('/', '_')}.pdf';
                          final result = await pickSavePath(
                            dialogTitle: 'Save Receipt PDF',
                            fileName: defaultName,
                            type: FileType.custom,
                            allowedExtensions: ['pdf'],
                          );
                          if (result != null) {
                            final file = File(result);
                            await file.writeAsBytes(bytes);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Receipt PDF saved'), backgroundColor: AppColors.success),
                              );
                            }
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
                            );
                          }
                        }
                      },
                      icon: AppIcon('document-download', size: 18),
                      label: const Text('Download'),
                    ),
                    SizedBox(width: 8.w),
                    ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          await Printing.layoutPdf(
                            // Rebuild at the paper the printer actually reports
                            // so the receipt lands centred and unclipped; A5 is
                            // only the starting suggestion.
                            format: await receiptPaper(),
                            onLayout: (PdfPageFormat format) async =>
                                (await buildReceiptPdf(receiptData, pageFormat: format)).save(),
                            name: 'Receipt_${receiptData.receiptNo.replaceAll('/', '_')}',
                          );
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
                            );
                          }
                        }
                      },
                      icon: AppIcon('printer', size: 18),
                      label: const Text('Print'),
                    ),
                    SizedBox(width: 8.w),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: AppIcon.linear('close-circle', size: 20),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(12.w),
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 2)),
                        ],
                      ),
                      child: ReceiptPreview(data: receiptData),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Assembles a ReceiptData object by joining payment + paymentdetails +
  /// feedemand + student + parent + institution rows. Returns null if the
  /// payment row can't be found.
  Future<ReceiptData?> _fetchReceiptData(int payId, String payNumber) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return null;

    final payment = await SupabaseService.fromSchema('payment')
        .select('pay_id, paynumber, paydate, paymethod, paystatus, payreference, transtotalamount, stu_id, recon_status, createdat')
        .eq('pay_id', payId)
        .maybeSingle();
    if (payment == null) return null;

    final stuId = payment['stu_id'] as int?;
    Map<String, dynamic>? student;
    String? payInchargeMob;
    if (stuId != null) {
      student = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, stuaddress, stumobile')
          .eq('stu_id', stuId)
          .maybeSingle();
      try {
        final parent = await SupabaseService.getStudentParent(stuId, stuadmno: student?['stuadmno']?.toString());
        payInchargeMob = parent?['payinchargemob']?.toString();
      } catch (_) {}
    }

    // paymentdetails → fee breakdown for this payment
    final details = await SupabaseService.fromSchema('paymentdetails')
        .select('dem_id, transtotalamount')
        .eq('pay_id', payId)
        .eq('activestatus', 1);
    final detailList = List<Map<String, dynamic>>.from(details);
    final demIds = detailList.map((d) => d['dem_id'] as int?).whereType<int>().toSet().toList();

    // Pull the matching feedemand rows so we know term/feetype/duedate/fine
    // for each line in the receipt.
    final Map<int, Map<String, dynamic>> demById = {};
    if (demIds.isNotEmpty) {
      final demands = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, demfeetype, demfeeterm, duedate, fineamount, feeamount, demseqtype, arrearclass')
          .inFilter('dem_id', demIds);
      for (final d in demands) {
        demById[d['dem_id'] as int] = Map<String, dynamic>.from(d);
      }
    }

    String dateStr = '-';
    final dateRaw = payment['paydate'] ?? payment['createdat'];
    if (dateRaw != null) {
      try {
        final dt = DateTime.parse(dateRaw.toString());
        dateStr = formatDmy(dt);
      } catch (_) {
        dateStr = dateRaw.toString();
      }
    }

    // Group fee details by term, splitting fine into its own line item.
    final termMap = <String, List<ReceiptFeeItem>>{};
    // The fee types ON THIS RECEIPT, for the letterhead. Not _payFgId: the
    // counter has usually moved on to the next group by the time a receipt is
    // printed or reopened, and it printed the college head on a hostel one.
    final feeTypesOnReceipt = <String>{};
    for (final d in detailList) {
      final demId = d['dem_id'] as int?;
      final dem = demId != null ? demById[demId] : null;
      final feeType = dem?['demfeetype']?.toString() ?? 'Fee';
      final term = dem?['demfeeterm']?.toString().trim().isNotEmpty == true
          ? dem!['demfeeterm'].toString()
          : '-';
      final fine = (dem?['fineamount'] as num?)?.toDouble() ?? 0;
      final collected = (d['transtotalamount'] as num?)?.toDouble() ?? 0;
      final feeOnly = (collected - fine).clamp(0, double.infinity).toDouble();
      feeTypesOnReceipt.add(feeType);
      termMap.putIfAbsent(term, () => []);
      termMap[term]!.add(ReceiptFeeItem(type: feeType, amount: feeOnly));
      if (fine > 0) {
        termMap[term]!.add(ReceiptFeeItem(type: '  Fine', amount: fine));
      }
    }
    final totalAmount = (payment['transtotalamount'] as num?)?.toDouble() ?? 0;
    final termDetails = termMap.isEmpty
        ? [ReceiptTermDetail(term: '-', fees: [ReceiptFeeItem(type: 'Payment', amount: totalAmount)])]
        : termMap.entries.map((e) => ReceiptTermDetail(term: e.key, fees: e.value)).toList();

    // For an ARREAR receipt, the Branch shows the arrear's ORIGINAL class
    // (feedemand.arrearclass), not the student's current class. Receipts are
    // single-type (regular/arrear collected separately), so any arrear demand
    // in this payment carries the class to display.
    String? arrearBranch;
    for (final dem in demById.values) {
      final isArr = (dem['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
      final ac = dem['arrearclass']?.toString() ?? '';
      if (isArr && ac.isNotEmpty) {
        arrearBranch = ac;
        break;
      }
    }
    final branchClass = (arrearBranch != null && arrearBranch.isNotEmpty)
        ? arrearBranch
        : (student?['stuclass']?.toString() ?? '-');

    final ins = await SupabaseService.getInstitutionInfo(insId);

    // What this receipt settled out of an advance. Read from the database, not
    // from screen state, so reprinting it later shows the same thing.
    double advAdjusted = 0;
    var advNo = '';
    try {
      final adj = await SupabaseService.fromSchema('advadjustment')
          .select('adjustamount, adv_id')
          .eq('ins_id', insId)
          .eq('pay_id', payId)
          .eq('activestatus', 1);
      final advIds = <int>{};
      for (final r in List<Map<String, dynamic>>.from(adj as List)) {
        advAdjusted += (r['adjustamount'] as num?)?.toDouble() ?? 0;
        final id = (r['adv_id'] as num?)?.toInt();
        if (id != null) advIds.add(id);
      }
      if (advIds.isNotEmpty) {
        final hdr = await SupabaseService.fromSchema('advance_collection')
            .select('advno')
            .inFilter('adv_id', advIds.toList());
        advNo = List<Map<String, dynamic>>.from(hdr as List)
            .map((e) => e['advno']?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .join(', ');
      }
    } catch (_) {
      // No advadjustment table yet — an ordinary receipt prints unchanged.
    }

    final receiptFg =
        await SupabaseService.feeGroupOfFeeTypes(feeTypesOnReceipt.toList());

    return ReceiptData(
      receiptNo: payment['paynumber']?.toString() ?? payNumber,
      date: dateStr,
      studentName: student?['stuname']?.toString() ?? '-',
      mobileNo: (payInchargeMob?.isNotEmpty == true) ? payInchargeMob! : (student?['stumobile']?.toString() ?? '-'),
      address: student?['stuaddress']?.toString() ?? '-',
      admissionNo: student?['stuadmno']?.toString() ?? '-',
      className: branchClass,
      courseName: student?['courname']?.toString().isNotEmpty == true ? student!['courname'].toString() : '-',
      // The group being collected decides the letterhead: a hostel receipt is
      // issued by the hostel (Setup -> Utilities -> Receipt Letterhead).
      schoolName: SupabaseService.letterheadFor(
        fgId: receiptFg,
        settings: _settings,
        fallbackName: (ins.name?.isNotEmpty == true) ? ins.name! : (auth.insName ?? 'Institution'),
        fallbackAddress: (ins.address?.isNotEmpty == true) ? ins.address! : '-',
      ).name,
      schoolAddress: SupabaseService.letterheadFor(
        fgId: receiptFg,
        settings: _settings,
        fallbackName: (ins.name?.isNotEmpty == true) ? ins.name! : (auth.insName ?? 'Institution'),
        fallbackAddress: (ins.address?.isNotEmpty == true) ? ins.address! : '-',
      ).address,
      headerBanner: SupabaseService.letterheadFor(
        fgId: receiptFg,
        settings: _settings,
        fallbackName: '',
        fallbackAddress: '',
      ).banner,
      // Printed only when this receipt also settled part of an advance, so the
      // student sees the whole settlement on one page.
      advanceAdjusted: advAdjusted,
      advanceNo: advNo,
      schoolLogoUrl: ins.logo,
      schoolMobile: ins.mobile,
      schoolEmail: ins.email,
      feeDetails: termDetails,
      paymentMethod: payment['paymethod']?.toString() ?? '-',
      paymentDate: dateStr,
      status: payment['paystatus']?.toString() == 'C' ? 'paid' : 'pending',
      reconStatus: payment['recon_status']?.toString() ?? 'P',
      paymentReference: payment['payreference']?.toString(),
      total: totalAmount,
    );
  }

  // ── Direct payment (Cash / Bank / Cheque) using atomic RPCs ──
  /// Fallback academic-year id for payments on demands with a NULL yr_id
  /// (arrear demands whose Fee/Arrear Year isn't in the year master).
  /// payment.yr_id and paymentdetails.yr_id are NOT NULL, so such a receipt is
  /// recorded under the current active year. Cached after the first lookup.
  int? _fallbackYrId;
  Future<int?> _currentYearId() async {
    if (_fallbackYrId != null) return _fallbackYrId;
    try {
      final r = await SupabaseService.fromSchema('year')
          .select('yr_id')
          .eq('activestatus', 1)
          .order('yr_id', ascending: false)
          .limit(1)
          .maybeSingle();
      _fallbackYrId = (r?['yr_id'] as num?)?.toInt();
    } catch (_) {}
    return _fallbackYrId;
  }

  Future<void> _processDirectPayment() async {
    setState(() => _processing = true);

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.currentUser?.inscode ?? '';
    final createdBy = auth.currentUser?.usename ?? '';
    final stuId = _student!['stu_id'] as int;
    final totalNet = _totalNetSelected;

    // Declared outside try so the catch block can reset fineamount on failure.
    final items = <Map<String, dynamic>>[];
    // Receipts already SAVED by the server, and the fees they paid. Outside the
    // try: when a later step fails, the cashier must be told what WAS saved --
    // "Payment failed" on a saved receipt is how a fee gets collected twice.
    final receipts = <dynamic>[];
    final savedDemIds = <int>{};

    try {
      // Only rows that will actually be CHARGED are checked for staleness. A
      // ticked row with nothing to collect — because an advance already
      // covered it — is legitimately at balance 0, and treating that as stale
      // aborted the whole payment with "already paid, refresh".
      final selectedDemIds = _allDemands
          .where((d) => _selected.contains(_demKey(d)) && _netAmt(d) > 0)
          .map((d) => d['dem_id'] as int)
          .toList();
      // A fee held by an online payment that is not settled must not be
      // collected again in cash: the online money may still arrive.
      if (selectedDemIds.isNotEmpty) {
        List<Map<String, dynamic>> held = const [];
        try {
          held = await OnlinePaymentService.feesHeld(stuId, selectedDemIds);
        } catch (e) {
          debugPrint('online hold check skipped: $e'); // database without it yet
        }
        if (held.isNotEmpty) {
          if (mounted) {
            setState(() => _processing = false);
            final h = held.first;
            final paid = h['status'] == 'X';
            final fee = _allDemands.firstWhere((d) => d['dem_id'] == h['dem_id'], orElse: () => const {})['demfeetype'] ?? 'A fee';
            final msg = paid
                ? '$fee was already paid online (${h['order_id']}), but its receipt is pending with the office '
                    '(Setup > Payment Gateways). Do not collect it again.'
                : '$fee has an online payment still being confirmed (${h['order_id']}). '
                    'It may still go through, so it cannot be collected another way yet.';
            if (paid) {
              _showPaytmRoutingError(msg);
            } else {
              await _offerCheckPending(msg, '${h['order_id']}');
            }
          }
          return;
        }
      }
      if (selectedDemIds.isNotEmpty) {
        final fresh = await SupabaseService.fromSchema('feedemand')
            .select('dem_id, balancedue, paidstatus')
            .eq('ins_id', insId!)
            .inFilter('dem_id', selectedDemIds);
        final stale = (fresh as List).where((r) {
          final bal = (r['balancedue'] as num?)?.toDouble() ?? 0;
          return bal <= 0 || r['paidstatus'] == 'P';
        }).toList();
        if (stale.isNotEmpty) {
          if (mounted) {
            setState(() => _processing = false);
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Fees Already Paid'),
                content: const Text(
                  'One or more selected fees have already been collected '
                  '(possibly by another user). Please refresh and try again.',
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _search();
                    },
                    child: const Text('Refresh'),
                  ),
                ],
              ),
            );
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Pre-flight balance check failed: $e');
    }

    try {
      final firstDemand = _allDemands.firstWhere((d) => _selected.contains(_demKey(d)));
      // Arrear demands may have a NULL yr_id (year not in master); payment.yr_id
      // is NOT NULL, so fall back to the current active year.
      int? yrId = firstDemand['yr_id'] as int?;
      yrId ??= await _currentYearId();

      // Build items list with fee type info
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final fine = _fine(key);
        final col = _con(key);
        // Same rule as _netAmt / the NET AMOUNT column, so the payment header
        // (folded from these amounts) always equals what the cashier was shown.
        final net = col + fine;
        if (net <= 0) continue;
        items.add({
          'dem_id': d['dem_id'] as int,
          'yr_id': (d['yr_id'] as int?) ?? yrId,
          'yrlabel': d['demfeeyear']?.toString() ?? '',
          'ins_id': insId,
          'amount': net,
          'fine': fine,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      // Write the cashier's fine onto each demand BEFORE taking the money.
      //
      // A receipt legitimately carries balance + fine, and the payment RPC
      // enforces exactly that ceiling by reading feedemand.fineamount. This used
      // to run AFTER the payment, so the server still saw fineamount = 0 and
      // rejected any collection that included a fine:
      //   "Collection of 25100.0 on demand 7900 exceeds the amount due
      //    (balance 25000.00 + fine 0.00)"
      // Persisting first makes the fine part of the demand's state before the
      // money moves, so the ceiling is computed from server state rather than
      // from anything the client claims. The failure path below resets these
      // back to 0 if the payment does not go through.
      for (final item in items) {
        final fine = (item['fine'] as num?)?.toDouble() ?? 0;
        final demId = item['dem_id'];
        if (fine > 0 && demId != null) {
          try {
            await SupabaseService.setDemandFine(
                token: _sessionToken, demId: demId, fineamount: fine);
          } catch (e) {
            debugPrint('Fine column update error for dem_id=$demId: $e');
          }
        }
      }

      // Build payment reference. _paymentMode is non-null here because the
      // bottom-bar button is disabled until the cashier picks a mode. We
      // store JUST the txn / cheque id (no narrative prefix) so the
      // PowerCollege SETTLEMENT ID column shows the clean value.
      final mode = _paymentMode ?? 'Cash';
      String payReference = '';
      String payMethod = mode.toLowerCase();

      if (_paymentMode == 'QR/UPI') {
        payReference = _upiRefController.text.trim();
        payMethod = 'upi';
      } else if (_paymentMode == 'Cheque' || _paymentMode == 'DD') {
        payReference = _chequeNoController.text.trim();
        payMethod = _paymentMode == 'DD' ? 'dd' : 'cheque';
      }

      // Split the receipt by fee YEAR: regular fees are all the current year
      // (one group → one call, unchanged), but arrear fees can span several
      // years (2022-2023, 2023-2024, …) and must each generate a SEPARATE
      // receipt. The RPC stamps payment.yr_id/yrlabel from the call's top-level
      // args (not per item), so we call it once per year group.
      final byYear = <String, List<Map<String, dynamic>>>{};
      for (final it in items) {
        final label = (it['yrlabel']?.toString().trim().isNotEmpty ?? false)
            ? it['yrlabel'].toString().trim()
            : (it['yr_id']?.toString() ?? '');
        byYear.putIfAbsent(label, () => []).add(it);
      }

      // Older years (arrears) first: with "arrear first" on, the current
      // year's fees are accepted only once the arrears are paid.
      final yearOrder = byYear.keys.toList()..sort();
      for (final entry in [for (final k in yearOrder) MapEntry(k, byYear[k]!)]) {
        final groupItems = entry.value;
        final groupYrId = (groupItems.first['yr_id'] as int?) ?? yrId;
        final groupTotal = groupItems.fold<double>(
            0, (s, it) => s + ((it['amount'] as num?)?.toDouble() ?? 0));
        // creates one payment per fee group within this year; amount includes fine.
        final result = await SupabaseService.processGroupedPayment(
          token: _sessionToken, insId: insId, inscode: inscode, stuId: stuId,
          yrId: groupYrId, yrlabel: entry.key, totalAmount: groupTotal,
          createdBy: createdBy, payMethod: payMethod, payReference: payReference,
          items: groupItems);
        if (result is List) {
          receipts.addAll(result);
        } else if (result != null) {
          receipts.add(result);
        }
        for (final it in groupItems) {
          final id = it['dem_id'];
          if (id is int) savedDemIds.add(id);
        }
      }

      final receiptStr = receipts.map((r) => r is Map ? r['paynumber'] ?? r.toString() : r.toString()).join(', ');
      // Grab the first pay_id so the Download Receipt button has something to fetch.
      int? firstPayId;
      for (final r in receipts) {
        if (r is Map && r['pay_id'] != null) {
          firstPayId = r['pay_id'] is int ? r['pay_id'] as int : int.tryParse(r['pay_id'].toString());
          break;
        }
      }

      // The receipts are saved. The steps below only add details to them, so a
      // failure there is a warning, never "Payment failed".
      String? followUpProblem;
      try {
      // Update cheque/DD details if applicable (DD reuses the same columns)
      if ((_paymentMode == 'Cheque' || _paymentMode == 'DD') && receipts.isNotEmpty) {
        for (final r in receipts) {
          final payId = r is Map ? r['pay_id'] : null;
          if (payId != null) {
            await SupabaseService.updatePayment(payId, {
              'paychequeno': _chequeNoController.text.trim(),
              'paychequedate': _chequeDate != null
                  ? '${_chequeDate!.year}-${_chequeDate!.month.toString().padLeft(2, '0')}-${_chequeDate!.day.toString().padLeft(2, '0')}'
                  : null,
              'paybankname': _bankNameController.text.trim(),
            });
          }
        }
      }

      // Record what was handed over and the change given back, so the cashbook
      // ties. The change goes in change_amount -- refund_amount is money
      // REFUNDED (Fee Refund) and a receipt with one cannot be cancelled.
      // One payment can make several receipts (one per year): the first
      // carries the change, and each receipt's tender is its own amount (+ the
      // change on the first), so the day's totals add up to what was handed
      // over instead of counting it once per receipt.
      if (_paymentMode == 'Cash' && receipts.isNotEmpty && _cashTenderAmount != null) {
        final change = _cashRefundAmount ?? 0;
        var first = true;
        for (final r in receipts) {
          final payId = r is Map ? r['pay_id'] : null;
          if (payId == null) continue;
          final own = (r is Map ? (r['amount'] as num?)?.toDouble() : null);
          await SupabaseService.updatePayment(payId, {
            'tender_amount': receipts.length == 1
                ? _cashTenderAmount
                : (own ?? 0) + (first ? change : 0),
            'change_amount': first ? change : 0,
          });
          first = false;
        }
      }

      } catch (e) {
        debugPrint('payment follow-up failed: $e');
        followUpProblem = friendlyError(e);
      }

      // fineamount is already recorded (written before the payment above, so the
      // RPC's balance + fine ceiling could see it). The RPC folds bal + fine into
      // paidamount and never touches fineamount, so nothing is left to do here
      // EXCEPT protect it from the reset-on-exit.
      for (final item in items) {
        final demId = item['dem_id'];
        if (demId is int) _paidFineDemIds.add(demId);
      }

      // The receipt exists now, so the advance can ride on it. Before the
      // dialog, so the receipt it offers already shows the adjustment.
      await _attachPendingAdjust(_payIdForPendingAdvance(receipts, firstPayId));

      _showSuccessDialog(receiptStr, totalNet, payId: firstPayId);
      if (followUpProblem != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Receipt $receiptStr is saved, but its '
              '${_paymentMode == 'Cash' ? 'cash tendered / change' : 'cheque / DD details'} could not be stored '
              '($followUpProblem). Add them from Receipts if needed. Do not collect again.'),
          backgroundColor: AppColors.warning,
          duration: const Duration(seconds: 10),
        ));
      }
    } catch (e) {
      debugPrint('PAYMENT SAVE FAILED (raw): $e');
      // Part of it was saved (fees of one year went through, another year's
      // did not): say exactly that, keep the paid fines, and reload.
      if (receipts.isNotEmpty) {
        final saved = receipts.map((r) => r is Map ? r['paynumber'] ?? '' : '').where((x) => '$x'.isNotEmpty).join(', ');
        for (final item in items) {
          final demId = item['dem_id'];
          if (demId is! int) continue;
          if (savedDemIds.contains(demId)) {
            _paidFineDemIds.add(demId);
          } else {
            try {
              await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: 0);
            } catch (_) {}
          }
        }
        if (mounted) {
          _showPaytmRoutingError(
              'Receipt $saved IS SAVED -- do not collect those fees again. '
              'The remaining fees could not be saved (${friendlyError(e)}). '
              'The list is refreshed: collect only what still shows as due.');
          await _search();
        }
        return;
      }
      String errorMsg = e.toString();
      if (errorMsg.contains('already fully paid')) {
        errorMsg = 'One or more fees have already been paid. Please refresh and try again.';
      } else if (errorMsg.contains('currently being processed')) {
        errorMsg = 'These fees are already being processed. Please wait and try again.';
      } else if (errorMsg.contains('not found or inactive')) {
        errorMsg = 'One or more fees are no longer available. Please refresh.';
      }

      // Payment failed — reset fineamount to 0 on attempted demands so no
      // stale fine is left in the DB.
      for (final item in items) {
        final demId = item['dem_id'];
        if (demId != null) {
          try {
            await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: 0);
          } catch (e2) {
            debugPrint('Fine reset error for dem_id=$demId: $e2');
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment failed. ${friendlyError(errorMsg)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  // ── Online payment (Setup > Payment Gateways) ──
  // Any gateway the school set up. The server (pay-create) checks the amounts
  // and picks the gateway; the window opens the gateway's page; the server
  // (pay-status) asks the gateway and raises the receipt. Nothing here writes
  // a payment row.
  Future<void> _processGatewayPayment() async {
    setState(() => _processing = true);
    final auth = context.read<AuthProvider>();
    final stuId = _student!['stu_id'] as int;
    final totalNet = _totalNetSelected;

    final items = <Map<String, dynamic>>[];
    final fgIds = <int>{};
    for (final key in _selected) {
      final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
      if (d.isEmpty) continue;
      final fine = _fine(key);
      // Same rule as _netAmt / the NET AMOUNT column.
      final net = _con(key) + fine;
      if (net <= 0) continue;
      items.add({'dem_id': d['dem_id'] as int, 'amount': net, 'fine': fine});
      final fg = _fgIdOf(d);
      if (fg != null) fgIds.add(fg);
    }
    if (items.isEmpty) {
      setState(() => _processing = false);
      return;
    }

    // Fees that settle into different accounts cannot share one order.
    final problem = await OnlinePaymentService.gatewayProblem(fgIds.toList());
    if (problem != null) {
      if (mounted) {
        setState(() => _processing = false);
        _showPaytmRoutingError(problem);
      }
      return;
    }

    OnlineOrder order;
    try {
      order = await OnlinePaymentService.start(stuId: stuId, items: items);
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        // A payment for this student / fee is still being confirmed: offer to
        // ask the gateway now instead of leaving the cashier stuck.
        if (e is OnlinePaymentException && e.code == 'P0002' && e.orderId != null) {
          await _offerCheckPending(e.message, e.orderId!);
        } else {
          _showPaytmRoutingError(e is OnlinePaymentException ? e.message : friendlyError(e));
        }
      }
      return;
    }
    if (!mounted) return;

    final gatewayName = pgProvider(order.provider)?.name ?? order.provider;
    final result = await showGatewayCheckout(
      context,
      order: order,
      gatewayName: gatewayName,
      payerName: _student!['stuname']?.toString() ?? '',
      payerMobile: (_parent?['payinchargemob'] ?? _student!['stumobile'] ?? '').toString(),
      merchantName: auth.insName ?? '',
    );
    if (!mounted) return;
    setState(() => _processing = false);

    switch (result?.status) {
      case 'C':
        // The server already stored any fine on the demand; keep the
        // reset-on-exit away from it.
        for (final it in items) {
          _paidFineDemIds.add(it['dem_id'] as int);
        }
        await _attachPendingAdjust(_payIdForPendingAdvance(result!.receipts, result.firstPayId));
        _showSuccessDialog(
            result.receiptNumbers.isEmpty ? order.orderId : result.receiptNumbers,
            totalNet, payId: result.firstPayId);
      case 'X':
        _showPaytmRoutingError(
            '$gatewayName took this payment, but the receipt could not be raised '
            '(${result!.note.isEmpty ? 'unknown reason' : result.note}). '
            'Do not collect it again. It is listed under Setup > Payment Gateways for the office. '
            'Reference: ${order.orderId}.');
        await _search();
      case 'F' when result!.moneyMayBeMoving:
        _showPaytmRoutingError(
            '$gatewayName is still processing this payment. Do not collect it again yet: if the payer\'s bank '
            'completes it, the receipt is raised automatically. Reference: ${order.orderId}.');
      case 'F':
        // "Not paid so far", not "nothing will ever be paid": a payer who
        // approves on the phone after the window closed is still receipted
        // automatically, and the office sees it if it cannot be.
        _showPaytmRoutingError(
            'Not paid so far: $gatewayName has not received this payment, and the dues are unchanged. '
            'If the payer says they approved it on their phone, wait a few minutes (it is receipted '
            'automatically) before taking it by another mode. Reference: ${order.orderId}.');
      case 'T':
        _showPaytmRoutingError(
            'Test payment went through. The gateway is in Test mode, so no receipt was raised and the '
            'fees are not credited. Switch it to Live in Setup > Payment Gateways to collect real fees.');
      case 'H':
        _showPaytmRoutingError('This payment was closed by the office. Reference: ${order.orderId}.');
      case null:
        break; // the window could not open; already told
      default:
        _showPaytmRoutingError(
            'The bank has not confirmed this payment yet. Do not collect it again. '
            'If the money went through, the receipt is raised automatically within a few '
            'minutes. Reference: ${order.orderId}.');
    }
  }

  /// A fee is held by an online payment that is not settled yet. Ask the
  /// gateway now (the server raises the receipt if it was paid).
  Future<void> _offerCheckPending(String message, String orderId) async {
    final check = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Online Payment Not Settled'),
        content: Text('$message\n\nAsk the gateway now whether it was paid?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Check Now')),
        ],
      ),
    );
    if (check != true || !mounted) return;
    try {
      final r = await OnlinePaymentService.status(orderId);
      if (!mounted) return;
      switch (r.status) {
        case 'C':
          _showPaytmRoutingError('It was paid: receipt ${r.receiptNumbers}. The dues are updated.');
          await _search();
        case 'F' when r.moneyMayBeMoving:
          _showPaytmRoutingError('The gateway is still processing this payment (it was closed early, but the payer\'s bank '
              'may still complete it). Wait a few minutes before collecting the fee another way. Reference: $orderId.');
        case 'F':
          _showPaytmRoutingError('The gateway says it was not paid. You can collect the fee now.');
        case 'T':
          _showPaytmRoutingError('That was a test payment (gateway in Test mode): nothing was collected.');
        case 'H':
          _showPaytmRoutingError('The office has closed this payment. You can collect the fee now.');
        case 'X':
          _showPaytmRoutingError('It was paid, but the receipt is pending with the office (Setup > Payment Gateways). '
              'Do not collect it again.');
        default:
          _showPaytmRoutingError('The gateway has not confirmed it yet. Try again in a few minutes, or ask the '
              'office to check it in Setup > Payment Gateways. Reference: $orderId.');
      }
    } catch (e) {
      if (mounted) _showPaytmRoutingError(e is OnlinePaymentException ? e.message : friendlyError(e));
    }
  }

  // ── Online payment (Paytm) ──
  // Mirrors _processOnlinePayment but uses Paytm JS Checkout and routes the
  // payment to the merchant (MID) tied to the fee group's bank account, so the
  // money settles to the correct IOBPAY entity. See docs/paytm_integration.md.
  Future<void> _processPaytmPayment() async {
    setState(() => _processing = true);

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.currentUser?.inscode ?? '';
    final createdBy = auth.currentUser?.usename ?? '';
    final stuId = _student!['stu_id'] as int;
    final totalNet = _totalNetSelected;

    // Block if an online payment for this student is still pending (<15 min),
    // so a double-tap or flaky network doesn't create a second live order.
    try {
      final pending = await SupabaseService.fromSchema('payment')
          .select('createdat')
          .eq('ins_id', insId!)
          .eq('stu_id', stuId)
          .eq('paystatus', 'I')
          .order('createdat', ascending: false)
          .limit(1)
          .maybeSingle();
      if (pending != null) {
        final createdAt = DateTime.tryParse(pending['createdat']?.toString() ?? '');
        if (createdAt != null && DateTime.now().difference(createdAt).inMinutes < 15) {
          if (mounted) {
            setState(() => _processing = false);
            final clear = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Online Payment Already Pending'),
                content: const Text(
                  'An online payment for this student was started but not '
                  'completed. If that attempt failed or the payment window was '
                  'closed, clear it and start a new payment.\n\n'
                  'Only clear if you are sure no payment actually went through.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Clear and Retry'),
                  ),
                ],
              ),
            );
            if (clear == true) {
              try {
                // Mark every not-completed (status 'I') attempt for this student
                // as failed, so the guard releases and a fresh order can start.
                await SupabaseService.failPendingPayments(stuId);
                if (mounted) _processPaytmPayment(); // retry, now unblocked
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Could not clear pending payment: ${friendlyError(e)}'),
                    backgroundColor: AppColors.error));
                }
              }
            }
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Paytm pending-payment check failed: $e');
    }

    int? createdPayId; // the temp 'I' row, so we can clean it up on failure
    try {
      final firstDemand = _allDemands.firstWhere((d) => _selected.contains(_demKey(d)));
      // Arrear demands may have a NULL yr_id; payment.yr_id is NOT NULL, so fall
      // back to the current active year.
      int? yrId = firstDemand['yr_id'] as int?;
      yrId ??= await _currentYearId();
      final yrlabel = firstDemand['demfeeyear']?.toString() ?? '';

      // Build items (same shape as the Razorpay flow).
      final items = <Map<String, dynamic>>[];
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final fine = _fine(key);
        final col = _con(key);
        // Same rule as _netAmt / the NET AMOUNT column (see _processDirectPayment).
        final net = col + fine;
        if (net <= 0) continue;
        items.add({
          'dem_id': d['dem_id'] as int,
          'yr_id': (d['yr_id'] as int?) ?? yrId,
          'yrlabel': d['demfeeyear']?.toString() ?? '',
          'ins_id': insId,
          'amount': net,
          'fine': fine,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      // Persist the fine before the payment, for the same reason as the cash
      // path: complete_payment_grouped caps a collection at balance + the fine
      // STORED on the demand, so a fine that is only written afterwards makes
      // the server reject the very payment that carries it. The failure path
      // below resets these to 0.
      for (final item in items) {
        final fine = (item['fine'] as num?)?.toDouble() ?? 0;
        final demId = item['dem_id'];
        if (fine > 0 && demId != null) {
          try {
            await SupabaseService.setDemandFine(
                token: _sessionToken, demId: demId, fineamount: fine);
          } catch (e) {
            debugPrint('Fine column update error for dem_id=$demId: $e');
          }
        }
      }

      // ONE FEE GROUP PER ONLINE PAYMENT.
      //
      // A Paytm order settles to exactly one merchant, and each fee group has
      // its own: college fees into the college merchant, hostel fees into the
      // hostel one. A single order covering both would land all of it in one
      // account, and nothing on the receipt would say so. Cash, cheque and DD
      // still take both groups at once -- they are banked by the receipt, not
      // by the gateway.
      final payingFgIds = <int>{};
      for (final d in _allDemands) {
        if (!_selected.contains(_demKey(d))) continue;
        final fg = _fgIdOf(d);
        if (fg != null) payingFgIds.add(fg);
      }
      // Resolved once, here, so the refusal below and the routing further down
      // cannot disagree with each other mid-payment if the setting is changed
      // while this collection is being taken.
      final splitByFeeGroup =
          await SupabaseService.feeGroupSettlementEnabled(insId!);

      // Which merchant does EACH paying group settle to? Resolved per group,
      // because what makes a mixed-group payment wrong is not the number of
      // groups -- it is two groups wanting DIFFERENT accounts. Two groups that
      // share one account (neither mapped, or both mapped to the same bank) are
      // one payment and must not be refused.
      final routingByFg = <int, PaytmRouting>{};
      for (final fg in payingFgIds) {
        routingByFg[fg] = await SupabaseService.resolvePaytmRouting(
            insId: insId!, banId: splitByFeeGroup ? _fgBankId[fg] : null);
      }
      final distinctMids = routingByFg.values
          .where((r) => r.ok && (r.mid ?? '').isNotEmpty)
          .map((r) => r.mid)
          .toSet();

      if (distinctMids.length > 1) {
        final names = payingFgIds
            .map((f) => _fgName[f] ?? 'fee group $f')
            .toList()
          ..sort();
        if (mounted) {
          setState(() => _processing = false);
          _showPaytmRoutingError(
              'An online payment settles into one account, but these dues '
              'belong to different accounts (${names.join(' and ')}). Collect '
              'one group at a time: untick the other card and pay this group '
              'first. Cash, cheque and DD can collect both together.');
        }
        return;
      }

      // Which Paytm merchant this payment settles to: the fee group's own bank
      // account, falling back to the institution's merchant. A payment that
      // cannot be routed is refused here rather than settled into the default
      // parent account with nothing to show it.
      final routing = payingFgIds.isEmpty
          ? await SupabaseService.resolvePaytmRouting(insId: insId!)
          : routingByFg[payingFgIds.first]!;
      if (!routing.ok) {
        if (mounted) {
          setState(() => _processing = false);
          _showPaytmRoutingError(routing.error!);
        }
        return;
      }
      final paytmMid = routing.mid;
      debugPrint('Paytm routing -> ${routing.mid} (${routing.source})');

      // Stamp the predominant fee group's bank on the payment row. This is a
      // label for Bank Reconciliation, not the settlement route — Paytm settles
      // to whichever account the merchant above is registered against.
      int? paytmBanId;
      try {
        final demIds = items.map((it) => it['dem_id']).whereType<int>().toList();
        if (demIds.isNotEmpty) {
          final fdRows = await SupabaseService.fromSchema('feedemand')
              .select('fee_id').inFilter('dem_id', demIds);
          final feeIds = (fdRows as List).map((r) => r['fee_id']).whereType<int>().toSet().toList();
          if (feeIds.isNotEmpty) {
            final ftRows = await SupabaseService.fromSchema('feetype')
                .select('fg_id').inFilter('fee_id', feeIds);
            final fgIds = (ftRows as List).map((r) => r['fg_id']).whereType<int>().toSet().toList();
            if (fgIds.isNotEmpty) {
              final fgRows = await SupabaseService.fromSchema('feegroup')
                  .select('ban_id').inFilter('fg_id', fgIds);
              final banIds = (fgRows as List).map((r) => r['ban_id']).whereType<int>().toList();
              if (banIds.isNotEmpty) {
                final counts = <int, int>{};
                for (final id in banIds) { counts[id] = (counts[id] ?? 0) + 1; }
                paytmBanId = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Paytm bank stamp resolve failed: $e');
      }

      // 1. Temporary payment row (status I).
      final payId = await SupabaseService.insertPayment({
        'ins_id': insId,
        'inscode': inscode,
        'stu_id': stuId,
        'yr_id': yrId ?? 0,
        'yrlabel': yrlabel,
        'transtotalamount': totalNet,
        'transcurrency': 'INR',
        'paydate': DateTime.now().toIso8601String(),
        'paystatus': 'I',
        'createdby': createdBy,
        'recon_status': 'P',
        'payitems': jsonEncode(items),
        if (paytmBanId != null) 'ban_id': paytmBanId,
      });
      createdPayId = payId;

      // 2. Initiate the Paytm transaction (server-side checksum + MID routing).
      final order = await PaytmService.createOrder(
        payId: payId,
        amount: totalNet,
        custId: 'STU-$stuId',
        mid: paytmMid,
      );
      await SupabaseService.updatePayment(payId, {'payorderid': order.orderId});

      // 3. Show the Paytm checkout + poll for status.
      String? result;
      if (mounted) {
        result = await showPaytmCheckout(
          context,
          order: order,
          amount: totalNet,
          studentName: _student!['stuname']?.toString() ?? '',
          studentMobile: _student!['stumobile']?.toString() ?? '',
          studentEmail: _student!['stuemail']?.toString() ?? '',
          // Paytm renders this inside its own checkout as who is being paid.
          // It used to be the institution name alone, so a hostel collection
          // and a college one were indistinguishable on the screen the payer
          // actually looks at -- even when the money was correctly routed to
          // different accounts. Naming the fee group makes the two tell apart.
          merchantName: () {
            final ins = auth.insName ?? 'KCET';
            final group = payingFgIds.isEmpty
                ? ''
                : (_fgName[payingFgIds.first] ?? '');
            return group.isEmpty ? ins : '$ins - $group';
          }(),
          // The fee group whose account this is going to, and the tail of the
          // merchant id that proves it -- the one place that shows WHICH
          // account, so a mis-route is visible before paying.
          settlingTo: () {
            final group = payingFgIds.isEmpty
                ? ''
                : (_fgName[payingFgIds.first] ?? 'fee group ${payingFgIds.first}');
            final mid = paytmMid ?? '';
            final tail = mid.length > 6 ? mid.substring(mid.length - 6) : mid;
            // NAME WHERE IT IS ACTUALLY GOING, not which fee group was
            // collected. When the group has no account of its own the money
            // falls back to the institution merchant -- printing the group
            // name beside that merchant's id would read as if the group's own
            // account had been used.
            if (!routing.routedToOwnAccount) {
              return tail.isEmpty
                  ? 'institution account (this fee group has none of its own)'
                  : 'institution account  ·  merchant …$tail';
            }
            if (group.isEmpty) return tail.isEmpty ? '' : 'merchant …$tail';
            return tail.isEmpty ? group : '$group  ·  merchant …$tail';
          }(),
        );
      }

      // 4. ASK PAYTM before deciding, and never write off an undecided payment.
      //
      // This used to be `status = result == 'C' ? 'C' : 'F'`: anything the
      // checkout dialog did not confirm was recorded as FAILED. The verify
      // call below already existed, but only to fetch a reference -- its
      // answer never changed the status.
      //
      // So a payment Paytm had CAPTURED was written off whenever the window
      // was closed early, the callback did not fire, or UPI was still settling
      // when the dialog resolved. The card was charged, no receipt was raised,
      // and nothing ever revisited an 'F' row -- the orphan sweep only looks
      // at 'I'. The money then turned up in the bank the next day with no
      // receipt to reconcile it against.
      //
      // Three outcomes now, not two:
      //   captured        -> 'C', raise the receipt, whatever the dialog said
      //   Paytm says fail -> 'F', a real decline
      //   undecided       -> leave the row 'I' and DO NOT complete it. The
      //                      sweep re-asks Paytm later and completes or fails
      //                      it then. An unresolved row is recoverable; a
      //                      wrongly failed one is not.
      String payRef = '';
      var gatewayMsg = '';
      bool gatewaySaysCaptured = false;
      bool gatewaySaysFailed = false;
      try {
        final s = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
        payRef = s.paymentId ?? '';
        gatewayMsg = s.message;
        gatewaySaysCaptured = s.isCaptured;
        gatewaySaysFailed = s.isFailed;
      } catch (e) {
        debugPrint('Paytm verify failed for ${order.orderId}: $e');
      }

      if (!gatewaySaysCaptured && !gatewaySaysFailed && result != 'C') {
        // Undecided. Leave the 'I' row alone for the sweep.
        if (mounted) {
          setState(() => _processing = false);
          _showPaytmRoutingError(
              'The bank has not confirmed this payment yet. Do not collect it '
              'again. If the money went through, the receipt appears here '
              'automatically within a few minutes. Attempt reference: '
              '${order.orderId}.');
        }
        return;
      }

      final status = (result == 'C' || gatewaySaysCaptured) ? 'C' : 'F';
      // The status API reports failure without a reason; the checkout callback
      // has Paytm's own words for it.
      if (gatewayMsg.isEmpty) gatewayMsg = PaytmService.lastGatewayMessage;

      // Items for per-group receipts (dem_id + amount + demfeetype).
      final completeItems = <Map<String, dynamic>>[];
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final fine = _fine(key);
        final col = _con(key);
        // Same rule as _netAmt / the NET AMOUNT column (see _processDirectPayment).
        final net = col + fine;
        if (net <= 0) continue;
        completeItems.add({
          'dem_id': d['dem_id'] as int,
          'amount': net,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      final reference = status == 'C' ? payRef : (result == 'F' ? 'FAILED:$payRef' : 'CANCELLED');
      try {
        // Paytm gateway → distinct "Online Transfer" mode in the MODE column
        // (still buckets as Online in charts/receipts, which lowercase + match
        // .contains('online')).
        final rpResult = await SupabaseService.completePaymentGrouped(
          token: _sessionToken, payId: payId, payMethod: 'Online Transfer',
          payReference: reference, items: completeItems, insId: insId, status: status);
        final receipts = rpResult is List ? rpResult : [rpResult];
        final receiptStr = receipts.map((r) => r is Map ? r['paynumber'] ?? r.toString() : r.toString()).join(', ');
        int? firstPayId;
        for (final r in receipts) {
          if (r is Map && r['pay_id'] != null) {
            firstPayId = r['pay_id'] is int ? r['pay_id'] as int : int.tryParse(r['pay_id'].toString());
            break;
          }
        }
        // On cancel/fail, clear any transient fine on the attempted demands.
        // On success, protect it from the reset-on-exit instead: _allDemands
        // still holds the pre-payment paidstatus, so dispose() would otherwise
        // wipe a fine that has just been collected.
        if (status != 'C') {
          for (final item in completeItems) {
            final demId = item['dem_id'];
            if (demId != null) {
              try {
                await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: 0);
              } catch (_) {}
            }
          }
        } else {
          for (final item in completeItems) {
            final demId = item['dem_id'];
            if (demId is int) _paidFineDemIds.add(demId);
          }
        }
        if (mounted) {
          if (status == 'C') {
            // Same as the direct path: attach the advance to the receipt the
            // gateway payment produced, before the dialog offers it.
            await _attachPendingAdjust(
                _payIdForPendingAdvance(receipts, firstPayId));
            _showSuccessDialog(receiptStr, totalNet, payId: firstPayId);
          } else {
            // The old message printed the raw receipt JSON, which told the
            // cashier nothing they could act on and looked like a crash. Say
            // what happened to the money instead: nothing was taken, the dues
            // are untouched, and the failed attempt is on record under this
            // order id.
            final failed = result == 'F';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    '${failed ? 'Paytm did not complete this payment' : 'Payment cancelled'}'
                    '${gatewayMsg.isEmpty ? '' : ' — $gatewayMsg'}. '
                    'Nothing has been collected and the dues are unchanged. '
                    'The attempt is recorded as ${order.orderId}; try again, or take it by another mode.'),
                backgroundColor: failed ? AppColors.error : AppColors.warning,
                duration: const Duration(seconds: 7),
              ));
          }
        }
      } catch (e) {
        debugPrint('complete_payment_grouped (Paytm) failed: $e');
        try {
          await SupabaseService.updatePayment(payId, {'paystatus': 'F'});
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error));
        }
      }
    } catch (e, st) {
      // Surface the real cause in the run log (the snackbar only shows a
      // friendly message) so failures can be diagnosed.
      debugPrint('PAYTM PAYMENT ERROR: $e');
      debugPrint('PAYTM PAYMENT STACK: $st');
      // Clean up the orphaned 'I' row so a failed/aborted attempt (e.g. a
      // network drop) doesn't block the next retry via the 15-min pending lock.
      if (createdPayId != null) {
        try {
          await SupabaseService.updatePayment(createdPayId, {'paystatus': 'F'});
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Paytm payment failed. ${friendlyError(e)}'), backgroundColor: AppColors.error));
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  // ── Helpers ──

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: AppUI.card(),
      padding: EdgeInsets.all(12.w),
      child: child,
    );
  }

  // Shared decoration for the Mode + Fee Type header dropdowns so they
  // render at the exact same height regardless of focus/value state.
  InputDecoration _headerDropdownDec({bool filled = false}) =>
      AppUI.field(context, '', filled: filled);

  // Shared styling for the Cheque / UPI / Online dialog input fields so
  // every input renders with the same bold-visible look.
  InputDecoration _dialogInputDec({required String hint, Widget? prefix, bool filled = false}) {
    final d = AppUI.field(context, hint, filled: filled);
    if (prefix == null) return d;
    return d.copyWith(
        prefixIcon: Padding(padding: const EdgeInsets.only(left: 12, right: 8), child: prefix));
  }

  TextStyle _dialogInputStyle({bool filled = false}) => AppUI.fieldText(context, filled: filled);

  bool get _compactCtx => MediaQuery.of(context).size.width <= 1366;

  TextStyle _ddTextStyle() => AppUI.fieldText(context);

  TextStyle _ddItemStyle() => AppUI.fieldText(context);

  InputDecoration _inputDec(String hint, {bool filled = false}) =>
      AppUI.field(context, hint, filled: filled);

  /// One line of dropdown text that shrinks to fit instead of wrapping onto
  /// a clipped second line.
  Widget _fitLine(String text, TextStyle style) => Align(
        alignment: Alignment.centerLeft,
        child: AppFitText(text, style: style),
      );

  Widget _detailRow(String icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon.linear(icon, size: 15, color: AppColors.textLight),
        SizedBox(width: 8.w),
        Text('$label  ', style: AppUI.muted),
        Expanded(
          child: Text(value,
              style: AppUI.label,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Widget _termChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border:
              Border.all(color: selected ? AppColors.primary : AppColors.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13.sp,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? AppColors.primary : AppColors.textSecondary)),
      ),
    );
  }

  Widget _numField(TextEditingController? ctrl, VoidCallback onChange, {int? maxLength, String? fieldKey, FocusNode? focusNode, bool enabled = true}) {
    if (ctrl == null) return const SizedBox();
    final filled = ctrl.text.trim().isNotEmpty;
    return SizedBox(
      height: 28.h,
      child: TextField(
        key: fieldKey != null ? ValueKey(fieldKey) : null,
        controller: ctrl,
        focusNode: focusNode,
        enabled: enabled,
        onChanged: (_) => onChange(),
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
          if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
        ],
        textAlign: TextAlign.center,
        style: AppUI.fieldText(context, filled: filled),
        // Kept at the row's compact height: this sits inside the dense demand
        // table, so only the kit's colours / radius / focus ring apply.
        decoration: AppUI.field(context, '0', filled: filled, dense: true).copyWith(
          contentPadding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 4.h),
          constraints: const BoxConstraints(),
        ),
      ),
    );
  }

  String _formatDate(String iso) {
    // Convert yyyy-MM-dd → dd-MM-yyyy
    final parts = iso.split('-');
    if (parts.length == 3) return '${parts[2]}-${parts[1]}-${parts[0]}';
    return iso;
  }
}

class _THCell extends StatelessWidget {
  final String text;
  final int flex;
  final TextAlign textAlign;
  const _THCell(this.text, {this.flex = 1, this.textAlign = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      // A gutter, so a right-aligned heading cannot touch the next column's.
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.w),
        child: Text(text.toUpperCase(),
            textAlign: textAlign,
            style: AppUI.tableHead),
      ),
    );
  }
}

class _TDCell extends StatelessWidget {
  final String text;
  final int flex;
  final TextStyle? style;
  final TextAlign textAlign;
  const _TDCell(this.text, {this.flex = 1, this.style, this.textAlign = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      // Same gutter as the heading above it, so figures line up under their
      // own column instead of crowding the neighbouring one.
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.w),
        child: Text(text,
            textAlign: textAlign,
            style: style ?? AppUI.cell,
            overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// One fee group's block in the demand table: its rows and its subtotal.
///
/// Each block is collected on its own receipt -- process_grouped_payment
/// raises one payment per fee group, numbered from that group's own sequence
/// and stamped with that group's mapped bank account. Nothing about a block
/// is merged with another.
class _FgBlock {
  const _FgBlock({
    required this.fgId,
    required this.label,
    required this.rows,
    required this.balance,
  });
  final int fgId;
  final String label;
  final List<Map<String, dynamic>> rows;
  final double balance;

  bool get isHostel => label.contains('HOSTEL') || label.contains('MESS');
  bool get isCollege => label.contains('COLLEGE') || label.contains('TUITION');

  /// Hostel green, college blue, anything else a neutral slate -- so the two
  /// receipts are told apart at a glance, not by reading the heading.
  Color get color => isHostel
      ? AppColors.success
      : isCollege
          ? AppColors.accent
          : AppColors.textSecondary;

  String get icon => isHostel
      ? 'home-2'
      : isCollege
          ? 'teacher'
          : 'folder-2';
}

/// One advance inside a staged adjustment plan: which advance, and what it
/// puts on each demand (dem_id -> amount).
///
/// Kept per advance rather than as one flat dem_id -> amount map, because
/// adjust_advance spends ONE advance per call: the split has to survive all
/// the way to the commit, or the money comes off whichever advance happened to
/// be first.
class _PlannedAdvance {
  const _PlannedAdvance({
    required this.advId,
    required this.advNo,
    required this.lines,
  });
  final int advId;
  final String advNo;
  final Map<String, double> lines;

  double get total => lines.values.fold(0, (a, b) => a + b);
}


/// The ticked fee lines -- a plain set, except that a line HELD for a pending
/// concession (Concession Approval) is never added, whichever path ticks it
/// (row tick, tick-all, auto-tick on load).
class _HeldAwareSet extends SetBase<String> {
  final Set<String> _inner = <String>{};
  Set<String> held = <String>{};
  @override
  bool add(String value) => held.contains(value) ? false : _inner.add(value);
  @override
  bool contains(Object? element) => _inner.contains(element);
  @override
  String? lookup(Object? element) => _inner.lookup(element);
  @override
  bool remove(Object? value) => _inner.remove(value);
  @override
  Iterator<String> get iterator => _inner.iterator;
  @override
  int get length => _inner.length;
  @override
  Set<String> toSet() => _inner.toSet();
}
