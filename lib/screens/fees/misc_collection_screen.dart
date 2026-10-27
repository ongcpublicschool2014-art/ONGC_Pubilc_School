import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:printing/printing.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../services/paytm_service.dart';
import '../../widgets/paytm_checkout_dialog.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';
import '../../utils/receipt_pdf.dart';
import '../../widgets/receipt_widget.dart';
import '../../widgets/empty_state.dart';
import '../../services/pending_collection_sweep.dart';
import '../../utils/school_terms.dart';
import '../../utils/app_text.dart';

/// Miscellaneous Fee Collection — a standalone counter collection (BONAFIDE
/// CERTIFICATE, APPLICATION, …) that does NOT reduce any demand. It is stored in
/// its own tables (misc_collection + misc_collection_detail) via the
/// save_misc_collection RPC; the receipt number is drawn from the shared
/// fee-receipt sequence. Collect from a registered Student or from Others
/// (free-text name, no reg no).
class MiscCollectionScreen extends StatefulWidget {
  const MiscCollectionScreen({super.key});

  @override
  State<MiscCollectionScreen> createState() => _MiscCollectionScreenState();
}

/// One fee line: a fee type (from the feetype master) + an amount.
class _MiscLine {
  int? feeId;
  String feeType = '';
  int? fgId;
  final TextEditingController amount = TextEditingController();
}

class _MiscCollectionScreenState extends State<MiscCollectionScreen> {
  // Selection: 'S' = registered Student, 'O' = Others (free text).
  String _selection = 'S';
  DateTime _date = DateTime.now();

  /// Reconciliation state the server gave the collection just saved -- 'R' when
  /// it is already realised (cash), 'P' while it waits for the bank. Drives the
  /// "* Subject to Realization" note on the receipt.
  String _savedReconStatus = 'R';
  // Null until the cashier picks a mode (shows "SELECT MODE"), exactly like the
  // Fee Collection bottom bar; Save stays disabled until it's chosen.
  String? _paymode;
  DateTime? _transDate;

  // Student-mode lookup.
  List<Map<String, dynamic>> _courseList = [];
  List<Map<String, dynamic>> _classList = [];
  List<Map<String, dynamic>> _students = [];
  String? _selectedCourse;
  String? _selectedClass;

  /// True when Course/Class were filled in FROM the picked student rather than
  /// chosen by the user. They then act as a read-out, not a filter -- otherwise
  /// picking a student would silently narrow the search pool to that student's
  /// own class, and the next reg no typed (from any other class) would return
  /// no match.
  bool _courseClassFromStudent = false;
  Map<String, dynamic>? _student;

  // Masters.
  List<Map<String, dynamic>> _feeTypes = [];
  // The fee groups, and the one this receipt is being collected under.
  //
  // A misc receipt is ONE document and is banked into ONE account, so every
  // line on it has to belong to the same fee group -- the server picks a group
  // for it either way (save_misc_collection takes the lowest fg_id of the
  // types collected), and a cashier who mixed a MESS FEE with a BONAFIDE had
  // no way of knowing which account the money went to. Choosing the group
  // first makes that the cashier's decision and narrows the fee type list to
  // what belongs in it.
  List<Map<String, dynamic>> _feeGroups = [];
  int? _fgId;

  /// fg_id of every group that has a receipt sequence. save_misc_collection
  /// REFUSES a collection into a group without one -- it will not number a
  /// receipt out of another group's run -- so the counter says so up front.
  final Set<int> _fgWithSequence = {};

  /// Institution settings, for the per-fee-group receipt letterhead: a hostel
  /// receipt is issued by the hostel, not by the college.
  Map<String, String> _settings = const {};

  /// The name and address a receipt should print.
  ///
  /// [fgId] is the group THE RECEIPT was collected under, not whatever the
  /// picker shows now: the form is cleared before the receipt is rendered, so
  /// reading the picker printed the college head on a hostel receipt.
  ({String name, String address, String banner}) _letterhead([int? fgId]) =>
      SupabaseService.letterheadFor(
        fgId: fgId ?? _fgId,
        settings: _settings,
        fallbackName: _insName ?? 'Institution',
        fallbackAddress: _insAddress ?? '-',
      );

  // Others-mode + shared header fields.
  final _nameCtrl = TextEditingController();
  final _regnoCtrl = TextEditingController();
  final _classCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  // Payment-mode details captured in the pay-time dialog (mirrors Fee
  // Collection): transrefno = UPI txn id / cheque-DD no, bankname free text.
  final _transRefCtrl = TextEditingController();
  final _bankNameCtrl = TextEditingController();
  final _draweeCtrl = TextEditingController();
  final _transAmtCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();

  final List<_MiscLine> _lines = [_MiscLine()];

