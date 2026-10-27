-- Performance indexes for demand generation + approval.
--
-- Without these, generation's two NOT EXISTS dedup checks and the approval
-- trigger's per-row feedemand lookup (by demno/demfeetype) do sequential scans
-- that grow O(N^2) as feedemand fills up — which is why generating/approving in
-- bulk timed out. These make each per-class batch finish in seconds.
--
-- Run once per institution schema (adjust the schema name). Also added to the
-- create_institution_schema generator so new schemas get them automatically.

-- Dedup checks in generate_feedemand_from_template / generate_feedemand_for_class
CREATE INDEX IF NOT EXISTS idx_feedemand_dedup
  ON kcet20262027.feedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1;

CREATE INDEX IF NOT EXISTS idx_tempfeedemand_dedup
  ON kcet20262027.tempfeedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1;

-- Approval trigger (fn_approve_tempfeedemand) looks up the existing feedemand row
-- by ins_id + demno + demfeetype for every row it approves.
CREATE INDEX IF NOT EXISTS idx_feedemand_demno_type
  ON kcet20262027.feedemand (ins_id, demno, demfeetype) WHERE activestatus = 1;
