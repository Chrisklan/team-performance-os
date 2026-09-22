-- =============================================================================
-- 20260922000037_app_execute_revoke.sql (Quelle: backend/26_app_execute_revoke.sql)
-- EXECUTE auf den acht Funktionen ohne Tuer entziehen (Punkt 55, Befund N5,
-- Entscheidung von Chris am 2026-09-22)
--
-- Der Befund (Audit 2026-09-21, Abschnitt 11.5): authenticated hat USAGE auf das
-- Schema app und EXECUTE auf 56 Funktionen darin. Acht davon haben keine Tuer in
-- public und keinen Aufrufer. Was sie draussen haelt, ist die Projekteinstellung
-- db-schemas ("public, graphql_public"), also eine Zeile Konfiguration, kein
-- Datenbankrecht. Gemessen gegen die gehostete PostgREST mit dem anon Schluessel:
--   POST /rest/v1/rpc/rpc_check_ins_medical, Header Content-Profile: app
--   -> HTTP 406 PGRST106 "Invalid schema: app"
-- Wer app spaeter exponiert, und das ist beim Bau der Physio Sicht ein plausibler
-- Schritt, oeffnet in derselben Sekunde F2, N2, N3, N4 und acht zurueckgerollte
-- Ablehnungen.
--
-- Die acht und was sie anfassen:
--   rpc_check_ins_medical   Check-ins des Teams samt body_map und Tippunkt
--   rpc_get_clearance       liest die medizinische Freigabe einer Person
--   rpc_set_clearance       setzt sie
--   rpc_propose_clearance   schlaegt sie vor (Physio schlaegt vor, Arzt entscheidet)
--   rpc_readiness_full      voller Readiness Wert mit allen Faktoren, nicht nur das Band
--   rpc_release_deviation   gibt eine auffaellige Trainingslast frei oder verwirft sie
--   rpc_list_team_members   listet die Personen des Teams
--   rpc_shred_person        loescht eine Person (Crypto Shredding, Art. 17 DSGVO)
-- Sechs fassen Gesundheitsdaten an, eine loescht einen Menschen aus dem System.
--
-- Warum der Entzug heute nichts kostet: kein Client ruft eine der acht. Grep ueber
-- Web app/, lib/, components/, scripts/ und Player src/ am 2026-09-22: nur ein
-- Kommentar in scripts/shred-auth-user.mjs nennt einen dieser Namen.
--
-- -----------------------------------------------------------------------------
-- Die Festlegung, die daran haengt (Entscheidung von Chris)
-- -----------------------------------------------------------------------------
-- Die sechs bestehenden Tueren in public sind SECURITY INVOKER. Sie laufen nur,
-- weil authenticated das EXECUTE auf der app Funktion dahinter hat. Gemessen im
-- Wegwerf-Klon: nimmt man app.rpc_my_body_map_figure() das EXECUTE, bricht die
-- Tuer public.rpc_my_body_map_figure() im eigenen Rumpf ab
--   ERROR: permission denied for function rpc_my_body_map_figure
--   KONTEXT: PL/pgSQL function public.rpc_my_body_map_figure() line 5 at assignment
--
-- Chris hat gewaehlt: Entzug jetzt, Recht beim Tuerbau einzeln zurueck. Bekommt
-- eine der acht in AP-47a eine Tuer, steht das GRANT EXECUTE fuer genau diese eine
-- Funktion in derselben Migration wie die Tuer. Das Invoker-Muster von Muster D
-- bleibt damit unangetastet und der Waechter sitzt weiter genau einmal, im Rumpf
-- der app Funktion. Der nicht gewaehlte Weg waere gewesen, kuenftige Tueren als
-- SECURITY DEFINER zu bauen: das haette die Tuer zu einem zweiten privilegierten
-- Pfad neben der ohnehin schon als DEFINER laufenden app Funktion gemacht, also
-- genau das Muster, das Befund N9 als Loch mit Tuerschild gezeigt hat.
--
-- ACHTUNG fuer AP-47a: eine der acht bekommt ihre Tuer NICHT, ohne dass in
-- derselben Migration steht
--   GRANT EXECUTE ON FUNCTION app.<name>(<signatur>) TO authenticated;
-- Sonst antwortet die neue Tuer mit 42501 aus ihrem eigenen Rumpf, und der Fehler
-- sieht aus wie ein Rechteproblem des Aufrufers. Zusaetzlich gilt Muster D, letzter
-- Absatz: die acht behalten heute ihr log_denial plus RAISE, ihre Ablehnung wird
-- also zurueckgerollt. Wer eine Tuer baut, baut sie auf "Antwort statt Ausnahme" um.
--
-- -----------------------------------------------------------------------------
-- Bestandswahrung, VOR dem Entzug gemessen (Lessons Learned AP-39b)
-- -----------------------------------------------------------------------------
-- Ein REVOKE materialisiert die ACL, die es leeren will: eine Funktion ohne eigenen
-- Eintrag (proacl IS NULL) gibt EXECUTE an PUBLIC, und authenticated erbt es dort.
-- Deshalb zuerst gelesen, dann entzogen. Cloud am 2026-09-22, alle acht identisch:
--   proacl IS NOT NULL, Inhalt "postgres=X/postgres | authenticated=X/postgres"
--   has_function_privilege: authenticated true, anon false, PUBLIC kein Eintrag
-- Die ACL ist also bereits materialisiert, ein REVOKE kann hier keine Default ACL
-- festschreiben. Entzogen wird genau ein Recht je Funktion, das von authenticated.
-- postgres behaelt seines als Eigentuemer. anon hatte nie eines (Migration
-- 20260921000024, AP-39b).
--
-- Voraussetzung: 09_rpcs.sql (definiert alle acht), 14_shred_person.sql
-- (rpc_shred_person in ihrer heutigen Fassung). Idempotent.
-- =============================================================================

