import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/tc_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../utils/tc_fields.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';

/// TC -> TC Approval (old frmTcApproval / frmApprovalCancel) and
/// TC -> TC Print (old frmTcPrinting): both list the saved certificates.
enum TcListMode { approval, print }

class TcApprovalScreen extends StatelessWidget {
  const TcApprovalScreen({super.key});
  @override
  Widget build(BuildContext context) => const _TcListScreen(mode: TcListMode.approval);
}

class TcPrintScreen extends StatelessWidget {
  const TcPrintScreen({super.key});
  @override
  Widget build(BuildContext context) => const _TcListScreen(mode: TcListMode.print);
}

class _TcListScreen extends StatefulWidget {
  final TcListMode mode;
  const _TcListScreen({required this.mode});
  @override
  State<_TcListScreen> createState() => _TcListScreenState();
}

class _TcListScreenState extends State<_TcListScreen> {
  bool _loading = true, _busy = false;
  List<Map<String, dynamic>> _items = []; // list items that HAVE a certificate
  final _search = TextEditingController();
  final Set<int> _picked = {};
  late String _filter = widget.mode == TcListMode.approval ? 'PENDING' : 'NOT_PRINTED';
  String _copy = 'AUTO';
  bool _hasFormat = true;

  bool get _approval => widget.mode == TcListMode.approval;

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

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait<dynamic>([TcService.list(), TcService.format()]);
      if (!mounted) return;
      setState(() {
        _items = [for (final i in r[0] as List<Map<String, dynamic>>) if (i['cert'] != null) i];
        _hasFormat = r[1] != null;
        _picked.removeWhere((id) => !_items.any((i) => _id(i) == id));
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Could not load. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  static int _id(Map<String, dynamic> i) => ((i['cert'] as Map)['tcc_id'] as num).toInt();
  static Map _cert(Map<String, dynamic> i) => i['cert'] as Map;
  static bool _approved(Map<String, dynamic> i) => (_cert(i)['approval'] as num?)?.toInt() == 1;
  static int _prints(Map<String, dynamic> i) => (_cert(i)['printcount'] as num?)?.toInt() ?? 0;

  List<Map<String, dynamic>> get _visible {
    final q = _search.text.trim().toLowerCase();
    return _items.where((i) {
      if (!_approval && !_approved(i)) return false; // print: approved only
      final ok = switch (_filter) {
        'PENDING' => !_approved(i),
        'APPROVED' => _approved(i),
        'NOT_PRINTED' => _prints(i) == 0,
        'PRINTED' => _prints(i) > 0,
        _ => true,
      };
      if (!ok) return false;
      return q.isEmpty || '${i['stuname']} ${i['stuadmno']} ${i['stuclass']} ${_cert(i)['tcserial']}'.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _approve(bool approve) async {
    final ids = _visible.where((i) => _picked.contains(_id(i)) && _approved(i) != approve).map(_id).toList();
    if (ids.isEmpty) {
      _snack(approve ? 'Tick certificates awaiting approval first.' : 'Tick approved certificates first.', AppColors.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await TcService.approve(ids, approve: approve);
      _snack(approve ? '$n certificate(s) approved.' : 'Approval cancelled for $n certificate(s).', AppColors.success);
      _picked.clear();
      await _load();
    } catch (e) {
      _snack('Failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print() async {
    final certs = [
      for (final i in _visible)
        if (_picked.contains(_id(i))) {..._cert(i).cast<String, dynamic>(), 'stuadmno': i['stuadmno'], 'stuname': i['stuname']}
    ];
    if (certs.isEmpty) {
      _snack('Tick the certificates to print.', AppColors.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      final path = await TcService.printTc(certs, _copy);
      if (path == null) return;
      await TcService.markPrinted([for (final c in certs) (c['tcc_id'] as num).toInt()]);
      _snack('${certs.length} TC(s) filled into $path -- opened to print.', AppColors.success);
      _picked.clear();
      await _load();
    } catch (e) {
      _snack(e is StateError ? e.message : 'Could not print. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _preview(Map<String, dynamic> i) {
    final fields = Map<String, dynamic>.from((_cert(i)['fields'] as Map?) ?? const {});
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${i['stuname']} -- TC ${_cert(i)['tcserial'] ?? ''}'),
        content: SizedBox(
          width: 560,
          height: 480,
          child: ListView(children: [
            for (final e in fields.entries)
              if ('${e.value ?? ''}'.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 200, child: Text(e.key, style: AppUI.muted)),
                    Expanded(child: Text('${e.value}', style: AppUI.body)),
                  ]),
                ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    final rows = _visible;
    final filters = _approval
        ? const [('PENDING', 'Awaiting approval'), ('APPROVED', 'Approved'), ('ALL', 'All')]
        : const [('NOT_PRINTED', 'Not printed'), ('PRINTED', 'Printed'), ('ALL', 'All approved')];
    final allTicked = rows.isNotEmpty && rows.every((i) => _picked.contains(_id(i)));
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: _approval ? 'tick-square' : 'printer',
          title: _approval ? 'TC Approval' : 'TC Print',
          subtitle: _approval
              ? 'Approve the saved certificates -- only approved ones can be printed. Approval Cancel re-opens one for editing.'
              : 'Fill the school\'s TC format for the ticked certificates and open it to print.',
          trailing: [IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
        ),
        SizedBox(height: 14.h),
        Row(children: [
          SizedBox(width: 320.w, child: AppSearchField(controller: _search, hintText: 'Search name / adm no / TC no', onChanged: (_) => setState(() {}))),
          SizedBox(width: 12.w),
          Wrap(spacing: 8.w, children: [
            for (final f in filters) ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
          ]),
          const Spacer(),
          if (!_approval) ...[
            SizedBox(
              width: 220.w,
              child: DropdownButtonFormField<String>(
                initialValue: _copy,
                isExpanded: true,
                decoration: AppUI.field(context, 'Copy', leadingIcon: 'document-text', filled: true),
                style: AppUI.fieldText(context, filled: true),
                items: const [
                  DropdownMenuItem(value: 'AUTO', child: Text('Auto (Original / Duplicate)')),
                  DropdownMenuItem(value: 'ORIGINAL', child: Text('Original')),
                  DropdownMenuItem(value: 'DUPLICATE', child: Text('Duplicate')),
                ],
                onChanged: (v) => setState(() => _copy = v ?? 'AUTO'),
              ),
            ),
            SizedBox(width: 10.w),
          ],
          if (_approval) ...[
            OutlinedButton.icon(onPressed: _busy ? null : () => _approve(false), icon: const Icon(Icons.undo, size: 16), label: const Text('Cancel approval')),
            SizedBox(width: 10.w),
            ElevatedButton.icon(onPressed: _busy ? null : () => _approve(true), icon: const Icon(Icons.verified, size: 16), label: Text('Approve (${_picked.length})')),
          ] else
            ElevatedButton.icon(
              onPressed: _busy || !_hasFormat ? null : _print,
              icon: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.print, size: 16),
              label: Text('Print (${_picked.length})'),
            ),
        ]),
        if (!_approval && !_hasFormat)
          Container(
            margin: EdgeInsets.only(top: 10.h),
            padding: EdgeInsets.all(12.w),
            decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppUI.controlRadius)),
            child: Text('Upload the school\'s TC format (Word .docx or PDF) in TC -> TC Format before printing.', style: AppUI.label.copyWith(color: AppColors.warning)),
          ),
        SizedBox(height: 14.h),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
            child: Column(children: [
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                child: Row(children: [
                  SizedBox(
                    width: 40,
                    child: Checkbox(
                      value: allTicked,
                      onChanged: rows.isEmpty
                          ? null
                          : (v) => setState(() => v == true ? _picked.addAll(rows.map(_id)) : _picked.removeAll(rows.map(_id))),
                    ),
                  ),
                  AppUI.th('Student', flex: 4),
                  AppUI.th('Section', flex: 2),
                  AppUI.th('TC No', flex: 2),
                  AppUI.th(_approval ? 'Saved by' : 'Approved by', flex: 3),
                  AppUI.th(_approval ? 'Status' : 'Printed', flex: 2),
                  const SizedBox(width: 48),
                ]),
              ),
              Expanded(
                child: rows.isEmpty
                    ? AppUI.empty(
                        title: 'Nothing here',
                        why: _items.isEmpty
                            ? 'Save certificates in TC -> TC Certificate first.'
                            : (_approval ? 'No certificate matches this filter.' : 'No approved certificate matches -- approve them in TC Approval.'),
                        icon: _approval ? 'tick-square' : 'printer')
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, k) {
                          final i = rows[k];
                          final c = _cert(i);
                          final id = _id(i);
                          return InkWell(
                            onTap: () => setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id)),
                            child: Container(
                              color: _picked.contains(id) ? AppColors.primaryLight : null,
                              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                              child: Row(children: [
                                SizedBox(width: 40, child: Checkbox(value: _picked.contains(id), onChanged: (_) => setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id)))),
                                Expanded(
                                  flex: 4,
                                  child: Row(children: [
                                    StudentAvatar(photoUrl: '${i['stuphoto'] ?? ''}', name: '${i['stuname'] ?? ''}', size: 32),
                                    SizedBox(width: 10.w),
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text('${i['stuname'] ?? ''}', style: AppUI.label, overflow: TextOverflow.ellipsis),
                                        Text('${i['stuadmno'] ?? ''}', style: AppUI.muted),
                                      ]),
                                    ),
                                  ]),
                                ),
                                Expanded(flex: 2, child: Text('${i['stuclass'] ?? ''}', style: AppUI.cell)),
                                Expanded(flex: 2, child: Text('${c['tcserial'] ?? ''}', style: AppUI.cell)),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    _approval
                                        ? '${c['updatedby'] ?? c['createdby'] ?? ''} · ${tcDate(c['updatedat'] ?? c['createdat'])}'
                                        : '${c['approvedby'] ?? ''} · ${tcDate(c['approveddate'])}',
                                    style: AppUI.muted,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: _approval
                                        ? (_approved(i)
                                            ? AppUI.chip('Approved ${tcDate(c['approveddate'])}', AppStatus.success)
                                            : AppUI.chip('Awaiting approval', AppStatus.warning))
                                        : (_prints(i) == 0
                                            ? AppUI.chip('Not printed', AppStatus.neutral)
                                            : AppUI.chip('${_prints(i)}x · ${tcDate(c['lastprintedat'])}', AppStatus.info)),
                                  ),
                                ),
                                SizedBox(
                                  width: 48,
                                  child: IconButton(tooltip: 'View details', onPressed: () => _preview(i), icon: const Icon(Icons.visibility_outlined, size: 18)),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
            ]),
          ),
        ),
        SizedBox(height: 8.h),
        Text('${AppUI.showing(rows.isEmpty ? 0 : 1, rows.length, rows.length)} · ${_picked.length} ticked', style: AppUI.muted),
      ]),
    );
  }
}
