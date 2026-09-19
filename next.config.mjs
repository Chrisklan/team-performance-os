/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Zweite Instanz (Mock-Tests) braucht ein eigenes Build-Verzeichnis.
  distDir: process.env.NEXT_DIST_DIR || ".next",
};

export default nextConfig;
