-- =============================================================================
-- 50_shred_person_role_history.pgtap.sql — Gegenprobe zu Punkt 90, 97, 98
-- PLUS B1, B2, H2, M1, N1, H-NEU (siehe Kopfkommentar von
-- backend/50_shred_person_role_history.sql fuer die vollstaendige Historie).
--
-- Punkt 98: nach rpc_shred_person ist app.persons.created_at auf den
-- Monatsersten gerundet (date_trunc('month', ..., 'UTC')), statt wie zuvor
-- unveraendert stehenzubleiben.
-- Punkt 90: eine offene role_assignments-Zeile (valid_to IS NULL) der
-- geschredderten Person wird geschlossen.
-- Punkt 97: valid_from und ein gesetztes valid_to aller role_assignments-
-- Zeilen dieser Person werden auf Monatsgenauigkeit gerundet -- inklusive des
-- Randfalls, dass eine sehr kurze, historische Zuweisung innerhalb desselben
-- Kalendermonats liegt.
-- B1: zwei Zuweisungen derselben Person, die sich ueber eine Monatsgrenze
-- hinweg beruehren (Gegenbeispiel aus dem Security-Review: Zeile A 1.3.-15.3.,
-- Zeile B 15.3.-20.4.) sowie drei dicht aufeinanderfolgende Zuweisungen im
-- selben Kalendermonat duerfen nach der Rundung weder die Constraint
-- role_assignments_one_active_role verletzen noch sich ueberlappen (direkter
-- tstzrange-Vergleich). Person P1 (offene + historische Zuweisung, A/B unten)
-- ist der Normalfall, der frueher (vor der deferred Constraint) eine eigene
-- Verschiebe-Reihenfolge brauchte -- jetzt genuegt die chronologische
-- Verkettung plus SET CONSTRAINTS ... DEFERRED.
-- B2: role_assignments.created_at wird ebenfalls auf Monatsgenauigkeit
-- gerundet.
-- H2: eine Zuweisung mit bereits gesetztem, aber noch zukuenftigem valid_to
-- wird beim Schreddern vorzeitig geschlossen (nicht erst beim natuerlichen
-- Ablauf in der Zukunft).
-- H-NEU: eine urspruenglich VOLLSTAENDIG ZUKUENFTIGE Zuweisung (P5) UND eine
-- urspruenglich im LAUFENDEN MONAT begonnene Zuweisung (P6) werden beim
-- Schreddern vollstaendig entfernt, nicht nur gerundet -- sonst erschiene die
-- geschredderte Person in role_assignments wieder/neu als aktuell oder
-- demnaechst aktiv.
-- B-4: eine Zuweisung mit valid_to = 'infinity' (P7) PLUS eine historische
-- Zuweisung derselben Person muss nach dem Shred einfach funktionieren --
-- ohne jede Sonderbehandlung, weil die Constraint deferred ist und H2 ueber
-- valid_to > v_now automatisch greift.
-- Zusaetzlich: Idempotenz -- ein zweiter Aufruf von rpc_shred_person fuer
-- dieselbe Person aendert weder created_at noch irgendeine
-- role_assignments-Zeile ein zweites Mal.
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(28);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c5000000-0000-0000-0000-000000000001','Team C50','Europe/Berlin');

