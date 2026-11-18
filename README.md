# tern-statusline

The omp statusline, remade for Tern: usage bars, provider, spend, AWS and kube widgets.

One Tern window plugin (`window.luau`) plus one omp companion extension (`omp/`) that bridges the
data only the omp process can see.

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
| `indicator` | Agent state glyph: ready, working, waiting, refreshing, attention | omp agent panes | text | `cx.agents:list()` |
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

Click a widget to open the detail panel; hover shows a tooltip.

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
    "indicator": { "icons": { "ready": "󰄾", "working": "󰙨" } },
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
  "order": ["indicator", "provider", "usage", "context", "budget", "cost", "aws", "kube"]
}
```

Every `segments.<id>` accepts:

| Key | Default | Effect |
| --- | --- | --- |
| `enabled` | `true` | `false` hides the widget entirely |
| `inapplicable` | `"hide"` | `"compact"` keeps a muted compact icon where the widget doesn't apply |
| `compact` | `false` | Always render the short form: the icon alone for `provider`, `aws`, `kube` (the value moves to the tooltip); the icon plus a short value for `usage` (`󰊚 77%`, lowest share left), `context` (`󰆧 23%`), `budget` (`󰆼 $20`, spend only), `cost` (`󰔛 $1.20`, no average); the state glyph for `indicator` |
| `compactIcon` | per widget | The compact glyph: kube `⎈`, context `󰆧`, budget `󰆼`, cost `󰔛`, aws `` (Nerd Font `nf-fa-aws`), usage `󰊚`, provider `󰚩`, indicator follows `icons.ready` |

`kube` and `aws` also take `refreshMs` (poll cadence, ≥ 250; defaults 10000 and 30000) and
`timeoutMs` (process timeout, ≥ 250; default 5000).

Tones cross strictly above `warnAt`/`badAt`. `barGlyphs` is the text meter's total width: bars,
tip dot and track together. The palette command `omp Statusline: Detail…` and the `ctrl+alt+s`
chord (rebindable in Tern's keybindings) open the same read-only detail panel a click does.

`statusSegments: true` re-enables the old single "Plugin segments" status formatter alongside the
widgets; `prefix` and `order` apply only to it. It also turns on by itself when this Tern can't
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

## Development

```sh
bun install
npm run check
```

`npm run check` validates the plugin manifest, compiles both Luau sources, runs the behavioral
scenarios inside a fake `tern` harness (`tests/behavior.luau`), and verifies the docs links.
