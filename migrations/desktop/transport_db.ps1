<#
  TRANSPORT MODULE - database tool (Windows PowerShell 5.1 or later).
  See TRANSPORT_DB_README.md. Files and their order: transport_install_order.txt.

  Works through the Supabase Management API with a personal access token
  (Supabase dashboard -> Account -> Access Tokens). The token is not saved.

    install  put the transport module on a database that does not have it
             (all files in one transaction: all or nothing)
    update   run every "always" file again (one transaction); brings an
             installed database up to date
    check    prove the SQL files rebuild exactly what the database has: a fresh
             install inside a transaction that is always rolled back
    test     run transport_02_phase1_tests.sql (always rolled back)
    year     start an academic year schema, e.g. -Year 2027-2028
    script   write the install and the update as one .sql file each, to run by
             hand (Supabase SQL editor or psql); no project or token needed.
             Default folder: migrations\desktop\single (-OutDir to change)

  Examples
    $env:SUPABASE_ACCESS_TOKEN = 'sbp_...'
    .\migrations\desktop\transport_db.ps1 -Action check   -ProjectRef abcdefghijklmnopqrst
    .\migrations\desktop\transport_db.ps1 -Action install -ProjectRef abcdefghijklmnopqrst
    .\migrations\desktop\transport_db.ps1 -Action year    -ProjectRef abcdefghijklmnopqrst -Year 2027-2028
    .\migrations\desktop\transport_db.ps1 -Action script

  install, update and year ask before changing anything; -Yes skips the question.
