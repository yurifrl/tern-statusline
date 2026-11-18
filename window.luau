--!strict
-- omp Statusline — the omp statusline, remade as Tern widgets.
--
-- Segments: provider, usage, context, budget, cost, aws, kube. Each is its own
-- widget (`tern.chrome.widget`, id = segment name) the user places in Tern's widget bar; a widget
-- hides (or shrinks to its compact glyph) when its segment doesn't apply to the focused pane.
-- The old single `tern.chrome.status` formatter survives behind `statusSegments = true`.
-- Data comes from three seams, each owned by one module:
--   agents    — `cx.agents:list()`, native: model, working/idle state, pane ids, cwd
--   cache     — the companion extension's per-project `~/.omp/cache/statusline/<cwd>.json`,
--               async via `cx.docs:read`; each omp session writes only its own project's file,
--               so cross-project and cross-pane writers can never cross-apply their data
--   process   — `tern.process.run` polls: kube context (fallback), aws profile
--
-- BUDGET SAFETY: widget `render` and `tern.chrome.status` must stay under Tern's 4 ms hook budget
-- (over budget disables every plugin timer until reload). They do ZERO work: views are prebuilt
-- into upvalues by poll callbacks (`rebuild`, which then calls `tern.chrome.refresh`), and the
-- formatters only record the pane and return the prebuilt value.
--
-- Layout (packages, not sections): config · format · data · segments · chrome · card.
-- Each package owns its state; cross-package calls go through the public functions listed in
-- each header. See AGENTS.md for the rules this layout follows.
--
-- The detail card is a host block (`host.luau`, kind `tern-statusline.card`): Tern only lets the
-- host half define blocks, so this half mirrors the focused pane's card model into `tern.kv`
-- ("card") and the host block draws it; the host asks for a refresh through kv ("card_refresh").

-- ── package: config ────────────────────────────────────────────────────────────
-- Reads the config file (`~/.config/tern-statusline/config.json`, overridable via
-- `TERN_STATUSLINE_CONFIG`), keeps it in `tern.kv` as the live mirror, and validates user JSON
-- at the boundary: unknown values fall back to defaults, nothing throws.

local CONFIG_DIR = "/.config/tern-statusline"
local CONFIG_FILE = "/config.json"

export type Tone = "muted" | "accent" | "ok" | "warn" | "error"

-- Segment names, in default render order.
export type SegmentName = "provider" | "usage" | "context" | "budget" | "cost" | "aws" | "kube"

local SEGMENT_NAMES: { SegmentName } = {
	"provider", "usage", "context", "budget", "cost", "aws", "kube",
}

-- What a widget shows when its segment doesn't apply to the focused pane (or has no data):
-- "hide" renders nothing, "compact" renders the muted `compactIcon` alone.
export type Inapplicable = "hide" | "compact"

export type SegmentConfig = {
	enabled: boolean,
	color: Tone?,
	-- widget knobs, shared by every segment
	inapplicable: Inapplicable,
	compact: boolean, -- always render the short glyph-plus-value form (per-segment, see segments)
	compactIcon: string,
	-- component-specific knobs; validated per segment below
	refreshMs: number?,
	timeoutMs: number?,
	strip: { string }?,
	showZero: boolean?,
	barGlyphs: number?,
	warnAt: number?,
	badAt: number?,
}

