# Planova — Claude Design canvas, captured

Source artifact: `https://claude.ai/artifact/E3BCxpMCA1Fs6w2HJG6AoW` (title **Planova**, a Claude
"Design (canvas)" artifact — 2 pages, 72 artboards covering an event-planning + live-tracking app).

Everything here was extracted from the running canvas, not typed by hand.

## Layout

| Path | What it is |
|---|---|
| `index.html` | Gallery of every artboard with thumbnail + link. Open this first. |
| `desktop/*.html` | 38 standalone desktop artboards (full rendered DOM, ~240–490 KB each). |
| `mobile/*.html` | 34 standalone mobile artboards. |
| `desktop-png/*.png` | Full-page renders of each desktop artboard at 2× DPR. |
| `mobile-png/*.png` | Same for mobile. |
| `source/` | The **authored** files, exactly as served: `project/D-*.dc.html`, `project/M-*.dc.html`, `project/canvas.json`, design-system CSS/tokens, and the `artifact-type/` runtime. |
| `../planova-inventory.md` | Screen titles (in canvas order) + file manifest with sizes. |
| `../planova-files.json` | Raw `/api/frame/...` metadata (file list, sha256s, title). |
| `../net/`, `../net2/`, `../frames/` | Raw capture material: page DOM snapshots, shell bundles, transport payloads. |
| `../frame-net/` | The canvas frame's own request log. |

## Two kinds of HTML — pick the right one

1. **`source/project/*.dc.html`** — the authored templates. Small (0.8 KB–123 KB), readable,
   contain the design's own structure and inline component CSS: `<script src="./support.js">`,
   `window.__dcFiles`, `data-dc-tpl` placeholders. This is what a human wrote.
2. **`desktop/` and `mobile/`** — the rendered result. The `dc-runtime` expands the templates into
   ~240 KB of final DOM. This is what the screen actually looks like; it opens in any browser with
   no tooling.

## How the capture worked

- The canvas host serves files at `https://<frame-uuid>.frame.claudeusercontent.com/_f/<ver>/<path>`
  (e.g. `/_f/1792749594-bdac/project/D-Join.dc.html`). Both `_files.json` and `project/canvas.json`
  are publicly readable there; the artboard *content* renders only for a viewer who can see the
  data, but the file bytes are not auth-gated.
- Artboards render inside per-artboard `srcdoc` iframes at a `~7.1%` canvas zoom. Their live
  documents were read via `iframe.contentDocument.documentElement.outerHTML` over CDP, one per
  board, for both pages (`[data-mega-artboard]` nodes).
- Asset references (`/_blob/<hash>`, `/_f/...`) were rewritten to absolute frame-host URLs so each
  HTML file renders standalone (logo and fonts load over the network).
- PNGs were produced by opening each HTML in Edge (CDP), sizing the viewport to the measured
  document, and capturing beyond-viewport at `deviceScaleFactor: 2`.

## Known limitations

- The dumped pages still reference three `blob:` runtime scripts that only exist in the live canvas.
  They are non-visual; the artifacts render without them.
- PNG widths land at ~935 px CSS (artboards are authored 1440 px wide but the canvas document
  carries its own scale), so PNGs are ~1870 px wide at 2×.
- `_files.json` lists 98 files; all 98 were downloaded (6.54 MB).
- Interaction states (hover, open menus, multi-step flows) are frozen as captured. The
  `…-Wizard`, `…-Errors`, `…-Blocked` boards carry those states explicitly.

## Tooling used (kept in `tools/`)

`cdp-extract.mjs` · `cdp-frames.mjs` · `cdp-eval.mjs` · `cdp-cookies.mjs` · `cdp-capture-all.mjs` ·
`cdp-net-frame.mjs` · `planova-dump.mjs` · `planova-shots.mjs` · `planova-absolutize.mjs` ·
`planova-source.mjs` · `planova-inventory.mjs` · `planova-index.mjs`
