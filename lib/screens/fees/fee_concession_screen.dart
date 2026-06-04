import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';

/// Fee Concession — per-student concession entry. Look up a student, see every
/// unpaid fee demand, enter a concession per fee type (balance updates live),
/// then Save to write conamount + balancedue back to feedemand.
class FeeConcessionScreen extends StatefulWidget {
  const FeeConcessionScreen({super.key});

  @override
  State<FeeConcessionScreen> createState() => _FeeConcessionScreenState();
}

class _ConRow {
  final int demId;
  final String feeType;
  final String term;
  final String section;
  final double feeAmount;
  final double paidAmount;
  final TextEditingController conCtrl;
  _ConRow({
    required this.demId,
    required this.feeType,
    required this.term,
    required this.section,
    required this.feeAmount,
    required this.paidAmount,
    required double concession,
  }) : conCtrl = TextEditingController(text: concession > 0 ? concession.toStringAsFixed(0) : '');

  double get concession {
    final c = double.tryParse(conCtrl.text.trim()) ?? 0;
    final max = feeAmount - paidAmount;
    return c < 0 ? 0 : (c > max ? max : c);
  }

  double get balance {
    final b = feeAmount - paidAmount - concession;
    return b > 0 ? b : 0;
  }

  void dispose() => conCtrl.dispose();
}

class _FeeConcessionScreenState extends State<FeeConcessionScreen> {
  final _searchCtrl = TextEditingController();
  Map<String, dynamic>? _student;
  List<_ConRow> _rows = [];
  List<Map<String, dynamic>> _suggestions = [];
  List<Map<String, dynamic>> _conTypes = [];
  String? _conTypeId;
  bool _searching = false, _loading = false, _saving = false;
  String? _error;

  // Filter-by-class state. Both lists are loaded once from public masters; the
  // section list is derived from the chosen Standard.
  List<Map<String, dynamic>> _standardList = []; // {cgrp_id, clagrpname}
  List<Map<String, dynamic>> _sectionList = [];  // {claname, cgrp_id}
  String? _selectedStandard;
  String? _selectedSection;

  @override
  void initState() {
    super.initState();
    _loadConTypes();
    _loadStandardsSections();
  }

