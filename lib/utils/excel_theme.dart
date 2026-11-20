import 'package:excel/excel.dart' as xl;

/// The app's colours for every Excel file it writes (templates and report
/// exports), so a downloaded sheet looks like the app: teal header with white
/// text, pale-teal totals, marigold group rows. Values match AppColors
/// (lib/utils/app_theme.dart). Red error marks are left to each screen.
class XlTheme {
  XlTheme._();

  /// Header row: AppColors.primary (teal) with white text.
  static final headerBg = xl.ExcelColor.fromHexString('#0F6B63');
  static final headerFg = xl.ExcelColor.fromHexString('#FFFFFF');

  /// Total / subtotal rows: AppColors.primarySoft.
  static final totalBg = xl.ExcelColor.fromHexString('#E1F0EC');

  /// Group heading rows (e.g. a date in a day-wise list): AppColors.goldSoft.
  static final groupBg = xl.ExcelColor.fromHexString('#FDF0DA');

  /// Accent text (a heading in a sheet body): teal.
  static final accentFg = xl.ExcelColor.fromHexString('#0F6B63');
}
