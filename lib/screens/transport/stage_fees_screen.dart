import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/transport_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import 'stage_fee_process_dialog.dart';
import 'transport_master_panel.dart';

/// STAGE FEES -- what each stage of a route costs, term by term
/// (tr_stage_fee). Pick the route, the term (the school app's semester of the
/// year) and Both / Pickup / Drop at the top; then the fee type (a transport
/// fee head: fee category TRA) and the effective dates, and type the amount
/// of each stage. The stages are saved together (tr_save 'stage_fee' with
/// "fees"); clearing an amount removes that stage's fee. The server checks
/// everything again (transport_core._stage_fee_save).
///
/// Process Fees (top) opens the Stage Fee Process: the students of the
/// ticked routes get the term's fee of their stage in their fee demands
/// (StageFeeProcessDialog).
class StageFeesScreen extends StatefulWidget {
  const StageFeesScreen({super.key});

  @override
  State<StageFeesScreen> createState() => _StageFeesScreenState();
}

/// The ways a fee is for: value, label, icon (Pickup heads to school, Drop home).
const _services = <(String, String, String)>[
  ('BOTH', 'Both', 'arrow-swap-horizontal'),
  ('PICKUP', 'Pickup', 'building'),
  ('DROP', 'Drop', 'home'),
];

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String? _isoDate(dynamic v) {
  final s = trText(v);
  return s.length >= 10 ? s.substring(0, 10) : null;
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

class _StageFeesScreenState extends State<StageFeesScreen> {
  List<Map<String, dynamic>> _routes = const [];
  List<Map<String, dynamic>> _stages = const [];
  List<Map<String, dynamic>> _terms = const [];
  List<Map<String, dynamic>> _feeTypes = const [];
  List<Map<String, dynamic>> _fees = const [];
  String _year = '';
  int? _routeId;
  int? _semId;
  String _service = 'BOTH';
  bool _loading = true;
  bool _loadingFees = false;
  String? _error;
  String? _feesError;

  /// The board has changes that are not saved yet.
  bool _dirty = false;

  /// Bumped to put the pickers back on the open route and term.
  int _pickerKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static Future<List<Map<String, dynamic>>> _list(int route, int sem, String service) =>
      TransportService.list('stage_fee', filter: {'route_id': route, 'sem_id': sem, 'service_type': service});

  /// The term today is in, else the first one.
  static Map<String, dynamic>? _currentTerm(List<Map<String, dynamic>> terms) {
    final today = _iso(DateTime.now());
    for (final t in terms) {
      final a = _isoDate(t['semstart']), b = _isoDate(t['semend']);
      if (a != null && b != null && a.compareTo(today) <= 0 && today.compareTo(b) <= 0) return t;
    }
    return terms.isEmpty ? null : terms.first;
  }

  /// The routes and their stages, the year's terms and transport fee types;
  /// then the open route's fees for the term and way (the first route in use
  /// and the current term, at first).
  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        TransportService.list('route'),
        TransportService.list('stage'),
        TransportService.lookups(),
      ]);
      final routes = r[0] as List<Map<String, dynamic>>;
      final look = r[2] as Map<String, dynamic>;
      final terms = _maps(look['terms']);
      var routeId = _routeId;
      if (!routes.any((x) => trId(x['route_id']) == routeId)) {
        final inUse = routes.where((x) => x['is_active'] != false);
        routeId = trId((inUse.isNotEmpty ? inUse.first : (routes.isEmpty ? null : routes.first))?['route_id']);
      }
      var semId = _semId;
      if (!terms.any((t) => trId(t['sem_id']) == semId)) semId = trId(_currentTerm(terms)?['sem_id']);
      final fees = routeId == null || semId == null ? <Map<String, dynamic>>[] : await _list(routeId, semId, _service);
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _stages = r[1] as List<Map<String, dynamic>>;
        _terms = terms;
        _feeTypes = _maps(look['feetypes']);
        _year = trText(look['year']);
        _routeId = routeId;
        _semId = semId;
        _fees = fees;
        _loading = false;
        _error = null;
        _feesError = null;
        _dirty = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _load();
  }

  Future<void> _refresh() async {
    if (_dirty && !await _discard()) return;
    await _reload();
  }

  /// Opens another route, term or way (asks first when changes would be lost).
  Future<void> _choose({int? route, int? sem, String? service}) async {
    final r = route ?? _routeId, s = sem ?? _semId, v = service ?? _service;
    if (r == _routeId && s == _semId && v == _service) return;
    if (_dirty && !await _discard()) {
      setState(() => _pickerKey++); // the pickers show the open ones again
      return;
    }
    setState(() {
      _routeId = r;
      _semId = s;
      _service = v;
      _loadingFees = true;
      _feesError = null;
      _dirty = false;
    });
    await _loadFees();
  }

  Future<void> _loadFees() async {
    final r = _routeId, s = _semId, v = _service;
    if (r == null || s == null) {
      setState(() => _loadingFees = false);
      return;
    }
    bool still() => mounted && r == _routeId && s == _semId && v == _service;
    try {
      final rows = await _list(r, s, v);
      if (!still()) return;
      setState(() {
        _fees = rows;
        _loadingFees = false;
        _feesError = null;
      });
    } catch (e) {
      if (!still()) return;
      setState(() {
        _loadingFees = false;
        _feesError = friendlyError(e);
      });
    }
  }

  /// Saves the board's stages, then shows what the server has now.
  Future<void> _save(Map<String, dynamic> payload) async {
    await TransportService.save('stage_fee', payload);
    final fresh = await _list(_routeId!, _semId!, _service);
    if (!mounted) return;
    setState(() {
      _fees = fresh;
      _dirty = false;
    });
  }

  Future<bool> _discard() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard the changes?'),
          content: const Text('Some changes are not saved yet. They are lost if you go on.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Editing')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.danger(ctx), child: const Text('Discard')),
          ],
        ),
      ) ==
      true;

  Widget _picker<T>({required Key key, required T? value, required String hint, required List<DropdownMenuItem<T>> items, required ValueChanged<T?> onChanged}) =>
      AppDropdownField<T>(
        key: key,
        initialValue: value,
        isExpanded: true,
        menuMaxHeight: 420,
        dropdownColor: AppColors.card,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', filled: value != null),
        hint: Text(hint, style: AppUI.muted),
        items: items,
        onChanged: onChanged,
      );

  Widget _routePicker() => _picker<int?>(
        key: ValueKey('sf-route-$_routeId-$_pickerKey'),
        value: _routeId,
        hint: 'Choose the route',
        items: [
          for (final r in _routes)
            DropdownMenuItem<int?>(
              value: trId(r['route_id']),
              child: Text(
                '${trText(r['route_code'])} · ${trText(r['route_name'])}${r['is_active'] == false ? ' (switched off)' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => _choose(route: v),
      );

  Widget _termPicker() => _picker<int?>(
        key: ValueKey('sf-term-$_semId-$_pickerKey'),
        value: _semId,
        hint: 'Choose the term',
        items: [
          for (final t in _terms)
            DropdownMenuItem<int?>(
              value: trId(t['sem_id']),
              child: Text(_termName(t), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => _choose(sem: v),
      );

  /// Both | Pickup | Drop as one switch: a track with the chosen way filled
  /// in the app colour.
  Widget _servicePicker() => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.segmentBg,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.fieldBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final s in _services) _serviceOption(s.$1, s.$2, s.$3),
        ]),
      );

  Widget _serviceOption(String value, String label, String icon) {
    final on = _service == value;
    return Material(
      key: ValueKey('sf-service-$value'),
      color: on ? AppColors.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(AppUI.controlRadius - 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius - 3),
        onTap: on ? null : () => _choose(service: value),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(icon, size: 15, color: on ? AppColors.onPrimary : AppColors.ink3),
            SizedBox(width: 6.w),
            Text(label, style: AppUI.label.copyWith(color: on ? AppColors.onPrimary : AppColors.ink2)),
          ]),
        ),
      ),
    );
  }

  /// The route, the term, the way and Refresh in one row, all the pickers' height.
  Widget _controls() => IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_routes.isNotEmpty) ...[
            SizedBox(width: 250.w, child: _routePicker()),
            SizedBox(width: 10.w),
          ],
          if (_terms.isNotEmpty) ...[
            SizedBox(width: 170.w, child: _termPicker()),
            SizedBox(width: 10.w),
          ],
          if (_routes.isNotEmpty && _terms.isNotEmpty) ...[
            _servicePicker(),
            SizedBox(width: 10.w),
          ],
          AspectRatio(
            aspectRatio: 1,
            child: Tooltip(
              message: 'Refresh',
              child: OutlinedButton(
                onPressed: _refresh,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: AppColors.card,
                  side: const BorderSide(color: AppColors.fieldBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.controlRadius)),
                ),
                child: const AppIcon('refresh', size: 17, color: AppColors.ink2),
              ),
            ),
          ),
          if (_routes.isNotEmpty && _terms.isNotEmpty && _feeTypes.isNotEmpty) ...[
            SizedBox(width: 10.w),
            OutlinedButton.icon(
              key: const ValueKey('sf-process'),
              onPressed: _openProcess,
              style: AppUI.secondary(context),
              icon: AppIcon('receipt-edit', size: AppBtn.iconSize(context), color: AppColors.primaryText),
              label: const Text('Process Fees'),
            ),
          ],
        ]),
      );

  /// The Stage Fee Process, for the open term and the fee type of the open
  /// route's fees. It bills the saved fees, so unsaved changes come first.
  Future<void> _openProcess() async {
    if (_dirty) {
      trSnack(context, 'Save or undo the changes first: the process bills the saved stage fees.', AppColors.warning);
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StageFeeProcessDialog(
        terms: _terms,
        feeTypes: _feeTypes,
        semId: _semId,
        feeId: trId(_fees.isEmpty ? null : _fees.first['fee_id']),
        loadRoutes: TransportService.stageFeeRoutes,
        onProcess: TransportService.processStageFees,
      ),
    );
  }

  Widget _body() {
    Map<String, dynamic>? route, term;
    for (final r in _routes) {
      if (trId(r['route_id']) == _routeId) route = r;
    }
    for (final t in _terms) {
      if (trId(t['sem_id']) == _semId) term = t;
    }
    if (route == null) {
      return AppUI.empty(title: 'No routes yet', why: 'Add a route and its stages in Routes & Stops first.', icon: 'routing');
    }
    if (term == null) {
      return AppUI.empty(
        title: 'No terms for ${_year.isEmpty ? 'this year' : _year}',
        why: 'Add the terms (semesters) of this academic year in the school app first. Stage fees are set term by term.',
        icon: 'calendar',
      );
    }
    if (_feeTypes.isEmpty) {
      return AppUI.empty(
        title: 'No transport fee type',
        why: 'Add a fee type with fee category TRA in the fee master first. Stage fees are charged under it.',
        icon: 'moneys',
      );
    }
    if (_loadingFees) return const AppLoading();
    if (_feesError != null) {
      return AppUI.empty(
        title: 'Could not load the fees of this route',
        why: _feesError,
        icon: 'info-circle',
        action: OutlinedButton(
          onPressed: () {
            setState(() => _loadingFees = true);
            _loadFees();
          },
          style: AppUI.secondary(context),
          child: const Text('Retry'),
        ),
      );
    }
    final rid = trId(route['route_id']);
    return StageFeeBoard(
      key: ValueKey('sf-board-$rid-$_semId-$_service'),
      route: route,
      term: term,
      service: _service,
      stages: [for (final g in _stages) if (trId(g['route_id']) == rid) g],
      fees: _fees,
      feeTypes: _feeTypes,
      onSave: _save,
      onDirtyChanged: (v) => _dirty = v,
      otherTerms: [for (final t in _terms) if (trId(t['sem_id']) != _semId) t],
      loadTerm: (sem) => _list(rid!, sem, _service),
      onCopy: (payload) => TransportService.save('stage_fee', payload),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open Stage Fees',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton(onPressed: _reload, style: AppUI.secondary(context), child: const Text('Retry')),
      );
    }
    return Container(
      decoration: AppUI.card(),
      padding: EdgeInsets.all(AppUI.cardPad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'moneys',
          title: 'Stage Fees',
          subtitle: 'What each stage of a route costs, term by term.',
          trailing: [_controls()],
        ),
        SizedBox(height: 14.h),
        Expanded(child: _body()),
      ]),
    );
  }
}

