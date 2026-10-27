import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/student_model.dart';
import '../models/institution_user_model.dart';
import '../models/payment_model.dart';
import '../models/fee_model.dart';

/// Central Supabase service for all database queries
class SupabaseService {
  static SupabaseClient get client => Supabase.instance.client;

  /// Current institution schema name (e.g. 'kcet20262027')
  static String? _currentSchema;
  static String? get currentSchema => _currentSchema;

  /// Server-issued session token for the logged-in user (security foundation).
  /// AuthProvider sets this after login and clears it on logout. The centralized
  /// write helpers below route through session-gated RPCs when it's present.
  static String? sessionToken;

  /// Set the schema after login
  static void setSchema(String? schema) {
    final changed = schema != _currentSchema;
    _currentSchema = schema;
    debugPrint('SupabaseService schema set to: $schema');
    if (changed) {
      _publicMasterTables.clear();
      _masterTablesReady = (schema == null || schema.isEmpty)
          ? Future.value()
          : _resolveMasterTables(schema);
    }
  }

  /// Master tables that live per-institution in the college layout but in
  /// PUBLIC (shared, filtered by ins_id) in the school layout.
  static const List<String> _masterTableCandidates = [
    'class', 'feegroup', 'feetype', 'bank', 'community', 'division', 'medium', 'clagrp',
    'course', 'concessioncategory',
  ];

  /// Candidates this database keeps in public — resolved per schema by
  /// [_resolveMasterTables]. Empty on the college layout.
  static final Set<String> _publicMasterTables = {};
  static Future<void> _masterTablesReady = Future.value();

  /// Completes once [setSchema] has worked out where the master tables live.
  /// Await it after setSchema, before the first fromSchema() query.
  static Future<void> get masterTablesReady => _masterTablesReady;

  /// True on the school database: masters (incl. course) in public, shown as
  /// Standard / Section, and no admission type / quota / batch.
  static bool get isSchoolLayout => _publicMasterTables.contains('feetype');

  /// Probe each candidate in the institution schema: a "table not found"
  /// answer means this database keeps it in public. Any other outcome
  /// (rows, empty under RLS, other errors) keeps the schema copy, so the
  /// college layout is never rerouted.
  static Future<void> _resolveMasterTables(String schema) async {
    await Future.wait(_masterTableCandidates.map((t) async {
      try {
        await client.schema(schema).from(t).select().limit(1);
      } on PostgrestException catch (e) {
        if (e.code == 'PGRST205' || e.code == '42P01') {
          if (_currentSchema == schema) _publicMasterTables.add(t);
        }
      } catch (_) {}
    }));
    if (_publicMasterTables.isNotEmpty) {
      debugPrint('SupabaseService: master tables in public for $schema: $_publicMasterTables');
    }
  }

  /// Query from institution-specific schema table
  /// Falls back to public if no schema is set, or if this database keeps the
  /// table in public (school layout — see [_resolveMasterTables]).
  static SupabaseQueryBuilder fromSchema(String table) {
    if (_currentSchema != null && _currentSchema!.isNotEmpty &&
        !_publicMasterTables.contains(table)) {
      return client.schema(_currentSchema!).from(table);
    }
    return client.from(table);
  }

  // ==================== LICENSE ====================

  /// Verify a license key against the institutionyear table
  static Future<Map<String, dynamic>> verifyLicenseKey(String licenseKey) async {
    try {
      final result = await client.rpc('verify_license_key', params: {
        'p_license_key': licenseKey.trim(),
      });
      debugPrint('License verification result: $result');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      debugPrint('License verification error: $e');
      return {'valid': false, 'message': 'Connection error. Please try again.'};
    }
  }

  // ==================== AUTH ====================

  /// Login institution user by email (or username for super admin), returns user if found
  /// Columns the login reads from institutionusers — every field
  /// InstitutionUserModel uses, but NOT usepassword. Selecting `*` would fail
  /// once anon's SELECT on the password-hash column is revoked.
  static const String _loginUserColumns =
      'use_id, ins_id, inscode, usename, usemail, usephone, usestadate, '
      'useotpstatus, usedob, ur_id, urname, des_id, desname, userepto, '
      'usecategory, activestatus';

  static Future<InstitutionUserModel?> loginUser({
    required String email,
    required String password,
    int? insId,
    bool isSuperAdmin = false,
    String? selectedYearLabel,
  }) async {
    try {
      List<dynamic> result;
      try {
        result = await client.rpc('verify_user_login', params: {
          'p_email': email.trim(),
          'p_plain_password': password,
          'p_is_super_admin': isSuperAdmin,
        });
      } catch (e) {
        // Fallback: old RPC signature without p_is_super_admin
        debugPrint('LOGIN: New RPC failed ($e), trying old signature');
        result = await client.rpc('verify_user_login', params: {
          'p_email': email.trim(),
          'p_plain_password': password,
        });
      }

      debugPrint('Login RPC result: $result');

      if (result.isEmpty) return null;

      final row = result.first as Map<String, dynamic>;
      if (row['is_valid'] != true) return null;

      final useId = row['use_id'];
      final isSuperAdminUser = isSuperAdmin || row['urname']?.toString() == 'Super Admin';

      // Super admin lives in public table, institution users in schema table
      Map<String, dynamic>? response;
      if (isSuperAdminUser) {
        var query = client
            .from('institutionusers')
            .select(_loginUserColumns)
            .eq('use_id', useId)
            .eq('activestatus', 1);
        response = await query.maybeSingle();
      } else {
        // Resolve schema from insId before querying
        if (insId != null) {
          final insRow = await client
              .from('institution')
              .select('inshortname')
              .eq('ins_id', insId)
              .maybeSingle();
          debugPrint('LOGIN: insRow=$insRow for insId=$insId');
          if (insRow != null && insRow['inshortname'] != null) {
            final shortName = (insRow['inshortname'] as String).toLowerCase();
            String? yearLabel = selectedYearLabel;
            if (yearLabel == null || yearLabel.isEmpty) {
              final yearRows = await client
                  .from('institutionyear')
                  .select('yrlabel')
                  .eq('ins_id', insId)
                  .eq('activestatus', 1)
                  .order('yrlabel', ascending: false)
                  .limit(1);
              debugPrint('LOGIN: yearRows=$yearRows');
              if ((yearRows as List).isNotEmpty) {
                yearLabel = yearRows.first['yrlabel'] as String;
              }
            }
            if (yearLabel != null) {
              final schema = '$shortName${yearLabel.replaceAll('-', '')}';
              debugPrint('LOGIN: Setting schema to $schema');
              setSchema(schema);
            }
          }
        }
        debugPrint('LOGIN: Querying schema=$_currentSchema for use_id=$useId');
        try {
          var query = client.from('institutionusers')
              .select(_loginUserColumns)
              .eq('use_id', useId)
              .eq('activestatus', 1);
          if (insId != null) {
            query = query.eq('ins_id', insId);
          }
          response = await query.maybeSingle();
          debugPrint('LOGIN: Schema user response=$response');
        } catch (e) {
          debugPrint('LOGIN: Schema query error: $e');
        }

        // Fallback: try public table if schema lookup returned nothing or failed
        if (response == null) {
          debugPrint('LOGIN: Trying public table fallback');
          try {
            var fallbackQuery = client
                .from('institutionusers')
                .select(_loginUserColumns)
                .eq('use_id', useId)
                .eq('activestatus', 1);
            if (insId != null) {
              fallbackQuery = fallbackQuery.eq('ins_id', insId);
            }
            response = await fallbackQuery.maybeSingle();
            debugPrint('LOGIN: Public fallback response=$response');
          } catch (e) {
            debugPrint('LOGIN: Public fallback error: $e');
          }
        }

        // Institute login REQUIRES a real institutionusers row for the
        // selected institution. Without this guard, a user belonging to
        // institution A could log into institution B by picking it on the
        // dropdown — the old "build from RPC result" fallback let that
        // through and seeded ins_id with whatever the user picked.
        if (response == null) {
          debugPrint('LOGIN: No institutionusers row for use_id=$useId ins_id=$insId — denying login');
          return null;
        }
        // Belt-and-braces: enforce ins_id equality on the row we found.
        if (insId != null && response['ins_id'] != insId) {
          debugPrint('LOGIN: row ins_id=${response['ins_id']} != selected $insId — denying login');
          return null;
        }
      }

      if (response == null) return null;

      // Fine generation is no longer triggered at login — fines are now
      // refreshed per-student at the moment a cashier opens their fee
      // collection form (see student_fee_collection_screen._searchStudent).

      return InstitutionUserModel.fromJson(response);
    } catch (e) {
      debugPrint('Login error: $e');
      return null;
    }
  }

  // ==================== SESSION TOKEN (security foundation) ====================

  /// Mint a server-side session token after a successful login. The RPC
  /// re-verifies the bcrypt password (scoped to the institution) and returns a
  /// raw token whose hash it stores in public.app_session. Write RPCs will
  /// require this token and derive ins_id/role from it server-side. See
  /// migrations/secure_app_session.sql and docs/SECURITY_REVIEW.md.
  static Future<String?> createAppSession({
    required String email,
    required String password,
    required int insId,
    bool isSuperAdmin = false,
  }) async {
    final token = await client.rpc('create_app_session', params: {
      'p_email': email,
      'p_plain_password': password,
      'p_ins_id': insId,
      'p_is_super_admin': isSuperAdmin,
    });
    return token?.toString();
  }

  /// Tell the server which academic year this session works in, so the
  /// session-gated RPCs (collection, demands, advance, reconcile ...) use that
  /// year's schema -- see school_session_year.sql. Best-effort: a database
  /// without set_session_year keeps using its newest year.
  static Future<void> setSessionYear(String yearLabel) async {
    final token = sessionToken;
    if (token == null || token.isEmpty || yearLabel.isEmpty) return;
    try {
      await client.rpc('set_session_year', params: {'p_token': token, 'p_yrlabel': yearLabel});
    } catch (e) {
      debugPrint('set_session_year($yearLabel) failed: $e');
    }
  }

  /// Revoke a session token (logout). Best-effort.
  static Future<void> revokeSession(String token) async {
    await client.rpc('revoke_session', params: {'p_token': token});
  }

  /// Complete a grouped payment. With a non-empty [token] it routes through the
  /// session-gated `complete_payment_secure` wrapper (ins_id derived server-side
  /// from the token); otherwise it falls back to the legacy
  /// `complete_payment_grouped`. Non-breaking during the security rollout — see
  /// migrations/secure_payments_phase1.sql.
  static Future<dynamic> completePaymentGrouped({
    required int payId,
    required String payMethod,
    String? payReference,
    required List<dynamic> items,
    int? insId,
    String status = 'C',
    String? token,
  }) {
    if (token != null && token.isNotEmpty) {
      return client.rpc('complete_payment_secure', params: {
        'p_token': token,
        'p_pay_id': payId,
        'p_pay_method': payMethod,
        'p_pay_reference': payReference,
        'p_items': items,
        'p_status': status,
      });
    }
    return client.rpc('complete_payment_grouped', params: {
      'p_pay_id': payId,
      'p_pay_method': payMethod,
      'p_pay_reference': payReference,
      'p_items': items,
      'p_ins_id': insId,
      'p_status': status,
    });
  }

  /// Grouped multi-fee-group collection. With a non-empty [token] it routes
  /// through `process_grouped_payment_secure` (ins_id derived server-side); else
  /// falls back to `process_grouped_payment`.
  static Future<dynamic> processGroupedPayment({
    int? insId,
    String? inscode,
    int? stuId,
    int? yrId,
    String? yrlabel,
    required num totalAmount,
    String? createdBy,
    required String payMethod,
    String? payReference,
    required List<dynamic> items,
    String? token,
  }) {
    if (token != null && token.isNotEmpty) {
      return client.rpc('process_grouped_payment_secure', params: {
        'p_token': token,
        'p_inscode': inscode,
        'p_stu_id': stuId,
        'p_yr_id': yrId,
        'p_yrlabel': yrlabel,
        'p_total_amount': totalAmount,
        'p_created_by': createdBy,
        'p_pay_method': payMethod,
        'p_pay_reference': payReference,
        'p_items': items,
      });
    }
    return client.rpc('process_grouped_payment', params: {
      'p_ins_id': insId,
      'p_inscode': inscode,
      'p_stu_id': stuId,
      'p_yr_id': yrId,
      'p_yrlabel': yrlabel,
      'p_total_amount': totalAmount,
      'p_created_by': createdBy,
      'p_pay_method': payMethod,
      'p_pay_reference': payReference,
      'p_items': items,
    });
  }

  // ---- Phase 1b: session-gated feedemand mutations (token → RPC, else legacy).
  // See migrations/secure_feedemand_phase1b.sql.

  /// Set/clear the fine on one demand.
  static Future<void> setDemandFine({required int demId, required num fineamount, String? token}) async {
    if (token != null && token.isNotEmpty) {
      try {
        await client.rpc('set_demand_fine', params: {'p_token': token, 'p_dem_id': demId, 'p_fineamount': fineamount});
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow; // RPC not deployed yet → safe idempotent fallback
      }
    }
    await fromSchema('feedemand').update({'fineamount': fineamount}).eq('dem_id', demId);
  }

