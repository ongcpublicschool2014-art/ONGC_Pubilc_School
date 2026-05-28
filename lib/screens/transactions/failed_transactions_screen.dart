import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/payment_model.dart';
import '../../models/student_model.dart';
import '../../widgets/receipt_widget.dart';
import '../../utils/receipt_pdf.dart';
import '../../utils/friendly_error.dart';

class FailedTransactionsScreen extends StatefulWidget {
  const FailedTransactionsScreen({super.key});

  @override
  State<FailedTransactionsScreen> createState() =>
      _FailedTransactionsScreenState();
}

class _FailedTransactionsScreenState extends State<FailedTransactionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = false;
  List<PaymentModel> _paidTransactions = [];
  String _searchQuery = '';
  final _searchController = TextEditingController();
  List<PaymentModel> _failedTransactions = [];
  Map<int, String> _stuIdToName = {};
  Map<int, StudentModel> _stuIdToStudent = {};
  DateTime? _filterFromDate;
  DateTime? _filterToDate;
  final Set<String> _filterMethods = {}; // empty = all methods
  String? _insName;
  String? _insLogoUrl;
  String? _insAddress;
  String? _insMobile;
  String? _insEmail;


  List<PaymentModel> _filterBySearch(List<PaymentModel> list) {
    var filtered = list;
    // Date filter
    if (_filterFromDate != null || _filterToDate != null) {
      filtered = filtered.where((t) {
        final date = t.paydate ?? t.createdat;
        final dateOnly = DateTime(date.year, date.month, date.day);
        if (_filterFromDate != null && dateOnly.isBefore(_filterFromDate!)) return false;
        if (_filterToDate != null && dateOnly.isAfter(_filterToDate!)) return false;
        return true;
      }).toList();
    }
    // Method filter
    if (_filterMethods.isNotEmpty) {
      filtered = filtered.where((t) {
        final m = (t.paymethod ?? '').toLowerCase();
        return _filterMethods.contains(m);
      }).toList();
    }
    // Search filter — name, roll no, class.
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((t) {
        final name = _getStudentName(t).toLowerCase();
        final stu = t.stuId != null ? _stuIdToStudent[t.stuId] : null;
        final rollNo = (stu?.stuadmno ?? '').toLowerCase();
        final cls = (stu?.stuclass ?? '').toLowerCase();
        return name.contains(_searchQuery) || rollNo.contains(_searchQuery) || cls.contains(_searchQuery);
      }).toList();
    }
    return filtered;
  }

  // null = main view with summary cards; 'all' | 'paid' | 'failed' =
  // an in-place drill-down opened by tapping a summary card.
  String? _drilldownFilter;

  List<PaymentModel> get _allTransactions {
    final List<PaymentModel> all;
    switch (_drilldownFilter ?? 'all') {
      case 'paid':
        all = [..._paidTransactions];
        break;
      case 'failed':
        all = [..._failedTransactions];
        break;
      default:
        all = [..._paidTransactions, ..._failedTransactions];
    }
    all.sort((a, b) {
      final dateA = a.paydate ?? a.createdat;
      final dateB = b.paydate ?? b.createdat;
      return dateB.compareTo(dateA);
    });
    return _filterBySearch(all);
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _fetchData();
  }

  /// Opens an in-place drill-down filtered to [filter].
  void _openDrilldown(String filter) {
    setState(() => _drilldownFilter = filter);
  }

  void _closeDrilldown() {
    setState(() => _drilldownFilter = null);
  }

  String _drilldownTitle() {
    switch (_drilldownFilter) {
      case 'paid':
        return 'Paid Transactions';
      case 'failed':
        return 'Failed Transactions';
      default:
        return 'All Transactions';
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in _hCtrls.values) {
      c.dispose();
    }
    for (final c in _vCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _fetchData() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        SupabaseService.getAllTransactions(insId),
        SupabaseService.getStudents(insId),
        SupabaseService.getInstitutionInfo(insId),
      ]);

      final allData = results[0] as List<Map<String, dynamic>>;
      final paidData = allData.where((t) => t['paystatus'] == 'C').toList();
      final failedData = allData.where((t) => t['paystatus'] == 'F').toList();
      final students = results[1] as List<StudentModel>;

      final stuIdToName = <int, String>{};
      final stuIdToStudent = <int, StudentModel>{};
      for (final s in students) {
        stuIdToName[s.stuId] = s.stuname;
        stuIdToStudent[s.stuId] = s;
      }

      final insInfo = results[2] as ({String? name, String? logo, String? address, String? mobile, String? email});

      // Guard: the user may have navigated away while the parallel
      // queries were in flight. Without this check Flutter logs a
      // "setState() called after dispose" warning every time the
      // Transactions tab is left mid-load.
      if (!mounted) return;
      setState(() {
        _paidTransactions =
            paidData.map((e) => PaymentModel.fromJson(e)).toList();
        _failedTransactions =
            failedData.map((e) => PaymentModel.fromJson(e)).toList();
        _stuIdToName = stuIdToName;
        _stuIdToStudent = stuIdToStudent;
        _insName = insInfo.name;
        _insLogoUrl = insInfo.logo;
        _insAddress = insInfo.address;
        _insMobile = insInfo.mobile;
        _insEmail = insInfo.email;
      });
    } catch (e) {
      debugPrint('Error loading transactions: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _getStudentName(PaymentModel t) {
    // Use stuname from RPC if available, fallback to student map lookup
    if (t.stuname != null && t.stuname!.isNotEmpty) {
      return t.stuname!;
    }
    if (t.stuId != null && _stuIdToName.containsKey(t.stuId)) {
      return _stuIdToName[t.stuId]!;
    }
    return '-';
  }

  Widget _buildDownloadButton(PaymentModel t) {
    final isReconciled = t.reconStatus == 'R';
    if (!isReconciled) {
      return Text('Pending Approval', style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600));
    }
    // No internal horizontal padding so the icon + label start flush with
    // the RECEIPT header text in the column above.
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _showReceiptOptions(t),
        icon: AppIcon('document-download', size: 16, color: AppColors.accent),
        label: Text('Download', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.accent), overflow: TextOverflow.visible, softWrap: false, maxLines: 1),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }

  Future<ReceiptData> _buildReceiptData(PaymentModel t) async {
    final stuName = _getStudentName(t);
    final student = t.stuId != null ? _stuIdToStudent[t.stuId] : null;
    final auth = context.read<AuthProvider>();
    final date = t.paydate ?? t.createdat;
    const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    final dateStr = '${months[date.month - 1]} ${date.day}, ${date.year}';

    // Fetch fee details from feedemand table
    List<ReceiptTermDetail> feeDetails = [];
    try {
      final details = await SupabaseService.getFeeDetailsByPayId(t.payId);
      if (details.isNotEmpty) {
        // Group by term — show month name from duedate for TUITION/VAN fees
        const monthFeeTypes = ['TUITION FEES', 'TUITION FEE', 'VAN FEES', 'VAN FEE'];
        final termMap = <String, List<ReceiptFeeItem>>{};
        for (final d in details) {
          String term = d['demfeeterm']?.toString() ?? '-';
          final feeType = d['demfeetype']?.toString() ?? d['feegroupname']?.toString() ?? 'Fee';
          // Line amount = actually collected in THIS payment (fee portion).
          // collectedamount comes from paymentdetails.transtotalamount; subtract
          // fineamount to isolate the fee portion and show Fine separately.
          final fine = (d['fineamount'] as num?)?.toDouble() ?? 0.0;
          final collected = (d['collectedamount'] as num?)?.toDouble()
              ?? (d['feeamount'] as num?)?.toDouble() ?? 0.0;
          final feeOnly = (collected - fine).clamp(0, double.infinity).toDouble();
          if (monthFeeTypes.contains(feeType.toUpperCase())) {
            final duedate = d['duedate'];
            if (duedate != null) {
              try {
                final dt = DateTime.parse(duedate.toString());
                term = months[dt.month - 1].toUpperCase();
              } catch (_) {}
            }
          }
          termMap.putIfAbsent(term, () => []);
          termMap[term]!.add(ReceiptFeeItem(type: feeType, amount: feeOnly));
          if (fine > 0) {
            termMap[term]!.add(ReceiptFeeItem(type: '  Fine', amount: fine));
          }
        }
        feeDetails = termMap.entries
            .map((e) => ReceiptTermDetail(term: e.key, fees: e.value))
            .toList();
      }
    } catch (e) {
      debugPrint('Error fetching fee details: $e');
    }

    // Fallback if no fee details found
    if (feeDetails.isEmpty) {
      feeDetails = [
        ReceiptTermDetail(
          term: t.yrlabel ?? '-',
          fees: [ReceiptFeeItem(type: 'Payment', amount: t.transtotalamount)],
        ),
      ];
    }

    return ReceiptData(
      receiptNo: t.paynumber ?? '${t.payId}',
      date: dateStr,
      studentName: stuName,
      mobileNo: student?.stumobile ?? '-',
      address: student?.stuaddress ?? '-',
      admissionNo: student?.stuadmno ?? '-',
      className: student?.stuclass ?? '-',
      courseName: student?.courname ?? '-',
      schoolName: _insName ?? auth.inscode ?? 'Institution',
      schoolAddress: _insAddress ?? '-',
      schoolLogoUrl: _insLogoUrl,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: feeDetails,
      paymentMethod: t.paymethod ?? '-',
      paymentDate: dateStr,
      status: t.isSuccess ? 'paid' : (t.paystatus == 'F' ? 'failed' : 'pending'),
      reconStatus: t.reconStatus ?? 'P',
      paymentReference: t.payreference,
      total: t.transtotalamount,
    );
  }

  void _showReceiptOptions(PaymentModel t) async {
    final receiptData = await _buildReceiptData(t);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
        child: SizedBox(
          width: 620,
          height: 920,
          child: Column(
            children: [
              // Action bar
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _downloadReceiptAsPdf(t);
                      },
                      icon: const AppIcon('document-download', size: 18),
                      label: const Text('Download'),
                    ),
                    SizedBox(width: 8.w),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _printReceipt(t);
                      },
                      icon: AppIcon('printer', size: 18),
                      label: const Text('Print'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                        elevation: 0,
                        textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                      ),
                    ),
                    SizedBox(width: 8.w),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: AppIcon.linear('close-circle', size: 20),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Receipt preview
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(12.w),
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ReceiptWidget(data: receiptData),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the receipt PDF via the shared B5 builder so every screen
  /// produces the identical Figma receipt design.
  Future<pw.Document> _buildReceiptPdf(PaymentModel t) async {
    final data = await _buildReceiptData(t);
    return buildReceiptPdf(data);
  }

  // ignore: unused_element
  Future<pw.Document> _legacyReceiptPdf(PaymentModel t) async {
    final data = await _buildReceiptData(t);

    final font = await PdfGoogleFonts.montserratRegular();
    final fontMedium = await PdfGoogleFonts.montserratMedium();
    final fontSemiBold = await PdfGoogleFonts.montserratSemiBold();
    final fontItalic = await PdfGoogleFonts.montserratItalic();
    final fontPtSerif = await PdfGoogleFonts.pTSerifRegular();

    const primaryBlue = PdfColor.fromInt(0xFF6C8EEF);
    const darkBlue = PdfColor.fromInt(0xFF4A6CD4);
    const textDark = PdfColor.fromInt(0xFF2a2a2a);
    const textMedium = PdfColor.fromInt(0xFF4c4c4c);
    const headerBg = PdfColor.fromInt(0xFFE9EEFF);
    const borderColor = PdfColor.fromInt(0xFFd9d9d9);
    const paidGreen = PdfColor.fromInt(0xFF34c759);
    const dividerColor = PdfColor.fromInt(0xFFACBEDD);

    final sSemiBold = pw.TextStyle(font: fontSemiBold, fontSize: 10, color: textDark);
    final sMedium = pw.TextStyle(font: fontMedium, fontSize: 10, color: textMedium);
    final sMediumDark = pw.TextStyle(font: fontMedium, fontSize: 10, color: textDark);

    pw.Widget labelValue(String label, String value) {
      return pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Text(label, style: sSemiBold),
          pw.SizedBox(width: 6),
          pw.Text(value, style: sMedium),
        ],
      );
    }

    pw.Widget tableCell(String text, pw.TextStyle style, {pw.Alignment alignment = pw.Alignment.center}) {
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        alignment: alignment,
        child: pw.Text(text, style: style),
      );
    }

    // Load logo image if available
    pw.ImageProvider? logoImage;
    if (data.schoolLogoUrl != null) {
      try {
        logoImage = await networkImage(data.schoolLogoUrl!);
      } catch (_) {}
    }

    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5,
        margin: const pw.EdgeInsets.all(40),
        theme: pw.ThemeData.withFont(base: font, bold: fontSemiBold, italic: fontItalic),
        build: (pw.Context ctx) {
          String formatAmount(double amount) {
            if (amount == amount.truncateToDouble()) {
              return amount.toInt().toString().replaceAllMapped(
                RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
            }
            return amount.toStringAsFixed(2).replaceAllMapped(
              RegExp(r'(\d)(?=(\d{3})+\.)'), (m) => '${m[1]},');
          }

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Header: Logo + School info (left) | Receipt title + No/Date (right)
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  // Left: Logo + School name + Address
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (logoImage != null)
                          pw.SizedBox(width: 64, height: 64,
                            child: pw.Image(logoImage, fit: pw.BoxFit.cover)),
                        if (logoImage != null) pw.SizedBox(height: 8),
                        pw.Text(data.schoolName, style: pw.TextStyle(font: fontSemiBold, fontSize: 14, color: darkBlue)),
                        pw.SizedBox(height: 6),
                        pw.Row(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text('Address:  ', style: sSemiBold),
                            pw.Expanded(child: pw.Text(data.schoolAddress, style: sMedium, maxLines: 3)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 20),
                  // Right: Receipt title + No + Date
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('Receipt', style: pw.TextStyle(font: fontSemiBold, fontSize: 32, color: primaryBlue)),
                      pw.SizedBox(height: 12),
                      labelValue('Receipt No:', data.receiptNo),
                      pw.SizedBox(height: 6),
                      labelValue('Date:', data.date),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 12),
              pw.Container(height: 1, color: dividerColor),
              pw.SizedBox(height: 12),
              // To section
              pw.Text('To:', style: pw.TextStyle(font: fontSemiBold, fontSize: 13, color: textDark)),
              pw.SizedBox(height: 8),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        labelValue('Name:', data.studentName),
                        pw.SizedBox(height: 6),
                        labelValue('Mobile No:', data.mobileNo),
                        pw.SizedBox(height: 6),
                        pw.Row(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text('Address:', style: sSemiBold),
                            pw.SizedBox(width: 6),
                            pw.Expanded(child: pw.Text(
                              (data.address.trim().isNotEmpty && data.address.trim() != '-' && data.address.trim().toLowerCase() != 'null') ? data.address : 'NA',
                              style: sMedium,
                            )),
                          ],
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 20),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      labelValue('Roll No:', data.admissionNo),
                      pw.SizedBox(height: 6),
                      labelValue('Class:', data.className),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 20),
              // Fee Table with stamp overlay
              pw.Stack(
                children: [
                  pw.Column(
                    children: [
                      pw.Table(
                        border: pw.TableBorder.all(color: borderColor, width: 0.5),
                        columnWidths: {
                          0: const pw.FixedColumnWidth(46),
                          1: const pw.FixedColumnWidth(125),
                          2: const pw.FlexColumnWidth(),
                          3: const pw.FixedColumnWidth(120),
                        },
                        children: [
                          pw.TableRow(
                            decoration: const pw.BoxDecoration(color: headerBg),
                            children: [
                              tableCell('S.No', sSemiBold.copyWith(color: primaryBlue)),
                              tableCell('Semester', sSemiBold.copyWith(color: primaryBlue)),
                              tableCell('Fee Type', sSemiBold.copyWith(color: primaryBlue)),
                              tableCell('Amount', sSemiBold.copyWith(color: primaryBlue)),
                            ],
                          ),
                          for (var i = 0; i < data.feeDetails.length; i++)
                            pw.TableRow(
                              children: [
                                pw.Container(
                                  padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  alignment: pw.Alignment.topCenter,
                                  child: pw.Text('${i + 1}.', style: sMediumDark),
                                ),
                                pw.Container(
                                  padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  alignment: pw.Alignment.topCenter,
                                  child: pw.Text(data.feeDetails[i].term, style: sMediumDark),
                                ),
                                pw.Container(
                                  padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  child: pw.Column(
                                    children: [
                                      for (final fee in data.feeDetails[i].fees)
                                        pw.Padding(
                                          padding: const pw.EdgeInsets.symmetric(vertical: 2),
                                          child: pw.Text(fee.type, style: sMediumDark, textAlign: pw.TextAlign.center),
                                        ),
                                    ],
                                  ),
                                ),
                                pw.Container(
                                  padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  child: pw.Column(
                                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                                    children: [
                                      for (final fee in data.feeDetails[i].fees)
                                        pw.Padding(
                                          padding: const pw.EdgeInsets.symmetric(vertical: 2),
                                          child: pw.Text('\u20B9${formatAmount(fee.amount)}', style: sMediumDark, textAlign: pw.TextAlign.right),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      // Sub Total row
                      pw.Row(
                        children: [
                          pw.SizedBox(width: 172),
                          pw.Expanded(
                            child: pw.Container(
                              padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: const pw.BoxDecoration(color: primaryBlue),
                              child: pw.Row(
                                children: [
                                  pw.Expanded(
                                    child: pw.Text('Sub Total', style: pw.TextStyle(font: fontSemiBold, fontSize: 10, color: PdfColors.white), textAlign: pw.TextAlign.right),
                                  ),
                                  pw.SizedBox(
                                    width: 119,
                                    child: pw.Text('\u20B9${formatAmount(data.total)}', style: pw.TextStyle(font: fontSemiBold, fontSize: 10, color: PdfColors.white), textAlign: pw.TextAlign.right),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  // Status stamp overlay – between Term and Fee Type columns
                  if (data.status == 'paid' || data.status == 'failed')
                    pw.Positioned(
                      left: 120, top: 40,
                      child: pw.Opacity(
                        opacity: 0.55,
                        child: pw.Transform.rotateBox(
                          angle: -0.40,
                          child: pw.Container(
                            padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 5),
                            decoration: pw.BoxDecoration(
                              color: PdfColor.fromInt(data.status == 'paid' ? 0x66c2eecd : 0x66FFD6D6),
                              borderRadius: pw.BorderRadius.circular(10.r),
                              border: pw.Border.all(
                                color: data.status == 'paid' ? paidGreen : const PdfColor.fromInt(0xFFFF3B30),
                                width: 2.5,
                              ),
                            ),
                            child: pw.Text(
                              data.status == 'paid' ? 'PAID' : 'FAILED',
                              style: pw.TextStyle(
                                font: fontSemiBold,
                                fontSize: 20,
                                color: data.status == 'paid' ? paidGreen : const PdfColor.fromInt(0xFFFF3B30),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              pw.SizedBox(height: 20),
              // Payment info
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  labelValue('Receipt Method:', data.paymentMethod.toLowerCase() == 'razorpay' ? 'Online' : data.paymentMethod),
                  pw.SizedBox(height: 6),
                  labelValue('Status:', data.status == 'paid' ? 'Paid' : data.status == 'failed' ? 'Failed' : data.status),
                  if (ReceiptWidget.isOnlineMethod(data.paymentMethod) &&
                      ReceiptWidget.formatReference(data.paymentReference).isNotEmpty) ...[
                    pw.SizedBox(height: 6),
                    labelValue('Reference:', ReceiptWidget.formatReference(data.paymentReference)),
                  ],
                ],
              ),
              pw.Spacer(),
              // Footer
              pw.Center(
                child: pw.Text('Thank you for your payment.', style: pw.TextStyle(font: fontPtSerif, fontSize: 14, color: textDark)),
              ),
              pw.SizedBox(height: 8),
              if (data.schoolEmail != null || data.schoolMobile != null)
                pw.Center(
                  child: pw.Text(
                    'For any further inquiries, please contact us at '
                    '${data.schoolEmail ?? ''}'
                    '${data.schoolEmail != null && data.schoolMobile != null ? ' or\ncall ' : ''}'
                    '${data.schoolMobile ?? ''}',
                    style: pw.TextStyle(font: fontMedium, fontSize: 10, color: textMedium),
                    textAlign: pw.TextAlign.center,
                  ),
                ),
            ],
          );
        },
      ),
    );
    return pdf;
  }

  Future<void> _downloadReceiptAsPdf(PaymentModel t) async {
    try {
      final pdf = await _buildReceiptPdf(t);
      final bytes = await pdf.save();
      final fileName = 'Receipt_${(t.paynumber ?? '${t.payId}').replaceAll('/', '_')}.pdf';

      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Receipt',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null) {
        final file = File(result);
        await file.writeAsBytes(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Receipt saved to $result'), backgroundColor: AppColors.accent),
          );
        }
      }
    } catch (e) {
      debugPrint('Error downloading receipt: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _printReceipt(PaymentModel t) async {
    try {
      final pdf = await _buildReceiptPdf(t);
      await Printing.layoutPdf(
        // Match the A5 page so the printer doesn't fall back to A4 and clip
        // the right edge.
        format: a5PageFormat,
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: 'Receipt_${(t.paynumber ?? '${t.payId}').replaceAll('/', '_')}',
      );
    } catch (e) {
      debugPrint('Error printing receipt: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDrilldown = _drilldownFilter != null;
    return Column(
      children: [
        if (isDrilldown)
          _buildDrilldownHeader()
        else ...[
          // Summary cards
          _buildSummaryCards(),
          SizedBox(height: 10.h),
        ],
        // 3. Combined header + table card
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      AppIcon('receipt-2',
                          color: AppColors.accent, size: 20),
                      SizedBox(width: 8.w),
                      Text(
                        'Transactions',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const Spacer(),
                      // In drill-down mode these move to the back-button card.
                      if (!isDrilldown) ..._toolbarActions(),
                    ],
                  ),
                ),
                // Table
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _buildAllTransactionTable(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Search + date/method filter + refresh — shared by the table-card
  /// header (main view) and the drill-down header card.
  List<Widget> _toolbarActions() {
    return [
      AppSearchField(
        controller: _searchController,
        hintText: 'Search by name, roll no or class…',
        onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
        width: 320,
        suffixIcon: _searchQuery.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.only(right: 10),
                child: IconButton(
                  icon: const AppIcon('close-circle', size: 14),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  splashRadius: 12,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              )
            : null,
      ),
      SizedBox(width: AppBtn.gap(context)),
      SizedBox(
        height: AppBtn.height(context),
        child: OutlinedButton.icon(
          onPressed: _openDateRangeDialog,
          icon: AppIcon.linear('calendar',
              size: AppBtn.iconSize(context), color: AppColors.textPrimary),
          label: Text(_dateRangeLabel(),
              style: TextStyle(
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 14.w),
            side: const BorderSide(color: AppColors.border),
          ),
        ),
      ),
      SizedBox(width: AppBtn.gap(context)),
      SizedBox(
        height: AppBtn.height(context),
        child: ElevatedButton.icon(
          onPressed: _fetchData,
          icon: AppIcon('refresh',
              size: AppBtn.iconSize(context), color: Colors.white),
          label: const Text('Refresh'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF10B981),
            foregroundColor: Colors.white,
            elevation: 0,
          ),
        ),
      ),
    ];
  }

  /// Drill-down header — Back button + breadcrumb inside a white card,
  /// matching the Fee Collection › Total Collection drill-down design.
  Widget _buildDrilldownHeader() {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final hPad = compact ? 10.0 : 14.0;
    final radius = compact ? 6.0 : 10.0;
    final textSize = compact ? 11.0 : 13.0;
    final innerGap = compact ? 4.0 : 6.0;
    return Padding(
      padding: EdgeInsets.only(bottom: 10.h),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            InkWell(
              onTap: _closeDrilldown,
              borderRadius: BorderRadius.circular(radius),
              child: Container(
                height: AppBtn.height(context),
                padding: EdgeInsets.symmetric(horizontal: hPad),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon.linear('Chevron Left',
                        size: AppBtn.iconSize(context), color: Colors.white),
                    SizedBox(width: innerGap),
                    Text('Back',
                        style: TextStyle(
                            fontSize: textSize,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ],
                ),
              ),
            ),
            SizedBox(width: 12.w),
            Container(width: 1, height: 18, color: AppColors.border),
            SizedBox(width: 12.w),
            Text('Transactions',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary)),
            SizedBox(width: 6.w),
            AppIcon.linear('Chevron Right',
                size: 14, color: AppColors.textSecondary),
            SizedBox(width: 6.w),
            Text(_drilldownTitle(),
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const Spacer(),
            ..._toolbarActions(),
          ],
        ),
      ),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _dateRangeLabel() {
    final hasDate = _filterFromDate != null || _filterToDate != null;
    final hasMethod = _filterMethods.isNotEmpty;
    if (!hasDate && !hasMethod) return 'Date & Mode';

    String datePart;
    if (!hasDate) {
      datePart = 'All Dates';
    } else if (_filterFromDate != null && _filterToDate != null) {
      datePart = '${_fmtDate(_filterFromDate!)} – ${_fmtDate(_filterToDate!)}';
    } else if (_filterFromDate != null) {
      datePart = 'From ${_fmtDate(_filterFromDate!)}';
    } else {
      datePart = 'Until ${_fmtDate(_filterToDate!)}';
    }
    if (hasMethod) {
      return '$datePart · ${_filterMethods.length} method${_filterMethods.length == 1 ? '' : 's'}';
    }
    return datePart;
  }

  Future<void> _openDateRangeDialog() async {
    // Build the chip set from the modes actually present in the loaded
    // transactions — keeps the filter list tight to what the user can act on.
    final availableMethods = <String>{};
    for (final t in _allTransactions) {
      final m = (t.paymethod ?? '').toLowerCase().trim();
      if (m.isNotEmpty && m != '-') availableMethods.add(m);
    }
    final methodList = availableMethods.toList()..sort();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        DateTime? from = _filterFromDate;
        DateTime? to = _filterToDate;
        final Set<String> methods = {..._filterMethods};
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          // Determine which preset matches the current from/to range so
          // its chip can be highlighted as selected.
          String activePreset() {
            if (from == null && to == null) return 'All';
            if (from == null || to == null) return '';
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            bool sameDay(DateTime a, DateTime b) =>
                a.year == b.year && a.month == b.month && a.day == b.day;
            if (sameDay(from!, today) && sameDay(to!, today)) return 'Today';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 7)))) return '7 Days';
            if (sameDay(to!, today) && sameDay(from!, now.subtract(const Duration(days: 30)))) return '30 Days';
            return '';
          }
          final preset = activePreset();
          Widget presetChip(String label, VoidCallback onTap) {
            final selected = preset == label;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.accent : AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            );
          }

          Widget methodChip(String m) {
            final selected = methods.contains(m);
            return Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: InkWell(
                onTap: () => setStateDialog(() {
                  if (selected) {
                    methods.remove(m);
                  } else {
                    methods.add(m);
                  }
                }),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                  ),
                  child: Text(
                    m.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w700,
                      color: selected ? AppColors.accent : AppColors.textPrimary,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            );
          }

          Widget datePickerBox({required String hint, required DateTime? value, required ValueChanged<DateTime?> onChanged}) {
            return InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (picked != null) onChanged(picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIcon.linear('calendar', size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Text(value != null ? _fmtDate(value) : hint,
                        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
                  ],
                ),
              ),
            );
          }

          Widget sectionLabel(String text) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(text, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.3)),
              );

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            title: Row(
              children: [
                Text('Filters', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const AppIcon.linear('close-circle', size: 20, color: AppColors.textSecondary),
                  splashRadius: 18,
                  tooltip: 'Close',
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  sectionLabel('QUICK RANGE'),
                  Row(children: [
                    presetChip('Today', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = DateTime(now.year, now.month, now.day); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('7 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 7)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('30 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() { from = now.subtract(const Duration(days: 30)); to = DateTime(now.year, now.month, now.day); });
                    }),
                    presetChip('All', () {
                      setStateDialog(() { from = null; to = null; });
                    }),
                  ]),
                  const SizedBox(height: 16),
                  sectionLabel('CUSTOM RANGE'),
                  Row(children: [
                    Expanded(child: datePickerBox(hint: 'From', value: from, onChanged: (d) => setStateDialog(() => from = d))),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('—')),
                    Expanded(child: datePickerBox(hint: 'To', value: to, onChanged: (d) => setStateDialog(() => to = d))),
                  ]),
                  if (methodList.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    sectionLabel('PAYMENT METHOD'),
                    Wrap(children: methodList.map(methodChip).toList()),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setStateDialog(() { from = null; to = null; methods.clear(); }),
                child: Text('Clear', style: TextStyle(color: AppColors.textSecondary, fontSize: 13.sp, fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  setState(() {
                    _filterFromDate = from;
                    _filterToDate = to;
                    _filterMethods
                      ..clear()
                      ..addAll(methods);
                  });
                  Navigator.pop(ctx);
                },
                child: const Text('Apply'),
              ),
            ],
          );
        });
      },
    );
  }

  List<PaymentModel> _applyDateFilter(List<PaymentModel> list) {
    var filtered = list;
    if (_filterFromDate != null || _filterToDate != null) {
      filtered = filtered.where((t) {
        final date = t.paydate ?? t.createdat;
        final dateOnly = DateTime(date.year, date.month, date.day);
        if (_filterFromDate != null && dateOnly.isBefore(_filterFromDate!)) return false;
        if (_filterToDate != null && dateOnly.isAfter(_filterToDate!)) return false;
        return true;
      }).toList();
    }
    if (_filterMethods.isNotEmpty) {
      filtered = filtered.where((t) {
        final m = (t.paymethod ?? '').toLowerCase();
        return _filterMethods.contains(m);
      }).toList();
    }
    return filtered;
  }

  Widget _buildSummaryCards() {
    final filteredPaid = _applyDateFilter(_paidTransactions);
    final filteredFailed = _applyDateFilter(_failedTransactions);
    final paidTotal = filteredPaid.fold<double>(
        0, (sum, t) => sum + t.transtotalamount);
    final failedTotal = filteredFailed.fold<double>(
        0, (sum, t) => sum + t.transtotalamount);

    return Row(
      children: [
        Expanded(
          child: _buildSummaryCard(
            'Total Paid',
            '\u20B9 ${paidTotal.toStringAsFixed(2)}',
            '${filteredPaid.length} transactions',
            Colors.green,
            'tick-circle',
            onTap: () => _openDrilldown('paid'),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _buildSummaryCard(
            'Total Failed',
            '\u20B9 ${failedTotal.toStringAsFixed(2)}',
            '${filteredFailed.length} transactions',
            Colors.red,
            'info-circle',
            onTap: () => _openDrilldown('failed'),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _buildSummaryCard(
            'Total Transactions',
            '${filteredPaid.length + filteredFailed.length}',
            'All records',
            AppColors.primary,
            'receipt-2',
            onTap: () => _openDrilldown('all'),
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(
      String title, String value, String subtitle, Color color, String icon,
      {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14.r),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12.r),
              ),
              child: AppIcon(icon, color: color, size: 22),
            ),
            SizedBox(width: 14.w),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.sp,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 4.h),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 21.sp,
                      fontWeight: FontWeight.w800,
                      color: color,
                      height: 1.1,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 4.h),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 8.w),
            AppIcon.linear('Chevron Right',
                size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  // ── Sticky-header table ──
  // Reference column was dropped — the same details surface via the receipt
  // download. Payment Method renamed to "Mode" for brevity.
  static const _txColWidths = <double>[60, 110, 100, 130, 180, 120, 120, 100, 90, 120];
  static const _txHeaders = <String>[
    'S NO.', 'DATE', 'RECEIPT NO', 'ROLL NO', 'NAME', 'CLASS',
    'MODE', 'AMOUNT', 'STATUS', 'RECEIPT',
  ];

  // Persistent horizontal scroll controllers per tab so the scrollbar thumb tracks scroll state
  final Map<String, ScrollController> _hCtrls = {};
  ScrollController _hCtrlFor(String key) => _hCtrls.putIfAbsent(key, () => ScrollController());

  // Vertical scroll controllers, one per table (all/paid/failed). Kept
  // separate from the horizontal ones so the custom vertical scrollbar can
  // live in a lane pinned to the viewport instead of off-screen at the
  // far-right edge of the (wider) horizontally-scrolling content.
  final Map<String, ScrollController> _vCtrls = {};
  ScrollController _vCtrlFor(String key) => _vCtrls.putIfAbsent(key, () => ScrollController());

  Widget _buildStickyTable(List<PaymentModel> transactions, {bool? fixedIsPaid}) {
    final cellStyle = TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w600);
    final headerStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: 13.sp, color: AppColors.textPrimary, letterSpacing: 0.3);

    final baseTotal = _txColWidths.fold<double>(0, (a, b) => a + b) + 32;
    final ctrlKey = fixedIsPaid == null ? 'all' : (fixedIsPaid ? 'paid' : 'failed');
    final hController = _hCtrlFor(ctrlKey);
    final vController = _vCtrlFor(ctrlKey);

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: LayoutBuilder(builder: (ctx, constraints) {
          // The vertical scrollbar always occupies a 16px lane on the right,
          // so the horizontal viewport for the content is that much narrower.
          const vBarWidth = 16.0;
          final viewportW = constraints.maxWidth - vBarWidth;
          final needsHScroll = baseTotal > viewportW;
          // If viewport is wider than the base width, scale columns up proportionally
          // so the table fills the available width. Otherwise keep fixed widths and scroll.
          final scale = needsHScroll ? 1.0 : (viewportW / baseTotal);
          final widths = [for (final w in _txColWidths) w * scale];
          final contentWidth = needsHScroll ? baseTotal : viewportW;
          final scrollbarHeight = needsHScroll ? 16.0 : 0.0;

          Widget headerRow = Container(
            color: AppColors.tableHeadBg,
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
            width: contentWidth,
            child: Row(
              children: [
                for (int c = 0; c < _txHeaders.length; c++)
                  SizedBox(width: widths[c], child: Text(_txHeaders[c], style: headerStyle, overflow: TextOverflow.ellipsis)),
              ],
            ),
          );

          Widget bodyRow(int i) {
            final t = transactions[i];
            final stuName = _getStudentName(t);
            final stu = t.stuId != null ? _stuIdToStudent[t.stuId] : null;
            final isSuccess = fixedIsPaid ?? t.isSuccess;
            final statusColor = isSuccess ? Colors.green : Colors.red;
            final statusText = isSuccess ? 'Paid' : 'Failed';
            final date = (fixedIsPaid == true ? t.paydate : (fixedIsPaid == false ? t.createdat : (t.paydate ?? t.createdat)));
            final dateStr = date != null
                ? '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}'
                : '-';
            return Container(
              color: i.isEven ? Colors.white : AppColors.surface,
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
              width: contentWidth,
              child: Row(
                children: [
                  SizedBox(width: widths[0], child: Text('${i + 1}', style: cellStyle)),
                  SizedBox(width: widths[1], child: Text(dateStr, style: cellStyle)),
                  SizedBox(width: widths[2], child: Text(t.paynumber ?? '—', style: cellStyle)),
                  SizedBox(width: widths[3], child: Text(stu?.stuadmno ?? '-', style: cellStyle, overflow: TextOverflow.ellipsis)),
                  SizedBox(width: widths[4], child: Text(stuName, style: cellStyle, overflow: TextOverflow.ellipsis)),
                  SizedBox(width: widths[5], child: Text(stu?.stuclass ?? '-', style: cellStyle)),
                  SizedBox(width: widths[6], child: Text(t.paymethod ?? '-', style: cellStyle)),
                  SizedBox(width: widths[7], child: Text(t.transtotalamount.toStringAsFixed(2), style: cellStyle)),
                  SizedBox(
                    width: widths[8],
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: statusColor.shade50, borderRadius: BorderRadius.circular(8.r)),
                        child: Text(statusText, style: TextStyle(color: statusColor.shade700, fontWeight: FontWeight.w600, fontSize: 13.sp)),
                      ),
                    ),
                  ),
                  SizedBox(width: widths[9], child: t.isSuccess ? _buildDownloadButton(t) : const SizedBox.shrink()),
                ],
              ),
            );
          }

          // Body list — framework scrollbar suppressed; the pinned bar on the
          // right drives it instead.
          final body = ScrollConfiguration(
            behavior: ScrollConfiguration.of(ctx).copyWith(scrollbars: false),
            child: ListView.separated(
              controller: vController,
              itemCount: transactions.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.4)),
              itemBuilder: (_, i) => bodyRow(i),
            ),
          );

          return Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: hController,
                        scrollDirection: Axis.horizontal,
                        physics: needsHScroll ? null : const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: contentWidth,
                          height: constraints.maxHeight - scrollbarHeight,
                          child: Column(
                            children: [
                              headerRow,
                              Container(height: 1, color: AppColors.border),
                              Expanded(child: body),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Vertical scrollbar pinned to the viewport — top spacer
                    // carries the header colour so the band reads as a
                    // continuous full-width strip with the bar only below it.
                    Column(
                      children: [
                        Container(width: 16, color: AppColors.tableHeadBg, child: SizedBox(height: 12.h * 2 + 18)),
                        Expanded(child: AppScrollbarBar(controller: vController)),
                      ],
                    ),
                  ],
                ),
              ),
              if (needsHScroll)
                Row(
                  children: [
                    Expanded(
                      child: ClassicHScrollbar(
                        controller: hController,
                        contentWidth: contentWidth,
                        viewportWidth: viewportW,
                      ),
                    ),
                    // Corner gap aligning the horizontal bar with the content
                    // viewport, not the vertical scrollbar lane.
                    const SizedBox(width: vBarWidth),
                  ],
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildAllTransactionTable() {
    final allTransactions = _allTransactions;
    if (allTransactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('receipt-2',
                size: 64, color: AppColors.accent.withValues(alpha: 0.5)),
            SizedBox(height: 16.h),
            Text(
              'No Transactions',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
            ),
          ],
        ),
      );
    }
    return _buildStickyTable(allTransactions);
  }

  Widget _buildTransactionTable(List<PaymentModel> allItems, {required bool isPaid}) {
    if (allItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              isPaid ? 'wallet-money' : 'tick-circle',
              size: 64,
              color: AppColors.accent.withValues(alpha: 0.5),
            ),
            SizedBox(height: 16.h),
            Text(
              isPaid ? 'No Paid Transactions' : 'No Failed Transactions',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
            ),
            SizedBox(height: 8.h),
            Text(
              isPaid
                  ? 'No completed payments found.'
                  : 'All transactions have been processed successfully.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary.withValues(alpha: 0.7),
                  ),
            ),
          ],
        ),
      );
    }
    return _buildStickyTable(allItems, fixedIsPaid: isPaid);
  }
}
