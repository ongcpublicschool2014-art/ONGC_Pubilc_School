import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';

/// FIT School "Peacock" theme -- every colour in one place. Screens read these
/// tokens; nothing hard-codes a hex value.
///
/// Deep teal primary, marigold accent, warm paper surfaces, coral errors. The
/// token NAMES are kept from the earlier themes so every screen follows along:
/// `gold*` is the marigold accent, `teal`/`tealBg` is the blue "Ready" /
/// series-4 colour (info2), `info` is purple (concession, series 3). The legacy
/// names (primary, accent, success, textLight ...) map onto these.
class AppColors {
  // ── Peacock: text ─────────────────────────────────────────────────────────
  static const Color ink = Color(0xFF17232B); // main text, headings
  static const Color ink2 = Color(0xFF4A5A63); // labels, secondary text
  static const Color ink3 = Color(0xFF8A979D); // hints, placeholders, table headers
  static const Color faint = Color(0xFFB9AE96); // disabled / inactive numerals

  // ── Peacock: surfaces ─────────────────────────────────────────────────────
  static const Color paper = Color(0xFFF5F1E8); // app background
  static const Color dots = Color(0xFFE3DBCA); // faint dot grid on the background
  static const Color card = Color(0xFFFFFDF8); // cards, panels, dialogs
  static const Color topbar = Color(0xEBFFFDF8); // card at 92%
  static const Color sunken = Color(0xFFFBF8F0); // form footers, inset areas
  static const Color tableHeader = Color(0xFFF8F4EA);
  static const Color fieldBg = Color(0xFFFFFEFB);
  static const Color segmentBg = Color(0xFFF3EDE0);
  static const Color readOnlyA = Color(0xFFFAF6EC); // read-only stripes
  static const Color readOnlyB = Color(0xFFF6F1E4);

  // ── Peacock: lines ────────────────────────────────────────────────────────
  static const Color line = Color(0xFFE6DFCF); // card borders, dividers
  static const Color line2 = Color(0xFFEFE9DC); // table row dividers
  static const Color fieldBorder = Color(0xFFDDD4C1);
  static const Color lineStrong = Color(0xFFD6CCB6);
  static const Color checkboxBorder = Color(0xFFC9BFA9);
  static const Color track = Color(0xFFEFE8D9);
  static const Color toggleOff = Color(0xFFD8CFBC);

  // ── Peacock: primary (teal) ── ─────────────────────────────────────────────
  static const Color primary = Color(0xFF0F6B63);
  static const Color primaryDark = Color(0xFF0A4D47);
  static const Color primaryText = Color(0xFF0A4D47); // teal text on light
  static const Color primarySoft = Color(0xFFE1F0EC); // icon tiles, avatars
  static const Color primaryTint = Color(0xFFF1F8F6); // selected table row
  static const Color primaryLine = Color(0xFFBFDDD7);
  static const Color primaryMuted = Color(0xFFA7CFC8);
  static const Color onPrimary = Color(0xFFFFF7E6);
  static const Color onPrimaryMuted = Color(0xFFA9D2CC);
  static const Color onPrimaryAccent = Color(0xFFFFE3B5);

  // ── Peacock: accent (marigold) ────────────────────────────────────────────────
  static const Color gold = Color(0xFFF0A43A);
  static const Color goldDark = Color(0xFFB7701A); // gold text, "Pending"
  static const Color goldSoft = Color(0xFFFDF0DA); // AY chip, drafts, notes
  static const Color goldTint = Color(0xFFFFF8EA); // "action needed" card
  static const Color goldLine = Color(0xFFEFCF96);
  static const Color goldMuted = Color(0xFFF2C77F);
  static const Color goldInk = Color(0xFF7A4A0E); // text inside gold-soft areas
  static const Color onGold = Color(0xFF2A1A04);

  // ── Peacock: status / chart ───────────────────────────────────────────────
  static const Color error = Color(0xFFC8453A); // coral
  static const Color errorBg = Color(0xFFFBE6E2);
  static const Color errorTint = Color(0xFFFFF8F6);
  static const Color errorInk = Color(0xFF8E2B22);
  static const Color info = Color(0xFF6B4FA0); // purple -- concession, series 3
  static const Color infoBg = Color(0xFFEEE8F7);
  static const Color teal = Color(0xFF2F7FB5); // blue (info2) -- "Ready" / "Editing", series 4
  static const Color tealBg = Color(0xFFE3EFF8);
  static const Color syncDot = Color(0xFF4ADE80);
  /// Chart series order: teal, marigold, purple, blue, coral.
  static const List<Color> chart = [primary, gold, info, teal, error];

  // ── Peacock: sidebar (dark teal) ────────────────────────────────────────
  static const Color sideBg = Color(0xFF0C2D2A);
  static const Color sideText = Color(0xFFC9DBD8);
  static const Color sideSubText = Color(0xFFA9C2BE);
  static const Color sideMuted = Color(0xFF6F9690);
  static const Color sideLabel = Color(0xFF5F8781);
  static const Color sideActiveBg = Color(0xFFFFF7E6);
  static const Color sideActiveText = Color(0xFF0A4D47);
  static const Color sideSubActive = Color(0xFFFFE3B5);
  static const Color sideTreeLine = Color(0x40B9CFCB); // #B9CFCB at 25%

