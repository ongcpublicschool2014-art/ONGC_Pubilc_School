import '../utils/school_terms.dart' show genderLabelOf;

/// Admission model — matches the PUBLIC-schema `admission` staging table
/// (see migrations/admission_public_module.sql). A row stays here as PENDING
/// until a class is allocated, after which it is moved into the institution
/// schema's students/parents/parentdetail tables and marked ALLOCATED.
class AdmissionModel {
  final int admId;
  final int insId;
  final String inscode;
  final int yrId;
  final String yrlabel;

  final String admno;
  final DateTime admdate;
  final String? admsource;

  /// 1 = seat booked now, studies from next year. See the Pre-admission
  /// tick on the Admission Entry screen.
  final int? preadmission;
  final String admstatus; // PENDING | ALLOCATED | CANCELLED
  final String? allocatedclass;
  final int? stuId;
  final String? allocatedby;
  final DateTime? allocateddate;
  final String? admremarks;
  /// Personal marks of identification (printed on the TC).
  final String? idmark1, idmark2;

  // student fields
  final String stuname;
  final String stugender; // M | F | T
  final DateTime? studob;
  final String? stumobile;
  final String? stuemail;
  final String? stuaddress;
  final String? stucity;
  final String? stustate;
  final String? stucountry;
  final String? stupin;
  final String? stubloodgrp;
  final String? stuphoto;
  final String? aadharno;
  /// Government student identifiers entered alongside Aadhar. EMIS comes from
  /// the school record; UMIS is issued on university enrolment, so a fresher
  /// often has one and not the other.
  final String? emisno;
  final String? umisno;
  /// Government scholarship. 'Y' / 'N' / null (not yet asked). The type is only
  /// meaningful when eligible is 'Y' — the form clears it when set back to No.
  final String? scholarship;
  final String? scholarshiptype;
  final String? courname;
  final String? stuclass;
  final String? admname; // admission type
  final String? quoname;
  final int? conId;
  final String? stucondesc;
  final String? batch;
  final String? admittyear;
  final String? medium;
  final String? paremail;

  // demographics / facilities
  final String? community;
  /// Admission -> Division (name from the Division master).
  final String? division;
  final String? caste;
  final String? religion;
  final String? nationality;
  final String? transportmode; // OWN | COLLEGE
  final String? hostel;        // Y | N

  // previous academics
  final String? prevschool;
  final String? prevclass;
  final String? prevboard;
  final double? prevpercent;

  // parent / guardian
  final String? fathername;
  final String? fathermobile;
  final String? fatheroccupation;
  final String? mothername;
  final String? mothermobile;
  final String? motheroccupation;
  final String? guardianname;
  final String? guardianmobile;
  final String? guardianoccupation;
  final String? payincharge;
  final String? payinchargemob;

  final String? createdby;
  final DateTime? createdon;
  final int activestatus;

  AdmissionModel({
    required this.admId,
    required this.insId,
    required this.inscode,
    required this.yrId,
    required this.yrlabel,
    required this.admno,
    required this.admdate,
    this.admsource,
    this.preadmission,
    this.admstatus = 'PENDING',
    this.allocatedclass,
    this.stuId,
    this.allocatedby,
    this.allocateddate,
    this.admremarks,
    this.idmark1,
    this.idmark2,
    required this.stuname,
    required this.stugender,
    this.studob,
    this.stumobile,
    this.stuemail,
    this.stuaddress,
    this.stucity,
    this.stustate,
    this.stucountry,
    this.stupin,
    this.stubloodgrp,
    this.stuphoto,
    this.aadharno,
    this.emisno,
    this.umisno,
    this.scholarship,
    this.scholarshiptype,
    this.courname,
    this.stuclass,
    this.admname,
    this.quoname,
    this.conId,
    this.stucondesc,
    this.batch,
    this.admittyear,
    this.medium,
    this.paremail,
    this.community,
    this.division,
    this.caste,
    this.religion,
    this.nationality,
    this.transportmode,
    this.hostel,
    this.prevschool,
    this.prevclass,
    this.prevboard,
    this.prevpercent,
    this.fathername,
    this.fathermobile,
    this.fatheroccupation,
    this.mothername,
    this.mothermobile,
    this.motheroccupation,
    this.guardianname,
    this.guardianmobile,
    this.guardianoccupation,
    this.payincharge,
    this.payinchargemob,
    this.createdby,
    this.createdon,
    this.activestatus = 1,
  });

  static DateTime? _date(dynamic v) =>
      (v == null || v.toString().isEmpty) ? null : DateTime.tryParse(v.toString());
  static int? _int(dynamic v) => v == null ? null : (v is int ? v : int.tryParse(v.toString()));
  static double? _dbl(dynamic v) =>
      v == null ? null : (v is num ? v.toDouble() : double.tryParse(v.toString()));

