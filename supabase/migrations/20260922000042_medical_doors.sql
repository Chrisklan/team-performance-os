-- =============================================================================
-- 20260922000042_medical_doors.sql (Quelle: backend/31_medical_doors.sql) — AP-47a Teil 2: die sechs Medizin-Tueren
--
-- Physio und Arzt bekommen in public eigene Tueren zu Check-ins, Readiness,
-- Lastabweichungen und Freigabe. Jede Rolle sieht nur ihren Teil (Modul 7
-- Abschnitt 5), jeder lesende Zugriff steht in app.access_log.
--
-- WAS DIESE DATEI AUSSERDEM SCHLIESST
--   F2  app.rpc_check_ins_medical lieferte das ganze Team und schrieb EINE
--       Protokollzeile mit subject_id = actor_id, also ueber die Physio selbst
--       statt ueber die gelesenen Menschen. Die Funktion bekommt p_person_id
--       (so nennt sie ADR-017 Abschnitt 4.2 ohnehin) und schreibt eine Zeile
--       je gelesener Person.
--   A2  Der self Zweig derselben Funktion war ADR-015 Stufe 1: auth_person_id()
--       IS NOT NULL, ohne is_active, ohne team_id Claim. Der Protokoll-INSERT
--       lief davor und kippte ohne bestaetigtes Team in 23502, dessen DETAIL
--       den ganzen Zeileninhalt herausgibt. Jetzt greift Regel 4 (der Helper).
--   A3  app.rpc_release_deviation schrieb GAR KEINE Protokollzeile. Eine
--       ungesichtete Abweichung ist laut Matrix medizinexklusiv, ihre Freigabe
--       ist ein Schreibzugriff darauf. Punkt 56 hat dieselbe Luecke bei
--       rpc_propose_clearance geschlossen, hier fehlte sie noch.
--
-- DIE FUENF REGELN VON MUSTER D, UND WO SIE HIER STEHEN
--   1. Keine Tuer ist STABLE oder IMMUTABLE. Alle sechs sind VOLATILE.
--   2. Kein RAISE mehr im Ablehnungszweig der app Funktion: app.deny gibt das
--      Fehlerobjekt zurueck, die Zeile in access_denials bleibt stehen.
--   3. Was kein log_denial ruft, bleibt bei RAISE. Das betrifft hier die
--      Eingabepruefung (22023) und "nicht gefunden" (P0002) — beides sind
--      keine Rechtefragen.
--   4. Jede Funktion mit p_person_id ruft app.auth_target_is_team_player VOR
--      dem INSERT.
--   5. Erste Bedingung im Rumpf ist app.auth_team_id() IS NULL -> deny. Bei
--      den Funktionen mit p_person_id faengt der Helper denselben Fall ab; die
--      eigene Zeile steht trotzdem, weil sie dort den Grund benennt und weil
--      rpc_review_deviation keinen Helper hat.
--
-- DAS RECHT KOMMT MIT (Punkt 55). Jede der sechs app Funktionen bekommt in
-- DIESER Datei ihr GRANT EXECUTE fuer authenticated zurueck. Die Tueren sind
-- SECURITY INVOKER und laufen nur damit. Ohne das GRANT antwortete die neue
-- Tuer mit 42501 aus ihrem eigenen Rumpf, und der Fehler saehe aus wie ein
-- Rechteproblem des Aufrufers.
--
-- WARUM DER RUECKGABETYP AUF JSONB WECHSELT. SETOF app.daily_checkins kann das
-- Ablehnungsobjekt nicht tragen. Derselbe Grund wie bei app.rpc_submit_checkin
-- in AP-45d, deshalb dort wie hier DROP statt REPLACE.
--
-- Voraussetzung: 09_rpcs.sql, 20_denial_answer.sql, 27_clearance_team_guard.sql,
-- 30_clearance_proposals.sql. Idempotent.
-- Tests: backend/31_medical_doors.pgtap.sql.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_medical_checkins(uuid, date, date);
DROP FUNCTION IF EXISTS public.rpc_medical_readiness(uuid, date, date);
DROP FUNCTION IF EXISTS public.rpc_get_clearance(uuid);
DROP FUNCTION IF EXISTS public.rpc_review_deviation(uuid, text);
DROP FUNCTION IF EXISTS public.rpc_propose_clearance(uuid, app.app_clearance, text);
DROP FUNCTION IF EXISTS public.rpc_set_clearance(uuid, app.app_clearance, text, date, date);

