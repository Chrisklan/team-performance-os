-- =============================================================================
-- 46_shred_person_hardening.sql — AP-69 Review-Funde (2026-09-29),
-- Punkte 89, 91, 92
--
-- Punkt 89 (WICHTIGSTER Fund, PII/Art. 17 DSGVO): app.rpc_shred_person
-- anonymisiert app.persons (display_name, auth_user_id, birth_date,
-- is_active, body_map_figure), laesst aber shirt_number, person_position und
-- position_cluster stehen. In Kombination (Rueckennummer + Position +
-- Positions-Cluster, oft zusammen mit dem team_id-Kontext) identifizieren sie
-- eine Person in einem Kader von ueblicherweise 20-30 Spielern praktisch
-- eindeutig -- das Pseudonym waere trivial aufloesbar, das Schreddern liefe
-- ins Leere. Fix: Schritt 5 setzt diese drei Felder zusaetzlich auf NULL.
--
-- Nachtrag Security-/Code-Review (2026-09-29, HOCH, Punkt 89 unvollstaendig):
-- app.persons traegt seit 20260924000045_baseline_engine.sql zusaetzlich
-- primary_position (text) und secondary_positions (text[]) -- dieselbe Art
-- Quasi-Identifikator, im ersten Wurf dieser Migration schlicht uebersehen,
-- weil sie erst nach dem urspruenglichen Entwurf von Punkt 89 entstanden.
-- Fix: Schritt 5 setzt jetzt auch diese beiden Felder auf NULL, die
-- Idempotenzbedingung ist entsprechend erweitert. Zusaetzlich haertet
-- backend/46_shred_person_hardening.pgtap.sql jetzt generisch: ein Test
-- vergleicht ALLE Spalten von app.persons (information_schema.columns) gegen
-- eine explizite Whitelist "nach dem Shred erlaubt stehenzubleiben" -- jede
-- kuenftig neu hinzugefuegte Spalte, die nicht auf der Whitelist steht, faellt
-- damit automatisch auf, statt wie primary_position/secondary_positions erst
-- beim naechsten Review entdeckt zu werden.
--
-- created_at bewusst NICHT ueberschrieben, Begruendung (pragmatische
-- Entscheidung, wie beauftragt):
--   1. created_at ist ein Systemfeld (Zeitpunkt des INSERT), keine fachliche
--      Angabe UEBER die Person (anders als birth_date) -- es sagt nur, WANN
--      diese Personenzeile im System angelegt wurde, nicht, wer die Person
--      ist. In einem Kader mit laufendem Zu-/Abgang ueber Jahre ist das
--      Anlagedatum fuer sich genommen kein praktikables Re-Identifikations-
--      merkmal (anders als shirt_number/person_position/position_cluster, die
--      zusammen einen konkreten Spieler auf dem Feld beschreiben).
--   2. UPDATE app.persons SET created_at = ... erzeugt technisch kein Problem
--      (created_at hat keinen Default-Trigger, der das verhindert) -- die
--      Zurueckhaltung ist eine bewusste Entscheidung, keine technische Grenze.
--   3. Nach Schritt 89 (shirt_number/person_position/position_cluster NULL)
--      bleibt von den vier genannten Feldern nur noch created_at uebrig. Ohne
--      die anderen drei quasi-identifizierenden Merkmale ist ein Anlagedatum
--      allein, kombiniert mit einer bereits anonymisierten Zeile (Pseudonym-
--      Name, kein Geburtsdatum, is_active=false), kein praktikabler
--      Re-Identifikationsweg mehr innerhalb eines Teams.
--   Wer diese Einschaetzung anders trifft (z.B. bei sehr kleinen Kadern, wo
--   ein Anlagedatum allein schon auf einen bestimmten Transfer-Zeitpunkt
--   schliessen laesst), kann created_at in einer Folge-Migration ergaenzen --
--   hier bewusst ausgelassen statt eine Rueckfrage zu blockieren.
--
-- Punkt 91: app.rpc_rebuild_baseline_history prueft nicht, ob die Zielperson
-- noch aktiv ist. Ein Admin konnte fuer eine bereits geschredderte Person
-- (is_active = false) ueber diese RPC wieder leere Baselines mit Status
-- "reset" erzeugen -- neue Datenzeilen fuer eine Person, deren Spuren gerade
-- erst geloescht wurden. Fix: zusaetzlicher Guard nach der bestehenden
-- Team-Pruefung, Muster app.deny (wie die zwei bestehenden Guards dieser
-- Funktion -- kein RAISE, diese Funktion antwortet durchgehend per app.deny).
--
-- Punkt 92: die sechs in Commit 6c79ade ergaenzten DELETEs (app.baselines,
-- app.metric_deviations, app.readiness_score, app.readiness_factors_coach,
-- app.readiness_factor_medical, app.session_rpe) filtern zusaetzlich auf
-- team_id = v_team_id. Bei einem (heute technisch nicht moeglichen)
-- Teamwechsel blieben Alt-Zeilen mit der alten team_id stehen. person_id ist
-- eine global eindeutige uuid, der team_id-Filter ist hier unnoetig
-- einschraenkend -- die Berechtigungspruefung (Schritt 1: nur admin, nur fuer
-- eine Person im EIGENEN Team) hat bereits vorher stattgefunden. Fix: diese
-- sechs DELETEs filtern nur noch auf person_id. Die ANDEREN, schon vorher
-- vorhandenen DELETEs in derselben Funktion (daily_checkins, readiness_scores,
-- load_deviations, clearance_proposals, medical_clearances, access_log,
-- model_call_subjects/model_call_log/session_hint_dismissals) behalten ihren
-- team_id-Filter unveraendert -- Punkt 92 nennt ausdruecklich nur die sechs aus
-- Punkt 84/92, eine Ausweitung auf die aelteren DELETEs ist nicht Teil dieses
-- Funds und wuerde deren eigene, unabhaengige Historie veraendern.
--
-- app.rpc_shred_person Rumpf 1:1 aus backend/42_shred_person_load_readiness.sql,
-- CREATE OR REPLACE, Signatur/Rueckgabetyp/ACL unveraendert.
-- app.rpc_rebuild_baseline_history Rumpf 1:1 aus backend/33_baseline_engine.sql,
-- CREATE OR REPLACE, Signatur/Rueckgabetyp/ACL unveraendert.
-- Voraussetzung: 33_baseline_engine.sql, 42_shred_person_load_readiness.sql.
-- Idempotent. Tests: backend/46_shred_person_hardening.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app.rpc_rebuild_baseline_history — Guard: Zielperson muss aktiv sein
--    (Punkt 91)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_rebuild_baseline_history(p_person_id uuid, p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_count     int := 0;
  v_team_id   uuid;
  v_is_active boolean;
  d           date;
  m           app.app_metric;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('baselines.rebuild', 'FORBIDDEN: baselines.rebuild');
  END IF;

  IF NOT app.auth_has_role('admin') THEN
    RETURN app.deny('baselines.rebuild', 'FORBIDDEN: baselines.rebuild');
  END IF;

  SELECT team_id, is_active INTO v_team_id, v_is_active FROM app.persons WHERE id = p_person_id;
  IF v_team_id IS NULL OR v_team_id <> app.auth_team_id() THEN
    RETURN app.deny('baselines.rebuild', 'FORBIDDEN: baselines.rebuild');
  END IF;

  -- Punkt 91 (Review 2026-09-29): eine geschredderte Person (is_active=false)
  -- darf keine neuen Baseline-Zeilen mehr bekommen -- das Loeschrecht (Art. 17)
  -- wuerde sonst durch einen spaeteren Rebuild wieder unterlaufen.
  IF NOT COALESCE(v_is_active, false) THEN
    RETURN app.deny('baselines.rebuild', 'FORBIDDEN: baselines.rebuild (inactive)');
  END IF;

  d := p_from;
  WHILE d <= p_to LOOP
    FOR m IN SELECT metric FROM app.baseline_metric_config LOOP
      PERFORM app._compute_baseline(v_team_id, p_person_id, m, d);
      v_count := v_count + 1;
    END LOOP;
    d := d + 1;
  END LOOP;

  RETURN jsonb_build_object('recomputed', v_count);
END;
$$;

COMMENT ON FUNCTION app.rpc_rebuild_baseline_history(uuid, date, date) IS
  'Backfill der Baseline-Historie, admin only, nur eigenes Team. Punkt 91 (2026-09-29): '
  'lehnt eine geschredderte Zielperson (is_active=false) ab (deny) -- verhindert neue '
  'Baseline-Zeilen fuer eine Person nach Art. 17 DSGVO Loeschung. '
  'Siehe backend/33_baseline_engine.sql, backend/46_shred_person_hardening.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_rebuild_baseline_history(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_rebuild_baseline_history(uuid, date, date) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. app.rpc_shred_person — vier Quasi-Identifikatoren (Punkt 89), sechs
--    DELETEs nur noch auf person_id (Punkt 92)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_shred_person(p_person_id uuid)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_team_id       uuid;
  v_actor_id      uuid;
  v_auth_user_id  uuid;
  v_found         boolean;
  v_now           timestamptz := now();
BEGIN
  -- ---------------------------------------------------------------------------
  -- 1. Berechtigung. Nur admin, nur das eigene Team.
  -- ---------------------------------------------------------------------------
  IF NOT app.auth_has_role('admin') THEN
    PERFORM app.log_denial('persons.shred');
    RAISE EXCEPTION 'FORBIDDEN: persons.shred (only admin)' USING errcode = '42501';
  END IF;

  v_team_id  := app.auth_team_id();
  v_actor_id := app.auth_person_id();

  -- Die Person muss es im eigenen Team geben. v1 lief bei einer fremden oder
  -- unbekannten id still durch und meldete Erfolg.
  SELECT p.auth_user_id, true
    INTO v_auth_user_id, v_found
    FROM app.persons p
   WHERE p.id = p_person_id
     AND p.team_id = v_team_id;

  IF NOT coalesce(v_found, false) THEN
    RAISE EXCEPTION 'NOT_FOUND: persons.shred' USING errcode = 'P0002';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2. Nutzdaten. Fuer Trainingsbefinden besteht keine Aufbewahrungspflicht.
  --    Jedes DELETE hier erzeugt ueber app.audit_log_trigger() eine Audit Zeile
  --    mit vollstaendiger Kopie. Schritt 6 raeumt sie im selben Aufruf mit ab.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.daily_checkins    WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.readiness_scores  WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.load_deviations   WHERE person_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 2b. Fund beim Review von AP-69: Baseline-Engine, Readiness-Score v2 und
  --     Trainingslast (session_rpe) tragen ebenfalls person_id/team_id mit
  --     ON DELETE CASCADE auf app.persons, der nie greift (Schritt 5
  --     anonymisiert, loescht nicht).
  --     Punkt 92 (Review 2026-09-29): diese sechs DELETEs filtern NUR NOCH auf
  --     person_id (global eindeutige uuid) -- der team_id-Filter war hier
  --     unnoetig einschraenkend, die Berechtigungspruefung (Schritt 1, nur fuer
  --     eine Person im EIGENEN Team) hat bereits vorher stattgefunden. Bei
  --     einem (heute technisch nicht moeglichen) Teamwechsel raeumt der Pfad
  --     damit auch Alt-Zeilen mit einer frueheren team_id auf.
  --     readiness_factors_coach/readiness_factor_medical haengen zusaetzlich
  --     per score_id ON DELETE CASCADE an readiness_score; das DELETE dort
  --     steht trotzdem explizit, keine Abhaengigkeit von einem CASCADE.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.baselines               WHERE person_id = p_person_id;
  DELETE FROM app.metric_deviations       WHERE person_id = p_person_id;
  DELETE FROM app.readiness_factors_coach WHERE person_id = p_person_id;
  DELETE FROM app.readiness_factor_medical WHERE person_id = p_person_id;
  DELETE FROM app.readiness_score         WHERE person_id = p_person_id;
  DELETE FROM app.session_rpe             WHERE person_id = p_person_id;

  -- ---------------------------------------------------------------------------
  -- 3. Medizinische Freigaben (Entscheidung 1: loeschen).
  --    Vorbehalt der anwaltlichen Gegenprobe zu § 630f BGB: zaehlt die Freigabe
  --    des Mannschaftsarztes als aerztliche Dokumentation, sticht Art. 17 Abs. 3
  --    lit. b das Loeschrecht, und aus diesem DELETE wird eine Reduktion.
  -- ---------------------------------------------------------------------------
  -- AP-47a: die Vorschlaege der Physio zuerst, sie verweisen auf dieselbe Person.
  DELETE FROM app.clearance_proposals WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.medical_clearances  WHERE person_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 3b. AP-69 (ADR-019 T6): Aufrufprotokoll der Modellaufrufe und Wegklicks.
  --     Begruendung im Kommentar am Kopf von 20260927130100_jev_switch_model_call_log.sql.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.model_call_subjects WHERE person_id = p_person_id AND team_id = v_team_id;
  UPDATE app.model_call_log
     SET actor_id = NULL, actor_kind = 'job', job_key = 'shredded', actor_role = NULL
   WHERE actor_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.session_hint_dismissals WHERE person_id = p_person_id AND team_id = v_team_id;
  UPDATE app.session_hint_dismissals
     SET dismissed_by = NULL
   WHERE dismissed_by = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 4. Zugriffsprotokoll (Entscheidung 2). Jede Zeile nennt zwei Personen.
  --    Betroffene (subject_id): die Zeile gehoert dieser Person, sie geht.
  --    Handelnde (actor_id): die Zeile gehoert der betroffenen Person und ist ihr
  --    Nachweis darueber, wer in ihre Daten gesehen hat. Sie bleibt unveraendert,
  --    der Personenbezug ist ueber die anonymisierte persons Zeile aufgehoben.
  --    app.access_denials nennt nur Handelnde und bleibt deshalb ganz unberuehrt.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.access_log WHERE subject_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 5. Personenzeile anonymisieren. Crypto Shredding: die id bleibt, damit jeder
  --    Verweis auf die Person als Handelnde weiter traegt.
  --    Die Bedingung am Ende macht den zweiten Aufruf wirkungslos statt
  --    wirkungsgleich: ohne sie schriebe jeder weitere Shred eine neue Audit
  --    Zeile und vergaebe einen neuen Pseudonymnamen.
  --
  --    Punkt 89 (Review 2026-09-29, WICHTIGSTER Fund): shirt_number,
  --    person_position und position_cluster kommen dazu -- in Kombination
  --    identifizieren sie eine Person in einem Kader praktisch eindeutig, das
  --    Pseudonym waere sonst trivial aufloesbar. created_at bleibt bewusst
  --    stehen (Systemfeld ohne fachlichen Personenbezug, kein praktikables
  --    Re-Identifikationsmerkmal ohne die drei genannten Felder -- Begruendung
  --    im Kopfkommentar dieser Migration).
  -- ---------------------------------------------------------------------------
  UPDATE app.persons
     SET display_name    = 'SCRAPED-' || substr(md5(random()::text), 1, 8),
         auth_user_id    = NULL,
         birth_date      = NULL,
         is_active       = false,
         -- AP-43: die Darstellungspraeferenz der Body Map faellt auf die Vorgabe
         -- zurueck. Sie ist kein Geschlechtsfeld, aber an einer namenlosen Zeile
         -- ist sie eine Restangabe ueber einen Menschen ohne jeden Zweck.
         body_map_figure = 'aus_dem_team',
         shirt_number     = NULL,
         person_position  = NULL,
         position_cluster = NULL,
         -- Nachtrag Review-Fund (2026-09-29, HOCH): baseline_engine
         -- (20260924000045) hat primary_position/secondary_positions zu
         -- app.persons hinzugefuegt, NACH dem urspruenglichen Entwurf von
         -- Punkt 89 -- sie fehlten deshalb im ersten Wurf dieser Migration.
         -- Beide sind exakt dieselbe Art Quasi-Identifikator wie
         -- person_position/position_cluster (Positionsangabe der Person) und
         -- muessen aus demselben Grund auf NULL.
         primary_position     = NULL,
         secondary_positions  = NULL,
         updated_at      = v_now
   WHERE id = p_person_id
     AND team_id = v_team_id
     AND (auth_user_id IS NOT NULL
          OR birth_date IS NOT NULL
          OR is_active
          OR body_map_figure <> 'aus_dem_team'
          OR display_name NOT LIKE 'SCRAPED-%'
          OR shirt_number IS NOT NULL
          OR person_position IS NOT NULL
          OR position_cluster IS NOT NULL
          OR primary_position IS NOT NULL
          OR secondary_positions IS NOT NULL);

  -- ---------------------------------------------------------------------------
  -- 6. audit_log. Laeuft ZULETZT, und das ist der Grundsatz des ganzen Pfads:
  --    app.audit_log_trigger() kopiert mit to_jsonb(OLD) und to_jsonb(NEW) ganze
  --    Zeilen. Die Schritte 2 bis 5 haben also gerade neue Kopien erzeugt. Weil
  --    diese Kopien denselben Personenbezug tragen, erfasst der Schritt sie mit.
  --    Liefe er frueher, raeumte der Pfad auf und fuellte danach nach.
  --
  --    Geleert wird der Inhalt, nicht die Zeile: table_name, row_id, operation,
  --    actor_id, actor_role und occurred_at bleiben stehen. Damit bleibt
  --    belegbar, DASS es eine Aenderung gab (Art. 5 Abs. 2, Art. 32), ohne den
  --    Inhalt zu behalten. Nebeneffekt, der gewollt ist: ein Shred taugt damit
  --    nicht zum Verwischen von Spuren.
  --
  --    Zwei Referenzformen, und nur diese zwei:
  --      a) person_id im jsonb  (daily_checkins, readiness_scores,
  --         medical_clearances, load_deviations)
  --      b) id im jsonb bei table_name = 'persons'  (dort stehen display_name
  --         und birth_date im Klartext)
  --    Verweise auf Handelnde (actor_id, set_by, proposed_by, reviewed_by)
  --    bleiben ausdruecklich unberuehrt, siehe Kopf der Datei.
  --
  --    app.audit_log traegt selbst keinen Trigger, dieses UPDATE erzeugt also
  --    keine neue Zeile. Die sechs Tabellen aus Schritt 2b tragen ebenfalls
  --    keinen Audit Trigger (siehe Kopfkommentar von backend/42_shred_person_
  --    load_readiness.sql), fuer sie entstehen also keine neuen Kopien, die
  --    dieser Schritt erfassen muesste.
  -- ---------------------------------------------------------------------------
  UPDATE app.audit_log a
     SET old_row = CASE WHEN a.old_row IS NULL THEN NULL
                        ELSE jsonb_build_object('shredded_at', v_now) END,
         new_row = CASE WHEN a.new_row IS NULL THEN NULL
                        ELSE jsonb_build_object('shredded_at', v_now) END
   WHERE a.team_id = v_team_id
     AND (a.old_row IS NOT NULL OR a.new_row IS NOT NULL)
     AND (
           a.old_row ->> 'person_id' = p_person_id::text
        OR a.new_row ->> 'person_id' = p_person_id::text
        OR (a.table_name = 'persons'
            AND (a.old_row ->> 'id' = p_person_id::text
                 OR a.new_row ->> 'id' = p_person_id::text))
         );

  -- ---------------------------------------------------------------------------
  -- 7. Abschlusszeile. Traegt keinen Inhalt: die Person steht in row_id, nicht
  --    im jsonb. Stuende sie im jsonb, loeschte ein zweiter Shred die
  --    Abschlusszeile des ersten wieder leer.
  -- ---------------------------------------------------------------------------
  INSERT INTO app.audit_log (team_id, table_name, row_id, operation, actor_id, actor_role, old_row, new_row)
  VALUES (
    v_team_id, 'persons', p_person_id, 'DELETE',
    v_actor_id, 'admin'::app.app_role,
    NULL, jsonb_build_object('action', 'crypto_shred', 'shredded_at', v_now)
  );

  -- ---------------------------------------------------------------------------
  -- 8. Das Auth Konto liegt im Schema auth und wird ueber die Admin API geloescht,
  --    nicht per SQL. Ohne diesen zweiten Schritt bliebe die E-Mail Adresse
  --    gespeichert und machte das Pseudonym wieder aufloesbar.
  --    NULL heisst: kein Konto zu loeschen (nie eines gehabt, oder schon geshreddet).
  -- ---------------------------------------------------------------------------
  RETURN v_auth_user_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM PUBLIC, anon;
