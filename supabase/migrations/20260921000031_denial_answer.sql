-- Migration 20260921000031_denial_answer.sql (AP-45d)
-- Quelle: backend/20_denial_answer.sql (identisch). Tests: backend/20_denial_answer.pgtap.sql.
-- Ersetzt zwei Helfer, fuenf app Funktionen und fuenf Tueren. Schreibt keine Daten,
-- veraendert keine bestehende Zeile. app.log_denial bleibt unveraendert.

-- =============================================================================
-- 20_denial_answer.sql — Die Ablehnung ueberlebt den Commit (AP-45d, Option A)
--
-- Befund F1 der Gegenlesung AP-45 (Audit 2026-09-21, Abschnitt 7): app.log_denial
-- ist ein einfacher INSERT und wird von dem RAISE, das unmittelbar folgt, wieder
-- zurueckgerollt. Gemessen im Autocommit: eine Ablehnung, app.access_denials bleibt
-- 0, log_denial allein schreibt 1. Die Compliance Metrik ist damit leer und das
-- DONE_WHEN des Moduls Rollen Medizin Gate ("Deny ueberlebt das raise") nicht erfuellt.
--
-- Chris hat am 2026-09-21 Option A gewaehlt (Audit Abschnitt 7, Vertrag in Abschnitt 9):
-- die Ablehnung wird Antwort statt Ausnahme. Damit committet die Transaktion und die
-- Zeile bleibt stehen. Muster D des Moduls nennt dafuer dblink (Option B); dblink liegt
-- in public und ist laut AP-39 fuer anon ausfuehrbar, braucht eine Login Rolle mit
-- Passwort und ist im gehosteten Supabase ungeklaert. Option A kommt ohne zweite
-- Verbindung und ohne neue Angriffsflaeche aus.
--
-- Vertrag der Antwort (Audit Abschnitt 9.2), ueber PostgREST:
--   HTTP 403, Body {"code":"42501","message":"FORBIDDEN: <resource>","details":null,"hint":null}
-- supabase-js prueft response.ok, 403 ist nicht ok, der Body wird zu error. Im Client
-- kommt damit exakt dasselbe an wie heute bei einem RAISE mit errcode 42501:
-- error.code "42501", error.message "FORBIDDEN: ...", status 403, data null.
-- Kein Client Umbau. Das ist ein eigenes Paket und steht nicht an.
--
-- Was Option A kostet: direkter SQL Zugriff sieht bei diesen fuenf Funktionen keine
-- Ausnahme mehr, sondern bekommt das Objekt als Wert. Nur PostgREST macht daraus einen
-- Fehler. Deshalb bleiben die acht app Funktionen OHNE Tuer bei ihrem RAISE
-- (rpc_list_team_members, rpc_check_ins_medical, rpc_readiness_full, rpc_release_deviation,
-- rpc_get_clearance, rpc_set_clearance, rpc_propose_clearance, rpc_shred_person).
-- Ihre Ablehnung wird weiter zurueckgerollt. Sobald eine von ihnen eine Tuer bekommt
-- (Befund F2, Bridge Punkt 39), muss sie nach demselben Vertrag umgebaut werden.
--
-- Diese Datei ersetzt ab AP-45d die Fassungen aus 11_checkin_submit.sql,
-- 13_checkin_api.sql, 17_squad_figure.sql, 18_body_map_figure_api.sql und
-- 19_body_map_history.sql. Die Rumpfe sind aus diesen Dateien uebernommen, geaendert
-- ist nur der Ablehnungszweig (zwei Zeilen werden eine), bei rpc_submit_checkin
-- zusaetzlich der Rueckgabetyp.
--
-- Zwei Aenderungen, die zum Vertrag gehoeren und nicht nach Geschmack aussehen sollen:
--
--   1. app.rpc_submit_checkin und public.rpc_submit_checkin geben jsonb statt uuid
--      zurueck. Ein Fehlerobjekt passt nicht in einen uuid. Bei Erfolg steht
--      to_jsonb(v_id) drin, das ist derselbe JSON String, den PostgREST aus einem
--      uuid Skalar ohnehin macht. src/lib/sync.ts liest von dieser Tuer nur
--      { error, status }, scripts/e2e-gate.mjs prueft typeof data === "string" und
--      row.id === data. Beides bleibt wahr.
--
--   2. app.rpc_my_body_map_figure und public.rpc_my_body_map_figure werden VOLATILE.
--      Sie waren STABLE. PostgREST faehrt immutable und stable Funktionen in einer
--      READ ONLY Transaktion, ein INSERT in access_denials scheitert dort mit 25006.
--      Eine Tuer, die eine Ablehnung schreibt, kann nicht stable sein. (Nebenbefund:
--      schon heute antwortet diese Tuer bei einer Ablehnung ueber PostgREST mit 25006
--      statt 42501. Dem Player faellt das nicht auf, figure.ts behandelt jeden Fehler
--      gleich als unavailable.)
--
-- Zwei FORBIDDEN in app.rpc_submit_checkin bleiben RAISE: daily_checkins.date und
-- daily_checkins.team. Sie rufen kein log_denial, es gibt dort nichts zu retten.
-- Ueber PostgREST sieht der Client bei beiden Wegen dasselbe.
--
-- Voraussetzung: 09_rpcs.sql (log_denial, denial_actor_role), 11, 13, 16, 17, 18, 19.
-- Idempotent.
-- =============================================================================

