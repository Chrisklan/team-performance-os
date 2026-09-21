-- Migration 20260921000030_body_map_history.sql (AP-45)
-- Quelle: backend/19_body_map_history.sql (identisch). Tests: backend/19_body_map_history.pgtap.sql.
-- Legt nur vier Funktionen an, schreibt keine Daten, veraendert keine bestehende Zeile.

-- =============================================================================
-- 19_body_map_history.sql — Verlauf je Region und Physio Sicht (AP-45)
--
-- Modul-Body-Map Abschnitte 7.2 und 7.3. Zwei Lesewege auf daily_checkins.body_map,
-- die es bisher nicht gab, und je eine Tuer in public (PostgREST exponiert nur
-- public, Muster wie 18_body_map_figure_api.sql).
--
--   app.rpc_my_body_map_history(p_days)             Die Spielerin liest ihre eigenen
--                                                   Angaben, Tag fuer Tag (7.2).
--   app.rpc_body_map_region_reports(p_person_id,    Medizinrollen des eigenen Teams
--                                   p_days)         lesen die Meldungen je Region
--                                                   einer Spielerin, gezaehlt (7.3).
--
-- Beide sind SECURITY DEFINER, weil authenticated die Spalte body_map nicht lesen
-- darf (09_rpcs.sql Abschnitt 6, Spaltenrechte). Die Tueren sind SECURITY INVOKER.
--
-- Eigener Verlauf:
-- * Nur Rolle player. Die Person kommt aus app.auth_person_id(), es gibt keinen
--   Parameter dafuer. Wer fremde Daten will, hat keinen Hebel.
-- * Antwort je Check-in Tag: Datum, answered (body_map IS NOT NULL) und die Regionen
--   mit region und pain. Kein Tippunkt, keine Zeichnung, keine Art: fuer eine Kurve
--   wird nichts davon gebraucht, und was nicht gesendet wird, kann nicht liegen bleiben.
-- * Keine Zeile im access_log. Die Uebersicht "Wer hat meine Daten gesehen" zeigt
--   Zugriffe anderer. Wuerde jedes Oeffnen des eigenen Verlaufs dort stehen, ginge
--   der eine Eintrag unter, auf den es ankommt.
--
-- Physio Sicht:
-- * Nur physio und doctor des eigenen Teams (ADR-009). Trainer, Athletiktrainer, Admin
--   und die Spielerin selbst bekommen FORBIDDEN. Die Spielerin liest ihren Verlauf
--   ueber die andere Tuer.
-- * Die Person muss im eigenen Team aktiv sein und eine gueltige Rolle player haben.
--   Fremdes Team, unbekannte Id, NULL, deaktivierte und geshredderte Person geben
--   dieselbe Antwort, es gibt kein Orakel fuer Ids. (Gegenlesung 2026-09-21: is_active
--   kam dazu, der Shred beendet die Rolle nicht.)
-- * Jedes Oeffnen schreibt VOR der Antwort eine Zeile in app.access_log: subject die
--   Spielerin, actor die Medizinperson, resource daily_checkins.body_map, scope_date
--   Beginn des Fensters. Genau diese Tabelle liest app.rpc_get_my_access_log, also die
--   Zugriffsuebersicht der Spielerin. (Im Modul steht dafuer "audit_log". Das audit_log
--   ist der Zeilentrigger der Datenaenderungen und wuerde eine Leseaktion nicht zeigen.)
-- * Nur Zaehlen: je Region reports (Tage mit Meldung), highest (hoechster gemeldeter
--   Wert), lastDate. Dazu answeredDays (Tage, an denen die Body Map beantwortet
--   wurde). Kein Mittelwert, keine Rangfolge (Reihenfolge ist die des Katalogs), kein
--   Vergleich links gegen rechts, nichts abhaengig von der Figur, kein Rechnen mit dem
--   Tippunkt (der wird hier gar nicht gelesen). Modul-Body-Map Abschnitt 8.
-- * legacy = Region ohne Flaeche auf der Silhouette (Altschluessel). Beide Schluessel
--   stehen nebeneinander, die alten Zeilen bleiben unangetastet (Entscheidung 5).
--
-- Fenster: p_days von 1 bis 90, Vorgabe 28, gerechnet in der Zeitzone des Teams.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 16_body_region.sql. Idempotent.
-- Tests: backend/19_body_map_history.pgtap.sql.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_my_body_map_history(integer);
DROP FUNCTION IF EXISTS public.rpc_body_map_region_reports(uuid, integer);

