import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../services/transport_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/pill_tab.dart';
import 'gps_mapping_panel.dart';
import 'transport_master_panel.dart';

/// VEHICLES -- the fleet with its documents, the GPS devices and which one is
/// on each vehicle (GPS Mapping), the vendors who supply contracted, leased
/// or hired vehicles, each vehicle's services and repairs (Service), and its
/// fuel fills and charges (Fuel).
class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key});

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

const _types = <(Object?, String)>[('BUS', 'Bus'), ('MINI_BUS', 'Mini Bus'), ('VAN', 'Van'), ('CAR', 'Car'), ('AUTO', 'Auto'), ('OTHER', 'Other')];
const _fuels = <(Object?, String)>[('DIESEL', 'Diesel'), ('PETROL', 'Petrol'), ('CNG', 'CNG'), ('ELECTRIC', 'Electric'), ('HYBRID', 'Hybrid')];
const _ownership = <(Object?, String)>[('OWNED', 'Owned'), ('CONTRACTED', 'Contracted'), ('LEASED', 'Leased'), ('HIRED', 'Hired')];
const _basis = <(Object?, String)>[('PER_MONTH', 'Per Month'), ('PER_TRIP', 'Per Trip'), ('PER_KM', 'Per Km')];
const _deviceTypes = <(Object?, String)>[('HARDWARE', 'Hardware Tracker'), ('MOBILE_APP', 'Mobile App')];
const _statuses = <(Object?, String)>[('ACTIVE', 'Active'), ('UNDER_REPAIR', 'Under Repair'), ('INACTIVE', 'Inactive'), ('SOLD', 'Sold'), ('SCRAPPED', 'Scrapped')];
const _docTypes = <(Object?, String)>[
  ('RC', 'RC'),
  ('INSURANCE', 'Insurance'),
  ('FITNESS', 'Fitness'),
  ('PERMIT', 'Permit'),
  ('PUC', 'PUC'),
  ('ROAD_TAX', 'Road Tax'),
  ('SPEED_GOVERNOR', 'Speed Governor'),
  ('GPS_CERT', 'GPS Certificate'),
  ('FIRE_CERT', 'Fire Certificate'),
  ('OTHER', 'Other'),
];

const _serviceTypes = <(Object?, String)>[
  ('PERIODIC', 'Periodic Service'),
  ('REPAIR', 'Repair'),
  ('TYRE', 'Tyre'),
  ('BATTERY', 'Battery'),
  ('ACCIDENT', 'Accident Repair'),
  ('OTHER', 'Other'),
];

String _label(List<(Object?, String)> options, dynamic value) {
  for (final o in options) {
    if (o.$1 == value) return o.$2;
  }
  return trText(value);
}

bool _notOwned(Map<String, dynamic> v) => v['ownership_type'] != null && v['ownership_type'] != 'OWNED';

num? _num(dynamic v) => v is num ? v : num.tryParse(trText(v));

/// 15000 -> "15,000 km"; '-' when empty.
String _km(dynamic v) {
  final n = _num(v);
  return n == null ? '-' : '${formatIndianNumber(n)} km';
}

String _amount(dynamic v) {
  final n = _num(v);
  return n == null ? '-' : formatCurrency(n);
}

String _days(dynamic v) {
  final n = trId(v);
  return n == null ? '-' : (n == 1 ? '1 day' : '$n days');
}

/// When the next service is due: the date, the reading, or both.
String _nextDue(Map<String, dynamic> r) {
  final parts = [
    if (r['next_due_date'] != null) formatDate(r['next_due_date'] as String?),
    if (r['next_due_km'] != null) _km(r['next_due_km']),
  ];
  return parts.isEmpty ? '-' : parts.join(' · ');
}

/// The seats, and the additional capacity for small children when there is
/// some: "40", or "40 + 2".
String _seatsText(Map<String, dynamic> v) {
  final seats = trText(v['seating_capacity']);
  final extra = trId(v['additional_capacity']) ?? 0;
  return extra > 0 ? '$seats + $extra' : seats;
}

