--!strict
-- Behavior tests for the omp Statusline plugin.
--
-- The plugin is loaded twice inside luau-web's sandboxed Luau VM — host and window sources under
-- `load_host_plugin(api)` / `load_window_plugin(api)` shims with `tern` bound to the fake below —
-- and driven only through the seams production data flows through: `tern.kv` (config),
-- `tern.docs:read` (the extension cache), `tern.fetch` (the gateway), `tern.process.run` (kube, aws), `cx.agents:list` (model/state) and the registered chrome formatter. Each scenario
-- seeds a seam, ticks the timers, and asserts on the segments the formatter returns.

local cases = 0

local function equal(actual: any, expected: any, label: string)
	assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function test(label: string, run: () -> ())
	local ok, err = pcall(run)
	assert(ok, label .. ": " .. tostring(err))
	cases += 1
end

-- ── the fake tern ──

local fake_window_cx, fake_pane

local function fake_tern()
	local t = {}
	t.plugin = { id = "tern-statusline" }
	t.now = function() return 1_000_000 end

	-- view builders: nodes are inert `{k, p, c}` tables in the fake, like Tern's wire nodes
	t.ui = {
		el = function(tag: string, props: any, children: any)
			return { k = tag, p = props or {}, c = children }
		end,
		span = function(text: string, style: string?)
			return { t = text, s = style }
		end,
		node = function(kind: string, props: any, children: any)
			return { k = kind, p = props or {}, c = children }
		end,
		badge = function(text: string, tone: string)
			return { k = "badge", p = { text = text, tone = tone } }
		end,
		col = function(children: any)
			return { k = "col", p = {}, c = children }
		end,
		row = function(children: any)
			return { k = "row", p = {}, c = children }
		end,
		rule = function(label: any)
			return { k = "rule", p = { label = label } }
		end,
	}

	-- host blocks: `tern.block.define` captures the def; `cx:new_block` instantiates it
	t.blocks = {}
	t.block = {
		define = function(id: string, def: any)
			assert(type(def.init) == "function" and type(def.view) == "function", "block needs init and view")
			t.blocks[id] = def
		end,
	}
	t.getenv = function(name)
		if name == "HOME" then
			return "/home/test"
		end
		if name == "AIHUB_API_KEY" then
			return "test-key"
		end
		return nil
	end

	-- JSON round-trips through a registry; fixtures seed exact tables instead of depending on a codec
	local registry: { [string]: any } = {}
	local next_id = 0
	t.json = {
		_decode = function(text: string)
			return registry[text]
		end,
		_encode = function(value: any): string
			next_id += 1
			local key = "#" .. next_id
			registry[key] = value
			return key
		end,
		decode = function(text: string): any
			return t.json._decode(text)
		end,
		encode = function(value: any): string
			return t.json._encode(value)
		end,
	}

	local log: { string } = {}
	t.log_lines = log
	t.log = {
		warn = function(message: string) table.insert(log, message) end,
		info = function(...) end,
		error = function(message: string) table.insert(log, message) end,
		debug = function(...) end,
	}

	t.refreshes = 0
	t.css = function(_name: string, _source: string) end

	-- kv is a table of dot-called functions, matching Tern's contract
	local store: { [string]: any } = {}
	t.kv = {
		store = store,
		get = function(key: string) return store[key] end,
		set = function(key: string, value: any) store[key] = value end,
	}

	t.timers = {}
	function t.timer(ms: number, fn: (any?) -> ())
		local handle = { ms = ms, fn = fn, cancelled = false }
		function handle.cancel(self) self.cancelled = true end
		table.insert(t.timers, handle)
		return handle
	end
	function t.tick(self, count: number?)
		for _ = 1, count or 1 do
			local pending: { any } = {}
			for _, handle in t.timers do
				if not handle.cancelled then
					table.insert(pending, handle)
				end
			end
			t.timers = {}
			for _, handle in pending do
				if not handle.cancelled then
					handle.fn(fake_window_cx(t))
				end
			end
		end
	end

	-- agent blocks, listed through the window cx like the real API
	t.agents = { blocks = {} }

	-- chrome: capture the legacy status formatter and every widget registration. A render that
	-- calls `tern.chrome.refresh` raises, as in Tern.
	local formatter: ((any) -> any)?
	local rendering = false
	t.widgets = {}
	t.chrome = {
		status = function(fn) formatter = fn end,
		widget = function(id: string, spec: any)
			assert(string.match(id, "^[a-z][a-z0-9%-]*$") and #id <= 32, "bad widget id " .. id)
			assert(type(spec.name) == "string" and type(spec.render) == "function", "widget needs name and render")
			assert(spec.icon == nil, "no icon names are declared")
			t.widgets[id] = spec
		end,
		refresh = function()
			assert(not rendering, "tern.chrome.refresh called from a formatter")
			t.refreshes += 1
		end,
	}
	function t.status_for(pane: any)
		assert(formatter, "chrome.status was never registered")
		rendering = true
		local out = formatter(pane)
		rendering = false
		return out
	end
	function t.widget_for(id: string, pane: any)
		local spec = t.widgets[id]
		assert(spec, "widget " .. id .. " was never registered")
		rendering = true
		local out = spec.render(pane)
		rendering = false
		return out
	end

	-- docs:read answers each registered path once through the awaitable shape
	t.reads = {}
	t.docs = {
		read = function(_self, path: string)
			return {
				next = function(_self, fn: (any?, string?) -> ())
					fn(t.reads[path], nil)
				end,
			}
		end,
		write = function(_self, _path: string, _text: string)
			return { next = function(_self, fn: (any?, string?) -> ()) fn(nil, nil) end }
		end,
	}

	-- fetch records calls; scenarios answer through t.fetch_answers
	t.fetches = 0
	t.fetch_answers = {}
	t.fetch = function(_url: string, _opts: any, cb: (any, any?) -> ())
		t.fetches += 1
		local answer = t.fetch_answers[t.fetches] or { status = 500, body = "" }
		cb(answer, nil)
	end

	-- process.run records calls; scenarios answer through t.process_answers, keyed by which
	-- poller the argv belongs to (kube/aws) so adding pollers never shifts indexes
	t.process_calls = {}
	t.process_opts = {}
	t.process_answers = {}
	t.process = {
		run = function(argv: { string }, opts: any, cb: (any, any?) -> ())
			table.insert(t.process_calls, argv)
			local bin = argv[1] or ""
			local name = if bin:find("kubectl", 1, true) then "kube"
				elseif bin:find("fish", 1, true) then "aws"
				else "other"
			t.process_opts[name] = opts
			local answer = t.process_answers[name] or { status = 1, stdout = "" }
			cb(answer, nil)
		end,
	}

	-- commands and events
	t.commands = {}
	t.command_defs = {}
	t.command = function(def: any)
		t.commands[def.id] = def.run
		t.command_defs[def.id] = def
	end
	t.actions = {}
	t.on = function(name: string, fn: any)
		t.actions[name] = fn
		-- window_start runs once per plugin per window; the fake fires it immediately
		if name == "window_start" then
			fn(fake_window_cx(t))
		end
	end

	-- the window's panes, as cx.session sees them; `t:focus(info)` registers one, focuses it and
	-- fires the focus event the way Tern does
	t.panes = {}
	t.focused = nil
	t.session = {
		pane = function(_self, id: number) return t.panes[id] end,
		focused = function(_self) return t.focused end,
		panes = function(_self)
			local out = {}
			for _, info in t.panes do
				table.insert(out, info)
			end
			return out
		end,
	}
	-- cx:new_block opens a plugin block pane in the focused pane's tab and runs the host def's init;
	-- cx.layout floats and closes it (close fires pane_closed, like Tern)
	t.cards = {}
	t.floats = {}
	t.opened = {}
	local next_pane = 50
	function t.new_block(kind: string, args: any, _how: any, _opts: any): number?
		local id = kind:match("^tern%-statusline%.(.+)$")
		local def = id and t.blocks[id]
		if not def then
			return nil
		end
		next_pane += 1
		local pane = next_pane
		local here = t.focused and t.panes[t.focused]
		t.panes[pane] = { pane = pane, kind = "plugin", block = kind, tab = here and here.tab, floating = false, cwd = "", title = "omp Statusline" }
		local bcx: any = { pane = pane, cols = 58, rows = 12, renders = 0 }
		function bcx.render(self) self.renders += 1 end
		function bcx.open(_self, target: string) table.insert(t.opened, target) end
		function bcx.toast(_self, ...) end
		local st = def.init(bcx, args or {}, nil)
		t.cards[pane] = { def = def, st = st, cx = bcx }
		return pane
	end
	t.layout = {
		float = function(_self, pane: number, over: number?, corner: string?, opts: any)
			local info = t.panes[pane]
			if not info then
				return false, "no pane"
			end
			info.floating = true
			t.floats[pane] = { over = over, corner = corner, opts = opts }
			return true, nil
		end,
		close = function(_self, pane: number)
			t.panes[pane] = nil
			t.cards[pane] = nil
			local handler = t.actions["pane_closed"]
			if handler then
				handler({ pane = pane }, fake_window_cx(t))
			end
		end,
		focus = function(_self, pane: number) t.focused = pane end,
	}
	-- The open card (there is at most one in these scenarios) and its current view.
	function t.card()
		for pane, entry in t.cards do
			return pane, entry
		end
		return nil, nil
	end
	function t.card_view(): any
		local _, entry = t.card()
		assert(entry, "a card is open")
		return entry.def.view(entry.st, entry.cx).main
	end
	function t.card_event(act: string, value: string?)
		local _, entry = t.card()
		assert(entry, "a card is open")
		entry.def.event(entry.st, { ev = "action", act = act, value = value }, entry.cx)
	end

	function t.focus(self, info: any)
		t.panes[info.pane] = info
		t.focused = info.pane
		local handler = t.actions["focus"]
		assert(handler, "focus handler registered")
		handler({ pane = info.pane, tab = 1 }, fake_window_cx(t))
	end

	return t
end

function fake_window_cx(t)
	return {
		session = t.session,
		docs = t.docs,
		layout = t.layout,
		new_block = function(_self, kind: string, args: any, how: any, opts: any)
			return t.new_block(kind, args, how, opts)
		end,
		agents = {
			list = function(_self)
				return t.agents.blocks
			end,
		},
		toast = function() end,
		pick = function()
			return { next = function(_self, fn: (any?) -> ()) fn(nil) end }
		end,
		prompt = function()
			return { next = function(_self, fn: (any?) -> ()) fn(nil) end }
		end,
	}
end

-- Agent panes are 7 by default; terminals get their own id (8) so a terminal never aliases an agent.
function fake_pane(kind: string?, id: number?)
	local k = kind or "agent"
	if k == "agent" then
		return { pane = id or 7, kind = k, program = "omp", busy = false, cwd = "/tmp", title = "omp" }
	end
	return { pane = id or 8, kind = k, program = "fish", busy = false, cwd = "/tmp", title = "fish" }
end

-- A statusline cache the companion extension would have written. `now` makes it just-written
-- (the live modelProvider the plugin trusts); the default is an old file it must not trust.
-- `cwd` is the extension's new payload field — the writer's session cwd, which the plugin
-- gates on; omit it to model an extension that predates the field.
local function cache_fixture(t: any, windows: { any }, now: boolean?, cwd: string?): string
	return t.json._encode({
		generatedAt = if now then os.time() * 1000 else 1_000_000,
		providers = {
			{
				id = "zai",
				label = "ZAI",
				windows = windows,
			},
		},
		contextPct = 42,
		sessionCost = "$1.20",
		sessionTurns = 3,
		modelProvider = "zai",
		cwd = cwd,
	})
end

-- The plugin reads the focused project's file: `~/.omp/cache/statusline/<cache_key>.json`. For
-- the fixtures' cwd "/tmp" the shared encoding yields %2Ftmp — these tests pin that contract.
local CACHE_PATH = "/home/test/.omp/cache/statusline/%2Ftmp.json"

local WIDGET_IDS = { "provider", "usage", "context", "budget", "cost", "aws", "kube" }

-- All widget texts for `pane` (default: the omp agent pane), in segment order, joined for
-- substring assertions.
local function joined_for(t: any, pane: any?): string
	local texts: { string } = {}
	for _, id in WIDGET_IDS do
		local view = t.widget_for(id, pane or fake_pane())
		if view then
			table.insert(texts, view.text)
		end
	end
	return table.concat(texts, " ")
end

local function claude_cli_pane()
	return { pane = 11, kind = "terminal", program = "c", running = { line = "c --cli", ms = 1 }, cwd = "/tmp", title = "c" }
end

local ACP_LINE = "'/Applications/Tern.app/Contents/MacOS/tern' acp --resume 'claude:abc'"

-- Both halves on one fake, as Tern runs them against one kv store: host first (it defines the
-- card block), then the window.
local function load_both(t: any)
	load_host_plugin(t)
	load_window_plugin(t)
end

-- The first node keyed `key` in a view tree, depth first.
local function find_key(node: any, key: string): any
	if type(node) ~= "table" then
		return nil
	end
	if node.p and node.p.key == key then
		return node
	end
	for _, child in node.c or {} do
		local hit = find_key(child, key)
		if hit then
			return hit
		end
	end
	return nil
end

-- Every key under `node` starting with `prefix`, in tree order.
local function keys_with(node: any, prefix: string, out: { string }?): { string }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	local key = node.p and node.p.key
	if type(key) == "string" and key:sub(1, #prefix) == prefix then
		table.insert(acc, key)
	end
	for _, child in node.c or {} do
		keys_with(child, prefix, acc)
	end
	return acc
end

-- A row's text: each text node's spans run together, nodes joined by a space.
local function text_of(node: any): string
	local parts: { string } = {}
	local function walk(n: any)
		if type(n) ~= "table" then
			return
		end
		if n.p then
			if n.p.spans then
				local joined = ""
				for _, span in n.p.spans do
					joined ..= span.t
				end
				table.insert(parts, joined)
			end
			if n.k == "badge" then
				table.insert(parts, n.p.text)
			end
		end
		for _, child in n.c or {} do
			walk(child)
		end
	end
	walk(node)
	return table.concat(parts, " ")
end

local function has_kind(node: any, kind: string): boolean
	if type(node) ~= "table" then
		return false
	end
	if node.k == kind then
		return true
	end
	for _, child in node.c or {} do
		if has_kind(child, kind) then
			return true
		end
	end
	return false
end

-- ── scenarios ──

test("registers one widget per segment", function()
	local t = fake_tern()
	load_window_plugin(t)
	for _, id in WIDGET_IDS do
		local spec = t.widgets[id]
		assert(spec ~= nil, "widget registered: " .. id)
		assert(spec.name:match("^SL %u") ~= nil, "name prefixed: " .. spec.name)
		assert(utf8.len(spec.description) <= 60, "description fits a tile: " .. spec.description)
		assert(type(spec.description) == "string" and spec.description ~= "", "description: " .. id)
		local styles = table.concat(spec.styles, ",")
		local meter = id == "usage" or id == "context" or id == "budget"
		equal(styles, if meter then "text,bar,ring" else "text", "styles for " .. id)
	end
	equal(t.widgets.kube.name, "SL Kube", "kube label")
	equal(t.widgets.usage.name, "SL Usage", "usage label")
end)

test("legacy status formatter is off by default", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t:tick(2)
	assert(t.status_for(fake_pane("agent")) == nil, "no legacy segments without statusSegments")
end)

test("statusSegments = true restores the status formatter for agent panes only", function()
	local t = fake_tern()
	t.kv.store["config"] = { statusSegments = true }
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	local segments = t.status_for(fake_pane("agent"))
	assert(type(segments) == "table", "agent panes get segments")
	assert(t.status_for(fake_pane("terminal")) == nil, "terminals get none")
	t:tick(2)
	local texts: { string } = {}
	for _, segment in t.status_for(fake_pane("agent")) do
		table.insert(texts, segment.text)
	end
	assert(table.concat(texts, " "):find("aihub", 1, true) ~= nil, "legacy bar carries the segments")
end)

test("claude CLI terminals get the ACP-style widgets; Z.AI display names read zai", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 9, model = "Z.AI GLM-4.7", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t.widget_for("provider", claude_cli_pane())
	t:tick(2)
	local cli = joined_for(t, claude_cli_pane())
	assert(cli:find("claude", 1, true) ~= nil, "cli shows claude: " .. cli)
	assert(t.widget_for("usage", claude_cli_pane()) == nil, "no omp widgets on the cli")
	t.agents.blocks = { { pane = 7, model = "Z.AI GLM-4.7", state = "working", cwd = "/tmp" } }
	t.widget_for("provider", fake_pane())
	t:tick(2)
	assert(joined_for(t):find("zai", 1, true) ~= nil, "display name maps to zai: " .. joined_for(t))
end)

test("hides every widget when disabled", function()
	local t = fake_tern()
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	load_window_plugin(t)
	t.kv.store["config"] = { enabled = false, segments = { kube = { inapplicable = "compact" } } }
	t:tick(2)
	equal(joined_for(t), "", "disabled means no widgets")
	equal(joined_for(t, fake_pane("terminal")), "", "not on terminals either")
end)

test("a segment with enabled = false renders nil", function()
	local t = fake_tern()
	t.kv.store["config"] = { segments = { kube = { enabled = false, inapplicable = "compact" } } }
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	load_window_plugin(t)
	t:tick(2)
	assert(t.widget_for("kube", fake_pane()) == nil, "disabled kube renders nothing")
end)

test("kube renders on a plain terminal pane, agent segments don't", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 9, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	t.process_answers["aws"] = { status = 0, stdout = "nsx\n" }
	load_window_plugin(t)
	t:tick(2)
	local term = fake_pane("terminal")
	local kube = t.widget_for("kube", term)
	assert(kube ~= nil and kube.text == "⎈ talos-default", "kube on a terminal: " .. tostring(kube and kube.text))
	equal(kube.title, "Kube: talos-default", "kube tooltip")
	equal(kube.command, "plugin.tern-statusline.detail", "kube clicks through to detail")
	assert(t.widget_for("aws", term) ~= nil, "aws on a terminal")
	for _, id in { "provider", "usage", "context", "budget", "cost" } do
		assert(t.widget_for(id, term) == nil, id .. " hides on a plain terminal")
	end
end)

test("usage, context and cost hide on an ACP pane", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "Opus 5.5", state = "working", cwd = "/tmp", program = "tern'", running = { line = ACP_LINE, ms = 1 } } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/tmp")
	load_window_plugin(t)
	t:tick(2)
	for _, id in { "usage", "cost", "context" } do
		assert(t.widget_for(id, fake_pane()) == nil, id .. " hides on ACP")
	end
	local provider = t.widget_for("provider", fake_pane())
	assert(provider ~= nil and provider.text == "claude", "provider names the ACP agent")
end)

test("inapplicable = compact shows the muted compact icon on an ACP pane", function()
	local t = fake_tern()
	t.kv.store["config"] = { segments = { usage = { inapplicable = "compact" }, cost = { inapplicable = "compact", compactIcon = "$" } } }
	t.agents.blocks = { { pane = 7, model = "Opus 5.5", state = "working", cwd = "/tmp", program = "tern'", running = { line = ACP_LINE, ms = 1 } } }
	load_window_plugin(t)
	t:tick(2)
	local usage = t.widget_for("usage", fake_pane())
	assert(usage ~= nil, "usage stays as a placeholder")
	equal(usage.text, "󰊚", "default compact icon")
	equal(usage.tone, "muted", "placeholder is muted")
	equal(usage.title, "Usage", "placeholder tooltip is the segment name")
	local cost = t.widget_for("cost", fake_pane())
	equal(cost and cost.text, "$", "configured compactIcon")
	assert(t.widget_for("context", fake_pane()) == nil, "default inapplicable still hides")
end)

test("bad widget config values fall back to defaults", function()
	local t = fake_tern()
	t.kv.store["config"] = { segments = { usage = { inapplicable = "shrink", compact = "yes", compactIcon = 3 } } }
	t.agents.blocks = { { pane = 7, model = "Opus 5.5", state = "working", cwd = "/tmp", program = "tern'", running = { line = ACP_LINE, ms = 1 } } }
	load_window_plugin(t)
	t:tick(2)
	assert(t.widget_for("usage", fake_pane()) == nil, "unknown inapplicable falls back to hide")
end)

test("compact = true renders each segment's short form", function()
	local t = fake_tern()
	t.kv.store["config"] = { segments = {
		usage = { compact = true }, kube = { compact = true },
		cost = { compact = true }, context = { compact = true },
	} }
	t.agents.blocks = { { pane = 7, model = "glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 77, reset = "1h" }, { label = "7D", pct = 90 } }, false, "/tmp")
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	load_window_plugin(t)
	t:tick(2)
	local usage = t.widget_for("usage", fake_pane())
	equal(usage and usage.text, "󰊚 77%", "usage: icon and the lowest share left")
	assert(math.abs((usage.value :: number) - 0.77) < 1e-9, "usage fill is the share left")
	assert(usage.tone ~= "error" and usage.tone ~= "warn", "77% left is healthy, not tinted: " .. tostring(usage.tone))
	local kube = t.widget_for("kube", fake_pane())
	equal(kube and kube.text, "⎈", "kube: glyph only")
	equal(kube.title, "Kube: talos-default", "the value moves to the tooltip")
	equal((t.widget_for("cost", fake_pane()) :: any).text, "󰔛 $1.20", "cost: spend, no average")
	local context = t.widget_for("context", fake_pane())
	equal(context and context.text, "󰆧 42%", "context: percent")
	equal(context.value, 0.42, "context fill")
end)

test("budget widget shows only when the provider is aihub", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "zai/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.fetch_answers[1] = { status = 200, body = t.json._encode({ daily_budget = { spent_usd = 50, limit_usd = 200 } }) }
	t.fetch_answers[2] = t.fetch_answers[1]
	load_window_plugin(t)
	t:tick(2)
	assert(t.widget_for("budget", fake_pane()) == nil, "budget hides under zai")
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t:tick(2)
	local budget = t.widget_for("budget", fake_pane())
	assert(budget ~= nil, "budget shows under aihub")
	equal(budget.text, "󰆼 $50/$200", "budget text")
	equal(budget.value, 0.25, "budget fill is spent/limit")
	assert(t.widget_for("budget", fake_pane("terminal")) == nil, "no budget on plain terminals")
end)

test("a data change redraws the widgets from the callback", function()
	local t = fake_tern()
	load_window_plugin(t)
	t:tick(1)
	local before = t.refreshes
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	t:tick(1)
	assert(t.refreshes > before, "rebuild asked Tern to redraw")
	equal((t.widget_for("kube", fake_pane()) :: any).text, "⎈ talos-default", "new view served")
end)

test("renders the provider from the agent list", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("aihub", 1, true) ~= nil, "provider text shows: " .. joined)
	assert(joined:find("glm%-5%.3%-flash", 1, false) == nil, "model id stays hidden: " .. joined)
end)

test("ACP agents show their own name, no omp widgets", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "Opus 5.5", state = "working", cwd = "/tmp", program = "tern'", running = { line = "'/Applications/Tern.app/Contents/MacOS/tern' acp --resume 'claude:abc'", ms = 1 } } }
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("claude", 1, true) ~= nil, "acp provider shows: " .. joined)
	assert(joined:find("aihub", 1, true) == nil, "no aihub on acp: " .. joined)
	assert(t.widget_for("cost", fake_pane()) == nil, "no cost on acp")
