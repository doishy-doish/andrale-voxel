#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
const [modPath, watPath, htmlPath, wasmOut, wabtCache] = process.argv.slice(2);
if (!modPath || !watPath || !htmlPath) {
  console.error("usage: rebuild-kernel.mjs <build-wasm.mjs> <world.wat> <index.html> [world.wasm-out] [wabt-cache]");
  process.exit(2);
}
const table = {
  "src/world.wat": watPath,
  "index.html": htmlPath,
  "src/world.wasm": wasmOut || watPath.replace(/\.wat$/, ".wasm"),
};
if (wabtCache) table["scratch/wabt36.js"] = wabtCache;
const fs = {
  readTextFile: async (p) => readFile(table[p] || p, "utf8"),
  writeTextFile: async (p, s) => writeFile(table[p] || p, s, "utf8"),
  readFile: async (p) => new Uint8Array(await readFile(table[p] || p)),
  writeFile: async (p, b) => writeFile(table[p] || p, b),
};
const target = modPath.startsWith("file:") ? modPath : "file://" + modPath;
const m = await import(target);
const r = await m.build({ fs });
console.log(JSON.stringify(r));
if (!r.ok) process.exit(1);
