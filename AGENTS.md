# AGENTS.md

Guidance for agents working in this repository.

## Layout

- `window.luau` — the Tern window plugin. Packages in order: `config` · `format` · `data` ·
  `segments` · `chrome` · `card`. Read the package banner comments first.
- `host.luau` — the host half: block `card` (kind `tern-statusline.card`), the floating detail
  card. Blocks are host-only in Tern, so the window's `card` package builds the model (per pane
  class, applicability already applied), mirrors it into kv `card`, and owns the toggle; the host
  only draws it, watches kv, and files refresh requests under kv `card_refresh`.
- `omp/statusline-cache.js` — companion omp extension; writes
  `~/.omp/cache/statusline/<escaped-cwd>.json`.
- `tests/behavior.luau` — the only test surface. Scenarios drive the fake `tern` in
  `fake_tern()` and assert rendered output through `t.widget_for(id, pane)` (one widget per
  segment id) and, for the opt-in `statusSegments` formatter, `joined_for`. Card scenarios load
  both halves (`load_both`), toggle with `t.commands["detail"]`, and inspect `t.card_view()` by
  node key (`w:<window>`, `ctx`, `budget`, `cost`, `kube`, `aws`, `btn:tab=<id>`,
  `chip:provider`, `foot`) with `find_key`/`keys_with`; `t.card_event(act)` clicks the toolbar.
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
- **The card is drawn from kv**: anything it shows goes into `card.model` (window) first; the
  host never reads files or polls. Card rows obey the same `applies` rules as the widgets.
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
