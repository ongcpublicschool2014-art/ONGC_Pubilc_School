-- transport_26_nightly_trips.sql
--
-- The next day's trips are made every evening at 21:00 India time (15:30
-- UTC; pg_cron runs in UTC) by transport_core.generate_next_day_trips()
-- (transport_02), so the Daily Trips screen shows them the night before and
-- the office can change a trip's vehicle or crew. Make Trips on that screen
-- does the same for one day at any time.
--
-- Safe to run again: cron.schedule replaces the job of the same name.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule('transport-next-day-trips', '30 15 * * *', 'SELECT transport_core.generate_next_day_trips()');

COMMIT;
