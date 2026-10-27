import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';

/// Advance Fee Definition for ONE student -- the advance counterpart of Fee
/// Collection's Student Fee Definition. Two sets, as there:
///   * the student's advance lines (stuadvdemand), ticked; and
///   * Advance Fee Definition lines of their next section / standard that
///     they do not have yet, unticked.
/// Tick to add, untick to remove (not once paid), edit an amount (never below
/// what is paid). "Add Fee" puts in a one-off line. Saved through
/// save_student_advance_definition. Pops true when anything was saved.
class AdvanceFeeDefinitionDialog extends StatefulWidget {
  final Map<String, dynamic> student;
  final int? nextClaId, nextCourId;
  final String nextClassName, nextYear;
  const AdvanceFeeDefinitionDialog({
    super.key,
    required this.student,
    required this.nextClaId,
    required this.nextCourId,
    required this.nextClassName,
    required this.nextYear,
  });

  @override
  State<AdvanceFeeDefinitionDialog> createState() => _AdvanceFeeDefinitionDialogState();
}

class _Row {
  final int? sadId; // null = not yet the student's (available / added)
  final int? afId;
  final String term, feeType;
  final String? due;
  final double paid;
  final double original;
  final String applies; // e.g. "New · Girl" from the definition
  /// An Advance Fee Definition line that applies to the student but is not
  /// saved (shown ticked). Unticking it and saving records an opt-out.
  final bool candidate;
  bool opted;
  final TextEditingController amount;
  _Row({
    required this.sadId,
    required this.afId,
    required this.term,
    required this.feeType,
    required this.due,
    required this.paid,
    required this.original,
    required this.applies,
    required this.opted,
    this.candidate = false,
  }) : amount = TextEditingController(text: original > 0 ? original.toStringAsFixed(0) : '');
  bool get locked => paid > 0.005;
  bool get isNew => sadId == null;
  double get value => double.tryParse(amount.text.trim()) ?? 0;
}

