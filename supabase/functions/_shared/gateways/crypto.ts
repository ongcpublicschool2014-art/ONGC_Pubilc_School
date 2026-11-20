// Small crypto helpers (Web Crypto, available in Deno Edge Functions).

const enc = new TextEncoder();

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function b64(buf: ArrayBuffer): string {
  let s = "";
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b);
  return btoa(s);
}

export async function sha256Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", enc.encode(text)));
}

export async function sha512Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-512", enc.encode(text)));
}

async function hmac(key: string, text: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(text));
}

export async function hmacSha256Hex(key: string, text: string): Promise<string> {
  return hex(await hmac(key, text));
}

export async function hmacSha256B64(key: string, text: string): Promise<string> {
  return b64(await hmac(key, text));
}

/// Constant-time-ish string compare (lengths differ -> false).
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
