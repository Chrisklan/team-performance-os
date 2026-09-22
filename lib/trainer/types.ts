// Team Performance OS — Datenmodell (Trainer-Frontend, MVP Phase 4)
// Felder gespiegelt aus Produktmodell v0.1 §3 + RLS-Matrix.md §3.
// Medical-Inhalte sind hier BEWUSST NICHT typisiert: die Coach-Rolle darf sie
// laut RLS-Matrix (medical_status_view) NUR als Status-Badge sehen. Der Daten-Layer
// (fixtures.ts) liefert sie für Coach niemals im Payload.

export type MedicalStatus = "green" | "yellow" | "orange" | "red"; // 🟢🟡🟠🔴

export type AttendanceStatus =
  | "anwesend"
  | "verletzt"
  | "reha"
  | "national"
  | "urlaub"
  | "krank";

export type TodayEvent = "training" | "spiel" | "none";

// Die drei Stufen aus app.app_readiness_band. Das ist alles, was Staff sieht.
export type ReadinessBand = "low" | "moderate" | "high";

export type PlayerBaseline = {
  // rolling 4-Wo. Profil pro Metrik (Baseline.rolling_avg).
  // Hier als Mini-Serie für die Readiness-Puls-Sparkline (Baseline-Trend).
  series: number[]; // z.B. letzte 7 Tage readiness-nahe Werte
  rollingAvg: number;
};

export type Player = {
  id: string;
  jersey: number; // Rückennummer
  name: string;
  position: string; // Stammposition
};

// MEDIZIN-GATE. Staff bekommt die Zustandsklasse, nie den Zahlwert und nie die
// Faktoren: beide sind in der kanonischen Matrix fuer coach und athletic_coach
// fett mit "-" markiert (Modul Rollen und Medizin Gate, Abschnitt 5). Bis zum
// 2026-09-22 lieferte app.rpc_morning_ops trotzdem value und factors mit
// (Befund N7), seit Migration 20260922000033 traegt der Payload nur noch band.
// Wer hier wieder ein Zahlfeld ergaenzt, hebt das Gate auf und braucht nach der
// harten Regel des Moduls ein neues ADR. Den vollen Wert liefert
// app.rpc_readiness_full, und die kennt nur physio, doctor und die Person selbst.
export type ReadinessScore = {
  band: ReadinessBand | null; // null = kein Readiness-Eintrag fuer heute
};

export type KaderMember = {
  player: Player;
  readiness: ReadinessScore; // null-Wert => "Kein Check-in"
  baseline: PlayerBaseline; // Trendgrundlage (immer vorhanden, auch ohne heutigen Check-in)
  medicalStatus: MedicalStatus; // NUR Badge (RLS: medical_status_view)
  medicalClearance: "frei" | "eingeschraenkt" | "gesperrt" | null; // NUR Freigabe-Status (RLS)
  attendance: AttendanceStatus;
  todayEvent: TodayEvent;
  hasCheckIn: boolean; // expliziter Zustand "Kein Check-in"
};

// Was die Coach-API liefert (post-RLS): KEINE Medical-Diagnose-Felder.
// Dieser Typ ist der Test-Anker: ein Grep auf den serialisierten Payload darf
// keine diagnosis/symptoms/treatment/reha_phase-Schlüssel enthalten.
export type CoachKaderPayload = {
  kaderName: string;
  syncState: "live" | "last_sync";
  asOf: string; // ISO-Datum
  members: KaderMember[];
};
