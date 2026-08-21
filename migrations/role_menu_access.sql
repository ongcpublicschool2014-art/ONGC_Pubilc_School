-- Role → menu access control.
-- Lets an Admin choose which sidebar menus each role can see, instead of the
-- visibility being compiled into the Dart code.
--
-- Canonical definition also lives in schoolsetup.sql (public tables section).
-- This is a PUBLIC table (like custuserroles, which it references by value):
-- roles are per-institution but not per-academic-year, so it must not live in
-- a year schema.
--
-- Semantics:
--   * One row per (ins_id, ur_id, menulabel) that the role is ALLOWED to see.
--   * NO rows for a role  -> that role has never been configured, so the app
--     falls back to the built-in defaults (adminOnly / accountantOnly flags).
--     This keeps existing installs behaving exactly as before this feature.
--   * Admin role always sees everything regardless of rows (no self-lockout).

CREATE TABLE IF NOT EXISTS public.rolemenuaccess (
  rma_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ins_id       integer NOT NULL,
  ur_id        integer NOT NULL,          -- public.custuserroles.ur_id
  menulabel    varchar(50) NOT NULL,      -- must match AppNavItem.label in lib/utils/app_menu.dart
  createdat    timestamp DEFAULT now() NOT NULL,
  createdby    varchar(50),
  activestatus smallint DEFAULT 1 NOT NULL
);

-- One row per role+menu; lets the app upsert/delete cleanly.
CREATE UNIQUE INDEX IF NOT EXISTS uq_rolemenuaccess_role_menu
  ON public.rolemenuaccess (ins_id, ur_id, menulabel);

CREATE INDEX IF NOT EXISTS idx_rolemenuaccess_role
  ON public.rolemenuaccess (ins_id, ur_id);

GRANT ALL ON public.rolemenuaccess TO anon, authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;
