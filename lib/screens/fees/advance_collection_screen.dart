import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:printing/printing.dart';

import '../../services/paytm_service.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/receipt_pdf.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';
import '../../widgets/paytm_checkout_dialog.dart';
import '../../widgets/receipt_widget.dart';
import '../../services/pending_collection_sweep.dart';
import '../../utils/school_terms.dart';

/// Advance Collection (Fees → Advance Collection).
///
/// Money taken from a STUDENT before any fee is due. An advance is always
/// against a registered student — there is no "Others" party like Misc
/// Collection has, because the money has to be spendable against that
/// student's own demands later.
///
/// THERE ARE TWO KINDS, chosen by the toggle in the header:
///   ADMISSION advance ('A') — collected BY FEE TYPE. The receipt carries a
///     breakdown (TUITION 10,000 / BUS 4,000 / …) and the total is the sum of
///     those lines, which is why the Advance Amount box disappears.
///   STUDENT advance ('S') — a plain amount, no breakdown.
/// Both are held against the student the same way and both are spent the same
/// way. The breakdown records what the money was taken FOR; it does not bind
/// the adjustment, which stays manual on the Fee Collection screen.
///
/// The receipt number comes from the RECEIPT sequence of the fee group the
/// advance is banked under (Setup → Sequence Master → Receipt Sequence)
/// for both kinds — one advance series, not two.
///
/// It is SPENT on the Fee Collection screen: a student with an unused advance
/// is highlighted there and the cashier applies it manually. This screen only
/// takes advances and shows what is left of each.
///
/// Layout and payment-mode handling deliberately mirror Misc Collection, down
/// to the footer triple (amount pill + mode dropdown + save) and the mode
/// details dialog, so the two counter screens behave identically.
///
/// Writes go through save_advance_collection (SECURITY DEFINER, session-gated):
/// advance_collection is a money table, so anon has no direct INSERT on it.
/// One line of an ADMISSION advance: a fee type from the master + an amount.
class _AdvLine {
  int? feeId;
  int? fgId;
  String feeType = '';
  final TextEditingController amount = TextEditingController();
}

class AdvanceCollectionScreen extends StatefulWidget {
  const AdvanceCollectionScreen({super.key});

  @override
  State<AdvanceCollectionScreen> createState() => _AdvanceCollectionScreenState();
}

class _AdvanceCollectionScreenState extends State<AdvanceCollectionScreen> {
  // ---- form state ----------------------------------------------------------
  /// 'A' admission advance (itemised by fee type), 'S' student advance (amount
  /// only). Stored verbatim in advance_collection.advtype.
  String _advType = 'S';
  /// Where THIS advance will be banked, for the strip beside the type toggle.
  /// An advance carries no fee group of its own, so the account it settles
  /// into is decided by its type -- and was invisible until the receipt was
  /// printed. Resolved with the same rule save_advance_collection uses.
  FeeRouting _routing = const FeeRouting();

  /// The group this advance type is CONFIGURED to settle into
  /// (Setup → Utilities → Advance Settlement), independent of what has been
  /// itemised so far — and the pool the fee-type picker is narrowed to.
  ///
  /// Not [_routing].fgId. For an ADMISSION advance _routing moves with the
  /// lines already chosen, so using it to decide what may be chosen NEXT
  /// would let the first pick silently decide the rest. Worse, an advance
  /// announcing "Settles into COLLEGE FEES" would happily accept a hostel fee
  /// type and bank the money somewhere the cashier was never shown.
  FeeRouting _advConfigured = const FeeRouting();

  /// The fee types an ADMISSION advance may be itemised against: those in the
  /// configured group only. Unmapped (no group) offers everything, because
  /// narrowing to nothing would read as "no fee types exist".
  List<Map<String, dynamic>> get _selectableFeeTypes {
    final fg = _advConfigured.fgId;
    if (fg == null) return _feeTypes;
    return _feeTypes
        .where((f) => (f['fg_id'] as num?)?.toInt() == fg)
        .toList();
  }

  /// Institution settings, for the per-fee-group receipt letterhead: a mess
  /// advance is receipted by the hostel, not by the college.
  Map<String, String> _settings = const {};

  ({String name, String address, String banner}) _letterhead() =>
      SupabaseService.letterheadFor(
        fgId: _routing.fgId,
        settings: _settings,
        fallbackName: _insName ?? 'Institution',
        fallbackAddress: _insAddress ?? '-',
      );
  DateTime _date = DateTime.now();
  // Null until the cashier picks a mode (shows "SELECT MODE"), exactly like the
  // Misc Collection / Fee Collection bottom bar; Save stays disabled until then.
  String? _paymode;
  DateTime? _transDate;

  final _amountCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  // Payment-mode details captured in the pay-time dialog (mirrors Misc):
  // transref = UPI txn id / cheque-DD no, bankname free text.
  final _transRefCtrl = TextEditingController();
  final _bankNameCtrl = TextEditingController();

  /// Institution header for the printed receipt, same as Misc Collection.
  String? _insName, _insAddress, _insLogo, _insMobile, _insEmail;

  /// What the SERVER decided about reconciliation for the receipt just saved.
  /// Cash is realised at once ('R'); everything else waits for the bank ('P'),
  /// and the receipt prints "Subject to Realization" until it clears.
  String _savedReconStatus = 'R';

  /// Fee-type lines — ADMISSION advances only.
  final List<_AdvLine> _lines = [_AdvLine()];
  List<Map<String, dynamic>> _feeTypes = [];

  /// Paytm's own transaction id, kept apart from payreference (which holds OUR
  /// order id) exactly as Misc Collection does — without it there is nothing to
  /// match a Paytm settlement report against except a dashboard lookup.
  String? _paytmTxnId;

  /// OUR order id for a Paytm advance (ADV<ins>T<millis>), stored in
  /// advance_collection.payorderid.
  String? _payOrderId;

  // ---- student lookup ------------------------------------------------------
  List<Map<String, dynamic>> _courseList = [];
  List<Map<String, dynamic>> _classList = [];
  List<Map<String, dynamic>> _students = [];

  /// Admission numbers of the students a MESS advance may be taken from:
  /// students.hostel = 'Y', set in Student Details.
  ///
  /// It also used to count anyone carrying a demand in a hostel-side fee
  /// group. That was wrong -- MESS FEE is defined at CLASS level, so every
  /// student of a class that is billed a mess fee got a demand and the
  /// "hostel" list came back as 46 of one class's 67 students. A fee demand
  /// says what a CLASS is billed, not who lives in the hostel.
  ///
  /// Empty means no student is flagged at all -- the flag is unused on this
  /// database -- and the list is then left unfiltered rather than empty: a
  /// counter that can take no money is worse than one offering too many
  /// names.
  final Set<String> _hostellers = {};
  bool _hostelLoaded = false;
  String? _selectedCourse;
  String? _selectedClass;

  /// True when Course/Class were filled in FROM the picked student rather than
  /// chosen by the user. They then act as a read-out, not a filter — otherwise
  /// picking a student would silently narrow the search pool to that student's
  /// own class, and the next reg no typed would return no match.
  bool _courseClassFromStudent = false;
  Map<String, dynamic>? _student;

  // ---- history -------------------------------------------------------------
  List<Map<String, dynamic>> _advances = [];

  /// While a student is picked the list shows only their advances — the cashier
  /// needs to see what this student already holds before taking more.

  // ---- Advances list view --------------------------------------------------
  /// The funnel button reveals these; both default to showing everything.

  int? _yrId;
  String? _yrLabel;

  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    // Recover anything Paytm confirmed after a counter walked away.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _sweepPendingCollections());
    _load();
    _loadStudents();
    _loadHostellers();
    _loadAdvances();
    _syncDate();
    _refreshRouting();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _remarksCtrl.dispose();
    _transRefCtrl.dispose();
    _bankNameCtrl.dispose();
    for (final l in _lines) {
      l.amount.dispose();
    }
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  // ===========================================================================
  // Loading
  // ===========================================================================

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    _loadYear(insId);
    try {
      final results = await Future.wait<dynamic>([
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
        SupabaseService.fromSchema('feetype')
            .select('fee_id, feedesc, fg_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('feedesc', ascending: true),
      ]);
      final info = await SupabaseService.getInstitutionInfo(insId);
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
        _feeTypes = List<Map<String, dynamic>>.from(results[2] as List);
        _insName = info.name;
        _insAddress = info.address;
        _insLogo = info.logo;
        _insMobile = info.mobile;
        _insEmail = info.email;
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

  Future<void> _loadYear(int insId) async {
    try {
      final years = await SupabaseService.getYears(insId);
      if (years.isEmpty) return;
      final y = years.first;
      if (!mounted) return;
      setState(() {
        _yrId = int.tryParse(y['yr_id']?.toString() ?? '');
        _yrLabel = y['yrlabel']?.toString();
      });
    } catch (e) {
      debugPrint('Advance: year lookup failed: $e');
    }
  }

  /// Every active student, loaded once; the search box filters in memory so a
  /// reg no can be typed straight in. fetchAll, not .limit(): PostgREST caps a
  /// response at 1000 rows and silently drops the rest.
  Future<void> _loadStudents() async {
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, stuphoto')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .order('stuadmno', ascending: true));
      final seen = <String>{};
      final deduped = <Map<String, dynamic>>[];
      for (final s in rows.map((e) => Map<String, dynamic>.from(e))) {
        final id = s['stu_id']?.toString();
        if (id == null || id.isEmpty || !seen.add(id)) continue;
        deduped.add(s);
      }
      if (mounted) setState(() => _students = deduped);
    } catch (_) {}
  }

  /// Fill [_hostellers] from the hostel flag. One small query.
  Future<void> _loadHostellers() async {
    try {
      final flagged = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students')
          .select('stuadmno')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .eq('hostel', 'Y'));
      if (!mounted) return;
      setState(() {
        _hostellers
          ..clear()
          ..addAll([
            for (final r in flagged)
              if ((r['stuadmno']?.toString() ?? '').trim().isNotEmpty)
                r['stuadmno'].toString().trim(),
          ]);
        _hostelLoaded = true;
      });
      debugPrint('MESS advance: ${_hostellers.length} hostel students flagged');
    } catch (e) {
      debugPrint('hosteller lookup failed: $e');
      if (mounted) setState(() => _hostelLoaded = true);
    }
  }

