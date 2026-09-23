/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Zweite Instanz (Mock-Tests) braucht ein eigenes Build-Verzeichnis.
  distDir: process.env.NEXT_DIST_DIR || ".next",
  experimental: {
    // Medizinsicht (Bridge Punkt 33): der Client Router haelt dynamische Seiten
    // nicht vor. Zurueck oder erneut Oeffnen fragt den Server, und damit die Tuer,
    // statt Art. 9 Daten aus dem Speicher des Browsers zu zeigen.
    staleTimes: { dynamic: 0 },
  },
  async headers() {
    return [
      {
        // Nichts aus der Medizinsicht landet im Browser Cache oder einem Proxy.
        source: "/medizin/:path*",
        headers: [
          { key: "Cache-Control", value: "private, no-store, max-age=0" },
          { key: "Referrer-Policy", value: "no-referrer" },
        ],
      },
      {
        source: "/medizin",
        headers: [
          { key: "Cache-Control", value: "private, no-store, max-age=0" },
          { key: "Referrer-Policy", value: "no-referrer" },
        ],
      },
    ];
  },
};

export default nextConfig;
