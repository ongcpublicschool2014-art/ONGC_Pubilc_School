-- =====================================================================
--  SCHOOL TRANSPORT - which GPS device is on which vehicle, with history
--
--  public.tr_vehicle_gps_device has one row for each time a device was on
--  a vehicle: installed_on, and removed_on once it came off (empty while it
--  is still on). The GPS Mapping tab of Vehicles saves it
--  (transport_core._vehicle_gps_save, file 02). tr_vehicle.gps_device_id
--  (file 06) follows it: always the device on the vehicle now, or empty.
--
--  This file:
--   1. adds who made or changed a row and when, and the rule that a device
--      cannot come off before the day it went on (ck_vgd_dates);
--   2. keeps updated_at current, like the other masters, and indexes the
--      history by vehicle and by device;
--   3. moves a device chosen on the vehicle form before the GPS Mapping tab
--      into the history, installed on the day the vehicle was last saved
--      (when two vehicles had the same device, the lower vehicle ID keeps
--      it), then makes tr_vehicle.gps_device_id match the history.
--
--  Safe to run again: once the history and the vehicles agree, step 3
--  changes nothing.
-- =====================================================================

BEGIN;

-- 1. Who and when; a device comes off on or after the day it went on.
ALTER TABLE public.tr_vehicle_gps_device
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS created_by BIGINT,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_by BIGINT;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'ck_vgd_dates' AND conrelid = 'public.tr_vehicle_gps_device'::regclass) THEN
    ALTER TABLE public.tr_vehicle_gps_device
      ADD CONSTRAINT ck_vgd_dates CHECK (removed_on IS NULL OR removed_on >= installed_on);
  END IF;
END $$;

-- 2. updated_at on every change; the history of one vehicle or one device.
CREATE OR REPLACE TRIGGER trg_tr_vehicle_gps_device_upd BEFORE UPDATE ON public.tr_vehicle_gps_device
  FOR EACH ROW EXECUTE FUNCTION transport_core.fn_set_updated_at();

CREATE INDEX IF NOT EXISTS ix_vgd_vehicle ON public.tr_vehicle_gps_device (vehicle_id, installed_on);
CREATE INDEX IF NOT EXISTS ix_vgd_device  ON public.tr_vehicle_gps_device (device_id, installed_on);

-- 3. Devices chosen on the vehicle form become history, then every vehicle
--    shows the device its history says is on it now.
INSERT INTO public.tr_vehicle_gps_device (inst_id, vehicle_id, device_id, installed_on, created_by, updated_by)
SELECT DISTINCT ON (v.gps_device_id)
       v.inst_id, v.vehicle_id, v.gps_device_id,
       -- never before the end of what the vehicle or the device already has
       GREATEST(v.updated_at::date,
                (SELECT max(m.removed_on) FROM public.tr_vehicle_gps_device m
                  WHERE m.vehicle_id = v.vehicle_id OR m.device_id = v.gps_device_id)),
       v.updated_by, v.updated_by
  FROM public.tr_vehicle v
 WHERE v.gps_device_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.tr_vehicle_gps_device m
                    WHERE m.removed_on IS NULL AND (m.vehicle_id = v.vehicle_id OR m.device_id = v.gps_device_id))
 ORDER BY v.gps_device_id, v.vehicle_id;

UPDATE public.tr_vehicle v
   SET gps_device_id = (SELECT m.device_id FROM public.tr_vehicle_gps_device m
                         WHERE m.vehicle_id = v.vehicle_id AND m.removed_on IS NULL)
 WHERE v.gps_device_id IS DISTINCT FROM (SELECT m.device_id FROM public.tr_vehicle_gps_device m
                                          WHERE m.vehicle_id = v.vehicle_id AND m.removed_on IS NULL);

COMMIT;
