-- =============================================================================
-- 24_legacy_rpc_revoke.sql — EXECUTE auf den beiden Legacy Definer RPCs
-- entziehen (Befund N9, 2026-09-22, Entscheidung von Chris am selben Tag)
--
-- Der Befund, gefunden beim Messen von Punkt 51 und dort nicht mit erledigt:
--   public.rpc_morning_ops(p_date date)
--   public.rpc_player_drilldown(p_person_id uuid, p_date date)
-- Beide sind SECURITY DEFINER, Eigentuemer ist postgres, und postgres traegt
-- rolbypassrls (gemessen: rolsuper false, rolbypassrls true). RLS gilt in
-- ihrem Rumpf also nicht. Sie lesen players, daily_checkins, readiness_scores,
-- baselines und medical_records direkt, nicht ueber die beiden Sichten
-- daily_checkins_staff und medical_status_view. Migration 20260922000034, die
-- public.is_staff() und public.is_medical_role() schliesst, erreicht sie
-- deshalb nicht: ihr einziger Waechter ist current_app_role() IS NOT NULL,
-- plus eine self Pruefung in rpc_player_drilldown, die nur fuer den Claim
-- 'player' greift. Jeder andere Claim kommt durch.
--
-- Warum der Entzug nichts kostet, gemessen am 2026-09-22:
--   * Kein Client ruft eine der beiden. Grep ueber Web app/, lib/, components/
--     und Player src/: der Web Client ruft ausschliesslich
--     public.rpc_trainer_morning_ops, der Player ausschliesslich seine eigenen
--     Tueren. Der Name rpc_morning_ops im Web meint die Tuer, nicht diese
--     Legacy Funktion mit Datumsparameter.
--   * Die Daten dahinter sind heute duenn: public.readiness_scores 0 Zeilen,
--     public.baselines 0 Zeilen, public.medical_records 0 Zeilen. Offen war
--     trotzdem der Weg, und ein Weg ohne RLS ist der Befund, nicht die Fuellung.
--
-- Bestandswahrung. Die ACL beider Funktionen ist bereits materialisiert
-- (proacl IS NOT NULL, gemessen):
--   postgres=EXECUTE, anon=EXECUTE, authenticated=EXECUTE, service_role=EXECUTE
-- Es gibt keinen PUBLIC Eintrag. Das REVOKE FROM PUBLIC unten kann deshalb
-- keine Default ACL festschreiben (Lessons Learned: ein REVOKE materialisiert
-- die ACL, die es leeren will) und ist reine Verteidigung in zweiter Reihe.
-- postgres und service_role behalten ihr Recht: der Eigentuemer, damit die
-- Funktion wartbar bleibt, und service_role, weil der Service Key ohnehin an
-- RLS vorbeigeht und kein zusaetzliches Loch aufmacht.
--
-- Zuruecknehmbar mit genau zwei GRANT Zeilen.
-- Idempotent, laeuft nur, wenn die Funktionen existieren (eine reine app
-- Datenbank wie tpos_gate_test traegt sie nicht).
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('public.rpc_morning_ops(date)') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION public.rpc_morning_ops(date) FROM PUBLIC;
    REVOKE EXECUTE ON FUNCTION public.rpc_morning_ops(date) FROM anon;
    REVOKE EXECUTE ON FUNCTION public.rpc_morning_ops(date) FROM authenticated;
    COMMENT ON FUNCTION public.rpc_morning_ops(date) IS
      'Legacy (AP-39). Seit 2026-09-22 kein EXECUTE fuer anon und authenticated: SECURITY DEFINER mit bypassrls Eigentuemer, liest die Basistabellen direkt (Befund N9). Der Trainer Weg ist public.rpc_trainer_morning_ops -> app.rpc_morning_ops().';
  END IF;

  IF to_regprocedure('public.rpc_player_drilldown(uuid, date)') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION public.rpc_player_drilldown(uuid, date) FROM PUBLIC;
    REVOKE EXECUTE ON FUNCTION public.rpc_player_drilldown(uuid, date) FROM anon;
    REVOKE EXECUTE ON FUNCTION public.rpc_player_drilldown(uuid, date) FROM authenticated;
    COMMENT ON FUNCTION public.rpc_player_drilldown(uuid, date) IS
      'Legacy (AP-39). Seit 2026-09-22 kein EXECUTE fuer anon und authenticated (Befund N9). Kein Client ruft sie.';
  END IF;
END $$;
