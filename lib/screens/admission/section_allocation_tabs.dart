import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import 'allot_section_screen.dart';
import 'class_allocation_screen.dart';

/// Admission > Section Allocation. On a school an Admin also gets a
/// "Section pending" tab: students admitted to a standard only (e.g. X -> XI
/// before results) who still need the principal to give them a section.
/// It used to be a separate "Allot Section" menu item.
class SectionAllocationTabs extends StatefulWidget {
  const SectionAllocationTabs({super.key});

  @override
  State<SectionAllocationTabs> createState() => _SectionAllocationTabsState();
}

class _SectionAllocationTabsState extends State<SectionAllocationTabs> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.read<AuthProvider>().currentUser?.urname == 'Admin';
    if (!isSchool || !isAdmin) return const ClassAllocationScreen();

    Widget tab(int i, String label, IconData icon) {
      final on = _tab == i;
      return ChoiceChip(
        avatar: Icon(icon, size: 16, color: on ? AppColors.primary : AppColors.textSecondary),
        label: Text(label),
        selected: on,
        showCheckmark: false,
        onSelected: (_) => setState(() => _tab = i),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        tab(0, 'Admissions', Icons.how_to_reg_outlined),
        SizedBox(width: 8.w),
        tab(1, 'Section pending', Icons.pending_actions_outlined),
      ]),
      SizedBox(height: AppUI.gap),
      Expanded(
        // Both stay alive, so switching tabs keeps each one's filters.
        child: IndexedStack(index: _tab, children: const [ClassAllocationScreen(), AllotSectionScreen()]),
      ),
    ]);
  }
}
