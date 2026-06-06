import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // Primary - Deep Navy (sidebars, headers, primary buttons)
  static const Color primary = Color(0xFF002147);
  static const Color primaryLight = Color(0xFFE4EAF2);
  static const Color primaryDark = Color(0xFF001834);
  static const Color primaryHover = Color(0xFF003069);

  // Accent - Burnished Amber (alerts, active files)
  static const Color accent = Color(0xFFD2913C);
  static const Color accentLight = Color(0xFFF3DCB5);
  static const Color accentDark = Color(0xFFA5711E);

  // Secondary - Brushed Silver (icons, secondary borders)
  static const Color secondary = Color(0xFFBFC1C2);
  static const Color secondaryLight = Color(0xFFD9DBDC);

  // Surfaces
  static const Color surface = Color(0xFFF9F8F4); // Bone White workspace
  static const Color surfaceCard = Color(0xFFFFFFFF);
  static const Color surfaceSidebar = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF002147);

  // Feedback colors
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF38BDF8);

  // Text
  static const Color textPrimary = Color(0xFF1A1A1A);   // Deep Charcoal
  static const Color textSecondary = Color(0xFF4A5568); // Slate Navy
  static const Color textLight = Color(0xFF9CA3AF);
  static const Color textOnPrimary = Color(0xFFFFFFFF); // Pure White on navy
  static const Color textAccent = Color(0xFF002147);    // Navy Shade — links, section heads

  // Tab pill (Reports) — Deep Navy selected, Slate Navy unselected
  static const Color tabSelected = Color(0xFF002147);
  static const Color tabUnselected = Color(0xFF4A5568);

  // Borders & Dividers — Brushed Silver
  static const Color border = Color(0xFFBFC1C2);
  static const Color cardBorder = Color(0xFFE5E5E5);
  static const Color divider = Color(0xFFBFC1C2);

  // Table head — warm stone, coheres with Bone White surface
  static const Color tableHeadBg = Color(0xFFEFEAD8);

  // Gradient
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6C8EEF), Color(0xFF4A6CD4)],
  );

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6C8EEF), Color(0xFF4A6CD4)],
  );

  static const LinearGradient splashGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF6C8EEF), Color(0xFF4A6CD4), Color(0xFF2D3A5F)],
  );
}

/// Project-wide responsive sizing helpers for action buttons.
/// Use [AppBtn.iconSize] and [AppBtn.gap] for icon sizes inside buttons
/// and the SizedBox between sibling buttons. Height/padding/radius/text
/// are handled by the theme override applied in main.dart at <= 1366.
class AppBtn {
  /// Icon size to pass to AppIcon / Icon inside an action button.
  /// 1920+ → 16, 1366 → 12.
  static double iconSize(BuildContext context) =>
      MediaQuery.of(context).size.width <= 1366 ? 12.0 : 16.0;

  /// Gap to insert as a SizedBox between sibling action buttons.
  /// 1920+ → 10, 1366 → 6.
  static double gap(BuildContext context) =>
      MediaQuery.of(context).size.width <= 1366 ? 6.0 : 10.0;

  /// Standard action-button height for SizedBox wrappers.
  /// 1920+ → 40, 1366 → 30. Theme also enforces minimumSize, so callers
  /// that don't wrap in SizedBox still get the right height.
  static double height(BuildContext context) =>
      MediaQuery.of(context).size.width <= 1366 ? 30.0 : 40.0;
}

/// Shared card treatment matching the minimal reference design:
/// white fill, 16px radius, soft diffused shadow (no border).
class AppCard {
  static const double radius = 16;

