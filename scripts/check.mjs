import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LuauState } from 'luau-web';

const root = fileURLToPath(new URL('../', import.meta.url));
const text = (name) => readFile(path.join(root, name), 'utf8');

// ── manifest contract ──
const manifest = await text('plugin.toml');
const pkg = JSON.parse(await text('package.json'));
const field = (name) => manifest.match(new RegExp(`^${name} = "(.*)"$`, 'm'))?.[1];
for (const name of ['id', 'name', 'version', 'window']) {
    assert.ok(field(name), `plugin.toml: missing ${name}`);
}
assert.equal(field('version'), pkg.version, 'plugin.toml version matches package.json');
assert.match(field('window'), /^[\w./-]+\.luau$/, 'window entry is a luau file');
assert.match(manifest, /^schema = 1$/m, 'schema is 1');
const license = (await text('LICENSE')).match(/^Copyright \(c\) (\d+) /m)?.[1];
assert.ok(license, 'LICENSE carries a copyright line');

// ── luau: compiles + behavior scenarios ──
const windowSource = await text(field('window'));
const behaviorSource = await text('tests/behavior.luau');
const vm = await LuauState.createAsync();
try {
    vm.loadstring(windowSource, field('window'), true);
    const run = vm.loadstring(`
local function load_window_plugin(api)
    local tern = api
${windowSource}
end
${behaviorSource}
`, 'behavior.luau', true);
    const [cases] = await run();
    assert.equal(typeof cases, 'number', 'behavior.luau returns a case count');
    assert.ok(cases > 0, 'behavior.luau ran at least one scenario');
    console.log(`Luau: runtime compiles; ${cases} behavioral scenarios pass.`);
} finally {
    vm.destroy();
}

// ── docs: every local link resolves to a file or heading ──
const docs = (await Promise.all(['README.md', 'AGENTS.md', 'CHANGELOG.md'].map(async (name) => [name, await text(name)])));
const exists = async (target) => { try { await stat(path.join(root, target)); return true; } catch { return false; } };
const slug = (heading) => heading.toLowerCase().replace(/[^\w\s-]/g, '').trim().replace(/\s+/g, '-');
let links = 0;
for (const [name, source] of docs) {
    for (const href of [...source.matchAll(/\]\(([^)#]+)(#[^)]+)?\)/g)].map((m) => [m[1], m[2]])) {
        const [target, anchor] = href;
        if (/^(https?:|mailto:)/.test(target)) continue;
        assert.ok(await exists(target), `${name}: broken link: ${target}`);
        if (anchor) {
            const headings = [...(await readFile(path.join(root, target), 'utf8')).matchAll(/^#{1,6}\s+(.+)$/gm)]
                .map((item) => slug(item[1]));
            assert.ok(headings.includes(decodeURIComponent(anchor.slice(1))), `${name}: missing anchor: ${anchor}`);
        }
        links += 1;
    }
}
console.log(`Contract: manifest versions match; ${links} local documentation links resolve.`);
