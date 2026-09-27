-- =============================================================================
-- 38_training_load.sql — Modul 6, Trainingsplanung (AP-68)
--
-- Liefert die fehlende Lastquelle fuer die Baseline-Engine: session_load und
-- acute_chronic_ratio auf app.daily_checkins sind seit 33_baseline_engine.sql
-- strukturell immer 0 Beobachtungen ("Trainingsmanagement-Modul, nicht
-- gebaut" -- siehe Kommentar dort, in dieser Migration korrigiert). SIG-03
-- "Schlaf plus Last" und SIG-04 "Lastsprung" (fachlich fertig spezifiziert,
-- nicht Teil dieses Pakets) warten auf genau diese Datenbasis.
--
-- Zuschnitt final (mit Chris abgestimmt, 2026-09-27):
--   * O-02: Session Load zaehlt auf session_date der Trainingseinheit selbst,
--     nicht auf den Folgetag.
--   * Kein app.training_session_participants (keine Teilgruppen-Zuweisung),
--     kein Status-Feld fuer Storno/Verschieben. Jede Einheit ist team-weit.
--     Planaenderungen laufen ueber Loeschen/Neuanlegen -- diese Migration
--     baut bewusst keine rpc_delete_training_session (ausserhalb DONE_WHEN
--     dieses Pakets, kein Aufrufer im Client vorbereitet).
--   * Intensitaet smallint 1-10 (konsistent zur RPE-Skala), Ziel Freitext.
--   * RPE-Erfassungsfenster wie rpc_submit_checkin: heute oder bis zu 2 Tage
--     zurueck, hier bezogen auf training_sessions.session_date.
--
-- Muster D (wie 33_baseline_engine.sql/34_readiness_score.sql/
-- 35_load_deviation.sql):
--   1. VOLATILE, app-Funktion und Tuer.
--   2. Kein RAISE im Ablehnungszweig, app.deny -- ausser bei genuinen
--      Eingabefehlern (RPE ausserhalb 1-10, Zeitfenster), dort RAISE mit
--      Errcode wie in 11_checkin_submit.sql (INVALID/FORBIDDEN je nach Fall).
--   3. team_id/created_by/person_id ausschliesslich aus den Auth-Helpern,
--      nie als Parameter.
--   4. Erste Bedingung: app.auth_team_id() IS NULL -> deny.
--
-- RLS auf training_sessions/session_rpe wie bei app.daily_checkins/app.
-- load_deviations (nicht das voll-gesperrte Muster von app.baselines/app.
-- readiness_score): GRANT auf authenticated plus Policies als zweite
-- Sicherheitsebene, tatsaechlicher Schreibweg laeuft ueber die SECURITY
-- DEFINER Tueren (Function-Owner ist Superuser in der Cloud-Migration,
-- umgeht RLS wie ueberall im Projekt).
--
-- Voraussetzung: 08_reconciling.sql (auth_team_id/auth_person_id/auth_is_staff/
-- auth_has_role), 09_rpcs.sql (app.daily_checkins), 33_baseline_engine.sql
-- (app.app_metric, app.baseline_metric_config: session_load/acute_chronic_ratio
-- bereits seed, direction='neutral', hier NICHT neu angelegt). Idempotent
-- (DROP ... IF EXISTS, CREATE OR REPLACE wo der Rueckgabetyp gleich bleibt).
-- Tests: backend/38_training_load.pgtap.sql.
--
-- Security-Review (2026-09-27, drei Runden auf Commits f7353a4/ed04ff8/74f080f) --
-- Fund 4 NICHT in diesem Paket behoben (needs_decision an Chris, ausserhalb
-- des Scopes): Spieler:innen koennen ueber die bestehende Policy
-- daily_checkins_select_team (backend/09_rpcs.sql) die Last/ACWR von
-- Mitspieler:innen lesen, obwohl die RPE-Rohdaten selbst (app.session_rpe)
-- korrekt gesperrt sind. Das ist eine Fachentscheidung, die ueber AP-68
-- hinausgeht (betrifft gleichermassen die bestehenden Schlaf-/Mentalwerte-
-- Spalten auf derselben Tabelle/Policy) -- nicht in dieser Migration geloest.
--
-- ZUSAETZLICHER FUND, dritte Review-Runde (per Supabase-MCP direkt gegen die
-- Cloud verifiziert, 2026-09-27): die Annahme "app.daily_checkins INSERT/
-- UPDATE-Grant fuer authenticated ist bereits entzogen" (Begruendung fuer
-- den neuen Spiegel backend/39_column_privileges_revoke_ap41.sql) stimmt
-- NICHT fuer die live Tabelle. Migration 20260925134906_column_privileges_
-- revoke_ap41 entzieht ausschliesslich auf den SECHS toten Vor-Silo-Tabellen
-- im public-Schema (public.daily_checkins/players/profiles/baselines/
-- load_deviations/medical_records, siehe backend/schema.sql) -- NICHT auf
-- app.daily_checkins, der live Tabelle, die diese Migration durchgaengig
-- verwendet. Direkte Abfrage gegen information_schema.role_table_grants
-- (Projekt tpos-pilot, 2026-09-27): authenticated hat auf app.daily_checkins
-- weiterhin INSERT und UPDATE, unveraendert seit backend/09_rpcs.sql. Damit
-- ist checkin_submitted_at (wie session_load/acute_chronic_ratio zuvor)
-- technisch weiterhin ueber einen direkten Table-Grant faelschbar, falls
-- PostgREST das app-Schema je exponiert (heute nicht der Fall, PGRST106,
-- siehe Kommentar in backend/35_load_deviation.sql) -- dieselbe Kategorie
-- Fund wie Fund 3 auf training_sessions/session_rpe, hier aber auf einer
-- BESTEHENDEN Tabelle mit eigener Migrationshistorie. NICHT in dieser
-- Runde behoben (ausserhalb des erteilten Auftrags fuer diese Migration,
-- ein REVOKE auf app.daily_checkins ist eine Entscheidung mit Tragweite
-- fuer eine Live-Tabelle, kein Nebeneffekt von AP-68) -- als expliziter
-- Fund an den Projektinhaber zurueckgemeldet (siehe Session-Report).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Enum app_session_type
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  CREATE TYPE app.app_session_type AS ENUM ('field','gym','recovery','tactical','test');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- 2. app.training_sessions — team-weit, kein Teilgruppen-/Status-Feld
-- -----------------------------------------------------------------------------