  static BoxDecoration decoration({
    double? borderRadius,
    Color? color,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.surfaceCard,
      borderRadius: BorderRadius.circular(borderRadius ?? radius),
      border: Border.all(color: AppColors.secondary, width: 1),
      boxShadow: const [
        // Whisper-soft drop
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, 0.02),
          offset: Offset(0, 2),
          blurRadius: 10,
        ),
      ],
    );
  }
}

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        secondary: AppColors.accent,
        surface: AppColors.surface,
        error: AppColors.error,
      ),
      scaffoldBackgroundColor: AppColors.surface,
      // Default popup/menu background for legacy DropdownButton, ContextMenu,
      // etc. Setting this white globally ensures `DropdownButtonFormField`
      // popups (the most-used pattern in this app) inherit the white,
      // rounded popup look from the Fee Group Assignments dropdown.
      canvasColor: Colors.white,
      textTheme: GoogleFonts.plusJakartaSansTextTheme().copyWith(
        displayLarge: GoogleFonts.plusJakartaSans(
          fontSize: 34.sp,
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
          letterSpacing: -0.5,
        ),
        displayMedium: GoogleFonts.plusJakartaSans(
          fontSize: 28.sp,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
          letterSpacing: -0.3,
        ),
        headlineLarge: GoogleFonts.plusJakartaSans(
          fontSize: 24.sp,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
        headlineMedium: GoogleFonts.plusJakartaSans(
          fontSize: 20.sp,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        titleLarge: GoogleFonts.plusJakartaSans(
          fontSize: 18.sp,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        titleMedium: GoogleFonts.plusJakartaSans(
          fontSize: 16.sp,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        bodyLarge: GoogleFonts.plusJakartaSans(
          fontSize: 16.sp,
          fontWeight: FontWeight.w400,
          color: AppColors.textPrimary,
        ),
        bodyMedium: GoogleFonts.plusJakartaSans(
          fontSize: 14.sp,
          fontWeight: FontWeight.w400,
          color: AppColors.textPrimary,
        ),
        labelLarge: GoogleFonts.plusJakartaSans(
          fontSize: 14.sp,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          minimumSize: const Size(0, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.border, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          minimumSize: const Size(0, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          minimumSize: const Size(0, 40),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        hintStyle: GoogleFonts.plusJakartaSans(
          color: AppColors.textLight,
          fontSize: 14.sp,
        ),
        labelStyle: GoogleFonts.plusJakartaSans(
          color: AppColors.textSecondary,
          fontSize: 14.sp,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shadowColor: const Color(0xFF0F172A).withValues(alpha: 0.04),
        color: AppColors.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppCard.radius),
        ),
      ),
      // Soft accent-tinted hover used by DropdownButton menu items, list
      // tiles and any default Material InkWell. Replaces the muted gray
      // hover that ships with Material 3 by default.
      hoverColor: AppColors.accent.withValues(alpha: 0.10),
      // DropdownMenu (Material 3) — rounded, white, soft elevation.
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.white),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.white),
          elevation: const WidgetStatePropertyAll(6),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.border),
            ),
          ),
        ),
      ),
      // PopupMenuButton — same rounded, white, accent hover treatment.
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
        textStyle: GoogleFonts.plusJakartaSans(
          fontSize: 13.sp,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      // Always-visible scrollbars — app-wide, on tables and any vertical
      // (or horizontal) overflow area. Prominent thumb so it reads clearly.
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: WidgetStateProperty.all(true),
        trackVisibility: WidgetStateProperty.all(true),
        interactive: true,
        thickness: WidgetStateProperty.all(13),
        radius: const Radius.circular(7),
        crossAxisMargin: 0,
        mainAxisMargin: 0,
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return AppColors.primary;
          }
          return AppColors.primary.withValues(alpha: 0.70);
        }),
        // Solid, clearly-visible track lane + a defined edge.
        trackColor: WidgetStateProperty.all(const Color(0xFFC9CED6)),
        trackBorderColor: WidgetStateProperty.all(const Color(0xFF9AA2AE)),
      ),
    );
  }

  static ThemeData get darkTheme {
    return lightTheme.copyWith(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.surfaceDark,
    );
  }

  /// Project-wide button shrink applied at width <= 1366 only.
  /// Mirrors the import-action button compact spec so all stock
  /// ElevatedButton/OutlinedButton/TextButton instances pick up the
  /// same look without per-call MediaQuery overrides.
  static ThemeData compactButtons(ThemeData base) {
    const compactPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 6);
    const compactMinSize = Size(0, 30);
    final compactShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
    );
    final compactTextStyle = GoogleFonts.plusJakartaSans(
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );

    return base.copyWith(
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: compactPadding,
          minimumSize: compactMinSize,
          shape: compactShape,
          textStyle: compactTextStyle,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.border, width: 1.5),
          padding: compactPadding,
          minimumSize: compactMinSize,
          shape: compactShape,
          textStyle: compactTextStyle,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          padding: compactPadding,
          minimumSize: compactMinSize,
          textStyle: compactTextStyle,
        ),
      ),
    );
  }
}