end)

test("a fresh cache's modelProvider beats the agent block's spawn-time model", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/tmp")
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("zai", 1, true) ~= nil, "live provider shows after a /model switch: " .. joined)
	assert(joined:find("ZAI 5H", 1, true) ~= nil, "usage follows the live provider too: " .. joined)
end)

test("a fresh cache from another cwd doesn't hijack the focused pane", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/elsewhere")
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("aihub", 1, true) ~= nil, "agent's own model shows when the writer is elsewhere: " .. joined)
	assert(joined:find("ZAI 5H", 1, true) == nil, "another writer's usage windows stay hidden: " .. joined)
end)

test("an old-shape cache doc without a cwd is hidden, not applied", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	-- a doc with no cwd cannot be scoped to any project (pre-cwd extension); hiding it is the
	-- only safe choice, so the agent block's own model decides
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, nil)
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("aihub", 1, true) ~= nil, "agent's own model shows over an unscoped cache: " .. joined)
	assert(joined:find("ZAI 5H", 1, true) == nil, "unscoped usage windows stay hidden: " .. joined)
end)

test("switching focus swaps which project's cache applies", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/tmp")
	t.reads["/home/test/.omp/cache/statusline/%2Fother.json"] = cache_fixture(t, { { label = "1D", pct = 20 } }, true, "/other")
	t:tick(2)
	assert(joined_for(t):find("ZAI 5H", 1, true) ~= nil, "the tmp project's windows show at first: " .. joined_for(t))
	-- focus moves to the other project: the next agent poll targets its file
	t.agents.blocks = { { pane = 9, model = "zai/glm-5.3-flash", state = "working", cwd = "/other" } }
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("ZAI 1D", 1, true) ~= nil, "the other project's windows follow focus: " .. joined)
	assert(joined:find("ZAI 5H", 1, true) == nil, "the first project's windows are gone: " .. joined)
