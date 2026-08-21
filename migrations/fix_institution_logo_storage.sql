-- ============================================================================
-- Fix: "Institution created, but logo upload failed. You don't have permission
-- to perform this action."
-- ============================================================================
-- Registration uploads the logo to the public InstitutionLogos bucket as the
-- anon role (the app has no Supabase Auth session). The upload needs INSERT +
-- UPDATE (upsert:true) storage policies for anon on that bucket. This
-- (re)creates the bucket and its policies. Idempotent / safe to re-run.
--
-- Run in the Supabase SQL editor (it runs with rights to manage storage
-- policies). Same as complete_setup.sql lines ~2839-2862.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('InstitutionLogos', 'InstitutionLogos', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS "InstitutionLogos public read" ON storage.objects;
CREATE POLICY "InstitutionLogos public read"
ON storage.objects FOR SELECT TO public
USING (bucket_id = 'InstitutionLogos');

DROP POLICY IF EXISTS "InstitutionLogos anon insert" ON storage.objects;
CREATE POLICY "InstitutionLogos anon insert"
ON storage.objects FOR INSERT TO anon, authenticated
WITH CHECK (bucket_id = 'InstitutionLogos');

DROP POLICY IF EXISTS "InstitutionLogos anon update" ON storage.objects;
CREATE POLICY "InstitutionLogos anon update"
ON storage.objects FOR UPDATE TO anon, authenticated
USING (bucket_id = 'InstitutionLogos')
WITH CHECK (bucket_id = 'InstitutionLogos');

DROP POLICY IF EXISTS "InstitutionLogos anon delete" ON storage.objects;
CREATE POLICY "InstitutionLogos anon delete"
ON storage.objects FOR DELETE TO anon, authenticated
USING (bucket_id = 'InstitutionLogos');
