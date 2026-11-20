import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/fee_kind.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/master_usage.dart';
import '../../utils/payment_gateways.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../widgets/online_route_chip.dart';
import '../../widgets/quick_bank_dialog.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../utils/formatters.dart' show formatIndianNumber;
import '../../widgets/card_title_block.dart';
import '../../widgets/focusable_tap.dart';
import '../../widgets/pill_tab.dart';
import '../admin/master_import_screen.dart';
import '../admin/settings_screen.dart' show PaymentSequenceTab, FineRulesTab;
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/sequence_ui.dart';

/// Fee Master — clean CRUD (Admission-Master style) for the fee lookups:
/// Fee Group, Fee Type, Concession, Class Fee Demand, Payment Sequence, Fine
/// Rules. Each tab is a left "Add" form + right table. Payment Sequence and
/// Fine Rules were previously in a standalone "Sequence Creation" sidebar
/// entry; they live here now so all fee configuration is in one place.
/// Fee Master — pill-tab page shell per fee-master-design.md § 1.
class FeeMasterScreen extends StatefulWidget {
  /// Which tab to open at. Each tab is its own sidebar submenu, so the sidebar
  /// is normally the tab selector and [showTabBar] is false.
  final int initialTab;

  /// When false the in-screen pill tab bar is hidden.
  final bool showTabBar;

  const FeeMasterScreen({super.key, this.initialTab = 0, this.showTabBar = true});

  /// The tab order, and the sidebar's link to it.
  ///
  /// On the widget rather than the State because the sidebar resolves a
  /// sub-item to a tab by LABEL, not by position, and reads this from
  /// outside the file -- see _subTab in dashboard_screen.dart.
  static const tabLabels = [
    'Fee Group',
    'Fee Type',
    'Semester',
    'Demand No',
    'Concession No',
    'Refund No',
    'Class Fee Demand',
    'Receipt Sequence',
    'Fine Rules',
    'Class Matching',
    'Advance Fee Definition',
    'Advance Fee Receipt No',
    // Cancelled / bounced receipt numbers (CANCNO) -- Sequence Master only.
    'Cancel No',
    // Arrear fee receipts (ARRFEENO) -- Sequence Master only.
    'Arrear Receipt No',
    // Miscellaneous Collection receipts (MISCFEENO) -- Sequence Master only.
    'Misc Receipt No',
  ];

  @override
  State<FeeMasterScreen> createState() => _FeeMasterScreenState();
}

class _FeeMasterScreenState extends State<FeeMasterScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _tabIcons = [
    'receipt-discount',
    'tag',
    'calendar-1',
    'category',
    'discount-shape',
    'money-recive',
    'empty-wallet-add',
    'sort',
    'hashtag',
    'warning-2',
    'arrow-swap-horizontal',
    'empty-wallet-add',
    'close-circle',
    'receipt-minus',
    'receipt-text',
  ];

  /// What a tab shows. [FeeMasterScreen.tabLabels] are routing keys and stay
  /// as they are; only the displayed text spells out "No." in full.
  static String _tabText(String key) {
    // 'Class Matching' is shown as Section Mapping (user, 2026-11-14).
    final t = schoolTerm(key == 'Class Matching' ? 'Class Mapping' : key);
    return t.endsWith(' No') ? '$t.' : t;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: FeeMasterScreen.tabLabels.length,
        vsync: this,
        // clamp: a sub-index carried over from a screen with more tabs
        // would otherwise be out of range here.
        initialIndex: widget.initialTab.clamp(0, FeeMasterScreen.tabLabels.length - 1));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTabBar)
          ListenableBuilder(
            listenable: _tabController,
            builder: (context, _) {
              final selected = _tabController.index;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                // Wrap, not a horizontal scroll view: with nine tabs the row runs
                // past the window on a laptop screen, and a horizontal
                // SingleChildScrollView has no scrollbar and ignores the mouse
                // wheel on desktop — the last tabs were simply unreachable.
                // Wrapping keeps one line when it fits and flows to a second when
                // it doesn't, so every tab stays clickable at any width.
                child: Wrap(
                  spacing: PillTab.gap(context),
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < FeeMasterScreen.tabLabels.length; i++)
                      PillTab(
                        icon: _tabIcons[i],
                        label: _tabText(FeeMasterScreen.tabLabels[i]),
                        selected: selected == i,
                        onTap: () => _tabController.animateTo(i),
                      ),
                  ],
                ),
              );
            },
          ),
        SizedBox(height: 6.h),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              _FeeGroupPanel(),
              _FeeTypePanel(),
              _SemesterPanel(),
              _DemandSequencePanel(),
              // Concession No + (school) Arrear Concession No in one frame.
              _DemandSequencePanel(actname: 'CONNO', defaultPrefix: 'CN', title: 'Concession No.', withArrear: true),
              _DemandSequencePanel(actname: 'REFNO', defaultPrefix: 'RF', title: 'Refund No.'),
              _ClassFeeDemandPanel(),
              PaymentSequenceTab(),
              FineRulesTab(),
              _ClassMatchPanel(),
              _AdvanceFeePanel(),
              // Advance Fee Collection's own receipt series, one per fee group.
              PaymentSequenceTab(series: 'ADVFEENO'),
              // Every cancelled / bounced receipt (school_receipt_cancel_no.sql).
              _DemandSequencePanel(actname: 'CANCNO', defaultPrefix: 'CAN', title: 'Cancel No.'),
              // Arrear fee receipts, one series per fee group.
              PaymentSequenceTab(series: 'ARRFEENO'),
              // Miscellaneous Collection receipts, one series per fee group.
              PaymentSequenceTab(series: 'MISCFEENO'),
            ],
          ),
        ),
      ],
    );
  }
}

// ── shared bits ───────────────────────────────────────────────────────────
/// Context-free twin of [AppUI.field]: radius, fill, padding, height and the
/// 2px focus ring all come from the global input theme; only the "filled"
/// accent edge is set here (same colour AppUI.field uses).
InputDecoration _dec(String label, {bool filled = false}) {
  final rest = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppUI.controlRadius),
    borderSide: BorderSide(color: filled ? AppColors.primary.withValues(alpha: 0.55) : AppColors.border),
  );
  return InputDecoration(
    labelText: label.isEmpty ? null : label,
    isDense: true,
    border: rest,
    enabledBorder: rest,
  );
}

void _snack(BuildContext ctx, String msg, Color color) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
}

Future<Map<String, dynamic>?> _currentYear(int insId) async {
  final years = await SupabaseService.getYears(insId);
  return years.isNotEmpty ? years.first : null;
}

/// Next id for a per-schema master = max(idCol) + 1. These tables have
/// sequence-backed triggers, but explicit-id imports leave the sequence
/// behind, so supplying an explicit id avoids primary-key collisions.
Future<int> _nextId(String table, String idCol) async {
  final res = await SupabaseService.fromSchema(table).select(idCol).order(idCol, ascending: false).limit(1).maybeSingle();
  final cur = res?[idCol];
  final n = cur is int ? cur : int.tryParse(cur?.toString() ?? '0') ?? 0;
  return n + 1;
}

TextStyle _h() => AppUI.tableHead;
TextStyle _c() => AppUI.cell;

// ── design helpers (all from the AppUI kit) ──

/// Field label; a trailing " *" is drawn as the kit's red required mark.
Widget _lbl(String text) {
  final req = text.endsWith(' *');
  final t = req ? text.substring(0, text.length - 2) : text;
  return Text.rich(TextSpan(children: [
    TextSpan(text: t, style: AppUI.label),
    if (req) const TextSpan(text: ' *', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w800)),
  ]));
}

// [filled] = the field has a value. Filled fields get an amber (accent)
// border; empty fields stay grey; the focused border is always amber.
/// [leadingIcon] puts an AppIcon in the field's prefix, so a toolbar of
/// dropdowns can be read at a glance rather than by its placeholder text. It
/// keeps the accent colour of the filled state, so the icon reinforces
/// "chosen" instead of competing with it.
InputDecoration _filledFieldDec(BuildContext context, String hint, {bool filled = false, String? leadingIcon}) =>
    AppUI.field(context, hint, filled: filled, leadingIcon: leadingIcon);

TextStyle _fieldTextStyle(BuildContext context) => AppUI.fieldText(context);

/// A dropdown's placeholder, passed as its own `hint:`. Left to the
/// decoration, it is laid on the empty button's baseline and sits low in the
/// box; as the button's hint it is centred like a text field's.
Widget _ddHint(BuildContext context, String hint) => AppFitText(hint, style: AppUI.field(context, hint).hintStyle);

/// Outer Add card — the kit card (white, 16r, 1px border, 20 padding).
/// Header uses the shared [CardTitleBlock] with optional subtitle.
Widget _addCard({required String icon, required String title, String? subtitle, required Widget child}) {
  return Container(
    padding: EdgeInsets.all(AppUI.cardPad),
    decoration: AppUI.card(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CardTitleBlock(icon: icon, title: title, subtitle: subtitle),
        SizedBox(height: 20.h),
        child,
      ],
    ),
  );
}

/// Outer List card — title row with icon-tile block + count badge + optional
/// action; inner bordered table card inside.
Widget _listCard({
  required String icon,
  required String title,
  String? subtitle,
  required int count,
  required String countLabel,
  required List<Widget> headerCells,
  required Widget body,
  Widget? action,
}) {
  return Container(
    padding: EdgeInsets.all(AppUI.cardPad),
    decoration: AppUI.card(),
    child: Column(
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: 12.h),
          child: Row(children: [
            CardTitleBlock(icon: icon, title: title, subtitle: subtitle),
            SizedBox(width: 10.w),
            AppUI.chip('$count $countLabel', AppStatus.info),
            const Spacer(),
            if (action != null) action,
          ]),
        ),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              children: [
                Container(
                  color: AppColors.tableHeadBg,
                  padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                  child: Row(children: headerCells),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Compact-or-expanded amber Import CSV/Excel button — sits in the
/// `action` slot of `_listCard`. Opens [MasterImportScreen] at [tabIndex],
/// then runs [onReturn].
Widget _importButton(
  BuildContext context, {
  required String title,
  required int tabIndex,
  required bool disabled,
  required Future<void> Function() onReturn,
}) {
  final iconSize = AppBtn.iconSize(context);
  return SizedBox(
    child: ElevatedButton.icon(
      onPressed: disabled
          ? null
          : () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    backgroundColor: AppColors.surface,
                    appBar: AppBar(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.textPrimary,
                      elevation: 0,
                      shape: const Border(bottom: BorderSide(color: AppColors.border)),
                      title: Row(children: [
                        const AppIcon('document-upload', size: 20, color: AppColors.primary),
                        SizedBox(width: 10.w),
                        Text('Import $title', style: AppUI.cardTitle),
                      ]),
                    ),
                    body: Padding(
                      padding: EdgeInsets.all(16.w),
                      child: MasterImportScreen(initialTabIndex: tabIndex, showInternalTabs: false),
                    ),
                  ),
                ),
              );
              await onReturn();
            },
      icon: AppIcon('document-upload', size: iconSize, color: Colors.white),
      label: const Text('Import CSV/Excel'),
    ),
  );
}

Future<bool> _confirmDelete(BuildContext ctx, String what) async {
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: const Text('Confirm Delete'),
      content: Text('Delete this $what?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
      ],
    ),
  );
  return ok == true;
}

// ══════════════════════════════════════════════════════════════════════════
// FEE GROUP
// ══════════════════════════════════════════════════════════════════════════
class _FeeGroupPanel extends StatefulWidget {
  const _FeeGroupPanel();
  @override
  State<_FeeGroupPanel> createState() => _FeeGroupPanelState();
}

class _FeeGroupPanelState extends State<_FeeGroupPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  // The bank account the group's money is collected into (feegroup.ban_id),
  // picked -- or created -- right here (user, 2026-11-14). No bank: Fee
  // Collection takes Cash only for the group.
  List<Map<String, dynamic>> _banks = [];
  int? _banId;
  int? _bankIdOf(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  String _bankLabel(Map<String, dynamic> b) {
    final acc = '${b['banaccno'] ?? ''}'.trim();
    return '${'${b['banname'] ?? ''}'.trim()}${acc.length > 4 ? '  ·  •••• ${acc.substring(acc.length - 4)}' : (acc.isEmpty ? '' : '  ·  $acc')}';
  }
  Map<String, dynamic>? _bankById(int? id) =>
      id == null ? null : _banks.where((b) => _bankIdOf(b['ban_id']) == id).firstOrNull;
  int? _editId; // non-null while editing an existing row
  bool _loading = true, _saving = false;

  // School: where each group's ONLINE money goes. Choosing a bank does not by
  // itself send it there (user, 2026-11-18). Only an Admin can read the
  // gateway; for anyone else the column stays hidden.
  bool _onlineKnown = false;
  Map<String, dynamic>? _gateway;
  Map<int, Map<String, dynamic>> _bankMerchants = {};

  Future<void> _loadOnline() async {
    if (!isSchool) return;
    try {
      final l = await PaymentGatewayService.list();
      final gws = (l['gateways'] as List? ?? const []);
      final bm = await PaymentGatewayService.bankMerchants();
      if (!mounted) return;
      setState(() {
        _gateway = gws.isEmpty ? null : Map<String, dynamic>.from(gws.first as Map);
        _bankMerchants = bm;
        _onlineKnown = true;
      });
    } catch (e) {
      debugPrint('fee group: gateway lookup failed: $e');
    }
  }

  OnlineRoute _routeOf(int? banId) =>
      onlineRouteFor(gateway: _gateway, bank: _bankById(banId), bankMerchants: _bankMerchants);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    _loadOnline();
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('feegroup').select('*').eq('ins_id', _insId).eq('activestatus', 1).order('fg_id', ascending: true),
        SupabaseService.getBanks(),
      ]);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(r[0] as List);
        _banks = List<Map<String, dynamic>>.from(r[1] as List);
        if (_banId != null && _bankById(_banId) == null) _banId = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// feegroup.hostellers_only. Fees in a ticked group are offered only to a
  /// student whose students.hostel is 'Y' -- Student Fee Definition was
  /// offering MESS FEE to day scholars because nothing narrowed the list by
  /// group. Stated here rather than guessed from the group's name: a name
  /// test misses "MA" (mess advance), and renaming a group would silently
  /// change who gets billed.
  bool _hostelOnly = false;

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['fg_id'] is int ? r['fg_id'] as int : int.tryParse(r['fg_id'].toString());
      _name.text = r['fgdesc']?.toString() ?? '';
      _hostelOnly = !isSchool && r['hostellers_only'] == true;
      _banId = _bankById(_bankIdOf(r['ban_id'])) == null ? null : _bankIdOf(r['ban_id']);
    });
  }

  /// "Manage bank accounts": every account in full, then the list is re-read
  /// (an account may have been renamed or removed).
  Future<void> _manageBanks() async {
    await showManageBanksDialog(context);
    if (mounted) await _load();
  }

  /// "+ New bank account": add one without leaving the screen, and pick it.
  Future<void> _newBank() async {
    final id = await showQuickBankDialog(context, existing: _banks);
    if (id == null || !mounted) return;
    final banks = await SupabaseService.getBanks();
    if (!mounted) return;
    setState(() {
      _banks = banks;
      _banId = id;
    });
    _snack(context, 'Bank account added -- save the fee group to collect into it.', AppColors.success);
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _hostelOnly = false;
      _banId = null;
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a group name.', AppColors.warning);
    if (_rows.any((r) => (r['fgdesc']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() && (r['fg_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists. Enter a different fee group name.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await SupabaseService.saveSchemaRow('feegroup', {'fgdesc': name, 'hostellers_only': _hostelOnly, 'ban_id': _banId}, pkCol: 'fg_id', pkVal: _editId!);
        if (mounted) _snack(context, 'Fee group updated.', AppColors.success);
      } else {
        final yr = await _currentYear(_insId);
        await SupabaseService.saveSchemaRow('feegroup', {
          'fg_id': await _nextId('feegroup', 'fg_id'),
          'fgdesc': name,
          'hostellers_only': _hostelOnly,
          'ban_id': _banId,
          'ins_id': _insId,
          // School: fee groups / fee types are shared by every year (no year columns).
          if (!isSchool) 'yr_id': yr != null ? int.tryParse(yr['yr_id'].toString()) ?? 0 : 0,
          if (!isSchool) 'yrlabel': yr?['yrlabel']?.toString() ?? '',
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Fee group added.', AppColors.success);
      }
      _name.clear();
      _editId = null;
      _hostelOnly = false;
      _banId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Could not save the fee group. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    // Refused before the confirmation dialog -- see master_usage.dart.
    final _name = _rows.firstWhere((r) => r['fg_id'].toString() == id.toString(), orElse: () => const {})['fgdesc']?.toString() ?? 'this fee group';
    final _used = await countReferencing('feetype', [('fg_id', id)]);
    if (_used > 0) {
      if (mounted) {
        await showMasterInUseDialog(context, name: _name, count: _used, noun: 'fee type', fix: 'Move or delete those fee types first.');
      }
      return;
    }
    if (!mounted) return;
    if (!await _confirmDelete(context, 'fee group')) return;
    try {
      await SupabaseService.deleteSchemaRow('feegroup', 'fg_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Could not delete the fee group. ${friendlyError(e)}', AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320.w,
          child: _addCard(
            icon: 'receipt-discount',
            title: _editId != null ? 'Edit Fee Group' : 'Add Fee Group',
            subtitle: 'group fees by category',
            child: FocusTraversalGroup(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _lbl('Group Name *'),
                SizedBox(height: 6.h),
                TextField(
                  controller: _name,
                  style: AppUI.fieldText(context, filled: _name.text.trim().isNotEmpty),
                  decoration: _filledFieldDec(context, 'Enter group name', filled: _name.text.trim().isNotEmpty),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _add(),
                ),
                SizedBox(height: 14.h),
                _lbl('Bank Account'),
                SizedBox(height: 6.h),
                AppDropdownField<int?>(
                  initialValue: _banId,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: AppUI.fieldText(context, filled: _banId != null),
                  decoration: _filledFieldDec(context, 'Not mapped -- Cash only', filled: _banId != null),
                  items: [
                    DropdownMenuItem<int?>(value: null, child: Text('Not mapped -- Cash only', overflow: TextOverflow.ellipsis)),
                    for (final b in _banks)
                      DropdownMenuItem<int?>(value: _bankIdOf(b['ban_id']), child: Text(_bankLabel(b), overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: _saving ? null : (v) => setState(() => _banId = v),
                ),
                SizedBox(height: 4.h),
                Row(children: [
                  Expanded(
                    child: Text(
                      _banId == null
                          ? 'Without a bank account only Cash can be collected for this group.'
                          : _onlineKnown
                              ? _routeOf(_banId).detail
                              : "This group's fees are banked here.",
                      style: AppUI.muted.copyWith(
                          fontSize: 12.sp,
                          color: _banId == null
                              ? AppColors.warning
                              : _onlineKnown && _routeOf(_banId).kind == OnlineRouteKind.problem
                                  ? AppColors.error
                                  : null),
                    ),
                  ),
                ]),
                // Add one on the spot, or open every account in full (edit,
                // delete, merchant keys) -- Payment Gateways no longer has them.
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton.icon(
                    onPressed: _saving ? null : _newBank,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New'),
                  ),
                  SizedBox(width: 4.w),
                  TextButton.icon(
                    onPressed: _saving ? null : _manageBanks,
                    icon: const Icon(Icons.account_balance_outlined, size: 16),
                    label: const Text('Manage bank accounts'),
                  ),
                ]),
                SizedBox(height: 10.h),
                // Narrows who the group's fees are offered to. Only Student Fee
                // Definition reads it today; Misc Collection and Advance can
                // use the same flag rather than each inventing a rule.
                // Not on a school: a fee line's own Dayscholar / Hostler
                // (Applicable To) decides that there.
                if (!isSchool) ...[
                InkWell(
                  onTap: _saving ? null : () => setState(() => _hostelOnly = !_hostelOnly),
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 4.h),
                    child: Row(children: [
                      SizedBox(
                        width: 24.w,
                        child: Checkbox(
                          value: _hostelOnly,
                          activeColor: AppColors.accent,
                          visualDensity: VisualDensity.compact,
                          onChanged: _saving ? null : (v) => setState(() => _hostelOnly = v ?? false),
                        ),
                      ),
                      SizedBox(width: 4.w),
                      Expanded(
                        child: Text('Hostellers Only', style: AppUI.label),
                      ),
                    ]),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(left: 28.w),
                  child: Text('These fees are offered only to students marked as hostellers.', style: AppUI.muted),
                ),
                ],
                SizedBox(height: 18.h),
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _add,
                      icon: Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                      label: Text(_editId != null ? AppText.update : AppText.save),
                    ),
                  ),
                  if (_editId != null) ...[
                    SizedBox(width: 8.w),
                    OutlinedButton(onPressed: _saving ? null : _cancelEdit, child: const Text(AppText.cancel)),
                  ],
                ]),
                SizedBox(height: 10.h),
                AppUI.requiredNote(),
              ],
            )),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _listCard(
            icon: 'receipt-discount',
            title: 'Fee Groups',
            subtitle: 'all fee groups in this institution',
            count: _rows.length,
            countLabel: 'groups',
            action: _importButton(context, title: 'Fee Group', tabIndex: 4, disabled: _saving, onReturn: _load),
            headerCells: [
              SizedBox(width: 50.w, child: Text('S NO.', style: _h())),
              Expanded(child: Text('GROUP NAME', style: _h())),
              Expanded(child: Text('BANK ACCOUNT', style: _h())),
              if (_onlineKnown) Expanded(child: Text('ONLINE MONEY GOES TO', style: _h())),
              if (!isSchool) SizedBox(width: 120.w, child: Text('HOSTELLERS ONLY', textAlign: TextAlign.center, style: _h())),
              SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? AppUI.empty(title: 'No fee groups', why: 'Add one with the form on the left, or use Import CSV/Excel.')
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['fg_id'] is int ? r['fg_id'] as int : int.tryParse(r['fg_id'].toString()) ?? 0;
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                              Expanded(child: Text(r['fgdesc']?.toString() ?? '', style: _c())),
                              Expanded(
                                child: Builder(builder: (_) {
                                  final b = _bankById(_bankIdOf(r['ban_id']));
                                  return b == null
                                      ? Align(alignment: Alignment.centerLeft, child: AppUI.chip('Cash only -- no bank', AppStatus.danger))
                                      : Text(_bankLabel(b), style: _c(), overflow: TextOverflow.ellipsis);
                                }),
                              ),
                              if (_onlineKnown)
                                Expanded(
                                  child: _bankById(_bankIdOf(r['ban_id'])) == null
                                      ? Text('-', style: AppUI.cell.copyWith(color: AppColors.textLight))
                                      : onlineRouteChip(_routeOf(_bankIdOf(r['ban_id']))),
                                ),
                              if (!isSchool)
                              SizedBox(
                                width: 120.w,
                                child: Center(
                                  child: r['hostellers_only'] == true
                                      ? AppUI.chip('Yes', AppStatus.success)
                                      : Text('-', style: AppUI.cell.copyWith(color: AppColors.textLight)),
                                ),
                              ),
                              SizedBox(
                                  width: 90.w,
                                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    InkWell(onTap: () => _edit(r), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('edit-2', size: 16, color: AppColors.primary))),
                                    SizedBox(width: 8.w),
                                    InkWell(onTap: () => _delete(id), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 16, color: AppColors.error))),
                                  ])),
                            ]),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// FEE TYPE
