import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/admission_model.dart';
import 'supabase_service.dart';
import '../utils/school_terms.dart';

/// Data access for the admission module.
///
/// Admissions live in the PUBLIC schema ([SupabaseService.client.from]),
/// not the per-institution schema, so capture works without tenant-schema
/// grants. The move into students/parents/parentdetail happens server-side
/// via the `allocate_admission_to_student` SECURITY DEFINER RPC.
class AdmissionService {
  AdmissionService._();

  static const _table = 'admission';

  /// Active admissions for an institution (newest first).
  static Future<List<AdmissionModel>> getAdmissions(int insId) async {
    try {
      const batchSize = 1000;
      int offset = 0;
      final List<Map<String, dynamic>> all = [];
      while (true) {
        final batch = await SupabaseService.client
            .from(_table)
            .select('*')
            .eq('ins_id', insId)
            // Include TC'd students (activestatus 2/3/4/5/9) as locked rows; only
            // truly CANCELLED admissions are hidden.
            .neq('admstatus', 'CANCELLED')
            .order('adm_id', ascending: false)
            .range(offset, offset + batchSize - 1);
        final list = (batch as List).cast<Map<String, dynamic>>();
        all.addAll(list);
        if (list.length < batchSize) break;
        offset += batchSize;
      }
      return all.map(AdmissionModel.fromJson).toList();
    } catch (e) {
      debugPrint('Error fetching admissions: $e');
      return [];
    }
  }

  /// Next admission number, formatted ADM00001 (best-effort, per institution).
  static Future<String> nextAdmissionNo(int insId) async {
    try {
      final count = await SupabaseService.client
          .from(_table)
          .count()
          .eq('ins_id', insId);
      return 'ADM${(count + 1).toString().padLeft(5, '0')}';
    } catch (e) {
      debugPrint('Error computing next admission no: $e');
      return 'ADM${DateTime.now().millisecondsSinceEpoch % 100000}';
    }
  }

  /// Insert a new admission — returns the new adm_id.
  static Future<int> addAdmission(Map<String, dynamic> data) async {
    final token = SupabaseService.sessionToken;
    if (token != null) {
      try {
        final res = await SupabaseService.client.rpc('save_admission', params: {
          'p_token': token, 'p_data': data, 'p_adm_id': null,
        });
        return (res as num).toInt();
      } on PostgrestException catch (e) {
        if (!SupabaseService.isMissingRpc(e)) rethrow; // not deployed yet → fallback
      }
    }
    final response = await SupabaseService.client
        .from(_table)
        .insert(data)
        .select('adm_id')
        .maybeSingle();
    if (response == null) {
      throw Exception('Admission insert returned no data (check RLS or required columns)');
    }
    return response['adm_id'] as int;
  }

  /// New admission numbered BY THE SERVER inside the same save: save_admission
  /// claims the next free number of [seqId] under the sequence row lock
  /// (skipping numbers already used) and inserts the admission in one
  /// transaction -- two users saving together get different numbers, and a
  /// save that fails uses none. Returns the new adm_id and the number given.
  static Future<({int admId, String admno})> addAdmissionNumbered(Map<String, dynamic> data, int seqId) async {
    final token = SupabaseService.sessionToken;
    final body = Map<String, dynamic>.from(data)
      ..remove('admno')
      ..['_seq_id'] = seqId;
    final res = await SupabaseService.client.rpc('save_admission', params: {
      'p_token': token, 'p_data': body, 'p_adm_id': null,
    });
    final admId = (res as num).toInt();
    final row = await SupabaseService.client.from(_table).select('admno').eq('adm_id', admId).maybeSingle();
    return (admId: admId, admno: (row?['admno'] ?? '').toString());
  }

  /// Update an existing admission.
  static Future<void> updateAdmission(int admId, Map<String, dynamic> data) async {
    final token = SupabaseService.sessionToken;
    if (token != null) {
      try {
        await SupabaseService.client.rpc('save_admission', params: {
          'p_token': token, 'p_data': data, 'p_adm_id': admId,
        });
        return;
      } on PostgrestException catch (e) {
        if (!SupabaseService.isMissingRpc(e)) rethrow;
      }
    }
    await SupabaseService.client.from(_table).update(data).eq('adm_id', admId);
  }

  /// Soft-cancel an admission (still PENDING — never allocated).
  static Future<void> cancelAdmission(int admId, {String? by}) async {
    await updateAdmission(admId, {
      'admstatus': AdmissionStatus.cancelled,
      'allocatedby': by,
    });
  }

  // ── admission masters (admissiontype / quota / community) ─────────────────

  /// Active rows of a per-schema master table, ordered by [orderCol].
  static Future<List<Map<String, dynamic>>> getMasterRows(String table, String orderCol) async {
    // A school has no admission-type / quota tables.
    if (isSchool && (table == 'admissiontype' || table == 'quota')) return [];
    try {
      final res = await SupabaseService.fromSchema(table)
          .select('*')
          .eq('activestatus', 1)
          .order(orderCol, ascending: true);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('getMasterRows($table) error: $e');
      return [];
    }
  }