DROP FUNCTION IF EXISTS app.rpc_check_ins_medical(date, date);
DROP FUNCTION IF EXISTS app.rpc_check_ins_medical(uuid, date, date);
DROP FUNCTION IF EXISTS app.rpc_readiness_full(uuid, date, date);
DROP FUNCTION IF EXISTS app.rpc_release_deviation(uuid, text);
DROP FUNCTION IF EXISTS app.rpc_get_clearance(uuid);
DROP FUNCTION IF EXISTS app.rpc_set_clearance(uuid, app.app_clearance, text, date, date);
DROP FUNCTION IF EXISTS app.rpc_propose_clearance(uuid, app.app_clearance, text);


-- =============================================================================
-- 1. app.rpc_check_ins_medical(p_person_id, p_from, p_to) — F2
-- =============================================================================
--
-- Eine Person je Aufruf, eine Protokollzeile je Aufruf, subject_id = die
-- gelesene Person. Die Auswahlliste kommt aus app.rpc_list_team_members
-- (Web-Vorlauf, Bridge Punkt 33), nicht mehr aus dieser Funktion.
--
-- Was dabei wegfaellt: die teamweite Abfrage. Kein Client hat sie je gerufen
-- (Grep ueber beide Repos), und sie war der Grund fuer F2.

