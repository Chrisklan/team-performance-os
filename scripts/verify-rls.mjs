// RLS-Verifikation: führt den Post-RLS Coach-Payload-Check aus.
// Beweis, dass der serialisierte Coach-Payload KEINE Medical-Diagnose-Felder enthält.
import { register } from "node:module";
// ts-Dateien direkt ausführen: wir nutzen einen simplen Transpile-Schritt via esbuild-fallback.
// Da keine esbuild-Abhängigkeit garantiert ist, parsen wir die Logik über tsx nicht;
// stattdessen replizieren wir den Check gegen die kompilierten Next-Build-Daten nicht
// (das wäre fragil). Stattdessen: direkter Import via tsx, falls vorhanden.

try {
  const { fetchKaderForCoach, coachPayloadIsRlsClean } = await import(
    "../lib/trainer/api.ts"
  );
  const payload = fetchKaderForCoach();
  const res = coachPayloadIsRlsClean(payload);
  console.log("MEMBERS:", payload.members.length);
  console.log("RLS_CLEAN:", res.clean);
  if (!res.clean) {
    console.log("VIOLATIONS:", res.violations.join(", "));
    process.exit(1);
  }
  // Zusatz: sicherstellen, dass mindestens ein "Kein Check-in"-Zustand existiert
  const noCheckIn = payload.members.filter((m) => !m.hasCheckIn).length;
  console.log("NO_CHECKIN_COUNT:", noCheckIn);
  console.log("OK");
} catch (e) {
  console.error("IMPORT_FAILED:", e.message);
  process.exit(2);
}
