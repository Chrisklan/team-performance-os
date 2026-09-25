// Team Performance OS — Antwortformen der Medizin-Tueren (Web Vorlauf, Bridge Punkt 33).
// Jede Form bildet genau ab, was die Tuer liefert. Felder, die hier fehlen, liest
// die Oberflaeche nicht, auch wenn die Tuer sie mitschickt.

export type ClearanceStatus = "full" | "limited" | "individual" | "blocked";

// public.rpc_list_team_members
export type TeamMember = {
  id: string;
  display_name: string;
  person_position: string | null;
  clearance_status: ClearanceStatus;
};
export type TeamMembersPayload = { members: TeamMember[] };

// public.rpc_body_map_region_reports
export type RegionReport = {
  region: string;
  label: string;
  reports: number;
  highest: number | null;
  lastDate: string | null;
  legacy: boolean;
};
export type RegionReportsPayload = {
  personId: string;
  from: string;
  to: string;
  days: number;
  answeredDays: number;
  regions: RegionReport[];
};

// public.rpc_medical_checkins. body_map ist ein Feld je Region, seit AP-43 ein
// Array aus { region, pain, point?, svg? }; aeltere Zeilen tragen ein Objekt
// { region: pain }. Der Tippunkt wird nie gelesen (Modul Body-Map Abschnitt 8).
export type BodyMapRaw = unknown;
export type CheckinDay = {
  id: string;
  date: string;
  sleep_duration_min: number | null;
  sleep_quality: number | null;
  recovery: number | null;
  energy: number | null;
  mental_stress: number | null;
  mental_mood: number | null;
  mental_motivation: number | null;
  training_readiness: number | null;
  body_map: BodyMapRaw;
  pain_max: number | null;
  submitted_at: string | null;
};
export type CheckinsPayload = {
  person_id: string;
  from: string | null;
  to: string | null;
  checkins: CheckinDay[];
};

// public.rpc_medical_readiness
export type ReadinessBand = "low" | "moderate" | "high";
export type ReadinessDay = {
  date: string;
  score_total: number | null;
  band: ReadinessBand | null;
  factors: Record<string, number> | null;
  computed_at: string | null;
};
export type ReadinessPayload = {
  person_id: string;
  from: string | null;
  to: string | null;
  scores: ReadinessDay[];
};

// public.rpc_get_clearance, Medizinform (ADR-017 Abschnitt 4.2)
export type Clearance = {
  status: ClearanceStatus;
  load_note: string | null;
  valid_from: string;
  valid_to: string | null;
  set_by?: string | null;
  set_by_role?: string | null;
};
export type ClearanceProposal = {
  id: string;
  status: ClearanceStatus;
  rationale: string | null;
  proposed_by: string | null;
  proposed_by_role: string | null;
  proposed_at: string;
};
export type ClearancePayload = {
  person_id: string;
  clearance: Clearance | null;
  open_proposals: ClearanceProposal[] | null;
};

export type PersonDetail = {
  regions: RegionReportsPayload;
  checkins: CheckinsPayload;
  readiness: ReadinessPayload;
  clearance: ClearancePayload;
};

// public.rpc_get_person_deviations (LoadDeviation, Modul 5, Bridge Punkt 57 Teil 3).
// Feldnamen wie die Tuer sie liefert (backend/35_load_deviation.sql, Abschnitt 8).
export type DeviationMetric =
  | "sleep_duration_min"
  | "sleep_quality"
  | "recovery"
  | "mental_stress"
  | "mental_mood"
  | "mental_motivation"
  | "session_load"
  | "acute_chronic_ratio"
  | "pain_max";

export type DeviationState = "unreviewed" | "released" | "dismissed";

export type LoadDeviation = {
  id: string;
  person_id: string;
  metric: DeviationMetric;
  deviation_pct: number;
  detected_on: string;
  state: DeviationState;
  streak_days: number | null;
  days_out_7: number | null;
  z_mean_7: number | null;
  trend_slope_7: number | null;
  magnitude: number | null;
  statement_key: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  released_at: string | null;
  created_at: string;
};
