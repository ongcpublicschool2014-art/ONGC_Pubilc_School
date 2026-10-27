import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/pill_tab.dart';
import '../../widgets/student_avatar.dart';
import '../../utils/friendly_error.dart';
import '../../utils/formatters.dart';
import '../../utils/fee_kind.dart';
import '../../utils/class_sort.dart';
import '../../utils/school_terms.dart';

const _termOrder = [
  'I SEMESTER', 'I TERM', 'II SEMESTER', 'II TERM', 'III SEMESTER', 'III TERM',
  'IV SEMESTER', 'V SEMESTER', 'VI SEMESTER',
  'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER',
  'NOVEMBER', 'DECEMBER', 'JANUARY', 'FEBRUARY',
  'MARCH', 'APRIL', 'MAY',
];

int _termIndex(String t) {
  final idx = _termOrder.indexWhere((x) => x.toLowerCase() == t.toLowerCase());
  return idx >= 0 ? idx : _termOrder.length;
}

String _formatDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
String _formatDateCompact(DateTime d) => '${d.day.toString().padLeft(2, '0')}${d.month.toString().padLeft(2, '0')}${d.year}';

String _formatNumber(double v) => formatIndianNumber(v);

class ReportsScreen extends StatefulWidget {
  /// Which report tab to open at (0=Daily Collection … 5=Export).
  final int initialTab;

  /// When false, the in-screen pill tab bar is hidden — used when each report
  /// is its own sidebar submenu (the sidebar is the tab selector).
  final bool showTabBar;

  const ReportsScreen({super.key, this.initialTab = 0, this.showTabBar = true});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> with SingleTickerProviderStateMixin {

  /// The title block every report on this screen uses.
  ///
  /// Each report used to build its own, and they had drifted: three
  /// different paddings, and four of the seven passed a `subtitle` to
  /// CardTitleBlock -- which stopped rendering one ("accepted for call-site
  /// compatibility; no longer rendered"), so that text was carried and never
  /// shown. Two reports had no subtitle at all.
  ///
  /// Built here rather than by re-enabling it in CardTitleBlock: dropping
  /// subtitles from card headers was a deliberate decision, and 25 call
  /// sites outside Reports still pass one. Changing the shared widget would
  /// put a subtitle under headers all over the app, which is not what was
  /// asked for.
  Widget _reportTitle(String icon, String title, String subtitle) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AppUI.iconTile(icon),
      SizedBox(width: 12.w),
      Flexible(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, overflow: TextOverflow.ellipsis, style: AppUI.cardTitle),
          SizedBox(height: 2.h),
          Text(subtitle, overflow: TextOverflow.ellipsis, style: AppUI.muted),
        ],
      )),
    ]);
  }

  late TabController _tabController;

  // Data
  List<Map<String, dynamic>> _allDemands = [];
  bool _loading = false;
  String? _error;

  // Filters
  List<String> _courses = [];
  List<String> _classes = [];
  List<String> _feeTypes = [];
  String? _selectedCourse;
  Set<String> _selectedClasses = <String>{}; // empty = all classes (multi-select)
  Set<String> _selectedAdmnTypes = <String>{}; // Pending Payment tab: filter by admission types (multi-select)
  Set<String> _selectedQuotas = <String>{};    // Pending Payment tab: filter by quotas (multi-select)
  Set<String> _selectedSeqTypes = <String>{};  // Pending Payment tab: Regular / Arrear (multi-select)

  // DCB Student Register (per-course Demand / Collection / Balance).
  bool _dcbLoaded = false;
  bool _dcbExporting = false;
  Map<String, Map<String, dynamic>> _stuInfo = {};   // admno -> {batch, quoname, admname, stuname}
  Map<int, String> _feeIdToType = {};                // fee_id -> feetype.type (COL/TRA/...)
  Map<String, String> _feeTypeNameToType = {};       // fee type name (upper) -> feetype.type
  Map<int, Map<String, dynamic>> _stuReceipt = {};   // stu_id -> {paynumber, paydate} (latest reconciled)
  Map<String, int> _dcbClassOrdid = {};              // class ordid for ordering
  List<String> _dcbTypeOptions = [];                  // distinct feetype.type values (DCB Type filter)
  /// Transfer-Certificate filter, shared by Pending Payment, Pending Details,
  /// Consolidated Status and the DCB Register.
  ///
  /// 'NOTC' (the default) leaves out students who hold a TC: they have left,
  /// and their dues are money nobody is going to collect. 'TC' shows only
  /// those students, 'ALL' shows both. The Student Ledger ignores it -- a
  /// leaver's ledger must still open -- and marks them TC ISSUED instead.
  String _tcFilter = 'NOTC';
  static const Map<String, String> _kTcLabels = {
    'NOTC': 'Without TC',
    'TC': 'TC Issued',
    'ALL': 'All Students',
  };

  /// feetype.type (COL / TRA / HOS). A SECOND axis from the fee group: the
  /// group is which bank account, the kind is what sort of charge. Shared by
  /// every report that narrows by fee, which is why it is not named for DCB
  /// any more -- it used to be _dcbTypes and lived on that one tab.
  Set<String> _selectedFeeKinds = <String>{};
  final GlobalKey _dcbFgKey = GlobalKey();
  Set<String> _dcbAdmnTypes = <String>{};            // selected admission types (empty = all)
  final GlobalKey _dcbAdmKey = GlobalKey();
  final GlobalKey _admnTypeKey = GlobalKey();
  final GlobalKey _quotaKey = GlobalKey();
  final GlobalKey _pendSeqKey = GlobalKey();
  Set<String> _selectedFeeTypes = <String>{};
  final GlobalKey _feeTypeKey = GlobalKey();

  /// Fee GROUP filter. Narrows a report to the fees banked into one account
  /// -- COLLEGE FEES, HOSTEL FEES -- which is how the accounts are actually
  /// kept and reconciled.
  ///
  /// Composes with the Fee Type filter rather than replacing it: picking
  /// HOSTEL FEES and then MESS FEE shows mess fees only, and picking a group
  /// alone shows everything in it.
  Set<String> _selectedFeeGroups = <String>{};
  List<String> _feeGroups = [];
  /// UPPER-CASED feedesc -> the groups it belongs to. A fee type absent here
  /// belongs to no live group and is hidden whenever a group filter is on.
  ///
  /// A SET because five descriptions exist under both COLLEGE FEES and HOSTEL
  /// FEES; such a fee shows under either filter rather than being assigned to
  /// one of them by accident of load order.
  Map<String, Set<String>> _feeTypeGroup = {};
  /// fee_id -> group. Exact, and preferred wherever the row carries one.
  Map<int, String> _feeIdGroup = {};
  final GlobalKey _feeGroupKey = GlobalKey();
  // Multi-select (checkbox) filters shared/Daily: empty set = "all".
  final GlobalKey _classKey = GlobalKey();
  final GlobalKey _prefixKey = GlobalKey();
  final GlobalKey _dailyTypeKey = GlobalKey();
  final GlobalKey _advTypeKey = GlobalKey();

  /// The tab the filters currently belong to; see [_onTabChanged].
  int _lastTabIndex = 0;

  /// Index of the Advance Register tab in [_tabController] / the TabBarView.
  static const int _kAdvanceRegisterTab = 6;

  /// Index of the Pending Details tab in [_tabController] / the TabBarView.
  static const int _kPendingDetailsTab = 3;

  /// A Refresh press is in flight — drives the spinner in the button.
  bool _refreshing = false;

  /// Re-read the data behind whichever report is on screen.
  ///
  /// Every tab caches its rows -- some behind a once-only flag -- so before
  /// this existed the Refresh button cleared the filters and nothing re-read
  /// the database: a fee collected while the report was open never showed up
  /// until you left the screen and came back.
  /// Put every filter back to its default.
  ///
  /// Shared by the Reset button and by switching report, so the two can never
  /// drift apart. Call it inside setState.
  void _clearFilters() {
    _selectedCourse = null;
    _selectedClasses = <String>{};
    _selectedFeeTypes = <String>{};
    _selectedFeeGroups = <String>{};
    _selectedPrefixes = <String>{};
    _selectedDailyTypes = <String>{};
    _selectedAdmnTypes = <String>{};
    _selectedQuotas = <String>{};
    _selectedSeqTypes = <String>{};
    _selectedFeeKinds = <String>{};
    _dcbAdmnTypes = <String>{};
    _selectedUser = null;
    _tcFilter = 'NOTC';
    _pdSeq = '';
    // Pending Details re-pivots from rows it already holds, so this costs no
    // round trip even when that tab is not the one being opened.
    _pdPivot();
  }

  /// A filter belongs to the report it was set on, not to the screen.
  ///
  /// A Course left over from Pending Payment silently narrowed whatever report
  /// was opened next -- and its grand total with it, which is the kind of wrong
  /// number nobody double-checks.
  void _onTabChanged() {
    // The listener fires twice per swipe: once as the animation starts, once
    // when it settles.
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == _lastTabIndex) return;
    _lastTabIndex = _tabController.index;
    // The register is fetched on FIRST open rather than at startup: it is
    // a whole year of advances and most sessions never open this tab.
    if (_tabController.index == _kAdvanceRegisterTab && !_advLoaded) {
      _loadAdvanceRegister();
    }
    // Three of the reports are filtered by the SERVER on p_tc, so a reset there
    // has to be fetched again rather than merely redrawn.
    final refetch = _tcFilter != 'NOTC';
    setState(_clearFilters);
    if (refetch) {
      _pendingMetaLoaded = false;
      _pdLoaded = false;
      _refreshActiveTab();
    }
  }

  Future<void> _refreshActiveTab() async {
    Future<void>? work;
    switch (_tabController.index) {
      case 0: // Daily Collection
        work = _loadDailyCollection();
        break;
      case 1: // Student Ledger -- only meaningful once a student is picked
        final admno = _ledgerStuAdmNo;
        if (admno != null && admno.isNotEmpty) work = _loadStudentLedger(admno);
        break;
      case 2: // Pending Payment
      case 4: // Consolidated Status -- same RPC pair feeds both
        work = _loadPendingMeta(force: true);
        break;
      case _kPendingDetailsTab:
        work = _loadPendingDetails(force: true);
        break;
      case 5: // DCB Register
        work = _loadDcbMeta(force: true);
        break;
      case _kAdvanceRegisterTab:
        work = _loadAdvanceRegister(force: true);
        break;
    }
    if (work == null) return;
    // Two of these loaders (Pending Payment / Consolidated Status, DCB) set no
    // loading flag of their own, so without this the button would look inert
    // for the several seconds the RPC takes.
    setState(() => _refreshing = true);
    try {
      await work;
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // Institution info
  String _insName = '';
  String _insAddress = '';
  String _insPhone = '';
  String _insEmail = '';

  // the Daily Collection range when the user navigates between tabs.
  // Export tab collection-type filter: All / Regular / Arrear

  // Daily collection tab state
  DateTime? _dailyFrom;
  DateTime? _dailyTo;
  bool _dailyLoading = false;

  /// Why the last Daily Collection load returned nothing, when the reason was
  /// a failure rather than an empty range.
  ///
  /// The load used to swallow its exception and leave the rows empty, so a
  /// statement timeout rendered as "No collections in this range" -- a
  /// finance report stating, in good faith, that no money was taken. The two
  /// must never look the same.
  String? _dailyError;
  /// feedesc -> feeshort, for the EXPORT column headers. Full descriptions
  /// ("MARK SHEET VERFICATION", "ADMISSION & TRANSFER FEE") make the exported
  /// grid unreadable at any sane column width; the short code is what the
  /// printed statement has always used.
  Map<String, String> _feeShort = {};

  /// feedesc -> feetype.ordid. Decides the LEFT-TO-RIGHT order of the
  /// fee-type columns. Empty on an older database, which falls back to
  /// alphabetical -- the behaviour these reports had before.
  Map<String, int> _feeOrder = {};

  /// Export header for a fee type: its short code when the master has one,
  /// otherwise the full description so a type added without a code still
  /// appears rather than showing a blank column.
  String _feeHdr(String feedesc) => _feeShort[feedesc] ?? feedesc;

  List<Map<String, dynamic>> _dailyRows = [];
  /// Receipts taken in the range but not yet matched against a bank statement.
  /// Kept apart from [_dailyRows] so they never inflate Total Collected — the
  /// money is in hand but unconfirmed, and the two must not be added together.
  List<Map<String, dynamic>> _dailyUnrecRows = [];

  /// Excel / PDF / Print are dead only when there is NOTHING to put in them.
  ///
  /// They used to be disabled on `_dailyRows.isEmpty` alone -- but unreconciled
  /// receipts are deliberately held in a separate list so they cannot inflate
  /// Total Collected, so a day whose receipts are ALL unreconciled left
  /// `_dailyRows` empty and the buttons inert, while the screen plainly showed
  /// receipts underneath. All three exports already include both lists.
  bool get _dailyNothingToExport =>
      _dailyRows.isEmpty && _dailyUnrecRows.isEmpty;
  List<String> _dailyFeeTypes = [];
  final ScrollController _dailyHScroll = ScrollController();
  final ScrollController _stickyHScroll = ScrollController();
  String? _selectedMode; // null = all, 'cash', 'bank'
  Set<String> _selectedPrefixes = <String>{}; // empty = all prefixes
  Set<String> _selectedDailyTypes = <String>{}; // empty = all types
  String? _selectedUser; // null = all, else a specific createdby (collector) name

  // Student Ledger tab state
  String? _ledgerStuAdmNo;
  // ── Pending Details ──────────────────────────────────────────────────────
  /// One row per student with a pending amount PER FEE TYPE -- the printed
  /// "PENDING DETAIL REPORT" the office uses, which the existing Pending
  /// Payment report cannot produce: that one aggregates per student/semester
  /// and has no fee-type breakdown.
  bool _pdLoading = false;
  /// Set once the RPC has been ATTEMPTED (success or failure). Without it the
  /// post-frame auto-load re-fires on every rebuild after an error.
  bool _pdLoaded = false;
  List<Map<String, dynamic>> _pdRows = [];
  List<String> _pdFeeTypes = [];
  String? _pdError;
  /// The flat (student x fee type) rows exactly as the RPC returned them. Kept
  /// so the Regular/Arrear filter can re-pivot without another round trip.
  List<Map<String, dynamic>> _pdRaw = [];
  /// '' = both. Otherwise 'REGULAR' or 'ARREAR', matched against demseqtype.
  String _pdSeq = '';

  bool _ledgerLoading = false;

  /// The TC this student holds, when they hold one -- number, date and effect
  /// date, for the header. The ledger opens either way: a student who has left
  /// is exactly the one you look up to find what they left owing.
  Map<String, dynamic>? _ledgerTc;
  List<Map<String, dynamic>> _ledgerDemands = [];
  List<Map<String, dynamic>> _ledgerMisc = []; // misc collections (collection-only)
  List<Map<String, dynamic>> _ledgerAdv = []; // advances taken from this student
  // Per-demand detail, keyed by dem_id. The ledger RPC returns ONE paynumber
  // per demand, so a fee settled by two receipts collapsed into a single line
  // showing only one of them; these give a line per receipt, per concession and
  // per refund, each with its own document number.
  Map<int, List<Map<String, dynamic>>> _ledgerAlloc = {};
  Map<int, List<Map<String, dynamic>>> _ledgerConcDet = {};
  Map<int, List<Map<String, dynamic>>> _ledgerRefDet = {};
  Map<int, Map<String, dynamic>> _ledgerPayments = {};
  Map<String, dynamic>? _ledgerStudent;
  /// students.stuphoto for the ledger student -- the report RPC carries no
  /// photo, so it is looked up once per pick. Null shows the initial.
  String? _ledgerPhoto;
  final TextEditingController _ledgerSearchCtrl = TextEditingController();

  bool _isCashMode(String paymethod) {
    final m = paymethod.toUpperCase();
    return m.contains('CASH') || m.contains('CHEQUE') || m.contains('DD');
  }

  String _prefixOf(String paynumber) {
    final m = RegExp(r'^[A-Za-z]+').firstMatch(paynumber);
    return m?.group(0) ?? '';
  }

  /// The fee-level filters hang off the Fee Group.
  ///
  /// Daily Collection's Fee Type, Prefix and Type and the DCB Register's fee
  /// KIND all answer "which of these", and what counts as a candidate depends
  /// on which account the money banks into. Ask them before the group is set
  /// and the lists are the whole college -- every prefix, every fee type,
  /// COL and HOS and TRA together -- which is exactly the state that made the
  /// bar unusable: six pickers, none of them narrowing anything.
  ///
  /// One fee group means there is nothing to choose, and the Fee Group
  /// control is hidden for that reason -- so the gate is open from the start
  /// rather than locked on a filter the operator cannot even see.
  bool get _feeGroupChosen =>
      _feeGroups.length < 2 || _selectedFeeGroups.isNotEmpty;

  static const String _kFeeGroupFirst = 'Select a fee group first';

  /// True when this Daily Collection receipt carries money against a fee in
  /// the chosen groups.
  ///
  /// GROUP only, deliberately -- not the Fee Type selection. Fee Type sits
  /// beside Prefix and Type, not above them, so narrowing these three by one
  /// another would let two sibling filters empty each other with nothing on
  /// screen explaining which one did it.
  bool _dailyRowInGroups(Map<String, dynamic> r) {
    if (_selectedFeeGroups.isEmpty) return true;
    final fees = r['fees'] as Map<String, double>?;
    if (fees == null) return true;
    return fees.entries.any((e) => e.value > 0 && _inSelectedGroups(e.key));
  }

  List<String> _dailyPrefixes() {
    final set = <String>{};
    for (final r in _dailyRows) {
      if (!_dailyRowInGroups(r)) continue;
      final n = r['paynumber']?.toString() ?? '';
      final p = _prefixOf(n);
      if (p.isNotEmpty) set.add(p);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// Every transaction type Daily Collection knows, in reading order.
  static const List<String> _kDailyTypes = [
    'Regular',
    'Arrear',
    'Misc',
    'Advance',
    'Advance (Admission)',
    'Advance (Mess)',
    // Listed for audit, but carries no amount -- the money was counted on the
    // day the advance was taken.
    'Advance Adjusted',
    'Cancelled',
  ];

  /// The types actually present in the loaded range, once the fee group has
  /// had its say. A fixed list offered Advance (Mess) against COLLEGE FEES
  /// and returned nothing.
  List<String> _dailyTypeOptions() {
    final present = <String>{};
    for (final r in _dailyRows) {
      if (!_dailyRowInGroups(r)) continue;
      present.add(r['type']?.toString() ?? 'Regular');
    }
    final list = _kDailyTypes.where(present.contains).toList();
    // Anything the report invented since this list was written still shows,
    // rather than becoming unfilterable.
    for (final t in present) {
      if (!list.contains(t)) list.add(t);
    }
    return list;
  }

  String _paymentBucket(String paymethod) {
    final m = paymethod.toUpperCase();
    if (m.contains('CASH')) return 'cash';
    // Cheque and DD are banked instruments, so they belong in the BANK column
    // rather than a third one of their own: the cash-up only needs to split
    // what is in the drawer from what goes to the bank.
    return 'bank';
  }

  /// Daily Collection order: day first, then receipt number ASCENDING within
  /// the day -- a collection statement is read as a receipt book.
  ///
  /// The trailing digits are compared numerically, so FC26/02699 precedes
  /// FC26/02700 rather than sorting after it as text would, and Fee and Misc
  /// receipts interleave correctly since they share one sequence. Sorting by
  /// date alone left same-day rows in whatever order the queries returned.
  static int _dailyReceiptNo(Map<String, dynamic> r) {
    final m = RegExp(r'(\d+)\s*\$').firstMatch(r['paynumber']?.toString().trim() ?? '');
    return m == null ? -1 : (int.tryParse(m.group(1)!) ?? -1);
  }

  static int _byDayThenReceipt(Map<String, dynamic> a, Map<String, dynamic> b) {
    final da = (a['paydate']?.toString() ?? '');
    final db = (b['paydate']?.toString() ?? '');
    final day = da.length >= 10 ? da.substring(0, 10) : da;
    final dbDay = db.length >= 10 ? db.substring(0, 10) : db;
    final c = day.compareTo(dbDay);
    if (c != 0) return c;
    final na = _dailyReceiptNo(a), nb = _dailyReceiptNo(b);
    if (na != nb) return na.compareTo(nb);
    return (a['paynumber']?.toString() ?? '').compareTo(b['paynumber']?.toString() ?? '');
  }

  String _dailyFmt(DateTime? d) =>
      d == null ? '-' : '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  String _dailyDateMethodLabel() {
    final hasDate = _dailyFrom != null || _dailyTo != null;
    final hasMode = _selectedMode != null;
    if (!hasDate && !hasMode) return 'Date & Mode';
    String datePart;
    if (!hasDate) {
      datePart = 'All Dates';
    } else if (_dailyFrom != null && _dailyTo != null) {
      datePart = '${_dailyFmt(_dailyFrom)} - ${_dailyFmt(_dailyTo)}';
    } else if (_dailyFrom != null) {
      datePart = 'From ${_dailyFmt(_dailyFrom)}';
    } else {
      datePart = 'Until ${_dailyFmt(_dailyTo)}';
    }
    if (hasMode) {
      return '$datePart • ${_selectedMode!.toUpperCase()}';
    }
    return datePart;
  }


  Future<void> _openDailyDateMethodDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        DateTime? from = _dailyFrom;
        DateTime? to = _dailyTo;
        String? mode = _selectedMode;
        String? user = _selectedUser;
        // Every distinct collector in the currently loaded daily rows, by name
        // (createdby = the collecting user's usename) — admin, accountant or
        // anyone else who posted a receipt.
        final users = {
          for (final r in _dailyRows)
            if ((r['createdby']?.toString() ?? '').trim().isNotEmpty)
              r['createdby'].toString(),
        }.toList()..sort();
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          String activePreset() {
            if (from == null && to == null) return 'All';
            if (from == null || to == null) return '';
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            bool sameDay(DateTime a, DateTime b) =>
                a.year == b.year && a.month == b.month && a.day == b.day;
            if (sameDay(from!, today) && sameDay(to!, today)) return 'Today';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 7)))) return '7 Days';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 30)))) return '30 Days';
            if (sameDay(to!, today) && sameDay(from!, DateTime(now.year, now.month, 1))) return 'This Month';
            return '';
          }
          final preset = activePreset();
          Widget presetChip(String label, VoidCallback onTap) {
            final selected = preset == label;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primaryLight : Colors.white,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: selected ? AppColors.primary : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: AppUI.label.copyWith(color: selected ? AppColors.primary : AppColors.textSecondary),
                  ),
                ),
              ),
            );
          }

          Widget datePickerBox({required String hint, required DateTime? value, required ValueChanged<DateTime?> onChanged}) {
            // Filled = a date is chosen -> amber border + amber bold text.
            final filled = value != null;
            return InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (picked != null) onChanged(picked);
              },
              child: Container(
                constraints: BoxConstraints(minHeight: AppUI.controlHeight(ctx)),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: filled ? AppColors.primary.withValues(alpha: 0.55) : AppColors.border),
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_today, size: 14, color: filled ? AppColors.primary : AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Text(filled ? _dailyFmt(value) : hint,
                        style: filled
                            ? AppUI.fieldText(ctx, filled: true)
                            : AppUI.fieldText(ctx).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)),
                  ],
                ),
              ),
            );
          }

          Widget modeChip(String label, String? key) {
            final selected = mode == key;
            return Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: InkWell(
                onTap: () => setStateDialog(() => mode = key),
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primaryLight : Colors.white,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: selected ? AppColors.primary : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: AppUI.label.copyWith(color: selected ? AppColors.primary : AppColors.textSecondary),
                  ),
                ),
              ),
            );
          }

          Widget sectionLabel(String text) => AppUI.sectionLabel(text);

          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            title: Row(
              children: [
                Text('Filters', style: AppUI.cardTitle),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                  splashRadius: 18,
                  tooltip: 'Close',
                ),
              ],
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  sectionLabel('QUICK RANGE'),
                  Wrap(children: [
                    presetChip('Today', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = DateTime(now.year, now.month, now.day); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('7 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 7)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('30 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 30)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('This Month', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = DateTime(now.year, now.month, 1); to = DateTime(now.year, now.month, now.day); });
                    }),
                  ]),
                  const SizedBox(height: 16),
                  sectionLabel('CUSTOM RANGE'),
                  Row(children: [
                    Expanded(child: datePickerBox(hint: 'Select from date', value: from, onChanged: (d) => setStateDialog(() => from = d))),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('-')),
                    Expanded(child: datePickerBox(hint: 'Select to date', value: to, onChanged: (d) => setStateDialog(() => to = d))),
                  ]),
                  const SizedBox(height: 16),
                  sectionLabel('PAYMENT MODE'),
                  Wrap(children: [
                    modeChip('All', null),
                    modeChip('Cash', 'cash'),
                    modeChip('Bank', 'bank'),
                  ]),
                  // USER (collector) filter - only relevant for the Cash mode,
                  // since cash is the only method a person physically handles.
                  // Bank/online payments reconcile via
                  // the payment gateway, not per-user, so the filter would
                  // just split already-unrelated totals.
                  if (mode == 'cash' && users.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    sectionLabel('USER'),
                    Wrap(children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 6),
                        child: InkWell(
                          onTap: () => setStateDialog(() => user = null),
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: user == null ? AppColors.primaryLight : Colors.white,
                              borderRadius: BorderRadius.circular(AppUI.controlRadius),
                              border: Border.all(color: user == null ? AppColors.primary : AppColors.border),
                            ),
                            child: Text('All',
                                style: AppUI.label.copyWith(color: user == null ? AppColors.primary : AppColors.textSecondary)),
                          ),
                        ),
                      ),
                      ...users.map((u) {
                        final selected = user == u;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 6),
                          child: InkWell(
                            onTap: () => setStateDialog(() => user = u),
                            borderRadius: BorderRadius.circular(AppUI.controlRadius),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: selected ? AppColors.primaryLight : Colors.white,
                                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                                border: Border.all(color: selected ? AppColors.primary : AppColors.border),
                              ),
                              child: Text(u,
                                  style: AppUI.label.copyWith(color: selected ? AppColors.primary : AppColors.textSecondary)),
                            ),
                          ),
                        );
                      }),
                    ]),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setStateDialog(() { from = null; to = null; mode = null; user = null; }),
                child: Text('Clear', style: AppUI.label.copyWith(color: AppColors.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _dailyFrom = from;
                    _dailyTo = to;
                    _selectedMode = mode;
                    // User filter only applies under Cash; clear it when
                    // the mode is anything else so non-cash rows aren't
                    // silently filtered out by a stale user selection.
                    _selectedUser = (mode == 'cash') ? user : null;
                  });
                  _loadDailyCollection();
                  Navigator.pop(ctx);
                },
                child: const Text('Apply'),
              ),
            ],
          );
        });
      },
    );
  }

  List<Widget> _dailyModeChips() {
    Widget chip(String label, String? key) {
      final active = _selectedMode == key;
      return Padding(
        padding: EdgeInsets.only(right: 4.w),
        child: InkWell(
          onTap: () => setState(() => _selectedMode = key),
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
            decoration: BoxDecoration(
              color: active ? AppColors.primaryLight : Colors.white,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: active ? AppColors.primary : AppColors.border),
            ),
            child: Text(label, style: AppUI.label.copyWith(color: active ? AppColors.primary : AppColors.textSecondary)),
          ),
        ),
      );
    }
    return [
      chip('All', null),
      chip('Cash', 'cash'),
      chip('Bank', 'bank'),
    ];
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: 7, vsync: this, initialIndex: widget.initialTab.clamp(0, 6));
    _lastTabIndex = _tabController.index;
    _tabController.addListener(_onTabChanged);
    final now = DateTime.now();
    // Daily Collection opens on TODAY -- it is the day's cash-up sheet, and the
    // month-to-date default meant every open started by narrowing the range.
    // The Filters dialog still offers 7 Days / 30 Days / This Month.
    _dailyFrom = DateTime(now.year, now.month, now.day);
    _dailyTo = DateTime(now.year, now.month, now.day);
    _loadData();
    _loadDailyCollection();
    // Opened STRAIGHT at this tab from the sidebar: _lastTabIndex was just set
    // to the same index, so no tab CHANGE fires and the lazy load in
    // _onTabChanged never runs -- the register read "No advances in this
    // range" with every advance sitting in the table.
    if (_tabController.index == _kAdvanceRegisterTab) _loadAdvanceRegister();
  }

  @override
  void didUpdateWidget(covariant ReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Each report is a separate sidebar submenu, but the dashboard reuses this
    // same widget/State when switching between them — so react to initialTab
    // changing and move the (hidden) tab controller to the requested report.
    if (widget.initialTab != oldWidget.initialTab &&
        _tabController.index != widget.initialTab) {
      _tabController.index = widget.initialTab.clamp(0, 6);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Fetch fee report data via RPC (single call, no pagination needed)
  Future<List<Map<String, dynamic>>> _fetchFeeDemandsDirectly(int insId) async {
    try {
      // 'ALL' on purpose: ONE load serves every tab. The DCB Register hides
      // students who hold a TC, the Student Ledger must still be able to open
      // them, so the filtering happens on screen off the stuactive field this
      // overload returns.
      final result = await SupabaseService.client
          .rpc('get_fee_report_data', params: {'p_ins_id': insId, 'p_tc': 'ALL'});
      if (result != null) return List<Map<String, dynamic>>.from(result as List);
    } catch (e) {
      debugPrint('RPC get_fee_report_data(p_tc) failed: $e');
      // A server without the overload: the original call still works, it just
      // returns active students only (no TC Issued rows to filter to).
      try {
        final result = await SupabaseService.client
            .rpc('get_fee_report_data', params: {'p_ins_id': insId});
        if (result != null) return List<Map<String, dynamic>>.from(result as List);
      } catch (e2) {
        debugPrint('RPC get_fee_report_data failed, using fallback: $e2');
      }
    }
    // Fallback: direct query
    const batchSize = 1000;
    int offset = 0;
    final allResults = <Map<String, dynamic>>[];
    while (true) {
      final batch = await SupabaseService.fromSchema('feedemand')
          .select('fee_id, stu_id, feeamount, conamount, paidamount, fineamount, balancedue, reconbalancedue, paidstatus, stuclass, courname, stuadmno, demfeetype, demfeeterm, activestatus')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .range(offset, offset + batchSize - 1);
      final list = batch as List;
      allResults.addAll(list.cast<Map<String, dynamic>>());
      if (list.length < batchSize) break;
      offset += batchSize;
    }
    // Enrich with student names
    final stuIds = allResults.map((d) => d['stu_id']).where((id) => id != null).toSet().toList();
    final Map<int, String> stuNameMap = {};
    // activestatus travels with the name so the TC filter works on the fallback
    // path too.
    final Map<int, int> stuActiveMap = {};
    for (int i = 0; i < stuIds.length; i += 200) {
      final chunk = stuIds.sublist(i, (i + 200).clamp(0, stuIds.length));
      final students = await SupabaseService.fromSchema('students').select('stu_id, stuname, activestatus').inFilter('stu_id', chunk);
      for (final s in students) {
        stuNameMap[s['stu_id'] as int] = s['stuname']?.toString() ?? '';
        stuActiveMap[s['stu_id'] as int] = (s['activestatus'] as num?)?.toInt() ?? 1;
      }
    }
    for (final d in allResults) {
      d['stuname'] = stuNameMap[d['stu_id'] as int?] ?? d['stuadmno']?.toString() ?? '';
      d['stuactive'] = stuActiveMap[d['stu_id'] as int?] ?? 1;
    }
    return allResults;
  }

  Future<void> _loadData() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _fetchFeeDemandsDirectly(insId),
        SupabaseService.getInstitutionInfo(insId),
      ]);
      final demands = results[0] as List<Map<String, dynamic>>;
      final insInfo = results[1] as ({String? name, String? logo, String? address, String? mobile, String? email});

      // Extract filters
      final courseSet = <String>{};
      final classSet = <String>{};
      final feeTypeSet = <String>{};
      for (final d in demands) {
        final c = d['courname']?.toString() ?? '';
        final cl = d['stuclass']?.toString() ?? '';
        final ft = d['demfeetype']?.toString() ?? '';
        if (c.isNotEmpty) courseSet.add(c);
        if (cl.isNotEmpty) classSet.add(cl);
        if (ft.isNotEmpty) feeTypeSet.add(ft);
      }

      // Class-master ordid → order classes by the institution's preferred order.
      final classOrdid = await SupabaseService.getClassOrder(insId);
      // Fee-master ordid → same idea for the fee-type columns.
      final feeOrdid = await SupabaseService.getFeeTypeOrder(insId);
      // feedesc → fee group, for the Fee Group filter.
      final feeGroupOf = await SupabaseService.getFeeTypeGroups(insId);
      final feeIdGroupOf = await SupabaseService.getFeeIdGroups(insId);
      final kinds = await SupabaseService.getFeeKindMaps(insId);

      if (mounted) setState(() {
        _allDemands = demands;
        _courses = courseSet.toList()..sort();
        _classes = classSet.toList()..sort(classOrdidComparator(classOrdid));
        _feeOrder = feeOrdid;
        _feeTypeGroup = feeGroupOf;
        _feeIdGroup = feeIdGroupOf;
        _feeIdToType = kinds.byId;
        _feeTypeNameToType = kinds.byName;
        if (_dcbTypeOptions.isEmpty) _dcbTypeOptions = kinds.codes;
        // The picker offers only groups that something is actually billed
        // under, not the whole master -- a filter that returns nothing is
        // noise, and an empty group is configuration, not a report.
        _feeGroups = feeGroupOf.values.expand((g) => g).toSet().toList()..sort();
        _feeTypes = feeTypeSet.toList()..sort(feeTypeOrdidComparator(feeOrdid));
        _insName = insInfo.name ?? '';
        _insAddress = insInfo.address?.replaceAll('\n', ', ') ?? '';
        _insPhone = insInfo.mobile ?? '';
        _insEmail = insInfo.email ?? '';
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  Future<void> _loadDailyCollection() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null || _dailyFrom == null || _dailyTo == null) return;
    setState(() {
      _dailyLoading = true;
      _dailyError = null;
      _dailyRows = [];
      _dailyUnrecRows = [];
      _dailyFeeTypes = [];
    });
    try {
      String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
      // One call via the json_agg wrapper returns ALL rows (a scalar JSON return
      // isn't subject to PostgREST's 1000-row cap), so the aggregate runs once
      // instead of being re-executed per 1000-row page. Falls back to paginating
      // the SETOF RPC on older DBs without the wrapper.
      final list = <Map<String, dynamic>>[];
      final params = {
        'p_schema': schema,
        'p_ins_id': insId,
        'p_from': d(_dailyFrom!),
        'p_to': d(_dailyTo!),
      };
      try {
        final agg = await SupabaseService.client.rpc('get_daily_collection_report_json', params: params);
        if (agg is List) list.addAll(List<Map<String, dynamic>>.from(agg));
      } catch (_) {
        const pageSize = 1000;
        int offset = 0;
        while (true) {
          final page = await SupabaseService.client
              .rpc('get_daily_collection_report', params: params)
              .range(offset, offset + pageSize - 1);
          final batch = page is List ? List<Map<String, dynamic>>.from(page) : <Map<String, dynamic>>[];
          list.addAll(batch);
          if (batch.length < pageSize) break;
          offset += pageSize;
        }
      }

      // Short codes for the export headers. Its own try/catch: a missing
      // feetype master must not fail the whole report, it just falls back to
      // the full descriptions.
      try {
        final ftRows = await SupabaseService.fromSchema('feetype')
            .select('feedesc, feeshort, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1);
        // Daily Collection can be the first tab a user opens, and the fee
        // GROUP map is built by the demand report. Without this the Fee Group
        // picker would be empty here until some other tab had been visited --
        // a filter that is sometimes there and sometimes not.
        if (_feeTypeGroup.isEmpty) {
          final g = await SupabaseService.getFeeTypeGroups(insId);
          if (g.isNotEmpty) {
            _feeTypeGroup = g;
            _feeIdGroup = await SupabaseService.getFeeIdGroups(insId);
            final k = await SupabaseService.getFeeKindMaps(insId);
            _feeIdToType = k.byId;
            _feeTypeNameToType = k.byName;
            if (_dcbTypeOptions.isEmpty) _dcbTypeOptions = k.codes;
            _feeGroups = g.values.expand((x) => x).toSet().toList()..sort();
          }
        }
        // Same trip, not a second one: the column order and the column
        // headings come from the same master and should never disagree.
        _feeOrder = {
          for (final r in (ftRows as List))
            if (r['feedesc'] != null)
              r['feedesc'].toString().trim().toUpperCase():
                  (r['ordid'] as num?)?.toInt() ?? 9999,
        };
        _feeShort = {
          for (final r in (ftRows as List))
            if (r['feedesc'] != null &&
                (r['feeshort']?.toString().trim().isNotEmpty ?? false))
              r['feedesc'].toString(): r['feeshort'].toString().trim(),
        };
      } catch (e) {
        debugPrint('feeshort lookup failed: $e');
      }

      final feeTypeSet = <String>{};
      final rows = <Map<String, dynamic>>[];
      /// Misc receipts still awaiting bank approval. Gathered alongside the
      /// day's rows below, then folded into the unreconciled section.
      final unrecList2 = <Map<String, dynamic>>[];

      // The unreconciled half — same columns, same shape, so it feeds the same
      // mapping below and lines up under the same fee-type columns. Its own
      // try/catch: an older DB without the RPC just shows no section rather
      // than failing the whole report.
      final unrecList = <Map<String, dynamic>>[];
      try {
        final agg = await SupabaseService.client
            .rpc('get_daily_collection_unreconciled_json', params: params);
        if (agg is List) unrecList.addAll(List<Map<String, dynamic>>.from(agg));
      } catch (e) {
        debugPrint('unreconciled collection RPC unavailable: $e');
      }

      Map<String, dynamic> mapRow(Map<String, dynamic> r) {
        final feesJson = r['fees_json'];
        final fees = <String, double>{};
        if (feesJson is Map) {
          feesJson.forEach((k, v) {
            final amt = (v as num?)?.toDouble() ?? 0;
            fees[k.toString()] = amt;
            feeTypeSet.add(k.toString());
          });
        }
        return {
          'paydate': r['paydate']?.toString() ?? '',
          'paynumber': r['paynumber']?.toString() ?? '',
          'stuadmno': r['stuadmno']?.toString() ?? '',
          'stuname': r['stuname']?.toString() ?? '',
          'courname': r['courname']?.toString() ?? '',
          'stuclass': r['stuclass']?.toString() ?? '',
          'semester': r['semester']?.toString() ?? '',
          'type': r['type']?.toString().isNotEmpty == true ? r['type'].toString() : 'Regular',
          'total': (r['total'] as num?)?.toDouble() ?? 0,
          'fine': (r['fine'] as num?)?.toDouble() ?? 0,
          'paymethod': r['paymethod']?.toString() ?? '',
          'createdby': r['createdby']?.toString() ?? '',
          'fees': fees,
        };
      }

      final unrecRows = [for (final r in unrecList) mapRow(r)]
        ..sort(_byDayThenReceipt);

      for (final r in list) {
        final feesJson = r['fees_json'];
        final fees = <String, double>{};
        if (feesJson is Map) {
          feesJson.forEach((k, v) {
            final amt = (v as num?)?.toDouble() ?? 0;
            fees[k.toString()] = amt;
            feeTypeSet.add(k.toString());
          });
        }
        rows.add({
          'paydate': r['paydate']?.toString() ?? '',
          'paynumber': r['paynumber']?.toString() ?? '',
          'stuadmno': r['stuadmno']?.toString() ?? '',
          'stuname': r['stuname']?.toString() ?? '',
          'courname': r['courname']?.toString() ?? '',
          'stuclass': r['stuclass']?.toString() ?? '',
          'semester': r['semester']?.toString() ?? '',
          'type': r['type']?.toString().isNotEmpty == true ? r['type'].toString() : 'Regular',
          'total': (r['total'] as num?)?.toDouble() ?? 0,
          'fine': (r['fine'] as num?)?.toDouble() ?? 0,
          'paymethod': r['paymethod']?.toString() ?? '',
          'createdby': r['createdby']?.toString() ?? '',
          'fees': fees,
        });
      }

      // Merge miscellaneous collections (BONAFIDE, APPLICATION, …) into the
      // report as 'Misc'-type receipts with their own fee-type breakdown.
      try {
        final mc = await SupabaseService.fromSchema('misc_collection')
            .select('mc_id, mcno, mcdate, regno, stuname, stuclass, courname, paymode, collectedby, totalamount, recon_status, activestatus, voidedby')
            .eq('ins_id', insId)
            // activestatus 9 = cancelled. Listed, not hidden: void_misc_receipt
            // leaves a hole in the receipt register (...3173, 3175) and that gap
            // is precisely what an auditor asks about. The row carries no money,
            // so no total moves -- the same treatment the cancelled fee receipts
            // and cancelled advances below already get.
            .inFilter('activestatus', [1, 9])
            .gte('mcdate', d(_dailyFrom!))
            .lte('mcdate', d(_dailyTo!));
        // A void always stamps voidedby. Anything else sitting at 9 was soft
        // deleted by an import and was never a receipt anyone took money on.
        final mcHeaders = List<Map<String, dynamic>>.from(mc as List)
            .where((h) =>
                ((h['activestatus'] as num?)?.toInt() ?? 1) != 9 ||
                (h['voidedby']?.toString() ?? '').trim().isNotEmpty)
            .toList();
        if (mcHeaders.isNotEmpty) {
          final ids = mcHeaders.map((h) => h['mc_id']).where((id) => id != null).toList();
          final det = await SupabaseService.fromSchema('misc_collection_detail')
              .select('mc_id, feetype, amount')
              .eq('activestatus', 1)
              .inFilter('mc_id', ids);
          final byMc = <dynamic, Map<String, double>>{};
          for (final dd in List<Map<String, dynamic>>.from(det as List)) {
            final ft = dd['feetype']?.toString() ?? 'Misc';
            final amt = (dd['amount'] as num?)?.toDouble() ?? 0;
            final m = byMc[dd['mc_id']] ??= <String, double>{};
            m[ft] = (m[ft] ?? 0) + amt;
            feeTypeSet.add(ft);
          }
          for (final h in mcHeaders) {
            final raw = h['mcdate']?.toString() ?? '';
            final cancelled = ((h['activestatus'] as num?)?.toInt() ?? 1) == 9;
            final amount =
                cancelled ? 0.0 : ((h['totalamount'] as num?)?.toDouble() ?? 0);
            // A misc receipt taken by UPI/bank is money the bank has not
            // confirmed yet, so it belongs in the unreconciled section with the
            // fee receipts rather than in the day's collected total. Rows from
            // a database without the recon columns read null -> treated as
            // reconciled, which is how they behaved before this existed. A
            // cancelled one is neither collected nor waiting on a bank: it goes
            // in the main list, at zero.
            final target = (!cancelled &&
                    (h['recon_status']?.toString() ?? 'R') == 'P')
                ? unrecList2
                : rows;
            target.add({
              'paydate': raw.length >= 10 ? raw.substring(0, 10) : raw,
              'paynumber': h['mcno']?.toString() ?? '',
              'stuadmno': h['regno']?.toString() ?? '',
              'stuname': h['stuname']?.toString() ?? '',
              'courname': h['courname']?.toString() ?? '',
              'stuclass': h['stuclass']?.toString() ?? '',
              'semester': '',
              'type': cancelled ? 'Cancelled' : 'Misc',
              'total': amount,
              'fine': 0.0,
              'paymethod': h['paymode']?.toString() ?? '',
              'createdby': h['collectedby']?.toString() ?? '',
              // The void takes the detail lines to activestatus 9 with the
              // header, so a cancelled receipt cannot reappear in a fee-type
              // column. Forced empty regardless, so it cannot on any database.
              'fees': cancelled
                  ? <String, double>{}
                  : (byMc[h['mc_id']] ?? <String, double>{}),
            });
          }
        }
      } catch (e) {
        debugPrint('daily collection misc merge error: $e');
      }

      // Merge ADVANCE collections. This is money over the counter on the day it
      // was taken, so it belongs in the day's collection exactly as a misc
      // receipt does. An ADMISSION advance carries its fee-type breakdown; a
      // STUDENT advance is a single amount and gets one 'ADVANCE' column.
      //
      // The matching 'Advance Adjustment' receipts are EXCLUDED further up (see
      // the paymethod filter): they settle a demand with money already counted
      // here on an earlier day, so counting them again would double the total.
      try {
        final ac = await SupabaseService.fromSchema('advance_collection')
            .select('adv_id, advno, advdate, advtype, stuadmno, stuname, stuclass, courname, '
                'paymethod, createdby, transtotalamount, recon_status, activestatus')
            .eq('ins_id', insId)
            // activestatus 9 = cancelled. Listed, not hidden: a receipt that
            // simply disappears from a day already printed is exactly what an
            // auditor asks about, and it is how the other cancelled receipts
            // are treated.
            .inFilter('activestatus', [1, 9])
            .inFilter('paystatus', ['C', 'R'])
            // advdate is a timestamp: the upper bound must be the next day,
            // exclusive, or everything after midnight on the last day is lost.
            .gte('advdate', d(_dailyFrom!))
            .lt('advdate', d(_dailyTo!.add(const Duration(days: 1))));
        final advHeaders = List<Map<String, dynamic>>.from(ac as List);
        if (advHeaders.isNotEmpty) {
          final ids = advHeaders.map((h) => h['adv_id']).where((id) => id != null).toList();
          final byAdv = <dynamic, Map<String, double>>{};
          try {
            final det = await SupabaseService.fromSchema('advance_detail')
                .select('adv_id, feetype, amount')
                .eq('activestatus', 1)
                .inFilter('adv_id', ids);
            for (final dd in List<Map<String, dynamic>>.from(det as List)) {
              final ft = dd['feetype']?.toString() ?? 'ADVANCE';
              final amt = (dd['amount'] as num?)?.toDouble() ?? 0;
              final m = byAdv[dd['adv_id']] ??= <String, double>{};
              m[ft] = (m[ft] ?? 0) + amt;
              feeTypeSet.add(ft);
            }
          } catch (_) {
            // No advance_detail table yet — student advances have no breakdown
            // anyway, so fall through to the single ADVANCE column below.
          }
          for (final h in advHeaders) {
            final raw = h['advdate']?.toString() ?? '';
            final cancelled = ((h['activestatus'] as num?)?.toInt() ?? 1) == 9;
            final amount =
                cancelled ? 0.0 : ((h['transtotalamount'] as num?)?.toDouble() ?? 0);
            var fees = byAdv[h['adv_id']];
            if (fees == null || fees.isEmpty) {
              // A student advance, or an admission advance whose breakdown could
              // not be read: one column so the row still totals correctly.
              fees = {'ADVANCE': amount};
              feeTypeSet.add('ADVANCE');
            }
            // A cancelled advance took no money, so it carries no breakdown
            // either -- same treatment a cancelled fee receipt gets.
            if (cancelled) fees = <String, double>{};
            // Cash is realised on the spot; a cheque/UPI advance waits for the
            // bank and belongs with the other unreconciled receipts. A
            // cancelled one is neither: it goes in the main list, at zero.
            final target = (!cancelled &&
                    (h['recon_status']?.toString() ?? 'R') == 'P')
                ? unrecList2
                : rows;
            target.add({
              'paydate': raw.length >= 10 ? raw.substring(0, 10) : raw,
              'paynumber': h['advno']?.toString() ?? '',
              'stuadmno': h['stuadmno']?.toString() ?? '',
              'stuname': h['stuname']?.toString() ?? '',
              'courname': h['courname']?.toString() ?? '',
              'stuclass': h['stuclass']?.toString() ?? '',
              'semester': '',
              'type': cancelled
                  ? 'Cancelled'
                  : switch ((h['advtype']?.toString() ?? 'S').toUpperCase()) {
                      'A' => 'Advance (Admission)',
                      // Banked into the hostel account, not the college one,
                      // so it has to be countable on its own in this report.
                      'M' => 'Advance (Mess)',
                      _ => 'Advance',
                    },
              'total': amount,
              'fine': 0.0,
              'paymethod': h['paymethod']?.toString() ?? '',
              'createdby': h['createdby']?.toString() ?? '',
              'fees': fees,
            });
          }
        }
      } catch (e) {
        // The table may not exist on this database yet — the report must still
        // render everything else.
        debugPrint('daily collection advance merge error: $e');
      }

      // ---- mark what was settled from an ADVANCE -----------------------
      // That money was counted as collection on the day the advance was TAKEN
      // (the advance rows merged above), so it must not be counted again as
      // money received today. It is held in its own ADJUSTED column instead of
      // being subtracted from the figures:
      //
      //     TOTAL     = the whole settlement, fee-type columns and all
      //     ADJUSTED  = the part that came off an advance
      //     NET AMT   = TOTAL - ADJUSTED, the money that changed hands
      //
      // so the day's cash still tallies while the statement keeps showing WHAT
      // was settled. Deducting it instead left a receipt paid entirely from an
      // advance printing as a bare receipt number with every column empty.
      //
      // Keyed on paynumber, not paymethod='Advance Adjustment': that test only
      // ever caught an advance covering a whole bill, and missed every
      // adjustment riding on the cashier's own receipt.
      try {
        final adj = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('advadjustment')
            .select('paynumber, demfeetype, adjustamount')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .gte('adjustdate', d(_dailyFrom!))
            .lte('adjustdate', d(_dailyTo!)));
        final adjTotal = <String, double>{};
        for (final r in adj) {
          final no = r['paynumber']?.toString() ?? '';
          if (no.isEmpty) continue;
          adjTotal[no] =
              (adjTotal[no] ?? 0) + ((r['adjustamount'] as num?)?.toDouble() ?? 0);
        }
        if (adjTotal.isNotEmpty) {
          void net(List<Map<String, dynamic>> target) {
            for (final row in target) {
              final no = row['paynumber']?.toString() ?? '';
              final off = adjTotal[no];
              if (off == null || off <= 0) continue;
              // Kept on the row for the ADJUSTED column. Without it the money
              // simply disappeared between the fee columns and the total, and
              // a receipt settled entirely from an advance listed as a blank
              // line with nothing to explain it.
              row['adjusted'] = ((row['adjusted'] as num?)?.toDouble() ?? 0) + off;
              // total and the fee-type columns stay as they are: they say what
              // the receipt SETTLED. Only the money columns come down, and they
              // do it by subtracting ADJUSTED rather than by rewriting this.
              if (((row['total'] as num?)?.toDouble() ?? 0) - off <= 0.005) {
                // Nothing came in for it today. Still LISTED — a cashier
                // looking for the receipt must find it — and flagged, so the
                // Type column explains a Net Amt of zero.
                row['type'] = 'Advance Adjusted';
              }
            }
          }

          net(rows);
          net(unrecList2);
          net(unrecRows);
        }
      } catch (e) {
        debugPrint('daily collection advance netting error: $e');
      }

      // Merge CANCELLED (voided) receipts so they're LISTED for audit, marked
      // 'Cancelled' with NO paid amount (empty fee columns, total 0 — they don't
      // affect the day's totals). A voided receipt is activestatus=9,
      // paystatus='R', with voidedby set (a fee-refund keeps activestatus=1, so
      // this doesn't pick those up). Keyed on the original paydate like every
      // other row.
      try {
        final voided = await SupabaseService.fromSchema('payment')
            .select('pay_id, paynumber, paydate, paymethod, stu_id, createdby, voidedby')
            .eq('ins_id', insId)
            .eq('activestatus', 9)
            .eq('paystatus', 'R')
            .gte('paydate', d(_dailyFrom!))
            .lte('paydate', '${d(_dailyTo!)}T23:59:59');
        final vrows = List<Map<String, dynamic>>.from(voided as List)
            .where((v) => (v['voidedby']?.toString() ?? '').trim().isNotEmpty)
            .toList();
        if (vrows.isNotEmpty) {
          final stuIds = vrows.map((v) => v['stu_id']).where((e) => e != null).toSet().toList();
          final stuMap = <dynamic, Map<String, dynamic>>{};
          if (stuIds.isNotEmpty) {
            final studs = await SupabaseService.fromSchema('students')
                .select('stu_id, stuadmno, stuname, stuclass, courname')
                .inFilter('stu_id', stuIds);
            for (final s in List<Map<String, dynamic>>.from(studs as List)) {
              stuMap[s['stu_id']] = s;
            }
          }
          for (final v in vrows) {
            final s = stuMap[v['stu_id']] ?? const {};
            final raw = v['paydate']?.toString() ?? '';
            rows.add({
              'paydate': raw.length >= 10 ? raw.substring(0, 10) : raw,
              'paynumber': v['paynumber']?.toString() ?? '',
              'stuadmno': s['stuadmno']?.toString() ?? '',
              'stuname': s['stuname']?.toString() ?? '',
              'courname': s['courname']?.toString() ?? '',
              'stuclass': s['stuclass']?.toString() ?? '',
              'semester': '',
              'type': 'Cancelled',
              'total': 0.0,
              'fine': 0.0,
              'paymethod': v['paymethod']?.toString() ?? '',
              'createdby': v['createdby']?.toString() ?? '',
              'fees': <String, double>{},
            });
          }
        }
      } catch (e) {
        debugPrint('daily collection cancelled merge error: $e');
      }

      // Merge REFUNDED receipts: fee_refund vouchers raised in the range (keyed
      // on refunddate). Shown as 'Refunded' rows with a NEGATIVE amount so the
      // Total column and the grand-total summary net them out of collections.
      try {
        final refs = await SupabaseService.fromSchema('fee_refund')
            .select('rf_id, refunddate, paynumber, stu_id, stuadmno, stuname, stuclass, refundmode, totalrefund, createdby')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .gte('refunddate', d(_dailyFrom!))
            .lte('refunddate', d(_dailyTo!));
        final rrows = List<Map<String, dynamic>>.from(refs as List);
        if (rrows.isNotEmpty) {
          final rStuIds = rrows.map((v) => v['stu_id']).where((e) => e != null).toSet().toList();
          final rStuMap = <dynamic, Map<String, dynamic>>{};
          if (rStuIds.isNotEmpty) {
            final studs = await SupabaseService.fromSchema('students')
                .select('stu_id, stuadmno, stuname, stuclass, courname')
                .inFilter('stu_id', rStuIds);
            for (final s in List<Map<String, dynamic>>.from(studs as List)) {
              rStuMap[s['stu_id']] = s;
            }
          }
          String pick(String? a, String? b) =>
              (a != null && a.trim().isNotEmpty) ? a.trim() : (b?.toString() ?? '');
          for (final v in rrows) {
            final s = rStuMap[v['stu_id']] ?? const {};
            final raw = v['refunddate']?.toString() ?? '';
            rows.add({
              'paydate': raw.length >= 10 ? raw.substring(0, 10) : raw,
              'paynumber': v['paynumber']?.toString() ?? '',
              'stuadmno': pick(v['stuadmno']?.toString(), s['stuadmno']?.toString()),
              'stuname': pick(v['stuname']?.toString(), s['stuname']?.toString()),
              'courname': s['courname']?.toString() ?? '',
              'stuclass': pick(v['stuclass']?.toString(), s['stuclass']?.toString()),
              'semester': '',
              'type': 'Refunded',
              'total': 0.0,
              'refund': (v['totalrefund'] as num?)?.toDouble() ?? 0,
              'fine': 0.0,
              'paymethod': v['refundmode']?.toString() ?? '',
              'createdby': v['createdby']?.toString() ?? '',
              'fees': <String, double>{},
            });
          }
        }
      } catch (e) {
        debugPrint('daily collection refund merge error: $e');
      }

      // Day, then receipt number: cancelled and misc rows fall in with their
      // day AND in receipt order, so the table reads as a receipt book.
      rows.sort(_byDayThenReceipt);

      if (mounted) {
        setState(() {
          _dailyRows = rows;
          _dailyUnrecRows = [...unrecRows, ...unrecList2]..sort(_byDayThenReceipt);
          _dailyFeeTypes = feeTypeSet.toList()..sort(feeTypeOrdidComparator(_feeOrder));
          _dailyLoading = false;
        });
      }
    } catch (e) {
      debugPrint('daily collection load error: $e');
      if (mounted) {
        setState(() {
          _dailyLoading = false;
          // A timeout is the common one and has a specific remedy, so say it
          // rather than dumping the Postgres text at the office.
          _dailyError = e.toString().contains('57014') ||
                  e.toString().toLowerCase().contains('statement timeout')
              ? 'The report took too long to build for this date range.\n'
                  'Try a shorter range, then Refresh.'
              : 'Could not load the report. ${friendlyError(e)}';
        });
      }
    }
  }

  /// Does this fee type pass BOTH the Fee Group and Fee Type filters?
  ///
  /// One place, because the two filters have to agree and because every
  /// report that narrows by fee type must narrow by group the same way --
  /// a column the table hides but the total still counts is worse than no
  /// filter at all.
  ///
  /// A fee type with no live group is shown when no group is picked and
  /// hidden when one is. That is the honest reading: it is not in the group
  /// you asked for.
  /// The fee TYPE half alone. Pending Details gets its GROUP filter from the
  /// RPC now, so filtering by group again here would be a second, differently
  /// worded copy of the same rule -- which is how the three reports came to
  /// disagree in the first place.
  bool _feeTypeSelected(String feetype) =>
      _selectedFeeTypes.isEmpty || _selectedFeeTypes.contains(feetype);

  bool _feeTypeAllowed(String feetype, {int? feeId}) =>
      _inSelectedGroups(feetype, feeId: feeId) && _feeTypeSelected(feetype);

  /// The GROUP half of the test on its own.
  ///
  /// Separate because the Fee Type picker needs it: its list has to be
  /// narrowed to the chosen groups, but narrowing it by the fee-type
  /// selection as well would be circular -- the picker would only ever offer
  /// what was already ticked.
  bool _inSelectedGroups(String feetype, {int? feeId}) {
    if (_selectedFeeGroups.isEmpty) return true;
    // fee_id first: it names exactly one feetype row, so a description that
    // exists under two groups is resolved rather than counted under both.
    if (feeId != null) {
      final exact = _feeIdGroup[feeId];
      if (exact != null) return _selectedFeeGroups.contains(exact);
    }
    // Falling back to the description. Only reached where the report row has
    // no fee_id -- Daily Collection keys its fee map by name -- and there a
    // shared description belongs to every group that uses it, so the fee is
    // shown under either filter rather than disappearing from one.
    final g = _feeTypeGroup[feetype.trim().toUpperCase()];
    return g != null && g.any(_selectedFeeGroups.contains);
  }

  /// True while either fee filter is narrowing the report.
  bool get _feeFilterActive =>
      _selectedFeeGroups.isNotEmpty || _selectedFeeTypes.isNotEmpty;

  /// The Daily Collection filter bar, as one predicate. Shared so the
  /// unreconciled section below the table narrows with the same filters —
  /// a section that ignored them would contradict the table above it.
  bool _dailyRowVisible(Map<String, dynamic> r) {
      if (_selectedCourse != null && r['courname']?.toString() != _selectedCourse) return false;
      if (_selectedClasses.isNotEmpty && !_selectedClasses.contains(r['stuclass']?.toString())) return false;
      if (_feeFilterActive) {
        final fees = r['fees'] as Map<String, double>;
        // A receipt stays only if it carries money against a fee the filters
        // still allow -- otherwise a COLLEGE FEES receipt would survive a
        // HOSTEL FEES filter showing nothing but a row of dashes.
        if (!fees.entries
            .any((e) => e.value > 0 && _feeTypeAllowed(e.key))) return false;
      }
      if (_selectedMode != null) {
        final isCash = _isCashMode(r['paymethod']?.toString() ?? '');
        if (_selectedMode == 'cash' && !isCash) return false;
        if (_selectedMode == 'bank' && isCash) return false;
      }
      if (_selectedPrefixes.isNotEmpty) {
        final p = _prefixOf(r['paynumber']?.toString() ?? '');
        if (!_selectedPrefixes.contains(p)) return false;
      }
      if (_selectedDailyTypes.isNotEmpty && !_selectedDailyTypes.contains(r['type']?.toString() ?? 'Regular')) return false;
      if (_selectedUser != null && r['createdby']?.toString() != _selectedUser) return false;
      return true;
  }

  /// True when this demand's student passes the TC filter.
  ///
  /// stuactive is students.activestatus, carried by get_fee_report_data. A
  /// server that predates it returns nothing, which reads as active -- so an
  /// un-migrated database behaves exactly as it did before.
  bool _tcMatches(Map<String, dynamic> d) {
    final active = ((d['stuactive'] as num?)?.toInt() ?? 1) == 1;
    switch (_tcFilter) {
      case 'TC':
        return !active;
      case 'ALL':
        return true;
      default:
        return active;
    }
  }

  List<Map<String, dynamic>> get _filteredDemands {
    return _allDemands.where((d) {
      if (!_tcMatches(d)) return false;
      if (_selectedCourse != null && d['courname']?.toString() != _selectedCourse) return false;
      if (_selectedClasses.isNotEmpty && !_selectedClasses.contains(d['stuclass']?.toString())) return false;
      if (_feeFilterActive &&
          !_feeTypeAllowed(d['demfeetype']?.toString() ?? '',
              feeId: (d['fee_id'] as num?)?.toInt())) return false;
      return true;
    }).toList();
  }

  // Get dynamic term columns from actual data
  List<String> _getTermColumns(List<Map<String, dynamic>> demands) {
    final terms = <String>{};
    for (final d in demands) {
      final t = d['demfeeterm']?.toString() ?? '';
      if (t.isNotEmpty) terms.add(t);
    }
    final sorted = terms.toList()..sort((a, b) => _termIndex(a).compareTo(_termIndex(b)));
    return sorted;
  }

  // Build student-wise pivot data with total and remarks
  // showPending=true uses reconbalancedue (reconciled pending), showPending=false uses feeamount (demanded)
  List<Map<String, dynamic>> _buildPivotData(List<Map<String, dynamic>> demands, List<String> terms, {required bool showPending}) {
    final Map<String, Map<String, dynamic>> studentMap = {};
    final Map<String, Set<String>> studentRemarks = {};
    for (final d in demands) {
      final admNo = d['stuadmno']?.toString() ?? '';
      if (admNo.isEmpty) continue;
      final term = d['demfeeterm']?.toString() ?? '';
      final feeType = d['demfeetype']?.toString() ?? '';
      final amount = showPending
          ? (d['reconbalancedue'] as num?)?.toDouble() ?? (d['balancedue'] as num?)?.toDouble() ?? 0
          : (d['feeamount'] as num?)?.toDouble() ?? 0;

      studentMap.putIfAbsent(admNo, () => {
        'stuadmno': admNo,
        'stuname': d['stuname']?.toString() ?? d['stuadmno']?.toString() ?? '',
        'courname': d['courname']?.toString() ?? '',
        'stuclass': d['stuclass']?.toString() ?? '',
      });

      if (term.isNotEmpty) {
        studentMap[admNo]![term] = (studentMap[admNo]![term] as double? ?? 0) + amount;
      }

      // Accumulate fine from the fineamount column
      final fine = (d['fineamount'] as num?)?.toDouble() ?? 0;
      studentMap[admNo]!['_fine'] = ((studentMap[admNo]!['_fine'] as double?) ?? 0) + fine;

      // Collect fee type remarks for pending amounts
      if (amount > 0 && feeType.isNotEmpty) {
        studentRemarks.putIfAbsent(admNo, () => <String>{}).add(feeType);
      }
    }

    // Calculate total and add remarks
    for (final entry in studentMap.entries) {
      double total = 0;
      for (final t in terms) {
        total += (entry.value[t] as double?) ?? 0;
      }
      entry.value['_total'] = total;
      entry.value['_remarks'] = (studentRemarks[entry.key] ?? {}).join(', ');
    }

    final list = studentMap.values.toList();
    list.sort((a, b) => (a['stuadmno'] as String).compareTo(b['stuadmno'] as String));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tabs (pill style) — hidden when each report is its own sidebar submenu.
        if (widget.showTabBar)
        ListenableBuilder(
          listenable: _tabController,
          builder: (context, _) {
            final selected = _tabController.index;
            final tabLabels = ['Daily Collection', 'Student Ledger', 'Pending Payment', 'Pending Details', 'Consolidated Status', 'DCB Register', 'Advance Register'];
            final tabIcons = ['calendar-1', 'book-1', 'clock', 'receipt-item', 'chart-2', 'grid-1', 'wallet-money'];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < tabLabels.length; i++) ...[
                      PillTab(
                        icon: tabIcons[i],
                        label: tabLabels[i],
                        selected: selected == i,
                        onTap: () => _tabController.animateTo(i),
                      ),
                      if (i < tabLabels.length - 1) SizedBox(width: PillTab.gap(context)),
                    ],
                    const SizedBox(width: 16),
                    if (_loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        // Filters (wrapped in one card)
        ListenableBuilder(listenable: _tabController, builder: (_, __) => _buildFilters()),
        // Content (white table area)
        Expanded(
          child: Container(
            decoration: AppCard.decoration(),
            clipBehavior: Clip.antiAlias,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? AppUI.empty(title: 'Could not load the report', why: '$_error')
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildDailyCollection(),
                          _buildStudentLedger(),
                          _buildPendingPayment(),
                          ListenableBuilder(
                            listenable: _tabController,
                            builder: (_, __) => _buildPendingDetails(),
                          ),
                          _buildConsolidatedStatus(),
                          _buildDcbRegister(),
                          _buildAdvanceRegister(),
                        ],
                      ),
          ),
        ),
      ],
    );
  }

  // Styled like the "All Methods" dropdown on Fee Collection: white pill,
  // border, just text + chevron (no leading icon), responsive at <=1366.
  /// Multi-select checkbox dropdown for fee types. Same visual shell as
  /// _filterDropdown so it lines up with the other Daily Collection filters.
  /// Empty selection = "All Fee Types".
  Widget _feeTypeMultiSelect({
    required double width,
    bool enabled = true,
    String? disabledTip,
  }) =>
      _multiSelectTrigger(
        width: width,
        anchor: _feeTypeKey,
        selected: _selectedFeeTypes,
        emptyLabel: 'All Fee Types',
        pluralNoun: 'fee types',
        onTap: _openFeeTypePicker,
        enabled: enabled,
        disabledTip: disabledTip,
      );

  /// The Fee Group filter. Same shell, same behaviour -- it narrows a report
  /// to the fees that bank into one account, which is how the accounts are
  /// kept. Hidden entirely when the institution has one fee group, because a
  /// filter with a single option only takes up room.
  Widget _feeGroupMultiSelect({required double width}) {
    if (_feeGroups.length < 2) return const SizedBox.shrink();
    return _multiSelectTrigger(
      width: width,
      anchor: _feeGroupKey,
      selected: _selectedFeeGroups,
      emptyLabel: 'All Fee Groups',
      pluralNoun: 'fee groups',
      onTap: _openFeeGroupPicker,
    );
  }

  Widget _multiSelectTrigger({
    required double width,
    required GlobalKey anchor,
    required Set<String> selected,
    required String emptyLabel,
    required String pluralNoun,
    required VoidCallback onTap,
    /// False locks the control. Daily Collection's fee-level filters hang off
    /// the Fee Group, and a picker that opens onto every fee type in the
    /// college while the group that decides them is still unset is worse than
    /// one that plainly cannot be opened yet.
    bool enabled = true,
    String? disabledTip,
  }) {
    // Render through the SAME InputDecorator frame + decoration that
    // _filterDropdown uses (AppUI.field), so the height/padding/border are
    // identical to the other filter dropdowns (this is just a tappable
    // multi-select).
    final selectedCount = selected.length;
    final filled = enabled && selectedCount > 0;
    final label = selectedCount == 0
        ? emptyLabel
        : selectedCount == 1
            ? selected.first
            : '$selectedCount $pluralNoun';
    final Widget shell = SizedBox(
      key: anchor,
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: enabled ? onTap : null,
        child: InputDecorator(
          isEmpty: false,
          decoration: AppUI.field(context, '', filled: filled).copyWith(
            enabled: enabled,
            fillColor: enabled ? Colors.white : AppColors.tableHeadBg,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  // Placeholder ("All Fee Types") = w500; selected value = accent.
                  style: !enabled
                      ? AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)
                      : filled
                          ? AppUI.fieldText(context, filled: true)
                          : AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.arrow_drop_down,
                  color: enabled
                      ? AppColors.textSecondary
                      : AppColors.textSecondary.withValues(alpha: 0.45)),
            ],
          ),
        ),
      ),
    );
    // The reason it is locked has to be readable, or a greyed control is just
    // a broken one.
    if (!enabled && disabledTip != null) {
      return Tooltip(message: disabledTip, child: shell);
    }
    return shell;
  }

  Future<void> _openFeeTypePicker() => _openMultiPicker(
        anchor: _feeTypeKey,
        // Union of the demand fee types and whatever the loaded Daily
        // Collection range contains, in the SAME order as the columns --
        // then narrowed to the chosen fee groups. Offering COLLEGE FEES types
        // while HOSTEL FEES is selected invites a pair of filters that
        // between them match nothing, with no hint as to why.
        options: <String>{..._feeTypes, ..._dailyFeeTypes}
            .where(_inSelectedGroups)
            .toList()
          ..sort(feeTypeOrdidComparator(_feeOrder)),
        current: _selectedFeeTypes,
        apply: (v) {
          setState(() => _selectedFeeTypes = v);
          _refreshAfterFeeFilter();
        },
      );

  Future<void> _openFeeGroupPicker() => _openMultiPicker(
        anchor: _feeGroupKey,
        options: _feeGroups,
        current: _selectedFeeGroups,
        apply: (v) {
          setState(() {
          _selectedFeeGroups = v;
          // Drop any fee type that is no longer in the chosen groups.
          // Without this, switching from COLLEGE FEES to HOSTEL FEES leaves
          // TUITION FEE ticked in a filter that can no longer see it, and the
          // report goes empty for a reason nothing on screen explains.
          _selectedFeeTypes =
              _selectedFeeTypes.where(_inSelectedGroups).toSet();
          // Same for the DCB Type filter: a type the new group has none of
          // would leave the register empty with nothing on screen saying why.
          final stillValid = _dcbTypeOptionsForGroup.toSet();
          _selectedFeeKinds = _selectedFeeKinds.where(stillValid.contains).toSet();
          // Daily Collection's Prefix and Type hang off the group too. Pruned
          // against the NEW group -- and cleared outright when the group is
          // cleared, because the controls lock again and a lock holding an
          // invisible selection would filter the report with nothing on
          // screen saying so.
          if (v.isEmpty) {
            // _dcbTypeOptionsForGroup offers everything when no group is set,
            // so the prune above cannot catch this one -- without it the DCB
            // Register would go on filtering by a kind nobody can see.
            _selectedFeeKinds = <String>{};
            _selectedPrefixes = <String>{};
            _selectedDailyTypes = <String>{};
          } else {
            final prefixes = _dailyPrefixes().toSet();
            _selectedPrefixes =
                _selectedPrefixes.where(prefixes.contains).toSet();
            final types = _dailyTypeOptions().toSet();
            _selectedDailyTypes =
                _selectedDailyTypes.where(types.contains).toSet();
          }
        });
          _refreshAfterFeeFilter();
        },
      );

  /// Pending Details builds its rows ONCE and caches them, so a fee filter
  /// changed while that tab is open would not redraw -- the picker would
  /// close and nothing would happen. Every other report filters at draw time
  /// and needs no help.
  void _refreshAfterFeeFilter() {
    switch (_tabController.index) {
      case _kPendingDetailsTab:
        _loadPendingDetails(force: true);
        break;
      case 2: // Pending Payment
      case 4: // Consolidated Status
        // Filtered by the SERVER, so a change has to be fetched again rather
        // than merely redrawn -- the same rule the TC filter already follows.
        _pendingMetaLoaded = false;
        _loadPendingMeta(force: true);
        break;
    }
  }

  Future<void> _openMultiPicker({
    required GlobalKey anchor,
    required List<String> options,
    required Set<String> current,
    required void Function(Set<String>) apply,
  }) async {
    final renderBox = anchor.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final triggerPos = renderBox.localToGlobal(Offset.zero);
    final triggerSize = renderBox.size;
    final screen = MediaQuery.of(context).size;

    const popupWidth = 280.0;
    const popupMaxHeight = 360.0;
    // Anchor: left-aligned to trigger, just below it. Clamp to screen.
    final left = triggerPos.dx
        .clamp(8.0, (screen.width - popupWidth - 8).clamp(8.0, screen.width));
    final top = (triggerPos.dy + triggerSize.height + 4)
        .clamp(8.0, (screen.height - 100).clamp(8.0, screen.height));

    final tempSelected = Set<String>.from(current);
    // Outside the StatefulBuilder: one created inside it would be rebuilt on
    // every keystroke and lose the caret.
    final searchCtrl = TextEditingController();
    final result = await showDialog<Set<String>>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(ctx),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: popupWidth,
            child: StatefulBuilder(builder: (ctx, setLocalState) {
              final q = searchCtrl.text.trim().toUpperCase();
              final visible = q.isEmpty
                  ? options
                  : options.where((f) => f.toUpperCase().contains(q)).toList();
              return Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: popupMaxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('Select Fee Types', style: AppUI.label),
                            ),
                            // Both act on what is VISIBLE. With no search that
                            // is the whole list, so the old behaviour is
                            // unchanged; with one, "Select All" means "all the
                            // ones I just searched for", which is the only
                            // reading that makes sense beside a filtered list.
                            InkWell(
                              onTap: () =>
                                  setLocalState(() => tempSelected.addAll(visible)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Select All',
                                    style: AppUI.label.copyWith(color: AppColors.primary)),
                              ),
                            ),
                            InkWell(
                              onTap: () => setLocalState(
                                  () => tempSelected.removeAll(visible)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Clear',
                                    style: AppUI.label.copyWith(color: AppColors.primary)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: TextField(
                          controller: searchCtrl,
                          autofocus: true,
                          style: AppUI.fieldText(ctx),
                          onChanged: (_) => setLocalState(() {}),
                          decoration: AppUI.field(
                            ctx,
                            'Search fee type',
                            dense: true,
                            leadingIcon: 'search-normal',
                            suffix: q.isEmpty
                                ? null
                                : InkWell(
                                    onTap: () => setLocalState(searchCtrl.clear),
                                    child: const Icon(Icons.close, size: 15),
                                  ),
                          ).copyWith(
                            suffixIconConstraints:
                                const BoxConstraints(minWidth: 28, minHeight: 28),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      if (visible.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: Text('No fee type matches',
                              textAlign: TextAlign.center,
                              style: AppUI.muted),
                        ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: visible
                              .map((ft) => CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    controlAffinity: ListTileControlAffinity.leading,
                                    value: tempSelected.contains(ft),
                                    title: Text(ft, style: AppUI.body),
                                    onChanged: (v) => setLocalState(() {
                                      if (v == true) {
                                        tempSelected.add(ft);
                                      } else {
                                        tempSelected.remove(ft);
                                      }
                                    }),
                                  ))
                              .toList(),
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(ctx, tempSelected),
                              child: const Text('Apply'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
    if (result != null) apply(result);
  }

  /// Generic checkbox multi-select trigger — same frame/height as the other
  /// filter dropdowns. Used for the Pending Payment Admn Type / Quota filters.
  Widget _checkMultiSelect({
    required GlobalKey anchorKey,
    required double width,
    required String allLabel,
    required String pluralNoun,
    required Set<String> selected,
    required VoidCallback onTap,
    /// Display form of a single selected value, so a chip can read
    /// "TRA  Transport" while still holding 'TRA'.
    String Function(String)? labelOf,
    /// See _multiSelectTrigger -- same contract, same reason.
    bool enabled = true,
    String? disabledTip,
  }) {
    final count = selected.length;
    final filled = enabled && count > 0;
    final label = count == 0
        ? allLabel
        : count == 1
            ? (labelOf?.call(selected.first) ?? selected.first)
            : '$count $pluralNoun';
    final Widget shell = SizedBox(
      key: anchorKey,
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: enabled ? onTap : null,
        child: InputDecorator(
          isEmpty: false,
          decoration: AppUI.field(context, '', filled: filled).copyWith(
            enabled: enabled,
            fillColor: enabled ? Colors.white : AppColors.tableHeadBg,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: !enabled
                      ? AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)
                      : filled
                          ? AppUI.fieldText(context, filled: true)
                          : AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.arrow_drop_down,
                  color: enabled
                      ? AppColors.textSecondary
                      : AppColors.textSecondary.withValues(alpha: 0.45)),
            ],
          ),
        ),
      ),
    );
    if (!enabled && disabledTip != null) {
      return Tooltip(message: disabledTip, child: shell);
    }
    return shell;
  }

  /// Popup checkbox list anchored under [anchorKey]; Select All / Clear /
  /// Cancel / Apply. Returns the chosen set via [onApply].
  Future<void> _openCheckPicker({
    required GlobalKey anchorKey,
    required String title,
    required List<String> options,
    required Set<String> current,
    required void Function(Set<String>) onApply,
    /// How to DISPLAY an option. The value selected and stored is still the
    /// option itself -- only the text changes -- so a list of codes can read
    /// as words without anything downstream having to know.
    String Function(String)? labelOf,
  }) async {
    final renderBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final triggerPos = renderBox.localToGlobal(Offset.zero);
    final triggerSize = renderBox.size;
    final screen = MediaQuery.of(context).size;

    const popupWidth = 280.0;
    const popupMaxHeight = 360.0;
    final left = triggerPos.dx.clamp(8.0, (screen.width - popupWidth - 8).clamp(8.0, screen.width));
    final top = (triggerPos.dy + triggerSize.height + 4).clamp(8.0, (screen.height - 100).clamp(8.0, screen.height));

    final tempSelected = Set<String>.from(current);
    final result = await showDialog<Set<String>>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(ctx),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: popupWidth,
            child: StatefulBuilder(builder: (ctx, setLocalState) {
              return Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: popupMaxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(title, style: AppUI.label),
                            ),
                            InkWell(
                              onTap: () => setLocalState(() => tempSelected
                                ..clear()
                                ..addAll(options)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Select All', style: AppUI.label.copyWith(color: AppColors.primary)),
                              ),
                            ),
                            InkWell(
                              onTap: () => setLocalState(tempSelected.clear),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Clear', style: AppUI.label.copyWith(color: AppColors.primary)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Flexible(
                        child: options.isEmpty
                            ? Padding(padding: const EdgeInsets.all(16), child: Text('No options', style: AppUI.muted))
                            : ListView(
                                shrinkWrap: true,
                                padding: EdgeInsets.zero,
                                children: options
                                    .map((o) => CheckboxListTile(
                                          dense: true,
                                          visualDensity: VisualDensity.compact,
                                          controlAffinity: ListTileControlAffinity.leading,
                                          value: tempSelected.contains(o),
                                          title: Text(labelOf?.call(o) ?? o,
                                              style: AppUI.body),
                                          onChanged: (v) => setLocalState(() {
                                            if (v == true) {
                                              tempSelected.add(o);
                                            } else {
                                              tempSelected.remove(o);
                                            }
                                          }),
                                        ))
                                    .toList(),
                              ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                            ElevatedButton(onPressed: () => Navigator.pop(ctx, tempSelected), child: const Text('Apply')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
    if (result != null) onApply(result);
  }

  Widget _filterDropdown<T>({
    required T value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    required double width,
    Key? key,
  }) {
    // Filled = a specific value is selected (not the "All"/null default).
    final filled = value != null;
    // Frame matches the Fee Master filter dropdowns: AppUI.field.
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<T>(
        key: key,
        value: value,
        isExpanded: true,
        icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        menuMaxHeight: 320,
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, hint, filled: filled),
        items: items,
        // Filled value reads bold + accent, distinct from the muted placeholder. Mirrors items 1:1.
        selectedItemBuilder: (context) => items.map((m) => Align(alignment: Alignment.centerLeft, child: Text(m.child is Text ? ((m.child as Text).data ?? '') : '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: filled)))).toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: AppCard.decoration(),
        child: Row(
          children: [
            // Scrollable filters (left)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // Course filter
          _filterDropdown<String?>(
            value: _selectedCourse,
            hint: schoolTerm('All Courses'),
            width: 160.w,
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(schoolTerm('All Courses'))),
              ..._courses.map((c) => DropdownMenuItem(value: c, child: Text(c))),
            ],
            onChanged: (v) => setState(() { _selectedCourse = v; _selectedClasses = <String>{}; }),
          ),
          SizedBox(width: 12.w),
          // Class filter — checkbox multi-select
          _checkMultiSelect(
            anchorKey: _classKey,
            width: 160.w,
            allLabel: schoolTerm('All Classes'),
            pluralNoun: schoolTerm('classes'),
            selected: _selectedClasses,
            onTap: () => _openCheckPicker(
              anchorKey: _classKey,
              title: schoolTerm('Select Classes'),
              options: (_selectedCourse != null
                      // Matched on the STUDENT's course and class, not the
                      // demand's. Some demand rows carry a course that no
                      // longer agrees with their class -- a leftover from a
                      // transfer that moved the class without the course --
                      // and matching on them offered impossible pairs, e.g.
                      // B.E CSE -I under B TECH- IT. The students table is
                      // consistent, so it is what the picker follows.
                      ? _classes.where((c) => _allDemands.any((d) =>
                          (d['stu_course'] ?? d['courname'])?.toString() == _selectedCourse &&
                          (d['stu_class'] ?? d['stuclass'])?.toString() == c))
                      : _classes)
                  .toList(),
              current: _selectedClasses,
              onApply: (s) => setState(() => _selectedClasses = s),
            ),
          ),
          // Fee Group, directly after Class.
          //
          // It belongs with Course and Class because it narrows the same way
          // they do -- which slice of the college you are looking at -- and
          // reading left to right the filter bar should go from the broadest
          // cut to the narrowest. Tucked on the end it read as an
          // afterthought and was easy to miss having left set.
          //
          // On every report that narrows by fee, which is now all of them.
          //
          // Daily Collection, Pending Details and the DCB Register filter in
          // Dart, on rows that carry a fee type. Pending Payment and
          // Consolidated Status are server-side aggregates with no fee type
          // in their output, so they pass the selection to the RPC instead --
          // see REPORT_RPCS_FEEGROUP_FILTER.sql. Different mechanism, same
          // answer.
          if (_tabController.index == 0 ||
              (_tabController.index >= 2 && _tabController.index <= 5)) ...[
            SizedBox(width: 12.w),
            _feeGroupMultiSelect(width: 180.w),
          ],
          if (_tabController.index == _kPendingDetailsTab) ...[
            SizedBox(width: 12.w),
            // Regular / Arrear — sits with Course and Class because it narrows
            // the same report, and re-pivots from cached rows so it is instant.
            _filterDropdown<String>(
              value: _pdSeq,
              hint: 'All Demand Types',
              width: 170.w,
              items: const [
                DropdownMenuItem(value: '', child: Text('All Demand Types')),
                DropdownMenuItem(value: 'REGULAR', child: Text('Regular')),
                DropdownMenuItem(value: 'ARREAR', child: Text('Arrear')),
              ],
              onChanged: (v) => setState(() {
                _pdSeq = v ?? '';
                _pdPivot();
              }),
            ),
          ],
          if (_tabController.index == 2) ...[
            SizedBox(width: 12.w),
            // A school has no admission type or quota.
            if (!isSchool) ...[
            // Admission Type filter (Pending Payment) — checkbox multi-select
            _checkMultiSelect(
              anchorKey: _admnTypeKey,
              width: 190.w,
              allLabel: 'All Admission Types',
              pluralNoun: 'admission types',
              selected: _selectedAdmnTypes,
              onTap: () => _openCheckPicker(
                anchorKey: _admnTypeKey,
                title: 'Select Admission Types',
                options: _pendingAdmnTypes(),
                current: _selectedAdmnTypes,
                onApply: (s) => setState(() => _selectedAdmnTypes = s),
              ),
            ),
            SizedBox(width: 12.w),
            // Quota filter (Pending Payment) — checkbox multi-select
            _checkMultiSelect(
              anchorKey: _quotaKey,
              width: 160.w,
              allLabel: 'All Quotas',
              pluralNoun: 'quotas',
              selected: _selectedQuotas,
              onTap: () => _openCheckPicker(
                anchorKey: _quotaKey,
                title: 'Select Quotas',
                options: _pendingQuotas(),
                current: _selectedQuotas,
                onApply: (s) => setState(() => _selectedQuotas = s),
              ),
            ),
            SizedBox(width: 12.w),
            ],
            // Regular / Arrear filter (Pending Payment) — checkbox multi-select
            _checkMultiSelect(
              anchorKey: _pendSeqKey,
              width: 170.w,
              allLabel: 'All Demand Types',
              pluralNoun: 'demand types',
              selected: _selectedSeqTypes,
              onTap: () => _openCheckPicker(
                anchorKey: _pendSeqKey,
                title: 'Select Demand Types',
                options: _pendingSeqTypes(),
                current: _selectedSeqTypes,
                onApply: (s) => setState(() => _selectedSeqTypes = s),
              ),
            ),
          ],
          if (_tabController.index == 5) ...[
            SizedBox(width: 12.w),
            // Fee KIND (COL / HOS / TRA). DCB ONLY, deliberately.
            //
            // It was briefly on every report and had to come off: Daily
            // Collection and Pending Payment each already have a filter
            // labelled "All Types" -- their own Regular/Arrear and
            // transaction-type pickers -- so the screen showed two controls
            // with the same name and no way to tell them apart.
            //
            // The list follows the chosen fee group, and is LOCKED until one
            // is chosen -- same rule as Daily Collection's three, for the same
            // reason: offered cold it lists COL, HOS and TRA together, which
            // is the whole college and narrows nothing.
            //
            // Both chip and list read "TRA  Transport" rather than a bare code.
            _checkMultiSelect(
              anchorKey: _dcbFgKey,
              width: 200.w,
              allLabel: 'All Fee Categories',
              pluralNoun: 'fee categories',
              selected: _selectedFeeKinds,
              labelOf: feeKindLabel,
              enabled: _feeGroupChosen,
              disabledTip: _kFeeGroupFirst,
              onTap: () => _openCheckPicker(
                anchorKey: _dcbFgKey,
                title: 'Select Fee Categories',
                options: _dcbTypeOptionsForGroup,
                current: _selectedFeeKinds,
                labelOf: feeKindLabel,
                onApply: (s) => setState(() => _selectedFeeKinds = s),
              ),
            ),
            // A school has no admission type.
            if (!isSchool) ...[
            SizedBox(width: 12.w),
            // Admission Type filter (DCB Register) — checkbox multi-select
            _checkMultiSelect(
              anchorKey: _dcbAdmKey,
              width: 190.w,
              allLabel: 'All Admission Types',
              pluralNoun: 'admission types',
              selected: _dcbAdmnTypes,
              onTap: () => _openCheckPicker(
                anchorKey: _dcbAdmKey,
                title: 'Select Admission Types',
                options: _dcbAdmnOptions(),
                current: _dcbAdmnTypes,
                onApply: (s) => setState(() => _dcbAdmnTypes = s),
              ),
            ),
            ],
          ],
          // Pending Payment / Pending Details / Consolidated Status / DCB.
          // Every one of them counts what is still owed, and a student who
          // holds a TC has left -- so they are left out unless asked for.
          if (_tabController.index >= 2 && _tabController.index <= 5) ...[
            SizedBox(width: 12.w),
            _filterDropdown<String>(
              key: ValueKey('tcfilter-$_tcFilter'),
              value: _tcFilter,
              hint: 'Without TC',
              width: 160.w,
              items: [
                for (final e in _kTcLabels.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                if (v == null || v == _tcFilter) return;
                setState(() => _tcFilter = v);
                // Pending Payment / Details / Consolidated are filtered by the
                // server, so they have to be fetched again. The DCB Register
                // filters the rows it already holds, so it just rebuilds.
                if (_tabController.index != 5) _refreshActiveTab();
              },
            ),
          ],

          // Daily Collection's three fee-level filters, all three locked
          // until a Fee Group is chosen and all three listing only what that
          // group contains — see _feeGroupChosen.
          if (_tabController.index == 0) ...[
            SizedBox(width: 12.w),
            _feeTypeMultiSelect(
              width: 200.w,
              enabled: _feeGroupChosen,
              disabledTip: _kFeeGroupFirst,
            ),
            SizedBox(width: 12.w),
            // Prefix filter — checkbox multi-select
            _checkMultiSelect(
              anchorKey: _prefixKey,
              width: 190.w,
              allLabel: 'All Receipt Prefixes',
              pluralNoun: 'receipt prefixes',
              selected: _selectedPrefixes,
              enabled: _feeGroupChosen,
              disabledTip: _kFeeGroupFirst,
              onTap: () => _openCheckPicker(
                anchorKey: _prefixKey,
                title: 'Select Receipt Prefixes',
                options: _dailyPrefixes(),
                current: _selectedPrefixes,
                onApply: (s) => setState(() => _selectedPrefixes = s),
              ),
            ),
            SizedBox(width: 12.w),
            // Type filter — checkbox multi-select
            _checkMultiSelect(
              anchorKey: _dailyTypeKey,
              width: 190.w,
              allLabel: 'All Transaction Types',
              pluralNoun: 'transaction types',
              selected: _selectedDailyTypes,
              enabled: _feeGroupChosen,
              disabledTip: _kFeeGroupFirst,
              onTap: () => _openCheckPicker(
                anchorKey: _dailyTypeKey,
                title: 'Select Transaction Types',
                options: _dailyTypeOptions(),
                current: _selectedDailyTypes,
                onApply: (s) => setState(() => _selectedDailyTypes = s),
              ),
            ),
          ],
                  ],
                ),
              ),
            ),
            // Reset (right corner)
            SizedBox(width: 12.w),
            SizedBox(
              height: AppBtn.height(context),
              child: ElevatedButton.icon(
                onPressed: _refreshing ? null : () {
                  setState(_clearFilters);
                  _refreshActiveTab();
                },
                icon: _refreshing
                    ? SizedBox(
                        width: AppBtn.iconSize(context),
                        height: AppBtn.iconSize(context),
                        child: const CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                label: const Text('Refresh'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Themed solid action button (Excel / PDF / Print); colour from the theme.
  Widget _miniExportBtn({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    /// A non-export action (Clear) reads as the outlined secondary button.
    bool secondary = false,
  }) {
    return SizedBox(
      height: AppBtn.height(context),
      child: secondary
          ? OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon, size: AppBtn.iconSize(context)),
              label: Text(label),
            )
          : ElevatedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon, size: AppBtn.iconSize(context)),
              label: Text(label),
            ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // TAB: CONSOLIDATED FEE COLLECTION STATUS
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  List<Map<String, dynamic>> _consolidatedRows() {
    return _consolidatedRowsCache.where((r) {
      if (_selectedCourse != null && r['course'] != _selectedCourse) return false;
      if (_selectedClasses.isNotEmpty && !_selectedClasses.contains(r['class']?.toString())) return false;
      return true;
    }).toList();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PENDING DETAILS — the printed "PENDING DETAIL REPORT": one row per student
  // with the pending amount split into a column per fee type.
  // ══════════════════════════════════════════════════════════════════════════

  /// Pull the per-student / per-fee-type figures.
  ///
  /// Served by an RPC rather than assembled here, for two reasons: PostgREST's
  /// 1000-row cap would silently truncate a whole-college pending list, and the
  /// money definitions (pending counts collected-but-unreconciled back as due;
  /// collection is fee-only and approved-only) have to match Pending Payment
  /// and Consolidated Status exactly or the three reports disagree in front of
  /// the office. get_pending_details_report reuses their SQL verbatim.
  Future<void> _loadPendingDetails({bool force = false}) async {
    if (_pdLoading) return;
    if (_pdLoaded && !force) return;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null) return;

    setState(() { _pdLoading = true; _pdError = null; });
    try {
      final raw = await _rpcWithTc('get_pending_details_report', schema, insId);
      // RETURNS json — supabase hands back a List, or a JSON string.
      List list;
      if (raw is List) {
        list = raw;
      } else if (raw is String && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        list = d is List ? d : <dynamic>[];
      } else {
        list = <dynamic>[];
      }

      _pdRaw = List<Map<String, dynamic>>.from(list);
      _pdPivot();
      if (!mounted) return;
      setState(() { _pdLoading = false; _pdLoaded = true; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _pdError = friendlyError(e); _pdLoading = false; _pdLoaded = true; });
    }
  }

  /// Build the on-screen rows from [_pdRaw], honouring the Regular/Arrear
  /// filter. Separate from the load so switching the filter is instant and
  /// costs no round trip -- the RPC returns the whole college either way.
  void _pdPivot() {
      final byAdm = <String, Map<String, dynamic>>{};
      final feeTypes = <String>{};
      for (final e in _pdRaw) {
        final adm = e['stuadmno']?.toString() ?? '';
        if (adm.isEmpty) continue;
        // demseqtype marks a demand as REGULAR or ARREAR. Older servers do not
        // return it at all; treat those rows as REGULAR so the filter degrades
        // to "everything" rather than silently emptying the report.
        if (_pdSeq.isNotEmpty) {
          final st = (e['demseqtype']?.toString().trim().toUpperCase() ?? '');
          if ((st.isEmpty ? 'REGULAR' : st) != _pdSeq) continue;
        }
        final ft = e['feetype']?.toString() ?? '';
        // FEE TYPE only. The fee GROUP filter is applied by
        // get_pending_details_report, using the same fee_id predicate as
        // Pending Payment and Consolidated Status -- see
        // REPORT_RPCS_FEEGROUP_FILTER.sql. Repeating it here on the fee
        // DESCRIPTION is exactly what made this report disagree with the
        // other two by Rs 1,82,254 on HOSTEL FEES.
        if (!_feeTypeSelected(ft)) continue;
        final pend = (e['pending'] as num?)?.toDouble() ?? 0;

        final r = byAdm.putIfAbsent(adm, () => {
              'stuadmno': adm,
              'stuname': e['stuname']?.toString() ?? '',
              'stuclass': e['stuclass']?.toString() ?? '',
              'courname': e['courname']?.toString() ?? '',
              'category': e['category']?.toString() ?? '',
              'demand': 0.0, 'net': 0.0, 'collection': 0.0, 'pending': 0.0,
              'byFee': <String, double>{},
            });
        r['demand'] = (r['demand'] as double) + ((e['demand'] as num?)?.toDouble() ?? 0);
        r['net'] = (r['net'] as double) + ((e['net_demand'] as num?)?.toDouble() ?? 0);
        r['collection'] = (r['collection'] as double) + ((e['collection'] as num?)?.toDouble() ?? 0);
        r['pending'] = (r['pending'] as double) + pend;
        if (ft.isNotEmpty && pend != 0) {
          // ACCUMULATE, never assign: the RPC groups by demseqtype as well as
          // fee type, so one student can have both a REGULAR and an ARREAR row
          // for the same fee. Assigning would silently keep only the last one.
          final byFee = r['byFee'] as Map<String, double>;
          byFee[ft] = (byFee[ft] ?? 0) + pend;
          // A fee type nobody owes gets no column — otherwise the grid carries
          // a blank column for every fee type ever defined.
          feeTypes.add(ft);
        }
      }

      final rows = byAdm.values.toList()
        ..sort((a, b) {
          final c = (a['courname'] as String).compareTo(b['courname'] as String);
          if (c != 0) return c;
          final cl = (a['stuclass'] as String).compareTo(b['stuclass'] as String);
          return cl != 0 ? cl : (a['stuadmno'] as String).compareTo(b['stuadmno'] as String);
        });
      _pdRows = rows;
      // Pending Detail's columns follow the same running order as every
      // other report, so a reader moving between tabs finds TUITION FEE in
      // the same place each time.
      _pdFeeTypes = feeTypes.toList()..sort(feeTypeOrdidComparator(_feeOrder));
  }

  /// Narrowed by the Course / Class filters shared with the other tabs.
  List<Map<String, dynamic>> get _pdVisible => _pdRows.where((r) {
        if (_selectedCourse != null && r['courname'] != _selectedCourse) return false;
        if (_selectedClasses.isNotEmpty && !_selectedClasses.contains(r['stuclass'])) return false;
        return true;
      }).toList();

  /// Fee-type columns worth showing: the ones with a non-zero TOTAL across the
  /// rows currently on screen. Derived from the FILTERED rows, not the whole
  /// college -- otherwise a Course/Class or Regular/Arrear filter leaves behind
  /// columns that are entirely blank.
  List<String> _pdShownFeeTypes(List<Map<String, dynamic>> rows) {
    final tot = <String, double>{};
    for (final r in rows) {
      (r['byFee'] as Map<String, double>)
          .forEach((k, v) => tot[k] = (tot[k] ?? 0) + v);
    }
    // Half a paisa, so a rounding artefact cannot resurrect a dead column.
    return _pdFeeTypes.where((f) => (tot[f] ?? 0).abs() > 0.005).toList();
  }

  List<String> _pdHeaders(List<String> fts) => <String>[
        AppText.serialNo, schoolTerm('Class'), schoolTerm('Register No'), 'Student Name', 'Category',
        'Total Demand', 'Net Demand', 'Total Collection',
        ...fts.map(_feeHdr), 'Pending Total',
      ];

  Widget _buildPendingDetails() {
    // Auto-load the first time the tab is actually shown. Gated on the index
    // (not just a flag) so opening Reports on some other tab doesn't fire this
    // whole-college aggregate for nothing -- which is why the child is wrapped
    // in a ListenableBuilder on _tabController: the TabBarView's children are
    // built once, so without it a tab switch would never re-enter here.
    if (!_pdLoaded && !_pdLoading && _tabController.index == _kPendingDetailsTab) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPendingDetails());
    }
    if (_pdLoading) return const Center(child: CircularProgressIndicator());
    if (_pdError != null) {
      return Column(children: [
        _pdToolbar(0),
        Expanded(child: Center(child: Text('Error: $_pdError'))),
      ]);
    }
    if (_pdRows.isEmpty) return _emptyState('No pending dues', why: 'No student in these filters owes anything right now.');

    final rows = _pdVisible;
    final fts = _pdShownFeeTypes(rows);
    double tDem = 0, tNet = 0, tCol = 0, tPen = 0;
    final ftTotals = <String, double>{};
    for (final r in rows) {
      tDem += r['demand'] as double;
      tNet += r['net'] as double;
      tCol += r['collection'] as double;
      tPen += r['pending'] as double;
      (r['byFee'] as Map<String, double>)
          .forEach((k, v) => ftTotals[k] = (ftTotals[k] ?? 0) + v);
    }

    final headers = _pdHeaders(fts);
    final widths = <double>[
      70, 140, 150, 230, 140, 130, 130, 140,
      ...fts.map((_) => 130.0), 140,
    ];

    return Column(children: [
      _pdToolbar(rows.length),
      Expanded(
        child: _stickyTable(
          columnWidths: widths,
          headers: headers,
          rows: [
            for (var i = 0; i < rows.length; i++)
              () {
                final r = rows[i];
                final byFee = r['byFee'] as Map<String, double>;
                return <String>[
                  '${i + 1}',
                  r['stuclass'] as String,
                  r['stuadmno'] as String,
                  r['stuname'] as String,
                  r['category'] as String,
                  _formatNumber(r['demand'] as double),
                  _formatNumber(r['net'] as double),
                  _formatNumber(r['collection'] as double),
                  ...fts.map((f) => (byFee[f] ?? 0) != 0 ? _formatNumber(byFee[f]!) : ''),
                  _formatNumber(r['pending'] as double),
                ];
              }(),
          ],
          footer: <String>[
            'TOTAL', '', '', '', '',
            _formatNumber(tDem), _formatNumber(tNet), _formatNumber(tCol),
            ...fts.map((f) => _formatNumber(ftTotals[f] ?? 0)),
            _formatNumber(tPen),
          ],
          numericCols: {for (int i = 5; i < headers.length; i++) i},
        ),
      ),
    ]);
  }

  Widget _pdToolbar(int count) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          _reportTitle('receipt-item', 'Pending Details', 'Every demand and receipt behind the pending figure'),
          const Spacer(),
          if (count > 0)
            Padding(
              padding: EdgeInsets.only(right: 10.w),
              child: Text('$count student${count == 1 ? '' : 's'} pending',
                  style: AppUI.muted),
            ),
          _miniExportBtn(
            onPressed: _pdRows.isEmpty ? () {} : _exportPendingDetailsExcel,
            icon: Icons.table_chart_rounded,
            label: AppText.exportExcel,
          ),
        ]),
      );

  /// Academic year for report titles, e.g. "2026-2027".
  ///
  /// AuthProvider.yearLabel is NOT reliable here: it is only populated on some
  /// login paths, and switching year on the dashboard updates that screen's own
  /// field without writing back -- which is why the exported title read
  /// "FOR THE YEAR" with nothing after it. The schema name always encodes the
  /// year (kcet20262027 -> 2026-2027), so fall back to that.
  String get _academicYearLabel {
    final fromAuth = (context.read<AuthProvider>().yearLabel ?? '').trim();
    if (fromAuth.isNotEmpty) return fromAuth;
    final m = RegExp(r'(\d{4})(\d{4})$')
        .firstMatch(SupabaseService.currentSchema ?? '');
    return m == null ? '' : '${m.group(1)}-${m.group(2)}';
  }

  /// Excel in the circulated layout: title block, then one block per course
  /// with its own header row and TOTAL line.
  Future<void> _exportPendingDetailsExcel() async {
    try {
      final rows = _pdVisible;
      if (rows.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Nothing to export for this filter.'),
              backgroundColor: AppColors.warning));
        }
        return;
      }
      final fts = _pdShownFeeTypes(rows);
      final headers = _pdHeaders(fts);

      // The institution block comes from _loadData, which this tab does not
      // wait for -- Pending Details loads itself through its own RPC. Export
      // before that lands and the college name is blank on the sheet, which is
      // what makes a printed report unusable. Fetch it here if it is missing.
      if (_insName.isEmpty) {
        try {
          final info = await SupabaseService.getInstitutionInfo(
              context.read<AuthProvider>().insId ?? 1);
          _insName = info.name ?? '';
          _insAddress = info.address?.replaceAll('\n', ', ') ?? '';
          _insPhone = info.mobile ?? '';
          _insEmail = info.email ?? '';
        } catch (e) {
          debugPrint('institution info for pending details export: $e');
        }
      }

      final excel = xl.Excel.createExcel();
      final sheet = excel['Pending Details'];
      excel.delete('Sheet1');

      // Header block copied from the Daily Collection statement so the two
      // circulated sheets read identically: bold name, plain address, bold
      // title, then Date / filter lines -- all left aligned, no colour band.
      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final plainStyle = xl.CellStyle(fontSize: 10);
      final sub = xl.CellStyle(bold: true, fontSize: 10);
      final hdr = xl.CellStyle(
        bold: true,
        fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final money = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final tot = xl.CellStyle(
          bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      int row = 0;
      xl.CellIndex at(int c, int r) =>
          xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r);
      void banner(String text, xl.CellStyle st) {
        sheet.cell(at(0, row))
          ..value = xl.TextCellValue(text)
          ..cellStyle = st;
        sheet.merge(at(0, row), at(headers.length - 1, row));
        row++;
      }

      banner(_insName, boldStyle);
      if (_insAddress.isNotEmpty) banner(_insAddress, plainStyle);
      final yr = _academicYearLabel;
      banner(
          'PENDING DETAILS REPORT${yr.isEmpty ? '' : ' FOR THE YEAR $yr'}',
          boldStyle);
      banner('Date: ${_formatDate(DateTime.now())}', plainStyle);
      // Mirrors the statement's "Collected by" line: says on the paper which
      // slice of the data this is, so a printed Arrear-only sheet cannot be
      // mistaken for the whole college.
      banner(
          'Demand Type: ${_pdSeq.isEmpty ? 'All' : (_pdSeq == 'ARREAR' ? 'Arrear' : 'Regular')}',
          boldStyle);
      row++;

      final courses = rows.map((r) => r['courname'] as String).toSet().toList()..sort();
      // College-wide figures, accumulated across the course blocks so the sheet
      // ends with a GRAND TOTAL and not just the last course's subtotal.
      double gDem = 0, gNet = 0, gCol = 0, gPen = 0;
      final gFt = <String, double>{};
      for (final course in courses) {
        banner(schoolTerm('Course : $course'), sub);
        for (var c = 0; c < headers.length; c++) {
          sheet.cell(at(c, row))
            ..value = xl.TextCellValue(headers[c])
            ..cellStyle = hdr;
        }
        row++;

        final courseRows = rows.where((r) => r['courname'] == course).toList();
        double sDem = 0, sNet = 0, sCol = 0, sPen = 0;
        final sFt = <String, double>{};
        for (var i = 0; i < courseRows.length; i++) {
          final r = courseRows[i];
          final byFee = r['byFee'] as Map<String, double>;
          sDem += r['demand'] as double;
          sNet += r['net'] as double;
          sCol += r['collection'] as double;
          sPen += r['pending'] as double;
          byFee.forEach((k, v) => sFt[k] = (sFt[k] ?? 0) + v);

          void txt(int c, String v) =>
              sheet.cell(at(c, row)).value = xl.TextCellValue(v);
          void amt(int c, double v, {bool showZero = false}) {
            // Blank, not 0.00: the fee-type columns are a sparse matrix
            // and a grid of zeros is unreadable. Total Collection is the
            // exception -- a student who has paid nothing must SAY 0, or
            // the empty cell reads as missing data.
            if (v == 0 && !showZero) return;
            sheet.cell(at(c, row))
              ..value = xl.DoubleCellValue(v)
              ..cellStyle = money;
          }
          txt(0, '${i + 1}');
          txt(1, r['stuclass'] as String);
          txt(2, r['stuadmno'] as String);
          txt(3, r['stuname'] as String);
          txt(4, r['category'] as String);
          amt(5, r['demand'] as double);
          amt(6, r['net'] as double);
          amt(7, r['collection'] as double, showZero: true);
          for (var f = 0; f < fts.length; f++) {
            amt(8 + f, byFee[fts[f]] ?? 0);
          }
          amt(8 + fts.length, r['pending'] as double);
          row++;
        }

        sheet.cell(at(0, row))
          ..value = xl.TextCellValue('TOTAL')
          ..cellStyle = tot;
        void t(int c, double v) => sheet.cell(at(c, row))
          ..value = xl.DoubleCellValue(v)
          ..cellStyle = tot;
        t(5, sDem);
        t(6, sNet);
        t(7, sCol);
        for (var f = 0; f < fts.length; f++) {
          t(8 + f, sFt[fts[f]] ?? 0);
        }
        t(8 + fts.length, sPen);
        row += 2;

        gDem += sDem;
        gNet += sNet;
        gCol += sCol;
        gPen += sPen;
        sFt.forEach((k, v) => gFt[k] = (gFt[k] ?? 0) + v);
      }

      // ── GRAND TOTAL ────────────────────────────────────────────────────────
      final grand = xl.CellStyle(
        bold: true,
        fontSize: 10,
        horizontalAlign: xl.HorizontalAlign.Right,
        backgroundColorHex: xl.ExcelColor.fromHexString('#E2E8F0'),
      );
      sheet.cell(at(0, row))
        ..value = xl.TextCellValue('GRAND TOTAL')
        ..cellStyle = xl.CellStyle(
            bold: true,
            fontSize: 10,
            backgroundColorHex: xl.ExcelColor.fromHexString('#E2E8F0'));
      for (var c = 1; c < 5; c++) {
        sheet.cell(at(c, row)).cellStyle = grand;
      }
      void g(int c, double v) => sheet.cell(at(c, row))
        ..value = xl.DoubleCellValue(v)
        ..cellStyle = grand;
      g(5, gDem);
      g(6, gNet);
      g(7, gCol);
      for (var f = 0; f < fts.length; f++) {
        g(8 + f, gFt[fts[f]] ?? 0);
      }
      g(8 + fts.length, gPen);
      row++;

      sheet.setColumnWidth(0, 7);
      sheet.setColumnWidth(1, 16);
      sheet.setColumnWidth(2, 16);
      sheet.setColumnWidth(3, 30);
      sheet.setColumnWidth(4, 18);
      for (var c = 5; c < headers.length; c++) {
        sheet.setColumnWidth(c, 14);
      }

      // Name the file after the course it actually holds. With a course
      // filtered, the sheet is only that course -- and a folder of
      // "Pending_Detail_Report_<today>" files, one per course exported the
      // same afternoon, is impossible to tell apart without opening each.
      // Anything a file name cannot carry (the dots and brackets in
      // "B.TECH (IT)") collapses to single underscores.
      final scope = _selectedCourse == null
          ? 'All_Courses'
          : _selectedCourse!
              .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
              .replaceAll(RegExp(r'^_+|_+$'), '');
      await _saveExcel(excel,
          'Pending_Detail_${scope}_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not export to Excel. ${friendlyError(e)}'),
            backgroundColor: AppColors.error));
      }
    }
  }

  Widget _buildConsolidatedStatus() {
    if (!_pendingMetaLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPendingMeta());
    }
    final rows = _consolidatedRows();
    if (rows.isEmpty) return _emptyState('No data', why: 'Nothing matches the current filters -- change them above or press Refresh.');

    final byClass = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      byClass.putIfAbsent('${r['course']}|${r['class']}', () => []).add(r);
    }

    final headerStyle = AppUI.tableHead;
    final cellStyle = AppUI.cell;

    return Column(
      // tab-body-open
          children: [
            Container(
              padding: EdgeInsets.only(bottom: 10.h),
              child: Row(children: [
                _reportTitle('chart-2', 'Consolidated Status', schoolTerm('Overall fee status across classes')),
                SizedBox(width: 8.w),
                Text('— ${_formatDate(DateTime.now())}', style: AppUI.muted),
                const Spacer(),
                _miniExportBtn(
                  onPressed: () => _exportConsolidatedExcel(rows, byClass),
                  icon: Icons.table_chart_rounded,
                  label: AppText.exportExcel,
                ),
                SizedBox(width: AppBtn.gap(context)),
                _miniExportBtn(
                  onPressed: () => _exportConsolidatedPdf(rows, byClass),
                  icon: Icons.picture_as_pdf_rounded,
                  label: AppText.exportPdf,
                ),
              ]),
            ),
            Expanded(
              child: _stickyTable(
            columnWidths: const [90, 110, 90, 110, 200, 120, 90, 110, 110, 120, 100, 110],
            headers: [schoolTerm('COURSE'), schoolTerm('CLASS'), 'STRENGTH', schoolTerm('SEMESTER'), 'CATEGORY', 'STUDENT COUNT', 'TYPE', 'DUE', 'CONCESSION', 'NET DEMAND', 'PAID', 'BALANCE'],
            rows: [
              for (final r in rows)
                [
                  r['course']?.toString() ?? '',
                  r['class']?.toString() ?? '',
                  '${r['strength'] ?? 0}',
                  r['semester']?.toString() ?? '',
                  r['category']?.toString() ?? '',
                  '${r['stud_count'] ?? 0}',
                  r['type']?.toString() ?? '',
                  _formatNumber((r['due'] as double?) ?? 0),
                  _formatNumber((r['concession'] as double?) ?? 0),
                  _formatNumber((r['net_demand'] as double?) ?? 0),
                  _formatNumber((r['paid'] as double?) ?? 0),
                  _formatNumber((r['balance'] as double?) ?? 0),
                ],
            ],
            footer: [
              'GRAND TOTAL', '', '', '', '', '', '',
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['due'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['concession'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['net_demand'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['paid'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['balance'] as double))),
            ],
            numericCols: const {7, 8, 9, 10, 11},
            centerCols: const {2, 5},
          ),
        ),
          ],
    );
  }

  Future<void> _exportConsolidatedExcel(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Consolidated Status'];
      excel.delete('Sheet1');
      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(bold: true, fontSize: 10);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      row++;
      if (_insAddress.isNotEmpty) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
        row++;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('Consolidated Fee Collection Status Report as on ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.TextCellValue('Date: ${_formatDate(DateTime.now())}');
      row += 2;

      final headers = [schoolTerm('Course'), schoolTerm('Class'), 'Strength', schoolTerm('Semester'), 'Category', 'Student Count', 'Type', 'Due', 'Concession', 'Net Demand', 'Paid', 'Balance'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      void writeRow(Map<String, dynamic> r, {bool isTotal = false, String? labelOverride}) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['course']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(labelOverride ?? r['class']?.toString() ?? '');
        if (labelOverride != null) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
        }
        if (!isTotal) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.IntCellValue((r['strength'] as int?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['semester']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(r['category']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.IntCellValue((r['stud_count'] as int?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.TextCellValue(r['type']?.toString() ?? '');
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = xl.DoubleCellValue((r['due'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: row)).value = xl.DoubleCellValue((r['concession'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).value = xl.DoubleCellValue((r['net_demand'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: row)).value = xl.DoubleCellValue((r['paid'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 11, rowIndex: row)).value = xl.DoubleCellValue((r['balance'] as double?) ?? 0);
        for (int c = 7; c <= 11; c++) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = isTotal ? totalStyle : numStyle;
        }
        row++;
      }

      for (final entry in byClass.entries) {
        for (final r in entry.value) writeRow(r);
        final cls = entry.value.first;
        writeRow({
          'course': cls['course'],
          'due': entry.value.fold<double>(0, (s, r) => s + (r['due'] as double)),
          'concession': entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double)),
          'net_demand': entry.value.fold<double>(0, (s, r) => s + (r['net_demand'] as double)),
          'paid': entry.value.fold<double>(0, (s, r) => s + (r['paid'] as double)),
          'balance': entry.value.fold<double>(0, (s, r) => s + (r['balance'] as double)),
        }, isTotal: true, labelOverride: schoolTerm('Class Total'));
      }
      writeRow({
        'course': '',
        'due': rows.fold<double>(0, (s, r) => s + (r['due'] as double)),
        'concession': rows.fold<double>(0, (s, r) => s + (r['concession'] as double)),
        'net_demand': rows.fold<double>(0, (s, r) => s + (r['net_demand'] as double)),
        'paid': rows.fold<double>(0, (s, r) => s + (r['paid'] as double)),
        'balance': rows.fold<double>(0, (s, r) => s + (r['balance'] as double)),
      }, isTotal: true, labelOverride: 'GRAND TOTAL');

      for (int c = 0; c < headers.length; c++) sheet.setColumnWidth(c, c <= 1 ? 18 : 13);
      await _saveExcel(excel, 'Consolidated_Status_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export to Excel. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  Future<void> _exportConsolidatedPdf(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass) async {
    try {
      final pdf = pw.Document();
      final data = <List<String>>[];
      for (final entry in byClass.entries) {
        for (final r in entry.value) {
          data.add([
            r['course']?.toString() ?? '',
            r['class']?.toString() ?? '',
            '${r['strength'] ?? 0}',
            r['semester']?.toString() ?? '',
            r['category']?.toString() ?? '',
            '${r['stud_count'] ?? 0}',
            r['type']?.toString() ?? '',
            _formatNumber((r['due'] as double?) ?? 0),
            _formatNumber((r['concession'] as double?) ?? 0),
            _formatNumber((r['net_demand'] as double?) ?? 0),
            _formatNumber((r['paid'] as double?) ?? 0),
            _formatNumber((r['balance'] as double?) ?? 0),
          ]);
        }
        data.add([
          entry.value.first['course']?.toString() ?? '', 'Class Total', '', '', '', '', '',
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['due'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['net_demand'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['paid'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['balance'] as double))),
        ]);
      }
      data.add([
        '', 'GRAND TOTAL', '', '', '', '', '',
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['due'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['concession'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['net_demand'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['paid'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['balance'] as double))),
      ]);
      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('Consolidated Fee Collection Status Report as on ${_formatDate(DateTime.now())}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Date: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.Table.fromTextArray(
            headers: [schoolTerm('COURSE'), schoolTerm('CLASS'), 'STRENGTH', schoolTerm('SEMESTER'), 'CATEGORY', 'STUDENT COUNT', 'TYPE', 'DUE', 'CONCESSION', 'NET DEMAND', 'PAID', 'BALANCE'],
            data: data,
            headerStyle: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 7),
            cellAlignments: {for (int i = 7; i <= 11; i++) i: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      // layoutPdf (print preview → Microsoft Print to PDF) works on Windows;
      // sharePdf is a mobile share-sheet concept and silently does nothing here.
      await _savePdf(pdf, 'Consolidated_Status_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the PDF. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // TAB: PENDING PAYMENT REPORT (course-class-semester)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  bool _pendingMetaLoaded = false;
  static const int _tablePageSize = 50;
  int _dailyPage = 0;
  List<Map<String, dynamic>> _pendingRowsCache = [];
  List<Map<String, dynamic>> _consolidatedRowsCache = [];

  /// Call a report RPC with the TC filter, falling back to the older 2-arg
  /// form on a server that has not had the overload added yet.
  Future<dynamic> _rpcWithTc(String fn, String schema, int insId) async {
    // Pending Payment and Consolidated Status aggregate server-side and carry
    // no fee type, so their Fee Group filter has to be applied in SQL. Null
    // means every group, which is what the report did before the argument
    // existed.
    final groups =
        _selectedFeeGroups.isEmpty ? null : _selectedFeeGroups.toList();
    try {
      return await SupabaseService.client.rpc(fn, params: {
        'p_schema': schema, 'p_ins_id': insId, 'p_tc': _tcFilter,
        'p_fee_groups': groups, 'p_fee_kinds': null,
      });
    } catch (e) {
      debugPrint('$fn(p_fee_kinds) unavailable, using the 4-arg form: $e');
      try {
        return await SupabaseService.client.rpc(fn, params: {
          'p_schema': schema, 'p_ins_id': insId, 'p_tc': _tcFilter,
          'p_fee_groups': groups,
        });
      } catch (_) {
        debugPrint('$fn(p_fee_groups) unavailable, using the 3-arg form');
        try {
          return await SupabaseService.client.rpc(fn, params: {
            'p_schema': schema, 'p_ins_id': insId, 'p_tc': _tcFilter,
          });
        } catch (e2) {
          debugPrint('$fn(p_tc) unavailable, using the 2-arg form: $e2');
          return SupabaseService.client.rpc(fn, params: {
            'p_schema': schema, 'p_ins_id': insId,
          });
        }
      }
    }
  }

  Future<void> _loadPendingMeta({bool force = false}) async {
    if (_pendingMetaLoaded && !force) return;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null) return;
    try {
      // p_tc is the TC filter. A server without the overload throws PGRST202,
      // and _rpcWithTc falls back to the 2-arg call, which means 'NOTC'.
      final pendingFut = _rpcWithTc('get_pending_payment_report', schema, insId);
      final consoFut = _rpcWithTc('get_consolidated_status_report', schema, insId);
      final results = await Future.wait([pendingFut, consoFut]);
      // RPC returns JSON (RETURNS json). Supabase may decode it as a List,
      // or hand back a JSON-encoded String - handle both.
      List _asList(dynamic v) {
        if (v is List) return v;
        if (v is String && v.isNotEmpty) {
          final decoded = jsonDecode(v);
          return decoded is List ? decoded : <dynamic>[];
        }
        return <dynamic>[];
      }
      debugPrint('Pending RPC result type: ${results[0].runtimeType}');
      debugPrint('Conso   RPC result type: ${results[1].runtimeType}');
      final pendingList = _asList(results[0]);
      final consoList   = _asList(results[1]);
      debugPrint('Pending rows: ${pendingList.length}, Conso rows: ${consoList.length}');
      final pending = pendingList.isNotEmpty
          ? List<Map<String, dynamic>>.from(pendingList).map((r) => {
              'course': r['courname']?.toString() ?? '',
              'class': r['stuclass']?.toString() ?? '',
              'semester': r['semester']?.toString() ?? '',
              // Older deployments of get_pending_payment_report don't return
              // seqtype; treat a missing value as Regular so the report still
              // renders in full before the migration is run.
              'seqtype': (r['seqtype']?.toString().trim().toUpperCase() == 'ARREAR')
                  ? 'Arrear' : 'Regular',
              'admname': r['admname']?.toString() ?? '',
              'stuadmno': r['stuadmno']?.toString() ?? '',
              'stuname': r['stuname']?.toString() ?? '',
              'pending': (r['pending'] as num?)?.toDouble() ?? 0,
              'concession': (r['concession'] as num?)?.toDouble() ?? 0,
              'quoname': r['quoname']?.toString() ?? '',
              'stumobile': r['stumobile']?.toString() ?? '',
            }).toList()
          : <Map<String, dynamic>>[];
      final conso = consoList.isNotEmpty
          ? List<Map<String, dynamic>>.from(consoList).map((r) => {
              'course': r['courname']?.toString() ?? '',
              'class': r['stuclass']?.toString() ?? '',
              'strength': (r['strength'] as num?)?.toInt() ?? 0,
              'semester': r['semester']?.toString() ?? '',
              'category': r['category']?.toString() ?? 'GENERAL',
              'stud_count': (r['stud_count'] as num?)?.toInt() ?? 0,
              'type': r['type']?.toString() ?? 'Regular',
              'due': (r['due'] as num?)?.toDouble() ?? 0,
              'concession': (r['concession'] as num?)?.toDouble() ?? 0,
              // Net Demand = Due − Concession (the RPC returned Due unchanged;
              // Balance already nets the concession, so only this display was off).
              'net_demand': ((r['due'] as num?)?.toDouble() ?? 0) - ((r['concession'] as num?)?.toDouble() ?? 0),
              'paid': (r['paid'] as num?)?.toDouble() ?? 0,
              'balance': (r['balance'] as num?)?.toDouble() ?? 0,
            }).toList()
          : <Map<String, dynamic>>[];
      if (mounted) setState(() {
        _pendingRowsCache = pending;
        _consolidatedRowsCache = conso;
        _pendingMetaLoaded = true;
      });
    } catch (e) {
      debugPrint('pending/consolidated load: $e');
    }
  }

  List<Map<String, dynamic>> _pendingRows() {
    return _pendingRowsCache.where((r) {
      if (_selectedCourse != null && r['course'] != _selectedCourse) return false;
      if (_selectedClasses.isNotEmpty && !_selectedClasses.contains(r['class']?.toString())) return false;
      if (_selectedAdmnTypes.isNotEmpty && !_selectedAdmnTypes.contains(r['admname']?.toString())) return false;
      if (_selectedQuotas.isNotEmpty && !_selectedQuotas.contains(r['quoname']?.toString())) return false;
      if (_selectedSeqTypes.isNotEmpty && !_selectedSeqTypes.contains(r['seqtype']?.toString())) return false;
      return true;
    }).toList();
  }

  /// Distinct, sorted admission types present in the pending data (for the filter).
  List<String> _pendingAdmnTypes() {
    final s = <String>{};
    for (final r in _pendingRowsCache) {
      final v = r['admname']?.toString() ?? '';
      if (v.isNotEmpty) s.add(v);
    }
    return s.toList()..sort();
  }

  /// Regular / Arrear values present in the pending data (for the filter).
  /// Regular first — it is the common case, and alphabetical would bury it.
  List<String> _pendingSeqTypes() {
    final s = <String>{};
    for (final r in _pendingRowsCache) {
      final v = r['seqtype']?.toString() ?? '';
      if (v.isNotEmpty) s.add(v);
    }
    return ['Regular', 'Arrear'].where(s.contains).toList();
  }

  /// Distinct, sorted quotas present in the pending data (for the filter).
  List<String> _pendingQuotas() {
    final s = <String>{};
    for (final r in _pendingRowsCache) {
      final v = r['quoname']?.toString() ?? '';
      if (v.isNotEmpty) s.add(v);
    }
    return s.toList()..sort();
  }

  Widget _buildPendingPayment() {
    if (!_pendingMetaLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPendingMeta());
    }
    final rows = _pendingRows();
    if (rows.isEmpty) return _emptyState('No pending dues', why: 'No student in these filters owes anything right now.');

    final byClass = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final key = '${r['course']}|${r['class']}';
      byClass.putIfAbsent(key, () => []).add(r);
    }
    double grandPending = 0, grandConcess = 0;
    for (final r in rows) {
      grandPending += (r['pending'] as double);
      grandConcess += (r['concession'] as double);
    }

    final headerStyle = AppUI.tableHead;
    final cellStyle = AppUI.cell;

    return Column(
      // tab-body-open
          children: [
            Container(
              padding: EdgeInsets.only(bottom: 10.h),
              child: Row(children: [
                _reportTitle('clock', 'Pending Payment', 'Students with outstanding balances'),
                SizedBox(width: 8.w),
                Text('— ${_formatDate(DateTime.now())}', style: AppUI.muted),
                const Spacer(),
                _miniExportBtn(
                  onPressed: () => _exportPendingPaymentExcel(rows, byClass, grandPending, grandConcess),
                  icon: Icons.table_chart_rounded,
                  label: AppText.exportExcel,
                ),
                SizedBox(width: AppBtn.gap(context)),
                _miniExportBtn(
                  onPressed: () => _exportPendingPaymentPdf(rows, byClass, grandPending, grandConcess),
                  icon: Icons.picture_as_pdf_rounded,
                  label: AppText.exportPdf,
                ),
              ]),
            ),
            Expanded(
              child: _stickyTable(
                // Equal-width columns (scaled to fill by _StickyTable).
                // A school has no admission type or quota: those two columns go.
                columnWidths: [110, 110, 110, 80, if (!isSchool) 140, 125, 110, 140, 155, if (!isSchool) 110, 110],
                headers: [schoolTerm('COURSE'), schoolTerm('CLASS'), schoolTerm('SEMESTER'), 'TYPE', if (!isSchool) 'ADMISSION TYPE', schoolTerm('REGISTER NO'), 'NAME', 'PENDING AMOUNT', 'CONCESSION AMOUNT', if (!isSchool) 'QUOTA', 'MOBILE NO'],
                rows: [
                  for (final r in rows)
                    [
                      r['course']?.toString() ?? '',
                      r['class']?.toString() ?? '',
                      r['semester']?.toString() ?? '',
                      r['seqtype']?.toString() ?? '',
                      if (!isSchool) r['admname']?.toString() ?? '',
                      r['stuadmno']?.toString() ?? '',
                      r['stuname']?.toString() ?? '',
                      _formatNumber((r['pending'] as double?) ?? 0),
                      _formatNumber((r['concession'] as double?) ?? 0),
                      if (!isSchool) r['quoname']?.toString() ?? '',
                      r['stumobile']?.toString() ?? '',
                    ],
                ],
                footer: [
                  'Grand Total', '', '', '', if (!isSchool) '', '', '',
                  _formatNumber(grandPending),
                  _formatNumber(grandConcess),
                  if (!isSchool) '', '',
                ],
                numericCols: isSchool ? const {6, 7} : const {7, 8},
              ),
            ),
          ],
    );
  }

  /// Sticky-header/footer table: shared horizontal scroll, only the body
  /// rows scroll vertically. Used by the Pending Payment report.
  Widget _stickyTable({
    required List<double> columnWidths,
    required List<String> headers,
    required List<List<String>> rows,
    required List<String> footer,
    Set<int> numericCols = const {},
    Set<int> centerCols = const {},
    // Per-report overrides. A report with a dozen columns needs smaller type
    // and a wider gutter to read; the default keeps every other table as it was.
    double? cellFontSize,
    double? headerFontSize,
    double? cellGap,
    List<Color?>? rowTints,
  }) {
    return _StickyTable(
      columnWidths: columnWidths,
      headers: headers,
      rows: rows,
      footer: footer,
      numericCols: numericCols,
      centerCols: centerCols,
      cellFontSize: cellFontSize,
      headerFontSize: headerFontSize,
      cellGap: cellGap,
      rowTints: rowTints,
    );
  }

  /// The four figures the Student Ledger exists to answer, above the table
  /// instead of under it.
  ///
  /// BALANCE is the one that matters and is sized and coloured to say so:
  /// green when the student is clear, amber while anything is outstanding.
  /// REFUND only appears when there is one -- an always-visible zero column
  /// is noise on the 99% of ledgers that have never had a refund.
  /// Who the ledger is for, readable at a glance.
  ///
  /// This replaced four lines of print-header: college name, address,
  /// "STUDENT LEDGER - <date>", then Name/Reg/Course/Class as labelled plain
  /// text. All of it still prints on the PDF, which is the copy that leaves
  /// the building. On screen the reader already knows which college they are
  /// in; what they need is which student, and the letterhead buried it.
  Widget _ledgerStudentStrip() {
    final s = _ledgerStudent!;
    final name = (s['stuname'] ?? '').toString();

    Widget fact(String label, String value) => Padding(
          padding: EdgeInsets.only(right: 22.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: AppUI.caps),
              SizedBox(height: 2.h),
              Text(value.trim().isEmpty ? '-' : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppUI.body.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        );

    return Padding(
      padding: EdgeInsets.only(bottom: 10.h),
      child: Row(
        children: [
          StudentAvatar(photoUrl: _ledgerPhoto, name: name, size: 44),
          SizedBox(width: 12.w),
          Flexible(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppUI.cardTitle),
          ),
          SizedBox(width: 22.w),
          fact(schoolTerm('REGISTER NO'), (s['stuadmno'] ?? '').toString()),
          fact(schoolTerm('COURSE'), (s['courname'] ?? '').toString()),
          fact(schoolTerm('CLASS'), (s['stuclass'] ?? '').toString()),
          if (s['tcissued'] == true || _ledgerTc != null) _ledgerTcBadge(),
          const Spacer(),
          Text('as on ${_formatDate(DateTime.now())}',
              style: AppUI.muted),
        ],
      ),
    );
  }

  /// The four figures the Student Ledger exists to answer, above the table
  /// instead of under it. They were only in the footer, under however many
  /// rows the student had -- on a full year, a scroll away.
  ///
  /// BALANCE is the one that decides anything, so it is the only card that is
  /// filled rather than outlined: green when the student is clear, amber
  /// while anything is outstanding. REFUND appears only when there is one; an
  /// always-visible zero is noise on the ledgers that never had a refund.
  Widget _ledgerSummaryBand({
    required double demand,
    required double concess,
    required double collected,
    required double refund,
    required double balance,
  }) {
    final settled = balance <= 0;
    const green = AppColors.success;
    const amber = AppColors.warning;
    const red = AppColors.error;
    const violet = AppColors.info;

    Widget card(String icon, Color color, String label, String value,
            {bool filled = false, bool last = false}) =>
        Expanded(
          child: Container(
            margin: EdgeInsets.only(right: last ? 0 : 10.w),
            padding: EdgeInsets.symmetric(horizontal: 13.w, vertical: 10.h),
            decoration: filled
                ? BoxDecoration(
                    color: color.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppUI.cardRadius),
                    border: Border.all(color: color.withValues(alpha: 0.35)),
                  )
                : AppUI.card(),
            child: Row(
              children: [
                AppUI.iconTile(icon, color: color, size: 16),
                SizedBox(width: 10.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppUI.caps),
                      SizedBox(height: 2.h),
                      Text(value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 17.sp,
                              fontWeight: FontWeight.w800,
                              color: filled ? color : AppColors.textPrimary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

    // Flush left and right, so the row of cards spans exactly the width of the
    // grid below. Every report table here is an unpadded Expanded child; a
    // band inset by 12 stood proud of the grid underneath it.
    return Padding(
      padding: EdgeInsets.only(bottom: 10.h),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            card('receipt-2', AppColors.demand, 'DEMAND', _formatNumber(demand)),
            card('discount-shape', violet, 'CONCESSION', _formatNumber(concess)),
            card('money-recive', green, 'COLLECTED', _formatNumber(collected)),
            if (refund != 0)
              card('money-send', red, 'REFUND', _formatNumber(refund)),
            card(settled ? 'tick-circle' : 'wallet-money', settled ? green : amber,
                'BALANCE', _formatNumber(balance),
                filled: true, last: true),
          ],
        ),
      ),
    );
  }

  Widget _pagerBar({required int total, required int page, VoidCallback? onPrev, VoidCallback? onNext}) {
    if (total <= _tablePageSize) return const SizedBox.shrink();
    final start = total == 0 ? 0 : page * _tablePageSize + 1;
    final end = ((page + 1) * _tablePageSize).clamp(0, total);
    final pages = ((total + _tablePageSize - 1) ~/ _tablePageSize).clamp(1, 9999);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.divider))),
      child: Row(
        children: [
          Text(AppUI.showing(start, end, total), style: AppUI.muted),
          const Spacer(),
          IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left_rounded), tooltip: 'Previous'),
          Text('Page ${page + 1} of $pages', style: AppUI.label),
          IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right_rounded), tooltip: 'Next'),
        ],
      ),
    );
  }

  Future<void> _exportPendingPaymentExcel(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass, double grandPending, double grandConcess) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Pending Payment'];
      excel.delete('Sheet1');
      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(bold: true, fontSize: 10);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      row++;
      if (_insAddress.isNotEmpty) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
        row++;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('PENDING PAYMENT REPORT AS ON ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.TextCellValue('Date: ${_formatDate(DateTime.now())}');
      row += 2;

      const headers = ['Course', 'Class', 'Semester', 'Type', 'Admission Type', 'Register No', 'Name', 'Pending Amount', 'Concession Amount', 'Quota', 'Mobile No'];
      // A school has no admission type or quota: those columns are left out
      // and the ones after them close up. oc() maps a column to its place.
      final hidden = isSchool ? const {4, 9} : const <int>{};
      int oc(int c) => c - hidden.where((h) => h < c).length;
      for (int c = 0; c < headers.length; c++) {
        if (hidden.contains(c)) continue;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(c), rowIndex: row)).value = xl.TextCellValue(schoolTerm(headers[c]));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(c), rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      for (final entry in byClass.entries) {
        for (final r in entry.value) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['course']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(r['class']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['semester']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['seqtype']?.toString() ?? '');
          if (!isSchool) sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(r['admname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(5), rowIndex: row)).value = xl.TextCellValue(r['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(6), rowIndex: row)).value = xl.TextCellValue(r['stuname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(7), rowIndex: row)).value = xl.DoubleCellValue((r['pending'] as double?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(7), rowIndex: row)).cellStyle = numStyle;
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(8), rowIndex: row)).value = xl.DoubleCellValue((r['concession'] as double?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(8), rowIndex: row)).cellStyle = numStyle;
          if (!isSchool) sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).value = xl.TextCellValue(r['quoname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(10), rowIndex: row)).value = xl.TextCellValue(r['stumobile']?.toString() ?? '');
          row++;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('Sub Total');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(7), rowIndex: row)).value = xl.DoubleCellValue(entry.value.fold<double>(0, (s, r) => s + (r['pending'] as double)));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(7), rowIndex: row)).cellStyle = totalStyle;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(8), rowIndex: row)).value = xl.DoubleCellValue(entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double)));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(8), rowIndex: row)).cellStyle = totalStyle;
        row++;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('Grand Total');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(7), rowIndex: row)).value = xl.DoubleCellValue(grandPending);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(7), rowIndex: row)).cellStyle = totalStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(8), rowIndex: row)).value = xl.DoubleCellValue(grandConcess);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: oc(8), rowIndex: row)).cellStyle = totalStyle;

      // Name is the widest, Admn Type next; Type only holds Regular/Arrear.
      for (int c = 0; c < headers.length; c++) {
        if (hidden.contains(c)) continue;
        sheet.setColumnWidth(oc(c), c == 6 ? 22 : (c == 4 ? 18 : (c == 3 ? 11 : 14)));
      }

      await _saveExcel(excel, 'Pending_Payment_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export to Excel. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  Future<void> _exportPendingPaymentPdf(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass, double grandPending, double grandConcess) async {
    try {
      final pdf = pw.Document();
      final data = <List<String>>[];
      for (final entry in byClass.entries) {
        for (final r in entry.value) {
          // A school has no admission type or quota: those two columns go.
          data.add([
            r['course']?.toString() ?? '',
            r['class']?.toString() ?? '',
            r['semester']?.toString() ?? '',
            r['seqtype']?.toString() ?? '',
            if (!isSchool) r['admname']?.toString() ?? '',
            r['stuadmno']?.toString() ?? '',
            r['stuname']?.toString() ?? '',
            _formatNumber((r['pending'] as double?) ?? 0),
            _formatNumber((r['concession'] as double?) ?? 0),
            if (!isSchool) r['quoname']?.toString() ?? '',
            r['stumobile']?.toString() ?? '',
          ]);
        }
        data.add(['', 'Sub Total', '', '', if (!isSchool) '', '', '',
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['pending'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double))),
          if (!isSchool) '', '']);
      }
      data.add(['', 'Grand Total', '', '', if (!isSchool) '', '', '', _formatNumber(grandPending), _formatNumber(grandConcess), if (!isSchool) '', '']);

      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('PENDING PAYMENT REPORT AS ON ${_formatDate(DateTime.now())}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Date: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.Table.fromTextArray(
            headers: [schoolTerm('COURSE'), schoolTerm('CLASS'), schoolTerm('SEMESTER'), 'TYPE', if (!isSchool) 'ADMISSION TYPE', schoolTerm('REGISTER NO'), 'NAME', 'PENDING AMOUNT', 'CONCESSION AMOUNT', if (!isSchool) 'QUOTA', 'MOBILE NO'],
            data: data,
            headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignments: isSchool
                ? {6: pw.Alignment.centerRight, 7: pw.Alignment.centerRight}
                : {7: pw.Alignment.centerRight, 8: pw.Alignment.centerRight},
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      await _savePdf(pdf, 'Pending_Payment_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the PDF. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // TAB: STUDENT LEDGER (per-student fee ledger)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  List<Map<String, dynamic>> _studentsForLedger() {
    final map = <String, Map<String, dynamic>>{};
    for (final d in _allDemands) {
      final admno = d['stuadmno']?.toString() ?? '';
      if (admno.isEmpty || map.containsKey(admno)) continue;
      // The STUDENT's course and class, not the demand's.
      //
      // A course transfer keeps the old course's settled demands and adds the
      // new course's, so one student owns demand rows under both. Reading the
      // course off the demand listed them under each one -- the same student
      // appeared in B.E-EEE and B.E-ECE, with whichever header the first
      // matching demand happened to carry. stu_course / stu_class come from
      // the students row, so there is exactly one answer. A server that
      // predates them falls back to the demand, which is how this behaved
      // before.
      final course = (d['stu_course'] ?? d['courname'])?.toString() ?? '';
      final cls = (d['stu_class'] ?? d['stuclass'])?.toString() ?? '';
      // Respect the All Courses / All Classes dropdowns at the top.
      if (_selectedCourse != null && course != _selectedCourse) continue;
      if (_selectedClasses.isNotEmpty && !_selectedClasses.contains(cls)) continue;
      map[admno] = {
        'stuadmno': admno,
        'stuname': d['stuname']?.toString() ?? '',
        'courname': course,
        'stuclass': cls,
        // Deliberately NOT filtered by _tcFilter: a student who has left still
        // has a ledger, and it is the one report you look at to find out what
        // they left owing. The list marks them instead.
        'tcissued': ((d['stuactive'] as num?)?.toInt() ?? 1) != 1,
      };
    }
    return map.values.toList()
      ..sort((a, b) => (a['stuadmno'] as String).compareTo(b['stuadmno'] as String));
  }

  /// The ledger student's photo for the strip: one small lookup by reg no.
  /// Display only -- a failure (or a newer pick) just leaves the initial.
  Future<void> _loadLedgerPhoto(int insId, String admno) async {
    try {
      final row = await SupabaseService.fromSchema('students')
          .select('stuphoto')
          .eq('ins_id', insId)
          .eq('stuadmno', admno)
          .limit(1)
          .maybeSingle();
      if (!mounted || _ledgerStuAdmNo != admno) return;
      setState(() => _ledgerPhoto = row?['stuphoto']?.toString());
    } catch (_) {}
  }

  Future<void> _loadStudentLedger(String admno) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null) return;
    setState(() {
      _ledgerStuAdmNo = admno;
      _ledgerLoading = true;
      _ledgerDemands = [];
      _ledgerMisc = [];
      _ledgerAdv = [];
      _ledgerPayments = {};
      _ledgerAlloc = {};
      _ledgerConcDet = {};
      _ledgerRefDet = {};
      _ledgerTc = null;
      _ledgerStudent = _studentsForLedger().firstWhere(
        (s) => s['stuadmno'] == admno,
        orElse: () => {'stuadmno': admno},
      );
      _ledgerPhoto = null;
    });
    _loadLedgerPhoto(insId, admno);
    try {
      final miscFuture = _loadLedgerMisc(insId, admno);
      final advFuture = _loadLedgerAdvance(insId, admno);
      final tcFuture = _loadLedgerTc(insId, admno);
      final result = await SupabaseService.client.rpc('get_student_ledger_report', params: {
        'p_schema': schema,
        'p_ins_id': insId,
        'p_stuadmno': admno,
      });
      final list = result is List ? List<Map<String, dynamic>>.from(result) : <Map<String, dynamic>>[];
      final misc = await miscFuture;
      final adv = await advFuture;
      final tc = await tcFuture;
      // Enrich with demseqtype / demfeeyear straight from feedemand when the
      // ledger RPC predates those columns (so the Regular / Arrear split works
      // without waiting on add_ledger_demseqtype.sql). Matched on fee
      // type + term + amount (amount disambiguates a regular vs arrear line of
      // the same fee type).
      if (list.isNotEmpty && list.first['demseqtype'] == null) {
        try {
          final fd = await SupabaseService.fromSchema('feedemand')
              .select('demfeetype, demfeeterm, demseqtype, demfeeyear, feeamount')
              .eq('ins_id', insId)
              .eq('stuadmno', admno)
              .eq('activestatus', 1);
          String key(Map r) => '${r['demfeetype']}|${r['demfeeterm']}|${(r['feeamount'] as num?)?.toDouble() ?? 0}';
          final lookup = <String, Map<String, dynamic>>{};
          for (final r in List<Map<String, dynamic>>.from(fd as List)) {
            lookup[key(r)] = r;
          }
          for (final row in list) {
            final m = lookup[key(row)];
            if (m != null) {
              row['demseqtype'] = m['demseqtype'];
              row['demfeeyear'] = m['demfeeyear'];
            }
          }
        } catch (e) {
          debugPrint('ledger demseqtype enrich error: $e');
        }
      }
      // Resolve each ledger row to its dem_id (the RPC doesn't return one), then
      // pull the receipt / concession / refund detail for those demands.
      final alloc = <int, List<Map<String, dynamic>>>{};
      final concDet = <int, List<Map<String, dynamic>>>{};
      final refDet = <int, List<Map<String, dynamic>>>{};
      try {
        final fd = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('feedemand')
            .select('dem_id, demfeetype, demfeeterm, feeamount, demno, createdat, duedate, demseqtype')
            .eq('ins_id', insId)
            .eq('stuadmno', admno)
            .eq('activestatus', 1));
        // The key must include REGULAR vs ARREAR.
        //
        // A student repeating a year owes the same fee twice: last year's
        // carried-forward arrear and this year's regular demand -- same fee
        // type, same term, same amount. On type|term|amount alone the two
        // collided, so both ledger lines took ONE dem_id and one doc number:
        // the arrear's AF26/... printed against both rows, and every
        // collection matched to that dem_id was shown twice.
        //
        // Normalised to REGULAR/ARREAR rather than compared raw: the RPC
        // COALESCEs a null demseqtype to 'DEMAND' while feedemand leaves it
        // null, so the two sides would never have matched on the literal.
        String seq(Map r) =>
            (r['demseqtype']?.toString().toUpperCase().contains('ARREAR') ?? false)
                ? 'ARREAR'
                : 'REGULAR';
        String k(Map r) =>
            '${r['demfeetype']}|${r['demfeeterm']}|${(r['feeamount'] as num?)?.toDouble() ?? 0}|${seq(r)}';
        final idOf = <String, int>{};
        final demRow = <String, Map<String, dynamic>>{};
        for (final r in fd) {
          final id = (r['dem_id'] as num?)?.toInt();
          if (id != null) {
            idOf[k(r)] = id;
            demRow[k(r)] = r;
          }
        }
        for (final row in list) {
          final id = idOf[k(row)];
          if (id != null) row['dem_id'] = id;
          // The Demand line of the transaction register needs the demand's own
          // date and document number; the ledger RPC returns neither.
          final m = demRow[k(row)];
          if (m != null) {
            row['demno'] = m['demno'];
            row['demdate'] = m['createdat'] ?? m['duedate'];
          }
        }
        final demIds = idOf.values.toList();
        if (demIds.isNotEmpty) {
          // One collection line per RECEIPT that touched the demand.
          final pd = await SupabaseService.fetchAll(() => SupabaseService
              .fromSchema('paymentdetails')
              .select('dem_id, pay_id, transtotalamount')
              .eq('ins_id', insId)
              .inFilter('dem_id', demIds));
          final payIds =
              pd.map((e) => (e['pay_id'] as num?)?.toInt()).whereType<int>().toSet().toList();
          final pays = <int, Map<String, dynamic>>{};
          if (payIds.isNotEmpty) {
            final pr = await SupabaseService.fetchAll(() => SupabaseService
                .fromSchema('payment')
                .select('pay_id, paynumber, paydate, activestatus, paystatus')
                .eq('ins_id', insId)
                .inFilter('pay_id', payIds));
            for (final r in pr) {
              // A voided receipt (activestatus 9) never belongs on a ledger.
              if (((r['activestatus'] as num?)?.toInt() ?? 1) == 9) continue;
              // NOR DOES A PAYMENT THAT NEVER SUCCEEDED.
              //
              // A failed or still-initiated attempt keeps its paymentdetails
              // rows -- complete_payment_grouped writes one per demand even
              // when it is recording a failure, so the attempt can be audited.
              // Counting those as money collected doubled the ledger: a
              // student whose 50,125 failed once and then paid showed 1,00,250
              // collected and a balance of -50,125, and another showed a nil
              // balance while Fee Collection still listed 35,225 as due. The
              // giveaway is a collection line with no DOC NO -- a failed
              // payment never gets a receipt number.
              //
              // 'C' collected, 'R' refunded (the money did arrive; the refund
              // is its own ledger line). Same rule the daily collection report
              // uses.
              final st = r['paystatus']?.toString();
              if (st != 'C' && st != 'R') continue;
              pays[(r['pay_id'] as num).toInt()] = Map<String, dynamic>.from(r);
            }
          }
          for (final r in pd) {
            final d = (r['dem_id'] as num?)?.toInt();
            final pid = (r['pay_id'] as num?)?.toInt();
            if (d == null || pid == null) continue;
            final pay = pays[pid];
            if (pay == null) continue;
            (alloc[d] ??= []).add({
              'amount': (r['transtotalamount'] as num?)?.toDouble() ?? 0,
              'docno': pay['paynumber']?.toString() ?? '',
              'docdate': pay['paydate']?.toString() ?? '',
            });
          }
          // Concession vouchers against these demands, with their doc numbers.
          try {
            final cd = await SupabaseService.fetchAll(() => SupabaseService
                .fromSchema('concessiondetail')
                .select('dem_id, conamount, con_hdr_id, condate, activestatus')
                .eq('ins_id', insId)
                .inFilter('dem_id', demIds));
            final hdrIds =
                cd.map((e) => (e['con_hdr_id'] as num?)?.toInt()).whereType<int>().toSet().toList();
            final hdrs = <int, Map<String, dynamic>>{};
            final voidedHdrs = <int>{};
            if (hdrIds.isNotEmpty) {
              final ch = await SupabaseService.fetchAll(() => SupabaseService
                  .fromSchema('concession')
                  .select('con_hdr_id, doc_no, condate, activestatus')
                  .eq('ins_id', insId)
                  .inFilter('con_hdr_id', hdrIds));
              for (final r in ch) {
                // A cancelled voucher never belongs on a ledger — same rule the
                // receipt lines already follow.
                if (((r['activestatus'] as num?)?.toInt() ?? 1) == 9) {
                  voidedHdrs.add((r['con_hdr_id'] as num).toInt());
                  continue;
                }
                hdrs[(r['con_hdr_id'] as num).toInt()] = Map<String, dynamic>.from(r);
              }
            }
            for (final r in cd) {
              final d = (r['dem_id'] as num?)?.toInt();
              final amt = (r['conamount'] as num?)?.toDouble() ?? 0;
              if (d == null || amt <= 0.004) continue;
              if (((r['activestatus'] as num?)?.toInt() ?? 1) == 9) continue;
              final hid = (r['con_hdr_id'] as num?)?.toInt() ?? -1;
              if (voidedHdrs.contains(hid)) continue;
              final h = hdrs[hid];
              (concDet[d] ??= []).add({
                'amount': amt,
                'docno': h?['doc_no']?.toString() ?? '',
                'docdate': (h?['condate'] ?? r['condate'])?.toString() ?? '',
              });
            }
          } catch (_) {/* concession tables not deployed yet */}
          // Refunds against these demands, with their doc numbers.
          try {
            final rd = await SupabaseService.fetchAll(() => SupabaseService
                .fromSchema('fee_refunddetails')
                .select('dem_id, refundamount, rf_id, activestatus')
                .eq('ins_id', insId)
                .inFilter('dem_id', demIds));
            final rfIds =
                rd.map((e) => (e['rf_id'] as num?)?.toInt()).whereType<int>().toSet().toList();
            final rfs = <int, Map<String, dynamic>>{};
            final voidedRfs = <int>{};
            if (rfIds.isNotEmpty) {
              final rh = await SupabaseService.fetchAll(() => SupabaseService
                  .fromSchema('fee_refund')
                  .select('rf_id, doc_no, refunddate, activestatus')
                  .eq('ins_id', insId)
                  .inFilter('rf_id', rfIds));
              for (final r in rh) {
                // A cancelled refund is not money that left — drop it, so
                // voiding a mistaken voucher actually clears the ledger.
                if (((r['activestatus'] as num?)?.toInt() ?? 1) == 9) {
                  voidedRfs.add((r['rf_id'] as num).toInt());
                  continue;
                }
                rfs[(r['rf_id'] as num).toInt()] = Map<String, dynamic>.from(r);
              }
            }
            for (final r in rd) {
              final d = (r['dem_id'] as num?)?.toInt();
              final amt = (r['refundamount'] as num?)?.toDouble() ?? 0;
              if (d == null || amt <= 0.004) continue;
              if (((r['activestatus'] as num?)?.toInt() ?? 1) == 9) continue;
              final rid = (r['rf_id'] as num?)?.toInt() ?? -1;
              if (voidedRfs.contains(rid)) continue;
              final h = rfs[rid];
              (refDet[d] ??= []).add({
                'amount': amt,
                'docno': h?['doc_no']?.toString() ?? '',
                'docdate': h?['refunddate']?.toString() ?? '',
              });
            }
          } catch (_) {/* refund tables not deployed yet */}
        }
      } catch (e) {
        debugPrint('ledger detail load error: $e');
      }

      // Synthesize a pseudo pay_id keyed by paynumber so the renderer's
      // d['pay_id'] lookup against _ledgerPayments still works.
      final payMap = <int, Map<String, dynamic>>{};
      for (var i = 0; i < list.length; i++) {
        final pn = list[i]['paynumber']?.toString();
        if (pn == null || pn.isEmpty) continue;
        final pid = pn.hashCode;
        list[i]['pay_id'] = pid;
        payMap[pid] = {'paynumber': pn, 'paydate': list[i]['paydate']};
      }
      if (mounted) {
        setState(() {
          _ledgerDemands = list;
          _ledgerMisc = misc;
          _ledgerAdv = adv;
          _ledgerPayments = payMap;
          _ledgerAlloc = alloc;
          _ledgerConcDet = concDet;
          _ledgerRefDet = refDet;
          _ledgerTc = tc;
          _ledgerLoading = false;
        });
      }
    } catch (e) {
      debugPrint('student ledger error: $e');
      if (mounted) setState(() => _ledgerLoading = false);
    }
  }

  /// Advances taken from this student. Like a misc collection they settle no
  /// demand of their own -- the money is HELD -- so they move no balance here.
  ///
  /// An ADMISSION advance was collected fee type by fee type and is listed that
  /// way; a STUDENT advance is a plain amount and gets one ADVANCE line.
  Future<List<Map<String, dynamic>>> _loadLedgerAdvance(
      int insId, String admno) async {
    try {
      final ac = await SupabaseService.fromSchema('advance_collection')
          .select('adv_id, advno, advdate, advtype, transtotalamount, adjustedamount')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('paystatus', 'C')
          .eq('stuadmno', admno)
          .order('advdate', ascending: true);
      final headers = List<Map<String, dynamic>>.from(ac as List);
      if (headers.isEmpty) return [];
      final ids = headers.map((h) => h['adv_id']).where((id) => id != null).toList();
      final byAdv = <dynamic, List<Map<String, dynamic>>>{};
      try {
        final det = await SupabaseService.fromSchema('advance_detail')
            .select('adv_id, feetype, amount')
            .eq('activestatus', 1)
            .inFilter('adv_id', ids);
        for (final d in List<Map<String, dynamic>>.from(det as List)) {
          (byAdv[d['adv_id']] ??= []).add(d);
        }
      } catch (_) {
        // No breakdown table: every advance falls back to a single line.
      }
      final rows = <Map<String, dynamic>>[];
      for (final h in headers) {
        final raw = h['advdate']?.toString() ?? '';
        final date = raw.length >= 10 ? raw.substring(0, 10) : raw;
        final total = (h['transtotalamount'] as num?)?.toDouble() ?? 0;
        final lines = byAdv[h['adv_id']] ?? const <Map<String, dynamic>>[];
        if (lines.isEmpty) {
          rows.add({
            'feetype': 'ADVANCE',
            'amount': total,
            'docno': h['advno']?.toString() ?? '',
            'docdate': date,
            'advtype': h['advtype']?.toString() ?? 'S',
          });
        } else {
          for (final d in lines) {
            rows.add({
              'feetype': d['feetype']?.toString() ?? 'ADVANCE',
              'amount': (d['amount'] as num?)?.toDouble() ?? 0,
              'docno': h['advno']?.toString() ?? '',
              'docdate': date,
              'advtype': h['advtype']?.toString() ?? 'S',
            });
          }
        }
        // Whatever has since been applied to this student's fees. It shows as
        // its own NEGATIVE line, because the demand it settled already carries
        // that money as a collection -- without this the column would count the
        // same rupee twice, once on the day it arrived and again on the day it
        // was spent.
        final used = (h['adjustedamount'] as num?)?.toDouble() ?? 0;
        if (used > 0.005) {
          rows.add({
            'feetype': 'ADVANCE',
            'amount': -used,
            'docno': h['advno']?.toString() ?? '',
            'docdate': date,
            'advtype': h['advtype']?.toString() ?? 'S',
            'adjusted': true,
          });
        }
      }
      return rows;
    } catch (e) {
      // Advance module not deployed on this database.
      debugPrint('ledger advance load error: $e');
      return [];
    }
  }

  /// Miscellaneous collections for this student (collection-only; no demand).
  /// Matched by registration number (regno = admission no).
  /// The TC on record for [admno], or null.
  ///
  /// tc_entry is append-only, so re-activating a student appends a row with no
  /// number; those are skipped, exactly as the Transfer Certificate screen does
  /// it, so the number that was actually issued is the one that shows.
  Future<Map<String, dynamic>?> _loadLedgerTc(int insId, String admno) async {
    try {
      final rows = await SupabaseService.fromSchema('tc_entry')
          .select('tc_id, tcno, tcdate, effectfrom, status')
          .eq('ins_id', insId)
          .eq('stuadmno', admno)
          .eq('activestatus', 1)
          .order('tc_id', ascending: true);
      Map<String, dynamic>? last;
      for (final r in List<Map<String, dynamic>>.from(rows as List)) {
        if ((r['tcno'] ?? '').toString().trim().isEmpty) continue;
        last = r;
      }
      return last;
    } catch (e) {
      // No tc_entry table on this database yet — the ledger simply shows no
      // TC line rather than failing to open.
      debugPrint('ledger TC lookup: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _loadLedgerMisc(int insId, String admno) async {
    try {
      final mc = await SupabaseService.fromSchema('misc_collection')
          .select('mc_id, mcno, mcdate')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('regno', admno)
          .order('mcdate', ascending: true);
      final headers = List<Map<String, dynamic>>.from(mc as List);
      if (headers.isEmpty) return [];
      final mcIds = headers.map((h) => h['mc_id']).where((id) => id != null).toList();
      final details = await SupabaseService.fromSchema('misc_collection_detail')
          .select('mc_id, feetype, amount')
          .eq('activestatus', 1)
          .inFilter('mc_id', mcIds);
      final byMc = <dynamic, List<Map<String, dynamic>>>{};
      for (final d in List<Map<String, dynamic>>.from(details as List)) {
        (byMc[d['mc_id']] ??= []).add(d);
      }
      final rows = <Map<String, dynamic>>[];
      for (final h in headers) {
        final raw = h['mcdate']?.toString() ?? '';
        final date = raw.length >= 10 ? raw.substring(0, 10) : raw;
        for (final d in (byMc[h['mc_id']] ?? const [])) {
          rows.add({
            'feetype': d['feetype']?.toString() ?? 'Misc',
            'amount': (d['amount'] as num?)?.toDouble() ?? 0,
            'docno': h['mcno']?.toString() ?? '',
            'docdate': date,
          });
        }
      }
      return rows;
    } catch (e) {
      debugPrint('ledger misc error: $e');
      return [];
    }
  }

  /// dd-MM-yyyy for display; the ISO form is kept separately for sorting.
  String _fmtDay(String iso) {
    if (iso.length < 10) return iso;
    final p = iso.substring(0, 10).split('-');
    return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : iso;
  }

  /// The ledger as a chronological TRANSACTION REGISTER: one row per event —
  /// Demand, Regular / Arrear / Misc Collection, Concession, Refund — each
  /// carrying its own amount column, ordered by date, with a running balance.
  ///
  /// Balance movement (balance = what the student still owes):
  ///   Demand      + net demand
  ///   Collection  − amount
  ///   Concession  − amount
  ///   Refund      + amount   (money handed back is owed again)
  ///   Misc        no movement — a misc collection has no demand behind it.
  ///
  /// The concession a demand already carried when it was raised stays on the
  /// Demand row; concessions granted later appear as their own dated rows. The
  /// two always add up to feedemand.conamount, so no concession is counted
  /// twice and none goes missing.
  List<Map<String, dynamic>> _ledgerLines() {
    String d10(dynamic v) {
      final t = v?.toString() ?? '';
      return t.length >= 10 ? t.substring(0, 10) : t;
    }

    bool isArr(Map d) =>
        (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';

    final ev = <Map<String, dynamic>>[];

    for (final d in _ledgerDemands) {
      final demId = (d['dem_id'] as num?)?.toInt();
      final feetype = d['demfeetype']?.toString() ?? '';
      final term = d['demfeeterm']?.toString() ?? '';
      final arrear = isArr(d);
      final fee = (d['feeamount'] as num?)?.toDouble() ?? 0;
      final conTotal = (d['conamount'] as num?)?.toDouble() ?? 0;
      final demDate = d10(d['demdate']);

      final concs = demId == null
          ? const <Map<String, dynamic>>[]
          : (_ledgerConcDet[demId] ?? const <Map<String, dynamic>>[]);
      final voucherCon =
          concs.fold<double>(0, (t, c) => t + ((c['amount'] as num?)?.toDouble() ?? 0));
      final baseCon = (conTotal - voucherCon).clamp(0.0, conTotal > 0 ? conTotal : 0.0);

      ev.add({
        'sort': demDate, 'seq': 0, 'kind': 'data',
        'type': 'Demand',
        'date': _fmtDay(demDate),
        'details': term,
        'feetype': feetype,
        'demand': fee,
        'concess': baseCon > 0.004 ? baseCon : null,
        'net': fee - baseCon,
        'collection': null, 'refund': null, 'fine': null,
        'docno': d['demno']?.toString() ?? '',
        'delta': fee - baseCon,
      });

      // A receipt carries balance + fine, so peel the demand's fine off the
      // earliest receipt that touched it — otherwise the fine would be double
      // counted, once inside Collection and once in its own column.
      var fineLeft = (d['fineamount'] as num?)?.toDouble() ?? 0;
      final receipts = demId == null
          ? const <Map<String, dynamic>>[]
          : (_ledgerAlloc[demId] ?? const <Map<String, dynamic>>[]);
      for (final r in receipts) {
        var amt = (r['amount'] as num?)?.toDouble() ?? 0;
        double? f;
        if (fineLeft > 0.004) {
          f = fineLeft > amt ? amt : fineLeft;
          amt -= f;
          fineLeft -= f;
        }
        final dt = d10(r['docdate']);
        ev.add({
          'sort': dt, 'seq': 1, 'kind': 'data',
          'type': arrear ? 'Arrear Collection' : 'Regular Collection',
          'date': _fmtDay(dt),
          'details': term,
          'feetype': feetype,
          'demand': null, 'concess': null, 'net': null,
          'collection': amt, 'refund': null, 'fine': f,
          'docno': r['docno']?.toString() ?? '',
          // Only the fee portion moves the balance. The fine is shown in its
          // own column but never entered the balance as a charge -- there is no
          // demand row for it, because a fine is not part of the demand.
          // Subtracting it here drove the closing balance negative by exactly
          // the fine (Demand 32,325 = Collection 32,325, yet it read -100).
          'delta': -amt,
        });
      }

      for (final c in concs) {
        final amt = (c['amount'] as num?)?.toDouble() ?? 0;
        final dt = d10(c['docdate']);
        ev.add({
          'sort': dt, 'seq': 2, 'kind': 'data',
          'type': 'Concession',
          'date': _fmtDay(dt),
          'details': term,
          'feetype': feetype,
          'demand': null, 'concess': amt, 'net': null,
          'collection': null, 'refund': null, 'fine': null,
          'docno': c['docno']?.toString() ?? '',
          'delta': -amt,
        });
      }

      final refs = demId == null
          ? const <Map<String, dynamic>>[]
          : (_ledgerRefDet[demId] ?? const <Map<String, dynamic>>[]);
      for (final r in refs) {
        final amt = (r['amount'] as num?)?.toDouble() ?? 0;
        final dt = d10(r['docdate']);
        ev.add({
          'sort': dt, 'seq': 3, 'kind': 'data',
          'type': 'Refund',
          'date': _fmtDay(dt),
          'details': term,
          'feetype': feetype,
          'demand': null, 'concess': null, 'net': null,
          'collection': null, 'refund': amt, 'fine': null,
          'docno': r['docno']?.toString() ?? '',
          'delta': amt,
        });
      }
    }

    // Misc collections have no demand behind them, so they move no balance.
    for (final m in _ledgerMisc) {
      final dt = d10(m['docdate']);
      ev.add({
        'sort': dt, 'seq': 4, 'kind': 'data',
        'type': 'Misc Collection',
        'date': _fmtDay(dt),
        'details': 'Miscellaneous',
        'feetype': m['feetype']?.toString() ?? 'Misc',
        'demand': null, 'concess': null, 'net': null,
        'collection': (m['amount'] as num?)?.toDouble() ?? 0,
        'refund': null, 'fine': null,
        'docno': m['docno']?.toString() ?? '',
        'delta': 0.0,
      });
    }

    // Advances move no balance either: the money is held against the student
    // until it is applied, and the demand it is applied to carries it then.
    for (final a in _ledgerAdv) {
      final dt = d10(a['docdate']);
      final isAdjusted = a['adjusted'] == true;
      ev.add({
        'sort': dt, 'seq': 4, 'kind': 'data',
        'type': isAdjusted
            ? 'Advance Adjusted'
            : switch ((a['advtype']?.toString() ?? 'S').toUpperCase()) {
                'A' => 'Advance (Admission)',
                'M' => 'Advance (Mess)',
                _ => 'Advance',
              },
        'date': _fmtDay(dt),
        'details': isAdjusted ? 'Applied to fees' : 'Advance received',
        'feetype': a['feetype']?.toString() ?? 'ADVANCE',
        'demand': null, 'concess': null, 'net': null,
        'collection': (a['amount'] as num?)?.toDouble() ?? 0,
        'refund': null, 'fine': null,
        'docno': a['docno']?.toString() ?? '',
        'delta': 0.0,
      });
    }

    // EVENT KIND first, date second -- so every Demand is listed before any
    // Collection, then concessions and refunds (seq 0..4).
    //
    // Sorting by date first read wrong: a demand raised in September sat BELOW
    // a July collection against it, so the running balance went negative and
    // only returned to zero on the last line. A ledger has to raise the charge
    // before it settles it, so the balance falls from the demand total to nil.
    // ISO dates still sort lexicographically within each kind.
    ev.sort((a, b) {
      final c = (a['seq'] as int).compareTo(b['seq'] as int);
      return c != 0 ? c : (a['sort'] as String).compareTo(b['sort'] as String);
    });

    var running = 0.0;
    for (final e in ev) {
      running += (e['delta'] as double?) ?? 0;
      e['balance'] = running;
    }
    return ev;
  }

  /// "TC ISSUED" on a ledger whose student has left, with the certificate's
  /// number and date when there is one on record.
  ///
  /// It is a statement of fact, not a warning: the balance below it is still
  /// owed, and this is what tells the reader why nobody is chasing it.
  /// "TC ISSUED • <no> • <date>", or '' when this student holds no TC.
  ///
  /// Shared by the screen badge, the Excel sheet and the PDF: a ledger that is
  /// mailed to someone has to carry the same fact the screen shows, or the
  /// balance on it reads as an ordinary unpaid due.
  String get _ledgerTcText {
    if (_ledgerStudent?['tcissued'] != true && _ledgerTc == null) return '';
    final no = (_ledgerTc?['tcno'] ?? '').toString().trim();
    final date = _ledgerTc?['tcdate'];
    return <String>[
      'TC Issued',
      if (no.isNotEmpty) no,
      if (date != null && date.toString().isNotEmpty) _fmtDcbDate(date.toString()),
    ].join('  •  ');
  }

  Widget _ledgerTcBadge() {
    return AppUI.chip(_ledgerTcText, AppStatus.warning);
  }

  /// Amount cell for the ledger: blank when there is nothing to show, so only
  /// the column that a transaction actually moved carries a figure.
  String _amt(double? v) => (v == null || v.abs() < 0.005) ? '' : _formatNumber(v);

  Widget _buildStudentLedger() {
    final students = _studentsForLedger();
    final headerStyle = AppUI.tableHead;
    final cellStyle = AppUI.cell;

    // One row per transaction, oldest first, with a running balance.
    final lines = _ledgerLines();
    double totDemand = 0, totConcess = 0, totCollection = 0, totRefund = 0, totFine = 0;
    for (final l in lines) {
      if (l['kind'] != 'data') continue;
      totDemand += (l['demand'] as double?) ?? 0;
      totConcess += (l['concess'] as double?) ?? 0;
      totCollection += (l['collection'] as double?) ?? 0;
      totRefund += (l['refund'] as double?) ?? 0;
      totFine += (l['fine'] as double?) ?? 0;
    }
    // Net Demand is derived, not summed: only Demand rows carry a net, so
    // adding the column would ignore every concession granted later.
    final totNetDemand = totDemand - totConcess;
    // The closing balance is the last running value, NOT a column sum.
    final totBalance = lines.isEmpty ? 0.0 : ((lines.last['balance'] as double?) ?? 0);

    return Column(
      // tab-body-open
      children: [
        Container(
          padding: EdgeInsets.only(bottom: 10.h),
          child: Row(
            children: [
              _reportTitle('book-1', 'Student Ledger', 'Fee history and balance for each student'),
              if (_ledgerLoading) ...[
                SizedBox(width: 12.w),
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
              ],
              const Spacer(),
              SizedBox(
                width: 360.w,
                child: Autocomplete<Map<String, dynamic>>(
                  // The list carries students who have left, so it has to say
                  // which ones they are.
                  displayStringForOption: (o) =>
                      '${o['stuadmno']} - ${o['stuname']}'
                      '${o['tcissued'] == true ? '  •  TC Issued' : ''}',
                  optionsBuilder: (value) {
                    final q = value.text.toLowerCase();
                    if (q.isEmpty) return students.take(20);
                    return students.where((s) =>
                        (s['stuadmno'] as String).toLowerCase().contains(q) ||
                        (s['stuname'] as String).toLowerCase().contains(q)).take(20);
                  },
                  onSelected: (s) => _loadStudentLedger(s['stuadmno'] as String),
                  fieldViewBuilder: (ctx, ctrl, focus, onSubmit) {
                    _ledgerSearchCtrl.value = ctrl.value;
                    return TextField(
                      controller: ctrl,
                      focusNode: focus,
                      style: AppUI.fieldText(ctx),
                      // Enter opens the highlighted suggestion. Without
                      // this the list could only be picked from with
                      // the mouse: typing a roll number in full and
                      // pressing Enter did nothing at all.
                      onSubmitted: (_) => onSubmit(),
                      decoration: AppUI.field(ctx, schoolTerm('Search by register no. or name'), leadingIcon: 'search-normal'),
                    );
                  },
                ),
              ),
              SizedBox(width: 8.w),
              if (_ledgerStudent != null) ...[
                _miniExportBtn(
                  onPressed: () => setState(() {
                    _ledgerStuAdmNo = null;
                    _ledgerStudent = null;
                    _ledgerDemands = [];
                    _ledgerPayments = {};
                  }),
                  icon: Icons.close_rounded,
                  label: 'Clear',
                  secondary: true,
                ),
                SizedBox(width: AppBtn.gap(context)),
              ],
              _miniExportBtn(
                onPressed: _ledgerDemands.isEmpty ? () {} : _exportStudentLedgerExcel,
                icon: Icons.table_chart_rounded,
                label: AppText.exportExcel,
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _ledgerDemands.isEmpty ? () {} : _exportStudentLedgerPdf,
                icon: Icons.picture_as_pdf_rounded,
                label: AppText.exportPdf,
              ),
            ],
          ),
        ),
        if (_ledgerStudent != null && _ledgerDemands.isNotEmpty) ...[
          // WHO, not WHERE. The institution name and address were the first
          // two lines on screen -- they belong on the PRINTED ledger, which
          // leaves the building, and they still are there. On screen the
          // reader already knows the college; what they need is the student.
          _ledgerStudentStrip(),
          // THE ANSWER, BEFORE THE WORKING.
          //
          // The four figures anyone opens this screen for were only in the
          // footer, under however many rows the student had -- on a full year
          // that is a scroll away. The table still carries them; this just
          // stops the reader having to reach the bottom to learn the balance.
          _ledgerSummaryBand(
            demand: totDemand,
            concess: totConcess,
            collected: totCollection,
            refund: totRefund,
            balance: totBalance,
          ),
          Expanded(
            child: _stickyTable(
              // Demand rows read amber, collections green, refunds red --
              // a ledger is two opposite kinds of line and the eye should not
              // have to read the TRANSACTION TYPE column to tell them apart.
              // Anything else keeps the ordinary zebra stripe.
              rowTints: [
                for (final l in lines)
                  switch ((l['type'] as String? ?? '').toUpperCase()) {
                    final t when t.contains('DEMAND') => AppColors.warningBg,
                    final t when t.contains('REFUND') => AppColors.errorBg,
                    final t when t.contains('COLLECTION') => AppColors.successBg,
                    _ => null,
                  },
              ],
              // Twelve columns on one screen: the type is a size down and the
              // gutter a size up, so DATE stops truncating and the figures stop
              // crowding the column beside them.
              cellFontSize: 11.5,
              headerFontSize: 10.5,
              cellGap: 12,
              columnWidths: const [105, 145, 130, 150, 100, 105, 110, 105, 95, 80, 115, 105],
              headers: const ['DATE', 'TRANSACTION TYPE', 'DETAILS', 'FEE TYPE', 'DEMAND', 'CONCESSION', 'NET DEMAND', 'COLLECTION', 'REFUND', 'FINE', 'DOCUMENT NO', 'BALANCE'],
              rows: [
                for (final l in lines)
                  [
                    l['date'] as String? ?? '',
                    l['type'] as String? ?? '',
                    l['details'] as String? ?? '',
                    l['feetype'] as String? ?? '',
                    _amt(l['demand'] as double?),
                    _amt(l['concess'] as double?),
                    _amt(l['net'] as double?),
                    _amt(l['collection'] as double?),
                    _amt(l['refund'] as double?),
                    _amt(l['fine'] as double?),
                    l['docno'] as String? ?? '',
                    _formatNumber((l['balance'] as double?) ?? 0),
                  ],
              ],
              footer: [
                'Total', '', '', '',
                _formatNumber(totDemand),
                _formatNumber(totConcess),
                _formatNumber(totNetDemand),
                _formatNumber(totCollection),
                _formatNumber(totRefund),
                _formatNumber(totFine),
                '',
                _formatNumber(totBalance),
              ],
              numericCols: const {4, 5, 6, 7, 8, 9, 11},
            ),
          ),
        ] else if (students.isNotEmpty) ...[
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.cardBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: AppVerticalScrollbar(
                header: Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    child: Row(
                      children: [
                        Expanded(child: Text(schoolTerm('ROLL NUMBER'), style: headerStyle)),
                        Expanded(child: Text('STUDENT NAME', style: headerStyle)),
                        Expanded(child: Text(schoolTerm('COURSE'), style: headerStyle)),
                        Expanded(child: Text(schoolTerm('CLASS'), style: headerStyle)),
                      ],
                    ),
                  ),
                builder: (context, controller) => ListView.separated(
                      controller: controller,
                      itemCount: students.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (ctx, i) {
                        final s = students[i];
                        return InkWell(
                          onTap: () => _loadStudentLedger(s['stuadmno']),
                          child: Container(
                            color: i.isOdd ? AppColors.surface : Colors.white,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                            child: Row(
                              children: [
                                Expanded(child: Text(s['stuadmno'] ?? '-', style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: AppColors.primary))),
                                Expanded(child: Text(s['stuname'] ?? '-', style: cellStyle, overflow: TextOverflow.ellipsis)),
                                Expanded(child: Text(s['courname'] ?? '-', style: cellStyle)),
                                Expanded(child: Text(s['stuclass'] ?? '-', style: cellStyle)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                ),
            ),
          ),
        ] else
          Expanded(child: _emptyState(schoolTerm('Select a course and class, or search for a student'))),
      ],
    );
  }

  Future<void> _exportStudentLedgerExcel() async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Student Ledger'];
      excel.delete('Sheet1');

      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(bold: true, fontSize: 10);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      row++;
      if (_insAddress.isNotEmpty) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
        row++;
      }
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('STUDENT LEDGER');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.TextCellValue('DATE: ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).cellStyle = boldStyle;
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('Student Name : ${_ledgerStudent?['stuname'] ?? ''}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue('${schoolTerm('Register No')} : ${_ledgerStudent?['stuadmno'] ?? ''}');
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(schoolTerm('Course : ${_ledgerStudent?['courname'] ?? ''}'));
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(schoolTerm('Class : ${_ledgerStudent?['stuclass'] ?? ''}'));
      row++;
      // A student who has left: say so on the sheet, or the balance below reads
      // as an ordinary pending due.
      if (_ledgerTcText.isNotEmpty) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value =
            xl.TextCellValue(_ledgerTcText);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
        row++;
      }
      row++;

      final headers = ['Date', 'Transaction Type', 'Details', 'Fee Type', 'Demand', 'Concession', 'Net Demand', 'Collection', 'Refund', 'Fine', 'Document No', 'Balance'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      final lines = _ledgerLines();
      double totDemand = 0, totConcess = 0, totCollection = 0, totRefund = 0, totFine = 0;

      void put(int col, double? v) {
        if (v == null || v.abs() < 0.005) return;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row)).value = xl.DoubleCellValue(v);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row)).cellStyle = numStyle;
      }

      for (final l in lines) {
        final demand = l['demand'] as double?;
        final conc = l['concess'] as double?;
        final collection = l['collection'] as double?;
        final refund = l['refund'] as double?;
        final fine = l['fine'] as double?;
        totDemand += demand ?? 0;
        totConcess += conc ?? 0;
        totCollection += collection ?? 0;
        totRefund += refund ?? 0;
        totFine += fine ?? 0;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(l['date'] as String? ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(l['type'] as String? ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(l['details'] as String? ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(l['feetype'] as String? ?? '');
        put(4, demand);
        put(5, conc);
        put(6, l['net'] as double?);
        put(7, collection);
        put(8, refund);
        put(9, fine);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: row)).value = xl.TextCellValue(l['docno'] as String? ?? '');
        put(11, l['balance'] as double?);
        row++;
      }

      // Net Demand is derived and Balance is the closing figure — neither is a
      // sum of its column.
      final totNetDemand = totDemand - totConcess;
      final totBalance = lines.isEmpty ? 0.0 : ((lines.last['balance'] as double?) ?? 0);

      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('Total');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      for (final e in <int, double>{4: totDemand, 5: totConcess, 6: totNetDemand,
                                    7: totCollection, 8: totRefund, 9: totFine,
                                    11: totBalance}.entries) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: e.key, rowIndex: row)).value = xl.DoubleCellValue(e.value);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: e.key, rowIndex: row)).cellStyle = totalStyle;
      }

      sheet.setColumnWidth(0, 12);
      sheet.setColumnWidth(1, 20);
      sheet.setColumnWidth(2, 16);
      sheet.setColumnWidth(3, 22);
      for (int c = 4; c < 12; c++) sheet.setColumnWidth(c, 13);

      await _saveExcel(excel, 'Student_Ledger_${_ledgerStudent?['stuadmno'] ?? ''}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export to Excel. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  Future<void> _exportStudentLedgerPdf() async {
    try {
      final pdf = pw.Document();
      final lines = _ledgerLines();
      double totDemand = 0, totConcess = 0, totCollection = 0, totRefund = 0, totFine = 0;
      final rows = <List<String>>[];
      for (final l in lines) {
        final demand = l['demand'] as double?;
        final conc = l['concess'] as double?;
        final collection = l['collection'] as double?;
        final refund = l['refund'] as double?;
        final fine = l['fine'] as double?;
        totDemand += demand ?? 0;
        totConcess += conc ?? 0;
        totCollection += collection ?? 0;
        totRefund += refund ?? 0;
        totFine += fine ?? 0;
        rows.add([
          l['date'] as String? ?? '',
          l['type'] as String? ?? '',
          l['details'] as String? ?? '',
          l['feetype'] as String? ?? '',
          _amt(demand), _amt(conc), _amt(l['net'] as double?),
          _amt(collection), _amt(refund), _amt(fine),
          l['docno'] as String? ?? '',
          _formatNumber((l['balance'] as double?) ?? 0),
        ]);
      }
      final totNetDemand = totDemand - totConcess;
      final totBalance = lines.isEmpty ? 0.0 : ((lines.last['balance'] as double?) ?? 0);
      rows.add(['Total', '', '', '',
        _formatNumber(totDemand), _formatNumber(totConcess), _formatNumber(totNetDemand),
        _formatNumber(totCollection), _formatNumber(totRefund), _formatNumber(totFine),
        '', _formatNumber(totBalance)]);

      pdf.addPage(pw.MultiPage(
        // 12 columns don't fit portrait.
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('STUDENT LEDGER', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('DATE: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 4),
            pw.Text('Student Name: ${_ledgerStudent?['stuname'] ?? ''}    ${schoolTerm('Register No')}: ${_ledgerStudent?['stuadmno'] ?? ''}', style: const pw.TextStyle(fontSize: 9)),
            pw.Text(schoolTerm('Course: ${_ledgerStudent?['courname'] ?? ''}    Class: ${_ledgerStudent?['stuclass'] ?? ''}'), style: const pw.TextStyle(fontSize: 9)),
            if (_ledgerTcText.isNotEmpty)
              pw.Text(_ledgerTcText,
                  style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.Table.fromTextArray(
            headers: ['Date', 'Transaction Type', 'Details', 'Fee Type', 'Demand', 'Concession', 'Net Demand', 'Collection', 'Refund', 'Fine', 'Document No', 'Balance'],
            data: rows,
            headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 7.5),
            cellAlignments: {for (int i = 4; i < 10; i++) i: pw.Alignment.centerRight, 11: pw.Alignment.centerRight},
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      await _savePdf(pdf, 'Student_Ledger_${_ledgerStudent?['stuadmno'] ?? ''}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the PDF. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // TAB: DAILY COLLECTION (receipt-wise pivot by fee type)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildDailyCollection() {
    String fmt(DateTime? d) => d == null ? '' : '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

    Widget quick(String label, VoidCallback onTap) => Padding(
          padding: EdgeInsets.only(left: 4.w),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(label, style: AppUI.label.copyWith(color: AppColors.textSecondary)),
            ),
          ),
        );

    final headerStyle = AppUI.tableHead;
    final cellStyle = AppUI.cell;

    final visibleRows = _dailyRows.where(_dailyRowVisible).toList();

    // Refunds never appear in the collection table nor affect Total Collected;
    // they are listed only in the Excel / PDF exports (separate section).
    final collectionRows = visibleRows.where((r) => (r['type']?.toString() ?? '') != 'Refunded').toList();

    // Money taken at the counter that no one has matched to a bank statement
    // yet. Same filters as the table above, listed separately below it: it is
    // real collection, but it is not confirmed, so it must never be added into
    // Total Collected.
    final unrecRows = _dailyUnrecRows
        .where(_dailyRowVisible)
        .where((r) => (r['type']?.toString() ?? '') != 'Refunded')
        .toList();

    // Columns narrow with the SAME predicate the rows do. If they did not, a
    // HOSTEL FEES filter would drop college receipts from the table while
    // still showing college columns -- and the column totals would count
    // money the table no longer lists.
    final visibleFeeTypes = _feeFilterActive
        ? _dailyFeeTypes.where(_feeTypeAllowed).toList()
        : _dailyFeeTypes;

    // When fee types are selected, narrow the row total down to the sum of
    // just those fees + the row's fine. With no filter, use the full receipt
    // total. CASH/CHEQUE/BANK columns and the footer follow this same total.
    double rowDisplayTotal(Map<String, dynamic> r) {
      // Refunds are NOT collections — they belong to their own refund date and
      // are listed as separate details below, so they never affect Total
      // Collected (the original receipt stays a full collection on its own day).
      if ((r['type']?.toString() ?? '') == 'Refunded') return 0;
      final fine = (r['fine'] as num?)?.toDouble() ?? 0;
      if (_selectedFeeTypes.isEmpty) {
        return (r['total'] as num?)?.toDouble() ?? 0;
      }
      final fees = r['fees'] as Map<String, double>;
      double sum = 0;
      for (final ft in _selectedFeeTypes) {
        sum += fees[ft] ?? 0;
      }
      return sum + fine;
    }

    // What came off an advance, and what therefore actually changed hands.
    double rowAdjusted(Map<String, dynamic> r) =>
        (r['adjusted'] as num?)?.toDouble() ?? 0;
    // NET AMT = TOTAL - ADJUSTED. Clamped at zero: with a fee-type filter on,
    // rowDisplayTotal counts only the chosen types while the adjustment is the
    // whole receipt's, so the subtraction can overshoot.
    double rowNetTotal(Map<String, dynamic> r) {
      final n = rowDisplayTotal(r) - rowAdjusted(r);
      return n > 0 ? n : 0;
    }

    // Total Collected comes ONLY from real collections (refunds are excluded).
    double totalAmt = 0;
    double totalFine = 0;
    // Settled from an advance rather than taken today. Its own column and its
    // own total: it is NOT added into Total Collected, because that rupee was
    // counted on the day the advance was received.
    double totalAdj = 0;
    // The money: TOTAL less what came off advances.
    double totalNet = 0;
    final ftTotals = <String, double>{};
    for (final r in collectionRows) {
      totalAmt += rowDisplayTotal(r);
      totalFine += (r['fine'] as num?)?.toDouble() ?? 0;
      totalAdj += rowAdjusted(r);
      totalNet += rowNetTotal(r);
      final fees = r['fees'] as Map<String, double>;
      for (final ft in visibleFeeTypes) {
        final v = fees[ft] ?? 0;
        ftTotals[ft] = (ftTotals[ft] ?? 0) + v;
      }
    }

    return Column(
      // tab-body-open
      children: [
        Container(
          padding: EdgeInsets.only(bottom: 10.h),
          child: Row(
            children: [
              _reportTitle('calendar-1', 'Daily Collection', 'Fee collection by date range'),
              SizedBox(width: 8.w),
              if (_dailyLoading)
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
              const Spacer(),
              Builder(builder: (_) {
                // Filled = any date/mode/user filter is active -> amber.
                final filled = _dailyFrom != null || _dailyTo != null || _selectedMode != null || _selectedUser != null;
                return SizedBox(
                  height: AppBtn.height(context),
                  child: OutlinedButton.icon(
                    onPressed: _openDailyDateMethodDialog,
                    icon: Icon(Icons.calendar_today, size: AppBtn.iconSize(context), color: filled ? AppColors.primary : AppColors.textSecondary),
                    label: Text(
                      _dailyDateMethodLabel(),
                      style: AppUI.label.copyWith(color: filled ? AppColors.primary : AppColors.textSecondary),
                    ),
                  ),
                );
              }),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _dailyNothingToExport ? () {} : () => _exportDailyCollectionExcel(),
                icon: Icons.table_chart_rounded,
                label: AppText.exportExcel,
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _dailyNothingToExport ? () {} : () => _exportDailyCollectionPdf(),
                icon: Icons.picture_as_pdf_rounded,
                label: AppText.exportPdf,
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _dailyNothingToExport ? () {} : () => _printDailyStatement(),
                icon: Icons.print_rounded,
                label: 'Print',
              ),
            ],
          ),
        ),
        Expanded(
          child: collectionRows.isEmpty
              // A failure and a genuinely empty range must not read the same.
              ? _emptyState(_dailyError ?? 'No collections in this range')
              : Builder(builder: (_) {
                  final showCash = _selectedMode == null || _selectedMode == 'cash';
                  // Cheque/DD report under BANK (see _paymentBucket), so there is no
                  // separate CHEQUE column.
                  // ignore: prefer_const_declarations
                  final showCheque = false;
                  final showBank = _selectedMode == null || _selectedMode == 'bank';
                  double totalCash = 0;
                  double totalCheque = 0;
                  double totalBank = 0;
                  for (final r in collectionRows) {
                    // The drawer and the bank only ever see the NET: an advance
                    // put its money there on the day it was taken.
                    final money = rowNetTotal(r);
                    final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
                    if (bucket == 'cash') {
                      totalCash += money;
                    } else if (bucket == 'cheque') {
                      totalCheque += money;
                    } else {
                      totalBank += money;
                    }
                  }
                  final headers = <String>[
                    'DATE', 'RECEIPT NO', schoolTerm('REGISTER NO'), 'STUDENT NAME', schoolTerm('COURSE'), schoolTerm('CLASS'), schoolTerm('SEMESTER'), 'TYPE',
                    ...visibleFeeTypes.map((t) => t.toUpperCase()),
                    'FINE', 'TOTAL',
                    if (showCash) 'CASH',
                    if (showCheque) 'CHEQUE',
                    if (showBank) 'BANK',
                    'ADJUSTED',
                    'NET AMOUNT',
                  ];
                  final widths = <double>[
                    // TYPE (the 8th) carries the longest labels on the sheet --
                    // 'Advance (Admission)' and 'Advance Adjusted' -- and at 110
                    // both truncated to 'Advance (Ad...'.
                    110, 130, 130, 200, 140, 150, 140, 175,
                    ...visibleFeeTypes.map((t) {
                      // Enough width for full uppercase label ("NEW ADMISSION FEES" etc.)
                      final len = t.length;
                      return (len > 14 ? 200.0 : len > 10 ? 170.0 : 140.0);
                    }),
                    100, 130,
                    if (showCash) 120,
                    if (showCheque) 120,
                    if (showBank) 120,
                    130,
                    130,
                  ];
                  // Numeric (right-aligned) columns start after the 8 text
                  // columns: DATE, RECEIPT NO, REG NO, NAME, COURSE, CLASS, SEMESTER, TYPE.
                  final numericCols = <int>{
                    for (int i = 8; i < headers.length; i++) i,
                  };
                  return _stickyTable(
                    columnWidths: widths,
                    headers: headers,
                    rows: [
                      for (final r in collectionRows.skip(_dailyPage * _tablePageSize).take(_tablePageSize))
                        () {
                          final fees = r['fees'] as Map<String, double>;
                          final fine = (r['fine'] as num?)?.toDouble() ?? 0;
                          final total = rowDisplayTotal(r);
                          final adj = rowAdjusted(r);
                          final net = rowNetTotal(r);
                          final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
                          final pd = DateTime.tryParse(r['paydate']?.toString() ?? '');
                          // A cancelled receipt is LISTED for audit but shows no
                          // paid amount — blank every money column. (Refunds are
                          // never here — they're in the separate Refunds section.)
                          final cancelled = (r['type']?.toString() ?? '') == 'Cancelled';
                          final typeText = r['type']?.toString() ?? 'Regular';
                          return <String>[
                            pd != null ? _formatDate(pd) : (r['paydate']?.toString() ?? ''),
                            r['paynumber']?.toString() ?? '',
                            r['stuadmno']?.toString() ?? '',
                            r['stuname']?.toString() ?? '',
                            r['courname']?.toString() ?? '',
                            r['stuclass']?.toString() ?? '',
                            r['semester']?.toString() ?? '',
                            typeText,
                            ...visibleFeeTypes.map((ft) => (!cancelled && fees[ft] != null && fees[ft] != 0) ? _formatNumber(fees[ft]!) : ''),
                            (!cancelled && fine != 0) ? _formatNumber(fine) : '',
                            cancelled ? '' : _formatNumber(total),
                            if (showCash) ((!cancelled && bucket == 'cash' && net > 0) ? _formatNumber(net) : ''),
                            if (showCheque) ((!cancelled && bucket == 'cheque' && net > 0) ? _formatNumber(net) : ''),
                            if (showBank) ((!cancelled && bucket == 'bank' && net > 0) ? _formatNumber(net) : ''),
                            (!cancelled && adj > 0) ? _formatNumber(adj) : '',
                            cancelled ? '' : _formatNumber(net),
                          ];
                        }(),
                    ],
                    footer: <String>[
                      'TOTAL', '', '', '', '', '', '', '',
                      ...visibleFeeTypes.map((ft) => _formatNumber(ftTotals[ft] ?? 0)),
                      _formatNumber(totalFine),
                      _formatNumber(totalAmt),
                      if (showCash) _formatNumber(totalCash),
                      if (showCheque) _formatNumber(totalCheque),
                      if (showBank) _formatNumber(totalBank),
                      _formatNumber(totalAdj),
                      _formatNumber(totalNet),
                    ],
                    numericCols: numericCols,
                  );
                }),
        ),
        _pagerBar(
          total: collectionRows.length,
          page: _dailyPage,
          onPrev: _dailyPage > 0 ? () => setState(() => _dailyPage--) : null,
          onNext: (_dailyPage + 1) * _tablePageSize < collectionRows.length
              ? () => setState(() => _dailyPage++)
              : null,
        ),
        // Receipts still awaiting bank reconciliation. Deliberately below the
        // main table and with its own total: the figure above is the confirmed
        // one, and merging the two would overstate what has actually landed.
        // Bounded height so it sits under the Expanded table rather than
        // fighting it for space.
        if (unrecRows.isNotEmpty) ...[
          SizedBox(height: 10.h),
          Builder(builder: (_) {
            double unrecTotal = 0;
            double unrecFine = 0;
            for (final r in unrecRows) {
              unrecTotal += rowDisplayTotal(r);
              unrecFine += (r['fine'] as num?)?.toDouble() ?? 0;
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 6.h),
                  child: Row(children: [
                    Icon(Icons.schedule_rounded, size: 16, color: AppColors.warning),
                    SizedBox(width: 6.w),
                    Text('UNRECONCILED',
                        style: AppUI.caps.copyWith(color: AppColors.warning)),
                    SizedBox(width: 8.w),
                    Flexible(
                      child: Text('Collected but not yet matched to a bank statement',
                          overflow: TextOverflow.ellipsis,
                          style: AppUI.muted),
                    ),
                    const Spacer(),
                    AppUI.chip(
                        '${unrecRows.length} receipt${unrecRows.length == 1 ? '' : 's'}  ·  ${_formatNumber(unrecTotal)}',
                        AppStatus.warning),
                  ]),
                ),
                SizedBox(
                  height: 190.h,
                  child: _stickyTable(
                    columnWidths: const [110, 130, 130, 200, 150, 140, 130, 100, 130],
                    headers: [
                      'DATE', 'RECEIPT NO', schoolTerm('REGISTER NO'), 'STUDENT NAME', schoolTerm('CLASS'),
                      schoolTerm('SEMESTER'), 'MODE', 'FINE', 'TOTAL',
                    ],
                    rows: [
                      for (final r in unrecRows)
                        () {
                          final pd = DateTime.tryParse(r['paydate']?.toString() ?? '');
                          final fine = (r['fine'] as num?)?.toDouble() ?? 0;
                          return <String>[
                            pd != null ? _formatDate(pd) : (r['paydate']?.toString() ?? ''),
                            r['paynumber']?.toString() ?? '',
                            r['stuadmno']?.toString() ?? '',
                            r['stuname']?.toString() ?? '',
                            r['stuclass']?.toString() ?? '',
                            r['semester']?.toString() ?? '',
                            r['paymethod']?.toString() ?? '',
                            fine != 0 ? _formatNumber(fine) : '',
                            _formatNumber(rowDisplayTotal(r)),
                          ];
                        }(),
                    ],
                    footer: <String>[
                      'TOTAL', '', '', '', '', '', '',
                      _formatNumber(unrecFine),
                      _formatNumber(unrecTotal),
                    ],
                    numericCols: const {7, 8},
                  ),
                ),
              ],
            );
          }),
        ],
        // Refunds are shown in the Excel / PDF exports (separate section) — not
        // on-screen, to keep this view focused on collections.
      ],
    );
  }


  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // TAB 1: COLLECTION STATEMENT (fee amounts by term)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildCollectionStatement() {
    final demands = _filteredDemands;
    final terms = _getTermColumns(demands);
    final pivotData = _buildPivotData(demands, terms, showPending: true);
    if (pivotData.isEmpty) return _emptyState('No fee data found', why: 'Nothing matches the current filters -- change them above or press Refresh.');

    // Calculate totals per term
    final Map<String, double> termTotals = {};
    for (final row in pivotData) {
      for (final t in terms) {
        termTotals[t] = (termTotals[t] ?? 0) + (row[t] as double? ?? 0);
      }
    }

    return _buildReportTable(
      title: 'PENDING FEE REPORT AS ON ${_formatDate(DateTime.now())}',
      subtitle: 'FEE TYPE : ${_selectedFeeTypes.isEmpty ? 'ALL FEE TYPE' : _selectedFeeTypes.join(', ')}',
      terms: terms,
      pivotData: pivotData,
      termTotals: termTotals,
      showPending: true,
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // TAB 2: PENDING - COURSE WISE
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildPendingCourseWise() {
    final demands = _filteredDemands.where((d) {
      final balance = (d['balancedue'] as num?)?.toDouble() ?? 0;
      return balance > 0;
    }).toList();
    final terms = _getTermColumns(demands);

    // Group by course
    final Map<String, List<Map<String, dynamic>>> courseGroups = {};
    for (final d in demands) {
      final course = d['courname']?.toString() ?? 'Unknown';
      courseGroups.putIfAbsent(course, () => []).add(d);
    }

    if (courseGroups.isEmpty) return _emptyState('No pending fees found', why: 'Nothing matches the current filters -- change them above or press Refresh.');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Export button
          Padding(
            padding: EdgeInsets.all(12.w),
            child: Row(
              children: [
                Text(schoolTerm('PENDING FEE REPORT - COURSE WISE'),
                    style: AppUI.cardTitle),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _exportPendingReport(demands, terms, 'Course_Wise'),
                  icon: Icon(Icons.download_rounded, size: 16.sp),
                  label: const Text('Export Excel'),
                ),
              ],
            ),
          ),
          ...courseGroups.entries.map((entry) {
            final courseName = entry.key;
            final courseDemands = entry.value;
            final pivotData = _buildPivotData(courseDemands, terms, showPending: true);
            final Map<String, double> termTotals = {};
            for (final row in pivotData) {
              for (final t in terms) {
                termTotals[t] = (termTotals[t] ?? 0) + (row[t] as double? ?? 0);
              }
            }
            final grandTotal = termTotals.values.fold<double>(0, (s, v) => s + v);

            return Container(
              margin: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
              clipBehavior: Clip.antiAlias,
              decoration: AppUI.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                    decoration: AppUI.tableHeadBar,
                    child: Row(
                      children: [
                        Text(courseName, style: AppUI.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.primary)),
                        const Spacer(),
                        Text('${pivotData.length} students', style: AppUI.muted),
                        SizedBox(width: 16.w),
                        Text('Total Pending: ${_formatNumber(grandTotal)}',
                            style: AppUI.money.copyWith(color: AppColors.error)),
                      ],
                    ),
                  ),
                  _buildDataTable(terms, pivotData, termTotals),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // TAB 3: PENDING - YEAR WISE
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildPendingYearWise() {
    final demands = _filteredDemands.where((d) {
      final balance = (d['balancedue'] as num?)?.toDouble() ?? 0;
      return balance > 0;
    }).toList();
    final terms = _getTermColumns(demands);

    // Group by class (year)
    final Map<String, List<Map<String, dynamic>>> classGroups = {};
    for (final d in demands) {
      final cls = d['stuclass']?.toString() ?? 'Unknown';
      classGroups.putIfAbsent(cls, () => []).add(d);
    }

    if (classGroups.isEmpty) return _emptyState('No pending fees found', why: 'Nothing matches the current filters -- change them above or press Refresh.');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(12.w),
            child: Row(
              children: [
                Text('PENDING FEE REPORT - YEAR WISE',
                    style: AppUI.cardTitle),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _exportPendingReport(demands, terms, 'Year_Wise'),
                  icon: Icon(Icons.download_rounded, size: 16.sp),
                  label: const Text('Export Excel'),
                ),
              ],
            ),
          ),
          ...classGroups.entries.map((entry) {
            final className = entry.key;
            final classDemands = entry.value;
            final pivotData = _buildPivotData(classDemands, terms, showPending: true);
            final Map<String, double> termTotals = {};
            for (final row in pivotData) {
              for (final t in terms) {
                termTotals[t] = (termTotals[t] ?? 0) + (row[t] as double? ?? 0);
              }
            }
            final grandTotal = termTotals.values.fold<double>(0, (s, v) => s + v);

            return Container(
              margin: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
              clipBehavior: Clip.antiAlias,
              decoration: AppUI.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                    decoration: AppUI.tableHeadBar,
                    child: Row(
                      children: [
                        Text(className, style: AppUI.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.primary)),
                        const Spacer(),
                        Text('${pivotData.length} students', style: AppUI.muted),
                        SizedBox(width: 16.w),
                        Text('Total Pending: ${_formatNumber(grandTotal)}',
                            style: AppUI.money.copyWith(color: AppColors.error)),
                      ],
                    ),
                  ),
                  _buildDataTable(terms, pivotData, termTotals),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // SHARED TABLE BUILDER
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildReportTable({
    required String title,
    required String subtitle,
    required List<String> terms,
    required List<Map<String, dynamic>> pivotData,
    required Map<String, double> termTotals,
    required bool showPending,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title & export
        Padding(
          padding: EdgeInsets.all(12.w),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppUI.cardTitle),
                  Text(subtitle, style: AppUI.muted),
                ],
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _exportCollectionStatement(pivotData, terms, termTotals),
                icon: Icon(Icons.download_rounded, size: 16.sp),
                label: const Text('Export Excel'),
              ),
            ],
          ),
        ),
        // Totals row
        Container(
          margin: EdgeInsets.symmetric(horizontal: 12.w),
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: AppColors.tableHeadBg,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
          ),
          child: Row(
            children: [
              Text('${pivotData.length} Students', style: AppUI.label.copyWith(color: AppColors.primary)),
              const Spacer(),
              ...terms.map((t) => Padding(
                padding: EdgeInsets.only(left: 12.w),
                child: Column(
                  children: [
                    Text(t, style: AppUI.caps),
                    Text(_formatNumber(termTotals[t] ?? 0), style: AppUI.money),
                  ],
                ),
              )),
            ],
          ),
        ),
        SizedBox(height: 8.h),
        // Data table
        Expanded(
            child: _buildDataTable(terms, pivotData, termTotals,
                bounded: true)),
      ],
    );
  }

  Widget _buildDataTable(List<String> terms, List<Map<String, dynamic>> pivotData, Map<String, double> termTotals, {bool bounded = false}) {
    // Group by course + class for display.
    final Map<String, List<Map<String, dynamic>>> classGroups = {};
    for (final row in pivotData) {
      final course = row['courname']?.toString() ?? '';
      final cls = row['stuclass']?.toString() ?? 'Unknown';
      final key = course.isNotEmpty ? '$course - $cls' : cls;
      classGroups.putIfAbsent(key, () => []).add(row);
    }

    // Fixed column widths - the pivot is wide (one column per term) and
    // scrolls horizontally, so the header can't use flex.
    final colWidths = <double>[
      54, 92, 112, 190,
      for (final _ in terms) 96,
      86, 100, 140,
    ];
    final tableWidth = colWidths.fold<double>(0, (a, b) => a + b);
    final headers = <String>[
      'SNO', schoolTerm('CLASS'), 'ADMN. NO', 'STUDENT NAME',
      for (final t in terms) t.toUpperCase(),
      'FINE', 'TOTAL', 'REMARKS',
    ];
    final lastNumericIdx = 5 + terms.length; // term columns + FINE + TOTAL
    bool rightAlign(int i) => i >= 4 && i <= lastNumericIdx;

    final hStyle = AppUI.tableHead;
    Widget cell(int i, Widget child) => SizedBox(
          width: colWidths[i],
          child: Align(
            alignment: rightAlign(i)
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: child,
            ),
          ),
        );

    // Flatten student rows + per-class total rows into row widgets.
    final rowWidgets = <Widget>[];
    int sno = 0;
    var zebra = false;
    for (final entry in classGroups.entries) {
      final Map<String, double> classTotals = {};
      double classGrandTotal = 0;
      double classTotalFine = 0;
      for (final row in entry.value) {
        sno++;
        final rowTotal = (row['_total'] as double?) ?? 0;
        final rowFine = (row['_fine'] as double?) ?? 0;
        classGrandTotal += rowTotal;
        classTotalFine += rowFine;
        for (final t in terms) {
          final val = (row[t] as double?) ?? 0;
          if (val > 0) classTotals[t] = (classTotals[t] ?? 0) + val;
        }
        final cs = AppUI.cell;
        rowWidgets.add(Container(
          color: zebra ? AppColors.surface : Colors.white,
          padding: EdgeInsets.symmetric(vertical: 8.h),
          child: Row(children: [
            cell(0, Text('$sno', style: cs)),
            cell(1, Text(row['stuclass']?.toString() ?? '', style: cs)),
            cell(2, Text(row['stuadmno']?.toString() ?? '', style: cs)),
            cell(3,
                Text(row['stuname']?.toString() ?? '',
                    style: cs, overflow: TextOverflow.ellipsis)),
            for (var ti = 0; ti < terms.length; ti++)
              cell(4 + ti, Builder(builder: (_) {
                final v = (row[terms[ti]] as double?) ?? 0;
                return Text(v > 0 ? _formatNumber(v) : '', style: cs);
              })),
            cell(
                4 + terms.length,
                Text(rowFine > 0 ? _formatNumber(rowFine) : '',
                    style: AppUI.cell.copyWith(color: AppColors.warning))),
            cell(
                5 + terms.length,
                Text(rowTotal > 0 ? _formatNumber(rowTotal) : '',
                    style: AppUI.money)),
            cell(
                6 + terms.length,
                Text(row['_remarks']?.toString() ?? '',
                    style: AppUI.muted)),
          ]),
        ));
        zebra = !zebra;
      }
      // Per-class total row.
      rowWidgets.add(Container(
        color: AppColors.tableHeadBg,
        padding: EdgeInsets.symmetric(vertical: 8.h),
        child: Row(children: [
          cell(0, const SizedBox()),
          cell(
              1,
              Text('Total',
                  style: AppUI.money)),
          cell(2, const SizedBox()),
          cell(3, const SizedBox()),
          for (var ti = 0; ti < terms.length; ti++)
            cell(
                4 + ti,
                Text(
                    (classTotals[terms[ti]] ?? 0) > 0
                        ? _formatNumber(classTotals[terms[ti]]!)
                        : '',
                    style: AppUI.money)),
          cell(
              4 + terms.length,
              Text(classTotalFine > 0 ? _formatNumber(classTotalFine) : '',
                  style: AppUI.money.copyWith(color: AppColors.warning))),
          cell(
              5 + terms.length,
              Text(
                  classGrandTotal > 0
                      ? _formatNumber(classGrandTotal)
                      : '',
                  style: AppUI.money)),
          cell(6 + terms.length, const SizedBox()),
        ]),
      ));
    }

    final header = Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(vertical: 10.h),
      child: Row(children: [
        for (var i = 0; i < headers.length; i++)
          cell(i, Text(headers[i], style: hStyle)),
      ]),
    );

    // bounded: a fixed-height host (Collection Statement) - sticky header +
    // internally scrolling body, so the table fills the height. Otherwise the
    // table is content-sized and the page scrolls (course/class section
    // views). Either way it gets its own horizontal bar when it overflows.
    return _HScrollTable(
      contentWidth: tableWidth,
      expand: bounded,
      child: bounded
            ? Column(
                children: [
                  header,
                  Container(height: 1, color: AppColors.border),
                  Expanded(
                    child: AppVerticalScrollbar(
                      builder: (context, sc) =>
                          ListView(controller: sc, children: rowWidgets),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  header,
                  Container(height: 1, color: AppColors.border),
                  ...rowWidgets,
                ],
              ),
    );
  }

  Widget _emptyState(String message, {String? why}) => AppUI.empty(icon: 'chart-1', title: message, why: why);

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // EXCEL EXPORT: COLLECTION STATEMENT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _exportCollectionStatement(List<Map<String, dynamic>> pivotData, List<String> terms, Map<String, double> termTotals) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Pending Fees'];
      excel.delete('Sheet1');

      final darkHeader = xl.CellStyle(
        bold: true, fontSize: 14,
        backgroundColorHex: xl.ExcelColor.fromHexString('#1E2532'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        horizontalAlign: xl.HorizontalAlign.Center,
      );
      final subHeader = xl.CellStyle(bold: true, fontSize: 11);
      final colHeader = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final totalStyle = xl.CellStyle(bold: true, fontSize: 11);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      // Columns: Sno, Class, Admn. No, Student Name, [terms], Total, Remarks
      final totalCols = 4 + terms.length + 3;

      // Institution header
      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = darkHeader;
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Center);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      final contactLine = [if (_insPhone.isNotEmpty) 'Ph: $_insPhone', if (_insEmail.isNotEmpty) 'Email: $_insEmail'].join('  |  ');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(contactLine);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Right);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;

      // Title
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('PENDING FEE REPORT AS ON ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('FEE TYPE : ${_selectedFeeTypes.isEmpty ? 'ALL FEE TYPE' : _selectedFeeTypes.join(', ')}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      row++; // blank row

      // Column headers: Sno, Class, Admn. No, Student Name, [terms], Total, Remarks
      final headers = ['Sno', schoolTerm('Class'), 'Admn. No', 'Student Name', ...terms, 'Fine', 'Total', 'Remarks'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = colHeader;
      }
      row++;

      // Group by course + class
      final Map<String, List<Map<String, dynamic>>> classGroups = {};
      for (final s in pivotData) {
        final course = s['courname']?.toString() ?? '';
        final cls = s['stuclass']?.toString() ?? 'Unknown';
        final key = course.isNotEmpty ? '$course - $cls' : cls;
        classGroups.putIfAbsent(key, () => []).add(s);
      }

      int sno = 0;
      for (final entry in classGroups.entries) {
        final classStudents = entry.value;
        final Map<String, double> classTotals = {};
        double classGrandTotal = 0;

        for (final student in classStudents) {
          sno++;
          final rowTotal = (student['_total'] as double?) ?? 0;
          classGrandTotal += rowTotal;

          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.IntCellValue(sno);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(student['stuclass']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(student['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(student['stuname']?.toString() ?? '');
          for (int c = 0; c < terms.length; c++) {
            final val = (student[terms[c]] as double?) ?? 0;
            if (val > 0) {
              classTotals[terms[c]] = (classTotals[terms[c]] ?? 0) + val;
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = numStyle;
            }
          }
          if (rowTotal > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowTotal.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          final rowFine = (student['_fine'] as double?) ?? 0;
          if (rowFine > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowFine.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6 + terms.length, rowIndex: row)).value = xl.TextCellValue(student['_remarks']?.toString() ?? '');
          row++;
        }

        // Class total row
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('Total');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = totalStyle;
        for (int c = 0; c < terms.length; c++) {
          final val = classTotals[terms[c]] ?? 0;
          if (val > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = totalStyle;
          }
        }
        if (classGrandTotal > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(classGrandTotal.toInt());
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = totalStyle;
        }
        row++;
      }

      // Column widths
      sheet.setColumnWidth(0, 6);
      sheet.setColumnWidth(1, 8);
      sheet.setColumnWidth(2, 10);
      sheet.setColumnWidth(3, 22);
      for (int c = 0; c < terms.length; c++) {
        sheet.setColumnWidth(4 + c, 12);
      }
      sheet.setColumnWidth(4 + terms.length, 8);
      sheet.setColumnWidth(5 + terms.length, 10);
      sheet.setColumnWidth(6 + terms.length, 25);

      await _saveExcel(excel, 'Pending_Fee_Report_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export to Excel. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // EXCEL EXPORT: PENDING REPORT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _exportPendingReport(List<Map<String, dynamic>> demands, List<String> terms, String groupBy) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Pending Fees'];
      excel.delete('Sheet1');

      final darkHeader = xl.CellStyle(
        bold: true, fontSize: 14,
        backgroundColorHex: xl.ExcelColor.fromHexString('#1E2532'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        horizontalAlign: xl.HorizontalAlign.Center,
      );
      final subHeader = xl.CellStyle(bold: true, fontSize: 11);
      final colHeader = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final totalStyle = xl.CellStyle(bold: true, fontSize: 11);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      // Columns: Sno, Class, Admn. No, Student Name, [terms], Total, Remarks
      final totalCols = 4 + terms.length + 3;
      int row = 0;

      // Institution header
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = darkHeader;
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Center);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      final contactLine = [if (_insPhone.isNotEmpty) 'Ph: $_insPhone', if (_insEmail.isNotEmpty) 'Email: $_insEmail'].join('  |  ');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(contactLine);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Right);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;

      // Title
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('PENDING FEE REPORT AS ON ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('FEE TYPE : ${_selectedFeeTypes.isEmpty ? 'ALL FEE TYPE' : _selectedFeeTypes.join(', ')}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      row++; // blank row

      // Column headers
      final headers = ['Sno', schoolTerm('Class'), 'Admn. No', 'Student Name', ...terms, 'Fine', 'Total', 'Remarks'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = colHeader;
      }
      row++;

      // Group by course + class
      final Map<String, List<Map<String, dynamic>>> classGroups = {};
      for (final d in demands) {
        final course = d['courname']?.toString() ?? '';
        final cls = d['stuclass']?.toString() ?? 'Unknown';
        final key = course.isNotEmpty ? '$course - $cls' : cls;
        classGroups.putIfAbsent(key, () => []).add(d);
      }

      int sno = 0;
      for (final entry in classGroups.entries) {
        final classStudents = entry.value;
        final pivotData = _buildPivotData(classStudents, terms, showPending: true);
        final Map<String, double> classTotals = {};
        double classGrandTotal = 0;

        for (final student in pivotData) {
          sno++;
          final rowTotal = (student['_total'] as double?) ?? 0;
          classGrandTotal += rowTotal;

          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.IntCellValue(sno);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(student['stuclass']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(student['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(student['stuname']?.toString() ?? '');
          for (int c = 0; c < terms.length; c++) {
            final val = (student[terms[c]] as double?) ?? 0;
            if (val > 0) {
              classTotals[terms[c]] = (classTotals[terms[c]] ?? 0) + val;
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = numStyle;
            }
          }
          if (rowTotal > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowTotal.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          final rowFine = (student['_fine'] as double?) ?? 0;
          if (rowFine > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowFine.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6 + terms.length, rowIndex: row)).value = xl.TextCellValue(student['_remarks']?.toString() ?? '');
          row++;
        }

        // Class total row
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('Total');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = totalStyle;
        for (int c = 0; c < terms.length; c++) {
          final val = classTotals[terms[c]] ?? 0;
          if (val > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = totalStyle;
          }
        }
        if (classGrandTotal > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(classGrandTotal.toInt());
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = totalStyle;
        }
        row++;
      }

      // Column widths
      sheet.setColumnWidth(0, 6);
      sheet.setColumnWidth(1, 8);
      sheet.setColumnWidth(2, 10);
      sheet.setColumnWidth(3, 22);
      for (int c = 0; c < terms.length; c++) {
        sheet.setColumnWidth(4 + c, 12);
      }
      sheet.setColumnWidth(4 + terms.length, 8);
      sheet.setColumnWidth(5 + terms.length, 10);
      sheet.setColumnWidth(6 + terms.length, 25);

      await _saveExcel(excel, 'Pending_${groupBy}_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export to Excel. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  Future<void> _exportDailyCollectionExcel() async {
    try {
      // Same predicate as the on-screen table, so an export can never disagree
      // with what was on screen when it was pressed.
      final visibleRows = _dailyRows.where(_dailyRowVisible).toList();
      // Receipts not yet matched to a bank statement — listed in their own
      // section below, never folded into the collection totals.
      final unrecRows = _dailyUnrecRows
          .where(_dailyRowVisible)
          .where((r) => (r['type']?.toString() ?? '') != 'Refunded')
          .toList();
      final feeTypes = _feeFilterActive
          ? _dailyFeeTypes.where(_feeTypeAllowed).toList()
          : _dailyFeeTypes;

      final excel = xl.Excel.createExcel();
      final sheet = excel['Daily Collection'];
      excel.delete('Sheet1');

      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      final showCash = _selectedMode == null || _selectedMode == 'cash';
      // Cheque/DD report under BANK (see _paymentBucket), so there is no
      // separate CHEQUE column.
      // ignore: prefer_const_declarations
      final showCheque = false;
      final showBank = _selectedMode == null || _selectedMode == 'bank';
      final modeCols = (showCash ? 1 : 0) + (showCheque ? 1 : 0) + (showBank ? 1 : 0);
      // 5 text columns now (Course removed): Receipt No, Reg No, Name, Class,
      // Semester -- then the fee types, fine, total, mode columns and net.
      final totalCols = 5 + feeTypes.length + 2 + modeCols + 2; // + Adjusted, Net

      int row = 0;
      void merged(String text, xl.CellStyle style) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(text);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = style;
        sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
        row++;
      }

      merged(_insName, boldStyle);
      if (_insAddress.isNotEmpty) merged(_insAddress, xl.CellStyle(fontSize: 10));
      merged('DAILY COLLECTION STATEMENT FROM ${_formatDate(_dailyFrom!)} TO ${_formatDate(_dailyTo!)}', boldStyle);
      merged('Date: ${_formatDate(DateTime.now())}', xl.CellStyle(fontSize: 10));
      // Collected-by line: specific user if filtered, otherwise derived
      // from the distinct cashiers visible in the exported rows.
      // Names a cashier only when one was filtered for -- see the A3
      // statement. 'All Users' matches the wording there.
      final exportCollectedBy = _selectedUser ?? 'All Users';
      merged('Collected By: $exportCollectedBy', boldStyle);
      row++;

      final modeHeaders = <String>[
        if (showCash) 'Cash',
        if (showCheque) 'Cheque',
        if (showBank) 'Bank',
      ];
      final headers = ['Receipt No', schoolTerm('Register No'), 'Student Name', schoolTerm('Class'), schoolTerm('Semester'),
        ...feeTypes.map(_feeHdr), 'Fine', 'Total', ...modeHeaders, 'Adjusted', 'Net Amount'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      final ftTotals = <String, double>{};
      double totalAmt = 0;
      double totalFine = 0;
      double totalCash = 0;
      double totalCheque = 0;
      double totalBank = 0;
      double totalAdj = 0;
      double totalNet = 0;

      final fineCol = 5 + feeTypes.length;
      final totalCol = 6 + feeTypes.length;
      int cursor = 7 + feeTypes.length;
      final cashCol = showCash ? cursor++ : -1;
      final chequeCol = showCheque ? cursor++ : -1;
      final bankCol = showBank ? cursor++ : -1;
      final adjCol = cursor++;
      final netCol = cursor;

      double exportRowTotal(Map<String, dynamic> r) {
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        if (_selectedFeeTypes.isEmpty) {
          return (r['total'] as num?)?.toDouble() ?? 0;
        }
        final fees = r['fees'] as Map<String, double>;
        double sum = 0;
        for (final ft in _selectedFeeTypes) {
          sum += fees[ft] ?? 0;
        }
        return sum + fine;
      }

      double exportRowAdj(Map<String, dynamic> r) =>
          (r['adjusted'] as num?)?.toDouble() ?? 0;
      // Net = Total - Adjusted, clamped (see the on-screen rowNetTotal).
      double exportRowNet(Map<String, dynamic> r) {
        final n = exportRowTotal(r) - exportRowAdj(r);
        return n > 0 ? n : 0;
      }

      // Styles for the per-date header + subtotal rows.
      final dateHeaderStyle = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#CBD5E1'),
      );
      final subtotalStyle = xl.CellStyle(
        bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right,
        backgroundColorHex: xl.ExcelColor.fromHexString('#EDF2F7'),
      );

      // Collection date of a receipt, as a sortable yyyy-MM-dd key.
      String dateKeyOf(Map<String, dynamic> r) {
        final raw = r['paydate']?.toString() ?? '';
        final dt = DateTime.tryParse(raw);
        if (dt != null) {
          return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        }
        return raw.length >= 10 ? raw.substring(0, 10) : raw;
      }

      // Group the visible COLLECTIONS by date (oldest first). Refunds are a
      // separate section (keyed to their own refund date), never collections.
      final byDate = <String, List<Map<String, dynamic>>>{};
      for (final r in visibleRows.where((r) => (r['type']?.toString() ?? '') != 'Refunded')) {
        byDate.putIfAbsent(dateKeyOf(r), () => []).add(r);
      }
      final dateKeys = byDate.keys.toList()..sort();
      final refundList = visibleRows.where((r) => (r['type']?.toString() ?? '') == 'Refunded').toList();

      // Write one receipt row, accumulating into the per-date (acc) and grand
      // totals. acc = [amt, fine, cash, cheque, bank, adjusted, net].
      void writeReceipt(Map<String, dynamic> r, Map<String, double> ftAcc, List<double> acc) {
        final fees = r['fees'] as Map<String, double>;
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        // A cancelled receipt is listed for audit with NO paid amount — it
        // contributes nothing to totals and its money cells stay blank. A
        // refunded receipt carries a NEGATIVE amount so it nets out of the day's
        // total; its refund also accumulates into the grand-total breakdown.
        // Only collections reach here (refunds are handled in their own section).
        final cancelled = (r['type']?.toString() ?? '') == 'Cancelled';
        final total = cancelled ? 0.0 : exportRowTotal(r);
        final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
        final adj = cancelled ? 0.0 : exportRowAdj(r);
        // Cash, bank and Net see only the money; Total keeps the settlement.
        final money = cancelled ? 0.0 : exportRowNet(r);
        acc[0] += total; acc[1] += (cancelled ? 0 : fine); acc[5] += adj; acc[6] += money;
        totalAmt += total; totalFine += (cancelled ? 0 : fine);
        totalAdj += adj; totalNet += money;
        if (!cancelled) {
          if (bucket == 'cash') { acc[2] += money; totalCash += money; }
          else if (bucket == 'cheque') { acc[3] += money; totalCheque += money; }
          else { acc[4] += money; totalBank += money; }
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['paynumber']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(r['stuadmno']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['stuname']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['stuclass']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(cancelled ? 'CANCELLED' : (r['semester']?.toString() ?? ''));
        if (!cancelled) {
          for (int c = 0; c < feeTypes.length; c++) {
            final v = fees[feeTypes[c]] ?? 0;
            ftAcc[feeTypes[c]] = (ftAcc[feeTypes[c]] ?? 0) + v;
            ftTotals[feeTypes[c]] = (ftTotals[feeTypes[c]] ?? 0) + v;
            if (v > 0) {
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).value = xl.DoubleCellValue(v);
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).cellStyle = numStyle;
            }
          }
          if (fine > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).value = xl.DoubleCellValue(fine);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(total);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = totalStyle;
          if (cashCol >= 0 && bucket == 'cash' && money > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).value = xl.DoubleCellValue(money);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).cellStyle = numStyle;
          }
          if (chequeCol >= 0 && bucket == 'cheque' && money > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).value = xl.DoubleCellValue(money);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).cellStyle = numStyle;
          }
          if (bankCol >= 0 && bucket == 'bank' && money > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).value = xl.DoubleCellValue(money);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).cellStyle = numStyle;
          }
          if (adj > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: adjCol, rowIndex: row)).value = xl.DoubleCellValue(adj);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: adjCol, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).value = xl.DoubleCellValue(money);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).cellStyle = totalStyle;
        }
        row++;
      }

      void writeSubtotal(String label, Map<String, double> ftAcc, List<double> acc) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(label);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subtotalStyle;
        for (int c = 0; c < feeTypes.length; c++) {
          final v = ftAcc[feeTypes[c]] ?? 0;
          if (v > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).value = xl.DoubleCellValue(v);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).cellStyle = subtotalStyle;
          }
        }
        if (acc[1] > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).value = xl.DoubleCellValue(acc[1]);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).cellStyle = subtotalStyle;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(acc[0]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = subtotalStyle;
        if (cashCol >= 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).value = xl.DoubleCellValue(acc[2]);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).cellStyle = subtotalStyle;
        }
        if (chequeCol >= 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).value = xl.DoubleCellValue(acc[3]);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).cellStyle = subtotalStyle;
        }
        if (bankCol >= 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).value = xl.DoubleCellValue(acc[4]);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).cellStyle = subtotalStyle;
        }
        if (acc[5] > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: adjCol, rowIndex: row)).value = xl.DoubleCellValue(acc[5]);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: adjCol, rowIndex: row)).cellStyle = subtotalStyle;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).value = xl.DoubleCellValue(acc[6]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).cellStyle = subtotalStyle;
        row++;
      }

      for (final dk in dateKeys) {
        final label = DateTime.tryParse(dk) != null ? _formatDate(DateTime.parse(dk)) : dk;
        // Date header spanning all columns.
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(label);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = dateHeaderStyle;
        sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
        row++;
        final ftAcc = <String, double>{};
        final acc = <double>[0, 0, 0, 0, 0, 0, 0];
        for (final r in byDate[dk]!) {
          writeReceipt(r, ftAcc, acc);
        }
        writeSubtotal('$label Total', ftAcc, acc);
        row++; // blank spacer between dates
      }

      // GRAND TOTAL row
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('GRAND TOTAL');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      for (int c = 0; c < feeTypes.length; c++) {
        final v = ftTotals[feeTypes[c]] ?? 0;
        if (v > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).value = xl.DoubleCellValue(v);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).cellStyle = totalStyle;
        }
      }
      if (totalFine > 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).value = xl.DoubleCellValue(totalFine);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).cellStyle = totalStyle;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(totalAmt);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = totalStyle;
      if (cashCol >= 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).value = xl.DoubleCellValue(totalCash);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).cellStyle = totalStyle;
      }
      if (chequeCol >= 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).value = xl.DoubleCellValue(totalCheque);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).cellStyle = totalStyle;
      }
      if (bankCol >= 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).value = xl.DoubleCellValue(totalBank);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).cellStyle = totalStyle;
      }
      if (totalAdj > 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: adjCol, rowIndex: row)).value = xl.DoubleCellValue(totalAdj);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: adjCol, rowIndex: row)).cellStyle = totalStyle;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).value = xl.DoubleCellValue(totalNet);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).cellStyle = totalStyle;
      row++;

      // Receipts still awaiting bank reconciliation — a SEPARATE section with
      // its own total, deliberately after GRAND TOTAL and never added into it.
      // The money is in hand but unconfirmed; merging the two would overstate
      // what has actually landed in the bank.
      if (unrecRows.isNotEmpty) {
        double uTotal = 0, uFine = 0;
        for (final r in unrecRows) {
          uTotal += exportRowTotal(r);
          uFine += (r['fine'] as num?)?.toDouble() ?? 0;
        }
        row++; // spacer
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value =
            xl.TextCellValue('UNRECONCILED (COLLECTED, NOT YET MATCHED TO A BANK STATEMENT)');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
        row++;
        // Same column layout as the collection table above so the two read
        // together — fee-type columns included.
        for (int c = 0; c < headers.length; c++) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value =
              xl.TextCellValue(headers[c]);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
        }
        row++;
        for (final r in unrecRows) {
          final fees = r['fees'] as Map<String, double>;
          final fine = (r['fine'] as num?)?.toDouble() ?? 0;
          final total = exportRowTotal(r);
          final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['paynumber']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(r['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['stuname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['stuclass']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(r['semester']?.toString() ?? '');
          for (int c = 0; c < feeTypes.length; c++) {
            final v = fees[feeTypes[c]] ?? 0;
            if (v != 0) {
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).value = xl.DoubleCellValue(v);
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).cellStyle = numStyle;
            }
          }
          if (fine != 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).value = xl.DoubleCellValue(fine);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(total);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = numStyle;
          if (cashCol >= 0 && bucket == 'cash') {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).value = xl.DoubleCellValue(total);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).cellStyle = numStyle;
          }
          if (chequeCol >= 0 && bucket == 'cheque') {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).value = xl.DoubleCellValue(total);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).cellStyle = numStyle;
          }
          if (bankCol >= 0 && bucket == 'bank') {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).value = xl.DoubleCellValue(total);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).value = xl.DoubleCellValue(total);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).cellStyle = numStyle;
          row++;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value =
            xl.TextCellValue('TOTAL UNRECONCILED');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
        if (uFine > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).value = xl.DoubleCellValue(uFine);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).cellStyle = totalStyle;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(uTotal);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = totalStyle;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).value = xl.DoubleCellValue(uTotal);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).cellStyle = totalStyle;
        row++;
      }

      // Refunds (keyed to their refund date) — a SEPARATE section listing each
      // refund + a by-mode total. Not part of the collection totals above.
      if (refundList.isNotEmpty) {
        double rCash = 0, rCheque = 0, rBank = 0, rTotal = 0;
        for (final r in refundList) {
          final a = (r['refund'] as num?)?.toDouble() ?? 0;
          rTotal += a;
          final b = _paymentBucket(r['paymethod']?.toString() ?? '');
          if (b == 'cash') rCash += a; else if (b == 'cheque') rCheque += a; else rBank += a;
        }
        row++; // spacer
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('REFUNDS (THIS PERIOD)');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
        row++;
        // Refund column headers reusing Receipt No / Reg No / Name / Class + Mode + Total.
        for (final h in ['Date', 'Receipt No', 'Register No', 'Student Name', 'Class']) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: ['Date', 'Receipt No', 'Register No', 'Student Name', 'Class'].indexOf(h), rowIndex: row)).value = xl.TextCellValue(schoolTerm(h));
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: ['Date', 'Receipt No', 'Register No', 'Student Name', 'Class'].indexOf(h), rowIndex: row)).cellStyle = headerStyle;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.TextCellValue('Mode');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).cellStyle = headerStyle;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.TextCellValue('Refund');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = headerStyle;
        row++;
        for (final r in refundList) {
          final raw = r['paydate']?.toString() ?? '';
          final dt = DateTime.tryParse(raw);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(dt != null ? _formatDate(dt) : (raw.length >= 10 ? raw.substring(0, 10) : raw));
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(r['paynumber']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['stuname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(r['stuclass']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.TextCellValue(r['paymethod']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue((r['refund'] as num?)?.toDouble() ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = numStyle;
          row++;
        }
        // Total refund by mode.
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('TOTAL REFUND');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
        if (cashCol >= 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).value = xl.DoubleCellValue(rCash); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).cellStyle = totalStyle; }
        if (chequeCol >= 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).value = xl.DoubleCellValue(rCheque); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).cellStyle = totalStyle; }
        if (bankCol >= 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).value = xl.DoubleCellValue(rBank); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).cellStyle = totalStyle; }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(rTotal);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = totalStyle;
        row++;
      }

      sheet.setColumnWidth(0, 12); // Receipt No
      sheet.setColumnWidth(1, 14); // Reg No
      sheet.setColumnWidth(2, 24); // Student Name
      sheet.setColumnWidth(3, 12); // Class
      sheet.setColumnWidth(4, 14); // Semester
      for (int c = 0; c < feeTypes.length; c++) {
        sheet.setColumnWidth(5 + c, 12);
      }
      sheet.setColumnWidth(fineCol, 8);
      sheet.setColumnWidth(totalCol, 10);
      if (cashCol >= 0) sheet.setColumnWidth(cashCol, 10);
      if (chequeCol >= 0) sheet.setColumnWidth(chequeCol, 10);
      if (bankCol >= 0) sheet.setColumnWidth(bankCol, 10);
      sheet.setColumnWidth(netCol, 10);

      await _saveExcel(excel, 'Daily_Collection_${_formatDateCompact(_dailyFrom!)}_${_formatDateCompact(_dailyTo!)}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export to Excel. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }





  // ══════════════════════════════════════════════════════════
  // TAB: DCB STUDENT REGISTER (per-course Demand / Collection / Balance)
  // ══════════════════════════════════════════════════════════
  /// Load the extra masters the DCB register needs (student batch/quota/admn,
  /// the Transport fee-group classification, reconciled receipts, class order).
  Future<void> _loadDcbMeta({bool force = false}) async {
    if (_dcbLoaded && !force) return;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final results = await Future.wait([
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
            // A school has no batch, quota or admission type.
            .select(isSchool ? 'stu_id, stuadmno, stuname' : 'stu_id, stuadmno, stuname, batch, quoname, admname')
            .eq('ins_id', insId).eq('activestatus', 1)),
        SupabaseService.fromSchema('feetype').select('fee_id, feedesc, fg_id, type').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('feegroup').select('fg_id, fgdesc').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('payment')
            .select('stu_id, paynumber, paydate')
            .eq('ins_id', insId).eq('paystatus', 'C').eq('recon_status', 'R').eq('activestatus', 1)),
        SupabaseService.getClassOrder(insId),
      ]);
      final students = results[0] as List;
      final feetypes = results[1] as List;
      final feegroups = results[2] as List;
      final payments = results[3] as List;
      final classOrd = results[4] as Map<String, int>;

      final stuInfo = <String, Map<String, dynamic>>{};
      for (final s in students) {
        final admno = s['stuadmno']?.toString() ?? '';
        if (admno.isEmpty) continue;
        stuInfo[admno] = {
          'batch': s['batch']?.toString() ?? '',
          'quoname': s['quoname']?.toString() ?? '',
          'admname': s['admname']?.toString() ?? '',
          'stuname': s['stuname']?.toString() ?? '',
        };
      }

      // fee_id / fee-name -> feetype.type (COL / TRA / ...). Both the DCB Type
      // filter AND the COLLEGE/TRANSPORT columns key off feetype.type: 'TRA' is
      // Transport, everything else is College — per the fee master.
      final feeIdToType = <int, String>{};
      final feeTypeNameToType = <String, String>{};
      final typeSet = <String>{};
      for (final ft in feetypes) {
        final fid = (ft['fee_id'] as num?)?.toInt();
        final nm = (ft['feedesc']?.toString() ?? '').toUpperCase();
        final tp = (ft['type']?.toString() ?? '').trim().toUpperCase();
        if (tp.isEmpty) continue;
        if (fid != null) feeIdToType[fid] = tp;
        if (nm.isNotEmpty) feeTypeNameToType[nm] = tp;
        typeSet.add(tp);
      }
      final typeOptions = typeSet.toList()..sort();

      // Latest reconciled receipt per student.
      final receipts = <int, Map<String, dynamic>>{};
      for (final p in payments) {
        final sid = (p['stu_id'] as num?)?.toInt();
        if (sid == null) continue;
        final pd = p['paydate']?.toString() ?? '';
        final ex = receipts[sid];
        if (ex == null || pd.compareTo(ex['paydate'] as String) > 0) {
          receipts[sid] = {'paynumber': p['paynumber']?.toString() ?? '', 'paydate': pd};
        }
      }

      if (mounted) setState(() {
        _stuInfo = stuInfo;
        _feeIdToType = feeIdToType;
        _feeTypeNameToType = feeTypeNameToType;
        _stuReceipt = receipts;
        _dcbClassOrdid = classOrd;
        _dcbTypeOptions = typeOptions;
        _dcbLoaded = true;
      });
    } catch (e) {
      debugPrint('DCB meta load: $e');
      if (mounted) setState(() => _dcbLoaded = true);
    }
  }

  /// The Type options that the chosen fee GROUP still allows.
  ///
  /// With HOSTEL FEES selected, offering TRA is offering a filter that can
  /// only ever return nothing: no transport fee banks into the hostel
  /// account. The list follows the group the same way the Fee Type list
  /// does.
  ///
  /// Resolved through fee_id, so a fee description that exists under two
  /// groups is attributed to the right one.
  List<String> get _dcbTypeOptionsForGroup {
    if (_selectedFeeGroups.isEmpty) return _dcbTypeOptions;
    final allowed = <String>{};
    _feeIdToType.forEach((feeId, type) {
      final g = _feeIdGroup[feeId];
      if (g != null && _selectedFeeGroups.contains(g)) allowed.add(type);
    });
    return _dcbTypeOptions.where(allowed.contains).toList();
  }

  /// The feetype.type a demand belongs to (COL / TRA / …), resolved by fee_id or
  /// by fee-type name. Drives BOTH the DCB Type filter and the COLLEGE/TRANSPORT
  /// column split, so they always agree.
  String? _demandType(Map<String, dynamic> d) {
    final fid = d['fee_id'];
    if (fid is num && _feeIdToType.containsKey(fid.toInt())) return _feeIdToType[fid.toInt()];
    return _feeTypeNameToType[(d['demfeetype']?.toString() ?? '').toUpperCase()];
  }

  /// A demand counts as Transport when its feetype.type is 'TRA' (else College).
  bool _isTransportDemand(Map<String, dynamic> d) {
    final t = (_demandType(d) ?? '').toUpperCase();
    return t == 'TRA' || t == 'TRANSPORT';
  }

  int _dcbTermRank(String t) => t.trim().toUpperCase() == 'YEARLY' ? 0 : 1;

  String _fmtDcbDate(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt == null ? iso : _formatDate(dt);
  }

  /// Distinct admission types present in the loaded students (for the DCB filter).
  List<String> _dcbAdmnOptions() {
    final set = <String>{};
    for (final info in _stuInfo.values) {
      final a = (info['admname'] as String?)?.trim() ?? '';
      if (a.isNotEmpty) set.add(a);
    }
    return set.toList()..sort();
  }

  /// Flattened DCB display rows for [course]. Each map has 'kind':
  /// 'data' | 'subtotal' | 'grand'. Data rows are one per (student, term);
  /// Sl No / Name / Receipt appear only on a student's first row.
  List<Map<String, dynamic>> _dcbRows(String course) {
    final groups = <String, Map<String, dynamic>>{};
    for (final d in _allDemands) {
      if (!_tcMatches(d)) continue;
      if ((d['courname']?.toString() ?? '') != course) continue;
      // Apply the Class filter (was ignored — DCB showed every class of the course).
      if (_selectedClasses.isNotEmpty && !_selectedClasses.contains(d['stuclass']?.toString() ?? '')) continue;
      if (d['activestatus'] != null && d['activestatus'] != 1) continue;
      if (_selectedFeeKinds.isNotEmpty && !_selectedFeeKinds.contains(_demandType(d))) continue;
      // DCB walks _allDemands itself rather than _filteredDemands, so the Fee
      // Group / Fee Type filters have to be applied here too -- otherwise the
      // picker sits in the filter bar doing nothing, which is worse than not
      // offering it.
      if (_feeFilterActive &&
          !_feeTypeAllowed(d['demfeetype']?.toString() ?? '',
              feeId: (d['fee_id'] as num?)?.toInt())) continue;
      final admno = d['stuadmno']?.toString() ?? '';
      if (admno.isEmpty) continue;
      if (_dcbAdmnTypes.isNotEmpty) {
        final at = (_stuInfo[admno]?['admname'] as String?)?.trim() ?? '';
        if (!_dcbAdmnTypes.contains(at)) continue;
      }
      final term = d['demfeeterm']?.toString() ?? '';
      final key = '$admno$term';
      final fee = (d['feeamount'] as num?)?.toDouble() ?? 0;
      final recBal = (d['reconbalancedue'] as num?)?.toDouble() ?? 0;
      final transport = _isTransportDemand(d);
      final g = groups.putIfAbsent(key, () => {
        'admno': admno,
        'term': term,
        'stuId': (d['stu_id'] as num?)?.toInt(),
        'name': d['stuname']?.toString() ?? (_stuInfo[admno]?['stuname'] as String? ?? ''),
        'cls': d['stuclass']?.toString() ?? '',
        'college': 0.0,
        'transport': 0.0,
        'balance': 0.0,
      });
      g['college'] = (g['college'] as double) + (transport ? 0 : fee);
      g['transport'] = (g['transport'] as double) + (transport ? fee : 0);
      g['balance'] = (g['balance'] as double) + recBal; // reconciled outstanding
    }
    if (groups.isEmpty) return [];

    final byStudent = <String, List<Map<String, dynamic>>>{};
    for (final g in groups.values) {
      byStudent.putIfAbsent(g['admno'] as String, () => []).add(g);
    }
    for (final list in byStudent.values) {
      list.sort((a, b) {
        final r = _dcbTermRank(a['term'] as String).compareTo(_dcbTermRank(b['term'] as String));
        return r != 0 ? r : (a['term'] as String).compareTo(b['term'] as String);
      });
    }

    int classKey(String cls) => _dcbClassOrdid[cls.trim().toUpperCase()] ?? 1 << 30;
    final students = byStudent.keys.toList()
      ..sort((a, b) {
        final ca = byStudent[a]!.first['cls'] as String;
        final cb = byStudent[b]!.first['cls'] as String;
        final ck = classKey(ca).compareTo(classKey(cb));
        if (ck != 0) return ck;
        final cc = ca.compareTo(cb);
        return cc != 0 ? cc : a.compareTo(b);
      });

    final rows = <Map<String, dynamic>>[];
    int sl = 0;
    String? curClass;
    double sCol = 0, sTra = 0, sDem = 0, sColl = 0, sBal = 0;
    double gCol = 0, gTra = 0, gDem = 0, gColl = 0, gBal = 0;

    void flushSubtotal() {
      if (curClass == null) return;
      rows.add({'kind': 'subtotal', 'college': sCol, 'transport': sTra, 'demand': sDem, 'collection': sColl, 'balance': sBal});
      sCol = sTra = sDem = sColl = sBal = 0;
    }

    for (final admno in students) {
      final terms = byStudent[admno]!;
      final cls = terms.first['cls'] as String;
      if (curClass != null && cls != curClass) flushSubtotal();
      curClass = cls;
      sl++;
      final info = _stuInfo[admno] ?? const {};
      final sid = terms.first['stuId'] as int?;
      final receipt = sid != null ? _stuReceipt[sid] : null;
      for (var i = 0; i < terms.length; i++) {
        final t = terms[i];
        final college = t['college'] as double;
        final transport = t['transport'] as double;
        final demand = college + transport;
        final balance = t['balance'] as double;
        final collection = demand - balance;
        sCol += college; sTra += transport; sDem += demand; sColl += collection; sBal += balance;
        gCol += college; gTra += transport; gDem += demand; gColl += collection; gBal += balance;
        rows.add({
          'kind': 'data',
          'slno': i == 0 ? '$sl' : '',
          'name': i == 0 ? (t['name'] as String) : '',
          'admno': i == 0 ? admno : '',
          'cls': cls,
          'batch': info['batch'] ?? '',
          'sem': t['term'],
          'college': college,
          'transport': transport,
          'demand': demand,
          'collection': collection,
          'balance': balance,
          'quota': info['quoname'] ?? '',
          'admtype': info['admname'] ?? '',
          'receipt': (i == 0 && receipt != null && (receipt['paynumber'] as String).isNotEmpty)
              ? '${receipt['paynumber']}${(receipt['paydate'] as String).isNotEmpty ? '  ${_fmtDcbDate(receipt['paydate'] as String)}' : ''}'
              : '',
        });
      }
    }
    flushSubtotal();
    rows.add({'kind': 'grand', 'college': gCol, 'transport': gTra, 'demand': gDem, 'collection': gColl, 'balance': gBal});
    return rows;
  }

  /// Combined DCB rows for every course (used when no course is selected).
  /// Each course section = a 'courseheader' row + that course's rows (which end
  /// in a per-course 'grand' total), followed by a final 'overall' total.
  List<Map<String, dynamic>> _dcbAllCoursesRows() {
    final rows = <Map<String, dynamic>>[];
    double oCol = 0, oTra = 0, oDem = 0, oColl = 0, oBal = 0;
    for (final course in _courses) {
      final cr = _dcbRows(course);
      if (cr.isEmpty) continue;
      rows.add({'kind': 'courseheader', 'course': course});
      for (final r in cr) {
        if (r['kind'] == 'grand') {
          oCol += r['college'] as double;
          oTra += r['transport'] as double;
          oDem += r['demand'] as double;
          oColl += r['collection'] as double;
          oBal += r['balance'] as double;
        }
        rows.add(r);
      }
    }
    if (rows.isEmpty) return [];
    rows.add({'kind': 'overall', 'college': oCol, 'transport': oTra, 'demand': oDem, 'collection': oColl, 'balance': oBal});
    return rows;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // TAB: ADVANCE REGISTER
  //
  // The office's register of advances taken, over a date range, with both
  // exports. It is NOT a move of the list under Advance Collection: that one
  // is the cashier's working view -- what THIS student already holds, read
  // while deciding whether to take more -- and it stays where the decision is
  // made. This is the thing you reconcile and file.
  //
  // Balance, not amount, is the figure that matters here: an advance is money
  // held, and only the unspent part is still a liability. Both are shown so
  // the sheet reconciles against the day it was collected as well.
  // ═══════════════════════════════════════════════════════════════════════
  List<Map<String, dynamic>> _advRows = [];
  bool _advLoading = false;
  bool _advLoaded = false;
  String? _advError;
  DateTime? _advFrom;
  DateTime? _advTo;
  Set<String> _advTypeFilter = <String>{}; // empty = every type
  int _advPage = 0;

  static const Map<String, String> _advTypeLabel = {
    'A': 'Admission',
    'S': 'Student',
    'M': 'Mess',
  };

  bool get _advNothingToExport => _filteredAdvRows.isEmpty;

  /// Type filter applied in the client: the range is the only thing worth a
  /// round trip, and an institution's whole year of advances is a few hundred
  /// rows.
  /// Course and Class come from the filter row every report shares. They are
  /// applied HERE rather than ignored: a filter that is visible and does
  /// nothing is worse than one that is absent, because the figure underneath
  /// looks filtered when it is not.
  List<Map<String, dynamic>> get _filteredAdvRows {
    return _advRows.where((r) {
      if (_advTypeFilter.isNotEmpty) {
        final t = _advTypeLabel[r['advtype']?.toString() ?? 'S'] ?? 'Student';
        if (!_advTypeFilter.contains(t)) return false;
      }
      if (_selectedCourse != null &&
          (r['courname']?.toString() ?? '') != _selectedCourse) {
        return false;
      }
      if (_selectedClasses.isNotEmpty &&
          !_selectedClasses.contains(r['stuclass']?.toString() ?? '')) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<void> _loadAdvanceRegister({bool force = false}) async {
    if (_advLoading) return;
    if (_advLoaded && !force) return;
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    setState(() {
      _advLoading = true;
      _advError = null;
    });
    try {
      String d(DateTime x) =>
          '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
      // fetchAll, not a plain select: PostgREST caps a response at 1000 rows
      // and says nothing about it, so a busy year would simply stop reporting
      // partway through the register.
      final rows = await SupabaseService.fetchAll(() {
        var q = SupabaseService
            .fromSchema('advance_collection')
            .select('adv_id, advno, advdate, advtype, stuadmno, stuname, stuclass, '
                'courname, transtotalamount, adjustedamount, balanceamount, '
                'paymethod, payreference, remarks, createdby, recon_status')
            .eq('ins_id', insId)
            .eq('activestatus', 1);
        if (_advFrom != null) q = q.gte('advdate', d(_advFrom!));
        // Upper bound is EXCLUSIVE on the next day: advdate carries a time, so
        // lte on the date alone drops everything taken after midnight on the
        // last day of the range.
        if (_advTo != null) {
          q = q.lt('advdate', d(_advTo!.add(const Duration(days: 1))));
        }
        return q;
      });
      if (!mounted) return;
      setState(() {
        _advRows = rows.map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) =>
              ((b['adv_id'] as num?) ?? 0).compareTo((a['adv_id'] as num?) ?? 0));
        _advLoaded = true;
        _advPage = 0;
      });
    } catch (e) {
      if (mounted) setState(() => _advError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _advLoading = false);
    }
  }

  String _advRangeLabel() {
    if (_advFrom == null && _advTo == null) return 'All Dates';
    final f = _advFrom == null ? '' : _formatDate(_advFrom!);
    final t = _advTo == null ? '' : _formatDate(_advTo!);
    if (f.isNotEmpty && t.isNotEmpty) return f == t ? f : '$f  -  $t';
    return f.isNotEmpty ? 'From $f' : 'To $t';
  }

  Future<void> _pickAdvRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: (_advFrom != null && _advTo != null)
          ? DateTimeRange(start: _advFrom!, end: _advTo!)
          : null,
    );
    if (picked == null) return;
    setState(() {
      _advFrom = picked.start;
      _advTo = picked.end;
    });
    await _loadAdvanceRegister(force: true);
  }

  /// The six money figures the register foots to.
  ({double amount, double adjusted, double balance, int count}) _advTotals(
      List<Map<String, dynamic>> rows) {
    double a = 0, j = 0, b = 0;
    for (final r in rows) {
      a += (r['transtotalamount'] as num?)?.toDouble() ?? 0;
      j += (r['adjustedamount'] as num?)?.toDouble() ?? 0;
      b += (r['balanceamount'] as num?)?.toDouble() ?? 0;
    }
    return (amount: a, adjusted: j, balance: b, count: rows.length);
  }

  List<String> _advRowCells(Map<String, dynamic> r) {
    final dt = DateTime.tryParse(r['advdate']?.toString() ?? '');
    final amt = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
    final adj = (r['adjustedamount'] as num?)?.toDouble() ?? 0;
    final bal = (r['balanceamount'] as num?)?.toDouble() ?? 0;
    return [
      r['advno']?.toString() ?? '',
      dt == null ? '' : _formatDate(dt),
      _advTypeLabel[r['advtype']?.toString() ?? 'S'] ?? 'Student',
      r['stuadmno']?.toString() ?? '',
      r['stuname']?.toString() ?? '',
      r['stuclass']?.toString() ?? '',
      r['paymethod']?.toString() ?? '',
      _formatNumber(amt),
      adj == 0 ? '' : _formatNumber(adj),
      _formatNumber(bal),
    ];
  }

  static const List<String> _advHeaders = [
    'RECEIPT NO', 'DATE', 'TYPE', 'REGISTER NO', 'STUDENT NAME', 'CLASS',
    'MODE', 'AMOUNT', 'ADJUSTED', 'BALANCE',
  ];

  Widget _buildAdvanceRegister() {
    final rows = _filteredAdvRows;
    final t = _advTotals(rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              _reportTitle('wallet-money', 'Advance Register', 'Advances taken, adjusted and still held'),
              SizedBox(width: 8.w),
              if (_advLoading)
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.accent)),
              const Spacer(),
              Builder(builder: (_) {
                final filled = _advFrom != null || _advTo != null;
                return SizedBox(
                  height: AppBtn.height(context),
                  child: OutlinedButton.icon(
                    onPressed: _pickAdvRange,
                    icon: Icon(Icons.calendar_today,
                        size: AppBtn.iconSize(context),
                        color: filled ? AppColors.primary : AppColors.textSecondary),
                    label: Text(_advRangeLabel(),
                        style: AppUI.label.copyWith(
                            color: filled
                                ? AppColors.primary
                                : AppColors.textSecondary)),
                  ),
                );
              }),
              SizedBox(width: AppBtn.gap(context)),
              _checkMultiSelect(
                anchorKey: _advTypeKey,
                width: 175.w,
                allLabel: 'All Advance Types',
                pluralNoun: 'advance types',
                selected: _advTypeFilter,
                onTap: () => _openCheckPicker(
                  anchorKey: _advTypeKey,
                  title: 'Select Advance Types',
                  options: const ['Admission', 'Student', 'Mess'],
                  current: _advTypeFilter,
                  onApply: (s) => setState(() {
                    _advTypeFilter = s;
                    _advPage = 0;
                  }),
                ),
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _advNothingToExport ? () {} : _exportAdvanceRegisterExcel,
                icon: Icons.table_chart_rounded,
                label: AppText.exportExcel,
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _advNothingToExport ? () {} : _exportAdvanceRegisterPdf,
                icon: Icons.picture_as_pdf_rounded,
                label: AppText.exportPdf,
              ),
            ],
          ),
        ),
        if (_advError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Could not load the register. $_advError',
                style: AppUI.muted.copyWith(color: AppColors.error)),
          ),
        Expanded(
          child: rows.isEmpty
              ? _emptyState(_advLoading
                  ? 'Loading advances...'
                  : 'No advances in this range')
              : _stickyTable(
                  columnWidths: const [
                    140, 110, 110, 120, 280, 140, 110,
                    130, 130, 130,
                  ],
                  headers: _advHeaders.map(schoolTerm).toList(),
                  rows: [
                    for (final r in rows
                        .skip(_advPage * _tablePageSize)
                        .take(_tablePageSize))
                      _advRowCells(r),
                  ],
                  footer: <String>[
                    'TOTAL', '', '', '', '', '', '',
                    _formatNumber(t.amount),
                    _formatNumber(t.adjusted),
                    _formatNumber(t.balance),
                  ],
                  numericCols: const {7, 8, 9},
                  centerCols: const {2},
                ),
        ),
        _pagerBar(
          total: rows.length,
          page: _advPage,
          onPrev: _advPage > 0 ? () => setState(() => _advPage--) : null,
          onNext: (_advPage + 1) * _tablePageSize < rows.length
              ? () => setState(() => _advPage++)
              : null,
        ),
      ],
    );
  }

  /// What each advance has been applied to, keyed by adv_id.
  ///
  /// Loaded on demand by the exports rather than held in state: the register
  /// itself never shows it, and most opens never export.
  Future<Map<int, List<Map<String, dynamic>>>> _advAdjustments(
      List<Map<String, dynamic>> rows) async {
    final byAdv = <int, List<Map<String, dynamic>>>{};
    final insId = context.read<AuthProvider>().insId;
    final ids = rows
        .map((a) => (a['adv_id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    if (insId == null || ids.isEmpty) return byAdv;
    try {
      final adj = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('advadjustment')
          .select('adv_id, paynumber, demfeetype, adjustamount, adjustdate')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .inFilter('adv_id', ids));
      for (final r in adj) {
        final id = (r['adv_id'] as num?)?.toInt();
        if (id == null) continue;
        (byAdv[id] ??= []).add(Map<String, dynamic>.from(r));
      }
    } catch (e) {
      debugPrint('advance register adjustment load: $e');
    }
    return byAdv;
  }

  /// What one advance was applied to: ONE ENTRY PER FEE TYPE, ordered by fee
  /// type then receipt.
  ///
  /// These used to be joined into a single cell ("FC26/02965 (TUITION FEE)
  /// 2500, FC26/02968 (TUITION FEE) 2500"), which cannot be totalled, filtered
  /// or pivoted -- the fee type a sum belongs to was buried in prose. Each one
  /// is its own row, with the fee type and the amount in columns of their own.
  List<Map<String, dynamic>> _advAppliedTo(
      Map<String, dynamic> a, Map<int, List<Map<String, dynamic>>> byAdv) {
    final id = (a['adv_id'] as num?)?.toInt();
    final lines = id == null
        ? const <Map<String, dynamic>>[]
        : (byAdv[id] ?? const <Map<String, dynamic>>[]);
    final out = [
      for (final l in lines)
        {
          'receipt': (l['paynumber']?.toString().trim() ?? '').isEmpty
              // An ADMISSION advance reduces the fee instead of paying it, so
              // it raises no receipt to name.
              ? 'Fee reduced'
              : l['paynumber'].toString().trim(),
          'feetype': l['demfeetype']?.toString().trim() ?? '',
          'amount': (l['adjustamount'] as num?)?.toDouble() ?? 0,
        }
    ];
    out.sort((x, y) {
      final c = (x['feetype'] as String).compareTo(y['feetype'] as String);
      return c != 0
          ? c
          : (x['receipt'] as String).compareTo(y['receipt'] as String);
    });
    return out;
  }

  static const List<String> _advExportHeaders = [
    AppText.serialNo, 'Class', 'Register No', 'Student Name', 'Receipt No', 'Date',
    'Type', 'Mode', 'Advance Paid', 'Total Adjusted', 'Balance',
    'Adjusted Against', 'Fee Type', 'Adjusted Amount',
  ];

  String _advTypeText(Map<String, dynamic> a) => switch (a['advtype']?.toString() ?? 'S') {
        'A' => 'Admission',
        'M' => 'Mess',
        _ => 'Student',
      };

  String _advPeriodText() =>
      'Period: ${_advRangeLabel()}    '
      'Types: ${_advTypeFilter.isEmpty ? 'All' : _advTypeFilter.join(', ')}';

  /// ADVANCE REGISTER -> .xlsx, in the layout the office already files.
  Future<void> _exportAdvanceRegisterExcel() async {
    final rows = _filteredAdvRows;
    if (rows.isEmpty) return;
    try {
      final byAdv = await _advAdjustments(rows);
      final excel = xl.Excel.createExcel();
      final sheet = excel['Advance Register'];
      excel.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final head = xl.CellStyle(bold: true, fontSize: 10);
      final numSt =
          xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final tot = xl.CellStyle(
          bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      var r = 0;
      void put(int c, String v, [xl.CellStyle? st]) {
        final cell = sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        cell.value = xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      void putNum(int c, double v, [xl.CellStyle? st]) {
        final cell = sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        cell.value = xl.DoubleCellValue(v);
        cell.cellStyle = st ?? numSt;
      }

      put(1, _insName, bold);
      r++;
      if (_insAddress.isNotEmpty) {
        put(1, _insAddress, bold);
        r++;
      }
      put(1, 'ADVANCE REGISTER AS ON ${_formatDate(DateTime.now())}', bold);
      r++;
      put(1, _advPeriodText(), bold);
      r += 2;

      for (var c = 0; c < _advExportHeaders.length; c++) {
        put(c, schoolTerm(_advExportHeaders[c]), head);
      }
      r++;

      var tPaid = 0.0, tAdj = 0.0, tBal = 0.0, tSplit = 0.0;
      for (var i = 0; i < rows.length; i++) {
        final a = rows[i];
        final paid = (a['transtotalamount'] as num?)?.toDouble() ?? 0;
        final adj = (a['adjustedamount'] as num?)?.toDouble() ?? 0;
        final bal = (a['balanceamount'] as num?)?.toDouble() ?? 0;
        tPaid += paid;
        tAdj += adj;
        tBal += bal;
        final raw = a['advdate']?.toString() ?? '';
        final d = DateTime.tryParse(raw);
        put(0, '${i + 1}');
        put(1, a['stuclass']?.toString() ?? '');
        put(2, a['stuadmno']?.toString() ?? '');
        put(3, a['stuname']?.toString() ?? '');
        put(4, a['advno']?.toString() ?? '');
        put(5,
            d != null ? _formatDate(d) : (raw.length >= 10 ? raw.substring(0, 10) : raw));
        put(6, _advTypeText(a));
        put(7, (a['paymethod']?.toString() ?? '').toUpperCase());
        putNum(8, paid);
        putNum(9, adj);
        putNum(10, bal);
        final lines = _advAppliedTo(a, byAdv);
        if (lines.isEmpty) {
          // Nothing applied yet: the advance still gets its row.
          r++;
        } else {
          for (var k = 0; k < lines.length; k++) {
            // The advance's own figures sit on its FIRST line only. Repeating
            // them down the continuation rows would double the totals of
            // anyone who selects the column.
            if (k > 0) put(0, '');
            final amt = (lines[k]['amount'] as double?) ?? 0;
            tSplit += amt;
            put(11, lines[k]['receipt'] as String);
            put(12, lines[k]['feetype'] as String);
            putNum(13, amt);
            r++;
          }
        }
      }

      put(3, 'Total', bold);
      putNum(8, tPaid, tot);
      putNum(9, tAdj, tot);
      putNum(10, tBal, tot);
      // The split column totals to the same figure as Adj.Amt -- if it does
      // not, an adjustment row is missing its advance or vice versa.
      putNum(13, tSplit, tot);
      r++;

      const widths = [8.0, 16.0, 18.0, 26.0, 16.0, 13.0, 12.0, 12.0, 13.0,
                      13.0, 13.0, 18.0, 26.0, 14.0];
      for (var c = 0; c < widths.length; c++) {
        sheet.setColumnWidth(c, widths[c]);
      }

      await _saveExcel(
          excel, 'Advance_Register_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not export to Excel. ${friendlyError(e)}'),
            backgroundColor: AppColors.error));
      }
    }
  }

  /// ADVANCE REGISTER -> .pdf, the same columns as the sheet so the two cannot
  /// be read as different reports.
  Future<void> _exportAdvanceRegisterPdf() async {
    final rows = _filteredAdvRows;
    if (rows.isEmpty) return;
    try {
      final byAdv = await _advAdjustments(rows);
      final data = <List<String>>[];
      var tPaid = 0.0, tAdj = 0.0, tBal = 0.0, tSplit = 0.0;
      for (var i = 0; i < rows.length; i++) {
        final a = rows[i];
        final paid = (a['transtotalamount'] as num?)?.toDouble() ?? 0;
        final adj = (a['adjustedamount'] as num?)?.toDouble() ?? 0;
        final bal = (a['balanceamount'] as num?)?.toDouble() ?? 0;
        tPaid += paid;
        tAdj += adj;
        tBal += bal;
        final d = DateTime.tryParse(a['advdate']?.toString() ?? '');
        final own = <String>[
          '${i + 1}',
          a['stuclass']?.toString() ?? '',
          a['stuadmno']?.toString() ?? '',
          a['stuname']?.toString() ?? '',
          a['advno']?.toString() ?? '',
          d == null ? '' : _formatDate(d),
          _advTypeText(a),
          (a['paymethod']?.toString() ?? '').toUpperCase(),
          _formatNumber(paid),
          _formatNumber(adj),
          _formatNumber(bal),
        ];
        final lines = _advAppliedTo(a, byAdv);
        if (lines.isEmpty) {
          data.add([...own, '', '', '']);
        } else {
          for (var k = 0; k < lines.length; k++) {
            final amt = (lines[k]['amount'] as double?) ?? 0;
            tSplit += amt;
            data.add([
              // Same rule as the sheet: the advance's own figures appear once,
              // on its first line, so a column can be summed.
              ...(k == 0 ? own : List<String>.filled(own.length, '')),
              lines[k]['receipt'] as String,
              lines[k]['feetype'] as String,
              _formatNumber(amt),
            ]);
          }
        }
      }
      data.add([
        '', '', '', 'Total', '', '', '', '',
        _formatNumber(tPaid), _formatNumber(tAdj), _formatNumber(tBal),
        '', '', _formatNumber(tSplit),
      ]);

      final pdf = pw.Document();
      pdf.addPage(pw.MultiPage(
        // 14 columns do not fit portrait.
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_insName,
                style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty)
              pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('ADVANCE REGISTER',
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('DATE: ${_formatDate(DateTime.now())}',
                  style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 2),
            pw.Text('${_advPeriodText()}    Advances: ${rows.length}',
                style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.TableHelper.fromTextArray(
            headers: _advExportHeaders.map(schoolTerm).toList(),
            data: data,
            headerStyle: pw.TextStyle(
                fontSize: 7, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 7),
            columnWidths: {
              0: const pw.FixedColumnWidth(26),
              1: const pw.FixedColumnWidth(48),
              2: const pw.FixedColumnWidth(58),
              3: const pw.FlexColumnWidth(2.2),
              4: const pw.FixedColumnWidth(52),
              5: const pw.FixedColumnWidth(42),
              6: const pw.FixedColumnWidth(42),
              7: const pw.FixedColumnWidth(36),
              8: const pw.FixedColumnWidth(42),
              9: const pw.FixedColumnWidth(40),
              10: const pw.FixedColumnWidth(42),
              11: const pw.FixedColumnWidth(58),
              12: const pw.FlexColumnWidth(1.8),
              13: const pw.FixedColumnWidth(44),
            },
            cellAlignments: {
              for (int i = 8; i <= 10; i++) i: pw.Alignment.centerRight,
              6: pw.Alignment.center,
              13: pw.Alignment.centerRight,
            },
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      await _savePdf(
          pdf, 'Advance_Register_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not create the PDF. ${friendlyError(e)}'),
            backgroundColor: AppColors.error));
      }
    }
  }

  Widget _buildDcbRegister() {
    if (!_dcbLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDcbMeta());
      return const Center(child: CircularProgressIndicator());
    }
    final course = _selectedCourse; // null => every course stacked
    final rows = course == null ? _dcbAllCoursesRows() : _dcbRows(course);
    final label = course ?? schoolTerm('All Courses');
    final studentCount = rows.where((r) => r['kind'] == 'data' && (r['slno'] as String).isNotEmpty).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.only(bottom: 10.h),
          child: Row(children: [
            _reportTitle('grid-1', 'DCB Register', 'Demand, collection and balance per student (reconciled)'),
            SizedBox(width: 10.w),
            Text('$label  ·  $studentCount students', style: AppUI.muted),
            const Spacer(),
            _miniExportBtn(
              onPressed: (rows.isEmpty || _dcbExporting) ? () {} : () => _exportDcbExcel(label, rows),
              icon: Icons.table_chart_rounded,
              label: _dcbExporting ? 'Exporting…' : AppText.exportExcel,
            ),
            SizedBox(width: AppBtn.gap(context)),
            _miniExportBtn(
              onPressed: (rows.isEmpty || _dcbExporting) ? () {} : () => _exportDcbPdf(label, rows),
              icon: Icons.picture_as_pdf_rounded,
              label: AppText.exportPdf,
            ),
          ]),
        ),
        Expanded(child: rows.isEmpty ? _emptyState('No fee demands', why: 'Nothing matches the current filters -- change them above or press Refresh.') : _dcbTable(rows)),
      ],
    );
  }

  Widget _dcbTable(List<Map<String, dynamic>> rows) {
    const base = <double>[56, 200, 92, 84, 84, 92, 100, 92, 100, 92, 110, 130, 140];
    final headers = ['S. NO.', 'NAME & REGISTER NO', 'CLASS', 'BATCH', 'SEMESTER', isSchool ? 'SCHOOL' : 'COLLEGE', 'TRANSPORT', 'DEMAND', 'COLLECTION', 'BALANCE', 'QUOTA', 'ADMISSION TYPE', 'RECEIPT'];
    const numCols = {5, 6, 7, 8, 9};
    // A school has no batch, quota or admission type: those columns are
    // skipped. Indexes stay the college's, so every lookup below is unchanged.
    final cols = [for (int i = 0; i < headers.length; i++) if (!(isSchool && (i == 3 || i == 10 || i == 11))) i];
    final totalW = cols.fold<double>(0, (a, i) => a + base[i]);
    String num0(Map<String, dynamic> r, String k) { final v = (r[k] as double?) ?? 0; return v == 0 ? '' : _formatNumber(v); }

    return LayoutBuilder(builder: (context, constraints) {
      // Fit to screen: fill the available width; only scroll if truly too narrow.
      final w = constraints.maxWidth > totalW ? constraints.maxWidth : totalW;
      final widths = base.map((x) => x * (w / totalW)).toList();

    Widget rowWidget(Map<String, dynamic> r, int idx) {
      final kind = r['kind'];
      if (kind == 'courseheader') {
        return Container(
          width: w,
          color: AppColors.primaryLight,
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
          child: Text(r['course'] as String, style: AppUI.label.copyWith(fontWeight: FontWeight.w800, color: AppColors.primary)),
        );
      }
      if (kind == 'subtotal' || kind == 'grand' || kind == 'overall') {
        final isGrand = kind == 'grand';
        final isOverall = kind == 'overall';
        final style = AppUI.money.copyWith(fontWeight: FontWeight.w800, color: (isGrand || isOverall) ? AppColors.primary : AppColors.textPrimary);
        String n(String k) => _formatNumber((r[k] as double?) ?? 0);
        final vals = ['', isOverall ? 'OVERALL' : isGrand ? 'Grand Total' : 'Subtotal', '', '', '', n('college'), n('transport'), n('demand'), n('collection'), n('balance'), '', '', ''];
        return Container(
          color: isOverall ? AppColors.primaryLight : isGrand ? AppColors.infoBg : AppColors.tableHeadBg,
          child: Row(children: [
            for (final i in cols)
              Container(width: widths[i], padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 9.h), alignment: numCols.contains(i) ? Alignment.centerRight : Alignment.centerLeft, child: Text(vals[i], style: style, overflow: TextOverflow.ellipsis)),
          ]),
        );
      }
      final cs = AppUI.cell;
      final text = <int, String>{0: r['slno'] as String, 2: r['cls'] as String, 3: r['batch'].toString(), 4: r['sem'].toString(), 5: num0(r, 'college'), 6: num0(r, 'transport'), 7: num0(r, 'demand'), 8: num0(r, 'collection'), 9: num0(r, 'balance'), 10: r['quota'].toString(), 11: r['admtype'].toString(), 12: r['receipt'] as String};
      return Container(
        color: idx.isEven ? Colors.white : AppColors.surface,
        child: Row(children: [
          for (final i in cols)
            Container(
              width: widths[i],
              padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 8.h),
              alignment: numCols.contains(i) ? Alignment.centerRight : Alignment.centerLeft,
              child: i == 1
                  ? ((r['name'] as String).isEmpty
                      ? const SizedBox.shrink()
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(r['name'] as String, style: AppUI.cell.copyWith(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                          if ((r['admno'] as String).isNotEmpty) Text(r['admno'] as String, style: AppUI.muted),
                        ]))
                  : Text(text[i] ?? '', style: cs, overflow: TextOverflow.ellipsis, maxLines: 2),
            ),
        ]),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
      // 13 columns need ~1360px. On a narrower window the last few (Quota,
      // Adm Type, Receipt) used to be simply unreachable: the scroll view had
      // no visible bar and desktop has no horizontal wheel.
      child: _HScrollTable(
        contentWidth: w,
        expand: true,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: AppColors.tableHeadBg,
                child: Row(children: [
                  for (final i in cols)
                    Container(width: widths[i], padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 10.h), alignment: numCols.contains(i) ? Alignment.centerRight : Alignment.centerLeft, child: Text(schoolTerm(headers[i]), style: AppUI.tableHead, overflow: TextOverflow.ellipsis)),
                ]),
              ),
              const Divider(height: 1, color: AppColors.cardBorder),
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                  itemBuilder: (_, i) => rowWidget(rows[i], i),
                ),
              ),
            ],
          ),
      ),
    );
    });
  }

  Future<void> _exportDcbExcel(String course, List<Map<String, dynamic>> rows) async {
    setState(() => _dcbExporting = true);
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['DCB Register'];
      excel.delete('Sheet1');
      void put(int row, int col, dynamic value, {xl.CellStyle? style}) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
        cell.value = value is num ? xl.DoubleCellValue(value.toDouble()) : xl.TextCellValue(value?.toString() ?? '');
        if (style != null) cell.cellStyle = style;
      }
      final titleStyle = xl.CellStyle(bold: true, fontSize: 12, horizontalAlign: xl.HorizontalAlign.Center);
      final headStyle = xl.CellStyle(bold: true, fontSize: 10, backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'), fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'));
      final boldNum = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final boldTxt = xl.CellStyle(bold: true, fontSize: 10);

      int r = 0;
      if (_insName.isNotEmpty) { put(r, 1, _insName, style: titleStyle); r++; }
      if (_insAddress.isNotEmpty) { put(r, 1, _insAddress, style: titleStyle); r++; }
      put(r, 1, 'DCB Register for $course', style: titleStyle);
      put(r, 8, 'Date: ${_formatDate(DateTime.now())}');
      r += 2;
      final headers = [AppText.serialNo, 'Name & Register No', 'Class', 'Batch', 'Semester', isSchool ? 'School Demand' : 'College Demand', 'Transport Demand', 'Demand', 'Collection', 'Balance', 'Quota', 'Admission Type', 'Receipt No & Date'];
      // A school has no batch, quota or admission type: those columns are left
      // out and the ones after them close up. putC() writes by college column.
      final hidden = isSchool ? const {3, 10, 11} : const <int>{};
      void putC(int row, int col, dynamic value, {xl.CellStyle? style}) {
        if (hidden.contains(col)) return;
        put(row, col - hidden.where((h) => h < col).length, value, style: style);
      }
      for (int c = 0; c < headers.length; c++) { putC(r, c, schoolTerm(headers[c]), style: headStyle); }
      r++;
      for (final row in rows) {
        final kind = row['kind'];
        if (kind == 'data') {
          final name = (row['name'] as String).isEmpty ? '' : '${row['name']}\n${row['admno']}';
          putC(r, 0, row['slno']);
          putC(r, 1, name);
          putC(r, 2, row['cls']);
          putC(r, 3, row['batch']);
          putC(r, 4, row['sem']);
          putC(r, 5, row['college']);
          putC(r, 6, row['transport']);
          putC(r, 7, row['demand']);
          putC(r, 8, row['collection']);
          putC(r, 9, row['balance']);
          putC(r, 10, row['quota']);
          putC(r, 11, row['admtype']);
          putC(r, 12, row['receipt']);
        } else if (kind == 'courseheader') {
          put(r, 0, row['course'], style: boldTxt);
        } else {
          final isOverall = kind == 'overall';
          final isGrand = kind == 'grand';
          put(r, (isGrand || isOverall) ? 0 : 1, isOverall ? 'OVERALL' : isGrand ? 'Grand Total' : 'Subtotal', style: boldTxt);
          putC(r, 5, row['college'], style: boldNum);
          putC(r, 6, row['transport'], style: boldNum);
          putC(r, 7, row['demand'], style: boldNum);
          putC(r, 8, row['collection'], style: boldNum);
          putC(r, 9, row['balance'], style: boldNum);
        }
        r++;
      }
      sheet.setColumnWidth(1, 30);
      await _saveExcel(excel, 'DCB_Register_${course.replaceAll(RegExp(r"[^A-Za-z0-9]+"), "_")}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export the DCB Register to Excel. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    } finally {
      if (mounted) setState(() => _dcbExporting = false);
    }
  }

  Future<void> _exportDcbPdf(String course, List<Map<String, dynamic>> rows) async {
    setState(() => _dcbExporting = true);
    try {
      final headers = ['S. NO.', 'NAME & REGISTER NO', 'CLASS', 'BATCH', 'SEMESTER', isSchool ? 'SCHOOL' : 'COLLEGE', 'TRANSPORT', 'DEMAND', 'COLLECTION', 'BALANCE', 'QUOTA', 'ADMISSION TYPE', 'RECEIPT'];
      // A school has no batch, quota or admission type: those columns are left
      // out of the printed table (and the figures after them close up).
      final hidden = isSchool ? const {3, 10, 11} : const <int>{};
      int oc(int c) => c - hidden.where((h) => h < c).length;
      List<String> vis(List<String> l) => [for (int i = 0; i < l.length; i++) if (!hidden.contains(i)) l[i]];
      String n(dynamic v) { final d = (v as double?) ?? 0; return d == 0 ? '' : _formatNumber(d); }
      final data = <List<String>>[];
      for (final row in rows) {
        final kind = row['kind'];
        if (kind == 'data') {
          final nm = (row['name'] as String).isEmpty ? '' : '${row['name']}\n${row['admno']}';
          data.add(vis([
            row['slno']?.toString() ?? '', nm, row['cls']?.toString() ?? '',
            row['batch']?.toString() ?? '', row['sem']?.toString() ?? '',
            n(row['college']), n(row['transport']), n(row['demand']), n(row['collection']), n(row['balance']),
            row['quota']?.toString() ?? '', row['admtype']?.toString() ?? '', row['receipt']?.toString() ?? '',
          ]));
        } else if (kind == 'courseheader') {
          data.add(vis([row['course']?.toString() ?? '', '', '', '', '', '', '', '', '', '', '', '', '']));
        } else {
          final lbl = kind == 'overall' ? 'OVERALL' : kind == 'grand' ? 'Grand Total' : 'Subtotal';
          data.add(vis(['', lbl, '', '', '', n(row['college']), n(row['transport']), n(row['demand']), n(row['collection']), n(row['balance']), '', '', '']));
        }
      }
      final pdf = pw.Document();
      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (_insName.isNotEmpty) pw.Text(_insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('DCB Register for $course', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Date: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.TableHelper.fromTextArray(
            headers: vis(headers.map(schoolTerm).toList()),
            data: data,
            headerStyle: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 7),
            cellAlignments: {for (final i in const [5, 6, 7, 8, 9]) oc(i): pw.Alignment.centerRight},
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      await _savePdf(pdf, 'DCB_Register_${course.replaceAll(RegExp(r"[^A-Za-z0-9]+"), "_")}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the DCB Register PDF. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    } finally {
      if (mounted) setState(() => _dcbExporting = false);
    }
  }



  Future<void> _exportDailyCollectionPdf() async {
    try {
      // Same predicate as the on-screen table, so an export can never disagree
      // with what was on screen when it was pressed.
      final visibleRows = _dailyRows.where(_dailyRowVisible).toList();
      // Receipts not yet matched to a bank statement — listed in their own
      // section below, never folded into the collection totals.
      final unrecRows = _dailyUnrecRows
          .where(_dailyRowVisible)
          .where((r) => (r['type']?.toString() ?? '') != 'Refunded')
          .toList();
      final feeTypes = _feeFilterActive
          ? _dailyFeeTypes.where(_feeTypeAllowed).toList()
          : _dailyFeeTypes;

      final showCash = _selectedMode == null || _selectedMode == 'cash';
      // Cheque/DD report under BANK (see _paymentBucket), so there is no
      // separate CHEQUE column.
      // ignore: prefer_const_declarations
      final showCheque = false;
      final showBank = _selectedMode == null || _selectedMode == 'bank';

      double pdfRowTotal(Map<String, dynamic> r) {
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        if (_selectedFeeTypes.isEmpty) {
          return (r['total'] as num?)?.toDouble() ?? 0;
        }
        final fees = r['fees'] as Map<String, double>;
        double sum = 0;
        for (final ft in _selectedFeeTypes) {
          sum += fees[ft] ?? 0;
        }
        return sum + fine;
      }

      double pdfRowAdj(Map<String, dynamic> r) =>
          (r['adjusted'] as num?)?.toDouble() ?? 0;
      // Net = Total - Adjusted, clamped (see the on-screen rowNetTotal).
      double pdfRowNet(Map<String, dynamic> r) {
        final n = pdfRowTotal(r) - pdfRowAdj(r);
        return n > 0 ? n : 0;
      }

      final ftTotals = <String, double>{};
      double totalAmt = 0;
      double totalNet = 0;
      double totalFine = 0;
      double totalCash = 0;
      double totalCheque = 0;
      double totalBank = 0;
      double totalRefund = 0;
      double totalAdj = 0;
      double refundCash = 0, refundCheque = 0, refundBank = 0;
      for (final r in visibleRows) {
        final type = r['type']?.toString() ?? '';
        // Counted before the skip below: a receipt settled ENTIRELY from an
        // advance adds nothing to the day's collection but everything to this
        // column, and it is exactly the row a cashier goes looking for.
        if (type != 'Cancelled' && type != 'Refunded') {
          totalAdj += (r['adjusted'] as num?)?.toDouble() ?? 0;
        }
        // A cancelled receipt took no money and is listed for audit only. An
        // advance-adjusted one DOES belong in the fee-type columns and in
        // Total -- it settled those fees -- and drops out of the money columns
        // on its own, because its Net is Total less the whole adjustment.
        if (type == 'Cancelled') continue;
        final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
        // Refunds are a SEPARATE section (below) — not collections. Tally them
        // by mode but keep them out of the collected totals.
        if (type == 'Refunded') {
          final ra = (r['refund'] as num?)?.toDouble() ?? 0;
          totalRefund += ra;
          if (bucket == 'cash') refundCash += ra;
          else if (bucket == 'cheque') refundCheque += ra;
          else refundBank += ra;
          continue;
        }
        final fees = r['fees'] as Map<String, double>;
        final total = pdfRowTotal(r);
        // The drawer and the bank see only the money.
        final money = pdfRowNet(r);
        totalAmt += total;
        totalNet += money;
        totalFine += (r['fine'] as num?)?.toDouble() ?? 0;
        if (bucket == 'cash') totalCash += money;
        else if (bucket == 'cheque') totalCheque += money;
        else totalBank += money;
        for (final ft in feeTypes) {
          ftTotals[ft] = (ftTotals[ft] ?? 0) + (fees[ft] ?? 0);
        }
      }

      // Only show fee-type columns that actually have a value in this range —
      // otherwise dozens of empty columns crush the A4 page into unreadable
      // vertical character-wrapping.
      final shownFeeTypes = feeTypes.where((ft) => (ftTotals[ft] ?? 0).abs() > 0.0001).toList();

      final modeHeaders = <String>[
        if (showCash) 'Cash',
        if (showCheque) 'Cheque',
        if (showBank) 'Bank',
      ];
      // Same rule the fee-type columns follow: a column nobody has a figure in
      // is dropped, because on a landscape A4 an empty one costs width the
      // columns that DO carry figures need. Counts the unreconciled section
      // too -- it prints in the same table.
      final showFine = totalFine.abs() > 0.0001 ||
          unrecRows.any((r) => ((r['fine'] as num?)?.toDouble() ?? 0) != 0);
      final headers = ['Receipt No', schoolTerm('Register No'), 'Student Name', schoolTerm('Class'),
        ...shownFeeTypes.map(_feeHdr), if (showFine) 'Fine', 'Total', ...modeHeaders,
        'Adjusted', 'Net Amount'];
      final rows = <List<String>>[];
      for (final r in visibleRows) {
        // Refunds are not collections — they go in their own section below.
        if ((r['type']?.toString() ?? '') == 'Refunded') continue;
        final fees = r['fees'] as Map<String, double>;
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
        // Cancelled receipt — listed for audit with no paid amount: 'CANCELLED'
        // in the Total column, every other money cell blank.
        final cancelled = (r['type']?.toString() ?? '') == 'Cancelled';
        final total = cancelled ? 0.0 : pdfRowTotal(r);
        final adj = cancelled ? 0.0 : pdfRowAdj(r);
        final money = cancelled ? 0.0 : pdfRowNet(r);
        rows.add([
          r['paynumber']?.toString() ?? '',
          r['stuadmno']?.toString() ?? '',
          r['stuname']?.toString() ?? '',
          r['stuclass']?.toString() ?? '',
          ...shownFeeTypes.map((ft) => (!cancelled && (fees[ft] ?? 0) > 0) ? _formatNumber(fees[ft]!) : ''),
          if (showFine) ((!cancelled && fine > 0) ? _formatNumber(fine) : ''),
          cancelled ? 'CANCELLED' : _formatNumber(total),
          if (showCash) ((!cancelled && bucket == 'cash' && money > 0) ? _formatNumber(money) : ''),
          if (showCheque) ((!cancelled && bucket == 'cheque' && money > 0) ? _formatNumber(money) : ''),
          if (showBank) ((!cancelled && bucket == 'bank' && money > 0) ? _formatNumber(money) : ''),
          adj > 0 ? _formatNumber(adj) : '',
          cancelled ? '' : _formatNumber(money),
        ]);
      }
      rows.add([
        'TOTAL', '', '', '',
        ...shownFeeTypes.map((ft) => _formatNumber(ftTotals[ft] ?? 0)),
        if (showFine) (totalFine > 0 ? _formatNumber(totalFine) : ''),
        _formatNumber(totalAmt),
        if (showCash) _formatNumber(totalCash),
        if (showCheque) _formatNumber(totalCheque),
        if (showBank) _formatNumber(totalBank),
        _formatNumber(totalAdj),
        _formatNumber(totalNet),
      ]);
      // Refunds section — separate details keyed to the refund date, listing
      // Receipts still awaiting bank reconciliation — their own section with its
      // own total, never part of Total Collected above: the money is in hand but
      // unconfirmed.
      if (unrecRows.isNotEmpty) {
        List<String> uBlankTail() => [
              ...shownFeeTypes.map((_) => ''),
              if (showFine) '',
              '',
              if (showCash) '',
              if (showCheque) '',
              if (showBank) '',
              '',
              '',
            ];
        rows.add(['UNRECONCILED (NOT YET MATCHED TO A BANK STATEMENT)', '', '', '', ...uBlankTail()]);
        double uTotal = 0, uFine = 0, uCash = 0, uCheque = 0, uBank = 0;
        double uAdj = 0, uNet = 0;
        for (final r in unrecRows) {
          final fees = r['fees'] as Map<String, double>;
          final fine = (r['fine'] as num?)?.toDouble() ?? 0;
          final total = pdfRowTotal(r);
          final adj = pdfRowAdj(r);
          final money = pdfRowNet(r);
          final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
          uTotal += total;
          uAdj += adj;
          uNet += money;
          uFine += fine;
          if (bucket == 'cash') { uCash += money; }
          else if (bucket == 'cheque') { uCheque += money; }
          else { uBank += money; }
          rows.add([
            r['paynumber']?.toString() ?? '',
            r['stuadmno']?.toString() ?? '',
            r['stuname']?.toString() ?? '',
            r['stuclass']?.toString() ?? '',
            ...shownFeeTypes.map((ft) => (fees[ft] ?? 0) > 0 ? _formatNumber(fees[ft]!) : ''),
            if (showFine) (fine > 0 ? _formatNumber(fine) : ''),
            _formatNumber(total),
            if (showCash) (bucket == 'cash' && money > 0 ? _formatNumber(money) : ''),
            if (showCheque) (bucket == 'cheque' && money > 0 ? _formatNumber(money) : ''),
            if (showBank) (bucket == 'bank' && money > 0 ? _formatNumber(money) : ''),
            adj > 0 ? _formatNumber(adj) : '',
            _formatNumber(money),
          ]);
        }
        rows.add([
          'TOTAL UNRECONCILED', '', '', '',
          ...shownFeeTypes.map((_) => ''),
          if (showFine) (uFine > 0 ? _formatNumber(uFine) : ''),
          _formatNumber(uTotal),
          if (showCash) _formatNumber(uCash),
          if (showCheque) _formatNumber(uCheque),
          if (showBank) _formatNumber(uBank),
          uAdj > 0 ? _formatNumber(uAdj) : '',
          _formatNumber(uNet),
        ]);
      }

      // each refund then a by-mode total. Never part of Total Collected.
      final refundList = visibleRows.where((r) => (r['type']?.toString() ?? '') == 'Refunded').toList();
      if (refundList.isNotEmpty) {
        List<String> blankTail() => [
              ...shownFeeTypes.map((_) => ''),
              if (showFine) '',
              '',
              if (showCash) '',
              if (showCheque) '',
              if (showBank) '',
              '',
              '',
            ];
        rows.add(['REFUNDS (THIS PERIOD)', '', '', '', ...blankTail()]);
        for (final r in refundList) {
          final a = (r['refund'] as num?)?.toDouble() ?? 0;
          final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
          rows.add([
            r['paynumber']?.toString() ?? '',
            r['stuadmno']?.toString() ?? '',
            r['stuname']?.toString() ?? '',
            r['stuclass']?.toString() ?? '',
            ...shownFeeTypes.map((_) => ''),
            if (showFine) '',
            _formatNumber(a),
            if (showCash) (bucket == 'cash' ? _formatNumber(a) : ''),
            if (showCheque) (bucket == 'cheque' ? _formatNumber(a) : ''),
            if (showBank) (bucket == 'bank' ? _formatNumber(a) : ''),
            '',
            _formatNumber(a),
          ]);
        }
        rows.add([
          'TOTAL REFUND', '', '', '',
          ...shownFeeTypes.map((_) => ''),
          if (showFine) '',
          _formatNumber(totalRefund),
          if (showCash) _formatNumber(refundCash),
          if (showCheque) _formatNumber(refundCheque),
          if (showBank) _formatNumber(refundBank),
          '',
          _formatNumber(totalRefund),
        ]);
      }

      final pdf = pw.Document();
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
          header: (_) {
            // "Collected by" line - shows who the report covers.
            //   * specific user filter active â†’ that user's name
            //   * no filter + 1 accountant visible in rows â†’ their name
            //   * no filter + multiple â†’ "All accountants" so the report
            //     makes it obvious that the totals span more than one
            //     cashier (prevents a cashier accepting a report for
            //     someone else's work).
            // Names a cashier only when one was filtered for -- see the A3
            // statement. 'All Users' matches the wording there.
            final collectedBy = _selectedUser ?? 'All Users';
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(_insName, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
                pw.SizedBox(height: 6),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('DAILY COLLECTION STATEMENT FROM ${_formatDate(_dailyFrom!)} TO ${_formatDate(_dailyTo!)}',
                        style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Date: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
                  ],
                ),
                pw.SizedBox(height: 2),
                pw.Text('Collected By: $collectedBy', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 6),
              ],
            );
          },
          build: (ctx) => [
            pw.Table.fromTextArray(
              headers: headers,
              data: rows,
              headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
              cellStyle: const pw.TextStyle(fontSize: 7.5),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {
                for (int i = 4; i < headers.length - 1; i++) i: pw.Alignment.centerRight,
              },
              // Give the identity columns real width so names don't wrap
              // character-by-character; numeric columns share the remainder.
              columnWidths: {
                0: const pw.FixedColumnWidth(46),
                1: const pw.FixedColumnWidth(54),
                2: const pw.FlexColumnWidth(2.4),
                3: const pw.FlexColumnWidth(1.3),
                4: const pw.FlexColumnWidth(1.3),
                for (int i = 5; i < headers.length; i++) i: const pw.FlexColumnWidth(1),
              },
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
              headerHeight: 26,
              cellHeight: 16,
            ),
          ],
        ),
      );

      await _savePdf(pdf, 'Daily_Collection_${_formatDateCompact(_dailyFrom!)}_${_formatDateCompact(_dailyTo!)}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the PDF. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  Future<void> _saveExcel(xl.Excel excel, String fileName) async {
    final bytes = excel.encode();
    if (bytes == null) return;

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Report',
      fileName: '$fileName.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (result == null) return;

    final file = File(result);
    await file.writeAsBytes(bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Report saved: ${file.path}'), backgroundColor: AppColors.success),
      );
    }
  }

  /// The DAILY COLLECTION STATEMENT, in the printed layout the office has
  /// always used: receipt number, one column per fee type (short codes), then
  /// Total / Cash / DD-Cheque / Bank / Net, and a status column.
  ///
  /// Deliberately different from the Excel and PDF exports:
  ///   * It lists EVERY receipt in the range in receipt-number order -- normal,
  ///     cancelled and not-yet-reconciled alike -- so the sequence reads
  ///     continuously with no gaps. A gap in a receipt book is what an auditor
  ///     asks about, and the other exports hide unreconciled receipts in a
  ///     separate section.
  ///   * The last column flags why a row is not ordinary money: UR = collected
  ///     but not yet matched to a bank statement, CAN = cancelled receipt.
  ///   * DD/Cheque keeps its own column here even though the on-screen report
  ///     folds it into Bank, because the printed statement has always shown it.
  ///
  /// Goes through Printing.layoutPdf, which opens the OS print preview -- the
  /// report is reviewed on screen and printed from the same dialog.
  Future<void> _printDailyStatement() async {
    try {
      // Collections in the range, cancelled ones included; refunds are not
      // collections and never appear.
      final normal = _dailyRows
          .where(_dailyRowVisible)
          .where((r) => (r['type']?.toString() ?? '') != 'Refunded')
          .map((r) => {...r, '_st': ''})
          .toList();
      // ...plus the unreconciled ones, which the other exports keep separate.
      final unrec = _dailyUnrecRows
          .where(_dailyRowVisible)
          .where((r) => (r['type']?.toString() ?? '') != 'Refunded')
          .map((r) => {...r, '_st': 'UR'})
          .toList();

      // One continuous list in receipt order. Numeric on the trailing digits so
      // FC26/02599 precedes FC26/02600 rather than sorting as text.
      int recNo(Map<String, dynamic> r) {
        final m = RegExp(r'(\d+)\s*$').firstMatch(r['paynumber']?.toString().trim() ?? '');
        return m == null ? -1 : (int.tryParse(m.group(1)!) ?? -1);
      }
      final rows = [...normal, ...unrec]
        ..sort((a, b) {
          final c = recNo(a).compareTo(recNo(b));
          return c != 0
              ? c
              : (a['paynumber']?.toString() ?? '').compareTo(b['paynumber']?.toString() ?? '');
        });

      if (rows.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Nothing to print for this range / filter.'),
              backgroundColor: AppColors.warning));
        }
        return;
      }

      final allFeeTypes = _feeFilterActive
          ? _dailyFeeTypes.where(_feeTypeAllowed).toList()
          : _dailyFeeTypes;
      // ADVANCE is not a fee. It is money taken in against no demand at all, so
      // it reads with the money columns rather than among the fees a student
      // was billed -- sorted alphabetically it landed between SPORTS FEE and
      // AUF, where it looked like another charge.
      final advKey = allFeeTypes.firstWhere(
          (t) => t.trim().toUpperCase() == 'ADVANCE',
          orElse: () => '');
      final feeTypes = allFeeTypes.where((t) => t != advKey).toList();

      // Blank rather than 0 in an empty money cell -- the printed sheet is read
      // by eye, and a grid of zeros hides the figures that matter.
      String amt(double v) => v == 0 ? '' : _formatNumber(v);

      // ── One printed line per receipt ──────────────────────────────────────
      // A receipt can reach here as SEVERAL rows -- a fine booked apart from
      // the fee it belongs to, or a settlement spanning more than one demand --
      // and the sheet printed each as its own line. FC26/02991 came out twice,
      // once carrying 75 of fine and once 66,500 of term fee, reading as two
      // receipts that each had their own Total and Net.
      //
      // Merge them back onto one line. Amounts add; cash and bank are kept
      // apart through the merge, so a receipt settled partly in each still
      // shows both. Grouped on the receipt number AND its status, because a
      // cancelled line and a live one never belong on the same row.
      final byReceipt = <String, Map<String, dynamic>>{};
      final receiptOrder = <String>[];
      for (final r in rows) {
        final cancelled = (r['type']?.toString() ?? '') == 'Cancelled';
        final st = cancelled ? 'CAN' : (r['_st']?.toString() ?? '');
        final no = r['paynumber']?.toString() ?? '';
        final key = '$no|$st';
        final m = byReceipt.putIfAbsent(key, () {
          receiptOrder.add(key);
          return <String, dynamic>{
            'no': no,
            'cancelled': cancelled,
            'st': st,
            'fees': <String, double>{},
            'fine': 0.0,
            'total': 0.0,
            'adj': 0.0,
            'cash': 0.0,
            'bank': 0.0,
          };
        });
        if (cancelled) continue; // nothing on a cancelled line but its number

        final fees = r['fees'] as Map<String, double>;
        final mf = m['fees'] as Map<String, double>;
        for (final ft in allFeeTypes) {
          final v = fees[ft] ?? 0;
          if (v != 0) mf[ft] = (mf[ft] ?? 0) + v;
        }
        final total = (r['total'] as num?)?.toDouble() ?? 0;
        final adj = (r['adjusted'] as num?)?.toDouble() ?? 0;
        // What actually came in for this line.
        final money = (total - adj) > 0 ? total - adj : 0.0;
        // Two buckets only: what is in the drawer, and what goes to the bank.
        // Cheque and DD are banked instruments, so they count as Bank -- same
        // rule as _paymentBucket and the on-screen report.
        final isCash = (r['paymethod']?.toString() ?? '').toUpperCase().contains('CASH');
        m['fine'] = (m['fine'] as double) + ((r['fine'] as num?)?.toDouble() ?? 0);
        m['total'] = (m['total'] as double) + total;
        m['adj'] = (m['adj'] as double) + adj;
        final bucket = isCash ? 'cash' : 'bank';
        m[bucket] = (m[bucket] as double) + money;
      }

      double cash = 0, bank = 0, net = 0, fineTot = 0;
      // Total column = the whole settlement; Net Amt = that less Adjusted.
      double grossTot = 0;
      // Settled out of an advance. Its own column and its own total, never
      // added into Net: that money was collected on the day the advance was
      // taken. Without the column a receipt paid entirely from an advance
      // printed as a bare receipt number with every figure blank.
      double adjTot = 0;
      final ftTotals = <String, double>{};

      for (final key in receiptOrder) {
        final m = byReceipt[key]!;
        if (m['cancelled'] as bool) continue;
        grossTot += m['total'] as double;
        cash += m['cash'] as double;
        bank += m['bank'] as double;
        net += (m['cash'] as double) + (m['bank'] as double);
        fineTot += m['fine'] as double;
        adjTot += m['adj'] as double;
        final mf = m['fees'] as Map<String, double>;
        for (final ft in allFeeTypes) {
          ftTotals[ft] = (ftTotals[ft] ?? 0) + (mf[ft] ?? 0);
        }
      }

      // ── A FIXED set of columns ────────────────────────────────────────────
      // Columns used to be dropped when nothing had been paid into them, so the
      // sheet changed shape with its contents: a quarter's range with two fee
      // types in it printed six columns, the same statement for one day printed
      // fourteen. Two reports of the same document could not be read side by
      // side, compared month to month, or filed as one series -- and with the
      // table sized to those six columns the whole block shrank to half the
      // sheet, which is what forced the college name onto two lines.
      //
      // Every column is now always present. A blank column is information: it
      // says nothing came in under that head. A sheet whose columns sit in the
      // same place every time can be read by eye.
      final shownFeeTypes = feeTypes;
      // ADVANCE is conditional, and STRUCTURAL rather than data-driven: an
      // institution with no ADVANCE head has no such column to leave blank.
      final showAdvance = advKey.isNotEmpty;
      // FINE is the deliberate exception to the fixed set, and it earns it.
      //
      // There are TWO kinds of fine in this system. Most are billed as a FEE
      // TYPE literally named FINE, so they already have a column among the fee
      // types. This one is the separate feedemand.fineamount, and it is rare --
      // Rs 100 across the whole of 2026 against Rs 355 of the other kind in a
      // single day.
      //
      // Printed unconditionally it puts a second column headed FINE next to the
      // first, usually reading 0, which reads as a duplicate rather than as a
      // different kind of money. It is shown only when it carries something.
      final showFine = fineTot != 0;
      // Same rule for the three settlement columns. Adjusted in particular is
      // empty on most days -- it only carries money settled out of an advance
      // -- and an all-blank column with a 0 total takes width from the fee
      // types that do carry figures. Cash and Bank follow the same test: a
      // day with no cash at all should not print a cash column.
      //
      // Total and Net Amt are NOT gated. They are the summary the statement
      // exists for, and a zero there is itself the answer.
      final showCash = cash != 0;
      final showBank = bank != 0;
      final showAdj  = adjTot != 0;

      final body = <List<String>>[];
      for (final key in receiptOrder) {
        final m = byReceipt[key]!;
        final cancelled = m['cancelled'] as bool;
        final mf = m['fees'] as Map<String, double>;
        final total = m['total'] as double;
        final rowCash = m['cash'] as double;
        final rowBank = m['bank'] as double;
        body.add([
          m['no'] as String,
          ...shownFeeTypes.map((ft) => (mf[ft] ?? 0) != 0 ? _formatNumber(mf[ft]!) : ''),
          if (showFine) amt(m['fine'] as double),
          if (showAdvance) amt(mf[advKey] ?? 0),
          cancelled ? '' : amt(total),
          if (showCash) amt(rowCash),
          if (showBank) amt(rowBank),
          if (showAdj) amt(m['adj'] as double),
          cancelled ? '' : amt(rowCash + rowBank),
          m['st'] as String,
        ]);
      }

      body.add([
        'TOTAL',
        ...shownFeeTypes.map((ft) => _formatNumber(ftTotals[ft] ?? 0)),
        if (showFine) _formatNumber(fineTot),
        if (showAdvance) _formatNumber(ftTotals[advKey] ?? 0),
        _formatNumber(grossTot),
        if (showCash) _formatNumber(cash),
        if (showBank) _formatNumber(bank),
        if (showAdj) _formatNumber(adjTot),
        _formatNumber(net),
        '',
      ]);

      final headers = <String>[
        'RECEIPT NO',
        ...shownFeeTypes.map(_feeHdr),
        if (showFine) 'FINE',
        if (showAdvance) 'ADVANCE',
        'TOTAL',
        if (showCash) 'CASH',
        if (showBank) 'BANK',
        if (showAdj) 'ADJUSTED',
        'NET AMOUNT',
        'STATUS',
      ];

      // The header states the report's SCOPE, so it names a cashier only when
      // one was actually filtered for. Inferring it from the data -- "only
      // LATHA appears, so title it LATHA" -- claimed a filter nobody applied,
      // and the same unfiltered report would relabel itself the moment a second
      // cashier's receipt landed in the range.
      final collectedBy = _selectedUser ?? 'All Users';

      // ── Column widths, measured from the content ──────────────────────────
      // The fee-type columns are open-ended: new fee types keep being added, so
      // this cannot be a hand-tuned list of widths. Each column is measured
      // against the widest string it actually holds.
      //
      // Helvetica: digits are ~0.556em, bold caps run wider, so headers are
      // measured at a higher rate than the data -- otherwise a header like
      // "SPORTS FEE" wraps onto two lines while its column looks half empty.
      const double kBaseFont = 9.0, kMinFont = 5.5;
      // kColPad = the two 2.5pt cell paddings plus the border, and ~2pt of
      // slack so a slightly-wider glyph than the estimate cannot clip.
      // 0.72, not 0.66: bold capitals in Helvetica run wider than the old
      // estimate allowed, so a seven-letter heading like ADVANCE wrapped to
      // 'ADVANC / E' inside a column that measured itself as wide enough.
      const double kHdrEm = 0.72, kCellEm = 0.56, kColPad = 7.0;

      double naturalAt(double pt) {
        var total = 0.0;
        for (var i = 0; i < headers.length; i++) {
          var w = headers[i].length * pt * kHdrEm;
          for (final r in body) {
            final c = r[i].length * pt * kCellEm;
            if (c > w) w = c;
          }
          total += w + kColPad;
        }
        return total;
      }

      final avail = PdfPageFormat.a3.landscape.width - 32; // page less margins
      // Enough fee types and even A3 runs out. Shrink the TYPE along with the
      // columns -- squeezing widths alone just wraps every cell into two lines.
      var fontPt = kBaseFont;
      final natural = naturalAt(kBaseFont);
      if (natural > avail) {
        fontPt = (kBaseFont * (avail / natural)).clamp(kMinFont, kBaseFont);
      }
      final colWidths = <double>[
        for (var i = 0; i < headers.length; i++)
          () {
            var w = headers[i].length * fontPt * kHdrEm;
            for (final r in body) {
              final c = r[i].length * fontPt * kCellEm;
              if (c > w) w = c;
            }
            return w + kColPad;
          }(),
      ];
      // The status column gets a few points of slack. It holds CAN / UR, three
      // capitals against a two-character header, and the character-count
      // estimate lands a hair under what Helvetica actually needs -- CAN wrapped
      // to CA / N on two lines. It is the narrowest column on the sheet, so the
      // slack costs nothing and it scales down with everything else below.
      if (colWidths.isNotEmpty) colWidths[colWidths.length - 1] += 6;
      // ── Shrink to fit, never stretch ──────────────────────────────────────
      // The columns keep exactly the width their contents need. Stretching them
      // out to the sheet was tried and was worse than the problem it fixed: a
      // two-receipt statement has nine columns needing about 450pt, and forcing
      // those across 1,159pt of A3 turned every column into a wide empty box
      // with a number in one corner.
      //
      // Nothing here has to reach the edge of the paper any more -- the heading
      // is sized to the SHEET rather than to the table (see heading() below), so
      // a narrow table can no longer drag the college name onto two lines.
      //
      // Shrinking stays unbounded: a table wider than the sheet MUST come in,
      // and below kMinFont the type stops shrinking so only the columns move.
      final fitted = colWidths.fold<double>(0, (a, b) => a + b);
      if (fitted > avail) {
        final k = avail / fitted;
        for (var i = 0; i < colWidths.length; i++) {
          colWidths[i] *= k;
        }
      }
      // ── Always A3 landscape ───────────────────────────────────────────────
      // This used to pick the smallest paper the table fitted on -- A4 portrait
      // for a narrow statement, A3 landscape for a wide one. It meant the same
      // report came out on different paper from one run to the next, and the
      // preview and the printer dialog were both hard-coded to A3 landscape
      // anyway: an A4 layout laid on an A3 sheet covers 297 of 420mm, which is
      // the stranded table with the wrapped college name over it.
      //
      // The office prints this statement on A3 landscape. It is now built for
      // A3 landscape every time, and the columns above stretch to fill it, so
      // one receipt and a thousand produce the same sheet.
      final pageFormat = PdfPageFormat.a3.landscape;

      // The finished table width. Used ONLY for the Collected By / Date line,
      // which belongs to the table rather than to the page.
      final tableW = colWidths.fold<double>(0, (a, b) => a + b);

      // The whole heading block, as a widget rather than a build() child:
      // MultiPage renders build() children once, so a two-page statement had
      // the college name only on page 1 and page 2 opened on a bare grid. As
      // the header callback it is drawn on every page instead.
      // TWO widths, deliberately.
      //
      // The TITLE BLOCK -- college name, address, statement line -- takes the
      // whole SHEET. It used to take the table's width, which meant a statement
      // with few columns squeezed the college name into a narrow box and broke
      // it across two lines while a wide one kept it on one. That block has to
      // look identical on every statement, so it is never sized by its contents.
      //
      // The COLLECTED BY / DATE line takes the TABLE's width, because those two
      // read as the table's own column headings -- pinned to the page edges they
      // float far away from the grid they describe, with a hand's width of
      // nothing between.
      pw.Widget heading() => pw.Center(
            child: pw.SizedBox(
              width: avail,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Center(
                    child: pw.Column(children: [
                      pw.Text(_insName.toUpperCase(),
                          style: pw.TextStyle(
                              fontSize: 15, fontWeight: pw.FontWeight.bold)),
                      if (_insAddress.isNotEmpty)
                        pw.Text(_insAddress.toUpperCase(),
                            textAlign: pw.TextAlign.center,
                            style: pw.TextStyle(
                                fontSize: 12, fontWeight: pw.FontWeight.bold)),
                    ]),
                  ),
                  pw.SizedBox(height: 10),
                  pw.Center(
                    child: pw.Text(
                        'DAILY COLLECTION STATEMENT FROM ${_dailyFmt(_dailyFrom)} TO ${_dailyFmt(_dailyTo)}',
                        textAlign: pw.TextAlign.center,
                        style: pw.TextStyle(
                            fontSize: 13, fontWeight: pw.FontWeight.bold)),
                  ),
                  pw.SizedBox(height: 4),
                  // Left and right ends line up with the table's own edges.
                  pw.Center(
                    child: pw.SizedBox(
                      width: tableW,
                      child: pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Collected By: $collectedBy',
                                style: pw.TextStyle(
                                    fontSize: 11,
                                    fontWeight: pw.FontWeight.bold)),
                            pw.Text('Date: ${_dailyFmt(DateTime.now())}',
                                style: pw.TextStyle(
                                    fontSize: 11,
                                    fontWeight: pw.FontWeight.bold)),
                          ]),
                    ),
                  ),
                  pw.SizedBox(height: 6),
                ],
              ),
            ),
          );

      final pdf = pw.Document();
      pdf.addPage(pw.MultiPage(
        // A3 landscape: this statement is printed on A3, and an A4 layout put
        // on A3 paper covers only 297/420 of the width -- a table stranded at
        // 70% of the sheet with type too small to read.
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.fromLTRB(16, 20, 16, 22),
        // Centre the block on the sheet. Done here rather than by wrapping the
        // table in a Center: only a direct child of build() can be split across
        // pages, and a Center is not splittable -- a long statement would stop
        // paginating and overflow the first page.
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        header: (ctx) => heading(),
        footer: (ctx) => pw.Center(
          child: pw.Text('${ctx.pageNumber}', style: const pw.TextStyle(fontSize: 10)),
        ),
        build: (ctx) => [
          // Kept OUT of the table's own widget so MultiPage can still split the
          // table across pages -- only a direct child of build() is splittable.
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: body,
            // Without this the measured widths are thrown away: fromTextArray
            // defaults to TableWidth.max, and with no flex column the pdf
            // package rescales EVERY fixed width up to fill the page
            // (table.dart, "tableWidth == TableWidth.max && totalFlex == 0.0").
            // That is what padded RECEIPT NO and SPORTS FEE with dead space.
            tableWidth: pw.TableWidth.min,
            // FIXED widths, measured from the content -- not flex. Flex always
            // consumes 100% of the page, so every column was padded out with
            // dead space to fill an A3 sheet. These are sized to the widest
            // string each column actually holds; a wide sheet then leaves
            // margin on the right instead of inflating every cell.
            columnWidths: {
              for (var i = 0; i < headers.length; i++)
                i: pw.FixedColumnWidth(colWidths[i]),
            },
            border: pw.TableBorder.all(width: 0.6, color: PdfColors.black),
            headerStyle: pw.TextStyle(fontSize: fontPt, fontWeight: pw.FontWeight.bold),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.white),
            cellStyle: pw.TextStyle(fontSize: fontPt),
            cellHeight: fontPt * 1.7,
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 2.5, vertical: 1.5),
            headerAlignment: pw.Alignment.center,
            cellAlignment: pw.Alignment.centerRight,
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              headers.length - 1: pw.Alignment.center,
            },
          ),
        ],
      ));

      // Show the PAGE first. Printing.layoutPdf goes straight to the Windows
      // printer-setup dialog -- printer, paper size, orientation -- which shows
      // nothing of the document, so a wrong date range or a clipped column is
      // only discovered on paper. _showPdfPreview renders the actual pages and
      // keeps a Print button for when it looks right.
      await _showPdfPreview(
        pdf,
        // The printer dialog picks portrait A4 unless told otherwise and then
        // clips a table this wide; the document's own landscape format is not
        // enough on its own.
        format: PdfPageFormat.a3.landscape,
        name:
            'Daily_Collection_Statement_${_formatDateCompact(_dailyFrom!)}_${_formatDateCompact(_dailyTo!)}',
      );
    } catch (e, st) {
      // The real error, not just the friendly one. A 1,300-row statement can
      // fail for reasons the generic message hides (memory, a null cell, a
      // format), and "something went wrong" leaves nothing to act on.
      debugPrint('Daily statement print failed: $e');
      debugPrint(st.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not print the statement. ${friendlyError(e)}', maxLines: 4),
            duration: const Duration(seconds: 8),
            backgroundColor: AppColors.error));
      }
    }
  }

  /// On-screen preview of a generated PDF, with a Print action.
  ///
  /// Printing.layoutPdf hands the document to the OS printer-setup dialog,
  /// which asks for printer/paper/orientation and shows none of the content.
  /// This renders the pages, so a wrong date range, a clipped column or a bad
  /// page break is caught before anything is printed.
  ///
  /// The document is serialised ONCE, here, and the same bytes are handed to
  /// both the preview and the printer. PdfPreview calls its `build` callback
  /// whenever it re-renders, and a pw.Document cannot be saved repeatedly --
  /// on a large statement that showed up as an intermittent "print failed"
  /// rather than an error anyone could act on. Saving once also avoids
  /// re-serialising a 1,300-row document on every rebuild.
  ///
  /// Page format and orientation are fixed: these statements are laid out for a
  /// specific sheet, and letting the preview re-flow them to A4 portrait would
  /// show something that is not what prints.
  Future<void> _showPdfPreview(
    pw.Document pdf, {
    required PdfPageFormat format,
    required String name,
  }) async {
    final bytes = await pdf.save();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 28.h),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // ── header ────────────────────────────────────────────────────
            Container(
              padding: EdgeInsets.fromLTRB(20.w, 12.h, 10.w, 12.h),
              color: Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: AppUI.cardHeader(
                      icon: 'printer',
                      title: 'Print Preview',
                      subtitle: '$name.pdf  ·  A3 landscape',
                    ),
                  ),
                  Tooltip(
                    message: 'Close',
                    child: Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: Padding(
                          padding: EdgeInsets.all(6.w),
                          child: const Icon(Icons.close,
                              color: AppColors.textSecondary, size: 20),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ── the pages ─────────────────────────────────────────────────
            Expanded(
              child: Container(
                color: AppColors.surface,
                child: PdfPreview(
                  build: (_) async => bytes,
                  initialPageFormat: format,
                  pdfFileName: '$name.pdf',
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  allowSharing: false,
                  allowPrinting: false, // the footer button below does this
                  useActions: false,
                  maxPageWidth: 1400,
                  padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 14.h),
                  scrollViewDecoration:
                      const BoxDecoration(color: AppColors.surface),
                  pdfPreviewPageDecoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4.r),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 8,
                          offset: Offset(0, 3)),
                    ],
                  ),
                  // Surface a preview-side failure instead of a blank pane.
                  onError: (context, error) => Center(
                    child: Padding(
                      padding: EdgeInsets.all(24.w),
                      child: Text('Could not show the preview. '
                          'You can still export the statement to Excel or PDF.',
                          textAlign: TextAlign.center,
                          style: AppUI.muted),
                    ),
                  ),
                ),
              ),
            ),
            // ── footer ────────────────────────────────────────────────────
            const Divider(height: 1, color: AppColors.divider),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Close'),
                  ),
                  SizedBox(width: 10.w),
                  ElevatedButton.icon(
                    onPressed: () => Printing.layoutPdf(
                      // Same bytes the preview showed, so what prints is
                      // exactly what was checked.
                      onLayout: (_) async => bytes,
                      format: format,
                      name: name,
                    ),
                    icon: const Icon(Icons.print, size: 16),
                    label: const Text('Print'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Save a PDF straight to a file (Save-As dialog) instead of routing it
  /// through the OS print dialog (Printing.layoutPdf). Matches _saveExcel.
  Future<void> _savePdf(pw.Document pdf, String fileName) async {
    final bytes = await pdf.save();
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF',
      fileName: '$fileName.pdf',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null) return;
    final path = result.toLowerCase().endsWith('.pdf') ? result : '$result.pdf';
    final file = File(path);
    await file.writeAsBytes(bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF saved: ${file.path}'), backgroundColor: AppColors.success),
      );
    }
  }
}

/// Stateful wrapper so the horizontal ScrollController survives across
/// rebuilds. Before this, applying a filter created a new ScrollController
/// every build - the scrollbar thumb would freeze in place because the
/// AnimatedBuilder was listening to an orphaned controller that was never
/// attached to a live ScrollView.
class _StickyTable extends StatefulWidget {
  const _StickyTable({
    required this.columnWidths,
    required this.headers,
    required this.rows,
    required this.footer,
    required this.numericCols,
    this.centerCols = const {},
    this.cellFontSize,
    this.headerFontSize,
    this.cellGap,
    this.rowTints,
  });

  final List<double> columnWidths;
  final List<String> headers;
  final List<List<String>> rows;
  final List<String> footer;
  final Set<int> numericCols;
  final Set<int> centerCols;

  /// Per-report type size and column gutter. Null keeps the defaults every
  /// other report table already uses.
  final double? cellFontSize;
  final double? headerFontSize;
  final double? cellGap;

  /// Optional per-row background, one entry per row. A null entry (or a null
  /// list) falls back to the usual zebra striping, so every other report that
  /// does not pass this is untouched.
  final List<Color?>? rowTints;

  @override
  State<_StickyTable> createState() => _StickyTableState();
}

/// A horizontally scrollable table body with the project's classic scrollbar
/// underneath, shown only when the content is actually wider than the window.
///
/// Each instance owns its ScrollController, because the Collection Statement
/// renders one of these per course — a single shared controller would be
/// attached to several positions at once and throw.
class _HScrollTable extends StatefulWidget {
  const _HScrollTable({
    required this.contentWidth,
    required this.child,
    this.expand = false,
  });

  /// Laid-out width of the table. When it fits, no bar is drawn and the view
  /// is locked so the content can't drift sideways.
  final double contentWidth;

  /// true when the host gives a bounded height and the table should fill it
  /// (sticky header + internally scrolling rows); false when the table is
  /// content-sized and the page around it scrolls.
  final bool expand;

  final Widget child;

  @override
  State<_HScrollTable> createState() => _HScrollTableState();
}

class _HScrollTableState extends State<_HScrollTable> {
  final ScrollController _h = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HScrollTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Content may have changed width after a filter, leaving the thumb sized
    // for the old extent. A ScrollController only notifies on user scroll, so
    // nudge it once the new layout exists. jumpTo(offset) is a no-op that
    // still fires notifyListeners().
    if (oldWidget.contentWidth == widget.contentWidth) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_h.hasClients) return;
      _h.jumpTo(_h.offset.clamp(0.0, _h.position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final needsScroll = widget.contentWidth > constraints.maxWidth + 0.5;
        final view = SingleChildScrollView(
          controller: _h,
          scrollDirection: Axis.horizontal,
          physics: needsScroll ? null : const NeverScrollableScrollPhysics(),
          child: SizedBox(width: widget.contentWidth, child: widget.child),
        );
        if (!needsScroll) return view;
        return Column(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (widget.expand) Expanded(child: view) else view,
            ClassicHScrollbar(
              controller: _h,
              contentWidth: widget.contentWidth,
              viewportWidth: constraints.maxWidth,
            ),
          ],
        );
      },
    );
  }
}

class _StickyTableState extends State<_StickyTable> {
  final ScrollController _hController = ScrollController();
  // Vertical scroll for the body rows. Kept separate so the custom vertical
  // scrollbar can live in a lane pinned to the viewport, instead of off-screen
  // at the far-right edge of the (wider) horizontally-scrolling content.
  final ScrollController _vController = ScrollController();

  @override
  void dispose() {
    _hController.dispose();
    _vController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _StickyTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Content (rows/columns) may have changed after a filter, so the
    // thumb size/position is probably now wrong. A ScrollController only
    // notifies listeners on user scroll, not on content resize, so the
    // scrollbar would otherwise keep the old ratio until the user scrolls.
    // Poke it once after the next frame so the AnimatedBuilder reruns
    // with the fresh maxScrollExtent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hController.hasClients) return;
      // jumpTo(offset) is a no-op that still fires notifyListeners().
      _hController.jumpTo(_hController.offset.clamp(0.0, _hController.position.maxScrollExtent));
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hController.hasClients) return;
      _hController.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.columnWidths.length == widget.headers.length);
    final baseTotal = widget.columnWidths.fold<double>(0, (a, b) => a + b.w);
    final headFs = widget.headerFontSize ?? 12;
    final cellFs = widget.cellFontSize ?? 13;
    final gap = widget.cellGap ?? 10;
    final headerStyle = AppUI.tableHead.copyWith(fontSize: headFs.sp);
    final footerStyle = AppUI.money.copyWith(fontSize: cellFs.sp);
    final cellStyle = AppUI.cell.copyWith(fontSize: cellFs.sp);

    // BORDERED GRID, matching what the PDF already prints.
    //
    // Every report's PDF uses pw.TableBorder.all, so the printed register has
    // ruled cells while the screen had only row separators -- the same report
    // read as two different documents. The lines are drawn per cell here
    // rather than with a Table widget because the columns are fixed-width and
    // the header has to stay sticky while the body scrolls.
    const gridLine = BorderSide(color: AppColors.divider);
    Widget rowWidget(List<String> values, List<double> widths, {Color? bg, TextStyle? style}) {
      return Container(
        width: double.infinity,
        // The bottom rule belongs to the row; the right-hand rule belongs to
        // each cell, so the last column closes the grid against the edge.
        //
        // The background goes INSIDE the decoration: Container asserts if it
        // is given both `color` and `decoration`.
        decoration: BoxDecoration(color: bg, border: const Border(bottom: gridLine)),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            for (int i = 0; i < values.length; i++)
              Container(
                width: widths[i],
                decoration: const BoxDecoration(border: Border(right: gridLine)),
                padding: EdgeInsets.symmetric(horizontal: gap.w, vertical: 6.h),
                child: Text(
                  values[i],
                  textAlign: widget.centerCols.contains(i)
                      ? TextAlign.center
                      : widget.numericCols.contains(i)
                          ? TextAlign.right
                          : TextAlign.left,
                  style: style ?? cellStyle,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // The vertical scrollbar always occupies a 16px lane on the right, so
        // the horizontal viewport for the table content is that much narrower.
        const vBarWidth = 16.0;
        final hViewport = constraints.maxWidth - vBarWidth;
        final needsScroll = baseTotal > hViewport;
        final scale = needsScroll ? 1.0 : (hViewport / baseTotal);
        final widths = [for (final c in widget.columnWidths) c.w * scale];
        final width = needsScroll ? baseTotal : hViewport;
        final scrollbarHeight = needsScroll ? 16.0 : 0.0;
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _hController,
                        scrollDirection: Axis.horizontal,
                        physics: needsScroll ? null : const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: width,
                          height: constraints.maxHeight - scrollbarHeight,
                          child: Column(
                            children: [
                              rowWidget(widget.headers, widths, bg: AppColors.tableHeadBg, style: headerStyle),
                              Container(height: 1, color: AppColors.cardBorder),
                              Expanded(
                                // Suppress the framework scrollbar; the pinned
                                // bar on the right drives this list instead.
                                child: ScrollConfiguration(
                                  behavior: ScrollConfiguration.of(context)
                                      .copyWith(scrollbars: false),
                                  // builder, not separated: every row now draws
                                  // its own bottom rule, so a separator here
                                  // would double the line between rows.
                                  child: ListView.builder(
                                    controller: _vController,
                                    itemCount: widget.rows.length,
                                    itemBuilder: (_, i) => rowWidget(widget.rows[i], widths,
                                        bg: (widget.rowTints != null &&
                                                i < widget.rowTints!.length &&
                                                widget.rowTints![i] != null)
                                            ? widget.rowTints![i]
                                            : (i.isEven ? Colors.white : AppColors.surface)),
                                  ),
                                ),
                              ),
                              Container(height: 1, color: AppColors.cardBorder),
                              rowWidget(widget.footer, widths, bg: AppColors.tableHeadBg, style: footerStyle),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Vertical scrollbar pinned to the viewport - top/bottom
                    // spacers carry the header/footer colour so each band
                    // reads as a continuous full-width strip with the bar
                    // only between them.
                    Column(
                      children: [
                        Container(width: 16, color: AppColors.tableHeadBg, child: SizedBox(height: 12.h * 2 + 18)),
                        Expanded(child: AppScrollbarBar(controller: _vController)),
                        Container(width: 16, color: AppColors.tableHeadBg, child: SizedBox(height: 12.h * 2 + 18)),
                      ],
                    ),
                  ],
                ),
              ),
              if (needsScroll)
                Row(
                  children: [
                    Expanded(
                      child: ClassicHScrollbar(
                        controller: _hController,
                        contentWidth: width,
                        viewportWidth: hViewport,
                      ),
                    ),
                    // Corner gap so the horizontal bar lines up with the
                    // content viewport, not the vertical scrollbar lane.
                    const SizedBox(width: vBarWidth),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}


