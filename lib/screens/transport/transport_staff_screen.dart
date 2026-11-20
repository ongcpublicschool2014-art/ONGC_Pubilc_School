import 'package:flutter/material.dart';

import '../../services/transport_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_ui.dart';
import 'transport_master_panel.dart';

/// TRANSPORT STAFF -- drivers, attenders, conductors and supervisors, with
/// their licence, badge, medical and police-verification documents.
class TransportStaffScreen extends StatefulWidget {
  const TransportStaffScreen({super.key});

  @override
  State<TransportStaffScreen> createState() => _TransportStaffScreenState();
}

const _staffTypes = <(Object?, String)>[
  ('DRIVER', 'Driver'),
  ('ATTENDER', 'Attender'),
  ('CONDUCTOR', 'Conductor'),
  ('SUPERVISOR', 'Supervisor'),
  ('CLEANER', 'Cleaner'),
];
const _employment = <(Object?, String)>[('PERMANENT', 'Permanent'), ('CONTRACT', 'Contract'), ('VENDOR', 'From Vendor')];
const _genders = <(Object?, String)>[('M', 'Male'), ('F', 'Female'), ('O', 'Other')];
const _statuses = <(Object?, String)>[('ACTIVE', 'Active'), ('ON_LEAVE', 'On Leave'), ('SUSPENDED', 'Suspended'), ('RELIEVED', 'Relieved')];
const _docTypes = <(Object?, String)>[
  ('DRIVING_LICENCE', 'Driving Licence'),
  ('PSV_BADGE', 'PSV Badge'),
  ('MEDICAL_FITNESS', 'Medical Fitness'),
  ('POLICE_VERIFICATION', 'Police Verification'),
  ('ID_PROOF', 'ID Proof'),
  ('TRAINING', 'Training'),
  ('OTHER', 'Other'),
];

String _label(List<(Object?, String)> options, dynamic value) {
  for (final o in options) {
    if (o.$1 == value) return o.$2;
  }
  return trText(value);
}

class _TransportStaffScreenState extends State<TransportStaffScreen> {
  List<(Object?, String)> _vendors = const [];
  int _warnDays = 30;

  @override
  void initState() {
    super.initState();
    _loadVendors();
    _loadWarnDays();
  }

  Future<void> _loadVendors() async {
    try {
      final rows = await TransportService.list('vendor');
      if (!mounted) return;
      setState(() {
        _vendors = [
          for (final r in rows)
            if (r['is_active'] != false) (trId(r['vendor_id']), trText(r['vendor_name'])),
        ];
      });
    } catch (e) {
      if (mounted) trSnack(context, friendlyError(e), AppColors.error);
    }
  }

  /// The warning period comes from Transport Setup, which only some roles can
  /// open: others keep the default.
  Future<void> _loadWarnDays() async {
    try {
      final s = await TransportService.settings();
      final d = trId(s['doc_expiry_alert_days']);
      if (mounted && d != null) setState(() => _warnDays = d);
    } catch (_) {}
  }

