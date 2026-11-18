--!strict
-- omp Statusline — host half: block `tern-statusline.card`, the floating detail card.
--
-- Tern lets only the host half define blocks, while every statusline value lives in the window
-- VM (agents, the omp cache, pollers). So the window builds the card model for the focused pane
-- (applicability already decided: omp-only rows are absent on ACP and claude CLI panes) and
-- mirrors it into kv "card"; this half draws it. A 1 s kv watch re-renders open cards when the
-- model's `rev` moves. Toolbar: refresh bumps kv "card_refresh" (the window re-runs its pollers),
-- edit opens the config file. Provider tabs only change what this card shows.
--
-- The toggle (click a widget, the palette command, ctrl+alt+s) lives in the window half.

local ui = tern.ui

type State = { cx: BlockCx, sel: string? }

local WATCH_MS = 1000

-- Open cards by pane; a card whose render raises (its pane went) drops out.
local open: { [number]: State } = {}
local model: any = nil
local seen_rev: any = nil
local seen_updated: any = nil
local watching = false

local function read_model(): boolean
	local ok, m = pcall(tern.kv.get, "card")
	if not ok or type(m) ~= "table" then
		return false
	end
	if model ~= nil and m.rev == seen_rev and m.updated == seen_updated then
		return false
	end
	model = m
	seen_rev = m.rev
	seen_updated = m.updated
	return true
end

local function watch()
	if read_model() then
		for pane, st in open do
			local ok = pcall(function()
				st.cx:render()
			end)
			if not ok then
				open[pane] = nil
			end
		end
	end
	if next(open) ~= nil then
		tern.timer(WATCH_MS, watch)
	else
		watching = false
	end
end

local function start_watch()
	if not watching then
		watching = true
		tern.timer(WATCH_MS, watch)
	end
end

-- ── view helpers ──

local function line(spans: { Span }, props: { [string]: any }?): Node
	local p: { [string]: any } = { spans = spans, truncate = "end" }
	for k, v in props or {} do
		p[k] = v
	end
	return ui.node("text", p)
end

local function button(text: string, tone: string, action: string, title: string?): Node
	local node = ui.badge(text, tone)
	local p: { [string]: any } = node.p or {}
	p.actions = { click = action }
	p.key = "btn:" .. action
	p.title = title
	p.basis = "content"
	node.p = p
	return node
end

local LABEL_W = "8ch"

local function label(text: string, title: string?): Node
	return line({ ui.span(text, "muted") }, { min = { w = LABEL_W }, max = { w = LABEL_W }, basis = "content", key = "label", title = title })
end

local function usd(value: number): string
	if value >= 100 then
		return string.format("$%.0f", value)
	end
	return (string.format("$%.2f", value):gsub("%.?0+$", ""))
end

-- Tone of a "used" value (context, budget share): strictly above warn, then bad.
local function used_tone(value: number?, warn: number?, bad: number?): string
	if value == nil then
		return ""
	end
	if bad and value > bad then
		return "error"
	end
	if warn and value > warn then
		return "warning"
	end
	return ""
end

-- Tone of a "left" share (usage windows): at or below warn, then bad.
local function left_tone(pct: number, warn: number?, bad: number?): string
	if bad and pct <= bad then
		return "error"
	end
	if warn and pct <= warn then
		return "warning"
	end
	return ""
end

-- `7D ━━━━─── 82% left 4d 4h`: label, the drawn bar (consumed share), the value, a muted tail.
local function meter_row(key: string, name: string, value: number, thresholds: { warn: number, bad: number }?, text: string, tone: string, tail: string?, title: string?): Node
	local children: { Node } = {
		label(name, title),
		ui.node("meter", { value = math.clamp(value, 0, 1), thresholds = thresholds, size = "sm", grow = 1, key = "bar", title = title }),
		line({ ui.span(text, "num" .. (if tone ~= "" then " " .. tone else "")) }, { min = { w = "9ch" }, basis = "content", key = "value" }),
	}
	if tail and tail ~= "" then
		table.insert(children, line({ ui.span(tail, "muted") }, { min = { w = "7ch" }, basis = "content", key = "tail" }))
	end
	return ui.node("row", { gap = "sm", key = key }, children)
