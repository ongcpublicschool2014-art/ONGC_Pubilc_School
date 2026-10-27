-- ############################################################################
--
--   READ-ONLY PRE-CHECK -- run this BEFORE LIVE_ADVANCE_LOAD_20260923.sql
--
--   Answers three questions in one row:
--     1. Which project am I actually on?
--     2. Is advance_collection there to load into?
--     3. Have the advances already been loaded?
--
--   It writes nothing. Safe to run on either project, as often as you like.
--
-- ----------------------------------------------------------------------------
-- HOW TO READ THE RESULT
-- ----------------------------------------------------------------------------
--   project        'LIVE' or 'TEST'. Worked out from classtype_cols, not from
--                  the project name -- both projects are called KCET and both
--                  show the PRODUCTION chip, which is how the wrong one got
--                  queried twice already. Cross-check the URL too: live is
--                  /project/exasnbapvgfeooxyxjas.
--
--   classtype_cols how many year schemas carry class.classtype. It is NO LONGER
--                  what decides LIVE vs TEST -- it could not be, once the
--                  0.0.8 release added the column to live and made both sides
--                  read the same. project now comes from
--                  public._this_is_the_test_project, which exists on TEST and
--                  nowhere else, so the release cannot blunt it.
--                  Read this column as: 0 = the release has NOT run here.
--
--   year_schema    the schema the load will write into, resolved exactly the
--                  way the app and the load script resolve it.
--
--   adv_table      'yes' = advance_collection exists. 'MISSING' = the load will
--                  fail (safely, writing nothing) and ADVANCE_COLLECTION_SETUP.sql
--                  has to be run on live first.
--
--   advances_loaded  0     = not loaded yet; the load is still to do.
--                    149   = already loaded; running it again changes nothing.
--                    other = tell me the number before doing anything else.
-- ############################################################################

DO $check$
DECLARE
  v_schema text;
  v_tbl    text;
  v_sql    text;
BEGIN
  SELECT lower(i.inshortname) || replace(y.yrlabel, '-', '')
    INTO v_schema
    FROM public.institution i
    JOIN public.institutionyear y ON y.ins_id = i.ins_id AND y.activestatus = 1
   WHERE i.ins_id = 1
   ORDER BY y.iyr_id DESC
   LIMIT 1;

  v_tbl := to_regclass(quote_ident(COALESCE(v_schema, 'x')) || '.advance_collection');

  -- Counting the advances needs the table to exist; when it does not, report
  -- that rather than failing, since "not created yet" is a real answer here.
  IF v_tbl IS NULL THEN
    v_sql := format($q$
      CREATE TEMP VIEW _pre_check AS
      SELECT CASE WHEN to_regclass('public._this_is_the_test_project') IS NULL
                  THEN 'LIVE' ELSE 'TEST' END AS project,
             (SELECT count(*) FROM information_schema.columns
               WHERE table_name = 'class' AND column_name = 'classtype') AS classtype_cols,
             %L::text AS year_schema,
             'MISSING'::text AS adv_table,
             NULL::bigint AS advances_loaded,
             NULL::numeric AS advances_total $q$, COALESCE(v_schema, '(unresolved)'));
  ELSE
    v_sql := format($q$
      CREATE TEMP VIEW _pre_check AS
      SELECT CASE WHEN to_regclass('public._this_is_the_test_project') IS NULL
                  THEN 'LIVE' ELSE 'TEST' END AS project,
             (SELECT count(*) FROM information_schema.columns
               WHERE table_name = 'class' AND column_name = 'classtype') AS classtype_cols,
             %L::text AS year_schema,
             'yes'::text AS adv_table,
             count(*) AS advances_loaded,
             COALESCE(sum(transtotalamount), 0) AS advances_total
        FROM %I.advance_collection
       WHERE createdby = 'ADVANCE IMPORT KCETAdvCol2627' $q$, v_schema, v_schema);
  END IF;

  EXECUTE v_sql;
END $check$;

SELECT * FROM _pre_check;