  void _documents(Map<String, dynamic> s) {
    final id = trId(s['staff_id'])!;
    showTrPanelDialog(
      context,
      TrPanel(
        key: ValueKey('sdocs-$id'),
        entity: 'staff_doc',
        pk: 'staff_doc_id',
        title: 'Documents: ${trText(s['full_name'])}',
        subtitle: _label(_staffTypes, s['staff_type']),
        icon: 'document-text',
        noun: 'document',
        filter: {'staff_id': id},
        fixed: {'staff_id': id},
        deleteNote: 'This document record will be removed. This cannot be undone.',
        emptyWhy: 'Add the licence, PSV badge, medical and police verification with their expiry dates.',
        columns: [
          TrColumn('Document', flex: 3, text: (r) => _label(_docTypes, r['doc_type'])),
          TrColumn('Number', flex: 3, text: (r) => trText(r['doc_no']), mono: true),
          TrColumn('Class', flex: 2, text: (r) => trText(r['licence_class'])),
          TrColumn('Expiry', flex: 2, text: (r) => r['expiry_date'] == null ? '-' : formatDate(r['expiry_date'] as String?)),
          TrColumn('Status', flex: 3, cell: (r) {
            if (r['is_current'] == false) return AppUI.chip('Old', AppStatus.neutral);
            final st = trExpiryStatus(r['expiry_date'] as String?, warnDays: _warnDays);
            return AppUI.chip(st.$1, st.$2);
          }),
          TrColumn('File', flex: 1, cell: (r) => trAttachmentCell(context, r['file_url'])),
        ],
        searchText: (r) => '${_label(_docTypes, r['doc_type'])} ${r['doc_no']}',
        newValues: (_) => const {'is_current': true},
        fields: (_) => [
          const TrField('doc_type', 'Document Type', kind: TrKind.choice, required: true, options: _docTypes),
          const TrField('doc_no', 'Document Number', maxLength: 40),
          TrField('licence_class', 'Licence Class', maxLength: 30, hint: 'LMV / HMV / TRANS', visibleWhen: (v) => v['doc_type'] == 'DRIVING_LICENCE'),
          const TrField('issuing_authority', 'Issued By', maxLength: 100),
          const TrField('issue_date', 'Issue Date', kind: TrKind.date),
          const TrField('expiry_date', 'Expiry Date', kind: TrKind.date),
          const TrField('is_current', 'Current Document', kind: TrKind.toggle),
          const TrField('file_url', 'Attachment', kind: TrKind.file, full: true, folder: 'transport/staff-docs'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppUI.card(),
      padding: EdgeInsets.all(AppUI.cardPad),
      child: TrPanel(
        key: ValueKey('staff-${_vendors.length}'),
        entity: 'staff',
        pk: 'staff_id',
        title: 'Transport Staff',
        subtitle: 'Drivers, attenders, conductors and supervisors.',
        icon: 'driver',
        noun: 'staff member',
        deleteNote: 'The staff member is marked Relieved and kept for past records. Someone with an open duty cannot be deleted.',
        emptyWhy: 'Add your drivers and attenders.',
        rowActions: [TrRowAction(icon: 'document-text', tooltip: 'Documents', onTap: _documents)],
        columns: [
          TrColumn('Code', flex: 2, text: (r) => trText(r['staff_code']), mono: true),
          TrColumn('Name', flex: 4, text: (r) => trText(r['full_name'])),
          TrColumn('Type', flex: 2, text: (r) => _label(_staffTypes, r['staff_type'])),
          TrColumn('Mobile', flex: 3, text: (r) => trText(r['mobile']), mono: true),
          TrColumn('Employment', flex: 2, text: (r) => _label(_employment, r['employment_type'])),
          TrColumn('Licence', flex: 2, cell: (r) {
            final till = r['license_valid_till'] as String?;
            if (till == null) return Text('-', style: AppUI.cell);
            final st = trExpiryStatus(till, warnDays: _warnDays);
            return Tooltip(message: 'Valid till ${formatDate(till)}', child: AppUI.chip(st.$1, st.$2));
          }),
          TrColumn('Police Check', flex: 2, cell: (r) => r['police_verified'] == true ? AppUI.chip('Verified', AppStatus.success) : AppUI.chip('Pending', AppStatus.warning)),
          TrColumn('Status', flex: 2, cell: (r) {
            final s = r['status'];
            return AppUI.chip(_label(_statuses, s), s == 'ACTIVE' ? AppStatus.success : (s == 'RELIEVED' ? AppStatus.neutral : AppStatus.warning));
          }),
        ],
        searchText: (r) => '${r['staff_code']} ${r['full_name']} ${r['mobile']} ${r['license_number'] ?? ''}',
        newValues: (_) => const {'staff_type': 'DRIVER', 'employment_type': 'PERMANENT', 'status': 'ACTIVE'},
        fields: (_) => [
          // shown in the form's top-right corner, beside the Staff fields
          const TrField('photo_url', 'Photo', kind: TrKind.photo, folder: 'transport/staff'),
          const TrField('staff_code', 'Staff Code', kind: TrKind.upper, required: true, maxLength: 20, section: 'Staff'),
          const TrField('full_name', 'Full Name', required: true, maxLength: 120),
          const TrField('staff_type', 'Staff Type', kind: TrKind.choice, required: true, options: _staffTypes),
          const TrField('mobile', 'Mobile', kind: TrKind.mobile, required: true, maxLength: 15),
          const TrField('alt_mobile', 'Alternate Mobile', kind: TrKind.mobile, maxLength: 15),
          const TrField('gender', 'Gender', kind: TrKind.choice, options: _genders),
          const TrField('date_of_birth', 'Date of Birth', kind: TrKind.date),
          const TrField('blood_group', 'Blood Group', kind: TrKind.upper, maxLength: 4),
          const TrField('address', 'Address', kind: TrKind.multiline, full: true),
          const TrField('license_number', 'Licence Number', kind: TrKind.upper, maxLength: 50, section: 'Driving Licence'),
          const TrField('license_type', 'Licence Type', kind: TrKind.upper, maxLength: 30, hint: 'LMV / HMV / TRANS'),
          const TrField('license_valid_till', 'Valid Till', kind: TrKind.date),
          const TrField('employment_type', 'Employment', kind: TrKind.choice, required: true, options: _employment, section: 'Employment'),
          TrField('vendor_id', 'Vendor', kind: TrKind.choice, required: true, options: _vendors, visibleWhen: (v) => v['employment_type'] == 'VENDOR'),
          const TrField('joining_date', 'Joining Date', kind: TrKind.date),
          const TrField('relieving_date', 'Relieving Date', kind: TrKind.date),
          const TrField('experience_years', 'Experience (years)', kind: TrKind.integer),
          const TrField('status', 'Status', kind: TrKind.choice, required: true, options: _statuses),
          const TrField('police_verified', 'Police Verified', kind: TrKind.toggle, section: 'Verification & Emergency'),
          const TrField('police_verified_on', 'Verified On', kind: TrKind.date),
          const TrField('id_proof_type', 'ID Proof Type', maxLength: 20, hint: 'e.g. Aadhaar'),
          const TrField('id_proof_no_masked', 'ID Number', maxLength: 20, hint: 'Only the last 4 digits are kept'),
          const TrField('emergency_contact_name', 'Emergency Contact', maxLength: 100),
          const TrField('emergency_contact_phone', 'Emergency Phone', kind: TrKind.mobile, maxLength: 15),
        ],
      ),
    );
  }
}
