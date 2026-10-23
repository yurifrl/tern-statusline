--!strict
-- omp Statusline — the omp statusline, remade as Tern chrome segments.
--
-- Segments (configurable order): indicator, provider, usage, context, budget, cost, memory, aws, kube.
-- Data comes from three seams, each owned by one module:
--   agents    — `cx.agents:list()`, native: model, working/idle state, pane ids
--   cache     — the companion extension's `~/.omp/cache/statusline.json`, async via `cx.docs:read`
--   process   — `tern.process.run` polls: kube context, memory RSS
--
-- BUDGET SAFETY: `tern.chrome.status` must stay under Tern's 4 ms hook budget (over budget
-- disables every plugin timer until reload). The formatter does ZERO work: segments are prebuilt
-- into upvalues by poll callbacks, and the formatter only returns the table.
--
-- Layout (packages, not sections): config · format · data · segments · chrome · detail · panel.
-- Each package owns its state; cross-package calls go through the public functions listed in
-- each header. See AGENTS.md for the rules this layout follows.

-- ── package: config ────────────────────────────────────────────────────────────
-- Reads the config file (`~/.config/tern-statusline/config.json`, overridable via
-- `TERN_STATUSLINE_CONFIG`), keeps it in `tern.kv` as the live mirror, and validates user JSON
-- at the boundary: unknown values fall back to defaults, nothing throws.

local CONFIG_DIR = "/.config/tern-statusline"
local CONFIG_FILE = "/config.json"

export type Tone = "muted" | "accent" | "ok" | "warn" | "error"

-- Segment names, in default render order.
export type SegmentName = "indicator" | "provider" | "usage" | "context" | "budget" | "cost" | "memory" | "aws" | "kube"

local SEGMENT_NAMES: { SegmentName } = {
	"indicator", "provider", "usage", "context", "budget", "cost", "memory", "aws", "kube",
}

export type SegmentConfig = {
	enabled: boolean,
	color: Tone?,
	-- component-specific knobs; validated per segment below
	icons: { [string]: string }?,
	refreshMs: number?,
	timeoutMs: number?,
	envVars: { string }?,
	strip: { string }?,
	showZero: boolean?,
	barGlyphs: number?,
	warnAt: number?,
	badAt: number?,
}

-- One segment's outcome: text (nil hides the segment) and its tone.
export type Rendered = {
	text: string,
	tone: Tone?,
}

export type Config = {
	enabled: boolean,
	-- "" none · "state" indicator glyph · any other string renders literally
	prefix: string,
	order: { SegmentName },
	segments: { [SegmentName]: SegmentConfig },
	detail: { enabled: boolean },
}

local DEFAULT_ICONS: { [string]: string } = {
	ready = "󰄾",
	working = "󰙨",
	refreshing = "󰔟",
	pressure = "󰆍",
	attention = "󰅐",
}

