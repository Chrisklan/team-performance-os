-- =============================================================================
-- 20260922000034_legacy_gate_close.sql (Quelle: backend/23_legacy_gate_close.sql) — Legacy Pfad public.* fuer Staff, Medizin und Admin
-- schliessen (Befund N6, Bridge Punkt 51, erledigt damit auch Punkt 24)
--
-- Der Befund (Audits/2026-09-21-ap45-bodymap-verlauf, Abschnitt 11.5, N6):
-- public.is_staff() prueft gegen coach, athletik, physio, arzt, admin, der
-- Claims Hook stellt aber app.app_role aus: coach, athletic_coach, physio,
-- doctor, admin. Zwei Vokabulare, die sich an drei Stellen nicht treffen.
--
-- Gemessen am 2026-09-22 in der Cloud (nur lesend, set_config in der FROM
-- Liste, je Rolle ein eigener Lauf, Gegenprobe mit doctor und player = 0):
--   Claim admin           -> is_staff true,  280 Zeilen public.daily_checkins
--   Claim arzt            -> is_staff true,  is_medical_role true, 280 Zeilen
--   Claim doctor          -> is_staff false, is_medical_role false, 0 Zeilen
--   Claim athletic_coach  -> is_staff false, 0 Zeilen
--   Claim player          -> is_staff false, 0 Zeilen
-- public.daily_checkins ist eine flache Tabelle mit soreness und free_text,
-- ohne Spaltenrechte. Wer dort Staff ist, sieht beides. Die Matrix gibt admin
-- auf daily_check_ins gar keinen Zugriff und coach/athletic_coach ein fettes
-- "-" auf body_map und free_text mit visibility med_only.
--
-- Die Wahl von Chris am 2026-09-22: SCHLIESSEN, nicht angleichen.
-- Der Grund gegen das Angleichen ist gemessen, nicht gemeint: haette
-- is_staff() auch athletic_coach gelernt, waere aus 0 sichtbaren Zeilen 280
-- geworden. Die Option haette den Verstoss vergroessert, statt ihn zu heilen.
--
-- Was diese Migration tut, drei Anweisungen:
--   1. public.is_staff()        gibt false zurueck
--   2. public.is_medical_role() gibt false zurueck
--   3. public.medical_records_select verliert den Zweig current_app_role() =
--      'admin' (Modul Abschnitt 5, Warnung Punkt 4). is_medical_role false
--      allein haette den Zweig stehen lassen.
-- Die self Zweige bleiben unberuehrt: player_id = current_player_id() traegt
-- weiter, und current_app_role() und current_player_id() werden nicht angefasst.
--
-- Warum die Funktionen bleiben und nur ihr Rumpf wechselt: 40 Policies auf 20
-- Tabellen nennen sie. Ein DROP zoege 40 Policy Aenderungen nach sich, ein
-- Rumpf ist eine Zeile und in einer Zeile zuruecknehmbar.
--
-- Wer bricht davon? Gemessen: niemand.
--   * Kein Client liest public.* als Tabelle. Beide Repos rufen ausschliesslich
--     RPCs (grep ueber Web app/, lib/, components/ und Player src/).
--   * Keine Funktion in public oder app ruft is_staff() oder is_medical_role().
--   * Zwei Sichten nennen sie, public.daily_checkins_staff und
--     public.medical_status_view. Beide werden damit leer. Kein Client liest sie.
--
-- NICHT geschlossen, und deshalb ein eigener Befund (N9, im Audit):
-- public.rpc_morning_ops(date) und public.rpc_player_drilldown(uuid, date) sind
-- SECURITY DEFINER, ihr Eigentuemer postgres hat rolbypassrls, und sie lesen die
-- Basistabellen direkt statt ueber die beiden Sichten. Ihr einziger Waechter ist
-- current_app_role() IS NOT NULL. Diese Migration erreicht sie nicht. Beide sind
-- fuer anon und authenticated ausfuehrbar und liegen in public, also exponiert.
--
-- NICHT Teil dieser Migration, weil AP-41: die Schreibpolicies, die
-- current_app_role() gegen 'coach' und 'athletik' pruefen (attendance, fines,
-- calendar_events, matches, messages). Sie sind heute durch dasselbe Vokabular
-- Missverhaeltnis tot, weil der Hook athletic_coach statt athletik ausstellt.
-- Tot durch Zufall ist kein Schutz, aber es ist auch kein Notfall.
--
-- Idempotent. Die Policy Aenderung laeuft nur, wenn die Tabelle existiert,
-- damit die Datei auch gegen eine reine app Datenbank laeuft.
-- =============================================================================

-- 1. ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
    -- Geschlossen am 2026-09-22 (Befund N6, Bridge Punkt 51 und 24).
    -- Vorher: SELECT current_app_role() IN ('coach','athletik','physio','arzt','admin');
    -- Zurueck geht es mit genau dieser Zeile.
    SELECT false;
$$;

COMMENT ON FUNCTION public.is_staff() IS
  'Seit 2026-09-22 immer false. Der Legacy Pfad public.* ist fuer Staff, Medizin und Admin zu, nur self bleibt (Befund N6).';

-- 2. ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_medical_role()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
    -- Geschlossen am 2026-09-22. Vorher:
    -- SELECT current_app_role() IN ('physio', 'arzt');
    -- Der Lesepfad der Medizin ist app.*, nicht public.*.
    SELECT false;
$$;

COMMENT ON FUNCTION public.is_medical_role() IS
  'Seit 2026-09-22 immer false. Medizin liest ueber app.*, nicht ueber den Legacy Pfad (Befund N6).';

-- 3. ---------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.medical_records') IS NOT NULL THEN
    DROP POLICY IF EXISTS medical_records_select ON public.medical_records;
    CREATE POLICY medical_records_select ON public.medical_records
      FOR SELECT
      USING (public.is_medical_role() OR player_id = public.current_player_id());
  END IF;
END $$;
