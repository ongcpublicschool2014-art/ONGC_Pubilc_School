-- Public Storage bucket that hosts the desktop auto-update manifest + installers.
-- The app reads  <project>/storage/v1/object/public/app-updates/latest.json  on
-- launch and, if a newer version is listed, downloads the installer .exe from
-- the same bucket. Public = anyone with the URL can DOWNLOAD (read-only); uploads
-- still require an authenticated admin (done from the Supabase dashboard).

INSERT INTO storage.buckets (id, name, public)
VALUES ('app-updates', 'app-updates', true)
ON CONFLICT (id) DO UPDATE SET public = true;
