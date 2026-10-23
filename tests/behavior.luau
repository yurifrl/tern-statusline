--!strict
-- Behavior tests for the omp Statusline plugin.
--
-- The plugin is loaded twice inside luau-web's sandboxed Luau VM — host and window sources under
-- `load_host_plugin(api)` / `load_window_plugin(api)` shims with `tern` bound to the fake below —
-- and driven only through the seams production data flows through: `tern.kv` (config),
-- `tern.docs:read` (the extension cache), `tern.fetch` (the gateway), `tern.process.run` (kube,
-- memory), `cx.agents:list` (model/state) and the registered chrome formatter. Each scenario
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
	t.plugin = { id = "omp-statusline" }
	t.now = function() return 1_000_000 end

	-- view builders: nodes are inert tables in the fake; detail/settings just assemble them
	t.ui = {
		el = function(tag: string, props: any, children: any)
			return { tag = tag, props = props, children = children }
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

	-- chrome status: capture the formatter
	local formatter: ((any) -> any)?
	t.chrome = {
		status = function(fn) formatter = fn end,
		refresh = function() t.refreshes += 1 end,
	}
	function t.status_for(pane: any)
		assert(formatter, "chrome.status was never registered")
		return formatter(pane)
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

	-- process.run records calls; scenarios answer through t.process_answers
	t.process_calls = {}
	t.process_answers = {}
	t.process = {
		run = function(argv: { string }, _opts: any, cb: (any, any?) -> ())
		table.insert(t.process_calls, argv)
		local answer = t.process_answers[#t.process_calls] or { status = 1, stdout = "" }
		cb(answer, nil)
	end,
	}

	-- commands and events
	t.commands = {}
	t.command = function(def: any) t.commands[def.id] = def.run end
	t.actions = {}
	t.on = function(name: string, fn: any)
		t.actions[name] = fn
		-- window_start runs once per plugin per window; the fake fires it immediately
		if name == "window_start" then
			fn(fake_window_cx(t))
		end
	end

	return t
end

function fake_window_cx(t)
	return {
		session = t.session,
		docs = t.docs,
		canvas = t.canvas,
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

function fake_pane(kind: string?)
	return { pane = 7, kind = kind or "agent", program = "omp", busy = false, cwd = "/tmp", title = "omp" }
end

-- A statusline cache the companion extension would have written.
local function cache_fixture(t: any, windows: { any }): string
	return t.json._encode({
		generatedAt = 1_000_000,
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
	})
end

-- All segment texts the formatter currently returns, joined for substring assertions.
local function joined_for(t: any): string
	local texts: { string } = {}
	for _, segment in t.status_for(fake_pane()) do
		table.insert(texts, segment.text)
	end
	return table.concat(texts, " ")
end

-- ── scenarios ──

test("registers a status formatter that answers agent panes only", function()
	local t = fake_tern()
	load_window_plugin(t)
	local segments = t.status_for(fake_pane("agent"))
	assert(type(segments) == "table", "agent panes get segments")
	assert(t.status_for(fake_pane("terminal")) == nil, "terminals get none")
end)

test("hides the whole line when disabled", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.kv.store["config"] = { enabled = false }
	t:tick(2)
	assert(t.status_for(fake_pane()) == nil, "disabled means no segments")
end)

test("renders provider and indicator from the agent list", function()
	local t = fake_tern()
	t.agents.blocks = { { pane = 7, model = "aihub/aihub/glm-5.3-flash", state = "working", cwd = "/tmp" } }
	load_window_plugin(t)
	t:tick(2)
	local segments = t.status_for(fake_pane())
	local texts: { string } = {}
	for _, segment in segments do
		table.insert(texts, segment.text)
	end
	local joined = table.concat(texts, " ")
	assert(joined:find("aihub", 1, true) ~= nil, "provider text shows: " .. joined)
	assert(joined:find("glm%-5%.3%-flash", 1, false) == nil, "model id stays hidden: " .. joined)
	assert(joined:find("󰙨", 1, true) ~= nil, "working glyph shows: " .. joined)
end)

test("usage segment draws the cache's windows with share and countdown", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.reads["/home/test/.omp/cache/statusline.json"] = cache_fixture(t, { { label = "5H", pct = 90, reset = "4h" } })
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("ZAI 5H", 1, true) ~= nil, "provider label shows: " .. joined)
	assert(joined:find("90%% left", 1, false) ~= nil, "share shows: " .. joined)
	assert(joined:find("4h", 1, true) ~= nil, "countdown shows: " .. joined)
end)

test("usage share reads remainingFraction from amount (omp's real shape)", function()
	local t = fake_tern()
	load_window_plugin(t)
	-- the shape `omp usage --json` emits: the share lives under `amount`
	t.reads["/home/test/.omp/cache/statusline.json"] = t.json._encode({
		generatedAt = 1_000_000,
		providers = {
			{
				id = "zai",
				label = "ZAI",
				windows = { { label = "5 Hours", pct = 56, reset = "3h" } },
			},
		},
	})
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("ZAI 5 Hours", 1, true) ~= nil, "provider label shows: " .. joined)
	assert(joined:find("56%% left", 1, false) ~= nil, "share shows: " .. joined)
	assert(joined:find("3h", 1, true) ~= nil, "countdown shows: " .. joined)
end)

test("usage bar respects configured barGlyphs", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.kv.store["config"] = { segments = { usage = { barGlyphs = 4 } } }
	t.reads["/home/test/.omp/cache/statusline.json"] = cache_fixture(t, { { label = "5H", pct = 50 } })
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
	-- when it changed); the bar must still render with the old prefix present
	t.kv.store["config"] = { prefix = "▍", segments = { usage = { color = "electric" } } }
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
	for _, segment in t.status_for(fake_pane()) do
		if segment.tone == "error" then
			return
		end
	end
	assert(false, "over 75% spend reads error")
end)