// ══════════════════════════════════════════════════════════════════════════
class _FeeTypePanel extends StatefulWidget {
  const _FeeTypePanel();
  @override
  State<_FeeTypePanel> createState() => _FeeTypePanelState();
}

class _FeeTypePanelState extends State<_FeeTypePanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _short = TextEditingController();
  final _type = TextEditingController();
  // School: the old app's fee Type -- SCH (school) or HOS (hostel), stored in
  // feetype.feecat (user, 2026-11-11). Reg/Opt stays in feetype.type.
  String? _cat;
  String? _fgId;
  String? _fine;

  /// Clearance order. Lower clears first; 100 is the neutral middle, so a fee
  /// type is only ordered against another when it is deliberately given a
  /// different number. Bus 10 clears before everything, Exam 900 after.
  final _payseq = TextEditingController();

  /// 'Yes' = a part payment is accepted; 'No' = the whole balance or nothing.
  String? _partial;
  List<Map<String, dynamic>> _feeGroups = [];
  List<Map<String, dynamic>> _rows = [];
  Map<int, String> _fgName = {};
  int? _editId; // non-null while editing an existing row
  bool _loading = true, _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    _type.dispose();
    _payseq.dispose();
    super.dispose();
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['fee_id'] is int ? r['fee_id'] as int : int.tryParse(r['fee_id'].toString());
      _name.text = r['feedesc']?.toString() ?? '';
      _short.text = r['feeshort']?.toString() ?? '';
      _type.text = r['type']?.toString() ?? '';
      _cat = const {'SCH', 'HOS'}.contains(r['feecat']?.toString()) ? r['feecat'].toString() : null;
      _fgId = r['fg_id']?.toString();
      _fine = '${r['feefineapplicable'] ?? 0}' == '1' ? 'Yes' : 'No';
      // Absent on a database where fee_payment_priority.sql has not run: show
      // the same neutral defaults the migration would apply.
      // Blank when the column is NULL -- not '100'. NULL means "never
      // configured", and the check function reads it as 100 anyway, so printing
      // 100 here made every untouched fee type look deliberately set. The hint
      // text carries the effective default instead.
      _payseq.text = r['payseq']?.toString() ?? '';
      _partial = (r['partialallowed']?.toString() ?? 'Y') == 'N' ? 'No' : 'Yes';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _short.clear();
      _type.clear();
      _cat = null;
      _fine = null;
      _payseq.clear();
      _partial = null;
    });
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  // Compact form (user, 2026-11-11): short fields sit two to a row so the
  // whole form fits the window without scrolling.
  Widget _field(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [_lbl(label), SizedBox(height: 6.h), child],
      );

  Widget _pair(Widget a, Widget b) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: a), SizedBox(width: 12.w), Expanded(child: b)],
      );

  Widget _text(TextEditingController c, String hint, {bool number = false}) => TextField(
        controller: c,
        keyboardType: number ? TextInputType.number : null,
        style: AppUI.fieldText(context, filled: c.text.trim().isNotEmpty),
        decoration: _filledFieldDec(context, hint, filled: c.text.trim().isNotEmpty),
        onChanged: (_) => setState(() {}),
      );

  /// [items] are (value, label) pairs.
  Widget _dd(String? value, String hint, List<(String, String)> items, ValueChanged<String?> onChanged) =>
      AppDropdownField<String>(
        initialValue: items.any((e) => e.$1 == value) ? value : null,
        isExpanded: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        style: _fieldTextStyle(context),
        icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
        decoration: _filledFieldDec(context, hint, filled: value != null && value.isNotEmpty),
        hint: _ddHint(context, hint),
        items: [
          for (final e in items)
            DropdownMenuItem(value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context))),
        ],
        selectedItemBuilder: (context) => [
          for (final e in items)
            Align(
                alignment: Alignment.centerLeft,
                child: Text(e.$2, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
        ],
        onChanged: onChanged,
      );

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final groups = await SupabaseService.getFeeGroups(_insId);
      final fgList = List<Map<String, dynamic>>.from(groups);
      final fgIds = fgList.map((g) => g['fg_id'] as int).toList();
      final types = fgIds.isEmpty ? <dynamic>[] : await SupabaseService.fromSchema('feetype').select('*').inFilter('fg_id', fgIds).eq('activestatus', 1).order('fee_id', ascending: true);
      if (!mounted) return;
      setState(() {
        _feeGroups = fgList;
        _fgName = {for (final g in fgList) g['fg_id'] as int: g['fgdesc']?.toString() ?? ''};
        // FeeType Order first, then ID (rows without an order go last).
        _rows = List<Map<String, dynamic>>.from(types)
          ..sort((a, b) {
            final oa = (a['ordid'] as num?)?.toInt() ?? 1 << 30, ob = (b['ordid'] as num?)?.toInt() ?? 1 << 30;
            if (oa != ob) return oa.compareTo(ob);
            return ((a['fee_id'] as num?) ?? 0).compareTo((b['fee_id'] as num?) ?? 0);
          });
        // Start with no fee group selected so the 'Select fee group'
        // placeholder shows (edit mode sets _fgId explicitly).
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Why [name] / [short] cannot be saved: a fee type belongs to ONE fee group,
  /// so the same fee in two groups would clash on receipts and fee demands,
  /// which find a fee type by its name (user, 2026-11-18). Spaces, dots and
  /// capitals do not make a different fee. Read fresh, across every group.
  Future<String?> _feeTypeClash(String name, String short) async {
    final rows = await SupabaseService.fromSchema('feetype')
        .select('fee_id, feedesc, feeshort, fg_id')
        .eq('ins_id', _insId)
        .eq('activestatus', 1);
    final others = [
      for (final r in rows as List)
        if ('${r['fee_id']}' != '$_editId') Map<String, dynamic>.from(r as Map),
    ];
    String groupOf(Map<String, dynamic> r) {
      final g = _fgName[(r['fg_id'] as num?)?.toInt()]?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
      return g.isEmpty ? 'another fee group' : g;
    }

    for (final r in others) {
      if (feeTypeKey(r['feedesc']) == feeTypeKey(name)) {
        return '"${'${r['feedesc']}'.trim()}" already exists in ${groupOf(r)}. A fee type can be in only one fee group.';
      }
    }
    if (feeTypeKey(short).isNotEmpty) {
      for (final r in others) {
        if (feeTypeKey(r['feeshort']) == feeTypeKey(short)) {
          return '"$short" is already the short name of ${'${r['feedesc']}'.trim()} (${groupOf(r)}). Enter a different short name.';
        }
      }
    }
    return null;
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a fee name.', AppColors.warning);
    if (_fgId == null) return _snack(context, 'Add a fee group first (Fee Master > Fee Group).', AppColors.warning);
    setState(() => _saving = true);
    try {
      final clash = await _feeTypeClash(name, _short.text.trim());
      if (!mounted) return;
      if (clash != null) return _snack(context, clash, AppColors.warning);
      if (_editId != null) {
        await SupabaseService.saveSchemaRow(
            'feetype',
            {
              'feedesc': name,
              'feeshort': _short.text.trim(),
              'fg_id': int.tryParse(_fgId!),
              'feefineapplicable': _fine == 'Yes' ? 1 : 0,
              'type': _type.text.trim().isEmpty ? null : _type.text.trim(),
              // Blank saves as NULL, so it stays blank on the next edit. Writing
              // 100 would mean the same to the rule engine but would quietly turn
              // "not configured" into "configured" the first time anything else on
              // the form was saved.
              'payseq': _payseq.text.trim().isEmpty ? null : int.tryParse(_payseq.text.trim()),
              'partialallowed': _partial == 'No' ? 'N' : 'Y',
              if (isSchool) 'feecat': _cat ?? 'SCH',
            },
            pkCol: 'fee_id',
            pkVal: _editId!);
        if (mounted) _snack(context, 'Fee type updated.', AppColors.success);
      } else {
        final yr = await _currentYear(_insId);
        await SupabaseService.saveSchemaRow('feetype', {
          'fee_id': await _nextId('feetype', 'fee_id'),
          if (isSchool) 'feecat': _cat ?? 'SCH',
          'feedesc': name,
          'feeshort': _short.text.trim(),
          'fg_id': int.tryParse(_fgId!),
          'feefineapplicable': _fine == 'Yes' ? 1 : 0,
          'type': _type.text.trim().isEmpty ? null : _type.text.trim(),
          // Blank saves as NULL, so it stays blank on the next edit. Writing
          // 100 would mean the same to the rule engine but would quietly turn
          // "not configured" into "configured" the first time anything else on
          // the form was saved.
          'payseq': _payseq.text.trim().isEmpty ? null : int.tryParse(_payseq.text.trim()),
          'partialallowed': _partial == 'No' ? 'N' : 'Y',
          // Display order: next after the highest already in the list.
          'ordid': _rows.fold<int>(0, (m, r) { final o = (r['ordid'] as num?)?.toInt() ?? 0; return o > m ? o : m; }) + 1,
          // School: fee groups / fee types are shared by every year (no year columns).
          if (!isSchool) 'yr_id': yr != null ? int.tryParse(yr['yr_id'].toString()) ?? 0 : 0,
          if (!isSchool) 'yrlabel': yr?['yrlabel']?.toString() ?? '',
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Fee type added.', AppColors.success);
      }
      _name.clear();
      _short.clear();
      _type.clear();
      _cat = null;
      _payseq.clear();
      _partial = null;
      _editId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Could not save the fee type. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    // Refused before the confirmation dialog -- see master_usage.dart.
    final _name = _rows.firstWhere((r) => r['fee_id'].toString() == id.toString(), orElse: () => const {})['feedesc']?.toString() ?? 'this fee type';
    final _used = await countReferencing('feedemand', [('fee_id', id), ('demfeetype', _name)]);
    if (_used > 0) {
      if (mounted) {
        await showMasterInUseDialog(context, name: _name, count: _used, noun: 'fee demand', fix: 'Fee demands have already been raised for this fee type, so it cannot be deleted.');
      }
      return;
    }
    if (!mounted) return;
    if (!await _confirmDelete(context, 'fee type')) return;
    try {
      await SupabaseService.deleteSchemaRow('feetype', 'fee_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Could not delete the fee type. ${friendlyError(e)}', AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 380.w,
          // Scrollable: this Row hands the card the window's full height as a
          // hard limit, and the form is a min-height Column, so on a laptop
          // screen the last fields (Priority, its help text, Part Payment
          // Allowed) and the Save button fell 167px past the bottom and were
          // unreachable. Scrolling keeps every field usable at any height;
          // the card still sizes to its content when there is room.
          child: SingleChildScrollView(
            child: _addCard(
              icon: 'tag',
              title: _editId != null ? 'Edit Fee Type' : 'Add Fee Type',
              subtitle: 'individual fees inside a group',
              child: FocusTraversalGroup(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _field('Fee Type Name *', _text(_name, 'Enter fee type name')),
                  SizedBox(height: 14.h),
                  _pair(
                    _field('Short Name', _text(_short, 'Short name')),
                    _field('Fee Group *', _dd(_fgId, 'Select', [
                      for (final g in _feeGroups) (g['fg_id'].toString(), g['fgdesc']?.toString() ?? ''),
                    ], (v) => setState(() => _fgId = v))),
                  ),
                  SizedBox(height: 14.h),
                  _pair(
                    _field('Fine Applicable', _dd(_fine, 'Yes / No', const [('No', 'No'), ('Yes', 'Yes')],
                        (v) => setState(() => _fine = v))),
                    // School: Type (SCH / HOS). College: its fee category.
                    isSchool
                        ? _field('Type', _dd(_cat, 'SCH / HOS', const [('SCH', 'SCH  School'), ('HOS', 'HOS  Hostel')],
                            (v) => setState(() => _cat = v)))
                        : _field('Fee Category', _dd(_type.text.trim().toUpperCase(), 'Select', [for (final k in kFeeKinds) (k.code, k.label)],
                            (v) => setState(() => _type.text = v ?? ''))),
                  ),
                  SizedBox(height: 14.h),
                  _pair(
                    // feetype.type is a code reports key off exactly (see fee_kind.dart),
                    // so it's a list, not free text.
                    isSchool
                        ? _field('Reg/Opt', _dd(_type.text.trim().toUpperCase(), 'REG / OPT', [for (final k in kFeeKinds) (k.code, k.label)],
                            (v) => setState(() => _type.text = v ?? '')))
                        : _field('Priority', _text(_payseq, 'Blank = 100', number: true)),
                    _field('Part Payment', _dd(_partial, 'Yes / No', const [('Yes', 'Yes'), ('No', 'No (full only)')],
                        (v) => setState(() => _partial = v))),
                  ),
                  if (isSchool) ...[
                    SizedBox(height: 14.h),
                    _field('Priority', _text(_payseq, 'e.g. 100 (blank = normal)', number: true)),
                  ],
                  SizedBox(height: 6.h),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Text('Lower priority is paid first: 10 first (Bus), 100 normal, 900 last (Exam).',
                          style: AppUI.muted.copyWith(height: 1.3)),
                    ),
                    Tooltip(
                      message: 'A fee can be paid only after every fee with a lower priority number is cleared. '
                          'Blank counts as 100. Arrears are always cleared before the same student\'s current-year fees.',
                      child: Padding(
                        padding: EdgeInsets.only(left: 6.w, top: 2.h),
                        child: const AppIcon('info-circle', size: 14, color: AppColors.textSecondary),
                      ),
                    ),
                  ]),
                  SizedBox(height: 18.h),
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _add,
                        icon: Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                        label: Text(_editId != null ? AppText.update : AppText.save),
                      ),
                    ),
                    if (_editId != null) ...[
                      SizedBox(width: 8.w),
                      OutlinedButton(onPressed: _saving ? null : _cancelEdit, child: const Text(AppText.cancel)),
                    ],
                  ]),
                  SizedBox(height: 10.h),
                  AppUI.requiredNote(),
                ],
              )),
            ),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _listCard(
            icon: 'tag',
            title: 'Fee Types',
            subtitle: 'all fee types in this institution',
            count: _rows.length,
            countLabel: 'types',
            action: _importButton(context, title: 'Fee Type', tabIndex: 5, disabled: _saving, onReturn: _load),
            headerCells: [
              SizedBox(width: 50.w, child: Text('S NO.', style: _h())),
              Expanded(flex: 3, child: Text('FEE TYPE', style: _h())),
              SizedBox(width: 90.w, child: Text('SHORT NAME', style: _h())),
              Expanded(flex: 2, child: Text('FEE GROUP', style: _h())),
              SizedBox(width: 50.w, child: Text('FINE', style: _h())),
              if (isSchool) SizedBox(width: 60.w, child: Text('TYPE', style: _h())),
              SizedBox(width: 70.w, child: Text(isSchool ? 'REG/OPT' : 'CATEGORY', style: _h())),
              SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? AppUI.empty(title: 'No fee types', why: 'Add one with the form on the left, or use Import CSV/Excel.')
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['fee_id'] is int ? r['fee_id'] as int : int.tryParse(r['fee_id'].toString()) ?? 0;
                          final fine = '${r['feefineapplicable'] ?? 0}' == '1' ? 'Yes' : 'No';
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                              Expanded(flex: 3, child: Text(r['feedesc']?.toString() ?? '', style: _c())),
                              SizedBox(width: 90.w, child: Text(r['feeshort']?.toString() ?? '', style: _c())),
                              Expanded(flex: 2, child: Text(_fgName[r['fg_id']] ?? '', style: _c())),
                              SizedBox(width: 50.w, child: Text(fine, style: _c())),
                              if (isSchool) SizedBox(width: 60.w, child: Text(r['feecat']?.toString() ?? 'SCH', style: _c())),
                              SizedBox(width: 70.w, child: Text(r['type']?.toString() ?? '', style: _c())),
                              SizedBox(
                                  width: 90.w,
                                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    InkWell(onTap: () => _edit(r), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('edit-2', size: 16, color: AppColors.primary))),
                                    SizedBox(width: 8.w),
                                    InkWell(onTap: () => _delete(id), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 16, color: AppColors.error))),
                                  ])),
                            ]),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// SEMESTER
// ══════════════════════════════════════════════════════════════════════════
class _SemesterPanel extends StatefulWidget {
  const _SemesterPanel();
  @override
  State<_SemesterPanel> createState() => _SemesterPanelState();
}

class _SemesterPanelState extends State<_SemesterPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _short = TextEditingController();
  String? _type; // S = Semester (school: T = Term), M = Monthly, Y = Yearly (null = not chosen)
  DateTime? _startDate;
  DateTime? _endDate;
  List<Map<String, dynamic>> _rows = [];
  int? _editId; // non-null while editing an existing row
  bool _loading = true, _saving = false;

  // Type flag ↔ label, shared by the Add dropdown and the table. A school's
  // semesters are TERMS, flagged T.
  static const _collegeTypeLabels = {'S': 'Semester', 'M': 'Monthly', 'Y': 'Yearly'};
  static const _schoolTypeLabels = {'T': 'Term', 'M': 'Monthly', 'Y': 'Yearly'};
  Map<String, String> get _typeLabels => isSchool ? _schoolTypeLabels : _collegeTypeLabels;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await SupabaseService.fromSchema('semester').select('*').eq('ins_id', _insId).eq('activestatus', 1);
      if (!mounted) return;
      // Order by the master-defined ordid, falling back to sem_id (also handles
      // schemas where the ordid column hasn't been added yet).
      final list = List<Map<String, dynamic>>.from(res as List)
        ..sort((a, b) {
          int key(Map<String, dynamic> r) => r['ordid'] is num ? (r['ordid'] as num).toInt() : (r['sem_id'] is num ? (r['sem_id'] as num).toInt() : 1 << 30);
          return key(a).compareTo(key(b));
        });
      setState(() {
        _rows = list;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['sem_id'] is int ? r['sem_id'] as int : int.tryParse(r['sem_id'].toString());
      _name.text = r['semname']?.toString() ?? '';
      _short.text = r['semshort']?.toString() ?? '';
      final t = r['semtype']?.toString().trim() ?? '';
      _type = _typeLabels.containsKey(t) ? t : (isSchool ? 'T' : 'S');
      _startDate = DateTime.tryParse(r['semstart']?.toString() ?? '');
      _endDate = DateTime.tryParse(r['semend']?.toString() ?? '');
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _short.clear();
      _type = null;
      _startDate = null;
      _endDate = null;
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, schoolTerm('Enter a semester name.'), AppColors.warning);
    if (_type == null) return _snack(context, schoolTerm('Select a semester type.'), AppColors.warning);
    if (_rows.any((r) => (r['semname']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() && (r['sem_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    if (_startDate != null && _endDate != null && _endDate!.isBefore(_startDate!)) {
      return _snack(context, 'End date must be on or after the start date.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      final short = _short.text.trim();
      String? d(DateTime? v) => v?.toIso8601String().split('T').first;
      if (_editId != null) {
        await SupabaseService.saveSchemaRow(
            'semester',
            {
              'semname': name,
              'semshort': short.isEmpty ? null : short,
              'semtype': _type,
              'semstart': d(_startDate),
              'semend': d(_endDate),
            },
            pkCol: 'sem_id',
            pkVal: _editId!);
        if (mounted) _snack(context, schoolTerm('Semester updated.'), AppColors.success);
      } else {
        await SupabaseService.saveSchemaRow('semester', {
          'sem_id': await _nextId('semester', 'sem_id'),
          'semname': name,
          'semshort': short.isEmpty ? null : short,
          'semtype': _type,
          'semstart': d(_startDate),
          'semend': d(_endDate),
          // Display order: next after the highest already in the list.
          'ordid': _rows.fold<int>(0, (m, r) { final o = (r['ordid'] as num?)?.toInt() ?? 0; return o > m ? o : m; }) + 1,
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, schoolTerm('Semester added.'), AppColors.success);
      }
      _name.clear();
      _short.clear();
      _type = null;
      _startDate = null;
      _endDate = null;
      _editId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, '${schoolTerm('Could not save the semester.')} ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    // Refused before the confirmation dialog -- see master_usage.dart.
    final _name = _rows.firstWhere((r) => r['sem_id'].toString() == id.toString(), orElse: () => const {})['semname']?.toString() ?? 'this semester';
    final _used = await countReferencing('feedemand', [('sem_id', id), ('demfeeterm', _name)]);
    if (_used > 0) {
      if (mounted) {
        await showMasterInUseDialog(context, name: _name, count: _used, noun: 'fee demand', fix: schoolTerm('Fee demands have already been raised for this semester, so it cannot be deleted.'));
      }
      return;
    }
    if (!mounted) return;
    if (!await _confirmDelete(context, schoolTerm('semester'))) return;
    try {
      await SupabaseService.deleteSchemaRow('semester', 'sem_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, '${schoolTerm('Could not delete the semester.')} ${friendlyError(e)}', AppColors.error);
    }
  }

  static String _fmtDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  Widget _semDateField(DateTime? value, String hint, ValueChanged<DateTime> onPick) {
    final filled = value != null;
    return InkWell(
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 6),
        );
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: _filledFieldDec(context, hint, filled: filled),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              filled ? _fmtDate(value) : hint,
              style: filled
                  ? AppUI.fieldText(context, filled: true)
                  : AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight),
            ),
            Icon(Icons.calendar_today_outlined, size: 14.sp, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320.w,
          child: _addCard(
            icon: 'calendar-1',
            title: schoolTerm(_editId != null ? 'Edit Semester' : 'Add Semester'),
            subtitle: 'collection cycles for the academic year',
            child: FocusTraversalGroup(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _lbl(schoolTerm('Semester Name *')),
                SizedBox(height: 6.h),
                TextField(
                    controller: _name,
                    style: AppUI.fieldText(context, filled: _name.text.trim().isNotEmpty),
                    decoration: _filledFieldDec(context, schoolTerm('Enter semester name'), filled: _name.text.trim().isNotEmpty),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _add()),
                SizedBox(height: 16.h),
                _lbl('Short Name'),
                SizedBox(height: 6.h),
                TextField(
                    controller: _short,
                    style: AppUI.fieldText(context, filled: _short.text.trim().isNotEmpty),
                    decoration: _filledFieldDec(context, 'Enter short name', filled: _short.text.trim().isNotEmpty),
                    onChanged: (_) => setState(() {})),
                SizedBox(height: 16.h),
                _lbl(schoolTerm('Semester Type *')),
                SizedBox(height: 6.h),
                AppDropdownField<String>(
                  initialValue: _type,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context),
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _filledFieldDec(context, schoolTerm('Select semester type'), filled: _type != null),
                  hint: _ddHint(context, schoolTerm('Select semester type')),
                  items: _typeLabels.entries
                      .map((e) => DropdownMenuItem(value: e.key, child: Text(schoolTerm(e.value), style: AppUI.fieldText(context))))
                      .toList(),
                  selectedItemBuilder: (context) => _typeLabels.entries
                      .map((e) => Align(
                          alignment: Alignment.centerLeft,
                          child: Text(schoolTerm(e.value), overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))))
                      .toList(),
                  onChanged: (v) => setState(() => _type = v),
                ),
                SizedBox(height: 16.h),
                _lbl('Start Date'),
                SizedBox(height: 6.h),
                _semDateField(_startDate, 'Select start date', (dt) => setState(() => _startDate = dt)),
                SizedBox(height: 16.h),
                _lbl('End Date'),
                SizedBox(height: 6.h),
                _semDateField(_endDate, 'Select end date', (dt) => setState(() => _endDate = dt)),
                SizedBox(height: 18.h),
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _add,
                      icon: Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                      label: Text(_editId != null ? AppText.update : AppText.save),
                    ),
                  ),
                  if (_editId != null) ...[
                    SizedBox(width: 8.w),
                    OutlinedButton(onPressed: _saving ? null : _cancelEdit, child: const Text(AppText.cancel)),
                  ],
                ]),
                SizedBox(height: 10.h),
                AppUI.requiredNote(),
              ],
            )),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _listCard(
            icon: 'calendar-1',
            title: schoolTerm('Semesters'),
            subtitle: 'all collection cycles in this institution',
            count: _rows.length,
            countLabel: schoolTerm('semesters'),
            action: _importButton(context, title: schoolTerm('Semester'), tabIndex: 8, disabled: _saving, onReturn: _load),
            headerCells: [
              Expanded(child: Text('S NO.', style: _h())),
              Expanded(child: Text(schoolTerm('SEMESTER NAME'), style: _h())),
              Expanded(child: Text('SHORT NAME', style: _h())),
              Expanded(child: Text('TYPE', style: _h())),
              Expanded(child: Text('START DATE', style: _h())),
              Expanded(child: Text('END DATE', style: _h())),
              Expanded(child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? AppUI.empty(title: schoolTerm('No semesters'), why: 'Add one with the form on the left.')
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['sem_id'] is int ? r['sem_id'] as int : int.tryParse(r['sem_id'].toString()) ?? 0;
                          final type = schoolTerm(_typeLabels[r['semtype']?.toString().trim()] ?? 'Semester');
                          final sd = DateTime.tryParse(r['semstart']?.toString() ?? '');
                          final ed = DateTime.tryParse(r['semend']?.toString() ?? '');
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              Expanded(child: Text('${i + 1}', style: _c())),
                              Expanded(child: Text(r['semname']?.toString() ?? '', style: _c())),
                              Expanded(child: Text(r['semshort']?.toString() ?? '', style: _c())),
                              Expanded(child: Text(type, style: _c())),
                              Expanded(child: Text(sd != null ? _fmtDate(sd) : '-', style: _c())),
                              Expanded(child: Text(ed != null ? _fmtDate(ed) : '-', style: _c())),
                              Expanded(
                                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                InkWell(onTap: () => _edit(r), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('edit-2', size: 16, color: AppColors.primary))),
                                SizedBox(width: 8.w),
                                InkWell(onTap: () => _delete(id), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 16, color: AppColors.error))),
                              ])),
                            ]),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }
}