-- Code-Review zu Commit f7353a4 (2026-09-27), Fund 1+2:
--   * created_by war NOT NULL + ON DELETE SET NULL -- widersprach sich
--     (Loeschen der anlegenden Person haette an der NOT-NULL-Constraint
--     scheitern muessen, statt sauber auf NULL zu fallen). Jetzt nullable:
--     die Einheit bleibt bei Personen-Loeschung als Historie erhalten.
--   * duration_min hatte keine Obergrenze. session_rpe.session_load ist
--     numeric(8,3) (5 Vorkommastellen, max 99999.999) -- duration_min nahe
--     dem smallint-Maximum (32767) mit rpe=10 waere 327670, numeric field
--     overflow beim INSERT. Exakt dieselbe Overflow-Fehlerklasse wie der in
--     der Vorsession gefundene und in backend/37_load_deviation_overflow_
--     fix.sql behobene Bug bei load_deviations.deviation. 300 Minuten (5h)
--     ist grosszuegig ueber jeder realistischen Trainingseinheit oder einem
--     Ganztagslehrgang, macht aber rpe*duration_min <= 3000 (weit unter dem
--     numeric(8,3)-Limit) strukturell unmoeglich zu ueberschreiten.
-- Security-Review zu Commit ed04ff8 (2026-09-27), Fund 3: der Kopfkommentar
-- dieser Migration behauptet "Schreibweg laeuft ausschliesslich ueber die
-- SECURITY DEFINER Tueren" -- das stimmte technisch nicht: authenticated
-- hatte weiterhin volles Table-Level INSERT/UPDATE. Die RLS-Policies unten
-- pruefen zudem deutlich weniger als die RPCs (kein Zeitfenster, keine
-- Rollenpruefung bei INSERT, created_by/created_at beliebig umschreibbar
-- per UPDATE). Jetzt technisch wahr: NUR NOCH GRANT SELECT fuer
-- authenticated, kein INSERT/UPDATE ueber Table-Grants mehr moeglich (die
-- Policies unten bleiben als dokumentierte Absicht stehen, greifen aber erst,
-- falls ein GRANT je wieder grosszuegiger wird -- ohne GRANT werden INSERT/
-- UPDATE bereits an der Rechteprüfung abgewiesen, bevor RLS ueberhaupt
-- auswertet). Der einzige Schreibweg ist damit wirklich nur noch die
-- SECURITY DEFINER Tuer (Function-Owner ist Superuser, umgeht Tabellenrechte
-- wie ueberall im Projekt).
CREATE TABLE IF NOT EXISTS app.training_sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id            uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  session_date       date NOT NULL,
  start_time         time,
  duration_min       smallint NOT NULL CHECK (duration_min > 0 AND duration_min <= 300),
  session_type       app.app_session_type NOT NULL DEFAULT 'field',
  planned_intensity  smallint CHECK (planned_intensity BETWEEN 1 AND 10),
  goal_text          text CHECK (char_length(goal_text) <= 2000),
  created_by         uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS training_sessions_team_date_idx
  ON app.training_sessions (team_id, session_date DESC);

COMMENT ON COLUMN app.training_sessions.created_by IS
  'NULL = anlegende Person geloescht (ON DELETE SET NULL) -- die Einheit selbst bleibt als Historie erhalten.';

ALTER TABLE app.training_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.training_sessions FORCE ROW LEVEL SECURITY;

-- NUR SELECT: der Schreibweg (INSERT/UPDATE) laeuft ausschliesslich ueber
-- rpc_create_training_session/rpc_update_training_session (Security-Review
-- Fund 3, siehe Kopfkommentar oben).
GRANT SELECT ON app.training_sessions TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON app.training_sessions FROM authenticated;

DROP POLICY IF EXISTS training_sessions_select_team ON app.training_sessions;
CREATE POLICY training_sessions_select_team ON app.training_sessions
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

-- Dritte Review-Runde (Security-Review, 2026-09-27), Fund 3-Rest (NIEDRIG):
-- die vorherige Session liess die INSERT/UPDATE-Policies "als dokumentierte
-- Absicht" bewusst stehen. Der Review widerspricht dem zu Recht: eine
-- Policy, die niemand mehr aktiv pflegt, aktiviert sich mit ihrer damaligen
-- (luckenhaften) Pruefung wieder, sobald irgendwann ein GRANT erteilt wird --
-- niemand vergleicht das dann gegen die aktuellen RPC-Regeln (Zeitfenster,
-- session_id-Team-Pruefung, Rolle). Konsequenz: DROP statt Liegenlassen. Ein
-- kuenftiges GRANT braucht eine neue, bewusst geschriebene Policy, keine
-- wiederbelebte alte.
DROP POLICY IF EXISTS training_sessions_insert_staff ON app.training_sessions;
DROP POLICY IF EXISTS training_sessions_update_staff ON app.training_sessions;

-- Kein DELETE-Policy: das Projekt gibt Loeschen generell nicht ueber RLS frei
-- (kein FOR DELETE Policy irgendwo im Bestand, gemessen 2026-09-27), keine
-- rpc_delete_training_session in diesem Paket.

-- -----------------------------------------------------------------------------
-- 3. app.session_rpe — RPE je Spieler und Einheit, session_load generiert
-- -----------------------------------------------------------------------------
-- duration_min ist ein Snapshot aus training_sessions.duration_min zum
-- Zeitpunkt der Abgabe (bewusst kein Live-Join): eine spaetere Korrektur der
-- geplanten Dauer darf die Last eines bereits abgegebenen RPE-Eintrags nicht
-- rueckwirkend veraendern.

-- Security-Review zu Commit ed04ff8 (2026-09-27), Fund 3: duration_min hatte
-- HIER (anders als auf training_sessions) noch KEIN CHECK -- ein direkter
-- INSERT mit negativem oder beliebig hohem duration_min waere durchgegangen
-- und haette (bei ausreichend Zeilen desselben Tages) denselben numeric-
-- Overflow-Bug reproduziert, der schon einmal gefixt wurde. session_load
-- selbst ist generiert (rpe*duration_min), das CHECK >= 0 ist trotzdem eine
-- explizite Invariante, kein Fehler heute erzeugbar (rpe/duration_min sind
-- beide > 0), aber falls die generierte Formel je erweitert wird.
CREATE TABLE IF NOT EXISTS app.session_rpe (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id     uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  session_id    uuid NOT NULL REFERENCES app.training_sessions(id) ON DELETE CASCADE,
  rpe           smallint NOT NULL CHECK (rpe BETWEEN 1 AND 10),
  duration_min  smallint NOT NULL CHECK (duration_min BETWEEN 1 AND 300),
  session_load  numeric(8,3) GENERATED ALWAYS AS (rpe * duration_min) STORED CHECK (session_load >= 0),
  submitted_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (person_id, session_id)
);

ALTER TABLE app.session_rpe ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.session_rpe FORCE ROW LEVEL SECURITY;

-- NUR SELECT: der Schreibweg (INSERT/Upsert) laeuft ausschliesslich ueber
-- rpc_submit_session_rpe (Security-Review Fund 3). Die bisherige INSERT-
-- Policy pruefte nur person_id/team_id, NICHT dass session_id zum eigenen
-- Team gehoert, NICHT das Zeitfenster, NICHT die Rolle player -- ein direkter
-- INSERT haette all das umgehen koennen. Ohne GRANT ist das strukturell
-- ausgeschlossen, nicht nur durch eine (luckenhafte) Policy.
GRANT SELECT ON app.session_rpe TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON app.session_rpe FROM authenticated;

DROP POLICY IF EXISTS session_rpe_select_visible ON app.session_rpe;
CREATE POLICY session_rpe_select_visible ON app.session_rpe
  FOR SELECT TO authenticated
  USING (
    team_id = app.auth_team_id()
    AND (person_id = app.auth_person_id() OR app.auth_is_staff() OR app.auth_is_medical())
  );

