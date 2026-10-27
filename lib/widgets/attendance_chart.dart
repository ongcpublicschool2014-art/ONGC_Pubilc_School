import 'package:flutter/material.dart';
import '../utils/app_theme.dart';

import './app_ui.dart';
class AttendanceChartWidget extends StatelessWidget {
  const AttendanceChartWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Attendance Overview', style: AppUI.cardTitle),
                  const SizedBox(height: 2),
                  Text('Weekly attendance trend', style: AppUI.muted),
                ],
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('This Week', style: AppUI.label),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // Custom bar chart
          SizedBox(
            height: 200,
            child: _AttendanceBarChart(),
          ),

          const SizedBox(height: 20),

          // Legend
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _LegendItem(color: AppColors.accent, label: 'Present'),
              const SizedBox(width: 24),
              _LegendItem(color: AppColors.error.withValues(alpha: 0.6), label: 'Absent'),
              const SizedBox(width: 24),
              _LegendItem(color: AppColors.secondary, label: 'Late'),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppUI.muted,
        ),
      ],
    );
  }
}

class _AttendanceBarChart extends StatelessWidget {
  final List<_DayData> data = const [
    _DayData('Mon', 92, 5, 3),
    _DayData('Tue', 94, 4, 2),
    _DayData('Wed', 91, 6, 3),
    _DayData('Thu', 95, 3, 2),
    _DayData('Fri', 88, 8, 4),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: data.map((day) {
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Percentage label
                Text(
                  '${day.present}%',
                  style: AppUI.label,
                ),
                const SizedBox(height: 8),
                // Stacked bar
                SizedBox(
                  height: 140,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // Late bar
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 600),
                        height: day.late_ * 1.4,
                        decoration: BoxDecoration(
                          color: AppColors.secondary,
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4)),
                        ),
                      ),
                      // Absent bar
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 600),
                        height: day.absent * 1.4,
                        color: AppColors.error.withValues(alpha: 0.6),
                      ),
                      // Present bar
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 600),
                        height: day.present * 1.2,
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(4)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Day label
                Text(
                  day.day,
                  style: AppUI.muted,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _DayData {
  final String day;
  final double present;
  final double absent;
  final double late_;

  const _DayData(this.day, this.present, this.absent, this.late_);
}
