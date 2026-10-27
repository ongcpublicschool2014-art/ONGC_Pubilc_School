import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../services/supabase_service.dart';
import 'app_theme.dart';

/// Is a master row still being used, and by how many rows?
///
/// Every master delete in the app is a SOFT delete — it sets activestatus = 0
/// — and every screen filters on activestatus = 1. So deleting a master that
/// is still referenced does not fail: the row quietly disappears from the
/// dropdowns while students, demands and receipts go on pointing at it by name
/// and by id. Nothing errors; the data just stops lining up. These checks are
/// what turn that into a refusal the operator can see.
///
/// [by] is tried in order and the FIRST non-zero count wins, which is why the
/// id comes before the name: the id is the right answer, but a row imported
/// before the masters existed can carry only the name, and those are exactly
/// the rows a delete would orphan.
///
/// COUNTED, never fetched. PostgREST caps a plain select at 1000 rows, and the
/// classes this has to catch have 1,851 students in them — a select would come
/// back short and read as "safe to delete".
///
/// No activestatus filter: a student who has been issued a TC still has
/// receipts and demands pointing at their class, and a settled demand still
/// prints its fee type. "Not active" is not the same as "not referenced".
Future<int> countReferencing(String table, List<(String, Object?)> by) async {
  for (final (col, val) in by) {
    if (val == null) continue;
    final v = val is String ? val.trim() : val;
    if (v is String && v.isEmpty) continue;
    try {
      final n = await SupabaseService.fromSchema(table).count().eq(col, v);
      if (n > 0) return n;
    } catch (_) {
      // The column does not exist on this schema. That is not evidence of
      // safety, so fall through and let the other candidates answer.
    }
  }
  return 0;
}

/// Tell the operator the delete was refused, and why.
///
/// A dialog rather than a snackbar: a snackbar times out and appears at the
/// very bottom of the window, nowhere near the trash icon that was just
/// clicked. This has to be read — it carries the number of rows in the way and
/// what to do about them — so it waits for an acknowledgement.
Future<void> showMasterInUseDialog(
  BuildContext context, {
  required String name,
  required int count,
  required String noun,
  required String fix,
  /// Replaces the "is still in use by N nouns" sentence.
  ///
  /// The default wording says the count is how many rows REFERENCE this row.
  /// That is true of a master, but not of a number sequence, where the figure
  /// is the last number issued -- so that caller says it in its own words
  /// rather than have the dialog state something false.
  String? detail,
}) {
  final plural = count == 1 ? noun : '${noun}s';
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14.r)),
      titlePadding: EdgeInsets.fromLTRB(20.w, 18.h, 20.w, 0),
      contentPadding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 0),
      title: Row(children: [
        Container(
          padding: EdgeInsets.all(7.w),
          decoration: BoxDecoration(
            color: AppColors.error.withValues(alpha: 0.10),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.block, size: 18.sp, color: AppColors.error),
        ),
        SizedBox(width: 10.w),
        Expanded(
          child: Text('Cannot delete',
              style: TextStyle(
                  fontSize: 15.5.sp,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
        ),
      ]),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 380.w),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              text: TextSpan(
                style: TextStyle(
                    fontSize: 13.sp, color: AppColors.textPrimary, height: 1.5),
                children: detail != null
                    ? [
                        const TextSpan(text: '"'),
                        TextSpan(
                            text: name,
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                        const TextSpan(text: '" '),
                        TextSpan(text: detail),
                      ]
                    : [
                        const TextSpan(text: '"'),
                        TextSpan(
                            text: name,
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                        const TextSpan(text: '" is still in use by '),
                        TextSpan(
                            text: '$count $plural',
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppColors.error)),
                        const TextSpan(text: '.'),
                      ],
              ),
            ),
            SizedBox(height: 10.h),
            Text(fix,
                style: TextStyle(
                    fontSize: 12.sp,
                    color: AppColors.textSecondary,
                    height: 1.45)),
          ],
        ),
      ),
      actionsPadding: EdgeInsets.fromLTRB(12.w, 6.h, 12.w, 10.h),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('OK',
              style: TextStyle(
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent)),
        ),
      ],
    ),
  );
}