// ══════════════════════════════════════════════════════════════════════════
// ADVANCE FEE DEFINITION — <year schema>.advfeedemand
// Next year's fees, defined now: per section (type 0) or for a whole standard
// (type 1), per term, with the same Applicable To flags as the section fee.
// A DEFINITION ONLY -- saving never raises student demands (unlike Section
// Fee Demand, whose lines are generated onto students).
// ══════════════════════════════════════════════════════════════════════════

/// Dispose a grid row's amount controller once the current frame is drawn.
/// The rows are replaced inside setState, and the amount boxes still hold the
/// old controller until they rebuild; disposing it at once made the box touch
/// a dead controller ("TextEditingController was used after being disposed").
void _disposeAfterFrame(TextEditingController c) =>
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());

/// Two Applicable To flags (New/Old, Boy/Girl, Day/Hostel) reach at least one
/// student in common -- 3 = Both reaches everyone. The same fee type on two
/// rows whose flags all meet would bill those students twice.
bool _flagsMeet(int a, int b) => a == 3 || b == 3 || a == b;

class _AdvLine {
  static int _seq = 0;
  final int uid = ++_seq;
  String? feeType;
  /// Loaded from a saved line (Edit): its fee type is locked -- change the
  /// amount or who it applies to, or delete the row (user, 2026-11-16).
  bool saved = false;
  final amount = TextEditingController();
  // dhb (Day Scholar / Hosteller) is no longer asked: always 3 = Both
  // (user, 2026-11-02). The column stays in the table for older rows.
  int nob = 3, bgb = 3, dhb = 3;
  void dispose() => _disposeAfterFrame(amount);
}

class _AdvanceFeePanel extends StatefulWidget {
  const _AdvanceFeePanel();
  @override
  State<_AdvanceFeePanel> createState() => _AdvanceFeePanelState();
}

