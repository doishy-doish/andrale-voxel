#!/usr/bin/env bash
# deploy-itch — build the standalone itch.io dir from Perchance sources and push it with butler.
#
# Runs on your own machine (Debian). No AI sandbox, no credentials in chat.
# Verified against the official manual (https://itchio.github.io/butler/):
#   install : https://broth.itch.zone/butler/linux-amd64/LATEST/archive/default
#   push    : butler push <dir> <user>/<game>:<channel>  (re-push updates the file)
#   headless: BUTLER_API_KEY env (from https://itch.io/user/settings/api-keys)
#             or a one-time interactive `butler login`.
#
# Usage:
#   1. One-time: create the game on itch.io (New project, Kind: HTML, check
#      "This file will be played in the browser"), note user/game. If the
#      channel is new, tag it HTML5 on the dashboard after the first push.
#   2. Copy this generator's index.html + main.pjs + world.wat + src/tools/
#      (deploy-itch.sh, rebuild-kernel.mjs, build-wasm.mjs) from the Perchance
#      editor into one folder on this machine.
#   3. From that folder:
#        BUTLER_API_KEY=xxx bash /path/to/deploy-itch.sh user/game:html5
#
# Env overrides: INDEX_SRC (default index.html), META_SRC (default main.pjs),
# WAT_SRC (default world.wat), OUT_DIR (default ./andrale-itch),
# BUTLER_DIR (default ~/.cache/andrale-butler),
# REBUILD_MJS (default sibling rebuild-kernel.mjs),
# BUILD_MJS (default sibling build-wasm.mjs),
# WASM_OUT (default world.wasm next to WAT_SRC),
# SKIP_WASM_REBUILD=1 (push embedded kernel as-is),
# ALLOW_TOKEN_MISMATCH=1 (allow unexpected [token] counts),
# SMOKE_CHECK=0 (skip the local serve smoke gate), SMOKE_PORT (default 8766),
# DRAW_BUDGET (default 1500, manual gate via ?debug=1 flythrough),
# DEPLOY_LOG (default ./deploy-log.jsonl).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET="${1:-}"
INDEX_SRC="${INDEX_SRC:-index.html}"
META_SRC="${META_SRC:-main.pjs}"
WAT_SRC="${WAT_SRC:-world.wat}"
OUT_DIR="${OUT_DIR:-./andrale-itch}"
BUTLER_DIR="${BUTLER_DIR:-$HOME/.cache/andrale-butler}"
REBUILD_MJS="${REBUILD_MJS:-$SCRIPT_DIR/rebuild-kernel.mjs}"
BUILD_MJS="${BUILD_MJS:-$SCRIPT_DIR/build-wasm.mjs}"
WASM_OUT="${WASM_OUT:-$(dirname "$WAT_SRC")/world.wasm}"
USRV="$(date +%Y%m%d-%H%M)"
DRAW_BUDGET="${DRAW_BUDGET:-1500}"
DEPLOY_LOG="${DEPLOY_LOG:-./deploy-log.jsonl}"

if [ -z "$TARGET" ]; then
  echo "usage: $0 user/game:html5   (e.g. $0 andy/andrale-voxel:html5)" >&2
  exit 2
fi
for f in "$INDEX_SRC" "$META_SRC"; do
  if [ ! -f "$f" ]; then echo "missing source file: $f (copy it from the Perchance editor)" >&2; exit 1; fi
done
command -v python3 >/dev/null 2>&1 || { echo "need python3 on PATH" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "need node on PATH" >&2; exit 1; }

if [ "${SKIP_WASM_REBUILD:-}" = "1" ]; then
  echo "SKIP_WASM_REBUILD=1 — pushing embedded kernel as-is."
else
  for f in "$WAT_SRC" "$REBUILD_MJS" "$BUILD_MJS"; do
    if [ ! -f "$f" ]; then echo "missing kernel source: $f (copy world.wat + src/tools, or SKIP_WASM_REBUILD=1 to push as-is)" >&2; exit 1; fi
  done
  echo "rebuilding kernel from $WAT_SRC..."
  node "$REBUILD_MJS" "$BUILD_MJS" "$WAT_SRC" "$INDEX_SRC" "$WASM_OUT"
fi

BUTLER="$BUTLER_DIR/butler"
if [ ! -x "$BUTLER" ]; then
  echo "fetching butler..."
  mkdir -p "$BUTLER_DIR"
  TMP_ZIP="$BUTLER_DIR/butler.zip"
  URL="https://broth.itch.zone/butler/linux-amd64/LATEST/archive/default"
  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$TMP_ZIP" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TMP_ZIP" "$URL"
  else
    echo "need curl or wget to fetch butler" >&2; exit 1
  fi
  python3 - "$TMP_ZIP" "$BUTLER_DIR" <<'PYEOF'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PYEOF
  chmod +x "$BUTLER"
  rm -f "$TMP_ZIP"
fi

echo "building $OUT_DIR from $INDEX_SRC + $META_SRC..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
INDEX_SRC="$INDEX_SRC" META_SRC="$META_SRC" OUT_DIR="$OUT_DIR" python3 <<'PYEOF'
import os, re, sys

idx = open(os.environ["INDEX_SRC"], encoding="utf-8").read()
meta = open(os.environ["META_SRC"], encoding="utf-8").read()

def val(key):
    m = re.search(r"^" + key + r" = (.*)$", meta, re.M)
    if not m:
        sys.exit("FATAL: '%s = ...' not found in %s" % (key, os.environ["META_SRC"]))
    return m.group(1).strip()

