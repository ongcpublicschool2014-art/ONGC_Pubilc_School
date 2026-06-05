/// Admission model — matches the PUBLIC-schema `admission` staging table
/// (see C:\pg_backups\admission_module.sql). A row stays here as PENDING
/// until a section is allocated, after which it is moved into the institution
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
  final String admstatus; // PENDING | ALLOCATED | CANCELLED
  final String? allocatedclass;
  final int? stuId;
  final String? allocatedby;
  final DateTime? allocateddate;
  final String? admremarks;

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
  final String? emisno;
  final String? clagrpname;     // CURRENT standard
  final String? admclagrpname;  // ADMITTED standard (frozen at admission)
  final String? stuclass;       // preferred section
  final String? medium;         // medium of instruction
  final int? conId;
  final String? stucondesc;
  final String? admittyear;

  // demographics / facilities
  final String? community;
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
    this.admstatus = 'PENDING',
    this.allocatedclass,
    this.stuId,
    this.allocatedby,
    this.allocateddate,
    this.admremarks,
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
    this.clagrpname,
    this.admclagrpname,
    this.stuclass,
    this.medium,
    this.conId,
    this.stucondesc,
    this.admittyear,
    this.community,
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
      admstatus: j['admstatus']?.toString() ?? 'PENDING',
      allocatedclass: j['allocatedclass']?.toString(),
      stuId: _int(j['stu_id']),
      allocatedby: j['allocatedby']?.toString(),
      allocateddate: _date(j['allocateddate']),
      admremarks: j['admremarks']?.toString(),
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
      clagrpname: j['clagrpname']?.toString(),
      admclagrpname: j['admclagrpname']?.toString(),
      stuclass: j['stuclass']?.toString(),
      medium: j['medium']?.toString(),
      conId: _int(j['con_id']),
      stucondesc: j['stucondesc']?.toString(),
      admittyear: j['admittyear']?.toString(),
      community: j['community']?.toString(),
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

  String get genderLabel =>
      stugender == 'M' ? 'Male' : stugender == 'F' ? 'Female' : 'Other';
  bool get isAllocated => admstatus == 'ALLOCATED' || stuId != null;
  bool get isPending => admstatus == 'PENDING';
}

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
