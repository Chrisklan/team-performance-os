# Build-Contract: Modul Trainer-Dashboard (Morning Ops) — TP-OS

Repo: /Users/christopherklan/local/03_Projects/Christopher/Apps/team-performance-os (Next.js 14 App Router, TypeScript, Tailwind).
Du baust MIT dem Claude Max Account (OAuth), NICHT API-Token. Schreibe echten Code, kein Pseudo.

## Pflicht-Quellen (gelesen, bereits im Repo verfügbar)
- lib/trainer/types.ts        — Datenmodell KaderMember / CoachKaderPayload (NICHT ändern, außer Bugfix)
- lib/trainer/fixtures.ts     — 14 Spieler Seed (>=12 OK), "Kein Check-in"-Zustand via hasCheckIn=false
- lib/trainer/api.ts          — fetchKaderForCoach() liefert Post-RLS-Payload; coachPayloadIsRlsClean()
- tailwind.config.ts          — Design-Tokens (surface/card, accent #3E8EFF, warn, ok, ink, muted)
- app/globals.css             — Switzer @import + Reduced-Motion Media-Query (bereits vorhanden)
- app/layout.tsx              — RootLayout (nicht ändern)

## Anzulegende Dateien (STRICTER FILE SCOPE — nur diese)
1. app/(trainer)/dashboard/page.tsx
   - Server Component: holt fetchKaderForCoach(), sortiert via lib/trainer/sort.ts,
     rendert Header + KaderGrid. 'use client' nur für interaktive Teile (Drawer/Filter).
   - Header: "Trainer-Dashboard · {asOf} · {kaderName}", Filter/Sort-Controls (Attention-first Default),
     Sync-Indikator (live/last_sync).
   - Ladezeit ist lokal irrelevant (<60s Kaderabruf = Design-Ziel, hier Seed-synchron).

2. components/trainer/KaderGrid.tsx
   - Grid großer Karten, Attention-first sortiert. Responsive (Tablet/Web), 8-Punkt-Spacing.
   - Jede Karte = PlayerCard. Klick öffnet DetailDrawer (Client-State).

3. components/trainer/PlayerCard.tsx
   - Identität: Rückennummer, Name, Stammposition.
   - Readiness-Wert (0-100) GROSS, Switzer Bold (font-bold). Bei hasCheckIn=false => "—" + "Kein Check-in".
   - 5-Faktor-Breakdown: sleep/recovery/mental/muscle/load als kleine +/− Bars (relative Werte).
   - ReadinessPulsSparkline (Baseline-Trend).
   - Medical-Status-Badge 🟢🟡🟠🔴 (NUR Badge, KEIN Inhalt).
   - Heute-Teilnahme: attendance (anwesend/verletzt/reha/national/urlaub/krank) + todayEvent (training/spiel/none).
   - Auffälligkeits-Zustand: niedrige Readiness ODER medicalStatus!=green ODER starker Baseline-Drop
     => visuell hervorgehoben (accent- oder warn-Kante), OHNE Diagnose.
   - Tastatur-Navigation: Karte ist <button> oder role="button" + tabIndex, Enter/Space öffnet Drawer.

4. components/trainer/ReadinessPulsSparkline.tsx  (SIGNATURE-ELEMENT)
   - Mini-Trend der Baseline-Serie (baseline.series) als SVG-Sparkline.
   - Deskriptiv: zeigt Abweichung zur rollingAvg, NIEMALS "Risiko"/"Vorhersage".
   - Reduced-Motion respektiert (keine Animations-Loop; statisches SVG).

5. components/trainer/DetailDrawer.tsx  (Client)
   - Read-only Drilldown bei Klick: voller 5-Faktor-Breakdown (Werte + Bezug zur Baseline in %),
     vergrößerte Sparkline + Abweichungswert deskriptiv ("−22% vom 4-Wo-Schnitt"),
     Heute-Teilnahme + Termine, Medical NUR Badge + Freigabe-Status. Keine Diagnose/Symptome.
   - Erreichbar per Tastatur, Escape schließt, Focus-Management.

6. lib/trainer/sort.ts
   - attentionSort(members): deterministische Attention-first Sortierung.
     Priorität: (niedrigster Readiness) -> (medicalStatus!=green) -> (Flag/Baseline-Drop) ->
     (kein Check-in) -> Rest. Stabile Sekundärsortierung (jersey) für Determiniertheit.

7. lib/trainer/aggregate.ts
   - REINE Aggregation/Label-Logik, KEINE Score-Berechnung.
   - isAuffaellig(member): bool nach obiger Regel.
   - baselineDeviationPct(member): (aktueller Wert? rollingAvg) -> %-Abweichung (deskriptiv).
   - factorLabels: Mapping Faktor->DE-Label.
   - attendanceLabel / todayEventLabel / medicalLabel (DE, Badge-Text).

## CONSTRAINTS (HART)
- Dashboard liest nur. Kein INSERT/UPDATE/DELETE.
- KEINE Scoring-/Algorithmus-Logik. Readiness-Wert + Faktoren kommen aus Fixtures (Quelle Modul Readiness Score).
- MDR-Wortwahl: niemals "Risiko"/"Vorhersage"/"Prediction"/"Injury Risk"/"warnt vor Verletzung".
  Erlaubt: "Baseline-Abweichung −22%", "Readiness niedrig", "Medical-Status 🟡".
- Medical-Spalte zeigt NUR Badge. Inhalt via RLS gesperrt (schon im Daten-Layer).
- AA-Kontrast (>=7:1 auf Graphit #0F1620): ink #E6EDF3 auf surface, warn/ok/accent nur für
  nicht-essenzielle Akzente oder mit ausreichendem Kontrast; Prüfung via Build + Screenshot.
- Reduced-Motion respektiert (globals.css bereits gegeben; keine eigenen keyframe-Loops).
- Sprache DE. Switzer Bold für Zahlen/Headlines (font-bold utility).
- TypeScript strict; `npm run build` muss grün sein.

## DONE_WHEN (Verifikation durch Hermes)
- `npm run build` grün.
- Dashboard rendert 14 Spieler ohne Console-Errors.
- PlayerCard zeigt alle 5 Elemente (Readiness, Faktor-Breakdown, Sparkline, Badge, Heute).
- Attention-first Sortierung deterministisch (niedrigste Readiness oben).
- "Kein Check-in" eigenständiger Zustand (nicht als verfügbar).
- Medical nur Badge; RLS-Test (coachPayloadIsRlsClean) clean.
- a11y: Tastatur-Nav der Cards, AA-Kontrast.

## OUT OF SCOPE (Abbruch bei Verstoß)
- Kein Scoring, keine Wearable-Echtzeit, keine Videoanalyse, keine AI-NL-Queries,
  kein Editieren, keine Medical-Detailansicht, keine LoadDeviation-Tiefe (nur spätere Spalte vorgemerkt).
