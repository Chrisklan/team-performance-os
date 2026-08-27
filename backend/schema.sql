-- ============================================================================
-- Team Performance OS — schema.sql
-- Bundesliga Sport-Performance-SaaS
--
-- Quelle: RLS-MATRIX.md (ARCHIE), ADR-001 (Silo-Tenant), ADR-003 (MVP-Scope),
--         ADR-004 (Rechtsbasis / Auditierbarkeit), ADR-005 (LoadDeviation-Naming)
--
-- ADR-001: Silo-Architektur. Jeder Verein = eigenes Deployment.
--          Deshalb KEIN tenant_id und KEINE Cross-Tenant-Spalten.
--          RLS trennt ausschliesslich Rollen INNERHALB eines Vereins.
--
-- Dieses File legt an: Rollen-Grundlage, auth-Shim, Helferfunktionen,
-- Tabellen (Matrix 3.1-3.6), Security-Definer-Views (Matrix 4),
-- Audit + Portabilitaet (Matrix 5).
-- Die Policies stehen in rls.sql.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Rollen (Supabase-kompatibel)
--    In Supabase existieren diese Rollen bereits. Lokal legen wir sie an,
--    damit RLS ueberhaupt greifen kann (Superuser umgeht RLS immer).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO authenticated, anon, service_role;

-- ---------------------------------------------------------------------------
-- 2. auth-Shim
--    In Supabase liefert das die Plattform. Lokal bilden wir exakt das
--    Verhalten nach: die Claims stehen im GUC `request.jwt.claims`.
--    Tests setzen sie via  SET LOCAL request.jwt.claims = '{...}'.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO authenticated, anon, service_role;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(auth.jwt() ->> 'sub', '')::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(auth.jwt() ->> 'role', '');
$$;

-- ---------------------------------------------------------------------------
-- 3. Domaenen / Check-Werte
-- ---------------------------------------------------------------------------
-- Rollen-Codes exakt gemaess Matrix 1.
CREATE DOMAIN app_role_code AS text
    CHECK (VALUE IN ('player', 'coach', 'athletik', 'physio', 'arzt', 'admin'));

-- Sichtbarkeits-Flag fuer Check-In-Freitext (Matrix 3.2 / 4.2)
CREATE DOMAIN checkin_visibility AS text
    CHECK (VALUE IN ('team', 'staff', 'med_only'));

-- Medical-Clearance-Badge (Matrix 3.4)
CREATE DOMAIN medical_clearance AS text
    CHECK (VALUE IN ('green', 'yellow', 'orange', 'red'));

-- Sichtbarkeit eines Medical-Records
CREATE DOMAIN medical_visibility AS text
    CHECK (VALUE IN ('med_only', 'staff_status', 'full'));

-- ---------------------------------------------------------------------------
-- 4. Tabellen — 3.1 Infrastruktur / 3.2 Spieler-Kern
-- ---------------------------------------------------------------------------

CREATE TABLE players (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name    text NOT NULL,
    last_name     text NOT NULL,
    birth_date    date,
    position      text,
    squad_number  smallint,
    status        text NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'injured', 'loaned', 'inactive')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE players IS 'Spieler-Stammdaten. Alle Staff-Rollen lesen *, Spieler liest own. Admin pflegt.';

