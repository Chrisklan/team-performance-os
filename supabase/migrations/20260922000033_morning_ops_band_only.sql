-- =============================================================================
-- 20260922000033_morning_ops_band_only.sql
-- app.rpc_morning_ops() liefert dem Trainerteam nur noch readiness.band.
-- Befund N7 der Opus-Gegenlesung (AP-45, 2026-09-22), Bridge Punkt 50.
--
-- Was der Befund sagt (Beleg Audits/2026-09-21-ap45-bodymap-verlauf 11.5):
-- app.rpc_morning_ops() baute 'readiness' aus rs.score_total, rs.band und
-- rs.factors. Ihr Waechter ist "IF NOT app.auth_is_staff()", also genau
-- coach und athletic_coach. Die kanonische Rollen-Zugriffsmatrix
-- (Module/Modul-Rollen-Medizin-Gate Abschnitt 5) setzt fuer beide Rollen in
-- den Zeilen readiness_scores.score_total und readiness_scores.factors ein
-- fett markiertes "-". Die Funktion ist SECURITY DEFINER und ging damit an
-- den Spaltenrechten vorbei, die denselben Schutz auf der Tabelle leisten:
--   authenticated auf app.readiness_scores =
--     band, computed_at, created_at, date, id, person_id, team_id
--   (score_total und factors fehlen dort absichtlich)
-- Gemessen am 2026-09-22: dieselbe Trainerin bekommt direkt
--   "permission denied for table readiness_scores",
-- durch die Tuer public.rpc_trainer_morning_ops dagegen
--   {"band":"high","value":83.0,"factors":{...,"soreness":0.4}}.
-- Das ist der einzige RPC, den der Web Client taeglich ruft
-- (lib/trainer/api.ts:45), der Befund war also live erreichbar.
--
-- Was diese Migration aendert: genau zwei Schluessel im Payload.
--   vorher: 'readiness' = {"value": rs.score_total, "band": rs.band,
--                          "factors": rs.factors}
--   nachher: 'readiness' = {"band": rs.band}
-- Die Schluessel werden entfernt, nicht auf null gesetzt: ein null-Feld
-- laedt dazu ein, es spaeter wieder zu fuellen.
--
-- Was diese Migration NICHT aendert:
-- * Waechter, Silo, Zeilenmenge, Reihenfolge, alle uebrigen Felder des
--   Payloads (player, baseline, medicalStatus, medicalClearance,
--   attendance, todayEvent, hasCheckIn) bleiben Zeichen fuer Zeichen gleich.
-- * Der Lesepfad fuer Medizin und self bleibt app.rpc_readiness_full
--   (physio, doctor, eigene Person), der beide Felder vollstaendig liefert.
-- * Keine Rechte, keine Policy, keine Tabelle, keine Datenzeile.
--
-- Kein DROP: gleiche Signatur, gleicher Rueckgabetyp, CREATE OR REPLACE
-- genuegt und laesst die Rechte der Funktion unangetastet.
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
  'Trainer-Kader-Payload. Medizin-Gate: nur readiness.band, nie score_total oder factors (Befund N7, 2026-09-22).';
