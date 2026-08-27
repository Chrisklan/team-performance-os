# Build-Contract: Player 360 Modul (6-Dimensionen-Aggregationsschicht) — TP-OS

Repo: /Users/christopherklan/local/03_Projects/Christopher/Apps/team-performance-os (Next.js 14 App Router, TypeScript, Tailwind).
Dur baust MIT dem Claude Max Account (OAuth), NICHT API-Token. Schreibe echten Code, kein Pseudo.

**WICHTIG — Workspace-Mismatch:** Das Kanban ticket zeigt workspace_path auf die golfbuxtehude-Astro-Site.
Das ist falsch: Player360 ist zu 100% Team Performance OS (MDR/RLS/SkillRating). Ziel-Repo ist team-performance-os.
Baue HIER. Der Mismatch wird separat auf dem Kanban-Board gemeldet.

**ERLAUBTE INFRA-ÄNDERUNG (kein Scope-Verstoss):** Das Repo hat noch KEINE Test-Infra.
Vitest ist nicht installiert. Du DARFST (und MUSST) `npm install -D vitest` ausführen und ggf. eine `vitest.config.ts` anlegen,
damit `lib/player360/player360.test.ts` lauffähig wird (DONE_WHEN verlangt die Tests zwingend).
Mehr als diese eine devDependency + deren Config änderst du nicht am Root-Setup.