-- Dritte Review-Runde, Fund 3-Rest: DROP statt Liegenlassen, siehe
-- Begruendung bei app.training_sessions oben (dieselbe Policy pruefte nur
-- person_id/team_id, nicht session_id-Teamzugehoerigkeit/Zeitfenster/Rolle).
DROP POLICY IF EXISTS session_rpe_insert_self ON app.session_rpe;

-- Kein eigenes UPDATE-Recht/Policy fuer authenticated: der Upsert in
-- rpc_submit_session_rpe laeuft ausschliesslich ueber die SECURITY DEFINER
-- Tuer (Function-Owner umgeht RLS und Tabellenrechte wie ueberall im Projekt).

-- -----------------------------------------------------------------------------
-- 4. app.daily_checkins um session_load/acute_chronic_ratio erweitern
-- -----------------------------------------------------------------------------
-- Beide Spalten gehoeren NICHT zum Medizin-Gate (anders als body_map/
-- pain_max): Last ist ueber load_deviations/session_load.above bereits fuer
-- Staff sichtbares Konzept (siehe backend/35_load_deviation.sql Statement-
-- Katalog). Column-Grant additiv (Postgres GRANT SELECT (cols) erweitert die
-- Freigabe, entzieht keine zuvor gewaehrten Spalten) -- die vorhandene Liste
-- aus backend/09_rpcs.sql bleibt unveraendert bestehen, hier nur ergaenzt.

