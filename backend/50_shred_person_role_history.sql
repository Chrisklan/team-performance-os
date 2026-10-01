-- =============================================================================
-- 50_shred_person_role_history.sql — Security-Re-Review-Funde (2026-09-30),
-- Punkte 90, 97, 98. Entscheidung mit Chris (Projektinhaber) am 2026-09-30.
--
-- Punkt 98 (ErwG 26 DSGVO, Re-Identifikationsrisiko): app.persons.created_at
-- blieb nach dem Schreddern bislang unveraendert stehen (bewusste Entscheidung
-- in backend/46_shred_person_hardening.sql, siehe deren Kopfkommentar). Fuer
-- Spieler, die einzeln als Wintertransfer o.ae. eingepflegt werden -- nicht als
-- Teil des initialen Kader-Bulk-Imports -- liegt created_at nah am echten,
-- haeufig oeffentlich bekannten Transferdatum. Entscheidung: created_at
-- zusaetzlich auf Monatsgenauigkeit runden (date_trunc('month', ...)) statt es
-- unveraendert zu lassen oder auf NULL zu setzen. Monatsgenauigkeit statt
-- Loeschen/NULL, weil created_at weiterhin belegt, DASS und UNGEFAEHR WANN eine
-- Personenzeile angelegt wurde (Nachvollziehbarkeit, Konsistenz mit dem
-- Audit-Log-Grundsatz aus Schritt 6: Metadaten bleiben, Inhalt wird
-- vergroebert) -- ein exaktes Transferdatum als Quasi-Identifikator faellt
-- damit weg, ohne jede zeitliche Einordnung zu kappen.
--
-- Punkt 90/97 (funktionales Risiko + gleicher Zeitanker wie Punkt 98):
-- app.role_assignments wurde vom Schredder-Pfad bislang gar nicht angefasst.
-- Eine offene Zuweisung (valid_to IS NULL) einer geschredderten Person blieb
-- aktiv -- Guards, die role_assignments joinen, koennten eine geschredderte
-- Person faelschlich weiter als aktiven Rolleninhaber sehen, falls sie nicht
-- zusaetzlich app.persons.is_active pruefen. Zusaetzlich ist valid_from (und
-- ein gesetztes valid_to) derselbe Typ Zeitanker wie created_at. Entscheidung,
-- konsistent zu Punkt 98:
--   a) jede Zuweisung schliessen, die noch aktiv ist oder es werden koennte
--      (offen, oder valid_to in der Zukunft) -- siehe H2 unten.
--   b) valid_from UND valid_to (falls gesetzt) aller role_assignments-Zeilen
--      dieser Person auf Monatsgenauigkeit runden.
--   c) jede Zeile, die dadurch now() erreichen oder in der Zukunft liegen
--      wuerde, wird stattdessen geloescht -- siehe H-NEU unten.
-- Historie wird in aller Regel NICHT geloescht, nur geschlossen und
-- vergroebert -- der Nachweis "es gab eine Aktivitaet in diesem Zeitraum"
-- bleibt erhalten, der Personenbezug (exaktes Datum) wird unscharf.
--
-- =============================================================================
-- VORGESCHICHTE UND VEREINFACHUNG (2026-10-01): drei aufeinanderfolgende
-- Fix-Runden (Code-/Security-Review, dann ein "dritter Durchlauf" mit echtem
-- Postgres-Testlauf) bauten eine Zweiphasen-Platzhalter-Technik: jede Zeile
-- wurde zunaechst auf einen kollisionsfreien Platzhalter im Jahr 9999
-- verschoben, danach erst auf ihren echten Zielwert geschrieben -- mit einer
-- eigenen, von der chronologischen Berechnung getrennten Reihenfolge fuer
-- Phase 1 (die urspruenglich offene Zeile zuerst), weil eine nach oben
-- unbeschraenkte Zeile sonst mit jeder bereits verschobenen Nachbarzeile
-- kollidierte. Grund fuer den ganzen Aufwand: role_assignments_one_active_role
-- (EXCLUDE USING gist auf app.role_assignments, siehe backend/08_reconciling.sql)
-- war NICHT deferrable -- Postgres pruefte sie nach JEDER einzelnen
-- Zeilenaenderung sofort, nicht erst am Ende der Transaktion. Jede Umordnung
-- mehrerer Zeilen unter derselben Mutual-Exclusion-Constraint musste deshalb
-- kollisionsfrei VOR jedem Zwischenschritt bleiben.
--
-- Das ist exakt der Fall, fuer den Postgres deferrable Constraints vorsieht:
-- mehrere Zeilen unter einer Exclude-/Unique-Regel innerhalb EINER Transaktion
-- neu anordnen, ohne dass die Schreibreihenfolge etwas zur Sache tut. Fix
-- (diese Fassung): die Constraint wird per DROP/ADD CONSTRAINT ... DEFERRABLE
-- INITIALLY IMMEDIATE umgestellt (siehe unten, vor der Funktion -- Details
-- und der genaue Grund fuer DROP/ADD statt ALTER CONSTRAINT dort).
-- "INITIALLY IMMEDIATE" aendert das STANDARDVERHALTEN fuer alle anderen Aufrufe
-- NICHT -- sie wird weiterhin sofort nach jeder Zeilenaenderung geprueft, AUSSER
-- eine Transaktion sagt explizit SET CONSTRAINTS ... DEFERRED, wie es
-- app.rpc_shred_person jetzt zu Beginn von Schritt 5b tut. Innerhalb dieser
-- einen Transaktion wird die Constraint dann erst am Transaktionsende (beim
-- COMMIT des RPC-Aufrufs) geprueft -- die Schreibreihenfolge innerhalb der
-- Funktion ist damit beliebig, der komplette Zweiphasen-Platzhalter-Mechanismus
-- (Jahr-9999-Verschiebung, getrennte Phase-1-Reihenfolge, Sonderbehandlung der
-- offenen/unendlichen Zeile) entfaellt ersatzlos.
--
-- Was bleibt, weil es ein eigenstaendiges fachliches bzw. technisches Problem
-- ist, keine Umgehung der Constraint:
--   - Die chronologische Verkettung (jede Zeile beginnt fruehestens dort, wo
--     die vorherige endet) bleibt -- das ist die eigentliche fachliche
--     Korrektheit (Punkt 97), nicht nur ein Weg, die Constraint zu erfuellen.
--   - H2 (Schliessbedingung: offen ODER valid_to > now()) bleibt unveraendert.
--   - H-NEU (Jetzt-/Zukunfts-Deckel nach der Verkettung, Zeilen im laufenden
--     Monat oder spaeter werden geloescht statt behalten) bleibt unveraendert
--     -- Punkt 90 verlangt weiterhin, dass keine verbleibende Zeile now()
--     erreicht oder vollstaendig in der Zukunft liegt.
--   - N1 (zeitzonenfeste Monatsaddition ueber date_add(..., 'UTC')) bleibt.
--   - M1 (date_trunc(..., 'UTC') statt sitzungszeitzonenabhaengig) bleibt.
--   - B2 (role_assignments.created_at runden) bleibt.
-- Was ERSATZLOS entfaellt: die Zweiphasen-Platzhalter-Schreibung selbst, die
-- Sonderbehandlung der urspruenglich offenen/unendlichen Zeile fuer die
-- Verschiebe-Reihenfolge (B-4-Fall, siehe unten), und alle dafuer noetigen
-- Zwischen-Arrays. Die Funktion schreibt jetzt direkt, pro Zeile, in derselben
-- Schleife, die auch die Verkettung berechnet.
--
-- B-4 (entfaellt von selbst): eine Zuweisung mit valid_to = 'infinity' verhielt
-- sich fuer die alte Platzhalter-Technik genauso wie valid_to IS NULL (beide
-- sind nach oben unbeschraenkt) und brauchte dort dieselbe Sonderbehandlung.
-- Mit einer deferred Constraint spielt es keine Rolle mehr, ob eine Zeile
-- valid_to = NULL, valid_to = 'infinity' oder ein endliches Datum hat, oder in
-- welcher Reihenfolge die Zeilen geschrieben werden -- H2 schliesst 'infinity'
-- ueber dieselbe Bedingung (valid_to > v_now) wie jede andere noch nicht
-- abgelaufene Zuweisung, ohne eigenen Code dafuer. Test: siehe
-- backend/50_shred_person_role_history.pgtap.sql, Person mit einer
-- valid_to = 'infinity'-Zeile plus einer historischen Zeile.
--
-- N-7 (Security-Review, Defense in Depth, billig mitgemacht): die sortierte
-- Abfrage der Zeilen dieser Person steht jetzt unter FOR UPDATE, und jedes
-- UPDATE/DELETE auf role_assignments in dieser Funktion filtert zusaetzlich
-- explizit auf person_id = p_person_id -- Schutz gegen ein theoretisches Race
-- mit einem gleichzeitigen Admin-UPDATE, das person_id einer Zeile umhaengt,
-- waehrend diese Funktion laeuft.
--
-- N-6: das DELETE aus dem H-NEU-Deckel (Schritt 5b) erzeugt KEINE eigene
-- Audit-Zeile -- app.audit_log_trigger() ist nicht an app.role_assignments
-- gebunden (siehe Schritt 5b unten und Schritt 6).
--
-- M-5 (Praezisierung, mit Chris akzeptiert): bei mehreren dichten
-- Rollenwechseln kann die chronologische Verkettung den Beginn einer Zeile,
-- die urspruenglich VOR dem laufenden Monat begann, so weit anheben, dass sie
-- rechnerisch im laufenden Monat landet und deshalb vom H-NEU-Deckel geloescht
-- wird -- nicht nur Zeilen, die im Original bereits im laufenden Monat
-- begannen. Das ist kein Fehlverhalten (die verkettete, gerundete Zeile ist
-- die massgebliche), nur eine ehrliche Klarstellung: "begann im laufenden
-- Monat" bezieht sich auf das BERECHNETE, nicht das urspruengliche valid_from.
--
-- B1/B2/H2/M1/N1/H-NEU-Fundbegruendung im Detail (Datum, Review, Beispiele)
-- unveraendert wie in frueheren Fassungen dieser Datei dokumentiert; diese
-- Fassung beschreibt nur noch die jetzige, vereinfachte Umsetzung.
--
-- H1 (Restrisiko, EXPLIZITE Entscheidung mit Chris, Option B gewaehlt,
-- 2026-10-01): app.audit_log.occurred_at der Person WIRD NICHT gerundet.
-- Audit-Log-Integritaet hat Vorrang, Zugriff ist Admin-only und selbst
-- protokolliert -- das verbleibende Re-Identifikationsrisiko ueber den exakten
-- occurred_at-Zeitpunkt einer Audit-Zeile wird damit bewusst akzeptiert statt
-- durch eine Vergroeberung der ohnehin schon reduzierten Audit-Historie
-- (siehe Schritt 6) weiter aufzuweichen.
--
-- Rundungs-Randfall (bleibt unveraendert gegenueber frueheren Fassungen):
-- rundet man valid_from und valid_to unabhaengig voneinander auf den
-- Monatsanfang ab, koennen beide im selben Kalendermonat auf denselben Wert
-- fallen (z.B. eine sehr kurze Zuweisung vom 5. bis 20. September). Die
-- Tabellen-Constraint role_assignments_valid_range verlangt aber
-- valid_to > valid_from (strikt) -- ein gleicher, abgerundeter Wert wuerde die
-- Zeile verletzen. Fix: faellt der abgerundete valid_to nicht ECHT groesser
-- aus als der (ggf. durch die Verkettung zur Vorzeile schon angehobene) eigene
-- valid_from, wird valid_to stattdessen auf den naechsten Monatsanfang NACH
-- dem eigenen valid_from angehoben (weiterhin ein exakter Monats-Grenzwert,
-- nur nach oben statt nach unten vergroebert).
--
-- Reihenfolge: die role_assignments-Aenderung (Schritt 5b) laeuft NACH der
-- Personenzeilen-Anonymisierung (Schritt 5) und VOR dem finalen audit_log-
-- Schritt (Schritt 6) -- der audit_log-Trigger kopiert dann bereits die
-- vergroeberten Werte mit, falls je einer auf role_assignments aktiv waere.
-- Geprueft (siehe backend/08_reconciling.sql, backend/09_rpcs.sql,
-- backend/30_clearance_proposals.sql): app.audit_log_trigger() ist aktuell NUR
-- an app.medical_clearances, app.persons, app.readiness_scores,
-- app.load_deviations, app.daily_checkins und app.clearance_proposals
-- gebunden -- NICHT an app.role_assignments. Der neue Schritt 5b erzeugt also
-- heute keine eigene Audit-Zeile ueber einen Trigger; sollte kuenftig ein
-- Audit-Trigger auf role_assignments ergaenzt werden, faengt die bestehende
-- Reihenfolge (5b vor 6) das automatisch korrekt ein, ohne dass diese Funktion
-- dann nochmal angefasst werden muesste.
--
-- Idempotenz: sowohl der created_at-Teil von Schritt 5 als auch Schritt 5b
-- sind so gebaut, dass ein zweiter Aufruf von rpc_shred_person fuer dieselbe,
-- bereits geschredderte Person (innerhalb desselben Zeitfensters -- siehe
-- M1/H2-Begruendung oben) zum selben Ergebnis kommt: weder
-- app.persons.created_at noch irgendeine role_assignments-Zeile dieser Person
-- aendert sich dadurch ein zweites Mal sichtbar. Schritt 5b fuehrt dafuer bei
-- jedem Aufruf die vollstaendige Berechnung erneut aus -- das ist bewusst
-- einfacher als eine Vorab-Pruefung "hat sich ueberhaupt etwas geaendert",
-- weil role_assignments keinen Audit-Trigger besitzt (siehe oben) und ein
-- wirkungsgleiches Wiederschreiben der bereits korrekten Werte deshalb keine
-- Nebeneffekte erzeugt.
--
-- app.rpc_shred_person Rumpf 1:1 aus backend/46_shred_person_hardening.sql,
-- CREATE OR REPLACE, Signatur/Rueckgabetyp/ACL unveraendert.
-- Voraussetzung: backend/46_shred_person_hardening.sql (bzw. die davor
-- liegende Kette bis 14_shred_person.sql/42_shred_person_load_readiness.sql).
-- backend/46_shred_person_hardening.sql selbst bleibt unveraendert -- diese
-- Datei ueberschreibt app.rpc_shred_person zur Laufzeit per CREATE OR REPLACE,
-- wie in diesem Projekt etabliert (siehe CLAUDE.md, "NICHT ANFASSEN").
-- Idempotent. Tests: backend/50_shred_person_role_history.pgtap.sql.
-- =============================================================================

