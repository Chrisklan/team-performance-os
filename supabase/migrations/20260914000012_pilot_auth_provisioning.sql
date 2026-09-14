-- =============================================================================
-- 20260914000012_pilot_auth_provisioning.sql — Pilot Magic-Link Provisioning
--
-- Problem (live verifiziert):
--   public.handle_new_user() legt bei jedem neuen auth.users-Eintrag ein neues
--   Player-Profil aus raw_user_meta_data.player_id an. Beim Magic-Link-Login
--   ist player_id NULL -> Verstoss gegen profiles_player_link_ck ->
--   "Database error saving new user". Pilot-Profile existieren bereits als
--   Seed-Zeilen (z.B. max.kruger@tpos.local) ohne auth.users-Gegenstueck.
--
-- Entscheidung:
--   * Pilot-User sind vorab geseedete Profile, identifiziert ueber die E-Mail.
--   * Beim ersten Magic-Link-Login wird die neue auth.users.id an das Seed-
--     Profil derselben (normalisierten) E-Mail gebunden:
--       public.profiles.id        := auth.users.id   (kanonisch)
--       app.persons.auth_user_id  := auth.users.id   (alt: Seed-Profil-ID)
--       app.persons.id / app.role_assignments.person_id bleiben stabil.
--   * player_id, role, full_name, email des Profils bleiben unveraendert.
--   * Unbekannte E-Mails werden abgewiesen (kein unzugeordneter User).
--   * Keine Abhaengigkeit von raw_user_meta_data / player_id.
--
-- Identitaetsvertrag (stabile Person, live verifizierter Bug behoben):
--   Bisher lieferte app.auth_person_id() direkt den JWT-sub (= auth.users.id).
--   Nach der Bindung oben ist auth.users.id aber NICHT app.persons.id, sondern
--   steht in app.persons.auth_user_id. Deshalb wird app.auth_person_id() hier
--   ersetzt:
--       app.auth_person_id() := app.persons.id
--                               WHERE app.persons.auth_user_id = JWT sub
--   JWT sub fehlt / ist keine UUID / keine gemappte Person -> NULL.
--   Alle bestehenden app.*-RLS-Policies und RPCs, die app.auth_person_id()
--   aufrufen, loesen damit weiterhin auf die stabile app.persons.id auf.
--
-- Atomar: Die Supabase-CLI spielt jede Migrationsdatei in einer Transaktion
--         ein; Trigger-Funktion, Trigger und app.auth_person_id() werden
--         gemeinsam ersetzt.
-- Idempotent: CREATE OR REPLACE FUNCTION, CREATE OR REPLACE TRIGGER, Aufraeumen
--             doppelter Trigger nur ueber Katalog-Lookup. Kein DROP TABLE,
--             kein Reset, keine Datenmutation beim Einspielen.
-- =============================================================================


-- =============================================================================
-- 1. Trigger-Funktion
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, app, auth, pg_temp
AS $$
DECLARE
  v_email        text;
  v_match_count  integer;
  v_old_id       uuid;
  v_profile_id_attnum smallint;
  v_ref          record;
  v_set          text;
  v_where        text;
  v_sql          text;
  v_i            integer := 0;
  v_updated      integer;