-- Punkt 98: created_at bewusst nah an einem konkreten (fiktiven)
-- Transferdatum -- ohne den Fix bliebe es exakt stehen, mit Fix rundet es auf
-- den Monatsersten.
INSERT INTO app.persons (id, team_id, display_name, auth_user_id, is_active, created_at) VALUES
  ('c5000000-0000-0000-0000-000000000005','c5000000-0000-0000-0000-000000000001','Admin C50','c5000000-0000-0000-0000-000000000005',true, now() - interval '400 days'),
  ('c5000000-0000-0000-0000-000000000011','c5000000-0000-0000-0000-000000000001','P1 Wintertransfer',NULL,true, '2026-01-15 14:37:00+01'::timestamptz),
  ('c5000000-0000-0000-0000-000000000061','c5000000-0000-0000-0000-000000000001','P2 Nahtloser Wechsel',NULL,true, now() - interval '600 days'),
  ('c5000000-0000-0000-0000-000000000081','c5000000-0000-0000-0000-000000000001','P3 Dichte Zuweisungen',NULL,true, now() - interval '600 days'),
  ('c5000000-0000-0000-0000-000000000101','c5000000-0000-0000-0000-000000000001','P4 Zukunftsende',NULL,true, now() - interval '600 days'),
  -- H-NEU: P5 hat eine historische (vergangene, geschlossene) Zuweisung UND
  -- eine vollstaendig ZUKUENFTIGE, noch nicht begonnene Zuweisung.
  ('c5000000-0000-0000-0000-000000000121','c5000000-0000-0000-0000-000000000001','P5 Zukunftsbeginn',NULL,true, now() - interval '600 days'),
  -- H-NEU: P6 hat ausschliesslich eine Zuweisung, die im LAUFENDEN
  -- Kalendermonat (nicht erst in der Zukunft) begonnen hat.
  ('c5000000-0000-0000-0000-000000000141','c5000000-0000-0000-0000-000000000001','P6 Laufender Monat',NULL,true, now() - interval '600 days'),
  -- B-4: P7 hat eine historische (geschlossene) Zuweisung PLUS eine Zuweisung
  -- mit valid_to = 'infinity' -- muss ohne jede Sonderbehandlung funktionieren.
  ('c5000000-0000-0000-0000-000000000161','c5000000-0000-0000-0000-000000000001','P7 Infinity',NULL,true, now() - interval '600 days');

