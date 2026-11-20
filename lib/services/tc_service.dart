import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../utils/tc_docx.dart';
import '../utils/tc_fields.dart';
import '../utils/tc_pdf.dart';
import 'supabase_service.dart';
import '../utils/save_path.dart';

/// TC module (school): certificate, approval, print and the school's Word
/// format. Server side: school_tc_certificate.sql.
class TcService {
  TcService._();

  static String? get _token => SupabaseService.sessionToken;

  /// Students with a TC issued, each with {tc, student, admission, cert}.
  static Future<List<Map<String, dynamic>>> list() async {
    final res = await SupabaseService.client.rpc('tc_certificate_list', params: {'p_token': _token});
    return [for (final x in (res as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
  }

  static Future<int> save(int stuId, String serial, Map<String, String> fields) async {
    final res = await SupabaseService.client.rpc('save_tc_certificate', params: {
      'p_token': _token, 'p_stu_id': stuId, 'p_tcserial': serial, 'p_fields': fields,
    });
    return (res as num).toInt();
  }

  static Future<int> approve(List<int> ids, {required bool approve}) async {
    final res = await SupabaseService.client.rpc('approve_tc_certificate', params: {
      'p_token': _token, 'p_ids': ids, 'p_approve': approve,
    });
    return (res as num?)?.toInt() ?? 0;
  }

  static Future<void> cancel(int id, String reason) => SupabaseService.client
      .rpc('cancel_tc_certificate', params: {'p_token': _token, 'p_id': id, 'p_reason': reason});

  static Future<void> markPrinted(List<int> ids) =>
      SupabaseService.client.rpc('mark_tc_printed', params: {'p_token': _token, 'p_ids': ids});

  /// {tcf_id, name, standards, filename, kind DOCX|PDF, placeholders, layout,
  /// uploadedby, uploadedat, content_b64?} of format [tcfId], or of the
  /// school's default format; null if none.
  static Future<Map<String, dynamic>?> format({bool withContent = false, int? tcfId}) async {
    final res = await SupabaseService.client.rpc('get_tc_format',
        params: {'p_token': _token, 'p_with_content': withContent, if (tcfId != null) 'p_tcf_id': tcfId});
    return res == null ? null : Map<String, dynamic>.from(res as Map);
  }

  /// Every TC format of the school (without file content), the default one
  /// (no standards) first. A school can keep one per group of standards,
  /// e.g. one for X and one for XI-XII.
  static Future<List<Map<String, dynamic>>> formats() async {
    final res = await SupabaseService.client.rpc('get_tc_formats', params: {'p_token': _token});
    return [for (final x in (res as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
  }

  static int? fmtId(Map<String, dynamic>? f) => (f?['tcf_id'] as num?)?.toInt();

  static List<String> fmtStandards(Map<String, dynamic>? f) =>
      [for (final x in (f?['standards'] as List? ?? const [])) '$x'];

  /// The format for a student of [standard]: the one listing that standard,
  /// else the default (no standards), else the first.
  static Map<String, dynamic>? formatFor(List<Map<String, dynamic>> formats, String standard) {
    final std = standard.trim().toUpperCase();
    for (final f in formats) {
      if (fmtStandards(f).any((s) => s.trim().toUpperCase() == std)) return f;
    }
    for (final f in formats) {
      if (fmtStandards(f).isEmpty) return f;
    }
    return formats.isEmpty ? null : formats.first;
  }

  /// Name and standards of a format. A standard can belong to one format only.
  static Future<void> setFormatInfo(int tcfId, String name, List<String> standards) =>
      SupabaseService.client.rpc('set_tc_format_info',
          params: {'p_token': _token, 'p_tcf_id': tcfId, 'p_name': name, 'p_standards': standards});

  static Future<void> deleteFormat(int tcfId) =>
      SupabaseService.client.rpc('delete_tc_format', params: {'p_token': _token, 'p_tcf_id': tcfId});

  static bool isPdf(Map<String, dynamic>? f) => '${f?['kind'] ?? ''}'.toUpperCase() == 'PDF';

  /// Saves a new format. A .docx is checked for {placeholders}; a PDF must
  /// render (its field layout starts empty and is placed on TC Format).
  /// [tcfId]: replace that format's file. Without it, [newName] adds a new
  /// format; with neither, the default format is replaced. Returns its id.
  static Future<int?> saveFormat(String filename, List<int> bytes, {int? tcfId, String? newName}) async {
    final pdf = filename.toLowerCase().endsWith('.pdf');
    final List<String> ph;
    if (pdf) {
      await TcPdf.pages(Uint8List.fromList(bytes), dpi: 20); // throws on a file that is not a PDF
      ph = const [];
    } else {
      ph = TcDocx.placeholders(bytes); // throws on a file that is not a .docx
    }
    final id = await SupabaseService.client.rpc('save_tc_format', params: {
      'p_token': _token, 'p_filename': filename, 'p_content_b64': base64Encode(bytes), 'p_placeholders': ph,
      'p_kind': pdf ? 'PDF' : 'DOCX', 'p_layout': pdf ? TcPdfLayout().toJson() : null,
      if (tcfId != null) 'p_tcf_id': tcfId,
      if (newName != null) 'p_name': newName,
    });
    return (id as num?)?.toInt();
  }

  /// PDF format: where each field prints.
  static Future<void> saveLayout(TcPdfLayout layout, {int? tcfId}) => SupabaseService.client.rpc('save_tc_layout', params: {
        'p_token': _token, 'p_layout': layout.toJson(), 'p_placeholders': layout.keys,
        if (tcfId != null) 'p_tcf_id': tcfId,
      });

  /// Auto values for a list item (from the student, admission and TC entry).
  static Map<String, String> autoValues(Map<String, dynamic> item,
      {required String schoolName, required String schoolAddress, required String yearLabel,
      String schoolPhone = '', String schoolEmail = '', String affiliationNo = '', int yearStartMonth = 4}) {
    final src = TcSource(
      student: Map<String, dynamic>.from((item['student'] as Map?) ?? const {}),
      admission: Map<String, dynamic>.from((item['admission'] as Map?) ?? const {}),
      tc: Map<String, dynamic>.from((item['tc'] as Map?) ?? const {}),
      schoolName: schoolName,
      schoolAddress: schoolAddress,
      yearLabel: yearLabel,
      schoolPhone: schoolPhone,
      schoolEmail: schoolEmail,
      affiliationNo: affiliationNo,
      pendingFees: (item['pending_fees'] as num?)?.toDouble(),
      yearStartMonth: yearStartMonth,
    );
    return {for (final f in kTcFields) f.key: f.auto == null ? '' : f.auto!(src)};
  }

  /// Fill the format for [certs] (each a saved certificate row) into one
  /// document. A PDF format goes straight to the printer at actual size (so
  /// the values land on the TC book's lines), unless [savePdf]; a Word
  /// format is saved and opened in Word to print.
  /// [copy]: 'AUTO' (ORIGINAL on the first print, DUPLICATE after),
  /// 'ORIGINAL' or 'DUPLICATE'.
  ///
  /// Returns where it went ('the printer' or the saved path; null if nothing
  /// went anywhere), the certificates SENT TO THE PRINTER ([printed]) and the
  /// ones only SAVED to a file ([saved]) -- those are printed outside the app,
  /// so the caller asks before counting them (the first print strikes the
  /// student off the rolls).
  static Future<({String? where, List<int> printed, List<int> saved})> printTc(
      List<Map<String, dynamic>> certs, String copy, {bool savePdf = false}) async {
    final printed = <int>[], saved = <int>[];
    String? where;
    Future<void> run(int? tcfId, List<Map<String, dynamic>> group) async {
      final r = await _printWith(tcfId, group, copy, savePdf: savePdf);
      if (r == null) return; // cancelled: not counted
      where = r;
      final ids = [for (final c in group) (c['tcc_id'] as num).toInt()];
      (r == 'the printer' ? printed : saved).addAll(ids);
    }

    // Each student prints on the format for their standard (Immaculate X
    // and XII...). Certificates are grouped by format and printed in turn.
    final all = await formats();
    if (all.length > 1) {
      final groups = <int, List<Map<String, dynamic>>>{};
      for (final c in certs) {
        final std = '${(c['fields'] as Map?)?['Standard'] ?? ''}';
        final id = fmtId(formatFor(all, std));
        if (id != null) (groups[id] ??= []).add(c);
      }
      if (groups.length > 1) {
        for (final e in groups.entries) {
          await run(e.key, e.value);
        }
        return (where: where, printed: printed, saved: saved);
      }
      if (groups.length == 1) {
        await run(groups.keys.first, certs);
        return (where: where, printed: printed, saved: saved);
      }
    }
    await run(null, certs);
    return (where: where, printed: printed, saved: saved);
  }

  static Future<String?> _printWith(int? tcfId, List<Map<String, dynamic>> certs, String copy, {bool savePdf = false}) async {
    final f = await format(withContent: true, tcfId: tcfId);
    final b64 = f?['content_b64']?.toString() ?? '';
    if (b64.isEmpty) throw StateError('No TC format has been uploaded. Upload one in TC > TC Format, then print again.');
    final now = DateTime.now();
    final printDate = tcDate(now.toIso8601String());
    final rows = <Map<String, String>>[
      for (final c in certs)
        {
          for (final e in Map<String, dynamic>.from((c['fields'] as Map?) ?? const {}).entries) e.key: '${e.value ?? ''}',
          'TC No': '${c['tcserial'] ?? (c['fields'] as Map?)?['TC No'] ?? ''}',
          'Copy': copy == 'AUTO'
              ? (((c['printcount'] as num?)?.toInt() ?? 0) > 0 ? 'DUPLICATE' : 'ORIGINAL')
              : copy,
          'Print Date': printDate,
        },
    ];
    final pdf = isPdf(f);
    final ext = pdf ? 'pdf' : 'docx';
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final name = certs.length == 1
        ? 'TC_${safe('${certs.first['stuadmno'] ?? ''}')}_${safe('${certs.first['stuname'] ?? ''}')}.$ext'
        : 'TC_${certs.length}_students_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.$ext';
    if (!pdf) return saveAndOpen(name, TcDocx.fill(base64Decode(b64), rows), dialogTitle: 'Save Transfer Certificate');
    final layout = TcPdfLayout.fromJson(f?['layout']);
    if (layout.fields.isEmpty) {
      throw StateError('The PDF format has no fields placed yet. Place the fields in TC > TC Format, then print again.');
    }
    final (bytes, paper) = await TcPdf.build(base64Decode(b64), layout, rows);
    if (savePdf) return saveAndOpen(name, bytes, dialogTitle: 'Save Transfer Certificate');
    return await toPrinter(bytes, paper, name) ? 'the printer' : null;
  }

  /// Print a PDF at actual size (no "fit to page"), on paper of [paper]'s
  /// size; the printer's unprintable edge is allowed for, so a value placed
  /// 30 mm from the top prints 30 mm from the top. Windows shows the printer
  /// choice first. False if cancelled.
  static Future<bool> toPrinter(Uint8List bytes, PdfPageFormat paper, String name) => Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: name,
        format: paper,
        usePrinterSettings: false,
      );

  /// Ask where to save [bytes] and open the file in its default app.
  static Future<String?> saveAndOpen(String name, List<int> bytes, {String dialogTitle = 'Save'}) async {
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : 'docx';
    final path = await pickSavePath(
      dialogTitle: dialogTitle,
      fileName: name,
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (path == null) return null;
    final out = path.toLowerCase().endsWith('.$ext') ? path : '$path.$ext';
    await File(out).writeAsBytes(bytes);
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', out]);
    }
    return out;
  }
}
