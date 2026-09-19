// Team Performance OS — Startseite leitet auf das Dashboard. Ohne Login greift die
// Middleware und schickt auf /login.

import { redirect } from "next/navigation";

export default function HomePage() {
  redirect("/dashboard");
}
