// Team Performance OS — Datenbank-Kapselung des KI-Gateways (AP-70a). NUR
// serverseitig, nie der privilegierte Admin-Schluessel (ADR-019 §3.3): der
// Client laeuft mit dem JWT der anfragenden Person (createSupabaseServerClient),
// genau wie bisher in squadCheckActions.ts.
//
// Kein freies .from(), kein freies .rpc() ausserhalb dieser Kapselung: open()
// ruft nur die in der Registry (purposes.ts) fuer den Zweck hinterlegte
// Tueroeffner-Tuer, readDoor() nur Namen aus dataDoors des Zwecks, finish()
// nur die gemeinsame Abschluss-Tuer. lib/ai/guardrails.test.ts (T3) prueft
// das Fehlen von .from(/.rpc( ausserhalb dieser Datei im Modellpfad.

import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { readGatewaySwitchConfig } from "./config";
import { GATEWAY_FINISH_DOOR, purposeSpec, type PurposeKey } from "./purposes";

type ServerClient = ReturnType<typeof createSupabaseServerClient>;
type RpcResult = Awaited<ReturnType<ServerClient["rpc"]>>;

export type FinishArgs = {
  callId: number;
  resultClass: string;
  latencyMs: number | null;
  finishToken: string;
};

export function gatewayDb(purpose: PurposeKey, client: ServerClient = createSupabaseServerClient()) {
  const spec = purposeSpec(purpose);

  return {
    // Ruft die Tueroeffner-Tuer des Zwecks mit den uebergebenen Argumenten auf
    // und reicht automatisch das Server-Secret durch (p_context_secret,
    // dieselbe Konvention wie app._mg_secret_ok/app._mg_open verlangen).
    async open(args: Record<string, unknown>): Promise<RpcResult> {
      const { secret } = readGatewaySwitchConfig();
      return client.rpc(spec.openDoor, { ...args, p_context_secret: secret });
    },

    // Nur Namen aus dataDoors des Zwecks -- AP-69 hat keine (dataDoors: []),
    // jeder Aufruf wirft. AP-70b traegt seine eigenen Lese-Tueren ein.
    async readDoor(name: string, args: Record<string, unknown>): Promise<RpcResult> {
      if (!spec.dataDoors.includes(name)) {
        throw new Error(`gatewayDb.readDoor: "${name}" ist keine dataDoor von "${purpose}"`);
      }
      return client.rpc(name, args);
    },

    async finish(args: FinishArgs): Promise<RpcResult> {
      return client.rpc(GATEWAY_FINISH_DOOR, {
        p_call_id: args.callId,
        p_result_class: args.resultClass,
        p_latency_ms: args.latencyMs,
        p_finish_token: args.finishToken,
      });
    },
  };
}

export type GatewayDb = ReturnType<typeof gatewayDb>;
