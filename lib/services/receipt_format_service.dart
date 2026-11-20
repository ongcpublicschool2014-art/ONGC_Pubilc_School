import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../utils/tc_pdf.dart';
import '../widgets/receipt_widget.dart';
import 'supabase_service.dart';

/// The school's own fee receipt format (Setup > Receipt Format): a PDF of
/// their receipt with each value placed on it. Server side:
/// school_receipt_format.sql. While one is saved and switched on, every
/// receipt print uses it instead of the built-in design.
class ReceiptFormatService {
  ReceiptFormatService._();

  static String? get _token => SupabaseService.sessionToken;

  // the uploaded file, rendered, kept until it (or its background setting)
  // changes -- checked on every receipt, so a change made on another PC, or
  // after this one signed in, is used at once
  static String? _cacheToken;
  static _Fmt? _cache;

  /// {filename, layout, active, uploadedby, uploadedat, content_b64?} or null.
  static Future<Map<String, dynamic>?> format({bool withContent = false}) async {
    final res = await SupabaseService.client
        .rpc('get_receipt_format', params: {'p_token': _token, 'p_with_content': withContent});
    return res == null ? null : Map<String, dynamic>.from(res as Map);
  }

  /// Saves a new PDF (checked that it opens). Fields already placed are kept.
  static Future<void> saveFormat(String filename, List<int> bytes) async {
    await TcPdf.pages(Uint8List.fromList(bytes), dpi: 20); // throws on a file that is not a PDF
    await SupabaseService.client.rpc('save_receipt_format', params: {
      'p_token': _token, 'p_filename': filename, 'p_content_b64': base64Encode(bytes),
    });
    forget();
  }

  static Future<void> saveLayout(TcPdfLayout layout) async {
    await SupabaseService.client.rpc('save_receipt_layout', params: {'p_token': _token, 'p_layout': layout.toJson()});
    forget();
  }

  /// On: receipts print on the uploaded format. Off: the built-in design.
  static Future<void> setActive(bool on) async {
    await SupabaseService.client.rpc('save_receipt_layout', params: {'p_token': _token, 'p_layout': null, 'p_active': on});
    forget();
  }

  static Future<void> remove() async {
    await SupabaseService.client.rpc('delete_receipt_format', params: {'p_token': _token});
    forget();
  }

  static void forget() => _cache = null;

  /// The format receipts print on now (file + current field places), or null
  /// for the built-in design: none saved, switched off, or no field placed.
  static Future<(_Fmt, TcPdfLayout)?> _inUse() async {
    try {
      final m = await format(); // without the file: a small read
      final layout = TcPdfLayout.fromJson(m?['layout']);
      if (m == null || m['active'] == false || layout.fields.isEmpty) return null;
      final stamp = '${m['uploadedat']}|${layout.background}';
      var c = _cache;
      if (c == null || c.stamp != stamp || _cacheToken != _token) {
        final full = await format(withContent: true);
        final b64 = '${full?['content_b64'] ?? ''}';
        if (b64.isEmpty) return null;
        final pdf = base64Decode(b64);
        c = _Fmt(stamp, pdf, await TcPdf.pages(pdf, dpi: layout.background ? 200 : 20));
        _cache = c;
        _cacheToken = _token;
      }
      return (c, layout);
    } catch (e) {
      // cannot read it now: print the built-in design rather than nothing
      debugPrint('Receipt format not used: $e');
      return null;
    }
  }

  /// True when receipts print on the school's own format.
  static Future<bool> inUse() async => await _inUse() != null;

  /// The paper to ask the printer for: the format's, or null (A5, built-in).
  static Future<PdfPageFormat?> paper() async {
    final f = await _inUse();
    if (f == null) return null;
    final (_, fmt) = await TcPdf.buildDoc(f.$1.pdf, f.$2, const [], pages: f.$1.pages);
    return fmt;
  }

  /// The receipt on the school's format, or null when none is in use.
  static Future<pw.Document?> build(ReceiptData data) async {
    final f = await _inUse();
    if (f == null) return null;
    // the student's other details, read only when the layout places one
    Map<String, dynamic> extra = const {};
    if (f.$2.keys.any(kReceiptDetailKeys.contains)) {
      try {
        final res = await SupabaseService.client
            .rpc('receipt_student_details', params: {'p_token': _token, 'p_admno': data.admissionNo});
        if (res is Map) extra = Map<String, dynamic>.from(res);
      } catch (e) {
        debugPrint('Receipt details not read: $e');
      }
    }
    final (doc, _) = await TcPdf.buildDoc(f.$1.pdf, f.$2, [receiptValues(data, extra: extra)], pages: f.$1.pages);
    return doc;
  }
}

class _Fmt {
  final String stamp; // uploaded-at + background: re-rendered when either changes
  final Uint8List pdf;
  final List<TcPdfPage> pages;
  const _Fmt(this.stamp, this.pdf, this.pages);
}

/// The fields a receipt format can place, in the order the designer lists them.
const String kReceiptLinesKey = 'Fee Lines';
const List<String> kReceiptFieldKeys = [
  // the receipt
  'Receipt No',
  'Receipt Date',
  'Receipt Time',
  'Academic Year',
  'Terms',
  // the student
  'Student Name',
  'Admission No',
  'Class',
  'Standard',
  'Section',
  'Father Name',
  'Mother Name',
  'Guardian Name',
  'Parent Mobile',
  'Mobile No',
  'Date of Birth',
  'EMIS No',
  'Address',
  // the money
  kReceiptLinesKey,
  'Total',
  'Advance Adjusted',
  'Amount Paid',
  'Amount in Words',
  'Balance Due',
  'Payment Mode',
  'Payment Date',
  'Transaction ID',
  // the school / counter
  'School Name',
  'School Address',
  'School Phone',
  'School Email',
  'Received By',
  'Remarks',
];

