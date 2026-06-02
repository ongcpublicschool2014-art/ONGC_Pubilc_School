import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Data model for a fee receipt. Kept stable so existing call sites
/// (Daily Collection, Student Fee Collection, Failed Transactions) and the
/// PDF builder continue to work unchanged.
class ReceiptData {
  final String receiptNo;
  final String date;
  final String studentName;
  final String mobileNo;
  final String address;
  final String admissionNo;
  final String className;
  final String courseName;
  final String schoolName;
  final String schoolAddress;
  final String? schoolLogoUrl;
  final String? schoolMobile;
  final String? schoolEmail;
  final List<ReceiptTermDetail> feeDetails;
  final String paymentMethod;
  final String paymentDate;
  final String status; // 'paid' or 'pending'
  final String reconStatus; // 'P' = pending recon, 'R' = reconciled
  final String? paymentReference; // gateway txn id / UTR — shown only for online/UPI
  final double total;

  const ReceiptData({
    required this.receiptNo,
    required this.date,
    required this.studentName,
    required this.mobileNo,
    required this.address,
    required this.admissionNo,
    required this.className,
    this.courseName = '-',
    required this.schoolName,
    required this.schoolAddress,
    this.schoolLogoUrl,
    this.schoolMobile,
    this.schoolEmail,
    required this.feeDetails,
    required this.paymentMethod,
    required this.paymentDate,
    required this.status,
    this.reconStatus = 'R',
    this.paymentReference,
    required this.total,
  });
}

class ReceiptTermDetail {
  final String term;
  final List<ReceiptFeeItem> fees;

  const ReceiptTermDetail({required this.term, required this.fees});
}

class ReceiptFeeItem {
  final String type;
  final double amount;

  const ReceiptFeeItem({required this.type, required this.amount});
}

/// One flattened "particular" line — a single fee row in the receipt table.
class ReceiptParticular {
  final String term;
  final String type;
  final double amount;
  const ReceiptParticular(
      {required this.term, required this.type, required this.amount});
}

/// Flattens the term-grouped fee details into a flat particulars list.
List<ReceiptParticular> flattenParticulars(ReceiptData data) {
  final rows = <ReceiptParticular>[];
  for (final term in data.feeDetails) {
    for (final fee in term.fees) {
      rows.add(ReceiptParticular(
          term: term.term, type: fee.type, amount: fee.amount));
    }
  }
  return rows;
}

/// Picks the printed header banner asset for a college from its name.
/// Returns null when no banner matches — the receipt then falls back to
/// the institution logo + name/address text.
String? receiptHeaderImage(String schoolName) {
  final s = schoolName.toLowerCase();
  if (s.contains('engineering')) return 'assets/images/kcet.png';
  if (s.contains('polytechnic')) return 'assets/images/kmptc.jpg';
  if (s.contains('science') ||
      s.contains('arts') ||
      s.contains('management') ||
      s.contains('women')) {
    return 'assets/images/kcsam.jpg';
  }
  return null;
}

/// Distinct semesters/terms on the receipt, joined for the header field.
String receiptSemesterLabel(ReceiptData data) {
  final terms = <String>{};
  for (final t in data.feeDetails) {
    final v = t.term.trim();
    if (v.isNotEmpty && v != '-') terms.add(v);
  }
  return terms.isEmpty ? '-' : terms.join(', ');
}

/// Amount with two decimals and thousands separators, e.g. 5000 -> "5,000.00".
String formatReceiptAmount(double amount) {
  final parts = amount.toStringAsFixed(2).split('.');
  final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return '$intPart.${parts[1]}';
}

const _onesWords = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
  'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
  'Seventeen', 'Eighteen', 'Nineteen'
];
const _tensWords = [
  '', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty',
  'Ninety'
];

String _twoDigitWords(int n) {
  if (n < 20) return _onesWords[n];
  final t = _tensWords[n ~/ 10];
  return n % 10 == 0 ? t : '$t ${_onesWords[n % 10]}';
}

