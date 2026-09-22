-- =============================================================================
-- 28_propose_clearance_log.sql — der Vorschlag der Physio kommt in die
-- Zugriffsuebersicht (Punkt 56, Befund N8)
--
-- Befund N8 der Gegenlesung mit Opus (Audit 2026-09-21, Abschnitt 11.5), gemessen
-- am 2026-09-22: app.rpc_propose_clearance schreibt eine Zeile in
-- app.medical_clearances, aber keine in app.access_log. Ihre Schwester
-- app.rpc_set_clearance schreibt beides.
--
--   Physio: rpc_propose_clearance(..., 'individual', 'Vorschlag Physio')
--           -> medical_clearances 1 -> 2, access_log 4 -> 4
--   Gegenprobe Aerztin, rpc_set_clearance
--           -> medical_clearances 2 -> 3, access_log 4 -> 5
--
-- Folge: eine Physio traegt eine Gesundheitsangabe ueber eine Spielerin ein, und in
-- der Zugriffsuebersicht dieser Spielerin (app.rpc_get_my_access_log) steht davon
-- nichts. Art. 15 DSGVO verlangt Auskunft ueber die Verarbeitung, nicht nur ueber
-- die Entscheidung am Ende der Kette.
--
-- Behebung: eine Zeile action = 'write', genau wie in rpc_set_clearance. Dieselbe
-- resource ('medical_clearances'), damit Vorschlag und Entscheidung in derselben
-- Zeile der Uebersicht zusammenlaufen; wer sie auseinanderhalten will, liest
-- actor_role, dort steht physio gegen doctor.
--
-- -----------------------------------------------------------------------------
-- Die Teampruefung kommt mit, und zwar zwingend
-- -----------------------------------------------------------------------------
-- app.rpc_propose_clearance hat dieselbe Luecke wie ihre Schwester in Befund N4:
-- sie schreibt team_id = app.auth_team_id() und person_id = p_person_id, ohne je
-- geprueft zu haben, ob diese Person im eigenen Team ist. N4 nennt sie nicht, weil
-- die Gegenlesung an rpc_set_clearance gemessen hat.
--
-- Wuerde Punkt 56 woertlich gebaut, also nur die access_log Zeile ergaenzt, schriebe
-- die Funktion ab sofort AUCH eine Protokollzeile ueber eine teamfremde Person --
-- also genau Befund N3, neu eingebaut, in eine Funktion, die ihn vorher nicht
-- hatte. Die Pruefung aus Punkt 52 steht deshalb hier ebenfalls, vor beiden
-- INSERTs. Sie nutzt denselben Helper, app.auth_target_is_team_player(uuid), aus
-- 27_clearance_team_guard.sql.
--
-- Muster D, letzter Absatz gilt unveraendert: rpc_propose_clearance hat keine Tuer
-- in public, ihre Ablehnung bleibt log_denial plus RAISE und wird zurueckgerollt.
-- Der Umbau auf "Antwort statt Ausnahme" gehoert zum Tuerbau (AP-47a).
--
-- Voraussetzung: 09_rpcs.sql (die Funktion, log_denial),
-- 27_clearance_team_guard.sql (der Helper). Idempotent.
-- =============================================================================

CREATE OR REPLACE FUNCTION app.rpc_propose_clearance(
  p_person_id uuid,
  p_status    app.app_clearance,
  p_rationale text DEFAULT NULL
)
RETURNS app.medical_clearances
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.medical_clearances;
BEGIN
  -- Rolle pruefen (erste Anweisung!) - NUR physio
  IF NOT app.auth_has_role('physio') THEN
    PERFORM app.log_denial('medical_clearances.propose');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.propose (only physio)' USING errcode = '42501';
  END IF;

  -- Muster D, Regel 4 (Punkt 56, gleiche Lage wie N4): Team und Zustand der
  -- Zielperson VOR dem Freigabe-INSERT und vor dem Protokoll-INSERT.
  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    PERFORM app.log_denial('medical_clearances.propose');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.propose' USING errcode = '42501';
  END IF;

  INSERT INTO app.medical_clearances (
    team_id, person_id, status, load_note, valid_from, valid_to,
    set_by, set_by_role, proposed_by
  ) VALUES (
    app.auth_team_id(), p_person_id, p_status, p_rationale, current_date, NULL,
    app.auth_person_id(), 'physio'::app.app_role, app.auth_person_id()
  )
  RETURNING * INTO v_row;

  -- Access log (Punkt 56, N8). Bis heute fehlte diese Zeile als einzige der
  -- beiden Schreibwege in medical_clearances.
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'medical_clearances', 'write'
  );

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Wer eine Tuer baut, gibt das Recht in derselben Migration zurueck und baut die Ablehnung '
  'auf Antwort statt Ausnahme um (Muster D). '
  'Punkt 56 (2026-09-22): Befund N8 behoben, der Vorschlag schreibt jetzt eine Zeile '
  'action=write in app.access_log. Die Teampruefung aus Punkt 52 steht vor beiden INSERTs.';
