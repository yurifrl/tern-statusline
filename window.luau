--!strict
-- omp Statusline — the omp statusline, remade as Tern chrome segments.
--
-- Segments (configurable order): indicator, model, usage, context, budget, cost, memory, aws, kube.
-- Data comes from three seams, each owned by one module:
--   agents    — `tern.agents:list()`, native: model, working/idle state, pane ids
--   cache     — the companion extension's `~/.omp/cache/statusline.json`, async via `cx.docs:read`
--   process   — `tern.process.run` polls: kube context, memory RSS
--
-- BUDGET SAFETY: `tern.chrome.status` must stay under Tern's 4 ms hook budget (over budget
-- disables every plugin timer until reload). The formatter does ZERO work: segments are prebuilt
-- into upvalues by poll callbacks, and the formatter only returns the table.
--
-- Layout (packages, not sections): config · format · data · segments · chrome · detail · settings.
-- Each package owns its state; cross-package calls go through the public functions listed in
-- each header. See AGENTS.md for the rules this layout follows.

-- ── package: config ────────────────────────────────────────────────────────────
-- Reads and writes the config file (`~/.config/tern-statusline/config.json`, overridable via
-- `TERN_STATUSLINE_CONFIG`), keeps it in `tern.kv` as the live mirror, and validates user JSON
-- at the boundary: unknown values fall back to defaults, nothing throws.

local CONFIG_DIR = "/.config/tern-statusline"
local CONFIG_FILE = "/config.json"

export type Tone = "muted" | "accent" | "ok" | "warn" | "error"

-- Segment names, in default render order.
export type SegmentName = "indicator" | "model" | "usage" | "context" | "budget" | "cost" | "memory" | "aws" | "kube"

local SEGMENT_NAMES: { SegmentName } = {
	"indicator", "model", "usage", "context", "budget", "cost", "memory", "aws", "kube",
}

