-- =============================================================================
-- 08_dashboard_migration.sql — rpc_morning_ops()
-- Liefert den Coach-Kader-Payload (CoachKaderPayload-Form) fuer das
-- Trainer-Dashboard aus app.persons, app.readiness_scores,
-- app.daily_checkins und app.medical_clearances.
-- Stand wie in der Cloud (Migration 20260918000015, AP-27/AP-32 Angleichung
-- 2026-09-19). Vorher las die Funktion public.*, das ist ersetzt.
-- ADR-001 Silo: Scoping ausschliesslich ueber app.auth_team_id().
-- ADR-009 Rollen-Matrix: nur Staff (coach/athletic_coach) darf lesen.
-- Idempotent: DROP IF EXISTS vor CREATE.
-- Voraussetzung: 08_reconciling.sql und 09_rpcs.sql (Tabellen, Helper).
-- =============================================================================

DROP FUNCTION IF EXISTS app.rpc_morning_ops();

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
        'readiness', jsonb_build_object(
          'value', rs.score_total,
          'band', rs.band,
          'factors', rs.factors
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
  ) m;

  RETURN jsonb_build_object(
    'kaderName', coalesce(v_kader_name, ''),
    'syncState', 'live',
    'asOf', to_char(current_date, 'YYYY-MM-DD'),
    'members', v_members
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_morning_ops() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_morning_ops() TO authenticated, anon, service_role;
