-- Migration 20260921000023_shred_person_v2.sql (AP-39b, Art. 17 DSGVO)
-- Quelle: backend/14_shred_person.sql (identisch). Tests: backend/14_shred_person.pgtap.sql.
-- Aendert den Rueckgabetyp von app.rpc_shred_person (boolean zu uuid) und
-- vervollstaendigt den Loeschpfad. Loescht Zeilen von Personen, die geshreddet
-- werden, aber nichts beim Einspielen selbst.

-- =============================================================================
-- 14_shred_person.sql — app.rpc_shred_person v2 (AP-39b, Art. 17 DSGVO)
--
-- Vorher (v1, 09_rpcs.sql 9.11): der Shred anonymisierte app.persons und schrieb
-- eine Abschlusszeile. Das Inventar aus AP-39 hat nachgezaehlt: das erfasst einen
-- von neun Speicherorten mit Personenbezug. Ueber 25 Personen blieben 3031 Zeilen
-- stehen, davon 2981 mit Art.-9-Inhalt, und der Shred erzeugte im selben Aufruf
-- zwei neue Kopien von Anzeigename und Geburtsdatum im audit_log.
--
-- v2 raeumt alle Speicherorte in app.*, die eine Person betreffen, und gibt den
-- Nachweis nach Art. 5 Abs. 2 nicht auf. Umsetzung des Loeschpfads aus Teil F
-- Stufe 1 des Audits mit den Entscheidungen von Chris vom 2026-09-21.
--
-- Reihenfolge im Aufruf (der Grundsatz, der sie bestimmt, steht in Schritt 6):
--   1. Berechtigung: nur admin, nur das eigene Team.
--   2. Nutzdaten loeschen: daily_checkins, readiness_scores, load_deviations.
--   3. Medizinische Freigaben loeschen (Entscheidung 1).
--   4. Zugriffsprotokoll differenziert: Betroffenenzeilen loeschen,
--      Handelndenzeilen unveraendert lassen (Entscheidung 2).
--   5. Personenzeile anonymisieren (Crypto Shredding, die id bleibt).
--   6. audit_log inhaltlich leeren, Metadaten behalten (Entscheidung 3).
--   7. Abschlusszeile schreiben.
--   8. Auth Konto: ausserhalb der Datenbank, deshalb gibt die Funktion die alte
--      auth_user_id zurueck (Entscheidung 4). Das Skript dazu ist
--      scripts/shred-auth-user.mjs.
--
-- Was der Pfad NICHT anfasst, und warum:
--   Verweise auf die Person als HANDELNDE (actor_id, set_by, proposed_by,
--   reviewed_by) bleiben unberuehrt. Der Shred loescht die Personenzeile nicht,
--   er anonymisiert sie, die persons.id bleibt. Jeder Verweis zeigt damit weiter
--   auf eine namenlose Zeile: die Historie bleibt lueckenlos und verknuepfbar,
--   nur nicht mehr zuordenbar. Eine Zeile, in der ein geshredderter Arzt als
--   set_by steht, gehoert inhaltlich dem Spieler, um dessen Freigabe es geht.
--   Sie anzufassen hiesse, den Loeschantrag des Arztes gegen die Historie des
--   Spielers laufen zu lassen.
--
-- Rueckgabetyp: v1 gab boolean, v2 gibt uuid (die alte auth_user_id, oder NULL,
-- wenn die Person kein Auth Konto hatte oder bereits geshreddet war).
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql. Idempotent.
-- Tests: backend/14_shred_person.pgtap.sql.
-- =============================================================================

-- Rueckgabetyp aendert sich, CREATE OR REPLACE reicht dafuer nicht.
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
  DELETE FROM app.medical_clearances WHERE person_id = p_person_id AND team_id = v_team_id;

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
     SET display_name = 'SCRAPED-' || substr(md5(random()::text), 1, 8),
         auth_user_id = NULL,
         birth_date   = NULL,
         is_active    = false,
         updated_at   = v_now
   WHERE id = p_person_id
     AND team_id = v_team_id
     AND (auth_user_id IS NOT NULL
          OR birth_date IS NOT NULL
          OR is_active
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

REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_shred_person(uuid) TO authenticated;

COMMENT ON FUNCTION app.rpc_shred_person(uuid) IS
  'Art. 17 DSGVO. Loescht alle Spuren einer Person in app.*, anonymisiert die '
  'Personenzeile und leert den Inhalt der zugehoerigen audit_log Zeilen, ohne '
  'deren Metadaten aufzugeben. Gibt die alte auth_user_id zurueck, damit das '
  'Auth Konto im zweiten Schritt ueber die Admin API geloescht werden kann '
  '(scripts/shred-auth-user.mjs). AP-39b.';
