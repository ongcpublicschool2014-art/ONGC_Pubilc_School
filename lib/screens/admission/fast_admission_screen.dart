import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../services/admission_service.dart';
import '../../widgets/app_icon.dart';

/// Fast Admission — spreadsheet-style bulk entry of PENDING admissions into
/// public.admission. Allocate sections later from the Class Allocation screen
/// (or one-by-one from the main Admission screen).
class FastAdmissionScreen extends StatefulWidget {
  const FastAdmissionScreen({super.key});

  @override
  State<FastAdmissionScreen> createState() => _FastAdmissionScreenState();
}

class _FastRow {
  final regNo = TextEditingController();
  final name = TextEditingController();
  final admYear = TextEditingController();
  String? sex; // M | F | T
  String? admittedStandard;
  String? standard;
  String? section;
  String? medium;
  DateTime? dob;
  DateTime admDate = DateTime.now();

  void dispose() {
    regNo.dispose();
    name.dispose();
    admYear.dispose();
  }

  bool get isBlank => name.text.trim().isEmpty && regNo.text.trim().isEmpty;
}

class _FastAdmissionScreenState extends State<FastAdmissionScreen> {
  final List<_FastRow> _rows = [];
  List<Map<String, dynamic>> _standardList = []; // {cgrp_id, clagrpname}
  List<Map<String, dynamic>> _sectionList = [];  // {claname, cgrp_id}
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _regSeqs = [];
  String? _selectedYrId;
  String? _selectedYrLabel;
  String? _selectedRegSeqId;
  String? _lastRegNo;
  bool _loading = true;
  bool _saving = false;

  static const _sexOptions = {'M': 'Male', 'F': 'Female', 'T': 'Other'};
  static const _mediumOptions = ['English', 'Tamil', 'Hindi', 'French', 'Telugu', 'Malayalam', 'Other'];

