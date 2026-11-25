# gps-ingest: bus positions from GPS trackers

The buses' GPS trackers send their positions to this function, and the parents' School Bus map shows where each bus is.

## How a position reaches the map

1. A tracker, its vendor's platform or a Traccar server sends the position here over HTTPS.
2. This function checks the key and reads the position. The formats it accepts are listed in `../_shared/gps_formats.ts`.
3. It stores the position through `public.tr_gps_ingest`, using the service role. That database function:
   - finds the tracker by its IMEI,
   - finds the vehicle it is fitted to on that day,
   - stores the ping,
   - updates the vehicle's latest position, and today's trip if one is in progress.
4. The parent app reads the latest position through `tr_parent_bus`, and the map refreshes every 20 seconds.

A position is shown as **live** for 10 minutes. After that, parents see "Last seen … ago".

## One-time setup (for each Supabase project)

You need a Supabase CLI login that can reach the **school** project.

```
supabase login
supabase secrets set GPS_INGEST_KEY=<a long random text, 32+ characters> --project-ref <ref>
supabase functions deploy gps-ingest --no-verify-jwt --project-ref <ref>
```

- **The key:** keep `GPS_INGEST_KEY` private. Only the tracker platform needs it.
- **Why `--no-verify-jwt`:** trackers can't send a Supabase token. The key replaces it.
- **The project refs:** live is `xjdvrrcmvyjocxynmhql`, test is `esgguehqlymultdyccae`.

## In the desktop app (once per tracker)

1. In **Transport → Vehicles → GPS Devices**, add the tracker with its **IMEI**, exactly as the tracker reports it.
2. In **GPS Mapping**, fit the tracker to its vehicle, from the date it went on.

A position from an IMEI that isn't listed, or that isn't fitted to a vehicle, is skipped. The reply says why.

## Pointing the trackers here

The address is:
`https://<ref>.supabase.co/functions/v1/gps-ingest?key=<GPS_INGEST_KEY>`

- **Tracker platforms with "HTTP push" or "data forwarding"** (most vendor platforms): give them the address above. They can either add the position as parameters, for example `&id={imei}&lat={lat}&lon={lng}&timestamp={unixtime}&speed={speed_knots}&bearing={course}`, or post JSON. For speed in km/h, send `speed_kmph=` instead of `speed=`.
- **Trackers that speak a TCP protocol** (GT06 / Concox, Teltonika, and similar): Supabase can't receive TCP. Run a **Traccar** server for the trackers, then forward from it with these settings in `traccar.xml`:
  ```
  <entry key='forward.enable'>true</entry>
  <entry key='forward.json'>true</entry>
  <entry key='forward.url'>https://<ref>.supabase.co/functions/v1/gps-ingest?key=<GPS_INGEST_KEY></entry>
  ```
- **Traccar Client app on a phone** (for testing, or if a driver's phone is used): set the server URL to the address above, without `?key=`, and add the key as the header `x-gps-key`. If the app can't add headers, keep `?key=...` in the URL.

## Replies

| Status | Meaning |
|---|---|
| 200 | `{"received", "stored", "live", "skipped": [{"imei", "reason"}]}`: some positions may have been skipped, with the reason. |
| 400 | No position found in the request (it needs an id or IMEI, plus lat and lon). |
| 401 | The key is wrong or missing. |
| 503 | `GPS_INGEST_KEY` isn't set on the project. |

A position is skipped when:
- the device is unknown or switched off,
- it isn't fitted to a vehicle,
- its position is 0/0 or out of range,
- the device clock is more than 10 minutes ahead,
- it's more than 7 days old.
