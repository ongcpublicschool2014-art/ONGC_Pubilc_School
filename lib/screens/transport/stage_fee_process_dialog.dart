import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'transport_master_panel.dart';

/// STAGE FEE PROCESS -- opened from Stage Fees (Process Fees). Choose the
/// term and the transport fee type: the school's routes are listed with
/// their students and the stages that have a fee, and a tick (that cannot be
/// changed) where the process has already billed students. Tick the routes
/// to process and press Process: each student's fee demand of the term and
/// fee type takes their stage fee (tr_stage_fee_process, where the server
/// checks everything). A processed route can be run again: new students are
/// added and changed fees updated, never below what is already paid.
class StageFeeProcessDialog extends StatefulWidget {
  /// The year's terms: {sem_id, semname, semshort}.
  final List<Map<String, dynamic>> terms;

  /// The transport fee types (fee category TRA): {fee_id, feedesc}.
  final List<Map<String, dynamic>> feeTypes;

  /// The term and fee type to start with.
  final int? semId;
  final int? feeId;

  /// The routes for a term and fee type, as tr_stage_fee_routes gives them.
  final Future<List<Map<String, dynamic>>> Function(int semId, int feeId) loadRoutes;

  /// Runs the process ({sem_id, fee_id, route_ids}) and returns its result.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> payload) onProcess;

  const StageFeeProcessDialog({
    super.key,
    required this.terms,
    required this.feeTypes,
    this.semId,
    this.feeId,
    required this.loadRoutes,
    required this.onProcess,
  });

  @override
  State<StageFeeProcessDialog> createState() => _StageFeeProcessDialogState();
}

