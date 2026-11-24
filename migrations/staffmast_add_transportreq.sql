-- ============================================================================
-- staffmast.transportreq  varchar(3) NULL DEFAULT 'OWN'
-- ============================================================================
-- staffmast is one table per school-year schema. This adds the column to every
-- staffmast that exists now, and to school_staff_year() so the staffmast of
-- each NEW year is created with it. Idempotent.
-- ============================================================================

BEGIN;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'staffmast' AND table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('ALTER TABLE %I.staffmast ADD COLUMN IF NOT EXISTS transportreq varchar(3) DEFAULT ''OWN''', r.s);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.school_staff_year(p_schema text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE s text := lower(p_schema); v_seq text;
BEGIN
  IF to_regnamespace(s) IS NULL OR to_regclass('public.schstaff') IS NULL
     OR to_regclass(quote_ident(s) || '.semester') IS NULL THEN   -- school year schemas only
    RETURN;
  END IF;
  v_seq := quote_ident(s) || '.staffmast_staffmast_id_seq';
  EXECUTE format('CREATE SEQUENCE IF NOT EXISTS %I.staffmast_staffmast_id_seq', s);
  EXECUTE format($t$
    CREATE TABLE IF NOT EXISTS %1$I.staffmast (
      staffmast_id  numeric(8,0) NOT NULL DEFAULT nextval(%2$L::regclass),
      staf_id       numeric(8,0) NOT NULL REFERENCES public.schstaff(staf_id) ON DELETE CASCADE,
      emp_code      varchar(30)  NOT NULL,
      stafname      varchar(120) NOT NULL,
      shortname     varchar(30)  NOT NULL,
      mobile_no     varchar(15),
      emailid       varchar(120),
      designation   varchar(30),
      transportreq  varchar(3)   DEFAULT 'OWN',
      is_active     boolean      NOT NULL DEFAULT true,
      created_by    integer,
      updated_by    integer,
      created_at    timestamptz  NOT NULL DEFAULT now(),
      updated_at    timestamptz  NOT NULL DEFAULT now(),
      PRIMARY KEY (staffmast_id),
      CONSTRAINT staffmast_staf_id_key UNIQUE (staf_id)
    )$t$, s, v_seq);
  EXECUTE format('ALTER TABLE %I.staffmast ADD COLUMN IF NOT EXISTS transportreq varchar(3) DEFAULT ''OWN''', s);
  EXECUTE format('ALTER SEQUENCE %I.staffmast_staffmast_id_seq OWNED BY %I.staffmast.staffmast_id', s, s);
  EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS staffmast_emp_code_key ON %I.staffmast (upper(btrim(emp_code)))', s);
  EXECUTE format('DROP TRIGGER IF EXISTS trg_staffmast_touch ON %I.staffmast', s);
  EXECUTE format('CREATE TRIGGER trg_staffmast_touch BEFORE UPDATE ON %I.staffmast FOR EACH ROW EXECUTE FUNCTION public.trg_staff_touch()', s);
  EXECUTE format('ALTER TABLE %I.staffmast ENABLE ROW LEVEL SECURITY', s);
  EXECUTE format('REVOKE ALL ON %I.staffmast FROM PUBLIC, anon, authenticated', s);
  EXECUTE format('REVOKE ALL ON SEQUENCE %I.staffmast_staffmast_id_seq FROM PUBLIC, anon, authenticated', s);
END $function$
;

COMMIT;

NOTIFY pgrst, 'reload schema';
