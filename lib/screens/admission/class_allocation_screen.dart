import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../services/admission_service.dart';
import '../../models/admission_model.dart';
import '../../widgets/app_icon.dart';

/// Section Allocation — batch-allocate PENDING admissions into sections.
/// Pick a Standard, assign each student a Section in the grid, then Save
/// to move them all into students/parents/parentdetail at once.
class ClassAllocationScreen extends StatefulWidget {
  const ClassAllocationScreen({super.key});

  @override
  State<ClassAllocationScreen> createState() => _ClassAllocationScreenState();
}

class _ClassAllocationScreenState extends State<ClassAllocationScreen> {
  List<AdmissionModel> _pending = [];
  List<Map<String, dynamic>> _standardList = [];
  List<Map<String, dynamic>> _sectionList = [];

  String? _selectedStandard;
  String _orderBy = 'Admission No';
  final Map<int, String?> _rowSection = {};
  bool _loading = true;
  bool _saving = false;

  static const _orderOptions = ['Admission No', 'Student Name', 'Sex + Student Name'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    final insId = _insId;
    try {
      final results = await Future.wait<dynamic>([
        AdmissionService.getAdmissions(insId),
        SupabaseService.client.from('clagrp').select('cgrp_id, clagrpname, ordid').eq('ins_id', insId).eq('activestatus', 1).order('ordid', ascending: true).order('clagrpname', ascending: true),
        SupabaseService.client.from('class').select('claname, cgrp_id, ordid').eq('ins_id', insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _pending = (results[0] as List<AdmissionModel>).where((a) => a.isPending).toList();
        _standardList = List<Map<String, dynamic>>.from(results[1] as List);
        _sectionList = List<Map<String, dynamic>>.from(results[2] as List);
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

  /// Pending admissions for the selected standard, sorted by Order By.
  List<AdmissionModel> get _rows {
    if (_selectedStandard == null) return [];
    final list = _pending
        .where((a) => (a.clagrpname?.trim() ?? '') == _selectedStandard)
        .toList();
    list.sort((a, b) {
      switch (_orderBy) {
        case 'Student Name':
          return a.stuname.toLowerCase().compareTo(b.stuname.toLowerCase());
        case 'Sex + Student Name':
          final s = a.stugender.compareTo(b.stugender);
          return s != 0 ? s : a.stuname.toLowerCase().compareTo(b.stuname.toLowerCase());
        default:
          return a.admno.compareTo(b.admno);
      }
    });
    return list;
  }

  Future<void> _autoFill() async {
    final options = _sectionNamesFor(_selectedStandard);
    if (options.isEmpty) {
      _snack('No sections available for $_selectedStandard.', AppColors.warning);
      return;
    }
    String? picked = options.length == 1 ? options.first : null;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Auto Fill section'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Apply one section to all ${_rows.length} student(s) in $_selectedStandard.',
                  style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
              SizedBox(height: 14.h),
              DropdownButtonFormField<String>(
                initialValue: picked,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Section'),
                items: options.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => setLocal(() => picked = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () { if (picked != null) Navigator.pop(ctx, picked); },
              child: const Text('Apply to all'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    setState(() {
      for (final a in _rows) {
        _rowSection[a.admId] = chosen;
      }
    });
  }

  Future<void> _save() async {
    final toAllocate = _rows.where((a) => (_rowSection[a.admId] ?? '').isNotEmpty).toList();
    if (toAllocate.isEmpty) {
      _snack('Assign a section to at least one student first.', AppColors.warning);
      return;
    }
    final by = context.read<AuthProvider>().userName;
    setState(() => _saving = true);
    int done = 0;
    final failures = <String>[];
    for (final a in toAllocate) {
      try {
        await AdmissionService.allocateClass(
          admId: a.admId,
          className: _rowSection[a.admId]!,
          stuadmno: a.admno,
          allocatedBy: by,
        );
        done++;
      } catch (e) {
        failures.add('${a.admno} ${a.stuname}: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _rowSection.clear();
    await _load();
    if (!mounted) return;
    if (failures.isEmpty) {
      _snack('Allocated $done student(s).', AppColors.success);
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Allocated $done, ${failures.length} failed'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [for (final f in failures) Padding(
                  padding: EdgeInsets.only(bottom: 4.h),
                  child: Text('• $f', style: TextStyle(fontSize: 12.sp, color: AppColors.error)),
                )],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

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
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16.w, 4.h, 16.w, 8.h),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        children: [
                          _tableHeader(),
                          Expanded(child: _body()),
                        ],
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
          const AppIcon('book-1', size: 20, color: AppColors.primary),
          SizedBox(width: 10.w),
          Text('Section Allocation',
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(width: 10.w),
          Text('Admitted — pending allocation',
              style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          SizedBox(width: 180.w, child: _standardDropdown()),
          SizedBox(width: 10.w),
          SizedBox(width: 160.w, child: _orderDropdown()),
          SizedBox(width: 10.w),
          SizedBox(
            height: btnHeight,
            child: ElevatedButton.icon(
              onPressed: _selectedStandard == null ? null : _autoFill,
              icon: Icon(Icons.auto_fix_high, size: btnIcon, color: Colors.white),
              label: const Text('Auto Fill'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.border,
                disabledForegroundColor: AppColors.textSecondary,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: btnHPad),
                textStyle: TextStyle(fontSize: btnText, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(btnRadius)),
              ),
            ),
          ),
          SizedBox(width: 12.w),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Text('${_pending.length} pending',
                style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.warning)),
          ),
        ],
      ),
    );
  }

  Widget _miniLabel(String t) => Text(t,
      style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary));

  Widget _standardDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _selectedStandard,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: 'Select Standard'),
      items: _standardNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) => setState(() {
        _selectedStandard = v;
        _rowSection.clear();
      }),
    );
  }

