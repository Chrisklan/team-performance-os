-- =============================================================================
-- 20260922000038_clearance_team_guard.sql (Quelle: backend/27_clearance_team_guard.sql) — Teampruefung vor den Schreibstellen (Punkt 52, Befunde N3 und N4)
--
-- Befunde N3 und N4 der Gegenlesung mit Opus (Audit 2026-09-21, Abschnitt 11.5),
-- gemessen am 2026-09-22:
--
--   N3  app.rpc_get_clearance(uuid) und app.rpc_readiness_full(uuid, date, date)
--       schreiben eine Zeile in app.access_log mit subject_id = p_person_id, ohne
--       je geprueft zu haben, ob diese Person im eigenen Team ist. Das team_id der
--       Zeile kommt aus den Claims der handelnden Person. Eine Trainerin aus Team
--       a1 ruft rpc_get_clearance mit der person_id einer Spielerin aus Team a2:
--       access_log 3 -> 4, Zeile "subject = ...0009 (Team der Person: a2)
--       geschrieben in team = a1, role = coach". app.rpc_shred_person loescht
--       WHERE subject_id = ... AND team_id = v_team_id und erreicht diese Zeile
--       nie: der Admin von Team a2 shreddet die Spielerin, persons wird
--       SCRAPED-..., die Protokollzeile steht unveraendert weiter in Team a1.
--
--   N4  app.rpc_set_clearance(...) schreibt zusaetzlich eine medizinische Freigabe
--       fuer eine teamfremde Person in das eigene Team. Kein Protokollproblem,
--       sondern eine Gesundheitsangabe (Art. 9 DSGVO) ueber einen Menschen
--       ausserhalb des Silos, die dessen eigener Loeschpfad nicht erreicht.
--
-- Muster D, Regel 4 (Modul-Rollen-Medizin-Gate Abschnitt 6): die Rolle allein
-- genuegt nicht. Nimmt die Funktion ein p_person_id entgegen, gehoert die Pruefung
-- auf Team und Zustand der Person VOR den Protokoll-INSERT, nicht erst in das WHERE
-- der Antwort. Vorbild ist app.rpc_body_map_region_reports (20_denial_answer.sql):
-- pe.team_id = v_team_id AND pe.is_active AND ra.role = 'player', DANN erst der
-- INSERT.
--
-- -----------------------------------------------------------------------------
-- Warum ein Helper statt drei Abschriften
-- -----------------------------------------------------------------------------
-- Das Praedikat des Vorbilds ist elf Zeilen lang und hat vier Bedingungen, von
-- denen jede einzeln traegt. Viermal abgeschrieben ist es viermal die Gelegenheit,
-- eine davon zu vergessen; das faellt beim Lesen nicht auf, weil die Funktion dann
-- immer noch plausibel aussieht. Es steht deshalb genau einmal, in
-- app.auth_target_is_team_player(uuid).
--
-- app.rpc_body_map_region_reports behaelt vorerst ihre eingebaute Fassung: sie
-- laeuft unveraendert in der Cloud, ihr Umbau war nicht Teil dieses Pakets, und ein
-- Umbau ohne Not an der einzigen Funktion, die heute ueber eine Tuer erreichbar ist
-- und Gesundheitsdaten liefert, waere schlechter Handel. Damit die beiden Fassungen
-- nicht auseinanderlaufen, prueft Suite 09 sie gegeneinander:
-- wer eine der beiden aendert und die andere vergisst, bekommt einen roten Test.
--
-- -----------------------------------------------------------------------------
-- Was die Pruefung mitnimmt, ohne dass es im Befund stand
-- -----------------------------------------------------------------------------
-- app.rpc_get_clearance liess bisher auch app.auth_person_id() = p_person_id durch.
-- auth_person_id() ist Stufe 1 von ADR-015: es loest den JWT sub auf und prueft
-- weder is_active noch den team_id Claim noch role_assignments. Eine deaktivierte
-- Person mit noch gueltigem Token kam also bis zum Protokoll-INSERT, wo erst
-- access_log.team_id NOT NULL sie stoppte -- mit 23502 statt mit einer Ablehnung,
-- und ohne Zeile in access_denials. Die neue Pruefung faengt diesen Fall als
-- regulaere Ablehnung ab, weil auth_team_id() dort NULL ist und der Vergleich
-- pe.team_id = NULL nie zutrifft.
--
-- -----------------------------------------------------------------------------
-- Die Ablehnung bleibt Ausnahme, nicht Antwort
-- -----------------------------------------------------------------------------
-- Muster D, letzter Absatz: die acht Funktionen ohne Tuer behalten log_denial plus
-- RAISE, ihre Ablehnung wird also weiter zurueckgerollt. Der Umbau auf "Antwort
-- statt Ausnahme" gehoert zum Tuerbau (AP-47a) und steht dort im COMMENT. Diese
-- Migration baut das Muster nicht um, sie setzt nur die fehlende Bedingung.
--
-- Fremdes Team, unbekannte Id, NULL, deaktivierte, geshredderte Person und Person
-- ohne gueltige Spielerinnenrolle antworten gleich. Wer p_person_id durchprobiert,
-- erfaehrt aus der Antwort nicht, welche Id es in einem anderen Team gibt.
--
-- Voraussetzung: 08_reconciling.sql (Helper, persons, role_assignments),
-- 09_rpcs.sql (die drei Funktionen, log_denial). Idempotent.
-- =============================================================================