// ── board ────────────────────────────────────────────────────────────────────
/// One route, term and way, given the lists, so it can be shown without a
/// server. [onSave] gets the save as the server takes it (tr_save
/// 'stage_fee' with "fees") and throws when it is refused.
class StageFeeBoard extends StatefulWidget {
  final Map<String, dynamic> route;

  /// The term: {sem_id, semname, semstart, semend}.
  final Map<String, dynamic> term;

  /// BOTH, PICKUP or DROP.
  final String service;

  /// This route's stages.
  final List<Map<String, dynamic>> stages;

  /// This route's fees for the term and way, as tr_list 'stage_fee' gives them.
  final List<Map<String, dynamic>> fees;

  /// The transport fee types (fee category TRA): {fee_id, feedesc}.
  final List<Map<String, dynamic>> feeTypes;
  final Future<void> Function(Map<String, dynamic> payload) onSave;
  final ValueChanged<bool>? onDirtyChanged;

  /// The year's other terms, in order, for Copy to Term.
  final List<Map<String, dynamic>> otherTerms;

  /// This route's fees for another term and the same way (what Copy to Term
  /// updates there).
  final Future<List<Map<String, dynamic>>> Function(int semId)? loadTerm;

  /// Saves fees into another term (Copy to Term): the same batch as [onSave],
  /// for that term, without changing this screen.
  final Future<void> Function(Map<String, dynamic> payload)? onCopy;

