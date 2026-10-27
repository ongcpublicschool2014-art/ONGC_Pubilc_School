/// Payment model matching Supabase 'payment' table
class PaymentModel {
  final int payId;
  final String? paynumber;
  final int insId;
  final String? inscode;
  final int? stuId;
  final int yrId;
  final String? yrlabel;
  final double transtotalamount;
  final String transcurrency;
  final DateTime? paydate;
  final String? paystatus;
  final String? paymethod;
  final String? payreference;
  final String? createdby;
  final DateTime createdat;
  final int activestatus;

  /// Student name returned by the RPC function (not stored in model permanently)
  final String? stuname;
  final String? reconStatus;

  PaymentModel({
    required this.payId,
    this.paynumber,
    required this.insId,
    this.inscode,
    this.stuId,
    this.yrId = 0,
    this.yrlabel,
    this.transtotalamount = 0,
    this.transcurrency = 'INR',
    this.paydate,
    this.paystatus,
    this.paymethod,
    this.payreference,
    this.createdby,
    required this.createdat,
    this.activestatus = 1,
    this.stuname,
    this.reconStatus,
  });

  factory PaymentModel.fromJson(Map<String, dynamic> json) {
    // Handle both direct table fields and RPC function field names
    final payIdRaw = json['pay_id'];
    final insIdRaw = json['ins_id'];
    final stuIdRaw = json['stu_id'];
    final yrIdRaw = json['yr_id'];

    return PaymentModel(
      payId: payIdRaw is int ? payIdRaw : int.parse(payIdRaw.toString()),
      paynumber: json['paynumber'] ?? json['payno'],
      insId: insIdRaw is int ? insIdRaw : int.parse(insIdRaw.toString()),
      inscode: json['inscode'],
      stuId: stuIdRaw != null
          ? (stuIdRaw is int ? stuIdRaw : int.parse(stuIdRaw.toString()))
          : null,
      yrId: yrIdRaw != null
          ? (yrIdRaw is int ? yrIdRaw : int.parse(yrIdRaw.toString()))
          : 0,
      yrlabel: json['yrlabel'],
      transtotalamount:
          (json['transtotalamount'] as num?)?.toDouble() ??
          (json['payamount'] as num?)?.toDouble() ?? 0,
      transcurrency: json['transcurrency'] ?? json['paycurrency'] ?? 'INR',
      // .toLocal() is NOT optional here. fn_get_transactions returns
      // paydate::timestamptz, so once the database was moved to Asia/Kolkata it
      // arrives carrying an offset -- "2026-10-05T00:25:50+05:30". DateTime.parse
      // normalises ANY offset to UTC, so .day then reads back as the 4th, and a
      // receipt taken at 00:25 on the 5th vanished from the 5th's list and from
      // the DATE column. Everything downstream reads .year/.month/.day off these
      // two fields, so the conversion has to happen at the parse, once.
      paydate: json['paydate'] != null
          ? DateTime.parse(json['paydate'].toString()).toLocal()
          : null,
      paystatus: json['paystatus'],
      paymethod: json['paymethod'],
      payreference: json['payreference'],
      createdby: json['createdby'],
      createdat: json['createdat'] != null
          ? DateTime.parse(json['createdat'].toString()).toLocal()
          : DateTime.now(),
      activestatus: json['activestatus'] ?? 1,
      stuname: json['stuname'],
      reconStatus: json['recon_status']?.toString(),
    );
  }

  double get amount => transtotalamount;
  bool get isSuccess => paystatus == 'C';

  String get statusText {
    switch (paystatus) {
      case 'C':
        return 'Completed';
      case 'F':
        return 'Failed';
      case 'R':
        return 'Refunded';
      case 'I':
        return 'Initiated';
      default:
        return 'Pending';
    }
  }
}