  Future<void> _loadStandardsSections() async {
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.client.from('clagrp').select('cgrp_id, clagrpname, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('clagrpname', ascending: true),
        SupabaseService.client.from('class').select('claname, cgrp_id, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _standardList = List<Map<String, dynamic>>.from(results[0] as List);
        _sectionList = List<Map<String, dynamic>>.from(results[1] as List);
      });
    } catch (_) {}
  }

  List<String> get _standardNames =>
      (_standardList.map((e) => e['clagrpname']?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty).toSet().toList());

  List<String> _sectionNamesFor(String? standardName) {
    Iterable<Map<String, dynamic>> src = _sectionList;
    if (standardName != null && standardName.trim().isNotEmpty) {
      final std = _standardList.firstWhere(
        (c) => (c['clagrpname']?.toString().trim() ?? '') == standardName.trim(),
        orElse: () => const {},
      );
      final cgrpId = std['cgrp_id'];
      src = cgrpId == null ? const <Map<String, dynamic>>[] : _sectionList.where((cl) => cl['cgrp_id'] == cgrpId);
    }
    return (src.map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty).toSet().toList());
  }

  /// Fetch students matching the Standard / Section filter into the
  /// suggestions list (same widget used by the name/admno search).
  Future<void> _loadFromFilter() async {
    if (_selectedStandard == null && _selectedSection == null) return;
    try {
      var query = SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, clagrpname')
          .eq('ins_id', _insId)
          .eq('activestatus', 1);
      if (_selectedStandard != null) {
        query = query.eq('clagrpname', _selectedStandard!);
      }
      if (_selectedSection != null) {
        query = query.eq('stuclass', _selectedSection!);
      }
      final rows = await query.order('stuname', ascending: true).limit(50);
      if (mounted) setState(() => _suggestions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

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

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _suggest(String q) async {
    final term = q.trim();
    if (term.length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, clagrpname')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .or('stuadmno.ilike.$term%,stuname.ilike.%$term%')
          .limit(10);
      if (mounted) setState(() => _suggestions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  void _pick(Map<String, dynamic> s) {
    _searchCtrl.text = s['stuadmno']?.toString() ?? '';
    setState(() => _suggestions = []);
    _load(s);
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _suggestions = [];
    });
    try {
      var rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, clagrpname')
          .eq('ins_id', _insId)
          .eq('stuadmno', q)
          .eq('activestatus', 1)
          .limit(1);
      if ((rows as List).isEmpty) {
        rows = await SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, clagrpname')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .ilike('stuname', '%$q%')
            .limit(1);
      }
      if ((rows as List).isEmpty) {
        setState(() {
          _error = 'No student found matching "$q"';
          _searching = false;
          _student = null;
        });
        return;
      }
      await _load(Map<String, dynamic>.from(rows.first as Map));
    } catch (e) {
      setState(() {
        _error = friendlyError(e);
        _searching = false;
      });
    }
  }

  Future<void> _load(Map<String, dynamic> student) async {
    setState(() {
      _searching = false;
      _loading = true;
      _student = student;
      for (final r in _rows) {
        r.dispose();
      }
      _rows = [];
    });
    try {
      final admno = student['stuadmno']?.toString() ?? '';
      final res = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuclass, demfeeterm, demfeetype, feeamount, conamount, paidamount, balancedue, con_id')
          .eq('ins_id', _insId)
          .eq('stuadmno', admno)
          .eq('activestatus', 1)
          .eq('paidstatus', 'U')
          .order('demfeeterm', ascending: true)
          .order('demfeetype', ascending: true);
      final list = (res as List).map((e) {
        final m = e as Map<String, dynamic>;
        return _ConRow(
          demId: m['dem_id'] is int ? m['dem_id'] as int : int.tryParse(m['dem_id'].toString()) ?? 0,
          feeType: m['demfeetype']?.toString() ?? '',
          term: m['demfeeterm']?.toString() ?? '',
          section: m['stuclass']?.toString() ?? '',
          feeAmount: (m['feeamount'] as num?)?.toDouble() ?? 0,
          paidAmount: (m['paidamount'] as num?)?.toDouble() ?? 0,
          concession: (m['conamount'] as num?)?.toDouble() ?? 0,
        );
      }).toList();
      // Pre-select the concession type already on the student's demands (if any).
      String? existingConId;
      for (final e in res) {
        final cid = (e as Map)['con_id'];
        if (cid != null) {
          existingConId = cid.toString();
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _rows = list;
        if (existingConId != null && _conTypes.any((t) => t['con_id'].toString() == existingConId)) {
          _conTypeId = existingConId;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  double get _totalCon => _rows.fold(0.0, (s, r) => s + r.concession);
  double get _totalBal => _rows.fold(0.0, (s, r) => s + r.balance);
  double get _totalDef => _rows.fold(0.0, (s, r) => s + r.feeAmount);

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() => _saving = true);
    try {
      final conId = _conTypeId != null ? int.tryParse(_conTypeId!) : null;
      for (final r in _rows) {
        await SupabaseService.fromSchema('feedemand').update({
          'con_id': r.concession > 0 ? conId : null,
          'conamount': r.concession,
          'balancedue': r.balance,
          'reconbalancedue': r.balance,
        }).eq('dem_id', r.demId);
      }
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Concession saved.', AppColors.success);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('Save failed. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  void _clear() {
    setState(() {
      _searchCtrl.clear();
      _student = null;
      for (final r in _rows) {
        r.dispose();
      }
      _rows = [];
      _suggestions = [];
      _selectedStandard = null;
      _selectedSection = null;
      _error = null;
    });
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppCard.decoration(),
      margin: EdgeInsets.all(8.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Divider(height: 1.h, color: AppColors.border),
          _lookup(),
          if (_student != null) ...[
            Divider(height: 1.h, color: AppColors.border),
            Expanded(child: _grid()),
            Divider(height: 1.h, color: AppColors.border),
            _footer(),
          ] else
            Expanded(
              child: Center(
                child: Text(_error ?? 'Search a student by Admission No or Name',
                    style: TextStyle(fontSize: 13.sp, color: _error != null ? AppColors.error : AppColors.textSecondary)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(18.w, 14.h, 18.w, 14.h),
        child: Row(children: [
          const AppIcon('receipt-discount', size: 20, color: AppColors.primary),
          SizedBox(width: 10.w),
          Text('Fee Concession', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(width: 10.w),
          Text("apply concession against a student's fee demands",
              style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
        ]),
      );

  Widget _lookup() {
    return Padding(
      padding: EdgeInsets.all(12.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(
              width: 340.w,
              child: TextField(
                controller: _searchCtrl,
                style: TextStyle(fontSize: 13.sp),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Admission No or Student Name',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
                ),
                onChanged: _suggest,
                onSubmitted: (_) => _search(),
              ),
            ),
            SizedBox(width: 10.w),
            ElevatedButton.icon(
              onPressed: _searching ? null : _search,
              icon: const Icon(Icons.search, size: 16),
              label: const Text('Search'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
            ),
            SizedBox(width: 10.w),
            OutlinedButton.icon(onPressed: _clear, icon: const Icon(Icons.clear, size: 16), label: const Text('Clear')),
            SizedBox(width: 16.w),
            Text('Concession Type', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            SizedBox(width: 8.w),
            SizedBox(
              width: 200.w,
              child: DropdownButtonFormField<String>(
                initialValue: _conTypeId,
                isExpanded: true,
                style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
                ),
                hint: Text('Select', style: TextStyle(fontSize: 12.sp, color: AppColors.textLight)),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('None')),
                  ..._conTypes.map((t) => DropdownMenuItem(value: t['con_id'].toString(), child: Text(t['condesc']?.toString() ?? '', overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) => setState(() => _conTypeId = v),
              ),
            ),
            const Spacer(),
            if (_student != null) _studentChip(),
          ]),
          SizedBox(height: 10.h),
          Row(children: [
            Text('Standard', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            SizedBox(width: 8.w),
            SizedBox(
              width: 200.w,
              child: DropdownButtonFormField<String>(
                initialValue: _standardNames.contains(_selectedStandard) ? _selectedStandard : null,
                isExpanded: true,
                style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
                ),
                hint: Text('All', style: TextStyle(fontSize: 12.sp, color: AppColors.textLight)),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('All')),
                  ..._standardNames.map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) => setState(() {
                  _selectedStandard = v;
                  if (_selectedSection != null && !_sectionNamesFor(v).contains(_selectedSection)) {
                    _selectedSection = null;
                  }
                  _loadFromFilter();
                }),
              ),
            ),
            SizedBox(width: 16.w),
            Text('Section', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            SizedBox(width: 8.w),
            SizedBox(
              width: 180.w,
              child: DropdownButtonFormField<String>(
                initialValue: _sectionNamesFor(_selectedStandard).contains(_selectedSection) ? _selectedSection : null,
                isExpanded: true,
                style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
                ),
                hint: Text('All', style: TextStyle(fontSize: 12.sp, color: AppColors.textLight)),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('All')),
                  ..._sectionNamesFor(_selectedStandard).map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) => setState(() {
                  _selectedSection = v;
                  _loadFromFilter();
                }),
              ),
            ),
            const Spacer(),
          ]),
          if (_suggestions.isNotEmpty)
            Container(
              margin: EdgeInsets.only(top: 6.h),
              constraints: BoxConstraints(maxHeight: 220.h, maxWidth: 340.w),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(color: AppColors.border),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8)],
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in _suggestions)
                    InkWell(
                      onTap: () => _pick(s),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                        child: Row(children: [
                          Expanded(child: Text('${s['stuname']} • ${s['stuadmno']}',
                              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary))),
                          Text(s['stuclass']?.toString() ?? '', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _studentChip() {
    final s = _student!;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.person, size: 14, color: AppColors.primary),
        SizedBox(width: 6.w),
        Text('${s['stuname']}', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
        SizedBox(width: 8.w),
        Text('${s['stuadmno']}  •  ${s['stuclass'] ?? ''}', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
      ]),
    );
  }

  Widget _grid() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return Center(child: Text('No unpaid fee demands for this student',
          style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)));
    }
    TextStyle h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
    TextStyle c() => TextStyle(fontSize: 12.sp, color: AppColors.textSecondary);
    return Column(
      children: [
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
          child: Row(children: [
            SizedBox(width: 80.w, child: Text('TERM', style: h())),
            Expanded(flex: 3, child: Text('FEE TYPE', style: h())),
            SizedBox(width: 110.w, child: Text('FEE DEF', textAlign: TextAlign.right, style: h())),
            SizedBox(width: 130.w, child: Text('CONCESSION', textAlign: TextAlign.right, style: h())),
            SizedBox(width: 110.w, child: Text('BALANCE', textAlign: TextAlign.right, style: h())),
          ]),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _rows.length,
            separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
            itemBuilder: (_, i) {
              final r = _rows[i];
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 4.h),
                child: Row(children: [
                  SizedBox(width: 80.w, child: Text(r.term, style: c())),
                  Expanded(flex: 3, child: Text(r.feeType, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
                  SizedBox(width: 110.w, child: Text(r.feeAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: c())),
                  SizedBox(
                    width: 130.w,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.w),
                      child: TextField(
                        controller: r.conCtrl,
                        textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                        style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r)),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
                  SizedBox(width: 110.w, child: Text(r.balance.toStringAsFixed(2), textAlign: TextAlign.right, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
                ]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _footer() {
    Widget tot(String label, double v, Color color) => Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label  ', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          Text(v.toStringAsFixed(2), style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: color)),
        ]);
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Row(children: [
        tot('Total Fee:', _totalDef, AppColors.textPrimary),
        SizedBox(width: 24.w),
        tot('Concession:', _totalCon, AppColors.accentDark),
        SizedBox(width: 24.w),
        tot('Balance:', _totalBal, AppColors.primary),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save, size: 16),
          label: const Text('Save Concession'),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.success, foregroundColor: Colors.white),
        ),
      ]),
    );
  }
}
