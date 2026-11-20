// Pure formatting helpers shared across the app. Extracted so they can be
// unit-tested without spinning up Flutter.

/// Format a date string as `DD-MM-YYYY`. Accepts ISO `YYYY-MM-DD` or any
/// `DateTime.parse`-compatible string. Returns `'-'` for null/empty and the
/// raw input when parsing fails.
String formatDate(String? dateStr) {
  if (dateStr == null || dateStr.isEmpty) return '-';
  try {
    final dt = DateTime.parse(dateStr);
    return '${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year}';
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

/// Format an amount like `₹1,23,456.00`. Pass [withSymbol] = false for the
/// number-only variant.
String formatCurrency(num value, {bool withSymbol = true}) {
  final n = formatIndianNumber(value);
  return withSymbol ? '₹$n' : n;
}

/// A time the server stored (payment.paydate and friends are kept in UTC with
/// no zone mark) as local time. A plain date ("2026-11-05") is already a
/// local date and comes back as is. Without this a receipt taken between
/// midnight and 05:30 India time reads as the previous day.
DateTime? serverTimeToLocal(dynamic v) {
  final s = (v?.toString() ?? '').trim();
  if (s.isEmpty) return null;
  final hasTime = s.contains('T') || s.contains(' ');
  if (!hasTime) return DateTime.tryParse(s);
  final zoned = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(s);
  return DateTime.tryParse(zoned ? s : '${s.replaceFirst(' ', 'T')}Z')?.toLocal();
}
