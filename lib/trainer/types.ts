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

export type ReadinessFactors = {
  // 5-Faktor-Breakdown aus ReadinessScore.factors (Quelle: Modul Readiness Score).
  // Werte sind bereits gewichtete, baseline-rel. Heuristik-Werte (0-100 je Faktor).
  sleep: number;
  recovery: number;
  mental: number;
  muscle: number; // MEDICINE-GATED im Quellmodul; im Coach-Payload als Wert vorhanden, aber nicht diagnostisch interpretiert
  load: number;
};

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

export type ReadinessScore = {
  value: number | null; // 0-100, null = kein Check-in heute
  factors: ReadinessFactors | null; // null = kein Check-in
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