end)

test("a stale cache keeps the agent block's model", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, false, "/tmp")
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("aihub", 1, true) ~= nil, "spawn-time model shows when the cache is old: " .. joined)
	assert(joined:find("ZAI 5H", 1, true) == nil, "stale cache must not drive usage bars: " .. joined)
end)

test("provider falls back to the cache's modelProvider on a bare or missing model", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, {}, false, "/tmp")
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("zai", 1, true) ~= nil, "cache provider shows for bare model: " .. joined)

	local t2 = fake_tern()
	t2.agents.blocks = { { pane = 7, state = "working", cwd = "/tmp" } }
	t2.reads[CACHE_PATH] = cache_fixture(t2, {}, false, "/tmp")
	load_window_plugin(t2)
	t2:tick(2)
	local joined2 = joined_for(t2)
	assert(joined2:find("zai", 1, true) ~= nil, "cache provider shows without a model: " .. joined2)
end)

test("usage bars hide when the active provider has no quota windows", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90, reset = "4h" } }, false, "/tmp")
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("ZAI", 1, true) == nil, "usage bars stay zai-scoped on aihub: " .. joined)
end)

test("usage segment draws the cache's windows with share and countdown", function()
	local t = fake_tern()
	-- the scoped read needs a focused agent; a bare model lets the stale rung supply zai
	t.agents.blocks = { { pane = 7, model = "glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90, reset = "4h" } }, false, "/tmp")
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("ZAI 5H", 1, true) ~= nil, "provider label shows: " .. joined)
	assert(joined:find("90%% left", 1, false) ~= nil, "share shows: " .. joined)
	assert(joined:find("4h", 1, true) ~= nil, "countdown shows: " .. joined)
end)

test("usage share reads remainingFraction from amount (omp's real shape)", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	-- the shape `omp usage --json` emits: the share lives under `amount`
	t.reads[CACHE_PATH] = t.json._encode({
		generatedAt = 1_000_000,
		providers = {
			{
				id = "zai",
				label = "ZAI",
				windows = { { label = "5 Hours", pct = 56, reset = "3h" } },
			},
		},
		modelProvider = "zai",
		cwd = "/tmp",
	})
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("ZAI 5 Hours", 1, true) ~= nil, "provider label shows: " .. joined)
	assert(joined:find("56%% left", 1, false) ~= nil, "share shows: " .. joined)
	assert(joined:find("3h", 1, true) ~= nil, "countdown shows: " .. joined)
end)