  @override
  void initState() {
    super.initState();
    _load();
    _refreshLastRegNo();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    final insId = _insId;
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.client.from('clagrp').select('cgrp_id, clagrpname, ordid').eq('ins_id', insId).eq('activestatus', 1).order('ordid', ascending: true).order('clagrpname', ascending: true),
        SupabaseService.client.from('class').select('claname, cgrp_id, ordid').eq('ins_id', insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
        SupabaseService.client.from('institutionyear').select('iyr_id, yrlabel').eq('ins_id', insId).eq('activestatus', 1).order('iyr_id', ascending: false),
        SupabaseService.client.from('regnoseq').select('*').eq('activestatus', 1).order('rns_id', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _standardList = List<Map<String, dynamic>>.from(results[0] as List);
        _sectionList = List<Map<String, dynamic>>.from(results[1] as List);
        _years = (results[2] as List)
            .map((r) => {'yr_id': r['iyr_id'], 'yrlabel': r['yrlabel']})
            .cast<Map<String, dynamic>>()
            .toList();
        _regSeqs = List<Map<String, dynamic>>.from(results[3] as List);
        if (_years.isNotEmpty) {
          _selectedYrId = _years.first['yr_id'].toString();
          _selectedYrLabel = _years.first['yrlabel']?.toString();
        }
        if (_rows.isEmpty) {
          for (var i = 0; i < 8; i++) {
            _rows.add(_FastRow());
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Failed to load. ${friendlyError(e)}', AppColors.error);
      }
    }
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

  void _addRow() => setState(() => _rows.add(_FastRow()));
  void _removeRow(int i) => setState(() => _rows.removeAt(i).dispose());

  int _seqNext(Map<String, dynamic> seq) {
    final cur = (seq['rnscurrent'] as num?)?.toInt() ?? 0;
    final start = (seq['rnsstart'] as num?)?.toInt() ?? 1;
    return cur < start ? start : cur + 1;
  }

  String _seqFormat(Map<String, dynamic> seq, int n) {
    final width = (seq['rnswidth'] as num?)?.toInt() ?? 0;
    final padded = n.toString().padLeft(width, '0');
    final affix = seq['rnsaffix']?.toString() ?? '';
    return (seq['rnsmode']?.toString() ?? 'P') == 'P' ? '$affix$padded' : '$padded$affix';
  }

  void _autoNumber() {
    if (_selectedRegSeqId == null) {
      _snack('Pick an Admission Sequence first.', AppColors.warning);
      return;
    }
    final seq = _regSeqs.firstWhere((s) => s['rns_id'].toString() == _selectedRegSeqId, orElse: () => const {});
    if (seq.isEmpty) return;
    var n = _seqNext(seq);
    setState(() {
      for (final r in _rows) {
        if (r.isBlank) continue;
        r.regNo.text = _seqFormat(seq, n);
        n++;
      }
    });
  }

  Future<void> _refreshLastRegNo() async {
    try {
      final res = await SupabaseService.client
          .from('admission')
          .select('admno')
          .eq('ins_id', _insId)
          .order('adm_id', ascending: false)
          .limit(1)
          .maybeSingle();
      final last = res?['admno']?.toString();
      if (!mounted) return;
      setState(() => _lastRegNo = (last == null || last.isEmpty) ? null : last);
    } catch (_) {/* keep previous */}
  }

  Future<void> _saveAll() async {
    final auth = context.read<AuthProvider>();
    final entries = _rows.where((r) => !r.isBlank).toList();
    if (entries.isEmpty) {
      _snack('Enter at least one row.', AppColors.warning);
      return;
    }
    final problems = <String>[];
    for (final r in entries) {
      final miss = <String>[];
      if (r.regNo.text.trim().isEmpty) miss.add('Admission No');
      if (r.name.text.trim().isEmpty) miss.add('Name');
      if (r.sex == null) miss.add('Sex');
      if (r.dob == null) miss.add('Birth Date');
      if (miss.isNotEmpty) problems.add('Row ${_rows.indexOf(r) + 1}: ${miss.join(', ')}');
    }
    if (problems.isNotEmpty) {
      _snack('Fill required fields — ${problems.first}${problems.length > 1 ? ' (+${problems.length - 1} more)' : ''}', AppColors.error);
      return;
    }
    setState(() => _saving = true);
    int done = 0;
    final failures = <String>[];
    for (final r in entries) {
      try {
        await AdmissionService.addAdmission({
          'ins_id': auth.insId ?? 1,
          'inscode': auth.inscode ?? '',
          'yr_id': int.tryParse(_selectedYrId ?? '0') ?? 0,
          'yrlabel': _selectedYrLabel ?? '',
          'admno': r.regNo.text.trim(),
          'admdate': r.admDate.toIso8601String().split('T').first,
          'admsource': 'WALK-IN',
          'stuname': r.name.text.trim(),
          'stugender': r.sex,
          'studob': r.dob?.toIso8601String().split('T').first,
          'clagrpname': r.standard,
          'admclagrpname': r.admittedStandard ?? r.standard,
          'stuclass': r.section,
          'medium': r.medium,
          'admittyear': r.admYear.text.trim().isEmpty ? null : r.admYear.text.trim(),
          'createdby': auth.userName,
        });
        done++;
      } catch (e) {
        failures.add('${r.regNo.text.trim()} ${r.name.text.trim()}: ${friendlyError(e)}');
      }
    }
    if (_selectedRegSeqId != null) {
      final seq = _regSeqs.firstWhere((s) => s['rns_id'].toString() == _selectedRegSeqId, orElse: () => const {});
      if (seq.isNotEmpty) {
        final newCurrent = _seqNext(seq) + done - 1;
        try { await AdmissionService.bumpRegSeqCurrent(int.parse(_selectedRegSeqId!), newCurrent); } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _refreshLastRegNo();

    if (failures.isEmpty) {
      _snack('Saved $done admission(s).', AppColors.success);
      for (final r in _rows) {
        r.dispose();
      }
      setState(() {
        _rows.clear();
        for (var i = 0; i < 8; i++) {
          _rows.add(_FastRow());
        }
        _selectedRegSeqId = null;
      });
      _load();
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Saved $done, ${failures.length} failed'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [for (final f in failures) Padding(padding: EdgeInsets.only(bottom: 4.h), child: Text('• $f', style: TextStyle(fontSize: 12.sp, color: AppColors.error)))],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  static const _wReg = 120.0, _wName = 180.0, _wSex = 70.0,
      _wAdmStd = 140.0, _wStd = 140.0, _wSec = 120.0, _wMed = 100.0,
      _wDob = 110.0, _wAdm = 110.0, _wYear = 80.0, _wDel = 40.0;
  static const _wTotal = _wReg + _wName + _wSex + _wAdmStd + _wStd + _wSec + _wMed + _wDob + _wAdm + _wYear + _wDel + 32;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                _header(),
                _toolbar(),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16.w, 4.h, 16.w, 8.h),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : LayoutBuilder(
                              builder: (ctx, c) {
                                final scale = c.maxWidth > _wTotal ? c.maxWidth / _wTotal : 1.0;
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SizedBox(
                                    width: _wTotal * scale,
                                    child: Column(
                                      children: [
                                        _tableHeader(scale),
                                        Expanded(
                                          child: ListView.builder(
                                            itemCount: _rows.length,
                                            itemBuilder: (_, i) => _rowWidget(i, scale),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ),
                _actionBar(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _header() {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final btnHeight = compact ? 30.0 : 40.0;
    final btnIcon = compact ? 12.0 : 16.0;
    final btnHPad = compact ? 10.0 : 18.0;
    final btnRadius = compact ? 6.0 : 10.0;
    final btnText = compact ? 11.0 : 13.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 14.h, 16.w, 14.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AppIcon('profile-add', size: 20, color: AppColors.primary),
          SizedBox(width: 10.w),
          Text('Fast Admission',
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(width: 10.w),
          Text('bulk entry — allocate sections later',
              style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          SizedBox(width: 200.w, child: _regSeqDropdown()),
          SizedBox(width: 10.w),
          _lastRegNoChip(),
          SizedBox(width: 10.w),
          SizedBox(
            height: btnHeight,
            child: ElevatedButton.icon(
              onPressed: _autoNumber,
              icon: AppIcon('document-text', size: btnIcon, color: Colors.white),
              label: const Text('Fill Admission Nos'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: btnHPad),
                textStyle: TextStyle(fontSize: btnText, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(btnRadius)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Toolbar merged into the header above. Kept as an empty stub so the
  /// existing build call remains valid.
  Widget _toolbar() => const SizedBox.shrink();

  /// Filled input decoration matching the Master Data / Fee Concession form
  /// style — placeholder hint inside, white fill, accent focus border.
  InputDecoration _filledFieldDec(String hint) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final textSize = compact ? 11.0 : 14.0;
    final hPad = compact ? 8.0 : 14.0;
    final vPad = compact ? 5.0 : 14.0;
    final radius = compact ? 5.0 : 8.0;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.accent)),
      filled: true,
      fillColor: Colors.white,
    );
  }

  Widget _regSeqDropdown() => DropdownButtonFormField<String>(
        initialValue: _selectedRegSeqId,
        isExpanded: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
        decoration: _filledFieldDec('Select Sequence'),
        items: _regSeqs.map((s) => DropdownMenuItem(value: s['rns_id'].toString(), child: Text(s['rnsname']?.toString() ?? '', overflow: TextOverflow.ellipsis))).toList(),
        onChanged: (v) => setState(() => _selectedRegSeqId = v),
      );

  Widget _lastRegNoChip() => InkWell(
        onTap: _refreshLastRegNo,
        borderRadius: BorderRadius.circular(8.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8.r),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.20)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history, size: 14.sp, color: AppColors.primary),
              SizedBox(width: 6.w),
              Text('Last Admission No: ', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
              Text(_lastRegNo ?? '—',
                  style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ],
          ),
        ),
      );

  Widget _tableHeader(double scale) {
    TextStyle s() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
    Widget c(String t, double w) => SizedBox(width: w * scale, child: Padding(padding: EdgeInsets.symmetric(horizontal: 6.w), child: Text(t, style: s())));
    return Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      child: Row(
        children: [
          c('ADMISSION NO', _wReg), c('STUDENT NAME', _wName), c('SEX', _wSex),
          c('ADMITTED STD', _wAdmStd), c('STANDARD', _wStd), c('SECTION', _wSec), c('MEDIUM', _wMed),
          c('BIRTH DATE', _wDob), c('JOIN DATE', _wAdm), c('ADM YEAR', _wYear),
          c('', _wDel),
        ],
      ),
    );
  }

  Widget _rowWidget(int i, double scale) {
    final r = _rows[i];
    return Container(
      decoration: BoxDecoration(
        color: i.isEven ? Colors.white : AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.4))),
      ),
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
      child: Row(
        children: [
          _cell(_wReg * scale, _textCell(r.regNo)),
          _cell(_wName * scale, _textCell(r.name)),
          _cell(_wSex * scale, _dropCell(r.sex, _sexOptions.entries.map((e) => MapEntry(e.key, e.key)).toList(), (v) => setState(() => r.sex = v))),
          _cell(_wAdmStd * scale, _dropCell(r.admittedStandard, _standardNames.map((e) => MapEntry(e, e)).toList(), (v) => setState(() => r.admittedStandard = v))),
          _cell(_wStd * scale, _dropCell(r.standard, _standardNames.map((e) => MapEntry(e, e)).toList(), (v) => setState(() {
                r.standard = v;
                if (r.section != null && !_sectionNamesFor(v).contains(r.section)) {
                  r.section = null;
                }
              }))),
          _cell(_wSec * scale, _dropCell(r.section, _sectionNamesFor(r.standard).map((e) => MapEntry(e, e)).toList(), (v) => setState(() => r.section = v))),
          _cell(_wMed * scale, _dropCell(r.medium, _mediumOptions.map((e) => MapEntry(e, e)).toList(), (v) => setState(() => r.medium = v))),
          _cell(_wDob * scale, _dateCell(r.dob, (d) => setState(() => r.dob = d))),
          _cell(_wAdm * scale, _dateCell(r.admDate, (d) => setState(() => r.admDate = d))),
          _cell(_wYear * scale, _textCell(r.admYear)),
          _cell(_wDel * scale, Center(
            child: InkWell(
              onTap: () => _removeRow(i),
              borderRadius: BorderRadius.circular(6.r),
              child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 15, color: AppColors.error)),
            ),
          )),
        ],
      ),
    );
  }

  Widget _cell(double w, Widget child) => SizedBox(width: w, child: Padding(padding: EdgeInsets.symmetric(horizontal: 3.w), child: child));

  /// Cell decoration — compact bordered cells matching the project's other
  /// inline-edit tables. Thin border, small radius, tight padding for a
  /// dense bulk-entry feel.
  InputDecoration _cellDec() => InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5.r),
          borderSide: BorderSide(color: AppColors.border.withValues(alpha: 0.6)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5.r),
          borderSide: BorderSide(color: AppColors.border.withValues(alpha: 0.6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5.r),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      );

  Widget _textCell(TextEditingController c) => TextField(
        controller: c,
        style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary),
        decoration: _cellDec(),
      );

  Widget _dropCell(String? value, List<MapEntry<String, String>> items, ValueChanged<String?> onChanged) {
    final values = items.map((e) => e.key).toList();
    return DropdownButtonFormField<String>(
      initialValue: values.contains(value) ? value : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary),
      decoration: _cellDec(),
      items: items.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.sp)))).toList(),
      onChanged: onChanged,
    );
  }

  Widget _dateCell(DateTime? value, ValueChanged<DateTime> onPick) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(context: context, initialDate: value ?? DateTime(now.year - 14), firstDate: DateTime(1950), lastDate: DateTime(now.year + 5));
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: _cellDec(),
        child: Text(value == null ? '—' : _fmt(value), style: TextStyle(fontSize: 12.sp, color: value == null ? AppColors.textLight : AppColors.textPrimary)),
      ),
    );
  }

  String _fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  Widget _actionBar() {
    final count = _rows.where((r) => !r.isBlank).length;
    return Padding(
      padding: EdgeInsets.all(12.w),
      child: Row(
        children: [
          OutlinedButton.icon(onPressed: _addRow, icon: const Icon(Icons.add, size: 16), label: const Text('Add Row')),
          SizedBox(width: 10.w),
          Text('$count filled', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _saving || count == 0 ? null : _saveAll,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Saving…' : 'Save All'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }
}
