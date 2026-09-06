# TASK CONTRACT — AP-13b: Reconciling-Migration (Medizin-Gate)

**Auditor:** Claude Code
**Stand:** 2026-09-06
**Branch:** `tpos/medizin-gate-rls` (Working Copy basierend auf `main`)
**Ziel:** Spec-konforme Rollen- + Medizin-Gate-Implementierung, die mit dem Dashboard kompatibel ist.

---

## KONTEXT: Warum es das gibt

Es gibt **drei konkurrierende Designs** im Repo:

1. **`backend/schema.sql` + `backend/rls.sql`** (auf `main`, live auf Cloud-DB):
   - Verwendet `public.players`, `public.profiles`, `current_app_role()`, `is_medical_role()`, `is_staff()`, `medical_status_view`
   - Kein `tenant_id`, kein `team_id` (Silo-Design)
   - **Nicht** spec-konform (veraltete Helper-Namen, `players` statt `persons`)

2. **`backend/02_medizin_gate.sql` + `backend/02_medizin_gate.pgtap.sql`** (auf `tpos/medizin-gate-rls`):
   - Verwendet `app.*`-Schema mit `tenant_id` auf jeder Tabelle
   - Helper: `app.tenant()`, `app.role()`, `app.uid()`, `app.self_player_id()`, `app.is_med()`, `app.is_med_staff()`, `app.is_sport_staff()`
   - Tabellen: `app.medical_record`, `app.medical_record_dx`, `app.readiness_score`, `app.readiness_factor_medical`, `app.daily_checkin`, `app.daily_checkin_medical`, `app.checkin_note_shared`, `app.medical_status_badge`, `app.badge_staging`, `app.badge_audit`, `app.medical_access_log`, `app.user_player`
   - **NICHT spec-konform** (verwendet `tenant_id` gegen ADR-001, fehlende `persons`/`role_assignments`/`medical_clearances`)

3. **Vault-Kanon** (Spec Modul 7 v1.1 + RLS-Schema v1.1):
   - Verlangt `persons`, `role_assignments`, `medical_clearances`, `audit_log`, `access_denials`
   - Helper: `auth_person_id()`, `auth_team_id()`, `auth_in_team()`, `auth_has_role()`, `auth_is_staff()`, `auth_is_medical()`
   - `team_id` statt `tenant_id` (ADR-001 Silo)
   - **Dieser Contract setzt den Vault-Kanon um.**

**Konflikt:** Die `02_medizin_gate.sql` vom Branch ist **nicht** verwendbar — sie verletzt ADR-001 (verwendet `tenant_id`) und enthält nicht die kanonischen Tabellen. Du musst eine **neue** Migration schreiben.

---

## SPECS (kanonisch, build-ready)

- `02 Projekte/Team Performance OS/Module/Modul-Rollen-Medizin-Gate.md` (Modul 7, v1.1)
- `02 Projekte/Team Performance OS/Backend/RLS-Schema.md` (v1.1)
- `02 Projekte/Team Performance OS/ADRs/ADR-2026-08-27-rollen-medizin-gate.md` (ADR-009)
- `02 Projekte/Team Performance OS/ADRs/ADR-2026-08-27-p3-readiness-visibility-gate.md` (ADR-011)

---

## CANONICAL ENVIRONMENT

- **Lokal:** Postgres 17 auf unix socket `/tmp`, DB `tpos_gate_test` existiert mit pgtap
- **Cloud:** Supabase `sxpfetwrqqwqijapgkcd` (Frankfurt, EU) — Migrationen bereits live: `20260904000001_schema.sql` bis `20260904000007_dashboard.sql`
- **Kein Docker / Kein Supabase CLI** für lokale Tests
- **JWT-Simulation:** `SET LOCAL request.jwt.claims = '{"sub":"<uuid>","role":"authenticated","app_role":"coach","team_id":"<tid>"}'`
- **Test-Befehle:**
  ```bash
  psql -X -h /tmp -v ON_ERROR_STOP=1 -d tpos_gate_test -f backend/08_reconciling.sql
  psql -X -h /tmp -d tpos_gate_test -f backend/08_reconciling.pgtap.sql
  ```

---

## SCHRITT 1: Fundament in `app.*` legen

Erstelle `backend/08_reconciling.sql` mit folgenden Tabellen (alle in Schema `app`):

