-- Migration 20260921000026_squad_figure.sql (AP-43, Modul-Body-Map Abschnitt 3.2b)
-- Quelle: backend/17_squad_figure.sql (identisch). Tests: backend/17_squad_figure.pgtap.sql.
-- Ergaenzt app.teams um squad_type und app.persons um body_map_figure, beide mit
-- Vorgabewert. Kein Geschlechtsfeld an der Person. Aendert keine bestehende
-- Zeile inhaltlich, die Vorgaben fuellen die neuen Spalten.

-- =============================================================================
-- 17_squad_figure.sql — Kadervorgabe und Darstellungspraeferenz (AP-43)
--
-- Modul-Body-Map Abschnitt 3.2b. Es gibt drei Silhouetten (weiblich, maennlich,
-- neutral), und die Frage ist, woher die App weiss, welche sie zeigt.
--
-- Entscheidung Chris und Claude vom 2026-09-20: KEIN Geschlechtsfeld an der
-- Person. Zwei Ebenen, beide ohne personenbezogene Geschlechtsangabe:
--
--   1. app.teams.squad_type        Eigenschaft der MANNSCHAFT, nicht der Person.
--                                  frauen, maenner, gemischt, unbestimmt. Steht
--                                  ohnehin oeffentlich auf der Vereinsseite und
--                                  wird beim Anlegen des Teams gesetzt.
--   2. app.persons.body_map_figure Darstellungspraeferenz. aus_dem_team (Vorgabe),
--                                  weiblich, maennlich, neutral. Eine Zeile in
--                                  den eigenen Einstellungen, keine Frage im
--                                  Onboarding, keine Begruendung noetig.
--
-- Warum nicht einfach ein Geschlechtsfeld: weil wir dann eine Angabe ueber einen
-- Menschen speichern wuerden, um eine Zeichnung auszuwaehlen. body_map_figure
-- traegt ausserhalb der Grafik keine Bedeutung und laesst sich fuer nichts
-- anderes hernehmen. Ein Geschlechtsfeld waere das nicht.
--
-- Warum nicht nur die Praeferenz: dann stuende jeder Spieler am Anfang vor der
-- neutralen Figur, die meisten wuerden nie umstellen, und die Entscheidung fuer
-- drei Figuren waere still wieder eine fuer eine.
--
-- Keine Ableitung aus der Figur (Modul Abschnitt 8): keine geschlechtsabhaengigen
-- Schwellwerte, keine eigene Auswertung, keine eigene Statistik. Sonst wird aus
-- einer Grafik eine medizinische Aussage.
--
-- Sichtbarkeit: body_map_figure steht bewusst NICHT in der Spaltenliste von
-- GRANT SELECT ON app.persons (08_reconciling.sql Abschnitt 5), genau wie
-- birth_date. Das Kader liest die Praeferenz seiner Mitglieder nicht. Wer sie
-- braucht, ist die Person selbst, und die liest sie ueber
-- app.rpc_my_body_map_figure(). Ohne diesen Weg waere die Spalte entweder tot
-- oder fuer das ganze Team offen.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql. Idempotent.
-- Tests: backend/17_squad_figure.pgtap.sql.
-- =============================================================================

-- =============================================================================
-- 1. Typen
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                  WHERE n.nspname = 'app' AND t.typname = 'app_squad_type') THEN
    CREATE TYPE app.app_squad_type AS ENUM ('frauen', 'maenner', 'gemischt', 'unbestimmt');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                  WHERE n.nspname = 'app' AND t.typname = 'app_body_map_figure') THEN
    CREATE TYPE app.app_body_map_figure AS ENUM ('aus_dem_team', 'weiblich', 'maennlich', 'neutral');
  END IF;
END
$$;

-- =============================================================================
-- 2. Spalten
-- =============================================================================

ALTER TABLE app.teams
  ADD COLUMN IF NOT EXISTS squad_type app.app_squad_type NOT NULL DEFAULT 'unbestimmt';

ALTER TABLE app.persons
  ADD COLUMN IF NOT EXISTS body_map_figure app.app_body_map_figure NOT NULL DEFAULT 'aus_dem_team';

COMMENT ON COLUMN app.teams.squad_type IS
  'Kadervorgabe fuer die Body Map Figur. Eigenschaft der Mannschaft, keine '
  'Angabe ueber eine Person. gemischt und unbestimmt fuehren auf die neutrale Figur.';
COMMENT ON COLUMN app.persons.body_map_figure IS
  'Darstellungspraeferenz fuer die Body Map Silhouette, kein Geschlechtsfeld. '
  'aus_dem_team folgt app.teams.squad_type. Traegt ausserhalb der Grafik keine '
  'Bedeutung, keine geschlechtsabhaengige Auswertung (Modul-Body-Map 3.2b und 8). '
  'Nicht in der Spaltenliste von GRANT SELECT ON app.persons, siehe 17_squad_figure.sql.';

-- =============================================================================
-- 3. Aufloesung
--
-- Eine Stelle, an der aus Vorgabe und Praeferenz die Figur wird. Steht hier und
-- nicht im Client, damit Player und Web nicht zwei Auslegungen bekommen.
-- =============================================================================