-- One segment's outcome: text (nil hides the segment) and its tone, plus what the widget view
-- needs: `short` (the compact form's text), `title` (tooltip) and `value` (bar/ring fill, 0–1).
export type Rendered = {
	text: string,
	tone: Tone?,
	short: string?,
	title: string?,
	value: number?,
}

export type Config = {
	enabled: boolean,
	-- legacy single-formatter path (`tern.chrome.status`); widgets are the default surface
	statusSegments: boolean,
	-- "" or "none" for none · any other string renders literally in front (legacy path only)
	prefix: string,
	order: { SegmentName }, -- legacy path only; widgets are placed in Tern's widget bar
	segments: { [SegmentName]: SegmentConfig },
	detail: { enabled: boolean },
}

-- Each segment's default compact glyph: the widget's compact form and its "inapplicable = compact"
-- placeholder. Users override per segment with `compactIcon`.
local COMPACT_ICONS: { [SegmentName]: string } = {
	provider = "󰚩",
	usage = "󰊚",
	context = "󰆧",
	budget = "󰆼",
	cost = "󰔛",
	aws = "\u{F270}", -- nf-fa-aws
	kube = "⎈",
}

local function seg_defaults(name: SegmentName, extra: { [string]: any }): SegmentConfig
	local seg: any = { enabled = true, inapplicable = "hide", compact = false, compactIcon = COMPACT_ICONS[name] }
	for key, value in extra do
		seg[key] = value
	end
	return seg :: SegmentConfig
end

local DEFAULTS: Config = {
	enabled = true,
	statusSegments = false,
	prefix = "",
	order = {
		"provider", "usage", "context", "budget", "cost", "aws", "kube",
	},
	segments = {
		provider = seg_defaults("provider", {}),
		usage = seg_defaults("usage", { barGlyphs = 8, warnAt = 25, badAt = 10 }),
		context = seg_defaults("context", { warnAt = 50, badAt = 75 }),
		budget = seg_defaults("budget", { warnAt = 50, badAt = 75 }),
		cost = seg_defaults("cost", { showZero = false }),
		aws = seg_defaults("aws", { refreshMs = 30000, timeoutMs = 5000 }),
		kube = seg_defaults("kube", { refreshMs = 10000, timeoutMs = 5000, strip = {} }),
	},
	detail = { enabled = true },
}

local config = {}

local TONES: { [string]: boolean } = { muted = true, accent = true, ok = true, warn = true, error = true }
local NAME_SET: { [string]: boolean } = {}
for _, name in SEGMENT_NAMES do
	NAME_SET[name] = true
end

-- What the file says is what every window shows. `tern.kv` is the live mirror every window reads;
-- `from_file` (the only writer of the mirror) validates with the same rules, so a hand edit and a
-- restart land on identical state.
local store = {
	file = nil :: string?,
	dirty = false,
}

local function merge_segment(name: SegmentName, input: any): SegmentConfig
	local base = table.clone(DEFAULTS.segments[name])
	if type(input) ~= "table" then
		return base
	end
	if input.enabled ~= nil then
		base.enabled = input.enabled == true
	end
	if TONES[input.color] then
		base.color = input.color :: Tone
	end
	if input.inapplicable == "hide" or input.inapplicable == "compact" then
		base.inapplicable = input.inapplicable :: Inapplicable
	end
	if type(input.compact) == "boolean" then
		base.compact = input.compact
	end
	if type(input.compactIcon) == "string" and input.compactIcon ~= "" then
		base.compactIcon = input.compactIcon
	end
	if name == "cost" and input.showZero ~= nil then
		base.showZero = input.showZero == true
	end
	for _, key in { "barGlyphs" } do
		if name == "usage" and type(input[key]) == "number" then
			local seg = base :: any
			seg[key] = math.floor(input[key])
		end
	end
	for _, key in { "warnAt", "badAt" } do
		if (name == "usage" or name == "context" or name == "budget") and type(input[key]) == "number" then
			local seg = base :: any
			seg[key] = tonumber(input[key])
		end
	end
	for _, key in { "refreshMs", "timeoutMs" } do
		if (name == "kube" or name == "aws") and type(input[key]) == "number" and (input[key] :: number) >= 250 then
			local seg = base :: any
			seg[key] = math.floor(input[key])
		end
	end
	if name == "kube" and type(input.strip) == "table" then
		local patterns: { string } = {}
		for _, p in input.strip do
			if type(p) == "string" then
				table.insert(patterns, p)
			end
		end
		base.strip = patterns
	end
	return base
end

-- Validates one raw config table against the defaults; unknown keys are dropped, bad values
-- fall back. A corrupt file degrades to defaults — a statusline must never fail to load.
local function normalize(input: any): Config
	local cfg = table.clone(DEFAULTS)
	cfg.segments = table.clone(DEFAULTS.segments)
	for name, seg in DEFAULTS.segments do
		cfg.segments[name] = table.clone(seg)
	end
	cfg.detail = table.clone(DEFAULTS.detail)
	if type(input) ~= "table" then
		return cfg
	end
	cfg.enabled = if input.enabled ~= nil then input.enabled == true else true
	if type(input.statusSegments) == "boolean" then
		cfg.statusSegments = input.statusSegments
	end
	if type(input.prefix) == "string" then
		cfg.prefix = input.prefix
	end
	if type(input.order) == "table" then
		local seen: { [string]: boolean } = {}
		local order: { SegmentName } = {}
		for _, name in input.order do
			if type(name) == "string" and NAME_SET[name] and not seen[name] then
				seen[name] = true
				table.insert(order, name :: SegmentName)
			end
		end
		if #order > 0 then
			cfg.order = order
		end
	end
	if type(input.segments) == "table" then
		for name in input.segments do
			if type(name) == "string" and NAME_SET[name] then
				cfg.segments[name :: SegmentName] = merge_segment(name :: SegmentName, input.segments[name])
			end
		end
	end
	if type(input.detail) == "table" and input.detail.enabled ~= nil then
		cfg.detail.enabled = input.detail.enabled == true
	end
	return cfg
end

-- The config path: `$TERN_STATUSLINE_CONFIG`, else `$XDG_CONFIG_HOME`, else `~/.config`.
local function config_path(): string?
	if store.file then
		return store.file
	end
	local override = tern.getenv("TERN_STATUSLINE_CONFIG")
	if override and override ~= "" then
		store.file = override
		return override
	end
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	if not home or home == "" then
		return nil
	end
	local xdg = tern.getenv("XDG_CONFIG_HOME")
	local dir = if xdg and xdg ~= "" then xdg .. CONFIG_DIR else home .. CONFIG_DIR
	store.file = dir .. CONFIG_FILE
	return store.file
end

-- Reads `tern.kv` (the mirror every window shares); file contents arrive via the cache poller,
-- which calls `config.from_file` with what it read.
local function load(): Config
	local ok, value = pcall(function(): any
		return tern.kv.get("config")
	end)
	if ok and type(value) == "table" then
		return normalize(value)
	end
	return normalize(nil)
end

local function from_file(text: string): Config
	local ok, value = pcall(function(): any
		return tern.json.decode(text)
	end)
	local cfg = if ok then normalize(value) else normalize(nil)
	-- the file is the one writer; the kv mirror only mirrors it, so every window sees the same
	tern.kv.set("config", cfg)
	return cfg
end

	config.DEFAULTS = DEFAULTS
	config.SEGMENT_NAMES = SEGMENT_NAMES
	config.load = load
	config.from_file = from_file
	config.path = config_path

-- ── package: format ────────────────────────────────────────────────────────────
-- Pure formatting helpers shared by every segment: counts, money, time. No state, no I/O.

local format = {}

-- Visible width of one string (glyphs), approximating Nerd Font double-width icons.
local function glyph_count(text: string): number
	local count = 0
	for _ in text:gmatch("[%z\1-\127\194-\223][\128-\191]*") do
		count += 1
	end
	return count
end
format.glyph_count = glyph_count

-- `$20`, `$1.5` from dollars.
function format.usd(value: number): string
	if value >= 100 then
		return string.format("$%.0f", value)
	end
	return (string.format("$%.2f", value):gsub("%.?0+$", ""))
end

-- `$1.20` from text; nil when it doesn't parse.
function format.parse_usd(text: string): number?
	return tonumber(text:match("%$([%d%.]+)"))
end

-- `1h 40m`, `45m` from milliseconds; coarse for countdowns.
function format.left(ms: number): string
	if ms <= 0 then
		return "now"
	end
	local minutes = math.floor(ms / 60000)
	local hours = math.floor(minutes / 60)
	if hours < 1 then
		return string.format("%dm", minutes)
	end
	if hours < 24 then
		local rem = minutes % 60
		return if rem > 0 then string.format("%dh %dm", hours, rem) else string.format("%dh", hours)
	end
	local days = math.floor(hours / 24)
	local h = hours % 24
	return if h > 0 then string.format("%dd %dh", days, h) else string.format("%dd", days)
end

-- The slim meter: `━━●───` — fill toward the tip dot, then track. Same glyphs the target look uses.
function format.meter(pct: number, glyphs: number): string
	local filled = math.floor((pct / 100) * (glyphs - 1) + 0.5)
	if filled > glyphs - 1 then
		filled = glyphs - 1
	end
	if filled < 0 then
		filled = 0
	end
	return string.rep("━", filled) .. "●" .. string.rep("─", glyphs - 1 - filled)
end

-- Threshold tone: `base` unless the value crosses warnAt, then badAt.
-- For "share left" values, where low is bad: tints at or below the thresholds.
function format.threshold_low(value: number?, base: Tone, warnAt: number?, badAt: number?): Tone
	if value == nil then
		return base
	end
	if badAt and value <= badAt then
		return "error"
	end
	if warnAt and value <= warnAt then
		return "warn"
	end
	return base
end

function format.threshold(value: number?, base: Tone, warnAt: number?, badAt: number?): Tone
	if value == nil then
		return base
	end
	if badAt and value > badAt then
		return "error"
	end
	if warnAt and value > warnAt then
		return "warn"
	end
	return base
end

-- ── package: data ──────────────────────────────────────────────────────────────
-- One snapshot type all segments read; three collectors fill it. Every collector owns its refresh
-- cadence and never blocks: async reads land in callbacks, process polls in `tern.process.run`
-- callbacks, and the agent list is synchronous but cheap (tern caches it).

local data = {}

export type ProviderWindow = {
	label: string, -- "5H", "7D"
	pct: number, -- share left, 0..100
	reset: string?, -- countdown text from the extension, e.g. "1h 40m"
	saved: number?, -- saved resets, shown as (+N)
}

export type Provider = {
	id: string,
	label: string, -- "Claude", "Codex"
	windows: { ProviderWindow },
}

export type Snapshot = {
	-- agents (native)
	pane: number?,
	model: string?,
	state: "ready" | "working" | "waiting" | "exited",
	agent_cwd: string?, -- the focused agent block's cwd; identifies whose session is on screen
	acp: string?, -- ACP agent name ("claude") when the focused block runs over ACP, nil for omp
	-- gateway (AI Hub, shared fetch)
	budget: { spent: number, limit: number? }?,
	-- cache (companion extension)
	providers: { Provider },
	model_provider: string?, -- the live omp session's active provider, from ctx.model
	cache_cwd: string?, -- the cache writer's cwd; shared file, so identity = cwd match
	cache_kube: string?, -- kubectl context resolved inside that session (env-true, incl. KUBECONFIG)
	cache_at: number?, -- when the cache was written (ms); freshness gates provider/usage precedence
	context_pct: number?, -- composer context used, 0..100, scraped from the composer's meter
	session_cost: string?, -- the composer bar's cost text, e.g. "$1.20"
	session_turns: number?, -- message count, for the average
	-- process polls
	kube: string?,
	aws_profile: string?, -- AWS_PROFILE captured from a login fish (Tern's own env lacks it)
	at: number, -- snapshot build time, ms
}

local EMPTY: Snapshot = {
	state = "exited",
	providers = {},
	at = 0,
}

local latest: Snapshot = EMPTY

function data.snapshot(): Snapshot
	return latest
end

function data.publish(next: Snapshot)
	latest = next
end

-- ── package: segments ──────────────────────────────────────────────────────────
-- One table per segment, in registry order. Each entry: `name`, `render(snapshot, seg) ->
-- Rendered`. Render is pure; missing data returns nil and the segment drops out. The chrome
-- package calls these per widget (and, for the legacy status formatter, in `config.order`) and
-- owns nothing about any one segment.

-- A cache written within this window is "live" — the extension rewrites it every second. Fresh
-- alone is not identity: the focused project's file is read, and the data applies only when the
-- writer's `cwd` matches the focused agent's cwd (the guard in read_cache already scopes reads,
-- so this is the belt to its braces; an escaping divergence must hide data, not mislabel it).
-- Without the match, the agent block's spawn-time model string decides.
local CACHE_FRESH_MS = 15_000

-- Does the fresh cache describe the session on screen? The cache file is shared by every omp
-- process (restored panes, background restores, this session), so a fresh `modelProvider` is
-- only trustworthy when the writer's `cwd` matches the focused agent's cwd. Writers without
-- a cwd field predate the extension change: no match → agent-model fallback, same as stale.
local function cache_matches(snap: Snapshot): boolean
	local fresh = snap.cache_at ~= nil and os.time() * 1000 - (snap.cache_at :: number) < CACHE_FRESH_MS
	if not fresh then
		return false
	end
	local cache_cwd = snap.cache_cwd
	local agent_cwd = snap.agent_cwd
	return cache_cwd ~= nil and cache_cwd ~= "" and agent_cwd ~= nil and agent_cwd ~= "" and cache_cwd == agent_cwd
end

-- Display names (`Z.AI GLM-4.7`) carry no `provider/` prefix; map the families we know. This
-- beats the shared per-cwd cache, which another session in the same directory may have written.
local function provider_of_display(model: string?): string?
	if not model then
		return nil
	end
	if model:match("^Z%.?AI") then
		return "zai"
	end
	return nil
end

local segments = {}

type Render = (Snapshot, SegmentConfig) -> Rendered?

local by_name: { [SegmentName]: Render } = {}

local function register(name: SegmentName, render: Render)
	by_name[name] = render
end

-- Compact forms (`compact = true`), per segment — the shortest text that still says something:
--   provider   `compactIcon` alone; the name moves to the tooltip
--   usage      `compactIcon` + the lowest share left across the shown windows: `󰊚 77%`
--   context    `compactIcon` + percent used: `󰆧 23%` (the full form is already this short)
--   budget     `compactIcon` + spend, no limit: `󰆼 $20`
--   cost       `compactIcon` + session spend, no per-message average: `󰔛 $1.20`
--   aws        `compactIcon` alone; the profile moves to the tooltip
--   kube       `compactIcon` alone (`⎈`); the context moves to the tooltip

-- provider — the AI provider behind the active model. The companion cache's `modelProvider`
-- (omp's live `ctx.model`) is the only source that follows /model switches, so it wins while
-- the cache is fresh AND the writer sits in the focused agent's cwd (see cache_matches); the
-- agent block's model string is fixed at spawn and otherwise fills in. ACP panes show the ACP
-- agent's name. The budget widget gates on this same answer (only aihub has a gateway budget).
local function provider_name(snap: Snapshot): string?
	if snap.acp then
		return snap.acp
	end
	local name: string? = provider_of_display(snap.model)
	if not name and cache_matches(snap) then
		name = snap.model_provider
	end
	if not name or name == "" then
		name = if snap.model then (snap.model :: string):match("^([^/]+)/") else nil
	end
	if not name or name == "" then
		name = snap.model_provider
	end
	if not name or name == "" then
		return nil
	end
	return name
end
segments.provider_name = provider_name

register("provider", function(snap, seg)
	local name = provider_name(snap)
	if not name then
		return nil
	end
	return { text = name, tone = seg.color or "accent", short = seg.compactIcon, title = "Provider: " .. name }
end)

-- usage — the active provider's windows as `5H ━●── 77% 1h` groups, joined by `·`. Bars render
-- only for the provider the active model is on (`zai/glm-…` → zai's windows; a provider without
-- a quota endpoint, like aihub, hides the segment entirely). The fresh cache's `modelProvider`
-- leads when the writer is in the focused agent's cwd, same gate as the provider segment —
-- otherwise a zai writer elsewhere kept zai's windows alive under an aihub pane.
-- The provider whose quota windows apply: the fresh matching cache's live provider, else the
-- agent's `provider/` model prefix, else the cache's provider. Shared with the card's tabs.
local function active_usage(snap: Snapshot): string?
	local active: string? = nil
	if cache_matches(snap) then
		active = snap.model_provider
	end
	if not active or active == "" then
		active = if snap.model then (snap.model :: string):match("^([^/]+)/") else nil
	end
	if not active or active == "" then
		active = snap.model_provider
	end
	if not active or active == "" then
		return nil
	end
	return active
end
segments.active_usage = active_usage

register("usage", function(snap, seg)
	local active = active_usage(snap)
	if not active then
		return nil
	end
	local shown: { Provider } = {}
	for _, provider in snap.providers do
		if provider.id == active then
			table.insert(shown, provider)
		end
	end
	if #shown == 0 then
		return nil
	end
	local glyphs = seg.barGlyphs or 8
	local parts: { string } = {}
	local tone: Tone = seg.color or "muted"
	local worst = 100
	for pi, provider in shown do
		for wi, window in provider.windows do
			local share = window.pct
			if share < worst then
				worst = share
			end
			local piece = string.format("%s %s %d%% left", window.label, format.meter(share, glyphs), share)
			if window.reset and window.reset ~= "" then
				piece ..= " " .. window.reset
			end
			if window.saved and window.saved > 0 then
				piece ..= string.format(" +%d", window.saved)
			end
			-- the provider's label rides its first window, so the group reads `ZAI 5H ━●─ 90% left`
			table.insert(parts, (if wi == 1 then provider.label .. " " else "") .. piece)
		end
	end
	local text = table.concat(parts, " · ")
	return {
		text = text,
		tone = format.threshold_low(worst, tone, seg.warnAt, seg.badAt),
		short = string.format("%s %d%%", seg.compactIcon, worst),
		title = "Usage: " .. text,
		value = worst / 100,
	}
end)

-- context — the composer context meter, scraped: `󰆧 23%`.
register("context", function(snap, seg)

	local pct = snap.context_pct
	if not pct then
		return nil
	end
	local shown = math.floor(pct + 0.5)
	return {
		text = string.format("󰆧 %d%%", shown),
		tone = format.threshold(pct, seg.color or "muted", seg.warnAt, seg.badAt),
		short = string.format("%s %d%%", seg.compactIcon, shown),
		title = string.format("Context: %d%% used", shown),
		value = pct / 100,
	}
end)

-- budget — daily gateway spend: `󰆼 $20/$200`, thresholds on the share.
register("budget", function(snap, seg)

	local budget = snap.budget
	if not budget then
		return nil
	end
	local text = format.usd(budget.spent) .. (if budget.limit then "/" .. format.usd(budget.limit) else "")
	local pct = if budget.limit and budget.limit > 0 then (budget.spent / budget.limit) * 100 else nil
	return {
		text = "󰆼 " .. text,
		tone = format.threshold(pct, seg.color or "accent", seg.warnAt, seg.badAt),
		short = seg.compactIcon .. " " .. format.usd(budget.spent),
		title = "Budget: " .. format.usd(budget.spent) .. (if budget.limit then " of " .. format.usd(budget.limit) else "") .. " today",
		value = if pct then pct / 100 else nil,
	}
end)

-- cost — session spend with per-message average: `󰔛 $1.20 · ~$0.08/msg`.
register("cost", function(snap, seg)

	if snap.acp or not snap.session_cost or snap.session_cost == "" then
		return nil
	end
	local text = "󰔛 " .. snap.session_cost
	local title = "Cost: " .. snap.session_cost
	if snap.session_turns and snap.session_turns > 1 then
		local total = format.parse_usd(snap.session_cost)
		if total then
			text ..= string.format(" · ~$%.2f/msg", total / snap.session_turns)
		end
		title ..= string.format(" · %d msgs", snap.session_turns)
	end
	return { text = text, tone = seg.color or "muted", short = seg.compactIcon .. " " .. snap.session_cost, title = title }
end)

-- aws — the login shell's AWS_PROFILE, captured by the fish poller into the snapshot: `☁ nsx`.
register("aws", function(snap, seg)
	local value = snap.aws_profile
	if not value or value == "" then
		return nil
	end
	return { text = "☁ " .. value, tone = seg.color or "warn", short = seg.compactIcon, title = "AWS: " .. value }
end)

local function strip_all(text: string, patterns: { string }): string
	local display = text
	for _, pattern in patterns do
		display = display:gsub(pattern, "")
	end
	return display
end

-- kube — current kubectl context. The cache wins when fresh: the companion extension runs
-- kubectl as a child of omp, so `KUBECONFIG` and direnv in the session's env are respected —
-- Tern's own process env can't see them (same reason aws polls a login fish). The process
-- poller fills in when the cache is stale or its writer never carried kube.
local function kube_value(snap: Snapshot, seg: SegmentConfig): string?
	local value = snap.kube
	if cache_matches(snap) and snap.cache_kube and snap.cache_kube ~= "" then
		value = snap.cache_kube
	end
	if not value or value == "" then
		return nil
	end
	local display = strip_all(value, seg.strip or {})
	return if display == "" then nil else display
end
segments.kube_value = kube_value

register("kube", function(snap, seg)
	local display = kube_value(snap, seg)
	if not display then
		return nil
	end
	return { text = "⎈ " .. display, tone = seg.color or "ok", short = seg.compactIcon, title = "Kube: " .. display }
end)

function segments.render(name: SegmentName, snap: Snapshot, seg: SegmentConfig): Rendered?

	local render = by_name[name]
	if not render then
		return nil
	end
	local ok, out = pcall(render, snap, seg)
	if not ok or type(out) ~= "table" then
		return nil
	end
	return out :: Rendered
end

-- ── package: chrome ────────────────────────────────────────────────────────────
-- Wires data to the widget bar: one focus/refresh loop, per-source pollers, the prebuilt widget
-- views (per pane class) every widget render returns, and the legacy status table. Owns all timing.

type StatusSegment = { text: string, icon: string?, tone: string?, command: string? }

-- Gateway: one fetch shared by nothing but us; retains the last snapshot on failure.
local gateway = {}

local gateway_url = "https://ai-llm-gateway.fbr.land"
local GATEWAY_MS = 60000

local gateway_state: { spent: number?, limit: number? } = {}

function gateway.budget(): { spent: number, limit: number? }?
	if not gateway_state.spent then
		return nil
	end
	return { spent = gateway_state.spent :: number, limit = gateway_state.limit }
end

local chrome = {}

-- The prebuilt status table; rebuilt only when its signature changes.
local built: { StatusSegment } = {}
local built_sig: string = ""

local cfg: Config = config.load()

-- The last pane the status bar showed; agents and usage follow it.
local shown_pane: number? = nil
-- The shown pane is a plain terminal running the claude CLI (`c`, `claude`): no agent block
-- backs it, so poll_agents must not borrow another agent's data for it.
local shown_cli = false
-- The ACP agent name the focused agent pane's own info names (`c`, `tern acp …`), when it does:
-- agents:list may not yield a block for such a pane, so the pane info is the reliable source.
local shown_acp: string? = nil

local function is_claude_cli(pane: any): boolean
	if pane.kind ~= "terminal" then
		return false
	end
	local line: string = (pane.running and pane.running.line) or ""
	local program: string = pane.program or ""
	return program == "c" or program == "claude" or line:match("^c%f[%s%z]") ~= nil or line:match("^claude%f[%s%z]") ~= nil
end

local function state_of(block: any): "ready" | "working" | "waiting" | "exited"
	local s = block.state
	if s == "working" then
		return "working"
	elseif s == "waiting_input" then
		return "waiting"
	elseif s == "exited" then
		return "exited"
	end
	return "ready"
end

local AGENT_POLL_MS = 2000

-- ACP detection: `tern acp --resume 'claude:<id>'` (restored panes), `tern acp claude`, or the
-- `c` alias (cly claude) that hides the ACP launch line. omp panes run `omp …`.
local function acp_of(block: any): string?
	local line: string = (block.running and block.running.line) or block.program or ""
	if line:match("^omp%f[%s%z]") or block.program == "omp" then
		return nil
	end
	local name = line:match("acp%s+%-%-resume%s+'?(%a+):") or line:match("acp%s+(%a+)")
	if name then
		return name
	end
	if block.program == "c" or line:match("^c%f[%s%z]") then
		return "claude"
	end
	return nil
end

-- Agents and cache both feed the snapshot; each keeps its own fields and merges on publish.
local agent_fields: { model: string?, state: "ready" | "working" | "waiting" | "exited", pane: number?, cwd: string?, acp: string? } = {
	state = "exited",
}
local cache_fields: { providers: { Provider }, model_provider: string?, cache_at: number?, context_pct: number?, session_cost: string?, session_turns: number?, cwd: string?, kube: string? } = {
	providers = {},
}
local proc_fields: { kube: string?, aws_profile: string? } = {}

-- Forward-declared: publish rebuilds the prebuilt bar, so every data source lands visibly.
local rebuild: () -> ()
-- Forward-declared: rebuild mirrors the card model into kv while the card is open (package card).
local card_mirror: (force: boolean?) -> ()
-- read_cache is declared with poll_cache but poll_agents kicks it the moment focus changes cwd,
-- so a pane switch shows its own project's data without waiting out the 3 s cadence.
local read_cache: (WindowCx?) -> ()

local function publish()
	data.publish({
		pane = agent_fields.pane,
		model = agent_fields.model,
		state = agent_fields.state,
		agent_cwd = agent_fields.cwd,
		acp = agent_fields.acp,
		budget = gateway.budget(),
		providers = cache_fields.providers,
		model_provider = cache_fields.model_provider,
		cache_cwd = cache_fields.cwd,
		cache_kube = cache_fields.kube,
		cache_at = cache_fields.cache_at,
		context_pct = cache_fields.context_pct,
		session_cost = cache_fields.session_cost,
		session_turns = cache_fields.session_turns,
		kube = proc_fields.kube,
		aws_profile = proc_fields.aws_profile,
		at = os.time() * 1000,
	})
	rebuild()
end

local last_cx: WindowCx? = nil
local last_focused_cwd: string? = nil

local function poll_agents()
	local cx = last_cx
	if cx == nil then
		return
	end
	local ok, blocks = pcall(function()
		return cx.agents:list()
	end)
	if not ok or type(blocks) ~= "table" then
		return
	end
	if shown_cli then
		agent_fields.pane = shown_pane
		agent_fields.model = nil
		agent_fields.state = "ready"
		agent_fields.cwd = nil
		agent_fields.acp = "claude"
		publish()
		return
	end
	local chosen: any = nil
	local pane = shown_pane
	if pane then
		for _, block in blocks do
			if block.pane == pane then
				chosen = block
				break
			end
		end
	end
	if not chosen and #blocks > 0 then
		-- the focused agent, else the first
		chosen = blocks[1]
	end
	if chosen then
		agent_fields.pane = chosen.pane
		agent_fields.model = chosen.model
		agent_fields.state = state_of(chosen)
		agent_fields.cwd = chosen.cwd
		agent_fields.acp = acp_of(chosen)
	else
		agent_fields.pane = nil
		agent_fields.model = nil
		agent_fields.state = "exited"
		agent_fields.cwd = nil
		agent_fields.acp = nil
	end
	-- focus crossing projects swaps which cache file the next read targets; kick it now instead
	-- of waiting out the 3 s cadence, and let the guard in read_cache drop stale in-flight reads
	if (agent_fields.cwd or "") ~= (last_focused_cwd or "") then
		last_focused_cwd = agent_fields.cwd
		read_cache(cx)
	end
	publish()
end

local CACHE_POLL_MS = 3000
local config_text: string? = nil

-- The extension's caches: one file per project, `~/.omp/cache/statusline/<escaped-cwd>.json`;
-- this plugin reads the focused block's project's file. The name must match the extension's
-- `cacheKey` byte for byte: non [A-Za-z0-9._-] become uppercase %XX over the UTF-8 bytes, names
-- past 220 chars truncate with a length suffix (255-byte filename cap with the dir prefix).
local CACHE_DIR_TAIL = "/.omp/cache/statusline"
local CACHE_DIR: string? = (function(): string?
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	return if home and home ~= "" then home .. CACHE_DIR_TAIL else nil
end)()

function cache_key(cwd: string): string
	while #cwd > 1 and cwd:sub(-1) == "/" do
		cwd = cwd:sub(1, -2)
	end
	if cwd == "" then
		cwd = "/" -- mirrors the extension's `|| "/"`: the root's file is %2F.json, never .json
	end
	local esc = (cwd:gsub("[^%w%.%-%_]", function(c: string): string
		return string.format("%%%02X", string.byte(c) or 0)
	end)) :: string
	if #esc > 220 then
		esc = esc:sub(1, 200) .. "-" .. tostring(#esc)
	end
	return esc
end

function cache_file(cwd: string): string?
	local dir = CACHE_DIR
	if not dir then
		return nil
	end
	return dir .. "/" .. cache_key(cwd) .. ".json"
end

local function parse_provider(value: any): Provider?
	if type(value) ~= "table" or type(value.id) ~= "string" or type(value.label) ~= "string" then
		return nil
	end
	local windows: { ProviderWindow } = {}
	if type(value.windows) == "table" then
		for _, w in value.windows do
			if type(w) == "table" and type(w.label) == "string" and type(w.pct) == "number" then
				table.insert(windows, {
					label = w.label,
					pct = w.pct,
					reset = if type(w.reset) == "string" then w.reset else nil,
					saved = if type(w.saved) == "number" then w.saved else nil,
				})
			end
		end
	end
	return { id = value.id, label = value.label, windows = windows }
end

local function parse_cache(text: string): (typeof(cache_fields), string?)
	local ok, doc = pcall(function(): any
		return tern.json.decode(text)
	end)
	if not ok or type(doc) ~= "table" then
		return cache_fields, nil
	end
	local providers: { Provider } = {}
	if type(doc.providers) == "table" then
		for _, p in doc.providers do
			local provider = parse_provider(p)
			if provider then
				table.insert(providers, provider)
			end
		end
	end
	local context: number? = nil
	if type(doc.contextPct) == "number" then
		context = doc.contextPct
	end
	local cost: string? = nil
	if type(doc.sessionCost) == "string" then
		cost = doc.sessionCost
	end
	local turns: number? = nil
	if type(doc.sessionTurns) == "number" then
		turns = doc.sessionTurns
	end
	local provider: string? = nil
	if type(doc.modelProvider) == "string" and (doc.modelProvider :: string) ~= "" then
		provider = doc.modelProvider
	end
	local cache_at: number? = nil
	if type(doc.generatedAt) == "number" then
		cache_at = doc.generatedAt
	end
	local cwd: string? = nil
	if type(doc.cwd) == "string" and (doc.cwd :: string) ~= "" then
		cwd = doc.cwd
	end
	local kube: string? = nil
	if type(doc.kube) == "string" and (doc.kube :: string) ~= "" then
		kube = doc.kube
	end
	-- the file also refreshes config when its version bumps; a present file confirms the extension
	return { providers = providers, model_provider = provider, cache_at = cache_at, context_pct = context, session_cost = cost, session_turns = turns, cwd = cwd, kube = kube }, nil
end

-- Reads the focused project's cache. cache_fields only ever holds values for the focused agent's
-- cwd — switching focus swaps files, and a read that lands after another focus change is dropped
-- by the cwd guard. parse_cache keeps the doc's own cwd; a mismatch with the path it came from
-- (impossible when both sides encode identically) hides the cache rather than mislabeling it.
function read_cache(cx: WindowCx?)
	if cx == nil then
		return
	end
	local cwd = agent_fields.cwd
	local path = if cwd and cwd ~= "" then cache_file(cwd) else nil
	if not path then
		-- no focused agent: drop stale cache-driven segments instead of showing another project's
		if next(cache_fields.providers) ~= nil or cache_fields.model_provider or cache_fields.kube or cache_fields.cache_at then
			cache_fields = { providers = {} }
			publish()
			chrome.refresh()
		end
		return
	end
	local ok, reading = pcall(function(): any
		return (cx :: WindowCx).docs:read(path :: string)
	end)
	if not ok or reading == nil then
		return
	end
	(reading :: any):next(function(text: string?, _err: string?)
		if agent_fields.cwd ~= cwd then
			return -- focus moved on while this read was in flight
		end
		if text == nil or type(text) ~= "string" then
			return
		end
		local fields = parse_cache(text :: string)
		-- strict: a doc without its own cwd is an old-shape file that cannot be scoped to any
		-- project, so it must be hidden, not applied
		if (fields.cwd or "") ~= (cwd or "") then
			return -- wrong project, or an old-shape file with no cwd at all
		end
		cache_fields = fields
		publish()
		chrome.refresh()
	end)
end

local function poll_cache(cx: WindowCx?)
	tern.timer(CACHE_POLL_MS, poll_cache)
	read_cache(cx)
	local ok, reading = pcall(function(): any
		return (cx :: WindowCx).docs:read(config.path())
	end)
	if ok and reading then
		reading:next(function(text: string?, _err: string?)
			if text ~= nil and text ~= config_text then
				config_text = text
				config.from_file(text :: string)
				chrome.refresh()
			end
		end)
	end
end

-- Process polls: kube context and AWS profile. Each on its own cadence (`segments.<id>.refreshMs`,
-- re-read every round) with its own process timeout (`timeoutMs`); async callbacks only.
local KUBE_MS = 10000
local AWS_MS = 30000
local PROC_TIMEOUT_MS = 5000

local function poll_ms(name: SegmentName, fallback: number): number
	local seg = cfg.segments[name]
	return (seg and seg.refreshMs) or fallback
end

local function poll_timeout(name: SegmentName): number
	local seg = cfg.segments[name]
	return (seg and seg.timeoutMs) or PROC_TIMEOUT_MS
end

-- `tern.process.run` raises when the binary can't spawn from Tern's launchd PATH; callers treat
-- that as a failed attempt instead of losing the timer chain.
local function run(argv: { string }, timeout_ms: number, cb: (result: any, cx: any?) -> ())
	local ok = pcall(function()
		tern.process.run(argv, { timeout_ms = timeout_ms }, cb)
	end)
	if not ok then
		cb({ status = -1 }, nil)
	end
end

local function poll_kube()
	-- Tern's launchd PATH lacks the user's shell paths and the mise shim needs mise's env
	-- (shim errors "no version is set" under launchd), so call the real binary. `latest` is
	-- mise's stable symlink to the active install, surviving version bumps.
	run({ "/Users/yuri/.local/share/mise/installs/kubectl/latest/kubectl", "config", "current-context" }, poll_timeout("kube"), function(shim_result, _cx)
		local shim_current = if shim_result.status == 0 then (shim_result.stdout or ""):gsub("%s+$", "") else ""
		if shim_current ~= nil and (shim_current :: string) ~= "" then
			proc_fields.kube = shim_current :: string
			publish()
			return
		end
		-- No current-context: exactly one configured context is an unambiguous fallback
		run({ "/Users/yuri/.local/share/mise/installs/kubectl/latest/kubectl", "config", "get-contexts", "-o", "name" }, poll_timeout("kube"), function(fallback, _cx)
			if fallback.status ~= 0 then
				proc_fields.kube = nil
				publish()
				return
			end
			local count, only = 0, nil
			for name in ((fallback.stdout or "") :: string):gmatch("[^\n]+") do
				name = (name :: string):gsub("%s+$", "")
				if name ~= "" then
					count += 1
					only = name
				end
			end
			proc_fields.kube = if count == 1 then only else nil
			publish()
		end)
	end)
end

-- AWS_PROFILE is a fish universal var set with `set -Ux` (conf.d/environment.fish); fish -N
-- skips config and doesn't export it, so load the normal config despite the startup cost.
local function poll_aws()
	run({ "/opt/homebrew/bin/fish", "-c", "echo $AWS_PROFILE" }, poll_timeout("aws"), function(result, _cx)
		local value = if result.status == 0 then (result.stdout or ""):gsub("%s+$", "") else ""
		proc_fields.aws_profile = if value ~= nil and (value :: string) ~= "" then value :: string else nil
		publish()
	end)
end

local function poll_gateway()
	local key = tern.getenv("AIHUB_API_KEY")
	if not key or key == "" then
		return
	end
	tern.fetch(gateway_url .. "/v1/me/usage", {
		headers = { Authorization = "Bearer " .. (key :: string) },
	}, function(result: any, _cx: WindowCx?)
		if result.status == 200 then
			local ok, doc = pcall(function(): any
				return tern.json.decode(result.body or "")
			end)
			if ok and type(doc) == "table" and type(doc.daily_budget) == "table" then
				local spent = doc.daily_budget.spent_usd
				local limit = doc.daily_budget.limit_usd
				if type(spent) == "number" then
					gateway_state.spent = spent
					gateway_state.limit = if type(limit) == "number" then limit else nil
					publish()
				end
			end
		end
	end)
end

local DETAIL_ACTION = "plugin." .. tern.plugin.id .. ".detail"

-- The status bar assembly: config order, hidden disabled/empty segments, prefix in front.
-- Every segment carries the detail command: a click toggles the card.
local function compose(cfg0: Config, snap: Snapshot): ({ StatusSegment }, string)
	local out: { StatusSegment } = {}
	local sig = {}
	if cfg0.prefix ~= "" and cfg0.prefix ~= "none" then
		table.insert(out, { text = cfg0.prefix, tone = "muted", command = DETAIL_ACTION })
		table.insert(sig, "p:" .. cfg0.prefix)
	end
	for _, name in cfg0.order do
		local seg = cfg0.segments[name]
		if seg and seg.enabled then
			local rendered = segments.render(name, snap, seg)
			local item = rendered :: Rendered?
			if item then
				table.insert(out, { text = item.text, tone = item.tone, command = DETAIL_ACTION })
				table.insert(sig, name .. ":" .. item.text .. ":" .. (item.tone or ""))
			end
		end
	end
	return out, table.concat(sig, "\n")
end

-- ── widgets ──
-- One Tern widget per segment (`<plugin>/<segment>`), placed by the user in the widget bar.
-- Applicability depends on what the focused pane is, so views are prebuilt per pane class:
--   agent     an agent pane; omp vs ACP comes from the snapshot (`snap.acp`)
--   cli       a terminal running the claude CLI (`c`, `claude`): no agent block backs it
--   terminal  anything else (plain shells, no pane): only agent-independent segments apply
-- `render` classifies the pane (a field compare) and returns `views[class][name]`, nothing else.

type PaneClass = "agent" | "acp" | "cli" | "terminal"
type WidgetViewT = { text: string, tone: string?, title: string?, command: string?, value: number? }

local PANE_CLASSES: { PaneClass } = { "agent", "acp", "cli", "terminal" }

-- Editor tiles are narrow: each description leads with a sample of the widget, then where it
-- applies. Tern's WidgetSpec has no preview/sample hook, so a tile on a pane where the widget
-- doesn't apply shows only its name and this line.
local WIDGETS: { [SegmentName]: { label: string, description: string, styles: { string } } } = {
	provider = { label = "Provider", description = "aihub / zai / claude · agent + claude CLI", styles = { "text" } },
	usage = { label = "Usage", description = "5H ━━●── 50% left · omp panes", styles = { "text", "bar", "ring" } },
	context = { label = "Context", description = "󰆧 23% context used · omp panes", styles = { "text", "bar", "ring" } },
	budget = { label = "Budget", description = "󰆼 $12/$200 AI Hub spend · aihub only", styles = { "text", "bar", "ring" } },
	cost = { label = "Cost", description = "󰔛 $1.20 · ~$0.08/msg · omp panes", styles = { "text" } },
	aws = { label = "AWS", description = "☁ sre · every pane", styles = { "text" } },
	kube = { label = "Kube", description = "⎈ talos-default · every pane", styles = { "text" } },
}

local function pane_class(pane: any): PaneClass
	if pane == nil then
		return "terminal"
	end
	if pane.kind == "agent" then
		-- an ACP agent pane (the `c` alias, `tern acp …`) says so in its own pane info
		return if acp_of(pane) then "acp" else "agent"
	end
	if is_claude_cli(pane) then
		return "cli"
	end
	return "terminal"
end

-- The snapshot as each pane class should see it. A CLI pane is always the claude ACP agent; an
-- ACP agent pane is the agent its pane info names (the matching block may be missing); a
-- plain terminal has no agent at all, so agent-scoped cache data (kube) must not leak in.
local function snapshot_for(class: PaneClass, snap: Snapshot): Snapshot
	if class == "agent" then
		return snap
	end
	local out = table.clone(snap)
	out.model = nil
	out.agent_cwd = nil
	if class == "cli" then
		out.acp = "claude"
		out.state = "ready"
	elseif class == "acp" then
		out.acp = shown_acp or snap.acp or "claude"
		out.state = "ready"
	else
		out.acp = nil
		out.state = "exited"
	end
	return out
end

-- Does segment `name` apply to a pane of `class` (seen through `snap`)? No data is decided later.
local function applies(name: SegmentName, class: PaneClass, snap: Snapshot): boolean
	local omp = class == "agent" and snap.acp == nil
	if name == "cost" or name == "usage" or name == "context" then
		return omp
	elseif name == "provider" then
		return class ~= "terminal"
	elseif name == "budget" then
		return class == "agent" and segments.provider_name(snap) == "aihub"
	end
	return true -- aws, kube: every pane
end

local function widget_view(name: SegmentName, class: PaneClass, cfg0: Config, snap: Snapshot): WidgetViewT?
	local seg = cfg0.segments[name]
	if not cfg0.enabled or not seg or not seg.enabled then
		return nil
	end
	local item: Rendered? = if applies(name, class, snap) then segments.render(name, snap, seg) else nil
	if not item then
		if seg.inapplicable == "compact" then
			return { text = seg.compactIcon, tone = "muted", title = WIDGETS[name].label, command = DETAIL_ACTION }
		end
		return nil
	end
	local rendered = item :: Rendered
	return {
		text = if seg.compact then rendered.short or rendered.text else rendered.text,
		tone = rendered.tone,
		title = rendered.title or WIDGETS[name].label,
		command = DETAIL_ACTION,
		value = rendered.value,
	}
end

local views: { [PaneClass]: { [SegmentName]: WidgetViewT } } = { agent = {}, acp = {}, cli = {}, terminal = {} }

-- False when `tern.chrome.widget` is missing or any registration raised: the legacy status
-- formatter then turns on by itself, so the bar is never silently empty.
local widgets_ok = true

local function status_on(): boolean
	return cfg.statusSegments or not widgets_ok
end
local views_sig = ""

local function view_sig(v: WidgetViewT): string
	return table.concat({ v.text, v.tone or "", v.title or "", v.command or "", if v.value then string.format("%.4f", v.value) else "" }, "\1")
end

-- Rebuilds the prebuilt widget views and the legacy status table when anything visible changed,
-- then asks Tern to redraw. Runs from callbacks, never a formatter or render.
rebuild = function()
	local snap = data.snapshot()
	local changed = false
	local next_views: { [PaneClass]: { [SegmentName]: WidgetViewT } } = {}
	local sig: { string } = {}
	for _, class in PANE_CLASSES do
		local seen = snapshot_for(class, snap)
		local by: { [SegmentName]: WidgetViewT } = {}
		for _, name in SEGMENT_NAMES do
			local v = widget_view(name, class, cfg, seen)
			if v then
				by[name] = v
				table.insert(sig, class .. "/" .. name .. "\1" .. view_sig(v))
			end
		end
		next_views[class] = by
	end
	local joined = table.concat(sig, "\n")
	if joined ~= views_sig then
		views = next_views
		views_sig = joined
		changed = true
	end
	if status_on() then
		local out, status_sig = compose(cfg, snap)
		if status_sig ~= built_sig then
			built = out
			built_sig = status_sig
			changed = true
		end
	elseif built_sig ~= "" then
		built = {}
		built_sig = ""
		changed = true
	end
	if changed then
		tern.chrome.refresh()
	end
	card_mirror()
end

function chrome.refresh()
	-- another window may have saved settings; the kv mirror is shared
	cfg = config.load()
	poll_agents()
	rebuild()
	tern.chrome.refresh()
end

-- The class of the pane the card describes: the last focused pane that isn't a plugin block (the
-- card itself takes focus when clicked, and must keep describing the pane it floats over).
local card_class: PaneClass = "terminal"
local CARD_KIND = tern.plugin.id .. ".card"

-- Records which pane the chrome shows, so poll_agents follows it. Same rule both formatters use:
-- only agent and claude CLI panes move `shown_pane`; a plain terminal keeps the last agent's.
local function note_pane(pane: any): PaneClass
	local class = pane_class(pane)
	if pane ~= nil and pane.kind ~= "plugin" and pane.block ~= CARD_KIND then
		card_class = class
	end
	if pane ~= nil then
		shown_cli = cfg.enabled and class == "cli"
		if class == "acp" then
			shown_acp = acp_of(pane)
		end
		if cfg.enabled and class ~= "terminal" then
			shown_pane = pane.pane
		end
	end
	return class
end

-- Moves `shown_pane`/`shown_cli` to the pane a focus event names, before anything polls: the
-- renders that would otherwise move them only run after the refresh, so the first frame on the
-- new pane would show the old pane's agent. Falls back to the session's focused pane.
function chrome.note_focus(ev: any, cx: WindowCx)
	local id: number? = if type(ev) == "table" and type(ev.pane) == "number" then ev.pane else nil
	if id == nil then
		local ok, focused = pcall(function(): any
			return cx.session:focused()
		end)
		id = if ok and type(focused) == "number" then focused else nil
	end
	if id == nil then
		return
	end
	local ok, info = pcall(function(): any
		return cx.session:pane(id :: number)
	end)
	if ok and type(info) == "table" then
		note_pane(info)
	end
end

-- 4 ms budget: each widget's render records the pane and returns its prebuilt view, nothing else.
for _, name in SEGMENT_NAMES do
	local meta = WIDGETS[name]
	local ok, err = pcall(function()
		tern.chrome.widget(name, {
			name = "SL " .. meta.label,
			description = meta.description,
			styles = meta.styles :: any,
			render = function(pane: StatusPaneInfo?): WidgetView?
				local class = note_pane(pane)
				return (views[class] :: any)[name]
			end,
		})
	end)
	if not ok then
		widgets_ok = false
		tern.log.warn("statusline widget " .. name .. ": " .. tostring(err) .. " (falling back to the status formatter)")
	end
end

-- Legacy single-formatter path, off unless `statusSegments = true` or widgets failed to register
-- (see `widgets_ok`). 4 ms budget: return the
-- prebuilt table, nothing else.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local class = note_pane(pane)
	if not cfg.enabled or not status_on() or class == "terminal" then
		return nil
	end
	return built
end)

-- ── package: card ──────────────────────────────────────────────────────────────
-- The floating detail card. Tern lets only the host half define blocks, so the block lives in
-- `host.luau`; this package owns everything that needs the window: the toggle (find / pop up /
-- close, like claude-usage), the card model built from the snapshot for the focused pane's class,
-- its mirror into kv "card" (written from `rebuild` only while a card is open, only when it
-- changed), and the refresh requests the host block files under kv "card_refresh".
--
-- The model is plain JSON. Applicability is decided here with the widgets' rules (`applies`), so
-- the host draws what it gets: omp-only rows are simply absent on ACP and claude CLI panes.

local card = {}

-- The pane of the open card, so rebuild knows whether to mirror; nil when none is open.
local card_pane: number? = nil
local card_sig = ""
local card_rev = 0
-- The data clock in the footer moves in 5 s steps, so an idle card writes kv at most that often.
local CARD_CLOCK_MS = 5000

export type CardWindow = { label: string, pct: number, reset: string?, saved: number? }
export type CardModel = {
	rev: number,
	class: string,
	provider: string?,
	model: string?,
	active: string?,
	providers: { { id: string, label: string, windows: { CardWindow } } },
	context: { pct: number, warn: number?, bad: number? }?,
	budget: { spent: number, limit: number?, warn: number?, bad: number? }?,
	cost: { total: string, avg: string?, turns: number? }?,
	kube: string?,
	aws: string?,
	usage: { warn: number?, bad: number? },
	updated: number,
	path: string?,
}

-- The card as a pane of `class` should see it (rows that don't apply, or lack data, are absent).
function card.model(cfg0: Config, class: PaneClass, snap: Snapshot): CardModel
	local seen = snapshot_for(class, snap)
	local omp = class == "agent" and seen.acp == nil
	local out: CardModel = {
		rev = 0,
		class = class,
		providers = {},
		usage = { warn = cfg0.segments.usage.warnAt, bad = cfg0.segments.usage.badAt },
		updated = 0,
		path = config.path(),
	}
	if applies("provider", class, seen) then
		out.provider = segments.provider_name(seen)
		out.model = seen.model
	end
	if omp then
		out.active = segments.active_usage(seen)
		for _, provider in seen.providers do
			local windows: { CardWindow } = {}
			for _, w in provider.windows do
				table.insert(windows, { label = w.label, pct = w.pct, reset = w.reset, saved = w.saved })
			end
			table.insert(out.providers, { id = provider.id, label = provider.label, windows = windows })
		end
		if seen.context_pct then
			local seg = cfg0.segments.context
			out.context = { pct = seen.context_pct :: number, warn = seg.warnAt, bad = seg.badAt }
		end
		local cost = seen.session_cost
		if cost and cost ~= "" then
			local total = format.parse_usd(cost :: string)
			local turns = seen.session_turns
			local avg: string? = nil
			if total and turns and turns > 1 then
				avg = string.format("$%.2f", total / turns)
			end
			out.cost = { total = cost :: string, avg = avg, turns = turns }
		end
	end
	if seen.budget and applies("budget", class, seen) then
		local seg = cfg0.segments.budget
		local budget = seen.budget :: { spent: number, limit: number? }
		out.budget = { spent = budget.spent, limit = budget.limit, warn = seg.warnAt, bad = seg.badAt }
	end
	out.kube = segments.kube_value(seen, cfg0.segments.kube)
	if seen.aws_profile and seen.aws_profile ~= "" then
		out.aws = seen.aws_profile
	end
	-- the footer's "updated": the omp cache's write time on omp panes, else the last poll
	local at = if omp and seen.cache_at then seen.cache_at :: number else snap.at
	out.updated = at - at % CARD_CLOCK_MS
	return out
end

local function model_sig(m: CardModel): string
	local parts: { string } = {
		m.class, m.provider or "", m.model or "", m.active or "", tostring(m.updated), m.path or "",
		m.kube or "", m.aws or "", tostring(m.usage.warn), tostring(m.usage.bad),
	}
	for _, p in m.providers do
		table.insert(parts, "p" .. p.id .. "\1" .. p.label)
		for _, w in p.windows do
			table.insert(parts, table.concat({ w.label, tostring(w.pct), w.reset or "", tostring(w.saved or "") }, "\1"))
		end
	end
	if m.context then
		table.insert(parts, string.format("c%.2f/%s/%s", m.context.pct, tostring(m.context.warn), tostring(m.context.bad)))
	end
	if m.budget then
		table.insert(parts, string.format("b%.4f/%s/%s/%s", m.budget.spent, tostring(m.budget.limit), tostring(m.budget.warn), tostring(m.budget.bad)))
	end
	if m.cost then
		table.insert(parts, "$" .. m.cost.total .. (m.cost.avg or "") .. tostring(m.cost.turns))
	end
	return table.concat(parts, "\n")
end

-- Writes the card model when a card is open and it changed. Runs from rebuild (callbacks only).
card_mirror = function(force: boolean?)
	if card_pane == nil then
		return
	end
	local m = card.model(cfg, card_class, data.snapshot())
	local sig = model_sig(m)
	if sig == card_sig and not force then
		return
	end
	card_sig = sig
	card_rev += 1
	m.rev = card_rev
	pcall(tern.kv.set, "card", m)
end

-- Finds the open card anywhere in this window (restored after a restart, or closed elsewhere),
-- so mirroring follows the card that exists rather than what this VM last opened.
function card.sync(cx: WindowCx)
	local ok, panes = pcall(function(): any
		return cx.session:panes()
	end)
	if not ok or type(panes) ~= "table" then
		return
	end
	local found: number? = nil
	for _, info in panes do
		if info.block == CARD_KIND then
			found = info.pane
			break
		end
	end
	if found ~= card_pane then
		card_pane = found
		card_mirror(true)
	end
end

-- The card in the focused pane's tab, if any (claude-usage's find_panel).
local function find_card(cx: WindowCx): (PaneInfo?, number?)
	local focused = cx.session:focused()
	local here = if focused then cx.session:pane(focused) else nil
	local tab = here and here.tab
	for _, p in cx.session:panes() do
		if p.block == CARD_KIND and p.tab == tab then
			return p, focused
		end
	end
	return nil, focused
end

-- Glance size in cells: wide enough for a meter row, one line per row the model will draw.
local function card_size(m: CardModel): { number }
	local rows = 4 -- head, rule, footer, padding
	for _, p in m.providers do
		if p.id == (m.active or "") then
			rows += math.max(#p.windows, 1)
		end
	end
	for _, present in { m.context ~= nil, m.budget ~= nil, m.cost ~= nil, m.kube ~= nil, m.aws ~= nil } do
		if present then
			rows += 1
		end
	end
	return { 58, rows + 2 }
end

-- Opens the card floating in the top-right corner over the focused tiled pane.
local function pop_up(cx: WindowCx, focused: number?)
	local over = focused
	local info = if over then cx.session:pane(over :: number) else nil
	if info == nil or info.floating then
		over = nil
	end
	if info and not info.floating then
		note_pane(info)
	end
	-- mirror before the block starts, so its first frame already has this pane's data
	card_pane = -1
	card_mirror(true)
	local pane = cx:new_block(CARD_KIND, nil, nil, { focus = false })
	if pane == nil then
		card_pane = nil
		cx:toast("error", "omp Statusline: cannot open the card", "is the plugin's host half loaded?")
		return
	end
	card_pane = pane
	cx.layout:float(pane, over, "tr", { focus = false, size = card_size(card.model(cfg, card_class, data.snapshot())) })
end

-- The click / palette / chord action: open the card, close it when it floats, re-float it when the
-- user docked it.
function card.toggle(cx: WindowCx)
	local panel, focused = find_card(cx)
	if panel == nil then
		pop_up(cx, focused)
	elseif panel.floating then
		cx.layout:close(panel.pane)
		if card_pane == panel.pane then
			card_pane = nil
		end
	else
		cx.layout:float(panel.pane, nil, "tr")
		cx.layout:focus(panel.pane)
	end
end

function card.closed(pane: number)
	if card_pane == pane then
		card_pane = nil
	end
end

-- The host block's refresh button bumps kv "card_refresh"; a change re-runs every poller now.
local refresh_seen: any = (function(): any
	local ok, value = pcall(tern.kv.get, "card_refresh")
	return if ok then value else nil
end)()

local refresh_all: () -> () -- assigned in wiring, once the pollers exist

function card.watch()
	if card_pane == nil then
		return
	end
	local ok, value = pcall(tern.kv.get, "card_refresh")
	if not ok or value == refresh_seen then
		return
	end
	refresh_seen = value
	refresh_all()
end

-- ── wiring ──

-- Cadence pollers run outside callbacks and need `cx` (agents, docs); window_start gives them one.
tern.on("window_start", function(cx: WindowCx)
	last_cx = cx
end)

tern.on("focus", function(ev: FocusEvent?, cx: WindowCx)
	last_cx = cx
	-- the focused pane leads the poll (and the cache read it kicks on a cwd change)
	chrome.note_focus(ev, cx)
	card.sync(cx)
	chrome.refresh()
end)

-- Every poller now: the card's refresh button. The gateway, kube and aws polls answer async and
-- publish; the cache read and agent poll publish too, so the mirror follows on its own.
refresh_all = function()
	poll_agents()
	read_cache(last_cx)
	poll_gateway()
	poll_kube()
	poll_aws()
end

-- The card toggle's default chord (Tern chord syntax, user-rebindable).
local CARD_KEYS = "ctrl+alt+s"

-- Palette command, chord and every widget click (`DETAIL_ACTION`): show / hide the card. The id
-- stays `detail` so existing keybindings keep working.
tern.command({ id = "detail", title = "omp Statusline: Show / Hide Card", icon = "gauge", keys = { CARD_KEYS }, run = card.toggle })

tern.on("pane_closed", function(ev: { pane: number })
	card.closed(ev.pane)
end)

-- Sheets: the chrome sheet hides tern's built-in git segment, whose branch reads twice next to the
-- plugin's segments (no settings knob for it).
do
	tern.css("statusline-chrome", table.concat({
		"footer#statusline .sl-git { display: none !important; }",
		-- the idle run dot and the pane size carry nothing the segments don't; hiding them also
		-- removes the stretch between the cwd and the plugin segments
		"footer#statusline .sl-run.idle { display: none !important; }",
		"footer#statusline .sl-n { display: none !important; }",
		-- the cwd parks at the bar's end, right before the plugin segments
		"footer#statusline .sl-cwd { order: 99 !important; margin-left: 12px !important; }",
	}, "\n"))
end

-- Boot: first refresh soon (the extension's cache lands when omp writes it), then cadences.
tern.timer(600, function(cx: WindowCx?)
	if cx then
		chrome.refresh()
	end
end)
tern.timer(300, function(cx: WindowCx?)
	poll_cache(cx)
end)

-- Cadences run forever; each schedules its own next tick.
local function cadence(ms: number | () -> number, fn: () -> ())
	local tick: () -> ()
	tick = function()
		local ok, err = pcall(fn)
		if not ok then
			-- a failing poller must not take the others down; log once per failure
			tern.log.warn("statusline poll failed: " .. tostring(err))
		end
		tern.timer(if type(ms) == "function" then ms() else ms, tick)
	end
	tern.timer(0, tick)
end

cadence(AGENT_POLL_MS, poll_agents)
cadence(1000, card.watch)
cadence(GATEWAY_MS, poll_gateway)
cadence(function() return poll_ms("kube", KUBE_MS) end, poll_kube)
cadence(function() return poll_ms("aws", AWS_MS) end, poll_aws)

-- Gateway refresh also rebuilds the bar on fetch callbacks (they call publish); poll_agents ticks
-- keep the model/state fresh between turns.
