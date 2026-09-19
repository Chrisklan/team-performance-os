-- Migration 20260919000021_trainer_api_wrapper.sql (AP-30)
-- Quelle: backend/12_trainer_api.sql (identisch). Tests: backend/12_trainer_api.pgtap.sql.
-- Schreibt keine Daten.

-- =============================================================================
-- 12_trainer_api.sql — API-Tuer fuer das Trainer-Dashboard (AP-30)
-- PostgREST exponiert nur public und graphql_public. Statt Schema app ganz
-- freizugeben (26 Tabellen, 51 Funktionen inkl. Legacy), gibt es genau eine
-- duenne Tuer in public.
--
-- * SECURITY INVOKER: laeuft mit der Rolle und den Claims des Aufrufers.
--   Die Pruefung (Waechter Stufe 2, FORBIDDEN) bleibt in app.rpc_morning_ops.
-- * Nur authenticated darf aufrufen. anon bekommt 42501 schon an der Tuer.
-- * Eigener Name: public.rpc_morning_ops(date) ist Legacy (AP-39), eine
--   Ueberladung ohne Parameter waere fuer PostgREST mehrdeutig.
-- * Liest nur, schreibt keine Daten.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 08_dashboard_migration.sql,
-- 10_auth_hook.sql. Idempotent.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_trainer_morning_ops()
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT app.rpc_morning_ops();
$$;

COMMENT ON FUNCTION public.rpc_trainer_morning_ops() IS
  'AP-30: API-Tuer fuer app.rpc_morning_ops(). Invoker, nur authenticated.';

REVOKE EXECUTE ON FUNCTION public.rpc_trainer_morning_ops() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_trainer_morning_ops() FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_trainer_morning_ops() TO authenticated, service_role;
