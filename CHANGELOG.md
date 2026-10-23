# Changelog

## 0.1.0 — 2026-10-23

First release: the omp statusline, remade for Tern.

- Nine segments: indicator, provider, usage meters per provider, context, gateway budget, session
  cost, agent memory, AWS profile, kube context.
- Prebuilt status table — the formatter returns cached segments under Tern's 4 ms hook budget;
  every poller rebuilds it through one `publish` path.
- Settings two ways — palette panel and detail dock, shared across windows through `tern.kv`,
  persisted to `~/.config/tern-statusline/config.json`; unknown values fall back to defaults.
- Detail canvas listing every segment's full values.
- Companion omp extension writing `~/.omp/cache/statusline.json` (usage windows, context,
  session cost) polled by the plugin.
- 11 behavioral scenarios in a fake `tern` harness; docs verified by `npm run check`.
