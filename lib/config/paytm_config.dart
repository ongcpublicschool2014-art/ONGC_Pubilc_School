/// Paytm Payment Gateway configuration (JS Checkout).
///
/// IMPORTANT: This file holds only NON-SECRET values. The merchant API key
/// (used to sign requests via the Paytm checksum) must NEVER live in the
/// client. It is set as the `PAYTM_MERCHANT_KEY` env var on the Supabase
/// edge functions (`create-paytm-order`, `get-paytm-payment`), exactly the
/// way `RAZORPAY_KEY_SECRET` is kept server-side for the Razorpay flow.
///
/// The MID and websiteName are not secret — the MID is embedded in the
/// JS Checkout SDK URL that the browser loads, so it is safe here.
///
/// Credentials source: Paytm Payments onboarding mail to
/// "SRI KRISHNASAMY REDDIAR EDUCATIONAL TRUST" (staging). The secret API key
/// from that mail is NOT stored here — it is the `PAYTM_MERCHANT_KEY` env var on
/// the edge functions. These are STAGING/TEST credentials. Production values are
/// filled in only after go-live (3 successful test txns submitted to Paytm).
class PaytmConfig {
  PaytmConfig._();

  /// Flip to true once production credentials are issued and verified.
  /// Keep false for the staging/test environment.
  static const bool isProduction = true;

  /// Paytm Split Settlement (per-unit banking). When true, each payment's funds
  /// are settled to the paying institution's CHILD MID (the value resolved from
  /// bank.paytm_mid) via `splitSettlementInfo`, while the order itself is still
  /// created under the single parent/default API MID. When false, the resolved
  /// MID is used directly as the order MID (single-account flow — today's live
  /// behaviour). Keep this false until Paytm has (a) enabled Split Settlement on
  /// the parent MID and (b) onboarded the four unit MIDs as child accounts with
  /// their banks registered — otherwise initiateTransaction rejects the split.
  static const bool splitSettlement = false;

  /// Per-unit settlement via INDEPENDENT merchant IDs (the live model).
  /// When true, each payment is created under the paying institution's OWN Paytm
  /// MID (resolved from public.paytm_configuration via
  /// SupabaseService.getPaytmMidForInstitution) and signed server-side with THAT
  /// MID's OWN merchant key (from the edge function's PAYTM_MERCHANTS map), so
  /// Paytm settles the funds directly to that unit's registered bank account.
  ///
  /// This is NOT Paytm "split settlement" and NOT the parent-key aggregator: each
  /// of the four unit MIDs is a full independent merchant with its own API key
  /// (verified working against production, resultCode 0000). Requires the edge
  /// functions (create-paytm-order, get-paytm-payment) to have PAYTM_MERCHANTS
  /// set to {"<mid>":"<key>", ...} for the four units — otherwise a routed MID
  /// with no key entry is rejected server-side. An institution with no config row
  /// falls back to the default MID. Mutually exclusive with [splitSettlement].
  static const bool perUnitSettlement = true;

  // ---- Merchant IDs (non-secret) ----------------------------------------

  /// Staging/Test MID. Two sets exist for this trust and only one is accepted
  /// by the staging gateway — the onboarding-mail pair (MID below +
  /// key f%FzIB&4t%GRo9m7 + WEBSTAGING) arrived matched, so try it first. The
  /// dashboard "Test API Details" pair (Krishn06051431858637 / JtHK6ipYjpm_cuuE)
  /// was rejected with resultCode 501. The edge function's PAYTM_MID env is what
  /// actually signs — keep this in sync with it.
  static const String stagingMid = 'iZngSb05004504656177';

  /// Production DEFAULT/fallback MID. Krishn06051431858637 (key JtHK6ipYjpm_cuuE,
  /// website DEFAULT, host secure.paytmpayments.com) is used only when an
  /// institution has no active row in public.paytm_configuration.
  ///
  /// The four units are INDEPENDENT production merchants, each with its OWN API
  /// key (verified working, resultCode 0000). Routing is per-institution via
  /// public.paytm_configuration; each MID's key lives in the edge function's
  /// PAYTM_MERCHANTS map (never in this client):
  ///   College (KCET) ins 1   Krishn36335928406501
  ///   Polytechnic    ins 2   Krishn15569334364496
  ///   Arts & Science ins 3   Krishn02645517368198
  ///   Mens Hostel    ins 4   Krishn33556941260773
  static const String productionMid = 'Krishn06051431858637';

  /// Active MID for the selected environment.
  static String get mid => isProduction ? productionMid : stagingMid;

  // ---- websiteName (non-secret) -----------------------------------------

  /// The `websiteName` parameter Paytm requires when initiating a transaction.
  /// On the STAGING gateway (securestage) this must be 'WEBSTAGING' — the
  /// dashboard's "Website: DEFAULT" is the *production* site name and is rejected
  /// on staging (Paytm returns resultCode 501). The edge function actually reads
  /// this from its PAYTM_WEBSITE env var; keep the two in sync.
  static const String stagingWebsiteName = 'WEBSTAGING';

  /// Production websiteName — 'DEFAULT' per the Paytm dashboard for these
  /// merchants (verify with Paytm; production uses the merchant's real site name,
  /// not WEBSTAGING). Edge function's PAYTM_WEBSITE env must match.
  static const String productionWebsiteName = 'DEFAULT';

  /// Active websiteName for the selected environment.
  static String get websiteName => isProduction ? productionWebsiteName : stagingWebsiteName;

  // ---- Gateway hosts -----------------------------------------------------

  /// Base host for the JS Checkout SDK script and the checkout UI.
  /// Per Paytm's JS Checkout docs the PRODUCTION host is secure.paytmpayments.com
  /// (NOT securegw.* — securegw returns 404 "Not Found" on initiateTransaction).
  /// Staging is securestage.paytmpayments.com. The edge function's PAYTM_HOST env
  /// must match: https://secure.paytmpayments.com for production.
  static String get host => isProduction
      ? 'https://secure.paytmpayments.com'
      : 'https://securestage.paytmpayments.com';

  /// Full URL of the merchant-specific JS Checkout SDK for the default MID.
  /// Format: {host}/merchantpgpui/checkoutjs/merchants/{MID}.js
  static String get checkoutJsUrl => checkoutJsUrlFor(mid);

  /// JS Checkout SDK URL for an explicit MID (per-fee-group / per-bank routing).
  static String checkoutJsUrlFor(String forMid) =>
      '$host/merchantpgpui/checkoutjs/merchants/$forMid.js';

  /// Hosts the checkout WebView is allowed to navigate to (defence in depth,
  /// mirrors the Razorpay allowlist). Used by the checkout dialog.
  static Set<String> get allowedHosts => {
        Uri.parse(host).host,
        'securestage.paytmpayments.com',
        'secure.paytmpayments.com',
        'securegw.paytmpayments.com',
      };
}