-- =============================================================================
-- 1. Bausteine
-- =============================================================================

-- Schreibt die Ablehnung und gibt das Fehlerobjekt zurueck. Kein RAISE, also rollt
-- nichts zurueck. log_denial steigt ohne bestaetigtes Team aus (anon, geshreddet,
-- Rolle entzogen), das Objekt kommt trotzdem und die Tuer bleibt zu.
CREATE OR REPLACE FUNCTION app.deny(p_resource text, p_message text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
BEGIN
  PERFORM app.log_denial(p_resource);
  RETURN jsonb_build_object(
    'code',    '42501',
    'message', p_message,
    'details', NULL,
    'hint',    NULL
  );
END;
$$;

COMMENT ON FUNCTION app.deny(text, text) IS
  'AP-45d: schreibt die Ablehnung in app.access_denials und gibt das Fehlerobjekt zurueck, '
  'das die Tuer in public mit HTTP 403 beantwortet. Ersetzt das Paar log_denial plus RAISE, '
  'das sich selbst zurueckrollte (Befund F1).';

REVOKE EXECUTE ON FUNCTION app.deny(text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.deny(text, text) TO service_role;

-- Erkennt das Fehlerobjekt. Die Erfolgsantworten der fuenf Tueren tragen nie einen
-- Schluessel code: sie sind entweder ein Objekt mit from/to/days/checkins, regions,
-- figure/source, oder ein JSON String (die id des Check-ins).
CREATE OR REPLACE FUNCTION app.is_denial(p_result jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT p_result IS NOT NULL
     AND jsonb_typeof(p_result) = 'object'
     AND p_result->>'code' IS NOT DISTINCT FROM '42501';
$$;

COMMENT ON FUNCTION app.is_denial(jsonb) IS
  'AP-45d: wahr, wenn das Ergebnis einer app Funktion das Fehlerobjekt aus app.deny ist. '
  'Fuer authenticated ausfuehrbar, weil die Tueren in public SECURITY INVOKER sind. '
  'Liest keine Daten.';

REVOKE EXECUTE ON FUNCTION app.is_denial(jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.is_denial(jsonb) TO authenticated, service_role;

-- =============================================================================
-- 2. app Funktionen mit Tuer: Ablehnung als Antwort
-- =============================================================================

-- 2.1 app.rpc_submit_checkin: Rueckgabetyp wechselt, deshalb DROP statt REPLACE.
-- Die Tuer in public haengt daran und wird in Abschnitt 3 neu gebaut. Ein SQL Rumpf
-- als Zeichenkette erzeugt keine verzeichnete Abhaengigkeit, der DROP braucht kein CASCADE.
DROP FUNCTION IF EXISTS public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb);
DROP FUNCTION IF EXISTS app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb);

CREATE OR REPLACE FUNCTION app.rpc_submit_checkin(
  p_date                date,
  p_sleep_duration_min  numeric DEFAULT NULL,
  p_sleep_quality       integer DEFAULT NULL,
  p_recovery            integer DEFAULT NULL,
  p_energy              integer DEFAULT NULL,
  p_mental_stress       integer DEFAULT NULL,
  p_mental_mood         integer DEFAULT NULL,
  p_mental_motivation   integer DEFAULT NULL,
  p_training_readiness  integer DEFAULT NULL,
  p_body_map            jsonb   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id  uuid;
  v_team_id    uuid;
  v_pain_max   smallint;
  v_id         uuid;
  v_score      numeric;
BEGIN
  IF NOT app.auth_has_role('player') THEN
    RETURN app.deny('daily_checkins.submit', 'FORBIDDEN: daily_checkins.submit');
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id := app.auth_team_id();

  IF p_date IS NULL OR p_date > current_date OR p_date < current_date - 2 THEN
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.date' USING errcode = '42501';
  END IF;

  IF p_body_map IS NOT NULL THEN
    IF jsonb_typeof(p_body_map) <> 'array' THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map' USING errcode = '22023';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE jsonb_typeof(e) <> 'object'
         OR jsonb_typeof(e -> 'region') IS DISTINCT FROM 'string'
         OR (e ? 'pain' AND jsonb_typeof(e -> 'pain') NOT IN ('number', 'null'))
         OR (jsonb_typeof(e -> 'pain') = 'number' AND (e ->> 'pain')::numeric NOT BETWEEN 0 AND 10)
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map' USING errcode = '22023';
    END IF;

    -- Region gegen den Katalog (AP-43). Geprueft wird die Existenz und der
    -- Abschalter active_to, nicht is_selectable: die 6 Altschluessel ohne
    -- Flaeche bleiben zulaessig, solange eine App aelter als AP-44b im Umlauf
    -- ist (Entscheidung Chris 2026-09-21). Sonst verloere ein Check-In aus der
    -- Offline Warteschlange still seine Gesundheitsdaten. Abgeschaltet wird
    -- spaeter ueber active_to in backend/body_regions.json, nicht hier.
    -- active_from ist dokumentarisch und steht bewusst nicht in der Bedingung:
    -- ein Offline Nachtrag von vorgestern darf den heutigen Katalog benutzen.
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE NOT EXISTS (
        SELECT 1
        FROM app.body_region br
        WHERE br.key = e ->> 'region'
          AND (br.active_to IS NULL OR br.active_to > p_date)
      )
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.region' USING errcode = '22023';
    END IF;

    -- Tippunkt: optional, genau zwei Zahlen von 0 bis 1 (Abschnitt 3.1).
    -- Normiert auf die viewBox, deshalb 0 bis 1 und nicht die Bildschirmgroesse:
    -- sonst zeigt derselbe Wert auf einem iPhone SE woanders hin als auf einem iPad.
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE e ? 'point'
        AND jsonb_typeof(e -> 'point') <> 'null'
        AND (
             jsonb_typeof(e -> 'point') <> 'array'
          OR jsonb_array_length(e -> 'point') <> 2
          OR EXISTS (
               SELECT 1
               FROM jsonb_array_elements(e -> 'point') c
               WHERE jsonb_typeof(c) <> 'number'
                  OR (c #>> '{}')::numeric NOT BETWEEN 0 AND 1
             )
        )
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.point' USING errcode = '22023';
    END IF;

    -- Figur und Version, auf der getippt wurde: <variante>@<version>.
    -- Ohne dieses Feld ist jede Ueberarbeitung der Grafik ein stiller
    -- Datenverlust (Abschnitt 3.1, Bedingung 2). Die Variante wird gegen
    -- app.body_figure_variant geprueft, die Version nur auf Format
    -- (Entscheidung Chris 2026-09-21). Eine neue Figur ist damit eine
    -- Datenzeile, keine Aenderung an dieser Funktion.
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE e ? 'svg'
        AND jsonb_typeof(e -> 'svg') <> 'null'
        AND (
             jsonb_typeof(e -> 'svg') <> 'string'
          OR (e ->> 'svg') !~ '^[a-z_]+@[0-9]+$'
          OR NOT EXISTS (
               SELECT 1
               FROM app.body_figure_variant v
               WHERE v.key = split_part(e ->> 'svg', '@', 1)
             )
        )
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.svg' USING errcode = '22023';
    END IF;

    -- Folgt aus Bedingung 2 oben, deshalb eigene Pruefung statt stillschweigen:
    -- ein Punkt ohne Figur zeigt auf keine bestimmte Kontur. Er waere nach der
    -- naechsten Ueberarbeitung der Grafik nicht mehr interpretierbar, und genau
    -- dagegen ist das Feld da.
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE e ? 'point'
        AND jsonb_typeof(e -> 'point') <> 'null'
        AND (NOT e ? 'svg' OR jsonb_typeof(e -> 'svg') = 'null')
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map.svg' USING errcode = '22023';
    END IF;

    SELECT max((e ->> 'pain')::numeric)::smallint
    INTO v_pain_max
    FROM jsonb_array_elements(p_body_map) e
    WHERE jsonb_typeof(e -> 'pain') = 'number';
  END IF;

  INSERT INTO app.daily_checkins (
    team_id, person_id, date, sleep_duration_min, sleep_quality, recovery,
    energy, mental_stress, mental_mood, mental_motivation, training_readiness,
    body_map, pain_max, submitted_at
  )
  VALUES (
    v_team_id, v_person_id, p_date, p_sleep_duration_min, p_sleep_quality, p_recovery,
    p_energy, p_mental_stress, p_mental_mood, p_mental_motivation, p_training_readiness,
    p_body_map, v_pain_max, now()
  )
  ON CONFLICT (person_id, date) DO UPDATE SET
    sleep_duration_min = EXCLUDED.sleep_duration_min,
    sleep_quality      = EXCLUDED.sleep_quality,
    recovery           = EXCLUDED.recovery,
    energy             = EXCLUDED.energy,
    mental_stress      = EXCLUDED.mental_stress,
    mental_mood        = EXCLUDED.mental_mood,
    mental_motivation  = EXCLUDED.mental_motivation,
    training_readiness = EXCLUDED.training_readiness,
    body_map           = EXCLUDED.body_map,
    pain_max           = EXCLUDED.pain_max,
    submitted_at       = EXCLUDED.submitted_at,
    updated_at         = now()
  WHERE app.daily_checkins.team_id = EXCLUDED.team_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.team' USING errcode = '42501';
  END IF;

  -- Score wie Migration 20260918000015 (deskriptiv, keine Diagnose).
  v_score := round((
      coalesce(p_sleep_quality, 5) +
      coalesce(p_recovery, 5) +
      coalesce(p_mental_mood, 5) +
      coalesce(p_mental_motivation, 5) +
      (10 - coalesce(p_mental_stress, 5))
    ) / 5.0, 2);

  INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors, computed_at)
  VALUES (
    v_team_id, v_person_id, p_date, v_score,
    CASE WHEN v_score >= 7 THEN 'high'::app.app_readiness_band
         WHEN v_score >= 5 THEN 'moderate'::app.app_readiness_band
         ELSE 'low'::app.app_readiness_band END,
    jsonb_build_object(
      'sleep_quality', p_sleep_quality,
      'recovery', p_recovery,
      'mental_mood', p_mental_mood,
      'mental_motivation', p_mental_motivation,
      'mental_stress', p_mental_stress,
      'training_readiness', p_training_readiness
    ),
    now()
  )
  ON CONFLICT (person_id, date) DO UPDATE SET
    score_total = EXCLUDED.score_total,
    band        = EXCLUDED.band,
    factors     = EXCLUDED.factors,
    computed_at = EXCLUDED.computed_at;

  RETURN to_jsonb(v_id);
END;
$$;

COMMENT ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) IS
  'ADR-016: only write path for player check-ins. Player role with DB-confirmed claims, person/team from auth helpers, date today or up to 2 days back, upsert per (person_id, date), body_map jsonb array with pain_max, readiness score in the same call. No free text. '
  'AP-43: region checked against app.body_region, optional tap point (two numbers 0 to 1, '
  'normalised to the silhouette viewBox) and optional figure svg as <variant>@<version>, '
  'variant checked against app.body_figure_variant. pain_max still reads pain only. '
  'AP-45d: returns jsonb. On success to_jsonb(id), on denial the error object from app.deny.';

REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) TO authenticated;

-- 2.2 Die vier uebrigen behalten Signatur und Rueckgabetyp, REPLACE genuegt und
-- erhaelt die Rechte.

CREATE OR REPLACE FUNCTION app.rpc_my_body_map_figure()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_row       record;
BEGIN
  v_person_id := app.auth_person_id();
  IF v_person_id IS NULL THEN
    RETURN app.deny('persons.body_map_figure', 'FORBIDDEN: persons.body_map_figure');
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
    RETURN app.deny('persons.body_map_figure', 'FORBIDDEN: persons.body_map_figure');
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
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
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
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
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
    RETURN app.deny('daily_checkins.body_map', 'FORBIDDEN: daily_checkins.body_map');
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

-- =============================================================================
-- 3. Tueren in public: Status setzen, Objekt weiterreichen
-- =============================================================================
--
-- Alle fuenf nach demselben Muster: Ergebnis holen, bei app.is_denial den Status auf
-- 403 setzen, Ergebnis zurueckgeben. set_config mit is_local = true gilt nur fuer diese
-- Transaktion. Die Tueren bleiben SECURITY INVOKER (die app Funktion dahinter ist
-- DEFINER und prueft die Rolle) und search_path bleibt leer, alles ist qualifiziert.

DROP FUNCTION IF EXISTS public.rpc_my_body_map_figure();
DROP FUNCTION IF EXISTS public.rpc_set_my_body_map_figure(text);
DROP FUNCTION IF EXISTS public.rpc_my_body_map_history(integer);
DROP FUNCTION IF EXISTS public.rpc_body_map_region_reports(uuid, integer);

CREATE FUNCTION public.rpc_submit_checkin(
  p_date                date,
  p_sleep_duration_min  numeric DEFAULT NULL,
  p_sleep_quality       integer DEFAULT NULL,
  p_recovery            integer DEFAULT NULL,
  p_energy              integer DEFAULT NULL,
  p_mental_stress       integer DEFAULT NULL,
  p_mental_mood         integer DEFAULT NULL,
  p_mental_motivation   integer DEFAULT NULL,
  p_training_readiness  integer DEFAULT NULL,
  p_body_map            jsonb   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := app.rpc_submit_checkin(
    p_date, p_sleep_duration_min, p_sleep_quality, p_recovery, p_energy,
    p_mental_stress, p_mental_mood, p_mental_motivation, p_training_readiness,
    p_body_map
  );
  IF app.is_denial(v_result) THEN
    PERFORM set_config('response.status', '403', true);
  END IF;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.rpc_my_body_map_figure()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := app.rpc_my_body_map_figure();
  IF app.is_denial(v_result) THEN
    PERFORM set_config('response.status', '403', true);
  END IF;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.rpc_set_my_body_map_figure(p_preference text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := app.rpc_set_my_body_map_figure(p_preference);
  IF app.is_denial(v_result) THEN
    PERFORM set_config('response.status', '403', true);
  END IF;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.rpc_my_body_map_history(p_days integer DEFAULT 28)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := app.rpc_my_body_map_history(p_days);
  IF app.is_denial(v_result) THEN
    PERFORM set_config('response.status', '403', true);
  END IF;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.rpc_body_map_region_reports(p_person_id uuid, p_days integer DEFAULT 28)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := app.rpc_body_map_region_reports(p_person_id, p_days);
  IF app.is_denial(v_result) THEN
    PERFORM set_config('response.status', '403', true);
  END IF;
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) IS
  'AP-34: API-Tuer fuer app.rpc_submit_checkin (ADR-016). Invoker, nur authenticated. '
  'AP-45d: jsonb statt uuid, Ablehnung als Antwort mit response.status 403.';
COMMENT ON FUNCTION public.rpc_my_body_map_figure() IS
  'AP-44c: API-Tuer fuer app.rpc_my_body_map_figure() (AP-43). Invoker, nur authenticated. '
  'AP-45d: volatile statt stable (die Ablehnung schreibt), Status 403 bei Ablehnung.';
COMMENT ON FUNCTION public.rpc_set_my_body_map_figure(text) IS
  'AP-44c: API-Tuer fuer app.rpc_set_my_body_map_figure(text) (AP-43). Invoker, nur authenticated. '
  'AP-45d: Status 403 bei Ablehnung.';
COMMENT ON FUNCTION public.rpc_my_body_map_history(integer) IS
  'AP-45: API-Tuer fuer app.rpc_my_body_map_history(integer). Invoker, nur authenticated. '
  'AP-45d: Status 403 bei Ablehnung.';
COMMENT ON FUNCTION public.rpc_body_map_region_reports(uuid, integer) IS
  'AP-45: API-Tuer fuer app.rpc_body_map_region_reports(uuid, integer). Invoker, nur authenticated. '
  'AP-45d: Status 403 bei Ablehnung.';

REVOKE EXECUTE ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb)                      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_figure()                      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_set_my_body_map_figure(text)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_history(integer)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_body_map_region_reports(uuid, integer)    FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb)                      FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_figure()                      FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_set_my_body_map_figure(text)              FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_my_body_map_history(integer)              FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_body_map_region_reports(uuid, integer)    FROM anon;

GRANT  EXECUTE ON FUNCTION public.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb)                      TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.rpc_my_body_map_figure()                      TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.rpc_set_my_body_map_figure(text)              TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.rpc_my_body_map_history(integer)              TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.rpc_body_map_region_reports(uuid, integer)    TO authenticated, service_role;