  factory AdmissionModel.fromJson(Map<String, dynamic> j) {
    return AdmissionModel(
      admId: _int(j['adm_id']) ?? 0,
      insId: _int(j['ins_id']) ?? 0,
      inscode: j['inscode']?.toString() ?? '',
      yrId: _int(j['yr_id']) ?? 0,
      yrlabel: j['yrlabel']?.toString() ?? '',
      admno: j['admno']?.toString() ?? '',
      admdate: _date(j['admdate']) ?? DateTime.now(),
      admsource: j['admsource']?.toString(),
      preadmission: (j['preadmission'] as num?)?.toInt(),
      admstatus: j['admstatus']?.toString() ?? 'PENDING',
      allocatedclass: j['allocatedclass']?.toString(),
      stuId: _int(j['stu_id']),
      allocatedby: j['allocatedby']?.toString(),
      allocateddate: _date(j['allocateddate']),
      admremarks: j['admremarks']?.toString(),
      idmark1: j['idmark1']?.toString(),
      idmark2: j['idmark2']?.toString(),
      stuname: j['stuname']?.toString() ?? '',
      stugender: j['stugender']?.toString() ?? 'M',
      studob: _date(j['studob']),
      stumobile: j['stumobile']?.toString(),
      stuemail: j['stuemail']?.toString(),
      stuaddress: j['stuaddress']?.toString(),
      stucity: j['stucity']?.toString(),
      stustate: j['stustate']?.toString(),
      stucountry: j['stucountry']?.toString(),
      stupin: j['stupin']?.toString(),
      stubloodgrp: j['stubloodgrp']?.toString(),
      stuphoto: j['stuphoto']?.toString(),
      aadharno: j['aadharno']?.toString(),
      emisno: j['emisno']?.toString(),
      umisno: j['umisno']?.toString(),
      scholarship: j['scholarship']?.toString(),
      scholarshiptype: j['scholarshiptype']?.toString(),
      courname: j['courname']?.toString(),
      stuclass: j['stuclass']?.toString(),
      admname: j['admname']?.toString(),
      quoname: j['quoname']?.toString(),
      conId: _int(j['con_id']),
      stucondesc: j['stucondesc']?.toString(),
      batch: j['batch']?.toString(),
      admittyear: j['admittyear']?.toString(),
      medium: j['medium']?.toString(),
      paremail: j['paremail']?.toString(),
      community: j['community']?.toString(),
      division: j['division']?.toString(),
      caste: j['caste']?.toString(),
      religion: j['religion']?.toString(),
      nationality: j['nationality']?.toString(),
      transportmode: j['transportmode']?.toString(),
      hostel: j['hostel']?.toString(),
      prevschool: j['prevschool']?.toString(),
      prevclass: j['prevclass']?.toString(),
      prevboard: j['prevboard']?.toString(),
      prevpercent: _dbl(j['prevpercent']),
      fathername: j['fathername']?.toString(),
      fathermobile: j['fathermobile']?.toString(),
      fatheroccupation: j['fatheroccupation']?.toString(),
      mothername: j['mothername']?.toString(),
      mothermobile: j['mothermobile']?.toString(),
      motheroccupation: j['motheroccupation']?.toString(),
      guardianname: j['guardianname']?.toString(),
      guardianmobile: j['guardianmobile']?.toString(),
      guardianoccupation: j['guardianoccupation']?.toString(),
      payincharge: j['payincharge']?.toString(),
      payinchargemob: j['payinchargemob']?.toString(),
      createdby: j['createdby']?.toString(),
      createdon: _date(j['createdon']),
      activestatus: _int(j['activestatus']) ?? 1,
    );
  }

  /// Boy / Girl / Other (school), Male / Female / Other (college).
  String get genderLabel => stugender == 'M' || stugender == 'F' ? genderLabelOf(stugender) : 'Other';
  bool get isAllocated => admstatus == 'ALLOCATED' || stuId != null;
  bool get isPending => admstatus == 'PENDING';
  /// A TC has been issued (leaving status 2/3/4/5/9) → the record is view-only.
  bool get isTcLocked => activestatus != 1;
}

/// Admission workflow statuses for the public.admission staging table.
class AdmissionStatus {
  static const pending = 'PENDING';
  static const allocated = 'ALLOCATED';
  static const cancelled = 'CANCELLED';

  static const List<String> ordered = [pending, allocated, cancelled];

  static const Map<String, String> labels = {
    pending: 'Pending',
    allocated: 'Allocated',
    cancelled: 'Cancelled',
  };

  static String label(String s) => labels[s] ?? s;
}