-- Postgres-Standardloesung fuer "mehrere Zeilen unter einer Exclude-Regel
-- innerhalb einer Transaktion neu anordnen": die Constraint deferrable machen.
-- INITIALLY IMMEDIATE aendert nichts am Standardverhalten fuer jeden anderen
-- Aufruf/jede andere Transaktion -- nur app.rpc_shred_person setzt sie unten
-- explizit per SET CONSTRAINTS auf DEFERRED, und nur fuer die Dauer des
-- eigenen Aufrufs. EXCLUDE-Constraints sind seit Postgres 9.4 deferrable-faehig
-- -- ABER (durch den echten Testlauf entdeckt, siehe "ECHTER TESTLAUF" weiter
-- unten): ALTER TABLE ... ALTER CONSTRAINT ... DEFERRABLE funktioniert in
-- Postgres NUR fuer FOREIGN-KEY-Constraints ("constraint ... is not a foreign
-- key constraint"), nicht fuer EXCLUDE/UNIQUE/PRIMARY KEY. Fuer diese muss die
-- Constraint DROP + mit DEFERRABLE neu ADD werden -- das baut den GiST-Index
-- einmalig neu auf (einmaliger Migrationskosten, kein laufzeitrelevanter
-- Unterschied danach).
ALTER TABLE app.role_assignments
  DROP CONSTRAINT role_assignments_one_active_role,
  ADD CONSTRAINT role_assignments_one_active_role EXCLUDE USING gist (
    person_id WITH =,
    tstzrange(valid_from, valid_to) WITH &&
  ) DEFERRABLE INITIALLY IMMEDIATE;

CREATE OR REPLACE FUNCTION app.rpc_shred_person(p_person_id uuid)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_team_id         uuid;
  v_actor_id        uuid;
  v_auth_user_id    uuid;
  v_found           boolean;
  v_now             timestamptz := now();
  -- Schritt 5b: chronologische Verkettung + H-NEU-Deckel, siehe Kopfkommentar.
  v_ra_row          record;
  v_prev_valid_to   timestamptz;
  v_this_from       timestamptz;
  v_this_to         timestamptz;
  v_closing_raw     timestamptz;
  v_capped_to       timestamptz;
  v_month_now       timestamptz;
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
  --    Pseudonym waere sonst trivial aufloesbar.
  --
  --    Punkt 98 (Security-Re-Review 2026-09-30): created_at wird jetzt, anders
  --    als in backend/46_shred_person_hardening.sql begruendet, zusaetzlich auf
  --    Monatsgenauigkeit gerundet -- Begruendung im Kopfkommentar dieser Datei
  --    (Wintertransfer-Einzelzugang, oeffentlich bekanntes Transferdatum,
  --    ErwG 26 DSGVO). M1-Fix: explizit date_trunc(..., 'UTC') statt
  --    zeitzonenabhaengigem date_trunc('month', created_at) -- siehe
  --    Kopfkommentar, Abschnitt M1.
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
         -- Punkt 98 (2026-09-30) + M1-Fix: created_at auf Monatsgenauigkeit
         -- runden, zeitzonenunabhaengig. Siehe Kopfkommentar dieser Datei.
         created_at       = date_trunc('month', created_at, 'UTC'),
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
          OR secondary_positions IS NOT NULL
          OR created_at <> date_trunc('month', created_at, 'UTC'));

  -- ---------------------------------------------------------------------------
  -- 5b. Punkt 90/97 (Security-Re-Review 2026-09-30): role_assignments der
  --     Person schliessen und vergroebern -- zeilenuebergreifend statt
  --     isoliert, und garantiert ohne verbleibenden Zeitraum, der now()
  --     erreicht/ueberschreitet oder vollstaendig in der Zukunft liegt.
  --     Ausfuehrliche Begruendung (Vereinfachung ueber eine deferred
  --     Constraint statt der frueheren Zweiphasen-Platzhalter-Technik, H2,
  --     H-NEU, M1, N1, B2, B-4) im Kopfkommentar dieser Datei.
  --
  --     Die Constraint wird NUR fuer diese eine Transaktion (den aktuellen
  --     RPC-Aufruf) nach hinten verschoben -- sie wird am Ende dieser
  --     Transaktion trotzdem geprueft, nur nicht mehr nach jeder einzelnen
  --     Zeilenaenderung. Jede andere Transaktion/jeder andere Aufruf prueft
  --     weiterhin sofort (INITIALLY IMMEDIATE, siehe ALTER TABLE oben).
  -- ---------------------------------------------------------------------------
  SET CONSTRAINTS role_assignments_one_active_role DEFERRED;

  v_prev_valid_to := NULL;
  v_month_now := date_trunc('month', v_now, 'UTC');

  -- N-7 (Security-Review, Defense in Depth): FOR UPDATE sperrt die Zeilen
  -- dieser Person fuer die Dauer der Transaktion gegen ein gleichzeitiges
  -- Admin-UPDATE, das person_id umhaengen wuerde.
  FOR v_ra_row IN
    SELECT id, valid_from, valid_to, created_at
      FROM app.role_assignments
     WHERE person_id = p_person_id
     ORDER BY valid_from, id
     FOR UPDATE
  LOOP
    -- Eigener Beginn: Monatsanfang abrunden (UTC, M1-Fix), aber nie vor dem
    -- Ende der Vorzeile (chronologische Verkettung, Punkt 97).
    v_this_from := date_trunc('month', v_ra_row.valid_from, 'UTC');
    IF v_prev_valid_to IS NOT NULL AND v_this_from < v_prev_valid_to THEN
      v_this_from := v_prev_valid_to;
    END IF;

    -- H2-Fix: schliessen, wenn offen (valid_to IS NULL) ODER das Ende noch in
    -- der Zukunft liegt (valid_to > v_now) -- deckt wegen valid_to > v_now
    -- automatisch auch valid_to = 'infinity' ab (B-4), ohne eigenen Sonderfall.
    -- GREATEST(v_now, valid_from) statt schlicht v_now deckt zusaetzlich eine
    -- noch nicht begonnene Zuweisung (valid_from > v_now) ab, ohne CHECK
    -- role_assignments_valid_range zu verletzen.
    IF v_ra_row.valid_to IS NULL OR v_ra_row.valid_to > v_now THEN
      v_closing_raw := GREATEST(v_now, v_ra_row.valid_from);
    ELSE
      v_closing_raw := v_ra_row.valid_to;
    END IF;

    v_this_to := date_trunc('month', v_closing_raw, 'UTC');

    -- Rundungs-Randfall: faellt das gerundete Ende nicht ECHT nach dem eigenen
    -- (ggf. durch die Verkettung zur Vorzeile schon angehobenen) Beginn, auf
    -- den naechsten Monatsanfang NACH dem eigenen Beginn anheben. N1-Fix:
    -- date_add(..., 'UTC') statt der session-zeitzonenabhaengigen
    -- timestamptz + interval '1 month'-Operation.
    IF v_this_to <= v_this_from THEN
      v_this_to := date_add(v_this_from, interval '1 month', 'UTC');
    END IF;

    v_prev_valid_to := v_this_to;

    -- H-NEU-Fix: Jetzt-/Zukunfts-Deckel. Eine Zeile, deren (bereits
    -- ueberlappungsfrei berechnetes) valid_from im laufenden Monat oder
    -- spaeter liegt, traegt keine schuetzenswerte "es gab Aktivitaet vor dem
    -- aktuellen Monat"-Information mehr -- loeschen statt behalten. Sonst
    -- valid_to zusaetzlich hart auf LEAST(valid_to, v_month_now) deckeln;
    -- kollabiert die Zeile dadurch (gedeckeltes valid_to <= valid_from), auch
    -- sie loeschen. Der Deckel wirkt nur verkuerzend/entfernend auf das
    -- Ergebnis der bereits ueberlappungsfreien Verkettung -- das kann keine
    -- neue Ueberlappung erzeugen.
    IF v_this_from >= v_month_now THEN
      DELETE FROM app.role_assignments WHERE id = v_ra_row.id AND person_id = p_person_id;
    ELSE
      v_capped_to := LEAST(v_this_to, v_month_now);
      IF v_capped_to <= v_this_from THEN
        DELETE FROM app.role_assignments WHERE id = v_ra_row.id AND person_id = p_person_id;
      ELSE
        -- B2-Fix: role_assignments.created_at wird ebenso gerundet wie
        -- app.persons.created_at (Punkt 98) -- dieselbe Luecke, dieselbe
        -- Spalte einer anderen Tabelle, per RLS fuer das ganze Team lesbar.
        UPDATE app.role_assignments
           SET valid_from = v_this_from,
               valid_to   = v_capped_to,
               created_at = date_trunc('month', v_ra_row.created_at, 'UTC')
         WHERE id = v_ra_row.id AND person_id = p_person_id;
      END IF;
    END IF;
  END LOOP;

  -- H1-Haertung (Security-Review, 2026-10-01): die Constraint fuer den Rest
  -- der aufrufenden Transaktion wieder auf sofortige Pruefung zurueckstellen.
  -- Saubererer Zustand nach der Funktion (ein nachfolgender Teil derselben
  -- Transaktion soll sich nicht auf einen laenger als noetig deferred
  -- Zustand verlassen), und ein evtl. verbleibender Fehler erscheint dadurch
  -- sofort hier statt erst spaeter, moeglicherweise an ganz anderer Stelle,
  -- beim COMMIT des Aufrufers.
  SET CONSTRAINTS app.role_assignments_one_active_role IMMEDIATE;

  -- ---------------------------------------------------------------------------
  -- 6. audit_log. Laeuft ZULETZT, und das ist der Grundsatz des ganzen Pfads:
  --    app.audit_log_trigger() kopiert mit to_jsonb(OLD) und to_jsonb(NEW) ganze
  --    Zeilen. Die Schritte 2 bis 5b haben also gerade neue Kopien erzeugt. Weil
  --    diese Kopien denselben Personenbezug tragen, erfasst der Schritt sie mit.
  --    Liefe er frueher, raeumte der Pfad auf und fuellte danach nach.
  --
  --    Geleert wird der Inhalt, nicht die Zeile: table_name, row_id, operation,
  --    actor_id, actor_role und occurred_at bleiben stehen. Damit bleibt
  --    belegbar, DASS es eine Aenderung gab (Art. 5 Abs. 2, Art. 32), ohne den
  --    Inhalt zu behalten. Nebeneffekt, der gewollt ist: ein Shred taugt damit
  --    nicht zum Verwischen von Spuren.
  --
  --    H1 (Restrisiko, explizite Entscheidung mit Chris, Option B, 2026-10-01):
  --    occurred_at bleibt bewusst UNGERUNDET stehen -- Audit-Log-Integritaet
  --    hat Vorrang, Zugriff ist Admin-only und selbst protokolliert. Siehe
  --    Kopfkommentar dieser Datei, Abschnitt H1.
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
  --    dieser Schritt erfassen muesste. Dasselbe gilt fuer role_assignments
  --    (Schritt 5b, N-6, siehe dort).
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
  '(Quasi-Identifikatoren, sonst trivial aufloesbares Pseudonym). '
  'Punkt 92: die sechs DELETEs aus Schritt 2b filtern nur noch auf person_id, nicht mehr '
  'zusaetzlich auf team_id. '
  'Punkt 98 (2026-09-30, Security-Re-Review): created_at wird in Schritt 5 zusaetzlich auf '
  'Monatsgenauigkeit gerundet, statt unveraendert zu bleiben -- '
  'Re-Identifikationsrisiko bei einzeln eingepflegten Wintertransfers (ErwG 26 DSGVO). '
  'Punkt 90/97 (2026-09-30): Schritt 5b schliesst role_assignments-Zeilen der Person und '
  'rundet valid_from/valid_to auf Monatsgenauigkeit, zeilenuebergreifend verkettet, mit '
  'Jetzt-/Zukunfts-Deckel (H-NEU) -- keine verbleibende Zeile erreicht now() oder liegt '
  'vollstaendig in der Zukunft. '
  '2026-10-01 (Vereinfachung): role_assignments_one_active_role wurde deferrable gemacht '
  '(siehe ALTER TABLE am Kopf dieser Datei) und wird in Schritt 5b per SET CONSTRAINTS ... '
  'DEFERRED nur fuer diesen einen Aufruf nach hinten verschoben -- ersetzt die zuvor dafuer '
  'gebaute Zweiphasen-Platzhalter-Technik (drei Fix-Runden, siehe Versionsgeschichte) durch '
  'den Postgres-Standardmechanismus fuer diesen Fall. Details im Kopfkommentar dieser Datei.';
