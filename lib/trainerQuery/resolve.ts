// Team Performance OS — Pseudonymisierung der Trainer-Frage (AP-70b). Rein,
// ohne Next/Supabase-Importe. Laeuft VOR jedem Modellaufruf: ersetzt jeden
// Namensbestandteil und jede Rueckennummer, die in der Trainer-Frage vorkommt,
// deterministisch durch einen P-Ref-Platzhalter. Das Modell sieht danach nur
// noch Platzhalter, nie einen echten Namen oder eine echte Rueckennummer.
//
// Security-Review AP-70b, C1 (Critical): ein reiner Teilstring-Match auf den
// vollen Anzeigenamen (fruehere Fassung) erkennt weder Nachname allein noch
// Vorname allein, keinen Spitznamen, keine Umlaut-Umschrift und keinen
// Tippfehler -- ein Klarname konnte unveraendert an OpenRouter gehen. Diese
// Fassung ist FAIL-CLOSED statt best-effort:
//   1. Tokenisiert die Frage in Buchstaben-/Ziffernlaeufe (Unicode-aware),
//      ersetzt jeden Namensbestandteil (Vor-/Nachname einzeln, ab Laenge 2,
//      NFKC+lowercase+Umlaut-Transliteration auf BEIDEN Seiten normalisiert --
//      kein reiner Teilstring-Match mehr, "Ali" trifft nicht mehr "Qualität").
//   2. Ersetzt Rueckennummern als eigenstaendiges Zahl-Token.
//   3. Scannt danach JEDEN verbleibenden Buchstaben-Token gegen eine feste,
//      geschlossene Vokabelliste (deutsche Frage-Woerter plus die eigenen
//      Domaenenbegriffe). 2-Zeichen-Tokens werden zusaetzlich gegen eine
//      eigene, bewusst kleine Kurzwortliste geprueft (ALLOWED_SHORT_VOCAB);
//      alles darunter (1-Zeichen-Tokens) ist grundsaetzlich blockiert. Ein
//      einziges unbekanntes Wort blockiert die GESAMTE Anfrage OHNE
//      Modellaufruf -- kein stiller Fallback auf "player_ref: keine", der
//      versehentlich alle Spieler auflisten wuerde.

import { randomInt } from "node:crypto";

export type ResolvedPlayerRef = {
  ref: string;
  personId: string;
  name: string;
  jersey: number;
  position: string;
  positionCategory: PositionCategory;
  band: "low" | "moderate" | "high" | null;
  medicalClearance: "frei" | "eingeschraenkt" | "gesperrt" | null;
  hasCheckIn: boolean;
};

type CoachKaderPayloadLike = {
  members: readonly {
    player: { id: string; jersey: number; name: string; position: string };
    readiness: { band: "low" | "moderate" | "high" | null };
    medicalClearance: "frei" | "eingeschraenkt" | "gesperrt" | null;
    hasCheckIn: boolean;
  }[];
};

// I-2 (Security-Review): der rohe person_position-Freitext (kann beliebig
// gepflegt sein, z.B. "IV (Reha)") geht NIE an das Modell. Nur diese vier
// festen Kategorien sind erlaubte Choice-Werte, siehe positionCategory().
export const POSITION_CATEGORIES = ["torwart", "abwehr", "mittelfeld", "sturm", "unbekannt"] as const;
export type PositionCategory = (typeof POSITION_CATEGORIES)[number];

// N-3 (Security-Re-Review): die Kuerzel ("iv", "av", "om", "dm", "tor") duerfen
// nur als EIGENSTAENDIGES Token greifen, nicht als Teilstring -- sonst wird
// z.B. "Torjaeger" (enthaelt "tor" als Teilstring) faelschlich zu "torwart".
// Die laengeren, eindeutigen Woerter (abwehr/verteidig/mittelfeld/sturm/
// stuerm/angriff) bleiben bewusst Teilstring-Suche: sie sind lang genug, dass
// kein realistisches deutsches Wort sie unbeabsichtigt als Teilstring traegt,
// waehrend die zwei- bis dreistelligen Kuerzel genau das Risiko haben (tor in
// Torjaeger/Torwart/Vortor, iv in "aktiv", av in "Erstattung" jeweils Teil
// eines laengeren Worts).
function positionTokens(rawPosition: string): string[] {
  return rawPosition
    .split(/[\s,/()\-]+/)
    .map(normalizeToken)
    .filter((t) => t.length > 0);
}

