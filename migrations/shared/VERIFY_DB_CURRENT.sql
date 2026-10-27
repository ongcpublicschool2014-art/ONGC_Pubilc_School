-- ============================================================================
-- Is this database carrying the current code? One row per thing that matters.
-- ============================================================================
-- Read-only. Run it on LIVE before and after a release, and on TEST after a
-- restore. Every row should read OK. Anything reading MISSING names the file
-- to run.
--
-- WHY THIS FILE EXISTS. "Is the migration on live?" has been answered three
-- times this week by reading a function definition by eye, and twice the
-- answer was wrong:
--
--   * _save_advance_collection was called stale because the marker searched
--     for sat outside a 200-line window -- the body is 11,715 characters;
--   * save_misc_collection was called stale because a psql LIKE pattern
--     containing $2 was eaten by PowerShell escaping before it reached the
--     server, so the match silently failed.
--
-- Both were false alarms that nearly produced a pointless "fix". A marker
-- checked INSIDE the real function body, from a file rather than a shell
-- argument, cannot go wrong that way.
--
-- ADDING A ROW. Pick a string that exists ONLY in the new version of the
-- function -- a comment line from the migration is ideal, because it is
-- stable and unique -- and add it to the VALUES list with the file that
-- installs it.
-- ============================================================================

WITH want(fn, marker, should_exist, installed_by) AS (
  VALUES
    -- A misc receipt is numbered out of its own fee group's sequence, so a
    -- MESS FEE is HF00002 and not FC26/03794 off the college run.
    ('save_misc_collection',      'RECEIPT NUMBER -- from the group', true,
     'migrations/MISC_RECEIPT_SEQUENCE_BY_GROUP.sql'),
    -- ...and the version it replaced must be gone.
    ('save_misc_collection',      'SHARED fee-collection sequence',   false,
     'migrations/MISC_RECEIPT_SEQUENCE_BY_GROUP.sql'),

    -- A fee added with no amount is refused. Without this a demand is billed
    -- 0, reads as fully settled and is never chased.
    ('add_student_fee_demand',    'p_amount <= 0',                    true,
     'migrations/shared/GUARD_ZERO_AMOUNT_FEE_DEMAND.sql'),

    -- The Transactions screen's date-filtered RPC. Absent, the app falls back
    -- to the unfiltered one and pays for the whole year to draw one day.
    ('fn_get_transactions_range', 'p.paydate >= $2',                  true,
     'migrations/desktop/FN_GET_TRANSACTIONS_RANGE.sql'),

    -- An advance refuses a line with no amount.
    ('_save_advance_collection',  'v_line_count = 0',                 true,
     'migrations/shared/ADVANCE_NUMBER_FROM_FEEGROUP.sql'),

    -- Routing survives a deleted bank.
    ('paytm_mid_for_routing',     'p_fg_id IS NULL AND p_ban_id IS NULL', true,
     'migrations/shared/FIX_ROUTING_LOOKUP_AFTER_BANK_DELETE.sql'),

    -- A refusal is only recorded when money was really taken.
    ('webhook_record_refusal',    'p_pay_id IS NOT NULL AND p_ins_id IS NOT NULL', true,
     'migrations/shared/REFUSALS_ONLY_WHEN_REAL.sql'),

    -- Row-level security for a newly provisioned schema. create_institution_
    -- schema delegates to this, so a new institution-year is born locked.
    ('read_lock_schema',          'app_tenant_read',                  true,
     'migrations/shared/CREATE_INSTITUTION_SCHEMA_CURRENT.sql')
),
got AS (
  SELECT w.fn, w.marker, w.should_exist, w.installed_by,
         f.def IS NOT NULL                      AS fn_exists,
         COALESCE(f.def LIKE '%' || w.marker || '%', false) AS marker_found
    FROM want w
    LEFT JOIN LATERAL (
      SELECT pg_get_functiondef(p.oid) AS def
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = w.fn
       LIMIT 1
    ) f ON true
)
SELECT CASE
         WHEN NOT fn_exists                     THEN 'MISSING - no such function'
         WHEN marker_found = should_exist       THEN 'OK'
         WHEN should_exist                      THEN 'MISSING - old version still installed'
         ELSE                                        'MISSING - old version not replaced'
       END                                      AS status,
       fn                                       AS function,
       CASE WHEN marker_found = should_exist THEN '' ELSE installed_by END AS run_this
  FROM got
 ORDER BY (CASE WHEN marker_found = should_exist THEN 1 ELSE 0 END), fn;
