import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'package:provider/provider.dart';

import '../../services/staff_service.dart';
import '../../services/supabase_service.dart';
import '../../utils/auth_provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/mobile_rules.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/empty_state.dart';
import '../transport/transport_master_panel.dart';

/// STAFF DETAILS -- laid out like Student Details (user, 2026-11-23): a
/// column of groups on the left (All Staff, each designation, Not This Year,
/// Relieved), the group's staff on the right, and a full profile page for one
/// staff member (Back bar, section cards, experience edited on the same page
/// and saved with it). Staff are never deleted (user, 2026-11-23): one who
/// leaves is marked Relieved and stays on record.
///
/// Data: public.schstaff + public.staff_experience + <year>.staffmast through
/// the staff_* functions (school_staff_master.sql, setup part 89).
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

// ── values and helpers (top level: unit-tested) ─────────────────────────────
const kStaffGenders = <(Object?, String)>[('M', 'Male'), ('F', 'Female'), ('T', 'Transgender')];
const kStaffCareOf = <(Object?, String)>[(1, 'Father'), (2, 'Mother'), (3, 'Husband'), (4, 'Wife'), (5, 'Guardian')];
const kStaffTransport = <(Object?, String)>[('OWN', 'Own Transport'), ('BUS', 'School Bus')];

const kStaffBloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']; // as Admission Entry

// Offered even before anyone has typed them (live starts empty).
const _kReligions = ['Hindu', 'Muslim', 'Christian', 'Sikh', 'Jain', 'Buddhist'];
const _kNationalities = ['Indian'];

/// Mobile No.: as Admission Entry -- 10 digits, starting 6-9, not one digit
/// repeated (the server checks is_real_parent_mobile).
String? staffMobileProblem(String t) =>
    isRealMobile(t) ? null : 'Mobile No. must be a 10-digit mobile number starting with 6, 7, 8 or 9.';

/// 10 digits (user, 2026-11-24: "phone no set validity 10 digits").
String? staffPhoneProblem(String t) => RegExp(r'^\d{10}$').hasMatch(t) ? null : 'Phone No. must be 10 digits.';

String? staffEmailProblem(String t) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t) ? null : 'Enter a valid e-mail address.';

/// The staff login password follows the students' / parents' app password
/// (Set Password in the mobile app): 8+ characters, an uppercase letter, a
/// lowercase letter and a number.
String? staffPasswordProblem(String t) {
  if (t.length < 8 || !RegExp(r'[A-Z]').hasMatch(t) || !RegExp(r'[a-z]').hasMatch(t) || !RegExp(r'[0-9]').hasMatch(t)) {
    return 'The password needs at least 8 characters, with an uppercase letter, a lowercase letter and a number.';
  }
  return null;
}

/// [used] first (as the school typed them), then [defaults] not already
/// there, ignoring case; A-Z.
List<String> staffSuggestions(List<String> used, List<String> defaults) {
  final seen = <String, String>{};
  for (final v in [...used, ...defaults]) {
    final t = v.trim();
    if (t.isNotEmpty) seen.putIfAbsent(t.toLowerCase(), () => t);
  }
  return seen.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// What the profile form offers, from staff_lookups.
class StaffLookups {
  final String year;
  final List<(Object?, String)> communities;
  /// The school's Staff Designation list: (des_id, desname).
  final List<(int, String)> designations;

  /// Values already used on staff and admissions, for the suggestions.
  final List<String> religions, nationalities, cities;
  const StaffLookups({
    this.year = '',
    this.communities = const [],
    this.designations = const [],
    this.religions = const [],
    this.nationalities = const [],
    this.cities = const [],
  });
}

/// Up to two initials, for the avatar ("Lakshmi Narayanan R" -> "LN").
String staffInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(w[0])).toList();
  if (words.isEmpty) return '?';
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}

/// Whole months from [from] to [to], both days counted -- the server's
/// _staff_exp_length (PostgreSQL age(to + 1, from)). Null when a date is
/// missing or [to] is before [from].
int? staffMonths(String? from, String? to) {
  final a = DateTime.tryParse(from ?? ''), b = DateTime.tryParse(to ?? '');
  if (a == null || b == null || b.isBefore(a)) return null;
  final end = DateTime(b.year, b.month, b.day + 1);
  var y = end.year - a.year, m = end.month - a.month;
  if (end.day < a.day) m -= 1;
  if (m < 0) {
    y -= 1;
    m += 12;
  }
  return y * 12 + m;
}

