"use server";

// Team Performance OS — Einheit anlegen oder aendern (AP-68 Tueren, AP-69 Seite).
// Ruft public.rpc_create_training_session bzw. public.rpc_update_training_session
// mit dem JWT der angemeldeten Person. Die Tueren pruefen Rolle (nur Staff),
// Team und Werte selbst, hier nur die Form, damit kein offensichtlich falscher
// Wert eine Ablehnungszeile erzeugt.

import { revalidatePath } from "next/cache";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { classifyRpcError } from "@/lib/trainer/errors";
import { isUuid } from "@/lib/medical/role";
import { SESSION_TYPES, type SessionType, type TrainingSession } from "./types";

export type SessionInput = {
  sessionId: string | null;
  sessionDate: string;
  startTime: string | null;
  durationMin: number;
  sessionType: SessionType;
  intensity: number;
  goalText: string | null;
};

export type SaveSessionResult = { ok: true; session: TrainingSession } | { ok: false; message: string };

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^\d{2}:\d{2}$/;

export async function saveTrainingSession(input: SessionInput): Promise<SaveSessionResult> {
  if (!DATE.test(input.sessionDate)) return { ok: false, message: "Datum fehlt." };
  if (input.startTime !== null && !TIME.test(input.startTime)) return { ok: false, message: "Uhrzeit im Format hh:mm angeben." };
  if (!Number.isInteger(input.durationMin) || input.durationMin < 1 || input.durationMin > 300) {
    return { ok: false, message: "Dauer zwischen 1 und 300 Minuten angeben." };
  }
  if (!Number.isInteger(input.intensity) || input.intensity < 1 || input.intensity > 10) {
    return { ok: false, message: "Intensität zwischen 1 und 10 angeben." };
  }
  if (!(SESSION_TYPES as readonly string[]).includes(input.sessionType)) return { ok: false, message: "Art der Einheit wählen." };
  const goal = input.goalText?.trim() ? input.goalText.trim().slice(0, 2000) : null;

  const supabase = createSupabaseServerClient();
  const common = {
    p_session_date: input.sessionDate,
    p_start_time: input.startTime,
    p_duration_min: input.durationMin,
    p_session_type: input.sessionType,
    p_planned_intensity: input.intensity,
    p_goal_text: goal,
  };

  if (input.sessionId !== null && !isUuid(input.sessionId)) return { ok: false, message: "Einheit nicht gefunden." };

  const { data, error, status } =
    input.sessionId === null
      ? await supabase.rpc("rpc_create_training_session", common)
      : await supabase.rpc("rpc_update_training_session", { p_session_id: input.sessionId, ...common });

  if (error) return { ok: false, message: classifyRpcError(error, status).message };
  const row = data as TrainingSession | null;
  if (!row || typeof row.id !== "string") return { ok: false, message: "Einheit konnte nicht gespeichert werden." };

  revalidatePath("/planung");
  return { ok: true, session: row };
}