BEGIN
  -- Bereits gebunden (z.B. doppelt feuernder Trigger): nichts zu tun.
  IF EXISTS (SELECT 1 FROM public.profiles pr WHERE pr.id = NEW.id) THEN
    RETURN NEW;
  END IF;

  v_email := lower(btrim(NEW.email));

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'TPOS pilot provisioning: auth user % has no e-mail; only pre-seeded pilot profiles may sign in', NEW.id
      USING ERRCODE = '42501';
  END IF;

  -- (1) Seed-Profil case-insensitiv ueber die E-Mail finden.
  SELECT count(*) INTO v_match_count
  FROM public.profiles pr
  WHERE lower(btrim(pr.email)) = v_email;

  -- (2) Unbekannte E-Mail abweisen.
  IF v_match_count = 0 THEN
    RAISE EXCEPTION 'TPOS pilot provisioning: no pre-seeded profile for e-mail %; sign-in rejected', v_email
      USING ERRCODE = '42501',
            HINT = 'Seed a public.profiles row (and app.persons) for this e-mail before inviting the user.';
  END IF;

  IF v_match_count > 1 THEN
    RAISE EXCEPTION 'TPOS pilot provisioning: % profiles share e-mail %; binding is ambiguous', v_match_count, v_email
      USING ERRCODE = '23505';
  END IF;

  SELECT pr.id INTO v_old_id
  FROM public.profiles pr
  WHERE lower(btrim(pr.email)) = v_email
  FOR UPDATE;

  -- Profil gehoert bereits zu einem anderen, existierenden auth.users-Eintrag.
  IF EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_old_id AND u.id <> NEW.id) THEN
    RAISE EXCEPTION 'TPOS pilot provisioning: profile for e-mail % is already bound to auth user %', v_email, v_old_id
      USING ERRCODE = '23505';
  END IF;

  -- (3) Primaerschluessel des Profils auf NEW.id umschreiben.
  --     Fremdschluessel auf public.profiles(id) (created_by, recorded_by,
  --     sender_profile_id, ...) sind NO ACTION. Deshalb laufen Profil-Update
  --     und Umhaengen aller referenzierenden Zeilen in EINEM Statement
  --     (datenmodifizierende CTEs); die FK-Pruefung greift erst am Statement-
  --     Ende. player_id, role, full_name und email werden nicht angefasst.
  SELECT a.attnum INTO v_profile_id_attnum
  FROM pg_attribute a
  WHERE a.attrelid = 'public.profiles'::regclass
    AND a.attname = 'id';

  v_sql := 'WITH p AS (UPDATE public.profiles SET id = $1 WHERE id = $2 RETURNING 1)';

  FOR v_ref IN
    SELECT c.conrelid::regclass::text AS tbl,
           array_agg(DISTINCT a.attname::text) AS cols
    FROM pg_constraint c
    JOIN pg_attribute a
      ON a.attrelid = c.conrelid
     AND a.attnum = c.conkey[1]
    WHERE c.contype = 'f'
      AND c.confrelid = 'public.profiles'::regclass
      AND c.conrelid <> 'public.profiles'::regclass
      AND cardinality(c.conkey) = 1
      AND c.confkey[1] = v_profile_id_attnum
    GROUP BY c.conrelid
  LOOP
    v_i := v_i + 1;

    SELECT string_agg(format('%I = CASE WHEN %I = $2 THEN $1 ELSE %I END', col, col, col), ', '),
           string_agg(format('%I = $2', col), ' OR ')
    INTO v_set, v_where
    FROM unnest(v_ref.cols) AS col;

    v_sql := v_sql || format(', r%s AS (UPDATE %s SET %s WHERE %s RETURNING 1)',
                             v_i, v_ref.tbl, v_set, v_where);
  END LOOP;

  v_sql := v_sql || ' SELECT count(*)::integer FROM p';

  EXECUTE v_sql INTO v_updated USING NEW.id, v_old_id;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'TPOS pilot provisioning: failed to rebind profile % to auth user %', v_old_id, NEW.id;
  END IF;

  -- (4) app.persons.auth_user_id von der alten Seed-Profil-ID auf NEW.id.
  --     app.persons.id und app.role_assignments.person_id bleiben stabil.
  UPDATE app.persons
  SET auth_user_id = NEW.id,
      updated_at   = now()
  WHERE auth_user_id = v_old_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated = 0 THEN
    RAISE EXCEPTION 'TPOS pilot provisioning: no app.persons row bound to seed profile % (e-mail %); run seed reconcile first', v_old_id, v_email
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  'Pilot Magic-Link provisioning: binds a new auth.users row to the pre-seeded public.profiles row with the same normalized e-mail (profiles.id := auth uid, app.persons.auth_user_id := auth uid). Rejects unknown e-mails. No raw_user_meta_data dependency.';

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM anon, authenticated;