  // ── Main menu: light, like the sign-in screen (2026-10-31) ───────────
  // The institution and super-admin menus read these: pale teal with the
  // sign-in school painting at the foot; the selected item keeps the Peacock
  // marigold bar.
  static const Color menuBg = primaryTint; // pale teal
  static const Color menuBorder = line;
  static const Color menuText = Color(0xFF06302C); // items and icons: deep teal, crisp on the pale menu
  static const Color menuSubText = menuText; // sub-items
  static const Color menuMuted = Color(0xFF6F9690); // carets, "SCHOOL ERP" (muted teal)
  static const Color menuActiveBg = primary; // selected item: solid teal pill
  static const Color menuActiveText = onPrimary; // light text / icon on it
  static const Color menuActiveEdge = gold; // its marigold left bar
  static const Color menuOpenBg = Color(0xFFE8F3F0); // an open group
  static const Color menuSubActiveBg = primary; // selected sub-item: solid teal too
  static const Color menuSubActive = onPrimary;
  static const Color menuTreeLine = primaryLine;
  static const Color menuBrandFit = primaryDark; // "FIT"
  static const Color menuBrandSchool = goldDark; // "School" (as on the sign-in screen)

  // ── Dashboard "Classic, polished" (2026-10-31) ──────────────────────────
  // Layout from DBA/redesign/DASHBOARD_CLASSIC_POLISHED_HANDOFF.md; colours
  // mapped onto the Peacock palette (no orange: highlights are marigold).
  static const Color orange = gold; // current-month bar, title underline, Pending Approval
  static const Color orangeInk = goldInk; // ACTION tag, current month label (accent text)
  static const Color onPrimaryWarm = onPrimaryAccent; // highlight text on the teal ticket
  static const Color chartTrack = track; // bar / donut track
  static const Color tileViolet = info;
  static const Color tileBlue = teal; // Peacock blue #2F7FB5
  static const Color tileRed = error;
  static const Color dashShadowNear = Color(0x0817232B); // rgba(23,35,43,.03)

  // ── Sign-in screen (2026-10-31) ─────────────────────────────────────────
  // Layout from the user's mock-up; colours on the Peacock palette.
  static const Color loginBg = paper; // page
  static const Color loginMint = primarySoft; // tab track
  static const Color loginLine = fieldBorder; // field borders
  static const Color loginInk = ink;
  static const Color loginInk2 = ink2;
  static const Color loginBrand = goldDark; // "School", "clarity." (large display text)
  static const Color loginBrandInk = goldInk; // "WELCOME TO" (small accent text)
  static const Color loginBtnTop = primary; // button gradient
  static const Color loginBtnBottom = primaryDark;
  static const Color loginOk = syncDot; // "Connected" dot
  static const Color loginSky = primaryTint; // top of the page (pale sky)
  static const Color loginWave = primaryLine; // card foot wave (front)

  // ── Admission-no. tag ───────────────────────────────────────────────────
  static const Color tagBg = Color(0xFFFBF5E7);
  static const Color tagBorder = Color(0xFFD6C49C);

  // ── School crest (institution initials) + sidebar glow ──────────────────
  static const Color crestBg = Color(0xFFFBEDE7);
  static const Color crestInk = Color(0xFF8A2A22);
  static const Color crestRing = Color(0xFFC98A80);
  static const Color glowTeal = Color(0xFF1F8C80); // soft glows on dark teal

  // ── Peacock names for the accent (same colours as gold*) ────────────────
  static const Color marigold = gold;
  static const Color marigoldDark = goldDark;
  static const Color marigoldSoft = goldSoft;

  // ── Legacy names, mapped onto Peacock (used across every screen) ────────
  static const Color primaryLight = primarySoft; // selected fills, chips
  static const Color primaryHover = primaryDark;
  // `accent` has always been the same colour as primary and is used for text
  // and edges, so it stays teal; the marigold accent is [gold] (too light for text).
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
  static const Color sidebarBorder = Color(0xFF082320);
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

/// The three Peacock typefaces (all Google Fonts).
///  * [heading] Fraunces -- titles, big amounts, section numerals; lining
///    numerals forced.
///  * body: Plus Jakarta Sans (the theme's default text font).
///  * [mono] JetBrains Mono -- admission numbers, IDs, amounts in tables.
class AppFonts {
  AppFonts._();
  static const List<FontFeature> lining = [FontFeature('lnum'), FontFeature.tabularFigures()];

  static TextStyle heading({double? size, FontWeight weight = FontWeight.w600, Color color = AppColors.ink, double? height, double? letterSpacing}) =>
      GoogleFonts.fraunces(fontSize: size, fontWeight: weight, color: color, height: height, letterSpacing: letterSpacing, fontFeatures: lining);

  static TextStyle body({double? size, FontWeight weight = FontWeight.w500, Color color = AppColors.ink, double? letterSpacing}) =>
      GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color, letterSpacing: letterSpacing, fontFeatures: const [FontFeature.tabularFigures()]);

