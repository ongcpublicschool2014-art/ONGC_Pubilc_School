-- Interim Promotion — mid-year move of a single student to another class.
-- Canonical definition also lives in complete_setup.sql (create_institution_schema);
-- this migration adds the table to the CURRENT active schema so the feature
-- works now. Run once per institution-year schema (change the schema name).
--
-- One row per promotion, keeping the before/after class for audit. The student
-- record itself is updated separately (students.stuclass / courname), and the
-- new class's fee demands are staged into tempfeedemand by the app.

CREATE TABLE IF NOT EXISTS kcet20262027.interim_promotion (
  ip_id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  doc_no                integer NOT NULL,      -- human-facing voucher number
  ins_id                integer NOT NULL,
  promotiondate         date NOT NULL,
  stu_id                bigint,
  stuadmno              varchar(25),
  stuname               varchar(50),
  courname              varchar(20),           -- course BEFORE the move
  stuclass              varchar(20),           -- class  BEFORE the move
  transferred_courname  varchar(20),           -- course AFTER the move
  transferred_class     varchar(20),           -- class  AFTER the move
  remarks               varchar(200),
  createdby             varchar(50),
  createdat             timestamp DEFAULT now() NOT NULL,
  activestatus          smallint DEFAULT 1 NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_interim_promotion_stu
  ON kcet20262027.interim_promotion (ins_id, stu_id);

-- PostgREST needs privileges + a schema-cache reload to expose the new table.
GRANT ALL ON kcet20262027.interim_promotion TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