CREATE TABLE profiles (
    id          uuid PRIMARY KEY,          -- = auth.users.id = JWT sub
    full_name   text NOT NULL,
    email       text,
    role        app_role_code NOT NULL,
    player_id   uuid REFERENCES players(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    -- Nur Rolle 'player' darf an einen Spieler-Datensatz gekoppelt sein.
    CONSTRAINT profiles_player_link_ck
        CHECK ((role = 'player' AND player_id IS NOT NULL)
            OR (role <> 'player' AND player_id IS NULL))
);

COMMENT ON TABLE profiles IS 'Autoritative Quelle fuer role + player_id. JWT-Claim app_role wird hieraus gespiegelt.';

CREATE UNIQUE INDEX profiles_player_id_uq ON profiles(player_id) WHERE player_id IS NOT NULL;
CREATE INDEX profiles_role_ix ON profiles(role);

CREATE TABLE daily_checkins (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id       uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    checkin_date    date NOT NULL DEFAULT current_date,
    sleep_hours     numeric(4,2) CHECK (sleep_hours >= 0 AND sleep_hours <= 24),
    sleep_quality   smallint CHECK (sleep_quality BETWEEN 1 AND 10),
    soreness        smallint CHECK (soreness BETWEEN 1 AND 10),
    mood            smallint CHECK (mood BETWEEN 1 AND 10),
    stress          smallint CHECK (stress BETWEEN 1 AND 10),
    energy          smallint CHECK (energy BETWEEN 1 AND 10),
    free_text       text,
    visibility_flag checkin_visibility NOT NULL DEFAULT 'staff',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (player_id, checkin_date)
);

COMMENT ON COLUMN daily_checkins.free_text IS
    'Feld-Gate: bei visibility_flag = med_only nur fuer Med-Rollen und den Spieler selbst. Durchgesetzt via View daily_checkins_staff.';

CREATE INDEX daily_checkins_player_date_ix ON daily_checkins(player_id, checkin_date DESC);

CREATE TABLE baselines (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id    uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    metric       text NOT NULL,
    window_days  smallint NOT NULL DEFAULT 28 CHECK (window_days > 0),
    mean_value   numeric(10,4),
    stddev_value numeric(10,4),
    sample_count integer NOT NULL DEFAULT 0,
    computed_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (player_id, metric, window_days)
);

COMMENT ON TABLE baselines IS 'Rolling-Profil. Read-only fuer alle App-Rollen, Schreiben nur Service-Role.';

CREATE TABLE readiness_scores (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id   uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    score_date  date NOT NULL DEFAULT current_date,
    value       numeric(5,2) NOT NULL CHECK (value >= 0 AND value <= 100),
    factors     jsonb NOT NULL DEFAULT '{}'::jsonb,
    computed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (player_id, score_date)
);

COMMENT ON TABLE readiness_scores IS 'Schreiben nur via Service/Trigger. Phase-4-Gating der Faktoren ist App-Logik, nicht DB (Matrix 4.3).';

-- ADR-005: bewusst NICHT "InjuryRiskSignal" — deskriptive Abweichung, kein MDR-Claim.
CREATE TABLE load_deviations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id       uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    detected_at     timestamptz NOT NULL DEFAULT now(),
    metric          text NOT NULL,
    deviation_pct   numeric(6,2) NOT NULL,
    severity        text NOT NULL DEFAULT 'info'
                         CHECK (severity IN ('info', 'watch', 'elevated')),
    factors         jsonb NOT NULL DEFAULT '{}'::jsonb,
    aggregate_label text
);

COMMENT ON TABLE load_deviations IS
    'ADR-005: deskriptive Belastungsabweichung, KEIN Verletzungsrisiko-Claim, KEIN MDR-Scope.';

CREATE INDEX load_deviations_player_ix ON load_deviations(player_id, detected_at DESC);

-- ---------------------------------------------------------------------------
-- 5. Tabellen — 3.3 Training & Wettkampf
-- ---------------------------------------------------------------------------