List<Map<String, dynamic>> _maps(dynamic v) => [
      for (final x in (v is List ? v : const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];

/// A term's name as the school app keeps it ("TERM 1").
String _termName(Map<String, dynamic>? t) {
  final name = trText(t?['semname']);
  if (name.isNotEmpty) return name;
  final short = trText(t?['semshort']);
  return short.isEmpty ? 'the term' : 'Term $short';
}

/// A server time as the local day, yyyy-mm-dd; null if there is none.
String? _localDay(dynamic v) {
  final t = DateTime.tryParse(trText(v))?.toLocal();
  if (t == null) return null;
  return '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

class _StageFeeProcessDialogState extends State<StageFeeProcessDialog> {
  int? _semId, _feeId;
  List<Map<String, dynamic>> _routes = const [];
  bool _loading = false;
  String? _error;

  /// The routes ticked to process.
  final Set<int> _picked = {};
  bool _running = false;

  /// The last run's result, and why the last run failed.
  Map<String, dynamic>? _result;
  String? _runError;

  /// Only the latest load is shown.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _semId = widget.terms.any((t) => trId(t['sem_id']) == widget.semId)
        ? widget.semId
        : (widget.terms.isEmpty ? null : trId(widget.terms.first['sem_id']));
    _feeId = widget.feeTypes.any((f) => trId(f['fee_id']) == widget.feeId)
        ? widget.feeId
        : (widget.feeTypes.length == 1 ? trId(widget.feeTypes.first['fee_id']) : null);
    _loading = _semId != null && _feeId != null;
    _fetch();
  }

  Future<void> _fetch() async {
    final s = _semId, f = _feeId, seq = ++_seq;
    if (s == null || f == null) return;
    try {
      final rows = await widget.loadRoutes(s, f);
      if (!mounted || seq != _seq) return;
      setState(() {
        _routes = rows;
        _loading = false;
        _error = null;
        _picked.retainWhere((id) => rows.any((r) => trId(r['route_id']) == id && _why(r) == null));
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  void _reload() {
    setState(() {
      _loading = _semId != null && _feeId != null;
      _error = null;
    });
    _fetch();
  }

  /// Another term or fee type: its routes, nothing ticked, no old result.
  void _choose({int? sem, int? fee}) {
    if ((sem ?? _semId) == _semId && (fee ?? _feeId) == _feeId) return;
    setState(() {
      _semId = sem ?? _semId;
      _feeId = fee ?? _feeId;
      _routes = const [];
      _picked.clear();
      _result = null;
      _runError = null;
      _error = null;
      _loading = _semId != null && _feeId != null;
    });
    _fetch();
  }

  String get _termText {
    for (final t in widget.terms) {
      if (trId(t['sem_id']) == _semId) return _termName(t);
    }
    return 'the term';
  }

  String get _feeText {
    for (final f in widget.feeTypes) {
      if (trId(f['fee_id']) == _feeId) return trText(f['feedesc']);
    }
    return 'the fee';
  }

  /// Why a route cannot be ticked, or null.
  String? _why(Map<String, dynamic> r) {
    if ((trId(r['students']) ?? 0) == 0) return 'No students have transport on this route';
    if ((trId(r['stages']) ?? 0) == 0) return 'No $_feeText is set for $_termText on this route: set it in Stage Fees first';
    return null;
  }

  /// The ticked routes that can be processed, in the list's order.
  List<int> get _ticked => [
        for (final r in _routes)
          if (_why(r) == null && _picked.contains(trId(r['route_id']))) trId(r['route_id'])!,
      ];

  Future<void> _process() async {
    final ids = _ticked;
    final sem = _semId, fee = _feeId;
    if (ids.isEmpty || sem == null || fee == null) return;
    final n = ids.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Process $n route${n == 1 ? '' : 's'}?'),
        content: Text(
          'The students of the ticked route${n == 1 ? '' : 's'} get their $_termText $_feeText from their stage fee: '
          'a fee demand is added for a student who has none and updated for one who has.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            key: const ValueKey('sfp-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            style: AppUI.primary(ctx),
            child: const Text('Process'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final res = await widget.onProcess({'sem_id': sem, 'fee_id': fee, 'route_ids': ids});
      if (!mounted) return;
      setState(() {
        _running = false;
        _result = res;
        _picked.clear();
      });
      await _fetch(); // the ticks of what is processed now
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _runError = friendlyError(e);
      });
    }
  }

  // ── term and fee type ──────────────────────────────────────────────────────
  Widget _picker<T>({required Key key, required T? value, required String label, required String hint, required List<DropdownMenuItem<T>> items, required ValueChanged<T?> onChanged}) =>
      AppDropdownField<T>(
        key: key,
        initialValue: value,
        isExpanded: true,
        menuMaxHeight: 380,
        dropdownColor: AppColors.card,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', label: label, filled: value != null),
        hint: Text(hint, style: AppUI.muted),
        items: items,
        onChanged: _running ? null : onChanged,
      );

  Widget _pickers() => Wrap(spacing: 12.w, runSpacing: 8.h, children: [
        SizedBox(
          width: 210,
          child: _picker<int?>(
            key: ValueKey('sfp-term-$_semId'),
            value: _semId,
            label: 'Term',
            hint: 'Choose the term',
            items: [
              for (final t in widget.terms)
                DropdownMenuItem<int?>(value: trId(t['sem_id']), child: Text(_termName(t), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => _choose(sem: v),
          ),
        ),
        SizedBox(
          width: 260,
          child: _picker<int?>(
            key: ValueKey('sfp-fee-$_feeId'),
            value: _feeId,
            label: 'Fee Type',
            hint: 'Choose the fee type',
            items: [
              for (final f in widget.feeTypes)
                DropdownMenuItem<int?>(value: trId(f['fee_id']), child: Text(trText(f['feedesc']), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => _choose(fee: v),
          ),
        ),
      ]);

  // ── routes (grid) ──────────────────────────────────────────────────────────
  static const double _wPick = 48, _wCode = 96, _wNum = 96, _wStages = 140, _wDone = 230;

  Widget _num(double width, dynamic v) => SizedBox(
        width: width,
        child: Padding(
          padding: EdgeInsets.only(right: 16.w),
          child: Text('${trId(v) ?? 0}', textAlign: TextAlign.right, style: AppUI.money),
        ),
      );

  Widget _head(List<int> free) {
    final all = free.isNotEmpty && free.every(_picked.contains);
    final some = free.any(_picked.contains);
    Widget h(String text, double width, {TextAlign align = TextAlign.left}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.only(right: align == TextAlign.right ? 16.w : 0),
            child: Text(text, textAlign: align, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.tableHead),
          ),
        );
    return Container(
      decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 2.h),
      child: Row(children: [
        SizedBox(
          width: _wPick,
          child: Tooltip(
            message: all ? 'Untick all' : 'Tick all that can be processed',
            child: Checkbox(
              key: const ValueKey('sfp-all'),
              tristate: true,
              value: all ? true : (some ? null : false),
              onChanged: free.isEmpty || _running
                  ? null
                  : (_) => setState(() {
                        if (all) {
                          _picked.removeAll(free);
                        } else {
                          _picked.addAll(free);
                        }
                      }),
            ),
          ),
        ),
        h('CODE', _wCode),
        Expanded(child: Text('ROUTE', style: AppUI.tableHead)),
        h('STUDENTS', _wNum, align: TextAlign.right),
        h('STAGES WITH FEE', _wStages, align: TextAlign.right),
        h('PROCESSED', _wDone),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r, int i) {
    final id = trId(r['route_id'])!;
    final why = _why(r);
    final on = why == null && _picked.contains(id);
    final done = trId(r['processed']) ?? 0;
    final day = _localDay(r['processed_at']);
    final can = why == null && !_running;
    void tick(bool v) => setState(() {
          if (v) {
            _picked.add(id);
          } else {
            _picked.remove(id);
          }
        });
    return InkWell(
      key: ValueKey('sfp-row-$id'),
      onTap: can ? () => tick(!on) : null,
      child: Container(
        decoration: BoxDecoration(color: on ? AppColors.primarySoft : (i.isEven ? Colors.white : AppColors.surface), border: const Border(bottom: BorderSide(color: AppColors.divider))),
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 1.h),
        child: Row(children: [
          SizedBox(
            width: _wPick,
            child: Tooltip(
              message: why ?? (on ? 'Ticked to process' : 'Tick to process'),
              child: Checkbox(key: ValueKey('sfp-pick-$id'), value: on, onChanged: can ? (v) => tick(v == true) : null),
            ),
          ),
          SizedBox(
            width: _wCode,
            child: Text(trText(r['route_code']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label),
          ),
          Expanded(
            child: Row(children: [
              Flexible(child: Text(trText(r['route_name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: why == null ? AppUI.cell : AppUI.muted)),
              if (r['is_active'] == false) ...[
                SizedBox(width: 8.w),
                Tooltip(message: 'Switched off in Routes & Stops', child: AppUI.chip('Off', AppStatus.neutral)),
              ],
            ]),
          ),
          _num(_wNum, r['students']),
          _num(_wStages, r['stages']),
          SizedBox(
            width: _wDone,
            // shows what is done; it is not a choice
            child: Tooltip(
              message: done > 0
                  ? 'Processed: $done fee demand${done == 1 ? '' : 's'} of $_termText $_feeText${day == null ? '' : ', last on ${formatDate(day)}'}'
                  : 'Not processed for $_termText $_feeText yet',
              child: Row(children: [
                Icon(
                  done > 0 ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                  key: ValueKey('sfp-done-$id-${done > 0}'),
                  size: 22,
                  color: done > 0 ? AppColors.primary : AppColors.ink3,
                ),
                if (done > 0) ...[
                  SizedBox(width: 8.w),
                  Flexible(
                    child: Text(
                      '$done student${done == 1 ? '' : 's'}${day == null ? '' : ' · ${formatDate(day)}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.muted,
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _body() {
    if (_semId == null || _feeId == null) {
      return AppUI.empty(title: 'Choose the term and fee type', why: 'The routes are listed for them.', icon: 'receipt-2');
    }
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not load the routes',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton(onPressed: _reload, style: AppUI.secondary(context), child: const Text('Retry')),
      );
    }
    if (_routes.isEmpty) {
      return AppUI.empty(title: 'No routes yet', why: 'Add a route and its stages in Routes & Stops first.', icon: 'routing');
    }
    final free = [
      for (final r in _routes)
        if (_why(r) == null) trId(r['route_id'])!,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _head(free),
      Expanded(
        child: ListView.builder(
          key: const ValueKey('sfp-rows'),
          itemCount: _routes.length,
          itemBuilder: (_, i) => _row(_routes[i], i),
        ),
      ),
    ]);
  }

  // ── result of the last run ─────────────────────────────────────────────────
  Widget _problem(Map<String, dynamic> p) {
    final adm = trText(p['stuadmno']), name = trText(p['stuname']), cls = trText(p['stuclass']);
    final who = [adm, name, if (cls.isNotEmpty) '($cls)'].where((s) => s.isNotEmpty).join(' ');
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3.h),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 80, child: Text(trText(p['route_code']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
        SizedBox(width: 72, child: Text(trText(p['stage']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted)),
        SizedBox(
          width: 250,
          child: Padding(
            padding: EdgeInsets.only(right: 10.w),
            child: Text(who.isEmpty ? '–' : who, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell),
          ),
        ),
        Expanded(child: Text(trText(p['reason']), style: AppUI.muted.copyWith(color: AppColors.ink2))),
      ]),
    );
  }

  Widget _resultPanel(Map<String, dynamic> r) {
    int k(String key) => trId(r[key]) ?? 0;
    final problems = _maps(r['problems']);
    final students = k('students');
    final parts = [
      '${k('added')} added',
      '${k('updated')} updated',
      if (k('unchanged') > 0) '${k('unchanged')} already right',
      if (k('skipped') > 0) '${k('skipped')} not processed',
    ];
    return Container(
      key: const ValueKey('sfp-result'),
      margin: EdgeInsets.fromLTRB(AppUI.cardPad, 10.h, AppUI.cardPad, 0),
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
      decoration: BoxDecoration(
        color: problems.isEmpty ? AppColors.primaryTint : AppColors.goldTint,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: problems.isEmpty ? AppColors.primaryLine : AppColors.goldLine),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(
          '$_termText $_feeText: $students student${students == 1 ? '' : 's'} processed. ${parts.join(', ')}.',
          style: AppUI.label,
        ),
        if (problems.isNotEmpty) ...[
          SizedBox(height: 6.h),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 140.h),
            child: ListView(
              key: const ValueKey('sfp-problems'),
              shrinkWrap: true,
              children: [for (final p in problems) _problem(p)],
            ),
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _ticked.length;
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(
              icon: 'receipt-2',
              title: 'Stage Fee Process',
              subtitle: 'Each student of a ticked route gets the term\'s fee of their stage in their fee demand.',
            ),
          ),
          Padding(padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad), child: _pickers()),
          SizedBox(height: 12.h),
          Expanded(child: _body()),
          if (_result != null) _resultPanel(_result!),
          if (_runError != null)
            Padding(
              padding: EdgeInsets.fromLTRB(AppUI.cardPad, 10.h, AppUI.cardPad, 0),
              child: Text(_runError!, key: const ValueKey('sfp-error'), style: AppUI.body.copyWith(color: AppColors.error)),
            ),
          AppFormFooter(
            note: '$n ticked · A processed route can be run again: new students are added and changed fees updated.',
            onCancel: _running ? null : () => Navigator.pop(context),
            cancelLabel: 'Close',
            actions: [
              ElevatedButton.icon(
                key: const ValueKey('sfp-process'),
                onPressed: n == 0 || _running ? null : _process,
                style: AppUI.primary(context),
                icon: AppIcon('receipt-edit', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
                label: Text(_running ? 'Processing...' : (n == 0 ? 'Process' : 'Process $n Route${n == 1 ? '' : 's'}')),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
