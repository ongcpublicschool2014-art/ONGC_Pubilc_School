import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';

/// Section Transfer — move active students between sections (within or across
/// class groups). Pick source standard + section, choose a target section per
/// student (or use Auto Fill), then Save to update students.stuclass /
/// clagrpname in bulk.
class SectionTransferScreen extends StatefulWidget {
  const SectionTransferScreen({super.key});

  @override
  State<SectionTransferScreen> createState() => _SectionTransferScreenState();
}

class _SectionTransferScreenState extends State<SectionTransferScreen> {
  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _standardList = [];
  List<Map<String, dynamic>> _sectionList = [];

  String? _srcStandard;
  String? _srcSection;
  String _orderBy = 'Admission No';
  final Map<int, String?> _rowTarget = {};

  bool _loading = true;
  bool _saving = false;

  static const _orderOptions = ['Admission No', 'Student Name', 'Gender + Student Name'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({int retriesLeft = 1}) async {
    setState(() => _loading = true);
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    // Re-assert the institution schema before querying. The global
    // SupabaseService schema briefly resets to null during auth refresh/login;
    // if _load runs in that window, fromSchema('students') would fall back to
    // the (nonexistent) public.students table, the query throws, and the
    // dropdowns are left empty for the whole session. Pulling the schema from
    // the authoritative AuthProvider keeps the query schema-scoped.
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    try {
      final results = await Future.wait<dynamic>([
        _fetchAllStudents(insId),
        SupabaseService.fromSchema('course')
            .select('cour_id, courname, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('ordid', ascending: true)
            .order('courname', ascending: true),
        SupabaseService.fromSchema('class')
            .select('claname, cour_id, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('ordid', ascending: true)
            .order('claname', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _students = results[0] as List<Map<String, dynamic>>;
        _standardList = List<Map<String, dynamic>>.from(results[1] as List);
        _sectionList = List<Map<String, dynamic>>.from(results[2] as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // A failure here is almost always the transient null-schema window above.
      // Retry once after re-asserting the schema before giving up.
      if (retriesLeft > 0) {
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) await _load(retriesLeft: retriesLeft - 1);
        return;
      }
      setState(() => _loading = false);
      _snack('Failed to load. ${friendlyError(e)}', AppColors.error);
    }
  }

  /// Fetch every active student in 1000-row pages. PostgREST caps a single
  /// response at 1000 rows, so an unpaginated select silently drops students
  /// beyond the first 1000 (here: the higher classes like X/XI/XII), which made
  /// their standards appear to have no students. Mirrors SupabaseService.getStudents.
  Future<List<Map<String, dynamic>>> _fetchAllStudents(int insId) async {
    const batchSize = 1000;
    int offset = 0;
    final all = <Map<String, dynamic>>[];
    while (true) {
      final batch = await SupabaseService.fromSchema('students')
          .select('stu_id, stuadmno, stuname, stugender, courname, stuclass')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('stu_id', ascending: true)
          .range(offset, offset + batchSize - 1);
      final list = (batch as List).cast<Map<String, dynamic>>();
      all.addAll(list);
      if (list.length < batchSize) break;
      offset += batchSize;
    }
    return all;
  }

  List<String> get _standardNames =>
      _standardList.map((e) => e['courname']?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty).toSet().toList();

  List<String> _sectionNamesFor(String? standardName) {
    Iterable<Map<String, dynamic>> src = _sectionList;
    if (standardName != null && standardName.trim().isNotEmpty) {
      final std = _standardList.firstWhere(
        (c) => (c['courname']?.toString().trim() ?? '') == standardName.trim(),
        orElse: () => const {},
      );
      final courId = std['cour_id'];
      src = courId == null ? const <Map<String, dynamic>>[] : _sectionList.where((cl) => cl['cour_id'] == courId);
    }
    return src.map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty).toSet().toList();
  }

  /// Classes students are ACTUALLY in for the selected course, taken from the
  /// student rows (not the class master). The two can differ in spacing/dots
  /// (e.g. student "B.TECH - AI&DS-II" vs master "B.TECH. - AI&DS-II"), so the
  /// source filter must use the student values or nothing matches.
  List<String> _sourceClassNamesFor(String? course) {
    if (course == null || course.trim().isEmpty) return [];
    final set = <String>{};
    for (final s in _students) {
      if ((s['courname']?.toString().trim() ?? '') != course.trim()) continue;
      final c = s['stuclass']?.toString().trim() ?? '';
      if (c.isNotEmpty) set.add(c);
    }
    return set.toList()..sort();
  }

  /// Map class name → owning course (courname). Used on Save so a cross-course
  /// transfer updates both stuclass and courname.
  Map<String, String> get _sectionToStandard {
    final m = <String, String>{};
    final byCour = {for (final s in _standardList) s['cour_id']: s['courname']?.toString().trim() ?? ''};
    for (final c in _sectionList) {
      final name = c['claname']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      m[name] = byCour[c['cour_id']] ?? '';
    }
    return m;
  }

  /// Active students for the chosen source standard. Section is an optional
  /// secondary filter — if left blank, every student under that standard is
  /// listed regardless of their current section.
  List<Map<String, dynamic>> get _rows {
    if (_srcStandard == null) return [];
    final list = _students.where((s) {
      final std = (s['courname']?.toString().trim() ?? '');
      final sec = (s['stuclass']?.toString().trim() ?? '');
      if (std != _srcStandard) return false;
      if (_srcSection != null && _srcSection!.isNotEmpty && sec != _srcSection) return false;
      return true;
    }).toList();
    list.sort((a, b) {
      final an = (a['stuname'] ?? '').toString().toLowerCase();
      final bn = (b['stuname'] ?? '').toString().toLowerCase();
      switch (_orderBy) {
        case 'Student Name':
          return an.compareTo(bn);
        case 'Gender + Student Name':
          final ga = (a['stugender'] ?? '').toString();
          final gb = (b['stugender'] ?? '').toString();
          final s = ga.compareTo(gb);
          return s != 0 ? s : an.compareTo(bn);
        default:
          return (a['stuadmno'] ?? '').toString().compareTo((b['stuadmno'] ?? '').toString());
      }
    });
    return list;
  }

  Future<void> _autoFill() async {
    final options = _sectionNamesFor(_srcStandard).where((s) => s != _srcSection).toList();
    if (options.isEmpty) {
      _snack('No target classes available.', AppColors.warning);
      return;
    }
    String? picked = options.length == 1 ? options.first : null;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Auto Fill target class'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Apply one target class to all ${_rows.length} student(s).',
                  style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
              SizedBox(height: 14.h),
              DropdownButtonFormField<String>(
                initialValue: picked,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Target Class'),
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
      for (final r in _rows) {
        _rowTarget[r['stu_id'] as int] = chosen;
      }
    });
  }

  Future<void> _save() async {
    final toTransfer = _rows.where((r) {
      final t = _rowTarget[r['stu_id'] as int] ?? '';
      return t.isNotEmpty && t != (r['stuclass']?.toString().trim() ?? '');
    }).toList();
    if (toTransfer.isEmpty) {
      _snack('Pick a different target class for at least one student.', AppColors.warning);
      return;
    }
    setState(() => _saving = true);
    int done = 0;
    final failures = <String>[];
    final secToStd = _sectionToStandard;
    for (final r in toTransfer) {
      final stuId = r['stu_id'] as int;
      final target = _rowTarget[stuId]!;
      final targetStd = secToStd[target] ?? (r['courname']?.toString() ?? '');
      try {
        await SupabaseService.updateStudent(stuId, {
          'stuclass': target,
          if (targetStd.isNotEmpty) 'courname': targetStd,
        });
        // Cascade the class change to every fee demand row for this
        // student — otherwise reports still show the old class.
        await SupabaseService.updateDemandClass(stuId, target,
            courname: targetStd.isNotEmpty ? targetStd : null);
        done++;
      } catch (e) {
        failures.add('${r['stuadmno']} ${r['stuname']}: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _rowTarget.clear();
    await _load();
    if (!mounted) return;
    if (failures.isEmpty) {
      _snack('Transferred $done student(s).', AppColors.success);
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Transferred $done, ${failures.length} failed'),
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
          Expanded(child: _standardDropdown()),
          SizedBox(width: 10.w),
          Expanded(child: _sectionDropdown()),
          SizedBox(width: 10.w),
          Expanded(child: _orderDropdown()),
          SizedBox(width: 10.w),
          SizedBox(
            height: btnHeight,
            child: ElevatedButton.icon(
              onPressed: (_srcStandard == null || _rows.isEmpty) ? null : _autoFill,
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
        ],
      ),
    );
  }

  Widget _standardDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _srcStandard,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: 'Course'),
      items: _standardNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) => setState(() {
        _srcStandard = v;
        _srcSection = null;
        _rowTarget.clear();
      }),
    );
  }

  Widget _sectionDropdown() {
    final options = _sourceClassNamesFor(_srcStandard);
    return DropdownButtonFormField<String>(
      initialValue: options.contains(_srcSection) ? _srcSection : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: 'Class'),
      items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: _srcStandard == null ? null : (v) => setState(() {
        _srcSection = v;
        _rowTarget.clear();
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
          Expanded(child: Text('ADMISSION NO', style: s())),
          Expanded(child: Text('STUDENT NAME', style: s())),
          Expanded(child: Text('GENDER', style: s())),
          Expanded(child: Text('CURRENT CLASS', style: s())),
          Expanded(child: Text('TRANSFER TO', style: s())),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_srcStandard == null) {
      return Center(
        child: Text('Pick a Course to list students',
            style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
      );
    }
    final rows = _rows;
    if (rows.isEmpty) {
      final scope = _srcSection?.isNotEmpty == true ? '$_srcStandard / $_srcSection' : '$_srcStandard';
      return Center(
        child: Text('No active students in $scope',
            style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
      );
    }
    // Transfer targets: the class master's classes for the course, unioned with
    // the classes students are actually in (covers the master↔student name gap).
    final targetOptions = <String>{
      ..._sectionNamesFor(_srcStandard),
      ..._sourceClassNamesFor(_srcStandard),
    }.toList()..sort();
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border),
      itemBuilder: (_, i) => _row(rows[i], targetOptions),
    );
  }

  Widget _row(Map<String, dynamic> r, List<String> options) {
    final stuId = r['stu_id'] as int;
    final gender = (r['stugender'] ?? '').toString();
    final genderLabel = gender == 'M' ? 'Male' : gender == 'F' ? 'Female' : (gender.isEmpty ? '—' : gender);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
      child: Row(
        children: [
          Expanded(child: Text((r['stuadmno'] ?? '').toString(), style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary))),
          Expanded(child: Text((r['stuname'] ?? '').toString(), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          Expanded(child: Text(genderLabel, style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
          Expanded(child: Text((r['stuclass'] ?? '—').toString(), style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: 8.w),
              child: DropdownButtonFormField<String>(
                initialValue: options.contains(_rowTarget[stuId]) ? _rowTarget[stuId] : null,
                isExpanded: true,
                isDense: true,
                decoration: _dec(),
                hint: Text('Select class', style: TextStyle(fontSize: 12.sp, color: AppColors.textLight)),
                items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (v) => setState(() => _rowTarget[stuId] = v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar() {
    final count = _rows.where((r) {
      final t = _rowTarget[r['stu_id'] as int] ?? '';
      return t.isNotEmpty && t != (r['stuclass']?.toString().trim() ?? '');
    }).length;
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Row(
        children: [
          if (count > 0)
            Text('$count selected for transfer',
                style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _saving || count == 0 ? null : _save,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Transferring…' : 'Save Transfer'),
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
