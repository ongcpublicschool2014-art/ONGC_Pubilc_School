/// Pay In Charge mobile rules.
///
/// The Pay In Charge mobile decides which parent record a student joins:
/// allocation reuses the parent row that already has this number, so brothers
/// and sisters share one record and one login. A placeholder typed to get past
/// a required field (9999999999, a staff number copied down a sheet) would
/// join hundreds of unrelated students to one record, and whoever holds that
/// number would see all of them in the parent app.
///
/// The database applies the same pattern before it reuses a parent row
/// (public.is_real_parent_mobile); this is the same check at entry.
library;

final RegExp _indianMobile = RegExp(r'^[6-9][0-9]{9}$');
final RegExp _oneDigitRepeated = RegExp(r'^(\d)\1{9}$');

/// True for a number that can be a parent's own mobile: 10 digits, starting
/// 6-9, and not one digit repeated (9999999999, 8888888888, ...).
bool isRealMobile(String v) {
  final t = v.trim();
  return _indianMobile.hasMatch(t) && !_oneDigitRepeated.hasMatch(t);
}

/// Message for a Pay In Charge mobile that fails [isRealMobile], naming the
/// field it came from ("Father Mobile"), or null when the number is fine.
String? payerMobileError(String field, String mobile) {
  final t = mobile.trim();
  if (t.isEmpty || isRealMobile(t)) return null;
  return '$field $t is not a valid mobile number. It becomes the Pay In Charge '
      'mobile and the parent app login, so enter the parent\'s own 10-digit '
      'number starting with 6, 7, 8 or 9. Placeholders such as 9999999999 are '
      'not accepted.';
}
