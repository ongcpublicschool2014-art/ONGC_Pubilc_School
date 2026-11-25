import 'dart:io';

import 'package:excel/excel.dart' as xl;
import '../../utils/excel_theme.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/class_sort.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/pill_tab.dart';
import 'admission_abstract_screen.dart';
import 'class_strength_screen.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_multi_pick.dart';
import '../../utils/save_path.dart';

/// ADMISSION REGISTER — the admissions taken in a date range, one row per
/// student, with the columns the office chooses and in the order it chooses.
///
/// Replaces the register from the old VB system, whose sheet this reproduces:
/// institution name / address / city, the title naming the course or class,
/// the From–To line, then SNo. plus the chosen fields, and a closing note
/// saying whether TC students were included.
///
/// WHICH FIELDS ARE OFFERED
/// The old dialog listed 37. Eleven of them have no column anywhere in this
/// database — Mother Tongue, Id Mark 1/2, Living With, the five separate phone
/// numbers and the two annual-income figures — and they were blank in the
/// sample sheet too. Offering them would print columns that can never fill, so
/// [_kFields] carries the 26 that resolve to real data. Adding any of the
/// others is a migration plus a form field first, then one entry here.
class AdmissionRegisterScreen extends StatefulWidget {
  const AdmissionRegisterScreen({super.key});

  @override
  State<AdmissionRegisterScreen> createState() => _AdmissionRegisterScreenState();
}

/// One selectable column.
///
/// [key] is what the picker moves around and what the sheet is built from;
/// [read] turns an admission row into the printed text. TC columns read from
/// the tc_entry row attached under `_tc` (see _load).
class _Field {
  final String key;
  final String label;
  final String Function(Map<String, dynamic> r) read;
  const _Field(this.key, this.label, this.read);
}

String _s(Object? v) => (v ?? '').toString().trim();

/// 'yyyy-MM-dd...' -> 'dd-MM-yyyy'.
String _d(Object? v) {
  final s = _s(v);
  if (s.length < 10) return '';
  final y = s.substring(0, 4), m = s.substring(5, 7), d = s.substring(8, 10);
  return '$d-$m-$y';
}

/// ordid as an int; blanks sort last.
int _ord(Object? v) => v is num ? v.toInt() : (int.tryParse(_s(v)) ?? 9999);

/// A numeric column as an int; blank is 0.
int _num(Object? v) => v is num ? v.toInt() : (int.tryParse(_s(v)) ?? 0);

Map<String, dynamic> _tcOf(Map<String, dynamic> r) =>
    (r['_tc'] as Map<String, dynamic>?) ?? const {};

/// The register's columns, in the order the old dialog listed them.
const List<_Field> _kFields = [
  _Field('admdate', AppText.dateOfAdmission, _readAdmDate),
  _Field('admno', 'Register No', _readAdmNo),
  _Field('aadharno', 'Aadhaar No.', _readAadhar),
  _Field('stuname', 'Student Name', _readName),
  _Field('stugender', 'Sex', _readSex),
  _Field('fathername', 'Father Name', _readFather),
  _Field('mothername', 'Mother Name', _readMother),
  _Field('courname', 'Course', _readCourse),
  _Field('stuclass', 'Class', _readClass),
  _Field('medium', 'Medium', _readMedium),
  _Field('yrlabel', 'Academic Year', _readYear),
  _Field('admname', 'Admission Type', _readAdmType),
  _Field('prevschool', 'Last School Studied', _readPrevSchool),
  _Field('studob', AppText.dateOfBirth, _readDob),
  _Field('community', 'Community', _readCommunity),
  _Field('caste', 'Caste', _readCaste),
  _Field('religion', 'Religion', _readReligion),
  _Field('nationality', 'Nationality', _readNationality),
  _Field('stubloodgrp', 'Blood Group', _readBlood),
  _Field('stuaddress', 'Permanent Address', _readAddress),
  _Field('stucity', 'City', _readCity),
  _Field('tcno', 'TC No', _readTcNo),
  _Field('tcdate', 'TC Date', _readTcDate),
  _Field('tcreason', 'TC Reason', _readTcReason),
  _Field('stumobile', 'Mobile No', _readMobile),
  _Field('stuemail', 'Email ID', _readEmail),
  // Everything else on the admission record that has a column behind it. The
  // old dialog never offered these -- the VB system had no EMIS/UMIS and kept
  // occupations elsewhere -- but they are asked for often enough to belong in
  // a register the office builds itself.
  _Field('emisno', 'EMIS No', _readEmis),
  _Field('umisno', 'UMIS No', _readUmis),
  _Field('fathermobile', 'Father Mobile', _readFatherMob),
  _Field('fatheroccupation', 'Father Occupation', _readFatherOcc),
  _Field('mothermobile', 'Mother Mobile', _readMotherMob),
  _Field('motheroccupation', 'Mother Occupation', _readMotherOcc),
  _Field('guardianname', 'Guardian Name', _readGuardian),
  _Field('guardianmobile', 'Guardian Mobile', _readGuardianMob),
  _Field('guardianoccupation', 'Guardian Occupation', _readGuardianOcc),
  _Field('payincharge', 'Pay In Charge', _readPayer),
  _Field('payinchargemob', 'Pay In Charge Mobile', _readPayerMob),
  _Field('paremail', 'Parent Email', _readParentEmail),
  _Field('quoname', 'Quota', _readQuota),
  _Field('stucondesc', 'Concession', _readConcession),
  _Field('batch', 'Batch', _readBatch),
  _Field('admsource', 'Admission Source', _readSource),
  _Field('admstatus', 'Admission Status', _readStatus),
  _Field('stustate', 'State', _readState),
  _Field('stucountry', 'Country', _readCountry),
  _Field('stupin', 'Pincode', _readPin),
  _Field('prevclass', 'Previous Class', _readPrevClass),
  _Field('prevboard', 'Previous Board', _readPrevBoard),
  _Field('prevpercent', 'Previous %', _readPrevPercent),
  _Field('hostel', 'Hostel', _readHostel),
  _Field('transportmode', 'Transport', _readTransport),
  _Field('scholarship', 'Scholarship', _readScholarship),
  _Field('scholarshiptype', 'Scholarship Type', _readScholarshipType),
];

