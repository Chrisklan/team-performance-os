-- =============================================================================
-- 14_shred_person.pgtap.sql — Tests fuer app.rpc_shred_person v2 (AP-39b)
--
-- Die Suite prueft die vier Eigenschaften, an denen der Loeschpfad scheitern
-- kann, ohne dass es jemand merkt:
--   1. Er raeumt zu wenig. Nach dem Shred steht der Anzeigename oder das
--      Geburtsdatum noch irgendwo im audit_log.
--   2. Er raeumt zu viel. Audit Zeilen verschwinden, und mit ihnen der Nachweis
--      nach Art. 5 Abs. 2, oder er greift Zeilen an, die einer anderen Person
--      gehoeren (Verweise auf Handelnde).
--   3. Er laeuft gegen sich selbst. Die DELETEs erzeugen ueber den Audit Trigger
--      neue Kopien, die der Pfad nicht mehr erfasst.
--   4. Auskunft und Loeschung laufen auseinander. rpc_export_my_data nennt einen
--      Speicherort, den der Shred nicht kennt.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 14_shred_person.sql.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;

SELECT no_plan();

-- =============================================================================
-- FIXTURES
--
-- Zwei Faelle in einer Suite:
--   Spielerin P wird geschreddert. Sie ist BETROFFENE, ihre Daten gehen.
--   Aerztin D wird danach geschreddert. Sie ist in den Freigaben von Q nur
--   HANDELNDE (set_by), diese Zeilen muessen unveraendert bleiben.
-- =============================================================================