test("usage bar respects configured barGlyphs", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t.kv.store["config"] = { segments = { usage = { barGlyphs = 4 } } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 50 } }, false, "/tmp")
	t:tick(3)
	-- the meter is the token between the window label and the share; count its codepoints
	local meter = joined_for(t):match("%s(%S+) %d+%%") or ""
	local glyphs = 0
	for _ in meter:gmatch("[^\128-\191]") do
		glyphs += 1
	end
	equal(glyphs, 4, "meter width is barGlyphs total: bars, tip dot, track")
end)

test("config round-trips through kv with unknown values falling back", function()
	local t = fake_tern()
	load_window_plugin(t)
	-- the kv mirror may carry a stale prefix from an earlier run (the poller mirrors the file only
	-- when it changed); the legacy bar must still render with the old prefix present
	t.kv.store["config"] = { statusSegments = true, prefix = "▍", segments = { usage = { color = "electric" } } }
	t:tick(2)
	local segments = t.status_for(fake_pane())
	assert(type(segments) == "table", "valid config still renders")
	-- unknown color fell back (no error, no crash) and the literal prefix is present
	local first = segments[1]
	assert(first ~= nil, "prefix segment renders")
	equal(first.text, "▍", "literal prefix accepted")
end)

test("budget renders from the gateway with thresholds", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t.fetch_answers[1] = {
		status = 200,
		body = t.json._encode({ daily_budget = { spent_usd = 12, limit_usd = 200 } }),
	}
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("$12/$200", 1, true) ~= nil, "budget text: " .. joined)
	-- each tick fires the cadence twice, so both rounds answer over-threshold spend
	t.fetch_answers[3] = {
		status = 200,
		body = t.json._encode({ daily_budget = { spent_usd = 160, limit_usd = 200 } }),
	}
	t.fetch_answers[4] = t.fetch_answers[3]
	t:tick(2)
	local budget = t.widget_for("budget", fake_pane())
	equal(budget and budget.tone, "error", "over 75% spend reads error")
