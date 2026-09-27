-- =============================================================================
-- 39_column_privileges_revoke_ap41.sql — backend-Spiegel fuer die bereits in
-- der Cloud angewendete Migration supabase/migrations/20260925134906_
-- column_privileges_revoke_ap41.sql (AP-41, Bridge Punkt 58).
--
-- FUND (Security-Review, dritte Runde, 2026-09-27): diese Migration hatte
-- bisher KEINEN Spiegel in backend/*.sql. Zweck dieser Datei: Spiegel zur
-- Vollstaendigkeit der Migrationshistorie, damit backend/*.sql jede in der
-- Cloud angewendete Migration abbildet. Lokal ist sie ein No-Op: die sechs
-- betroffenen public-Tabellen entstehen nur in backend/schema.sql, das nicht
-- Teil der lokalen Testkette (08 bis 39) ist -- die Guards unten greifen
-- dort nicht, es wird nichts entzogen, und die lokale Testkette weicht in
-- diesem Punkt auch vorher nicht von der Cloud ab (die Tabellen fehlen
-- lokal einfach). In der Cloud bildet sie EXAKT denselben REVOKE nach, der
-- dort seit 2026-09-25 bereits gilt. KEINE neue Migration: die Cloud hat
-- diesen Schritt bereits (per Supabase-MCP bestaetigt), nur der backend-
-- Spiegel fehlte.
--
-- WICHTIG, kein Verwechslungsrisiko: die sechs Tabellen hier sind
-- public.daily_checkins/players/profiles/baselines/load_deviations/
-- medical_records -- die tote Vor-Silo-Generation (siehe backend/schema.sql,
-- NICHT Teil der lokalen Testkette, ADR-001/ADR-009/ADR-011 haben app.* als
-- alleinige Schicht abgeloest). Das ist NICHT dasselbe wie app.daily_checkins
-- (die live Tabelle, die diese und die Modul-6-Migration 38_training_load.sql
-- durchgaengig verwenden) -- app.daily_checkins hat weiterhin ein eigenes,
-- unveraendertes INSERT/UPDATE-Grant fuer authenticated (siehe 09_rpcs.sql),
-- das von DIESER Migration bewusst nicht beruehrt wird (ausserhalb des
-- Scopes dieses Spiegels, Backlog-Entscheidung an Chris, siehe Kopfkommentar
-- von backend/38_training_load.sql).
--
-- Guards (to_regclass): backend/schema.sql (wo diese sechs Tabellen entstehen)
-- ist bewusst NICHT Teil der lokalen Testkette (tote Vor-Silo-Generation,
-- siehe Kopfkommentar von backend/38_training_load.sql). Ohne Guard wuerde
-- REVOKE ... ON public.players lokal mit "relation does not exist" scheitern.
-- In der Cloud existieren alle sechs Tabellen, die Guards sind dort ein
-- reiner No-Op (IF EXISTS greift, REVOKE laeuft wie im Original).
-- =============================================================================

DO $$ BEGIN
  IF to_regclass('public.daily_checkins') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.daily_checkins FROM authenticated, anon;
  END IF;
END $$;

DO $$ BEGIN
  IF to_regclass('public.players') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.players FROM authenticated, anon;
  END IF;
END $$;

DO $$ BEGIN
  IF to_regclass('public.profiles') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.profiles FROM authenticated, anon;
  END IF;
END $$;

DO $$ BEGIN
  IF to_regclass('public.baselines') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.baselines FROM authenticated, anon;
  END IF;
END $$;

DO $$ BEGIN
  IF to_regclass('public.load_deviations') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.load_deviations FROM authenticated, anon;
  END IF;
END $$;

DO $$ BEGIN
  IF to_regclass('public.medical_records') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.medical_records FROM authenticated, anon;
  END IF;
END $$;
