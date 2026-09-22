-- =============================================================================
-- 20260922000041_clearance_proposals.sql (Quelle: backend/30_clearance_proposals.sql) — AP-47a Teil 1: der Vorschlag bekommt eine eigene Tabelle
--
-- Der Vorschlag der Physio bekommt eine eigene Tabelle.
--
-- WARUM. Bis heute schreibt app.rpc_propose_clearance eine echte Zeile in
-- app.medical_clearances, mit echtem status und valid_from = current_date.
-- ADR-017 Abschnitt 4.2 sagt fuer diese Funktion woertlich "kein Effekt auf
-- status", die Rollenmatrix (Modul 7 Abschnitt 5) fuehrt physio mit
-- "vorschlagen" und doctor mit "RW". Gemessen am 2026-09-22 im Klon tpos_a4,
-- Autocommit, echte Claims:
--
--   Aerztin setzt gestern    -> full    | doctor | "Arzt: voll freigegeben"
--   Physio schlaegt heute vor-> blocked | physio | "Physio: Verdacht, bitte pruefen"
--   app.rpc_get_clearance als Aerztin  -> blocked | physio | Physio: Verdacht...
--   app.rpc_list_team_members als Coach-> Player User | full
--                                         Player User | blocked   (ZWEI Zeilen)
--
-- Drei Schaeden in einem: (1) der Vorschlag ueberschreibt die Entscheidung,
-- weil rpc_get_clearance ORDER BY valid_from DESC LIMIT 1 nimmt. (2) Die
-- Kaderliste vervielfacht die Spielerin, weil der LEFT JOIN kein LIMIT hat.
-- (3) Der Begruendungstext der Physio landet ueber load_note beim Trainer —
-- ADR-017 Abschnitt 3 sagt "Status und load_note, nie ein Grund".
--
-- Chris hat am 2026-09-22 den Weg gewaehlt: eigene Tabelle. Damit ist die
-- Trennung strukturell und nicht per Filter, den jemand vergessen kann.
--
-- Bestand: in der Cloud gibt es 0 Zeilen mit proposed_by IS NOT NULL
-- (gemessen 2026-09-22, "vorschlaege": 0 bei 25 gesamt). Es ist also nichts
-- umzuziehen. Die Spalte medical_clearances.proposed_by bleibt stehen, sie
-- wird nur nicht mehr beschrieben: ein DROP COLUMN wuerde Historie wegnehmen,
-- die es heute zwar nicht gibt, aber in einem anderen Silo geben kann.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 14_shred_person.sql,
-- 27_clearance_team_guard.sql. Idempotent.
-- Tests: backend/30_clearance_proposals.pgtap.sql.
-- =============================================================================

-- =============================================================================
-- 1. Die Tabelle
-- =============================================================================