class _AdvanceFeeDefinitionDialogState extends State<AdvanceFeeDefinitionDialog> {
  final List<_Row> _rows = [];
  List<String> _terms = [], _feeTypes = [];
  String? _term; // null = all terms
  bool _loading = true, _saving = false, _saved = false;
  String? _error, _info;
  /// students.stuphoto for the header avatar. From the caller's student map
  /// when it carries one, otherwise looked up once by stu_id.
  String? _photo;

  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPhoto();
  }

  /// Display only: a failure just leaves the initial.
  Future<void> _loadPhoto() async {
    if (widget.student.containsKey('stuphoto')) {
      _photo = widget.student['stuphoto']?.toString();
      return;
    }
    final stuId = widget.student['stu_id'];
    if (stuId == null) return;
    try {
      final row = await SupabaseService.fromSchema('students')
          .select('stuphoto')
          .eq('stu_id', stuId)
          .maybeSingle();
      if (mounted) setState(() => _photo = row?['stuphoto']?.toString());
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.amount.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final insId = context.read<AuthProvider>().insId ?? 1;
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('stuadvdemand').select('*').eq('stu_id', widget.student['stu_id']).eq('activestatus', 1),
        SupabaseService.fromSchema('advfeedemand').select('*').eq('activestatus', 1),
        SupabaseService.fromSchema('semester').select('semname').eq('ins_id', insId).eq('activestatus', 1).order('sem_id'),
        SupabaseService.fromSchema('feetype').select('feedesc').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.client.rpc('preview_student_advance', params: {'p_token': SupabaseService.sessionToken, 'p_stu_id': widget.student['stu_id']}),
      ]);
      final mine = List<Map<String, dynamic>>.from((r[0] as List).cast<Map<String, dynamic>>());
      final defs = List<Map<String, dynamic>>.from((r[1] as List).cast<Map<String, dynamic>>())
          .where((d) =>
              (_id(d['aftype']) == 0 && _id(d['cla_id']) == widget.nextClaId) ||
              (_id(d['aftype']) == 1 && _id(d['cour_id']) == widget.nextCourId))
          .toList()
        // Section-wise before standard-wise, then the more specific first.
        ..sort((a, b) {
          final t = (_id(a['aftype']) ?? 0).compareTo(_id(b['aftype']) ?? 0);
          if (t != 0) return t;
          int spec(Map d) => [d['afnob'], d['afbgb'], d['afdhb']].where((x) => _id(x) != 3).length;
          return spec(b).compareTo(spec(a));
        });
      String applies(Map d) {
        const nob = {1: 'New', 2: 'Old'}, bgb = {1: 'Boy', 2: 'Girl'}, dhb = {1: AppText.dayScholar, 2: AppText.hosteller};
        final p = [nob[_id(d['afnob'])], bgb[_id(d['afbgb'])], dhb[_id(d['afdhb'])]].whereType<String>().toList();
        return p.isEmpty ? 'All Students' : p.join(' · ');
      }

      if (!mounted) return;
      setState(() {
        for (final x in _rows) {
          x.amount.dispose();
        }
        _rows.clear();
        final have = <String>{};
        for (final m in mine) {
          have.add('${m['afterm']}|${m['affeetype']}');
          _rows.add(_Row(
            sadId: _id(m['sad_id']),
            afId: _id(m['af_id']),
            term: '${m['afterm']}',
            feeType: '${m['affeetype']}',
            due: m['duedate']?.toString(),
            paid: _num(m['paidamount']),
            original: _num(m['feeamount']),
            applies: '',
            opted: true,
          ));
        }
        // Applicable but not saved: ticked, as the screen collects them.
        for (final c in (r[4] is List ? r[4] as List : const [])) {
          final m = Map<String, dynamic>.from(c as Map);
          have.add('${m['afterm']}|${m['affeetype']}');
          final d = defs.firstWhere((x) => _id(x['af_id']) == _id(m['af_id']), orElse: () => const {});
          _rows.add(_Row(
            sadId: null,
            afId: _id(m['af_id']),
            term: '${m['afterm']}',
            feeType: '${m['affeetype']}',
            due: m['afduedate']?.toString(),
            paid: 0,
            original: _num(m['afamount']),
            applies: d.isEmpty ? '' : applies(d),
            opted: true,
            candidate: true,
          ));
        }
        for (final d in defs) {
          final k = '${d['afterm']}|${d['affeetype']}';
          if (!have.add(k)) continue; // already the student's, or a less specific variant
          _rows.add(_Row(
            sadId: null,
            afId: _id(d['af_id']),
            term: '${d['afterm']}',
            feeType: '${d['affeetype']}',
            due: d['afduedate']?.toString(),
            paid: 0,
            original: _num(d['afamount']),
            applies: applies(d),
            opted: false,
          ));
        }
        _rows.sort((a, b) {
          if (a.opted != b.opted) return a.opted ? -1 : 1;
          final t = a.term.compareTo(b.term);
          return t != 0 ? t : a.feeType.compareTo(b.feeType);
        });
        _terms = (r[2] as List).map((e) => '${e['semname']}').toList();
        _feeTypes = (r[3] as List).map((e) => '${e['feedesc']}').toList()..sort();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load the advance fee demand. ${friendlyError(e)}';
        });
      }
    }
  }

  List<_Row> get _visible => _term == null ? _rows : _rows.where((r) => r.term == _term).toList();

  double get _toReceive => _rows.where((r) => r.opted).fold(0.0, (t, r) => t + (r.value - r.paid).clamp(0, double.infinity));

  Future<void> _addFee() async {
    String? term = _term ?? (_terms.isNotEmpty ? _terms.first : null), fee;
    final amt = TextEditingController();
    DateTime? due;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add Advance Fee'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: term,
                isExpanded: true,
                style: AppUI.fieldText(ctx),
                decoration: AppUI.field(ctx, schoolTerm('Select semester'), label: schoolTerm('Semester *'), filled: term != null),
                items: [for (final t in _terms) DropdownMenuItem(value: t, child: Text(t))],
                onChanged: (v) => setLocal(() => term = v),
              ),
              SizedBox(height: 10.h),
              DropdownButtonFormField<String>(
                initialValue: fee,
                isExpanded: true,
                style: AppUI.fieldText(ctx),
                decoration: AppUI.field(ctx, 'Select fee type', label: 'Fee Type *', filled: fee != null),
                items: [for (final f in _feeTypes) DropdownMenuItem(value: f, child: Text(f))],
                onChanged: (v) => setLocal(() => fee = v),
              ),
              SizedBox(height: 10.h),
              TextField(
                controller: amt,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                style: AppUI.fieldText(ctx),
                decoration: AppUI.field(ctx, 'Enter amount', label: 'Amount *'),
              ),
              SizedBox(height: 10.h),
              InkWell(
                onTap: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(context: ctx, initialDate: due ?? now, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 3));
                  if (d != null) setLocal(() => due = d);
                },
                child: InputDecorator(
                  decoration: AppUI.field(ctx, '', label: 'Due Date', leadingIcon: 'calendar-1', filled: due != null),
                  child: Text(due == null ? 'Select due date (${AppText.dateHint})' : formatDmy(due),
                      style: AppUI.fieldText(ctx, filled: due != null)),
                ),
              ),
              SizedBox(height: 12.h),
              Align(alignment: Alignment.centerLeft, child: AppUI.requiredNote()),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, term != null && fee != null && (double.tryParse(amt.text.trim()) ?? 0) > 0),
              child: const Text('Add Fee'),
            ),
          ],
        ),
      ),
    );
    final value = double.tryParse(amt.text.trim()) ?? 0;
    amt.dispose();
    if (ok != true || term == null || fee == null) return;
    if (_rows.any((r) => r.term == term && r.feeType == fee)) {
      setState(() => _error = '$fee is already listed for $term -- edit that line instead.');
      return;
    }
    setState(() {
      _error = null;
      _info = null;
      _rows.insert(
          0,
          _Row(
            sadId: null,
            afId: null,
            term: term!,
            feeType: fee!,
            due: due?.toIso8601String().split('T').first,
            paid: 0,
            original: value,
            applies: 'Added manually',
            opted: true,
          ));
    });
  }

  Future<void> _save() async {
    final lines = [
      for (final r in _rows)
        // An applicable line not raised yet: ticked -> raised for the student,
        // unticked -> an opt-out, so it is not raised for them later either.
        if (r.candidate || !r.isNew || r.opted)
          {
            'sad_id': r.sadId,
            'af_id': r.afId,
            'afterm': r.term,
            'affeetype': r.feeType,
            'amount': r.value,
            'duedate': r.due,
            'opted': r.opted,
            'candidate': r.candidate,
          },
    ];
    for (final r in _rows.where((r) => r.opted)) {
      if (r.value <= 0) return setState(() => _error = '${r.term} ${r.feeType}: enter an amount.');
      if (r.value < r.paid) return setState(() => _error = '${r.term} ${r.feeType}: cannot be less than the ${r.paid.toStringAsFixed(2)} already paid.');
    }
    setState(() {
      _saving = true;
      _error = null;
      _info = null;
    });
    try {
      final res = await SupabaseService.client.rpc('save_student_advance_definition', params: {
        'p_token': SupabaseService.sessionToken,
        'p_stu_id': widget.student['stu_id'],
        'p_lines': lines,
      });
      final m = res is Map ? res : const {};
      _saved = true;
      await _load();
      if (mounted) {
        setState(() => _info = 'Advance fee demand saved: ${m['added'] ?? 0} added, ${m['updated'] ?? 0} changed, ${m['removed'] ?? 0} removed.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _close() => Navigator.pop(context, _saved);

  @override
  Widget build(BuildContext context) {
    final s = widget.student;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 920.w,
          height: 600.h,
          child: Column(children: [
            Container(
              padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14.h, 14.w, 14.h),
              decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppColors.divider))),
              child: Row(children: [
                AppUI.iconTile('task-square'),
                SizedBox(width: 12.w),
                StudentAvatar(photoUrl: _photo, name: s['stuname']?.toString() ?? '', size: 44),
                SizedBox(width: 10.w),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('Advance Fee Demand', style: AppUI.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                    SizedBox(height: 2.h),
                    Text(
                      '${s['stuname']}  •  ${s['stuadmno']}  •  ${schoolTerm('Next class')} ${widget.nextClassName}  •  ${widget.nextYear}',
                      style: AppUI.muted,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
                SizedBox(width: 10.w),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _close,
                  icon: const Icon(Icons.close, color: AppColors.textSecondary, size: 20),
                ),
              ]),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      SizedBox(width: 170.w, child: _termList()),
                      const VerticalDivider(width: 1, color: AppColors.divider),
                      Expanded(child: _table()),
                    ]),
            ),
            Divider(height: 1.h, color: AppColors.divider),
            _footer(),
          ]),
        ),
      ),
    );
  }

  Widget _termList() {
    Widget item(String? t) => Material(
          color: _term == t ? AppColors.primaryLight : Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _term = t),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
              child: Text(t ?? schoolTerm('All Semesters'),
                  style: AppUI.body.copyWith(
                      fontWeight: _term == t ? FontWeight.w700 : FontWeight.w500,
                      color: _term == t ? AppColors.primary : AppColors.textPrimary)),
            ),
          ),
        );
    final terms = {..._rows.map((r) => r.term)}.toList()..sort();
    return ListView(children: [item(null), for (final t in terms) item(t)]);
  }

  Widget _table() {
    TextStyle h() => AppUI.tableHead;
    TextStyle c() => AppUI.cell;
    String d(String? v) {
      final x = DateTime.tryParse(v ?? '');
      return x == null ? '-' : formatDmy(x);
    }

    final rows = _visible;
    return Column(children: [
      Container(
        decoration: AppUI.tableHeadBar,
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
        child: Row(children: [
          SizedBox(width: 56.w, child: Text('OPTED', style: h())),
          Expanded(flex: 2, child: Text(schoolTerm('SEMESTER'), style: h())),
          Expanded(flex: 3, child: Text('FEE TYPE', style: h())),
          Expanded(flex: 2, child: Text('APPLIES TO', style: h())),
          SizedBox(width: 90.w, child: Text('DUE DATE', style: h())),
          SizedBox(width: 90.w, child: Text('AMOUNT', textAlign: TextAlign.right, style: h())),
          SizedBox(width: 12.w),
          SizedBox(width: 80.w, child: Text('PAID', textAlign: TextAlign.right, style: h())),
          SizedBox(width: 80.w, child: Text('BALANCE', textAlign: TextAlign.right, style: h())),
        ]),
      ),
      Expanded(
        child: rows.isEmpty
            ? AppUI.empty(
                title: 'No advance fees listed',
                why: widget.nextClaId == null
                    ? schoolTerm('This class has no Class Matching. Set it in Setup → Fee Master → Class Matching, or use Add Fee.')
                    : 'No advance fees defined for ${widget.nextClassName} -- use Add Fee.',
                icon: 'receipt-item')
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.divider),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final bg = r.locked
                      ? AppColors.tableHeadBg
                      : r.isNew
                          ? AppColors.successBg
                          : Colors.white;
                  final live = r.opted || r.locked;
                  return Container(
                    color: bg,
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 2.h),
                    child: Row(children: [
                      SizedBox(
                        width: 56.w,
                        child: r.locked
                            ? Tooltip(message: 'Locked: a payment has already been collected for this fee.', child: Icon(Icons.lock_outline, size: 16.sp, color: AppColors.textSecondary))
                            : Checkbox(
                                value: r.opted,
                                visualDensity: VisualDensity.compact,
                                onChanged: (v) => setState(() {
                                  _error = null;
                                  _info = null;
                                  r.opted = v ?? false;
                                }),
                              ),
                      ),
                      Expanded(flex: 2, child: Text(r.term, style: c())),
                      Expanded(flex: 3, child: Text(r.feeType, style: c().copyWith(fontWeight: FontWeight.w600))),
                      Expanded(flex: 2, child: Text(r.applies.isEmpty ? '—' : r.applies, style: c())),
                      SizedBox(width: 90.w, child: Text(d(r.due), style: c())),
                      SizedBox(
                        width: 90.w,
                        child: TextField(
                          controller: r.amount,
                          textAlign: TextAlign.right,
                          onTap: () => r.amount.selection = TextSelection(baseOffset: 0, extentOffset: r.amount.text.length),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                          style: AppUI.fieldText(context, filled: live),
                          decoration: AppUI.field(context, '0.00', filled: live, dense: true)
                              .copyWith(contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8)),
                          // Typing an amount opts in (one way -- unticking stays
                          // the explicit checkbox, as on Student Fee Definition).
                          onChanged: (v) => setState(() {
                            _error = null;
                            _info = null;
                            if ((double.tryParse(v.trim()) ?? 0) > 0) r.opted = true;
                          }),
                        ),
                      ),
                      SizedBox(width: 12.w),
                      SizedBox(width: 80.w, child: Text(r.paid.toStringAsFixed(2), textAlign: TextAlign.right, style: AppUI.money)),
                      SizedBox(
                        width: 80.w,
                        child: Text((r.opted ? (r.value - r.paid).clamp(0, double.infinity) : 0).toStringAsFixed(2), textAlign: TextAlign.right, style: AppUI.money),
                      ),
                    ]),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _strip(String text, Color color, IconData icon) => Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: 10.h),
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
        decoration: BoxDecoration(
          color: color == AppColors.error ? AppColors.errorBg : AppColors.successBg,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(icon, size: 18.sp, color: color),
          SizedBox(width: 8.w),
          Expanded(child: Text(text, style: AppUI.body.copyWith(fontWeight: FontWeight.w600, color: color))),
        ]),
      );

  Widget _footer() => Padding(
        padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_error != null) _strip(_error!, AppColors.error, Icons.error_outline),
          if (_error == null && _info != null) _strip(_info!, AppColors.success, Icons.check_circle_outline),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _saving || _loading ? null : _addFee,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Fee'),
            ),
            SizedBox(width: 16.w),
            Text('Fees to be Received: ', style: AppUI.label.copyWith(color: AppColors.textSecondary)),
            Text('₹ ${_toReceive.toStringAsFixed(2)}', style: AppUI.money.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.primary)),
            const Spacer(),
            OutlinedButton(onPressed: _close, child: const Text('Cancel')),
            SizedBox(width: 10.w),
            ElevatedButton.icon(
              onPressed: _saving || _loading ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save, size: 16),
              label: const Text('Save'),
            ),
          ]),
        ]),
      );
}