  const StageFeeBoard({
    super.key,
    required this.route,
    required this.term,
    required this.service,
    required this.stages,
    required this.fees,
    required this.feeTypes,
    required this.onSave,
    this.onDirtyChanged,
    this.otherTerms = const [],
    this.loadTerm,
    this.onCopy,
  });

  @override
  State<StageFeeBoard> createState() => _StageFeeBoardState();
}

/// What saving would do to a stage.
enum _Change { none, added, changed, removed }

/// Up to 8 digits and 2 decimals (the server keeps NUMERIC(10,2)).
class _AmountFormatter extends TextInputFormatter {
  static final _ok = RegExp(r'^\d{0,8}(\.\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      _ok.hasMatch(newValue.text) ? newValue : oldValue;
}

class _StageFeeBoardState extends State<StageFeeBoard> {
  final Map<int, TextEditingController> _amount = {};
  final Map<int, FocusNode> _focus = {};
  final _vScroll = ScrollController();

  /// Stage id -> its saved fee (the latest start date, if it has several).
  Map<int, Map<String, dynamic>> _saved = {};

  /// The stages shown, by stage number: switched on, or with a saved fee.
  List<Map<String, dynamic>> _shown = const [];

  /// The fee type and dates, as loaded and as the board shows them now.
  int? _hdrFee, _feeId;
  String? _hdrFrom, _hdrTo, _from, _to;
  bool _saving = false;
  bool _wasDirty = false;