CREATE TABLE IF NOT EXISTS app.clearance_proposals (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id           uuid NOT NULL REFERENCES app.teams(id)   ON DELETE CASCADE,
  person_id         uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  status            app.app_clearance NOT NULL,
  rationale         text,
  proposed_by       uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  proposed_by_role  app.app_role NOT NULL,
  proposed_at       timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE app.clearance_proposals IS
  'AP-47a (2026-09-22): der Vorschlag der Physio, getrennt von der Entscheidung '
  'der Aerztin in app.medical_clearances. Append only, kein decided Flag: ein '
  'Vorschlag ist offen, solange nach seinem proposed_at keine Freigabe mit '
  'spaeterem valid_from steht. Art. 9 DSGVO, Loeschpfad in app.rpc_shred_person.';

COMMENT ON COLUMN app.clearance_proposals.status IS
  'Der VORGESCHLAGENE Zustand. Er ist nie die geltende Freigabe — die steht '
  'ausschliesslich in app.medical_clearances und wird ausschliesslich von '
  'app.rpc_set_clearance geschrieben (nur doctor).';

COMMENT ON COLUMN app.clearance_proposals.rationale IS
  'Begruendung der Physio. Ein Grund im Sinne von ADR-017 Abschnitt 3 und '
  'verlaesst die Datenbank nur fuer physio und doctor, nie fuer Staff oder admin.';

CREATE INDEX IF NOT EXISTS idx_clearance_proposals_team_id   ON app.clearance_proposals(team_id);
CREATE INDEX IF NOT EXISTS idx_clearance_proposals_person_id ON app.clearance_proposals(person_id);
CREATE INDEX IF NOT EXISTS idx_clearance_proposals_person_at ON app.clearance_proposals(person_id, proposed_at DESC);

ALTER TABLE app.clearance_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.clearance_proposals FORCE  ROW LEVEL SECURITY;


-- =============================================================================
-- 2. Rechte und Policy
-- =============================================================================
--
-- authenticated bekommt auf dieser Tabelle GAR NICHTS. Gelesen wird ueber
-- app.rpc_get_clearance, geschrieben ueber app.rpc_propose_clearance, beide
-- SECURITY DEFINER. Das ist die Lehre aus Befund F4 (AP-45e): ein Recht, das
-- der Definer Pfad nicht braucht, ist eine Flaeche ohne Nutzen.
--
-- Die SELECT Policy steht trotzdem, und sie ist bewusst nicht tot: sie beisst
-- in der Sekunde, in der jemand spaeter ein GRANT SELECT setzt. Dann gilt
-- sofort die Medizingrenze statt "alle im Team", wie sie
-- medical_clearances_select_team zieht. Punkt 55 nennt das den Unterschied
-- zwischen einer Einstellung und einem Recht.

REVOKE ALL ON app.clearance_proposals FROM PUBLIC;
REVOKE ALL ON app.clearance_proposals FROM anon;
REVOKE ALL ON app.clearance_proposals FROM authenticated;
GRANT  ALL ON app.clearance_proposals TO   service_role;

DROP POLICY IF EXISTS clearance_proposals_select_medical ON app.clearance_proposals;
CREATE POLICY clearance_proposals_select_medical ON app.clearance_proposals
  FOR SELECT TO authenticated
  USING (app.auth_is_medical() AND team_id = app.auth_team_id());

COMMENT ON POLICY clearance_proposals_select_medical ON app.clearance_proposals IS
  'Nur physio und doctor im eigenen Team. Kein Staff, kein admin, auch nicht die '
  'betroffene Person: ein Vorschlag ist keine Freigabe. ADR-018 gibt admin ein R '
  'auf medical_clearances.status und load_note, nicht auf diese Tabelle.';

DROP TRIGGER IF EXISTS clearance_proposals_audit ON app.clearance_proposals;
CREATE TRIGGER clearance_proposals_audit
  AFTER INSERT OR UPDATE OR DELETE ON app.clearance_proposals
  FOR EACH ROW EXECUTE FUNCTION app.audit_log_trigger();


-- =============================================================================
-- 3. app.rpc_propose_clearance schreibt in die neue Tabelle
-- =============================================================================
--
-- Rumpf sonst unveraendert gegenueber 28_propose_clearance_log.sql: Rollen-
-- pruefung zuerst, dann die Teampruefung aus Punkt 52 vor BEIDEN INSERTs,
-- dann die Protokollzeile aus Punkt 56.
--
-- Die resource der Protokollzeile bleibt absichtlich 'medical_clearances' und
-- wird NICHT auf 'clearance_proposals' umgestellt. Punkt 56 hat sie genau
-- deshalb so gewaehlt: Vorschlag und Entscheidung sollen in der Zugriffs-
-- uebersicht der Spielerin in derselben Zeile zusammenlaufen. Unterscheidbar
-- bleiben sie ueber actor_role (physio gegen doctor).
--
-- Rueckgabetyp und der Umbau auf "Antwort statt Ausnahme" stehen in Teil 2
-- (31_medical_doors.sql), zusammen mit der Tuer.

CREATE OR REPLACE FUNCTION app.rpc_propose_clearance(
  p_person_id uuid,
  p_status    app.app_clearance,
  p_rationale text DEFAULT NULL
)
RETURNS app.medical_clearances
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_proposal app.clearance_proposals;
  v_row      app.medical_clearances;
BEGIN
  -- Rolle pruefen (erste Anweisung!) - NUR physio
  IF NOT app.auth_has_role('physio') THEN
    PERFORM app.log_denial('medical_clearances.propose');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.propose (only physio)' USING errcode = '42501';
  END IF;

  -- Muster D, Regel 4 (Punkt 56, gleiche Lage wie N4)
  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    PERFORM app.log_denial('medical_clearances.propose');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.propose' USING errcode = '42501';
  END IF;

  INSERT INTO app.clearance_proposals (
    team_id, person_id, status, rationale, proposed_by, proposed_by_role
  ) VALUES (
    app.auth_team_id(), p_person_id, p_status, p_rationale,
    app.auth_person_id(), 'physio'::app.app_role
  )
  RETURNING * INTO v_proposal;

  -- Access log (Punkt 56, N8)
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'medical_clearances', 'write'
  );

  -- Rueckgabe im alten Typ, damit dieser Zwischenstand fuer sich lauffaehig
  -- bleibt. Die Zeile ist NICHT gespeichert, sie beschreibt den Vorschlag.
  -- Teil 2 ersetzt Typ und Rumpf durch jsonb.
  v_row.id          := v_proposal.id;
  v_row.team_id     := v_proposal.team_id;
  v_row.person_id   := v_proposal.person_id;
  v_row.status      := v_proposal.status;
  v_row.load_note   := v_proposal.rationale;
  v_row.valid_from  := v_proposal.proposed_at;
  v_row.set_by      := v_proposal.proposed_by;
  v_row.set_by_role := v_proposal.proposed_by_role;
  v_row.proposed_by := v_proposal.proposed_by;
  v_row.created_at  := v_proposal.created_at;
  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) IS
  'AP-47a (2026-09-22): der Vorschlag steht ab jetzt in app.clearance_proposals und '
  'ist damit strukturell keine Freigabe mehr. Vorher schrieb er eine echte Zeile in '
  'app.medical_clearances und ueberschrieb die Entscheidung der Aerztin (gemessen im '
  'Klon tpos_a4). Punkt 56: die Protokollzeile bleibt resource=medical_clearances, '
  'damit Vorschlag und Entscheidung in der Zugriffsuebersicht zusammenlaufen. '
  'Punkt 52: die Teampruefung steht vor beiden INSERTs.';


