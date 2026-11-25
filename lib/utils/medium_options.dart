import '../services/supabase_service.dart';

/// A student's Medium (user, 2026-11-24): picked from Setup -> Master Data ->
/// Medium (public.medium) on Admission Entry and Student Details, and English
/// for a new student ("defaulty medium as english for student") -- Fast
/// Admission, which has no Medium field, saves the default.
const kDefaultMedium = 'ENGLISH';

/// The school's active mediums, in the order they were added. Empty when none
/// are set up or the table can't be read: a form still works with the default.
Future<List<String>> loadMediums(int insId) => SupabaseService.fromSchema('medium')
    .select('medname')
    .eq('ins_id', insId)
    .eq('activestatus', 1)
    .order('med_id')
    .then<List<String>>((rows) => mediumNames(rows as List), onError: (_) => <String>[]);

/// The names of medium rows, trimmed, blanks and repeats (any case) left out.
List<String> mediumNames(List rows) {
  final seen = <String>{};
  return [
    for (final r in rows)
      if ('${(r as Map)['medname'] ?? ''}'.trim() case final n when n.isNotEmpty && seen.add(n.toLowerCase())) n,
  ];
}

/// The medium a new student starts with: the list's English (whatever its
/// spelling there), or [kDefaultMedium] when the list has none.
String defaultMedium(List<String> mediums) {
  for (final m in mediums) {
    if (m.trim().toLowerCase() == 'english') return m;
  }
  for (final m in mediums) {
    if (m.toLowerCase().contains('english')) return m;
  }
  return kDefaultMedium;
}

/// A saved medium in the list's own spelling ("english" -> "ENGLISH" when the
/// list has ENGLISH); kept as it is when the list doesn't have it, and null
/// when blank.
String? matchMedium(List<String> mediums, String? saved) {
  final v = (saved ?? '').trim();
  if (v.isEmpty) return null;
  for (final m in mediums) {
    if (m.toLowerCase() == v.toLowerCase()) return m;
  }
  return v;
}

/// The dropdown's items: the list, plus the record's own medium when the list
/// doesn't have it -- so opening an older record never clears its medium.
List<String> mediumItems(List<String> mediums, String? current) {
  final c = (current ?? '').trim();
  return [
    ...mediums,
    if (c.isNotEmpty && !mediums.any((m) => m.toLowerCase() == c.toLowerCase())) c,
  ];
}
