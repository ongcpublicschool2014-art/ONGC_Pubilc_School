import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../utils/app_theme.dart';
import 'package:provider/provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../utils/auth_provider.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';

/// Student Fee Definition — lists every fee for a student and lets the cashier
/// define which ones apply. It shows two sets (mirrors the legacy VB feedefine):
///   * the student's EXISTING demands (feedemand), and
///   * class fees the student doesn't have yet (classfeedemand), shown unticked.
/// On Save: ticking an available fee INSERTs a demand; unticking an existing one
/// (with no collection) DELETEs it; editing a ticked fee's amount UPDATEs it.
/// Rows that already carry a collection or a concession are locked (the amount
/// stays editable; they just can't be un-ticked). Returns true if saved.
class StudentFeeDefinitionDialog extends StatefulWidget {
  final int insId;
  final String stuAdmno;
  final String stuName;
  final String admName;
  const StudentFeeDefinitionDialog({
    super.key,
    required this.insId,
    required this.stuAdmno,
    required this.stuName,
    required this.admName,
  });

  @override
  State<StudentFeeDefinitionDialog> createState() => _StudentFeeDefinitionDialogState();
}

class _DefRow {
  final int demId;         // 0 for an available (not-yet-created) fee
  final int? cfId;         // classfeedemand template id (needed to insert)
  final bool isNew;        // true = available fee → INSERT a demand on save
  final String sem;
  final String cls;
  final String feeType;
  final String admType;    // admission type this fee applies to
  final double concession;
  final double paidAmount; // already collected on this demand
  final double balanceDue; // stored outstanding (already reflects payments)
  final double origAmount; // original feeamount, to detect edits
  final bool origOpted;    // opted state at load, to detect a deliberate opt-out
  final bool locked;       // paidAmount>0 or conamount>0 → can't be un-ticked
  // Template fields carried for the direct-insert fallback (when no session RPC).
  final int? claId, semId, feeId;
  final String? dueDate;
  final TextEditingController amountCtrl;
  bool opted;
  _DefRow({
    required this.demId,
    required this.cfId,
    required this.isNew,
    required this.sem,
    required this.cls,
    required this.feeType,
    required this.admType,
    required double amount,
    required this.concession,
    required this.paidAmount,
    required this.balanceDue,
    required this.opted,
    required this.origOpted,
    required this.locked,
    this.claId,
    this.semId,
    this.feeId,
    this.dueDate,
  })  : origAmount = amount,
        amountCtrl = TextEditingController(
            text: amount.abs() < 0.005 ? '' : amount.toStringAsFixed(2));

  double get amount => double.tryParse(amountCtrl.text.trim()) ?? 0;

  /// True once the cashier edits the fee amount.
  bool get amountChanged => (amount - origAmount).abs() >= 0.005;

  double get balance {
    // New/edited rows recompute for the current amount (still crediting anything
    // already paid); an untouched existing row shows its stored outstanding.
    final b = (isNew || amountChanged) ? (amount - concession - paidAmount) : balanceDue;
    return b > 0 ? b : 0;
  }

  void dispose() => amountCtrl.dispose();
}

class _StudentFeeDefinitionDialogState extends State<StudentFeeDefinitionDialog> {
  List<_DefRow> _rows = [];
  String? _sem; // left-list selected semester
  bool _loading = true;
  bool _saving = false;
  String? _error; // inline validation message shown inside the dialog
  String? _info;  // inline confirmation shown after a save, dialog stays open

  /// Set once anything has been written. Save no longer closes the dialog, so
  /// this is what the dialog returns on close — the caller reloads its demands
  /// only if something actually changed.
  bool _savedAny = false;

