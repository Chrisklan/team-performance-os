// Team Performance OS — gemeinsame Ausgangswaechter-Bausteine des KI-Gateways
// (AP-70a). Rein, ohne Next/Supabase-Importe. Jeder Zweck baut seinen eigenen
// guard() aus diesen Bausteinen (siehe lib/planung/jevSquadCheck.ts::
// overlaysFromRefs fuer AP-69).

import { FORBIDDEN_MODEL_RESPONSE_KEYS, forbiddenKeyHits } from "@/lib/ai/forbiddenKeys";
import { g01Violations } from "@/lib/ai/guardrails";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Alle Schluessel-Pfade in einem Wert, in jeder Tiefe, als letztes
// Pfadsegment (der Schluesselname selbst, ohne Elternpfad).
export function keyPaths(value: unknown): string[] {
  const out: string[] = [];
  const walk = (v: unknown) => {
    if (Array.isArray(v)) {
      for (const item of v) walk(item);
      return;
    }
    if (isRecord(v)) {
      for (const [key, vv] of Object.entries(v)) {
        out.push(key);
        walk(vv);
      }
    }
  };
  walk(value);
  return out;
}

function normalizeKey(k: string): string {
  return k.trim().toLowerCase();
}

// true, wenn JEDER Schluessel der Antwort entweder auf der Allowlist steht
// oder schon im Tuer-Payload vorkam (die Tuer hat ihn also selbst
// herausgegeben -- kein vom Modell erfundenes Feld).
//
// F2 (Security-Review, Fixrunde): zwei Ergaenzungen.
//   1. Normalisierung (lowercase, getrimmt) VOR dem Abgleich -- ein Schluessel
//      durfte vorher nur bei exakt gleicher Gross/Kleinschreibung als bekannt
//      gelten, "Person_ID" haette also faelschlich als "erfunden" gegolten
//      bzw. ein umbenannter bekannter Schluessel konnte den Abgleich umgehen.
//   2. Substring-Sperre: ein Antwortschluessel, der einen Begriff aus der
//      FORBIDDEN_MODEL_RESPONSE_KEYS-Sperrliste als TEILWORT enthaelt (z.B.
//      "person_id_and_pain_level"), wird abgelehnt -- auch wenn er sich durch
//      Umbenennung/Zusammensetzen der exakten Sperrlisten-Pruefung entzogen
//      haette. Diese Sperre gewinnt immer, unabhaengig von der Allowlist.
export function assertKeysSubset(
  answer: unknown,
  doorPayload: unknown,
  allowlist: readonly string[],
): boolean {
  const answerKeys = keyPaths(answer).map(normalizeKey);
  const forbiddenNormalized = FORBIDDEN_MODEL_RESPONSE_KEYS.map(normalizeKey);
  if (answerKeys.some((k) => forbiddenNormalized.some((f) => k.includes(f)))) {
    return false;
  }

  const allowed = new Set([...allowlist, ...keyPaths(doorPayload)].map(normalizeKey));
  return answerKeys.every((k) => allowed.has(k));
}

function collectPrimitives(value: unknown): (string | number | boolean)[] {
  const out: (string | number | boolean)[] = [];
  const walk = (v: unknown) => {
    if (Array.isArray(v)) {
      for (const item of v) walk(item);
      return;
    }
    if (isRecord(v)) {
      for (const vv of Object.values(v)) walk(vv);
      return;
    }
    if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") out.push(v);
  };
  walk(value);
  return out;
}

// F2 (Security-Review, Fixrunde): war zuvor global -- ein Wert von Person B
// haette faelschlich als "stammt aus dem Tuer-Payload" fuer Person A gegolten,
// weil nur GESAMMELT geprueft wurde, ob der Wert IRGENDWO im Payload vorkommt,
// nie WESSEN Eintrag er gehoert. Jetzt gebunden an idKey (z.B. "ref" oder
// "person_id"): jeder answer-Eintrag wird NUR gegen den doorPayload-Eintrag
// mit demselben idKey-Wert geprueft, nie gegen den gesamten Payload. Ein
// answer-Eintrag ohne passenden door-Eintrag (unbekannte/erfundene id)
// scheitert sofort, kein Fallback auf eine globale Werte-Menge.
//
// Vorbereitet fuer AP-70b (Trainer-Queries mit mehreren Personen und
// tatsaechlich vom Modell durchgereichten Werten je Person) -- fuer AP-69
// bleibt sie aktuell UNGENUTZT: overlaysFromRefs (lib/planung/jevSquadCheck.ts)
// bildet ref -> person_id bereits ueber eine direkte Map-Lookup aus ctx.refs,
// die Bindung ist dort schon durch Konstruktion korrekt, overlays tragen
// keinen weiteren vom Modell stammenden Primitivwert, den man noch binden
// muesste (suggestion/hint_key/source sind server-seitige Literale).
export function assertValueProvenance(
  answer: readonly Record<string, unknown>[],
  doorPayload: readonly Record<string, unknown>[],
  idKey: string,
): boolean {
  const byId = new Map<string, Record<string, unknown>>();
  for (const entry of doorPayload) {
    const id = entry[idKey];
    if (typeof id === "string") byId.set(id, entry);
  }

  return answer.every((entry) => {
    const id = entry[idKey];
    if (typeof id !== "string") return false;
    const doorEntry = byId.get(id);
    if (!doorEntry) return false;
    const doorValues = new Set(collectPrimitives(doorEntry).map(String));
    return collectPrimitives(entry).every((v) => doorValues.has(String(v)));
  });
}

// N1 (Security-Re-Review, zweite Fixrunde): g01Violations() ist eine reine
// Teilstring-Suche ueber EINEN String. run.ts rief sie bisher auf
// JSON.stringify(outcome.body) auf -- das prueft damit auch jeden
// Schluesselnamen mit, nicht nur Werte. Eine echte JEV-Choice-Antwort hat die
// Form { choice, probabilities: {...}, confidence }; der Schluessel
// "probabilities" enthaelt "probab" als Teilstring und loeste G-01 IMMER aus,
// unabhaengig vom tatsaechlichen Inhalt -- jede echte Antwort wurde verworfen.
//
// Diese Funktion sammelt NUR String-BLATTWERTE (keine Schluesselnamen, keine
// Zahlen/Booleans, die g01Violations ohnehin nicht sinnvoll prueft) in jeder
// Tiefe und prueft G-01 ausschliesslich gegen diese Werte, verkettet mit einem
// Trennzeichen (ein einzelner g01Violations-Aufruf reicht, die Sperrliste ist
// reine Teilstring-Suche -- ein Treffer an einer Grenze zwischen zwei
// verketteten Werten ist fuer die kurzen Sperrbegriffe hier praktisch
// ausgeschlossen und im Zweifel harmlos-konservativ, da er nur zu einer
// zusaetzlichen Ablehnung fuehren koennte, nie zu einer entgangenen).
function collectStringLeaves(value: unknown, out: string[]): void {
  if (Array.isArray(value)) {
    for (const item of value) collectStringLeaves(item, out);
    return;
  }
  if (isRecord(value)) {
    for (const v of Object.values(value)) collectStringLeaves(v, out);
    return;
  }
  if (typeof value === "string") out.push(value);
}

export function g01ViolationsInStringValues(value: unknown): string[] {
  const leaves: string[] = [];
  collectStringLeaves(value, leaves);
  return g01Violations(leaves.join("\n"));
}

export { forbiddenKeyHits, g01Violations };
