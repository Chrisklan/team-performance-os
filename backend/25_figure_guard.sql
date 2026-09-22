-- =============================================================================
-- 25_figure_guard.sql — Waechter fuer die beiden Figur-Tueren (Punkt 54, Befund N1)
--
-- Befund N1 der Gegenlesung mit Opus (Audit 2026-09-21, Abschnitt 11.5), gemessen
-- am 2026-09-22: app.rpc_my_body_map_figure() und app.rpc_set_my_body_map_figure(text)
-- pruefen nur app.auth_person_id() IS NOT NULL. Das ist Stufe 1 von ADR-015, nicht
-- Stufe 2. auth_person_id() loest den JWT sub ueber persons.auth_user_id auf und
-- prueft weder is_active noch den team_id Claim noch role_assignments. Folge,
-- gemessen: eine deaktivierte Person liest ihre Figur UND setzt sie (aus_dem_team
-- auf maennlich, geschrieben in app.persons), ein falscher team_id Claim und ein
-- falscher Rollen-Claim kommen ebenfalls durch. Dieselbe Person an
-- app.rpc_my_body_map_history: Ablehnung. Es war der letzte ueber die API
-- erreichbare Befund und der einzige, bei dem jemand ohne Recht SCHREIBT.
--
-- Muster D, Regel 5 (Modul-Rollen-Medizin-Gate Abschnitt 6): eine Tuer ohne
-- bestaetigtes Team ist keine Tuer. Erste Bedingung im Rumpf ist deshalb
-- app.auth_team_id() IS NOT NULL. Die Bedingung ersetzt die alte, sie stapelt sich
-- nicht davor: auth_team_id() joint selbst ueber auth_person_id(), ein bestaetigtes
-- Team setzt eine aufgeloeste Person voraus. Zwei Bedingungen waeren eine tote.
--
-- KEINE Rollenpruefung. Die Figur ist reine Darstellung der Body Map (Modul-Body-Map
-- 3.2b), kein Gesundheitsdatum. Jede Person des Teams stellt ihre eigene Darstellung
-- um, auch Trainerin, Physio und Arzt (Suite 18 prueft das seit AP-44c). Ein
-- auth_has_role('player') hier sperrte sie aus, ohne etwas zu schuetzen.
--
-- -----------------------------------------------------------------------------
-- Die zweite Haelfte von N1: diese Tueren schrieben NIE eine Ablehnungszeile
-- -----------------------------------------------------------------------------
-- app.log_denial steigt ohne bestaetigtes Team wortlos aus, weil
-- app.access_denials.team_id NOT NULL ist. Genau die Faelle, die der neue Waechter
-- jetzt abweist (deaktiviert, falscher team_id Claim, Rolle entzogen), haben also
-- definitionsgemaess kein bestaetigtes Team: ohne eine Aenderung an log_denial
-- bliebe access_denials bei jeder dieser Ablehnungen unveraendert, und die zweite
-- Haelfte von N1 waere nicht behoben, sondern nur verschoben.
--
-- Deshalb bekommt log_denial einen Rueckfall auf das Team, in dem die DATENBANK die
-- handelnde Person fuehrt (app.persons.team_id), wenn der Claim kein Team bestaetigt.
-- Das ist der fachlich richtige Silo: die Ablehnung gehoert in das Team, dem die
-- Person zugeordnet ist, nicht in das, das ihr Token behauptet. Der Rueckfall gilt
-- zentral, nicht nur fuer diese beiden Tueren: dieselbe Luecke verschluckt heute
-- jede Ablehnung nach Deaktivierung oder Rollenentzug, an jeder Tuer.
--
-- Was der Rueckfall NICHT tut:
--   * Er nimmt keine Zeile weg. Jede Ablehnung, die heute geschrieben wird, wird
--     danach unveraendert geschrieben, mit demselben Team.
--   * Er greift nicht fuer anon und nicht nach dem Shredding: beide haben keine
--     aufgeloeste Person (rpc_shred_person setzt auth_user_id auf NULL), der
--     Rueckfall findet nichts und log_denial steigt aus wie bisher. Die Antwort ist
--     in beiden Faellen trotzdem die des Vertrags, die Tuer bleibt zu.
--   * Er erzeugt keine neue Spur ueber eine geshredderte Person. app.access_denials
--     nennt nur Handelnde (actor_id), nie Betroffene, und bleibt beim Shred bewusst
--     unberuehrt (14_shred_person.sql, Zeile 115). Die actor_id zeigt danach auf die
--     pseudonymisierte Personenzeile, wie jeder andere Verweis auf eine Handelnde.
--
-- Voraussetzung: 08_reconciling.sql (Helper, access_denials), 09_rpcs.sql
-- (log_denial), 20_denial_answer.sql (app.deny, die Tueren in public). Idempotent.
-- Die Tueren in public bleiben unveraendert: sie sind seit AP-45d volatile, geben
-- jsonb zurueck und setzen bei app.is_denial den Status 403. Ein Fehlerobjekt passt
-- also in beide Rueckgabetypen, ein Typwechsel wie bei rpc_submit_checkin (uuid auf
-- jsonb) ist hier nicht noetig.
-- =============================================================================

-- =============================================================================
-- 1. log_denial: Rueckfall auf das Team der Person
-- =============================================================================