-- =============================================================================
-- 2. Trigger auf auth.users
--    Eventuelle weitere Trigger, die dieselbe Funktion unter anderem Namen
--    aufrufen, werden entfernt, damit genau ein AFTER INSERT Trigger bleibt.
-- =============================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.tgname
    FROM pg_trigger t
    WHERE t.tgrelid = 'auth.users'::regclass
      AND NOT t.tgisinternal
      AND t.tgfoid = 'public.handle_new_user()'::regprocedure
      AND t.tgname <> 'on_auth_user_created'
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON auth.users', r.tgname);
  END LOOP;
END $$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- =============================================================================
-- 3. Identitaetsvertrag: app.auth_person_id() -> stabile app.persons.id
--    JWT sub (auth.users.id) wird ueber app.persons.auth_user_id auf die
--    stabile Person-ID abgebildet. Kein direktes Durchreichen des sub mehr.
-- =============================================================================

CREATE OR REPLACE FUNCTION app.auth_person_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sub       text;
  v_auth_uid  uuid;
  v_person_id uuid;
BEGIN
  -- JWT sub aus den PostgREST-Claims (aktuelles Format), Fallback auf das
  -- aeltere Einzel-Claim-Setting.
  v_sub := nullif(
             btrim(
               coalesce(
                 nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
                 nullif(pg_catalog.current_setting('request.jwt.claim.sub', true), '')
               )
             ),
             ''
           );

  IF v_sub IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_auth_uid := v_sub::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      RETURN NULL;
  END;

  SELECT pe.id INTO v_person_id
  FROM app.persons pe
  WHERE pe.auth_user_id = v_auth_uid;

  RETURN v_person_id;  -- NULL, wenn keine Person gemappt ist
END;
$$;

COMMENT ON FUNCTION app.auth_person_id() IS
  'Returns the stable app.persons.id of the authenticated user by looking up app.persons.auth_user_id = JWT sub (auth.uid()). Returns NULL if there is no JWT subject or no mapped person. Person IDs stay stable across pilot auth binding.';


