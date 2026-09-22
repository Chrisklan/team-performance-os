# Design v1.0 — Tokens und Mockups

Abgenommen von Chris am 2026-09-22. Vollständige Begründung je Token im Vault:
`02 Projekte/Team Performance OS/Design-Tokens.md`, Abschnitt „Neufassung v1.0".

`mockups-v1.html` im Browser öffnen: drei Screens, eigenständige Datei ohne Abhängigkeiten.

## Anker

Die Farben sind **auf https://www.bsv-live.de/ aus dem berechneten CSS ausgelesen**, nicht
abgeleitet. Wer sie ändern will, misst dort nach. Der Seitenhintergrund des Vereins trägt
Handballfeld-Linien, daher liegen sie auch hier auf jedem Screen.

## Tokens

| Rolle | Wert | Verwendung |
|---|---|---|
| `field` | `#04284C` | Grundfläche |
| `panel` | `#063E75` | Kopfzeile, Karten, erhobene Fläche |
| `signal` | `#FFD800` | Primäraktion, Marke, Aufmerksamkeit |
| `ink` | `#EAF1F8` | Text |
| `muted` | `#9DB6CE` | Nebentext, Normlinie |
| `stop` | `#E23D3D` | **nur** Fläche, Rand, Punkt |
| `stop-ink` | `#FF8A8A` | Warntext |

`stop` ist nie Textgrund: weißer Text darauf erreicht nur 4,23 zu 1. Für Text auf rotem
Grund gibt es keine zulässige Kombination, stattdessen Outline mit `stop-ink`.

- **Schrift:** Roboto Condensed Bold (Display, Zahlen, Labels, Großbuchstaben), Roboto Regular (Text). Nur zwei Weights.
- **Type-Skala:** `12 / 14 / 16 / 20 / 32 / 40 / 72`
- **Spacing:** `4 / 8 / 12 / 16 / 24 / 32 / 48 / 64 / 96`, keine Freihandwerte
- **Radius:** `0 / 4 / 8` (vorher `8 / 12 / 20`, der Anker ist kantig)

## Signature-Element: Kaderleiste

Eine waagerechte Linie ist der eigene Schnitt der Spielerin. Jede Spielerin ist ein Plättchen
mit ihrer Trikotnummer darauf. Wer abweicht, rutscht darunter und hängt an einem Strich.
Position und Länge tragen die Aussage auch ohne Farbe, das ist Absicht.

Ersetzt den Readiness-Puls aus v0.2.

## Offen

- Die Player App führt zwei Token-Systeme (`colors` dunkel, `tokens` hell). Die helle Seite hat mit v1.0 keinen Anker mehr.
- Radius `0/4/8` betrifft alle bestehenden Komponenten.
- Die Check-In Skala ist eine durchgehende Leiste, kein Raster aus zehn Feldern: zehn Felder erreichen auf 390 Punkt Breite das 44-Punkt-Touchziel nicht.