-- =============================================================================
-- 1. Der Helper
-- =============================================================================
--
-- Wahr genau dann, wenn p_person_id eine aktive Person im bestaetigten Team der
-- handelnden Person ist UND dort heute eine gueltige Rolle 'player' traegt.
--
-- is_active steht hier, weil app.rpc_shred_person die Rolle nicht beendet: ohne
-- diese Bedingung oeffnete die Pruefung eine Sicht auf eine Person, die es nicht
-- mehr gibt, und schriebe danach eine Zeile in den access_log, die der Shred fuer
-- diese Person gerade geloescht hat.
--
-- NULL-sicher in beide Richtungen: p_person_id IS NULL trifft nie, und ohne
-- bestaetigtes Team ist app.auth_team_id() NULL, der Vergleich damit ebenfalls
-- NULL. EXISTS macht daraus false, nie NULL -- "IF NOT ..." wirkt also sicher.

CREATE OR REPLACE FUNCTION app.auth_target_is_team_player(p_person_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM app.persons pe
      JOIN app.role_assignments ra
        ON ra.person_id = pe.id AND ra.team_id = pe.team_id
     WHERE pe.id        = p_person_id
       AND pe.team_id   = app.auth_team_id()
       AND pe.is_active
       AND ra.role      = 'player'
       AND ra.valid_from <= now()
       AND (ra.valid_to IS NULL OR ra.valid_to > now())
  );
$$;

COMMENT ON FUNCTION app.auth_target_is_team_player(uuid) IS
  'Muster D, Regel 4: Team und Zustand der Zielperson, geprueft VOR jedem Protokoll- '
  'oder Freigabe-INSERT. Wahr nur fuer eine aktive Person mit gueltiger Rolle player '
  'im bestaetigten Team der handelnden Person. Ohne bestaetigtes Team false, nie NULL. '
  'Punkt 52 (2026-09-22), Befunde N3 und N4. Gleichbedeutend mit dem eingebauten '
  'Praedikat in app.rpc_body_map_region_reports, Suite 09 haelt beide gegeneinander.';

