// Bundles the island's TypeScript into dist/ for Tauri.
import { build } from "esbuild";
import { cpSync, mkdirSync } from "node:fs";

mkdirSync("dist", { recursive: true });
cpSync("src/index.html", "dist/index.html");
cpSync("src/style.css", "dist/style.css");
await build({ entryPoints: ["src/main.ts"], bundle: true, format: "esm", target: "es2022", outfile: "dist/app.js", minify: true });
console.log("built dist/");