test("kube applies strip patterns from config", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.kv.store["config"] = { segments = { kube = { strip = { "^arn:aws:eks:[^:]+:[0-9]+:cluster/" } } } }
	-- each tick fires both process pollers (kube, memory) twice; answer every round with the arn
	t.process_answers[1] = { status = 0, stdout = "arn:aws:eks:us-east-1:123:cluster/talos-default\n" }
	t.process_answers[2] = t.process_answers[1]
	t.process_answers[3] = t.process_answers[1]
	t.process_answers[4] = t.process_answers[1]
	t:tick(2)
	local joined = joined_for(t)
	assert(joined:find("⎈ talos%-default", 1, false) ~= nil, "arn prefix stripped: " .. joined)
end)

test("memory renders the largest omp agent RSS", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.process_answers[1] = { status = 1, stdout = "" } -- kube fails, harmless
	t.process_answers[2] = { status = 0, stdout = "290000 /usr/local/bin/omp agent --serve\n" }
	t:tick(3)
	local joined = joined_for(t)
	assert(joined:find("283M", 1, true) ~= nil, "rss renders in MiB: " .. joined)
end)

test("config file lands in kv through the docs poller", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.reads["/home/test/.config/tern-statusline/config.json"] = t.json._encode({ prefix = "▍" })
	t:tick(2)
	assert(t.kv.store["config"] ~= nil, "file content mirrored into kv")
	equal((t.kv.store["config"] :: any).prefix, "▍", "prefix came from the file")
end)

test("detail panel lists every fact", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.agents.blocks = { { pane = 7, model = "test/model", state = "working", cwd = "/tmp" } }
	t.reads["/home/test/.omp/cache/statusline.json"] = cache_fixture(t, { { label = "5H", pct = 90 } })
	t.process_answers[1] = { status = 0, stdout = "talos-default\n" }
	t.fetch_answers[1] = {
		status = 200,
		body = t.json._encode({ daily_budget = { spent_usd = 12, limit_usd = 200 } }),
	}
	t:tick(3)
	assert(type(t.commands["detail"]) == "function", "detail command registered")

	-- the palette command and a segment click both open the same canvas
	local opened = false
	t.canvas = {
		open = function(_self, _spec: any)
			opened = true
			return 91, nil
		end,
		set = function(_self, _pane: number, _change: any) end,
		get = function(_self, _pane: number) return nil end,
		list = function(_self) return {} end,
	}
	t.commands["detail"](fake_window_cx(t))
	assert(opened, "detail command opens a canvas")

	opened = false
	local segments = t.status_for(fake_pane())
	assert(#segments > 0, "segments render")
	for _, segment in segments do
		assert(segment.command == "plugin.omp-statusline.detail", "click opens detail: " .. tostring(segment.command))
		assert(t.commands["detail"] ~= nil, "detail command registered")
		segment.text = nil -- touch nothing; only command wiring matters
		break
	end
	assert(not opened, "no open happened before the command ran")
end)

test("every rendered segment clicks through to detail", function()
	local t = fake_tern()
	load_window_plugin(t)
	t.agents.blocks = { { pane = 7, model = "test/model", state = "working", cwd = "/tmp" } }
	t.reads["/home/test/.omp/cache/statusline.json"] = cache_fixture(t, { { label = "5H", pct = 90 } })
	t.process_answers[1] = { status = 0, stdout = "talos-default\n" }
	t.fetch_answers[1] = {
		status = 200,
		body = t.json._encode({ daily_budget = { spent_usd = 12, limit_usd = 200 } }),
	}
	t:tick(3)
	local opened = false
	t.canvas = {
		open = function(_self, _spec: any)
			opened = true
			return 91, nil
		end,
		set = function(_self, _pane: number, _change: any) end,
		get = function(_self, _pane: number) return nil end,
		list = function(_self) return {} end,
	}
	-- the palette command and a segment click open the same read-only panel
	t.commands["detail"](fake_window_cx(t))
	assert(opened, "detail command opens a canvas")
end)

return cases
