# Verzeichnis von Verarbeitungstätigkeiten (VVT) — Team Performance OS

> **Status:** Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.
> **Stand:** 2026-09-18
> **Verantwortlich:** Christopher Klan (Cloudchris / KlanLabs)

---

## 1. Gegenstand der Verarbeitung

**Zweck:** Bereitstellung einer digitalen Plattform zur täglichen Leistungs- und Gesundheitsüberwachung von Profi-Fußballern im Kader eines Sportvereins.

**Rechtsnutzung:** TPOS wird vom Verein/Betrieb als Arbeitsmittel im Rahmen des Beschäftigungsverhältnisses eingesetzt.

---

## 2. Kategorien betroffener Personen

| Kategorie | Beschreibung | Anzahl (geschätzt) |
|-----------|--------------|-------------------|
| Spieler | Aktive Profis im Kader | 15–30 pro Team |
| Trainer | Chef- und Co-Trainer | 2–5 pro Team |
| Medizinpersonal | Arzt, Physio, Athletic Coach | 3–8 pro Team |
| Admin | IT-Verantwortlicher | 1–2 pro Team |

---

## 3. Kategorien personenbezogener Daten

### 3.1 Stammdaten (Art. 6 Abs. 1 lit. b)
| Datenfeld | Tabelle | Zweck |
|-----------|---------|-------|
| Name | `app.persons.display_name`, `public.players.first_name`, `public.players.last_name`, `public.profiles.full_name` | Identifikation |
| Geburtsdatum | `public.players.birth_date`, `app.persons.birth_date` | Altersgruppen-Analyse |
| E-Mail | `public.profiles.email` | Auth, Magic Link |
| Trikotnummer | `public.players.squad_number`, `app.persons.shirt_number` | Identifikation im Kader |
| Position | `public.players.position`, `app.persons.person_position` | Team-Organisation |
| Auth-ID | `app.persons.auth_user_id`, `public.profiles.id` | Authentifizierung |

### 3.2 Leistungsdaten (Art. 6 Abs. 1 lit. f)
| Datenfeld | Tabelle | Zweck |
|-----------|---------|-------|
| Schlaf, Regeneration, Body Map, Mental, Bereitschaft | `public.daily_checkins` | Täglicher Check-In |
| Baseline-Werte | `public.baselines` | Langzeittrend-Analyse |
| Readiness-Score | `public.readiness_scores` | Morning-Briefing |
| Load Deviation | `public.load_deviations` | Belastungswarnung |
| RPE | `public.session_loads` | Trainingsbelastung |

### 3.3 Gesundheitsdaten (Art. 9 DSGVO)
| Datenfeld | Tabelle | Zweck |
|-----------|---------|-------|
| Medical Clearance Status | `app.medical_clearances.status` | Freigabe-Management |
| Belastungshinweis | `app.medical_clearances.load_note` | Trainer-Information |
| Diagnose | `public.medical_records.diagnosis` | Medizinische Dokumentation |
| Symptome | `public.medical_records.symptoms` | Medizinische Dokumentation |
| Behandlung | `public.medical_records.treatment` | Medizinische Dokumentation |
| Body-Map-Regionen | `public.daily_checkins` (JSON) | Schmerz-Lokalisation |

### 3.4 Protokolldaten
| Datenfeld | Tabelle | Zweck |
|-----------|---------|-------|
| Wer hat wann welche Daten gesehen | `public.access_log`, `app.audit_log` | Rechenschaftspflicht Art. 5 Abs. 2 |
| Zugriffsverweigerungen | `app.access_denials` | Compliance-Metrik |
| Push-Token | Expo Push Service | Benachrichtigung |

---

## 4. Kategorien von Empfängern

| Empfänger | Daten | Rechtsgrundlage |
|-----------|-------|-----------------|
| Supabase Inc. | Alle DB-Daten | Art. 28 (Auftragsverarbeiter) |
| Vercel Inc. | Web-Logs, Session-Daten | Art. 28 (Auftragsverarbeiter) |
| Expo Inc. | Push-Tokens | Art. 28 (Auftragsverarbeiter) |

---

## 5. Übermittlung in Drittlände

| Anbieter | Standort | Mechanismus |
|----------|----------|-------------|
| Supabase | USA (Frankfurt-Region) | SCC (Standard Contractual Clauses) |
| Vercel | USA | SCC |
| Expo | USA | SCC |

---

## 6. Löschfristen

| Datenart | Frist | Begründung |
|----------|-------|------------|
| Check-In-Daten | Vertragsende + 12 Monate | Leistungsanalyse, Baseline-Update |
| Medizin-Records | Vertragsende + 3 Jahre | Versicherungsnachweis |
| Audit-Logs | 3 Jahre (ab Eintrag) | Rechenschaftspflicht |
| Access Logs | 1 Jahr (ab Eintrag) | Sicherheitsüberwachung |
| Push-Tokens | bis Widerruf | Benachrichtigungsservice |
| Auth-Daten | Vertragsende + 30 Tage | Wartefrist |

---

## 7. Beschreibung der technischen und organisatorischen Maßnahmen

### 7.1 Zugriffskontrolle (Art. 25 DSGVO)
- Row-Level Security auf allen Tabellen
- Role-based Access (6 Rollen nach ADR-009)
- Keine gemeinsame Nutzung von Accounts
- Magic-Link-Auth (kein Passwort-Management)

### 7.2 Verschlüsselung (Art. 32 DSGVO)
- TLS 1.3 in Transit
- AES-256 at Rest (Supabase Managed)
- Keine clientseitige Verschlüsselung erforderlich (Datacenter-Level)

### 7.3 Integrität (Art. 5 Abs. 1 lit. f)
- Triggermechanismus für `updated_at`
- Append-only `audit_log` via Trigger
- Constraints (CHECK, UNIQUE, FK) auf DB-Ebene

### 7.4 Verfügbarkeit (Art. 5 Abs. 1 lit. f)
- Supabase 99.99% SLA
- Automatische Backups (7 Tage Retention)
- PITR (Point-in-Time Recovery)

### 7.5 Evaluierung (Art. 32 Abs. 1 lit. d)
- Regelmäßige Review der RLS-Policies (pgTAP-Tests)
- Audit-Metrik (`access_denials` als Compliance-KPI)

---

## 8. Verantwortlicher

**Verantwortlicher:** Christopher Klan / Cloudchris (Einzelunternehmen)
**Adresse:** [einfügen]
**E-Mail:** [Datenschutz-E-Mail]
**Vertretungsberechtigt:** Christopher Klan

---

## 9. Datenschutz-Folgenabschätzung

**Erforderlich:** Ja (Art. 35 DSGVO) — Verarbeitung von Gesundheitsdaten (Art. 9) im großen Maßstab.

**Status:** Wird erstellt / liegt noch nicht vor.

---

*Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.*
*Stand: 2026-09-18*
