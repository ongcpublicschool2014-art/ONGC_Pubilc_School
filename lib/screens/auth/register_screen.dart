import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/app_theme.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../utils/friendly_error.dart';
class RegisterScreen extends StatefulWidget {
  final VoidCallback? onRegistered;
  final Map<String, dynamic>? editInstitution; // when set, the wizard edits this institution
  const RegisterScreen({super.key, this.onRegistered, this.editInstitution});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final PageController _pageController = PageController();
  int _currentStep = 0;
  final _formKeys = [GlobalKey<FormState>(), GlobalKey<FormState>(), GlobalKey<FormState>()];

  // Step 1: Institution Info
  String? _institutionType;
  String _institutionRecognized = 'Yes';
  DateTime? _institutionStartDate;
  File? _logoFile;
  final _institutionNameController = TextEditingController();
  final _institutionShortNameController = TextEditingController();
  final _institutionCodeController = TextEditingController();
  final _authorizedUsernameController = TextEditingController();
  final _designationController = TextEditingController();
  final _mobileNumberController = TextEditingController();
  final _activationCodeController = TextEditingController();

  final List<String> _institutionTypes = [
    'Schools (Primary, Secondary, Higher Secondary)',
    'Colleges',
    'Universities',
    'Polytechnic Institutions',
    'Vocational Training Centers',
    'Coaching Institutes',
  ];

  // Step 2: Affiliation & Address
  DateTime? _affiliationStartYear;
  final _affiliationController = TextEditingController();
  final _affiliationNumberController = TextEditingController();
  final _address1Controller = TextEditingController();
  final _address2Controller = TextEditingController();
  final _address3Controller = TextEditingController();
  final _pinCodeController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _countryController = TextEditingController();
  final _emailController = TextEditingController();

  // Academic Year
  final _yearLabelController = TextEditingController();
  DateTime? _yearStartDate;
  DateTime? _yearEndDate;

  // Step 3: Account Setup
  String _adminDesignation = 'Principal';
  final List<String> _designationOptions = [
    'Principal', 'Vice Principal', 'Director', 'Chairman',
    'Head Master', 'Administrator', 'Manager',
  ];
  final _adminNameController = TextEditingController();
  final _adminEmailController = TextEditingController();
  final _adminPhoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  DateTime? _adminDob;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isCreating = false;
  bool _requestingCode = false;
  bool _validatingCode = false;
  // null = not checked yet, true = verified against license_keys, false = rejected.
  bool? _codeValidated;
  String? _codeValidationMsg;
  // Snapshot of the code text at the moment validation succeeded — re-typing
  // any character invalidates the verified state so a tampered code can't
  // bypass the gate.
  String _validatedCodeSnapshot = '';

  bool get _editMode => widget.editInstitution != null;

  /// True while the edit-mode prefill is still fetching. The form is blocked
  /// during it: _loadForEdit writes the controllers only after two awaited
  /// queries, so anything typed before they land was silently overwritten —
  /// which reads as "the field won't let me type".
  bool _editLoading = false;

  @override
  void initState() {
    super.initState();
    if (_editMode) _loadForEdit();
  }

  /// Edit mode: load the institution's full row and prefill steps 1 & 2.
  Future<void> _loadForEdit() async {
    setState(() => _editLoading = true);
    final insId = widget.editInstitution!['ins_id'];
    Map<String, dynamic> m = Map<String, dynamic>.from(widget.editInstitution!);
    try {
      final row = await SupabaseService.client.from('institution').select().eq('ins_id', insId).maybeSingle();
      if (row != null) m = Map<String, dynamic>.from(row);
    } catch (e) {
      debugPrint('load for edit error: $e');
    }
    if (!mounted) return;
    setState(() {
      _institutionNameController.text = m['insname']?.toString() ?? '';
      _institutionShortNameController.text = m['inshortname']?.toString() ?? '';
      _institutionCodeController.text = m['inscode']?.toString() ?? '';
      _authorizedUsernameController.text = m['insautusername']?.toString() ?? '';
      _designationController.text = m['insdesignation']?.toString() ?? '';
      _mobileNumberController.text = m['insmobno']?.toString() ?? '';
      _emailController.text = m['insmail']?.toString() ?? '';
      _affiliationController.text = m['insaffliation']?.toString() ?? '';
      _affiliationNumberController.text = m['insaffno']?.toString() ?? '';
      _cityController.text = m['inscity']?.toString() ?? '';
      _stateController.text = m['insstate']?.toString() ?? '';
      _countryController.text = m['inscountry']?.toString() ?? '';
      _pinCodeController.text = m['inspincode']?.toString() ?? '';

      // These were missing, which is why Address Line 1 and the rest came up
      // blank in edit mode — and, because Address Line 1 is required, why
      // Update Institution then failed validation and would not save.
      _address1Controller.text = m['insaddress1']?.toString() ?? '';
      _address2Controller.text = m['insaddress2']?.toString() ?? '';
      _address3Controller.text = m['insaddress3']?.toString() ?? '';

      _institutionRecognized =
          (m['insrecognised']?.toString().toUpperCase() == 'Y') ? 'Yes' : 'No';

      // it_id -> the display name the dropdown holds.
      const idToType = {
        1: 'Schools (Primary, Secondary, Higher Secondary)',
        2: 'Colleges',
        3: 'Universities',
        4: 'Polytechnic Institutions',
        5: 'Vocational Training Centers',
        6: 'Coaching Institutes',
      };
      final itId = (m['it_id'] as num?)?.toInt();
      _institutionType = itId == null ? null : idToType[itId];

      final affYear = int.tryParse((m['insaffstayear'] ?? '').toString().trim());
      _affiliationStartYear = affYear == null ? null : DateTime(affYear);

      // Institution Start Date — also missing, so the field read "Select date"
      // on a record that has one.
      _institutionStartDate =
          DateTime.tryParse(m['insstadate']?.toString() ?? '');
    });
    await _loadAcademicYearForEdit(insId);
    if (mounted) setState(() => _editLoading = false);
  }

