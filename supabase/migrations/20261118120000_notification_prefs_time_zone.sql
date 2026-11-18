-- The phone's time zone (IANA id, e.g. "America/Chicago"), written by the app on every prefs save.
-- Lets the partner-alert push say "no food until 8:31" in local time.
alter table public.notification_prefs
  add column if not exists time_zone text;
