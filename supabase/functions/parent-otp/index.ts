// parent-otp -- sends the parent app's sign-up / forgot-password OTP.
// POST { mobile } -> { status: SENT | NOT_FOUND | WAIT | LIMIT | NOT_SET | FAILED | ERROR }.
// The OTP and the SMS account stay on the server (parent_otp_issue).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Issue = {
  status: string;
  wait_seconds?: number;
  otp?: string;
  to?: string;
  sms?: { user: string; password: string; sender: string; template: string };
};

async function sendSms(i: Issue): Promise<boolean> {
  const params: Record<string, string> = {
    user: i.sms!.user,
    password: i.sms!.password,
    mobile: i.to!,
    // The approved DLT template: do not reword.
    message: `Thanks for Choosing FIT School. OTP for Login User Account creation is: ${i.otp}.`,
    sender: i.sms!.sender,
    type: "3",
    template_id: i.sms!.template,
  };
  const query = Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
  const res = await fetch(`https://api.bulksmsgateway.in/sendmessage.php?${query}`, {
    signal: AbortSignal.timeout(10000),
  });
  const body = (await res.text()).trim();
  return res.ok && (/success|sent/i.test(body) || /^\d+$/.test(body));
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let mobile = "";
  try {
    mobile = String((await req.json()).mobile ?? "");
    const { data, error } = await db.rpc("parent_otp_issue", { p_mobile: mobile });
    if (error) throw new Error(error.message);
    const issue = data as Issue;
    if (issue.status !== "READY") {
      return json({ status: issue.status, wait_seconds: issue.wait_seconds });
    }
    let sent = false;
    try {
      sent = await sendSms(issue);
    } catch (_) {
      sent = false;
    }
    if (!sent) {
      await db.rpc("parent_otp_cancel", { p_mobile: mobile });
      return json({ status: "FAILED" });
    }
    return json({ status: "SENT" });
  } catch (e) {
    console.error("parent-otp:", (e as Error).message);
    return json({ status: "ERROR" }, 500);
  }
});
