# Löschkonzept — Team Performance OS

> **Status:** Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.
> **Stand:** 2026-09-18

---

## 1. Zweck

Dieses Dokument beschreibt die technische und organisatorische Umsetzung der Löschung personenbezogener Daten im Team Performance OS nach Art. 17 DSGVO (Recht auf Löschung) und Art. 5 Abs. 1 lit. e DSGVO (Speicherbegrenzung).

---

## 2. Löschverfahren

### 2.1 Standard-Löschung (Soft Delete + Cascade)

**Auslöser:** Vertragsende eines Spielers/Trainers, Widerruf der Einwilligung, Auskunftsbegehren.

**Technische Umsetzung:**

```sql
-- 1. Person löscht (CASCADE auf alle abhängigen Tabellen)
DELETE FROM app.persons WHERE id = :person_id;
-- → CASCADE löscht: app.role_assignments, app.medical_clearances

-- 2. Auth-User löscht
-- Supabase: DELETE FROM auth.users WHERE id = :auth_user_id;
-- → Trigger löscht: public.profiles, public.players (CASCADE)

-- 3. Verbleibende Daten anonymisieren
UPDATE public.daily_checkins SET free_text = NULL WHERE player_id = :player_id;
UPDATE public.medical_records SET diagnosis = NULL, symptoms = NULL, treatment = NULL, rehab_plan = NULL WHERE player_id = :player_id;
```

**Gelöschte Daten:**
- `app.persons` (Name, Geburtsdatum, Auth-ID)
- `app.role_assignments` (Rollen-Zuordnungen)
- `app.medical_clearances` (Clearance-Status, Belastungshinweise)
- `public.players` (Stammdaten)
- `public.profiles` (E-Mail, Rolle, Auth-ID)
- `public.medical_records` (Diagnosen, Symptome, Behandlung)
- `public.daily_checkins` (Freitext → NULL, Metriken anonymisiert)
- `public.session_loads` (RPE-Werte)
- `public.attendance` (Teilnahme)
- `public.development_goals` (Ziele)
- `public.fines` (Strafen)
- `public.wearable_samples` (Biometrie-Rohdaten)
- `public.video_clips` (Video-Referenzen)

### 2.2 Kryptografisches Shredding (Pseudonymisierung)

Für Daten, die aus technischen Gründen nicht vollständig gelöscht werden können (z.B. in `audit_log`):

```sql
-- Pseudonymisierung: personenbezogene Felder werden überschrieben
UPDATE app.audit_log SET actor_id = NULL WHERE actor_id = :person_id;
UPDATE app.access_denials SET actor_id = NULL WHERE actor_id = :person_id;
UPDATE public.access_log SET viewer_profile_id = NULL WHERE viewer_profile_id = :profile_id;
```

**Hinweis:** Kryptografisches Shredding ist **Pseudonymisierung**, keine Anonymisierung (Art. 4 Nr. 5 DSGVO). Die Daten bleiben im System, sind aber nicht mehr einer natürlichen Person zuordenbar.

### 2.3 Vollständige Löschung (Hard Delete)

**Auslöschung aller Resten nach Ablauf der Aufbewahrungsfristen:**

```sql
-- Audit-Logs nach 3 Jahren
DELETE FROM app.audit_log WHERE occurred_at < NOW() - INTERVAL '3 years';
DELETE FROM public.access_log WHERE at < NOW() - INTERVAL '1 year';

-- Access-Denials nach 1 Jahr
DELETE FROM app.access_denials WHERE occurred_at < NOW() - INTERVAL '1 year';
```

---

## 3. Aufbewahrungsfristen

| Datenart | Frist | Beginn | Begründung |
|----------|-------|--------|------------|
| Check-In-Daten | 12 Monate | Vertragsende | Leistungsanalyse, Baseline-Update |
| Medizin-Records | 3 Jahre | Vertragsende | Versicherungsnachweis |
| Audit-Logs | 3 Jahre | Eintrag | Rechenschaftspflicht Art. 5 Abs. 2 |
| Access Logs | 1 Jahr | Eintrag | Sicherheitsüberwachung |
| Push-Tokens | bis Widerruf | Registrierung | Benachrichtigungsservice |
| Auth-Daten | 30 Tage | Vertragsende | Wartefrist für Wiederaufnahme |

---

## 4. Ausnahmen vom Recht auf Löschung (Art. 17 Abs. 3 DSGVO)

Die Löschung kann verzögert oder abgelehnt werden, wenn:

1. **Aufbewahrungspflichten** bestehen (z.B. handelsrechtliche Aufbewahrung von Strafen/Fines)
2. **Rechtsansprüche** geltend gemacht werden (z.B. Verletzungsfall, Versicherungsstreit)
3. **Audit-Logs** betroffen sind (Rechenschaftspflicht Art. 5 Abs. 2 erfordert Aufbewahrung)

In diesen Fällen erfolgt **Pseudonymisierung** statt Löschung.

---

## 5. Verantwortlichkeiten

| Rolle | Aufgabe |
|-------|---------|
| **Admin** | Löschung anstoßen (via Supabase Dashboard oder RPC) |
| **Arzt** | Medizin-Records prüfen vor Löschung |
| **Datenschutz** | Löschung dokumentieren, Bestätigung an Betroffenen senden |
| **Supabase** | Automatische CASCADE-Löschung via FK-Constraints |

---

## 6. Löschbestätigung

Nach Abschluss der Löschung erhält der Betroffene eine Bestätigung mit:

- Datum der Löschung
- Umfang der gelöschten Daten
- Ausnahmen (falls Pseudonymisierung statt Löschung)
- Name des Verantwortlichen

---

## 7. Technische Trigger

### 7.1 Automatische Löschung (Supabase Edge Function)

```typescript
// supabase/functions/shred-person/index.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req) => {
  const { person_id } = await req.json()
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  // 1. Auth-User löscht (CASCADE auf profiles, players)
  const { data: person } = await supabase
    .from('app.persons')
    .select('auth_user_id')
    .eq('id', person_id)
    .single()

  if (person?.auth_user_id) {
    await supabase.auth.admin.deleteUser(person.auth_user_id)
  }

  // 2. App-Person löscht (CASCADE auf role_assignments, medical_clearances)
  await supabase.from('app.persons').delete().eq('id', person_id)

  // 3. Pseudonymisierung in Audit-Logs
  await supabase.from('app.audit_log').update({ actor_id: null }).eq('actor_id', person_id)

  return new Response(JSON.stringify({ success: true }), {
    headers: { 'Content-Type': 'application/json' }
  })
})
```

### 7.2 Retention-Job (pg_cron)

```sql
-- Audit-Logs nach 3 Jahren löscht
SELECT cron.schedule(
  'retention-audit-log',
  '0 3 * * *',  -- täglich um 03:00
  $$DELETE FROM app.audit_log WHERE occurred_at < NOW() - INTERVAL '3 years'$$
);

-- Access-Denials nach 1 Jahr löscht
SELECT cron.schedule(
  'retention-access-denials',
  '0 3 * * *',
  $$DELETE FROM app.access_denials WHERE occurred_at < NOW() - INTERVAL '1 year'$$
);
```

---

*Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.*
*Stand: 2026-09-18*