local DEFAULTS: Config = {
	enabled = true,
	prefix = "",
	order = {
		"indicator", "provider", "usage", "context", "budget", "cost", "memory", "aws", "kube",
	},
	segments = {
		indicator = { enabled = true, icons = DEFAULT_ICONS },
		provider = { enabled = true },
		usage = { enabled = true, barGlyphs = 8, warnAt = 25, badAt = 10 },
		context = { enabled = true, warnAt = 50, badAt = 75 },
		budget = { enabled = true, warnAt = 50, badAt = 75 },
		cost = { enabled = true, showZero = false },
		memory = { enabled = true, refreshMs = 10000 },
		aws = { enabled = true, envVars = { "AWS_PROFILE", "AWS_DEFAULT_PROFILE" } },
		kube = { enabled = true, refreshMs = 10000, timeoutMs = 5000, strip = {} },
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
	if name == "indicator" and type(input.icons) == "table" then
		for key, icon in input.icons do
			if type(key) == "string" and type(icon) == "string" and DEFAULT_ICONS[key] then
				(base.icons :: { [string]: string })[key] = icon
			end
		end
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
		if type(input[key]) == "number" and (input[key] :: number) >= 250 then
			local seg = base :: any
			seg[key] = math.floor(input[key])
		end
	end
	if (name == "aws" or name == "kube") and type(input.envVars) == "table" then
		local vars: { string } = {}
		for _, v in input.envVars do
			if type(v) == "string" and v ~= "" then
				table.insert(vars, v)
			end
		end
		if #vars > 0 then
			base.envVars = vars
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
	if type(input) ~= "table" then
		return cfg
	end
	cfg.enabled = if input.enabled ~= nil then input.enabled == true else true
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
-- Pure formatting helpers shared by every segment: counts, memory, money, time. No state, no I/O.

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

-- `412M`, `1.2G` from bytes; nil passes through as "".
function format.memory(bytes: number?): string
	if not bytes then
		return ""
	end
	if bytes >= 1024 * 1024 * 1024 then
		return string.format("%.1fG", bytes / (1024 * 1024 * 1024))
	end
	return string.format("%.0fM", bytes / (1024 * 1024))
end

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
	-- gateway (AI Hub, shared fetch)
	budget: { spent: number, limit: number? }?,
	-- cache (companion extension)
	providers: { Provider },
	context_pct: number?, -- composer context used, 0..100, scraped from the composer's meter
	session_cost: string?, -- the composer bar's cost text, e.g. "$1.20"
	session_turns: number?, -- message count, for the average
	-- process polls
	memory_bytes: number?,
	kube: string?,
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
-- One table per segment, in registry order. Each entry: `name`, `render(snapshot, seg, icons) ->
-- (text, tone)`. Render is pure; missing data returns nil and the segment drops out. The chrome
-- package walks `config.order`, calls these, and owns nothing about any one segment.

local segments = {}

type Render = (Snapshot, SegmentConfig) -> Rendered?

local by_name: { [SegmentName]: Render } = {}

local function register(name: SegmentName, render: Render)
	by_name[name] = render
end

-- indicator — state glyph; pressure overrides working when context passes thresholds.
register("indicator", function(snap, seg)

	local icons = seg.icons :: { [string]: string }
	if snap.state == "working" or snap.state == "waiting" then
		local ctx = snap.context_pct
		if ctx and seg.warnAt and ctx > seg.warnAt then
			return { text = icons.pressure, tone = if seg.badAt and ctx > seg.badAt then "error" else "warn" }
		end
		return { text = icons.working, tone = "accent" }
	end
	if snap.state == "exited" then
		return nil
	end
	return { text = icons.ready, tone = "ok" }
end)

-- provider — the AI provider behind the active agent's model: `aihub/aihub/glm-5.3-flash` reads
-- `aihub`; a bare model name (no provider prefix) hides the segment.
register("provider", function(snap, seg)

	if not snap.model then
		return nil
	end
	local name = (snap.model :: string):match("^([^/]+)/")
	if not name or name == "" then
		return nil
	end
	return { text = name, tone = seg.color or "accent" }
end)

-- usage — provider windows as `5H ━●── 77% 1h` groups, joined by `·`.
register("usage", function(snap, seg)

	if #snap.providers == 0 then
		return nil
	end
	local glyphs = seg.barGlyphs or 8
	local parts: { string } = {}
	local tone: Tone = seg.color or "muted"
	local worst = 100
	for pi, provider in snap.providers do
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
	return { text = table.concat(parts, " · "), tone = format.threshold(worst, tone, seg.warnAt, seg.badAt) }
end)

-- context — the composer context meter, scraped: `󰆧 23%`.
register("context", function(snap, seg)

	local pct = snap.context_pct
	if not pct then
		return nil
	end
	return {
		text = string.format("󰆧 %d%%", math.floor(pct + 0.5)),
		tone = format.threshold(pct, seg.color or "muted", seg.warnAt, seg.badAt),
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
	return { text = "󰆼 " .. text, tone = format.threshold(pct, seg.color or "accent", seg.warnAt, seg.badAt) }
end)

-- cost — session spend with per-message average: `󰔛 $1.20 · ~$0.08/msg`.
register("cost", function(snap, seg)

	if not snap.session_cost or snap.session_cost == "" then
		return nil
	end
	local text = "󰔛 " .. snap.session_cost
	if snap.session_turns and snap.session_turns > 1 then
		local total = format.parse_usd(snap.session_cost)
		if total then
			text ..= string.format(" · ~$%.2f/msg", total / snap.session_turns)
		end
	end
	return { text = text, tone = seg.color or "muted" }
end)

-- memory — the omp process's RSS: `󰍛 412M`.
register("memory", function(snap, seg)

	if not snap.memory_bytes then
		return nil
	end
	return { text = "󰍛 " .. format.memory(snap.memory_bytes), tone = seg.color or "muted" }
end)

-- aws — first configured env var holding a profile name: `☁ nsx`.
register("aws", function(snap, seg)

	local vars = seg.envVars or { "AWS_PROFILE", "AWS_DEFAULT_PROFILE" }
	for _, name in vars do
		local value = tern.getenv(name)
		if value and value ~= "" then
			return { text = "☁ " .. value, tone = seg.color or "warn" }
		end
	end
	return nil
end)

local function strip_all(text: string, patterns: { string }): string
	local display = text
	for _, pattern in patterns do
		display = display:gsub(pattern, "")
	end
	return display
end

-- kube — current kubectl context, refreshed by the process poller: `⎈ talos-default`.
register("kube", function(snap, seg)

	if not snap.kube or snap.kube == "" then
		return nil
	end
	local display = strip_all(snap.kube, seg.strip or {})
	if display == "" then
		return nil
	end
	return { text = "⎈ " .. display, tone = seg.color or "ok" }
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

-- ── package: detail ────────────────────────────────────────────────────────────
-- The detail view replaces the hover card of the old statusline: clicking the statusline (or the
-- palette command) opens a canvas listing every segment's full values — per-window resets, model,
-- spend math, kube context, config path.

local detail = {}

local DETAIL_SHEET = "statusline-detail"
local PANEL_TITLE = "omp Statusline: Detail"

-- One line per fact; segments append theirs.
type Row = { label: string, value: string, tone: Tone? }

local function row(label: string, value: string, tone: Tone?): Row
	return { label = label, value = value, tone = tone }
end

-- The view: segment rows top to bottom, then the config path and the settings hint.
local function build_rows(cfg: Config, snap: Snapshot, path: string?): { Row }
	local rows: { Row } = {}
	local model = snap.model or "—"
	table.insert(rows, row("Model", model, "accent"))
	local provider = if model ~= "—" then (model :: string):match("^[^/]+") or "—" else "—"
	table.insert(rows, row("Provider", provider :: string, "accent"))
	local state = snap.state
	table.insert(rows, row("State", state, if state == "working" then "accent" elseif state == "ready" then "ok" else "muted"))
	for _, provider in snap.providers do
		for _, window in provider.windows do
			local value = string.format("%d%% left", window.pct)
			if window.reset and window.reset ~= "" then
				value ..= " · resets in " .. window.reset
			end
			if window.saved and window.saved > 0 then
				value ..= string.format(" · +%d saved", window.saved)
			end
			table.insert(rows, row(provider.label .. " " .. window.label, value))
		end
	end
	if snap.context_pct then
		table.insert(rows, row("Context", string.format("%d%% used", math.floor(snap.context_pct + 0.5))))
	end
	if snap.budget then
		local value = format.usd(snap.budget.spent)
		if snap.budget.limit then
			value ..= " of " .. format.usd(snap.budget.limit)
		end
		table.insert(rows, row("Budget", value))
	end
	if snap.session_cost then
		local turns = if snap.session_turns then string.format(" · %d msgs", snap.session_turns) else ""
		table.insert(rows, row("Session cost", snap.session_cost .. turns))
	end
	if snap.memory_bytes then
		table.insert(rows, row("Memory", format.memory(snap.memory_bytes)))
	end
	if snap.kube then
		table.insert(rows, row("Kube", snap.kube))
	end
	if path then
		table.insert(rows, row("Config", path, "muted"))
	end
	return rows
end

function detail.view(cfg: Config, snap: Snapshot, path: string?)
	local rows = build_rows(cfg, snap, path)
	local nodes = {}
	for i, item in rows do
		table.insert(nodes, (tern.ui.el("div", {
			key = "r" .. i,
			class = "tsl-row",
			attrs = { ["data-tone"] = item.tone or "" },
		}, {
			tern.ui.el("span", { class = "tsl-label", text = item.label }),
			tern.ui.el("span", { class = "tsl-value", text = item.value }),
		})))
	end
	return tern.ui.el("div", { class = "tsl-detail" }, nodes)
end

function detail.sheet(): string
	return [==[
.tsl-detail { display: flex; flex-direction: column; gap: 2px; padding: 12px 16px; }
.tsl-row { display: flex; justify-content: space-between; gap: 16px; }
.tsl-label { font: 500 11px/18px var(--mono); color: var(--t3); }
.tsl-value { font: 400 11.5px/18px var(--mono); font-variant-numeric: tabular-nums; color: var(--t1); white-space: nowrap; }
.tsl-row[data-tone='accent'] .tsl-value { color: var(--accent); }
.tsl-row[data-tone='ok'] .tsl-value { color: var(--ok); }
.tsl-row[data-tone='warn'] .tsl-value { color: var(--warn); }
.tsl-row[data-tone='error'] .tsl-value { color: var(--bad); }
.tsl-row[data-tone='muted'] .tsl-value { color: var(--t3); }
]==]
end

-- ── package: chrome ────────────────────────────────────────────────────────────
-- Wires data to the status bar: one focus/refresh loop, per-source pollers, and the prebuilt
-- segment table the 4 ms formatter returns. Owns all timing.

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

-- Agents and cache both feed the snapshot; each keeps its own fields and merges on publish.
local agent_fields: { model: string?, state: "ready" | "working" | "waiting" | "exited", pane: number? } = {
	state = "exited",
}
local cache_fields: { providers: { Provider }, context_pct: number?, session_cost: string?, session_turns: number? } = {
	providers = {},
}
local proc_fields: { memory_bytes: number?, kube: string? } = {}

-- Forward-declared: publish rebuilds the prebuilt bar, so every data source lands visibly.
local rebuild: () -> ()

local function publish()
	data.publish({
		pane = agent_fields.pane,
		model = agent_fields.model,
		state = agent_fields.state,
		budget = gateway.budget(),
		providers = cache_fields.providers,
		context_pct = cache_fields.context_pct,
		session_cost = cache_fields.session_cost,
		session_turns = cache_fields.session_turns,
		memory_bytes = proc_fields.memory_bytes,
		kube = proc_fields.kube,
		at = os.time() * 1000,
	})
	rebuild()
end

local last_cx: WindowCx? = nil

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
	else
		agent_fields.pane = nil
		agent_fields.model = nil
		agent_fields.state = "exited"
	end
	publish()
end

local CACHE_POLL_MS = 3000
local cache_text: string? = nil
local config_text: string? = nil

-- The extension's cache: `~/.omp/cache/statusline.json` (the companion extension writes it).
local CACHE_FILE = "/.omp/cache/statusline.json"
local CACHE_PATH: string? = (function(): string?
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	return if home and home ~= "" then home .. CACHE_FILE else nil
end)()

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
	-- the file also refreshes config when its version bumps; a present file confirms the extension
	return { providers = providers, context_pct = context, session_cost = cost, session_turns = turns }, nil
end

local function poll_cache(cx: WindowCx?)
	tern.timer(CACHE_POLL_MS, poll_cache)
	if cx == nil then
		return
	end
	local read = function(path: string?): any
		if path == nil then
			return nil
		end
		local ok, reading = pcall(function(): any
			return (cx :: WindowCx).docs:read(path :: string)
		end)
		return if ok then reading else nil
	end
	-- the extension's cache; a failed read (the file being replaced, or gone) keeps the last text
	local reading = read(CACHE_PATH)
	if reading then
		reading:next(function(text: string?, _err: string?)
			if text ~= nil and text ~= cache_text then
				cache_text = text
				cache_fields = parse_cache(text :: string)
				publish()
				chrome.refresh()
			end
		end)
	end
	-- the config file; its contents normalize into the kv mirror every window already reads
	local config_reading = read(config.path())
	if config_reading then
		config_reading:next(function(text: string?, _err: string?)
			if text ~= nil and text ~= config_text then
				config_text = text
				config.from_file(text :: string)
				chrome.refresh()
			end
		end)
	end
end

-- Process polls: kube context and omp RSS. Each on its own cadence, async callbacks only.
local KUBE_MS = 10000
local MEMORY_MS = 10000

local function poll_kube()
	tern.process.run({ "kubectl", "config", "current-context" }, { timeout_ms = 5000 }, function(result, _cx)
		local text = if result.status == 0 then (result.stdout or "") else ""
		if text ~= "" then
			proc_fields.kube = (text :: string):gsub("%s+$", "")
		else
			proc_fields.kube = nil
		end
		publish()
	end)
end

local function poll_memory()
	tern.process.run({ "ps", "-axo", "rss=,command=" }, { timeout_ms = 5000 }, function(result, _cx)
		local stdout = if result.status == 0 then (result.stdout or "") else ""
		if result.status ~= 0 or stdout == "" then
			return
		end
		local best: number? = nil
		for line in (stdout :: string):gmatch("[^\n]+") do
			local rss = tonumber(string.match(line, "^%s*(%d+)") or "")
			if rss and line:find("omp", 1, true) and line:find("agent", 1, true) then
				-- largest matching omp agent process wins
				best = if best == nil or rss > best then rss else best
			end
		end
		if best then
			proc_fields.memory_bytes = best * 1024
		end
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
-- Every segment carries the detail command: a click opens the panel.
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

-- Rebuilds the prebuilt table when the snapshot changed anything visible. Runs from callbacks,
-- never the formatter.
rebuild = function()
	local snap = data.snapshot()
	local out, sig = compose(cfg, snap)
	if sig ~= built_sig then
		built = out
		built_sig = sig
	end
end

function chrome.refresh()
	-- another window may have saved settings; the kv mirror is shared
	cfg = config.load()
	poll_agents()
	rebuild()
	tern.chrome.refresh()
end

-- 4 ms budget: return the prebuilt table, nothing else.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	if not cfg.enabled or pane.kind ~= "agent" then
		return nil
	end
	shown_pane = pane.pane
	return built
end)

-- ── package: panel ─────────────────────────────────────────────────────────────
-- The config file is the single source of truth: `poll_cache` reads it every CACHE_POLL_MS and
-- `config.from_file` normalizes it; nothing in this plugin ever writes it. The detail panel is
-- read-only and lives here only because it owns the panel-pane plumbing.

local panel_pane: number? = nil

-- The detail canvas: one row per fact, opened from the statusline click or the palette.
local function open_detail(cx: WindowCx)
	local cfg0 = config.load()
	local view = detail.view(cfg0, data.snapshot(), config.path())
	local opened, err = cx.canvas:open({
		title = PANEL_TITLE,
		about = "Every statusline value in full, from the last snapshot.",
		view = view,
		dock = tern.ui.el("div", { class = "tsl-dock" }, {
			tern.ui.el("span", { class = "tsl-hint", text = "values refresh when the statusline does" }),
		}),
		how = "preview",
	})
	if opened then
		panel_pane = opened
	else
		cx:toast("error", "Cannot open detail: " .. tostring(err))
	end
end

local detail_sheet_installed = false

-- The panel redraws itself on every focus while open; canvas:set replaces the whole view, so
-- there is no signature to diff — the 4 ms chrome formatter is the one that diffs.

local function sync_panel(cx: WindowCx)
	local pane = panel_pane
	if pane == nil then
		return
	end
	local alive = false
	for _, info in cx.session:panes() do
		if info.pane == pane then
			alive = true
			break
		end
	end
	if not alive then
		panel_pane = nil
		return
	end
	local cfg0 = config.load()
	local snap = data.snapshot()
	-- the pane may already be closing or owned by another plugin between the scan and the set
	local ok, err = pcall(function()
		cx.canvas:set(pane, {
			view = detail.view(cfg0, snap, config.path()),
		})
	end)
	if not ok then
		panel_pane = nil
		tern.log.warn("statusline panel: " .. tostring(err))
	end
end

-- ── wiring ──

-- Cadence pollers run outside callbacks and need `cx` (agents, docs); window_start gives them one.
tern.on("window_start", function(cx: WindowCx)
	last_cx = cx
end)

tern.on("focus", function(_ev, cx: WindowCx)
	last_cx = cx
	chrome.refresh()
	sync_panel(cx)
end)

-- Palette command. The chord opens the detail panel; the config file is the only way to change
-- behavior, and the README documents every key.
tern.command({ id = "detail", title = "omp Statusline: Detail…", icon = "gauge", keys = { PANEL_KEYS }, run = open_detail })

-- Panels close when their pane goes.
tern.on("pane_closed", function(ev: { pane: number })
	if panel_pane == ev.pane then
		panel_pane = nil
	end
end)

-- Sheets: the detail view styles its own classes; the chrome sheet hides tern's built-in git
-- segment, whose branch reads twice next to the plugin's segments (no settings knob for it).
if not detail_sheet_installed then
	detail_sheet_installed = true
	tern.css(DETAIL_SHEET, detail.sheet())
	tern.css("statusline-chrome", "footer#statusline .sl-git { display: none !important; }")
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
local function cadence(ms: number, fn: () -> ())
	local tick: () -> ()
	tick = function()
		local ok, err = pcall(fn)
		if not ok then
			-- a failing poller must not take the others down; log once per failure
			tern.log.warn("statusline poll failed: " .. tostring(err))
		end
		tern.timer(ms, tick)
	end
	tern.timer(0, tick)
end

cadence(AGENT_POLL_MS, poll_agents)
cadence(GATEWAY_MS, poll_gateway)
cadence(KUBE_MS, poll_kube)
cadence(MEMORY_MS, poll_memory)

-- Gateway refresh also rebuilds the bar on fetch callbacks (they call publish); poll_agents ticks
-- keep the model/state fresh between turns.
