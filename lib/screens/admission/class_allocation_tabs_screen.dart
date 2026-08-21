import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../widgets/pill_tab.dart';
import 'class_allocation_screen.dart';
import 'section_transfer_screen.dart';
import 'interim_promotion_screen.dart';

/// Class Allocation wrapper — Section Allocation + Section Transfer as the
/// same pill-style tabs the Fee Master / Reports screens use.
class ClassAllocationTabsScreen extends StatefulWidget {
  const ClassAllocationTabsScreen({super.key});

  @override
  State<ClassAllocationTabsScreen> createState() => _ClassAllocationTabsScreenState();
}

class _ClassAllocationTabsScreenState extends State<ClassAllocationTabsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  static const _labels = ['Class Allocation', 'Class Transfer', 'Interim Promotion'];
  static const _icons = ['task-square', 'arrow-swap-horizontal', 'ranking'];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _labels.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: _tab,
          builder: (context, _) {
            final selected = _tab.index;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < _labels.length; i++) ...[
                      PillTab(
                        icon: _icons[i],
                        label: _labels[i],
                        selected: selected == i,
                        onTap: () => _tab.animateTo(i),
                      ),
                      if (i < _labels.length - 1)
                        SizedBox(width: PillTab.gap(context)),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
        SizedBox(height: 6.h),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: const [
              ClassAllocationScreen(),
              SectionTransferScreen(),
              InterimPromotionScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
