# Datenschutzerklärung — Team Performance OS

> **Status:** Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.
> **Stand:** 2026-09-18

---

## 1. Verantwortlicher

**Verantwortlicher im Sinne der DSGVO:**
Christopher Klan / Cloudchris (Einzelunternehmen)
[Adresse einfügen]
E-Mail: [Datenschutz-E-Mail einfügen]
Telefon: [einfügen]

Datenschutzbeauftragter: Nicht benannt (Pflicht nur bei ≥20 Personen mit automatischer Verarbeitung — Art. 37 Abs. 1 lit. b DSGVO).

---

## 2. Welche Daten werden verarbeitet?

### 2.1 Stammdaten
- Name, Geburtsdatum (nur für Arzt/Physio sichtbar), Trikotnummer, Position
- E-Mail und Telefon (optional, für Team-Kommunikation)

### 2.2 Leistungsdaten (täglicher Check-In)
- Schlafdauer, Schlafqualität
- Muskelkater, Stimmung, Stress, Energie (Skala 1-10)
- Freitext (optional, mit Sichtbarkeitsstufe: `team` / `staff` / `med_only`)

### 2.3 Medizinische Daten (sensibel nach Art. 9 DSGVO)
- Medical Clearance Status (full/limited/individual/blocked)
- Belastungshinweise (load_note — keine Diagnose)
- Medizinische Records (Kategorie, Diagnose, Symptome, Behandlung, Reha-Plan)
- Body-Map-Daten (Check-In Schmerzregionen)

### 2.4 Trainings- und Belastungsdaten
- RPE (Rate of Perceived Exertion) pro Trainingseinheit
- Berechnete Readiness-Scores (0-100)
- Baseline-Metriken (Rolling Average)
- Trainingshistorie und Teilnahme

### 2.5 Systemdaten
- Supabase Auth-ID
- Rolle (player, coach, athletic_coach, physio, doctor, admin)
- Zugriffsprotokolle (`access_log`)
- Audit-Trail (`audit_log`)

---

## 3. Rechtsgrundlage

### 3.1 Art. 6 Abs. 1 lit. b DSGVO (Vertrag)
- TPOS wird im Rahmen des Arbeitsverhältnisses (Spieler, Trainer) genutzt.

### 3.2 Art. 6 Abs. 1 lit. f DSGVO (Berechtigtes Interesse)
- Berechnung von Scores und Baselines zur Leistungsoptimierung
- Audit-Logging zur Sicherstellung der Datensicherheit

### 3.3 Art. 9 Abs. 2 lit. b DSGVO i.V.m. Art. 88 DSGVO + § 26 BDSG
- Gesundheitsdaten (Art. 9) werden im Beschäftigungskontext verarbeitet.
- **Erforderlich:** Betriebsvereinbarung mit dem Spielerrat.

### 3.4 Art. 9 Abs. 2 lit. a DSGVO (Einwilligung)
- Optionaler Freitext mit `med_only`-Flag: Der Spieler kann selbst bestimmen, ob der Text nur für Medizin-Personal sichtbar ist.

---

## 4. Wer hat Zugriff? (Rollen-Matrix)

| Rolle | Spieler-Stammdaten | Check-In | Medizin-Records | Clearance | Audit-Log |
|-------|-------------------|----------|-----------------|-----------|-----------|
| **Spieler** | nur eigene | nur eigene | nur eigene | nur eigenen | nie |
| **Trainer** | alle | alle | keine | nur Badge+Note | nie |
| **Athletiktrainer** | alle | alle | keine | nur Badge+Note | nie |
| **Physio** | alle | alle | alle | alle | nie |
| **Arzt** | alle | alle | alle (inkl. Schreiben) | alle (inkl. Schreiben) | nie |
| **Admin** | alle | alle (keine Schreibrechte) | nur lesend | alle | alle |

**Row-Level Security (RLS):** Alle Zugriffe werden auf Datenbankebene durch Policies erzwungen. Keine Policy kann durch Client-Code umgangen werden.

---

## 5. Speicherdaten

| Datenart | Speicherdauer | Begründung |
|----------|---------------|------------|
| Check-In-Daten | Ende Vertrag + 1 Jahr | Leistungsanalyse, Baseline-Update |
| Medizin-Records | Ende Vertrag + 3 Jahre | Nachweis für Versicherungsfälle |
| Audit-Logs | 3 Jahre | Rechenschaftspflicht Art. 5 Abs. 2 |
| Access Logs | 1 Jahr | Sicherheitsüberwachung |
| Push-Tokens | bis Widerruf | Erforderlich für Benachrichtigungen |
| Auth-Daten | Ende Vertrag + 30 Tage | Wartefrist für Wiederaufnahme |

---

## 6. Weitergabe an Dritte

### 6.1 Auftragsverarbeiter (Art. 28 DSGVO)
| Anbieter | Standort | Zweck | SCC |
|----------|----------|-------|-----|
| Supabase Inc. | USA (EU/Frankfurt-Region) | Datenbank + Auth | erforderlich |
| Vercel Inc. | USA | Hosting Web-Admin | erforderlich |
| Expo Inc. | USA | Push-Notifications | erforderlich |

### 6.2 Keine Weitergabe an Dritte
- Keine Datenverkäufe
- Keine automatisierte Profiling für Werbezwecke
- Keine Datenübermittlung an Transfer-Agenturen oder Medien ohne explizite Einwilligung

---

## 7. Rechte der betroffenen Personen

| Recht | Beschreibung | Ausführung |
|-------|--------------|------------|
| **Auskunft (Art. 15)** | Kopie aller gespeicherten Daten | per E-Mail an DSB |
| **Berichtigung (Art. 16)** | Korrektur falscher Daten | über App (eigene Daten) oder DSB |
| **Löschung (Art. 17)** | Löschung nach Ende der Verarbeitung | über RPC `data_portability_export()` oder DSB |
| **Einschränkung (Art. 18)** | Sperrung der Verarbeitung | nur bei Streit über Richtigkeit |
| **Datenübertragbarkeit (Art. 20)** | Export in maschinenlesbarem Format | per RPC oder DSB (JSON) |
| **Widerspruch (Art. 21)** | Widerspruch gegen Verarbeitung | berechtigtes Interesse-Widerspruch möglich |
| **Beschwerde (Art. 77)** | Beschwerde bei Aufsichtsbehörde | zuständig: [Landesdatenschutzbeauftragte] |

---

## 8. Datensicherheit

- **Verschlüsselung:** HTTPS/TLS in Transit; AES-256 at Rest (Supabase)
- **Authentifizierung:** Magic-Link (keine Passwörter gespeichert)
- **Zugriffskontrolle:** RLS + FORCE RLS auf allen Tabellen
- **Audit-Logging:** Vollständige Dokumentation aller Medizin-Zugriffe
- **Spalten-Level-Grants:** `birth_date` und Freitext-Felder separat geschützt

---

## 9. Änderungen

Diese Datenschutzerklärung wird bei Änderungen der Datenverarbeitung aktualisiert. Die jeweils aktuelle Version ist in der App und auf der Web-Konsole verfügbar.

---

*Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.*
*Stand: 2026-09-18*
