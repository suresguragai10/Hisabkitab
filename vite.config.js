import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// base: "./" makes asset paths relative, so the build works whether it is
// served from a domain root OR a GitHub Pages subpath like /hisabkitab/.
export default defineConfig({
  plugins: [react()],
  base: "./",
});
