import 'package:flutter/foundation.dart';
import '../models/admission_model.dart';
import 'supabase_service.dart';

/// Data access for the admission module. Admission, community, and regnoseq
/// all live in PUBLIC — the move into per-schema students/parents/parentdetail
/// happens server-side via the `allocate_admission_to_student` SECURITY
/// DEFINER RPC.
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
            .eq('activestatus', 1)
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

  /// Insert a new admission — returns the new adm_id.
  static Future<int> addAdmission(Map<String, dynamic> data) async {
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

  /// Update an existing admission.
  static Future<void> updateAdmission(int admId, Map<String, dynamic> data) async {
    await SupabaseService.client.from(_table).update(data).eq('adm_id', admId);
  }

  /// Soft-cancel an admission (still PENDING — never allocated).
  static Future<void> cancelAdmission(int admId, {String? by}) async {
    await updateAdmission(admId, {
      'admstatus': AdmissionStatus.cancelled,
      'allocatedby': by,
    });
  }

  // ── admission masters ────────────────────────────────────────────────────
  // community + regnoseq live in PUBLIC (default).
  // termperiod lives in the per-institution SCHEMA — pass inSchema: true.

  static dynamic _src(String table, bool inSchema) =>
      inSchema ? SupabaseService.fromSchema(table) : SupabaseService.client.from(table);

  /// Active rows of a master table, ordered by [orderCol].
  static Future<List<Map<String, dynamic>>> getMasterRows(String table, String orderCol,
      {bool inSchema = false}) async {
    try {
      final res = await _src(table, inSchema)
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
  static Future<int> nextMasterId(String table, String idCol, {bool inSchema = false}) async {
    try {
      final res = await _src(table, inSchema)
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

  static Future<void> addMasterRow(String table, Map<String, dynamic> data,
      {bool inSchema = false}) async {
    await _src(table, inSchema).insert(data);
  }

  static Future<void> deleteMasterRow(String table, String idCol, int id,
      {bool inSchema = false}) async {
    await _src(table, inSchema).update({'activestatus': 0}).eq(idCol, id);
  }

  static Future<void> updateMasterRow(String table, String idCol, int id, Map<String, dynamic> data,
      {bool inSchema = false}) async {
    await _src(table, inSchema).update(data).eq(idCol, id);
  }

  /// Advance a register-number sequence's running counter after it's used.
  static Future<void> bumpRegSeqCurrent(int rnsId, int newCurrent) async {
    await SupabaseService.client
        .from('regnoseq')
        .update({'rnscurrent': newCurrent})
        .eq('rns_id', rnsId);
  }

  /// Allocate a section and move the admission into the institution schema's
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
    final result = await SupabaseService.client.rpc(
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
