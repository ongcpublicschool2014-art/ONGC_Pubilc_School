import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // ── Design system tokens (one source for every screen) ──────────────────
  // Accent blue #2450E6, navy chrome #0E1A3A, page #F4F6FA, text #101828 /
  // muted #667085, cards white + 1px #E4E7EC. Status colours always travel
  // with a text label, never colour alone.

  // Primary / accent - the one blue
  static const Color primary = Color(0xFF2450E6);
  static const Color primaryLight = Color(0xFFE9EEFD);  // selected fills, chips
  static const Color primaryDark = Color(0xFF0E1A3A);   // navy
  static const Color primaryHover = Color(0xFF1C40BE);

  static const Color accent = Color(0xFF2450E6);
  static const Color accentLight = Color(0xFFE9EEFD);
  static const Color accentDark = Color(0xFF1C40BE);

  // Secondary - neutral border family
  static const Color secondary = Color(0xFFD0D5DD);
  static const Color secondaryLight = Color(0xFFE4E7EC);

  // Surfaces
  static const Color surface = Color(0xFFF4F6FA);       // page background
  static const Color surfaceCard = Color(0xFFFFFFFF);   // cards
  static const Color surfaceSidebar = Color(0xFF0E1A3A); // sidebar navy
  static const Color surfaceDark = Color(0xFF0E1A3A);

  // Status (text colour; pair with the *Bg tint and a label)
  static const Color success = Color(0xFF0B7A55);
  static const Color successBg = Color(0xFFECFDF3);
  static const Color warning = Color(0xFF93500A);
  static const Color warningBg = Color(0xFFFFF4E0);
  static const Color error = Color(0xFFB42318);
  static const Color errorBg = Color(0xFFFEF3F2);
  static const Color info = Color(0xFF175CD3);
  static const Color infoBg = Color(0xFFEFF4FF);

  // Metric hues for KPI tiles (each figure its own hue, AA on white)
  static const Color demand = Color(0xFF6941C6);        // violet - demand / outstanding
  static const Color today = Color(0xFF0E7C86);         // teal - today's figures

  // Text
  static const Color textPrimary = Color(0xFF101828);   // titles, values (~17:1)
  static const Color textSecondary = Color(0xFF475467); // body (~7.6:1)
  static const Color textLight = Color(0xFF667085);     // muted labels / hints (~4.8:1)
  static const Color textOnPrimary = Color(0xFFFFFFFF);
  static const Color textAccent = Color(0xFF2450E6);

  // Sidebar (navy chrome)
  static const Color sidebarBg = Color(0xFF0E1A3A);
  static const Color sidebarBorder = Color(0xFF1D2A50);
  static const Color sidebarText = Color(0xFFE4E7EC);

  // Tabs
  static const Color tabSelected = Color(0xFF2450E6);
  static const Color tabUnselected = Color(0xFF667085);

  // Borders & dividers
  static const Color border = Color(0xFFD0D5DD);      // controls (inputs, outlined buttons) - 3:1-ish edge
  static const Color cardBorder = Color(0xFFE4E7EC);  // cards
  static const Color divider = Color(0xFFEAECF0);     // inner dividers, table rows

  // Table head
  static const Color tableHeadBg = Color(0xFFF2F4F7);

  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2450E6), Color(0xFF1C40BE)],
  );

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2450E6), Color(0xFF1C40BE)],
  );

  static const LinearGradient splashGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF2450E6), Color(0xFF1C40BE), Color(0xFF0E1A3A)],
  );
}

/// Project-wide responsive sizing helpers for action buttons.
/// Height/padding/radius/text come from the theme (44px controls; 40px on
/// <= 1366 screens, where the whole UI is scaled down).
class AppBtn {
  static double iconSize(BuildContext context) =>
      MediaQuery.of(context).size.width <= 1366 ? 15.0 : 18.0;

  static double gap(BuildContext context) =>
      MediaQuery.of(context).size.width <= 1366 ? 8.0 : 10.0;

  static double height(BuildContext context) =>
      MediaQuery.of(context).size.width <= 1366 ? 40.0 : 44.0;
}

/// Card: white, 16px radius, 1px #E4E7EC border, a whisper of shadow.
class AppCard {
  static const double radius = 16;

