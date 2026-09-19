-- =============================================================================
-- refresh_pilot_dates.sql — Pilot-Seed auf heute verschieben (AP-32)
--
-- Kein Migrationsschritt. Manuell einspielen, wenn das Dashboard Werte fuer
-- das aktuelle Datum braucht (rpc_morning_ops() filtert auf current_date).
--
-- Was es tut:
--   Das feste Seed-Fenster 2026-08-23 bis 2026-09-05 (14 Tage) ist die Vorlage.
--   Jede Vorlagenzeile wird um (current_date - 2026-09-05) Tage nach vorn
--   kopiert, sodass die letzten 14 Tage bis heute gefuellt sind. Gilt fuer
--   app.daily_checkins und die zugehoerigen app.readiness_scores.
--
-- Eigenschaften:
--   * Idempotent: ON CONFLICT (person_id, date) DO NOTHING. Zweiter Lauf am
--     selben Tag fuegt nichts ein.
--   * Nur Kopieren, kein UPDATE, kein DELETE. Die Vorlage und echte Check-Ins
--     bleiben unangeaendert, vorhandene (person, datum) werden nie ueberschrieben.
--   * Scores nur zu Check-Ins, die dieser Lauf neu angelegt hat.
--   * Nur aktive Personen. Struktur, Policies und RPC-Logik bleiben unberuehrt.
--   * Ein einziges Statement, also atomar, unabhaengig davon, wie der Client
--     Transaktionen handhabt.
--   * Der Audit-Trigger (app.audit_log_trigger) schreibt fuer jede neue Zeile
--     einen audit_log-Eintrag. Actor ist NULL, weil kein JWT gesetzt ist.
--
-- Aufruf lokal:  psql -X -h /tmp -v ON_ERROR_STOP=1 -d <db> -f supabase/seed/refresh_pilot_dates.sql
-- Aufruf Cloud:  nur nach Freigabe durch Chris, Zeilenzahlen vorher und nachher.
-- =============================================================================

WITH cfg AS (
  SELECT
    date '2026-08-23'                    AS tpl_start,
    date '2026-09-05'                    AS tpl_end,
    (current_date - date '2026-09-05')   AS shift_days
),
new_checkins AS (
  INSERT INTO app.daily_checkins (
    team_id, person_id, date,
    sleep_duration_min, sleep_quality, recovery, energy,
    mental_stress, mental_mood, mental_motivation,
    training_readiness, pain_max, body_map,
    submitted_at, created_at
  )
  SELECT
    t.team_id,
    t.person_id,
    t.date + cfg.shift_days,
    t.sleep_duration_min, t.sleep_quality, t.recovery, t.energy,
    t.mental_stress, t.mental_mood, t.mental_motivation,
    t.training_readiness, t.pain_max, t.body_map,
    t.submitted_at + make_interval(days => cfg.shift_days),
    t.submitted_at + make_interval(days => cfg.shift_days)
  FROM cfg
  JOIN app.daily_checkins t
    ON t.date BETWEEN cfg.tpl_start AND cfg.tpl_end
  JOIN app.persons p
    ON p.id = t.person_id AND p.is_active
  WHERE cfg.shift_days > 0
  ON CONFLICT (person_id, date) DO NOTHING
  RETURNING person_id, date
),
new_scores AS (
  INSERT INTO app.readiness_scores (
    team_id, person_id, date, score_total, band, factors, computed_at, created_at
  )
  SELECT
    s.team_id,
    s.person_id,
    s.date + cfg.shift_days,
    s.score_total, s.band, s.factors,
    s.computed_at + make_interval(days => cfg.shift_days),
    s.computed_at + make_interval(days => cfg.shift_days)
  FROM cfg
  JOIN new_checkins n
    ON true
  JOIN app.readiness_scores s
    ON s.person_id = n.person_id
   AND s.date = n.date - cfg.shift_days
  ON CONFLICT (person_id, date) DO NOTHING
  RETURNING person_id, date
)
SELECT
  (SELECT shift_days FROM cfg)        AS shift_days,
  (SELECT count(*) FROM new_checkins) AS checkins_inserted,
  (SELECT count(*) FROM new_scores)   AS scores_inserted;