CREATE FUNCTION app.rpc_check_ins_medical(
  p_person_id uuid,
  p_from      date DEFAULT NULL,
  p_to        date DEFAULT NULL
)
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
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
  END IF;

  -- Medizin-Gate: Staff und admin haben hier gar nichts zu suchen.
  IF app.auth_is_staff() OR app.auth_has_role('admin') THEN
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
  END IF;

  -- Medizin oder die Person selbst.
  IF NOT (app.auth_is_medical() OR app.auth_person_id() = p_person_id) THEN
    RETURN app.deny('daily_checkins.medical', 'FORBIDDEN: daily_checkins.medical');
  END IF;

  -- Muster D, Regel 4: Team und Zustand der Zielperson VOR dem Protokoll-INSERT.
  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    RETURN app.deny('daily_checkins.medical', 'FORBIDDEN: daily_checkins.medical');
  END IF;

  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'daily_checkins.body_map', 'read', COALESCE(p_from, current_date)
  );

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'date'), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'id',                  dc.id,
               'date',                dc.date,
               'sleep_duration_min',  dc.sleep_duration_min,
               'sleep_quality',       dc.sleep_quality,
               'recovery',            dc.recovery,
               'energy',              dc.energy,
               'mental_stress',       dc.mental_stress,
               'mental_mood',         dc.mental_mood,
               'mental_motivation',   dc.mental_motivation,
               'training_readiness',  dc.training_readiness,
               'body_map',            dc.body_map,
               'pain_max',            dc.pain_max,
               'submitted_at',        dc.submitted_at
             ) AS x
        FROM app.daily_checkins dc
       WHERE dc.team_id   = app.auth_team_id()
         AND dc.person_id = p_person_id
         AND (p_from IS NULL OR dc.date >= p_from)
         AND (p_to   IS NULL OR dc.date <= p_to)
    ) s;

  RETURN jsonb_build_object(
    'person_id', p_person_id,
    'from',      p_from,
    'to',        p_to,
    'checkins',  v_rows
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_check_ins_medical(uuid, date, date) IS
  'AP-47a (2026-09-22): Tuer public.rpc_medical_checkins. Muster D, Ablehnung als '
  'Antwort. Befund F2 geschlossen: eine Person je Aufruf, eine access_log Zeile mit '
  'subject_id = der gelesenen Person statt einer Zeile ueber die Physio selbst. '
  'Befund A2 geschlossen: der self Zweig laeuft jetzt ueber '
  'app.auth_target_is_team_player statt ueber auth_person_id() allein.';

-- Ein CREATE ohne dieses REVOKE gibt PUBLIC ein EXECUTE, und ueber PUBLIC
-- erbt anon. pgTAP Suite 26 haelt beides fest.
REVOKE EXECUTE ON FUNCTION app.rpc_check_ins_medical(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_check_ins_medical(uuid, date, date) TO authenticated;


-- =============================================================================
-- 2. app.rpc_readiness_full(p_person_id, p_from, p_to)
-- =============================================================================

CREATE FUNCTION app.rpc_readiness_full(
  p_person_id uuid,
  p_from      date DEFAULT NULL,
  p_to        date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('readiness_scores.full', 'FORBIDDEN: readiness_scores.full');
  END IF;

  IF app.auth_is_staff() OR app.auth_has_role('admin') THEN
    RETURN app.deny('readiness_scores.score_total', 'FORBIDDEN: readiness_scores.score_total');
  END IF;

  IF NOT (app.auth_is_medical() OR app.auth_person_id() = p_person_id) THEN
    RETURN app.deny('readiness_scores.full', 'FORBIDDEN: readiness_scores.full');
  END IF;

  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    RETURN app.deny('readiness_scores.full', 'FORBIDDEN: readiness_scores.full');
  END IF;

  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'readiness_scores.score_total', 'read', COALESCE(p_from, current_date)
  );

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'date'), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'date',        rs.date,
               'score_total', rs.score_total,
               'band',        rs.band,
               'factors',     rs.factors,
               'computed_at', rs.computed_at
             ) AS x
        FROM app.readiness_scores rs
       WHERE rs.team_id   = app.auth_team_id()
         AND rs.person_id = p_person_id
         AND (p_from IS NULL OR rs.date >= p_from)
         AND (p_to   IS NULL OR rs.date <= p_to)
    ) s;

  RETURN jsonb_build_object(
    'person_id', p_person_id,
    'from',      p_from,
    'to',        p_to,
    'scores',    v_rows
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_readiness_full(uuid, date, date) IS
  'AP-47a (2026-09-22): Tuer public.rpc_medical_readiness. Muster D, Ablehnung als '
  'Antwort. Punkt 52: die Teampruefung steht vor dem Protokoll-INSERT.';

-- Ein CREATE ohne dieses REVOKE gibt PUBLIC ein EXECUTE, und ueber PUBLIC
-- erbt anon. pgTAP Suite 26 haelt beides fest.
REVOKE EXECUTE ON FUNCTION app.rpc_readiness_full(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_readiness_full(uuid, date, date) TO authenticated;


-- =============================================================================
-- 3. app.rpc_get_clearance(p_person_id) — die Antwort haengt an der Rolle
-- =============================================================================
--
-- ADR-017 Abschnitt 4.2: was die Rolle nicht sehen darf, verlaesst die
-- Datenbank nicht. Drei Empfaengerkreise, zwei Formen:
--
--   physio, doctor        volle Zeile, dazu die offenen Vorschlaege aus
--                         app.clearance_proposals
--   coach, athletic_coach status, load_note, Gueltigkeit — sonst nichts
--   admin                 dasselbe, Grundlage ADR-018
--   die Person selbst     dasselbe
--
-- Was fuer Staff, admin und die Person selbst NICHT herausgeht: set_by,
-- set_by_role, proposed_by und jeder Vorschlag. Alle vier sagen, dass eine
-- Medizinperson beteiligt war, und ADR-017 Abschnitt 3 gibt dem Trainer
-- "Status und load_note, nie ein Grund".
--
-- Ein Vorschlag gilt als offen, solange nach seinem proposed_at keine Freigabe
-- mit spaeterem valid_from steht. Kein Flag, kein Zustand, der auseinander
-- laufen koennte.
--
-- Der admin Zweig im Waechter ist begruendet, nicht vergessen: ADR-018,
-- angenommen am 2026-09-22. ENTSCHIEDEN IST DIE ROLLE admin, WIE SIE HEUTE IN
-- app.app_role STEHT. Eine spaeter eingefuehrte, eingeschraenkte Verwaltungs-
-- rolle erbt das Recht NICHT. app.auth_has_role('admin') prueft gegen genau
-- EINE Zeichenkette und laesst eine neue Rolle deshalb gar nicht durch. Wer
-- das hier auf "alle Verwaltungsrollen" verallgemeinert, hebt ADR-018 ueber
-- seinen Geltungsbereich hinaus.

CREATE FUNCTION app.rpc_get_clearance(p_person_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row        app.medical_clearances;
  v_clearance  jsonb;
  v_proposals  jsonb;
  v_medical    boolean;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('medical_clearances.get', 'FORBIDDEN: medical_clearances.get');
  END IF;

  IF NOT (app.auth_is_staff() OR app.auth_is_medical() OR app.auth_has_role('admin')
          OR app.auth_person_id() = p_person_id) THEN
    RETURN app.deny('medical_clearances.get', 'FORBIDDEN: medical_clearances.get');
  END IF;

  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    RETURN app.deny('medical_clearances.get', 'FORBIDDEN: medical_clearances.get');
  END IF;

  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'medical_clearances', 'read'
  );

  -- Dieselbe Auswahlregel wie app.rpc_list_team_members, samt id-Tiebreaker:
  -- ohne ihn entscheidet bei gleichem valid_from der Zufall, und Liste und
  -- Detail koennten verschiedene Zustaende zeigen.
  SELECT * INTO v_row
    FROM app.medical_clearances c
   WHERE c.person_id  = p_person_id
     AND c.team_id    = app.auth_team_id()
     AND c.valid_from <= current_date
     AND (c.valid_to IS NULL OR c.valid_to >= current_date)
   ORDER BY c.valid_from DESC, c.id DESC
   LIMIT 1;

  v_medical := app.auth_is_medical();

  IF v_row.id IS NULL THEN
    v_clearance := NULL;
  ELSIF v_medical THEN
    v_clearance := jsonb_build_object(
      'status',      v_row.status,
      'load_note',   v_row.load_note,
      'valid_from',  v_row.valid_from,
      'valid_to',    v_row.valid_to,
      'set_by',      v_row.set_by,
      'set_by_role', v_row.set_by_role
    );
  ELSE
    v_clearance := jsonb_build_object(
      'status',     v_row.status,
      'load_note',  v_row.load_note,
      'valid_from', v_row.valid_from,
      'valid_to',   v_row.valid_to
    );
  END IF;

  IF v_medical THEN
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'proposed_at' DESC), '[]'::jsonb) INTO v_proposals
      FROM (
        SELECT jsonb_build_object(
                 'id',               cp.id,
                 'status',           cp.status,
                 'rationale',        cp.rationale,
                 'proposed_by',      cp.proposed_by,
                 'proposed_by_role', cp.proposed_by_role,
                 'proposed_at',      cp.proposed_at
               ) AS x
          FROM app.clearance_proposals cp
         WHERE cp.person_id = p_person_id
           AND cp.team_id   = app.auth_team_id()
           AND (v_row.id IS NULL OR cp.proposed_at > v_row.valid_from)
      ) s;
  ELSE
    v_proposals := NULL;
  END IF;

  RETURN jsonb_build_object(
    'person_id',      p_person_id,
    'clearance',      v_clearance,
    'open_proposals', v_proposals
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_get_clearance(uuid) IS
  'AP-47a (2026-09-22): Tuer public.rpc_get_clearance. Muster D, Ablehnung als '
  'Antwort. Die Antwort haengt an der Rolle (ADR-017 Abschnitt 4.2): set_by, '
  'set_by_role und die offenen Vorschlaege gehen nur an physio und doctor, nie an '
  'Staff, admin oder die Person selbst. '
  'Punkt 52: die Teampruefung steht vor dem Protokoll-INSERT. '
  'Punkt 53 (N2): der admin Zweig ist begruendet, nicht vergessen — ADR-018, '
  'angenommen. Entschieden ist die Rolle admin, wie sie heute in app.app_role '
  'steht; eine spaetere, eingeschraenkte Verwaltungsrolle erbt das Recht nicht.';

-- Ein CREATE ohne dieses REVOKE gibt PUBLIC ein EXECUTE, und ueber PUBLIC
-- erbt anon. pgTAP Suite 26 haelt beides fest.
REVOKE EXECUTE ON FUNCTION app.rpc_get_clearance(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_clearance(uuid) TO authenticated;


-- =============================================================================
-- 4. app.rpc_release_deviation(p_deviation_id, p_decision) — A3
-- =============================================================================

CREATE FUNCTION app.rpc_release_deviation(
  p_deviation_id uuid,
  p_decision     text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.load_deviations;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('load_deviations.release', 'FORBIDDEN: load_deviations.release');
  END IF;

  IF NOT (app.auth_has_role('physio') OR app.auth_has_role('doctor')) THEN
    RETURN app.deny('load_deviations.release', 'FORBIDDEN: load_deviations.release');
  END IF;

  -- Regel 3: das ist keine Rechtefrage, also kein log_denial und damit RAISE.
  IF p_decision IS NULL OR p_decision NOT IN ('release', 'dismiss') THEN
    RAISE EXCEPTION 'INVALID: load_deviations.decision' USING errcode = '22023';
  END IF;

  UPDATE app.load_deviations
     SET state       = CASE WHEN p_decision = 'release' THEN 'released'::app.app_deviation_state
                            ELSE 'dismissed'::app.app_deviation_state END,
         reviewed_by = app.auth_person_id(),
         reviewed_at = now(),
         released_at = CASE WHEN p_decision = 'release' THEN now() ELSE released_at END
   WHERE id      = p_deviation_id
     AND team_id = app.auth_team_id()
  RETURNING * INTO v_row;

  -- Fremdes Team, unbekannte Id und geloeschte Zeile geben dieselbe Antwort.
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: load_deviations' USING errcode = 'P0002';
  END IF;

  -- Befund A3 (AP-47a): bis heute schrieb diese Funktion keine Protokollzeile.
  -- Eine ungesichtete Abweichung ist medizinexklusiv (Modul 7 Abschnitt 5), ihre
  -- Freigabe ist ein Schreibzugriff darauf. Gleiche Begruendung wie Punkt 56
  -- bei rpc_propose_clearance. Steht NACH dem UPDATE, weil erst die Zeile sagt,
  -- um wessen Daten es geht; scheitert das UPDATE, gibt es auch nichts zu
  -- protokollieren.
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
  VALUES (
    app.auth_team_id(), v_row.person_id, app.auth_person_id(), app.denial_actor_role(),
    'load_deviations', 'write', v_row.date
  );

  RETURN jsonb_build_object(
    'id',          v_row.id,
    'person_id',   v_row.person_id,
    'date',        v_row.date,
    'deviation',   v_row.deviation,
    'state',       v_row.state,
    'reviewed_by', v_row.reviewed_by,
    'reviewed_at', v_row.reviewed_at,
    'released_at', v_row.released_at
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_release_deviation(uuid, text) IS
  'AP-47a (2026-09-22): Tuer public.rpc_review_deviation. Muster D, Ablehnung als '
  'Antwort. Befund A3 geschlossen: die Freigabe schreibt jetzt eine access_log Zeile '
  'action=write mit subject_id = der betroffenen Person. Vorher schrieb sie keine.';

-- Ein CREATE ohne dieses REVOKE gibt PUBLIC ein EXECUTE, und ueber PUBLIC
-- erbt anon. pgTAP Suite 26 haelt beides fest.
REVOKE EXECUTE ON FUNCTION app.rpc_release_deviation(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_release_deviation(uuid, text) TO authenticated;


-- =============================================================================
-- 5. app.rpc_propose_clearance(p_person_id, p_status, p_rationale)
-- =============================================================================
--
-- Schreibt nach app.clearance_proposals (Teil 1), nie nach medical_clearances.
-- Die Protokollzeile bleibt resource='medical_clearances' (Punkt 56).

CREATE FUNCTION app.rpc_propose_clearance(
  p_person_id uuid,
  p_status    app.app_clearance,
  p_rationale text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_proposal app.clearance_proposals;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('medical_clearances.propose', 'FORBIDDEN: medical_clearances.propose');
  END IF;

  IF NOT app.auth_has_role('physio') THEN
    RETURN app.deny('medical_clearances.propose', 'FORBIDDEN: medical_clearances.propose (only physio)');
  END IF;

  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    RETURN app.deny('medical_clearances.propose', 'FORBIDDEN: medical_clearances.propose');
  END IF;

  INSERT INTO app.clearance_proposals (
    team_id, person_id, status, rationale, proposed_by, proposed_by_role
  ) VALUES (
    app.auth_team_id(), p_person_id, p_status, p_rationale,
    app.auth_person_id(), 'physio'::app.app_role
  )
  RETURNING * INTO v_proposal;

  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'medical_clearances', 'write'
  );

  RETURN jsonb_build_object(
    'id',               v_proposal.id,
    'person_id',        v_proposal.person_id,
    'status',           v_proposal.status,
    'rationale',        v_proposal.rationale,
    'proposed_by',      v_proposal.proposed_by,
    'proposed_by_role', v_proposal.proposed_by_role,
    'proposed_at',      v_proposal.proposed_at
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) IS
  'AP-47a (2026-09-22): Tuer public.rpc_propose_clearance. Muster D, Ablehnung als '
  'Antwort. Der Vorschlag steht in app.clearance_proposals und ist strukturell keine '
  'Freigabe: ADR-017 Abschnitt 4.2 sagt "kein Effekt auf status". '
  'Punkt 52 und 56: Teampruefung vor beiden INSERTs, Protokollzeile action=write mit '
  'resource=medical_clearances, damit Vorschlag und Entscheidung zusammenlaufen.';

-- Ein CREATE ohne dieses REVOKE gibt PUBLIC ein EXECUTE, und ueber PUBLIC
-- erbt anon. pgTAP Suite 26 haelt beides fest.
REVOKE EXECUTE ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) TO authenticated;


-- =============================================================================
-- 6. app.rpc_set_clearance(...) — nur doctor (ADR-017 D3)
-- =============================================================================

CREATE FUNCTION app.rpc_set_clearance(
  p_person_id   uuid,
  p_status      app.app_clearance,
  p_load_note   text DEFAULT NULL,
  p_valid_from  date DEFAULT current_date,
  p_valid_to    date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.medical_clearances;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('medical_clearances.set', 'FORBIDDEN: medical_clearances.set');
  END IF;

  -- Nur doctor. admin liest die Freigabe (ADR-018), setzen darf er sie nicht:
  -- die Zeile "medical_clearances setzen" bleibt fuer admin bei '-'.
  IF NOT app.auth_has_role('doctor') THEN
    RETURN app.deny('medical_clearances.set', 'FORBIDDEN: medical_clearances.set (only doctor)');
  END IF;

  -- Hier ist die Pruefung keine Protokollfrage: ohne sie schriebe eine Aerztin
  -- aus Team a1 eine Gesundheitsangabe ueber einen Menschen aus Team a2 in ihr
  -- eigenes Team, und der Loeschpfad dieses Menschen erreichte sie nie.
  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    RETURN app.deny('medical_clearances.set', 'FORBIDDEN: medical_clearances.set');
  END IF;

  INSERT INTO app.medical_clearances (
    team_id, person_id, status, load_note, valid_from, valid_to, set_by, set_by_role
  ) VALUES (
    app.auth_team_id(), p_person_id, p_status, p_load_note, p_valid_from, p_valid_to,
    app.auth_person_id(), 'doctor'::app.app_role
  )
  RETURNING * INTO v_row;

  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'medical_clearances', 'write'
  );

  RETURN jsonb_build_object(
    'id',          v_row.id,
    'person_id',   v_row.person_id,
    'status',      v_row.status,
    'load_note',   v_row.load_note,
    'valid_from',  v_row.valid_from,
    'valid_to',    v_row.valid_to,
    'set_by',      v_row.set_by,
    'set_by_role', v_row.set_by_role
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date) IS
  'AP-47a (2026-09-22): Tuer public.rpc_set_clearance. Muster D, Ablehnung als '
  'Antwort. Nur doctor (ADR-017 D3). proposed_by wird nicht mehr beschrieben, der '
  'Vorschlag lebt seit AP-47a in app.clearance_proposals. '
  'Punkt 52: Teampruefung vor dem Freigabe-INSERT.';

-- Ein CREATE ohne dieses REVOKE gibt PUBLIC ein EXECUTE, und ueber PUBLIC
-- erbt anon. pgTAP Suite 26 haelt beides fest.
REVOKE EXECUTE ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date) TO authenticated;


-- =============================================================================
-- 7. Die sechs Tueren in public
-- =============================================================================
--
-- Alle sechs nach demselben Muster wie public.rpc_body_map_region_reports:
-- SECURITY INVOKER, SET search_path = '', VOLATILE, der Waechter sitzt genau
-- einmal — im Rumpf der app Funktion. Die Tuer macht aus dem Fehlerobjekt
-- einen HTTP 403 und sonst nichts.
--
-- Nicht DEFINER: das waere ein zweiter privilegierter Pfad neben der ohnehin
-- als DEFINER laufenden app Funktion, also genau das Muster, das Befund N9 als
-- "Loch mit Tuerschild" gezeigt hat.

CREATE FUNCTION public.rpc_medical_checkins(p_person_id uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_check_ins_medical(p_person_id, p_from, p_to);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE FUNCTION public.rpc_medical_readiness(p_person_id uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_readiness_full(p_person_id, p_from, p_to);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE FUNCTION public.rpc_get_clearance(p_person_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_get_clearance(p_person_id);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE FUNCTION public.rpc_review_deviation(p_deviation_id uuid, p_decision text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_release_deviation(p_deviation_id, p_decision);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE FUNCTION public.rpc_propose_clearance(p_person_id uuid, p_status app.app_clearance, p_rationale text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_propose_clearance(p_person_id, p_status, p_rationale);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE FUNCTION public.rpc_set_clearance(p_person_id uuid, p_status app.app_clearance, p_load_note text DEFAULT NULL, p_valid_from date DEFAULT current_date, p_valid_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_set_clearance(p_person_id, p_status, p_load_note, p_valid_from, p_valid_to);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_medical_checkins(uuid, date, date)  IS 'AP-47a: API-Tuer fuer app.rpc_check_ins_medical. Invoker, nur authenticated.';
COMMENT ON FUNCTION public.rpc_medical_readiness(uuid, date, date) IS 'AP-47a: API-Tuer fuer app.rpc_readiness_full. Invoker, nur authenticated.';
COMMENT ON FUNCTION public.rpc_get_clearance(uuid)                 IS 'AP-47a: API-Tuer fuer app.rpc_get_clearance. Invoker, nur authenticated.';
COMMENT ON FUNCTION public.rpc_review_deviation(uuid, text)        IS 'AP-47a: API-Tuer fuer app.rpc_release_deviation. Invoker, nur authenticated.';
COMMENT ON FUNCTION public.rpc_propose_clearance(uuid, app.app_clearance, text) IS 'AP-47a: API-Tuer fuer app.rpc_propose_clearance. Invoker, nur authenticated.';
COMMENT ON FUNCTION public.rpc_set_clearance(uuid, app.app_clearance, text, date, date) IS 'AP-47a: API-Tuer fuer app.rpc_set_clearance. Invoker, nur authenticated.';

REVOKE EXECUTE ON FUNCTION public.rpc_medical_checkins(uuid, date, date)  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_medical_readiness(uuid, date, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_get_clearance(uuid)                 FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_review_deviation(uuid, text)        FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_propose_clearance(uuid, app.app_clearance, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_set_clearance(uuid, app.app_clearance, text, date, date) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_medical_checkins(uuid, date, date)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_medical_readiness(uuid, date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_get_clearance(uuid)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_review_deviation(uuid, text)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_propose_clearance(uuid, app.app_clearance, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_set_clearance(uuid, app.app_clearance, text, date, date) TO authenticated, service_role;
