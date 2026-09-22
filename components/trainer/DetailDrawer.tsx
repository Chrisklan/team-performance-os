"use client";

// Team Performance OS — DetailDrawer.
// Read-only Drilldown: voller 5-Faktor-Breakdown, vergrößerte Sparkline mit
// deskriptiver Baseline-Abweichung, Heute-Teilnahme, Medical NUR Badge + Freigabe.
// Escape schließt, Fokus wandert beim Öffnen in den Drawer und bleibt darin (Tab-Trap).

import { useEffect, useRef } from "react";
import {
  FACTOR_ORDER,
  attendanceLabel,
  baselineDeviationPct,
  factorLabels,
  medicalClearanceLabel,
  medicalLabel,
  todayEventLabel,
} from "@/lib/trainer/aggregate";
import type { KaderMember, MedicalStatus } from "@/lib/trainer/types";
import { ReadinessPulsSparkline } from "./ReadinessPulsSparkline";

const MEDICAL_ICON: Record<MedicalStatus, string> = {
  green: "🟢",
  yellow: "🟡",
  orange: "🟠",
  red: "🔴",
};

const FOCUSABLE_SELECTOR =
  'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';

type DetailDrawerProps = {
  member: KaderMember | null;
  onClose: () => void;
};

export function DetailDrawer({ member, onClose }: DetailDrawerProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!member) return;
    closeButtonRef.current?.focus();

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        onClose();
        return;
      }
      if (event.key !== "Tab" || !panelRef.current) return;

      const focusable = panelRef.current.querySelectorAll<HTMLElement>(
        FOCUSABLE_SELECTOR,
      );
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];

      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [member, onClose]);

  if (!member) return null;

  const {
    player,
    readiness,
    baseline,
    medicalStatus,
    medicalClearance,
    attendance,
    todayEvent,
    hasCheckIn,
  } = member;
  const deviation = baselineDeviationPct(member);
  const clearanceLabel = medicalClearanceLabel(medicalClearance);

  return (
    <div className="fixed inset-0 z-50 flex justify-end">
      <div
        className="absolute inset-0 bg-black/60"
        onClick={onClose}
        aria-hidden="true"
      />
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="detail-drawer-title"
        className="relative flex h-full w-full max-w-md flex-col gap-8 overflow-y-auto border-l border-white/10 bg-panel p-8"
      >
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-sm text-muted">
              #{player.jersey} · {player.position}
            </p>
            <h2 id="detail-drawer-title" className="text-xl font-bold text-ink">
              {player.name}
            </h2>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            onClick={onClose}
            className="rounded-sm px-3 py-2 text-sm text-muted hover:text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal"
          >
            Schließen
          </button>
        </div>

        <section className="flex items-center justify-between gap-4">
          <div>
            {hasCheckIn ? (
              <p className="text-5xl font-bold text-ink">{readiness.value}</p>
            ) : (
              <p className="text-5xl font-bold text-muted">—</p>
            )}
            <p className="text-sm text-muted">
              {hasCheckIn && deviation !== null
                ? `${deviation > 0 ? "+" : ""}${deviation}% vom 4-Wo-Schnitt`
                : "Kein Check-in"}
            </p>
          </div>
          <ReadinessPulsSparkline
            series={baseline.series}
            rollingAvg={baseline.rollingAvg}
            width={160}
            height={56}
            variant="large"
            ariaLabel={`Readiness-Puls Baseline-Trend für ${player.name}, 4-Wochen-Schnitt ${Math.round(
              baseline.rollingAvg,
            )}`}
          />
        </section>

        <section>
          <h3 className="mb-3 text-sm font-bold text-ink">5-Faktor-Breakdown</h3>
          <div className="flex flex-col gap-3">
            {FACTOR_ORDER.map((factor) => {
              const value = readiness.factors ? readiness.factors[factor] : null;
              return (
                <div key={factor} className="flex items-center gap-3">
                  <span className="w-24 shrink-0 text-sm text-muted">
                    {factorLabels[factor]}
                  </span>
                  <div className="h-2 flex-1 rounded-full bg-white/5">
                    {value !== null && (
                      <div
                        className="h-full rounded-full bg-muted"
                        style={{ width: `${value}%` }}
                      />
                    )}
                  </div>
                  <span className="w-10 shrink-0 text-right text-sm text-ink">
                    {value ?? "—"}
                  </span>
                </div>
              );
            })}
          </div>
        </section>

        <section>
          <h3 className="mb-2 text-sm font-bold text-ink">Heute</h3>
          <p className="text-sm text-ink">
            {attendanceLabel(attendance)} · {todayEventLabel(todayEvent)}
          </p>
        </section>

        <section>
          <h3 className="mb-2 text-sm font-bold text-ink">Medical</h3>
          <p className="flex items-center gap-2 text-sm text-ink">
            <span aria-hidden="true" className="text-lg leading-none">
              {MEDICAL_ICON[medicalStatus]}
            </span>
            {medicalLabel(medicalStatus)}
            {clearanceLabel ? ` · ${clearanceLabel}` : ""}
          </p>
        </section>
      </div>
    </div>
  );
}
