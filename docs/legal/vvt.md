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
| Darstellungspräferenz Body Map | `app.persons.body_map_figure` | Welche der drei Silhouetten dem Spieler angezeigt wird (`aus_dem_team`, `weiblich`, `maennlich`, `neutral`). **Kein Geschlechtsfeld:** die Angabe trägt außerhalb der Zeichnung keine Bedeutung, wird nirgends ausgewertet und ist für niemanden im Team sichtbar außer der Person selbst. Vorgabe `aus_dem_team` folgt `app.teams.squad_type`, einer Eigenschaft der Mannschaft (AP-43) |

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
| Body-Map-Regionen | `public.daily_checkins` (JSON), `app.daily_checkins.body_map` (JSON) | Schmerz-Lokalisation |
| Tippunkt auf der Silhouette | `app.daily_checkins.body_map[].point` (JSON) | Stelle innerhalb der Region, auf die der Spieler selbst gezeigt hat. Zwei Koordinaten von 0 bis 1, normiert auf die Zeichnung, nicht auf den Bildschirm. Rein beschreibend: nichts rechnet damit, der Bereitschaftswert liest ihn nicht (AP-43) |
| Figur der Silhouette | `app.daily_checkins.body_map[].svg` (JSON) | Welche Zeichnung und welche Version der Punkt meint, zum Beispiel `weiblich_vorne@1`. Ohne sie wäre der Punkt nach einer Überarbeitung der Zeichnung nicht mehr lesbar |

### 3.4 Protokolldaten
| Datenfeld | Tabelle | Zweck |
|-----------|---------|-------|
| Wer hat wann welche Daten gesehen | `public.access_log`, `app.audit_log` | Rechenschaftspflicht Art. 5 Abs. 2 |
| Zugriffsverweigerungen | `app.access_denials` | Compliance-Metrik |
| Push-Token | Expo Push Service | Benachrichtigung |

### 3.5 Daten der KI-Ebene (ADR-019, Entwurf, noch nicht angenommen)
| Datenfeld | Tabelle | Zweck |
|-----------|---------|-------|
| Hinweis aus Signal oder Einordnung (Regel- bzw. Signal-ID, Einordnungsklasse, Sichtungsreihenfolge, Konfidenz, Modellversion, Status offen/übernommen/verworfen, Bearbeiter) | `app.signal_hints` (Arbeitsname) | Sichtung durch Physio und Arzt, Vorstufe zum Freigabevorschlag. **Art. 9 DSGVO**, wenn aus Art.-9-Eingaben abgeleitet. Nur `physio` und `doctor` lesen, jeder Lesezugriff in `app.access_log` |
| Aufrufprotokoll Modellaufrufe (Zeitpunkt, Zweck, Auslöser, betroffene Personen, Anbieter, Modell und Version, Hash der Eingabe, Ergebnisklasse), **ohne Inhalt** | `app.model_call_log` (Arbeitsname) | Rechenschaftspflicht Art. 5 Abs. 2, Nachvollziehbarkeit, Reproduzierbarkeit |
| Kennzeichen Vorbefüllung (vorbefüllt ja/nein, geändert ja/nein) | am Check-in (`app.daily_checkins`, Spalte noch festzulegen) | Messung der Check-in-Beschleunigung (AP-67). Keine Modellwerte, nur die Tatsache der Vorbefüllung |
| Check-in-Freitext (nur falls ADR-019 Entscheidung E5 angenommen wird) | eigene medizinseitige Tabelle, **nicht** `app.daily_checkins` | Einordnung durch JEV (AP-65), Sichtung durch Medizin. **Art. 9 DSGVO** |

**Nicht gespeichert:** Prompts, an das Modell gesendete Rohtexte, Rohantworten, Reasoning-Spuren, Antworten auf Trainerfragen, Audio aus dem Diktat (die Spracherkennung läuft auf dem Gerät).

---

## 4. Kategorien von Empfängern

| Empfänger | Daten | Rechtsgrundlage |
|-----------|-------|-----------------|
| Supabase Inc. | Alle DB-Daten | Art. 28 (Auftragsverarbeiter) |
| Vercel Inc. | Web-Logs, Session-Daten | Art. 28 (Auftragsverarbeiter) |
| Expo Inc. | Push-Tokens | Art. 28 (Auftragsverarbeiter) |
| Modellaufrufe: Anbieter des Klassifikationsmodells JEV (TypeSafe, ADR-019 Entscheidung E3 vom 2026-09-27: Einbau mit Ein/Aus-Schalter, Echtdaten ausdrücklich VOR Abschluss eines AVV erlaubt — bewusste Ausnahme, Risiko bei Chris/Unternehmen, siehe ADR-019 §3.6 Warnkasten) | Pseudonymisierte Auszüge aus Check-in, Body Map, ggf. Freitext (Art. 9), einzeln je Aufruf | Art. 28 (Auftragsverarbeiter), **AVV bleibt Ziel, ist aber keine Vorbedingung mehr für den Start (E3-Ausnahme)**. Bei Betrieb in eigener Infrastruktur entfällt der Empfänger |
| Modellaufrufe AP-69 Plan gegen Zustand: OpenRouter Inc. (Router) weiter an TypeSafe (JEV, `typesafe/jev-1.13`). Zweite bewusste Ausnahme von ADR-019 §3.6 vom 2026-09-27: Router ohne AVV mit TPOS, von Chris im Chat bestätigt, gleiche Risikolage wie E3 (bei Chris/Unternehmen), direkter TypeSafe-Weg mit AVV bleibt Ziel. Läuft nur mit Betreiber-Notaus an (`JEV_ENABLED`) UND Team-Schalter `jev_squad_check_enabled` (setzt nur `admin`), Standard aus | Je Aufruf nur Spielerinnen aus der vollen Gruppe mit offenem Hinweis, pseudonymisiert (zufälliges Kürzel je Aufruf): Readiness-Band, geplante Last gegen eigene Norm als Stufe, Schlüssel freigegebener Lastabweichungen der letzten 7 Tage (nie `pain_max`), dazu Dauer, Intensität und Art der Einheit. Nie Name, Rückennummer, Position, Freigabestatus, Score-Zahl, Faktoren, Check-in-Status, Body Map oder Schmerzwert. Kein Inhalt wird gespeichert, nur `app.model_call_log`/`app.model_call_subjects` ohne Inhalt (§3.5) | Art. 28 angestrebt, **AVV liegt weder mit OpenRouter noch mit TypeSafe vor (Ausnahme, siehe links)**. Betrifft Art.-9-nahe Daten (Band). Verarbeitungsort bei OpenRouter nicht vertraglich auf EU/EWR festgelegt, siehe §5 |
| Modellaufrufe: Anbieter des Reasoning-Modells für Trainerfragen (Anbieter nach ADR-019 Entscheidung E3) | Pseudonymisierte Antworten der Trainer-Türen (Band, Freigabe-Badge, Anwesenheit, freigegebene Abweichungen). Nie Body Map, Freitext, Schmerzwert oder Score-Zahl | Art. 28, Bedingungen wie oben |

