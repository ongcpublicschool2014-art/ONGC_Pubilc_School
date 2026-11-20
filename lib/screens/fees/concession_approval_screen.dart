import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_text.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';

/// Fees -> Concession Approval (user, 2026-11-14: "now i want a screen for
/// concession approval").
///
/// A concession entered by someone whose role may not open this screen does
/// not touch the fee demands: it waits here (public.concession_request). On
/// Approve it is saved exactly as Fee Concession saves one -- voucher number,
/// demand reduced -- in the requester's name; Reject keeps it with the
/// reason. Server side: school_concession_approval.sql.
class ConcessionApprovalScreen extends StatefulWidget {
  const ConcessionApprovalScreen({super.key});

  @override
  State<ConcessionApprovalScreen> createState() => _ConcessionApprovalScreenState();
}

class _ConcessionApprovalScreenState extends State<ConcessionApprovalScreen> {
  String _status = 'P'; // P pending, A approved, R rejected
  List<Map<String, dynamic>> _rows = [];
  final Set<int> _picked = {};
  bool _loading = true, _busy = false;
  String? _error;

  static int _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static String _inr(num v) => '₹${formatIndianNumber(v)}';
  static String _dmy(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '-' : formatDmy(d);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await SupabaseService.client
          .rpc('concession_requests', params: {'p_token': SupabaseService.sessionToken, 'p_status': _status});
      if (!mounted) return;
      setState(() {
        _rows = [for (final r in (res as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
        _picked.removeWhere((id) => !_rows.any((r) => _id(r['cr_id']) == id));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<bool> _approveOne(Map<String, dynamic> r, {bool quiet = false}) async {
    try {
      final res = await SupabaseService.client.rpc('approve_concession_request',
          params: {'p_token': SupabaseService.sessionToken, 'p_cr_id': _id(r['cr_id'])});
      final doc = res is Map ? '${res['doc_no'] ?? ''}' : '';
      if (!quiet) _snack('Approved -- ${doc.isEmpty ? 'concession' : doc} made for ${r['stuname']}.', AppColors.success);
      return true;
    } catch (e) {
      if (!quiet) _snack('Could not approve: ${friendlyError(e)}', AppColors.error);
      return false;
    }
  }

  Future<void> _approve(Map<String, dynamic> r) async {
    setState(() => _busy = true);
    await _approveOne(r);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _approvePicked() async {
    final todo = _rows.where((r) => _picked.contains(_id(r['cr_id']))).toList();
    if (todo.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Approve ${todo.length} concession${todo.length == 1 ? '' : 's'}', style: AppUI.cardTitle),
        content: Text(
            'Total ${_inr(todo.fold<double>(0, (t, r) => t + _num(r['totalconcession'])))}. Each one is saved with its own concession number.',
            style: AppUI.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    var done = 0;
    final failed = <String>[];
    for (final r in todo) {
      if (await _approveOne(r, quiet: true)) {
        done++;
      } else {
        failed.add('${r['stuadmno']}');
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _picked.clear();
    });
    _snack(
        failed.isEmpty
            ? '$done concession${done == 1 ? '' : 's'} approved.'
            : '$done approved; ${failed.length} could not be (${failed.join(', ')}) -- open them to see why.',
        failed.isEmpty ? AppColors.success : AppColors.warning);
    await _load();
  }

  Future<void> _reject(Map<String, dynamic> r) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reject concession', style: AppUI.cardTitle),
        content: SizedBox(
          width: 420.w,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r['stuname']} (${r['stuadmno']}) -- ${_inr(_num(r['totalconcession']))}. The fees stay as they are.', style: AppUI.body),
            SizedBox(height: 12.h),
            AppUI.fieldLabel('Reason', required: true),
            TextField(
              controller: reason,
              autofocus: true,
              maxLines: 2,
              style: AppUI.fieldText(context, filled: true),
              decoration: AppUI.field(context, 'Why it is not approved'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(style: AppUI.danger(ctx), onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
        ],
      ),
    );
    final why = reason.text.trim();
    reason.dispose();
    if (ok != true) return;
    if (why.isEmpty) return _snack('Enter the reason for rejecting it.', AppColors.warning);
    setState(() => _busy = true);
    try {
      await SupabaseService.client.rpc('reject_concession_request',
          params: {'p_token': SupabaseService.sessionToken, 'p_cr_id': _id(r['cr_id']), 'p_reason': why});
      _snack('Rejected -- the fees of ${r['stuname']} are unchanged.', AppColors.success);
    } catch (e) {
      _snack('Could not reject: ${friendlyError(e)}', AppColors.error);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  /// The request's fee lines, and Approve / Reject when it is pending.
  Future<void> _open(Map<String, dynamic> r) async {
    final lines = [for (final l in (r['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];
    final pending = '${r['status']}' == 'P';
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${r['stuname']}  ·  ${r['stuadmno']}', style: AppUI.cardTitle),
        content: SizedBox(
          width: 620.w,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
                [
                  schoolTerm('Class: ${r['stuclass'] ?? '-'}'),
                  'Category: ${r['contype'] ?? '-'}',
                  _typeText(r),
                  'Asked by ${r['requestedby'] ?? '-'} on ${_dmy(r['requestedat'])}',
                ].join('   ·   '),
                style: AppUI.muted),
            SizedBox(height: 12.h),
            Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                Container(
                  decoration: AppUI.tableHeadBar,
                  padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                  child: Row(children: [
                    AppUI.th('TERM', flex: 2),
                    AppUI.th('FEE TYPE', flex: 4),
                    AppUI.th('FEE', flex: 2, align: TextAlign.right),
                    AppUI.th('CONCESSION', flex: 2, align: TextAlign.right),
                  ]),
                ),
                for (var i = 0; i < lines.length; i++)
                  Container(
                    color: i.isEven ? Colors.white : AppColors.surface,
                    padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 9.h),
                    child: Row(children: [
                      Expanded(flex: 2, child: Text('${lines[i]['demfeeterm'] ?? '-'}', style: AppUI.cell)),
                      Expanded(flex: 4, child: Text('${lines[i]['demfeetype'] ?? '-'}', style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                      Expanded(flex: 2, child: Text(_inr(_num(lines[i]['feeamount'])), style: AppUI.money, textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: Text(_inr(_num(lines[i]['conamount'])), style: AppUI.money.copyWith(color: AppColors.success), textAlign: TextAlign.right)),
                    ]),
                  ),
              ]),
            ),
            if ('${r['decision_note'] ?? ''}'.isNotEmpty) ...[
              SizedBox(height: 10.h),
              Text('Reason: ${r['decision_note']}', style: AppUI.body.copyWith(color: AppColors.error)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          if (pending) ...[
            OutlinedButton(onPressed: () => Navigator.pop(ctx, 'R'), child: const Text('Reject')),
            ElevatedButton(onPressed: r['current_year'] == false ? null : () => Navigator.pop(ctx, 'A'), child: const Text('Approve')),
          ],
        ],
      ),
    );
    if (act == 'A') await _approve(r);
    if (act == 'R') await _reject(r);
  }

  String _typeText(Map<String, dynamic> r) =>
      '${'${r['seqtype']}' == 'ARREAR' ? 'Arrear write-off' : 'Regular'}${'${r['source']}' == 'SECTION' ? ' · Whole section' : ''}';

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: AppUI.card(),
        padding: EdgeInsets.all(AppUI.cardPad),
        child: AppUI.cardHeader(
          icon: 'tick-square',
          title: 'Concession Approval',
          subtitle: "Concessions waiting for approval before they reduce a student's fees",
          trailing: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'P', label: Text('Pending')),
                ButtonSegment(value: 'A', label: Text('Approved')),
                ButtonSegment(value: 'R', label: Text('Rejected')),
              ],
              selected: {_status},
              onSelectionChanged: (v) {
                setState(() {
                  _status = v.first;
                  _picked.clear();
                });
                _load();
              },
            ),
            SizedBox(width: 10.w),
            OutlinedButton.icon(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Refresh')),
          ],
        ),
      ),
      SizedBox(height: AppUI.gap),
      Expanded(
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: AppUI.card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _table()),
            if (_status == 'P' && _rows.isNotEmpty) _footer(),
          ]),
        ),
      ),
    ]);
  }

  Widget _table() {
    if (_loading) return const AppLoading(label: 'Loading concessions…');
    if (_error != null) return AppUI.empty(icon: 'warning-2', title: 'Could not load', why: _error);
    if (_rows.isEmpty) {
      return AppUI.empty(
        icon: 'tick-circle',
        title: _status == 'P' ? 'Nothing waiting for approval' : (_status == 'A' ? 'No approved concessions yet' : 'No rejected concessions'),
        why: _status == 'P' ? 'Every concession saved in Fee Concession waits here until it is approved.' : null,
      );
    }
    final pending = _status == 'P';
    final allPicked = pending && _rows.every((r) => _picked.contains(_id(r['cr_id'])));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: AppUI.tableHeadBar,
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
        child: Row(children: [
          if (pending)
            SizedBox(
              width: 36.w,
              child: Checkbox(
                value: allPicked,
                visualDensity: VisualDensity.compact,
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                          _picked.clear();
                          if (v == true) _picked.addAll(_rows.map((r) => _id(r['cr_id'])));
                        }),
              ),
            ),
          AppUI.th('DATE', flex: 2),
          AppUI.th(schoolTerm('ROLL NO.'), flex: 2),
          AppUI.th('STUDENT', flex: 4),
          AppUI.th(schoolTerm('CLASS'), flex: 2),
          AppUI.th('CATEGORY', flex: 3),
          AppUI.th('TYPE', flex: 3),
          AppUI.th('CONCESSION', flex: 2, align: TextAlign.right),
          // the same gap the rows leave after the amount ("CONCESSIONREJECTED BY")
          SizedBox(width: 12.w),
          AppUI.th(pending ? 'ASKED BY' : (_status == 'A' ? 'APPROVED BY' : 'REJECTED BY'), flex: 2),
          // the reason gets more room than a number or the buttons
          AppUI.th(pending ? 'ACTION' : (_status == 'A' ? 'CONCESSION NO.' : 'REASON'), flex: _status == 'R' ? 5 : 3,
              align: pending ? TextAlign.center : TextAlign.left),
        ]),
      ),
      Expanded(
        child: ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: _rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
          itemBuilder: (_, i) => _row(_rows[i], i),
        ),
      ),
    ]);
  }

  Widget _row(Map<String, dynamic> r, int i) {
    final id = _id(r['cr_id']);
    final pending = _status == 'P';
    final lines = (r['lines'] as List? ?? const []).length;
    return Material(
      color: i.isEven ? Colors.white : AppColors.surface,
      child: InkWell(
        onTap: _busy ? null : () => _open(r),
        hoverColor: AppColors.primaryLight.withValues(alpha: 0.6),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
          child: Row(children: [
            if (pending)
              SizedBox(
                width: 36.w,
                child: Checkbox(
                  value: _picked.contains(id),
                  visualDensity: VisualDensity.compact,
                  onChanged: _busy ? null : (v) => setState(() => v == true ? _picked.add(id) : _picked.remove(id)),
                ),
              ),
            Expanded(flex: 2, child: Text(_dmy(pending ? r['requestedat'] : r['decidedat']), style: AppUI.cell)),
            Expanded(flex: 2, child: Text('${r['stuadmno'] ?? '-'}', style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: AppColors.primary))),
            Expanded(
              flex: 4,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['stuname'] ?? '-'}', style: AppUI.cell.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                Text('$lines fee line${lines == 1 ? '' : 's'}', style: AppUI.muted.copyWith(fontSize: 12.sp)),
              ]),
            ),
            Expanded(flex: 2, child: Text('${r['stuclass'] ?? '-'}', style: AppUI.cell)),
            Expanded(flex: 3, child: Text('${r['contype'] ?? '-'}', style: AppUI.cell, overflow: TextOverflow.ellipsis)),
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.centerLeft,
                child: AppUI.chip(_typeText(r), '${r['seqtype']}' == 'ARREAR' ? AppStatus.warning : AppStatus.info),
              ),
            ),
            Expanded(flex: 2, child: Text(_inr(_num(r['totalconcession'])), style: AppUI.money, textAlign: TextAlign.right)),
            SizedBox(width: 12.w),
            Expanded(flex: 2, child: Text('${(pending ? r['requestedby'] : r['decidedby']) ?? '-'}', style: AppUI.cell, overflow: TextOverflow.ellipsis)),
            Expanded(
              flex: _status == 'R' ? 5 : 3,
              child: pending
                  ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Tooltip(
                        message: r['current_year'] == false ? 'From a closed year: it can only be rejected' : 'Approve',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: _busy || r['current_year'] == false ? null : () => _approve(r),
                          icon: const Icon(Icons.check_circle_outline, color: AppColors.success),
                        ),
                      ),
                      Tooltip(
                        message: 'Reject',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: _busy ? null : () => _reject(r),
                          icon: const Icon(Icons.cancel_outlined, color: AppColors.error),
                        ),
                      ),
                    ])
                  // The reason in full: wraps to a second line, and the whole
                  // text is in the tooltip (it was cut off at one line).
                  : Tooltip(
                      message: _status == 'A' ? '' : '${r['decision_note'] ?? ''}',
                      child: Text(
                        _status == 'A' ? '${r['doc_no'] ?? '-'}' : '${r['decision_note'] ?? '-'}',
                        style: AppUI.cell.copyWith(color: _status == 'A' ? AppColors.primary : AppColors.error),
                        maxLines: _status == 'A' ? 1 : 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _footer() {
    final total = _rows.fold<double>(0, (t, r) => t + _num(r['totalconcession']));
    final picked = _rows.where((r) => _picked.contains(_id(r['cr_id']))).toList();
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
      padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
      child: Row(children: [
        Text('${_rows.length} waiting  ·  ${_inr(total)}', style: AppUI.label),
        const Spacer(),
        if (picked.isNotEmpty) ...[
          Text('${picked.length} selected', style: AppUI.muted),
          SizedBox(width: 12.w),
        ],
        ElevatedButton.icon(
          onPressed: _busy || picked.isEmpty ? null : _approvePicked,
          icon: _busy
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.done_all, size: 16, color: Colors.white),
          label: const Text('Approve Selected'),
        ),
      ]),
    );
  }
}
