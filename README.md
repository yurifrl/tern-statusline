# tern-statusline

The omp statusline, remade for Tern: usage bars, provider, spend, AWS and kube widgets.

One Tern plugin (`window.luau` for the widgets, `host.luau` for the detail card block) plus one omp
companion extension (`omp/`) that bridges the data only the omp process can see.

## Install

1. Tern plugin: `tern plugin link <this directory>` (a git checkout; `tern plugin install
   <git-url>` works too).
2. omp companion: `omp plugin link <this directory>/omp` — the `tern-statusline-cache` omp
   plugin, sourced from the same checkout. No raw symlinks into `~/.omp/agent/extensions/`.

Both reload their daemons on link; restart omp sessions to pick the extension up.

## What the statusline shows

Every segment is its own Tern widget, `tern-statusline/<id>`, named `SL <Label>` (e.g. `SL Usage`) in the
widget picker. A widget hides itself when it doesn't apply to the focused pane, or has no data.

| Widget | Shows | Applies on | Styles | Data source |
| --- | --- | --- | --- | --- |
| `provider` | The provider behind the agent's model — `aihub/…` reads `aihub`, Z.AI display names read `zai`, claude reads `claude` | any agent pane, claude CLI terminals | text | agent list, the cache file |
| `usage` | Per-provider usage meter: `ZAI 5H ━━●─── 50% left` | omp agent panes | text, bar, ring | the cache file (`omp usage --json`) |
| `context` | Composer context meter: `󰆧 23%` | omp agent panes | text, bar, ring | the cache file |
| `budget` | Gateway daily spend: `󰆼 $12/$200` | provider is `aihub` | text, bar, ring | the AIHub gateway `/v1/me/usage` |
| `cost` | Session cost and per-message average | omp agent panes | text | the cache file |
| `aws` | AWS profile captured from a login fish (`AWS_PROFILE`) | every pane | text | `fish -N -c` poller |
| `kube` | Current kubectl context: `⎈ talos-default` | every pane | text | the cache file, `kubectl config current-context` fallback |

"omp agent panes" excludes ACP agents (`tern acp … claude:<id>`, `tern acp claude`, the `c` alias)
and the claude CLI running in a terminal. Bar and ring fill with the usage share left, the context
used, and the budget spent against its limit.

Hover shows a tooltip. Click a widget to toggle the detail card (below).

## The detail card

