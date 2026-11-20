import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import 'class_concession_panel.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';
import '../../utils/school_terms.dart';
import '../../utils/app_text.dart';
import '../../widgets/app_dropdown_field.dart';

/// Fee Concession — two views:
///   • LIST   : every persisted concession record across the institution, with
///              KPI totals, Course/Class/Student filters and pagination.
///   • DETAIL : pick a student and their fee demands (from feedemand) list by
///              semester with the concession editable inline; Save persists a
///              voucher (concession + concessiondetail) via process_concession
///              and re-applies each line onto feedemand.
class FeeConcessionScreen extends StatefulWidget {
  const FeeConcessionScreen({super.key});

  @override
  State<FeeConcessionScreen> createState() => _FeeConcessionScreenState();
}

/// One editable fee-demand line.
class _ConRow {
  final int demId;
  final String feeType;
  final String term;
  final String section;
  /// 'ARREAR' for a carried-forward demand, 'REGULAR' otherwise — read from
  /// feedemand.demseqtype, same rule as Fee Collection.
  final String seqType;
  final String feeYear;
  final double feeAmount;
  final double paidAmount;
  final double appliedAmount; // concession already on the demand at load → locks the row
  final TextEditingController conCtrl;
  _ConRow({
    required this.demId,
    required this.feeType,
    required this.term,
    required this.section,
    required this.seqType,
    required this.feeYear,
    required this.feeAmount,
    required this.paidAmount,
    required double concession,
  })  : appliedAmount = concession,
        conCtrl = TextEditingController(text: concession > 0 ? concession.toStringAsFixed(0) : '');

  // A concession already applied is locked (can't be edited/re-applied → no
  // duplicate voucher). Editable only when it's collectible with an unpaid
  // balance and nothing has been applied yet.
  bool get isApplied => appliedAmount > 0.009;
  bool get editable => (feeAmount - paidAmount) > 0.009 && !isApplied && pendingAmount == null;
  /// A concession on this line is waiting in Concession Approval.
  double? pendingAmount;

  double get concession {
    final c = double.tryParse(conCtrl.text.trim()) ?? 0;
    // Cap at the unpaid balance -- but floor that cap at 0. When paid EXCEEDS
    // the fee (an over-payment awaiting refund) the cap went negative and this
    // returned a NEGATIVE concession, which silently subtracted from the
    // screen totals: three lines carrying 3000 / 0 / 0 summed to 500.
    final max = feeAmount - paidAmount;
    if (c <= 0 || max <= 0) return 0;
    return c > max ? max : c;
  }

  double get balance {
    final b = feeAmount - paidAmount - concession;
    return b > 0 ? b : 0;
  }

  void dispose() => conCtrl.dispose();
}

class _FeeConcessionScreenState extends State<FeeConcessionScreen> {
  // School: 'student' (one student, below) or 'section' (old product's
  // section-wise concession -- ClassConcessionPanel).
  String _mode = 'student';
  // view: 'list' (all records) | 'detail' (one student)
  String _view = 'list';
  String? _error;

  // concession categories (concessioncategory master)
  List<Map<String, dynamic>> _conTypes = [];

  // course/class filter masters
  List<Map<String, dynamic>> _courseList = [];
  List<Map<String, dynamic>> _classList = [];
  String? _selectedCourse;
  String? _selectedClass;
  List<Map<String, dynamic>> _filteredStudents = [];
  bool _studentsLoading = false;
  int _filterReq = 0; // drops a slower, older filter load
  /// Every active student — the Student search falls back to this when no
  /// Course/Class filter is set.
  List<Map<String, dynamic>> _allStudents = [];

  // ── list view ──
  List<Map<String, dynamic>> _allCon = [];
  bool _listLoading = false;
  int _page = 0;
  final int _pageSize = 10;

  // ── detail view (editable fee-demand list) ──
  Map<String, dynamic>? _student;
  // The open student's photo (students.stuphoto). Kept apart from _student
  // because a concession record opened from the list carries no photo, so it
  // is fetched separately -- and must not leak into the saved row.
  String? _studentPhoto;
  List<_ConRow> _demandRows = [];
  bool _demandLoading = false;
  bool _detailSaving = false;
  String? _dSem, _dFeeType; // Step-2 filters
  final TextEditingController _pctCtrl = TextEditingController(); // concession %
  String? _dConType; // Step-2 Concession Type = the category applied on Save
  // Regular Concession / Arrear Write-off -- handled separately (user,
  // 2026-11-14), chosen at the top: the records listed, the student's lines
  // shown and the voucher series (CONNO for regular, ARRCONNO for arrear --
  // the old product's separate arrear voucher / "Arrear Fee Write Off").
  String _dSeqType = 'REGULAR';
  bool get _arrear => _dSeqType == 'ARREAR';
  /// Vouchers that are arrear write-offs (their lines are arrear demands).
  Set<int> _arrearHdr = {};
  bool _isArrearRec(Map<String, dynamic> r) => _arrearHdr.contains((r['con_hdr_id'] as num?)?.toInt());

  @override
  void initState() {
    super.initState();
    _loadConTypes();
    _loadCoursesClasses();
    _loadList();
  }