end)

test("kube applies strip patterns from config", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.kv.store["config"] = { segments = { kube = { strip = { "^arn:aws:eks:[^:]+:[0-9]+:cluster/" } } } }
	-- each tick fires all process pollers; answer the kube poller every round with the arn
	t.process_answers["kube"] = { status = 0, stdout = "arn:aws:eks:us-east-1:123:cluster/talos-default\n" }
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("⎈ talos%-default", 1, false) ~= nil, "arn prefix stripped: " .. joined)
end)

test("kube follows the session's env through the fresh cache", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.kv.store["config"] = { segments = { kube = { strip = { "^arn:aws:eks:[^:]+:[0-9]+:cluster/" } } } }
	-- the extension resolves kubectl inside omp (KUBECONFIG visible); Tern's own poller only
	-- ever sees Tern's env, so its answer must lose when the cache carries a value
	t.reads[CACHE_PATH] = t.json._encode({
		generatedAt = os.time() * 1000,
		providers = {},
		modelProvider = "aihub",
		cwd = "/tmp",
		kube = "arn:aws:eks:us-east-1:123:cluster/talos-default",
	})
	t.process_answers["kube"] = { status = 0, stdout = "arn:aws:eks:us-east-1:123:cluster/from-poller\n" }
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("⎈ talos%-default", 1, false) ~= nil, "session-resolved kube wins: " .. joined)
	assert(joined:find("from%-poller", 1, false) == nil, "Tern's env-blind poll loses: " .. joined)
