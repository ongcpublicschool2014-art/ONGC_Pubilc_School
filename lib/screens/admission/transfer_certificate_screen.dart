import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/app_text.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/form_section_panel.dart';
import '../../widgets/pill_tab.dart';
import '../../widgets/student_avatar.dart';
import '../../widgets/app_dropdown_field.dart';

/// Transfer Certificate module (Admission → Transfer Certificate).
/// Two tabs — Individual (one student) and Whole Class (bulk). Issuing a TC sets
/// the student's leaving status (1 active, 2 discontinued, 3 transferred,
/// 4 completed, 5 others, 9 terminated) on both the schema student and the
/// public admission record via the save_tc_entry RPC.
class TransferCertificateScreen extends StatefulWidget {
  const TransferCertificateScreen({super.key});

  @override
  State<TransferCertificateScreen> createState() => _TransferCertificateScreenState();
}

const List<(int, String)> kTcStatuses = [
  (1, 'Active'),
  (2, 'Discontinued'),
  (3, 'Transferred'),
  (4, 'Completed'),
  (5, 'Others'),
  (9, 'Terminated'),
];

String _statusLabel(int code) =>
    kTcStatuses.firstWhere((s) => s.$1 == code, orElse: () => (code, '—')).$2;

String? _ymd(DateTime? d) =>
    d == null ? null : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 'yyyy-MM-dd...' (or null) -> DateTime.
DateTime? _parseDate(dynamic v) {
  final s = (v ?? '').toString();
  if (s.length < 10) return null;
  return DateTime.tryParse(s.substring(0, 10));
}

String _fmt(dynamic v) {
  if (v == null) return '';
  final s = v.toString();
  if (s.length >= 10 && s[4] == '-') {
    // ISO yyyy-MM-dd... → dd-MM-yyyy
    return '${s.substring(8, 10)}-${s.substring(5, 7)}-${s.substring(0, 4)}';
  }
  return s;
}

