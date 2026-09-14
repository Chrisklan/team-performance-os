-- =============================================================================
-- 20260914000013_assign_internal_pilot_email.sql — Interne Pilot-Login-E-Mail
--
-- Problem:
--   Das Seed-Profil von Max Kruger traegt max.kruger@tpos.local. ".local" ist
--   eine reservierte, nicht routbare Domain (RFC 6762, mDNS). Supabase Auth
--   kann dorthin keinen Magic Link zustellen; die Adresse ist als Login-
--   Identitaet fuer den Pilot unbrauchbar.
--
-- Entscheidung (einmalig, interner Pilot):
--   * public.profiles.email des exakten Seed-Profils
--       a0000000-0000-0000-0000-000000000001
--     wird von max.kruger@tpos.local auf mail@c-klan.de umgestellt, damit der
--     Magic Link im aktiven Pilot-Postfach ankommt.
--   * Sonst wird NICHTS veraendert: id, player_id, role, full_name des Profils,
--     app.persons, app.role_assignments und auth.users bleiben unberuehrt.
--
-- Erhaltener Ablauf (20260914000012):
--   public.handle_new_user() bindet einen neuen auth.users-Eintrag ueber die
--   normalisierte E-Mail an genau ein Seed-Profil und schreibt danach
--   profiles.id sowie app.persons.auth_user_id um. Nach dieser Migration
--   matcht der erste Magic-Link-Login mit mail@c-klan.de genau dieses Profil;
--   app.persons.id und die Rollen-Zuordnung bleiben stabil.
--
-- Fail closed (vor jeder Mutation, Zeile per FOR UPDATE gesperrt):
--   * Seed-Profil fehlt
--   * Zieladresse liegt bereits auf einem anderen Profil
--   * aktuelle normalisierte E-Mail ist weder alt noch Ziel
--   * ein auth.users-Eintrag besitzt die Zieladresse bereits
-- Idempotent: Traegt das Seed-Profil die Zieladresse bereits, passiert nichts.
-- Atomar: Die Supabase-CLI spielt jede Migrationsdatei in einer Transaktion ein.
-- =============================================================================

DO $$
DECLARE
  c_profile_id  constant uuid := 'a0000000-0000-0000-0000-000000000001';
  c_old_email   constant text := 'max.kruger@tpos.local';
  c_new_email   constant text := 'mail@c-klan.de';
  v_current     text;
  v_updated     integer;
BEGIN
  -- (1) Seed-Profil sperren und aktuelle E-Mail normalisiert lesen.
  SELECT lower(btrim(pr.email)) INTO v_current
  FROM public.profiles pr
  WHERE pr.id = c_profile_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TPOS pilot email: seed profile % not found; refusing to assign %', c_profile_id, c_new_email
      USING ERRCODE = 'P0002';
  END IF;

  -- (2) Zieladresse darf auf keinem anderen Profil liegen.
  IF EXISTS (
    SELECT 1
    FROM public.profiles pr
    WHERE lower(btrim(pr.email)) = c_new_email
      AND pr.id <> c_profile_id
  ) THEN
    RAISE EXCEPTION 'TPOS pilot email: e-mail % is already assigned to a different profile', c_new_email
      USING ERRCODE = '23505';
  END IF;

  -- (3) Bereits umgestellt: nichts tun.
  IF v_current = c_new_email THEN
    RAISE NOTICE 'TPOS pilot email: seed profile % already uses %; no change', c_profile_id, c_new_email;
    RETURN;
  END IF;

  -- (4) Nur von exakt der erwarteten alten Adresse umstellen.
  IF v_current IS DISTINCT FROM c_old_email THEN
    RAISE EXCEPTION 'TPOS pilot email: seed profile % has unexpected e-mail % (expected %)', c_profile_id, coalesce(v_current, '<null>'), c_old_email
      USING ERRCODE = '22023';
  END IF;

  -- (5) Kein auth.users-Eintrag darf die Zieladresse bereits besitzen.
  IF EXISTS (
    SELECT 1
    FROM auth.users u
    WHERE lower(btrim(u.email)) = c_new_email
  ) THEN
    RAISE EXCEPTION 'TPOS pilot email: auth user for % already exists; refusing to reassign profile %', c_new_email, c_profile_id
      USING ERRCODE = '23505';
  END IF;

  -- (6) Einzige Mutation: E-Mail des gesperrten Seed-Profils.
  UPDATE public.profiles
  SET email = c_new_email
  WHERE id = c_profile_id
    AND lower(btrim(email)) = c_old_email;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'TPOS pilot email: expected to update exactly 1 profile, updated %', v_updated;
  END IF;
END $$;


-- =============================================================================
-- Verifikation nach dem Einspielen (nur lesend, manuell ausfuehren)
-- =============================================================================
--
-- V1  Seed-Profil traegt die neue Adresse, Stammdaten unveraendert:
--       SELECT pr.id, pr.email, pr.role, pr.full_name, pr.player_id
--       FROM public.profiles pr
--       WHERE pr.id = 'a0000000-0000-0000-0000-000000000001';
--     Erwartet: email = mail@c-klan.de,
--               player_id = b04077db-eab6-4345-9df3-4d14a172dc1c
--
-- V2  Genau ein Profil mit der Zieladresse, keins mehr mit der alten:
--       SELECT lower(btrim(email)) AS email, count(*)
--       FROM public.profiles
--       WHERE lower(btrim(email)) IN ('mail@c-klan.de', 'max.kruger@tpos.local')
--       GROUP BY 1;
--     Erwartet: 1 Zeile, mail@c-klan.de | 1
--
-- V3  app.persons weiterhin an die Seed-ID gebunden (vor dem ersten Login):
--       SELECT pe.id, pe.auth_user_id
--       FROM app.persons pe
--       WHERE pe.id = 'a0000000-0000-0000-0000-000000000001';
--     Erwartet: auth_user_id = a0000000-0000-0000-0000-000000000001
-- =============================================================================
