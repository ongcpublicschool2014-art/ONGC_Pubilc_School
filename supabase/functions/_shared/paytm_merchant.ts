// Resolve a Paytm merchant (MID + secret key) for a request.
//
// Secrets live server-side only. Two env layouts are supported:
//   * PAYTM_MID + PAYTM_MERCHANT_KEY        — the single default merchant.
//   * PAYTM_MERCHANTS (JSON)                — multi-merchant routing, a map of
//       { "<mid>": "<merchantKey>", ... }   so each IOBPAY entity (KCET,
//       Hostel, Arts&Science, Polytechnic) settles to its own bank account.
//
// Resolution given an optional requested `mid` (from the fee group's bank):
//   - mid in PAYTM_MERCHANTS            -> that mid + its key
//   - mid === PAYTM_MID                 -> default key
//   - mid given, PAYTM_SUBMERCHANT_MODE -> that (sub) mid + the PARENT key
//                                          (aggregator: sub MIDs share one key)
//   - no mid                            -> default merchant
//   - mid given but unknown            -> throws (don't silently mis-route money)

export interface PaytmMerchant {
  mid: string;
  key: string;
  website: string;
  host: string;
}

export function resolveMerchant(requestedMid?: string | null): PaytmMerchant {
  const website = Deno.env.get("PAYTM_WEBSITE") ?? "WEBSTAGING";
  const host = Deno.env.get("PAYTM_HOST") ??
    "https://securestage.paytmpayments.com";

  const defaultMid = Deno.env.get("PAYTM_MID") ?? "";
  const defaultKey = Deno.env.get("PAYTM_MERCHANT_KEY") ?? "";

  // Aggregator / sub-merchant mode: sub MIDs are linked under the parent and
  // have NO own key, so a transaction runs under the requested sub MID but is
  // signed with the PARENT (default) key. Gated by env so an unknown MID is
  // never silently signed unless this is deliberately enabled.
  const subMerchantMode = Deno.env.get("PAYTM_SUBMERCHANT_MODE") === "true";

  let merchants: Record<string, string> = {};
  const raw = Deno.env.get("PAYTM_MERCHANTS");
  if (raw) {
    try {
      merchants = JSON.parse(raw) as Record<string, string>;
    } catch (_) {
      throw new Error("PAYTM_MERCHANTS is not valid JSON");
    }
  }

  const mid = (requestedMid && String(requestedMid).trim()) || "";

  if (mid) {
    if (merchants[mid]) return { mid, key: merchants[mid], website, host };
    if (mid === defaultMid && defaultKey) {
      return { mid, key: defaultKey, website, host };
    }
    // Sub MID linked under the parent — sign with the parent key.
    if (subMerchantMode && defaultKey) {
      return { mid, key: defaultKey, website, host };
    }
    throw new Error(`No merchant key configured for MID ${mid}`);
  }

  if (!defaultMid || !defaultKey) {
    throw new Error("Payment gateway not configured");
  }
  return { mid: defaultMid, key: defaultKey, website, host };
}
