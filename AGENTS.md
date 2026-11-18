# AGENTS.md

Guidance for agents working in this repository.

## Layout

- `window.luau` — the Tern window plugin. Packages in order: `config` · `format` · `data` ·
  `segments` · `chrome` · `detail` · `panel`. Read the package banner comments first.
- `omp/statusline-cache.js` — companion omp extension; writes
  `~/.omp/cache/statusline/<escaped-cwd>.json`.
- `tests/behavior.luau` — the only test surface. Scenarios drive the fake `tern` in
  `fake_tern()` and assert rendered output through `t.widget_for(id, pane)` (one widget per
  segment id) and, for the opt-in `statusSegments` formatter, `joined_for`.
- `scripts/check.mjs` — manifest contract, Luau compile + scenarios, docs link check.

## Rules

- **No npm, no pnpm**: bun for installs (`bun install`), `node scripts/check.mjs` to verify.
- **Tests first**: a fix lands only with the failing scenario fixed in `tests/behavior.luau`.
  Drive behavior through the production seams — `t.kv.store`, `t.reads`, `t.fetch_answers`,
  `t.process_answers`, `t.agents.blocks`, `t:focus(pane)` (fires Tern's focus event) — never by
  reaching into module internals.
- **Timing in scenarios**: `t:tick(n)` fires each pending timer `n` times; the process pollers
  (kube, aws) and the gateway fetch all run every tick, so seed one answer per poller per tick
  (`process_answers`/`fetch_answers` are consumed in call order).
- **4 ms budget is sacred**: widget renders and the opt-in `tern.chrome.status` formatter only
  return prebuilt segments. Anything new renders through a poller → `publish` → `rebuild`.
- **Applicability**: a widget hides (or goes compact via `inapplicable`) when
  its segment doesn't apply to the focused pane or has no data — omp-only widgets must stay
  hidden on ACP panes and claude CLI terminals. Cover each new rule with a `t.widget_for`
  scenario per pane kind.
- **Widget names**: `SL <Label>`; each `description` leads with a sample of the widget, then where
  it applies, in at most 60 characters (the registration scenario asserts both).
- **Validated config**: user input flows through `config.normalize`; unknown keys drop, bad
  values fall back to defaults. Never trust a raw config table downstream.
- **UTF-8**: meters use multibyte glyphs; count codepoints (`[^\128-\191]`), not bytes, in
  assertions.
- Keep the manifest (`plugin.toml`, `package.json`) and this documentation in sync with the
  widget table and config keys.
