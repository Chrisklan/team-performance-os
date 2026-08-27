-- ============================================================================
-- Team Performance OS — rls.sql
--
-- Row-Level-Security-Policies gemaess RLS-MATRIX.md Abschnitt 3.1-3.6.
-- Voraussetzung: schema.sql wurde vorher angewendet.
--
-- ADR-001 Silo: KEIN tenant_id. `*` in der Matrix bedeutet im Silo
-- "alle Zeilen der Tabelle", weil die Instanz genau einem Verein gehoert.
--
-- Grundregeln:
--   * Alle Policies gelten fuer die Rolle `authenticated`.
--     `service_role` hat BYPASSRLS (ETL, Trigger-Jobs, Score-Berechnung).
--   * Tabellen ohne Schreib-Policy sind fuer App-Rollen bewusst read-only
--     (Schreiben nur durch Service-Role: baselines, readiness_scores,
--      load_deviations, wearable_samples, access_log).
--   * DELETE wird nirgends gewaehrt (Matrix kennt kein D). Loeschen laeuft
--     ueber Service-Role bzw. Retention-Jobs.
--
-- Aufloesung eines Widerspruchs in der Matrix (dokumentiert, bewusst):
--   3.4 Tabellenzeile gibt `admin` = R(*) auf medical_records, der Fliesstext
--   darunter sagt "Admin: KEINE Basis-Tabellen-Sicht". Umgesetzt ist R(*),
--   weil DONE_WHEN 6 explizit fordert: "Admin: voller Lesezugriff, aber KEIN
--   medizinischer Schreibzugriff". Der Fokus-Test des Med-Gates nennt nur
--   coach und athletik. Admin bleibt also lesend, schreibt aber nie medizinisch.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Grants. Ohne Grant kein Zugriff, unabhaengig von RLS.
--    RLS entscheidet danach ueber die Zeilen.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON medical_status_view, daily_checkins_staff TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- ---------------------------------------------------------------------------
-- 1. RLS scharfschalten (Matrix 6)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'profiles', 'players', 'daily_checkins', 'baselines', 'readiness_scores',
        'load_deviations', 'training_sessions', 'session_loads', 'matches',
        'attendance', 'development_goals', 'medical_records', 'calendar_events',
        'messages', 'fines', 'wearable_samples', 'video_clips', 'access_log'
    ]
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    END LOOP;
END
$$;

-- ===========================================================================
-- 3.1 INFRASTRUKTUR
-- ===========================================================================

-- profiles: Staff sieht alle Profile (Namen/Rollen), Spieler nur das eigene.
CREATE POLICY profiles_select ON profiles
    FOR SELECT TO authenticated
    USING (is_staff() OR id = current_profile_id());

-- Nur Admin legt Profile an bzw. aendert Rollen.
CREATE POLICY profiles_admin_insert ON profiles
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() = 'admin');

CREATE POLICY profiles_admin_update ON profiles
    FOR UPDATE TO authenticated
    USING (current_app_role() = 'admin')
    WITH CHECK (current_app_role() = 'admin');

-- access_log (ADR-004): Spieler sieht die eigenen Zugriffe, Admin auditiert alles.
-- Coach/Athletik/Physio/Arzt haben KEINEN Lesezugriff. Kein INSERT per Policy:
-- geschrieben wird ausschliesslich via log_access() (SECURITY DEFINER).
CREATE POLICY access_log_select ON access_log
    FOR SELECT TO authenticated
    USING (current_app_role() = 'admin' OR player_id = current_player_id());

-- ===========================================================================
-- 3.2 SPIELER-KERN
-- ===========================================================================

-- players: Stammdaten. Staff liest alle, Spieler die eigene Zeile.
CREATE POLICY players_select ON players
    FOR SELECT TO authenticated
    USING (is_staff() OR id = current_player_id());

CREATE POLICY players_admin_insert ON players
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() = 'admin');

CREATE POLICY players_admin_update ON players
    FOR UPDATE TO authenticated
    USING (current_app_role() = 'admin')
    WITH CHECK (current_app_role() = 'admin');

-- daily_checkins: Staff liest alle, Spieler liest und schreibt NUR eigene.
-- Das Feld-Gate auf free_text sitzt in der View daily_checkins_staff.
CREATE POLICY daily_checkins_select ON daily_checkins
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

CREATE POLICY daily_checkins_own_insert ON daily_checkins
    FOR INSERT TO authenticated
    WITH CHECK (player_id = current_player_id());

CREATE POLICY daily_checkins_own_update ON daily_checkins
    FOR UPDATE TO authenticated
    USING (player_id = current_player_id())
    WITH CHECK (player_id = current_player_id());

-- baselines: read-only fuer App-Rollen, Berechnung durch Service-Role.
CREATE POLICY baselines_select ON baselines
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

-- readiness_scores: read-only fuer App-Rollen, Berechnung durch Service/Trigger.
CREATE POLICY readiness_scores_select ON readiness_scores
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

-- load_deviations (ADR-005): read-only fuer App-Rollen, Erzeugung durch Service.
CREATE POLICY load_deviations_select ON load_deviations
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

-- ===========================================================================
-- 3.3 TRAINING & WETTKAMPF
-- ===========================================================================

-- training_sessions: alle authentifizierten Rollen lesen (Spieler wollen
-- wissen, was ansteht). Planung nur Coach/Athletik.
CREATE POLICY training_sessions_select ON training_sessions
    FOR SELECT TO authenticated
    USING (current_app_role() IS NOT NULL);

CREATE POLICY training_sessions_planner_insert ON training_sessions
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

CREATE POLICY training_sessions_planner_update ON training_sessions
    FOR UPDATE TO authenticated
    USING (current_app_role() IN ('coach', 'athletik'))
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