end

local function value_row(key: string, name: string, spans: { Span }): Node
	return ui.node("row", { gap = "sm", key = key }, {
		label(name),
		line(spans, { grow = 1, min = { w = 0 }, key = "value" }),
	})
end

-- Thresholds on the consumed share for a "left" window: warnAt 25% left tints at 75% used.
local function left_thresholds(warn: number?, bad: number?): { warn: number, bad: number }?
	if warn == nil or bad == nil then
		return nil
	end
	return { warn = 1 - warn / 100, bad = 1 - bad / 100 }
end

local function used_thresholds(warn: number?, bad: number?): { warn: number, bad: number }?
	if warn == nil or bad == nil then
		return nil
	end
	return { warn = warn / 100, bad = bad / 100 }
end

local function selected_provider(st: State, m: any): any
	local providers = m.providers or {}
	local want = st.sel or m.active
	for _, p in providers do
		if p.id == want then
			return p
		end
	end
	if st.sel == nil and m.active ~= nil then
		return nil -- the active provider has no quota windows at all
	end
	return providers[1]
end

local function head(st: State, m: any): Node
	local children: { Node } = {}
	local shown = selected_provider(st, m)
	local providers = m.providers or {}
	if #providers > 0 then
		for _, p in providers do
			local text = (if p.id == m.active then "● " else "") .. p.label
			local tone = if shown and p.id == shown.id then "accent" else "neutral"
			table.insert(children, button(text, tone, "tab=" .. p.id, if p.id == m.active then p.label .. " · the active model's provider" else p.label))
		end
	elseif m.provider then
		local chip = ui.badge(m.provider, "accent")
		chip.p = chip.p or {}
		;(chip.p :: any).key = "chip:provider"
		table.insert(children, chip)
	end
	table.insert(children, line({ ui.span(m.model or "", "muted") }, { grow = 1, min = { w = 0 }, key = "model", title = m.model }))
	table.insert(children, button("↻", "neutral", "refresh", "r · refresh now"))
	table.insert(children, button("✎ config", "neutral", "edit", if m.path then "e · open " .. m.path else "e · open the config file"))
	return ui.node("row", { gap = "sm", key = "head" }, children)
end

local function rows(st: State, m: any): { Node }
	local out: { Node } = {}
	local usage = m.usage or {}
	local shown = selected_provider(st, m)
	if shown then
		if #shown.windows == 0 then
			table.insert(out, line({ ui.span(shown.label .. " has no quota windows", "dim") }, { key = "w:none" }))
		end
		for _, w in shown.windows do
			local tail = w.reset or ""
			if w.saved and w.saved > 0 then
				tail ..= string.format(" +%d", w.saved)
			end
			local title = string.format("%s %s: %d%% left", shown.label, w.label, w.pct) .. (if w.reset then " · resets in " .. w.reset else "")
			table.insert(out, meter_row("w:" .. w.label, w.label, 1 - w.pct / 100, left_thresholds(usage.warn, usage.bad), string.format("%d%% left", w.pct), left_tone(w.pct, usage.warn, usage.bad), tail, title))
		end
	elseif m.active then
		table.insert(out, line({ ui.span(m.active .. " has no quota windows", "dim") }, { key = "w:none" }))
	end
	if m.context then
		local c = m.context
		local pct = math.floor(c.pct + 0.5)
		table.insert(out, meter_row("ctx", "context", c.pct / 100, used_thresholds(c.warn, c.bad), string.format("%d%%", pct), used_tone(c.pct, c.warn, c.bad), nil, string.format("Context: %d%% used", pct)))
	end
	if m.budget then
		local b = m.budget
		local text = usd(b.spent) .. (if b.limit then "/" .. usd(b.limit) else "")
		if b.limit and b.limit > 0 then
			local share = b.spent / b.limit
			table.insert(out, meter_row("budget", "budget", share, used_thresholds(b.warn, b.bad), text, used_tone(share * 100, b.warn, b.bad), "today", "AI Hub spend today"))
		else
			table.insert(out, value_row("budget", "budget", { ui.span(text, "num"), ui.span(" today", "muted") }))
		end
	end
	if m.cost then
		local spans: { Span } = { ui.span(m.cost.total, "num") }
		if m.cost.avg then
			table.insert(spans, ui.span(" · ~" .. m.cost.avg .. "/msg", "muted"))
		end
		if m.cost.turns then
			table.insert(spans, ui.span(string.format(" · %d msgs", m.cost.turns), "dim"))
		end
		table.insert(out, value_row("cost", "cost", spans))
	end
	if m.kube then
		table.insert(out, value_row("kube", "kube", { ui.span("⎈ " .. m.kube, "success") }))
	end
	if m.aws then
		table.insert(out, value_row("aws", "aws", { ui.span("☁ " .. m.aws, "warning") }))
	end
	return out
