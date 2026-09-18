# Team Performance OS — DSGVO-Dokumentation

> **Status:** Entwurf zur juristischen Prüfung. Keine verbindliche Rechtberatung.
> **Stand:** 2026-09-18
> **Verantwortlich:** Christopher Klan (cloudchris / KlanLabs)

Diese Dokumentation beschreibt die datenschutzrechtliche Basis für das **Team Performance OS (TPOS)** — eine B2B-Sportsoftware für Bundesliga-Kader zur täglichen Leistungs- und Gesundheitsüberwachung.

## Dokumente im Ordner

| Datei | Inhalt | Rechtsgrundlage |
|-------|--------|-----------------|
| [`datenschutzerklaerung.md`](./datenschutzerklaerung.md) | Informationen für Betroffene (Spieler, Trainer, Medizin) | Art. 13, 14 DSGVO |
| [`vvt.md`](./vvt.md) | Verzeichnis von Verarbeitungstätigkeiten | Art. 30 DSGVO |
| [`loeschkonzept.md`](./loeschkonzept.md) | Lösch- und Aufbewahrungsregeln | Art. 5 Abs. 1 lit. e, Art. 17 DSGVO |
| [`betroffenenrechte.md`](./betroffenenrechte.md) | Prozesse für Auskunft, Berichtigung, Löschung, Widerspruch | Art. 15–22 DSGVO |

## Architektur-Überblick

```
[Spieler] (Expo App)  →  Supabase (PostgreSQL, EU/Frankfurt)  →  [Trainer] (Next.js Web)
                              │
                              ├── public.*  (Check-In, Baseline, Medizin, Training)
                              └── app.*     (persons, role_assignments, medical_clearances)
```

- **Datenbank:** Supabase auf AWS `eu-central-1` (Frankfurt), Projekt `sxpfetwrqqwqijapgkcd`
- **Hosting Web:** Vercel (US, SCC erforderlich)
- **Mobile:** Expo (US, SCC erforderlich)
- **Push:** Expo Push Services (US)
- **Auth:** Supabase Auth (Magic Link)

## Betroffene Gruppen

| Rolle | Beschreibung | Rechtsstatus |
|-------|--------------|--------------|
| **Spieler** | Profi-Fußballer im Kader | Beschäftigter (Art. 88 DSGVO) |
| **Trainer/Coach** | Verantwortlich für Training & Taktik | Beschäftigter |
| **Athletiktrainer** | Leistungsdiagnostik & Kondition | Beschäftigter |
| **Physiotherapie** | Reha & Prävention | Beschäftigter |
| **Arzt** | Medizinische Clearances | Beschäftigter |
| **Admin** | Systemverwaltung (Audit-only auf Medizin) | Beschäftigter |

## Kritische Punkte (juristische Prüfung erforderlich)

1. **Betriebsvereinbarung:** Alle Verarbeitungen laufen über Art. 88 DSGVO + § 26 BDSG. Eine Betriebsvereinbarung mit dem Spielerrat liegt noch nicht vor.
2. **DSFA:** Eine Datenschutz-Folgenabschätzung ist wegen Art. 9-Verarbeitung (Gesundheitsdaten) verpflichtend und wurde noch nicht erstellt.
3. **Drittland-Übermittlung:** Vercel und Expo Server in den USA. Standardvertragsklauseln (SCC) müssen vertraglich vereinbart sein.
4. **Push-Token:** Expo Push Tokens sind personenbezogen und unterliegen der DSGVO.
5. **Wearable-Daten:** `wearable_samples.raw` (JSONb) kann sensible Biometrie-Daten enthalten.

## Open Juristische Items

- [ ] Betriebsvereinbarung mit Spielerrat abschließen
- [ ] DSFA für Art. 9-Verarbeitung erstellen
- [ ] SCC mit Vercel vertraglich bestätigen
- [ ] SCC mit Expo vertraglich bestätigen
- [ ] Aufbewahrungsfristen für `access_log` und `audit_log` festlegen (nach DSGVO max. 3 Jahre empfohlen)

## Technische Sicherheitsmaßnahmen

- **RLS:** Row-Level Security auf allen Tabellen (`ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY`)
- **Spaltenrechte:** `birth_date` auf `app.persons` explizit gesperrt (Grant-Liste ohne diese Spalte)
- **Audit-Trail:** `audit_log` (append-only via Trigger) dokumentiert INSERT/UPDATE/DELETE auf `persons` und `medical_clearances`
- **Zugriffsmetrik:** `access_denials` protokolliert verbotene Zugriffsversuche
- **Export:** `data_portability_export()` (Art. 20 DSGVO) für Spieler und Admin
- **Pseudonymisierung:** `profiles.player_id` als Trennung zwischen Auth- und Spieler-Datensatz
- **Feld-Level-Gate:** `daily_checkins_staff`-View blendet `free_text` bei `med_only` für Nicht-Med-Rollen aus
- **Medizin-View:** `medical_status_view` zeigt nur `(player_id, clearance, visibility, updated_at)` — keine Diagnosen/Symptome

## Versionshistorie

| Datum | Änderung | Autor |
|-------|----------|-------|
| 2026-09-18 | Initialer Entwurf erstellt | Hermes (Claude) |