-- Nur die DEFINER Funktionen rufen sie, und die laufen mit den Rechten ihres
-- Eigentuemers. authenticated braucht das Recht nicht und bekommt es nicht: die
-- Funktion beantwortet die Frage "gibt es diese Person in meinem Team", und das ist
-- nichts, was ein Client frei durchprobieren koennen muss.
REVOKE EXECUTE ON FUNCTION app.auth_target_is_team_player(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.auth_target_is_team_player(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION app.auth_target_is_team_player(uuid) FROM authenticated;


-- =============================================================================
-- 2. app.rpc_readiness_full — Pruefung vor den Protokoll-INSERT (N3)
-- =============================================================================
--
-- Unveraendert gegenueber 09_rpcs.sql: beide Rollenpruefungen, der INSERT, die
-- Abfrage. Neu ist allein der dritte IF Block.
--
-- Die neue Bedingung trifft auch den Fall, dass eine Physio ihre EIGENE readiness
-- abfragt: sie ist keine Spielerin, die Pruefung lehnt ab. Das ist kein Verlust,
-- app.readiness_scores entsteht aus Check-Ins und die schreiben nur Spielerinnen;
-- fuer Staff gab es dort noch nie eine Zeile. Die Matrix fuehrt readiness_scores
-- fuer Staff ohnehin nur als Fremdsicht, "R self" steht in der Spalte player.

CREATE OR REPLACE FUNCTION app.rpc_readiness_full(
  p_person_id uuid,
  p_from      date DEFAULT NULL,
  p_to        date DEFAULT NULL
)
RETURNS SETOF app.readiness_scores
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Rolle pruefen (erste Anweisung!)
  IF app.auth_is_staff() OR app.auth_has_role('admin') THEN
    PERFORM app.log_denial('readiness_scores.score_total');
    RAISE EXCEPTION 'FORBIDDEN: readiness_scores.score_total' USING errcode = '42501';
  END IF;

  IF NOT (app.auth_is_medical() OR app.auth_person_id() = p_person_id) THEN
    PERFORM app.log_denial('readiness_scores.full');
    RAISE EXCEPTION 'FORBIDDEN: readiness_scores.full' USING errcode = '42501';
  END IF;

  -- Muster D, Regel 4 (Punkt 52, N3): Team und Zustand der Zielperson VOR dem
  -- Protokoll-INSERT. Ohne diese Zeile schreibt eine korrekt autorisierte Medizin-
  -- rolle eine access_log Zeile ueber eine teamfremde Person, und rpc_shred_person
  -- erreicht sie nie.
  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    PERFORM app.log_denial('readiness_scores.full');
    RAISE EXCEPTION 'FORBIDDEN: readiness_scores.full' USING errcode = '42501';
  END IF;

  -- Access log
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
  VALUES (
    app.auth_team_id(),
    p_person_id,
    app.auth_person_id(),
    app.denial_actor_role(),
    'readiness_scores.score_total',
    'read',
    COALESCE(p_from, current_date)
  );

  RETURN QUERY
  SELECT rs.* FROM app.readiness_scores rs
  WHERE rs.team_id = app.auth_team_id()
    AND rs.person_id = p_person_id
    AND (p_from IS NULL OR rs.date >= p_from)
    AND (p_to IS NULL OR rs.date <= p_to);
END;
$$;

COMMENT ON FUNCTION app.rpc_readiness_full(uuid, date, date) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Wer eine Tuer baut, gibt das Recht in derselben Migration zurueck und baut die Ablehnung '
  'auf Antwort statt Ausnahme um (Muster D). '
  'Punkt 52 (2026-09-22): Befund N3 behoben, die Teampruefung steht vor dem Protokoll-INSERT.';


-- =============================================================================
-- 3. app.rpc_get_clearance — Pruefung vor den Protokoll-INSERT (N3)
-- =============================================================================
--
-- Der Waechter bleibt unveraendert, auch der Zweig app.auth_has_role('admin').
-- Chris hat am 2026-09-22 zu Befund N2 (Punkt 53) entschieden, die MATRIX zu
-- aendern statt den Code: admin bekommt in der Zeile medical_clearances.status +
-- load_note ein R. Nach der harten Regel von Modul-Rollen-Medizin-Gate Abschnitt 5
-- braucht das ein neues ADR; solange das nicht geschrieben und angenommen ist,
-- bleibt die Stelle in der Matrix als offen vermerkt. Die Zeile "medical_clearances
-- setzen" bleibt fuer admin bei '-', app.rpc_set_clearance verlangt unveraendert
-- doctor.

CREATE OR REPLACE FUNCTION app.rpc_get_clearance(p_person_id uuid)
RETURNS app.medical_clearances
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.medical_clearances;
BEGIN
  -- Rolle pruefen (erste Anweisung!)
  IF NOT (app.auth_is_staff() OR app.auth_is_medical() OR app.auth_has_role('admin')
          OR app.auth_person_id() = p_person_id) THEN
    PERFORM app.log_denial('medical_clearances.get');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.get' USING errcode = '42501';
  END IF;

  -- Muster D, Regel 4 (Punkt 52, N3): Team und Zustand der Zielperson VOR dem
  -- Protokoll-INSERT. Faengt zusaetzlich den self Zweig oben ab, der ueber
  -- auth_person_id() laeuft und deshalb weder is_active noch den team_id Claim
  -- kennt (Stufe 1 von ADR-015).
  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    PERFORM app.log_denial('medical_clearances.get');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.get' USING errcode = '42501';
  END IF;

  -- Access log (medizinische Ressource)
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(),
    p_person_id,
    app.auth_person_id(),
    app.denial_actor_role(),
    'medical_clearances',
    'read'
  );

  SELECT * INTO v_row FROM app.medical_clearances
  WHERE person_id = p_person_id
    AND team_id = app.auth_team_id()
    AND valid_from <= current_date
    AND (valid_to IS NULL OR valid_to >= current_date)
  ORDER BY valid_from DESC
  LIMIT 1;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION app.rpc_get_clearance(uuid) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Wer eine Tuer baut, gibt das Recht in derselben Migration zurueck und baut die Ablehnung '
  'auf Antwort statt Ausnahme um (Muster D). '
  'Punkt 52 (2026-09-22): Befund N3 behoben, die Teampruefung steht vor dem Protokoll-INSERT. '
  'Punkt 53 (N2, admin im Waechter): Chris hat entschieden, die Matrix zu aendern statt den '
  'Code. Der admin Zweig bleibt deshalb absichtlich stehen, das ADR dazu ist offen.';


-- =============================================================================
-- 4. app.rpc_set_clearance — Pruefung vor den Freigabe-INSERT (N4)
-- =============================================================================
--
-- Hier ist die Pruefung keine Protokollfrage: ohne sie schreibt eine Aerztin aus
-- Team a1 eine Gesundheitsangabe ueber einen Menschen aus Team a2 in ihr eigenes
-- Team, und der Loeschpfad dieses Menschen erreicht sie nicht.
--
-- Die Ablehnung nennt hier bewusst nicht "(only doctor)": an dieser Stelle ist die
-- Rolle richtig und die Zielperson falsch. Die Meldung sagt also, welche Huerde
-- getroffen wurde, ohne etwas ueber die Person zu sagen -- fremdes Team, unbekannte
-- Id und deaktivierte Person geben dieselbe Antwort.

CREATE OR REPLACE FUNCTION app.rpc_set_clearance(
  p_person_id   uuid,
  p_status      app.app_clearance,
  p_load_note   text DEFAULT NULL,
  p_valid_from  date DEFAULT current_date,
  p_valid_to    date DEFAULT NULL
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
  -- Rolle pruefen (erste Anweisung!) - NUR doctor
  IF NOT app.auth_has_role('doctor') THEN
    PERFORM app.log_denial('medical_clearances.set');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.set (only doctor)' USING errcode = '42501';
  END IF;

  -- Muster D, Regel 4 (Punkt 52, N4): Team und Zustand der Zielperson VOR dem
  -- Freigabe-INSERT.
  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    PERFORM app.log_denial('medical_clearances.set');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.set' USING errcode = '42501';
  END IF;

  INSERT INTO app.medical_clearances (
    team_id, person_id, status, load_note, valid_from, valid_to, set_by, set_by_role
  ) VALUES (
    app.auth_team_id(), p_person_id, p_status, p_load_note, p_valid_from, p_valid_to,
    app.auth_person_id(), 'doctor'::app.app_role
  )
  RETURNING * INTO v_row;

  -- Access log
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'medical_clearances', 'write'
  );

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Wer eine Tuer baut, gibt das Recht in derselben Migration zurueck und baut die Ablehnung '
  'auf Antwort statt Ausnahme um (Muster D). '
  'Punkt 52 (2026-09-22): Befund N4 behoben, die Teampruefung steht vor dem Freigabe-INSERT.';
