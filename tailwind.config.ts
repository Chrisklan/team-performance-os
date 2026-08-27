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
        // Design-Tokens v0.2 (Team Performance OS)
        surface: {
          DEFAULT: "#0F1620", // Primary Surface (tiefes Graphit-Nachtblau)
          card: "#16212E", // Secondary Surface / Cards
        },
        accent: "#3E8EFF", // Signal / Primär-Aktion (ruhiges Sport-Blau)
        warn: "#E23D3D", // Semantik Aufmerksamkeit/Warnung (gedämpftes Rot)
        ok: "#3FB87A", // Semantik Positiv (ruhiges Grün)
        ink: "#E6EDF3", // Text/Neutral auf Dunkel
        muted: "#8A98A8", // gedämpfter Neutrralton für Sekundärtext
      },
      fontFamily: {
        sans: ["Switzer", "system-ui", "-apple-system", "Segoe UI", "sans-serif"],
      },
      fontSize: {
        // Type-Skala (Build-Zwang): 12/14/16/20/24/32/40/56/72
        xs: "12px",
        sm: "14px",
        base: "16px",
        lg: "20px",
        xl: "24px",
        "2xl": "32px",
        "3xl": "40px",
        "4xl": "56px",
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
        sm: "8px",
        md: "12px",
        lg: "20px",
      },
    },
  },
  plugins: [],
};

export default config;
