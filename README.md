# tern-statusline

The omp statusline, remade for Tern: usage bars, provider, spend, memory, AWS and kube segments.

One Tern window plugin (`window.luau`) plus one omp companion extension (`omp/`) that bridges the
data only the omp process can see.

## Install

1. Tern plugin: `tern plugin link <this directory>` (a git checkout; `tern plugin install
   <git-url>` works too).
2. omp companion: `omp plugin link <this directory>/omp` — the `tern-statusline-cache` omp
   plugin, sourced from the same checkout. No raw symlinks into `~/.omp/agent/extensions/`.

Both reload their daemons on link; restart omp sessions to pick the extension up.

## What the statusline shows

Segments, in default order:

| Segment | Shows | Data source |
| --- | --- | --- |
| `indicator` | Agent state glyph: ready, working, waiting, refreshing, attention | `cx.agents:list()` |
| `provider` | The provider behind the agent's model — `aihub/…` reads `aihub` | agent list |
| `usage` | Per-provider usage meter: `ZAI 5H ━━●─── 50% left` | the cache file (`omp usage --json`) |
| `context` | Composer context meter, scraped: `󰆧 23%` | the cache file |
| `budget` | Gateway daily spend: `󰆼 $12/$200` | the AIHub gateway `/v1/me/usage` |
| `cost` | Session cost and per-message average | the cache file |
| `memory` | Largest omp agent process RSS: `󰍛 283M` | `ps -axo rss=,command=` |
| `aws` | AWS profile from `AWS_PROFILE` / `AWS_DEFAULT_PROFILE` | environment |
| `kube` | Current kubectl context: `⎈ talos-default` | `kubectl config current-context` |

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
  "prefix": "",
  "order": ["indicator", "provider", "usage", "context", "budget", "cost", "memory", "aws", "kube"],
  "segments": {
    "indicator": { "icons": { "ready": "󰄾", "working": "󰙨" } },
    "usage": { "barGlyphs": 8, "warnAt": 25, "badAt": 10 },
    "context": { "warnAt": 50, "badAt": 75 },
    "budget": { "warnAt": 50, "badAt": 75 },
    "cost": { "showZero": false },
    "memory": { "refreshMs": 10000 },
    "aws": { "envVars": ["AWS_PROFILE", "AWS_DEFAULT_PROFILE"] },
    "kube": { "strip": ["^arn:aws:eks:[^:]+:[0-9]+:cluster/"] }
  },
  "detail": { "enabled": true }
}
```

Tones cross strictly above `warnAt`/`badAt`. `barGlyphs` is the meter's total width: bars, tip
dot and track together. Clicking any segment opens the detail panel (read-only); the palette
command `omp Statusline: Detail…` and the `ctrl+alt+s` chord open the same view.

## How it works

- **4 ms budget** — the status formatter does zero work: it returns a prebuilt segment table that
  is rebuilt only when a poller changed something visible.
- **Pollers** — agent state every 2 s, the omp cache every 3 s, the AIHub gateway every 60 s
  (needs `AIHUB_API_KEY`), kubectl and memory every 10 s. A failing poller never takes the others
  down.
- **The cache file** (`~/.omp/cache/statusline.json`) is written by the omp companion extension on
  `session_start` and after every turn: provider usage windows, context percent, session cost and
  message count. It refreshes `omp usage --json` at most once a minute.
- **Gateway budget** — `daily_budget` from the gateway renders with the shared threshold tones.

## Development

```sh
bun install
npm run check
```

`npm run check` validates the plugin manifest, compiles both Luau sources, runs 11 behavioral
scenarios inside a fake `tern` harness (`tests/behavior.luau`), and verifies the docs links.