  /// The academic year lives in public.institutionyear, not institution, so the
  /// full-row fetch above never sees it. Without this the Year Label / Start /
  /// End fields stay empty and — Year Label being required — block the save.
  Future<void> _loadAcademicYearForEdit(dynamic insId) async {
    try {
      final row = await SupabaseService.client
          .from('institutionyear')
          .select('yrlabel, iyrstadate, iyrenddate')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('iyrstadate', ascending: false)
          .limit(1)
          .maybeSingle();
      if (row == null || !mounted) return;
      setState(() {
        _yearLabelController.text = row['yrlabel']?.toString() ?? '';
        _yearStartDate = DateTime.tryParse(row['iyrstadate']?.toString() ?? '');
        _yearEndDate = DateTime.tryParse(row['iyrenddate']?.toString() ?? '');
      });
    } catch (e) {
      debugPrint('load academic year for edit error: $e');
    }
  }

  /// Edit mode: update the institution's descriptive columns (no schema/admin).
  Future<void> _updateInstitution() async {
    final ok0 = _formKeys[0].currentState?.validate() ?? true;
    final ok1 = _formKeys[1].currentState?.validate() ?? true;
    if (!ok0) { _goToStep(0); return; }
    if (!ok1) { _goToStep(1); return; }
    setState(() => _isCreating = true);
    try {
      // institution has RLS (SELECT-only for anon) → write via SECURITY DEFINER RPC.
      await SupabaseService.client.rpc('admin_update_institution', params: {
        'p_ins_id': widget.editInstitution!['ins_id'],
        'p_patch': {
          'insname': _institutionNameController.text.trim(),
          'inshortname': _institutionShortNameController.text.trim(),
          'inscode': _institutionCodeController.text.trim(),
          'insautusername': _authorizedUsernameController.text.trim(),
          'insdesignation': _designationController.text.trim(),
          'insmobno': _mobileNumberController.text.trim(),
          'insmail': _emailController.text.trim(),
          'insaffliation': _affiliationController.text.trim(),
          'insaffno': _affiliationNumberController.text.trim(),
          'inscity': _cityController.text.trim(),
          'insstate': _stateController.text.trim(),
          'inscountry': _countryController.text.trim(),
          'inspincode': _pinCodeController.text.trim(),
          // Previously unsaved, so an edit silently dropped them.
          'insaddress1': _address1Controller.text.trim(),
          'insaddress2': _address2Controller.text.trim(),
          'insaddress3': _address3Controller.text.trim(),
          'insrecognised': _institutionRecognized == 'Yes' ? 'Y' : 'N',
          if (_institutionType != null)
            'it_id': const {
              'Schools (Primary, Secondary, Higher Secondary)': 1,
              'Colleges': 2,
              'Universities': 3,
              'Polytechnic Institutions': 4,
              'Vocational Training Centers': 5,
              'Coaching Institutes': 6,
            }[_institutionType!],
          if (_affiliationStartYear != null)
            'insaffstayear': _affiliationStartYear!.year.toString(),
          'updatedby': 'SUPERADMIN',
        },
      });

      // The academic year is deliberately NOT written back: it is read-only in
      // edit mode, because the tenant schema name embeds it and every demand,
      // receipt and report is keyed to it. Changing it here would silently
      // point the institution at a year its data doesn't live in.
      if (!mounted) return;
      setState(() => _isCreating = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Institution updated'), backgroundColor: AppColors.success));
      widget.onRegistered?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _isCreating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: $e'), backgroundColor: AppColors.error));
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _institutionNameController.dispose();
    _institutionShortNameController.dispose();
    _institutionCodeController.dispose();
    _authorizedUsernameController.dispose();
    _designationController.dispose();
    _mobileNumberController.dispose();
    _activationCodeController.dispose();
    _affiliationController.dispose();
    _affiliationNumberController.dispose();
    _address1Controller.dispose();
    _address2Controller.dispose();
    _address3Controller.dispose();
    _pinCodeController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _countryController.dispose();
    _emailController.dispose();
    _yearLabelController.dispose();
    _adminNameController.dispose();
    _adminEmailController.dispose();
    _adminPhoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _goToStep(int step) {
    _pageController.animateToPage(step, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    setState(() => _currentStep = step);
  }

  /// Validate the form for [step] and return whether it passed. Used by the
  /// Next button and the milestone-progress chevron taps so we don't let
  /// the user advance over a step with required fields still empty.
  bool _validateStep(int step) {
    if (step < 0 || step >= _formKeys.length) return true;
    return _formKeys[step].currentState?.validate() ?? true;
  }

  /// Wipe every text field and step state so the form is back to its
  /// freshly-mounted appearance. Called after a successful institution
  /// creation so the super admin can register the next one without
  /// stale values bleeding over.
  void _resetForm() {
    _institutionNameController.clear();
    _institutionShortNameController.clear();
    _institutionCodeController.clear();
    _authorizedUsernameController.clear();
    _designationController.clear();
    _mobileNumberController.clear();
    _activationCodeController.clear();
    _affiliationController.clear();
    _affiliationNumberController.clear();
    _address1Controller.clear();
    _address2Controller.clear();
    _address3Controller.clear();
    _pinCodeController.clear();
    _cityController.clear();
    _stateController.clear();
    _countryController.clear();
    _emailController.clear();
    _yearLabelController.clear();
    _adminNameController.clear();
    _adminEmailController.clear();
    _adminPhoneController.clear();
    _passwordController.clear();
    _confirmPasswordController.clear();
    setState(() {
      _institutionType = null;
      _institutionRecognized = 'Yes';
      _institutionStartDate = null;
      _affiliationStartYear = null;
      _yearStartDate = null;
      _yearEndDate = null;
      _adminDob = null;
      _adminDesignation = 'Principal';
      _logoFile = null;
      _logoFileName = null;
      _obscurePassword = true;
      _obscureConfirm = true;
      // Each step has its own form key, so just reset their internal state.
      for (final k in _formKeys) {
        k.currentState?.reset();
      }
    });
    // Snap back to step 1.
    _pageController.jumpToPage(0);
    setState(() => _currentStep = 0);
  }

  String? _logoFileName;

  Future<void> _pickLogo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
    );
    if (result != null && result.files.single.path != null) {
      final file = result.files.single;
      final ext = file.extension?.toLowerCase() ?? '';
      if (!['png', 'jpg', 'jpeg'].contains(ext)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Only PNG, JPG, JPEG formats are allowed'), backgroundColor: AppColors.error),
          );
        }
        return;
      }
      setState(() {
        _logoFile = File(file.path!);
        _logoFileName = file.name;
      });
    }
  }

