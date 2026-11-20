/// What a fee type IS — as opposed to which account it banks into.
///
/// `feetype.type` holds a three-letter CODE, and reports compare against it
/// exactly: the DCB Register splits its COLLEGE and TRANSPORT columns on
/// `type = 'TRA'`. So the codes below are not a presentation choice, they are
/// the stored values, and changing one silently moves money between columns.
///
/// This lives in one place because two screens need it and they must not
/// drift: Fee Master writes the code, the DCB Register reads it back. When
/// the picker there listed the raw codes, an operator had to know that TRA
/// meant transport.
///
/// NOT the same thing as the fee GROUP. A group says which bank account the
/// money lands in; the kind says what sort of charge it is. A HOSTEL FEES
/// group can hold a fee that is a college charge, which is why both exist.
library;

import 'school_terms.dart';

/// College: code → label, in the order they should be offered.
const List<({String code, String label})> _collegeFeeKinds = [
  (code: 'COL', label: 'College'),
  (code: 'TRA', label: 'Transport'),
  (code: 'HOS', label: 'Hostel'),
];

/// School: a fee is either charged to everyone (Regular) or only to the
/// students who opt for it (Optional). Stored in feetype.type like the
/// college codes.
const List<({String code, String label})> _schoolFeeKinds = [
  (code: 'REG', label: 'Regular'),
  (code: 'OPT', label: 'Optional'),
];

/// The kinds offered on this database.
List<({String code, String label})> get kFeeKinds => isSchool ? _schoolFeeKinds : _collegeFeeKinds;

/// 'TRA' → 'TRA  Transport'. Unknown or blank codes come back unchanged, so a
/// value some older import put there is still visible and still selectable
/// rather than vanishing from the list.
String feeKindLabel(String code) {
  final c = code.trim().toUpperCase();
  if (c.isEmpty) return code;
  for (final k in kFeeKinds) {
    if (k.code == c) return '${k.code}  ${k.label}';
  }
  return code;
}

/// What makes two fee type names (or short names) the same fee: spaces, dots
/// and capitals do not count. Used by Fee Master -> Fee Type and its import.
String feeTypeKey(Object? v) => '${v ?? ''}'.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