  int get _routeId => trId(widget.route['route_id'])!;
  String? get _termFrom => _isoDate(widget.term['semstart']);
  String? get _termTo => _isoDate(widget.term['semend']);

  @override
  void initState() {
    super.initState();
    _fresh();
  }

  @override
  void didUpdateWidget(StageFeeBoard old) {
    super.didUpdateWidget(old);
    if (old.fees != widget.fees) {
      // saved: start again from what the server has now
      _fresh();
      _wasDirty = false;
    } else {
      _index();
    }
  }

  @override
  void dispose() {
    for (final c in _amount.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    _vScroll.dispose();
    super.dispose();
  }

  static String _from0(Map<String, dynamic>? f) => _isoDate(f?['effective_from']) ?? '';

  void _fresh() {
    final saved = <int, Map<String, dynamic>>{};
    for (final f in widget.fees) {
      final g = trId(f['stage_id']);
      if (g == null) continue;
      if (saved[g] == null || _from0(f).compareTo(_from0(saved[g])) > 0) saved[g] = f;
    }
    _saved = saved;
    _index();
    // the fee type and dates of the newest fee; else the term's dates
    Map<String, dynamic>? newest;
    for (final f in saved.values) {
      if (newest == null || _from0(f).compareTo(_from0(newest)) > 0) newest = f;
    }
    final known = {for (final t in widget.feeTypes) trId(t['fee_id'])};
    final fee = trId(newest?['fee_id']);
    _hdrFee = fee != null && known.contains(fee) ? fee : (widget.feeTypes.length == 1 ? trId(widget.feeTypes.first['fee_id']) : null);
    _hdrFrom = newest != null ? _isoDate(newest['effective_from']) : _termFrom;
    _hdrTo = newest != null ? _isoDate(newest['effective_to']) : _termTo;
    _feeId = _hdrFee;
    _from = _hdrFrom;
    _to = _hdrTo;
    for (final e in _amount.entries) {
      e.value.text = _savedText(e.key);
    }
  }

  void _index() {
    _shown = [
      for (final g in widget.stages)
        if (trId(g['stage_id']) != null && (g['is_active'] != false || _saved.containsKey(trId(g['stage_id'])))) g,
    ]..sort((a, b) {
        final c = (trId(a['stage_no']) ?? 0).compareTo(trId(b['stage_no']) ?? 0);
        return c != 0 ? c : trId(a['stage_id'])!.compareTo(trId(b['stage_id'])!);
      });
    for (final g in _shown) {
      final id = trId(g['stage_id'])!;
      if (!_amount.containsKey(id)) _amount[id] = TextEditingController(text: _savedText(id));
      _focus.putIfAbsent(id, () => FocusNode(onKeyEvent: (_, e) => _onKey(id, e)));
    }
  }

  String _savedText(int id) => _saved[id] == null ? '' : trNumberText(_saved[id]!['amount']);

  bool get _headerChanged => _feeId != _hdrFee || _from != _hdrFrom || _to != _hdrTo;

  _Change _change(int id) {
    final s = _saved[id];
    final t = _amount[id]?.text.trim() ?? '';
    if (s == null) return t.isEmpty ? _Change.none : _Change.added;
    if (t.isEmpty) return _Change.removed;
    // a new fee type or date goes to every saved fee
    if (_headerChanged || num.tryParse(t) != num.tryParse(trText(s['amount']))) return _Change.changed;
    return _Change.none;
  }

  List<int> get _changed => [
        for (final g in _shown)
          if (_change(trId(g['stage_id'])!) != _Change.none) trId(g['stage_id'])!,
      ];

  /// A new stage fee needs the stage switched on; a saved one can still change.
  bool _editable(Map<String, dynamic> g) => g['is_active'] != false || _saved.containsKey(trId(g['stage_id']));

  String _stageName(int id) {
    for (final g in _shown) {
      if (trId(g['stage_id']) == id) return 'Stage ${trText(g['stage_no'])} (${trText(g['stage_name'])})';
    }
    return 'a stage';
  }

  void _edit(VoidCallback change) {
    setState(change);
    final dirty = _changed.isNotEmpty;
    if (dirty != _wasDirty) {
      _wasDirty = dirty;
      widget.onDirtyChanged?.call(dirty);
    }
  }

  // ── keys ───────────────────────────────────────────────────────────────────
  /// Down / Up go to the next / previous stage's amount; Enter goes on too.
  KeyEventResult _onKey(int id, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(id, 1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(id, -1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int from, int step) {
    final ids = [for (final g in _shown) if (_editable(g)) trId(g['stage_id'])!];
    final at = ids.indexOf(from);
    if (at < 0 || at + step < 0 || at + step >= ids.length) return;
    final next = ids[at + step];
    final node = _focus[next]!;
    node.requestFocus();
    final c = _amount[next]!;
    c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length); // type to replace
    final ctx = node.context;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          alignmentPolicy: step > 0 ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    }
  }

  // ── dates ──────────────────────────────────────────────────────────────────
  Future<void> _pickDate({required bool end}) async {
    final first = DateTime.tryParse((end ? _from : null) ?? _termFrom ?? '') ?? DateTime(2000);
    final last = DateTime.tryParse(_termTo ?? '') ?? DateTime(2100);
    if (last.isBefore(first)) return;
    var initial = DateTime.tryParse((end ? _to : _from) ?? '') ?? (end ? last : first);
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await trPickDate(
      context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: '${end ? 'Effective To' : 'Effective From'}: ${_termName(widget.term)}',
    );
    if (picked == null || !mounted) return;
    _edit(() {
      if (end) {
        _to = _iso(picked);
      } else {
        _from = _iso(picked);
        if (_to != null && _to!.compareTo(_from!) < 0) _to = null; // an end before the start is no end
      }
    });
  }

  // ── save ───────────────────────────────────────────────────────────────────
  /// What the server would refuse anyway, said before sending; null if fine.
  String? _problem(List<int> ids) {
    if (_feeId == null) return 'Choose the fee type.';
    final from = _from, to = _to;
    if (from == null) return 'Choose the Effective From date.';
    if (to != null && to.compareTo(from) < 0) return 'The Effective To date cannot be before the Effective From date.';
    final a = _termFrom, b = _termTo;
    if ((a != null && from.compareTo(a) < 0) || (b != null && (from.compareTo(b) > 0 || (to != null && to.compareTo(b) > 0)))) {
      return 'The dates must be within ${_termName(widget.term)} (${formatDate(a)} to ${formatDate(b)}).';
    }
    for (final id in ids) {
      final t = _amount[id]!.text.trim();
      if (t.isNotEmpty && num.tryParse(t) == null) return 'Enter a valid fee for ${_stageName(id)}.';
    }
    return null;
  }

  Future<void> _save() async {
    final ids = _changed;
    if (ids.isEmpty) return;
    final problem = _problem(ids);
    if (problem != null) {
      trSnack(context, problem, AppColors.warning);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave({
        'route_id': _routeId,
        'sem_id': trId(widget.term['sem_id']),
        'service_type': widget.service,
        'fee_id': _feeId,
        'effective_from': _from,
        'effective_to': _to,
        'fees': [
          for (final id in ids)
            {
              'stage_id': id,
              if (_saved[id] != null) 'stage_fee_id': trId(_saved[id]!['stage_fee_id']),
              'amount': _amount[id]!.text.trim(),
            },
        ],
      });
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, ids.length == 1 ? 'Saved the fee of 1 stage.' : 'Saved the fees of ${ids.length} stages.', AppColors.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  void _undoAll() => _edit(_fresh);

  // ── copy to term ───────────────────────────────────────────────────────────
  String get _way => switch (widget.service) { 'PICKUP' => 'pickup only', 'DROP' => 'drop only', _ => 'both ways' };

  /// The saved fees Copy to Term takes: this fee type's, on stages in use.
  Map<int, Map<String, dynamic>> get _copyable => {
        for (final g in _shown)
          if (g['is_active'] != false && _saved[trId(g['stage_id'])] != null && trId(_saved[trId(g['stage_id'])]!['fee_id']) == _feeId)
            trId(g['stage_id'])!: _saved[trId(g['stage_id'])]!,
      };

  /// Why Copy to Term cannot run now; null when it can.
  String? get _copyWhyNot {
    if (widget.otherTerms.isEmpty || widget.loadTerm == null || widget.onCopy == null) return 'This year has no other term';
    if (_changed.isNotEmpty) return 'Save or undo the changes first: the saved fees are copied';
    if (_feeId == null) return 'Choose the fee type first';
    if (_copyable.isEmpty) return 'No saved ${_feeName()} fee on this route to copy';
    return null;
  }

  String _feeName() {
    for (final t in widget.feeTypes) {
      if (trId(t['fee_id']) == _feeId) return trText(t['feedesc']);
    }
    return 'stage';
  }

  /// Copies this route's saved fees of the chosen fee type and way to the
  /// same route, fee type and way of [target], with that term's dates. A
  /// stage that already has a fee there takes the new amount; nothing else
  /// in that term changes, and this screen stays as it is.
  Future<void> _copyTo(Map<String, dynamic> target) async {
    final sem = trId(target['sem_id']);
    final name = _termName(target);
    final from = _isoDate(target['semstart']);
    final src = _copyable;
    if (sem == null || src.isEmpty) return;
    if (from == null) {
      trSnack(context, '$name has no start date in the school app, so its fees would have no Effective From date.', AppColors.warning);
      return;
    }
    setState(() => _saving = true);
    try {
      // that term's fees on this route and way, to update instead of doubling
      final there = <int, Map<String, dynamic>>{};
      for (final f in await widget.loadTerm!(sem)) {
        final g = trId(f['stage_id']);
        if (g != null && (there[g] == null || _from0(f).compareTo(_from0(there[g])) > 0)) there[g] = f;
      }
      await widget.onCopy!({
        'route_id': _routeId,
        'sem_id': sem,
        'service_type': widget.service,
        'fee_id': _feeId,
        'effective_from': from,
        'effective_to': _isoDate(target['semend']),
        'fees': [
          for (final e in src.entries)
            {
              'stage_id': e.key,
              if (there[e.key] != null) 'stage_fee_id': trId(there[e.key]!['stage_fee_id']),
              'amount': trNumberText(e.value['amount']),
            },
        ],
      });
      if (!mounted) return;
      setState(() => _saving = false);
      final n = src.length;
      trSnack(
        context,
        'Copied $n stage fee${n == 1 ? '' : 's'} of route ${trText(widget.route['route_code'])} (${_feeName()}, $_way) to $name.',
        AppColors.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('copy to $name', friendlyError(e)), AppColors.error);
    }
  }

  /// Copy to Term: a button that lists the other terms; picking one copies.
  Widget _copyButton() {
    final why = _copyWhyNot;
    final can = why == null && !_saving;
    return PopupMenuButton<int>(
      key: const ValueKey('sf-copy'),
      enabled: can,
      tooltip: why ?? 'Copy these fees to another term',
      position: PopupMenuPosition.under,
      onSelected: (sem) {
        for (final t in widget.otherTerms) {
          if (trId(t['sem_id']) == sem) _copyTo(t);
        }
      },
      itemBuilder: (_) => [
        for (final t in widget.otherTerms)
          PopupMenuItem<int>(
            key: ValueKey('sf-copy-to-${trId(t['sem_id'])}'),
            value: trId(t['sem_id']),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: _termName(t), style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: '   ${formatDate(_isoDate(t['semstart']))} to ${formatDate(_isoDate(t['semend']))}', style: AppUI.muted),
            ])),
          ),
      ],
      // the look of the other buttons; the menu button takes the click
      child: IgnorePointer(
        child: OutlinedButton.icon(
          onPressed: can ? () {} : null,
          style: AppUI.secondary(context),
          icon: AppIcon('copy', size: AppBtn.iconSize(context), color: can ? AppColors.primaryText : AppColors.ink3),
          label: const Text('Copy to Term'),
        ),
      ),
    );
  }