  // Institution info for the receipt.
  String? _insName, _insAddress, _insLogo, _insMobile, _insEmail;

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Recover anything Paytm confirmed after a counter walked away.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _sweepPendingCollections());
    _load();
    _loadStudents();
    _syncDate();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _regnoCtrl.dispose();
    _classCtrl.dispose();
    _cityCtrl.dispose();
    _addressCtrl.dispose();
    _transRefCtrl.dispose();
    _bankNameCtrl.dispose();
    _draweeCtrl.dispose();
    _transAmtCtrl.dispose();
    _remarksCtrl.dispose();
    for (final l in _lines) {
      l.amount.dispose();
    }
    super.dispose();
  }

  /// The schema's active academic year. Read from the year master rather than
  /// taken from AuthProvider alone: auth.yearLabel can be empty for a session
  /// (it is restored from prefs), and misc_collection was being written with
  /// yr_id NULL and yrlabel '' whenever it was -- which drops those receipts out
  /// of every year-scoped report.
  int? _yrId;
  String? _yrLabel;

  /// Paytm's own transaction id for this receipt, kept apart from transrefno
  /// (which holds OUR order id). A Misc collection has no payment row, so
  /// without this there is nothing to match against a Paytm settlement report
  /// except a dashboard lookup per receipt.
  String? _paytmTxnId;

  /// OUR order id for a Paytm misc collection (MISC<ins>T<millis>).
  ///
  /// Set the moment the order is signed and kept until the receipt is saved,
  /// because it is the only thing that ties this screen to the intent row the
  /// webhook completes from if the capture lands after we have moved on.
  String? _paytmOrderId;

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
      debugPrint('Misc: year lookup failed: $e');
    }
  }

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
        SupabaseService.fromSchema('feegroup')
            .select('fg_id, fgdesc, ban_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('fg_id', ascending: true),
      ]);
      final info = await SupabaseService.getInstitutionInfo(insId);
      // Which groups this counter may collect under (Setup -> Utilities ->
      // Misc Collection). Empty = no restriction.
      final settings = await SupabaseService.getInstitutionSettings(insId);
      final allowedFgs = SupabaseService.miscFeeGroups(settings);
      final seqRows = await SupabaseService.fromSchema('sequence')
          .select('fg_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
        _feeTypes = List<Map<String, dynamic>>.from(results[2] as List);
        // Only groups that actually OWN fee types can be collected here. An
        // advance-only group (STUDENT ADVANCE, MESS ADVANCE) exists to bank
        // advances, has no fee types, and as a chip would offer an empty
        // search box and no way to tell why.
        final typed = {
          for (final t in _feeTypes)
            if (t['fg_id'] is int) t['fg_id'] as int,
        };
        _settings = settings;
        _fgWithSequence
          ..clear()
          ..addAll([
            for (final r in (seqRows as List))
              if (r['fg_id'] is int) r['fg_id'] as int,
          ]);
        _feeGroups = [
          for (final g in List<Map<String, dynamic>>.from(results[3] as List))
            if (typed.contains(g['fg_id']) &&
                (allowedFgs.isEmpty || allowedFgs.contains(g['fg_id'])))
              g,
        ];
        _fgId ??= _feeGroups.isEmpty ? null : _feeGroups.first['fg_id'] as int?;
        _insName = info.name;
        _insAddress = info.address;
        _insLogo = info.logo;
        _insMobile = info.mobile;
        _insEmail = info.email;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load fee types and students. ${friendlyError(e)}', AppColors.error);
    }
  }

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
    // Keeps the existing order within each group and sends the TC batches to
    // the foot of the list (utils/class_sort.dart).
    return classGroupPartition(
        _classList
            .where((cl) => cl['cour_id'] == id)
            .map((e) => e['claname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty),
        (s) => s);
  }

  /// Every active student, loaded once. The search box filters this in memory,
  /// so a reg no can be typed straight in without first choosing a course and
  /// class — Course/Class are now optional narrowing filters, not a gate.
  ///
  /// fetchAll, not .limit(500): PostgREST caps a response at 1000 rows and the
  /// old limit silently hid everyone past the 500th, which looks identical to
  /// "that student doesn't exist" when you search for them.
  Future<void> _loadStudents() async {
    final auth = context.read<AuthProvider>();
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, stumobile, stuaddress, stucity, activestatus, stuphoto')
          .eq('ins_id', auth.insId ?? 1)
          .neq('activestatus', 9)
          .eq('preadmission', 0)  // next year's intake: advance screens only
          .order('stuadmno', ascending: true));
      // De-duplicate by stu_id (and drop null ids): a duplicate would give the
      // search two identical-looking entries pointing at the same student.
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

  /// The picked student has been issued a Transfer Certificate.
  ///
  /// students.activestatus is what the TC screen writes when a certificate is
  /// issued (2 Discontinued, 3 Transferred, 4 Completed, 5 Others, 9
  /// Terminated) and sets back to 1 when one is cancelled. A leaver stays
  /// SEARCHABLE -- their past receipts are looked up long after they go -- but
  /// no money is taken from them at this counter, because a receipt raised
  /// against someone who has left is one that has to be cancelled afterwards.
  ///
  /// OTHERS mode is unaffected: it collects against a name, not a registered
  /// student, which is why the mode is part of the test.
  bool get _studentHasTc =>
      _selection == 'S' &&
      _student != null &&
      ((_student!['activestatus'] as num?)?.toInt() ?? 1) != 1;

  /// The search pool, narrowed by whichever of Course / Class the USER set.
  /// Both may be left blank, in which case every student is searchable.
  List<Map<String, dynamic>> _searchPool() => _students.where((e) {
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

  /// The string stored in misc_collection.paymode.
  ///
  /// Deliberately NOT the dropdown value: Fee Collection rewrites the mode
  /// before storing it ('Cash'->'cash', 'QR/UPI'->'upi', Paytm->'Online
  /// Transfer'), and misc used to store the dropdown value verbatim. One
  /// receipt series with two vocabularies made Pending Approval and
  /// Transactions read as though they were different systems, so misc now
  /// matches payment.paymethod exactly.
  ///
  /// The dropdown value is unchanged -- only what reaches the database.
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

  void _pickStudent(Map<String, dynamic> s) {
    setState(() {
      _student = s;
      _nameCtrl.text = s['stuname']?.toString() ?? '';
      _regnoCtrl.text = s['stuadmno']?.toString() ?? '';
      _classCtrl.text = s['stuclass']?.toString() ?? '';
      _cityCtrl.text = s['stucity']?.toString() ?? '';
      _addressCtrl.text = s['stuaddress']?.toString() ?? '';

      // Show the student's own course and class in the two dropdowns. Matched
      // against the masters first: a student whose course was renamed (or who
      // predates the master row) would otherwise hand the dropdown a value that
      // is not among its items, which throws.
      final cour = s['courname']?.toString().trim() ?? '';
      final cls = s['stuclass']?.toString().trim() ?? '';
      _selectedCourse = _courseNames.contains(cour) ? cour : null;
      _selectedClass =
          _classesFor(_selectedCourse).contains(cls) ? cls : null;
      _courseClassFromStudent = true;
    });
  }

  /// What the receipt will come to -- and therefore what the parent is
  /// charged.
  ///
  /// ONLY named lines count, the same test [_namedLines] applies when saving.
  /// This used to sum every line, including one with an amount typed but no
  /// fee type picked. The Paytm order was created for that larger figure while
  /// the save dropped the unnamed line, so on 2026-09-30 a parent was charged
  /// Rs 3,600 against a receipt for Rs 150 -- the other Rs 3,450 taken with
  /// nothing issued for it. The two must be computed the same way or they can
  /// differ again.
  double get _total => _namedLines.fold(
      0.0, (s, l) => s + (double.tryParse(l.amount.text.trim()) ?? 0));

  /// The lines a save would keep: a fee type chosen AND an amount on it.
  List<_MiscLine> get _namedLines => _lines
      .where((l) =>
          l.feeType.trim().isNotEmpty &&
          (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
      .toList();

  /// Lines carrying money the cashier typed but never named. Silently dropping
  /// these is what lost the Rs 3,450; they now stop the collection instead.
  List<_MiscLine> get _unnamedWithAmount => _lines
      .where((l) =>
          l.feeType.trim().isEmpty &&
          (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
      .toList();

  /// Today, according to the DATABASE. Falls back to this machine's clock if
  /// get_server_date() is not deployed yet, so the app works either way.
  ///
  /// Everything on this screen that needs "today" comes through here. A
  /// workstation with a wrong system date was dating misc receipts a day out
  /// while regular fee receipts -- stamped NOW() server-side inside the RPC --
  /// stayed correct.
  Future<DateTime> _serverToday() async {
    try {
      final res = await SupabaseService.client.rpc('get_server_date');
      final d = DateTime.tryParse(res?.toString() ?? '');
      if (d != null) return DateTime(d.year, d.month, d.day);
    } catch (_) {/* function not deployed, or offline */}
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Refresh the collection date from the server. Cheap, and the answer only
  /// changes at midnight, so it is done on load and after each new record
  /// rather than on every keystroke.
  Future<void> _syncDate() async {
    final d = await _serverToday();
    if (mounted && d != _date) setState(() => _date = d);
  }

  void _newRecord() {
    setState(() {
      _selection = 'S';
      // Kept as an immediate value so the field is never blank; _syncDate()
      // below corrects it from the server.
      _date = DateTime.now();
      _paymode = null;
      _transDate = null;
      _selectedCourse = null;
      _selectedClass = null;
      _courseClassFromStudent = false;
      _student = null;
      _nameCtrl.clear();
      _regnoCtrl.clear();
      _classCtrl.clear();
      _cityCtrl.clear();
      _addressCtrl.clear();
      _transRefCtrl.clear();
      _bankNameCtrl.clear();
      _draweeCtrl.clear();
      _transAmtCtrl.clear();
      _remarksCtrl.clear();
      for (final l in _lines) {
        l.amount.dispose();
      }
      _lines
        ..clear()
        ..add(_MiscLine());
      _fgId = _feeGroups.isEmpty ? null : _feeGroups.first['fg_id'] as int?;
    });
    // Re-ask the server: a counter left open across midnight would otherwise
    // keep dating new receipts to the day it was opened.
    _syncDate();
  }

  /// Save & Print entry point. Mirrors the Fee Collection flow: for any
  /// non-Cash mode a dialog collects the mode-specific transaction details
  /// (UPI txn id, or cheque/DD no + date + bank) before the payment is saved.
  Future<void> _onSaveAndPrint() async {
    // Before any other validation. The button is already disabled, so this is
    // the guard for the paths that do not go through it -- Enter on a field,
    // or a student picked after the amounts were typed.
    if (_studentHasTc) {
      _snack('This student has been issued a TC, so fees cannot be collected.',
          AppColors.error);
      return;
    }
    if (_nameCtrl.text.trim().isEmpty) {
      _snack('Enter a name', AppColors.warning);
      return;
    }
    if (_namedLines.isEmpty) {
      _snack('Add at least one fee with an amount', AppColors.warning);
      return;
    }
    // An amount with no fee type against it cannot be receipted, so it must
    // not be collected either. Saying so is the whole point: the alternative,
    // taking the money and issuing a smaller receipt, is what happened before.
    final unnamed = _unnamedWithAmount;
    if (unnamed.isNotEmpty) {
      final missing = unnamed
          .map((l) => '₹${l.amount.text.trim()}')
          .join(', ');
      _snack(
          '${unnamed.length == 1 ? '1 line has' : '${unnamed.length} lines have'} '
          'an amount ($missing) but no fee type. Select a fee type or clear '
          'the amount.',
          AppColors.error);
      return;
    }
    if (_paymode == null) {
      _snack('Select a payment mode', AppColors.warning);
      return;
    }
    // Paytm takes the money BEFORE the receipt exists. The other non-cash modes
    // only record a reference the cashier types in, so they keep the dialog.
    if (_paymode == 'Paytm') {
      final amount = _total;
      if (amount <= 0) {
        _snack('Enter an amount before paying', AppColors.warning);
        return;
      }
      final ref = await _payWithPaytm(amount);
      if (ref == null) return; // not confirmed -- nothing is saved
      _transRefCtrl.text = ref;
      // _date, not DateTime.now(): this is the transaction date Bank
      // Reconciliation matches against the bank statement, and _date is the
      // server's. A day out here means the receipt never matches its line.
      _transDate = _date;
      _transAmtCtrl.text = amount.toStringAsFixed(2);
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

  /// What this receipt WOULD be, recorded before Paytm is contacted.
  ///
  /// Paytm takes the money before the receipt exists, so without this there is
  /// no record anywhere of which fee types the money was for -- and a capture
  /// that lands after the counter has moved on cannot be receipted by anyone.
  /// Deliberately NOT built from _save()'s header: at this point the cashier
  /// has not typed a reference and there is no transaction id yet, so the
  /// fields that only exist after payment are filled the way the Paytm branch
  /// fills them.
  Map<String, dynamic> _intentHeader(double amount) {
    final auth = context.read<AuthProvider>();
    String? stuIdStr;
    if (_selection == 'S' && _student != null) {
      stuIdStr = _student!['stu_id']?.toString();
    }
    return <String, dynamic>{
      'inscode': auth.inscode ?? '',
      'yr_id': _yrId,
      'yrlabel': _yrLabel ?? auth.yearLabel ?? '',
      'selection': _selection,
      'stu_id': stuIdStr,
      'regno': _regnoCtrl.text.trim(),
      'stuclass': _classCtrl.text.trim(),
      'stuname': _nameCtrl.text.trim(),
      'courname': _student?['courname']?.toString() ?? _selectedCourse ?? '',
      'city': _cityCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'paymode': _dbPaymode('Paytm'),
      'ban_id': null,
      'bankname': 'PAYTM',
      'transrefno': '',
      'draweebank': '',
      'transdate': _date.toIso8601String().split('T').first,
      'transamt': amount.toStringAsFixed(2),
      'collectedby': auth.userName ?? '',
      'remarks': _remarksCtrl.text.trim(),
    };
  }

  List<Map<String, dynamic>> _intentLines() => _lines
      .where((l) =>
          l.feeType.trim().isNotEmpty &&
          (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
      .map((l) => {
            'fee_id': l.feeId?.toString(),
            'feetype': l.feeType.trim(),
            'amount': l.amount.text.trim(),
          })
      .toList();

  /// Collect a Misc receipt through Paytm.
  ///
  /// Returns the Paytm order id once the gateway CONFIRMS the money, null
  /// otherwise. showPaytmCheckout reports 'C' only after a server-side verify
  /// against Paytm's status API, so the receipt is written strictly against
  /// money that actually landed -- an abandoned or failed checkout leaves no
  /// misc_collection row behind at all.
  Future<String?> _payWithPaytm(double amount) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;

    // Same routing rule as Fee Collection: the merchant of the fee group this
    // receipt will be banked under -- a MESS FEE collected here settles into
    // the hostel merchant, a BONAFIDE into the college one -- falling back to
    // the institution's own merchant, and a refusal rather than a silent fall
    // back to the parent.
    //
    // The group is resolved the same way save_misc_collection resolves it, so
    // the account named on the receipt and the account the money lands in are
    // the same account.
    final banId = !await SupabaseService.feeGroupSettlementEnabled(insId)
        ? null
        : await SupabaseService.resolveRoutingBanId(
      insId: insId,
      feeTypes: [
        for (final l in _lines)
          if (l.feeType.trim().isNotEmpty &&
              (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
            l.feeType.trim(),
      ],
    );
    final routing =
        await SupabaseService.resolvePaytmRouting(insId: insId, banId: banId);
    if (!routing.ok) {
      if (mounted) _snack(routing.error!, AppColors.error);
      return null;
    }

    // A misc collection has no payment row to derive an order id from, so it
    // carries its own. The timestamp keeps it unique per counter.
    _paytmTxnId = null;
    final orderId = 'MISC${insId}T${DateTime.now().millisecondsSinceEpoch}';
    _paytmOrderId = orderId;

    // BEFORE the gateway is contacted, never after: the whole point is to have
    // a record if this machine never gets to the save. A failure here is not
    // fatal -- the collection still works exactly as it did -- but it does mean
    // a late capture would be unrecoverable, so say so in the log.
    try {
      await SupabaseService.client.rpc('record_pending_collection', params: {
        'p_order_id': orderId,
        'p_ins_id': insId,
        'p_kind': 'M',
        'p_amount': amount,
        'p_header': _intentHeader(amount),
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
        // A misc receipt has no payment row. Must not be 0 -- see
        // PaytmService.kNoPaymentRow. Nothing downstream reads it: the order id
        // and cust id are both passed explicitly, and the function's
        // payorderid update matches no row for a negative id.
        payId: PaytmService.kNoPaymentRow,
        amount: amount,
        custId: _regnoCtrl.text.trim().isNotEmpty
            ? 'STU-${_regnoCtrl.text.trim()}'
            : 'MISC-$insId',
        orderId: orderId,
        mid: routing.mid,
      );
      if (!mounted) return null;
      // NAME THE MERCHANT THE PAYER IS ABOUT TO PAY.
      //
      // Left unset, buildCheckoutHtml falls back to the literal 'KCET', so a
      // MESS FEE routed to the hostel merchant still announced itself as the
      // college in Paytm's own header -- the one screen the payer actually
      // reads. Fee Collection already composes this; misc did not, so the two
      // disagreed about the same payment.
      //
      // The group is resolved from the fee types, exactly as banId above was,
      // so the name shown and the account billed cannot drift apart.
      final payFg = await SupabaseService.feeGroupOfFeeTypes([
        for (final l in _lines)
          if (l.feeType.trim().isNotEmpty &&
              (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
            l.feeType.trim(),
      ]);
      final payGroup = payFg == null
          ? ''
          : (_feeGroups.firstWhere((g) => g['fg_id'] == payFg,
                  orElse: () => const {})['fgdesc']
              ?.toString() ??
              '');
      if (!mounted) return null;
      final insName = context.read<AuthProvider>().insName ?? 'KCET';
      final payMid = routing.mid ?? '';
      final midTail =
          payMid.length > 6 ? payMid.substring(payMid.length - 6) : payMid;
      final status = await showPaytmCheckout(
        context,
        order: order,
        amount: amount,
        studentName: _nameCtrl.text.trim(),
        merchantName: payGroup.isEmpty || !routing.routedToOwnAccount
            ? insName
            : '$insName - $payGroup',
        // Which account, and the tail of the merchant id that proves it, so a
        // mis-route is visible BEFORE the card is entered.
        //
        // When the group has no account of its own the money falls back to
        // the institution merchant; naming the group beside that merchant's
        // id would read as if the group's own account had been used.
        settlingTo: !routing.routedToOwnAccount
            ? (midTail.isEmpty
                ? 'institution account (this fee group has none of its own)'
                : 'institution account  ·  merchant …$midTail')
            : payGroup.isEmpty
                ? (midTail.isEmpty ? '' : 'merchant …$midTail')
                : '$payGroup  ·  merchant …$midTail',
      );
      if (status == 'C') {
        // One extra status call purely to read the TXNID. Deliberately
        // best-effort: the money is already confirmed, so a hiccup here must
        // not fail the receipt -- it just leaves paytm_txnid null.
        try {
          final st = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
          _paytmTxnId = st.paymentId;
        } catch (e) {
          debugPrint('Paytm txnid lookup failed: $e');
        }
        // The TXN id, not the order id. transrefno is what the receipt prints
        // and what Bank Reconciliation matches against the statement; the order
        // id (MISC<ins>T<millis>) is ours alone and appears on no bank line.
        // Falls back to the order id only if the status lookup above failed, so
        // the receipt still carries something traceable.
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
      // The gateway's own words, not friendlyError's generic line: a Paytm
      // or edge-function refusal names the actual reason, and hiding it turns
      // a two-minute fix into a guessing game.
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        _snack('Paytm could not complete the payment. $msg', AppColors.error);
      }
      return null;
    }
  }

  /// Collects the transaction details for a non-Cash mode, exactly like the
  /// Fee Collection pay dialog. Returns true when the user confirms.
  Future<bool> _promptModeDetails() async {
    _transRefCtrl.clear();
    _bankNameCtrl.clear();
    // Default to the collection date rather than blank: a UPI payment happens
    // on the day it is collected, and a cheque is nearly always dated today
    // too. Still editable, and Cheque/DD continue to require it explicitly.
    _transDate = _date;
    final isUpi = _paymode == 'QR/UPI';
    final doc = _paymode == 'DD' ? 'DD' : 'Cheque';
    final docWord = _paymode == 'DD' ? 'DD' : 'cheque'; // in sentences
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
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const AppIcon('wallet-money', size: 20, color: AppColors.accent),
                  SizedBox(width: 8.w),
                  Text(isUpi ? 'UPI Payment' : '$doc Payment', style: AppUI.cardTitle),
                  const Spacer(),
                  Text('₹${_total.toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
                ]),
                SizedBox(height: 18.h),
                if (isUpi)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      flex: 3,
                      child: _labeled('UPI Transaction ID *', TextField(
                        controller: _transRefCtrl, style: _txt, autofocus: true,
                        onChanged: (_) { if (refErr != null) setD(() => refErr = null); },
                        decoration: _dec('e.g. 412345678901').copyWith(errorText: refErr),
                      )),
                    ),
                    SizedBox(width: 12.w),
                    Expanded(
                      flex: 2,
                      child: _labeled('Transaction Date',
                          _dateBox(_transDate, (dt) => setD(() => _transDate = dt),
                              hint: AppText.dateHint)),
                    ),
                  ])
                else ...[
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _labeled('$doc No. *', TextField(
                      controller: _transRefCtrl, style: _txt, autofocus: true,
                      onChanged: (_) { if (refErr != null) setD(() => refErr = null); },
                      decoration: _dec('Enter $doc number').copyWith(errorText: refErr),
                    ))),
                    SizedBox(width: 12.w),
                    Expanded(child: _labeled('$doc Date *',
                        _dateBox(_transDate, (dt) => setD(() { _transDate = dt; dateErr = null; }), hint: AppText.dateHint))),
                  ]),
                  if (dateErr != null) ...[
                    SizedBox(height: 5.h),
                    Text(dateErr!, style: TextStyle(fontSize: 11.sp, color: AppColors.error)),
                  ],
                  SizedBox(height: 12.h),
                  _labeled('Bank Name *', TextField(
                    controller: _bankNameCtrl, style: _txt,
                    onChanged: (_) { if (bankErr != null) setD(() => bankErr = null); },
                    decoration: _dec('Enter bank name').copyWith(errorText: bankErr),
                  )),
                ],
                SizedBox(height: 22.h),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  AppUI.requiredNote(),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
                  ),
                  SizedBox(width: 10.w),
                  ElevatedButton(
                    onPressed: () {
                      if (_transRefCtrl.text.trim().isEmpty) {
                        setD(() => refErr = isUpi ? 'Enter the UPI transaction ID' : 'Enter the $docWord number');
                        return;
                      }
                      if (!isUpi) {
                        final noDate = _transDate == null;
                        final noBank = _bankNameCtrl.text.trim().isEmpty;
                        if (noDate || noBank) {
                          setD(() {
                            dateErr = noDate ? 'Select the $docWord date' : null;
                            bankErr = noBank ? 'Enter the bank name' : null;
                          });
                          return;
                        }
                      }
                      _transAmtCtrl.text = _total.toStringAsFixed(2);
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
    final insId = auth.insId ?? 1;
    if (_nameCtrl.text.trim().isEmpty) {
      _snack('Enter a name', AppColors.warning);
      return;
    }
    final validLines = _lines
        .where((l) => l.feeType.trim().isNotEmpty && (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
        .toList();
    if (validLines.isEmpty) {
      _snack('Add at least one fee with an amount', AppColors.warning);
      return;
    }
    // Fee group for the shared receipt sequence = first line's fee group.
    final fgId = validLines.first.fgId;

    setState(() => _saving = true);
    try {
      String? stuIdStr;
      if (_selection == 'S' && _student != null) {
        stuIdStr = _student!['stu_id']?.toString();
      }
      final bankName = _paymode == 'Cash' ? null : _bankNameCtrl.text.trim();
      final header = <String, dynamic>{
        'inscode': auth.inscode ?? '',
        // Both are required for the receipt to appear in year-scoped reports.
        // Prefer the year master over AuthProvider, which can be blank.
        'yr_id': _yrId,
        'yrlabel': _yrLabel ?? auth.yearLabel ?? '',
        // mcdate is deliberately NOT sent. save_misc_collection falls back to
        // CURRENT_DATE when it is absent, so the collection date comes from the
        // database server -- exactly like a regular fee, whose paydate is
        // stamped NOW() inside process_grouped_payment and never taken from the
        // client. A workstation with a wrong clock was dating misc receipts a
        // day out while fee receipts were correct, which is what broke tallying.
        // The screen has no date picker, so nothing user-chosen is lost here.
        'selection': _selection,
        'stu_id': stuIdStr,
        'regno': _regnoCtrl.text.trim(),
        'stuclass': _classCtrl.text.trim(),
        'stuname': _nameCtrl.text.trim(),
        'courname': _student?['courname']?.toString() ?? _selectedCourse ?? '',
        'city': _cityCtrl.text.trim(),
        'address': _addressCtrl.text.trim(),
        'paymode': _dbPaymode(_paymode),
        'ban_id': null,
        'bankname': bankName,
        'transrefno': _transRefCtrl.text.trim(),
        'paytm_txnid': _paytmTxnId,
        'draweebank': _draweeCtrl.text.trim(),
        // The mode dialog only asks for a date on Cheque/DD -- QR/UPI and Paytm
        // have no separate instrument date -- so fall back to the collection
        // date rather than writing NULL. A non-cash receipt with no transaction
        // date cannot be matched against a bank statement.
        'transdate': (_paymode == 'Cash'
                ? null
                : (_transDate ?? _date))
            ?.toIso8601String()
            .split('T')
            .first,
        'transamt': _transAmtCtrl.text.trim(),
        'collectedby': auth.userName ?? '',
        'remarks': _remarksCtrl.text.trim(),
        if (fgId != null) 'fg_id': fgId.toString(),
      };
      final lines = validLines
          .map((l) => {
                'fee_id': l.feeId?.toString(),
                'feetype': l.feeType.trim(),
                'amount': l.amount.text.trim(),
              })
          .toList();

      // A Paytm collection must be CLAIMED before it is saved. The webhook can
      // be raising this same receipt right now from the intent row -- it does
      // so whenever a capture lands late -- and two writers would produce two
      // receipts for one payment. Exactly one caller wins the claim.
      if (_paytmOrderId != null) {
        final claim = await SupabaseService.client
            .rpc('claim_pending_collection', params: {
          'p_order_id': _paytmOrderId,
          'p_by': 'COUNTER',
        });
        final won = claim is List && claim.isNotEmpty;
        if (!won) {
          setState(() => _saving = false);
          _snack(
            'This payment has already been receipted automatically. '
            'Open View Receipts on Miscellaneous Collection to print it.',
            AppColors.warning,
          );
          return;
        }
      }

      final res = await SupabaseService.client.rpc('save_misc_collection', params: {
        'p_ins_id': insId,
        'p_header': header,
        'p_lines': lines,
      });
      final map = res is Map ? res : <String, dynamic>{};
      final mcno = map['mcno']?.toString() ?? '';

      // The intent is done. Settling it stops the health check reporting this
      // collection as unfinished, and stops the webhook touching it again.
      if (_paytmOrderId != null) {
        try {
          await SupabaseService.client.rpc('settle_pending_collection', params: {
            'p_order_id': _paytmOrderId,
            'p_status': 'C',
            'p_receipt_no': mcno,
          });
        } catch (e) {
          debugPrint('settle_pending_collection failed: $e');
        }
        _paytmOrderId = null;
      }
      final total = (map['total'] as num?)?.toDouble() ?? _total;

      // Read back the date the server stamped, so the printed receipt and the
      // stored row can never disagree. Best effort: if this select fails the
      // receipt falls back to the local date, which is cosmetic -- the row is
      // already saved with the correct server date either way.
      try {
        final saved = await SupabaseService.fromSchema('misc_collection')
            .select('mcdate, recon_status')
            .eq('ins_id', insId)
            .eq('mcno', mcno)
            .limit(1);
        final rows = saved as List;
        if (rows.isNotEmpty) {
          final d = DateTime.tryParse(rows.first['mcdate']?.toString() ?? '');
          if (d != null) _date = d;
          // Whether this collection counts as realised is decided by the RPC
          // (cash clears immediately, everything else waits for the bank), so
          // the receipt takes the server's answer rather than guessing from the
          // pay mode here.
          _savedReconStatus =
              rows.first['recon_status']?.toString() ?? 'P';
        }
      } catch (_) {/* keep the local date on the receipt */}

      if (!mounted) return;
      setState(() => _saving = false);
      _showSuccessDialog(mcno, total, validLines);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // friendlyError keeps the useful part of a database refusal while
      // hiding raw exception text from the counter.
      _snack('Could not save the collection. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<void> _showReceipt(String mcno, double total, List<_MiscLine> lines) async {
    // The group these lines belong to -- the same one the server banked the
    // receipt under.
    final lhFg = await SupabaseService.feeGroupOfFeeTypes(
        [for (final l in lines) l.feeType.trim()]);
    final dateStr = formatDmy(_date);
    final data = ReceiptData(
      receiptNo: mcno,
      date: dateStr,
      studentName: _nameCtrl.text.trim(),
      mobileNo: (_student != null ? _student!['stumobile']?.toString() : null) ?? '-',
      address: _addressCtrl.text.trim().isEmpty ? '-' : _addressCtrl.text.trim(),
      admissionNo: _regnoCtrl.text.trim().isEmpty ? '-' : _regnoCtrl.text.trim(),
      className: _classCtrl.text.trim().isEmpty ? '-' : _classCtrl.text.trim(),
      courseName: _selectedCourse ?? '-',
      schoolName: _letterhead(lhFg).name,
      schoolAddress: _letterhead(lhFg).address,
      headerBanner: _letterhead(lhFg).banner,
      schoolLogoUrl: _insLogo,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: [
        ReceiptTermDetail(
          term: '-',
          fees: [
            for (final l in lines)
              ReceiptFeeItem(type: l.feeType.trim(), amount: double.tryParse(l.amount.text.trim()) ?? 0),
          ],
        ),
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

  /// Post-save confirmation — same shape as Fee Collection's: a tick, the
  /// receipt number, amount and mode, a View Receipt button that opens the
  /// existing receipt viewer, and Done to clear the form for the next entry.
  void _showSuccessDialog(String mcno, double total, List<_MiscLine> lines) {
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
            Text('Collection Saved', style: AppUI.cardTitle),
            SizedBox(height: 8.h),
            Text('Receipt No.: $mcno',
                style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
            Text('Amount: ₹${total.toStringAsFixed(2)}',
                style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
            Text('${AppText.paymentMode}: ${_paymode ?? 'Cash'}',
                style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
            SizedBox(height: 16.h),
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                // Build the receipt BEFORE clearing — _showReceipt reads the
                // form's student/payment fields, which _newRecord resets.
                await _showReceipt(mcno, total, lines);
                if (mounted) _newRecord();
              },
              icon: AppIcon('document-download', size: 16),
              label: const Text('View Receipt'),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
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

  /// Receipt viewer window: rendered receipt with Download / Print / close.
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
                            fileName: 'Receipt_${data.receiptNo.replaceAll('/', '_')}.pdf',
                            type: FileType.custom,
                            allowedExtensions: ['pdf'],
                          );
                          if (res != null) {
                            await File(res).writeAsBytes(bytes);
                            if (mounted) _snack('Receipt PDF saved', AppColors.success);
                          }
                        } catch (e) {
                          if (mounted) _snack(friendlyError(e), AppColors.error);
                        }
                      },
                      icon: AppIcon('document-download', size: 18),
                      label: const Text('Download PDF'),
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
                        BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 2)),
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

  // ── Receipts lookup: browse & reprint saved misc collections ───────────────
  Future<void> _openReceiptsList() async {
    final auth = context.read<AuthProvider>();
    List<Map<String, dynamic>> rows = [];
    try {
      final res = await SupabaseService.fromSchema('misc_collection')
          .select('mc_id, mcno, mcdate, stuname, stuclass, regno, totalamount, paymode, city, address, transrefno, paytm_txnid, recon_status')
          .eq('ins_id', auth.insId ?? 1)
          .eq('activestatus', 1)
          .order('mc_id', ascending: false)
          .limit(200);
      rows = List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      if (mounted) _snack('Could not load receipts. ${friendlyError(e)}', AppColors.error);
      return;
    }
    if (!mounted) return;
    final search = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        final q = search.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? rows
            : rows.where((r) =>
                (r['mcno']?.toString().toLowerCase() ?? '').contains(q) ||
                (r['stuname']?.toString().toLowerCase() ?? '').contains(q) ||
                (r['regno']?.toString().toLowerCase() ?? '').contains(q)).toList();
        return Dialog(
          child: SizedBox(
            width: 640,
            height: 680,
            child: Column(children: [
              Padding(
                padding: EdgeInsets.fromLTRB(16.w, 14.h, 16.w, 8.h),
                child: Row(children: [
                  AppUI.iconTile('receipt-2', size: 18),
                  SizedBox(width: 12.w),
                  Text('Miscellaneous Receipts', style: AppUI.cardTitle),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: AppIcon.linear('close-circle', size: 20)),
                ]),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.w),
                child: TextField(controller: search, style: _txt, decoration: _dec(schoolTerm('Search by receipt no., name or register no.')), onChanged: (_) => setSt(() {})),
              ),
              SizedBox(height: 8.h),
              const Divider(height: 1),
              Expanded(
                child: Container(
                  color: AppColors.surface,
                  child: filtered.isEmpty
                      ? (q.isEmpty
                          ? const EmptyState(icon: 'receipt-2', title: 'No receipts yet', subtitle: 'Saved miscellaneous collections will show up here.')
                          : AppUI.empty(
                              icon: 'receipt-2',
                              title: 'No matching receipts',
                              why: 'Nothing matches "${search.text.trim()}". ${schoolTerm('Try another receipt no., name or register no.')}'))
                      : Builder(builder: (_) {
                          // Group receipts by date (rows already come newest-first).
                          final groups = <String, List<Map<String, dynamic>>>{};
                          for (final r in filtered) {
                            groups.putIfAbsent(r['mcdate']?.toString() ?? '', () => []).add(r);
                          }
                          final items = <Widget>[];
                          groups.forEach((date, list) {
                            final dayTotal = list.fold<double>(0, (s, r) => s + ((r['totalamount'] as num?)?.toDouble() ?? 0));
                            items.add(_dateHeader(date, list.length, dayTotal));
                            for (final r in list) {
                              items.add(_receiptTile(r, () { Navigator.pop(ctx); _viewSavedReceipt(r); }));
                            }
                          });
                          return ListView(padding: EdgeInsets.fromLTRB(12.w, 4.h, 12.w, 12.h), children: items);
                        }),
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }

  String _prettyDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso.isEmpty ? '—' : iso;
    return formatDmy(d);
  }

  Widget _dateHeader(String iso, int count, double total) => Padding(
        padding: EdgeInsets.only(top: 10.h, bottom: 6.h, left: 2.w, right: 2.w),
        child: Row(children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
            decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(999)),
            child: Text(_prettyDate(iso), style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
          ),
          SizedBox(width: 8.w),
          Text('$count receipt${count == 1 ? '' : 's'}', style: AppUI.muted),
          const Spacer(),
          Text('₹ ${total.toStringAsFixed(2)}', textAlign: TextAlign.right, style: AppUI.money),
        ]),
      );

  Widget _receiptTile(Map<String, dynamic> r, VoidCallback onTap) {
    final amt = (r['totalamount'] as num?)?.toDouble() ?? 0;
    final name = r['stuname']?.toString() ?? '';
    final sub = [r['mcno'], r['stuclass'] ?? r['regno'], r['paymode']]
        .where((e) => e != null && e.toString().trim().isNotEmpty)
        .join('  •  ');
    return Padding(
      padding: EdgeInsets.only(bottom: 6.h),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
            child: Row(children: [
              AppUI.iconTile('receipt-2', size: 18),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isEmpty ? '-' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label),
                  SizedBox(height: 2.h),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
                ]),
              ),
              SizedBox(width: 10.w),
              Text('₹ ${amt.toStringAsFixed(2)}', textAlign: TextAlign.right, style: AppUI.money),
              SizedBox(width: 8.w),
              AppIcon.linear('Chevron Right', size: 16, color: AppColors.textLight),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _viewSavedReceipt(Map<String, dynamic> mc) async {
    final auth = context.read<AuthProvider>();
    List<Map<String, dynamic>> lines = [];
    try {
      final res = await SupabaseService.fromSchema('misc_collection_detail')
          .select('feetype, amount')
          .eq('mc_id', mc['mc_id'])
          .eq('activestatus', 1);
      lines = List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      if (mounted) _snack('Could not load the receipt details. ${friendlyError(e)}', AppColors.error);
      return;
    }
    // From the receipt's own lines, not from the picker: a saved receipt is
    // reopened long after the counter moved on to another group.
    final lhFg = await SupabaseService.feeGroupOfFeeTypes(
        [for (final l in lines) l['feetype']?.toString() ?? '']);
    if (!mounted) return;
    DateTime d = DateTime.now();
    final ds = mc['mcdate']?.toString();
    if (ds != null && ds.isNotEmpty) d = DateTime.tryParse(ds) ?? d;
    final dateStr = formatDmy(d);
    final data = ReceiptData(
      receiptNo: mc['mcno']?.toString() ?? '',
      date: dateStr,
      studentName: mc['stuname']?.toString() ?? '',
      mobileNo: '-',
      address: (mc['address']?.toString().trim().isNotEmpty ?? false) ? mc['address'].toString() : '-',
      admissionNo: (mc['regno']?.toString().trim().isNotEmpty ?? false) ? mc['regno'].toString() : '-',
      className: (mc['stuclass']?.toString().trim().isNotEmpty ?? false) ? mc['stuclass'].toString() : '-',
      schoolName: _letterhead(lhFg).name,
      schoolAddress: _letterhead(lhFg).address,
      headerBanner: _letterhead(lhFg).banner,
      schoolLogoUrl: _insLogo,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: [
        ReceiptTermDetail(term: '-', fees: [
          for (final l in lines)
            ReceiptFeeItem(type: l['feetype']?.toString() ?? '', amount: (l['amount'] as num?)?.toDouble() ?? 0),
        ]),
      ],
      paymentMethod: mc['paymode']?.toString() ?? 'Cash',
      paymentDate: dateStr,
      status: 'paid',
      // Gateway txn id when there is one -- receipts saved before this fix
      // still hold the order id in transrefno.
      paymentReference: (mc['paytm_txnid']?.toString().trim().isNotEmpty ?? false)
          ? mc['paytm_txnid']?.toString()
          : mc['transrefno']?.toString(),
      // The row's OWN state. Hardcoding 'R' meant a non-cash misc receipt never
      // printed "* Subject to Realization", so the document said the money had
      // cleared while Bank Reconciliation still showed it pending.
      reconStatus: mc['recon_status']?.toString() ?? 'P',
      total: (mc['totalamount'] as num?)?.toDouble() ?? 0,
    );
    if (mounted) _showReceiptWindow(data);
  }

  void _snack(String msg, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: c));
  }

  // ── styling helpers ────────────────────────────────────────────────────────
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

  /// Small section header (tinted icon chip + title) used to group the form
  /// into clear cards, consistent with the rest of the app.
  /// Each section carries its own colour, so the eye can find "the green one"
  /// without reading every heading: Student blue, Collection Details green,
  /// Fee Types violet. Matches Advance Collection.
  Widget _miniHeader(String icon, String title, Color tint, {Widget? trailing}) => Row(children: [
        Container(
          width: 24.w, height: 24.w, alignment: Alignment.center,
          decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(7.r)),
          child: AppIcon(icon, size: 13, color: tint),
        ),
        SizedBox(width: 8.w),
        Text(title, style: AppUI.label),
        if (trailing != null) ...[const Spacer(), trailing],
      ]);

  Widget _sectionCard({required String icon, required String title, required Color tint, required Widget child, Widget? trailing}) => Container(
        width: double.infinity,
        // Tight: three of these stack on a laptop and the fee table -- the
        // part being filled in -- was pushed under the fold.
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: EdgeInsets.all(10.w),
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
                      icon: _selection == 'S' ? 'people' : 'user-add',
                      title: _selection == 'S' ? 'Student' : 'Payer Details',
                      tint: AppColors.accent,
                      child: _partyRow(),
                    ),
                    SizedBox(height: 9.h),
                    _detailForm(),
                    SizedBox(height: 9.h),
                    _sectionCard(
                      icon: 'tag',
                      title: 'Fee Types',
                      tint: AppColors.demand,
                      child: _feeGrid(),
                    ),
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
          AppUI.iconTile('receipt-2'),
          SizedBox(width: 12.w),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Miscellaneous Collection', style: AppUI.cardTitle),
                Text('Counter collections that do not settle a fee demand',
                    style: AppUI.muted),
              ]),
          SizedBox(width: 18.w),
          _segToggle(),
          SizedBox(width: 12.w),
          Expanded(
            child: Text(
                _selection == 'S'
                    ? 'Against a registered student'
                    : schoolTerm('Against a name — no register no. needed'),
                overflow: TextOverflow.ellipsis,
                style: AppUI.muted),
          ),
          Builder(builder: (context) {
            final compact = MediaQuery.of(context).size.width <= 1366;
            return Row(mainAxisSize: MainAxisSize.min, children: [
              _toolButton(
                  icon: 'receipt-2',
                  label: 'View Receipts',
                  compact: compact,
                  onTap: _openReceiptsList),
              SizedBox(width: 8.w),
              _toolButton(
                  icon: 'trash', label: AppText.clear, compact: compact, onTap: _newRecord),
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


  Widget _segToggle() {
    Widget seg(String label, String val) {
      final sel = _selection == val;
      return InkWell(
        onTap: () => setState(() => _selection = val),
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
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10.r), border: Border.all(color: AppColors.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [seg('Student', 'S'), seg('Others', 'O')]),
    );
  }


  /// Type a reg no or a name. Mirrors the Transfer Certificate search rather
  /// than inventing a second idiom for the same job.
  ///
  /// The key rebuilds the field when the filters or the picked student change,
  /// so initialValue is re-read — Autocomplete only honours it on construction.
  Widget _studentSearch() => Autocomplete<Map<String, dynamic>>(
        key: ValueKey('miscstu-${_selectedCourse ?? ''}-${_selectedClass ?? ''}-${_student?['stuadmno'] ?? ''}'),
        initialValue: TextEditingValue(
            text: _student == null ? '' : '${_student!['stuadmno']}  •  ${_student!['stuname']}'),
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
          decoration: _dec(_students.isEmpty ? 'Loading students…' : schoolTerm('Search by register no. or name'))
              .copyWith(
                  prefixIcon: Icon(Icons.search, size: 18.sp, color: AppColors.textLight),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 0)),
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
                    .map((e) => _suggestionRow(e, onSelected))
                    .toList(),
              ),
            ),
          ),
        ),
      );

  /// One line of the student dropdown. A leaver is still listed -- they have
  /// to be findable -- but wears a red pill, so the counter sees it BEFORE
  /// selecting rather than after typing the amounts.
  Widget _suggestionRow(Map<String, dynamic> e,
      void Function(Map<String, dynamic>) onSelected) {
    final cls = e['stuclass']?.toString().trim() ?? '';
    final hasTc = ((e['activestatus'] as num?)?.toInt() ?? 1) != 1;
    return InkWell(
      onTap: () => onSelected(e),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
        child: Row(children: [
          Expanded(
            child: Text(
                '${e['stuadmno']}  •  ${e['stuname']}'
                "${cls.isEmpty ? '' : '   ($cls)'}",
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.sp)),
          ),
          if (hasTc) ...[
            SizedBox(width: 8.w),
            AppUI.chip('TC Issued', AppStatus.danger),
          ],
        ]),
      ),
    );
  }

  Widget _partyRow() {
    if (_selection == 'S') {
      final fields = <Widget>[
        SizedBox(width: 200.w, child: _labeled(schoolTerm('Course'), DropdownButtonFormField<String>(
          // FormField.initialValue is read once, in initState -- a rebuild with
          // a new value is ignored. Keying on the value forces a fresh field so
          // a course set from the picked student actually shows.
          key: ValueKey('misc-course-${_selectedCourse ?? ''}'),
          initialValue: _courseNames.contains(_selectedCourse) ? _selectedCourse : null,
          isExpanded: true, style: _txt, decoration: _dec(schoolTerm('Select course')),
          items: _courseNames.map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (v) => setState(() { _selectedCourse = v; _selectedClass = null; _student = null; _courseClassFromStudent = false; }),
        ))),
        SizedBox(width: 180.w, child: _labeled(schoolTerm('Class'), DropdownButtonFormField<String>(
          key: ValueKey('misc-class-${_selectedCourse ?? ''}-${_selectedClass ?? ''}'),
          initialValue: _classesFor(_selectedCourse).contains(_selectedClass) ? _selectedClass : null,
          isExpanded: true, style: _txt, decoration: _dec(schoolTerm('Select class')),
          items: _classesFor(_selectedCourse).map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (v) => setState(() { _selectedClass = v; _student = null; _courseClassFromStudent = false; }),
        ))),
        SizedBox(width: 320.w, child: _labeled('Student', _studentSearch())),
        if (_student != null) _selectedStudentStrip(),
      ];
      // The refusal sits directly under the picker, so it reads as part of
      // choosing the student rather than as a footnote further down the form.
      if (!_studentHasTc) {
        return Wrap(spacing: 12.w, runSpacing: 10.h, children: fields);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12.w, runSpacing: 10.h, children: fields),
        _miscTcNotice(),
      ]);
    }
    // Others mode — free text.
    return Wrap(spacing: 12.w, runSpacing: 10.h, children: [
      SizedBox(width: 260.w, child: _labeled('Name *', TextField(controller: _nameCtrl, style: _txt, decoration: _dec('Enter name')))),
      SizedBox(width: 200.w, child: _labeled(schoolTerm('Register No.'), TextField(controller: _regnoCtrl, style: _txt, decoration: _dec(schoolTerm('Enter register no. (optional)'))))),
      SizedBox(width: 180.w, child: _labeled(schoolTerm('Class'), TextField(controller: _classCtrl, style: _txt, decoration: _dec(schoolTerm('Enter class (optional)'))))),
      SizedBox(width: 180.w, child: _labeled('City', TextField(controller: _cityCtrl, style: _txt, decoration: _dec('Enter city (optional)')))),
      SizedBox(width: 300.w, child: _labeled('Address', TextField(controller: _addressCtrl, style: _txt, decoration: _dec('Enter address (optional)')))),
    ]);
  }

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
                    '${schoolTerm('Register No.:')} ${s['stuadmno'] ?? ''}'
                    "${cls.isEmpty ? '' : '  •  $cls'}",
                    style: AppUI.muted,
                    overflow: TextOverflow.ellipsis),
              ]),
        ),
      ]),
    );
  }

  /// "TC ISSUED" -- the same red bar Fee Collection shows. One counter
  /// refusing a leaver while the next one takes their money would be worse
  /// than either rule on its own.
  Widget _miscTcNotice() => Container(
        margin: EdgeInsets.only(top: 12.h),
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
        decoration: BoxDecoration(
          color: AppColors.error,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
        ),
        child: Row(children: [
          Icon(Icons.block, size: 18.sp, color: Colors.white),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('TC Issued — Fees Cannot Be Collected',
                      style: TextStyle(
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                          color: Colors.white)),
                  SizedBox(height: 2.h),
                  Text(
                    'This student has been issued a Transfer Certificate, so '
                    'miscellaneous fees cannot be collected. Re-activate the '
                    'student on TC → Transfer Certificate Entry first.',
                    style: TextStyle(
                        fontSize: 11.5.sp,
                        color: Colors.white.withValues(alpha: 0.92)),
                  ),
                ]),
          ),
        ]),
      );

  Widget _detailForm() {
    return _sectionCard(
      icon: 'calendar-1',
      title: 'Collection Details',
      tint: AppColors.success,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _labeled('Date', Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(horizontal: AppUI.compact(context) ? 12 : 14),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
          // Read-only on purpose: mcdate is stamped by the DATABASE server
          // inside save_misc_collection, so a workstation with a wrong clock
          // cannot misdate a receipt.
          child: Row(children: [
            const AppIcon('calendar-1', size: 14, color: AppColors.success),
            SizedBox(width: 8.w),
            Expanded(child: Text(formatDmy(_date), style: _txt)),
            Icon(Icons.lock_outline, size: 13.sp, color: AppColors.textLight),
          ]),
        ), icon: 'calendar-1')),
        SizedBox(width: 12.w),
        Expanded(child: _labeled('Collected By', TextField(
          controller: TextEditingController(text: context.read<AuthProvider>().userName ?? ''),
          enabled: false, style: _txt, decoration: _dec('', enabled: false)), icon: 'people')),
        SizedBox(width: 12.w),
        Expanded(flex: 2, child: _labeled('Remarks', TextField(controller: _remarksCtrl, style: _txt, decoration: _dec('Add remarks (optional)')), icon: 'receipt-edit')),
      ]),
    );
  }


  Widget _dateBox(DateTime? value, ValueChanged<DateTime> onPicked, {String hint = AppText.dateHint}) => InkWell(
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
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.border)),
          child: Text(
            value == null ? hint : formatDmy(value),
            style: value == null
                ? AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)
                : AppUI.fieldText(context),
          ),
        ),
      );

  /// Which fee group this receipt is collected under -- and therefore which
  /// bank account it is banked into, and which Paytm merchant an online
  /// payment settles to.
  Widget _fgPicker() {
    final chosen = _feeGroups.firstWhere((g) => g['fg_id'] == _fgId,
        orElse: () => const <String, dynamic>{});
    final bankMissing = chosen.isNotEmpty && chosen['ban_id'] == null;
    final seqMissing = chosen.isNotEmpty &&
        chosen['fg_id'] is int &&
        !_fgWithSequence.contains(chosen['fg_id']);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 7.h),
      color: AppColors.demand.withValues(alpha: 0.06),
      child: Row(children: [
        AppIcon('folder-2', size: 15.sp, color: AppColors.demand),
        SizedBox(width: 8.w),
        Text('FEE GROUP', style: _hStyle),
        SizedBox(width: 12.w),
        // A controlled DropdownButton, not chips: the list grows with every
        // group an institution adds, and `value:` is re-read on every build so
        // what is shown is always the group the receipt will be banked under.
        SizedBox(
          width: 260.w,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.border),
            ),
            child: DropdownButton<int?>(
              value: _fgId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              padding: EdgeInsets.symmetric(vertical: 2.h),
              style: AppUI.fieldText(context),
              items: [
                for (final g in _feeGroups)
                  DropdownMenuItem<int?>(
                    value: g['fg_id'] as int?,
                    child: Text((g['fgdesc']?.toString() ?? '').toUpperCase(),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5.sp, fontWeight: FontWeight.w700)),
                  ),
              ],
              onChanged: _saving ? null : _pickFeeGroup,
            ),
          ),
        ),
        const Spacer(),
        if (seqMissing)
          Tooltip(
            message:
                'No receipt sequence for ${chosen['fgdesc']}. Create one in '
                'Setup → Sequence Master → Receipt Sequence. Until then a '
                'collection into this group is refused — it has no receipt '
                'number of its own.',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.warning_amber_rounded,
                  size: 15.sp, color: AppColors.error),
              SizedBox(width: 5.w),
              Text('No receipt sequence',
                  style: TextStyle(
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: AppColors.error)),
            ]),
          )
        else if (bankMissing)
          Tooltip(
            message:
                'No bank account is mapped to ${chosen['fgdesc']}. Map one in '
                'Setup → Bank Accounts, then Fee Master → Fee Group. Until then '
                'fees in this group cannot be collected.',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.warning_amber_rounded,
                  size: 15.sp, color: AppColors.warning),
              SizedBox(width: 5.w),
              Text('No bank account',
                  style: TextStyle(
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: AppColors.warning)),
            ]),
          ),
      ]),
    );
  }

  /// Switch the receipt's fee group. Lines from the previous group are cleared
  /// rather than carried over -- they would be banked into the new group's
  /// account, which is the quiet mis-settlement this picker exists to stop.
  void _pickFeeGroup(int? fgId) {
    final drops = _lines.where((l) => l.feeId != null && l.fgId != fgId).length;
    setState(() {
      _fgId = fgId;
      if (fgId != null) {
        for (final l in _lines) {
          if (l.feeId != null && l.fgId != fgId) {
            l.feeId = null;
            l.feeType = '';
            l.fgId = null;
            l.amount.text = '';
          }
        }
      }
    });
    if (drops > 0) {
      _snack(
          '$drops fee ${drops == 1 ? 'line' : 'lines'} cleared — they belong to '
          'another fee group, and one receipt is banked into one account.',
          AppColors.warning);
    }
  }

  Widget _feeGrid() {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        _fgPicker(),
        const Divider(height: 1, color: AppColors.divider),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 7.h),
          color: AppColors.tableHeadBg,
          child: Row(children: [
            Expanded(flex: 5, child: Text('FEE TYPE', style: _hStyle)),
            Expanded(flex: 3, child: Text('AMOUNT (₹)', style: _hStyle, textAlign: TextAlign.right)),
            SizedBox(width: 44.w),
          ]),
        ),
        const Divider(height: 1, color: AppColors.divider),
        for (int i = 0; i < _lines.length; i++) _lineRow(i),
        const Divider(height: 1, color: AppColors.divider),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 7.h),
          child: Row(children: [
            ElevatedButton.icon(
              onPressed: _saving ? null : () => setState(() => _lines.add(_MiscLine())),
              icon: const Icon(Icons.add, size: 16),
              label: const Text(AppText.addRow),
            ),
            const Spacer(),
            Text('Total', style: AppUI.muted),
            SizedBox(width: 12.w),
            Text('₹ ${_total.toStringAsFixed(2)}', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w800, color: AppColors.primary)),
          ]),
        ),
      ]),
    );
  }


  TextStyle get _hStyle => AppUI.tableHead;

  Widget _lineRow(int i) {
    final line = _lines[i];
    // Money typed against no fee type. The line cannot be receipted, and
    // before this was flagged it was charged anyway and then dropped on save
    // -- FC26/03251, Rs 3,600 taken for a Rs 150 receipt. Saying so on the
    // field itself, not only on the save, is what makes it obvious which
    // line is wrong.
    final needsType = line.feeType.trim().isEmpty &&
        (double.tryParse(line.amount.text.trim()) ?? 0) > 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 4.h),
      child: Row(children: [
        // Type-to-filter rather than a plain dropdown: there are well over a
        // hundred fee types, so scrolling to "DUPLICATE TRANSFER CERTIFICATE"
        // is slower than typing three letters of it.
        Expanded(flex: 5, child: Autocomplete<Map<String, dynamic>>(
          key: ValueKey('misfee-$i-${line.feeId ?? ''}'),
          initialValue: TextEditingValue(text: line.feeType),
          optionsBuilder: (tev) {
            final q = tev.text.toLowerCase().trim();
            // Only the chosen group's types. With no group chosen yet the
            // whole master is offered and picking one SETS the group, so the
            // quick path (type three letters, done) still works.
            // Only the chosen group's types -- and with no group chosen,
            // only types from groups this counter is allowed to collect.
            final allowed = {for (final g in _feeGroups) g['fg_id']};
            final pool = _fgId == null
                ? _feeTypes.where((f) => allowed.contains(f['fg_id']))
                : _feeTypes.where((f) => f['fg_id'] == _fgId);
            if (q.isEmpty) return pool;
            return pool.where((f) =>
                (f['feedesc']?.toString() ?? '').toLowerCase().contains(q));
          },
          displayStringForOption: (f) => f['feedesc']?.toString() ?? '',
          onSelected: (f) => setState(() {
            line.feeId = f['fee_id'] as int?;
            line.feeType = f['feedesc']?.toString() ?? '';
            line.fgId = f['fg_id'] as int?;
            // First pick decides the receipt's group; the rest of the lines
            // are then held to it.
            _fgId ??= line.fgId;
          }),
          fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
            controller: controller,
            focusNode: focusNode,
            style: _txt,
            decoration: _dec('Search fee type').copyWith(
              prefixIcon: Icon(Icons.search,
                  size: 18.sp,
                  color: needsType ? AppColors.error : AppColors.textLight),
              prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 0),
              errorText: needsType ? 'Select a fee type for this amount' : null,
              errorStyle: TextStyle(fontSize: 10.5.sp, height: 1.1),
              enabledBorder: needsType
                  ? OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                      borderSide: const BorderSide(color: AppColors.error))
                  : null,
            ),
            onSubmitted: (_) => onSubmit(),
            // A selection stays selected only while the text still MATCHES it.
            //
            // Clearing the box already cleared the line. But typing extra
            // characters onto a chosen fee type did not: the field read
            // 'ATTENDANCE INFORMATION eeee' while the line still held
            // 'ATTENDANCE INFORMATION', so the receipt was right and the screen
            // was lying. A cashier cannot be expected to collect money against
            // a field that does not say what it will print.
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
                  children: options.map((f) => InkWell(
                        onTap: () => onSelected(f),
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                          child: Text(f['feedesc']?.toString() ?? '',
                              style: TextStyle(fontSize: 13.sp)),
                        ),
                      )).toList(),
                ),
              ),
            ),
          ),
        )),
        SizedBox(width: 12.w),
        Expanded(flex: 3, child: TextField(
          controller: line.amount, style: _txt, textAlign: TextAlign.right, keyboardType: TextInputType.number,
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
            onPressed: _lines.length == 1 ? null : () => setState(() { _lines[i].amount.dispose(); _lines.removeAt(i); }),
            icon: Icon(Icons.remove_circle_outline, size: 20, color: _lines.length == 1 ? AppColors.textLight : AppColors.error),
            tooltip: AppText.deleteRow,
            padding: EdgeInsets.zero,
          ),
        ),
      ]),
    );
  }

  /// Bottom bar: how many fee lines are ready, then the amount, the mode and
  /// the save button — the same triple as Advance / Fee Collection.
  Widget _footer() {
    final count = _lines
        .where((l) => l.feeType.trim().isNotEmpty && (double.tryParse(l.amount.text.trim()) ?? 0) > 0)
        .length;
    // A leaver cannot be paid for at all, whatever else is filled in.
    final ready = !_saving && _paymode != null && !_studentHasTc;
    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 10.h),
      child: Row(children: [
        Icon(Icons.info_outline, size: 15.sp, color: AppColors.textLight),
        SizedBox(width: 7.w),
        Text('$count fee ${count == 1 ? 'type' : 'types'}', style: AppUI.label),
        SizedBox(width: 16.w),
        AppUI.requiredNote(),
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
            const AppIcon('tag', size: 15, color: AppColors.accent),
            SizedBox(width: 8.w),
            Text('Net Amount: ',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.3)),
            Text('₹${_total.toStringAsFixed(0)}',
                style: TextStyle(
                    fontSize: 14.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
          ]),
        ),
        SizedBox(width: 12.w),
        Container(
          width: 190.w,
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
              hint: Text('Select payment mode',
                  overflow: TextOverflow.ellipsis,
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
              items: const [
                DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                DropdownMenuItem(value: 'QR/UPI', child: Text('QR/UPI')),
                DropdownMenuItem(value: 'Paytm', child: Text('Paytm')),
                DropdownMenuItem(value: 'Cheque', child: Text('Cheque')),
                DropdownMenuItem(value: 'DD', child: Text('DD')),
              ],
              onChanged: (v) => setState(() => _paymode = v),
            ),
          ),
        ),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
            onPressed: ready ? _onSaveAndPrint : null,
            icon: _saving
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textLight))
                : Icon(_paymode == 'Paytm' ? Icons.open_in_new : Icons.send, size: 16.sp),
            label: Text(_saving
                ? 'Saving…'
                : (_paymode == 'Cash' ? 'Save Receipt' : 'Proceed to Pay')),
        ),
      ]),
    );
  }

}