CREATE OR REPLACE FUNCTION app.log_denial(p_resource text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, public, auth, pg_temp
AS $$
DECLARE
  v_team_id uuid;
  v_actor_id uuid;
  v_actor_role app.app_role;
BEGIN
  v_team_id := app.auth_team_id();
  v_actor_id := app.auth_person_id();
  v_actor_role := app.denial_actor_role();

  -- Punkt 54: Ohne bestaetigtes Team (deaktiviert, falscher team_id Claim, Rolle
  -- entzogen) gibt der Claim kein Team her. Die Datenbank kennt das Team der Person
  -- trotzdem. Die Ablehnung gehoert in diesen Silo, sonst verschwindet genau die
  -- Ablehnung, die den Rechteentzug belegt.
  IF v_team_id IS NULL AND v_actor_id IS NOT NULL THEN
    SELECT pe.team_id INTO v_team_id
      FROM app.persons pe
     WHERE pe.id = v_actor_id;
  END IF;

  -- Ohne jede Person (anon, geshreddet) gibt es kein Team, dem die Ablehnung
  -- zugeordnet werden kann. Ohne diesen Ausstieg scheitert der INSERT an
  -- team_id NOT NULL und der Aufrufer bekaeme 23502 statt FORBIDDEN.
  IF v_team_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO app.access_denials (team_id, actor_id, actor_role, resource, occurred_at)
  VALUES (v_team_id, v_actor_id, v_actor_role, p_resource, now());
END;
$$;

COMMENT ON FUNCTION app.log_denial(text) IS
  'Schreibt eine Ablehnung nach app.access_denials. Aufgerufen nur aus app.deny und aus '
  'den Definer-Funktionen, die den Deny feststellen, nie durch authenticated. '
  'Punkt 54 (2026-09-22): faellt auf app.persons.team_id der handelnden Person zurueck, '
  'wenn der Claim kein Team bestaetigt. Sonst verschwindet jede Ablehnung nach '
  'Deaktivierung, Rollenentzug oder falschem team_id Claim spurlos (Befund N1, zweite Haelfte). '
  'Ohne aufgeloeste Person (anon, geshreddet) steigt sie weiter ohne Zeile aus.';

REVOKE EXECUTE ON FUNCTION app.log_denial(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.log_denial(text) TO service_role;

-- =============================================================================
-- 2. Die beiden Figur-Funktionen: bestaetigtes Team als erste Bedingung
-- =============================================================================
-- Rumpf wie in 20_denial_answer.sql, geaendert ist genau die erste Bedingung.
-- Wer hier etwas am Waechter oder am Rueckgabetyp aendert, muss 20 nachziehen.

CREATE OR REPLACE FUNCTION app.rpc_my_body_map_figure()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_row       record;
BEGIN
  -- ADR-015 Stufe 2 (Muster D, Regel 5): bestaetigte Claims, nicht nur ein sub,
  -- der sich auf eine Person abbilden laesst. Deckt is_active, den team_id Claim
  -- und die gueltige Rolle in einem ab.
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('persons.body_map_figure', 'FORBIDDEN: persons.body_map_figure');
  END IF;

  v_person_id := app.auth_person_id();

  SELECT p.body_map_figure, t.squad_type
    INTO v_row
    FROM app.persons p
    JOIN app.teams t ON t.id = p.team_id
   WHERE p.id = v_person_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: persons.body_map_figure' USING errcode = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'preference', v_row.body_map_figure::text,
    'squadType',  v_row.squad_type::text,
    'figure',     app.body_map_figure_for(v_row.body_map_figure, v_row.squad_type)
  );
END;
$$;

CREATE OR REPLACE FUNCTION app.rpc_set_my_body_map_figure(p_preference text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_value     app.app_body_map_figure;
BEGIN
  -- Siehe rpc_my_body_map_figure. Hier wiegt die Bedingung schwerer: das ist der
  -- Schreibweg, und eine deaktivierte Person hat bis Punkt 54 ueber ihn
  -- app.persons geschrieben.
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('persons.body_map_figure', 'FORBIDDEN: persons.body_map_figure');
  END IF;

  v_person_id := app.auth_person_id();

  BEGIN
    v_value := p_preference::app.app_body_map_figure;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'INVALID: persons.body_map_figure' USING errcode = '22023';
  END;

  -- Die Bedingung am Ende haelt das audit_log ruhig: app.persons traegt einen
  -- Audit Trigger, der ganze Zeilen kopiert. Ein Setzen auf denselben Wert
  -- wuerde sonst eine weitere Vollkopie der Personenzeile erzeugen.
  UPDATE app.persons
     SET body_map_figure = v_value,
         updated_at      = now()
   WHERE id = v_person_id
     AND body_map_figure IS DISTINCT FROM v_value;

  RETURN app.rpc_my_body_map_figure();
END;
$$;

COMMENT ON FUNCTION app.rpc_my_body_map_figure() IS
  'AP-43: liefert Praeferenz, Kaderart und aufgeloeste Figur der eigenen Person. '
  'Punkt 54 (2026-09-22): Waechter ist app.auth_team_id() IS NOT NULL (ADR-015 Stufe 2), '
  'nicht mehr nur auth_person_id(). Keine Rollenpruefung, die Figur ist Darstellung.';
COMMENT ON FUNCTION app.rpc_set_my_body_map_figure(text) IS
  'AP-43: setzt die Figur-Praeferenz der eigenen Person. '
  'Punkt 54 (2026-09-22): Waechter ist app.auth_team_id() IS NOT NULL (ADR-015 Stufe 2). '
  'Vorher schrieb eine deaktivierte Person hierueber in app.persons (Befund N1).';
