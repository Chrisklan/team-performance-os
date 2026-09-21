-- =============================================================================
-- 15_legacy_revoke_anon.pgtap.sql — Tests zum Rechteentzug fuer anon (AP-39b)
--
-- Die Migration nimmt Rechte. Ein Test, der nur prueft, dass sie durchgelaufen
-- ist, beweist nichts. Geprueft wird deshalb beides:
--   was anon nicht mehr darf, und was authenticated weiterhin darf.
--
-- Der zweite Teil ist der wichtigere. Entscheidung 5 lautet "nur anon", und die
-- Migration muss EXECUTE von PUBLIC nehmen, um an drei geerbte Rechte zu kommen.
-- Genau dort koennte authenticated still mitverlieren.
--
-- Voraussetzung: 15_legacy_revoke_anon.sql ist eingespielt.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;

SELECT no_plan();

-- =============================================================================
-- 1. anon hat im Schema app nichts mehr
-- =============================================================================

SELECT is(has_schema_privilege('anon', 'app', 'USAGE'), false,
  'anon hat kein USAGE mehr auf Schema app. Das ist die eigentliche Tuer');

SELECT is((SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'app' AND c.relkind IN ('r','v','m','p')
              AND (has_table_privilege('anon', c.oid, 'SELECT')
                OR has_table_privilege('anon', c.oid, 'INSERT')
                OR has_table_privilege('anon', c.oid, 'UPDATE')
                OR has_table_privilege('anon', c.oid, 'DELETE'))), 0::bigint,
  'anon hat auf keiner Tabelle oder Sicht in app noch ein Recht');

SELECT is((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'app' AND has_function_privilege('anon', p.oid, 'EXECUTE')), 0::bigint,
  'anon kann keine Funktion in app mehr ausfuehren');

-- Die 22 Legacy Policies haengen an app.tenant(). Solange niemand tenant_id in
-- das Token schreibt, sperren sie ohnehin. Ohne USAGE kommt anon gar nicht erst
-- an die Frage heran (ADR-015).
SELECT is((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'app' AND p.proname IN ('tenant', 'role', 'uid')
              AND has_function_privilege('anon', p.oid, 'EXECUTE')), 0::bigint,
  'anon erreicht auch die Legacy Claim Leser nicht mehr');


-- =============================================================================
-- 2. authenticated ist unberuehrt (Entscheidung 5)
-- =============================================================================

SELECT is(has_schema_privilege('authenticated', 'app', 'USAGE'), true,
  'authenticated hat weiter USAGE auf app. Die Invoker Tueren in public brauchen es');

SELECT is(has_function_privilege('authenticated', 'app.rpc_submit_checkin(date,numeric,integer,integer,integer,integer,integer,integer,integer,jsonb)', 'EXECUTE'), true,
  'authenticated darf weiter app.rpc_submit_checkin ausfuehren');

SELECT is(has_function_privilege('authenticated', 'public.rpc_submit_checkin(date,numeric,integer,integer,integer,integer,integer,integer,integer,jsonb)', 'EXECUTE'), true,
  'die Tuer public.rpc_submit_checkin ist fuer authenticated offen');

SELECT is(has_function_privilege('authenticated', 'public.rpc_trainer_morning_ops()', 'EXECUTE'), true,
  'die Tuer public.rpc_trainer_morning_ops ist fuer authenticated offen');

SELECT is(has_function_privilege('authenticated', 'app.rpc_shred_person(uuid)', 'EXECUTE'), true,
  'authenticated darf weiter app.rpc_shred_person aufrufen (die Rollenpruefung sitzt in der Funktion)');

-- Die drei Funktionen, deren EXECUTE vor der Migration nur ueber PUBLIC kam.
-- Sie sind der Grund fuer Schritt 0 der Migration.
SELECT is(has_function_privilege('authenticated', 'app.denial_actor_role()', 'EXECUTE'), true,
  'authenticated hat app.denial_actor_role behalten, obwohl das Recht vorher nur geerbt war');


-- =============================================================================
-- 3. Der Auth Hook bleibt zu (ADR-015)
-- =============================================================================

SELECT is(has_function_privilege('authenticated', 'app.custom_access_token_hook(jsonb)', 'EXECUTE'), false,
  'authenticated darf den Auth Hook weiterhin nicht ausfuehren');
SELECT is(has_function_privilege('anon', 'app.custom_access_token_hook(jsonb)', 'EXECUTE'), false,
  'anon darf den Auth Hook weiterhin nicht ausfuehren');
SELECT is(has_schema_privilege('supabase_auth_admin', 'app', 'USAGE'), true,
  'supabase_auth_admin hat weiter USAGE auf app, sonst scheitert jeder Login');


SELECT * FROM finish();
ROLLBACK;