  // Student record — needed to build a new demand (and the insert fallback).
  int? _stuId;
  String _stuclass = '', _inscode = '', _yrlabel = '', _courname = '', _stuAdmName = '';
  /// students.stuphoto, for the header avatar only.
  String? _stuPhoto;
  /// students.hostel = 'Y'. Decides whether fee groups marked HOSTELLERS ONLY
  /// are offered at all: a day scholar was being shown MESS FEE because the
  /// available-fee list was filtered by admission type and nothing else.
  bool _isHosteller = false;
  /// fg_id -> hostellers_only, from feegroup. The rule lives on the group so
  /// it can be seen and changed, rather than being guessed from its name --
  /// a name test also misses "MA" (mess advance).
  final Map<int, bool> _fgHostelOnly = {};
  /// Fee type name -> its fee group, for grouping the list and applying the
  /// rule above.
  final Map<String, int> _fgOfFeeType = {};
  final Map<int, String> _fgName = {};
  int? _yrId, _conId, _admId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // 1. The student's existing demands -- REGULAR ONLY.
      //
      // Arrears are dues carried forward from an earlier year. This dialog
      // defines which of THIS year's class fees a student owes and writes to
      // their current-year demands, so an arrear row has no business being
      // editable here: changing its amount would rewrite a figure that was
      // already demanded, billed and part-paid in a previous year.
      //
      // Filtered client-side rather than with a NOT ILIKE, so a row whose
      // demseqtype is NULL (older rows predate the column) is still treated as
      // regular and keeps showing.
      final res = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuclass, demfeeterm, demfeetype, feeamount, balancedue, conamount, paidamount, collectible, cf_id, demseqtype')
          .eq('ins_id', widget.insId)
          .eq('stuadmno', widget.stuAdmno)
          .eq('activestatus', 1)
          .order('demfeeterm', ascending: true)
          .order('demfeetype', ascending: true);
      final demRows = (res as List)
          .cast<Map<String, dynamic>>()
          .where((r) => !(r['demseqtype']?.toString().toUpperCase().contains('ARREAR') ?? false))
          .toList();

      // 2. Student record (class / admission type / ids for a new demand).
      try {
        final s = await SupabaseService.fromSchema('students')
            .select(isSchool
                ? 'stu_id, stuclass, inscode, yr_id, yrlabel, courname, con_id, hostel, stuphoto'
                : 'stu_id, stuclass, admname, inscode, yr_id, yrlabel, courname, con_id, hostel, stuphoto')
            .eq('ins_id', widget.insId)
            .eq('stuadmno', widget.stuAdmno)
            .limit(1);
        if ((s as List).isNotEmpty) {
          final m = s.first as Map;
          _stuId = (m['stu_id'] as num?)?.toInt();
          _stuclass = m['stuclass']?.toString() ?? '';
          _inscode = m['inscode']?.toString() ?? '';
          _yrId = (m['yr_id'] as num?)?.toInt();
          _yrlabel = m['yrlabel']?.toString() ?? '';
          _courname = m['courname']?.toString() ?? '';
          _conId = (m['con_id'] as num?)?.toInt();
          _stuAdmName = m['admname']?.toString() ?? '';
          _stuPhoto = m['stuphoto']?.toString();
          // A blank flag counts as NOT a hosteller -- the same reading the
          // Class Fee Demand "Hostellers only" filter uses
          // (hostel.eq.N OR hostel.is.null). 27 students have it blank.
          _isHosteller =
              (m['hostel']?.toString().trim().toUpperCase() ?? '') == 'Y';
        }
      } catch (_) {/* best effort — insert fallback just won't have every field */}