  @override
  void dispose() {
    for (final r in _demandRows) {
      r.dispose();
    }
    _pctCtrl.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  // ── masters / loads ───────────────────────────────────────────────────────
  Future<void> _loadConTypes() async {
    try {
      final res = await SupabaseService.fromSchema('concessioncategory')
          .select('con_id, condesc')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .order('condesc', ascending: true);
      if (mounted) setState(() => _conTypes = List<Map<String, dynamic>>.from(res as List));
    } catch (_) {}
  }

  Future<void> _loadCoursesClasses() async {
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('courname', ascending: true),
        SupabaseService.fromSchema('class').select('claname, cour_id, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
      });
    } catch (_) {}
  }

  /// All persisted concession voucher headers for the institution.
  Future<void> _loadList() async {
    setState(() => _listLoading = true);
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService.fromSchema('concession')
          .select('con_hdr_id, doc_no, condate, stu_id, stuadmno, stuname, stuclass, courname, con_id, contype, totalfee, totalconcession, totalbalance, createdby')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .order('con_hdr_id', ascending: false));
      if (mounted) setState(() { _allCon = rows; _listLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _listLoading = false; _error = friendlyError(e); });
    }
    // Arrear write-offs: the vouchers whose lines are arrear demands (the
    // voucher itself does not say).
    try {
      final arr = await SupabaseService.fetchAll(() => SupabaseService.fromSchema('feedemand')
          .select('dem_id').eq('ins_id', _insId).eq('demseqtype', 'ARREAR').order('dem_id'));
      final ids = arr.map((d) => (d['dem_id'] as num?)?.toInt()).whereType<int>().toSet();
      var hdr = <int>{};
      if (ids.isNotEmpty) {
        final det = await SupabaseService.fetchAll(() => SupabaseService.fromSchema('concessiondetail')
            .select('con_hdr_id, dem_id').eq('ins_id', _insId).eq('activestatus', 1).order('cond_id'));
        hdr = {
          for (final d in det)
            if (ids.contains((d['dem_id'] as num?)?.toInt()) && d['con_hdr_id'] != null) (d['con_hdr_id'] as num).toInt(),
        };
      }
      if (mounted) setState(() => _arrearHdr = hdr);
    } catch (_) {}
    // Every active student, so the Student box can be searched without first
    // picking a Course/Class. fetchAll: a plain select stops at 1000 rows.
    try {
      final studs = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, stuphoto')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0));  // next year's intake: advance screens only
      studs.sort((a, b) => (a['stuname'] ?? '').toString().compareTo((b['stuname'] ?? '').toString()));
      if (mounted) setState(() => _allStudents = studs);
    } catch (_) {}
  }

  List<String> get _courseNames =>
      (_courseList.map((e) => e['courname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList());

  List<String> _classNamesFor(String? courseName) {
    Iterable<Map<String, dynamic>> src = _classList;
    if (courseName != null && courseName.trim().isNotEmpty) {
      final std = _courseList.firstWhere((c) => (c['courname']?.toString().trim() ?? '') == courseName.trim(), orElse: () => const {});
      final id = std['cour_id'];
      src = id == null ? const <Map<String, dynamic>>[] : _classList.where((cl) => cl['cour_id'] == id);
    }
    // Keeps the master's own order within each group and sends the TC
    // batches to the foot of the list (utils/class_sort.dart).
    return classGroupPartition(
        src.map((e) => e['claname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty).toSet(),
        (s) => s);
  }

  /// The students of the chosen Standard / Section -- listed on the left so
  /// one can be picked (user, 2026-11-14: "when i selects students not
  /// listing the students").
  Future<void> _loadFromFilter() async {
    final req = ++_filterReq;
    if (_selectedCourse == null && _selectedClass == null) {
      if (mounted) setState(() { _filteredStudents = []; _studentsLoading = false; });
      return;
    }
    setState(() { _filteredStudents = []; _studentsLoading = true; _error = null; });
    try {
      final course = _selectedCourse, section = _selectedClass;
      final rows = await SupabaseService.fetchAll(() {
        var query = SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname, stuphoto')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .eq('preadmission', 0);  // next year's intake: advance screens only
        if (course != null) query = query.eq('courname', course);
        if (section != null) query = query.eq('stuclass', section);
        return query.order('stuname', ascending: true);
      });
      final seen = <String>{};
      final deduped = <Map<String, dynamic>>[];
      for (final s in rows) {
        if (seen.add(s['stu_id']?.toString() ?? '')) deduped.add(s);
      }
      if (mounted && req == _filterReq) setState(() { _filteredStudents = deduped; _studentsLoading = false; });
    } catch (e) {
      if (mounted && req == _filterReq) setState(() { _studentsLoading = false; _error = friendlyError(e); });
    }
  }

  // ── detail view: load the student's fee demands (editable) ────────────────
  Future<void> _openDetail(Map<String, dynamic> student) async {
    setState(() {
      _view = 'detail';
      _student = student;
      for (final r in _demandRows) { r.dispose(); }
      _demandRows = [];
      _demandLoading = true;
      _dSem = _dFeeType = _dConType = null;
      _error = null;
      _studentPhoto = student['stuphoto']?.toString();
    });
    if (!student.containsKey('stuphoto')) _loadStudentPhoto(student['stu_id']);
    await _loadDemands();
  }

  /// Regular <-> Arrear: a voucher is one or the other, so amounts typed but
  /// not saved for the other type are cleared rather than left hidden.
  void _setSeqType(String type) {
    if (type == _dSeqType) return;
    setState(() {
      for (final r in _demandRows.where((r) => r.editable)) {
        r.conCtrl.text = '';
      }
      _dSeqType = type;
      if (type == 'ARREAR') _mode = 'student'; // write-off is per student
      _dSem = _dFeeType = null;
      _page = 0;
    });
  }

  /// A record opened from the concession list has no stuphoto column; look it
  /// up for that one student. A failure just leaves the initial showing.
  Future<void> _loadStudentPhoto(dynamic stuId) async {
    if (stuId == null) return;
    try {
      final row = await SupabaseService.fromSchema('students')
          .select('stuphoto')
          .eq('stu_id', stuId)
          .maybeSingle();
      if (!mounted || _student?['stu_id']?.toString() != stuId.toString()) return;
      setState(() => _studentPhoto = row?['stuphoto']?.toString());
    } catch (_) {}
  }

  Future<void> _loadDemands() async {
    final admno = _student?['stuadmno']?.toString() ?? '';
    if (admno.isEmpty) { setState(() => _demandLoading = false); return; }
    setState(() => _demandLoading = true);
    try {
      final res = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuclass, demfeeterm, demfeetype, feeamount, conamount, paidamount, con_id, collectible, demseqtype, demfeeyear')
          .eq('ins_id', _insId)
          .eq('stuadmno', admno)
          .eq('activestatus', 1)
          .order('demfeeterm', ascending: true)
          .order('demfeetype', ascending: true);
      // Concession only applies to collectible fees — a non-collectible demand
      // isn't billed, so exclude collectible=false (keep true / unset).
      final list = (res as List).where((e) => (e as Map)['collectible'] != false).map((e) {
        final m = e as Map<String, dynamic>;
        return _ConRow(
          demId: m['dem_id'] is int ? m['dem_id'] as int : int.tryParse(m['dem_id'].toString()) ?? 0,
          feeType: m['demfeetype']?.toString() ?? '',
          term: m['demfeeterm']?.toString() ?? '',
          section: m['stuclass']?.toString() ?? '',
          seqType: (m['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR'
              ? 'ARREAR'
              : 'REGULAR',
          feeYear: m['demfeeyear']?.toString() ?? '',
          feeAmount: (m['feeamount'] as num?)?.toDouble() ?? 0,
          paidAmount: (m['paidamount'] as num?)?.toDouble() ?? 0,
          concession: (m['conamount'] as num?)?.toDouble() ?? 0,
        );
      }).toList();
      // Preselect the category already on the demands (if any).
      String? existing;
      for (final e in res) {
        final cid = (e as Map)['con_id'];
        if (cid != null) { existing = cid.toString(); break; }
      }
      // Lines already waiting for approval are shown as pending, locked.
      try {
        final stuId = _student?['stu_id'];
        if (stuId != null && SupabaseService.sessionToken != null) {
          final pend = await SupabaseService.client.rpc('concession_pending_lines',
              params: {'p_token': SupabaseService.sessionToken, 'p_stu_id': stuId});
          for (final x in (pend as List? ?? const [])) {
            final m = x as Map;
            final dem = (m['dem_id'] as num?)?.toInt();
            for (final row in list.where((row) => row.demId == dem)) {
              row.pendingAmount = (m['conamount'] as num?)?.toDouble() ?? 0;
            }
          }
        }
      } catch (_) {
        // college / older database: no approval step
      }
      if (!mounted) return;
      setState(() {
        _demandRows = list;
        if (existing != null && _conTypes.any((t) => t['con_id'].toString() == existing)) _dConType = existing;
        _demandLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _demandLoading = false; _error = friendlyError(e); });
    }
  }

  void _backToList() {
    setState(() {
      _view = 'list';
      _student = null;
      for (final r in _demandRows) { r.dispose(); }
      _demandRows = [];
      _error = null;
    });
    _loadList();
  }

  void _clearFilters() {
    _filterReq++;
    setState(() {
      _selectedCourse = null;
      _selectedClass = null;
      _filteredStudents = [];
      _studentsLoading = false;
      _page = 0;
      _error = null;
      if (_view == 'detail') { _dSem = _dFeeType = null; }
    });
  }

  // ── list filtering + KPIs ─────────────────────────────────────────────────
  List<Map<String, dynamic>> get _filteredList {
    return _allCon.where((r) {
      if (_isArrearRec(r) != _arrear) return false;
      if (_selectedCourse != null && (r['courname']?.toString() != _selectedCourse)) return false;
      if (_selectedClass != null && (r['stuclass']?.toString() != _selectedClass)) return false;
      return true;
    }).toList();
  }

  /// A Standard or Section is chosen: the list shows its students.
  bool get _byFilter => _selectedCourse != null || _selectedClass != null;

  /// Students offered by the Student search: those of the chosen Standard /
  /// Section, or everyone when none is chosen.
  List<Map<String, dynamic>> get _studentPool => _byFilter ? _filteredStudents : _allStudents;

  double _sum(List<Map<String, dynamic>> rows, String key) =>
      rows.fold(0.0, (s, r) => s + ((r[key] as num?)?.toDouble() ?? 0));

  // ── detail filtering + distincts ──────────────────────────────────────────
  /// Concession by PERCENTAGE: every editable line on screen (Term / Fee Type
  /// filters respected) gets that share of its fee, capped at what is still
  /// unpaid. Lines can still be changed by hand afterwards.
  void _applyPercent() {
    final pct = double.tryParse(_pctCtrl.text.trim()) ?? 0;
    if (pct <= 0 || pct > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a percentage between 1 and 100.'), backgroundColor: AppColors.warning));
      return;
    }
    setState(() {
      for (final r in _filteredDemands.where((r) => r.editable)) {
        var v = (r.feeAmount * pct / 100);
        final max = r.feeAmount - r.paidAmount;
        if (v > max) v = max;
        r.conCtrl.text = v <= 0 ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
      }
    });
  }

  /// The chosen type's lines (Regular or Arrear).
  Iterable<_ConRow> get _typeRows => _demandRows.where((r) => r.seqType == _dSeqType);

  List<_ConRow> get _filteredDemands => _typeRows.where((r) {
        if (_dSem != null && r.term != _dSem) return false;
        if (_dFeeType != null && r.feeType != _dFeeType) return false;
        return true;
      }).toList();


  // ── save ──────────────────────────────────────────────────────────────────
  // True if a numbering sequence with this actname (e.g. CONNO) is configured.
  Future<bool> _hasSequence(String actname) async {
    try {
      final r = await SupabaseService.fromSchema('sequence')
          .select('seq_id').eq('ins_id', _insId).eq('actname', actname).eq('activestatus', 1).limit(1).maybeSingle();
      return r != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveConcession() async {
    if (_student == null) return;
    final arrear = _dSeqType == 'ARREAR';
    final lines = _typeRows.where((r) => r.editable && r.concession > 0).toList();
    if (lines.isEmpty) {
      _popup('Nothing to Apply', 'Enter a concession amount on at least one unpaid ${arrear ? 'arrear ' : ''}fee line.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    if (_dConType == null || _dConType!.isEmpty) {
      _popup('Concession Category Required', 'Select a concession category under "Filter Concession" first. It is applied to these lines.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    if (!await _hasSequence(arrear ? 'ARRCONNO' : 'CONNO')) {
      _popup('Sequence Required',
          'Create the ${arrear ? 'Arrear' : 'Regular'} concession series in Setup → Sequence Master → Concession No (Concession Type: ${arrear ? 'Arrear' : 'Regular'}) first.',
          AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    setState(() => _detailSaving = true);
    try {
      final auth = context.read<AuthProvider>();
      final conId = int.tryParse(_dConType!);
      final contype = _conTypes.firstWhere((t) => t['con_id'].toString() == _dConType, orElse: () => const {})['condesc']?.toString();
      final token = auth.sessionToken;

      // Regular and arrear are separate money, so each gets its OWN voucher —
      // its own doc_no off the CONNO sequence — rather than one mixed document
      // that can't be reconciled back to either.
      final byType = <String, List<_ConRow>>{};
      for (final r in lines) {
        byType.putIfAbsent(r.seqType, () => []).add(r);
      }
      // Regular first so the numbering reads in the order the screen shows it.
      final types = byType.keys.toList()
        ..sort((a, b) => a == b ? 0 : (a == 'REGULAR' ? -1 : 1));

      var sentForApproval = 0;
      for (final type in types) {
        final group = byType[type]!;
        final totalFee = group.fold(0.0, (s, r) => s + r.feeAmount);
        final totalCon = group.fold(0.0, (s, r) => s + r.concession);
        final totalBal = group.fold(0.0, (s, r) => s + r.balance);
        final header = <String, dynamic>{
          // doc_no is assigned by process_concession from the CONNO sequence;
          // it is the concession's only document number (receiptno was retired).
          'ins_id': _insId,
          'inscode': auth.inscode,
          'yrlabel': auth.yearLabel,
          'condate': DateTime.now().toIso8601String().split('T').first,
          'stu_id': _student!['stu_id'],
          'stuadmno': _student!['stuadmno'],
          'stuname': _student!['stuname'],
          'stuclass': _student!['stuclass'],
          'courname': _student!['courname'],
          'con_id': conId,
          'contype': contype,
          'totalfee': totalFee,
          'totalconcession': totalCon,
          'totalbalance': totalBal,
          'createdby': auth.userName,
          // ARREAR -> the arrear concession series (ARRCONNO, AC26/0001) on school
          'seqtype': type,
        };
        final detailLines = group
            .map((r) => {
                  'dem_id': r.demId,
                  'demfeeterm': r.term,
                  'demfeetype': r.feeType,
                  'feeamount': r.feeAmount,
                  'conamount': r.concession,
                  'balancedue': r.balance,
                })
            .toList();

        if (token != null && token.isNotEmpty) {
          final res = await SupabaseService.client.rpc('process_concession', params: {
            'p_token': token, 'p_header': header, 'p_lines': detailLines,
          });
          // Negative = it went for approval (school_concession_approval.sql).
          if (res is num && res < 0) sentForApproval++;
        } else {
          for (final r in group) {
            await SupabaseService.applyConcession(
                demId: r.demId, conId: conId, conamount: r.concession, balancedue: r.balance);
          }
        }
      }
      if (!mounted) return;
      setState(() => _detailSaving = false);
      _snack(
          sentForApproval > 0
              ? '${_arrear ? 'Arrear write-off' : 'Concession'} for ${_student!['stuname']} sent for approval -- it reduces the fees once approved in Fees → Concession Approval.'
              : types.length > 1
                  ? 'Concession saved for ${_student!['stuname']} — separate vouchers for Regular and Arrear.'
                  : '${_arrear ? 'Arrear write-off' : 'Concession'} saved for ${_student!['stuname']}.',
          AppColors.success);
      await _loadDemands();
      // the list on the left shows the new voucher straight away
      _loadList();
    } catch (e) {
      if (mounted) {
        setState(() => _detailSaving = false);
        _popup('Save Failed', friendlyError(e), AppColors.error, Icons.error_outline);
      }
    }
  }

  // ── UI helpers ────────────────────────────────────────────────────────────
  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  void _popup(String title, String message, Color color, IconData icon) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [Icon(icon, color: color, size: 22), const SizedBox(width: 10), Expanded(child: Text(title, style: AppUI.cardTitle))]),
        content: Text(message, style: AppUI.body),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
      ),
    );
  }

  InputDecoration _fieldDec(String hint) => AppUI.field(context, hint);

  TextStyle _fieldTextStyle() => AppUI.fieldText(context);

  /// One line of dropdown text that shrinks to fit instead of wrapping onto
  /// a clipped second line.
  Widget _fitLine(String text) => Align(
        alignment: Alignment.centerLeft,
        child: AppFitText(text, style: _fieldTextStyle()),
      );

  // Concession category is a label, not a status: one neutral/info pill for
  // every category (the text carries the meaning).
  Widget _typeBadge(String type) =>
      AppUI.chip(type.isEmpty ? '—' : type, type.trim().isEmpty ? AppStatus.neutral : AppStatus.info);

  Widget _kpiCard({required String icon, required Color tint, required String value, required String label, String? sub}) =>
      AppUI.kpi(icon: icon, label: label, value: value, sub: sub, tint: tint);

  Widget _stepBadge(int n, String title) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 20.w, height: 20.w, alignment: Alignment.center, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle), child: Text('$n', style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w800, color: Colors.white))),
        SizedBox(width: 8.w),
        Text(title, style: AppUI.label),
      ]);

  // Indian grouping is last-3 then 2s (1,15,824.00). The old local regex
  // grouped by 2 all the way (11,58,24.00), so every concession figure on this
  // screen read wrong by an order of magnitude at a glance.
  String _inr(num v) => '₹${formatIndianNumber(v)}';
  String _date(dynamic v) {
    final s = v?.toString() ?? '';
    if (s.length < 10) return s;
    final p = s.substring(0, 10).split('-');
    return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : s;
  }

  // ── build ─────────────────────────────────────────────────────────────────
  // Single Student: master-detail -- concession records + student search on
  // the left, the picked student's demand lines + concession entry on the
  // right. Whole Section keeps the ClassConcessionPanel as before.
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(clipBehavior: Clip.antiAlias, decoration: AppUI.card(), child: _header()),
      SizedBox(height: AppUI.gap),
      Expanded(
        child: _mode == 'section'
            ? Container(clipBehavior: Clip.antiAlias, decoration: AppUI.card(), child: const ClassConcessionPanel())
            : _masterDetail(),
      ),
    ]);
  }

  Widget _header() => Padding(
        padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h),
        child: Row(children: [
          AppUI.iconTile('receipt-discount'),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Fee Concession', style: AppUI.cardTitle),
              SizedBox(height: 2.h),
              Text(_mode == 'section'
                      ? schoolTerm('Concession for every student of a class with a concession category')
                      : _arrear
                          ? "Write off a student's arrear (previous year) dues"
                          : "Apply concession against a student's fee demands",
                  style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          // Regular Concession: one student or a whole section. Arrear
          // Write-off: one student only (user, 2026-11-14).
          ...[
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'REGULAR', label: Text('Regular Concession'), icon: Icon(Icons.discount_outlined, size: 16)),
                ButtonSegment(value: 'ARREAR', label: Text('Arrear Write-off'), icon: Icon(Icons.history, size: 16)),
              ],
              selected: {_dSeqType},
              onSelectionChanged: (v) => _setSeqType(v.first),
            ),
          ],
          if (isSchool && !_arrear) ...[
            SizedBox(width: 10.w),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'student', label: Text('Single Student'), icon: Icon(Icons.person_outline, size: 16)),
                ButtonSegment(value: 'section', label: Text(schoolTerm('Whole Class')), icon: const Icon(Icons.groups_outlined, size: 16)),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() => _mode = v.first),
            ),
          ],
        ]),
      );

  Widget _masterDetail() {
    final filtered = _filteredList;
    final picked = _view == 'detail' && _student != null;
    final byFilter = _byFilter;
    return AppMasterDetail(
      listTitle: byFilter ? 'Students' : (_arrear ? 'Arrear Write-offs' : 'Concessions'),
      listIcon: byFilter ? 'people' : 'discount-shape',
      listSubtitle: byFilter
          ? (_arrear ? 'Pick a student to write off arrears' : 'Pick a student to apply a concession')
          : (_arrear ? 'Search for a student to write off arrears' : 'Search for a student to apply a new concession'),
      listActions: [
        TextButton.icon(
          onPressed: _clearFilters,
          icon: const AppIcon('refresh', size: 14, color: AppColors.primary),
          label: const Text('Clear'),
        ),
      ],
      search: _studentSearch(),
      filters: [_courseClassFilters()],
      list: byFilter ? _studentList() : _recordList(filtered),
      footer: _recordFooter(byFilter ? _filteredStudents.length : filtered.length),
      detail: picked ? _detailBody() : null,
      emptyDetail: _overview(filtered),
      showDetail: picked,
      onBack: _backToList,
    );
  }

  // ══════════════════════════════ LIST PANE ═════════════════════════════════
  // Typeable: search by admission no or name across EVERY student, not just
  // the ones inside the Course/Class filter -- looking a student up by number
  // shouldn't depend on knowing their course first.
  Widget _studentSearch() => LayoutBuilder(
        builder: (context, box) => Autocomplete<Map<String, dynamic>>(
          displayStringForOption: (o) => '${o['stuadmno']} • ${o['stuname']}',
          optionsBuilder: (v) {
            final q = v.text.trim().toLowerCase();
            final pool = _studentPool;
            if (q.isEmpty) return pool.take(20);
            return pool
                .where((s) => '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q))
                .take(30);
          },
          onSelected: (s) => _openDetail(s),
          fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
            controller: ctrl,
            focusNode: focus,
            style: _fieldTextStyle(),
            decoration: AppUI.field(context, schoolTerm('Search by roll no. or name'), leadingIcon: 'search-normal-1').copyWith(
              suffixIcon: ctrl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: Icon(Icons.close, size: 15.sp, color: AppColors.textSecondary),
                      onPressed: () => setState(ctrl.clear),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(10.r),
              child: SizedBox(
                width: box.maxWidth,
                height: options.length > 8 ? 320.h : null,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: options.length <= 8,
                  itemCount: options.length,
                  itemBuilder: (_, i) {
                    final o = options.elementAt(i);
                    return ListTile(
                      dense: true,
                      title: Text('${o['stuadmno']} • ${o['stuname']}',
                          style: AppUI.cell.copyWith(fontWeight: FontWeight.w600)),
                      subtitle: Text('${o['courname'] ?? ''} • ${o['stuclass'] ?? ''}',
                          style: AppUI.muted),
                      onTap: () => onSelected(o),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

  Widget _courseClassFilters() => Row(children: [
        Expanded(
          child: AppDropdownField<String>(
            initialValue: _courseNames.contains(_selectedCourse) ? _selectedCourse : null,
            isExpanded: true, dropdownColor: Colors.white, borderRadius: BorderRadius.circular(12), elevation: 6, style: _fieldTextStyle(), decoration: _fieldDec(schoolTerm('All Courses')),
            items: [DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All Courses'))), ..._courseNames.map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis)))],
            // The shown value stays on one line and shrinks to fit, not "All" + a clipped "Standards".
            selectedItemBuilder: (_) => [_fitLine(schoolTerm('All Courses')), for (final s in _courseNames) _fitLine(s)],
            onChanged: (v) => setState(() { _selectedCourse = v; if (_selectedClass != null && !_classNamesFor(v).contains(_selectedClass)) _selectedClass = null; _page = 0; _loadFromFilter(); }),
          ),
        ),
        SizedBox(width: 10.w),
        Expanded(
          child: AppDropdownField<String>(
            initialValue: _classNamesFor(_selectedCourse).contains(_selectedClass) ? _selectedClass : null,
            isExpanded: true, dropdownColor: Colors.white, borderRadius: BorderRadius.circular(12), elevation: 6, style: _fieldTextStyle(), decoration: _fieldDec(schoolTerm('All Classes')),
            items: [DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All Classes'))), ..._classNamesFor(_selectedCourse).map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis)))],
            selectedItemBuilder: (_) => [_fitLine(schoolTerm('All Classes')), for (final s in _classNamesFor(_selectedCourse)) _fitLine(s)],
            onChanged: (v) => setState(() { _selectedClass = v; _page = 0; _loadFromFilter(); }),
          ),
        ),
      ]);

  Widget _filterCol(String label, Widget child, {bool required = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        AppUI.fieldLabel(label, required: required),
        child,
      ]);

  Widget _recordList(List<Map<String, dynamic>> filtered) {
    if (_listLoading) return const AppLoading(label: 'Loading concessions…');
    if (filtered.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(icon: 'receipt-discount', title: _arrear ? 'No arrear write-offs' : 'No concession records', subtitle: _error ?? (_arrear ? 'Search a student above to write off arrears' : 'Search a student above to apply a concession'), action: OutlinedButton.icon(onPressed: _clearFilters, icon: const AppIcon('refresh', size: 15, color: AppColors.primary), label: const Text(AppText.clearFilters))),
        ),
      );
    }
    final pageCount = (filtered.length / _pageSize).ceil();
    if (_page >= pageCount) _page = pageCount - 1;
    final start = _page * _pageSize;
    final pageRows = filtered.sublist(start, (start + _pageSize).clamp(0, filtered.length));
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: pageRows.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) => _recordTile(pageRows[i]),
    );
  }

  /// The students of the chosen Standard / Section, with the concession each
  /// already has this year. Tapping one opens their fee demands on the right.
  Widget _studentList() {
    if (_studentsLoading) return const AppLoading(label: 'Loading students…');
    final rows = _filteredStudents;
    if (rows.isEmpty) {
      final where = _selectedClass ?? _selectedCourse ?? '';
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(icon: 'people', title: 'No students', subtitle: _error ?? 'No active student is in $where.', action: OutlinedButton.icon(onPressed: _clearFilters, icon: const AppIcon('refresh', size: 15, color: AppColors.primary), label: const Text(AppText.clearFilters))),
        ),
      );
    }
    final given = <String, double>{};
    for (final c in _allCon.where((c) => _isArrearRec(c) == _arrear)) {
      final k = c['stu_id']?.toString() ?? '';
      given[k] = (given[k] ?? 0) + ((c['totalconcession'] as num?)?.toDouble() ?? 0);
    }
    final pageCount = (rows.length / _pageSize).ceil();
    if (_page >= pageCount) _page = pageCount - 1;
    final start = _page * _pageSize;
    final pageRows = rows.sublist(start, (start + _pageSize).clamp(0, rows.length));
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: pageRows.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) {
        final s = pageRows[i];
        final sel = _view == 'detail' && _student != null && _student!['stu_id']?.toString() == s['stu_id']?.toString();
        final cls = [s['courname'], s['stuclass']].map((e) => e?.toString().trim() ?? '').where((x) => x.isNotEmpty).join(' / ');
        final amt = given[s['stu_id']?.toString() ?? ''] ?? 0;
        return Material(
          color: sel ? AppColors.primaryLight : Colors.white,
          child: InkWell(
            onTap: () => _openDetail(s),
            hoverColor: AppColors.primaryLight.withValues(alpha: 0.6),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 10.h),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s['stuname']?.toString() ?? '', style: AppUI.label.copyWith(color: sel ? AppColors.primary : AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                    SizedBox(height: 2.h),
                    Text('${s['stuadmno'] ?? ''}${cls.isEmpty ? '' : '  ·  $cls'}', style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                SizedBox(width: 10.w),
                amt > 0
                    ? Text(_inr(amt), textAlign: TextAlign.right, style: AppUI.money.copyWith(color: sel ? AppColors.primary : AppColors.textPrimary))
                    : Text('No concession', style: AppUI.muted.copyWith(fontSize: 12.sp)),
              ]),
            ),
          ),
        );
      },
    );
  }

  /// One concession record: student + class on the left, amount + category on
  /// the right. Tapping it opens that student on the right (what the old eye
  /// button did).
  Widget _recordTile(Map<String, dynamic> r) {
    final sel = _view == 'detail' && _student != null && _student!['stu_id']?.toString() == r['stu_id']?.toString();
    final cls = [r['courname'], r['stuclass']].map((e) => e?.toString().trim() ?? '').where((s) => s.isNotEmpty).join(' / ');
    final by = r['createdby']?.toString() ?? '';
    final when = _date(r['condate']);
    return Material(
      color: sel ? AppColors.primaryLight : Colors.white,
      child: InkWell(
        onTap: () => _openDetail(r),
        hoverColor: AppColors.primaryLight.withValues(alpha: 0.6),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 10.h),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r['stuname']?.toString() ?? '', style: AppUI.label.copyWith(color: sel ? AppColors.primary : AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                SizedBox(height: 2.h),
                Text('${r['stuadmno'] ?? ''}${cls.isEmpty ? '' : '  ·  $cls'}', style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                SizedBox(height: 2.h),
                Text(by.isEmpty ? when : '$when  ·  by $by', style: AppUI.muted.copyWith(fontSize: 12.sp), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            SizedBox(width: 10.w),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(((r['totalconcession'] as num?)?.toDouble() ?? 0).toStringAsFixed(2), textAlign: TextAlign.right, style: AppUI.money.copyWith(color: sel ? AppColors.primary : AppColors.textPrimary)),
              SizedBox(height: 6.h),
              // Wide enough for a full category name ("PANDEMIC CONCESSION"
              // was cut off at 130); the tooltip covers anything longer.
              Tooltip(
                message: r['contype']?.toString() ?? '',
                child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 210.w), child: _typeBadge(r['contype']?.toString() ?? '')),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _recordFooter(int total) {
    final pageCount = total == 0 ? 0 : (total / _pageSize).ceil();
    final start = total == 0 ? 0 : _page * _pageSize + 1;
    final end = ((_page + 1) * _pageSize).clamp(0, total);
    return Row(children: [
      Expanded(child: Text(AppUI.showing(start, end, total), style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis)),
      if (pageCount > 1) ...[
        _pageBtn(Icons.chevron_left, _page > 0 ? () => setState(() => _page--) : null),
        Padding(padding: EdgeInsets.symmetric(horizontal: 8.w), child: Text('${_page + 1} / $pageCount', style: AppUI.label)),
        _pageBtn(Icons.chevron_right, _page < pageCount - 1 ? () => setState(() => _page++) : null),
      ],
    ]);
  }

  Widget _pageBtn(IconData icon, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7.r),
        child: Container(width: 30.w, height: 30.w, alignment: Alignment.center, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(7.r), border: Border.all(color: AppColors.border)), child: Icon(icon, size: 18, color: onTap == null ? AppColors.textLight : AppColors.textPrimary)),
      );

  /// 4 KPI tiles in one row, or 2x2 when the pane is narrow.
  Widget _kpiGrid(List<Widget> tiles) => LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth < 760 ? 2 : 4;
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += perRow) {
          final chunk = tiles.sublist(i, (i + perRow).clamp(0, tiles.length));
          rows.add(Row(children: [
            for (var j = 0; j < chunk.length; j++) ...[if (j > 0) SizedBox(width: 12.w), Expanded(child: chunk[j])],
          ]));
        }
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (var k = 0; k < rows.length; k++) ...[if (k > 0) SizedBox(height: 12.h), rows[k]],
        ]);
      });

  /// Right pane before a student is picked: the list's KPI totals + what to do.
  Widget _overview(List<Map<String, dynamic>> filtered) {
    final students = filtered.map((e) => e['stu_id']?.toString() ?? '').where((s) => s.isNotEmpty).toSet().length;
    final totalAmt = _sum(filtered, 'totalconcession');
    final avg = students == 0 ? 0.0 : totalAmt / students;
    return SingleChildScrollView(
      padding: EdgeInsets.all(AppUI.cardPad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.sectionLabel('Overview'),
        _kpiGrid([
          _kpiCard(icon: 'discount-shape', tint: AppColors.primary, value: '${filtered.length}', label: _arrear ? 'Total Write-offs' : 'Total Concessions', sub: 'This Year'),
          _kpiCard(icon: 'wallet-money', tint: AppColors.success, value: _inr(totalAmt), label: 'Total Amount', sub: 'This Year'),
          _kpiCard(icon: 'people', tint: AppColors.demand, value: '$students', label: 'Total Students', sub: 'This Year'),
          _kpiCard(icon: 'chart-1', tint: AppColors.warning, value: _inr(avg), label: _arrear ? 'Average Write-off' : 'Average Concession', sub: 'Per Student'),
        ]),
        SizedBox(height: 40.h),
        AppUI.empty(
          icon: 'receipt-discount',
          title: 'Select a student',
          why: schoolTerm('Pick a concession on the left, or search for a student by roll no. or name, to see their fee demands and apply a concession.'),
        ),
      ]),
    );
  }

  // ══════════════════════════════ DETAIL VIEW ═══════════════════════════════
  Widget _detailBody() {
    final rows = _filteredDemands;
    final totalFee = rows.fold(0.0, (s, r) => s + r.feeAmount);
    final totalPaid = rows.fold(0.0, (s, r) => s + r.paidAmount);
    final totalCon = rows.fold(0.0, (s, r) => s + r.concession);
    // Net Payable = Fee − Paid − Concession (the sum of the Balance column), so
    // the footer tallies: Fee − Paid − Concession = Net Payable.
    final netPayable = rows.fold(0.0, (s, r) => s + r.balance);
    // Keyed by student so switching students straight from the list starts a
    // fresh detail (as opening it from the old list view did).
    return KeyedSubtree(
      key: ValueKey('con-detail-${_student?['stu_id']}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _detailFilterCard(),
          // (The four total cards were removed -- user, 2026-11-14; the
          // footer bar carries the same totals.)
          SizedBox(height: AppUI.gap),
          Row(children: [
            _stepBadge(3, schoolTerm('Fee Demands by Semester')),
            SizedBox(width: 12.w),
            Expanded(child: Text('Enter a concession against any unpaid line', textAlign: TextAlign.right, style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
          SizedBox(height: 10.h),
          _demandGrid(rows),
        ]))),
        _detailFooter(totalFee, totalPaid, totalCon, netPayable),
      ]),
    );
  }

  Widget _detailFilterCard() {
    final s = _student!;
    final name = s['stuname']?.toString() ?? '';
    // Required: Save refuses without it ("Concession Category Required").
    final conTypeDrop = _filterCol('Concession Category', AppDropdownField<String>(
      initialValue: _dConType, isExpanded: true, dropdownColor: Colors.white, borderRadius: BorderRadius.circular(12), elevation: 6, style: _fieldTextStyle(), decoration: _fieldDec('Select concession category'),
      items: _conTypes.map((t) => DropdownMenuItem(value: t['con_id'].toString(), child: Text(t['condesc']?.toString() ?? '', overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) => setState(() => _dConType = v),
    ), required: true);
    final pctBox = _filterCol('Concession %', Row(children: [
      Expanded(
        child: TextField(
          controller: _pctCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,3}\.?\d{0,2}'))],
          style: _fieldTextStyle(),
          decoration: _fieldDec('%'),
          onSubmitted: (_) => _applyPercent(),
        ),
      ),
      SizedBox(width: 6.w),
      Tooltip(
        message: 'Fill every line shown with this % of its fee',
        child: OutlinedButton(
          onPressed: _applyPercent,
          style: OutlinedButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 10.w)),
          child: const Text('Apply %'),
        ),
      ),
    ]));
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Step 1: student
        Align(alignment: Alignment.centerLeft, child: _stepBadge(1, 'Select Student')),
        SizedBox(height: 10.h),
        AppUI.fieldLabel('Student', required: true),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.primary.withValues(alpha: 0.55))),
          child: Row(children: [
            StudentAvatar(photoUrl: _studentPhoto, name: name, size: 44),
            SizedBox(width: 10.w),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(name, style: AppUI.label, overflow: TextOverflow.ellipsis),
              SizedBox(height: 2.h),
              Text(schoolTerm('Roll No.: ${s['stuadmno']}  |  Class: ${s['stuclass'] ?? ''}'), style: AppUI.muted, overflow: TextOverflow.ellipsis),
            ])),
            Tooltip(
              message: 'Close',
              child: InkWell(onTap: _backToList, borderRadius: BorderRadius.circular(6.r), child: Padding(padding: EdgeInsets.all(4.w), child: const Icon(Icons.close, size: 16, color: AppColors.textLight))),
            ),
          ]),
        ),
        SizedBox(height: 18.h),
        // Step 2: the category applied + an optional % for every line. (The
        // Term / Fee Type filters were removed -- user, 2026-11-14.)
        Align(alignment: Alignment.centerLeft, child: _stepBadge(2, 'Concession Details')),
        SizedBox(height: 10.h),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: conTypeDrop),
          SizedBox(width: 10.w),
          SizedBox(width: 260.w, child: pctBox),
        ]),
      ]),
    );
  }

  /// The student's demands grouped by semester/term, each concession editable.
  Widget _demandGrid(List<_ConRow> rows) {
    if (_demandLoading) return SizedBox(height: 240.h, child: const AppLoading(label: 'Loading fee demands…'));
    if (rows.isEmpty) {
      return Container(constraints: BoxConstraints(minHeight: 220.h), alignment: Alignment.center, padding: EdgeInsets.symmetric(vertical: 24.h),
          child: EmptyState(
              icon: 'receipt-discount',
              title: _dSeqType == 'ARREAR' ? 'No arrear fee demands' : 'No fee demands',
              subtitle: _error ??
                  (_dSeqType == 'ARREAR'
                      ? 'This student has no arrear (previous year) dues. Choose Regular Concession for this year\'s fees.'
                      : 'This student has no active fee demands to apply a concession on')));
    }
    // Regular and arrear are different money and are collected on separate
    // receipts, so they get their own blocks rather than being mixed by term.
    final regular = rows.where((r) => r.seqType != 'ARREAR').toList();
    final arrear = rows.where((r) => r.seqType == 'ARREAR').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Only badge the blocks when both exist — a student with regular fees
      // only shouldn't grow an extra header for no reason.
      if (regular.isNotEmpty) ...[
        if (arrear.isNotEmpty) _seqTypeHeader('REGULAR', regular),
        ..._termBlocks(regular),
      ],
      if (arrear.isNotEmpty) ...[
        _seqTypeHeader('ARREAR', arrear),
        ..._termBlocks(arrear),
      ],
    ]);
  }

  /// Term sections for one sequence type.
  List<Widget> _termBlocks(List<_ConRow> rows) {
    final byTerm = <String, List<_ConRow>>{};
    for (final r in rows) {
      byTerm.putIfAbsent(r.term.isEmpty ? '—' : r.term, () => []).add(r);
    }
    final terms = byTerm.keys.toList()..sort();
    return [
      for (final term in terms) ...[
        _termSection(term, byTerm[term]!),
        SizedBox(height: 12.h),
      ],
    ];
  }

  /// REGULAR / ARREAR band above a group, with its own fee + concession tally.
  Widget _seqTypeHeader(String type, List<_ConRow> rows) {
    final isArrear = type == 'ARREAR';
    final fee = rows.fold(0.0, (s, r) => s + r.feeAmount);
    final con = rows.fold(0.0, (s, r) => s + r.concession);
    // Arrear demands can span years; name them so it's clear what is included.
    final years = rows.map((r) => r.feeYear).where((y) => y.isNotEmpty).toSet().toList()..sort();
    return Padding(
      padding: EdgeInsets.only(bottom: 8.h),
      child: Row(children: [
        AppUI.chip(type, isArrear ? AppStatus.warning : AppStatus.info),
        if (isArrear && years.isNotEmpty) ...[
          SizedBox(width: 8.w),
          Text(years.join(', '), style: AppUI.muted),
        ],
        const Spacer(),
        Text('Fee ${fee.toStringAsFixed(0)}  •  Concession ${con.toStringAsFixed(0)}', style: AppUI.muted),
      ]),
    );
  }

  Widget _termSection(String term, List<_ConRow> rows) {
    final termFee = rows.fold(0.0, (s, r) => s + r.feeAmount);
    final termCon = rows.fold(0.0, (s, r) => s + r.concession);
    TextStyle h() => AppUI.tableHead;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(children: [
        // term header
        Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppColors.divider))),
          child: Row(children: [
            const AppIcon.linear('calendar-1', size: 16, color: AppColors.primary),
            SizedBox(width: 8.w),
            Text(term, style: AppUI.label),
            const Spacer(),
            Text('Fee ${termFee.toStringAsFixed(0)}   •   Concession ${termCon.toStringAsFixed(0)}', style: AppUI.muted),
          ]),
        ),
        // column header
        Container(color: AppColors.tableHeadBg, padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 9.h), child: Row(children: [
          Expanded(flex: 3, child: Text('FEE TYPE', style: h())),
          SizedBox(width: 120.w, child: Text('FEE AMOUNT', textAlign: TextAlign.right, style: h())),
          SizedBox(width: 90.w, child: Text('PAID', textAlign: TextAlign.right, style: h())),
          SizedBox(width: 150.w, child: Padding(padding: EdgeInsets.only(right: 12.w), child: Text('CONCESSION', textAlign: TextAlign.right, style: h()))),
          SizedBox(width: 120.w, child: Text('BALANCE', textAlign: TextAlign.right, style: h())),
        ])),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
          itemBuilder: (_, i) {
            final r = rows[i];
            final c = AppUI.money.copyWith(fontWeight: FontWeight.w600, color: AppColors.textSecondary);
            return Container(color: Colors.white, padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 5.h), child: Row(children: [
              Expanded(flex: 3, child: Text(r.feeType, style: AppUI.cell)),
              SizedBox(width: 120.w, child: Text(r.feeAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: c)),
              SizedBox(width: 90.w, child: Text(r.paidAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: c)),
              SizedBox(width: 150.w, child: Padding(padding: EdgeInsets.symmetric(horizontal: 10.w), child: r.editable
                  ? TextField(
                      controller: r.conCtrl,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      style: AppUI.fieldText(context, filled: r.concession > 0),
                      decoration: AppUI.field(context, '0', filled: r.concession > 0, dense: true),
                      onChanged: (val) {
                        final entered = double.tryParse(val.trim());
                        final max = r.feeAmount - r.paidAmount;
                        if (entered != null && entered > max) {
                          final clamped = max.toStringAsFixed(0);
                          r.conCtrl.text = clamped;
                          r.conCtrl.selection = TextSelection.collapsed(offset: clamped.length);
                          _snack('Concession can\'t exceed the unpaid amount (${max.toStringAsFixed(0)}).', AppColors.warning);
                        }
                        setState(() {});
                      },
                    )
                  : r.pendingAmount != null
                      ? Tooltip(
                          message: 'Concession of ${r.pendingAmount!.toStringAsFixed(2)} waiting in Fees → Concession Approval',
                          // Shrinks to the cell rather than overflowing it.
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.hourglass_top_rounded, size: 12.sp, color: AppColors.warning),
                                SizedBox(width: 5.w),
                                Text('${r.pendingAmount!.toStringAsFixed(2)} pending',
                                    style: AppUI.money.copyWith(color: AppColors.warning)),
                              ]),
                            ),
                          ),
                        )
                  : r.isApplied
                      ? Row(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.lock, size: 12.sp, color: AppColors.textLight),
                          SizedBox(width: 5.w),
                          Text(r.appliedAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: AppUI.money.copyWith(color: AppColors.success)),
                        ])
                      : Text('0.00', textAlign: TextAlign.right, style: AppUI.cell.copyWith(color: AppColors.textLight)),
              )),
              SizedBox(width: 120.w, child: Text(r.balance.toStringAsFixed(2), textAlign: TextAlign.right, style: AppUI.money)),
            ]));
          },
        ),
      ]),
    );
  }

  Widget _detailFooter(double totalFee, double totalPaid, double totalCon, double netPayable) {
    Widget tot(String label, double v, Color color) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: AppUI.muted),
          SizedBox(height: 2.h),
          Text(_inr(v), style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w800, color: color)),
        ]);
    // Footer bar: running totals (wrap when the pane is narrow), then Cancel
    // (= close this student, as the old Back arrow did) + Save.
    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        Expanded(
          child: Wrap(spacing: 26.w, runSpacing: 8.h, children: [
            tot('Total Fee Amount', totalFee, AppColors.textPrimary),
            tot('Total Paid', totalPaid, AppColors.today),
            tot('Total Concession', totalCon, AppColors.success),
            tot('Net Payable', netPayable, AppColors.primary),
          ]),
        ),
        SizedBox(width: 12.w),
        AppUI.requiredNote(),
        SizedBox(width: 12.w),
        OutlinedButton(onPressed: _detailSaving ? null : _backToList, child: const Text(AppText.cancel)),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
          onPressed: _detailSaving ? null : _saveConcession,
          icon: _detailSaving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check, size: 16, color: Colors.white),
          // School: every concession waits in Concession Approval.
          label: Text(isSchool ? 'Send for Approval' : (_arrear ? 'Save Write-off' : 'Save Concession')),
        ),
      ]),
    );
  }
}