class _AdvanceFeePanelState extends State<_AdvanceFeePanel> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _courses = [], _classes = [], _terms = [], _fees = [], _saved = [];
  // Section Mapping rows and pre-admission students, for "raised for whom".
  List<Map<String, dynamic>> _maps = [], _preStudents = [];
  String _nextYear = '';
  /// 0 = section-wise, 1 = standard-wise. Not chosen here: it follows the
  /// standard's Fee Demand By (Setup > Master Data > Standard).
  int _type = 0;

  /// The standard's Fee Demand By is STANDARD.
  bool _stdLevel(int? cour) =>
      '${_courses.firstWhere((c) => _id(c['cour_id']) == cour, orElse: () => const {})['feelevel'] ?? ''}' == 'STANDARD';
  int? _cour, _cla;
  String? _term;
  DateTime? _due;
  final List<_AdvLine> _lines = [];
  bool _loading = true, _saving = false;
  bool _editMode = false; // New = blank grid, Edit = the saved lines

  final Map<String, Set<int>> _groupsOf = {}; // feedesc -> its fg_ids
  /// OPTIONAL fee types (feetype.type 'OPT', e.g. bus). They are never raised
  /// as advance demands -- like Section Fee Demand, an optional fee is added
  /// per student in Fee Definition -- so a line using one is flagged.
  final Set<String> _optional = {};
  /// Next-year sections / standards offered in the dropdowns: only the ones
  /// saved in Section Mapping, the ones pre-admission students are admitted
  /// into, and the first standard (user, 2026-11-14: "only mapped class should
  /// list").
  final Set<int> _targetCla = {}, _targetCour = {};
  List<Map<String, dynamic>> get _matchedCourses => [
        for (final c in _courses)
          if (_targetCour.contains(_id(c['cour_id'])) || _classes.any((k) => _id(k['cour_id']) == _id(c['cour_id']) && _targetCla.contains(_id(k['cla_id'])))) c,
      ];
  List<Map<String, dynamic>> get _matchedSections => [
        for (final c in _classes)
          if (_targetCla.contains(_id(c['cla_id'])) && (_cour == null || _id(c['cour_id']) == _cour) && !_stdLevel(_id(c['cour_id']))) c,
      ];
  int? _fg;

  List<_AdvLine> get _visibleLines =>
      _fg == null ? _lines : _lines.where((l) => l.feeType == null || (_groupsOf[l.feeType]?.contains(_fg) ?? false)).toList();
  List<String> get _pickable => [
        for (final f in _fees)
          if (_fg == null || (_groupsOf['${f['feedesc']}']?.contains(_fg) ?? false)) '${f['feedesc']}',
      ];

  @override
  bool get wantKeepAlive => true;

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  @override
  void initState() {
    super.initState();
    _blank();
    if (isSchool) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid, feelevel, classtype').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('semester').select('sem_id, semname').eq('ins_id', _insId).eq('activestatus', 1).order('sem_id'),
        SupabaseService.fromSchema('feetype').select('fee_id, feedesc, fg_id, type').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('advfeedemand').select('*').eq('activestatus', 1).order('af_id')),
        SupabaseService.getYears(_insId),
        SupabaseService.fromSchema('feegroup').select('fg_id, fgdesc').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('classmatch').select('curclassid, nextclassid, nextcourseid').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
            .select('cla_id, cour_id').eq('ins_id', _insId).eq('activestatus', 1).eq('preadmission', 1)),
      ]);
      if (!mounted) return;
      List<Map<String, dynamic>> m(dynamic x) => List<Map<String, dynamic>>.from((x as List).cast<Map<String, dynamic>>());
      setState(() {
        _courses = m(r[0])..sort((a, b) => (_id(a['ordid']) ?? 9999).compareTo(_id(b['ordid']) ?? 9999));
        if (_cour != null) {
          _type = _stdLevel(_cour) ? 1 : 0; // the flag may have changed
          if (_type == 1) _cla = null;
        }
        _classes = m(r[1])..sort((a, b) => classCompare('${a['claname']}', '${b['claname']}'));
        _terms = m(r[2]);
        // one name per fee type (it may sit in several groups)
        final fees = m(r[3]);
        _optional
          ..clear()
          ..addAll([for (final f in fees) if ('${f['type'] ?? ''}'.trim().toUpperCase() == 'OPT') '${f['feedesc']}']);
        _groupsOf.clear();
        for (final f in fees) {
          final fg = _id(f['fg_id']);
          if (fg != null) (_groupsOf['${f['feedesc']}'] ??= <int>{}).add(fg);
        }
        final seen = <String>{};
        _fees = [for (final f in fees) if (seen.add('${f['feedesc']}')) f]..sort((a, b) => '${a['feedesc']}'.compareTo('${b['feedesc']}'));
        _maps = m(r[7]);
        _preStudents = m(r[8]);
        // Next-year sections offered: the targets of Section Mapping, plus the
        // sections pre-admission students are already admitted into (they stay
        // where they are, no mapping involved).
        _targetCla
          ..clear()
          ..addAll([for (final x in [...m(r[7]).map((e) => e['nextclassid']), ...m(r[8]).map((e) => e['cla_id'])]) if (_id(x) != null) _id(x)!]);
        _targetCour
          ..clear()
          ..addAll([for (final x in [...m(r[7]).map((e) => e['nextcourseid']), ...m(r[8]).map((e) => e['cour_id'])]) if (_id(x) != null) _id(x)!]);
        // The first standard (PREKG ...) and its sections as well: nobody is
        // promoted into it, but new admissions and pre-admissions start there.
        final first = _courses.isEmpty ? null : _id(_courses.first['cour_id']);
        if (first != null) {
          _targetCour.add(first);
          _targetCla.addAll([
            for (final c in _classes)
              if (_id(c['cour_id']) == first && _id(c['cla_id']) != null) _id(c['cla_id'])!,
          ]);
        }
        // no fee group selector: all groups' fee types (_fg stays null)
        _fg = null;
        _saved = m(r[4]);
        final years = r[5] as List;
        final cur = years.isNotEmpty ? '${(years.first as Map)['yrlabel'] ?? ''}' : '';
        final p = cur.split('-').map(int.tryParse).toList();
        _nextYear = p.length == 2 && p[0] != null && p[1] != null ? '${p[0]! + 1}-${p[1]! + 1}' : '';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack(context, 'Could not load the advance fee details. ${friendlyError(e)}', AppColors.error);
      }
    }
  }


  bool get _scopeReady => _cour != null && (_type == 1 || _cla != null) && _term != null;

  /// Whose fees these are -- as the old product, where an advance fee was a
  /// pair "current class -> applicable class": the sections mapped into the
  /// chosen next-year section / standard in Section Mapping, and the
  /// pre-admission students already in it (user, 2026-11-14).
  String? get _forWhom {
    if (_cour == null || (_type == 0 && _cla == null)) return null;
    String cls(int? id) => '${_classes.firstWhere((c) => _id(c['cla_id']) == id, orElse: () => const {})['claname'] ?? ''}';
    String std(int? id) => '${_courses.firstWhere((c) => _id(c['cour_id']) == id, orElse: () => const {})['courname'] ?? ''}';
    final from = <String>[];
    for (final x in _maps) {
      final hit = _type == 0 ? _id(x['nextclassid']) == _cla : _id(x['nextcourseid']) == _cour;
      final n = cls(_id(x['curclassid']));
      if (hit && n.isNotEmpty && !from.contains(n)) from.add(n);
    }
    final pre = _preStudents.where((x) => _type == 0 ? _id(x['cla_id']) == _cla : _id(x['cour_id']) == _cour).length;
    final target = _type == 0 ? cls(_cla) : std(_cour);
    final parts = [
      if (from.isNotEmpty) 'the students of ${from.join(', ')} (moving to $target next year)',
      if (pre > 0) '$pre pre-admission student${pre == 1 ? '' : 's'} admitted to $target',
    ];
    return parts.isEmpty
        ? 'No section is mapped to $target in Section Mapping and no pre-admission student is in it yet -- saving raises no demands.'
        : 'Raised for ${parts.join(' and ')}.';
  }

  bool _inScope(Map<String, dynamic> r) =>
      _id(r['aftype']) == _type &&
      _id(r['cour_id']) == _cour &&
      (_type == 1 ? r['cla_id'] == null : _id(r['cla_id']) == _cla) &&
      '${r['afterm']}' == _term;

  /// Five blank rows, as the Section Fee Demand grid starts.
  void _blank() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines
      ..clear()
      ..addAll(List.generate(5, (_) => _AdvLine()));
  }

  /// The chosen scope + term already has advance fees saved.
  bool get _hasSaved => _scopeReady && _saved.any(_inScope);

  /// New: blank rows. Edit: the lines saved for the chosen scope + term. The
  /// mode follows what is saved: fees already there open in Edit and New is
  /// not offered (user, 2026-11-16).
  void _reload() {
    _editMode = _hasSaved;
    _blank();
    if (!_editMode || !_scopeReady) return;
    final rows = _saved.where(_inScope).toList();
    if (rows.isEmpty) return;
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    for (final r in rows) {
      final l = _AdvLine()
        ..feeType = '${r['affeetype']}'
        ..saved = true
        ..nob = _id(r['afnob']) ?? 3
        ..bgb = _id(r['afbgb']) ?? 3
        ..dhb = _id(r['afdhb']) ?? 3;
      final a = r['afamount'];
      final n = a is num ? a : double.tryParse('${a ?? ''}');
      if (n != null) l.amount.text = n == n.roundToDouble() ? n.toInt().toString() : n.toString();
      _lines.add(l);
    }
    final d = DateTime.tryParse('${rows.first['afduedate'] ?? ''}');
    if (d != null) _due = d;
  }

  double get _total => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.amount.text.trim()) ?? 0));

  Future<void> _save() async {
    if (!_scopeReady || _due == null) {
      return _snack(context, schoolTerm(_type == 0
          ? 'Select the course, class, term and Pay On or Before date.'
          : 'Select the course, term and Pay On or Before date.'), AppColors.warning);
    }
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _snack(context, 'Add at least one fee line.', AppColors.warning);
    for (final l in lines) {
      if (_dupFee(l, l.feeType)) return _dupSnack(l.feeType!);
    }
    setState(() => _saving = true);
    try {
      // Replace this scope + term as a whole.
      await SupabaseService.deleteSchemaRowsWhere('advfeedemand', {
        'aftype': _type,
        'cour_id': _cour,
        'cla_id': _type == 1 ? null : _cla,
        'afterm': _term,
      });
      final semId = _id(_terms.firstWhere((t) => '${t['semname']}' == _term, orElse: () => const {})['sem_id']);
      for (final l in lines) {
        await SupabaseService.saveSchemaRow('advfeedemand', {
          'aftype': _type,
          'cour_id': _cour,
          'cla_id': _type == 1 ? null : _cla,
          'afterm': _term,
          'sem_id': semId,
          'affeetype': l.feeType,
          'fee_id': _id(_fees.firstWhere((f) => '${f['feedesc']}' == l.feeType, orElse: () => const {})['fee_id']),
          'afamount': double.tryParse(l.amount.text.trim()) ?? 0,
          'afduedate': _due!.toIso8601String().split('T').first,
          'afnob': l.nob,
          'afbgb': l.bgb,
          'afdhb': l.dhb,
          'activestatus': 1,
        });
      }
      final raised = await _raise(_cour!, _type == 1 ? null : _cla);
      if (!mounted) return;
      final opt = lines.where((l) => _optional.contains(l.feeType)).length;
      _snack(
          context,
          'Saved ${lines.length} advance fee line(s); $raised advance demand(s) raised.'
          '${opt > 0 ? ' $opt optional fee line(s) were not raised. Add them per student in Fee Collection > Fee Definition.' : ''}',
          opt > 0 ? AppColors.warning : AppColors.success);
      await _load();
      if (mounted) setState(_reload);
    } catch (e) {
      if (mounted) _snack(context, 'Could not save the advance fees. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The grid's lines, checked the way Save checks them. null = not ready
  /// (the reason has been shown).
  List<_AdvLine>? _readyLines() {
    if (_term == null || _due == null) {
      _snack(context, schoolTerm('Select the semester and the Pay On or Before date first.'), AppColors.warning);
      return null;
    }
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) {
      _snack(context, 'Enter fee amounts to copy.', AppColors.warning);
      return null;
    }
    for (final l in lines) {
      if (_dupFee(l, l.feeType)) {
        _dupSnack(l.feeType!);
        return null;
      }
    }
    return lines;
  }

  /// Replace the lines of one scope (type + standard [+ section]) for the
  /// current term with [lines].
  /// Raise the advance demands after a definition is saved -- as Section Fee
  /// Demand raises its demands on Save: unpaid demands of this scope + term
  /// are rebuilt from the definition, then every student it applies to gets
  /// the demands they lack (refresh_advance_demands). Paid ones, hand-added
  /// ones and a student's opt-outs are left alone. Returns how many were raised.
  Future<int> _raise(int cour, int? cla) async {
    final res = await SupabaseService.client.rpc('refresh_advance_demands', params: {
      'p_token': SupabaseService.sessionToken,
      'p_aftype': _type,
      'p_cour_id': cour,
      'p_cla_id': cla,
      'p_term': _term,
    });
    return res is Map ? (_id(res['raised']) ?? 0) : 0;
  }

  Future<int> _writeScope(int cour, int? cla, List<_AdvLine> lines) async {
    await SupabaseService.deleteSchemaRowsWhere('advfeedemand', {
      'aftype': _type,
      'cour_id': cour,
      'cla_id': _type == 1 ? null : cla,
      'afterm': _term,
    });
    final semId = _id(_terms.firstWhere((t) => '${t['semname']}' == _term, orElse: () => const {})['sem_id']);
    for (final l in lines) {
      await SupabaseService.saveSchemaRow('advfeedemand', {
        'aftype': _type,
        'cour_id': cour,
        'cla_id': _type == 1 ? null : cla,
        'afterm': _term,
        'sem_id': semId,
        'affeetype': l.feeType,
        'fee_id': _id(_fees.firstWhere((f) => '${f['feedesc']}' == l.feeType, orElse: () => const {})['fee_id']),
        'afamount': double.tryParse(l.amount.text.trim()) ?? 0,
        'afduedate': _due!.toIso8601String().split('T').first,
        'afnob': l.nob,
        'afbgb': l.bgb,
        'afdhb': l.dhb,
        'activestatus': 1,
      });
    }
    return _raise(cour, _type == 1 ? null : cla);
  }

  /// Copy the grid (amounts, Applicable To, term, due date) to other sections
  /// -- or, standard-wise, to other standards. Each target's lines for this
  /// term are replaced, and their advance demands raised.
  Future<void> _copyFee() async {
    final lines = _readyLines();
    if (lines == null) return;
    // (id, label, standard) of every possible target except the current one.
    // Same level only: sections of section-wise standards, or other
    // standard-wise standards.
    final targets = _type == 0
        ? [
            for (final c in _classes)
              if (_id(c['cla_id']) != _cla && _targetCla.contains(_id(c['cla_id'])) && !_stdLevel(_id(c['cour_id'])))
                (_id(c['cla_id'])!, '${c['claname']}', _id(c['cour_id'])!),
          ]
        : [
            for (final c in _matchedCourses)
              if (_id(c['cour_id']) != _cour && _stdLevel(_id(c['cour_id']))) (_id(c['cour_id'])!, '${c['courname']}', _id(c['cour_id'])!),
          ];
    final picked = await _pickTargets(targets);
    if (picked == null || picked.isEmpty) return;
    setState(() => _saving = true);
    var done = 0, raised = 0;
    final fails = <String>[];
    for (final t in targets.where((t) => picked.contains(t.$1))) {
      try {
        raised += await _writeScope(t.$3, _type == 0 ? t.$1 : null, lines);
        done++;
      } catch (e) {
        fails.add('${t.$2}: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(
      context,
      fails.isEmpty
          ? schoolTerm('Copied ${lines.length} advance fee line(s) to $done ${_type == 0 ? 'class(es)' : 'course(s)'}; $raised advance demand(s) raised.')
          : 'Copied to $done; could not copy to ${fails.length}. ${fails.first}',
      fails.isEmpty ? AppColors.success : AppColors.error,
    );
    await _load();
  }

  /// Multi-select of copy targets with a search box; ticks survive searching.
  Future<Set<int>?> _pickTargets(List<(int, String, int)> targets) {
    final picked = <int>{};
    var query = '';
    final from = _type == 0
        ? '${_classes.firstWhere((c) => _id(c['cla_id']) == _cla, orElse: () => const {})['claname'] ?? ''}'
        : '${_courses.firstWhere((c) => _id(c['cour_id']) == _cour, orElse: () => const {})['courname'] ?? ''}';
    return showDialog<Set<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final q = query.trim().toLowerCase();
          final options = targets.where((t) => q.isEmpty || t.$2.toLowerCase().contains(q)).toList();
          return AlertDialog(
            title: Text(schoolTerm(_type == 0 ? 'Copy Fees to Classes' : 'Copy Fees to Courses'),
                style: AppUI.cardTitle),
            content: SizedBox(
              width: 360.w,
              height: 360.h,
              child: ListView(children: [
                Padding(
                  padding: EdgeInsets.only(bottom: 4.h),
                  child: Text('From $from • ${_term ?? ''}', style: AppUI.muted),
                ),
                Padding(
                  padding: EdgeInsets.only(bottom: 6.h),
                  child: TextField(
                    autofocus: true,
                    style: AppUI.fieldText(context),
                    decoration: AppUI.field(context, schoolTerm(_type == 0 ? 'Search by class name' : 'Search by course name'), leadingIcon: 'search-normal'),
                    onChanged: (v) => setLocal(() => query = v),
                  ),
                ),
                Row(children: [
                  if (picked.isNotEmpty)
                    Text('${picked.length} selected', style: AppUI.label.copyWith(color: AppColors.primary)),
                  const Spacer(),
                  TextButton(
                    onPressed: options.isEmpty
                        ? null
                        : () => setLocal(() {
                              final all = options.every((t) => picked.contains(t.$1));
                              for (final t in options) {
                                all ? picked.remove(t.$1) : picked.add(t.$1);
                              }
                            }),
                    child: Text(options.isNotEmpty && options.every((t) => picked.contains(t.$1)) ? 'Clear All' : 'Select All'),
                  ),
                ]),
                if (options.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 24.h),
                    child: AppUI.empty(title: schoolTerm(_type == 0 ? 'No other classes to copy to' : 'No other courses to copy to')),
                  ),
                for (final t in options)
                  CheckboxListTile(
                    dense: true,
                    value: picked.contains(t.$1),
                    title: Text(t.$2, style: AppUI.body),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (v) => setLocal(() => v == true ? picked.add(t.$1) : picked.remove(t.$1)),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, picked),
                child: Text('Copy to ${picked.length}'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _drop<T>(String hint, T? value, List<(T, String)> items, ValueChanged<T?>? onChanged, {String? icon}) {
    return AppDropdownField<T>(
      key: ValueKey('$hint-$value-${items.length}'),
      initialValue: items.any((e) => e.$1 == value) ? value : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      style: _fieldTextStyle(context),
      decoration: _filledFieldDec(context, hint, filled: value != null, leadingIcon: icon),
      hint: _ddHint(context, hint),
      items: [
        for (final e in items)
          DropdownMenuItem<T>(value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context))),
      ],
      onChanged: _saving ? null : onChanged,
    );
  }

  Widget _flag(int value, Map<int, String> labels, ValueChanged<int> onChanged) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.w),
      child: AppDropdownField<int>(
        initialValue: labels.containsKey(value) ? value : 3,
        isExpanded: true,
        isDense: true,
        dropdownColor: Colors.white,
        decoration: _dec('', filled: value != 3),
        items: [
          for (final e in labels.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: e.key != 3))),
        ],
        onChanged: _saving ? null : (v) => onChanged(v ?? 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!isSchool) {
      return AppUI.empty(title: 'Advance Fee Demand is available for schools only.');
    }
    if (_loading) return const Center(child: CircularProgressIndicator());

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header -- icon tile, title + subtitle, year chip, breadcrumb.
        Padding(
          padding: EdgeInsets.only(bottom: 16.h),
          child: Row(children: [
            AppUI.iconTile('empty-wallet-add'),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Advance Fee Demand', style: AppUI.cardTitle),
                SizedBox(height: 2.h),
                Text(schoolTerm('Next year\'s fees for each class. Saving raises the advance demands for its students.'),
                    style: AppUI.muted),
              ]),
            ),
            if (_nextYear.isNotEmpty) ...[
              AppUI.chip('Academic Year $_nextYear', AppStatus.info),
              SizedBox(width: 14.w),
            ],
            if (MediaQuery.of(context).size.width > 1100)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.home_outlined, size: 14.sp, color: AppColors.textLight),
                for (final crumb in const ['Setup', 'Fee Master']) ...[
                  _crumb(),
                  Text(crumb, style: AppUI.muted),
                ],
                _crumb(),
                Text('Advance Fee Demand', style: AppUI.label),
              ]),
          ]),
        ),
        // Filters -- the full width, one Expanded slot each.
        Padding(
          padding: EdgeInsets.only(bottom: 10.h),
          child: FocusTraversalGroup(
            child: Row(children: [
              // Only the standards / sections already set in Section Matching
              // (or holding pre-admission students) are offered.
              Expanded(
                child: _drop<int>(
                    _matchedCourses.isEmpty ? 'Map sections first in Section Mapping' : schoolTerm('Select next year course'),
                    _cour,
                    [
                      for (final c in _matchedCourses)
                        (_id(c['cour_id'])!, '${c['courname']}${_stdLevel(_id(c['cour_id'])) ? ' - all sections' : ''}'),
                    ],
                    (v) => setState(() {
                          _cour = v;
                          _cla = null;
                          _type = _stdLevel(v) ? 1 : 0; // Fee Demand By of the standard
                          _reload();
                        }),
                    icon: 'teacher'),
              ),
              SizedBox(width: 8.w),
              if (_type == 0) ...[
                Expanded(
                  child: _drop<int>(
                      schoolTerm('Select next year class'),
                      _cla,
                      [for (final c in _matchedSections) (_id(c['cla_id'])!, '${c['claname']}')],
                      (v) => setState(() {
                            _cla = v;
                            _reload();
                          }),
                      icon: 'book-1'),
                ),
                SizedBox(width: 8.w),
              ],
              Expanded(
                child: _drop<String>(schoolTerm('Select semester'), _term, [for (final t in _terms) ('${t['semname']}', '${t['semname']}')],
                    (v) => setState(() {
                          _term = v;
                          _reload();
                        }),
                    icon: 'book'),
              ),
              SizedBox(width: 8.w),
              // No fee group selector (user, 2026-10-30): every group's fee
              // types are offered; each saved line takes its group from its
              // fee type.
              Expanded(
                child: FocusableTap(
                  onTap: () async {
                    final now = DateTime.now();
                    final p = await showDatePicker(context: context, initialDate: _due ?? now, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 5));
                    if (p != null) setState(() => _due = p);
                  },
                  child: InputDecorator(
                    decoration: _filledFieldDec(context, '', filled: _due != null, leadingIcon: 'calendar-1').copyWith(
                      suffixIcon: Padding(
                        padding: EdgeInsets.only(right: 10.w),
                        child: AppIcon('calendar', size: 15, color: _due != null ? AppColors.primary : AppColors.textSecondary),
                      ),
                      suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    ),
                    child: Text(
                      _due == null ? 'Select date' : '${_due!.day.toString().padLeft(2, '0')}-${_due!.month.toString().padLeft(2, '0')}-${_due!.year}',
                      overflow: TextOverflow.ellipsis,
                      style: _due == null
                          ? AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)
                          : AppUI.fieldText(context, filled: true),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
        // Who these fees are raised for (current section -> next year's).
        if (_forWhom != null)
          Padding(
            padding: EdgeInsets.only(bottom: 10.h),
            child: Row(children: [
              const AppIcon('people', size: 15, color: AppColors.textSecondary),
              SizedBox(width: 8.w),
              Expanded(child: Text(_forWhom!, style: AppUI.muted)),
            ]),
          ),
        // Mode buttons on their own line, right-aligned (as Section Fee Demand).
        Padding(
          padding: EdgeInsets.only(bottom: 10.h),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            // New only while nothing is saved, Edit only once it is.
            if (!_hasSaved) ...[
              ExcludeFocus(child: _mode('New', Icons.add, !_editMode, () => setState(() {
                    _editMode = false;
                    _reload();
                  }))),
              SizedBox(width: 8.w),
            ],
            if (_hasSaved) ...[
              ExcludeFocus(child: _mode('Edit', Icons.edit, _editMode, () => setState(() {
                    _editMode = true;
                    _reload();
                  }))),
              SizedBox(width: 8.w),
            ],
            ExcludeFocus(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _copyFee,
                icon: const Icon(Icons.copy_all, size: 15),
                label: const Text('Copy Fees'),
              ),
            ),
          ]),
        ),
        SizedBox(height: 4.h),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
            child: Column(children: [
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                child: Row(children: [
                  Expanded(flex: 3, child: Text('FEE TYPE', style: _h())),
                  SizedBox(width: 140.w, child: Text('AMOUNT', textAlign: TextAlign.right, style: _h())),
                  SizedBox(width: 120.w, child: Text('NEW / OLD', textAlign: TextAlign.center, style: _h())),
                  SizedBox(width: 120.w, child: Text('BOY / GIRL', textAlign: TextAlign.center, style: _h())),
                  SizedBox(width: 44.w),
                ]),
              ),
              Expanded(
                child: FocusTraversalGroup(
                  child: CustomScrollView(slivers: [
                    SliverList.separated(
                      itemCount: _visibleLines.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (_, i) => _lineRow(_visibleLines[i], i),
                    ),
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24.h),
                        child: AppUI.empty(
                          title: _lines.isEmpty ? 'No fee types yet' : 'No more fee types',
                          why: schoolTerm('Add a new row to define next year\'s fee types for this class.'),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
              const Divider(height: 1, color: AppColors.divider),
              Padding(
                padding: EdgeInsets.all(12.w),
                child: Row(children: [
                  OutlinedButton.icon(
                    onPressed: _saving ? null : () => setState(() => _lines.add(_AdvLine())),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Row'),
                  ),
                  SizedBox(width: 12.w),
                  // Takes all the free width and wraps to a second line rather
                  // than ending in "…".
                  Expanded(
                    child: Text('Applicable To "Both" means every student. Saving raises the advance demands; collect them in Advance Fee Collection.',
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: AppUI.muted),
                  ),
                  SizedBox(width: 12.w),
                  Text(_fg == null ? 'Total  ' : 'Total, all groups  ', style: AppUI.label.copyWith(color: AppColors.textSecondary)),
                  Text(_total.toStringAsFixed(2), style: AppUI.money.copyWith(color: AppColors.primary)),
                  SizedBox(width: 16.w),
                  ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save, size: 16),
                    label: const Text('Save'),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _crumb() => Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.w),
        child: Icon(Icons.chevron_right, size: 13.sp, color: AppColors.textLight),
      );

  Widget _mode(String label, IconData icon, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryLight : Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: active ? AppColors.primary : AppColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15.sp, color: active ? AppColors.primary : AppColors.textSecondary),
          SizedBox(width: 6.w),
          Text(label, style: AppUI.label.copyWith(color: active ? AppColors.primary : AppColors.textSecondary)),
        ]),
      ),
    );
  }

  String? _matchFee(String text) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final f in _fees) {
      final n = '${f['feedesc']}';
      if (n.toLowerCase() == q) return n;
    }
    return null;
  }

  /// [fee] is already on another row that reaches any of the same students
  /// (New/Old, Boy/Girl, Day/Hostel meet; "Both" meets everything) -- a
  /// duplicate (user, 2026-11-14 "restrict duplicate selection", 2026-11-16 "no
  /// duplicate feetype"). The same fee for DIFFERENT students (New at one
  /// amount, Old at another) is still allowed.
  bool _dupFee(_AdvLine l, String? fee, {int? nob, int? bgb, int? dhb}) =>
      fee != null &&
      _lines.any((o) =>
          !identical(o, l) &&
          o.feeType == fee &&
          _flagsMeet(o.nob, nob ?? l.nob) &&
          _flagsMeet(o.bgb, bgb ?? l.bgb) &&
          _flagsMeet(o.dhb, dhb ?? l.dhb));

  void _dupSnack(String fee) => _snack(context, _dupText(fee), AppColors.warning);

  /// One grid row -- the same anatomy as a Section Fee Demand line: a
  /// type-to-find fee type, the amount with a rupee mark, the three Applicable
  /// To pickers and a remove button.
  Widget _lineRow(_AdvLine l, int i) {
    final names = _pickable;
    return Container(
      color: i.isEven ? Colors.white : AppColors.surface,
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 5.h),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 10.h),
            child: Autocomplete<String>(
              key: ValueKey('adv-ft-${l.uid}-${_fg ?? 'all'}'),
              initialValue: TextEditingValue(text: l.feeType ?? ''),
              // Fee types already on another row for the same students are
              // not offered again. A saved row's fee type is locked.
              optionsBuilder: (v) {
                if (l.saved) return const Iterable<String>.empty();
                final q = v.text.trim().toLowerCase();
                final free = names.where((e) => e == l.feeType || !_dupFee(l, e));
                return q.isEmpty ? free : free.where((e) => e.toLowerCase().contains(q));
              },
              onSelected: (v) {
                if (_dupFee(l, v)) return _dupSnack(v);
                setState(() => l.feeType = v);
              },
              fieldViewBuilder: (context, ctrl, focus, onSubmit) => Focus(
                canRequestFocus: false,
                skipTraversal: true,
                // Leaving with text that matches no fee type puts the last
                // valid pick back -- a row never looks filled but is empty.
                onFocusChange: (has) {
                  if (has || l.saved) return;
                  final m = _matchFee(ctrl.text);
                  if (m != null && _dupFee(l, m)) {
                    _dupSnack(m);
                    ctrl.text = l.feeType ?? '';
                  } else if (m != null) {
                    if (l.feeType != m) setState(() => l.feeType = m);
                  } else {
                    ctrl.text = l.feeType ?? '';
                  }
                },
                child: TextField(
                  controller: ctrl,
                  focusNode: focus,
                  enabled: !_saving,
                  readOnly: l.saved,
                  style: AppUI.fieldText(context, filled: true),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Search fee type',
                    hintStyle: AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight),
                    suffixIcon: l.saved ? _lockedMark() : Icon(Icons.search, size: 16.sp, color: AppColors.textSecondary),
                    suffixIconConstraints: BoxConstraints(minWidth: 22.w, minHeight: 22.h),
                  ),
                  onChanged: (v) {
                    final m = _matchFee(v);
                    if (m != null && !_dupFee(l, m)) l.feeType = m;
                  },
                  onSubmitted: (v) {
                    final m = _matchFee(v);
                    if (m != null && _dupFee(l, m)) {
                      _dupSnack(m);
                      ctrl.text = l.feeType ?? '';
                      return;
                    }
                    if (m != null) setState(() => l.feeType = m);
                    onSubmit();
                  },
                ),
              ),
              optionsViewBuilder: (context, onSelected, options) => Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: 320.h, maxWidth: 420.w),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (_, k) {
                        final e = options.elementAt(k);
                        return InkWell(
                          onTap: () => onSelected(e),
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                            child: Text(e, style: AppUI.fieldText(context, filled: true)),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (l.feeType != null && _optional.contains(l.feeType))
          Tooltip(
            message: 'Optional fee: not raised as an advance demand for every student. '
                'Add it per student in Fee Collection -> Fee Definition.',
            child: AppUI.chip('Optional - not raised', AppStatus.warning),
          ),
        SizedBox(width: 8.w),
        SizedBox(
          width: 132.w,
          child: TextField(
            controller: l.amount,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            textAlign: TextAlign.right,
            style: AppUI.money.copyWith(color: l.amount.text.trim().isNotEmpty ? AppColors.primary : AppColors.textPrimary),
            decoration: _dec('', filled: l.amount.text.trim().isNotEmpty).copyWith(
              prefixIcon: Padding(
                padding: EdgeInsets.only(left: 10.w, right: 6.w),
                child: Text('₹', style: AppUI.label.copyWith(color: AppColors.textSecondary)),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        // Changing who a row is for may not make it repeat another row.
        SizedBox(width: 120.w, child: _flag(l.nob, _kNobLabels, (v) {
          if (_dupFee(l, l.feeType, nob: v)) return _dupSnack(l.feeType!);
          setState(() => l.nob = v);
        })),
        SizedBox(width: 120.w, child: _flag(l.bgb, _kBgbLabels, (v) {
          if (_dupFee(l, l.feeType, bgb: v)) return _dupSnack(l.feeType!);
          setState(() => l.bgb = v);
        })),
        SizedBox(
          width: 44.w,
          child: IconButton(
            tooltip: AppText.deleteRow,
            visualDensity: VisualDensity.compact,
            onPressed: _saving
                ? null
                : () => setState(() {
                      l.dispose();
                      _lines.remove(l);
                    }),
            icon: const AppIcon('trash', size: 16, color: AppColors.error),
          ),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// CLASS (SECTION) MATCHING — <year schema>.classmatch
// Which section of the NEXT standard each section moves into at promotion
// (UKG A -> I A ...). Pick the current and next standard; every section of
// the current one gets a next section, matched by its letter to start with.
// Save replaces the standard's matches.
// ══════════════════════════════════════════════════════════════════════════

class _ClassMatchPanel extends StatefulWidget {
  const _ClassMatchPanel();
  @override
  State<_ClassMatchPanel> createState() => _ClassMatchPanelState();
}

class _ClassMatchPanelState extends State<_ClassMatchPanel> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _courses = []; // ordered by ordid
  List<Map<String, dynamic>> _classes = [];
  List<Map<String, dynamic>> _matches = [];
  int? _cur; // current standard (cour_id)
  int? _next; // next standard (cour_id)
  final Map<int, int?> _pick = {}; // current section cla_id -> next section cla_id
  bool _loading = true, _saving = false;

  @override
  bool get wantKeepAlive => true;

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  @override
  void initState() {
    super.initState();
    // College has no classmatch table -- the panel is school-only.
    if (isSchool) {
      _load();
    } else {
      _loading = false;
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait([
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('classmatch').select('*').eq('activestatus', 1),
      ]);
      if (!mounted) return;
      setState(() {
        _courses = List<Map<String, dynamic>>.from((r[0] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => (_id(a['ordid']) ?? 9999).compareTo(_id(b['ordid']) ?? 9999));
        _classes = List<Map<String, dynamic>>.from((r[1] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => classCompare('${a['claname']}', '${b['claname']}'));
        _matches = List<Map<String, dynamic>>.from((r[2] as List).cast<Map<String, dynamic>>());
        _loading = false;
        if (_cur != null) _selectCurrent(_cur);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack(context, '${schoolTerm('Could not load the class mapping.')} ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  String _courseName(int? id) => '${_courses.firstWhere((c) => _id(c['cour_id']) == id, orElse: () => const {})['courname'] ?? ''}';
  String _className(int? id) => '${_classes.firstWhere((c) => _id(c['cla_id']) == id, orElse: () => const {})['claname'] ?? ''}';
  List<Map<String, dynamic>> _sectionsOf(int? cour) => _classes.where((c) => _id(c['cour_id']) == cour).toList();

  /// The section's own letter: "UKG A" of standard "UKG" -> "A".
  String _suffix(Map<String, dynamic> cls) {
    final name = '${cls['claname']}'.trim();
    final std = _courseName(_id(cls['cour_id'])).trim();
    return (std.isNotEmpty && name.toUpperCase().startsWith(std.toUpperCase()) ? name.substring(std.length) : name)
        .trim()
        .toUpperCase();
  }

  /// Next section with the same letter (UKG A -> I A), or none.
  int? _autoMatch(Map<String, dynamic> cur, int? nextCour) {
    final want = _suffix(cur);
    for (final n in _sectionsOf(nextCour)) {
      if (_suffix(n) == want) return _id(n['cla_id']);
    }
    return null;
  }

  /// Choose the current standard: saved matches fill the grid; with none, the
  /// next standard in order is proposed and sections are matched by letter.
  void _selectCurrent(int? cour) {
    _cur = cour;
    _pick.clear();
    final saved = _matches.where((m) => _id(m['curcourseid']) == cour).toList();
    if (saved.isNotEmpty) {
      _next = _id(saved.first['nextcourseid']);
    } else {
      final i = _courses.indexWhere((c) => _id(c['cour_id']) == cour);
      _next = (i >= 0 && i + 1 < _courses.length) ? _id(_courses[i + 1]['cour_id']) : null;
    }
    for (final s in _sectionsOf(cour)) {
      final id = _id(s['cla_id'])!;
      final m = saved.firstWhere((x) => _id(x['curclassid']) == id, orElse: () => const {});
      _pick[id] = m.isNotEmpty ? _id(m['nextclassid']) : _autoMatch(s, _next);
    }
  }

  void _selectNext(int? cour) {
    _next = cour;
    for (final s in _sectionsOf(_cur)) {
      _pick[_id(s['cla_id'])!] = _autoMatch(s, cour);
    }
  }

  Future<void> _save() async {
    if (_cur == null || _next == null) {
      return _snack(context, schoolTerm('Select the current and the next course.'), AppColors.warning);
    }
    if (_cur == _next) return _snack(context, schoolTerm('The next course must be a different course.'), AppColors.warning);
    final rows = _pick.entries.where((e) => e.value != null).toList();
    if (rows.isEmpty) return _snack(context, schoolTerm('Select the next class for at least one class.'), AppColors.warning);
    setState(() => _saving = true);
    try {
      // Replace this standard's matches as a whole.
      await SupabaseService.deleteSchemaRowsWhere('classmatch', {'curcourseid': _cur});
      for (final e in rows) {
        await SupabaseService.saveSchemaRow('classmatch', {
          'curclassid': e.key,
          'curcourseid': _cur,
          'nextclassid': e.value,
          'nextcourseid': _next,
          'activestatus': 1,
        });
      }
      if (!mounted) return;
      _snack(context, schoolTerm('Class mapping saved for ${_courseName(_cur)} to ${_courseName(_next)} (${rows.length} class(es)).'), AppColors.success);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, '${schoolTerm('Could not save the class mapping.')} ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteStandard(int cour) async {
    if (!await _confirmDelete(context, schoolTerm('class mapping for ${_courseName(cour)}'))) return;
    try {
      await SupabaseService.deleteSchemaRowsWhere('classmatch', {'curcourseid': cour});
      if (_cur == cour) _cur = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, '${schoolTerm('Could not delete the class mapping.')} ${friendlyError(e)}', AppColors.error);
    }
  }

  Widget _courseDrop(String hint, int? value, ValueChanged<int?> onChanged, {int? exclude}) {
    final opts = _courses.where((c) => _id(c['cour_id']) != exclude).toList();
    return AppDropdownField<int>(
      key: ValueKey('$hint-$value-${opts.length}'),
      initialValue: opts.any((c) => _id(c['cour_id']) == value) ? value : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      style: _fieldTextStyle(context),
      decoration: _filledFieldDec(context, hint, filled: value != null, leadingIcon: 'teacher'),
      hint: _ddHint(context, hint),
      items: [
        for (final c in opts)
          DropdownMenuItem(value: _id(c['cour_id']), child: Text('${c['courname']}', style: AppUI.fieldText(context))),
      ],
      onChanged: _saving ? null : onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!isSchool) {
      return AppUI.empty(title: 'Class Mapping is available for schools only.');
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    final cur = _sectionsOf(_cur);
    final nextOpts = _sectionsOf(_next);
    // Saved matches grouped by current standard, in standard order.
    final byStd = <int, List<Map<String, dynamic>>>{};
    for (final m in _matches) {
      (byStd[_id(m['curcourseid']) ?? 0] ??= []).add(m);
    }
    final stdOrder = _courses.map((c) => _id(c['cour_id'])!).where(byStd.containsKey).toList();
    final listRows = [
      for (final s in stdOrder)
        ...(byStd[s]!..sort((a, b) => classCompare(_className(_id(a['curclassid'])), _className(_id(b['curclassid']))))),
    ];

    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 520.w,
        child: Container(
          padding: EdgeInsets.all(AppUI.cardPad),
          decoration: AppUI.card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            CardTitleBlock(icon: 'arrow-swap-horizontal', title: schoolTerm('Class Mapping'), subtitle: schoolTerm('Which class each class moves into at promotion')),
            SizedBox(height: 18.h),
            _lbl(schoolTerm('Current Course *')),
            SizedBox(height: 6.h),
            _courseDrop(schoolTerm('Select current course'), _cur, (v) => setState(() => _selectCurrent(v))),
            SizedBox(height: 14.h),
            _lbl(schoolTerm('Next Course *')),
            SizedBox(height: 6.h),
            _courseDrop(schoolTerm('Select next course'), _next, (v) => setState(() => _selectNext(v)), exclude: _cur),
            SizedBox(height: 16.h),
            Expanded(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
                child: Column(children: [
                  Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                    child: Row(children: [
                      Expanded(child: Text(schoolTerm('CURRENT CLASS'), style: _h())),
                      Expanded(child: Text(schoolTerm('NEXT CLASS'), style: _h())),
                    ]),
                  ),
                  Expanded(
                    child: _cur == null
                        ? AppUI.empty(title: schoolTerm('Select the current course'))
                        : cur.isEmpty
                            ? AppUI.empty(title: schoolTerm('No classes in ${_courseName(_cur)}'))
                            : ListView.separated(
                                itemCount: cur.length,
                                separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                                itemBuilder: (_, i) {
                                  final s = cur[i];
                                  final id = _id(s['cla_id'])!;
                                  final chosen = _pick[id];
                                  return Container(
                                    color: i.isEven ? Colors.white : AppColors.surface,
                                    padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 6.h),
                                    child: Row(children: [
                                      Expanded(child: Text('${s['claname']}', style: AppUI.fieldText(context))),
                                      Expanded(
                                        child: AppDropdownField<int>(
                                          key: ValueKey('nx-$id-$chosen-$_next'),
                                          initialValue: nextOpts.any((c) => _id(c['cla_id']) == chosen) ? chosen : null,
                                          isExpanded: true,
                                          isDense: true,
                                          dropdownColor: Colors.white,
                                          decoration: _dec('', filled: chosen != null),
                                          hint: Text(schoolTerm('Select class'), style: AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)),
                                          items: [
                                            for (final n in nextOpts)
                                              DropdownMenuItem(value: _id(n['cla_id']), child: Text('${n['claname']}', style: AppUI.fieldText(context))),
                                          ],
                                          onChanged: _saving ? null : (v) => setState(() => _pick[id] = v),
                                        ),
                                      ),
                                    ]),
                                  );
                                },
                              ),
                  ),
                ]),
              ),
            ),
            SizedBox(height: 14.h),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              AppUI.requiredNote(),
              const Spacer(),
              OutlinedButton(
                onPressed: _saving ? null : () => setState(() => _selectCurrent(_cur)),
                child: const Text('Cancel'),
              ),
              SizedBox(width: 10.w),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save, size: 16),
                label: const Text('Save'),
              ),
            ]),
          ]),
        ),
      ),
      SizedBox(width: 16.w),
      Expanded(
        child: _listCard(
          icon: 'category',
          title: schoolTerm('Saved Class Mapping'),
          count: listRows.length,
          countLabel: 'mappings',
          headerCells: [
            Expanded(child: Text(schoolTerm('COURSE'), style: _h())),
            Expanded(child: Text(schoolTerm('CURRENT CLASS'), style: _h())),
            Expanded(child: Text(schoolTerm('NEXT CLASS'), style: _h())),
            SizedBox(width: 90.w, child: Text('', style: _h())),
          ],
          body: listRows.isEmpty
              ? AppUI.empty(title: schoolTerm('No class mapping saved yet'), why: schoolTerm('Pick the current and next course on the left and save.'))
              : ListView.separated(
                  itemCount: listRows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                  itemBuilder: (_, i) {
                    final m = listRows[i];
                    final std = _id(m['curcourseid']);
                    final firstOfStd = i == 0 || _id(listRows[i - 1]['curcourseid']) != std;
                    return InkWell(
                      onTap: () => setState(() => _selectCurrent(std)),
                      child: Container(
                        color: i.isEven ? Colors.white : AppColors.surface,
                        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                        child: Row(children: [
                          Expanded(child: Text(firstOfStd ? '${_courseName(std)} -> ${_courseName(_id(m['nextcourseid']))}' : '', style: _c())),
                          Expanded(child: Text(_className(_id(m['curclassid'])), style: _c())),
                          Expanded(child: Text(_className(_id(m['nextclassid'])), style: _c())),
                          SizedBox(
                            width: 90.w,
                            child: firstOfStd
                                ? Align(
                                    alignment: Alignment.centerRight,
                                    child: IconButton(
                                      tooltip: schoolTerm('Delete this course\'s mapping'),
                                      onPressed: () => _deleteStandard(std!),
                                      icon: const AppIcon('trash', size: 16, color: AppColors.error),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ),
    ]);
  }
}

// ══════════════════════════════════════════════════════════════════════════
// CLASS FEE DEMAND
// ══════════════════════════════════════════════════════════════════════════

class _FeeLine {
  /// Identity for the fee-type picker's widget key.
  ///
  /// Autocomplete seeds its text controller from `initialValue` ONCE, when the
  /// widget is first built. Keying it on the row INDEX meant that switching to
  /// Edit — which replaces _lines with freshly loaded rows — reused the same
  /// State for index 0, so the box kept its old (empty) text while the amount
  /// beside it showed the saved figure. The amount survived because it owns its
  /// controller here; the fee type did not because Autocomplete owns that one.
  /// A per-line id changes whenever the lines are rebuilt and never while the
  /// user is typing, so the field re-seeds on load without losing focus.
  static int _seq = 0;
  final int uid = ++_seq;

  String? feeType;
  final amount = TextEditingController();

  /// ALL tick. Decides whether the fee is raised against students at all:
  /// ticked → a demand per student in the class (feedemand.collectible = true);
  /// unticked → saved on the classfeedemand template only.
  bool applyAll = false;
  bool isCustom = false; // user-added via "Add Row" — fee type is a dropdown
  /// School, Edit: loaded from a saved line, so its fee type is locked --
  /// change the amount or who it applies to, or delete the row (user,
  /// 2026-11-16 "on edit already selected feetypes cannot change").
  bool saved = false;

  /// School "Applicable To" (classfeedemand.cfnob / cfbgb / cfdhb):
  /// New(1)/Old(2), Boy(1)/Girl(2), Dayscholar(1)/Hostler(2); 3 = Both.
  // dhb (Day Scholar / Hosteller) is no longer asked: always 3 = Both
  // (user, 2026-11-02). The column stays in the table for older rows.
  int nob = 3, bgb = 3, dhb = 3;
  void dispose() => _disposeAfterFrame(amount);
}

/// Why a fee type cannot go on a second row.
String _dupText(String fee) => '$fee is already added for these students. To add it again for different students, '
    'set New / Old or Boy / Girl on both rows so they do not overlap ("Both" includes everyone).';

/// The lock shown in place of the search mark on a saved fee type.
Widget _lockedMark() => Tooltip(
      message: 'Saved fee type - it cannot be changed. Edit the amount, or delete the row to remove it.',
      child: Icon(Icons.lock_outline, size: 16.sp, color: AppColors.textSecondary),
    );

const Map<int, String> _kNobLabels = {3: 'Both', 1: 'New', 2: 'Old'};
const Map<int, String> _kBgbLabels = {3: 'Both', 1: 'Boy', 2: 'Girl'};

class _ClassFeeDemandPanel extends StatefulWidget {
  const _ClassFeeDemandPanel();
  @override
  State<_ClassFeeDemandPanel> createState() => _ClassFeeDemandPanelState();
}

class _ClassFeeDemandPanelState extends State<_ClassFeeDemandPanel> with AutomaticKeepAliveClientMixin {
  String? _cls;
  String? _sem;
  String? _admId; // null => all admission types
  DateTime? _due;
  bool _editMode = false; // false = New (blank grid), true = Edit (prefilled)
  final List<_FeeLine> _lines = [];

  List<String> _classNames = [];

  /// School: a standard whose Fee Demand By is STANDARD shows in the picker
  /// once, as "<standard> - all sections"; that label -> its sections. Saving
  /// it writes the same lines to every one of them.
  final Map<String, List<String>> _stdSections = {};

  /// The sections a picker entry stands for (a section is just itself).
  List<String> _sectionsOf(String cls) => _stdSections[cls] ?? [cls];
  List<String> _semesters = [];
  // Semester name -> {start, end} dates, used to bound the Pay-On-or-Before picker.
  List<String> _feeTypeNames = [];

  /// feedesc -> every fg_id it appears under. A SET, not one id: the same fee
  /// name can legitimately exist in more than one group, and collapsing that
  /// to a single id would hide the name from one of its groups.
  final Map<String, Set<int>> _feeTypeGroups = {};

  /// Fee groups, for the group filter above the grid.
  List<Map<String, dynamic>> _feeGroups = [];

  /// OPTIONAL fee types (feetype.type 'OPT'): kept on the section template
  /// but never raised for every student (generate_feedemand_for_class) --
  /// flagged on the row, as Advance Fee Demand does (user, 2026-11-14).
  final Set<String> _optional = {};

  /// Who the demand is raised for: null = everyone, 'Y' = hostellers only,
  /// 'N' = day scholars only.
  ///
  /// Unlike the fee group filter this one CHANGES WHAT IS SAVED, not just
  /// what is shown -- a mess or hostel fee should reach hostellers and nobody
  /// else. It narrows the student roster in _generateTempDemands exactly the
  /// way the Admission Type filter already does.
  ///
  /// THE USER'S CHOICE, and nothing else writes to it. Read it through
  /// [_effHostelFilter], which applies the HOSTELLERS ONLY pin on top without
  /// overwriting what was picked here.
  String? _hostelFilter;

  /// fg_id of every group ticked HOSTELLERS ONLY in Setup > Fee Master > Fee
  /// Group.
  ///
  /// This is not a display filter. A fee in one of these groups must reach
  /// hostellers and nobody else, whatever [_hostelFilter] happens to be set
  /// to -- MESS FEE was staged against all 71 students of B.TECH AI&DS-I
  /// because the dropdown was left on "All Students" and nothing else checked.
  /// The rule belongs to the group, so the group enforces it.
  final Set<int> _hostelOnlyGroups = <int>{};

  /// Whether the fee group currently chosen in the picker is hostellers-only.
  bool get _groupIsHostelOnly => _fgFilter != null && _hostelOnlyGroups.contains(_fgFilter);

  /// Why the last generate matched nobody, counted filter by filter. Set only
  /// on the zero path, so it costs nothing on a normal save.
  String? _rosterDiag;

  /// The roster the batch actually runs against: the user's own choice, unless
  /// a HOSTELLERS ONLY group is selected, which pins it to hostellers.
  ///
  /// DERIVED, never stored. [_hostelFilter] keeps what the user picked and
  /// nothing else writes to it, so moving off a ticked group restores that
  /// choice instead of leaving "Hostellers only" stuck in the box.
  String? get _effHostelFilter => _groupIsHostelOnly ? 'Y' : _hostelFilter;

  /// Whether this fee line may only be billed to hostellers.
  ///
  /// The picker is narrowed to one group, so that is the group the line was
  /// chosen from and its flag is the one that counts. A line whose fee does
  /// not belong to the current group (a row saved before the filter moved)
  /// falls back to its own groups, and is hostel-only only if EVERY group it
  /// appears under is ticked -- one open group means the fee is legitimately
  /// billable to everyone and must not be withheld.
  bool _hostelOnlyLine(_FeeLine l) {
    final groups = _feeTypeGroups[l.feeType?.trim()] ?? const <int>{};
    if (groups.isEmpty) return false;
    if (_fgFilter != null && groups.contains(_fgFilter)) {
      return _hostelOnlyGroups.contains(_fgFilter);
    }
    return groups.every(_hostelOnlyGroups.contains);
  }

  /// Which group the fee-type picker is narrowed to. null = every group.
  ///
  /// A FILTER ON THE PICKER ONLY. It never touches the rows already saved for
  /// a class -- those are rebuilt from _feeTypeNames unfiltered, so switching
  /// the filter can never make a saved fee line disappear.
  int? _fgFilter;

  /// The one entry in [options] whose text matches exactly, or null. Shared
  /// by the class and fee type pickers so both commit typed text the same way.
  String? _matchOne(List<String> options, String text) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final e in options) {
      if (e.toLowerCase() == q) return e;
    }
    return null;
  }

  /// The fee type whose name is EXACTLY this text, or null.
  ///
  /// Matched against the UNFILTERED list on purpose: a row that already holds
  /// a valid fee type must not be invalidated just because the group filter
  /// was narrowed afterwards.
  String? _matchFeeType(String text) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final e in _feeTypeNames) {
      if (e.toLowerCase() == q) return e;
    }
    return null;
  }

  /// The rows the grid shows, after the fee group filter.
  ///
  /// A VIEW OVER _lines, not a rebuild. Every row stays in _lines with whatever
  /// has been typed into it, so changing the filter cannot discard an amount
  /// that has not been saved yet -- which is exactly what reloading the grid on
  /// every filter change would do.
  ///
  /// A row with no fee type chosen yet always shows: otherwise Add Row under a
  /// filter would append a row the user cannot see.
  List<_FeeLine> get _visibleLines {
    if (_fgFilter == null) return _lines;
    return _lines.where((l) => l.feeType == null || (_feeTypeGroups[l.feeType]?.contains(_fgFilter) ?? false)).toList();
  }

  /// [fee] is already on another row that reaches any of the same students
  /// (user, 2026-11-16 "no duplicate feetype to add"). College rows are all
  /// "Both", so there it is simply the same fee type twice.
  bool _dupFee(_FeeLine l, String? fee, {int? nob, int? bgb}) =>
      fee != null &&
      _lines.any((o) =>
          !identical(o, l) &&
          o.feeType == fee &&
          _flagsMeet(o.nob, nob ?? l.nob) &&
          _flagsMeet(o.bgb, bgb ?? l.bgb) &&
          _flagsMeet(o.dhb, l.dhb));

  void _dupSnack(String fee) => _snack(context, _dupText(fee), AppColors.warning);

  /// The first fee line that repeats another for the same students, if any.
  _FeeLine? _firstDup(List<_FeeLine> lines) {
    for (final l in lines) {
      if (_dupFee(l, l.feeType)) return l;
    }
    return null;
  }

  /// The fee types the picker offers, after the group filter.
  List<String> get _pickableFeeTypes => _fgFilter == null ? _feeTypeNames : _feeTypeNames.where((n) => _feeTypeGroups[n]?.contains(_fgFilter) ?? false).toList();
  List<Map<String, dynamic>> _admTypes = [];
  Map<String, String> _admName = {};
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _blankLines(); // opens with a few blank rows, like Advance Fee Demand
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Retry the batch a couple of times so a dropped connection self-heals
      // instead of leaving the panel stuck/blank on the flaky network.
      List<dynamic> results = const [];
      for (var attempt = 0;; attempt++) {
        try {
          results = await Future.wait([
            // Page past PostgREST's 1000-row cap — an institution can have far
            // more class-fee definitions across all classes/sems/quotas, and Edit
            // needs every row to prefill. Ordered by cf_id for stable paging.
            SupabaseService.fetchAll(() => SupabaseService.fromSchema('classfeedemand').select('*').eq('activestatus', 1).order('cf_id')),
            SupabaseService.fromSchema('class').select('claname, ordid, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
            SupabaseService.fromSchema('feetype').select('feedesc, fg_id, type').eq('activestatus', 1),
            // No admission type on the school database -- keep the slot, empty.
            if (isSchool)
              Future.value(<Map<String, dynamic>>[])
            else
              SupabaseService.fromSchema('admissiontype').select('adm_id, admname').eq('ins_id', _insId).eq('activestatus', 1),
            SupabaseService.fromSchema('semester').select('semname, semstart, semend').eq('ins_id', _insId).eq('activestatus', 1),
            SupabaseService.fromSchema('course').select(isSchool ? 'cour_id, ordid, courname, feelevel' : 'cour_id, ordid').eq('ins_id', _insId).eq('activestatus', 1),
            SupabaseService.fromSchema('feegroup').select(isSchool ? 'fg_id, fgdesc' : 'fg_id, fgdesc, hostellers_only').eq('ins_id', _insId).eq('activestatus', 1),
          ]);
          break;
        } catch (_) {
          if (attempt >= 2) rethrow;
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from((results[0] as List).cast<Map<String, dynamic>>());
        // Order classes by course order, then class order (matches the
        // dashboard's class-wise ordering) instead of plain alphabetical.
        final courseOrd = <int, int>{
          for (final c in (results[5] as List))
            if ((c['cour_id'] as num?) != null) (c['cour_id'] as num).toInt(): (c['ordid'] as num?)?.toInt() ?? 9999,
        };
        final seenClass = <String>{};
        final classRows = (results[1] as List).where((e) {
          final nm = e['claname']?.toString().trim() ?? '';
          return nm.isNotEmpty && seenClass.add(nm);
        }).toList()
          ..sort((a, b) {
            final ca = courseOrd[(a['cour_id'] as num?)?.toInt()] ?? 9999;
            final cb = courseOrd[(b['cour_id'] as num?)?.toInt()] ?? 9999;
            if (ca != cb) return ca.compareTo(cb);
            final oa = (a['ordid'] as num?)?.toInt() ?? 9999;
            final ob = (b['ordid'] as num?)?.toInt() ?? 9999;
            return oa.compareTo(ob);
          });
        // Master ordid order within each group, TC batches last
        // (utils/class_sort.dart).
        _classNames = classGroupPartition(classRows.map((e) => e['claname'].toString().trim()), (s) => s);
        // Standards set to Fee Demand By = Standard collapse to one entry.
        _stdSections.clear();
        if (isSchool) {
          final stdLabel = <int, String>{
            for (final c in (results[5] as List))
              if ('${c['feelevel'] ?? ''}' == 'STANDARD' && (c['cour_id'] as num?) != null)
                (c['cour_id'] as num).toInt(): '${'${c['courname'] ?? ''}'.trim()} - all sections',
          };
          final courOf = <String, int?>{for (final e in classRows) e['claname'].toString().trim(): (e['cour_id'] as num?)?.toInt()};
          final merged = <String>[];
          for (final n in _classNames) {
            final label = stdLabel[courOf[n]];
            if (label == null) {
              merged.add(n);
            } else {
              if (!_stdSections.containsKey(label)) merged.add(label);
              (_stdSections[label] ??= []).add(n);
            }
          }
          _classNames = merged;
          if (_cls != null && !_classNames.contains(_cls)) _cls = null; // the flag changed
        }
        _feeTypeNames = (results[2] as List).map((e) => e['feedesc']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort();
        _optional
          ..clear()
          ..addAll([
            for (final e in (results[2] as List))
              if ('${e['type'] ?? ''}'.trim().toUpperCase() == 'OPT') '${e['feedesc']}'.trim(),
          ]);
        _feeTypeGroups.clear();
        for (final e in (results[2] as List)) {
          final nm = e['feedesc']?.toString().trim() ?? '';
          final fg = (e['fg_id'] as num?)?.toInt();
          if (nm.isEmpty || fg == null) continue;
          (_feeTypeGroups[nm] ??= <int>{}).add(fg);
        }
        _feeGroups = List<Map<String, dynamic>>.from((results[6] as List).cast<Map<String, dynamic>>())..sort((a, b) => (a['fgdesc']?.toString() ?? '').compareTo(b['fgdesc']?.toString() ?? ''));
        _hostelOnlyGroups
          ..clear()
          ..addAll(_feeGroups.where((g) => g['hostellers_only'] == true).map((g) => (g['fg_id'] as num?)?.toInt()).whereType<int>());
        // No fee group selector (user, 2026-10-30): the picker offers every
        // group's fee types; each saved line takes its group from its fee
        // type, so _fgFilter stays null.
        _fgFilter = null;
        _admTypes = List<Map<String, dynamic>>.from((results[3] as List).cast<Map<String, dynamic>>());
        _semesters = (results[4] as List).map((e) => e['semname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort(_semesterOrder);
        _admName = {for (final a in _admTypes) a['adm_id'].toString(): a['admname']?.toString() ?? ''};
        // Start with no class selected so the 'Select Class' placeholder shows.
        if (_cls != null) _reloadGrid();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  double get _total => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.amount.text.trim()) ?? 0));

  String _amtStr(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// Rebuild the grid for the current Class / Semester / Admn Type selection:
  /// one row per active fee type, with AMOUNT (and ALL) pre-filled from any
  /// existing classfeedemand record that matches the selection. Fee types
  /// without an existing record show a blank amount. Called inside an existing
  /// setState whenever Class, Semester or Admn Type changes.
  void _loadLinesForSelection() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    if (isSchool) {
      int flag(dynamic v) => (v is num ? v.toInt() : int.tryParse('${v ?? ''}')) ?? 3;
      bool inSel(Map r, String c) => (r['cfclass']?.toString() ?? '') == c && (_sem == null || (r['cfterm']?.toString() ?? '') == _sem);
      // Edit can be pressed before a section is picked: show one empty row
      // rather than failing half-way with the old rows already gone.
      final secs = _cls == null ? const <String>[] : _sectionsOf(_cls!);
      if (secs.isEmpty) {
        _lines.add(_FeeLine()..isCustom = true);
        return;
      }
      final src = secs.firstWhere((c) => _rows.any((r) => inSel(r, c)), orElse: () => secs.first);
      final saved = _rows
          .where((r) => inSel(r, src))
          .toList()
        ..sort((a, b) => ((a['cf_id'] as num?) ?? 0).compareTo((b['cf_id'] as num?) ?? 0));
      for (final r in saved) {
        final d = DateTime.tryParse(r['cfdduedate']?.toString() ?? '');
        if (d != null) {
          _due = d;
          break;
        }
      }
      for (final r in saved) {
        final line = _FeeLine()
          ..feeType = r['cffeetype']?.toString()
          ..saved = true
          ..applyAll = true
          ..nob = flag(r['cfnob'])
          ..bgb = flag(r['cfbgb'])
          ..dhb = flag(r['cfdhb']);
        final amt = r['cfamount'];
        final n = amt is num ? amt : double.tryParse(amt?.toString() ?? '');
        if (n != null) line.amount.text = _amtStr(n);
        _lines.add(line);
      }
      if (_lines.isEmpty) _lines.add(_FeeLine()..isCustom = true);
      return;
    }
    // Existing records matching the current selection (class + sem + adm type).
    final existing = <String, Map<String, dynamic>>{};
    for (final r in _rows) {
      if ((r['cfclass']?.toString() ?? '') != _cls) continue;
      if (_sem != null && (r['cfterm']?.toString() ?? '') != _sem) continue;
      final admMatch = _admId == null ? r['admissiontype'] == null : r['admissiontype']?.toString() == _admId;
      if (!admMatch) continue;
      existing[r['cffeetype']?.toString() ?? ''] = r;
    }
    // Prefill "Pay On or Before" from the saved records (one due date per
    // selection) so Edit shows the existing due date instead of a blank field.
    for (final r in existing.values) {
      final raw = r['cfdduedate']?.toString();
      if (raw != null && raw.isNotEmpty) {
        final d = DateTime.tryParse(raw);
        if (d != null) {
          _due = d;
          break;
        }
      }
    }
    // Only the fee types this selection actually has saved — same reasoning as
    // the blank grid: listing every fee type in the institution buried the
    // handful that carry an amount. Add Row adds one that isn't there yet.
    final savedTypes = _feeTypeNames.where(existing.containsKey).toList();
    for (final ft in savedTypes) {
      final line = _FeeLine()..feeType = ft;
      final r = existing[ft];
      if (r != null) {
        final amt = r['cfamount'];
        final n = amt is num ? amt : double.tryParse(amt?.toString() ?? '');
        if (n != null) line.amount.text = _amtStr(n);
        line.applyAll = r['collectible'] == true; // restore the ALL tick on edit
      }
      _lines.add(line);
    }
    if (_lines.isEmpty) {
      _lines.add(_FeeLine()..isCustom = true);
    }
  }

  /// cf_id / cla_id / sem_id / fee_id for the current selection, keyed by fee
  /// type, read back from classfeedemand after the template has been saved.
  ///
  /// They cannot be known before the save: the insert supplies only cf_id, and
  /// cla_id / sem_id / fee_id are filled by the set_classfee_ids trigger. A
  /// demand staged without them carries four NULLs and loses its link to the
  /// template row that raised it.
  Map<String, Map<String, int?>> _templateIds = {};

  /// [forClass] because Copy Fee writes the same lines to several classes and
  /// each one has its OWN cf_id and cla_id. Loading once for the screen's
  /// class and reusing it would stamp the source class's ids onto every copy.
  Future<void> _loadTemplateIds({String? forClass}) async {
    _templateIds = {};
    final cls = forClass ?? _cls;
    if (cls == null || _sem == null) return;
    try {
      var q = SupabaseService.fromSchema('classfeedemand').select('cf_id, cla_id, sem_id, fee_id, cffeetype').eq('cfclass', cls).eq('cfterm', _sem!).eq('activestatus', 1);
      final admId = _admId == null ? null : int.tryParse(_admId!);
      if (!isSchool) q = admId == null ? q.isFilter('admissiontype', null) : q.eq('admissiontype', admId);
      for (final r in (await q as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final ft = m['cffeetype']?.toString();
        if (ft == null || ft.isEmpty) continue;
        int? id(String k) => (m[k] as num?)?.toInt();
        _templateIds[ft] = {
          'cf_id': id('cf_id'),
          'cla_id': id('cla_id'),
          'sem_id': id('sem_id'),
          'fee_id': id('fee_id'),
        };
      }
    } catch (e) {
      // Not fatal: the demand is still correct money, it just loses the link
      // back to its template. Say so rather than failing the whole save.
      debugPrint('_loadTemplateIds failed: $e');
    }
  }

  /// Blank grid for NEW mode: ONE empty row whose fee type is picked from a
  /// dropdown. It used to seed a row per fee type, which meant scrolling a list
  /// of every fee in the institution to reach the two or three actually being
  /// set (and saving skips empty rows anyway). Add Row grows it on demand.
  void _blankLines() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    // Five, not one. Defining a class's fees means entering several, and a
    // single row made Add Row a step before every one of them.
    for (var i = 0; i < 5; i++) {
      _lines.add(_FeeLine()..isCustom = true);
    }
  }

  /// The chosen section (or every section of a standard) already has fees for
  /// the chosen term.
  bool get _hasSaved {
    if (_cls == null || _sem == null) return false;
    final secs = _sectionsOf(_cls!);
    return _rows.any((r) => secs.contains('${r['cfclass'] ?? ''}') && '${r['cfterm'] ?? ''}' == _sem);
  }

  /// Rebuild the grid for the current selection per the active mode: New shows
  /// blank rows, Edit prefills from saved classfeedemand. School: the mode
  /// follows what is saved -- fees already there open in Edit and New is not
  /// offered; nothing saved is New (user, 2026-11-16).
  void _reloadGrid() {
    if (isSchool) _editMode = _hasSaved;
    _editMode ? _loadLinesForSelection() : _blankLines();
  }

  Future<void> _save() async {
    if (_cls == null || _sem == null || _due == null) {
      return _snack(context, schoolTerm('Select the class, semester and Pay On or Before date.'), AppColors.warning);
    }
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _snack(context, 'Add at least one fee line.', AppColors.warning);
    final dup = _firstDup(lines);
    if (dup != null) return _dupSnack(dup.feeType!);
    if (isSchool) {
      for (final l in lines) {
        l.applyAll = true; // no ALL tick: Applicable To decides who is billed
      }
    }
    final auth = context.read<AuthProvider>(); // capture before async gaps
    setState(() => _saving = true);
    int done = 0;
    int demCount = 0;
    final fails = <String>[];

    // Idempotent save: replace the template rows for THIS Class + Semester +
    // Admn Type so unticking/editing persists instead of leaving stale rows
    // (an insert-only save left the old collectible=true row behind, so the
    // ALL tick reappeared on reload).
    // A standard set to Fee Demand By = Standard: the same lines go to every
    // one of its sections (a section entry is just itself).
    final targets = isSchool ? _sectionsOf(_cls!) : [_cls!];
    try {
      for (final cls in targets) {
        await SupabaseService.deleteSchemaRowsWhere('classfeedemand', {
          'cfclass': cls,
          'cfterm': _sem!,
          if (!isSchool) 'admissiontype': _admId != null ? int.tryParse(_admId!) : null,
        });
      }
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      return _snack(context, 'Could not replace the saved fee lines. ${friendlyError(e)}', AppColors.error);
    }

    for (final cls in targets) {
     for (final l in lines) {
      try {
        await SupabaseService.saveSchemaRow('classfeedemand', {
          'cf_id': await _nextId('classfeedemand', 'cf_id'),
          'cfclass': cls,
          'cfterm': _sem,
          'cffeetype': l.feeType,
          'cfamount': double.tryParse(l.amount.text.trim()),
          'cfdduedate': _due!.toIso8601String().split('T').first,
          if (!isSchool) 'admissiontype': _admId != null ? int.tryParse(_admId!) : null,
          'collectible': isSchool || l.applyAll,
          if (isSchool) ...{'cfnob': l.nob, 'cfbgb': l.bgb, 'cfdhb': l.dhb},
        });
        if (cls == targets.first) done++;
      } catch (e) {
        fails.add('${targets.length > 1 ? '$cls ' : ''}${l.feeType}: ${friendlyError(e)}');
      }
     }
    }
    // New mode: stage a tempfeedemand per student for EVERY fee line (→ Fee
    // Demand Approval → feedemand). Edit mode: push the edited amounts straight
    // into the students' existing feedemand rows instead of staging new ones.
    if (fails.isEmpty) {
      try {
        // Read the template rows BACK before staging demands.
        //
        // classfeedemand's cla_id / sem_id / fee_id are filled by the
        // set_classfee_ids trigger, not by the insert above, so the only way
        // to know what they ended up as is to ask. Staging without them left
        // every generated demand with cla_id, sem_id, fee_id and cf_id NULL --
        // a demand that cannot be traced back to the template that raised it,
        // and that the Fee Demand import then reports as missing ids.
        await _loadTemplateIds();
        _belowPaid.clear();
        if (isSchool) {
          for (final cls in targets) {
            demCount += await _schoolDemands(lines, auth, cls, propagate: _editMode);
          }
        } else {
          demCount = _editMode
                ? await _propagateToFeedemand(lines, auth)
                : await _generateTempDemands(lines, auth);
        }
      } catch (e) {
        fails.add('Demand ${_editMode ? 'update' : 'generation'}: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (fails.isEmpty) {
      // Nothing generated has two very different causes — no line was ticked
      // ALL, or none of the students matched — and saying which saves a long
      // hunt for a demand that was never meant to exist.
      final ticked = lines.where((l) => l.applyAll).length;
      final noneTicked = !_editMode && ticked == 0;
      final noStudents = !_editMode && !noneTicked && demCount == 0;
      final secNote = targets.length > 1 ? ' for ${targets.length} sections' : '';
      _snack(
        context,
        _editMode
            ? 'Updated $done fee line(s)$secNote${demCount > 0 ? ' • $demCount student demand(s) updated' : ''}.'
            : noneTicked
                ? schoolTerm('Saved $done fee line(s) to the class template. None ticked ALL, so no student demands were created.')
                : noStudents
                    ? 'Saved $done fee line(s). No student matched, so no demands were created.'
                        '${_rosterDiag != null ? ' ($_rosterDiag)' : ''}'
                    : 'Saved $done fee line(s)$secNote • $demCount demand(s) sent for approval.',
        (noneTicked || noStudents) ? AppColors.warning : AppColors.success,
      );
      if (_belowPaid.isNotEmpty && mounted) {
        final list = List<String>.from(_belowPaid);
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${list.length} Student Fee(s) Not Changed'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('These students have already paid more than the new amount, so their fee was left as it was. '
                        'Refund the difference (Fee Refund) or set a fee they have not overpaid.', style: AppUI.body),
                    const SizedBox(height: 10),
                    for (final t in list)
                      Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $t', style: AppUI.cell)),
                  ],
                ),
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          ),
        );
      }
      setState(() {
        for (final l in _lines) {
          l.dispose();
        }
        _lines
          ..clear()
          ..addAll(List.generate(5, (_) => _FeeLine()));
      });
    }
    await _load();
    if (fails.isNotEmpty && mounted) _snack(context, 'Saved $done fee line(s); ${fails.length} could not be saved. ${fails.first}', AppColors.error);
  }

  /// Stage a tempfeedemand row for every active student in the class × each
  /// ALL-ticked fee line (→ Fee Demand Approval, isapproved=false). temp_id and
  /// demno are filled by the schema's set_temp_id trigger.
  ///
  /// The ALL tick is what decides whether a fee is raised against students at
  /// all: ticked → a demand per student; unticked → the amount is kept on the
  /// classfeedemand template only, ready to be applied later per student (Fee
  /// Demand, Student Fee Definition) without billing the whole class now.
  Future<int> _generateTempDemands(List<_FeeLine> lines, AuthProvider auth, {String? forClass}) async {
    lines = lines.where((l) => l.applyAll).toList();
    if (lines.isEmpty) return 0;
    final cls = forClass ?? _cls!;
    final insId = auth.insId ?? 1;
    final years = await SupabaseService.getYears(insId);
    final yr = years.isNotEmpty ? years.first : null;
    final yrId = yr != null ? int.tryParse(yr['yr_id'].toString()) ?? 0 : 0;
    final yrLabel = yr?['yrlabel']?.toString() ?? '';
    // Restrict to the chosen admission type (null = All).
    String? admName;
    if (_admId != null) {
      admName = _admTypes.firstWhere((a) => a['adm_id'].toString() == _admId, orElse: () => const {})['admname']?.toString();
    }
    // Paged: a truncated roster here would silently skip students when
    // generating demands, leaving them unbilled with no error.
    //
    // `hostel` decides who the demand reaches: 'Y' hostellers, 'N' day
    // scholars, null everyone. students.hostel is char(1) and is null on a
    // few rows -- a null is NOT a hosteller, so 'N' has to match the nulls
    // too or those students are silently skipped and left unbilled.
    Future<List<Map<String, dynamic>>> roster(String? hostel, {bool withAdm = true}) =>
        SupabaseService.fetchAll(() {
          var q = SupabaseService.fromSchema('students')
              .select('stu_id, stuadmno, courname')
              .eq('ins_id', insId)
              .eq('stuclass', cls)
              .eq('activestatus', 1)
              .eq('preadmission', 0); // next year's intake: advance screens only
          if (withAdm && admName != null && admName.isNotEmpty) q = q.eq('admname', admName);
          if (hostel == 'Y') {
            q = q.eq('hostel', 'Y');
          } else if (hostel == 'N') {
            q = q.or('hostel.eq.N,hostel.is.null');
          }
          return q;
        });

    // Split the batch by WHO each line may be billed to, and raise each half
    // against its own roster. One roster for the whole batch cannot be right
    // when a hostel fee and a college fee are saved together: the wider of
    // the two always wins, and the hostel fee lands on day scholars.
    //
    // A hostel-only line is pinned to 'Y' whatever the dropdown says. The one
    // case it yields to is "Day scholars only" -- hostel-only AND day scholar
    // is nobody, so those lines are dropped rather than quietly widened.
    final eff = _effHostelFilter;  // what the dropdown is actually showing
    final hostelLines = lines.where(_hostelOnlyLine).toList();
    final openLines = lines.where((l) => !_hostelOnlyLine(l)).toList();
    final batches = <(List<_FeeLine>, List<Map<String, dynamic>>)>[];
    if (openLines.isNotEmpty) {
      batches.add((openLines, await roster(eff)));
    }
    if (hostelLines.isNotEmpty && eff != 'N') {
      batches.add((
        hostelLines,
        eff == 'Y' && openLines.isNotEmpty
            ? batches.first.$2 // same query, don't ask twice
            : await roster('Y')
      ));
    }

    // Nothing matched. Say WHICH filter emptied the roster instead of naming
    // all of them and leaving the office to guess -- "no students match this
    // class + admission type" was reported for a class that did have
    // students, because the real culprit was the hostel pin and the message
    // never mentioned it.
    if (batches.every((b) => b.$2.isEmpty)) {
      final inClass = (await roster(null, withAdm: false)).length;
      final afterAdm = admName == null || admName.isEmpty ? inClass : (await roster(null)).length;
      final parts = <String>['$inClass in $cls'];
      if (admName != null && admName.isNotEmpty) parts.add('$afterAdm after $admName');
      if (eff != null) {
        parts.add('0 after ${eff == 'Y' ? 'Hostellers only' : 'Day scholars only'}'
            '${_groupIsHostelOnly ? ' (set by the fee group)' : ''}');
      }
      _rosterDiag = parts.join(', ');
      return 0;
    }
    _rosterDiag = null;

    final rows = <Map<String, dynamic>>[];
    final due = _due!.toIso8601String().split('T').first;
    for (final (batchLines, students) in batches) {
      for (final s in students) {
        for (final l in batchLines) {
          final amt = double.tryParse(l.amount.text.trim()) ?? 0;
          rows.add({
            'ins_id': insId,
            'inscode': auth.inscode ?? '',
            'yr_id': yrId,
            'stu_id': s['stu_id'],
            'stuadmno': s['stuadmno'],
            'stuclass': cls,
            'courname': s['courname'],
            'demfeeyear': yrLabel,
            'demfeeterm': _sem,
            'demfeetype': l.feeType,
            // REGULAR, said explicitly. Left out, feedemand's set_dem_id trigger
            // defaults demseqtype to 'DEMAND', so a class-generated demand came
            // out labelled differently from the identical one raised by the
            // import or by add_student_fee_demand, both of which say REGULAR.
            // Only an arrear is anything else.
            'demseqtype': 'REGULAR',
            'feeamount': amt,
            'balancedue': amt,
            'duedate': due,
            'createdby': auth.userName,
            'isapproved': false,
            'activestatus': 1,
            'collectible': l.applyAll,
            // The template row this demand came from. Without these four the
            // demand reaches feedemand with cla_id, sem_id, fee_id and cf_id all
            // NULL and can no longer be traced back to the fee it was raised
            // from -- which is also what the Fee Demand import then complains
            // about. Read back from classfeedemand in _loadTemplateIds, because
            // three of the four are set by a trigger rather than by the insert.
            ...?_templateIds[l.feeType],
          });
        }
      }
    }
    if (rows.isEmpty) return 0;
    await SupabaseService.importSchemaRows('tempfeedemand', List<Map<String, dynamic>>.from(rows));
    return rows.length;
  }

  /// School: Edit first moves each line's new amount onto the unpaid demands
  /// of the students that line applies to (Applicable To), then the server's
  /// generate_feedemand_for_class stages a demand for every matching student
  /// who has none yet for that term + fee type -- the same rules the Class Fee
  /// Demand import uses. Returns demands updated + staged.
  /// Students the server leaves unchanged on an amount edit: they have already
  /// paid (+ concession) more than the new amount. Listed after the save.
  final List<String> _belowPaid = [];

  Future<void> _noteBelowPaid(int insId, String cls, String feeType, double amt, Iterable<String>? admnos) async {
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService.fromSchema('feedemand')
          .select('stuadmno, paidamount, conamount')
          .eq('ins_id', insId)
          .eq('stuclass', cls)
          .eq('demfeeterm', _sem ?? '')
          .eq('demfeetype', feeType)
          .eq('activestatus', 1));
      final only = admnos?.toSet();
      for (final r in rows) {
        final adm = r['stuadmno']?.toString() ?? '';
        if (only != null && !only.contains(adm)) continue;
        final paid = (r['paidamount'] as num?)?.toDouble() ?? 0;
        final con = (r['conamount'] as num?)?.toDouble() ?? 0;
        if (paid <= 0.005 || amt + 0.005 >= paid + con) continue;
        _belowPaid.add('$adm ($cls): $feeType ${formatIndianNumber(amt)} is below already paid '
            '${formatIndianNumber(paid)}${con > 0 ? ' + concession ${formatIndianNumber(con)}' : ''}');
      }
    } catch (_) {/* only the report is lost; the server still skips them */}
  }

  Future<int> _schoolDemands(List<_FeeLine> lines, AuthProvider auth, String cls, {required bool propagate}) async {
    final insId = auth.insId ?? 1;
    var n = 0;
    if (propagate) {
      final studs = await SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
          .select('stuadmno, stugender, hostel, admittyear, yrlabel')
          .eq('ins_id', insId)
          .eq('stuclass', cls)
          .eq('activestatus', 1)
          .eq('preadmission', 0));
      bool fits(_FeeLine l, Map s) {
        final yr = s['yrlabel']?.toString() ?? '';
        final adm = (s['admittyear']?.toString() ?? '').trim();
        final isNew = adm.isNotEmpty && (adm == yr || adm == yr.split('-').first);
        final hosteller = (s['hostel']?.toString() ?? '').trim().toUpperCase() == 'Y';
        final g = s['stugender']?.toString();
        return (l.nob == 3 || l.nob == (isNew ? 1 : 2)) &&
            (l.bgb == 3 || (l.bgb == 1 && g == 'M') || (l.bgb == 2 && g == 'F')) &&
            (l.dhb == 3 || l.dhb == (hosteller ? 2 : 1));
      }
      for (final l in lines) {
        final admnos = [for (final s in (studs as List)) if (fits(l, s as Map)) s['stuadmno'].toString()];
        if (admnos.isEmpty) continue;
        await _noteBelowPaid(insId, cls, l.feeType ?? '', double.tryParse(l.amount.text.trim()) ?? 0, admnos);
        final res = await SupabaseService.client.rpc('propagate_class_fee', params: {
          'p_ins_id': insId,
          'p_class': cls,
          'p_term': _sem,
          'p_lines': [
            {'feetype': l.feeType, 'amount': double.tryParse(l.amount.text.trim()) ?? 0, 'collectible': true},
          ],
          'p_admnos': admnos,
        });
        n += (res as num?)?.toInt() ?? 0;
      }
    }
    final g = await SupabaseService.client.rpc('generate_feedemand_for_class', params: {'p_ins_id': insId, 'p_class': cls});
    n += (g is num) ? g.toInt() : (int.tryParse(g?.toString() ?? '') ?? 0);
    _rosterDiag = null;
    return n;
  }

  /// Edit mode: push the edited Class Fee Demand amounts into the students'
  /// existing UNPAID feedemand rows (same class + term + fee type, restricted to
  /// the chosen admission type). Recomputes balancedue = amount - concession -
  /// paid. Returns the number of student demand rows updated.
  Future<int> _propagateToFeedemand(List<_FeeLine> lines, AuthProvider auth) async {
    final insId = auth.insId ?? 1;
    // Resolve the admno set for the chosen admission type (null = all students).
    Set<String>? allowed;
    if (_admId != null) {
      final admName = _admTypes.firstWhere((a) => a['adm_id'].toString() == _admId, orElse: () => const {})['admname']?.toString();
      final studs = await SupabaseService.fromSchema('students')
          .select('stuadmno')
          .eq('ins_id', insId)
          .eq('stuclass', _cls!)
          .eq('activestatus', 1)
          .eq('preadmission', 0) // next year's intake: advance screens only
          .eq('admname', admName ?? '');
      allowed = {for (final s in (studs as List)) (s as Map)['stuadmno'].toString()};
    }

    // Fast path: one set-based RPC updates every matching unpaid demand per fee
    // line server-side (replaces the old N+1: a SELECT + per-row rebuild for
    // each of potentially thousands of student demands). Falls back to the
    // per-row loop on ANY error so it stays correct even before the migration
    // is run (add_propagate_class_fee.sql) or if the RPC misbehaves.
    for (final l in lines) {
      await _noteBelowPaid(insId, _cls!, l.feeType ?? '', double.tryParse(l.amount.text.trim()) ?? 0, allowed);
    }
    try {
      final lineMaps = [
        for (final l in lines)
          {
            'feetype': l.feeType,
            'amount': double.tryParse(l.amount.text.trim()) ?? 0,
            'collectible': l.applyAll,
          }
      ];
      final res = await SupabaseService.client.rpc('propagate_class_fee', params: {
        'p_ins_id': insId,
        'p_class': _cls,
        'p_term': _sem,
        'p_lines': lineMaps,
        'p_admnos': allowed?.toList(),
      });
      return (res as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('propagate_class_fee RPC unavailable, using per-row fallback: $e');
    }

    var updated = 0;
    for (final l in lines) {
      final amt = double.tryParse(l.amount.text.trim()) ?? 0;
      final res = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuadmno, conamount, paidamount')
          .eq('ins_id', insId)
          .eq('stuclass', _cls!)
          .eq('demfeeterm', _sem!)
          .eq('demfeetype', l.feeType!)
          .eq('paidstatus', 'U')
          .eq('activestatus', 1);
      for (final r in (res as List)) {
        final m = r as Map;
        if (allowed != null && !allowed.contains(m['stuadmno'].toString())) continue;
        final con = (m['conamount'] as num?)?.toDouble() ?? 0;
        final paid = (m['paidamount'] as num?)?.toDouble() ?? 0;
        if (amt + 0.005 < paid + con) continue; // already paid more: left as is (listed)
        final bal = (amt - con - paid) > 0 ? (amt - con - paid) : 0;
        await SupabaseService.rebuildDemand(
          (m['dem_id'] as num).toInt(),
          feeamount: amt,
          balancedue: bal,
          collectible: l.applyAll,
        );
        updated++;
      }
    }
    return updated;
  }

  /// Copy the current grid's fee lines (amounts + ALL ticks) to one or more
  /// other classes for the same Semester + Admn Type. Replaces each target's
  /// existing template rows (idempotent) and stages tempfeedemand for that
  /// class's students — for the ALL-ticked lines only, same rule as Save.
  Future<void> _copyFee() async {
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _snack(context, 'Enter fee amounts to copy.', AppColors.warning);
    final dup = _firstDup(lines);
    if (dup != null) return _dupSnack(dup.feeType!);
    if (isSchool) {
      for (final l in lines) {
        l.applyAll = true;
      }
    }
    if (_sem == null || _due == null) {
      return _snack(context, schoolTerm('Select the semester and Pay On or Before date before copying.'), AppColors.warning);
    }
    final picked = await _pickTargetClasses();
    if (picked == null || picked.isEmpty) return;
    final targets = [for (final t in picked) ...(isSchool ? _sectionsOf(t) : [t])];
    final byStd = isSchool && _stdSections.containsKey(_cls);

    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    final due = _due!.toIso8601String().split('T').first;
    final admType = _admId != null ? int.tryParse(_admId!) : null;
    var classesDone = 0, demTotal = 0;
    final fails = <String>[];
    for (final cls in targets) {
      try {
        // Idempotent: clear this target's template rows for the selection.
        await SupabaseService.deleteSchemaRowsWhere('classfeedemand', {
          'cfclass': cls,
          'cfterm': _sem!,
          if (!isSchool) 'admissiontype': admType,
        });
        for (final l in lines) {
          await SupabaseService.saveSchemaRow('classfeedemand', {
            'cf_id': await _nextId('classfeedemand', 'cf_id'),
            'cfclass': cls,
            'cfterm': _sem,
            'cffeetype': l.feeType,
            'cfamount': double.tryParse(l.amount.text.trim()),
            'cfdduedate': due,
            if (!isSchool) 'admissiontype': admType,
            'collectible': isSchool || l.applyAll,
            if (isSchool) ...{'cfnob': l.nob, 'cfbgb': l.bgb, 'cfdhb': l.dhb},
          });
        }
        await _loadTemplateIds(forClass: cls);
        demTotal += isSchool
            ? await _schoolDemands(lines, auth, cls, propagate: false)
            : await _generateTempDemands(lines, auth, forClass: cls);
        classesDone++;
      } catch (e) {
        fails.add('$cls: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    final copiedTicked = lines.any((l) => l.applyAll);
    _snack(
      context,
      fails.isEmpty
          ? copiedTicked
              ? (byStd
                  ? 'Copied fees to ${picked.length} standard(s) • $demTotal demand(s) staged.'
                  : schoolTerm('Copied fees to $classesDone class(es) • $demTotal demand(s) staged.'))
              : schoolTerm('Copied fees to $classesDone class(es). No line is ticked ALL, so no student demands were created.')
          : 'Copied to $classesDone; could not copy to ${fails.length}. ${fails.first}',
      fails.isEmpty ? (copiedTicked ? AppColors.success : AppColors.warning) : AppColors.error,
    );
    await _load();
  }

  /// Multi-select dialog of target classes (excludes the source class).
  Future<List<String>?> _pickTargetClasses() async {
    final picked = <String>{};
    var copyQuery = ''; // what is typed in the dialog's search box
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Same problem as the class picker: 60-odd classes in a checkbox
          // list meant scrolling to find each one. The search narrows the
          // list; ticks already made are KEPT when the text changes, because
          // `picked` lives outside this builder -- so you can search, tick,
          // clear the search, search again and the earlier ticks survive.
          final q = copyQuery.trim().toLowerCase();
          // School: copy like to like. Fees set for a whole standard (Fee
          // Demand By = Standard) go to other such standards; fees set for a
          // section go to other section-wise sections only.
          final byStd = isSchool && _stdSections.containsKey(_cls);
          String shown(String c) => byStd ? c.replaceFirst(RegExp(r' - all sections$'), '') : c;
          final options = _classNames
              .where((c) => c != _cls && (!isSchool || _stdSections.containsKey(c) == byStd) && (q.isEmpty || shown(c).toLowerCase().contains(q)))
              .toList();
          return AlertDialog(
            title: Text(byStd ? 'Copy Fees to Standards' : schoolTerm('Copy Fees to Classes'), style: AppUI.cardTitle),
            content: SizedBox(
              width: 360.w,
              height: 360.h,
              child: options.isEmpty
                  ? AppUI.empty(
                      title: byStd ? 'No other standards' : schoolTerm('No other classes'),
                      why: !isSchool
                          ? null
                          : byStd
                              ? 'Only standards whose Fee Demand By is Standard are listed.'
                              : 'Only sections of standards whose Fee Demand By is Section are listed.')
                  : ListView(
                      children: [
                        Padding(
                          padding: EdgeInsets.only(bottom: 4.h),
                          child: Text('From ${shown(_cls ?? '')} • ${_sem ?? ''}${isSchool ? '' : ' • ${_admId == null ? 'All' : (_admName[_admId] ?? '')}'}', style: AppUI.muted),
                        ),
                        Padding(
                          padding: EdgeInsets.only(bottom: 6.h),
                          child: TextField(
                            autofocus: true,
                            style: AppUI.fieldText(context),
                            decoration: AppUI.field(context, byStd ? 'Search by standard name' : schoolTerm('Search by class name'), leadingIcon: 'search-normal'),
                            onChanged: (v) => setLocal(() => copyQuery = v),
                          ),
                        ),
                        if (picked.isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(bottom: 4.h),
                            child: Text('${picked.length} selected', style: AppUI.label.copyWith(color: AppColors.primary)),
                          ),
                        for (final c in options)
                          CheckboxListTile(
                            dense: true,
                            value: picked.contains(c),
                            title: Text(shown(c), style: AppUI.body),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) => setLocal(() => v == true ? picked.add(c) : picked.remove(c)),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, picked.toList()),
                child: Text('Copy to ${picked.length}'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _delete(int id) async {
    // A demand raised from this template keeps its cf_id, so deleting the
    // template would leave those demands describing a fee line that no
    // longer exists.
    final used = await countReferencing('feedemand', [('cf_id', id)]);
    if (used > 0) {
      if (mounted) {
        await showMasterInUseDialog(context, name: 'this fee line', count: used, noun: 'fee demand', fix: 'Fee demands have already been raised from this fee line, so it cannot be deleted.');
      }
      return;
    }
    if (!mounted) return;
    if (!await _confirmDelete(context, 'fee line')) return;
    try {
      await SupabaseService.deleteSchemaRow('classfeedemand', 'cf_id', id, soft: false);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Could not delete the fee line. ${friendlyError(e)}', AppColors.error);
    }
  }

  String _fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    // Saved Demands panel removed — the creation form spans the full width.
    return _creation();
  }

  /// Order the term list the way the office reads it: semesters, then YEARLY,
  /// then the months.
  ///
  /// Plain alphabetical interleaved all three -- AUGUST, DECEMBER, FEBRUARY,
  /// I SEM, II SEM, III SEM, IV SEM, JANUARY, JULY... -- so finding "V SEM"
  /// meant scanning past six months. Within each group the order is the one
  /// that means something: I to VIII for semesters, and the ACADEMIC year for
  /// months, June first, because that is when the year starts here and how
  /// the mess and hostel fees are billed.
  static int _semesterOrder(String a, String b) {
    const sems = ['I SEM', 'II SEM', 'III SEM', 'IV SEM', 'V SEM', 'VI SEM', 'VII SEM', 'VIII SEM'];
    const months = ['JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER', 'JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY'];
    // (group, position). Anything unrecognised falls to the end, alphabetical,
    // so a term nobody anticipated is still reachable rather than lost.
    (int, int) rank(String v) {
      final u = v.trim().toUpperCase();
      final si = sems.indexOf(u);
      if (si >= 0) return (0, si);
      if (u == 'YEARLY') return (1, 0);
      final mi = months.indexOf(u);
      if (mi >= 0) return (2, mi);
      return (3, 0);
    }

    final ra = rank(a), rb = rank(b);
    if (ra.$1 != rb.$1) return ra.$1.compareTo(rb.$1);
    if (ra.$2 != rb.$2) return ra.$2.compareTo(rb.$2);
    return a.compareTo(b);
  }

  /// Compact Both / X / Y picker for a school fee line's Applicable To.
  Widget _flagDrop(int value, Map<int, String> labels, ValueChanged<int> onChanged) {
    final set = value != 3;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 6.w),
      child: AppDropdownField<int>(
        initialValue: labels.containsKey(value) ? value : 3,
        isExpanded: true,
        isDense: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(10),
        icon: Icon(Icons.arrow_drop_down, size: 18.sp, color: AppColors.textSecondary),
        decoration: _dec('', filled: set).copyWith(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 9.h)),
        items: [
          for (final e in labels.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value, style: AppUI.fieldText(context))),
        ],
        selectedItemBuilder: (_) => [
          for (final e in labels.entries)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(e.value,
                  overflow: TextOverflow.ellipsis,
                  style: AppUI.fieldText(context, filled: e.key != 3)),
            ),
        ],
        onChanged: (v) => onChanged(v ?? 3),
      ),
    );
  }

  Widget _crumbSep() => Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.w),
        child: Icon(Icons.chevron_right, size: 13.sp, color: AppColors.textLight),
      );

  Widget _modeButton(String label, IconData icon, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryLight : Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: active ? AppColors.primary : AppColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15.sp, color: active ? AppColors.primary : AppColors.textSecondary),
          SizedBox(width: 6.w),
          Text(label, style: AppUI.label.copyWith(color: active ? AppColors.primary : AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _creation() {
    return Container(
      // Outer white card wrapping the whole creation panel (mode buttons,
      // filter row, fee table, total/save) so it visually mirrors the
      // Saved Demands card on the right.
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Page header. Built inline rather than with CardTitleBlock, which
          // takes a subtitle for call-site compatibility but no longer renders
          // one -- and this header needs its subtitle.
          Padding(
            padding: EdgeInsets.only(bottom: 16.h),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              AppUI.iconTile('receipt-edit'),
              SizedBox(width: 12.w),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(schoolTerm('Class Fee Demand'), style: AppUI.cardTitle),
                  SizedBox(height: 2.h),
                  Text(schoolTerm('Define fee types and amounts for each class'), style: AppUI.muted),
                ],
              )),
              // Breadcrumb. Hidden below 1100px: it is orientation, not a
              // control, and it is the first thing worth losing when the filter
              // row needs the width.
              if (MediaQuery.of(context).size.width > 1100)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.home_outlined, size: 14.sp, color: AppColors.textLight),
                  for (final crumb in const ['Setup', 'Fee Master']) ...[
                    _crumbSep(),
                    Text(crumb, style: AppUI.muted),
                  ],
                  _crumbSep(),
                  Text(schoolTerm('Class Fee Demand'), style: AppUI.label),
                ]),
            ]),
          ),
          // Single top row — filters on the left, mode buttons on the right.
          // Each filter is an Expanded slot, mode buttons get fixed widths so
          // everything fits side-by-side without wrapping.
          Padding(
            padding: EdgeInsets.only(bottom: 10.h),
            child: FocusTraversalGroup(
                child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // TYPE TO FIND A CLASS. There are 60-odd of them, so the plain
                // dropdown meant scrolling a long list to reach B.TECH (IT) -III.
                // `contains`, not `startsWith`: the useful fragment is rarely the
                // first word -- "ece" has to find "B.E ECE -II".
                Expanded(
                    child: Autocomplete<String>(
                  key: ValueKey('cls-${_cls ?? ''}'),
                  initialValue: TextEditingValue(text: _cls ?? ''),
                  optionsBuilder: (v) {
                    final q = v.text.trim().toLowerCase();
                    if (q.isEmpty) return _classNames;
                    return _classNames.where((e) => e.toLowerCase().contains(q));
                  },
                  onSelected: (v) => setState(() {
                    _cls = v;
                    _reloadGrid();
                  }),
                  fieldViewBuilder: (context, ctrl, focus, onSubmit) => Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    // Leaving the field with text that matches no class puts the
                    // last valid pick back, so the box never shows a class that
                    // is not actually selected.
                    onFocusChange: (has) {
                      if (has) return;
                      final m = _matchOne(_classNames, ctrl.text);
                      if (m != null) {
                        if (_cls != m)
                          setState(() {
                            _cls = m;
                            _reloadGrid();
                          });
                      } else {
                        ctrl.text = _cls ?? '';
                      }
                    },
                    child: TextField(
                      controller: ctrl,
                      focusNode: focus,
                      style: AppUI.fieldText(context, filled: true),
                      decoration:
                          _filledFieldDec(context, schoolTerm('Search or select class'), filled: _cls != null, leadingIcon: 'teacher').copyWith(suffixIcon: Icon(Icons.search, size: 17.sp, color: AppColors.textSecondary)),
                      onChanged: (v) {
                        final m = _matchOne(_classNames, v);
                        if (m != null && m != _cls)
                          setState(() {
                            _cls = m;
                            _reloadGrid();
                          });
                      },
                      onTap: () {
                        if (ctrl.text.isNotEmpty) ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
                      },
                    ),
                  ),
                  optionsViewBuilder: (context, onSelected, options) => Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: 340.h, maxWidth: 320.w),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (_, i) {
                            final e = options.elementAt(i);
                            return InkWell(
                              onTap: () => onSelected(e),
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                                child: Text(e, style: AppUI.fieldText(context, filled: true)),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                )),
                SizedBox(width: 8.w),
                Expanded(
                    child: AppDropdownField<String>(
                  initialValue: _sem,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context),
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _filledFieldDec(context, schoolTerm('Select semester'), filled: _sem != null, leadingIcon: 'book'),
                  hint: Text(schoolTerm('Select semester'),
                      overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)),
                  items: _semesters
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text(e, style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis)))
                      .toList(),
                  selectedItemBuilder: (context) => _semesters
                      .map((e) => Align(
                          alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _sem = v;
                    _reloadGrid();
                  }),
                )),
                SizedBox(width: 8.w),
                // No admission type on the school database.
                if (!isSchool) ...[
                Expanded(
                    child: AppDropdownField<String>(
                  initialValue: _admId,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context),
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _filledFieldDec(context, 'All Admission Types', filled: _admId != null, leadingIcon: 'layer'),
                  hint: Text('All Admission Types',
                      overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)),
                  items: [
                    // 'all' is a sentinel → normalised to null (applies to every
                    // admission type). Null shows the "All Admission Types" hint.
                    DropdownMenuItem(
                        value: 'all',
                        child: Text('All Admission Types', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis)),
                    ..._admTypes.map((a) => DropdownMenuItem(
                        value: a['adm_id'].toString(),
                        child: Text(a['admname']?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis))),
                  ],
                  selectedItemBuilder: (context) => [
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Text('All Admission Types', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                    ..._admTypes.map((a) => Align(
                        alignment: Alignment.centerLeft,
                        child: Text(a['admname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                  ],
                  onChanged: (v) => setState(() {
                    _admId = v == 'all' ? null : v;
                    _reloadGrid();
                  }),
                )),
                SizedBox(width: 8.w),
                ],
                // HOSTEL -- narrows WHO the demand is raised for.
                //
                // Sits beside the fee group filter but does the opposite kind of
                // job: that one only changes which fee types are offered, this
                // one changes which students get billed when ALL is ticked. A
                // mess or hostel fee must reach hostellers and nobody else.
                // Locked to "Hostellers only", and greyed, while the chosen fee
                // group is ticked HOSTELLERS ONLY -- the group already decides,
                // and a box reading "All Students" over a batch that reaches
                // only hostellers is a lie the screen tells about itself.
                // School: Dayscholar/Hostler is chosen per fee line instead.
                if (!isSchool) ...[
                Expanded(
                    child: AppDropdownField<String>(
                  key: ValueKey('hostel-${_effHostelFilter ?? 'all'}'),
                  initialValue: _effHostelFilter ?? 'all',
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context),
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _filledFieldDec(context, 'All Students', filled: _effHostelFilter != null, leadingIcon: 'buildings'),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All Students', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: 'Y', child: Text('Hostellers only', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: 'N', child: Text('Day scholars only', overflow: TextOverflow.ellipsis)),
                  ],
                  selectedItemBuilder: (context) => [
                    for (final t in const ['All Students', 'Hostellers only', 'Day scholars only'])
                      Align(alignment: Alignment.centerLeft, child: Text(t, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                  ],
                  onChanged: _groupIsHostelOnly
                      ? null
                      : (v) => setState(() => _hostelFilter = (v == null || v == 'all') ? null : v),
                )),
                SizedBox(width: 8.w),
                ],
                // No fee group selector (user, 2026-10-30): the fee-type picker
                // offers every group's fee types.
                Expanded(
                    child: FocusableTap(
                  onTap: () async {
                    final now = DateTime.now();
                    // Due date is independent of the semester start/end dates.
                    final first = DateTime(now.year - 1);
                    final last = DateTime(now.year + 5);
                    final initial = (_due != null && !_due!.isBefore(first) && !_due!.isAfter(last)) ? _due! : now;
                    final p = await showDatePicker(context: context, initialDate: initial, firstDate: first, lastDate: last);
                    if (p != null) setState(() => _due = p);
                  },
                  child: InputDecorator(
                    // InputDecorator doesn't render hintText when a child widget is
                    // present, so we render the placeholder text inline ourselves.
                    decoration: _filledFieldDec(context, '', filled: _due != null, leadingIcon: 'calendar-1').copyWith(
                      // Trailing chevron-free calendar mark: the field opens a
                      // picker, so it should not look like a text box.
                      suffixIcon: Padding(
                        padding: EdgeInsets.only(right: 10.w),
                        child: AppIcon('calendar', size: 15, color: _due != null ? AppColors.primary : AppColors.textSecondary),
                      ),
                      suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    ),
                    child: Text(
                      _due == null ? 'Select date' : _fmt(_due!),
                      overflow: TextOverflow.ellipsis,
                      style: _due == null ? AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight) : AppUI.fieldText(context, filled: true),
                    ),
                  ),
                )),
              ],
            )),
          ),
          // ACTIONS ON THEIR OWN LINE.
          //
          // They used to share the row with the filters. That was fine with
          // four fields; with six -- Class, Semester, Admission Type, Students,
          // Fee Group, Due Date -- the buttons took roughly 600px and left each
          // field about 165, so every one of them read "All Admissio...",
          // "COLLEGE FE...", "Pay On or Be...". The filters now have the full
          // width and the buttons sit right-aligned beneath, which also keeps
          // them in one place instead of drifting as fields are added.
          Padding(
            padding: EdgeInsets.only(bottom: 10.h),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Mouse-only — kept out of Tab so the key moves through the
                // input fields (pickers + amounts) and not the buttons.
                // School: New only while nothing is saved, Edit only once it is.
                if (!isSchool || !_hasSaved) ...[
                  ExcludeFocus(
                      child: _modeButton(
                          'New',
                          Icons.add,
                          !_editMode,
                          () => setState(() {
                                _editMode = false;
                                _reloadGrid();
                              }))),
                  SizedBox(width: 8.w),
                ],
                if (!isSchool || _hasSaved) ...[
                  ExcludeFocus(
                      child: _modeButton(
                          'Edit',
                          Icons.edit,
                          _editMode,
                          () => setState(() {
                                _editMode = true;
                                _reloadGrid();
                              }))),
                  SizedBox(width: 8.w),
                ],
                ExcludeFocus(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _copyFee,
                    icon: const Icon(Icons.copy_all, size: 15),
                    label: const Text('Copy Fees'),
                  ),
                ),
                SizedBox(width: 8.w),
                ExcludeFocus(
                  child: _importButton(context, title: schoolTerm('Class Fee Demand'), tabIndex: 7, disabled: _saving, onReturn: _load),
                ),
              ],
            ),
          ),
          SizedBox(height: 4.h),
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
              child: Column(children: [
                Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text('FEE TYPE', style: _h())),
                      SizedBox(width: 140.w, child: Text('AMOUNT', textAlign: TextAlign.right, style: _h())),
                      if (isSchool) ...[
                        SizedBox(width: 120.w, child: Text('NEW / OLD', textAlign: TextAlign.center, style: _h())),
                        SizedBox(width: 120.w, child: Text('BOY / GIRL', textAlign: TextAlign.center, style: _h())),
                      ] else
                        SizedBox(width: 70.w, child: Text('ALL', textAlign: TextAlign.center, style: _h())),
                      SizedBox(width: 44.w, child: Text('', style: _h())),
                    ])),
                // Rows first, then the leftover space carries the "no more fee
                // types" prompt -- a SliverFillRemaining rather than a Column, so
                // a long list still scrolls and simply pushes the prompt out of
                // view instead of squashing it.
                Expanded(
                    child: FocusTraversalGroup(
                        child: CustomScrollView(slivers: [
                  SliverList.separated(
                      itemCount: _visibleLines.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (_, i) {
                        final l = _visibleLines[i];
                        return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 5.h),
                            child: Row(children: [
                              Expanded(
                                  flex: 3,
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 10.h),
                                    // EVERY ROW IS EDITABLE NOW, saved ones included. A saved
                                    // row used to be plain text, so correcting a fee type meant
                                    // deleting the line and adding it back. Save already
                                    // replaces every row for the selection, so changing one in
                                    // place persists correctly.
                                    child: // TYPE TO FIND IT. The plain DropdownButton listed
                                        // every fee type in the institution alphabetically --
                                        // over a hundred of them -- so picking BOOK FEES meant
                                        // scrolling past A.U.SPORTS FEE, ADMISSION & TRANSFER,
                                        // ALUMNI ASSOCIATION and the rest with no way to jump.
                                        //
                                        // Keyed on the group filter so the field rebuilds when
                                        // the filter changes; without the key the Autocomplete
                                        // keeps its old option list until it is next focused.
                                        Autocomplete<String>(
                                      key: ValueKey('ft-${l.uid}-${_fgFilter ?? 'all'}'),
                                      initialValue: TextEditingValue(text: l.feeType ?? ''),
                                      optionsBuilder: (v) {
                                        // A saved row's fee type is locked (school, Edit).
                                        if (isSchool && l.saved) return const Iterable<String>.empty();
                                        final q = v.text.trim().toLowerCase();
                                        // Fee types already on another row for the same
                                        // students are not offered again.
                                        final pool = _pickableFeeTypes.where((e) => e == l.feeType || !_dupFee(l, e));
                                        // Empty box shows everything, so tapping it still
                                        // behaves like the dropdown it replaced.
                                        if (q.isEmpty) return pool;
                                        // `contains`, not `startsWith`: the useful word is
                                        // rarely the first one ("DUPLICATE ID CARD" is
                                        // found by typing "id").
                                        return pool.where((e) => e.toLowerCase().contains(q));
                                      },
                                      onSelected: (v) {
                                        if (_dupFee(l, v)) return _dupSnack(v);
                                        setState(() => l.feeType = v);
                                      },
                                      // TYPING ALONE MUST COUNT AS CHOOSING.
                                      //
                                      // Autocomplete only reports through onSelected --
                                      // when an option is TAPPED. Type "MESS FEE" in full
                                      // and press Save and the row looks complete but
                                      // holds no fee type, so _save() skips it and
                                      // answers "Add at least one fee line." The old
                                      // dropdown could not do this: picking always set a
                                      // value. So the text is matched as it is typed, and
                                      // on leaving the field anything that matches
                                      // nothing is put back to the last valid pick --
                                      // the row is never left looking filled but empty.
                                      fieldViewBuilder: (context, ctrl, focus, onSubmit) => Focus(
                                        canRequestFocus: false,
                                        skipTraversal: true,
                                        onFocusChange: (hasFocus) {
                                          if (hasFocus || (isSchool && l.saved)) return;
                                          final m = _matchFeeType(ctrl.text);
                                          if (m != null && _dupFee(l, m)) {
                                            _dupSnack(m);
                                            ctrl.text = l.feeType ?? '';
                                          } else if (m != null) {
                                            if (l.feeType != m) setState(() => l.feeType = m);
                                          } else {
                                            ctrl.text = l.feeType ?? '';
                                          }
                                        },
                                        child: TextField(
                                          controller: ctrl,
                                          focusNode: focus,
                                          readOnly: isSchool && l.saved,
                                          style: AppUI.fieldText(context, filled: true),
                                          decoration: InputDecoration(
                                            isDense: true,
                                            border: InputBorder.none,
                                            hintText: 'Search fee type',
                                            hintStyle: AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight),
                                            suffixIcon: isSchool && l.saved ? _lockedMark() : Icon(Icons.search, size: 16.sp, color: AppColors.textSecondary),
                                            suffixIconConstraints: BoxConstraints(minWidth: 22.w, minHeight: 22.h),
                                          ),
                                          // No setState: only _save() and the blur check
                                          // read feeType, and rebuilding here would close
                                          // the options list on every keystroke.
                                          onChanged: (v) {
                                            final m = _matchFeeType(v);
                                            if (m != null && !_dupFee(l, m)) l.feeType = m;
                                          },
                                          onSubmitted: (v) {
                                            final m = _matchFeeType(v);
                                            if (m != null && _dupFee(l, m)) {
                                              _dupSnack(m);
                                              ctrl.text = l.feeType ?? '';
                                              return;
                                            }
                                            if (m != null) setState(() => l.feeType = m);
                                            onSubmit();
                                          },
                                          onTap: () {
                                            if (isSchool && l.saved) return;
                                            if (ctrl.text.isNotEmpty) ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
                                          },
                                        ),
                                      ),
                                      optionsViewBuilder: (context, onSelected, options) => Align(
                                        alignment: Alignment.topLeft,
                                        child: Material(
                                          elevation: 6,
                                          borderRadius: BorderRadius.circular(12),
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(maxHeight: 320.h, maxWidth: 420.w),
                                            child: ListView.builder(
                                              padding: EdgeInsets.zero,
                                              shrinkWrap: true,
                                              itemCount: options.length,
                                              itemBuilder: (_, k) {
                                                final e = options.elementAt(k);
                                                return InkWell(
                                                  onTap: () => onSelected(e),
                                                  child: Padding(
                                                    padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                                                    child: Text(e, style: AppUI.fieldText(context, filled: true)),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  )),
                              if (isSchool && l.feeType != null && _optional.contains(l.feeType!.trim()))
                                Tooltip(
                                  message: 'Optional fee: kept on this section but not raised for every student. '
                                      'Add it per student in Fee Collection -> Fee Definition.',
                                  child: AppUI.chip('Optional - not raised', AppStatus.warning),
                                ),
                              SizedBox(width: 8.w),
                              SizedBox(
                                  width: 132.w,
                                  child: TextField(
                                      controller: l.amount,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                                      textAlign: TextAlign.right,
            style: AppUI.money.copyWith(color: l.amount.text.trim().isNotEmpty ? AppColors.primary : AppColors.textPrimary),
                                      decoration: _dec('', filled: l.amount.text.trim().isNotEmpty).copyWith(
                                        // The currency sits in the field rather than the column
                                        // heading, so a row still reads as money on its own.
                                        prefixIcon: Padding(
                                          padding: EdgeInsets.only(left: 10.w, right: 6.w),
                                          child: Text('₹', style: AppUI.label.copyWith(color: AppColors.textSecondary)),
                                        ),
                                        prefixIconConstraints: BoxConstraints(minWidth: 0, minHeight: 0),
                                      ),
                                      onChanged: (_) => setState(() {}))),
                              if (isSchool) ...[
                                // Changing who a row is for may not make it repeat another row.
                                SizedBox(width: 120.w, child: _flagDrop(l.nob, _kNobLabels, (v) {
                                  if (_dupFee(l, l.feeType, nob: v)) return _dupSnack(l.feeType!);
                                  setState(() => l.nob = v);
                                })),
                                SizedBox(width: 120.w, child: _flagDrop(l.bgb, _kBgbLabels, (v) {
                                  if (_dupFee(l, l.feeType, bgb: v)) return _dupSnack(l.feeType!);
                                  setState(() => l.bgb = v);
                                })),
                              ] else
                              SizedBox(
                                  width: 70.w,
                                  child: Center(
                                      child: Tooltip(
                                          message: schoolTerm('Tick = raise a demand for every student in the class. Untick = save the amount on the class template only, no student demand.'),
                                          child: ExcludeFocus(
                                              child: Checkbox(
                                                  value: l.applyAll,
                                                  activeColor: AppColors.accent,
                                                  visualDensity: VisualDensity.compact,
                                                  onChanged: (v) => setState(() => l.applyAll = v ?? false)))))),
                              // Delete on every row, saved ones included: Save replaces
                              // the whole selection, so dropping a row here removes it.
                              SizedBox(
                                  width: 44.w,
                                  child: IconButton(
                                    tooltip: AppText.deleteRow,
                                    visualDensity: VisualDensity.compact,
                                    // By identity: `i` indexes the FILTERED view, so
                                    // removeAt(i) would delete a different row whenever a
                                    // group filter is on.
                                    onPressed: () => setState(() {
                                      l.dispose();
                                      _lines.remove(l);
                                    }),
                                    icon: const AppIcon('trash', size: 16, color: AppColors.error),
                                  )),
                            ]));
                      }),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24.h),
                      child: AppUI.empty(
                        title: _lines.isEmpty ? 'No fee types yet' : 'No more fee types',
                        why: schoolTerm('Add a new row to define fee types for this class.'),
                      ),
                    ),
                  ),
                ]))),
                const Divider(height: 1, color: AppColors.divider),
                Padding(
                    padding: EdgeInsets.all(12.w),
                    child: Row(children: [
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _lines.add(_FeeLine()..isCustom = true)),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Row'),
                      ),
                      SizedBox(width: 12.w),
                      // Takes all the free width and wraps to a second line
                      // rather than ending in "…".
                      Expanded(
                          child: Text(isSchool
                                  ? 'Regular fees are raised for the students they apply to ("Both" = everyone). Optional fees are not; add them per student in Fee Collection > Fee Definition.'
                                  : schoolTerm('Tick ALL to raise this fee as a demand for every student — untick to keep it on the class template only'),
                              maxLines: 2, overflow: TextOverflow.ellipsis, style: AppUI.muted)),
                      SizedBox(width: 12.w),
                      // Save writes every row, not just the visible ones, so the
                      // total stays the full one -- and says so while a group filter
                      // is hiding rows that are part of it.
                      Text(_fgFilter == null ? 'Total  ' : 'Total, all groups  ', style: AppUI.label.copyWith(color: AppColors.textSecondary)),
                      Text(_total.toStringAsFixed(2), style: AppUI.money.copyWith(color: AppColors.primary)),
                      SizedBox(width: 16.w),
                      ElevatedButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save, size: 16),
                          label: const Text('Save')),
                    ])),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // Saved Demands panel — currently hidden (not rendered in build); kept so it
  // can be restored if needed.
  // ignore: unused_element
  Widget _existing() {
    final filtered = _cls == null ? _rows : _rows.where((r) => (r['cfclass']?.toString() ?? '') == _cls).toList();
    return _listCard(
      icon: 'category',
      title: 'Saved Demands',
      subtitle: schoolTerm('class-wise fee demands for the academic year'),
      count: filtered.length,
      countLabel: 'items',
      action: _importButton(context, title: schoolTerm('Class Fee Demand'), tabIndex: 7, disabled: _saving, onReturn: _load),
      headerCells: [
        SizedBox(width: 70.w, child: Text('TERM', style: _h())),
        Expanded(flex: 2, child: Text('FEE TYPE', style: _h())),
        SizedBox(width: 70.w, child: Text('AMT', textAlign: TextAlign.right, style: _h())),
        if (!isSchool) Expanded(child: Text('ADM', style: _h())),
        SizedBox(width: 44.w, child: Text('', style: _h())),
      ],
      body: filtered.isEmpty
          ? AppUI.empty(title: 'No fee demands')
          : ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (_, i) {
                final r = filtered[i];
                final id = r['cf_id'] is int ? r['cf_id'] as int : int.tryParse(r['cf_id'].toString()) ?? 0;
                return Container(
                  color: i.isEven ? Colors.white : AppColors.surface,
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  child: Row(children: [
                    SizedBox(width: 70.w, child: Text(r['cfterm']?.toString() ?? '', style: _c())),
                    Expanded(flex: 2, child: Text(r['cffeetype']?.toString() ?? '', style: _c())),
                    SizedBox(width: 70.w, child: Text(r['cfamount']?.toString() ?? '', textAlign: TextAlign.right, style: AppUI.money)),
                    if (!isSchool) Expanded(child: Text(_admName['${r['admissiontype'] ?? ''}'] ?? 'All', style: _c())),
                    SizedBox(
                        width: 44.w,
                        child: Center(child: InkWell(onTap: () => _delete(id), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 15, color: AppColors.error))))),
                  ]),
                );
              },
            ),
    );
  }
}