  // ── fee type and dates (top) ───────────────────────────────────────────────
  Widget _feePicker() => AppDropdownField<int?>(
        key: ValueKey('sf-fee-$_feeId'),
        initialValue: _feeId,
        isExpanded: true,
        menuMaxHeight: 380,
        dropdownColor: AppColors.card,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', label: 'Fee Type', filled: _feeId != null),
        hint: Text('Choose the fee type', style: AppUI.muted),
        items: [
          for (final f in widget.feeTypes)
            DropdownMenuItem<int?>(
              value: trId(f['fee_id']),
              child: Text(trText(f['feedesc']), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _saving ? null : (v) => _edit(() => _feeId = v),
      );

  Widget _dateField({required bool end}) {
    final v = end ? _to : _from;
    return InkWell(
      key: ValueKey('sf-${end ? 'to' : 'from'}'),
      onTap: _saving ? null : () => _pickDate(end: end),
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: InputDecorator(
        decoration: AppUI.field(
          context,
          '',
          label: end ? 'Effective To' : 'Effective From',
          leadingIcon: 'calendar',
          filled: v != null,
          suffix: end && v != null && !_saving
              ? Tooltip(
                  message: 'No end date',
                  child: InkWell(
                    key: const ValueKey('sf-to-clear'),
                    onTap: () => _edit(() => _to = null),
                    child: const Icon(Icons.close, size: 15, color: AppColors.ink2),
                  ),
                )
              : null,
        ),
        child: Text(
          v == null ? (end ? 'Open' : 'Set date') : formatDate(v),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: v == null ? AppUI.muted : AppUI.fieldText(context),
        ),
      ),
    );
  }

  Widget _bar(int changes) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10.w,
        runSpacing: 8.h,
        children: [
          Wrap(spacing: 10.w, runSpacing: 8.h, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(width: 240.w, child: _feePicker()),
            SizedBox(width: 175.w, child: _dateField(end: false)),
            SizedBox(width: 175.w, child: _dateField(end: true)),
          ]),
          Wrap(spacing: 10.w, runSpacing: 8.h, children: [
            _copyButton(),
            OutlinedButton.icon(
              onPressed: changes == 0 || _saving ? null : _undoAll,
              style: AppUI.secondary(context),
              icon: AppIcon('rotate-left', size: AppBtn.iconSize(context), color: AppColors.primaryText),
              label: const Text('Undo All'),
            ),
            ElevatedButton.icon(
              onPressed: changes == 0 || _saving ? null : _save,
              style: AppUI.primary(context),
              icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
              label: Text(_saving ? 'Saving...' : (changes == 0 ? AppText.save : 'Save $changes Change${changes == 1 ? '' : 's'}')),
            ),
          ]),
        ],
      );

  // ── stages (table) ─────────────────────────────────────────────────────────
  static const double _wStage = 96, _wKm = 130, _wAmount = 180, _wState = 110, _wAct = 40;

  Widget _cell(double width, Widget child, {Alignment align = Alignment.centerLeft}) =>
      SizedBox(width: width, child: Padding(padding: EdgeInsets.only(right: 10.w), child: Align(alignment: align, child: child)));

  String _kmText(Map<String, dynamic> g) {
    final a = trNumberText(g['from_km']), b = trNumberText(g['to_km']);
    if (a.isEmpty && b.isEmpty) return '–';
    return '${a.isEmpty ? '?' : a} – ${b.isEmpty ? '?' : b} km';
  }

  Widget _amountField(Map<String, dynamic> g) {
    final id = trId(g['stage_id'])!;
    final can = _editable(g) && !_saving;
    return TextField(
      key: ValueKey('sf-amount-$id'),
      controller: _amount[id],
      focusNode: _focus[id],
      enabled: can,
      textAlign: TextAlign.right,
      textInputAction: TextInputAction.next,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_AmountFormatter()],
      style: AppUI.money,
      decoration: AppUI.field(context, can ? 'No fee' : 'Switched off', dense: true, filled: _amount[id]!.text.isNotEmpty)
          .copyWith(prefixText: '₹ ', prefixStyle: AppUI.money.copyWith(color: AppColors.ink3)),
      onChanged: (_) => _edit(() {}),
      onEditingComplete: () => _move(id, 1),
    );
  }