-- KEIN GRANT fuer authenticated (Punkt 55, siehe 30_clearance_proposals.sql).
REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM authenticated;

COMMENT ON FUNCTION app.rpc_shred_person(uuid) IS
  'Art. 17 DSGVO. Loescht alle Spuren einer Person in app.*, anonymisiert die '
  'Personenzeile und leert den Inhalt der zugehoerigen audit_log Zeilen, ohne '
  'deren Metadaten aufzugeben. Gibt die alte auth_user_id zurueck, damit das '
  'Auth Konto im zweiten Schritt ueber die Admin API geloescht werden kann '
  '(scripts/shred-auth-user.mjs). AP-39b. '
  'AP-47a (2026-09-22): app.clearance_proposals kommt in Schritt 3 dazu. '
  'AP-69 (2026-09-27): Schritt 3b, model_call_subjects geloescht, model_call_log-Ausloeser '
  'anonymisiert, session_hint_dismissals fuer die Person geloescht, dismissed_by NULL. '
  '2026-09-27 (Review-Fund): Schritt 2b, sechs bislang uebersehene Tabellen mit '
  'person_id/team_id (baselines, metric_deviations, readiness_score, '
  'readiness_factors_coach, readiness_factor_medical, session_rpe) ergaenzt. '
  'Punkt 89 (2026-09-29, WICHTIGSTER Fund): shirt_number/person_position/position_cluster/'
  'primary_position/secondary_positions werden in Schritt 5 zusaetzlich auf NULL gesetzt '
  '(Quasi-Identifikatoren, sonst trivial aufloesbares Pseudonym) -- created_at bleibt bewusst '
  'stehen, Begruendung im Kopfkommentar von backend/46_shred_person_hardening.sql. '
  'Nachtrag (2026-09-29, Review-Fund): primary_position/secondary_positions (baseline_engine, '
  '20260924000045) im ersten Wurf uebersehen, jetzt ergaenzt. Punkt 92: die sechs DELETEs aus '
  'Schritt 2b filtern nur noch auf person_id, nicht mehr zusaetzlich auf team_id.';
