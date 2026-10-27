-- REVERTED: on-admission (per-student-insert) fee-demand generation is DISABLED.
--
-- The AFTER INSERT trigger trg_gen_feedemand_on_student auto-generated a
-- student's demands into tempfeedemand on enrolment. That behaviour is no longer
-- wanted — demands are generated explicitly instead (generate_feedemand_for_class
-- / generate_feedemand_from_template, or Fee Demand). This block DROPS both the
-- trigger AND the fn_gen_feedemand_on_student function on every tenant schema.
--
-- Run this DO block ONCE to remove the trigger + function from all existing schemas.

DO $do$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT LIKE 'pg_%'
      AND nspname NOT IN ('public','information_schema','extensions','auth','storage',
                          'realtime','supabase_functions','graphql','graphql_public',
                          'pgsodium','pgsodium_masks','vault','net','_realtime','supabase_migrations')
  LOOP
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema=s AND table_name='students') THEN
      EXECUTE format('DROP TRIGGER IF EXISTS trg_gen_feedemand_on_student ON %I.students', s);
      EXECUTE format('DROP FUNCTION IF EXISTS %I.fn_gen_feedemand_on_student()', s);
      RAISE NOTICE 'feedemand-on-student trigger + function DROPPED on schema: %', s;
    END IF;
  END LOOP;
END $do$;
