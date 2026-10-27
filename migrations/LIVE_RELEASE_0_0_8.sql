-- ############################################################################
-- ############################################################################
--
--   EduCore360  --  LIVE RELEASE 0.0.8, 24-09-2026
--
--   ONE FILE. Run it top to bottom in the SQL editor on the LIVE project.
--
-- ############################################################################
-- ############################################################################
--
-- Everything the 0.0.8 desktop build needs from the database, in the order it
-- has to happen. Five scripts that were pending separately, assembled so they
-- cannot be run out of order or half-run.
--
-- ---------------------------------------------------------------------------
-- WHAT IS IN HERE
-- ---------------------------------------------------------------------------
-- 1. LIVE_RUN_20260919.sql
--    Everything pending since the 11 September run -- seven parts in dependency order, including three carried-forward functions.
--
-- 2. LIVE_RUN_20260921.sql
--    class.classtype (PROMOTIONAL / TERMINAL / COMPLETED) and its backfill. REQUIRED by this build: the dashboard and the Class screen read it.
--
-- 3. FIX_PAIDSTATUS_ON_APPROVAL.sql
--    Stops a demand ending up paidstatus = P while balancedue > 0 -- invisible in Fee Collection, so the student appears to owe nothing.
--
-- 4. LIVE_FIX_CLASS_NAME_MISMATCH.sql
--    Renames six master classes to the names ~228 students already carry, so those students pick up a classtype. Must follow CLASS_TYPE.
--
-- 5. LIVE_RUN_20260924.sql
--    Grants the two new report menus -- Admission Register, TC Report -- to every already-configured role.
--
--

-- ---------------------------------------------------------------------------
-- WHY THE ORDER MATTERS
-- ---------------------------------------------------------------------------
-- Part 2 adds class.classtype; part 4 renames the six classes whose students
-- would otherwise never get one. Run 4 before 2 and those ~228 students stay
-- untyped and keep falling out of the dashboard's Promotional / Terminal
-- split.
--
-- ---------------------------------------------------------------------------
-- ALL OR NOTHING
-- ---------------------------------------------------------------------------
-- The SQL editor runs this as ONE transaction. Any error anywhere rolls back
-- every part -- there is no state where three of the five have landed. It is
-- a large file; give it time rather than assuming it has hung.
--
-- SAFE TO RE-RUN. Every part was written to be: the backfills only fill NULLs,
-- the renames match on the old name, the grants are ON CONFLICT DO NOTHING.
--
-- ---------------------------------------------------------------------------
-- WHAT IT CHANGES
-- ---------------------------------------------------------------------------
--   * adds class.classtype on every year schema, and fills it
--   * clears succeedingclass on classes that do not promote
--   * renames six class-master rows (all of which hold ZERO students)
--   * fixes fn_approve_tempfeedemand so approval sets paidstatus correctly
--   * inserts rolemenuaccess rows for two new menus
--   * plus the functions carried forward from 19 September
--
-- No receipt, payment or advance row is written. The 149 student advances are
-- NOT in here -- LIVE_ADVANCE_LOAD_20260923.sql is separate, because loading
-- money is a decision about money, not about a build.
--
-- ---------------------------------------------------------------------------
-- AFTERWARDS
-- ---------------------------------------------------------------------------
-- Run this, then:   NOTIFY pgrst, 'reload schema';
-- without which PostgREST will not see the new column.
--
-- ---------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ---------------------------------------------------------------------------
-- ONE result, five rows, every one reading OK. The editor shows only the last
-- statement, so the parts' own checks are folded into that single table.
--
-- Each part was applied and checked on the TEST project first.
-- ############################################################################


-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ON THE TEST PROJECT
--
-- public._this_is_the_test_project exists on TEST and nowhere else. Checked
-- once here rather than five times; the editor runs the file as one
-- transaction, so an abort leaves the database untouched.
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NOT NULL THEN
    RAISE EXCEPTION
      'This is the TEST project -- this release is for LIVE only. Nothing was written. Switch to the live project (URL must read /project/exasnbapvgfeooxyxjas) and run it again.';
  END IF;
END $guard$;



-- ############################################################################
-- ############################################################################
--  PART 1 of 5 -- LIVE_RUN_20260919.sql
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- ############################################################################
--
--   EduCore360  --  LIVE UPDATE, 19-09-2026
--
--   ONE FILE. Run it top to bottom in the SQL editor.
--
-- ############################################################################
-- ############################################################################
--
-- -- 1. Everything pending since the 11 September live run
--    Seven parts in dependency order: the three functions carried forward
--    from 12-14 September, the Advance Collection module, the reports TC
--    filter, course transfer moving the advance, roll-number change reaching
--    everything, pre-admission (which also updates create_institution_schema
--    so NEW schemas get the column), and finally the destructive drop of the
--    Export report functions.
--
-- 2. Repair: demands whose course contradicts their own class
--    A fee demand carries both courname and stuclass; some rows disagree with
--    each other. Re-stamps courname from the course that OWNS the demand's
--    class, never from the student's current course -- that distinction is
--    what keeps a transferred student's settled money in the register it was
--    collected in. Read-only BEFORE section first; currently a no-op on TEST.
--
--
-- ---------------------------------------------------------------------------
-- BEFORE YOU START
-- ---------------------------------------------------------------------------
--
-- 1. SAFE TO RE-RUN, except the Export-report drop, and that is IF EXISTS.
--    Tables are CREATE TABLE IF NOT EXISTS, columns ADD COLUMN IF NOT EXISTS,
--    functions CREATE OR REPLACE.
--
-- 2. READ-ONLY "BEFORE" SECTIONS PRINT AS THEY RUN, and part 1's advance
--    section prints the current source of the four functions it replaces.
--    KEEP THE OUTPUT. It is what you would restore from.
--
-- 3. THE SUPABASE SQL EDITOR DOES NOT SHOW RAISE NOTICE. Several sections
--    report their counts that way, so run this in a client that shows notices
--    if you want to see them -- or use the SELECT-form checks at the end of
--    the repair section, which return rows instead.
--
-- 4. DATA IS CHANGED BY THREE REPAIR BLOCKS, all idempotent, all realigning
--    rows to the student they belong to:
--      * advances left under a class the student has left
--      * advances / misc receipts left under an old roll number
--      * demands whose course contradicts their own class
--
-- 5. THE EXPORT-REPORT DROP CANNOT BE UNDONE BY RE-RUNNING ANYTHING.
--    RUN IT ONLY AFTER THE NEW DESKTOP BUILD IS DEPLOYED -- an older copy
--    still showing the Export tab would call a function that no longer
--    exists. If the exe is not out yet, stop before it and run it later from
--    migrations/DROP_POWERCOLLEGE_EXPORT.sql.
--
-- ---------------------------------------------------------------------------
-- WHAT IS DELIBERATELY *NOT* HERE
-- ---------------------------------------------------------------------------
-- The YEAR ROLLOVER work is TEST-only and is NOT in this file: not
-- rollover_academic_year's rewrite, not rollover_preview, not the copy
-- helpers, and not students.arrearonly. It lives in
-- migrations/YEAR_ROLLOVER_TEST.sql and
-- migrations/YEAR_ROLLOVER_CREATE_SCHEMA_TEST.sql, neither of which may be run
-- on live. This file was checked for those names before it was written.
--
-- NOTE ON rollover_academic_year: it DOES appear below, but only as the
-- pre-admission patch to the EXISTING function -- the same version live has
-- been heading for since 18 September. Nothing calls it.
--
-- Every part was applied and checked on the TEST project (a full restore of
-- live) before it reached this file.
-- ############################################################################



-- ############################################################################
-- ############################################################################
--
--   PART 1 OF 2  --  Everything pending since the 11 September live run
--   source: migrations/LIVE_UPDATE_20260919.sql
--
--   Seven parts in dependency order: the three functions carried forward
--   from 12-14 September, the Advance Collection module, the reports TC
--   filter, course transfer moving the advance, roll-number change reaching
--   everything, pre-admission (which also updates create_institution_schema
--   so NEW schemas get the column), and finally the destructive drop of the
--   Export report functions.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- ############################################################################
--
--   EduCore360  --  LIVE UPDATE, 19-09-2026
--
--   ONE FILE. Run it top to bottom in the SQL editor.
--
-- ############################################################################
-- ############################################################################
--
-- It is EVERY pending migration since the 11 September live run, concatenated
-- in dependency order, byte for byte -- nothing here was rewritten for the
-- bundle, so this file and the individual files in migrations/ cannot drift
-- apart. Anything written between 12 and 17 September that a later part
-- supersedes is deliberately absent: parts 2-6 ship the newer definition of
-- those same functions.
--
--   1. Carried forward from 12-14 September         
--     Three functions written after the 11 September live run that never went
--     across in a bundle of their own: reconcile_payments_batch (SECURITY
--     DEFINER), mark_payment_notifications_read and
--     delete_stale_initiated_payments. All three are CREATE OR REPLACE, so if
--     live already has them this part is a no-op.
--
--   2. Advance Collection                           
--     The advance module itself: three tables in every institution schema,
--     collect / adjust / cancel / refund / reconcile, the Daily Collection
--     split-line fix, and the reconbalancedue fix on cash payments. Replaces
--     void_receipt, process_grouped_payment and the two daily-collection report
--     functions whole -- its PRE-FLIGHT prints what live has now.
--
--   3. Reports: leavers out, TC filter in           
--     Students holding a TC stop counting in the outstanding-dues reports, and
--     those reports gain a Without TC / TC Issued / All filter. Adds overloads
--     -- the existing function signatures keep working, so an un-updated desktop
--     copy is unaffected.
--
--   4. Course transfer moves the advance            
--     A transferred student's advance was left filed under the class they left,
--     invisible to both advance screens while money sat on it. Includes a repair
--     for rows already stranded.
--
--   5. Roll-number change reaches everything        
--     advance_collection and misc_collection were missing from the cascade, so a
--     renumbered student left rows behind under a number that names nobody.
--     Includes a repair for rows already stranded.
--
--   6. Pre-admission                                
--     Seat booked now, studies from next year: the flag, no fee demand this
--     year, no class promotion at the year change, and the unspent advance
--     carried into the new year. Its copy of get_consolidated_status_report is
--     the newest one -- it carries BOTH the TC filter from part 2 and the
--     class-strength fix, which is why this part runs after that one.
--
--   7. Drop the Export report's functions  *** DESTRUCTIVE *** 
--     The Export report is gone from the app, so its two functions have no
--     caller. THIS IS THE ONLY PART THAT DESTROYS ANYTHING -- see the warning in
--     the header.
--
--
-- ---------------------------------------------------------------------------
-- BEFORE YOU START
-- ---------------------------------------------------------------------------
--
-- 1. EVERY PART IS SAFE TO RE-RUN except part 7, and part 7 is IF EXISTS.
--    Tables are CREATE TABLE IF NOT EXISTS, columns are ADD COLUMN IF NOT
--    EXISTS, functions are CREATE OR REPLACE.
--
-- 2. PARTS 2 TO 6 PRINT A READ-ONLY "BEFORE" SECTION as they run, and part 2
--    prints the current source of the four functions it replaces. KEEP THE
--    OUTPUT. It is what you would restore from.
--
-- 3. THREE BLOCKS CHANGE DATA, all of them repairs that realign rows to the
--    student they belong to. They are idempotent and they run automatically:
--      * part 4 -- advances left under a class the student has left
--      * part 5 -- advances / misc receipts left under an old roll number
--    If you would rather inspect before repairing, run parts 1-3, then part 4
--    and part 5 by hand from their own files.
--
-- 4. PART 7 DROPS TWO FUNCTIONS and cannot be undone by re-running anything.
--    RUN PART 7 ONLY AFTER THE NEW DESKTOP BUILD IS DEPLOYED -- a copy still
--    showing the Export tab will call a function that no longer exists. If the
--    exe is not out yet, stop after part 6 and run part 7 later from
--    migrations/DROP_POWERCOLLEGE_EXPORT.sql.
--
-- 5. ORDER MATTERS in one place: part 6 ships the newest
--    get_consolidated_status_report, carrying both part 3's TC filter and its
--    own class-strength fix. Running part 3 after part 6 would undo that.
--
-- Every part was applied and checked on the TEST project (a full restore of
-- live) before it reached this file.
--
-- ############################################################################



-- ############################################################################
-- ############################################################################
--
--   PART 1 OF 7  --  Carried forward from 12-14 September
--   source: migrations/_CARRIED_FORWARD_20260914.sql
--
--   Three functions written after the 11 September live run that never went
--   across in a bundle of their own: reconcile_payments_batch (SECURITY
--   DEFINER), mark_payment_notifications_read and
--   delete_stale_initiated_payments. All three are CREATE OR REPLACE, so if
--   live already has them this part is a no-op.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- Carried forward: three functions written 12-14 September that were never
-- bundled for live. Each is CREATE OR REPLACE and independent of the rest.
-- ############################################################################

-- ---------------------------------------------------------------------------
-- source: migrations/reconcile_payments_batch_definer.sql
-- ---------------------------------------------------------------------------
-- ============================================================================
-- reconcile_payments_batch -> SECURITY DEFINER
--
-- SYMPTOM (live, 12 Sep 2026): reconciling a FEE receipt logged
--     42501  permission denied for table payment
-- four times, and the reconcile silently did nothing.
--
-- CAUSE: this function was created without SECURITY DEFINER, so it runs as the
-- CALLER -- anon. The money-table lockdown revoked INSERT/UPDATE/DELETE on
-- payment from anon, so the UPDATE inside it is refused. Its sibling
-- reconcile_misc_batch IS SECURITY DEFINER, which is why MISC receipts
-- reconciled fine while fee receipts failed.
--
-- WHY IT LOOKED FINE ON TEST: NOT the grants. Verified on test by reproducing
-- live's exact privilege state inside a rolled-back transaction: anon has no
-- UPDATE on payment there either, a direct UPDATE as anon raises 42501, and
-- this SECURITY DEFINER function then reconciled the receipt successfully.
-- The likely difference is that test's deployed function was ALREADY DEFINER
-- while complete_setup.sql carried a stale invoker-mode copy.
--
-- So on live the failure is either (a) an invoker-mode function, or (b) the
-- function being absent, with the client falling back to a direct payment
-- UPDATE that anon cannot perform. This file fixes both: it creates-or-replaces
-- the function as SECURITY DEFINER and re-grants EXECUTE.
--
-- The body below is byte-for-byte the deployed function; the ONLY change is
-- adding SECURITY DEFINER, putting it on the same footing as every other
-- money-writing RPC.
--
-- SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_payments_batch(
    p_schema        TEXT,
    p_ins_id        INT,
    p_pay_ids       INT[],
    p_user          TEXT,
    p_bank_ref      TEXT DEFAULT NULL,
    p_bank_date     TEXT DEFAULT NULL
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    updated_count INT := 0;
BEGIN
    IF p_pay_ids IS NULL OR array_length(p_pay_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    -- 1. Mark selected payments reconciled
    EXECUTE format($q$
        UPDATE %I.payment
           SET recon_status   = 'R',
               reconciled_by  = %L,
               reconciled_date = now(),
               bank_reference = COALESCE(NULLIF(%L, ''), bank_reference),
               bank_date      = COALESCE(%L::timestamp, bank_date)
         WHERE ins_id = %L
           AND pay_id = ANY (%L::INT[])
    $q$, p_schema, p_user, COALESCE(p_bank_ref, ''), p_bank_date, p_ins_id, p_pay_ids);

    GET DIAGNOSTICS updated_count = ROW_COUNT;

    -- 2. Recompute reconbalancedue for every demand touched by any of the
    --    now-reconciled payments. feedemand.pay_id is single-valued (and
    --    overwritten by the latest payment), so partial payments across two
    --    days would be missed by a pay_id-based WHERE. Use paymentdetails
    --    instead, and compute reconbalancedue as
    --      feeamount - conamount - sum(reconciled payments for this demand).
    EXECUTE format($q$
        UPDATE %1$I.feedemand fd
           SET reconbalancedue = GREATEST(
                 COALESCE(fd.feeamount, 0) - COALESCE(fd.conamount, 0) - COALESCE((
                     SELECT SUM(pd2.transtotalamount)
                     FROM %1$I.paymentdetails pd2
                     JOIN %1$I.payment p2
                       ON p2.pay_id = pd2.pay_id
                     WHERE pd2.dem_id = fd.dem_id
                       AND pd2.ins_id = %2$L
                       AND p2.paystatus = 'C'
                       AND p2.recon_status = 'R'
                 ), 0),
                 0)
         WHERE fd.ins_id = %2$L
           AND fd.dem_id IN (
               SELECT pd.dem_id
               FROM %1$I.paymentdetails pd
               WHERE pd.pay_id = ANY (%3$L::INT[])
                 AND pd.ins_id = %2$L
           )
    $q$, p_schema, p_ins_id, p_pay_ids);

    RETURN updated_count;
END $$;


GRANT EXECUTE ON FUNCTION public.reconcile_payments_batch(TEXT, INT, INT[], TEXT, TEXT, TEXT)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: expects security_definer = true
SELECT p.prosecdef AS security_definer
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'reconcile_payments_batch';

-- ---------------------------------------------------------------------------
-- source: migrations/mark_payment_notifications_read.sql
-- ---------------------------------------------------------------------------
-- ============================================================================
-- mark_payment_notifications_read -- parent app marks receipt notifications
-- as read without an UPDATE grant on payment.
--
-- WHY: payment is a money table and anon's INSERT/UPDATE/DELETE on it is
-- revoked. The parent app updated payment.notification_read directly, which
-- Postgres refused (42501 permission denied for table payment). The app
-- swallows the error, so read state never saved -- and the refusals filled
-- the Postgres log, where they looked like a Bank Reconciliation failure.
--
-- SECURITY DEFINER, but it can only set notification_read = true, and only on
-- the given student's own payments: no other column, no other student.
-- Returns the number of rows changed.
--
-- SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mark_payment_notifications_read(
  p_ins_id integer, p_stu_id bigint, p_pay_ids bigint[]
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout = '15s'
AS $$
DECLARE v text; n integer;
BEGIN
  IF p_pay_ids IS NULL OR array_length(p_pay_ids, 1) IS NULL THEN RETURN 0; END IF;
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN 0; END IF;
  -- Only the read flag, only this student's own payments.
  EXECUTE format(
    'UPDATE %I.payment SET notification_read = true '
    'WHERE stu_id = $1 AND pay_id = ANY ($2) '
    'AND notification_read IS DISTINCT FROM true', v)
  USING p_stu_id, p_pay_ids;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.mark_payment_notifications_read(integer, bigint, bigint[]) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: expects security_definer = true, anon_can_execute = true
SELECT p.prosecdef AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
       pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'mark_payment_notifications_read';

-- ---------------------------------------------------------------------------
-- source: migrations/delete_stale_initiated_payments_keep_ordered.sql
-- ---------------------------------------------------------------------------
-- ============================================================================
-- delete_stale_initiated_payments -- never delete a payment that reached Paytm.
--
-- WHY: the parent app calls this when it restores a cart left mid-payment,
-- which is exactly what a phone shows after the app closes during checkout.
-- It deleted EVERY in-progress ('I') payment for the student -- including one
-- where Paytm had already taken the money but the app died before recording
-- it. That erased the only record: no receipt, fee still due, and the
-- desktop's Paytm-aware recovery could no longer find it.
--
-- NOW: only 'I' payments with no order id are deleted (no gateway order, so
-- nothing can have been charged). Payments with an order id stay 'I' and are
-- resolved against Paytm by the sweeps.
--
-- Server-side, so it protects every installed app version immediately.
-- Same signature: CREATE OR REPLACE keeps the existing grant. SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_stale_initiated_payments(p_ins_id integer, p_stu_id bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout = '15s'
AS $$
DECLARE v text; n integer;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN 0; END IF;
  -- Only payments that never got a gateway order id: nothing can have been
  -- charged. One WITH an order id may have been paid, so it stays 'I' for the
  -- Paytm-aware sweeps to complete or fail -- deleting it lost the record.
  EXECUTE format('DELETE FROM %I.paymentdetails WHERE pay_id IN '
                 '(SELECT pay_id FROM %I.payment WHERE stu_id=$1 AND paystatus=''I'' '
                 'AND NULLIF(btrim(payorderid), '''') IS NULL)', v, v)
    USING p_stu_id;
  EXECUTE format('WITH d AS (DELETE FROM %I.payment WHERE stu_id=$1 AND paystatus=''I'' '
                 'AND NULLIF(btrim(payorderid), '''') IS NULL RETURNING 1) '
                 'SELECT count(*) FROM d', v)
    INTO n USING p_stu_id;
  RETURN n;
END; $$;

GRANT EXECUTE ON FUNCTION public.delete_stale_initiated_payments(integer, bigint) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: expects keeps_ordered_payments = true
SELECT position('payorderid' in p.prosrc) > 0 AS keeps_ordered_payments
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'delete_stale_initiated_payments';



-- ############################################################################
-- ############################################################################
--
--   PART 2 OF 7  --  Advance Collection
--   source: migrations/LIVE_UPDATE_20260918.sql
--
--   The advance module itself: three tables in every institution schema,
--   collect / adjust / cancel / refund / reconcile, the Daily Collection
--   split-line fix, and the reconbalancedue fix on cash payments. Replaces
--   void_receipt, process_grouped_payment and the two daily-collection report
--   functions whole -- its PRE-FLIGHT prints what live has now.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- EduCore360 -- LIVE UPDATE, 18-09-2026
--
-- One file, run top to bottom in the SQL editor. It carries every database
-- change made since the last live update, in dependency order:
--
--   1. ADVANCE_COLLECTION_SETUP.sql           Advance Collection module: the three tables in every institution schema, plus save_advance_collection() and adjust_advance().
--   2. ADVANCE_CANCEL_REFUND.sql              Cancel / refund an advance, and let void_receipt cancel an advance-adjustment receipt (it replaces public.
--   3. ADVANCE_BANK_RECON.sql                 reconcile_advance_batch(): a non-cash advance settles in Bank Reconciliation.
--   4. FIX_DAILY_FEETYPE_SPLIT_LINES.sql      Daily Collection: a fee settled in two pieces on one receipt no longer loses a piece (replaces the two report functions).
--   5. fix_reconbalancedue_cash_payment.sql   A cash payment no longer wipes OTHER pending payments off reconbalancedue (replaces process_grouped_payment).
--
-- ALL OF IT IS SAFE TO RE-RUN. Every table is CREATE TABLE IF NOT EXISTS and
-- every function is CREATE OR REPLACE. No row is inserted, updated or deleted
-- anywhere: this file changes structure and code only.
--
-- Applied and exercised on the TEST project first (a full restore of live,
-- 18-09-2026), including advance collection, adjustment, cancel, refund, bank
-- reconciliation and a Paytm payment through the staging gateway.
--
-- ---------------------------------------------------------------------------
-- FOUR FUNCTIONS ARE REPLACED WHOLE, NOT JUST ADDED:
--     public.void_receipt
--     public.process_grouped_payment
--     public.get_daily_collection_report
--     public.get_daily_collection_unreconciled
-- Their bodies here come from C:\pg_backups\complete_setup.sql with one
-- deliberate change each. If live has drifted from that file, this overwrites
-- the drift. The PRE-FLIGHT section below prints what live has RIGHT NOW --
-- run it first and keep the output, so there is something to compare against
-- and to restore from.
-- ---------------------------------------------------------------------------
--
-- AFTER RUNNING, two things are configuration rather than schema, so they are
-- deliberately NOT in this file:
--   * A numbering sequence for advances (Fee Master -> Advance No). A STUDENT
--     advance refuses without it. An ADMISSION advance does not need one -- it
--     draws from the payment sequence, like a fee receipt.
--   * A numbering sequence for refunds (Fee Master -> Refund No), if this
--     institution has never raised one.
-- The last query in this file reports whether they exist.
-- ############################################################################


-- ############################################################################
-- PRE-FLIGHT (READ-ONLY) -- run this section on its own first and SAVE the
-- output. It is the current definition of everything this file replaces.
-- ############################################################################
SELECT p.proname,
       pg_get_functiondef(p.oid) AS current_definition_on_this_database
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('void_receipt', 'process_grouped_payment',
                     'get_daily_collection_report', 'get_daily_collection_unreconciled')
 ORDER BY p.proname;



-- ############################################################################
-- PART 1 of 5 -- ADVANCE_COLLECTION_SETUP.sql
--
-- Advance Collection module: the three tables in every institution schema, plus save_advance_collection() and adjust_advance().
-- ############################################################################

-- ============================================================================
-- ADVANCE COLLECTION -- complete setup. RUN THIS WHOLE FILE, TOP TO BOTTOM.
-- RUN IT ON TEST FIRST. It changes money tables.
--
-- Creates, in EVERY institution schema:
--   advance_collection   money taken from a STUDENT before any fee is due.
--                        Mirrors payment's money/reconcile columns but carries
--                        no fg_id / fee_id on the header. balanceamount is
--                        GENERATED (taken - adjusted - refunded), so it cannot
--                        drift from its parts.
--   advance_detail       fee-type breakdown of an ADMISSION advance.
--   advadjustment        one row per amount moved off an advance onto a fee
--                        demand, with the receipt that settlement raised.
--
-- TWO KINDS OF ADVANCE, told apart by advance_collection.advtype:
--   'A'  ADMISSION advance -- collected BY FEE TYPE. The receipt carries a
--        breakdown (TUITION 10,000 / BUS 4,000 / ...) in advance_detail and the
--        header total is always the sum of those lines.
--   'S'  STUDENT advance -- a plain amount, no breakdown.
-- Both are held against the student the same way and spent the same way.
--
-- and, in public:
--   save_advance_collection(p_token, p_header, p_lines)  take an advance
--   adjust_advance(p_token, p_adv_id, p_lines, p_by, p_pay_id)
--                                                        spend it on demands.
--     With p_pay_id it ATTACHES to the cash receipt the cashier just raised --
--     one receipt, one sequence number, total = cash + advance. Without it the
--     advance covered everything and it raises its own receipt.
--
-- BEFORE THE FIRST ADVANCE CAN BE TAKEN: open Fee Master -> Advance No and
-- save a sequence (e.g. prefix AD26/ width 5, start 1). Nothing is seeded here
-- -- save_advance_collection refuses with a clear message rather than inventing
-- a receipt number. Same pattern as Concession No and Refund No.
--
-- IDEMPOTENT throughout (IF NOT EXISTS / ADD COLUMN IF NOT EXISTS / CREATE OR
-- REPLACE) -- safe to re-run, including on a schema that already has the first
-- cut of these tables. It creates no data.
--
-- RE-RUN THIS ON TEST even though the first cut is already applied there. It
-- carries three changes made since:
--   1. advtype + advance_detail (the two kinds of advance above).
--   2. paytm_txnid on the header, so a Paytm advance records the gateway's own
--      transaction id apart from our order id -- the same split
--      misc_collection uses.
--   3. save_advance_collection sets recon_status the way save_misc_collection
--      does: cash is 'R' (realised on the spot -- no bank line will ever match
--      it), everything else 'P'. It used to hardcode 'P', which parked every
--      cash advance in Bank Reconciliation forever.
-- The 2-argument save_advance_collection is DROPPED and replaced by the
-- 3-argument one; leaving both would give PostgREST two overloads to choose
-- between.
-- ============================================================================

DO $adv$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'payment')
       AND nspname NOT IN ('public','information_schema')
       AND nspname NOT LIKE 'pg\_%'
  LOOP
    -- ---- header: the advance receipt -------------------------------------
    EXECUTE format($t$
      CREATE TABLE IF NOT EXISTS %I.advance_collection (
        adv_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        ins_id            integer NOT NULL,
        inscode           varchar(10),
        stu_id            bigint NOT NULL,
        stuadmno          varchar(25),
        stuname           varchar(50),
        stuclass          varchar(20),
        courname          varchar(20),
        yr_id             integer,
        yrlabel           varchar(20),
        advno             varchar(30) NOT NULL,
        advdate           timestamp DEFAULT now() NOT NULL,
        -- 'A' admission advance (itemised in advance_detail), 'S' student
        -- advance (amount only).
        advtype           char(1) DEFAULT 'S' NOT NULL
                            CHECK (advtype = ANY(ARRAY['A','S'])),
        transtotalamount  numeric(12,2) NOT NULL CHECK (transtotalamount > 0),
        adjustedamount    numeric(12,2) DEFAULT 0 NOT NULL,
        refund_amount     numeric(12,2) DEFAULT 0 NOT NULL,
        -- always exactly what is left; cannot drift from its parts
        balanceamount     numeric(12,2) GENERATED ALWAYS AS
                            (transtotalamount - adjustedamount - refund_amount) STORED,
        transcurrency     varchar(20) DEFAULT 'INR' NOT NULL,
        paystatus         char(1) DEFAULT 'C' NOT NULL
                            CHECK (paystatus = ANY(ARRAY['I','C','F','R'])),
        paymethod         varchar(60),
        payreference      varchar(100),
        payorderid        varchar(100),
        -- Paytm's own transaction id, kept apart from payreference (which
        -- holds OUR order id), exactly as misc_collection.paytm_txnid does.
        paytm_txnid       varchar(60),
        paychequeno       varchar(50),
        paychequedate     date,
        paybankname       varchar(100),
        ban_id            integer,
        recon_status      char(1) DEFAULT 'P',
        reconciled_by     varchar(50),
        reconciled_date   timestamp,
        bank_reference    varchar(100),
        bank_date         date,
        tender_amount     numeric(12,2),
        remarks           varchar(255),
        createdby         varchar(50),
        createdat         timestamp DEFAULT now() NOT NULL,
        voidedby          varchar(100),
        voideddate        timestamp,
        voidreason        varchar(255),
        activestatus      smallint DEFAULT 1 NOT NULL
      )$t$, s);

    -- Schemas that got the FIRST cut of this table (no advtype / paytm_txnid)
    -- are brought up to date here rather than by a second migration file.
    EXECUTE format($t$
      ALTER TABLE %I.advance_collection
        ADD COLUMN IF NOT EXISTS advtype     char(1) DEFAULT 'S' NOT NULL,
        ADD COLUMN IF NOT EXISTS paytm_txnid varchar(60)$t$, s);
    EXECUTE format('ALTER TABLE %I.advance_collection DROP CONSTRAINT IF EXISTS chk_advance_advtype', s);
    EXECUTE format($t$ALTER TABLE %I.advance_collection
      ADD CONSTRAINT chk_advance_advtype CHECK (advtype = ANY(ARRAY['A','S']))$t$, s);

    -- One advance receipt number per institution.
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS uq_advance_advno ON %I.advance_collection (ins_id, advno)', s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advance_stu ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1', s);
    -- Drives "students with an unused advance" (the Fee Collection highlight).
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advance_open ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1 AND balanceamount > 0', s);

    -- ---- detail: what an ADMISSION advance was taken for -----------------
    -- Mirrors misc_collection_detail. feetype is varchar(60), not misc's 30:
    -- real fee names run long (DUPLICATE TRANSFER CERTIFICATE is 29) and there
    -- is no reason to inherit a limit that is one rename away from failing.
    EXECUTE format($t$
      CREATE TABLE IF NOT EXISTS %I.advance_detail (
        advd_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        adv_id        bigint NOT NULL,
        ins_id        integer NOT NULL,
        fee_id        integer,
        fg_id         integer,
        feetype       varchar(60) NOT NULL,
        amount        numeric(12,2) NOT NULL DEFAULT 0,
        activestatus  smallint DEFAULT 1 NOT NULL
      )$t$, s);
    EXECUTE format('ALTER TABLE %I.advance_detail DROP CONSTRAINT IF EXISTS fk_advance_detail_advance', s);
    EXECUTE format('ALTER TABLE %I.advance_detail ADD CONSTRAINT fk_advance_detail_advance FOREIGN KEY (adv_id) REFERENCES %I.advance_collection(adv_id)', s, s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advance_detail_adv ON %I.advance_detail (adv_id)', s);

    -- ---- child: what the advance was applied to --------------------------
    EXECUTE format($t$
      CREATE TABLE IF NOT EXISTS %I.advadjustment (
        adj_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        adv_id         bigint NOT NULL,
        ins_id         integer NOT NULL,
        stu_id         bigint,
        dem_id         bigint,
        -- the fee receipt raised when the adjustment settled the demand
        pay_id         bigint,
        paynumber      varchar(30),
        demfeeterm     varchar(20),
        demfeetype     varchar(30),
        adjustamount   numeric(12,2) NOT NULL CHECK (adjustamount > 0),
        adjustdate     date DEFAULT CURRENT_DATE NOT NULL,
        remarks        varchar(255),
        createdby      varchar(50),
        createdat      timestamp DEFAULT now() NOT NULL,
        activestatus   smallint DEFAULT 1 NOT NULL
      )$t$, s);

    EXECUTE format('ALTER TABLE %I.advadjustment DROP CONSTRAINT IF EXISTS fk_advadjustment_advance', s);
    EXECUTE format('ALTER TABLE %I.advadjustment ADD CONSTRAINT fk_advadjustment_advance FOREIGN KEY (adv_id) REFERENCES %I.advance_collection(adv_id)', s, s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advadjustment_adv ON %I.advadjustment (adv_id)', s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advadjustment_dem ON %I.advadjustment (ins_id, dem_id)', s);

    -- ---- money-table lockdown (same posture as payment/feedemand) --------
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.advance_collection, %I.advance_detail, %I.advadjustment FROM anon', s, s, s);
    EXECUTE format('GRANT SELECT ON %I.advance_collection, %I.advance_detail, %I.advadjustment TO anon, authenticated', s, s, s);

    RAISE NOTICE 'advance_collection + advance_detail + advadjustment ready in %', s;
  END LOOP;
END
$adv$;


-- ============================================================================
-- save_advance_collection — take an advance and issue its receipt.
--
-- ins_id comes from the session, never the client. The receipt number is drawn
-- from the ADVNO sequence row under FOR UPDATE, so two counters cannot take the
-- same number.
--
-- p_lines is the fee-type breakdown, REQUIRED for an admission advance
-- (advtype 'A') and ignored for a student advance (advtype 'S'):
--   [{"fee_id":18,"fg_id":2,"feetype":"TUITION FEE","amount":10000}, …]
--
-- The 2-argument version is dropped first: adding p_lines with a DEFAULT would
-- otherwise leave two overloads that PostgREST can resolve either way.
-- ============================================================================
DROP FUNCTION IF EXISTS public.save_advance_collection(text, jsonb);

CREATE OR REPLACE FUNCTION public.save_advance_collection(
  p_token text, p_header jsonb, p_lines jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10);
  v_yr_id integer; v_yrlabel varchar(20);
  v_seq_id int; v_cur numeric; v_width int; v_prefix text; v_advno text;
  v_adv_id bigint; v_amount numeric;
  v_paymode text; v_recon char(1);
  v_advtype char(1); v_lines_total numeric; v_line_count integer := 0;
  v_fg_id integer;
  itm RECORD;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_advtype := UPPER(COALESCE(NULLIF(p_header->>'advtype',''), 'S'));
  IF v_advtype NOT IN ('A','S') THEN
    RAISE EXCEPTION 'Advance type must be A (admission) or S (student)';
  END IF;

  v_amount := COALESCE((p_header->>'transtotalamount')::numeric, 0);

  IF v_advtype = 'A' THEN
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
      RAISE EXCEPTION 'An admission advance needs at least one fee type line';
    END IF;
    SELECT COALESCE(SUM((l->>'amount')::numeric), 0)
      INTO v_lines_total FROM jsonb_array_elements(p_lines) l;
    IF v_lines_total <= 0 THEN
      RAISE EXCEPTION 'The fee type amounts must add up to more than zero';
    END IF;
    -- The header total IS the sum of the lines. Taking the client's figure
    -- would let a receipt and its own breakdown tell different stories.
    v_amount := v_lines_total;
  ELSIF v_amount <= 0 THEN
    RAISE EXCEPTION 'Advance amount must be greater than zero';
  END IF;

  -- Same rule as save_misc_collection: cash never goes to reconciliation --
  -- there is no bank line to match it to, so it is realised the moment it is
  -- taken. Everything else waits for the bank. Hardcoding 'P' parked every
  -- cash advance in Bank Reconciliation forever.
  v_paymode := LOWER(COALESCE(NULLIF(p_header->>'paymethod',''), 'Cash'));
  v_recon   := CASE WHEN v_paymode LIKE '%cash%' THEN 'R' ELSE 'P' END;

  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;

  -- Year resolved server-side, like the other collection RPCs.
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v_ins;

  -- Receipt number. The two types draw from DIFFERENT series.
  --
  --   'A' ADMISSION advance -> the PAYMENT sequence, the same series a fee
  --       receipt comes from (Fee Master -> Payment Sequence). It is collected
  --       fee type by fee type against an admission and later comes off the
  --       bill itself, so what the family is handed reads as a fee receipt. The
  --       fee group comes from the FIRST line, exactly as a collection numbers
  --       its receipt per fee group.
  --
  --   'S' STUDENT advance -> ADVNO (Fee Master -> Advance No), its own series:
  --       money HELD against the student rather than a fee paid, spent later
  --       through an adjustment.
  IF v_advtype = 'A' THEN
    v_fg_id := NULLIF(p_lines->0->>'fg_id', '')::integer;
    IF v_fg_id IS NULL THEN
      -- Older client, or a line saved without its group: resolve it from the
      -- fee type the way adjust_advance does.
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                       WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
        INTO v_fg_id USING (p_lines->0->>'feetype');
    END IF;

    IF v_fg_id IS NOT NULL THEN
      EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                             COALESCE(NULLIF(seqprefix,''''),
                                      regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                        FROM %I.sequence
                       WHERE ins_id=$1 AND fg_id=$2 AND activestatus=1
                       ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins, v_fg_id;
    END IF;
    -- A fee type whose group has no sequence of its own must not cost the
    -- cashier the collection: fall back to the institution's first payment
    -- sequence, which is the only one most colleges have.
    IF v_seq_id IS NULL THEN
      EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                             COALESCE(NULLIF(seqprefix,''''),
                                      regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                        FROM %I.sequence
                       WHERE ins_id=$1 AND fg_id IS NOT NULL AND activestatus=1
                       ORDER BY fg_id, seq_id LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins;
    END IF;
    IF v_seq_id IS NULL THEN
      RAISE EXCEPTION 'No payment sequence configured. Add one in Fee Master → Payment Sequence first.';
    END IF;
  ELSE
    EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5), COALESCE(seqprefix,'''')
                      FROM %I.sequence
                     WHERE ins_id=$1 AND actname=''ADVNO'' AND activestatus=1
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins;
    IF v_seq_id IS NULL THEN
      RAISE EXCEPTION 'No Advance No sequence configured. Add one in Fee Master → Advance No first.';
    END IF;
  END IF;
  v_cur := v_cur + 1;
  v_advno := v_prefix || lpad(v_cur::bigint::text, v_width, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;

  EXECUTE format($i$
    INSERT INTO %I.advance_collection
      (ins_id, inscode, stu_id, stuadmno, stuname, stuclass, courname, yr_id, yrlabel,
       advno, advdate, advtype, transtotalamount, paystatus, paymethod, payreference,
       payorderid, paytm_txnid, paychequeno, paychequedate, paybankname, ban_id,
       tender_amount, remarks, createdby, recon_status)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,
            $10, COALESCE($11::timestamp, now()), $12, $13, 'C', $14, $15,
            $16, $17, $18, $19, $20, $21,
            $22, $23, $24, $25)
    RETURNING adv_id$i$, v_schema)
  INTO v_adv_id
  USING v_ins, v_inscode,
        (p_header->>'stu_id')::bigint, p_header->>'stuadmno', p_header->>'stuname',
        p_header->>'stuclass', p_header->>'courname', v_yr_id, v_yrlabel,
        v_advno, NULLIF(p_header->>'advdate','')::timestamp, v_advtype, v_amount,
        p_header->>'paymethod', p_header->>'payreference',
        p_header->>'payorderid', p_header->>'paytm_txnid',
        p_header->>'paychequeno', NULLIF(p_header->>'paychequedate','')::date,
        p_header->>'paybankname', NULLIF(p_header->>'ban_id','')::integer,
        NULLIF(p_header->>'tender_amount','')::numeric, p_header->>'remarks',
        p_header->>'createdby', v_recon;

  -- Fee-type breakdown: admission advances only.
  IF v_advtype = 'A' THEN
    FOR itm IN
      SELECT NULLIF(l->>'fee_id','')::integer  AS fee_id,
             NULLIF(l->>'fg_id','')::integer   AS fg_id,
             l->>'feetype'                     AS feetype,
             COALESCE((l->>'amount')::numeric, 0) AS amount
        FROM jsonb_array_elements(p_lines) l
    LOOP
      CONTINUE WHEN itm.amount <= 0 OR COALESCE(trim(itm.feetype), '') = '';
      EXECUTE format('INSERT INTO %I.advance_detail (adv_id, ins_id, fee_id, fg_id, feetype, amount)
                      VALUES ($1,$2,$3,$4,$5,$6)', v_schema)
        USING v_adv_id, v_ins, itm.fee_id, itm.fg_id, itm.feetype, itm.amount;
      v_line_count := v_line_count + 1;
    END LOOP;
    IF v_line_count = 0 THEN
      RAISE EXCEPTION 'An admission advance needs at least one fee type line with an amount';
    END IF;
  END IF;

  RETURN jsonb_build_object('adv_id', v_adv_id, 'advno', v_advno, 'amount', v_amount,
                            'advtype', v_advtype, 'lines', v_line_count,
                            'recon_status', v_recon);
END; $$;

GRANT EXECUTE ON FUNCTION public.save_advance_collection(text, jsonb, jsonb) TO anon, authenticated;


-- Advance Collection — stage 2: adjust_advance().
--
-- Applies part (or all) of a student's advance to specific fee demands. The
-- demand is settled exactly as a counter collection settles it, and a real fee
-- receipt is raised, so the student ledger, receipt reprint and DCB all behave
-- normally.
--
-- MIRRORS complete_payment_grouped: receipts are grouped per FEE GROUP (a
-- receipt number comes from that group's sequence), each demand row is locked
-- FOR UPDATE before it is touched, and the amount can never exceed what is
-- owed (balance + fine).
--
-- TWO KINDS OF ADVANCE, and they do DIFFERENT THINGS to the demand.
--
--   'S' STUDENT advance -- money held against a student already studying. It
--     PAYS the demand: paidamount goes up, balancedue comes down, exactly as a
--     counter collection does.
--
--   'A' ADMISSION advance -- taken from a student admitted for NEXT year, so
--     there is no bill to settle when it is collected. It does NOT pay the
--     demand; it REDUCES IT. feeamount comes down by the amount applied (and
--     balancedue with it, since balance is feeamount less concession less paid)
--     while paidamount is left alone -- the student is billed net of what they
--     already handed over at admission. feedemand.pay_id is deliberately NOT
--     stamped either: this receipt did not pay the demand.
--
--   Both are chosen manually by the cashier, both draw the advance down and
--     both are recorded in advadjustment. Only the STUDENT advance produces a
--     RECEIPT: it settles a demand the way money does. An admission advance
--     reduces a bill, so there is nothing to give a receipt for -- and a
--     receipt would show up in Daily Collection as a collection that never
--     happened, only to be netted straight back out again. Its advadjustment
--     rows therefore carry pay_id / paynumber NULL.
--
-- TWO MODES.
--
--   p_pay_id GIVEN  -- the normal counter case. The cashier is collecting the
--     rest in cash, so the payment row ALREADY EXISTS. The advance attaches to
--     it: its lines become paymentdetails on that receipt and its amount is
--     added to payment.transtotalamount, so ONE receipt shows the whole
--     settlement (cash + advance) and one number is drawn from the sequence.
--
--   p_pay_id NULL   -- the advance covers everything, so no cash receipt
--     exists. For a STUDENT advance a receipt is raised per fee group, as
--     below. For an ADMISSION advance no payment row is written at all: the
--     demand is reduced and the advadjustment row is the only record.
--
-- EITHER WAY advadjustment records the amount against the receipt's pay_id, so
-- a REPRINT can show the advance long after the screen state is gone.
--
-- NO NEW BANK MONEY MOVES HERE. The cash arrived when the advance was taken.
-- With p_pay_id the receipt keeps the cashier's own paymethod; standalone it is
-- written with:
--     paymethod    = 'Advance Adjustment'
--     payreference = the advance number (AD26/00001)
--     recon_status = 'R'
-- Reconciliation is marked done because no bank line will ever arrive for it —
-- leaving it 'P' would park it in Bank Reconciliation forever. `paymethod`
-- is what the collection reports must exclude so the money is not counted
-- twice (once as the advance, once as this receipt).
--
-- Everything happens in ONE transaction: if any line fails, no demand is
-- touched, no receipt is raised and the advance is untouched.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). Run on TEST first.
-- ============================================================================

-- Dropped first: adding a defaulted argument makes a NEW signature, and two
-- overloads would leave PostgREST free to pick either one.
DROP FUNCTION IF EXISTS public.adjust_advance(text, bigint, jsonb, text);

CREATE OR REPLACE FUNCTION public.adjust_advance(
  p_token text, p_adv_id bigint, p_lines jsonb, p_created_by text DEFAULT NULL,
  p_pay_id bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text;
  v_adv RECORD; v_total numeric := 0;
  v_fg_ids integer[] := '{}'; v_fg_id integer; v_item_fg integer;
  v_pay_id bigint; v_paynumber text; v_group_total numeric;
  v_seq RECORD; v_new_no integer;
  v_cur_paid numeric; v_cur_bal numeric; v_cur_fine numeric;
  v_stu_id bigint; v_term text; v_type text;
  itm RECORD; v_result jsonb := '[]'::jsonb;
  v_attach boolean := p_pay_id IS NOT NULL;
  v_pay RECORD;
  v_advtype char(1);
  v_adv_reconciled boolean;
  v_cur_fee numeric; v_cap numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Nothing to adjust';
  END IF;

  -- Lock the advance: two counters cannot spend the same balance.
  EXECUTE format('SELECT adv_id, ins_id, stu_id, advno, balanceamount, paystatus, activestatus,
                         inscode, yr_id, yrlabel, createdby, COALESCE(advtype, ''S'') AS advtype,
                         COALESCE(recon_status, ''P'') AS recon_status
                    FROM %I.advance_collection
                   WHERE adv_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
    INTO v_adv USING p_adv_id, v_ins;
  IF v_adv.adv_id IS NULL THEN RAISE EXCEPTION 'Advance % not found', p_adv_id; END IF;
  IF v_adv.activestatus <> 1 OR v_adv.paystatus <> 'C' THEN
    RAISE EXCEPTION 'Advance % is cancelled or not collected', v_adv.advno;
  END IF;
  v_advtype := COALESCE(v_adv.advtype, 'S');
  -- Was the advance's own money confirmed by the bank? Cash is, at once;
  -- a cheque is not until it clears. It decides whether settling a demand from
  -- this advance may also bring reconbalancedue down -- see the student branch.
  v_adv_reconciled := (COALESCE(v_adv.recon_status, 'P') = 'R');

  SELECT COALESCE(SUM((l->>'amount')::numeric), 0) INTO v_total
    FROM jsonb_array_elements(p_lines) l;
  IF v_total <= 0 THEN RAISE EXCEPTION 'Adjustment amount must be greater than zero'; END IF;
  IF v_total > v_adv.balanceamount + 0.005 THEN
    RAISE EXCEPTION 'Adjusting % exceeds the advance balance of % on %',
      v_total, v_adv.balanceamount, v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  -- ---- ATTACH MODE -------------------------------------------------------
  -- Settle every line onto the receipt the cashier just raised, instead of
  -- raising another one.
  IF v_attach THEN
    EXECUTE format('SELECT pay_id, paynumber, stu_id, paystatus, activestatus
                      FROM %I.payment WHERE pay_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
      INTO v_pay USING p_pay_id, v_ins;
    IF v_pay.pay_id IS NULL THEN
      RAISE EXCEPTION 'Receipt % not found', p_pay_id;
    END IF;
    IF COALESCE(v_pay.activestatus, 1) = 9 OR v_pay.paystatus <> 'C' THEN
      RAISE EXCEPTION 'Receipt % is cancelled or incomplete', p_pay_id USING ERRCODE = 'P0001';
    END IF;
    -- The advance and the receipt must belong to the same student, or an
    -- advance could be spent on somebody else's fees.
    IF v_pay.stu_id <> v_adv.stu_id THEN
      RAISE EXCEPTION 'Receipt % belongs to another student', p_pay_id USING ERRCODE = 'P0001';
    END IF;

    v_pay_id := v_pay.pay_id;
    v_paynumber := v_pay.paynumber;

    FOR itm IN SELECT (l->>'dem_id')::bigint AS dem_id, (l->>'amount')::numeric AS amount
                 FROM jsonb_array_elements(p_lines) l
    LOOP
      EXECUTE format('SELECT demfeeterm, demfeetype FROM %I.feedemand WHERE dem_id = $1', v_schema)
        INTO v_term, v_type USING itm.dem_id;

      -- Same lock and guards a counter collection uses.
      EXECUTE format('SELECT paidamount, balancedue, fineamount FROM %I.feedemand
                       WHERE dem_id = $1 AND activestatus = 1 FOR UPDATE', v_schema)
        INTO v_cur_paid, v_cur_bal, v_cur_fine USING itm.dem_id;
      IF COALESCE(v_cur_bal, 0) <= 0 THEN
        RAISE EXCEPTION 'Demand % is already paid. Please refresh.', itm.dem_id USING ERRCODE = 'P0001';
      END IF;
      -- An ADMISSION advance reduces the bill, so it can never take feeamount
      -- below what has already been paid on it -- that would leave a demand
      -- owing a negative amount. The balance is exactly that headroom, and a
      -- fine is NOT part of it: a fine is not something a reduced bill erases.
      IF v_advtype = 'A' THEN
        v_cap := COALESCE(v_cur_bal, 0);
        IF itm.amount > v_cap + 0.005 THEN
          RAISE EXCEPTION 'Reducing demand % by % exceeds the % still billed on it.',
            itm.dem_id, itm.amount, v_cap USING ERRCODE = 'P0001';
        END IF;
      ELSIF itm.amount > COALESCE(v_cur_bal,0) + COALESCE(v_cur_fine,0) + 0.005 THEN
        RAISE EXCEPTION 'Adjusting % on demand % exceeds the amount due (balance % + fine %).',
          itm.amount, itm.dem_id, COALESCE(v_cur_bal,0), COALESCE(v_cur_fine,0) USING ERRCODE = 'P0001';
      END IF;

      EXECUTE format('INSERT INTO %I.paymentdetails
                        (pay_id, dem_id, yr_id, yrlabel, ins_id, transcurrency, transtotalamount)
                      VALUES ($1,$2,$3,$4,$5,''INR'',$6)', v_schema)
        USING v_pay_id, itm.dem_id, v_adv.yr_id, v_adv.yrlabel, v_ins, itm.amount;

      IF v_advtype = 'A' THEN
        -- ADMISSION advance: bill the student LESS, do not record a payment.
        -- feeamount carries the reduction; balancedue and reconbalancedue
        -- follow it; paidamount and pay_id are untouched, because no money
        -- moved against this demand today.
        EXECUTE format('UPDATE %I.feedemand
                          SET feeamount        = GREATEST(COALESCE(feeamount,0) - $1, 0),
                              balancedue       = GREATEST(COALESCE(balancedue,0) - $1, 0),
                              reconbalancedue  = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                              paidstatus       = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0
                                                      THEN ''P'' ELSE ''U'' END
                        WHERE dem_id = $2 AND activestatus = 1', v_schema)
          USING itm.amount, itm.dem_id;
      ELSE
        -- STUDENT advance: settles the demand exactly as cash would.
        --
        -- reconbalancedue comes down WITH the balance, but only when the
        -- advance's own money is already confirmed. That figure means "owed
        -- after reconciliation", and an advance taken in cash was banked the
        -- day it was received -- leaving it alone reported the fee as still
        -- outstanding after it had been settled (a 65,000 demand with 500 left
        -- showed 35,500 owed). An advance still waiting on a cheque has not
        -- been confirmed, so it stays up until the bank says so.
        IF v_adv_reconciled THEN
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount      = COALESCE(paidamount,0) + $1,
                                balancedue      = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                reconbalancedue = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                                paidstatus      = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id          = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        ELSE
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount = COALESCE(paidamount,0) + $1,
                                balancedue = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                paidstatus = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id     = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        END IF;
      END IF;

      EXECUTE format('INSERT INTO %I.advadjustment
                        (adv_id, ins_id, stu_id, dem_id, pay_id, paynumber,
                         demfeeterm, demfeetype, adjustamount, createdby)
                      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)', v_schema)
        USING p_adv_id, v_ins, v_adv.stu_id, itm.dem_id, v_pay_id, v_paynumber,
              v_term, v_type, itm.amount, COALESCE(p_created_by, v_adv.createdby);
    END LOOP;

    -- The receipt now settles cash AND advance, so its total says so.
    EXECUTE format('UPDATE %I.payment SET transtotalamount = COALESCE(transtotalamount,0) + $1
                     WHERE pay_id = $2', v_schema)
      USING v_total, p_pay_id;

    EXECUTE format('UPDATE %I.advance_collection
                      SET adjustedamount = COALESCE(adjustedamount,0) + $1
                    WHERE adv_id = $2', v_schema)
      USING v_total, p_adv_id;

    RETURN jsonb_build_object(
      'advno', v_adv.advno, 'adjusted', v_total, 'attached_to', v_paynumber,
      'receipts', jsonb_build_array(jsonb_build_object(
        'pay_id', v_pay_id, 'paynumber', v_paynumber, 'amount', v_total)));
  END IF;

  -- ---- STANDALONE MODE ---------------------------------------------------
  -- Which fee groups are involved (one receipt per group, like a collection).
  FOR itm IN SELECT (l->>'dem_id')::bigint AS dem_id, (l->>'amount')::numeric AS amount
               FROM jsonb_array_elements(p_lines) l
  LOOP
    IF itm.amount IS NULL OR itm.amount <= 0 THEN
      RAISE EXCEPTION 'Each line must carry an amount greater than zero';
    END IF;
    -- The demand must belong to the SAME student as the advance.
    EXECUTE format('SELECT stu_id, demfeeterm, demfeetype FROM %I.feedemand
                     WHERE dem_id = $1 AND ins_id = $2 AND activestatus = 1', v_schema)
      INTO v_stu_id, v_term, v_type USING itm.dem_id, v_ins;
    IF v_stu_id IS NULL THEN RAISE EXCEPTION 'Demand % not found', itm.dem_id; END IF;
    IF v_stu_id <> v_adv.stu_id THEN
      RAISE EXCEPTION 'Demand % belongs to another student', itm.dem_id USING ERRCODE = 'P0001';
    END IF;

    EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
      INTO v_item_fg USING v_type;
    v_item_fg := COALESCE(v_item_fg, 0);
    IF NOT (v_item_fg = ANY(v_fg_ids)) THEN v_fg_ids := v_fg_ids || v_item_fg; END IF;
  END LOOP;

  -- One receipt per fee group -- for a STUDENT advance.
  FOREACH v_fg_id IN ARRAY v_fg_ids LOOP
    v_group_total := 0;
    v_pay_id := NULL;
    v_paynumber := NULL;

    -- An ADMISSION advance raises NO receipt and draws NO receipt number. It
    -- reduces what the student is billed; no money changes hands today, so
    -- there is nothing to receipt -- and a receipt would appear in Daily
    -- Collection as a collection that never happened, to be netted straight
    -- back out again. A STUDENT advance settles a demand the way cash does, so
    -- it gets the receipt, the sequence number and the paymentdetails lines.
    IF v_advtype <> 'A' THEN
      EXECUTE format($p$
        INSERT INTO %I.payment
          (ins_id, inscode, stu_id, yr_id, yrlabel, transtotalamount, transcurrency,
           paydate, paystatus, paymethod, payreference, createdby, recon_status, activestatus)
        VALUES ($1,$2,$3,$4,$5,0,'INR', now(), 'C', 'Advance Adjustment', $6, $7, $8, 1)
        RETURNING pay_id$p$, v_schema)
      INTO v_pay_id
      USING v_ins, v_adv.inscode, v_adv.stu_id, v_adv.yr_id, v_adv.yrlabel,
            v_adv.advno, COALESCE(p_created_by, v_adv.createdby),
            -- Mirrors the ADVANCE, rather than always claiming 'R'. No bank
            -- line will ever arrive for this receipt, but if the advance behind
            -- it is still waiting on one, neither is this money.
            CASE WHEN v_adv_reconciled THEN 'R' ELSE 'P' END;

      -- Receipt number from that fee group's sequence (same rule as a collection).
      v_seq := NULL;
      EXECUTE format('SELECT seq_id, sequid, seqwidth, seqcurno FROM %I.sequence
                       WHERE ins_id = $1 AND fg_id = $2 LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq USING v_ins, v_fg_id;
      IF v_seq IS NULL THEN
        v_paynumber := 'ADJ' || v_pay_id;
      ELSE
        v_new_no := v_seq.seqcurno + 1;
        v_paynumber := regexp_replace(v_seq.sequid, '\d+$', '') || lpad(v_new_no::text, v_seq.seqwidth::integer, '0');
        EXECUTE format('UPDATE %I.sequence SET seqcurno = $1 WHERE seq_id = $2', v_schema)
          USING v_new_no, v_seq.seq_id;
      END IF;
      EXECUTE format('UPDATE %I.payment SET paynumber = $1 WHERE pay_id = $2', v_schema)
        USING v_paynumber, v_pay_id;
    END IF;

    FOR itm IN SELECT (l->>'dem_id')::bigint AS dem_id, (l->>'amount')::numeric AS amount
                 FROM jsonb_array_elements(p_lines) l
    LOOP
      EXECUTE format('SELECT demfeeterm, demfeetype FROM %I.feedemand WHERE dem_id = $1', v_schema)
        INTO v_term, v_type USING itm.dem_id;
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
        INTO v_item_fg USING v_type;
      CONTINUE WHEN COALESCE(v_item_fg, 0) <> v_fg_id;

      -- Lock and guard the demand exactly as a counter collection does.
      EXECUTE format('SELECT paidamount, balancedue, fineamount FROM %I.feedemand
                       WHERE dem_id = $1 AND activestatus = 1 FOR UPDATE', v_schema)
        INTO v_cur_paid, v_cur_bal, v_cur_fine USING itm.dem_id;
      IF COALESCE(v_cur_bal, 0) <= 0 THEN
        RAISE EXCEPTION 'Demand % is already paid. Please refresh.', itm.dem_id USING ERRCODE = 'P0001';
      END IF;
      -- An ADMISSION advance reduces the bill, so it can never take feeamount
      -- below what has already been paid on it -- that would leave a demand
      -- owing a negative amount. The balance is exactly that headroom, and a
      -- fine is NOT part of it: a fine is not something a reduced bill erases.
      IF v_advtype = 'A' THEN
        v_cap := COALESCE(v_cur_bal, 0);
        IF itm.amount > v_cap + 0.005 THEN
          RAISE EXCEPTION 'Reducing demand % by % exceeds the % still billed on it.',
            itm.dem_id, itm.amount, v_cap USING ERRCODE = 'P0001';
        END IF;
      ELSIF itm.amount > COALESCE(v_cur_bal,0) + COALESCE(v_cur_fine,0) + 0.005 THEN
        RAISE EXCEPTION 'Adjusting % on demand % exceeds the amount due (balance % + fine %).',
          itm.amount, itm.dem_id, COALESCE(v_cur_bal,0), COALESCE(v_cur_fine,0) USING ERRCODE = 'P0001';
      END IF;

      -- Only when there IS a receipt. A paymentdetails row with no payment
      -- behind it is an orphan every receipt and ledger query would trip over.
      IF v_pay_id IS NOT NULL THEN
        EXECUTE format('INSERT INTO %I.paymentdetails
                          (pay_id, dem_id, yr_id, yrlabel, ins_id, transcurrency, transtotalamount)
                        VALUES ($1,$2,$3,$4,$5,''INR'',$6)', v_schema)
          USING v_pay_id, itm.dem_id, v_adv.yr_id, v_adv.yrlabel, v_ins, itm.amount;
      END IF;

      IF v_advtype = 'A' THEN
        -- ADMISSION advance: bill the student LESS, do not record a payment.
        -- feeamount carries the reduction; balancedue and reconbalancedue
        -- follow it; paidamount and pay_id are untouched, because no money
        -- moved against this demand today.
        EXECUTE format('UPDATE %I.feedemand
                          SET feeamount        = GREATEST(COALESCE(feeamount,0) - $1, 0),
                              balancedue       = GREATEST(COALESCE(balancedue,0) - $1, 0),
                              reconbalancedue  = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                              paidstatus       = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0
                                                      THEN ''P'' ELSE ''U'' END
                        WHERE dem_id = $2 AND activestatus = 1', v_schema)
          USING itm.amount, itm.dem_id;
      ELSE
        -- STUDENT advance: settles the demand exactly as cash would.
        --
        -- reconbalancedue comes down WITH the balance, but only when the
        -- advance's own money is already confirmed. That figure means "owed
        -- after reconciliation", and an advance taken in cash was banked the
        -- day it was received -- leaving it alone reported the fee as still
        -- outstanding after it had been settled (a 65,000 demand with 500 left
        -- showed 35,500 owed). An advance still waiting on a cheque has not
        -- been confirmed, so it stays up until the bank says so.
        IF v_adv_reconciled THEN
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount      = COALESCE(paidamount,0) + $1,
                                balancedue      = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                reconbalancedue = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                                paidstatus      = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id          = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        ELSE
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount = COALESCE(paidamount,0) + $1,
                                balancedue = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                paidstatus = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id     = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        END IF;
      END IF;

      EXECUTE format('INSERT INTO %I.advadjustment
                        (adv_id, ins_id, stu_id, dem_id, pay_id, paynumber,
                         demfeeterm, demfeetype, adjustamount, createdby)
                      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)', v_schema)
        USING p_adv_id, v_ins, v_adv.stu_id, itm.dem_id, v_pay_id, v_paynumber,
              v_term, v_type, itm.amount, COALESCE(p_created_by, v_adv.createdby);

      v_group_total := v_group_total + itm.amount;
    END LOOP;

    IF v_pay_id IS NOT NULL THEN
      EXECUTE format('UPDATE %I.payment SET transtotalamount = $1 WHERE pay_id = $2', v_schema)
        USING v_group_total, v_pay_id;

      -- 'receipts' stays EMPTY for an admission advance, and the app reads it:
      -- no receipt number is quoted to the cashier because none exists.
      v_result := v_result || jsonb_build_object(
        'pay_id', v_pay_id, 'paynumber', v_paynumber, 'fg_id', v_fg_id, 'amount', v_group_total);
    END IF;
  END LOOP;

  -- Finally draw the advance down. balanceamount is generated, so it follows.
  EXECUTE format('UPDATE %I.advance_collection
                    SET adjustedamount = COALESCE(adjustedamount,0) + $1
                  WHERE adv_id = $2', v_schema)
    USING v_total, p_adv_id;

  RETURN jsonb_build_object('advno', v_adv.advno, 'adjusted', v_total, 'receipts', v_result);
END; $$;

GRANT EXECUTE ON FUNCTION public.adjust_advance(text, bigint, jsonb, text, bigint) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- every row below should read as described.
-- ============================================================================

-- 1. All three tables exist in every institution schema.
SELECT table_schema, table_name
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection','advance_detail','advadjustment')
 ORDER BY table_schema, table_name;

-- 2. Both RPCs are SECURITY DEFINER and callable by anon. save_advance_collection
--    must show THREE arguments (p_token text, p_header jsonb, p_lines jsonb)
--    and appear exactly ONCE -- a second, 2-argument row means the DROP did not
--    take and PostgREST has an ambiguous overload.
SELECT p.proname,
       p.prosecdef                                      AS security_definer,   -- expect t
       has_function_privilege('anon', p.oid, 'EXECUTE')  AS anon_can_execute,   -- expect t
       pg_get_function_identity_arguments(p.oid)         AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('save_advance_collection','adjust_advance')
 ORDER BY p.proname, args;

-- 3. anon can READ the money tables but NOT write them.
SELECT table_schema, table_name,
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'SELECT') AS anon_select,              -- expect t
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'INSERT') AS anon_insert_expect_false, -- expect f
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'UPDATE') AS anon_update_expect_false, -- expect f
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'DELETE') AS anon_delete_expect_false  -- expect f
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection','advance_detail','advadjustment')
 ORDER BY table_schema, table_name;

-- 4. Does the Advance No sequence exist yet? "No ADVNO sequence anywhere yet"
--    is normal on a fresh install -- create it in Fee Master -> Advance No
--    before collecting. Walks every schema, so it needs no schema name.
DO $chk$
DECLARE s text; r record; found boolean := false;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'sequence')
       AND nspname NOT IN ('public','information_schema')
       AND nspname NOT LIKE 'pg\_%'
  LOOP
    FOR r IN EXECUTE format(
      'SELECT ins_id, seqprefix, seqwidth, seqcurno,
              seqprefix || lpad((seqcurno + 1)::bigint::text, seqwidth::int, ''0'') AS next_advno
         FROM %I.sequence WHERE actname = ''ADVNO'' AND activestatus = 1', s)
    LOOP
      found := true;
      RAISE NOTICE 'ADVNO in %: ins_id=% prefix=% width=% current=% -> next receipt %',
        s, r.ins_id, r.seqprefix, r.seqwidth, r.seqcurno, r.next_advno;
    END LOOP;
  END LOOP;
  IF NOT found THEN
    RAISE NOTICE 'No ADVNO sequence anywhere yet -- create one in Fee Master -> Advance No.';
  END IF;
END
$chk$;


-- ############################################################################
-- PART 2 of 5 -- ADVANCE_CANCEL_REFUND.sql
--
-- Cancel / refund an advance, and let void_receipt cancel an advance-adjustment receipt (it replaces public.void_receipt -- see the PRE-FLIGHT note).
-- ############################################################################

-- ============================================================================
-- Advance Collection -- stage 3: CANCEL and REFUND an advance receipt.
--
-- An advance is money in hand like any other receipt, so the two screens that
-- undo money must reach it:
--
--   Fee Cancel Receipt  ->  void_advance_receipt()
--   Fee Refund          ->  refund_advance()
--
-- WHY TWO VERBS, AND WHEN EACH ONE IS RIGHT
--   CANCEL is for a receipt that should never have existed -- wrong student,
--   wrong amount, keyed twice. The advance is struck out whole. It is refused
--   once ANY of it has been applied to a fee, because a demand has already been
--   settled or reduced on the strength of it: reverse that first, from Fee
--   Cancel Receipt (a student advance's adjustment receipt) or by collecting
--   the fee again (an admission advance's reduction).
--
--   REFUND is for money the institution is giving back -- the student left, or
--   took an advance they no longer need. The receipt stays valid and what was
--   already spent on fees stays spent; only the UNUSED balance goes back.
--
-- BANK PROTECTION, same rule the fee and misc voids use: a non-cash receipt the
-- bank has already confirmed (recon_status 'R') cannot be cancelled behind the
-- statement's back. Cash never reconciles, so it stays cancellable.
--
-- BALANCE, never recomputed by hand. advance_collection.balanceamount is
--     transtotalamount - adjustedamount - refund_amount
-- as a generated column, so a refund only has to add to refund_amount and the
-- balance follows. Nothing can drift.
--
-- The refund voucher is an ordinary fee_refund row, so the existing refund
-- register lists it beside every other refund:
--     pay_id     NULL      -- an advance is not a payment row
--     paynumber  AD26/...  -- the advance receipt it came off
--     one fee_refunddetails line, dem_id NULL, refundfeetype 'ADVANCE'
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================


-- ============================================================================
-- void_advance_receipt(p_token, p_adv_id, p_user, p_reason)
--
-- Session-gated: ins_id and the schema come from the token, never from the
-- caller, so one institution cannot cancel another's receipt.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.void_advance_receipt(
  p_token text, p_adv_id bigint, p_user text DEFAULT NULL, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_adv RECORD; v_is_cash boolean;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- Locked: a cancel and an adjustment must not cross.
  EXECUTE format('SELECT adv_id, advno, advtype, transtotalamount, adjustedamount,
                         refund_amount, balanceamount, paymethod, paystatus,
                         COALESCE(recon_status, ''P'') AS recon_status, activestatus
                    FROM %I.advance_collection
                   WHERE adv_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
    INTO v_adv USING p_adv_id, v_ins;

  IF v_adv.adv_id IS NULL THEN
    RAISE EXCEPTION 'Advance receipt % not found', p_adv_id;
  END IF;
  IF v_adv.activestatus <> 1 OR v_adv.paystatus = 'R' THEN
    RAISE EXCEPTION 'Advance % is already cancelled', v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  -- Already spent on fees: the demand it touched has to be put back first.
  IF COALESCE(v_adv.adjustedamount, 0) > 0.005 THEN
    RAISE EXCEPTION 'Advance % has % already applied to fees. Reverse the adjustment before cancelling it.',
      v_adv.advno, to_char(v_adv.adjustedamount, 'FM99,99,99,990.00') USING ERRCODE = 'P0001';
  END IF;
  -- Partly given back already: cancelling would erase the record of a refund
  -- that actually happened.
  IF COALESCE(v_adv.refund_amount, 0) > 0.005 THEN
    RAISE EXCEPTION 'Advance % has % already refunded and cannot be cancelled.',
      v_adv.advno, to_char(v_adv.refund_amount, 'FM99,99,99,990.00') USING ERRCODE = 'P0001';
  END IF;

  v_is_cash := LOWER(COALESCE(v_adv.paymethod, '')) LIKE '%cash%';
  IF v_adv.recon_status = 'R' AND NOT v_is_cash THEN
    RAISE EXCEPTION 'Advance % is reconciled with the bank and cannot be cancelled',
      v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('UPDATE %I.advance_collection
                     SET paystatus    = ''R'',
                         activestatus = 9,
                         voidedby     = $1,
                         voideddate   = now(),
                         voidreason   = $2
                   WHERE adv_id = $3 AND ins_id = $4', v_schema)
    USING p_user, NULLIF(p_reason, ''), p_adv_id, v_ins;

  -- The fee-type breakdown goes with it, so a cancelled advance cannot turn up
  -- in the Advance Adjustment screen's HELD column.
  EXECUTE format('UPDATE %I.advance_detail SET activestatus = 9 WHERE adv_id = $1', v_schema)
    USING p_adv_id;

  RETURN jsonb_build_object(
    'adv_id', v_adv.adv_id, 'advno', v_adv.advno,
    'amount', v_adv.transtotalamount, 'cancelled', true);
END; $$;

GRANT EXECUTE ON FUNCTION public.void_advance_receipt(text, bigint, text, text) TO anon, authenticated;


-- ============================================================================
-- refund_advance(p_token, p_header)
--
-- p_header: adv_id, amount, refundmode, refunddate, refundreason,
--           ban_id, bankname, bankref, chequedate, accountcode, createdby
--
-- Returns the voucher: {rf_id, doc_no, advno, refunded, balance_left}.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refund_advance(
  p_token text, p_header jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_adv RECORD;
  v_amount numeric; v_rf_id bigint;
  v_seq_id integer; v_num integer; v_scur numeric; v_sstart numeric;
  v_prefix text; v_width int; v_docno text;
  v_yrid integer; v_yrlabel text; v_left numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_amount := ROUND(COALESCE((p_header->>'amount')::numeric, 0), 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Refund amount must be greater than zero' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT adv_id, advno, advtype, inscode, stu_id, stuadmno, stuname,
                         stuclass, yr_id, yrlabel, transtotalamount, adjustedamount,
                         refund_amount, balanceamount, paystatus, activestatus
                    FROM %I.advance_collection
                   WHERE adv_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
    INTO v_adv USING (p_header->>'adv_id')::bigint, v_ins;

  IF v_adv.adv_id IS NULL THEN
    RAISE EXCEPTION 'Advance receipt % not found', p_header->>'adv_id';
  END IF;
  IF v_adv.activestatus <> 1 OR v_adv.paystatus = 'R' THEN
    RAISE EXCEPTION 'Advance % is cancelled', v_adv.advno USING ERRCODE = 'P0001';
  END IF;
  -- Only the UNUSED balance can go back: what has already settled a fee is not
  -- the institution's to return twice.
  IF v_amount > COALESCE(v_adv.balanceamount, 0) + 0.005 THEN
    RAISE EXCEPTION 'Refunding % exceeds the % still unused on advance %.',
      to_char(v_amount, 'FM99,99,99,990.00'),
      to_char(COALESCE(v_adv.balanceamount, 0), 'FM99,99,99,990.00'),
      v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  -- Active academic year, resolved server-side like process_refund does.
  BEGIN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id = $1 AND activestatus = 1
                     ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_yrid, v_yrlabel USING v_ins;
  EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
  END;

  -- doc_no from the REFNO sequence, drawn FOR UPDATE, exactly as a fee refund
  -- does -- so advance refunds and fee refunds share one voucher series.
  EXECUTE format('SELECT seq_id, seqstart, seqcurno, seqprefix, seqwidth FROM %I.sequence
                   WHERE ins_id = $1 AND actname = ''REFNO'' AND activestatus = 1
                   ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_sstart, v_scur, v_prefix, v_width USING v_ins;
  IF v_seq_id IS NOT NULL THEN
    v_num := (CASE WHEN COALESCE(v_scur, 0) < COALESCE(v_sstart, 1)
                   THEN COALESCE(v_sstart, 1) ELSE v_scur + 1 END)::integer;
    v_docno := COALESCE(v_prefix, '') || LPAD(v_num::text, COALESCE(v_width, 5)::int, '0');
    EXECUTE format('UPDATE %I.sequence SET seqcurno = $1 WHERE seq_id = $2', v_schema)
      USING v_num, v_seq_id;
  ELSE
    v_docno := NULLIF(p_header->>'doc_no', '');
  END IF;
  IF v_docno IS NULL THEN
    RAISE EXCEPTION 'No Refund No sequence configured. Add a REFNO sequence in Fee Master first.'
      USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format(
    'INSERT INTO %I.fee_refund(doc_no,ins_id,inscode,yr_id,yrlabel,refunddate,pay_id,paynumber,
                               stu_id,stuadmno,stuname,stuclass,refundmode,ban_id,bankname,bankref,
                               chequedate,accountcode,refundreason,totalrefund,totaladjust,
                               createdby,activestatus)
     VALUES($1,$2,$3,$4,$5,COALESCE(NULLIF($6,'''')::date, CURRENT_DATE),NULL,$7,
            $8,$9,$10,$11,$12,$13,$14,$15,
            NULLIF($16,'''')::date,$17,$18,$19,0,
            $20,1) RETURNING rf_id', v_schema)
  INTO v_rf_id USING
    v_docno, v_ins, v_adv.inscode, COALESCE(v_adv.yr_id, v_yrid),
    COALESCE(NULLIF(v_adv.yrlabel, ''), v_yrlabel),
    p_header->>'refunddate', v_adv.advno,
    v_adv.stu_id, v_adv.stuadmno, v_adv.stuname, v_adv.stuclass,
    COALESCE(NULLIF(p_header->>'refundmode', ''), 'Cash'),
    NULLIF(p_header->>'ban_id', '')::integer,
    p_header->>'bankname', p_header->>'bankref', p_header->>'chequedate',
    p_header->>'accountcode', p_header->>'refundreason',
    v_amount, p_header->>'createdby';

  -- dem_id NULL: an advance is not owed against any one demand. The line still
  -- names what it was, so the refund register reads the same as every other.
  EXECUTE format(
    'INSERT INTO %I.fee_refunddetails(rf_id,dem_id,ins_id,refundterm,refundfeetype,
                                      feeamount,refundamount,adjustamount,activestatus)
     VALUES($1,NULL,$2,''Advance'',''ADVANCE'',$3,$4,0,1)', v_schema)
    USING v_rf_id, v_ins, v_adv.transtotalamount, v_amount;

  -- balanceamount is generated from this, so the advance's remaining balance
  -- follows on its own.
  EXECUTE format('UPDATE %I.advance_collection
                     SET refund_amount = COALESCE(refund_amount, 0) + $1
                   WHERE adv_id = $2 AND ins_id = $3', v_schema)
    USING v_amount, v_adv.adv_id, v_ins;

  EXECUTE format('SELECT balanceamount FROM %I.advance_collection WHERE adv_id = $1', v_schema)
    INTO v_left USING v_adv.adv_id;

  RETURN jsonb_build_object(
    'rf_id', v_rf_id, 'doc_no', v_docno, 'advno', v_adv.advno,
    'refunded', v_amount, 'balance_left', v_left);
END; $$;

GRANT EXECUTE ON FUNCTION public.refund_advance(text, jsonb) TO anon, authenticated;


-- ============================================================================
-- void_receipt_with_advance(p_token, p_pay_id, p_user, p_reason)
--
-- Cancelling a fee receipt that an ADVANCE helped settle. void_receipt on its
-- own puts the demand back but leaves the advance showing the money as spent,
-- so the student would lose it: the fee is owed again AND the advance is gone.
-- This wrapper does both halves in one transaction --
--
--   1. void_receipt()  -- restores every demand, voids the payment for audit
--   2. hands the advance's share back: advance_collection.adjustedamount comes
--      down by what this receipt took, so balanceamount (generated) rises again
--   3. deactivates the advadjustment rows, so nothing is netted off twice in
--      Daily Collection or the dashboard
--
-- A receipt with no advance behind it behaves exactly as void_receipt does.
--
-- REFUSED for an ADMISSION advance. That adjustment reduced feeamount rather
-- than paying it, so void_receipt's reversal (paidamount down, balance up) is
-- the wrong shape entirely -- it would bill the student for money they handed
-- over at admission. Legacy receipts only: the current adjust_advance raises no
-- receipt for an admission advance at all.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.void_receipt_with_advance(
  p_token text, p_pay_id bigint, p_user text DEFAULT NULL, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_res jsonb;
  v_total numeric := 0; v_admission integer := 0; r RECORD;
  v_pm text; v_rs text; v_host_restores boolean;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- No advance module on this database: an ordinary void is all there is to do.
  IF to_regclass(format('%I.advadjustment', v_schema)) IS NULL THEN
    RETURN COALESCE(public.void_receipt(v_ins, p_pay_id, p_user, p_reason), '{}'::jsonb);
  END IF;

  EXECUTE format('SELECT count(*)
                    FROM %I.advadjustment aj
                    JOIN %I.advance_collection a ON a.adv_id = aj.adv_id
                   WHERE aj.pay_id = $1 AND aj.ins_id = $2 AND aj.activestatus = 1
                     AND COALESCE(a.advtype, ''S'') = ''A''', v_schema, v_schema)
    INTO v_admission USING p_pay_id, v_ins;
  IF v_admission > 0 THEN
    RAISE EXCEPTION 'This receipt carries an ADMISSION advance, which reduced the fee rather than paying it. Cancelling it here would bill the student twice -- reverse it from the Advance side instead.'
      USING ERRCODE = 'P0001';
  END IF;

  -- Will void_receipt put reconbalancedue back on our behalf? It does that for
  -- cash and for a cleared advance-adjustment receipt. When the advance rode on
  -- a cheque or UPI receipt instead, it will not -- and the advance's own share
  -- DID come off reconbalancedue when it was applied, so this has to restore it.
  EXECUTE format('SELECT LOWER(COALESCE(paymethod, '''')), COALESCE(recon_status, ''P'')
                    FROM %I.payment WHERE pay_id = $1 AND ins_id = $2', v_schema)
    INTO v_pm, v_rs USING p_pay_id, v_ins;
  v_host_restores := (v_pm = 'cash') OR (v_pm = 'advance adjustment' AND v_rs = 'R');

  -- Demands first: if this refuses (reconciled receipt, already void), nothing
  -- has been handed back to any advance.
  v_res := public.void_receipt(v_ins, p_pay_id, p_user, p_reason);

  IF NOT v_host_restores THEN
    FOR r IN EXECUTE format('SELECT aj.dem_id, SUM(aj.adjustamount) AS amt
                               FROM %I.advadjustment aj
                               JOIN %I.advance_collection a ON a.adv_id = aj.adv_id
                              WHERE aj.pay_id = $1 AND aj.ins_id = $2 AND aj.activestatus = 1
                                AND COALESCE(a.recon_status, ''P'') = ''R''
                              GROUP BY aj.dem_id', v_schema, v_schema)
             USING p_pay_id, v_ins
    LOOP
      EXECUTE format('UPDATE %I.feedemand
                         SET reconbalancedue = COALESCE(reconbalancedue, 0) + $1
                       WHERE dem_id = $2 AND ins_id = $3', v_schema)
        USING r.amt, r.dem_id, v_ins;
    END LOOP;
  END IF;

  FOR r IN EXECUTE format('SELECT adv_id, SUM(adjustamount) AS amt
                             FROM %I.advadjustment
                            WHERE pay_id = $1 AND ins_id = $2 AND activestatus = 1
                            GROUP BY adv_id', v_schema)
           USING p_pay_id, v_ins
  LOOP
    EXECUTE format('UPDATE %I.advance_collection
                       SET adjustedamount = GREATEST(COALESCE(adjustedamount, 0) - $1, 0)
                     WHERE adv_id = $2 AND ins_id = $3', v_schema)
      USING r.amt, r.adv_id, v_ins;
    v_total := v_total + COALESCE(r.amt, 0);
  END LOOP;

  EXECUTE format('UPDATE %I.advadjustment SET activestatus = 9
                   WHERE pay_id = $1 AND ins_id = $2 AND activestatus = 1', v_schema)
    USING p_pay_id, v_ins;

  RETURN COALESCE(v_res, '{}'::jsonb)
         || jsonb_build_object('returned_to_advance', v_total);
END; $$;

GRANT EXECUTE ON FUNCTION public.void_receipt_with_advance(text, bigint, text, text) TO anon, authenticated;



-- ============================================================================
-- void_receipt -- an ADVANCE ADJUSTMENT receipt is not a bank-matched receipt.
--
-- adjust_advance writes its receipt with recon_status 'R' because no bank line
-- will ever arrive for it: the money was banked when the advance was taken.
-- void_receipt read that 'R' as "the bank has confirmed this" and refused to
-- cancel it, so an advance applied to the wrong fee could not be undone at all.
--
-- Two named conditions replace the single cash test:
--   v_no_bank_leg    -- paymethod 'Advance Adjustment'; never protect it
--   v_restore_recon  -- did this receipt actually reduce reconbalancedue when
--                       it was taken? Cash always did; an advance adjustment
--                       did when the advance behind it had cleared
--
-- Everything else is reproduced verbatim from complete_setup.sql so nothing
-- else drifts. SAFE TO RE-RUN. No data is touched.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.void_receipt(p_ins_id integer, p_pay_id bigint, p_user text, p_reason text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
DECLARE
  v text; p RECORD; d RECORD; v_is_cash boolean;
  v_no_bank_leg boolean; v_restore_recon boolean;
  v_fee numeric; v_con numeric; v_paid numeric; v_bal numeric; v_recon numeric;
  v_newpaid numeric; v_newbal numeric; v_delta numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found for ins_id %', p_ins_id; END IF;

  -- Lock the receipt row so a concurrent void/reconcile serialises.
  EXECUTE format('SELECT pay_id, paymethod, recon_status, activestatus, paynumber FROM %I.payment WHERE pay_id=$1 AND ins_id=$2 FOR UPDATE', v)
    INTO p USING p_pay_id, p_ins_id;
  IF p.pay_id IS NULL THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0001';
  END IF;
  IF p.activestatus = 9 THEN
    RAISE EXCEPTION 'Receipt is already deleted' USING ERRCODE = 'P0001';
  END IF;

  v_is_cash := LOWER(COALESCE(p.paymethod, '')) = 'cash';
  -- An 'Advance Adjustment' receipt has NO BANK LEG. The money was banked when
  -- the advance was taken; adjust_advance marks the receipt reconciled for that
  -- reason alone, not because a statement line matched it. Treating that as
  -- bank-matched made such a receipt impossible to cancel at all -- the one
  -- receipt a cashier most often needs to undo, because it is how an advance is
  -- applied to the wrong fee.
  v_no_bank_leg := LOWER(COALESCE(p.paymethod, '')) = 'advance adjustment';
  -- Protect genuinely bank-matched (non-cash reconciled) receipts.
  IF p.recon_status = 'R' AND NOT v_is_cash AND NOT v_no_bank_leg THEN
    RAISE EXCEPTION 'Receipt % is reconciled with the bank and cannot be deleted', p.paynumber USING ERRCODE = 'P0001';
  END IF;
  -- Whether reconbalancedue must be put back is a separate question: it was
  -- only ever reduced by a receipt that counted as reconciled when it was
  -- taken. Cash always did; an advance adjustment did if the advance behind it
  -- had cleared.
  v_restore_recon := v_is_cash OR (v_no_bank_leg AND p.recon_status = 'R');

  -- Restore every demand this receipt settled. Cash also reduced
  -- reconbalancedue at collection, so add that back too; non-cash pending
  -- receipts never touched reconbalancedue.
  FOR d IN EXECUTE format('SELECT dem_id, transtotalamount FROM %I.paymentdetails WHERE pay_id=$1 AND activestatus=1', v) USING p_pay_id LOOP
    -- Take the receipt's money back off the demand, then RECOMPUTE the balance
    -- from the invariant the rest of the system uses (feeamount - conamount -
    -- paidamount) rather than adding the receipt amount back on. Incrementing
    -- is right only when the demand was not over-collected: voiding one of two
    -- duplicate receipts (fee 300, paid 600, balance 0) has to leave the demand
    -- settled at 300/300, and bal + amount would re-bill a student who is
    -- square. It also gets fines right -- a receipt carries balance + fine, so
    -- adding the whole receipt back over-billed by the fine.
    -- paidstatus now follows the recomputed balance instead of being forced to
    -- 'U': another receipt may still cover this demand in full.
    EXECUTE format('SELECT feeamount, conamount, paidamount, balancedue, reconbalancedue FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2 FOR UPDATE', v)
      INTO v_fee, v_con, v_paid, v_bal, v_recon USING d.dem_id, p_ins_id;
    CONTINUE WHEN v_fee IS NULL;
    v_newpaid := GREATEST(COALESCE(v_paid,0) - d.transtotalamount, 0);
    v_newbal  := GREATEST(COALESCE(v_fee,0) - COALESCE(v_con,0) - v_newpaid, 0);
    v_delta   := v_newbal - COALESCE(v_bal,0);
    IF v_restore_recon THEN
      -- Cash also reduced reconbalancedue at collection, so move it back by
      -- however much the balance actually moved. An advance adjustment did the
      -- same, for the same reason.
      EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, reconbalancedue=$3, paidstatus=$4, pay_id=NULL WHERE dem_id=$5 AND ins_id=$6', v)
        USING v_newpaid, v_newbal, GREATEST(COALESCE(v_recon, v_bal, 0) + v_delta, 0),
              CASE WHEN v_newbal > 0 THEN 'U' ELSE 'P' END, d.dem_id, p_ins_id;
    ELSE
      EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, paidstatus=$3, pay_id=NULL WHERE dem_id=$4 AND ins_id=$5', v)
        USING v_newpaid, v_newbal, CASE WHEN v_newbal > 0 THEN 'U' ELSE 'P' END, d.dem_id, p_ins_id;
    END IF;
  END LOOP;

  -- Soft-void: keep the payment for audit, deactivate its details.
  EXECUTE format('UPDATE %I.paymentdetails SET activestatus=9 WHERE pay_id=$1', v) USING p_pay_id;
  EXECUTE format('UPDATE %I.payment SET activestatus=9, paystatus=''R'', voidedby=$1, voideddate=now(), voidreason=$2 WHERE pay_id=$3', v)
    USING p_user, NULLIF(TRIM(COALESCE(p_reason, '')), ''), p_pay_id;

  RETURN jsonb_build_object('voided', p_pay_id, 'paynumber', p.paynumber);
END; $_$;
GRANT EXECUTE ON FUNCTION public.void_receipt(integer, bigint, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect four rows, every flag t (advance_adjustment_cancellable
-- is meaningful only on void_receipt; the other three read f).
-- ============================================================================
SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
       pg_get_function_identity_arguments(p.oid)        AS args,
       p.prosrc LIKE '%v_no_bank_leg%'                  AS advance_adjustment_cancellable
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('void_advance_receipt', 'refund_advance',
                     'void_receipt_with_advance', 'void_receipt')
 ORDER BY p.proname;


-- ############################################################################
-- PART 3 of 5 -- ADVANCE_BANK_RECON.sql
--
-- reconcile_advance_batch(): a non-cash advance settles in Bank Reconciliation.
-- ############################################################################

-- ============================================================================
-- Advance Collection -- stage 4: a non-cash advance reaches Bank Reconciliation.
--
-- save_advance_collection already marks cash 'R' and everything else 'P', the
-- same rule a misc receipt follows. But the Bank Reconciliation screen only
-- ever read payment and misc_collection, so an advance taken by cheque, UPI or
-- Paytm was written as pending and then had nowhere to go: it could not be
-- ticked, matched against a statement, or settled. It simply sat there.
--
-- This adds the missing half -- the batch approve -- and the screen now lists
-- advances alongside fee and misc receipts.
--
-- Mirrors reconcile_misc_batch exactly, including the guard that matters:
-- recon_status = 'P' in the WHERE clause, so approving twice cannot rewrite the
-- reconciled_by / reconciled_date of a receipt somebody else already settled.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_advance_batch(
    p_ins_id    integer,
    p_adv_ids   bigint[],
    p_user      text,
    p_bank_ref  text DEFAULT NULL,
    p_bank_date text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE v text; n integer := 0;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  IF p_adv_ids IS NULL OR array_length(p_adv_ids, 1) IS NULL THEN RETURN 0; END IF;

  EXECUTE format('UPDATE %I.advance_collection
                     SET recon_status    = ''R'',
                         reconciled_by   = $2,
                         reconciled_date = NOW(),
                         bank_reference  = COALESCE($3, bank_reference),
                         bank_date       = COALESCE($4::date, bank_date)
                   WHERE ins_id = $5 AND adv_id = ANY($1)
                     AND recon_status = ''P'' AND activestatus = 1', v)
    USING p_adv_ids, p_user, NULLIF(p_bank_ref, ''), NULLIF(p_bank_date, ''), p_ins_id;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;

GRANT EXECUTE ON FUNCTION public.reconcile_advance_batch(integer, bigint[], text, text, text) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect one row, both flags t.
-- ============================================================================
SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'reconcile_advance_batch';


-- ############################################################################
-- PART 4 of 5 -- FIX_DAILY_FEETYPE_SPLIT_LINES.sql
--
-- Daily Collection: a fee settled in two pieces on one receipt no longer loses a piece (replaces the two report functions).
-- ############################################################################

-- ============================================================================
-- DAILY COLLECTION: a fee settled in two pieces on one receipt lost a piece.
--
-- SYMPTOM
-- A receipt that takes part of a fee in cash and part from an advance shows the
-- fee-type column SHORT, while Total is right:
--
--     FC26/02934   T/F 35,000   Total 35,500   Cash 500   Adjusted 35,000
--                      ^^^^^^ should be 35,500
--
-- CAUSE
-- Both report functions built the fee-type breakdown with
--
--     jsonb_object_agg(fd.demfeetype, pd.transtotalamount - fd.fineamount)
--
-- over one row per paymentdetails line. A demand settled twice on the same
-- receipt (cash + advance, or two part-payments) produces two rows with the
-- SAME key, and jsonb_object_agg keeps only the last one -- the 500 was
-- dropped. The same join counted the demand's fine once per line, and the
-- per-line subtraction took that fine off the fee more than once.
--
-- FIX
-- Aggregate per demand first, then per fee type, and take the fine off once.
-- Both functions get the same treatment, so the reconciled and unreconciled
-- sections cannot disagree.
--
-- Row totals are unaffected -- they were already summed from the collected
-- amounts -- so the day's money does not move. Only the breakdown is corrected.
--
-- Reproduced verbatim from complete_setup.sql apart from those two aggregates.
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_daily_collection_report(
    p_schema TEXT, p_ins_id INT, p_from DATE, p_to DATE
) RETURNS TABLE (
    pay_id BIGINT, paynumber TEXT, stuadmno TEXT, stuname TEXT,
    courname TEXT, stuclass TEXT, semester TEXT, type TEXT, paymethod TEXT, createdby TEXT,
    fees_json JSONB, fine NUMERIC, total NUMERIC, paydate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                -- FEE ONLY, and SUMMED PER FEE TYPE.
                --
                -- A demand can appear on one receipt more than once -- part
                -- cash and part advance is the everyday case -- and
                -- jsonb_object_agg keeps only the LAST value for a repeated
                -- key. A 35,500 tuition fee settled as 500 cash + 35,000
                -- advance therefore printed as 35,000: the 500 vanished from
                -- the fee-type column while the row total still read 35,500.
                --
                -- The fine comes off ONCE PER DEMAND, not once per line.
                -- pd.transtotalamount includes the fine and fd.fineamount is
                -- the whole of it, so subtracting it from every line of a split
                -- demand understated the fee by the fine each extra time.
                (SELECT COALESCE(jsonb_object_agg(t.ft, t.amt)
                                 FILTER (WHERE t.ft IS NOT NULL), '{}'::jsonb)
                   FROM (SELECT d.demfeetype AS ft, SUM(d.amt) AS amt
                           FROM (SELECT fd2.demfeetype,
                                        SUM(pd2.transtotalamount)
                                          - COALESCE(MAX(fd2.fineamount), 0) AS amt
                                   FROM %1$I.paymentdetails pd2
                                   JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                                  WHERE pd2.pay_id = p.pay_id
                                    AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')
                                  GROUP BY fd2.demfeetype, fd2.dem_id) d
                          GROUP BY d.demfeetype) t) AS fees_json,
                -- One fine per DEMAND. SUM over the joined rows counted it
                -- again for every line a split demand added.
                (SELECT COALESCE(SUM(f.fineamount), 0)
                   FROM (SELECT DISTINCT fd2.dem_id, fd2.fineamount
                           FROM %1$I.paymentdetails pd2
                           JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                          WHERE pd2.pay_id = p.pay_id
                            AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')) f)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus IN ('C','R') AND p.recon_status = 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;
GRANT EXECUTE ON FUNCTION public.get_daily_collection_report(TEXT, INT, DATE, DATE) TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.get_daily_collection_unreconciled(
    p_schema TEXT, p_ins_id INT, p_from DATE, p_to DATE
) RETURNS TABLE (
    pay_id BIGINT, paynumber TEXT, stuadmno TEXT, stuname TEXT,
    courname TEXT, stuclass TEXT, semester TEXT, type TEXT, paymethod TEXT, createdby TEXT,
    fees_json JSONB, fine NUMERIC, total NUMERIC, paydate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                -- FEE ONLY, and SUMMED PER FEE TYPE.
                --
                -- A demand can appear on one receipt more than once -- part
                -- cash and part advance is the everyday case -- and
                -- jsonb_object_agg keeps only the LAST value for a repeated
                -- key. A 35,500 tuition fee settled as 500 cash + 35,000
                -- advance therefore printed as 35,000: the 500 vanished from
                -- the fee-type column while the row total still read 35,500.
                --
                -- The fine comes off ONCE PER DEMAND, not once per line.
                -- pd.transtotalamount includes the fine and fd.fineamount is
                -- the whole of it, so subtracting it from every line of a split
                -- demand understated the fee by the fine each extra time.
                (SELECT COALESCE(jsonb_object_agg(t.ft, t.amt)
                                 FILTER (WHERE t.ft IS NOT NULL), '{}'::jsonb)
                   FROM (SELECT d.demfeetype AS ft, SUM(d.amt) AS amt
                           FROM (SELECT fd2.demfeetype,
                                        SUM(pd2.transtotalamount)
                                          - COALESCE(MAX(fd2.fineamount), 0) AS amt
                                   FROM %1$I.paymentdetails pd2
                                   JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                                  WHERE pd2.pay_id = p.pay_id
                                    AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')
                                  GROUP BY fd2.demfeetype, fd2.dem_id) d
                          GROUP BY d.demfeetype) t) AS fees_json,
                -- One fine per DEMAND. SUM over the joined rows counted it
                -- again for every line a split demand added.
                (SELECT COALESCE(SUM(f.fineamount), 0)
                   FROM (SELECT DISTINCT fd2.dem_id, fd2.fineamount
                           FROM %1$I.paymentdetails pd2
                           JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                          WHERE pd2.pay_id = p.pay_id
                            AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')) f)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus IN ('C','R')
            AND p.recon_status IS DISTINCT FROM 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;
GRANT EXECUTE ON FUNCTION public.get_daily_collection_unreconciled(TEXT, INT, DATE, DATE) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect both rows t.
-- ============================================================================
SELECT p.proname,
       p.prosrc LIKE '%GROUP BY fd2.demfeetype, fd2.dem_id%' AS sums_split_lines
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('get_daily_collection_report', 'get_daily_collection_unreconciled')
 ORDER BY p.proname;


-- ############################################################################
-- PART 5 of 5 -- fix_reconbalancedue_cash_payment.sql
--
-- A cash payment no longer wipes OTHER pending payments off reconbalancedue (replaces process_grouped_payment).
-- ############################################################################

-- ============================================================================
-- FIX: a cash payment wiped OTHER pending payments off reconbalancedue.
--
-- WHAT WENT WRONG
-- process_grouped_payment has two branches. Cash is auto-reconciled, so it
-- syncs reconbalancedue; everything else leaves it alone until the bank
-- confirms. The cash branch set
--
--     reconbalancedue = balancedue
--
-- which is only right when nothing else on that demand is awaiting
-- reconciliation. When something is, that assignment declares it reconciled
-- too, and the money vanishes from Outstanding without the bank ever
-- confirming it.
--
-- A real case (demand 9178, fee 82,500):
--     7,500  upi              pending
--    20,000  Online Transfer  pending
--    10,000  cash             auto-reconciled
--
--   before the cash:  balancedue 55,000   reconbalancedue 82,500
--   after  the cash:  balancedue 45,000   reconbalancedue 45,000   <-- wrong
--   correct:                              reconbalancedue 72,500
--
-- 27,500 of unconfirmed money disappeared, and the dashboard stopped adding up:
-- Total Fees Due - Total Collected no longer equalled Outstanding.
--
-- THE FIX
-- Reduce reconbalancedue by THIS payment's own amount instead of collapsing it:
--
--     reconbalancedue = GREATEST(COALESCE(reconbalancedue,0) - itm.amount, 0)
--
-- On a demand with nothing pending this gives exactly the same answer it gives
-- today, so ordinary collections are unaffected. On a demand that does have
-- pending payments it keeps them pending, which is the point.
--
-- Only the one line changes; the rest of the function is reproduced verbatim
-- from complete_setup.sql so nothing else drifts.
--
-- ALSO RUN migrations/QUERY_fix_reconbalancedue.sql to repair rows already
-- damaged by this. This migration stops it happening again; it does not go
-- back and correct history.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_grouped_payment(
  p_ins_id integer, p_inscode varchar, p_stu_id bigint,
  p_yr_id integer, p_yrlabel varchar, p_total_amount numeric,
  p_created_by varchar, p_pay_method text, p_pay_reference text,
  p_items jsonb
) RETURNS jsonb
-- search_path is PINNED, matching what is already on live. A
-- SECURITY DEFINER function without it is a privilege-escalation vector
-- (and Supabase's advisor flags it). complete_setup.sql had lost this
-- clause, so rebuilding the function from it would have silently
-- stripped the hardening off live.
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $$
DECLARE
  v text; v_fg_id INTEGER; v_pay_id BIGINT; v_pay_number TEXT;
  v_seq RECORD; v_new_no INTEGER;
  v_current_paid NUMERIC; v_current_balance NUMERIC; v_current_fine NUMERIC;
  v_new_paid NUMERIC; v_new_balance NUMERIC;
  v_result JSONB := '[]'::jsonb;
  v_group_total NUMERIC;
  itm RECORD; v_fg_ids INTEGER[];
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found'; END IF;
  v_fg_ids := ARRAY[]::INTEGER[];
  FOR itm IN SELECT x.dem_id, x.yr_id, x.yrlabel, x.amount, x.demfeetype
    FROM jsonb_to_recordset(p_items) AS x(dem_id bigint, yr_id integer, yrlabel text, ins_id integer, amount numeric, demfeetype text)
  LOOP
    v_fg_id := NULL;
    IF itm.demfeetype = 'FINE' THEN
      -- New format: demno starts with 'FNG<fg_id>' (group-wise fine).
      -- Older format: 'FN<orig_dem_id>' (per-demand fine) — fall back to that.
      EXECUTE format($q$
        SELECT CASE
          WHEN fn.demno LIKE 'FNG%%' THEN
            NULLIF(substring(fn.demno from '[0-9]+'), '')::int
          WHEN fn.demno LIKE 'FN%%' THEN
            (SELECT ft.fg_id FROM %I.feedemand orig
             JOIN %I.feetype ft
               ON (orig.fee_id IS NOT NULL AND ft.fee_id = orig.fee_id)
               OR (orig.fee_id IS NULL AND ft.feedesc = orig.demfeetype)
             WHERE orig.dem_id = NULLIF(substring(fn.demno from '[0-9]+'), '')::bigint
               AND ft.activestatus = 1 LIMIT 1)
          ELSE NULL
        END
        FROM %I.feedemand fn
        WHERE fn.dem_id = $1
      $q$, v, v, v) INTO v_fg_id USING itm.dem_id;
    END IF;
    IF v_fg_id IS NULL THEN
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc=$1 AND ft.activestatus=1 LIMIT 1',v) INTO v_fg_id USING itm.demfeetype;
    END IF;
    IF v_fg_id IS NULL THEN v_fg_id := 0; END IF;
    IF NOT v_fg_id = ANY(v_fg_ids) THEN v_fg_ids := v_fg_ids || v_fg_id; END IF;
  END LOOP;
  -- Create one payment per fee group
  FOREACH v_fg_id IN ARRAY v_fg_ids LOOP
    v_group_total := 0;
    -- Online-channel payments (razorpay / QR-UPI / online) stamp ban_id from
    -- the fee group so per-bank routing reports work. Cash / cheque / DD all
    -- land in one main account, so they leave ban_id NULL.
    EXECUTE format('INSERT INTO %1$I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,paydate,paystatus,paymethod,payreference,createdby,recon_status,reconciled_by,reconciled_date,ban_id) VALUES($1,$2,$3,$4,$5,0,''INR'',NOW(),''C'',$6,$7,$8,CASE WHEN LOWER($6)=''cash'' THEN ''R'' ELSE ''P'' END,CASE WHEN LOWER($6)=''cash'' THEN $8 ELSE NULL END,CASE WHEN LOWER($6)=''cash'' THEN NOW() ELSE NULL END,CASE WHEN LOWER($6) IN (''razorpay'',''upi'',''qr_upi'',''online'') THEN (SELECT ban_id FROM %1$I.feegroup WHERE fg_id=$9 LIMIT 1) ELSE NULL END) RETURNING pay_id',v)
    INTO v_pay_id USING p_ins_id,p_inscode,p_stu_id,p_yr_id,p_yrlabel,p_pay_method,p_pay_reference,p_created_by,v_fg_id;
    -- Get sequence for this fee group (with row lock for concurrency)
    v_seq := NULL;
    EXECUTE format('SELECT seq_id,sequid,seqwidth,seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id=$2 LIMIT 1 FOR UPDATE',v) INTO v_seq USING p_ins_id,v_fg_id;
    IF v_seq IS NULL THEN v_pay_number:='PAY'||v_pay_id;
    ELSE v_new_no:=v_seq.seqcurno+1; v_pay_number:=regexp_replace(v_seq.sequid,'\d+$','')||lpad(v_new_no::TEXT,v_seq.seqwidth::INTEGER,'0'); EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2',v) USING v_new_no,v_seq.seq_id;
    END IF;
    EXECUTE format('UPDATE %I.payment SET paynumber=$1 WHERE pay_id=$2',v) USING v_pay_number,v_pay_id;
    -- Process demands for this fee group
    FOR itm IN SELECT x.dem_id, x.yr_id, x.yrlabel, x.amount, x.demfeetype
      FROM jsonb_to_recordset(p_items) AS x(dem_id bigint, yr_id integer, yrlabel text, ins_id integer, amount numeric, demfeetype text)
    LOOP
      DECLARE v_item_fg INTEGER;
      BEGIN
        v_item_fg := NULL;
        IF itm.demfeetype = 'FINE' THEN
          EXECUTE format($q$
            SELECT ft.fg_id
            FROM %I.feedemand fn
            JOIN %I.feedemand orig ON orig.dem_id = NULLIF(substring(fn.demno from '[0-9]+'), '')::bigint
            JOIN %I.feetype ft
              ON (orig.fee_id IS NOT NULL AND ft.fee_id = orig.fee_id)
              OR (orig.fee_id IS NULL AND ft.feedesc = orig.demfeetype)
            WHERE fn.dem_id = $1 AND ft.activestatus = 1
            LIMIT 1
          $q$, v, v, v) INTO v_item_fg USING itm.dem_id;
        END IF;
        IF v_item_fg IS NULL THEN
          EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc=$1 AND ft.activestatus=1 LIMIT 1',v) INTO v_item_fg USING itm.demfeetype;
        END IF;
        IF v_item_fg IS NULL THEN v_item_fg := 0; END IF;
        IF v_item_fg != v_fg_id THEN CONTINUE; END IF;
      END;
      v_group_total := v_group_total + itm.amount;
      EXECUTE format('INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount) VALUES($1,$2,$3,$4,$5,''INR'',$6)',v) USING v_pay_id,itm.dem_id,itm.yr_id,itm.yrlabel,p_ins_id,itm.amount;
      -- FOR UPDATE locks the row so concurrent collectors serialize. If the
      -- locked balance is already <= 0 another accountant got here first;
      -- raise to roll back this whole txn (including the payment row inserted
      -- above) so no duplicate receipt is created.
      EXECUTE format('SELECT paidamount,balancedue,fineamount FROM %I.feedemand WHERE dem_id=$1 AND activestatus=1 FOR UPDATE',v) INTO v_current_paid,v_current_balance,v_current_fine USING itm.dem_id;
      IF COALESCE(v_current_balance,0) <= 0 THEN
        RAISE EXCEPTION 'Demand % is already paid (balance=%). Another payment may have been posted - please refresh.', itm.dem_id, v_current_balance USING ERRCODE = 'P0001';
      END IF;
      -- Never take more than is owed. A receipt legitimately carries
      -- balance + fine, so the fine is part of the ceiling; anything above it
      -- is a stale screen or a double post, and collecting it creates money
      -- that has to be refunded later.
      IF itm.amount > COALESCE(v_current_balance,0) + COALESCE(v_current_fine,0) + 0.005 THEN
        RAISE EXCEPTION 'Collection of % on demand % exceeds the amount due (balance % + fine %). Please refresh and try again.',
          itm.amount, itm.dem_id, COALESCE(v_current_balance,0), COALESCE(v_current_fine,0) USING ERRCODE = 'P0001';
      END IF;
      v_new_paid:=COALESCE(v_current_paid,0)+itm.amount; v_new_balance:=COALESCE(v_current_balance,0)-itm.amount; IF v_new_balance<0 THEN v_new_balance:=0; END IF;
      -- For cash (auto-reconciled) payments, also sync reconbalancedue so
      -- the Pending Payment Report doesn't leave them as owed.
      IF LOWER(p_pay_method) = 'cash' THEN
        -- Reduce reconbalancedue by THIS payment only. It used to be set
        -- equal to balancedue, which silently declared every OTHER pending
        -- payment on the same demand reconciled as well -- see the header.
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1,balancedue=$2,reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$5,0),paidstatus=CASE WHEN $2<=0 THEN ''P'' ELSE ''U'' END,pay_id=$3 WHERE dem_id=$4',v) USING v_new_paid,v_new_balance,v_pay_id,itm.dem_id,itm.amount;
      ELSE
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1,balancedue=$2,paidstatus=CASE WHEN $2<=0 THEN ''P'' ELSE ''U'' END,pay_id=$3 WHERE dem_id=$4',v) USING v_new_paid,v_new_balance,v_pay_id,itm.dem_id;
      END IF;
    END LOOP;
    EXECUTE format('UPDATE %I.payment SET transtotalamount=$1 WHERE pay_id=$2',v) USING v_group_total,v_pay_id;
    v_result := v_result || jsonb_build_object('pay_id',v_pay_id,'paynumber',v_pay_number,'fg_id',v_fg_id,'amount',v_group_total);
  END LOOP;
  RETURN v_result;
END; $$;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- the cash branch must now decrement, not assign.
-- Expect: has_fix = t, still_collapses = f
-- ============================================================================
SELECT p.proname,
       prosrc LIKE '%reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$5,0)%' AS has_fix,
       prosrc LIKE '%balancedue=$2,reconbalancedue=$2,%'                          AS still_collapses
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'process_grouped_payment';



-- ############################################################################
-- FINAL VERIFY -- one row per object. Every 'present' column should read t.
-- ############################################################################
NOTIFY pgrst, 'reload schema';

SELECT 'advance tables (per schema)' AS what,
       count(*) FILTER (WHERE table_name = 'advance_collection') AS advance_collection,
       count(*) FILTER (WHERE table_name = 'advance_detail')     AS advance_detail,
       count(*) FILTER (WHERE table_name = 'advadjustment')      AS advadjustment
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection', 'advance_detail', 'advadjustment');

SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
       CASE
         WHEN p.proname = 'adjust_advance'          THEN p.prosrc LIKE '%v_adv_reconciled%'
         WHEN p.proname = 'save_advance_collection' THEN p.prosrc LIKE '%fg_id=$2 AND activestatus=1%'
         WHEN p.proname = 'void_receipt'            THEN p.prosrc LIKE '%v_no_bank_leg%'
         WHEN p.proname = 'process_grouped_payment' THEN p.prosrc LIKE '%reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$5,0)%'
         WHEN p.proname LIKE 'get_daily_collection%' THEN p.prosrc LIKE '%GROUP BY fd2.demfeetype, fd2.dem_id%'
         ELSE true
       END                                              AS carries_this_updates_change
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('save_advance_collection', 'adjust_advance', 'void_advance_receipt',
                     'refund_advance', 'void_receipt_with_advance', 'reconcile_advance_batch',
                     'get_daily_collection_report', 'get_daily_collection_unreconciled',
                     'process_grouped_payment', 'void_receipt')
 ORDER BY p.proname;

-- Numbering sequences (CONFIGURATION, not created by this file). A missing
-- ADVNO only blocks STUDENT advances; a missing REFNO only blocks refunds.
-- Both are added in Fee Master -> Advance No / Refund No.
DO $seqchk$
DECLARE r RECORD; v_adv int; v_ref int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'sequence' AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('SELECT count(*) FROM %I.sequence WHERE actname = ''ADVNO'' AND activestatus = 1', r.s) INTO v_adv;
    EXECUTE format('SELECT count(*) FROM %I.sequence WHERE actname = ''REFNO'' AND activestatus = 1', r.s) INTO v_ref;
    RAISE NOTICE '%: ADVNO %, REFNO %', r.s,
      CASE WHEN v_adv > 0 THEN 'configured' ELSE 'MISSING -- student advances will refuse' END,
      CASE WHEN v_ref > 0 THEN 'configured' ELSE 'MISSING -- refunds will refuse' END;
  END LOOP;
END $seqchk$;



-- ############################################################################
-- ############################################################################
--
--   PART 3 OF 7  --  Reports: leavers out, TC filter in
--   source: migrations/REPORTS_STUDENT_TC_FILTER.sql
--
--   Students holding a TC stop counting in the outstanding-dues reports, and
--   those reports gain a Without TC / TC Issued / All filter. Adds overloads
--   -- the existing function signatures keep working, so an un-updated desktop
--   copy is unaffected.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- EduCore360 -- REPORTS: LEAVERS OUT BY DEFAULT, PLUS A TC FILTER, 18-09-2026
--
-- Two things, in one file:
--
-- (A) A student who has left is no longer counted in the outstanding-dues
--     reports. They still own their demand rows, so Pending Payment, Pending
--     Details, Consolidated Status and the DCB Register were carrying money
--     nobody is going to collect.
--
-- (B) Those four reports get a TC filter -- Without TC / TC Issued / All
--     Students -- so the leavers can still be looked at deliberately.
--
-- students.activestatus is what the Transfer Certificate screen writes when a
-- TC is issued, and what it sets back to 1 when a TC is cancelled, so it is
-- the definition of "holds a TC" used here:
--     1 Active, 2 Discontinued, 3 Transferred, 4 Completed, 5 Others,
--     9 Terminated.
--
-- NOTHING IS DROPPED AND NO SIGNATURE CHANGES. The existing 1-arg / 2-arg
-- functions keep working exactly as they do now (a desktop copy that has not
-- been updated yet is unaffected); the new behaviour arrives as OVERLOADS that
-- take the filter. PostgREST picks the one whose argument names match the
-- call, so the two never collide.
--
--   public.tc_student_filter(text)                            NEW helper
--   public.get_fee_report_data(int, text)                     NEW overload
--   public.get_pending_payment_report(text, int, text)        NEW overload
--   public.get_consolidated_status_report(text, int, text)    NEW overload
--   public.get_pending_details_report(text, int, text)        NEW overload
--   public.get_pending_payment_report(text, int)              now a wrapper
--   public.get_consolidated_status_report(text, int)          now a wrapper
--   public.get_pending_details_report(text, int)              now a wrapper
--   public.get_pending_export_data(int)                       active only
--
-- SAFE TO RE-RUN. No row is inserted, updated or deleted: this changes code
-- only. CREATE OR REPLACE keeps the existing EXECUTE grants; the new functions
-- are granted explicitly at the end.
--
-- DELIBERATELY NOT CHANGED -- these report money that was actually received,
-- and a receipt is history. Dropping a leaver's past receipts would stop the
-- day's total matching the bank:
--   * get_daily_collection_report / _unreconciled  (Daily Collection)
--   * get_powercollege_export                      (Reports -> Export)
--   * get_student_ledger_report                    (Student Ledger deliberately
--     still opens a leaver's ledger, and the screen marks them TC ISSUED)
--
-- Applied and checked on the TEST project first (a full restore of live).
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- what the leavers are worth on THIS database. Run this
-- first and keep the output.
-- ############################################################################
DO $before$
DECLARE r RECORD; v_stu int; v_dem int; v_bal numeric;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(DISTINCT s.stu_id), count(fd.dem_id), COALESCE(sum(fd.balancedue),0)
        FROM %I.students s
        JOIN %I.feedemand fd ON fd.stu_id = s.stu_id AND fd.ins_id = s.ins_id
                            AND fd.activestatus = 1
       WHERE s.activestatus <> 1 $q$, r.s, r.s) INTO v_stu, v_dem, v_bal;
    RAISE NOTICE '%: % students with a TC, % live demands, % pending',
                 r.s, v_stu, v_dem, v_bal;
  END LOOP;
END $before$;


-- ----------------------------------------------------------------------------
-- 1 -- public.tc_student_filter(text)
--
-- The one place the three filter modes are defined. It returns a SQL fragment,
-- never the caller's text, so the reports below cannot be injected into.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tc_student_filter(p_tc TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $tcf$
  SELECT CASE UPPER(COALESCE(TRIM(p_tc), 'NOTC'))
           -- Students who hold a TC: they have left, so their dues are shown
           -- only when they are asked for.
           WHEN 'TC'  THEN 's.activestatus <> 1'
           -- Everybody, TC or not.
           WHEN 'ALL' THEN 'TRUE'
           -- Default, and what every report shows unless told otherwise.
           ELSE 's.activestatus = 1'
         END;
$tcf$;


-- ----------------------------------------------------------------------------
-- 2 -- public.get_fee_report_data(integer, text)   NEW OVERLOAD
--
-- Feeds the DCB Register and the Student Ledger picker. The app calls this one
-- with 'ALL' and does the filtering on screen, because the Student Ledger must
-- be able to open a student who has left while the DCB Register hides them --
-- one load, both behaviours. It returns one extra field, stuactive, which is
-- how the screen tells them apart and how it marks a ledger TC ISSUED.
--
-- The 1-arg form is untouched and still returns active students only.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_fee_report_data(p_ins_id integer, p_tc text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $gfrd$
DECLARE v text; r json; v_stu text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN '[]'::json; END IF;
  v_stu := public.tc_student_filter(p_tc);
  EXECUTE format('SELECT json_agg(t) FROM (SELECT fd.fee_id,fd.stu_id,fd.feeamount,fd.conamount,fd.paidamount,fd.balancedue,fd.reconbalancedue,fd.paidstatus,fd.stuclass,fd.courname,fd.stuadmno,fd.demfeetype,fd.demfeeterm,fd.activestatus,s.stuname,s.activestatus AS stuactive,s.stuclass AS stu_class,s.courname AS stu_course FROM %1$I.feedemand fd JOIN %1$I.students s ON s.stu_id=fd.stu_id AND s.ins_id=fd.ins_id AND %2$s WHERE fd.ins_id=$1 AND fd.activestatus=1 ORDER BY fd.stuadmno) t', v, v_stu) INTO r USING p_ins_id;
  RETURN COALESCE(r, '[]'::json);
END; $gfrd$;


-- ----------------------------------------------------------------------------
-- 3 -- public.get_pending_payment_report(text, int, text)   NEW OVERLOAD
-- Reports -> Pending Payment.
-- The students join is now whatever tc_student_filter() returns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.seqtype, t.stuadmno), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  fd.demfeeterm::TEXT AS semester,
                  -- Regular vs Arrear, same rule as Fee Collection and Fee
                  -- Concession: anything not explicitly ARREAR counts as
                  -- REGULAR, so a null/blank demseqtype never hides a due.
                  (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END)::TEXT AS seqtype,
                  s.admname::TEXT AS admname, s.stuadmno::TEXT AS stuadmno, s.stuname::TEXT AS stuname,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  s.quoname::TEXT AS quoname, s.stumobile::TEXT AS stumobile
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, fd.demfeeterm,
                   (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END),
                   s.admname, s.stuadmno, s.stuname, s.quoname, s.stumobile
          -- Keep a group that has nothing pending but DID receive a concession:
          -- dropping it also dropped its conamount, so the report's CON. AMT
          -- total came out short of SUM(feedemand.conamount).
          HAVING  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) <> 0
             OR   COALESCE(SUM(fd.conamount), 0) <> 0
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;

-- ----------------------------------------------------------------------------
-- 4 -- public.get_consolidated_status_report(text, int, text)   NEW OVERLOAD
-- Reports -> Consolidated Status.
-- The students join is now whatever tc_student_filter() returns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH class_strength AS (
            SELECT courname, stuclass, COUNT(DISTINCT stu_id)::INT AS strength
            FROM   %1$I.students WHERE ins_id = %2$L AND activestatus = 1
            GROUP BY courname, stuclass
        ),
        pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.category, t.type), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  cs.strength,
                  fd.demfeeterm::TEXT AS semester,
                  -- category = admission type (e.g. GOVERNMENT QUOTA / MANAGEMENT QUOTA)
                  COALESCE(NULLIF(s.admname, ''), 'GENERAL')::TEXT AS category,
                  COUNT(DISTINCT s.stu_id)::INT AS stud_count,
                  (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                  SUM(fd.feeamount)::NUMERIC AS due,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  SUM(fd.feeamount)::NUMERIC AS net_demand,
                  -- Paid = fee-only, approved-only (pending-approval amounts are subtracted)
                  GREATEST(
                    COALESCE(SUM(fd.paidamount),0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                      - COALESCE(SUM(pa.pending_fee),0),
                    0
                  )::NUMERIC AS paid,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS balance
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN class_strength cs
                 ON cs.courname = s.courname AND cs.stuclass = s.stuclass
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, cs.strength,
                   fd.demfeeterm, COALESCE(NULLIF(s.admname, ''), 'GENERAL'),
                   (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;

-- ----------------------------------------------------------------------------
-- 5 -- public.get_pending_details_report(text, int, text)   NEW OVERLOAD
-- Reports -> Pending Details.
-- The students join is now whatever tc_student_filter() returns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_details_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        ),
        per_type AS (
          SELECT  s.courname::TEXT                                  AS courname,
                  s.stuclass::TEXT                                  AS stuclass,
                  s.stuadmno::TEXT                                  AS stuadmno,
                  s.stuname::TEXT                                   AS stuname,
                  -- Category on the printed sheet is the student's quota.
                  COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL')::TEXT   AS category,
                  COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS')::TEXT AS feetype,
                  -- REGULAR vs ARREAR, so the report can be filtered to one or
                  -- the other. NULL is reported as REGULAR: older rows predate
                  -- the column and are all current-year demands.
                  COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')::TEXT AS demseqtype,
                  SUM(fd.feeamount)::NUMERIC                        AS demand,
                  SUM(fd.feeamount - COALESCE(fd.conamount, 0))::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount), 0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0)
                      - COALESCE(SUM(pa.pending_fee), 0),
                    0
                  )::NUMERIC                                        AS collection,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, s.stuadmno, s.stuname,
                   COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL'),
                   COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS'),
                   COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')
        )
        -- Only students who actually owe something. Their OTHER fee types are
        -- still returned, because the Total Demand / Collection columns are
        -- whole-student figures, not just the unpaid slice.
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.stuadmno, t.feetype, t.demseqtype), '[]'::json)
        FROM (
          SELECT * FROM per_type
          WHERE  stuadmno IN (SELECT stuadmno FROM per_type
                               GROUP BY stuadmno HAVING SUM(pending) <> 0)
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;


-- ----------------------------------------------------------------------------
-- 6 -- the original 2-arg forms become wrappers
--
-- A desktop copy that has not been updated yet calls these. They now mean
-- "without TC", which is the same set of students the report should have been
-- showing all along, and there is only one copy of each report body to keep.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_payment_report(p_schema TEXT, p_ins_id INT)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w1$
  SELECT public.get_pending_payment_report(p_schema, p_ins_id, 'NOTC');
$w1$;

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(p_schema TEXT, p_ins_id INT)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w2$
  SELECT public.get_consolidated_status_report(p_schema, p_ins_id, 'NOTC');
$w2$;

CREATE OR REPLACE FUNCTION public.get_pending_details_report(p_schema TEXT, p_ins_id INT)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w3$
  SELECT public.get_pending_details_report(p_schema, p_ins_id, 'NOTC');
$w3$;


-- ----------------------------------------------------------------------------
-- 7 -- public.get_pending_export_data(integer)
-- The pending-fee export on the Fee Collection screen. No filter on that
-- screen, so it is simply active students.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_export_data(p_ins_id integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN '[]'::json; END IF;
  EXECUTE format('SELECT json_agg(t) FROM (SELECT fd.stu_id,fd.stuadmno,fd.stuclass,fd.courname,fd.demfeetype,fd.demfeeterm,fd.feeamount,fd.conamount,fd.balancedue,fd.reconbalancedue,fd.paidstatus,s.stuname FROM %I.feedemand fd JOIN %I.students s ON s.stu_id=fd.stu_id AND s.ins_id=fd.ins_id AND s.activestatus=1 WHERE fd.ins_id=$1 AND fd.activestatus=1 ORDER BY fd.courname,fd.stuclass,fd.stuadmno) t', v, v) INTO r USING p_ins_id;
  RETURN COALESCE(r, '[]'::json);
END; $$;


GRANT EXECUTE ON FUNCTION public.tc_student_filter(TEXT)                           TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_fee_report_data(integer, text)                TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_payment_report(TEXT, INT, TEXT)       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_consolidated_status_report(TEXT, INT, TEXT)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_details_report(TEXT, INT, TEXT)       TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- VERIFY -- anon_can_execute must read t on every row.
-- ############################################################################
SELECT p.proname,
       pg_get_function_identity_arguments(p.oid) AS args,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('tc_student_filter', 'get_fee_report_data', 'get_pending_export_data',
                     'get_pending_payment_report', 'get_consolidated_status_report',
                     'get_pending_details_report')
 ORDER BY p.proname, args;

-- The three modes, on this database. without_tc is what the report shows now,
-- and without_tc + tc_issued must add up to all_students.
SELECT (SELECT sum((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(s, i, 'NOTC')) e) AS without_tc,
       (SELECT sum((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(s, i, 'TC')) e)   AS tc_issued,
       (SELECT sum((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(s, i, 'ALL')) e)  AS all_students
  FROM (SELECT get_institution_schema(1) AS s, 1 AS i) q;



-- ############################################################################
-- ############################################################################
--
--   PART 4 OF 7  --  Course transfer moves the advance
--   source: migrations/TRANSFER_UPDATES_ADVANCE.sql
--
--   A transferred student's advance was left filed under the class they left,
--   invisible to both advance screens while money sat on it. Includes a repair
--   for rows already stranded.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- EduCore360 -- COURSE TRANSFER ALSO MOVES THE STUDENT'S ADVANCES, 19-09-2026
--
-- public.transfer_course_with_credit already moves the student's class and
-- course onto students, public.admission and the new fee demands. It did not
-- touch advance_collection, which carries stuclass / courname of its own --
-- and both the Advance Collection and the Advance Adjustment screens FILTER on
-- those columns rather than joining students.
--
-- The effect: transfer a student who is holding an advance and the advance
-- stays filed under the class they left. It disappears from the new class's
-- list, and from the Advance Adjustment grid, while the money is still on it.
--
-- One statement is added, as step 2c. Nothing else in the function changes;
-- the body below is otherwise exactly what is in C:\pg_backups\complete_setup.sql.
--
--   * advance_detail and advadjustment hold no class or course column, so
--     there is nothing on them to move.
--   * payment and misc_collection are NOT touched. A receipt is a document
--     that was issued to a student in a class on a day, and rewriting the
--     class on it would change what was printed. An advance is different --
--     it is a live balance that has to be found and spent.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE, one function, no data change of its own.
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- advances whose class no longer matches their student.
-- These are the ones already stranded; run the FIX at the bottom to move them.
-- ############################################################################
DO $before$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*) FROM %I.advance_collection a
        JOIN %I.students s ON s.stu_id = a.stu_id
       WHERE a.stuclass IS DISTINCT FROM s.stuclass
          OR a.courname IS DISTINCT FROM s.courname $q$, r.s, r.s) INTO n;
    RAISE NOTICE '%: % advance row(s) filed under the wrong class', r.s, n;
  END LOOP;
END $before$;


-- ############################################################################
-- THE FUNCTION
-- ############################################################################
CREATE OR REPLACE FUNCTION public.transfer_course_with_credit(
  p_ins_id integer, p_stu_id bigint,
  p_target_class text, p_target_course text,
  p_credits jsonb,            -- [{"cf_id": int, "feeamt": numeric, "credit": numeric}]
  p_doc_no integer, p_promotion_date date,
  p_created_by text, p_remarks text,
  p_target_adm_id smallint DEFAULT NULL   -- NULL = leave admission type unchanged
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '60s'
AS $$
DECLARE
  v text;
  v_paid numeric; v_remaining numeric; v_applied numeric := 0; v_new_count int := 0;
  v_stuadmno text; v_stuname text; v_old_course text; v_old_class text;
  v_log_rows integer;
  v_yr_id int; v_yrlabel text; v_inscode text; v_con_id int; v_admname text; v_adm_id smallint;
  v_new_admname text;
  cf RECORD; v_credit numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  EXECUTE format('SELECT stuadmno, stuname, courname, stuclass, yr_id, yrlabel, inscode, con_id, admname, adm_id FROM %I.students WHERE stu_id=$1', v)
    INTO v_stuadmno, v_stuname, v_old_course, v_old_class, v_yr_id, v_yrlabel, v_inscode, v_con_id, v_admname, v_adm_id
    USING p_stu_id;
  IF v_stuadmno IS NULL THEN RAISE EXCEPTION 'Student % not found', p_stu_id; END IF;

  -- The credit pool = what the student already paid on the current course.
  EXECUTE format('SELECT COALESCE(SUM(paidamount),0) FROM %I.feedemand WHERE stu_id=$1 AND activestatus=1', v)
    INTO v_paid USING p_stu_id;
  v_remaining := v_paid;

  -- 1) Settle / drop the old course demands.
  --    paid = 0 -> delete (nothing collected); paid > 0 -> keep but reduce the
  --    demand to the paid amount (balance 0, Paid) as a settled record.
  EXECUTE format('DELETE FROM %I.feedemand WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)=0', v)
    USING p_stu_id;
  EXECUTE format($u$UPDATE %I.feedemand
      SET feeamount=paidamount, conamount=0, balancedue=0, reconbalancedue=0, paidstatus='P'
      WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)>0$u$, v)
    USING p_stu_id;

  -- 2) Move the student to the new class/course (names + resolved ids). cla_id
  --    and cour_id come from the target class (class.cla_id / class.cour_id),
  --    else a course-name match, else kept as-is.
  -- 2a-i) Resolve the target admission type's NAME once. students.admname and
  --       public.admission.admname are denormalised copies, so moving adm_id
  --       without the name would leave the two disagreeing -- and several
  --       reports read the NAME, not the id.
  IF p_target_adm_id IS NOT NULL THEN
    EXECUTE format('SELECT admname FROM %I.admissiontype WHERE adm_id = $1', v)
      INTO v_new_admname USING p_target_adm_id;
  END IF;

  EXECUTE format($su$
    WITH tc AS (
      SELECT cl.cla_id, cl.cour_id FROM %1$I.class cl
      WHERE UPPER(TRIM(cl.claname)) = UPPER(TRIM($1)) AND cl.activestatus = 1
      ORDER BY cl.cla_id LIMIT 1
    ), co AS (
      SELECT c.cour_id FROM %1$I.course c
      WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM($2)) AND c.activestatus = 1
      ORDER BY c.cour_id LIMIT 1
    )
    UPDATE %1$I.students s SET
      stuclass = $1, courname = $2,
      cla_id  = COALESCE((SELECT cla_id  FROM tc), s.cla_id),
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), s.cour_id),
      adm_id  = COALESCE($4::smallint, s.adm_id),
      admname = COALESCE($5, s.admname)
    WHERE s.stu_id = $3
  $su$, v)
    USING p_target_class, p_target_course, p_stu_id, p_target_adm_id, v_new_admname;

  -- 2b) Mirror the move onto the student's admission record (public.admission),
  --     so the admission table's course/class stay in sync with the transfer.
  --     Matched by admission number (admno = student's stuadmno, unique per
  --     institution) because allocated admissions often carry a NULL stu_id;
  --     a stu_id match is kept as a fallback. cour_id / cla_id are refreshed
  --     from the schema masters; admit_cour_id (the originally-admitted course)
  --     is deliberately left unchanged.
  EXECUTE format($ad$
    WITH tc AS (
      SELECT cl.cla_id, cl.cour_id
      FROM %1$I.class cl
      WHERE UPPER(TRIM(cl.claname)) = UPPER(TRIM($1)) AND cl.activestatus = 1
      ORDER BY cl.cla_id LIMIT 1
    ), co AS (
      SELECT c.cour_id
      FROM %1$I.course c
      WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM($2)) AND c.activestatus = 1
      ORDER BY c.cour_id LIMIT 1
    )
    UPDATE public.admission a SET
      courname = $2, stuclass = $1, allocatedclass = $1,
      cla_id  = COALESCE((SELECT cla_id  FROM tc), a.cla_id),
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), a.cour_id),
      admtype_id = COALESCE($5::smallint, a.admtype_id),
      admname    = COALESCE($6, a.admname)
    WHERE a.ins_id = $3 AND a.activestatus = 1
      AND a.admno = $4
  $ad$, v)
    USING p_target_class, p_target_course, p_ins_id, v_stuadmno,
          p_target_adm_id, v_new_admname;

  -- 2c) And onto the student's ADVANCES.
  --
  --     advance_collection carries stuclass / courname of its own, and both
  --     the Advance Collection and Advance Adjustment screens filter on those
  --     columns rather than joining students. Left alone, a transferred
  --     student's advance stays filed under the class they left: it vanishes
  --     from the new class's list while money is still sitting on it.
  --
  --     Every row for the student is moved, cancelled ones included, so the
  --     two screens and the advance report agree about which class an advance
  --     belongs to. advance_detail and advadjustment hold no class or course
  --     column, so there is nothing on them to move.
  --
  --     Guarded by to_regclass: an institution schema created before the
  --     advance module exists has no such table, and a transfer must not fail
  --     because of it.
  IF to_regclass(format('%I.advance_collection', v)) IS NOT NULL THEN
    EXECUTE format($av$
      UPDATE %1$I.advance_collection a
         SET stuclass = $1, courname = $2
       WHERE a.stu_id = $3
         AND (a.stuclass IS DISTINCT FROM $1 OR a.courname IS DISTINCT FROM $2)
    $av$, v)
      USING p_target_class, p_target_course, p_stu_id;
  END IF;

  -- 3) Create the new course demands from the client amounts. The client already
  --    reduced feeamt by the matching OLD PAID (VB col8 -= paid); credit is the
  --    fee's concession (feeamount = feeamt, conamount = credit,
  --    balancedue = feeamt - credit, paidamount = 0). classfeedemand read-only.
  FOR cf IN EXECUTE format($q$
      SELECT c.cf_id, c.cfterm, c.cffeetype, c.cfdduedate, c.collectible,
             c.cla_id, c.sem_id, c.fee_id,
             (it->>'feeamt')::numeric AS feeamt,
             COALESCE((it->>'credit')::numeric, 0) AS credit
      FROM jsonb_array_elements($1::jsonb) it
      JOIN %I.classfeedemand c ON c.cf_id = (it->>'cf_id')::int
      WHERE (it->>'feeamt')::numeric > 0
      ORDER BY c.cf_id
    $q$, v) USING p_credits
  LOOP
    -- Concession = old paid + old concession carried (client capped at the fee).
    v_credit := LEAST(GREATEST(cf.credit, 0), cf.feeamt);
    v_applied := v_applied + v_credit;
    v_remaining := GREATEST(v_remaining - v_credit, 0);

    EXECUTE format($i$
      INSERT INTO %I.feedemand
        (demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, demfeeyear, demfeeterm, demfeetype,
         feeamount, con_id, conamount, paidamount, balancedue, reconbalancedue, duedate, paidstatus,
         createdby, activestatus, collectible, cla_id, sem_id, fee_id, cf_id, courname)
      VALUES ('REGULAR',$1,$2,$3,$4,$5,$6,$7,$8,$9,
              $10,$11,$12,0,GREATEST($10-$12,0),GREATEST($10-$12,0),$13,
              CASE WHEN $10-$12<=0 THEN 'P' ELSE 'U' END,
              $14,1,$15,$16,$17,$18,$19,$20)
    $i$, v)
    -- collectible is forced TRUE, not inherited from classfeedemand: that column
    -- defaults to FALSE, and these demands are the fees the operator explicitly
    -- ticked and priced on the Adjust Fees page. Inheriting false made them
    -- invisible to Fee Collection, so the student could never pay them.
    USING p_ins_id, v_inscode, v_yr_id, p_stu_id, v_stuadmno, p_target_class, v_yrlabel, cf.cfterm, cf.cffeetype,
          cf.feeamt, v_con_id, v_credit, cf.cfdduedate, p_created_by, true,
          cf.cla_id, cf.sem_id, cf.fee_id, cf.cf_id, p_target_course;
    v_new_count := v_new_count + 1;
  END LOOP;

  -- 4) Log the transfer (with the ORIGINAL course/class). One row per student
  --    per date: a second transfer on the same day UPDATES that day's row
  --    instead of adding a duplicate (the VB frmClassTransfer rule — studhist
  --    is keyed on studid + tdate).
  EXECUTE format($l$
    UPDATE %I.interim_promotion SET
      doc_no = $1, stuadmno = $5, courname = $6, stuclass = $7, stuname = $8,
      transferred_courname = $9, transferred_class = $10, remarks = $11,
      createdby = $12, activestatus = 1,
      admname = $13, transferred_admname = $14
    WHERE ins_id = $2 AND stu_id = $4 AND promotiondate = $3
  $l$, v)
  USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
        p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by,
        v_admname, COALESCE(v_new_admname, v_admname);
  GET DIAGNOSTICS v_log_rows = ROW_COUNT;
  IF v_log_rows = 0 THEN
    EXECUTE format($l$
      INSERT INTO %I.interim_promotion
        (doc_no, ins_id, promotiondate, stu_id, stuadmno, courname, stuclass, stuname,
         transferred_courname, transferred_class, remarks, createdby, activestatus,
         admname, transferred_admname)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,1,$13,$14)
    $l$, v)
    USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
          p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by,
          v_admname, COALESCE(v_new_admname, v_admname);
  END IF;

  RETURN jsonb_build_object('new_demands', v_new_count, 'applied', v_applied,
                            'old_paid', v_paid, 'leftover_credit', v_remaining);
END;
$$;

GRANT EXECUTE ON FUNCTION public.transfer_course_with_credit(
  integer, bigint, text, text, jsonb, integer, date, text, text, smallint
) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- FIX THE ROWS ALREADY STRANDED -- transfers done before this update left
-- their advances behind. This moves each one onto its student's current class.
-- It changes DATA, so read the BEFORE output first and run this only if the
-- count it printed is what you expect.
-- ############################################################################
DO $fix$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      UPDATE %I.advance_collection a
         SET stuclass = s.stuclass, courname = s.courname
        FROM %I.students s
       WHERE s.stu_id = a.stu_id
         AND (a.stuclass IS DISTINCT FROM s.stuclass
           OR a.courname IS DISTINCT FROM s.courname) $q$, r.s, r.s);
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '%: % advance row(s) moved', r.s, n;
  END LOOP;
END $fix$;


-- ############################################################################
-- VERIFY -- carries_the_advance_step must read t, and the count must be 0.
-- ############################################################################
SELECT p.prosrc LIKE '%advance_collection%' AS carries_the_advance_step
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'transfer_course_with_credit';

DO $after$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*) FROM %I.advance_collection a
        JOIN %I.students s ON s.stu_id = a.stu_id
       WHERE a.stuclass IS DISTINCT FROM s.stuclass
          OR a.courname IS DISTINCT FROM s.courname $q$, r.s, r.s) INTO n;
    RAISE NOTICE '%: % still mismatched (should be 0)', r.s, n;
  END LOOP;
END $after$;



-- ############################################################################
-- ############################################################################
--
--   PART 5 OF 7  --  Roll-number change reaches everything
--   source: migrations/ROLLNO_CHANGE_CASCADE.sql
--
--   advance_collection and misc_collection were missing from the cascade, so a
--   renumbered student left rows behind under a number that names nobody.
--   Includes a repair for rows already stranded.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- EduCore360 -- ROLL-NUMBER CHANGE MUST REACH ADVANCES AND MISC RECEIPTS
-- 19-09-2026
--
-- public.save_rollno_change renames the student and then cascades the new
-- number to every table that stores it. Two were missing:
--
--   * <schema>.advance_collection.stuadmno
--   * <schema>.misc_collection.regno      (same number, different column name,
--                                          so it could not ride the loop)
--
-- A roll number is an IDENTITY, not a historical attribute. Once it changes
-- the old one names nobody, so a row left behind under it cannot be found --
-- and in the case of an advance, money is still sitting on it.
--
-- Every tenant table that carries a roll number was checked; after this the
-- list is complete:
--     students, feedemand, tempfeedemand, concession, concessiondetail,
--     fee_refund, parentdetail, tc_entry, interim_promotion,
--     advance_collection, misc_collection, public.admission.
--   * student_import is deliberately left out -- it is the raw import staging
--     table, not a record of the student.
--   * payment, paymentdetails and advadjustment key on stu_id and hold no roll
--     number, so nothing on them can go stale.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE, one function, no data change of its own.
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- rows whose roll number no longer matches the student's.
-- These are the ones already stranded by earlier roll-number changes.
-- ############################################################################
DO $before$
DECLARE r RECORD; n_adv int; n_misc int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    n_adv := 0; n_misc := 0;
    BEGIN
      EXECUTE format($q$
        SELECT count(*) FROM %I.advance_collection a
          JOIN %I.students s ON s.stu_id = a.stu_id
         WHERE a.stuadmno IS DISTINCT FROM s.stuadmno $q$, r.s, r.s) INTO n_adv;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    BEGIN
      EXECUTE format($q$
        SELECT count(*) FROM %I.misc_collection m
          JOIN %I.students s ON s.stu_id = m.stu_id
         WHERE m.regno IS DISTINCT FROM s.stuadmno $q$, r.s, r.s) INTO n_misc;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    RAISE NOTICE '%: % advance row(s), % misc receipt(s) under an old roll number',
                 r.s, n_adv, n_misc;
  END LOOP;
END $before$;


-- ############################################################################
-- THE FUNCTION
-- ############################################################################
CREATE OR REPLACE FUNCTION public.save_rollno_change(
  p_token text, p_effectdate date, p_rows jsonb, p_createdby text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10);
  itm RECORD; v_count int := 0; v_exists boolean; v_tbl text;
  v_stuid bigint; v_stuname text; v_stuclass text; v_claid smallint;
  v_old text; v_new text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;

  FOR itm IN SELECT * FROM jsonb_to_recordset(p_rows) AS x(oldrollno text, newrollno text)
  LOOP
    v_old := TRIM(COALESCE(itm.oldrollno, ''));
    v_new := TRIM(COALESCE(itm.newrollno, ''));
    CONTINUE WHEN v_new = '' OR v_old = '' OR v_new = v_old;

    EXECUTE format('SELECT stu_id, stuname, stuclass, cla_id FROM %I.students WHERE ins_id=$1 AND stuadmno=$2 LIMIT 1', v_schema)
      INTO v_stuid, v_stuname, v_stuclass, v_claid USING v_ins, v_old;
    IF v_stuid IS NULL THEN CONTINUE; END IF;

    -- the new number must be free (students + admission both have UNIQUE on it)
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.students WHERE ins_id=$1 AND stuadmno=$2 AND stu_id<>$3)', v_schema)
      INTO v_exists USING v_ins, v_new, v_stuid;
    IF v_exists THEN RAISE EXCEPTION 'Roll number % is already in use by another student', v_new; END IF;
    -- ...including a pending admission that has not been allocated yet, which
    -- would otherwise break the admission UNIQUE(ins_id, admno) mid-cascade.
    SELECT EXISTS(SELECT 1 FROM public.admission WHERE ins_id = v_ins AND admno = v_new)
      INTO v_exists;
    IF v_exists THEN RAISE EXCEPTION 'Roll number % is already used by an admission record', v_new; END IF;

    -- No once-per-day limit: correcting a number the same day is normal, and
    -- every step is logged below, so the trail stays complete. The checks that
    -- matter -- that the new number is not already taken by another student or
    -- a pending admission -- are above and still enforced.

    -- master row
    EXECUTE format('UPDATE %I.students SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema)
      USING v_new, v_ins, v_old;
    -- every table keyed by stuadmno (skipped if a legacy schema lacks one)
    --
    -- advance_collection was missing from this list. A roll number is an
    -- IDENTITY, not a historical attribute: once it changes, the old one names
    -- nobody, and an advance left under it cannot be found by the screens --
    -- which look the student up by roll number -- while money is still on it.
    FOREACH v_tbl IN ARRAY ARRAY['feedemand','tempfeedemand','concession','concessiondetail',
                                 'fee_refund','parentdetail','tc_entry','interim_promotion',
                                 'advance_collection'] LOOP
      BEGIN
        EXECUTE format('UPDATE %I.%I SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema, v_tbl)
          USING v_new, v_ins, v_old;
      EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
      END;
    END LOOP;
    -- misc_collection holds the same number under a different name (regno), so
    -- it cannot ride the loop above.
    BEGIN
      EXECUTE format('UPDATE %I.misc_collection SET regno=$1 WHERE ins_id=$2 AND regno=$3', v_schema)
        USING v_new, v_ins, v_old;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    -- the shared admission row links by admno = stuadmno
    UPDATE public.admission SET admno = v_new WHERE ins_id = v_ins AND admno = v_old;

    INSERT INTO public.rollno_change(ins_id, inscode, stu_id, oldrollno, newrollno,
                                     stuname, stuclass, cla_id, effectdate, createdby)
    VALUES (v_ins, v_inscode, v_stuid, v_old, v_new,
            v_stuname, v_stuclass, v_claid, p_effectdate, p_createdby);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_rollno_change(text, date, jsonb, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- FIX THE ROWS ALREADY STRANDED -- roll-number changes made before this update
-- left these behind. Matched by stu_id, which never changes.
-- It changes DATA, so read the BEFORE output first and run this only if the
-- counts it printed are what you expect.
-- ############################################################################
DO $fix$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    BEGIN
      EXECUTE format($q$
        UPDATE %I.advance_collection a SET stuadmno = s.stuadmno
          FROM %I.students s
         WHERE s.stu_id = a.stu_id AND a.stuadmno IS DISTINCT FROM s.stuadmno $q$,
        r.s, r.s);
      GET DIAGNOSTICS n = ROW_COUNT;
      RAISE NOTICE '%: % advance row(s) renumbered', r.s, n;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    BEGIN
      EXECUTE format($q$
        UPDATE %I.misc_collection m SET regno = s.stuadmno
          FROM %I.students s
         WHERE s.stu_id = m.stu_id AND m.regno IS DISTINCT FROM s.stuadmno $q$,
        r.s, r.s);
      GET DIAGNOSTICS n = ROW_COUNT;
      RAISE NOTICE '%: % misc receipt(s) renumbered', r.s, n;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
  END LOOP;
END $fix$;


-- ############################################################################
-- VERIFY -- both flags must read t, and the counts above must be 0.
-- ############################################################################
SELECT p.prosrc LIKE '%advance_collection%' AS cascades_to_advances,
       p.prosrc LIKE '%misc_collection SET regno%' AS cascades_to_misc
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_rollno_change';



-- ############################################################################
-- ############################################################################
--
--   PART 6 OF 7  --  Pre-admission
--   source: migrations/PREADMISSION.sql
--
--   Seat booked now, studies from next year: the flag, no fee demand this
--   year, no class promotion at the year change, and the unspent advance
--   carried into the new year. Its copy of get_consolidated_status_report is
--   the newest one -- it carries BOTH the TC filter from part 2 and the
--   class-strength fix, which is why this part runs after that one.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- EduCore360 -- PRE-ADMISSION (seat booked now, studies from next year)
-- 19-09-2026
--
-- A student admitted during THIS year who will only start NEXT year. The
-- institution takes an admission collection from them now to hold the seat.
--
-- Two facts follow from that, and this file makes the database obey both:
--
--   1. They owe nothing this year. No fee demand is raised for them.
--   2. They DO NOT MOVE UP a class at the year change. The coming year is
--      their first, so they start in the class they were admitted to --
--      promoting them would make a first-year a second-year on day one.
--
-- And the money follows them: an unspent advance is carried into the new
-- year's schema, at its remaining balance, so the deposit can be adjusted
-- against the fees it was taken for.
--
-- WHAT CHANGES
--   * public.admission          + preadmission smallint (0/1)
--   * <schema>.students         + preadmission smallint (0/1)
--   * create_institution_schema   new schemas get the column
--   * allocate_admission_to_student  copies the flag onto the student
--   * generate_feedemand_for_class   skips pre-admission students
--   * rollover_academic_year         keeps their class, clears the flag in the
--                                    new year, and carries unspent advances
--
-- save_admission needs no change: it copies whatever columns public.admission
-- has, so the app sets the flag just by sending it.
--
-- SAFE TO RE-RUN. The columns are ADD COLUMN IF NOT EXISTS and default to 0,
-- so every existing student is an ordinary one; the functions are CREATE OR
-- REPLACE. No row changes meaning.
--
-- NOTE ON THE ROLLOVER: rollover_academic_year is still not called by the app
-- (the New Year button only creates an empty schema) and has other known
-- defects -- see docs/YEAR_ROLLOVER_DESIGN.md. This file changes only the two
-- things pre-admission needs; it is not the rollover repair.
--
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- 1 -- THE COLUMN, on the shared admission table and on every year schema
-- ############################################################################
ALTER TABLE public.admission
  ADD COLUMN IF NOT EXISTS preadmission smallint DEFAULT 0 NOT NULL;

DO $cols$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS '
                   'preadmission smallint DEFAULT 0 NOT NULL', r.s);
    RAISE NOTICE '%.students: preadmission present', r.s;
  END LOOP;
END $cols$;


-- ############################################################################
-- 2 -- NEW SCHEMAS GET IT TOO
-- ############################################################################
CREATE OR REPLACE FUNCTION public.create_institution_schema(
  p_schema_name text,
  p_ins_id integer DEFAULT NULL,
  p_year_label text DEFAULT NULL,
  p_start_date date DEFAULT NULL,
  p_end_date date DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_schema text := lower(p_schema_name); v_inscode varchar(10);
BEGIN
  -- Get inscode for year record
  IF p_ins_id IS NOT NULL THEN
    SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = p_ins_id;
  END IF;
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);

  -- year
  EXECUTE format('CREATE TABLE %I.year (yr_id integer NOT NULL PRIMARY KEY, ins_id integer NOT NULL, yrlabel varchar(9) NOT NULL, yrstadate date NOT NULL, yrenddate date NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- students
  -- students — `aadharno + community/caste/religion/nationality/transportmode/hostel`
  -- columns are carried over from public.admission during class allocation.
  EXECUTE format('CREATE TABLE %I.students (stu_id bigint NOT NULL PRIMARY KEY CHECK (stu_id > 0), ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, stuadmno varchar(25) NOT NULL, stuadmdate date NOT NULL, stuname varchar(50) NOT NULL, stugender char(1) NOT NULL CHECK (stugender = ANY(ARRAY[''M'',''F'',''T''])), studob date NOT NULL, stumobile varchar(30), stuemail varchar(254), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stugeocoordinates varchar(40), stubloodgrp varchar(20), stuphoto text, stuclass varchar(20) NOT NULL, cour_id integer, admit_cour_id smallint, courname varchar(20), con_id integer, stucondesc varchar(20), stuser_id varchar(25) NOT NULL, stupassword varchar(255), stumobotp numeric(6,0), stuotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now() NOT NULL, suspendeddate date, suspendedby varchar(50), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,3,4,5,9])), createdon timestamp DEFAULT now() NOT NULL, terminatedreason text, batch varchar(9), preadmission smallint DEFAULT 0 NOT NULL CHECK (preadmission = ANY(ARRAY[0,1])), admname varchar(30), quoname varchar(30), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), emisno varchar(30), umisno varchar(30), scholarship char(1), scholarshiptype varchar(60), medium varchar(30), cla_id smallint, adm_id smallint, quo_id smallint)', v_schema);
  -- No UNIQUE on stuemail: students commonly share or lack an email (bulk import
  -- of hundreds would fail on the first shared/placeholder address).
  EXECUTE format('ALTER TABLE %I.students ADD CONSTRAINT uq_students_admission UNIQUE (ins_id, stuadmno)', v_schema);

  -- parents
  EXECUTE format('CREATE TABLE %I.parents (par_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), partype char(1) NOT NULL CHECK (partype = ANY(ARRAY[''P'',''G''])), paremail varchar(254), fathername varchar(50), mothername varchar(50), guardianname varchar(50), fathermobile varchar(20), mothermobile varchar(20), guardianmobile varchar(20), fatheroccupation varchar(60), motheroccupation varchar(60), guardianoccupation varchar(60), payincharge varchar(50) NOT NULL, payinchargemob varchar(20) NOT NULL, parpassword varchar(255), parmobotp numeric(6,0), parmobotp_at timestamp, parotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now(), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,9])), ins_id integer)', v_schema);
  -- No UNIQUE on paremail: parents commonly share an email (siblings / one family
  -- email), so a bulk student import would fail on the first shared address.

  -- parentdetail
  EXECUTE format('CREATE TABLE %I.parentdetail (pd_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), par_id bigint NOT NULL, stu_id bigint NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, stuadmno varchar(20) NOT NULL UNIQUE, stuname varchar(50) NOT NULL, stuclass varchar(20) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- feedemand — `collectible=false` rows are recorded but never shown for
  -- collection; carried through from the classfeedemand template.
  EXECUTE format('CREATE TABLE %I.feedemand (dem_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, demseqtype varchar(20) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, paidamount numeric(12,2) DEFAULT 0, fineamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) CHECK (balancedue >= 0), reconbalancedue numeric(12,2) DEFAULT 0, duedate date NOT NULL, pay_id integer, paidstatus char(1) DEFAULT ''U'' NOT NULL CHECK (paidstatus = ANY(ARRAY[''P'',''U''])), createdby varchar(50) NOT NULL, createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])), inactivedate timestamp, remarks varchar(50), fee_id integer, courname varchar(20), collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, cf_id integer, arrearclass varchar(30))', v_schema);

  -- tempfeedemand (staging — copied into feedemand by fn_approve_tempfeedemand on approval)
  EXECUTE format('CREATE TABLE %I.tempfeedemand (temp_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, courname varchar(20), demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2), duedate date NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), isapproved boolean DEFAULT false, collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, fee_id integer, cf_id integer, demseqtype varchar(20), arrearclass varchar(30))', v_schema);

  -- Demand generation + approval performance indexes. The dedup NOT EXISTS
  -- checks (generate_feedemand_from_template / _for_class) and the approval
  -- trigger's per-row feedemand lookup would otherwise sequential-scan and grow
  -- O(N^2) as feedemand fills, timing out on bulk generate/approve.
  EXECUTE format('CREATE INDEX idx_feedemand_dedup ON %I.feedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);
  EXECUTE format('CREATE INDEX idx_tempfeedemand_dedup ON %I.tempfeedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);
  EXECUTE format('CREATE INDEX idx_feedemand_demno_type ON %I.feedemand (ins_id, demno, demfeetype) WHERE activestatus = 1', v_schema);

  -- Approval trigger: copy temp → feedemand carrying the collectible flag.
  EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_dem_id bigint; v_paid numeric; v_net numeric; BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid FROM %1$I.feedemand WHERE ins_id = NEW.ins_id AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> '''' AND demno IS NOT DISTINCT FROM NEW.demno AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype AND activestatus = 1 ORDER BY dem_id LIMIT 1; IF v_dem_id IS NOT NULL THEN v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0); UPDATE %1$I.feedemand SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount, balancedue = v_net, reconbalancedue = v_net, duedate = NEW.duedate, collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id, demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass WHERE dem_id = v_dem_id; ELSE INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); END IF; NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER trg_tempfeedemand_approve BEFORE UPDATE OF isapproved ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.fn_approve_tempfeedemand()', v_schema, v_schema);

  -- feegroup
  EXECUTE format('CREATE TABLE %I.feegroup (fg_id integer NOT NULL PRIMARY KEY, fgdesc varchar(30) NOT NULL, ban_id integer, ins_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);

  -- feetype (feefineapplicable: 1 = fines apply when overdue, 0 = no fine)
  EXECUTE format('CREATE TABLE %I.feetype (fee_id integer NOT NULL PRIMARY KEY, feedesc varchar(30) NOT NULL, feeshort varchar(10) NOT NULL, feefineapplicable smallint DEFAULT 0, fg_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])), ins_id integer, type varchar(20), payseq smallint DEFAULT 100, partialallowed char(1) DEFAULT ''Y'')', v_schema);
  -- (feegroup_accountant removed — unused scaffold; no app or DB references.)
  EXECUTE format('ALTER TABLE %I.feetype ADD CONSTRAINT fk_feetype_feegroup FOREIGN KEY (fg_id) REFERENCES %I.feegroup(fg_id)', v_schema, v_schema);
  -- Lets PostgREST resolve embedded selects like feedemand?select=*,feetype(*) in the mobile app.
  EXECUTE format('ALTER TABLE %I.feedemand ADD CONSTRAINT fk_feedemand_feetype FOREIGN KEY (fee_id) REFERENCES %I.feetype(fee_id) NOT VALID', v_schema, v_schema);

  -- concessioncategory
  EXECUTE format('CREATE TABLE %I.concessioncategory (con_id integer NOT NULL PRIMARY KEY, condesc varchar(20) NOT NULL, ins_id integer NOT NULL, ordid integer, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])))', v_schema);

  -- course
  EXECUTE format('CREATE TABLE %I.course (cour_id integer NOT NULL PRIMARY KEY, courname varchar(100) NOT NULL, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- class
  EXECUTE format('CREATE TABLE %I.class (cla_id integer NOT NULL PRIMARY KEY, claname varchar(20) NOT NULL, ins_id integer, ordid smallint, succeedingclass integer, cour_id integer, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  -- succeedingclass is the cla_id of the next class in the promotion ladder
  -- (NULL for the terminal class). cour_id is optional / informational.

  -- admissiontype + quota + community + division + semester master lookups.
  -- (Register-number sequencing lives in the shared `sequence` table below,
  --  actname = 'REGNO' — not a separate regnoseq table anymore.)
  EXECUTE format('CREATE TABLE %I.admissiontype (adm_id smallint PRIMARY KEY, admname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  EXECUTE format('CREATE TABLE %I.quota (quo_id smallint PRIMARY KEY, quoname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  -- Community master (lookup for the admission form).
  EXECUTE format('CREATE TABLE %I.community (com_id smallint PRIMARY KEY, comname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  EXECUTE format('CREATE TABLE %I.division (div_id smallint PRIMARY KEY, divname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  -- (Register-number sequencing now lives in the shared `sequence` table below,
  --  actname = 'REGNO' — the separate regnoseq table has been retired.)
  -- Semester master (drives the demfeeterm dropdown in Fee Demand / Class Fee Demand).
  EXECUTE format('CREATE TABLE %I.semester (sem_id smallint PRIMARY KEY, semname varchar(30) NOT NULL, semshort varchar(10), semtype char(1) NOT NULL DEFAULT ''S'' CHECK (semtype IN (''S'',''M'',''Y'')), semstart date, semend date, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  -- classfeedemand — `collectible` carries the "ALL" tick from the template into
  -- each generated tempfeedemand/feedemand row.
  EXECUTE format('CREATE TABLE %I.classfeedemand (cf_id integer NOT NULL PRIMARY KEY, cfclass varchar(20), cfterm varchar(20), cffeetype varchar(30), cfamount numeric(12,2), cfdduedate date, admissiontype smallint, collectible boolean DEFAULT false NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, cla_id smallint, sem_id smallint, fee_id integer)', v_schema);

  -- NOTE: on-admission (per-student-insert) fee-demand auto-generation was
  -- reverted. There is deliberately no fn_gen_feedemand_on_student function or
  -- trg_gen_feedemand_on_student trigger here. Adding a student does NOT create
  -- demands. Generate them explicitly via generate_feedemand_for_class /
  -- generate_feedemand_from_template (or the Fee Demand screen).

  -- finerule (overdue fine slabs configured by admin)
  EXECUTE format('CREATE TABLE %I.finerule (fr_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, rulename varchar(50) NOT NULL, feetype varchar(30) DEFAULT ''ALL'', from_days integer NOT NULL, to_days integer, fine_type varchar(10) DEFAULT ''FIXED'' CHECK (fine_type IN (''FIXED'',''PERCENT'')), fine_value numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);


  -- payment
  EXECUTE format('CREATE TABLE %I.payment (pay_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), transtotalamount numeric(12,2) NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paydate timestamp, paystatus char(1) CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), paygwresponse numeric(15,0), payitems text, createdby varchar(100), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, paynumber varchar(30) UNIQUE, payorderid varchar(100), notification_read boolean DEFAULT false, paychequeno varchar(50), paychequedate date, paybankname varchar(100), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, ban_id integer, tender_amount numeric(12,2), refund_amount numeric(12,2), voidedby varchar(100), voideddate timestamp, voidreason varchar(255))', v_schema);

  -- bank: per-institution beneficiary account list. Fee groups are
  -- tagged with ban_id so a single payment can be split (mock for now —
  -- real splits later via Razorpay Route or virtual accounts).
  EXECUTE format('CREATE TABLE %I.bank (ban_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer, banname varchar(45) NOT NULL, banbranch varchar(80) NOT NULL, ifsccode varchar(15) NOT NULL, banaddress1 varchar(50) NOT NULL, banaddress2 varchar(50), banaddress3 varchar(50), banmobile varchar(15), banemail varchar(60), banaccno varchar(20) NOT NULL, banaccholder varchar(50) NOT NULL, paytm_mid varchar(40), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);
  EXECUTE format('ALTER TABLE %I.feegroup ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_feegroup_bank', v_schema);
  EXECUTE format('ALTER TABLE %I.payment ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_payment_bank', v_schema);

  -- paymentdetails
  EXECUTE format('CREATE TABLE %I.paymentdetails (pyd_id bigint NOT NULL PRIMARY KEY, pay_id bigint NOT NULL, dem_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), ins_id integer NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- paymentgateway
  EXECUTE format('CREATE TABLE %I.paymentgateway (gw_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, gwname varchar(100) NOT NULL, gwapikey varchar(255), gwapisecret varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- interim_promotion (mid-year move of a single student to another class;
  -- keeps the before/after course+class for audit)
  EXECUTE format('CREATE TABLE %I.interim_promotion (ip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no integer NOT NULL, ins_id integer NOT NULL, promotiondate date NOT NULL, stu_id bigint, stuadmno varchar(25), stuname varchar(50), courname varchar(20), stuclass varchar(20), admname varchar(30), transferred_courname varchar(20), transferred_class varchar(20), transferred_admname varchar(30), remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE INDEX idx_interim_promotion_stu ON %I.interim_promotion (ins_id, stu_id)', v_schema);

  -- fee_refund (refund voucher header; one row per refund raised against a receipt/payment)
  EXECUTE format('CREATE TABLE %I.fee_refund (rf_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), refunddate date NOT NULL, pay_id bigint, paynumber varchar(30), stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), refundmode varchar(20) NOT NULL, ban_id integer, bankname varchar(100), bankref varchar(100), chequedate date, accountcode varchar(50), refundreason varchar(200), totalrefund numeric(12,2) DEFAULT 0, totaladjust numeric(12,2) DEFAULT 0, createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- fee_refunddetails (per fee-line breakdown of a refund voucher; dem_id references this schema''s feedemand by value)
  EXECUTE format('CREATE TABLE %I.fee_refunddetails (rfd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, rf_id bigint NOT NULL, dem_id bigint, ins_id integer NOT NULL, refundterm varchar(20), refundfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, refundamount numeric(12,2) DEFAULT 0, adjustamount numeric(12,2) DEFAULT 0, adjustreason varchar(200), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- concession (concession voucher header; one row per concession applied to a student) + concessiondetail (per fee-line breakdown). Written only via process_concession(). See migrations/add_concession_tables.sql.
  EXECUTE format('CREATE TABLE %I.concession (con_hdr_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30), ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), condate date NOT NULL DEFAULT CURRENT_DATE, stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), con_id integer, contype varchar(30), totalfee numeric(12,2) DEFAULT 0, totalconcession numeric(12,2) DEFAULT 0, totalbalance numeric(12,2) DEFAULT 0, remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE TABLE %I.concessiondetail (cond_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, con_hdr_id bigint NOT NULL, ins_id integer NOT NULL, stu_id bigint, stuadmno varchar(25), receiptno varchar(30), dem_id bigint, demfeeterm varchar(20), demfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) DEFAULT 0, con_id integer, contype varchar(30), condate date, createdby varchar(50), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE INDEX idx_concession_stu ON %I.concession (ins_id, stu_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_concessiondetail_hdr ON %I.concessiondetail (con_hdr_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_concessiondetail_stu ON %I.concessiondetail (ins_id, stu_id)', v_schema);

  -- misc_collection (standalone counter collection: BONAFIDE, APPLICATION, …).
  -- Does NOT touch feedemand. selection ''S'' = registered student, ''O'' = others.
  -- Receipt number (mcno) is drawn from the shared fee-receipt sequence.
  EXECUTE format('CREATE TABLE %I.misc_collection (mc_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), mcno varchar(30) NOT NULL, mcdate date NOT NULL DEFAULT CURRENT_DATE, selection char(1) NOT NULL DEFAULT ''S'' CHECK (selection IN (''S'',''O'')), stu_id bigint, regno varchar(25), stuclass varchar(30), stuname varchar(100) NOT NULL, courname varchar(20), city varchar(50), address varchar(255), paymode varchar(20) DEFAULT ''Cash'', ban_id integer, bankname varchar(100), transrefno varchar(50), paytm_txnid varchar(60), draweebank varchar(100), transdate date, transamt numeric(12,2), collectedby varchar(50), remarks varchar(255), totalamount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamptz, bank_reference varchar(100), bank_date date, paystatus char(1) DEFAULT ''C'', voidedby varchar(100), voideddate timestamptz, voidreason varchar(255))', v_schema);
  EXECUTE format('CREATE TABLE %I.misc_collection_detail (mcd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, mc_id bigint NOT NULL, ins_id integer NOT NULL, fee_id integer, feetype varchar(30) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE INDEX idx_misc_detail_mc ON %I.misc_collection_detail (mc_id)', v_schema);

  -- advance_collection (money taken BEFORE any fee is due). Mirrors `payment`'s
  -- money/reconcile columns but carries NO fg_id / fee_id -- an advance is just
  -- an amount held against the student. It is later applied to specific fee
  -- demands ("adjusted"), which advadjustment records. Receipt number (advno)
  -- comes from the schema's own sequence, actname='ADVNO' (Fee Master ->
  -- Advance No). balanceamount is GENERATED, so it can never drift from its
  -- parts. See migrations/add_advance_collection.sql.
  EXECUTE format('CREATE TABLE %I.advance_collection (adv_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id bigint NOT NULL, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), yr_id integer, yrlabel varchar(20), advno varchar(30) NOT NULL, advdate timestamp DEFAULT now() NOT NULL, advtype char(1) DEFAULT ''S'' NOT NULL CHECK (advtype = ANY(ARRAY[''A'',''S''])), transtotalamount numeric(12,2) NOT NULL CHECK (transtotalamount > 0), adjustedamount numeric(12,2) DEFAULT 0 NOT NULL, refund_amount numeric(12,2) DEFAULT 0 NOT NULL, balanceamount numeric(12,2) GENERATED ALWAYS AS (transtotalamount - adjustedamount - refund_amount) STORED, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paystatus char(1) DEFAULT ''C'' NOT NULL CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), payorderid varchar(100), paytm_txnid varchar(60), paychequeno varchar(50), paychequedate date, paybankname varchar(100), ban_id integer, recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, tender_amount numeric(12,2), remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, voidedby varchar(100), voideddate timestamp, voidreason varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE UNIQUE INDEX uq_advance_advno ON %I.advance_collection (ins_id, advno)', v_schema);
  EXECUTE format('CREATE INDEX idx_advance_stu ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1', v_schema);
  -- Drives "students with an unused advance" (the Fee Collection highlight).
  EXECUTE format('CREATE INDEX idx_advance_open ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1 AND balanceamount > 0', v_schema);

  -- advance_detail: the fee-type breakdown of an ADMISSION advance
  -- (advtype ''A''). Mirrors misc_collection_detail. A student advance
  -- (advtype ''S'') is a plain amount and has no rows here at all.
  -- feetype is varchar(60), not misc''s 30: real fee names run long.
  EXECUTE format('CREATE TABLE %I.advance_detail (advd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, fee_id integer, fg_id integer, feetype varchar(60) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);
  EXECUTE format('CREATE INDEX idx_advance_detail_adv ON %I.advance_detail (adv_id)', v_schema);

  -- advadjustment: one row per amount moved off an advance onto a fee demand,
  -- with the fee receipt that settlement raised.
  EXECUTE format('CREATE TABLE %I.advadjustment (adj_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, stu_id bigint, dem_id bigint, pay_id bigint, paynumber varchar(30), demfeeterm varchar(20), demfeetype varchar(30), adjustamount numeric(12,2) NOT NULL CHECK (adjustamount > 0), adjustdate date DEFAULT CURRENT_DATE NOT NULL, remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);
  EXECUTE format('CREATE INDEX idx_advadjustment_adv ON %I.advadjustment (adv_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_advadjustment_dem ON %I.advadjustment (ins_id, dem_id)', v_schema);

  -- sequence: unified numbering for BOTH fee-receipt sequences (fg_id set,
  -- actname = fee-group name) AND admission/register-number sequences
  -- (fg_id NULL, actname = 'REGNO'; the seqend + division columns apply only to
  -- register sequences). Register numbers replace the old separate regnoseq table.
  EXECUTE format('CREATE TABLE %I.sequence (seq_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, mod_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, actname varchar(30) NOT NULL, seqname varchar(50) NOT NULL, isprefix char(1) NOT NULL, seqprefix varchar(15) NOT NULL, seqstart numeric(9,0) NOT NULL, seqwidth numeric(2,0) NOT NULL, sequid varchar(18) NOT NULL, seqcurno numeric(9,0) NOT NULL, seqend numeric(9,0), division varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, fg_id integer)', v_schema);

  -- shoppingcart
  EXECUTE format('CREATE TABLE %I.shoppingcart (car_id integer NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, stu_id bigint NOT NULL, transtype varchar(10) NOT NULL, transdate date DEFAULT CURRENT_DATE NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, carinitiated char(1) DEFAULT ''N'' NOT NULL, createdby varchar(50) NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE UNIQUE INDEX unique_active_cart_per_student ON %I.shoppingcart (stu_id) WHERE activestatus = 1', v_schema);

  -- shoppingcartdetails
  EXECUTE format('CREATE TABLE %I.shoppingcartdetails (cd_id integer NOT NULL PRIMARY KEY, car_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, dem_id bigint NOT NULL, transdetail_id integer, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- notice
  EXECUTE format('CREATE TABLE %I.notice (notice_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, noticetitle text NOT NULL, noticedesc text, noticepriority varchar(20) DEFAULT ''Normal'', noticecategory varchar(50) DEFAULT ''General'', noticetarget text, createdby varchar(50), createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1, noticefromdate date, noticetodate date)', v_schema);
  EXECUTE format('CREATE INDEX idx_notice_ins_id ON %I.notice (ins_id)', v_schema);

  -- notification
  EXECUTE format('CREATE TABLE %I.notification (noti_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, stu_id integer, notice_id bigint, notititle text, notibody text, notitype varchar(50), isread integer DEFAULT 0, createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1)', v_schema);
  EXECUTE format('CREATE INDEX idx_notification_notice_id ON %I.notification(notice_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_notification_ins_id ON %I.notification (ins_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_notification_stu_id ON %I.notification (stu_id)', v_schema);

  -- userlogin
  EXECUTE format('CREATE TABLE %I.userlogin (ul_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), uluser varchar(50), ulusetype smallint, ultime timestamp, ulattempt smallint DEFAULT 0, ulip varchar(40), ullocation varchar(50), ulsuccess char(1) DEFAULT ''N'' NOT NULL, ulsesid numeric, ulsesstart timestamp DEFAULT now() NOT NULL, ulsesend timestamp, ulsestime timestamp)', v_schema);


  -- student_import
  EXECUTE format('CREATE TABLE %I.student_import (imp_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), stuadmno varchar(25) NOT NULL, stuname varchar(50) NOT NULL, stugender char(1), studob date, stuadmdate date, stuclass varchar(20) NOT NULL, courname varchar(20), stumobile varchar(30), stuemail varchar(254), concession varchar(50), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stubloodgrp varchar(20), fathername varchar(50), fathermobile varchar(30), fatheroccupation varchar(50), mothername varchar(50), mothermobile varchar(30), motheroccupation varchar(50), guardianname varchar(50), guardianmobile varchar(30), guardianoccupation varchar(50), payincharge varchar(50), payinchargemob varchar(30), admname varchar(50), quoname varchar(50), batch varchar(9), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), paremail varchar(254), cla_id smallint, cour_id integer, admit_cour_id smallint, medium varchar(30), adm_id smallint, quo_id smallint, status varchar(10) DEFAULT ''PENDING'', error_msg text, created_at timestamp DEFAULT now())', v_schema);

  -- FOREIGN KEYS
  EXECUTE format('ALTER TABLE %I.paymentdetails ADD CONSTRAINT fk_paymentdetails_payment FOREIGN KEY (pay_id) REFERENCES %I.payment(pay_id)', v_schema, v_schema);
  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_car_id_fkey FOREIGN KEY (car_id) REFERENCES %I.shoppingcart(car_id)', v_schema, v_schema);
  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_dem_id_fkey FOREIGN KEY (dem_id) REFERENCES %I.feedemand(dem_id)', v_schema, v_schema);

  -- ============================================
  -- TRIGGER FUNCTIONS (per schema)
  -- ============================================

  -- Auto-increment triggers for all tables
  EXECUTE format('CREATE FUNCTION %I.set_yr_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.yr_id IS NULL OR NEW.yr_id = 0 THEN NEW.yr_id := COALESCE((SELECT MAX(yr_id) FROM %I.year), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_year_yr_id BEFORE INSERT ON %I.year FOR EACH ROW EXECUTE FUNCTION %I.set_yr_id()', v_schema, v_schema);

  -- students: sequence-backed id, no hardcoded storage URL (photos resolved client-side)
  EXECUTE format('CREATE SEQUENCE %I.students_stu_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_stu_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stu_id IS NULL OR NEW.stu_id = 0 THEN NEW.stu_id := nextval(''%I.students_stu_id_seq''); END IF; IF (NEW.cour_id IS NULL OR NEW.cour_id = 0) AND NEW.courname IS NOT NULL AND TRIM(NEW.courname) != '''' THEN SELECT c.cour_id INTO NEW.cour_id FROM %I.course c WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM(NEW.courname)) AND c.ins_id = NEW.ins_id LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_students_before_insert BEFORE INSERT ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.set_stu_id()', v_schema, v_schema);

  -- parents: sequence-backed id
  EXECUTE format('CREATE SEQUENCE %I.parents_par_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_par_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.par_id IS NULL OR NEW.par_id = 0 THEN NEW.par_id := nextval(''%I.parents_par_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_parents_before_insert BEFORE INSERT ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.set_par_id()', v_schema, v_schema);

  -- parentdetail: sequence-backed id
  EXECUTE format('CREATE SEQUENCE %I.parentdetail_pd_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_pd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pd_id IS NULL OR NEW.pd_id = 0 THEN NEW.pd_id := nextval(''%I.parentdetail_pd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_parentdetail_auto_id BEFORE INSERT ON %I.parentdetail FOR EACH ROW EXECUTE FUNCTION %I.set_pd_id()', v_schema, v_schema);

  -- feedemand uses a real sequence (bulk import path — must be O(1) per row)
  EXECUTE format('CREATE SEQUENCE %I.feedemand_dem_id_seq', v_schema);
  EXECUTE format($f$CREATE FUNCTION %I.set_dem_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.dem_id IS NULL OR NEW.dem_id = 0 THEN NEW.dem_id := nextval('%I.feedemand_dem_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.dem_id::TEXT, 5, '0'); END IF; END IF; IF NEW.demseqtype IS NULL OR TRIM(NEW.demseqtype) = '' THEN NEW.demseqtype := 'DEMAND'; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.demfeetype IS NOT NULL THEN SELECT ft.fee_id INTO NEW.fee_id FROM %I.feetype ft WHERE ft.feedesc = NEW.demfeetype AND ft.activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_feedemand_before_insert BEFORE INSERT ON %I.feedemand FOR EACH ROW EXECUTE FUNCTION %I.set_dem_id()', v_schema, v_schema);

  -- tempfeedemand uses a real sequence (bulk import path — must be O(1) per row)
  EXECUTE format('CREATE SEQUENCE %I.tempfeedemand_temp_id_seq', v_schema);
  EXECUTE format($f$CREATE FUNCTION %I.set_temp_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.temp_id IS NULL THEN NEW.temp_id := nextval('%I.tempfeedemand_temp_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.temp_id::TEXT, 5, '0'); END IF; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_temp_id BEFORE INSERT ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_temp_id()', v_schema, v_schema);

  -- Master-table auto-increment sequences. The NULL/0 guard lets callers
  -- supply an explicit id (needed when importing master data from a legacy
  -- system); a plain INSERT without the column gets nextval().
  EXECUTE format('CREATE SEQUENCE %I.feegroup_fg_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_fg_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fg_id IS NULL OR NEW.fg_id = 0 THEN NEW.fg_id := nextval(''%I.feegroup_fg_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_feegroup_fg_id BEFORE INSERT ON %I.feegroup FOR EACH ROW EXECUTE FUNCTION %I.set_fg_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.feetype_fee_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_fee_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fee_id IS NULL OR NEW.fee_id = 0 THEN NEW.fee_id := nextval(''%I.feetype_fee_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_feetype_fee_id BEFORE INSERT ON %I.feetype FOR EACH ROW EXECUTE FUNCTION %I.set_fee_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.concessioncategory_con_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_con_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.con_id IS NULL OR NEW.con_id = 0 THEN NEW.con_id := nextval(''%I.concessioncategory_con_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_concession_con_id BEFORE INSERT ON %I.concessioncategory FOR EACH ROW EXECUTE FUNCTION %I.set_con_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.course_cour_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_cour_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cour_id IS NULL OR NEW.cour_id = 0 THEN NEW.cour_id := nextval(''%I.course_cour_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_course_cour_id BEFORE INSERT ON %I.course FOR EACH ROW EXECUTE FUNCTION %I.set_cour_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.class_cla_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_cla_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cla_id IS NULL OR NEW.cla_id = 0 THEN NEW.cla_id := nextval(''%I.class_cla_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_class_cla_id BEFORE INSERT ON %I.class FOR EACH ROW EXECUTE FUNCTION %I.set_cla_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.classfeedemand_cf_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_cf_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cf_id IS NULL THEN NEW.cf_id := nextval(''%I.classfeedemand_cf_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_classfeedemand_cf_id BEFORE INSERT ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_cf_id()', v_schema, v_schema);
  -- Resolve cla_id / sem_id / fee_id from the cfclass / cfterm / cffeetype names
  -- on insert/update (schema-qualified, so it works from the session-gated RPCs).
  EXECUTE format('CREATE OR REPLACE FUNCTION %I.set_classfee_ids() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF (NEW.cla_id IS NULL OR NEW.cla_id = 0) AND NEW.cfclass IS NOT NULL THEN SELECT cla_id INTO NEW.cla_id FROM %I.class WHERE claname = NEW.cfclass AND activestatus = 1 LIMIT 1; END IF; IF (NEW.sem_id IS NULL OR NEW.sem_id = 0) AND NEW.cfterm IS NOT NULL THEN SELECT sem_id INTO NEW.sem_id FROM %I.semester WHERE semname = NEW.cfterm AND activestatus = 1 LIMIT 1; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.cffeetype IS NOT NULL THEN SELECT fee_id INTO NEW.fee_id FROM %I.feetype WHERE feedesc = NEW.cffeetype AND activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_classfeedemand_ids BEFORE INSERT OR UPDATE ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_classfee_ids()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.payment_pay_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %1$I.set_pay_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_next bigint; BEGIN IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN PERFORM pg_advisory_xact_lock(hashtext(%1$L)::bigint); SELECT COALESCE(MAX(pay_id),0) + 1 INTO v_next FROM %1$I.payment; NEW.pay_id := v_next; END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER trg_payment_auto_increment BEFORE INSERT ON %I.payment FOR EACH ROW EXECUTE FUNCTION %I.set_pay_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.paymentdetails_pyd_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_pyd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pyd_id IS NULL OR NEW.pyd_id = 0 THEN NEW.pyd_id := nextval(''%I.paymentdetails_pyd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_paymentdetails_auto_increment BEFORE INSERT ON %I.paymentdetails FOR EACH ROW EXECUTE FUNCTION %I.set_pyd_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_car_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.car_id := COALESCE((SELECT MAX(car_id) FROM %I.shoppingcart), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_generate_car_id BEFORE INSERT ON %I.shoppingcart FOR EACH ROW EXECUTE FUNCTION %I.set_car_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.cd_id := COALESCE((SELECT MAX(cd_id) FROM %I.shoppingcartdetails), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_generate_cd_id BEFORE INSERT ON %I.shoppingcartdetails FOR EACH ROW EXECUTE FUNCTION %I.set_cd_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_notice_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.notice_id IS NULL OR NEW.notice_id = 0 THEN NEW.notice_id := COALESCE((SELECT MAX(notice_id) FROM %I.notice), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_notice_id BEFORE INSERT ON %I.notice FOR EACH ROW EXECUTE FUNCTION %I.set_notice_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_noti_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.noti_id IS NULL OR NEW.noti_id = 0 THEN NEW.noti_id := COALESCE((SELECT MAX(noti_id) FROM %I.notification), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_noti_id BEFORE INSERT ON %I.notification FOR EACH ROW EXECUTE FUNCTION %I.set_noti_id()', v_schema, v_schema);

  -- Password hash triggers
  EXECUTE format('CREATE FUNCTION %I.hash_student_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stupassword IS NOT NULL AND NEW.stupassword != '''' AND LEFT(NEW.stupassword, 4) != ''$2a$'' AND LEFT(NEW.stupassword, 4) != ''$2b$'' THEN NEW.stupassword := crypt(NEW.stupassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER hash_student_password_trigger BEFORE INSERT OR UPDATE OF stupassword ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.hash_student_password()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.hash_parent_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.parpassword IS NOT NULL AND NEW.parpassword != '''' AND LEFT(NEW.parpassword, 4) != ''$2a$'' AND LEFT(NEW.parpassword, 4) != ''$2b$'' THEN NEW.parpassword := crypt(NEW.parpassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER hash_parent_password_trigger BEFORE INSERT OR UPDATE OF parpassword ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.hash_parent_password()', v_schema, v_schema);

  -- Transfer Certificate entries (Admission → Transfer Certificate). One row per
  -- TC issued; save_tc_entry writes here and stamps the student's + admission's
  -- activestatus with the leaving code, so non-active students drop out of the
  -- active screens (which filter activestatus=1).
  EXECUTE format('CREATE TABLE %I.tc_entry (tc_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), stu_id bigint, stuadmno varchar(25) NOT NULL, stuname varchar(50), stuclass varchar(20), cla_id smallint, birthdate date, joindate date, status smallint NOT NULL DEFAULT 1 CHECK (status = ANY(ARRAY[1,2,3,4,5,9])), statustype varchar(20), tcno varchar(30), tcdate date, effectfrom date, docno varchar(30), docdate date, remarks varchar(200), createdby varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE SEQUENCE %I.tc_entry_tc_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_tc_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.tc_id IS NULL OR NEW.tc_id = 0 THEN NEW.tc_id := nextval(''%I.tc_entry_tc_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_tc_entry_tc_id BEFORE INSERT ON %I.tc_entry FOR EACH ROW EXECUTE FUNCTION %I.set_tc_id()', v_schema, v_schema);
  EXECUTE format('ALTER TABLE %I.tc_entry ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.tc_entry USING (true) WITH CHECK (true)', v_schema);

  -- (rollno_change lives in public, alongside public.admission — see above.)

  -- (fn_approve_tempfeedemand + trigger are defined right after the tempfeedemand
  -- table above; they carry the `collectible` flag from temp into feedemand.)

  -- RLS
  EXECUTE format('ALTER TABLE %I.notice ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('ALTER TABLE %I.notification ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('ALTER TABLE %I.tempfeedemand ENABLE ROW LEVEL SECURITY', v_schema);
  -- student_import was missing its ENABLE (policy created below), which tripped
  -- the Supabase "Policy Exists RLS Disabled" advisor for every new schema.
  EXECUTE format('ALTER TABLE %I.student_import ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.notice USING (true) WITH CHECK (true)', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.notification USING (true) WITH CHECK (true)', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.tempfeedemand USING (true) WITH CHECK (true)', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.student_import USING (true) WITH CHECK (true)', v_schema);

  -- PERMISSIONS
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated', v_schema);
  EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO anon, authenticated', v_schema);
  EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO anon, authenticated', v_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO anon, authenticated', v_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO anon, authenticated', v_schema);

  -- Auto-create year records if parameters provided
  IF p_ins_id IS NOT NULL AND p_year_label IS NOT NULL THEN
    -- Insert into public.institutionyear, stamping iyrschema so the row
    -- carries the per-year schema name (e.g. 'kcet20262027') without the
    -- app having to re-derive it from inshortname + yrlabel.
    INSERT INTO public.institutionyear (ins_id, inscode, yrlabel, iyrstadate, iyrenddate, iyrschema, activestatus)
    VALUES (p_ins_id, COALESCE(v_inscode, ''), p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year'), v_schema, 1)
    ON CONFLICT (ins_id, yrlabel) DO UPDATE SET iyrschema = EXCLUDED.iyrschema;

    -- Insert into schema year table
    EXECUTE format('INSERT INTO %I.year (ins_id, yrlabel, yrstadate, yrenddate, activestatus) VALUES ($1, $2, $3, $4, 1)', v_schema)
    USING p_ins_id, p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year');
  END IF;

  -- Expose schema to PostgREST (may fail on free tier - handled by app login)
  BEGIN
    PERFORM public.expose_schema(v_schema);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'expose_schema skipped: %', SQLERRM;
  END;

  -- Security (Option B): the money tables are written ONLY through session-gated
  -- SECURITY DEFINER RPCs (they run as owner), so a new schema is born with anon
  -- direct-write REVOKED on them. SELECT is left intact (reads unchanged). This
  -- mirrors phase3a_revoke_money_writes.sql for existing schemas.
  EXECUTE format(
    'REVOKE INSERT, UPDATE, DELETE ON %I.payment, %I.paymentdetails, %I.feedemand, '
    '%I.fee_refund, %I.fee_refunddetails, %I.concession, %I.concessiondetail, %I.students, %I.parents, %I.parentdetail, '
    '%I.advance_collection, %I.advance_detail, %I.advadjustment FROM anon',
    v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema,
    v_schema, v_schema, v_schema);

  -- Read lockdown: enable RLS + per-tenant SELECT policy on sensitive tables so a
  -- NEW institution is born read-locked (anon can't SELECT another tenant's PII/
  -- money). Wrapped so a policy hiccup never blocks institution creation.
  BEGIN
    PERFORM public.read_lock_schema(v_schema);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'read_lock_schema skipped for %: %', v_schema, SQLERRM;
  END;

END; $$;

-- ############################################################################
-- 3 -- ALLOCATION carries the flag from the admission onto the student
-- ############################################################################
CREATE OR REPLACE FUNCTION public.allocate_admission_to_student(
  p_adm_id      bigint,
  p_schema      text,
  p_class       text,
  p_stuadmno    text,
  p_allocatedby text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
DECLARE
  v_schema   text := lower(p_schema);
  v          public.admission%ROWTYPE;
  v_stu_id   bigint;
  v_par_id   bigint;
  v_yr_id    integer;
  v_yrlabel  varchar(9);
  v_adm_id   smallint;
  v_cla_id   smallint;
  v_cour_id  integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'allocate_admission: schema % does not exist', v_schema;
  END IF;

  SELECT * INTO v FROM public.admission WHERE adm_id = p_adm_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Admission % not found', p_adm_id; END IF;
  IF v.admstatus = 'ALLOCATED' THEN
    RAISE EXCEPTION 'Admission % is already allocated', p_adm_id;
  END IF;

  -- admission no longer stores yr_id/yrlabel — derive from the target schema.
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v.ins_id;
  IF v_yr_id IS NULL THEN
    RAISE EXCEPTION 'allocate_admission: cannot resolve academic year for schema %', v_schema;
  END IF;

  -- Self-heal: ensure the target schema's students table has the demographic
  -- columns (no-op if already present). Covers schemas created before this
  -- feature was added.
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS aadharno      varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS community     varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS caste         varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS religion      varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS nationality   varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS transportmode varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS hostel        char(1)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS emisno        varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS umisno        varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarship     char(1)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarshiptype varchar(60)', v_schema);

  -- Resolve the allocated class's ids (p_class can differ from the admission's
  -- preferred class) so the new student carries cla_id / cour_id; adm_id (from
  -- admission.admtype_id) / quo_id / medium come straight from the admission row.
  EXECUTE format('SELECT cla_id, cour_id FROM %I.class WHERE UPPER(TRIM(claname))=UPPER(TRIM($1)) AND activestatus=1 ORDER BY cla_id LIMIT 1', v_schema)
    INTO v_cla_id, v_cour_id USING p_class;

  -- 1) students (stu_id auto-assigned by the schema's set_stu_id trigger)
  EXECUTE format(
    'INSERT INTO %I.students '
    '(ins_id, inscode, yr_id, yrlabel, stuadmno, stuadmdate, stuname, stugender, studob, '
    ' stumobile, stuemail, stuaddress, stucity, stustate, stucountry, stupin, stubloodgrp, stuphoto, '
    ' stuclass, courname, con_id, stucondesc, stuser_id, stuotpstatus, '
    ' approvedby, approveddate, activestatus, createdon, batch, admname, quoname, admittyear, aadharno, '
    ' community, caste, religion, nationality, transportmode, hostel, emisno, umisno, scholarship, scholarshiptype, cla_id, cour_id, adm_id, quo_id, medium, admit_cour_id, preadmission) '
    'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,'
    ' $19,$20,$21,$22,$5,0,$23,now(),1,now(),$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,'
    ' $41,$42,$43,$44,$35,$36,$37,$38,$39,$40,$45) RETURNING stu_id', v_schema)
  INTO v_stu_id
  USING v.ins_id, v.inscode, v_yr_id, v_yrlabel, p_stuadmno, COALESCE(v.admdate, CURRENT_DATE),
        v.stuname, v.stugender, v.studob, v.stumobile, v.stuemail, v.stuaddress, v.stucity,
        v.stustate, v.stucountry, v.stupin, v.stubloodgrp, v.stuphoto, p_class, v.courname,
        v.con_id, v.stucondesc, p_allocatedby, v.batch, v.admname, v.quoname, v.admittyear, v.aadharno,
        v.community, v.caste, v.religion, v.nationality, v.transportmode, v.hostel,
        COALESCE(v_cla_id, v.cla_id), COALESCE(v_cour_id, v.cour_id), v.admtype_id, v.quo_id, v.medium,
        COALESCE(v.admit_cour_id, v_cour_id, v.cour_id),
        -- $41-$44: appended rather than inserted mid-list so every existing
        -- placeholder keeps its number.
        v.emisno, v.umisno, v.scholarship, v.scholarshiptype,
        -- $45: seat booked now, studies from next year. Carried onto the
        -- student so the fee generator can skip them and the rollover can
        -- keep their class.
        COALESCE(v.preadmission, 0)::smallint;

  -- 2) parents — reuse an existing parent matched by payinchargemob, else create.
  IF v.payinchargemob IS NOT NULL AND TRIM(v.payinchargemob) <> '' THEN
    EXECUTE format('SELECT par_id FROM %I.parents WHERE payinchargemob = $1 LIMIT 1', v_schema)
      INTO v_par_id USING v.payinchargemob;
    IF v_par_id IS NULL THEN
      EXECUTE format('ALTER TABLE %I.parents ADD COLUMN IF NOT EXISTS paremail varchar(254)', v_schema);
      EXECUTE format(
        'INSERT INTO %I.parents '
        '(ins_id, yr_id, yrlabel, partype, fathername, fathermobile, fatheroccupation, '
        ' mothername, mothermobile, motheroccupation, guardianname, guardianmobile, guardianoccupation, '
        ' payincharge, payinchargemob, paremail, parotpstatus, approveddate, activestatus) '
        'VALUES ($1,$2,$3,''P'',$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,NULLIF(TRIM($15),''''),0,now(),1) RETURNING par_id', v_schema)
      INTO v_par_id
      USING v.ins_id, v_yr_id, v_yrlabel, v.fathername, v.fathermobile, v.fatheroccupation,
            v.mothername, v.mothermobile, v.motheroccupation, v.guardianname, v.guardianmobile,
            v.guardianoccupation, COALESCE(NULLIF(TRIM(v.payincharge), ''), v.stuname), v.payinchargemob, v.paremail;
    END IF;

    -- 3) parentdetail link
    EXECUTE format(
      'INSERT INTO %I.parentdetail '
      '(yr_id, yrlabel, par_id, stu_id, ins_id, inscode, stuadmno, stuname, stuclass, activestatus) '
      'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
    USING v_yr_id, v_yrlabel, v_par_id, v_stu_id, v.ins_id, v.inscode, p_stuadmno, v.stuname, p_class;
  END IF;

  -- 4) stamp the admission row as allocated (admission no longer has stu_id).
  UPDATE public.admission
     SET allocatedclass = p_class,
         admstatus = 'ALLOCATED',
         allocatedby = p_allocatedby,
         allocateddate = now()
   WHERE adm_id = p_adm_id;

  -- NOTE: fee demand is deliberately NOT generated on admission/allocation.
  -- Enrolment creates the student (+ parent) only; fee demands are raised
  -- separately from the Fee Demand screen (generate_feedemand_*). Allocation
  -- therefore never seeds tempfeedemand. (v_adm_id stays declared but unused.)

  RETURN json_build_object(
    'adm_id', p_adm_id, 'stu_id', v_stu_id, 'par_id', v_par_id,
    'stuadmno', p_stuadmno, 'class', p_class, 'status', 'ALLOCATED');
END;
$fn$;

-- ############################################################################
-- 4 -- FEE DEMANDS skip a pre-admission student
-- ############################################################################
CREATE OR REPLACE FUNCTION public.generate_feedemand_for_class(
  p_ins_id integer, p_class text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '120s'
AS $$
DECLARE v_schema text; v_count int;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;
  EXECUTE format($q$
    INSERT INTO %1$I.tempfeedemand
      (ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, duedate,
       activestatus, createdby, isapproved, collectible,
       cla_id, sem_id, cf_id, fee_id, demseqtype)
    SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname,
       s.yrlabel, cf.cfterm, cf.cffeetype, cf.cfamount, s.con_id, 0, cf.cfamount,
       cf.cfdduedate, 1, COALESCE(s.approvedby, 'SYSTEM'), false, COALESCE(cf.collectible, true),
       cf.cla_id, cf.sem_id, cf.cf_id, cf.fee_id, 'REGULAR'
    FROM %1$I.students s
    JOIN %1$I.classfeedemand cf
      ON cf.cfclass = s.stuclass AND cf.activestatus = 1
    LEFT JOIN %1$I.admissiontype a
      ON UPPER(TRIM(a.admname)) = UPPER(TRIM(s.admname)) AND a.activestatus = 1 AND a.ins_id = s.ins_id
    WHERE s.activestatus <> 9
      -- A pre-admission student has paid to hold a seat for NEXT year and is
      -- not studying this one, so this year's fees are not theirs to owe.
      -- They pick the new year's demands up after the rollover, by which time
      -- the flag is cleared.
      AND COALESCE(s.preadmission, 0) = 0
      AND s.stuclass = $1
      AND cf.cfamount IS NOT NULL
      AND (cf.cfdduedate IS NULL OR cf.cfdduedate >= s.stuadmdate)
      AND (cf.admissiontype IS NULL OR cf.admissiontype = a.adm_id)
      AND NOT EXISTS (SELECT 1 FROM %1$I.tempfeedemand t
            WHERE t.stu_id = s.stu_id AND t.demfeeterm = cf.cfterm
              AND t.demfeetype = cf.cffeetype AND t.activestatus = 1)
      AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd
            WHERE fd.stu_id = s.stu_id AND fd.demfeeterm = cf.cfterm
              AND fd.demfeetype = cf.cffeetype AND fd.activestatus = 1)
  $q$, v_schema) USING p_class;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ############################################################################
-- 5 -- ROLLOVER keeps their class, clears the flag, and carries the money
-- ############################################################################
CREATE OR REPLACE FUNCTION public.rollover_academic_year(p_ins_id integer, p_old_year_label text, p_new_year_label text, p_start_date date, p_end_date date) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
DECLARE
  v_short        text;
  v_old          text;   -- old schema name
  v_new          text;   -- new schema name
  v_new_yr       integer;
  v_active       integer := 0;
  v_carried      integer := 0;
  v_graduated    integer := 0;
  v_parents      integer := 0;
  v_pdetail      integer := 0;
  v_openrows     integer := 0;
  v_openamt      numeric(14,2) := 0;
BEGIN
  -- --- resolve schema names ------------------------------------------------
  SELECT lower(inshortname) INTO v_short
  FROM public.institution WHERE ins_id = p_ins_id;
  IF v_short IS NULL THEN
    RAISE EXCEPTION 'Institution % not found', p_ins_id;
  END IF;

  v_old := v_short || replace(p_old_year_label, '-', '');
  v_new := v_short || replace(p_new_year_label, '-', '');

  -- --- guards --------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_old) THEN
    RAISE EXCEPTION 'Old year schema % does not exist', v_old;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_new) THEN
    RAISE EXCEPTION 'New year schema % already exists - aborting to avoid clobber', v_new;
  END IF;

  -- --- 1. build the empty new-year schema (+ year / institutionyear rows) --
  PERFORM public.create_institution_schema(v_new, p_ins_id, p_new_year_label, p_start_date, p_end_date);

  EXECUTE format('SELECT yr_id FROM %I.year ORDER BY yr_id LIMIT 1', v_new) INTO v_new_yr;

  -- ========================================================================
  -- 2. MASTER / CONFIG  (copy as-is, preserve PKs, then advance sequences)
  -- ========================================================================

  -- bank  (ban_id is GENERATED ALWAYS AS IDENTITY -> OVERRIDING SYSTEM VALUE)
  EXECUTE format($q$
    INSERT INTO %1$I.bank
      (ban_id, banname, banbranch, ifsccode, banaddress1, banaddress2,
       banaddress3, banmobile, banemail, banaccno, banaccholder, activestatus)
    OVERRIDING SYSTEM VALUE
    SELECT ban_id, banname, banbranch, ifsccode, banaddress1, banaddress2,
       banaddress3, banmobile, banemail, banaccno, banaccholder, activestatus
    FROM %2$I.bank
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval(pg_get_serial_sequence('%1$I.bank','ban_id'),
      GREATEST((SELECT COALESCE(MAX(ban_id),0) FROM %1$I.bank),1))$q$, v_new);

  -- course
  EXECUTE format($q$
    INSERT INTO %1$I.course (cour_id, courname, ordid, ins_id, activestatus)
    SELECT cour_id, courname, ordid, ins_id, activestatus FROM %2$I.course
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.course_cour_id_seq',
      GREATEST((SELECT COALESCE(MAX(cour_id),0) FROM %1$I.course),1))$q$, v_new);

  -- class  (preserve cla_id so succeedingclass self-references stay valid)
  EXECUTE format($q$
    INSERT INTO %1$I.class (cla_id, claname, ins_id, ordid, succeedingclass, cour_id, activestatus)
    SELECT cla_id, claname, ins_id, ordid, succeedingclass, cour_id, activestatus FROM %2$I.class
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.class_cla_id_seq',
      GREATEST((SELECT COALESCE(MAX(cla_id),0) FROM %1$I.class),1))$q$, v_new);

  -- concessioncategory
  EXECUTE format($q$
    INSERT INTO %1$I.concessioncategory (con_id, condesc, ins_id, ordid, activestatus)
    SELECT con_id, condesc, ins_id, ordid, activestatus FROM %2$I.concessioncategory
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.concessioncategory_con_id_seq',
      GREATEST((SELECT COALESCE(MAX(con_id),0) FROM %1$I.concessioncategory),1))$q$, v_new);

  -- admissiontype (smallint PK, no sequence)
  EXECUTE format($q$
    INSERT INTO %1$I.admissiontype (adm_id, admname, ins_id, activestatus, createdat, createdby)
    SELECT adm_id, admname, ins_id, activestatus, createdat, createdby FROM %2$I.admissiontype
  $q$, v_new, v_old);

  -- quota (smallint PK, no sequence)
  EXECUTE format($q$
    INSERT INTO %1$I.quota (quo_id, quoname, ins_id, activestatus, createdat, createdby)
    SELECT quo_id, quoname, ins_id, activestatus, createdat, createdby FROM %2$I.quota
  $q$, v_new, v_old);

  -- paymentgateway (identity)
  EXECUTE format($q$
    INSERT INTO %1$I.paymentgateway
      (gw_id, gwname, gwapikey, gwapisecret, activestatus)
    OVERRIDING SYSTEM VALUE
    SELECT gw_id, gwname, gwapikey, gwapisecret, activestatus FROM %2$I.paymentgateway
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval(pg_get_serial_sequence('%1$I.paymentgateway','gw_id'),
      GREATEST((SELECT COALESCE(MAX(gw_id),0) FROM %1$I.paymentgateway),1))$q$, v_new);

  -- finerule (identity)
  EXECUTE format($q$
    INSERT INTO %1$I.finerule
      (fr_id, ins_id, rulename, feetype, from_days, to_days, fine_type, fine_value, activestatus, createdat, createdby)
    OVERRIDING SYSTEM VALUE
    SELECT fr_id, ins_id, rulename, feetype, from_days, to_days, fine_type, fine_value, activestatus, createdat, createdby
    FROM %2$I.finerule
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval(pg_get_serial_sequence('%1$I.finerule','fr_id'),
      GREATEST((SELECT COALESCE(MAX(fr_id),0) FROM %1$I.finerule),1))$q$, v_new);

  -- classfeedemand  (class-level fee template, no year column)
  EXECUTE format($q$
    INSERT INTO %1$I.classfeedemand (cf_id, cfclass, cfterm, cffeetype, cfamount, cfdduedate, admissiontype)
    SELECT cf_id, cfclass, cfterm, cffeetype, cfamount, cfdduedate, admissiontype FROM %2$I.classfeedemand
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.classfeedemand_cf_id_seq',
      GREATEST((SELECT COALESCE(MAX(cf_id),0) FROM %1$I.classfeedemand),1))$q$, v_new);

  -- feegroup  (re-stamp year)
  EXECUTE format($q$
    INSERT INTO %1$I.feegroup (fg_id, fgdesc, ban_id, ins_id, yr_id, yrlabel, activestatus)
    SELECT fg_id, fgdesc, ban_id, ins_id, $1, $2, activestatus FROM %2$I.feegroup
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  EXECUTE format($q$SELECT setval('%1$I.feegroup_fg_id_seq',
      GREATEST((SELECT COALESCE(MAX(fg_id),0) FROM %1$I.feegroup),1))$q$, v_new);

  -- feetype  (re-stamp year, keep fg_id link)
  EXECUTE format($q$
    INSERT INTO %1$I.feetype (fee_id, feedesc, feeshort, feefineapplicable, fg_id, yr_id, yrlabel, activestatus, ins_id)
    SELECT fee_id, feedesc, feeshort, feefineapplicable, fg_id, $1, $2, activestatus, ins_id FROM %2$I.feetype
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  EXECUTE format($q$SELECT setval('%1$I.feetype_fee_id_seq',
      GREATEST((SELECT COALESCE(MAX(fee_id),0) FROM %1$I.feetype),1))$q$, v_new);

  -- sequence  (re-stamp year, RESET running number to start)
  EXECUTE format($q$
    INSERT INTO %1$I.sequence
      (ins_id, mod_id, yr_id, yrlabel, actname, seqname, isprefix, seqprefix,
       seqstart, seqwidth, sequid, seqcurno, activestatus, fg_id)
    SELECT ins_id, mod_id, $1, $2, actname, seqname, isprefix, seqprefix,
       seqstart, seqwidth, sequid, seqstart, activestatus, fg_id
    FROM %2$I.sequence
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;

  -- ========================================================================
  -- 3. PROMOTION MAP  (which students carry forward, and to which class)
  -- ========================================================================
  CREATE TEMP TABLE _promote (stu_id bigint PRIMARY KEY, new_class varchar(20)) ON COMMIT DROP;

  EXECUTE format($q$
    INSERT INTO _promote (stu_id, new_class)
    SELECT s.stu_id,
           CASE
             -- PRE-ADMISSION: admitted during this year to hold a seat for the
             -- NEXT one. The coming year is their FIRST, so they start in the
             -- class they were admitted to -- promoting them would put a
             -- first-year into second year on day one.
             WHEN COALESCE(s.preadmission, 0) = 1 THEN s.stuclass
             WHEN c.cla_id IS NULL THEN s.stuclass            -- class master unmatched: keep class
             ELSE COALESCE(nc.claname, s.stuclass)            -- promoted to next class
           END
    FROM %1$I.students s
    LEFT JOIN %1$I.class c
      ON UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
     AND c.ins_id = s.ins_id AND c.activestatus = 1
    LEFT JOIN %1$I.class nc ON nc.cla_id = c.succeedingclass
    WHERE s.activestatus = 1
      -- A pre-admission student is never "graduating", whatever class they hold.
      AND (COALESCE(s.preadmission, 0) = 1
           OR NOT (c.cla_id IS NOT NULL AND c.succeedingclass IS NULL))  -- exclude terminal/graduating
  $q$, v_old);

  EXECUTE format('SELECT COUNT(*) FROM %I.students WHERE activestatus = 1', v_old) INTO v_active;
  SELECT COUNT(*) INTO v_carried FROM _promote;
  v_graduated := v_active - v_carried;

  -- ========================================================================
  -- 4. STUDENTS  (preserve stu_id, promote class, re-stamp year)
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.students
      (stu_id, ins_id, inscode, yr_id, yrlabel, stuadmno, stuadmdate, stuname,
       stugender, studob, stumobile, stuemail, stuaddress, stucity, stustate,
       stucountry, stupin, stugeocoordinates, stubloodgrp, stuphoto, stuclass,
       cour_id, courname, con_id, stucondesc, stuser_id, stupassword,
       stuotpstatus, approvedby, approveddate, activestatus, createdon,
       batch, admname, quoname, admittyear, preadmission)
    SELECT s.stu_id, s.ins_id, s.inscode, $1, $2, s.stuadmno, s.stuadmdate, s.stuname,
       s.stugender, s.studob, s.stumobile, s.stuemail, s.stuaddress, s.stucity, s.stustate,
       s.stucountry, s.stupin, s.stugeocoordinates, s.stubloodgrp, s.stuphoto, p.new_class,
       s.cour_id, s.courname, s.con_id, s.stucondesc, s.stuser_id, s.stupassword,
       0, s.approvedby, now(), 1, now(),
       s.batch, s.admname, s.quoname, s.admittyear, 0
    FROM %2$I.students s
    JOIN _promote p ON p.stu_id = s.stu_id
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  -- preadmission is written as 0 above: the year they were waiting for has
  -- arrived, so in the new schema they are an ordinary student of that class.

  EXECUTE format($q$SELECT setval('%1$I.students_stu_id_seq',
      GREATEST((SELECT COALESCE(MAX(stu_id),0) FROM %1$I.students),1))$q$, v_new);

  -- ========================================================================
  -- 4b. UNSPENT ADVANCES  (money in hand, so it MUST follow its student)
  -- ========================================================================
  -- The whole point of a pre-admission collection: the deposit is taken this
  -- year and adjusted against next year's fees. Left behind it would be money
  -- the institution holds and the new year cannot see. Only rows with a
  -- balance are carried -- a fully spent or refunded advance is history and
  -- belongs to the year it was settled in. adv_id is preserved so the detail
  -- rows still match, and the class is re-stamped to the class the student
  -- lands in.
  --
  -- Guarded: a schema created before the advance module has no such table.
  IF to_regclass(format('%I.advance_collection', v_old)) IS NOT NULL
     AND to_regclass(format('%I.advance_collection', v_new)) IS NOT NULL THEN
    EXECUTE format($q$
      INSERT INTO %1$I.advance_collection
        (adv_id, ins_id, inscode, stu_id, stuadmno, stuname, stuclass, courname,
         yr_id, yrlabel, advno, advdate, advtype, transtotalamount, adjustedamount,
         refund_amount, transcurrency, paystatus, paymethod, payreference,
         remarks, createdby, createdat, recon_status, reconciled_by,
         reconciled_date, bank_reference, bank_date, activestatus)
      OVERRIDING SYSTEM VALUE
      SELECT a.adv_id, a.ins_id, a.inscode, a.stu_id, a.stuadmno, a.stuname,
             p.new_class, a.courname, $1, $2, a.advno, a.advdate, a.advtype,
             -- Carried forward at its REMAINING value: what was already spent
             -- was spent in the old year and must not be spendable again.
             a.balanceamount, 0, 0,
             a.transcurrency, a.paystatus, a.paymethod, a.payreference,
             COALESCE(NULLIF(a.remarks, ''), '') , a.createdby, a.createdat,
             a.recon_status, a.reconciled_by, a.reconciled_date,
             a.bank_reference, a.bank_date, a.activestatus
        FROM %2$I.advance_collection a
        JOIN _promote p ON p.stu_id = a.stu_id
       WHERE a.activestatus = 1 AND a.balanceamount > 0
    $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
    EXECUTE format($q$SELECT setval('%1$I.advance_collection_adv_id_seq',
        GREATEST((SELECT COALESCE(MAX(adv_id),0) FROM %1$I.advance_collection),1))$q$, v_new);

    -- The fee-type breakdown an ADMISSION advance was collected against; it is
    -- what Advance Adjustment matches on, so it has to come too.
    IF to_regclass(format('%I.advance_detail', v_new)) IS NOT NULL THEN
      EXECUTE format($q$
        INSERT INTO %1$I.advance_detail (adv_id, ins_id, fee_id, fg_id, feetype, amount, activestatus)
        SELECT d.adv_id, d.ins_id, d.fee_id, d.fg_id, d.feetype, d.amount, d.activestatus
          FROM %2$I.advance_detail d
          JOIN %1$I.advance_collection a ON a.adv_id = d.adv_id
         WHERE d.activestatus = 1
      $q$, v_new, v_old);
    END IF;
  END IF;

  -- ========================================================================
  -- 5. PARENTS  (only those linked to carried students)
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.parents
      (par_id, yr_id, yrlabel, partype, paremail, fathername, mothername,
       guardianname, fathermobile, mothermobile, guardianmobile,
       fatheroccupation, motheroccupation, guardianoccupation, payincharge,
       payinchargemob, parpassword, parotpstatus, approvedby, approveddate,
       activestatus, ins_id)
    SELECT par_id, $1, $2, partype, paremail, fathername, mothername,
       guardianname, fathermobile, mothermobile, guardianmobile,
       fatheroccupation, motheroccupation, guardianoccupation, payincharge,
       payinchargemob, parpassword, 0, approvedby, approveddate,
       activestatus, ins_id
    FROM %2$I.parents
    WHERE par_id IN (
      SELECT DISTINCT pd.par_id FROM %2$I.parentdetail pd
      JOIN _promote p ON p.stu_id = pd.stu_id
    )
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  GET DIAGNOSTICS v_parents = ROW_COUNT;

  EXECUTE format($q$SELECT setval('%1$I.parents_par_id_seq',
      GREATEST((SELECT COALESCE(MAX(par_id),0) FROM %1$I.parents),1))$q$, v_new);

  -- ========================================================================
  -- 6. PARENTDETAIL  (carried students, class updated)
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.parentdetail
      (pd_id, yr_id, yrlabel, par_id, stu_id, ins_id, inscode, stuadmno, stuname, stuclass, activestatus)
    SELECT pd.pd_id, $1, $2, pd.par_id, pd.stu_id, pd.ins_id, pd.inscode,
       pd.stuadmno, pd.stuname, p.new_class, pd.activestatus
    FROM %2$I.parentdetail pd
    JOIN _promote p ON p.stu_id = pd.stu_id
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  GET DIAGNOSTICS v_pdetail = ROW_COUNT;

  EXECUTE format($q$SELECT setval('%1$I.parentdetail_pd_id_seq',
      GREATEST((SELECT COALESCE(MAX(pd_id),0) FROM %1$I.parentdetail),1))$q$, v_new);

  -- ========================================================================
  -- 7. OPENING BALANCE  (consolidate prior-year unpaid dues per feetype)
  --    Grouped per student + feetype so bank routing (feetype->feegroup->bank)
  --    is preserved when these are collected in the new year.
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.feedemand
      (yr_id, ins_id, inscode, stu_id, stuadmno, stuclass, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, paidamount,
       fineamount, balancedue, reconbalancedue, duedate, paidstatus,
       createdby, activestatus, courname, remarks)
    SELECT $1, d.ins_id, d.inscode, d.stu_id, d.stuadmno, p.new_class, $2,
       'Opening Balance', d.demfeetype, SUM(d.balancedue), d.con_id, 0, 0,
       0, SUM(d.balancedue), SUM(d.balancedue), $3, 'U',
       'YEAR_ROLLOVER', 1, d.courname, ('Dues ' || $4)
    FROM %2$I.feedemand d
    JOIN _promote p ON p.stu_id = d.stu_id
    WHERE d.activestatus = 1 AND d.paidstatus = 'U' AND d.balancedue > 0
    GROUP BY d.ins_id, d.inscode, d.stu_id, d.stuadmno, p.new_class, d.demfeetype, d.con_id, d.courname
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label, p_start_date, p_old_year_label;
  GET DIAGNOSTICS v_openrows = ROW_COUNT;

  EXECUTE format($q$SELECT COALESCE(SUM(balancedue),0) FROM %1$I.feedemand WHERE createdby='YEAR_ROLLOVER'$q$, v_new)
    INTO v_openamt;

  -- ========================================================================
  -- DONE
  -- ========================================================================
  RETURN json_build_object(
    'old_schema',          v_old,
    'new_schema',          v_new,
    'new_yr_id',           v_new_yr,
    'active_students',     v_active,
    'students_carried',    v_carried,
    'students_graduated',  v_graduated,
    'parents_carried',     v_parents,
    'parentdetail_carried',v_pdetail,
    'opening_balance_rows',v_openrows,
    'opening_balance_total',v_openamt
  );
END;
$_$;
GRANT EXECUTE ON FUNCTION public.rollover_academic_year(p_ins_id integer, p_old_year_label text, p_new_year_label text, p_start_date date, p_end_date date) TO anon, authenticated;


-- ############################################################################
-- 6 -- TWO PLACES THAT COUNT STUDENTS RATHER THAN DEMANDS
--
-- Every other report is demand-driven, and a pre-admission student has no
-- demands, so they are already absent from Pending Payment, Pending Details,
-- the DCB Register and the Student Ledger. Their advance DOES show in Daily
-- Collection, which is right -- the money was taken.
--
-- These two count STUDENTS, so they had to be told:
--   * Consolidated Status' class strength -- next year's intake is not this
--     class's strength.
--   * get_students_by_class, behind the Students screen.
-- ############################################################################
CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH class_strength AS (
            SELECT courname, stuclass, COUNT(DISTINCT stu_id)::INT AS strength
            FROM   %1$I.students WHERE ins_id = %2$L AND activestatus = 1
              -- Next year's intake is not this class's strength.
              AND COALESCE(preadmission, 0) = 0
            GROUP BY courname, stuclass
        ),
        pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.category, t.type), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  cs.strength,
                  fd.demfeeterm::TEXT AS semester,
                  -- category = admission type (e.g. GOVERNMENT QUOTA / MANAGEMENT QUOTA)
                  COALESCE(NULLIF(s.admname, ''), 'GENERAL')::TEXT AS category,
                  COUNT(DISTINCT s.stu_id)::INT AS stud_count,
                  (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                  SUM(fd.feeamount)::NUMERIC AS due,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  SUM(fd.feeamount)::NUMERIC AS net_demand,
                  -- Paid = fee-only, approved-only (pending-approval amounts are subtracted)
                  GREATEST(
                    COALESCE(SUM(fd.paidamount),0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                      - COALESCE(SUM(pa.pending_fee),0),
                    0
                  )::NUMERIC AS paid,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS balance
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN class_strength cs
                 ON cs.courname = s.courname AND cs.stuclass = s.stuclass
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, cs.strength,
                   fd.demfeeterm, COALESCE(NULLIF(s.admname, ''), 'GENERAL'),
                   (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.get_students_by_class(p_ins_id integer, p_class text) RETURNS SETOF json
LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE v text; BEGIN v := get_institution_schema(p_ins_id); IF v IS NULL THEN RETURN; END IF;
RETURN QUERY EXECUTE format('SELECT row_to_json(t) FROM (SELECT * FROM %I.students WHERE ins_id = $1 AND activestatus = 1 AND COALESCE(preadmission,0) = 0 AND stuclass = $2 ORDER BY stuname) t', v) USING p_ins_id, p_class; END; $$;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- VERIFY -- every flag must read t.
-- ############################################################################
SELECT
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='public' AND table_name='admission'
      AND column_name='preadmission') = 1                        AS admission_has_column,
  (SELECT bool_and(has_col) FROM (
     SELECT EXISTS (SELECT 1 FROM information_schema.columns c
                     WHERE c.table_schema=t.table_schema AND c.table_name='students'
                       AND c.column_name='preadmission') AS has_col
       FROM information_schema.tables t
      WHERE t.table_name='students'
        AND t.table_schema NOT IN ('pg_catalog','information_schema')) q
  )                                                              AS every_schema_has_column,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='allocate_admission_to_student')  AS allocation_copies_it,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='generate_feedemand_for_class')   AS demands_skip_them,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='rollover_academic_year')         AS rollover_keeps_class,
  (SELECT prosrc LIKE '%advance_collection%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='rollover_academic_year')         AS rollover_carries_advances,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='create_institution_schema')      AS new_schemas_get_column;

-- How many pre-admission students there are, per year schema.
DO $count$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('SELECT count(*) FROM %I.students WHERE preadmission = 1', r.s) INTO n;
    RAISE NOTICE '%: % pre-admission student(s)', r.s, n;
  END LOOP;
END $count$;



-- ############################################################################
-- ############################################################################
--
--   PART 7 OF 7  --  Drop the Export report's functions  *** DESTRUCTIVE ***
--   source: migrations/DROP_POWERCOLLEGE_EXPORT.sql
--
--   The Export report is gone from the app, so its two functions have no
--   caller. THIS IS THE ONLY PART THAT DESTROYS ANYTHING -- see the warning in
--   the header.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- EduCore360 -- DROP THE EXPORT REPORT'S FUNCTIONS, 19-09-2026
--
-- The Export report (Reports -> Export, the PowerCollege per-line-item export)
-- has been removed from the desktop app: the sidebar entry, the tab and about
-- 660 lines behind it are gone. These two functions existed only to feed it
-- and now have no caller.
--
--   public.get_powercollege_export_json(text, integer, date, date)
--   public.get_powercollege_export(text, integer, date, date)
--
-- Checked before writing this: nothing in the desktop app, nothing in the edge
-- functions, and no other database function references them -- only the _json
-- wrapper calls the base one, which is why it is dropped first.
--
-- ---------------------------------------------------------------------------
-- THIS IS THE ONE FILE HERE THAT DESTROYS SOMETHING. A dropped function cannot
-- be brought back by re-running anything; it has to be re-created from its
-- source. Run the PRE-FLIGHT below FIRST and keep the output -- that output is
-- the restore script. The same bodies are also in this repo's git history and
-- were in C:\pg_backups\complete_setup.sql before this change.
--
-- If the parent mobile app or any outside integration calls either function,
-- STOP: they will start failing the moment this runs.
-- ---------------------------------------------------------------------------
-- ############################################################################


-- ############################################################################
-- PRE-FLIGHT (READ-ONLY) -- the current source of both functions. SAVE THIS.
-- Two rows expected. No rows means they are already gone.
-- ############################################################################
SELECT p.proname,
       pg_get_functiondef(p.oid) AS restore_this_if_you_need_it_back
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('get_powercollege_export', 'get_powercollege_export_json')
 ORDER BY p.proname;


-- ############################################################################
-- DROP -- the wrapper first: it calls the one below it.
-- ############################################################################
DROP FUNCTION IF EXISTS public.get_powercollege_export_json(text, integer, date, date);
DROP FUNCTION IF EXISTS public.get_powercollege_export(text, integer, date, date);

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- VERIFY -- must return NO ROWS.
-- ############################################################################
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname LIKE 'get_powercollege%';



-- ############################################################################
-- ############################################################################
--
--   PART 2 OF 2  --  Repair: demands whose course contradicts their own class
--   source: migrations/FIX_DEMAND_COURSE_MISMATCH.sql
--
--   A fee demand carries both courname and stuclass; some rows disagree with
--   each other. Re-stamps courname from the course that OWNS the demand's
--   class, never from the student's current course -- that distinction is
--   what keeps a transferred student's settled money in the register it was
--   collected in. Read-only BEFORE section first; currently a no-op on TEST.
--
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- EduCore360 -- FEE DEMANDS WHOSE COURSE DOES NOT MATCH THEIR OWN CLASS
-- 19-09-2026
--
-- feedemand carries both courname and stuclass. Some rows disagree with each
-- other: a demand filed under B TECH- IT but in class B.E CSE -I, when the
-- class master says B.E CSE -I belongs to B.E-CSE. That pairing cannot be
-- true of anything.
--
-- ---------------------------------------------------------------------------
-- THE RULE, AND WHY IT IS NOT "THE STUDENT'S CURRENT COURSE"
-- ---------------------------------------------------------------------------
-- A demand's course is the course that OWNS ITS OWN CLASS (class.cour_id ->
-- course.courname). It is NOT the student's current course.
--
-- That distinction matters because of COURSE TRANSFER. When a student moves
-- course, transfer_course_with_credit keeps their already-paid demands as
-- settled records, still carrying the OLD course and the OLD class -- which is
-- correct and historical: that money was billed and collected under the old
-- course, and the DCB Register for that course must go on showing it.
--
-- Re-stamping those rows with the student's CURRENT course would leave the old
-- class beside the new course -- inventing exactly the mismatch this file
-- exists to remove -- and would move settled money from one course's register
-- to another's. So the repair below never looks at the student.
--
-- A worked example from TEST (2627372, transferred B.E-EEE -> B.E-ECE):
--     B.E-EEE / B.E EEE -I   x4   <- old course, settled. LEFT ALONE.
--     B.E-ECE / B.E ECE -I   x3   <- new course. LEFT ALONE.
-- Both pairs are internally consistent, so neither is touched.
--
-- ---------------------------------------------------------------------------
-- WHERE THE BAD ROWS COME FROM
-- ---------------------------------------------------------------------------
-- Not from course transfer: that writes course and class together, and the
-- interim_promotion log on TEST shows all of its moves paired correctly
-- (B.E-EEE/B.E EEE -I -> B.E-ECE/B.E ECE -I, and so on).
--
-- The bad rows carry the student's CURRENT class with a STALE course, i.e.
-- something changed the class and left the course behind. Two paths can do
-- that:
--   * Student Transfer (the section screen). It resolves the target course
--     from class.cour_id and passes it to update_demand_class; when that
--     resolution came back empty it fell back to the student's existing
--     course, so stuclass moved and courname did not.
--   * Fee Demand Import, if a sheet carried a class from one column and a
--     course from another that do not belong together.
-- The class master is clean now -- every class has a valid cour_id -- so the
-- first path cannot recur; the import path is only as good as the sheet.
--
-- WHAT IT BROKE
-- The reports' Class dropdown was built from the (course, class) pairs present
-- in the demands, so it offered impossible pairs: pick B TECH- IT and the list
-- included B.E CSE -I. The app no longer matches on the demand -- it follows
-- the student -- so the dropdown is already correct without this file. This
-- repairs the DATA, so the reports that group by feedemand.courname (the DCB
-- Register, the course filters) agree too.
--
-- Nothing but courname is touched: no amount, no balance, no status, no class.
--
-- SAFE TO RE-RUN: the UPDATE only matches rows that still disagree.
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- how many rows disagree with their own class, per
-- schema. Run this first and keep the output.
-- ############################################################################
DO $before$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*)
        FROM %I.feedemand fd
        JOIN %I.class  c  ON UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
                          AND c.activestatus = 1
        JOIN %I.course co ON co.cour_id = c.cour_id
       WHERE fd.activestatus = 1
         AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'') $q$,
      r.s, r.s, r.s) INTO n;
    RAISE NOTICE '%: % demand row(s) whose course does not match their own class',
                 r.s, n;
  END LOOP;
END $before$;

-- The detail, so the pairs can be eyeballed before anything changes.
SELECT fd.courname AS demand_course, fd.stuclass AS demand_class,
       co.courname AS class_actually_belongs_to, count(*) AS rows
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.class  c  ON UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
                              AND c.activestatus = 1
  JOIN kcet20262027.course co ON co.cour_id = c.cour_id
 WHERE fd.activestatus = 1
   AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'')
 GROUP BY 1, 2, 3
 ORDER BY rows DESC;


-- ############################################################################
-- THE REPAIR -- changes DATA. Read the BEFORE output first.
--
-- courname := the course that owns this demand's class. A demand whose class
-- is not in the class master is skipped (the JOIN drops it) rather than
-- guessed at.
-- ############################################################################
DO $fix$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      UPDATE %I.feedemand fd
         SET courname = co.courname
        FROM %I.class c
        JOIN %I.course co ON co.cour_id = c.cour_id
       WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
         AND c.activestatus = 1
         AND fd.activestatus = 1
         AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'') $q$,
      r.s, r.s, r.s);
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '%: % demand row(s) re-stamped with their class''s course', r.s, n;
  END LOOP;
END $fix$;


-- ############################################################################
-- VERIFY -- every schema must report 0.
-- ############################################################################
DO $after$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*)
        FROM %I.feedemand fd
        JOIN %I.class  c  ON UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
                          AND c.activestatus = 1
        JOIN %I.course co ON co.cour_id = c.cour_id
       WHERE fd.activestatus = 1
         AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'') $q$,
      r.s, r.s, r.s) INTO n;
    RAISE NOTICE '%: % still mismatched (should be 0)', r.s, n;
  END LOOP;
END $after$;

-- A transferred student keeps BOTH pairs, each internally consistent. This
-- should list their old course's settled demands AND their new course's --
-- if it ever shows an old class beside a new course, the repair above has
-- been changed to follow the student, and that is wrong.
SELECT fd.stuadmno, fd.courname, fd.stuclass, count(*) AS rows
  FROM kcet20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND fd.stuadmno IN (SELECT stuadmno FROM kcet20262027.interim_promotion
                        WHERE activestatus = 1)
 GROUP BY 1, 2, 3
 ORDER BY fd.stuadmno, fd.courname;


-- ############################################################################
-- ############################################################################
--  PART 2 of 5 -- LIVE_RUN_20260921.sql
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- ############################################################################
--
--   EduCore360  --  LIVE UPDATE, 21-09-2026
--
--   ONE FILE. Run it top to bottom in the SQL editor.
--
-- ############################################################################
-- ############################################################################
--
-- Everything pending since LIVE_RUN_20260919.sql. That is ONE thing: the class
-- master learning what kind of class each row is. The other changes shipped
-- since the 19th -- the fee-type search, the right-aligned amount, the advance
-- receipt wording, Sequence Master, the TC block on Misc Collection -- are all
-- in the desktop build and need nothing here.
--
-- ---------------------------------------------------------------------------
-- WHAT IT CHANGES
-- ---------------------------------------------------------------------------
-- class.classtype, on every year schema:
--
--   PROMOTIONAL  a normal year. Moves up to its Succeeding Class.
--   TERMINAL     the FINAL YEAR of the course. The ladder ends here. This
--                includes a class that promotes INTO a TC class -- which is
--                how live records graduation (B.E ECE -IV -> ECE TC 23).
--   COMPLETED    a TC class. Students who have left. Never promoted from.
--
-- and create_institution_schema, so a NEW year schema is born with it.
--
-- ---------------------------------------------------------------------------
-- WHY IT MATTERS MORE THAN IT LOOKS
-- ---------------------------------------------------------------------------
-- The class master could only IMPLY these. A final year was one with no
-- succeeding class; a TC batch was one someone had named "CSE TC 25". On TEST
-- -- a restore of live -- that convention had already failed: 30 TC classes
-- succeed THEMSELVES, and 1,880 active students sit in TC classes. A class
-- that promotes to itself is indistinguishable from an ordinary promotion to
-- anything reading succeedingclass, so those students look promotable.
--
-- ---------------------------------------------------------------------------
-- THIS FILE CHANGES DATA
-- ---------------------------------------------------------------------------
--   * it BACKFILLS classtype once, from the evidence already in each row
--     (named like a TC batch -> COMPLETED; promotes into a TC class, or to
--     nothing -> TERMINAL; otherwise PROMOTIONAL)
--   * it then CLEARS succeedingclass on every class whose type says it does
--     not promote. On a restore of live that is 47 rows: the 39 TC and
--     self-referencing links, plus the 8 final years' links into a TC class.
--
-- Nothing outside the class table is touched. No receipt, demand, payment or
-- student row is read or written.
--
-- ---------------------------------------------------------------------------
-- BEFORE YOU START
-- ---------------------------------------------------------------------------
--
-- 1. SAFE TO RE-RUN. The backfill only fills NULLs, so a correction you make
--    by hand afterwards survives. The rename step is guarded and cannot run
--    twice. The repair only touches rows already marked as non-promoting.
--
-- 2. THE SUPABASE SQL EDITOR DOES NOT SHOW RAISE NOTICE, and several sections
--    report their counts that way. The last two statements return ROWS
--    instead: a per-type count, and a contradiction list that should come back
--    EMPTY.
--
-- 3. DEPLOY THE DESKTOP BUILD TOO. The Class screen is where a type is
--    corrected, and an older build cannot show or write the column. Nothing
--    breaks without it -- every class simply reads PROMOTIONAL.
--
-- 4. EXPECTED RESULT on a restore of live: 65 COMPLETED, 25 PROMOTIONAL and
--    10 TERMINAL classes; by student, 1,880 COMPLETED, 1,351 PROMOTIONAL and
--    374 TERMINAL. The contradiction query at the end must come back EMPTY.
--
-- ---------------------------------------------------------------------------
-- NOT HERE
-- ---------------------------------------------------------------------------
-- The YEAR ROLLOVER work is TEST-only and is not in this file. It was checked
-- for by name before this file was written.
--
-- Applied and checked on the TEST project (a restore of live) first.
-- ############################################################################


-- ############################################################################
-- ############################################################################
--
--   EduCore360 -- class.classtype
--   21-09-2026
--
-- ############################################################################
-- ############################################################################
--
-- The class master could not say what KIND of class a row was. A final year
-- was only recognisable by having no succeeding class, and a TC holding class
-- only by someone having named it "CSE TC 25". Both are conventions, not
-- facts, and both break: this institution has TC classes that succeed
-- THEMSELVES (CSE TC 22 -> CSE TC 22), which reads as an ordinary promotion to
-- any rule based on succeedingclass -- and 1,851 active students sit in them.
--
--   PROMOTIONAL  a normal year. Moves up to its Succeeding Class.
--   TERMINAL     the FINAL YEAR of the course. The ladder ends here. A class
--                that promotes INTO a TC class is one of these -- that is
--                how live records graduation (B.E ECE -IV -> ECE TC 23) -- and
--                its link to the TC class is cleared.
--   COMPLETED    a TC class. Students who have left / completed. Not taught,
--                not billed, never promoted from.
--
-- ---------------------------------------------------------------------------
-- WHAT IT DOES
-- ---------------------------------------------------------------------------
--   1. adds the column to class in every year schema, nullable at first
--   2. renames the earlier vocabulary if this file was run before it changed
--   3. backfills the rest once, from the evidence already in the row
--   4. locks it down: NOT NULL, DEFAULT 'PROMOTIONAL', CHECK on the 3 values
--
-- The backfill only ever touches NULLs, so re-running cannot undo a correction
-- made by hand. That is why the column is added WITHOUT a default first: with
-- one, every existing row would arrive already "PROMOTIONAL" and there would
-- be nothing to tell apart from a real choice.
--
-- SAFE TO RE-RUN.
-- Nothing else changes: no function, no other table, no row outside class.
-- ############################################################################

-- ############################################################################
-- 1 -- THE COLUMN, nullable, so the backfill can tell new rows from chosen ones
-- ############################################################################
DO $add$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'class'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('ALTER TABLE %I.class ADD COLUMN IF NOT EXISTS classtype varchar(12)', r.s);
    -- Dropped so the rename below is possible at all: the first version of
    -- this file wrote a CHECK that allows 'TC' and not 'TERMINAL'.
    EXECUTE format('ALTER TABLE %I.class DROP CONSTRAINT IF EXISTS chk_class_classtype', r.s);
  END LOOP;
END $add$;


-- ############################################################################
-- 2 -- THE EARLIER VOCABULARY, renamed
--
-- An earlier version of this file used TC for the holding class and COMPLETED
-- for the final year. Those two words swapped meaning: a TC class IS the
-- completed one, and the final year is TERMINAL.
--
-- ORDER MATTERS. COMPLETED must move to TERMINAL before TC takes the name
-- COMPLETED, or the two collide and the final years are lost among the TC
-- classes. Guarded on 'TC' still existing, which is true ONLY of the old
-- vocabulary -- so running this file twice cannot rename anything twice.
-- ############################################################################
DO $rename$
DECLARE r RECORD; n_term int; n_comp int; v_old boolean;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'class'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.class WHERE classtype = ''TC'')', r.s)
      INTO v_old;
    CONTINUE WHEN NOT v_old;

    EXECUTE format('UPDATE %I.class SET classtype = ''TERMINAL'' WHERE classtype = ''COMPLETED''', r.s);
    GET DIAGNOSTICS n_term = ROW_COUNT;
    EXECUTE format('UPDATE %I.class SET classtype = ''COMPLETED'' WHERE classtype = ''TC''', r.s);
    GET DIAGNOSTICS n_comp = ROW_COUNT;

    RAISE NOTICE '%: renamed % -> TERMINAL, % TC -> COMPLETED', r.s, n_term, n_comp;
  END LOOP;
END $rename$;


-- ############################################################################
-- 3 -- BACKFILL  (NULLs only)
--
-- A row named like a TC batch is COMPLETED whatever its succeedingclass says
-- -- including the self-referencing ones, which is the whole point. Then
-- TERMINAL for a real class with nowhere to promote to. Everything else is an
-- ordinary year.
-- ############################################################################
DO $fill$
DECLARE r RECORD; n_comp int; n_term int; n_prom int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'class'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    -- "CSE TC 25", "MCA TC 26" -- TC as a whole word, not the TC inside a
    -- name like "B.TECH".
    EXECUTE format($q$
      UPDATE %I.class SET classtype = 'COMPLETED'
       WHERE classtype IS NULL
         AND claname ~* '(^|[^A-Za-z])TC([^A-Za-z]|$)' $q$, r.s);
    GET DIAGNOSTICS n_comp = ROW_COUNT;

    -- A class that promotes INTO a TC class is the final year. This is how
    -- live models graduation ("B.E ECE -IV -> ECE TC 23"), so it has to be
    -- read as TERMINAL -- otherwise every final year comes out PROMOTIONAL.
    -- Runs after the COMPLETED step above, which is what types the targets.
    EXECUTE format($q$
      UPDATE %I.class c SET classtype = 'TERMINAL'
        FROM %I.class nc
       WHERE c.classtype IS NULL
         AND nc.cla_id = c.succeedingclass
         AND nc.classtype = 'COMPLETED' $q$, r.s, r.s);
    GET DIAGNOSTICS n_term = ROW_COUNT;

    EXECUTE format($q$
      UPDATE %I.class SET classtype = 'TERMINAL'
       WHERE classtype IS NULL
         AND succeedingclass IS NULL $q$, r.s);
    GET DIAGNOSTICS n_prom = ROW_COUNT;
    n_term := n_term + n_prom;

    EXECUTE format($q$
      UPDATE %I.class SET classtype = 'PROMOTIONAL'
       WHERE classtype IS NULL $q$, r.s);
    GET DIAGNOSTICS n_prom = ROW_COUNT;

    IF n_comp + n_term + n_prom > 0 THEN
      RAISE NOTICE '%: % COMPLETED (TC), % TERMINAL (final year), % PROMOTIONAL',
                   r.s, n_comp, n_term, n_prom;
    END IF;
  END LOOP;
END $fill$;


-- ############################################################################
-- 3b -- CORRECTION for a database typed by the first version of this file
--
-- The backfill above only fills NULLs, so a schema that was already typed
-- before the "promotes into a TC class" rule existed keeps its final years as
-- PROMOTIONAL. This corrects exactly that case and nothing else: a class typed
-- PROMOTIONAL whose succeeding class is a COMPLETED (TC) one. Part 6 then
-- clears the link, after which it no longer matches -- so re-running is a
-- no-op.
-- ############################################################################
DO $fixterm$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'class'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      UPDATE %I.class c SET classtype = 'TERMINAL'
        FROM %I.class nc
       WHERE c.classtype = 'PROMOTIONAL'
         AND nc.cla_id = c.succeedingclass
         AND nc.classtype = 'COMPLETED' $q$, r.s, r.s);
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN
      RAISE NOTICE '%: % final-year class(es) promoting into a TC class are now TERMINAL', r.s, n;
    END IF;
  END LOOP;
END $fixterm$;


-- ############################################################################
-- 4 -- LOCK IT DOWN
-- ############################################################################
DO $lock$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'class'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('ALTER TABLE %I.class ALTER COLUMN classtype SET DEFAULT ''PROMOTIONAL''', r.s);
    EXECUTE format('UPDATE %I.class SET classtype = ''PROMOTIONAL'' WHERE classtype IS NULL', r.s);
    EXECUTE format('ALTER TABLE %I.class ALTER COLUMN classtype SET NOT NULL', r.s);
    EXECUTE format($q$ALTER TABLE %I.class ADD CONSTRAINT chk_class_classtype
                      CHECK (classtype IN ('PROMOTIONAL','TERMINAL','COMPLETED'))$q$, r.s);
  END LOOP;
END $lock$;


-- ############################################################################
-- 5 -- VERIFY  (read-only)
-- ############################################################################
SELECT classtype, count(*) AS classes
  FROM kcet20262027.class
 GROUP BY classtype
 ORDER BY classtype;

-- Rows whose Succeeding Class contradicts their type. Only a PROMOTIONAL class
-- should have one, and nothing should succeed itself.
SELECT cla_id, claname, classtype, succeedingclass,
       CASE WHEN cla_id = succeedingclass THEN 'succeeds ITSELF'
            WHEN classtype <> 'PROMOTIONAL' AND succeedingclass IS NOT NULL
              THEN 'not promotional, but promotes to something'
            WHEN classtype = 'PROMOTIONAL' AND succeedingclass IS NULL
              THEN 'promotional, but promotes to nothing'
       END AS issue
  FROM kcet20262027.class
 WHERE activestatus = 1
   AND (cla_id = succeedingclass
        OR (classtype <> 'PROMOTIONAL' AND succeedingclass IS NOT NULL)
        OR (classtype = 'PROMOTIONAL' AND succeedingclass IS NULL))
 ORDER BY classtype, claname;


-- ############################################################################
-- 6 -- REPAIR: a class that does not promote must not point at anything
--
-- This is what clears the rows that succeed THEMSELVES. They are all TC
-- classes, and a self-reference is indistinguishable from a real promotion to
-- anything reading succeedingclass -- which is how 1,851 students in TC
-- classes looked promotable.
--
-- Only touches rows whose type already says they do not promote, so it cannot
-- break a live ladder. Re-running changes nothing.
-- ############################################################################
DO $repair$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'class'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      UPDATE %I.class SET succeedingclass = NULL
       WHERE classtype <> 'PROMOTIONAL'
         AND succeedingclass IS NOT NULL $q$, r.s);
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN
      RAISE NOTICE '%: % non-promotional class(es) no longer promote', r.s, n;
    END IF;
  END LOOP;
END $repair$;


-- ############################################################################
-- 7 -- NEW SCHEMAS GET THE COLUMN TOO
--
-- create_institution_schema builds the schema for a new YEAR and for a brand
-- new institution. Without this a new year would come up with no classtype at
-- all and the Class screen would have nothing to write.
--
-- Taken from the running definition with pg_get_functiondef and edited by
-- script: the only difference is the classtype clause on the class table.
-- ############################################################################
CREATE OR REPLACE FUNCTION public.create_institution_schema(p_schema_name text, p_ins_id integer DEFAULT NULL::integer, p_year_label text DEFAULT NULL::text, p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$

DECLARE v_schema text := lower(p_schema_name); v_inscode varchar(10);

BEGIN

  -- Get inscode for year record

  IF p_ins_id IS NOT NULL THEN

    SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = p_ins_id;

  END IF;

  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);



  -- year

  EXECUTE format('CREATE TABLE %I.year (yr_id integer NOT NULL PRIMARY KEY, ins_id integer NOT NULL, yrlabel varchar(9) NOT NULL, yrstadate date NOT NULL, yrenddate date NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- students

  -- students — `aadharno + community/caste/religion/nationality/transportmode/hostel`

  -- columns are carried over from public.admission during class allocation.

  EXECUTE format('CREATE TABLE %I.students (stu_id bigint NOT NULL PRIMARY KEY CHECK (stu_id > 0), ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, stuadmno varchar(25) NOT NULL, stuadmdate date NOT NULL, stuname varchar(50) NOT NULL, stugender char(1) NOT NULL CHECK (stugender = ANY(ARRAY[''M'',''F'',''T''])), studob date NOT NULL, stumobile varchar(30), stuemail varchar(254), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stugeocoordinates varchar(40), stubloodgrp varchar(20), stuphoto text, stuclass varchar(20) NOT NULL, cour_id integer, admit_cour_id smallint, courname varchar(20), con_id integer, stucondesc varchar(20), stuser_id varchar(25) NOT NULL, stupassword varchar(255), stumobotp numeric(6,0), stuotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now() NOT NULL, suspendeddate date, suspendedby varchar(50), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,3,4,5,9])), createdon timestamp DEFAULT now() NOT NULL, terminatedreason text, batch varchar(9), preadmission smallint DEFAULT 0 NOT NULL CHECK (preadmission = ANY(ARRAY[0,1])), admname varchar(30), quoname varchar(30), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), emisno varchar(30), umisno varchar(30), scholarship char(1), scholarshiptype varchar(60), medium varchar(30), cla_id smallint, adm_id smallint, quo_id smallint)', v_schema);

  -- No UNIQUE on stuemail: students commonly share or lack an email (bulk import

  -- of hundreds would fail on the first shared/placeholder address).

  EXECUTE format('ALTER TABLE %I.students ADD CONSTRAINT uq_students_admission UNIQUE (ins_id, stuadmno)', v_schema);



  -- parents

  EXECUTE format('CREATE TABLE %I.parents (par_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), partype char(1) NOT NULL CHECK (partype = ANY(ARRAY[''P'',''G''])), paremail varchar(254), fathername varchar(50), mothername varchar(50), guardianname varchar(50), fathermobile varchar(20), mothermobile varchar(20), guardianmobile varchar(20), fatheroccupation varchar(60), motheroccupation varchar(60), guardianoccupation varchar(60), payincharge varchar(50) NOT NULL, payinchargemob varchar(20) NOT NULL, parpassword varchar(255), parmobotp numeric(6,0), parmobotp_at timestamp, parotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now(), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,9])), ins_id integer)', v_schema);

  -- No UNIQUE on paremail: parents commonly share an email (siblings / one family

  -- email), so a bulk student import would fail on the first shared address.



  -- parentdetail

  EXECUTE format('CREATE TABLE %I.parentdetail (pd_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), par_id bigint NOT NULL, stu_id bigint NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, stuadmno varchar(20) NOT NULL UNIQUE, stuname varchar(50) NOT NULL, stuclass varchar(20) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- feedemand — `collectible=false` rows are recorded but never shown for

  -- collection; carried through from the classfeedemand template.

  EXECUTE format('CREATE TABLE %I.feedemand (dem_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, demseqtype varchar(20) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, paidamount numeric(12,2) DEFAULT 0, fineamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) CHECK (balancedue >= 0), reconbalancedue numeric(12,2) DEFAULT 0, duedate date NOT NULL, pay_id integer, paidstatus char(1) DEFAULT ''U'' NOT NULL CHECK (paidstatus = ANY(ARRAY[''P'',''U''])), createdby varchar(50) NOT NULL, createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])), inactivedate timestamp, remarks varchar(50), fee_id integer, courname varchar(20), collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, cf_id integer, arrearclass varchar(30))', v_schema);



  -- tempfeedemand (staging — copied into feedemand by fn_approve_tempfeedemand on approval)

  EXECUTE format('CREATE TABLE %I.tempfeedemand (temp_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, courname varchar(20), demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2), duedate date NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), isapproved boolean DEFAULT false, collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, fee_id integer, cf_id integer, demseqtype varchar(20), arrearclass varchar(30))', v_schema);



  -- Demand generation + approval performance indexes. The dedup NOT EXISTS

  -- checks (generate_feedemand_from_template / _for_class) and the approval

  -- trigger's per-row feedemand lookup would otherwise sequential-scan and grow

  -- O(N^2) as feedemand fills, timing out on bulk generate/approve.

  EXECUTE format('CREATE INDEX idx_feedemand_dedup ON %I.feedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);

  EXECUTE format('CREATE INDEX idx_tempfeedemand_dedup ON %I.tempfeedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);

  EXECUTE format('CREATE INDEX idx_feedemand_demno_type ON %I.feedemand (ins_id, demno, demfeetype) WHERE activestatus = 1', v_schema);



  -- Approval trigger: copy temp → feedemand carrying the collectible flag.

  EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_dem_id bigint; v_paid numeric; v_net numeric; BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid FROM %1$I.feedemand WHERE ins_id = NEW.ins_id AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> '''' AND demno IS NOT DISTINCT FROM NEW.demno AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype AND activestatus = 1 ORDER BY dem_id LIMIT 1; IF v_dem_id IS NOT NULL THEN v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0); UPDATE %1$I.feedemand SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount, balancedue = v_net, reconbalancedue = v_net, duedate = NEW.duedate, collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id, demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass WHERE dem_id = v_dem_id; ELSE INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); END IF; NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER trg_tempfeedemand_approve BEFORE UPDATE OF isapproved ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.fn_approve_tempfeedemand()', v_schema, v_schema);



  -- feegroup

  EXECUTE format('CREATE TABLE %I.feegroup (fg_id integer NOT NULL PRIMARY KEY, fgdesc varchar(30) NOT NULL, ban_id integer, ins_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);



  -- feetype (feefineapplicable: 1 = fines apply when overdue, 0 = no fine)

  EXECUTE format('CREATE TABLE %I.feetype (fee_id integer NOT NULL PRIMARY KEY, feedesc varchar(30) NOT NULL, feeshort varchar(10) NOT NULL, feefineapplicable smallint DEFAULT 0, fg_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])), ins_id integer, type varchar(20), payseq smallint DEFAULT 100, partialallowed char(1) DEFAULT ''Y'')', v_schema);

  -- (feegroup_accountant removed — unused scaffold; no app or DB references.)

  EXECUTE format('ALTER TABLE %I.feetype ADD CONSTRAINT fk_feetype_feegroup FOREIGN KEY (fg_id) REFERENCES %I.feegroup(fg_id)', v_schema, v_schema);

  -- Lets PostgREST resolve embedded selects like feedemand?select=*,feetype(*) in the mobile app.

  EXECUTE format('ALTER TABLE %I.feedemand ADD CONSTRAINT fk_feedemand_feetype FOREIGN KEY (fee_id) REFERENCES %I.feetype(fee_id) NOT VALID', v_schema, v_schema);



  -- concessioncategory

  EXECUTE format('CREATE TABLE %I.concessioncategory (con_id integer NOT NULL PRIMARY KEY, condesc varchar(20) NOT NULL, ins_id integer NOT NULL, ordid integer, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])))', v_schema);



  -- course

  EXECUTE format('CREATE TABLE %I.course (cour_id integer NOT NULL PRIMARY KEY, courname varchar(100) NOT NULL, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- class

  EXECUTE format('CREATE TABLE %I.class (cla_id integer NOT NULL PRIMARY KEY, claname varchar(20) NOT NULL, ins_id integer, ordid smallint, succeedingclass integer, cour_id integer, activestatus smallint DEFAULT 1 NOT NULL, classtype varchar(12) DEFAULT ''PROMOTIONAL'' NOT NULL CHECK (classtype = ANY(ARRAY[''PROMOTIONAL'',''TERMINAL'',''COMPLETED''])))', v_schema);

  -- succeedingclass is the cla_id of the next class in the promotion ladder

  -- (NULL for the terminal class). cour_id is optional / informational.



  -- admissiontype + quota + community + division + semester master lookups.

  -- (Register-number sequencing lives in the shared `sequence` table below,

  --  actname = 'REGNO' — not a separate regnoseq table anymore.)

  EXECUTE format('CREATE TABLE %I.admissiontype (adm_id smallint PRIMARY KEY, admname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  EXECUTE format('CREATE TABLE %I.quota (quo_id smallint PRIMARY KEY, quoname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  -- Community master (lookup for the admission form).

  EXECUTE format('CREATE TABLE %I.community (com_id smallint PRIMARY KEY, comname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  EXECUTE format('CREATE TABLE %I.division (div_id smallint PRIMARY KEY, divname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  -- (Register-number sequencing now lives in the shared `sequence` table below,

  --  actname = 'REGNO' — the separate regnoseq table has been retired.)

  -- Semester master (drives the demfeeterm dropdown in Fee Demand / Class Fee Demand).

  EXECUTE format('CREATE TABLE %I.semester (sem_id smallint PRIMARY KEY, semname varchar(30) NOT NULL, semshort varchar(10), semtype char(1) NOT NULL DEFAULT ''S'' CHECK (semtype IN (''S'',''M'',''Y'')), semstart date, semend date, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);



  -- classfeedemand — `collectible` carries the "ALL" tick from the template into

  -- each generated tempfeedemand/feedemand row.

  EXECUTE format('CREATE TABLE %I.classfeedemand (cf_id integer NOT NULL PRIMARY KEY, cfclass varchar(20), cfterm varchar(20), cffeetype varchar(30), cfamount numeric(12,2), cfdduedate date, admissiontype smallint, collectible boolean DEFAULT false NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, cla_id smallint, sem_id smallint, fee_id integer)', v_schema);



  -- NOTE: on-admission (per-student-insert) fee-demand auto-generation was

  -- reverted. There is deliberately no fn_gen_feedemand_on_student function or

  -- trg_gen_feedemand_on_student trigger here. Adding a student does NOT create

  -- demands. Generate them explicitly via generate_feedemand_for_class /

  -- generate_feedemand_from_template (or the Fee Demand screen).



  -- finerule (overdue fine slabs configured by admin)

  EXECUTE format('CREATE TABLE %I.finerule (fr_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, rulename varchar(50) NOT NULL, feetype varchar(30) DEFAULT ''ALL'', from_days integer NOT NULL, to_days integer, fine_type varchar(10) DEFAULT ''FIXED'' CHECK (fine_type IN (''FIXED'',''PERCENT'')), fine_value numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);





  -- payment

  EXECUTE format('CREATE TABLE %I.payment (pay_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), transtotalamount numeric(12,2) NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paydate timestamp, paystatus char(1) CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), paygwresponse numeric(15,0), payitems text, createdby varchar(100), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, paynumber varchar(30) UNIQUE, payorderid varchar(100), notification_read boolean DEFAULT false, paychequeno varchar(50), paychequedate date, paybankname varchar(100), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, ban_id integer, tender_amount numeric(12,2), refund_amount numeric(12,2), voidedby varchar(100), voideddate timestamp, voidreason varchar(255))', v_schema);



  -- bank: per-institution beneficiary account list. Fee groups are

  -- tagged with ban_id so a single payment can be split (mock for now —

  -- real splits later via Razorpay Route or virtual accounts).

  EXECUTE format('CREATE TABLE %I.bank (ban_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer, banname varchar(45) NOT NULL, banbranch varchar(80) NOT NULL, ifsccode varchar(15) NOT NULL, banaddress1 varchar(50) NOT NULL, banaddress2 varchar(50), banaddress3 varchar(50), banmobile varchar(15), banemail varchar(60), banaccno varchar(20) NOT NULL, banaccholder varchar(50) NOT NULL, paytm_mid varchar(40), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);

  EXECUTE format('ALTER TABLE %I.feegroup ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_feegroup_bank', v_schema);

  EXECUTE format('ALTER TABLE %I.payment ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_payment_bank', v_schema);



  -- paymentdetails

  EXECUTE format('CREATE TABLE %I.paymentdetails (pyd_id bigint NOT NULL PRIMARY KEY, pay_id bigint NOT NULL, dem_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), ins_id integer NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- paymentgateway

  EXECUTE format('CREATE TABLE %I.paymentgateway (gw_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, gwname varchar(100) NOT NULL, gwapikey varchar(255), gwapisecret varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- interim_promotion (mid-year move of a single student to another class;

  -- keeps the before/after course+class for audit)

  EXECUTE format('CREATE TABLE %I.interim_promotion (ip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no integer NOT NULL, ins_id integer NOT NULL, promotiondate date NOT NULL, stu_id bigint, stuadmno varchar(25), stuname varchar(50), courname varchar(20), stuclass varchar(20), admname varchar(30), transferred_courname varchar(20), transferred_class varchar(20), transferred_admname varchar(30), remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE INDEX idx_interim_promotion_stu ON %I.interim_promotion (ins_id, stu_id)', v_schema);



  -- fee_refund (refund voucher header; one row per refund raised against a receipt/payment)

  EXECUTE format('CREATE TABLE %I.fee_refund (rf_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), refunddate date NOT NULL, pay_id bigint, paynumber varchar(30), stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), refundmode varchar(20) NOT NULL, ban_id integer, bankname varchar(100), bankref varchar(100), chequedate date, accountcode varchar(50), refundreason varchar(200), totalrefund numeric(12,2) DEFAULT 0, totaladjust numeric(12,2) DEFAULT 0, createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- fee_refunddetails (per fee-line breakdown of a refund voucher; dem_id references this schema''s feedemand by value)

  EXECUTE format('CREATE TABLE %I.fee_refunddetails (rfd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, rf_id bigint NOT NULL, dem_id bigint, ins_id integer NOT NULL, refundterm varchar(20), refundfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, refundamount numeric(12,2) DEFAULT 0, adjustamount numeric(12,2) DEFAULT 0, adjustreason varchar(200), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- concession (concession voucher header; one row per concession applied to a student) + concessiondetail (per fee-line breakdown). Written only via process_concession(). See migrations/add_concession_tables.sql.

  EXECUTE format('CREATE TABLE %I.concession (con_hdr_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30), ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), condate date NOT NULL DEFAULT CURRENT_DATE, stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), con_id integer, contype varchar(30), totalfee numeric(12,2) DEFAULT 0, totalconcession numeric(12,2) DEFAULT 0, totalbalance numeric(12,2) DEFAULT 0, remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE TABLE %I.concessiondetail (cond_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, con_hdr_id bigint NOT NULL, ins_id integer NOT NULL, stu_id bigint, stuadmno varchar(25), receiptno varchar(30), dem_id bigint, demfeeterm varchar(20), demfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) DEFAULT 0, con_id integer, contype varchar(30), condate date, createdby varchar(50), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE INDEX idx_concession_stu ON %I.concession (ins_id, stu_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_concessiondetail_hdr ON %I.concessiondetail (con_hdr_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_concessiondetail_stu ON %I.concessiondetail (ins_id, stu_id)', v_schema);



  -- misc_collection (standalone counter collection: BONAFIDE, APPLICATION, …).

  -- Does NOT touch feedemand. selection ''S'' = registered student, ''O'' = others.

  -- Receipt number (mcno) is drawn from the shared fee-receipt sequence.

  EXECUTE format('CREATE TABLE %I.misc_collection (mc_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), mcno varchar(30) NOT NULL, mcdate date NOT NULL DEFAULT CURRENT_DATE, selection char(1) NOT NULL DEFAULT ''S'' CHECK (selection IN (''S'',''O'')), stu_id bigint, regno varchar(25), stuclass varchar(30), stuname varchar(100) NOT NULL, courname varchar(20), city varchar(50), address varchar(255), paymode varchar(20) DEFAULT ''Cash'', ban_id integer, bankname varchar(100), transrefno varchar(50), paytm_txnid varchar(60), draweebank varchar(100), transdate date, transamt numeric(12,2), collectedby varchar(50), remarks varchar(255), totalamount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamptz, bank_reference varchar(100), bank_date date, paystatus char(1) DEFAULT ''C'', voidedby varchar(100), voideddate timestamptz, voidreason varchar(255))', v_schema);

  EXECUTE format('CREATE TABLE %I.misc_collection_detail (mcd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, mc_id bigint NOT NULL, ins_id integer NOT NULL, fee_id integer, feetype varchar(30) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE INDEX idx_misc_detail_mc ON %I.misc_collection_detail (mc_id)', v_schema);



  -- advance_collection (money taken BEFORE any fee is due). Mirrors `payment`'s

  -- money/reconcile columns but carries NO fg_id / fee_id -- an advance is just

  -- an amount held against the student. It is later applied to specific fee

  -- demands ("adjusted"), which advadjustment records. Receipt number (advno)

  -- comes from the schema's own sequence, actname='ADVNO' (Fee Master ->

  -- Advance No). balanceamount is GENERATED, so it can never drift from its

  -- parts. See migrations/add_advance_collection.sql.

  EXECUTE format('CREATE TABLE %I.advance_collection (adv_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id bigint NOT NULL, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), yr_id integer, yrlabel varchar(20), advno varchar(30) NOT NULL, advdate timestamp DEFAULT now() NOT NULL, advtype char(1) DEFAULT ''S'' NOT NULL CHECK (advtype = ANY(ARRAY[''A'',''S''])), transtotalamount numeric(12,2) NOT NULL CHECK (transtotalamount > 0), adjustedamount numeric(12,2) DEFAULT 0 NOT NULL, refund_amount numeric(12,2) DEFAULT 0 NOT NULL, balanceamount numeric(12,2) GENERATED ALWAYS AS (transtotalamount - adjustedamount - refund_amount) STORED, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paystatus char(1) DEFAULT ''C'' NOT NULL CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), payorderid varchar(100), paytm_txnid varchar(60), paychequeno varchar(50), paychequedate date, paybankname varchar(100), ban_id integer, recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, tender_amount numeric(12,2), remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, voidedby varchar(100), voideddate timestamp, voidreason varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE UNIQUE INDEX uq_advance_advno ON %I.advance_collection (ins_id, advno)', v_schema);

  EXECUTE format('CREATE INDEX idx_advance_stu ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1', v_schema);

  -- Drives "students with an unused advance" (the Fee Collection highlight).

  EXECUTE format('CREATE INDEX idx_advance_open ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1 AND balanceamount > 0', v_schema);



  -- advance_detail: the fee-type breakdown of an ADMISSION advance

  -- (advtype ''A''). Mirrors misc_collection_detail. A student advance

  -- (advtype ''S'') is a plain amount and has no rows here at all.

  -- feetype is varchar(60), not misc''s 30: real fee names run long.

  EXECUTE format('CREATE TABLE %I.advance_detail (advd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, fee_id integer, fg_id integer, feetype varchar(60) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);

  EXECUTE format('CREATE INDEX idx_advance_detail_adv ON %I.advance_detail (adv_id)', v_schema);



  -- advadjustment: one row per amount moved off an advance onto a fee demand,

  -- with the fee receipt that settlement raised.

  EXECUTE format('CREATE TABLE %I.advadjustment (adj_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, stu_id bigint, dem_id bigint, pay_id bigint, paynumber varchar(30), demfeeterm varchar(20), demfeetype varchar(30), adjustamount numeric(12,2) NOT NULL CHECK (adjustamount > 0), adjustdate date DEFAULT CURRENT_DATE NOT NULL, remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);

  EXECUTE format('CREATE INDEX idx_advadjustment_adv ON %I.advadjustment (adv_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_advadjustment_dem ON %I.advadjustment (ins_id, dem_id)', v_schema);



  -- sequence: unified numbering for BOTH fee-receipt sequences (fg_id set,

  -- actname = fee-group name) AND admission/register-number sequences

  -- (fg_id NULL, actname = 'REGNO'; the seqend + division columns apply only to

  -- register sequences). Register numbers replace the old separate regnoseq table.

  EXECUTE format('CREATE TABLE %I.sequence (seq_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, mod_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, actname varchar(30) NOT NULL, seqname varchar(50) NOT NULL, isprefix char(1) NOT NULL, seqprefix varchar(15) NOT NULL, seqstart numeric(9,0) NOT NULL, seqwidth numeric(2,0) NOT NULL, sequid varchar(18) NOT NULL, seqcurno numeric(9,0) NOT NULL, seqend numeric(9,0), division varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, fg_id integer)', v_schema);



  -- shoppingcart

  EXECUTE format('CREATE TABLE %I.shoppingcart (car_id integer NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, stu_id bigint NOT NULL, transtype varchar(10) NOT NULL, transdate date DEFAULT CURRENT_DATE NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, carinitiated char(1) DEFAULT ''N'' NOT NULL, createdby varchar(50) NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE UNIQUE INDEX unique_active_cart_per_student ON %I.shoppingcart (stu_id) WHERE activestatus = 1', v_schema);



  -- shoppingcartdetails

  EXECUTE format('CREATE TABLE %I.shoppingcartdetails (cd_id integer NOT NULL PRIMARY KEY, car_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, dem_id bigint NOT NULL, transdetail_id integer, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- notice

  EXECUTE format('CREATE TABLE %I.notice (notice_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, noticetitle text NOT NULL, noticedesc text, noticepriority varchar(20) DEFAULT ''Normal'', noticecategory varchar(50) DEFAULT ''General'', noticetarget text, createdby varchar(50), createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1, noticefromdate date, noticetodate date)', v_schema);

  EXECUTE format('CREATE INDEX idx_notice_ins_id ON %I.notice (ins_id)', v_schema);



  -- notification

  EXECUTE format('CREATE TABLE %I.notification (noti_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, stu_id integer, notice_id bigint, notititle text, notibody text, notitype varchar(50), isread integer DEFAULT 0, createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1)', v_schema);

  EXECUTE format('CREATE INDEX idx_notification_notice_id ON %I.notification(notice_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_notification_ins_id ON %I.notification (ins_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_notification_stu_id ON %I.notification (stu_id)', v_schema);



  -- userlogin

  EXECUTE format('CREATE TABLE %I.userlogin (ul_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), uluser varchar(50), ulusetype smallint, ultime timestamp, ulattempt smallint DEFAULT 0, ulip varchar(40), ullocation varchar(50), ulsuccess char(1) DEFAULT ''N'' NOT NULL, ulsesid numeric, ulsesstart timestamp DEFAULT now() NOT NULL, ulsesend timestamp, ulsestime timestamp)', v_schema);





  -- student_import

  EXECUTE format('CREATE TABLE %I.student_import (imp_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), stuadmno varchar(25) NOT NULL, stuname varchar(50) NOT NULL, stugender char(1), studob date, stuadmdate date, stuclass varchar(20) NOT NULL, courname varchar(20), stumobile varchar(30), stuemail varchar(254), concession varchar(50), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stubloodgrp varchar(20), fathername varchar(50), fathermobile varchar(30), fatheroccupation varchar(50), mothername varchar(50), mothermobile varchar(30), motheroccupation varchar(50), guardianname varchar(50), guardianmobile varchar(30), guardianoccupation varchar(50), payincharge varchar(50), payinchargemob varchar(30), admname varchar(50), quoname varchar(50), batch varchar(9), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), paremail varchar(254), cla_id smallint, cour_id integer, admit_cour_id smallint, medium varchar(30), adm_id smallint, quo_id smallint, status varchar(10) DEFAULT ''PENDING'', error_msg text, created_at timestamp DEFAULT now())', v_schema);



  -- FOREIGN KEYS

  EXECUTE format('ALTER TABLE %I.paymentdetails ADD CONSTRAINT fk_paymentdetails_payment FOREIGN KEY (pay_id) REFERENCES %I.payment(pay_id)', v_schema, v_schema);

  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_car_id_fkey FOREIGN KEY (car_id) REFERENCES %I.shoppingcart(car_id)', v_schema, v_schema);

  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_dem_id_fkey FOREIGN KEY (dem_id) REFERENCES %I.feedemand(dem_id)', v_schema, v_schema);



  -- ============================================

  -- TRIGGER FUNCTIONS (per schema)

  -- ============================================



  -- Auto-increment triggers for all tables

  EXECUTE format('CREATE FUNCTION %I.set_yr_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.yr_id IS NULL OR NEW.yr_id = 0 THEN NEW.yr_id := COALESCE((SELECT MAX(yr_id) FROM %I.year), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_year_yr_id BEFORE INSERT ON %I.year FOR EACH ROW EXECUTE FUNCTION %I.set_yr_id()', v_schema, v_schema);



  -- students: sequence-backed id, no hardcoded storage URL (photos resolved client-side)

  EXECUTE format('CREATE SEQUENCE %I.students_stu_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_stu_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stu_id IS NULL OR NEW.stu_id = 0 THEN NEW.stu_id := nextval(''%I.students_stu_id_seq''); END IF; IF (NEW.cour_id IS NULL OR NEW.cour_id = 0) AND NEW.courname IS NOT NULL AND TRIM(NEW.courname) != '''' THEN SELECT c.cour_id INTO NEW.cour_id FROM %I.course c WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM(NEW.courname)) AND c.ins_id = NEW.ins_id LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_students_before_insert BEFORE INSERT ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.set_stu_id()', v_schema, v_schema);



  -- parents: sequence-backed id

  EXECUTE format('CREATE SEQUENCE %I.parents_par_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_par_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.par_id IS NULL OR NEW.par_id = 0 THEN NEW.par_id := nextval(''%I.parents_par_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_parents_before_insert BEFORE INSERT ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.set_par_id()', v_schema, v_schema);



  -- parentdetail: sequence-backed id

  EXECUTE format('CREATE SEQUENCE %I.parentdetail_pd_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_pd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pd_id IS NULL OR NEW.pd_id = 0 THEN NEW.pd_id := nextval(''%I.parentdetail_pd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_parentdetail_auto_id BEFORE INSERT ON %I.parentdetail FOR EACH ROW EXECUTE FUNCTION %I.set_pd_id()', v_schema, v_schema);



  -- feedemand uses a real sequence (bulk import path — must be O(1) per row)

  EXECUTE format('CREATE SEQUENCE %I.feedemand_dem_id_seq', v_schema);

  EXECUTE format($f$CREATE FUNCTION %I.set_dem_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.dem_id IS NULL OR NEW.dem_id = 0 THEN NEW.dem_id := nextval('%I.feedemand_dem_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.dem_id::TEXT, 5, '0'); END IF; END IF; IF NEW.demseqtype IS NULL OR TRIM(NEW.demseqtype) = '' THEN NEW.demseqtype := 'DEMAND'; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.demfeetype IS NOT NULL THEN SELECT ft.fee_id INTO NEW.fee_id FROM %I.feetype ft WHERE ft.feedesc = NEW.demfeetype AND ft.activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_feedemand_before_insert BEFORE INSERT ON %I.feedemand FOR EACH ROW EXECUTE FUNCTION %I.set_dem_id()', v_schema, v_schema);



  -- tempfeedemand uses a real sequence (bulk import path — must be O(1) per row)

  EXECUTE format('CREATE SEQUENCE %I.tempfeedemand_temp_id_seq', v_schema);

  EXECUTE format($f$CREATE FUNCTION %I.set_temp_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.temp_id IS NULL THEN NEW.temp_id := nextval('%I.tempfeedemand_temp_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.temp_id::TEXT, 5, '0'); END IF; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_temp_id BEFORE INSERT ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_temp_id()', v_schema, v_schema);



  -- Master-table auto-increment sequences. The NULL/0 guard lets callers

  -- supply an explicit id (needed when importing master data from a legacy

  -- system); a plain INSERT without the column gets nextval().

  EXECUTE format('CREATE SEQUENCE %I.feegroup_fg_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_fg_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fg_id IS NULL OR NEW.fg_id = 0 THEN NEW.fg_id := nextval(''%I.feegroup_fg_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_feegroup_fg_id BEFORE INSERT ON %I.feegroup FOR EACH ROW EXECUTE FUNCTION %I.set_fg_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.feetype_fee_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_fee_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fee_id IS NULL OR NEW.fee_id = 0 THEN NEW.fee_id := nextval(''%I.feetype_fee_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_feetype_fee_id BEFORE INSERT ON %I.feetype FOR EACH ROW EXECUTE FUNCTION %I.set_fee_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.concessioncategory_con_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_con_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.con_id IS NULL OR NEW.con_id = 0 THEN NEW.con_id := nextval(''%I.concessioncategory_con_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_concession_con_id BEFORE INSERT ON %I.concessioncategory FOR EACH ROW EXECUTE FUNCTION %I.set_con_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.course_cour_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cour_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cour_id IS NULL OR NEW.cour_id = 0 THEN NEW.cour_id := nextval(''%I.course_cour_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_course_cour_id BEFORE INSERT ON %I.course FOR EACH ROW EXECUTE FUNCTION %I.set_cour_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.class_cla_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cla_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cla_id IS NULL OR NEW.cla_id = 0 THEN NEW.cla_id := nextval(''%I.class_cla_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_class_cla_id BEFORE INSERT ON %I.class FOR EACH ROW EXECUTE FUNCTION %I.set_cla_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.classfeedemand_cf_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cf_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cf_id IS NULL THEN NEW.cf_id := nextval(''%I.classfeedemand_cf_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_classfeedemand_cf_id BEFORE INSERT ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_cf_id()', v_schema, v_schema);

  -- Resolve cla_id / sem_id / fee_id from the cfclass / cfterm / cffeetype names

  -- on insert/update (schema-qualified, so it works from the session-gated RPCs).

  EXECUTE format('CREATE OR REPLACE FUNCTION %I.set_classfee_ids() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF (NEW.cla_id IS NULL OR NEW.cla_id = 0) AND NEW.cfclass IS NOT NULL THEN SELECT cla_id INTO NEW.cla_id FROM %I.class WHERE claname = NEW.cfclass AND activestatus = 1 LIMIT 1; END IF; IF (NEW.sem_id IS NULL OR NEW.sem_id = 0) AND NEW.cfterm IS NOT NULL THEN SELECT sem_id INTO NEW.sem_id FROM %I.semester WHERE semname = NEW.cfterm AND activestatus = 1 LIMIT 1; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.cffeetype IS NOT NULL THEN SELECT fee_id INTO NEW.fee_id FROM %I.feetype WHERE feedesc = NEW.cffeetype AND activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_classfeedemand_ids BEFORE INSERT OR UPDATE ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_classfee_ids()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.payment_pay_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %1$I.set_pay_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_next bigint; BEGIN IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN PERFORM pg_advisory_xact_lock(hashtext(%1$L)::bigint); SELECT COALESCE(MAX(pay_id),0) + 1 INTO v_next FROM %1$I.payment; NEW.pay_id := v_next; END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER trg_payment_auto_increment BEFORE INSERT ON %I.payment FOR EACH ROW EXECUTE FUNCTION %I.set_pay_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.paymentdetails_pyd_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_pyd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pyd_id IS NULL OR NEW.pyd_id = 0 THEN NEW.pyd_id := nextval(''%I.paymentdetails_pyd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_paymentdetails_auto_increment BEFORE INSERT ON %I.paymentdetails FOR EACH ROW EXECUTE FUNCTION %I.set_pyd_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_car_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.car_id := COALESCE((SELECT MAX(car_id) FROM %I.shoppingcart), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_generate_car_id BEFORE INSERT ON %I.shoppingcart FOR EACH ROW EXECUTE FUNCTION %I.set_car_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_cd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.cd_id := COALESCE((SELECT MAX(cd_id) FROM %I.shoppingcartdetails), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_generate_cd_id BEFORE INSERT ON %I.shoppingcartdetails FOR EACH ROW EXECUTE FUNCTION %I.set_cd_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_notice_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.notice_id IS NULL OR NEW.notice_id = 0 THEN NEW.notice_id := COALESCE((SELECT MAX(notice_id) FROM %I.notice), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_notice_id BEFORE INSERT ON %I.notice FOR EACH ROW EXECUTE FUNCTION %I.set_notice_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_noti_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.noti_id IS NULL OR NEW.noti_id = 0 THEN NEW.noti_id := COALESCE((SELECT MAX(noti_id) FROM %I.notification), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_noti_id BEFORE INSERT ON %I.notification FOR EACH ROW EXECUTE FUNCTION %I.set_noti_id()', v_schema, v_schema);



  -- Password hash triggers

  EXECUTE format('CREATE FUNCTION %I.hash_student_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stupassword IS NOT NULL AND NEW.stupassword != '''' AND LEFT(NEW.stupassword, 4) != ''$2a$'' AND LEFT(NEW.stupassword, 4) != ''$2b$'' THEN NEW.stupassword := crypt(NEW.stupassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER hash_student_password_trigger BEFORE INSERT OR UPDATE OF stupassword ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.hash_student_password()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.hash_parent_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.parpassword IS NOT NULL AND NEW.parpassword != '''' AND LEFT(NEW.parpassword, 4) != ''$2a$'' AND LEFT(NEW.parpassword, 4) != ''$2b$'' THEN NEW.parpassword := crypt(NEW.parpassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER hash_parent_password_trigger BEFORE INSERT OR UPDATE OF parpassword ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.hash_parent_password()', v_schema, v_schema);



  -- Transfer Certificate entries (Admission → Transfer Certificate). One row per

  -- TC issued; save_tc_entry writes here and stamps the student's + admission's

  -- activestatus with the leaving code, so non-active students drop out of the

  -- active screens (which filter activestatus=1).

  EXECUTE format('CREATE TABLE %I.tc_entry (tc_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), stu_id bigint, stuadmno varchar(25) NOT NULL, stuname varchar(50), stuclass varchar(20), cla_id smallint, birthdate date, joindate date, status smallint NOT NULL DEFAULT 1 CHECK (status = ANY(ARRAY[1,2,3,4,5,9])), statustype varchar(20), tcno varchar(30), tcdate date, effectfrom date, docno varchar(30), docdate date, remarks varchar(200), createdby varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE SEQUENCE %I.tc_entry_tc_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_tc_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.tc_id IS NULL OR NEW.tc_id = 0 THEN NEW.tc_id := nextval(''%I.tc_entry_tc_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_tc_entry_tc_id BEFORE INSERT ON %I.tc_entry FOR EACH ROW EXECUTE FUNCTION %I.set_tc_id()', v_schema, v_schema);

  EXECUTE format('ALTER TABLE %I.tc_entry ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.tc_entry USING (true) WITH CHECK (true)', v_schema);



  -- (rollno_change lives in public, alongside public.admission — see above.)



  -- (fn_approve_tempfeedemand + trigger are defined right after the tempfeedemand

  -- table above; they carry the `collectible` flag from temp into feedemand.)



  -- RLS

  EXECUTE format('ALTER TABLE %I.notice ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('ALTER TABLE %I.notification ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('ALTER TABLE %I.tempfeedemand ENABLE ROW LEVEL SECURITY', v_schema);

  -- student_import was missing its ENABLE (policy created below), which tripped

  -- the Supabase "Policy Exists RLS Disabled" advisor for every new schema.

  EXECUTE format('ALTER TABLE %I.student_import ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.notice USING (true) WITH CHECK (true)', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.notification USING (true) WITH CHECK (true)', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.tempfeedemand USING (true) WITH CHECK (true)', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.student_import USING (true) WITH CHECK (true)', v_schema);



  -- PERMISSIONS

  EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated', v_schema);

  EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO anon, authenticated', v_schema);

  EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO anon, authenticated', v_schema);

  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO anon, authenticated', v_schema);

  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO anon, authenticated', v_schema);



  -- Auto-create year records if parameters provided

  IF p_ins_id IS NOT NULL AND p_year_label IS NOT NULL THEN

    -- Insert into public.institutionyear, stamping iyrschema so the row

    -- carries the per-year schema name (e.g. 'kcet20262027') without the

    -- app having to re-derive it from inshortname + yrlabel.

    INSERT INTO public.institutionyear (ins_id, inscode, yrlabel, iyrstadate, iyrenddate, iyrschema, activestatus)

    VALUES (p_ins_id, COALESCE(v_inscode, ''), p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year'), v_schema, 1)

    ON CONFLICT (ins_id, yrlabel) DO UPDATE SET iyrschema = EXCLUDED.iyrschema;



    -- Insert into schema year table

    EXECUTE format('INSERT INTO %I.year (ins_id, yrlabel, yrstadate, yrenddate, activestatus) VALUES ($1, $2, $3, $4, 1)', v_schema)

    USING p_ins_id, p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year');

  END IF;



  -- Expose schema to PostgREST (may fail on free tier - handled by app login)

  BEGIN

    PERFORM public.expose_schema(v_schema);

  EXCEPTION WHEN OTHERS THEN

    RAISE NOTICE 'expose_schema skipped: %', SQLERRM;

  END;



  -- Security (Option B): the money tables are written ONLY through session-gated

  -- SECURITY DEFINER RPCs (they run as owner), so a new schema is born with anon

  -- direct-write REVOKED on them. SELECT is left intact (reads unchanged). This

  -- mirrors phase3a_revoke_money_writes.sql for existing schemas.

  EXECUTE format(

    'REVOKE INSERT, UPDATE, DELETE ON %I.payment, %I.paymentdetails, %I.feedemand, '

    '%I.fee_refund, %I.fee_refunddetails, %I.concession, %I.concessiondetail, %I.students, %I.parents, %I.parentdetail, '

    '%I.advance_collection, %I.advance_detail, %I.advadjustment FROM anon',

    v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema,

    v_schema, v_schema, v_schema);



  -- Read lockdown: enable RLS + per-tenant SELECT policy on sensitive tables so a

  -- NEW institution is born read-locked (anon can't SELECT another tenant's PII/

  -- money). Wrapped so a policy hiccup never blocks institution creation.

  BEGIN

    PERFORM public.read_lock_schema(v_schema);

  EXCEPTION WHEN OTHERS THEN

    RAISE NOTICE 'read_lock_schema skipped for %: %', v_schema, SQLERRM;

  END;



END; $function$;


-- ############################################################################
-- 8 -- VERIFY  (read-only)
-- ############################################################################
SELECT CASE WHEN prosrc LIKE '%classtype%' THEN 'yes' ELSE 'NO -- not applied' END
         AS new_schemas_get_classtype
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema';

-- Nothing should come back: no self-reference, and nothing non-promotional
-- still pointing at a class.
SELECT cla_id, claname, classtype, succeedingclass
  FROM kcet20262027.class
 WHERE activestatus = 1
   AND (cla_id = succeedingclass
        OR (classtype <> 'PROMOTIONAL' AND succeedingclass IS NOT NULL))
 ORDER BY claname;


-- ############################################################################
-- ############################################################################
--  PART 3 of 5 -- FIX_PAIDSTATUS_ON_APPROVAL.sql
-- ############################################################################
-- ############################################################################

-- ############################################################################
-- ############################################################################
--
--   EduCore360 -- demands left marked PAID while still owing
--   21-09-2026
--
-- ############################################################################
-- ############################################################################
--
-- A demand can end up with paidstatus = 'P' and balancedue > 0 at the same
-- time. Fee Collection lists demands with paidstatus = 'U', so such a demand
-- is INVISIBLE there -- the student appears to owe nothing -- while Student
-- Fee Definition, which reads balancedue directly, still shows the amount.
--
-- Found on 2627374: a FINE of 700 with 400 paid and 300 outstanding, while
-- the collection screen said "No pending fee demands".
--
-- ---------------------------------------------------------------------------
-- THE CAUSE
-- ---------------------------------------------------------------------------
-- fn_approve_tempfeedemand -- the Fee Demand Approval path. When an approval
-- lands on a demand that ALREADY EXISTS it recomputes the balance:
--
--     v_net := GREATEST(feeamount - conamount - already_paid, 0);
--     UPDATE feedemand SET feeamount = ..., balancedue = v_net, ...
--
-- ...and never touches paidstatus. Raising a demand from 400 to 700 for a
-- student who had already paid the 400 therefore leaves balancedue = 300 on a
-- row still flagged 'P'. The money is owed, and the one screen that collects
-- it cannot see it.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES
-- ---------------------------------------------------------------------------
--   2. repairs existing rows -- the flag follows the balance, both ways
--   3. replaces fn_approve_tempfeedemand in every year schema
--   4. replaces create_institution_schema, so a NEW schema is born with the
--      fixed trigger rather than the broken one
--
-- RUN migrations/CLASS_TYPE.sql FIRST. Part 4 below is generated on top of the
-- definition that file installs, and both replace create_institution_schema --
-- whichever runs last wins.
--
-- SAFE TO RE-RUN. The repair only touches rows whose flag contradicts their
-- own balance; on a clean database it changes nothing.
-- ############################################################################

-- ############################################################################
-- 1 -- BEFORE  (read-only)
-- ############################################################################
SELECT paidstatus,
       COUNT(*) FILTER (WHERE balancedue > 0) AS contradicts_its_balance,
       SUM(balancedue) FILTER (WHERE balancedue > 0)::numeric(14,2) AS hidden_amount
  FROM kcet20262027.feedemand
 WHERE activestatus = 1
 GROUP BY 1 ORDER BY 1;


-- ############################################################################
-- 2 -- REPAIR: the flag follows the balance
--
-- Both directions. 'P' with a balance hides money that is owed; 'U' with no
-- balance keeps a settled demand on the collection screen for ever.
-- ############################################################################
DO $fix$
DECLARE r RECORD; n_open int; n_done int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$UPDATE %I.feedemand SET paidstatus = 'U'
                       WHERE activestatus = 1 AND paidstatus = 'P'
                         AND COALESCE(balancedue,0) > 0$q$, r.s);
    GET DIAGNOSTICS n_open = ROW_COUNT;

    EXECUTE format($q$UPDATE %I.feedemand SET paidstatus = 'P'
                       WHERE activestatus = 1 AND paidstatus = 'U'
                         AND COALESCE(balancedue,0) <= 0
                         AND COALESCE(paidamount,0) > 0$q$, r.s);
    GET DIAGNOSTICS n_done = ROW_COUNT;

    IF n_open + n_done > 0 THEN
      RAISE NOTICE '%: % re-opened (owed but flagged paid), % closed (settled but flagged unpaid)',
                   r.s, n_open, n_done;
    END IF;
  END LOOP;
END $fix$;


-- ############################################################################
-- 3 -- THE APPROVAL TRIGGER, in every existing year schema
-- ############################################################################
DO $fn$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'tempfeedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    v_schema := r.s;
  EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_dem_id bigint; v_paid numeric; v_net numeric; BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid FROM %1$I.feedemand WHERE ins_id = NEW.ins_id AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> '''' AND demno IS NOT DISTINCT FROM NEW.demno AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype AND activestatus = 1 ORDER BY dem_id LIMIT 1; IF v_dem_id IS NOT NULL THEN v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0); UPDATE %1$I.feedemand SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount, balancedue = v_net, reconbalancedue = v_net, paidstatus = CASE WHEN v_net <= 0 THEN ''P'' ELSE ''U'' END, duedate = NEW.duedate, collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id, demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass WHERE dem_id = v_dem_id; ELSE INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); END IF; NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', v_schema);
    RAISE NOTICE '%: fn_approve_tempfeedemand now sets paidstatus', v_schema;
  END LOOP;
END $fn$;


-- ############################################################################
-- 4 -- AND IN NEW SCHEMAS
--
-- create_institution_schema carries its own copy of the trigger. Taken from
-- the running definition with pg_get_functiondef and edited by script: the
-- only difference is the same paidstatus clause.
-- ############################################################################
CREATE OR REPLACE FUNCTION public.create_institution_schema(p_schema_name text, p_ins_id integer DEFAULT NULL::integer, p_year_label text DEFAULT NULL::text, p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$



DECLARE v_schema text := lower(p_schema_name); v_inscode varchar(10);



BEGIN



  -- Get inscode for year record



  IF p_ins_id IS NOT NULL THEN



    SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = p_ins_id;



  END IF;



  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);







  -- year



  EXECUTE format('CREATE TABLE %I.year (yr_id integer NOT NULL PRIMARY KEY, ins_id integer NOT NULL, yrlabel varchar(9) NOT NULL, yrstadate date NOT NULL, yrenddate date NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- students



  -- students — `aadharno + community/caste/religion/nationality/transportmode/hostel`



  -- columns are carried over from public.admission during class allocation.



  EXECUTE format('CREATE TABLE %I.students (stu_id bigint NOT NULL PRIMARY KEY CHECK (stu_id > 0), ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, stuadmno varchar(25) NOT NULL, stuadmdate date NOT NULL, stuname varchar(50) NOT NULL, stugender char(1) NOT NULL CHECK (stugender = ANY(ARRAY[''M'',''F'',''T''])), studob date NOT NULL, stumobile varchar(30), stuemail varchar(254), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stugeocoordinates varchar(40), stubloodgrp varchar(20), stuphoto text, stuclass varchar(20) NOT NULL, cour_id integer, admit_cour_id smallint, courname varchar(20), con_id integer, stucondesc varchar(20), stuser_id varchar(25) NOT NULL, stupassword varchar(255), stumobotp numeric(6,0), stuotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now() NOT NULL, suspendeddate date, suspendedby varchar(50), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,3,4,5,9])), createdon timestamp DEFAULT now() NOT NULL, terminatedreason text, batch varchar(9), preadmission smallint DEFAULT 0 NOT NULL CHECK (preadmission = ANY(ARRAY[0,1])), admname varchar(30), quoname varchar(30), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), emisno varchar(30), umisno varchar(30), scholarship char(1), scholarshiptype varchar(60), medium varchar(30), cla_id smallint, adm_id smallint, quo_id smallint)', v_schema);



  -- No UNIQUE on stuemail: students commonly share or lack an email (bulk import



  -- of hundreds would fail on the first shared/placeholder address).



  EXECUTE format('ALTER TABLE %I.students ADD CONSTRAINT uq_students_admission UNIQUE (ins_id, stuadmno)', v_schema);







  -- parents



  EXECUTE format('CREATE TABLE %I.parents (par_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), partype char(1) NOT NULL CHECK (partype = ANY(ARRAY[''P'',''G''])), paremail varchar(254), fathername varchar(50), mothername varchar(50), guardianname varchar(50), fathermobile varchar(20), mothermobile varchar(20), guardianmobile varchar(20), fatheroccupation varchar(60), motheroccupation varchar(60), guardianoccupation varchar(60), payincharge varchar(50) NOT NULL, payinchargemob varchar(20) NOT NULL, parpassword varchar(255), parmobotp numeric(6,0), parmobotp_at timestamp, parotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now(), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,9])), ins_id integer)', v_schema);



  -- No UNIQUE on paremail: parents commonly share an email (siblings / one family



  -- email), so a bulk student import would fail on the first shared address.







  -- parentdetail



  EXECUTE format('CREATE TABLE %I.parentdetail (pd_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), par_id bigint NOT NULL, stu_id bigint NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, stuadmno varchar(20) NOT NULL UNIQUE, stuname varchar(50) NOT NULL, stuclass varchar(20) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- feedemand — `collectible=false` rows are recorded but never shown for



  -- collection; carried through from the classfeedemand template.



  EXECUTE format('CREATE TABLE %I.feedemand (dem_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, demseqtype varchar(20) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, paidamount numeric(12,2) DEFAULT 0, fineamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) CHECK (balancedue >= 0), reconbalancedue numeric(12,2) DEFAULT 0, duedate date NOT NULL, pay_id integer, paidstatus char(1) DEFAULT ''U'' NOT NULL CHECK (paidstatus = ANY(ARRAY[''P'',''U''])), createdby varchar(50) NOT NULL, createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])), inactivedate timestamp, remarks varchar(50), fee_id integer, courname varchar(20), collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, cf_id integer, arrearclass varchar(30))', v_schema);







  -- tempfeedemand (staging — copied into feedemand by fn_approve_tempfeedemand on approval)



  EXECUTE format('CREATE TABLE %I.tempfeedemand (temp_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, courname varchar(20), demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2), duedate date NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), isapproved boolean DEFAULT false, collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, fee_id integer, cf_id integer, demseqtype varchar(20), arrearclass varchar(30))', v_schema);







  -- Demand generation + approval performance indexes. The dedup NOT EXISTS



  -- checks (generate_feedemand_from_template / _for_class) and the approval



  -- trigger's per-row feedemand lookup would otherwise sequential-scan and grow



  -- O(N^2) as feedemand fills, timing out on bulk generate/approve.



  EXECUTE format('CREATE INDEX idx_feedemand_dedup ON %I.feedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);



  EXECUTE format('CREATE INDEX idx_tempfeedemand_dedup ON %I.tempfeedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);



  EXECUTE format('CREATE INDEX idx_feedemand_demno_type ON %I.feedemand (ins_id, demno, demfeetype) WHERE activestatus = 1', v_schema);







  -- Approval trigger: copy temp → feedemand carrying the collectible flag.



  EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_dem_id bigint; v_paid numeric; v_net numeric; BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid FROM %1$I.feedemand WHERE ins_id = NEW.ins_id AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> '''' AND demno IS NOT DISTINCT FROM NEW.demno AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype AND activestatus = 1 ORDER BY dem_id LIMIT 1; IF v_dem_id IS NOT NULL THEN v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0); UPDATE %1$I.feedemand SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount, balancedue = v_net, reconbalancedue = v_net, paidstatus = CASE WHEN v_net <= 0 THEN ''P'' ELSE ''U'' END, duedate = NEW.duedate, collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id, demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass WHERE dem_id = v_dem_id; ELSE INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); END IF; NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', v_schema);



  EXECUTE format('CREATE TRIGGER trg_tempfeedemand_approve BEFORE UPDATE OF isapproved ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.fn_approve_tempfeedemand()', v_schema, v_schema);







  -- feegroup



  EXECUTE format('CREATE TABLE %I.feegroup (fg_id integer NOT NULL PRIMARY KEY, fgdesc varchar(30) NOT NULL, ban_id integer, ins_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);







  -- feetype (feefineapplicable: 1 = fines apply when overdue, 0 = no fine)



  EXECUTE format('CREATE TABLE %I.feetype (fee_id integer NOT NULL PRIMARY KEY, feedesc varchar(30) NOT NULL, feeshort varchar(10) NOT NULL, feefineapplicable smallint DEFAULT 0, fg_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])), ins_id integer, type varchar(20), payseq smallint DEFAULT 100, partialallowed char(1) DEFAULT ''Y'')', v_schema);



  -- (feegroup_accountant removed — unused scaffold; no app or DB references.)



  EXECUTE format('ALTER TABLE %I.feetype ADD CONSTRAINT fk_feetype_feegroup FOREIGN KEY (fg_id) REFERENCES %I.feegroup(fg_id)', v_schema, v_schema);



  -- Lets PostgREST resolve embedded selects like feedemand?select=*,feetype(*) in the mobile app.



  EXECUTE format('ALTER TABLE %I.feedemand ADD CONSTRAINT fk_feedemand_feetype FOREIGN KEY (fee_id) REFERENCES %I.feetype(fee_id) NOT VALID', v_schema, v_schema);







  -- concessioncategory



  EXECUTE format('CREATE TABLE %I.concessioncategory (con_id integer NOT NULL PRIMARY KEY, condesc varchar(20) NOT NULL, ins_id integer NOT NULL, ordid integer, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])))', v_schema);







  -- course



  EXECUTE format('CREATE TABLE %I.course (cour_id integer NOT NULL PRIMARY KEY, courname varchar(100) NOT NULL, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- class



  EXECUTE format('CREATE TABLE %I.class (cla_id integer NOT NULL PRIMARY KEY, claname varchar(20) NOT NULL, ins_id integer, ordid smallint, succeedingclass integer, cour_id integer, activestatus smallint DEFAULT 1 NOT NULL, classtype varchar(12) DEFAULT ''PROMOTIONAL'' NOT NULL CHECK (classtype = ANY(ARRAY[''PROMOTIONAL'',''TERMINAL'',''COMPLETED''])))', v_schema);



  -- succeedingclass is the cla_id of the next class in the promotion ladder



  -- (NULL for the terminal class). cour_id is optional / informational.







  -- admissiontype + quota + community + division + semester master lookups.



  -- (Register-number sequencing lives in the shared `sequence` table below,



  --  actname = 'REGNO' — not a separate regnoseq table anymore.)



  EXECUTE format('CREATE TABLE %I.admissiontype (adm_id smallint PRIMARY KEY, admname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);



  EXECUTE format('CREATE TABLE %I.quota (quo_id smallint PRIMARY KEY, quoname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);



  -- Community master (lookup for the admission form).



  EXECUTE format('CREATE TABLE %I.community (com_id smallint PRIMARY KEY, comname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);



  EXECUTE format('CREATE TABLE %I.division (div_id smallint PRIMARY KEY, divname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);



  -- (Register-number sequencing now lives in the shared `sequence` table below,



  --  actname = 'REGNO' — the separate regnoseq table has been retired.)



  -- Semester master (drives the demfeeterm dropdown in Fee Demand / Class Fee Demand).



  EXECUTE format('CREATE TABLE %I.semester (sem_id smallint PRIMARY KEY, semname varchar(30) NOT NULL, semshort varchar(10), semtype char(1) NOT NULL DEFAULT ''S'' CHECK (semtype IN (''S'',''M'',''Y'')), semstart date, semend date, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);







  -- classfeedemand — `collectible` carries the "ALL" tick from the template into



  -- each generated tempfeedemand/feedemand row.



  EXECUTE format('CREATE TABLE %I.classfeedemand (cf_id integer NOT NULL PRIMARY KEY, cfclass varchar(20), cfterm varchar(20), cffeetype varchar(30), cfamount numeric(12,2), cfdduedate date, admissiontype smallint, collectible boolean DEFAULT false NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, cla_id smallint, sem_id smallint, fee_id integer)', v_schema);







  -- NOTE: on-admission (per-student-insert) fee-demand auto-generation was



  -- reverted. There is deliberately no fn_gen_feedemand_on_student function or



  -- trg_gen_feedemand_on_student trigger here. Adding a student does NOT create



  -- demands. Generate them explicitly via generate_feedemand_for_class /



  -- generate_feedemand_from_template (or the Fee Demand screen).







  -- finerule (overdue fine slabs configured by admin)



  EXECUTE format('CREATE TABLE %I.finerule (fr_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, rulename varchar(50) NOT NULL, feetype varchar(30) DEFAULT ''ALL'', from_days integer NOT NULL, to_days integer, fine_type varchar(10) DEFAULT ''FIXED'' CHECK (fine_type IN (''FIXED'',''PERCENT'')), fine_value numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);











  -- payment



  EXECUTE format('CREATE TABLE %I.payment (pay_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), transtotalamount numeric(12,2) NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paydate timestamp, paystatus char(1) CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), paygwresponse numeric(15,0), payitems text, createdby varchar(100), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, paynumber varchar(30) UNIQUE, payorderid varchar(100), notification_read boolean DEFAULT false, paychequeno varchar(50), paychequedate date, paybankname varchar(100), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, ban_id integer, tender_amount numeric(12,2), refund_amount numeric(12,2), voidedby varchar(100), voideddate timestamp, voidreason varchar(255))', v_schema);







  -- bank: per-institution beneficiary account list. Fee groups are



  -- tagged with ban_id so a single payment can be split (mock for now —



  -- real splits later via Razorpay Route or virtual accounts).



  EXECUTE format('CREATE TABLE %I.bank (ban_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer, banname varchar(45) NOT NULL, banbranch varchar(80) NOT NULL, ifsccode varchar(15) NOT NULL, banaddress1 varchar(50) NOT NULL, banaddress2 varchar(50), banaddress3 varchar(50), banmobile varchar(15), banemail varchar(60), banaccno varchar(20) NOT NULL, banaccholder varchar(50) NOT NULL, paytm_mid varchar(40), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);



  EXECUTE format('ALTER TABLE %I.feegroup ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_feegroup_bank', v_schema);



  EXECUTE format('ALTER TABLE %I.payment ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_payment_bank', v_schema);







  -- paymentdetails



  EXECUTE format('CREATE TABLE %I.paymentdetails (pyd_id bigint NOT NULL PRIMARY KEY, pay_id bigint NOT NULL, dem_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), ins_id integer NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- paymentgateway



  EXECUTE format('CREATE TABLE %I.paymentgateway (gw_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, gwname varchar(100) NOT NULL, gwapikey varchar(255), gwapisecret varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- interim_promotion (mid-year move of a single student to another class;



  -- keeps the before/after course+class for audit)



  EXECUTE format('CREATE TABLE %I.interim_promotion (ip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no integer NOT NULL, ins_id integer NOT NULL, promotiondate date NOT NULL, stu_id bigint, stuadmno varchar(25), stuname varchar(50), courname varchar(20), stuclass varchar(20), admname varchar(30), transferred_courname varchar(20), transferred_class varchar(20), transferred_admname varchar(30), remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  EXECUTE format('CREATE INDEX idx_interim_promotion_stu ON %I.interim_promotion (ins_id, stu_id)', v_schema);







  -- fee_refund (refund voucher header; one row per refund raised against a receipt/payment)



  EXECUTE format('CREATE TABLE %I.fee_refund (rf_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), refunddate date NOT NULL, pay_id bigint, paynumber varchar(30), stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), refundmode varchar(20) NOT NULL, ban_id integer, bankname varchar(100), bankref varchar(100), chequedate date, accountcode varchar(50), refundreason varchar(200), totalrefund numeric(12,2) DEFAULT 0, totaladjust numeric(12,2) DEFAULT 0, createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- fee_refunddetails (per fee-line breakdown of a refund voucher; dem_id references this schema''s feedemand by value)



  EXECUTE format('CREATE TABLE %I.fee_refunddetails (rfd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, rf_id bigint NOT NULL, dem_id bigint, ins_id integer NOT NULL, refundterm varchar(20), refundfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, refundamount numeric(12,2) DEFAULT 0, adjustamount numeric(12,2) DEFAULT 0, adjustreason varchar(200), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- concession (concession voucher header; one row per concession applied to a student) + concessiondetail (per fee-line breakdown). Written only via process_concession(). See migrations/add_concession_tables.sql.



  EXECUTE format('CREATE TABLE %I.concession (con_hdr_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30), ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), condate date NOT NULL DEFAULT CURRENT_DATE, stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), con_id integer, contype varchar(30), totalfee numeric(12,2) DEFAULT 0, totalconcession numeric(12,2) DEFAULT 0, totalbalance numeric(12,2) DEFAULT 0, remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  EXECUTE format('CREATE TABLE %I.concessiondetail (cond_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, con_hdr_id bigint NOT NULL, ins_id integer NOT NULL, stu_id bigint, stuadmno varchar(25), receiptno varchar(30), dem_id bigint, demfeeterm varchar(20), demfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) DEFAULT 0, con_id integer, contype varchar(30), condate date, createdby varchar(50), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  EXECUTE format('CREATE INDEX idx_concession_stu ON %I.concession (ins_id, stu_id)', v_schema);



  EXECUTE format('CREATE INDEX idx_concessiondetail_hdr ON %I.concessiondetail (con_hdr_id)', v_schema);



  EXECUTE format('CREATE INDEX idx_concessiondetail_stu ON %I.concessiondetail (ins_id, stu_id)', v_schema);







  -- misc_collection (standalone counter collection: BONAFIDE, APPLICATION, …).



  -- Does NOT touch feedemand. selection ''S'' = registered student, ''O'' = others.



  -- Receipt number (mcno) is drawn from the shared fee-receipt sequence.



  EXECUTE format('CREATE TABLE %I.misc_collection (mc_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), mcno varchar(30) NOT NULL, mcdate date NOT NULL DEFAULT CURRENT_DATE, selection char(1) NOT NULL DEFAULT ''S'' CHECK (selection IN (''S'',''O'')), stu_id bigint, regno varchar(25), stuclass varchar(30), stuname varchar(100) NOT NULL, courname varchar(20), city varchar(50), address varchar(255), paymode varchar(20) DEFAULT ''Cash'', ban_id integer, bankname varchar(100), transrefno varchar(50), paytm_txnid varchar(60), draweebank varchar(100), transdate date, transamt numeric(12,2), collectedby varchar(50), remarks varchar(255), totalamount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamptz, bank_reference varchar(100), bank_date date, paystatus char(1) DEFAULT ''C'', voidedby varchar(100), voideddate timestamptz, voidreason varchar(255))', v_schema);



  EXECUTE format('CREATE TABLE %I.misc_collection_detail (mcd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, mc_id bigint NOT NULL, ins_id integer NOT NULL, fee_id integer, feetype varchar(30) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  EXECUTE format('CREATE INDEX idx_misc_detail_mc ON %I.misc_collection_detail (mc_id)', v_schema);







  -- advance_collection (money taken BEFORE any fee is due). Mirrors `payment`'s



  -- money/reconcile columns but carries NO fg_id / fee_id -- an advance is just



  -- an amount held against the student. It is later applied to specific fee



  -- demands ("adjusted"), which advadjustment records. Receipt number (advno)



  -- comes from the schema's own sequence, actname='ADVNO' (Fee Master ->



  -- Advance No). balanceamount is GENERATED, so it can never drift from its



  -- parts. See migrations/add_advance_collection.sql.



  EXECUTE format('CREATE TABLE %I.advance_collection (adv_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id bigint NOT NULL, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), yr_id integer, yrlabel varchar(20), advno varchar(30) NOT NULL, advdate timestamp DEFAULT now() NOT NULL, advtype char(1) DEFAULT ''S'' NOT NULL CHECK (advtype = ANY(ARRAY[''A'',''S''])), transtotalamount numeric(12,2) NOT NULL CHECK (transtotalamount > 0), adjustedamount numeric(12,2) DEFAULT 0 NOT NULL, refund_amount numeric(12,2) DEFAULT 0 NOT NULL, balanceamount numeric(12,2) GENERATED ALWAYS AS (transtotalamount - adjustedamount - refund_amount) STORED, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paystatus char(1) DEFAULT ''C'' NOT NULL CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), payorderid varchar(100), paytm_txnid varchar(60), paychequeno varchar(50), paychequedate date, paybankname varchar(100), ban_id integer, recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, tender_amount numeric(12,2), remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, voidedby varchar(100), voideddate timestamp, voidreason varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  EXECUTE format('CREATE UNIQUE INDEX uq_advance_advno ON %I.advance_collection (ins_id, advno)', v_schema);



  EXECUTE format('CREATE INDEX idx_advance_stu ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1', v_schema);



  -- Drives "students with an unused advance" (the Fee Collection highlight).



  EXECUTE format('CREATE INDEX idx_advance_open ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1 AND balanceamount > 0', v_schema);







  -- advance_detail: the fee-type breakdown of an ADMISSION advance



  -- (advtype ''A''). Mirrors misc_collection_detail. A student advance



  -- (advtype ''S'') is a plain amount and has no rows here at all.



  -- feetype is varchar(60), not misc''s 30: real fee names run long.



  EXECUTE format('CREATE TABLE %I.advance_detail (advd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, fee_id integer, fg_id integer, feetype varchar(60) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);



  EXECUTE format('CREATE INDEX idx_advance_detail_adv ON %I.advance_detail (adv_id)', v_schema);







  -- advadjustment: one row per amount moved off an advance onto a fee demand,



  -- with the fee receipt that settlement raised.



  EXECUTE format('CREATE TABLE %I.advadjustment (adj_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, stu_id bigint, dem_id bigint, pay_id bigint, paynumber varchar(30), demfeeterm varchar(20), demfeetype varchar(30), adjustamount numeric(12,2) NOT NULL CHECK (adjustamount > 0), adjustdate date DEFAULT CURRENT_DATE NOT NULL, remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);



  EXECUTE format('CREATE INDEX idx_advadjustment_adv ON %I.advadjustment (adv_id)', v_schema);



  EXECUTE format('CREATE INDEX idx_advadjustment_dem ON %I.advadjustment (ins_id, dem_id)', v_schema);







  -- sequence: unified numbering for BOTH fee-receipt sequences (fg_id set,



  -- actname = fee-group name) AND admission/register-number sequences



  -- (fg_id NULL, actname = 'REGNO'; the seqend + division columns apply only to



  -- register sequences). Register numbers replace the old separate regnoseq table.



  EXECUTE format('CREATE TABLE %I.sequence (seq_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, mod_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, actname varchar(30) NOT NULL, seqname varchar(50) NOT NULL, isprefix char(1) NOT NULL, seqprefix varchar(15) NOT NULL, seqstart numeric(9,0) NOT NULL, seqwidth numeric(2,0) NOT NULL, sequid varchar(18) NOT NULL, seqcurno numeric(9,0) NOT NULL, seqend numeric(9,0), division varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, fg_id integer)', v_schema);







  -- shoppingcart



  EXECUTE format('CREATE TABLE %I.shoppingcart (car_id integer NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, stu_id bigint NOT NULL, transtype varchar(10) NOT NULL, transdate date DEFAULT CURRENT_DATE NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, carinitiated char(1) DEFAULT ''N'' NOT NULL, createdby varchar(50) NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  EXECUTE format('CREATE UNIQUE INDEX unique_active_cart_per_student ON %I.shoppingcart (stu_id) WHERE activestatus = 1', v_schema);







  -- shoppingcartdetails



  EXECUTE format('CREATE TABLE %I.shoppingcartdetails (cd_id integer NOT NULL PRIMARY KEY, car_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, dem_id bigint NOT NULL, transdetail_id integer, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);







  -- notice



  EXECUTE format('CREATE TABLE %I.notice (notice_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, noticetitle text NOT NULL, noticedesc text, noticepriority varchar(20) DEFAULT ''Normal'', noticecategory varchar(50) DEFAULT ''General'', noticetarget text, createdby varchar(50), createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1, noticefromdate date, noticetodate date)', v_schema);



  EXECUTE format('CREATE INDEX idx_notice_ins_id ON %I.notice (ins_id)', v_schema);







  -- notification



  EXECUTE format('CREATE TABLE %I.notification (noti_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, stu_id integer, notice_id bigint, notititle text, notibody text, notitype varchar(50), isread integer DEFAULT 0, createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1)', v_schema);



  EXECUTE format('CREATE INDEX idx_notification_notice_id ON %I.notification(notice_id)', v_schema);



  EXECUTE format('CREATE INDEX idx_notification_ins_id ON %I.notification (ins_id)', v_schema);



  EXECUTE format('CREATE INDEX idx_notification_stu_id ON %I.notification (stu_id)', v_schema);







  -- userlogin



  EXECUTE format('CREATE TABLE %I.userlogin (ul_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), uluser varchar(50), ulusetype smallint, ultime timestamp, ulattempt smallint DEFAULT 0, ulip varchar(40), ullocation varchar(50), ulsuccess char(1) DEFAULT ''N'' NOT NULL, ulsesid numeric, ulsesstart timestamp DEFAULT now() NOT NULL, ulsesend timestamp, ulsestime timestamp)', v_schema);











  -- student_import



  EXECUTE format('CREATE TABLE %I.student_import (imp_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), stuadmno varchar(25) NOT NULL, stuname varchar(50) NOT NULL, stugender char(1), studob date, stuadmdate date, stuclass varchar(20) NOT NULL, courname varchar(20), stumobile varchar(30), stuemail varchar(254), concession varchar(50), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stubloodgrp varchar(20), fathername varchar(50), fathermobile varchar(30), fatheroccupation varchar(50), mothername varchar(50), mothermobile varchar(30), motheroccupation varchar(50), guardianname varchar(50), guardianmobile varchar(30), guardianoccupation varchar(50), payincharge varchar(50), payinchargemob varchar(30), admname varchar(50), quoname varchar(50), batch varchar(9), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), paremail varchar(254), cla_id smallint, cour_id integer, admit_cour_id smallint, medium varchar(30), adm_id smallint, quo_id smallint, status varchar(10) DEFAULT ''PENDING'', error_msg text, created_at timestamp DEFAULT now())', v_schema);







  -- FOREIGN KEYS



  EXECUTE format('ALTER TABLE %I.paymentdetails ADD CONSTRAINT fk_paymentdetails_payment FOREIGN KEY (pay_id) REFERENCES %I.payment(pay_id)', v_schema, v_schema);



  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_car_id_fkey FOREIGN KEY (car_id) REFERENCES %I.shoppingcart(car_id)', v_schema, v_schema);



  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_dem_id_fkey FOREIGN KEY (dem_id) REFERENCES %I.feedemand(dem_id)', v_schema, v_schema);







  -- ============================================



  -- TRIGGER FUNCTIONS (per schema)



  -- ============================================







  -- Auto-increment triggers for all tables



  EXECUTE format('CREATE FUNCTION %I.set_yr_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.yr_id IS NULL OR NEW.yr_id = 0 THEN NEW.yr_id := COALESCE((SELECT MAX(yr_id) FROM %I.year), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_year_yr_id BEFORE INSERT ON %I.year FOR EACH ROW EXECUTE FUNCTION %I.set_yr_id()', v_schema, v_schema);







  -- students: sequence-backed id, no hardcoded storage URL (photos resolved client-side)



  EXECUTE format('CREATE SEQUENCE %I.students_stu_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_stu_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stu_id IS NULL OR NEW.stu_id = 0 THEN NEW.stu_id := nextval(''%I.students_stu_id_seq''); END IF; IF (NEW.cour_id IS NULL OR NEW.cour_id = 0) AND NEW.courname IS NOT NULL AND TRIM(NEW.courname) != '''' THEN SELECT c.cour_id INTO NEW.cour_id FROM %I.course c WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM(NEW.courname)) AND c.ins_id = NEW.ins_id LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_students_before_insert BEFORE INSERT ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.set_stu_id()', v_schema, v_schema);







  -- parents: sequence-backed id



  EXECUTE format('CREATE SEQUENCE %I.parents_par_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_par_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.par_id IS NULL OR NEW.par_id = 0 THEN NEW.par_id := nextval(''%I.parents_par_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_parents_before_insert BEFORE INSERT ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.set_par_id()', v_schema, v_schema);







  -- parentdetail: sequence-backed id



  EXECUTE format('CREATE SEQUENCE %I.parentdetail_pd_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_pd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pd_id IS NULL OR NEW.pd_id = 0 THEN NEW.pd_id := nextval(''%I.parentdetail_pd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_parentdetail_auto_id BEFORE INSERT ON %I.parentdetail FOR EACH ROW EXECUTE FUNCTION %I.set_pd_id()', v_schema, v_schema);







  -- feedemand uses a real sequence (bulk import path — must be O(1) per row)



  EXECUTE format('CREATE SEQUENCE %I.feedemand_dem_id_seq', v_schema);



  EXECUTE format($f$CREATE FUNCTION %I.set_dem_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.dem_id IS NULL OR NEW.dem_id = 0 THEN NEW.dem_id := nextval('%I.feedemand_dem_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.dem_id::TEXT, 5, '0'); END IF; END IF; IF NEW.demseqtype IS NULL OR TRIM(NEW.demseqtype) = '' THEN NEW.demseqtype := 'DEMAND'; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.demfeetype IS NOT NULL THEN SELECT ft.fee_id INTO NEW.fee_id FROM %I.feetype ft WHERE ft.feedesc = NEW.demfeetype AND ft.activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_feedemand_before_insert BEFORE INSERT ON %I.feedemand FOR EACH ROW EXECUTE FUNCTION %I.set_dem_id()', v_schema, v_schema);







  -- tempfeedemand uses a real sequence (bulk import path — must be O(1) per row)



  EXECUTE format('CREATE SEQUENCE %I.tempfeedemand_temp_id_seq', v_schema);



  EXECUTE format($f$CREATE FUNCTION %I.set_temp_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.temp_id IS NULL THEN NEW.temp_id := nextval('%I.tempfeedemand_temp_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.temp_id::TEXT, 5, '0'); END IF; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_temp_id BEFORE INSERT ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_temp_id()', v_schema, v_schema);







  -- Master-table auto-increment sequences. The NULL/0 guard lets callers



  -- supply an explicit id (needed when importing master data from a legacy



  -- system); a plain INSERT without the column gets nextval().



  EXECUTE format('CREATE SEQUENCE %I.feegroup_fg_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_fg_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fg_id IS NULL OR NEW.fg_id = 0 THEN NEW.fg_id := nextval(''%I.feegroup_fg_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_feegroup_fg_id BEFORE INSERT ON %I.feegroup FOR EACH ROW EXECUTE FUNCTION %I.set_fg_id()', v_schema, v_schema);







  EXECUTE format('CREATE SEQUENCE %I.feetype_fee_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_fee_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fee_id IS NULL OR NEW.fee_id = 0 THEN NEW.fee_id := nextval(''%I.feetype_fee_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_feetype_fee_id BEFORE INSERT ON %I.feetype FOR EACH ROW EXECUTE FUNCTION %I.set_fee_id()', v_schema, v_schema);







  EXECUTE format('CREATE SEQUENCE %I.concessioncategory_con_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_con_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.con_id IS NULL OR NEW.con_id = 0 THEN NEW.con_id := nextval(''%I.concessioncategory_con_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_concession_con_id BEFORE INSERT ON %I.concessioncategory FOR EACH ROW EXECUTE FUNCTION %I.set_con_id()', v_schema, v_schema);







  EXECUTE format('CREATE SEQUENCE %I.course_cour_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_cour_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cour_id IS NULL OR NEW.cour_id = 0 THEN NEW.cour_id := nextval(''%I.course_cour_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_course_cour_id BEFORE INSERT ON %I.course FOR EACH ROW EXECUTE FUNCTION %I.set_cour_id()', v_schema, v_schema);







  EXECUTE format('CREATE SEQUENCE %I.class_cla_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_cla_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cla_id IS NULL OR NEW.cla_id = 0 THEN NEW.cla_id := nextval(''%I.class_cla_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_class_cla_id BEFORE INSERT ON %I.class FOR EACH ROW EXECUTE FUNCTION %I.set_cla_id()', v_schema, v_schema);







  EXECUTE format('CREATE SEQUENCE %I.classfeedemand_cf_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_cf_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cf_id IS NULL THEN NEW.cf_id := nextval(''%I.classfeedemand_cf_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_classfeedemand_cf_id BEFORE INSERT ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_cf_id()', v_schema, v_schema);



  -- Resolve cla_id / sem_id / fee_id from the cfclass / cfterm / cffeetype names



  -- on insert/update (schema-qualified, so it works from the session-gated RPCs).



  EXECUTE format('CREATE OR REPLACE FUNCTION %I.set_classfee_ids() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF (NEW.cla_id IS NULL OR NEW.cla_id = 0) AND NEW.cfclass IS NOT NULL THEN SELECT cla_id INTO NEW.cla_id FROM %I.class WHERE claname = NEW.cfclass AND activestatus = 1 LIMIT 1; END IF; IF (NEW.sem_id IS NULL OR NEW.sem_id = 0) AND NEW.cfterm IS NOT NULL THEN SELECT sem_id INTO NEW.sem_id FROM %I.semester WHERE semname = NEW.cfterm AND activestatus = 1 LIMIT 1; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.cffeetype IS NOT NULL THEN SELECT fee_id INTO NEW.fee_id FROM %I.feetype WHERE feedesc = NEW.cffeetype AND activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_classfeedemand_ids BEFORE INSERT OR UPDATE ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_classfee_ids()', v_schema, v_schema);







  EXECUTE format('CREATE SEQUENCE %I.payment_pay_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %1$I.set_pay_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_next bigint; BEGIN IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN PERFORM pg_advisory_xact_lock(hashtext(%1$L)::bigint); SELECT COALESCE(MAX(pay_id),0) + 1 INTO v_next FROM %1$I.payment; NEW.pay_id := v_next; END IF; RETURN NEW; END; $t$', v_schema);



  EXECUTE format('CREATE TRIGGER trg_payment_auto_increment BEFORE INSERT ON %I.payment FOR EACH ROW EXECUTE FUNCTION %I.set_pay_id()', v_schema, v_schema);







  EXECUTE format('CREATE SEQUENCE %I.paymentdetails_pyd_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_pyd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pyd_id IS NULL OR NEW.pyd_id = 0 THEN NEW.pyd_id := nextval(''%I.paymentdetails_pyd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_paymentdetails_auto_increment BEFORE INSERT ON %I.paymentdetails FOR EACH ROW EXECUTE FUNCTION %I.set_pyd_id()', v_schema, v_schema);







  EXECUTE format('CREATE FUNCTION %I.set_car_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.car_id := COALESCE((SELECT MAX(car_id) FROM %I.shoppingcart), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_generate_car_id BEFORE INSERT ON %I.shoppingcart FOR EACH ROW EXECUTE FUNCTION %I.set_car_id()', v_schema, v_schema);







  EXECUTE format('CREATE FUNCTION %I.set_cd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.cd_id := COALESCE((SELECT MAX(cd_id) FROM %I.shoppingcartdetails), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_generate_cd_id BEFORE INSERT ON %I.shoppingcartdetails FOR EACH ROW EXECUTE FUNCTION %I.set_cd_id()', v_schema, v_schema);







  EXECUTE format('CREATE FUNCTION %I.set_notice_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.notice_id IS NULL OR NEW.notice_id = 0 THEN NEW.notice_id := COALESCE((SELECT MAX(notice_id) FROM %I.notice), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_notice_id BEFORE INSERT ON %I.notice FOR EACH ROW EXECUTE FUNCTION %I.set_notice_id()', v_schema, v_schema);







  EXECUTE format('CREATE FUNCTION %I.set_noti_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.noti_id IS NULL OR NEW.noti_id = 0 THEN NEW.noti_id := COALESCE((SELECT MAX(noti_id) FROM %I.notification), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_noti_id BEFORE INSERT ON %I.notification FOR EACH ROW EXECUTE FUNCTION %I.set_noti_id()', v_schema, v_schema);







  -- Password hash triggers



  EXECUTE format('CREATE FUNCTION %I.hash_student_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stupassword IS NOT NULL AND NEW.stupassword != '''' AND LEFT(NEW.stupassword, 4) != ''$2a$'' AND LEFT(NEW.stupassword, 4) != ''$2b$'' THEN NEW.stupassword := crypt(NEW.stupassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);



  EXECUTE format('CREATE TRIGGER hash_student_password_trigger BEFORE INSERT OR UPDATE OF stupassword ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.hash_student_password()', v_schema, v_schema);







  EXECUTE format('CREATE FUNCTION %I.hash_parent_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.parpassword IS NOT NULL AND NEW.parpassword != '''' AND LEFT(NEW.parpassword, 4) != ''$2a$'' AND LEFT(NEW.parpassword, 4) != ''$2b$'' THEN NEW.parpassword := crypt(NEW.parpassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);



  EXECUTE format('CREATE TRIGGER hash_parent_password_trigger BEFORE INSERT OR UPDATE OF parpassword ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.hash_parent_password()', v_schema, v_schema);







  -- Transfer Certificate entries (Admission → Transfer Certificate). One row per



  -- TC issued; save_tc_entry writes here and stamps the student's + admission's



  -- activestatus with the leaving code, so non-active students drop out of the



  -- active screens (which filter activestatus=1).



  EXECUTE format('CREATE TABLE %I.tc_entry (tc_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), stu_id bigint, stuadmno varchar(25) NOT NULL, stuname varchar(50), stuclass varchar(20), cla_id smallint, birthdate date, joindate date, status smallint NOT NULL DEFAULT 1 CHECK (status = ANY(ARRAY[1,2,3,4,5,9])), statustype varchar(20), tcno varchar(30), tcdate date, effectfrom date, docno varchar(30), docdate date, remarks varchar(200), createdby varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  EXECUTE format('CREATE SEQUENCE %I.tc_entry_tc_id_seq', v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_tc_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.tc_id IS NULL OR NEW.tc_id = 0 THEN NEW.tc_id := nextval(''%I.tc_entry_tc_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);



  EXECUTE format('CREATE TRIGGER trg_tc_entry_tc_id BEFORE INSERT ON %I.tc_entry FOR EACH ROW EXECUTE FUNCTION %I.set_tc_id()', v_schema, v_schema);



  EXECUTE format('ALTER TABLE %I.tc_entry ENABLE ROW LEVEL SECURITY', v_schema);



  EXECUTE format('CREATE POLICY "Allow all" ON %I.tc_entry USING (true) WITH CHECK (true)', v_schema);







  -- (rollno_change lives in public, alongside public.admission — see above.)







  -- (fn_approve_tempfeedemand + trigger are defined right after the tempfeedemand



  -- table above; they carry the `collectible` flag from temp into feedemand.)







  -- RLS



  EXECUTE format('ALTER TABLE %I.notice ENABLE ROW LEVEL SECURITY', v_schema);



  EXECUTE format('ALTER TABLE %I.notification ENABLE ROW LEVEL SECURITY', v_schema);



  EXECUTE format('ALTER TABLE %I.tempfeedemand ENABLE ROW LEVEL SECURITY', v_schema);



  -- student_import was missing its ENABLE (policy created below), which tripped



  -- the Supabase "Policy Exists RLS Disabled" advisor for every new schema.



  EXECUTE format('ALTER TABLE %I.student_import ENABLE ROW LEVEL SECURITY', v_schema);



  EXECUTE format('CREATE POLICY "Allow all" ON %I.notice USING (true) WITH CHECK (true)', v_schema);



  EXECUTE format('CREATE POLICY "Allow all" ON %I.notification USING (true) WITH CHECK (true)', v_schema);



  EXECUTE format('CREATE POLICY "Allow all" ON %I.tempfeedemand USING (true) WITH CHECK (true)', v_schema);



  EXECUTE format('CREATE POLICY "Allow all" ON %I.student_import USING (true) WITH CHECK (true)', v_schema);







  -- PERMISSIONS



  EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated', v_schema);



  EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO anon, authenticated', v_schema);



  EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO anon, authenticated', v_schema);



  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO anon, authenticated', v_schema);



  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO anon, authenticated', v_schema);







  -- Auto-create year records if parameters provided



  IF p_ins_id IS NOT NULL AND p_year_label IS NOT NULL THEN



    -- Insert into public.institutionyear, stamping iyrschema so the row



    -- carries the per-year schema name (e.g. 'kcet20262027') without the



    -- app having to re-derive it from inshortname + yrlabel.



    INSERT INTO public.institutionyear (ins_id, inscode, yrlabel, iyrstadate, iyrenddate, iyrschema, activestatus)



    VALUES (p_ins_id, COALESCE(v_inscode, ''), p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year'), v_schema, 1)



    ON CONFLICT (ins_id, yrlabel) DO UPDATE SET iyrschema = EXCLUDED.iyrschema;







    -- Insert into schema year table



    EXECUTE format('INSERT INTO %I.year (ins_id, yrlabel, yrstadate, yrenddate, activestatus) VALUES ($1, $2, $3, $4, 1)', v_schema)



    USING p_ins_id, p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year');



  END IF;







  -- Expose schema to PostgREST (may fail on free tier - handled by app login)



  BEGIN



    PERFORM public.expose_schema(v_schema);



  EXCEPTION WHEN OTHERS THEN



    RAISE NOTICE 'expose_schema skipped: %', SQLERRM;



  END;







  -- Security (Option B): the money tables are written ONLY through session-gated



  -- SECURITY DEFINER RPCs (they run as owner), so a new schema is born with anon



  -- direct-write REVOKED on them. SELECT is left intact (reads unchanged). This



  -- mirrors phase3a_revoke_money_writes.sql for existing schemas.



  EXECUTE format(



    'REVOKE INSERT, UPDATE, DELETE ON %I.payment, %I.paymentdetails, %I.feedemand, '



    '%I.fee_refund, %I.fee_refunddetails, %I.concession, %I.concessiondetail, %I.students, %I.parents, %I.parentdetail, '



    '%I.advance_collection, %I.advance_detail, %I.advadjustment FROM anon',



    v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema,



    v_schema, v_schema, v_schema);







  -- Read lockdown: enable RLS + per-tenant SELECT policy on sensitive tables so a



  -- NEW institution is born read-locked (anon can't SELECT another tenant's PII/



  -- money). Wrapped so a policy hiccup never blocks institution creation.



  BEGIN



    PERFORM public.read_lock_schema(v_schema);



  EXCEPTION WHEN OTHERS THEN



    RAISE NOTICE 'read_lock_schema skipped for %: %', v_schema, SQLERRM;



  END;







END; $function$;


-- ############################################################################
-- 5 -- VERIFY  (read-only)
-- ############################################################################
-- Should be EMPTY: no demand's flag contradicts its own balance.
SELECT dem_id, stuadmno, demfeetype, feeamount, paidamount, balancedue, paidstatus
  FROM kcet20262027.feedemand
 WHERE activestatus = 1
   AND ((paidstatus = 'P' AND COALESCE(balancedue,0) > 0)
     OR (paidstatus = 'U' AND COALESCE(balancedue,0) <= 0 AND COALESCE(paidamount,0) > 0))
 ORDER BY dem_id;

SELECT CASE WHEN prosrc LIKE '%paidstatus = CASE WHEN v_net%' THEN 'yes'
            ELSE 'NO -- not applied' END AS new_schemas_fixed
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema';


-- ############################################################################
-- ############################################################################
--  PART 4 of 5 -- LIVE_FIX_CLASS_NAME_MISMATCH.sql
-- ############################################################################
-- ############################################################################

-- ############################################################################
--
--   EduCore360 -- FIX CLASS NAMES ON LIVE, 23-09-2026
--
--   Six final-year classes in the master are named after the COURSE
--   ("B.E-CSE-IV") while every other year in the same ladder is named the way
--   students actually hold it ("B.E CSE -I", "-II", "-III"). The difference is
--   a hyphen where the rest of the ladder has a space, so it survives any
--   comparison that only strips whitespace.
--
--   Run the whole file in the SQL editor on the LIVE project. Run
--   CHECK_BEFORE_ADVANCE_LOAD.sql first if you have not already -- it says
--   LIVE or TEST from the database itself, which the project name will not.
--
-- ----------------------------------------------------------------------------
-- WHY IT MATTERS
-- ----------------------------------------------------------------------------
-- Students sitting in a class the master does not contain:
--
--   * get no classtype, so they are missing from every Promotional / Terminal
--     count and from anything keyed on the class master
--   * end the promotion ladder on a name nobody is in: "B.E CSE -III" succeeds
--     to "B.E-CSE-IV", which holds 0 students
--
-- On the TEST restore that was 228 active students, and it made the final-year
-- count read 63 instead of roughly 290.
--
-- ----------------------------------------------------------------------------
-- WHAT IT CHANGES
-- ----------------------------------------------------------------------------
-- The claname of up to six rows in <schema>.class. Nothing else -- no student,
-- demand, receipt or payment row is written. On the TEST restore:
--
--   cla_id  from              to
--   ------  ----------------  ------------------
--      54   B.E-ECE-IV        B.E ECE -IV          (78 students)
--      51   B.E-CSE-IV        B.E CSE -IV          (62)
--       1   B TECH- IT-IV     B.TECH ( IT) -IV     (61)
--     229   B.E-CIVIL-IV      B.E CIVIL-IV         (20)
--     120   M.E-EST-II        M.E EST- II          (4)
--     344   B ED-II           B.ED - II            (3)
--
-- The MASTER row is the right thing to move, not the students: the students'
-- name is the one already printed on their demands, receipts and ledgers, and
-- all six master rows hold ZERO students, so renaming them strands nobody.
--
-- succeedingclass is by cla_id, so the ladder follows the rename automatically
-- and needs no repair.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RUN, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- * Each rename is matched on the OLD name, so a second run finds nothing.
-- * A rename is SKIPPED if the new name already exists -- that would merge two
--   classes, and there would be no way back.
-- * All or nothing: the editor runs this as one transaction.
-- * This file does NOT read class.classtype, so it works whether or not
--   LIVE_RUN_20260921.sql (CLASS_TYPE.sql) has been run yet. Order between the
--   two does not matter.
--
-- ----------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ----------------------------------------------------------------------------
-- One result, in three parts, because the editor shows only the last statement:
--
--   1 BEFORE   the classes students are in that the master did not contain
--   2 RENAME   what each of the six renames did: "renamed", "not found"
--              (already correct on live) or "SKIPPED - target exists"
--   3 AFTER    must be a single row reading "none - every class matches".
--              Anything else is a class still unmatched, and worth telling me
--              about before you move on.
--
-- Checked on the TEST project (a restore of live) first.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 1 -- capture the BEFORE picture
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _cm_before ON COMMIT DROP AS
SELECT s.courname AS course, s.stuclass AS detail, COUNT(*)::bigint AS students
  FROM kcet20262027.students s
 WHERE s.activestatus = 1 AND COALESCE(s.preadmission, 0) = 0
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                    WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                      AND c.ins_id = s.ins_id AND c.activestatus = 1)
 GROUP BY 1, 2;


-- ----------------------------------------------------------------------------
-- 2 -- the rename
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _cm_log (detail text, students bigint) ON COMMIT DROP;

DO $ren$
DECLARE
  n int;
  i int;
  pairs CONSTANT text[][] := ARRAY[
    ARRAY['B.E-ECE-IV',    'B.E ECE -IV'],
    ARRAY['B.E-CSE-IV',    'B.E CSE -IV'],
    ARRAY['B TECH- IT-IV', 'B.TECH ( IT) -IV'],
    ARRAY['B.E-CIVIL-IV',  'B.E CIVIL-IV'],
    ARRAY['M.E-EST-II',    'M.E EST- II'],
    ARRAY['B ED-II',       'B.ED - II']
  ];
BEGIN
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    -- Never rename onto a name that already exists: that would merge two
    -- classes, and there would be no way back.
    IF EXISTS (SELECT 1 FROM kcet20262027.class
                WHERE UPPER(TRIM(claname)) = UPPER(TRIM(pairs[i][2]))
                  AND activestatus = 1) THEN
      INSERT INTO _cm_log VALUES
        (format('SKIPPED  %s -> %s  (target already exists)', pairs[i][1], pairs[i][2]), 0);
      CONTINUE;
    END IF;

    UPDATE kcet20262027.class
       SET claname = pairs[i][2]
     WHERE UPPER(TRIM(claname)) = UPPER(TRIM(pairs[i][1]))
       AND activestatus = 1;
    GET DIAGNOSTICS n = ROW_COUNT;

    INSERT INTO _cm_log VALUES (
      CASE WHEN n > 0
           THEN format('renamed  %s -> %s', pairs[i][1], pairs[i][2])
           ELSE format('not found  %s  (nothing to rename)', pairs[i][1])
      END, n);
  END LOOP;
END $ren$;


-- ----------------------------------------------------------------------------
-- 3 -- the whole story, in one result
-- ----------------------------------------------------------------------------
SELECT '1 BEFORE' AS stage,
       course || ' -- ' || detail AS detail,
       students
  FROM _cm_before

UNION ALL
SELECT '2 RENAME', detail, students FROM _cm_log

UNION ALL
SELECT '3 AFTER',
       COALESCE(x.course || ' -- ' || x.detail, 'none - every class matches'),
       COALESCE(x.students, 0)
  FROM (SELECT s.courname AS course, s.stuclass AS detail, COUNT(*)::bigint AS students
          FROM kcet20262027.students s
         WHERE s.activestatus = 1 AND COALESCE(s.preadmission, 0) = 0
           AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                            WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                              AND c.ins_id = s.ins_id AND c.activestatus = 1)
         GROUP BY 1, 2) x
 RIGHT JOIN (SELECT 1) one ON TRUE

 ORDER BY stage, students DESC, detail;


-- ############################################################################
-- ############################################################################
--  PART 5 of 5 -- LIVE_RUN_20260924.sql
-- ############################################################################
-- ############################################################################

-- ############################################################################
--
--   EduCore360 -- LIVE UPDATE, 24-09-2026
--
--   Run the whole file, top to bottom, in the SQL editor on the LIVE project.
--   It refuses to run on TEST, so a mis-click costs nothing.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS RELEASE NEEDS FROM THE DATABASE
-- ----------------------------------------------------------------------------
-- Almost nothing. The session's work -- the class-ordering rule, the bank
-- delete guard, the Daily Collection print, the export buttons, the three new
-- reports, the per-tile dashboard access -- is all in the desktop build and
-- needs no schema change:
--
--   * dashboard tile grants reuse public.rolemenuaccess, storing keys like
--     'dash:collected' in the column the menu labels already use. The prefix
--     is what keeps a tile named "Quick Actions" from being read as a menu of
--     the same name.
--   * the new reports only READ -- public.admission and <schema>.tc_entry.
--
-- ONE thing does need doing here, and it is this file:
--
--   TWO NEW MENUS -- 'Admission Register' and 'TC Report'. A role that has
--   already been configured in Roles & Access has no row for a menu that did
--   not exist when it was configured, so on the new build those roles would
--   simply not see the reports, with nothing to say why. This grants both to
--   every role that is ALREADY configured, exactly as
--   rolemenuaccess_dashboard.sql did when Dashboard became assignable.
--
--   Roles with NO rows are left alone: no rows still means "never configured",
--   and the app falls back to its built-in defaults for them.
--
-- ----------------------------------------------------------------------------
-- BEFORE YOU DEPLOY THE BUILD -- READ THIS
-- ----------------------------------------------------------------------------
-- This release makes LIVE_RUN_20260921.sql (CLASS_TYPE.sql) REQUIRED, where it
-- was optional before. The dashboard's Total Students card and the Class screen
-- both SELECT class.classtype, which live does not have yet. Without it those
-- two break.
--
-- The class DROPDOWNS are safe either way -- they fall back to reading a TC
-- batch from its name -- but the dashboard card does not.
--
-- So the order for this release is:
--
--   1. LIVE_RUN_20260919.sql            still unrun
--   2. LIVE_RUN_20260921.sql            still unrun  <- now required
--   3. FIX_PAIDSTATUS_ON_APPROVAL.sql   still unrun
--   4. LIVE_FIX_CLASS_NAME_MISMATCH.sql still unrun
--   5. THIS FILE
--   6. NOTIFY pgrst, 'reload schema';
--
-- LIVE_ADVANCE_LOAD_20260923.sql (the 149 student advances) is independent of
-- the build -- run it whenever you intend that money to become adjustable.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RUN, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- It only INSERTs grant rows, and only for roles that already have some. No
-- existing grant is changed or removed, and ON CONFLICT DO NOTHING makes a
-- second run a no-op.
--
-- To undo:
--   DELETE FROM public.rolemenuaccess
--    WHERE createdby = 'migration 20260924'
--      AND menulabel IN ('Admission Register', 'TC Report');
--
-- ----------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ----------------------------------------------------------------------------
-- One row per configured role, with has_admission_register and has_tc_report
-- both true. A role missing from the list has never been configured and will
-- see the reports through the built-in defaults.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 1 -- grant the two new report menus to every already-configured role
-- ----------------------------------------------------------------------------
INSERT INTO public.rolemenuaccess (ins_id, ur_id, menulabel, createdby, activestatus)
SELECT DISTINCT r.ins_id, r.ur_id, m.label, 'migration 20260924', 1
  FROM public.rolemenuaccess r
 CROSS JOIN (VALUES ('Admission Register'), ('TC Report')) AS m(label)
 WHERE r.activestatus = 1
   AND NOT EXISTS (
         SELECT 1 FROM public.rolemenuaccess d
          WHERE d.ins_id = r.ins_id
            AND d.ur_id  = r.ur_id
            AND d.menulabel = m.label)
ON CONFLICT (ins_id, ur_id, menulabel) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 2 -- what each configured role can now see
-- ----------------------------------------------------------------------------
SELECT a.ins_id,
       a.ur_id,
       COALESCE(u.urname, '(role not in custuserroles)')      AS role,
       count(*) FILTER (WHERE a.menulabel NOT LIKE 'dash:%')  AS menus_allowed,
       count(*) FILTER (WHERE a.menulabel LIKE 'dash:%')      AS dashboard_tiles,
       bool_or(a.menulabel = 'Admission Register')            AS has_admission_register,
       bool_or(a.menulabel = 'TC Report')                     AS has_tc_report
  FROM public.rolemenuaccess a
  LEFT JOIN public.custuserroles u
         ON u.ur_id = a.ur_id AND u.ins_id = a.ins_id
 WHERE a.activestatus = 1
 GROUP BY a.ins_id, a.ur_id, u.urname
 ORDER BY a.ins_id, a.ur_id;

-- ############################################################################
-- VERIFY -- the only result this file returns
--
-- Five rows, all reading OK. Anything else and nothing was kept: the whole
-- file is one transaction.
-- ############################################################################
SELECT * FROM (

  SELECT 1 AS ord, 'class.classtype exists' AS part,
         CASE WHEN count(*) > 0 THEN 'OK' ELSE 'MISSING' END AS status,
         count(*)::text || ' year schema(s) carry the column' AS detail
    FROM information_schema.columns
   WHERE table_name = 'class' AND column_name = 'classtype'

  UNION ALL

  SELECT 2, 'every class is typed',
         CASE WHEN count(*) = 0 THEN 'OK' ELSE 'NOT TYPED' END,
         count(*)::text || ' active class(es) still have no classtype'
    FROM kcet20262027.class
   WHERE activestatus = 1 AND classtype IS NULL

  UNION ALL

  SELECT 3, 'every student''s class is in the master',
         CASE WHEN count(*) = 0 THEN 'OK' ELSE 'UNMATCHED' END,
         count(*)::text || ' active student(s) sit in a class the master lacks'
    FROM kcet20262027.students s
   WHERE s.activestatus = 1 AND COALESCE(s.preadmission, 0) = 0
     AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                      WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                        AND c.ins_id = s.ins_id AND c.activestatus = 1)

  UNION ALL

  -- The function lives in the YEAR SCHEMA, not public -- there is one copy per
  -- schema, and every one of them has to carry the clause.
  SELECT 4, 'approval sets paidstatus',
         CASE WHEN total > 0 AND fixed = total THEN 'OK' ELSE 'MISSING' END,
         fixed::text || ' of ' || total::text
           || ' fn_approve_tempfeedemand copy/copies set paidstatus'
    FROM (SELECT count(*) AS total,
                 count(*) FILTER (
                   WHERE pg_get_functiondef(p.oid) LIKE '%%paidstatus%%') AS fixed
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE p.proname = 'fn_approve_tempfeedemand'
             AND n.nspname NOT IN ('pg_catalog', 'information_schema')) f

  UNION ALL

  SELECT 5, 'new report menus granted',
         CASE WHEN count(*) FILTER (WHERE NOT has_both) = 0 THEN 'OK' ELSE 'MISSING' END,
         count(*)::text || ' configured role(s), '
           || count(*) FILTER (WHERE has_both)::text || ' with both new reports'
    FROM (SELECT a.ins_id, a.ur_id,
                 bool_or(a.menulabel = 'Admission Register')
                   AND bool_or(a.menulabel = 'TC Report') AS has_both
            FROM public.rolemenuaccess a
           WHERE a.activestatus = 1
           GROUP BY a.ins_id, a.ur_id) r

) z ORDER BY ord;
