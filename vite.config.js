import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// base: "./" keeps asset paths relative so it works on a GitHub Pages subpath.
export default defineConfig({
  plugins: [react()],
  base: "./",
});
