-- Fee Refund tables — refund voucher raised against a fee-collection receipt.
-- Canonical definition lives in complete_setup.sql (create_institution_schema);
-- this migration adds them to the CURRENT active schema so the feature works now.
-- Run once per institution-year schema (change the schema name for others).

-- fee_refund: one row per refund voucher (the receipt/payment being refunded).
CREATE TABLE IF NOT EXISTS kcet20262027.fee_refund (
  rf_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  doc_no        integer NOT NULL,        -- human-facing refund voucher number
  ins_id        integer NOT NULL,
  inscode       varchar(10),
  yr_id         integer,
  yrlabel       varchar(20),
  refunddate    date NOT NULL,
  pay_id        bigint,                  -- payment.pay_id being refunded
  paynumber     varchar(30),             -- denormalised receipt number
  stu_id        bigint,
  stuadmno      varchar(25),
  stuname       varchar(50),
  stuclass      varchar(20),
  refundmode    varchar(20) NOT NULL,    -- Cash / Cheque / DD / Others
  ban_id        integer,                 -- bank.ban_id by value (no cross-schema FK)
  bankname      varchar(100),
  bankref       varchar(100),
  chequedate    date,
  accountcode   varchar(50),
  refundreason  varchar(200),
  totalrefund   numeric(12,2) DEFAULT 0,
  totaladjust   numeric(12,2) DEFAULT 0,
  createdby     varchar(50),
  createdat     timestamp DEFAULT now() NOT NULL,
  activestatus  smallint DEFAULT 1 NOT NULL
);

-- fee_refunddetails: per fee-line breakdown of a refund voucher.
CREATE TABLE IF NOT EXISTS kcet20262027.fee_refunddetails (
  rfd_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rf_id         bigint NOT NULL,         -- fee_refund.rf_id
  dem_id        bigint,                  -- feedemand.dem_id being refunded
  ins_id        integer NOT NULL,
  refundterm    varchar(20),
  refundfeetype varchar(30),
  feeamount     numeric(12,2) DEFAULT 0, -- amount originally collected on this line
  refundamount  numeric(12,2) DEFAULT 0, -- amount returned to the student
  adjustamount  numeric(12,2) DEFAULT 0, -- amount retained / adjusted
  adjustreason  varchar(200),
  activestatus  smallint DEFAULT 1 NOT NULL
);

-- PostgREST needs privileges + a schema-cache reload to expose the new tables.
GRANT ALL ON kcet20262027.fee_refund         TO anon, authenticated;
GRANT ALL ON kcet20262027.fee_refunddetails  TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
