import 'package:flutter/material.dart';
import '../../utils/app_menu.dart';
import '../../widgets/sequence_type_field.dart';
import '../admission/admission_master_screen.dart';
import '../fees/fee_master_screen.dart';

/// Setup -> Sequence Master: one screen, the number series picked from a
/// "Sequence Type" dropdown at the top of the form (user, 2026-11-13; was one
/// sidebar sub-item per series). Each series' panel still lives on Admission
/// Master or Fee Master and is shown here by its tab label; the panels draw
/// the dropdown (SequenceTypeField) from the SequenceTypeScope set here.
class SequenceMasterScreen extends StatefulWidget {
  const SequenceMasterScreen({super.key});

  @override
  State<SequenceMasterScreen> createState() => _SequenceMasterScreenState();
}

class _SequenceMasterScreenState extends State<SequenceMasterScreen> {
  // Kept for the session, so coming back opens the series last worked on.
  static String? _last;
  late String _label;

  @override
  void initState() {
    super.initState();
    final types = visibleSequenceTypes;
    _label = types.any((t) => t.label == _last) ? _last! : types.first.label;
  }

  Widget _panel() {
    final ai = AdmissionMasterScreen.tabLabels.indexOf(_label);
    if (ai >= 0) {
      return AdmissionMasterScreen(key: ValueKey('seq-adm-$ai'), initialTab: ai, showTabBar: false);
    }
    final fi = FeeMasterScreen.tabLabels.indexOf(_label);
    return FeeMasterScreen(key: ValueKey('seq-fee-$fi'), initialTab: fi < 0 ? 0 : fi, showTabBar: false);
  }

  @override
  Widget build(BuildContext context) {
    return SequenceTypeScope(
      label: _label,
      onChanged: (v) => setState(() => _label = _last = v),
      child: _panel(),
    );
  }
}