  static BoxDecoration decoration({
    double? borderRadius,
    Color? color,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.surfaceCard,
      borderRadius: BorderRadius.circular(borderRadius ?? radius),
      border: Border.all(color: AppColors.cardBorder, width: 1),
      boxShadow: const [
        BoxShadow(color: Color.fromRGBO(16, 24, 40, 0.04), offset: Offset(0, 1), blurRadius: 2),
      ],
    );
  }
}

class AppTheme {
  /// Every amount / id lines up: tabular figures on every text style.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextStyle _m(double size, FontWeight w, Color c, {double? ls}) => GoogleFonts.manrope(
        fontSize: size,
        fontWeight: w,
        color: c,
        letterSpacing: ls,
        fontFeatures: tabular,
      );

  /// A focus ring that is visible on any button fill.
  static WidgetStateProperty<BorderSide?> _focusSide(BorderSide rest) => WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return const BorderSide(color: AppColors.primaryDark, width: 2);
        return rest;
      });

  static ButtonStyle _solid({required double h, required EdgeInsets pad, required double fs}) => ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFE4E7EC),
        disabledForegroundColor: const Color(0xFF98A2B3),
        elevation: 0,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.manrope(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(BorderSide.none));

  static ButtonStyle _outline({required double h, required EdgeInsets pad, required double fs}) => OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        backgroundColor: Colors.white,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.manrope(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(const BorderSide(color: AppColors.border, width: 1)));

  static ButtonStyle _text({required double h, required EdgeInsets pad, required double fs}) => TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.manrope(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(BorderSide.none));

  static ThemeData get lightTheme {
    final base = GoogleFonts.manropeTextTheme();
    TextStyle t(TextStyle? b, double size, FontWeight w, Color c, {double? ls}) =>
        (b ?? const TextStyle()).merge(_m(size, w, c, ls: ls));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        secondary: AppColors.accent,
        surface: AppColors.surfaceCard,
        error: AppColors.error,
      ),
      scaffoldBackgroundColor: AppColors.surface,
      canvasColor: Colors.white,
      focusColor: AppColors.primary.withValues(alpha: 0.12),
      hoverColor: AppColors.primary.withValues(alpha: 0.06),
      // Type scale: page title 26/800, card title 17/800, body 14/500,
      // labels 13/700, small caps 12/700.
      textTheme: base.copyWith(
        displayLarge: t(base.displayLarge, 34.sp, FontWeight.w800, AppColors.textPrimary, ls: -0.5),
        displayMedium: t(base.displayMedium, 28.sp, FontWeight.w800, AppColors.textPrimary, ls: -0.3),
        displaySmall: t(base.displaySmall, 26.sp, FontWeight.w800, AppColors.textPrimary, ls: -0.3),
        headlineLarge: t(base.headlineLarge, 26.sp, FontWeight.w800, AppColors.textPrimary, ls: -0.3),
        headlineMedium: t(base.headlineMedium, 20.sp, FontWeight.w800, AppColors.textPrimary),
        headlineSmall: t(base.headlineSmall, 18.sp, FontWeight.w800, AppColors.textPrimary),
        titleLarge: t(base.titleLarge, 17.sp, FontWeight.w800, AppColors.textPrimary),
        titleMedium: t(base.titleMedium, 14.sp, FontWeight.w600, AppColors.textPrimary),
        titleSmall: t(base.titleSmall, 13.sp, FontWeight.w700, AppColors.textPrimary),
        bodyLarge: t(base.bodyLarge, 15.sp, FontWeight.w500, AppColors.textPrimary),
        bodyMedium: t(base.bodyMedium, 14.sp, FontWeight.w500, AppColors.textPrimary),
        bodySmall: t(base.bodySmall, 12.sp, FontWeight.w500, AppColors.textSecondary),
        labelLarge: t(base.labelLarge, 14.sp, FontWeight.w700, AppColors.textPrimary),
        labelMedium: t(base.labelMedium, 13.sp, FontWeight.w700, AppColors.textPrimary),
        labelSmall: t(base.labelSmall, 12.sp, FontWeight.w700, AppColors.textLight, ls: 0.6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: _solid(h: 44, pad: const EdgeInsets.symmetric(horizontal: 18, vertical: 10), fs: 14)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: _outline(h: 44, pad: const EdgeInsets.symmetric(horizontal: 18, vertical: 10), fs: 14)),
      textButtonTheme: TextButtonThemeData(
          style: _text(h: 44, pad: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), fs: 14)),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ).copyWith(side: _focusSide(BorderSide.none)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primaryLight : Colors.white),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.textSecondary),
          textStyle: WidgetStatePropertyAll(GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        constraints: const BoxConstraints(minHeight: 44),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border, width: 1),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.cardBorder, width: 1),
        ),
        // Focus ring: 2px accent, unmistakable.
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
        hintStyle: _m(14.sp, FontWeight.w500, AppColors.textLight),
        labelStyle: _m(13.sp, FontWeight.w700, AppColors.textSecondary),
        floatingLabelStyle: _m(13.sp, FontWeight.w700, AppColors.primary),
        helperStyle: _m(12.sp, FontWeight.w500, AppColors.textLight),
        errorStyle: _m(12.sp, FontWeight.w600, AppColors.error),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: const BorderSide(color: Color(0xFF98A2B3), width: 1.5),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : Colors.white),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surfaceCard,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppCard.radius),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.tableHeadBg,
        selectedColor: AppColors.primaryLight,
        side: const BorderSide(color: AppColors.cardBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: _m(12.sp, FontWeight.w700, AppColors.textSecondary),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: AppColors.primary,
        unselectedLabelColor: AppColors.textLight,
        indicatorColor: AppColors.primary,
        labelStyle: _m(14.sp, FontWeight.w700, AppColors.primary),
        unselectedLabelStyle: _m(14.sp, FontWeight.w600, AppColors.textLight),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        titleTextStyle: _m(14.sp, FontWeight.w600, AppColors.textPrimary),
        subtitleTextStyle: _m(12.5.sp, FontWeight.w500, AppColors.textLight),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: const WidgetStatePropertyAll(AppColors.tableHeadBg),
        headingTextStyle: _m(12.sp, FontWeight.w700, AppColors.textSecondary, ls: 0.4),
        dataTextStyle: _m(14.sp, FontWeight.w500, AppColors.textPrimary),
        dividerThickness: 1,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.white),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.white),
          elevation: const WidgetStatePropertyAll(6),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.cardBorder),
            ),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        textStyle: _m(14.sp, FontWeight.w600, AppColors.textPrimary),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: WidgetStateProperty.all(true),
        trackVisibility: WidgetStateProperty.all(true),
        interactive: true,
        thickness: WidgetStateProperty.all(10),
        radius: const Radius.circular(6),
        crossAxisMargin: 0,
        mainAxisMargin: 0,
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) || states.contains(WidgetState.dragged)) {
            return const Color(0xFF667085);
          }
          return const Color(0xFF98A2B3);
        }),
        trackColor: WidgetStateProperty.all(const Color(0xFFF2F4F7)),
        trackBorderColor: WidgetStateProperty.all(const Color(0xFFE4E7EC)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 10,
        shadowColor: const Color(0xFF101828).withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: _m(17.sp, FontWeight.w800, AppColors.textPrimary),
        contentTextStyle: _m(14.sp, FontWeight.w500, AppColors.textSecondary),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.textPrimary,
        contentTextStyle: _m(14.sp, FontWeight.w600, Colors.white),
        actionTextColor: Colors.white,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.textPrimary.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: _m(12.sp, FontWeight.w600, Colors.white),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.primary),
      dividerTheme: const DividerThemeData(color: AppColors.divider, thickness: 1, space: 1),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        headerBackgroundColor: AppColors.primary,
        headerForegroundColor: Colors.white,
      ),
    );
  }

  static ThemeData get darkTheme {
    return lightTheme.copyWith(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.surfaceDark,
    );
  }

  /// At 1366px or narrower: the same controls at 40px (the whole UI is scaled
  /// about 0.85 there), same radius, focus ring and type.
  static ThemeData compactButtons(ThemeData base) {
    const pad = EdgeInsets.symmetric(horizontal: 14, vertical: 8);
    return base.copyWith(
      elevatedButtonTheme: ElevatedButtonThemeData(style: _solid(h: 40, pad: pad, fs: 13)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _outline(h: 40, pad: pad, fs: 13)),
      textButtonTheme: TextButtonThemeData(style: _text(h: 40, pad: pad, fs: 13)),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        constraints: const BoxConstraints(minHeight: 40),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}