> **Ausgeschlossen als Empfänger personenbezogener Daten (ADR-019 §3.6):** kostenlose Modellendpunkte, Modell-Router oder Anbieter ohne AVV, auch bei pseudonymisierten Daten — davon unberührt ist die E3-Ausnahme für TypeSafe/JEV selbst (siehe oben).

---

## 5. Übermittlung in Drittlände

| Anbieter | Standort | Mechanismus |
|----------|----------|-------------|
| Supabase | USA (Frankfurt-Region) | SCC (Standard Contractual Clauses) |
| Vercel | USA | SCC |
| Expo | USA | SCC |
| OpenRouter (AP-69, Router zu TypeSafe/JEV) | USA, Verarbeitungsort nicht vertraglich festgelegt | **Kein Mechanismus vereinbart** (kein AVV, keine SCC). Teil der bewussten Ausnahme von ADR-019 §3.6 vom 2026-09-27, Risiko bei Chris/Unternehmen. Vor Livegang beim Kunden zu schließen (AVV/SCC oder Wechsel auf den direkten TypeSafe-Weg in EU/EWR) |
| Modellanbieter (ADR-019, Entscheidung E3 vom 2026-09-27 entschieden, E4 EU-AI-Act/BetrVG weiterhin offen) | **EU/EWR vorausgesetzt** | Keine Drittlandübermittlung vorgesehen. Ein Anbieter mit Verarbeitung außerhalb EU/EWR ist für Personenbezug ausgeschlossen |

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
| Hinweise, verworfen oder unbearbeitet | 90 Tage (ab Erzeugung) | Zweck mit Sichtung erledigt (ADR-019, Entwurf) |
| Hinweise, übernommen als Vorschlag | wie Medizin-Records (Vertragsende + 3 Jahre) | Herkunftsnachweis des Freigabevorschlags (ADR-019, Entwurf) |
| Aufrufprotokoll Modellaufrufe | 1 Jahr (ab Eintrag) | Rechenschaftspflicht, analog Access Logs (ADR-019, Entwurf) |
| Kennzeichen Vorbefüllung | wie Check-In-Daten | Teil des Check-ins (ADR-019, Entwurf) |
| Prompts, Rohantworten, Antworten Trainerfragen | keine Speicherung | flüchtig; beim Anbieter vertraglich 0 Tage (ADR-019, Entwurf) |

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

### 7.6 KI-Ebene (ADR-019, Entwurf)
- Kein Modell hat Datenbankzugriff. Modellwerkzeuge sind ausschließlich die rollengeprüften Türen in `public`, aufgerufen mit dem JWT der anfragenden Person
- Batch-Einordnung nur über eng geschnittene Lese- und Schreibfunktionen, Ergebnisse nur in die medizinseitige Hinweisliste
- Kein `service_role` Key im Prozess, der ein Modell aufruft
- Pseudonymisierung im Gateway (Platzhalter statt Namen und IDs, Rückübersetzung serverseitig)
- Geschlossene Ausgabelisten, Validierung vor dem Speichern, Modellversion festgeschrieben
- Keine Speicherung von Prompts und Rohantworten, Request-Bodies im Gateway nicht geloggt
- Keine automatisierte Entscheidung (Art. 22): jede Konsequenz setzt ein Mensch im protokollierten Freigabepfad
- Tests: Rollenmatrix Hinweisliste, kein Schreibpfad in Freigaben, Grep auf verbotene Schlüssel in Modellantworten, Löschpfad erfasst die neuen Tabellen

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

**Nachtrag KI-Ebene (ADR-019, Entwurf):** Die Einordnung von Gesundheitsdaten Beschäftigter durch ein Modell (AP-65) und die modellgestützte Gruppenzuordnung (AP-69) sind in der DSFA eigens zu bewerten. Zusätzlich zu prüfen: Einordnung nach EU AI Act Anhang III Nr. 4 und Mitbestimmung (§ 87 Abs. 1 Nr. 6 BetrVG) über die Betriebsvereinbarung. Livegang der KI-Ebene beim Kunden erst nach dieser Prüfung.

---

*Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.*
*Stand: 2026-09-18*
