# =====================================================================
#  Restore a live dump INTO the TEST project.
#
#  Usage (PowerShell, from anywhere):
#      $env:PGPASSWORD = '<TEST database password>'
#      .\tools\restore_live_to_test.ps1 -Dump 'E:\COLLEGE MANAGEMENT\DB\FULL_LIVE_20261005_1014.dump'
#
#  WHAT IT DOES, and why each bit is there -- every one of these was learned
#  the hard way on 21 Sep and 1 Oct 2026:
#
#   * Backs TEST up first. The restore is --clean: it drops before it creates.
#
#   * Builds a filtered TOC. Two classes of line must come out:
#       - SCHEMA / COMMENT / ACL for `public` and the tenant schema. `public`
#         on Supabase is owned by pg_database_owner, so dropping and recreating
#         it fails and takes the whole transaction with it.
#       - DEFAULT ACL ... supabase_admin. postgres cannot change those default
#         privileges ("permission denied"), and TEST already has them.
#
#   * KEEPS privileges otherwise (no --no-privileges). The app depends on the
#     REVOKEs against anon -- drop them and a client can write money tables.
#
#   * --single-transaction --exit-on-error, so a partial restore is impossible.
#
#  AFTERWARDS YOU MUST RUN  tools/restore_test_repair.sql  ON TEST.
#  pg_restore silently leaves behind: schema GRANTS, column DEFAULTS, every
#  TRIGGER (all the primary keys are trigger-generated) and every FOREIGN KEY
#  (PostgREST resolves embedded selects from them). Skipping it looks like a
#  broken app, not a broken restore.
#
#  It also restores the TEST marker, so `SELECT public.db_env()` answers again.
# =====================================================================
param(
  [Parameter(Mandatory = $true)][string]$Dump,
  [string]$PgBin   = 'C:\Program Files\PostgreSQL\17\bin',
  [string]$DbHost  = 'aws-0-ap-northeast-2.pooler.supabase.com',
  [int]   $Port    = 5432,
  [string]$DbUser  = 'postgres.lyzmuwmqpqjqwbykfwzl',
  [string]$DbName  = 'postgres',
  [string]$Schema  = 'kcet20262027',
  [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

# A password is needed, but it may come from %APPDATA%\postgresql\pgpass.conf
# rather than the environment -- that file is the safer place for it.
if (-not $env:PGPASSWORD -and -not (Test-Path "$env:APPDATA\postgresql\pgpass.conf")) {
  throw 'No credentials: set $env:PGPASSWORD or add the TEST entry to pgpass.conf.'
}
if (-not (Test-Path $Dump)) { throw "Dump not found: $Dump" }

$restore = Join-Path $PgBin 'pg_restore.exe'
$dumpexe = Join-Path $PgBin 'pg_dump.exe'
foreach ($e in @($restore, $dumpexe)) { if (-not (Test-Path $e)) { throw "Not found: $e" } }

$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$work  = Join-Path $env:TEMP "restore_$stamp"
New-Item -ItemType Directory -Path $work -Force | Out-Null

# --- 1. back TEST up -------------------------------------------------------
if (-not $SkipBackup) {
  $before = "C:\pg_backups\TEST_before_restore_$stamp.dump"
  Write-Host "Backing up TEST -> $before"
  & $dumpexe -h $DbHost -p $Port -U $DbUser -d $DbName `
      --schema=public --schema=$Schema -Fc -f $before
  if ($LASTEXITCODE -ne 0) { throw "TEST backup failed ($LASTEXITCODE) - stopping before any change." }
  Write-Host "  ok"
}

# --- 1b. drop the tenant schema's FOREIGN KEYS ------------------------------
#
# --clean drops each constraint before recreating it, and a FOREIGN KEY holds a
# dependency on the PRIMARY KEY index it references:
#
#   cannot drop constraint advance_collection_pkey ... because other objects
#   depend on it: constraint advance_detail_adv_id_fkey depends on index ...
#
# So the restore cannot proceed while they exist. They are not lost: these are
# the same keys restore_test_repair.sql recreates afterwards -- pg_restore never
# carries them over anyway, which is why that script exists.
#
# Generic rather than by name, so a key added later is covered.
$psql = Join-Path $PgBin 'psql.exe'
if (-not (Test-Path $psql)) { throw "Not found: $psql" }
Write-Host "Dropping foreign keys in $Schema (restore_test_repair.sql puts them back)..."
$dropFks = @"
DO `$fk`$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT conrelid::regclass AS tbl, conname
             FROM pg_constraint c
             JOIN pg_namespace n2 ON n2.oid = c.connamespace
            WHERE c.contype = 'f' AND n2.nspname = '$Schema'
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'dropped % foreign key(s)', n;
END `$fk`$;
"@
$dropFks | & $psql -h $DbHost -p $Port -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -f -
if ($LASTEXITCODE -ne 0) { throw "Could not drop foreign keys ($LASTEXITCODE) - stopping." }

# --- 1c. drop nextval() COLUMN DEFAULTS ------------------------------------
#
# The same shape of problem one level down: --clean drops each sequence, and a
# column default of nextval('<seq>') depends on it:
#
#   cannot drop sequence tempfeedemand_temp_id_seq ... default value for column
#   temp_id ... depends on sequence ...
#
# Only nextval defaults are touched -- those are the ones holding a dependency.
# restore_test_repair.sql puts them back; pg_restore does not carry them over
# either, which is the "integer PKs lose their default" case in its header.
Write-Host "Dropping nextval() column defaults in $Schema (restore_test_repair.sql puts them back)..."
$dropDefs = @"
DO `$d`$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT c.relname AS tbl, a.attname AS col
             FROM pg_attrdef ad
             JOIN pg_class c ON c.oid = ad.adrelid
             JOIN pg_namespace ns ON ns.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ad.adnum
            WHERE ns.nspname = '$Schema'
              AND pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval%'
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I DROP DEFAULT', '$Schema', r.tbl, r.col);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'dropped % column default(s)', n;
END `$d`$;
"@
$dropDefs | & $psql -h $DbHost -p $Port -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -f -
if ($LASTEXITCODE -ne 0) { throw "Could not drop column defaults ($LASTEXITCODE) - stopping." }

# --- 2. filtered TOC -------------------------------------------------------
$tocRaw = Join-Path $work 'toc.txt'
& $restore -l $Dump | Out-File -FilePath $tocRaw -Encoding ascii
if ($LASTEXITCODE -ne 0) { throw "pg_restore -l failed ($LASTEXITCODE)" }

$drop = @(
  "SCHEMA - public",
  "SCHEMA - $Schema",
  "COMMENT - SCHEMA public",
  "ACL - SCHEMA public",
  "ACL - SCHEMA $Schema"
)
$toc = Join-Path $work 'toc.filtered.txt'
$kept = 0; $removed = 0
Get-Content $tocRaw | ForEach-Object {
  $line = $_
  $skip = $false
  foreach ($d in $drop) { if ($line -match [regex]::Escape($d)) { $skip = $true } }
  if ($line -match 'DEFAULT ACL' -and $line -match 'supabase_admin') { $skip = $true }
  if ($skip) { $removed++ } else { $kept++; $line }
} | Out-File -FilePath $toc -Encoding ascii

Write-Host "TOC: kept $kept, removed $removed"

# --- 3. restore ------------------------------------------------------------
Write-Host 'Restoring (single transaction, aborts on first error)...'
$env:PGOPTIONS = '-c statement_timeout=0'
& $restore -h $DbHost -p $Port -U $DbUser -d $DbName `
    --clean --if-exists --no-owner --single-transaction --exit-on-error `
    -L $toc $Dump
if ($LASTEXITCODE -ne 0) { throw "RESTORE FAILED ($LASTEXITCODE). TEST is unchanged - the whole thing was one transaction." }

Write-Host ''
Write-Host 'Restore finished.'
Write-Host ''
Write-Host 'NOW RUN ON TEST, or the app will look broken:'
Write-Host '    C:\Users\User7\Desktop\KCET\tools\restore_test_repair.sql'
Write-Host ''
Write-Host 'It puts back the schema grants, the column defaults, every trigger'
Write-Host 'and every foreign key - none of which pg_restore carries over - and'
Write-Host 'recreates the TEST marker so SELECT public.db_env() answers again.'