// ── Demand No sequence ─────────────────────────────────────────────────────
/// Single institution-wide demand-number (demno) sequence, stored in the shared
/// `sequence` table with actname='DEMNO', fg_id NULL. Once configured, new fee
/// demands emit <prefix><padded seqcurno+1> (e.g. DM00001) instead of the
/// default DExx/NNNNN — see migrations/add_demno_sequence.sql (the set_dem_id /
/// set_temp_id triggers read this row).
class _DemandSequencePanel extends StatefulWidget {
  const _DemandSequencePanel({this.actname = 'DEMNO', this.defaultPrefix = 'DM', this.title = 'Demand No.', this.withArrear = false});
  // actname distinguishes the demand (DEMNO), concession (CONNO), refund
  // (REFNO) and advance (ADVNO) single-sequence rows in the shared
  // `sequence` table.
  final String actname;
  final String defaultPrefix;
  final String title;
  /// Concession No only: on the school database the arrear concession series
  /// (ARRCONNO, AC26/0001) is managed in the same frame -- pick its row on the
  /// right to edit it in the form.
  final bool withArrear;
  @override
  State<_DemandSequencePanel> createState() => _DemandSequencePanelState();
}

class _DemandSequencePanelState extends State<_DemandSequencePanel> with AutomaticKeepAliveClientMixin {
  bool _loading = true, _saving = false;
  Map<String, dynamic>? _seq; // the series being edited
  final Map<String, Map<String, dynamic>?> _rows = {}; // actname -> sequence row
  int _active = 0;