class _TransferCertificateScreenState extends State<TransferCertificateScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: _tabLabels.length, vsync: this);

  static const _tabLabels = ['Individual', 'Whole Class'];
  static const _tabIcons = ['user', 'people'];

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  bool _loading = true;
  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _classes = [];
  List<Map<String, dynamic>> _courses = [];
  List<Map<String, dynamic>> _sequences = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _indAdmno.dispose();
    _indTcNo.dispose();
    _indDocNo.dispose();
    _indRemarks.dispose();
    _wcSearch.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final insId = _insId;
      // All five at once. None depends on another, and awaiting them in turn
      // made opening this screen cost the SUM of the round trips -- the students
      // scan alone pages 1000 rows at a time, and it is unfiltered by status.
      //
      // The last two keep their own try/catch INSIDE the future, so a missing
      // sequence or tc_entry table still degrades to an empty list rather than
      // failing the whole load -- exactly as it did when they ran in sequence.
      //
      // fetchAll, not a plain select: PostgREST caps a response at 1000 rows and
      // silently truncates, which would drop whole classes from the list.
      final res = await Future.wait<dynamic>([
        SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select('stu_id, stuadmno, stuname, stugender, stuclass, studob, stuadmdate, cla_id, activestatus, stuphoto')
            .eq('ins_id', insId)
            // This screen deliberately does NOT filter activestatus -- it has to
            // list students who already hold a TC. That is why the pre-admission
            // exclusion has to be spelled out here: a student admitted for next
            // year has not started, so there is nothing to transfer them out of.
            .eq('preadmission', 0)),
        SupabaseService.fromSchema('class')
            .select('cla_id, claname, cour_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.fromSchema('course')
            .select('cour_id, courname')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        // TC-only doc-number sequences (actname='TCNO' -- separate from the
        // fee / register sequences). Tolerate a legacy sequence table shape.
        Future<List<Map<String, dynamic>>>(() async {
          try {
            final s = await SupabaseService.fromSchema('sequence')
                .select('seq_id, actname, seqname, isprefix, seqprefix, seqstart, seqcurno, seqwidth')
                .eq('ins_id', insId)
                .eq('activestatus', 1)
                .eq('actname', 'TCNO');
            return (s as List).map((e) => Map<String, dynamic>.from(e)).toList();
          } catch (_) {
            return <Map<String, dynamic>>[]; // no sequence table / other shape
          }
        }),
        Future<List<Map<String, dynamic>>>(() async {
          try {
            return await SupabaseService.fetchAll(() => SupabaseService
                .fromSchema('tc_entry')
                .select('tc_id, stuadmno, tcno, tcdate, effectfrom, status, docno')
                .eq('ins_id', insId)
                .eq('activestatus', 1));
          } catch (_) {
            return <Map<String, dynamic>>[]; // not created yet -- empty boxes
          }
        }),
      ]);
      final students = List<Map<String, dynamic>>.from(res[0] as List);
      final classes = res[1];
      final courses = res[2];
      final seqs = List<Map<String, dynamic>>.from(res[3] as List);
      // tc_entry is append-only history, and students.activestatus drives the
      // form -- but a student who already HAS a TC should show the number that
      // was issued rather than an empty box, so keep the latest row per student.
      //
      // Ascending tc_id, so the last write for a student wins -- but only rows
      // that actually carry a TC number count. tc_entry is append-only, so
      // re-activating a student appends a row with no tcno; letting that win
      // would hide the number that was issued.
      final lastTc = <String, Map<String, dynamic>>{};
      final latest = <String, Map<String, dynamic>>{};
      final tcRows = List<Map<String, dynamic>>.from(res[4] as List)
        ..sort((a, b) => ((a['tc_id'] as num?) ?? 0).compareTo((b['tc_id'] as num?) ?? 0));
      for (final r in tcRows) {
        final k = r['stuadmno']?.toString() ?? '';
        if (k.isEmpty) continue;
        latest[k] = Map<String, dynamic>.from(r);
        if ((r['tcno'] ?? '').toString().trim().isEmpty) continue;
        lastTc[k] = Map<String, dynamic>.from(r);
      }
      if (!mounted) return;
      setState(() {
        _students = students.map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => (a['stuname'] ?? '').toString().compareTo((b['stuname'] ?? '').toString()));
        _classes = (classes as List).map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => classCompare(
              (a['claname'] ?? '').toString(), (b['claname'] ?? '').toString()));
        _courses = (courses as List).map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => (a['courname'] ?? '').toString().compareTo((b['courname'] ?? '').toString()));
        _sequences = seqs;
        _lastTc
          ..clear()
          ..addAll(lastTc);
        _latestTc
          ..clear()
          ..addAll(latest);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load the students and TC details. ${friendlyError(e)}', AppColors.error);
    }
  }

  void _snack(String msg, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: c));
  }

  // ---------------------------------------------------------------- Individual
  final _indAdmno = TextEditingController();
  final _indTcNo = TextEditingController();
  final _indDocNo = TextEditingController();
  final _indRemarks = TextEditingController();
  Map<String, dynamic>? _indStudent;
  String? _indCourse; // filter
  String? _indClass;  // filter
  int _indStatus = 1;

  // Classes for the Individual filter — all, or the selected course's classes.
  List<Map<String, dynamic>> get _indClassOptions {
    if (_indCourse == null) return _classes;
    final cour = _courses.firstWhere((c) => c['courname'].toString() == _indCourse, orElse: () => const {});
    final id = cour['cour_id'];
    if (id == null) return _classes;
    return _classes.where((cl) => cl['cour_id'] == id).toList();
  }

  // Students narrowed by the Course/Class filter (by class name, robust to null ids).
  List<Map<String, dynamic>> _indFilteredStudents() {
    Iterable<Map<String, dynamic>> list = _students;
    if (_indClass != null) {
      list = list.where((s) => (s['stuclass'] ?? '').toString() == _indClass);
    } else if (_indCourse != null) {
      final names = _indClassOptions.map((c) => c['claname'].toString()).toSet();
      list = list.where((s) => names.contains((s['stuclass'] ?? '').toString()));
    }
    return list.toList();
  }
  DateTime? _indTcDate;
  DateTime? _indEffectFrom;
  DateTime? _indDocDate = DateTime.now(); // defaults to today
  int? _indSeqId;
  int? _indEditingTcId;
  bool _indSaving = false;

  String _seqLabel(Map s) => (s['seqname']?.toString().trim().isNotEmpty ?? false)
      ? s['seqname'].toString()
      : ((s['actname']?.toString().trim().isNotEmpty ?? false) ? s['actname'].toString() : 'SEQ');
  // Same numbering convention as register sequences: seqcurno starts at 0, so the
  // first number is seqstart, then cur+1 thereafter.
  int _nextSeqNum(Map s) {
    final cur = (s['seqcurno'] as num?)?.toInt() ?? 0;
    final start = (s['seqstart'] as num?)?.toInt() ?? 1;
    return cur < start ? start : cur + 1;
  }
  /// Formats an explicit counter value, so a batch can number ahead of the
  /// stored seqcurno before writing it back once.
  String _seqNoFor(Map s, int n) {
    final width = (s['seqwidth'] as num?)?.toInt() ?? 0;
    final padded = n.toString().padLeft(width, '0');
    final affix = s['seqprefix']?.toString() ?? '';
    return (s['isprefix']?.toString() ?? 'Y') == 'Y' ? '$affix$padded' : '$padded$affix';
  }

  String _nextSeqNo(Map s) => _seqNoFor(s, _nextSeqNum(s));

  /// Is the Individual tab's Doc No the one its register would give next
  /// (not typed over by hand)?
  bool _indDocNoFromSeq() {
    final seq = _sequences.firstWhere((e) => (e['seq_id'] as num).toInt() == _indSeqId, orElse: () => const {});
    return seq.isNotEmpty && _indDocNo.text.trim() == _nextSeqNo(seq);
  }

  void _indPick(Map<String, dynamic>? s) {
    setState(() {
      _indStudent = s;
      // Append-only: every save creates a NEW tc_entry row (audit trail), so we
      // never edit an existing one (Doc No / sequence are left as-is). But if
      // this student already HAS a TC, show its number and dates rather than a
      // blank form — otherwise there's no way to see what was issued.
      _indEditingTcId = null;
      _indStatus = (s?['activestatus'] as num?)?.toInt() ?? 1;
      _indRemarks.clear();
      // Only a student who has LEFT carries a current TC. Once re-activated the
      // form goes blank again, even though the history row survives.
      // A TC saved but not yet approved and printed: open THAT entry, so
      // saving updates it instead of issuing a second TC.
      final pending = _pendingTc(s);
      if (pending != null) {
        _indStatus = (pending['status'] as num?)?.toInt() ?? _indStatus;
        _indEditingTcId = (pending['tc_id'] as num?)?.toInt();
        _indDocNo.text = (pending['docno'] ?? '').toString();
      }
      final prev = pending ??
          ((s == null || _indStatus == 1) ? null : _lastTc[s['stuadmno']?.toString() ?? '']);
      _indTcNo.text = (prev?['tcno'] ?? '').toString();
      _indTcDate = _parseDate(prev?['tcdate']);
      _indEffectFrom = _parseDate(prev?['effectfrom']);
    });
    final pending = _pendingTc(s);
    if (pending != null) {
      _snack('This student already has a TC waiting for approval / printing (TC No ${pending['tcno'] ?? '-'}). '
          'Saving now updates that TC.', AppColors.warning);
    }
  }

  void _indNew() {
    setState(() {
      _indStudent = null;
      _indAdmno.clear();
      _indTcNo.clear();
      _indDocNo.clear();
      _indRemarks.clear();
      _indStatus = 1;
      _indTcDate = null;
      _indEffectFrom = null;
      _indDocDate = DateTime.now(); // default to today
      _indSeqId = null;
      _indEditingTcId = null;
    });
  }

  Future<void> _indSave() async {
    final s = _indStudent;
    if (s == null) {
      _snack('Select a student first.', AppColors.error);
      return;
    }
    // TC entry requires a TC sequence (created in Admission Master → TC Sequence).
    if (_sequences.isEmpty) {
      _snack('No TC sequence found. Create one in Admission Master → TC Sequence.', AppColors.error);
      return;
    }
    if (_indSeqId == null) {
      _snack('Select a TC sequence first.', AppColors.error);
      return;
    }
    if (_indDocDate == null) { _snack('Select the document date.', AppColors.error); return; }
    // TC Date / Effect From are required when actually issuing a TC (a leaving
    // status); re-activating (Active) needs neither.
    if (_indStatus != 1) {
      if (_indTcDate == null) { _snack('Select the TC date.', AppColors.error); return; }
      if (_indEffectFrom == null) { _snack('Select the effective date.', AppColors.error); return; }
    }
    // TC Date must be on/after the student's Join Date (admission date).
    final join = s['stuadmdate'] == null ? null : DateTime.tryParse(s['stuadmdate'].toString());
    if (_indTcDate != null && join != null && _indTcDate!.isBefore(join)) {
      _snack('The TC date cannot be before the date of admission (${_fmt(s['stuadmdate'])}). Select a later TC date.', AppColors.error);
      return;
    }
    // Warn about outstanding fees before issuing a TC (a leaving status).
    if (_indStatus != 1) {
      final pending = await _pendingFees(s['stuadmno'].toString());
      if (!mounted) return;
      if (pending == null || pending > 0.005) {
        final ok = await _confirmPending(pending);
        if (ok != true) return;
      }
    }
    setState(() => _indSaving = true);
    try {
      final auth = context.read<AuthProvider>();
      await SupabaseService.saveTcEntry({
        'stuadmno': s['stuadmno'],
        'stuname': s['stuname'],
        'stuclass': s['stuclass'],
        'cla_id': s['cla_id'],
        'stu_id': s['stu_id'],
        'birthdate': s['studob'],
        'joindate': s['stuadmdate'],
        'status': _indStatus,
        'tcno': _indTcNo.text.trim(),
        'tcdate': _ymd(_indTcDate),
        'effectfrom': _ymd(_indEffectFrom),
        'docno': _indDocNo.text.trim(),
        'docdate': _ymd(_indDocDate),
        'remarks': _indRemarks.text.trim(),
        'createdby': auth.userName,
        // Doc No still the register's next number: the server claims it under
        // a lock (it moves the counter; two clerks no longer get the same one).
        if (_indSeqId != null && _indEditingTcId == null && _indDocNoFromSeq()) 'seq_id': _indSeqId,
      }, tcId: _indEditingTcId);
      _snack(
          _indStatus == 1
              ? 'Student re-activated. Status changed to ${_statusLabel(_indStatus)}.'
              : 'Transfer certificate saved. The student becomes ${_statusLabel(_indStatus)} once the certificate is approved in TC Approval and printed.',
          AppColors.success);
      await _load();
      _indNew();
    } catch (e) {
      _snack('Could not save the transfer certificate. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _indSaving = false);
    }
  }

  // Sum of outstanding fee balances for a student (by admission no). Null when
  // it could not be read -- that used to come back as 0, so the warning
  // silently never showed.
  Future<double?> _pendingFees(String admno) async {
    try {
      final res = await SupabaseService.fromSchema('feedemand')
          .select('balancedue')
          .eq('ins_id', _insId)
          .eq('stuadmno', admno)
          .eq('activestatus', 1);
      double sum = 0;
      for (final r in (res as List)) {
        final b = (r['balancedue'] as num?)?.toDouble() ?? 0;
        if (b > 0) sum += b;
      }
      return sum;
    } catch (_) {
      return null;
    }
  }

  Future<bool?> _confirmPending(double? amount) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(amount == null ? 'Fees Not Checked' : 'Pending Fees'),
          content: Text(amount == null
              ? 'The pending fees could not be checked just now.\n\nDo you want to issue the transfer certificate anyway?'
              : 'This student has pending fees of ₹${amount.toStringAsFixed(2)}.\n\nDo you want to issue the transfer certificate anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );

  // --------------------------------------------------------------- Whole Class
  String? _wcCourse;
  String? _wcClass;
  final Map<String, _WcRow> _wcRows = {}; // by stuadmno
  bool _wcSaving = false;
  final Set<String> _wcSelected = {}; // selected stuadmnos
  /// Latest tc_entry per student (stuadmno -> row). Lets an already-issued TC
  /// show its number/date instead of a blank, editable cell.
  final Map<String, Map<String, dynamic>> _lastTc = {};
  /// The very latest tc_entry per student, re-activation rows included.
  final Map<String, Map<String, dynamic>> _latestTc = {};

  /// A TC saved but not yet in force: the student stays active until the
  /// approved certificate is printed, so without this they looked like any
  /// active student -- and a second TC could be issued over the first.
  Map<String, dynamic>? _pendingTc(Map<String, dynamic>? s) {
    if (s == null || ((s['activestatus'] as num?)?.toInt() ?? 1) != 1) return null;
    final last = _latestTc[s['stuadmno']?.toString() ?? ''];
    if (last == null || ((last['status'] as num?)?.toInt() ?? 1) == 1) return null;
    return last;
  }

  final _wcSearch = TextEditingController();
  int _wcPage = 0;
  static const int _wcPageSize = 10;
  int? _wcBulkStatus; // Bulk Action target status applied to selected rows

  // Whole-class students after the search box, and the current page slice.
  List<Map<String, dynamic>> get _wcFiltered {
    final q = _wcSearch.text.toLowerCase().trim();
    if (q.isEmpty) return _wcStudents;
    return _wcStudents.where((s) => '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q)).toList();
  }
  List<Map<String, dynamic>> get _wcPaged {
    final all = _wcFiltered;
    final start = _wcPage * _wcPageSize;
    if (start >= all.length) return const [];
    return all.sublist(start, (start + _wcPageSize).clamp(0, all.length));
  }

  // Classes to offer in the Whole-Class dropdown — all, or only those of the
  // selected course (matched via class.cour_id).
  List<Map<String, dynamic>> get _wcClassOptions {
    if (_wcCourse == null) return _classes;
    final cour = _courses.firstWhere((c) => c['courname'].toString() == _wcCourse, orElse: () => const {});
    final courId = cour['cour_id'];
    if (courId == null) return _classes;
    return _classes.where((cl) => cl['cour_id'] == courId).toList();
  }

  void _wcSelectCourse(String? c) {
    setState(() {
      _wcCourse = c;
      _wcClass = null;
      _wcRows.clear();
      _wcSelected.clear();
      _wcPage = 0;
    });
  }

  List<Map<String, dynamic>> get _wcStudents =>
      _wcClass == null ? [] : _students.where((s) => (s['stuclass'] ?? '') == _wcClass).toList();

  void _wcSelectClass(String? c) {
    setState(() {
      _wcClass = c;
      _wcPage = 0;
      _wcSelected.clear();
      _wcRows.clear();
      for (final s in _wcStudents) {
        _wcRows[s['stuadmno'].toString()] = _WcRow(
            tcNo: TextEditingController(),
            remarks: TextEditingController(),
            tcDate: DateTime.now());
      }
    });
  }

  // Generate TC for the checkbox-selected students, applying the Bulk-Action
  // status + each row's TC No / Date / Remarks. Append-only (one row per save).
  /// The TC number and date a whole-class row will be SAVED with.
  ///
  /// A student who already holds a TC keeps the one they were issued -- their
  /// cells are read-only in the grid, so there is nothing to re-type and the
  /// mandatory check is already satisfied.
  ({String no, DateTime? date}) _wcTcFor(Map<String, dynamic> s) {
    final admno = s['stuadmno'].toString();
    final isActive = ((s['activestatus'] as num?)?.toInt() ?? 1) == 1;
    final issued = isActive ? _pendingTc(s) : _lastTc[admno];
    final issuedNo = (issued?['tcno'] ?? '').toString().trim();
    if (issuedNo.isNotEmpty) {
      return (no: issuedNo, date: _parseDate(issued?['tcdate']));
    }
    final row = _wcRows[admno];
    return (no: row?.tcNo.text.trim() ?? '', date: row?.tcDate);
  }

  Future<void> _wcGenerate() async {
    if (_wcSelected.isEmpty) { _snack('Select at least one student.', AppColors.error); return; }
    if (_wcBulkStatus == null) { _snack('Select a status in Bulk Action.', AppColors.error); return; }
    // Setting the class back to Active CANCELS the TCs -- no certificate is
    // issued, so no number, no date and no sequence are needed.
    final isActivate = _wcBulkStatus == 1;
    // TC No and TC Date are mandatory on every selected student. Checked before
    // the fee lookup below so a missing number costs no round trips.
    if (!isActivate) {
      final missing = <String>[];
      for (final s in _wcStudents.where((s) => _wcSelected.contains(s['stuadmno'].toString()))) {
        final tc = _wcTcFor(s);
        if (tc.no.isEmpty || tc.date == null) missing.add(s['stuadmno'].toString());
      }
      if (missing.isNotEmpty) {
        final more = missing.length - 3;
        _snack(
            '${schoolTerm('Enter the TC No. and TC date for register no. ')}'
            '${missing.take(3).join(', ')}${more > 0 ? ' and $more more' : ''}.',
            AppColors.error);
        return;
      }
    }
    // Warn about total outstanding fees across the selected students.
    double? pending = 0;
    for (final admno in _wcSelected) {
      final p = await _pendingFees(admno);
      pending = (p == null || pending == null) ? null : pending + p;
    }
    if (!mounted) return;
    if (pending == null || pending > 0.005) {
      final ok = await _confirmPending(pending);
      if (ok != true) return;
    }
    // Re-activating consumes no sequence number, so it needs no sequence.
    if (!isActivate && _sequences.isEmpty) {
      _snack('Create a TC sequence in Admission Master → TC Sequence first.', AppColors.error);
      return;
    }
    setState(() => _wcSaving = true);
    final auth = context.read<AuthProvider>();
    int saved = 0;
    // Doc numbers come from the TC register, one per student, claimed by the
    // server for each save (no client-side counter to race).
    final Map<String, dynamic>? seq = isActivate || _sequences.isEmpty ? null : _sequences.first;
    final today = _ymd(DateTime.now());
    try {
      for (final s in _wcStudents.where((s) => _wcSelected.contains(s['stuadmno'].toString()))) {
        final admno = s['stuadmno'].toString();
        final row = _wcRows[admno]!;
        final tc = _wcTcFor(s);
        // A TC already waiting for approval is updated, not issued twice.
        final pendingId = (_pendingTc(s)?['tc_id'] as num?)?.toInt();
        await SupabaseService.saveTcEntry({
          'stuadmno': admno,
          'stuname': s['stuname'],
          'stuclass': s['stuclass'],
          'cla_id': s['cla_id'],
          'stu_id': s['stu_id'],
          'birthdate': s['studob'],
          'joindate': s['stuadmdate'],
          'status': _wcBulkStatus,
          'tcno': isActivate ? '' : tc.no,
          'tcdate': isActivate ? null : _ymd(tc.date),
          // Effect From is not asked for here: a whole class leaves on the date
          // its TC carries, so it follows the TC date rather than costing the
          // user a second picker on every row. The Individual tab still asks.
          'effectfrom': isActivate ? null : _ymd(tc.date),
          'docno': pendingId == null ? '' : (_pendingTc(s)?['docno'] ?? '').toString(),
          'docdate': isActivate ? null : today,
          'remarks': row.remarks.text.trim(),
          'createdby': auth.userName,
          if (seq != null && pendingId == null) 'seq_id': (seq['seq_id'] as num).toInt(),
        }, tcId: isActivate ? null : pendingId);
        saved++;
      }
      _snack(
          isActivate
              ? 'Re-activated $saved student(s). Their TCs are cancelled.'
              : 'TC issued for $saved student(s). They become ${_statusLabel(_wcBulkStatus!)} once their certificates are approved in TC Approval and printed.',
          AppColors.success);
      await _load();
      _wcSelectClass(_wcClass);
    } catch (e) {
      _snack('Could not issue the TCs. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _wcSaving = false);
    }
  }

  // -------------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 0),
          child: AppUI.cardHeader(icon: 'document-text', title: 'Transfer Certificate Entry'),
        ),
        // Pill tabs — same convention as Master Data / Admission Master.
        ListenableBuilder(
          listenable: _tabs,
          builder: (context, _) {
            final selected = _tabs.index;
            return Padding(
              padding: EdgeInsets.fromLTRB(16.w, 8, 16.w, 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (var i = 0; i < _tabLabels.length; i++) ...[
                    PillTab(
                      icon: _tabIcons[i],
                      label: schoolTerm(_tabLabels[i]),
                      selected: selected == i,
                      onTap: () => _tabs.animateTo(i),
                    ),
                    if (i < _tabLabels.length - 1) SizedBox(width: PillTab.gap(context)),
                  ],
                ]),
              ),
            );
          },
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(controller: _tabs, children: [_individualTab(), _wholeClassTab()]),
        ),
      ],
    );
  }

  // ---- Individual tab
  Widget _individualTab() {
    final s = _indStudent;
    return SingleChildScrollView(
      padding: EdgeInsets.all(16.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _twoUpPanels(
            left: _sectionCard('Student Details', 'user', [
            _rowFields([
              _labeled('TC Sequence *', AppDropdownField<int>(
                key: ValueKey('tcseq-${_indSeqId ?? 0}'),
                initialValue: _indSeqId,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: _indSeqId != null),
                decoration: _dec(_sequences.isEmpty ? 'No TC sequence yet. Add one in Admission Master' : 'Select TC sequence'),
                items: _sequences.map((e) => DropdownMenuItem(value: (e['seq_id'] as num).toInt(), child: Text(_seqLabel(e), overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (v) => setState(() {
                  _indSeqId = v;
                  final seq = _sequences.firstWhere((e) => (e['seq_id'] as num).toInt() == v, orElse: () => const {});
                  if (seq.isNotEmpty) _indDocNo.text = _nextSeqNo(seq);
                }),
              ), icon: 'receipt-2'),
              // Read-only: the document number comes from the chosen TC sequence
              // and is what the next save consumes, so a hand-typed value would
              // drift from the sequence counter.
              _labeled('Document No.', TextField(
                controller: _indDocNo,
                readOnly: true,
                style: AppUI.fieldText(context).copyWith(color: AppColors.textSecondary),
                decoration: _dec(AppText.generated).copyWith(
                  fillColor: AppColors.tableHeadBg,
                ),
              ), icon: 'receipt-2'),
              _labeled('Document Date *', _dateField(_indDocDate, (d) => setState(() => _indDocDate = d), hint: 'Select document date'), icon: 'calendar-1'),
            ]),
            _rowFields([
              _labeled(schoolTerm('Course'), AppDropdownField<String>(
                key: ValueKey('tccourse-${_indCourse ?? ''}'),
                initialValue: _indCourse,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: _indCourse != null),
                decoration: _dec(schoolTerm('Select course (optional)')),
                items: [DropdownMenuItem<String>(value: null, child: Text(schoolTerm('Select course (optional)'))), ..._courses.map((e) => DropdownMenuItem(value: e['courname'].toString(), child: Text(e['courname'].toString(), overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() { _indCourse = v; _indClass = null; _indStudent = null; }),
              ), icon: 'ranking'),
              _labeled(schoolTerm('Class'), AppDropdownField<String>(
                key: ValueKey('tcfclass-${_indClass ?? ''}-${_indCourse ?? ''}'),
                initialValue: _indClass,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: _indClass != null),
                decoration: _dec(schoolTerm('Select class (optional)')),
                items: [DropdownMenuItem<String>(value: null, child: Text(schoolTerm('Select class (optional)'))), ..._indClassOptions.map((e) => DropdownMenuItem(value: e['claname'].toString(), child: Text(e['claname'].toString(), overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() { _indClass = v; _indStudent = null; }),
              ), icon: 'grid-1'),
              _labeled(schoolTerm('Register No. *'), _admnoAutocomplete(s), icon: 'user-add'),
            ]),
            _rowFields([
              _labeled(
                'Student Name',
                s == null
                    ? _readonly('')
                    : Row(children: [
                        StudentAvatar(photoUrl: s['stuphoto']?.toString(), name: s['stuname']?.toString() ?? '', size: 44),
                        SizedBox(width: 10.w),
                        Expanded(child: _readonly(s['stuname']?.toString() ?? '')),
                      ]),
                icon: 'people',
              ),
              _labeled('Gender', _readonly(_genderLabel(s?['stugender'])), icon: 'user-tick'),
              _labeled('Date of Birth', _readonly(_fmt(s?['studob'])), icon: 'calendar-1'),
              _labeled(AppText.dateOfAdmission, _readonly(_fmt(s?['stuadmdate'])), icon: 'calendar-1'),
            ]),
          ]),
            right: _sectionCard('Transfer Certificate Details', 'document-text', [
            _rowFields([
              _labeled('Status *', AppDropdownField<int>(
                key: ValueKey('tcstatus-$_indStatus'),
                initialValue: _indStatus,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: true),
                decoration: _dec('Status'),
                items: kTcStatuses.map((e) => DropdownMenuItem(value: e.$1, child: Text(e.$2))).toList(),
                onChanged: (v) => setState(() {
                  _indStatus = v ?? 1;
                  // Re-activating cancels the TC: a TC number, its date and the
                  // effect date describe a student who has LEFT, so carrying
                  // them onto an Active record would be contradictory.
                  if (_indStatus == 1) {
                    _indTcNo.clear();
                    _indTcDate = null;
                    _indEffectFrom = null;
                  }
                }),
              ), icon: 'user-tick'),
              _labeled('TC No.', TextField(controller: _indTcNo, style: AppUI.fieldText(context), decoration: _dec('Enter TC number'))),
            ]),
            _rowFields([
              _labeled('TC Date *', _dateField(_indTcDate, (d) => setState(() => _indTcDate = d), hint: 'Select TC date')),
              _labeled('Effective From *', _dateField(_indEffectFrom, (d) => setState(() => _indEffectFrom = d), hint: 'Select effective date')),
            ]),
            _labeled('Remarks', TextField(
              controller: _indRemarks,
              maxLines: 3,
              maxLength: 500,
              style: AppUI.fieldText(context),
              decoration: _dec('Add remarks (optional)'),
            )),
          ]),
          ),
          SizedBox(height: AppUI.gap),
          Row(children: [
            AppUI.requiredNote(),
            const Spacer(),
            OutlinedButton(onPressed: _indSaving ? null : _indReset, child: const Text(AppText.clear)),
            SizedBox(width: 10.w),
            ElevatedButton.icon(
              onPressed: _indSaving ? null : _indSave,
              icon: _indSaving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save, size: 16),
              label: const Text(AppText.save),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _admnoAutocomplete(Map<String, dynamic>? s) => Autocomplete<Map<String, dynamic>>(
        key: ValueKey('tcac-${_indCourse ?? ''}-${_indClass ?? ''}-${s?['stuadmno'] ?? ''}'),
        initialValue: TextEditingValue(text: s == null ? '' : '${s['stuadmno']}  •  ${s['stuname']}'),
        optionsBuilder: (tev) {
          final q = tev.text.toLowerCase().trim();
          final base = _indFilteredStudents();
          final f = q.isEmpty ? base : base.where((e) => '${e['stuadmno']} ${e['stuname']}'.toLowerCase().contains(q));
          return f.take(50);
        },
        displayStringForOption: (e) => '${e['stuadmno']}  •  ${e['stuname']}',
        onSelected: (e) => _indPick(e),
        fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
          controller: controller,
          focusNode: focusNode,
          style: AppUI.fieldText(context),
          decoration: _dec(schoolTerm('Search by register no. or name')).copyWith(prefixIcon: Icon(Icons.search, size: 18.sp, color: AppColors.textSecondary)),
          onSubmitted: (_) => onSubmit(),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 260.h, maxWidth: 520.w),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: options.map((e) => InkWell(
                  onTap: () => onSelected(e),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                    child: Text('${e['stuadmno']}  •  ${e['stuname']}', style: AppUI.body),
                  ),
                )).toList(),
              ),
            ),
          ),
        ),
      );

  // Titled section card (mockup): header strip (icon + title) + body.
  /// Shared with Student Transfer via [FormSectionPanel] -- the two screens
  /// used to draw their own panels and looked subtly different for no reason.
  Widget _sectionCard(String title, String icon, List<Widget> children) =>
      FormSectionPanel(
        title: title,
        icon: icon,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      );

  String _genderLabel(dynamic g) {
    switch (g?.toString().toUpperCase()) {
      case 'M': return kBoyLabel;
      case 'F': return kGirlLabel;
      case 'T': return 'Other';
      default: return '';
    }
  }

  // Reset the TC-detail fields but keep the selected student + sequence.
  void _indReset() {
    setState(() {
      _indStatus = (_indStudent?['activestatus'] as num?)?.toInt() ?? 1;
      _indTcNo.clear();
      _indRemarks.clear();
      _indTcDate = null;
      _indEffectFrom = null;
    });
  }

  // ---- Whole Class tab
  Widget _wholeClassTab() {
    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bulk Action (target status) + Generate TC (Selected) + refresh.
          Row(children: [
            SizedBox(
              width: 280.w,
              child: AppDropdownField<int>(
                key: ValueKey('wcbulk-${_wcBulkStatus ?? 0}'),
                initialValue: _wcBulkStatus,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: _wcBulkStatus != null),
                decoration: _dec('Select status for the ticked students'),
                items: kTcStatuses.map((e) => DropdownMenuItem(value: e.$1, child: Text(e.$2))).toList(),
                onChanged: (v) => setState(() => _wcBulkStatus = v),
              ),
            ),
            const Spacer(),
            AppUI.requiredNote(),
            SizedBox(width: 12.w),
            ElevatedButton.icon(
              onPressed: (_wcSaving || _wcSelected.isEmpty) ? null : _wcGenerate,
              icon: _wcSaving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.description_outlined, size: 16),
              // The button says what it will actually do — with Active picked it
              // cancels TCs rather than generating them.
              label: Text(_wcBulkStatus == 1
                  ? 'Re-activate (${_wcSelected.length})'
                  : 'Issue TC (${_wcSelected.length})'),
            ),
            SizedBox(width: 8.w),
            IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: Icon(Icons.refresh, size: 20.sp, color: AppColors.textSecondary)),
          ]),
          SizedBox(height: 12.h),
          // Course + Class filters + search.
          Row(children: [
            SizedBox(width: 220.w, child: AppDropdownField<String>(
              key: ValueKey('wccourse-${_wcCourse ?? ''}'),
              initialValue: _wcCourse,
              isExpanded: true,
              style: AppUI.fieldText(context, filled: _wcCourse != null),
              decoration: _dec(schoolTerm('All courses')),
              items: [DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All courses'))), ..._courses.map((e) => DropdownMenuItem(value: e['courname'].toString(), child: Text(e['courname'].toString(), overflow: TextOverflow.ellipsis)))],
              onChanged: _wcSelectCourse,
            )),
            SizedBox(width: 12.w),
            SizedBox(width: 220.w, child: AppDropdownField<String>(
              key: ValueKey('wcclass-${_wcClass ?? ''}-${_wcCourse ?? ''}'),
              initialValue: _wcClass,
              isExpanded: true,
              style: AppUI.fieldText(context, filled: _wcClass != null),
              decoration: _dec(schoolTerm('Select class')),
              items: _wcClassOptions.map((e) => DropdownMenuItem(value: e['claname'].toString(), child: Text(e['claname'].toString(), overflow: TextOverflow.ellipsis))).toList(),
              onChanged: _wcSelectClass,
            )),
            const Spacer(),
            SizedBox(width: 260.w, child: TextField(
              controller: _wcSearch,
              style: AppUI.fieldText(context),
              decoration: _dec(schoolTerm('Search by register no. or name')).copyWith(prefixIcon: Icon(Icons.search, size: 18.sp, color: AppColors.textSecondary)),
              onChanged: (_) => setState(() => _wcPage = 0),
            )),
          ]),
          SizedBox(height: 12.h),
          // Table headers stay on screen even before a class is picked.
          Expanded(child: _wcTable()),
          if (_wcClass != null && _wcStudents.isNotEmpty) _wcPagination(),
        ],
      ),
    );
  }

  Widget _wcTable() {
    final paged = _wcPaged;
    final filtered = _wcFiltered;
    final allSelected = filtered.isNotEmpty && filtered.every((s) => _wcSelected.contains(s['stuadmno'].toString()));
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
            decoration: AppUI.tableHeadBar,
            child: Row(children: [
              SizedBox(width: 36.w, child: Checkbox(
                value: allSelected,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() {
                  final ids = filtered.map((s) => s['stuadmno'].toString());
                  if (v == true) { _wcSelected.addAll(ids); } else { _wcSelected.removeAll(ids); }
                }),
              )),
              _hc(schoolTerm('Register No.'), 2), _hc('Student Name', 3), _hc('Gender', 2), _hc(AppText.dateOfBirth, 2), _hc(AppText.dateOfAdmission, 2),
              _hc('Status', 2), _hc('TC No. *', 2), _hc('TC Date *', 2), _hc('Remarks', 3), SizedBox(width: 44.w),
            ]),
          ),
          Expanded(
            child: paged.isEmpty
                ? AppUI.empty(
                    icon: _wcClass == null ? 'document-text' : 'people',
                    title: _wcClass == null ? schoolTerm('Select a class') : 'No students',
                    why: _wcClass == null
                        ? schoolTerm('Choose a class above to list its students, then tick the ones to issue a TC for.')
                        : schoolTerm('No students match this class or search.'),
                  )
                : ListView.separated(
              itemCount: paged.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (_, i) {
                final s = paged[i];
                final admno = s['stuadmno'].toString();
                final row = _wcRows[admno]!;
                final selected = _wcSelected.contains(admno);
                // Already issued: show the TC number and date that were given,
                // read-only, instead of an empty box that invites a re-entry.
                // An ACTIVE student holds no current TC even if the history has
                // one, so their cells stay editable for a fresh issue.
                final isActive = ((s['activestatus'] as num?)?.toInt() ?? 1) == 1;
                final issued = isActive ? null : _lastTc[admno];
                final issuedNo = (issued?['tcno'] ?? '').toString().trim();
                final hasIssued = issuedNo.isNotEmpty;
                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 4.h),
                  child: Row(children: [
                    SizedBox(width: 36.w, child: Checkbox(
                      value: selected,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(() { if (v == true) { _wcSelected.add(admno); } else { _wcSelected.remove(admno); } }),
                    )),
                    _cc(admno, 2),
                    _cc(s['stuname']?.toString() ?? '', 3),
                    _cc(_genderLabel(s['stugender']), 2),
                    _cc(_fmt(s['studob']), 2),
                    _cc(_fmt(s['stuadmdate']), 2),
                    Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: _statusBadge((s['activestatus'] as num?)?.toInt() ?? 1))),
                    Expanded(
                        flex: 2,
                        child: hasIssued
                            ? Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4.w),
                                child: Text(issuedNo,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppUI.cell.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.primary)),
                              )
                            : Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4.w),
                                child: TextField(controller: row.tcNo, style: AppUI.fieldText(context), decoration: _decDense()))),
                    Expanded(
                        flex: 2,
                        child: hasIssued
                            ? Text(_fmt(issued?['tcdate']),
                                style: AppUI.cell)
                            : InkWell(
                                onTap: () async { final d = await _pickDate(row.tcDate); if (d != null) setState(() => row.tcDate = d); },
                                child: Text(row.tcDate == null ? AppText.dateHint : _fmt(_ymd(row.tcDate)),
                                    style: AppUI.cell.copyWith(color: row.tcDate == null ? AppColors.textLight : AppColors.textPrimary)),
                              )),
                    Expanded(flex: 3, child: Padding(padding: EdgeInsets.symmetric(horizontal: 4.w), child: TextField(controller: row.remarks, style: AppUI.fieldText(context), decoration: _decDense()))),
                    SizedBox(width: 44.w, child: IconButton(
                      tooltip: 'Clear row',
                      icon: Icon(Icons.delete_outline, size: 16.sp, color: AppColors.error),
                      onPressed: () => setState(() {
                        row.tcNo.clear();
                        row.remarks.clear();
                        row.tcDate = DateTime.now(); // back to the default, not blank
                        _wcSelected.remove(admno);
                      }),
                    )),
                  ]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(int code) =>
      AppUI.chip(_statusLabel(code), code == 1 ? AppStatus.success : AppStatus.warning);

  Widget _wcPagination() {
    final total = _wcFiltered.length;
    final pages = total == 0 ? 1 : (total / _wcPageSize).ceil();
    final start = total == 0 ? 0 : _wcPage * _wcPageSize + 1;
    final end = ((_wcPage + 1) * _wcPageSize).clamp(0, total);
    return Padding(
      padding: EdgeInsets.only(top: 10.h),
      child: Row(children: [
        IconButton(onPressed: _wcPage > 0 ? () => setState(() => _wcPage--) : null, icon: const Icon(Icons.chevron_left, size: 20)),
        Text('Page ${_wcPage + 1} of $pages', style: AppUI.muted),
        IconButton(onPressed: (_wcPage + 1) < pages ? () => setState(() => _wcPage++) : null, icon: const Icon(Icons.chevron_right, size: 20)),
        const Spacer(),
        Text(AppUI.showing(start, end, total), style: AppUI.muted),
      ]),
    );
  }

  // ---- small helpers
  Widget _hc(String t, int flex) => AppUI.th(t, flex: flex);
  Widget _cc(String t, int flex) => Expanded(flex: flex, child: Text(t,
      overflow: TextOverflow.ellipsis, style: AppUI.cell));

  /// True once the window is wide enough to show the two panels across.
  /// Below it they stack, because half of a narrow window cannot hold a label
  /// and its field side by side.
  bool get _twoUp => MediaQuery.of(context).size.width >= 1180;

  /// Two panels across on a wide window, stacked on a narrow one.
  Widget _twoUpPanels({required Widget left, required Widget right}) {
    if (!_twoUp) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [left, SizedBox(height: AppUI.gap), right],
      );
    }
    // NO IntrinsicHeight here. It forces the Row to the height Flutter
    // *computes* for its children, and that estimate can land a pixel or three
    // under what the panels actually lay out to -- which is what produced the
    // "BOTTOM OVERFLOWED BY 3.0 PIXELS" stripe. It bought nothing either way:
    // with CrossAxisAlignment.start the panels are not stretched to a common
    // height, so each already takes exactly the height it needs.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        SizedBox(width: AppUI.gap),
        Expanded(child: right),
      ],
    );
  }

  /// A row of fields, chunked to at most two across once the panels sit side
  /// by side. Four fields in a half-width panel leaves each about 200px --
  /// narrower than the dropdowns' own text, so they truncate.
  Widget _rowFields(List<Widget> children) {
    final perRow = _twoUp ? 2 : children.length;
    final rows = <List<Widget>>[];
    for (var i = 0; i < children.length; i += perRow) {
      rows.add(children.sublist(
          i, i + perRow > children.length ? children.length : i + perRow));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: EdgeInsets.only(bottom: 14.h),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < row.length; i++) ...[
                  if (i > 0) SizedBox(width: 16.w),
                  Expanded(child: row[i]),
                ],
                // Keep a lone trailing field half-width instead of letting it
                // stretch across the panel on its own.
                if (row.length < perRow)
                  for (int i = 0; i < perRow - row.length; i++) ...[
                    SizedBox(width: 16.w),
                    const Expanded(child: SizedBox()),
                  ],
              ],
            ),
          ),
      ],
    );
  }

  /// Same label treatment as Student Transfer -- icon, bold caption, field
  /// beneath. [icon] is optional so a minor field can stay plain.
  Widget _labeled(String label, Widget field, {String? icon}) =>
      FormFieldLabel(label: label, icon: icon, child: field);

  Widget _readonly(String v) => Container(
        width: double.infinity,
        constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: AppUI.compact(context) ? 12 : 14),
        decoration: BoxDecoration(
          color: AppColors.tableHeadBg,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Text(v.isEmpty ? AppText.autoFilled : v,
            style: v.isEmpty
                ? AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)
                : AppUI.fieldText(context)),
      );

  Widget _dateField(DateTime? value, ValueChanged<DateTime> onPick, {String hint = 'Select date'}) => InkWell(
        onTap: () async {
          final d = await _pickDate(value);
          if (d != null) onPick(d);
        },
        child: InputDecorator(
          decoration: _dec(hint),
          child: Text(value == null ? hint : _fmt(_ymd(value)),
              style: value == null
                  ? AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)
                  : AppUI.fieldText(context, filled: true)),
        ),
      );

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: DateTime(1980),
        lastDate: DateTime(2100),
      );

  InputDecoration _dec(String hint) => AppUI.field(context, hint);

  InputDecoration _decDense() => AppUI.field(context, '', dense: true);
}

class _WcRow {
  final TextEditingController tcNo;
  final TextEditingController remarks;

  /// Defaults to today. TC Date is mandatory, and a class is almost always
  /// issued on the day it is entered -- an empty box just made the cashier
  /// open the picker 30 times to choose the date they were already on.
  DateTime? tcDate;
  _WcRow({required this.tcNo, required this.remarks, this.tcDate});
}
