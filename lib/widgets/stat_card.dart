import 'package:flutter/material.dart';
import '../utils/app_theme.dart';

import './app_icon.dart';
import './app_ui.dart';
class StatData {
  final String label;
  final String value;
  final String change;
  final bool isPositive;
  final String icon;
  final Color color;

  const StatData({
    required this.label,
    required this.value,
    required this.change,
    required this.isPositive,
    required this.icon,
    required this.color,
  });
}

class StatCard extends StatefulWidget {
  final StatData data;

  const StatCard({super.key, required this.data});

  @override
  State<StatCard> createState() => _StatCardState();
}

class _StatCardState extends State<StatCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        // AppUI.kpi anatomy: icon tile, CAPS label, 20/800 value, muted sub
        // (here the change pill). Hover only tints the card edge.
        decoration: AppUI.card().copyWith(
          border: Border.all(
            color: _isHovered
                ? widget.data.color.withValues(alpha: 0.3)
                : AppColors.cardBorder,
          ),
        ),
        child: Row(
          children: [
            AppUI.iconTile(widget.data.icon, color: widget.data.color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.data.label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.caps,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.data.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: widget.data.isPositive
                          ? AppColors.successBg
                          : AppColors.errorBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon(
                          widget.data.isPositive
                              ? 'arrow-up-1'
                              : 'arrow-down',
                          size: 14,
                          color: widget.data.isPositive
                              ? AppColors.success
                              : AppColors.error,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            widget.data.change,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.data.isPositive
                                  ? AppColors.success
                                  : AppColors.error,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