      // 3. Admission-type master + class-fee templates for this student's class.
      final admById = <int, String>{};
      final admByName = <String, int>{};
      final cfById = <int, Map<String, dynamic>>{};
      final cfByKey = <String, Map<String, dynamic>>{};
      final classes = demRows
          .map((m) => m['stuclass']?.toString() ?? '')
          .where((c) => c.isNotEmpty)
          .toSet()
        ..add(_stuclass);
      classes.removeWhere((c) => c.isEmpty);
      try {
        final futures = <Future>[
          // No admission type on the school database -- keep the slot, empty.
          if (isSchool)
            Future.value(<dynamic>[])
          else
            SupabaseService.fromSchema('admissiontype')
                .select('adm_id, admname')
                .eq('ins_id', widget.insId)
                .eq('activestatus', 1),
          if (classes.isNotEmpty)
            SupabaseService.fromSchema('classfeedemand')
                .select(isSchool
                    ? 'cf_id, cfclass, cffeetype, cfterm, cfamount, cla_id, sem_id, fee_id, cfdduedate'
                    : 'cf_id, cfclass, cffeetype, cfterm, cfamount, admissiontype, cla_id, sem_id, fee_id, cfdduedate')
                .eq('activestatus', 1)
                .inFilter('cfclass', classes.toList()),
          // Which group each fee belongs to, and which groups are hostel-only.
          SupabaseService.fromSchema('feegroup')
              .select(isSchool ? 'fg_id, fgdesc' : 'fg_id, fgdesc, hostellers_only') // no such column on a school
              .eq('ins_id', widget.insId)
              .eq('activestatus', 1),
          SupabaseService.fromSchema('feetype')
              .select('feedesc, fg_id')
              .eq('ins_id', widget.insId)
              .eq('activestatus', 1),
        ];
        final r = await Future.wait(futures);
        for (final a in (r[0] as List)) {
          final id = (a['adm_id'] as num?)?.toInt();
          final nm = a['admname']?.toString() ?? '';
          if (id != null) {
            admById[id] = nm;
            if (nm.isNotEmpty) admByName[nm.trim().toUpperCase()] = id;
          }
        }
        if (classes.isNotEmpty) {
          for (final c in (r[1] as List)) {
            final m = c as Map<String, dynamic>;
            final id = (m['cf_id'] as num?)?.toInt();
            if (id != null) cfById[id] = m;
            cfByKey.putIfAbsent('${m['cfclass']}|${m['cffeetype']}|${m['cfterm']}', () => m);
          }
        }
        // The two group reads sit after the optional classfeedemand one.
        final gi = classes.isNotEmpty ? 2 : 1;
        for (final g in (r[gi] as List)) {
          final m = g as Map<String, dynamic>;
          final id = (m['fg_id'] as num?)?.toInt();
          if (id == null) continue;
          _fgHostelOnly[id] = m['hostellers_only'] == true;
          _fgName[id] = m['fgdesc']?.toString() ?? '';
        }
        for (final t in (r[gi + 1] as List)) {
          final m = t as Map<String, dynamic>;
          final nm = m['feedesc']?.toString().trim();
          final fg = (m['fg_id'] as num?)?.toInt();
          if (nm != null && nm.isNotEmpty && fg != null) {
            _fgOfFeeType[nm.toUpperCase()] = fg;
          }
        }
      } catch (_) {/* best effort */}
      // Resolve the student's admission-type id (from the students record, or
      // the caller-supplied name) so available fees are limited to it — this is
      // the VB's IntAdmType (Studmain_admtype).
      final admKey = (_stuAdmName.isNotEmpty ? _stuAdmName : widget.admName).trim().toUpperCase();
      _admId = admByName[admKey];

      String admNameOf(Map<String, dynamic>? cf) {
        if (cf == null) return '';
        final at = cf['admissiontype'];
        final id = at is num ? at.toInt() : int.tryParse(at?.toString() ?? '');
        return id != null ? (admById[id] ?? '') : '';
      }

      // Existing-demand keys, so available fees exclude ones already given.
      final existingKeys = demRows
          .map((m) => '${m['stuclass']}|${m['demfeetype']}|${m['demfeeterm']}')
          .toSet();

