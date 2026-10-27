-- Storage bootstrap, lifted out of complete_setup.sql so it can be re-run on
-- its own. Creates the InstitutionLogos bucket and the storage.objects
-- policies that logo and student-photo uploads need.
--
-- Run this when a logo upload fails with "You don't have permission to perform
-- this action" (42501): it means the bucket exists but has no INSERT policy,
-- which happens when the block inside complete_setup.sql could not SET ROLE
-- supabase_storage_admin and warned instead of aborting.
--
-- Idempotent: every policy is dropped and recreated.

DO $storage$
BEGIN
  --------------------------------------------------------------------
  -- 1. Buckets — safe as the current (postgres/anon) role
  --------------------------------------------------------------------
  BEGIN
    INSERT INTO storage.buckets (id, name, public)
    VALUES ('InstitutionLogos', 'InstitutionLogos', true)
    ON CONFLICT (id) DO UPDATE SET public = true;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'storage: could not create the InstitutionLogos bucket (%). Create it as a Public bucket from the Dashboard (Storage).', SQLERRM;
  END;

  --------------------------------------------------------------------
  -- 2. Become the storage owner so policy DDL is allowed, then create
  --    every policy. On failure: warn (don't abort) + RESET ROLE.
  --------------------------------------------------------------------
  BEGIN
    -- postgres is a member of supabase_storage_admin on hosted Supabase; this
    -- makes CREATE POLICY on storage.objects/buckets succeed. If it can't be
    -- done, the EXCEPTION handler below prints the Dashboard fallback.
    EXECUTE 'SET ROLE supabase_storage_admin';

    -- storage.buckets visibility (SDK resolves the bucket before objects)
    EXECUTE 'DROP POLICY IF EXISTS "Public buckets are visible to all" ON storage.buckets';
    EXECUTE 'CREATE POLICY "Public buckets are visible to all" ON storage.buckets FOR SELECT TO anon, authenticated USING (public = true)';

    -- InstitutionLogos bucket
    EXECUTE 'DROP POLICY IF EXISTS "InstitutionLogos public read" ON storage.objects';
    EXECUTE 'CREATE POLICY "InstitutionLogos public read" ON storage.objects FOR SELECT TO public USING (bucket_id = ''InstitutionLogos'')';
    EXECUTE 'DROP POLICY IF EXISTS "InstitutionLogos anon insert" ON storage.objects';
    EXECUTE 'CREATE POLICY "InstitutionLogos anon insert" ON storage.objects FOR INSERT TO anon, authenticated WITH CHECK (bucket_id = ''InstitutionLogos'')';
    EXECUTE 'DROP POLICY IF EXISTS "InstitutionLogos anon update" ON storage.objects';
    EXECUTE 'CREATE POLICY "InstitutionLogos anon update" ON storage.objects FOR UPDATE TO anon, authenticated USING (bucket_id = ''InstitutionLogos'') WITH CHECK (bucket_id = ''InstitutionLogos'')';
    EXECUTE 'DROP POLICY IF EXISTS "InstitutionLogos anon delete" ON storage.objects';
    EXECUTE 'CREATE POLICY "InstitutionLogos anon delete" ON storage.objects FOR DELETE TO anon, authenticated USING (bucket_id = ''InstitutionLogos'')';

    -- Per-institution student-photo buckets. ensure_student_photo_bucket()
    -- creates one bucket per inscode ('student-photos-<code>') but can't make
    -- object policies (it runs as anon). These wildcard policies cover every
    -- such bucket at once, so no per-institution policy step is ever needed.
    EXECUTE 'DROP POLICY IF EXISTS "student photos public read" ON storage.objects';
    EXECUTE 'CREATE POLICY "student photos public read" ON storage.objects FOR SELECT TO public USING (bucket_id LIKE ''student-photos-%'')';
    EXECUTE 'DROP POLICY IF EXISTS "student photos anon write" ON storage.objects';
    EXECUTE 'CREATE POLICY "student photos anon write" ON storage.objects FOR INSERT TO anon, authenticated WITH CHECK (bucket_id LIKE ''student-photos-%'')';
    EXECUTE 'DROP POLICY IF EXISTS "student photos anon update" ON storage.objects';
    EXECUTE 'CREATE POLICY "student photos anon update" ON storage.objects FOR UPDATE TO anon, authenticated USING (bucket_id LIKE ''student-photos-%'') WITH CHECK (bucket_id LIKE ''student-photos-%'')';
    EXECUTE 'DROP POLICY IF EXISTS "student photos anon delete" ON storage.objects';
    EXECUTE 'CREATE POLICY "student photos anon delete" ON storage.objects FOR DELETE TO anon, authenticated USING (bucket_id LIKE ''student-photos-%'')';

    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    BEGIN RESET ROLE; EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE WARNING 'storage: could not create object/bucket policies from SQL (%). Finish them from the Supabase Dashboard: Storage -> create bucket "InstitutionLogos" (Public); Storage -> Policies on "objects" add SELECT(public) + INSERT/UPDATE/DELETE(anon,authenticated) for bucket_id = ''InstitutionLogos'' and for bucket_id LIKE ''student-photos-%%''.', SQLERRM;
  END;
END
$storage$;

-- The app-updates bucket is NOT created by complete_setup.sql. It holds
-- latest.json, maintenance.json and the installers, so auto-update and the
-- maintenance flag need it. Public read; nothing in the app writes to it.
INSERT INTO storage.buckets (id, name, public)
VALUES ('app-updates', 'app-updates', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DO $upd$
BEGIN
  EXECUTE 'SET ROLE supabase_storage_admin';
  EXECUTE 'DROP POLICY IF EXISTS "app-updates public read" ON storage.objects';
  EXECUTE 'CREATE POLICY "app-updates public read" ON storage.objects FOR SELECT TO public USING (bucket_id = ''app-updates'')';
  RESET ROLE;
EXCEPTION WHEN OTHERS THEN
  BEGIN RESET ROLE; EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE WARNING 'storage: could not create the app-updates policy (%). Add it from the Dashboard: Storage -> Policies -> objects -> SELECT for public where bucket_id = ''app-updates''.', SQLERRM;
END
$upd$;

-- Verify: both buckets public, and policies present for objects.
SELECT id, public FROM storage.buckets ORDER BY id;
SELECT policyname, cmd FROM pg_policies
 WHERE schemaname = 'storage' AND tablename = 'objects' ORDER BY policyname;
