-- =============================================================================
-- 20260919000020_move_player_email.sql — Spieler-Login auf spieler@c-klan.de
-- (AP-29, Entscheidung Chris 2026-09-19: E-Mail umstellen, Bindung behalten)
--
-- Vorher (Admin API, 2026-09-19): auth.users 95fe2495-… (Maximilian Krueger,
-- Rolle player) von mail@c-klan.de auf spieler@c-klan.de umgestellt, bestaetigt.
-- auth.users.id, public.profiles.id und app.persons.auth_user_id bleiben gleich.
--
-- Diese Migration zieht nur public.profiles.email nach, damit Profil und
-- Auth-User dieselbe Adresse tragen (handle_new_user bindet ueber sie).
--
-- Fail closed:
--   * Profil fehlt
--   * Auth-User traegt nicht spieler@c-klan.de (Admin-API-Schritt fehlt)
--   * Zieladresse liegt auf einem anderen Profil
--   * aktuelle Adresse ist weder alt noch Ziel
-- Idempotent: Traegt das Profil die Zieladresse bereits, passiert nichts.
-- =============================================================================

DO $$
DECLARE
  c_profile_id  constant uuid := '95fe2495-7de9-4b44-af51-9f792ef6ddea';
  c_old_email   constant text := 'mail@c-klan.de';
  c_new_email   constant text := 'spieler@c-klan.de';
  v_current     text;
  v_updated     integer;
BEGIN
  SELECT lower(btrim(pr.email)) INTO v_current
  FROM public.profiles pr
  WHERE pr.id = c_profile_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TPOS player email: profile % not found', c_profile_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM auth.users u
    WHERE u.id = c_profile_id
      AND lower(btrim(u.email)) = c_new_email
  ) THEN
    RAISE EXCEPTION 'TPOS player email: auth user % does not carry %; run the Admin API step first', c_profile_id, c_new_email
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles pr
    WHERE lower(btrim(pr.email)) = c_new_email
      AND pr.id <> c_profile_id
  ) THEN
    RAISE EXCEPTION 'TPOS player email: % is already assigned to a different profile', c_new_email
      USING ERRCODE = '23505';
  END IF;

  IF v_current = c_new_email THEN
    RAISE NOTICE 'TPOS player email: profile % already uses %; no change', c_profile_id, c_new_email;
    RETURN;
  END IF;

  IF v_current IS DISTINCT FROM c_old_email THEN
    RAISE EXCEPTION 'TPOS player email: profile % has unexpected e-mail % (expected %)', c_profile_id, coalesce(v_current, '<null>'), c_old_email
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
  SET email = c_new_email
  WHERE id = c_profile_id
    AND lower(btrim(email)) = c_old_email;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'TPOS player email: expected to update exactly 1 profile, updated %', v_updated;
  END IF;
END $$;
