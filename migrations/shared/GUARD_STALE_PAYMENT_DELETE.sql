-- ============================================================================
-- Close the SECOND door into the same room.
-- ============================================================================
-- WHAT THIS IS. On 12-10-2026 create_pending_payment was taught not to delete
-- a payment row younger than 15 minutes, because "payorderid is blank" had
-- turned out to be a false proxy for "nothing can have been charged" -- that
-- is how KANNAN D's Rs 5,125 was destroyed by his own retry.
--
-- delete_stale_initiated_payments does the SAME DELETE, with the SAME test,
-- and was never guarded:
--
--     DELETE FROM <schema>.payment
--      WHERE stu_id = $1 AND paystatus = 'I'
--        AND NULLIF(btrim(payorderid), '') IS NULL
--
-- It is called by the PARENT APP -- seen on live at 13-10-2026 11:17:33, one
-- minute after a real payment went through the same screen.
--
-- HOW BIG IS THE WINDOW NOW. Smaller than it was, not closed. Since the edge
-- function was repaired, a payment that reaches the gateway is stamped within
-- about a second -- live shows insert_payment at 11:16:13 and
-- stamp_payorderid at 11:16:14. But between those two instants the row exists
-- with a blank payorderid and Paytm may already have an order open. A second
-- session calling this in that second deletes a live attempt, and the money
-- arrives with nothing to land on.
--
-- One second times every payment is not a risk worth leaving in place when
-- the fix is the same clause that is already on the other path.
--
-- WHY AGE AND NOT SOMETHING CLEVERER. 15 minutes matches
-- _sweepOrphanedPayments' own cutoff, so any row this refuses to delete is
-- one the sweep has already taken responsibility for. The two must agree, or
-- a row falls between them.
--
-- Patches the live definition in place rather than replacing it, so an
-- unrelated change to this function since cannot be silently reverted.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

DO $patch$
DECLARE
  src text;
  old_txt CONSTANT text := 'AND NULLIF(btrim(payorderid), '''''''') IS NULL';
  new_txt CONSTANT text := 'AND NULLIF(btrim(payorderid), '''''''') IS NULL '
                           'AND createdat < now() - interval ''''15 minutes''''';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
   WHERE n2.nspname = 'public' AND p.proname = 'delete_stale_initiated_payments';

  IF src IS NULL THEN
    RAISE NOTICE 'delete_stale_initiated_payments does not exist - nothing to do';
    RETURN;
  END IF;

  IF src LIKE '%15 minutes%' THEN
    RAISE NOTICE 'delete_stale_initiated_payments already guarded';
    RETURN;
  END IF;

  -- Both DELETEs carry the clause, so expect exactly two replacements. Any
  -- other count means the function is not what this was written against, and
  -- guessing at a money path is how the duplicated clause got onto live in
  -- the create_pending_payment patch.
  n := (length(src) - length(replace(src, old_txt, ''))) / length(old_txt);
  IF n <> 2 THEN
    RAISE EXCEPTION 'Expected the payorderid test twice, found % - NOT patched. '
      'The function has changed since this was written; read it before forcing.', n;
  END IF;

  src := replace(src, old_txt, new_txt);
  EXECUTE src;
  RAISE NOTICE 'patched public.delete_stale_initiated_payments (% clause(s))', n;
END
$patch$;


-- ------------------------------------------------------------- VERIFY ------
-- Both deletion paths guarded, and the guard present twice in this one --
-- once per DELETE, not once doubled up.
SELECT p.proname,
       pg_get_functiondef(p.oid) LIKE '%15 minutes%'                AS age_guarded,
       (length(pg_get_functiondef(p.oid))
        - length(replace(pg_get_functiondef(p.oid), '15 minutes', '')))
         / length('15 minutes')                                      AS guard_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('create_pending_payment', 'delete_stale_initiated_payments')
 ORDER BY 1;
