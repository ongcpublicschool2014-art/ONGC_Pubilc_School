-- =====================================================================
-- Let the Transactions screen SEE unfinished misc/advance collections.
--
-- public.pending_collection is REVOKEd from anon/authenticated on purpose: a
-- forged row there would read as "money the college received" to whoever works
-- the list. But the revoke takes SELECT with it, so the admin app -- which
-- reads with the anon key -- could not show them at all.
--
-- WRITING stays locked. Only reading is opened, and only through this
-- function. It takes ins_id rather than a session token: the first version
-- demanded a session and silently returned nothing when one could not be
-- resolved, which is indistinguishable from "there is nothing to show" -- a
-- bad property for a screen whose job is to reveal money that may be at risk.
-- The same anon key already reads payment rows with names and amounts, so this
-- exposes nothing new.
--
-- Read-only. Writes still go through record/claim/settle.
-- =====================================================================
DROP FUNCTION IF EXISTS public.list_pending_collections(text, date, date);

CREATE OR REPLACE FUNCTION public.list_pending_collections(
  p_ins_id integer, p_from date DEFAULT NULL, p_to date DEFAULT NULL
) RETURNS TABLE(order_id text, kind char, amount numeric, header jsonb,
                status char, created_at timestamptz, receipt_no text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions AS $$
  SELECT c.order_id, c.kind, c.amount, c.header, c.status,
         c.created_at, c.receipt_no
    FROM public.pending_collection c
   WHERE c.ins_id = p_ins_id
     AND (p_from IS NULL OR c.created_at >= p_from::timestamptz)
     AND (p_to   IS NULL OR c.created_at <  (p_to + 1)::timestamptz)
   ORDER BY c.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.list_pending_collections(integer, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pending_collections(integer, date, date)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Must return your 7 rows for today.
SELECT count(*) AS rows_the_app_will_see
  FROM public.list_pending_collections(1, CURRENT_DATE, CURRENT_DATE);
