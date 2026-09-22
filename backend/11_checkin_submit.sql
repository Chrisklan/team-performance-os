-- =============================================================================
-- 11_checkin_submit.sql — Check-In der Player-App direkt nach app.* (AP-33)
-- ADR-016 Weg (b): app.rpc_submit_checkin ist der einzige Schreibweg der App.
-- Kein Sync aus public.*, kein zweiter Speicherort fuer Gesundheitsdaten.
--
-- * Nur Rolle player mit bestaetigten Claims (Waechter Stufe 2, ADR-015).
-- * person_id und team_id kommen nur aus auth_person_id()/auth_team_id().
-- * Datum: heute oder bis zu 2 Tage zurueck (Offline-Nachtrag).
-- * Idempotent je (person_id, date): zweiter Aufruf am selben Tag ersetzt.
-- * Body Map als jsonb-Array [{region, pain, art, point, svg}], pain_max berechnet.
-- * Score im selben Aufruf nach app.readiness_scores (Formel Migration 000015).
-- * Kein Freitext (Entscheidung Chris 2026-09-19, Datenminimierung).
--
-- AP-43 (2026-09-21), Modul-Body-Map Abschnitt 3.1 und 6:
--   * region wird gegen app.body_region geprueft. Vorher ging jeder String
--     durch, knie_l, knee_l und "Knie links" landeten in derselben Spalte und
--     die Historie eines Spielers zerfiel beim naechsten App Update.
--   * point ist der Tippunkt: optional, genau zwei Zahlen von 0 bis 1,
--     normiert auf die viewBox der Silhouette, nicht in Pixeln. Er ist ein Bild
--     fuer die Physio, kein Messwert: pain_max liest weiter nur pain, und
--     nichts rechnet mit ihm (Modul Abschnitt 8).
--   * svg ist die Figur, auf der getippt wurde, als <variante>@<version>.
--     Variante gegen app.body_figure_variant, Version nur auf Format
--     (Entscheidung Chris 2026-09-21).
--   * art bleibt ungeprueft, wie bisher. Nicht Teil von AP-43.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 16_body_region.sql. Idempotent.
-- =============================================================================

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
RETURNS uuid
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
    PERFORM app.log_denial('daily_checkins.submit');
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.submit' USING errcode = '42501';
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

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) IS
  'ADR-016: only write path for player check-ins. Player role with DB-confirmed claims, person/team from auth helpers, date today or up to 2 days back, upsert per (person_id, date), body_map jsonb array with pain_max, readiness score in the same call. No free text. '
  'AP-43: region checked against app.body_region, optional tap point (two numbers 0 to 1, '
  'normalised to the silhouette viewBox) and optional figure svg as <variant>@<version>, '
  'variant checked against app.body_figure_variant. pain_max still reads pain only.';

REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) TO authenticated;

-- -----------------------------------------------------------------------------
-- AP-45d (2026-09-21): die Ablehnung wurde von dem RAISE mit zurueckgerollt
-- (Befund F1). Ab jetzt ist sie Antwort statt Ausnahme. Die Funktionen dieser Datei,
-- die davon betroffen sind, werden in 20_denial_answer.sql zuletzt neu angelegt.
-- Wer hier etwas am Waechter oder am Rueckgabetyp aendert, muss 20 nachziehen.
-- -----------------------------------------------------------------------------