INSERT INTO app.teams (id, name, timezone) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'Shred Test Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, birth_date) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'Admin Shredtest',   'admin',  'e2000000-0000-0000-0000-000000000001', NULL),
  ('e1000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'Aerztin Shredtest', 'doctor', 'e2000000-0000-0000-0000-000000000002', NULL),
  ('e1000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'Coach Shredtest',   'coach',  'e2000000-0000-0000-0000-000000000003', NULL),
  -- P, die geschredderte Person. Name und Geburtsdatum sind bewusst markant,
  -- damit eine Volltextsuche im audit_log sie eindeutig findet.
  ('e1000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001', 'Paula Loeschpfad',  'player', 'e2000000-0000-0000-0000-000000000004', '1999-03-17'),
  -- Q bleibt stehen und dient als Kontrolle.
  ('e1000000-0000-0000-0000-000000000005', 'e0000000-0000-0000-0000-000000000001', 'Quentin Bleibt',    'player', 'e2000000-0000-0000-0000-000000000005', '2001-07-02');

INSERT INTO app.role_assignments (team_id, person_id, role) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'admin'),
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000002', 'doctor'),
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000003', 'coach'),
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000004', 'player'),
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000005', 'player');

-- Nutzdaten von P, in allen Speicherorten, die rpc_export_my_data nennt.
INSERT INTO app.daily_checkins (team_id, person_id, date, body_map, pain_max, sleep_quality) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000004', '2026-09-01', '[{"region":"knee_left","pain":4}]'::jsonb, 4, 6),
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000004', '2026-09-02', '[{"region":"knee_left","pain":2}]'::jsonb, 2, 7);

INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000004', '2026-09-01', 71.5, 'moderate', '{"sleep": 6, "muscle": 4}'::jsonb);

INSERT INTO app.load_deviations (team_id, person_id, date, deviation, state) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000004', '2026-09-01', 18.25, 'unreviewed');

-- Freigabe FUER P, gesetzt VON D.
INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000004', 'limited', 'max 60 min', '2026-09-01', 'e1000000-0000-0000-0000-000000000002', 'doctor');

-- Freigabe FUER Q, ebenfalls gesetzt VON D. Diese Zeile gehoert inhaltlich Q und
-- muss den Shred von D unveraendert ueberstehen.
INSERT INTO app.medical_clearances (id, team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('e3000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000005', 'full', 'ohne Auflage', '2026-09-01', 'e1000000-0000-0000-0000-000000000002', 'doctor');

-- Zugriffsprotokoll. Zeile 1: P ist Betroffene, D Handelnde (geht beim Shred von P).
-- Zeile 2: Q ist Betroffene, D Handelnde (bleibt, auch beim Shred von D).
INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000004', 'e1000000-0000-0000-0000-000000000002', 'doctor', 'medical_clearances', 'read'),
  ('e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000005', 'e1000000-0000-0000-0000-000000000002', 'doctor', 'medical_clearances', 'read');


CREATE OR REPLACE FUNCTION app._t_shred_jwt(p_sub text, p_role text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', json_build_object(
    'sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
    'team_id', 'e0000000-0000-0000-0000-000000000001')::text, true);
$$;

-- Volltextsuche im audit_log. Sie ist der harte Test: sie fragt nicht, ob der
-- Pfad die erwarteten Zeilen getroffen hat, sondern ob irgendwo noch Klartext steht.
CREATE OR REPLACE FUNCTION app._t_audit_hits(p_needle text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM app.audit_log a
   WHERE coalesce(a.old_row::text, '') ILIKE '%' || p_needle || '%'
      OR coalesce(a.new_row::text, '') ILIKE '%' || p_needle || '%';
$$;


-- =============================================================================
-- 1. Ausgangslage: der Klartext ist wirklich da
--    Ohne diese Tests belegt ein spaeteres "0 Treffer" nichts.
-- =============================================================================

SELECT cmp_ok(app._t_audit_hits('Paula Loeschpfad'), '>', 0::bigint,
  'Ausgangslage: der Anzeigename von P steht im audit_log');
SELECT cmp_ok(app._t_audit_hits('1999-03-17'), '>', 0::bigint,
  'Ausgangslage: das Geburtsdatum von P steht im audit_log');
SELECT cmp_ok(app._t_audit_hits('knee_left'), '>', 0::bigint,
  'Ausgangslage: die Body Map von P steht im audit_log');
SELECT is((SELECT count(*) FROM app.daily_checkins WHERE person_id = 'e1000000-0000-0000-0000-000000000004'), 2::bigint,
  'Ausgangslage: P hat zwei Check-Ins');

CREATE TEMP TABLE _audit_before AS
  SELECT id, team_id, table_name, row_id, operation, actor_id, actor_role, occurred_at,
         (old_row IS NOT NULL) AS had_old, (new_row IS NOT NULL) AS had_new
    FROM app.audit_log;

CREATE TEMP TABLE _clearance_q_before AS
  SELECT * FROM app.medical_clearances WHERE id = 'e3000000-0000-0000-0000-000000000001';

CREATE TEMP TABLE _access_q_before AS
  SELECT * FROM app.access_log WHERE subject_id = 'e1000000-0000-0000-0000-000000000005';


-- =============================================================================
-- 2. Der Shred von P
-- =============================================================================

SELECT app._t_shred_jwt('e2000000-0000-0000-0000-000000000001', 'admin');

SELECT is(app.rpc_shred_person('e1000000-0000-0000-0000-000000000004'),
  'e2000000-0000-0000-0000-000000000004'::uuid,
  'Shred gibt die alte auth_user_id zurueck (Schritt 8, Admin API)');


-- -----------------------------------------------------------------------------
-- 2a. Nutzdaten sind weg
-- -----------------------------------------------------------------------------

SELECT is((SELECT count(*) FROM app.daily_checkins   WHERE person_id = 'e1000000-0000-0000-0000-000000000004'), 0::bigint, 'daily_checkins von P sind geloescht');
SELECT is((SELECT count(*) FROM app.readiness_scores WHERE person_id = 'e1000000-0000-0000-0000-000000000004'), 0::bigint, 'readiness_scores von P sind geloescht');
SELECT is((SELECT count(*) FROM app.load_deviations  WHERE person_id = 'e1000000-0000-0000-0000-000000000004'), 0::bigint, 'load_deviations von P sind geloescht');
SELECT is((SELECT count(*) FROM app.medical_clearances WHERE person_id = 'e1000000-0000-0000-0000-000000000004'), 0::bigint, 'medical_clearances von P sind geloescht (Entscheidung 1)');
SELECT is((SELECT count(*) FROM app.access_log WHERE subject_id = 'e1000000-0000-0000-0000-000000000004'), 0::bigint, 'access_log: Betroffenenzeilen von P sind geloescht (Entscheidung 2)');

SELECT is((SELECT display_name FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000004') LIKE 'SCRAPED-%', true, 'persons: Anzeigename ist pseudonymisiert');
SELECT is((SELECT auth_user_id FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000004'), NULL, 'persons: auth_user_id ist NULL');
SELECT is((SELECT birth_date   FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000004'), NULL, 'persons: Geburtsdatum ist NULL');
SELECT is((SELECT is_active    FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000004'), false, 'persons: Person ist inaktiv');
SELECT is((SELECT count(*) FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000004'), 1::bigint,
  'persons: die Zeile bleibt stehen, damit Verweise auf die Person als Handelnde weiter tragen');


-- -----------------------------------------------------------------------------
-- 2b. Der Kern des Pakets: im audit_log ist nichts mehr zu finden
--     Das schliesst die Kopien ein, die der Shred selbst gerade erzeugt hat.
-- -----------------------------------------------------------------------------

SELECT is(app._t_audit_hits('Paula Loeschpfad'), 0::bigint,
  'audit_log: Suche nach dem Anzeigenamen von P findet 0 Treffer');
SELECT is(app._t_audit_hits('1999-03-17'), 0::bigint,
  'audit_log: Suche nach dem Geburtsdatum von P findet 0 Treffer');
SELECT is(app._t_audit_hits('knee_left'), 0::bigint,
  'audit_log: Suche nach der Body Map von P findet 0 Treffer');
SELECT is(app._t_audit_hits('max 60 min'), 0::bigint,
  'audit_log: Suche nach dem Freitext der Freigabe von P findet 0 Treffer');
SELECT is(app._t_audit_hits('e1000000-0000-0000-0000-000000000004'), 0::bigint,
  'audit_log: die person_id von P steht in keinem old_row oder new_row mehr');


-- -----------------------------------------------------------------------------
-- 2c. Der Nachweis bleibt: Metadaten unveraendert, keine Zeile verschwunden
-- -----------------------------------------------------------------------------

SELECT is((SELECT count(*) FROM _audit_before b WHERE NOT EXISTS (SELECT 1 FROM app.audit_log a WHERE a.id = b.id)), 0::bigint,
  'audit_log: keine Zeile wurde geloescht (Art. 5 Abs. 2)');

SELECT is((SELECT count(*) FROM _audit_before b JOIN app.audit_log a ON a.id = b.id
            WHERE a.table_name  IS DISTINCT FROM b.table_name
               OR a.row_id      IS DISTINCT FROM b.row_id
               OR a.operation   IS DISTINCT FROM b.operation
               OR a.actor_id    IS DISTINCT FROM b.actor_id
               OR a.actor_role  IS DISTINCT FROM b.actor_role
               OR a.occurred_at IS DISTINCT FROM b.occurred_at), 0::bigint,
  'audit_log: table_name, row_id, operation, actor und Zeitpunkt sind unveraendert');

SELECT is((SELECT count(*) FROM _audit_before b JOIN app.audit_log a ON a.id = b.id
            WHERE (a.old_row IS NOT NULL) IS DISTINCT FROM b.had_old
               OR (a.new_row IS NOT NULL) IS DISTINCT FROM b.had_new), 0::bigint,
  'audit_log: geleert heisst ueberschrieben, nicht genullt. Aus old_row wird nie NULL');

-- Zwoelf Zeilen tragen Bezug zu P und sind jetzt geleert. Die Herleitung, damit
-- die Zahl nachvollziehbar bleibt und nicht nur passt:
--   6 aus dem Aufbau der Fixtures (1 persons, 2 daily_checkins, 1 readiness_scores,
--     1 load_deviations, 1 medical_clearances)
--   5 aus den DELETEs dieses Aufrufs, die der Trigger als Vollkopie geschrieben hat
--   1 aus dem UPDATE auf app.persons in Schritt 5
-- Genau diese fuenf plus eine sind der Grund, warum Schritt 6 zuletzt laeuft.
SELECT is((SELECT count(*) FROM app.audit_log
            WHERE (old_row ? 'shredded_at' OR new_row ? 'shredded_at')
              AND new_row ->> 'action' IS DISTINCT FROM 'crypto_shred'), 12::bigint,
  'audit_log: die zwoelf Zeilen mit Bezug zu P sind geleert, die sechs aus dem Shred selbst eingeschlossen');

SELECT is((SELECT count(*) FROM app.audit_log
            WHERE table_name = 'persons' AND row_id = 'e1000000-0000-0000-0000-000000000004'
              AND new_row ->> 'action' = 'crypto_shred'), 1::bigint,
  'audit_log: genau eine Abschlusszeile, und sie traegt keinen Inhalt');


-- -----------------------------------------------------------------------------
-- 2d. Gegenprobe: was NICHT angefasst werden durfte
-- -----------------------------------------------------------------------------

SELECT is((SELECT count(*) FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000005' AND display_name = 'Quentin Bleibt'), 1::bigint,
  'Kontrolle: Q ist unveraendert');
SELECT cmp_ok(app._t_audit_hits('Quentin Bleibt'), '>', 0::bigint,
  'Kontrolle: der Klartext von Q steht weiter im audit_log');
SELECT is((SELECT count(*) FROM app.medical_clearances WHERE person_id = 'e1000000-0000-0000-0000-000000000005'), 1::bigint,
  'Kontrolle: die Freigabe von Q ist unberuehrt');
SELECT is((SELECT count(*) FROM app.access_log WHERE subject_id = 'e1000000-0000-0000-0000-000000000005'), 1::bigint,
  'Kontrolle: die access_log Zeile von Q ist unberuehrt');


-- =============================================================================
-- 3. Idempotenz: der zweite Shred derselben Person
-- =============================================================================

CREATE TEMP TABLE _after_first AS SELECT count(*) AS n FROM app.audit_log;
CREATE TEMP TABLE _person_after_first AS SELECT * FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000004';

SELECT is(app.rpc_shred_person('e1000000-0000-0000-0000-000000000004'), NULL,
  'Zweiter Shred: kein Auth Konto mehr zu loeschen, Rueckgabe NULL');

SELECT is((SELECT n FROM _after_first) + 1, (SELECT count(*) FROM app.audit_log),
  'Zweiter Shred: das audit_log waechst nur um die Abschlusszeile');

SELECT is((SELECT count(*) FROM _person_after_first b JOIN app.persons p ON p.id = b.id
            WHERE p.display_name IS DISTINCT FROM b.display_name
               OR p.updated_at   IS DISTINCT FROM b.updated_at), 0::bigint,
  'Zweiter Shred: die Personenzeile wird nicht noch einmal angefasst');

SELECT is(app._t_audit_hits('Paula Loeschpfad'), 0::bigint,
  'Zweiter Shred: weiter 0 Treffer, der Pfad fuellt nicht nach');


-- =============================================================================
-- 4. Berechtigung
-- =============================================================================

SELECT app._t_shred_jwt('e2000000-0000-0000-0000-000000000003', 'coach');
SELECT throws_ok($$SELECT app.rpc_shred_person('e1000000-0000-0000-0000-000000000005')$$,
  '42501', 'FORBIDDEN: persons.shred (only admin)', 'Coach darf nicht shredden');

SELECT app._t_shred_jwt('e2000000-0000-0000-0000-000000000002', 'doctor');
SELECT throws_ok($$SELECT app.rpc_shred_person('e1000000-0000-0000-0000-000000000005')$$,
  '42501', 'FORBIDDEN: persons.shred (only admin)', 'Aerztin darf nicht shredden');

SELECT app._t_shred_jwt('e2000000-0000-0000-0000-000000000001', 'admin');
SELECT throws_ok($$SELECT app.rpc_shred_person('11111111-1111-1111-1111-111111111111')$$,
  'P0002', 'NOT_FOUND: persons.shred', 'Admin trifft keine Person ausserhalb des eigenen Teams');


-- =============================================================================
-- 5. Gegenprobe zu den Referenzformen (Korrektur vom 2026-09-21)
--
--    D wird geschreddert. In den Freigaben und im Zugriffsprotokoll von Q steht
--    sie nur als HANDELNDE (set_by, actor_id). Diese Zeilen gehoeren inhaltlich Q.
--    Wuerde der Pfad sie anfassen, liefe der Loeschantrag von D gegen die
--    Historie von Q.
-- =============================================================================

CREATE TEMP TABLE _audit_q_before AS
  SELECT id, old_row, new_row FROM app.audit_log
   WHERE row_id = 'e3000000-0000-0000-0000-000000000001';

SELECT cmp_ok((SELECT count(*) FROM _audit_q_before), '>', 0::bigint,
  'Ausgangslage: es gibt eine Audit Zeile zur Freigabe von Q, in der D als set_by steht');

SELECT app._t_shred_jwt('e2000000-0000-0000-0000-000000000001', 'admin');
SELECT is(app.rpc_shred_person('e1000000-0000-0000-0000-000000000002'),
  'e2000000-0000-0000-0000-000000000002'::uuid, 'Shred der Aerztin D');

SELECT is((SELECT count(*) FROM _clearance_q_before b JOIN app.medical_clearances m ON m.id = b.id
            WHERE m.person_id  IS DISTINCT FROM b.person_id
               OR m.status     IS DISTINCT FROM b.status
               OR m.load_note  IS DISTINCT FROM b.load_note
               OR m.set_by     IS DISTINCT FROM b.set_by
               OR m.set_by_role IS DISTINCT FROM b.set_by_role), 0::bigint,
  'Handelnde: die Freigabe von Q ist unveraendert, set_by zeigt weiter auf D');

SELECT is((SELECT count(*) FROM _access_q_before b JOIN app.access_log a ON a.id = b.id
            WHERE a.subject_id IS DISTINCT FROM b.subject_id
               OR a.actor_id   IS DISTINCT FROM b.actor_id
               OR a.actor_role IS DISTINCT FROM b.actor_role), 0::bigint,
  'Handelnde: die access_log Zeile von Q ist unveraendert, actor_id zeigt weiter auf D');

SELECT is((SELECT count(*) FROM _audit_q_before b JOIN app.audit_log a ON a.id = b.id
            WHERE a.old_row IS DISTINCT FROM b.old_row
               OR a.new_row IS DISTINCT FROM b.new_row), 0::bigint,
  'Handelnde: die Audit Zeile zur Freigabe von Q ist inhaltlich unveraendert');

SELECT is(app._t_audit_hits('Aerztin Shredtest'), 0::bigint,
  'Betroffene: der Anzeigename von D ist trotzdem aus dem audit_log verschwunden');

SELECT is((SELECT count(*) FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000002'), 1::bigint,
  'Handelnde: die Personenzeile von D bleibt, damit die Verweise nicht ins Leere zeigen');


-- =============================================================================
-- 6. Auskunft und Loeschung decken dieselben Speicherorte ab
--
--    rpc_export_my_data (Art. 15, 20) ist die Liste der Orte, die schon einmal
--    jemand vollstaendig zusammengetragen hat. Weicht sie von dem ab, was der
--    Shred raeumt, ist das ein Testfehler, kein Kommentar: wer Auskunft verlangt,
--    bekaeme dann mehr Listen, als eine Loeschung leeren kann.
-- =============================================================================

SELECT app._t_shred_jwt('e2000000-0000-0000-0000-000000000005', 'player');

SELECT set_eq(
  $$SELECT jsonb_object_keys(app.rpc_export_my_data()) EXCEPT SELECT 'exported_at'$$,
  $$VALUES ('person'), ('daily_checkins'), ('readiness_scores'),
           ('load_deviations'), ('medical_clearances'), ('access_log')$$,
  'Export und Shred kennen dieselben Speicherorte. Kommt hier einer dazu, gehoert er in 14_shred_person.sql');

-- Und die Gegenprobe in Zahlen: fuer P ist jeder dieser Orte leer.
SELECT is((SELECT count(*) FROM app.daily_checkins     WHERE person_id  = 'e1000000-0000-0000-0000-000000000004')
        + (SELECT count(*) FROM app.readiness_scores   WHERE person_id  = 'e1000000-0000-0000-0000-000000000004')
        + (SELECT count(*) FROM app.load_deviations    WHERE person_id  = 'e1000000-0000-0000-0000-000000000004')
        + (SELECT count(*) FROM app.medical_clearances WHERE person_id  = 'e1000000-0000-0000-0000-000000000004')
        + (SELECT count(*) FROM app.access_log         WHERE subject_id = 'e1000000-0000-0000-0000-000000000004'), 0::bigint,
  'Nach dem Shred ist jeder Speicherort aus dem Export fuer P leer');


SELECT * FROM finish();
ROLLBACK;