/// Register fields that have no column on a school (admission type, quota,
/// batch do not exist there), so they are never offered.
const Set<String> _kSchoolHiddenFields = {'admname', 'quoname', 'batch', 'umisno', 'scholarship', 'scholarshiptype'}; // nor UMIS / scholarship

/// A field's label as the person reads it. Previous Class is the class at the
/// previous school, not a section here, so it keeps its own wording.
String _fieldLabel(_Field f) => f.key == 'prevclass' ? f.label : schoolTerm(f.label);

String _readAdmDate(Map<String, dynamic> r) => _d(r['admdate']);
String _readAdmNo(Map<String, dynamic> r) => _s(r['admno']);
String _readAadhar(Map<String, dynamic> r) => _s(r['aadharno']);
String _readName(Map<String, dynamic> r) => _s(r['stuname']);
String _readSex(Map<String, dynamic> r) => _s(r['stugender']);
String _readFather(Map<String, dynamic> r) => _s(r['fathername']);
String _readMother(Map<String, dynamic> r) => _s(r['mothername']);
String _readCourse(Map<String, dynamic> r) => _s(r['courname']);
String _readClass(Map<String, dynamic> r) => _s(r['stuclass']);
String _readMedium(Map<String, dynamic> r) => _s(r['medium']);
String _readYear(Map<String, dynamic> r) => _s(r['admittyear']);
String _readAdmType(Map<String, dynamic> r) => _s(r['admname']);
String _readPrevSchool(Map<String, dynamic> r) => _s(r['prevschool']);
String _readDob(Map<String, dynamic> r) => _d(r['studob']);
String _readCommunity(Map<String, dynamic> r) => _s(r['community']);
String _readCaste(Map<String, dynamic> r) => _s(r['caste']);
String _readReligion(Map<String, dynamic> r) => _s(r['religion']);
String _readNationality(Map<String, dynamic> r) => _s(r['nationality']);
String _readBlood(Map<String, dynamic> r) => _s(r['stubloodgrp']);
String _readAddress(Map<String, dynamic> r) => _s(r['stuaddress']).replaceAll('\n', ', ');
String _readCity(Map<String, dynamic> r) => _s(r['stucity']);
String _readTcNo(Map<String, dynamic> r) => _s(_tcOf(r)['tcno']);
String _readTcDate(Map<String, dynamic> r) => _d(_tcOf(r)['tcdate']);
String _readTcReason(Map<String, dynamic> r) => _s(_tcOf(r)['remarks']);
String _readMobile(Map<String, dynamic> r) => _s(r['stumobile']);
String _readEmail(Map<String, dynamic> r) => _s(r['stuemail']);
String _readEmis(Map<String, dynamic> r) => _s(r['emisno']);
String _readUmis(Map<String, dynamic> r) => _s(r['umisno']);
String _readFatherMob(Map<String, dynamic> r) => _s(r['fathermobile']);
String _readFatherOcc(Map<String, dynamic> r) => _s(r['fatheroccupation']);
String _readMotherMob(Map<String, dynamic> r) => _s(r['mothermobile']);
String _readMotherOcc(Map<String, dynamic> r) => _s(r['motheroccupation']);
String _readGuardian(Map<String, dynamic> r) => _s(r['guardianname']);
String _readGuardianMob(Map<String, dynamic> r) => _s(r['guardianmobile']);
String _readGuardianOcc(Map<String, dynamic> r) => _s(r['guardianoccupation']);
String _readPayer(Map<String, dynamic> r) => _s(r['payincharge']);
String _readPayerMob(Map<String, dynamic> r) => _s(r['payinchargemob']);
String _readParentEmail(Map<String, dynamic> r) => _s(r['paremail']);
String _readQuota(Map<String, dynamic> r) => _s(r['quoname']);
String _readConcession(Map<String, dynamic> r) => _s(r['stucondesc']);
String _readBatch(Map<String, dynamic> r) => _s(r['batch']);
String _readSource(Map<String, dynamic> r) => _s(r['admsource']);
String _readStatus(Map<String, dynamic> r) => _s(r['admstatus']);
String _readState(Map<String, dynamic> r) => _s(r['stustate']);
String _readCountry(Map<String, dynamic> r) => _s(r['stucountry']);
String _readPin(Map<String, dynamic> r) => _s(r['stupin']);
String _readPrevClass(Map<String, dynamic> r) => _s(r['prevclass']);
String _readPrevBoard(Map<String, dynamic> r) => _s(r['prevboard']);
String _readPrevPercent(Map<String, dynamic> r) => _s(r['prevpercent']);
String _readHostel(Map<String, dynamic> r) => _s(r['hostel']);
String _readTransport(Map<String, dynamic> r) => _s(r['transportmode']);
String _readScholarship(Map<String, dynamic> r) => _s(r['scholarship']);
String _readScholarshipType(Map<String, dynamic> r) => _s(r['scholarshiptype']);

