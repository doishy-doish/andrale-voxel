# Pushing builds to itch.io without a local butler

Researched 2026-10-17 from primary sources (itch API docs, butler + go-itchio +
httpkit source on GitHub). No papers involved — this is API archaeology, not research.

## Verdict

Butler is replaceable. Its push is plain HTTPS end to end — no sockets, no
native code required. Two viable paths:

### Path 1 (mainstream, recommended): CI + butler + API key — LOCKED IN 2026-10-17

GitHub Action builds the zip, runs `butler push dir user/game:channel` with a
`BUTLER_API_KEY` secret. Zero custom code, diffs/patches free, fully automatic
after setup. This is what top shippers do.

### Path 2 (pure code, no binary anywhere): reimplement the wharf handshake — PARKED, R&D only

All verified against source:

1. Auth: plain API key works on wharf endpoints (`ClientWithKey`, base
   `https://api.itch.io`). User pastes key at runtime — NEVER store it in src/.
2. `POST /wharf/builds` (target, channel, user_version) → build id. Fresh
   channel returns parent id 0: patch is computed against an EMPTY signature,
   so no parent download is ever needed for first pushes.
3. `POST /wharf/builds/{id}/files` twice (patch + signature) → GCS resumable
   `uploadUrl` per file.
4. PUT bytes to the upload URLs (Google Cloud Storage resumable protocol,
   256KB chunks, Content-Range — reimplementable with fetch).
5. `POST /wharf/builds/{id}/files/{fid}` to finalize each file.

### Hard constraints (empirically confirmed)

- Browser-direct fetch to `api.itch.io` FAILS (CORS — probed live, `Failed to
  fetch` on both the endpoint and preflight). So this cannot run in page JS,
  workers, or the character-code iframe directly. It MUST run through a
  CORS-free relay (agent proxy tooling, a tiny user-run relay, or CI).
- The one unbuilt piece: the pwr patch/signature writer (block hashes +
  compression per the `wharf/pwr` Go package). Everything around it is trivial
  JSON + PUTs. Porting pwr is the actual project; estimate from source size is
  small (single-purpose format), but its exact block/hash/compression params
  must be read from `github.com/itchio/wharf`, not guessed.

## Next step when green-lit

Read the wharf `pwr` package source, port the writer to JS, prototype the full
handshake with a throwaway channel + fresh API key, verify the build processes
server-side. Keep the key out of the workspace at every step.

## Status 2026-10-17 — LIVE CHAIN, method locked: in-browser Wharf runner

- Target: `doishy-doish/andrale-voxel` (game_id 5173853, channel `html5`).
  Verified against live build records (`GET /wharf/builds/{id}`, key in-page only).
- Chain (all `completed`): 2145748 → 2146045 (userversion 2026-10-17-1406) →
  2146256 (userversion 2026-10-17-1434) → 2147080 (userversion 2026-10-17-1650,
  parent 2146256 — ships the saved shove + art pass + mobile-fix batch).
  Next push diffs against parent 2147080; server assigns the build id, version strings are timestamps.
- `scratch/wharf-pwr/pwr.mjs`: pure-JS writer (proto3 encoder, βhash weak +
  vendored MD5 strong, 64KB blocks, gzip bodies, exact wire framing). Verified
  against the real `pwr.proto`/`tlc.proto` via protobufjs: magics, headers,
  container, every block hash, ops round-trip byte-exact incl. empty files.
- Deviations from butler to know: gzip (not brotli-q1) bodies, header quality 0.
  Server reads the algorithm from the header; server acceptance PROVEN by the
  three completed builds above. page-lib `GZIP=1` is correct — NEVER touch it
  (build 2145698 died flipping the header to 2 on a brotli body).
- Transport: fetch-plugin proxy forwards PUT + Content-Range + binary bodies
  byte-exact. Poll builds with GET, not POST.
- Architecture: handshake runs in `page_eval` (the proxy refuses worker-origin
  requests). Key (`localStorage.__wharfKey`, preview origin) + slug + DIST_URL
  stay in-memory only — `MAIN(KEY, SLUG, DIST_URL, resume)` constants at call
  time, never written to the workspace. No slug is cached anywhere by design.
- Push recipe: `execute_js` assembles runner in-memory → `tools.page_eval`,
  timeoutMs 500000. Precondition: owner SAVE verified in the served doc first.
- STANDBY lifted 2026-10-17: owner SAVE verified (lastEditTime + unsaved=false),
  dist rebuilt from saved doc (3,873,013 B, WASM valid), build 2147080 pushed +
  completed. Lane parked; next readings decide what builds next.
