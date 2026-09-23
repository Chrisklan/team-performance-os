-- =============================================================================
-- 20260923000043_team_members_door.sql (Quelle: backend/32_team_members_door.sql) — Web Vorlauf Physio Sicht (Bridge Punkt 33, 44, 64)
--
-- Zwei Dinge, beide klein, beide nach bekanntem Muster:
--
-- 1. app.rpc_list_team_members bekommt eine Tuer in public. Sie ist die letzte
--    der acht Funktionen ohne Tuer, die eine bekommen soll (Punkt 44), und die
--    Auswahlliste der Physio Sicht im Web. rpc_shred_person bleibt zu.
--
-- 2. "nicht gefunden" kommt als HTTP 404 heraus statt als 500 (Punkt 64).
--
-- -----------------------------------------------------------------------------
-- Teil 1: RAISE wird Muster D
-- -----------------------------------------------------------------------------
-- Bisher: log_denial plus RAISE. Die Ablehnung rollte sich selbst zurueck
-- (Befund F1), access_denials blieb leer. Eine Tuer davor haette daran nichts
-- geaendert. Deshalb gibt die app Funktion jetzt jsonb zurueck, im
-- Ablehnungsfall das Objekt aus app.deny, und die Tuer setzt den 403.
-- Rueckgabetyp wechselt von TABLE auf jsonb, also DROP statt REPLACE.
--
-- Die fuenf Regeln von Muster D (Modul 7 Abschnitt 6), hier:
--   1. VOLATILE, app Funktion und Tuer.
--   2. Kein RAISE im Ablehnungszweig, app.deny.
--   3. Es gibt keinen Sachfehler, also kein RAISE ueberhaupt.
--   4. Kein p_person_id, also kein Helper. Die Zeilenauswahl selbst benutzt
--      dasselbe Praedikat wie app.auth_target_is_team_player (siehe unten).
--   5. Erste Bedingung: app.auth_team_id() IS NULL -> deny.
--
-- WER DURCHKOMMT, unveraendert: Staff (coach, athletic_coach), Medizin (physio,
-- doctor), admin. Nicht: player. Die Liste traegt Name, Position und den
-- Freigabestatus, und den Status sehen laut ADR-017 Abschnitt 3 alle fuenf.
--
-- WAS SICH AN DER LISTE AENDERT, bewusst:
--   (a) Nur noch aktive Personen mit gueltiger Rolle player. Vorher kamen
--       Trainer, Physio, Aerztin und Admin mit, jede mit dem Status 'full',
--       den es fuer sie gar nicht gibt. Die Liste ist die Auswahl der Detail-
--       Tueren, und die lassen nur app.auth_target_is_team_player durch. Wer
--       in der Liste einen Trainer anklickt, bekaeme dort FORBIDDEN und
--       hinterliesse eine Zeile in access_denials, die keinen Missbrauch
--       zeigt, sondern nur eine schlechte Liste. Liste und Detail duerfen nicht
--       auseinanderlaufen, dieselbe Begruendung wie beim LATERAL LIMIT 1.
--       Kein Client ruft die Funktion bisher (Grep ueber beide Repos).
--   (b) Stabile Reihenfolge nach display_name, dann id.
--
-- KEINE access_log ZEILE BEIM LESEN DER LISTE. Das Protokoll ist die
-- Zugriffsuebersicht der Spielerin: jede Zeile sagt "diese Person hat meine
-- Gesundheitsdaten gelesen". Die Liste liefert keine Gesundheitsdaten ueber
-- den Status hinaus, und den Status sieht das Trainerteam ohnehin. 25 Zeilen
-- je Seitenaufruf wuerden die Uebersicht jeder Spielerin mit Rauschen fuellen,
-- und das echte Oeffnen einer Person (drei Detail-Tueren, je eine Zeile) ginge
-- darin unter. Die Ablehnung dagegen steht in access_denials.
--
-- DAS RECHT KOMMT MIT (Punkt 55): GRANT EXECUTE der app Funktion in dieser
-- Datei. Ein CREATE ohne REVOKE gibt PUBLIC ein EXECUTE (Audit 15.7), deshalb
-- steht das REVOKE ausdruecklich da.
--
-- -----------------------------------------------------------------------------
-- Teil 2: P0002 als 404
-- -----------------------------------------------------------------------------
-- Regel 3 laesst "nicht gefunden" als RAISE ... P0002 stehen, das ist keine
-- Rechtefrage. PostgREST kennt fuer P0002 keine eigene Abbildung und antwortet
-- 500 (in der Cloud gemessen, Audit 16.3). Die Oberflaeche kann dann "gibt es
-- nicht" nicht von "Server kaputt" unterscheiden.
--
-- Die Tuer faengt genau P0002 (no_data_found) und nichts sonst, setzt
-- response.status 404 und gibt ein Objekt mit derselben Form wie die
-- Ablehnung zurueck: code, message, details, hint. supabase-js liest das als
-- error mit code 'P0002'. Alle anderen Fehler laufen unveraendert durch.
--
-- Der EXCEPTION Block oeffnet eine Untertransaktion. Das ist hier harmlos:
-- in beiden app Funktionen steht das RAISE P0002 vor jedem Schreiben
-- (rpc_release_deviation: das UPDATE hat keine Zeile getroffen, also gibt es
-- nichts zurueckzurollen), und eine Ablehnung ist kein Fehler, sondern ein
-- Rueckgabewert, sie verlaesst den Block also unberuehrt.
--
-- Betroffen sind die zwei Tueren, deren app Funktion P0002 werfen kann:
-- rpc_review_deviation und rpc_my_body_map_figure (Grep ueber backend/, gueltige
-- Fassungen 31 und 25). rpc_set_my_body_map_figure wirft seit 25 kein P0002
-- mehr, nur 22023, und bleibt unberuehrt.
-- CREATE OR REPLACE mit gleicher Signatur und gleichem Rueckgabetyp: die ACL
-- bleibt erhalten (in AP-57 gemessen), deshalb hier kein neues GRANT.
--
-- Voraussetzung: 09_rpcs.sql, 20_denial_answer.sql, 25_figure_guard.sql,
-- 26_app_execute_revoke.sql, 27_clearance_team_guard.sql, 30_clearance_proposals.sql,
-- 31_medical_doors.sql. Idempotent.
-- Tests: backend/32_team_members_door.pgtap.sql, 26_app_execute_revoke.pgtap.sql.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_list_team_members();
DROP FUNCTION IF EXISTS app.rpc_list_team_members();


