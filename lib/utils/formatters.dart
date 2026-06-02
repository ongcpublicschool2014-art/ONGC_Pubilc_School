// Pure formatting helpers shared across the app. Extracted so they can be
// unit-tested without spinning up Flutter.

/// Format a date string as `DD/MM/YYYY`. Accepts ISO `YYYY-MM-DD` or any
/// `DateTime.parse`-compatible string. Returns `'-'` for null/empty and the
/// raw input when parsing fails.
String formatDate(String? dateStr) {
  if (dateStr == null || dateStr.isEmpty) return '-';
  try {
    final dt = DateTime.parse(dateStr);
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  } catch (_) {
    return dateStr;
  }
}

/// Format a number with the Indian thousands grouping (`12,34,567`).
/// The integer portion is grouped 3-2-2-... from the right; the decimal
/// portion (when present) is rounded to 2 places. Negatives keep the sign.
String formatIndianNumber(num value) {
  final negative = value < 0;
  final abs = value.abs();
  final str = abs.toStringAsFixed(_hasDecimals(abs) ? 2 : 0);
  final dot = str.indexOf('.');
  final intPart = dot >= 0 ? str.substring(0, dot) : str;
  final decPart = dot >= 0 ? str.substring(dot) : '';

  String grouped;
  if (intPart.length <= 3) {
    grouped = intPart;
  } else {
    final last3 = intPart.substring(intPart.length - 3);
    var rest = intPart.substring(0, intPart.length - 3);
    final buf = StringBuffer();
    while (rest.length > 2) {
      buf.write(',');
      buf.write(rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    grouped = '$rest${buf.toString().split('').reversed.join().split(',').reversed.where((s) => s.isNotEmpty).map((s) => ',$s').join()},$last3';
    // The above is convoluted — rebuild simply:
    final pieces = <String>[last3];
    var r = intPart.substring(0, intPart.length - 3);
    while (r.length > 2) {
      pieces.add(r.substring(r.length - 2));
      r = r.substring(0, r.length - 2);
    }
    if (r.isNotEmpty) pieces.add(r);
    grouped = pieces.reversed.join(',');
  }

  return '${negative ? '-' : ''}$grouped$decPart';
}

bool _hasDecimals(num v) {
  if (v is int) return false;
  return (v - v.truncate()).abs() > 1e-9;
}

/// Format an amount as a number-only string like `1,23,456` (decimals kept
/// only when non-zero). Pass [withSymbol] = true to prepend `₹` — used by PDF
/// receipts and Excel exports. On-screen UI defaults to no symbol.
String formatCurrency(num value, {bool withSymbol = false}) {
  final n = formatIndianNumber(value);
  return withSymbol ? '₹$n' : n;
}