  Widget _orderDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _orderBy,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: 'Order By'),
      items: _orderOptions.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
      onChanged: (v) => setState(() => _orderBy = v ?? 'Admission No'),
    );
  }

  Widget _tableHeader() {
    TextStyle s() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
    return Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
      child: Row(
        children: [
          SizedBox(width: 140.w, child: Text('ADMISSION NO', style: s())),
          Expanded(flex: 3, child: Text('STUDENT NAME', style: s())),
          SizedBox(width: 80.w, child: Text('SEX', style: s())),
          Expanded(flex: 2, child: Text('STANDARD', style: s())),
          SizedBox(width: 220.w, child: Text('SECTION', style: s())),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_selectedStandard == null) {
      return Center(
        child: Text('Select a standard to list admitted students',
            style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
      );
    }
    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Text('No pending admissions for $_selectedStandard',
            style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
      );
    }
    final options = _sectionNamesFor(_selectedStandard);
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border),
      itemBuilder: (_, i) => _row(rows[i], options),
    );
  }

  Widget _row(AdmissionModel a, List<String> options) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
      child: Row(
        children: [
          SizedBox(width: 140.w, child: Text(a.admno, style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary))),
          Expanded(flex: 3, child: Text(a.stuname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          SizedBox(width: 80.w, child: Text(a.genderLabel, style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
          Expanded(flex: 2, child: Text(a.clagrpname ?? '—', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
          SizedBox(
            width: 220.w,
            child: DropdownButtonFormField<String>(
              initialValue: options.contains(_rowSection[a.admId]) ? _rowSection[a.admId] : null,
              isExpanded: true,
              isDense: true,
              decoration: _dec(),
              hint: Text('Select section', style: TextStyle(fontSize: 12.sp, color: AppColors.textLight)),
              items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() => _rowSection[a.admId] = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar() {
    final count = _rows.where((a) => (_rowSection[a.admId] ?? '').isNotEmpty).length;
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Row(
        children: [
          if (count > 0)
            Text('$count selected for allocation',
                style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _saving || count == 0 ? null : _save,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Allocating…' : 'Save Allocation'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  InputDecoration _dec({String? hint}) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final textSize = compact ? 11.0 : 14.0;
    final hPad = compact ? 8.0 : 14.0;
    final vPad = compact ? 5.0 : 14.0;
    final radius = compact ? 5.0 : 8.0;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.accent)),
    );
  }
}