INSERT INTO app.role_assignments (id, team_id, person_id, role, valid_from, valid_to, created_at) VALUES
  ('c5000000-0000-0000-0000-000000000021','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000005','admin', now() - interval '400 days', NULL, now() - interval '400 days'),
  -- A: historische, bereits geschlossene Zuweisung, VOLLSTAENDIG innerhalb
  -- desselben Kalendermonats (Januar 2026) -- der Randfall aus Punkt 97, der
  -- ohne die Anhebe-Logik die Tabellen-Constraint verletzen wuerde.
  ('c5000000-0000-0000-0000-000000000031','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000011','player', '2026-01-05 10:00:00+01'::timestamptz, '2026-01-20 10:00:00+01'::timestamptz, '2026-01-05 10:00:00+01'::timestamptz),
  -- B: die AKTUELL offene Zuweisung, beginnt Monate spaeter (kein Overlap mit A).
  ('c5000000-0000-0000-0000-000000000032','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000011','physio', '2026-06-10 08:00:00+02'::timestamptz, NULL, '2026-06-10 08:00:00+02'::timestamptz),
  -- B1-Gegenbeispiel aus dem Security-Review: C1 endet exakt dort, wo C2
  -- beginnt, mitten im Maerz -- unabhaengiges Runden wuerde beide auf
  -- ueberlappende Zeitraeume werfen.
  ('c5000000-0000-0000-0000-000000000071','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000061','player', '2026-03-01 10:00:00+01'::timestamptz, '2026-03-15 10:00:00+01'::timestamptz, '2026-03-01 09:00:00+01'::timestamptz),
  ('c5000000-0000-0000-0000-000000000072','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000061','coach',  '2026-03-15 10:00:00+01'::timestamptz, '2026-04-20 10:00:00+01'::timestamptz, '2026-03-15 10:00:00+01'::timestamptz),
  -- B1 Randfall (b): drei dicht aufeinanderfolgende Zuweisungen, alle
  -- vollstaendig im selben Kalendermonat (Maerz).
  ('c5000000-0000-0000-0000-000000000091','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000081','player',        '2026-03-01 00:00:00+01'::timestamptz, '2026-03-10 00:00:00+01'::timestamptz, '2026-03-01 00:00:00+01'::timestamptz),
  ('c5000000-0000-0000-0000-000000000092','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000081','coach',         '2026-03-10 00:00:00+01'::timestamptz, '2026-03-20 00:00:00+01'::timestamptz, '2026-03-10 00:00:00+01'::timestamptz),
  ('c5000000-0000-0000-0000-000000000093','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000081','athletic_coach', '2026-03-20 00:00:00+01'::timestamptz, '2026-03-31 00:00:00+01'::timestamptz, '2026-03-20 00:00:00+01'::timestamptz),
  -- H2: valid_to ist bereits gesetzt, liegt aber noch in der Zukunft -- muss
  -- beim Schreddern trotzdem vorzeitig geschlossen werden.
  ('c5000000-0000-0000-0000-000000000111','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000101','doctor', now() - interval '400 days', now() + interval '2 months', now() - interval '400 days'),
  -- H-NEU, P5: F1 historisch, vollstaendig vergangen und bereits geschlossen
  -- (bleibt nach dem Shred bestehen, nur gerundet).
  ('c5000000-0000-0000-0000-000000000131','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000121','player', now() - interval '200 days', now() - interval '190 days', now() - interval '200 days'),
  -- H-NEU, P5: F2 vollstaendig zukuenftig, noch offen (valid_from > now()) --
  -- ohne den H-NEU-Fix wuerde H2 (valid_to IS NULL) sie schliessen und auf
  -- einen (noch) zukuenftigen Monatsanfang runden, die Person erschiene dann
  -- im Januar 2027 wieder/neu als aktiv. Muss nach dem Shred vollstaendig weg
  -- sein.
  ('c5000000-0000-0000-0000-000000000132','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000121','coach', now() + interval '3 months', NULL, now() + interval '3 months'),
  -- H-NEU, P6: G1 beginnt im LAUFENDEN Kalendermonat (5 Tage nach dem
  -- Monatsanfang von now()), noch offen. Ohne den H-NEU-Fix bliebe diese
  -- Zuweisung nach der reinen Monatsrundung exakt im aktuell laufenden Monat
  -- aktiv -- die Person erschiene direkt nach dem Shred wieder als aktiv.
  ('c5000000-0000-0000-0000-000000000151','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000141','player', date_trunc('month', now(), 'UTC') + interval '5 days', NULL, date_trunc('month', now(), 'UTC') + interval '5 days'),
  -- B-4, P7: J1 historisch, vollstaendig vergangen und bereits geschlossen
  -- (bleibt nach dem Shred bestehen, nur gerundet).
  ('c5000000-0000-0000-0000-000000000171','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000161','player', now() - interval '400 days', now() - interval '390 days', now() - interval '400 days'),
  -- B-4, P7: J2 beginnt danach und ist explizit mit valid_to = 'infinity'
  -- gesetzt (statt NULL) -- fuer die alte Platzhalter-Technik verhielt sich
  -- das identisch zu NULL und brauchte dieselbe Sonderbehandlung; H2 schliesst
  -- sie jetzt einfach ueber dieselbe Bedingung (valid_to > v_now) wie jede
  -- andere noch nicht abgelaufene Zuweisung.
  ('c5000000-0000-0000-0000-000000000172','c5000000-0000-0000-0000-000000000001','c5000000-0000-0000-0000-000000000161','coach', now() - interval '380 days', 'infinity'::timestamptz, now() - interval '380 days');

CREATE OR REPLACE FUNCTION app._t50_jwt(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', 'c5000000-0000-0000-0000-000000000001')::text, true);
$$;

SELECT app._t50_jwt('c5000000-0000-0000-0000-000000000005', 'admin');

-- Shred ausfuehren (P1 bis P6 in einem Block -- alle sechs sind unabhaengige
-- Personen desselben Teams, die Reihenfolge spielt fuer die Pruefungen unten
-- keine Rolle). P1 ist zugleich der DRITTER-DURCHLAUF-BLOCKER-Fall: ohne den
-- Phase-1-Reihenfolge-Fix bricht genau dieser Aufruf mit ERROR 23P01 ab.
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000011'::uuid);
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000061'::uuid);
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000081'::uuid);
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000101'::uuid);
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000121'::uuid);
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000141'::uuid);
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000161'::uuid);

-- -----------------------------------------------------------------------------
-- Punkt 98: created_at ist auf den Monatsersten (UTC, M1-Fix) gerundet.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT created_at FROM app.persons WHERE id = 'c5000000-0000-0000-0000-000000000011'),
  date_trunc('month', '2026-01-15 14:37:00+01'::timestamptz, 'UTC'),
  'Punkt 98: created_at ist nach dem Shred auf den Monatsersten gerundet'
);