      // 4. Build EXISTING rows.
      final list = demRows.map((m) {
        final cfId = (m['cf_id'] as num?)?.toInt();
        final cf = (cfId != null ? cfById[cfId] : null) ??
            cfByKey['${m['stuclass']}|${m['demfeetype']}|${m['demfeeterm']}'];
        final fee = (m['feeamount'] as num?)?.toDouble() ?? 0;
        final cfAmt = (cf?['cfamount'] as num?)?.toDouble() ?? 0;
        final admType = admNameOf(cf);
        final paid = (m['paidamount'] as num?)?.toDouble() ?? 0;
        final conc = (m['conamount'] as num?)?.toDouble() ?? 0;
        final opted = m['collectible'] == true;
        return _DefRow(
          demId: m['dem_id'] is int ? m['dem_id'] as int : int.tryParse(m['dem_id'].toString()) ?? 0,
          cfId: cfId,
          isNew: false,
          sem: m['demfeeterm']?.toString() ?? '',
          cls: m['stuclass']?.toString() ?? '',
          feeType: m['demfeetype']?.toString() ?? '',
          admType: admType.isNotEmpty ? admType : widget.admName,
          amount: fee > 0 ? fee : cfAmt,
          concession: conc,
          paidAmount: paid,
          balanceDue: (m['balancedue'] as num?)?.toDouble() ?? 0,
          opted: opted,
          origOpted: opted,
          locked: paid > 0.005 || conc > 0.005,
        );
      }).toList();

      // 5. Build AVAILABLE rows — class fees for this student's class + admission
      //    type that aren't already a demand. Shown unticked, to be added.
      final seen = <String>{...existingKeys};
      for (final c in cfById.values) {
        final cls = c['cfclass']?.toString() ?? '';
        if (cls.isEmpty || cls != _stuclass) continue; // only the current class
        final at = c['admissiontype'];
        final atId = at is num ? at.toInt() : int.tryParse(at?.toString() ?? '');
        // Only the student's admission type (VB: feeinfo_admntype_id = IntAdmType);
        // a null admission type means the fee applies to every type.
        if (atId != null && atId != _admId) continue;
        final key = '$cls|${c['cffeetype']}|${c['cfterm']}';
        if (seen.contains(key)) continue; // already a demand / already added
        // A day scholar is not offered a hostel-only group's fees. Only the
        // AVAILABLE list is filtered -- a demand the student already HAS stays
        // visible even if the group is hostel-only, because hiding a fee that
        // has been billed (and possibly paid) would make it unreachable.
        if (_hiddenFromThisStudent(c['cffeetype']?.toString() ?? '')) continue;
        seen.add(key);
        list.add(_DefRow(
          demId: 0,
          cfId: (c['cf_id'] as num?)?.toInt(),
          isNew: true,
          sem: c['cfterm']?.toString() ?? '',
          cls: cls,
          feeType: c['cffeetype']?.toString() ?? '',
          admType: admNameOf(c).isNotEmpty ? admNameOf(c) : widget.admName,
          amount: (c['cfamount'] as num?)?.toDouble() ?? 0,
          concession: 0,
          paidAmount: 0,
          balanceDue: (c['cfamount'] as num?)?.toDouble() ?? 0,
          opted: false,
          origOpted: false,
          locked: false,
          claId: (c['cla_id'] as num?)?.toInt(),
          semId: (c['sem_id'] as num?)?.toInt(),
          feeId: (c['fee_id'] as num?)?.toInt(),
          dueDate: c['cfdduedate']?.toString(),
        ));
      }

