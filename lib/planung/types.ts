// Team Performance OS — Antwortformen der Planungs-Tueren (AP-69 Plan gegen Zustand).
// Rein, ohne Next/Supabase-Importe. Jede Form bildet ab, was die Tuer liefert
// (backend/40_squad_check.sql, backend/41_jev_switch_model_call_log.sql).

// app.module_flags, Team-Schalter fuer die JEV-Zuordnung. Setzen darf ihn nur
// admin (app._module_flag_setters), lesen jede authentifizierte Rolle.
export const JEV_SQUAD_CHECK_FLAG = "jev_squad_check_enabled";

// Die vier Spalten. suspend ist "aussetzen" und entsteht nur als Spiegel der
// aerztlichen Freigabe (ADR-019 §5.1), nie aus Regel oder JEV.
export type Suggestion = "full" | "reduced" | "individual" | "suspend";
export const SUGGESTIONS: readonly Suggestion[] = ["full", "reduced", "individual", "suspend"];

export type SuggestionSource = "mirror" | "rule";
export type HintKey = "h1" | "h2" | "h3" | "h4";
export type DismissableHintKey = "h1" | "h2" | "h4" | "j1";
export const DISMISSABLE_HINT_KEYS: readonly DismissableHintKey[] = ["h1", "h2", "h4", "j1"];

export type LoadLevel = "far_above" | "above" | "normal" | "below" | "no_norm";
export type ReadinessBand = "low" | "moderate" | "high";
export type ClearanceStatus = "full" | "limited" | "individual" | "blocked";

export type SquadAthlete = {
  person_id: string;
  display_name: string;
  jersey: number | null;
  suggestion: Suggestion;
  source: SuggestionSource;
  clearance: ClearanceStatus | null;
  band: ReadinessBand | null;
  load_level: LoadLevel;
  released_deviation_keys: string[];
  has_checkin: boolean;
  hints: HintKey[];
  dismissed_hints: DismissableHintKey[];
};

// public.rpc_get_session_squad_check
export type SquadCheckPayload = {
  rule_version: "v1";
  session_id: string | null;
  session_date: string;
  planned_day_load: number;
  athletes: SquadAthlete[];
};

export type SessionType = "field" | "gym" | "recovery" | "tactical" | "test";
export const SESSION_TYPES: readonly SessionType[] = ["field", "gym", "recovery", "tactical", "test"];

// public.rpc_list_training_sessions / rpc_create_training_session
export type TrainingSession = {
  id: string;
  session_date: string;
  start_time: string | null;
  duration_min: number;
  session_type: SessionType;
  planned_intensity: number | null;
  goal_text: string | null;
};

// public.rpc_squad_check_jev_context. candidates tragen nie person_id, refs
// uebersetzt serverseitig zurueck und verlaesst den Server nie Richtung Modell.
export type JevCandidate = {
  ref: string;
  band: ReadinessBand | "unknown";
  planned_load_vs_own_norm: LoadLevel;
  released_deviations_7d: string[];
};
export type JevContext = {
  call_id: number | null;
  provider?: string;
  model?: string;
  rule_version?: string;
  session?: { duration_min: number; planned_intensity: number; session_type: SessionType };
  candidates: JevCandidate[];
  refs: { ref: string; person_id: string }[];
};

// Ergebnis der JEV-Stufe an die Oberflaeche. Nie eine Wahrscheinlichkeit oder
// Konfidenz, nie ein anderer Vorschlag als reduced.
export type JevOverlay = {
  person_id: string;
  suggestion: "reduced";
  hint_key: "j1";
  source: "jev";
};
export type JevRunStatus = "off" | "fallback" | "no_candidates" | "ok" | "partial";
export type JevRunResult = { status: JevRunStatus; overlays: JevOverlay[] };

// Ergebnisklassen in app.model_call_log (ohne pending).
export type ModelCallResultClass =
  | "ok"
  | "partial"
  | "invalid"
  | "timeout"
  | "rate_limited"
  | "http_error";