-- -----------------------------------------------------------------------------
-- Punkt 90: die offene Zuweisung (B, valid_to war NULL) ist geschlossen.
-- -----------------------------------------------------------------------------

SELECT ok(
  (SELECT valid_to FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000032') IS NOT NULL,
  'Punkt 90: die vormals offene role_assignments-Zeile (valid_to war NULL) ist nach dem Shred geschlossen'
);

-- -----------------------------------------------------------------------------
-- Punkt 97: valid_from/valid_to sind auf Monatsgenauigkeit gerundet (UTC).
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT valid_from FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000032'),
  date_trunc('month', '2026-06-10 08:00:00+02'::timestamptz, 'UTC'),
  'Punkt 97: valid_from der (vormals offenen) Zeile B ist auf Monatsgenauigkeit gerundet'
);

SELECT ok(
  (SELECT valid_to = date_trunc('month', valid_to, 'UTC') FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000032'),
  'Punkt 97: valid_to der (jetzt geschlossenen) Zeile B ist selbst ein exakter Monats-Grenzwert'
);

SELECT ok(
  (SELECT valid_to > valid_from FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000032'),
  'Kontrolle: Zeile B verletzt nach der Rundung nicht role_assignments_valid_range (valid_to > valid_from)'
);

SELECT is(
  (SELECT valid_from FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000031'),
  date_trunc('month', '2026-01-05 10:00:00+01'::timestamptz, 'UTC'),
  'Punkt 97: valid_from der historischen Zeile A ist auf Monatsgenauigkeit gerundet'
);

-- Randfall (Kopfkommentar backend/50_shred_person_role_history.sql): A liegt
-- vollstaendig im Januar 2026 -- reines Abrunden wuerde valid_to = valid_from
-- erzeugen. Die Funktion hebt valid_to stattdessen auf den naechsten
-- Monatsanfang an.
SELECT is(
  (SELECT valid_to FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000031'),
  date_trunc('month', '2026-01-05 10:00:00+01'::timestamptz, 'UTC') + interval '1 month',
  'Punkt 97 Randfall: valid_to der historischen Zeile A (selber Monat wie valid_from) wird auf den '
  'naechsten Monatsanfang angehoben statt gleich valid_from zu werden'
);

SELECT ok(
  (SELECT valid_to > valid_from FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000031'),
  'Kontrolle: Zeile A verletzt nach der Rundung/Anhebung nicht role_assignments_valid_range'
);

-- -----------------------------------------------------------------------------
-- B1 (Blocker): C1/C2 beruehren sich exakt an einer Monatsgrenze mitten im
-- Maerz. Unabhaengiges Runden wuerfe beide auf denselben/ueberlappende
-- Zeitraeume -- hier muss das Ergebnis nachweislich ueberlappungsfrei sein.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT valid_to FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000071'),
  (SELECT valid_from FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000072'),
  'B1: C1.valid_to und C2.valid_from treffen sich exakt (konstruktionsbedingt ueberlappungsfrei)'
);

SELECT ok(
  NOT (
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000071')
    &&
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000072')
  ),
  'B1: C1 und C2 ueberlappen sich nach der Rundung nachweislich nicht (tstzrange)'
);

-- B2: role_assignments.created_at von C1 ist ebenfalls auf Monatsgenauigkeit
-- gerundet.
SELECT is(
  (SELECT created_at FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000071'),
  date_trunc('month', '2026-03-01 09:00:00+01'::timestamptz, 'UTC'),
  'B2: role_assignments.created_at von C1 ist nach dem Shred auf den Monatsersten gerundet'
);

-- -----------------------------------------------------------------------------
-- B1 Randfall (b): drei dicht aufeinanderfolgende Zuweisungen (D1/D2/D3),
-- alle vollstaendig im selben Kalendermonat -- jedes Paar muss nachweislich
-- ueberlappungsfrei sein.
-- -----------------------------------------------------------------------------

SELECT ok(
  NOT (
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000091')
    &&
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000092')
  ),
  'B1 Randfall: D1 und D2 ueberlappen sich nach der Rundung nachweislich nicht'
);

SELECT ok(
  NOT (
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000092')
    &&
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000093')
  ),
  'B1 Randfall: D2 und D3 ueberlappen sich nach der Rundung nachweislich nicht'
);

SELECT ok(
  NOT (
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000091')
    &&
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000093')
  ),
  'B1 Randfall: D1 und D3 ueberlappen sich nach der Rundung nachweislich nicht'
);

-- -----------------------------------------------------------------------------
-- H2: die Zuweisung mit bereits gesetztem, aber noch zukuenftigem valid_to
-- (E1) wird vorzeitig geschlossen, nicht erst beim natuerlichen Ablauf.
-- now() ist innerhalb derselben Transaktion identisch zum v_now der Funktion.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT valid_to FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000111'),
  date_trunc('month', now(), 'UTC'),
  'H2: E1 (valid_to war in der Zukunft gesetzt) ist auf den aktuellen Monatsanfang geschlossen'
);

SELECT isnt(
  (SELECT valid_to FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000111'),
  date_trunc('month', now() + interval '2 months', 'UTC'),
  'H2 Kontrolle: E1 wurde NICHT einfach auf den urspruenglichen (zukuenftigen) Monat gerundet'
);

SELECT ok(
  (SELECT valid_to > valid_from FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000111'),
  'Kontrolle: E1 verletzt nach dem Schliessen/Runden nicht role_assignments_valid_range'
);

-- -----------------------------------------------------------------------------
-- P1 (offene + historische Zuweisung, der Normalfall): A und B ueberlappen
-- sich nach dem Schreddern nachweislich nicht.
-- -----------------------------------------------------------------------------

SELECT ok(
  NOT (
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000031')
    &&
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000032')
  ),
  'P1: A (historisch) und B (vormals offen) derselben Person ueberlappen sich nicht'
);

-- -----------------------------------------------------------------------------
-- H-NEU: P5 hat eine historische Zeile (F1, bleibt erhalten) und eine
-- urspruenglich vollstaendig zukuenftige Zeile (F2, muss nach dem Shred
-- vollstaendig verschwunden sein).
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000132'),
  0,
  'H-NEU: F2 (P5, urspruenglich vollstaendig zukuenftig) ist nach dem Shred vollstaendig geloescht'
);

SELECT is(
  (SELECT count(*)::int FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000131'),
  1,
  'H-NEU Kontrolle: F1 (P5, historisch) bleibt nach dem Shred erhalten -- nur F2 wird entfernt'
);

-- -----------------------------------------------------------------------------
-- H-NEU: P6 hat ausschliesslich eine Zeile, die im laufenden Kalendermonat
-- begann (G1) -- muss nach dem Shred vollstaendig verschwunden sein, nicht
-- nur gerundet.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000151'),
  0,
  'H-NEU: G1 (P6, Beginn im laufenden Monat) ist nach dem Shred vollstaendig geloescht'
);

-- -----------------------------------------------------------------------------
-- B-4: P7 hat eine historische Zeile (J1, bleibt erhalten) und eine Zeile mit
-- valid_to = 'infinity' (J2, muss wie jede andere offene Zeile geschlossen und
-- gerundet werden -- ohne jede Sonderbehandlung, weil die Constraint deferred
-- ist).
-- -----------------------------------------------------------------------------

SELECT ok(
  (SELECT valid_to FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000172') IS NOT NULL
  AND (SELECT valid_to FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000172') <> 'infinity'::timestamptz,
  'B-4: J2 (valid_to war ''infinity'') ist nach dem Shred geschlossen und nicht mehr unbeschraenkt'
);

SELECT is(
  (SELECT count(*)::int FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000171'),
  1,
  'B-4 Kontrolle: J1 (P7, historisch) bleibt nach dem Shred erhalten'
);

SELECT ok(
  NOT (
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000171')
    &&
    (SELECT tstzrange(valid_from, valid_to) FROM app.role_assignments WHERE id = 'c5000000-0000-0000-0000-000000000172')
  ),
  'B-4: J1 und J2 ueberlappen sich nach der Rundung nachweislich nicht'
);

-- -----------------------------------------------------------------------------
-- H-NEU Generalprobe: ueber ALLE in diesem Test geschredderten Personen
-- (P1-P7) hinweg enthaelt KEINE verbleibende role_assignments-Zeile now(),
-- und KEINE liegt vollstaendig in der Zukunft -- exakt die vom zweiten
-- Review-Agenten verlangte Garantie fuer Punkt 90.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int
     FROM app.role_assignments
    WHERE person_id IN (
            'c5000000-0000-0000-0000-000000000011',
            'c5000000-0000-0000-0000-000000000061',
            'c5000000-0000-0000-0000-000000000081',
            'c5000000-0000-0000-0000-000000000101',
            'c5000000-0000-0000-0000-000000000121',
            'c5000000-0000-0000-0000-000000000141',
            'c5000000-0000-0000-0000-000000000161'
          )
      AND (valid_to > now() OR valid_from > now())),
  0,
  'H-NEU Generalprobe: keine verbleibende role_assignments-Zeile einer geschredderten Person (P1-P7) hat valid_to > now() oder valid_from > now()'
);

-- -----------------------------------------------------------------------------
-- Idempotenz: zweiter Aufruf von rpc_shred_person aendert nichts mehr an
-- role_assignments oder created_at (hier exemplarisch an P1 und P2 geprueft).
-- -----------------------------------------------------------------------------

CREATE TEMP TABLE t50_snapshot AS
  SELECT id, valid_from, valid_to, created_at FROM app.role_assignments
   WHERE person_id IN ('c5000000-0000-0000-0000-000000000011', 'c5000000-0000-0000-0000-000000000061');

SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000011'::uuid);
SELECT app.rpc_shred_person('c5000000-0000-0000-0000-000000000061'::uuid);

SELECT is(
  (SELECT count(*)::int FROM app.role_assignments ra
     JOIN t50_snapshot s ON s.id = ra.id
    WHERE ra.valid_from IS DISTINCT FROM s.valid_from
       OR ra.valid_to IS DISTINCT FROM s.valid_to
       OR ra.created_at IS DISTINCT FROM s.created_at),
  0,
  'Idempotenz: ein zweiter Shred-Aufruf aendert keine role_assignments-Zeile (P1/P2) mehr'
);

SELECT is(
  (SELECT created_at FROM app.persons WHERE id = 'c5000000-0000-0000-0000-000000000011'),
  date_trunc('month', '2026-01-15 14:37:00+01'::timestamptz, 'UTC'),
  'Idempotenz: ein zweiter Shred-Aufruf aendert created_at (P1) nicht mehr'
);

-- -----------------------------------------------------------------------------
-- M1 (Security-Review, Testluecke): die bisherigen Tests oben pruefen nur die
-- berechneten Werte (tstzrange-Vergleich), nicht ob Postgres selbst ueber die
-- deferred Constraint role_assignments_one_active_role keine Verletzung
-- findet -- ROLLBACK am Ende dieser Datei prueft deferred Constraints
-- NICHT, ein reiner ROLLBACK-basierter Testlauf uebte die Constraint also nie
-- tatsaechlich aus. SET CONSTRAINTS ... IMMEDIATE zwingt Postgres, jetzt
-- sofort zu pruefen, waehrend die Testtransaktion noch offen ist.
-- -----------------------------------------------------------------------------

SELECT lives_ok(
  $$SET CONSTRAINTS app.role_assignments_one_active_role IMMEDIATE$$,
  'deferred Constraint ist nach allen Shreds tatsaechlich erfuellt'
);

SELECT * FROM finish();
ROLLBACK;
