-- 20260924000044_morning_ops_role_guard.sql (Quelle: backend/08_dashboard_migration.sql) — Bridge Punkt 67
--
-- app.rpc_morning_ops() filterte die Personenauswahl nur nach ap.team_id und
-- ap.is_active, keine Rolle. Physio, Arzt und Admin standen deshalb mit in
-- der "Kader"-Liste (gefunden 2026-09-23/24 beim ersten echten Rendern des
-- Trainer-Kader-Screens, AP-46). Kein Datenleck (Name/Position duerfen Staff
-- laut Matrix lesen), aber fachlich falsch, betrifft auch das
-- Web-Trainer-Dashboard (KaderGrid.tsx, dieselbe Tuer).
--
-- Gleicher Fix wie bei app.rpc_list_team_members (Punkt 66,
-- backend/32_team_members_door.sql Zeile ~139-147): dasselbe EXISTS gegen
-- app.role_assignments, role = 'player', team_id Abgleich, Gueltigkeitsfenster
-- valid_from/valid_to. Liste und Kader-Payload duerfen nicht auseinanderlaufen.
--
-- Kein DROP: gleiche Signatur, gleicher Rueckgabetyp (jsonb), CREATE OR
-- REPLACE genuegt und laesst die Rechte der Funktion unangetastet. Kein
-- GRANT/REVOKE geaendert.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 20260922000033.
-- Idempotent.
-- =============================================================================

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
        -- Nur das Band. KEIN score_total, KEINE factors: siehe backend/08_dashboard_migration.sql.
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
        'hasCheckIn', EXISTS (SELECT 1 FROM app.daily_checkins dc WHERE dc.person_id = ap.id AND dc.date = current_date)
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
      -- Bridge Punkt 67: dasselbe Praedikat wie app.auth_target_is_team_player
      -- und app.rpc_list_team_members, damit Liste und Kader-Payload nicht
      -- auseinanderlaufen. Physio, Arzt und Admin verschwinden damit aus dem
      -- Kader-Payload.
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
