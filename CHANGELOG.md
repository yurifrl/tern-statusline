# Changelog

## Unreleased

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