end)

test("a fresh cache without kube still lets the poller fill in", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	-- fresh, same cwd, but the extension predates the kube field
	t.reads[CACHE_PATH] = cache_fixture(t, {}, true, "/tmp")
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	load_window_plugin(t)
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("⎈ talos%-default", 1, false) ~= nil, "poller fills in when the cache has no kube: " .. joined)
end)

test("aws renders the fish-captured profile from the snapshot", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.process_answers["aws"] = { status = 0, stdout = "nsx\n" }
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("☁ nsx", 1, true) ~= nil, "aws profile shows: " .. joined)
end)

test("config file lands in kv through the docs poller", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.reads["/home/test/.config/tern-statusline/config.json"] = t.json._encode({ prefix = "▍" })
	t:tick(2)
	assert(t.kv.store["config"] ~= nil, "file content mirrored into kv")
	equal((t.kv.store["config"] :: any).prefix, "▍", "prefix came from the file")
end)

test("a widget click toggles the floating card open and closed", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "zai/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/tmp")
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	load_both(t)
	t:focus(fake_pane())
	t:tick(2)
	local view = t.widget_for("kube", fake_pane())
	equal(view and view.command, "plugin.tern-statusline.detail", "a widget click runs the toggle")
	assert(t.card() == nil, "no card before the click")

	t.commands["detail"](fake_window_cx(t))
	local pane = t.card()
	assert(pane ~= nil, "the click opened a card block")
	equal(t.panes[pane].block, "tern-statusline.card", "the card is the host block")
	assert(t.panes[pane].floating, "the card floats")
	equal(t.floats[pane].corner, "tr", "top-right corner")
	equal(t.floats[pane].over, 7, "over the focused pane")
	assert(type(t.kv.store["card"]) == "table", "the window mirrored the card model")
	assert(find_key(t.card_view(), "kube") ~= nil, "the first frame already has data")

	t.commands["detail"](fake_window_cx(t))
	assert(t.card() == nil, "the second click closed it")
	assert(t.panes[pane] == nil, "its pane is gone")
