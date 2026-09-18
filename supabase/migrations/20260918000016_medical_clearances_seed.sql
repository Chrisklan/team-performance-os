-- Migration: 20260918000016_medical_clearances_seed.sql
-- Seed: Für alle 25 Pilot-Spieler 'full' (frei) einrichten.
-- Medizin-Gate funktioniert sonst nicht — der Pilot braucht gültige Badges.

INSERT INTO app.medical_clearances (
  id, team_id, person_id, status, load_note, valid_from, valid_to, set_by, set_by_role
)
SELECT
  gen_random_uuid(),
  p.team_id,
  p.id,
  'full',
  'Seed: Pilot freigegeben',
  now(),
  now() + interval '1 year',
  p.id,
  'admin'
FROM app.persons p;
