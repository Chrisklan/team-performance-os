-- =============================================================================
-- 23_legacy_gate_close.pgtap.sql — der Legacy Pfad bleibt zu (Befund N6)
--
-- Was hier geprueft wird und was nicht: die Legacy Tabellen (public.daily_checkins,
-- public.medical_records, public.players, public.profiles) liegen NICHT in
-- tpos_gate_test, diese Datenbank traegt nur das Schema app. Die Suite prueft
-- deshalb den Teil, der ohne sie traegt: die beiden Helfer selbst, fuer jeden
-- Wert, den der Hook oder der Seed ausstellen kann, und die Wirkung einer
-- Policy, die auf ihnen steht.
--
-- Die Wirkung auf die echten Legacy Tabellen ist in einer eigenen Wegwerf
-- Datenbank gemessen worden (tpos_legacy_probe aus backend/schema.sql und
-- backend/rls.sql, Autocommit, SET ROLE authenticated, echte Claims). Ergebnis
-- im Audit, Abschnitt 12: vorher sahen coach, athletik, physio, arzt und admin
-- die fremden Zeilen, nachher keiner davon, und die Spielerin sieht ihre eigene
-- Zeile unveraendert. Eine pgTAP Suite kann das nicht ersetzen, sie kann nur
-- verhindern, dass jemand den Rumpf zurueckdreht, ohne es zu merken.
--
-- Voraussetzung: 23_legacy_gate_close.sql ist eingespielt.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(30);

CREATE FUNCTION app._t23_claim(p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', '00000000-0000-0000-0000-0000000000aa',
                       'role', 'authenticated', 'app_role', p_role)::text,
    true);
$$;

-- ---------------------------------------------------------------------------
-- 1. Jeder Wert aus beiden Vokabularen bekommt false. Auch die drei, die vor
--    dem 2026-09-22 true bekamen (coach, athletik, physio, arzt, admin), und
--    die drei, die der Hook ausstellt und die der Legacy Pfad nie kannte.
-- ---------------------------------------------------------------------------
SELECT app._t23_claim('coach');
SELECT is(public.is_staff(), false, 'is_staff: coach bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: coach bekommt false');
SELECT app._t23_claim('athletik');
SELECT is(public.is_staff(), false, 'is_staff: athletik bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: athletik bekommt false');
SELECT app._t23_claim('athletic_coach');
SELECT is(public.is_staff(), false, 'is_staff: athletic_coach bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: athletic_coach bekommt false');
SELECT app._t23_claim('physio');
SELECT is(public.is_staff(), false, 'is_staff: physio bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: physio bekommt false');
SELECT app._t23_claim('arzt');
SELECT is(public.is_staff(), false, 'is_staff: arzt bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: arzt bekommt false');
SELECT app._t23_claim('doctor');
SELECT is(public.is_staff(), false, 'is_staff: doctor bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: doctor bekommt false');
SELECT app._t23_claim('admin');
SELECT is(public.is_staff(), false, 'is_staff: admin bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: admin bekommt false');
SELECT app._t23_claim('player');
SELECT is(public.is_staff(), false, 'is_staff: player bekommt false');
SELECT is(public.is_medical_role(), false, 'is_medical_role: player bekommt false');

-- Ohne jeden Claim (anon): ebenfalls false, nicht NULL.
SELECT set_config('request.jwt.claims', '', true);
SELECT is(public.is_staff(), false, 'is_staff: ohne Claims false, nicht NULL');
SELECT is(public.is_medical_role(), false, 'is_medical_role: ohne Claims false, nicht NULL');

-- ---------------------------------------------------------------------------
-- 2. Die Funktionen bleiben, was die 40 Policies von ihnen erwarten
-- ---------------------------------------------------------------------------
SELECT is((SELECT provolatile FROM pg_proc WHERE oid = 'public.is_staff()'::regprocedure), 's',
  'is_staff bleibt STABLE');
SELECT is((SELECT prosecdef FROM pg_proc WHERE oid = 'public.is_staff()'::regprocedure), true,
  'is_staff bleibt SECURITY DEFINER');
SELECT is((SELECT provolatile FROM pg_proc WHERE oid = 'public.is_medical_role()'::regprocedure), 's',
  'is_medical_role bleibt STABLE');
SELECT is((SELECT prosecdef FROM pg_proc WHERE oid = 'public.is_medical_role()'::regprocedure), true,
  'is_medical_role bleibt SECURITY DEFINER');
SELECT ok(has_function_privilege('authenticated', 'public.is_staff()', 'EXECUTE'),
  'authenticated darf is_staff weiter ausfuehren, sonst brechen die Policies');
SELECT ok(has_function_privilege('authenticated', 'public.is_medical_role()', 'EXECUTE'),
  'authenticated darf is_medical_role weiter ausfuehren');

-- ---------------------------------------------------------------------------
-- 3. Wirkungsprobe an einer Policy derselben Bauart, mit Positivkontrolle.
--    Ohne die Kontrolle bewiese ein "0 Zeilen" nur, dass der Aufbau nicht traegt.
-- ---------------------------------------------------------------------------
CREATE TABLE app._t23_legacy_like (id int primary key, inhalt text);
INSERT INTO app._t23_legacy_like VALUES (1, 'fremde Zeile'), (2, 'zweite fremde Zeile');
ALTER TABLE app._t23_legacy_like ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_staff ON app._t23_legacy_like FOR SELECT USING (public.is_staff());
CREATE POLICY p_kontrolle ON app._t23_legacy_like FOR SELECT USING (current_setting('app._t23_kontrolle', true) = 'an');
GRANT SELECT ON app._t23_legacy_like TO authenticated;

SET ROLE authenticated;
SELECT app._t23_claim('coach');
SELECT is((SELECT count(*)::int FROM app._t23_legacy_like), 0,
  'Policy is_staff(): coach sieht keine fremde Zeile mehr');
SELECT app._t23_claim('admin');
SELECT is((SELECT count(*)::int FROM app._t23_legacy_like), 0,
  'Policy is_staff(): admin sieht keine fremde Zeile mehr');
SELECT app._t23_claim('arzt');
SELECT is((SELECT count(*)::int FROM app._t23_legacy_like), 0,
  'Policy is_staff(): arzt sieht keine fremde Zeile mehr');
-- Positivkontrolle: derselbe Aufbau, dieselbe Rolle, nur ein anderes Praedikat.
SELECT set_config('app._t23_kontrolle', 'an', true);
SELECT is((SELECT count(*)::int FROM app._t23_legacy_like), 2,
  'Positivkontrolle: mit wahrem Praedikat liefert derselbe Aufbau 2 Zeilen');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 4. Regressionsanker am Rumpf
-- ---------------------------------------------------------------------------
SELECT ok((SELECT prosrc FROM pg_proc WHERE oid = 'public.is_staff()'::regprocedure) ~* 'select\s+false',
  'Regressionsanker: is_staff gibt woertlich false zurueck');
SELECT ok((SELECT prosrc FROM pg_proc WHERE oid = 'public.is_medical_role()'::regprocedure) ~* 'select\s+false',
  'Regressionsanker: is_medical_role gibt woertlich false zurueck');

SELECT * FROM finish();
ROLLBACK;