-- =============================================================================
-- 4. Verifikation nach dem Einspielen (nur lesend, manuell ausfuehren)
-- =============================================================================
--
-- V1  Genau ein Trigger auf auth.users ruft die neue Funktion auf:
--       SELECT t.tgname, t.tgfoid::regprocedure AS fn, t.tgenabled
--       FROM pg_trigger t
--       WHERE t.tgrelid = 'auth.users'::regclass
--         AND NOT t.tgisinternal;
--     Erwartet: on_auth_user_created | handle_new_user() | O
--
-- V2  Funktion haengt nicht mehr an raw_user_meta_data / player_id-Metadaten:
--       SELECT position('raw_user_meta_data' IN pg_get_functiondef('public.handle_new_user()'::regprocedure)) = 0
--              AS no_metadata_dependency;
--     Erwartet: true
--
-- V3  Seed-Profil vor dem ersten Login (noch ungebunden):
--       SELECT pr.id, pr.email, pr.role, pr.full_name, pr.player_id,
--              (SELECT u.id FROM auth.users u WHERE lower(u.email) = lower(pr.email)) AS auth_user_id
--       FROM public.profiles pr
--       WHERE lower(btrim(pr.email)) = 'max.kruger@tpos.local';
--     Erwartet: 1 Zeile, auth_user_id NULL, player_id NOT NULL
--
-- V4  Nach dem ersten Magic-Link-Login: Profil-ID = auth.users.id, Daten erhalten:
--       SELECT u.id AS auth_user_id, pr.id AS profile_id, pr.email, pr.role,
--              pr.full_name, pr.player_id
--       FROM auth.users u
--       JOIN public.profiles pr ON pr.id = u.id
--       WHERE lower(u.email) = 'max.kruger@tpos.local';
--     Erwartet: 1 Zeile, profile_id = auth_user_id, role/full_name/player_id wie in V3
--
-- V5  app.persons zeigt auf die neue auth-ID, Person-ID stabil:
--       SELECT pe.id AS person_id, pe.auth_user_id, pr.id AS profile_id, pr.email
--       FROM app.persons pe
--       JOIN public.profiles pr ON pr.id = pe.auth_user_id
--       WHERE lower(btrim(pr.email)) = 'max.kruger@tpos.local';
--     Erwartet: 1 Zeile, person_id = alte Seed-Profil-ID aus V3, auth_user_id = auth.users.id
--
-- V6  Rollen-Zuordnungen haengen weiter an der stabilen Person:
--       SELECT ra.person_id, ra.role, ra.valid_from, ra.valid_to
--       FROM app.role_assignments ra
--       JOIN app.persons pe ON pe.id = ra.person_id
--       JOIN auth.users u ON u.id = pe.auth_user_id
--       WHERE lower(u.email) = 'max.kruger@tpos.local';
--     Erwartet: unveraenderte Rolle(n) wie vor dem Login
--
-- V7  Keine verwaisten Bindungen app.persons -> public.profiles:
--       SELECT count(*) AS orphaned_persons
--       FROM app.persons pe
--       LEFT JOIN public.profiles pr ON pr.id = pe.auth_user_id
--       WHERE pe.auth_user_id IS NOT NULL
--         AND pr.id IS NULL;
--     Erwartet: 0
--
-- V8  Keine doppelten E-Mails in public.profiles (sonst Login abgewiesen):
--       SELECT lower(btrim(email)) AS email, count(*)
--       FROM public.profiles
--       WHERE email IS NOT NULL
--       GROUP BY 1
--       HAVING count(*) > 1;
--     Erwartet: 0 Zeilen
--
-- V9  app.auth_person_id() loest fuer max.kruger@tpos.local auf die stabile
--     app.persons.id auf, wenn request.jwt.claims.sub = auth.users.id ist
--     (READ ONLY Transaktion, set_config nur transaktionslokal, ROLLBACK):
--       BEGIN READ ONLY;
--       SELECT set_config('request.jwt.claims',
--                         json_build_object('sub', u.id::text, 'role', 'authenticated')::text,
--                         true)
--       FROM auth.users u
--       WHERE lower(u.email) = 'max.kruger@tpos.local';
--       SELECT u.id                   AS auth_user_id,
--              pe.id                  AS expected_person_id,
--              app.auth_person_id()   AS resolved_person_id,
--              app.auth_person_id() = pe.id        AS resolves_to_person_id,
--              app.auth_person_id() IS DISTINCT FROM u.id AS not_raw_jwt_sub
--       FROM auth.users u
--       JOIN app.persons pe ON pe.auth_user_id = u.id
--       WHERE lower(u.email) = 'max.kruger@tpos.local';
--       ROLLBACK;
--     Erwartet: 1 Zeile, resolves_to_person_id = true, not_raw_jwt_sub = true
--
-- V10 Ohne JWT-sub bzw. mit ungemapptem sub liefert die Funktion NULL:
--       BEGIN READ ONLY;
--       SELECT set_config('request.jwt.claims', '', true);
--       SELECT app.auth_person_id() IS NULL AS null_without_sub;
--       SELECT set_config('request.jwt.claims',
--                         json_build_object('sub', '00000000-0000-0000-0000-000000000000')::text,
--                         true);
--       SELECT app.auth_person_id() IS NULL AS null_for_unmapped_sub;
--       ROLLBACK;
--     Erwartet: true, true
-- =============================================================================
