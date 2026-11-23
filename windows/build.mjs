// Bundles the island and the dashboard into dist/ for Tauri.
import { build } from "esbuild";
import { cpSync, mkdirSync } from "node:fs";

mkdirSync("dist", { recursive: true });
for (const f of ["index.html", "dashboard.html", "shared.css", "style.css", "dashboard.css", "icon.png"]) cpSync(`src/${f}`, `dist/${f}`);
const common = { bundle: true, format: "esm", target: "es2022", minify: true };
await build({ ...common, entryPoints: ["src/main.ts"], outfile: "dist/app.js" });
await build({ ...common, entryPoints: ["src/dashboard.ts"], outfile: "dist/dashboard.js" });
console.log("built dist/");
