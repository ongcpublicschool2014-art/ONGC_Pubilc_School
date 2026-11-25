// GPS position formats the gps-ingest function accepts (2026-11-20).
// Pure code (no Deno APIs) so it can be tested with plain Node.
//
//  1. URL / form parameters -- the OsmAnd protocol of Traccar Client and of
//     many tracker platforms' "HTTP push":
//       id | deviceid | imei | uniqueId, lat | latitude, lon | lng | longitude,
//       timestamp (Unix seconds or ms, or ISO), speed (KNOTS, as OsmAnd) or
//       speed_kmph, bearing | heading | course, altitude, accuracy,
//       batt | battery (0-100), ignition, sat | satellites.
//  2. Traccar "position forwarding" JSON:
//       {"position": {"latitude", "longitude", "fixTime", "speed" (knots),
//        "course", "altitude", "accuracy", "attributes": {"ignition",
//        "batteryLevel", "sat"}}, "device": {"uniqueId"}}
//  3. Traccar Client JSON: {"device_id", "location": {"timestamp",
//       "coords": {"latitude", "longitude", "speed" (m/s), "heading",
//       "altitude", "accuracy"}, "battery": {"level" (0-1)}}}
//  4. Simple JSON, one object or a list:
//       {"imei", "lat", "lon", "time" | "at" | "timestamp", "speed_kmph" (or
//        "speed" in km/h), "heading", "altitude", "accuracy", "battery",
//        "ignition", "satellites"}
// The access key comes from ?key=, the x-gps-key header or a "key" field.

export interface GpsPosition {
  imei: string;
  lat: number;
  lon: number;
  at?: string; // ISO time; the server uses "now" when missing
  speed_kmph?: number;
  heading?: number;
  altitude_m?: number;
  accuracy_m?: number;
  battery_pct?: number;
  ignition?: boolean;
  satellites?: number;
  raw?: unknown;
}

export interface ParsedRequest {
  key: string | null;
  positions: GpsPosition[];
}

const KNOT_KMH = 1.852;
const MPS_KMH = 3.6;

type Bag = Record<string, unknown>;

function num(v: unknown): number | undefined {
  if (v === null || v === undefined || v === "") return undefined;
  const n = typeof v === "number" ? v : Number(String(v).trim());
  return Number.isFinite(n) ? n : undefined;
}

function bool(v: unknown): boolean | undefined {
  if (v === null || v === undefined || v === "") return undefined;
  if (typeof v === "boolean") return v;
  const s = String(v).trim().toLowerCase();
  if (["1", "true", "on", "yes"].includes(s)) return true;
  if (["0", "false", "off", "no"].includes(s)) return false;
  return undefined;
}

function str(v: unknown): string {
  return v === null || v === undefined ? "" : String(v).trim();
}

/** Unix seconds, Unix milliseconds or an ISO date -> ISO; undefined when unreadable. */
export function toIso(v: unknown): string | undefined {
  if (v === null || v === undefined || v === "") return undefined;
  const s = String(v).trim();
  if (/^\d+(\.\d+)?$/.test(s)) {
    const n = Number(s);
    const ms = n > 1e12 ? n : n * 1000; // milliseconds when it is that large
    const d = new Date(ms);
    return isNaN(d.getTime()) ? undefined : d.toISOString();
  }
  const d = new Date(s);
  return isNaN(d.getTime()) ? undefined : d.toISOString();
}

function pick(b: Bag, ...names: string[]): unknown {
  for (const n of names) {
    if (b[n] !== undefined && b[n] !== null && b[n] !== "") return b[n];
  }
  return undefined;
}

function clean(p: GpsPosition): GpsPosition {
  const out: GpsPosition = { imei: p.imei, lat: p.lat, lon: p.lon };
  for (const k of ["at", "speed_kmph", "heading", "altitude_m", "accuracy_m", "battery_pct", "ignition", "satellites", "raw"] as const) {
    if (p[k] !== undefined) (out as unknown as Bag)[k] = p[k];
  }
  return out;
}

/** Format 1: flat parameters (query string or form body). */
export function fromParams(b: Bag): GpsPosition | null {
  const imei = str(pick(b, "id", "deviceid", "device_id", "imei", "uniqueId", "uniqueid"));
  const lat = num(pick(b, "lat", "latitude"));
  const lon = num(pick(b, "lon", "lng", "long", "longitude"));
  if (!imei || lat === undefined || lon === undefined) return null;
  const kmh = num(pick(b, "speed_kmph", "kmph", "speed_kmh"));
  const kn = num(b["speed"]);
  return clean({
    imei,
    lat,
    lon,
    at: toIso(pick(b, "timestamp", "time", "fixtime", "at")),
    speed_kmph: kmh ?? (kn === undefined ? undefined : kn * KNOT_KMH),
    heading: num(pick(b, "bearing", "heading", "course")),
    altitude_m: num(pick(b, "altitude", "alt")),
    accuracy_m: num(pick(b, "accuracy", "acc")),
    battery_pct: num(pick(b, "batt", "battery", "batteryLevel")),
    ignition: bool(pick(b, "ignition", "acc_on")),
    satellites: num(pick(b, "sat", "satellites")),
    raw: b,
  });
}