      // Ticked (opted) rows first, then group by class, semester, fee type.
      // Ticked first, then BY FEE GROUP, then class / semester / fee type.
      // Grouping matters now that a student can be offered fees from more than
      // one group: COLLEGE FEES and HOSTEL FEES interleaved alphabetically
      // read as one undifferentiated list, which is how a mess fee went
      // unnoticed among a day scholar's college fees.
      list.sort((a, b) {
        if (a.opted != b.opted) return a.opted ? -1 : 1;
        final g = _groupNameOf(a.feeType).compareTo(_groupNameOf(b.feeType));
        if (g != 0) return g;
        final c = a.cls.compareTo(b.cls);
        if (c != 0) return c;
        final s = a.sem.compareTo(b.sem);
        if (s != 0) return s;
        return a.feeType.compareTo(b.feeType);
      });
      if (!mounted) return;
      setState(() {
        for (final r in _rows) {
          r.dispose();
        }
        _rows = list;
        _sem ??= list.isNotEmpty ? list.first.sem : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack("Could not load this student's fees. ${friendlyError(e)}", AppColors.error);
      }
    }
  }

  List<String> get _sems =>
      (_rows.map((r) => r.sem).where((s) => s.isNotEmpty).toSet().toList()..sort());
  /// Chosen fee group, null = all. A SELECTION rather than a column: the
  /// group is the same for most of the list, so printing it on every row cost
  /// a column's width to repeat "COLLEGE FEES" forty times.
  String? _fgPick;

  /// Groups actually present in this student's list, for the selector. Built
  /// from the rows so a group with nothing to offer never appears.
  List<String> get _groupsPresent {
    final g = <String>{};
    for (final r in _rows) {
      final n = _groupNameOf(r.feeType);
      if (n.isNotEmpty) g.add(n);
    }
    final out = g.toList()..sort();
    return out;
  }

  List<_DefRow> get _visible => _rows.where((r) {
        if (_sem != null && r.sem != _sem) return false;
        if (_fgPick != null && _groupNameOf(r.feeType) != _fgPick) return false;
        return true;
      }).toList();
  double get _toReceive => _visible.where((r) => r.opted).fold(0.0, (s, r) => s + r.balance);

  /// True when Save would actually write something. Mirrors the branches in
  /// [_save] one-for-one — if that logic changes, this must change with it.
  bool get _hasChanges => _rows.any((r) {
        if (r.isNew) return r.opted && r.cfId != null;
        if (r.locked) return r.amountChanged;
        if (r.opted) return r.amountChanged || !r.origOpted;
        return r.origOpted; // an existing fee unticked → delete on save
      });

  Future<void> _save() async {
    // Say so rather than closing on a no-op. An available fee arrives pre-filled
    // with its template amount but un-opted, so it is easy to read the dialog as
    // "500 is set, save it" and get a silent close that wrote nothing.
    if (!_hasChanges) {
      setState(() => _error = 'Nothing to save. Tick a fee under OPTED to add it '
          'to this student, or change an amount.');
      return;
    }

    // A fee amount can't be set below what's already been collected on it.
    for (final r in _rows) {
      if ((r.opted || r.locked) && r.paidAmount - r.amount > 0.005) {
        setState(() => _error =
            '${r.feeType}: amount ₹${r.amount.toStringAsFixed(2)} cannot be less '
            'than the already-paid ₹${r.paidAmount.toStringAsFixed(2)}.');
        return;
      }
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final auth = context.read<AuthProvider>();
      final token = auth.sessionToken;
      for (final r in _rows) {
        if (r.isNew) {
          // Available fee ticked → create the demand.
          if (r.opted && r.cfId != null) {
            await SupabaseService.addStudentFeeDemand(
              token: token,
              stuAdmno: widget.stuAdmno,
              cfId: r.cfId!,
              amount: r.amount,
              fallbackRow: _newDemandRow(r, auth.userName ?? 'SYSTEM'),
            );
          }
        } else if (r.locked) {
          // A collection exists — can't be unticked/deleted, but the amount may
          // still be edited (VB updates studfee_amt for collected rows). Write
          // only on an actual change; keep its opt (collectible) state.
          if (r.amountChanged) {
            await SupabaseService.saveFeeDefinition(
              token: token, demId: r.demId, feeamount: r.amount,
              collectible: r.origOpted, balancedue: r.balance);
          }
        } else if (r.opted) {
          // Existing + ticked → update amount / opt-in. Only write on a change.
          if (r.amountChanged || !r.origOpted) {
            await SupabaseService.saveFeeDefinition(
              token: token, demId: r.demId, feeamount: r.amount, collectible: true,
              balancedue: r.amountChanged ? r.balance : null);
          }
        } else if (r.origOpted) {
          // Existing collectible fee unticked (no collection) → delete it.
          await SupabaseService.deleteStudentFeeDemand(r.demId, token: token);
        }
        // (existing + already non-collectible + still unticked → nothing to do)
      }
      if (!mounted) return;
      // Stay open, so several semesters can be defined in one sitting.
      //
      // The reload is NOT optional. Rows created a moment ago are still marked
      // isNew in memory, so without it a second Save would insert every one of
      // them again. Reloading gives them their dem_id and a fresh
      // origOpted/origAmount baseline, which is also what makes _hasChanges
      // correctly report "nothing to save" until something else is touched.
      _savedAny = true;
      setState(() {
        _saving = false;
        _error = null;
        _info = 'Saved. Add more fees, or close when you are done.';
      });
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('Could not save the fee definition. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  /// Full feedemand row for the direct-insert fallback (used when there is no
  /// session token / the RPC is absent). The set_dem_id trigger fills dem_id,
  /// demno, demseqtype and fee_id, so those are left out.
  Map<String, dynamic> _newDemandRow(_DefRow r, String userName) {
    final amt = r.amount < 0 ? 0.0 : r.amount;
    final today = DateTime.now();
    final due = (r.dueDate != null && r.dueDate!.isNotEmpty)
        ? r.dueDate
        : '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    return <String, dynamic>{
      'ins_id': widget.insId,
      'inscode': _inscode,
      if (_yrId != null) 'yr_id': _yrId,
      if (_stuId != null) 'stu_id': _stuId,
      'stuadmno': widget.stuAdmno,
      'stuclass': r.cls,
      'courname': _courname,
      'demfeeyear': _yrlabel,
      'demfeeterm': r.sem,
      'demfeetype': r.feeType,
      'feeamount': amt,
      if (_conId != null) 'con_id': _conId,
      'conamount': 0,
      'balancedue': amt,
      'reconbalancedue': amt,
      'paidamount': 0,
      'duedate': due,
      'activestatus': 1,
      'createdby': userName,
      'collectible': true,
      if (r.claId != null) 'cla_id': r.claId,
      if (r.semId != null) 'sem_id': r.semId,
      if (r.cfId != null) 'cf_id': r.cfId,
      if (r.feeId != null) 'fee_id': r.feeId,
      'demseqtype': 'REGULAR',
    };
  }

  /// The single way out without saving. X, Cancel and Esc all route here so
  /// they cannot drift apart, and it pops THIS dialog's route explicitly rather
  /// than whatever Navigator.pop resolves to from a descendant context.
  void _close() {
    if (!mounted) return;
    Navigator.of(context).pop(_savedAny);
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }


  /// The fee group a fee belongs to, by name. Empty when it cannot be
  /// resolved, which sorts such rows together at the top rather than
  /// scattering them.
  String _groupNameOf(String feeType) {
    final fg = _fgOfFeeType[feeType.trim().toUpperCase()];
    return fg == null ? '' : (_fgName[fg] ?? '');
  }

  /// Is this fee one a day scholar should never be offered?
  ///
  /// The rule is on the GROUP (feegroup.hostellers_only), set in Setup > Fee
  /// Master > Fee Group, not inferred from the fee's name. A fee whose group
  /// cannot be resolved is treated as open to everyone -- hiding a fee by
  /// accident bills nobody, and that is the failure that goes unnoticed.
  bool _hiddenFromThisStudent(String feeType) {
    if (_isHosteller) return false;
    final fg = _fgOfFeeType[feeType.trim().toUpperCase()];
    if (fg == null) return false;
    return _fgHostelOnly[fg] == true;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
      child: SizedBox(
        width: 920.w,
        height: 600.h,
        child: Column(
          children: [
            // header
            Container(
              padding: EdgeInsets.fromLTRB(20.w, 16.h, 14.w, 16.h),
              child: Row(
                children: [
                  AppUI.iconTile('clipboard-tick'),
                  SizedBox(width: 12.w),
                  Text('Student Fee Definition', style: AppUI.cardTitle),
                  SizedBox(width: 12.w),
                  StudentAvatar(photoUrl: _stuPhoto, name: widget.stuName, size: 44),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Text('${widget.stuName}  •  ${widget.stuAdmno}${isSchool ? '' : '  •  ${widget.admName}'}',
                        overflow: TextOverflow.ellipsis,
                        style: AppUI.muted),
                  ),
                  // An explicit hit box rather than a bare IconButton: its
                  // 48x48 default target sat partly past the header's right
                  // padding, so the visible glyph and the area that actually
                  // responds were not the same rectangle.
                  Tooltip(
                    message: 'Close without saving',
                    child: Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _close,
                        child: Padding(
                          padding: EdgeInsets.all(6.w),
                          child: const Icon(Icons.close, color: AppColors.textSecondary, size: 20),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.divider),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                      ? AppUI.empty(
                          title: 'No fees defined for this student',
                          why: 'No fee structure matches this student yet.',
                          icon: 'clipboard-text')
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ExcludeFocusTraversal(
                              child: SizedBox(width: 170.w, child: _semList()),
                            ),
                            const VerticalDivider(width: 1, color: AppColors.divider),
                            Expanded(child: FocusTraversalGroup(child: _table())),
                          ],
                        ),
            ),
            const Divider(height: 1, color: AppColors.divider),
            _footer(),
          ],
        ),
      ),
      ),
    );
  }

  Widget _semList() {
    final sems = _sems;
    return ListView(
      children: [
        for (final s in sems)
          Material(
            color: _sem == s ? AppColors.primaryLight : Colors.transparent,
            child: InkWell(
              onTap: () => setState(() => _sem = s),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
                child: Text(s,
                    style: TextStyle(
                        fontSize: 14.sp,
                        fontWeight: _sem == s ? FontWeight.w700 : FontWeight.w500,
                        color: _sem == s ? AppColors.primary : AppColors.textPrimary)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _table() {
    TextStyle h() => AppUI.tableHead;
    TextStyle c() => AppUI.cell;
    final rows = _visible;
    final groups = _groupsPresent;
    return Column(
      children: [
        // FEE GROUP as a selection, not a column. Most of the list belongs to
        // one group, so a column spent its width repeating "COLLEGE FEES" on
        // every row; as chips it says the same thing once and doubles as a
        // filter. Hidden entirely when there is only one group to choose.
        if (groups.length > 1)
          Container(
            padding: EdgeInsets.fromLTRB(12.w, 8.h, 12.w, 8.h),
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8.w,
              runSpacing: 6.h,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('FEE GROUP', style: AppUI.caps),
                for (final g in <String?>[null, ...groups])
                  ChoiceChip(
                    label: Text(g ?? 'All',
                        style: TextStyle(
                            fontSize: 12.sp,
                            fontWeight: _fgPick == g
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _fgPick == g
                                ? AppColors.primary
                                : AppColors.textPrimary)),
                    selected: _fgPick == g,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    selectedColor: AppColors.primaryLight,
                    onSelected: (_) => setState(() => _fgPick = g),
                  ),
              ],
            ),
          ),
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
          child: Row(children: [
            SizedBox(width: 56.w, child: Text('OPTED', style: h())),
            Expanded(flex: 2, child: Text(schoolTerm('CLASS'), style: h())),
            if (!isSchool) Expanded(flex: 2, child: Text('ADMISSION TYPE', style: h())),
            Expanded(flex: 3, child: Text('FEE TYPE', style: h())),
            SizedBox(width: 90.w, child: Text('AMOUNT', textAlign: TextAlign.right, style: h())),
            SizedBox(width: 12.w),
            SizedBox(width: 80.w, child: Text('BALANCE', textAlign: TextAlign.right, style: h())),
            SizedBox(width: 96.w, child: Text('CONCESSION', textAlign: TextAlign.right, style: h())),
          ]),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
            itemBuilder: (_, i) {
              final r = rows[i];
              // Colour cue: new/available = green tint, locked = grey.
              final bg = r.locked
                  ? AppColors.tableHeadBg
                  : r.isNew
                      ? AppColors.successBg
                      : (i.isEven ? Colors.white : AppColors.surface);
              return FocusTraversalGroup(child: Container(
                color: bg,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 2.h),
                child: Row(children: [
                  SizedBox(
                    width: 56.w,
                    child: r.locked
                        ? Tooltip(
                            message: r.paidAmount > 0.005
                                ? 'A collection exists — locked'
                                : 'A concession exists — locked',
                            child: Icon(Icons.lock_outline, size: 16.sp, color: AppColors.textSecondary))
                        : Checkbox(
                            value: r.opted,
                            activeColor: AppColors.accent,
                            visualDensity: VisualDensity.compact,
                            onChanged: (v) => setState(() {
                              _error = null;
                              _info = null;
                              r.opted = v ?? false;
                            }),
                          ),
                  ),
                  Expanded(flex: 2, child: Text(r.cls, style: c())),
                  if (!isSchool) Expanded(flex: 2, child: Text(r.admType.isNotEmpty ? r.admType : '-', style: c())),
                  Expanded(flex: 3, child: Text(r.feeType, style: AppUI.cell)),
                  SizedBox(
                    width: 90.w,
                    // Every amount is typeable. It used to be read-only until the
                    // row was ticked, which made the auto-opt below unreachable:
                    // you had to tick first, so typing could never be what ticked
                    // it. Typing the amount IS the cashier's intent to opt in, so
                    // that is now the one gesture that does both.
                    child: TextField(
                      controller: r.amountCtrl,
                      textAlign: TextAlign.right,
                      // Select-all on tap so a typed value REPLACES the old one
                      // instead of being inserted at the caret.
                      onTap: () => r.amountCtrl.selection = TextSelection(
                          baseOffset: 0, extentOffset: r.amountCtrl.text.length),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      // Keyed on opted, NOT on "has text". An available fee
                      // arrives pre-filled with its template amount while still
                      // un-opted; styling it by text made that row look live and
                      // included when it is neither, and Save would then appear
                      // to do nothing. Accent = this row will be written.
                      style: AppUI.fieldText(context, filled: r.opted || r.locked),
                      // Empty means zero. Shown as a hint so an un-opted row
                      // still reads '0.00' at a glance, as it did when this
                      // cell was a read-only box.
                      decoration: AppUI.field(context, '0.00', filled: r.opted || r.locked, dense: true)
                          .copyWith(contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8)),
                      onChanged: (v) => setState(() {
                        _error = null;
                        _info = null;
                        // Typing a positive amount opts the student into this fee.
                        //
                        // Deliberately one-way. Clearing the field does NOT untick:
                        // on an existing fee an untick means DELETE THE DEMAND at
                        // save, and a half-typed or accidentally-cleared cell must
                        // never be the gesture that deletes one. Un-opting stays
                        // the checkbox — explicit, and the only way to remove a fee.
                        if ((double.tryParse(v.trim()) ?? 0) > 0) r.opted = true;
                      }),
                    ),
                  ),
                  SizedBox(width: 12.w),
                  SizedBox(width: 80.w, child: Text(r.balance.toStringAsFixed(2), textAlign: TextAlign.right, style: c())),
                  SizedBox(width: 96.w, child: Text(r.concession.toStringAsFixed(2), textAlign: TextAlign.right, style: c())),
                ]),
              ));
            },
          ),
        ),
      ],
    );
  }

  Widget _footer() {
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(bottom: 10.h),
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
              decoration: BoxDecoration(
                color: AppColors.errorBg,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18.sp, color: AppColors.error),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w600,
                            color: AppColors.error)),
                  ),
                ],
              ),
            ),
          ],
          // Save no longer closes the dialog, so the confirmation has to be
          // here — otherwise a successful save looks identical to nothing
          // happening. An error outranks it.
          if (_error == null && _info != null) ...[
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(bottom: 10.h),
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
              decoration: BoxDecoration(
                color: AppColors.successBg,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 18.sp, color: AppColors.success),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(_info!,
                        style: TextStyle(
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w600,
                            color: AppColors.success)),
                  ),
                ],
              ),
            ),
          ],
          Row(
        children: [
          Text('Fees to be Received: ', style: AppUI.muted),
          Text('₹ ${_toReceive.toStringAsFixed(2)}', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.primary)),
          const Spacer(),
          OutlinedButton(onPressed: _close, child: const Text('Cancel')),
          SizedBox(width: 10.w),
          ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: const Text('Save'),
          ),
        ],
      ),
        ],
      ),
    );
  }
}