## Pflicht-Quellen (lesen, im Repo vorhanden)
- lib/trainer/types.ts       — Datenmodell (CoachKaderPayload, KaderMember, MedicalStatus, ReadinessScore, PlayerBaseline)
- lib/trainer/fixtures.ts     — 14 Spieler Seed (Post-RLS, Coach-Sicht: KEINE Medical-Diagnosefelder)
- lib/trainer/api.ts          — fetchKaderForCoach(), FORBIDDEN_MEDICAL_KEYS, coachPayloadIsRlsClean()
- backend/RLS-MATRIX.md        — authoritative RLS-Regeln (player=own; coach OHNE medical_records roh + OHNE nicht-ACK'd load_deviations; arzt/physio=alle)
- tailwind.config.ts / app/globals.css — Design-Tokens (surface/card, accent #3E8EFF, warn, ok, ink, muted) + Reduced-Motion
- Modul-Player360.md + ADR-2026-08-27-player360-spec.md (im Vault) = Spezifikation

## Grundprinzip
Player 360 = REINE Aggregations-/Visualisierungsschicht über vorhandene, einzeln MDR-sichere Moduldaten.
- KEINE eigene Metrik/Risiko-Berechnung. KEINE Inference.
- Reine Read-Only-Sicht. Schreibzugriff NUR Audit-Log (Access-Log).
- Die Daten-Layer-Funktionen liefern Post-RLS-Payloads (wie api.ts/fixtures.ts etabliert).
  Echte DB/RLS kommt später; hier: reine TS-Funktionen + Fixtures + vitest (analog lib/trainer).

## Anzulegende Dateien (STRICTER FILE SCOPE — nur diese)

1. lib/player360/types.ts
   - Dimension-Typen: 'physical' | 'technical' | 'tactical' | 'mental' | 'availability' | 'development'
   - PlayerSkillRating: { id, player_id, dimension: 'technical'|'tactical'|'physical'|'mental', skill: string, score_1_5: number, rated_by: string, rated_at: string (date), }  // NEU, siehe Spec §4 Datenmodell-Lücke
   - Source-Entity-Typen (nur die für Aggregation nötigen Felder, gespiegelt aus RLS-Matrix):
     PlayerProfile (id, jersey, name, position, stammposition, nebenpositionen, groesse?, gewicht?, starker_fuss?, geburtsdatum?),
     MedicalRecordView (NUR: player_id, clearance: 'frei'|'eingeschraenkt'|'gesperrt'|null, visibility: 'green'|'yellow'|'orange'|'red'), // NICHT diagnosis/symptoms/treatment
     LoadDeviation (player_id, band, med_acknowledged: boolean, period), // gated
     DailyCheckIn (player_id, date, mental_stress, mental_motivation, mental_stimmung, mental_energy, sleep, recovery),
     ReadinessScore (player_id, date, value, factors),
     Baseline (player_id, metric, series: number[], rollingAvg),
     Attendance (player_id, date, status),
     DevelopmentGoal (player_id, category, title, progression_1_5, period_weeks),
     AccessLogEntry (id, viewer_profile_id, player_id, table_name, record_id, action, at)
   - Player360 (aggregiertes Ergebnis): player_id + sechs Dimension-Objekte { physical, technical, tactical, mental, availability, development }
   - Role-Typ: 'player' | 'coach' | 'athletik' | 'physio' | 'arzt' | 'admin'
   - AuditViewEntry: abgeleitet aus AccessLogEntry für "Wer hat meine Daten gesehen"

2. lib/player360/fixtures.ts
   - Vollständige Quell-Entities für ~3–4 Spieler (inkl. mind. 1 mit gated MedicalRecord + 1 nicht-ACK'd LoadDeviation + 1 mit SkillRatings in allen 4 Dimensionen).
   - WICHTIG für Tests: Lege rohe Medical-Diagnose-Daten NICHT an (die sind per RLS nie im Payload).
     Stattdessen: medical_records als Quelle mit diagnosis/symptoms EXISTIERT in den Source-Fixtures,
     ABER die Aggregations-Funktion entfernt sie für coach/athletik (siehe gate.ts).
     Praktisch: fixtures enthält medicalRaw (mit diagnosis) + medicalStatusView (nur Badge) — letzteres ist was durchgereicht wird.

3. lib/player360/gate.ts  (RLS-Double-Check, reine Funktionen)
   - applyRlsGate(payload, viewerRole, viewerPlayerId): entfernt/ maskiert Felder je Rolle:
     - player: sieht NUR player_id === viewerPlayerId; SkillRatings ANDERER Spieler nie.
     - coach / athletik: KEINE medical_records-Rohdaten (nur medicalStatusView) + KEINE nicht-med_acknowledged LoadDeviation.
     - arzt / physio: alles (inkl. medicalRaw + nicht-ACK'd LoadDeviation).
   - isCoachPayloadRlsClean(payload): grep-assert auf FORBIDDEN_KEYS (diagnosis, symptoms, treatment, reha_phase, risk, injury, prediction, Verletzungsrisiko, Risiko) im serialisierten JSON -> clean/violations.
   - FUNKTIONEN MÜSSEN DETERMINISTISCH sein (kein new Date() im Core; at-Zeiten als Argument).

4. lib/player360/aggregate.ts  (REINE Aggregation, KEINE Score-Berechnung)
   - aggregatePlayer360(sources, viewerRole, viewerPlayerId): Player360
   - Pro Dimension (reine Reads/JOINs über die Source-Entities, gruppiert nach player_id + Saison):
     - physical: PlayerProfile-Stammdaten + Baseline-Serie (Readiness-Puls) + (nur Med) MedicalRecord-Verlauf
     - technical: PlayerSkillRating(dimension='technical') Liste + DevelopmentGoal(category='technical')
     - tactical: PlayerProfile(stammposition/nebenpositionen) + PlayerSkillRating(dimension='tactical')
     - mental: DailyCheckIn mental_{stress,motivation,stimmung,energy} Trend (deskriptiv) + DevelopmentGoal(category='mental')
     - availability: Attendance-Historie + MedicalStatusView(clearance/visibility Badge) + aktive LoadDeviation-Count (nur nach med_acknowledged)
     - development: DevelopmentGoal(alle, 1-5 Progression) + PlayerSkillRating-Radar (aktuell)
   - KEINE neue Metrik. Zeigt existierende Werte thematisch gruppiert.

5. lib/player360/audit.ts
   - logAccess360(viewerProfileId, playerId, table='player360', at): erzeugt AccessLogEntry (nur Konstruktor/In-Memory-Push, keine DB).
   - getViewerAccessLog(playerId, allLogs): AuditViewEntry[] für "Wer hat meine Daten gesehen" (player sieht nur eigene player_id-Zeilen).

6. lib/player360/portability.ts
   - exportEscrowJson(playerId, sources): string (JSON) der EIGENEN 360.
   - Körperdaten (groesse, gewicht, geburtsdatum) in eigenes Feld body_metrics trennbar (separates Sub-Objekt), damit
     Vereins-IP von Körperdaten getrennt exportiert werden kann (Art. 20 DSGVO). Funktion getBodyMetricsSeparable(json) -> { core, body_metrics }.

7. components/player360/ReadinessPulsSparkline.tsx  (SIGNATURE-ELEMENT, Reuse aus trainer falls vorhanden)
   - Mini-Trend der Baseline-Serie als SVG-Sparkline. Reduced-Motion respektiert (statisch, kein Loop).
   - Deskriptiv: zeigt Abweichung zur rollingAvg, NIEMALS "Risiko"/"Vorhersage".

8. components/player360/Player360View.tsx  (Server Component, Read-only Drilldown)
   - Sechs Sektionen (Physical / Technical / Tactical / Mental / Availability / Development), je Dimension eine Karte.
   - Physical + Availability rendern ReadinessPulsSparkline (Signature-Element, Pflicht laut DONE_WHEN).
   - Mental: 4 Sparklines (stress/motivation/stimmung/energy), deskriptiv beschriftet.
   - Availability: Attendance-Timeline + Clearance-Badge (🟢🟡🟠🔴) + gated LoadDeviation-Count (nur nach med_acknowledged).
   - Technical/Tactical: SkillRating-Liste (nur eigene für player; Coach nur eigener Kader — hier: RLS-Isolation über gate.ts).
   - Immer wenn diese Seite "geöffnet" wird: logAccess360(...) aufrufen (im Server-Kontext via Prop/Callback).
   - "Wer hat meine Daten gesehen": unten Audit-Liste aus getViewerAccessLog.
   - HARTE Compliance: KEIN "Risiko"/"Verletzung"/"Prediction"/"Verletzungsrisiko" im gerenderten Text/Tooltip.

9. app/(player)/[playerId]/page.tsx  (Route, öffnet die 360-Seite)
   - Holt Quell-Entities (hier: fixtures), ruft aggregatePlayer360 + logAccess360 + rendert Player360View.
   - Simuliert viewerRole via Prop (später: aus JWT app_role).

10. lib/player360/sql/player360-schema.sql  (DDL für spätere echte DB-Wiring, NICHT zur Laufzeit ausgeführt)
    - CREATE TABLE player_skill_ratings (wie Spec §4) + Access-Log-Tabelle (ADR-004) + gated Views (medical_status_view already in matrix).
    - Kommentar: "DDL only; verification via vitest, not psql (kein lokaler Postgres im Scaffold)."

11. lib/player360/player360.test.ts  (vitest)
    - Pro Dimension ein Integration-Test: aggregatePlayer360 liefert korrekte Daten aus den Quell-Entities.
    - G-01: isCoachPayloadRlsClean besteht (String-Blacklist UI+API+Export). Zusätzlich: grep über exportEscrowJson + Player360View-Serialisierung.
    - G-02: RLS-Test — player sieht nur eigene 360; coach ohne medicalRaw + ohne nicht-ACK'd LoadDeviation; arzt/physio sehen alle.
    - G-03: assert, dass aggregatePlayer360/gate KEINE Schreibfunktion auf Quell-Entities exportieren (nur audit.logAccess360 schreibt, und zwar NUR AccessLog).
    - G-04: nach aggregate + logAccess360 ist in allLogs ein Eintrag (viewer, player_id, at); getViewerAccessLog(playerId) liefert ihn sichtbar.
    - G-05: exportEscrowJson(playerId) liefert valides JSON; getBodyMetricsSeparable trennt Körperdaten.
    - G-06: SkillRating eines ANDEREN Spielers ist im payload für player/coach nicht enthalten (RLS).
    - COMPLIANCE-GREP: ein Test, der den gerenderten Player360View-Text (React renderToStaticMarkup) auf die Blacklist prüft.

## CONSTRAINTS (HART)
- MDR-sicher (G-01): KEINE "risk"/"injury"/"prediction"/"Verletzungsrisiko"/"Risiko" Strings in UI/API/Export.
- RLS (G-02): player nur eigen; coach ohne Medical-Rohdaten + ohne nicht-ACK'd LoadDeviation; Medizin alle.
- Scope (G-03): KEINE Schreibpfade in Player/CheckIn/Baseline/MedicalRecord/Attendance/Clearance (ausser Audit-Log).
- Audit (G-04): jeder Öffnen einer 360-Seite -> Audit-Log (wer, wann, player_id); sichtbares Feature "Wer hat meine Daten gesehen".
- Portability (G-05): Escrow-Export der EIGENEN 360 als JSON; Körperdaten trennbar.
- SkillRating-Isolation (G-06): SkillRating anderer Spieler nie sichtbar.
- Reduced-Motion: keine Animations-Loops in Sparkline.
- Design-Tokens aus tailwind.config.ts nutzen (keine hartkodierten Farben außerhalb der Klassen).
- TypeScript strict; 'use client' nur wo nötig (Interaktivität). Server Components default.

## DONE_WHEN (Verifikation — maschinell prüfbar)
- [x] npm install (falls fehlend) im Ziel-Repo.
- [x] npx tsc --noEmit im team-performance-os Repo grün (strict).
- [x] npx vitest run lib/player360/player360.test.ts grün (alle G-Tests).
- [x] grep -rE "risk|injury|prediction|Verletzungsrisiko|Risiko" lib/player360 components/player360 app/\(player\) -> 0 Treffer in Quelltext (außer in Blacklist-Konstanten/Kommentaren die als solche markiert sind).
- [x] git diff --stat zeigt nur die oben gelisteten Dateien (file scope eingehalten).
- [x] PlayerSkillRating-Entity im Schema (player360-schema.sql) + im TS-Typ vorhanden.
- [x] Readiness-Puls-Sparkline in Physical + Availability gerendert (Player360View nutzt die Komponente).

## OUT_OF_SCOPE (bewusst NICHT)
Eigene Risiko-/Verletzungsvorhersage, neue Metrik-Berechnung, GPS/Catapult-Heatmaps, Videoanalyse-Embed, Vertragsdaten im Profil.
