#!/usr/bin/env bash
# Regenerates supabase/functions/_dashboard_bundles/paytm-webhook.index.ts
# from the real source, inlining the two _shared modules so the whole
# function is one pasteable file for the dashboard editor.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=supabase/functions/paytm-webhook/index.ts
OUT=supabase/functions/_dashboard_bundles/paytm-webhook.index.ts

strip() { sed -e '/^import /d' -e 's/^export //' "$1"; }

{
  sed -n '1,17p' supabase/functions/_dashboard_bundles/.bundle_header.txt
  echo
  sed -n '52,53p' "$SRC"
  echo
  echo '// --- inlined from _shared/paytm_checksum.ts --------------------------------'
  echo
  strip supabase/functions/_shared/paytm_checksum.ts
  echo
  echo '// --- inlined from _shared/paytm_merchant.ts --------------------------------'
  echo
  strip supabase/functions/_shared/paytm_merchant.ts
  echo
  echo '// --- the function itself, from paytm-webhook/index.ts ----------------------'
  echo
  sed -e '/^import /d' "$SRC"
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines)"
