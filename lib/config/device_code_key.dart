/// Shared AES-256 key for decrypting the device-code JSON that the
/// `request-device-code` Edge Function emails to the office.
///
/// This value MUST exactly match the `DEVICE_CODE_ENC_KEY` secret set on
/// the Supabase Edge Function — both sides use the same key.
///
/// Generate a fresh key once with:
///   openssl rand -base64 32
/// Paste the same string here AND into the Supabase secret.
///
/// Note: a key compiled into a desktop binary can be extracted by a
/// determined attacker. This protects the email/file from casual
/// reading; it is not unbreakable. The activation code it wraps is
/// already single-use and device-bound.
class DeviceCodeKey {
  DeviceCodeKey._();

  /// Base64-encoded 32-byte (AES-256) key. Must match the
  /// DEVICE_CODE_ENC_KEY secret on the Supabase Edge Function.
  ///
  /// Deliberately chosen to contain no '+' or '/': a '+' pasted into a
  /// URL-encoded form field arrives as a space, and atob() then fails with
  /// "Failed to decode base64" on the server side. Re-generate the same way
  /// if it ever needs rotating.
  static const String base64Key = 'ltKE0h13PztSLERUzl5E7TI8zSUETg0WPNtT2XJb6oU=';

  /// True once a real key has been pasted in (not the placeholder).
  static bool get isConfigured => base64Key != 'REPLACE_WITH_BASE64_32BYTE_KEY';
}