```sql
-- teams (falls nicht vorhanden)
CREATE TABLE app.teams (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  timezone      text NOT NULL DEFAULT 'Europe/Berlin',
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- persons (kanonisch: Spieler UND Staff)
CREATE TABLE app.persons (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  auth_user_id  uuid UNIQUE,  -- references auth.users(id) ON DELETE SET NULL (kein FK für Standalone-Test)
  display_name  text NOT NULL,
  position      text,
  shirt_number  smallint,
  birth_date    date,  -- PII: nur self, doctor, admin
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz
);

-- role_assignments (eine Person kann mehrere Rollen haben)
CREATE TABLE app.role_assignments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id     uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id   uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  role        app_role NOT NULL,  -- CREATE TYPE app_role AS ENUM ('player','coach','athletic_coach','physio','doctor','admin')
  valid_from  date NOT NULL DEFAULT current_date,
  valid_to    date,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (person_id, role, valid_from)
);

-- medical_clearances (einziger medizinischer Datenpunkt mit Trainer-Sichtbarkeit)
CREATE TYPE app.app_clearance AS ENUM ('full', 'limited', 'individual', 'blocked');

CREATE TABLE app.medical_clearances (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id     uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  status        app.app_clearance NOT NULL,
  load_note     text,  -- belastungsbezogen, KEINE Diagnose
  valid_from    date NOT NULL,
  valid_to      date,
  set_by        uuid NOT NULL,  -- references app.persons(id)
  set_by_role   app_role NOT NULL,
  proposed_by   uuid,  -- references app.persons(id)
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- audit_log (DSGVO Rechenschaftspflicht, append-only)
CREATE TABLE app.audit_log (
  id          bigserial PRIMARY KEY,
  team_id     uuid NOT NULL,
  table_name  text NOT NULL,
  row_id      uuid NOT NULL,
  operation   text NOT NULL,  -- 'INSERT' | 'UPDATE' | 'DELETE'
  actor_id    uuid,
  actor_role  app_role,
  old_row     jsonb,
  new_row     jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

-- access_denials (Compliance-Metrik: jeder Deny auf medizinischen Tabellen)
CREATE TABLE app.access_denials (
  id          bigserial PRIMARY KEY,
  team_id     uuid,
  actor_id    uuid,
  actor_role  app_role,
  resource    text NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now()
);
```

**Wichtig:**
- Alle Tabellen: `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY`
- `team_id` ist die **einzige** Scoping-Ebene (ADR-001 Silo) — **KEIN `tenant_id`**
- `app_role` Enum: `CREATE TYPE app.app_role AS ENUM ('player','coach','athletic_coach','physio','doctor','admin')`

---

## SCHRITT 2: Helper-Funktionen ergänzen

Erstelle in `backend/08_reconciling.sql`:

```sql
-- Alle: LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, auth, pg_temp

CREATE OR REPLACE FUNCTION app.auth_person_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, auth, pg_temp
AS $$
  SELECT nullif(auth.jwt() ->> 'person_id', '')::uuid;
$$;

CREATE OR REPLACE FUNCTION app.auth_team_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, auth, pg_temp
AS $$
  SELECT nullif(auth.jwt() ->> 'team_id', '')::uuid;
$$;

CREATE OR REPLACE FUNCTION app.auth_has_role(r app.app_role) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, auth, pg_temp
AS $$
  SELECT coalesce((auth.jwt() -> 'roles') ? r::text, false);
$$;

CREATE OR REPLACE FUNCTION app.auth_in_team(t uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, auth, pg_temp
AS $$
  SELECT t IS NOT NULL AND t = app.auth_team_id();
$$;

CREATE OR REPLACE FUNCTION app.auth_is_staff() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, auth, pg_temp
AS $$
  SELECT app.auth_has_role('coach') OR app.auth_has_role('athletic_coach');
$$;

CREATE OR REPLACE FUNCTION app.auth_is_medical() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, auth, pg_temp
AS $$
  SELECT app.auth_has_role('physio') OR app.auth_has_role('doctor');
$$;
```

**Grants:** `REVOKE EXECUTE FROM PUBLIC; GRANT EXECUTE TO authenticated, anon, service_role;`

---

## SCHRITT 3: RPCs implementieren

Implementiere **alle 11 RPCs** aus Spec §7 (Abschnitt 420-433):

