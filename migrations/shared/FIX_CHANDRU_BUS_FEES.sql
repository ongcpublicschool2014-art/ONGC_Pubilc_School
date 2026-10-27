-- =====================================================================
-- CHANDRU R (262791, B.E MECH -I) -- the last demand billed nothing
-- while holding money. Needs TWO figures the database cannot supply.
--
-- WHAT HAPPENED. On 05-10-2026 11:40:31 a BUS FEES demand was added
-- through Student Fee Definition with the amount left blank, and
-- Rs 10,000 cash was collected into it 55 seconds later (FC26/03398,
-- taken by LATHA). His BUS APPLICATION is blank too, from a separate
-- event on 21-09.
--
-- WHY NOT JUST BILL THE 10,000 HE PAID. Bus fees are route-based and
-- range from 6,600 to 23,300; there is no standard figure, and his
-- student record carries no route, stop, address or city to infer one
-- from. The nearest comparable -- the next student through the same
-- dialog that morning -- paid 12,500 against a 15,200 bill, so a part
-- payment is entirely normal here. Writing 10,000 in would close an
-- account that may still owe money, which is the exact failure this
-- whole exercise has been unwinding.
--
-- ASK FIRST: the transport office knows his route fee, and LATHA took
-- the cash two days ago.
--
--   * if 10,000 was the WHOLE fee        -> leave 10000 below
--   * if his route costs more            -> put the route fee below
--
-- BUS APPLICATION is 100 for 584 students and 0 for 43; his is 0.
-- Confirm it is due before including it.
-- =====================================================================

WITH answer(bus_fee, bus_application) AS (
  VALUES (10000::numeric,        -- <<< the route fee the office confirms
          100::numeric)          -- <<< 0 if he is not charged it
)
UPDATE kcet20262027.feedemand fd
   SET feeamount       = v.amount,
       balancedue      = GREATEST(v.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       reconbalancedue = GREATEST(v.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       paidstatus      = CASE WHEN v.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0) <= 0
                              THEN 'P' ELSE 'U' END
  FROM answer a
  CROSS JOIN LATERAL (VALUES ('BUS FEES', a.bus_fee),
                             ('BUS APPLICATION', a.bus_application)) AS v(feetype, amount)
 WHERE fd.stuadmno     = '262791'
   AND fd.demfeetype   = v.feetype
   AND fd.activestatus = 1
   AND COALESCE(fd.feeamount,0) = 0   -- only while still unbilled
   AND v.amount > 0;                  -- a zero here means "do not bill it"

-- His ledger afterwards. BUS FEES balance = route fee - 10,000.
SELECT demfeetype, feeamount, paidamount, balancedue, paidstatus
  FROM kcet20262027.feedemand
 WHERE stuadmno = '262791' AND activestatus = 1
 ORDER BY demfeetype;

-- The whole point: this should now return NO rows.
SELECT stuadmno, demfeetype, feeamount, paidamount
  FROM kcet20262027.feedemand
 WHERE activestatus = 1
   AND COALESCE(feeamount,0) - COALESCE(conamount,0) <= 0
   AND COALESCE(paidamount,0) > 0;
