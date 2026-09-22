import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        // Design-Tokens v1.0 Marine, Anker bsv-live.de (docs/design/README.md).
        // Verbindliche Namen, gemessen, nicht abgeleitet. Niemand erfindet Zwischenwerte.
        field: "#04284C",
        panel: "#063E75",
        signal: "#FFD800",
        ink: "#EAF1F8",
        muted: "#9DB6CE",
        stop: "#E23D3D",
        "stop-ink": "#FF8A8A",
        // Ergaenzt 2026-09-22 (AP-54-Nachtrag, von Chris entschieden): Datenskalen
        // (Faktor-Balken, Score-Note, Readiness-Puls, Erfolgszustand) brauchen mehr
        // als eine Aufmerksamkeitsfarbe. clear stand schon ungenutzt im Mockup,
        // caution und notice sind neu. Ampel ueber vier Stufen: stop -> caution ->
        // notice -> clear, alle bewusst fern von signal (Gelb).
        clear: "#3DD68C",
        caution: "#F2711C",
        notice: "#8BC34A",
      },
      fontFamily: {
        sans: ["Roboto", "system-ui", "-apple-system", "Segoe UI", "sans-serif"],
        display: ["Roboto Condensed", "system-ui", "-apple-system", "Segoe UI", "sans-serif"],
      },
      fontSize: {
        // Type-Skala v1.0 (verbindlich): 12/14/16/20/32/40/72
        xs: "12px",
        sm: "14px",
        base: "16px",
        lg: "20px",
        xl: "32px",
        "2xl": "32px",
        "3xl": "40px",
        "4xl": "72px",
        "5xl": "72px",
      },
      spacing: {
        // Spacing-Skala (Build-Zwang): 4/8/12/16/24/32/48/64/96
        1: "4px",
        2: "8px",
        3: "12px",
        4: "16px",
        6: "24px",
        8: "32px",
        12: "48px",
        16: "64px",
        24: "96px",
      },
      borderRadius: {
        // Radius v1.0 (verbindlich): 0/4/8
        sm: "4px",
        md: "8px",
        lg: "8px",
      },
    },
  },
  plugins: [],
};

export default config;