export type SegmentConfig = {
	enabled: boolean,
	color: Tone?,
	-- component-specific knobs; validated per segment below
	icons: { [string]: string }?,
	showModel: boolean?,
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
		"indicator", "model", "usage", "context", "budget", "cost", "memory", "aws", "kube",
	},
	segments = {
		indicator = { enabled = true, icons = DEFAULT_ICONS },
		model = { enabled = true, showModel = false },
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

-- What the settings read and write. `tern.kv` is the live mirror every window sees; the file is
-- the durable copy the next launch loads. Both go through here, so one validation serves both.
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
	if name == "model" and input.showModel ~= nil then
		base.showModel = input.showModel == true
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

local function save(cfg: Config): ()
	tern.kv.set("config", cfg)
end

local function from_file(text: string): Config
	local ok, value = pcall(function(): any
		return tern.json.decode(text)
	end)
	local cfg = if ok then normalize(value) else normalize(nil)
	save(cfg)
	return cfg
end

	config.DEFAULTS = DEFAULTS
	config.SEGMENT_NAMES = SEGMENT_NAMES
	config.load = load
	config.save = save
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

-- model — the provider, optionally with the model id after a slash.
register("model", function(snap, seg)

	if not snap.model then
		return nil
	end
	return { text = snap.model, tone = seg.color or "accent" }
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

type StatusSegment = { text: string, icon: string?, tone: string? }

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

local function poll_agents()
	-- the cadence is also when another window's saved settings reach this one
	local next_cfg = config.load()
	if next_cfg ~= cfg then
		cfg = next_cfg
	end
	local blocks = tern.agents.list()
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

-- The status bar assembly: config order, hidden disabled/empty segments, prefix in front.
local function compose(cfg0: Config, snap: Snapshot): ({ StatusSegment }, string)
	local out: { StatusSegment } = {}
	local sig = {}
	if cfg0.prefix ~= "" and cfg0.prefix ~= "none" then
		table.insert(out, { text = cfg0.prefix, tone = "muted" })
		table.insert(sig, "p:" .. cfg0.prefix)
	end
	for _, name in cfg0.order do
		local seg = cfg0.segments[name]
		if seg and seg.enabled then
			local rendered = segments.render(name, snap, seg)
			local item = rendered :: Rendered?
			if item then
				table.insert(out, { text = item.text, tone = item.tone })
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

function chrome.refresh(new_cfg: Config?)
	if new_cfg then
		cfg = new_cfg
	else
		-- another window may have saved settings; the kv mirror is shared
		cfg = config.load()
	end
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

-- ── package: settings ──────────────────────────────────────────────────────────
-- Settings two ways, sharing one mutation surface: the panel (a canvas beside the focused pane)
-- and the palette menu (`cx:pick` trees). Every change goes through `apply`, which saves to
-- `tern.kv` (all windows see it at once), rewrites the config file via `tern.docs:write`, and
-- redraws the line — so the menu saves to file, which is the preferred behavior.

local PANEL_KEYS = "ctrl+alt+s"

local DETAIL_ACTION = "plugin." .. tern.plugin.id .. ".detail"
local SETTINGS_ACTION = "plugin." .. tern.plugin.id .. ".settings"
local TOGGLE_ACTION = "plugin." .. tern.plugin.id .. ".toggle"

local panel_pane: number? = nil

-- The config file, rewritten from the live mirror. The parent directory must exist (tern raises
-- otherwise); the install step creates it, and a failure toasts once.
local wrote_at = 0
local function write_file(cx: WindowCx, cfg: Config)
	local path = config.path()
	if not path then
		return
	end
	local ok, writing = pcall(function(): any
		return cx.docs:write(path :: string, tern.json.encode(cfg))
	end)
	if ok and writing then
		-- the file now matches the mirror; the next differing read is someone else's change
		config_text = tern.json.encode(cfg)
		writing:next(function(_range: any, err: string?)
			if err and os.time() * 1000 - wrote_at > 60000 then
				wrote_at = os.time() * 1000
				local dir = (path :: string):match("(.*/)") or ""
				cx:toast("error", "statusline config: " .. err, "Create " .. dir .. " first")
			end
		end)
	end
end

local function apply(cx: WindowCx, cfg: Config)
	config.save(cfg)
	chrome.refresh(cfg)
	write_file(cx, cfg)
end

-- The detail canvas: one row per fact, opened from the statusline click, the palette, or chord.
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
		how = "beside",
	})
	if opened then
		panel_pane = opened
	else
		cx:toast("error", "Cannot open detail: " .. tostring(err))
	end
end

local detail_sheet_installed = false

-- The panel keeps itself current while open: each refresh redraws it if its signature changed.
local panel_sig: string? = nil

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
	local sig = tostring(snap.at) .. ":" .. tostring(#snap.providers) .. ":" .. tostring(snap.state)
	if sig ~= panel_sig then
		panel_sig = sig
		cx.canvas:set(pane, {
			view = detail.view(cfg0, snap, config.path()),
		})
	end
end

-- ── the palette menu ──

local function toggle(cx: WindowCx)
	local cfg0 = config.load()
	cfg0.enabled = not cfg0.enabled
	apply(cx, cfg0)
	cx:toast("info", "Statusline " .. (if cfg0.enabled then "on" else "off"))
end

local function choose_prefix(cx: WindowCx)
	local cfg0 = config.load()
	cx:pick({
		placeholder = "Prefix",
		icon = "text",
		items = {
			{ label = "None", current = cfg0.prefix == "", pick = "" },
			{ label = "State glyph (ready/working/…)", current = cfg0.prefix == "state", pick = "state" },
		},
	}):next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
		if item then
			local cfg1 = config.load()
			cfg1.prefix = (item :: any).pick
			apply(next_cx or cx, cfg1)
		end
	end)
end

-- One toggle entry per segment, in config order; a second pick reorders.
local function choose_order(cx: WindowCx)
	local cfg0 = config.load()
	local items: { any } = {}
	for _, name in config.SEGMENT_NAMES do
		local seg = cfg0.segments[name]
		table.insert(items, {
			label = name,
			detail = if seg and seg.enabled then "shown" else "hidden",
			pick = name,
		})
	end
	cx:pick({ placeholder = "Show which segments first?", items = items, icon = "list" }):next(function(item, _err, next_cx)
		if not item then
			return
		end
		local first = (item :: any).pick :: SegmentName
		local rest: { SegmentName } = {}
		for _, name in cfg0.order do
			if name ~= first then
				table.insert(rest, name)
			end
		end
		local order = { first }
		for _, name in rest do
			table.insert(order, name)
		end
		local cfg1 = config.load()
		cfg1.order = order
		apply(next_cx or cx, cfg1)
	end)
