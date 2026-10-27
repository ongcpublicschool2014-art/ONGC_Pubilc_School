-- ############################################################################
--
--   EduCore360 -- ADVANCE RECEIPT NUMBER, PREFIX "SA"
--   24-09-2026
--
--   Sets the Advance No sequence (Fee Master -> Advance No) to prefix SA,
--   width 5, starting at 1. Advance Collection refuses to take a STUDENT
--   advance until this row exists -- it will not invent a receipt number.
--
--   SAFE ON EITHER PROJECT, and meant for both. Unlike the release scripts
--   this one carries no refuse-guard: the same configuration is wanted on
--   TEST and on LIVE. It prints which project it ran on so you can see.
--
-- ----------------------------------------------------------------------------
-- THE ONE THING WORTH READING BEFORE YOU RUN IT
-- ----------------------------------------------------------------------------
-- The 149 advances waiting to be loaded onto live already carry SA numbers,
-- but in the LEGACY format -- SA + 2-digit year + 5 digits:
--
--     SA2500334 ... SA2500354      (5 rows)
--     SA2600001 ... SA2600299      (10 rows)
--
-- This script configures plain "SA" + 5 digits, so the next receipt the app
-- issues is SA00001. That is SEVEN characters against the legacy NINE, so the
-- two series cannot collide on uq_advance_advno -- but they will sit side by
-- side in the register looking unrelated.
--
-- If instead you want the app to CONTINUE the legacy series -- next receipt
-- SA2600300 -- change the two values in section 1 to:
--
--     v_prefix := 'SA26';          -- instead of 'SA'
--     v_width  := 5;               -- unchanged
--
-- and the counter maths below will pick up from SA2600299 on its own, because
-- it reads the highest number already issued under the prefix it is given.
-- Say the word and I will hand you that version instead.
--
-- ----------------------------------------------------------------------------
-- HOW THE COUNTER IS SET, AND WHY IT CANNOT REISSUE A NUMBER
-- ----------------------------------------------------------------------------
-- seqcurno is never set blind. It is computed as the HIGHEST of:
--
--   * the highest number already issued under this prefix, read from
--     advance_collection itself
--   * seqstart - 1
--   * the row's current seqcurno, but ONLY when the prefix is not changing
--
-- So a re-run cannot rewind the counter and hand out a number twice; and
-- changing the prefix starts that prefix's own series rather than inheriting
-- a count from the old one. TEST currently has AD00001 / AD00002 issued under
-- the old "AD" prefix, so switching to SA there starts at SA00001, which is
-- free.
--
-- SAFE TO RE-RUN. It writes one configuration row per institution and touches
-- no receipt, advance, demand or payment.
--
-- To see it afterwards in the app: Fee Master -> Advance No.
-- ############################################################################


-- ----------------------------------------------------------------------------
-- 1 -- the settings
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _advno_log (
  ord       int,
  institution text,
  detail    text
) ON COMMIT DROP;

DO $advno$
DECLARE
  v_prefix  text := 'SA';   -- <= the receipt prefix
  v_width   int  := 5;      -- <= digits after it, so SA00001
  v_start   int  := 1;      -- <= first number

  r          RECORD;
  v_schema   text;
  v_seq_id   int;
  v_oldpre   text;
  v_oldcur   numeric;
  v_maxused  numeric;
  v_newcur   numeric;
  v_yr_id    int;
  v_yrlabel  text;
  v_sequid   text;
  v_action   text;
