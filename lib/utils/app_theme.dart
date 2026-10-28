import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';

/// EduCore360 "Royal" theme -- every colour in one place. Screens read these
/// tokens; nothing hard-codes a hex value.
///
/// Maroon primary, gold accent, warm paper surfaces, burnt-orange errors (plain
/// red clashes with maroon). The legacy names (primary, accent, success,
/// textLight ...) are kept and mapped onto Royal so every existing screen
/// follows the theme; the Royal names (gold, ink2, line2, sideBg ...) are for
/// new styling.
class AppColors {
  // ── Royal: text ─────────────────────────────────────────────────────────
  static const Color ink = Color(0xFF2B1A1E); // main text, headings
  static const Color ink2 = Color(0xFF5E4A4F); // labels, secondary text
  static const Color ink3 = Color(0xFF9A8A8E); // hints, placeholders, table headers
  static const Color faint = Color(0xFFBBA9A0); // disabled / inactive numerals

  // ── Royal: surfaces ─────────────────────────────────────────────────────
  static const Color paper = Color(0xFFF7F3EE); // app background
  static const Color dots = Color(0xFFE6DCD2); // faint dot grid on the background
  static const Color card = Color(0xFFFFFCF9); // cards, panels, dialogs
  static const Color topbar = Color(0xF0FFFCF9); // card at 94%
  static const Color sunken = Color(0xFFFAF5F0); // form footers, inset areas
  static const Color tableHeader = Color(0xFFF7F0E9);
  static const Color fieldBg = Color(0xFFFFFEFC);
  static const Color segmentBg = Color(0xFFF3EBE3);
  static const Color readOnlyA = Color(0xFFFAF4EE); // read-only stripes
  static const Color readOnlyB = Color(0xFFF5EDE5);

  // ── Royal: lines ────────────────────────────────────────────────────────
  static const Color line = Color(0xFFEADFD5); // card borders, dividers
  static const Color line2 = Color(0xFFF2EAE2); // table row dividers
  static const Color fieldBorder = Color(0xFFDCCFC2);
  static const Color lineStrong = Color(0xFFCDBDAE);
  static const Color checkboxBorder = Color(0xFFC3B2A2);
  static const Color track = Color(0xFFF0E6DC);
  static const Color toggleOff = Color(0xFFD5C7B9);

  // ── Royal: primary (maroon) ─────────────────────────────────────────────
  static const Color primary = Color(0xFF7A1F2B);
  static const Color primaryDark = Color(0xFF571520);
  static const Color primaryText = Color(0xFF6A1A25); // maroon text on light
  static const Color primarySoft = Color(0xFFF6E4E6); // icon tiles, avatars
  static const Color primaryTint = Color(0xFFFBF2F3); // selected table row
  static const Color primaryLine = Color(0xFFE3BDC2);
  static const Color primaryMuted = Color(0xFFD9A9B0);
  static const Color onPrimary = Color(0xFFFFF6E8);
  static const Color onPrimaryMuted = Color(0xFFE7B9BF);
  static const Color onPrimaryAccent = Color(0xFFF3D58A);

  // ── Royal: accent (gold) ────────────────────────────────────────────────
  static const Color gold = Color(0xFFC9971C);
  static const Color goldDark = Color(0xFF8F6A0E); // gold text, "Pending"
  static const Color goldSoft = Color(0xFFFBF1D6); // AY chip, drafts, notes
  static const Color goldTint = Color(0xFFFDF8EA); // "action needed" card
  static const Color goldLine = Color(0xFFE8D08C);
  static const Color goldMuted = Color(0xFFE6CC85);
  static const Color goldInk = Color(0xFF6B4F08); // text inside gold-soft areas
  static const Color onGold = Color(0xFF2A1E00);