  /// Dashboard figures and titles: the body sans (Plus Jakarta Sans) at display
  /// weight -- the user chose a sans with a clean rupee sign for the dashboard.
  static TextStyle figure({double? size, FontWeight weight = FontWeight.w700, Color color = AppColors.ink, double? height}) =>
      GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color, height: height,
          letterSpacing: size == null ? null : -0.02 * size, fontFeatures: const [FontFeature.tabularFigures()]);

  static TextStyle mono({double? size, FontWeight weight = FontWeight.w500, Color color = AppColors.ink}) =>
      GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: weight, color: color);
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

/// Card: card fill, 14px radius, 1px line border, the Peacock two-layer shadow.
class AppCard {
  static const double radius = 14;

  static BoxDecoration decoration({
    double? borderRadius,
    Color? color,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.surfaceCard,
      borderRadius: BorderRadius.circular(borderRadius ?? radius),
      border: Border.all(color: AppColors.cardBorder, width: 1),
      boxShadow: const [
        BoxShadow(color: Color.fromRGBO(23, 35, 43, 0.03), offset: Offset(0, 1)),
        BoxShadow(color: Color.fromRGBO(23, 35, 43, 0.35), offset: Offset(0, 12), blurRadius: 28, spreadRadius: -22),
      ],
    );
  }
}

class AppTheme {
  /// Every amount / id lines up: tabular figures on every text style.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextStyle _m(double size, FontWeight w, Color c, {double? ls}) => GoogleFonts.plusJakartaSans(
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.plusJakartaSans(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(BorderSide.none));

  static ButtonStyle _outline({required double h, required EdgeInsets pad, required double fs}) => OutlinedButton.styleFrom(
        foregroundColor: AppColors.primaryText,
        backgroundColor: AppColors.card,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.plusJakartaSans(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(const BorderSide(color: AppColors.fieldBorder, width: 1)));

  static ButtonStyle _text({required double h, required EdgeInsets pad, required double fs}) => TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        padding: pad,
        minimumSize: Size(0, h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.plusJakartaSans(fontSize: fs, fontWeight: FontWeight.w700, fontFeatures: tabular),
      ).copyWith(side: _focusSide(BorderSide.none));

  static ThemeData get lightTheme {
    final base = GoogleFonts.plusJakartaSansTextTheme();
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
      // Peacock type scale: headings Fraunces (page 25, card 19),
      // body Plus Jakarta Sans 14, labels 12.5, eyebrows 10.5/800 caps.
      textTheme: base.copyWith(
        displayLarge: AppFonts.body(size: 40.sp, weight: FontWeight.w700),
        displayMedium: AppFonts.body(size: 32.sp, weight: FontWeight.w700),
        displaySmall: AppFonts.body(size: 28.sp, weight: FontWeight.w700),
        headlineLarge: AppFonts.body(size: 25.sp, weight: FontWeight.w700),
        headlineMedium: AppFonts.body(size: 21.sp, weight: FontWeight.w700),
        headlineSmall: AppFonts.body(size: 19.sp, weight: FontWeight.w700),
        titleLarge: AppFonts.body(size: 19.sp, weight: FontWeight.w700),
        titleMedium: t(base.titleMedium, 14.sp, FontWeight.w600, AppColors.textPrimary),
        titleSmall: t(base.titleSmall, 13.sp, FontWeight.w700, AppColors.textPrimary),
        bodyLarge: t(base.bodyLarge, 15.sp, FontWeight.w500, AppColors.textPrimary),
        bodyMedium: t(base.bodyMedium, 14.sp, FontWeight.w500, AppColors.textPrimary),
        bodySmall: t(base.bodySmall, 12.sp, FontWeight.w500, AppColors.textSecondary),
        labelLarge: t(base.labelLarge, 14.sp, FontWeight.w700, AppColors.textPrimary),
        labelMedium: t(base.labelMedium, 13.sp, FontWeight.w700, AppColors.textPrimary),
        labelSmall: t(base.labelSmall, 10.5.sp, FontWeight.w800, AppColors.textLight, ls: 1.58),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: _solid(h: 40, pad: const EdgeInsets.symmetric(horizontal: 18, vertical: 9), fs: 14)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: _outline(h: 40, pad: const EdgeInsets.symmetric(horizontal: 18, vertical: 9), fs: 14)),
      textButtonTheme: TextButtonThemeData(
          style: _text(h: 40, pad: const EdgeInsets.symmetric(horizontal: 14, vertical: 9), fs: 14)),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ).copyWith(side: _focusSide(BorderSide.none)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.line)),
          // segmented track = segmentBg; the selected segment is a card
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.card : AppColors.segmentBg),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primaryText : AppColors.ink2),
          textStyle: WidgetStatePropertyAll(GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.fieldBg,
        isDense: true,
        constraints: const BoxConstraints(minHeight: 42),
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
        // Focus: teal border.
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppCard.radius)),
        titleTextStyle: AppFonts.body(size: 19.sp, weight: FontWeight.w700),
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