| RPC | Params | Returns | Erlaubte Rollen |
|-----|--------|---------|-----------------|
| `app.rpc_get_my_roles()` | – | `{person_id, team_id, roles[]}` | alle |
| `app.rpc_list_team_members()` | – | `person[]` (id, name, position, clearance_status) | staff, medical, admin |
| `app.rpc_check_ins_medical(p_from, p_to)` | date, date | `daily_check_ins[]` inkl. `body_map` | medical, self. Staff+admin: `FORBIDDEN` + `access_denials` |
| `app.rpc_readiness_full(p_person_id, p_from, p_to)` | uuid, date, date | `readiness_scores[]` inkl. `score_total`, `factors` | medical, self. Staff+admin: `FORBIDDEN` + `access_denials` |
| `app.rpc_release_deviation(p_deviation_id, p_decision)` | uuid, text | `load_deviation` | `physio`, `doctor` |
| `app.rpc_get_clearance(p_person_id)` | uuid | `{status, load_note, valid_from, valid_to}` | staff (nur Badge+Note), medical, self |
| `app.rpc_set_clearance(p_person_id, p_status, p_load_note, p_valid_from, p_valid_to)` | | `medical_clearance` | **nur** `doctor` |
| `app.rpc_propose_clearance(p_person_id, p_status, p_rationale)` | | `medical_clearance` (`proposed_by` gesetzt) | `physio` |
| `app.rpc_get_my_access_log(p_from, p_to)` | date, date | `access_log[]` | self |
| `app.rpc_export_my_data()` | – | `jsonb` (Art. 20 DSGVO) | self, admin |
| `app.rpc_shred_person(p_person_id)` | uuid | `boolean` | `admin` |
| `app.rpc_admin_denials(p_from, p_to)` | date, date | `access_denials[]` | `admin` |

**Jeder RPC:**
- `SECURITY DEFINER`
- Prüft Rolle als **erste Anweisung** im Funktionsrumpf
- Schreibt bei medizinnahen Ressourcen einen `audit_log`-Eintrag
- Wirft `raise exception 'FORBIDDEN' using errcode = '42501'` bei verbotenem Zugriff
- Schreibt bei Deny einen `access_denials`-Eintrag (über `dblink` in autonomer Transaktion, damit der Eintrag das `raise` überlebt)

---

## SCHRITT 4: Dashboard migriere

Passe `backend/03_dashboard.sql` (oder erstelle `backend/08_dashboard_migration.sql`) an:

- `rpc_morning_ops()` gegen `app.persons`, `app.medical_clearances`, `app.role_assignments` umstellen
- Helper-Aufrufe von `current_profile_id()`, `current_app_role()`, `current_player_id()` auf `app.auth_person_id()`, `app.auth_team_id()`, `app.auth_is_staff()` umstellen
- `medical_status_view` gegen `app.medical_clearances` ersetzen
- `players` gegen `app.persons` ersetzen
- `profiles` gegen `app.persons` + `app.role_assignments` ersetzen

**Wichtig:** Die Dashboard-Migration muss **additiv** sein — die bestehenden `public.*`-Tabellen werden **nicht** gelöscht (sie existieren auf der Cloud-DB und werden von anderen Features verwendet).

---

## SCHRITT 5: pgTAP-Suite schreiben

Erstelle `backend/08_reconciling.pgtap.sql` mit Tests für:

1. **RLS-Policies** für `persons`, `role_assignments`, `medical_clearances`, `audit_log`, `access_denials`
2. **Alle neuen RPCs** (positiv + negativ)
3. **Admin-Zugriff auf `audit_log`** = erlaubt
4. **`audit_log` wird bei JEDEM Insert/Update/Delete auf medizinischen Tabellen geschrieben** (Trigger-Test)
5. **`access_denials` wird bei JEDEM Deny geschrieben und überlebt `raise exception`** (autonome Transaktion per `dblink`)
6. **Spaltenrechte:** `revoke select` + `grant select (liste)` auf `persons` (ohne `birth_date`), `medical_clearances`
7. **Kein Vorkommen von `tenants`, `tenant_id`, `auth_in_tenant`, `auth_player_id`, `players`, `player_id`** im Repo (Grep-Test)

---

## SCHRITT 6: Spaltenrechte setzen

```sql
-- persons: birth_date ist NICHT in der Spaltenliste
REVOKE SELECT ON app.persons FROM authenticated;
GRANT SELECT (id, team_id, auth_user_id, display_name, position, shirt_number, is_active, created_at, updated_at) ON app.persons TO authenticated;

-- medical_clearances: load_note ist in der Liste (Trainer-sichtbar)
REVOKE SELECT ON app.medical_clearances FROM authenticated;
GRANT SELECT (id, team_id, person_id, status, load_note, valid_from, valid_to, set_by, set_by_role, proposed_by, created_at) ON app.medical_clearances TO authenticated;

-- audit_log: nur admin lesbar
REVOKE SELECT ON app.audit_log FROM authenticated;
GRANT SELECT ON app.audit_log TO authenticated;  -- Policy begrenzt auf admin

-- access_denials: nur admin lesbar
REVOKE SELECT ON app.access_denials FROM authenticated;
GRANT SELECT ON app.access_denials TO authenticated;  -- Policy begrenzt auf admin
```

