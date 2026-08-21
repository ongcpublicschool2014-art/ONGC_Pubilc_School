-- PERF + BUG: the superadmin dashboard's per-institution figures (Today
-- Collection, Pending Approval) were computed CLIENT-SIDE by querying each
-- tenant's payment/paymentdetails/feedemand tables directly. But the superadmin
-- runs as the anon role, which CANNOT directly SELECT tenant tables (RLS/grants)
-- -> those queries silently returned 0 rows, so Today Collection & Pending
-- Approval always showed 0. (The institution app avoids this by reading through
-- SECURITY DEFINER RPCs; the v1 dashboard card works for the same reason.)
--
-- Fix: this RPC is SECURITY DEFINER (runs with owner privileges, so it CAN read
-- tenant tables) and computes pending_approval + today_collected server-side per
-- institution in one round-trip. today_collected uses the server's CURRENT_DATE.
-- The client reads today_collected + pending_approval from here; total_collected
-- / total_pending still come from get_super_admin_dashboard (admin-card parity).
--
-- Accepts p_yrlabel (selected academic year; NULL = latest active year) to match
-- the client call. Previously the on-file version took no params -> PGRST202.

DROP FUNCTION IF EXISTS public.get_super_admin_dashboard_v2();
DROP FUNCTION IF EXISTS public.get_super_admin_dashboard_v2(text);

CREATE OR REPLACE FUNCTION public.get_super_admin_dashboard_v2(p_yrlabel text DEFAULT NULL)
RETURNS TABLE (
    ins_id           INT,
    insname          TEXT,
    inscode          TEXT,
    inshortname      TEXT,
    inslogo          TEXT,
    activestatus     SMALLINT,
    student_count    INT,
    total_demand     NUMERIC,
    total_collected  NUMERIC,
    total_pending    NUMERIC,
    pending_approval NUMERIC,
    today_collected  NUMERIC
) LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    rec       RECORD;
    schema_n  TEXT;
    short_n   TEXT;
    yr_label  TEXT;
    demand    NUMERIC;
    collected NUMERIC;
    pending   NUMERIC;
    pending_a NUMERIC;
    today_c   NUMERIC;
    stu_cnt   INT;
BEGIN
    FOR rec IN
        SELECT i.ins_id, i.insname, i.inscode, i.inshortname, i.inslogo, i.activestatus
        FROM   public.institution i
        ORDER  BY i.ins_id
    LOOP
        short_n  := lower(rec.inshortname);
        yr_label := NULL;
        IF p_yrlabel IS NOT NULL AND btrim(p_yrlabel) <> '' THEN
            SELECT iy.yrlabel INTO yr_label
            FROM   public.institutionyear iy
            WHERE  iy.ins_id = rec.ins_id AND iy.activestatus = 1 AND iy.yrlabel = p_yrlabel
            LIMIT  1;
        END IF;
        IF yr_label IS NULL THEN
            SELECT iy.yrlabel INTO yr_label
            FROM   public.institutionyear iy
            WHERE  iy.ins_id = rec.ins_id AND iy.activestatus = 1
            ORDER  BY iy.iyr_id DESC
            LIMIT  1;
        END IF;

        IF yr_label IS NULL OR short_n IS NULL THEN
            ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
            inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
            student_count := 0; total_demand := 0; total_collected := 0; total_pending := 0;
            pending_approval := 0; today_collected := 0;
            RETURN NEXT; CONTINUE;
        END IF;
        schema_n := short_n || replace(yr_label, '-', '');

        IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = schema_n) THEN
            ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
            inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
            student_count := 0; total_demand := 0; total_collected := 0; total_pending := 0;
            pending_approval := 0; today_collected := 0;
            RETURN NEXT; CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)), 0)
            FROM   %1$I.payment p
            JOIN   %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
            JOIN   %1$I.feedemand fd ON fd.dem_id = pd.dem_id
            WHERE  p.ins_id = %2$L AND p.activestatus = 1 AND p.paystatus = 'C'
              AND  p.recon_status = 'P' AND fd.activestatus = 1
        $q$, schema_n, rec.ins_id)
        INTO pending_a;

        EXECUTE format($q$
            SELECT
                COALESCE(SUM(feeamount), 0),
                COALESCE(SUM(balancedue), 0) + %3$L::numeric,
                COALESCE(SUM(feeamount), 0) - (COALESCE(SUM(balancedue), 0) + %3$L::numeric)
            FROM %1$I.feedemand WHERE ins_id = %2$L AND activestatus = 1
        $q$, schema_n, rec.ins_id, pending_a)
        INTO demand, pending, collected;

        -- recon_status='R' only: Today Collection counts RECONCILED money (cash
        -- auto-reconciles). Unreconciled payments are Pending Approval, not
        -- collection — matches the institution dashboard's Today Collection.
        EXECUTE format($q$
            SELECT COALESCE(SUM(transtotalamount), 0)
            FROM %1$I.payment
            WHERE ins_id = %2$L AND activestatus = 1 AND paystatus = 'C'
              AND recon_status = 'R'
              AND paydate >= CURRENT_DATE AND paydate < CURRENT_DATE + 1
        $q$, schema_n, rec.ins_id)
        INTO today_c;

        EXECUTE format($q$
            SELECT COUNT(*) FROM %I.students WHERE ins_id = %L AND activestatus = 1
        $q$, schema_n, rec.ins_id)
        INTO stu_cnt;

        ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
        inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
        student_count := stu_cnt; total_demand := demand; total_collected := collected;
        total_pending := pending; pending_approval := pending_a; today_collected := today_c;
        RETURN NEXT;
    END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION public.get_super_admin_dashboard_v2(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