end

local function render(st: State, _cx: BlockCx): BlockView
	local m = model
	if m == nil then
		return { main = ui.col({ line({ ui.span("Waiting for the statusline…", "muted") }, { key = "empty" }) }) }
	end
	local main: { Node } = { head(st, m), ui.rule("") }
	local body = rows(st, m)
	if #body == 0 then
		table.insert(main, line({ ui.span("Nothing to show for this pane", "dim") }, { key = "none" }))
	end
	for _, node in body do
		table.insert(main, node)
	end
	if type(m.updated) == "number" and m.updated > 0 then
		local age = math.max(0, os.time() * 1000 - m.updated)
		table.insert(main, ui.node("row", { gap = "xs", key = "foot" }, {
			line({ ui.span("updated", "dim") }, { basis = "content" }),
			ui.node("elapsed", { age = age, format = "short" }),
			line({ ui.span("ago", "dim") }, { basis = "content" }),
		}))
	end
	return { main = ui.col(main) }
end

-- ── actions ──

local function refresh(st: State)
	local ok, current = pcall(tern.kv.get, "card_refresh")
	local n = if ok and type(current) == "number" then current else 0
	pcall(tern.kv.set, "card_refresh", n + 1)
	read_model()
	st.cx:render()
end

local function edit(st: State)
	local m = model
	if m and type(m.path) == "string" and m.path ~= "" then
		st.cx:open(m.path)
	else
		st.cx:toast("error", "omp Statusline: no config path", "set HOME or TERN_STATUSLINE_CONFIG")
	end
end

local function next_tab(st: State)
	local m = model
	local providers = (m and m.providers) or {}
	if #providers == 0 then
		return
	end
	local shown = m and selected_provider(st, m)
	local idx = 0
	for i, p in providers do
		if shown and p.id == shown.id then
			idx = i
		end
	end
	st.sel = providers[idx % #providers + 1].id
end

local card_block: BlockDef<State> = {
	init = function(cx, _args, _saved)
		local st: State = { cx = cx, sel = nil }
		open[cx.pane] = st
		read_model()
		start_watch()
		return st
	end,

	title = function(_st)
		return "omp Statusline"
	end,

	view = render,

	key = function(st, key, _cx)
		if key.name == "r" then
			refresh(st)
		elseif key.name == "e" then
			edit(st)
		elseif key.name == "tab" then
			next_tab(st)
		else
			return false
		end
		return true
	end,

	event = function(st, ev, _cx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "tab" and type(ev.value) == "string" then
			st.sel = ev.value
		elseif ev.act == "refresh" then
			refresh(st)
		elseif ev.act == "edit" then
			edit(st)
		end
	end,
}

tern.block.define("card", card_block)
