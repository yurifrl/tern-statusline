# Changelog

## Unreleased

- Every segment is its own Tern widget — `tern-statusline/<id>` for `provider`, `usage`,
  `context`, `budget`, `cost`, `aws`, `kube`, named `SL <Label>` (e.g. `SL Kube`) —
  placed through the palette's `Edit widgets…`. `usage`, `context` and `budget` render as text, bar
  or ring (bar: usage share left, context used, budget spent of limit); the rest are text. Click
  opens the detail panel; hover shows a tooltip.
- Widgets hide when they don't apply to the focused pane: `cost`, `usage` and `context` on omp
  agent panes only; `provider` on any agent pane or claude CLI terminal;
  `budget` only when the provider is aihub; `aws` and `kube` everywhere, plain terminals included.
  No data counts as not applicable.
- New per-segment keys under `segments.<id>`: `inapplicable` (`"hide"` default, `"compact"` shows
  the muted compact icon), `compact` (always the short form: icon alone for `provider`, `aws`,
  `kube`, value in the tooltip; icon plus short value for `usage`, `context`, `budget`, `cost`),
  `compactIcon`, and `enabled: false` to hide
  the widget entirely.
- Removed the `indicator` segment (state glyph) and its `icons` table. A leftover
  `segments.indicator` or `"indicator"` in `order` is ignored; `prefix` stays a literal string.
- ACP agent panes are recognized from their own pane info (`c` alias, `tern acp …`), so the
  provider reads `claude` and the omp-only widgets hide even when `agents:list()` yields no block
  for the pane.
- Removed the `memory` segment: its widget, the `ps -axo rss=,command=` poller and the plugin's use
  of the cache's `rssBytes` are gone. A leftover `segments.memory` or `"memory"` in `order` is
  ignored.
- `kube` and `aws` honor `refreshMs` and `timeoutMs` (they were accepted but never used).
- If this Tern can't register widgets, the legacy status formatter turns on by itself.
- Focus changes show the newly focused pane's data on the first frame (the shown pane used to move
  only after the agent poll, leaving the old pane's data up for up to 2 s, and a claude CLI pane's
  ACP state could stick to the next agent).
- The `ctrl+alt+s` detail chord works: it was bound to an undefined name and never registered.
- Migration: the bar is empty until widgets are placed. `statusSegments: true` brings back the
  single "Plugin segments" status formatter; `prefix` and `order` apply only to it.
- ACP agents are detected — `tern acp --resume 'claude:<id>'` (restored panes), `tern acp claude`,
  and the `c` alias — and the claude CLI in a plain terminal too: `cost` hides,
  `provider` shows the agent name (`claude`) instead of the cached aihub.
- Z.AI display names (`Z.AI GLM-4.7`) map to the `zai` provider ahead of the per-cwd cache, which
  another session in the same directory may have written.

- The cache is per project, not global: the companion extension writes
  `~/.omp/cache/statusline/<escaped-cwd>.json` (one file per session cwd, identical encoder both
  sides) and the plugin reads the focused agent's project's file. Every omp process used to write
  one shared `statusline.json`, so a fresh write was last-writer-wins — three home-systems sessions
  and five other projects' sessions flipped one file's `modelProvider`/`contextPct`/cost several
  times a second, which is the "zai bar under an aihub pane" flicker. Subagent sessions
  (`ctx.agent.kind == "sub"`) never write; only main sessions do.
- The extension touches only while its session works (1 s touch gated on `busy`, 30 s idle
  keepalive), so idle panes stop stamping stale `contextPct`/cost over active ones in the same
  project; two busy sessions in one directory still alternate at the plugin's 3 s read cadence.
- The `kube` segment now reports the session's real context: the companion extension runs
  `kubectl config current-context` through the session cwd's mise config, so per-dir
  `[env] KUBECONFIG` (e.g. home-systems' `.mise.toml`) applies and an explicit `KUBECONFIG`
  at launch wins; Tern's own process env is never trusted while the cache is fresh. The
  process poller stays as the fallback for stale caches and older extensions.
- Six new behavioral scenarios: foreign-cwd cache rejection, unscoped (pre-cwd) docs hidden,
  focus swaps between projects' files, cache RSS beating the ps scan, cache-carried kube
  overriding the poller, poller fallback when the cache predates `kube`; 24 total.
- The `aws` segment works in the GUI again: Tern's own environment lacks the login shell's exports,
  so the segment now reads `AWS_PROFILE` captured by a `fish -N -c` poller into the snapshot
  (universal vars serve it in ~30 ms) instead of `tern.getenv`, which only sees Tern's launch env.
- The `kube` segment survives Tern's PATH: it tries `kubectl` by name, falls back to the absolute
  mise shim, and when no current-context is set but exactly one context is configured, shows that
  context instead of hiding.
- Companion cache writes now carry context again: `contextPct` reads omp's real `ContextUsage`
  (`tokens`/`contextWindow`) instead of the nonexistent `limit` field — the context segment and the
  provider/usage fallbacks had been silently absent since the live-model rework.
- The 60 s cache refresher exists again: omp's `ExtensionContext` has no `setInterval`, so the old
  call threw inside `session_start` and every write after the first was skipped; a single
  module-level timer now follows the live session (unref'd so print/pipe runs never hang).

- Provider segment now sources from the live omp session's `ctx.model.provider` via the companion
  cache (the same source the omp/pi statusline reads), falling back from the agent block's model
  prefix — bare or missing agent model names no longer hide the label.
- Usage bars render only for the active provider's windows: on `zai/glm-…` you see zai's quota
  bars; on providers without a quota endpoint (aihub, litellm, omniroute) the segment drops out
  instead of showing stale bars for a provider you're not spending on.
- Detail panel's Provider row follows the same resolution.
- Two new behavioral scenarios: cache-provider fallback, zai-scoped usage gating; 15 total.

## 0.1.0 — 2026-10-23

First release: the omp statusline, remade for Tern.

- Nine segments: indicator, provider (from the model id's first path element), usage meters per
  provider, context, gateway budget, session cost, agent memory, AWS profile, kube context.
- Prebuilt status table — the formatter returns cached segments under Tern's 4 ms hook budget;
  every poller rebuilds it through one `publish` path.
- The config file is the only way to configure: `~/.config/tern-statusline/config.json` polled
  into the shared kv mirror; unknown values fall back to defaults. A palette command opens the
  read-only detail panel; segments click through to it.
- Detail canvas listing every segment's full values.
- Companion omp plugin (`omp/` package, `tern-statusline-cache`) writing
  `~/.omp/cache/statusline.json` (usage windows, context, session cost) polled by the plugin;
  installs with `omp plugin link omp/`.
- 13 behavioral scenarios in a fake `tern` harness; docs verified by `npm run check`.