-- =============================================================================
-- 4. app.rpc_list_team_members: eine Zeile je Person, deterministisch
-- =============================================================================
--
-- Ueber den Auftrag hinaus, mit Grund (wie AP-57 bei Punkt 56).
--
-- Der LEFT JOIN hatte kein LIMIT. Zwei gleichzeitig gueltige Freigabezeilen
-- ergaben zwei Kaderzeilen fuer denselben Menschen, im Klon gemessen:
--   Player User | full
--   Player User | blocked
-- Abschnitt 3 nimmt die haeufigste Ursache weg (den Vorschlag), aber nicht die
-- Moeglichkeit: zwei Entscheidungen der Aerztin mit ueberlappender Gueltigkeit
-- erzeugen dieselbe Doppelzeile. Die Kaderliste ist die Auswahlliste der
-- Physio-Sicht (Web-Vorlauf, Bridge Punkt 33) — eine doppelte Spielerin dort
-- ist kein Schoenheitsfehler, sondern zwei widerspruechliche Gesundheits-
-- angaben nebeneinander.
--
-- LATERAL mit ORDER BY valid_from DESC, id DESC LIMIT 1: dieselbe Auswahlregel
-- wie in app.rpc_get_clearance, damit Liste und Detail nie auseinanderlaufen.
-- Der id-Tiebreaker steht dort ebenfalls (Teil 2), sonst entscheidet bei
-- gleichem valid_from der Zufall.

