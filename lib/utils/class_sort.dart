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

/// Order classes by course/prefix, then by year — so a course reads
/// B.E CIVIL-I, -II, -III, -IV instead of DB insertion order.
/// Fallback ordering when no ordid map is available (see [classOrdidComparator]).
int classCompare(String a, String b) {
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
Comparator<String> classOrdidComparator(Map<String, int> ordid) {
  int keyOf(String c) => ordid[c.trim().toUpperCase()] ?? -1;
  return (a, b) {
    final oa = keyOf(a), ob = keyOf(b);
    if (oa >= 0 && ob >= 0) return oa != ob ? oa.compareTo(ob) : classCompare(a, b);
    if (oa >= 0) return -1; // known class before unknown
    if (ob >= 0) return 1;
    return classCompare(a, b);
  };
}
