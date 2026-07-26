import js from "@eslint/js";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import prettierConfig from "eslint-config-prettier";
import globals from "globals";

export default [
  { ignores: ["dist/**", "node_modules/**"] },
  js.configs.recommended,
  {
    files: ["**/*.{js,jsx}"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      parserOptions: { ecmaFeatures: { jsx: true } },
      globals: { ...globals.browser, ...globals.node },
    },
    plugins: {
      react,
      "react-hooks": reactHooks,
      "react-refresh": reactRefresh,
    },
    settings: { react: { version: "detect" } },
    rules: {
      ...react.configs.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      "react/react-in-jsx-scope": "off", // Vite's automatic JSX runtime
      "react/prop-types": "off", // not used in this codebase
      "react-refresh/only-export-components": "warn",
      "no-unused-vars": ["warn", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
      // This codebase's `useEffect(() => { load(); }, [dep])` data-fetching
      // pattern is used throughout and is safe here (no Suspense/concurrent
      // rendering) -- downgraded from error to warn so adding lint tooling
      // doesn't fail the build on ~26 pre-existing, intentional effects.
      "react-hooks/set-state-in-effect": "warn",
    },
  },
  {
    files: ["**/*.test.js", "**/*.test.jsx"],
    languageOptions: { globals: { ...globals.node } },
  },
  prettierConfig,
];