REVOKE EXECUTE ON FUNCTION app.rpc_list_team_members()                                                              FROM authenticated;
REVOKE EXECUTE ON FUNCTION app.rpc_check_ins_medical(date, date)                                                    FROM authenticated;
REVOKE EXECUTE ON FUNCTION app.rpc_readiness_full(uuid, date, date)                                                 FROM authenticated;
REVOKE EXECUTE ON FUNCTION app.rpc_release_deviation(uuid, text)                                                    FROM authenticated;
REVOKE EXECUTE ON FUNCTION app.rpc_get_clearance(uuid)                                                              FROM authenticated;
REVOKE EXECUTE ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date)                         FROM authenticated;
REVOKE EXECUTE ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text)                                 FROM authenticated;
REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid)                                                               FROM authenticated;

COMMENT ON FUNCTION app.rpc_list_team_members() IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Wer eine Tuer baut, gibt das Recht in derselben Migration zurueck (die Tuer ist INVOKER).';
COMMENT ON FUNCTION app.rpc_check_ins_medical(date, date) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Wer eine Tuer baut, gibt das Recht in derselben Migration zurueck und baut die Ablehnung '
  'auf Antwort statt Ausnahme um (Muster D). Befund F2 gehoert in dasselbe Paket.';
COMMENT ON FUNCTION app.rpc_readiness_full(uuid, date, date) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Befund N3 (Teampruefung vor dem Protokoll-INSERT) gehoert vor jede Tuer auf diese Funktion.';
COMMENT ON FUNCTION app.rpc_release_deviation(uuid, text) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer.';
COMMENT ON FUNCTION app.rpc_get_clearance(uuid) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Befunde N2 (admin im Waechter) und N3 (Teampruefung) gehoeren vor jede Tuer auf diese Funktion.';
COMMENT ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Befund N4 (Freigabe fuer eine teamfremde Person) gehoert vor jede Tuer auf diese Funktion.';
COMMENT ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Befund N8 (schreibt ohne Protokollzeile) gehoert vor jede Tuer auf diese Funktion.';
-- rpc_shred_person traegt als einzige der acht schon einen Kommentar (AP-39b). Er
-- wird angehaengt, nicht ersetzt: er nennt den zweiten Schritt ueber die Admin API,
-- und den findet sonst niemand wieder.
COMMENT ON FUNCTION app.rpc_shred_person(uuid) IS
  'Art. 17 DSGVO. Loescht alle Spuren einer Person in app.*, anonymisiert die Personenzeile '
  'und leert den Inhalt der zugehoerigen audit_log Zeilen, ohne deren Metadaten aufzugeben. '
  'Gibt die alte auth_user_id zurueck, damit das Auth Konto im zweiten Schritt ueber die '
  'Admin API geloescht werden kann (scripts/shred-auth-user.mjs). AP-39b. '
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer.';