export function positionCategory(rawPosition: string): PositionCategory {
  const n = normalizeToken(rawPosition);
  const tokens = new Set(positionTokens(rawPosition));
  // "torwart" bleibt als eindeutiges volles Wort Teilstring-Suche (kein
  // realistisches anderes Wort enthaelt "torwart"); das Kuerzel "tor" greift
  // nur als eigenstaendiges Token -- das trennt "Torjaeger" (Teilstring "tor",
  // aber kein Token "tor" und kein Wort "torwart") sauber von "TOR"/"Torwart".
  if (n.includes("torwart") || tokens.has("tor")) return "torwart";
  if (n.includes("abwehr") || n.includes("verteidig") || tokens.has("iv") || tokens.has("av")) return "abwehr";
  if (n.includes("mittelfeld") || tokens.has("zm") || tokens.has("dm") || tokens.has("om")) return "mittelfeld";
  if (n.includes("sturm") || n.includes("stuerm") || n.includes("angriff")) return "sturm";
  return "unbekannt";
}

function normalizeToken(s: string): string {
  return s
    .normalize("NFKC")
    .toLowerCase()
    .replace(/ä/g, "ae")
    .replace(/ö/g, "oe")
    .replace(/ü/g, "ue")
    .replace(/ß/g, "ss");
}

// Geschlossene Vokabelliste erlaubter Frage-Woerter (deutsche Funktionswoerter
// plus die eigenen Domaenenbegriffe aus schema.ts/render.ts). Bewusst NICHT
// vollstaendig im Sinn einer freien Sprache -- ein unbekanntes Wort blockiert
// lieber eine harmlose Frage als einen Klarnamen durchzulassen (fail-closed,
// siehe Kopfkommentar).
const ALLOWED_VOCAB = new Set(
  [
    // Fragewoerter
    "wie", "viele", "viel", "wieviele", "wieviel", "wer", "welche", "welcher", "welches", "was", "wo", "warum", "wieso",
    // Verben/Hilfsverben
    "ist", "sind", "hat", "haben", "gibt", "gib", "gebe", "geht", "gehts", "zeig", "zeige", "sag", "sage", "kann",
    "koennen", "moechte", "brauche", "will", "wuerde", "bitte", "zeigen", "auflisten", "liste", "listen", "nenn",
    "nenne",
    // Artikel/Pronomen/Konjunktionen
    "der", "die", "das", "dem", "den", "des", "ein", "eine", "einen", "einem", "einer", "eines", "und", "oder", "als",
    "dass", "ob", "mit", "ohne", "von", "zum", "zur", "fuer", "ueber", "unter", "nach", "vor", "aus", "alle", "aller",
    "alles", "jede", "jeder", "jedes", "jemand", "keine", "kein", "keinen", "keiner", "noch", "nicht", "dieser",
    "diese", "dieses",
    // Zeit/Zustand (nur "heute", Vergangenheit/Zukunft ist separat per
    // TIME_MARKER_PATTERN in queryActions.ts blockiert, unabhaengig hiervon)
    "heute", "heutige", "heutigen", "heutiger", "aktuell", "aktuelle", "aktuellen", "stand", "gerade", "jetzt",
    // Domaenen-Nomen
    "spieler", "spielerin", "spielerinnen", "spielern", "mannschaft", "kader", "team", "anzahl", "namen", "name",
    "nummer", "rueckennummer", "trikotnummer", "position",
    // Readinessband
    "readiness", "readinessband", "band", "niedrig", "niedriges", "niedrige", "mittel", "mittlere", "mittleres",
    "hoch", "hohe", "hohes",
    // Freigabe
    "freigabe", "frei", "freie", "freien", "eingeschraenkt", "eingeschraenkte", "eingeschraenkten", "gesperrt",
    "gesperrte", "gesperrten",
    // Checkin
    "checkin", "check", "eingecheckt",
    // Positionen
    "torwart", "abwehr", "verteidigung", "verteidiger", "mittelfeld", "mittelfeldspieler", "sturm", "stuermer",
    "stuermerin", "aussenverteidiger", "innenverteidiger",
  ].map(normalizeToken),
);