String _threeDigitWords(int n) {
  final parts = <String>[];
  if (n ~/ 100 > 0) parts.add('${_onesWords[n ~/ 100]} Hundred');
  if (n % 100 > 0) parts.add(_twoDigitWords(n % 100));
  return parts.join(' ');
}

String _numberToWords(int n) {
  if (n == 0) return 'Zero';
  final parts = <String>[];
  final crore = n ~/ 10000000;
  n %= 10000000;
  final lakh = n ~/ 100000;
  n %= 100000;
  final thousand = n ~/ 1000;
  n %= 1000;
  if (crore > 0) parts.add('${_numberToWords(crore)} Crore');
  if (lakh > 0) parts.add('${_twoDigitWords(lakh)} Lakh');
  if (thousand > 0) parts.add('${_twoDigitWords(thousand)} Thousand');
  if (n > 0) parts.add(_threeDigitWords(n));
  return parts.join(' ');
}

/// "Rupees Five Thousand Only" style amount-in-words for the receipt footer.
String amountInWords(double amount) {
  final whole = amount.round();
  if (whole <= 0) return 'Rupees Zero Only';
  return 'Rupees ${_numberToWords(whole)} Only';
}

/// B5 fee-receipt widget — a Flutter port of the Figma "Receipt" design.
/// Renders at ISO B5 (176×250 mm ≈ 499×709 pt). The matching print/download
/// PDF is produced by `buildReceiptPdf` in receipt_pdf.dart.
class ReceiptWidget extends StatelessWidget {
  final ReceiptData data;

  const ReceiptWidget({super.key, required this.data});

  /// ISO B5 in PDF points (176×250 mm at 72 dpi).
  static const double b5Width = 499;
  static const double b5Height = 709;

  static const double _amountColWidth = 120;
  static const _border = BorderSide(color: Colors.black, width: 1);

  /// Kept for backward compatibility with existing call sites.
  static bool isOnlineMethod(String method) {
    final m = method.toLowerCase();
    return m.contains('razorpay') ||
        m.contains('online') ||
        m.contains('upi') ||
        m.contains('netbanking') ||
        m.contains('card');
  }

  /// Kept for backward compatibility with existing call sites.
  static String formatReference(String? raw) {
    if (raw == null) return '';
    var s = raw.trim();
    if (s.isEmpty) return '';
    final colon = s.indexOf(':');
    if (colon != -1 && colon < 30) s = s.substring(colon + 1).trim();
    final byMatch =
        RegExp(r'\s+by\s+.+$', caseSensitive: false).firstMatch(s);
    if (byMatch != null) s = s.substring(0, byMatch.start).trim();
    return s;
  }

