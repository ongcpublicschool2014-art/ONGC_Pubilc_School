import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/pill_tab.dart';
import '../../utils/friendly_error.dart';

const _termOrder = [
  'I SEMESTER', 'I TERM', 'II SEMESTER', 'II TERM', 'III SEMESTER', 'III TERM',
  'IV SEMESTER', 'V SEMESTER', 'VI SEMESTER',
  'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER',
  'NOVEMBER', 'DECEMBER', 'JANUARY', 'FEBRUARY',
  'MARCH', 'APRIL', 'MAY',
];

int _termIndex(String t) {
  final idx = _termOrder.indexWhere((x) => x.toLowerCase() == t.toLowerCase());
  return idx >= 0 ? idx : _termOrder.length;
}

String _formatDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
String _formatDateCompact(DateTime d) => '${d.day.toString().padLeft(2, '0')}${d.month.toString().padLeft(2, '0')}${d.year}';

String _formatNumber(double v) {
  if (v == 0) return '0';
  final s = v.toStringAsFixed(0);
  final result = StringBuffer();
  int count = 0;
  for (int i = s.length - 1; i >= 0; i--) {
    if (count == 3 || (count > 3 && (count - 3) % 2 == 0)) result.write(',');
    result.write(s[i]);
    count++;
  }
  return result.toString().split('').reversed.join();
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Data
  List<Map<String, dynamic>> _allDemands = [];
  bool _loading = false;
  String? _error;

  // Filters
  List<String> _courses = [];
  List<String> _classes = [];
  List<String> _feeTypes = [];
  String? _selectedCourse;
  String? _selectedClass;
  Set<String> _selectedFeeTypes = <String>{};
  final GlobalKey _feeTypeKey = GlobalKey();

  // Institution info
  String _insName = '';
  String _insAddress = '';
  String _insPhone = '';
  String _insEmail = '';

  // PowerCollege tab state — independent date range so it doesn't override
  // the Daily Collection range when the user navigates between tabs.
  DateTime? _pcFrom;
  DateTime? _pcTo;
  bool _pcExporting = false;
  bool _pcLoading = false;
  List<Map<String, dynamic>> _pcRows = [];

  // Daily collection tab state
  DateTime? _dailyFrom;
  DateTime? _dailyTo;
  bool _dailyLoading = false;
  List<Map<String, dynamic>> _dailyRows = [];
  List<String> _dailyFeeTypes = [];
  final ScrollController _dailyHScroll = ScrollController();
  final ScrollController _stickyHScroll = ScrollController();
  String? _selectedMode; // null = all, 'cash', 'bank'
  String? _selectedPrefix;
  String? _selectedUser; // null = all, else a specific createdby value
  // Lower-cased user names whose desname = 'Accountant' for this institution.
  // The USER chip list in the Filters dialog is narrowed to these names so
  // admins/principals who rarely collect don't clutter the filter.
  Set<String> _accountantNames = {};

  // Student Ledger tab state
  String? _ledgerStuAdmNo;
  bool _ledgerLoading = false;
  List<Map<String, dynamic>> _ledgerDemands = [];
  Map<int, Map<String, dynamic>> _ledgerPayments = {};
  Map<String, dynamic>? _ledgerStudent;
  final TextEditingController _ledgerSearchCtrl = TextEditingController();

  bool _isCashMode(String paymethod) {
    final m = paymethod.toUpperCase();
    return m.contains('CASH') || m.contains('CHEQUE') || m.contains('DD');
  }

  String _prefixOf(String paynumber) {
    final m = RegExp(r'^[A-Za-z]+').firstMatch(paynumber);
    return m?.group(0) ?? '';
  }

  List<String> _dailyPrefixes() {
    final set = <String>{};
    for (final r in _dailyRows) {
      final n = r['paynumber']?.toString() ?? '';
      final p = _prefixOf(n);
      if (p.isNotEmpty) set.add(p);
    }
    final list = set.toList()..sort();
    return list;
  }

  String _paymentBucket(String paymethod) {
    final m = paymethod.toUpperCase();
    if (m.contains('CASH')) return 'cash';
    if (m.contains('CHEQUE') || m.contains('DD')) return 'cheque';
    return 'bank';
  }

  String _dailyFmt(DateTime? d) =>
      d == null ? '-' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _dailyDateMethodLabel() {
    final hasDate = _dailyFrom != null || _dailyTo != null;
    final hasMode = _selectedMode != null;
    if (!hasDate && !hasMode) return 'Date & Mode';
    String datePart;
    if (!hasDate) {
      datePart = 'All Dates';
    } else if (_dailyFrom != null && _dailyTo != null) {
      datePart = '${_dailyFmt(_dailyFrom)} – ${_dailyFmt(_dailyTo)}';
    } else if (_dailyFrom != null) {
      datePart = 'From ${_dailyFmt(_dailyFrom)}';
    } else {
      datePart = 'Until ${_dailyFmt(_dailyTo)}';
    }
    if (hasMode) {
      return '$datePart · ${_selectedMode!.toUpperCase()}';
    }
    return datePart;
  }

  /// Quick-range / custom-range filter dialog for the PowerCollege tab.
  /// Mirrors the Daily Collection dialog so the two reports feel
  /// consistent, but trims the payment-mode and user pickers since the
  /// PowerCollege export is mode-agnostic.
  Future<void> _openPcDateDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        DateTime? from = _pcFrom;
        DateTime? to = _pcTo;
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          String activePreset() {
            if (from == null || to == null) return '';
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            bool sameDay(DateTime a, DateTime b) =>
                a.year == b.year && a.month == b.month && a.day == b.day;
            if (sameDay(from!, today) && sameDay(to!, today)) return 'Today';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 7)))) return '7 Days';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 30)))) return '30 Days';
            if (sameDay(to!, today) && sameDay(from!, DateTime(now.year, now.month, 1))) return 'This Month';
            return '';
          }
          final preset = activePreset();
          Widget presetChip(String label, VoidCallback onTap) {
            final selected = preset == label;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.accent : AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            );
          }

          Widget datePickerBox({required String hint, required DateTime? value, required ValueChanged<DateTime?> onChanged}) {
            return InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (picked != null) onChanged(picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.calendar_today, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Text(value != null ? _dailyFmt(value) : hint,
                        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
                  ],
                ),
              ),
            );
          }

          Widget sectionLabel(String text) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(text, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.3)),
              );

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            title: Row(
              children: [
                Text('Filters', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                  splashRadius: 18,
                  tooltip: 'Close',
                ),
              ],
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  sectionLabel('QUICK RANGE'),
                  Wrap(children: [
                    presetChip('Today', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = DateTime(now.year, now.month, now.day); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('7 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 7)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('30 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 30)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('This Month', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = DateTime(now.year, now.month, 1); to = DateTime(now.year, now.month, now.day); });
                    }),
                  ]),
                  const SizedBox(height: 16),
                  sectionLabel('CUSTOM RANGE'),
                  Row(children: [
                    Expanded(child: datePickerBox(hint: 'From', value: from, onChanged: (d) => setStateDialog(() => from = d))),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('—')),
                    Expanded(child: datePickerBox(hint: 'To', value: to, onChanged: (d) => setStateDialog(() => to = d))),
                  ]),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  if (from != null && to != null) {
                    setState(() {
                      _pcFrom = from;
                      _pcTo = to;
                    });
                    _loadPowerCollege();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Apply'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _openDailyDateMethodDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        DateTime? from = _dailyFrom;
        DateTime? to = _dailyTo;
        String? mode = _selectedMode;
        String? user = _selectedUser;
        // Distinct cashiers in the currently loaded daily rows, narrowed to
        // users whose designation is 'Accountant'. Admins/principals etc
        // don't show here even if they posted a receipt, so the filter stays
        // focused on the intended audit: per-cashier daily collection.
        final users = {
          for (final r in _dailyRows)
            if ((r['createdby']?.toString() ?? '').isNotEmpty &&
                _accountantNames.contains((r['createdby'] as String).trim().toLowerCase()))
              r['createdby'].toString(),
        }.toList()..sort();
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          String activePreset() {
            if (from == null && to == null) return 'All';
            if (from == null || to == null) return '';
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            bool sameDay(DateTime a, DateTime b) =>
                a.year == b.year && a.month == b.month && a.day == b.day;
            if (sameDay(from!, today) && sameDay(to!, today)) return 'Today';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 7)))) return '7 Days';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 30)))) return '30 Days';
            if (sameDay(to!, today) && sameDay(from!, DateTime(now.year, now.month, 1))) return 'This Month';
            return '';
          }
          final preset = activePreset();
          Widget presetChip(String label, VoidCallback onTap) {
            final selected = preset == label;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.accent : AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            );
          }

          Widget datePickerBox({required String hint, required DateTime? value, required ValueChanged<DateTime?> onChanged}) {
            return InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (picked != null) onChanged(picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.calendar_today, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Text(value != null ? _dailyFmt(value) : hint,
                        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
                  ],
                ),
              ),
            );
          }

          Widget modeChip(String label, String? key) {
            final selected = mode == key;
            return Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: InkWell(
                onTap: () => setStateDialog(() => mode = key),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w700,
                      color: selected ? AppColors.accent : AppColors.textPrimary,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            );
          }

          Widget sectionLabel(String text) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(text, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.3)),
              );

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            title: Row(
              children: [
                Text('Filters', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                  splashRadius: 18,
                  tooltip: 'Close',
                ),
              ],
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  sectionLabel('QUICK RANGE'),
                  Wrap(children: [
                    presetChip('Today', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = DateTime(now.year, now.month, now.day); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('7 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 7)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('30 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 30)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('This Month', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = DateTime(now.year, now.month, 1); to = DateTime(now.year, now.month, now.day); });
                    }),
                  ]),
                  const SizedBox(height: 16),
                  sectionLabel('CUSTOM RANGE'),
                  Row(children: [
                    Expanded(child: datePickerBox(hint: 'From', value: from, onChanged: (d) => setStateDialog(() => from = d))),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('—')),
                    Expanded(child: datePickerBox(hint: 'To', value: to, onChanged: (d) => setStateDialog(() => to = d))),
                  ]),
                  const SizedBox(height: 16),
                  sectionLabel('PAYMENT MODE'),
                  Wrap(children: [
                    modeChip('All', null),
                    modeChip('Cash', 'cash'),
                    modeChip('Bank', 'bank'),
                  ]),
                  // USER (accountant) filter — only relevant for the Cash
                  // mode, since cash is the only method the accountant
                  // physically handles. Bank/online payments reconcile via
                  // the payment gateway, not per-user, so the filter would
                  // just split already-unrelated totals.
                  if (mode == 'cash' && users.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    sectionLabel('USER'),
                    Wrap(children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 6),
                        child: InkWell(
                          onTap: () => setStateDialog(() => user = null),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: user == null ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: user == null ? AppColors.accent : AppColors.border),
                            ),
                            child: Text('All',
                                style: TextStyle(
                                  fontSize: 12.sp,
                                  fontWeight: FontWeight.w700,
                                  color: user == null ? AppColors.accent : AppColors.textPrimary,
                                  letterSpacing: 0.3,
                                )),
                          ),
                        ),
                      ),
                      ...users.map((u) {
                        final selected = user == u;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 6),
                          child: InkWell(
                            onTap: () => setStateDialog(() => user = u),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                              ),
                              child: Text(u,
                                  style: TextStyle(
                                    fontSize: 12.sp,
                                    fontWeight: FontWeight.w700,
                                    color: selected ? AppColors.accent : AppColors.textPrimary,
                                    letterSpacing: 0.3,
                                  )),
                            ),
                          ),
                        );
                      }),
                    ]),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setStateDialog(() { from = null; to = null; mode = null; user = null; }),
                child: Text('Clear', style: TextStyle(color: AppColors.textSecondary, fontSize: 13.sp, fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
                onPressed: () {
                  setState(() {
                    _dailyFrom = from;
                    _dailyTo = to;
                    _selectedMode = mode;
                    // User filter only applies under Cash; clear it when
                    // the mode is anything else so non-cash rows aren't
                    // silently filtered out by a stale user selection.
                    _selectedUser = (mode == 'cash') ? user : null;
                  });
                  _loadDailyCollection();
                  Navigator.pop(ctx);
                },
                child: const Text('Apply'),
              ),
            ],
          );
        });
      },
    );
  }

  List<Widget> _dailyModeChips() {
    Widget chip(String label, String? key) {
      final active = _selectedMode == key;
      return Padding(
        padding: EdgeInsets.only(right: 4.w),
        child: InkWell(
          onTap: () => setState(() => _selectedMode = key),
          borderRadius: BorderRadius.circular(6.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
            decoration: BoxDecoration(
              color: active ? AppColors.accent.withValues(alpha: 0.15) : AppColors.surface,
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(color: active ? AppColors.accent : AppColors.border),
            ),
            child: Text(label, style: TextStyle(
              fontSize: 12.sp,
              fontWeight: FontWeight.w600,
              color: active ? AppColors.accent : AppColors.textPrimary,
            )),
          ),
        ),
      );
    }
    return [
      chip('All', null),
      chip('Cash', 'cash'),
      chip('Bank', 'bank'),
    ];
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    final now = DateTime.now();
    _dailyFrom = DateTime(now.year, now.month, 1);
    _dailyTo = DateTime(now.year, now.month, now.day);
    _pcFrom = DateTime(now.year, now.month, 1);
    _pcTo = DateTime(now.year, now.month, now.day);
    // Pre-load the PowerCollege list so the tab isn't blank on first view.
    _loadPowerCollege();
    _loadData();
    _loadDailyCollection();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Fetch fee report data via RPC (single call, no pagination needed)
  Future<List<Map<String, dynamic>>> _fetchFeeDemandsDirectly(int insId) async {
    try {
      final result = await SupabaseService.client.rpc('get_fee_report_data', params: {'p_ins_id': insId});
      if (result != null) return List<Map<String, dynamic>>.from(result as List);
    } catch (e) {
      debugPrint('RPC get_fee_report_data failed, using fallback: $e');
    }
    // Fallback: direct query
    const batchSize = 1000;
    int offset = 0;
    final allResults = <Map<String, dynamic>>[];
    while (true) {
      final batch = await SupabaseService.fromSchema('feedemand')
          .select('fee_id, stu_id, feeamount, conamount, paidamount, fineamount, balancedue, reconbalancedue, paidstatus, stuclass, courname, stuadmno, demfeetype, demfeeterm, activestatus')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .range(offset, offset + batchSize - 1);
      final list = batch as List;
      allResults.addAll(list.cast<Map<String, dynamic>>());
      if (list.length < batchSize) break;
      offset += batchSize;
    }
    // Enrich with student names
    final stuIds = allResults.map((d) => d['stu_id']).where((id) => id != null).toSet().toList();
    final Map<int, String> stuNameMap = {};
    for (int i = 0; i < stuIds.length; i += 200) {
      final chunk = stuIds.sublist(i, (i + 200).clamp(0, stuIds.length));
      final students = await SupabaseService.fromSchema('students').select('stu_id, stuname').inFilter('stu_id', chunk);
      for (final s in students) { stuNameMap[s['stu_id'] as int] = s['stuname']?.toString() ?? ''; }
    }
    for (final d in allResults) { d['stuname'] = stuNameMap[d['stu_id'] as int?] ?? d['stuadmno']?.toString() ?? ''; }
    return allResults;
  }

  Future<void> _loadData() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _fetchFeeDemandsDirectly(insId),
        SupabaseService.getInstitutionInfo(insId),
        SupabaseService.client
            .from('institutionusers')
            .select('usename')
            .eq('ins_id', insId)
            // Case-insensitive "contains" so "Accountant", "Sr. Accountant",
            // "Junior Accountant" all qualify — schools label roles
            // inconsistently and we don't want the filter to silently drop
            // everyone because of capitalisation.
            .ilike('desname', '%accountant%')
            .eq('activestatus', 1),
      ]);
      final demands = results[0] as List<Map<String, dynamic>>;
      final insInfo = results[1] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final accountantRows = results[2] as List;
      final accountantNames = accountantRows
          .map((r) => (r['usename']?.toString() ?? '').trim().toLowerCase())
          .where((n) => n.isNotEmpty)
          .toSet();

      // Extract filters
      final courseSet = <String>{};
      final classSet = <String>{};
      final feeTypeSet = <String>{};
      for (final d in demands) {
        final c = d['courname']?.toString() ?? '';
        final cl = d['stuclass']?.toString() ?? '';
        final ft = d['demfeetype']?.toString() ?? '';
        if (c.isNotEmpty) courseSet.add(c);
        if (cl.isNotEmpty) classSet.add(cl);
        if (ft.isNotEmpty) feeTypeSet.add(ft);
      }

      if (mounted) setState(() {
        _allDemands = demands;
        _courses = courseSet.toList()..sort();
        _classes = classSet.toList()..sort();
        _feeTypes = feeTypeSet.toList()..sort();
        _insName = insInfo.name ?? '';
        _insAddress = insInfo.address?.replaceAll('\n', ', ') ?? '';
        _insPhone = insInfo.mobile ?? '';
        _insEmail = insInfo.email ?? '';
        _accountantNames = accountantNames;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  Future<void> _loadDailyCollection() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null || _dailyFrom == null || _dailyTo == null) return;
    setState(() {
      _dailyLoading = true;
      _dailyRows = [];
      _dailyFeeTypes = [];
    });
    try {
      String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
      final result = await SupabaseService.client.rpc('get_daily_collection_report', params: {
        'p_schema': schema,
        'p_ins_id': insId,
        'p_from': d(_dailyFrom!),
        'p_to': d(_dailyTo!),
      });
      final list = result is List ? List<Map<String, dynamic>>.from(result) : <Map<String, dynamic>>[];

      final feeTypeSet = <String>{};
      final rows = <Map<String, dynamic>>[];
      for (final r in list) {
        final feesJson = r['fees_json'];
        final fees = <String, double>{};
        if (feesJson is Map) {
          feesJson.forEach((k, v) {
            final amt = (v as num?)?.toDouble() ?? 0;
            fees[k.toString()] = amt;
            feeTypeSet.add(k.toString());
          });
        }
        rows.add({
          'paydate': r['paydate']?.toString() ?? '',
          'paynumber': r['paynumber']?.toString() ?? '',
          'stuadmno': r['stuadmno']?.toString() ?? '',
          'stuname': r['stuname']?.toString() ?? '',
          'courname': r['courname']?.toString() ?? '',
          'stuclass': r['stuclass']?.toString() ?? '',
          'total': (r['total'] as num?)?.toDouble() ?? 0,
          'fine': (r['fine'] as num?)?.toDouble() ?? 0,
          'paymethod': r['paymethod']?.toString() ?? '',
          'createdby': r['createdby']?.toString() ?? '',
          'fees': fees,
        });
      }

      if (mounted) {
        setState(() {
          _dailyRows = rows;
          _dailyFeeTypes = feeTypeSet.toList()..sort();
          _dailyLoading = false;
        });
      }
    } catch (e) {
      debugPrint('daily collection load error: $e');
      if (mounted) setState(() => _dailyLoading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredDemands {
    return _allDemands.where((d) {
      if (_selectedCourse != null && d['courname']?.toString() != _selectedCourse) return false;
      if (_selectedClass != null && d['stuclass']?.toString() != _selectedClass) return false;
      if (_selectedFeeTypes.isNotEmpty && !_selectedFeeTypes.contains(d['demfeetype']?.toString())) return false;
      return true;
    }).toList();
  }

  // Get dynamic term columns from actual data
  List<String> _getTermColumns(List<Map<String, dynamic>> demands) {
    final terms = <String>{};
    for (final d in demands) {
      final t = d['demfeeterm']?.toString() ?? '';
      if (t.isNotEmpty) terms.add(t);
    }
    final sorted = terms.toList()..sort((a, b) => _termIndex(a).compareTo(_termIndex(b)));
    return sorted;
  }

  // Build student-wise pivot data with total and remarks
  // showPending=true uses reconbalancedue (reconciled pending), showPending=false uses feeamount (demanded)
  List<Map<String, dynamic>> _buildPivotData(List<Map<String, dynamic>> demands, List<String> terms, {required bool showPending}) {
    final Map<String, Map<String, dynamic>> studentMap = {};
    final Map<String, Set<String>> studentRemarks = {};
    for (final d in demands) {
      final admNo = d['stuadmno']?.toString() ?? '';
      if (admNo.isEmpty) continue;
      final term = d['demfeeterm']?.toString() ?? '';
      final feeType = d['demfeetype']?.toString() ?? '';
      final amount = showPending
          ? (d['reconbalancedue'] as num?)?.toDouble() ?? (d['balancedue'] as num?)?.toDouble() ?? 0
          : (d['feeamount'] as num?)?.toDouble() ?? 0;

      studentMap.putIfAbsent(admNo, () => {
        'stuadmno': admNo,
        'stuname': d['stuname']?.toString() ?? d['stuadmno']?.toString() ?? '',
        'courname': d['courname']?.toString() ?? '',
        'stuclass': d['stuclass']?.toString() ?? '',
      });

      if (term.isNotEmpty) {
        studentMap[admNo]![term] = (studentMap[admNo]![term] as double? ?? 0) + amount;
      }

      // Accumulate fine from the fineamount column
      final fine = (d['fineamount'] as num?)?.toDouble() ?? 0;
      studentMap[admNo]!['_fine'] = ((studentMap[admNo]!['_fine'] as double?) ?? 0) + fine;

      // Collect fee type remarks for pending amounts
      if (amount > 0 && feeType.isNotEmpty) {
        studentRemarks.putIfAbsent(admNo, () => <String>{}).add(feeType);
      }
    }

    // Calculate total and add remarks
    for (final entry in studentMap.entries) {
      double total = 0;
      for (final t in terms) {
        total += (entry.value[t] as double?) ?? 0;
      }
      entry.value['_total'] = total;
      entry.value['_remarks'] = (studentRemarks[entry.key] ?? {}).join(', ');
    }

    final list = studentMap.values.toList();
    list.sort((a, b) => (a['stuadmno'] as String).compareTo(b['stuadmno'] as String));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tabs (pill style)
        ListenableBuilder(
          listenable: _tabController,
          builder: (context, _) {
            final selected = _tabController.index;
            final tabLabels = ['Daily Collection', 'Student Ledger', 'Pending Payment', 'Consolidated Status', 'PowerCollege'];
            final tabIcons = ['calendar-1', 'book-1', 'clock', 'chart-2', 'document-download'];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < tabLabels.length; i++) ...[
                      PillTab(
                        icon: tabIcons[i],
                        label: tabLabels[i],
                        selected: selected == i,
                        onTap: () => _tabController.animateTo(i),
                      ),
                      if (i < tabLabels.length - 1) SizedBox(width: PillTab.gap(context)),
                    ],
                    const SizedBox(width: 16),
                    if (_loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        // Filters (wrapped in one card)
        ListenableBuilder(listenable: _tabController, builder: (_, __) => _buildFilters()),
        // Content (white table area)
        Expanded(
          child: Container(
            decoration: AppCard.decoration(),
            clipBehavior: Clip.antiAlias,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text('Error: $_error'))
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildDailyCollection(),
                          _buildStudentLedger(),
                          _buildPendingPayment(),
                          _buildConsolidatedStatus(),
                          _buildPowerCollege(),
                        ],
                      ),
          ),
        ),
      ],
    );
  }

  // Styled like the "All Methods" dropdown on Fee Collection: white pill,
  // border, just text + chevron (no leading icon), responsive at <=1366.
  /// Multi-select checkbox dropdown for fee types. Same visual shell as
  /// _filterDropdown so it lines up with the other Daily Collection filters.
  /// Empty selection = "All Fee Types".
  Widget _feeTypeMultiSelect({required double width}) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final hPad = compact ? 10.0 : 14.0;
    final radius = compact ? 6.0 : 10.0;
    final textSize = compact ? 11.0 : 13.0;
    final selectedCount = _selectedFeeTypes.length;
    final label = selectedCount == 0
        ? 'All Fee Types'
        : selectedCount == 1
            ? _selectedFeeTypes.first
            : '$selectedCount fee types';
    return SizedBox(
      key: _feeTypeKey,
      width: width,
      height: AppBtn.height(context),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: _openFeeTypePicker,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AppIcon.linear('Chevron Down', size: AppBtn.iconSize(context)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFeeTypePicker() async {
    final renderBox = _feeTypeKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final triggerPos = renderBox.localToGlobal(Offset.zero);
    final triggerSize = renderBox.size;
    final screen = MediaQuery.of(context).size;

    const popupWidth = 280.0;
    const popupMaxHeight = 360.0;
    // Anchor: left-aligned to trigger, just below it. Clamp to screen.
    final left = triggerPos.dx
        .clamp(8.0, (screen.width - popupWidth - 8).clamp(8.0, screen.width));
    final top = (triggerPos.dy + triggerSize.height + 4)
        .clamp(8.0, (screen.height - 100).clamp(8.0, screen.height));

    final tempSelected = Set<String>.from(_selectedFeeTypes);
    final result = await showDialog<Set<String>>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(ctx),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: popupWidth,
            child: StatefulBuilder(builder: (ctx, setLocalState) {
              return Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: popupMaxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text('Select Fee Types',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                            ),
                            InkWell(
                              onTap: () => setLocalState(() => tempSelected
                                ..clear()
                                ..addAll(_feeTypes)),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Select All',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                              ),
                            ),
                            InkWell(
                              onTap: () => setLocalState(tempSelected.clear),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Clear',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: _feeTypes
                              .map((ft) => CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    controlAffinity: ListTileControlAffinity.leading,
                                    value: tempSelected.contains(ft),
                                    title: Text(ft, style: const TextStyle(fontSize: 12)),
                                    onChanged: (v) => setLocalState(() {
                                      if (v == true) {
                                        tempSelected.add(ft);
                                      } else {
                                        tempSelected.remove(ft);
                                      }
                                    }),
                                  ))
                              .toList(),
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(ctx, tempSelected),
                              child: const Text('Apply'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() => _selectedFeeTypes = result);
    }
  }

  Widget _filterDropdown<T>({
    required T value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    required double width,
    Key? key,
  }) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final hPad = compact ? 10.0 : 14.0;
    final radius = compact ? 6.0 : 10.0;
    final textSize = compact ? 11.0 : 13.0;
    return SizedBox(
      width: width,
      height: AppBtn.height(context),
      child: DropdownButtonHideUnderline(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: AppColors.border),
          ),
          child: DropdownButton<T>(
            key: key,
            value: value,
            isExpanded: true,
            hint: Text(hint, style: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            style: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            icon: AppIcon.linear('Chevron Down', size: AppBtn.iconSize(context)),
            isDense: true,
            // Popup styling — rounded, white, soft elevation, no Material 3 tint.
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            menuMaxHeight: 320,
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: AppCard.decoration(),
        child: Row(
          children: [
            // Scrollable filters (left)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // Course filter
          _filterDropdown<String?>(
            value: _selectedCourse,
            hint: 'All Courses',
            width: 160.w,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All Courses')),
              ..._courses.map((c) => DropdownMenuItem(value: c, child: Text(c))),
            ],
            onChanged: (v) => setState(() { _selectedCourse = v; _selectedClass = null; }),
          ),
          SizedBox(width: 12.w),
          // Class filter
          _filterDropdown<String?>(
            key: ValueKey(_selectedCourse),
            value: _selectedClass,
            hint: 'All Classes',
            width: 160.w,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All Classes')),
              ...(_selectedCourse != null
                  ? _classes.where((c) => _allDemands.any((d) => d['courname']?.toString() == _selectedCourse && d['stuclass']?.toString() == c))
                  : _classes
              ).map((c) => DropdownMenuItem(value: c, child: Text(c))),
            ],
            onChanged: (v) => setState(() => _selectedClass = v),
          ),
          if (_tabController.index == 0) ...[
            SizedBox(width: 12.w),
            _feeTypeMultiSelect(width: 200.w),
            SizedBox(width: 12.w),
            Builder(builder: (_) {
              final prefixes = _dailyPrefixes();
              // Stale _selectedPrefix can survive a date change that drops
              // its prefix from the list — guard against the assertion in
              // DropdownButton requiring exactly one matching item.
              final safeValue = (_selectedPrefix != null && prefixes.contains(_selectedPrefix))
                  ? _selectedPrefix
                  : null;
              return _filterDropdown<String?>(
                value: safeValue,
                hint: 'All Prefixes',
                width: 170.w,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('All Prefixes')),
                  ...prefixes.map((p) => DropdownMenuItem(value: p, child: Text(p))),
                ],
                onChanged: (v) => setState(() => _selectedPrefix = v),
              );
            }),
          ],
                  ],
                ),
              ),
            ),
            // Reset (right corner)
            SizedBox(width: 12.w),
            SizedBox(
              height: AppBtn.height(context),
              child: ElevatedButton.icon(
                onPressed: () => setState(() {
                  _selectedCourse = null;
                  _selectedClass = null;
                  _selectedFeeTypes = <String>{};
                  _selectedPrefix = null;
                }),
                icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                label: const Text('Refresh'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Solid-color action button — matches Master Data's Browse / Format / Sample style.
  Widget _miniExportBtn({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return SizedBox(
      height: AppBtn.height(context),
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: AppBtn.iconSize(context)),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════
  // TAB: CONSOLIDATED FEE COLLECTION STATUS
  // ═══════════════════════════════════════════════
  List<Map<String, dynamic>> _consolidatedRows() {
    return _consolidatedRowsCache.where((r) {
      if (_selectedCourse != null && r['course'] != _selectedCourse) return false;
      if (_selectedClass != null && r['class'] != _selectedClass) return false;
      return true;
    }).toList();
  }

  Widget _buildConsolidatedStatus() {
    if (!_pendingMetaLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPendingMeta());
    }
    final rows = _consolidatedRows();
    if (rows.isEmpty) return _emptyState('No data');

    final byClass = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      byClass.putIfAbsent('${r['course']}|${r['class']}', () => []).add(r);
    }

    final headerStyle = TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
    final cellStyle = TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w600);

    return Column(
      // tab-body-open
          children: [
            Container(
              padding: EdgeInsets.fromLTRB(0, 8.h, 0, 8.h),
              child: Row(children: [
                AppIcon('chart-2', size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text('Consolidated Status', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                SizedBox(width: 8.w),
                Text('— ${_formatDate(DateTime.now())}', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                const Spacer(),
                _miniExportBtn(
                  onPressed: () => _exportConsolidatedExcel(rows, byClass),
                  icon: Icons.table_chart_rounded,
                  label: 'Excel',
                  color: const Color(0xFF10B981),
                ),
                SizedBox(width: AppBtn.gap(context)),
                _miniExportBtn(
                  onPressed: () => _exportConsolidatedPdf(rows, byClass),
                  icon: Icons.picture_as_pdf_rounded,
                  label: 'PDF',
                  color: const Color(0xFFEF4444),
                ),
              ]),
            ),
            Expanded(
              child: _stickyTable(
            columnWidths: const [90, 110, 90, 110, 200, 100, 90, 110, 100, 120, 100, 110],
            headers: const ['COURSE', 'CLASS', 'STRENGTH', 'SEMESTER', 'CATEGORY', 'STUD COUNT', 'TYPE', 'DUE', 'CONCESS', 'NET DEMAND', 'PAID', 'BALANCE'],
            rows: [
              for (final r in rows.skip(_consolidatedPage * _tablePageSize).take(_tablePageSize))
                [
                  r['course']?.toString() ?? '',
                  r['class']?.toString() ?? '',
                  '${r['strength'] ?? 0}',
                  r['semester']?.toString() ?? '',
                  r['category']?.toString() ?? '',
                  '${r['stud_count'] ?? 0}',
                  r['type']?.toString() ?? '',
                  _formatNumber((r['due'] as double?) ?? 0),
                  _formatNumber((r['concession'] as double?) ?? 0),
                  _formatNumber((r['net_demand'] as double?) ?? 0),
                  _formatNumber((r['paid'] as double?) ?? 0),
                  _formatNumber((r['balance'] as double?) ?? 0),
                ],
            ],
            footer: [
              'GRAND TOTAL', '', '', '', '', '', '',
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['due'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['concession'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['net_demand'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['paid'] as double))),
              _formatNumber(rows.fold<double>(0, (s, r) => s + (r['balance'] as double))),
            ],
            numericCols: const {7, 8, 9, 10, 11},
            centerCols: const {2, 5},
          ),
        ),
            _pagerBar(
              total: rows.length,
              page: _consolidatedPage,
              onPrev: _consolidatedPage > 0 ? () => setState(() => _consolidatedPage--) : null,
              onNext: (_consolidatedPage + 1) * _tablePageSize < rows.length
                  ? () => setState(() => _consolidatedPage++)
                  : null,
            ),
          ],
    );
  }

  Future<void> _exportConsolidatedExcel(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Consolidated Status'];
      excel.delete('Sheet1');
      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(bold: true, fontSize: 10);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      row++;
      if (_insAddress.isNotEmpty) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
        row++;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('Consolidated Fee Collection Status Report as on ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.TextCellValue('Date: ${_formatDate(DateTime.now())}');
      row += 2;

      const headers = ['Course', 'Class', 'Strength', 'Semester', 'Category', 'Stud Count', 'Type', 'Due', 'Concess', 'Net Demand', 'Paid', 'Balance'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      void writeRow(Map<String, dynamic> r, {bool isTotal = false, String? labelOverride}) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['course']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(labelOverride ?? r['class']?.toString() ?? '');
        if (labelOverride != null) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
        }
        if (!isTotal) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.IntCellValue((r['strength'] as int?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['semester']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(r['category']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.IntCellValue((r['stud_count'] as int?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.TextCellValue(r['type']?.toString() ?? '');
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = xl.DoubleCellValue((r['due'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: row)).value = xl.DoubleCellValue((r['concession'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).value = xl.DoubleCellValue((r['net_demand'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: row)).value = xl.DoubleCellValue((r['paid'] as double?) ?? 0);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 11, rowIndex: row)).value = xl.DoubleCellValue((r['balance'] as double?) ?? 0);
        for (int c = 7; c <= 11; c++) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = isTotal ? totalStyle : numStyle;
        }
        row++;
      }

      for (final entry in byClass.entries) {
        for (final r in entry.value) writeRow(r);
        final cls = entry.value.first;
        writeRow({
          'course': cls['course'],
          'due': entry.value.fold<double>(0, (s, r) => s + (r['due'] as double)),
          'concession': entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double)),
          'net_demand': entry.value.fold<double>(0, (s, r) => s + (r['net_demand'] as double)),
          'paid': entry.value.fold<double>(0, (s, r) => s + (r['paid'] as double)),
          'balance': entry.value.fold<double>(0, (s, r) => s + (r['balance'] as double)),
        }, isTotal: true, labelOverride: 'Class Total');
      }
      writeRow({
        'course': '',
        'due': rows.fold<double>(0, (s, r) => s + (r['due'] as double)),
        'concession': rows.fold<double>(0, (s, r) => s + (r['concession'] as double)),
        'net_demand': rows.fold<double>(0, (s, r) => s + (r['net_demand'] as double)),
        'paid': rows.fold<double>(0, (s, r) => s + (r['paid'] as double)),
        'balance': rows.fold<double>(0, (s, r) => s + (r['balance'] as double)),
      }, isTotal: true, labelOverride: 'GRAND TOTAL');

      for (int c = 0; c < headers.length; c++) sheet.setColumnWidth(c, c <= 1 ? 18 : 13);
      await _saveExcel(excel, 'Consolidated_Status_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  Future<void> _exportConsolidatedPdf(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass) async {
    try {
      final pdf = pw.Document();
      final data = <List<String>>[];
      for (final entry in byClass.entries) {
        for (final r in entry.value) {
          data.add([
            r['course']?.toString() ?? '',
            r['class']?.toString() ?? '',
            '${r['strength'] ?? 0}',
            r['semester']?.toString() ?? '',
            r['category']?.toString() ?? '',
            '${r['stud_count'] ?? 0}',
            r['type']?.toString() ?? '',
            _formatNumber((r['due'] as double?) ?? 0),
            _formatNumber((r['concession'] as double?) ?? 0),
            _formatNumber((r['net_demand'] as double?) ?? 0),
            _formatNumber((r['paid'] as double?) ?? 0),
            _formatNumber((r['balance'] as double?) ?? 0),
          ]);
        }
        data.add([
          entry.value.first['course']?.toString() ?? '', 'Class Total', '', '', '', '', '',
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['due'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['net_demand'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['paid'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['balance'] as double))),
        ]);
      }
      data.add([
        '', 'GRAND TOTAL', '', '', '', '', '',
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['due'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['concession'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['net_demand'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['paid'] as double))),
        _formatNumber(rows.fold<double>(0, (s, r) => s + (r['balance'] as double))),
      ]);
      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('Consolidated Fee Collection Status Report as on ${_formatDate(DateTime.now())}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Date: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.Table.fromTextArray(
            headers: const ['COURSE', 'CLASS', 'STRENGTH', 'SEMESTER', 'CATEGORY', 'STUD COUNT', 'TYPE', 'DUE', 'CONCESS', 'NET DEMAND', 'PAID', 'BALANCE'],
            data: data,
            headerStyle: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 7),
            cellAlignments: {for (int i = 7; i <= 11; i++) i: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      await Printing.sharePdf(bytes: await pdf.save(), filename: 'Consolidated_Status_${_formatDateCompact(DateTime.now())}.pdf');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  // ═══════════════════════════════════════════════
  // TAB: PENDING PAYMENT REPORT (course-class-semester)
  // ═══════════════════════════════════════════════
  bool _pendingMetaLoaded = false;
  static const int _tablePageSize = 50;
  int _pendingPage = 0;
  int _consolidatedPage = 0;
  int _dailyPage = 0;
  List<Map<String, dynamic>> _pendingRowsCache = [];
  List<Map<String, dynamic>> _consolidatedRowsCache = [];

  Future<void> _loadPendingMeta() async {
    if (_pendingMetaLoaded) return;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null) return;
    try {
      final pendingFut = SupabaseService.client.rpc('get_pending_payment_report', params: {
        'p_schema': schema, 'p_ins_id': insId,
      });
      final consoFut = SupabaseService.client.rpc('get_consolidated_status_report', params: {
        'p_schema': schema, 'p_ins_id': insId,
      });
      final results = await Future.wait([pendingFut, consoFut]);
      // RPC returns JSON (RETURNS json). Supabase may decode it as a List,
      // or hand back a JSON-encoded String — handle both.
      List _asList(dynamic v) {
        if (v is List) return v;
        if (v is String && v.isNotEmpty) {
          final decoded = jsonDecode(v);
          return decoded is List ? decoded : <dynamic>[];
        }
        return <dynamic>[];
      }
      debugPrint('Pending RPC result type: ${results[0].runtimeType}');
      debugPrint('Conso   RPC result type: ${results[1].runtimeType}');
      final pendingList = _asList(results[0]);
      final consoList   = _asList(results[1]);
      debugPrint('Pending rows: ${pendingList.length}, Conso rows: ${consoList.length}');
      final pending = pendingList.isNotEmpty
          ? List<Map<String, dynamic>>.from(pendingList).map((r) => {
              'course': r['courname']?.toString() ?? '',
              'class': r['stuclass']?.toString() ?? '',
              'semester': r['semester']?.toString() ?? '',
              'admname': r['admname']?.toString() ?? '',
              'stuadmno': r['stuadmno']?.toString() ?? '',
              'stuname': r['stuname']?.toString() ?? '',
              'pending': (r['pending'] as num?)?.toDouble() ?? 0,
              'concession': (r['concession'] as num?)?.toDouble() ?? 0,
              'quoname': r['quoname']?.toString() ?? '',
              'stumobile': r['stumobile']?.toString() ?? '',
            }).toList()
          : <Map<String, dynamic>>[];
      final conso = consoList.isNotEmpty
          ? List<Map<String, dynamic>>.from(consoList).map((r) => {
              'course': r['courname']?.toString() ?? '',
              'class': r['stuclass']?.toString() ?? '',
              'strength': (r['strength'] as num?)?.toInt() ?? 0,
              'semester': r['semester']?.toString() ?? '',
              'category': r['category']?.toString() ?? 'GENERAL',
              'stud_count': (r['stud_count'] as num?)?.toInt() ?? 0,
              'type': r['type']?.toString() ?? 'Regular',
              'due': (r['due'] as num?)?.toDouble() ?? 0,
              'concession': (r['concession'] as num?)?.toDouble() ?? 0,
              'net_demand': (r['net_demand'] as num?)?.toDouble() ?? 0,
              'paid': (r['paid'] as num?)?.toDouble() ?? 0,
              'balance': (r['balance'] as num?)?.toDouble() ?? 0,
            }).toList()
          : <Map<String, dynamic>>[];
      if (mounted) setState(() {
        _pendingRowsCache = pending;
        _consolidatedRowsCache = conso;
        _pendingMetaLoaded = true;
      });
    } catch (e) {
      debugPrint('pending/consolidated load: $e');
    }
  }

  List<Map<String, dynamic>> _pendingRows() {
    return _pendingRowsCache.where((r) {
      if (_selectedCourse != null && r['course'] != _selectedCourse) return false;
      if (_selectedClass != null && r['class'] != _selectedClass) return false;
      return true;
    }).toList();
  }

  Widget _buildPendingPayment() {
    if (!_pendingMetaLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPendingMeta());
    }
    final rows = _pendingRows();
    if (rows.isEmpty) return _emptyState('No pending dues');

    final byClass = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final key = '${r['course']}|${r['class']}';
      byClass.putIfAbsent(key, () => []).add(r);
    }
    double grandPending = 0, grandConcess = 0;
    for (final r in rows) {
      grandPending += (r['pending'] as double);
      grandConcess += (r['concession'] as double);
    }

    final headerStyle = TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
    final cellStyle = TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w600);

    return Column(
      // tab-body-open
          children: [
            Container(
              padding: EdgeInsets.fromLTRB(0, 8.h, 0, 8.h),
              child: Row(children: [
                AppIcon('clock', size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text('Pending Payment', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                SizedBox(width: 8.w),
                Text('— ${_formatDate(DateTime.now())}', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                const Spacer(),
                _miniExportBtn(
                  onPressed: () => _exportPendingPaymentExcel(rows, byClass, grandPending, grandConcess),
                  icon: Icons.table_chart_rounded,
                  label: 'Excel',
                  color: const Color(0xFF10B981),
                ),
                SizedBox(width: AppBtn.gap(context)),
                _miniExportBtn(
                  onPressed: () => _exportPendingPaymentPdf(rows, byClass, grandPending, grandConcess),
                  icon: Icons.picture_as_pdf_rounded,
                  label: 'PDF',
                  color: const Color(0xFFEF4444),
                ),
              ]),
            ),
            Expanded(
              child: _stickyTable(
                columnWidths: const [90, 90, 100, 140, 90, 170, 110, 100, 90, 110],
                headers: const ['COURSE', 'CLASS', 'SEMESTER', 'ADMN TYPE', 'REG. NO', 'NAME', 'PENDING AMT', 'CON. AMT', 'QUOTA', 'MOBILE NO'],
                rows: [
                  for (final r in rows.skip(_pendingPage * _tablePageSize).take(_tablePageSize))
                    [
                      r['course']?.toString() ?? '',
                      r['class']?.toString() ?? '',
                      r['semester']?.toString() ?? '',
                      r['admname']?.toString() ?? '',
                      r['stuadmno']?.toString() ?? '',
                      r['stuname']?.toString() ?? '',
                      _formatNumber((r['pending'] as double?) ?? 0),
                      _formatNumber((r['concession'] as double?) ?? 0),
                      r['quoname']?.toString() ?? '',
                      r['stumobile']?.toString() ?? '',
                    ],
                ],
                footer: [
                  'G.Tot', '', '', '', '', '',
                  _formatNumber(grandPending),
                  _formatNumber(grandConcess),
                  '', '',
                ],
                numericCols: const {6, 7},
              ),
            ),
            _pagerBar(
              total: rows.length,
              page: _pendingPage,
              onPrev: _pendingPage > 0 ? () => setState(() => _pendingPage--) : null,
              onNext: (_pendingPage + 1) * _tablePageSize < rows.length
                  ? () => setState(() => _pendingPage++)
                  : null,
            ),
          ],
    );
  }

  /// Sticky-header/footer table: shared horizontal scroll, only the body
  /// rows scroll vertically. Used by the Pending Payment report.
  Widget _stickyTable({
    required List<double> columnWidths,
    required List<String> headers,
    required List<List<String>> rows,
    required List<String> footer,
    Set<int> numericCols = const {},
    Set<int> centerCols = const {},
  }) {
    return _StickyTable(
      columnWidths: columnWidths,
      headers: headers,
      rows: rows,
      footer: footer,
      numericCols: numericCols,
      centerCols: centerCols,
    );
  }

  Widget _pagerBar({required int total, required int page, VoidCallback? onPrev, VoidCallback? onNext}) {
    if (total <= _tablePageSize) return const SizedBox.shrink();
    final start = total == 0 ? 0 : page * _tablePageSize + 1;
    final end = ((page + 1) * _tablePageSize).clamp(0, total);
    final pages = ((total + _tablePageSize - 1) ~/ _tablePageSize).clamp(1, 9999);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
      decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.border))),
      child: Row(
        children: [
          Text('$start–$end of $total', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
          const Spacer(),
          IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left_rounded), tooltip: 'Previous'),
          Text('Page ${page + 1} of $pages', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
          IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right_rounded), tooltip: 'Next'),
        ],
      ),
    );
  }

  Future<void> _exportPendingPaymentExcel(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass, double grandPending, double grandConcess) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Pending Payment'];
      excel.delete('Sheet1');
      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(bold: true, fontSize: 10);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      row++;
      if (_insAddress.isNotEmpty) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
        row++;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('PENDING PAYMENT REPORT AS ON ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.TextCellValue('Date: ${_formatDate(DateTime.now())}');
      row += 2;

      const headers = ['Course', 'Class', 'Semester', 'Admn Type', 'Reg. No', 'Name', 'Pending Amount', 'Con. Amount', 'Quota', 'Mobile No'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      for (final entry in byClass.entries) {
        for (final r in entry.value) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['course']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(r['class']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['semester']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['admname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(r['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.TextCellValue(r['stuname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.DoubleCellValue((r['pending'] as double?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).cellStyle = numStyle;
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = xl.DoubleCellValue((r['concession'] as double?) ?? 0);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).cellStyle = numStyle;
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: row)).value = xl.TextCellValue(r['quoname']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).value = xl.TextCellValue(r['stumobile']?.toString() ?? '');
          row++;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('Sub Total');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.DoubleCellValue(entry.value.fold<double>(0, (s, r) => s + (r['pending'] as double)));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).cellStyle = totalStyle;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = xl.DoubleCellValue(entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double)));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).cellStyle = totalStyle;
        row++;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('G.Tot');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.DoubleCellValue(grandPending);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).cellStyle = totalStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = xl.DoubleCellValue(grandConcess);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).cellStyle = totalStyle;

      for (int c = 0; c < headers.length; c++) sheet.setColumnWidth(c, c == 5 ? 22 : (c == 3 ? 18 : 14));

      await _saveExcel(excel, 'Pending_Payment_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  Future<void> _exportPendingPaymentPdf(List<Map<String, dynamic>> rows, Map<String, List<Map<String, dynamic>>> byClass, double grandPending, double grandConcess) async {
    try {
      final pdf = pw.Document();
      final data = <List<String>>[];
      for (final entry in byClass.entries) {
        for (final r in entry.value) {
          data.add([
            r['course']?.toString() ?? '',
            r['class']?.toString() ?? '',
            r['semester']?.toString() ?? '',
            r['admname']?.toString() ?? '',
            r['stuadmno']?.toString() ?? '',
            r['stuname']?.toString() ?? '',
            _formatNumber((r['pending'] as double?) ?? 0),
            _formatNumber((r['concession'] as double?) ?? 0),
            r['quoname']?.toString() ?? '',
            r['stumobile']?.toString() ?? '',
          ]);
        }
        data.add(['', 'Sub Total', '', '', '', '',
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['pending'] as double))),
          _formatNumber(entry.value.fold<double>(0, (s, r) => s + (r['concession'] as double))),
          '', '']);
      }
      data.add(['', 'G.Tot', '', '', '', '', _formatNumber(grandPending), _formatNumber(grandConcess), '', '']);

      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('PENDING PAYMENT REPORT AS ON ${_formatDate(DateTime.now())}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Date: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.Table.fromTextArray(
            headers: const ['COURSE', 'CLASS', 'SEMESTER', 'ADMN TYPE', 'REG. NO', 'NAME', 'PENDING AMT', 'CON. AMT', 'QUOTA', 'MOBILE'],
            data: data,
            headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignments: {6: pw.Alignment.centerRight, 7: pw.Alignment.centerRight},
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      await Printing.sharePdf(bytes: await pdf.save(), filename: 'Pending_Payment_${_formatDateCompact(DateTime.now())}.pdf');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  // ═══════════════════════════════════════════════
  // TAB: STUDENT LEDGER (per-student fee ledger)
  // ═══════════════════════════════════════════════
  List<Map<String, dynamic>> _studentsForLedger() {
    final map = <String, Map<String, dynamic>>{};
    for (final d in _allDemands) {
      final admno = d['stuadmno']?.toString() ?? '';
      if (admno.isEmpty || map.containsKey(admno)) continue;
      final course = d['courname']?.toString() ?? '';
      final cls = d['stuclass']?.toString() ?? '';
      // Respect the All Courses / All Classes dropdowns at the top.
      if (_selectedCourse != null && course != _selectedCourse) continue;
      if (_selectedClass != null && cls != _selectedClass) continue;
      map[admno] = {
        'stuadmno': admno,
        'stuname': d['stuname']?.toString() ?? '',
        'courname': course,
        'stuclass': cls,
      };
    }
    return map.values.toList()
      ..sort((a, b) => (a['stuadmno'] as String).compareTo(b['stuadmno'] as String));
  }

  Future<void> _loadStudentLedger(String admno) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null) return;
    setState(() {
      _ledgerStuAdmNo = admno;
      _ledgerLoading = true;
      _ledgerDemands = [];
      _ledgerPayments = {};
      _ledgerStudent = _studentsForLedger().firstWhere(
        (s) => s['stuadmno'] == admno,
        orElse: () => {'stuadmno': admno},
      );
    });
    try {
      final result = await SupabaseService.client.rpc('get_student_ledger_report', params: {
        'p_schema': schema,
        'p_ins_id': insId,
        'p_stuadmno': admno,
      });
      final list = result is List ? List<Map<String, dynamic>>.from(result) : <Map<String, dynamic>>[];
      // Synthesize a pseudo pay_id keyed by paynumber so the renderer's
      // d['pay_id'] lookup against _ledgerPayments still works.
      final payMap = <int, Map<String, dynamic>>{};
      for (var i = 0; i < list.length; i++) {
        final pn = list[i]['paynumber']?.toString();
        if (pn == null || pn.isEmpty) continue;
        final pid = pn.hashCode;
        list[i]['pay_id'] = pid;
        payMap[pid] = {'paynumber': pn, 'paydate': list[i]['paydate']};
      }
      if (mounted) {
        setState(() {
          _ledgerDemands = list;
          _ledgerPayments = payMap;
          _ledgerLoading = false;
        });
      }
    } catch (e) {
      debugPrint('student ledger error: $e');
      if (mounted) setState(() => _ledgerLoading = false);
    }
  }

  Widget _buildStudentLedger() {
    final students = _studentsForLedger();
    final headerStyle = TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
    final cellStyle = TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w600);

    // Build rows grouped by term (YEARLY / V SEM / VI SEM / Misc)
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final d in _ledgerDemands) {
      final term = (d['demfeeterm']?.toString() ?? 'Misc');
      grouped.putIfAbsent(term, () => []).add(d);
    }

    double totDemand = 0, totConcess = 0, totNetDemand = 0, totCollection = 0, totFine = 0, totBalance = 0;
    for (final d in _ledgerDemands) {
      final demand = (d['feeamount'] as num?)?.toDouble() ?? 0;
      final conc = (d['conamount'] as num?)?.toDouble() ?? 0;
      totDemand += demand;
      totConcess += conc;
      totNetDemand += demand - conc;
      final paid = (d['paidamount'] as num?)?.toDouble() ?? 0;
      final fine = (d['fineamount'] as num?)?.toDouble() ?? 0;
      // Recon-aware: only count collection/fine after the row's payment is
      // reconciled (reconbalancedue drops to 0). Falls back to balancedue.
      final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
          ?? (d['balancedue'] as num?)?.toDouble() ?? demand;
      final isReconciled = reconBal <= 0;
      totCollection += isReconciled ? (paid - fine) : 0;
      totFine += isReconciled ? fine : 0;
      totBalance += reconBal;
    }

    return Column(
      // tab-body-open
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(0, 8.h, 0, 8.h),
          child: Row(
            children: [
              AppIcon('book-1', size: 18, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Student Ledger', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              if (_ledgerLoading) ...[
                SizedBox(width: 12.w),
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
              ],
              const Spacer(),
              SizedBox(
                width: 360.w,
                child: Autocomplete<Map<String, dynamic>>(
                  displayStringForOption: (o) => '${o['stuadmno']} - ${o['stuname']}',
                  optionsBuilder: (value) {
                    final q = value.text.toLowerCase();
                    if (q.isEmpty) return students.take(20);
                    return students.where((s) =>
                        (s['stuadmno'] as String).toLowerCase().contains(q) ||
                        (s['stuname'] as String).toLowerCase().contains(q)).take(20);
                  },
                  onSelected: (s) => _loadStudentLedger(s['stuadmno'] as String),
                  fieldViewBuilder: (ctx, ctrl, focus, onSubmit) {
                    _ledgerSearchCtrl.value = ctrl.value;
                    return Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F2F4),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          const AppIcon.linear('search-normal', size: 16, color: Color(0xFF9CA3AF)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: ctrl,
                              focusNode: focus,
                              style: const TextStyle(fontSize: 13, color: Color(0xFF1F2937)),
                              cursorHeight: 16,
                              decoration: const InputDecoration(
                                hintText: 'Search Student (Adm No / Name)',
                                hintStyle: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                                isCollapsed: true,
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              SizedBox(width: 8.w),
              if (_ledgerStudent != null) ...[
                _miniExportBtn(
                  onPressed: () => setState(() {
                    _ledgerStuAdmNo = null;
                    _ledgerStudent = null;
                    _ledgerDemands = [];
                    _ledgerPayments = {};
                  }),
                  icon: Icons.close_rounded,
                  label: 'Clear',
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: AppBtn.gap(context)),
              ],
              _miniExportBtn(
                onPressed: _ledgerDemands.isEmpty ? () {} : _exportStudentLedgerExcel,
                icon: Icons.table_chart_rounded,
                label: 'Excel',
                color: const Color(0xFF10B981),
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _ledgerDemands.isEmpty ? () {} : _exportStudentLedgerPdf,
                icon: Icons.picture_as_pdf_rounded,
                label: 'PDF',
                color: const Color(0xFFEF4444),
              ),
            ],
          ),
        ),
        if (_ledgerStudent != null && _ledgerDemands.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.all(12.w),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_insName, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700)),
                if (_insAddress.isNotEmpty) Text(_insAddress, style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                SizedBox(height: 6.h),
                Text('STUDENT LEDGER — ${_formatDate(DateTime.now())}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700)),
                SizedBox(height: 8.h),
                Row(children: [
                  Expanded(child: Text('Name: ${_ledgerStudent!['stuname'] ?? ''}', style: TextStyle(fontSize: 13.sp))),
                  Expanded(child: Text('Reg No: ${_ledgerStudent!['stuadmno'] ?? ''}', style: TextStyle(fontSize: 13.sp))),
                ]),
                SizedBox(height: 4.h),
                Row(children: [
                  Expanded(child: Text('Course: ${_ledgerStudent!['courname'] ?? ''}', style: TextStyle(fontSize: 13.sp))),
                  Expanded(child: Text('Class: ${_ledgerStudent!['stuclass'] ?? ''}', style: TextStyle(fontSize: 13.sp))),
                ]),
              ],
            ),
          ),
          Expanded(
            child: _stickyTable(
              columnWidths: const [100, 200, 100, 110, 110, 110, 80, 120, 110, 110],
              headers: const ['DETAILS', 'FEE TYPE', 'DEMAND', 'CONCESS.', 'NET DEMAND', 'COLLECTION', 'FINE', 'DOC. NO', 'DOC. DATE', 'BALANCE'],
              rows: [
                for (final entry in grouped.entries) ...[
                  [entry.key, '', '', '', '', '', '', '', '', ''],
                  ...entry.value.map((d) {
                    final demand = (d['feeamount'] as num?)?.toDouble() ?? 0;
                    final conc = (d['conamount'] as num?)?.toDouble() ?? 0;
                    final net = demand - conc;
                    final paid = (d['paidamount'] as num?)?.toDouble() ?? 0;
                    final fine = (d['fineamount'] as num?)?.toDouble() ?? 0;
                    final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
                        ?? (d['balancedue'] as num?)?.toDouble() ?? demand;
                    final isReconciled = reconBal <= 0;
                    final collection = isReconciled ? (paid - fine) : 0.0;
                    final fineDisplay = isReconciled ? fine : 0.0;
                    final bal = reconBal;
                    final pay = d['pay_id'] != null ? _ledgerPayments[d['pay_id']] : null;
                    // Show DOC.NO / DOC.DATE only after reconciliation —
                    // unreconciled payments don't surface here yet.
                    final docNo = isReconciled ? (pay?['paynumber']?.toString() ?? '') : '';
                    final docDate = isReconciled ? (pay?['paydate']?.toString() ?? '') : '';
                    return [
                      '',
                      d['demfeetype']?.toString() ?? '',
                      demand > 0 ? _formatNumber(demand) : '',
                      conc > 0 ? _formatNumber(conc) : '',
                      net > 0 ? _formatNumber(net) : '',
                      collection > 0 ? _formatNumber(collection) : '',
                      fineDisplay > 0 ? _formatNumber(fineDisplay) : '',
                      docNo,
                      docDate.length >= 10 ? docDate.substring(0, 10) : docDate,
                      bal > 0 ? _formatNumber(bal) : '0',
                    ];
                  }),
                ],
              ],
              footer: [
                'Total', '',
                _formatNumber(totDemand),
                _formatNumber(totConcess),
                _formatNumber(totNetDemand),
                _formatNumber(totCollection),
                _formatNumber(totFine),
                '', '',
                _formatNumber(totBalance),
              ],
              numericCols: const {2, 3, 4, 5, 6, 9},
            ),
          ),
        ] else if (students.isNotEmpty) ...[
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: AppVerticalScrollbar(
                header: Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    child: Row(
                      children: [
                        Expanded(child: Text('ROLL NO', style: headerStyle)),
                        Expanded(child: Text('STUDENT NAME', style: headerStyle)),
                        Expanded(child: Text('COURSE', style: headerStyle)),
                        Expanded(child: Text('CLASS', style: headerStyle)),
                      ],
                    ),
                  ),
                builder: (context, controller) => ListView.separated(
                      controller: controller,
                      itemCount: students.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
                      itemBuilder: (ctx, i) {
                        final s = students[i];
                        return InkWell(
                          onTap: () => _loadStudentLedger(s['stuadmno']),
                          child: Container(
                            color: i.isOdd ? AppColors.surface : Colors.white,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                            child: Row(
                              children: [
                                Expanded(child: Text(s['stuadmno'] ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                                Expanded(child: Text(s['stuname'] ?? '-', style: cellStyle, overflow: TextOverflow.ellipsis)),
                                Expanded(child: Text(s['courname'] ?? '-', style: cellStyle)),
                                Expanded(child: Text(s['stuclass'] ?? '-', style: cellStyle)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                ),
            ),
          ),
        ] else
          Expanded(child: _emptyState('Select course and class, or search a student')),
      ],
    );
  }

  Future<void> _exportStudentLedgerExcel() async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Student Ledger'];
      excel.delete('Sheet1');

      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(bold: true, fontSize: 10);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      row++;
      if (_insAddress.isNotEmpty) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
        row++;
      }
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('STUDENT LEDGER');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.TextCellValue('DATE: ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).cellStyle = boldStyle;
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('Student Name : ${_ledgerStudent?['stuname'] ?? ''}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue('Reg. No : ${_ledgerStudent?['stuadmno'] ?? ''}');
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('Course : ${_ledgerStudent?['courname'] ?? ''}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue('Class : ${_ledgerStudent?['stuclass'] ?? ''}');
      row++;
      row++;

      final headers = ['Details', 'FeeType', 'Demand', 'Concess.', 'Net Demand', 'Collection', 'Fine', 'Doc. No', 'Doc. Date', 'Balance'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final d in _ledgerDemands) {
        final term = (d['demfeeterm']?.toString() ?? 'Misc');
        grouped.putIfAbsent(term, () => []).add(d);
      }

      double totDemand = 0, totConcess = 0, totNetDemand = 0, totCollection = 0, totFine = 0, totBalance = 0;

      for (final entry in grouped.entries) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(entry.key);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
        row++;
        for (final d in entry.value) {
          final demand = (d['feeamount'] as num?)?.toDouble() ?? 0;
          final conc = (d['conamount'] as num?)?.toDouble() ?? 0;
          final net = demand - conc;
          final paid = (d['paidamount'] as num?)?.toDouble() ?? 0;
          final fineRaw = (d['fineamount'] as num?)?.toDouble() ?? 0;
          final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
              ?? (d['balancedue'] as num?)?.toDouble() ?? demand;
          final isReconciled = reconBal <= 0;
          final fine = isReconciled ? fineRaw : 0.0;
          final bal = reconBal;
          final pay = d['pay_id'] != null ? _ledgerPayments[d['pay_id']] : null;
          final collection = isReconciled ? (paid - fineRaw) : 0.0;
          totDemand += demand; totConcess += conc; totNetDemand += net; totCollection += collection; totFine += fine; totBalance += bal;
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(d['demfeetype']?.toString() ?? '');
          if (demand > 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.DoubleCellValue(demand); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).cellStyle = numStyle; }
          if (conc > 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.DoubleCellValue(conc); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).cellStyle = numStyle; }
          if (net > 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.DoubleCellValue(net); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).cellStyle = numStyle; }
          if (collection > 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.DoubleCellValue(collection); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).cellStyle = numStyle; }
          if (fine > 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.DoubleCellValue(fine); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).cellStyle = numStyle; }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = xl.TextCellValue(isReconciled ? (pay?['paynumber']?.toString() ?? '') : '');
          final pd = isReconciled ? (pay?['paydate']?.toString() ?? '') : '';
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: row)).value = xl.TextCellValue(pd.length >= 10 ? pd.substring(0, 10) : pd);
          if (bal > 0) { sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).value = xl.DoubleCellValue(bal); sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).cellStyle = numStyle; }
          row++;
        }
      }

      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('Total');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.DoubleCellValue(totDemand);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).cellStyle = totalStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.DoubleCellValue(totConcess);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).cellStyle = totalStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.DoubleCellValue(totNetDemand);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).cellStyle = totalStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.DoubleCellValue(totCollection);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).cellStyle = totalStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.DoubleCellValue(totFine);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).cellStyle = totalStyle;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).value = xl.DoubleCellValue(totBalance);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row)).cellStyle = totalStyle;

      sheet.setColumnWidth(0, 12);
      sheet.setColumnWidth(1, 22);
      for (int c = 2; c < 10; c++) sheet.setColumnWidth(c, 12);

      await _saveExcel(excel, 'Student_Ledger_${_ledgerStudent?['stuadmno'] ?? ''}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  Future<void> _exportStudentLedgerPdf() async {
    try {
      final pdf = pw.Document();
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final d in _ledgerDemands) {
        grouped.putIfAbsent(d['demfeeterm']?.toString() ?? 'Misc', () => []).add(d);
      }
      double totDemand = 0, totConcess = 0, totNetDemand = 0, totCollection = 0, totFine = 0, totBalance = 0;
      final rows = <List<String>>[];
      for (final entry in grouped.entries) {
        rows.add([entry.key, '', '', '', '', '', '', '', '', '']);
        for (final d in entry.value) {
          final demand = (d['feeamount'] as num?)?.toDouble() ?? 0;
          final conc = (d['conamount'] as num?)?.toDouble() ?? 0;
          final net = demand - conc;
          final paid = (d['paidamount'] as num?)?.toDouble() ?? 0;
          final fineRaw = (d['fineamount'] as num?)?.toDouble() ?? 0;
          final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
              ?? (d['balancedue'] as num?)?.toDouble() ?? demand;
          final isReconciled = reconBal <= 0;
          final fine = isReconciled ? fineRaw : 0.0;
          final bal = reconBal;
          final pay = d['pay_id'] != null ? _ledgerPayments[d['pay_id']] : null;
          final collection = isReconciled ? (paid - fineRaw) : 0.0;
          totDemand += demand; totConcess += conc; totNetDemand += net; totCollection += collection; totFine += fine; totBalance += bal;
          final pd = isReconciled ? (pay?['paydate']?.toString() ?? '') : '';
          rows.add([
            '',
            d['demfeetype']?.toString() ?? '',
            demand > 0 ? _formatNumber(demand) : '',
            conc > 0 ? _formatNumber(conc) : '',
            net > 0 ? _formatNumber(net) : '',
            collection > 0 ? _formatNumber(collection) : '',
            fine > 0 ? _formatNumber(fine) : '',
            isReconciled ? (pay?['paynumber']?.toString() ?? '') : '',
            pd.length >= 10 ? pd.substring(0, 10) : pd,
            bal > 0 ? _formatNumber(bal) : '0',
          ]);
        }
      }
      rows.add(['Total', '', _formatNumber(totDemand), _formatNumber(totConcess), _formatNumber(totNetDemand), _formatNumber(totCollection), _formatNumber(totFine), '', '', _formatNumber(totBalance)]);

      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('STUDENT LEDGER', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('DATE: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 4),
            pw.Text('Student Name: ${_ledgerStudent?['stuname'] ?? ''}    Reg. No: ${_ledgerStudent?['stuadmno'] ?? ''}', style: const pw.TextStyle(fontSize: 9)),
            pw.Text('Course: ${_ledgerStudent?['courname'] ?? ''}    Class: ${_ledgerStudent?['stuclass'] ?? ''}', style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (ctx) => [
          pw.Table.fromTextArray(
            headers: ['Details', 'FeeType', 'Demand', 'Concess.', 'Net Demand', 'Collection', 'Fine', 'Doc. No', 'Doc. Date', 'Balance'],
            data: rows,
            headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignments: {for (int i = 2; i < 7; i++) i: pw.Alignment.centerRight, 9: pw.Alignment.centerRight},
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
          ),
        ],
      ));
      await Printing.sharePdf(bytes: await pdf.save(), filename: 'Student_Ledger_${_ledgerStudent?['stuadmno'] ?? ''}.pdf');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  // ═══════════════════════════════════════════════
  // TAB: DAILY COLLECTION (receipt-wise pivot by fee type)
  // ═══════════════════════════════════════════════
  Widget _buildDailyCollection() {
    String fmt(DateTime? d) => d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

    Widget quick(String label, VoidCallback onTap) => Padding(
          padding: EdgeInsets.only(left: 4.w),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6.r),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(6.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(label, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ),
          ),
        );

    final headerStyle = TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
    final cellStyle = TextStyle(fontSize: 13.sp, color: AppColors.textPrimary);

    final visibleRows = _dailyRows.where((r) {
      if (_selectedCourse != null && r['courname']?.toString() != _selectedCourse) return false;
      if (_selectedClass != null && r['stuclass']?.toString() != _selectedClass) return false;
      if (_selectedFeeTypes.isNotEmpty) {
        final fees = r['fees'] as Map<String, double>;
        if (!_selectedFeeTypes.any((ft) => (fees[ft] ?? 0) > 0)) return false;
      }
      if (_selectedMode != null) {
        final isCash = _isCashMode(r['paymethod']?.toString() ?? '');
        if (_selectedMode == 'cash' && !isCash) return false;
        if (_selectedMode == 'bank' && isCash) return false;
      }
      if (_selectedPrefix != null) {
        final p = _prefixOf(r['paynumber']?.toString() ?? '');
        if (p != _selectedPrefix) return false;
      }
      if (_selectedUser != null && r['createdby']?.toString() != _selectedUser) return false;
      return true;
    }).toList();

    final visibleFeeTypes = _selectedFeeTypes.isNotEmpty
        ? _dailyFeeTypes.where(_selectedFeeTypes.contains).toList()
        : _dailyFeeTypes;

    // When fee types are selected, narrow the row total down to the sum of
    // just those fees + the row's fine. With no filter, use the full receipt
    // total. CASH/CHEQUE/BANK columns and the footer follow this same total.
    double rowDisplayTotal(Map<String, dynamic> r) {
      final fine = (r['fine'] as num?)?.toDouble() ?? 0;
      if (_selectedFeeTypes.isEmpty) {
        return (r['total'] as num?)?.toDouble() ?? 0;
      }
      final fees = r['fees'] as Map<String, double>;
      double sum = 0;
      for (final ft in _selectedFeeTypes) {
        sum += fees[ft] ?? 0;
      }
      return sum + fine;
    }

    double totalAmt = 0;
    double totalFine = 0;
    final ftTotals = <String, double>{};
    for (final r in visibleRows) {
      totalAmt += rowDisplayTotal(r);
      totalFine += (r['fine'] as num?)?.toDouble() ?? 0;
      final fees = r['fees'] as Map<String, double>;
      for (final ft in visibleFeeTypes) {
        final v = fees[ft] ?? 0;
        ftTotals[ft] = (ftTotals[ft] ?? 0) + v;
      }
    }

    return Column(
      // tab-body-open
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(0, 8.h, 0, 8.h),
          child: Row(
            children: [
              AppIcon('calendar-1', size: 18, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Daily Collection', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              SizedBox(width: 8.w),
              if (_dailyLoading)
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
              const Spacer(),
              SizedBox(
                height: AppBtn.height(context),
                child: OutlinedButton.icon(
                  onPressed: _openDailyDateMethodDialog,
                  icon: Icon(Icons.calendar_today, size: AppBtn.iconSize(context), color: AppColors.textPrimary),
                  label: Text(
                    _dailyDateMethodLabel(),
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: 14.w),
                    side: const BorderSide(color: AppColors.border),
                  ),
                ),
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _dailyRows.isEmpty ? () {} : () => _exportDailyCollectionExcel(),
                icon: Icons.table_chart_rounded,
                label: 'Excel',
                color: const Color(0xFF10B981),
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: _dailyRows.isEmpty ? () {} : () => _exportDailyCollectionPdf(),
                icon: Icons.picture_as_pdf_rounded,
                label: 'PDF',
                color: const Color(0xFFEF4444),
              ),
            ],
          ),
        ),
        Expanded(
          child: visibleRows.isEmpty
              ? _emptyState('No collections in this range')
              : Builder(builder: (_) {
                  final showCash = _selectedMode == null || _selectedMode == 'cash';
                  final showCheque = _selectedMode == null || _selectedMode == 'cash';
                  final showBank = _selectedMode == null || _selectedMode == 'bank';
                  double totalCash = 0;
                  double totalCheque = 0;
                  double totalBank = 0;
                  for (final r in visibleRows) {
                    final total = rowDisplayTotal(r);
                    final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
                    if (bucket == 'cash') {
                      totalCash += total;
                    } else if (bucket == 'cheque') {
                      totalCheque += total;
                    } else {
                      totalBank += total;
                    }
                  }
                  final headers = <String>[
                    'DATE', 'RECEIPT NO', 'REG NO', 'STUDENT NAME', 'COURSE', 'CLASS',
                    ...visibleFeeTypes.map((t) => t.toUpperCase()),
                    'FINE', 'TOTAL',
                    if (showCash) 'CASH',
                    if (showCheque) 'CHEQUE',
                    if (showBank) 'BANK',
                    'NET AMT',
                  ];
                  final widths = <double>[
                    110, 130, 130, 200, 140, 150,
                    ...visibleFeeTypes.map((t) {
                      // Enough width for full uppercase label ("NEW ADMISSION FEES" etc.)
                      final len = t.length;
                      return (len > 14 ? 200.0 : len > 10 ? 170.0 : 140.0);
                    }),
                    100, 130,
                    if (showCash) 120,
                    if (showCheque) 120,
                    if (showBank) 120,
                    130,
                  ];
                  // Numeric (right-aligned) columns start after the 6 text
                  // columns: DATE, RECEIPT NO, REG NO, NAME, COURSE, CLASS.
                  final numericCols = <int>{
                    for (int i = 6; i < headers.length; i++) i,
                  };
                  return _stickyTable(
                    columnWidths: widths,
                    headers: headers,
                    rows: [
                      for (final r in visibleRows.skip(_dailyPage * _tablePageSize).take(_tablePageSize))
                        () {
                          final fees = r['fees'] as Map<String, double>;
                          final fine = (r['fine'] as num?)?.toDouble() ?? 0;
                          final total = rowDisplayTotal(r);
                          final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
                          final pd = DateTime.tryParse(r['paydate']?.toString() ?? '');
                          return <String>[
                            pd != null ? _formatDate(pd) : (r['paydate']?.toString() ?? ''),
                            r['paynumber']?.toString() ?? '',
                            r['stuadmno']?.toString() ?? '',
                            r['stuname']?.toString() ?? '',
                            r['courname']?.toString() ?? '',
                            r['stuclass']?.toString() ?? '',
                            ...visibleFeeTypes.map((ft) => (fees[ft] != null && fees[ft] != 0) ? _formatNumber(fees[ft]!) : ''),
                            fine != 0 ? _formatNumber(fine) : '',
                            _formatNumber(total),
                            if (showCash) (bucket == 'cash' ? _formatNumber(total) : ''),
                            if (showCheque) (bucket == 'cheque' ? _formatNumber(total) : ''),
                            if (showBank) (bucket == 'bank' ? _formatNumber(total) : ''),
                            _formatNumber(total),
                          ];
                        }(),
                    ],
                    footer: <String>[
                      'TOTAL', '', '', '', '', '',
                      ...visibleFeeTypes.map((ft) => _formatNumber(ftTotals[ft] ?? 0)),
                      _formatNumber(totalFine),
                      _formatNumber(totalAmt),
                      if (showCash) _formatNumber(totalCash),
                      if (showCheque) _formatNumber(totalCheque),
                      if (showBank) _formatNumber(totalBank),
                      _formatNumber(totalAmt),
                    ],
                    numericCols: numericCols,
                  );
                }),
        ),
        _pagerBar(
          total: visibleRows.length,
          page: _dailyPage,
          onPrev: _dailyPage > 0 ? () => setState(() => _dailyPage--) : null,
          onNext: (_dailyPage + 1) * _tablePageSize < visibleRows.length
              ? () => setState(() => _dailyPage++)
              : null,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════
  // TAB 1: COLLECTION STATEMENT (fee amounts by term)
  // ═══════════════════════════════════════════════
  Widget _buildCollectionStatement() {
    final demands = _filteredDemands;
    final terms = _getTermColumns(demands);
    final pivotData = _buildPivotData(demands, terms, showPending: true);
    if (pivotData.isEmpty) return _emptyState('No fee data found');

    // Calculate totals per term
    final Map<String, double> termTotals = {};
    for (final row in pivotData) {
      for (final t in terms) {
        termTotals[t] = (termTotals[t] ?? 0) + (row[t] as double? ?? 0);
      }
    }

    return _buildReportTable(
      title: 'PENDING FEE REPORT AS ON ${_formatDate(DateTime.now())}',
      subtitle: 'FEE TYPE : ${_selectedFeeTypes.isEmpty ? 'ALL FEE TYPE' : _selectedFeeTypes.join(', ')}',
      terms: terms,
      pivotData: pivotData,
      termTotals: termTotals,
      showPending: true,
    );
  }

  // ═══════════════════════════════════════════════
  // TAB 2: PENDING - COURSE WISE
  // ═══════════════════════════════════════════════
  Widget _buildPendingCourseWise() {
    final demands = _filteredDemands.where((d) {
      final balance = (d['balancedue'] as num?)?.toDouble() ?? 0;
      return balance > 0;
    }).toList();
    final terms = _getTermColumns(demands);

    // Group by course
    final Map<String, List<Map<String, dynamic>>> courseGroups = {};
    for (final d in demands) {
      final course = d['courname']?.toString() ?? 'Unknown';
      courseGroups.putIfAbsent(course, () => []).add(d);
    }

    if (courseGroups.isEmpty) return _emptyState('No pending fees found');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Export button
          Padding(
            padding: EdgeInsets.all(12.w),
            child: Row(
              children: [
                Text('PENDING FEE REPORT - COURSE WISE',
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _exportPendingReport(demands, terms, 'Course_Wise'),
                  icon: Icon(Icons.download_rounded, size: 16.sp),
                  label: Text('Export Excel', style: TextStyle(fontSize: 13.sp)),
                ),
              ],
            ),
          ),
          ...courseGroups.entries.map((entry) {
            final courseName = entry.key;
            final courseDemands = entry.value;
            final pivotData = _buildPivotData(courseDemands, terms, showPending: true);
            final Map<String, double> termTotals = {};
            for (final row in pivotData) {
              for (final t in terms) {
                termTotals[t] = (termTotals[t] ?? 0) + (row[t] as double? ?? 0);
              }
            }
            final grandTotal = termTotals.values.fold<double>(0, (s, v) => s + v);

            return Container(
              margin: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(10.r)),
                    ),
                    child: Row(
                      children: [
                        Text(courseName, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.accent)),
                        const Spacer(),
                        Text('${pivotData.length} students', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                        SizedBox(width: 16.w),
                        Text('Total Pending: ${_formatNumber(grandTotal)}',
                            style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: Colors.red)),
                      ],
                    ),
                  ),
                  _buildDataTable(terms, pivotData, termTotals),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════
  // TAB 3: PENDING - YEAR WISE
  // ═══════════════════════════════════════════════
  Widget _buildPendingYearWise() {
    final demands = _filteredDemands.where((d) {
      final balance = (d['balancedue'] as num?)?.toDouble() ?? 0;
      return balance > 0;
    }).toList();
    final terms = _getTermColumns(demands);

    // Group by class (year)
    final Map<String, List<Map<String, dynamic>>> classGroups = {};
    for (final d in demands) {
      final cls = d['stuclass']?.toString() ?? 'Unknown';
      classGroups.putIfAbsent(cls, () => []).add(d);
    }

    if (classGroups.isEmpty) return _emptyState('No pending fees found');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(12.w),
            child: Row(
              children: [
                Text('PENDING FEE REPORT - YEAR WISE',
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _exportPendingReport(demands, terms, 'Year_Wise'),
                  icon: Icon(Icons.download_rounded, size: 16.sp),
                  label: Text('Export Excel', style: TextStyle(fontSize: 13.sp)),
                ),
              ],
            ),
          ),
          ...classGroups.entries.map((entry) {
            final className = entry.key;
            final classDemands = entry.value;
            final pivotData = _buildPivotData(classDemands, terms, showPending: true);
            final Map<String, double> termTotals = {};
            for (final row in pivotData) {
              for (final t in terms) {
                termTotals[t] = (termTotals[t] ?? 0) + (row[t] as double? ?? 0);
              }
            }
            final grandTotal = termTotals.values.fold<double>(0, (s, v) => s + v);

            return Container(
              margin: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(10.r)),
                    ),
                    child: Row(
                      children: [
                        Text(className, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.accent)),
                        const Spacer(),
                        Text('${pivotData.length} students', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                        SizedBox(width: 16.w),
                        Text('Total Pending: ${_formatNumber(grandTotal)}',
                            style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: Colors.red)),
                      ],
                    ),
                  ),
                  _buildDataTable(terms, pivotData, termTotals),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════
  // SHARED TABLE BUILDER
  // ═══════════════════════════════════════════════
  Widget _buildReportTable({
    required String title,
    required String subtitle,
    required List<String> terms,
    required List<Map<String, dynamic>> pivotData,
    required Map<String, double> termTotals,
    required bool showPending,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title & export
        Padding(
          padding: EdgeInsets.all(12.w),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  Text(subtitle, style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                ],
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _exportCollectionStatement(pivotData, terms, termTotals),
                icon: Icon(Icons.download_rounded, size: 16.sp),
                label: Text('Export Excel', style: TextStyle(fontSize: 13.sp)),
              ),
            ],
          ),
        ),
        // Totals row
        Container(
          margin: EdgeInsets.symmetric(horizontal: 12.w),
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8.r),
          ),
          child: Row(
            children: [
              Text('${pivotData.length} Students', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
              const Spacer(),
              ...terms.map((t) => Padding(
                padding: EdgeInsets.only(left: 12.w),
                child: Column(
                  children: [
                    Text(t, style: TextStyle(fontSize: 10.sp, color: AppColors.textPrimary)),
                    Text(_formatNumber(termTotals[t] ?? 0),
                        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ],
                ),
              )),
            ],
          ),
        ),
        SizedBox(height: 8.h),
        // Data table
        Expanded(
            child: _buildDataTable(terms, pivotData, termTotals,
                bounded: true)),
      ],
    );
  }

  Widget _buildDataTable(List<String> terms, List<Map<String, dynamic>> pivotData, Map<String, double> termTotals, {bool bounded = false}) {
    // Group by course + class for display.
    final Map<String, List<Map<String, dynamic>>> classGroups = {};
    for (final row in pivotData) {
      final course = row['courname']?.toString() ?? '';
      final cls = row['stuclass']?.toString() ?? 'Unknown';
      final key = course.isNotEmpty ? '$course - $cls' : cls;
      classGroups.putIfAbsent(key, () => []).add(row);
    }

    // Fixed column widths — the pivot is wide (one column per term) and
    // scrolls horizontally, so the header can't use flex.
    final colWidths = <double>[
      54, 92, 112, 190,
      for (final _ in terms) 96,
      86, 100, 140,
    ];
    final tableWidth = colWidths.fold<double>(0, (a, b) => a + b);
    final headers = <String>[
      'SNO', 'CLASS', 'ADMN. NO', 'STUDENT NAME',
      for (final t in terms) t.toUpperCase(),
      'FINE', 'TOTAL', 'REMARKS',
    ];
    final lastNumericIdx = 5 + terms.length; // term columns + FINE + TOTAL
    bool rightAlign(int i) => i >= 4 && i <= lastNumericIdx;

    final hStyle = TextStyle(
        fontSize: 13.sp,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: 0.3);
    Widget cell(int i, Widget child) => SizedBox(
          width: colWidths[i],
          child: Align(
            alignment: rightAlign(i)
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: child,
            ),
          ),
        );

    // Flatten student rows + per-class total rows into row widgets.
    final rowWidgets = <Widget>[];
    int sno = 0;
    var zebra = false;
    for (final entry in classGroups.entries) {
      final Map<String, double> classTotals = {};
      double classGrandTotal = 0;
      double classTotalFine = 0;
      for (final row in entry.value) {
        sno++;
        final rowTotal = (row['_total'] as double?) ?? 0;
        final rowFine = (row['_fine'] as double?) ?? 0;
        classGrandTotal += rowTotal;
        classTotalFine += rowFine;
        for (final t in terms) {
          final val = (row[t] as double?) ?? 0;
          if (val > 0) classTotals[t] = (classTotals[t] ?? 0) + val;
        }
        final cs = TextStyle(fontSize: 13.sp, color: AppColors.textPrimary);
        rowWidgets.add(Container(
          color: zebra ? AppColors.surface : Colors.white,
          padding: EdgeInsets.symmetric(vertical: 8.h),
          child: Row(children: [
            cell(0, Text('$sno', style: cs)),
            cell(1, Text(row['stuclass']?.toString() ?? '', style: cs)),
            cell(2, Text(row['stuadmno']?.toString() ?? '', style: cs)),
            cell(3,
                Text(row['stuname']?.toString() ?? '',
                    style: cs, overflow: TextOverflow.ellipsis)),
            for (var ti = 0; ti < terms.length; ti++)
              cell(4 + ti, Builder(builder: (_) {
                final v = (row[terms[ti]] as double?) ?? 0;
                return Text(v > 0 ? _formatNumber(v) : '', style: cs);
              })),
            cell(
                4 + terms.length,
                Text(rowFine > 0 ? _formatNumber(rowFine) : '',
                    style: TextStyle(
                        fontSize: 13.sp, color: Colors.orange))),
            cell(
                5 + terms.length,
                Text(rowTotal > 0 ? _formatNumber(rowTotal) : '',
                    style: TextStyle(
                        fontSize: 13.sp,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary))),
            cell(
                6 + terms.length,
                Text(row['_remarks']?.toString() ?? '',
                    style: TextStyle(
                        fontSize: 10.sp,
                        color: AppColors.textPrimary))),
          ]),
        ));
        zebra = !zebra;
      }
      // Per-class total row.
      rowWidgets.add(Container(
        color: const Color(0xFFE2E8F0),
        padding: EdgeInsets.symmetric(vertical: 8.h),
        child: Row(children: [
          cell(0, const SizedBox()),
          cell(
              1,
              Text('Total',
                  style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary))),
          cell(2, const SizedBox()),
          cell(3, const SizedBox()),
          for (var ti = 0; ti < terms.length; ti++)
            cell(
                4 + ti,
                Text(
                    (classTotals[terms[ti]] ?? 0) > 0
                        ? _formatNumber(classTotals[terms[ti]]!)
                        : '',
                    style: TextStyle(
                        fontSize: 13.sp,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary))),
          cell(
              4 + terms.length,
              Text(classTotalFine > 0 ? _formatNumber(classTotalFine) : '',
                  style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700,
                      color: Colors.orange))),
          cell(
              5 + terms.length,
              Text(
                  classGrandTotal > 0
                      ? _formatNumber(classGrandTotal)
                      : '',
                  style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary))),
          cell(6 + terms.length, const SizedBox()),
        ]),
      ));
    }

    final header = Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(vertical: 10.h),
      child: Row(children: [
        for (var i = 0; i < headers.length; i++)
          cell(i, Text(headers[i], style: hStyle)),
      ]),
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: tableWidth,
        // bounded: a fixed-height host (Collection Statement) — sticky
        // header + internally scrolling body. Otherwise the table is
        // content-sized and the page scrolls (course/class section views).
        child: bounded
            ? Column(
                children: [
                  header,
                  Container(height: 1, color: AppColors.border),
                  Expanded(
                    child: AppVerticalScrollbar(
                      builder: (context, sc) =>
                          ListView(controller: sc, children: rowWidgets),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  header,
                  Container(height: 1, color: AppColors.border),
                  ...rowWidgets,
                ],
              ),
      ),
    );
  }

  Widget _emptyState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.assessment_outlined, size: 48.sp, color: AppColors.accent.withValues(alpha: 0.4)),
          SizedBox(height: 12.h),
          Text(message, style: TextStyle(fontSize: 14.sp, color: AppColors.textPrimary)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════
  // EXCEL EXPORT: COLLECTION STATEMENT
  // ═══════════════════════════════════════════════
  Future<void> _exportCollectionStatement(List<Map<String, dynamic>> pivotData, List<String> terms, Map<String, double> termTotals) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Pending Fees'];
      excel.delete('Sheet1');

      final darkHeader = xl.CellStyle(
        bold: true, fontSize: 14,
        backgroundColorHex: xl.ExcelColor.fromHexString('#1E2532'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        horizontalAlign: xl.HorizontalAlign.Center,
      );
      final subHeader = xl.CellStyle(bold: true, fontSize: 11);
      final colHeader = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final totalStyle = xl.CellStyle(bold: true, fontSize: 11);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      // Columns: Sno, Class, Admn. No, Student Name, [terms], Total, Remarks
      final totalCols = 4 + terms.length + 3;

      // Institution header
      int row = 0;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = darkHeader;
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Center);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      final contactLine = [if (_insPhone.isNotEmpty) 'Ph: $_insPhone', if (_insEmail.isNotEmpty) 'Email: $_insEmail'].join('  |  ');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(contactLine);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Right);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;

      // Title
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('PENDING FEE REPORT AS ON ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('FEE TYPE : ${_selectedFeeTypes.isEmpty ? 'ALL FEE TYPE' : _selectedFeeTypes.join(', ')}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      row++; // blank row

      // Column headers: Sno, Class, Admn. No, Student Name, [terms], Total, Remarks
      final headers = ['Sno', 'Class', 'Admn. No', 'Student Name', ...terms, 'Fine', 'Total', 'Remarks'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = colHeader;
      }
      row++;

      // Group by course + class
      final Map<String, List<Map<String, dynamic>>> classGroups = {};
      for (final s in pivotData) {
        final course = s['courname']?.toString() ?? '';
        final cls = s['stuclass']?.toString() ?? 'Unknown';
        final key = course.isNotEmpty ? '$course - $cls' : cls;
        classGroups.putIfAbsent(key, () => []).add(s);
      }

      int sno = 0;
      for (final entry in classGroups.entries) {
        final classStudents = entry.value;
        final Map<String, double> classTotals = {};
        double classGrandTotal = 0;

        for (final student in classStudents) {
          sno++;
          final rowTotal = (student['_total'] as double?) ?? 0;
          classGrandTotal += rowTotal;

          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.IntCellValue(sno);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(student['stuclass']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(student['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(student['stuname']?.toString() ?? '');
          for (int c = 0; c < terms.length; c++) {
            final val = (student[terms[c]] as double?) ?? 0;
            if (val > 0) {
              classTotals[terms[c]] = (classTotals[terms[c]] ?? 0) + val;
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = numStyle;
            }
          }
          if (rowTotal > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowTotal.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          final rowFine = (student['_fine'] as double?) ?? 0;
          if (rowFine > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowFine.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6 + terms.length, rowIndex: row)).value = xl.TextCellValue(student['_remarks']?.toString() ?? '');
          row++;
        }

        // Class total row
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('Total');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = totalStyle;
        for (int c = 0; c < terms.length; c++) {
          final val = classTotals[terms[c]] ?? 0;
          if (val > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = totalStyle;
          }
        }
        if (classGrandTotal > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(classGrandTotal.toInt());
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = totalStyle;
        }
        row++;
      }

      // Column widths
      sheet.setColumnWidth(0, 6);
      sheet.setColumnWidth(1, 8);
      sheet.setColumnWidth(2, 10);
      sheet.setColumnWidth(3, 22);
      for (int c = 0; c < terms.length; c++) {
        sheet.setColumnWidth(4 + c, 12);
      }
      sheet.setColumnWidth(4 + terms.length, 8);
      sheet.setColumnWidth(5 + terms.length, 10);
      sheet.setColumnWidth(6 + terms.length, 25);

      await _saveExcel(excel, 'Pending_Fee_Report_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  // ═══════════════════════════════════════════════
  // EXCEL EXPORT: PENDING REPORT
  // ═══════════════════════════════════════════════
  Future<void> _exportPendingReport(List<Map<String, dynamic>> demands, List<String> terms, String groupBy) async {
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel['Pending Fees'];
      excel.delete('Sheet1');

      final darkHeader = xl.CellStyle(
        bold: true, fontSize: 14,
        backgroundColorHex: xl.ExcelColor.fromHexString('#1E2532'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        horizontalAlign: xl.HorizontalAlign.Center,
      );
      final subHeader = xl.CellStyle(bold: true, fontSize: 11);
      final colHeader = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final totalStyle = xl.CellStyle(bold: true, fontSize: 11);
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      // Columns: Sno, Class, Admn. No, Student Name, [terms], Total, Remarks
      final totalCols = 4 + terms.length + 3;
      int row = 0;

      // Institution header
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insName);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = darkHeader;
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(_insAddress);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Center);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;
      final contactLine = [if (_insPhone.isNotEmpty) 'Ph: $_insPhone', if (_insEmail.isNotEmpty) 'Email: $_insEmail'].join('  |  ');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(contactLine);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = xl.CellStyle(horizontalAlign: xl.HorizontalAlign.Right);
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
      row++;

      // Title
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('PENDING FEE REPORT AS ON ${_formatDate(DateTime.now())}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('FEE TYPE : ${_selectedFeeTypes.isEmpty ? 'ALL FEE TYPE' : _selectedFeeTypes.join(', ')}');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = subHeader;
      row++;
      row++; // blank row

      // Column headers
      final headers = ['Sno', 'Class', 'Admn. No', 'Student Name', ...terms, 'Fine', 'Total', 'Remarks'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = colHeader;
      }
      row++;

      // Group by course + class
      final Map<String, List<Map<String, dynamic>>> classGroups = {};
      for (final d in demands) {
        final course = d['courname']?.toString() ?? '';
        final cls = d['stuclass']?.toString() ?? 'Unknown';
        final key = course.isNotEmpty ? '$course - $cls' : cls;
        classGroups.putIfAbsent(key, () => []).add(d);
      }

      int sno = 0;
      for (final entry in classGroups.entries) {
        final classStudents = entry.value;
        final pivotData = _buildPivotData(classStudents, terms, showPending: true);
        final Map<String, double> classTotals = {};
        double classGrandTotal = 0;

        for (final student in pivotData) {
          sno++;
          final rowTotal = (student['_total'] as double?) ?? 0;
          classGrandTotal += rowTotal;

          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.IntCellValue(sno);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(student['stuclass']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(student['stuadmno']?.toString() ?? '');
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(student['stuname']?.toString() ?? '');
          for (int c = 0; c < terms.length; c++) {
            final val = (student[terms[c]] as double?) ?? 0;
            if (val > 0) {
              classTotals[terms[c]] = (classTotals[terms[c]] ?? 0) + val;
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
              sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = numStyle;
            }
          }
          if (rowTotal > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowTotal.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          final rowFine = (student['_fine'] as double?) ?? 0;
          if (rowFine > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).value = xl.IntCellValue(rowFine.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + terms.length, rowIndex: row)).cellStyle = numStyle;
          }
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6 + terms.length, rowIndex: row)).value = xl.TextCellValue(student['_remarks']?.toString() ?? '');
          row++;
        }

        // Class total row
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue('Total');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).cellStyle = totalStyle;
        for (int c = 0; c < terms.length; c++) {
          final val = classTotals[terms[c]] ?? 0;
          if (val > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).value = xl.IntCellValue(val.toInt());
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4 + c, rowIndex: row)).cellStyle = totalStyle;
          }
        }
        if (classGrandTotal > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).value = xl.IntCellValue(classGrandTotal.toInt());
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + terms.length, rowIndex: row)).cellStyle = totalStyle;
        }
        row++;
      }

      // Column widths
      sheet.setColumnWidth(0, 6);
      sheet.setColumnWidth(1, 8);
      sheet.setColumnWidth(2, 10);
      sheet.setColumnWidth(3, 22);
      for (int c = 0; c < terms.length; c++) {
        sheet.setColumnWidth(4 + c, 12);
      }
      sheet.setColumnWidth(4 + terms.length, 8);
      sheet.setColumnWidth(5 + terms.length, 10);
      sheet.setColumnWidth(6 + terms.length, 25);

      await _saveExcel(excel, 'Pending_${groupBy}_${_formatDateCompact(DateTime.now())}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  Future<void> _exportDailyCollectionExcel() async {
    try {
      final visibleRows = _dailyRows.where((r) {
        if (_selectedCourse != null && r['courname']?.toString() != _selectedCourse) return false;
        if (_selectedClass != null && r['stuclass']?.toString() != _selectedClass) return false;
        if (_selectedFeeTypes.isNotEmpty) {
          final fees = r['fees'] as Map<String, double>;
          if (!_selectedFeeTypes.any((ft) => (fees[ft] ?? 0) > 0)) return false;
        }
        if (_selectedMode != null) {
          final isCash = _isCashMode(r['paymethod']?.toString() ?? '');
          if (_selectedMode == 'cash' && !isCash) return false;
          if (_selectedMode == 'bank' && isCash) return false;
        }
        if (_selectedPrefix != null) {
          final p = _prefixOf(r['paynumber']?.toString() ?? '');
          if (p != _selectedPrefix) return false;
        }
        if (_selectedUser != null && r['createdby']?.toString() != _selectedUser) return false;
        return true;
      }).toList();
      final feeTypes = _selectedFeeTypes.isNotEmpty
          ? _dailyFeeTypes.where(_selectedFeeTypes.contains).toList()
          : _dailyFeeTypes;

      final excel = xl.Excel.createExcel();
      final sheet = excel['Daily Collection'];
      excel.delete('Sheet1');

      final boldStyle = xl.CellStyle(bold: true, fontSize: 11);
      final headerStyle = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      final showCash = _selectedMode == null || _selectedMode == 'cash';
      final showCheque = _selectedMode == null || _selectedMode == 'cash';
      final showBank = _selectedMode == null || _selectedMode == 'bank';
      final modeCols = (showCash ? 1 : 0) + (showCheque ? 1 : 0) + (showBank ? 1 : 0);
      final totalCols = 5 + feeTypes.length + 2 + modeCols + 1; // +fine +total +(cash/cheque/bank) +net

      int row = 0;
      void merged(String text, xl.CellStyle style) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(text);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = style;
        sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), xl.CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: row));
        row++;
      }

      merged(_insName, boldStyle);
      if (_insAddress.isNotEmpty) merged(_insAddress, xl.CellStyle(fontSize: 10));
      merged('DAILY COLLECTION STATEMENT FROM ${_formatDate(_dailyFrom!)} TO ${_formatDate(_dailyTo!)}', boldStyle);
      merged('Date: ${_formatDate(DateTime.now())}', xl.CellStyle(fontSize: 10));
      // Collected-by line: specific user if filtered, otherwise derived
      // from the distinct cashiers visible in the exported rows.
      final exportCashiers = <String>{
        for (final r in visibleRows)
          if ((r['createdby']?.toString() ?? '').isNotEmpty) r['createdby'].toString(),
      };
      final exportCollectedBy = _selectedUser
          ?? (exportCashiers.length == 1 ? exportCashiers.first : 'All accountants');
      merged('Collected by: $exportCollectedBy', boldStyle);
      row++;

      final modeHeaders = <String>[
        if (showCash) 'Cash',
        if (showCheque) 'Cheque',
        if (showBank) 'Bank',
      ];
      final headers = ['Receipt No', 'Reg No', 'Student Name', 'Course', 'Class', ...feeTypes, 'Fine', 'Total', ...modeHeaders, 'Net Amt'];
      for (int c = 0; c < headers.length; c++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).value = xl.TextCellValue(headers[c]);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = headerStyle;
      }
      row++;

      final ftTotals = <String, double>{};
      double totalAmt = 0;
      double totalFine = 0;
      double totalCash = 0;
      double totalCheque = 0;
      double totalBank = 0;

      final fineCol = 5 + feeTypes.length;
      final totalCol = 6 + feeTypes.length;
      int cursor = 7 + feeTypes.length;
      final cashCol = showCash ? cursor++ : -1;
      final chequeCol = showCheque ? cursor++ : -1;
      final bankCol = showBank ? cursor++ : -1;
      final netCol = cursor;

      double exportRowTotal(Map<String, dynamic> r) {
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        if (_selectedFeeTypes.isEmpty) {
          return (r['total'] as num?)?.toDouble() ?? 0;
        }
        final fees = r['fees'] as Map<String, double>;
        double sum = 0;
        for (final ft in _selectedFeeTypes) {
          sum += fees[ft] ?? 0;
        }
        return sum + fine;
      }

      for (final r in visibleRows) {
        final fees = r['fees'] as Map<String, double>;
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        final total = exportRowTotal(r);
        final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
        totalAmt += total;
        totalFine += fine;
        if (bucket == 'cash') { totalCash += total; }
        else if (bucket == 'cheque') { totalCheque += total; }
        else { totalBank += total; }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['paynumber']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(r['stuadmno']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['stuname']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['courname']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(r['stuclass']?.toString() ?? '');
        for (int c = 0; c < feeTypes.length; c++) {
          final v = fees[feeTypes[c]] ?? 0;
          ftTotals[feeTypes[c]] = (ftTotals[feeTypes[c]] ?? 0) + v;
          if (v > 0) {
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).value = xl.DoubleCellValue(v);
            sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).cellStyle = numStyle;
          }
        }
        if (fine > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).value = xl.DoubleCellValue(fine);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).cellStyle = numStyle;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(total);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = totalStyle;
        if (cashCol >= 0 && bucket == 'cash') {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).value = xl.DoubleCellValue(total);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).cellStyle = numStyle;
        }
        if (chequeCol >= 0 && bucket == 'cheque') {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).value = xl.DoubleCellValue(total);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).cellStyle = numStyle;
        }
        if (bankCol >= 0 && bucket == 'bank') {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).value = xl.DoubleCellValue(total);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).cellStyle = numStyle;
        }
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).value = xl.DoubleCellValue(total);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).cellStyle = totalStyle;
        row++;
      }

      // TOTAL row
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue('TOTAL');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).cellStyle = boldStyle;
      for (int c = 0; c < feeTypes.length; c++) {
        final v = ftTotals[feeTypes[c]] ?? 0;
        if (v > 0) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).value = xl.DoubleCellValue(v);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5 + c, rowIndex: row)).cellStyle = totalStyle;
        }
      }
      if (totalFine > 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).value = xl.DoubleCellValue(totalFine);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: fineCol, rowIndex: row)).cellStyle = totalStyle;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).value = xl.DoubleCellValue(totalAmt);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: totalCol, rowIndex: row)).cellStyle = totalStyle;
      if (cashCol >= 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).value = xl.DoubleCellValue(totalCash);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: cashCol, rowIndex: row)).cellStyle = totalStyle;
      }
      if (chequeCol >= 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).value = xl.DoubleCellValue(totalCheque);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: chequeCol, rowIndex: row)).cellStyle = totalStyle;
      }
      if (bankCol >= 0) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).value = xl.DoubleCellValue(totalBank);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: bankCol, rowIndex: row)).cellStyle = totalStyle;
      }
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).value = xl.DoubleCellValue(totalAmt);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: netCol, rowIndex: row)).cellStyle = totalStyle;

      sheet.setColumnWidth(0, 12);
      sheet.setColumnWidth(1, 14);
      sheet.setColumnWidth(2, 24);
      sheet.setColumnWidth(3, 14);
      sheet.setColumnWidth(4, 12);
      for (int c = 0; c < feeTypes.length; c++) {
        sheet.setColumnWidth(5 + c, 12);
      }
      sheet.setColumnWidth(fineCol, 8);
      sheet.setColumnWidth(totalCol, 10);
      if (cashCol >= 0) sheet.setColumnWidth(cashCol, 10);
      if (chequeCol >= 0) sheet.setColumnWidth(chequeCol, 10);
      if (bankCol >= 0) sheet.setColumnWidth(bankCol, 10);
      sheet.setColumnWidth(netCol, 10);

      await _saveExcel(excel, 'Daily_Collection_${_formatDateCompact(_dailyFrom!)}_${_formatDateCompact(_dailyTo!)}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  /// PowerCollege export — one row per (payment, fee demand) for every
  /// reconciled payment in the selected date range. Joins payment +
  /// paymentdetails + feedemand + students + bank server-side via the
  /// get_powercollege_export RPC. Only paystatus='C' AND recon_status='R'
  /// rows are included (matches the "settled / cleared" expectation).
  /// Fetch reconciled per-line-item rows for the current PC date range
  /// into _pcRows. Called on tab init and when the user changes a date.
  /// Same RPC the export uses; we just keep the result in memory so the
  /// tab can show a preview and the export button doesn't have to re-fetch.
  Future<void> _loadPowerCollege() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final schema = SupabaseService.currentSchema;
    if (insId == null || schema == null || _pcFrom == null || _pcTo == null) return;

    setState(() {
      _pcLoading = true;
      _pcRows = [];
    });
    try {
      String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
      final result = await SupabaseService.client.rpc('get_powercollege_export', params: {
        'p_schema': schema,
        'p_ins_id': insId,
        'p_from': d(_pcFrom!),
        'p_to': d(_pcTo!),
      });
      final rows = result is List ? List<Map<String, dynamic>>.from(result) : <Map<String, dynamic>>[];
      if (mounted) {
        setState(() {
          _pcRows = rows;
          _pcLoading = false;
        });
      }
    } catch (e) {
      debugPrint('PowerCollege load error: $e');
      if (mounted) setState(() => _pcLoading = false);
    }
  }

  Future<void> _exportPowerCollege() async {
    if (_pcFrom == null || _pcTo == null) return;
    if (_pcRows.isEmpty && !_pcLoading) {
      // Last-second refresh in case the list was cleared.
      await _loadPowerCollege();
    }
    if (_pcRows.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No payments in this date range.'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    setState(() => _pcExporting = true);
    try {
      final rows = _pcRows;
      final excel = xl.Excel.createExcel();
      final sheet = excel['PowerCollege'];
      excel.delete('Sheet1');

      final headerStyle = xl.CellStyle(
        bold: true, fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final numStyle = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      const headers = [
        'Roll No', 'Name', 'Course', 'Class',
        'Transaction Date', 'Payment Mode', 'Doc No', 'Term', 'Fee Type',
        'Amount', 'Fine', 'Bank Name', 'Settlement Date',
      ];

      for (int c = 0; c < headers.length; c++) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
        cell.value = xl.TextCellValue(headers[c]);
        cell.cellStyle = headerStyle;
      }

      String fmtDate(dynamic raw) {
        if (raw == null) return '';
        final s = raw.toString();
        final dt = DateTime.tryParse(s);
        return dt == null ? s : _formatDate(dt);
      }

      double grandTotal = 0;
      double grandFine = 0;
      for (int i = 0; i < rows.length; i++) {
        final r = rows[i];
        final amt = (r['amount'] as num?)?.toDouble() ?? 0;
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        grandTotal += amt;
        grandFine += fine;
        final row = i + 1;

        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(r['stuadmno']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(r['stuname']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['courname']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(r['stuclass']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(fmtDate(r['paydate']));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row)).value = xl.TextCellValue(r['paymethod']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row)).value = xl.TextCellValue(r['docno']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row)).value = xl.TextCellValue(r['demfeeterm']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: row)).value = xl.TextCellValue(r['demfeetype']?.toString() ?? '');
        final amtCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: row));
        amtCell.value = xl.DoubleCellValue(amt);
        amtCell.cellStyle = numStyle;
        final fineCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: row));
        fineCell.value = xl.DoubleCellValue(fine);
        fineCell.cellStyle = numStyle;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 11, rowIndex: row)).value = xl.TextCellValue(r['banname']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 12, rowIndex: row)).value = xl.TextCellValue(r['settlement_id']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 13, rowIndex: row)).value = xl.TextCellValue(fmtDate(r['settlement_date']));
      }

      // Grand total row
      final totalRow = rows.length + 1;
      final totalLabelCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: totalRow));
      totalLabelCell.value = xl.TextCellValue('Grand Total');
      totalLabelCell.cellStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final totalCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: totalRow));
      totalCell.value = xl.DoubleCellValue(grandTotal);
      totalCell.cellStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final fineTotalCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: totalRow));
      fineTotalCell.value = xl.DoubleCellValue(grandFine);
      fineTotalCell.cellStyle = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);

      // Reasonable widths
      sheet.setColumnWidth(0, 14);
      sheet.setColumnWidth(1, 28);
      sheet.setColumnWidth(2, 10);
      sheet.setColumnWidth(3, 20);
      sheet.setColumnWidth(4, 16);
      sheet.setColumnWidth(5, 14);
      sheet.setColumnWidth(6, 14);
      sheet.setColumnWidth(7, 12);
      sheet.setColumnWidth(8, 16);
      sheet.setColumnWidth(9, 12);
      sheet.setColumnWidth(10, 10);
      sheet.setColumnWidth(11, 22);
      sheet.setColumnWidth(12, 18);
      sheet.setColumnWidth(13, 16);

      await _saveExcel(excel, 'PowerCollege_${_formatDateCompact(_pcFrom!)}_${_formatDateCompact(_pcTo!)}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PowerCollege export error. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _pcExporting = false);
    }
  }

  /// PowerCollege tab — date range pickers, Excel export button, and a
  /// preview table of every reconciled per-line-item row that the export
  /// would emit. Same shape as Daily Collection so users can see what
  /// they'll get before downloading.
  Widget _buildPowerCollege() {
    String fmt(dynamic raw) {
      if (raw == null) return '';
      final dt = DateTime.tryParse(raw.toString());
      return dt == null ? raw.toString() : _formatDate(dt);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(0, 8.h, 0, 8.h),
          child: Row(
            children: [
              const AppIcon('document-download', size: 18, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('PowerCollege Export',
                  style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              SizedBox(width: 8.w),
              if (_pcLoading)
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
              const Spacer(),
              SizedBox(
                height: AppBtn.height(context),
                child: OutlinedButton.icon(
                  onPressed: _openPcDateDialog,
                  icon: Icon(Icons.calendar_today, size: AppBtn.iconSize(context), color: AppColors.textPrimary),
                  label: Text(
                    _pcFrom != null && _pcTo != null
                        ? '${_formatDate(_pcFrom!)} – ${_formatDate(_pcTo!)}'
                        : 'Pick range',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: 14.w),
                    side: const BorderSide(color: AppColors.border),
                  ),
                ),
              ),
              SizedBox(width: AppBtn.gap(context)),
              _miniExportBtn(
                onPressed: (_pcRows.isEmpty || _pcExporting) ? () {} : _exportPowerCollege,
                icon: Icons.download_rounded,
                label: _pcExporting ? 'Exporting…' : 'Excel',
                color: const Color(0xFF10B981),
              ),
            ],
          ),
        ),
        Expanded(
          child: _pcRows.isEmpty
              ? _emptyState(_pcLoading
                  ? 'Loading reconciled payments…'
                  : 'No payments in this range')
              : Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: _PowerCollegeTable(rows: _pcRows, fmt: fmt),
                ),
        ),
      ],
    );
  }


  Future<void> _exportDailyCollectionPdf() async {
    try {
      final visibleRows = _dailyRows.where((r) {
        if (_selectedCourse != null && r['courname']?.toString() != _selectedCourse) return false;
        if (_selectedClass != null && r['stuclass']?.toString() != _selectedClass) return false;
        if (_selectedFeeTypes.isNotEmpty) {
          final fees = r['fees'] as Map<String, double>;
          if (!_selectedFeeTypes.any((ft) => (fees[ft] ?? 0) > 0)) return false;
        }
        if (_selectedMode != null) {
          final isCash = _isCashMode(r['paymethod']?.toString() ?? '');
          if (_selectedMode == 'cash' && !isCash) return false;
          if (_selectedMode == 'bank' && isCash) return false;
        }
        if (_selectedPrefix != null) {
          final p = _prefixOf(r['paynumber']?.toString() ?? '');
          if (p != _selectedPrefix) return false;
        }
        if (_selectedUser != null && r['createdby']?.toString() != _selectedUser) return false;
        return true;
      }).toList();
      final feeTypes = _selectedFeeTypes.isNotEmpty
          ? _dailyFeeTypes.where(_selectedFeeTypes.contains).toList()
          : _dailyFeeTypes;

      final showCash = _selectedMode == null || _selectedMode == 'cash';
      final showCheque = _selectedMode == null || _selectedMode == 'cash';
      final showBank = _selectedMode == null || _selectedMode == 'bank';

      double pdfRowTotal(Map<String, dynamic> r) {
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        if (_selectedFeeTypes.isEmpty) {
          return (r['total'] as num?)?.toDouble() ?? 0;
        }
        final fees = r['fees'] as Map<String, double>;
        double sum = 0;
        for (final ft in _selectedFeeTypes) {
          sum += fees[ft] ?? 0;
        }
        return sum + fine;
      }

      final ftTotals = <String, double>{};
      double totalAmt = 0;
      double totalFine = 0;
      double totalCash = 0;
      double totalCheque = 0;
      double totalBank = 0;
      for (final r in visibleRows) {
        final fees = r['fees'] as Map<String, double>;
        final total = pdfRowTotal(r);
        totalAmt += total;
        totalFine += (r['fine'] as num?)?.toDouble() ?? 0;
        final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
        if (bucket == 'cash') totalCash += total;
        else if (bucket == 'cheque') totalCheque += total;
        else totalBank += total;
        for (final ft in feeTypes) {
          ftTotals[ft] = (ftTotals[ft] ?? 0) + (fees[ft] ?? 0);
        }
      }

      final modeHeaders = <String>[
        if (showCash) 'Cash',
        if (showCheque) 'Cheque',
        if (showBank) 'Bank',
      ];
      final headers = ['Receipt No', 'Reg No', 'Student Name', 'Course', 'Class', ...feeTypes, 'Fine', 'Total', ...modeHeaders, 'Net Amt'];
      final rows = <List<String>>[];
      for (final r in visibleRows) {
        final fees = r['fees'] as Map<String, double>;
        final fine = (r['fine'] as num?)?.toDouble() ?? 0;
        final total = pdfRowTotal(r);
        final bucket = _paymentBucket(r['paymethod']?.toString() ?? '');
        rows.add([
          r['paynumber']?.toString() ?? '',
          r['stuadmno']?.toString() ?? '',
          r['stuname']?.toString() ?? '',
          r['courname']?.toString() ?? '',
          r['stuclass']?.toString() ?? '',
          ...feeTypes.map((ft) => (fees[ft] ?? 0) > 0 ? _formatNumber(fees[ft]!) : ''),
          fine > 0 ? _formatNumber(fine) : '',
          _formatNumber(total),
          if (showCash) (bucket == 'cash' ? _formatNumber(total) : ''),
          if (showCheque) (bucket == 'cheque' ? _formatNumber(total) : ''),
          if (showBank) (bucket == 'bank' ? _formatNumber(total) : ''),
          _formatNumber(total),
        ]);
      }
      rows.add([
        'TOTAL', '', '', '', '',
        ...feeTypes.map((ft) => _formatNumber(ftTotals[ft] ?? 0)),
        totalFine > 0 ? _formatNumber(totalFine) : '',
        _formatNumber(totalAmt),
        if (showCash) _formatNumber(totalCash),
        if (showCheque) _formatNumber(totalCheque),
        if (showBank) _formatNumber(totalBank),
        _formatNumber(totalAmt),
      ]);

      final pdf = pw.Document();
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
          header: (_) {
            // "Collected by" line — shows who the report covers.
            //   * specific user filter active → that user's name
            //   * no filter + 1 accountant visible in rows → their name
            //   * no filter + multiple → "All accountants" so the report
            //     makes it obvious that the totals span more than one
            //     cashier (prevents a cashier accepting a report for
            //     someone else's work).
            final distinctCashiers = <String>{
              for (final r in visibleRows)
                if ((r['createdby']?.toString() ?? '').isNotEmpty) r['createdby'].toString(),
            };
            final collectedBy = _selectedUser
                ?? (distinctCashiers.length == 1 ? distinctCashiers.first : 'All accountants');
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(_insName, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                if (_insAddress.isNotEmpty) pw.Text(_insAddress, style: const pw.TextStyle(fontSize: 9)),
                pw.SizedBox(height: 6),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('DAILY COLLECTION STATEMENT FROM ${_formatDate(_dailyFrom!)} TO ${_formatDate(_dailyTo!)}',
                        style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Date: ${_formatDate(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
                  ],
                ),
                pw.SizedBox(height: 2),
                pw.Text('Collected by: $collectedBy', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 6),
              ],
            );
          },
          build: (ctx) => [
            pw.Table.fromTextArray(
              headers: headers,
              data: rows,
              headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {
                for (int i = 4; i < headers.length - 1; i++) i: pw.Alignment.centerRight,
              },
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
              headerHeight: 22,
              cellHeight: 16,
            ),
          ],
        ),
      );

      await Printing.sharePdf(
        bytes: await pdf.save(),
        filename: 'Daily_Collection_${_formatDateCompact(_dailyFrom!)}_${_formatDateCompact(_dailyTo!)}.pdf',
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF error. ${friendlyError(e)}'), backgroundColor: Colors.red));
    }
  }

  Future<void> _saveExcel(xl.Excel excel, String fileName) async {
    final bytes = excel.encode();
    if (bytes == null) return;

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Report',
      fileName: '$fileName.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (result == null) return;

    final file = File(result);
    await file.writeAsBytes(bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Report saved: ${file.path}'), backgroundColor: Colors.green),
      );
    }
  }
}

