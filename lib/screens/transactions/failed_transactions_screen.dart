import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/payment_model.dart';
import '../../utils/formatters.dart';
import '../../models/student_model.dart';
import '../../widgets/receipt_widget.dart';
import '../../utils/receipt_pdf.dart';
import '../../utils/friendly_error.dart';
import '../../services/pending_collection_sweep.dart';
import '../../utils/school_terms.dart';

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
  List<PaymentModel> _reversedTransactions = []; // refunded + cancelled (paystatus 'R')
  /// paystatus 'I' -- started at the gateway, never resolved either way.
  ///
  /// Deliberately NOT folded into Failed. A pending payment may have been
  /// captured by Paytm with the app never hearing back; showing it as failed
  /// is what made Rs 91,500 of real receipts look like nothing happened.
  /// These are the rows the orphan sweep and the webhook act on, so the
  /// counter should be able to see them rather than discover them later.
  List<PaymentModel> _pendingTransactions = [];

  /// Captures Paytm confirmed that the database REFUSED to receipt -- money
  /// the college holds with nothing on any student's ledger against it.
  ///
  /// These were recorded from the day the webhook learned to record them and
  /// shown to nobody: the table is service_role only and no screen read it.
  /// A Rs 2,700 capture on 12-10-2026 was flagged 2.9 seconds after it
  /// happened and still took nineteen hours and a morning of log reading to
  /// attribute, because the alarm rang into an empty room.
  ///
  /// Not filtered by the date range. A refusal is outstanding until somebody
  /// deals with it; hiding last week's because the picker says today is how
  /// one goes unnoticed for a month.
  List<Map<String, dynamic>> _refusals = [];
  final Map<int, String> _txType = {};   // payId -> Regular/Arrear/Misc/Cancelled
  final Map<int, String> _txStatus = {}; // payId -> Paid/Failed/Refunded/Cancelled
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
    // Search filter - name, roll no, class.
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
      case 'pending':
        all = [..._pendingTransactions];
        break;
      default:
        all = [
          ..._paidTransactions,
          ..._failedTransactions,
          ..._reversedTransactions,
          ..._pendingTransactions,
        ];
    }
    all.sort(_byReceiptDesc);
    return _filterBySearch(all);
  }

  /// Receipt-number order, newest first.
  ///
  /// Compares the trailing digits numerically rather than as text, so
  /// FC26/02673 sorts above FC26/0999 instead of below it once the counter
  /// rolls past a digit boundary. Fee and Misc receipts draw from the same
  /// sequence, so this interleaves them correctly -- sorting by date alone left
  /// every same-day receipt in whatever order the two queries happened to
  /// return, which is why the Misc rows all landed after the fee rows.
  static int _receiptNo(String? s) {
    if (s == null) return -1;
    final m = RegExp(r'(\d+)\s*$').firstMatch(s.trim());
    return m == null ? -1 : (int.tryParse(m.group(1)!) ?? -1);
  }

  static int _byReceiptDesc(PaymentModel a, PaymentModel b) {
    // DATE first, newest day at the top. Receipt number alone is not a proxy
    // for recency: the series run on separate counters, so AFR2600166 outranks
    // FC26/02673 numerically while being the older receipt.
    final da = a.paydate ?? a.createdat, db = b.paydate ?? b.createdat;
    final dayA = DateTime(da.year, da.month, da.day);
    final dayB = DateTime(db.year, db.month, db.day);
    if (dayA != dayB) return dayB.compareTo(dayA);

    // Within a day, highest receipt number first. Compared numerically so the
    // order holds once the counter crosses a digit boundary, and so Fee and
    // Misc receipts interleave -- they draw from the same sequence.
    final na = _receiptNo(a.paynumber), nb = _receiptNo(b.paynumber);
    if (na != nb) return nb.compareTo(na);

    // Same day and same number: fall back to the timestamp, then the raw
    // string, so the order stays stable between rebuilds.
    final c = db.compareTo(da);
    return c != 0 ? c : (b.paynumber ?? '').compareTo(a.paynumber ?? '');
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // Open on today. The screen loads the full history either way -- the
    // filter is applied client-side -- but a cashier arriving here wants the
    // day's receipts, not 2,800 rows to scroll past. Widen it from Date & Mode.
    final now = DateTime.now();
    _filterFromDate = DateTime(now.year, now.month, now.day);
    _filterToDate = DateTime(now.year, now.month, now.day);
    _fetchData();
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

  /// An advance has no `payment` row, so it borrows a synthetic pay_id the way
  /// a misc collection does. Misc uses -mc_id; advances are pushed past this
  /// offset so the two id spaces can never collide and hand one row's receipt
  /// to the other.
  static const int _advIdOffset = 1000000000;
  /// Unfinished misc/advance collections live in public.pending_collection,
  /// which is keyed by a TEXT order id, so they get synthetic ids from a
  /// third range that cannot collide with misc (-mc_id) or advance
  /// (-(1e9 + adv_id)). They are rebuilt on every fetch and are only ever
  /// map keys within one load -- nothing persists them.
  static const int _pendingIdOffset = 2000000000;
  static int _advPayId(int advId) => -(_advIdOffset + advId);
  static int _advIdOf(int payId) => -payId - _advIdOffset;
  static bool _isAdvance(PaymentModel t) => t.payreference == 'ADVANCE';

  Future<void> _fetchData() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    try {
      // Resolve anything unfinished, so this screen answers its own question.
      // It is where a pending collection is noticed, and it was the one screen
      // that could show you money at risk without being able to do anything
      // about it.
      //
      // NOT awaited. It used to run first and block the whole load, which put
      // one Paytm round trip per open intent -- sequentially -- in front of
      // every refresh, including a refresh of a day with nothing on it. The
      // sweep already runs at login and every five minutes
      // (PendingCollectionSweep.startAuto), so the list is drawn from what is
      // known now and refreshed only if this pass actually changed something.
      unawaited(PendingCollectionSweep.run(
              insId: insId, sessionToken: auth.sessionToken)
          .then((r) {
            if (r.didSomething && mounted && !_isLoading) _fetchData();
          })
          .catchError((Object e) {
            debugPrint('pending collection sweep: $e');
          }));
      // Only the visible range is fetched. Widening the date filter refetches
      // (see the Date & Mode dialog), so nothing is missing -- it is just not
      // loaded until it is asked for.
      final from = _filterFromDate;
      final to = _filterToDate;
      // Unresolved refusals, alongside the list rather than before it. A
      // failure here must never stop the screen drawing -- it is an extra
      // warning, not the data the screen exists for.
      unawaited(SupabaseService.listWebhookRefusals(insId).then((r) {
        if (mounted) setState(() => _refusals = r);
      }).catchError((Object e) {
        debugPrint('webhook refusals: $e');
      }));

      final results = await Future.wait([
        SupabaseService.getAllTransactions(insId, from: from, to: to),
        SupabaseService.getInstitutionInfo(insId),
      ]);

      final allData = results[0] as List<Map<String, dynamic>>;
      final paidData = allData.where((t) => t['paystatus'] == 'C').toList();
      final failedData = allData.where((t) => t['paystatus'] == 'F').toList();
      final reversedData = allData.where((t) => t['paystatus'] == 'R').toList();
      final pendingData = allData.where((t) => t['paystatus'] == 'I').toList();

      final insInfo = results[1] as ({String? name, String? logo, String? address, String? mobile, String? email});

      // The students map carries roll no, class and the receipt's address and
      // mobile. It used to come from getStudents(), which pulls `select('*')`
      // for every active student -- four paged round trips and several megabytes
      // -- to answer a dozen lookups. Only the students actually on screen are
      // fetched now; the ids from misc and advance are added below, once those
      // rows are in.
      final stuIdsOnScreen = <int>{
        for (final t in allData)
          if ((t['stu_id'] as num?) != null) (t['stu_id'] as num).toInt(),
      };

      // Include miscellaneous collections as paid transactions.
      // Marked with payreference='MISC' so TYPE shows the Misc chip and the
      // receipt is built from misc_collection. Roll No/Class resolve via stu_id.
      final miscPaid = <PaymentModel>[];
      try {
        final miscRows = await SupabaseService.fetchAll(() {
          var q = SupabaseService
              .fromSchema('misc_collection')
              .select('mc_id, mcno, mcdate, stu_id, stuname, paymode, totalamount, collectedby, recon_status')
              .eq('ins_id', insId).eq('activestatus', 1);
          if (from != null && to != null) {
            String d(DateTime x) => '${x.year.toString().padLeft(4, '0')}-'
                '${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
            q = q.gte('mcdate', d(from)).lte('mcdate', d(to));
          }
          return q;
        });
        for (final m in miscRows) {
          final dt = DateTime.tryParse(m['mcdate']?.toString() ?? '');
          final msid = (m['stu_id'] as num?)?.toInt();
          if (msid != null) stuIdsOnScreen.add(msid);
          miscPaid.add(PaymentModel(
            payId: -((m['mc_id'] as num?)?.toInt() ?? 0),
            paynumber: m['mcno']?.toString(),
            insId: insId,
            stuId: (m['stu_id'] as num?)?.toInt(),
            transtotalamount: (m['totalamount'] as num?)?.toDouble() ?? 0,
            paydate: dt,
            paystatus: 'C',
            paymethod: m['paymode']?.toString(),
            payreference: 'MISC',
            createdby: m['collectedby']?.toString(),
            createdat: dt ?? DateTime.now(),
            stuname: m['stuname']?.toString(),
            // Was hard-coded 'R'. Misc now reconciles like a fee payment, so a
            // UPI misc receipt awaiting approval must say so here too --
            // otherwise this screen offers its receipt while Pending Approval
            // and Bank Reconciliation both hold it. Null (column not yet added)
            // reads as 'R', which is how misc behaved before reconciliation.
            reconStatus: m['recon_status']?.toString() ?? 'R',
          ));
        }
      } catch (e) {
        debugPrint('Transactions misc merge error: $e');
      }

      // Include ADVANCE collections as paid transactions. Marked with
      // payreference='ADVANCE' so TYPE shows the Advance chip and the receipt is
      // built from advance_collection. These are real money over the counter --
      // leaving them out made the day's transaction list disagree with the
      // drawer. (The matching Advance Adjustment receipts DO have payment rows
      // and already appear; they move no new money, which is why they show a
      // mode of 'Advance Adjustment'.)
      final advancePaid = <PaymentModel>[];
      // adv_ids whose receipt is cancelled / has had money given back. The row
      // still lists; only its status chip differs.
      final advanceCancelled = <int>{};
      final advanceRefunded = <int>{};
      try {
        final advRows = await SupabaseService.fetchAll(() {
          var q = SupabaseService
              .fromSchema('advance_collection')
              .select('adv_id, advno, advdate, stu_id, stuadmno, stuname, stuclass, '
                  'paymethod, transtotalamount, createdby, recon_status, '
                  'activestatus, refund_amount')
              // Cancelled advances (activestatus 9) are listed too, marked
              // Cancelled, rather than vanishing from a day already reconciled.
              .eq('ins_id', insId)
              .inFilter('activestatus', [1, 9])
              .inFilter('paystatus', ['C', 'R']);
          if (from != null && to != null) {
            String d(DateTime x) => '${x.year.toString().padLeft(4, '0')}-'
                '${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
            // advdate is a timestamp, so the upper bound is the NEXT day
            // exclusive -- lte on the date alone drops everything after
            // midnight on the last day of the range.
            final next = to.add(const Duration(days: 1));
            q = q.gte('advdate', d(from)).lt('advdate', d(next));
          }
          return q;
        });
        for (final a in advRows) {
          final dt = DateTime.tryParse(a['advdate']?.toString() ?? '');
          final asid = (a['stu_id'] as num?)?.toInt();
          if (asid != null) stuIdsOnScreen.add(asid);
          final isCancelled = ((a['activestatus'] as num?)?.toInt() ?? 1) == 9;
          final refunded =
              ((a['refund_amount'] as num?)?.toDouble() ?? 0) > 0.005;
          if (isCancelled) {
            advanceCancelled.add((a['adv_id'] as num?)?.toInt() ?? 0);
          } else if (refunded) {
            advanceRefunded.add((a['adv_id'] as num?)?.toInt() ?? 0);
          }
          advancePaid.add(PaymentModel(
            payId: _advPayId((a['adv_id'] as num?)?.toInt() ?? 0),
            paynumber: a['advno']?.toString(),
            insId: insId,
            stuId: (a['stu_id'] as num?)?.toInt(),
            transtotalamount: (a['transtotalamount'] as num?)?.toDouble() ?? 0,
            paydate: dt,
            paystatus: 'C',
            paymethod: a['paymethod']?.toString(),
            payreference: 'ADVANCE',
            createdby: a['createdby']?.toString(),
            createdat: dt ?? DateTime.now(),
            stuname: a['stuname']?.toString(),
            reconStatus: a['recon_status']?.toString() ?? 'R',
          ));
        }
      } catch (e) {
        // The table may not exist yet on this database — the rest of the
        // screen must still load.
        debugPrint('Transactions advance merge error: $e');
      }

      // Classify each transaction's TYPE (Regular/Arrear/Misc/Cancelled) and
      // MISC AND ADVANCE THAT NEVER FINISHED.
      //
      // misc_collection has no paystatus at all and advance rows are written
      // only on success, so an attempt that was never completed appears in
      // NEITHER table -- which is exactly why a late capture used to be
      // unrecoverable. public.pending_collection is the record of what was
      // being collected, written before the gateway is contacted, so it is the
      // only place these can be shown from.
      //
      //   I/P -> Pending  (the gateway has not given a final answer, or a
      //                    sweep is mid-flight). Money may well have been taken.
      //   X/F -> Failed   (abandoned, or Paytm said so)
      //   C   -> skipped  -- the real receipt is already listed above.
      final pendingCollections = <PaymentModel>[];
      final failedCollections = <PaymentModel>[];
      // Written into local maps and merged below: txType/txStatus are not
      // declared until after this block.
      final pendingType = <int, String>{};
      final pendingStatus = <int, String>{};
      try {
        // Read through the RPC, not the table: pending_collection is REVOKEd
        // from anon so a client cannot forge a row that would read as money
        // received, and the revoke takes SELECT with it. The function is gated
        // on a session because misc and advance are admin-only.
        String? d(DateTime? x) => x == null
            ? null
            : '${x.year.toString().padLeft(4, '0')}-'
                '${x.month.toString().padLeft(2, '0')}-'
                '${x.day.toString().padLeft(2, '0')}';
        final rows = List<Map<String, dynamic>>.from(
            await SupabaseService.client.rpc('list_pending_collections', params: {
              'p_ins_id': insId,
              'p_from': d(from),
              'p_to': d(to),
            }) as List);
        debugPrint('pending_collection: ${rows.length} unfinished row(s)');
        var i = 0;
        for (final r in rows) {
          final hdr = (r['header'] is Map)
              ? Map<String, dynamic>.from(r['header'] as Map)
              : <String, dynamic>{};
          final isMisc = (r['kind']?.toString() ?? 'M') == 'M';
          final st = r['status']?.toString() ?? 'I';
          if (st == 'C') continue; // the real receipt is already listed above
          final model = PaymentModel(
            payId: -(_pendingIdOffset + (i++)),
            paynumber: null, // no receipt was ever drawn -- that is the point
            insId: insId,
            stuId: int.tryParse(hdr['stu_id']?.toString() ?? ''),
            stuname: hdr['stuname']?.toString(),
            transtotalamount: (r['amount'] as num?)?.toDouble() ?? 0,
            // .toLocal() for the same reason as PaymentModel.fromJson:
            // pending_collection.created_at is a timestamptz, so it arrives with
            // an offset and DateTime.parse would leave it in UTC -- putting an
            // intent raised just after midnight on the previous day.
            paydate: DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal(),
            createdat:
                DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal() ??
                    DateTime.now(),
            paystatus: st == 'X' || st == 'F' ? 'F' : 'I',
            // What the receipt WOULD have carried, taken from the intent --
            // misc stores it as paymode, advance as paymethod, and both are
            // already mapped through _dbPaymode ('Paytm' -> 'Online Transfer').
            // Hardcoding 'Paytm' here made the same collection read one way
            // while pending and another once receipted.
            paymethod: (hdr['paymode'] ?? hdr['paymethod'])?.toString() ??
                'Online Transfer',
            payreference: isMisc ? 'MISC' : 'ADVANCE',
            createdby: hdr['createdby']?.toString() ??
                hdr['collectedby']?.toString(),
          );
          if (model.stuId != null) stuIdsOnScreen.add(model.stuId!);
          pendingType[model.payId] = isMisc ? 'Misc' : 'Advance';
          if (st == 'X' || st == 'F') {
            pendingStatus[model.payId] = 'Failed';
            failedCollections.add(model);
          } else {
            pendingStatus[model.payId] = 'Pending';
            pendingCollections.add(model);
          }
        }
      } catch (e) {
        // The table only exists once the collection-recovery migration is run.
        debugPrint('pending_collection not available: $e');
      }

      // Every id that can appear is known by now, so start the students fetch
      // here and let it run alongside the classification queries below rather
      // than after them.
      final studentsFuture =
          SupabaseService.getStudentsByIds(insId, stuIdsOnScreen);

      // resolve refunded vs cancelled (both are paystatus 'R'; a voided receipt
      // is activestatus=9, which the RPC doesn't return).
      final txType = <int, String>{};
      final txStatus = <int, String>{};
      final payIds = allData.map((t) => (t['pay_id'] as num?)?.toInt()).whereType<int>().toList();
      final cancelled = <int>{};
      final feeTypeByPay = <int, String>{};
      try {
        // Only a REVERSED receipt (paystatus 'R') can be cancelled — a void sets
        // activestatus=9 together with paystatus='R'. So fetch activestatus for
        // just those pay_ids (usually a handful) instead of scanning the whole
        // payment table again.
        final reversedPayIds = reversedData
            .map((t) => (t['pay_id'] as num?)?.toInt())
            .whereType<int>()
            .toList();
        for (int i = 0; i < reversedPayIds.length; i += 200) {
          final chunk = reversedPayIds.sublist(i, (i + 200).clamp(0, reversedPayIds.length));
          if (chunk.isEmpty) continue;
          final av = await SupabaseService.fromSchema('payment')
              .select('pay_id, activestatus').inFilter('pay_id', chunk);
          for (final r in (av as List)) {
            if ((r['activestatus'] as num?)?.toInt() == 9) {
              final p = (r['pay_id'] as num?)?.toInt(); if (p != null) cancelled.add(p);
            }
          }
        }
        // Chunked because the id list travels in the URL, but the chunks go
        // out TOGETHER. Run one after another, a widened date range turned
        // into dozens of serial round trips -- the reason a month took so
        // much longer than a day than its row count suggests.
        List<List<int>> chunksOf(List<int> xs) {
          final out = <List<int>>[];
          for (int i = 0; i < xs.length; i += 200) {
            out.add(xs.sublist(i, (i + 200).clamp(0, xs.length)));
          }
          return out;
        }

        final demIdsByPay = <int, Set<int>>{};
        final allDemIds = <int>{};
        final pdBatches = await Future.wait(chunksOf(payIds).map((chunk) =>
            SupabaseService.fetchAll(() => SupabaseService
                .fromSchema('paymentdetails')
                .select('pay_id, dem_id')
                .inFilter('pay_id', chunk))));
        for (final pd in pdBatches) {
          for (final r in pd) {
            final p = (r['pay_id'] as num?)?.toInt(); final d = (r['dem_id'] as num?)?.toInt();
            if (p != null && d != null) { (demIdsByPay[p] ??= {}).add(d); allDemIds.add(d); }
          }
        }
        final demArrear = <int, bool>{};
        final fdBatches = await Future.wait(chunksOf(allDemIds.toList()).map(
            (chunk) async => await SupabaseService
                .fromSchema('feedemand')
                .select('dem_id, demseqtype')
                .inFilter('dem_id', chunk) as List));
        for (final fd in fdBatches) {
          for (final r in fd) {
            final d = (r['dem_id'] as num?)?.toInt();
            if (d != null) demArrear[d] = (r['demseqtype']?.toString().trim().toUpperCase() == 'ARREAR');
          }
        }
        for (final e in demIdsByPay.entries) {
          feeTypeByPay[e.key] = e.value.any((d) => demArrear[d] == true) ? 'Arrear' : 'Regular';
        }
      } catch (e) {
        debugPrint('Transactions type classify error: $e');
      }
      for (final t in allData) {
        final p = (t['pay_id'] as num?)?.toInt();
        if (p == null) continue;
        final ps = t['paystatus']?.toString();
        final isCancelled = cancelled.contains(p);
        txStatus[p] = ps == 'C'
            ? 'Paid'
            : ps == 'F'
                ? 'Failed'
                : ps == 'I'
                    ? 'Pending'
                    : (isCancelled ? 'Cancelled' : 'Refunded');
        txType[p] = isCancelled ? 'Cancelled' : (feeTypeByPay[p] ?? 'Regular');
      }
      for (final m in miscPaid) { txStatus[m.payId] = 'Paid'; txType[m.payId] = 'Misc'; }
      for (final a in advancePaid) {
        // Type stays 'Advance' whatever happened to it -- the chip says what it
        // IS, the status says what became of it.
        txType[a.payId] = 'Advance';
        final advId = _advIdOf(a.payId);
        txStatus[a.payId] = advanceCancelled.contains(advId)
            ? 'Cancelled'
            : (advanceRefunded.contains(advId) ? 'Refunded' : 'Paid');
      }

      final stuIdToStudent = await studentsFuture;
      final stuIdToName = <int, String>{
        for (final e in stuIdToStudent.entries) e.key: e.value.stuname,
      };

      // Guard: the user may have navigated away while the parallel
      // queries were in flight. Without this check Flutter logs a
      // "setState() called after dispose" warning every time the
      // Transactions tab is left mid-load.
      if (!mounted) return;
      setState(() {
        // A cancelled or refunded advance is no longer money in the drawer, so
        // it leaves the Paid list for the reversed one -- exactly where a
        // cancelled or refunded fee receipt goes (both carry paystatus 'R').
        // Leaving them in Paid would have the KPI count receipts that were
        // undone.
        bool undone(PaymentModel a) {
          final id = _advIdOf(a.payId);
          return advanceCancelled.contains(id) || advanceRefunded.contains(id);
        }
        _paidTransactions = [
          ...paidData.map((e) => PaymentModel.fromJson(e)),
          ...miscPaid,
          ...advancePaid.where((a) => !undone(a)),
        ]..sort(_byReceiptDesc);
        _failedTransactions = [
          ...failedData.map((e) => PaymentModel.fromJson(e)),
          ...failedCollections,
        ]..sort(_byReceiptDesc);
        _pendingTransactions = [
          ...pendingData.map((e) => PaymentModel.fromJson(e)),
          ...pendingCollections,
        ]..sort(_byReceiptDesc);
        _reversedTransactions = [
          ...reversedData.map((e) => PaymentModel.fromJson(e)),
          ...advancePaid.where(undone),
        ]..sort(_byReceiptDesc);
        _txType..clear()..addAll(txType)..addAll(pendingType);
        _txStatus..clear()..addAll(txStatus)..addAll(pendingStatus);
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

  Widget _typeChip(String type) {
    final AppStatus status;
    switch (type) {
      case 'Arrear':
        status = AppStatus.warning; break;
      case 'Misc':
        status = AppStatus.neutral; break;
      case 'Advance':
        // Green, the same colour the collection screens give advance money.
        status = AppStatus.success; break;
      case 'Cancelled':
        status = AppStatus.danger; break;
      default: // Regular
        status = AppStatus.info;
    }
    return AppUI.chip(type, status);
  }

  Widget _buildDownloadButton(PaymentModel t) {
    // A failed payment collected nothing, so there is no receipt AND nothing to
    // reconcile. recon_status still reads 'P' on those rows (it is the column
    // default), which is why this has to check paystatus first -- otherwise a
    // failed transaction is labelled "Pending Approval" as though the money
    // were sitting in a bank waiting to clear.
    if ((t.paystatus ?? '') == 'F') {
      return Text('No receipt',
          style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w600));
    }
    // An unreconciled receipt is still a real receipt the office needs to hand
    // over -- it just prints "* Subject to Realization" (reconStatus 'P' is
    // passed straight through to the receipt). So it downloads like any other,
    // in amber rather than accent, which flags the state without withholding
    // the document the way the old "Pending Approval" label did.
    final isReconciled = t.reconStatus == 'R';
    final color = isReconciled ? AppColors.accent : AppColors.warning;
    // No internal horizontal padding so the icon + label start flush with
    // the RECEIPT header text in the column above.
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _showReceiptOptions(t),
        icon: AppIcon('document-download', size: 16, color: color),
        label: Text(isReconciled ? 'Download' : 'Download (Unreconciled)',
            style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: color), overflow: TextOverflow.visible, softWrap: false, maxLines: 1),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }

  /// RECEIPT-column tag for a voided receipt — tapping it reprints the receipt
  /// with a diagonal "CANCELLED" watermark (see receipt_pdf.dart).
  Widget _cancelledReceiptTag(PaymentModel t) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => _showReceiptOptions(t),
        child: AppUI.chip('Cancelled', AppStatus.danger),
      ),
    );
  }

  /// Build the receipt for a miscellaneous collection (payId = -mc_id) from
  /// misc_collection + misc_collection_detail (same layout as the Misc screen).
  /// Institution settings, for the per-fee-group receipt letterhead. Loaded
  /// lazily: a reprinted hostel receipt must carry the hostel's head, and this
  /// screen reprints all three kinds.
  Map<String, String> _settings = const {};

  Future<({String name, String address, String banner})> _letterhead(
      int? fgId) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    // Asked every time, not once per screen: getInstitutionSettings
    // now serves a shared 60-second cache, so this costs nothing and a
    // letterhead changed on another machine reaches this counter without
    // restarting the app.
    {
      _settings = await SupabaseService.getInstitutionSettings(insId);
    }
    return SupabaseService.letterheadFor(
      fgId: fgId,
      settings: _settings,
      fallbackName: _insName ?? auth.inscode ?? 'Institution',
      fallbackAddress: _insAddress ?? '-',
    );
  }

  Future<ReceiptData> _buildMiscReceiptData(PaymentModel t) async {
    final auth = context.read<AuthProvider>();
    final mcId = -t.payId;
    final date = t.paydate ?? t.createdat;
    final dateStr = formatDmy(date);

    Map<String, dynamic> mc = {};
    final items = <ReceiptFeeItem>[];
    try {
      final hdr = await SupabaseService.fromSchema('misc_collection')
          .select('mc_id, mcno, stuname, stuclass, regno, address, paymode, totalamount, transrefno, paytm_txnid, recon_status')
          .eq('mc_id', mcId)
          .maybeSingle();
      if (hdr != null) mc = Map<String, dynamic>.from(hdr);
      final det = await SupabaseService.fromSchema('misc_collection_detail')
          .select('feetype, amount')
          .eq('mc_id', mcId)
          .eq('activestatus', 1);
      for (final l in (det as List)) {
        items.add(ReceiptFeeItem(type: l['feetype']?.toString() ?? 'Misc', amount: (l['amount'] as num?)?.toDouble() ?? 0));
      }
    } catch (e) {
      debugPrint('Misc receipt fetch error: $e');
    }
    if (items.isEmpty) {
      items.add(ReceiptFeeItem(type: 'Miscellaneous', amount: t.transtotalamount));
    }

    final student = t.stuId != null ? _stuIdToStudent[t.stuId] : null;
    String pick(String? a, String? b) =>
        (a != null && a.trim().isNotEmpty) ? a.trim() : ((b != null && b.trim().isNotEmpty) ? b.trim() : '-');
    // Which group this receipt was banked under, so the reprint carries the
    // same letterhead the counter printed.
    final lh = await _letterhead(
        await SupabaseService.feeGroupOfFeeTypes([for (final i in items) i.type]));
    return ReceiptData(
      receiptNo: t.paynumber ?? mc['mcno']?.toString() ?? '$mcId',
      date: dateStr,
      studentName: pick(t.stuname, mc['stuname']?.toString()) == '-' ? _getStudentName(t) : pick(t.stuname, mc['stuname']?.toString()),
      mobileNo: student?.stumobile ?? '-',
      address: pick(mc['address']?.toString(), student?.stuaddress),
      admissionNo: pick(mc['regno']?.toString(), student?.stuadmno),
      className: pick(mc['stuclass']?.toString(), student?.stuclass),
      courseName: student?.courname ?? '-',
      schoolName: lh.name,
      schoolAddress: lh.address,
      headerBanner: lh.banner,
      schoolLogoUrl: _insLogoUrl,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: [ReceiptTermDetail(term: '-', fees: items)],
      paymentMethod: pick(t.paymethod, mc['paymode']?.toString()),
      paymentDate: dateStr,
      status: 'paid',
      // The misc row's OWN reconciliation state, not a hardcoded 'R'.
      // Hardcoding it meant an unreconciled misc receipt never printed
      // "* Subject to Realization", even though the list flagged it amber with
      // a "Download *" -- so the document handed to the student claimed the
      // money had cleared when it had not. Falls back to the list row's status,
      // then to 'P', because unreconciled is the safer assumption on a receipt.
      reconStatus: mc['recon_status']?.toString() ?? t.reconStatus ?? 'P',
      // Misc collections keep their gateway/UPI reference on
      // misc_collection.transrefno, not on payment.payreference -- there is no
      // payment row -- so the receipt showed "Txn ID : -" for every one of them.
      // Gateway txn id first: a Paytm misc receipt keeps the ORDER id in
      // transrefno, so the receipt used to print an id no bank statement shows.
      paymentReference: (mc['paytm_txnid']?.toString().trim().isNotEmpty ?? false)
          ? mc['paytm_txnid']?.toString()
          : mc['transrefno']?.toString(),
      total: t.transtotalamount,
    );
  }

  /// Build the receipt for an ADVANCE collection (payId = -(offset + adv_id))
  /// from advance_collection + advance_detail.
  ///
  /// An ADMISSION advance was collected against fee types, so its receipt lists
  /// them. A STUDENT advance is a plain amount and gets a single line — there is
  /// no breakdown to invent.
  Future<ReceiptData> _buildAdvanceReceiptData(PaymentModel t) async {
    final auth = context.read<AuthProvider>();
    final advId = _advIdOf(t.payId);
    final date = t.paydate ?? t.createdat;
    final dateStr = formatDmy(date);

    Map<String, dynamic> adv = {};
    final items = <ReceiptFeeItem>[];
    try {
      final hdr = await SupabaseService.fromSchema('advance_collection')
          .select('adv_id, advno, advtype, stuname, stuclass, stuadmno, courname, '
              'paymethod, payreference, paytm_txnid, transtotalamount, remarks, recon_status')
          .eq('adv_id', advId)
          .maybeSingle();
      if (hdr != null) adv = Map<String, dynamic>.from(hdr);
      if ((adv['advtype']?.toString() ?? 'S') == 'A') {
        final det = await SupabaseService.fromSchema('advance_detail')
            .select('feetype, amount')
            .eq('adv_id', advId)
            .eq('activestatus', 1);
        for (final l in (det as List)) {
          items.add(ReceiptFeeItem(
              type: l['feetype']?.toString() ?? 'Advance',
              amount: (l['amount'] as num?)?.toDouble() ?? 0));
        }
      }
    } catch (e) {
      debugPrint('Advance receipt fetch error: $e');
    }
    // What this advance is called: the fee group it was banked under. The
    // receipt used to read "Student Advance" for every non-admission advance,
    // so a mess advance printed from here disagreed with the one printed at
    // the counter -- and with the account the money actually went to.
    final advType = (adv['advtype']?.toString() ?? 'S').toUpperCase();
    final advFg = await SupabaseService.resolveRoutingTarget(
      insId: auth.insId ?? 1,
      advType: (adv['advtype']?.toString() ?? 'S').toUpperCase(),
    );
    final advLh = await _letterhead(advFg.fgId);
    // The advance KIND, not the fee group. advanceGroupLabel resolves where
    // the money BANKED, which printed "COLLEGE FEES" on the particulars line
    // of a student advance -- and could differ from the receipt the counter
    // handed over, because that screen decided it a third way.
    final groupLabel = SupabaseService.advanceHeadName(advType);

    if (items.isEmpty) {
      // A STUDENT or MESS advance has no advance_detail breakdown -- it is a
      // plain amount -- so this is its normal path, not merely a fallback.
      items.add(ReceiptFeeItem(type: groupLabel, amount: t.transtotalamount));
    }

    final student = t.stuId != null ? _stuIdToStudent[t.stuId] : null;
    String pick(String? a, String? b) =>
        (a != null && a.trim().isNotEmpty) ? a.trim() : ((b != null && b.trim().isNotEmpty) ? b.trim() : '-');
    final admission = (adv['advtype']?.toString() ?? 'S') == 'A';
    return ReceiptData(
      receiptNo: t.paynumber ?? adv['advno']?.toString() ?? '$advId',
      date: dateStr,
      studentName: pick(t.stuname, adv['stuname']?.toString()) == '-'
          ? _getStudentName(t)
          : pick(t.stuname, adv['stuname']?.toString()),
      mobileNo: student?.stumobile ?? '-',
      address: student?.stuaddress ?? '-',
      admissionNo: pick(adv['stuadmno']?.toString(), student?.stuadmno),
      className: pick(adv['stuclass']?.toString(), student?.stuclass),
      courseName: pick(adv['courname']?.toString(), student?.courname),
      schoolName: advLh.name,
      schoolAddress: advLh.address,
      headerBanner: advLh.banner,
      schoolLogoUrl: _insLogoUrl,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      // The term slot names what kind of advance this is — the receipt has no
      // semester, because an advance is not tied to one.
      feeDetails: [
        ReceiptTermDetail(term: groupLabel.toUpperCase(), fees: items),
      ],
      paymentMethod: pick(t.paymethod, adv['paymethod']?.toString()),
      paymentDate: dateStr,
      status: 'paid',
      // Cash is realised on the spot; anything else waits for the bank, and the
      // receipt must say so rather than imply the money has cleared.
      reconStatus: adv['recon_status']?.toString() ?? t.reconStatus ?? 'P',
      // Gateway txn id first — a Paytm advance keeps OUR order id in
      // payreference, which appears on no bank statement.
      paymentReference: (adv['paytm_txnid']?.toString().trim().isNotEmpty ?? false)
          ? adv['paytm_txnid']?.toString()
          : adv['payreference']?.toString(),
      total: t.transtotalamount,
    );
  }

  Future<ReceiptData> _buildReceiptData(PaymentModel t) async {
    // Misc collections live in their own tables — build their receipt from there.
    if (t.payreference == 'MISC') return _buildMiscReceiptData(t);
    if (_isAdvance(t)) return _buildAdvanceReceiptData(t);
    // Collected on this receipt, for the letterhead lookup below.
    final feeTypesOnReceipt = <String>{};
    final stuName = _getStudentName(t);
    final student = t.stuId != null ? _stuIdToStudent[t.stuId] : null;
    final auth = context.read<AuthProvider>();
    final date = t.paydate ?? t.createdat;
    final dateStr = formatDmy(date);

    // Fetch fee details from feedemand table
    List<ReceiptTermDetail> feeDetails = [];
    // For an ARREAR receipt, Branch = the arrear's original class
    // (feedemand.arrearclass) rather than the student's current class.
    String? arrearBranch;
    // Branch = the class the PAID demands were billed under (feedemand.stuclass),
    // so an old receipt keeps the class at payment time even after a course
    // transfer changes the student's current class.
    String? payBranch;
    final cancelled = _txStatus[t.payId] == 'Cancelled';

    // How much of this receipt was settled out of an advance. Read from
    // advadjustment by pay_id, exactly as the Fee Collection screen does, so a
    // reprint here says the same thing as the original print.
    double advAdjusted = 0;
    var advNo = '';
    try {
      final adj = await SupabaseService.fromSchema('advadjustment')
          .select('adjustamount, adv_id')
          .eq('pay_id', t.payId)
          .eq('activestatus', 1);
      final advIds = <int>{};
      for (final r in List<Map<String, dynamic>>.from(adj as List)) {
        advAdjusted += (r['adjustamount'] as num?)?.toDouble() ?? 0;
        final id = (r['adv_id'] as num?)?.toInt();
        if (id != null) advIds.add(id);
      }
      if (advIds.isNotEmpty) {
        final hdr = await SupabaseService.fromSchema('advance_collection')
            .select('advno')
            .inFilter('adv_id', advIds.toList());
        advNo = List<Map<String, dynamic>>.from(hdr as List)
            .map((e) => e['advno']?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .join(', ');
      }
    } catch (_) {
      // No advadjustment table yet — an ordinary receipt reprints unchanged.
    }

    try {
      final details = await _receiptLines(t, cancelled);
      if (details.isNotEmpty) {
        for (final d in details) {
          final sc = d['stuclass']?.toString() ?? '';
          if (payBranch == null && sc.isNotEmpty) payBranch = sc;
          final isArr = (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
          final ac = d['arrearclass']?.toString() ?? '';
          if (isArr && ac.isNotEmpty) {
            arrearBranch = ac;
            break;
          }
        }
        // Group by term (the actual demfeeterm / semester).
        final termMap = <String, List<ReceiptFeeItem>>{};
        for (final d in details) {
          final term = d['demfeeterm']?.toString().trim().isNotEmpty == true
              ? d['demfeeterm'].toString()
              : '-';
          final feeType = d['demfeetype']?.toString() ?? d['feegroupname']?.toString() ?? 'Fee';
          // Line amount = actually collected in THIS payment (fee portion).
          // collectedamount comes from paymentdetails.transtotalamount; subtract
          // fineamount to isolate the fee portion and show Fine separately.
          final fine = (d['fineamount'] as num?)?.toDouble() ?? 0.0;
          final collected = (d['collectedamount'] as num?)?.toDouble()
              ?? (d['feeamount'] as num?)?.toDouble() ?? 0.0;
          final feeOnly = (collected - fine).clamp(0, double.infinity).toDouble();
          termMap.putIfAbsent(term, () => []);
          termMap[term]!.add(ReceiptFeeItem(type: feeType, amount: feeOnly));
          if (fine > 0) {
            termMap[term]!.add(ReceiptFeeItem(type: '  Fine', amount: fine));
          }
        }
        feeTypesOnReceipt
            .addAll(details.map((d) => d['demfeetype']?.toString() ?? ''));
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

    final feeLh = await _letterhead(
        await SupabaseService.feeGroupOfFeeTypes(feeTypesOnReceipt.toList()));
    return ReceiptData(
      receiptNo: t.paynumber ?? '${t.payId}',
      date: dateStr,
      studentName: stuName,
      mobileNo: student?.stumobile ?? '-',
      address: student?.stuaddress ?? '-',
      admissionNo: student?.stuadmno ?? '-',
      className: (arrearBranch != null && arrearBranch.isNotEmpty)
          ? arrearBranch
          : (payBranch != null && payBranch.isNotEmpty)
              ? payBranch
              : (student?.stuclass ?? '-'),
      courseName: student?.courname ?? '-',
      schoolName: feeLh.name,
      schoolAddress: feeLh.address,
      headerBanner: feeLh.banner,
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
      advanceAdjusted: advAdjusted,
      advanceNo: advNo,
      cancelled: cancelled,
    );
  }

  /// Fee lines for a receipt. A live receipt reads feedemand by pay_id; a voided
  /// receipt cleared feedemand.pay_id, so re-join through paymentdetails (kept
  /// for audit at activestatus=9) → feedemand by dem_id.
  Future<List<Map<String, dynamic>>> _receiptLines(PaymentModel t, bool cancelled) async {
    if (!cancelled) return SupabaseService.getFeeDetailsByPayId(t.payId);
    try {
      final pd = await SupabaseService.fromSchema('paymentdetails')
          .select('dem_id, transtotalamount')
          .eq('pay_id', t.payId);
      final rows = List<Map<String, dynamic>>.from(pd as List);
      final demIds = rows.map((r) => r['dem_id']).where((e) => e != null).toList();
      if (demIds.isEmpty) return [];
      final dems = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuclass, demfeeterm, demfeetype, fee_id, fineamount, demseqtype, arrearclass')
          .inFilter('dem_id', demIds);
      final demMap = {for (final d in (dems as List)) d['dem_id']: Map<String, dynamic>.from(d as Map)};
      return rows.map((r) {
        final d = Map<String, dynamic>.from(demMap[r['dem_id']] ?? <String, dynamic>{});
        d['collectedamount'] = r['transtotalamount'];
        return d;
      }).toList();
    } catch (e) {
      debugPrint('Error fetching cancelled receipt lines: $e');
      return [];
    }
  }

  void _showReceiptOptions(PaymentModel t) async {
    final receiptData = await _buildReceiptData(t);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
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
                      icon: AppIcon('printer', size: 18, color: Colors.white),
                      label: const Text('Print'),
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
  Future<pw.Document> _buildReceiptPdf(PaymentModel t, [PdfPageFormat? fmt]) async {
    final data = await _buildReceiptData(t);
    return buildReceiptPdf(data, pageFormat: fmt);
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
                      labelValue(schoolTerm('Roll Number:'), data.admissionNo),
                      pw.SizedBox(height: 6),
                      labelValue(schoolTerm('Class:'), data.className),
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
                              tableCell(AppText.serialNo, sSemiBold.copyWith(color: primaryBlue)),
                              tableCell(schoolTerm('Semester'), sSemiBold.copyWith(color: primaryBlue)),
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
                                          child: pw.Text('${formatAmount(fee.amount)}', style: sMediumDark, textAlign: pw.TextAlign.right),
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
                                    child: pw.Text('${formatAmount(data.total)}', style: pw.TextStyle(font: fontSemiBold, fontSize: 10, color: PdfColors.white), textAlign: pw.TextAlign.right),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  // Status stamp overlay - between Term and Fee Type columns
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
                  labelValue('${AppText.paymentMode}:', data.paymentMethod.toLowerCase() == 'razorpay' ? 'Online' : data.paymentMethod),
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
      await Printing.layoutPdf(
        // Rebuild at the paper the printer actually reports so the receipt
        // lands centred and unclipped; A5 is only the starting suggestion.
        format: a5PageFormat,
        onLayout: (PdfPageFormat format) async =>
            (await _buildReceiptPdf(t, format)).save(),
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
    return Column(
      children: [
        // Summary cards — tapping one filters the table below in place.
        _buildSummaryCards(),
        // Only when there is something to say. An always-present "0 unmatched"
        // strip is noise, and noise is what gets stopped being read.
        if (_refusals.isNotEmpty) _buildRefusalBanner(),
        SizedBox(height: AppUI.gap),
        // 3. Combined header + table card
        Expanded(
          child: Container(
            decoration: AppUI.card(),
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          AppIcon.linear('receipt-2', color: AppColors.primary, size: 20),
                          SizedBox(width: 8.w),
                          Text(
                            'Transactions',
                            style: AppUI.cardTitle,
                          ),
                          const Spacer(),
                          ..._toolbarActions(),
                        ],
                      ),
                      SizedBox(height: 10.h),
                      Align(alignment: Alignment.centerLeft, child: _buildStatusTabs()),
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

  /// Search + date/method filter + refresh - shared by the table-card
  /// header (main view) and the drill-down header card.
  List<Widget> _toolbarActions() {
    return [
      AppSearchField(
        controller: _searchController,
        hintText: schoolTerm('Search by name, roll number or class'),
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
      OutlinedButton.icon(
        onPressed: _openDateRangeDialog,
        icon: AppIcon.linear('calendar',
            size: AppBtn.iconSize(context), color: AppColors.primary),
        label: Text(_dateRangeLabel()),
      ),
      SizedBox(width: AppBtn.gap(context)),
      OutlinedButton.icon(
        onPressed: _fetchData,
        icon: AppIcon('refresh',
            size: AppBtn.iconSize(context), color: AppColors.primary),
        label: const Text('Refresh'),
      ),
    ];
  }

  /// Drill-down header - Back button + breadcrumb inside a white card,
  /// matching the Fee Collection > Total Collection drill-down design.
  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  /// Subtitle for the Total Transactions card. The count is already filtered,
  /// so labelling it "All records" while the screen opens on today would state
  /// the opposite of what is on screen.
  String _recordScopeLabel() {
    if (_filterFromDate == null && _filterToDate == null) return 'All records';
    final now = DateTime.now();
    bool isToday(DateTime? d) =>
        d != null && d.year == now.year && d.month == now.month && d.day == now.day;
    if (isToday(_filterFromDate) && isToday(_filterToDate)) return 'Today';
    return _dateRangeLabel();
  }

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
      return '$datePart • ${_filterMethods.length} method${_filterMethods.length == 1 ? '' : 's'}';
    }
    return datePart;
  }

  Future<void> _openDateRangeDialog() async {
    // Build the chip set from the modes actually present in the loaded
    // transactions - keeps the filter list tight to what the user can act on.
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
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primaryLight : Colors.white,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: selected ? AppColors.primary : AppColors.border),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.primary : AppColors.textPrimary,
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
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primaryLight : Colors.white,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: selected ? AppColors.primary : AppColors.border),
                  ),
                  child: Text(
                    m.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w700,
                      color: selected ? AppColors.primary : AppColors.textPrimary,
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
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              child: Container(
                constraints: BoxConstraints(minHeight: AppUI.controlHeight(ctx)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: value != null ? AppColors.primary.withValues(alpha: 0.55) : AppColors.border),
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon.linear('calendar', size: 14, color: value != null ? AppColors.primary : AppColors.textLight),
                    const SizedBox(width: 8),
                    Text(value != null ? _fmtDate(value) : hint,
                        style: value != null ? AppUI.fieldText(ctx, filled: true) : AppUI.fieldText(ctx).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            );
          }

          Widget sectionLabel(String text) => AppUI.sectionLabel(text);

          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            title: Row(
              children: [
                Text('Filters', style: AppUI.cardTitle),
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
                    Expanded(child: datePickerBox(hint: 'Select from date', value: from, onChanged: (d) => setStateDialog(() => from = d))),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('-')),
                    Expanded(child: datePickerBox(hint: 'Select to date', value: to, onChanged: (d) => setStateDialog(() => to = d))),
                  ]),
                  if (methodList.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    sectionLabel('PAYMENT MODE'),
                    Wrap(children: methodList.map(methodChip).toList()),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setStateDialog(() { from = null; to = null; methods.clear(); }),
                child: const Text('Clear'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _filterFromDate = from;
                    _filterToDate = to;

                    _filterMethods
                      ..clear()
                      ..addAll(methods);
                  });
                  Navigator.pop(ctx);
                  // The fetch is date-bounded now, so a widened range needs new
                  // data: re-filtering what is already in memory would show an
                  // empty screen for any day that was never loaded.
                  _fetchData();
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

  /// All / Paid / Failed filter tabs (replaces the old card drill-down).
  Widget _buildStatusTabs() {
    final paid = _applyDateFilter(_paidTransactions).length;
    final failed = _applyDateFilter(_failedTransactions).length;
    final reversed = _applyDateFilter(_reversedTransactions).length;
    final pending = _applyDateFilter(_pendingTransactions).length;
    Widget tab(String label, int count, String? value, Color cntColor) {
      final sel = _drilldownFilter == value;
      return Padding(padding: EdgeInsets.only(right: 8.w), child: InkWell(
        onTap: () => setState(() => _drilldownFilter = value),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
          decoration: BoxDecoration(color: sel ? AppColors.primary : Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: sel ? AppColors.primary : AppColors.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: sel ? Colors.white : AppColors.textPrimary)),
            SizedBox(width: 8.w),
            Container(padding: EdgeInsets.symmetric(horizontal: 7.w, vertical: 1.h), decoration: BoxDecoration(color: sel ? Colors.white.withValues(alpha: 0.25) : cntColor.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20.r)), child: Text('$count', style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w800, color: sel ? Colors.white : cntColor))),
          ]),
        ),
      ));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      tab('All', paid + failed + reversed + pending, null, AppColors.primary),
      tab('Paid', paid, 'paid', AppColors.success),
      tab('Failed', failed, 'failed', AppColors.error),
      tab('Pending', pending, 'pending', AppColors.warning),
    ]);
  }

  /// Money Paytm took that nobody has receipted.
  ///
  /// Amber, not red: nothing is broken and nothing is lost -- the money is in
  /// the account. It is waiting on a decision, and the only failure mode is
  /// nobody making one.
  ///
  /// Deliberately not dismissible and not tied to the date filter. It stays
  /// until the money is dealt with, because the cost of one of these going
  /// quiet is a family chased for fees they have already paid.
  Widget _buildRefusalBanner() {
    final total = _refusals.fold<double>(
        0, (sum, r) => sum + (num.tryParse('${r['amount'] ?? 0}')?.toDouble() ?? 0));
    final n = _refusals.length;
    final oldest = _refusals
        .map((r) => DateTime.tryParse('${r['first_seen']}')?.toLocal())
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    final waited = oldest == null ? null : DateTime.now().difference(oldest);

    return Padding(
      padding: EdgeInsets.only(top: 10.h),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: _showRefusalDetails,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
          decoration: BoxDecoration(
            color: AppColors.warningBg,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              AppIcon('wallet-money', color: AppColors.warning, size: 20),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n == 1
                          ? '1 payment received with no receipt'
                          : '$n payments received with no receipt',
                      style: AppUI.label.copyWith(color: AppColors.warning),
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      '₹${formatIndianNumber(total)} is in the bank with nothing on any '
                      "student's ledger against it"
                      '${waited == null ? '' : ' — oldest waiting ${_waitedFor(waited)}'}'
                      '. Click for details.',
                      style: AppUI.muted.copyWith(color: AppColors.warning),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8.w),
              AppIcon('arrow-right-3', color: AppColors.warning, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  /// The list behind the banner.
  ///
  /// Read-only on purpose. list_webhook_refusals cannot write, and a refusal
  /// is a claim that the college holds unreceipted money -- a screen that
  /// could tick it away would let somebody make the claim disappear without
  /// the money being dealt with. These close when a receipt is raised or a
  /// refund is made, not when a button is pressed.
  Future<void> _showRefusalDetails() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        title: Row(
          children: [
            AppIcon('wallet-money', color: AppColors.warning, size: 20),
            SizedBox(width: 8.w),
            Expanded(
              child: Text('Payments with no receipt', style: AppUI.cardTitle),
            ),
          ],
        ),
        content: SizedBox(
          width: 620.w,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paytm confirmed each of these, but the system could not tell '
                'which student or which fees the money was for, so it refused '
                'to guess rather than credit the wrong ledger.',
                style: AppUI.muted,
              ),
              SizedBox(height: 12.h),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _refusals.length,
                  separatorBuilder: (_, __) => Divider(height: 14.h),
                  itemBuilder: (_, i) {
                    final r = _refusals[i];
                    final amt = num.tryParse('${r['amount'] ?? 0}') ?? 0;
                    final seen = DateTime.tryParse('${r['first_seen']}')?.toLocal();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('₹${formatIndianNumber(amt)}', style: AppUI.money),
                            const Spacer(),
                            if (seen != null)
                              Text(
                                '${seen.day.toString().padLeft(2, '0')}-'
                                '${seen.month.toString().padLeft(2, '0')}-'
                                '${seen.year}  '
                                '${seen.hour.toString().padLeft(2, '0')}:'
                                '${seen.minute.toString().padLeft(2, '0')}',
                                style: AppUI.muted,
                              ),
                          ],
                        ),
                        SizedBox(height: 3.h),
                        // The order id is what the office quotes to Paytm and
                        // what any recovery is written against, so it is shown
                        // in full and selectable rather than truncated.
                        SelectableText('Order ${r['order_id']}',
                            style: AppUI.muted.copyWith(color: AppColors.textSecondary)),
                        SizedBox(height: 3.h),
                        Text('${r['reason'] ?? ''}',
                            style: AppUI.body),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(height: 10.h),
              Text(
                'Share the order ID with your system administrator. Each payment '
                'needs someone to identify the payer and then issue a receipt '
                'or a refund; it cannot be settled from this screen.',
                style: AppUI.muted,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// "3 days", "19 hours", "40 minutes" — whichever reads honestly. An age in
  /// plain words is what makes somebody act; a timestamp is just data.
  String _waitedFor(Duration d) {
    if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
    if (d.inHours >= 1) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
    final m = d.inMinutes < 1 ? 1 : d.inMinutes;
    return '$m minute${m == 1 ? '' : 's'}';
  }

  Widget _buildSummaryCards() {
    final filteredPaid = _applyDateFilter(_paidTransactions);
    final filteredFailed = _applyDateFilter(_failedTransactions);
    final filteredReversed = _applyDateFilter(_reversedTransactions);
    final filteredPending = _applyDateFilter(_pendingTransactions);
    final paidTotal = filteredPaid.fold<double>(
        0, (sum, t) => sum + t.transtotalamount);
    final failedTotal = filteredFailed.fold<double>(
        0, (sum, t) => sum + t.transtotalamount);
    final pendingTotal = filteredPending.fold<double>(
        0, (sum, t) => sum + t.transtotalamount);

    // Active filter: 'paid' / 'failed' / null(=all). Tapping the active card
    // clears it back to all; 'Total Transactions' always shows all.
    return Row(
      children: [
        Expanded(
          child: _buildSummaryCard(
            'Total Transactions',
            '${filteredPaid.length + filteredFailed.length + filteredReversed.length + filteredPending.length}',
            _recordScopeLabel(),
            AppColors.primary,
            'receipt-2',
          ),
        ),
        SizedBox(width: AppUI.gap),
        Expanded(
          child: _buildSummaryCard(
            'Total Paid',
            formatIndianNumber(paidTotal),
            '${filteredPaid.length} transactions',
            AppColors.success,
            'tick-circle',
          ),
        ),
        SizedBox(width: AppUI.gap),
        Expanded(
          child: _buildSummaryCard(
            'Total Failed',
            formatIndianNumber(failedTotal),
            '${filteredFailed.length} transactions',
            AppColors.error,
            'info-circle',
          ),
        ),
        SizedBox(width: AppUI.gap),
        Expanded(
          // Money that may or may not have been taken. Not a loss and not a
          // collection -- it is the list somebody should be looking at.
          child: _buildSummaryCard(
            'Total Pending',
            formatIndianNumber(pendingTotal),
            '${filteredPending.length} awaiting the gateway',
            AppColors.warning,
            'clock',
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(
      String title, String value, String subtitle, Color color, String icon) {
    return AppUI.kpi(icon: icon, label: title, value: value, sub: subtitle, tint: color);
  }

  // â”€â”€ Sticky-header table â”€â”€
  // Reference column was dropped - the same details surface via the receipt
  // download. Payment Method renamed to "Mode" for brevity.
  // AMOUNT (index 7) is 12 wider than it needs to be, and gives those 12 back
  // as _txAmountGap below, so the text area is unchanged and the extra is a
  // real gutter.
  static const _txColWidths = <double>[60, 110, 100, 130, 170, 110, 100, 112, 100, 100, 180];
  /// AMOUNT's position. Money reads right-aligned so the rupee figures
  /// line up on their units digit; the header follows the column.
  static const _txAmountCol = 7;

  /// Gutter after the right-aligned AMOUNT column.
  ///
  /// A right-aligned cell ends exactly where the next one starts, so AMOUNT
  /// and TYPE sat flush against each other and the header read "AMOUNTTYPE".
  /// Every other column is left-aligned and gets its gap for free from the
  /// slack at the end of its own text; only this one has to be given one.
  static const _txAmountGap = 12.0;
  static const _txHeaders = <String>[
    'S. NO.', 'DATE', 'RECEIPT NO', 'ROLL NUMBER', 'NAME', 'CLASS',
    'MODE', 'AMOUNT', 'TYPE', 'STATUS', 'RECEIPT',
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
    final cellStyle = AppUI.cell;
    final headerStyle = AppUI.tableHead;

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
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder),
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
                  SizedBox(
                      width: widths[c],
                      child: Padding(
                        padding: EdgeInsets.only(
                            right: c == _txAmountCol ? _txAmountGap : 0),
                        child: Text(schoolTerm(_txHeaders[c]),
                            style: headerStyle,
                            textAlign:
                                c == _txAmountCol ? TextAlign.right : TextAlign.left,
                            overflow: TextOverflow.ellipsis),
                      )),
              ],
            ),
          );

          Widget bodyRow(int i) {
            final t = transactions[i];
            final stuName = _getStudentName(t);
            final stu = t.stuId != null ? _stuIdToStudent[t.stuId] : null;
            final statusText = _txStatus[t.payId] ?? (fixedIsPaid == false ? 'Failed' : 'Paid');
            final type = _txType[t.payId] ?? 'Regular';
            final AppStatus statusKind = statusText == 'Pending'
                ? AppStatus.warning
                : statusText == 'Failed'
                ? AppStatus.danger
                : statusText == 'Refunded'
                    ? AppStatus.warning
                    : statusText == 'Cancelled'
                        ? AppStatus.neutral
                        : AppStatus.success;
            final date = (fixedIsPaid == true ? t.paydate : (fixedIsPaid == false ? t.createdat : (t.paydate ?? t.createdat)));
            final dateStr = date != null
                ? '${date.day.toString().padLeft(2, '0')}-${date.month.toString().padLeft(2, '0')}-${date.year}'
                : '-';
            return Container(
              color: i.isEven ? Colors.white : AppColors.surface,
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
              width: contentWidth,
              child: Row(
                children: [
                  SizedBox(width: widths[0], child: Text('${i + 1}', style: cellStyle)),
                  SizedBox(width: widths[1], child: Text(dateStr, style: cellStyle)),
                  SizedBox(width: widths[2], child: Text(t.paynumber ?? '-', style: cellStyle)),
                  SizedBox(width: widths[3], child: Text(stu?.stuadmno ?? '-', style: cellStyle, overflow: TextOverflow.ellipsis)),
                  SizedBox(width: widths[4], child: Text(stuName, style: cellStyle, overflow: TextOverflow.ellipsis)),
                  SizedBox(width: widths[5], child: Text(stu?.stuclass ?? '-', style: cellStyle)),
                  SizedBox(width: widths[6], child: Text(t.paymethod ?? '-', style: cellStyle)),
                  SizedBox(
                      width: widths[_txAmountCol],
                      child: Padding(
                        padding: const EdgeInsets.only(right: _txAmountGap),
                        child: Text(formatIndianNumber(t.transtotalamount),
                            style: AppUI.money, textAlign: TextAlign.right),
                      )),
                  SizedBox(width: widths[8], child: Align(alignment: Alignment.centerLeft, child: _typeChip(type))),
                  SizedBox(
                    width: widths[9],
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AppUI.chip(statusText, statusKind),
                    ),
                  ),
                  SizedBox(
                    width: widths[10],
                    child: statusText == 'Paid'
                        ? _buildDownloadButton(t)
                        : statusText == 'Cancelled'
                            ? _cancelledReceiptTag(t)
                            : const SizedBox.shrink(),
                  ),
                ],
              ),
            );
          }

          // Body list - framework scrollbar suppressed; the pinned bar on the
          // right drives it instead.
          final body = ScrollConfiguration(
            behavior: ScrollConfiguration.of(ctx).copyWith(scrollbars: false),
            child: ListView.separated(
              controller: vController,
              itemCount: transactions.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
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
                              Container(height: 1, color: AppColors.divider),
                              Expanded(child: body),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Vertical scrollbar pinned to the viewport - top spacer
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
      // The screen opens on today, so "nothing here" is usually "nothing was
      // collected today" -- not "there are no transactions". Say which, and
      // name the range, or a cashier reads an empty grid as a failed load.
      final scope = _emptyScopeLine();
      return AppUI.empty(title: 'No collections', why: scope, icon: 'receipt-2');
    }
    return _buildStickyTable(allTransactions);
  }

  /// Explains WHICH slice came back empty, so the message is actionable:
  /// widen the date, clear the search, or accept that nothing was collected.
  String _emptyScopeLine() {
    if (_searchQuery.isNotEmpty) {
      return 'Nothing matches "$_searchQuery" in the selected range.';
    }
    final now = DateTime.now();
    bool isToday(DateTime? d) =>
        d != null && d.year == now.year && d.month == now.month && d.day == now.day;
    if (isToday(_filterFromDate) && isToday(_filterToDate)) {
      return 'No fees have been collected today. Use Date & Mode to look at another day.';
    }
    if (_filterFromDate == null && _filterToDate == null) {
      return _filterMethods.isEmpty
          ? 'No collection has been recorded yet.'
          : 'No collection recorded for the selected payment mode.';
    }
    return 'No collection for ${_dateRangeLabel()}.';
  }

  Widget _buildTransactionTable(List<PaymentModel> allItems, {required bool isPaid}) {
    if (allItems.isEmpty) {
      return AppUI.empty(
        title: isPaid ? 'No paid transactions' : 'No failed transactions',
        why: isPaid
            ? 'No completed payments found.'
            : 'All transactions have been processed successfully.',
        icon: isPaid ? 'wallet-money' : 'tick-circle',
      );
    }
    return _buildStickyTable(allItems, fixedIsPaid: isPaid);
  }
}