  Future<void> _loadAdvances() async {
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('advance_collection')
          .select('adv_id, advno, advdate, advtype, stu_id, stuadmno, stuname, stuclass, '
              'transtotalamount, adjustedamount, balanceamount, paymethod, '
              'payreference, remarks, createdby, recon_status')
          .eq('ins_id', _insId)
          .eq('activestatus', 1));
      if (!mounted) return;
      setState(() {
        _advances = rows.map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) =>
              ((b['adv_id'] as num?) ?? 0).compareTo((a['adv_id'] as num?) ?? 0));
      });
    } catch (_) {}
  }

  /// Today, from the DATABASE server. A workstation with a wrong clock would
  /// otherwise show a date the server never writes.
  Future<DateTime> _serverToday() async {
    try {
      final res = await SupabaseService.client.rpc('get_server_date');
      final d = DateTime.tryParse(res?.toString() ?? '');
      if (d != null) return DateTime(d.year, d.month, d.day);
    } catch (_) {/* function not deployed, or offline */}
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<void> _syncDate() async {
    final d = await _serverToday();
    if (mounted && d != _date) setState(() => _date = d);
  }

  // ===========================================================================
  // Lookup helpers
  // ===========================================================================

  List<String> get _courseNames => _courseList
      .map((e) => e['courname']?.toString().trim() ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> _classesFor(String? course) {
    if (course == null) return const [];
    final c = _courseList.firstWhere(
        (e) => (e['courname']?.toString().trim() ?? '') == course,
        orElse: () => const {});
    final id = c['cour_id'];
    if (id == null) return const [];
    // Keeps the master's own order within each group and sends the TC
    // batches to the foot of the list (utils/class_sort.dart).
    return classGroupPartition(
        _classList
            .where((cl) => cl['cour_id'] == id)
            .map((e) => e['claname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty),
        (s) => s);
  }

  /// A mess advance is money for the hostel mess, so it is taken ONLY from
  /// hostel students -- see [_hostellers]. Any other type offers everyone.
  ///
  /// There is deliberately NO "nobody is flagged, so show everyone" fallback.
  /// That fallback meant a database where the hostel flag had never been set
  /// -- which is every database so far: 3,466 students marked 'N', 26 null,
  /// not one 'Y' -- silently offered mess advances against day scholars, which
  /// is the one thing this filter exists to prevent. An empty list that says
  /// why is better than a full list that is wrong.
  ///
  /// Until the flag is loaded the list is also empty rather than open, so a
  /// fast typist cannot beat the query to it.
  bool _mayTakeMess(Map<String, dynamic> e) {
    if (_advType != 'M') return true;
    if (!_hostelLoaded) return false;
    return _hostellers.contains((e['stuadmno']?.toString() ?? '').trim());
  }

  List<Map<String, dynamic>> _searchPool() => _students.where((e) {
        if (!_mayTakeMess(e)) return false;
        if (_courseClassFromStudent) return true;
        if (_selectedCourse != null &&
            (e['courname']?.toString().trim() ?? '') != _selectedCourse) {
          return false;
        }
        if (_selectedClass != null &&
            (e['stuclass']?.toString().trim() ?? '') != _selectedClass) {
          return false;
        }
        return true;
      }).toList();

  void _pickStudent(Map<String, dynamic> s) {
    setState(() {
      _student = s;
      // Show the student's own course and class in the dropdowns. Matched
      // against the masters first: a student whose course was renamed would
      // otherwise hand the dropdown a value that is not among its items, which
      // throws.
      final cour = s['courname']?.toString().trim() ?? '';
      final cls = s['stuclass']?.toString().trim() ?? '';
      _selectedCourse = _courseNames.contains(cour) ? cour : null;
      _selectedClass = _classesFor(_selectedCourse).contains(cls) ? cls : null;
      _courseClassFromStudent = true;
    });
  }

  /// The string stored in advance_collection.paymethod.
  ///
  /// Deliberately NOT the dropdown value. Fee Collection stores 'cash' / 'upi'
  /// / 'cheque' / 'dd' in payment.paymethod and Misc matches it exactly (see
  /// misc_collection_screen._dbPaymode). An advance that invented a third
  /// vocabulary would read as a different system in Transactions, Bank
  /// Reconciliation and every collection report.
  static String _dbPaymode(String? uiMode) {
    switch (uiMode) {
      case 'QR/UPI':
        return 'upi';
      case 'Paytm':
        return 'Online Transfer';
      case 'Cheque':
        return 'cheque';
      case 'DD':
        return 'dd';
      case 'Cash':
      default:
        return (uiMode ?? 'Cash').toLowerCase();
    }
  }

  /// What is being collected. An admission advance is the SUM OF ITS LINES —
  /// the Advance Amount box is not even shown for it, so the receipt and its
  /// own breakdown can never disagree.
  /// What the receipt will come to -- and therefore what the parent is charged.
  ///
  /// For an ADMISSION advance only NAMED lines count, matching [_validLines],
  /// which is what a save keeps. Summing every line instead meant an amount
  /// typed against no fee type was charged and then dropped: on 2026-09-30 the
  /// identical flaw in Misc Collection took Rs 3,600 for a Rs 150 receipt. The
  /// charge and the receipt have to be computed the same way.
  double get _amount {
    if (_advType == 'A') {
      var sum = 0.0;
      for (final l in _validLines) {
        sum += double.tryParse(l.amount.text.trim()) ?? 0;
      }
      return sum;
    }
    return double.tryParse(_amountCtrl.text.replaceAll(',', '').trim()) ?? 0;
  }

  /// The lines worth saving: a fee type chosen AND an amount above zero.
  List<_AdvLine> get _validLines => _lines
      .where((l) =>
          l.feeType.trim().isNotEmpty && (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
      .toList();

  /// Lines carrying money the cashier typed but never named -- they cannot be
  /// receipted, so they must not be collected either.
  List<_AdvLine> get _unnamedWithAmount => _lines
      .where((l) =>
          l.feeType.trim().isEmpty &&
          (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
      .toList();

  /// What the picked student still has unspent — shown as a strip so the
  /// cashier does not stack a second advance without noticing the first.
  double get _studentOpenBalance {
    final s = _student;
    if (s == null) return 0;
    var sum = 0.0;
    for (final a in _advances) {
      if (a['stu_id'] != s['stu_id']) continue;
      sum += (a['balanceamount'] as num?)?.toDouble() ?? 0;
    }
    return sum;
  }

  // ===========================================================================
  // Save
  // ===========================================================================

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _onSave() async {
    if (_student == null) {
      _snack('Choose a student — an advance is always against a student.',
          AppColors.warning);
      return;
    }
    if (_advType == 'A' && _validLines.isEmpty) {
      _snack('Add at least one fee type with an amount', AppColors.warning);
      return;
    }
    // An amount with no fee type cannot go on the receipt, so it must not be
    // charged. Refusing is the point -- quietly dropping it is what lost money.
    if (_advType == 'A' && _unnamedWithAmount.isNotEmpty) {
      final n = _unnamedWithAmount.length;
      _snack(
          '${n == 1 ? 'A line has' : '$n lines have'} an amount with no fee '
          'type chosen. Pick the fee type, or clear the amount.',
          AppColors.error);
      return;
    }
    if (_amount <= 0) {
      _snack(
          _advType == 'A'
              ? 'The fee type amounts must add up to more than zero'
              : 'Enter an advance amount greater than zero',
          AppColors.warning);
      return;
    }
    if (_paymode == null) {
      _snack('Select a payment mode', AppColors.warning);
      return;
    }
    // ---- the money must have somewhere to land -------------------------
    //
    // The routing strip above the form has warned about this since the screen
    // was written, but a warning is only a warning: the cashier could still
    // take the money and find out afterwards that nothing was banked, or that
    // the server refused the receipt.
    //
    // THE UTILITIES MAPPING IS COMPULSORY. Without it the group was guessed
    // from fee-type names -- which works until a name changes or a new group
    // is added, and then money is quietly banked into the wrong account with
    // nothing on screen to say so. An explicit mapping is the only way the
    // counter can be sure. Settings are re-read here rather than trusted from
    // build time, so a mapping just saved in Utilities takes effect without
    // reopening the screen.
    {
      final insId = context.read<AuthProvider>().insId;
      if (insId != null) {
        final st = await SupabaseService.getInstitutionSettings(insId);
        if (!mounted) return;
        _settings = st;
      }
    }
    final mapped =
        (_settings[SupabaseService.advanceRouteKey(_advType)] ?? '').trim();
    if (mapped.isEmpty) {
      _snack(
          '${switch (_advType) {
            'A' => 'Admission advance',
            'M' => 'Mess advance',
            _ => 'Student advance',
          }} is not mapped to a fee group, so there is no account to bank it '
          'into. Set it in Setup -> Utilities -> Advance Settlement.',
          AppColors.error);
      return;
    }
    if (_routing.fgId == null) {
      _snack(
          'This advance is not linked to any fee group, so there is no account '
          'to bank it into. Map it in Setup -> Utilities -> Advance Settlement '
          'before collecting.',
          AppColors.error);
      return;
    }
    if (!_routing.hasSequence) {
      // _save_advance_collection refuses this outright rather than numbering the
      // receipt out of another group's run -- better to say so before the money
      // changes hands than after.
      //
      // Which sequence is missing depends on the kind of advance, and so does
      // where it is created. Naming the wrong screen is worse than saying
      // nothing: the cashier goes to Sequence Master, finds a sequence already
      // sitting there, and concludes the app is broken.
      _snack(
          '${_routing.fgName} has no receipt sequence, so an advance into it '
          'cannot be numbered -- it draws its number from that group\'s own '
          'series. Create one in Setup -> Sequence Master -> Receipt Sequence.',
          AppColors.error);
      return;
    }
    if (!_routing.hasBank) {
      _snack(
          'No bank account is mapped to ${_routing.fgName}, so this advance '
          'would be banked nowhere. Map one in Setup -> Bank Details, then '
          'Fee Master -> Fee Group.',
          AppColors.error);
      return;
    }
    // Paytm takes the money BEFORE the receipt exists. The other non-cash modes
    // only record a reference the cashier types in, so they keep the dialog.
    // Same split as Misc Collection.
    if (_paymode == 'Paytm') {
      final ref = await _payWithPaytm(_amount);
      if (ref == null) return; // not confirmed -- nothing is saved
      _transRefCtrl.text = ref;
      // _date, not DateTime.now(): this is the transaction date Bank
      // Reconciliation matches against the statement, and _date is the
      // server's. A day out here means the receipt never matches its line.
      _transDate = _date;
      _bankNameCtrl.text = 'PAYTM';
    } else if (_paymode != 'Cash') {
      final ok = await _promptModeDetails();
      if (!ok) return;
    }
    await _save();
  }


  /// Recover any misc/advance Paytm collection a counter never finished.
  ///
  /// Runs on open, like Fee Collection's orphan sweep. The case it exists for:
  /// a cashier opens a UPI collect, cancels the window, and the payer approves
  /// it on their phone a minute later -- Paytm takes the money and nothing was
  /// watching. Asking Paytm on the next open is what turns that back into a
  /// receipt without depending on the webhook being wired up.
  Future<void> _sweepPendingCollections() async {
    try {
      final auth = context.read<AuthProvider>();
      final insId = auth.insId;
      if (insId == null) return;
      final res = await PendingCollectionSweep.run(
          insId: insId, sessionToken: auth.sessionToken);
      if (res.receipted > 0 && mounted) {
        _snack(
          '${res.receipted} payment(s) confirmed by Paytm after the counter '
          'closed have been receipted. Refresh to see them.',
          AppColors.success,
        );
      }
    } catch (e) {
      debugPrint('sweepPendingCollections: $e');
    }
  }

  /// What this advance WOULD be, recorded before Paytm is contacted.
  ///
  /// Paytm takes the money before the receipt exists, so without this nothing
  /// records who the advance was for or what it was itemised against, and a
  /// capture landing after the counter has moved on cannot be receipted by
  /// anyone. The fields that only exist after payment are filled the way the
  /// Paytm branch fills them.
  Map<String, dynamic> _intentHeader(String orderId, double amount) {
    final auth = context.read<AuthProvider>();
    return <String, dynamic>{
      'stu_id': _student!['stu_id'],
      'stuadmno': _student!['stuadmno'],
      'stuname': _student!['stuname'],
      'stuclass': _student!['stuclass'],
      'courname': _student!['courname'] ?? _selectedCourse ?? '',
      'yr_id': _yrId,
      'yrlabel': _yrLabel ?? auth.yearLabel ?? '',
      'advtype': _advType,
      'transtotalamount': amount,
      'paymethod': _dbPaymode('Paytm'),
      'payreference': orderId,
      'payorderid': orderId,
      'paychequeno': null,
      'paychequedate': (_transDate ?? _date).toIso8601String().split('T').first,
      'paybankname': 'PAYTM',
      'tender_amount': amount,
      'remarks': _remarksCtrl.text.trim(),
      'createdby': auth.userName,
    };
  }

  List<Map<String, dynamic>>? _intentLines() => _advType == 'A'
      ? _validLines
          .map((l) => {
                'fee_id': l.feeId,
                'fg_id': l.fgId,
                'feetype': l.feeType.trim(),
                'amount': double.tryParse(l.amount.text.trim()) ?? 0,
              })
          .toList()
      : null;

  /// Collect an advance through Paytm.
  ///
  /// Returns the reference to store once the gateway CONFIRMS the money, null
  /// otherwise. showPaytmCheckout reports 'C' only after a server-side verify
  /// against Paytm's status API, so the advance is written strictly against
  /// money that actually landed — an abandoned or failed checkout leaves no
  /// advance_collection row behind at all.
  Future<String?> _payWithPaytm(double amount) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;

    // Same routing rule as Fee Collection and Misc, and the same one
    // save_advance_collection uses when it banks the receipt: a MESS advance
    // settles into the hostel merchant, an admission advance into the merchant
    // of the fee types it is itemised against, a student advance into the
    // college one. Falls back to the institution's own merchant, and refuses
    // rather than silently reaching the parent.
    final banId = !await SupabaseService.feeGroupSettlementEnabled(insId)
        ? null
        : await SupabaseService.resolveRoutingBanId(
      insId: insId,
      advType: _advType,
      feeTypes: _advType == 'A'
          ? [for (final l in _validLines) l.feeType.trim()]
          : const [],
    );
    final routing =
        await SupabaseService.resolvePaytmRouting(insId: insId, banId: banId);
    if (!routing.ok) {
      if (mounted) _snack(routing.error!, AppColors.error);
      return null;
    }

    // An advance has no payment row to derive an order id from, so it carries
    // its own. The timestamp keeps it unique per counter.
    _paytmTxnId = null;
    _payOrderId = null;
    final orderId = 'ADV${insId}T${DateTime.now().millisecondsSinceEpoch}';
    _payOrderId = orderId;

    // BEFORE the gateway is contacted, never after: the point is to have a
    // record if this machine never reaches the save. A failure here does not
    // stop the collection -- it only means a late capture would be
    // unrecoverable -- so it is logged rather than raised.
    try {
      await SupabaseService.client.rpc('record_pending_collection', params: {
        'p_order_id': orderId,
        'p_ins_id': insId,
        'p_kind': 'A',
        'p_amount': amount,
        'p_header': _intentHeader(orderId, amount),
        'p_lines': _intentLines(),
        'p_created_by': context.read<AuthProvider>().userName ?? '',
        // The sweep must ask THE MERCHANT THIS ORDER WAS SIGNED WITH;
        // the wrong one answers "no such order" and a captured
        // payment would look like a failure.
        'p_ban_id': banId,
      });
    } catch (e) {
      debugPrint('record_pending_collection failed for $orderId: $e');
    }

    try {
      final order = await PaytmService.createOrder(
        // An advance has no payment row. Must not be 0 — see
        // PaytmService.kNoPaymentRow. Nothing downstream reads it: the order id
        // and cust id are both passed explicitly, and the function's
        // payorderid update matches no row for a negative id.
        payId: PaytmService.kNoPaymentRow,
        amount: amount,
        custId: 'STU-${_student?['stuadmno'] ?? insId}',
        orderId: orderId,
        mid: routing.mid,
      );
      if (!mounted) return null;
      _payOrderId = order.orderId;
      // NAME THE MERCHANT THE PAYER IS ABOUT TO PAY.
      //
      // Left unset, buildCheckoutHtml falls back to the literal 'KCET', so a
      // MESS advance routed to the hostel merchant still announced itself as
      // the college in Paytm's own header. Fee Collection already composes
      // this; advance did not.
      //
      // The group is read back from the bank the routing chose, so the name
      // shown and the account billed cannot drift apart. Only when exactly
      // ONE group maps to that bank is it named -- two groups sharing an
      // account make the label a guess, and the merchant tail still proves
      // which account it is.
      String payGroup = '';
      if (banId != null) {
        try {
          final g = await SupabaseService.fromSchema('feegroup')
              .select('fgdesc')
              .eq('ins_id', insId)
              .eq('ban_id', banId)
              .eq('activestatus', 1);
          final gs = List<Map<String, dynamic>>.from(g as List);
          if (gs.length == 1) payGroup = gs.first['fgdesc']?.toString() ?? '';
        } catch (e) {
          debugPrint('advance checkout group name lookup failed: $e');
        }
      }
      if (!mounted) return null;
      final insName = context.read<AuthProvider>().insName ?? 'KCET';
      final payMid = routing.mid ?? '';
      final midTail =
          payMid.length > 6 ? payMid.substring(payMid.length - 6) : payMid;
      final head = SupabaseService.advanceHeadName(_advType);
      final status = await showPaytmCheckout(
        context,
        order: order,
        amount: amount,
        studentName: _student?['stuname']?.toString() ?? '',
        merchantName: '$insName - $head',
        settlingTo: payGroup.isEmpty
            ? (midTail.isEmpty ? '' : 'merchant …$midTail')
            : '$payGroup  ·  merchant …$midTail',
      );
      if (status == 'C') {
        // One extra status call purely to read the TXNID. Deliberately
        // best-effort: the money is already confirmed, so a hiccup here must
        // not fail the receipt — it just leaves paytm_txnid null.
        try {
          final st = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
          _paytmTxnId = st.paymentId;
        } catch (e) {
          debugPrint('Paytm txnid lookup failed: $e');
        }
        // The TXN id, not the order id: payreference is what Bank
        // Reconciliation matches against the statement, while the order id
        // (ADV<ins>T<millis>) is ours alone and appears on no bank line. Falls
        // back to the order id only if the status lookup above failed, so the
        // receipt still carries something traceable.
        return _paytmTxnId ?? order.orderId;
      }
      if (mounted) {
        // Paytm's own RESPMSG when the checkout reported one. Without it a
        // decline, a closed window and an unenabled instrument all read as the
        // same sentence, and the cashier has nothing to act on.
        final why = PaytmService.lastGatewayMessage;
        _snack(
            '${status == 'F' ? 'Payment failed or was cancelled' : 'Payment not confirmed'}'
            '${why.isEmpty ? '' : ' — $why'} — nothing was saved.',
            AppColors.warning);
      }
      return null;
    } catch (e) {
      // The gateway's own words, not friendlyError's generic line: a Paytm or
      // edge-function refusal names the actual reason, and hiding it turns a
      // two-minute fix into a guessing game.
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        _snack('Paytm error. $msg', AppColors.error);
      }
      return null;
    }
  }

  Future<bool> _promptModeDetails() async {
    // Default the instrument date to the collection date: a UPI payment is
    // recorded on the day it is collected, and a cheque is nearly always dated
    // today too. Still editable, and Cheque/DD require it explicitly.
    _transDate = _date;
    final isUpi = _paymode == 'QR/UPI';
    final doc = _paymode == 'DD' ? 'DD' : 'Cheque';
    String? refErr, dateErr, bankErr;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460.w),
            child: Padding(
              padding: EdgeInsets.all(22.w),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const AppIcon('wallet-money', size: 20, color: AppColors.accent),
                      SizedBox(width: 8.w),
                      Text(isUpi ? 'UPI Payment' : '$doc Payment',
                          style: AppUI.cardTitle),
                      const Spacer(),
                      Text('₹${_amount.toStringAsFixed(2)}',
                          style: TextStyle(
                              fontSize: 16.sp,
                              fontWeight: FontWeight.w800,
                              color: AppColors.accent)),
                    ]),
                    SizedBox(height: 18.h),
                    if (isUpi)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          flex: 3,
                          child: _labeled(
                              'UPI Transaction ID *',
                              TextField(
                                controller: _transRefCtrl,
                                style: _txt,
                                autofocus: true,
                                onChanged: (_) {
                                  if (refErr != null) setD(() => refErr = null);
                                },
                                decoration: _dec('e.g. 412345678901')
                                    .copyWith(errorText: refErr),
                              )),
                        ),
                        SizedBox(width: 12.w),
                        Expanded(
                          flex: 2,
                          child: _labeled('Transaction Date',
                              _dateBox(_transDate, (dt) => setD(() => _transDate = dt))),
                        ),
                      ])
                    else ...[
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                            child: _labeled(
                                '$doc No *',
                                TextField(
                                  controller: _transRefCtrl,
                                  style: _txt,
                                  autofocus: true,
                                  onChanged: (_) {
                                    if (refErr != null) setD(() => refErr = null);
                                  },
                                  decoration: _dec('Enter $doc number')
                                      .copyWith(errorText: refErr),
                                ))),
                        SizedBox(width: 12.w),
                        Expanded(
                            child: _labeled(
                                '$doc Date *',
                                _dateBox(_transDate, (dt) => setD(() {
                                      _transDate = dt;
                                      dateErr = null;
                                    })))),
                      ]),
                      if (dateErr != null) ...[
                        SizedBox(height: 5.h),
                        Text(dateErr!,
                            style: TextStyle(fontSize: 11.sp, color: AppColors.error)),
                      ],
                      SizedBox(height: 12.h),
                      _labeled(
                          'Bank Name *',
                          TextField(
                            controller: _bankNameCtrl,
                            style: _txt,
                            onChanged: (_) {
                              if (bankErr != null) setD(() => bankErr = null);
                            },
                            decoration:
                                _dec('Enter bank name').copyWith(errorText: bankErr),
                          )),
                    ],
                    SizedBox(height: 22.h),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel',
                            style: TextStyle(color: AppColors.textSecondary)),
                      ),
                      SizedBox(width: 10.w),
                      ElevatedButton(
                        onPressed: () {
                          if (_transRefCtrl.text.trim().isEmpty) {
                            setD(() => refErr = isUpi
                                ? 'Enter the UPI Transaction ID'
                                : '$doc number is required');
                            return;
                          }
                          if (!isUpi) {
                            final noDate = _transDate == null;
                            final noBank = _bankNameCtrl.text.trim().isEmpty;
                            if (noDate || noBank) {
                              setD(() {
                                dateErr = noDate ? '$doc date is required' : null;
                                bankErr = noBank ? 'Bank name is required' : null;
                              });
                              return;
                            }
                          }
                          Navigator.pop(ctx, true);
                        },
                        child: const Text('Save'),
                      ),
                    ]),
                  ]),
            ),
          ),
        ),
      ),
    );
    return result == true;
  }

  Future<void> _save() async {
    final auth = context.read<AuthProvider>();
    final isCash = _paymode == 'Cash';
    setState(() => _saving = true);
    try {
      // A Paytm advance must be CLAIMED before it is saved. The webhook can be
      // raising this same receipt right now from the intent row -- it does so
      // whenever a capture lands late -- and two writers would produce two
      // receipts for one payment. Exactly one caller wins the claim.
      if (_payOrderId != null && _paymode == 'Paytm') {
        final claim = await SupabaseService.client
            .rpc('claim_pending_collection', params: {
          'p_order_id': _payOrderId,
          'p_by': 'COUNTER',
        });
        final won = claim is List && claim.isNotEmpty;
        if (!won) {
          setState(() => _saving = false);
          _snack(
            'This payment has already been receipted automatically. '
            'Open Advance Collection to print it.',
            AppColors.warning,
          );
          return;
        }
      }

      final res =
          await SupabaseService.client.rpc('save_advance_collection', params: {
        'p_token': auth.sessionToken,
        'p_header': {
          'stu_id': _student!['stu_id'],
          'stuadmno': _student!['stuadmno'],
          'stuname': _student!['stuname'],
          'stuclass': _student!['stuclass'],
          'courname': _student!['courname'] ?? _selectedCourse ?? '',
          // Both are needed for the receipt to appear in year-scoped reports.
          'yr_id': _yrId,
          'yrlabel': _yrLabel ?? auth.yearLabel ?? '',
          // advdate is deliberately NOT sent: save_advance_collection stamps
          // now() on the database server, so the collection date can never come
          // from a workstation with a wrong clock.
          'advtype': _advType,
          'transtotalamount': _amount,
          'paymethod': _dbPaymode(_paymode),
          'payreference': isCash ? null : _transRefCtrl.text.trim(),
          // Paytm only: OUR order id and Paytm's own txn id, kept apart.
          'payorderid': _payOrderId,
          'paytm_txnid': _paytmTxnId,
          // Cheque/DD keep the instrument fields; QR/UPI has no instrument, so
          // only the reference and the transaction date are recorded.
          'paychequeno': (_paymode == 'Cheque' || _paymode == 'DD')
              ? _transRefCtrl.text.trim()
              : null,
          // The date Bank Reconciliation matches against the statement, for
          // every non-cash mode (Misc stores the same thing in transdate).
          'paychequedate':
              isCash ? null : (_transDate ?? _date).toIso8601String().split('T').first,
          'paybankname': isCash ? null : _bankNameCtrl.text.trim(),
          'tender_amount': _amount,
          'remarks': _remarksCtrl.text.trim(),
          'createdby': auth.userName,
        },
        // Fee-type breakdown: admission advances only. The server recomputes
        // the total from these, so it can never drift from the receipt.
        'p_lines': _advType == 'A'
            ? _validLines
                .map((l) => {
                      'fee_id': l.feeId,
                      'fg_id': l.fgId,
                      'feetype': l.feeType.trim(),
                      'amount': double.tryParse(l.amount.text.trim()) ?? 0,
                    })
                .toList()
            : null,
      });
      final map = res is Map ? res : const <String, dynamic>{};
      final advno = map['advno']?.toString() ?? '';

      // The intent is done. Settling it stops the health check reporting this
      // advance as unfinished, and stops the webhook touching it again.
      if (_payOrderId != null && _paymode == 'Paytm') {
        try {
          await SupabaseService.client.rpc('settle_pending_collection', params: {
            'p_order_id': _payOrderId,
            'p_status': 'C',
            'p_receipt_no': advno,
          });
        } catch (e) {
          debugPrint('settle_pending_collection failed: $e');
        }
      }
      final recon = map['recon_status']?.toString() ?? (isCash ? 'R' : 'P');
      if (!mounted) return;
      _savedReconStatus = recon;
      // The amount and the breakdown are read off the form, which _newRecord
      // clears -- so the receipt is built from what is captured HERE and the
      // form is only reset once the cashier is done with the dialog.
      final total = _amount;
      final lines = <ReceiptFeeItem>[
        if (_advType == 'A')
          for (final l in _validLines)
            ReceiptFeeItem(
                type: l.feeType.trim(),
                amount: double.tryParse(l.amount.text.trim()) ?? 0)
        else
          // Named, not bare 'ADVANCE': the line has to say WHICH kind of
          // advance it is, because the two are not interchangeable -- a
          // student advance pays demands, an admission advance reduces
          // the fee itself.
          //
          // NOT the fee group. That is where the money BANKS, not what was
          // collected, and preferring it printed "COLLEGE FEES" on a student
          // advance receipt -- telling the family they had paid a fee they
          // had not. Same name the Fee Types grid shows, so the screen the
          // cashier read and the paper the family keeps cannot disagree.
          ReceiptFeeItem(type: _fixedHeadName, amount: total),
      ];
      _showSuccessDialog(advno, total, lines, recon);
      await _loadAdvances();
      _syncDate();
    } catch (e) {
      // The RAW error in the run log: friendlyError flattens a server
      // exception to "something went wrong", which is unactionable when the
      // cause is a named one (no receipt sequence for a fee group, say).
      debugPrint('ADVANCE SAVE FAILED (raw): $e');
      if (!mounted) return;
      _snack('Could not collect the advance. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Post-save confirmation -- the same shape Fee Collection and Misc
  /// Collection use: a tick, the receipt number, amount and mode, View Receipt
  /// to open the printable receipt, and Done to clear the form for the next
  /// entry. The form is NOT cleared until this closes, because the receipt is
  /// built from what is still on it.
  void _showSuccessDialog(
      String advno, double total, List<ReceiptFeeItem> lines, String recon) {
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
            Text('Advance Collected', style: AppUI.cardTitle),
            SizedBox(height: 8.h),
            Text('Receipt No: $advno',
                style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
            Text('Amount: ₹${total.toStringAsFixed(2)}',
                style: TextStyle(
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent)),
            Text('Mode: ${_paymode ?? 'Cash'}',
                style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
            if (recon != 'R') ...[
              SizedBox(height: 6.h),
              Text('Waiting for bank reconciliation',
                  style: TextStyle(
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w600,
                      color: AppColors.warning)),
            ],
            SizedBox(height: 16.h),
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _showReceipt(advno, total, lines);
                if (mounted) _newRecord();
              },
              icon: AppIcon('document-download', size: 16),
              label: const Text('View Receipt'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _newRecord();
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// Build the advance receipt and open the viewer.
  ///
  /// An ADMISSION advance lists the fee types it was taken for; a STUDENT
  /// advance is a plain amount and gets a single ADVANCE line -- there is no
  /// breakdown to invent.
  Future<void> _showReceipt(
      String advno, double total, List<ReceiptFeeItem> lines) async {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final d = _date;
    final dateStr = '${months[d.month - 1]} ${d.day}, ${d.year}';
    final stu = _student ?? const <String, dynamic>{};
    final data = ReceiptData(
      receiptNo: advno,
      date: dateStr,
      studentName: stu['stuname']?.toString() ?? '-',
      mobileNo: stu['stumobile']?.toString() ?? '-',
      address: '-',
      admissionNo: stu['stuadmno']?.toString() ?? '-',
      className: stu['stuclass']?.toString() ?? '-',
      courseName: stu['courname']?.toString() ?? _selectedCourse ?? '-',
      schoolName: _letterhead().name,
      schoolAddress: _letterhead().address,
      headerBanner: _letterhead().banner,
      schoolLogoUrl: _insLogo,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: [
        ReceiptTermDetail(
            // The advance KIND, for all three types. It used to be the fee
            // group, which is where the money banks -- not what was collected.
            term: _fixedHeadName,
            fees: lines),
      ],
      paymentMethod: _dbPaymode(_paymode),
      paymentDate: dateStr,
      status: 'paid',
      paymentReference: _transRefCtrl.text.trim(),
      reconStatus: _savedReconStatus,
      total: total,
    );
    if (mounted) _showReceiptWindow(data);
  }

  void _showReceiptWindow(ReceiptData data) {
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
                        try {
                          final pdf = await buildReceiptPdf(data);
                          final bytes = await pdf.save();
                          final res = await FilePicker.platform.saveFile(
                            dialogTitle: 'Save Receipt PDF',
                            fileName:
                                'Receipt_${data.receiptNo.replaceAll('/', '_')}.pdf',
                            type: FileType.custom,
                            allowedExtensions: ['pdf'],
                          );
                          if (res != null) {
                            await File(res).writeAsBytes(bytes);
                            if (mounted) _snack('Receipt saved', AppColors.success);
                          }
                        } catch (e) {
                          if (mounted) _snack(friendlyError(e), AppColors.error);
                        }
                      },
                      icon: AppIcon('document-download', size: 18),
                      label: const Text('Download'),
                    ),
                    SizedBox(width: 8.w),
                    ElevatedButton.icon(
                      onPressed: () async {
                        try {
                          await Printing.layoutPdf(
                            format: a5PageFormat,
                            onLayout: (fmt) async =>
                                (await buildReceiptPdf(data, pageFormat: fmt)).save(),
                            name: 'Receipt_${data.receiptNo.replaceAll('/', '_')}',
                          );
                        } catch (e) {
                          if (mounted) _snack(friendlyError(e), AppColors.error);
                        }
                      },
                      icon: AppIcon('printer', size: 18, color: Colors.white),
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
                      decoration: BoxDecoration(boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 10,
                            offset: const Offset(0, 2)),
                      ]),
                      child: ReceiptWidget(data: data),
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

  void _newRecord() {
    setState(() {
      _student = null;
      _selectedCourse = null;
      _selectedClass = null;
      _courseClassFromStudent = false;
      _paymode = null;
      _transDate = null;
      _amountCtrl.clear();
      _remarksCtrl.clear();
      _transRefCtrl.clear();
      _bankNameCtrl.clear();
      _paytmTxnId = null;
      _payOrderId = null;
      for (final l in _lines) {
        l.amount.dispose();
      }
      _lines
        ..clear()
        ..add(_AdvLine());
    });
  }

  // ===========================================================================
  // Shared chrome (same shapes as Misc Collection)
  // ===========================================================================

  InputDecoration _dec(String hint, {bool enabled = true}) => enabled
      ? AppUI.field(context, hint)
      : AppUI.field(context, hint).copyWith(fillColor: AppColors.surface);

  TextStyle get _txt => AppUI.fieldText(context);

  Widget _labeled(String label, Widget child, {String? icon}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              AppIcon(icon, size: 12, color: AppColors.accent),
              SizedBox(width: 5.w),
            ],
            Text(label, style: AppUI.label),
          ]),
          SizedBox(height: 6.h),
          child,
        ],
      );

  /// Each section of the form carries its own colour, so the eye can find
  /// "the green one" (what is being collected) without reading every heading:
  /// Student blue, Collection Details green, Fee Types violet, Advances amber.
  Widget _miniHeader(String icon, String title, Color tint, {Widget? trailing}) =>
      Row(children: [
        Container(
          width: 24.w,
          height: 24.w,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(7.r)),
          child: AppIcon(icon, size: 13, color: tint),
        ),
        SizedBox(width: 8.w),
        Text(title, style: AppUI.label),
        if (trailing != null) ...[const Spacer(), trailing],
      ]);

  Widget _sectionCard(
          {required String icon,
          required String title,
          required Color tint,
          required Widget child,
          Widget? trailing}) =>
      Container(
        width: double.infinity,
        // Tight: Student, Collection Details and the advance list stack on a
        // laptop, and the list -- the part that is read -- lost the most.
        padding: EdgeInsets.fromLTRB(12.w, 10.h, 12.w, 12.h),
        // The section's colour lives on its header tile; the panel itself is
        // the standard card.
        decoration: AppUI.card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _miniHeader(icon, title, tint, trailing: trailing),
          SizedBox(height: 9.h),
          child,
        ]),
      );

  Widget _dateBox(DateTime? value, ValueChanged<DateTime> onPicked,
          {String hint = 'dd/mm/yyyy'}) =>
      InkWell(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: value ?? DateTime.now(),
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (picked != null) onPicked(picked);
        },
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: Container(
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(horizontal: AppUI.compact(context) ? 12 : 14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.border)),
          child: Text(
            value == null ? hint : _dmy(value),
            style: value == null
                ? AppUI.fieldText(context).copyWith(
                    color: AppColors.textLight, fontWeight: FontWeight.w500)
                : AppUI.fieldText(context),
          ),
        ),
      );

  static String _dmy(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _money(Object? v) {
    final d = (v as num?)?.toDouble() ?? 0;
    return d == d.truncateToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Could not load. $_loadError',
              style: TextStyle(fontSize: 13.sp, color: AppColors.error)),
          SizedBox(height: 12.h),
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    return Padding(
      padding: EdgeInsets.all(10.w),
      // The card FILLS the window, and the footer sits on its bottom edge.
      //
      // It briefly hugged its content instead, to kill the empty panel under a
      // two-card form -- but that just moved the gap outside the card, where it
      // showed as grey. Filling the sheet and keeping the action bar pinned to
      // the bottom is the lesser of the two: the form is simply short, and
      // Collect Advance stays where the hand expects it.
      child: Container(
        decoration: AppUI.card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1, color: AppColors.divider),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 10.h),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionCard(
                        icon: 'people',
                        title: 'Student',
                        tint: AppColors.accent,
                        child: _partyRow()),
                    if (_student != null && _studentOpenBalance > 0) ...[
                      SizedBox(height: 8.h),
                      _openBalanceStrip(),
                    ],
                    SizedBox(height: 9.h),
                    _detailForm(),
                    SizedBox(height: 9.h),
                    // Every type gets the grid. An admission advance is
                    // genuinely itemised; student and mess are a single head,
                    // so they get one fixed row naming it. Same shape on all
                    // three tabs, and the amount is typed in the same place.
                    _sectionCard(
                      icon: 'tag',
                      title: 'Fee Types',
                      tint: AppColors.demand,
                      // Say WHY the picker is short. Without this a narrowed
                      // list reads as missing fee types rather than as the
                      // Advance Settlement mapping doing its job.
                      trailing: _advType == 'A' &&
                              _advConfigured.fgName.trim().isNotEmpty
                          ? Tooltip(
                              message:
                                  'An advance banks into one account, so only '
                                  '${_advConfigured.fgName} fee types are '
                                  'offered. Change it in Setup → Utilities → '
                                  'Advance Settlement.',
                              child: Text(
                                '${_advConfigured.fgName} only',
                                style: TextStyle(
                                    fontSize: 10.5.sp,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textLight),
                              ),
                            )
                          : null,
                      child: _advType == 'A' ? _feeGrid() : _fixedFeeGrid(),
                    ),
                    SizedBox(height: 9.h),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: AppColors.divider),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 12.h),
        child: Row(children: [
          AppUI.iconTile('empty-wallet-add'),
          SizedBox(width: 12.w),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Advance Collection', style: AppUI.cardTitle),
                Text('Manage advance payments collected from students',
                    style: AppUI.muted),
              ]),
          SizedBox(width: 18.w),
          _segToggle(),
          SizedBox(width: 12.w),
          Expanded(child: _routingStrip()),
          Builder(builder: (context) {
            final compact = MediaQuery.of(context).size.width <= 1366;
            return Row(mainAxisSize: MainAxisSize.min, children: [
              _toolButton(
                icon: 'refresh',
                label: 'Refresh',
                compact: compact,
                onTap: _saving
                    ? null
                    : () {
                        _loadAdvances();
                        _loadStudents();
                      },
              ),
              SizedBox(width: 8.w),
              _toolButton(
                icon: 'trash',
                label: 'Clear',
                compact: compact,
                onTap: _saving ? null : _newRecord,
              ),
            ]);
          }),
        ]),
      );

  Widget _toolButton(
          {required String icon,
          required String label,
          required bool compact,
          VoidCallback? onTap}) =>
      OutlinedButton.icon(
        onPressed: onTap,
        icon: AppIcon(icon, size: compact ? 15 : 18, color: AppColors.accent),
        label: Text(label),
      );


  /// ADMISSION vs STUDENT advance. Switching clears the side that no longer
  /// applies, so a half-filled fee grid can never be saved as a student
  /// advance (or a stale amount as an admission one).
  /// Re-resolve where the advance now being collected will be banked.
  ///
  /// Cheap (three small selects) and only on a type change or a fee-type pick,
  /// never per keystroke.
  Future<void> _refreshRouting() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    // Asked every time, not once per screen: getInstitutionSettings
    // now serves a shared 60-second cache, so this costs nothing and a
    // letterhead changed on another machine reaches this counter without
    // restarting the app.
    {
      final st = await SupabaseService.getInstitutionSettings(insId);
      if (mounted) setState(() => _settings = st);
    }
    final r = await SupabaseService.resolveRoutingTarget(
      insId: insId,
      advType: _advType,
      feeTypes: _advType == 'A'
          ? [for (final l in _validLines) l.feeType.trim()]
          : const [],
    );
    // The CONFIGURED target, resolved with NO fee types so the lines already
    // picked cannot sway it. Identical to `r` until an admission advance has
    // its first line, so the extra call is skipped until then.
    final cfg = (_advType == 'A' && _validLines.isNotEmpty)
        ? await SupabaseService.resolveRoutingTarget(
            insId: insId, advType: _advType, feeTypes: const [])
        : r;
    if (!mounted) return;
    setState(() {
      _routing = r;
      _advConfigured = cfg;
    });
  }

  /// "Settles into HOSTEL FEES · IOB · Paytm Krishn3355..." -- the account the
  /// cashier is about to put money in, named before they do it.
  Widget _routingStrip() {
    final r = _routing;
    if (r.fgId == null) {
      // "Amount only" read as a harmless note about the form. It is not: with
      // no fee group there is no account to bank into and no series to number
      // from, and the collection is refused at Collect. Say so here, in the
      // same amber the other blocking states use, rather than at the end.
      return Tooltip(
        message: 'This advance is not mapped to any fee group, so there is no '
            'account to bank it into and no receipt series to number it from. '
            'Map it in Setup → Utilities → Advance Settlement.',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.warning_amber_rounded,
              size: 13.sp, color: AppColors.warning),
          SizedBox(width: 5.w),
          Flexible(
            child: Text('NO FEE GROUP MAPPED — set it in Utilities',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning)),
          ),
        ]),
      );
    }
    // A missing receipt sequence stops the collection outright -- the server
    // refuses rather than numbering it out of another group's run -- so it is
    // flagged here, before the cashier takes the money.
    //
    // An UNMAPPED group is not fatal, because the server guesses by name the
    // same way the counter does -- but it is still wrong to present a guess as
    // a setting. It is called out so the office can make it deliberate.
    final bad = !r.hasBank || !r.hasSequence || !r.mapped;
    final colour = bad ? AppColors.warning : AppColors.textLight;
    final parts = <String>[
      // "NOT MAPPED" first, because it qualifies everything after it: the group
      // named next is where this WOULD go, not where anybody said it should.
      if (!r.mapped) 'NOT MAPPED',
      r.fgName.toUpperCase(),
      if (!r.hasSequence) 'NO RECEIPT SEQUENCE',
      if (r.hasBank) r.bankName else 'NO BANK ACCOUNT',
      if (r.hasBank && r.hasSequence)
        r.hasMerchant ? 'Paytm ${r.paytmMid}' : 'Paytm: institution merchant',
    ];
    return Tooltip(
      message: !r.mapped
          ? '${switch (_advType) {
              'A' => 'Admission',
              'M' => 'Mess',
              _ => 'Student',
            }} advance is not mapped to a fee group, so nobody has chosen where '
              'it banks. It would fall back to ${r.fgName} — matched on the '
              'name, not configured. Set it in Setup → Utilities → Advance '
              'Settlement.'
          : !r.hasSequence
          ? 'No receipt sequence for ${r.fgName}. An advance draws its number '
              'from its fee group\'s own series, so it is refused until one '
              'exists. Create it in Setup → Sequence Master → Receipt Sequence.'
          : bad
          ? 'No bank account is mapped to ${r.fgName}. Map one in Setup → Bank '
              'Details, then Fee Master → Fee Group; until then this advance is '
              'banked nowhere.'
          : r.hasMerchant
              ? 'Cash and cheque are banked into ${r.bankName}. An online '
                  'payment settles to merchant ${r.paytmMid}, which is '
                  'registered against that account.'
              : '${r.bankName} names no Paytm merchant, so an online payment '
                  'settles to the institution merchant — the college account. '
                  'Set the MID in Setup → Bank Details.',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(bad ? Icons.warning_amber_rounded : Icons.account_balance,
            size: 13.sp, color: colour),
        SizedBox(width: 5.w),
        Flexible(
          child: Text('Settles into ${parts.join(' · ')}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.sp,
                  fontWeight: bad ? FontWeight.w700 : FontWeight.w500,
                  color: colour)),
        ),
      ]),
    );
  }

  Widget _segToggle() {
    Widget seg(String label, String val) {
      final sel = _advType == val;
      return InkWell(
        onTap: _saving
            ? null
            : () => setState(() {
                  if (_advType == val) return;
                  _advType = val;
                  _refreshRouting();
                  // A student picked under STUDENT may not be a hosteller.
                  if (_student != null && !_mayTakeMess(_student!)) {
                    _student = null;
                  }
                  if (val == 'A') {
                    _amountCtrl.clear();
                  } else {
                    for (final l in _lines) {
                      l.amount.dispose();
                    }
                    _lines
                      ..clear()
                      ..add(_AdvLine());
                  }
                }),
        borderRadius: BorderRadius.circular(8.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 9.h),
          decoration: BoxDecoration(
            color: sel ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: sel ? Colors.white : AppColors.textSecondary)),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(3.w),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      // MESS is a plain amount like STUDENT; the two differ only in which
      // account the money settles into -- mess goes to the hostel fee group's
      // bank account, admission and student to the college one. The routing is
      // decided server-side in save_advance_collection, not here.
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('ADMISSION', 'A'),
        seg('STUDENT', 'S'),
        seg('MESS', 'M'),
      ]),
    );
  }


  Widget _partyRow() => Wrap(spacing: 12.w, runSpacing: 10.h, children: [
        SizedBox(
            width: 200.w,
            child: _labeled(
                schoolTerm('Course'),
                DropdownButtonFormField<String>(
                  // FormField.initialValue is read once, in initState — a
                  // rebuild with a new value is ignored. Keying on the value
                  // forces a fresh field so a course set from the picked
                  // student actually shows.
                  key: ValueKey('adv-course-${_selectedCourse ?? ''}'),
                  initialValue:
                      _courseNames.contains(_selectedCourse) ? _selectedCourse : null,
                  isExpanded: true,
                  style: _txt,
                  decoration: _dec(schoolTerm('Select course')),
                  items: _courseNames
                      .map((s) => DropdownMenuItem(
                          value: s, child: Text(s, overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _selectedCourse = v;
                    _selectedClass = null;
                    _student = null;
                    _courseClassFromStudent = false;
                  }),
                ))),
        SizedBox(
            width: 180.w,
            child: _labeled(
                schoolTerm('Class'),
                DropdownButtonFormField<String>(
                  key: ValueKey('adv-class-${_selectedCourse ?? ''}-${_selectedClass ?? ''}'),
                  initialValue: _classesFor(_selectedCourse).contains(_selectedClass)
                      ? _selectedClass
                      : null,
                  isExpanded: true,
                  style: _txt,
                  decoration: _dec(schoolTerm('Select class')),
                  items: _classesFor(_selectedCourse)
                      .map((s) => DropdownMenuItem(
                          value: s, child: Text(s, overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _selectedClass = v;
                    _student = null;
                    _courseClassFromStudent = false;
                  }),
                ))),
        SizedBox(width: 340.w, child: _labeled('Student *', _studentSearch())),
        if (_student != null) _selectedStudentStrip(),
      ]);

  /// The picked student's photo, name and reg no, beside the search box, so
  /// the counter can see who they are collecting from.
  Widget _selectedStudentStrip() {
    final s = _student!;
    final name = s['stuname']?.toString() ?? '';
    final cls = s['stuclass']?.toString().trim() ?? '';
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 360.w),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        StudentAvatar(photoUrl: s['stuphoto']?.toString(), name: name, size: 52),
        SizedBox(width: 10.w),
        Flexible(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppUI.label, overflow: TextOverflow.ellipsis),
                Text(
                    '${schoolTerm('Reg No')}: ${s['stuadmno'] ?? ''}'
                    "${cls.isEmpty ? '' : '  •  $cls'}",
                    style: AppUI.muted,
                    overflow: TextOverflow.ellipsis),
              ]),
        ),
      ]),
    );
  }

  Widget _studentSearch() => Autocomplete<Map<String, dynamic>>(
        // _advType is part of the key because the MESS tab offers a DIFFERENT
        // set of students. Autocomplete recomputes its options only when the
        // text changes, so without this, switching to MESS left the list it
        // had built for STUDENT on screen -- every student, filter or not.
        key: ValueKey(
            'advstu-$_advType-${_selectedCourse ?? ''}-${_selectedClass ?? ''}-${_student?['stuadmno'] ?? ''}'),
        initialValue: TextEditingValue(
            text: _student == null
                ? ''
                : '${_student!['stuadmno']}  •  ${_student!['stuname']}'),
        optionsBuilder: (tev) {
          final q = tev.text.toLowerCase().trim();
          final base = _searchPool();
          if (q.isEmpty) return base.take(50);
          return base
              .where((e) => '${e['stuadmno']} ${e['stuname']}'.toLowerCase().contains(q))
              .take(50);
        },
        displayStringForOption: (e) => '${e['stuadmno']}  •  ${e['stuname']}',
        onSelected: _pickStudent,
        fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
          controller: controller,
          focusNode: focusNode,
          style: _txt,
          decoration: _dec(_students.isEmpty
                  ? 'Loading students…'
                  : (_advType == 'M'
                      ? (!_hostelLoaded
                          ? 'Checking who lives in the hostel…'
                          : _hostellers.isEmpty
                              // Says what to DO. "No hostellers" on its own
                              // reads as a broken screen; the flag simply has
                              // never been set on this database.
                              ? 'No hostel students. Set hostel = Y in Student Details first'
                              : 'Hostel students only (${_hostellers.length}) — type reg no or name')
                      : 'Type reg no or name'))
              .copyWith(
                  prefixIcon:
                      Icon(Icons.search, size: 18.sp, color: AppColors.textLight),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 40, minHeight: 0)),
          onSubmitted: (_) => onSubmit(),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8.r),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 280.h, maxWidth: 420.w),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: options
                    .map((e) => InkWell(
                          onTap: () => onSelected(e),
                          child: Padding(
                            padding:
                                EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                            child: Text(
                                '${e['stuadmno']}  •  ${e['stuname']}'
                                '${(e['stuclass']?.toString().trim().isNotEmpty ?? false) ? '   (${e['stuclass']})' : ''}',
                                style: TextStyle(fontSize: 13.sp)),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        ),
      );

  /// This student already holds unspent advance money. Say so before a second
  /// one is taken by mistake.
  Widget _openBalanceStrip() => Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.45)),
        ),
        child: Row(children: [
          const AppIcon('empty-wallet-add', size: 17, color: AppColors.success),
          SizedBox(width: 9.w),
          Expanded(
            child: Text(
              '${_student!['stuname']} already holds ₹${_money(_studentOpenBalance)} '
              'in unused advance. Spend it on Fee Collection before taking more.',
              style: TextStyle(
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
          ),
        ]),
      );

  Widget _detailForm() => _sectionCard(
        icon: 'calendar-1',
        title: 'Collection Details',
        tint: AppColors.success,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: _labeled(
                    'Date',
                    // Read-only on purpose: the collection date is stamped by
                    // the DATABASE server inside save_advance_collection, so a
                    // workstation with a wrong clock cannot misdate a receipt.
                    Container(
                      width: double.infinity,
                      constraints:
                          BoxConstraints(minHeight: AppUI.controlHeight(context)),
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.symmetric(
                          horizontal: AppUI.compact(context) ? 12 : 14),
                      decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                          border: Border.all(color: AppColors.cardBorder)),
                      child: Row(children: [
                        const AppIcon('calendar-1', size: 14, color: AppColors.success),
                        SizedBox(width: 8.w),
                        Expanded(child: Text(_dmy(_date), style: _txt)),
                        Icon(Icons.lock_outline, size: 13.sp, color: AppColors.textLight),
                      ]),
                    ),
                    icon: 'calendar-1')),
            SizedBox(width: 12.w),
            Expanded(
                child: _labeled(
                    'Collected By',
                    TextField(
                        controller: TextEditingController(
                            text: context.read<AuthProvider>().userName ?? ''),
                        enabled: false,
                        style: _txt,
                        decoration: _dec('', enabled: false)),
                    icon: 'people')),
            SizedBox(width: 12.w),
            // The amount is typed in the Fee Types grid on every tab now, so
            // there is nothing to type here. Two boxes for one figure is how a
            // receipt and its own breakdown end up disagreeing.
            Expanded(
                flex: 2,
                child: _labeled(
                    'Remarks',
                    TextField(
                        controller: _remarksCtrl,
                        style: _txt,
                        decoration: _dec('Why the advance was taken')),
                    icon: 'receipt-edit')),
          ]),
      );

  /// The one fixed head a STUDENT or MESS advance is taken against.
  ///
  /// These are not itemised -- the money is held against the student and spent
  /// later, so there is nothing to break down. But a bare "Advance Amount" box
  /// in the Collection Details card made the two screens look unfinished beside
  /// Admission, which has a grid. Same grid, one row, and the head it is
  /// collected under is named rather than left implicit.
  ///
  /// Deliberately NOT a real `_AdvLine`: the amount stays bound to
  /// [_amountCtrl], so saving, the Paytm intent, validation and the receipt all
  /// behave exactly as before. This is presentation, not a change to the money.
  String get _fixedHeadName => SupabaseService.advanceHeadName(_advType);

  Widget _fixedFeeGrid() => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.cardBorder)),
        child: Column(children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            color: AppColors.tableHeadBg,
            child: Row(children: [
              Expanded(flex: 5, child: _th('FEE TYPE')),
              Expanded(flex: 3, child: _th('AMOUNT', right: true)),
              SizedBox(width: 44.w),
            ]),
          ),
          const Divider(height: 1, color: AppColors.divider),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
            child: Row(children: [
              Expanded(
                flex: 5,
                child: Row(children: [
                  const AppIcon('tag', size: 14, color: AppColors.demand),
                  SizedBox(width: 8.w),
                  Text(_fixedHeadName, style: AppUI.cell),
                ]),
              ),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _amountCtrl,
                  style: _txt,
                  textAlign: TextAlign.right,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                  ],
                  decoration: _dec('0').copyWith(prefixText: '₹ '),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              // Matches the width of the remove button on an admission line, so
              // the AMOUNT column sits in the same place on every tab.
              SizedBox(width: 44.w),
            ]),
          ),
          const Divider(height: 1, color: AppColors.divider),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            child: Row(children: [
              const Spacer(),
              Text('Total', style: AppUI.muted),
              SizedBox(width: 12.w),
              Text('₹ ${_amount.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
            ]),
          ),
        ]),
      );

  /// Fee-type lines of an ADMISSION advance. Same grid as Misc Collection.
  Widget _feeGrid() => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.cardBorder)),
        child: Column(children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            color: AppColors.tableHeadBg,
            child: Row(children: [
              Expanded(flex: 5, child: _th('FEE TYPE')),
              Expanded(flex: 3, child: _th('AMOUNT', right: true)),
              SizedBox(width: 44.w),
            ]),
          ),
          const Divider(height: 1, color: AppColors.divider),
          for (int i = 0; i < _lines.length; i++) _lineRow(i),
          const Divider(height: 1, color: AppColors.divider),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            child: Row(children: [
              OutlinedButton.icon(
                onPressed: _saving ? null : () => setState(() => _lines.add(_AdvLine())),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
              ),
              const Spacer(),
              Text('Total', style: AppUI.muted),
              SizedBox(width: 12.w),
              Text('₹ ${_amount.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 15.sp, fontWeight: FontWeight.w800, color: AppColors.primary)),
            ]),
          ),
        ]),
      );

  Widget _lineRow(int i) {
    final line = _lines[i];
    // Money typed against no fee type. Such a line cannot be receipted, and
    // before this was flagged the identical flaw in Misc Collection charged it
    // and then dropped it on save -- FC26/03251, Rs 3,600 taken for a Rs 150
    // receipt. Marking the field itself is what makes the offending line
    // obvious; the total and the save refuse it regardless.
    final needsType = line.feeType.trim().isEmpty &&
        (double.tryParse(line.amount.text.trim()) ?? 0) > 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 6.h),
      child: Row(children: [
        // Type-to-filter rather than a plain dropdown: there are well over a
        // hundred fee types, so typing three letters beats scrolling to them.
        Expanded(
            flex: 5,
            child: Autocomplete<Map<String, dynamic>>(
              key: ValueKey('advfee-$i-${line.feeId ?? ''}'),
              initialValue: TextEditingValue(text: line.feeType),
              optionsBuilder: (tev) {
                final q = tev.text.toLowerCase().trim();
                // Only the configured group's fee types. An advance banks into
                // ONE account, so offering every fee type invited itemising a
                // hostel fee under an advance settling into the college.
                final pool = _selectableFeeTypes;
                if (q.isEmpty) return pool;
                return pool.where(
                    (f) => (f['feedesc']?.toString() ?? '').toLowerCase().contains(q));
              },
              displayStringForOption: (f) => f['feedesc']?.toString() ?? '',
              onSelected: (f) => setState(() {
                line.feeId = f['fee_id'] as int?;
                line.feeType = f['feedesc']?.toString() ?? '';
                line.fgId = f['fg_id'] as int?;
                // An admission advance is banked under the group of the fee
                // types it is itemised against, so the strip moves with them.
                _refreshRouting();
              }),
              fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                controller: controller,
                focusNode: focusNode,
                style: _txt,
                decoration: _dec('Search fee type').copyWith(
                  prefixIcon: Icon(Icons.search,
                      size: 18.sp,
                      color:
                          needsType ? AppColors.error : AppColors.textLight),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 40, minHeight: 0),
                  errorText:
                      needsType ? 'Pick a fee type for this amount' : null,
                  errorStyle: TextStyle(fontSize: 10.5.sp, height: 1.1),
                  enabledBorder: needsType
                      ? OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                          borderSide: const BorderSide(color: AppColors.error))
                      : null,
                ),
                onSubmitted: (_) => onSubmit(),
                // A selection stays selected only while the text still MATCHES
                // it. Clearing already cleared the line; typing EXTRA
                // characters onto a chosen fee type did not, so the field could
                // read one thing while the line held another.
                onChanged: (v) {
                  if (line.feeId != null && v.trim() != line.feeType.trim()) {
                    setState(() {
                      line.feeId = null;
                      line.feeType = '';
                      line.fgId = null;
                    });
                  }
                },
              ),
              optionsViewBuilder: (context, onSelected, options) => Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8.r),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: 300.h, maxWidth: 460.w),
                    child: ListView(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      children: options
                          .map((f) => InkWell(
                                onTap: () => onSelected(f),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 12.w, vertical: 10.h),
                                  child: Text(f['feedesc']?.toString() ?? '',
                                      style: TextStyle(fontSize: 13.sp)),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                ),
              ),
            )),
        SizedBox(width: 12.w),
        Expanded(
            flex: 3,
            child: TextField(
              controller: line.amount,
              style: _txt,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: _dec('0.00').copyWith(
                enabledBorder: needsType
                    ? OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppUI.controlRadius),
                        borderSide: const BorderSide(color: AppColors.error))
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            )),
        SizedBox(width: 8.w),
        SizedBox(
          width: 36.w,
          child: IconButton(
            onPressed: _lines.length == 1
                ? null
                : () => setState(() {
                      _lines[i].amount.dispose();
                      _lines.removeAt(i);
                    }),
            icon: Icon(Icons.remove_circle_outline,
                size: 20, color: _lines.length == 1 ? AppColors.textLight : AppColors.error),
            tooltip: 'Remove',
            padding: EdgeInsets.zero,
          ),
        ),
      ]),
    );
  }

  Widget _th(String t, {bool right = false, bool center = false}) => Text(
        t,
        textAlign:
            right ? TextAlign.right : (center ? TextAlign.center : TextAlign.left),
        style: AppUI.tableHead,
      );

  /// Footer mirrors the Misc / Fee Collection bottom bar: a left status label,
  /// then an accent-tinted ADVANCE AMOUNT pill + Mode dropdown + Save button as
  /// one unified triple (same fill, border, height and radius).
  /// Bottom bar: what the counter has on file, then the amount being taken,
  /// the mode and the save button — the same triple as Misc / Fee Collection.
  Widget _footer() {
    final ready = !_saving && _paymode != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 10.h),
      // The institution-wide tally that used to sit here ("20 advances ·
      // Rs 50,478 unused") belongs to the register, which is now Reports ->
      // Advance Register. At the counter it answered a question nobody was
      // asking: what matters here is what THIS student holds, and the strip
      // above the form says that.
      child: Row(children: [
        const Spacer(),
        // What is about to be collected.
        Container(
          height: AppUI.controlHeight(context),
          padding: EdgeInsets.symmetric(horizontal: 16.w),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.30)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(_advType == 'A' ? 'tag' : 'empty-wallet-add',
                size: 15, color: AppColors.accent),
            SizedBox(width: 8.w),
            Text(switch (_advType) {
              'A' => 'ADMISSION ADVANCE: ',
              'M' => 'MESS ADVANCE: ',
              _ => 'ADVANCE AMOUNT: '
            },
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.3)),
            Text('₹${_amount.toStringAsFixed(0)}',
                style: TextStyle(
                    fontSize: 14.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
          ]),
        ),
        SizedBox(width: 12.w),
        Container(
          width: 168.w,
          height: AppUI.controlHeight(context),
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(
                color: _paymode == null ? AppColors.border : AppColors.accent, width: 1.2),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _paymode,
              isExpanded: true,
              isDense: false,
              hint: Text('SELECT MODE',
                  style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                      letterSpacing: 0.3)),
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              style: TextStyle(
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  letterSpacing: 0.3),
              // Same five modes as Misc Collection and Fee Collection, in the
              // same order. Paytm runs the real gateway (see _payWithPaytm).
              items: const [
                DropdownMenuItem(value: 'Cash', child: Text('CASH')),
                DropdownMenuItem(value: 'QR/UPI', child: Text('QR/UPI')),
                DropdownMenuItem(value: 'Paytm', child: Text('PAYTM')),
                DropdownMenuItem(value: 'Cheque', child: Text('CHEQUE')),
                DropdownMenuItem(value: 'DD', child: Text('DD')),
              ],
              onChanged: _saving ? null : (v) => setState(() => _paymode = v),
            ),
          ),
        ),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
            onPressed: ready ? _onSave : null,
            icon: _saving
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textLight))
                : Icon(_paymode == 'Paytm' ? Icons.open_in_new : Icons.send, size: 16.sp),
            label: Text(_saving
                ? 'Saving…'
                : (_paymode == 'Paytm' ? 'Proceed to Pay' : 'Collect Advance')),
        ),
      ]),
    );
  }

}
