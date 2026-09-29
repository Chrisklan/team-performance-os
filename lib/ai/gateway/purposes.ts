// Team Performance OS — Registry der KI-Gateway-Zwecke (AP-70a).
// Einzige Quelle erlaubter RPC-Namen im GATEWAY-KERN (lib/ai/gateway): der
// Registry-Grep-Test in lib/ai/guardrails.test.ts scannt genau diesen Ordner,
// nicht den gesamten Modellpfad (lib/ai, lib/planung) -- Korrektur der
// vorherigen Kopfkommentar-Behauptung (Fixrunde, L1). lib/planung/
// squadCheckActions.ts ruft daneben weitere RPCs auf (z.B. rpc_dismiss_
// session_hint ueber den dynamischen Parameter `fn` in hintCall), die nichts
// mit dem Modell-Gateway zu tun haben und deshalb bewusst NICHT Teil dieser
// Registry sind.
//
// Rein, ohne Next/Supabase-Importe (Typ-Importe aus lib/planung/types.ts,
// lib/planung/jevSquadCheck.ts und lib/ai/jevTypes.ts sind reine Typen ohne
// Next/Supabase-Abhaengigkeit und werden ausschliesslich als `import type`
// gezogen -- kein Laufzeit-Import, kein Zyklus).

import type { JevContext, JevOverlay } from "@/lib/planung/types";
import type { JevValidation } from "@/lib/planung/jevSquadCheck";
import type { JevRequest } from "@/lib/ai/jevTypes";
// AP-70b: reine Typ-Importe fuer die Trainer-Query-Funktion, kein
// Next/Supabase-Laufzeit-Import (wie oben).
import type {
  ParsedTrainerQueryAnswers,
  TrainerQueryContext,
  TrainerQueryEvaluation,
} from "@/lib/trainerQuery/evaluate";

export type GatewayProvider = "jev";

export type PurposeSpec = {
  // Die Tuer, die die pending-Zeile anlegt (app._mg_open dahinter,
  // backend/47_model_gateway_core.sql).
  openDoor: string;
  // Zusaetzliche Lese-Tueren, die waehrend eines Aufrufs dieses Zwecks gelesen
  // werden duerfen. AP-69 braucht keine (die Kontext-Tuer liefert bereits
  // alles), AP-70b (Trainer-Queries) kommt in einem separaten Paket.
  dataDoors: readonly string[];
  // Schreib-Tueren -- fuer AP-69 bewusst leer (kein Modellaufruf schreibt
  // Nutzdaten). Siehe Kopfkommentar der Umsetzungsvorgabe: "Keine
  // Schreibtueren (writeDoors) -- fuer AP-69 bleibt die Liste leer."
  writeDoors: readonly string[];
  provider: GatewayProvider;
};

export const AP69_SQUAD_CHECK = "ap69_squad_check" as const;
// AP-70b: Trainer-Query-Funktion. Eigene Tuer (app.rpc_trainer_query_open,
// backend/48_trainer_query.sql), eigene Lese-Tuer fuer den Kader-Payload
// (public.rpc_trainer_morning_ops -- dieselbe Tuer wie das Trainer-Dashboard,
// AP-30). Der Kader-Payload wird NIE an das Modell weitergereicht (siehe
// lib/trainerQuery/resolve.ts/spec.ts) -- dataDoors ist trotzdem noetig, weil
// queryActions.ts ihn fuer die deterministische Auswertung selbst lesen muss.
export const AP70_TRAINER_QUERY = "ap70_trainer_query" as const;

export type PurposeKey = typeof AP69_SQUAD_CHECK | typeof AP70_TRAINER_QUERY;

// Code-Review P1 (Fixrunde): bindet ModelCallSpec<P> (lib/ai/gateway/run.ts)
// strukturell an das jeweilige purpose-Feld. Vorher hatte ModelCallSpec vier
// freie Generics (Ctx, Req, Parsed, Out) ohne Band zu purpose -- TypeScript
// liess eine spec mit falsch zugeordneten Typen fuer einen anderen Zweck
// klaglos durchkompilieren. Jeder Zweck traegt hier seine eigenen Ctx/Req/
// Parsed/Out ein, ein falsch verdrahteter Zweck wird jetzt ein Typfehler.
export interface PurposeTypeMap {
  [AP69_SQUAD_CHECK]: {
    Ctx: JevContext;
    Req: JevRequest;
    Parsed: JevValidation;
    Out: JevOverlay[];
  };
  [AP70_TRAINER_QUERY]: {
    Ctx: TrainerQueryContext;
    Req: JevRequest;
    Parsed: ParsedTrainerQueryAnswers;
    Out: TrainerQueryEvaluation;
  };
}

// Abschluss-Tuer ist fuer jeden Zweck dieselbe (app.rpc_finish_model_call).
export const GATEWAY_FINISH_DOOR = "rpc_finish_model_call" as const;

export const GATEWAY_PURPOSES: Record<PurposeKey, PurposeSpec> = {
  [AP69_SQUAD_CHECK]: {
    openDoor: "rpc_squad_check_jev_context",
    dataDoors: [],
    writeDoors: [],
    provider: "jev",
  },
  [AP70_TRAINER_QUERY]: {
    openDoor: "rpc_trainer_query_open",
    // Dieselbe Tuer wie das Trainer-Dashboard (AP-30) -- liefert NUR den post-RLS
    // Kader-Payload der eigenen Person, keine Sonderrechte fuer den Modellpfad.
    dataDoors: ["rpc_trainer_morning_ops"],
    writeDoors: [],
    provider: "jev",
  },
};

export function purposeSpec(purpose: PurposeKey): PurposeSpec {
  return GATEWAY_PURPOSES[purpose];
}

// Alle RPC-Namen, die aus dem Modellpfad heraus aufgerufen werden duerfen
// (Tueroeffner, Lese-Tueren, Abschluss-Tuer). Grundlage fuer den
// Registry-Grep-Test in lib/ai/guardrails.test.ts.
export function allowedGatewayRpcNames(): Set<string> {
  const names = new Set<string>([GATEWAY_FINISH_DOOR]);
  for (const spec of Object.values(GATEWAY_PURPOSES)) {
    names.add(spec.openDoor);
    for (const d of spec.dataDoors) names.add(d);
    for (const w of spec.writeDoors) names.add(w);
  }
  return names;
}