---

## DONE_WHEN

- [ ] `app.persons`, `app.role_assignments`, `app.medical_clearances`, `app.audit_log`, `app.access_denials` existieren mit RLS + FORCE RLS
- [ ] Helper `app.auth_in_team()`, `app.auth_has_role()`, `app.auth_person_id()`, `app.auth_team_id()`, `app.auth_is_staff()`, `app.auth_is_medical()` existieren
- [ ] Alle 11 RPCs aus Spec §7 implementiert und getestet
- [ ] Dashboard (`rpc_morning_ops`) läuft gegen `app.*`-Tabellen
- [ ] pgTAP: Admin-Zugriff auf `audit_log` = erlaubt
- [ ] pgTAP: `audit_log` wird bei JEDEM Insert/Update/Delete auf medizinischen Tabellen geschrieben
- [ ] pgTAP: `access_denials` wird bei JEDEM Deny geschrieben und überlebt `raise exception`
- [ ] Spaltenrechte: `revoke select` + `grant select (liste)` auf `persons`, `medical_clearances`
- [ ] Kein Vorkommen von `tenants`, `tenant_id`, `auth_in_tenant`, `auth_player_id`, `players`, `player_id` im Repo (`grep -rn` → 0 hits)

---

## VERIFIKATION

```bash
# 1. Migration anwenden
psql -X -h /tmp -v ON_ERROR_STOP=1 -d tpos_gate_test -f backend/08_reconciling.sql
# → exit 0

# 2. pgTAP-Tests laufen lassen
psql -X -h /tmp -d tpos_gate_test -f backend/08_reconciling.pgtap.sql
# → 100% grün, keine failed tests

# 3. Grep-Check
grep -rn "tenants\|tenant_id\|auth_in_tenant\|auth_player_id\|players\|player_id" backend/
# → 0 hits

# 4. Dashboard rendert mit echten Daten aus `app.*`
# (Manueller Test gegen lokale DB oder Cloud-DB)
```

---

## OUT_OF_SCOPE

- `backend/02_medizin_gate.sql` von `tpos/medizin-gate-rls` NICHT verwenden (nicht spec-konform)
- Alte `backend/schema.sql` / `backend/rls.sql` NICHT löschen (noch für `public.*`-Tabellen benötigt)
- `main`-Branch NICHT verändern (nur neue Dateien im Working Tree)
- Cloud-DB Push erst nach lokaler Verifikation
- UI-Komponenten (erfolgen in separatem AP)

---

## CONSTRAINTS

- **ADR-001 Silo:** Eine Supabase-Instanz = ein Verein. **KEIN `tenant_id`** — `team_id` ist die einzige Scoping-Ebene.
- **ADR-009 Rollen-Matrix:** Hart, nicht per Feature-Flag aufhebbar. Ein Ticket, das eines der `–` aufweicht, braucht ein neues ADR.
- **ADR-011 P3-Gating:** `readiness_scores.score_total` ist player-only. Staff sieht nur `band`.
- **Supabase-Instanz:** `sxpfetwrqqwqijapgkcd` (Frankfurt, EU)
- **Migrationen aufsteigend:** `supabase/migrations/20260904000008_reconciling.sql` (nach `07_dashboard.sql`)
- **JWT-Simulation:** `SET LOCAL request.jwt.claims = '{"sub":"<uuid>","role":"authenticated","app_role":"coach","team_id":"<tid>"}'`
- **dblink-Extension:** Bereits in `02_medizin_gate.sql` verwendet — für autonome Transaktion bei `access_denials`

---

## QUELLEN

- Spec: `02 Projekte/Team Performance OS/Module/Modul-Rollen-Medizin-Gate.md` (v1.1, kanonisch)
- Spec: `02 Projekte/Team Performance OS/Backend/RLS-Schema.md` (v1.1, build-fertig)
- ADR: `02 Projekte/Team Performance OS/ADRs/ADR-2026-08-27-rollen-medizin-gate.md` (ADR-009)
- ADR: `02 Projekte/Team Performance OS/ADRs/ADR-2026-08-27-p3-readiness-visibility-gate.md` (ADR-011)
- Audit: `02 Projekte/Team Performance OS/Audits/2026-09-06-medizin-gate-compliance-audit.md` (§9 Reconciling-AP)
- Backlog: `02 Projekte/Team Performance OS/Arbeitspakete.md` (AP-13b)
