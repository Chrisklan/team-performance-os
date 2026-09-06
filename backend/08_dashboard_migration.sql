-- =============================================================================
-- 08_dashboard_migration.sql — rpc_morning_ops() (AP13b-Schritt-2)
-- Liefert den Coach-Kader-Payload (CoachKaderPayload-Form) fuer das
-- Trainer-Dashboard direkt aus app.* + public.* — ersetzt die Fixtures.
-- ADR-001 Silo: Scoping ausschliesslich ueber app.auth_team_id().
-- ADR-009 Rollen-Matrix: nur Staff (coach/athletic_coach) darf lesen.
-- Idempotent: DROP IF EXISTS vor CREATE.
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
      coalesce(pl.squad_number, 0) AS jersey,
      jsonb_build_object(
        'player', jsonb_build_object(
          'id', pl.id,
          'jersey', coalesce(pl.squad_number, 0),
          'name', trim(both ' ' from (pl.first_name || ' ' || pl.last_name)),
          'position', coalesce(pl.position, '')
        ),
        'readiness', jsonb_build_object(
          'value', rs.value,
          'factors', rs.factors
        ),
        'baseline', jsonb_build_object(
          'series', coalesce(bl.series, '[]'::jsonb),
          'rollingAvg', coalesce(bl.rolling_avg, 0)
        ),
        'medicalStatus', coalesce(mr.clearance, 'green'),
        'medicalClearance', mc.clearance_mapped,
        'attendance', coalesce(att.attendance_mapped, 'anwesend'),
        'todayEvent', coalesce(ev.today_event, 'none'),
        'hasCheckIn', (rs.value IS NOT NULL)
      ) AS member
    FROM app.persons p
    JOIN public.profiles pr ON pr.id = p.auth_user_id
    JOIN public.players pl ON pl.id = pr.player_id
    LEFT JOIN public.readiness_scores rs
      ON rs.player_id = pl.id AND rs.score_date = current_date
    LEFT JOIN LATERAL (
      -- baselines hat kein Zeitreihen-Feld: series = alle mean_value je Metrik/
      -- Fenster, chronologisch nach computed_at; rollingAvg = deren Mittel.
      SELECT jsonb_agg(b.mean_value ORDER BY b.computed_at) AS series,
             round(avg(b.mean_value), 2) AS rolling_avg
      FROM public.baselines b
      WHERE b.player_id = pl.id
    ) bl ON true
    LEFT JOIN LATERAL (
      SELECT CASE a.status
               WHEN 'present' THEN 'anwesend'
               WHEN 'absent'  THEN 'krank'
               WHEN 'excused' THEN 'urlaub'
               WHEN 'late'    THEN 'anwesend'
               WHEN 'partial' THEN 'anwesend'
               ELSE 'anwesend'
             END AS attendance_mapped
      FROM public.attendance a
      WHERE a.player_id = pl.id AND a.event_date = current_date
      ORDER BY a.recorded_at DESC
      LIMIT 1
    ) att ON true
    LEFT JOIN LATERAL (
      SELECT CASE
               WHEN EXISTS (
                 SELECT 1 FROM public.training_sessions ts WHERE ts.session_date = current_date
               ) THEN 'training'
               WHEN EXISTS (
                 SELECT 1 FROM public.matches ma WHERE ma.match_date = current_date
               ) THEN 'spiel'
               ELSE 'none'
             END AS today_event
    ) ev ON true
    LEFT JOIN LATERAL (
      -- juengste, aktuell gueltige Freigabe (Rollen-Medizin-Gate, app.medical_clearances)
      SELECT CASE mcl.status
               WHEN 'full'       THEN 'frei'
               WHEN 'limited'    THEN 'eingeschraenkt'
               WHEN 'individual' THEN 'eingeschraenkt'
               WHEN 'blocked'    THEN 'gesperrt'
             END AS clearance_mapped
      FROM app.medical_clearances mcl
      WHERE mcl.person_id = p.id
        AND mcl.valid_from <= now()
        AND (mcl.valid_to IS NULL OR mcl.valid_to > now())
      ORDER BY mcl.valid_from DESC
      LIMIT 1
    ) mc ON true
    LEFT JOIN LATERAL (
      -- juengster medical_records-Eintrag, nur das Badge (clearance), keine Diagnose.
      SELECT mr2.clearance
      FROM public.medical_records mr2
      WHERE mr2.player_id = pl.id
      ORDER BY mr2.updated_at DESC
      LIMIT 1
    ) mr ON true
    WHERE p.team_id = v_team_id
      AND p.is_active = true
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
