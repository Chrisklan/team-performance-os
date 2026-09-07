-- =============================================================================
-- 20260907000011_seed_reconcile.sql — Seed Reconcile
-- Migrates existing seed data from public.players/profiles into app.persons
-- and app.role_assignments. Idempotent (ON CONFLICT DO NOTHING).
-- =============================================================================

-- 0. Ensure a team exists (idempotent)
--    If app.teams is empty, create the default team. If it has rows, skip.
DO $$
DECLARE
  v_team_id uuid;
BEGIN
  SELECT id INTO v_team_id FROM app.teams LIMIT 1;

  IF v_team_id IS NULL THEN
    INSERT INTO app.teams (id, name, timezone)
    VALUES (
      '11111111-1111-1111-1111-111111111111'::uuid,
      'BSV Buxtehude',
      'Europe/Berlin'
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING id INTO v_team_id;
  END IF;
END $$;

-- 1. Migrate public.profiles → app.persons
--    Mapping:
--      id              → id
--      full_name       → display_name
--      id              → auth_user_id (profiles.id = auth.users.id via trigger)
--      player_id       → join to public.players for birth_date, position, squad_number
--      status          → is_active (active = true, else false)
--    team_id is NOT NULL → pulled from app.teams (single team assumption)
INSERT INTO app.persons (
  id,
  team_id,
  auth_user_id,
  display_name,
  person_position,
  shirt_number,
  birth_date,
  is_active,
  created_at,
  updated_at
)
SELECT
  pr.id,
  (SELECT id FROM app.teams LIMIT 1),
  pr.id,
  pr.full_name,
  pl.position,
  pl.squad_number,
  pl.birth_date,
  COALESCE(pl.status = 'active', true),
  pr.created_at,
  pr.updated_at
FROM public.profiles pr
LEFT JOIN public.players pl ON pl.id = pr.player_id
ON CONFLICT (id) DO NOTHING;

-- 2. Migrate public.profiles → app.role_assignments
--    Mapping:
--      profiles.id     → person_id
--      profiles.role   → role (with mapping: athletik→athletic_coach, arzt→doctor)
--      team_id         → from app.teams
--      valid_from      → now()
--      valid_to        → NULL (current assignment)
INSERT INTO app.role_assignments (
  team_id,
  person_id,
  role,
  valid_from,
  valid_to,
  created_at
)
SELECT
  (SELECT id FROM app.teams LIMIT 1),
  pr.id,
  CASE pr.role
    WHEN 'athletik' THEN 'athletic_coach'::app.app_role
    WHEN 'arzt'     THEN 'doctor'::app.app_role
    ELSE pr.role::app.app_role
  END,
  now(),
  NULL,
  pr.created_at
FROM public.profiles pr
ON CONFLICT DO NOTHING;

-- 3. Verification (logged, not blocking)
DO $$
DECLARE
  v_persons_count int;
  v_roles_count int;
  v_null_auth int;
  v_null_team int;
BEGIN
  SELECT count(*) INTO v_persons_count FROM app.persons;
  SELECT count(*) INTO v_roles_count FROM app.role_assignments;
  SELECT count(*) INTO v_null_auth FROM app.persons WHERE auth_user_id IS NULL;
  SELECT count(*) INTO v_null_team FROM app.role_assignments WHERE team_id IS NULL;

  RAISE NOTICE 'Seed Reconcile complete: persons=%, roles=%, null_auth=%, null_team=%',
    v_persons_count, v_roles_count, v_null_auth, v_null_team;
END $$;
