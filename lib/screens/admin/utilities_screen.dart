import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/app_text.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../utils/school_terms.dart';

/// Setup -> Utilities: per-institution behaviour toggles.
///  - Admission Number mode: Automatic (generate & lock) vs Manual (suggest & edit)
///  - Fee collection: collect arrear demands before regular
///  - Advance settlement: which fee group -- and so which bank account and
///    which Paytm merchant -- each advance type is banked into
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

  /// advtype -> fg_id, null meaning "not configured": the server then works it
  /// out from the names, which is what it did before this existed.
  final Map<String, int?> _advRoute = {'A': null, 'S': null, 'M': null};
  List<Map<String, dynamic>> _feeGroups = [];

  /// Fee groups the Misc Collection counter may collect under. Empty means no
  /// restriction -- every group that owns a fee type, which is what the screen
  /// did before this setting existed.

  /// fg_id -> the letterhead its receipts print. Empty fields mean "use the
  /// institution's", which is what the college groups do.
  final Map<int, TextEditingController> _lhName = {};
  final Map<int, TextEditingController> _lhAddr = {};

  /// fg_id -> the printed header image: a bundled asset path, an https URL, or
  /// empty for the name + address text header.
  final Map<int, TextEditingController> _lhBanner = {};

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
    List<Map<String, dynamic>> groups = [];
    try {
      final rows = await SupabaseService.fromSchema('feegroup')
          .select('fg_id, fgdesc, ban_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('fg_id', ascending: true);
      groups = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      // No groups readable: the card then offers nothing to pick and the
      // server keeps using the name rule.
    }
    if (!mounted) return;
    setState(() {
      _admMode = (s['admission_number_mode'] ?? 'MANUAL').toUpperCase() == 'AUTO' ? 'AUTO' : 'MANUAL';
      _arrearFirst = (s['fee_collection_arrear_first'] ?? 'true').toLowerCase() != 'false';
      _feeGroups = groups;
      for (final t in const ['A', 'S', 'M']) {
        _advRoute[t] =
            int.tryParse((s[SupabaseService.advanceRouteKey(t)] ?? '').trim());
      }
      for (final g in groups) {
        final id = g['fg_id'] as int?;
        if (id == null) continue;
        _lhName[id] = TextEditingController(
            text: s[SupabaseService.letterheadNameKey(id)] ?? '');
        _lhAddr[id] = TextEditingController(
            text: s[SupabaseService.letterheadAddrKey(id)] ?? '');
        _lhBanner[id] = TextEditingController(
            text: s[SupabaseService.letterheadBannerKey(id)] ?? '');
      }
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
      for (final t in const ['A', 'S', 'M']) {
        // Empty means "not configured", which is a real choice: it puts that
        // advance type back on the name rule rather than pinning it.
        await SupabaseService.setInstitutionSetting(
            insId, SupabaseService.advanceRouteKey(t),
            _advRoute[t]?.toString() ?? '', by: auth.userName);
      }
      for (final id in isSchool ? const <int>[] : _lhName.keys) {
        await SupabaseService.setInstitutionSetting(
            insId,
            SupabaseService.letterheadNameKey(id),
            _lhName[id]!.text.trim(),
            by: auth.userName);
        await SupabaseService.setInstitutionSetting(
            insId,
            SupabaseService.letterheadAddrKey(id),
            _lhAddr[id]!.text.trim(),
            by: auth.userName);
        await SupabaseService.setInstitutionSetting(
            insId,
            SupabaseService.letterheadBannerKey(id),
            _lhBanner[id]!.text.trim(),
            by: auth.userName);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Utilities saved'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the settings. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rendered inside the dashboard's SingleChildScrollView (unbounded height),
    // so it must size to its content — no Expanded / inner scroll view.
    if (_loading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 80.h),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    // Two columns on a wide window, one on a laptop. These are short settings
    // and the old single column pushed Save four cards down the page, so it
    // was reached by scrolling past everything every time.
    return LayoutBuilder(builder: (context, c) {
      final twoUp = c.maxWidth >= 1180;
      final cardW = twoUp ? (c.maxWidth - AppUI.gap) / 2 : c.maxWidth;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- header: what this screen is, and the one button it has -----
          Container(
            margin: EdgeInsets.only(bottom: AppUI.gap),
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: AppUI.cardHeader(
              icon: 'setting-2',
              title: 'Utilities',
              subtitle: 'How this institution behaves at the counter.',
              trailing: [
              // Save sits WITH the title, not at the end of the page: every
              // card on this screen is one field, and hunting for the button
              // after a scroll is how a change gets left unsaved.
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? SizedBox(
                        width: 15.w,
                        height: 15.w,
                        child: const CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const AppIcon('document', size: 16, color: Colors.white),
                label: Text(_saving ? 'Saving…' : AppText.save),
              ),
            ]),
          ),

          Wrap(
            spacing: AppUI.gap,
            runSpacing: AppUI.gap,
            children: [
              SizedBox(width: cardW, child: _admissionCard()),
              SizedBox(width: cardW, child: _feeCollectionCard()),
              // A school has no Mess / Student / Admission advance at the
              // counter (its advance fees have their own series), so the
              // settlement-group mapping is college only.
              if (!isSchool) SizedBox(width: cardW, child: _advanceSettlementCard()),
              // A school's receipts always carry the institution's own name,
              // address and logo (user, 2026-11-18).
              if (!isSchool) SizedBox(width: cardW, child: _letterheadCard()),
            ],
          ),
          SizedBox(height: 24.h),
        ],
      );
    });
  }

  // ── building blocks ─────────────────────────────────────────────────────────
  /// One setting, in its own colour.
  ///
  /// Four white cards on a white page read as one grey slab, and nothing on
  /// them said what the setting is currently SET to without reading the
  /// control. So each card carries a tint of its own, a tinted header band,
  /// and [state] -- a pill saying what it is doing right now.
  Widget _sectionCard({
    required Widget chip,
    required String title,
    required String desc,
    required Widget child,
    Color tint = AppColors.accent,
    String? state,
  }) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 14.h),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.divider)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                ),
                child: chip,
              ),
              SizedBox(width: 12.w),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title, style: AppUI.cardTitle),
                    SizedBox(height: 2.h),
                    Text(desc, style: AppUI.muted.copyWith(height: 1.35)),
                  ])),
              if (state != null) ...[
                SizedBox(width: 10.w),
                AppUI.chip(state, AppStatus.info),
              ],
            ]),
          ),
          Padding(
            padding: EdgeInsets.all(AppUI.cardPad),
            child: child,
          ),
        ],
      ),
    );
  }

  Widget _admissionCard() {
    return _sectionCard(
      chip: Text('#',
          style: TextStyle(
              fontSize: 17.sp,
              fontWeight: FontWeight.w800,
              color: AppColors.accent)),
      tint: AppColors.accent,
      state: _admMode == 'AUTO' ? 'AUTOMATIC' : 'MANUAL',
      title: 'Admission Number',
      desc: schoolTerm('How the register number is filled on the Admission Entry and Fast Admission forms.'),
      // Two mutually exclusive modes with a one-line consequence each: a
      // segmented control says that in a third of the height two radio blocks
      // took, and the preview shows what the field will actually do.
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _seg('Automatic', 'AUTO')),
          SizedBox(width: 8.w),
          Expanded(child: _seg('Manual', 'MANUAL')),
        ]),
        SizedBox(height: 12.h),
        Row(children: [
          Expanded(
            child: Text(
                _admMode == 'AUTO'
                    ? 'The next number comes from the sequence and the field is locked.'
                    : 'The next number is suggested; the user may edit or overwrite it.',
                style: AppUI.muted),
          ),
          SizedBox(width: 12.w),
          _admMode == 'AUTO' ? _autoPreview(true) : _manualPreview(true),
        ]),
      ]),
    );
  }

  Widget _letterheadCard() {
    final overrides = _lhName.entries
        .where((e) => e.value.text.trim().isNotEmpty)
        .length;
    return _sectionCard(
      chip: const AppIcon('document-text', size: 17, color: AppColors.warning),
      tint: AppColors.warning,
      state: overrides == 0 ? 'INSTITUTION' : '$overrides CUSTOM',
      title: 'Receipt Letterhead',
      desc: 'A receipt is issued by whoever collected it. Give a fee group its '
          'own name and address and its receipts print that instead of the '
          "institution's — leave both empty to keep the institution's.",
      child: Column(children: [
        for (var i = 0; i < _feeGroups.length; i++) ...[
          if (i > 0)
            Divider(height: 18.h, color: AppColors.divider),
          _letterheadRow(_feeGroups[i]),
        ],
      ]),
    );
  }

  Widget _letterheadRow(Map<String, dynamic> g) {
    final id = g['fg_id'] as int?;
    if (id == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((g['fgdesc']?.toString() ?? '').toUpperCase(), style: AppUI.caps),
      SizedBox(height: 6.h),
      TextField(
        controller: _lhName[id],
        enabled: !_saving,
        style: AppUI.fieldText(context),
        decoration: _lhDec("Enter letterhead name (leave blank to use the institution's)"),
      ),
      SizedBox(height: 6.h),
      TextField(
        controller: _lhAddr[id],
        enabled: !_saving,
        maxLines: 2,
        style: AppUI.fieldText(context),
        decoration: _lhDec('Enter letterhead address (optional)'),
      ),
      SizedBox(height: 6.h),
      // The printed header image. Receipts used to pick this by matching the
      // institution's NAME, so a hostel receipt would have carried the college
      // banner; here it is mapped to the fee group instead.
      // School: no bundled college banners or typed paths -- upload an image.
      if (isSchool)
        _uploadRow(id)
      else
      Row(children: [
        Expanded(
          child: TextField(
            controller: _lhBanner[id],
            enabled: !_saving,
            style: AppUI.fieldText(context),
            decoration: _lhDec('Enter header image path or https URL'),
          ),
        ),
        SizedBox(width: 6.w),
        PopupMenuButton<String>(
          tooltip: 'Bundled banners',
          enabled: !_saving,
          itemBuilder: (_) => [
            const PopupMenuItem(value: '', child: Text('None (text header)')),
            for (final e in SupabaseService.kBundledBanners.entries)
              PopupMenuItem(value: e.key, child: Text(e.value)),
          ],
          onSelected: (v) => setState(() => _lhBanner[id]!.text = v),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(Icons.image_outlined,
                size: 16.sp, color: AppColors.textSecondary),
          ),
        ),
      ]),
      if ((_lhBanner[id]?.text.trim() ?? '').isNotEmpty) ...[
        SizedBox(height: 6.h),
        Container(
          height: 46.h,
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.all(4.w),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.border),
          ),
          child: _lhBanner[id]!.text.trim().startsWith('http')
              ? Image.network(_lhBanner[id]!.text.trim(),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text('Image could not be loaded. Check the URL.',
                      style: AppUI.muted.copyWith(color: AppColors.error)))
              : Image.asset(_lhBanner[id]!.text.trim(),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text(
                      'Bundled image not found. Check the asset path.',
                      style: AppUI.muted.copyWith(color: AppColors.error))),
        ),
      ],
    ]);
  }

  /// fg_id currently uploading.
  int? _uploading;

  Widget _uploadRow(int id) {
    final has = (_lhBanner[id]?.text.trim() ?? '').isNotEmpty;
    final busy = _uploading == id;
    return Row(children: [
      OutlinedButton.icon(
        onPressed: _saving || _uploading != null ? null : () => _uploadHeader(id),
        icon: busy
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.upload_rounded, size: 16),
        label: Text(busy ? 'Uploading...' : (has ? 'Replace Header Image' : 'Upload Header Image')),
      ),
      SizedBox(width: 8.w),
      if (has)
        TextButton.icon(
          onPressed: _saving || _uploading != null ? null : () => _removeHeader(id),
          icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.error),
          label: const Text('Remove', style: TextStyle(color: AppColors.error)),
        )
      else
        Flexible(
          child: Text('PNG or JPG, about 4:1 wide. Without an image, the name and address are printed.',
              overflow: TextOverflow.ellipsis,
              style: AppUI.muted),
        ),
    ]);
  }

  /// Pick an image, store it in the InstitutionLogos bucket under
  /// letterheads/, and save its public URL as this fee group's header at once
  /// (no separate Save needed).
  Future<void> _uploadHeader(int id) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg'], withData: true);
    final f = picked?.files.single;
    if (f == null) return;
    setState(() => _uploading = id);
    try {
      final bytes = f.bytes ?? await File(f.path!).readAsBytes();
      if (bytes.length > 2 * 1024 * 1024) throw const _UploadRefused('The image is larger than 2 MB. Choose a smaller file.');
      final ext = (f.extension ?? 'png').toLowerCase() == 'jpeg' ? 'jpg' : (f.extension ?? 'png').toLowerCase();
      final code = (auth.inscode ?? 'ins$insId').replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
      final path = 'letterheads/${code}_fg$id.$ext';
      final bucket = SupabaseService.client.storage.from('InstitutionLogos');
      await bucket.uploadBinary(path, bytes,
          fileOptions: FileOptions(upsert: true, contentType: ext == 'jpg' ? 'image/jpeg' : 'image/png'));
      // The version stamp makes receipts fetch the new image after a replace.
      final url = '${bucket.getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';
      await SupabaseService.setInstitutionSetting(insId, SupabaseService.letterheadBannerKey(id), url, by: auth.userName);
      if (!mounted) return;
      setState(() => _lhBanner[id]!.text = url);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Header image uploaded'), backgroundColor: AppColors.success));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(e is _UploadRefused ? e.message : 'Could not upload the image. ${friendlyError(e)}'),
                backgroundColor: AppColors.error));
      }
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  Future<void> _removeHeader(int id) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _uploading = id);
    try {
      await SupabaseService.setInstitutionSetting(insId, SupabaseService.letterheadBannerKey(id), '', by: auth.userName);
      if (mounted) setState(() => _lhBanner[id]!.text = '');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not remove the header image. ${friendlyError(e)}'), backgroundColor: AppColors.error));
      }
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  InputDecoration _lhDec(String hint) => AppUI.field(context, hint);

  /// One half of the Admission Number segmented control.
  Widget _seg(String label, String value) {
    final on = _admMode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: _saving ? null : () => setState(() => _admMode = value),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 10.h),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? AppColors.accent : Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: on ? AppColors.accent : AppColors.border),
        ),
        child: Text(label,
            style: AppUI.label.copyWith(
                color: on ? Colors.white : AppColors.textSecondary)),
      ),
    );
  }

  Widget _advanceSettlementCard() {
    return _sectionCard(
      chip: const AppIcon('bank', size: 17, color: AppColors.success),
      tint: AppColors.success,
      state: '${_advRoute.values.where((v) => v != null).length}/3 SET',
      title: 'Advance Settlement',
      desc: 'Which fee group each kind of advance is banked under. The group '
          'decides the bank account (Setup → Fee Master → Fee Group) and, for an '
          'online payment, the Paytm merchant registered against that account '
          '(Setup → Fee Master → Fee Group → Manage bank accounts).',
      child: Column(children: [
        _advRouteRow('M', 'Mess Advance',
            'Collected for the mess. Normally the hostel group.'),
        Divider(height: 18.h, color: AppColors.divider),
        _advRouteRow('S', 'Student Advance',
            'Held against a student, spent later at Fee Collection.'),
        Divider(height: 18.h, color: AppColors.divider),
        _advRouteRow('A', 'Admission Advance',
            'Itemised against fee types — used only when none of them '
            'resolves a group.'),
      ]),
    );
  }

  Widget _advRouteRow(String type, String title, String subtitle) {
    final fgId = _advRoute[type];
    final chosen = _feeGroups.firstWhere((g) => g['fg_id'] == fgId,
        orElse: () => const <String, dynamic>{});
    final bankMissing = chosen.isNotEmpty && chosen['ban_id'] == null;

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppUI.label.copyWith(fontSize: 14.sp)),
          SizedBox(height: 3.h),
          Text(subtitle, style: AppUI.muted),
          if (bankMissing) ...[
            SizedBox(height: 4.h),
            Row(children: [
              Icon(Icons.warning_amber_rounded,
                  size: 14.sp, color: AppColors.warning),
              SizedBox(width: 5.w),
              Expanded(
                child: Text(
                    'No bank account is assigned to ${chosen['fgdesc']}, so advances '
                    'routed there are not banked. Assign one in Setup → Fee Master → Fee Group.',
                    style: AppUI.muted.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColors.warning)),
              ),
            ]),
          ],
        ]),
      ),
      SizedBox(width: 12.w),
      SizedBox(
        width: 190.w,
        // A CONTROLLED DropdownButton, not DropdownButtonFormField.
        //
        // The form-field variant keeps its own copy of the value and only
        // reads `initialValue` on its first build, so with three identical
        // unkeyed fields in a column the value a row DISPLAYS can drift from
        // the key it WRITES -- which is how the mess advance ended up saved
        // against the admission key. `value:` is read on every build, so what
        // is on screen is always what is in _advRoute, and the ValueKey stops
        // one row's state ever being reused by another.
        child: Container(
          key: ValueKey('advroute-$type'),
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(
                color: fgId != null
                    ? AppColors.primary.withValues(alpha: 0.55)
                    : AppColors.border),
          ),
          child: DropdownButton<int?>(
            value: fgId,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            padding: EdgeInsets.symmetric(vertical: 4.h),
            style: AppUI.fieldText(context, filled: fgId != null),
            items: [
              DropdownMenuItem<int?>(
                value: null,
                child: Text('Automatic (from fee group names)',
                    style: AppUI.fieldText(context).copyWith(color: AppColors.textLight)),
              ),
              for (final g in _feeGroups)
                DropdownMenuItem<int?>(
                  value: g['fg_id'] as int?,
                  child: Text(g['fgdesc']?.toString() ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.fieldText(context, filled: true)),
                ),
            ],
            onChanged: _saving ? null : (v) => setState(() => _advRoute[type] = v),
          ),
        ),
      ),
    ]);
  }

  Widget _feeCollectionCard() {
    return _sectionCard(
      chip: Text('₹',
          style: TextStyle(
              fontSize: 17.sp,
              fontWeight: FontWeight.w800,
              color: AppColors.today)),
      tint: AppColors.today,
      state: _arrearFirst ? 'ARREAR FIRST' : 'ANY ORDER',
      title: 'Fee Collection',
      desc: 'Controls how outstanding dues are prioritised at the collection counter.',
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Collect Arrears Before Regular Fees', style: AppUI.label.copyWith(fontSize: 14.sp)),
          SizedBox(height: 3.h),
          Text('When a student has arrear dues, the collection screen opens on Arrear first so arrears are cleared before regular fees.',
              style: AppUI.muted),
        ])),
        SizedBox(width: 16.w),
        Switch(
          value: _arrearFirst,
          activeThumbColor: Colors.white,
          activeTrackColor: AppColors.accent,
          onChanged: (v) => setState(() => _arrearFirst = v),
        ),
      ]),
    );
  }

  Widget _numChip(String t, Color fg, {Color? bg}) => Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
        decoration: BoxDecoration(color: bg ?? Colors.white, borderRadius: BorderRadius.circular(7.r), border: Border.all(color: AppColors.border)),
        child: Text(t, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w800, color: fg, letterSpacing: 1)),
      );

  /// Automatic → shows the sequence auto-advancing, with a lock (field locked).
  Widget _autoPreview(bool active) {
    final fg = active ? AppColors.accent : AppColors.textLight;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: active ? AppColors.accent.withValues(alpha: 0.06) : AppColors.surface,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: active ? AppColors.accent.withValues(alpha: 0.30) : AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _numChip('001', fg),
        SizedBox(width: 8.w),
        Icon(Icons.arrow_forward, size: 15.sp, color: fg),
        SizedBox(width: 8.w),
        _numChip('002', fg),
        SizedBox(width: 12.w),
        Icon(Icons.lock, size: 16.sp, color: fg),
      ]),
    );
  }

  /// Manual → shows an editable suggested value with a pencil affordance.
  Widget _manualPreview(bool active) {
    final fg = active ? AppColors.accent : AppColors.textLight;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 96.w,
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8.r), border: Border.all(color: active ? AppColors.accent : AppColors.border, width: active ? 1.4 : 1)),
        child: Text('001', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 1)),
      ),
      SizedBox(width: 10.w),
      Container(
        width: 34.w,
        height: 34.w,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: active ? AppColors.accent.withValues(alpha: 0.10) : AppColors.surface, borderRadius: BorderRadius.circular(8.r), border: Border.all(color: active ? AppColors.accent.withValues(alpha: 0.30) : AppColors.border)),
        child: Icon(Icons.edit, size: 15.sp, color: fg),
      ),
    ]);
  }
}

/// A header image the app refuses before uploading (too large). Its message
/// is written for the user, so it is shown as it is.
class _UploadRefused implements Exception {
  const _UploadRefused(this.message);
  final String message;
}