#>
param(
  [Parameter(Mandatory = $true)] [ValidateSet('install', 'update', 'check', 'test', 'year', 'script')] [string] $Action,
  [string] $ProjectRef,
  [string] $AccessToken = $env:SUPABASE_ACCESS_TOKEN,
  [string] $Year,
  [string] $OutDir,
  [switch] $Yes
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if ($Action -ne 'script') {
  if (-not $AccessToken) { throw 'Give -AccessToken, or set $env:SUPABASE_ACCESS_TOKEN (Supabase -> Account -> Access Tokens).' }
  if ($ProjectRef -notmatch '^[a-z0-9]{20}$') { throw 'ProjectRef should be the 20-letter project id from the project URL.' }
}
$api = 'https://api.supabase.com/v1/projects/' + $ProjectRef

# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------
function Invoke-Sql([string] $sql) {
  $body = [Text.Encoding]::UTF8.GetBytes((@{ query = $sql } | ConvertTo-Json -Compress))
  try {
    return Invoke-RestMethod -Method Post -Uri "$api/database/query" -Headers @{ Authorization = "Bearer $AccessToken" } `
      -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 600
  } catch {
    $m = $_.ErrorDetails.Message
    if ($m) { try { $m = ($m | ConvertFrom-Json).message } catch { } } else { $m = $_.Exception.Message }
    throw (New-Object System.Exception $m)
  }
}

function Confirm-Target([string] $what) {
  $p = Invoke-RestMethod -Uri $api -Headers @{ Authorization = "Bearer $AccessToken" }
  Write-Host ("Project: {0} ({1})" -f $p.name, $ProjectRef) -ForegroundColor Cyan
  if ($Yes) { return }
  $ans = Read-Host "$what on '$($p.name)'? Type yes to continue"
  if ($ans -ne 'yes') { throw 'Stopped; nothing was changed.' }
}

function Get-State {
  $r = Invoke-Sql @'
SELECT (to_regclass('public.tr_route') IS NOT NULL OR to_regnamespace('transport20262027') IS NOT NULL OR to_regnamespace('transport2627') IS NOT NULL
        OR to_regnamespace('transport') IS NOT NULL)                                       AS installed,
       to_regprocedure('public.session_context(text)') IS NOT NULL                          AS session_context,
       to_regprocedure('public._role_can(integer,integer,text,text[],text)') IS NOT NULL   AS role_can,
       to_regclass('public.institutionyear') IS NOT NULL                                   AS institutionyear,
       to_regclass('public.feetype') IS NOT NULL                                           AS feetype,
       to_regclass('public.rolemenuaccess') IS NOT NULL                                    AS rolemenuaccess,
       to_regclass('public.institutionusers') IS NOT NULL                                  AS institutionusers,
       EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'InstitutionLogos')                AS logos_bucket
'@
  return @($r)[0]
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
function Get-Manifest {
  $items = @()
  foreach ($line in Get-Content (Join-Path $here 'transport_install_order.txt')) {
    $t = ($line -replace '#.*$', '').Trim()
    if (-not $t) { continue }
    $p = $t -split '\s+'
    if ($p.Count -ne 2 -or $p[1] -notin @('once', 'always')) { throw "Bad line in transport_install_order.txt: $line" }
    if (-not (Test-Path (Join-Path $here $p[0]))) { throw "Missing file: $($p[0])" }
    $items += [pscustomobject]@{ File = $p[0]; Mode = $p[1] }
  }
  return $items
}

# Top-level statements of a script; quotes, comments and $tag$ bodies aware.
function Get-Statements([string] $sql) {
  $list = New-Object System.Collections.Generic.List[string]
  $i = 0; $n = $sql.Length; $start = 0
  while ($i -lt $n) {
    $ch = $sql[$i]
    if ($ch -eq '-' -and $i + 1 -lt $n -and $sql[$i + 1] -eq '-') {
      $j = $sql.IndexOf("`n", $i); if ($j -lt 0) { $i = $n } else { $i = $j + 1 }; continue
    }
    if ($ch -eq '/' -and $i + 1 -lt $n -and $sql[$i + 1] -eq '*') {
      $depth = 1; $i += 2
      while ($i -lt $n -and $depth -gt 0) {
        if ($sql[$i] -eq '/' -and $i + 1 -lt $n -and $sql[$i + 1] -eq '*') { $depth++; $i += 2 }
        elseif ($sql[$i] -eq '*' -and $i + 1 -lt $n -and $sql[$i + 1] -eq '/') { $depth--; $i += 2 }
        else { $i++ }
      }
      continue
    }
    if ($ch -eq "'") {
      if ($i -gt 0 -and "$($sql[$i - 1])" -match '^[Ee]$' -and ($i -lt 2 -or "$($sql[$i - 2])" -notmatch '^[A-Za-z0-9_]$')) {
        throw "E'...' strings are not supported here (position $i); use standard strings."
      }
      $i++
      while ($i -lt $n) {
        if ($sql[$i] -eq "'") { if ($i + 1 -lt $n -and $sql[$i + 1] -eq "'") { $i += 2; continue }; break }
        $i++
      }
      $i++; continue
    }
    if ($ch -eq '"') { $j = $sql.IndexOf('"', $i + 1); if ($j -lt 0) { throw 'Unclosed "' }; $i = $j + 1; continue }
    if ($ch -eq '$') {
      $m = [regex]::Match($sql.Substring($i, [Math]::Min(80, $n - $i)), '^\$([A-Za-z_][A-Za-z0-9_]*)?\$')
      if ($m.Success) {
        $tag = $m.Value; $j = $sql.IndexOf($tag, $i + $tag.Length)
        if ($j -lt 0) { throw "Unclosed dollar quote $tag at $i" }
        $i = $j + $tag.Length; continue
      }
    }
    if ($ch -eq ';') { $list.Add($sql.Substring($start, $i - $start + 1)); $start = $i + 1 }
    $i++
  }
  $rest = $sql.Substring($start)
  if (($rest -replace '(?s)--[^\n]*|/\*.*?\*/', '').Trim().Length -gt 0) { $list.Add($rest.TrimEnd() + ';') }
  return , $list
}

function Get-FirstWord([string] $stmt) {
  $s = $stmt -replace '(?s)^(\s|--[^\n]*(\n|$)|/\*.*?\*/)*', ''
  $m = [regex]::Match($s, '^[A-Za-z]+')
  if ($m.Success) { return $m.Value.ToUpper() }
  return ''
}

$txControl = @('BEGIN', 'COMMIT', 'END', 'ROLLBACK', 'ABORT', 'START', 'SAVEPOINT', 'RELEASE', 'PREPARE')

