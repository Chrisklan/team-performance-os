-- Migration 20260921000024_legacy_revoke_anon.sql (AP-39b, Teil F Stufe 2 Schritt 1)
-- Quelle: backend/15_legacy_revoke_anon.sql (identisch). Tests: backend/15_legacy_revoke_anon.pgtap.sql.
-- Nimmt der Rolle anon alle Rechte im Schema app. Schreibt keine Daten,
-- einzeln zuruecknehmbar. authenticated bleibt unveraendert.

-- =============================================================================
-- 15_legacy_revoke_anon.sql — Rechteentzug im Schema app fuer anon (AP-39b)
--
-- Teil F Stufe 2 Schritt 1 des Legacy Audits, Entscheidung 5 von Chris
-- (2026-09-21): jetzt, und zuerst nur fuer `anon`. `authenticated` bleibt
-- unberuehrt, weil die beiden Invoker Funktionen public.rpc_submit_checkin und
-- public.rpc_trainer_morning_ops USAGE auf app brauchen.
--
-- Diese Migration ist bewusst von 14_shred_person.sql getrennt: sie loescht
-- nichts, sie nimmt nur Rechte, und sie ist einzeln zuruecknehmbar.
--
-- NACHGEMESSEN in der Cloud am 2026-09-21, lesend, vor dieser Migration:
--   anon hat USAGE auf Schema app                                    ja
--   anon hat Rechte auf app Tabellen                        0 von 32
--   anon kann app Funktionen ausfuehren                    33 von 55
--     davon mit eigenem Grant                                      30
--     davon nur ueber PUBLIC geerbt (proacl IS NULL)                3
--       denial_actor_role(), log_immutable(), mr_guard()
--   Funktionen in public, die app beruehren und fuer anon ausfuehrbar sind   0
--   Sichten in public, die app beruehren                                    0
-- Kein anon Pfad beruehrt heute das Schema app. Der Entzug bricht nichts.
--
-- Die Reihenfolge der Anweisungen folgt der Wirkung, nicht der Bequemlichkeit:
-- das USAGE auf dem Schema ist die eigentliche Tuer, alles davor ist
-- Verteidigung in zweiter Reihe fuer den Fall, dass jemand das USAGE spaeter
-- wieder vergibt.
--
-- Warum das ueberhaupt noetig ist, obwohl alle Legacy Tabellen leer sind:
-- 22 der 36 Legacy Policies sperren nur, weil app.tenant() ohne den Claim
-- `tenant_id` NULL liefert. Das ist ein Umstand, keine Entscheidung. Wer diesen
-- Claim je in das Token schreibt, schaltet in einem Schritt Lese und
-- Schreibrechte auf Art.-9-Tabellen scharf (ADR-015). Rechte entziehen ist
-- umkehrbar und kostet nichts.
--
-- Voraussetzung: 08_reconciling.sql. Idempotent.
-- Tests: backend/15_legacy_revoke_anon.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Bestand von authenticated festschreiben, BEVOR irgendetwas entzogen wird.
--
--    Entscheidung 5 sagt: authenticated bleibt unberuehrt. Das ist hier keine
--    Selbstverstaendlichkeit, denn Schritt 3 muss EXECUTE von PUBLIC nehmen, und
--    authenticated erbt einen Teil seiner Rechte ueber PUBLIC. Dieser Block macht
--    aus geerbten Rechten ausdrueckliche, ohne ein einziges neues zu vergeben:
--    er grantet genau dort, wo authenticated das Recht in diesem Moment hat.
--    Die 4 Funktionen, auf die authenticated heute KEIN EXECUTE hat (darunter der
--    Auth Hook aus ADR-015), bleiben deshalb zu.
--
--    Die Stellung ganz oben ist kein Stil, sondern Bedingung: schon ein
--    `REVOKE ... FROM anon` materialisiert die bis dahin leere ACL einer
--    Funktion. Liefe dieser Block danach, fande er nichts mehr vor und
--    authenticated verlaere die geerbten Rechte still.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'app'
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Tabellen, Sichten und Sequenzen. Heute ein Nulleingriff (anon hat dort
--    nichts), aber er haelt, wenn jemand spaeter pauschal grantet.
-- -----------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA app FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA app FROM anon;

-- -----------------------------------------------------------------------------
-- 2. Funktionen. Die 30 mit eigenem Grant trifft REVOKE FROM anon direkt.
-- -----------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS  IN SCHEMA app FROM anon;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA app FROM anon;

-- -----------------------------------------------------------------------------
-- 3. Drei Funktionen haben keine eigene ACL und erben EXECUTE ueber PUBLIC. Ein
--    REVOKE von anon laeuft dort ins Leere, weil anon gar keinen eigenen Eintrag
--    hat. Sie brauchen ein REVOKE FROM PUBLIC, und das traefe auch
--    authenticated. Deshalb steht Schritt 0 ganz oben: er hat den Bestand von
--    authenticated vorher festgeschrieben.
-- -----------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS  IN SCHEMA app FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA app FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 4. Das USAGE auf dem Schema. Ohne USAGE nuetzt ein EXECUTE nichts, auch ein
--    spaeter geerbtes nicht.
--    Achtung fuer kuenftige Sessions: 08_reconciling.sql vergibt in Abschnitt 1
--    `GRANT USAGE ON SCHEMA app TO authenticated, anon, service_role`. Wer diese
--    Datei neu einspielt, oeffnet die Tuer wieder und muss danach diese
--    Migration erneut laufen lassen.
-- -----------------------------------------------------------------------------
REVOKE USAGE ON SCHEMA app FROM anon;

-- -----------------------------------------------------------------------------
-- 5. Neue Objekte sollen nicht von selbst wieder offen sein. Gilt fuer die
--    Rolle, die diese Migration ausfuehrt (Cloud: postgres), und damit fuer
--    alles, was kuenftige Migrationen in app anlegen.
-- -----------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE ALL ON TABLES    FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE ALL ON FUNCTIONS FROM anon, PUBLIC;

COMMENT ON SCHEMA app IS
  'Zielarchitektur TPOS. Ueber PostgREST nicht exponiert, jede API Tuer liegt als '
  'eigene Funktion in public. Seit AP-39b (2026-09-21) hat anon hier weder USAGE '
  'noch Rechte auf Tabellen oder Funktionen. authenticated ist unveraendert.';
