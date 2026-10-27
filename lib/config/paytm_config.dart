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

  /// PRODUCTION unless a config.json says otherwise.
  ///
  /// Deliberately NOT a hand-edited constant. Editing a committed `= false`
  /// back and forth to test is how a staging build ships: the flag is invisible
  /// in the exe and nobody remembers it at release time. Instead the same
  /// untracked config.json that already points a machine at the TEST database
  /// opts in, with "paytmStaging": true, and SupabaseConfig.load() sets this.
  /// A production install has no such file, so it cannot be switched.
  static bool isProduction = true;

  /// Paytm Split Settlement (per-unit banking). When true, each payment's funds
  /// are settled to the paying institution's CHILD MID (the value resolved from
  /// bank.paytm_mid) via `splitSettlementInfo`, while the order itself is still
  /// created under the single parent/default API MID. When false, the resolved
  /// MID is used directly as the order MID (single-account flow — today's live
  /// behaviour). Keep this false until Paytm has (a) enabled Split Settlement on
  /// the parent MID and (b) onboarded the four unit MIDs as child accounts with
  /// their banks registered — otherwise initiateTransaction rejects the split.
  static const bool splitSettlement = false;

  // Per-unit settlement via INDEPENDENT merchant IDs is the live model, and it
  // is no longer a flag. SupabaseService.resolvePaytmRouting resolves the
  // paying institution's own merchant from public.paytm_configuration, and
  // refuses the payment when it cannot — never falling back to the default
  // parent merchant, which is how money silently reached the parent account
  // after a database rebuild.
  //
  // Routing by FEE GROUP (a group naming a bank, the bank naming a merchant)
  // was built and reverted: one Paytm order settles to exactly one merchant, so
  // a student paying tuition and hostel fees together could not be collected in
  // one transaction — the normal case at the counter.
  //
  // This is NOT Paytm "split settlement" and NOT the parent-key aggregator.
  // Requires the edge functions (create-paytm-order, get-paytm-payment) to have
  // PAYTM_MERCHANTS set to {"<mid>":"<key>", ...} — a routed MID with no key
  // entry is rejected server-side rather than silently mis-settled.

  // ---- Merchant id -------------------------------------------------------

  /// There is deliberately NO default MID here.
  ///
  /// A merchant id is not secret, but it identifies ONE institution, and this
  /// binary is installed at several. Compiled in, it is a default that cannot
  /// be seen from the outside and cannot be changed without a release.
  ///
  /// The MID comes from the database instead, resolved per collection by
  /// SupabaseService.resolvePaytmRouting:
  ///     bank.paytm_mid            (the fee group's own account)  ->  else
  ///     public.paytm_configuration.merchant_id  (the institution)  ->  else
  ///     REFUSE the payment
  /// Refusing is the correct third branch. Falling back to whichever merchant
  /// happened to be in the build would settle one institution's money into
  /// another's account with nothing on the receipt to show it.
  ///
  /// See docs/PAYTM_WORKFLOW.md.

  // websiteName lives server-side only: resolveMerchant() reads PAYTM_WEBSITE
  // in the edge functions, and nothing in the client ever used the copy that
  // was here. Two places to keep in sync was one too many.

  // ---- Gateway hosts -----------------------------------------------------

  /// Base host for the JS Checkout SDK script and the checkout UI.
  /// Per Paytm's JS Checkout docs the PRODUCTION host is secure.paytmpayments.com
  /// (NOT securegw.* — securegw returns 404 "Not Found" on initiateTransaction).
  /// Staging is securestage.paytmpayments.com. The edge function's PAYTM_HOST env
  /// must match: https://secure.paytmpayments.com for production.
  static String get host => isProduction
      ? 'https://secure.paytmpayments.com'
      : 'https://securestage.paytmpayments.com';

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
