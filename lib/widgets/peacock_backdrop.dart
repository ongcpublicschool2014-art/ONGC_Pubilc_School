import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'app_icon.dart';
import 'app_ui.dart';

/// The sign-in screen's background for the other first-run screens (Activate
/// This PC, Set Up Super Admin): dark teal, a teal glow behind the card, a
/// marigold glow bottom-left, and the FIT School brand top-left. [child] is
/// centred and scrolls when the window is short.
class PeacockBackdrop extends StatelessWidget {
  final Widget child;
  const PeacockBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final glowD = math.min(size.width, size.height) * 1.1;
    return Scaffold(
      backgroundColor: AppColors.sideBg,
      body: Stack(fit: StackFit.expand, children: [
        Positioned(
          left: (size.width - glowD) / 2,
          top: (size.height - glowD) / 2,
          child: _glow(glowD, AppColors.primary, 0.35),
        ),
        Positioned(
          left: -size.height * 0.4,
          bottom: -size.height * 0.4,
          child: _glow(size.height * 0.9, AppColors.gold, 0.16),
        ),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 0),
              child: Row(children: [const PeacockBrand(), const Spacer()]),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  child: child,
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  static Widget _glow(double d, Color color, double alpha) => IgnorePointer(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)]),
          ),
        ),
      );
}

/// Logo on a cream plate with a marigold ring, and "FIT School".
class PeacockBrand extends StatelessWidget {
  final double logo;
  const PeacockBrand({super.key, this.logo = 44});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: logo,
          height: logo,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.onPrimary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.gold, width: 2),
          ),
          child: Image.asset('assets/images/app_logo_mark.png', fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const AppIcon('teacher', color: AppColors.primary, size: 16)),
        ),
        const SizedBox(width: 10),
        Text.rich(TextSpan(children: [
          TextSpan(text: 'FIT ', style: AppFonts.heading(size: 20, color: AppColors.onPrimary)),
          TextSpan(text: 'School', style: AppFonts.heading(size: 20, color: AppColors.gold)),
        ])),
      ]);
}

/// The card on a [PeacockBackdrop]: the kit card with a marigold top edge,
/// an icon on a gold-ringed plate and a Fraunces title.
class PeacockCard extends StatelessWidget {
  final double width;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const PeacockCard({
    super.key,
    required this.width,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(28, 24, 28, 28),
  });

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        clipBehavior: Clip.antiAlias,
        decoration: AppUI.card().copyWith(
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.30), blurRadius: 40, offset: const Offset(0, 18))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(height: 5, color: AppColors.gold),
          Padding(
            padding: padding,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: AppColors.goldSoft,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: AppColors.goldLine),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 26, color: AppColors.goldInk),
                ),
              ),
              const SizedBox(height: 12),
              Text(title, textAlign: TextAlign.center, style: AppFonts.heading(size: 26, height: 1.15)),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(subtitle!, textAlign: TextAlign.center, style: AppUI.muted),
              ],
              const SizedBox(height: 16),
              child,
            ]),
          ),
        ]),
      );
}
