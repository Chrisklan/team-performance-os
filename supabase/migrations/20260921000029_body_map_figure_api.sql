-- Migration 20260921000029_body_map_figure_api.sql (AP-44c)
-- Quelle: backend/18_body_map_figure_api.sql (identisch). Tests: backend/18_body_map_figure_api.pgtap.sql.
-- Legt nur zwei Funktionen an, schreibt keine Daten, veraendert keine bestehende Zeile.

-- =============================================================================
-- 18_body_map_figure_api.sql — API-Tuer fuer die Figur der Body Map (AP-44c)
-- PostgREST exponiert nur public und graphql_public. app.rpc_my_body_map_figure()
-- und app.rpc_set_my_body_map_figure(text) (AP-43, 17_squad_figure.sql) sind damit
-- ueber die API nicht erreichbar (PGRST106). Statt Schema app freizugeben gibt es
-- zwei duenne Tueren in public, Muster wie 13_checkin_api.sql.
--
-- * SECURITY INVOKER: laeuft mit Rolle und Claims des Aufrufers. Die eigene
--   Person kommt aus app.auth_person_id() in der app Funktion, nie aus einem
--   Parameter. Der Umweg ueber SECURITY DEFINER bleibt dort, wo er hingehoert.
-- * Nur authenticated darf aufrufen. anon bekommt 42501 schon an der Tuer.
-- * Eigene Namen. Eine Ueberladung wuerde PostgREST mehrdeutig machen, es gibt
--   in public aber ohnehin keine Funktion dieses Namens.
-- * Gibt genau das zurueck, was die app Funktion liefert: preference, squadType,
--   figure. Kein Geschlechtsfeld, reine Darstellung (Modul-Body-Map 3.2b).
-- * Schreibt ausschliesslich persons.body_map_figure der eigenen Person.
--
-- Voraussetzung: 17_squad_figure.sql. Idempotent.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_my_body_map_figure();
DROP FUNCTION IF EXISTS public.rpc_set_my_body_map_figure(text);

CREATE FUNCTION public.rpc_my_body_map_figure()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT app.rpc_my_body_map_figure();
$$;

CREATE FUNCTION public.rpc_set_my_body_map_figure(p_preference text)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT app.rpc_set_my_body_map_figure(p_preference);
$$;

COMMENT ON FUNCTION public.rpc_my_body_map_figure() IS
  'AP-44c: API-Tuer fuer app.rpc_my_body_map_figure() (AP-43). Invoker, nur authenticated.';
COMMENT ON FUNCTION public.rpc_set_my_body_map_figure(text) IS
  'AP-44c: API-Tuer fuer app.rpc_set_my_body_map_figure(text) (AP-43). Invoker, nur authenticated.';

REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_figure()          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_set_my_body_map_figure(text)  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_figure()          FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_set_my_body_map_figure(text)  FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_my_body_map_figure()          TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.rpc_set_my_body_map_figure(text)  TO authenticated, service_role;