CREATE TABLE training_sessions (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title         text NOT NULL,
    session_date  date NOT NULL,
    start_time    time,
    duration_min  smallint CHECK (duration_min > 0),
    session_type  text NOT NULL DEFAULT 'field'
                       CHECK (session_type IN ('field', 'gym', 'recovery', 'tactical', 'test')),
    planned_load  numeric(8,2),
    notes         text,
    created_by    uuid REFERENCES profiles(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE session_loads (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id   uuid NOT NULL REFERENCES training_sessions(id) ON DELETE CASCADE,
    player_id    uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    rpe          smallint CHECK (rpe BETWEEN 1 AND 10),
    duration_min smallint CHECK (duration_min > 0),
    session_load numeric(8,2) GENERATED ALWAYS AS (rpe * duration_min) STORED,
    submitted_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (session_id, player_id)
);

COMMENT ON TABLE session_loads IS 'sRPE. Spieler schreibt eigenen Wert, Staff liest alle.';

CREATE TABLE matches (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    opponent    text NOT NULL,
    match_date  date NOT NULL,
    kickoff     time,
    home_away   text NOT NULL DEFAULT 'home' CHECK (home_away IN ('home', 'away')),
    competition text,
    result      text,
    created_by  uuid REFERENCES profiles(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE attendance (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id   uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    event_type  text NOT NULL CHECK (event_type IN ('training', 'match', 'meeting', 'treatment')),
    event_id    uuid,
    event_date  date NOT NULL,
    status      text NOT NULL DEFAULT 'present'
                     CHECK (status IN ('present', 'absent', 'excused', 'late', 'partial')),
    reason      text,
    recorded_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
    recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX attendance_player_ix ON attendance(player_id, event_date DESC);

CREATE TABLE development_goals (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id       uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    title           text NOT NULL,
    description     text,
    target_date     date,
    progress        smallint NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
    status          text NOT NULL DEFAULT 'open'
                         CHECK (status IN ('open', 'in_progress', 'achieved', 'dropped')),
    self_assessment text,
    created_by      uuid REFERENCES profiles(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE development_goals IS 'Spieler darf die eigene Zeile bewerten (U own). Anlage via Service/Staff-Backoffice.';

-- ---------------------------------------------------------------------------
-- 6. Tabellen — 3.4 Medizin (SENSITIV)
-- ---------------------------------------------------------------------------

CREATE TABLE medical_records (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id        uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    record_date      date NOT NULL DEFAULT current_date,
    category         text NOT NULL DEFAULT 'assessment'
                          CHECK (category IN ('assessment', 'injury', 'illness', 'treatment', 'rehab', 'clearance')),
    diagnosis        text,
    symptoms         text,
    treatment        text,
    rehab_plan       text,
    clearance        medical_clearance NOT NULL DEFAULT 'green',
    visibility       medical_visibility NOT NULL DEFAULT 'med_only',
    author_profile_id uuid REFERENCES profiles(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE medical_records IS
    'Hartes Gate: Basiszeile nur fuer physio/arzt (R/W/U), Spieler own (R) und admin (R, Audit). Coach/Athletik NIE — nur medical_status_view.';

CREATE INDEX medical_records_player_ix ON medical_records(player_id, updated_at DESC);

-- ---------------------------------------------------------------------------
-- 7. Tabellen — 3.5 Team / Kommunikation / Disziplin
-- ---------------------------------------------------------------------------

CREATE TABLE calendar_events (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title      text NOT NULL,
    event_type text NOT NULL DEFAULT 'other'
                    CHECK (event_type IN ('training', 'match', 'meeting', 'treatment', 'travel', 'other')),
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz,
    location   text,
    audience   text NOT NULL DEFAULT 'team',
    created_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT calendar_events_range_ck CHECK (ends_at IS NULL OR ends_at >= starts_at)
);

CREATE TABLE messages (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_profile_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    -- Zustellung entweder an eine Gruppe (Rolle oder 'team') ODER an einen Spieler.
    to_role           text CHECK (to_role IN ('team', 'player', 'coach', 'athletik', 'physio', 'arzt', 'admin')),
    to_player_id      uuid REFERENCES players(id) ON DELETE CASCADE,
    subject           text,
    body              text NOT NULL,
    sent_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT messages_target_ck CHECK (to_role IS NOT NULL OR to_player_id IS NOT NULL)
);

CREATE INDEX messages_to_role_ix ON messages(to_role);
CREATE INDEX messages_to_player_ix ON messages(to_player_id);

CREATE TABLE fines (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id    uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    reason       text NOT NULL,
    amount_cents integer NOT NULL CHECK (amount_cents >= 0),
    fine_date    date NOT NULL DEFAULT current_date,
    paid         boolean NOT NULL DEFAULT false,
    created_by   uuid REFERENCES profiles(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 8. Tabellen — 3.6 Spaetere Module (Schema + RLS angelegt, MVP-OUT)
-- ---------------------------------------------------------------------------

CREATE TABLE wearable_samples (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id  uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    source     text NOT NULL,
    sampled_at timestamptz NOT NULL DEFAULT now(),
    metric     text NOT NULL,
    value      numeric(12,4),
    raw        jsonb NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE wearable_samples IS 'Rohdaten. Nur athletik (+ admin Audit) und Spieler own. Coach und Med-Rollen bewusst NEIN.';

CREATE INDEX wearable_samples_player_ix ON wearable_samples(player_id, sampled_at DESC);

CREATE TABLE video_clips (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id  uuid REFERENCES players(id) ON DELETE CASCADE,
    match_id   uuid REFERENCES matches(id) ON DELETE SET NULL,
    title      text NOT NULL,
    url        text NOT NULL,
    tags       text[] NOT NULL DEFAULT '{}',
    created_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 9. Audit — ADR-004 (Matrix 5)
-- ---------------------------------------------------------------------------

CREATE TABLE access_log (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    viewer_profile_id uuid REFERENCES profiles(id) ON DELETE SET NULL,
    player_id         uuid REFERENCES players(id) ON DELETE CASCADE,
    table_name        text NOT NULL,
    record_id         uuid,
    action            text NOT NULL DEFAULT 'select'
                           CHECK (action IN ('select', 'insert', 'update', 'delete', 'export')),
    at                timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE access_log IS
    'ADR-004: "Wer sah meine Daten". INSERT ausschliesslich via log_access() (SECURITY DEFINER) oder Service-Role.';

CREATE INDEX access_log_player_ix ON access_log(player_id, at DESC);

COMMIT;

-- ============================================================================
-- 10. Helferfunktionen (SECURITY DEFINER, STABLE) — Matrix 2
--     SECURITY DEFINER, weil current_app_role()/current_player_id() auf
--     profiles zugreifen und dabei NICHT durch die profiles-RLS laufen duerfen
--     (sonst Rekursion Policy -> Funktion -> Policy).
--     search_path fix gesetzt: kein Hijacking ueber temporaere Objekte.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION current_profile_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
    SELECT auth.uid();
$$;

COMMENT ON FUNCTION current_profile_id() IS 'JWT sub = auth.users.id = profiles.id.';

CREATE OR REPLACE FUNCTION current_app_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
    -- Primaer der gespiegelte JWT-Claim, Fallback der Join auf profiles.
    SELECT coalesce(
        nullif(auth.jwt() ->> 'app_role', ''),
        (SELECT p.role::text FROM profiles p WHERE p.id = auth.uid())
    );
$$;

COMMENT ON FUNCTION current_app_role() IS 'app_role-Claim aus dem JWT, Fallback profiles.role.';

CREATE OR REPLACE FUNCTION current_player_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
    SELECT p.player_id FROM profiles p WHERE p.id = auth.uid();
$$;

COMMENT ON FUNCTION current_player_id() IS 'player_id des aktuellen Profils. NULL bei Staff.';

CREATE OR REPLACE FUNCTION is_medical_role()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
    SELECT current_app_role() IN ('physio', 'arzt');
$$;

CREATE OR REPLACE FUNCTION is_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
    SELECT current_app_role() IN ('coach', 'athletik', 'physio', 'arzt', 'admin');
$$;

REVOKE EXECUTE ON FUNCTION current_profile_id(), current_app_role(), current_player_id(),
                            is_medical_role(), is_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION current_profile_id(), current_app_role(), current_player_id(),
                          is_medical_role(), is_staff() TO authenticated, anon, service_role;

COMMIT;

-- ============================================================================
-- 11. Spalten-Trennung via Security-Definer-Views — Matrix 4
--     Views laufen in PG 15+ per Default mit den Rechten des View-Owners
--     (security_invoker = false) und umgehen damit die RLS der Basistabelle.
--     Die Zeilenfilterung passiert deshalb IN der View.
-- ============================================================================

BEGIN;

-- 11.1 medical_status_view — Status-Badge fuer Nicht-Med-Rollen.
--      Entblendet medical_records auf (player_id, clearance, visibility, updated_at).
--      Eine Zeile je Spieler: der aktuellste Record = der gueltige Badge.
CREATE VIEW medical_status_view
WITH (security_invoker = false) AS
SELECT DISTINCT ON (m.player_id)
       m.player_id,
       m.clearance,
       m.visibility,
       m.updated_at
FROM medical_records m
WHERE is_staff()
   OR m.player_id = current_player_id()
ORDER BY m.player_id, m.updated_at DESC, m.id;

COMMENT ON VIEW medical_status_view IS
    'Matrix 3.4/4.1: Badge-Sicht auf medical_records fuer alle Rollen. Keine Diagnose, keine Symptome, keine Behandlung.';

-- 11.2 daily_checkins_staff — Feld-Gate auf free_text.
--      free_text ist NULL, wenn visibility_flag = med_only UND der Betrachter
--      weder Med-Rolle noch der Spieler selbst ist.
CREATE VIEW daily_checkins_staff
WITH (security_invoker = false) AS
SELECT c.id,
       c.player_id,
       c.checkin_date,
       c.sleep_hours,
       c.sleep_quality,
       c.soreness,
       c.mood,
       c.stress,
       c.energy,
       CASE
           WHEN c.visibility_flag = 'med_only'
                AND NOT is_medical_role()
                AND c.player_id IS DISTINCT FROM current_player_id()
           THEN NULL
           ELSE c.free_text
       END AS free_text,
       c.visibility_flag,
       c.created_at,
       c.updated_at
FROM daily_checkins c
WHERE is_staff()
   OR c.player_id = current_player_id();

COMMENT ON VIEW daily_checkins_staff IS
    'Matrix 4.2: Spalten-Gate auf free_text. Coach/Athletik/Admin sehen bei med_only NULL, Med-Rollen und der Spieler selbst sehen den Text.';

COMMIT;

-- ============================================================================
-- 12. Audit- und Portabilitaets-Funktionen — Matrix 5
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION log_access(
    p_player_id  uuid,
    p_table_name text,
    p_record_id  uuid DEFAULT NULL,
    p_action     text DEFAULT 'select'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO access_log (viewer_profile_id, player_id, table_name, record_id, action)
    VALUES (current_profile_id(), p_player_id, p_table_name, p_record_id, p_action)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION log_access(uuid, text, uuid, text) IS
    'ADR-004: einziger Schreibpfad in access_log fuer App-Rollen. Es gibt bewusst KEINE INSERT-Policy auf access_log.';

CREATE OR REPLACE FUNCTION data_portability_export(p_player_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_result jsonb;
BEGIN
    -- Art. 20 DSGVO: nur der Spieler selbst oder Admin.
    -- coalesce ist Pflicht: current_player_id() ist bei Staff NULL, und
    -- NULL = p_player_id ergibt NULL, nicht false. Ohne coalesce wuerde
    -- NOT (NULL OR false) zu NULL und der Zugriff bliebe ungeprueft.
    IF NOT (coalesce(current_player_id() = p_player_id, false)
            OR coalesce(current_app_role() = 'admin', false)) THEN
        RAISE EXCEPTION 'insufficient_privilege: data_portability_export is restricted to the data subject or admin'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'exported_at',       now(),
        'player',            (SELECT to_jsonb(p) FROM players p WHERE p.id = p_player_id),
        'profile',           (SELECT to_jsonb(pr) FROM profiles pr WHERE pr.player_id = p_player_id),
        'daily_checkins',    coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM daily_checkins    t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'baselines',         coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM baselines         t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'readiness_scores',  coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM readiness_scores  t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'load_deviations',   coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM load_deviations   t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'session_loads',     coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM session_loads     t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'attendance',        coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM attendance        t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'development_goals', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM development_goals t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'medical_records',   coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM medical_records   t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'fines',             coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM fines             t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'wearable_samples',  coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM wearable_samples  t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'video_clips',       coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM video_clips       t WHERE t.player_id = p_player_id), '[]'::jsonb),
        'access_log',        coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM access_log        t WHERE t.player_id = p_player_id), '[]'::jsonb)
    ) INTO v_result;

    PERFORM log_access(p_player_id, 'data_portability_export', NULL, 'export');

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION data_portability_export(uuid) IS
    'Art. 20 DSGVO Escrow-Export. Aufrufbar nur vom Spieler selbst oder von Admin.';

REVOKE EXECUTE ON FUNCTION log_access(uuid, text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION data_portability_export(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION log_access(uuid, text, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION data_portability_export(uuid) TO authenticated, service_role;

COMMIT;

-- ============================================================================
-- 13. updated_at-Trigger
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'players', 'profiles', 'daily_checkins', 'training_sessions', 'matches',
        'development_goals', 'medical_records', 'calendar_events', 'fines', 'video_clips'
    ]
    LOOP
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
            t || '_set_updated_at', t
        );
    END LOOP;
END
$$;

COMMIT;