-- =============================================================================
-- 1. app.rpc_list_team_members() — Muster D
-- =============================================================================

CREATE FUNCTION app.rpc_list_team_members()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  -- Muster D, Regel 5: ohne bestaetigtes Team ist das hier keine Tuer.
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('persons.list', 'FORBIDDEN: persons.list');
  END IF;

  IF NOT (app.auth_is_staff() OR app.auth_is_medical() OR app.auth_has_role('admin')) THEN
    RETURN app.deny('persons.list', 'FORBIDDEN: persons.list');
  END IF;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'display_name', x->>'id'), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'id',               p.id,
               'display_name',     p.display_name,
               'person_position',  p.person_position,
               'clearance_status', COALESCE(mc.status, 'full'::app.app_clearance)
             ) AS x
        FROM app.persons p
        LEFT JOIN LATERAL (
          SELECT c.status
            FROM app.medical_clearances c
           WHERE c.person_id = p.id
             AND c.team_id   = app.auth_team_id()
             AND c.valid_from <= current_date
             AND (c.valid_to IS NULL OR c.valid_to >= current_date)
           ORDER BY c.valid_from DESC, c.id DESC
           LIMIT 1
        ) mc ON true
       WHERE p.team_id = app.auth_team_id()
         AND p.is_active
         -- Dasselbe Praedikat wie app.auth_target_is_team_player, damit jede
         -- Person der Liste auch durch die Detail-Tueren kommt.
         AND EXISTS (
           SELECT 1
             FROM app.role_assignments ra
            WHERE ra.person_id = p.id
              AND ra.team_id   = p.team_id
              AND ra.role      = 'player'
              AND ra.valid_from <= now()
              AND (ra.valid_to IS NULL OR ra.valid_to > now())
         )
    ) s;

  RETURN jsonb_build_object('members', v_rows);
END;
$$;

COMMENT ON FUNCTION app.rpc_list_team_members() IS
  'Web Vorlauf Physio Sicht (2026-09-23, Bridge Punkt 33 und 44): Tuer '
  'public.rpc_list_team_members. Muster D, Ablehnung als Antwort, Rueckgabe jsonb '
  '{members:[...]}. Nur aktive Spielerinnen mit gueltiger Rolle player, dasselbe '
  'Praedikat wie app.auth_target_is_team_player, damit Liste und Detail-Tueren nicht '
  'auseinanderlaufen. Freigabestatus mit LATERAL LIMIT 1 und derselben Auswahlregel '
  'wie app.rpc_get_clearance (AP-47a). Schreibt keine access_log Zeile, siehe '
  'backend/32_team_members_door.sql.';

-- Ein CREATE ohne dieses REVOKE gibt PUBLIC ein EXECUTE, und ueber PUBLIC
-- erbt anon (Audit 15.7). Das GRANT ist Punkt 55: das Recht kommt mit der Tuer.
REVOKE EXECUTE ON FUNCTION app.rpc_list_team_members() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_list_team_members() TO authenticated;


-- =============================================================================
-- 2. Die Tuer in public
-- =============================================================================
-- Wie die sechs aus AP-47a: SECURITY INVOKER, SET search_path = '', VOLATILE.
-- Der Waechter sitzt genau einmal, im Rumpf der app Funktion.

CREATE FUNCTION public.rpc_list_team_members()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_list_team_members();
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_list_team_members() IS
  'Web Vorlauf Physio Sicht (Bridge Punkt 33): API-Tuer fuer app.rpc_list_team_members. '
  'Invoker, nur authenticated.';

REVOKE EXECUTE ON FUNCTION public.rpc_list_team_members() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_list_team_members() TO authenticated, service_role;


-- =============================================================================
-- 3. P0002 als 404 (Punkt 64)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_review_deviation(p_deviation_id uuid, p_decision text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_release_deviation(p_deviation_id, p_decision);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
EXCEPTION WHEN no_data_found THEN
  PERFORM set_config('response.status', '404', true);
  RETURN jsonb_build_object('code', 'P0002', 'message', SQLERRM, 'details', NULL, 'hint', NULL);
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_my_body_map_figure()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_my_body_map_figure();
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
EXCEPTION WHEN no_data_found THEN
  PERFORM set_config('response.status', '404', true);
  RETURN jsonb_build_object('code', 'P0002', 'message', SQLERRM, 'details', NULL, 'hint', NULL);
END; $$;

COMMENT ON FUNCTION public.rpc_review_deviation(uuid, text) IS
  'AP-47a: API-Tuer fuer app.rpc_release_deviation. Invoker, nur authenticated. '
  'Punkt 64 (2026-09-23): P0002 kommt als HTTP 404 heraus, nicht als 500.';
COMMENT ON FUNCTION public.rpc_my_body_map_figure() IS
  'API-Tuer fuer app.rpc_my_body_map_figure. Punkt 64 (2026-09-23): P0002 als HTTP 404.';
