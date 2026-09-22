-- =============================================================================
-- 29_clearance_admin_adr018.sql — ADR-018 angenommen, der admin Zweig ist jetzt
-- begruendet (Punkt 53, Befund N2)
--
-- KEINE Verhaltensaenderung. Diese Migration aendert genau einen COMMENT.
--
-- Befund N2 der Gegenlesung mit Opus: der Waechter von app.rpc_get_clearance laesst
-- app.auth_has_role('admin') durch, die Rollenmatrix setzte dort ein '-'. Zwei Wege
-- standen zur Wahl: admin aus dem Waechter nehmen, oder die Matrix aendern. Der
-- zweite braucht nach der harten Regel von Modul-Rollen-Medizin-Gate Abschnitt 5
-- ein neues ADR.
--
-- Chris hat am 2026-09-22 den zweiten Weg gewaehlt UND begruendet:
--
--   "admin ist admin, der kann alles sehen, muss er. Es kann weiter admin Rollen
--    geben, die vielleicht nicht alles sehen duerfen."
--
-- Dazu drei konkrete Zwecke: Kaderplanung und Aufstellung, Meldung an Verband oder
-- Versicherung, Vertretung wenn kein Arzt erreichbar ist. Umfang: Status UND
-- Freitext (load_note).
--
-- Der zweite Satz ist die Einschraenkung und gehoert in jeden kuenftigen Bau:
-- entschieden ist die Rolle `admin`, wie sie heute existiert. Eine spaeter
-- eingefuehrte, eingeschraenkte Verwaltungsrolle erbt dieses Recht NICHT, sie
-- braucht ihre eigene Zeile in der Matrix und ihre eigene Entscheidung. Nach
-- ADR-015 traegt eine Person genau eine Rolle, eine neue Rolle waere also ein
-- neuer Wert in app.app_role und damit ohnehin ein eigener Vorgang.
--
-- Die Matrix in Modul Abschnitt 5 ist entsprechend geaendert: Zeile
-- `medical_clearances.status` + `load_note`, Spalte admin, '-' auf 'R'. Genau eine
-- Zelle. Die Zeile "`medical_clearances` setzen" bleibt fuer admin bei '-',
-- app.rpc_set_clearance verlangt unveraendert doctor und app.rpc_propose_clearance
-- unveraendert physio.
--
-- Voraussetzung: 27_clearance_team_guard.sql (setzt den Kommentar, den diese Datei
-- ersetzt). Idempotent.
-- =============================================================================

COMMENT ON FUNCTION app.rpc_get_clearance(uuid) IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated. Keine Tuer in public, kein Aufrufer. '
  'Wer eine Tuer baut, gibt das Recht in derselben Migration zurueck und baut die Ablehnung '
  'auf Antwort statt Ausnahme um (Muster D). '
  'Punkt 52 (2026-09-22): Befund N3 behoben, die Teampruefung steht vor dem Protokoll-INSERT. '
  'Punkt 53 (2026-09-22): Befund N2 geschlossen. Der admin Zweig ist KEIN Versehen, er ist per '
  'ADR-018 entschieden und begruendet (Kaderplanung, Verbandsmeldung, Vertretung ohne Arzt), '
  'Umfang Status UND load_note. Die Matrix fuehrt admin seither mit R. '
  'GRENZE: entschieden ist die Rolle admin, wie sie heute existiert. Eine spaeter eingefuehrte, '
  'eingeschraenkte Verwaltungsrolle erbt dieses Recht NICHT und braucht eine eigene Entscheidung.';
