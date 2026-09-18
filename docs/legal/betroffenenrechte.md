# Betroffenenrechte — Team Performance OS

> **Status:** Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.
> **Stand:** 2026-09-18

---

## 1. Überblick

Betroffene Personen (Spieler, Trainer, Medizinpersonal) haben nach der DSGVO folgende Rechte:

| Recht | Artikel | Beschreibung |
|-------|---------|--------------|
| Auskunft | Art. 15 | Kopie aller gespeicherten Daten |
| Berichtigung | Art. 16 | Korrektur unrichtiger Daten |
| Löschung | Art. 17 | Löschung nach Ende der Verarbeitung |
| Einschränkung | Art. 18 | Sperrung der Verarbeitung |
| Datenübertragbarkeit | Art. 20 | Export in maschinenlesbarem Format |
| Widerspruch | Art. 21 | Widerspruch gegen Verarbeitung |
| Beschwerde | Art. 77 | Beschwerde bei Aufsichtsbehörde |

---

## 2. Auskunftsrecht (Art. 15 DSGVO)

### 2.1 Anforderungen
- Betroffener stellt Anfrage per E-Mail an den Verantwortlichen
- Identitätsprüfung (z.B. durch Vergleich mit hinterlegter E-Mail)
- Antwort innerhalb von **30 Tagen**

### 2.2 Bereitstellung der Daten

**Automatisch (via App):**
- Spieler kann seine eigenen Daten jederzeit in der App einsehen
- Check-In-Historie, Baseline, Readiness-Score, LoadDeviation

**Manuell (per E-Mail an Verantwortlichen):**
- Vollständiger Export via `data_portability_export()` (Art. 20)
- Audit-Logs (wer hat wann welche Daten gesehen)
- Medizin-Records (vollständig)

### 2.3 Format
- JSON (maschinenlesbar)
- PDF (Mensch-lesbar, auf Anfrage)

---

## 3. Recht auf Berichtigung (Art. 16 DSGVO)

### 3.1 Selbst-Service (via App)
- Spieler kann eigene Check-In-Daten korrigieren (solange nicht älter als 24h)
- Spieler kann Entwicklungs-Ziele aktualisieren

### 3.2 Admin-Service
- Stammdaten (Name, Geburtsdatum) nur durch Admin änderbar
- Medizin-Records nur durch Arzt/Physio änderbar
- Änderungen werden im `audit_log` dokumentiert

### 3.3 Prozess
1. Betroffener meldet Berichtigungswunsch (E-Mail oder App)
2. Admin prüft und korrigiert
3. Bestätigung an Betroffenen
4. `audit_log` dokumentiert die Änderung

---

## 4. Recht auf Löschung (Art. 17 DSGVO)

Siehe separates Dokument: [`loeschkonzept.md`](./loeschkonzept.md)

### 4.1 Auslöser
- Vertragsende
- Widerruf der Einwilligung
- Auskunftsbegehren des Betroffenen

### 4.2 Ausnahmen (Art. 17 Abs. 3)
- Aufbewahrungspflichten (z.B. handelsrechtliche Aufbewahrung)
- Rechtsansprüche (z.B. Verletzungsfall)
- Audit-Logs (Rechenschaftspflicht)

---

## 5. Recht auf Einschränkung (Art. 18 DSGVO)

### 5.1 Voraussetzungen
- Streit über Richtigkeit der Daten
- Verarbeitung ist unrechtmäßig, aber Löschung wird abgelehnt
- Verantwortlicher benötigt die Daten nicht mehr, aber Betroffener schon

### 5.2 Umsetzung
- Daten werden in `app.persons` als `is_active = false` markiert
- Keine neuen Check-Ins möglich
- Bestehende Daten bleiben für Audit-Zwecke erhalten

---

## 6. Recht auf Datenübertragbarkeit (Art. 20 DSGVO)

### 6.1 Automatisch (via App)
- Spieler kann seine Daten als JSON exportieren
- RPC: `app.rpc_export_my_data()` (nur für self oder admin)

### 6.2 Umfang
```json
{
  "exported_at": "2026-09-18T12:00:00Z",
  "player": { "id": "...", "first_name": "...", "last_name": "..." },
  "daily_checkins": [...],
  "baselines": [...],
  "readiness_scores": [...],
  "load_deviations": [...],
  "session_loads": [...],
  "attendance": [...],
  "development_goals": [...],
  "medical_records": [...],
  "fines": [...],
  "wearable_samples": [...],
  "video_clips": [...],
  "access_log": [...]
}
```

### 6.3 Format
- JSON (maschinenlesbar)
- CSV (auf Anfrage, für Tabellenkalkulation)

---

## 7. Widerspruchsrecht (Art. 21 DSGVO)

### 7.1 Widerspruch gegen berechtigtes Interesse
- Betroffener kann der Verarbeitung auf Grundlage von Art. 6 Abs. 1 lit. f widersprechen
- Gründe: besondere Situation des Betroffenen

### 7.2 Auswirkung
- Verarbeitung wird eingestellt, es sei denn, es gibt zwingende schutzwürdige Gründe
- Im Besäftigungskontext (Art. 88 DSGVO) ist der Widerspruch eingeschränkt

### 7.3 Widerspruch gegen Direktwerbung
- TPOS nutzt keine Direktwerbe-Maßnahmen
- Push-Nachrichten dienen nur dem Check-In-Reminder (berechtigtes Interesse)

---

## 8. Beschwerderecht (Art. 77 DSGVO)

Betroffene können sich bei der zuständigen Aufsichtsbehörde beschweren:

**Zuständige Behörde:**
[Landesdatenschutzbeauftragte einfügen]
Adresse: [einfügen]
E-Mail: [einfügen]

---

## 9. Antragstellung

### 9.1 Kontakt
**Verantwortlicher:** Christopher Klan / Cloudchris
**E-Mail:** [Datenschutz-E-Mail]
**Adresse:** [einfügen]

### 9.2 Erforderliche Informationen
- Name und Kontaktdaten des Betroffenen
- Art des Rechts (Auskunft, Berichtigung, Löschung, etc.)
- Identitätsnachweis (z.B. Kopie des Personalausweises oder Bestätigung der E-Mail)

### 9.3 Fristen
- Bestätigung des Eingangs: **48 Stunden**
- Bearbeitung: **30 Tage** (verlängerbar um 60 Tage bei komplexen Anfragen)

---

## 10. Dokumentation

Alle Anträge und deren Bearbeitung werden dokumentiert:

| Feld | Beschreibung |
|------|--------------|
| Antragsdatum | Datum des Eingangs |
| Art des Rechts | Art. 15/16/17/18/20/21 |
| Betroffener | Name, Spieler-ID |
| Bearbeiter | Admin-Name |
| Bearbeitungsdatum | Datum der Erledigung |
| Ergebnis | Erfolgreich / Abgelehnt / Teilweise |

---

*Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.*
*Stand: 2026-09-18*