/// Fields read from the student's record when the receipt prints.
const Set<String> kReceiptDetailKeys = {
  'Academic Year', 'Standard', 'Section', 'Father Name', 'Mother Name', 'Guardian Name',
  'Parent Mobile', 'Date of Birth', 'EMIS No', 'Balance Due', 'Received By',
};

/// Values the designer and Test Print show.
const Map<String, String> kReceiptSamples = {
  'Receipt No': 'R/2026/00125',
  'Receipt Date': '29-10-2026',
  'Receipt Time': '10:45 AM',
  'Academic Year': '2026-2027',
  'Terms': 'TERM 1',
  'Student Name': 'ARUN KUMAR S',
  'Admission No': 'ADM00012',
  'Class': 'V - A',
  'Standard': 'V',
  'Section': 'V - A',
  'Father Name': 'SURESH KUMAR R',
  'Mother Name': 'LATHA S',
  'Guardian Name': '',
  'Parent Mobile': '9876543210',
  'Date of Birth': '05-06-2015',
  'EMIS No': '330401234567',
  'Balance Due': '4,500.00',
  'School Phone': '0413-2200000',
  'School Email': 'office@school.in',
  'Received By': 'ADMIN',
  'Mobile No': '9876543210',
  'Address': '12, GANDHI STREET, UDUMALPET',
  kReceiptLinesKey: '1. Term 1 Tuition Fee\t12,000.00\n2. Term 1 Book Fee\t2,500.00\n3. Transport Fee\t1,000.00',
  'Total': '15,500.00',
  'Advance Adjusted': '',
  'Amount Paid': '15,500.00',
  'Amount in Words': 'Rupees Fifteen Thousand Five Hundred Only',
  'Payment Mode': 'CASH',
  'Payment Date': '29-10-2026',
  'Transaction ID': '',
  'School Name': 'ONGC PUBLIC SCHOOL',
  'School Address': 'UDUMALPET',
  'Remarks': 'Subject to realisation',
};

/// One receipt's values by field name. [extra]: the student's other details
/// (receipt_student_details), when the layout places any of them.
Map<String, String> receiptValues(ReceiptData d, {Map<String, dynamic> extra = const {}}) {
  String x(String k) => '${extra[k] ?? ''}'.trim();
  final now = DateTime.now();
  final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
  final terms = <String>[];
  for (final t in d.feeDetails) {
    if (t.term.trim().isNotEmpty && !terms.contains(t.term.trim())) terms.add(t.term.trim());
  }
  final balance = num.tryParse(x('balance'));
  final rows = flattenParticulars(d);
  // the term is added only where the same fee appears in more than one term
  final types = <String, int>{};
  for (final r in rows) {
    types[r.type] = (types[r.type] ?? 0) + 1;
  }
  final lines = [
    for (var i = 0; i < rows.length; i++)
      '${i + 1}. ${(types[rows[i].type] ?? 0) > 1 ? '${rows[i].term} ' : ''}${rows[i].type}\t${formatReceiptAmount(rows[i].amount)}',
  ];
  final paid = d.total - d.advanceAdjusted;
  final ref = (d.paymentReference ?? '').trim();
  return {
    'Receipt No': d.receiptNo,
    'Receipt Date': d.date,
    'Student Name': d.studentName,
    'Admission No': d.admissionNo,
    'Class': d.className,
    'Mobile No': d.mobileNo,
    'Address': d.address,
    kReceiptLinesKey: lines.join('\n'),
    'Total': formatReceiptAmount(d.total),
    'Advance Adjusted': d.hasAdvanceAdjustment
        ? '${formatReceiptAmount(d.advanceAdjusted)}${d.advanceNo.isEmpty ? '' : ' (${d.advanceNo})'}'
        : '',
    'Amount Paid': formatReceiptAmount(paid),
    // what changed hands (the total less any advance), matching 'Amount Paid'
    'Amount in Words': amountInWords(paid),
    'Payment Mode': d.paymentMethod,
    'Payment Date': d.paymentDate,
    'Transaction ID': ref,
    'School Name': d.schoolName,
    'School Address': d.schoolAddress,
    'School Phone': (d.schoolMobile ?? '').trim(),
    'School Email': (d.schoolEmail ?? '').trim(),
    'Receipt Time': '$hour:${now.minute.toString().padLeft(2, '0')} ${now.hour < 12 ? 'AM' : 'PM'}',
    'Terms': terms.join(', '),
    'Academic Year': x('yrlabel'),
    'Standard': x('standard'),
    'Section': x('section').isEmpty ? d.className : x('section'),
    'Father Name': x('father'),
    'Mother Name': x('mother'),
    'Guardian Name': x('guardian'),
    'Parent Mobile': x('fathermobile').isEmpty ? d.mobileNo : x('fathermobile'),
    'Date of Birth': x('dob'),
    'EMIS No': x('emisno'),
    // what the student still owes (all terms), as on the day it prints
    'Balance Due': balance == null ? '' : formatReceiptAmount(balance.toDouble()),
    'Received By': x('user'),
    'Remarks': [
      if (d.cancelled) 'CANCELLED',
      if (d.reconStatus != 'R') 'Subject to realisation',
    ].join('  '),
  };
}