-- session_loads: Spieler meldet den eigenen RPE, Staff liest alle.
CREATE POLICY session_loads_select ON session_loads
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

CREATE POLICY session_loads_own_insert ON session_loads
    FOR INSERT TO authenticated
    WITH CHECK (player_id = current_player_id());

CREATE POLICY session_loads_own_update ON session_loads
    FOR UPDATE TO authenticated
    USING (player_id = current_player_id())
    WITH CHECK (player_id = current_player_id());

-- matches: alle lesen, Coach/Athletik planen.
CREATE POLICY matches_select ON matches
    FOR SELECT TO authenticated
    USING (current_app_role() IS NOT NULL);

CREATE POLICY matches_planner_insert ON matches
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

CREATE POLICY matches_planner_update ON matches
    FOR UPDATE TO authenticated
    USING (current_app_role() IN ('coach', 'athletik'))
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

-- attendance: Status setzt Coach/Athletik, Spieler sieht den eigenen.
CREATE POLICY attendance_select ON attendance
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

CREATE POLICY attendance_staff_insert ON attendance
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

CREATE POLICY attendance_staff_update ON attendance
    FOR UPDATE TO authenticated
    USING (current_app_role() IN ('coach', 'athletik'))
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

-- development_goals: Staff liest alle, Spieler liest und bewertet das eigene.
CREATE POLICY development_goals_select ON development_goals
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

CREATE POLICY development_goals_own_update ON development_goals
    FOR UPDATE TO authenticated
    USING (player_id = current_player_id())
    WITH CHECK (player_id = current_player_id());

-- ===========================================================================
-- 3.4 MEDIZIN — hartes Gate
-- ===========================================================================

-- Basiszeile: nur physio/arzt (voll), Spieler own (ADR-004 Transparenz)
-- und admin lesend (Audit). Coach und Athletik sehen hier NICHTS —
-- fuer die gibt es ausschliesslich medical_status_view.
CREATE POLICY medical_records_select ON medical_records
    FOR SELECT TO authenticated
    USING (
        is_medical_role()
        OR current_app_role() = 'admin'
        OR player_id = current_player_id()
    );

-- Schreiben ausschliesslich Med-Rollen. Admin explizit NICHT.
CREATE POLICY medical_records_med_insert ON medical_records
    FOR INSERT TO authenticated
    WITH CHECK (is_medical_role());

CREATE POLICY medical_records_med_update ON medical_records
    FOR UPDATE TO authenticated
    USING (is_medical_role())
    WITH CHECK (is_medical_role());

-- ===========================================================================
-- 3.5 TEAM / KOMMUNIKATION / DISZIPLIN
-- ===========================================================================

-- calendar_events: alle lesen, Staff plant.
CREATE POLICY calendar_events_select ON calendar_events
    FOR SELECT TO authenticated
    USING (current_app_role() IS NOT NULL);

CREATE POLICY calendar_events_planner_insert ON calendar_events
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

CREATE POLICY calendar_events_planner_update ON calendar_events
    FOR UPDATE TO authenticated
    USING (current_app_role() IN ('coach', 'athletik'))
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

-- messages: sichtbar fuer Absender, direkt adressierten Spieler,
-- die adressierte Rollen-Gruppe, das gesamte Team und Admin (Audit).
CREATE POLICY messages_select ON messages
    FOR SELECT TO authenticated
    USING (
        sender_profile_id = current_profile_id()
        OR to_player_id = current_player_id()
        OR to_role = 'team'
        OR to_role = current_app_role()
        OR current_app_role() = 'admin'
    );

-- Senden duerfen coach, athletik, physio, arzt — und zwar nur im eigenen Namen.
-- player sendet nicht, admin liest nur.
CREATE POLICY messages_staff_insert ON messages
    FOR INSERT TO authenticated
    WITH CHECK (
        current_app_role() IN ('coach', 'athletik', 'physio', 'arzt')
        AND sender_profile_id = current_profile_id()
    );

CREATE POLICY messages_staff_update ON messages
    FOR UPDATE TO authenticated
    USING (current_app_role() IN ('coach', 'athletik', 'physio', 'arzt'))
    WITH CHECK (current_app_role() IN ('coach', 'athletik', 'physio', 'arzt'));

-- fines: Strafenkasse. Staff liest alle, Spieler sieht die eigenen,
-- verwaltet wird durch Coach/Athletik.
CREATE POLICY fines_select ON fines
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

CREATE POLICY fines_staff_insert ON fines
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

CREATE POLICY fines_staff_update ON fines
    FOR UPDATE TO authenticated
    USING (current_app_role() IN ('coach', 'athletik'))
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

-- ===========================================================================
-- 3.6 SPAETERE MODULE
-- ===========================================================================

-- wearable_samples: Rohdaten. Nur Athletiktrainer, Admin (Audit) und der
-- Spieler selbst. Coach und Med-Rollen bewusst ausgeschlossen.
CREATE POLICY wearable_samples_select ON wearable_samples
    FOR SELECT TO authenticated
    USING (
        current_app_role() IN ('athletik', 'admin')
        OR player_id = current_player_id()
    );

-- video_clips: Staff liest alle, Spieler die eigenen, Coach/Athletik pflegen.
CREATE POLICY video_clips_select ON video_clips
    FOR SELECT TO authenticated
    USING (is_staff() OR player_id = current_player_id());

CREATE POLICY video_clips_editor_insert ON video_clips
    FOR INSERT TO authenticated
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

CREATE POLICY video_clips_editor_update ON video_clips
    FOR UPDATE TO authenticated
    USING (current_app_role() IN ('coach', 'athletik'))
    WITH CHECK (current_app_role() IN ('coach', 'athletik'));

COMMIT;
