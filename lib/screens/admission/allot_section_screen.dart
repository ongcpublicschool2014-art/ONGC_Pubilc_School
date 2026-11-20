import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_dropdown_field.dart';

/// Admission -> Allot Section (school, principal / Admin).
///
/// A pre-admission (e.g. X -> XI, admitted before the results) is placed in its
/// STANDARD only (Class Allocation -> "XI (section later)"). After the results
/// the student asks the principal for a section; once the principal agrees it
/// is allotted here. A student of this year then gets the section's fees,
/// staged for Fee Demand Approval; a pre-admission gets them from the new year.
/// Advance taken meanwhile stays as an advance, to be adjusted against them.
/// Server side: section_pending_list / allot_section_secure
/// (school_preadmission_standard.sql).
class AllotSectionScreen extends StatefulWidget {
  const AllotSectionScreen({super.key});

  @override
  State<AllotSectionScreen> createState() => _AllotSectionScreenState();
}

class _AllotSectionScreenState extends State<AllotSectionScreen> {
  bool _loading = true, _saving = false;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _sections = []; // cla_id, claname, cour_id
  String? _standard; // courname filter
  int? _section; // cla_id to allot
  final Set<int> _ticked = {};
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static int? _id(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final insId = context.read<AuthProvider>().insId ?? 0;
      final r = await Future.wait<dynamic>([
        SupabaseService.client.rpc('section_pending_list', params: {'p_token': SupabaseService.sessionToken}),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
      ]);
      if (!mounted) return;
      setState(() {
        _rows = [for (final x in (r[0] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
        _sections = List<Map<String, dynamic>>.from(r[1] as List)..sort((a, b) => '${a['claname']}'.compareTo('${b['claname']}'));
        _ticked.removeWhere((id) => !_rows.any((x) => _id(x['stu_id']) == id));
        if (_standard != null && !_standards.contains(_standard)) _standard = null;
        _standard ??= _standards.length == 1 ? _standards.first : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load the students waiting for a section. ${friendlyError(e)}', AppColors.error);
    }
  }

  List<String> get _standards => {for (final x in _rows) '${x['courname'] ?? ''}'}.where((s) => s.isNotEmpty).toList()..sort();

  int? get _courId {
    final r = _rows.where((x) => '${x['courname']}' == _standard);
    return r.isEmpty ? null : _id(r.first['cour_id']);
  }

  List<Map<String, dynamic>> get _sectionsOfStandard => [for (final s in _sections) if (_id(s['cour_id']) == _courId) s];

  List<Map<String, dynamic>> get _visible {
    final q = _search.text.trim().toLowerCase();
    return _rows.where((x) {
      if (_standard != null && '${x['courname']}' != _standard) return false;
      return q.isEmpty || '${x['stuadmno']} ${x['stuname']}'.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _allot() async {
    final ids = [for (final x in _visible) if (_ticked.contains(_id(x['stu_id']))) _id(x['stu_id'])!];
    final sec = _sectionsOfStandard.where((s) => _id(s['cla_id']) == _section).toList();
    if (_standard == null) return _snack(schoolTerm('Choose the standard first.'), AppColors.warning);
    if (ids.isEmpty) return _snack('Tick the students to allot.', AppColors.warning);
    if (sec.isEmpty) return _snack(schoolTerm('Choose the section to allot.'), AppColors.warning);
    final name = '${sec.first['claname']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Allot $name?'),
        content: Text('${ids.length} ${ids.length == 1 ? 'student moves' : 'students move'} into $name, as approved by the principal. '
            'A student of this year gets the section\'s fees, sent to Fee Demand Approval; advance already taken '
            'is adjusted against them in Advance Reconcile.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allot Section')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final res = await SupabaseService.client.rpc('allot_section_secure', params: {
        'p_token': SupabaseService.sessionToken,
        'p_stu_ids': ids,
        'p_cla_id': _section,
        'p_by': context.read<AuthProvider>().userName,
      });
      final m = Map<String, dynamic>.from(res as Map);
      final staged = _id(m['staged']) ?? 0;
      _snack('${m['allotted']} ${_id(m['allotted']) == 1 ? 'student' : 'students'} allotted to $name.'
          '${staged > 0 ? ' $staged fee demand${staged == 1 ? '' : 's'} sent to Fee Demand Approval.' : ''}', AppColors.success);
      _ticked.clear();
      _section = null;
      await _load();
    } catch (e) {
      _snack('Could not allot the section. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _drop<T>(String hint, T? value, List<(T, String)> items, ValueChanged<T?> onChanged, {String icon = 'book'}) =>
      AppDropdownField<T>(
        initialValue: items.any((e) => e.$1 == value) ? value : null,
        isExpanded: true,
        decoration: AppUI.field(context, hint, leadingIcon: icon, filled: value != null),
        style: AppUI.fieldText(context, filled: value != null),
        hint: Text(hint, overflow: TextOverflow.ellipsis),
        items: [for (final e in items) DropdownMenuItem(value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis))],
        onChanged: onChanged,
      );

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final allTicked = rows.isNotEmpty && rows.every((x) => _ticked.contains(_id(x['stu_id'])));
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'task-square',
          title: 'Section Pending',
          subtitle: schoolTerm('Pre-admissions placed in their standard only. When the principal approves, allot the section here.'),
          trailing: [
            OutlinedButton.icon(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Refresh')),
          ],
        ),
        SizedBox(height: 14.h),
        Row(children: [
          SizedBox(
            width: 240.w,
            child: _drop<String>(schoolTerm('Select standard'), _standard, [for (final s in _standards) (s, s)],
                (v) => setState(() {
                      _standard = v;
                      _section = null;
                      _ticked.clear();
                    })),
          ),
          SizedBox(width: 10.w),
          Expanded(child: AppSearchField(controller: _search, hintText: 'Search by admission no. or name', onChanged: (_) => setState(() {}))),
          SizedBox(width: 10.w),
          SizedBox(
            width: 220.w,
            child: _drop<int>(schoolTerm('Section to allot'), _section,
                [for (final s in _sectionsOfStandard) (_id(s['cla_id'])!, '${s['claname']}')], (v) => setState(() => _section = v),
                icon: 'book-1'),
          ),
          SizedBox(width: 10.w),
          ElevatedButton.icon(
            onPressed: _saving || _standard == null ? null : _allot,
            style: AppUI.primary(context),
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.how_to_reg_outlined, size: 16),
            label: Text('Allot Section (${rows.where((x) => _ticked.contains(_id(x['stu_id']))).length})'),
          ),
        ]),
        if (_standard == null && _rows.isNotEmpty) ...[
          SizedBox(height: 8.h),
          Text(schoolTerm('Choose the standard to allot its sections.'), style: AppUI.muted),
        ],
        SizedBox(height: 12.h),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty
                  ? AppUI.empty(
                      title: 'No students waiting for a section',
                      why: schoolTerm('A pre-admission placed in its standard only (Class Allocation -> "(section later)") appears here.'),
                      icon: 'task-square')
                  : Column(children: [
                      Container(
                        decoration: AppUI.tableHeadBar.copyWith(borderRadius: BorderRadius.circular(8)),
                        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
                        child: Row(children: [
                          SizedBox(
                            width: 40,
                            child: Checkbox(
                              value: allTicked,
                              onChanged: _standard == null
                                  ? null
                                  : (v) => setState(() {
                                        for (final x in rows) {
                                          v == true ? _ticked.add(_id(x['stu_id'])!) : _ticked.remove(_id(x['stu_id']));
                                        }
                                      }),
                            ),
                          ),
                          AppUI.th('S. No.', flex: 1),
                          AppUI.th('Admission No.', flex: 2),
                          AppUI.th('Student Name', flex: 4),
                          AppUI.th('Gender', flex: 1),
                          AppUI.th(schoolTerm('Standard'), flex: 1),
                          AppUI.th('Status', flex: 2),
                          AppUI.th('Advance Held', flex: 2, align: TextAlign.right),
                        ]),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (_, i) {
                            final x = rows[i];
                            final id = _id(x['stu_id'])!;
                            final pre = _id(x['preadmission']) == 1;
                            final adv = (x['advance'] as num?)?.toDouble() ?? 0;
                            return Container(
                              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
                              decoration: BoxDecoration(
                                color: _ticked.contains(id) ? AppColors.primaryLight.withValues(alpha: 0.35) : null,
                                border: const Border(bottom: BorderSide(color: AppColors.divider)),
                              ),
                              child: Row(children: [
                                SizedBox(
                                  width: 40,
                                  child: Checkbox(
                                    value: _ticked.contains(id),
                                    onChanged: _standard == null
                                        ? null
                                        : (v) => setState(() => v == true ? _ticked.add(id) : _ticked.remove(id)),
                                  ),
                                ),
                                Expanded(flex: 1, child: Text('${i + 1}', style: AppUI.cell)),
                                Expanded(flex: 2, child: Text('${x['stuadmno'] ?? ''}', style: AppUI.cell)),
                                Expanded(flex: 4, child: Text('${x['stuname'] ?? ''}', style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                                Expanded(flex: 1, child: Text(genderLabel(x['stugender']), style: AppUI.cell)),
                                Expanded(flex: 1, child: Text('${x['courname'] ?? ''}', style: AppUI.cell)),
                                Expanded(
                                  flex: 2,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: AppUI.chip(pre ? 'Pre-admission' : 'This year', pre ? AppStatus.info : AppStatus.warning),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(adv > 0 ? '₹${formatIndianNumber(adv)}' : '—',
                                      textAlign: TextAlign.right, style: AppUI.money),
                                ),
                              ]),
                            );
                          },
                        ),
                      ),
                    ]),
        ),
      ]),
    );
  }
}
