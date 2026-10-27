-- ============================================================================
-- Let the office SEE the refusals. Read-only.
-- ============================================================================
-- WHAT IS WRONG TODAY. public.webhook_refusal is where the system records
-- money Paytm confirmed that it could not turn into a receipt. It works: on
-- 12-10-2026 a Rs 2,700 capture at 15:38:04 was flagged at 15:38:06.913 --
-- under three seconds.
--
-- Nobody ever sees it. The table is service_role only, and no screen in any
-- app reads it. student_fee_collection_screen.dart WRITES refusals and
-- nothing anywhere reads them back. So that Rs 2,700 sat unnoticed for
-- nineteen hours and took a morning of log archaeology to attribute to
-- SANDHIYAH T -- a question the database had already asked, out loud, before
-- the parent had put her phone down.
--
-- Detection without delivery is not detection.
--
-- WHAT THIS DOES. One STABLE SECURITY DEFINER reader so the desktop app can
-- list them. Same shape as open_pending_collections: takes an institution,
-- granted to anon and authenticated.
--
-- WHAT IT DELIBERATELY DOES NOT DO. It cannot write. Resolving a refusal
-- stays with resolve_webhook_refusal (service_role) and with the recovery
-- scripts, which close the row as part of raising the receipt. A refusal is
-- a claim that the college holds money it has not receipted; a client that
-- could clear that claim could hide it.
--
-- ins_id IS NULL rows are INCLUDED. The commonest refusal -- "no payment row,
-- the attempt is gone" -- has no payment row to read an institution from, so
-- ins_id is null. Those are precisely the ones that need a human, and
-- filtering them out would hide the entire class of problem this exists for.
-- Harmless while one institution is live; revisit when a second one is.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.list_webhook_refusals(
  p_ins_id integer,
  p_include_resolved boolean DEFAULT false,
  p_limit integer DEFAULT 200
)
RETURNS TABLE(
  order_id        text,
  ins_id          integer,
  pay_id          bigint,
  amount          numeric,
  reason          text,
  times_seen      integer,
  first_seen      timestamptz,
  last_seen       timestamptz,
  resolved_at     timestamptz,
  resolved_by     text,
  resolution_note text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT r.order_id, r.ins_id, r.pay_id, r.amount, r.reason,
         r.times_seen, r.first_seen, r.last_seen,
         r.resolved_at, r.resolved_by, r.resolution_note
    FROM public.webhook_refusal r
   WHERE (r.ins_id = p_ins_id OR r.ins_id IS NULL)
     AND (p_include_resolved OR r.resolved_at IS NULL)
   ORDER BY (r.resolved_at IS NULL) DESC, r.last_seen DESC
   LIMIT GREATEST(COALESCE(p_limit, 200), 1);
$$;

GRANT EXECUTE ON FUNCTION public.list_webhook_refusals(integer, boolean, integer)
  TO anon, authenticated;


-- ------------------------------------------------------------- VERIFY ------
-- 1. The reader exists and the table is still closed to clients.
SELECT
  to_regprocedure('public.list_webhook_refusals(integer,boolean,integer)')
    IS NOT NULL                                            AS reader_exists,
  NOT has_table_privilege('anon', 'public.webhook_refusal', 'SELECT')
                                                           AS table_still_closed,
  NOT has_table_privilege('anon', 'public.webhook_refusal', 'UPDATE')
                                                           AS anon_cannot_clear;

-- 2. What the office would see right now. Empty is the good answer.
SELECT order_id, amount, reason, times_seen, first_seen
  FROM public.list_webhook_refusals(1);