end

-- Per-segment summary line for the chooser.
local function segment_detail(cfg: Config, name: SegmentName): string
	local seg = cfg.segments[name]
	if not seg then
		return ""
	end
	local bits: { string } = { if seg.enabled then "on" else "off" }
	if seg.color then
		table.insert(bits, (seg.color :: string))
	end
	if name == "usage" and seg.warnAt then
		table.insert(bits, string.format("warn<%d bad<%d", seg.warnAt, seg.badAt or 0))
	end
	if name == "model" and seg.showModel then
		table.insert(bits, "model id")
	end
	return table.concat(bits, " · ")
end

-- The options for one segment; toggles and color first, then its specific knobs.
local function segment_options(cx: WindowCx, name: SegmentName)
	local cfg0 = config.load()
	local seg = cfg0.segments[name]
	if not seg then
		return
	end
	local items: { any } = {
		{ label = if seg.enabled then "Disable" else "Enable", pick = "enabled" },
		{
			label = "Cycle color",
			detail = if seg.color then seg.color else "default",
			pick = "color",
		},
	}
	if name == "model" then
		table.insert(items, { label = if seg.showModel then "Hide model id" else "Show model id", pick = "showModel" })
	elseif name == "cost" then
		table.insert(items, { label = if seg.showZero then "Hide when $0" else "Show when $0", pick = "showZero" })
	elseif name == "usage" then
		table.insert(items, { label = "Bar width", detail = tostring(seg.barGlyphs or 8), pick = "barGlyphs" })
		table.insert(items, { label = "Warn threshold", detail = if seg.warnAt then seg.warnAt .. "%" else "—", pick = "warnAt" })
		table.insert(items, { label = "Bad threshold", detail = if seg.badAt then seg.badAt .. "%" else "—", pick = "badAt" })
	elseif name == "context" or name == "budget" then
		table.insert(items, { label = "Warn threshold", detail = if seg.warnAt then seg.warnAt .. "%" else "—", pick = "warnAt" })
		table.insert(items, { label = "Bad threshold", detail = if seg.badAt then seg.badAt .. "%" else "—", pick = "badAt" })
	elseif name == "kube" then
		table.insert(items, { label = "Strip patterns…", detail = table.concat(seg.strip or {}, ", "), pick = "strip" })
	elseif name == "aws" then
		table.insert(items, { label = "Env variables…", detail = table.concat(seg.envVars or {}, ", "), pick = "envVars" })
	end
	cx:pick({ placeholder = name .. " options", items = items, icon = "sliders" }):next(function(item, _err, next_cx)
		local target = next_cx or cx
		if not item then
			return
		end
		local pick = (item :: any).pick :: string
		local cfg1 = config.load()
		local seg1 = cfg1.segments[name]
		if pick == "enabled" then
			seg1.enabled = not seg1.enabled
		elseif pick == "color" then
			local cycle: { Tone? } = { nil, "muted", "accent", "ok", "warn", "error" }
			local at = 1
			for i, t in cycle do
				if t == seg1.color then
					at = i
					break
				end
			end
			seg1.color = cycle[at % #cycle + 1]
		elseif pick == "showModel" then
			seg1.showModel = not seg1.showModel
		elseif pick == "showZero" then
			seg1.showZero = not seg1.showZero
		elseif pick == "barGlyphs" then
			seg1.barGlyphs = ((seg1.barGlyphs or 8) >= 16) and 4 or (seg1.barGlyphs or 8) + 4
		elseif pick == "warnAt" then
			seg1.warnAt = ((seg1.warnAt or 50) >= 90) and 10 or (seg1.warnAt or 50) + 20
		elseif pick == "badAt" then
			seg1.badAt = ((seg1.badAt or 75) >= 95) and 20 or (seg1.badAt or 75) + 20
		elseif pick == "strip" or pick == "envVars" then
			target:prompt({
				value = table.concat(if pick == "strip" then seg1.strip or {} else seg1.envVars or {}, ", "),
				placeholder = if pick == "strip" then "patterns, comma-separated" else "env var names, comma-separated",
				icon = "text",
			}):next(function(text: string?, _e: string?, next2: WindowCx?)
				if text and text ~= "" then
					local parts: { string } = {}
					for part in text:gmatch("[^,]+") do
						table.insert(parts, (part:gsub("^%s+", ""):gsub("%s+$", "")))
					end
					if pick == "strip" then
						seg1.strip = parts
					else
						seg1.envVars = parts
					end
					apply(next2 or target, cfg1)
				end
			end)
			return
		end
		apply(target, cfg1)
		segment_options(target :: any, name)
	end)
end

-- Per-segment options: color, plus the knobs each segment owns.
local function segment_menu(cx: WindowCx)
	local cfg0 = config.load()
	local items: { any } = {}
	for _, name in cfg0.order do
		table.insert(items, { label = name, detail = segment_detail(cfg0, name), pick = name })
	end
	cx:pick({ placeholder = "Which segment?", items = items, icon = "sliders" }):next(function(item, _err, next_cx)
		if item then
			segment_options(next_cx or cx, (item :: any).pick :: SegmentName)
		end
	end)
end

-- The settings menu: one entry per surface, every leaf applying through `apply`.
local function menu(cx: WindowCx)
	cx:pick({
		placeholder = "Statusline settings",
		icon = "sliders",
		items = {
			{ label = "Toggle statusline", detail = if config.load().enabled then "currently on" else "currently off", pick = "toggle" },
			{ label = "Choose prefix…", detail = config.load().prefix == "" and "none" or config.load().prefix, pick = "prefix" },
			{ label = "Reorder segments…", detail = table.concat(config.load().order, ", "), pick = "order" },
			{ label = "Segment options…", detail = "colors, icons, thresholds per segment", pick = "segments" },
			{ label = "Open detail panel…", detail = PANEL_KEYS, pick = "detail" },
		},
	}):next(function(item, _err, next_cx)
		local target = next_cx or cx
		if not item then
			return
		end
		local pick = (item :: any).pick :: string
		if pick == "toggle" then
			toggle(target :: any)
		elseif pick == "prefix" then
			choose_prefix(target)
		elseif pick == "order" then
			choose_order(target)
		elseif pick == "segments" then
			segment_menu(target)
		elseif pick == "detail" then
			open_detail(target)
		end
	end)
end

-- ── wiring ──

tern.on("focus", function(_ev, cx: WindowCx)
	chrome.refresh()
	sync_panel(cx)
end)

-- Palette commands and chords.
tern.command({ id = "settings", title = "omp Statusline: Settings…", icon = "sliders", keys = { PANEL_KEYS }, run = menu })
tern.command({ id = "detail", title = "omp Statusline: Detail…", icon = "gauge", run = open_detail })
tern.command({ id = "toggle", title = "omp Statusline: Toggle", icon = "power", run = toggle })

-- `statusline` in the status bar, on agent panes: a click opens settings.

-- The status bar formatter must stay pure and under budget; the click actions run from events.

tern.on("action", function(ev, cx: WindowCx): boolean
	if ev.action == SETTINGS_ACTION then
		menu(cx)
		return true
	elseif ev.action == DETAIL_ACTION then
		open_detail(cx)
		return true
	elseif ev.action == TOGGLE_ACTION then
		toggle(cx)
		return true
	end
	return false
end)

-- Panels close when their pane goes.
tern.on("pane_closed", function(ev: { pane: number })
	if panel_pane == ev.pane then
		panel_pane = nil
	end
end)

-- The detail sheet reaches plugin blocks by their data-surface.
if not detail_sheet_installed then
	detail_sheet_installed = true
	tern.css(DETAIL_SHEET, detail.sheet())
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
			tern.log("statusline poll failed: " .. tostring(err))
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
