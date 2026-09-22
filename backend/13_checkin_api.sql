-- =============================================================================
-- 13_checkin_api.sql — API-Tuer fuer den Check-In der Player-App (AP-34)
-- PostgREST exponiert nur public und graphql_public. app.rpc_submit_checkin (ADR-016)
-- ist damit ueber die API nicht erreichbar (PGRST106). Statt Schema app freizugeben
-- gibt es genau eine duenne Tuer in public, Muster wie 12_trainer_api.sql.
--
-- * SECURITY INVOKER: laeuft mit Rolle und Claims des Aufrufers. Rolle player,
--   Datumsfenster, person_id/team_id aus den Helpern und Score bleiben in
--   app.rpc_submit_checkin (Waechter Stufe 2, ADR-015).
-- * Nur authenticated darf aufrufen. anon bekommt 42501 schon an der Tuer.
-- * Parameter und Namen identisch zu app.rpc_submit_checkin, damit PostgREST
--   benannte Argumente 1:1 durchreicht.
-- * Schreibt ausschliesslich nach app.daily_checkins und app.readiness_scores.
--
-- Voraussetzung: 11_checkin_submit.sql. Idempotent.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb);

CREATE FUNCTION public.rpc_submit_checkin(
  p_date                date,
  p_sleep_duration_min  numeric DEFAULT NULL,
  p_sleep_quality       integer DEFAULT NULL,
  p_recovery            integer DEFAULT NULL,
  p_energy              integer DEFAULT NULL,
  p_mental_stress       integer DEFAULT NULL,
  p_mental_mood         integer DEFAULT NULL,
  p_mental_motivation   integer DEFAULT NULL,
  p_training_readiness  integer DEFAULT NULL,
  p_body_map            jsonb   DEFAULT NULL
)
RETURNS uuid
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT app.rpc_submit_checkin(
    p_date, p_sleep_duration_min, p_sleep_quality, p_recovery, p_energy,
    p_mental_stress, p_mental_mood, p_mental_motivation, p_training_readiness,
    p_body_map
  );
$$;

COMMENT ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) IS
  'AP-34: API-Tuer fuer app.rpc_submit_checkin (ADR-016). Invoker, nur authenticated.';

REVOKE EXECUTE ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- AP-45d (2026-09-21): die Ablehnung wurde von dem RAISE mit zurueckgerollt
-- (Befund F1). Ab jetzt ist sie Antwort statt Ausnahme. Die Funktionen dieser Datei,
-- die davon betroffen sind, werden in 20_denial_answer.sql zuletzt neu angelegt.
-- Wer hier etwas am Waechter oder am Rueckgabetyp aendert, muss 20 nachziehen.
-- -----------------------------------------------------------------------------
