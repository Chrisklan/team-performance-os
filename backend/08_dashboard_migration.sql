-- =============================================================================
-- 08_dashboard_migration.sql — rpc_morning_ops()
-- Liefert den Coach-Kader-Payload (CoachKaderPayload-Form) fuer das
-- Trainer-Dashboard aus app.persons, app.readiness_scores,
-- app.daily_checkins und app.medical_clearances.
-- Stand: Migration <naechste_freie_nummer>_morning_ops_role_guard (Bridge
-- Punkt 67, 2026-09-24). Davor 20260922000033 (AP-55, Befund N7 der
-- Opus-Gegenlesung). Davor 20260918000015 (AP-27/AP-32 Angleichung
-- 2026-09-19), davor las die Funktion public.*, das ist ersetzt.
-- ADR-001 Silo: Scoping ausschliesslich ueber app.auth_team_id().
-- ADR-009 Rollen-Matrix: nur Staff (coach/athletic_coach) darf lesen.
--
-- Bridge Punkt 67 (2026-09-23/24): die Personenauswahl filterte nur nach
-- ap.team_id und ap.is_active, keine Rolle. Physio, Arzt und Admin standen
-- deshalb mit in der "Kader"-Liste, sichtbar geworden beim ersten echten
-- Rendern des Trainer-Kader-Screens (AP-46). Kein Datenleck (Name/Position
-- duerfen Staff laut Matrix lesen), aber fachlich falsch. Gleicher Fix wie
-- bei app.rpc_list_team_members (Punkt 66, backend/32_team_members_door.sql
-- Zeile ~139-147): dasselbe EXISTS-Praedikat gegen app.role_assignments,
-- role = 'player', mit Gueltigkeitsfenster. Liste und Kader-Payload duerfen
-- nicht auseinanderlaufen, dieselbe Begruendung wie bei der Mitgliederliste.
--
-- Medizin-Gate (Modul-Rollen-Medizin-Gate Abschnitt 5, fett markierte Striche):
-- Staff bekommt Zustandsklassen, nie Zahlwerte oder Verlaeufe. Der Payload
-- traegt deshalb NUR readiness.band (low/moderate/high). score_total und
-- factors standen bis zum 2026-09-22 darin und waren damit fuer coach und
-- athletic_coach live erreichbar, obwohl die Spaltenrechte von authenticated
-- auf app.readiness_scores beide Spalten sperren (band, computed_at,
-- created_at, date, id, person_id, team_id) - die SECURITY DEFINER Funktion
-- ging an diesem Schutz vorbei. Der Lesepfad fuer Medizin und self ist und
-- bleibt app.rpc_readiness_full, der beide Felder vollstaendig liefert.
-- Wer hier wieder ein Zahlfeld einbaut, hebt das Medizin-Gate auf und
-- braucht nach der harten Regel des Moduls ein neues ADR.
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
        -- Nur das Band. KEIN score_total, KEINE factors: siehe Kopf.
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

-- Rechte wie in der Cloud gemessen (2026-09-22):
--   authenticated=EXECUTE, postgres=EXECUTE, service_role=EXECUTE, kein PUBLIC.
-- anon steht hier bis zum 2026-09-22 im GRANT und war damit ein Ruecklaeufer:
-- Migration 20260921000024 (AP-39b) hat anon jedes EXECUTE in app entzogen,
-- ein Neuaufbau der Test DB nach der dokumentierten Reihenfolge gab es hier
-- aber sofort zurueck. Gefunden hat das Suite 15 (anon kann keine Funktion in
-- app mehr ausfuehren, have 1 want 0), nachdem diese Datei neu eingespielt
-- wurde. Die Cloud war nie betroffen, dort laeuft nur die Migration.
REVOKE EXECUTE ON FUNCTION app.rpc_morning_ops() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_morning_ops() FROM anon;
GRANT EXECUTE ON FUNCTION app.rpc_morning_ops() TO authenticated, service_role;
