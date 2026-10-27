import 'package:flutter/material.dart';
import '../utils/app_theme.dart';

import './app_ui.dart';
class QuickActionsWidget extends StatelessWidget {
  final VoidCallback? onAddStudent;

  const QuickActionsWidget({super.key, this.onAddStudent});

  @override
  Widget build(BuildContext context) {
    final actions = [
      _QuickAction(
        icon: 'user-add',
        label: 'Add Student',
        color: AppColors.accent,
        onTap: onAddStudent,
      ),
      _QuickAction(
        icon: 'receipt-2',
        label: 'Collect Fee',
        color: AppColors.success,
      ),
      _QuickAction(
        icon: 'volume-high',
        label: 'Send Notice',
        color: AppColors.info,
      ),
      _QuickAction(
        icon: 'chart-2',
        label: 'View Reports',
        color: AppColors.demand,
      ),
    ];

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick Actions', style: AppUI.cardTitle),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: actions
                .map((action) => _QuickActionChip(action: action))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _QuickActionChip extends StatefulWidget {
  final _QuickAction action;

  const _QuickActionChip({required this.action});

  @override
  State<_QuickActionChip> createState() => _QuickActionChipState();
}

class _QuickActionChipState extends State<_QuickActionChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: () {
          if (widget.action.onTap != null) {
            widget.action.onTap!();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${widget.action.label} — Coming soon!'),
                duration: const Duration(seconds: 1),
              ),
            );
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.action.color.withValues(alpha: 0.06)
                : Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(
              color: _isHovered
                  ? widget.action.color.withValues(alpha: 0.3)
                  : AppColors.cardBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppUI.iconTile(widget.action.icon, color: widget.action.color, size: 16),
              const SizedBox(width: 10),
              Text(widget.action.label, style: AppUI.label),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction {
  final String icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });
}