  /// Next id for a smallint-PK master (max + 1) — these tables have no sequence.
  static Future<int> nextMasterId(String table, String idCol) async {
    if (isSchool && (table == 'admissiontype' || table == 'quota')) return 1;
    try {
      final res = await SupabaseService.fromSchema(table)
          .select(idCol)
          .order(idCol, ascending: false)
          .limit(1)
          .maybeSingle();
      final cur = res?[idCol];
      final n = cur is int ? cur : int.tryParse(cur?.toString() ?? '0') ?? 0;
      return n + 1;
    } catch (e) {
      debugPrint('nextMasterId($table) error: $e');
      return 1;
    }
  }

  static Future<void> addMasterRow(String table, Map<String, dynamic> data) async {
    await SupabaseService.saveSchemaRow(table, data);
  }

  static Future<void> deleteMasterRow(String table, String idCol, int id) async {
    await SupabaseService.deleteSchemaRow(table, idCol, id);
  }

  static Future<void> updateMasterRow(String table, String idCol, int id, Map<String, dynamic> data) async {
    await SupabaseService.saveSchemaRow(table, data, pkCol: idCol, pkVal: id);
  }

  // ── register-number sequences ────────────────────────────────────────────
  // These live as rows in the shared `sequence` table (discriminated by
  // actname='REGNO' / fg_id NULL), NOT a separate regnoseq table anymore.

  /// Active register-number sequences (actname='REGNO'), oldest first.
  static Future<List<Map<String, dynamic>>> getRegSequences({String actname = 'REGNO'}) async {
    try {
      final res = await SupabaseService.fromSchema('sequence')
          .select('*')
          .eq('actname', actname)
          .eq('activestatus', 1)
          .order('seq_id', ascending: true);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('getRegSequences error: $e');
      return [];
    }
  }

  /// Insert a register-number sequence (seq_id is auto-generated — do not set it).
  static Future<void> addRegSequence(Map<String, dynamic> data) async {
    await SupabaseService.saveSchemaRow('sequence', data);
  }

  /// Soft-delete a register-number sequence by its seq_id.
  static Future<void> deleteRegSequence(int seqId) async {
    await SupabaseService.deleteSchemaRow('sequence', 'seq_id', seqId);
  }

  /// Claim the next number from a register sequence ON THE SERVER
  /// (claim_reg_no: locks the sequence row, advances it and returns the
  /// formatted number in one statement), so two operators saving at the same
  /// moment never get the same number. A claimed number stays used even if the
  /// save then fails -- a gap, never a duplicate.
  ///
  /// Returns null when the RPC is not deployed, so a database without it still
  /// saves (on the old client-computed number) instead of refusing.
  static Future<String?> claimRegNo(int seqId) async {
    final token = SupabaseService.sessionToken;
    if (token == null) return null;
    try {
      final res = await SupabaseService.client.rpc('claim_reg_no', params: {
        'p_token': token,
        'p_seq_id': seqId,
      });
      final no = res?.toString().trim() ?? '';
      return no.isEmpty ? null : no;
    } on PostgrestException catch (e) {
      if (SupabaseService.isMissingRpc(e)) return null;
      rethrow;
    }
  }

  /// Advance a register-number sequence's running counter after it's used.
  static Future<void> bumpRegSeqCurrent(int seqId, int newCurrent) async {
    await SupabaseService.saveSchemaRow('sequence', {'seqcurno': newCurrent},
        pkCol: 'seq_id', pkVal: seqId);
  }

  /// The institution's active academic year as {yr_id, yrlabel} (newest first),
  /// or {0, ''} if none — used to fill the sequence row's NOT NULL year columns.
  static Future<Map<String, dynamic>> getActiveYear(int insId) async {
    try {
      final row = await SupabaseService.fromSchema('year')
          .select('yr_id, yrlabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('yr_id', ascending: false)
          .limit(1)
          .maybeSingle();
      return {
        'yr_id': row?['yr_id'] ?? 0,
        'yrlabel': row?['yrlabel']?.toString() ?? '',
      };
    } catch (e) {
      debugPrint('getActiveYear error: $e');
      return {'yr_id': 0, 'yrlabel': ''};
    }
  }

  /// Allocate a class and move the admission into the institution schema's
  /// students/parents/parentdetail tables. Returns the new stu_id.
  static Future<int> allocateClass({
    required int admId,
    required String className,
    required String stuadmno,
    String? allocatedBy,
  }) async {
    final schema = SupabaseService.currentSchema;
    if (schema == null || schema.isEmpty) {
      throw Exception('No institution schema is set — cannot allocate.');
    }
    dynamic result;
    final token = SupabaseService.sessionToken;
    if (token != null) {
      try {
        // Token-gated wrapper — verifies the admission is ours and derives the
        // schema server-side (client can't pass an arbitrary p_schema).
        result = await SupabaseService.client.rpc(
          'allocate_admission_secure',
          params: {
            'p_token': token,
            'p_adm_id': admId,
            'p_class': className,
            'p_stuadmno': stuadmno,
            'p_allocatedby': allocatedBy,
          },
        );
      } on PostgrestException catch (e) {
        if (!SupabaseService.isMissingRpc(e)) rethrow;
      }
    }
    result ??= await SupabaseService.client.rpc(
      'allocate_admission_to_student',
      params: {
        'p_adm_id': admId,
        'p_schema': schema,
        'p_class': className,
        'p_stuadmno': stuadmno,
        'p_allocatedby': allocatedBy,
      },
    );
    final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
    final stuId = map['stu_id'];
    return stuId is int ? stuId : int.tryParse(stuId?.toString() ?? '') ?? 0;
  }
}
