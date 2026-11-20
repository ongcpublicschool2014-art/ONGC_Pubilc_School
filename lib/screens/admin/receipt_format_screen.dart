import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/receipt_format_service.dart';
import '../../services/tc_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../utils/tc_fields.dart';
import '../../utils/tc_pdf.dart';
import '../../widgets/app_ui.dart';
import '../tc/tc_pdf_designer.dart';

/// Setup -> Receipt Format: the school's own fee receipt. Upload it as a PDF
/// (a scan of the pre-printed receipt book, or the school's own design) and
/// place each value on it; every receipt then prints on it. Remove it, or
/// switch it off, to print the built-in receipt again.
class ReceiptFormatScreen extends StatefulWidget {
  const ReceiptFormatScreen({super.key});
  @override
  State<ReceiptFormatScreen> createState() => _ReceiptFormatScreenState();
}

class _ReceiptFormatScreenState extends State<ReceiptFormatScreen> {
  bool _loading = true, _busy = false;
  Map<String, dynamic>? _fmt;
  Uint8List? _bytes;

  bool get _active => _fmt?['active'] != false;
  int get _placed => TcPdfLayout.fromJson(_fmt?['layout']).fields.length;

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
      final f = await ReceiptFormatService.format(withContent: true);
      final b64 = f?['content_b64']?.toString() ?? '';
      if (mounted) {
        setState(() {
          _fmt = f;
          _bytes = b64.isEmpty ? null : base64Decode(b64);
        });
      }
    } catch (e) {
      _snack('Could not load the receipt format. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _upload() async {
    final pick = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null || !mounted) return;
    if (_fmt != null &&
        !await _confirm('Replace Receipt Format?',
            'The fields already placed are kept. Check their places on the new file, then Save Layout.', 'Replace')) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ReceiptFormatService.saveFormat(f.name, bytes);
      _snack(_placed == 0
          ? 'Receipt format uploaded. Now place each value on the page, then click Save Layout.'
          : 'Receipt format replaced. Check the field places, then Save Layout.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('That file could not be read as a PDF. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setActive(bool on) async {
    setState(() => _busy = true);
    try {
      await ReceiptFormatService.setActive(on);
      _fmt?['active'] = on;
      _snack(on ? 'Receipts now print on the school\'s format.' : 'Receipts now print in the built-in design.', AppColors.success);
    } catch (e) {
      _snack('Could not change it. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (!await _confirm('Remove Receipt Format?',
        'The uploaded file and the field places are deleted. Receipts print in the built-in design.', 'Remove')) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ReceiptFormatService.remove();
      _snack('Receipt format removed.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Could not remove it. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _saveLayout(TcPdfLayout layout) async {
    try {
      await ReceiptFormatService.saveLayout(layout);
      _fmt?['layout'] = layout.toJson();
      setState(() {});
      _snack('Layout saved with ${layout.fields.length} field(s).', AppColors.success);
      return true;
    } catch (e) {
      _snack('Could not save the layout. ${friendlyError(e)}', AppColors.error);
      return false;
    }
  }

  Future<void> _testPrint(TcPdfLayout layout) async {
    try {
      final row = {for (final k in layout.keys) k: kReceiptSamples[k] ?? k};
      final (bytes, paper) = await TcPdf.build(_bytes!, layout, [row], guides: true);
      if (await TcService.toPrinter(bytes, paper, 'Receipt Alignment Test')) {
        _snack('Test page sent to the printer. Hold it against a receipt; if every value is off by the same amount, '
            'set Printer Adjustment and Save Layout.', AppColors.success);
      }
    } catch (e) {
      _snack('Could not make the test print. ${friendlyError(e)}', AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: EdgeInsets.all(AppUI.cardPad),
          decoration: AppUI.card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AppUI.cardHeader(
              icon: 'document-upload',
              title: 'Receipt Format',
              subtitle: 'The school\'s own fee receipt: upload it as a PDF (a scan of the receipt book, or your own design) '
                  'and place each value on it. Every receipt then prints on it.',
              trailing: [
                if (_fmt != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _remove,
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Remove Format'),
                  ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _upload,
                  icon: _busy
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.upload_file, size: 16),
                  label: Text(_fmt == null ? 'Upload Format' : 'Replace Format'),
                ),
              ],
            ),
            SizedBox(height: 16.h),
            if (_fmt == null)
              AppUI.empty(
                title: 'Receipts print in the built-in design',
                why: 'Upload the school\'s receipt as a PDF to print every receipt on it instead.',
                icon: 'document-upload',
              )
            else
              Row(children: [
                AppUI.iconTile('receipt-2'),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${_fmt!['filename']}', style: AppUI.label, overflow: TextOverflow.ellipsis),
                    Text('Uploaded by ${_fmt!['uploadedby'] ?? ''} on ${tcDate(_fmt!['uploadedat'])}', style: AppUI.muted),
                  ]),
                ),
                SizedBox(width: 12.w),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: Text('Print receipts on this format', style: AppUI.label, overflow: TextOverflow.ellipsis)),
                      SizedBox(width: 8.w),
                      Switch(value: _active, onChanged: _busy ? null : _setActive),
                    ]),
                    Text(
                      !_active
                          ? 'Off: receipts print in the built-in design.'
                          : _placed == 0
                              ? 'No fields placed yet: receipts print in the built-in design until you Save Layout.'
                              : 'On: every receipt prints on this format.',
                      style: AppUI.muted,
                      textAlign: TextAlign.right,
                    ),
                  ]),
                ),
              ]),
          ]),
        ),
        if (_bytes != null) ...[
          SizedBox(height: AppUI.gap),
          Container(
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AppUI.cardHeader(
                icon: 'edit-2',
                title: 'Place the Fields',
                subtitle: 'Put each value where it should print; {Fee Lines} prints one line per fee with its amount. '
                    'Test Print prints the values with a mm ruler: hold it against a receipt, correct any shift, then Save Layout.',
              ),
              SizedBox(height: 14.h),
              TcPdfDesigner(
                key: ValueKey('${_fmt!['uploadedat']}'),
                pdf: _bytes!,
                layout: TcPdfLayout.fromJson(_fmt!['layout']),
                onSave: _saveLayout,
                onTest: _testPrint,
                keys: kReceiptFieldKeys,
                samples: kReceiptSamples,
                listKey: kReceiptLinesKey,
                bookName: 'receipt books',
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}
