// Send a 6-digit OTP to verify the mobile number during first-run
// super-admin registration. There is no institutionusers row yet, so
// the OTP is stored in public.superadmin_reg_otp (keyed by the 10-digit
// mobile). register_super_admin() later verifies the typed OTP against
// that row before creating the account.
//
// Uses a direct Postgres connection (SUPABASE_DB_URL) — same reasoning
// as send-password-reset-otp.
//
// Configure secrets in Supabase dashboard → Edge Functions → Secrets:
//   BULKSMS_USER, BULKSMS_PASSWORD, BULKSMS_SENDER, BULKSMS_TEMPLATE_ID
//   SUPABASE_DB_URL  — auto-injected by the platform
//
// Deploy:
//   supabase functions deploy send-superadmin-otp

import { Pool } from 'https://deno.land/x/postgres@v0.19.3/mod.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function maskPhone(phone: string): string {
  const digits = phone.replace(/\D/g, '')
  if (digits.length < 4) return '****'
  return '*'.repeat(digits.length - 4) + digits.slice(-4)
}

function cleanMobile(raw: string): string {
  const digits = raw.replace(/\D/g, '')
  return digits.length > 10 ? digits.slice(-10) : digits
}

const dbUrl = Deno.env.get('SUPABASE_DB_URL') ?? Deno.env.get('DB_URL')
const pool = dbUrl ? new Pool(dbUrl, 1, true) : null

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { mobile } = await req.json()
    const phone = cleanMobile(String(mobile ?? ''))
    if (phone.length !== 10) {
      return new Response(JSON.stringify({ error: 'A valid 10-digit mobile is required' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (!pool) {
      return new Response(JSON.stringify({
        error: 'database connection not configured',
        hint: 'Set SUPABASE_DB_URL (or DB_URL) as an Edge Function secret',
      }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const conn = await pool.connect()
    try {
      // Refuse if a super admin already exists — registration is closed.
      const exists = await conn.queryObject<{ e: boolean }>(
        `SELECT EXISTS (SELECT 1 FROM public.institutionusers
                         WHERE inscode = 'SUPER' AND activestatus = 1) AS e`,
      )
      if (exists.rows[0]?.e) {
        return new Response(JSON.stringify({ error: 'A super admin already exists' }), {
          status: 409,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      const otp = Math.floor(100000 + Math.random() * 900000)

      // Upsert the pending OTP, resetting attempts + timestamp.
      await conn.queryObject(
        `INSERT INTO public.superadmin_reg_otp (mobile, otp, created_at, attempts)
         VALUES ($1, $2, now(), 0)
         ON CONFLICT (mobile) DO UPDATE
           SET otp = EXCLUDED.otp, created_at = now(), attempts = 0`,
        [phone, otp],
      )

      // DLT-approved template — text must match BULKSMS_TEMPLATE_ID exactly.
      const message = `Thanks for Choosing EduCore360. OTP for Login User Account creation is: ${otp}.`
      const url = new URL('http://api.bulksmsgateway.in/sendmessage.php')
      url.searchParams.set('user', Deno.env.get('BULKSMS_USER') ?? '')
      url.searchParams.set('password', Deno.env.get('BULKSMS_PASSWORD') ?? '')
      url.searchParams.set('mobile', phone)
      url.searchParams.set('message', message)
      url.searchParams.set('sender', Deno.env.get('BULKSMS_SENDER') ?? 'TBSTEC')
      url.searchParams.set('type', '3')
      url.searchParams.set('template_id', Deno.env.get('BULKSMS_TEMPLATE_ID') ?? '')

      const smsRes = await fetch(url.toString())
      const smsBody = await smsRes.text()
      const looksOk =
        smsRes.status === 200 &&
        (/^\d+$/.test(smsBody.trim()) || /success|sent/i.test(smsBody))
      if (!looksOk) {
        return new Response(
          JSON.stringify({ error: 'SMS gateway rejected', detail: smsBody.slice(0, 200) }),
          { status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
        )
      }

      return new Response(
        JSON.stringify({ ok: true, masked: maskPhone(phone) }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    } finally {
      conn.release()
    }
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
