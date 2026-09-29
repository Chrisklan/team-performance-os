// Team Performance OS — Gateway-Konfiguration (AP-70a): Betreiber-Notaus und
// Server-Secret fuer die Tuer-Oeffner. NUR serverseitig.
//
// Getrennt von lib/ai/jev.ts::readJevConfig (Provider-Einstellungen wie Modell/
// Timeout/Mindest-Konfidenz -- AP-69-spezifisch, bleibt dort). Diese Datei
// haelt die zwei Werte, die JEDER Zweck braucht: das Betreiber-Notaus
// (JEV_ENABLED + ein Key) und das Server-Secret fuer die Kontext-Tueren.

import "server-only";

export type GatewaySwitchConfig = {
  enabled: boolean;
  apiKey: string | null;
  // Punkt 87 Nachfolge (AP-70a): MODEL_GATEWAY_SECRET ist der neue Name,
  // JEV_CONTEXT_SECRET bleibt als Uebergangs-Fallback lesbar, bis die
  // Cloud-Umgebungsvariable umbenannt ist (kein Verhaltensunterschied fuer
  // AP-69: squadCheckActions.ts liest heute JEV_CONTEXT_SECRET direkt).
  secret: string | null;
};

export function readGatewaySwitchConfig(env: NodeJS.ProcessEnv = process.env): GatewaySwitchConfig {
  const apiKey = env.OPENROUTER_API_KEY?.trim() || null;
  const secret = env.MODEL_GATEWAY_SECRET?.trim() || env.JEV_CONTEXT_SECRET?.trim() || null;
  return {
    enabled: env.JEV_ENABLED === "true" && apiKey !== null,
    apiKey,
    secret,
  };
}
