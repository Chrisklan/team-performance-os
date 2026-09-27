-- =============================================================================
-- 20260927140000_shred_person_load_readiness.sql — app.rpc_shred_person:
-- sechs vergessene Tabellen mit person_id/team_id, ON DELETE CASCADE nutzlos
--
-- Fund beim Review von AP-69 (Aufrufprotokoll, backend/41): app.baselines,
-- app.metric_deviations, app.readiness_score, app.readiness_factors_coach,
-- app.readiness_factor_medical (alle aus 20260924000045_baseline_engine.sql
-- bzw. 20260925000046_readiness_score.sql) und app.session_rpe (aus
-- 20260927120000_training_load.sql) tragen alle
-- "person_id uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE".
-- Der CASCADE greift nie: Schritt 5 des Loeschpfads loescht die persons-Zeile
-- nie, er anonymisiert sie nur per UPDATE (Crypto Shredding, Kommentar am Kopf
-- von 20260927130100_jev_switch_model_call_log.sql). Sechs personenbezogene
-- Tabellen blieben damit nach jedem Shred vollstaendig stehen, mit Klartext-
-- Messwerten (readiness_factor_medical.value_full, baselines.median/mad,
-- session_rpe.rpe) unter derselben nun pseudonymisierten person_id.
--
-- Rein additiv: Rumpf 1:1 aus 20260927130100_jev_switch_model_call_log.sql
-- Zeile 500-663 uebernommen, nur sechs neue DELETEs in Schritt 2 ergaenzt, an
-- der Stelle der anderen personenbezogenen Kennzahlen. Keine der sechs
-- Tabellen traegt den Audit Trigger (grep bestaetigt: kein
-- audit_log_trigger auf baselines/metric_deviations/readiness_score/
-- readiness_factors_coach/readiness_factor_medical/session_rpe), Schritt 6
-- muss fuer sie nichts nachraeumen, wie schon bei model_call_subjects/
-- session_hint_dismissals in AP-69 festgehalten.
--
-- readiness_factors_coach und readiness_factor_medical haengen zusaetzlich
-- ueber score_id ON DELETE CASCADE an readiness_score -- das DELETE auf
-- readiness_score raeumt sie technisch mit auf. Beide DELETEs stehen trotzdem
-- explizit da, aus demselben Grund wie beim Rest der Funktion: der Pfad soll
-- nicht von einem CASCADE abhaengen, den schon dieser Fund als bruechig
-- gezeigt hat, sondern von expliziten, lesbaren DELETEs mit derselben
-- WHERE-Form wie ueberall sonst in der Funktion.
--
-- app.role_assignments (auch person_id, auch ON DELETE CASCADE, auch nicht im
-- Loeschpfad) ist NICHT Teil dieser Migration -- separat zu klaeren, ob eine
-- Rollenzuweisung nach einem Shred geloescht oder (wie bislang wohl absichtlich)
-- stehen bleiben soll, um die Team-Historie nicht zu verfaelschen.
-- =============================================================================

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
  --     anonymisiert, loescht nicht). Ohne diese sechs DELETEs blieben
  --     Messwerte -- teils medizinisch (readiness_factor_medical.value_full)
  --     -- unter der nun pseudonymisierten person_id stehen.
  --     readiness_factors_coach/readiness_factor_medical haengen zusaetzlich
  --     per score_id ON DELETE CASCADE an readiness_score; das DELETE dort
  --     stehen trotzdem explizit, keine Abhaengigkeit von einem CASCADE.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.baselines               WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.metric_deviations       WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.readiness_factors_coach WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.readiness_factor_medical WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.readiness_score         WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.session_rpe             WHERE person_id = p_person_id AND team_id = v_team_id;

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
  --     Begruendung im Kommentar ueber der Funktion in
  --     20260927130100_jev_switch_model_call_log.sql.
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
         updated_at      = v_now
   WHERE id = p_person_id
     AND team_id = v_team_id
     AND (auth_user_id IS NOT NULL
          OR birth_date IS NOT NULL
          OR is_active
          OR body_map_figure <> 'aus_dem_team'
          OR display_name NOT LIKE 'SCRAPED-%');

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
  --    keinen Audit Trigger (siehe Kopfkommentar dieser Migration), fuer sie
  --    entstehen also keine neuen Kopien, die dieser Schritt erfassen muesste.
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
  'readiness_factors_coach, readiness_factor_medical, session_rpe) ergaenzt -- '
  'deren ON DELETE CASCADE auf persons griff nie, weil die Personenzeile nie '
  'geloescht, nur anonymisiert wird.';
