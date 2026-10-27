/// Turn a raw exception into a short, accountant-readable sentence.
///
/// Most callers do `catch (e) { showSnackBar(Text('Error: $e')); }` which
/// dumps `PostgrestException(message: new row violates row-level security
/// policy for table "payment", code: 42501, ...)` into the UI. Replace
/// those call sites with `friendlyError(e)` so the user sees an actionable
/// message instead.
String friendlyError(Object e) {
  final s = e.toString();
  final lower = s.toLowerCase();

  // Network reachability
  if (lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable')) {
    return 'Cannot reach the server. Check your internet connection and try again.';
  }
  if (lower.contains('timeoutexception') || lower.contains('timed out')) {
    return 'The server took too long to respond. Try again in a moment.';
  }

  // Supabase PostgREST
  if (lower.contains('pgrst106') || lower.contains('invalid schema')) {
    return 'This institution\'s data isn\'t exposed yet. Ask the super admin to finish schema setup.';
  }
  if (lower.contains('42501') ||
      lower.contains('row-level security') ||
      lower.contains('permission denied')) {
    return 'You don\'t have permission to perform this action.';
  }
  if (lower.contains('duplicate key') || lower.contains('23505')) {
    return 'That record already exists. Refresh and try again.';
  }
  if (lower.contains('foreign key') || lower.contains('23503')) {
    return 'This record is linked to other data and cannot be changed right now.';
  }
  // A CHECK constraint refused the row (23514). In practice that means schema
  // drift: the app can now produce a value the database has not been told to
  // accept. A mess advance was rejected for months of this session by an
  // advtype check that still read A/S only, and the cashier was shown nothing
  // but "something went wrong" -- so name the rule and point at the fix.
  if (lower.contains('23514') || lower.contains('violates check constraint')) {
    final rule =
        RegExp(r'violates check constraint "([^"]+)"').firstMatch(s)?.group(1);
    return 'The database rejected this value'
        '${rule == null ? '' : ' (rule "$rule")'}. This usually means a '
        'database update has not been run yet — ask the administrator.';
  }
  if (lower.contains('already paid') || lower.contains('p0001')) {
    // Raised by process_grouped_payment's balance guard
    final match = RegExp(r"Demand \d+ is already paid").firstMatch(s);
    if (match != null) {
      return 'One of the selected fees has already been collected by another user. Please refresh.';
    }
  }
  if (lower.contains('no schema found')) {
    return 'Institution schema is missing. Contact the super admin.';
  }

  // A deliberate RAISE EXCEPTION from one of our own functions (code P0001).
  // Those messages are written for the person at the screen -- "Roll number X
  // is already in use by another student", "Collection of X exceeds the amount
  // due" -- so passing them through is far more useful than the generic
  // fallback, which is what they used to collapse into.
  final raised = RegExp(r'message:\s*(.+?),\s*code:\s*P0001').firstMatch(s);
  if (raised != null) {
    final m = raised.group(1)!.trim();
    if (m.isNotEmpty) return m;
  }

  // The function simply isn't on this database yet — a migration that hasn't
  // been run. That collapsed into "Something went wrong, contact support",
  // which sends people hunting for a fault when the answer is to run the SQL.
  if (lower.contains('pgrst202') ||
      lower.contains('could not find the function') ||
      lower.contains('42883')) {
    return 'This feature needs a database update that has not been run yet. '
        'Ask the administrator to run the pending SQL script.';
  }

  // Storage / file issues
  if (lower.contains('bucket not found')) {
    return 'Storage bucket is missing on the server. Contact the super admin.';
  }
  if (lower.contains('payload too large') || lower.contains('413')) {
    return 'File is too large to upload. Please use a smaller file.';
  }

  // Razorpay edge function / gateway
  if (lower.contains('order_id') && lower.contains('not found')) {
    return 'Payment order not found. Start a fresh payment.';
  }

  // Fall back to a generic sentence. Don\'t dump the raw exception — it\'s
  // scary for a non-technical cashier. If they need the detail, it\'s in
  // the log.
  return 'Something went wrong. Please try again. If it keeps happening, contact support.';
}