  // ── Royal: status / chart ───────────────────────────────────────────────
  static const Color error = Color(0xFFC2410C); // burnt orange
  static const Color errorBg = Color(0xFFFDE8DC);
  static const Color errorTint = Color(0xFFFFF7F2);
  static const Color errorInk = Color(0xFF7C2D12);
  static const Color info = Color(0xFF3F4F9A); // navy -- concession, series 2
  static const Color infoBg = Color(0xFFE7E9F6);
  static const Color teal = Color(0xFF1F7F80); // "Ready" / "Editing", series 3
  static const Color tealBg = Color(0xFFDFF2F2);
  static const Color syncDot = Color(0xFF4ADE80);
  /// Chart series order: maroon, gold, navy, teal, burnt orange.
  static const List<Color> chart = [primary, gold, info, teal, error];

  // ── Royal: sidebar (dark maroon) ────────────────────────────────────────
  static const Color sideBg = Color(0xFF3D0F17);
  static const Color sideText = Color(0xFFEBD3D6);
  static const Color sideSubText = Color(0xFFD3B4B9);
  static const Color sideMuted = Color(0xFFA07A80);
  static const Color sideLabel = Color(0xFF8C5F66);
  static const Color sideActiveBg = Color(0xFFFFF6E8);
  static const Color sideActiveText = Color(0xFF5A1520);
  static const Color sideSubActive = Color(0xFFF3D58A);
  static const Color sideTreeLine = Color(0x38EBD3D6); // sideText at 22%

  // ── Admission-no. tag ───────────────────────────────────────────────────
  static const Color tagBg = Color(0xFFFBF4E6);
  static const Color tagBorder = Color(0xFFD9C08A);

  // ── Legacy names, mapped onto Royal (used across every screen) ──────────
  static const Color primaryLight = primarySoft; // selected fills, chips
  static const Color primaryHover = primaryDark;
  // `accent` has always been the same colour as primary and is used for text
  // and edges, so it stays maroon; gold is [gold] (too light for text).
  static const Color accent = primary;
  static const Color accentLight = primarySoft;
  static const Color accentDark = primaryDark;
  static const Color secondary = fieldBorder;
  static const Color secondaryLight = line;
  static const Color surface = paper; // page background
  static const Color surfaceCard = card;
  static const Color surfaceSidebar = sideBg;
  static const Color surfaceDark = sideBg;
  static const Color success = teal; // "Ready" / settled
  static const Color successBg = tealBg;
  static const Color warning = goldDark; // "Pending"
  static const Color warningBg = goldSoft;
  static const Color demand = info; // KPI hue: demand / outstanding
  static const Color today = teal; // KPI hue: today's figures
  static const Color textPrimary = ink;
  static const Color textSecondary = ink2;
  static const Color textLight = ink3;
  static const Color textOnPrimary = onPrimary;
  static const Color textAccent = primaryText;
  static const Color sidebarBg = sideBg;
  static const Color sidebarBorder = Color(0xFF2E0A11);
  static const Color sidebarText = sideText;
  static const Color tabSelected = primary;
  static const Color tabUnselected = ink3;
  static const Color border = fieldBorder; // inputs, secondary buttons
  static const Color cardBorder = line;
  static const Color divider = line2;
  static const Color tableHeadBg = tableHeader;

  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryDark],
  );

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gold, goldDark],
  );

  static const LinearGradient splashGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [primary, primaryDark, sideBg],
  );
}

/// The three Royal typefaces (all Google Fonts).
///  * [heading] Playfair Display -- titles, big amounts, section numerals;
///    lining numerals forced (Playfair's old-style digits look wrong for money).
///  * body: Source Sans 3 (the theme's default text font).
///  * [mono] IBM Plex Mono -- admission numbers, IDs, amounts in tables.
class AppFonts {
  AppFonts._();
  static const List<FontFeature> lining = [FontFeature('lnum'), FontFeature.tabularFigures()];

  static TextStyle heading({double? size, FontWeight weight = FontWeight.w700, Color color = AppColors.ink, double? height, double? letterSpacing}) =>
      GoogleFonts.playfairDisplay(fontSize: size, fontWeight: weight, color: color, height: height, letterSpacing: letterSpacing, fontFeatures: lining);

  static TextStyle body({double? size, FontWeight weight = FontWeight.w500, Color color = AppColors.ink, double? letterSpacing}) =>
      GoogleFonts.sourceSans3(fontSize: size, fontWeight: weight, color: color, letterSpacing: letterSpacing, fontFeatures: const [FontFeature.tabularFigures()]);

