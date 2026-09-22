import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Local dev only: proxy API calls to the FastAPI backend so the frontend
// can call relative paths (/score, /healthz) just like it does in prod
// behind CloudFront.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/score": "http://localhost:8080",
      "/healthz": "http://localhost:8080",
    },
  },
});
