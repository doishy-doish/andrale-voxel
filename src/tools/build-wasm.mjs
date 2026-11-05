// build-wasm.mjs — the ONE repeatable way to rebuild src/world.wasm and re-embed it.
//
// Before this file existed the rebuild was an ad-hoc recipe typed into an agent
// eval each time: fetch the wabt module, eval it, parse/validate/toBinary, then
// hand-edit the WASM_B64 line of index.html (a single ~16 KB line, which is
// exactly the kind of edit a human -- or an agent reading a truncated file --
// gets subtly wrong). Three things are therefore fragile and all three are
// handled here:
//
//   1. THE BINARY. wabt's `toBinary` returns an `out` whose `buffer` is a
//      WebAssembly MEMORY buffer, not a tight ArrayBuffer. `new Uint8Array(out)`
//      is wrong (it stringifies the object and yields a 0-length array), and
//      `new Uint8Array(out.buffer)` is wrong too (it includes whatever slack the
//      allocator left). The only correct view is the offset/length triple.
//
//   2. THE EMBED. index.html carries the kernel as a base64 string literal and
//      `loadWasm()` decodes it with `atob`. That string is the SOURCE OF TRUTH at
//      runtime, so the build has to write both the binary and the literal, and
//      then prove -- by decoding the literal it just wrote -- that the two agree.
//      A build that writes world.wasm but not the literal silently ships the old
//      kernel, which is the worst possible failure for this project: the gate
//      would pass (it reads world.wasm), the preview would pass (it decodes the
//      literal via atob), and only the two TOGETHER reveal the drift.
//
//   3. THE COMMENT-ONLY EDIT. wabt is deterministic, so a `.wat` change that
//      touches only a comment (`;;`) or only whitespace must produce a
//      BYTE-IDENTICAL binary. `build` reports that case explicitly rather than
//      hiding it in a diff, because it is the cheapest available proof that the
//      toolchain is not the thing that moved.
//
// Usage (from execute_js, which has the workspace fs):
//   const m = await import(<blob url of this file>);
//   return await m.build({ fs });                       // uses scratch/wabt36.js if present
//   return await m.build({ fs, check: false });          // skip the on-disk .wasm compare
//
// `wabtSrc` may be passed directly to skip the fetch (the agent caches the 1.2 MB
// module at scratch/wabt36.js; scratch is ephemeral, hence the fetch fallback).
// Nothing here is imported by the shipped generator -- it is a source-tree tool,
// the same category as kernel-gate.mjs and gen-bench.mjs.

export const WABT_URL = "https://cdn.jsdelivr.net/npm/wabt@1.0.36/index.js";
export const LOCAL_WABT = "scratch/wabt36.js";
export const WAT_PATH = "src/world.wat";
export const WASM_PATH = "src/world.wasm";
export const HTML_PATH = "index.html";

// The literal is anchored on `const WASM_B64 = "` and a permissive base64 body so
// a truncated read can never match a prefix of it. `embed` asserts EXACTLY ONE
// match: two literals would mean a previous edit duplicated the kernel, which
// must be fixed by hand rather than silently having one of them overwritten.
const B64_RE = /const WASM_B64 = "([A-Za-z0-9+/=]*)";/;
const b64Len = (n) => Math.ceil(n / 3) * 4;

// Chunked so a 16 KB buffer never becomes a 16 000-argument `String.fromCharCode`
// call (V8 throws RangeError somewhere around 60-125 k arguments, and the margin
// is engine-dependent). 0x8000 is the size the platform's own helpers use.
export function bytesToB64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}
export function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function fnv1a(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) { h ^= bytes[i]; h = Math.imul(h, 0x01000193) >>> 0; }
  return h >>> 0;
}

// Load wabt 1.0.36. The pinned version matters: wabt's binary encoding is stable
// for a given version but not guaranteed across them, and a wabt upgrade that
// changes one encoding byte would look exactly like a kernel change to the gate.
export async function loadWabt({ fs, wabtSrc } = {}) {
  let src = wabtSrc;
  if (!src && fs) {
    try { src = await fs.readTextFile(LOCAL_WABT); } catch (_) { src = null; }
  }
  if (!src) {
    const r = await fetch(WABT_URL);
    if (!r.ok) throw new Error("wabt fetch failed: " + r.status);
    src = await r.text();
  }
  // The UMD bundle assigns `WabtModule` when evaluated as a script; `(0,eval)` in
  // module/global scope is the only way to do that here (a `new Function` body
  // cannot see the module's own bindings, and an ESM `import` of the UMD file
  // throws). Verified in both the page and the execute_js worker.
  const WabtModule = await (0, eval)(src + "\n;WabtModule");
  const wabt = await WabtModule();
  return { wabt, srcLen: src.length };
}