Clicking any widget, the palette command `omp Statusline: Show / Hide Card` or `ctrl+alt+s`
(rebindable in Tern's keybindings; the action is still `plugin.tern-statusline.detail`) floats a
card in the top-right corner over the focused pane. The same action closes it again.

- **Provider tabs** — one chip per provider in the omp cache (e.g. `ZAI`, `Anthropic`); the active
  model's provider wears a `●` and starts selected. Clicking a chip (or `tab` in the card) shows
  that provider's windows.
- **Usage meters** — one row per window: label, a drawn bar of the consumed share, the share left,
  the reset countdown and saved resets: `7D ━━━━─── 82% left 4d 4h`. Tones follow
  `segments.usage.warnAt`/`badAt` (percent left).
- **Context** (bar), **AI Hub budget** spent/limit (bar, aihub only), **session cost** with the
  per-message average and message count, **kube** and **aws**.
- **Toolbar** — `↻` (or `r`) re-runs every poller now; `✎ config` (or `e`) opens
  `~/.config/tern-statusline/config.json`.
- **Footer** — when the data was last refreshed.

The card follows the focused pane with the widgets' applicability rules: ACP agents and claude CLI
terminals show the provider, kube and aws, never the omp-only rows; plain terminals show kube and
aws. Focusing the card itself keeps it on the pane it describes, and it redraws while open
whenever the data changes.

## Placing widgets

Open the palette › `Edit widgets…` and add the `tern-statusline/<id>` widgets you want, where you
want them.

Upgrading from the single status formatter: the bar stays empty until widgets are placed. To keep
the old "Plugin segments" formatter instead, set `"statusSegments": true` in the config.

## Configuration

The config file is the only way to change behavior — there is no settings UI:

```sh
$EDITOR ~/.config/tern-statusline/config.json   # Tern applies it within ~3 s
```

The file lives at `~/.config/tern-statusline/config.json` (respects `XDG_CONFIG_HOME`, override
with `TERN_STATUSLINE_CONFIG`). The cache poller reads it, normalizes it into the `tern.kv` mirror
every window shares, and redraws the bar — all windows converge on the file within one poll.
Unknown keys and bad values fall back to defaults; a corrupt file never fails to load.

```json
{
  "enabled": true,
  "segments": {
    "usage": { "barGlyphs": 8, "warnAt": 25, "badAt": 10 },
    "context": { "warnAt": 50, "badAt": 75, "inapplicable": "compact" },
    "budget": { "warnAt": 50, "badAt": 75 },
    "cost": { "showZero": false, "enabled": false },
    "aws": { "refreshMs": 30000, "timeoutMs": 5000, "compact": true },
    "kube": { "strip": ["^arn:aws:eks:[^:]+:[0-9]+:cluster/"], "refreshMs": 10000, "compactIcon": "☸" }
  },
  "detail": { "enabled": true },
  "statusSegments": false,
  "prefix": "",
  "order": ["provider", "usage", "context", "budget", "cost", "aws", "kube"]
}
```

Every `segments.<id>` accepts:

| Key | Default | Effect |
| --- | --- | --- |
| `enabled` | `true` | `false` hides the widget entirely |
| `inapplicable` | `"hide"` | `"compact"` keeps a muted compact icon where the widget doesn't apply |
| `compact` | `false` | Always render the short form: the icon alone for `provider`, `aws`, `kube` (the value moves to the tooltip); the icon plus a short value for `usage` (`󰊚 77%`, lowest share left), `context` (`󰆧 23%`), `budget` (`󰆼 $20`, spend only), `cost` (`󰔛 $1.20`, no average) |
| `compactIcon` | per widget | The compact glyph: kube `⎈`, context `󰆧`, budget `󰆼`, cost `󰔛`, aws `` (Nerd Font `nf-fa-aws`), usage `󰊚`, provider `󰚩` |

`kube` and `aws` also take `refreshMs` (poll cadence, ≥ 250; defaults 10000 and 30000) and
`timeoutMs` (process timeout, ≥ 250; default 5000).

Tones cross strictly above `warnAt`/`badAt`. `barGlyphs` is the text meter's total width: bars,
tip dot and track together.

`statusSegments: true` re-enables the old single "Plugin segments" status formatter alongside the
widgets; `prefix` (a literal string shown first; `""` or `"none"` for nothing) and `order` apply
only to it. It also turns on by itself when this Tern can't
register widgets (`tern.chrome.widget` missing or rejecting a spec), so the bar is never empty.

## How it works

- **4 ms budget** — widget renders (and the opt-in status formatter) do zero work: they return
  prebuilt segments that are rebuilt only when a poller changed something visible.
- **Pollers** — agent state every 2 s, the omp cache every 3 s, the AIHub gateway every 60 s
  (needs `AIHUB_API_KEY`), kubectl every 10 s and the AWS profile every 30 s (both configurable).
  A failing poller never takes the others down. A focus change moves the shown pane before the
  agent poll and reads the new project's cache at once, so the first frame is the new pane's.
- **The cache file** (`~/.omp/cache/statusline/<escaped-cwd>.json`, one per project) is written by the omp companion extension on
  `session_start` and after every turn: provider usage windows, context percent, session cost and
  message count. It refreshes `omp usage --json` at most once a minute.
- **Gateway budget** — `daily_budget` from the gateway renders with the shared threshold tones.
- **The card** — Tern lets only a plugin's host half define blocks, but every value lives in the
  window half. So the window builds the card model for the focused pane (rows that don't apply are
  left out) and mirrors it into `tern.kv` key `card` while a card is open, only when it changed
  (the footer clock moves in 5 s steps); the host block watches that key every second and redraws.
  The refresh button bumps kv `card_refresh`, which the window answers by running every poller.

## Development

```sh
bun install
node scripts/check.mjs
```

`node scripts/check.mjs` validates the plugin manifest (including the `card` block), compiles both Luau sources (host and window), runs the behavioral
scenarios inside a fake `tern` harness (`tests/behavior.luau`), and verifies the docs links.