CREATE OR REPLACE FUNCTION app.rpc_list_team_members()
RETURNS TABLE(
  id uuid,
  display_name text,
  person_position text,
  clearance_status app.app_clearance
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Rolle pruefen (erste Anweisung)
  IF NOT (app.auth_is_staff() OR app.auth_is_medical() OR app.auth_has_role('admin')) THEN
    PERFORM app.log_denial('persons.list');
    RAISE EXCEPTION 'FORBIDDEN: persons.list' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.display_name,
    p.person_position,
    COALESCE(mc.status, 'full'::app.app_clearance) AS clearance_status
  FROM app.persons p
  LEFT JOIN LATERAL (
    SELECT c.status
      FROM app.medical_clearances c
     WHERE c.person_id = p.id
       AND c.team_id   = app.auth_team_id()
       AND c.valid_from <= current_date
       AND (c.valid_to IS NULL OR c.valid_to >= current_date)
     ORDER BY c.valid_from DESC, c.id DESC
     LIMIT 1
  ) mc ON true
  WHERE p.team_id = app.auth_team_id()
    AND p.is_active = true;
END;
$$;

COMMENT ON FUNCTION app.rpc_list_team_members() IS
  'Punkt 55 (2026-09-22): kein EXECUTE fuer authenticated, keine Tuer in public. '
  'Die Tuer gehoert in den Web-Vorlauf (Bridge Punkt 33), nicht in AP-47a. '
  'AP-47a (2026-09-22): LATERAL LIMIT 1 statt LEFT JOIN. Zwei gleichzeitig gueltige '
  'Freigabezeilen ergaben vorher zwei Kaderzeilen fuer denselben Menschen. Dieselbe '
  'Auswahlregel wie app.rpc_get_clearance.';


-- =============================================================================
-- 5. Loeschpfad (Art. 17 DSGVO)
-- =============================================================================
--
-- Eine neue Art.-9-Tabelle ohne Loeschpfad ist ein Duplikat ohne Loeschpfad,
-- und genau das verbietet die wichtigste Regel der Bridge (Abschnitt 2,
-- Punkt 4). Der Rumpf ist Zeile fuer Zeile der aus 14_shred_person.sql, mit
-- genau EINER neuen Zeile in Schritt 3, bei den Freigaben, mit demselben
-- Vorbehalt zu Paragraph 630f BGB.
--
-- Schritt 6 erfasst die neue Tabelle ohne Zutun: app.clearance_proposals traegt
-- den Audit Trigger aus Abschnitt 2, ihre Kopien nennen person_id im jsonb und
-- fallen damit unter Referenzform a).

DROP FUNCTION IF EXISTS app.rpc_shred_person(uuid);

CREATE FUNCTION app.rpc_shred_person(p_person_id uuid)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_team_id       uuid;
  v_actor_id      uuid;
  v_auth_user_id  uuid;
  v_found         boolean;
  v_now           timestamptz := now();