  TextStyle _body({double size = 9, FontWeight weight = FontWeight.w400}) =>
      GoogleFonts.inter(fontSize: size, fontWeight: weight, color: Colors.black);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: b5Width,
      height: b5Height,
      color: Colors.white,
      padding: const EdgeInsets.all(48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 10),
          Text(
            'RECEIPT',
            textAlign: TextAlign.center,
            style: _body(size: 9, weight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Expanded(child: _table()),
        ],
      ),
    );
  }

  // Centered college banner (kcet/kmptc/kcsam) — falls back to logo + text.
  Widget _header() {
    final banner = receiptHeaderImage(data.schoolName);
    if (banner != null) {
      // Two-grid header: 20% crest | 5% gap | 75% banner.
      return SizedBox(
        height: 100,
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Center(
                child: Image.asset('assets/images/KMPTC Logo.jpg',
                    height: 88, fit: BoxFit.contain),
              ),
            ),
            const Expanded(flex: 1, child: SizedBox()),
            Expanded(
              flex: 15,
              child: Center(
                child: Image.asset(banner, fit: BoxFit.contain),
              ),
            ),
          ],
        ),
      );
    }
    final hasLogo = (data.schoolLogoUrl ?? '').isNotEmpty;
    return SizedBox(
      height: 100,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (hasLogo) ...[
            SizedBox(
              width: 70,
              height: 70,
              child: Image.network(
                data.schoolLogoUrl!,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: 14),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(data.schoolName,
                    style: _body(size: 9, weight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(data.schoolAddress,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _body(size: 9, weight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The bordered receipt table.
  Widget _table() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _infoRow(),
          _sectionHeaderRow(),
          Expanded(child: _particularsRow()),
          _totalRow(),
          _footerRow(),
        ],
      ),
    );
  }

  // Two equal cells: student details | receipt details.
  Widget _infoRow() {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _infoCell([
              _kv('Name', data.studentName),
              _kv('Reg. No', data.admissionNo),
              _kv('Branch', data.className),
              _kv('Mode', data.paymentMethod.isEmpty ? '-' : data.paymentMethod),
            ]),
          ),
          Container(width: 1, color: Colors.black),
          Expanded(
            child: _infoCell([
              _kv('Receipt No', data.receiptNo),
              _kv('Date', data.date),
              _kv('Sem', 'FEE (UP TO DATE)'),
              _kv('Txn ID', (data.paymentReference ?? '').trim().isEmpty ? '-' : data.paymentReference!.trim()),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _infoCell(List<Widget> lines) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            lines[i],
          ],
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return RichText(
      text: TextSpan(
        style: _body(size: 9),
        children: [
          TextSpan(
              text: '$label : ',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(
              text: value.trim().isEmpty ? '-' : value,
              style: const TextStyle(fontWeight: FontWeight.w400)),
        ],
      ),
    );
  }

  // PARTICULARS | AMOUNTS (Rs) column headings.
  Widget _sectionHeaderRow() {
    return Container(
      decoration: const BoxDecoration(border: Border(top: _border)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text('PARTICULARS',
                    textAlign: TextAlign.center,
                    style: _body(size: 9, weight: FontWeight.w700)),
              ),
            ),
            Container(width: 1, color: Colors.black),
            SizedBox(
              width: _amountColWidth,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text('AMOUNTS (Rs)',
                    textAlign: TextAlign.right,
                    style: _body(size: 9, weight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // The fee lines — fills the remaining vertical space.
  Widget _particularsRow() {
    final rows = flattenParticulars(data);
    return Container(
      decoration: const BoxDecoration(border: Border(top: _border)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    Text('${i + 1}. ${rows[i].type}', style: _body()),
                  ],
                ],
              ),
            ),
          ),
          Container(width: 1, color: Colors.black),
          SizedBox(
            width: _amountColWidth,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    Text(formatReceiptAmount(rows[i].amount),
                        style: _body()),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // TOTAL | grand total.
  Widget _totalRow() {
    return Container(
      decoration: const BoxDecoration(border: Border(top: _border)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text('TOTAL',
                    textAlign: TextAlign.right,
                    style: _body(size: 9, weight: FontWeight.w700)),
              ),
            ),
            Container(width: 1, color: Colors.black),
            SizedBox(
              width: _amountColWidth,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(formatReceiptAmount(data.total),
                    textAlign: TextAlign.right,
                    style: _body(size: 9, weight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Amount in words + cashier signature line. When the payment isn't
  // reconciled yet (cheque clearance pending, UPI not yet matched, etc.) a
  // "* Subject to Realization" note prints on the left so the student sees
  // the receipt isn't a settled-cash equivalent.
  Widget _footerRow() {
    final isPending = data.reconStatus != 'R';
    return Container(
      height: 110,
      decoration: const BoxDecoration(border: Border(top: _border)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(amountInWords(data.total),
              style: _body(size: 9, weight: FontWeight.w500)),
          if (isPending) ...[
            const SizedBox(height: 4),
            Text('* Subject to Realization',
                style: _body(size: 9, weight: FontWeight.w600).copyWith(color: const Color(0xFFB85C00))),
          ],
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 34),
            child: Text('Cashier',
                textAlign: TextAlign.right,
                style: _body(size: 9, weight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