/// Stateful wrapper so the horizontal ScrollController survives across
/// rebuilds. Before this, applying a filter created a new ScrollController
/// every build — the scrollbar thumb would freeze in place because the
/// AnimatedBuilder was listening to an orphaned controller that was never
/// attached to a live ScrollView.
class _StickyTable extends StatefulWidget {
  const _StickyTable({
    required this.columnWidths,
    required this.headers,
    required this.rows,
    required this.footer,
    required this.numericCols,
    this.centerCols = const {},
  });

  final List<double> columnWidths;
  final List<String> headers;
  final List<List<String>> rows;
  final List<String> footer;
  final Set<int> numericCols;
  final Set<int> centerCols;

  @override
  State<_StickyTable> createState() => _StickyTableState();
}

class _StickyTableState extends State<_StickyTable> {
  final ScrollController _hController = ScrollController();
  // Vertical scroll for the body rows. Kept separate so the custom vertical
  // scrollbar can live in a lane pinned to the viewport, instead of off-screen
  // at the far-right edge of the (wider) horizontally-scrolling content.
  final ScrollController _vController = ScrollController();

  @override
  void dispose() {
    _hController.dispose();
    _vController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _StickyTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Content (rows/columns) may have changed after a filter, so the
    // thumb size/position is probably now wrong. A ScrollController only
    // notifies listeners on user scroll, not on content resize, so the
    // scrollbar would otherwise keep the old ratio until the user scrolls.
    // Poke it once after the next frame so the AnimatedBuilder reruns
    // with the fresh maxScrollExtent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hController.hasClients) return;
      // jumpTo(offset) is a no-op that still fires notifyListeners().
      _hController.jumpTo(_hController.offset.clamp(0.0, _hController.position.maxScrollExtent));
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hController.hasClients) return;
      _hController.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.columnWidths.length == widget.headers.length);
    final baseTotal = widget.columnWidths.fold<double>(0, (a, b) => a + b.w);
    final headerStyle = TextStyle(
      fontSize: 13.sp,
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
      letterSpacing: 0.3,
    );
    final footerStyle = TextStyle(
      fontSize: 13.sp,
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
    );
    final cellStyle = TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w600);

    Widget rowWidget(List<String> values, List<double> widths, {Color? bg, TextStyle? style}) {
      return Container(
        width: double.infinity,
        color: bg,
        padding: EdgeInsets.symmetric(vertical: 6.h),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            for (int i = 0; i < values.length; i++)
              SizedBox(
                width: widths[i],
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10.w),
                  child: Text(
                    values[i],
                    textAlign: widget.centerCols.contains(i)
                        ? TextAlign.center
                        : widget.numericCols.contains(i)
                            ? TextAlign.right
                            : TextAlign.left,
                    style: style ?? cellStyle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // The vertical scrollbar always occupies a 16px lane on the right, so
        // the horizontal viewport for the table content is that much narrower.
        const vBarWidth = 16.0;
        final hViewport = constraints.maxWidth - vBarWidth;
        final needsScroll = baseTotal > hViewport;
        final scale = needsScroll ? 1.0 : (hViewport / baseTotal);
        final widths = [for (final c in widget.columnWidths) c.w * scale];
        final width = needsScroll ? baseTotal : hViewport;
        final scrollbarHeight = needsScroll ? 16.0 : 0.0;
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _hController,
                        scrollDirection: Axis.horizontal,
                        physics: needsScroll ? null : const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: width,
                          height: constraints.maxHeight - scrollbarHeight,
                          child: Column(
                            children: [
                              rowWidget(widget.headers, widths, bg: AppColors.tableHeadBg, style: headerStyle),
                              Container(height: 1, color: AppColors.border),
                              Expanded(
                                // Suppress the framework scrollbar; the pinned
                                // bar on the right drives this list instead.
                                child: ScrollConfiguration(
                                  behavior: ScrollConfiguration.of(context)
                                      .copyWith(scrollbars: false),
                                  child: ListView.separated(
                                    controller: _vController,
                                    itemCount: widget.rows.length,
                                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
                                    itemBuilder: (_, i) => rowWidget(widget.rows[i], widths, bg: i.isEven ? Colors.white : AppColors.surface),
                                  ),
                                ),
                              ),
                              Container(height: 1, color: AppColors.border),
                              rowWidget(widget.footer, widths, bg: AppColors.tableHeadBg, style: footerStyle),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Vertical scrollbar pinned to the viewport — top/bottom
                    // spacers carry the header/footer colour so each band
                    // reads as a continuous full-width strip with the bar
                    // only between them.
                    Column(
                      children: [
                        Container(width: 16, color: AppColors.tableHeadBg, child: SizedBox(height: 12.h * 2 + 18)),
                        Expanded(child: AppScrollbarBar(controller: _vController)),
                        Container(width: 16, color: AppColors.tableHeadBg, child: SizedBox(height: 12.h * 2 + 18)),
                      ],
                    ),
                  ],
                ),
              ),
              if (needsScroll)
                Row(
                  children: [
                    Expanded(
                      child: ClassicHScrollbar(
                        controller: _hController,
                        contentWidth: width,
                        viewportWidth: hViewport,
                      ),
                    ),
                    // Corner gap so the horizontal bar lines up with the
                    // content viewport, not the vertical scrollbar lane.
                    const SizedBox(width: vBarWidth),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Custom table for the PowerCollege report. Sticky header, scrollable body,
/// and the project's standard Windows-style horizontal scrollbar pinned to
/// the bottom (matches the table style used on Fee Collection / Students /
/// Failed Transactions).
class _PowerCollegeTable extends StatefulWidget {
  const _PowerCollegeTable({required this.rows, required this.fmt});
  final List<Map<String, dynamic>> rows;
  final String Function(dynamic) fmt;

  @override
  State<_PowerCollegeTable> createState() => _PowerCollegeTableState();
}

class _PowerCollegeTableState extends State<_PowerCollegeTable> {
  final _hCtrl = ScrollController();
  final _vCtrl = ScrollController();

  // Widths picked so every uppercase header fits on one line (TRANSACTION
  // DATE / PAYMENT MODE / SETTLEMENT DATE are the long ones).
  static const _colWidths = <double>[
    120, 220, 110, 130, 170, 140, 130, 90, 200, 100, 90, 240, 180, 170,
  ];
  static const _headers = <String>[
    'ROLL NO', 'NAME', 'COURSE', 'CLASS',
    'TRANSACTION DATE', 'PAYMENT MODE', 'DOC NO', 'TERM', 'FEE TYPE',
    'AMOUNT', 'FINE', 'BANK NAME', 'SETTLEMENT ID', 'SETTLEMENT DATE',
  ];
  static const _numericColumns = <int>{9, 10};

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  Widget _headerCell(int i, double w) {
    return Container(
      width: w,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      alignment: _numericColumns.contains(i) ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        _headers[i],
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(
          fontSize: 13.sp,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _bodyCell(int i, String text, double w) {
    return Container(
      width: w,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      alignment: _numericColumns.contains(i) ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13.sp,
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double baseWidth = 0;
    for (final w in _colWidths) {
      baseWidth += w;
    }

    return LayoutBuilder(builder: (_, constraints) {
      // Reserve 16px for the pinned vertical scrollbar lane.
      final viewportWidth = (constraints.maxWidth - 16).clamp(0.0, double.infinity);
      final needsScroll = baseWidth > viewportWidth;
      // When the viewport is wider than the fixed total, distribute the
      // extra space proportionally so the columns fill the row instead of
      // leaving a gap on the right.
      final tableWidth = needsScroll ? baseWidth : viewportWidth;
      final extra = tableWidth - baseWidth;
      final List<double> adj = _colWidths
          .map((w) => w + (extra * w / baseWidth))
          .toList(growable: false);
      // Header padding (vertical 12) + ~18px text line ≈ 42, plus the 1px
      // divider below.
      const headerH = 43.0;
      return Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    controller: _hCtrl,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: tableWidth,
                      child: Column(
                        children: [
                          Container(
                            decoration: const BoxDecoration(
                              color: AppColors.tableHeadBg,
                              border: Border(
                                bottom: BorderSide(color: AppColors.border, width: 1),
                              ),
                            ),
                            child: Row(
                              children: [
                                for (int i = 0; i < _headers.length; i++) _headerCell(i, adj[i]),
                              ],
                            ),
                          ),
                          Expanded(
                            // Framework scrollbar suppressed — the pinned bar
                            // on the right (outside the horizontal scroll)
                            // drives the vertical scroll instead.
                            child: ScrollConfiguration(
                              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                              child: ListView.builder(
                                controller: _vCtrl,
                                itemCount: widget.rows.length,
                                itemBuilder: (_, idx) {
                                  final r = widget.rows[idx];
                                  final amt = (r['amount'] as num?)?.toDouble() ?? 0;
                                  final fine = (r['fine'] as num?)?.toDouble() ?? 0;
                                  return Container(
                                    decoration: BoxDecoration(
                                      color: idx.isEven ? Colors.white : AppColors.surface,
                                      border: const Border(
                                        bottom: BorderSide(color: AppColors.border, width: 0.5),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        _bodyCell(0, r['stuadmno']?.toString() ?? '', adj[0]),
                                        _bodyCell(1, r['stuname']?.toString() ?? '', adj[1]),
                                        _bodyCell(2, r['courname']?.toString() ?? '', adj[2]),
                                        _bodyCell(3, r['stuclass']?.toString() ?? '', adj[3]),
                                        _bodyCell(4, widget.fmt(r['paydate']), adj[4]),
                                        _bodyCell(5, r['paymethod']?.toString() ?? '', adj[5]),
                                        _bodyCell(6, r['docno']?.toString() ?? '', adj[6]),
                                        _bodyCell(7, r['demfeeterm']?.toString() ?? '', adj[7]),
                                        _bodyCell(8, r['demfeetype']?.toString() ?? '', adj[8]),
                                        _bodyCell(9, amt.toStringAsFixed(2), adj[9]),
                                        _bodyCell(10, fine.toStringAsFixed(2), adj[10]),
                                        _bodyCell(11, r['banname']?.toString() ?? '', adj[11]),
                                        _bodyCell(12, r['settlement_id']?.toString() ?? '', adj[12]),
                                        _bodyCell(13, widget.fmt(r['settlement_date']), adj[13]),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Pinned vertical scrollbar — sits outside the horizontal
                // scroll so it stays in the viewport. The top spacer carries
                // the header colour so the band reads as one continuous strip.
                Column(
                  children: [
                    Container(width: 16, height: headerH, color: AppColors.tableHeadBg),
                    Expanded(child: AppScrollbarBar(controller: _vCtrl)),
                  ],
                ),
              ],
            ),
          ),
          if (needsScroll)
            ClassicHScrollbar(
              controller: _hCtrl,
              contentWidth: tableWidth,
              viewportWidth: viewportWidth,
            ),
        ],
      );
    });
  }
}
