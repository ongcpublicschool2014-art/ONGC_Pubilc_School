import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../widgets/card_title_block.dart';

/// Setup -> Utilities: per-institution behaviour toggles.
///  - Admission Number mode: Automatic (generate & lock) vs Manual (suggest & edit)
///  - Fee collection: collect arrear demands before regular
class UtilitiesScreen extends StatefulWidget {
  const UtilitiesScreen({super.key});

  @override
  State<UtilitiesScreen> createState() => _UtilitiesScreenState();
}

class _UtilitiesScreenState extends State<UtilitiesScreen> {
  bool _loading = true;
  bool _saving = false;
  String _admMode = 'MANUAL'; // 'AUTO' | 'MANUAL'
  bool _arrearFirst = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final s = await SupabaseService.getInstitutionSettings(insId);
    if (!mounted) return;
    setState(() {
      _admMode = (s['admission_number_mode'] ?? 'MANUAL').toUpperCase() == 'AUTO' ? 'AUTO' : 'MANUAL';
      _arrearFirst = (s['fee_collection_arrear_first'] ?? 'true').toLowerCase() != 'false';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _saving = true);
    try {
      await SupabaseService.setInstitutionSetting(insId, 'admission_number_mode', _admMode, by: auth.userName);
      await SupabaseService.setInstitutionSetting(
          insId, 'fee_collection_arrear_first', _arrearFirst ? 'true' : 'false', by: auth.userName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Utilities saved'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // This screen is rendered inside the dashboard's SingleChildScrollView
    // (unbounded height), so it must size to its content — no Expanded / inner
    // scroll view (that layout crash white-screened the whole window).
    if (_loading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 80.h),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8.h),
          child: const CardTitleBlock(
            icon: 'setting-2',
            title: 'Utilities',
            subtitle: 'institution-wide numbering & collection behaviour',
          ),
        ),
        _admissionCard(),
        SizedBox(height: 12.h),
        _feeCollectionCard(),
        SizedBox(height: 16.h),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? SizedBox(width: 16.w, height: 16.w, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check, size: 18, color: Colors.white),
            label: Text(_saving ? 'Saving…' : 'Save', style: const TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 12.h),
            ),
          ),
        ),
        SizedBox(height: 24.h),
      ],
    );
  }

  Widget _sectionCard({required String title, required String desc, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(18.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(height: 4.h),
          Text(desc, style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          SizedBox(height: 14.h),
          child,
        ],
      ),
    );
  }

  Widget _admissionCard() {
    return _sectionCard(
      title: 'Admission Number',
      desc: 'How the register / admission number is filled on the Admission and Fast Admission forms.',
      child: Column(
        children: [
          _radioTile(
            selected: _admMode == 'AUTO',
            title: 'Automatic',
            subtitle: 'Generate the next number from the sequence and lock the field.',
            onTap: () => setState(() => _admMode = 'AUTO'),
          ),
          SizedBox(height: 8.h),
          _radioTile(
            selected: _admMode == 'MANUAL',
            title: 'Manual',
            subtitle: 'Suggest the next number but let the user edit or overwrite it.',
            onTap: () => setState(() => _admMode = 'MANUAL'),
          ),
        ],
      ),
    );
  }

  Widget _feeCollectionCard() {
    return _sectionCard(
      title: 'Fee Collection',
      desc: 'Controls how outstanding dues are prioritised at the collection counter.',
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _arrearFirst,
        activeColor: AppColors.primary,
        onChanged: (v) => setState(() => _arrearFirst = v),
        title: Text('Collect arrear before regular',
            style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        subtitle: Text(
          'When a student has arrear dues, the collection screen opens on Arrear first so arrears are cleared before regular fees.',
          style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary),
        ),
      ),
    );
  }

  Widget _radioTile({required bool selected, required String title, required String subtitle, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: EdgeInsets.all(12.w),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.06) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? AppColors.primary : AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: selected ? AppColors.primary : AppColors.textSecondary, size: 20),
            SizedBox(width: 10.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  SizedBox(height: 2.h),
                  Text(subtitle, style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
