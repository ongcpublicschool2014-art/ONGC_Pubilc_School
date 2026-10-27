import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../services/tc_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/tc_fields.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';

/// TC -> TC Certificate (old PsTc "TC Issue", dba.TransMaster): the details
/// printed on each TC'd student's certificate. Opening a student fills every
/// field it can from the student / admission / TC entry; the rest are typed.
/// Saving stores the whole set, so an approved certificate prints exactly
/// what was approved. Approved = read-only (cancel the approval to edit).
class TcCertificateScreen extends StatefulWidget {
  const TcCertificateScreen({super.key});
  @override
  State<TcCertificateScreen> createState() => _TcCertificateScreenState();
}

class _TcCertificateScreenState extends State<TcCertificateScreen> {
  bool _loading = true, _saving = false;
  List<Map<String, dynamic>> _items = [];
  List<String> _templateKeys = []; // placeholders in the uploaded format
  String _schoolName = '', _schoolAddress = '';
  final _search = TextEditingController();
  String _filter = 'ALL'; // ALL | NEW | DRAFT | APPROVED
  Map<String, dynamic>? _sel;
  final _serial = TextEditingController();
  final Map<String, TextEditingController> _ctl = {};

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  String get _year => context.read<AuthProvider>().yearLabel ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _serial.dispose();
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _load({int? keepStu}) async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait<dynamic>([
        TcService.list(),
        TcService.format(),
        SupabaseService.getInstitutionInfo(_insId),
      ]);
      if (!mounted) return;
      final info = r[2] as ({String? name, String? logo, String? address, String? mobile, String? email});
      setState(() {
        _items = r[0] as List<Map<String, dynamic>>;
        final f = r[1] as Map<String, dynamic>?;
        _templateKeys = [for (final x in (f?['placeholders'] as List? ?? const [])) '$x'];
        _schoolName = info.name ?? '';
        _schoolAddress = (info.address ?? '').replaceAll('\n', ', ');
        _loading = false;
      });
      if (keepStu != null) {
        final m = _items.where((i) => i['stu_id'] == keepStu);
        if (m.isNotEmpty) _open(m.first);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Could not load. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  String _status(Map<String, dynamic> i) {
    final c = i['cert'] as Map?;
    if (c == null) return 'NEW';
    return (c['approval'] as num?)?.toInt() == 1 ? 'APPROVED' : 'DRAFT';
  }

  List<Map<String, dynamic>> get _visible {
    final q = _search.text.trim().toLowerCase();
    return _items.where((i) {
      if (_filter != 'ALL' && _status(i) != _filter) return false;
      if (q.isEmpty) return true;
      return '${i['stuname']} ${i['stuadmno']} ${i['stuclass']}'.toLowerCase().contains(q);
    }).toList();
  }

  /// The extra fields the school's format has that are not in the standard list.
  List<String> get _extraKeys => [
        for (final k in _templateKeys)
          if (!kTcFieldKeys.contains(k) && !kTcPrintTimeKeys.contains(k)) k
      ];

  bool get _locked => _sel != null && _status(_sel!) == 'APPROVED';

  TextEditingController _c(String k) => _ctl.putIfAbsent(k, () => TextEditingController());

  void _open(Map<String, dynamic> i) {
    final auto = TcService.autoValues(i, schoolName: _schoolName, schoolAddress: _schoolAddress, yearLabel: _year);
    final cert = i['cert'] as Map?;
    final saved = Map<String, dynamic>.from((cert?['fields'] as Map?) ?? const {});
    // a new certificate starts the district fields from the last saved one
    if (cert == null) {
      for (final k in kTcCarryKeys) {
        for (final o in _items) {
          final v = '${((o['cert'] as Map?)?['fields'] as Map?)?[k] ?? ''}'.trim();
          if (v.isNotEmpty) {
            auto[k] = v;
            break;
          }
        }
      }
    }
    setState(() {
      _sel = i;
      _serial.text = '${cert?['tcserial'] ?? (i['tc'] as Map?)?['tcno'] ?? ''}';
      for (final k in [...kTcFieldKeys, ..._extraKeys]) {
        _c(k).text = saved.containsKey(k) ? '${saved[k] ?? ''}' : (auto[k] ?? '');
      }
    });
  }

  /// Refill the auto fields from the current student / admission data.
  void _refill() {
    if (_sel == null) return;
    final auto = TcService.autoValues(_sel!, schoolName: _schoolName, schoolAddress: _schoolAddress, yearLabel: _year);
    setState(() {
      for (final f in kTcFields) {
        if (f.auto != null) _c(f.key).text = auto[f.key] ?? '';
      }
    });
    _snack('Filled again from the student and admission records -- Save to keep.', AppColors.info);
  }

  Future<void> _save() async {
    final i = _sel;
    if (i == null) return;
    setState(() => _saving = true);
    try {
      final fields = {
        for (final k in [...kTcFieldKeys, ..._extraKeys]) k: _c(k).text.trim()
      };
      fields['TC No'] = _serial.text.trim();
      await TcService.save((i['stu_id'] as num).toInt(), _serial.text.trim(), fields);
      _snack('TC certificate saved for ${i['stuname']}. It now waits for approval.', AppColors.success);
      await _load(keepStu: i['stu_id'] as int?);
    } catch (e) {
      _snack('Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cancelCert() async {
    final c = _sel?['cert'] as Map?;
    if (c == null) return;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this TC certificate?'),
        content: SizedBox(
          width: 380,
          child: TextField(controller: reason, decoration: AppUI.field(ctx, 'Reason (optional)')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.danger(ctx), child: const Text('Cancel certificate')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await TcService.cancel((c['tcc_id'] as num).toInt(), reason.text);
      _snack('Certificate cancelled.', AppColors.success);
      await _load(keepStu: _sel?['stu_id'] as int?);
    } catch (e) {
      _snack('Could not cancel. ${friendlyError(e)}', AppColors.error);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────
  Widget _statusChip(String s) => switch (s) {
        'APPROVED' => AppUI.chip('Approved', AppStatus.success),
        'DRAFT' => AppUI.chip('Awaiting approval', AppStatus.warning),
        _ => AppUI.chip('Not started', AppStatus.neutral),
      };

  @override
  Widget build(BuildContext context) {
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    final rows = _visible;
    return AppMasterDetail(
      listTitle: 'TC Certificates',
      listIcon: 'document-text',
      listSubtitle: 'Students with a TC issued',
      listActions: [
        IconButton(tooltip: 'Refresh', onPressed: _loading ? null : () => _load(keepStu: _sel?['stu_id'] as int?), icon: const Icon(Icons.refresh)),
      ],
      search: AppSearchField(controller: _search, hintText: 'Search name / adm no / section', onChanged: (_) => setState(() {})),
      filters: [
        Wrap(spacing: 8.w, runSpacing: 6.h, children: [
          for (final f in const [('ALL', 'All'), ('NEW', 'Not started'), ('DRAFT', 'Awaiting approval'), ('APPROVED', 'Approved')])
            ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
        ]),
      ],
      list: rows.isEmpty
          ? AppUI.empty(
              title: _items.isEmpty ? 'No TC issued yet' : 'Nothing matches',
              why: _items.isEmpty ? 'Issue the TC first in TC -> Transfer Certificate; the student then appears here.' : 'Change the search or filter.',
              icon: 'document-text')
          : ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, k) {
                final i = rows[k];
                final on = _sel?['stu_id'] == i['stu_id'];
                return InkWell(
                  onTap: () => _open(i),
                  child: Container(
                    color: on ? AppColors.primaryLight : null,
                    padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                    child: Row(children: [
                      StudentAvatar(photoUrl: '${i['stuphoto'] ?? ''}', name: '${i['stuname'] ?? ''}', size: 36, enlargeOnTap: false),
                      SizedBox(width: 10.w),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${i['stuname'] ?? ''}', style: AppUI.label.copyWith(color: on ? AppColors.primary : null), overflow: TextOverflow.ellipsis),
                          Text('${i['stuadmno'] ?? ''} · ${i['stuclass'] ?? ''} · ${(i['tc'] as Map?)?['statustype'] ?? ''}',
                              style: AppUI.muted, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                      _statusChip(_status(i)),
                    ]),
                  ),
                );
              },
            ),
      footer: Text(AppUI.showing(rows.isEmpty ? 0 : 1, rows.length, rows.length), style: AppUI.muted),
      detail: _sel == null ? null : _detail(),
      emptyDetail: AppUI.empty(title: 'Select a student', why: 'Pick a TC-issued student on the left to fill their certificate.', icon: 'document-text'),
      showDetail: _sel != null,
      onBack: () => setState(() => _sel = null),
    );
  }

  /// Course of study: one row per school (row 1 = this school, row 2 = the
  /// previous school from the admission), as on the state-board TC.
  Widget _studyGrid() {
    Widget cell(Widget child, int flex) => Expanded(flex: flex, child: Padding(padding: EdgeInsets.only(right: 8.w), child: child));
    const flex = [5, 3, 3, 3, 3];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        SizedBox(width: 28.w),
        for (var c = 0; c < kTcStudyCols.length; c++) cell(Text(kTcStudyCols[c].$2, style: AppUI.tableHead), flex[c]),
      ]),
      SizedBox(height: 6.h),
      for (var n = 1; n <= kTcStudyRows; n++)
        Padding(
          padding: EdgeInsets.only(bottom: 8.h),
          child: Row(children: [
            SizedBox(width: 28.w, child: Text('$n', style: AppUI.muted)),
            for (var c = 0; c < kTcStudyCols.length; c++)
              cell(
                TextField(
                  controller: _c('Study $n ${kTcStudyCols[c].$1}'),
                  style: AppUI.fieldText(context, filled: _c('Study $n ${kTcStudyCols[c].$1}').text.isNotEmpty),
                  decoration: AppUI.field(context, '', dense: true),
                  onChanged: (_) => setState(() {}),
                ),
                flex[c],
              ),
          ]),
        ),
    ]);
  }

  Widget _detail() {
    final i = _sel!;
    final cert = i['cert'] as Map?;
    final groups = <String, List<String>>{};
    for (final f in kTcFields) {
      if (f.key == 'TC No') continue; // the serial field above
      groups.putIfAbsent(f.group, () => []).add(f.key);
    }
    if (_extraKeys.isNotEmpty) groups['From your TC format'] = _extraKeys;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.all(AppUI.cardPad),
        child: Row(children: [
          StudentAvatar(photoUrl: '${i['stuphoto'] ?? ''}', name: '${i['stuname'] ?? ''}', size: 52),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i['stuname'] ?? ''}', style: AppUI.cardTitle),
              Text('${i['stuadmno'] ?? ''} · ${i['stuclass'] ?? ''} · TC ${(i['tc'] as Map?)?['tcno'] ?? ''} on ${tcDate((i['tc'] as Map?)?['tcdate'])}',
                  style: AppUI.muted),
            ]),
          ),
          _statusChip(_status(i)),
        ]),
      ),
      if (_locked)
        Container(
          margin: EdgeInsets.symmetric(horizontal: AppUI.cardPad),
          padding: EdgeInsets.all(12.w),
          decoration: BoxDecoration(color: AppColors.successBg, borderRadius: BorderRadius.circular(AppUI.controlRadius)),
          child: Text('Approved by ${cert?['approvedby'] ?? ''} on ${tcDate(cert?['approveddate'])}. Read-only -- cancel the approval in TC Approval to edit.',
              style: AppUI.label.copyWith(color: AppColors.success)),
        ),
      if (_templateKeys.isEmpty)
        Container(
          margin: EdgeInsets.fromLTRB(AppUI.cardPad, 8.h, AppUI.cardPad, 0),
          padding: EdgeInsets.all(12.w),
          decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppUI.controlRadius)),
          child: Text('No TC format uploaded yet (TC -> TC Format). You can fill and approve now; printing needs the format.',
              style: AppUI.label.copyWith(color: AppColors.warning)),
        ),
      const Divider(height: 24),
      Expanded(
        child: AbsorbPointer(
          absorbing: _locked,
          child: Opacity(
            opacity: _locked ? 0.8 : 1,
            child: ListView(
              padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 4.h),
              children: [
                AppUI.sectionLabel('TC serial number'),
                SizedBox(
                  width: 320.w,
                  child: TextField(controller: _serial, style: AppUI.fieldText(context, filled: true), decoration: AppUI.field(context, 'TC No', filled: true)),
                ),
                SizedBox(height: 14.h),
                for (final g in groups.entries) ...[
                  AppUI.sectionLabel(g.key),
                  if (g.key == kTcStudyGroup) ...[
                    _studyGrid(),
                    SizedBox(height: 16.h),
                  ] else ...[
                    LayoutBuilder(builder: (context, c) {
                      final cols = c.maxWidth > 900 ? 3 : (c.maxWidth > 560 ? 2 : 1);
                      final w = (c.maxWidth - (cols - 1) * 12.w) / cols;
                      return Wrap(spacing: 12.w, runSpacing: 12.h, children: [
                        for (final k in g.value)
                          SizedBox(
                            width: w,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              AppUI.fieldLabel(k, optional: false),
                              TextField(
                                controller: _c(k),
                                style: AppUI.fieldText(context, filled: _c(k).text.isNotEmpty),
                                decoration: AppUI.field(context, kTcFields.where((f) => f.key == k).map((f) => f.hint).firstOrNull ?? ''),
                                onChanged: (_) => setState(() {}),
                              ),
                            ]),
                          ),
                      ]);
                    }),
                    SizedBox(height: 16.h),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      AppFormFooter(
        note: _locked ? 'Approved certificates are read-only.' : 'Every value here is what the TC prints. Save, then approve in TC Approval.',
        onCancel: () => setState(() => _sel = null),
        cancelLabel: 'Close',
        actions: [
          if (!_locked && cert != null)
            OutlinedButton.icon(
                onPressed: _saving ? null : _cancelCert,
                icon: const Icon(Icons.block, size: 16),
                label: const Text('Cancel certificate'),
                style: AppUI.secondary(context).copyWith(foregroundColor: const WidgetStatePropertyAll(AppColors.error))),
          if (!_locked)
            OutlinedButton.icon(onPressed: _saving ? null : _refill, icon: const Icon(Icons.restart_alt, size: 16), label: const Text('Refill from records')),
          if (!_locked)
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save, size: 16),
              label: Text(cert == null ? 'Save certificate' : 'Save changes'),
            ),
        ],
      ),
    ]);
  }
}