-- =============================================================================
-- 1. Eigener Verlauf
-- =============================================================================

CREATE OR REPLACE FUNCTION app.rpc_my_body_map_history(p_days integer DEFAULT 28)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_team_id   uuid;
  v_today     date;
  v_from      date;
BEGIN
  -- Rolle pruefen (erste Anweisung)
  IF NOT app.auth_has_role('player') THEN
    PERFORM app.log_denial('daily_checkins.body_map');
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.body_map' USING errcode = '42501';
  END IF;

  IF p_days IS NULL OR p_days < 1 OR p_days > 90 THEN
    RAISE EXCEPTION 'INVALID: body_map_history.days' USING errcode = '22023';
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id   := app.auth_team_id();

  SELECT (now() AT TIME ZONE t.timezone)::date INTO v_today
    FROM app.teams t WHERE t.id = v_team_id;
  v_from := v_today - (p_days - 1);

  RETURN jsonb_build_object(
    'from', v_from,
    'to',   v_today,
    'days', p_days,
    'checkins', COALESCE((
      SELECT jsonb_agg(
               jsonb_build_object(
                 'date', dc.date,
                 'answered', dc.body_map IS NOT NULL,
                 'regions', COALESCE((
                   SELECT jsonb_agg(
                            jsonb_build_object('region', e ->> 'region', 'pain', e -> 'pain')
                            ORDER BY e ->> 'region')
                     FROM jsonb_array_elements(
                            CASE WHEN jsonb_typeof(dc.body_map) = 'array'
                                 THEN dc.body_map ELSE '[]'::jsonb END) e
                 ), '[]'::jsonb)
               )
               ORDER BY dc.date)
        FROM app.daily_checkins dc
       WHERE dc.person_id = v_person_id
         AND dc.team_id   = v_team_id
         AND dc.date     >= v_from
    ), '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_my_body_map_history(integer) IS
  'AP-45: eigener Verlauf der Body Map, Tag fuer Tag (Modul-Body-Map 7.2). Nur Rolle player, Person aus den Claims, nur region und pain, kein Tippunkt. Schreibt nichts, auch nicht in den access_log.';

-- =============================================================================
-- 2. Physio Sicht
-- =============================================================================

CREATE OR REPLACE FUNCTION app.rpc_body_map_region_reports(p_person_id uuid, p_days integer DEFAULT 28)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id  uuid;
  v_actor_id uuid;
  v_today    date;
  v_from     date;
  v_answered integer;
  v_regions  jsonb;
BEGIN
  -- Rolle pruefen (erste Anweisung). Nur Medizin: Trainer, Admin und die Spielerin
  -- selbst fallen hier heraus.
  IF NOT app.auth_is_medical() THEN
    PERFORM app.log_denial('daily_checkins.body_map');
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.body_map' USING errcode = '42501';
  END IF;

  IF p_days IS NULL OR p_days < 1 OR p_days > 90 THEN
    RAISE EXCEPTION 'INVALID: body_map_history.days' USING errcode = '22023';
  END IF;

  v_team_id  := app.auth_team_id();
  v_actor_id := app.auth_person_id();

  -- Die Person muss im eigenen Team aktive Spielerin sein. Fremdes Team, unbekannte
  -- Id, NULL, deaktivierte und geshredderte Person antworten gleich. is_active steht
  -- hier, weil rpc_shred_person die Rolle nicht beendet: ohne diese Bedingung oeffnete
  -- die Tuer eine Sicht auf eine Person, die es nicht mehr gibt, und schriebe danach
  -- eine Zeile in den access_log, die der Shred fuer diese Person gerade geloescht hat.
  IF p_person_id IS NULL OR NOT EXISTS (
    SELECT 1
      FROM app.persons pe
      JOIN app.role_assignments ra
        ON ra.person_id = pe.id AND ra.team_id = pe.team_id
     WHERE pe.id        = p_person_id
       AND pe.team_id   = v_team_id
       AND pe.is_active
       AND ra.role      = 'player'
       AND ra.valid_from <= now()
       AND (ra.valid_to IS NULL OR ra.valid_to > now())
  ) THEN
    PERFORM app.log_denial('daily_checkins.body_map');
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.body_map' USING errcode = '42501';
  END IF;

  SELECT (now() AT TIME ZONE t.timezone)::date INTO v_today
    FROM app.teams t WHERE t.id = v_team_id;
  v_from := v_today - (p_days - 1);

  -- Protokoll zuerst: ohne Eintrag keine Antwort.
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
  VALUES (v_team_id, p_person_id, v_actor_id, app.denial_actor_role(),
          'daily_checkins.body_map', 'read', v_from);

  SELECT count(*)::integer INTO v_answered
    FROM app.daily_checkins dc
   WHERE dc.person_id = p_person_id
     AND dc.team_id   = v_team_id
     AND dc.date     >= v_from
     AND dc.body_map IS NOT NULL;

  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'region',   r.region,
             'label',    COALESCE(br.label_de, r.region),
             'reports',  r.reports,
             'highest',  r.highest,
             'lastDate', r.last_date,
             'legacy',   COALESCE(NOT br.is_selectable, true))
           ORDER BY br.sort NULLS LAST, r.region), '[]'::jsonb)
    INTO v_regions
    FROM (
      SELECT e ->> 'region'              AS region,
             count(DISTINCT dc.date)     AS reports,
             max((e ->> 'pain')::numeric)::integer AS highest,
             max(dc.date)                AS last_date
        FROM app.daily_checkins dc
       CROSS JOIN LATERAL jsonb_array_elements(
              CASE WHEN jsonb_typeof(dc.body_map) = 'array'
                   THEN dc.body_map ELSE '[]'::jsonb END) e
       WHERE dc.person_id = p_person_id
         AND dc.team_id   = v_team_id
         AND dc.date     >= v_from
       GROUP BY e ->> 'region'
    ) r
    LEFT JOIN app.body_region br ON br.key = r.region;

  RETURN jsonb_build_object(
    'personId',     p_person_id,
    'from',         v_from,
    'to',           v_today,
    'days',         p_days,
    'answeredDays', v_answered,
    'regions',      v_regions
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_body_map_region_reports(uuid, integer) IS
  'AP-45: Meldungen je Region einer Spielerin, gezaehlt (Modul-Body-Map 7.3). Nur physio und doctor des eigenen Teams (ADR-009). Schreibt bei jedem Oeffnen eine Zeile in app.access_log (Zugriffsuebersicht der Spielerin). Nur Zaehlen, kein Mittelwert, keine Rangfolge, kein Tippunkt.';

REVOKE EXECUTE ON FUNCTION app.rpc_my_body_map_history(integer)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_body_map_region_reports(uuid, integer)    FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_my_body_map_history(integer)              FROM anon;
REVOKE EXECUTE ON FUNCTION app.rpc_body_map_region_reports(uuid, integer)    FROM anon;
GRANT  EXECUTE ON FUNCTION app.rpc_my_body_map_history(integer)              TO authenticated;
GRANT  EXECUTE ON FUNCTION app.rpc_body_map_region_reports(uuid, integer)    TO authenticated;

-- =============================================================================
-- 3. Tueren in public
-- =============================================================================

CREATE FUNCTION public.rpc_my_body_map_history(p_days integer DEFAULT 28)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT app.rpc_my_body_map_history(p_days);
$$;

CREATE FUNCTION public.rpc_body_map_region_reports(p_person_id uuid, p_days integer DEFAULT 28)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT app.rpc_body_map_region_reports(p_person_id, p_days);
$$;

COMMENT ON FUNCTION public.rpc_my_body_map_history(integer) IS
  'AP-45: API-Tuer fuer app.rpc_my_body_map_history(integer). Invoker, nur authenticated.';
COMMENT ON FUNCTION public.rpc_body_map_region_reports(uuid, integer) IS
  'AP-45: API-Tuer fuer app.rpc_body_map_region_reports(uuid, integer). Invoker, nur authenticated.';

REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_history(integer)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_body_map_region_reports(uuid, integer)    FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_history(integer)              FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_body_map_region_reports(uuid, integer)    FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_my_body_map_history(integer)              TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.rpc_body_map_region_reports(uuid, integer)    TO authenticated, service_role;
