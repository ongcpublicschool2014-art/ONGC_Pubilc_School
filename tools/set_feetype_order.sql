-- ============================================================================
-- The fee-type running order the office asked for.
-- ============================================================================
-- These eight lead, in this sequence. Everything else is numbered from 9
-- upwards in alphabetical order -- which is what "don't consider order"
-- means in practice: nobody has an opinion about them, so they keep the order
-- they already appeared in.
--
-- EVERY fee type gets a number, none are left NULL. The display is identical
-- either way (the app sorts a blank ordid last), but a real number is one the
-- office can see in the master and change, where a blank looks like something
-- nobody got round to.
--
--   1  TUITION FEE
--   2  BUS FEES
--   3  ANNA UNIVERSITY FEE
--   4  A.U.SPORTS FEE            (the office calls this "sports fee")
--   5  BUS APPLICATION           ("bus application fee")
--   6  FIRST GRADUATE AMOUNT     ("first graduate")
--   7  SC/ST SCHOLARSHIP
--   8  EXAM FEE
--
-- MATCHED ON feedesc, NOT fee_id. The reports join fee types by DESCRIPTION
-- -- feedemand stores demfeetype as text, there is no fee_id on the report
-- rows -- so the description is what the ordering has to key on. It also
-- means this script reads the same on live as on TEST without checking
-- whether the ids line up.
--
-- The descriptions above were read off the database, not guessed:
--   18 TUITION FEE · 46 BUS FEES · 21 ANNA UNIVERSITY FEE · 191 A.U.SPORTS FEE
--   253 BUS APPLICATION · 134 FIRST GRADUATE AMOUNT · 161 SC/ST SCHOLARSHIP
--   49 EXAM FEE
--
-- STEP 1 CLEARS EVERYTHING FIRST, on purpose. Without it the seed numbers
-- from FEETYPE_ORDID's PART 2 would stay on every other fee type and sort
-- them AHEAD of nothing in particular, in creation order -- which is not the
-- "don't consider" the office asked for and would look arbitrary.
--
-- Re-runnable. Run FEETYPE_ORDID.sql (or the 13-10 release) first so the
-- column exists.
--
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

-- --------------------------------------------------------------- STEP 1 ----
-- Clear. Everything starts unnumbered, then the eight are given their place.
-- ---------------------------------------------------------------------------
UPDATE kcet20262027.feetype SET ordid = NULL WHERE ordid IS NOT NULL;


-- --------------------------------------------------------------- STEP 2 ----
-- The eight, in order. UPPER(btrim()) so a stray space or a difference in
-- case cannot quietly skip one and leave a gap nobody notices.
-- ---------------------------------------------------------------------------
UPDATE kcet20262027.feetype f
   SET ordid = v.ord
  FROM (VALUES
          (1, 'TUITION FEE'),
          (2, 'BUS FEES'),
          (3, 'ANNA UNIVERSITY FEE'),
          (4, 'A.U.SPORTS FEE'),
          (5, 'BUS APPLICATION'),
          (6, 'FIRST GRADUATE AMOUNT'),
          (7, 'SC/ST SCHOLARSHIP'),
          (8, 'EXAM FEE')
       ) AS v(ord, name)
 WHERE UPPER(btrim(f.feedesc)) = v.name;


-- --------------------------------------------------------------- STEP 3 ----
-- Everything else, from 9 upwards, alphabetically.
--
-- Inactive fee types are numbered too, so a blank never comes back if one is
-- reactivated. They consume numbers and leave gaps among the active ones --
-- harmless, because the order only ever compares these values, it never
-- counts on them being consecutive.
-- ---------------------------------------------------------------------------
UPDATE kcet20262027.feetype f
   SET ordid = r.seq
  FROM (
    SELECT fee_id,
           (8 + row_number() OVER (ORDER BY UPPER(btrim(feedesc)), fee_id))::smallint AS seq
      FROM kcet20262027.feetype
     WHERE ordid IS NULL
  ) r
 WHERE f.fee_id = r.fee_id;


-- --------------------------------------------------------------- STEP 4 ----
-- Did all eight land? A name that has changed in the master would silently
-- match nothing, so this says so rather than leaving a hole in the order.
-- ---------------------------------------------------------------------------
DO $check$
DECLARE missing text;
BEGIN
  SELECT string_agg(v.name, ', ' ORDER BY v.ord)
    INTO missing
    FROM (VALUES
            (1, 'TUITION FEE'), (2, 'BUS FEES'), (3, 'ANNA UNIVERSITY FEE'),
            (4, 'A.U.SPORTS FEE'), (5, 'BUS APPLICATION'),
            (6, 'FIRST GRADUATE AMOUNT'), (7, 'SC/ST SCHOLARSHIP'),
            (8, 'EXAM FEE')
         ) AS v(ord, name)
   WHERE NOT EXISTS (SELECT 1 FROM kcet20262027.feetype f
                      WHERE UPPER(btrim(f.feedesc)) = v.name
                        AND f.ordid = v.ord);
  IF missing IS NOT NULL THEN
    RAISE WARNING 'NOT numbered (no fee type with this exact description): %',
      missing;
  ELSE
    RAISE NOTICE 'all eight numbered';
  END IF;
END
$check$;


-- ------------------------------------------------------------- VERIFY ------
-- 1. Nothing left unnumbered. Expect 0.
SELECT count(*) AS still_blank
  FROM kcet20262027.feetype WHERE ordid IS NULL;

-- 2. The order the reports and the Fee Type picker will now use.
SELECT ordid AS ord, feedesc, feeshort, activestatus
  FROM kcet20262027.feetype
 WHERE activestatus = 1
 ORDER BY ordid, feedesc;