end)

test("the card draws a meter row per usage window", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "zai/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, {
		{ label = "5H", pct = 90, reset = "1h 40m" },
		{ label = "7D", pct = 82, reset = "4d 4h", saved = 2 },
	}, true, "/tmp")
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	t.process_answers["aws"] = { status = 0, stdout = "nsx\n" }
	load_both(t)
	t:focus(fake_pane())
	t:tick(2)
	t.commands["detail"](fake_window_cx(t))
	local main = t.card_view()
	local rows = keys_with(main, "w:")
	equal(table.concat(rows, ","), "w:5H,w:7D", "one row per window")
	for _, key in rows do
		assert(has_kind(find_key(main, key), "meter"), key .. " draws a bar")
	end
	equal(text_of(find_key(main, "w:7D")), "7D 82% left 4d 4h +2", "label, value, reset, saved")
	local chip = find_key(main, "btn:tab=zai")
	assert(chip ~= nil, "a provider chip per cached provider")
	equal(chip.p.tone, "accent", "the active provider is highlighted")
	assert(has_kind(find_key(main, "ctx"), "meter"), "context draws a bar")
	equal(text_of(find_key(main, "cost")), "cost $1.20 · ~$0.40/msg · 3 msgs", "session cost and average")
	equal(text_of(find_key(main, "kube")), "kube ⎈ talos-default", "kube row")
	equal(text_of(find_key(main, "aws")), "aws ☁ nsx", "aws row")
	assert(find_key(main, "btn:refresh") ~= nil and find_key(main, "btn:edit") ~= nil, "toolbar")
	assert(find_key(main, "foot") ~= nil, "updated footer")
	assert(not text_of(main):find("/config.json", 1, true), "no raw config path row")
end)

test("omp-only card rows are absent on an ACP pane", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 9, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/tmp")
	t.fetch_answers[1] = { status = 200, body = t.json._encode({ daily_budget = { spent_usd = 12, limit_usd = 200 } }) }
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	t.process_answers["aws"] = { status = 0, stdout = "nsx\n" }
	load_both(t)
	local acp = { pane = 12, kind = "agent", program = "c", running = { line = "c", ms = 1 }, busy = false, cwd = "/tmp", title = "c" }
	t:focus(acp)
	t:tick(2)
	t.commands["detail"](fake_window_cx(t))
	local main = t.card_view()
	equal(#keys_with(main, "w:"), 0, "no usage windows")
	equal(#keys_with(main, "btn:tab="), 0, "no provider tabs")
	for _, key in { "ctx", "cost", "budget" } do
		assert(find_key(main, key) == nil, key .. " hides on the ACP pane")
	end
	equal(text_of(find_key(main, "chip:provider")), "claude", "the ACP agent's provider")
	assert(find_key(main, "kube") ~= nil and find_key(main, "aws") ~= nil, "kube and aws apply everywhere")
end)

test("the open card follows focus and redraws when data changes", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "zai/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/tmp")
	load_both(t)
	t:focus(fake_pane())
	t:tick(2)
	t.commands["detail"](fake_window_cx(t))
	local pane, entry = t.card()
	equal(text_of(find_key(t.card_view(), "w:5H")), "5H 90% left", "first value")

	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 40 } }, true, "/tmp")
	local renders = entry.cx.renders
	t:tick(2)
	assert(entry.cx.renders > renders, "the host re-rendered the open card")
	equal(text_of(find_key(t.card_view(), "w:5H")), "5H 40% left", "new value")

	-- clicking the card focuses it; it keeps describing the agent pane
	t:focus(t.panes[pane :: number])
	t:tick(2)
	assert(find_key(t.card_view(), "w:5H") ~= nil, "focusing the card keeps the agent's rows")

	t:focus(claude_cli_pane())
	t:tick(2)
	equal(#keys_with(t.card_view(), "w:"), 0, "a claude CLI pane drops the omp rows")
	equal(text_of(find_key(t.card_view(), "chip:provider")), "claude", "and shows its provider")
end)

test("the card's refresh re-runs the pollers and edit opens the config file", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "zai/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_both(t)
	t:focus(fake_pane())
	t:tick(2)
	t.commands["detail"](fake_window_cx(t))
	local before = t.fetches
	t:tick(1)
	local baseline = t.fetches - before
	t.card_event("refresh")
	equal(t.kv.store["card_refresh"], 1, "refresh request filed in kv")
	before = t.fetches
	t:tick(1)
	equal(t.fetches - before, baseline + 1, "the window re-polled the gateway at once")
	t.card_event("edit")
	equal(t.opened[1], "/home/test/.config/tern-statusline/config.json", "edit opens the config file")
end)