# Several files as ONE script for one transaction: each file's own BEGIN/COMMIT
# is left out; any other transaction statement is refused.
function Build-Script([string[]] $files) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($f in $files) {
    [void]$sb.AppendLine("-- ===== $f =====")
    [void]$sb.AppendLine('RESET search_path;')
    foreach ($st in (Get-Statements ([IO.File]::ReadAllText((Join-Path $here $f))))) {
      $w = Get-FirstWord $st
      if ($w -eq 'BEGIN' -or $w -eq 'COMMIT') { continue }
      if ($txControl -contains $w) { throw "$f has a top-level $w statement; remove it (each run is one transaction)." }
      [void]$sb.AppendLine($st.Trim())
    }
  }
  [void]$sb.AppendLine('RESET search_path;')
  return $sb.ToString()
}

function Assert-NoTxControl([string] $sql) {
  foreach ($st in (Get-Statements $sql)) {
    if ($txControl -contains (Get-FirstWord $st)) { throw 'Internal: the script has a top-level transaction statement.' }
  }
}

$backstop = 'DO $z$ BEGIN RAISE EXCEPTION ''ROLLED_BACK (nothing kept)''; END $z$;'

# ---------------------------------------------------------------------------
# check: snapshot -> move the module aside -> install from files -> compare
# ---------------------------------------------------------------------------
$snapshotFn = @'
CREATE FUNCTION pg_temp.tr_snap() RETURNS TABLE(k text, v text) LANGUAGE sql AS $snap$
  WITH rel AS (
    SELECT c.oid, n.nspname, c.relname, c.relkind, c.relispartition, c.relrowsecurity, c.relforcerowsecurity,
           c.relacl, pg_get_userbyid(c.relowner) AS owner, c.relpartbound
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r','p','v','m','f','S')
       AND (n.nspname ~ '^transport(\d{4}|_core)?$' OR (n.nspname = 'public' AND c.relname LIKE 'tr\_%'))
  )
  SELECT 'schema:' || nspname, coalesce(nspacl::text, '') || ' owner=' || pg_get_userbyid(nspowner)
    FROM pg_namespace WHERE nspname ~ '^transport(\d{4}|_core)?$'
  UNION ALL
  SELECT 'rel:' || nspname || '.' || relname,
         relkind::text || ' rls=' || relrowsecurity || '/' || relforcerowsecurity || ' acl=' || coalesce(relacl::text, '') || ' owner=' || owner
         || CASE WHEN relkind = 'p' THEN ' key=' || pg_get_partkeydef(oid) ELSE '' END
         || CASE WHEN relispartition THEN ' bound=' || pg_get_expr(relpartbound, oid) ELSE '' END
    FROM rel
  UNION ALL
  SELECT 'col:' || r.nspname || '.' || r.relname || '.' || a.attname,
         format_type(a.atttypid, a.atttypmod) || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
         || coalesce(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), '')
         || CASE a.attidentity WHEN 'a' THEN ' IDENTITY ALWAYS' WHEN 'd' THEN ' IDENTITY BY DEFAULT' ELSE '' END
         || CASE a.attgenerated WHEN 's' THEN ' GENERATED' ELSE '' END
    FROM rel r JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE r.relkind IN ('r','p','v','m','f')
  UNION ALL
  SELECT 'con:' || r.nspname || '.' || r.relname || '.' || k.conname, pg_get_constraintdef(k.oid)
    FROM rel r JOIN pg_constraint k ON k.conrelid = r.oid
  UNION ALL
  SELECT 'idx:' || r.nspname || '.' || i.relname, pg_get_indexdef(x.indexrelid)
    FROM rel r JOIN pg_index x ON x.indrelid = r.oid JOIN pg_class i ON i.oid = x.indexrelid
  UNION ALL
  SELECT 'trg:' || r.nspname || '.' || r.relname || '.' || t.tgname, pg_get_triggerdef(t.oid)
    FROM rel r JOIN pg_trigger t ON t.tgrelid = r.oid AND NOT t.tgisinternal
  UNION ALL
  SELECT 'view:' || r.nspname || '.' || r.relname, md5(pg_get_viewdef(r.oid))
    FROM rel r WHERE r.relkind IN ('v','m')
  UNION ALL
  SELECT 'pol:' || r.nspname || '.' || r.relname || '.' || p.polname,
         p.polcmd::text || ' ' || coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')
    FROM rel r JOIN pg_policy p ON p.polrelid = r.oid
  UNION ALL
  -- function text compared with whitespace squeezed (CRLF / LF does not count)
  SELECT 'fn:' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         md5(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g')) || ' acl=' || coalesce(p.proacl::text, '') || ' owner=' || pg_get_userbyid(p.proowner)
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prokind IN ('f','p') AND (n.nspname ~ '^transport(\d{4}|_core)?$' OR (n.nspname = 'public' AND p.proname LIKE 'tr\_%'))
$snap$;
CREATE TEMP TABLE _db AS SELECT * FROM pg_temp.tr_snap();
'@

$moveAside = @'
DO $hold$
DECLARE r record;
BEGIN
  CREATE SCHEMA zz_hold;
  FOR r IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport(\d{8}|\d{4}|_core)?$' LOOP
    EXECUTE format('ALTER SCHEMA %I RENAME TO %I', r.nspname, 'zz_hold_' || r.nspname);
  END LOOP;
  FOR r IN SELECT c.relname, c.relkind FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'tr\_%' AND c.relkind IN ('r','p','v','m','f') LOOP
    IF r.relkind IN ('v','m') THEN EXECUTE format('ALTER VIEW public.%I SET SCHEMA zz_hold', r.relname);
    ELSE EXECUTE format('ALTER TABLE public.%I SET SCHEMA zz_hold', r.relname); END IF;
  END LOOP;
  FOR r IN SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'tr\_%' LOOP
    EXECUTE format('ALTER FUNCTION public.%I(%s) SET SCHEMA zz_hold', r.proname, r.args);
  END LOOP;
END $hold$;
'@

# Year schemas the database has beyond the first one are started again the
# same way (transport20272028 -> '2027-2028').
$otherYears = @'
DO $yr$
DECLARE s record;
BEGIN
  FOR s IN SELECT substr(nspname, 9) AS y FROM pg_namespace
            WHERE nspname ~ '^zz_hold_transport\d{8}$' AND nspname <> 'zz_hold_transport20262027' ORDER BY nspname LOOP
    PERFORM transport_core.create_year_schema(substr(s.y, 10, 4) || '-' || substr(s.y, 14, 4));
  END LOOP;
END $yr$;
'@

$compare = @'
RESET search_path;
CREATE TEMP TABLE _files AS SELECT * FROM pg_temp.tr_snap();
DO $d$
DECLARE r jsonb;
BEGIN
  SELECT jsonb_build_object(
    'db', (SELECT count(*) FROM _db), 'files', (SELECT count(*) FROM _files),
    'only_in_db', coalesce((SELECT jsonb_agg(b.k || ' = ' || b.v ORDER BY b.k) FROM _db b
                             WHERE NOT EXISTS (SELECT 1 FROM _files a WHERE a.k = b.k)), '[]'),
    'only_in_files', coalesce((SELECT jsonb_agg(a.k || ' = ' || a.v ORDER BY a.k) FROM _files a
                                WHERE NOT EXISTS (SELECT 1 FROM _db b WHERE a.k = b.k)), '[]'),
    'different', coalesce((SELECT jsonb_agg(b.k || E'\n      database: ' || b.v || E'\n      files:    ' || a.v ORDER BY b.k)
                            FROM _db b JOIN _files a USING (k) WHERE a.v IS DISTINCT FROM b.v), '[]')) INTO r;
  RAISE EXCEPTION 'CHECK_RESULT %', r;
END $d$;
'@
# (E'' above is inside $d$ ... $d$, so the statement scanner never sees it as a string.)

# ---------------------------------------------------------------------------
switch ($Action) {
  'install' {
    $s = Get-State
    if ($s.installed) { throw 'Transport is already on this database. Use -Action update.' }
    $missing = @('session_context', 'role_can', 'institutionyear', 'feetype', 'rolemenuaccess', 'institutionusers') | Where-Object { -not $s.$_ }
    if ($missing) { throw ('Main FIT School database objects are missing: ' + ($missing -join ', ') + '. Set up the main database first.') }
    if (-not $s.logos_bucket) {
      Write-Warning 'Storage bucket InstitutionLogos is missing: staff photos and document files cannot be uploaded until it exists (same bucket and policies as the main app).'
    }
    $files = @(Get-Manifest | ForEach-Object { $_.File })
    $sql = Build-Script $files
    Assert-NoTxControl $sql
    Confirm-Target 'Install the transport module'
    Write-Host ('Installing in one transaction: ' + ($files -join ', '))
    Invoke-Sql $sql | Out-Null
    Write-Host 'Transport installed.' -ForegroundColor Green
    Write-Host 'Next: if a school works in a year other than 2026-2027, start that year:'
    Write-Host '  .\migrations\desktop\transport_db.ps1 -Action year -ProjectRef <ref> -Year 2027-2028'
  }
  'update' {
    $s = Get-State
    if (-not $s.installed) { throw 'Transport is not on this database. Use -Action install.' }
    $files = @(Get-Manifest | Where-Object { $_.Mode -eq 'always' } | ForEach-Object { $_.File })
    $sql = Build-Script $files
    Assert-NoTxControl $sql
    Confirm-Target 'Update the transport module'
    Write-Host ('Updating in one transaction: ' + ($files -join ', '))
    Invoke-Sql $sql | Out-Null
    Write-Host 'Transport updated.' -ForegroundColor Green
  }
  'check' {
    $s = Get-State
    if (-not $s.installed) { throw 'Transport is not on this database; nothing to compare.' }
    $all = @(Get-Manifest)
    $sql = 'RESET search_path;' + "`n" + $snapshotFn + $moveAside +
           (Build-Script @($all | ForEach-Object { $_.File })) +
           (Build-Script @($all | Where-Object { $_.Mode -eq 'always' } | ForEach-Object { $_.File })) +
           $otherYears + $compare + $backstop
    Assert-NoTxControl $sql
    Write-Host 'Comparing the database with a fresh install from the files (rolled back; transport calls wait a few seconds)...'
    try { Invoke-Sql $sql | Out-Null; throw 'Internal: the check did not end with its result.' }
    catch {
      $m = $_.Exception.Message
      if ($m -notmatch 'CHECK_RESULT (\{.*\})') { throw $m }
      $r = $Matches[1] | ConvertFrom-Json
    }
    $parts = @(
      @{ Name = 'Only in the database (not made by the files)'; Items = @($r.only_in_db) },
      @{ Name = 'Only made by the files (not in the database)'; Items = @($r.only_in_files) },
      @{ Name = 'Different'; Items = @($r.different) })
    Write-Host ("Objects: database {0}, files {1}" -f $r.db, $r.files)
    $bad = 0
    foreach ($p in $parts) {
      if ($p.Items.Count -eq 0) { continue }
      Write-Host ("{0}: {1}" -f $p.Name, $p.Items.Count) -ForegroundColor Yellow
      foreach ($x in $p.Items) {
        # monthly GPS partitions are data, made by a job, not by the files
        if ($x -match '\.tr_gps_ping_\d{6}') { Write-Host "  (expected) $x"; continue }
        Write-Host "  $x"; $bad++
      }
    }
    if ($bad -eq 0) { Write-Host 'No differences: the SQL files rebuild this database exactly.' -ForegroundColor Green }
    else { Write-Host "$bad difference(s): put them in the SQL files (or fix the database)." -ForegroundColor Red; exit 2 }
  }
  'test' {
    $sql = [IO.File]::ReadAllText((Join-Path $here 'transport_02_phase1_tests.sql')) + "`n" + $backstop
    try { Invoke-Sql $sql | Out-Null; $m = 'The tests did not finish.' } catch { $m = $_.Exception.Message }
    if ($m -match 'TESTS_OK') { Write-Host $m -ForegroundColor Green }
    else { Write-Host $m -ForegroundColor Red; exit 1 }
  }
  'script' {
    # The same SQL install and update send, as one file each for running by
    # hand. Each is one transaction (BEGIN ... COMMIT: all or nothing) and
    # first checks it is run on the right kind of database.
    if (-not $OutDir) { $OutDir = Join-Path $here 'single' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $all = @(Get-Manifest)
    $installed = "to_regclass('public.tr_route') IS NOT NULL OR to_regnamespace('transport20262027') IS NOT NULL OR to_regnamespace('transport2627') IS NOT NULL OR to_regnamespace('transport') IS NOT NULL"
    $jobs = @(
      [pscustomobject]@{
        Name  = 'transport_full_install.sql'
        Files = @($all | ForEach-Object { $_.File })
        What  = @(
          'Puts the transport module on a database that does not have it yet: every',
          'file of transport_install_order.txt ("once" and "always"), in order.',
          'Then, if a school works in a year other than 2026-2027, start that year:',
          "  SELECT transport_core.create_year_schema('2027-2028');")
        Guard = @"
DO `$guard`$
BEGIN
  IF $installed THEN
    RAISE EXCEPTION 'Transport is already on this database: run transport_update.sql instead. Nothing was changed.';
  END IF;
  IF to_regprocedure('public.session_context(text)') IS NULL
     OR to_regprocedure('public._role_can(integer,integer,text,text[],text)') IS NULL
     OR to_regclass('public.institutionyear') IS NULL OR to_regclass('public.feetype') IS NULL
     OR to_regclass('public.rolemenuaccess') IS NULL OR to_regclass('public.institutionusers') IS NULL THEN
    RAISE EXCEPTION 'The main FIT School database is not set up here (session_context, _role_can, institutionyear, feetype, rolemenuaccess, institutionusers). Nothing was changed.';
  END IF;
END `$guard`$;
"@
      },
      [pscustomobject]@{
        Name  = 'transport_update.sql'
        Files = @($all | Where-Object { $_.Mode -eq 'always' } | ForEach-Object { $_.File })
        What  = @(
          'Brings a database that already has the transport module up to date: the',
          '"always" files of transport_install_order.txt, in order (each is safe to',
          'run again). The "once" files are not in it: they ran at install, and a',
          'menu file (03, 09, 12, 13, 14, 17) added after a database was installed',
          'is run on that database by hand, once.')
        Guard = @"
DO `$guard`$
BEGIN
  IF NOT ($installed) THEN
    RAISE EXCEPTION 'Transport is not on this database: run transport_full_install.sql instead. Nothing was changed.';
  END IF;
END `$guard`$;
"@
      })
    foreach ($j in $jobs) {
      $body = Build-Script $j.Files
      Assert-NoTxControl $body
      $head = @(
        '-- =====================================================================',
        ('--  SCHOOL TRANSPORT - {0}' -f $j.Name),
        '--',
        ($j.What | ForEach-Object { '--  ' + $_ }),
        '--',
        '--  One transaction (BEGIN ... COMMIT): if any statement fails, nothing is kept.',
        '--  Run it in the Supabase SQL editor, or:',
        ('--    psql "<connection string>" -v ON_ERROR_STOP=1 -f {0}' -f $j.Name),
        '--',
        ('--  Made by transport_db.ps1 -Action script on {0} from:' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')),
        ($j.Files | ForEach-Object { '--    ' + $_ }),
        '--  Do not edit this file: change those files and run -Action script again.',
        '-- =====================================================================',
        '') | ForEach-Object { $_ }
      $text = ($head -join "`n") + "`nBEGIN;`n`n" + $j.Guard + "`n" + $body + "`nCOMMIT;`n"
      $path = Join-Path $OutDir $j.Name
      [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
      Write-Host ("{0}  ({1} files, {2:N0} KB)" -f $path, $j.Files.Count, ((Get-Item $path).Length / 1KB))
    }
  }
  'year' {
    if ($Year -notmatch '^\d{4}-\d{4}$') { throw 'Give -Year like 2027-2028.' }
    $s = Get-State
    if (-not $s.installed) { throw 'Transport is not on this database. Use -Action install first.' }
    Confirm-Target "Start the transport year $Year"
    $r = Invoke-Sql ("SELECT transport_core.create_year_schema('{0}') AS schema_name;" -f $Year)
    Write-Host ('Year schema ready: ' + @($r)[0].schema_name) -ForegroundColor Green
  }
}