/** Formats 2-4: one JSON value (object or list). */
export function fromJson(j: unknown): GpsPosition[] {
  if (Array.isArray(j)) return j.flatMap((x) => fromJson(x));
  if (!j || typeof j !== "object") return [];
  const o = j as Bag;
  // 2. Traccar position forwarding
  if (o.position && typeof o.position === "object") {
    const p = o.position as Bag;
    const dev = (o.device && typeof o.device === "object" ? o.device : {}) as Bag;
    const a = (p.attributes && typeof p.attributes === "object" ? p.attributes : {}) as Bag;
    const imei = str(pick(dev, "uniqueId", "uniqueid") ?? pick(p, "deviceId"));
    const lat = num(p.latitude), lon = num(p.longitude);
    if (!imei || lat === undefined || lon === undefined) return [];
    const kn = num(p.speed);
    return [clean({
      imei, lat, lon,
      at: toIso(pick(p, "fixTime", "deviceTime", "serverTime")),
      speed_kmph: kn === undefined ? undefined : kn * KNOT_KMH,
      heading: num(p.course),
      altitude_m: num(p.altitude),
      accuracy_m: num(p.accuracy),
      battery_pct: num(pick(a, "batteryLevel", "battery")),
      ignition: bool(a.ignition),
      satellites: num(pick(a, "sat", "satellites")),
      raw: o,
    })];
  }
  // 3. Traccar Client JSON
  if (o.location && typeof o.location === "object") {
    const l = o.location as Bag;
    const c = (l.coords && typeof l.coords === "object" ? l.coords : {}) as Bag;
    const bat = (l.battery && typeof l.battery === "object" ? l.battery : {}) as Bag;
    const imei = str(pick(o, "device_id", "id", "imei"));
    const lat = num(c.latitude), lon = num(c.longitude);
    if (!imei || lat === undefined || lon === undefined) return [];
    const mps = num(c.speed);
    const level = num(bat.level);
    return [clean({
      imei, lat, lon,
      at: toIso(l.timestamp),
      speed_kmph: mps === undefined || mps < 0 ? undefined : mps * MPS_KMH,
      heading: num(c.heading),
      altitude_m: num(c.altitude),
      accuracy_m: num(c.accuracy),
      battery_pct: level === undefined ? undefined : Math.round(level <= 1 ? level * 100 : level),
      raw: o,
    })];
  }
  // 4. simple JSON (speed in km/h)
  const imei = str(pick(o, "imei", "id", "deviceid", "device_id", "uniqueId"));
  const lat = num(pick(o, "lat", "latitude"));
  const lon = num(pick(o, "lon", "lng", "longitude"));
  if (!imei || lat === undefined || lon === undefined) return [];
  return [clean({
    imei, lat, lon,
    at: toIso(pick(o, "at", "time", "timestamp", "fixTime")),
    speed_kmph: num(pick(o, "speed_kmph", "kmph", "speed")),
    heading: num(pick(o, "heading", "course", "bearing")),
    altitude_m: num(pick(o, "altitude", "altitude_m")),
    accuracy_m: num(pick(o, "accuracy", "accuracy_m")),
    battery_pct: num(pick(o, "battery", "battery_pct", "batt")),
    ignition: bool(o.ignition),
    satellites: num(pick(o, "satellites", "sat")),
    raw: o,
  })];
}

/** Everything one request carries: the key and its positions. */
export function parseRequest(url: URL, headers: { get(name: string): string | null }, body: string): ParsedRequest {
  const q: Bag = Object.fromEntries(url.searchParams.entries());
  let key: string | null = str(q.key) || headers.get("x-gps-key") || null;
  const positions: GpsPosition[] = [];
  const fromQuery = fromParams(q);
  if (fromQuery) positions.push(fromQuery);
  const text = body.trim();
  if (text) {
    const type = (headers.get("content-type") || "").toLowerCase();
    if (type.includes("json") || text.startsWith("{") || text.startsWith("[")) {
      try {
        const j = JSON.parse(text);
        if (j && typeof j === "object" && !Array.isArray(j) && typeof (j as Bag).key === "string") key = key || str((j as Bag).key);
        positions.push(...fromJson(j));
      } catch {
        // not JSON after all: no positions from the body
      }
    } else {
      const form: Bag = Object.fromEntries(new URLSearchParams(text).entries());
      if (!key && form.key) key = str(form.key);
      const p = fromParams(form);
      if (p) positions.push(p);
    }
  }
  for (const p of positions) {
    if (p.raw && typeof p.raw === "object") delete (p.raw as Bag).key; // the key is never stored
  }
  return { key, positions };
}

/** Same length and same characters, without stopping at the first difference. */
export function sameKey(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
