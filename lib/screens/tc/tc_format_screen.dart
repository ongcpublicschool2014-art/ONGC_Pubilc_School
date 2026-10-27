import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/tc_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../utils/tc_docx.dart';
import '../../utils/tc_fields.dart';
import '../../utils/tc_pdf.dart';
import '../../widgets/app_ui.dart';
import 'tc_pdf_designer.dart';

/// TC -> TC Format: the school's own TC, either
///  * a Word (.docx) template -- wherever data goes, type a placeholder in
///    braces: {Student Name}, {DOB in Words}, {TC No} ... Placeholders the app
///    does not know become extra fields on the TC Certificate screen; or
///  * a PDF -- each field is placed on the page here (like the old app's
///    alignment set-up), optionally printing only the values on TC books.
/// {Copy} prints ORIGINAL / DUPLICATE, {Print Date} today's date.
class TcFormatScreen extends StatefulWidget {
  const TcFormatScreen({super.key});
  @override
  State<TcFormatScreen> createState() => _TcFormatScreenState();
}

class _TcFormatScreenState extends State<TcFormatScreen> {
  bool _loading = true, _busy = false;
  Map<String, dynamic>? _fmt;
  Uint8List? _bytes;

  bool get _isPdf => TcService.isPdf(_fmt);

  @override
  void initState() {
    super.initState();
    _load();
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
      final f = await TcService.format(withContent: true);
      final b64 = f?['content_b64']?.toString() ?? '';
      if (mounted) {
        setState(() {
          _fmt = f;
          _bytes = b64.isEmpty ? null : base64Decode(b64);
        });
      }
    } catch (e) {
      _snack('Could not load. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    final pick = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['docx', 'pdf'], withData: true);
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) return;
    final pdf = f.name.toLowerCase().endsWith('.pdf');
    if (!mounted) return;
    if (_fmt != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace the TC format?'),
          content: Text(_isPdf
              ? 'The fields placed on the current PDF will be cleared. Saved certificates are not affected.'
              : 'Saved certificates are not affected; they print on the new format.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await TcService.saveFormat(f.name, bytes);
      if (pdf) {
        _snack('PDF format uploaded -- now place each field on the page and Save layout.', AppColors.success);
      } else {
        final ph = TcDocx.placeholders(bytes);
        _snack(ph.isEmpty
            ? 'Uploaded, but no {placeholders} were found -- type them where the data should go, e.g. {Student Name}.'
            : 'TC format uploaded -- ${ph.length} placeholder(s) found.',
            ph.isEmpty ? AppColors.warning : AppColors.success);
      }
      await _load();
    } catch (e) {
      _snack(pdf
          ? 'That file could not be read as a PDF. ${friendlyError(e)}'
          : 'That file could not be read as a Word .docx document. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String name, List<int> bytes) async {
    try {
      final out = await TcService.saveAndOpen(name, bytes);
      if (out != null) _snack('Saved to $out', AppColors.success);
    } catch (e) {
      _snack('Could not save. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<bool> _saveLayout(TcPdfLayout layout) async {
    try {
      await TcService.saveLayout(layout);
      _fmt?['layout'] = layout.toJson();
      _snack('Layout saved -- ${layout.fields.length} field(s).', AppColors.success);
      return true;
    } catch (e) {
      _snack('Could not save the layout. ${friendlyError(e)}', AppColors.error);
      return false;
    }
  }

  Future<void> _testPrint(TcPdfLayout layout) async {
    try {
      final row = {for (final k in layout.keys) k: kTcPdfSamples[k] ?? k};
      final bytes = await TcPdf.fill(_bytes!, layout, [row]);
      await _open('TC_Format_Test.pdf', bytes);
    } catch (e) {
      _snack('Could not make the test print. ${friendlyError(e)}', AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final ph = [for (final x in (_fmt?['placeholders'] as List? ?? const [])) '$x'];
    final known = {...kTcFieldKeys, ...kTcPrintTimeKeys};
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: EdgeInsets.all(AppUI.cardPad),
          decoration: AppUI.card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AppUI.cardHeader(
              icon: 'document-upload',
              title: 'TC Format',
              subtitle: 'The school\'s own transfer certificate: a Word (.docx) file with {placeholders} where the data goes, '
                  'or a PDF on which you place each field.',
              trailing: [
                PopupMenuButton<String>(
                  tooltip: 'Download a Word sample to start from',
                  onSelected: (v) => v == 'STATE'
                      ? _open('TC_Format_State_Board.docx', TcDocx.sampleStateBoard(studyRows: kTcStudyRows, studyCols: kTcStudyCols))
                      : _open('TC_Format_CBSE.docx', TcDocx.sample(kTcSampleLines)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'CBSE', child: Text('CBSE format')),
                    PopupMenuItem(value: 'STATE', child: Text('State board format (TN / Puducherry, as the old app) -- delete the Hr. Sec. line if not needed')),
                  ],
                  child: IgnorePointer(
                    child: OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Word sample'),
                    ),
                  ),
                ),
                if (_bytes != null)
                  OutlinedButton.icon(
                    onPressed: () => _open('${_fmt!['filename'] ?? (_isPdf ? 'TC_Format.pdf' : 'TC_Format.docx')}', _bytes!),
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: const Text('Open current'),
                  ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _upload,
                  icon: _busy
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.upload_file, size: 16),
                  label: Text(_fmt == null ? 'Upload format' : 'Replace format'),
                ),
              ],
            ),
            SizedBox(height: 16.h),
            if (_fmt == null)
              AppUI.empty(
                title: 'No TC format uploaded',
                why: 'Upload a Word .docx with {placeholders} (start from the Word sample), '
                    'or the school\'s TC as a PDF and place each field on it.',
                icon: 'document-upload',
              )
            else ...[
              Row(children: [
                AppUI.iconTile('document-text'),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(child: Text('${_fmt!['filename']}', style: AppUI.label, overflow: TextOverflow.ellipsis)),
                      SizedBox(width: 8.w),
                      AppUI.chip(_isPdf ? 'PDF' : 'WORD', _isPdf ? AppStatus.danger : AppStatus.info),
                    ]),
                    Text('Uploaded by ${_fmt!['uploadedby'] ?? ''} on ${tcDate(_fmt!['uploadedat'])}', style: AppUI.muted),
                  ]),
                ),
              ]),
              if (!_isPdf) ...[
                SizedBox(height: 14.h),
                AppUI.sectionLabel('Placeholders in this format (${ph.length})'),
                Wrap(spacing: 8.w, runSpacing: 8.h, children: [
                  for (final k in ph)
                    Tooltip(
                      message: known.contains(k) ? 'Filled by the app' : 'Not a standard field -- typed on TC Certificate',
                      child: AppUI.chip('{$k}', known.contains(k) ? AppStatus.success : AppStatus.info),
                    ),
                ]),
              ],
            ],
          ]),
        ),
        SizedBox(height: AppUI.gap),
        if (_isPdf && _bytes != null)
          Container(
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AppUI.cardHeader(
                icon: 'edit-2',
                title: 'Place the fields',
                subtitle: 'Put each value where it should print. Use Test print to check on paper, then Save layout.',
              ),
              SizedBox(height: 14.h),
              TcPdfDesigner(
                key: ValueKey('${_fmt!['uploadedat']}'),
                pdf: _bytes!,
                layout: TcPdfLayout.fromJson(_fmt!['layout']),
                onSave: _saveLayout,
                onTest: _testPrint,
              ),
            ]),
          )
        else
          Container(
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppUI.cardHeader(icon: 'tag', title: 'Placeholders you can use', subtitle: 'Click one to copy it, then paste it into the Word file.'),
              SizedBox(height: 12.h),
              for (final g in {for (final f in kTcFields) f.group}) ...[
                AppUI.sectionLabel(g),
                Wrap(spacing: 8.w, runSpacing: 8.h, children: [
                  for (final f in kTcFields.where((f) => f.group == g && (g != kTcStudyGroup || f.key.startsWith('Study 1 ')))) _copyChip(f.key),
                ]),
                if (g == kTcStudyGroup) ...[
                  SizedBox(height: 6.h),
                  Text('One row per school. Row 1 is shown; rows 2 to $kTcStudyRows are {Study 2 School} ... {Study $kTcStudyRows Medium}.', style: AppUI.muted),
                ],
                SizedBox(height: 12.h),
              ],
              AppUI.sectionLabel('At print time'),
              Wrap(spacing: 8.w, runSpacing: 8.h, children: [_copyChip('Copy'), _copyChip('Print Date')]),
              SizedBox(height: 10.h),
              Text('{Copy} prints ORIGINAL the first time and DUPLICATE on reprints. Any other {name} you add becomes an extra field to fill on TC Certificate.',
                  style: AppUI.muted),
            ]),
          ),
      ]),
    );
  }

  Widget _copyChip(String k) => ActionChip(
        label: Text('{$k}'),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: '{$k}'));
          _snack('{$k} copied.', AppColors.success);
        },
      );
}
