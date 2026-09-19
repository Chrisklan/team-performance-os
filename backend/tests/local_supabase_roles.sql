-- =============================================================================
-- local_supabase_roles.sql — Supabase-Rollen, die lokal fehlen (nur Test-DB)
--
-- In der Cloud existiert supabase_auth_admin bereits (Supabase Auth).
-- Lokal (Homebrew-Postgres, tpos_gate_test) fehlt sie, dann scheitern die
-- Grants in backend/10_auth_hook.sql. Rollen gelten clusterweit, einmal
-- ausfuehren reicht. NICHT als Migration in die Cloud spielen.
--
-- Lauf: psql -X -h /tmp -v ON_ERROR_STOP=1 -d tpos_gate_test -f backend/tests/local_supabase_roles.sql
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOLOGIN NOINHERIT;
  END IF;
END $$;