-- Security-Review zu Commit ed04ff8 (2026-09-27), Fund 1 (HOCH): app.
-- cron_training_load legt/aktualisiert ueber _compute_daily_session_load
-- fuer JEDE aktive Person eine daily_checkins-Zeile ("kein Training -> 0,
-- nicht NULL"). app.rpc_morning_ops (siehe unten, Abschnitt 12) hat
-- hasCheckIn bisher als reine Zeilen-EXISTS-Pruefung berechnet -- ab dem
-- Nachtlauf 02:30 hätte das Trainer-Dashboard fuer JEDE Person "Check-in
-- vorhanden" gemeldet, auch ohne echten Wellness-Check-in. checkin_
-- submitted_at ist die Entkopplung: NUR app.rpc_submit_checkin (Abschnitt
-- 11 unten) setzt sie, _compute_daily_session_load fasst sie nie an (weder
-- INSERT noch UPDATE), hasCheckIn prueft ab jetzt checkin_submitted_at IS
-- NOT NULL statt Zeilen-Existenz.
--
-- Fund 5 (NIEDRIG): session_load war numeric(8,3) (5 Vorkommastellen) --
-- die Tagessumme in _compute_daily_session_load kann ab ca. 34 Einheiten an
-- einem Tag ueberlaufen und haette den GESAMTEN Nachtlauf fuer ALLE Personen
-- abgebrochen (eine Transaktion). numeric(10,3) macht das strukturell
-- unmoeglich (7 Vorkommastellen, weit über jeder realistischen Tagessumme).
ALTER TABLE app.daily_checkins
  ADD COLUMN IF NOT EXISTS session_load         numeric(10,3),
  ADD COLUMN IF NOT EXISTS acute_chronic_ratio   numeric(6,3),
  ADD COLUMN IF NOT EXISTS checkin_submitted_at  timestamptz;

ALTER TABLE app.daily_checkins
  ALTER COLUMN session_load TYPE numeric(10,3);

COMMENT ON COLUMN app.daily_checkins.checkin_submitted_at IS
  'Wird AUSSCHLIESSLICH von app.rpc_submit_checkin gesetzt (echter Wellness-Check-in). '
  'app._compute_daily_session_load setzt sie NIEMALS -- eine Zeile, die nur durch den '
  'Trainingslast-Nachtlauf entstand, hat checkin_submitted_at = NULL. hasCheckIn in '
  'app.rpc_morning_ops prueft checkin_submitted_at IS NOT NULL, nicht Zeilen-Existenz.';

-- Dritte Review-Runde (2026-09-27), Fund 1-Rest: Backfill fuer bestehende
-- Zeilen. Ohne diesen Schritt zeigt hasCheckIn am Deploy-Tag fuer JEDE
-- Person false, und jede historische medizinische Sicht (rpc_check_ins_
-- medical, rpc_my_body_map_history, unten per CREATE OR REPLACE gefixt)
-- verliert alle bisherigen echten Check-ins -- checkin_submitted_at ist bei
-- der Spaltenanlage fuer alle Bestandszeilen NULL, unabhaengig davon, ob sie
-- einen echten Check-in enthalten. Kriterium: irgendein Wellness-/Body-Map-
-- Feld ist gesetzt (identisch zu den Parametern, die rpc_submit_checkin
-- entgegennimmt) -- bewusst NICHT "session_load IS NULL", falls zum
-- Deploy-Zeitpunkt bereits kuenstliche Nachtlauf-Zeilen existieren, die
-- zufaellig KEIN session_load haben (z.B. weil der Nachtlauf noch nicht
-- lief). checkin_submitted_at = submitted_at: das bestehende Feld traegt
-- bereits den Zeitpunkt der letzten echten Abgabe (rpc_submit_checkin setzt
-- submitted_at bei jedem Aufruf, _compute_daily_session_load fasst es nicht
-- an), also die korrekte historische Zeit, kein now().
UPDATE app.daily_checkins SET checkin_submitted_at = submitted_at
 WHERE checkin_submitted_at IS NULL
   AND (sleep_duration_min IS NOT NULL OR sleep_quality IS NOT NULL OR recovery IS NOT NULL
        OR energy IS NOT NULL OR mental_stress IS NOT NULL OR mental_mood IS NOT NULL
        OR mental_motivation IS NOT NULL OR training_readiness IS NOT NULL OR body_map IS NOT NULL);

GRANT SELECT (id, team_id, person_id, date, sleep_duration_min, sleep_quality,
              recovery, energy, mental_stress, mental_mood, mental_motivation,
              training_readiness, session_load, acute_chronic_ratio,
              checkin_submitted_at, submitted_at, created_at, updated_at)
  ON app.daily_checkins TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. app._compute_daily_session_load — Aggregation, interne Funktion
-- -----------------------------------------------------------------------------
-- Summiert session_rpe.session_load fuer person_id+date (Join ueber
-- session_id -> training_sessions.session_date = p_date, O-02: Last zaehlt
-- auf den Tag der Einheit selbst). Kein Training am Tag -> 0, nicht NULL:
-- ein Ruhetag ist echte, gezaehlte Last-Information fuer die 7/28-Tage-
-- Mittel weiter unten (app.cron_training_load), nicht "keine Beobachtung".
-- Upsert legt bei Bedarf eine daily_checkins-Zeile nur mit team_id/person_id/
-- date/session_load an (Rest NULL, INSBESONDERE checkin_submitted_at bleibt
-- immer unberuehrt -- siehe Kommentar auf der Spalte oben), analog zum
-- Upsert in rpc_submit_checkin.
--
-- Security-Review zu Commit ed04ff8 (2026-09-27), Fund 2 (MITTEL, Silo-Bruch
-- bei Teamwechsel): die Summenabfrage filterte NICHT auf team_id, und der
-- Upsert hatte nicht die Team-Absicherung, die rpc_submit_checkin bereits
-- hat (11_checkin_submit.sql/20_denial_answer.sql: "WHERE app.daily_checkins.
-- team_id = EXCLUDED.team_id"). Nach einem Teamwechsel einer Person haette
-- Last des NEUEN Teams in eine Zeile des ALTEN Teams geschrieben werden
-- koennen (und umgekehrt), lesbar fuer das falsche Team-Staff. Jetzt: die
-- Summe zaehlt nur RPE-Zeilen desselben Teams, und der Upsert schreibt nur,
-- wenn die (ggf. bestehende) Zeile zum aktuellen Team der Person passt.
-- Anders als rpc_submit_checkin (RAISE bei Nichttreffer) wird hier NICHT
-- geworfen: diese Funktion laeuft in app.cron_training_load ueber ALLE
-- aktiven Personen in EINER Transaktion -- ein RAISE fuer eine einzelne
-- Person wuerde den gesamten Nachtlauf fuer alle anderen Personen
-- mitabbrechen. Ein Nichttreffer ist hier zudem kein Angriffsversuch
-- (anders als beim direkten rpc_submit_checkin-Aufruf einer Person), sondern
-- ein legitimer Randfall (Teamwechsel) -- sicheres Verhalten ist stilles
-- Ueberspringen (kein Schreiben in die falsche Team-Zeile), nicht Abbruch.

CREATE OR REPLACE FUNCTION app._compute_daily_session_load(p_person_id uuid, p_date date)
RETURNS numeric
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id  uuid;
  v_load     numeric(10,3);
  v_row_id   uuid;
BEGIN
  SELECT team_id INTO v_team_id FROM app.persons WHERE id = p_person_id;

  IF v_team_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(sum(sr.session_load), 0)::numeric(10,3)
    INTO v_load
    FROM app.session_rpe sr
    JOIN app.training_sessions ts ON ts.id = sr.session_id
   WHERE sr.person_id = p_person_id
     AND sr.team_id = v_team_id
     AND ts.session_date = p_date;

  INSERT INTO app.daily_checkins (team_id, person_id, date, session_load)
  VALUES (v_team_id, p_person_id, p_date, v_load)
  ON CONFLICT (person_id, date) DO UPDATE SET
    session_load = EXCLUDED.session_load,
    updated_at   = now()
  WHERE app.daily_checkins.team_id = EXCLUDED.team_id
  RETURNING id INTO v_row_id;

  IF v_row_id IS NULL THEN
    -- Team-Mismatch (Silo-Schutz, Fund 2): eine bestehende Zeile gehoert
    -- einem anderen Team als dem aktuellen Team der Person (z.B. nach einem
    -- Teamwechsel) -- kein Schreiben, kein Fehler, kein Abbruch des
    -- Cron-Laufs fuer andere Personen. Dritte Review-Runde (2026-09-27):
    -- ein stiller RETURN NULL hinterlaesst keine Spur -- app.log_denial
    -- schreibt (anders als ein RAISE WARNING, das laut Review nicht in
    -- cron.job_run_details landet) eine Zeile in app.access_denials, sofern
    -- JWT-Claims im aktuellen Kontext vorhanden sind (bei einem direkten
    -- Aufruf aus rpc_submit_session_rpe der Fall, bei einem Cron-Lauf ohne
    -- Request-Kontext ist es ein bewusstes No-Op von log_denial selbst,
    -- gleiches Verhalten wie an jeder anderen Stelle im Projekt).
    PERFORM app.log_denial('daily_checkins.team');
    RETURN NULL;
  END IF;

  RETURN v_load;
END;
$$;

REVOKE EXECUTE ON FUNCTION app._compute_daily_session_load(uuid, date) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. app.rpc_create_training_session — Muster D, staff-only
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_create_training_session(
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type DEFAULT 'field',
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id   uuid;
  v_person_id uuid;
  v_row       app.training_sessions%rowtype;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('training_sessions.create', 'FORBIDDEN: training_sessions.create');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('training_sessions.create', 'FORBIDDEN: training_sessions.create');
  END IF;

  IF p_session_date IS NULL THEN
    RAISE EXCEPTION 'INVALID: training_sessions.session_date' USING errcode = '22023';
  END IF;

  IF p_duration_min IS NULL OR p_duration_min <= 0 OR p_duration_min > 300 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.duration_min' USING errcode = '22023';
  END IF;

  IF p_planned_intensity IS NOT NULL AND p_planned_intensity NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.planned_intensity' USING errcode = '22023';
  END IF;

  v_team_id   := app.auth_team_id();
  v_person_id := app.auth_person_id();

  INSERT INTO app.training_sessions (
    team_id, session_date, start_time, duration_min, session_type,
    planned_intensity, goal_text, created_by
  )
  VALUES (
    v_team_id, p_session_date, p_start_time, p_duration_min, p_session_type,
    p_planned_intensity, p_goal_text, v_person_id
  )
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

COMMENT ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, staff-only (coach/athletic_coach). '
  'team_id/created_by ausschliesslich aus den Auth-Helpern. Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. app.rpc_update_training_session — Muster D, staff-only, eigenes Team
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_update_training_session(
  p_session_id         uuid,
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type,
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid;
  v_row     app.training_sessions%rowtype;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('training_sessions.update', 'FORBIDDEN: training_sessions.update');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('training_sessions.update', 'FORBIDDEN: training_sessions.update');
  END IF;

  v_team_id := app.auth_team_id();

  IF NOT EXISTS (
    SELECT 1 FROM app.training_sessions WHERE id = p_session_id AND team_id = v_team_id
  ) THEN
    RETURN app.deny('training_sessions.update', 'FORBIDDEN: training_sessions.update');
  END IF;

  IF p_session_date IS NULL THEN
    RAISE EXCEPTION 'INVALID: training_sessions.session_date' USING errcode = '22023';
  END IF;

  IF p_duration_min IS NULL OR p_duration_min <= 0 OR p_duration_min > 300 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.duration_min' USING errcode = '22023';
  END IF;

  IF p_planned_intensity IS NOT NULL AND p_planned_intensity NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.planned_intensity' USING errcode = '22023';
  END IF;

  UPDATE app.training_sessions SET
    session_date      = p_session_date,
    start_time        = p_start_time,
    duration_min      = p_duration_min,
    session_type      = p_session_type,
    planned_intensity = p_planned_intensity,
    goal_text         = p_goal_text,
    updated_at        = now()
  WHERE id = p_session_id AND team_id = v_team_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

COMMENT ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, staff-only, nur eigenes Team. '
  'Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. app.rpc_list_training_sessions — alle Rollen, team-gescoped
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_list_training_sessions(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid;
  v_rows    jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('training_sessions.list', 'FORBIDDEN: training_sessions.list');
  END IF;

  v_team_id := app.auth_team_id();

  SELECT COALESCE(jsonb_agg(to_jsonb(ts) ORDER BY ts.session_date, ts.start_time NULLS LAST), '[]'::jsonb)
    INTO v_rows
    FROM app.training_sessions ts
   WHERE ts.team_id = v_team_id
     AND (p_from IS NULL OR ts.session_date >= p_from)
     AND (p_to   IS NULL OR ts.session_date <= p_to);

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION app.rpc_list_training_sessions(date, date) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, alle Rollen, team-gescoped. '
  'Rueckgabe ist ein JSON-Array. Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_list_training_sessions(date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_list_training_sessions(date, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 9. app.rpc_submit_session_rpe — Muster D, nur der Spieler selbst
-- -----------------------------------------------------------------------------
-- Zeitfenster wie rpc_submit_checkin: heute oder bis zu 2 Tage zurueck,
-- bezogen auf training_sessions.session_date (nicht auf den Abgabezeitpunkt).
-- duration_min wird als Snapshot aus training_sessions kopiert (Abschnitt 3).

CREATE OR REPLACE FUNCTION app.rpc_submit_session_rpe(p_session_id uuid, p_rpe smallint)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id     uuid;
  v_person_id   uuid;
  v_session     app.training_sessions%rowtype;
  v_id          uuid;
  v_daily_load  numeric;
  v_row         app.session_rpe%rowtype;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.submit');
  END IF;

  IF NOT app.auth_has_role('player') THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.submit');
  END IF;

  v_team_id   := app.auth_team_id();
  v_person_id := app.auth_person_id();

  SELECT * INTO v_session FROM app.training_sessions
   WHERE id = p_session_id AND team_id = v_team_id;

  IF v_session.id IS NULL THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.submit');
  END IF;

  IF v_session.session_date > current_date OR v_session.session_date < current_date - 2 THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.window');
  END IF;

  IF p_rpe IS NULL OR p_rpe NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: session_rpe.rpe' USING errcode = '22023';
  END IF;

  INSERT INTO app.session_rpe (team_id, person_id, session_id, rpe, duration_min, submitted_at)
  VALUES (v_team_id, v_person_id, p_session_id, p_rpe, v_session.duration_min, now())
  ON CONFLICT (person_id, session_id) DO UPDATE SET
    rpe           = EXCLUDED.rpe,
    duration_min  = EXCLUDED.duration_min,
    submitted_at  = now()
  RETURNING id INTO v_id;

  v_daily_load := app._compute_daily_session_load(v_person_id, v_session.session_date);

  SELECT * INTO v_row FROM app.session_rpe WHERE id = v_id;

  RETURN to_jsonb(v_row) || jsonb_build_object('daily_session_load', v_daily_load);
END;
$$;

COMMENT ON FUNCTION app.rpc_submit_session_rpe(uuid, smallint) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, nur der Spieler selbst. Zeitfenster wie '
  'rpc_submit_checkin (heute oder bis zu 2 Tage zurueck), bezogen auf session_date (O-02). '
  'duration_min als Snapshot aus training_sessions. Ruft im selben Aufruf app._compute_'
  'daily_session_load auf. Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_submit_session_rpe(uuid, smallint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_submit_session_rpe(uuid, smallint) TO authenticated;

-- -----------------------------------------------------------------------------
-- 9b. Security-Review Fund 1 (HOCH): app.rpc_submit_checkin und app.
--     rpc_morning_ops muessen an checkin_submitted_at angeschlossen werden.
-- -----------------------------------------------------------------------------
-- app.rpc_submit_checkin ist die einzige Stelle, die einen ECHTEN Wellness-
-- Check-in entgegennimmt (ADR-016). Body identisch zur zuletzt gueltigen
-- Fassung (backend/20_denial_answer.sql) -- CREATE OR REPLACE, NICHT DROP+
-- CREATE, damit Signatur/Rueckgabetyp (jsonb, AP-45d) unveraendert bleiben
-- und keine abhaengige Tuer erneut angelegt werden muss. Einzige Aenderung:
-- checkin_submitted_at wird beim INSERT UND beim ON CONFLICT DO UPDATE
-- gesetzt. app._compute_daily_session_load (Abschnitt 5 oben) setzt diese
-- Spalte NIEMALS -- das ist die eigentliche Entkopplung.

CREATE OR REPLACE FUNCTION app.rpc_submit_checkin(
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
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id  uuid;
  v_team_id    uuid;
  v_pain_max   smallint;
  v_id         uuid;
  v_score      numeric;
BEGIN
  IF NOT app.auth_has_role('player') THEN
    RETURN app.deny('daily_checkins.submit', 'FORBIDDEN: daily_checkins.submit');
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id := app.auth_team_id();

  IF p_date IS NULL OR p_date > current_date OR p_date < current_date - 2 THEN
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.date' USING errcode = '42501';
  END IF;

  IF p_body_map IS NOT NULL THEN
    IF jsonb_typeof(p_body_map) <> 'array' THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map' USING errcode = '22023';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE jsonb_typeof(e) <> 'object'
         OR jsonb_typeof(e -> 'region') IS DISTINCT FROM 'string'
         OR (e ? 'pain' AND jsonb_typeof(e -> 'pain') NOT IN ('number', 'null'))
         OR (jsonb_typeof(e -> 'pain') = 'number' AND (e ->> 'pain')::numeric NOT BETWEEN 0 AND 10)
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map' USING errcode = '22023';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE NOT EXISTS (
        SELECT 1
        FROM app.body_region br
        WHERE br.key = e ->> 'region'
          AND (br.active_to IS NULL OR br.active_to > p_date)
      )
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.region' USING errcode = '22023';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE e ? 'point'
        AND jsonb_typeof(e -> 'point') <> 'null'
        AND (
             jsonb_typeof(e -> 'point') <> 'array'
          OR jsonb_array_length(e -> 'point') <> 2
          OR EXISTS (
               SELECT 1
               FROM jsonb_array_elements(e -> 'point') c
               WHERE jsonb_typeof(c) <> 'number'
                  OR (c #>> '{}')::numeric NOT BETWEEN 0 AND 1
             )
        )
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.point' USING errcode = '22023';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE e ? 'svg'
        AND jsonb_typeof(e -> 'svg') <> 'null'
        AND (
             jsonb_typeof(e -> 'svg') <> 'string'
          OR (e ->> 'svg') !~ '^[a-z_]+@[0-9]+$'
          OR NOT EXISTS (
               SELECT 1
               FROM app.body_figure_variant v
               WHERE v.key = split_part(e ->> 'svg', '@', 1)
             )
        )
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.svg' USING errcode = '22023';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE e ? 'point'
        AND jsonb_typeof(e -> 'point') <> 'null'
        AND (NOT e ? 'svg' OR jsonb_typeof(e -> 'svg') = 'null')
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.svg' USING errcode = '22023';
    END IF;

    SELECT max((e ->> 'pain')::numeric)::smallint
    INTO v_pain_max
    FROM jsonb_array_elements(p_body_map) e
    WHERE jsonb_typeof(e -> 'pain') = 'number';
  END IF;

  INSERT INTO app.daily_checkins (
    team_id, person_id, date, sleep_duration_min, sleep_quality, recovery,
    energy, mental_stress, mental_mood, mental_motivation, training_readiness,
    body_map, pain_max, submitted_at, checkin_submitted_at
  )
  VALUES (
    v_team_id, v_person_id, p_date, p_sleep_duration_min, p_sleep_quality, p_recovery,
    p_energy, p_mental_stress, p_mental_mood, p_mental_motivation, p_training_readiness,
    p_body_map, v_pain_max, now(), now()
  )
  ON CONFLICT (person_id, date) DO UPDATE SET
    sleep_duration_min   = EXCLUDED.sleep_duration_min,
    sleep_quality        = EXCLUDED.sleep_quality,
    recovery             = EXCLUDED.recovery,
    energy               = EXCLUDED.energy,
    mental_stress        = EXCLUDED.mental_stress,
    mental_mood          = EXCLUDED.mental_mood,
    mental_motivation    = EXCLUDED.mental_motivation,
    training_readiness   = EXCLUDED.training_readiness,
    body_map             = EXCLUDED.body_map,
    pain_max             = EXCLUDED.pain_max,
    submitted_at         = EXCLUDED.submitted_at,
    checkin_submitted_at = EXCLUDED.checkin_submitted_at,
    updated_at           = now()
  WHERE app.daily_checkins.team_id = EXCLUDED.team_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.team' USING errcode = '42501';
  END IF;

  v_score := round((
      coalesce(p_sleep_quality, 5) +
      coalesce(p_recovery, 5) +
      coalesce(p_mental_mood, 5) +
      coalesce(p_mental_motivation, 5) +
      (10 - coalesce(p_mental_stress, 5))
    ) / 5.0, 2);

  INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors, computed_at)
  VALUES (
    v_team_id, v_person_id, p_date, v_score,
    CASE WHEN v_score >= 7 THEN 'high'::app.app_readiness_band
         WHEN v_score >= 5 THEN 'moderate'::app.app_readiness_band
         ELSE 'low'::app.app_readiness_band END,
    jsonb_build_object(
      'sleep_quality', p_sleep_quality,
      'recovery', p_recovery,
      'mental_mood', p_mental_mood,
      'mental_motivation', p_mental_motivation,
      'mental_stress', p_mental_stress,
      'training_readiness', p_training_readiness
    ),
    now()
  )
  ON CONFLICT (person_id, date) DO UPDATE SET
    score_total = EXCLUDED.score_total,
    band        = EXCLUDED.band,
    factors     = EXCLUDED.factors,
    computed_at = EXCLUDED.computed_at;

  RETURN to_jsonb(v_id);
END;
$$;

COMMENT ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) IS
  'ADR-016: only write path for player check-ins. Player role with DB-confirmed claims, person/team from auth helpers, date today or up to 2 days back, upsert per (person_id, date), body_map jsonb array with pain_max, readiness score in the same call. No free text. '
  'AP-43: region checked against app.body_region, optional tap point (two numbers 0 to 1, '
  'normalised to the silhouette viewBox) and optional figure svg as <variant>@<version>, '
  'variant checked against app.body_figure_variant. pain_max still reads pain only. '
  'AP-45d: returns jsonb. On success to_jsonb(id), on denial the error object from app.deny. '
  'AP-68 Security-Review Fund 1: setzt checkin_submitted_at (einziger Ort im System, der das tut) -- '
  'das trennt einen echten Wellness-Check-in von einer Zeile, die nur der Trainingslast-Nachtlauf angelegt hat.';

REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) TO authenticated;

-- app.rpc_morning_ops: Body identisch zur zuletzt gueltigen Fassung
-- (backend/08_dashboard_migration.sql, Bridge Punkt 67/2026-09-24) --
-- CREATE OR REPLACE, Signatur/Rueckgabetyp unveraendert. Einzige Aenderung:
-- hasCheckIn prueft jetzt checkin_submitted_at IS NOT NULL statt reiner
-- Zeilen-Existenz (Fund 1).

CREATE OR REPLACE FUNCTION app.rpc_morning_ops()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public, auth, pg_temp
AS $$
DECLARE
  v_team_id    uuid;
  v_kader_name text;
  v_members    jsonb;
BEGIN
  IF NOT app.auth_is_staff() THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501';
  END IF;

  v_team_id := app.auth_team_id();

  SELECT t.name INTO v_kader_name
  FROM app.teams t
  WHERE t.id = v_team_id;

  SELECT coalesce(jsonb_agg(m.member ORDER BY m.jersey), '[]'::jsonb)
  INTO v_members
  FROM (
    SELECT
      coalesce(ap.shirt_number, 0) AS jersey,
      jsonb_build_object(
        'player', jsonb_build_object(
          'id', ap.id,
          'jersey', coalesce(ap.shirt_number, 0),
          'name', coalesce(ap.display_name, ''),
          'position', coalesce(ap.person_position, '')
        ),
        -- Nur das Band. KEIN score_total, KEINE factors: siehe Kopf von
        -- 08_dashboard_migration.sql.
        'readiness', jsonb_build_object(
          'band', rs.band
        ),
        'baseline', jsonb_build_object(
          'series', '[]'::jsonb,
          'rollingAvg', 0
        ),
        'medicalStatus', coalesce(mc.clearance_mapped, 'green'),
        'medicalClearance', mc.clearance_mapped,
        'attendance', 'anwesend',
        'todayEvent', 'none',
        -- Fund 1 (Security-Review 2026-09-27): echtes Feld statt Zeilen-
        -- Existenz, siehe Kommentar auf app.daily_checkins.checkin_submitted_at.
        'hasCheckIn', EXISTS (
          SELECT 1 FROM app.daily_checkins dc
           WHERE dc.person_id = ap.id AND dc.date = current_date
             AND dc.checkin_submitted_at IS NOT NULL
        )
      ) AS member
    FROM app.persons ap
    LEFT JOIN app.readiness_scores rs
      ON rs.person_id = ap.id AND rs.date = current_date
    LEFT JOIN LATERAL (
      SELECT CASE mcl.status
               WHEN 'full'       THEN 'frei'
               WHEN 'limited'    THEN 'eingeschraenkt'
               WHEN 'individual' THEN 'eingeschraenkt'
               WHEN 'blocked'    THEN 'gesperrt'
             END AS clearance_mapped
      FROM app.medical_clearances mcl
      WHERE mcl.person_id = ap.id
        AND mcl.valid_from <= now()
        AND (mcl.valid_to IS NULL OR mcl.valid_to > now())
      ORDER BY mcl.valid_from DESC
      LIMIT 1
    ) mc ON true
    WHERE ap.team_id = v_team_id
      AND ap.is_active = true
      AND EXISTS (
        SELECT 1
          FROM app.role_assignments ra
         WHERE ra.person_id = ap.id
           AND ra.team_id   = ap.team_id
           AND ra.role      = 'player'
           AND ra.valid_from <= now()
           AND (ra.valid_to IS NULL OR ra.valid_to > now())
      )
  ) m;

  RETURN jsonb_build_object(
    'kaderName', coalesce(v_kader_name, ''),
    'syncState', 'live',
    'asOf', to_char(current_date, 'YYYY-MM-DD'),
    'members', v_members
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_morning_ops() IS
  'Trainer-Kader-Payload. AP-68 Security-Review Fund 1: hasCheckIn prueft checkin_submitted_at '
  'IS NOT NULL statt Zeilen-Existenz auf app.daily_checkins (sonst meldet der Trainingslast-'
  'Nachtlauf faelschlich jeden Tag einen Check-in fuer jede Person). Sonst unveraendert zur '
  'Fassung aus backend/08_dashboard_migration.sql (Bridge Punkt 67).';

REVOKE EXECUTE ON FUNCTION app.rpc_morning_ops() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_morning_ops() FROM anon;
GRANT EXECUTE ON FUNCTION app.rpc_morning_ops() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 9c. Dritte Review-Runde (2026-09-27), Fund 1-Rest: zwei weitere Stellen in
--     der Medizin-/Self-Sicht zaehlten Check-ins ueber reine Zeilenexistenz.
--     Codebase-weit geprueft (grep "FROM app.daily_checkins" ueber backend/*
--     und supabase/migrations/*): Baseline-Engine (33_baseline_engine.sql,
--     34_readiness_score.sql) filtert je Metrik explizit auf IS NOT NULL
--     ueber to_jsonb(dc)->>metric -- eine reine Lastzeile hat dort ueberall
--     NULL und traegt nichts bei, unveraendert korrekt. app.rpc_body_map_
--     region_reports (backend/20_denial_answer.sql) zaehlt bereits explizit
--     "dc.body_map IS NOT NULL" bzw. joint per LATERAL gegen die Elemente
--     von body_map -- eine reine Lastzeile hat body_map=NULL und liefert
--     dort strukturell nichts, unveraendert korrekt. app.rpc_export_my_data
--     (backend/09_rpcs.sql) ist ein roher Self-Export (to_jsonb(dc.*), DSGVO-
--     Auskunft ueber ALLE eigenen Daten) -- eine reine Lastzeile ist dort
--     bewusst und korrekt Teil des Exports, kein hasCheckIn-Konzept.
--     app.v_daily_checkins_staff (backend/09_rpcs.sql) ist eine ungenutzte
--     View (kein SELECT-Aufrufer im gesamten Repo gefunden) -- fuer diese
--     Migration keine Aenderung, siehe Kopfkommentar Fund 4/weitere Funde.
-- -----------------------------------------------------------------------------

-- app.rpc_check_ins_medical: Body identisch zur zuletzt gueltigen Fassung
-- (backend/31_medical_doors.sql) -- CREATE OR REPLACE, Signatur/Rueckgabetyp
-- unveraendert. Einzige Aenderung: die WHERE-Klausel schliesst Zeilen ohne
-- echten Check-in aus.

CREATE OR REPLACE FUNCTION app.rpc_check_ins_medical(
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
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
  END IF;

  IF app.auth_is_staff() OR app.auth_has_role('admin') THEN
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
  END IF;

  IF NOT (app.auth_is_medical() OR app.auth_person_id() = p_person_id) THEN
    RETURN app.deny('daily_checkins.medical', 'FORBIDDEN: daily_checkins.medical');
  END IF;

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
         -- Fund 1-Rest: nur echte Check-ins, keine reinen Trainingslast-Zeilen.
         AND dc.checkin_submitted_at IS NOT NULL
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
  'app.auth_target_is_team_player statt ueber auth_person_id() allein. '
  'AP-68 Security-Review Fund 1-Rest (2026-09-27): nur Zeilen mit checkin_submitted_at '
  'IS NOT NULL -- eine reine Trainingslast-Zeile ist kein Check-in.';

REVOKE EXECUTE ON FUNCTION app.rpc_check_ins_medical(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_check_ins_medical(uuid, date, date) TO authenticated;

-- app.rpc_my_body_map_history: Body identisch zur zuletzt gueltigen Fassung
-- (backend/20_denial_answer.sql) -- CREATE OR REPLACE, Signatur/Rueckgabetyp
-- unveraendert. Einzige Aenderung: die WHERE-Klausel im checkins-Unterabfrage
-- schliesst Zeilen ohne echten Check-in aus (bisher erschien JEDE Zeile als
-- Tag im Kalender, auch eine reine Trainingslast-Zeile mit answered=false).

CREATE OR REPLACE FUNCTION app.rpc_my_body_map_history(p_days integer DEFAULT 28)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_team_id   uuid;
  v_today     date;
  v_from      date;
BEGIN
  IF NOT app.auth_has_role('player') THEN
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
  END IF;

  IF p_days IS NULL OR p_days < 1 OR p_days > 90 THEN
    RAISE EXCEPTION 'INVALID: body_map_history.days' USING errcode = '22023';
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id   := app.auth_team_id();

  SELECT (now() AT TIME ZONE t.timezone)::date INTO v_today
    FROM app.teams t WHERE t.id = v_team_id;
  v_from := v_today - (p_days - 1);

  RETURN jsonb_build_object(
    'from', v_from,
    'to',   v_today,
    'days', p_days,
    'checkins', COALESCE((
      SELECT jsonb_agg(
               jsonb_build_object(
                 'date', dc.date,
                 'answered', dc.body_map IS NOT NULL,
                 'regions', COALESCE((
                   SELECT jsonb_agg(
                            jsonb_build_object('region', e ->> 'region', 'pain', e -> 'pain')
                            ORDER BY e ->> 'region')
                     FROM jsonb_array_elements(
                            CASE WHEN jsonb_typeof(dc.body_map) = 'array'
                                 THEN dc.body_map ELSE '[]'::jsonb END) e
                 ), '[]'::jsonb)
               )
               ORDER BY dc.date)
        FROM app.daily_checkins dc
       WHERE dc.person_id = v_person_id
         AND dc.team_id   = v_team_id
         AND dc.date     >= v_from
         -- Fund 1-Rest: nur echte Check-ins zaehlen als Tag im Kalender.
         AND dc.checkin_submitted_at IS NOT NULL
    ), '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_my_body_map_history(integer) IS
  'AP-45: einzige Tuer fuer die eigene Body-Map-Historie. '
  'AP-68 Security-Review Fund 1-Rest (2026-09-27): nur Zeilen mit checkin_submitted_at '
  'IS NOT NULL erscheinen im checkins-Array -- eine reine Trainingslast-Zeile ist kein Tag '
  'mit Check-in-Versuch, auch nicht mit answered=false.';

REVOKE EXECUTE ON FUNCTION app.rpc_my_body_map_history(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_my_body_map_history(integer) TO authenticated;

-- -----------------------------------------------------------------------------
-- 10. Die Tueren in public
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_create_training_session(
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type DEFAULT 'field',
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_create_training_session(p_session_date, p_start_time, p_duration_min, p_session_type, p_planned_intensity, p_goal_text);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_update_training_session(
  p_session_id         uuid,
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type,
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_update_training_session(p_session_id, p_session_date, p_start_time, p_duration_min, p_session_type, p_planned_intensity, p_goal_text);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_list_training_sessions(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_list_training_sessions(p_from, p_to);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_submit_session_rpe(p_session_id uuid, p_rpe smallint)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_submit_session_rpe(p_session_id, p_rpe);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) IS 'API-Tuer fuer app.rpc_create_training_session. Invoker, nur authenticated. AP-68.';
COMMENT ON FUNCTION public.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) IS 'API-Tuer fuer app.rpc_update_training_session. Invoker, nur authenticated. AP-68.';
COMMENT ON FUNCTION public.rpc_list_training_sessions(date, date) IS 'API-Tuer fuer app.rpc_list_training_sessions. Invoker, nur authenticated. AP-68.';
COMMENT ON FUNCTION public.rpc_submit_session_rpe(uuid, smallint) IS 'API-Tuer fuer app.rpc_submit_session_rpe. Invoker, nur authenticated. AP-68.';

REVOKE EXECUTE ON FUNCTION public.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_list_training_sessions(date, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_submit_session_rpe(uuid, smallint) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_list_training_sessions(date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_submit_session_rpe(uuid, smallint) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 11. app.cron_training_load — Nachtlauf, service_role (Cron 02:30, vor
--     app.cron_baseline_engine 03:00 und app.cron_loaddeviation 03:30 --
--     Muster wie supabase/migrations/20260927082030_wire_baseline_
--     loaddeviation_cron.sql, hier direkt im gleichen Paket verdrahtet, damit
--     der Job vom ersten Tag an existiert statt erneut vergessen zu werden.
-- -----------------------------------------------------------------------------
-- acute_chronic_ratio: acute = avg(session_load) ueber 7 Tage [as_of-6..as_of],
-- chronic = avg(session_load) ueber 28 Tage [as_of-27..as_of]. chronic = 0
-- oder NULL -> ratio NULL, kein Fehler, keine Division-durch-Null-Exception
-- (COALESCE/NULLIF-frei durch CASE, expliziter als NULLIF(chronic,0) fuer
-- die Lesbarkeit im Test).
--
-- Security-Review zu Commit ed04ff8 (2026-09-27), Fund 1 (Teil 2): die
-- Schleife lief ueber JEDE aktive Person, auch Coach/Physio/Arzt/Admin --
-- die legen nie eine RPE ab und brauchen keine Trainingslast-Zeile. Auf
-- Rolle player beschraenkt (dasselbe EXISTS-Praedikat wie app.rpc_
-- morning_ops/app.rpc_list_team_members, Bridge Punkt 67): das schliesst
-- einen Teil des hasCheckIn-Problems zusaetzlich ab (Staff bekommt gar
-- keine Zeile mehr vom Nachtlauf) und ist fachlich korrekt (Last ergibt fuer
-- Nicht-Spieler:innen kein Konzept).

CREATE OR REPLACE FUNCTION app.cron_training_load()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  r         record;
  v_acute   numeric;
  v_chronic numeric;
  v_ratio   numeric(6,3);
BEGIN
  FOR r IN
    SELECT p.id AS person_id
      FROM app.persons p
     WHERE p.is_active
       AND EXISTS (
         SELECT 1 FROM app.role_assignments ra
          WHERE ra.person_id = p.id AND ra.team_id = p.team_id AND ra.role = 'player'
            AND ra.valid_from <= now() AND (ra.valid_to IS NULL OR ra.valid_to > now())
       )
  LOOP
    PERFORM app._compute_daily_session_load(r.person_id, current_date);
  END LOOP;

  FOR r IN
    SELECT p.id AS person_id
      FROM app.persons p
     WHERE p.is_active
       AND EXISTS (
         SELECT 1 FROM app.role_assignments ra
          WHERE ra.person_id = p.id AND ra.team_id = p.team_id AND ra.role = 'player'
            AND ra.valid_from <= now() AND (ra.valid_to IS NULL OR ra.valid_to > now())
       )
  LOOP
    SELECT avg(dc.session_load) INTO v_acute
      FROM app.daily_checkins dc
     WHERE dc.person_id = r.person_id
       AND dc.date BETWEEN current_date - 6 AND current_date;

    SELECT avg(dc.session_load) INTO v_chronic
      FROM app.daily_checkins dc
     WHERE dc.person_id = r.person_id
       AND dc.date BETWEEN current_date - 27 AND current_date;

    v_ratio := CASE
      WHEN v_chronic IS NULL OR v_chronic = 0 THEN NULL
      ELSE round((v_acute / v_chronic)::numeric, 3)
    END;

    -- Dritte Review-Runde (2026-09-27), Fund 2-Rest: dieses UPDATE hatte
    -- (anders als der Upsert in app._compute_daily_session_load direkt
    -- darueber) KEINEN Teamfilter. Am Wechseltag einer Person haette die
    -- Ratio in die heutige Zeile des ALTEN Teams geschrieben werden koennen,
    -- selbst wenn der Teamwechsel schon vollzogen ist (person.team_id zeigt
    -- bereits auf das neue Team, die Zeile fuer heute gehoert aber noch dem
    -- alten). team_id wird bewusst frisch aus app.persons gelesen (nicht aus
    -- einer Variable von oben), damit ein Wechsel zwischen den beiden
    -- Schleifen dieser Funktion ebenfalls korrekt greift.
    UPDATE app.daily_checkins
       SET acute_chronic_ratio = v_ratio, updated_at = now()
     WHERE person_id = r.person_id
       AND date = current_date
       AND team_id = (SELECT team_id FROM app.persons WHERE id = r.person_id);
  END LOOP;
END;
$$;

COMMENT ON FUNCTION app.cron_training_load() IS
  'Nachtlauf 02:30 (AP-68, Modul 6): app._compute_daily_session_load fuer alle aktiven '
  'Personen fuer heute, danach acute_chronic_ratio (7-Tage/28-Tage-Mittel, chronic=0/NULL '
  '-> ratio NULL). Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.cron_training_load() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.cron_training_load() TO service_role;

-- Code-Review zu Commit f7353a4 (2026-09-27), Fund 3, VERSCHAERFT im
-- Security-Review zu Commit ed04ff8 (Fund 5, NIEDRIG): ein stiller Skip ohne
-- jede Meldung wuerde exakt das Bug-Muster reproduzieren, das gerade erst
-- gefunden wurde (etwas fehlt, niemand merkt es) -- ABER ein pauschaler
-- "EXCEPTION WHEN OTHERS" um CREATE EXTENSION faengt in der Cloud auch echte
-- Berechtigungsfehler lautlos ab (z.B. fehlende Superuser-Rechte), nicht nur
-- die bekannte lokale Grenze. Jetzt gezielt: erst pruefen, OB die Extension
-- ueberhaupt verfuegbar ist (pg_available_extensions, kein Fehler, nur eine
-- Katalogabfrage) -- fehlt sie (Homebrew-Postgres lokal), WARNEN und
-- ueberspringen, KEIN Exception-Block. Ist sie verfuegbar, laeuft CREATE
-- EXTENSION IF NOT EXISTS ungeschuetzt (wie im Referenzmuster 20260927082030_
-- wire_baseline_loaddeviation_cron.sql) -- ein echter Berechtigungsfehler in
-- der Cloud bricht diese Migration dann sichtbar ab, statt lautlos zu
-- verschwinden. Idempotent planen: erst unschedule (nur wenn der Job laut
-- cron.job tatsaechlich existiert), dann neu.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    RAISE WARNING 'app.cron_training_load NICHT geplant: Extension pg_cron ist auf dieser '
      'Postgres-Instanz nicht verfuegbar (pg_available_extensions). Bekannte Grenze der '
      'lokalen Test-DB (Homebrew-Postgres ohne pg_cron) -- in der Cloud darf das NICHT '
      'passieren, da 20260927082030_wire_baseline_loaddeviation_cron.sql die Extension '
      'bereits aktiviert haben muss. Siehe backend/38_training_load.sql.';
    RETURN;
  END IF;

  CREATE EXTENSION IF NOT EXISTS pg_cron;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'training-load-nightly') THEN
    PERFORM cron.unschedule('training-load-nightly');
  END IF;

  PERFORM cron.schedule(
    'training-load-nightly',
    '30 2 * * *',
    $cron$SELECT app.cron_training_load();$cron$
  );
END $$;
