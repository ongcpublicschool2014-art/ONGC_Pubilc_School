-- =====================================================================
--  SCHOOL TRANSPORT - tr_vehicle.gps_device_id
--
--  Adds an optional link from a vehicle to its GPS device.
--  NULL = no device linked. References transport20262027.tr_gps_device
--  (same target as public.tr_vehicle_gps_device.device_id).
--
--  Safe to run again.
-- =====================================================================

BEGIN;

ALTER TABLE public.tr_vehicle
  ADD COLUMN IF NOT EXISTS gps_device_id BIGINT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'tr_vehicle_gps_device_id_fkey'
                    AND conrelid = 'public.tr_vehicle'::regclass) THEN
    ALTER TABLE public.tr_vehicle
      ADD CONSTRAINT tr_vehicle_gps_device_id_fkey
      FOREIGN KEY (gps_device_id) REFERENCES transport20262027.tr_gps_device(device_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_tr_vehicle_gps_device_id ON public.tr_vehicle(gps_device_id);

COMMIT;
