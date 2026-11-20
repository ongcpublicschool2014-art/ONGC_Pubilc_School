-- transport_20_vehicle_fuel_required.sql
--
-- tr_vehicle.fuel_type becomes compulsory (NOT NULL). Its check is
-- unchanged: DIESEL, PETROL, CNG, ELECTRIC or HYBRID. The Vehicles screen's
-- Fuel tab shows quantities in litres, or kWh for an electric vehicle, from
-- this column.
--
-- No fuel is guessed for a vehicle that has none: the run stops, naming
-- those vehicles, and nothing is changed. Set the fuel of each in
-- Transport -> Vehicles, then run again.
--
-- Safe to run again.
BEGIN;

DO $$
DECLARE n integer; codes text;
BEGIN
  SELECT count(*) INTO n FROM public.tr_vehicle WHERE fuel_type IS NULL;
  IF n > 0 THEN
    SELECT string_agg(format('%s (school %s)', vehicle_code, inst_id), ', ') INTO codes
      FROM (SELECT vehicle_code, inst_id FROM public.tr_vehicle
             WHERE fuel_type IS NULL ORDER BY inst_id, vehicle_code LIMIT 20) x;
    RAISE EXCEPTION '% vehicle(s) have no fuel type: %. Set the fuel of each in Transport -> Vehicles, then run again; nothing was changed.', n, codes;
  END IF;
END $$;

ALTER TABLE public.tr_vehicle ALTER COLUMN fuel_type SET NOT NULL;

COMMIT;