// N-1 (Security-Re-Review): 2-Zeichen-Tokens, die NICHT durch einen P-Ref
// ersetzt wurden, muessen trotzdem gegen eine feste Liste bekannter
// 2-Zeichen-Funktionswoerter geprueft werden statt stillschweigend
// durchzulaufen -- sonst waere z.B. ein Wort wie "ab" unblockiert Klartext im
// Modellaufruf. Bewusst klein und geschlossen, analog zu ALLOWED_VOCAB.
//
// Security-Re-Review, Finding 1: "an", "im", "so", "du", "es", "er", "ja"
// bewusst NICHT aufgenommen -- das sind zugleich plausible kurze Nachnamen.
// Ist ein Spieler mit so einem Namen nicht im aktuellen Kader-Payload (Gast,
// Vertretung, teamfremde Frage), wuerde das Wort sonst als "erlaubtes
// Funktionswort" durchgelassen statt zu blockieren -- ein echter, wenn auch
// seltener Klartext-Leckpfad. Nur die wenig namensartigen Praepositionen/
// Funktionswoerter bleiben in der Liste.
//
// Security-Review-Nachtrag (Punkt 103): fuer einen Namensbestandteil eines
// AKTUELLEN Kadermitglieds greift dieses Risiko nicht -- resolvePlayerRefs
// prueft namePartIndex (aus dem aktuellen payload/refs gebaut) VOR diesem
// Kurzwort-Scan, ein echter Kadername wird also immer schon vorher zum P-Ref.
// Das verbleibende Restrisiko ist ausschliesslich der Fall eines echten,
// NICHT im aktuellen Kader-Payload enthaltenen Kurznamens (Gast, Vertretung,
// teamfremde Person) -- die Funktion kennt ausserhalb des aktuellen Kaders
// keine Namen und kann diesen Fall strukturell nicht schliessen, ohne echte
// Funktionswoerter mitzublockieren. Bewusst akzeptiertes Restrisiko, siehe
// Regressionstest "Punkt 103" in trainerQuery.test.ts.
const ALLOWED_SHORT_VOCAB = new Set(["zu", "ab", "am", "in", "ob", "wo"].map(normalizeToken));

const AMBIGUOUS_MARKER = "jemand";

const TOKEN_RE = /[\p{L}\p{M}]+|[0-9]+/gu;
const ALNUM_RE = /[\p{L}\p{M}0-9]+/gu;

function refWidth(total: number): number {
  return Math.max(2, String(total).length);
}

// I-1 (Security-Review, Important): P-Refs duerfen NICHT stabil nach
// Tuer-Reihenfolge (Rueckennummer-Sortierung) vergeben werden -- oeffentlich
// bekannte Bundesliga-Rueckennummern wuerden dem Provider erlauben, jede
// P-Ref ueber mehrere Anfragen hinweg derselben Person zuzuordnen (gleiches
// Niveau wie AP-69, backend/47_model_gateway_core.sql: row_number() OVER
// (ORDER BY random())). Fisher-Yates mit crypto.randomInt, je Aufruf neu.
function shuffledIndexes(n: number): number[] {
  const idx = Array.from({ length: n }, (_, i) => i);
  for (let i = idx.length - 1; i > 0; i--) {
    const j = randomInt(i + 1);
    [idx[i], idx[j]] = [idx[j], idx[i]];
  }
  return idx;
}

export function buildPlayerRefs(payload: CoachKaderPayloadLike): ResolvedPlayerRef[] {
  const width = refWidth(payload.members.length);
  const order = shuffledIndexes(payload.members.length);
  return order.map((memberIndex, position) => {
    const m = payload.members[memberIndex];
    return {
      ref: "P" + String(position + 1).padStart(width, "0"),
      personId: m.player.id,
      name: m.player.name,
      jersey: m.player.jersey,
      position: m.player.position,
      positionCategory: positionCategory(m.player.position),
      band: m.readiness.band,
      medicalClearance: m.medicalClearance,
      hasCheckIn: m.hasCheckIn,
    };
  });
}

// normalizedNamePart -> alle Refs, die diesen Bestandteil im Anzeigenamen
// tragen (Vor-/Nachname einzeln, ab normalisierter Laenge 2).
//
// N-1 (Security-Re-Review): vorher ab Laenge 3 -- ein Spieler mit
// 2-Zeichen-Namensbestandteil ("Li", "Wu", "Oh") wurde dadurch NIE indexiert
// und ging unveraendert als Klartext an das Modell, sobald sein Name in der
// Frage vorkam. Die Schwelle ab hier auf 2 gesenkt; ein Guard fuer
// (theoretisch durch den Split nicht auftretende) leere Reste bleibt.
function buildNamePartIndex(refs: readonly ResolvedPlayerRef[]): Map<string, ResolvedPlayerRef[]> {
  const index = new Map<string, ResolvedPlayerRef[]>();
  for (const r of refs) {
    for (const rawPart of r.name.split(/[\s-]+/)) {
      const part = normalizeToken(rawPart);
      if (part.length < 2) continue;
      const list = index.get(part) ?? [];
      list.push(r);
      index.set(part, list);
    }
  }
  return index;
}

