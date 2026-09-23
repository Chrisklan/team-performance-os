// Team Performance OS — Adresse ohne gueltige Person-ID in der Medizinsicht.
// Kein Aufruf einer Tuer ist erfolgt (page.tsx prueft die UUID zuerst).

import { MedicalStateScreen } from "@/components/medical/MedicalStateScreen";

export default function MedizinPersonNotFound() {
  return <MedicalStateScreen kind="PERSON_NOT_FOUND" />;
}