// Compile `.wat` text -> exact bytes. Throws with wabt's own diagnostics on a
// parse/validate failure; `destroy()` is in a finally so a bad parse cannot leak
// the module (it is ~1 MB of wasm heap per instance).
export function compileWat(wabt, wat, name = "world.wat") {
  const mod = wabt.parseWat(name, wat);
  try {
    mod.validate();
    // `{log:false}` and nothing else: wabt's other toBinary options already default
    // to the values this project builds with, and spelling them out would invite a
    // future edit to the option list to become a silent encoding change.
    const out = mod.toBinary({ log: false });
    return new Uint8Array(out.buffer, out.byteOffset, out.byteLength);
  } finally { mod.destroy(); }
}

// Embed `bytes` as the WASM_B64 literal of `html`. Returns the new html.
export function embedB64(html, bytes) {
  const m = html.match(new RegExp(B64_RE.source, "g"));
  if (!m || m.length !== 1) throw new Error("expected exactly 1 WASM_B64 literal, found " + (m ? m.length : 0));
  const b64 = bytesToB64(bytes);
  const next = html.replace(B64_RE, () => 'const WASM_B64 = "' + b64 + '";');
  // Round-trip through the WRITER'S OWN decoder path (atob), so the assertion
  // covers the literal and not the `bytes` we already had in hand.
  const back = b64ToBytes(next.match(B64_RE)[1]);
  if (back.length !== bytes.length) throw new Error("embed round-trip length " + back.length + " != " + bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    if (back[i] !== bytes[i]) throw new Error("embed round-trip differs at byte " + i);
  }
  return next;
}

// The whole build. `fs` is the workspace fs (execute_js) or any object with
// readTextFile/writeTextFile/readFile/writeFile; without it, pass `wat`/`html`
// explicitly and the result is returned instead of written.
export async function build({ fs, wabtSrc, wat, html, write = true, check = true, name = "world.wat" } = {}) {
  const t0 = Date.now();
  const hadFs = !!fs;
  if (!wat && fs) wat = await fs.readTextFile(WAT_PATH);
  if (!html && fs) html = await fs.readTextFile(HTML_PATH);
  if (typeof wat !== "string" || typeof html !== "string") throw new Error("build needs {fs} or {wat, html}");

  const { wabt, srcLen } = await loadWabt({ fs, wabtSrc });
  const bytes = compileWat(wabt, wat, name);

  // The old binary (if any) is read BEFORE anything is written, so the compare is
  // against the state the tree was actually in.
  let old = null;
  if (fs) { try { old = await fs.readFile(WASM_PATH); } catch (_) { old = null; } }
  const oldHash = old ? fnv1a(old) : null;
  const newHash = fnv1a(bytes);

  const nextHtml = embedB64(html, bytes);
  const embedded = b64ToBytes(nextHtml.match(B64_RE)[1]);

  if (fs && write) {
    await fs.writeFile(WASM_PATH, bytes);
    if (nextHtml !== html) await fs.writeTextFile(HTML_PATH, nextHtml);
  }

  return {
    ok: true,
    watBytes: wat.length,
    wasmBytes: bytes.length,
    wasmHash: newHash.toString(16).padStart(8, "0"),
    prevWasmBytes: old ? old.length : null,
    prevWasmHash: oldHash === null ? null : oldHash.toString(16).padStart(8, "0"),
    // Byte-identical to the previous build: the source change was comment-only or
    // the toolchain moved under us. Either way this is the number to report.
    unchanged: oldHash !== null && oldHash === newHash,
    embeddedBytes: embedded.length,
    htmlBytes: nextHtml.length,
    htmlChanged: nextHtml !== html,
    b64Len: b64Len(bytes.length),
    wabtBytes: srcLen,
    check,
    wrote: !!(fs && write),
    hadFs,
    ms: Date.now() - t0,
  };
}

// Guard for a test that only wants to know the tree is self-consistent: does the
// literal in index.html decode to exactly src/world.wasm?
export async function verify({ fs, html } = {}) {
  if (!html && fs) html = await fs.readTextFile(HTML_PATH);
  const wasm = await fs.readFile(WASM_PATH);
  const m = html.match(B64_RE);
  if (!m) return { ok: false, error: "no WASM_B64 literal" };
  const lit = b64ToBytes(m[1]);
  let diff = -1;
  if (lit.length !== wasm.length) diff = -2;
  else for (let i = 0; i < wasm.length; i++) if (lit[i] !== wasm[i]) { diff = i; break; }
  return { ok: diff === -1, wasmBytes: wasm.length, literalBytes: lit.length, diff,
    wasmHash: fnv1a(wasm).toString(16).padStart(8, "0"),
    literalHash: fnv1a(lit).toString(16).padStart(8, "0"), b64Len: m[1].length };
}
