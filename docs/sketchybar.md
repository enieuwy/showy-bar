# SketchyBar integration

## What gets added

Per provider in the filtered render set (`codexbar usage --format json`
after `CB_BARS_PROVIDERS` / `CB_BARS_PROVIDERS_EXCLUDE` are applied):

- `cb_bars.<provider>.icon`  — provider PNG (rendered from CodexBar's SVG)
- `cb_bars.<provider>.bar`   — multi-segment usage bar PNG
- `cb_bars.<provider>.label` — countdown label

Plus:

- `cb_bars.trigger`     — invisible item that runs the plugin every
  `CB_BARS_SKETCHYBAR_UPDATE_FREQ` seconds.
- `cb_bars_bracket`     — pill background grouping the triple.

Provider adds/removals reconcile against that filtered set on the next plugin
tick; no `sketchybar --reload` is required after the initial install.

## Pill geometry

The bracket reads `CB_BARS_SKETCHYBAR_PILL_RADIUS`,
`CB_BARS_SKETCHYBAR_PILL_HEIGHT`, and `CB_BARS_SKETCHYBAR_PILL_COLOR`.
Defaults are `14`, `28`, and `0xcc24273a`.

For compatibility with existing sketchybarrc setups, the bootstrap item also
forwards `PILL_RADIUS` / `PILL_HEIGHT` into those envs when the explicit
`CB_BARS_SKETCHYBAR_PILL_*` knobs are unset.

## Click action

Clicking the usage bar, label, or a non-degraded provider icon runs
`CB_BARS_SKETCHYBAR_CLICK` (default: `open -b com.steipete.codexbar`),
which brings the CodexBar app forward. When a provider status is degraded
(`minor`, `maintenance`, `major`, or `critical`) and CodexBar supplies an
HTTP(S) status URL, clicking that provider's icon opens the status page
instead.

## Provider filters

`CB_BARS_PROVIDERS` is an allow-list. `CB_BARS_PROVIDERS_EXCLUDE` removes
providers from that result afterward, so the exclude list wins on overlap.

Examples:

- empty / empty → every provider CodexBar currently reports
- include only → only those providers
- exclude only → everything except those providers
- include + exclude → the include set minus the exclude set

## PNG bar layout

```
+-------------------------------- 80 px ---------------------------+
|                          primary (5h)                            |   ← row 1
+------------------------------------------------------------------+
|                          secondary (7d)                          |   ← row 2
+------------------------------------------------------------------+
|                          tertiary (varies)                       |   ← row 3 (only when present)
+------------------------------------------------------------------+
```

When a provider has only primary + secondary (most common), the image is
18 px tall; with tertiary it's 22 px.

## Customizing colors

Set `CB_BARS_PALETTE_GOOD/WARN/BAD/UNKNOWN/TRACK/TEXT` in
`~/.config/codexbar-bars/config.env`. All values are 6-char hex (no `#`).

## Cache

PNGs go to `${CB_BARS_SKETCHYBAR_IMAGE_CACHE}` (default
`~/.cache/codexbar-bars/sketchybar`). They are byte-compared on each
refresh; only changed images are written.

## Caveats

- The plugin does not dim or annotate when the cache is stale. Zellij and
  tmux do; SketchyBar relies on CodexBar's own menu for incident hints.