  static TextStyle mono({double? size, FontWeight weight = FontWeight.w500, Color color = AppColors.ink}) =>
      GoogleFonts.ibmPlexMono(fontSize: size, fontWeight: weight, color: color);
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
      MediaQuery.of(context).size.width <= 1366 ? 36.0 : 40.0;
}

/// Card: Royal card fill, 10px radius, 1px line border, a very soft shadow.
class AppCard {
  static const double radius = 10;

  static BoxDecoration decoration({
    double? borderRadius,
    Color? color,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.surfaceCard,
      borderRadius: BorderRadius.circular(borderRadius ?? radius),
      border: Border.all(color: AppColors.cardBorder, width: 1),
      boxShadow: const [
        BoxShadow(color: Color.fromRGBO(23, 35, 43, 0.35), offset: Offset(0, 12), blurRadius: 28, spreadRadius: -22),
      ],
    );
  }
}

class AppTheme {
  /// Every amount / id lines up: tabular figures on every text style.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextStyle _m(double size, FontWeight w, Color c, {double? ls}) => GoogleFonts.sourceSans3(
        fontSize: size,
        fontWeight: w,
        color: c,
        letterSpacing: ls,
        fontFeatures: tabular,
      );

  /// A focus ring that is visible on any button fill.
  static WidgetStateProperty<BorderSide?> _focusSide(BorderSide rest) => WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return const BorderSide(color: AppColors.gold, width: 2);
        return rest;
      });

  static ButtonStyle _solid({required double h, required EdgeInsets pad, required double fs}) => ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        disabledBackgroundColor: AppColors.line,
        disabledForegroundColor: AppColors.ink3,
        elevation: 0,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: GoogleFonts.sourceSans3(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(BorderSide.none));

  static ButtonStyle _outline({required double h, required EdgeInsets pad, required double fs}) => OutlinedButton.styleFrom(
        foregroundColor: AppColors.primaryText,
        backgroundColor: AppColors.card,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: GoogleFonts.sourceSans3(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(const BorderSide(color: AppColors.fieldBorder, width: 1)));

  static ButtonStyle _text({required double h, required EdgeInsets pad, required double fs}) => TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: GoogleFonts.sourceSans3(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(BorderSide.none));

  static ThemeData get lightTheme {
    final base = GoogleFonts.sourceSans3TextTheme();
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
      scaffoldBackgroundColor: AppColors.paper,
      canvasColor: AppColors.card,
      focusColor: AppColors.primary.withValues(alpha: 0.12),
      hoverColor: AppColors.primary.withValues(alpha: 0.06),
      // Royal type scale: headings Playfair Display (page 25, card 19),
      // body Source Sans 3 14.5, labels 12.5, eyebrows 10.5/800 caps.
      textTheme: base.copyWith(
        displayLarge: AppFonts.heading(size: 40.sp),
        displayMedium: AppFonts.heading(size: 32.sp),
        displaySmall: AppFonts.heading(size: 28.sp),
        headlineLarge: AppFonts.heading(size: 25.sp),
        headlineMedium: AppFonts.heading(size: 21.sp),
        headlineSmall: AppFonts.heading(size: 19.sp),
        titleLarge: AppFonts.heading(size: 19.sp),
        titleMedium: t(base.titleMedium, 14.sp, FontWeight.w600, AppColors.textPrimary),
        titleSmall: t(base.titleSmall, 13.sp, FontWeight.w700, AppColors.textPrimary),
        bodyLarge: t(base.bodyLarge, 15.sp, FontWeight.w500, AppColors.textPrimary),
        bodyMedium: t(base.bodyMedium, 14.5.sp, FontWeight.w500, AppColors.textPrimary),
        bodySmall: t(base.bodySmall, 12.sp, FontWeight.w500, AppColors.textSecondary),
        labelLarge: t(base.labelLarge, 14.sp, FontWeight.w700, AppColors.textPrimary),
        labelMedium: t(base.labelMedium, 13.sp, FontWeight.w700, AppColors.textPrimary),
        labelSmall: t(base.labelSmall, 10.5.sp, FontWeight.w800, AppColors.textLight, ls: 1.6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: _solid(h: 40, pad: const EdgeInsets.symmetric(horizontal: 18, vertical: 9), fs: 14)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: _outline(h: 40, pad: const EdgeInsets.symmetric(horizontal: 18, vertical: 9), fs: 14)),
      textButtonTheme: TextButtonThemeData(
          style: _text(h: 40, pad: const EdgeInsets.symmetric(horizontal: 14, vertical: 9), fs: 14)),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ).copyWith(side: _focusSide(BorderSide.none)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.line)),
          // segmented track = segmentBg; the selected segment is a card
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.card : AppColors.segmentBg),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primaryText : AppColors.ink2),
          textStyle: WidgetStatePropertyAll(GoogleFonts.sourceSans3(fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.fieldBg,
        isDense: true,
        constraints: const BoxConstraints(minHeight: 42),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border, width: 1),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.cardBorder, width: 1),
        ),
        // Focus: maroon border (Royal focus ring).
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
        hintStyle: _m(14.sp, FontWeight.w500, AppColors.textLight),
        labelStyle: _m(13.sp, FontWeight.w700, AppColors.textSecondary),
        floatingLabelStyle: _m(13.sp, FontWeight.w700, AppColors.primary),
        helperStyle: _m(12.sp, FontWeight.w500, AppColors.textLight),
        errorStyle: _m(12.sp, FontWeight.w600, AppColors.error),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: const BorderSide(color: AppColors.checkboxBorder, width: 1.5),
        checkColor: const WidgetStatePropertyAll(AppColors.onPrimary),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.fieldBg),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.onPrimary : AppColors.card),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.toggleOff),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.checkboxBorder),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.card,
        surfaceTintColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppCard.radius),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.segmentBg,
        selectedColor: AppColors.primarySoft,
        checkmarkColor: AppColors.primary,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        titleTextStyle: _m(14.sp, FontWeight.w600, AppColors.textPrimary),
        subtitleTextStyle: _m(12.5.sp, FontWeight.w500, AppColors.textLight),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: const WidgetStatePropertyAll(AppColors.tableHeadBg),
        headingTextStyle: _m(11.sp, FontWeight.w800, AppColors.ink3, ls: 1.2),
        dataTextStyle: _m(14.sp, FontWeight.w500, AppColors.textPrimary),
        dividerThickness: 1,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(AppColors.card),
          surfaceTintColor: const WidgetStatePropertyAll(AppColors.card),
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
        color: AppColors.card,
        surfaceTintColor: AppColors.card,
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
            return AppColors.ink3;
          }
          return AppColors.lineStrong;
        }),
        trackColor: WidgetStateProperty.all(AppColors.track),
        trackBorderColor: WidgetStateProperty.all(AppColors.line),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: AppColors.card,
        elevation: 10,
        shadowColor: AppColors.ink.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        titleTextStyle: AppFonts.heading(size: 19.sp),
        contentTextStyle: _m(14.sp, FontWeight.w500, AppColors.textSecondary),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        contentTextStyle: _m(14.sp, FontWeight.w600, AppColors.onPrimary),
        actionTextColor: AppColors.onPrimaryAccent,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.primaryDark.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: _m(12.sp, FontWeight.w600, AppColors.onPrimary),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.primary),
      dividerTheme: const DividerThemeData(color: AppColors.divider, thickness: 1, space: 1),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: AppColors.card,
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        headerBackgroundColor: AppColors.primary,
        headerForegroundColor: AppColors.onPrimary,
        todayBorder: const BorderSide(color: AppColors.gold),
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
      elevatedButtonTheme: ElevatedButtonThemeData(style: _solid(h: 36, pad: pad, fs: 13)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _outline(h: 36, pad: pad, fs: 13)),
      textButtonTheme: TextButtonThemeData(style: _text(h: 36, pad: pad, fs: 13)),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        constraints: const BoxConstraints(minHeight: 38),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}
