/// Student model matching Supabase 'students' table
class StudentModel {
  final int stuId;
  final int insId;
  final String inscode;
  final String stuadmno;
  final DateTime stuadmdate;
  final String stuname;
  final String stugender;
  final DateTime studob;
  final String stumobile;
  final String? stuemail;
  final String? stuaddress;
  final String? stucity;
  final String? stustate;
  final String? stucountry;
  final String? stupin;
  final String? stubloodgrp;
  final String? stuphoto;
  final String stuclass;
  final int? cgrpId;
  final String? clagrpname;
  final int? conId;
  final String stuserId;
  final int activestatus;
  final DateTime createdon;

  StudentModel({
    required this.stuId,
    required this.insId,
    required this.inscode,
    required this.stuadmno,
    required this.stuadmdate,
    required this.stuname,
    required this.stugender,
    required this.studob,
    required this.stumobile,
    this.stuemail,
    this.stuaddress,
    this.stucity,
    this.stustate,
    this.stucountry,
    this.stupin,
    this.stubloodgrp,
    this.stuphoto,
    required this.stuclass,
    this.cgrpId,
    this.clagrpname,
    this.conId,
    required this.stuserId,
    this.activestatus = 1,
    required this.createdon,
  });

  factory StudentModel.fromJson(Map<String, dynamic> json) {
    return StudentModel(
      stuId: json['stu_id'] is int
          ? json['stu_id']
          : int.parse(json['stu_id'].toString()),
      insId: json['ins_id'] is int
          ? json['ins_id']
          : int.parse(json['ins_id'].toString()),
      inscode: json['inscode'] ?? '',
      stuadmno: json['stuadmno'] ?? '',
      stuadmdate: json['stuadmdate'] != null
          ? DateTime.parse(json['stuadmdate'])
          : DateTime.now(),
      stuname: json['stuname'] ?? '',
      stugender: json['stugender'] ?? 'M',
      studob: json['studob'] != null
          ? DateTime.parse(json['studob'])
          : DateTime.now(),
      stumobile: json['stumobile'] ?? '',
      stuemail: json['stuemail'],
      stuaddress: json['stuaddress'],
      stucity: json['stucity'],
      stustate: json['stustate'],
      stucountry: json['stucountry'],
      stupin: json['stupin'],
      stubloodgrp: json['stubloodgrp'],
      stuphoto: json['stuphoto'],
      stuclass: json['stuclass'] ?? '',
      cgrpId: json['cgrp_id'] as int?,
      clagrpname: json['clagrpname']?.toString(),
      conId: json['con_id'] as int?,
      stuserId: json['stuser_id'] ?? '',
      activestatus: json['activestatus'] ?? 1,
      createdon: json['createdon'] != null
          ? DateTime.parse(json['createdon'])
          : DateTime.now(),
    );
  }

  String get name => stuname;
  String get admissionNumber => stuadmno;
  String get className => stuclass;
  String get gender =>
      stugender == 'M' ? 'Male' : stugender == 'F' ? 'Female' : 'Other';
  bool get isActive => activestatus == 1;
}