CREATE OR REPLACE FUNCTION app.body_map_figure_for(
  p_preference app.app_body_map_figure,
  p_squad_type app.app_squad_type
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_preference
           WHEN 'weiblich'  THEN 'weiblich'
           WHEN 'maennlich' THEN 'maennlich'
           WHEN 'neutral'   THEN 'neutral'
           ELSE CASE p_squad_type
                  WHEN 'frauen'  THEN 'weiblich'
                  WHEN 'maenner' THEN 'maennlich'
                  ELSE 'neutral'
                END
         END;
$$;

COMMENT ON FUNCTION app.body_map_figure_for(app.app_body_map_figure, app.app_squad_type) IS
  'AP-43: Praeferenz schlaegt Kadervorgabe, gemischt und unbestimmt fuehren auf neutral.';

-- =============================================================================
-- 4. Leseweg und Schreibweg fuer die eigene Praeferenz
--
-- Beide SECURITY DEFINER und beide nur fuer die eigene Person. Die RLS Policy
-- persons_update_admin laesst sonst nur einen admin schreiben, und die
-- Spaltenliste im SELECT Grant laesst niemanden lesen. Ohne diese zwei
-- Funktionen koennte der Spieler seine eigene Praeferenz also weder sehen noch
-- setzen. Der Umweg ueber eine Funktion ist der Preis dafuer, dass niemand
-- sonst sie sieht.
-- =============================================================================

CREATE OR REPLACE FUNCTION app.rpc_my_body_map_figure()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_row       record;
BEGIN
  v_person_id := app.auth_person_id();
  IF v_person_id IS NULL THEN
    PERFORM app.log_denial('persons.body_map_figure');
    RAISE EXCEPTION 'FORBIDDEN: persons.body_map_figure' USING errcode = '42501';
  END IF;

  SELECT p.body_map_figure, t.squad_type
    INTO v_row
    FROM app.persons p
    JOIN app.teams t ON t.id = p.team_id
   WHERE p.id = v_person_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: persons.body_map_figure' USING errcode = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'preference', v_row.body_map_figure::text,
    'squadType',  v_row.squad_type::text,
    'figure',     app.body_map_figure_for(v_row.body_map_figure, v_row.squad_type)
  );
END;
$$;

CREATE OR REPLACE FUNCTION app.rpc_set_my_body_map_figure(p_preference text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_value     app.app_body_map_figure;
BEGIN
  v_person_id := app.auth_person_id();
  IF v_person_id IS NULL THEN
    PERFORM app.log_denial('persons.body_map_figure');
    RAISE EXCEPTION 'FORBIDDEN: persons.body_map_figure' USING errcode = '42501';
  END IF;

  BEGIN
    v_value := p_preference::app.app_body_map_figure;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'INVALID: persons.body_map_figure' USING errcode = '22023';
  END;

  -- Die Bedingung am Ende haelt das audit_log ruhig: app.persons traegt einen
  -- Audit Trigger, der ganze Zeilen kopiert. Ein Setzen auf denselben Wert
  -- wuerde sonst eine weitere Vollkopie der Personenzeile erzeugen.
  UPDATE app.persons
     SET body_map_figure = v_value,
         updated_at      = now()
   WHERE id = v_person_id
     AND body_map_figure IS DISTINCT FROM v_value;

  RETURN app.rpc_my_body_map_figure();
END;
$$;

COMMENT ON FUNCTION app.rpc_my_body_map_figure() IS
  'AP-43: liest die eigene Darstellungspraeferenz und die daraus aufgeloeste Figur. '
  'Nur die eigene Person, person_id kommt aus app.auth_person_id().';
COMMENT ON FUNCTION app.rpc_set_my_body_map_figure(text) IS
  'AP-43: setzt die eigene Darstellungspraeferenz (aus_dem_team, weiblich, maennlich, neutral). '
  'Nur die eigene Person. Kein Geschlechtsfeld, reine Darstellung.';

REVOKE EXECUTE ON FUNCTION app.rpc_my_body_map_figure()          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_set_my_body_map_figure(text)  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.body_map_figure_for(app.app_body_map_figure, app.app_squad_type) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_my_body_map_figure()          FROM anon;
REVOKE EXECUTE ON FUNCTION app.rpc_set_my_body_map_figure(text)  FROM anon;
GRANT  EXECUTE ON FUNCTION app.rpc_my_body_map_figure()          TO authenticated;
GRANT  EXECUTE ON FUNCTION app.rpc_set_my_body_map_figure(text)  TO authenticated;

-- =============================================================================
-- 5. Bestandswahrung der Spaltenrechte auf app.persons
--
-- ADD COLUMN vergibt kein Spaltenrecht, die neue Spalte ist fuer authenticated
-- also von sich aus nicht lesbar. Der Block hier schreibt das fest, statt sich
-- darauf zu verlassen: er setzt die Spaltenliste aus 08_reconciling.sql erneut
-- und laesst body_map_figure und birth_date bewusst aus.
-- =============================================================================

REVOKE SELECT ON app.persons FROM authenticated;
GRANT SELECT (id, team_id, auth_user_id, display_name, person_position, shirt_number,
              is_active, created_at, updated_at)
  ON app.persons TO authenticated;
-- birth_date und body_map_figure sind NICHT in der Liste.
