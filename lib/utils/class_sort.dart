// Shared class-name ordering.
//
// Historically each screen kept its own `_classOrder` list and sorted by
// `indexOf(wholeClassName)`. That only works for bare school grades ("I",
// "II", ...); college classes like "B.E CIVIL-I" / "B.TECH (IT) -II" never
// match the list, so every such class got the same rank and the dropdowns
// showed them in database (insertion) order. This orders by course, then year.

const List<String> kClassOrder = [
  'PKG', 'LKG', 'UKG',
  'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII',
];

/// Course / section prefix — the text before the last '-' (empty for a bare
/// grade like "III"), so classes of the same course group together.
String classPrefix(String c) {
  final s = c.trim().toUpperCase();
  final dash = s.lastIndexOf('-');
  return dash >= 0 ? s.substring(0, dash).trim() : '';
}

/// Rank of a class by its trailing year token: "B.E CIVIL-III" -> III,
/// "B.TECH (IT) -II" -> II, bare "III"/"PKG" ranked whole. Unknowns sort last.
int classRank(String c) {
  final s = c.trim().toUpperCase();
  final dash = s.lastIndexOf('-');
  final tail = dash >= 0 ? s.substring(dash + 1).trim() : s;
  final idx = kClassOrder.indexOf(tail);
  return idx >= 0 ? idx : kClassOrder.length;
}

/// Does this class name read as a TC (transfer-certificate) batch?
///
/// Matched on a standalone TC token, so "CSE TC 25" and "B ED TC" match while
/// "B.TECH (IT) -II" does not — TECH has no TC on its own.
///
/// This is the fallback for [classGroupRank] when no classtype is known, and
/// it is the ONLY signal available until CLASS_TYPE.sql has been run: the
/// class.classtype column does not exist on every database yet.
final RegExp _tcToken = RegExp(r'\bTC\b');
bool isTcClassName(String c) => _tcToken.hasMatch(c.trim().toUpperCase());

/// Which group a class belongs to for ordering: 0 PROMOTIONAL, 1 TERMINAL,
/// 2 COMPLETED (a TC batch).
///
/// Dropdowns lead with the classes people are actually working in and push the
/// leavers to the bottom. Left alone, "CSE TC 25" and "CSE TC 26" sorted above
/// "B.E CSE -I" and a cashier picking a class met the TC batches first.
///
/// [classtype] is the class master's own column when the caller has it. When
/// it is null or unrecognised the name decides, so a database without the
/// column still gets TC batches last.
int classGroupRank(String className, {String? classtype}) {
  switch ((classtype ?? '').trim().toUpperCase()) {
    case 'PROMOTIONAL':
      return 0;
    case 'TERMINAL':
      return 1;
    case 'COMPLETED':
      return 2;
  }
  return isTcClassName(className) ? 2 : 0;
}

/// Regroup [items] as promotional, then terminal, then TC batches, KEEPING the
/// order each group already had.
///
/// For the screens whose class list is already ordered the way the institution
/// wants it — by the class master's ordid, or by the order a query returned —
/// where re-sorting with [classCompare] would throw that away. A stable
/// partition, which List.sort is not.
List<T> classGroupPartition<T>(
  Iterable<T> items,
  String Function(T) nameOf, {
  String? Function(T)? typeOf,
}) {
  final promotional = <T>[], terminal = <T>[], completed = <T>[];
  for (final it in items) {
    switch (classGroupRank(nameOf(it), classtype: typeOf?.call(it))) {
      case 0:
        promotional.add(it);
      case 1:
        terminal.add(it);
      default:
        completed.add(it);
    }
  }
  return [...promotional, ...terminal, ...completed];
}

/// [inner], with the group rank applied first: promotional, then terminal,
/// then the TC batches. [typeOf] supplies class.classtype for a class name
/// when the caller has it; without it the name decides.
Comparator<String> byClassGroup(Comparator<String> inner,
    {String? Function(String)? typeOf}) {
  return (a, b) {
    final ga = classGroupRank(a, classtype: typeOf?.call(a));
    final gb = classGroupRank(b, classtype: typeOf?.call(b));
    return ga != gb ? ga.compareTo(gb) : inner(a, b);
  };
}

/// Order classes by course/prefix, then by year — so a course reads
/// B.E CIVIL-I, -II, -III, -IV instead of DB insertion order.
///
/// TC batches sort after everything else, whatever their course: they hold
/// students who have left, so they belong at the foot of a picker.
///
/// Fallback ordering when no ordid map is available (see [classOrdidComparator]).
int classCompare(String a, String b) {
  final ga = classGroupRank(a), gb = classGroupRank(b);
  if (ga != gb) return ga.compareTo(gb);
  final pa = classPrefix(a), pb = classPrefix(b);
  if (pa != pb) return pa.compareTo(pb);
  final ra = classRank(a), rb = classRank(b);
  if (ra != rb) return ra.compareTo(rb);
  return a.trim().toUpperCase().compareTo(b.trim().toUpperCase());
}

/// Authoritative ordering: sort by the class master's order-id.
///
/// [ordid] maps an UPPER-CASED, trimmed class name to a composite sort key
/// (course.ordid then class.ordid) — build it with
/// SupabaseService.getClassOrder(). Classes present in the map win; anything
/// missing falls back to [classCompare] so it never jumps to the top.
Comparator<String> classOrdidComparator(Map<String, int> ordid,
    {String? Function(String)? typeOf}) {
  int keyOf(String c) => ordid[c.trim().toUpperCase()] ?? -1;
  return (a, b) {
    // Group first: a TC batch carries an ordid like any other class, so
    // without this it sorts back in among the live years.
    final ga = classGroupRank(a, classtype: typeOf?.call(a));
    final gb = classGroupRank(b, classtype: typeOf?.call(b));
    if (ga != gb) return ga.compareTo(gb);
    final oa = keyOf(a), ob = keyOf(b);
    if (oa >= 0 && ob >= 0) return oa != ob ? oa.compareTo(ob) : classCompare(a, b);
    if (oa >= 0) return -1; // known class before unknown
    if (ob >= 0) return 1;
    return classCompare(a, b);
  };
}

/// Ordering for fee-type columns in reports: the fee master's order-id first,
/// description second.
///
/// [ordid] maps an UPPER-CASED, trimmed fee description to feetype.ordid —
/// build it with SupabaseService.getFeeTypeOrder(). Anything missing from the
/// map sorts AFTER everything in it, then alphabetically among its peers, so
/// a report never shuffles between runs and an unnumbered fee type never
/// jumps to the front.
///
/// Reports also invent columns the fee master has never heard of — 'ADVANCE'
/// is assembled from advance_collection, not feetype. Those land in the
/// unnumbered group by the same rule, which is where they belong.
Comparator<String> feeTypeOrdidComparator(Map<String, int> ordid) {
  int keyOf(String f) => ordid[f.trim().toUpperCase()] ?? 1 << 30;
  return (a, b) {
    final ka = keyOf(a), kb = keyOf(b);
    if (ka != kb) return ka.compareTo(kb);
    return a.trim().toUpperCase().compareTo(b.trim().toUpperCase());
  };
}