BEGIN
  v_sequid := left(v_prefix || lpad(v_start::text, v_width, '0'), 18);

  FOR r IN SELECT ins_id, COALESCE(insname, inscode, ins_id::text) AS name
             FROM public.institution
            WHERE COALESCE(activestatus, 1) = 1
            ORDER BY ins_id
  LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    CONTINUE WHEN v_schema IS NULL;
    -- A schema with no sequence table predates the numbering rework; nothing
    -- here can apply to it.
    CONTINUE WHEN to_regclass(format('%I.sequence', v_schema)) IS NULL;

    -- The year stamped on the row, exactly as the Fee Master screen does it.
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year
                     WHERE ins_id = $1 AND activestatus = 1
                     ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_yr_id, v_yrlabel USING r.ins_id;

    -- The highest number ALREADY ISSUED under this exact prefix and width, read
    -- from the advances themselves rather than trusted from the counter. An
    -- advance loaded by script (the 149) never touched the sequence, so the
    -- counter alone would happily hand out a number that is already taken.
    v_maxused := 0;
    IF to_regclass(format('%I.advance_collection', v_schema)) IS NOT NULL THEN
      EXECUTE format(
        'SELECT COALESCE(MAX(substring(advno from %s)::numeric), 0)
           FROM %I.advance_collection
          WHERE ins_id = $1 AND advno ~ $2',
        (length(v_prefix) + 1)::text, v_schema)
        INTO v_maxused
        USING r.ins_id, '^' || v_prefix || '[0-9]{' || v_width || '}$';
    END IF;

    SELECT NULL::int, NULL::text, NULL::numeric INTO v_seq_id, v_oldpre, v_oldcur;
    EXECUTE format('SELECT seq_id, seqprefix, COALESCE(seqcurno, 0)
                      FROM %I.sequence
                     WHERE ins_id = $1 AND actname = ''ADVNO'' AND activestatus = 1
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_oldpre, v_oldcur USING r.ins_id;

    IF v_seq_id IS NULL THEN
      -- Nothing configured yet: start this prefix's own series.
      v_newcur := GREATEST(v_maxused, v_start - 1);
      EXECUTE format(
        'INSERT INTO %I.sequence
           (ins_id, mod_id, yr_id, yrlabel, actname, seqname, isprefix,
            seqprefix, seqstart, seqwidth, sequid, seqcurno, activestatus, fg_id)
         VALUES ($1, 0, $2, $3, ''ADVNO'', $4, ''Y'',
                 $4, $5, $6, $7, $8, 1, NULL)', v_schema)
        USING r.ins_id, COALESCE(v_yr_id, 0), COALESCE(v_yrlabel, ''),
              v_prefix, v_start, v_width, v_sequid, v_newcur;
      v_action := 'created';
    ELSE
      -- Keep the running count only when the prefix is NOT changing. A new
      -- prefix is a new series, and inheriting the old prefix's count would
      -- skip numbers for no reason.
      IF upper(COALESCE(v_oldpre, '')) = upper(v_prefix) THEN
        v_newcur := GREATEST(v_oldcur, v_maxused, v_start - 1);
        v_action := 'already SA -- counter kept';
      ELSE
        v_newcur := GREATEST(v_maxused, v_start - 1);
        v_action := format('prefix %s -> %s', COALESCE(v_oldpre, '(none)'), v_prefix);
      END IF;
      EXECUTE format(
        'UPDATE %I.sequence
            SET seqname = $1, seqprefix = $1, isprefix = ''Y'',
                seqstart = $2, seqwidth = $3, sequid = $4, seqcurno = $5
          WHERE seq_id = $6', v_schema)
        USING v_prefix, v_start, v_width, v_sequid, v_newcur, v_seq_id;
    END IF;

    INSERT INTO _advno_log VALUES (
      r.ins_id, r.name,
      format('%s -- next advance receipt will be %s%s',
             v_action, v_prefix, lpad((v_newcur + 1)::bigint::text, v_width, '0')));
  END LOOP;
END $advno$;


-- ----------------------------------------------------------------------------
-- 2 -- what it did, plus which project you are on
-- ----------------------------------------------------------------------------
SELECT 'project' AS ord,
       CASE WHEN to_regclass('public._this_is_the_test_project') IS NOT NULL
            THEN 'TEST' ELSE 'LIVE' END AS institution,
       'run on this project' AS detail

UNION ALL
SELECT ord::text, institution, detail FROM _advno_log

-- No third branch reading the sequence table back by name. Section 1 resolves
-- the year schema per institution, so naming it here would be the one place
-- in the file that assumes what it is called -- and because the editor runs
-- this as ONE transaction, that SELECT failing on a differently-named schema
-- would roll back the configuration it had just written. The log row above
-- already carries the resulting number.

 ORDER BY 1;