/// The unit a vehicle's fuel is measured in: kWh for an electric one, else litres.
String _unit(Map<String, dynamic>? vehicle) => vehicle?['fuel_type'] == 'ELECTRIC' ? 'kWh' : 'L';

/// 40 -> "40 L" (or "40 kWh"); '-' when empty.
String _qty(dynamic v, Map<String, dynamic>? vehicle) {
  final n = _num(v);
  return n == null ? '-' : '${formatIndianNumber(n)} ${_unit(vehicle)}';
}

/// The tabs, in order.
const _tabVehicles = 0, _tabVendors = 1, _tabService = 2, _tabFuel = 3, _tabDevices = 4, _tabMapping = 5;

class _VehiclesScreenState extends State<VehiclesScreen> {
  int _tab = _tabVehicles;
  List<(Object?, String)> _vendors = const [];

  /// Device id -> its name, for the vehicle list's GPS Device column. Every
  /// device of the school, switched-off ones too.
  Map<int, String> _devices = const {};

  /// The school's vehicles, every status, for the Service and Fuel tabs'
  /// vehicle column and vehicle picker.
  List<Map<String, dynamic>> _vehicles = const [];

  /// The transport staff, every status, for the Fuel tab's Filled By.
  List<Map<String, dynamic>> _staff = const [];

  /// GPS Mapping has changes that are not saved yet.
  bool _mappingDirty = false;
  int _warnDays = 30;

  @override
  void initState() {
    super.initState();
    _loadVendors();
    _loadDevices();
    _loadVehicles();
    _loadStaff();
    _loadWarnDays();
  }

  /// If the list cannot be loaded, the Service and Fuel tabs cannot add a
  /// record; their own lists show why.
  Future<void> _loadVehicles() async {
    try {
      final rows = await TransportService.list('vehicle');
      if (mounted) setState(() => _vehicles = rows);
    } catch (_) {}
  }

  /// If the list cannot be loaded, the Fuel tab's Filled By has no names to
  /// pick; the entry can still be saved without one.
  Future<void> _loadStaff() async {
    try {
      final rows = await TransportService.list('staff');
      if (mounted) setState(() => _staff = rows);
    } catch (_) {}
  }

  /// GPS devices are a master shared by every year, like the vehicles. If
  /// the list cannot be loaded, the vehicle list shows no device names; the
  /// GPS Devices tab shows why.
  Future<void> _loadDevices() async {
    try {
      final rows = await TransportService.list('gps_device');
      if (!mounted) return;
      setState(() => _devices = {
            for (final r in rows)
              if (trId(r['device_id']) != null) trId(r['device_id'])!: gpsDeviceName(r),
          });
    } catch (_) {}
  }

