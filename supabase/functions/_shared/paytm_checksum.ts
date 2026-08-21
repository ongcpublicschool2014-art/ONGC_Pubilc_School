// Paytm checksum (signature) helper for Deno edge functions.
//
// Port of the official PaytmChecksum library's generate/verify routines.
// Algorithm:
//   1. salt = 4 random alphanumeric chars
//   2. hash = SHA256(params + "|" + salt)  (hex)
//   3. finalString = hash + salt
//   4. checksum = base64( AES-128-CBC encrypt(finalString) ) with the
//      merchant key as the AES key and the fixed IV below.
//
// Verify decrypts the checksum, splits off the trailing 4-char salt, and
// re-hashes to confirm. The merchant key must be 16 chars (AES-128).
//
// Ref: https://www.paytmpayments.com/docs/checksum

const IV = "@@@@&&&&####$$$$"; // fixed 16-byte IV used by PaytmChecksum
const SALT_CHARS =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function fromBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function randomSalt(length = 4): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let s = "";
  for (const b of bytes) s += SALT_CHARS[b % SALT_CHARS.length];
  return s;
}

async function importKey(key: string): Promise<CryptoKey> {
  // AES-128-CBC requires a 16-byte key. Paytm merchant keys are 16 chars.
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(key),
    { name: "AES-CBC" },
    false,
    ["encrypt", "decrypt"],
  );
}

/// Generate a Paytm signature over `params` (usually JSON.stringify(body)).
export async function generateSignature(
  params: string,
  key: string,
): Promise<string> {
  const salt = randomSalt(4);
  const hash = await sha256Hex(params + "|" + salt);
  const finalString = hash + salt;
  const cryptoKey = await importKey(key);
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-CBC", iv: encoder.encode(IV) },
    cryptoKey,
    encoder.encode(finalString),
  );
  return toBase64(new Uint8Array(encrypted));
}

/// Verify a Paytm signature (e.g. on webhook/callback payloads).
export async function verifySignature(
  params: string,
  key: string,
  checksum: string,
): Promise<boolean> {
  try {
    const cryptoKey = await importKey(key);
    const decrypted = await crypto.subtle.decrypt(
      { name: "AES-CBC", iv: encoder.encode(IV) },
      cryptoKey,
      fromBase64(checksum),
    );
    const decryptedStr = decoder.decode(decrypted);
    const salt = decryptedStr.slice(-4);
    const hash = decryptedStr.slice(0, -4);
    const expected = await sha256Hex(params + "|" + salt);
    return hash === expected;
  } catch (_) {
    return false;
  }
}