  Widget _stateCell(_Change c) => switch (c) {
        _Change.added => AppUI.chip('New', AppStatus.info),
        _Change.changed => AppUI.chip('Changed', AppStatus.warning),
        _Change.removed => Tooltip(message: 'The amount is empty: saving removes this fee', child: AppUI.chip('Remove', AppStatus.danger)),
        _Change.none => const SizedBox.shrink(),
      };

  Widget _row(Map<String, dynamic> g, int i) {
    final id = trId(g['stage_id'])!;
    final c = _change(id);
    final off = g['is_active'] == false;
    return Container(
      key: ValueKey('sf-row-$id'),
      constraints: BoxConstraints(minHeight: 50.h),
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 4.h),
      decoration: BoxDecoration(color: c != _Change.none ? AppColors.accent.withValues(alpha: 0.045) : (i.isEven ? Colors.white : AppColors.surface), border: const Border(bottom: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        _cell(_wStage, Text('Stage ${trText(g['stage_no'])}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(fontWeight: FontWeight.w700))),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: 10.w),
            child: Row(children: [
              Flexible(child: Text(trText(g['stage_name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
              if (off) ...[SizedBox(width: 8.w), Tooltip(message: 'Switched off in Routes & Stops', child: AppUI.chip('Off', AppStatus.neutral))],
            ]),
          ),
        ),
        _cell(_wKm, Text(_kmText(g), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(color: AppColors.ink2))),
        _cell(_wAmount, _amountField(g)),
        _cell(_wState, _stateCell(c)),
        SizedBox(
          width: _wAct,
          child: c == _Change.none
              ? null
              : IconButton(
                  tooltip: 'Undo this stage',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  onPressed: _saving || (c == _Change.changed && _headerChanged && _amount[id]!.text.trim() == _savedText(id))
                      ? null // only the fee type or dates changed it: Undo All puts those back
                      : () => _edit(() => _amount[id]!.text = _savedText(id)),
                  icon: const AppIcon('rotate-left', size: 16, color: AppColors.ink2),
                ),
        ),
      ]),
    );
  }

  Widget _head() {
    Widget h(String text, double width, {Alignment align = Alignment.centerLeft}) =>
        _cell(width, Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.tableHead), align: align);
    return Container(
      height: 42.h,
      padding: EdgeInsets.symmetric(horizontal: 14.w),
      decoration: const BoxDecoration(color: AppColors.tableHeadBg, border: Border(bottom: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        h('STAGE', _wStage),
        Expanded(child: Padding(padding: EdgeInsets.only(right: 10.w), child: Text('NAME', style: AppUI.tableHead))),
        h('DISTANCE', _wKm),
        h('AMOUNT', _wAmount, align: Alignment.centerRight),
        h('', _wState),
        const SizedBox(width: _wAct),
      ]),
    );
  }

  Widget _table() => Container(
        decoration: AppUI.card(),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head(),
          Expanded(
            // all the stages built, so Down can always reach the next one
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: Scrollbar(
                controller: _vScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  key: const ValueKey('sf-rows'),
                  controller: _vScroll,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var i = 0; i < _shown.length; i++) _row(_shown[i], i),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      );

  Widget _summary(int changes) {
    final withFee = _shown.where((g) => (_amount[trId(g['stage_id'])]?.text.trim() ?? '').isNotEmpty).length;
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: '${_shown.length} stage${_shown.length == 1 ? '' : 's'} · $withFee with a fee · ${_termName(widget.term)}, $_way',
          style: AppUI.muted,
        ),
        if (changes > 0)
          TextSpan(
            text: '   ·   $changes change${changes == 1 ? '' : 's'} not saved',
            style: AppUI.muted.copyWith(color: AppColors.goldDark, fontWeight: FontWeight.w700),
          ),
        TextSpan(
          text: '   ·   ↓ or Enter goes to the next stage. Clear an amount to remove that stage\'s fee.',
          style: AppUI.muted,
        ),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) {
      return AppUI.empty(
        title: 'This route has no stages',
        why: 'Add its stages in Routes & Stops first. Each stage gets its own fee.',
        icon: 'routing',
      );
    }
    final changes = _changed.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _bar(changes),
      SizedBox(height: 12.h),
      Expanded(child: _table()),
      SizedBox(height: 8.h),
      _summary(changes),
    ]);
  }
}