  /// Opens another tab; leaving GPS Mapping with changes not saved asks first.
  Future<void> _goTo(int tab) async {
    if (tab == _tab) return;
    if (_tab == _tabMapping && _mappingDirty) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Leave without saving?'),
          content: const Text('The GPS Mapping changes you made are not saved yet. They will be lost.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: AppUI.danger(ctx), child: const Text('Leave')),
          ],
        ),
      );
      if (leave != true || !mounted) return;
      _mappingDirty = false;
    }
    setState(() => _tab = tab);
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

  void _documents(Map<String, dynamic> v) {
    final id = trId(v['vehicle_id'])!;
    showTrPanelDialog(
      context,
      TrPanel(
        key: ValueKey('vdocs-$id'),
        entity: 'vehicle_doc',
        pk: 'vehicle_doc_id',
        title: 'Documents: ${trText(v['vehicle_code'])}',
        subtitle: trText(v['registration_no']),
        icon: 'document-text',
        noun: 'document',
        filter: {'vehicle_id': id},
        fixed: {'vehicle_id': id},
        deleteNote: 'This document record will be removed. This cannot be undone.',
        emptyWhy: 'Add the RC, insurance, fitness, permit, PUC and road tax with their expiry dates.',
        columns: [
          TrColumn('Document', flex: 3, text: (r) => _label(_docTypes, r['doc_type'])),
          TrColumn('Number', flex: 3, text: (r) => trText(r['doc_no']), mono: true),
          TrColumn('Issued By', flex: 3, text: (r) => trText(r['issuing_authority'])),
          TrColumn('Expiry', flex: 2, text: (r) => r['expiry_date'] == null ? '-' : formatDate(r['expiry_date'] as String?)),
          TrColumn('Status', flex: 3, cell: (r) {
            if (r['is_current'] == false) return AppUI.chip('Old', AppStatus.neutral);
            final s = trExpiryStatus(r['expiry_date'] as String?, warnDays: _warnDays);
            return AppUI.chip(s.$1, s.$2);
          }),
          TrColumn('File', flex: 1, cell: (r) => trAttachmentCell(context, r['file_url'])),
        ],
        searchText: (r) => '${_label(_docTypes, r['doc_type'])} ${r['doc_no']} ${r['issuing_authority']}',
        newValues: (_) => const {'is_current': true},
        fields: (_) => [
          const TrField('doc_type', 'Document Type', kind: TrKind.choice, required: true, options: _docTypes),
          const TrField('doc_no', 'Document Number', maxLength: 60),
          const TrField('issuing_authority', 'Issued By', maxLength: 100, hint: 'RTO or insurer'),
          TrField('insurance_type', 'Insurance Type', maxLength: 20, hint: 'Comprehensive / Third Party', visibleWhen: (v) => v['doc_type'] == 'INSURANCE'),
          TrField('insured_value', 'Insured Value', kind: TrKind.decimal, visibleWhen: (v) => v['doc_type'] == 'INSURANCE'),
          TrField('premium_amount', 'Premium Amount', kind: TrKind.decimal, visibleWhen: (v) => v['doc_type'] == 'INSURANCE'),
          const TrField('issue_date', 'Issue Date', kind: TrKind.date),
          const TrField('valid_from', 'Valid From', kind: TrKind.date),
          const TrField('expiry_date', 'Expiry Date', kind: TrKind.date),
          const TrField('is_current', 'Current Document', kind: TrKind.toggle),
          const TrField('file_url', 'Attachment', kind: TrKind.file, full: true, folder: 'transport/vehicle-docs'),
          const TrField('remarks', 'Remarks', kind: TrKind.multiline, full: true),
        ],
      ),
    );
  }

  Widget _vehiclesPanel() => TrPanel(
        key: ValueKey('vehicles-${_vendors.length}-${_devices.length}'),
        entity: 'vehicle',
        pk: 'vehicle_id',
        title: 'Vehicles',
        subtitle: 'The school\'s buses and vans.',
        icon: 'bus',
        noun: 'vehicle',
        deleteNote: 'The vehicle is marked Inactive and kept for past records. A vehicle used by a schedule cannot be deleted.',
        emptyWhy: 'Add your first vehicle.',
        onChanged: _loadVehicles,
        rowActions: [TrRowAction(icon: 'document-text', tooltip: 'Documents', onTap: _documents)],
        columns: [
          TrColumn('Code', flex: 2, text: (r) => trText(r['vehicle_code']), mono: true),
          TrColumn('Registration', flex: 3, text: (r) => trText(r['registration_no']), mono: true),
          TrColumn('Type', flex: 2, text: (r) => _label(_types, r['vehicle_type'])),
          const TrColumn('Seats', flex: 1, text: _seatsText),
          TrColumn('Ownership', flex: 2, text: (r) => _label(_ownership, r['ownership_type'])),
          TrColumn('Vendor', flex: 3, text: (r) => r['vendor_id'] == null ? '-' : _label(_vendors, trId(r['vendor_id']))),
          TrColumn('GPS Device', flex: 3, text: (r) => r['gps_device_id'] == null ? '-' : (_devices[trId(r['gps_device_id'])] ?? '-'), mono: true),
          TrColumn('Status', flex: 2, cell: (r) {
            final s = r['status'];
            return AppUI.chip(_label(_statuses, s), s == 'ACTIVE' ? AppStatus.success : (s == 'UNDER_REPAIR' ? AppStatus.warning : AppStatus.neutral));
          }),
        ],
        searchText: (r) => '${r['vehicle_code']} ${r['registration_no']} ${r['make']} ${r['model']}',
        newValues: (_) => const {
          'vehicle_type': 'BUS',
          'additional_capacity': 0,
          'ownership_type': 'OWNED',
          'status': 'ACTIVE',
          'has_gps': true,
          'has_first_aid': true,
          'has_fire_extinguisher': true,
        },
        fields: (_) => [
          const TrField('vehicle_code', 'Vehicle Code', kind: TrKind.upper, required: true, maxLength: 20, hint: 'e.g. BUS-07', section: 'Vehicle'),
          const TrField('registration_no', 'Registration Number', kind: TrKind.upper, required: true, maxLength: 20),
          const TrField('vehicle_type', 'Vehicle Type', kind: TrKind.choice, required: true, options: _types),
          const TrField('seating_capacity', 'Seating Capacity', kind: TrKind.integer, required: true),
          // small children: e.g. three on a two-seat bench is 1 more
          const TrField('additional_capacity', 'Additional Capacity', kind: TrKind.integer, maxLength: 3,
              hint: 'Extra small children, e.g. 3 on 2 seats = 1'),
          const TrField('permitted_capacity', 'Permitted Capacity', kind: TrKind.integer),
          const TrField('fuel_type', 'Fuel', kind: TrKind.choice, required: true, options: _fuels),
          const TrField('make', 'Make', maxLength: 50),
          const TrField('model', 'Model', maxLength: 50),
          const TrField('manufacture_year', 'Year of Manufacture', kind: TrKind.integer, maxLength: 4),
          const TrField('colour', 'Colour', maxLength: 20),
          const TrField('chassis_no', 'Chassis Number', kind: TrKind.upper, maxLength: 30),
          const TrField('engine_no', 'Engine Number', kind: TrKind.upper, maxLength: 30),
          const TrField('odometer_km', 'Odometer (km)', kind: TrKind.decimal),
          const TrField('status', 'Status', kind: TrKind.choice, required: true, options: _statuses),
          const TrField('ownership_type', 'Ownership', kind: TrKind.choice, required: true, options: _ownership, section: 'Ownership'),
          TrField('vendor_id', 'Vendor', kind: TrKind.choice, required: true, options: _vendors, visibleWhen: _notOwned),
          const TrField('contract_basis', 'Contract Basis', kind: TrKind.choice, options: _basis, visibleWhen: _notOwned),
          const TrField('contract_rate', 'Contract Rate', kind: TrKind.decimal, visibleWhen: _notOwned),
          const TrField('contract_from', 'Contract From', kind: TrKind.date, visibleWhen: _notOwned),
          const TrField('contract_to', 'Contract To', kind: TrKind.date, visibleWhen: _notOwned),
          TrField('purchase_date', 'Purchase Date', kind: TrKind.date, visibleWhen: (v) => !_notOwned(v)),
          TrField('purchase_cost', 'Purchase Cost', kind: TrKind.decimal, visibleWhen: (v) => !_notOwned(v)),
          // which GPS device is on the vehicle is set in the GPS Mapping tab
          const TrField('has_gps', 'GPS', kind: TrKind.toggle, section: 'Safety Fittings'),
          const TrField('has_cctv', 'CCTV', kind: TrKind.toggle),
          const TrField('has_speed_governor', 'Speed Governor', kind: TrKind.toggle),
          const TrField('has_first_aid', 'First Aid Box', kind: TrKind.toggle),
          const TrField('has_fire_extinguisher', 'Fire Extinguisher', kind: TrKind.toggle),
          const TrField('has_panic_button', 'Panic Button', kind: TrKind.toggle),
          const TrField('remarks', 'Remarks', kind: TrKind.multiline, full: true),
        ],
      );

  Widget _vendorsPanel() => TrPanel(
        key: const ValueKey('vendors'),
        entity: 'vendor',
        pk: 'vendor_id',
        title: 'Vendors',
        subtitle: 'Contractors who supply vehicles or staff.',
        icon: 'shop',
        noun: 'vendor',
        deleteNote: 'The vendor is switched off and kept for past records. A vendor with active vehicles or staff cannot be deleted.',
        emptyWhy: 'Add a vendor before adding a contracted, leased or hired vehicle.',
        onChanged: _loadVendors,
        columns: [
          TrColumn('Vendor', flex: 4, text: (r) => trText(r['vendor_name'])),
          TrColumn('Contact', flex: 3, text: (r) => trText(r['contact_person'])),
          TrColumn('Mobile', flex: 2, text: (r) => trText(r['mobile']), mono: true),
          TrColumn('GSTIN', flex: 3, text: (r) => trText(r['gstin']), mono: true),
          TrColumn('Agreement To', flex: 2, text: (r) => r['agreement_to'] == null ? '-' : formatDate(r['agreement_to'] as String?)),
          const TrColumn('Status', flex: 2, cell: trActiveChip),
        ],
        searchText: (r) => '${r['vendor_name']} ${r['contact_person']} ${r['mobile']} ${r['gstin']}',
        newValues: (_) => const {'is_active': true},
        fields: (_) => const [
          TrField('vendor_name', 'Vendor Name', required: true, maxLength: 150, section: 'Vendor'),
          TrField('contact_person', 'Contact Person', maxLength: 100),
          TrField('mobile', 'Mobile', kind: TrKind.mobile, maxLength: 15),
          TrField('email', 'Email', maxLength: 120),
          TrField('address', 'Address', kind: TrKind.multiline, full: true),
          TrField('gstin', 'GSTIN', kind: TrKind.upper, maxLength: 15, section: 'Tax & Bank'),
          TrField('pan', 'PAN', kind: TrKind.upper, maxLength: 10),
          TrField('bank_account_no', 'Bank Account Number', maxLength: 30),
          TrField('bank_ifsc', 'IFSC', kind: TrKind.upper, maxLength: 11),
          TrField('agreement_no', 'Agreement Number', maxLength: 50, section: 'Agreement'),
          TrField('agreement_from', 'Agreement From', kind: TrKind.date),
          TrField('agreement_to', 'Agreement To', kind: TrKind.date),
          TrField('is_active', 'Active', kind: TrKind.toggle),
        ],
      );

  Widget _devicesPanel() => TrPanel(
        key: const ValueKey('gps-devices'),
        entity: 'gps_device',
        pk: 'device_id',
        title: 'GPS Devices',
        subtitle: 'Trackers and phones that send vehicle locations. Put one on a vehicle in GPS Mapping.',
        icon: 'gps',
        noun: 'GPS device',
        deleteNote: 'The device is removed. A device that has been on a vehicle or has location history cannot be deleted; switch it off instead.',
        emptyWhy: 'Add a GPS tracker, then put it on a vehicle in GPS Mapping.',
        onChanged: _loadDevices,
        columns: [
          TrColumn('IMEI', flex: 3, text: (r) => trText(r['imei']), mono: true),
          TrColumn('Type', flex: 2, text: (r) => _label(_deviceTypes, r['device_type'])),
          TrColumn('SIM', flex: 2, text: (r) => trText(r['sim_no']), mono: true),
          TrColumn('Provider', flex: 2, text: (r) => trText(r['sim_provider'])),
          TrColumn('Supplier', flex: 3, text: (r) => trText(r['vendor_name'])),
          const TrColumn('Status', flex: 2, cell: trActiveChip),
        ],
        searchText: (r) => '${r['imei']} ${r['sim_no']} ${r['sim_provider']} ${r['vendor_name']}',
        newValues: (_) => const {'device_type': 'HARDWARE', 'is_active': true},
        fields: (_) => const [
          TrField('device_type', 'Device Type', kind: TrKind.choice, required: true, options: _deviceTypes, section: 'Device'),
          TrField('imei', 'IMEI', kind: TrKind.upper, maxLength: 20),
          TrField('sim_no', 'SIM Number', maxLength: 20),
          TrField('sim_provider', 'SIM Provider', maxLength: 30, hint: 'e.g. Airtel'),
          TrField('vendor_name', 'Supplier', maxLength: 100),
          TrField('protocol', 'Protocol', maxLength: 30, hint: 'e.g. GT06'),
          TrField('is_active', 'Active', kind: TrKind.toggle),
        ],
      );

  /// The services and repairs of the session's academic year, latest first
  /// (the server lists, saves and removes that year's records only).
  Widget _servicePanel() {
    final byId = {
      for (final v in _vehicles)
        if (trId(v['vehicle_id']) != null) trId(v['vehicle_id'])!: v,
    };
    String code(Map<String, dynamic> r) {
      final c = trText(byId[trId(r['vehicle_id'])]?['vehicle_code']);
      return c.isEmpty ? '-' : c;
    }

    return TrPanel(
      key: ValueKey('vehicle-service-${_vehicles.length}'),
      entity: 'vehicle_service',
      pk: 'service_id',
      title: 'Vehicle Service',
      subtitle: 'Services, repairs, tyres and batteries of the vehicles in this academic year, with their cost.',
      icon: 'setting',
      noun: 'service record',
      addBlockedReason: _vehicles.isEmpty ? 'Add a vehicle in the Vehicles tab first.' : null,
      deleteNote: 'This service record will be removed. This cannot be undone.',
      emptyWhy: 'Add each service or repair with its date, odometer reading, cost and when the next one is due.',
      columns: [
        TrColumn('Date', flex: 2, text: (r) => formatDate(r['service_date'] as String?)),
        TrColumn('Vehicle', flex: 2, text: code, mono: true),
        TrColumn('Service', flex: 3, text: (r) => _label(_serviceTypes, r['service_type'])),
        TrColumn('Workshop', flex: 3, text: (r) => trText(r['workshop']).isEmpty ? '-' : trText(r['workshop'])),
        TrColumn('Odometer', flex: 2, text: (r) => _km(r['odometer_km']), align: TextAlign.right),
        TrColumn('Amount', flex: 2, text: (r) => _amount(r['amount']), mono: true, align: TextAlign.right),
        TrColumn('Downtime', flex: 2, text: (r) => _days(r['downtime_days'])),
        const TrColumn('Next Due', flex: 3, text: _nextDue),
      ],
      searchText: (r) => '${code(r)} ${trText(byId[trId(r['vehicle_id'])]?['registration_no'])} '
          '${_label(_serviceTypes, r['service_type'])} ${trText(r['workshop'])} ${trText(r['description'])}',
      newValues: (_) => {'service_type': 'PERIODIC', 'service_date': DateTime.now().toIso8601String().substring(0, 10)},
      fields: (_) => [
        // vehicles in use, and the record's own vehicle whatever its status
        TrField('vehicle_id', 'Vehicle', kind: TrKind.choice, required: true, section: 'Service',
            optionsFor: (v) => [
                  for (final x in _vehicles)
                    if (x['status'] == 'ACTIVE' || x['status'] == 'UNDER_REPAIR' || trId(x['vehicle_id']) == trId(v['vehicle_id']))
                      (trId(x['vehicle_id']), '${trText(x['vehicle_code'])} · ${trText(x['registration_no'])}'),
                ]),
        const TrField('service_type', 'Service Type', kind: TrKind.choice, required: true, options: _serviceTypes),
        const TrField('service_date', 'Service Date', kind: TrKind.date, required: true),
        const TrField('odometer_km', 'Odometer (km)', kind: TrKind.decimal),
        const TrField('workshop', 'Workshop', maxLength: 120, hint: 'Garage or service centre'),
        const TrField('amount', 'Amount', kind: TrKind.decimal),
        const TrField('downtime_days', 'Downtime (days)', kind: TrKind.integer, maxLength: 3, hint: 'Days the vehicle was off the road'),
        const TrField('next_due_date', 'Next Due Date', kind: TrKind.date, section: 'Next Service'),
        const TrField('next_due_km', 'Next Due (km)', kind: TrKind.decimal),
        const TrField('description', 'Work Done', kind: TrKind.multiline, full: true, hint: 'Parts changed, work done, bill number'),
      ],
    );
  }

  /// The fuel fills and charges of the session's academic year, latest first
  /// (they are kept in that year's own records, so another year does not see
  /// them). An empty amount is worked out on the server as quantity x rate.
  Widget _fuelPanel() {
    final byId = {
      for (final v in _vehicles)
        if (trId(v['vehicle_id']) != null) trId(v['vehicle_id'])!: v,
    };
    final staffById = {
      for (final s in _staff)
        if (trId(s['staff_id']) != null) trId(s['staff_id'])!: s,
    };
    Map<String, dynamic>? vehicle(Map<String, dynamic> r) => byId[trId(r['vehicle_id'])];
    String code(Map<String, dynamic> r) {
      final c = trText(vehicle(r)?['vehicle_code']);
      return c.isEmpty ? '-' : c;
    }

    String filledBy(Map<String, dynamic> r) {
      final n = trText(staffById[trId(r['filled_by_staff_id'])]?['full_name']);
      return n.isEmpty ? '-' : n;
    }

    /// The fuel of the entry's vehicle, as set on the vehicle (tr_vehicle.fuel_type).
    String fuel(Map<String, dynamic> r) {
      final f = vehicle(r)?['fuel_type'];
      return f == null ? '' : _label(_fuels, f);
    }

    return TrPanel(
      key: ValueKey('fuel-log-${_vehicles.length}-${_staff.length}'),
      entity: 'fuel_log',
      pk: 'fuel_log_id',
      title: 'Fuel Log',
      subtitle: 'Fuel fills and charging of the vehicles in this academic year, with their cost.',
      icon: 'gas-station',
      noun: 'fuel entry',
      addBlockedReason: _vehicles.isEmpty ? 'Add a vehicle in the Vehicles tab first.' : null,
      deleteNote: 'This fuel entry will be removed. This cannot be undone.',
      emptyWhy: 'Add each fill with its date, quantity, amount and odometer reading.',
      columns: [
        TrColumn('Date', flex: 2, text: (r) => formatDate(r['fill_date'] as String?)),
        TrColumn('Vehicle', flex: 2, text: code, mono: true),
        TrColumn('Fuel', flex: 2, text: (r) => fuel(r).isEmpty ? '-' : fuel(r)),
        TrColumn('Quantity', flex: 2, text: (r) => _qty(r['quantity'], vehicle(r)), align: TextAlign.right),
        TrColumn('Rate', flex: 2, text: (r) => _amount(r['rate']), mono: true, align: TextAlign.right),
        TrColumn('Amount', flex: 2, text: (r) => _amount(r['amount']), mono: true, align: TextAlign.right),
        TrColumn('Odometer', flex: 2, text: (r) => _km(r['odometer_km']), align: TextAlign.right),
        TrColumn('Bill No', flex: 2, text: (r) => trText(r['bill_no']).isEmpty ? '-' : trText(r['bill_no']), mono: true),
        TrColumn('Filled By', flex: 3, text: filledBy),
      ],
      searchText: (r) => '${code(r)} ${trText(vehicle(r)?['registration_no'])} ${fuel(r)} ${trText(r['bill_no'])} ${filledBy(r)}',
      newValues: (_) => {'fill_date': DateTime.now().toIso8601String().substring(0, 10)},
      fields: (_) => [
        // vehicles in use, and the entry's own vehicle whatever its status
        TrField('vehicle_id', 'Vehicle', kind: TrKind.choice, required: true, section: 'Fuel Fill',
            optionsFor: (v) => [
                  for (final x in _vehicles)
                    if (x['status'] == 'ACTIVE' || x['status'] == 'UNDER_REPAIR' || trId(x['vehicle_id']) == trId(v['vehicle_id']))
                      (trId(x['vehicle_id']), '${trText(x['vehicle_code'])} · ${trText(x['registration_no'])}'),
                ]),
        // shown from the chosen vehicle; not part of the fuel entry
        TrField('vehicle_fuel', 'Fuel', kind: TrKind.display, hint: 'Choose the vehicle', displayFor: fuel),
        const TrField('fill_date', 'Fill Date', kind: TrKind.date, required: true),
        const TrField('quantity', 'Quantity', kind: TrKind.decimal, required: true, hint: 'Litres, or kWh for an electric vehicle'),
        const TrField('rate', 'Rate', kind: TrKind.decimal, hint: 'Per litre or kWh'),
        const TrField('amount', 'Amount', kind: TrKind.decimal, hint: 'As on the bill; left empty, quantity x rate'),
        const TrField('odometer_km', 'Odometer (km)', kind: TrKind.decimal),
        const TrField('bill_no', 'Bill Number', maxLength: 40),
        // active staff, and the entry's own staff member whatever their status
        TrField('filled_by_staff_id', 'Filled By', kind: TrKind.choice,
            optionsFor: (v) => [
                  for (final s in _staff)
                    if (s['status'] == 'ACTIVE' || trId(s['staff_id']) == trId(v['filled_by_staff_id']))
                      (trId(s['staff_id']), '${trText(s['full_name'])} · ${trText(s['staff_code'])}'),
                ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppUI.card(),
      padding: EdgeInsets.all(AppUI.cardPad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          PillTab(icon: 'bus', label: 'Vehicles', selected: _tab == _tabVehicles, onTap: () => _goTo(_tabVehicles)),
          SizedBox(width: PillTab.gap(context)),
          PillTab(icon: 'shop', label: 'Vendors', selected: _tab == _tabVendors, onTap: () => _goTo(_tabVendors)),
          SizedBox(width: PillTab.gap(context)),
          PillTab(icon: 'setting', label: 'Service', selected: _tab == _tabService, onTap: () => _goTo(_tabService)),
          SizedBox(width: PillTab.gap(context)),
          PillTab(icon: 'gas-station', label: 'Fuel', selected: _tab == _tabFuel, onTap: () => _goTo(_tabFuel)),
          SizedBox(width: PillTab.gap(context)),
          PillTab(icon: 'gps', label: 'GPS Devices', selected: _tab == _tabDevices, onTap: () => _goTo(_tabDevices)),
          SizedBox(width: PillTab.gap(context)),
          PillTab(icon: 'link', label: 'GPS Mapping', selected: _tab == _tabMapping, onTap: () => _goTo(_tabMapping)),
        ]),
        SizedBox(height: 14.h),
        Expanded(
          child: switch (_tab) {
            _tabVehicles => _vehiclesPanel(),
            _tabDevices => _devicesPanel(),
            _tabMapping => GpsMappingPanel(key: const ValueKey('gps-mapping'), onDirtyChanged: (d) => _mappingDirty = d),
            _tabService => _servicePanel(),
            _tabFuel => _fuelPanel(),
            _ => _vendorsPanel(),
          },
        ),
      ]),
    );
  }
}