hook, cred, note = val("hookLine"), val("credLine"), val("supportNote")
for token, rep, want in [("[hookLine]", hook, 2), ("[credLine]", cred, 2), ("[supportNote]", note, 1)]:
    n = idx.count(token)
    if n != want:
        msg = "FATAL: %s occurs %dx (recipe expects %d) — refusing to push an unexplained diff" % (token, n, want)
        if os.environ.get("ALLOW_TOKEN_MISMATCH") == "1":
            print("WARN: " + msg + " — continuing")
        else:
            sys.exit(msg)
    idx = idx.replace(token, rep)

srv = re.findall(r'<script type="text/x-server-plugin">.*?</script>', idx, re.S)
if len(srv) != 1:
    sys.exit("FATAL: expected 1 server-plugin block, found %d" % len(srv))
idx = idx.replace(srv[0], "")

m = re.search(r"^\s+title = (.*)$", meta, re.M)
title = m.group(1).strip() if m else "Andrale Voxel"

shim = """<script>
window.generatorName = "andrale-voxel";
window.root = {
  superFetch: function (u, o) { return fetch(u, o); },
  kv: { aether: {
    get: async function (k) { try { var v = localStorage.getItem("aether:" + k); return v == null ? null : JSON.parse(v); } catch (e) { return null; } },
    set: async function (k, v) { try { localStorage.setItem("aether:" + k, JSON.stringify(v)); } catch (e) {} },
    "delete": async function (k) { try { localStorage.removeItem("aether:" + k); } catch (e) {} }
  } }
};
</script>"""

page = ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no\">\n"
        "<title>" + title + "</title>\n"
        "<style>html,body{margin:0;padding:0;background:#0b0e14;height:100%;overflow:hidden}</style>\n"
        + shim + "\n</head>\n<body>\n" + idx + "\n</body>\n</html>\n")

dbg = '<script>if(new URLSearchParams(location.search).has("debug")){window.__dcCur=0;window.__dcMax=0;for(const k of["drawArrays","drawElements","drawArraysInstanced","drawElementsInstanced"]){const f=WebGLRenderingContext.prototype[k];if(f&&!f.__dcW){const w=function(){window.__dcCur++;return f.apply(this,arguments)};w.__dcW=true;WebGLRenderingContext.prototype[k]=w}}const tick=function(){if(window.__dcCur>window.__dcMax)window.__dcMax=window.__dcCur;window.__dcCur=0;requestAnimationFrame(tick)};requestAnimationFrame(tick)}</script>'
if "</head>" not in page:
    sys.exit("FATAL: no </head> in built page, cannot inject debug readout")
page = page.replace("</head>", dbg + "\n</head>", 1)

out = os.path.join(os.environ["OUT_DIR"], "index.html")
open(out, "w", encoding="utf-8").write(page)
print("wrote %s (%d bytes)" % (out, len(page.encode("utf-8"))))
PYEOF

OUT_DIR="$OUT_DIR" node -e 'const fs=require("fs");const h=fs.readFileSync(process.env.OUT_DIR+"/index.html","utf8");const m=h.match(/const WASM_B64 = "([A-Za-z0-9+/=]*)";/);if(!m){console.error("FATAL: no WASM_B64 literal in dist");process.exit(1)}const b=Buffer.from(m[1],"base64");if(!WebAssembly.validate(b)){console.error("FATAL: dist WASM_B64 failed WebAssembly.validate");process.exit(1)}console.log("wasm ok: "+b.length+" bytes");'

if [ "${SMOKE_CHECK:-1}" = "1" ]; then
  PORT="${SMOKE_PORT:-8766}"
  cd "$OUT_DIR"
  python3 -m http.server "$PORT" >/dev/null 2>&1 &
  SRV=$!
  cd - >/dev/null
  sleep 1
  CODE=$(curl -s -o /tmp/itch-smoke.html -w "%{http_code}" "http://127.0.0.1:$PORT/index.html?debug=1" || echo "000")
  if [ "$CODE" != "200" ] || ! grep -q 'id="gameCanvas"' /tmp/itch-smoke.html 2>/dev/null; then
    echo "FATAL: smoke check failed (http $CODE)" >&2
    kill $SRV 2>/dev/null
    exit 1
  fi
  rm -f /tmp/itch-smoke.html
  kill $SRV 2>/dev/null
  echo "smoke ok (200 + gameCanvas)."
fi
echo "draw-call gate (manual): serve $OUT_DIR, load index.html?debug=1, fly 10s, read window.__dcMax (budget $DRAW_BUDGET)."

if [ -z "${BUTLER_API_KEY:-}" ]; then
  echo "note: BUTLER_API_KEY not set — relying on stored login (run 'butler login' once if push fails)."
fi
if [ "${BUTLER_JSON:-}" = "1" ]; then
  "$BUTLER" push --json "$OUT_DIR" "$TARGET" --userversion "$USRV"
else
  "$BUTLER" push "$OUT_DIR" "$TARGET" --userversion "$USRV"
fi
echo "pushed $TARGET. First push to a new channel: tag it HTML5 on the game's dashboard page."
STATUS_OUT=$("$BUTLER" status "$TARGET" 2>&1 || true)
printf '{"ts":"%s","target":"%s","userversion":"%s","status":%s}\n' "$(date -u +%FT%TZ)" "$TARGET" "$USRV" "$(printf '%s' "$STATUS_OUT" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" >> "$DEPLOY_LOG"
echo "logged to $DEPLOY_LOG."
