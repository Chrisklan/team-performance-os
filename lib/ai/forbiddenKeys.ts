// Team Performance OS — gemeinsame Sperrliste verbotener Schluessel fuer jede
// Antwort, die ein Modell im Gateway-Kern (AP-70a) zurueckgibt. Speist sich aus
// der bestehenden Trainer-API-Liste (lib/trainer/api.ts, FORBIDDEN_MEDICAL_KEYS)
// und ergaenzt die in AP-70a benannten zusaetzlichen Felder. Rein, ohne
// Next/Supabase-Importe.
//
// Verwendung (verifiziert, Fixrunde F2): lib/ai/gateway/run.ts::runModelCall
// prueft JEDE rohe Modellantwort gegen diese Liste (forbiddenKeyHits), als
// fester, nicht uebersteuerbarer Teil des Ablaufs -- BEVOR der zweckspezifische
// parse()/guard() der jeweiligen ModelCallSpec sie ueberhaupt sieht. Ein
// Treffer ist ein PFLICHT-Ausgangswaechter-Fehler (Ergebnisklasse 'rejected').
// lib/ai/gateway/guard.ts::assertKeysSubset prueft zusaetzlich, je Zweck, auf
// Schluessel-Ebene (Substring, normalisiert) gegen dieselbe Liste.

import { FORBIDDEN_MEDICAL_KEYS } from "@/lib/trainer/api";

export const FORBIDDEN_MODEL_RESPONSE_KEYS: readonly string[] = [
  ...FORBIDDEN_MEDICAL_KEYS,
  "score_total",
  "factors",
  "value",
  "body_map",
  "pain",
  "regions",
  "series",
  "deviation",
  "deviations",
  "deviation_key",
  "deviation_keys",
  "notes",
  "note",
  "comment",
  "comments",
  "text",
  "free_text",
  "freetext",
];

function collectKeys(value: unknown, out: Set<string>): void {
  if (Array.isArray(value)) {
    for (const item of value) collectKeys(item, out);
    return;
  }
  if (value !== null && typeof value === "object") {
    for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
      out.add(key);
      collectKeys(v, out);
    }
  }
}

// Findet jeden Schluessel aus der Sperrliste, der irgendwo (in jeder Tiefe)
// im uebergebenen Objekt vorkommt. Teilwort-frei (exakter Schluesselname),
// damit z.B. "planned_load_vs_own_norm" nicht faelschlich "value" triggert.
export function forbiddenKeyHits(value: unknown): string[] {
  const keys = new Set<string>();
  collectKeys(value, keys);
  return FORBIDDEN_MODEL_RESPONSE_KEYS.filter((k) => keys.has(k));
}