BEGIN
  -- ---------------------------------------------------------------------------
  -- 1. Berechtigung. Nur admin, nur das eigene Team.
  -- ---------------------------------------------------------------------------
  IF NOT app.auth_has_role('admin') THEN
    PERFORM app.log_denial('persons.shred');
    RAISE EXCEPTION 'FORBIDDEN: persons.shred (only admin)' USING errcode = '42501';
  END IF;

  v_team_id  := app.auth_team_id();
  v_actor_id := app.auth_person_id();

  -- Die Person muss es im eigenen Team geben. v1 lief bei einer fremden oder
  -- unbekannten id still durch und meldete Erfolg.
  SELECT p.auth_user_id, true
    INTO v_auth_user_id, v_found
    FROM app.persons p
   WHERE p.id = p_person_id
     AND p.team_id = v_team_id;

  IF NOT coalesce(v_found, false) THEN
    RAISE EXCEPTION 'NOT_FOUND: persons.shred' USING errcode = 'P0002';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2. Nutzdaten. Fuer Trainingsbefinden besteht keine Aufbewahrungspflicht.
  --    Jedes DELETE hier erzeugt ueber app.audit_log_trigger() eine Audit Zeile
  --    mit vollstaendiger Kopie. Schritt 6 raeumt sie im selben Aufruf mit ab.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.daily_checkins    WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.readiness_scores  WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.load_deviations   WHERE person_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 3. Medizinische Freigaben (Entscheidung 1: loeschen).
  --    Vorbehalt der anwaltlichen Gegenprobe zu § 630f BGB: zaehlt die Freigabe
  --    des Mannschaftsarztes als aerztliche Dokumentation, sticht Art. 17 Abs. 3
  --    lit. b das Loeschrecht, und aus diesem DELETE wird eine Reduktion.
  -- ---------------------------------------------------------------------------
  -- AP-47a: die Vorschlaege der Physio zuerst, sie verweisen auf dieselbe Person.
  DELETE FROM app.clearance_proposals WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.medical_clearances  WHERE person_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 4. Zugriffsprotokoll (Entscheidung 2). Jede Zeile nennt zwei Personen.
  --    Betroffene (subject_id): die Zeile gehoert dieser Person, sie geht.
  --    Handelnde (actor_id): die Zeile gehoert der betroffenen Person und ist ihr
  --    Nachweis darueber, wer in ihre Daten gesehen hat. Sie bleibt unveraendert,
  --    der Personenbezug ist ueber die anonymisierte persons Zeile aufgehoben.
  --    app.access_denials nennt nur Handelnde und bleibt deshalb ganz unberuehrt.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.access_log WHERE subject_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 5. Personenzeile anonymisieren. Crypto Shredding: die id bleibt, damit jeder
  --    Verweis auf die Person als Handelnde weiter traegt.
  --    Die Bedingung am Ende macht den zweiten Aufruf wirkungslos statt
  --    wirkungsgleich: ohne sie schriebe jeder weitere Shred eine neue Audit
  --    Zeile und vergaebe einen neuen Pseudonymnamen.
  -- ---------------------------------------------------------------------------
  UPDATE app.persons
     SET display_name    = 'SCRAPED-' || substr(md5(random()::text), 1, 8),
         auth_user_id    = NULL,
         birth_date      = NULL,
         is_active       = false,
         -- AP-43: die Darstellungspraeferenz der Body Map faellt auf die Vorgabe
         -- zurueck. Sie ist kein Geschlechtsfeld, aber an einer namenlosen Zeile
         -- ist sie eine Restangabe ueber einen Menschen ohne jeden Zweck.
         body_map_figure = 'aus_dem_team',
         updated_at      = v_now
   WHERE id = p_person_id
     AND team_id = v_team_id
     AND (auth_user_id IS NOT NULL
          OR birth_date IS NOT NULL
          OR is_active
          OR body_map_figure <> 'aus_dem_team'
          OR display_name NOT LIKE 'SCRAPED-%');

  -- ---------------------------------------------------------------------------
  -- 6. audit_log. Laeuft ZULETZT, und das ist der Grundsatz des ganzen Pfads:
  --    app.audit_log_trigger() kopiert mit to_jsonb(OLD) und to_jsonb(NEW) ganze
  --    Zeilen. Die Schritte 2 bis 5 haben also gerade neue Kopien erzeugt. Weil
  --    diese Kopien denselben Personenbezug tragen, erfasst der Schritt sie mit.
  --    Liefe er frueher, raeumte der Pfad auf und fuellte danach nach.
  --
  --    Geleert wird der Inhalt, nicht die Zeile: table_name, row_id, operation,
  --    actor_id, actor_role und occurred_at bleiben stehen. Damit bleibt
  --    belegbar, DASS es eine Aenderung gab (Art. 5 Abs. 2, Art. 32), ohne den
  --    Inhalt zu behalten. Nebeneffekt, der gewollt ist: ein Shred taugt damit
  --    nicht zum Verwischen von Spuren.
  --
  --    Zwei Referenzformen, und nur diese zwei:
  --      a) person_id im jsonb  (daily_checkins, readiness_scores,
  --         medical_clearances, load_deviations)
  --      b) id im jsonb bei table_name = 'persons'  (dort stehen display_name
  --         und birth_date im Klartext)
  --    Verweise auf Handelnde (actor_id, set_by, proposed_by, reviewed_by)
  --    bleiben ausdruecklich unberuehrt, siehe Kopf der Datei.
  --
  --    app.audit_log traegt selbst keinen Trigger, dieses UPDATE erzeugt also
  --    keine neue Zeile.
  -- ---------------------------------------------------------------------------
  UPDATE app.audit_log a
     SET old_row = CASE WHEN a.old_row IS NULL THEN NULL
                        ELSE jsonb_build_object('shredded_at', v_now) END,
         new_row = CASE WHEN a.new_row IS NULL THEN NULL
                        ELSE jsonb_build_object('shredded_at', v_now) END
   WHERE a.team_id = v_team_id
     AND (a.old_row IS NOT NULL OR a.new_row IS NOT NULL)
     AND (
           a.old_row ->> 'person_id' = p_person_id::text
        OR a.new_row ->> 'person_id' = p_person_id::text
        OR (a.table_name = 'persons'
            AND (a.old_row ->> 'id' = p_person_id::text
                 OR a.new_row ->> 'id' = p_person_id::text))
         );

  -- ---------------------------------------------------------------------------
  -- 7. Abschlusszeile. Traegt keinen Inhalt: die Person steht in row_id, nicht
  --    im jsonb. Stuende sie im jsonb, loeschte ein zweiter Shred die
  --    Abschlusszeile des ersten wieder leer.
  -- ---------------------------------------------------------------------------
  INSERT INTO app.audit_log (team_id, table_name, row_id, operation, actor_id, actor_role, old_row, new_row)
  VALUES (
    v_team_id, 'persons', p_person_id, 'DELETE',
    v_actor_id, 'admin'::app.app_role,
    NULL, jsonb_build_object('action', 'crypto_shred', 'shredded_at', v_now)
  );

  -- ---------------------------------------------------------------------------
  -- 8. Das Auth Konto liegt im Schema auth und wird ueber die Admin API geloescht,
  --    nicht per SQL. Ohne diesen zweiten Schritt bliebe die E-Mail Adresse
  --    gespeichert und machte das Pseudonym wieder aufloesbar.
  --    NULL heisst: kein Konto zu loeschen (nie eines gehabt, oder schon geshreddet).
  -- ---------------------------------------------------------------------------
  RETURN v_auth_user_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM PUBLIC, anon;
-- KEIN GRANT fuer authenticated. 14_shred_person.sql hat eines, Punkt 55 hat es
-- wieder entzogen, und rpc_shred_person bekommt in AP-47a keine Tuer. Ein DROP
-- plus CREATE setzt die ACL zurueck, das REVOKE muss also hier stehen; ein
-- uebernommenes GRANT haette den Entzug stillschweigend rueckgaengig gemacht.
REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM authenticated;

COMMENT ON FUNCTION app.rpc_shred_person(uuid) IS
  'Art. 17 DSGVO. Loescht alle Spuren einer Person in app.*, anonymisiert die '
  'Personenzeile und leert den Inhalt der zugehoerigen audit_log Zeilen, ohne '
  'deren Metadaten aufzugeben. Gibt die alte auth_user_id zurueck, damit das '
  'Auth Konto im zweiten Schritt ueber die Admin API geloescht werden kann '
  '(scripts/shred-auth-user.mjs). AP-39b. '
  'AP-47a (2026-09-22): app.clearance_proposals kommt in Schritt 3 dazu.';
