import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../utils/tc_docx.dart';
import '../utils/tc_fields.dart';
import '../utils/tc_pdf.dart';
import 'supabase_service.dart';

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

  /// {filename, kind DOCX|PDF, placeholders, layout, uploadedby, uploadedat,
  /// content_b64?} or null.
  static Future<Map<String, dynamic>?> format({bool withContent = false}) async {
    final res = await SupabaseService.client
        .rpc('get_tc_format', params: {'p_token': _token, 'p_with_content': withContent});
    return res == null ? null : Map<String, dynamic>.from(res as Map);
  }

  static bool isPdf(Map<String, dynamic>? f) => '${f?['kind'] ?? ''}'.toUpperCase() == 'PDF';

  /// Saves a new format. A .docx is checked for {placeholders}; a PDF must
  /// render (its field layout starts empty and is placed on TC Format).
  static Future<void> saveFormat(String filename, List<int> bytes) async {
    final pdf = filename.toLowerCase().endsWith('.pdf');
    final List<String> ph;
    if (pdf) {
      await TcPdf.pages(Uint8List.fromList(bytes), dpi: 20); // throws on a file that is not a PDF
      ph = const [];
    } else {
      ph = TcDocx.placeholders(bytes); // throws on a file that is not a .docx
    }
    await SupabaseService.client.rpc('save_tc_format', params: {
      'p_token': _token, 'p_filename': filename, 'p_content_b64': base64Encode(bytes), 'p_placeholders': ph,
      'p_kind': pdf ? 'PDF' : 'DOCX', 'p_layout': pdf ? TcPdfLayout().toJson() : null,
    });
  }

  /// PDF format: where each field prints.
  static Future<void> saveLayout(TcPdfLayout layout) => SupabaseService.client.rpc('save_tc_layout', params: {
        'p_token': _token, 'p_layout': layout.toJson(), 'p_placeholders': layout.keys,
      });

  /// Auto values for a list item (from the student, admission and TC entry).
  static Map<String, String> autoValues(Map<String, dynamic> item,
      {required String schoolName, required String schoolAddress, required String yearLabel}) {
    final src = TcSource(
      student: Map<String, dynamic>.from((item['student'] as Map?) ?? const {}),
      admission: Map<String, dynamic>.from((item['admission'] as Map?) ?? const {}),
      tc: Map<String, dynamic>.from((item['tc'] as Map?) ?? const {}),
      schoolName: schoolName,
      schoolAddress: schoolAddress,
      yearLabel: yearLabel,
    );
    return {for (final f in kTcFields) f.key: f.auto == null ? '' : f.auto!(src)};
  }

  /// Fill the format for [certs] (each a saved certificate row) into one
  /// document -- Word for a .docx format, PDF for a PDF format -- ask where to
  /// save it and open it to print.
  /// [copy]: 'AUTO' (ORIGINAL on the first print, DUPLICATE after),
  /// 'ORIGINAL' or 'DUPLICATE'. Returns the saved path, or null if cancelled.
  static Future<String?> printTc(List<Map<String, dynamic>> certs, String copy) async {
    final f = await format(withContent: true);
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
    final List<int> bytes;
    if (pdf) {
      final layout = TcPdfLayout.fromJson(f?['layout']);
      if (layout.fields.isEmpty) {
        throw StateError('The PDF format has no fields placed yet. Place the fields in TC > TC Format, then print again.');
      }
      bytes = await TcPdf.fill(base64Decode(b64), layout, rows);
    } else {
      bytes = TcDocx.fill(base64Decode(b64), rows);
    }
    final ext = pdf ? 'pdf' : 'docx';
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final name = certs.length == 1
        ? 'TC_${safe('${certs.first['stuadmno'] ?? ''}')}_${safe('${certs.first['stuname'] ?? ''}')}.$ext'
        : 'TC_${certs.length}_students_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.$ext';
    return saveAndOpen(name, bytes, dialogTitle: 'Save Transfer Certificate');
  }

  /// Ask where to save [bytes] and open the file in its default app.
  static Future<String?> saveAndOpen(String name, List<int> bytes, {String dialogTitle = 'Save'}) async {
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : 'docx';
    final path = await FilePicker.platform.saveFile(
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
