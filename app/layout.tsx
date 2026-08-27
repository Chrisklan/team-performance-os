import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Team Performance OS — Trainer-Dashboard",
  description: "Kaderstatus in <60s: Readiness, Auffälligkeiten, Heute-Terminplan.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="de">
      <body>{children}</body>
    </html>
  );
}
