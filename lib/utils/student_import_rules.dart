/// Student Import (Student Details -> Import CSV/Excel): the parent and
/// Payment In Charge rule for one row.
///
///  1. At least one parent -- Father, Mother or Guardian -- with BOTH a name
///     and a mobile.
///  2. Payment In Charge and Payment Mobile, both filled in the sheet.
///
/// [cell] returns a column's trimmed value, or null when it is blank.
/// Returns column key -> message for every cell to mark; empty = row passes.
Map<String, String> importParentPayErrors(String? Function(String key) cell) {
  final errors = <String, String>{};
  const parents = [('fathername', 'fathermobile'), ('mothername', 'mothermobile'), ('guardianname', 'guardianmobile')];
  if (!parents.any((p) => cell(p.$1) != null && cell(p.$2) != null)) {
    const msg = 'Enter the name and mobile of at least one parent (Father, Mother or Guardian).';
    // Mark the half-filled parent(s); with none started, the father's cells.
    final started = parents.where((p) => cell(p.$1) != null || cell(p.$2) != null).toList();
    for (final p in started.isEmpty ? [parents.first] : started) {
      for (final k in [p.$1, p.$2]) {
        if (cell(k) == null) errors[k] = msg;
      }
    }
  }
  if (cell('payincharge') == null) errors['payincharge'] = 'Payment In Charge is required.';
  if (cell('payinchargemob') == null) errors['payinchargemob'] = 'Payment Mobile is required.';
  return errors;
}