  /// (actname, default prefix, title) of every series this frame manages.
  List<(String, String, String)> get _series => [
        (widget.actname, widget.defaultPrefix, widget.title),
        if (widget.withArrear && isSchool) ('ARRCONNO', 'AC', 'Arrear Concession No.'),
      ];
  String get _act => _series[_active].$1;
  String get _title => _series[_active].$3;

  /// Load the chosen series into the form.
  void _select(int i) {
    setState(() {
      _active = i;
      _seq = _rows[_series[i].$1];
      _prefixCtrl.text = _seq?['seqprefix']?.toString() ?? _series[i].$2;
      _widthCtrl.text = ((_seq?['seqwidth'] as num?)?.toInt() ?? 5).toString();
      _startCtrl.text = ((_seq?['seqstart'] as num?)?.toInt() ?? 1).toString();
    });
  }
  final _prefixCtrl = TextEditingController(text: 'DM');
  final _widthCtrl = TextEditingController(text: '5');
  final _startCtrl = TextEditingController(text: '1');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _prefixCtrl.text = widget.defaultPrefix;
    _load();
  }

  @override
  void dispose() {
    _prefixCtrl.dispose();
    _widthCtrl.dispose();
    _startCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      for (final sr in _series) {
        final res = await SupabaseService.fromSchema('sequence').select().eq('ins_id', insId).eq('actname', sr.$1).eq('activestatus', 1).order('seq_id').limit(1).maybeSingle();
        _rows[sr.$1] = res == null ? null : Map<String, dynamic>.from(res);
      }
      if (!mounted) return;
      if (_active >= _series.length) _active = 0;
      _select(_active);
      setState(() => _loading = false);
    } catch (e) {
      debugPrint('DEMNO load: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _width => (int.tryParse(_widthCtrl.text.trim()) ?? 5).clamp(1, 9);
  int get _start => int.tryParse(_startCtrl.text.trim()) ?? 1;
  String get _preview => '${_prefixCtrl.text.trim().toUpperCase()}${_start.toString().padLeft(_width, '0')}';

  Future<void> _save() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    var prefix = _prefixCtrl.text.trim().toUpperCase();
    if (prefix.isEmpty) {
      _snack(context, 'Enter a prefix.', AppColors.warning);
      return;
    }
    if (prefix.length > 15) prefix = prefix.substring(0, 15);
    final width = _width;
    final start = _start.clamp(1, 999999999);
    setState(() => _saving = true);
    try {
      final sequid0 = '$prefix${start.toString().padLeft(width, '0')}';
      final sequid = sequid0.length > 18 ? sequid0.substring(0, 18) : sequid0;
      // Only ever ONE demand sequence per institution: reuse the existing row
      // if there is one (even if it wasn't loaded into state), else insert.
      int? seqId = (_seq?['seq_id'] as num?)?.toInt();
      if (seqId == null) {
        final existing = await SupabaseService.fromSchema('sequence').select('seq_id').eq('ins_id', insId).eq('actname', _act).eq('activestatus', 1).order('seq_id').limit(1).maybeSingle();
        seqId = (existing?['seq_id'] as num?)?.toInt();
      }
      if (seqId != null) {
        await SupabaseService.saveSchemaRow(
            'sequence',
            {
              'seqprefix': prefix,
              'seqname': prefix,
              'seqwidth': width,
              'seqstart': start,
              'sequid': sequid,
            },
            pkCol: 'seq_id',
            pkVal: seqId);
      } else {
        final year = await _currentYear(insId);
        await SupabaseService.saveSchemaRow('sequence', {
          'ins_id': insId,
          'mod_id': 0,
          'yr_id': year?['yr_id'] ?? 0,
          'yrlabel': year?['yrlabel']?.toString() ?? '',
          'actname': _act,
          'seqname': prefix,
          'isprefix': 'Y',
          'seqprefix': prefix,
          'seqstart': start,
          'seqwidth': width,
          'sequid': sequid,
          'seqcurno': start - 1, // first demand number == start
          'fg_id': null,
        });
      }
      if (mounted) {
        _snack(context, '$_title sequence saved.', AppColors.success);
        _load();
      }
    } catch (e) {
      if (mounted) _snack(context, 'Could not save the sequence. ${friendlyError(e)}', AppColors.error);
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return SequenceUI.layout(form: _form(), list: _info());
  }

  /// The form card every sequence screen shares (SequenceUI).
  Widget _form() {
    final exists = _seq != null;
    return SequenceUI.formCard(
      title: '$_title Sequence',
      subtitle: 'One $_title sequence for the whole institution',
      preview: _prefixCtrl.text.trim().isEmpty ? null : _preview,
      button: SequenceUI.saveButton(saving: _saving, editing: exists, onPressed: _save),
      fields: [
            // Concession No. (school): pick Regular or Arrear Concession --
            // the same as clicking its row on the right (user, 2026-11-13).
            if (_series.length > 1) ...[
              _lbl('Concession Type'),
              SizedBox(height: 6.h),
              AppDropdownField<int>(
                key: ValueKey('contype-$_active'),
                initialValue: _active,
                isExpanded: true,
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                style: _fieldTextStyle(context),
                icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                decoration: _filledFieldDec(context, 'Select concession type', filled: true),
                items: [
                  for (var i = 0; i < _series.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(_series[i].$1 == 'ARRCONNO' ? 'Arrear Concession' : 'Regular Concession',
                          style: AppUI.fieldText(context)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null && v != _active) _select(v);
                },
              ),
              SizedBox(height: 16.h),
            ],
            _lbl('Prefix *'),
            SizedBox(height: 6.h),
            TextField(
              controller: _prefixCtrl,
              textCapitalization: TextCapitalization.characters,
              style: AppUI.fieldText(context, filled: _prefixCtrl.text.trim().isNotEmpty),
              decoration: _filledFieldDec(context, 'e.g. ${widget.defaultPrefix}', filled: _prefixCtrl.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: 16.h),
            _lbl('Number of Digits'),
            SizedBox(height: 6.h),
            TextField(
              controller: _widthCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: AppUI.fieldText(context, filled: _widthCtrl.text.trim().isNotEmpty),
              decoration: _filledFieldDec(context, 'e.g. 5', filled: _widthCtrl.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: 16.h),
            _lbl(exists ? 'Start Number (Locked)' : 'Start Number'),
            SizedBox(height: 6.h),
            TextField(
              controller: _startCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              enabled: !exists, // the start is locked once the counter is running
              style: AppUI.fieldText(context, filled: _startCtrl.text.trim().isNotEmpty),
              decoration: _filledFieldDec(context, 'e.g. 1', filled: _startCtrl.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
            ),
      ],
    );
  }

  /// The list every sequence screen shares (SequenceUI). Edit loads the
  /// series into the form (Concession: also its Arrear Concession series).
  Widget _info() {
    final multi = _series.length > 1;
    return SequenceUI.listCard(
      title: multi ? 'Concession Sequences' : '${widget.title} Sequences',
      loading: false,
      count: _series.where((sr) => _rows[sr.$1] != null).length,
      emptyTitle: 'No ${widget.title} sequence set up yet',
      emptyWhy: 'Set a prefix and starting number on the left and save.',
      hint: multi ? 'Click a row to edit it' : null,
      rows: [
        for (var i = 0; i < _series.length; i++)
          if (multi || _rows[_series[i].$1] != null) _seqRow(i, multi),
      ],
    );
  }

  Future<void> _deleteSeries(int i) async {
    final s = _rows[_series[i].$1];
    if (s == null) return;
    if (!await SequenceUI.confirmDelete(context,
        name: _series[i].$3,
        current: (s['seqcurno'] as num?)?.toInt() ?? 0,
        start: (s['seqstart'] as num?)?.toInt() ?? 1)) {
      return;
    }
    try {
      await SupabaseService.deleteSchemaRow('sequence', 'seq_id', (s['seq_id'] as num).toInt());
      if (mounted) _snack(context, '${_series[i].$3} sequence deleted.', AppColors.success);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Could not delete the sequence. ${friendlyError(e)}', AppColors.error);
    }
  }

  SeqRow _seqRow(int i, bool multi) {
    final sr = _series[i];
    final s = _rows[sr.$1];
    final prefix = s?['seqprefix']?.toString() ?? '';
    final width = (s?['seqwidth'] as num?)?.toInt() ?? 5;
    final start = (s?['seqstart'] as num?)?.toInt() ?? 1;
    final cur = (s?['seqcurno'] as num?)?.toInt() ?? 0;
    return SeqRow(
      name: sr.$3,
      prefix: prefix,
      next: s == null ? null : SequenceUI.nextNumber(affix: prefix, current: cur, start: start, width: width),
      lastIssued: s == null ? '—' : SequenceUI.lastIssued(current: cur, start: start),
      selected: multi && i == _active,
      onEdit: () => _select(i),
      onDelete: s == null ? null : () => _deleteSeries(i),
    );
  }
}
