import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';

/// Student Fee Definition — lists every fee defined for a student (Regular +
/// Optional). The "Opted" checkbox maps to feedemand.collectible: ticking it
/// opts the student in so the fee comes up at the counter. Returns true if
/// the cashier saved.
class StudentFeeDefinitionDialog extends StatefulWidget {
  final int insId;
  final String stuAdmno;
  final String stuName;
  const StudentFeeDefinitionDialog({
    super.key,
    required this.insId,
    required this.stuAdmno,
    required this.stuName,
  });

  @override
  State<StudentFeeDefinitionDialog> createState() => _StudentFeeDefinitionDialogState();
}

class _DefRow {
  final int demId;
  final String term;
  final String section;
  final String feeType;
  final double concession;
  final bool optional;
  final TextEditingController amountCtrl;
  bool opted;
  _DefRow({
    required this.demId,
    required this.term,
    required this.section,
    required this.feeType,
    required double amount,
    required this.concession,
    required this.optional,
    required this.opted,
  }) : amountCtrl = TextEditingController(text: amount.toStringAsFixed(2));

  double get amount => double.tryParse(amountCtrl.text.trim()) ?? 0;
  double get balance {
    final b = amount - concession;
    return b > 0 ? b : 0;
  }

  void dispose() => amountCtrl.dispose();
}

class _StudentFeeDefinitionDialogState extends State<StudentFeeDefinitionDialog> {
  List<_DefRow> _rows = [];
  String? _term;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuclass, demfeeterm, demfeetype, feeamount, balancedue, conamount, collectible, feeoptional')
          .eq('ins_id', widget.insId)
          .eq('stuadmno', widget.stuAdmno)
          .eq('activestatus', 1)
          .eq('paidstatus', 'U')
          .order('demfeeterm', ascending: true)
          .order('demfeetype', ascending: true);
      final list = (res as List).map((r) {
        final m = r as Map<String, dynamic>;
        return _DefRow(
          demId: m['dem_id'] is int ? m['dem_id'] as int : int.tryParse(m['dem_id'].toString()) ?? 0,
          term: m['demfeeterm']?.toString() ?? '',
          section: m['stuclass']?.toString() ?? '',
          feeType: m['demfeetype']?.toString() ?? '',
          amount: (m['feeamount'] as num?)?.toDouble() ?? 0,
          concession: (m['conamount'] as num?)?.toDouble() ?? 0,
          optional: ((m['feeoptional'] as num?)?.toInt() ?? 0) == 1,
          opted: m['collectible'] == true,
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        for (final r in _rows) {
          r.dispose();
        }
        _rows = list;
        _term ??= list.isNotEmpty ? list.first.term : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Load failed. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  List<String> get _terms =>
      (_rows.map((r) => r.term).where((s) => s.isNotEmpty).toSet().toList()..sort());
  List<_DefRow> get _visible => _term == null ? _rows : _rows.where((r) => r.term == _term).toList();
  double get _toReceive => _visible.where((r) => r.opted).fold(0.0, (s, r) => s + r.balance);

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      for (final r in _rows) {
        await SupabaseService.fromSchema('feedemand').update({
          'feeamount': r.amount,
          'balancedue': r.balance,
          'reconbalancedue': r.balance,
          'collectible': r.opted,
        }).eq('dem_id', r.demId);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('Save failed. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
      child: SizedBox(
        width: 920.w,
        height: 600.h,
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.fromLTRB(18.w, 14.h, 14.w, 14.h),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12.r)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.fact_check_outlined, color: Colors.white, size: 20),
                  SizedBox(width: 10.w),
                  Text('Student Fee Definition',
                      style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: Colors.white)),
                  SizedBox(width: 12.w),
                  Expanded(
                    child: Text('${widget.stuName}  •  ${widget.stuAdmno}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.sp, color: Colors.white.withValues(alpha: 0.85))),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                      ? Center(child: Text('No fees defined for this student',
                          style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 170.w, child: _termList()),
                            const VerticalDivider(width: 1, color: AppColors.border),
                            Expanded(child: _table()),
                          ],
                        ),
            ),
            Divider(height: 1.h, color: AppColors.border),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _termList() {
    final terms = _terms;
    return ListView(
      children: [
        for (final t in terms)
          Material(
            color: _term == t ? AppColors.accent.withValues(alpha: 0.12) : Colors.transparent,
            child: InkWell(
              onTap: () => setState(() => _term = t),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
                child: Text(t,
                    style: TextStyle(
                        fontSize: 13.sp,
                        fontWeight: _term == t ? FontWeight.w700 : FontWeight.w500,
                        color: _term == t ? AppColors.accentDark : AppColors.textPrimary)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _table() {
    TextStyle h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
    TextStyle c() => TextStyle(fontSize: 12.sp, color: AppColors.textSecondary);
    final rows = _visible;
    return Column(
      children: [
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
          child: Row(children: [
            SizedBox(width: 56.w, child: Text('OPTED', style: h())),
            Expanded(flex: 2, child: Text('SECTION', style: h())),
            Expanded(flex: 3, child: Text('FEE TYPE', style: h())),
            SizedBox(width: 70.w, child: Text('TYPE', style: h())),
            SizedBox(width: 100.w, child: Text('AMOUNT', textAlign: TextAlign.right, style: h())),
            SizedBox(width: 12.w),
            SizedBox(width: 90.w, child: Text('BALANCE', textAlign: TextAlign.right, style: h())),
            SizedBox(width: 90.w, child: Text('CONC.', textAlign: TextAlign.right, style: h())),
          ]),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
            itemBuilder: (_, i) {
              final r = rows[i];
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 2.h),
                child: Row(children: [
                  SizedBox(
                    width: 56.w,
                    child: Checkbox(
                      value: r.opted,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(() => r.opted = v ?? false),
                    ),
                  ),
                  Expanded(flex: 2, child: Text(r.section, style: c())),
                  Expanded(flex: 3, child: Text(r.feeType, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
                  SizedBox(width: 70.w, child: Text(r.optional ? 'Optional' : 'Regular', style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: r.optional ? AppColors.warning : AppColors.success))),
                  SizedBox(
                    width: 100.w,
                    child: TextField(
                      controller: r.amountCtrl,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r)),
                      ),
                      onChanged: (v) => setState(() {
                        // Typing a positive amount auto-opts the student into this fee.
                        if ((double.tryParse(v.trim()) ?? 0) > 0) r.opted = true;
                      }),
                    ),
                  ),
                  SizedBox(width: 12.w),
                  SizedBox(width: 90.w, child: Text(r.balance.toStringAsFixed(2), textAlign: TextAlign.right, style: c())),
                  SizedBox(width: 90.w, child: Text(r.concession.toStringAsFixed(2), textAlign: TextAlign.right, style: c())),
                ]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _footer() {
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Row(
        children: [
          Text('Fees to be Received: ', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          Text('₹ ${_toReceive.toStringAsFixed(2)}', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.primary)),
          const Spacer(),
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          SizedBox(width: 10.w),
          ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.success, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }
}
