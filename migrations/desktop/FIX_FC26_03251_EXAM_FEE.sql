-- =====================================================================
-- Add the missing EXAM FEE line to misc receipt FC26/03251.
--
-- WHAT HAPPENED: on 2026-09-30 at 14:13 SALAMAN RAJA S (421321106039) paid
-- Rs 3,600 through Paytm -- one transaction, 20260930010960000312058822689059251.
-- The counter had two lines on screen, MISCELLANEOUS 150 and an exam fee of
-- 3,450 whose fee type was never picked from the dropdown. Misc Collection
-- charged the sum of ALL lines but saved only the NAMED ones, so Paytm took
-- Rs 3,600 and the receipt was written for Rs 150.
--
-- The money arrived as a single Paytm transaction, so the tidiest record is a
-- single receipt for the whole of it: this AMENDS FC26/03251 rather than
-- issuing a second receipt, which would leave two rows to match against one
-- bank line. The receipt number, date and transaction id are untouched.
--
-- IT REFUSES unless live still matches exactly what was surveyed:
--   * the receipt is still active, still Rs 150, still that Paytm txn
--   * it still has exactly one line
--   * no EXAM FEE line has already been added (i.e. this has not been run)
--
-- Wrapped in a transaction: review the two SELECTs, then COMMIT or ROLLBACK.
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_mc  bigint;
  v_ins integer;
  v_n   integer;
BEGIN
  SELECT mc_id, ins_id INTO v_mc, v_ins
    FROM kcet20262027.misc_collection
   WHERE mcno = 'FC26/03251'
     AND activestatus = 1
     AND totalamount = 150.00
     AND paytm_txnid = '20260930010960000312058822689059251';
  IF v_mc IS NULL THEN
    RAISE EXCEPTION 'REFUSED: FC26/03251 is not in the state this fix expects '
                    '(active, Rs 150, that Paytm txn). It may already be fixed.';
  END IF;

  SELECT COUNT(*) INTO v_n
    FROM kcet20262027.misc_collection_detail
   WHERE mc_id = v_mc AND activestatus = 1;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'REFUSED: expected exactly one detail line, found %', v_n;
  END IF;

  IF EXISTS (SELECT 1 FROM kcet20262027.misc_collection_detail
              WHERE mc_id = v_mc AND fee_id = 49 AND activestatus = 1) THEN
    RAISE EXCEPTION 'REFUSED: an EXAM FEE line already exists on this receipt.';
  END IF;

  -- The line the cashier meant to add. fee_id 49 = EXAM FEE, the same type the
  -- other 23 misc exam-fee receipts use.
  INSERT INTO kcet20262027.misc_collection_detail
         (mc_id, ins_id, fee_id, feetype, amount, activestatus)
  VALUES (v_mc, v_ins, 49, 'EXAM FEE', 3450.00, 1);

  -- The header total must equal its lines, and equal what Paytm took.
  UPDATE kcet20262027.misc_collection
     SET totalamount = 3600.00,
         transamt    = CASE WHEN transamt IS NULL THEN NULL ELSE 3600.00 END,
         remarks     = TRIM(BOTH ' ' FROM
                        COALESCE(remarks,'') ||
                        ' [EXAM FEE 3450 added 2026-09-30: charged by Paytm but '
                        'not receipted -- fee type had not been picked]')
   WHERE mc_id = v_mc;

  RAISE NOTICE 'FC26/03251 amended: mc_id %, now Rs 3,600 over two lines', v_mc;
END $$;

-- Confirm before committing: header 3,600 and two lines summing to 3,600.
SELECT mcno, stuname, totalamount, paytm_txnid, recon_status
  FROM kcet20262027.misc_collection WHERE mcno = 'FC26/03251';

SELECT d.feetype, d.amount
  FROM kcet20262027.misc_collection_detail d
  JOIN kcet20262027.misc_collection m ON m.mc_id = d.mc_id
 WHERE m.mcno = 'FC26/03251' AND d.activestatus = 1
 ORDER BY d.mcd_id;

-- Review the two results above, then run:  COMMIT;   (or ROLLBACK; to abandon)