class _AdmissionRegisterScreenState extends State<AdmissionRegisterScreen>
    with SingleTickerProviderStateMixin {
  // The register lists the students; the abstract counts them. One menu entry,
  // two views of the same admissions.
  late final TabController _tabs = TabController(length: 3, vsync: this);
  static const _tabLabels = ['Register', 'Abstract', 'Class Strength'];
  static const _tabIcons = ['book-1', 'chart-2', 'people'];

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  String get _yearLabel => _s(context.read<AuthProvider>().yearLabel);

  bool _loading = true;
  bool _running = false;
  String? _loadError;

  // Masters for the filters.
  List<Map<String, dynamic>> _courseRows = [];
  List<Map<String, dynamic>> _classRows = [];
  List<String> _admTypes = [];

  String _insName = '';
  String _insAddress = '';
  String _insCity = '';

  // ── Filters ───────────────────────────────────────────────────────────────
  late DateTime _from;
  late DateTime _to;

  /// null = every course / every class. Two dropdowns rather than the old
  /// All / Course / Class radio and one shared picker, so this filter row
  /// reads the same as every other report screen.
  String? _course;
  /// Classes to include. Empty = all of them.
  ///
  /// A register is usually wanted for a few classes at once -- III and IV, or
  /// every first year -- and a single-select dropdown meant running the report
  /// once per class and pasting the sheets together.
  final Set<String> _classes = {};

  /// The one-class label used in titles and file names; null when the filter
  /// is all classes or several of them.
  String? get _class => _classes.length == 1 ? _classes.first : null;

  /// null = every admission type. A plain dropdown rather than the old
  /// All/Selected radio pair, which needed two controls to say one thing.
  String? _admType;

  /// Unticked by default, matching the old report: the register is normally
  /// the students still on the rolls, and the sheet says so in its closing
  /// note either way.
  bool _withTc = false;

  // ── Column selection ──────────────────────────────────────────────────────
  final List<String> _picked = [];  // Report List, in print order
  String? _availSel;                // highlighted in Available
  String? _pickedSel;               // highlighted in Report List

  /// How the sheet is sorted. A register is read by register number or by
  /// name; unlike the old order-by list this cannot be left empty, which used
  /// to leave the order to whatever the database happened to return.
  String _orderKey = 'admno';

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Fallback window, as the old dialog had it: this May to next May.
    // _loadMasters replaces it with the logged-in year's dates.
    final now = DateTime.now();
    _from = DateTime(now.year, 5, 6);
    if (now.isBefore(_from)) _from = DateTime(now.year - 1, 5, 6);
    _to = DateTime(_from.year + 1, 5, 5);
    // A register with no columns prints nothing, so start with the ones every
    // register carries; the office adds the rest.
    _picked.addAll(const ['admdate', 'admno', 'stuname', 'stugender', 'courname', 'stuclass']);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMasters());
  }

  List<_Field> get _availableFields =>
      _kFields
          .where((f) => !_picked.contains(f.key) && !(isSchool && _kSchoolHiddenFields.contains(f.key)))
          .toList();

  _Field _field(String key) => _kFields.firstWhere((f) => f.key == key);

  Future<void> _loadMasters() async {
    final auth = context.read<AuthProvider>();
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final insId = _insId;
      final res = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course')
            .select('cour_id, courname, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.fromSchema('class')
            .select('claname, cour_id, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        // A school has no admission-type table.
        if (isSchool)
          Future<dynamic>.value(const [])
        else
          SupabaseService.fromSchema('admissiontype')
              .select('admname')
              .eq('ins_id', insId)
              .eq('activestatus', 1),
        SupabaseService.getInstitutionInfo(insId),
        _loadYearDates(insId),
      ]);
      if (!mounted) return;
      final info = res[3] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final yearDates = res[4] as (DateTime, DateTime)?;
      setState(() {
        if (yearDates != null) {
          _from = yearDates.$1;
          _to = yearDates.$2;
        }
        // Master-data order: standards by ordid, sections by (standard, section) ordid.
        _courseRows = List<Map<String, dynamic>>.from(res[0] as List)
          ..sort((a, b) {
            final c = _ord(a['ordid']).compareTo(_ord(b['ordid']));
            return c != 0 ? c : _s(a['courname']).compareTo(_s(b['courname']));
          });
        final courOrd = {for (final c in _courseRows) c['cour_id']: _ord(c['ordid'])};
        _classRows = List<Map<String, dynamic>>.from(res[1] as List)
          ..sort((a, b) {
            var c = (courOrd[a['cour_id']] ?? 9999).compareTo(courOrd[b['cour_id']] ?? 9999);
            if (c == 0) c = _ord(a['ordid']).compareTo(_ord(b['ordid']));
            return c != 0 ? c : _s(a['claname']).compareTo(_s(b['claname']));
          });
        _admTypes = (res[2] as List)
            .map((e) => _s(e['admname']))
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
        _insName = info.name ?? '';
        final addr = (info.address ?? '').replaceAll('\n', ', ');
        // The old sheet printed address and city on separate lines. Ours comes
        // back as one string, so the LAST comma-separated part becomes the city
        // line and the rest stays above it.
        final parts = addr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        if (parts.length > 1) {
          _insCity = parts.removeLast();
          _insAddress = parts.join(', ');
        } else {
          _insAddress = addr;
          _insCity = '';
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = friendlyError(e);
      });
    }
  }

  /// Start and end of the logged-in academic year, or null when it is not
  /// found (the May-to-May default then stays).
  Future<(DateTime, DateTime)?> _loadYearDates(int insId) async {
    final label = _yearLabel;
    if (label.isEmpty) return null;
    try {
      final rows = await SupabaseService.client
          .from('institutionyear')
          .select('iyrstadate, iyrenddate')
          .eq('ins_id', insId)
          .eq('yrlabel', label)
          .limit(1);
      if (rows.isEmpty) return null;
      final start = DateTime.tryParse(_s(rows.first['iyrstadate']));
      final end = DateTime.tryParse(_s(rows.first['iyrenddate']));
      if (start == null || end == null) return null;
      return (start, end);
    } catch (_) {
      return null;
    }
  }

  List<String> get _courseNames =>
      _courseRows.map((e) => _s(e['courname'])).where((s) => s.isNotEmpty).toList();

  /// Classes of the chosen course, or all of them -- grouped so TC batches sit
  /// last, like every other class picker (utils/class_sort.dart).
  List<String> get _classNames {
    final courId = _course == null
        ? null
        : _courseRows.firstWhere((c) => _s(c['courname']) == _course,
            orElse: () => const <String, dynamic>{})['cour_id'];
    return classGroupPartition(
        _classRows
            .where((c) => courId == null || c['cour_id'] == courId)
            .map((e) => _s(e['claname']))
            .where((s) => s.isNotEmpty),
        (s) => s);
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _dmy(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  /// Class filter: tick as many as the register should cover.
  Widget _classPicker() {
    final label = _classes.isEmpty
        ? schoolTerm('All Classes')
        : (_classes.length == 1
            ? _classes.first
            : schoolTerm('${_classes.length} classes selected'));
    return Builder(builder: (field) => InkWell(
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: _running
          ? null
          : () {
              _anchor = field;
              _openClassPicker();
            },
      child: Container(
        constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
        padding: EdgeInsets.symmetric(horizontal: 12.w),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(
              color: _classes.isEmpty
                  ? AppColors.border
                  : AppColors.primary.withValues(alpha: 0.55)),
        ),
        child: Row(children: [
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: _classes.isEmpty
                    ? AppUI.fieldText(context).copyWith(
                        fontWeight: FontWeight.w500, color: AppColors.textLight)
                    : AppUI.fieldText(context, filled: true)),
          ),
          Icon(Icons.arrow_drop_down, color: AppColors.textSecondary, size: 22.sp),
        ]),
      ),
    ));
  }

  /// The filter field just tapped: the pick panel opens under it.
  BuildContext? _anchor;

  Future<void> _openClassPicker() async {
    final picked = await showAppMultiPick<String>(
      context,
      anchor: _anchor,
      title: schoolTerm('Select Classes'),
      searchHint: schoolTerm('Search class'),
      groups: [('', [for (final c in _classNames) (c, c)])],
      selected: _classes,
    );
    if (picked == null || !mounted) return;
    setState(() => _classes
      ..clear()
      ..addAll(picked));
  }

  /// One half of the New admissions / Active students switch.
  Widget _modeSeg(String label, String value) {
    final on = _mode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: _running ? null : () => setState(() => _mode = value),
      child: Container(
        constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: 14.w),
        decoration: BoxDecoration(
          color: on ? AppColors.primaryLight : Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: on ? AppColors.primary : AppColors.border),
        ),
        child: Text(label,
            style: AppUI.label.copyWith(color: on ? AppColors.primary : AppColors.textSecondary)),
      ),
    );
  }

  /// Who the register lists.
  ///
  ///   'NEW'    -- admitted between From and To. The register as it was: a
  ///              record of admissions taken in a period.
  ///   'ACTIVE' -- everyone on the rolls in the current year, whenever they
  ///              were admitted. The same 47 columns, the same picker, a
  ///              different question: not "who joined" but "who is here".
  ///
  /// Both read public.admission, so no column is lost either way; ACTIVE only
  /// drops the date window and keeps the admissions whose student is still
  /// active in this year's schema.
  String _mode = 'NEW';

  // ── Run ───────────────────────────────────────────────────────────────────

  Future<void> _run({required bool pdf}) async {
    if (_picked.isEmpty) {
      _snack('Add at least one field to the report list.', AppColors.warning);
      return;
    }
    if (_mode == 'NEW' && _to.isBefore(_from)) {
      _snack('The To date is before the From date. Select a To date on or after the From date.', AppColors.warning);
      return;
    }
    setState(() => _running = true);
    try {
      final insId = _insId;
      // fetchAll, not a plain select: PostgREST caps a response at 1000 rows
      // and truncates silently, which on a full year would drop most of the
      // register without saying so.
      var q = SupabaseService.client
          .from('admission')
          .select('admno, admdate, stuname, stugender, studob, stumobile, stuemail, '
              'stuaddress, stucity, stustate, stucountry, stupin, stubloodgrp, aadharno, '
              '${isSchool ? 'courname, stuclass, stucondesc, admsource, admstatus, ' : 'courname, stuclass, admname, quoname, stucondesc, batch, admsource, admstatus, '}'
              'community, caste, religion, nationality, medium, admittyear, '
              'prevschool, prevclass, prevboard, prevpercent, hostel, transportmode, '
              'scholarship, scholarshiptype, emisno, ${isSchool ? '' : 'umisno, '}paremail, '
              'fathername, fathermobile, fatheroccupation, '
              'mothername, mothermobile, motheroccupation, '
              'guardianname, guardianmobile, guardianoccupation, '
              'payincharge, payinchargemob, activestatus')
          .eq('ins_id', insId);
      // The date window belongs to the admissions question only. "Who is on
      // the rolls now" is not a period, and filtering it by admdate would drop
      // every senior student.
      if (_mode == 'NEW') {
        q = q
            .gte('admdate', _ymd(_from))
            .lte('admdate', _ymd(_to))
            .neq('admstatus', 'CANCELLED');
        // Standard / section filters run here for NEW only. ACTIVE takes them
        // from the students rows below, which follow Section Transfer.
        if (_s(_course).isNotEmpty) q = q.eq('courname', _course!);
        if (_classes.isNotEmpty) q = q.inFilter('stuclass', _classes.toList());
      }
      if (!isSchool && _s(_admType).isNotEmpty) {
        q = q.eq('admname', _admType!);
      }
      var rows = List<Map<String, dynamic>>.from(
          await SupabaseService.fetchAll(() => q));

      // ACTIVE: keep only the admissions whose student is still on this year's
      // rolls. students, not admission.activestatus -- a student who has left
      // is taken off the roll in the year schema, and admission keeps the
      // record of the admission itself.
      if (_mode == 'ACTIVE') {
        // Current standard / section per reg no, from this year's students.
        final onRoll = <String, Map<String, dynamic>>{};
        try {
          final stu = await SupabaseService.fetchAll(() => SupabaseService
              .fromSchema('students')
              .select('stuadmno, stuclass, courname')
              .eq('ins_id', insId)
              .eq('activestatus', 1)
              .eq('preadmission', 0));
          for (final r in stu) {
            final k = _s(r['stuadmno']);
            if (k.isNotEmpty) onRoll[k] = r;
          }
        } catch (e) {
          _snack('Could not load this year\'s students. ${friendlyError(e)}', AppColors.error);
          setState(() => _running = false);
          return;
        }
        final course = _s(_course).toUpperCase();
        final classes = _classes.map((c) => c.toUpperCase()).toSet();
        rows = [
          for (final r in rows)
            if (onRoll[_s(r['admno'])] case final st?)
              {...r, 'courname': _s(st['courname']), 'stuclass': _s(st['stuclass'])},
        ]
            .where((r) =>
                (course.isEmpty || _s(r['courname']).toUpperCase() == course) &&
                (classes.isEmpty || classes.contains(_s(r['stuclass']).toUpperCase())))
            .toList();
      }

      // TC rows, keyed by reg no. Needed both for the TC columns and for the
      // "With T.C. Student" switch, and it is one read either way.
      final tcByAdmno = <String, Map<String, dynamic>>{};
      try {
        final tcRows = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('tc_entry')
            .select('stuadmno, tcno, tcdate, remarks, tc_id, status')
            .eq('ins_id', insId)
            .eq('activestatus', 1));
        // The latest row per reg no decides. A re-activation appends a row
        // with status 1 and no tcno, which cancels the earlier TC.
        final latest = <String, Map<String, dynamic>>{};
        for (final t in tcRows) {
          final k = _s(t['stuadmno']);
          if (k.isEmpty) continue;
          final prev = latest[k];
          if (prev == null || _num(t['tc_id']) > _num(prev['tc_id'])) latest[k] = t;
        }
        latest.forEach((k, t) {
          if (_s(t['tcno']).isNotEmpty && _num(t['status']) != 1) tcByAdmno[k] = t;
        });
      } catch (_) {
        // tc_entry missing on this schema: the TC columns print blank and the
        // TC filter has nothing to exclude, which is the honest result.
      }

      final out = <Map<String, dynamic>>[];
      for (final r in rows) {
        final tc = tcByAdmno[_s(r['admno'])];
        if (!_withTc && tc != null) continue; // "Without Tc Students"
        out.add({...r, if (tc != null) '_tc': tc});
      }

      if (out.isEmpty) {
        _snack(
            _mode == 'ACTIVE'
                ? 'No students on the rolls for these filters. Change the filters and try again.'
                : 'No admissions in this date range for these filters. Widen the dates or change the filters.',
            AppColors.warning);
        return;
      }

      // Ties fall back to reg no, so two students of the same name come out in
      // the same order every run.
      final orderField = _field(_orderKey);
      out.sort((a, b) {
        final c = orderField
            .read(a)
            .toUpperCase()
            .compareTo(orderField.read(b).toUpperCase());
        return c != 0 ? c : _s(a['admno']).compareTo(_s(b['admno']));
      });

      await (pdf ? _exportPdf(out) : _export(out));
    } catch (e) {
      _snack('Could not build the register. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// The class names the sheet when one is chosen: it is the narrower of the
  /// two, so naming the course as well would only repeat what it already says.
  String get _titleLine {
    if (_classes.length == 1) return schoolTerm('ADMISSION REGISTER of Class ${_classes.first}');
    if (_classes.length > 1) {
      return schoolTerm('ADMISSION REGISTER of ${_classes.length} Classes');
    }
    if (_s(_course).isNotEmpty) return schoolTerm('ADMISSION REGISTER of Course $_course');
    return 'ADMISSION REGISTER';
  }

  /// The line under the title: the date range, or the year for the roll list.
  String get _periodLine {
    if (_mode == 'ACTIVE') {
      return _yearLabel.isEmpty
          ? 'Students on the rolls'
          : 'Students on the rolls — Academic Year $_yearLabel';
    }
    return 'From : ${_dmy(_from)}  To : ${_dmy(_to)}';
  }

  /// File name without extension. The roll list has no date range.
  String _fileBase(String scopeName) {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    if (_mode == 'ACTIVE') {
      return 'Admission_Register_Active_$scopeName${_yearLabel.isEmpty ? '' : '_${safe(_yearLabel)}'}';
    }
    return 'Admission_Register_${scopeName}_${safe(_dmy(_from))}_${safe(_dmy(_to))}';
  }

  /// The same rows as the Excel sheet, laid out for paper.
  Future<void> _exportPdf(List<Map<String, dynamic>> rows) async {
    final fields = _picked.map(_field).toList();
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final scopeName = _s(_class).isNotEmpty
        ? safe(_class!)
        : _s(_course).isNotEmpty
            ? safe(_course!)
            : 'All';
    final ok = await saveReportPdf(
      context,
      fileName: _fileBase(scopeName),
      insName: _insName,
      insAddress: _insAddress,
      insCity: _insCity,
      title: _titleLine,
      subtitle: _periodLine,
      headers: [AppText.serialNo, ...fields.map(_fieldLabel)],
      rows: [
        for (var i = 0; i < rows.length; i++)
          ['${i + 1}', ...fields.map((f) => f.read(rows[i]))],
      ],
      rightAlign: const {0},
      footNote: 'Note: ${_withTc ? 'With' : 'Without'} TC Students',
    );
    if (ok) _snack('Admission register PDF saved -- ${rows.length} students.', AppColors.success);
  }

  Future<void> _export(List<Map<String, dynamic>> rows) async {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final scopeName = _s(_class).isNotEmpty
        ? safe(_class!)
        : _s(_course).isNotEmpty
            ? safe(_course!)
            : 'All';
    final path = await pickSavePath(
      dialogTitle: 'Save Admission Register',
      fileName: '${_fileBase(scopeName)}.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (path == null) return;

    final book = xl.Excel.createExcel();
    final sheet = book['Admission Register'];
    book.delete('Sheet1');

    final bold = xl.CellStyle(bold: true, fontSize: 11);
    final hdr = xl.CellStyle(
      bold: true,
      fontSize: 10,
      backgroundColorHex: XlTheme.headerBg,
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
    );

    void put(int col, int row, String text, [xl.CellStyle? style]) {
      final c = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
      c.value = xl.TextCellValue(text);
      if (style != null) c.cellStyle = style;
    }

    // The heading block sits over column C, exactly as the old sheet did.
    put(2, 0, _insName.toUpperCase(), bold);
    if (_insAddress.isNotEmpty) put(2, 1, _insAddress.toUpperCase(), bold);
    if (_insCity.isNotEmpty) put(2, 2, _insCity.toUpperCase(), bold);
    put(2, 3, _titleLine, bold);
    put(2, 4, _periodLine, bold);

    const headerRow = 6; // row 7 in Excel's own numbering
    final fields = _picked.map(_field).toList();
    put(0, headerRow, AppText.serialNo, hdr);
    for (var i = 0; i < fields.length; i++) {
      put(i + 1, headerRow, _fieldLabel(fields[i]), hdr);
      sheet.setColumnWidth(i + 1, fields[i].key == 'stuname' || fields[i].key == 'stuaddress' ? 28 : 16);
    }
    sheet.setColumnWidth(0, 7);

    var r = headerRow + 2; // one blank row under the header, as in the original
    for (var i = 0; i < rows.length; i++) {
      put(0, r, '${i + 1}');
      for (var c = 0; c < fields.length; c++) {
        put(c + 1, r, fields[c].read(rows[i]));
      }
      r++;
    }
    put(0, r + 1, 'Note: ${_withTc ? 'With' : 'Without'} TC Students', bold);

    final bytes = book.encode();
    if (bytes == null) throw Exception('Could not build the Excel file');
    await File(path).writeAsBytes(bytes);
    _snack('Admission register saved — ${rows.length} students.', AppColors.success);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pill tabs -- same convention as Master Data / Transfer Certificate.
        ListenableBuilder(
          listenable: _tabs,
          builder: (context, _) => Padding(
            padding: EdgeInsets.fromLTRB(16.w, 8, 16.w, 0),
            child: Row(children: [
              for (var i = 0; i < _tabLabels.length; i++) ...[
                PillTab(
                  icon: _tabIcons[i],
                  label: _tabLabels[i],
                  selected: _tabs.index == i,
                  onTap: () => _tabs.animateTo(i),
                ),
                if (i < _tabLabels.length - 1) SizedBox(width: PillTab.gap(context)),
              ],
            ]),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _registerTab(),
              // Its own screen still, just reached from here: the abstract
              // loads its own masters and owns its own filters.
              const AdmissionAbstractScreen(),
              // The old "Strength with Tc" sheet: opening, new, TC per section.
              const ClassStrengthScreen(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _registerTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return AppUI.empty(
        title: 'Could not load the master data.',
        why: _loadError,
        action: OutlinedButton.icon(
            onPressed: _loadMasters,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry')),
      );
    }

    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _modeSeg('New Admissions', 'NEW'),
            SizedBox(width: 8.w),
            _modeSeg('Active Students', 'ACTIVE'),
            SizedBox(width: 14.w),
            Expanded(
              child: Text(
                  _mode == 'NEW'
                      ? 'Admissions in a date range, with the columns you choose.'
                      : 'Everyone on the rolls this year, whenever they were admitted.',
                  style: AppUI.muted),
            ),
            _exportBtn(
              onPressed: () => _run(pdf: false),
              icon: Icons.table_chart_rounded,
              label: AppText.exportExcel,
            ),
            SizedBox(width: AppBtn.gap(context)),
            _exportBtn(
              onPressed: () => _run(pdf: true),
              icon: Icons.picture_as_pdf_rounded,
              label: AppText.exportPdf,
            ),
          ]),
          SizedBox(height: 12.h),
          _filters(),
          SizedBox(height: 12.h),
          Expanded(child: _pickers()),
          SizedBox(height: 12.h),
          Row(children: [
            Checkbox(
              value: _withTc,
              activeColor: AppColors.primary,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => setState(() => _withTc = v ?? false),
            ),
            Text('Include TC Students', style: AppUI.body),
            SizedBox(width: 8.w),
            Expanded(
              child: Text(
                _mode == 'ACTIVE'
                    // The roll list is built from students still active in
                    // this year's schema, and a TC takes a student off it --
                    // so there is nothing for this switch to include.
                    ? 'Not used for the roll list — a student holding a TC is '
                        'already off the rolls for this year.'
                    : (_withTc
                        ? 'Students who already hold a TC are included.'
                        : 'Students who already hold a TC are left out.'),
                style: AppUI.muted,
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _filters() {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(children: [
        Row(children: [
          // Dimmed and inert for the roll list -- a date window there would
          // read as a filter that is being applied, and it is not.
          Expanded(
            child: IgnorePointer(
              ignoring: _mode != 'NEW',
              child: Opacity(
                opacity: _mode == 'NEW' ? 1 : 0.45,
                child: _dateField('From Date', _from, (d) => setState(() => _from = d)),
              ),
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: IgnorePointer(
              ignoring: _mode != 'NEW',
              child: Opacity(
                opacity: _mode == 'NEW' ? 1 : 0.45,
                child: _dateField('To Date', _to, (d) => setState(() => _to = d)),
              ),
            ),
          ),
          // A school has no admission type.
          if (!isSchool) ...[
          SizedBox(width: 12.w),
          Expanded(
            flex: 2,
            child: _labeled('Admission Type', AppDropdownField<String?>(
              key: ValueKey('admtype-${_admType ?? ''}'),
              initialValue: _admTypes.contains(_admType) ? _admType : null,
              isExpanded: true,
              isDense: true,
              decoration: _dec('All Admission Types'),
              style: AppUI.fieldText(context),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All Admission Types')),
                ..._admTypes.map((e) =>
                    DropdownMenuItem<String?>(value: e, child: Text(e, overflow: TextOverflow.ellipsis))),
              ],
              onChanged: (v) => setState(() => _admType = v),
            )),
          ),
          ],
        ]),
        SizedBox(height: 10.h),
        Row(children: [
          Expanded(
            child: _labeled(schoolTerm('Course'), AppDropdownField<String?>(
              key: ValueKey('course-${_course ?? ''}'),
              initialValue: _courseNames.contains(_course) ? _course : null,
              isExpanded: true,
              isDense: true,
              decoration: _dec(schoolTerm('All Courses')),
              style: AppUI.fieldText(context),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text(schoolTerm('All Courses'))),
                ..._courseNames.map((e) => DropdownMenuItem<String?>(
                    value: e, child: Text(e, overflow: TextOverflow.ellipsis))),
              ],
              // A class of the previous course would contradict the new one, so
              // the narrower filter clears whenever the course changes.
              onChanged: (v) => setState(() {
                _course = v;
                _classes.clear();
              }),
            )),
          ),
          SizedBox(width: 12.w),
          Expanded(child: _labeled(schoolTerm('Class'), _classPicker())),
          SizedBox(width: 12.w),
          Expanded(
            child: _labeled('Sort By', AppDropdownField<String>(
              initialValue: _orderKey,
              isExpanded: true,
              isDense: true,
              decoration: _dec(''),
              style: AppUI.fieldText(context),
              items: [
                DropdownMenuItem(value: 'admno', child: Text(schoolTerm('Register No'))),
                const DropdownMenuItem(value: 'stuname', child: Text('Student Name')),
              ],
              onChanged: (v) => setState(() => _orderKey = v ?? 'admno'),
            )),
          ),
        ]),
      ]),
    );
  }

  /// The old dialog's two-list chooser: fields move between Available and
  /// Report List, and Up/Down set the printed order.
  Widget _pickers() {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        flex: 3,
        child: _listCard(
          title: 'Available Fields',
          count: _availableFields.length,
          child: _checkList(
            _availableFields.map((f) => (f.key, _fieldLabel(f))).toList(),
            checked: false,
            selected: _availSel,
            onSelect: (k) => setState(() => _availSel = k),
            onToggle: _addField,
          ),
        ),
      ),
      SizedBox(width: 8.w),
      Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        _moveBtn('»', 'Add every field', () => setState(() {
              for (final f in _availableFields) {
                _picked.add(f.key);
              }
              _availSel = null;
            })),
        _moveBtn('«', 'Remove every field', () => setState(() {
              _picked.clear();
              _pickedSel = null;
            })),
      ]),
      SizedBox(width: 8.w),
      Expanded(
        flex: 3,
        child: _listCard(
          title: 'Report List',
          count: _picked.length,
          trailing: _upDown(
            onUp: () => _move(_picked, _pickedSel, -1),
            onDown: () => _move(_picked, _pickedSel, 1),
          ),
          child: _checkList(
            _picked.map((k) => (k, _fieldLabel(_field(k)))).toList(),
            checked: true,
            selected: _pickedSel,
            onSelect: (k) => setState(() => _pickedSel = k),
            onToggle: _removeField,
          ),
        ),
      ),
    ]);
  }

  /// Tick in Available -> the field joins the Report list, in the order it
  /// was ticked. Up/Down on the right is what sets the printed order.
  void _addField(String key) => setState(() {
        if (!_picked.contains(key)) _picked.add(key);
        _availSel = null;
      });

  /// Untick in the Report list -> back to Available.
  void _removeField(String key) => setState(() {
        _picked.remove(key);
        if (_pickedSel == key) _pickedSel = null;
      });

  void _move(List<String> list, String? key, int delta) {
    if (key == null) return;
    final i = list.indexOf(key);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return;
    setState(() {
      list.removeAt(i);
      list.insert(j, key);
    });
  }

  // ── small pieces ──────────────────────────────────────────────────────────


  /// The app's export button: the themed solid button, sized through AppBtn
  /// so it matches every other button. Disabled while an export is running.
  Widget _exportBtn({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
  }) {
    return SizedBox(
      height: AppBtn.height(context),
      child: ElevatedButton.icon(
        onPressed: _running ? null : onPressed,
        icon: _running
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(icon, size: AppBtn.iconSize(context)),
        label: Text(label),
      ),
    );
  }

  InputDecoration _dec(String hint) => AppUI.field(context, hint);

  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppUI.fieldLabel(label),
          child,
        ],
      );

  Widget _dateField(String label, DateTime value, ValueChanged<DateTime> onPick) =>
      _labeled(
        label,
        InkWell(
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          onTap: () async {
            final p = await showDatePicker(
              context: context,
              initialDate: value,
              firstDate: DateTime(2000),
              lastDate: DateTime(DateTime.now().year + 5),
            );
            if (p != null) onPick(p);
          },
          child: InputDecorator(
            decoration: _dec('').copyWith(
              suffixIcon: Icon(Icons.calendar_today_outlined, size: 15.sp, color: AppColors.textSecondary),
            ),
            child: Text(_dmy(value), style: AppUI.fieldText(context)),
          ),
        ),
      );

  Widget _listCard({required String title, required int count, Widget? trailing, required Widget child}) =>
      Container(
        decoration: AppUI.card(),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          Container(
            decoration: AppUI.tableHeadBar,
            padding: EdgeInsets.fromLTRB(12.w, 7.h, 6.w, 7.h),
            child: Row(children: [
              Expanded(
                child: Text('$title · $count'.toUpperCase(), style: AppUI.tableHead),
              ),
              if (trailing != null) trailing,
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ]),
      );

  /// A list whose rows carry a checkbox. Ticking is the move: there is no
  /// separate "now press the arrow" step, so the tick and the field's side of
  /// the screen always agree.
  Widget _checkList(
    List<(String, String)> items, {
    required bool checked,
    required String? selected,
    required ValueChanged<String> onSelect,
    required ValueChanged<String> onToggle,
  }) {
    if (items.isEmpty) {
      return AppUI.empty(
        title: checked ? 'Select a field on the left to add it' : 'Every field is in the report',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (_, i) {
        final (key, label) = items[i];
        final on = key == selected;
        return InkWell(
          onTap: () => onSelect(key),
          onDoubleTap: () => onToggle(key),
          child: Container(
            width: double.infinity,
            color: on ? AppColors.primaryLight : Colors.transparent,
            padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 1.h),
            child: Row(children: [
              Checkbox(
                value: checked,
                activeColor: AppColors.primary,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (_) => onToggle(key),
              ),
              SizedBox(width: 2.w),
              Expanded(
                child: Text(label,
                    style: on
                        ? AppUI.cell.copyWith(fontWeight: FontWeight.w700, color: AppColors.primary)
                        : AppUI.cell),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _moveBtn(String glyph, String tip, VoidCallback onTap) => Padding(
        padding: EdgeInsets.symmetric(vertical: 4.h),
        child: Tooltip(
          message: tip,
          child: SizedBox(
            width: 44.w,
            child: OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
              child: Text(glyph, style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      );

  Widget _upDown({required VoidCallback onUp, required VoidCallback onDown}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Move up',
          onPressed: onUp,
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.arrow_upward, size: 16.sp, color: AppColors.textSecondary),
        ),
        IconButton(
          tooltip: 'Move down',
          onPressed: onDown,
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.arrow_downward, size: 16.sp, color: AppColors.textSecondary),
        ),
      ]);
}
