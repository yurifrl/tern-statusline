// statusline-cache — companion omp extension for the `tern-statusline` Tern plugin.
//
// The Tern plugin runs outside the omp process, so the data only omp sees (context usage, session
// cost, message count) is written to a cache file it polls. Usage windows per provider come from
// `omp usage --json`, the same reports omp's own usage segment shows; the plugin's settings panel
// can show every provider at once, not just the active one.
//
// Written to ~/.omp/cache/statusline.json on session_start and after every turn:
//   { generatedAt, providers: [{id,label,windows:[{label,pct,reset,saved}]}],
//     contextPct, sessionCost, sessionTurns, modelProvider }
//
// Install: copy or symlink into ~/.omp/agent/extensions/ and restart omp sessions.

import { execFile } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const CACHE_FILE = join(homedir(), ".omp", "cache", "statusline.json");
const USAGE_MS = 60_000;

function ompBin() {
	return process.env.OMP_BIN || process.env.OMP_PATH || "omp";
}

// The GUI Tern process may not carry the user's PATH; the installed omp binary is the fallback.
function ompPaths() {
	return [ompBin(), `${homedir()}/Library/Application Support/Tern/omp/bin/omp`];
}

function fetchUsageJson() {
	const argv = ["usage", "--json"];
	const opts = { timeout: 15_000, maxBuffer: 4 * 1024 * 1024 };
	return new Promise((resolve) => {
		const attempt = (index) => {
			if (index >= ompPaths().length) return resolve(undefined);
			execFile(ompPaths()[index], argv, opts, (err, stdout) => {
				if (err) return attempt(index + 1);
				try {
					const doc = JSON.parse(stdout.toString("utf8"));
					resolve(doc && typeof doc === "object" ? doc : undefined);
				} catch {
					attempt(index + 1);
				}
			});
		};
		attempt(0);
	});
}

// The provider ids the usage report tracks; anything else has no windows to show.
function isTrackedProvider(provider) {
	return typeof provider === "string" && provider.length > 0;
}

// Provider's share left, 0..100, for the windows the report carries.
function windowsFor(limit) {
	const window = limit?.window;
	const label = typeof window?.label === "string" ? window.label : undefined;
	// the report nests shares under `amount` (older drafts had it at the top level)
	const raw = limit?.amount?.remainingFraction ?? limit?.remainingFraction;
	const frac = typeof raw === "number" ? raw : undefined;
	if (!label || frac === undefined) return undefined;
	const pct = Math.max(0, Math.min(100, Math.round(frac * 100)));
	const resetsAt = typeof window?.resetsAt === "number" ? window.resetsAt : undefined;
	const reset = resetsAt !== undefined ? fmtReset(resetsAt - Date.now()) : undefined;
	return { label, pct, reset, saved: 0 };
}

function fmtReset(ms) {
	if (!Number.isFinite(ms) || ms <= 0) return undefined;
	const mins = Math.round(ms / 60_000);
	if (mins < 60) return `${mins}m`;
	const hours = Math.floor(mins / 60);
	const rem = mins % 60;
	if (hours < 24) return rem ? `${hours}h ${rem}m` : `${hours}h`;
	const days = Math.floor(hours / 24);
	const h = hours % 24;
	return h ? `${days}d ${h}h` : `${days}d`;
}

function providerGroups(doc) {
	const groups = new Map();
	for (const report of Array.isArray(doc?.reports) ? doc.reports : []) {
		if (!isTrackedProvider(report.provider)) continue;
		const windows = [];
		for (const limit of Array.isArray(report.limits) ? report.limits : []) {
			const window = windowsFor(limit);
			if (window) windows.push(window);
		}
		if (!windows.length) continue;
		if (!groups.has(report.provider)) {
			groups.set(report.provider, { id: report.provider, label: shortProvider(report.provider), windows });
		}
	}
	return [...groups.values()];
}

// One-word label: the first word of the id, capitalized; e.g. `zai` → `ZAI`.
function shortProvider(provider) {
	const word = String(provider).split(/[-_.]/)[0] || String(provider);
	return word.toUpperCase() === word ? word : word[0].toUpperCase() + word.slice(1);
}

// Context usage, 0..100, from omp's live gauge; over-reads the provider-true fill (×2–3.7 on some
// providers), which the plugin shows as-is — the composer bar carries the same number.
function contextPct(ctx) {
	const usage = ctx?.getContextUsage?.();
	if (!usage || typeof usage.tokens !== "number" || typeof usage.contextWindow !== "number" || usage.contextWindow <= 0) {
		return undefined;
	}
	return Math.min(100, Math.round((usage.tokens / usage.contextWindow) * 100));
}

// Session cost from usage records on the active branch, summed; turns = assistant messages.
function sessionSpend(ctx) {
	try {
		const branch = ctx.sessionManager.getActiveBranch?.();
		const messages = branch?.messages ?? [];
		let total = 0;
		let turns = 0;
		for (const message of messages) {
			if (message.role !== "assistant") continue;
			turns += 1;
			const cost = message.usage?.cost?.total;
			if (typeof cost === "number") total += cost;
		}
		return { total, turns };
	} catch {
		return { total: 0, turns: 0 };
	}
}

async function writeCache(ctx) {
	const [doc, spend] = [await fetchUsageJson(), sessionSpend(ctx)];
	const payload = {
		generatedAt: Date.now(),
		providers: providerGroups(doc),
		contextPct: contextPct(ctx),
		sessionCost: spend.total > 0 ? `$${spend.total.toFixed(2)}` : "$0.00",
		sessionTurns: spend.turns,
		modelProvider: ctx?.model?.provider,
	};
	try {
		mkdirSync(dirname(CACHE_FILE), { recursive: true });
		const tmp = `${CACHE_FILE}.tmp`;
		writeFileSync(tmp, JSON.stringify(payload));
		renameSync(tmp, CACHE_FILE); // atomic swap: readers never see a half-file
	} catch {
		// cache write failure is invisible; the plugin keeps its last good read
	}
}

export default function statuslineCache(pi) {
	let writing = false;
	let timer;
	let liveCtx;
	const update = async (_event, ctx) => {
		if (writing) return;
		writing = true;
		try {
			await writeCache(ctx);
		} finally {
			writing = false;
		}
	};
	pi.on("session_start", async (_event, ctx) => {
		liveCtx = ctx; // ExtensionContext has no setInterval; one module timer writes the latest session's data
		await update(_event, ctx);
		if (!timer) {
			timer = setInterval(() => {
				void update(_event, liveCtx);
			}, USAGE_MS);
			timer.unref?.(); // never hold the process open (print/pipe mode)
		}
	});
	pi.on("turn_end", async (_event, ctx) => {
		await update(_event, ctx);
	});
}