  /// Apply a concession to one demand.
  static Future<void> applyConcession({required int demId, int? conId, required num conamount, required num balancedue, String? token}) async {
    if (token != null && token.isNotEmpty) {
      try {
        await client.rpc('apply_concession', params: {
          'p_token': token, 'p_dem_id': demId, 'p_con_id': conId, 'p_conamount': conamount, 'p_balancedue': balancedue,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('feedemand').update({
      'con_id': conId, 'conamount': conamount, 'balancedue': balancedue, 'reconbalancedue': balancedue,
    }).eq('dem_id', demId);
  }

  /// Save a per-student fee definition. [balancedue] null = amount unchanged (don't touch outstanding).
  static Future<void> saveFeeDefinition({required int demId, required num feeamount, required bool collectible, num? balancedue, String? token}) async {
    if (token != null && token.isNotEmpty) {
      try {
        await client.rpc('save_fee_definition', params: {
          'p_token': token, 'p_dem_id': demId, 'p_feeamount': feeamount, 'p_collectible': collectible, 'p_balancedue': balancedue,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    final data = <String, dynamic>{'feeamount': feeamount, 'collectible': collectible};
    if (balancedue != null) { data['balancedue'] = balancedue; data['reconbalancedue'] = balancedue; }
    await fromSchema('feedemand').update(data).eq('dem_id', demId);
  }

  /// New Roll Number — renumber students. The RPC replaces stuadmno and
  /// cascades the new number to every table keyed by it (plus admission.admno)
  /// in one transaction, then logs each change. [rows] = [{oldrollno, newrollno}].
  /// Returns how many students were renumbered.
  static Future<int> saveRollNoChange({
    required DateTime effectDate,
    required List<Map<String, dynamic>> rows,
    String? createdBy,
    String? token,
  }) async {
    token ??= sessionToken;
    final d = '${effectDate.year.toString().padLeft(4, '0')}-'
        '${effectDate.month.toString().padLeft(2, '0')}-'
        '${effectDate.day.toString().padLeft(2, '0')}';
    final res = await client.rpc('save_rollno_change', params: {
      'p_token': token, 'p_effectdate': d, 'p_rows': rows, 'p_createdby': createdBy,
    });
    return res is int ? res : int.tryParse(res?.toString() ?? '') ?? 0;
  }

  /// Transfer Certificate — issue/edit a TC for one student. Writes the tc_entry
  /// row and stamps the leaving status (1..5,9) onto the student + admission.
  /// [tcId] null = new, else update in place. Returns the tc_id.
  static Future<int?> saveTcEntry(Map<String, dynamic> data, {int? tcId, String? token}) async {
    token ??= sessionToken;
    final res = await client.rpc('save_tc_entry', params: {
      'p_token': token, 'p_data': data, 'p_tc_id': tcId,
    });
    return res is int ? res : int.tryParse(res?.toString() ?? '');
  }

  /// Transfer Certificate — delete a TC entry and revert the student + admission
  /// back to active (1).
  static Future<void> deleteTcEntry(int tcId, {String? token}) async {
    token ??= sessionToken;
    await client.rpc('delete_tc_entry', params: {'p_token': token, 'p_tc_id': tcId});
  }

  /// Student Fee Definition — add a fee the student doesn't yet have, from a
  /// classfeedemand template row (cf_id). Session-gated RPC resolves the student
  /// + template server-side; falls back to a direct insert of [fallbackRow].
  static Future<void> addStudentFeeDemand({
    required String stuAdmno, required int cfId, required num amount,
    Map<String, dynamic>? fallbackRow, String? token,
  }) async {
    // REFUSED HERE AS WELL AS IN THE RPC, because of the fallback below: on a
    // database without the RPC this method inserts fallbackRow directly, and
    // no server-side guard can see that. A demand billed 0 reads as fully
    // settled the moment it exists, so it is never chased -- that is how
    // dem_id 10126 came to hold Rs 10,000 against a bill of nothing.
    if (amount <= 0) {
      throw ArgumentError(
          'Enter the amount for this fee. A fee added with no amount is billed '
          '0, reads as fully settled and is never collected. If the student is '
          'not charged this fee, remove it instead of leaving it blank.');
    }
    token ??= sessionToken;
    if (token != null && token.isNotEmpty) {
      try {
        await client.rpc('add_student_fee_demand', params: {
          'p_token': token, 'p_stuadmno': stuAdmno, 'p_cf_id': cfId, 'p_amount': amount,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    if (fallbackRow != null) await fromSchema('feedemand').insert(fallbackRow);
  }

  /// Student Fee Definition — remove a fee the student no longer needs. The RPC
  /// refuses if anything has been collected on it. Session-gated; falls back to
  /// a direct delete guarded on paidamount = 0.
  static Future<void> deleteStudentFeeDemand(int demId, {String? token}) async {
    token ??= sessionToken;
    if (token != null && token.isNotEmpty) {
      try {
        await client.rpc('delete_student_fee_demand', params: {'p_token': token, 'p_dem_id': demId});
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('feedemand').delete().eq('dem_id', demId).eq('paidamount', 0);
  }

  /// Cascade a student's class/course onto all their demand rows (Section
  /// Transfer). Session-gated; falls back to a direct update.
  static Future<void> updateDemandClass(int stuId, String stuclass, {String? courname}) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('update_demand_class', params: {
          'p_token': token, 'p_stu_id': stuId, 'p_class': stuclass, 'p_courname': courname,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    final data = <String, dynamic>{'stuclass': stuclass};
    if (courname != null && courname.isNotEmpty) data['courname'] = courname;
    await fromSchema('feedemand').update(data).eq('stu_id', stuId);
  }

  /// Push recomputed amounts into one demand row (Fee Master edit-mode).
  /// Session-gated; falls back to a direct update.
  static Future<void> rebuildDemand(int demId,
      {required num feeamount, required num balancedue, required bool collectible}) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('rebuild_demand', params: {
          'p_token': token, 'p_dem_id': demId, 'p_feeamount': feeamount,
          'p_balancedue': balancedue, 'p_collectible': collectible,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('feedemand').update({
      'feeamount': feeamount, 'balancedue': balancedue,
      'reconbalancedue': balancedue, 'collectible': collectible,
    }).eq('dem_id', demId);
  }

  /// Session-gated: create the temporary 'I' payment row (ins_id + paystatus
  /// forced server-side). Falls back to a direct insert. Returns the new pay_id.
  static Future<int> insertPayment(Map<String, dynamic> data) async {
    final token = sessionToken;
    if (token != null) {
      try {
        final res = await client.rpc('insert_payment', params: {'p_token': token, 'p_data': data});
        return (res as num).toInt();
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    final resp = await fromSchema('payment').insert(data).select('pay_id').single();
    return resp['pay_id'] as int;
  }

  /// Session-gated: whitelisted pre-completion field update on one payment row
  /// (payorderid/payreference/cheque/tender/paystatus F|I|P — never 'C'/'R').
  static Future<void> updatePayment(int payId, Map<String, dynamic> data) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('update_payment', params: {'p_token': token, 'p_pay_id': payId, 'p_data': data});
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('payment').update(data).eq('pay_id', payId);
  }

  /// Session-gated: mark all of a student's pending ('I') payments failed to
  /// release the 15-min pending lock. Falls back to a direct bulk update.
  static Future<void> failPendingPayments(int stuId) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('fail_pending_payments', params: {'p_token': token, 'p_stu_id': stuId});
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('payment').update({'paystatus': 'F'}).eq('stu_id', stuId).eq('paystatus', 'I');
  }

  /// Batch reconcile payments. With a [token] it routes through the session-gated
  /// reconcile_payments_secure wrapper (ins_id/schema derived server-side); else
  /// the legacy reconcile_payments_batch. See migrations/secure_reconcile_phase1b.sql.
  static Future<int> reconcilePayments({
    required List<int> payIds,
    required int insId,
    required String schema,
    required String userName,
    String? bankRef,
    String? bankDate,
    String? token,
  }) async {
    final r = (token != null && token.isNotEmpty)
        ? await client.rpc('reconcile_payments_secure', params: {
            'p_token': token, 'p_pay_ids': payIds, 'p_user': userName,
            'p_bank_ref': bankRef, 'p_bank_date': bankDate,
          })
        : await client.rpc('reconcile_payments_batch', params: {
            'p_schema': schema, 'p_ins_id': insId, 'p_pay_ids': payIds, 'p_user': userName,
            'p_bank_ref': bankRef, 'p_bank_date': bankDate,
          });
    return (r as num?)?.toInt() ?? payIds.length;
  }

  /// True when a PostgrestException means the RPC isn't deployed yet — so an
  /// IDEMPOTENT write may safely fall back to a direct table update. Do NOT use
  /// for non-idempotent RPCs (e.g. payment completion), where a partial run then
  /// a fallback could double-process.
  static bool _missingRpc(PostgrestException e) {
    final c = e.code ?? '';
    final m = e.message.toLowerCase();
    return c == '42883' || c == 'PGRST202' ||
        m.contains('does not exist') || m.contains('could not find the function');
  }

  /// Public alias so other libraries (e.g. AdmissionService) can share the
  /// "RPC not deployed yet → fall back to a direct write" detection.
  static bool isMissingRpc(PostgrestException e) => _missingRpc(e);

  /// Session-gated generic upsert for whitelisted institution-schema master
  /// tables (see migrations/secure_masters_groupd.sql). Routes through the
  /// save_schema_row RPC when a token exists, else falls back to a direct write.
  /// Returns the row's pk on insert when [pkCol] is given, else null.
  static Future<int?> saveSchemaRow(String table, Map<String, dynamic> data,
      {String? pkCol, int? pkVal}) async {
    final token = sessionToken;
    if (token != null) {
      try {
        final res = await client.rpc('save_schema_row', params: {
          'p_token': token, 'p_table': table, 'p_data': data,
          'p_pk_col': pkCol, 'p_pk_val': pkVal,
        });
        return (res as num?)?.toInt();
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    if (pkVal == null) {
      if (pkCol != null) {
        final resp = await fromSchema(table).insert(data).select(pkCol).maybeSingle();
        return (resp?[pkCol] as num?)?.toInt();
      }
      await fromSchema(table).insert(data);
      return null;
    }
    await fromSchema(table).update(data).eq(pkCol!, pkVal);
    return pkVal;
  }

  /// Session-gated generic soft/hard delete for whitelisted master tables.
  static Future<void> deleteSchemaRow(String table, String pkCol, int pkVal,
      {bool soft = true}) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('delete_schema_row', params: {
          'p_token': token, 'p_table': table, 'p_pk_col': pkCol,
          'p_pk_val': pkVal, 'p_soft': soft,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    if (soft) {
      await fromSchema(table).update({'activestatus': 0}).eq(pkCol, pkVal);
    } else {
      await fromSchema(table).delete().eq(pkCol, pkVal);
    }
  }

  /// Session-gated generic upsert for whitelisted institution-scoped PUBLIC
  /// tables (institutionusers, staffdesignation — see
  /// migrations/secure_publicrows_groupc2.sql). ins_id is forced server-side and
  /// UPDATEs are scoped by it. Returns the pk on insert when [pkCol] is given.
  static Future<int?> savePublicRow(String table, Map<String, dynamic> data,
      {String? pkCol, int? pkVal}) async {
    final token = sessionToken;
    if (token != null) {
      try {
        final res = await client.rpc('save_public_row', params: {
          'p_token': token, 'p_table': table, 'p_data': data,
          'p_pk_col': pkCol, 'p_pk_val': pkVal,
        });
        return (res as num?)?.toInt();
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    if (pkVal == null) {
      if (pkCol != null) {
        final resp = await client.from(table).insert(data).select(pkCol).maybeSingle();
        return (resp?[pkCol] as num?)?.toInt();
      }
      await client.from(table).insert(data);
      return null;
    }
    await client.from(table).update(data).eq(pkCol!, pkVal);
    return pkVal;
  }

  /// Session-gated generic soft/hard delete for whitelisted public tables.
  static Future<void> deletePublicRow(String table, String pkCol, int pkVal,
      {bool soft = true}) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('delete_public_row', params: {
          'p_token': token, 'p_table': table, 'p_pk_col': pkCol,
          'p_pk_val': pkVal, 'p_soft': soft,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    if (soft) {
      await client.from(table).update({'activestatus': 0}).eq(pkCol, pkVal);
    } else {
      await client.from(table).delete().eq(pkCol, pkVal);
    }
  }

  /// Session-gated batch import (insert, or upsert-on-[conflictCol]) for
  /// whitelisted master tables. Falls back to a direct batch write. Returns
  /// the number of rows affected (best-effort). See secure_imports_groupd2.sql.
  static Future<int> importSchemaRows(String table, List<Map<String, dynamic>> rows,
      {String? conflictCol}) async {
    if (rows.isEmpty) return 0;
    final token = sessionToken;
    if (token != null) {
      try {
        final res = await client.rpc('import_schema_rows', params: {
          'p_token': token, 'p_table': table, 'p_rows': rows, 'p_conflict_col': conflictCol,
        });
        return (res as num?)?.toInt() ?? rows.length;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    if (conflictCol != null) {
      await fromSchema(table).upsert(rows, onConflict: conflictCol);
    } else {
      await fromSchema(table).insert(rows);
    }
    return rows.length;
  }

  /// Session-gated compound-condition (equality/IS NULL) delete for whitelisted
  /// master tables — e.g. classfeedemand cleared by class+term+admissiontype.
  static Future<void> deleteSchemaRowsWhere(String table, Map<String, dynamic> match) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('delete_schema_rows_where', params: {
          'p_token': token, 'p_table': table, 'p_match': match,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    var q = fromSchema(table).delete();
    match.forEach((k, v) {
      q = v == null ? q.isFilter(k, null) : q.eq(k, v);
    });
    await q;
  }



  // ==================== SUBSCRIPTION ====================

  /// Check if institution has an active subscription year with a valid license key.
  /// Validates: today within institutionyear date range, iyearsubstatus=1,
  /// iyearlicencekey present, and the key's row in public.license_keys has status='used'
  /// (i.e. activated and not revoked). license_keys.status flips to 'revoked'
  /// to remotely kill an institution's access mid-year.
  ///
  /// [yearLabel] is the academic year the user picked on the login screen.
  /// Without this filter, an institution with multiple institutionyear rows
  /// could log into a year whose row has no key, by piggy-backing on a
  /// different year's valid key — that's an auth bypass. Pass the picked
  /// label so we only check that specific row.
  static Future<({bool isActive, String? yearLabel, DateTime? endDate, String? reason})> checkSubscription(int insId, {String? yearLabel}) async {
    try {
      final res = await client.rpc('check_subscription', params: {
        'p_ins_id': insId,
        'p_yrlabel': yearLabel,
      });
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final isActive = m['is_active'] == true;
      final endRaw = m['end_date']?.toString();
      return (
        isActive: isActive,
        yearLabel: m['year_label'] as String?,
        endDate: endRaw != null && endRaw.isNotEmpty ? DateTime.tryParse(endRaw) : null,
        reason: isActive ? null : (m['reason'] as String?),
      );
    } catch (e) {
      debugPrint('Subscription check error: $e');
      return (isActive: false, yearLabel: null, endDate: null, reason: 'Unable to verify subscription status. Please check your internet connection.');
    }
  }

  // ==================== MASTER DATA CHECK ====================

  /// Check if essential master data exists for an institution
  static Future<({bool hasFeeGroups, bool hasFeeTypes, bool hasConcessions, bool hasClassFeeDemand})> checkMasterData(int insId) async {
    try {
      final results = await Future.wait([
        fromSchema('feegroup').select('fg_id').eq('ins_id', insId).eq('activestatus', 1).limit(1),
        fromSchema('feetype').select('fee_id').eq('ins_id', insId).eq('activestatus', 1).limit(1),
        fromSchema('concessioncategory').select('con_id').eq('ins_id', insId).eq('activestatus', 1).limit(1),
        fromSchema('classfeedemand').select('cf_id').limit(1),
      ]);
      return (
        hasFeeGroups: (results[0] as List).isNotEmpty,
        hasFeeTypes: (results[1] as List).isNotEmpty,
        hasConcessions: (results[2] as List).isNotEmpty,
        hasClassFeeDemand: (results[3] as List).isNotEmpty,
      );
    } catch (e) {
      debugPrint('Master data check error: $e');
      return (hasFeeGroups: false, hasFeeTypes: false, hasConcessions: false, hasClassFeeDemand: false);
    }
  }

  // ==================== INSTITUTION ====================

  /// Scan the InstitutionLogos bucket and write each matched file's public
  /// URL into the corresponding institution row (matched by inscode prefix).
  /// Only fills rows whose inslogo is currently NULL/empty — never overwrites
  /// a manually set URL. Returns the number of rows updated.
  static Future<int> backfillInstitutionLogos() async {
    int filled = 0;
    try {
      final files = await client.storage.from('InstitutionLogos').list(path: 'logos');
      if (files.isEmpty) return 0;

      final rows = await client
          .from('institution')
          .select('ins_id, inscode, inslogo');

      for (final row in rows) {
        final current = (row['inslogo'] as String?)?.trim() ?? '';
        if (current.isNotEmpty) continue;
        final inscode = (row['inscode'] as String?)?.trim();
        if (inscode == null || inscode.isEmpty) continue;
        // Loose match: filename startsWith inscode (case-insensitive),
        // so files like "KMPTC Logo.jpg" still link to inscode "KMPTC".
        final lcCode = inscode.toLowerCase();
        final match = files.where((f) => f.name.toLowerCase().startsWith(lcCode)).toList();
        if (match.isEmpty) continue;
        final path = 'logos/${match.first.name}';
        final url = client.storage.from('InstitutionLogos').getPublicUrl(path);
        await client.from('institution').update({'inslogo': url}).eq('ins_id', row['ins_id']);
        filled++;
      }
    } catch (e) {
      debugPrint('backfillInstitutionLogos error: $e');
    }
    return filled;
  }

  /// Get all institution names for the login dropdown.
  /// Includes inslogo so the login form can render the selected
  /// institution's logo without a second round-trip. Also performs a
  /// one-shot bucket-to-DB sync for any rows whose inslogo is empty —
  /// after the first run, every institution's logo URL is persisted in
  /// the DB and subsequent loads skip the bucket entirely.
  static Future<List<Map<String, dynamic>>> getInstitutionNames() async {
    try {
      final raw = await client
          .from('institution')
          .select('ins_id, insname, inslogo, inscode')
          .order('insname');
      final list = List<Map<String, dynamic>>.from(raw);

      // Collect rows missing a logo URL — only run the bucket sync if any.
      final needSync = list.where((r) {
        final url = (r['inslogo'] as String?)?.trim() ?? '';
        final code = (r['inscode'] as String?)?.trim() ?? '';
        return url.isEmpty && code.isNotEmpty;
      }).toList();
      if (needSync.isEmpty) return list;

      try {
        final files = await client.storage.from('InstitutionLogos').list(path: 'logos');
        if (files.isEmpty) return list;
        for (final row in needSync) {
          final code = (row['inscode'] as String).toLowerCase();
          final match = files.where((f) => f.name.toLowerCase().startsWith(code)).toList();
          if (match.isEmpty) continue;
          final path = 'logos/${match.first.name}';
          final url = client.storage.from('InstitutionLogos').getPublicUrl(path);
          // Mutate the row we'll return so the dropdown shows it now.
          row['inslogo'] = url;
          // Persist so subsequent loads (and other screens) get it from DB.
          try {
            await client.from('institution').update({'inslogo': url}).eq('ins_id', row['ins_id']);
          } catch (e) {
            debugPrint('inslogo persist failed for ins_id=${row['ins_id']}: $e');
          }
        }
      } catch (e) {
        debugPrint('Bucket list during getInstitutionNames failed: $e');
      }
      return list;
    } catch (e) {
      debugPrint('Get institution names error: $e');
      return [];
    }
  }

  /// Get institution name, logo, and address from the institution table.
  /// If `inslogo` is empty but a matching `<inscode>.<ext>` exists in the
  /// InstitutionLogos bucket, the URL is auto-filled into the row so the
  /// header / receipts / dashboard pick it up the next time round.
  // ---- Per-institution Utilities settings (Setup -> Utilities) ----
  /// Code-side defaults, applied when an institution has no row for a key yet.
  static const Map<String, String> kSettingDefaults = {
    'admission_number_mode': 'MANUAL',       // 'AUTO' | 'MANUAL'
    'fee_collection_arrear_first': 'true',   // 'true' | 'false'
    // Which fee group each advance type is banked under -- a feegroup.fg_id, or
    // empty for "work it out from the names" (see resolveRoutingTarget and
    // ADVANCE_ROUTING_CONFIG.sql, which apply the identical rule).
    'advance_route_fg_A': '',
    'advance_route_fg_S': '',
    'advance_route_fg_M': '',
    // Which fee groups the Misc Collection counter may collect under, as a
    // comma-separated list of fg_id. Empty = every group that owns a fee type,
    // which is what it did before this setting existed. An advance-only group
    // (STUDENT ADVANCE, MESS ADVANCE) has a fee type of its own but nothing
    // that belongs on a misc receipt, so it is excluded here rather than by
    // guessing from the group's name.
    'misc_collection_fee_groups': '',
  };

  /// The setting above, parsed. Empty set = no restriction.
  static Set<int> miscFeeGroups(Map<String, String> settings) => {
        for (final part in (settings['misc_collection_fee_groups'] ?? '').split(','))
          if (int.tryParse(part.trim()) != null) int.parse(part.trim()),
      };

  /// Settings keys for a fee group's own receipt letterhead.
  ///
  /// A hostel receipt is issued by the HOSTEL, not by the college: it carries
  /// the hostel's name and address, not the institution's letterhead. Rather
  /// than hardcode that for one group, any fee group may carry its own -- the
  /// college keeps the institution's by leaving these empty.
  static String letterheadNameKey(int fgId) => 'letterhead_name_$fgId';
  static String letterheadAddrKey(int fgId) => 'letterhead_addr_$fgId';

  /// The printed header image for a group's receipts: a bundled asset path
  /// ('assets/images/kcet.png') or an https URL. Empty = no banner, and the
  /// receipt prints the name and address as text.
  ///
  /// This replaces guessing the banner from the institution's NAME, which is
  /// what receipt_widget.dart did: anything containing "engineering" got the
  /// college artwork, so a hostel receipt would have carried the college's.
  static String letterheadBannerKey(int fgId) => 'letterhead_banner_$fgId';

  /// Banner images bundled with the app, offered in Utilities.
  static const Map<String, String> kBundledBanners = {
    'assets/images/kcet.png': 'Engineering & Technology',
    'assets/images/kmptc.jpg': 'Polytechnic',
    'assets/images/kcsam.jpg': 'Arts, Science & Management',
    'assets/images/krishnasamy_hostel.png': 'Hostel',
  };

  /// The letterhead a receipt of [fgId] should print, falling back to the
  /// institution's own. [settings] is passed in when the caller already has
  /// them, so printing a receipt is not another round trip.
  static ({String name, String address, String banner}) letterheadFor({
    required int? fgId,
    required Map<String, String> settings,
    required String fallbackName,
    required String fallbackAddress,
  }) {
    if (fgId == null) {
      return (name: fallbackName, address: fallbackAddress, banner: '');
    }
    final n = (settings[letterheadNameKey(fgId)] ?? '').trim();
    final a = (settings[letterheadAddrKey(fgId)] ?? '').trim();
    final b = (settings[letterheadBannerKey(fgId)] ?? '').trim();
    return (
      name: n.isEmpty ? fallbackName : n,
      address: a.isEmpty ? fallbackAddress : a,
      banner: b,
    );
  }

  /// The setting key naming the fee group an advance of [advType] is banked
  /// under. Kept here so the client, the Utilities screen and
  /// save_advance_collection cannot spell it three different ways.
  static String advanceRouteKey(String advType) =>
      'advance_route_fg_${advType.toUpperCase()}';

  /// Cached settings, and when they were read.
  ///
  /// Every counter holds its Utilities settings for the life of the screen,
  /// and the desktop app stays open all day -- so a letterhead changed on the
  /// office machine never reached the other counters until they restarted.
  /// A short-lived shared cache fixes that without a round trip per receipt:
  /// screens may now ask on every print, and at most one call per [_settingsTtl]
  /// actually reaches the database.
  static final Map<int, Map<String, String>> _settingsCache = {};
  static final Map<int, DateTime> _settingsAt = {};
  static const Duration _settingsTtl = Duration(seconds: 60);

  /// Drop the cache so the very next read goes to the database. Called after
  /// Utilities saves, so the machine that made the change sees it at once
  /// rather than waiting out the TTL like everyone else.
  static void invalidateSettingsCache([int? insId]) {
    if (insId == null) {
      _settingsCache.clear();
      _settingsAt.clear();
    } else {
      _settingsCache.remove(insId);
      _settingsAt.remove(insId);
    }
  }

  /// All Utilities settings for an institution, merged over [kSettingDefaults]
  /// so callers always get a complete map.
  ///
  /// Served from the cache when it was read less than [_settingsTtl] ago. Pass
  /// [fresh] to force a read -- used where being a minute out of date would be
  /// wrong rather than merely untidy.
  static Future<Map<String, String>> getInstitutionSettings(int insId,
      {bool fresh = false}) async {
    if (!fresh) {
      final at = _settingsAt[insId];
      final hit = _settingsCache[insId];
      if (at != null && hit != null &&
          DateTime.now().difference(at) < _settingsTtl) {
        return Map<String, String>.from(hit);
      }
    }
    final merged = Map<String, String>.from(kSettingDefaults);
    try {
      final rows = await client
          .from('institution_settings')
          .select('setting_key, setting_value')
          .eq('ins_id', insId);
      for (final r in (rows as List)) {
        final k = r['setting_key']?.toString();
        if (k != null && k.isNotEmpty) merged[k] = r['setting_value']?.toString() ?? '';
      }
      // Only a READ that reached the database is worth caching. On failure the
      // defaults are returned but not stored, so the next call retries.
      _settingsCache[insId] = Map<String, String>.from(merged);
      _settingsAt[insId] = DateTime.now();
    } catch (e) {
      debugPrint('getInstitutionSettings failed: $e');
    }
    return merged;
  }

  /// Upserts one Utilities setting.
  static Future<void> setInstitutionSetting(int insId, String key, String value, {String? by}) async {
    await client.from('institution_settings').upsert({
      'ins_id': insId,
      'setting_key': key,
      'setting_value': value,
      'updatedat': DateTime.now().toIso8601String(),
      if (by != null) 'updatedby': by,
    }, onConflict: 'ins_id,setting_key');
    invalidateSettingsCache(insId);
  }

  static Future<({String? name, String? logo, String? address, String? mobile, String? email})> getInstitutionInfo(int insId) async {
    try {
      final result = await client
          .from('institution')
          .select('insname, inslogo, insaddress1, insaddress2, insaddress3, inspincode, insmobno, insmail, inscode')
          .eq('ins_id', insId)
          .maybeSingle();

      if (result == null) return (name: null, logo: null, address: null, mobile: null, email: null);

      // Build full address from individual columns (split into two lines)
      final line1Parts = <String>[
        if (result['insaddress1'] != null && (result['insaddress1'] as String).isNotEmpty) result['insaddress1'] as String,
        if (result['insaddress2'] != null && (result['insaddress2'] as String).isNotEmpty) result['insaddress2'] as String,
      ];
      final line2Parts = <String>[
        if (result['insaddress3'] != null && (result['insaddress3'] as String).isNotEmpty) result['insaddress3'] as String,
        if (result['inspincode'] != null && (result['inspincode'] as String).isNotEmpty) result['inspincode'] as String,
      ];
      final lines = <String>[
        if (line1Parts.isNotEmpty) line1Parts.join(', '),
        if (line2Parts.isNotEmpty) line2Parts.join(', '),
      ];
      final address = lines.isNotEmpty ? lines.join('\n') : null;

      // inslogo column stores the full public URL directly
      String? logoUrl = (result['inslogo'] as String?)?.trim();
      if (logoUrl == null || logoUrl.isEmpty) {
        // Auto-backfill from bucket. Real files are named freely (e.g.
        // "KMPTC Logo.jpg"), so match on filename startsWith inscode rather
        // than strict equality. Skip the URL guess entirely — broken
        // guesses would 404 forever; better to fall through to the
        // initial-letter avatar until the file actually exists.
        final inscode = (result['inscode'] as String?)?.trim();
        if (inscode != null && inscode.isNotEmpty) {
          try {
            final files = await client.storage.from('InstitutionLogos').list(path: 'logos');
            final lcCode = inscode.toLowerCase();
            final match = files.where((f) {
              return f.name.toLowerCase().startsWith(lcCode);
            }).toList();
            if (match.isNotEmpty) {
              final path = 'logos/${match.first.name}';
              logoUrl = client.storage.from('InstitutionLogos').getPublicUrl(path);
              // Persist so subsequent loads don't list the bucket.
              try {
                await client.from('institution').update({'inslogo': logoUrl}).eq('ins_id', insId);
              } catch (e) {
                debugPrint('inslogo backfill update failed: $e');
              }
            }
          } catch (e) {
            debugPrint('Bucket list for inscode=$inscode failed: $e');
          }
        }
      }

      return (
        name: result['insname'] as String?,
        logo: logoUrl,
        address: address,
        mobile: result['insmobno'] as String?,
        email: result['insmail'] as String?,
      );
    } catch (e) {
      debugPrint('Error fetching institution info: $e');
      return (name: null, logo: null, address: null, mobile: null, email: null);
    }
  }

  /// Create a new institution and return the inserted row (with ins_id)
  static Future<Map<String, dynamic>?> createInstitution(Map<String, dynamic> data) async {
    try {
      final response = await client.from('institution').insert(data).select().single();
      return response;
    } catch (e) {
      debugPrint('ERROR creating institution: $e');
      debugPrint('Data sent: $data');
      rethrow;
    }
  }

  // ==================== STUDENTS ====================

  /// Get total active student count for an institution
  static Future<int> getStudentCount(int insId) async {
    try {
      final count = await fromSchema('students')
          .count()
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0);  // next year's intake: advance screens only
      return count;
    } catch (e) {
      debugPrint('Error getting student count: $e');
      return 0;
    }
  }

  // ── Students cache ────────────────────────────────────────────────────────
  // getStudents is the app's single most-repeated heavy read (5+ screens; the
  // notices screen alone calls it 3x per open). Cache the result per-institution
  // with a short TTL and coalesce concurrent identical calls into ONE network
  // round-trip. Any student write clears it (invalidateStudentsCache); a caller
  // that must see its own just-written change immediately passes forceRefresh.
  static final Map<int, List<StudentModel>> _studentsCache = {};
  static final Map<int, DateTime> _studentsCacheAt = {};
  static final Map<int, Future<List<StudentModel>>> _studentsInFlight = {};
  static const Duration _studentsCacheTtl = Duration(seconds: 60);

  /// Clear the students cache. Pass [insId] to clear one institution, or nothing
  /// to clear all. Call after any student insert/update/import/photo change.
  static void invalidateStudentsCache([int? insId]) {
    if (insId == null) {
      _studentsCache.clear();
      _studentsCacheAt.clear();
    } else {
      _studentsCache.remove(insId);
      _studentsCacheAt.remove(insId);
    }
  }

  /// Get all active students for an institution (cached — see above).
  static Future<List<StudentModel>> getStudents(int insId, {bool forceRefresh = false}) async {
    if (forceRefresh) {
      try {
        final result = await _fetchStudents(insId);
        _studentsCache[insId] = result;
        _studentsCacheAt[insId] = DateTime.now();
        return result;
      } catch (e) {
        debugPrint('Error fetching students: $e');
        return const [];
      }
    }
    final at = _studentsCacheAt[insId];
    final cached = _studentsCache[insId];
    if (cached != null && at != null && DateTime.now().difference(at) < _studentsCacheTtl) {
      return cached;
    }
    final existing = _studentsInFlight[insId];
    if (existing != null) return existing;
    final future = () async {
      try {
        final result = await _fetchStudents(insId);
        _studentsCache[insId] = result;
        _studentsCacheAt[insId] = DateTime.now();
        return result;
      } catch (e) {
        debugPrint('Error fetching students: $e');
        return const <StudentModel>[]; // don't cache failures
      } finally {
        _studentsInFlight.remove(insId);
      }
    }();
    _studentsInFlight[insId] = future;
    return future;
  }

  static Future<List<StudentModel>> _fetchStudents(int insId) async {
    const batchSize = 1000;
    int offset = 0;
    final List<Map<String, dynamic>> allResults = [];
    while (true) {
      final batch = await fromSchema('students')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0)  // next year's intake: advance screens only
          .order('stuname', ascending: true)
          .range(offset, offset + batchSize - 1);
      final list = batch as List;
      allResults.addAll(list.cast<Map<String, dynamic>>());
      if (list.length < batchSize) break;
      offset += batchSize;
    }
    return allResults.map((e) => StudentModel.fromJson(e)).toList();
  }

  /// Just the students named by a set of ids, keyed by stu_id.
  ///
  /// For a screen that needs a handful of students -- the ones on the
  /// transactions it has just loaded -- this replaces getStudents(), which
  /// fetches `select('*')` for every active student in four paged round trips
  /// to build a map that is then read a dozen times. A day with eight receipts
  /// does not need three and a half thousand student rows.
  ///
  /// Unfiltered by activestatus on purpose: a receipt printed for a student who
  /// has since left must still carry their roll number and class.
  static Future<Map<int, StudentModel>> getStudentsByIds(
      int insId, Iterable<int> stuIds) async {
    final ids = stuIds.toSet().toList();
    if (ids.isEmpty) return {};
    final out = <int, StudentModel>{};
    try {
      // Chunked because a URL carries the id list, and PostgREST rejects one
      // that grows past the server's header limit.
      const chunkSize = 300;
      final chunks = <List<int>>[];
      for (int i = 0; i < ids.length; i += chunkSize) {
        chunks.add(ids.sublist(i, (i + chunkSize).clamp(0, ids.length)));
      }
      final results = await Future.wait(chunks.map((c) async =>
          await fromSchema('students')
              // ins_id is not read by this screen but StudentModel.fromJson
              // parses it unguarded, so leaving it out throws on every row.
              .select('stu_id, ins_id, stuname, stuadmno, stuclass, '
                  'stuaddress, courname, stumobile')
              .eq('ins_id', insId)
              .inFilter('stu_id', c) as List));
      for (final batch in results) {
        for (final r in batch) {
          final m = Map<String, dynamic>.from(r as Map);
          final id = (m['stu_id'] as num?)?.toInt();
          if (id != null) out[id] = StudentModel.fromJson(m);
        }
      }
    } catch (e) {
      debugPrint('Error fetching students by id: $e');
    }
    return out;
  }

  /// Fetch student remarks (stucondesc) as a map keyed by stu_id
  static Future<Map<int, String>> getStudentRemarks(int insId) async {
    try {
      const batchSize = 1000;
      int offset = 0;
      final Map<int, String> result = {};
      while (true) {
        final batch = await fromSchema('students')
            .select('stu_id, stucondesc')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('preadmission', 0)  // next year's intake: advance screens only
            .range(offset, offset + batchSize - 1);
        final list = batch as List;
        for (final s in list) {
          final desc = s['stucondesc']?.toString() ?? '';
          if (desc.isNotEmpty) {
            result[s['stu_id'] as int] = desc;
          }
        }
        if (list.length < batchSize) break;
        offset += batchSize;
      }
      return result;
    } catch (e) {
      debugPrint('Error fetching student remarks: $e');
      return {};
    }
  }

  /// Count of students per class — one row per class, used for fast class list display
  static Future<Map<String, int>> getStudentCountsByClass(int insId) async {
    try {
      final response = await client.rpc('get_student_counts_by_class', params: {'p_ins_id': insId});
      final map = <String, int>{};
      for (final row in (response as List)) {
        map[row['stuclass']?.toString() ?? ''] = (row['student_count'] as num?)?.toInt() ?? 0;
      }
      if (map.isNotEmpty) return map;
    } catch (e) {
      debugPrint('RPC get_student_counts_by_class failed, using fallback: $e');
    }
    // Fallback: count from direct query
    try {
      final students = await getStudents(insId);
      final map = <String, int>{};
      for (final s in students) {
        final cls = s.stuclass.isNotEmpty ? s.stuclass : 'Unassigned';
        map[cls] = (map[cls] ?? 0) + 1;
      }
      return map;
    } catch (e) {
      debugPrint('Fallback student count failed: $e');
      return {};
    }
  }

  /// Students for a single class — used for lazy drilldown
  static Future<List<StudentModel>> getStudentsByClass(int insId, String className) async {
    try {
      final response = await client.rpc('get_students_by_class', params: {'p_ins_id': insId, 'p_class': className});
      final list = (response as List).map((e) => StudentModel.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      if (list.isNotEmpty) return list;
    } catch (e) {
      debugPrint('RPC get_students_by_class failed, using fallback: $e');
    }
    // Fallback: direct query filtered by class
    try {
      final response = await fromSchema('students')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0)  // next year's intake: advance screens only
          .eq('stuclass', className)
          .order('stuname', ascending: true);
      return (response as List).map((e) => StudentModel.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (e) {
      debugPrint('Fallback getStudentsByClass failed: $e');
      return [];
    }
  }

  /// Get fee types (feedesc) from fee table
  static Future<List<String>> getFeeTypes(int insId) async {
    try {
      final response = await fromSchema('feetype')
          .select('feedesc')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('fee_id', ascending: true);
      return (response as List).map((e) => e['feedesc']?.toString() ?? '').where((s) => s.isNotEmpty).toList();
    } catch (e) {
      debugPrint('Error fetching fee types: $e');
      return [];
    }
  }

  /// Lightweight: fetch only stu_id, stuname, stuadmno for name lookups
  static Future<Map<int, Map<String, String>>> getStudentNameMap(int insId) async {
    try {
      const batchSize = 1000;
      int offset = 0;
      final Map<int, Map<String, String>> result = {};
      while (true) {
        final batch = await fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('preadmission', 0)  // next year's intake: advance screens only
            .range(offset, offset + batchSize - 1);
        final list = batch as List;
        for (final s in list) {
          result[s['stu_id'] as int] = {
            'stuname': s['stuname'] as String? ?? '',
            'stuadmno': s['stuadmno'] as String? ?? '',
            'stuclass': s['stuclass'] as String? ?? '',
            'courname': s['courname'] as String? ?? '',
          };
        }
        if (list.length < batchSize) break;
        offset += batchSize;
      }
      return result;
    } catch (e) {
      debugPrint('Error fetching student name map: $e');
      return {};
    }
  }

  /// Add a new student record — returns the new stu_id
  static Future<int> addStudent(Map<String, dynamic> data) async {
    invalidateStudentsCache(); // new student → the cached list is now stale
    final token = sessionToken;
    if (token != null) {
      try {
        final res = await client.rpc('save_student', params: {
          'p_token': token, 'p_data': data, 'p_stu_id': null,
        });
        return (res as num).toInt();
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow; // RPC not deployed yet → legacy fallback
      }
    }
    final response = await fromSchema('students')
        .insert(data)
        .select('stu_id')
        .maybeSingle();
    if (response == null) throw Exception('Student insert returned no data (check RLS or required columns)');
    return response['stu_id'] as int;
  }

  /// Update an existing student record
  static Future<void> updateStudent(int stuId, Map<String, dynamic> data) async {
    invalidateStudentsCache(); // edited student → the cached list is now stale
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('save_student', params: {
          'p_token': token, 'p_data': data, 'p_stu_id': stuId,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('students').update(data).eq('stu_id', stuId);
  }

  /// Void (delete) a fee-collection receipt: reverses the balances it settled
  /// and soft-voids the payment for audit. Blocks bank-reconciled receipts
  /// server-side. Optional [reason] is stored on payment.voidreason (Fee Cancel
  /// Receipt screen). See migrations/add_void_receipt.sql +
  /// add_void_receipt_reason.sql.
  /// Void a MISC receipt. Separate RPC from voidReceipt: a misc receipt
  /// settles no feedemand, so there is no balance to restore -- only the
  /// receipt to void and an audit trail to leave.
  static Future<void> voidMiscReceipt(int mcId,
      {required int insId, required String user, String? reason}) async {
    await client.rpc('void_misc_receipt', params: {
      'p_ins_id': insId,
      'p_mc_id': mcId,
      'p_user': user,
      'p_reason': reason,
    });
  }

  /// Void an ADVANCE receipt (AD26/...). Session-gated, so the institution
  /// comes from the token and not the caller.
  ///
  /// The server refuses it once any of the advance has been applied to a fee or
  /// refunded: a demand has been settled or reduced on the strength of it, and
  /// that has to be put back first. See migrations/ADVANCE_CANCEL_REFUND.sql.
  static Future<void> voidAdvanceReceipt(int advId,
      {required String token, required String user, String? reason}) async {
    await client.rpc('void_advance_receipt', params: {
      'p_token': token,
      'p_adv_id': advId,
      'p_user': user,
      'p_reason': reason,
    });
  }

  /// Give back the UNUSED balance of an advance. Writes an ordinary fee_refund
  /// voucher (pay_id NULL, paynumber = the advance number) so it lands in the
  /// same refund register as every other refund, and adds to
  /// advance_collection.refund_amount -- balanceamount is generated from that,
  /// so the remaining balance follows on its own.
  ///
  /// Returns the voucher: {rf_id, doc_no, advno, refunded, balance_left}.
  static Future<Map<String, dynamic>> refundAdvance({
    required String token,
    required Map<String, dynamic> header,
  }) async {
    final res = await client.rpc('refund_advance', params: {
      'p_token': token,
      'p_header': header,
    });
    return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  }

  /// Void a fee receipt.
  ///
  /// With a [token] this goes through void_receipt_with_advance, which does the
  /// same reversal AND hands back whatever an advance put into the receipt --
  /// advance_collection.adjustedamount comes down, so the student keeps money
  /// that was theirs. Without it (or on an older database) the plain
  /// void_receipt runs, which restores the demands but leaves the advance
  /// showing as spent.
  static Future<void> voidReceipt(int payId,
      {required int insId, required String user, String? reason, String? token}) async {
    if (token != null && token.isNotEmpty) {
      try {
        await client.rpc('void_receipt_with_advance', params: {
          'p_token': token,
          'p_pay_id': payId,
          'p_user': user,
          'p_reason': reason,
        });
        return;
      } on PostgrestException catch (e) {
        // Not deployed yet -> fall through to the plain void below. Any other
        // failure (a reconciled receipt, an admission advance) is the server
        // refusing on purpose and must reach the cashier.
        if (!_missingRpc(e)) rethrow;
      }
    }
    try {
      // Reason-aware 4-arg overload (add_void_receipt_reason.sql).
      await client.rpc('void_receipt', params: {
        'p_ins_id': insId,
        'p_pay_id': payId,
        'p_user': user,
        'p_reason': reason,
      });
    } on PostgrestException catch (e) {
      // Older DB that only has the 3-arg void_receipt — retry without p_reason
      // so cancellation still works before the reason migration is applied.
      final notFound = e.code == 'PGRST202' ||
          e.code == '42883' ||
          e.message.toLowerCase().contains('void_receipt');
      if (!notFound) rethrow;
      await client.rpc('void_receipt', params: {
        'p_ins_id': insId,
        'p_pay_id': payId,
        'p_user': user,
      });
    }
  }

  /// Fetch EVERY row of a query, paging past PostgREST's row cap.
  ///
  /// PostgREST caps a single response at 1000 rows and does so silently — a
  /// plain `.select()` on feedemand/students/payment just stops at 1000 and the
  /// screen shows partial data with no error. Asking for `.limit(100000)` does
  /// not help; the server still returns 1000.
  ///
  /// [buildQuery] must return a FRESH builder each call (a builder can only be
  /// awaited once), e.g.:
  ///
  /// ```dart
  /// final rows = await SupabaseService.fetchAll(() => SupabaseService
  ///     .fromSchema('feedemand')
  ///     .select('stu_id, balancedue')
  ///     .eq('ins_id', insId));
  /// ```
  static Future<List<Map<String, dynamic>>> fetchAll(
    dynamic Function() buildQuery, {
    int pageSize = 1000,
  }) async {
    final all = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final batch = await buildQuery().range(offset, offset + pageSize - 1);
      final list = (batch as List).cast<Map<String, dynamic>>();
      all.addAll(list);
      if (list.length < pageSize) break;
      offset += pageSize;
    }
    return all;
  }

  /// Stage fee demands for a student who has just moved into [targetClass].
  ///
  /// The DB trigger `fn_gen_feedemand_on_student` only fires on student INSERT,
  /// so a class *change* (Interim Promotion) would otherwise never be re-billed.
  /// This mirrors that trigger's rules exactly:
  ///   * match `classfeedemand` on cfclass = target class,
  ///   * admissiontype NULL (applies to all) or matching the student's type,
  ///   * skip rows already staged in tempfeedemand or live in feedemand
  ///     (same student + term + fee type), so re-running is safe,
  ///   * carry the template's due date and `collectible` flag.
  ///
  /// Rows land in `tempfeedemand` (isapproved = false) and appear in Fee Demand
  /// Approval, exactly like every other demand. Returns the number staged.
  static Future<int> generateDemandsForStudent({
    required int insId,
    required String inscode,
    required Map<String, dynamic> student, // stu_id, stuadmno, admname
    required String targetClass,
    required String targetCourse,
    String? createdBy,
  }) async {
    final stuId = (student['stu_id'] as num?)?.toInt();
    if (stuId == null) return 0;

    final years = await getYears(insId);
    final yr = years.isNotEmpty ? years.first : null;
    final yrId = yr != null ? int.tryParse(yr['yr_id'].toString()) ?? 0 : 0;
    final yrLabel = yr?['yrlabel']?.toString() ?? '';

    // Resolve the student's admission type so type-specific templates match.
    int? admId;
    final admName = student['admname']?.toString().trim() ?? '';
    if (!isSchoolLayout && admName.isNotEmpty) {
      try {
        final a = await fromSchema('admissiontype')
            .select('adm_id, admname')
            .eq('activestatus', 1);
        for (final r in (a as List)) {
          if ((r['admname']?.toString().trim().toUpperCase() ?? '') == admName.toUpperCase()) {
            admId = (r['adm_id'] as num?)?.toInt();
            break;
          }
        }
      } catch (_) {}
    }

    final cfRows = await fromSchema('classfeedemand')
        .select(isSchoolLayout
            ? 'cfterm, cffeetype, cfamount, cfdduedate, collectible'
            : 'cfterm, cffeetype, cfamount, cfdduedate, admissiontype, collectible')
        .eq('cfclass', targetClass)
        .eq('activestatus', 1);

    // Existing demands for this student — used to skip duplicates.
    final existing = <String>{};
    for (final table in ['tempfeedemand', 'feedemand']) {
      try {
        final rows = await fromSchema(table)
            .select('demfeeterm, demfeetype')
            .eq('stu_id', stuId)
            .eq('activestatus', 1);
        for (final r in (rows as List)) {
          existing.add('${r['demfeeterm']}|${r['demfeetype']}');
        }
      } catch (_) {}
    }

    final rows = <Map<String, dynamic>>[];
    for (final cf in (cfRows as List)) {
      final amt = (cf['cfamount'] as num?)?.toDouble();
      if (amt == null) continue; // trigger skips NULL amounts
      final cfAdm = (cf['admissiontype'] as num?)?.toInt();
      if (cfAdm != null && cfAdm != admId) continue;
      final term = cf['cfterm']?.toString() ?? '';
      final feeType = cf['cffeetype']?.toString() ?? '';
      if (existing.contains('$term|$feeType')) continue;
      final due = cf['cfdduedate'];
      if (due == null) continue; // tempfeedemand.duedate is NOT NULL
      rows.add({
        'ins_id': insId,
        'inscode': inscode,
        'yr_id': yrId,
        'stu_id': stuId,
        'stuadmno': student['stuadmno'],
        'stuclass': targetClass,
        'courname': targetCourse,
        'demfeeyear': yrLabel,
        'demfeeterm': term,
        'demfeetype': feeType,
        // REGULAR, said explicitly -- see _generateTempDemands. Without it the
        // set_dem_id trigger stamps 'DEMAND' and the same fee ends up labelled
        // two different ways depending on which screen raised it.
        'demseqtype': 'REGULAR',
        'feeamount': amt,
        'balancedue': amt,
        'duedate': due,
        'createdby': createdBy,
        'isapproved': false,
        'activestatus': 1,
        'collectible': cf['collectible'] ?? true,
      });
    }
    if (rows.isEmpty) return 0;
    await fromSchema('tempfeedemand').insert(rows);
    return rows.length;
  }

  /// Get academic years for an institution
  static Future<List<Map<String, dynamic>>> getYears(int insId) async {
    try {
      final response = await fromSchema('year')
          .select('yr_id, yrlabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('yr_id', ascending: false);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching years: $e');
      return [];
    }
  }

  /// Get distinct class names for an institution
  /// Map of course → list of classes within that course, derived from
  /// the live students table. Empty course names map under "Other" so
  /// nothing is silently dropped.
  /// Distinct (courname, stuclass) pairs for the institution.
  ///
  /// Uses the `get_distinct_classes` RPC (server-side `SELECT DISTINCT`) so we
  /// don't ship the entire students table just to derive a few dozen names —
  /// and, critically, so classes past the 1000-row PostgREST cap are NOT
  /// silently dropped. Falls back to a *paginated* students scan (via fetchAll,
  /// which loops past 1000) if the RPC isn't deployed yet.
  static Future<List<Map<String, String>>> _distinctCourseClass(int insId) async {
    List<Map<String, dynamic>> rows;
    try {
      final res = await client.rpc('get_distinct_classes', params: {'p_ins_id': insId});
      rows = (res as List).cast<Map<String, dynamic>>();
    } on PostgrestException catch (e) {
      if (!_missingRpc(e)) rethrow;
      rows = await fetchAll(() => fromSchema('students')
          .select('courname, stuclass')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0));  // next year's intake: advance screens only
    }
    return [
      for (final r in rows)
        {
          'courname': (r['courname']?.toString() ?? '').trim(),
          'stuclass': (r['stuclass']?.toString() ?? '').trim(),
        },
    ];
  }

  static Future<Map<String, List<String>>> getCourseClassMap(int insId) async {
    try {
      final pairs = await _distinctCourseClass(insId);
      final map = <String, Set<String>>{};
      for (final r in pairs) {
        final cls = r['stuclass'] ?? '';
        if (cls.isEmpty) continue;
        final course = (r['courname'] ?? '').isEmpty ? 'Other' : r['courname']!;
        map.putIfAbsent(course, () => <String>{}).add(cls);
      }
      return {
        for (final e in map.entries) e.key: (e.value.toList()..sort()),
      };
    } catch (e) {
      debugPrint('Error fetching course/class map: $e');
      return {};
    }
  }

  static Future<List<String>> getClasses(int insId) async {
    try {
      final pairs = await _distinctCourseClass(insId);
      final classes = pairs
          .map((r) => r['stuclass'] ?? '')
          .where((c) => c.isNotEmpty)
          .toSet()
          .toList();
      const classOrder = ['PKG', 'LKG', 'UKG', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII'];
      classes.sort((a, b) {
        final idxA = classOrder.indexOf(a.toUpperCase());
        final idxB = classOrder.indexOf(b.toUpperCase());
        if (idxA >= 0 && idxB >= 0) return idxA.compareTo(idxB);
        if (idxA >= 0) return -1;
        if (idxB >= 0) return 1;
        return a.compareTo(b);
      });
      return classes;
    } catch (e) {
      debugPrint('Error fetching classes: $e');
      return [];
    }
  }

  /// className (UPPER-CASED + trimmed) -> composite sort key (course.ordid then
  /// class.ordid) from the class/course masters. Drives class-filter ordering
  /// (see utils/class_sort.dart -> classOrdidComparator). Empty on any error,
  /// which makes callers fall back to the name-based [classCompare].
  static Future<Map<String, int>> getClassOrder(int insId) async {
    try {
      final classRows = await fromSchema('class')
          .select('claname, ordid, cour_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final courseRows = await fromSchema('course')
          .select('cour_id, ordid')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final courseOrd = <int, int>{};
      for (final c in (courseRows as List)) {
        final id = (c['cour_id'] as num?)?.toInt();
        if (id != null) courseOrd[id] = (c['ordid'] as num?)?.toInt() ?? 9999;
      }
      final map = <String, int>{};
      for (final r in (classRows as List)) {
        final name = (r['claname']?.toString() ?? '').trim().toUpperCase();
        if (name.isEmpty) continue;
        final cid = (r['cour_id'] as num?)?.toInt();
        final cord = cid != null ? (courseOrd[cid] ?? 9999) : 9999;
        final clord = (r['ordid'] as num?)?.toInt() ?? 9999;
        map[name] = cord * 100000 + clord;
      }
      return map;
    } catch (e) {
      debugPrint('getClassOrder error: $e');
      return {};
    }
  }

  /// feedesc -> feetype.ordid, for ordering fee-type columns in reports.
  ///
  /// Reports used to lay these out ALPHABETICALLY, which put TUITION FEE --
  /// the one everybody looks for -- near the end because of its initial
  /// letter. feetype.ordid lets the office say what the running order is, the
  /// same way class and course already do.
  ///
  /// Keyed on the UPPER-CASED description because that is what the reports
  /// carry: feedemand stores demfeetype as text, not a fee_id, so the
  /// description is the only join there is.
  ///
  /// Anything unset sorts last rather than first: a fee type nobody has
  /// numbered should not displace the ones somebody has.
  static Future<Map<String, int>> getFeeTypeOrder(int insId) async {
    try {
      final rows = await fromSchema('feetype')
          .select('feedesc, ordid')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final map = <String, int>{};
      for (final r in (rows as List)) {
        final name = (r['feedesc']?.toString() ?? '').trim().toUpperCase();
        if (name.isEmpty) continue;
        map[name] = (r['ordid'] as num?)?.toInt() ?? 9999;
      }
      return map;
    } catch (e) {
      // An older database without the column just gets alphabetical order --
      // worse, but not broken, and never a failed report.
      debugPrint('getFeeTypeOrder error: $e');
      return {};
    }
  }

  /// feedesc -> the fee GROUP it belongs to, for the Fee Group report filter.
  ///
  /// Keyed on the UPPER-CASED description for the same reason as
  /// getFeeTypeOrder: feedemand stores demfeetype as text, so the description
  /// is the only join the reports have.
  ///
  /// A fee type in no group, or in a group that has since been deactivated,
  /// is simply absent from the map. Reports treat that as "belongs to no
  /// group", which keeps it visible when no group filter is set and hides it
  /// when one is -- the honest answer either way, rather than quietly
  /// assigning it somewhere.
  ///
  /// A SET per description, not a single group, because descriptions are NOT
  /// unique across groups: APPLICATION, FINE, GENERAL BREAKAGE, MISCELLANEOUS
  /// and STAFF NOTICE SALARY all exist under both COLLEGE FEES and HOSTEL
  /// FEES here. Keeping one would mean the last row read silently won and the
  /// same fee vanished from whichever group lost the toss. Belonging to both
  /// shows it under either filter, which is the truthful answer when the
  /// report row carries only a description and no fee_id to resolve it.
  static Future<Map<String, Set<String>>> getFeeTypeGroups(int insId) async {
    try {
      final types = await fromSchema('feetype')
          .select('feedesc, fg_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final groups = await fromSchema('feegroup')
          .select('fg_id, fgdesc')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final byId = <int, String>{};
      for (final g in (groups as List)) {
        final id = (g['fg_id'] as num?)?.toInt();
        final name = (g['fgdesc']?.toString() ?? '').trim();
        if (id != null && name.isNotEmpty) byId[id] = name;
      }
      final map = <String, Set<String>>{};
      for (final t in (types as List)) {
        final name = (t['feedesc']?.toString() ?? '').trim().toUpperCase();
        final fg = (t['fg_id'] as num?)?.toInt();
        if (name.isEmpty || fg == null) continue;
        final g = byId[fg];
        if (g != null) (map[name] ??= <String>{}).add(g);
      }
      return map;
    } catch (e) {
      debugPrint('getFeeTypeGroups error: $e');
      return {};
    }
  }

  /// fee_id -> its fee group. The UNAMBIGUOUS form of getFeeTypeGroups.
  ///
  /// Use this wherever the report row carries a fee_id. Descriptions are not
  /// unique across groups, so name-matching counts a shared fee under both;
  /// fee_id names exactly one row and resolves it.
  static Future<Map<int, String>> getFeeIdGroups(int insId) async {
    try {
      final types = await fromSchema('feetype')
          .select('fee_id, fg_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final groups = await fromSchema('feegroup')
          .select('fg_id, fgdesc')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final byId = <int, String>{};
      for (final g in (groups as List)) {
        final id = (g['fg_id'] as num?)?.toInt();
        final name = (g['fgdesc']?.toString() ?? '').trim();
        if (id != null && name.isNotEmpty) byId[id] = name;
      }
      final map = <int, String>{};
      for (final t in (types as List)) {
        final fee = (t['fee_id'] as num?)?.toInt();
        final fg = (t['fg_id'] as num?)?.toInt();
        if (fee == null || fg == null) continue;
        final g = byId[fg];
        if (g != null) map[fee] = g;
      }
      return map;
    } catch (e) {
      debugPrint('getFeeIdGroups error: $e');
      return {};
    }
  }

  /// feetype.type lookups: by fee_id, by UPPER-CASED description, and the
  /// distinct codes in use.
  ///
  /// Loaded centrally because the Type filter is on every report now. It used
  /// to be built only by the DCB Register's own loader, so on any other tab
  /// the maps were empty -- and an empty map plus a selected kind means every
  /// row fails the test and the report goes blank.
  static Future<({Map<int, String> byId, Map<String, String> byName, List<String> codes})>
      getFeeKindMaps(int insId) async {
    try {
      final rows = await fromSchema('feetype')
          .select('fee_id, feedesc, type')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final byId = <int, String>{};
      final byName = <String, String>{};
      final codes = <String>{};
      for (final r in (rows as List)) {
        final t = (r['type']?.toString() ?? '').trim().toUpperCase();
        if (t.isEmpty) continue;
        final id = (r['fee_id'] as num?)?.toInt();
        final nm = (r['feedesc']?.toString() ?? '').trim().toUpperCase();
        if (id != null) byId[id] = t;
        if (nm.isNotEmpty) byName[nm] = t;
        codes.add(t);
      }
      return (byId: byId, byName: byName, codes: codes.toList()..sort());
    } catch (e) {
      debugPrint('getFeeKindMaps error: $e');
      return (byId: <int, String>{}, byName: <String, String>{}, codes: <String>[]);
    }
  }

  /// Get concession categories for an institution
  static Future<List<Map<String, dynamic>>> getConcessions(int insId) async {
    try {
      final response = await fromSchema('concessioncategory')
          .select('con_id, condesc')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('con_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching concessions: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getAdmissionTypes(int insId) async {
    if (isSchoolLayout) return []; // no admission type on the school database
    try {
      final response = await fromSchema('admissiontype')
          .select('adm_id, admname')
          .eq('activestatus', 1)
          .order('adm_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching admission types: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getQuotas(int insId) async {
    if (isSchoolLayout) return []; // no quota on the school database
    try {
      final response = await fromSchema('quota')
          .select('quo_id, quoname')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('quo_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching quotas: $e');
      return [];
    }
  }

  /// Find an existing parent record — checks fathermobile, then mothermobile,
  /// then payinchargemob in order. Returns par_id of first match, or null.
  static Future<int?> findParentByMobile({
    required int insId,
    String? fatherMobile,
    String? motherMobile,
    String? payMobile,
  }) async {
    if (fatherMobile != null && fatherMobile.isNotEmpty) {
      final result = await fromSchema('parents')
          .select('par_id')
          .eq('ins_id', insId)
          .eq('fathermobile', fatherMobile)
          .eq('activestatus', 1)
          .maybeSingle();
      if (result != null) return result['par_id'] as int;
    }
    if (motherMobile != null && motherMobile.isNotEmpty) {
      final result = await fromSchema('parents')
          .select('par_id')
          .eq('ins_id', insId)
          .eq('mothermobile', motherMobile)
          .eq('activestatus', 1)
          .maybeSingle();
      if (result != null) return result['par_id'] as int;
    }
    if (payMobile != null && payMobile.isNotEmpty) {
      final result = await fromSchema('parents')
          .select('par_id')
          .eq('ins_id', insId)
          .eq('payinchargemob', payMobile)
          .eq('activestatus', 1)
          .maybeSingle();
      if (result != null) return result['par_id'] as int;
    }
    return null;
  }

  /// Insert parent record — returns the new par_id
  static Future<int> saveParent(Map<String, dynamic> data) async {
    final token = sessionToken;
    if (token != null) {
      try {
        final res = await client.rpc('save_parent', params: {
          'p_token': token, 'p_data': data, 'p_par_id': null,
        });
        return (res as num).toInt();
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    final response = await fromSchema('parents')
        .insert(data)
        .select('par_id')
        .maybeSingle();
    if (response == null) throw Exception('Parent insert returned no data (check RLS or required columns)');
    return response['par_id'] as int;
  }

  /// Insert parentdetail record linking student ↔ parent
  static Future<void> saveParentDetail(Map<String, dynamic> data) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('save_parentdetail', params: {
          'p_token': token, 'p_data': data,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('parentdetail').insert(data);
  }

  /// Update an existing parent record (session-gated; legacy fallback)
  static Future<void> updateParent(int parId, Map<String, dynamic> data) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('save_parent', params: {
          'p_token': token, 'p_data': data, 'p_par_id': parId,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('parents').update(data).eq('par_id', parId);
  }

  /// Update a student's denormalized parentdetail row (session-gated; fallback)
  static Future<void> updateParentDetail(int stuId, Map<String, dynamic> data) async {
    final token = sessionToken;
    if (token != null) {
      try {
        await client.rpc('save_parentdetail', params: {
          'p_token': token, 'p_data': data, 'p_stu_id': stuId,
        });
        return;
      } on PostgrestException catch (e) {
        if (!_missingRpc(e)) rethrow;
      }
    }
    await fromSchema('parentdetail').update(data).eq('stu_id', stuId);
  }

  /// Fetch parent record for a given student (via parentdetail → parents)
  static Future<Map<String, dynamic>?> getStudentParent(int stuId, {String? stuadmno}) async {
    try {
      // Try by stu_id first
      var detail = await fromSchema('parentdetail')
          .select('par_id')
          .eq('stu_id', stuId)
          .maybeSingle();
      // Fallback: try by stuadmno if stu_id lookup returned nothing
      if (detail == null && stuadmno != null && stuadmno.isNotEmpty) {
        detail = await fromSchema('parentdetail')
            .select('par_id')
            .eq('stuadmno', stuadmno)
            .maybeSingle();
      }
      if (detail == null) return null;
      final parId = detail['par_id'] as int;
      final parent = await fromSchema('parents')
          .select('*')
          .eq('par_id', parId)
          .maybeSingle();
      return parent;
    } catch (e) {
      debugPrint('Error fetching student parent: $e');
      return null;
    }
  }

  // ==================== TEACHERS / STAFF ====================

  /// Get total active staff count for an institution
  static Future<int> getTeacherCount(int insId) async {
    try {
      final response = await client.from('institutionusers')
          .select('use_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      return (response as List).length;
    } catch (e) {
      debugPrint('Error getting teacher count: $e');
      return 0;
    }
  }

  /// Get all active staff for an institution
  static Future<List<InstitutionUserModel>> getInstitutionUsers(
      int insId) async {
    try {
      // Explicit column list — anon has SELECT revoked on `usepassword`
      // (security hardening), so `select('*')` would be denied wholesale.
      final response = await client.from('institutionusers')
          .select('use_id, ins_id, inscode, usename, usemail, usephone, '
              'usestadate, usemaiotp, usemobotp, useotpstatus, usedob, '
              'usecategory, ur_id, urname, des_id, desname, userepto, '
              'approvedby, approveddate, suspendeddate, suspendedby, '
              'terminateddate, terminatedby, activestatus, terminatedreason')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('usename', ascending: true)
          // Don't let a slow/hung request leave the list spinning forever.
          .timeout(const Duration(seconds: 15));
      return (response as List)
          .map((e) => InstitutionUserModel.fromJson(e))
          .toList();
    } catch (e) {
      debugPrint('Error fetching institution users: $e');
      return [];
    }
  }

  /// Create a new institution user (admin/staff)
  static Future<bool> createInstitutionUser(Map<String, dynamic> data) async {
    try {
      // Session-gated: forces ins_id server-side so a staff/admin account can
      // only ever be created for the caller's own institution (closes the
      // anon-key privilege-escalation hole). Password hashing trigger still runs.
      await savePublicRow('institutionusers', data, pkCol: 'use_id');
      return true;
    } catch (e) {
      debugPrint('Error creating institution user: $e');
      debugPrint('User data: $data');
      rethrow;
    }
  }

  /// Update an existing institution user (admin/staff).
  ///
  /// Same session-gated save_public_row RPC as create, which forces ins_id
  /// server-side, so a user can only ever be edited inside the caller's own
  /// institution. There is no direct-write fallback on purpose: a plain UPDATE
  /// is blocked by RLS on public.institutionusers (the same reason terminate
  /// goes through an RPC), so it would silently match 0 rows.
  ///
  /// Pass `usepassword` ONLY when it is actually being changed -- the hash
  /// trigger fires on UPDATE OF usepassword and re-hashes whatever it is given.
  static Future<bool> updateInstitutionUser(int useId, Map<String, dynamic> data) async {
    final token = sessionToken;
    if (token == null || token.isEmpty) {
      throw StateError('No active session. Sign out and sign in again to edit users.');
    }
    try {
      await savePublicRow('institutionusers', data, pkCol: 'use_id', pkVal: useId);
      return true;
    } catch (e) {
      debugPrint('Error updating institution user: $e');
      rethrow;
    }
  }

  /// Terminate (deactivate) an institution user
  static Future<bool> terminateInstitutionUser(int useId, {required int insId, required String terminatedBy, required String terminatedReason}) async {
    try {
      debugPrint('Terminating user with use_id: $useId (ins_id: $insId)');
      // SECURITY DEFINER RPC — bypasses RLS on public.institutionusers (a direct
      // UPDATE was blocked by row-level security). Returns rows updated.
      final res = await client.rpc('terminate_institution_user', params: {
        'p_use_id': useId,
        'p_ins_id': insId,
        'p_terminatedby': terminatedBy,
        'p_terminatedreason': terminatedReason,
      });
      final count = res is int ? res : int.tryParse(res?.toString() ?? '0') ?? 0;
      debugPrint('Terminate user rows updated: $count');
      return count > 0;
    } catch (e, st) {
      debugPrint('Error terminating institution user: $e');
      debugPrint('Stack trace: $st');
      return false;
    }
  }

  /// Terminate (deactivate) a student
  static Future<bool> terminateStudent(int stuId, {required String terminatedBy, required String terminatedReason}) async {
    try {
      debugPrint('Terminating student with stu_id: $stuId');
      final now = DateTime.now().toIso8601String();
      final data = {
        'activestatus': 9,
        'terminatedby': terminatedBy,
        'terminateddate': now,
        'terminatedreason': terminatedReason,
      };
      // Route through the session-gated update path (falls back to a direct
      // update inside updateStudent when no token / RPC not yet deployed).
      await updateStudent(stuId, data);
      debugPrint('Terminate student success');
      return true;
    } catch (e, st) {
      debugPrint('Error terminating student: $e');
      debugPrint('Stack trace: $st');
      return false;
    }
  }

  // ==================== BANK ACCOUNTS ====================

  /// Per-institution beneficiary bank accounts (school's own, transport's,
  /// hostel's etc.). Stored in the institution schema, not public, so each
  /// tenant only sees its own list.
  static Future<List<Map<String, dynamic>>> getBanks() async {
    try {
      final response = await fromSchema('bank')
          .select('*')
          .eq('activestatus', 1)
          .order('ban_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching banks: $e');
      return [];
    }
  }

  static Future<int?> addBank(Map<String, dynamic> data) async {
    try {
      return await saveSchemaRow('bank', data, pkCol: 'ban_id');
    } catch (e) {
      debugPrint('Error adding bank: $e');
      rethrow;
    }
  }

  static Future<bool> updateBank(int banId, Map<String, dynamic> data) async {
    try {
      await saveSchemaRow('bank', data, pkCol: 'ban_id', pkVal: banId);
      return true;
    } catch (e) {
      debugPrint('Error updating bank: $e');
      return false;
    }
  }

  /// Soft-delete: flips activestatus to 0 so historical fee groups /
  /// payments still resolve their bank reference. A hard DELETE would
  /// orphan the FK references.
  static Future<bool> deleteBank(int banId) async {
    try {
      await deleteSchemaRow('bank', 'ban_id', banId);
      return true;
    } catch (e) {
      debugPrint('Error deleting bank: $e');
      return false;
    }
  }

  // ==================== FEE GROUPS ====================

  /// Get all active fee groups for an institution
  static Future<List<Map<String, dynamic>>> getFeeGroups(int insId) async {
    try {
      final response = await fromSchema('feegroup')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('fg_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching fee groups: $e');
      return [];
    }
  }

  /// Assign / clear the beneficiary bank account on a fee group. Used by
  /// the Bank Details screen so admins can route each fee group's
  /// payments to a specific bank without re-importing fee groups.
  static Future<bool> setFeeGroupBank(int fgId, int? banId) async {
    try {
      await saveSchemaRow('feegroup', {'ban_id': banId}, pkCol: 'fg_id', pkVal: fgId);
      return true;
    } catch (e) {
      debugPrint('Error updating feegroup ban_id: $e');
      return false;
    }
  }

  /// Which Paytm merchant an online payment is created under.
  ///
  /// Routing is per INSTITUTION: the paying unit's own merchant, from
  /// public.paytm_configuration, whose order is signed server-side with that
  /// merchant's own key (PAYTM_MERCHANTS) so Paytm settles to that unit's
  /// registered bank account.
  ///
  /// Fee-group routing (a group naming a bank, the bank naming a merchant) was
  /// tried and reverted: one Paytm order settles to exactly one merchant, so a
  /// student paying tuition and hostel fees together could not be collected in
  /// a single transaction, which is the normal case at the counter.
  ///
  /// An unresolvable institution returns [PaytmRouting.error] rather than
  /// quietly falling back to the default parent merchant — that fallback is how
  /// money silently reached the parent account after a database rebuild, with
  /// nothing in the app or on Paytm to show it had happened.
  /// Whether a collection settles to its FEE GROUP's own Paytm merchant.
  ///
  /// OFF in production. While false, every online collection is created under
  /// the institution's merchant from public.paytm_configuration -- exactly what
  /// 0.0.8 does -- and a hostel fee group mapped to the hostel bank still
  /// settles into the COLLEGE account, because banId is forced to null and the
  /// routing falls back to the institution merchant.
  ///
  /// Deliberately NOT a hand-edited constant, for the same reason
  /// PaytmConfig.isProduction is not: editing a committed `= false` to true to
  /// test it is how the counter ends up shipping a split it was never meant to
  /// have. The flag is invisible in the exe and nobody remembers it at release
  /// time. Instead the same untracked config.json that already points a machine
  /// at the TEST database opts in, with "feeGroupSettlement": true.
  /// A production install has no such file, so it cannot be switched on.
  ///
  /// Turning it on is not free: a student owing college AND hostel dues can no
  /// longer pay both in one online transaction -- one Paytm order settles to
  /// exactly one merchant, so the collection screen refuses the mixed case and
  /// asks for two payments. Cash, cheque and DD still take both at once; they
  /// are banked by the receipt, not by the gateway. That cost is why this is a
  /// per-machine opt-in rather than a release decision made by accident.
  ///
  /// Prerequisites, all now in place: BANK_ROUTING_BY_FEEGROUP and
  /// FIX_ONLINE_PAYMENT_BAN_ID applied, the hostel bank (ban_id 2) carrying its
  /// own paytm_mid, fee group 2 naming that bank, the HF26/ sequence, and the
  /// hostel merchant's key in the PAYTM_MERCHANTS edge secret -- without the
  /// key the server REJECTS the routed payment rather than mis-settling it.
  static bool kFeeGroupSettlement = false;

  /// The institution setting that turns the same routing on for EVERY counter,
  /// without a rebuild and without a file on each machine:
  ///
  ///   INSERT INTO public.institution_settings
  ///       (ins_id, setting_key, setting_value, updatedat, updatedby)
  ///   VALUES (1, 'fee_group_settlement', 'true', now(), 'ADMIN')
  ///   ON CONFLICT (ins_id, setting_key)
  ///   DO UPDATE SET setting_value = EXCLUDED.setting_value;
  ///
  /// Set it to 'false' to turn it straight back off. That matters more than the
  /// convenience: the first time real money routes to a newly onboarded
  /// merchant is exactly when an instant undo is wanted, and a rebuild-and-
  /// release is not one. Every counter picks the change up within the settings
  /// cache TTL (60s), or immediately on the next screen that reads fresh.
  static const String feeGroupSettlementKey = 'fee_group_settlement';

  /// Whether this collection should settle into its FEE GROUP's own merchant.
  ///
  /// True if EITHER the machine opted in through config.json (how the routing
  /// is tested before it is turned on for everyone) OR the institution has the
  /// setting above. The compiled default stays false, so production can only
  /// reach it deliberately -- through a row anyone can see and reverse.
  /// ROUTING IS AUTOMATIC. A collection settles into its fee group's own
  /// merchant whenever that group is mapped to a bank and that bank names a
  /// Paytm merchant. Nothing has to be switched on: an account is used because
  /// someone configured it, which is the only reason it would be there.
  ///
  /// This is safe because the FALLBACK is unchanged. A group with no bank, or
  /// a bank with no merchant, still resolves the institution's merchant -- so a
  /// database with one fee group behaves exactly as it does today. The only
  /// payment that moves is one whose group names a DIFFERENT account, which is
  /// the case the mapping was created for. Verified 2026-10-01: the institution
  /// merchant and the COLLEGE FEES bank merchant are the same id, so college
  /// collections are unaffected; only HOSTEL FEES resolves elsewhere.
  ///
  /// The setting is therefore a KILL SWITCH, not an on-switch. Setting
  /// `fee_group_settlement` to 'false' forces every payment back through the
  /// institution's single merchant, on every counter, within the settings cache
  /// TTL and without a rebuild. That matters the first time real money routes
  /// to a newly onboarded merchant: if its key is missing from PAYTM_MERCHANTS
  /// or the account is not registered with Paytm, this turns it off in seconds
  /// rather than in a release.
  static Future<bool> feeGroupSettlementEnabled(int insId) async {
    if (kFeeGroupSettlement) return true;
    try {
      final s = await getInstitutionSettings(insId);
      // Only an explicit 'false' disables it.
      return (s[feeGroupSettlementKey] ?? '').trim().toLowerCase() != 'false';
    } catch (e) {
      // A failed settings read says nothing about which account the money
      // belongs in, and a group with no merchant of its own still falls back to
      // the institution's. Carry on rather than mis-settling on a lookup error.
      debugPrint('feeGroupSettlementEnabled: $e');
      return true;
    }
  }

  static Future<PaytmRouting> resolvePaytmRouting(
      {required int insId, int? banId}) async {
    // The fee group's own bank account first. Hostel fees are banked into the
    // hostel account, so an online hostel payment has to settle into the
    // hostel MERCHANT -- settling it into the college merchant and correcting
    // it by hand afterwards is not something the receipt would ever show.
    //
    // One Paytm order settles to exactly one merchant, so the caller must
    // already have narrowed the collection to a single fee group before asking
    // for a bank-routed merchant.
    if (banId != null) {
      try {
        final row = await fromSchema('bank')
            .select('paytm_mid')
            .eq('ban_id', banId)
            .maybeSingle();
        final bankMid = row?['paytm_mid']?.toString().trim();
        if (bankMid != null && bankMid.isNotEmpty) {
          return PaytmRouting(mid: bankMid, source: 'bank:$banId');
        }
      } catch (e) {
        // Fall through to the institution merchant: an unreadable bank row is
        // not a reason to refuse money the institution can still collect.
        debugPrint('resolvePaytmRouting bank lookup failed: $e');
      }
    }
    final String? insMid;
    try {
      insMid = await getPaytmMidForInstitution(insId);
    } catch (e) {
      debugPrint('resolvePaytmRouting lookup failed: $e');
      return const PaytmRouting(
          error: 'Could not work out which bank account this payment settles '
              'to. Try again, or collect it offline.');
    }
    if (insMid == null) {
      return const PaytmRouting(
          error: 'No Paytm merchant is set up for this institution, so an '
              'online payment cannot be routed to the right bank account. '
              'Collect it offline, or ask an administrator to configure it.');
    }
    return PaytmRouting(mid: insMid, source: 'institution');
  }

  /// The bank account a misc collection or an advance will be banked into.
  ///
  /// This is the CLIENT-SIDE MIRROR of the rule save_misc_collection and
  /// save_advance_collection already apply (BANK_ROUTING_BY_FEEGROUP.sql).
  /// Those resolve the account when the receipt is written; an online payment
  /// has to know the same answer BEFORE the order is created, because the
  /// merchant the order is signed with is what decides where the money
  /// actually settles. Resolve it differently in the two places and the
  /// receipt would name one account while the money went to another -- and
  /// nothing on the receipt would show it.
  ///
  ///   advType 'M'   the group owning a MESS fee type, else one named HOSTEL
  ///   advType 'A'   the group of the fee types it is itemised against
  ///   misc lines    the lowest fg_id among the fee types collected, which is
  ///                 the same one the receipt is banked under
  ///   anything else the COLLEGE group, else the lowest fg_id
  ///
  /// Returns null when nothing resolves or the group has no bank mapped: the
  /// caller then falls back to the institution's own merchant rather than
  /// refusing money it can still take.
  static Future<int?> resolveRoutingBanId({
    required int insId,
    List<String> feeTypes = const [],
    String? advType,
  }) async =>
      (await resolveRoutingTarget(
              insId: insId, feeTypes: feeTypes, advType: advType))
          .banId;

  /// The same resolution, with the NAMES -- so a counter can show the cashier
  /// where the money is going before they take it, in the same words the
  /// receipt will use.
  static Future<FeeRouting> resolveRoutingTarget({
    required int insId,
    List<String> feeTypes = const [],
    String? advType,
  }) async {
    Future<int?> fgOfFeeTypes(List<String> names) async {
      final wanted = names.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (wanted.isEmpty) return null;
      final row = await fromSchema('feetype')
          .select('fg_id')
          .inFilter('feedesc', wanted)
          .eq('activestatus', 1)
          .order('fg_id', ascending: true)
          .limit(1)
          .maybeSingle();
      return row?['fg_id'] as int?;
    }


    try {
      int? fgId;
      var isMapped = false;
      // CONFIGURED first (Setup -> Utilities -> Advance Settlement). Only if
      // nothing is configured does it fall back to matching names, which is
      // what save_advance_collection does server-side -- the two must agree,
      // or the strip on the counter would promise one account and the receipt
      // use another.
      if (advType != null && advType.isNotEmpty) {
        final settings = await getInstitutionSettings(insId);
        final raw = (settings[advanceRouteKey(advType)] ?? '').trim();
        final configured = int.tryParse(raw);
        if (configured != null) {
          // A group from another year's schema, or a deleted one, is ignored
          // rather than trusted: fee groups are per schema.
          final live = await fromSchema('feegroup')
              .select('fg_id')
              .eq('fg_id', configured)
              .eq('ins_id', insId)
              .eq('activestatus', 1)
              .maybeSingle();
          if (live != null) {
            fgId = live['fg_id'] as int?;
            isMapped = fgId != null;
          }
        }
      }
      // THE FEE TYPES NAME THEIR OWN GROUP, and that is more specific than any
      // default, so it wins.
      //
      // This used to require advType == 'A', which quietly excluded the one
      // caller that has nothing else to go on: Misc Collection passes fee
      // types and NO advance type, so it fell past this to the "unmapped"
      // return and every misc receipt settled into the institution's default
      // merchant. A MESS FEE banked into the college account instead of the
      // hostel one, while the screen said HOSTEL FEES. Advance and regular fee
      // collection were unaffected -- an advance always passes an advType, and
      // fee collection routes server-side through process_grouped_payment --
      // which is exactly why only misc was wrong.
      //
      // 'S' and 'M' advances are excluded on purpose: those are configured in
      // Setup -> Utilities -> Advance Settlement and the setting above decides
      // them, not the fee types.
      final typesDecide = advType == null || advType.isEmpty || advType == 'A';
      if (typesDecide && feeTypes.isNotEmpty) {
        final byType = await fgOfFeeTypes(feeTypes);
        if (byType != null) {
          fgId = byType;
          // Not a guess: the fee types collected against name this group.
          isMapped = true;
        }
      }
      if (fgId != null) {
        return await _routingFor(
            insId: insId, fgId: fgId, advType: advType, mapped: isMapped);
      }
      // NO NAME FALLBACK. There used to be a chain here -- the group owning a
      // MESS fee type, else one named like a hostel, else one named like a
      // college, else simply the lowest id -- so something always resolved and
      // the counter always showed an account.
      //
      // That is worse than showing nothing. The guess is usually right, which
      // means it is trusted; when it is wrong the money banks somewhere nobody
      // chose and the screen said it would go there, confidently, the whole
      // time. "COLLEGE FEES" appeared for a MESS advance purely because that
      // group's name matched last.
      //
      // Unmapped now resolves to nothing, the strip says NO FEE GROUP MAPPED,
      // and _collect refuses before any money changes hands. One setting in
      // Setup -> Utilities -> Advance Settlement decides it.
      return const FeeRouting();
    } catch (e) {
      debugPrint('resolveRoutingTarget failed: $e');
      return const FeeRouting();
    }
  }

  /// The fee group a set of collected fee types belongs to -- the lowest
  /// fg_id among them, which is the same one save_misc_collection and
  /// process_grouped_payment bank the receipt under.
  ///
  /// Used when a receipt is REPRINTED and the screen no longer knows which
  /// group it was collected for: a hostel receipt has to print the hostel
  /// letterhead however it is opened.
  static Future<int?> feeGroupOfFeeTypes(List<String> feeTypes) async {
    final wanted =
        feeTypes.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (wanted.isEmpty) return null;
    try {
      final row = await fromSchema('feetype')
          .select('fg_id')
          .inFilter('feedesc', wanted)
          .eq('activestatus', 1)
          .order('fg_id', ascending: true)
          .limit(1)
          .maybeSingle();
      return row?['fg_id'] as int?;
    } catch (e) {
      debugPrint('feeGroupOfFeeTypes failed: $e');
      return null;
    }
  }

  /// What an advance receipt should call itself: the FEE GROUP it was banked
  /// under -- "MESS ADVANCE", "STUDENT ADVANCE" -- rather than a word derived
  /// from its type.
  ///
  /// advance_collection stores ban_id but no fg_id, so:
  ///   * if exactly ONE fee group maps to that bank, that is the group, and it
  ///     is the historical truth even if the mapping has since changed;
  ///   * otherwise fall back to the group the type is configured to route to
  ///     today (Setup -> Utilities -> Advance Settlement);
  ///   * and if neither answers, [fallback].
  /// What an advance receipt is FOR — the ONE name every screen prints.
  ///
  /// Three screens render an advance receipt (Advance Collection, Transactions,
  /// Fee Demand Approval) and until 05-10-2026 each decided this differently:
  /// one preferred the fee group, one looked the group up by bank account, one
  /// said "Advance" for both student and mess. So the family's copy read
  /// "COLLEGE FEES" for a Rs 200 student advance -- naming a fee they had not
  /// paid -- and a reprint from a different screen could disagree with the
  /// original.
  ///
  /// The FEE GROUP is where the money BANKS. It is not what was collected, and
  /// it has no business on the particulars line.
  static String advanceHeadName(String? advType) =>
      switch ((advType ?? 'S').trim().toUpperCase()) {
        'A' => 'ADMISSION ADVANCE',
        'M' => 'MESS ADVANCE',
        _ => 'STUDENT ADVANCE',
      };

  static Future<String> advanceGroupLabel({
    required int insId,
    required String advType,
    int? banId,
    String fallback = 'Advance',
  }) async {
    try {
      if (banId != null) {
        final rows = await fromSchema('feegroup')
            .select('fgdesc')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('ban_id', banId);
        final names = [
          for (final r in (rows as List))
            if ((r['fgdesc']?.toString() ?? '').trim().isNotEmpty)
              r['fgdesc'].toString().trim(),
        ];
        // Two groups sharing one bank cannot say which this was; fall through.
        if (names.length == 1) return names.first;
      }
      final routed =
          await resolveRoutingTarget(insId: insId, advType: advType.toUpperCase());
      if (routed.fgName.trim().isNotEmpty) return routed.fgName.trim();
    } catch (e) {
      debugPrint('advanceGroupLabel failed: $e');
    }
    return fallback;
  }

  /// A fee group with its bank account and that account's Paytm merchant.
  /// The sequence tested here is the FEE GROUP's own, for every kind of
  /// advance, because that is now the only series an advance is numbered from
  /// -- see migrations/shared/ADVANCE_NUMBER_FROM_FEEGROUP.sql.
  ///
  /// It briefly checked an ADVNO series for student and mess advances, which
  /// was the server's old rule. The rule itself was the problem: mapping an
  /// advance to a fee group was not enough, a second sequence had to exist on
  /// a different screen, and nothing on the counter said so until Collect was
  /// pressed. One mapping now decides the account and the number together.
  static Future<FeeRouting> _routingFor(
      {required int insId,
      required int fgId,
      String? advType,
      bool mapped = false}) async {
    final grp = await fromSchema('feegroup')
        .select('fg_id, fgdesc, ban_id')
        .eq('fg_id', fgId)
        .maybeSingle();
    final seq = await fromSchema('sequence')
        .select('seq_id')
        .eq('ins_id', insId)
        .eq('fg_id', fgId)
        .eq('activestatus', 1)
        .limit(1)
        .maybeSingle();
    final hasSeq = seq != null;
    final banId = grp?['ban_id'] as int?;
    if (banId == null) {
      return FeeRouting(
          fgId: fgId,
          fgName: grp?['fgdesc']?.toString() ?? '',
          hasSequence: hasSeq,
          mapped: mapped);
    }
    final bank = await fromSchema('bank')
        .select('banname, paytm_mid')
        .eq('ban_id', banId)
        .maybeSingle();
    return FeeRouting(
      fgId: fgId,
      fgName: grp?['fgdesc']?.toString() ?? '',
      banId: banId,
      bankName: bank?['banname']?.toString() ?? '',
      paytmMid: bank?['paytm_mid']?.toString().trim() ?? '',
      hasSequence: hasSeq,
      mapped: mapped,
    );
  }

  /// The paying institution's own Paytm merchant, from the routing table
  /// public.paytm_configuration (institution_id -> merchant_id, is_active).
  ///
  /// Only merchant_id is read. The table's website / industry_type / channel_id
  /// columns are NOT used — those come from the edge function's PAYTM_WEBSITE
  /// env (and channelId from the mobile app's request), so changing them here
  /// has no effect.
  ///
  /// Each merchant is a full independent Paytm account signed with its OWN key
  /// from the edge function's PAYTM_MERCHANTS map — not the aggregator model,
  /// where a sub MID is signed with the parent key. Paytm rejects that with
  /// 2005 "Checksum provided is invalid", proven against this account.
  ///
  /// Returns null when no active row exists. The caller
  /// ([resolvePaytmRouting]) then REFUSES the payment; it deliberately does not
  /// fall back to the default parent merchant, which is how money silently
  /// reached the parent account after a database rebuild.
  static Future<String?> getPaytmMidForInstitution(int insId) async {
    try {
      final row = await client
          .from('paytm_configuration')
          .select('merchant_id')
          .eq('institution_id', insId)
          .eq('is_active', true)
          .maybeSingle();
      final mid = row?['merchant_id']?.toString();
      return (mid != null && mid.isNotEmpty) ? mid : null;
    } catch (e) {
      debugPrint('getPaytmMidForInstitution error: $e');
      return null;
    }
  }

  /// Insert a fee group — returns the new fg_id
  static Future<int> addFeeGroup(Map<String, dynamic> data) async {
    final id = await saveSchemaRow('feegroup', data, pkCol: 'fg_id');
    if (id == null) throw Exception('Fee group insert returned no data');
    return id;
  }

  // ==================== FEE MASTER ====================

  /// Get all active fee master records for an institution
  static Future<List<Map<String, dynamic>>> getFeesMaster(int insId) async {
    try {
      // feetype has no ins_id — filter via fee group IDs belonging to this institution
      final feeGroups = await getFeeGroups(insId);
      if (feeGroups.isEmpty) return [];
      final fgIds = feeGroups.map((fg) => fg['fg_id'] as int).toList();
      final response = await fromSchema('feetype')
          .select('*')
          .inFilter('fg_id', fgIds)
          .eq('activestatus', 1)
          .order('fee_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching fees master: $e');
      return [];
    }
  }

  /// Insert a fee master record — returns the new fee_id
  static Future<int> addFeeMaster(Map<String, dynamic> data) async {
    final id = await saveSchemaRow('feetype', data, pkCol: 'fee_id');
    if (id == null) throw Exception('Fee insert returned no data');
    return id;
  }

  // ==================== FEES ====================

  /// Get all fee demands for an institution (with student name)
  static Future<List<Map<String, dynamic>>> getFeeDemands(int insId) async {
    try {
      // RETURNS json (json_agg) — single scalar bypasses PostgREST row limit
      final response = await client.rpc('get_fee_demands', params: {'p_ins_id': insId});
      if (response == null) return [];
      final list = List<Map<String, dynamic>>.from(response as List);
      // If RPC doesn't include demfeeterm, enrich from fallback
      if (list.isNotEmpty && !list.first.containsKey('demfeeterm')) {
        debugPrint('RPC get_fee_demands missing demfeeterm, enriching with fallback');
        final termMap = await _getFeeDemandTermMap(insId);
        for (final row in list) {
          final feeId = row['fee_id'];
          if (feeId != null && termMap.containsKey(feeId)) {
            row['demfeeterm'] = termMap[feeId];
          }
        }
      }
      return list;
    } catch (e) {
      debugPrint('RPC get_fee_demands failed: $e');
      return _getFeeDemandsFallback(insId);
    }
  }

  /// Fetch only fee_id -> demfeeterm mapping for enrichment
  static Future<Map<int, String>> _getFeeDemandTermMap(int insId) async {
    try {
      const batchSize = 1000;
      int offset = 0;
      final Map<int, String> result = {};
      while (true) {
        final batch = await fromSchema('feedemand')
            .select('fee_id, demfeeterm')
            .eq('ins_id', insId)
            .range(offset, offset + batchSize - 1);
        final list = batch as List;
        for (final row in list) {
          final feeId = row['fee_id'] as int?;
          final term = row['demfeeterm']?.toString() ?? '';
          if (feeId != null && term.isNotEmpty) {
            result[feeId] = term;
          }
        }
        if (list.length < batchSize) break;
        offset += batchSize;
      }
      return result;
    } catch (e) {
      debugPrint('Error fetching term map: $e');
      return {};
    }
  }

  static Future<List<Map<String, dynamic>>> _getFeeDemandsFallback(int insId) async {
    try {
      const batchSize = 1000;
      int offset = 0;
      final List<Map<String, dynamic>> allResults = [];
      while (true) {
        final batch = await fromSchema('feedemand')
            .select('fee_id, ins_id, stu_id, feeamount, conamount, paidamount, balancedue, reconbalancedue, paidstatus, demseqtype, stuclass, stuadmno, demfeetype, demfeeterm, pay_id, activestatus')
            .eq('ins_id', insId)
            .range(offset, offset + batchSize - 1);
        final list = batch as List;
        allResults.addAll(list.cast<Map<String, dynamic>>());
        if (list.length < batchSize) break;
        offset += batchSize;
      }
      return allResults;
    } catch (e) {
      debugPrint('Fallback getFeeDemands failed: $e');
      return [];
    }
  }

  /// Get paid fee demands with payment date (for date-wise tab)
  /// Uses RPC to bypass row limits; falls back to direct query
  static Future<List<Map<String, dynamic>>> getPaidFeeDemands(int insId) async {
    // Skip RPC — it only fetches paidstatus='P' and misses partially paid ('U') rows.
    // Using paginated fallback which includes both 'P' and 'U' with paidamount > 0.

    // Fallback: fetch paid feedemand rows (paginated), then batch-fetch payment dates
    try {
      final demandList = <Map<String, dynamic>>[];
      const batchSize = 1000;
      int offset = 0;
      while (true) {
        final demands = await fromSchema('feedemand')
            .select('fee_id, ins_id, stu_id, feeamount, conamount, paidamount, fineamount, balancedue, paidstatus, stuclass, courname, stuadmno, demfeetype, demfeeterm, pay_id')
            .eq('ins_id', insId)
            .inFilter('paidstatus', ['P', 'U'])
            .eq('activestatus', 1)
            .gt('paidamount', 0)
            .range(offset, offset + batchSize - 1);
        final rows = List<Map<String, dynamic>>.from(demands as List);
        demandList.addAll(rows);
        if (rows.length < batchSize) break;
        offset += batchSize;
      }
      if (demandList.isEmpty) return [];

      // Collect unique pay_ids and stu_ids
      final payIds = demandList
          .map((d) => d['pay_id'])
          .where((id) => id != null)
          .toSet()
          .toList();
      final stuIds = demandList
          .map((d) => d['stu_id'])
          .where((id) => id != null)
          .toSet()
          .toList();

      // Fetch payment dates and student names in parallel
      final Map<int, String> payDateMap = {};
      final Map<int, String> stuNameMap = {};
      // Only reconciled (approved) payments should show in the date-wise
      // register — pending-approval money is displayed separately.
      final Set<int> approvedPayIds = {};

      final enrichFutures = <Future>[];

      // Payment date + recon status futures
      for (var i = 0; i < payIds.length; i += 500) {
        final chunk = payIds.sublist(i, (i + 500).clamp(0, payIds.length));
        enrichFutures.add(fromSchema('payment')
            .select('pay_id, paydate, recon_status')
            .inFilter('pay_id', chunk)
            .then((payRows) {
          for (final row in (payRows as List)) {
            final id = row['pay_id'] as int?;
            final date = row['paydate']?.toString();
            final status = row['recon_status']?.toString() ?? 'P';
            if (id != null) {
              if (date != null) payDateMap[id] = date;
              if (status == 'R') approvedPayIds.add(id);
            }
          }
        }));
      }

      // Student name futures
      for (var i = 0; i < stuIds.length; i += 500) {
        final chunk = stuIds.sublist(i, (i + 500).clamp(0, stuIds.length));
        enrichFutures.add(fromSchema('students')
            .select('stu_id, stuname')
            .inFilter('stu_id', chunk)
            .then((stuRows) {
          for (final row in (stuRows as List)) {
            final id = row['stu_id'] as int?;
            final name = row['stuname']?.toString();
            if (id != null && name != null) stuNameMap[id] = name;
          }
        }));
      }

      await Future.wait(enrichFutures);

      // Enrich demand rows with paydate and stuname
      for (final d in demandList) {
        final payId = d['pay_id'] as int?;
        if (payId != null) d['paydate'] = payDateMap[payId];
        final stuId = d['stu_id'] as int?;
        if (stuId != null) d['stuname'] = stuNameMap[stuId] ?? '';
      }

      // Drop demands whose payment is still pending approval.
      final approved = demandList.where((d) {
        final payId = d['pay_id'] as int?;
        return payId != null && approvedPayIds.contains(payId);
      }).toList();

      return approved;
    } catch (e) {
      debugPrint('Error fetching paid fee demands: $e');
      return [];
    }
  }

  /// Raw Daily Collection rows for a date range — one row per (receipt x
  /// semester), each with fees_json (demfeetype -> amount), fine, total, and
  /// student info. Same source the Reports > Daily Collection screen uses, so
  /// callers reconcile with it exactly. Uses the json_agg wrapper (no 1000-row
  /// cap); falls back to paginating the SETOF RPC.
  static Future<List<Map<String, dynamic>>> getDailyCollectionRows(
      int insId, DateTime from, DateTime to) async {
    final schema = currentSchema;
    if (schema == null) return [];
    String d(DateTime x) =>
        '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final params = {
      'p_schema': schema,
      'p_ins_id': insId,
      'p_from': d(from),
      'p_to': d(to),
    };
    final list = <Map<String, dynamic>>[];
    try {
      final agg = await client.rpc('get_daily_collection_report_json', params: params);
      if (agg is List) list.addAll(List<Map<String, dynamic>>.from(agg));
    } catch (_) {
      const pageSize = 1000;
      int offset = 0;
      while (true) {
        final page = await client
            .rpc('get_daily_collection_report', params: params)
            .range(offset, offset + pageSize - 1);
        final batch = page is List ? List<Map<String, dynamic>>.from(page) : <Map<String, dynamic>>[];
        list.addAll(batch);
        if (batch.length < pageSize) break;
        offset += pageSize;
      }
    }
    return list;
  }

  /// Fetch paynumber lookup map: pay_id → paynumber
  static Future<Map<int, String>> getPayNumberMap(List<int> payIds, {required int insId}) async {
    if (payIds.isEmpty) return {};
    try {
      final Map<int, String> result = {};
      // Batch in chunks of 500 to avoid query size limits
      for (var i = 0; i < payIds.length; i += 500) {
        final chunk = payIds.sublist(i, (i + 500).clamp(0, payIds.length));
        final response = await fromSchema('payment')
            .select('pay_id, paynumber')
            .eq('ins_id', insId)
            .inFilter('pay_id', chunk);
        for (final row in (response as List)) {
          final id = row['pay_id'] as int?;
          final num = row['paynumber']?.toString();
          if (id != null && num != null) result[id] = num;
        }
      }
      return result;
    } catch (e) {
      debugPrint('Error fetching pay numbers: $e');
      return {};
    }
  }

  /// Fetch total fee demand (sum of feeamount), total collection (sum of transtotalamount), and total pending (sum of balancedue)
  /// Uses RPC for server-side aggregation to avoid PostgREST row limits.
  static Future<Map<String, double>> getFeeTotals(int insId) async {
    try {
      final result = await _retry(() => client.rpc('get_fee_totals', params: {'p_ins_id': insId}));
      final rpcFine = (result['total_fine'] as num?)?.toDouble() ?? 0;
      return {
        'totalDemand': (result['total_demand'] as num?)?.toDouble() ?? 0,
        // The RPC's total_paid is SUM(paidamount), which carries the fine
        // portion with it. Fine is a late-payment penalty, not fee collection,
        // so it is reported on its own card -- and the paginated fallback below
        // has always subtracted it, so the two paths disagreed depending on
        // whether the RPC was reachable.
        'totalPaid': ((result['total_paid'] as num?)?.toDouble() ?? 0) - rpcFine,
        'totalPending': (result['total_pending'] as num?)?.toDouble() ?? 0,
        'totalFine': rpcFine,
      };
    } catch (e) {
      debugPrint('RPC get_fee_totals failed, using fallback: $e');
    }

    // Fallback: paginate through all rows to avoid 1000-row cap
    try {
      double totalDemand = 0, totalPaidRaw = 0, totalPending = 0, totalFine = 0;
      const batchSize = 1000;
      int offset = 0;
      while (true) {
        final demandRes = await fromSchema('feedemand')
            .select('feeamount, paidamount, balancedue, fineamount, paidstatus')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .range(offset, offset + batchSize - 1);
        final rows = demandRes as List;
        for (final row in rows) {
          totalDemand += (row['feeamount'] as num?)?.toDouble() ?? 0;
          totalPaidRaw += (row['paidamount'] as num?)?.toDouble() ?? 0;
          totalPending += (row['balancedue'] as num?)?.toDouble() ?? 0;
          // Count fine on demands that are paid OR partially paid
          final paid = (row['paidamount'] as num?)?.toDouble() ?? 0;
          final isPaid = (row['paidstatus']?.toString() ?? '') == 'P';
          if (isPaid || paid > 0) {
            totalFine += (row['fineamount'] as num?)?.toDouble() ?? 0;
          }
        }
        if (rows.length < batchSize) break;
        offset += batchSize;
      }

      // Match RPC: totalPaid is fee-only collection (excludes fine portion of paid rows)
      return {'totalDemand': totalDemand, 'totalPaid': totalPaidRaw - totalFine, 'totalPending': totalPending, 'totalFine': totalFine};
    } catch (e) {
      debugPrint('Error fetching fee totals: $e');
      return {'totalDemand': 0, 'totalPaid': 0, 'totalPending': 0, 'totalFine': 0};
    }
  }

  /// Fetch payment amounts (transtotalamount) for given pay_ids
  static Future<Map<int, double>> getPayAmountMap(List<int> payIds, {required int insId}) async {
    if (payIds.isEmpty) return {};
    try {
      final Map<int, double> result = {};
      for (var i = 0; i < payIds.length; i += 500) {
        final chunk = payIds.sublist(i, (i + 500).clamp(0, payIds.length));
        final response = await fromSchema('payment')
            .select('pay_id, transtotalamount')
            .eq('ins_id', insId)
            .inFilter('pay_id', chunk);
        for (final row in (response as List)) {
          final id = row['pay_id'] as int?;
          final amt = (row['transtotalamount'] as num?)?.toDouble();
          if (id != null && amt != null) result[id] = amt;
        }
      }
      return result;
    } catch (e) {
      debugPrint('Error fetching pay amounts: $e');
      return {};
    }
  }

  /// Retry a network call a couple of times with a short backoff, so a single
  /// dropped connection (TLS handshake terminated / socket timeout) self-heals
  /// instead of blanking the dashboard. Used by the summary/payment fetches.
  static Future<T> _retry<T>(Future<T> Function() fn, {int retries = 2}) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await fn();
      } catch (_) {
        if (attempt >= retries) rethrow;
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  }

  /// Aggregate summary per class — one row per class, no row-limit issues
  static Future<List<Map<String, dynamic>>> getFeeDemandSummary(int insId) async {
    try {
      final response = await _retry(() => client.rpc('get_fee_demand_summary', params: {'p_ins_id': insId}));
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('RPC get_fee_demand_summary failed: $e');
      return [];
    }
  }

  /// Fetch ordering maps for the institution's courses and classes
  /// (course.ordid keyed by courname, class.ordid keyed by claname). Used by
  /// summary screens that need to sort rows by master-data order rather than
  /// alphabetic / hard-coded class order.
  static Future<({Map<String, int> courseOrd, Map<String, int> classOrd})>
      getCourseClassOrdering(int insId) async {
    try {
      final results = await Future.wait<dynamic>([
        fromSchema('course').select('courname, ordid').eq('ins_id', insId).eq('activestatus', 1),
        fromSchema('class').select('claname, ordid').eq('ins_id', insId).eq('activestatus', 1),
      ]);
      final courseOrd = <String, int>{};
      for (final r in (results[0] as List)) {
        final name = (r['courname'] as String?)?.trim();
        final ord = (r['ordid'] as num?)?.toInt();
        if (name != null && name.isNotEmpty && ord != null) courseOrd[name] = ord;
      }
      final classOrd = <String, int>{};
      for (final r in (results[1] as List)) {
        final name = (r['claname'] as String?)?.trim();
        final ord = (r['ordid'] as num?)?.toInt();
        if (name != null && name.isNotEmpty && ord != null) classOrd[name] = ord;
      }
      return (courseOrd: courseOrd, classOrd: classOrd);
    } catch (e) {
      debugPrint('getCourseClassOrdering failed: $e');
      return (courseOrd: <String, int>{}, classOrd: <String, int>{});
    }
  }

  /// Whether the prerequisites for importing students are in place: master
  /// data (classes) and admission master (admission types). The student import
  /// is blocked until BOTH have been imported, so course/class and admission
  /// mappings exist for the incoming rows. Fail-safe: on error both flags
  /// return false so the import stays gated rather than silently allowed.
  static Future<({bool hasMasterData, bool hasAdmissionMaster})>
      getStudentImportPrerequisites(int insId) async {
    var hasMasterData = false;
    var hasAdmissionMaster = false;
    try {
      final results = await Future.wait<dynamic>([
        fromSchema('class')
            .select('claname')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .limit(1),
        // School has no admission type table -- nothing to wait for there.
        if (!isSchoolLayout)
          fromSchema('admissiontype')
              .select('adm_id')
              .eq('activestatus', 1)
              .limit(1),
      ]);
      hasMasterData = (results[0] as List).isNotEmpty;
      hasAdmissionMaster = isSchoolLayout || (results[1] as List).isNotEmpty;
    } catch (e) {
      debugPrint('getStudentImportPrerequisites failed: $e');
    }
    return (hasMasterData: hasMasterData, hasAdmissionMaster: hasAdmissionMaster);
  }

  /// Individual demand rows for a single class — used for drilldown
  static Future<List<Map<String, dynamic>>> getFeeDemandsByClass(int insId, String className) async {
    try {
      // RETURNS json (json_agg) — single scalar bypasses PostgREST row limit
      final response = await client.rpc('get_fee_demands_by_class', params: {'p_ins_id': insId, 'p_class': className});
      if (response == null) return [];
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('RPC get_fee_demands_by_class failed: $e');
      return [];
    }
  }

  /// Fetch pending fee demands for the institution via DB function.
  /// Only returns rows for students with activestatus = 1.
  ///
  /// Prefer the `_json` wrapper: `get_fee_demands_pending` returns SETOF json,
  /// which PostgREST caps at 1000 rows — bulk demand generation stages far more
  /// than that, so a plain call silently hides demands past #1000 from the
  /// approval queue. The json_agg wrapper returns every row as one JSON value
  /// (no cap). Falls back to the capped RPC if the wrapper isn't deployed yet.
  static Future<List<Map<String, dynamic>>> getFeeDemandsPending(int insId) async {
    try {
      final response = await client
          .rpc('get_fee_demands_pending_json', params: {'p_ins_id': insId});
      if (response == null) return [];
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('get_fee_demands_pending_json failed, falling back (capped at 1000): $e');
      try {
        final response = await client
            .rpc('get_fee_demands_pending', params: {'p_ins_id': insId});
        if (response == null) return [];
        return List<Map<String, dynamic>>.from(response as List);
      } catch (e2) {
        debugPrint('getFeeDemandsPending failed: $e2');
        return [];
      }
    }
  }

  /// Get fee collection summary for an institution
  /// Fee Collection = sum of transtotalamount from payment table where paystatus='C'
  /// Pending Fees = sum of balancedue from feedemand table where paidstatus='U'
  static Future<FeeSummary> getFeeSummary(int insId) async {
    try {
      // Use RPCs for server-side aggregation (avoids row-limit issues and slow pagination)
      final rpcFuture = _retry(() => client.rpc('get_fee_summary', params: {'p_ins_id': insId}));
      final totalsFuture = getFeeTotals(insId);
      final results = await Future.wait<dynamic>([rpcFuture, totalsFuture]);

      final rpcResult = results[0];
      final feeTotals = results[1] as Map<String, double>;

      // Pending must use the RECONCILED balance (reconbalancedue) so
      // collected-but-not-yet-reconciled payments still count as pending.
      // get_fee_totals already sums reconbalancedue; the get_fee_summary RPC
      // sums plain balancedue, so prefer the former to stay consistent with
      // the dashboard's Pending Fees card.
      final totalPending =
          feeTotals['totalPending'] ?? (rpcResult['total_pending'] as num?)?.toDouble() ?? 0;
      final pendingCount = (rpcResult['pending_count'] as num?)?.toInt() ?? 0;

      return FeeSummary(
        totalDue: feeTotals['totalDemand'] ?? 0,
        totalPaid: feeTotals['totalPaid'] ?? 0,
        totalPending: totalPending,
        pendingCount: pendingCount,
      );
    } catch (e) {
      debugPrint('Error fetching fee summary: $e');
      return FeeSummary(
          totalDue: 0, totalPaid: 0, totalPending: 0, pendingCount: 0);
    }
  }

  // ==================== PAYMENTS ====================

  /// Get payments for an institution within a date range via RPC function
  static Future<List<Map<String, dynamic>>> getPaymentsByDateRange(
    int insId, {
    required DateTime fromDate,
    required DateTime toDate,
  }) async {
    try {
      final from = fromDate.toIso8601String().split('T').first;
      final to = toDate.toIso8601String().split('T').first;

      final response = await _retry(() => client.rpc('get_payments_by_date_range', params: {
        'p_ins_id': insId,
        'p_from_date': from,
        'p_to_date': to,
      }));

      // Normalise: wrap flat student fields into nested 'students' map
      // so existing UI code (p['students']['stuname'] etc.) keeps working
      if (response == null) return [];
      final payments = List<Map<String, dynamic>>.from(response as List);
      debugPrint('RPC get_payments_by_date_range returned ${payments.length} rows');
      for (final p in payments) {
        if (p['stuname'] != null && !p.containsKey('students')) {
          p['students'] = {
            'stuname': p['stuname'],
            'stuadmno': p['stuadmno'],
            'stuclass': p['stuclass'],
            'courname': p['courname'] ?? '',
          };
        }
      }
      // If RPC returns exactly 1000 rows, it may be truncated — fall through to paginated fallback
      if (payments.length == 1000) {
        debugPrint('RPC may be truncated (exactly 1000 rows), using paginated fallback');
      } else {
        return payments;
      }
    } catch (e) {
      debugPrint('RPC get_payments_by_date_range failed, using fallback: $e');
    }

    // Fallback if RPC not yet created (paginated)
    try {
      final from = fromDate.toIso8601String().split('T').first;
      final to = '${toDate.toIso8601String().split('T').first}T23:59:59';
      final payments = <Map<String, dynamic>>[];
      const batchSize = 1000;
      int offset = 0;
      while (true) {
        final response = await fromSchema('payment')
            .select('*')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('paystatus', 'C')
            .gte('paydate', from)
            .lte('paydate', to)
            .order('paydate', ascending: false)
            .range(offset, offset + batchSize - 1);
        final rows = List<Map<String, dynamic>>.from(response as List);
        payments.addAll(rows);
        if (rows.length < batchSize) break;
        offset += batchSize;
      }

      // Collect unique stu_ids and fetch student info
      final stuIds = payments
          .map((p) => p['stu_id'])
          .where((id) => id != null)
          .toSet()
          .toList();

      if (stuIds.isNotEmpty) {
        final students = await fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname')
            .inFilter('stu_id', stuIds);
        final stuMap = <int, Map<String, dynamic>>{};
        for (final s in (students as List)) {
          stuMap[s['stu_id'] as int] = s;
        }
        for (final p in payments) {
          final stuId = p['stu_id'];
          if (stuId != null && stuMap.containsKey(stuId)) {
            p['students'] = stuMap[stuId];
          }
        }
      }

      return payments;
    } catch (e) {
      debugPrint('Error fetching payments by date range: $e');
      return [];
    }
  }

  /// Get fee details for a payment, with fee group name lookup
  static Future<List<Map<String, dynamic>>> getFeeDetailsByPayId(int payId, {int? insId}) async {
    try {
      // PAYMENTDETAILS FIRST, not feedemand.pay_id.
      //
      // feedemand.pay_id holds only the LAST payment that touched the demand,
      // so any demand paid more than once loses the earlier receipts' lines:
      // reprinting instalment 1 found no rows and fell back to a single
      // "Payment" line. An advance adjustment made it routine -- adjust_advance
      // stamps pay_id, then the cash payment in the same transaction overwrites
      // it, leaving the adjustment receipt with no particulars at all.
      //
      // paymentdetails is written once per receipt and never rewritten, so it
      // is the only faithful record of what a given receipt covered.
      final pd = await fromSchema('paymentdetails')
          .select('dem_id, transtotalamount')
          .eq('pay_id', payId);
      final pdRows = List<Map<String, dynamic>>.from(pd as List);
      final paidMap = <int, double>{};
      final demIds = <int>[];
      for (final p in pdRows) {
        final demId = (p['dem_id'] as num?)?.toInt();
        if (demId == null) continue;
        // One receipt can carry two lines for the same demand; sum them.
        paidMap[demId] = (paidMap[demId] ?? 0) + ((p['transtotalamount'] as num?)?.toDouble() ?? 0);
        if (!demIds.contains(demId)) demIds.add(demId);
      }
      debugPrint('RECEIPT: pay_id=$payId paymentdetails=${paidMap.length} rows=${paidMap.entries.map((e) => '${e.key}:${e.value}').join(", ")}');

      var details = <Map<String, dynamic>>[];
      if (demIds.isNotEmpty) {
        final response = await fromSchema('feedemand')
            .select('dem_id, stuclass, demfeeterm, demfeetype, fee_id, feeamount, conamount, paidamount, fineamount, balancedue, paidstatus, duedate, demseqtype, arrearclass')
            .inFilter('dem_id', demIds);
        details = List<Map<String, dynamic>>.from(response as List);
        for (final d in details) {
          final demId = (d['dem_id'] as num?)?.toInt();
          if (demId != null && paidMap.containsKey(demId)) {
            d['collectedamount'] = paidMap[demId];
          }
        }
        // Keep receipt order stable: follow the order the lines were written.
        details.sort((a, b) => demIds
            .indexOf((a['dem_id'] as num).toInt())
            .compareTo(demIds.indexOf((b['dem_id'] as num).toInt())));
      } else {
        // No paymentdetails at all (a legacy row, or a header-only receipt).
        // Fall back to the old linkage so nothing that used to print stops.
        final response = await fromSchema('feedemand')
            .select('dem_id, stuclass, demfeeterm, demfeetype, fee_id, feeamount, conamount, paidamount, fineamount, balancedue, paidstatus, duedate, demseqtype, arrearclass')
            .eq('pay_id', payId)
            .eq('activestatus', 1);
        details = List<Map<String, dynamic>>.from(response as List);
      }

      // Fetch fee group names via fee_id → feetype → feegroup
      if (details.isNotEmpty) {
        try {
          final feeIds = details
              .map((d) => d['fee_id'])
              .where((id) => id != null)
              .toSet()
              .toList();
          if (feeIds.isNotEmpty) {
            final feeTypes = await fromSchema('feetype')
                .select('fee_id, feedesc, fg_id')
                .inFilter('fee_id', feeIds)
                .eq('activestatus', 1);
            final feeIdToFgId = <int, int>{};
            final fgIds = <int>{};
            for (final ft in (feeTypes as List)) {
              feeIdToFgId[ft['fee_id'] as int] = ft['fg_id'] as int;
              fgIds.add(ft['fg_id'] as int);
            }
            final feeGroups = await fromSchema('feegroup')
                .select('fg_id, fgdesc')
                .inFilter('fg_id', fgIds.toList());
            final fgMap = <int, String>{};
            for (final fg in (feeGroups as List)) {
              fgMap[fg['fg_id'] as int] = fg['fgdesc']?.toString() ?? '';
            }
            for (final d in details) {
              final feeId = d['fee_id'] as int?;
              if (feeId != null && feeIdToFgId.containsKey(feeId)) {
                d['feegroupname'] = fgMap[feeIdToFgId[feeId]] ?? '';
              }
            }
          }
        } catch (e) {
          debugPrint('Error fetching fee group names: $e');
        }
      }

      return details;
    } catch (e) {
      debugPrint('Error fetching fee details for pay_id $payId: $e');
      return [];
    }
  }

  /// Get fee group names mapped by fee_id
  /// Returns two maps:
  /// - 'byId': fee_id -> fee group name
  /// - 'byName': fee type name (feedesc) -> fee group name
  static Future<Map<String, Map>> getFeeGroupMaps(int insId) async {
    try {
      final feeTypes = await fromSchema('feetype')
          .select('fee_id, feedesc, fg_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final feeIdToFgId = <int, int>{};
      final feeDescToFgId = <String, int>{};
      final fgIds = <int>{};
      for (final ft in (feeTypes as List)) {
        final feeId = ft['fee_id'] as int?;
        final fgId = ft['fg_id'] as int?;
        final feedesc = ft['feedesc']?.toString() ?? '';
        if (fgId != null && fgId > 0) {
          if (feeId != null) {
            feeIdToFgId[feeId] = fgId;
          }
          if (feedesc.isNotEmpty) {
            feeDescToFgId[feedesc] = fgId;
          }
          fgIds.add(fgId);
        }
      }
      if (fgIds.isEmpty) return {'byId': {}, 'byName': {}};
      final feeGroups = await fromSchema('feegroup')
          .select('fg_id, fgdesc')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .inFilter('fg_id', fgIds.toList());
      final fgMap = <int, String>{};
      for (final fg in (feeGroups as List)) {
        fgMap[fg['fg_id'] as int] = fg['fgdesc']?.toString() ?? '';
      }
      final byId = <int, String>{};
      for (final entry in feeIdToFgId.entries) {
        final name = fgMap[entry.value] ?? '';
        if (name.isNotEmpty) {
          byId[entry.key] = name;
        }
      }
      final byName = <String, String>{};
      for (final entry in feeDescToFgId.entries) {
        final name = fgMap[entry.value] ?? '';
        if (name.isNotEmpty) {
          byName[entry.key] = name;
        }
      }
      return {'byId': byId, 'byName': byName};
    } catch (e) {
      debugPrint('Error fetching fee group map: $e');
      return {'byId': {}, 'byName': {}};
    }
  }

  /// Get recent payments for an institution
  static Future<List<PaymentModel>> getRecentPayments(int insId,
      {int limit = 10}) async {
    try {
      // RECEIPT DATE, NOT INSERTION DATE.
      //
      // createdat is when the ROW was written; paydate is when the money was
      // taken. They differ whenever a receipt is imported or recovered by the
      // sweep -- those are written today and dated weeks back. Ordering by
      // createdat put the back-dated hostel arrears (July, August) at the top
      // of Recent Payments while the 33 collections taken that morning were
      // nowhere on the card.
      //
      // `paydate ?? createdat` is the Transactions screen's own rule, so the
      // two screens now agree about what "recent" means. The server sorts on
      // paydate with nulls last; over-fetching lets the client sort rescue a
      // row with no paydate instead of letting the limit drop it.
      final response = await fromSchema('payment')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          // Recent Payments shows successful collections only — exclude failed
          // ('F') / initiated ('I') attempts. 'C' = collected, 'R' = refunded.
          .inFilter('paystatus', ['C', 'R'])
          .order('paydate', ascending: false, nullsFirst: false)
          .order('createdat', ascending: false)
          .limit(limit * 3);
      final rows = (response as List)
          .map((e) => PaymentModel.fromJson(e))
          .toList()
        ..sort((a, b) =>
            (b.paydate ?? b.createdat).compareTo(a.paydate ?? a.createdat));
      return rows.take(limit).toList();
    } catch (e) {
      debugPrint('Error fetching recent payments: $e');
      return [];
    }
  }

  /// Get all transactions for an institution via RPC, with direct table fallback
  /// [from]/[to] bound the fetch server-side. Without them this pulls every
  /// transaction the institution has ever taken, which the Transactions screen
  /// then throws away to show one day -- thousands of rows and a dozen extra
  /// round trips for a handful of receipts.
  ///
  /// The bound matches the screen's own rule, `paydate ?? createdat`: a row
  /// with no paydate (an initiated payment) is judged on createdat, so it is
  /// not silently dropped by a paydate-only filter.
  /// Latched once the date-aware RPC is found to be absent, so a database
  /// without the migration pays for one failed call per session, not one per
  /// refresh.
  static bool _txRangeRpcMissing = false;

  static Future<List<Map<String, dynamic>>> getAllTransactions(int insId,
      {DateTime? from, DateTime? to}) async {
    String d(DateTime x) => '${x.year.toString().padLeft(4, '0')}-'
        '${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    String? orClause;
    if (from != null && to != null) {
      final lo = d(from);
      // Exclusive upper bound on the next day, so a timestamp anywhere inside
      // the last day is included without depending on how time is stored.
      final hi = d(to.add(const Duration(days: 1)));
      orClause = 'and(paydate.gte.$lo,paydate.lt.$hi),'
          'and(paydate.is.null,createdat.gte.$lo,createdat.lt.$hi)';
    }
    // Preferred: the RANGE overload, which takes the dates as arguments.
    //
    // fn_get_transactions(p_ins_id) takes only an institution, so `.or(dates)`
    // is a PostgREST filter applied to its OUTPUT. The function is plpgsql and
    // cannot be inlined, so Postgres must build every payment row the
    // institution has ever had, LEFT JOIN students for each one and sort the
    // lot by createdat, and only then throw away all but the day asked for.
    // Drawing today costs the whole year -- and costs exactly as much on a day
    // with no transactions at all. The overload pushes the dates into the WHERE
    // inside the function, where an index can be used.
    if (!_txRangeRpcMissing) {
      try {
        final all = <Map<String, dynamic>>[];
        const batchSize = 1000;
        int offset = 0;
        while (true) {
          final response = await client.rpc('fn_get_transactions_range', params: {
            'p_ins_id': insId,
            'p_from': from == null ? null : d(from),
            'p_to': to == null ? null : d(to),
          }).range(offset, offset + batchSize - 1);
          final rows = List<Map<String, dynamic>>.from(response as List);
          all.addAll(rows);
          if (rows.length < batchSize) break;
          offset += batchSize;
        }
        return all;
      } catch (e) {
        // Only a MISSING function is permanent. A timeout or a dropped
        // connection must not disable the fast path for the rest of the
        // session, which is what latching on any error at all would do.
        final msg = e.toString();
        if (msg.contains('PGRST202') ||
            msg.contains('Could not find the function') ||
            msg.contains('does not exist')) {
          _txRangeRpcMissing = true;
          debugPrint('fn_get_transactions_range not deployed; '
              'using the unfiltered RPC (slower). Run '
              'migrations/desktop/FN_GET_TRANSACTIONS_RANGE.sql');
        } else {
          debugPrint('fn_get_transactions_range failed: $e');
        }
      }
    }
    // Fallback: the enriched RPC (adds stuname), PAGINATED — PostgREST caps any
    // single response (RPC calls included) at 1000 rows, so a plain call would
    // silently return only the first 1000 transactions. The RPC orders by
    // createdat DESC, so range-paging is stable.
    try {
      final all = <Map<String, dynamic>>[];
      const batchSize = 1000;
      int offset = 0;
      while (true) {
        var q = client.rpc('fn_get_transactions', params: {'p_ins_id': insId});
        if (orClause != null) q = q.or(orClause);
        final response = await q.range(offset, offset + batchSize - 1);
        final rows = List<Map<String, dynamic>>.from(response as List);
        all.addAll(rows);
        if (rows.length < batchSize) break;
        offset += batchSize;
      }
      // An empty DAY is an ordinary answer -- don't pay for the whole payment
      // table to confirm it. An empty result with NO date filter is not: the
      // function returns nothing when it cannot resolve the institution's
      // schema, and that is what the direct query is here to rescue.
      if (all.isNotEmpty || orClause != null) return all;
    } catch (e) {
      debugPrint('RPC fn_get_transactions failed, falling back to direct query: $e');
    }
    // Fallback: query payment table directly (paginated)
    try {
      final allRows = <Map<String, dynamic>>[];
      const batchSize = 1000;
      int offset = 0;
      while (true) {
        var q = fromSchema('payment').select().eq('ins_id', insId);
        if (orClause != null) q = q.or(orClause);
        final response = await q
            .order('createdat', ascending: false)
            .range(offset, offset + batchSize - 1);
        final rows = List<Map<String, dynamic>>.from(response as List);
        allRows.addAll(rows);
        if (rows.length < batchSize) break;
        offset += batchSize;
      }
      debugPrint('Payment table fallback returned ${allRows.length} records');
      return allRows;
    } catch (e) {
      debugPrint('Error fetching transactions from payment table: $e');
      return [];
    }
  }

  /// Get failed transactions (filtered from RPC)
  static Future<List<Map<String, dynamic>>> getFailedTransactions(int insId) async {
    final all = await getAllTransactions(insId);
    return all.where((t) => t['paystatus'] == 'F').toList();
  }

  /// Get paid transactions (filtered from RPC)
  static Future<List<Map<String, dynamic>>> getPaidTransactions(int insId) async {
    final all = await getAllTransactions(insId);
    return all.where((t) => t['paystatus'] == 'C').toList();
  }

  /// Captures Paytm confirmed that the database refused to receipt.
  ///
  /// Each row is money the college has received with nothing on any student's
  /// ledger against it, waiting on a person to decide: receipt it, or refund
  /// the family. The table itself is service_role only -- this reads it
  /// through list_webhook_refusals, which cannot write, so a client can see
  /// the claim but never clear it.
  ///
  /// Returns an empty list if the migration is not deployed. An older
  /// database should show no banner, not an error on a screen the counter
  /// uses all day.
  static Future<List<Map<String, dynamic>>> listWebhookRefusals(
    int insId, {
    bool includeResolved = false,
  }) async {
    try {
      final rows = await client.rpc('list_webhook_refusals', params: {
        'p_ins_id': insId,
        'p_include_resolved': includeResolved,
      });
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('list_webhook_refusals unavailable: $e');
      return [];
    }
  }

  // ==================== ROLES ====================

  /// Get active roles for an institution from custuserroles table
  static Future<List<Map<String, dynamic>>> getRoles(int insId) async {
    try {
      final response = await client
          .from('custuserroles')
          .select('ur_id, urname')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('ur_id', ascending: true);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('Error fetching roles: $e');
      return [];
    }
  }

  // ==================== DESIGNATION ====================

  static Future<List<Map<String, dynamic>>> getDesignations(int insId) async {
    try {
      final response = await client
          .from('staffdesignation')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('des_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching designations: $e');
      return [];
    }
  }

  static Future<bool> createDesignation(Map<String, dynamic> data) async {
    try {
      await savePublicRow('staffdesignation', data, pkCol: 'des_id');
      return true;
    } catch (e) {
      debugPrint('Error creating designation: $e');
      debugPrint('Designation data: $data');
      rethrow;
    }
  }

  static Future<bool> updateDesignation(int desId, Map<String, dynamic> data) async {
    try {
      await savePublicRow('staffdesignation', data, pkCol: 'des_id', pkVal: desId);
      return true;
    } catch (e) {
      debugPrint('Error updating designation: $e');
      return false;
    }
  }

  static Future<bool> deleteDesignation(int desId) async {
    try {
      await deletePublicRow('staffdesignation', 'des_id', desId);
      return true;
    } catch (e) {
      debugPrint('Error deleting designation: $e');
      return false;
    }
  }

  // ==================== USER ROLES ====================

  static Future<List<Map<String, dynamic>>> getUserRoles(int insId) async {
    try {
      final response = await client
          .from('custuserroles')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('ur_id', ascending: true);
      return List<Map<String, dynamic>>.from(response as List);
    } catch (e) {
      debugPrint('Error fetching user roles: $e');
      return [];
    }
  }

  /// Which sidebar menus each role may see, as ur_id -> {menulabel}.
  /// An absent/empty entry means the role was never configured, so callers
  /// fall back to the built-in adminOnly/accountantOnly defaults.
  static Future<Map<int, Set<String>>> getRoleMenuAccess(int insId) async {
    try {
      final res = await client
          .from('rolemenuaccess')
          .select('ur_id, menulabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final map = <int, Set<String>>{};
      for (final r in (res as List)) {
        final urId = (r['ur_id'] as num?)?.toInt();
        final label = r['menulabel']?.toString();
        if (urId == null || label == null) continue;
        map.putIfAbsent(urId, () => <String>{}).add(label);
      }
      return map;
    } catch (e) {
      // Table missing (migration not run) or offline — fall back to defaults.
      debugPrint('Error fetching role menu access: $e');
      return {};
    }
  }

  /// Replace a role's menu grants with [allowed]. Deletes then re-inserts so
  /// the stored set exactly matches what the Admin ticked.
  static Future<bool> saveRoleMenuAccess({
    required int insId,
    required int urId,
    required Set<String> allowed,
    String? createdBy,
  }) async {
    try {
      final token = sessionToken;
      if (token != null) {
        try {
          await client.rpc('save_role_menu_access', params: {
            'p_token': token,
            'p_ur_id': urId,
            'p_labels': allowed.toList(),
            'p_createdby': createdBy,
          });
          return true;
        } on PostgrestException catch (e) {
          if (!_missingRpc(e)) rethrow;
        }
      }
      await client.from('rolemenuaccess').delete().eq('ins_id', insId).eq('ur_id', urId);
      if (allowed.isNotEmpty) {
        await client.from('rolemenuaccess').insert([
          for (final label in allowed)
            {
              'ins_id': insId,
              'ur_id': urId,
              'menulabel': label,
              'createdby': createdBy,
              'activestatus': 1,
            }
        ]);
      }
      return true;
    } catch (e) {
      debugPrint('Error saving role menu access: $e');
      rethrow;
    }
  }

  static Future<bool> createUserRole(Map<String, dynamic> data) async {
    try {
      final token = sessionToken;
      if (token != null) {
        try {
          await client.rpc('save_user_role', params: {
            'p_token': token, 'p_data': data, 'p_ur_id': null,
          });
          return true;
        } on PostgrestException catch (e) {
          if (!_missingRpc(e)) rethrow;
        }
      }
      await client.from('custuserroles').insert(data);
      return true;
    } catch (e) {
      debugPrint('Error creating user role: $e');
      debugPrint('Role data: $data');
      rethrow;
    }
  }

  static Future<bool> updateUserRole(int urId, Map<String, dynamic> data) async {
    try {
      final token = sessionToken;
      if (token != null) {
        try {
          await client.rpc('save_user_role', params: {
            'p_token': token, 'p_data': data, 'p_ur_id': urId,
          });
          return true;
        } on PostgrestException catch (e) {
          if (!_missingRpc(e)) rethrow;
        }
      }
      await client.from('custuserroles').update(data).eq('ur_id', urId);
      return true;
    } catch (e) {
      debugPrint('Error updating user role: $e');
      return false;
    }
  }

  static Future<bool> deleteUserRole(int urId) async {
    try {
      final token = sessionToken;
      if (token != null) {
        try {
          await client.rpc('delete_user_role', params: {
            'p_token': token, 'p_ur_id': urId,
          });
          return true;
        } on PostgrestException catch (e) {
          if (!_missingRpc(e)) rethrow;
        }
      }
      await client.from('custuserroles').update({'activestatus': 0}).eq('ur_id', urId);
      return true;
    } catch (e) {
      debugPrint('Error deleting user role: $e');
      return false;
    }
  }
}

/// Where a collection will be banked: the fee group, its bank account and
/// that account's Paytm merchant.
///
/// Resolved by [SupabaseService.resolveRoutingTarget] with the same rule the
/// save functions apply server-side, so a counter can SHOW the destination
/// before the money is taken instead of the cashier finding out from the
/// receipt.
class FeeRouting {
  const FeeRouting({
    this.fgId,
    this.fgName = '',
    this.banId,
    this.bankName = '',
    this.paytmMid = '',
    this.hasSequence = true,
    this.mapped = false,
  });

  final int? fgId;
  final String fgName;
  final int? banId;
  final String bankName;

  /// The group has a receipt sequence (Setup -> Sequence Master -> Receipt
  /// Sequence). Without one, save_advance_collection and save_misc_collection
  /// REFUSE the collection rather than number it out of another group's run,
  /// so the counters say so before the cashier takes any money.
  final bool hasSequence;

  /// Empty when the account names no merchant — an online payment then falls
  /// back to the institution's own merchant.
  final String paytmMid;

  /// TRUE when this group was CONFIGURED for the job -- Setup -> Utilities ->
  /// Advance Settlement for an advance, or named by the fee types of an
  /// admission advance.
  ///
  /// FALSE when nothing was configured and the group was GUESSED by matching
  /// names ("the one called COLLEGE", else the lowest id). The guess is usually
  /// right, which is the problem: the counter showed "Settles into COLLEGE
  /// FEES" with the confidence of a setting nobody had made, so a wrong guess
  /// would have banked money somewhere nobody chose and nothing would have
  /// said so.
  final bool mapped;

  bool get hasBank => banId != null;
  bool get hasMerchant => paytmMid.isNotEmpty;
}

/// Outcome of [SupabaseService.resolvePaytmRouting] — which Paytm merchant an
/// online payment is created under, or why it must not be taken at all.
class PaytmRouting {
  /// Merchant the order is created under; null when [error] is set.
  final String? mid;

  /// Non-null means do not take the payment — show this to the user.
  final String? error;

  /// Where [mid] came from: 'bank:<ban_id>' when the fee group's own account
  /// named a merchant, 'institution' when it did not and the institution's
  /// default was used instead.
  final String source;

  const PaytmRouting({this.mid, this.error, this.source = ''});

  bool get ok => error == null;

  /// The money is going to the fee group's OWN account, not the institution
  /// default.
  ///
  /// Not just for the log. A group with no ban_id (or a bank with no
  /// paytm_mid) still collects -- it falls back to the institution merchant,
  /// which is right for a college with one account and wrong for one with a
  /// separate hostel account nobody mapped. It is the only path that settles
  /// somewhere without complaining, so the counter is told before the card
  /// goes in rather than after reconciliation.
  bool get routedToOwnAccount => source.startsWith('bank:');
}
