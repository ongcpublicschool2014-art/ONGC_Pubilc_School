import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../services/tc_service.dart';
import '../../utils/auth_provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/docx_to_pdf.dart';
import '../../utils/friendly_error.dart';
import '../../utils/tc_autoplace.dart';
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
  Map<String, dynamic>? _fmt; // the chosen format, with its file
  Uint8List? _bytes;

  // A school can keep several formats, each for some standards (Immaculate
  // X for IX-X, XII for XI-XII); the one without standards is the default.
  List<Map<String, dynamic>> _formats = [];
  int? _selId;
  List<String> _stdNames = [];
  final _nameCtl = TextEditingController();
  Set<String> _selStd = {};

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

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  Future<List<String>> _loadStandards() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return [];
    try {
      final rows = await SupabaseService.fromSchema('course').select('courname, ordid').eq('ins_id', insId).eq('activestatus', 1);
      final list = List<Map<String, dynamic>>.from(rows as List)
        ..sort((a, b) => ((a['ordid'] as num?) ?? 1 << 30).compareTo((b['ordid'] as num?) ?? 1 << 30));
      return [for (final r in list) '${r['courname'] ?? ''}'.trim()].where((x) => x.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _load({int? select}) async {
    setState(() => _loading = true);
    try {
      final list = await TcService.formats();
      final ids = [for (final f in list) TcService.fmtId(f)];
      final id = select ?? (ids.contains(_selId) ? _selId : (ids.isEmpty ? null : ids.first));
      final f = id == null ? null : await TcService.format(withContent: true, tcfId: id);
      final b64 = f?['content_b64']?.toString() ?? '';
      if (_stdNames.isEmpty) _stdNames = await _loadStandards();
      if (mounted) {
        setState(() {
          _formats = list;
          _selId = id;
          _fmt = f;
          _bytes = b64.isEmpty ? null : base64Decode(b64);
          _nameCtl.text = '${f?['name'] ?? ''}';
          _selStd = TcService.fmtStandards(f).toSet();
        });
      }
    } catch (e) {
      _snack('Could not load the TC format. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// [asNew]: add another format (e.g. the XII one) instead of replacing the
  /// chosen format's file.
  Future<void> _upload({bool asNew = false}) async {
    final pick = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['docx', 'pdf'], withData: true);
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    var bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) return;
    var name = f.name;
    var pdf = name.toLowerCase().endsWith('.pdf');
    var fromWord = false;
    var autoFields = <TcPdfField>[];
    if (!mounted) return;
    // A Word file can be used like a PDF too: turned into a PDF on this PC
    // and the fields placed on its page. Or, as before, its {placeholders}
    // are filled in.
    if (!pdf) {
      List<String> found;
      try {
        found = TcDocx.placeholders(bytes);
      } catch (_) {
        found = const [];
      }
      final place = await _askWordUse(found.length);
      if (place == null) return;
      if (place) {
        setState(() => _busy = true);
        try {
          final docx = bytes;
          bytes = await DocxToPdf.convert(docx);
          // Fill the page straight away: each blank after a label the app
          // knows ("Name of the pupil") gets its field.
          autoFields = TcAutoPlace.fields(await TcAutoPlace.blanks(docx));
        } catch (e) {
          _snack(e is DocxToPdfException ? e.message : 'Could not turn the Word file into a PDF. ${friendlyError(e)}', AppColors.error);
          if (mounted) setState(() => _busy = false);
          return;
        }
        if (mounted) setState(() => _busy = false);
        name = '${name.replaceFirst(RegExp(r'\.docx$', caseSensitive: false), '')}.pdf';
        pdf = true;
        fromWord = true;
      }
    }
    if (!mounted) return;
    if (_fmt != null && !asNew) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace TC Format?'),
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
      final adding = asNew || _selId == null;
      final id = await TcService.saveFormat(name, bytes,
          tcfId: adding ? null : _selId, newName: adding ? f.name.replaceFirst(RegExp(r'\.(docx|pdf)$', caseSensitive: false), '') : null);
      if (autoFields.isNotEmpty) await TcService.saveLayout(TcPdfLayout(fields: autoFields), tcfId: id);
      if (pdf) {
        _snack(fromWord
            ? (autoFields.isNotEmpty
                ? 'Word file uploaded. ${autoFields.length} field(s) were placed from its labels: check them, place any '
                    'others, then click Save Layout.'
                : 'Word file uploaded as a PDF. Now place each field on the page, then click Save Layout.')
            : 'PDF format uploaded. Now place each field on the page, then click Save Layout.', AppColors.success);
      } else {
        final ph = TcDocx.placeholders(bytes);
        _snack(ph.isEmpty
            ? 'Format uploaded, but no {placeholders} were found. Type them in the Word file where the data should go, e.g. {Student Name}, then upload it again.'
            : 'TC format uploaded. ${ph.length} placeholder(s) found.',
            ph.isEmpty ? AppColors.warning : AppColors.success);
      }
      await _load(select: id);
    } catch (e) {
      _snack(pdf
          ? 'That file could not be read as a PDF. ${friendlyError(e)}'
          : 'That file could not be read as a Word .docx document. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// How to use an uploaded Word file: true = place fields on its page (like
  /// a PDF), false = fill its {placeholders}, null = cancelled.
  Future<bool?> _askWordUse(int placeholders) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use this Word file how?'),
        content: SizedBox(
          width: 460.w,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Place fields on the page', style: AppUI.label),
            Text('Like a PDF: the page is shown here and you put each value where it should print. '
                'Works with any Word TC, and on TC books with the form already printed.', style: AppUI.muted),
            SizedBox(height: 12.h),
            Text('Fill its {placeholders}', style: AppUI.label),
            Text(placeholders == 0
                ? 'No {placeholders} were found in this file, so nothing would be filled.'
                : '$placeholders placeholder(s) found, such as {Student Name}; each is replaced with the value.', style: AppUI.muted),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          OutlinedButton(onPressed: placeholders == 0 ? null : () => Navigator.pop(ctx, false), child: const Text('Fill Placeholders')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Place Fields')),
        ],
      ),
    );
  }

  Future<void> _open(String name, List<int> bytes) async {
    try {
      final out = await TcService.saveAndOpen(name, bytes);
      if (out != null) _snack('Saved to $out', AppColors.success);
    } catch (e) {
      _snack('Could not save the file. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<bool> _saveLayout(TcPdfLayout layout) async {
    try {
      await TcService.saveLayout(layout, tcfId: _selId);
      _fmt?['layout'] = layout.toJson();
      _snack('Layout saved with ${layout.fields.length} field(s).', AppColors.success);
      return true;
    } catch (e) {
      _snack('Could not save the layout. ${friendlyError(e)}', AppColors.error);
      return false;
    }
  }

  Future<void> _testPrint(TcPdfLayout layout) async {
    try {
      final row = {for (final k in layout.keys) k: kTcPdfSamples[k] ?? k};
      // straight to the printer at actual size, with a mm ruler and a box round
      // each field: hold it against a TC book page to check the alignment
      final (bytes, paper) = await TcPdf.build(_bytes!, layout, [row], guides: true);
      if (await TcService.toPrinter(bytes, paper, 'TC Alignment Test')) {
        _snack('Test page sent to the printer. Hold it against a TC page; if every value is off by the same amount, '
            'set Printer Adjustment and Save Layout.', AppColors.success);
      }
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
              // Short enough for two lines beside the three buttons in a small window.
              subtitle: 'The school\'s own TC: a PDF or Word (.docx) file on which you place each field, '
                  'or a Word file with {placeholders}.',
              trailing: [
                PopupMenuButton<String>(
                  tooltip: 'Download a Word sample to start from',
                  onSelected: (v) => switch (v) {
                    'STATE' => _open('TC_Format_State_Board.docx', TcDocx.sampleStateBoard(studyRows: kTcStudyRows, studyCols: kTcStudyCols)),
                    'IMM_X' => _open('TC_Immaculate_X.docx', TcClientFormats.immaculate(higherSecondary: false)),
                    'IMM_XII' => _open('TC_Immaculate_XII.docx', TcClientFormats.immaculate(higherSecondary: true)),
                    'VES' => _open('TC_VES.docx', TcClientFormats.ves()),
                    'IMM_X_B' => _open('TC_Immaculate_X_blank.docx', TcClientFormats.immaculate(higherSecondary: false, blank: true)),
                    'IMM_XII_B' => _open('TC_Immaculate_XII_blank.docx', TcClientFormats.immaculate(higherSecondary: true, blank: true)),
                    'VES_B' => _open('TC_VES_blank.docx', TcClientFormats.ves(blank: true)),
                    _ => _open('TC_Format_CBSE.docx', TcDocx.sample(kTcSampleLines)),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'CBSE', child: Text('CBSE Format')),
                    PopupMenuItem(
                      value: 'STATE',
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        const Text('State Board Format (Tamil Nadu / Puducherry)'),
                        Text('Delete the Higher Secondary line if not needed.', style: AppUI.muted),
                      ]),
                    ),
                    const PopupMenuDivider(),
                    for (final (v, t) in const [
                      ('IMM_X', 'Immaculate X (State Board)'),
                      ('IMM_XII', 'Immaculate XII (Higher Secondary)'),
                      ('VES', 'VES (CBSE, pre-printed letterhead)'),
                    ])
                      PopupMenuItem(value: v, child: Text('$t -- with {placeholders}')),
                    const PopupMenuDivider(),
                    for (final (v, t) in const [
                      ('IMM_X_B', 'Immaculate X'),
                      ('IMM_XII_B', 'Immaculate XII'),
                      ('VES_B', 'VES'),
                    ])
                      PopupMenuItem(
                        value: v,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text('$t -- blank, to place fields'),
                          Text('Upload it and choose Place Fields: the fields are placed for you.', style: AppUI.muted),
                        ]),
                      ),
                  ],
                  child: IgnorePointer(
                    child: OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Download Word Sample'),
                    ),
                  ),
                ),
                if (_bytes != null)
                  OutlinedButton.icon(
                    onPressed: () => _open('${_fmt!['filename'] ?? (_isPdf ? 'TC_Format.pdf' : 'TC_Format.docx')}', _bytes!),
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: const Text('Open Current Format'),
                  ),
                if (_fmt != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _upload(asNew: true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Format'),
                  ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _upload,
                  icon: _busy
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.upload_file, size: 16),
                  label: Text(_fmt == null ? 'Upload Format' : 'Replace File'),
                ),
              ],
            ),
            SizedBox(height: 16.h),
            if (_formats.isNotEmpty) ...[
              _formatPicker(),
              SizedBox(height: 14.h),
            ],
            if (_fmt == null)
              AppUI.empty(
                title: 'No TC format uploaded',
                why: 'Upload the school\'s TC as a PDF or Word file and place each field on it, '
                    'or a Word .docx with {placeholders} (start from the Word sample).',
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
                      AppUI.chip(_isPdf ? 'PDF' : 'Word', _isPdf ? AppStatus.danger : AppStatus.info),
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
                      message: known.contains(k) ? 'Filled by the app' : 'Not a standard field; enter it on the TC Details screen',
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
                title: 'Place the Fields',
                subtitle: 'Put each value where it should print. Test Print prints the values with a mm ruler on plain paper: '
                    'hold it against a TC book page, correct any shift with Printer Adjustment, then Save Layout.',
              ),
              SizedBox(height: 14.h),
              TcPdfDesigner(
                key: ValueKey('${_fmt!['tcf_id']}-${_fmt!['uploadedat']}'),
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
              AppUI.cardHeader(icon: 'tag', title: 'Available Placeholders', subtitle: 'Click one to copy it, then paste it into the Word file.'),
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
              Text('{Copy} prints ORIGINAL the first time and DUPLICATE on reprints. Any other {name} you add becomes an extra field to fill on TC Details.',
                  style: AppUI.muted),
            ]),
          ),
      ]),
    );
  }

  /// The school's formats as chips, and the chosen one's name + standards.
  Widget _formatPicker() {
    final usedElsewhere = <String, String>{
      for (final f in _formats)
        if (TcService.fmtId(f) != _selId)
          for (final st in TcService.fmtStandards(f)) st: '${f['name'] ?? ''}',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppUI.sectionLabel('Formats (${_formats.length})'),
      Wrap(spacing: 8.w, runSpacing: 8.h, children: [
        for (final f in _formats)
          ChoiceChip(
            selected: TcService.fmtId(f) == _selId,
            label: Text('${f['name'] ?? ''}  ·  ${TcService.fmtStandards(f).isEmpty ? 'Default (other standards)' : TcService.fmtStandards(f).join(', ')}'),
            onSelected: (_) => _busy ? null : _load(select: TcService.fmtId(f)),
          ),
      ]),
      SizedBox(height: 12.h),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 280.w,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppUI.fieldLabel('Format Name', required: true),
            TextField(controller: _nameCtl, style: AppUI.fieldText(context), decoration: AppUI.field(context, 'e.g. Immaculate XII')),
          ]),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppUI.fieldLabel('Standards using this format'),
            Wrap(spacing: 6.w, runSpacing: 6.h, children: [
              for (final st in _stdNames)
                Tooltip(
                  message: usedElsewhere.containsKey(st) ? 'Used by ${usedElsewhere[st]}' : '',
                  child: FilterChip(
                    label: Text(st),
                    selected: _selStd.contains(st),
                    onSelected: usedElsewhere.containsKey(st)
                        ? null
                        : (v) => setState(() => v ? _selStd.add(st) : _selStd.remove(st)),
                  ),
                ),
            ]),
            SizedBox(height: 4.h),
            Text('None ticked = the default format, for every standard not given to another format.', style: AppUI.muted),
          ]),
        ),
        SizedBox(width: 12.w),
        Column(children: [
          ElevatedButton(onPressed: _busy ? null : _saveInfo, child: const Text('Save')),
          SizedBox(height: 8.h),
          TextButton(
            onPressed: _busy ? null : _deleteFormat,
            child: Text('Delete Format', style: TextStyle(color: AppColors.error)),
          ),
        ]),
      ]),
    ]);
  }

  Future<void> _saveInfo() async {
    final id = _selId;
    if (id == null) return;
    if (_nameCtl.text.trim().isEmpty) return _snack('Enter a name for the format.', AppColors.warning);
    final ordered = [for (final st in _stdNames) if (_selStd.contains(st)) st];
    try {
      await TcService.setFormatInfo(id, _nameCtl.text.trim(), ordered);
      _snack('Format saved.', AppColors.success);
      await _load(select: id);
    } catch (e) {
      _snack('Could not save the format. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<void> _deleteFormat() async {
    final id = _selId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${_fmt?['name'] ?? 'this format'}?'),
        content: const Text('Saved certificates are not affected; they print on the format for their standard.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await TcService.deleteFormat(id);
      _selId = null;
      await _load();
    } catch (e) {
      _snack('Could not delete the format. ${friendlyError(e)}', AppColors.error);
    }
  }

  Widget _copyChip(String k) => ActionChip(
        label: Text('{$k}'),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: '{$k}'));
          _snack('{$k} copied to clipboard.', AppColors.success);
        },
      );
}
