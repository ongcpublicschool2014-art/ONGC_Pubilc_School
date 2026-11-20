import '../services/supabase_service.dart';

/// What the Fee Refund and Fee Cancel receipt lists say about a receipt --
/// its type, the series it was numbered from and its running number -- and
/// finding a student by receipt number (user, 2026-11-14: "add receipt no
/// search"; "show type of receipt and sequence no").
class ReceiptInfo {
  ReceiptInfo._();

  /// The active numbering series as (prefix, name), longest prefix first so
  /// "CF26/" wins over "C". A fee group's receipt series is named after the
  /// fee group (sequence.actname).
  static Future<List<(String, String)>> loadSeries(int insId) async {
    try {
      final rows = await SupabaseService.fromSchema('sequence')
          .select('actname, seqprefix')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final out = <(String, String)>[];
      for (final r in rows as List) {
        final p = '${(r as Map)['seqprefix'] ?? ''}'.trim();
        final a = '${r['actname'] ?? ''}'.trim();
        if (p.isEmpty || a.isEmpty) continue;
        out.add((p, switch (a.toUpperCase()) {
          'ADVFEENO' => 'ADVANCE RECEIPT',
          'ARRFEENO' => 'ARREAR RECEIPT',
          'MISCFEENO' => 'MISCELLANEOUS RECEIPT',
          _ => a,
        }));
      }
      out.sort((x, y) => y.$1.length.compareTo(x.$1.length));
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// "COLLEGE FEES" for CF26/00002: the series whose prefix the number
  /// starts with. (No Seq. No. -- user, 2026-11-14: "remove the seq no".)
  static String seriesText(String receiptNo, List<(String, String)> series) {
    final n = receiptNo.trim();
    if (n.isEmpty) return '';
    for (final (p, name) in series) {
      if (n.toUpperCase().startsWith(p.toUpperCase())) return name;
    }
    return '';
  }

  /// pay_id -> 'Regular' / 'Arrear' / 'Regular + Arrear', from the fee
  /// demands each fee receipt paid (feedemand.demseqtype).
  static Future<Map<int, String>> feeKinds(Iterable<int> payIds) async {
    final ids = payIds.toSet().toList();
    if (ids.isEmpty) return const {};
    try {
      final det = await SupabaseService.fromSchema('paymentdetails').select('pay_id, dem_id').inFilter('pay_id', ids);
      final demOf = <int, Set<int>>{};
      for (final d in det as List) {
        final p = ((d as Map)['pay_id'] as num?)?.toInt();
        final m = (d['dem_id'] as num?)?.toInt();
        if (p != null && m != null) (demOf[p] ??= {}).add(m);
      }
      final demIds = demOf.values.expand((e) => e).toSet().toList();
      if (demIds.isEmpty) return const {};
      final dem = await SupabaseService.fromSchema('feedemand').select('dem_id, demseqtype').inFilter('dem_id', demIds);
      final arrear = <int>{
        for (final d in dem as List)
          if ('${(d as Map)['demseqtype'] ?? ''}'.trim().toUpperCase() == 'ARREAR') (d['dem_id'] as num).toInt(),
      };
      return {
        for (final e in demOf.entries)
          e.key: e.value.every(arrear.contains)
              ? 'Arrear'
              : (e.value.any(arrear.contains) ? 'Regular + Arrear' : 'Regular'),
      };
    } catch (_) {
      return const {};
    }
  }

  /// The type line of a receipt row: "Fee Receipt · Regular", "Misc Receipt",
  /// "Advance Receipt".
  static String typeText(Map<String, dynamic> r, Map<int, String> feeKinds) {
    if (r['adv_id'] != null) return 'Advance Receipt';
    if (r['mc_id'] != null) return 'Misc Receipt';
    final k = feeKinds[(r['pay_id'] as num?)?.toInt()];
    return k == null ? 'Fee Receipt' : 'Fee Receipt · $k';
  }

  /// Students with a receipt whose number contains [q] -- fee, misc (when
  /// [misc]) and advance receipts of this year's current students. Each is the
  /// student row plus '_rkey' (the screens' receipt key: P:/M:/A:<id>) and
  /// '_rno' (the receipt number). Needs 3+ characters with a digit in them.
  static Future<List<Map<String, dynamic>>> findByReceiptNo(int insId, String q, {bool misc = true}) async {
    final t = q.trim();
    if (t.length < 3 || !RegExp(r'\d').hasMatch(t)) return const [];
    final pat = '%${t.replaceAll('%', '')}%';
    final hits = <({String key, String no, int? stuId, String? admno})>[];
    try {
      final rows = await SupabaseService.fromSchema('payment')
          .select('pay_id, paynumber, stu_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .ilike('paynumber', pat)
          .order('pay_id', ascending: false)
          .limit(15);
      for (final r in rows as List) {
        hits.add((key: 'P:${(r as Map)['pay_id']}', no: '${r['paynumber'] ?? ''}', stuId: (r['stu_id'] as num?)?.toInt(), admno: null));
      }
    } catch (_) {}
    if (misc) {
      try {
        final rows = await SupabaseService.fromSchema('misc_collection')
            .select('mc_id, mcno, stu_id, regno')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .ilike('mcno', pat)
            .order('mc_id', ascending: false)
            .limit(15);
        for (final r in rows as List) {
          hits.add((key: 'M:${(r as Map)['mc_id']}', no: '${r['mcno'] ?? ''}', stuId: (r['stu_id'] as num?)?.toInt(), admno: r['regno']?.toString()));
        }
      } catch (_) {}
    }
    try {
      final rows = await SupabaseService.fromSchema('advance_collection')
          .select('adv_id, advno, stu_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .ilike('advno', pat)
          .order('adv_id', ascending: false)
          .limit(15);
      for (final r in rows as List) {
        hits.add((key: 'A:${(r as Map)['adv_id']}', no: '${r['advno'] ?? ''}', stuId: (r['stu_id'] as num?)?.toInt(), admno: null));
      }
    } catch (_) {}
    if (hits.isEmpty) return const [];

    // The students -- current ones only, as both screens list.
    final byId = <int, Map<String, dynamic>>{};
    final byAdm = <String, Map<String, dynamic>>{};
    final ids = hits.map((h) => h.stuId).whereType<int>().toSet().toList();
    final adms = hits.where((h) => h.stuId == null).map((h) => h.admno).whereType<String>().where((s) => s.isNotEmpty).toSet().toList();
    const cols = 'stu_id, stuname, stuadmno, stuclass, courname, stuphoto';
    try {
      if (ids.isNotEmpty) {
        final rows = await SupabaseService.fromSchema('students').select(cols)
            .eq('ins_id', insId).eq('activestatus', 1).eq('preadmission', 0).inFilter('stu_id', ids);
        for (final s in rows as List) {
          byId[((s as Map)['stu_id'] as num).toInt()] = Map<String, dynamic>.from(s);
        }
      }
      if (adms.isNotEmpty) {
        final rows = await SupabaseService.fromSchema('students').select(cols)
            .eq('ins_id', insId).eq('activestatus', 1).eq('preadmission', 0).inFilter('stuadmno', adms);
        for (final s in rows as List) {
          byAdm['${(s as Map)['stuadmno']}'] = Map<String, dynamic>.from(s);
        }
      }
    } catch (_) {
      return const [];
    }
    return [
      for (final h in hits)
        if ((h.stuId != null ? byId[h.stuId] : byAdm[h.admno ?? '']) case final s?)
          {...s, '_rkey': h.key, '_rno': h.no},
    ];
  }
}