/// "3 Years 2 Months", "1 Year", "" for under a month.
String staffSpanText(int months) {
  final y = months ~/ 12, m = months % 12;
  return [
    if (y > 0) '$y ${y == 1 ? 'Year' : 'Years'}',
    if (m > 0) '$m ${m == 1 ? 'Month' : 'Months'}',
  ].join(' ');
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Time in this school: joining date to the relieving date (or today).
String staffServiceText(Map<String, dynamic> r) {
  final end = r['staftermin'] == true && r['staftermindate'] != null ? '${r['staftermindate']}' : _iso(DateTime.now());
  final m = staffMonths(r['joindate'] as String?, end);
  return m == null ? '' : staffSpanText(m);
}

AppStatus _statusOf(Map<String, dynamic> r) {
  if (r['staftermin'] == true) return AppStatus.neutral;
  if (r['in_year'] != true) return AppStatus.warning;
  return r['is_active'] == true ? AppStatus.success : AppStatus.neutral;
}

String _statusText(Map<String, dynamic> r) {
  if (r['staftermin'] == true) return 'Relieved';
  if (r['in_year'] != true) return 'Not This Year';
  return r['is_active'] == true ? 'Active' : 'Inactive';
}

// Left-column groups
const _kAll = 'all';
const _kNotYear = 'notyear';
const _kRelieved = 'relieved';
const _kDes = 'des:'; // + designation ('' = none)

class _Group {
  final String key, title, icon;
  final int count;
  const _Group(this.key, this.title, this.icon, this.count);
}

class _StaffScreenState extends State<StaffScreen> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  String? _error;
  StaffLookups _lookups = const StaffLookups();
  String _group = _kAll;
  final _search = TextEditingController();

  /// The profile shown: null = the list; {} = a new staff member.
  Map<String, dynamic>? _open;
  int _openRev = 0;
  final _profile = GlobalKey<StaffProfileState>();

  @override
  void initState() {
    super.initState();
    _load();
    _loadLookups();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await StaffService.list();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        _error = null;
        if (!_groups().any((g) => g.key == _group)) _group = _kAll;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _loadLookups() async {
    try {
      final l = await StaffService.lookups();
      if (!mounted) return;
      setState(() => _lookups = StaffLookups(
            year: trText(l['year']),
            communities: [
              for (final c in (l['communities'] as List? ?? const []))
                if (c is Map) (trId(c['com_id']), trText(c['comname'])),
            ],
            designations: [
              for (final d in (l['designations'] as List? ?? const []))
                if (d is Map && trId(d['des_id']) != null) (trId(d['des_id'])!, trText(d['desname'])),
            ],
            religions: [for (final v in (l['religions'] as List? ?? const [])) trText(v)],
            nationalities: [for (final v in (l['nationalities'] as List? ?? const [])) trText(v)],
            cities: [for (final v in (l['cities'] as List? ?? const [])) trText(v)],
          ));
    } catch (_) {
      // the list shows the problem; the form still works without the lists
    }
  }

  bool _working(Map<String, dynamic> r) => r['staftermin'] != true;
  String _designation(Map<String, dynamic> r) => trText(r['designation']);

  List<_Group> _groups() {
    final working = _rows.where(_working).toList();
    final byDes = <String, int>{};
    for (final r in working) {
      byDes.update(_designation(r), (n) => n + 1, ifAbsent: () => 1);
    }
    final names = byDes.keys.where((d) => d.isNotEmpty).toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final notYear = working.where((r) => r['in_year'] != true).length;
    return [
      _Group(_kAll, 'All Staff', 'people', working.length),
      for (final d in names) _Group('$_kDes$d', d, 'briefcase', byDes[d]!),
      if ((byDes[''] ?? 0) > 0) _Group(_kDes, 'No Designation', 'user', byDes['']!),
      if (notYear > 0) _Group(_kNotYear, 'Not This Year', 'calendar-remove', notYear),
      _Group(_kRelieved, 'Relieved', 'logout', _rows.length - working.length),
    ];
  }

  List<Map<String, dynamic>> _groupRows() {
    final rows = switch (_group) {
      _kAll => _rows.where(_working),
      _kNotYear => _rows.where((r) => _working(r) && r['in_year'] != true),
      _kRelieved => _rows.where((r) => !_working(r)),
      _ => _rows.where((r) => _working(r) && _designation(r) == _group.substring(_kDes.length)),
    };
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return rows.toList();
    return rows
        .where((r) => [r['emp_code'], r['stafname'], r['shortname'], r['mobileno'], r['emailid'], r['designation']]
            .any((v) => trText(v).toLowerCase().contains(q)))
        .toList();
  }

  /// Leaves an open profile only once its unsaved changes are let go.
  Future<bool> _leaveProfile() async {
    if (_open == null) return true;
    return await _profile.currentState?.confirmLeave() ?? true;
  }

  Future<void> _pickGroup(String key) async {
    if (!await _leaveProfile() || !mounted) return;
    setState(() {
      _group = key;
      _open = null;
      _search.clear();
    });
  }

  Future<void> _openStaff(Map<String, dynamic>? r) async {
    if (!await _leaveProfile() || !mounted) return;
    setState(() {
      _open = r ?? <String, dynamic>{};
      _openRev++;
    });
  }

  Future<void> _saved(int id) async {
    await _load();
    if (!mounted) return;
    final row = _rows.where((r) => trId(r['staf_id']) == id).firstOrNull;
    setState(() {
      _open = row;
      _openRev++;
    });
    trSnack(context, 'Saved.', AppColors.success);
  }


  // ── left column ────────────────────────────────────────────────────────────
  Widget _rail() {
    final groups = _groups();
    final working = groups.first.count;
    return Container(
      decoration: AppUI.card(),
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 10.h),
          child: AppUI.cardHeader(icon: 'profile-2user', title: 'Staff Details', trailing: [_pill('$working')]),
        ),
        const Divider(height: 1, color: AppColors.divider),
        Expanded(
          child: _loading
              ? const AppLoading()
              : ListView(
                  padding: EdgeInsets.fromLTRB(12.w, 10.h, 10.w, 10.h),
                  children: [
                    for (final g in groups) ...[
                      if (g.key == _kNotYear || (g.key == _kRelieved && !groups.any((x) => x.key == _kNotYear)))
                        Padding(
                          padding: EdgeInsets.fromLTRB(4.w, 8.h, 0, 8.h),
                          child: Text('OTHERS', style: AppUI.caps),
                        ),
                      _groupTile(g),
                    ],
                  ],
                ),
        ),
      ]),
    );
  }

  Widget _pill(String text, {Color color = AppColors.accent}) => Container(
        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10.r)),
        child: Text(text, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _groupTile(_Group g) {
    const c = AppColors.accent;
    final selected = _group == g.key && _open == null;
    return Padding(
      padding: EdgeInsets.only(bottom: 6.h),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('staff-group-${g.key}'),
          borderRadius: BorderRadius.circular(10.r),
          onTap: () => _pickGroup(g.key),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
            decoration: BoxDecoration(
              color: selected ? c.withValues(alpha: 0.10) : Colors.white,
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(color: selected ? c.withValues(alpha: 0.55) : AppColors.border, width: selected ? 1.4 : 1),
            ),
            child: Row(children: [
              Container(
                width: 30.w,
                height: 30.h,
                decoration: BoxDecoration(color: c.withValues(alpha: selected ? 0.2 : 0.1), borderRadius: BorderRadius.circular(8.r)),
                child: Center(child: AppIcon(g.icon, size: 15, color: c)),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.sp, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? c : AppColors.textPrimary)),
                  Text(g.count == 1 ? '1 staff member' : '${g.count} staff', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                ]),
              ),
              _pill('${g.count}'),
              SizedBox(width: 6.w),
              const AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
            ]),
          ),
        ),
      ),
    );
  }

  // ── the group's list ───────────────────────────────────────────────────────
  _Group get _current => _groups().firstWhere((g) => g.key == _group, orElse: () => _groups().first);

  Widget _listCard() {
    final g = _current;
    final rows = _groupRows();
    final searching = _search.text.trim().isNotEmpty;
    return Container(
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: EdgeInsets.fromLTRB(12.w, 10.h, 16.w, 10.h),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.06),
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(AppUI.cardRadius), topRight: Radius.circular(AppUI.cardRadius)),
            border: const Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          child: Row(children: [
            AppIcon(g.icon, size: 14, color: AppColors.accent),
            SizedBox(width: 6.w),
            Flexible(
              child: Text(g.title,
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.accent)),
            ),
            SizedBox(width: 8.w),
            _pill(g.count == 1 ? '1 staff member' : '${g.count} staff'),
            if (_lookups.year.isNotEmpty) ...[
              SizedBox(width: 8.w),
              Text('AY ${_lookups.year}', style: AppUI.muted),
            ],
            const Spacer(),
            AppSearchField(
              controller: _search,
              hintText: 'Search by name, code or mobile',
              onChanged: (_) => setState(() {}),
              width: 260.w,
            ),
            SizedBox(width: 12.w),
            ElevatedButton.icon(
              key: const ValueKey('staff-add'),
              onPressed: _loading || _error != null ? null : () => _openStaff(null),
              style: AppUI.primary(context),
              icon: AppIcon('add-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
              label: const Text('Add Staff Member'),
            ),
          ]),
        ),
        Expanded(
          child: _loading
              ? const AppLoading()
              : _error != null
                  ? AppUI.empty(
                      title: 'Could not load the staff',
                      why: _error,
                      icon: 'info-circle',
                      action: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });
                          _load();
                        },
                        style: AppUI.secondary(context),
                        child: const Text('Retry'),
                      ),
                    )
                  : AppVerticalScrollbar(
                      header: Container(
                        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                        color: AppColors.tableHeadBg,
                        child: Row(children: [
                          Expanded(flex: 1, child: Text('S. NO.', style: AppUI.tableHead)),
                          Expanded(flex: 2, child: Text('EMPLOYEE CODE', style: AppUI.tableHead)),
                          Expanded(flex: 4, child: Text('STAFF NAME', style: AppUI.tableHead)),
                          Expanded(flex: 3, child: Text('DESIGNATION', style: AppUI.tableHead)),
                          Expanded(flex: 2, child: Text('MOBILE NO.', style: AppUI.tableHead)),
                          Expanded(flex: 2, child: Text('DATE OF JOINING', style: AppUI.tableHead)),
                          Expanded(flex: 2, child: Text('IN SERVICE', style: AppUI.tableHead)),
                          Expanded(flex: 2, child: Text('STATUS', style: AppUI.tableHead)),
                          Expanded(flex: 1, child: Text('VIEW', textAlign: TextAlign.right, style: AppUI.tableHead)),
                        ]),
                      ),
                      builder: (context, controller) => rows.isEmpty
                          ? AppUI.empty(
                              icon: 'profile-2user',
                              title: searching ? 'No staff member found' : (_rows.isEmpty ? 'No staff yet' : 'No staff here'),
                              why: searching
                                  ? 'No staff member matches your search.'
                                  : (_rows.isEmpty ? 'Add your teachers and other staff with Add Staff Member.' : 'No staff member is in this group.'),
                            )
                          : ListView.separated(
                              controller: controller,
                              padding: EdgeInsets.zero,
                              itemCount: rows.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                              itemBuilder: (context, i) => _row(rows[i], i),
                            ),
                    ),
        ),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r, int i) {
    final name = trText(r['stafname']);
    final code = trText(r['emp_code']);
    final des = _designation(r);
    return InkWell(
      onTap: () => _openStaff(r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
        color: i.isEven ? Colors.white : AppColors.surface,
        child: Row(children: [
          Expanded(flex: 1, child: Text('${i + 1}', style: AppUI.cell)),
          Expanded(
            flex: 2,
            child: Text(code.isEmpty ? '-' : code, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
          ),
          Expanded(
            flex: 4,
            child: Row(children: [
              CircleAvatar(
                radius: 15.r,
                backgroundColor: AppColors.primarySoft,
                child: Text(staffInitials(name), style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
              ),
              SizedBox(width: 10.w),
              Expanded(child: Text(name, style: AppUI.cell, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          Expanded(flex: 3, child: Text(des.isEmpty ? '-' : des, style: AppUI.cell, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 2, child: Text(trText(r['mobileno']), style: AppUI.cell)),
          Expanded(flex: 2, child: Text(r['joindate'] == null ? '-' : formatDate(r['joindate'] as String?), style: AppUI.cell)),
          Expanded(flex: 2, child: Text(staffServiceText(r).isEmpty ? '-' : staffServiceText(r), style: AppUI.cell)),
          Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: AppUI.chip(_statusText(r), _statusOf(r)))),
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 30.w,
                height: 30.w,
                decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8.r)),
                child: const Center(child: AppIcon('user', size: 16, color: AppColors.accent)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 260.w, child: _rail()),
      SizedBox(width: AppUI.gap),
      Expanded(
        child: open == null
            ? _listCard()
            : StaffProfile(
                key: _profile,
                rev: _openRev,
                staff: open.isEmpty ? null : open,
                lookups: _lookups,
                onBack: () => setState(() => _open = null),
                onSaved: _saved,
                onLookupsChanged: _loadLookups,
              ),
      ),
    ]);
  }
}

// ── one staff member ─────────────────────────────────────────────────────────
/// One row of the Experience card.
class _ExpRow {
  final int? id;
  final TextEditingController school;
  final TextEditingController length;
  String? from, to;

  /// The length follows the dates until someone types their own.
  bool autoLength;
  _ExpRow({this.id, String school = '', String length = '', this.from, this.to, this.autoLength = true})
      : school = TextEditingController(text: school),
        length = TextEditingController(text: length);

  bool get isBlank => school.text.trim().isEmpty && from == null && to == null && length.text.trim().isEmpty;

  void dispose() {
    school.dispose();
    length.dispose();
  }
}

/// The full profile page of one staff member ([staff] null: a new one), saved
/// in one go -- details, this year's row and the experience list.
class StaffProfile extends StatefulWidget {
  final Map<String, dynamic>? staff;
  final StaffLookups lookups;
  final VoidCallback onBack;
  final ValueChanged<int> onSaved;

  /// Reloads [lookups] (e.g. after a designation was added).
  final Future<void> Function()? onLookupsChanged;

  /// Changes when the same record is opened again (e.g. after a save), so
  /// the forms start from the saved values.
  final int rev;
  const StaffProfile({
    super.key,
    required this.staff,
    required this.lookups,
    required this.onBack,
    required this.onSaved,
    this.onLookupsChanged,
    this.rev = 0,
  });

  @override
  State<StaffProfile> createState() => StaffProfileState();
}

class StaffProfileState extends State<StaffProfile> {
  // New keys for each record opened: a GlobalKey keeps its form's state, and
  // the forms must start from the record's (saved) values.
  var _personal = GlobalKey<TrFormBodyState>();
  var _contact = GlobalKey<TrFormBodyState>();
  var _job = GlobalKey<TrFormBodyState>();
  var _leaving = GlobalKey<TrFormBodyState>();

  final List<_ExpRow> _exp = [];
  bool _expLoading = false;
  String? _expError;
  bool _dirty = false, _saving = false;

  int? get _id => trId(widget.staff?['staf_id']);
  Map<String, dynamic> get _initial =>
      widget.staff ?? const {'is_active': true, 'transportreq': 'OWN', 'staftermin': false, 'nationality': 'Indian'};

  @override
  void initState() {
    super.initState();
    _loadExperience();
  }

  @override
  void didUpdateWidget(StaffProfile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rev != widget.rev) {
      _dirty = false;
      _personal = GlobalKey<TrFormBodyState>();
      _contact = GlobalKey<TrFormBodyState>();
      _job = GlobalKey<TrFormBodyState>();
      _leaving = GlobalKey<TrFormBodyState>();
      _loadExperience();
    }
  }

  @override
  void dispose() {
    for (final e in _exp) {
      e.dispose();
    }
    super.dispose();
  }

  Future<void> _loadExperience() async {
    for (final e in _exp) {
      e.dispose();
    }
    _exp.clear();
    final id = _id;
    if (id == null) {
      setState(() {
        _expLoading = false;
        _expError = null;
      });
      return;
    }
    setState(() {
      _expLoading = true;
      _expError = null;
    });
    try {
      final rows = await StaffService.experience(id);
      if (!mounted) return;
      setState(() {
        for (final r in rows) {
          final from = r['experiencefrom'] as String?, to = r['experienceto'] as String?;
          final len = trText(r['experienceyears']);
          final m = staffMonths(from, to);
          _exp.add(_ExpRow(
            id: trId(r['staffexp_id']),
            school: trText(r['schoolname']),
            length: len,
            from: from,
            to: to,
            autoLength: len.isEmpty || (m != null && len == staffSpanText(m)),
          ));
        }
        _expLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _expLoading = false;
        _expError = friendlyError(e);
      });
    }
  }

  void _changed() => _dirty = true;

  /// True when there is nothing unsaved, or the user lets it go.
  Future<bool> confirmLeave() async {
    if (!_dirty || _saving) return !_saving;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('The changes to this staff member are not saved yet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Editing')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _back() async {
    if (await confirmLeave() && mounted) widget.onBack();
  }

  Future<void> _save() async {
    final parts = [_personal, _contact, _job, _leaving].map((k) => k.currentState?.collect()).toList();
    if (parts.any((p) => p == null)) return;
    final exp = [for (final e in _exp) if (!e.isBlank) e];
    if (exp.any((e) => e.school.text.trim().isEmpty)) {
      trSnack(context, 'Experience: enter the school name, or remove the row.', AppColors.warning);
      return;
    }
    final row = <String, dynamic>{
      for (final p in parts) ...p!,
      if (_id != null) 'staf_id': _id,
      // left out when the list could not be loaded: the server keeps it as it is
      if (_expError == null && !_expLoading)
        'experiences': [
          for (final e in exp)
            {
              if (e.id != null) 'staffexp_id': e.id,
              'schoolname': e.school.text.trim(),
              'experiencefrom': e.from,
              'experienceto': e.to,
              'experienceyears': e.length.text.trim(),
            },
        ],
    };
    setState(() => _saving = true);
    try {
      final saved = await StaffService.save(row) ?? _id;
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      if (saved != null) widget.onSaved(saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      trSnack(context, AppText.couldNot('save', friendlyError(e)), AppColors.error);
    }
  }

  /// Adds a designation to the school's Staff Designation list (as Users does)
  /// and returns its name, which the Designation field then shows.
  Future<Object?> _addDesignation() async {
    final name = TextEditingController();
    int? reportsTo;
    String? error;
    var saving = false;
    final added = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          Future<void> add() async {
            final n = name.text.trim();
            if (n.isEmpty) return setD(() => error = 'Enter the designation name.');
            if (widget.lookups.designations.any((d) => d.$2.toLowerCase() == n.toLowerCase())) {
              return setD(() => error = '$n is already on the list.');
            }
            final insId = ctx.read<AuthProvider>().insId;
            if (insId == null) return setD(() => error = 'Sign in again to add a designation.');
            setD(() {
              saving = true;
              error = null;
            });
            try {
              await SupabaseService.createDesignation({'ins_id': insId, 'desname': n, 'desrepto': reportsTo, 'activestatus': 1});
              await widget.onLookupsChanged?.call();
              if (ctx.mounted) Navigator.pop(ctx, n);
            } catch (e) {
              setD(() {
                saving = false;
                error = AppText.couldNot('add the designation', friendlyError(e));
              });
            }
          }

          return AlertDialog(
            backgroundColor: AppColors.card,
            title: AppUI.cardHeader(icon: 'personalcard', title: 'Add Designation'),
            content: SizedBox(
              width: 380,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AppUI.fieldLabel('Designation Name', required: true),
                TextField(
                  controller: name,
                  autofocus: true,
                  enabled: !saving,
                  // the year's staff list keeps 30 characters (staffmast.designation)
                  inputFormatters: [LengthLimitingTextInputFormatter(30)],
                  textCapitalization: TextCapitalization.words,
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, '', filled: name.text.trim().isNotEmpty)
                      .copyWith(hintText: 'e.g. Teacher', errorText: error),
                  onChanged: (_) => setD(() => error = null),
                  onSubmitted: (_) => add(),
                ),
                SizedBox(height: 14.h),
                AppUI.fieldLabel('Reports To'),
                AppDropdownField<int?>(
                  initialValue: reportsTo,
                  isExpanded: true,
                  dropdownColor: AppColors.card,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, '', filled: reportsTo != null),
                  items: [
                    DropdownMenuItem<int?>(value: null, child: Text('None', style: AppUI.muted)),
                    for (final d in widget.lookups.designations) DropdownMenuItem<int?>(value: d.$1, child: Text(d.$2)),
                  ],
                  onChanged: saving ? null : (v) => setD(() => reportsTo = v),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: saving ? null : () => Navigator.pop(ctx), child: const Text(AppText.cancel)),
              ElevatedButton.icon(
                onPressed: saving ? null : add,
                style: AppUI.primary(context),
                icon: saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onPrimary))
                    : AppIcon('add-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
                label: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
    name.dispose();
    if (added != null) _changed();
    return added;
  }

  // ── experience rows ────────────────────────────────────────────────────────
  void _setDate(_ExpRow e, bool isFrom, String? iso) {
    setState(() {
      if (isFrom) {
        e.from = iso;
      } else {
        e.to = iso;
      }
      if (e.autoLength) {
        final m = staffMonths(e.from, e.to);
        e.length.text = m == null ? '' : staffSpanText(m);
      }
    });
    _changed();
  }

  Future<void> _pickExpDate(_ExpRow e, bool isFrom) async {
    final now = DateTime.now();
    final current = DateTime.tryParse((isFrom ? e.from : e.to) ?? '');
    final picked = await trPickDate(
      context,
      initialDate: current ?? DateTime.tryParse((isFrom ? e.to : e.from) ?? '') ?? now,
      firstDate: DateTime(1950),
      lastDate: DateTime(now.year + 1),
      helpText: isFrom ? 'From' : 'To',
    );
    if (picked != null && mounted) _setDate(e, isFrom, _iso(picked));
  }

  Widget _dateBox(_ExpRow e, bool isFrom) {
    final iso = isFrom ? e.from : e.to;
    final busy = _saving;
    return InkWell(
      onTap: busy ? null : () => _pickExpDate(e, isFrom),
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: InputDecorator(
        decoration: AppUI.field(
          context,
          '',
          filled: iso != null,
          leadingIcon: 'calendar',
          suffix: iso == null || busy
              ? null
              : IconButton(
                  tooltip: AppText.clear,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => _setDate(e, isFrom, null),
                ),
        ),
        child: Text(iso == null ? AppText.dateHint : formatDate(iso),
            overflow: TextOverflow.ellipsis, style: iso == null ? AppUI.muted : AppUI.fieldText(context)),
      ),
    );
  }

  Widget _experience() {
    final busy = _saving;
    if (_expLoading) return Padding(padding: EdgeInsets.all(16.w), child: const AppLoading());
    if (_expError != null) {
      return AppUI.empty(
        title: 'Could not load the experience',
        why: _expError,
        icon: 'info-circle',
        action: OutlinedButton(onPressed: _loadExperience, style: AppUI.secondary(context), child: const Text('Retry')),
      );
    }
    final total = _exp.fold<int>(0, (s, e) => s + (staffMonths(e.from, e.to) ?? 0));
    return LayoutBuilder(builder: (context, c) {
      // One line per school when there is room for the dates in full
      // (DD-MM-YYYY with its icon and clear button); two lines otherwise.
      const dateW = 190.0, lengthW = 170.0, delW = 40.0, gap = 10.0;
      final oneLine = c.maxWidth >= 240 + 2 * dateW + lengthW + delW + 4 * gap;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_exp.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 10.h),
            child: Text('No earlier schools added. Use Add School for each place this staff member worked before.', style: AppUI.muted),
          )
        else if (oneLine) ...[
          Row(children: [
            Expanded(child: Text('SCHOOL NAME', style: AppUI.tableHead)),
            const SizedBox(width: gap),
            SizedBox(width: dateW, child: Text('FROM', style: AppUI.tableHead)),
            const SizedBox(width: gap),
            SizedBox(width: dateW, child: Text('TO', style: AppUI.tableHead)),
            const SizedBox(width: gap),
            SizedBox(width: lengthW, child: Text('DURATION', style: AppUI.tableHead)),
            const SizedBox(width: gap + delW),
          ]),
          SizedBox(height: 6.h),
          for (final e in _exp)
            Padding(
              padding: EdgeInsets.only(bottom: 8.h),
              child: Row(children: [
                Expanded(child: _schoolField(e, busy)),
                const SizedBox(width: gap),
                SizedBox(width: dateW, child: _dateBox(e, true)),
                const SizedBox(width: gap),
                SizedBox(width: dateW, child: _dateBox(e, false)),
                const SizedBox(width: gap),
                SizedBox(width: lengthW, child: _lengthField(e, busy)),
                const SizedBox(width: gap),
                SizedBox(width: delW, child: _removeButton(e, busy)),
              ]),
            ),
        ] else
          for (final e in _exp)
            Container(
              margin: EdgeInsets.only(bottom: 10.h),
              padding: EdgeInsets.fromLTRB(12.w, 10.h, 6.w, 12.h),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AppUI.fieldLabel('School Name'),
                Row(children: [
                  Expanded(child: _schoolField(e, busy)),
                  const SizedBox(width: 6),
                  SizedBox(width: delW, child: _removeButton(e, busy)),
                ]),
                SizedBox(height: 10.h),
                Padding(
                  padding: const EdgeInsets.only(right: delW + 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [AppUI.fieldLabel('From'), _dateBox(e, true)])),
                    const SizedBox(width: gap),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [AppUI.fieldLabel('To'), _dateBox(e, false)])),
                    const SizedBox(width: gap),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [AppUI.fieldLabel('Duration'), _lengthField(e, busy)])),
                  ]),
                ),
              ]),
            ),
      SizedBox(height: 4.h),
      Row(children: [
        OutlinedButton.icon(
          key: const ValueKey('staff-exp-add'),
          onPressed: busy
              ? null
              : () {
                  setState(() => _exp.add(_ExpRow()));
                  _changed();
                },
          style: AppUI.secondary(context),
          icon: AppIcon('add-circle', size: AppBtn.iconSize(context), color: AppColors.primary),
          label: const Text('Add School'),
        ),
        const Spacer(),
        if (total > 0) Text('Total before joining: ${staffSpanText(total)}', style: AppUI.label),
      ]),
      ]);
    });
  }

  Widget _schoolField(_ExpRow e, bool busy) => TextField(
        controller: e.school,
        enabled: !busy,
        inputFormatters: [LengthLimitingTextInputFormatter(50)],
        textCapitalization: TextCapitalization.words,
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', filled: e.school.text.trim().isNotEmpty).copyWith(hintText: 'School name'),
        onChanged: (_) {
          setState(() {});
          _changed();
        },
      );

  Widget _lengthField(_ExpRow e, bool busy) => TextField(
        controller: e.length,
        enabled: !busy,
        inputFormatters: [LengthLimitingTextInputFormatter(30)],
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, '', filled: e.length.text.trim().isNotEmpty).copyWith(hintText: 'From the dates'),
        onChanged: (v) {
          // typing a length of one's own stops it following the dates; clearing it starts again
          setState(() => e.autoLength = v.trim().isEmpty);
          _changed();
        },
      );

  Widget _removeButton(_ExpRow e, bool busy) => IconButton(
        tooltip: AppText.deleteRow,
        visualDensity: VisualDensity.compact,
        onPressed: busy
            ? null
            : () {
                setState(() {
                  _exp.remove(e);
                  e.dispose();
                });
                _changed();
              },
        icon: const AppIcon('trash', size: 16, color: AppColors.error),
      );

  // ── page parts ─────────────────────────────────────────────────────────────
  Widget _bar() {
    final s = widget.staff;
    final busy = _saving;
    final name = s == null ? 'New Staff Member' : trText(s['stafname']);
    final code = trText(s?['emp_code']);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
      decoration: AppUI.card(),
      child: Row(children: [
        InkWell(
          key: const ValueKey('staff-back'),
          onTap: busy ? null : _back,
          borderRadius: BorderRadius.circular(8.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
            decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppUI.controlRadius)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
              SizedBox(width: 6.w),
              Text('Back', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: Colors.white)),
            ]),
          ),
        ),
        SizedBox(width: 12.w),
        Container(width: 1, height: 18, color: AppColors.border),
        SizedBox(width: 12.w),
        Text('Staff Details', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
        SizedBox(width: 6.w),
        const AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
        SizedBox(width: 6.w),
        Flexible(
          child: Text(name,
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        ),
        if (code.isNotEmpty) ...[
          SizedBox(width: 6.w),
          Text('($code)', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
        ],
        const Spacer(),
        AppUI.requiredNote(),
        SizedBox(width: 14.w),
        ElevatedButton.icon(
          key: const ValueKey('staff-save'),
          onPressed: busy ? null : _save,
          style: AppUI.primary(context),
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onPrimary))
              : AppIcon('tick-circle', size: AppBtn.iconSize(context), color: AppColors.onPrimary),
          label: const Text(AppText.save),
        ),
      ]),
    );
  }

  Widget _fact(String label, String value) => Padding(
        padding: EdgeInsets.only(left: 28.w),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label.toUpperCase(), style: AppUI.caps),
          SizedBox(height: 4.h),
          Text(value.isEmpty ? '-' : value, style: AppUI.body.copyWith(fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _header() {
    final s = widget.staff;
    final name = s == null ? '' : trText(s['stafname']);
    final des = trText(s?['designation']);
    final code = trText(s?['emp_code']);
    final service = s == null ? '' : staffServiceText(s);
    final before = _exp.fold<int>(0, (t, e) => t + (staffMonths(e.from, e.to) ?? 0));
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Row(children: [
        Container(
          width: 64.w,
          height: 64.w,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.25), width: 2),
          ),
          alignment: Alignment.center,
          child: s == null
              ? const AppIcon('user-add', size: 26, color: AppColors.primary)
              : Text(staffInitials(name), style: AppFonts.heading(size: 22.sp, weight: FontWeight.w700, color: AppColors.primary)),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s == null ? 'New Staff Member' : name, overflow: TextOverflow.ellipsis, style: AppUI.cardTitle),
            SizedBox(height: 4.h),
            Text(
              s == null
                  ? 'Fill in the details below, then Save.'
                  : [if (des.isNotEmpty) des, if (code.isNotEmpty) 'Employee Code $code'].join('  ·  '),
              style: AppUI.muted,
            ),
            if (s != null) ...[
              SizedBox(height: 8.h),
              Wrap(spacing: 8.w, runSpacing: 6.h, children: [
                AppUI.chip(_statusText(s), _statusOf(s)),
                if (service.isNotEmpty) AppUI.chip('In service $service', AppStatus.info),
                if (before > 0) AppUI.chip('Before joining ${staffSpanText(before)}', AppStatus.neutral),
              ]),
            ],
          ]),
        ),
        if (s != null) ...[
          _fact('Mobile No.', trText(s['mobileno'])),
          _fact('E-mail', trText(s['emailid'])),
          _fact('Date of Joining', s['joindate'] == null ? '' : formatDate(s['joindate'] as String?)),
        ],
      ]),
    );
  }

  Widget _card({required String icon, required String title, String? subtitle, List<Widget> trailing = const [], required Widget child}) =>
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(AppUI.cardPad),
        decoration: AppUI.card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppUI.cardHeader(icon: icon, title: title, subtitle: subtitle, trailing: trailing),
          SizedBox(height: 16.h),
          child,
        ]),
      );

  Widget _form(GlobalKey<TrFormBodyState> key, List<TrField> fields) => TrFormBody(
        key: key,
        fields: fields,
        initial: _initial,
        enabled: !_saving,
        onChanged: (_) => _changed(),
      );

  @override
  Widget build(BuildContext context) {
    final year = widget.lookups.year.isEmpty ? 'This Year' : widget.lookups.year;
    final designations = widget.lookups.designations;
    final personal = _card(
      icon: 'user',
      title: 'Personal Details',
      child: _form(_personal, [
        const TrField('stafname', 'Staff Name', required: true, maxLength: 50, full: true),
        const TrField('shortname', 'Short Name', required: true, maxLength: 30),
        const TrField('gender', 'Gender', kind: TrKind.choice, required: true, options: kStaffGenders, hint: 'Select gender'),
        const TrField('dob', AppText.dateOfBirth, kind: TrKind.date, required: true),
        TrField('bloodgroup', 'Blood Group', kind: TrKind.choice, hint: 'Select blood group',
            optionsFor: (v) {
              final cur = trText(v['bloodgroup']);
              return [
                for (final b in kStaffBloodGroups) (b, b),
                if (cur.isNotEmpty && !kStaffBloodGroups.contains(cur)) (cur, cur),
              ];
            }),
        const TrField('stafcare', 'Care Of', kind: TrKind.choice, options: kStaffCareOf, hint: 'Select relation'),
        TrField('stafcarename', 'Care Of Name', maxLength: 50, visibleWhen: (v) => v['stafcare'] != null),
        TrField('religion', 'Religion', kind: TrKind.suggest, maxLength: 30, hint: 'Type or select a religion',
            suggestions: staffSuggestions(widget.lookups.religions, _kReligions)),
        TrField('community_id', 'Community', kind: TrKind.choice, options: widget.lookups.communities, hint: 'Select community'),
        TrField('nationality', 'Nationality', kind: TrKind.suggest, maxLength: 30, hint: 'Type or select a nationality',
            suggestions: staffSuggestions(widget.lookups.nationalities, _kNationalities)),
      ]),
    );
    final contact = _card(
      icon: 'call',
      title: 'Contact',
      child: _form(_contact, [
        // as Admission Entry: digits only, the mobile exactly 10 (6-9 first)
        const TrField('mobileno', 'Mobile No.', kind: TrKind.digits, required: true, maxLength: 10,
            hint: '10-digit mobile number', check: staffMobileProblem),
        const TrField('phoneno', 'Phone No.', kind: TrKind.digits, maxLength: 10, hint: '10 digits', check: staffPhoneProblem),
        const TrField('emailid', 'E-mail', required: true, maxLength: 50, hint: 'name@example.com', check: staffEmailProblem),
        TrField('city', 'City', kind: TrKind.suggest, maxLength: 50, hint: 'Type or select a city',
            suggestions: staffSuggestions(widget.lookups.cities, const [])),
        const TrField('address', 'Address', kind: TrKind.multiline, full: true, maxLength: 100),
      ]),
    );
    final job = _card(
      icon: 'briefcase',
      title: 'Employment',
      subtitle: 'Employee code, designation and transport for $year.',
      child: _form(_job, [
        const TrField('emp_code', 'Employee Code', kind: TrKind.upper, required: true, maxLength: 30),
        // From the school's Staff Designation list (the same list as Users);
        // a designation saved before that, not on the list, still shows.
        TrField('designation', 'Designation', kind: TrKind.choice, hint: 'Select designation',
            optionsFor: (v) {
              final cur = trText(v['designation']);
              return [
                for (final d in designations) (d.$2, d.$2),
                if (cur.isNotEmpty && !designations.any((d) => d.$2 == cur)) (cur, cur),
              ];
            },
            onAdd: _addDesignation,
            addLabel: 'Add New Designation'),
        const TrField('joindate', 'Date of Joining', kind: TrKind.date, required: true),
        const TrField('confirmationdate', 'Confirmation Date', kind: TrKind.date),
        const TrField('qualification', 'Qualification', maxLength: 30, hint: 'e.g. M.Sc., B.Ed.'),
        const TrField('transportreq', 'Transport', kind: TrKind.choice, required: true, options: kStaffTransport, hint: 'Select transport'),
        const TrField('is_active', 'Active This Year', kind: TrKind.toggle),
        const TrField('experience', 'Experience Summary', kind: TrKind.multiline, full: true, maxLength: 500,
            hint: 'A line or two; add each earlier school under Experience'),
      ]),
    );
    final experience = _card(
      icon: 'award',
      title: 'Experience',
      subtitle: 'Schools worked at before joining. Saved with the staff member.',
      child: _experience(),
    );
    final leaving = _card(
      icon: 'lock-1',
      title: 'Leaving & Login',
      child: _form(_leaving, [
        const TrField('staftermin', 'Relieved', kind: TrKind.toggle),
        TrField('staftermindate', 'Relieving Date', kind: TrKind.date, visibleWhen: (v) => v['staftermin'] == true),
        // the staff login: the same rules as the students' / parents' app password
        TrField('password', 'Password', kind: TrKind.password, maxLength: 60, full: true, check: staffPasswordProblem,
            hint: widget.staff?['has_password'] == true
                ? 'A password is set; type a new one to change it'
                : '8+ characters, with upper- and lower-case letters and a number'),
      ]),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _bar(),
      SizedBox(height: 8.h),
      Expanded(
        child: SingleChildScrollView(
          child: LayoutBuilder(builder: (context, c) {
            final gap = AppUI.gap;
            final wide = c.maxWidth >= 980;
            final cards = wide
                // Experience across the full width: its dates need the room
                ? Column(children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Column(children: [personal, SizedBox(height: gap), contact])),
                      SizedBox(width: gap),
                      Expanded(child: Column(children: [job, SizedBox(height: gap), leaving])),
                    ]),
                    SizedBox(height: gap),
                    experience,
                  ])
                : Column(children: [
                    personal,
                    SizedBox(height: gap),
                    contact,
                    SizedBox(height: gap),
                    job,
                    SizedBox(height: gap),
                    experience,
                    SizedBox(height: gap),
                    leaving,
                  ]);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _header(),
              SizedBox(height: gap),
              cards,
              SizedBox(height: gap),
            ]);
          }),
        ),
      ),
    ]);
  }
}