export type ResolveResult =
  | { ok: true; pseudonymizedQuestion: string; refs: ResolvedPlayerRef[]; mentionedRefs: ResolvedPlayerRef[] }
  // C1: die Frage enthaelt nach der Namens-/Nummern-Ersetzung noch mindestens
  // ein Wort, das weder ein P-Ref noch aus der festen Vokabelliste ist --
  // harte Absage, KEIN Modellaufruf, KEIN stiller Fallback.
  | { ok: false; reason: "unresolved_token" }
  // N-2 (Security-Re-Review): ein Namensbestandteil trifft mehrere Personen
  // (z.B. geteilter Nachname) -- harte Absage OHNE Modellaufruf, statt den
  // neutralen Platzhalter durchzulassen und das Modell zwischen Kandidaten
  // waehlen zu lassen (bzw. bei "keine" alle freien Spieler aufzulisten).
  | { ok: false; reason: "ambiguous_name" };

export function resolvePlayerRefs(question: string, payload: CoachKaderPayloadLike): ResolveResult {
  const refs = buildPlayerRefs(payload);
  const namePartIndex = buildNamePartIndex(refs);
  const mentioned = new Set<string>();
  // N-2: sobald ein Namensbestandteil mehrdeutig ist, brechen wir NACH dem
  // replace()-Durchlauf sofort mit einer Absage ab -- kein Modellaufruf, kein
  // neutraler Platzhalter, der das Modell raten laesst.
  let ambiguous = false;

  let pseudonymized = question.replace(TOKEN_RE, (match) => {
    if (/^[0-9]+$/.test(match)) {
      const num = Number(match);
      if (num > 0) {
        const owner = refs.find((r) => r.jersey === num);
        if (owner) {
          mentioned.add(owner.ref);
          return owner.ref;
        }
      }
      return match;
    }

    const norm = normalizeToken(match);
    // N-1: Schwelle von < 3 auf < 2 gesenkt, damit 2-Zeichen-Namensbestandteile
    // ("Li", "Wu", "Oh") ueberhaupt gegen den Namensindex geprueft werden.
    if (norm.length < 2) return match;

    // Punkt 104 (Security-Review): Namensauflösung hat hier BEWUSST Vorrang
    // vor der Funktionswort-Erkennung (ALLOWED_VOCAB/ALLOWED_SHORT_VOCAB
    // weiter unten) -- der Namensindex wird zuerst geprueft, ein Token, das
    // sowohl ein Namensbestandteil eines aktuellen Kadermitglieds als auch ein
    // Funktionswort/eine Praeposition ist (z.B. Nachname "Im" oder "Zu"), wird
    // deshalb immer als P-Ref aufgeloest, nie als Funktionswort durchgelassen.
    // Das ist die sicherere Richtung: ein echter Spielername geht dadurch nie
    // unveraendert als Klartext ans Modell. Das Risiko liegt nur in der
    // umgekehrten, harmlosen Richtung -- ein Funktionswort wird faelschlich
    // als Namensnennung behandelt und liefert eine sachlich falsche, aber
    // nicht datenschutzrelevante Antwort (der Trainer ist ohnehin fuer alle
    // Kaderdaten berechtigt). Bewusst akzeptiertes, dokumentiertes Verhalten,
    // siehe Regressionstest "Punkt 104" in trainerQuery.test.ts.
    const owners = namePartIndex.get(norm);
    if (!owners || owners.length === 0) return match;
    if (owners.length === 1) {
      mentioned.add(owners[0].ref);
      return owners[0].ref;
    }
    // Namensbestandteil ist zwischen mehreren Personen mehrdeutig (z.B.
    // geteilter Nachname): fail-closed statt raten lassen (N-2).
    ambiguous = true;
    for (const o of owners) mentioned.add(o.ref);
    return AMBIGUOUS_MARKER;
  });

  if (ambiguous) {
    return { ok: false, reason: "ambiguous_name" };
  }

  const refPattern = new RegExp(`^p\\d{2,}$`, "i");
  for (const match of pseudonymized.matchAll(ALNUM_RE)) {
    const token = match[0];
    const norm = normalizeToken(token);
    if (refPattern.test(token)) continue;
    if (norm === AMBIGUOUS_MARKER) continue;
    // N-1: 2-Zeichen-Tokens duerfen NICHT mehr stillschweigend durchlaufen --
    // sie muessen entweder ein ersetzter P-Ref-Rest sein (oben behandelt) oder
    // gegen die geschlossene Kurzwortliste geprueft werden.
    if (norm.length <= 2) {
      if (ALLOWED_SHORT_VOCAB.has(norm)) continue;
      return { ok: false, reason: "unresolved_token" };
    }
    if (ALLOWED_VOCAB.has(norm)) continue;
    // Unbekanntes Wort ausserhalb der geschlossenen Vokabelliste -- fail-closed.
    return { ok: false, reason: "unresolved_token" };
  }

  return {
    ok: true,
    pseudonymizedQuestion: pseudonymized,
    refs,
    mentionedRefs: refs.filter((r) => mentioned.has(r.ref)),
  };
}
