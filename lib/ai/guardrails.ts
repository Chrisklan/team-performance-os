// Team Performance OS — G-01 fuer die KI-Ebene (ADR-019 §3.5 Punkt 5, Test T5).
// Rein, ohne Next/Supabase-Importe.
//
// G-01 (ADR-006) ist bisher eine Sperrliste fuer Textbausteine
// (backend/35_load_deviation.pgtap.sql, statement_catalog). ADR-019 erweitert
// sie auf Prompts, Einordnungslisten und Hinweistexte. Diese Liste ist der
// Kern fuer Modell-Texte: keine Diagnose-, Risiko-, Verletzungs-, Schmerz- oder
// Wahrscheinlichkeitsbegriffe, deutsch und englisch. Geprueft wird als
// Teilwort, ohne Gross/Kleinschreibung.
//
// Bewusst NICHT auf der Liste: "reduced"/"reduziert". Die geschlossene
// Optionsliste von AP-69 ist full/reduced/unclear, mit Chris abgestimmt. Der
// Vorschlag "reduziert" ist die einzige Richtung, die JEV ueberhaupt kennt, und
// er bleibt ein Hinweis an den Trainer, keine Handlungsvorgabe (ADR-019 §3.1).
export const G01_MODEL_TEXT_BLACKLIST: readonly string[] = [
  // Diagnose
  "diagnos",
  "befund",
  "symptom",
  "patholog",
  "krank",
  "illness",
  "disease",
  "sick",
  // Verletzung, Schmerz
  "verletz",
  "injur",
  "schmerz",
  "pain",
  "wound",
  // Risiko, Gefahr, Vorhersage
  "risiko",
  "risk",
  "gefahr",
  "danger",
  "hazard",
  "prognos",
  "vorhersag",
  "predict",
  "forecast",
  "wahrscheinlich",
  "probab",
  "likelihood",
  // Behandlung
  "therap",
  "behandl",
  "treatment",
  "medizin",
  "medical",
];

export function g01Violations(text: string): string[] {
  const lower = text.toLowerCase();
  return G01_MODEL_TEXT_BLACKLIST.filter((word) => lower.includes(word));
}