  /// Send a new-institution activation request to the office via the
  /// `request-activation-code` Edge Function. The office sees the institution
  /// name + email and replies with a code the super-admin pastes back into
  /// the Activation Code field.
  Future<void> _requestActivationCode() async {
    final insName = _institutionNameController.text.trim();
    final email = _emailController.text.trim();
    final messenger = ScaffoldMessenger.of(context);

    if (insName.isEmpty || email.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Enter Institution Name and Email first, then request a code.'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    setState(() => _requestingCode = true);
    try {
      await SupabaseService.client.functions.invoke(
        'request-activation-code',
        body: {
          'purpose': 'register',
          'insName': insName,
          'inscode': _institutionCodeController.text.trim(),
          'contact': _authorizedUsernameController.text.trim(),
          'mobile': _mobileNumberController.text.trim(),
          'email': email,
        },
      );
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Request sent. The office will email you an activation code shortly.'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not send request. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _requestingCode = false);
    }
  }

  Future<void> _validateActivationCode() async {
    final code = _activationCodeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _codeValidated = false;
        _codeValidationMsg = 'Enter the activation code first';
      });
      return;
    }
    setState(() {
      _validatingCode = true;
      _codeValidationMsg = null;
    });
    try {
      final result = await SupabaseService.verifyLicenseKey(code);
      final ok = result['valid'] == true;
      if (!mounted) return;
      setState(() {
        _validatingCode = false;
        _codeValidated = ok;
        _codeValidationMsg = (result['message'] as String?) ?? (ok ? 'Activation code verified' : 'Invalid activation code');
        _validatedCodeSnapshot = ok ? code : '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _validatingCode = false;
        _codeValidated = false;
        _codeValidationMsg = friendlyError(e);
        _validatedCodeSnapshot = '';
      });
    }
  }

  Future<void> _handleRegister() async {
    if (!_formKeys[2].currentState!.validate()) return;

    if (_passwordController.text != _confirmPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match'), backgroundColor: AppColors.error),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      final itIdMap = {
        'Schools (Primary, Secondary, Higher Secondary)': 1,
        'Colleges': 2,
        'Universities': 3,
        'Polytechnic Institutions': 4,
        'Vocational Training Centers': 5,
        'Coaching Institutes': 6,
      };

      final yrLabel = _yearLabelController.text.trim().isNotEmpty
          ? _yearLabelController.text.trim()
          : '${DateTime.now().year}-${DateTime.now().year + 1}';
      final yrStaDate = _yearStartDate ?? DateTime(DateTime.now().year, 6, 1);
      final yrEndDate = _yearEndDate ?? DateTime(DateTime.now().year + 1, 5, 31);

      // Single atomic RPC call — creates institution rows AND schema in one
      // transaction. If validation fails or schema creation errors out, the
      // database rolls back every insert so no partial data is left behind.
      // The activation code is required: register_institution validates the
      // hash against license_keys (status='used', not 'revoked') and rejects
      // the call if it doesn't match.
      final result = await SupabaseService.client.rpc('register_institution', params: {
        'p_license_key': _activationCodeController.text.trim(),
        'p_insname': _institutionNameController.text.trim(),
        'p_inscode': _institutionCodeController.text.trim(),
        'p_inshortname': _institutionShortNameController.text.trim(),
        'p_insstadate': (_institutionStartDate ?? DateTime.now()).toIso8601String().split('T').first,
        'p_insautusername': _authorizedUsernameController.text.trim(),
        'p_insdesignation': _designationController.text.trim().isNotEmpty ? _designationController.text.trim() : 'Principal',
        'p_insmobno': _mobileNumberController.text.trim(),
        'p_insmail': _emailController.text.trim(),
        'p_it_id': itIdMap[_institutionType] ?? 1,
        'p_insrecognised': _institutionRecognized == 'Yes' ? 'Y' : 'N',
        'p_insaffliation': _affiliationController.text.trim(),
        'p_insaffno': _affiliationNumberController.text.trim(),
        'p_insaffstayear': _affiliationStartYear?.year.toString() ?? '',
        'p_insaddress1': _address1Controller.text.trim(),
        'p_insaddress2': _address2Controller.text.trim(),
        'p_insaddress3': _address3Controller.text.trim(),
        'p_inscity': _cityController.text.trim(),
        'p_insstate': _stateController.text.trim(),
        'p_inscountry': _countryController.text.trim(),
        'p_inspincode': _pinCodeController.text.trim(),
        'p_yrlabel': yrLabel,
        'p_yrstadate': yrStaDate.toIso8601String().split('T').first,
        'p_yrenddate': yrEndDate.toIso8601String().split('T').first,
        'p_adminname': _adminNameController.text.trim(),
        'p_adminemail': _adminEmailController.text.trim(),
        'p_adminphone': _adminPhoneController.text.trim(),
        'p_adminpassword': _passwordController.text,
        'p_admindob': _adminDob != null ? _adminDob!.toIso8601String().split('T').first : '2000-01-01',
        'p_admindesignation': _adminDesignation,
      });

      final regResult = result is Map ? result : (result is List && result.isNotEmpty ? result.first : null);
      if (regResult == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Registration failed'), backgroundColor: AppColors.error),
          );
          setState(() => _isCreating = false);
        }
        return;
      }

      final schemaName = regResult['schema']?.toString() ?? '';
      debugPrint('Registered ins_id=${regResult['ins_id']}, schema="$schemaName"');

      // Try to expose schema to API (best-effort — fails silently on free tier)
      if (schemaName.isNotEmpty) {
        try {
          await SupabaseService.client.rpc('expose_schema', params: {
            'p_schema': schemaName,
          });
          debugPrint('Schema "$schemaName" exposed to API');
        } catch (e) {
          debugPrint('expose_schema skipped (run manually in SQL Editor): $e');
        }
      }

      // Create the per-institution student photo bucket. Runs via a
      // SECURITY DEFINER RPC so anon can trigger it. Failure used to
      // only debugPrint, which made the missing bucket invisible until
      // someone tried to upload a photo months later. Now we surface it
      // to the super admin via a snackbar so they can re-run the RPC
      // manually if Supabase rejected the call.
      if (regResult['inscode'] != null) {
        try {
          await SupabaseService.client.rpc('ensure_student_photo_bucket', params: {
            'p_inscode': regResult['inscode'].toString(),
          });
          debugPrint('Photo bucket ready for inscode=${regResult['inscode']}');
        } catch (e) {
          debugPrint('ensure_student_photo_bucket failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Institution created, but student photo bucket setup failed: $e\n'
                  'Run: SELECT public.ensure_student_photo_bucket(\'${regResult['inscode']}\') in Supabase SQL Editor.',
                ),
                backgroundColor: AppColors.warning,
                duration: const Duration(seconds: 10),
              ),
            );
          }
        }
      }

      // Upload logo if selected
      if (_logoFile != null && regResult['inscode'] != null) {
        try {
          final inscode = regResult['inscode'].toString();
          final ext = _logoFile!.path.split('.').last.toLowerCase();
          final path = 'logos/$inscode.$ext';
          await SupabaseService.client.storage.from('InstitutionLogos').upload(
            path,
            _logoFile!,
            fileOptions: const FileOptions(upsert: true),
          );
          final logoUrl = SupabaseService.client.storage.from('InstitutionLogos').getPublicUrl(path);
          await SupabaseService.client.from('institution').update({'inslogo': logoUrl}).eq('ins_id', regResult['ins_id']);
          debugPrint('Logo uploaded: $logoUrl');
        } catch (e) {
          debugPrint('Logo upload failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Institution created, but logo upload failed. ${friendlyError(e)}'),
                backgroundColor: AppColors.warning,
                duration: const Duration(seconds: 6),
              ),
            );
          }
        }
      }

      // Show success and reset the form so the next institution starts
      // from a blank slate instead of the previous one's data.
      if (mounted) {
        setState(() => _isCreating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Institution created successfully!'), backgroundColor: AppColors.success),
        );
        _resetForm();
        widget.onRegistered?.call();
      }
    } catch (e) {
      debugPrint('Registration error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
        setState(() => _isCreating = false);
      }
    }
  }

  Future<void> _pickInstitutionStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _institutionStartDate ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _institutionStartDate = picked);
  }

  Future<void> _pickAffiliationStartYear() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _affiliationStartYear ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      helpText: 'Select Affiliation Start Year',
    );
    if (picked != null) setState(() => _affiliationStartYear = DateTime(picked.year));
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    // Block interaction until the edit prefill has landed, so a keystroke
    // can't be overwritten by the fetch completing a moment later.
    if (_editMode && _editLoading) {
      return Container(
        color: AppColors.surface,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          // Milestone progress bar
          _buildMilestoneProgress(context),

          // Page slider
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _currentStep = i),
              children: _editMode
                  ? [_buildStep1(), _buildStep2()]
                  : [_buildStep1(), _buildStep2(), _buildStep3()],
            ),
          ),

          // Bottom navigation
          Padding(
            padding: EdgeInsets.fromLTRB(32.w, 0, 32.w, 16.h),
            child: Row(
              children: [
                if (_currentStep > 0)
                  OutlinedButton.icon(
                    onPressed: () => _goToStep(_currentStep - 1),
                    icon: AppIcon.linear('Chevron Left', size: 18),
                    label: const Text('Previous'),
                  ),
                const Spacer(),
                if (_currentStep < (_editMode ? 1 : 2))
                  ElevatedButton.icon(
                    onPressed: () {
                      if (_validateStep(_currentStep)) _goToStep(_currentStep + 1);
                    },
                    icon: const Text('Next'),
                    label: AppIcon.linear('Chevron Right', size: 18),
                  )
                else if (_editMode)
                  ElevatedButton.icon(
                    onPressed: _isCreating ? null : _updateInstitution,
                    icon: _isCreating
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check, size: 18),
                    label: Text(_isCreating ? 'Updating…' : 'Update Institution'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMilestoneProgress(BuildContext context) {
    final steps = [
      {'icon': 'building', 'label': 'Institution Info'},
      {'icon': 'location', 'label': 'Affiliation & Address'},
      if (!_editMode) {'icon': 'lock', 'label': 'Account Setup'},
    ];

    Color stateColor(int stepIndex) {
      if (stepIndex < _currentStep) return AppColors.success;
      if (stepIndex == _currentStep) return AppColors.primary;
      return AppColors.textSecondary.withValues(alpha: 0.4);
    }

    final isMobile = MediaQuery.of(context).size.width < 600;
    final circleSize = isMobile ? 36.0 : 40.0;
    final iconSize = isMobile ? 18.0 : 20.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(isMobile ? 16 : 32.w, 20.h, isMobile ? 16 : 32.w, 8.h),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24.w, vertical: 16),
        decoration: AppUI.card(),
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(steps.length * 2 - 1, (index) {
          if (index.isOdd) {
            final stepBefore = index ~/ 2;
            final isDone = stepBefore < _currentStep;
            final isActiveSegment = stepBefore == _currentStep - 1 || stepBefore == _currentStep;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: circleSize / 2 - 1.5),
                child: Container(
                  height: 3,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: isDone
                        ? AppColors.success
                        : isActiveSegment
                            ? AppColors.primary.withValues(alpha: 0.4)
                            : AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            );
          }

          final stepIndex = index ~/ 2;
          final step = steps[stepIndex];
          final isActive = stepIndex == _currentStep;
          final isDone = stepIndex < _currentStep;
          final color = stateColor(stepIndex);

          return GestureDetector(
            onTap: () {
              // Backward (or same) jumps go through immediately.
              if (stepIndex <= _currentStep) {
                _goToStep(stepIndex);
                return;
              }
              // Forward jumps must validate every step in between.
              for (int s = _currentStep; s < stepIndex; s++) {
                if (!_validateStep(s)) return;
              }
              _goToStep(stepIndex);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Circle with icon
                Container(
                  width: circleSize,
                  height: circleSize,
                  decoration: BoxDecoration(
                    color: isDone || isActive ? color : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color,
                      width: isActive ? 2 : 1.5,
                    ),
                  ),
                  child: Center(
                    child: isDone
                        ? AppIcon('tick-circle', size: iconSize, color: Colors.white)
                        : AppIcon(
                            step['icon'] as String,
                            size: iconSize,
                            color: isActive ? Colors.white : color,
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'STEP ${stepIndex + 1}',
                  style: AppUI.caps,
                ),
                const SizedBox(height: 2),
                Text(
                  isMobile ? (step['label'] as String).split(' ').first : step['label'] as String,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppUI.label.copyWith(
                    fontSize: isMobile ? 12 : null,
                    color: isActive || isDone ? AppColors.textPrimary : AppColors.textLight,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
      ),
    );
  }

  // Step 1: Institution Information
  Widget _buildStep1() {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 32.w, vertical: 20.h),
      child: Container(
        padding: EdgeInsets.all(isMobile ? 16 : AppUI.cardPad),
        decoration: AppUI.card(),
        child: Form(
          key: _formKeys[0],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppUI.cardHeader(
                icon: 'building',
                title: 'Institution Information',
                subtitle: 'Enter the basic details about your institution',
              ),
              SizedBox(height: 20.h),

              _formRow(context, [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Institution Type'),
                  SizedBox(
                    height: AppUI.controlHeight(context),
                    child: DropdownButtonFormField<String>(
                      initialValue: _institutionType,
                      isExpanded: true,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      decoration: _inputDec('Select institution type', filled: _institutionType != null),
                      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textLight),
                      style: AppUI.fieldText(context),
                      items: _institutionTypes.map((t) => DropdownMenuItem(value: t, child: Text(t, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context)))).toList(),
                      selectedItemBuilder: (context) => _institutionTypes.map((t) => Align(alignment: Alignment.centerLeft, child: Text(t, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context)))).toList(),
                      onChanged: (v) => setState(() => _institutionType = v),
                    ),
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Institution Name *'),
                  TextFormField(
                    controller: _institutionNameController,
                    decoration: _inputDec('Enter institution name', filled: _institutionNameController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                    style: _fieldStyleFilled(_institutionNameController.text.trim().isNotEmpty),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (_) => setState(() {}),
                    validator: (v) => _vRequiredMax(v, 80, 'Institution name'),
                  ),
                ]),
              ]),
              SizedBox(height: 16.h),

              // Logo picker + Short Name + Institution Code
              _formRow(context, [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Institution Logo'),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _pickLogo,
                        borderRadius: BorderRadius.circular(AppUI.controlRadius),
                        child: Container(
                          height: AppUI.controlHeight(context),
                          padding: EdgeInsets.symmetric(horizontal: 14.w),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(AppUI.controlRadius),
                            border: Border.all(color: _logoFile != null ? AppColors.primary.withValues(alpha: 0.55) : AppColors.border),
                          ),
                          child: _logoFile != null
                              ? Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(_logoFile!, width: 36, height: 36, fit: BoxFit.cover),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text('Change',
                                          style: AppUI.fieldText(context)),
                                    ),
                                    AppIcon('edit-2', size: 16, color: AppColors.primary),
                                  ],
                                )
                              : Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(7),
                                      decoration: BoxDecoration(
                                        color: AppColors.primaryLight,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: AppIcon.linear('camera', size: 16, color: AppColors.primary),
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text('Upload Logo',
                                          overflow: TextOverflow.ellipsis,
                                          style: AppUI.fieldText(context).copyWith(color: AppColors.textLight)),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Short Name *'),
                  TextFormField(
                    controller: _institutionShortNameController,
                    // Locked once the institution exists — see _lockedInEdit.
                    readOnly: _editMode,
                    enabled: !_editMode,
                    decoration: _inputDec('e.g. KCET', filled: _institutionShortNameController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                    style: _fieldStyleFilled(_institutionShortNameController.text.trim().isNotEmpty),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (_) => setState(() {}),
                    validator: _editMode ? null : (v) => _vRequiredMax(v, 30, 'Short name'),
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Institution Code *'),
                  TextFormField(
                    // Locked in edit mode: inscode is what the tenant schema
                    // name is derived from, so changing it after creation
                    // would orphan that institution's whole schema.
                    readOnly: _editMode,
                    enabled: !_editMode,
                    controller: _institutionCodeController,
                    decoration: _inputDec('Enter code', filled: _institutionCodeController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                    style: _fieldStyleFilled(_institutionCodeController.text.trim().isNotEmpty),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    inputFormatters: [LengthLimitingTextInputFormatter(10)],
                    onChanged: (_) => setState(() {}),
                    validator: (v) => _vRequiredMax(v, 10, 'Code'),
                  ),
                ]),
              ]),
              SizedBox(height: 16.h),

              _formRow(context, [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Institution Start Date'),
                  InkWell(
                    onTap: _pickInstitutionStartDate,
                    child: InputDecorator(
                      decoration: _inputDec('Select date', filled: _institutionStartDate != null).copyWith(suffixIcon: AppIcon.linear('calendar-1', size: 18, color: AppColors.textLight)),
                      child: Text(
                        _institutionStartDate != null ? _formatDate(_institutionStartDate!) : 'Select date',
                        style: _pickerText(_institutionStartDate != null),
                      ),
                    ),
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Authorized Username'),
                  TextFormField(
                    controller: _authorizedUsernameController,
                    decoration: _inputDec('Enter authorized username', filled: _authorizedUsernameController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                    style: _fieldStyleFilled(_authorizedUsernameController.text.trim().isNotEmpty),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (_) => setState(() {}),
                    validator: (v) => _vOptionalMax(v, 50, 'Authorized username'),
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Designation'),
                  TextFormField(
                    controller: _designationController,
                    decoration: _inputDec('Enter designation', filled: _designationController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                    style: _fieldStyleFilled(_designationController.text.trim().isNotEmpty),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (_) => setState(() {}),
                    validator: (v) => _vOptionalMax(v, 30, 'Designation'),
                  ),
                ]),
              ]),
              SizedBox(height: 16.h),

              _formRow(context, [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Mobile Number'),
                  TextFormField(
                    controller: _mobileNumberController,
                    decoration: _inputDec('Enter mobile number', filled: _mobileNumberController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                    style: _fieldStyleFilled(_mobileNumberController.text.trim().isNotEmpty),
                    keyboardType: TextInputType.phone,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                    onChanged: (_) => setState(() {}),
                    validator: _vMobile10,
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Institution Recognized'),
                  SizedBox(
                    height: AppUI.controlHeight(context),
                    child: DropdownButtonFormField<String>(
                      initialValue: _institutionRecognized,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      decoration: _inputDec('Select', filled: true),
                      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textLight),
                      style: _fieldStyle(),
                      items: [DropdownMenuItem(value: 'Yes', child: Text('Yes', style: AppUI.fieldText(context))), DropdownMenuItem(value: 'No', child: Text('No', style: AppUI.fieldText(context)))],
                      selectedItemBuilder: (context) => [Align(alignment: Alignment.centerLeft, child: Text('Yes', style: AppUI.fieldText(context))), Align(alignment: Alignment.centerLeft, child: Text('No', style: AppUI.fieldText(context)))],
                      onChanged: (v) { if (v != null) setState(() => _institutionRecognized = v); },
                    ),
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Email *'),
                  TextFormField(
                    controller: _emailController,
                    decoration: _inputDec('Enter email address', filled: _emailController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                    style: _fieldStyleFilled(_emailController.text.trim().isNotEmpty),
                    keyboardType: TextInputType.emailAddress,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (_) => setState(() {}),
                    validator: _vEmail,
                  ),
                ]),
              ]),
              // Activation code applies only to NEW registrations, not edits.
              if (!_editMode) ...[
              SizedBox(height: 16.h),
              _formRow(context, [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _fieldLabel('Activation Code *'),
                  TextFormField(
                    controller: _activationCodeController,
                    decoration: _inputDec('Enter activation code', filled: _activationCodeController.text.trim().isNotEmpty).copyWith(
                      errorMaxLines: 2,
                      suffixIcon: _codeValidated == true
                          ? const Icon(Icons.check_circle, color: AppColors.success, size: 18)
                          : (_codeValidated == false ? const Icon(Icons.cancel, color: AppColors.error, size: 18) : null),
                    ),
                    style: _fieldStyleFilled(_activationCodeController.text.trim().isNotEmpty),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (v) {
                      // Any edit after a successful verify invalidates the
                      // gate so the cashier can't tamper with a verified
                      // code and slip past.
                      if (_codeValidated != null && v.trim() != _validatedCodeSnapshot) {
                        _codeValidated = null;
                        _codeValidationMsg = null;
                      }
                      // Recolor the field live (amber when it has a value).
                      setState(() {});
                    },
                    validator: (v) {
                      final s = v?.trim() ?? '';
                      if (s.isEmpty) return 'Activation code is required';
                      if (_codeValidated != true || s != _validatedCodeSnapshot) {
                        return 'Verify the activation code before proceeding';
                      }
                      return null;
                    },
                  ),
                  if (_codeValidationMsg != null) ...[
                    SizedBox(height: 6.h),
                    Text(
                      _codeValidationMsg!,
                      style: AppUI.muted.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _codeValidated == true ? AppColors.success : AppColors.error,
                      ),
                    ),
                  ],
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(height: 22.h),
                  SizedBox(
                    height: AppUI.controlHeight(context),
                    child: ElevatedButton.icon(
                      onPressed: (_validatingCode || _requestingCode) ? null : _validateActivationCode,
                      icon: _validatingCode
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.verified_outlined, size: 18),
                      label: Text(_validatingCode ? 'Validating…' : 'Validate'),
                    ),
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(height: 22.h),
                  SizedBox(
                    height: AppUI.controlHeight(context),
                    child: OutlinedButton.icon(
                      onPressed: _requestingCode ? null : _requestActivationCode,
                      icon: _requestingCode
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.email_outlined, size: 18),
                      label: Text(_requestingCode ? 'Sending…' : 'Request Activation Code'),
                    ),
                  ),
                ]),
              ]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Step 2: Affiliation & Address
  Widget _buildStep2() {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 32.w, vertical: 20.h),
      child: Form(
        key: _formKeys[1],
        child: Column(
        children: [
          // Affiliation card
          Container(
            padding: EdgeInsets.all(isMobile ? 16 : AppUI.cardPad),
            decoration: AppUI.card(),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppUI.cardHeader(
                    icon: 'verify',
                    title: 'Affiliation Information',
                    subtitle: 'Enter affiliation and recognition details',
                  ),
                  SizedBox(height: 20.h),

                  _formRow(context, [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _fieldLabel('Institution Affiliation'),
                      TextFormField(
                        controller: _affiliationController,
                        decoration: _inputDec('Enter affiliation', filled: _affiliationController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                        style: _fieldStyleFilled(_affiliationController.text.trim().isNotEmpty),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        onChanged: (_) => setState(() {}),
                        validator: (v) => _vOptionalMax(v, 70, 'Affiliation'),
                      ),
                    ]),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _fieldLabel('Affiliation Number'),
                      TextFormField(
                        controller: _affiliationNumberController,
                        decoration: _inputDec('Enter affiliation number', filled: _affiliationNumberController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                        style: _fieldStyleFilled(_affiliationNumberController.text.trim().isNotEmpty),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        onChanged: (_) => setState(() {}),
                        validator: (v) => _vOptionalMax(v, 25, 'Affiliation number'),
                      ),
                    ]),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _fieldLabel('Affiliation Start Year'),
                      InkWell(
                        onTap: _pickAffiliationStartYear,
                        child: InputDecorator(
                          decoration: _inputDec('Select year', filled: _affiliationStartYear != null).copyWith(suffixIcon: AppIcon.linear('calendar-1', size: 18, color: AppColors.textLight)),
                          child: Text(
                            _affiliationStartYear != null ? '${_affiliationStartYear!.year}' : 'Select year',
                            style: _pickerText(_affiliationStartYear != null),
                          ),
                        ),
                      ),
                    ]),
                  ]),
                ],
              ),
          ),
          SizedBox(height: AppUI.gap),

          // Address card
          Container(
            padding: EdgeInsets.all(isMobile ? 16 : AppUI.cardPad),
            decoration: AppUI.card(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppUI.cardHeader(
                  icon: 'location',
                  title: 'Address',
                  subtitle: 'Enter the institution address details',
                ),
                SizedBox(height: 20.h),

                _formRow(context, [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Address Line 1 *'),
                    TextFormField(
                      controller: _address1Controller,
                      decoration: _inputDec('Enter address line 1', filled: _address1Controller.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                      style: _fieldStyleFilled(_address1Controller.text.trim().isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => _vRequiredMax(v, 60, 'Address'),
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Address Line 2'),
                    TextFormField(
                      controller: _address2Controller,
                      decoration: _inputDec('Enter address line 2', filled: _address2Controller.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                      style: _fieldStyleFilled(_address2Controller.text.trim().isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => _vOptionalMax(v, 60, 'Address'),
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Address Line 3'),
                    TextFormField(
                      controller: _address3Controller,
                      decoration: _inputDec('Enter address line 3', filled: _address3Controller.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                      style: _fieldStyleFilled(_address3Controller.text.trim().isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => _vOptionalMax(v, 60, 'Address'),
                    ),
                  ]),
                ]),
                SizedBox(height: 14.h),
                _formRow(context, [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Pin Code *'),
                    TextFormField(
                      controller: _pinCodeController,
                      decoration: _inputDec('Enter pin code', filled: _pinCodeController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                      style: _fieldStyleFilled(_pinCodeController.text.trim().isNotEmpty),
                      keyboardType: TextInputType.number,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                      onChanged: (_) => setState(() {}),
                      validator: _vPincode,
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('City'),
                    TextFormField(
                      controller: _cityController,
                      decoration: _inputDec('Enter city', filled: _cityController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                      style: _fieldStyleFilled(_cityController.text.trim().isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => _vOptionalMax(v, 50, 'City'),
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('State'),
                    TextFormField(
                      controller: _stateController,
                      decoration: _inputDec('Enter state', filled: _stateController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                      style: _fieldStyleFilled(_stateController.text.trim().isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => _vOptionalMax(v, 35, 'State'),
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Country'),
                    TextFormField(
                      controller: _countryController,
                      decoration: _inputDec('Enter country', filled: _countryController.text.trim().isNotEmpty).copyWith(errorMaxLines: 2),
                      style: _fieldStyleFilled(_countryController.text.trim().isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => _vOptionalMax(v, 35, 'Country'),
                    ),
                  ]),
                ]),
              ],
            ),
          ),
          SizedBox(height: AppUI.gap),

          // Academic Year card
          Container(
            padding: EdgeInsets.all(isMobile ? 16 : AppUI.cardPad),
            decoration: AppUI.card(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppUI.cardHeader(
                  icon: 'calendar-1',
                  title: 'Academic Year',
                  subtitle: 'Set up the academic year for your institution',
                ),
                SizedBox(height: 20.h),

                _formRow(context, [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Year Label *'),
                    TextFormField(
                      controller: _yearLabelController,
                      // The academic year is fixed once the institution and its
                      // schema exist — the schema name embeds it, and demands,
                      // receipts and reports are all keyed to it. Read-only in
                      // edit mode, and no longer required there, since an older
                      // record may have a blank label that must not block a save.
                      readOnly: _editMode,
                      enabled: !_editMode,
                      decoration: _inputDec('e.g. 2025-2026', filled: _yearLabelController.text.trim().isNotEmpty),
                      style: _fieldStyleFilled(_yearLabelController.text.trim().isNotEmpty),
                      onChanged: (_) => setState(() {}),
                      validator: _editMode
                          ? null
                          : (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Start Date *'),
                    InkWell(
                      // Locked in edit mode, like the year label.
                      onTap: _editMode ? null : () async {
                        final picked = await showDatePicker(context: context, initialDate: _yearStartDate ?? DateTime(DateTime.now().year, 6, 1), firstDate: DateTime(2000), lastDate: DateTime(2100));
                        if (picked != null) setState(() => _yearStartDate = picked);
                      },
                      child: InputDecorator(
                        decoration: _inputDec('Select start date', filled: _yearStartDate != null).copyWith(suffixIcon: AppIcon.linear('calendar-1', size: 18, color: AppColors.textLight)),
                        child: Text(
                          _yearStartDate != null ? _formatDate(_yearStartDate!) : 'Select start date',
                          style: _pickerText(_yearStartDate != null),
                        ),
                      ),
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('End Date *'),
                    InkWell(
                      // Locked in edit mode, like the year label.
                      onTap: _editMode ? null : () async {
                        final picked = await showDatePicker(context: context, initialDate: _yearEndDate ?? DateTime(DateTime.now().year + 1, 5, 31), firstDate: DateTime(2000), lastDate: DateTime(2100));
                        if (picked != null) setState(() => _yearEndDate = picked);
                      },
                      child: InputDecorator(
                        decoration: _inputDec('Select end date', filled: _yearEndDate != null).copyWith(suffixIcon: AppIcon.linear('calendar-1', size: 18, color: AppColors.textLight)),
                        child: Text(
                          _yearEndDate != null ? _formatDate(_yearEndDate!) : 'Select end date',
                          style: _pickerText(_yearEndDate != null),
                        ),
                      ),
                    ),
                  ]),
                ]),
              ],
            ),
          ),
          SizedBox(height: 20.h),
        ],
      ),
      ),
    );
  }

  // Step 3: Account Setup
  Widget _buildStep3() {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 32.w, vertical: 20.h),
      child: Container(
        padding: EdgeInsets.all(isMobile ? 16 : AppUI.cardPad),
        decoration: AppUI.card(),
        child: Form(
          key: _formKeys[2],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppUI.cardHeader(
                  icon: 'lock',
                  title: 'Account Setup',
                  subtitle: 'Create an admin account for your institution',
                ),
                SizedBox(height: 20.h),

                _formRow(context, [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Admin Name *'),
                    TextFormField(
                      controller: _adminNameController,
                      decoration: _inputDec('Enter admin name', filled: _adminNameController.text.trim().isNotEmpty).copyWith(
                        prefixIcon: AppIcon.linear('user', size: 16, color: AppColors.textLight),
                        errorMaxLines: 2,
                      ),
                      style: _fieldStyleFilled(_adminNameController.text.trim().isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => _vRequiredMax(v, 50, 'Admin name'),
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Designation *'),
                    SizedBox(
                      height: AppUI.controlHeight(context),
                      child: DropdownButtonFormField<String>(
                        initialValue: _adminDesignation,
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        decoration: _inputDec('Select designation', filled: true).copyWith(
                          prefixIcon: AppIcon.linear('personalcard', size: 16, color: AppColors.textLight),
                        ),
                        icon: const Icon(Icons.arrow_drop_down, color: AppColors.textLight),
                        style: _fieldStyle(),
                        items: _designationOptions.map((d) => DropdownMenuItem(value: d, child: Text(d, style: AppUI.fieldText(context)))).toList(),
                        selectedItemBuilder: (context) => _designationOptions.map((d) => Align(alignment: Alignment.centerLeft, child: Text(d, style: AppUI.fieldText(context)))).toList(),
                        onChanged: (v) => setState(() => _adminDesignation = v ?? 'Principal'),
                        validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                      ),
                    ),
                  ]),
                ]),
                SizedBox(height: 14.h),

                _formRow(context, [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Admin Email *'),
                    TextFormField(
                      controller: _adminEmailController,
                      decoration: _inputDec('Enter email', filled: _adminEmailController.text.trim().isNotEmpty).copyWith(
                        prefixIcon: AppIcon.linear('sms', size: 16, color: AppColors.textLight),
                        errorMaxLines: 2,
                      ),
                      style: _fieldStyleFilled(_adminEmailController.text.trim().isNotEmpty),
                      keyboardType: TextInputType.emailAddress,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: (_) => setState(() {}),
                      validator: _vEmail,
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Admin Phone *'),
                    TextFormField(
                      controller: _adminPhoneController,
                      decoration: _inputDec('Enter phone', filled: _adminPhoneController.text.trim().isNotEmpty).copyWith(
                        prefixIcon: AppIcon.linear('call', size: 16, color: AppColors.textLight),
                        errorMaxLines: 2,
                      ),
                      style: _fieldStyleFilled(_adminPhoneController.text.trim().isNotEmpty),
                      keyboardType: TextInputType.phone,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                      onChanged: (_) => setState(() {}),
                      validator: _vMobile10,
                    ),
                  ]),
                ]),
                SizedBox(height: 14.h),

                _formRow(context, [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Password *'),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      onChanged: (_) => setState(() {}),
                      decoration: _inputDec('Enter password', filled: _passwordController.text.isNotEmpty).copyWith(
                        prefixIcon: AppIcon.linear('lock', size: 16, color: AppColors.textLight),
                        // Compact tap target — IconButton's default 48×48 hit
                        // area gets clipped inside the smaller field height,
                        // so wrap the icon in a tight InkWell instead.
                        suffixIcon: InkWell(
                          onTap: () => setState(() => _obscurePassword = !_obscurePassword),
                          customBorder: const CircleBorder(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: AppIcon(
                              _obscurePassword ? 'eye-slash' : 'eye',
                              size: 18,
                              color: AppColors.textLight,
                            ),
                          ),
                        ),
                        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                      ),
                      style: _fieldStyleFilled(_passwordController.text.isNotEmpty),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: _vPassword,
                    ),
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _fieldLabel('Confirm Password *'),
                    TextFormField(
                      controller: _confirmPasswordController,
                      obscureText: _obscureConfirm,
                      onChanged: (_) => setState(() {}),
                      decoration: _inputDec('Re-enter password', filled: _confirmPasswordController.text.isNotEmpty).copyWith(
                        prefixIcon: AppIcon.linear('lock', size: 16, color: AppColors.textLight),
                        suffixIcon: InkWell(
                          onTap: () => setState(() => _obscureConfirm = !_obscureConfirm),
                          customBorder: const CircleBorder(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: AppIcon(
                              _obscureConfirm ? 'eye-slash' : 'eye',
                              size: 18,
                              color: AppColors.textLight,
                            ),
                          ),
                        ),
                        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                      ),
                      style: _fieldStyleFilled(_confirmPasswordController.text.isNotEmpty),
                      validator: (v) {
                        if (v != _passwordController.text) return 'Passwords do not match';
                        return null;
                      },
                    ),
                  ]),
                ]),
                SizedBox(height: 32.h),

                Center(
                  child: SizedBox(
                    height: AppUI.controlHeight(context),
                    child: ElevatedButton.icon(
                      onPressed: _isCreating ? null : _handleRegister,
                      icon: _isCreating
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : AppIcon('tick-circle', size: 18, color: Colors.white),
                      label: Text(_isCreating ? 'Creating...' : 'Create Institution'),
                      style: AppUI.primary(context).copyWith(
                        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 32)),
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

  // Kit label above a field; a trailing " *" becomes the kit's red marker.
  Widget _fieldLabel(String label) {
    return label.endsWith(' *')
        ? AppUI.fieldLabel(label.substring(0, label.length - 2), required: true)
        : AppUI.fieldLabel(label);
  }

  // Renders [fields] as a Row on desktop and stacks them vertically on mobile.
  Widget _formRow(BuildContext context, List<Widget> fields, {double gap = 14, List<int>? flexes}) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    if (isMobile) {
      final children = <Widget>[];
      for (var i = 0; i < fields.length; i++) {
        children.add(fields[i]);
        if (i < fields.length - 1) children.add(SizedBox(height: gap));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
    }
    final children = <Widget>[];
    for (var i = 0; i < fields.length; i++) {
      children.add(Expanded(flex: flexes != null && i < flexes.length ? flexes[i] : 1, child: fields[i]));
      if (i < fields.length - 1) children.add(SizedBox(width: gap));
    }
    return Row(children: children);
  }

  TextStyle _fieldStyle() => AppUI.fieldText(context);

  // Value style inside a field (the kit field text). The [filled] flag is
  // retained for call-site compatibility.
  TextStyle _fieldStyleFilled(bool filled) => AppUI.fieldText(context);

  // Text shown inside a date-picker field: the value, or a muted placeholder.
  TextStyle _pickerText(bool set) => set
      ? AppUI.fieldText(context)
      : AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500);

  // ── Validators (mapped to public.institution column types) ───
  String? _vRequiredMax(String? v, int max, String label) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length > max) return '$label must be less than $max characters';
    return null;
  }
  String? _vOptionalMax(String? v, int max, String label) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s.length > max) return '$label must be less than $max characters';
    return null;
  }
  String? _vEmail(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Email is required';
    if (!RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$').hasMatch(s)) return 'Enter a valid email address';
    return null;
  }
  String? _vMobile10(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length != 10) return 'Mobile must be 10 digits';
    return null;
  }
  String? _vPincode(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length != 6) return 'Pin code must be 6 digits';
    return null;
  }
  String? _vPassword(String? v) {
    final s = v ?? '';
    if (s.isEmpty) return 'Password is required';
    if (s.length < 8) return 'Password must be at least 8 characters';
    return null;
  }

  // The kit field. [filled] gives the accent edge once the field holds a
  // value. Callers add small prefix/suffix AppIcons, so keep a tight slot.
  InputDecoration _inputDec(String hint, {bool filled = false}) {
    return AppUI.field(context, hint, filled: filled).copyWith(
      suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 16),
      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 16),
    );
  }
}