test("focusing agent B shows B's data right after the focus event, no tick", function()
	local t = fake_tern()
	t.agents.blocks = {
		{ pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" },
		{ pane = 9, model = "zai/glm-5.3-flash", state = "working", cwd = "/other" },
	}
	t.reads["/home/test/.omp/cache/statusline/%2Fother.json"] = cache_fixture(t, { { label = "1D", pct = 20 } }, true, "/other")
	load_window_plugin(t)
	t:focus(fake_pane("agent", 7))
	t:tick(2)
	equal((t.widget_for("provider", fake_pane("agent", 7)) :: any).text, "aihub", "A's provider first")
	t:focus(fake_pane("agent", 9))
	local b = fake_pane("agent", 9)
	equal((t.widget_for("provider", b) :: any).text, "zai", "B's provider on the first frame")
	local joined = joined_for(t, b)
	assert(joined:find("ZAI 1D", 1, true) ~= nil, "B's project cache was read on focus: " .. joined)
end)

test("focusing agent B from a claude CLI pane drops the claude ACP state", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 9, model = "zai/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t:focus(claude_cli_pane())
	equal((t.widget_for("provider", claude_cli_pane()) :: any).text, "claude", "cli reads claude")
	t:focus(fake_pane("agent", 9))
	local b = fake_pane("agent", 9)
	equal((t.widget_for("provider", b) :: any).text, "zai", "B's own provider, not claude")
end)

test("missing tern.chrome.widget falls back to the status formatter", function()
	local t = fake_tern()
	t.chrome.widget = nil
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t:tick(2)
	local segments = t.status_for(fake_pane())
	assert(type(segments) == "table" and #segments > 0, "legacy bar takes over without statusSegments")
	assert(#t.log_lines > 0, "the fallback is logged")
end)

test("a widget registration that raises also falls back", function()
	local t = fake_tern()
	t.chrome.widget = function(_id: string, _spec: any) error("unknown style") end
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t:tick(2)
	local segments = t.status_for(fake_pane())
	assert(type(segments) == "table" and #segments > 0, "legacy bar takes over")
end)

test("the card toggle registers the ctrl+alt+s chord", function()
	local t = fake_tern()
	load_window_plugin(t)
	local def = t.command_defs["detail"]
	assert(def ~= nil, "detail command registered")
	equal(def.keys and def.keys[1], "ctrl+alt+s", "default chord")
end)

test("kube and aws pollers honor refreshMs and timeoutMs", function()
	local t = fake_tern()
	t.kv.store["config"] = { segments = { kube = { refreshMs = 20000, timeoutMs = 2000 }, aws = { refreshMs = 45000, timeoutMs = 3000 } } }
	load_window_plugin(t)
	t:tick(1)
	equal(t.process_opts.kube.timeout_ms, 2000, "kube timeout")
	equal(t.process_opts.aws.timeout_ms, 3000, "aws timeout")
	local seen: { [number]: boolean } = {}
	for _, handle in t.timers do
		seen[handle.ms] = true
	end
	assert(seen[20000], "kube reschedules on its refreshMs")
	assert(seen[45000], "aws reschedules on its refreshMs")
end)

test("a leftover memory section in the config is ignored", function()
	local t = fake_tern()
	t.kv.store["config"] = { order = { "memory", "kube" }, statusSegments = true, segments = { memory = { compact = true, refreshMs = 5000 } } }
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	load_window_plugin(t)
	t:tick(2)
	assert(t.widgets["memory"] == nil, "no memory widget")
	local texts: { string } = {}
	for _, segment in t.status_for(fake_pane()) do
		table.insert(texts, segment.text)
	end
	equal(table.concat(texts, " "), "⎈ talos-default", "unknown order entries drop")
end)

test("budget never shows on a claude CLI pane", function()
	local t = fake_tern()
	t.fetch_answers[1] = { status = 200, body = t.json._encode({ daily_budget = { spent_usd = 50, limit_usd = 200 } }) }
	load_window_plugin(t)
	t:tick(2)
	assert(t.widget_for("budget", claude_cli_pane()) == nil, "no budget on the cli")
end)

test("a leftover indicator section in the config is ignored", function()
	local t = fake_tern()
	t.kv.store["config"] = { order = { "indicator", "kube" }, statusSegments = true, segments = { indicator = { icons = { ready = "R" }, compact = true } } }
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.process_answers["kube"] = { status = 0, stdout = "talos-default\n" }
	load_window_plugin(t)
	t:tick(2)
	assert(t.widgets["indicator"] == nil, "no indicator widget")
	local texts: { string } = {}
	for _, segment in t.status_for(fake_pane()) do
		table.insert(texts, segment.text)
	end
	equal(table.concat(texts, " "), "⎈ talos-default", "unknown order entries drop")
end)

test("an ACP agent pane from the c alias reads claude without a matching agent block", function()
	local t = fake_tern()
	-- agents:list yields only an unrelated omp block; the focused pane is the `c` ACP agent
	t.agents.blocks = { { pane = 9, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	t.reads[CACHE_PATH] = cache_fixture(t, { { label = "5H", pct = 90 } }, true, "/tmp")
	load_window_plugin(t)
	local acp = { pane = 12, kind = "agent", program = "c", running = { line = "c", ms = 1 }, busy = false, cwd = "/tmp", title = "c" }
	t:focus(acp)
	t:tick(2)
	local provider = t.widget_for("provider", acp)
	equal(provider and provider.text, "claude", "provider names the ACP agent")
	for _, id in { "usage", "cost", "context", "budget" } do
		assert(t.widget_for(id, acp) == nil, id .. " hides on the ACP pane")
	end
end)

return cases
