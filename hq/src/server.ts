/**
 * HQ — the out-of-world brain and the only thing an agent talks to.
 *
 * Surfaces:
 *   GET  /health              liveness + bridge state
 *   GET  /tools               tool schemas for a profile (what the model may emit)
 *   GET  /brief               live situation (also embedded in priming)
 *   GET  /prime?profile=…     the full boot transcript: system + primed messages
 *   POST /invoke              validated tool call
 *   WS   /bridge              the in-world Bridge dials in here
 *
 *   GET  /lua/manifest        hash manifest of the Lua tree  ── file sync
 *   GET  /lua/file/:path      raw source of one module       ──
 *
 *   GET  /map                 live 3D view of the surveyed world  ── operator's eyes
 *   GET  /map/state           one poll: fleet, caves, materials   ──
 *   GET  /map/voxels          the occupancy grid                  ──
 *   GET  /map/vendor/:file    vendored Three.js                   ──
 *
 * FILE SYNC, and why it exists: CC computers have no shell we can reach and no
 * shared filesystem. Without a pull path, shipping a Lua change means retyping it
 * into an in-game terminal. So HQ publishes the repo's `lua/` tree with content
 * hashes; the in-world Sync module pulls only what changed and writes it to
 * MainFrame's disk. From there the EXISTING PowNet `UPDATE` mechanism distributes
 * to drones — we deliberately do not replace a deploy path that already works.
 *
 *     repo lua/  ──http──►  MainFrame disk  ──PowNet UPDATE──►  drones
 */
import { createServer } from 'node:http';
import { readFile, readdir, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join, relative, extname } from 'node:path';
import { registry } from './tools/registry.js';
import { startSupplyLoop } from './agent/supply.js';
import './tools/core.js';                 // side-effect: registers the core tools
import { buildBrief } from './tools/core.js';
import { getProfile, permits } from './agent/profiles.js';
import { buildPriming, render } from './agent/priming.js';
import { bridge } from './bridge/ws.js';

const PORT = Number(process.env.PORT ?? 4400);
const LUA_DIR = process.env.LUA_DIR ?? join(process.cwd(), '..', 'lua');
/**
 * Static assets for /map. Baked into the image rather than bind-mounted like lua/: the Lua tree is
 * edited and re-synced at runtime by design, whereas the page and its vendored Three.js are build
 * output and must not be able to drift from the server that serves them.
 */
const PUBLIC_DIR = process.env.PUBLIC_DIR ?? join(process.cwd(), 'public');

let callSeq = 0;
const log = (msg: string, data?: unknown) =>
  console.log(new Date().toISOString(), msg, data === undefined ? '' : JSON.stringify(data));

// ── Lua file sync ──────────────────────────────────────────────────────────

/** Walk the Lua tree and hash every file. Cheap enough to do per request. */
async function luaManifest() {
  const files: Record<string, { sha1: string; bytes: number }> = {};
  async function walk(dir: string) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) { await walk(full); continue; }
      if (!['.lua', ''].includes(extname(entry.name))) continue; // .lua + extensionless (startup)
      const buf = await readFile(full);
      files[relative(LUA_DIR, full)] = {
        sha1: createHash('sha1').update(buf).digest('hex'),
        bytes: buf.length,
      };
    }
  }
  await walk(LUA_DIR);
  return { generatedAt: new Date().toISOString(), files };
}

// ── HTTP ───────────────────────────────────────────────────────────────────

/**
 * Cache for the map-wide queries that are expensive INSIDE MapServer.
 *
 * Returns the previous answer while a refresh is in flight, and keeps the last good answer if a
 * refresh fails -- so a slow MapServer degrades the map's freshness rather than blanking it.
 */
const SLOW_TTL_MS = 120_000;
const slowCache = new Map<string, { at: number; value: unknown; inflight?: Promise<unknown> }>();

async function slowCached(key: string, fn: () => Promise<unknown>): Promise<unknown> {
  const hit = slowCache.get(key);
  if (hit && Date.now() - hit.at < SLOW_TTL_MS) return hit.value;
  if (hit?.inflight) return hit.value;               // refresh already running; serve what we have
  const entry = hit ?? { at: 0, value: null };
  entry.inflight = fn()
    .then((v) => { entry.value = v; entry.at = Date.now(); return v; })
    .catch(() => entry.value)                        // keep the last good answer
    .finally(() => { entry.inflight = undefined; });
  slowCache.set(key, entry);
  return hit ? entry.value : await entry.inflight;   // first call waits; later ones do not
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://hq');
  const send = (code: number, body: unknown, type = 'application/json') => {
    const payload = type === 'application/json' ? JSON.stringify(body, null, 2) : String(body);
    res.writeHead(code, { 'content-type': type });
    res.end(payload);
  };
  /**
   * JSON without the pretty-printing. `send` indents because its readers are humans and language
   * models; the map page's readers are a poll loop and a voxel grid, where indentation is most of
   * the payload. Same envelope, different audience.
   */
  const sendCompact = (code: number, body: unknown, headers: Record<string, string> = {}) => {
    res.writeHead(code, { 'content-type': 'application/json', ...headers });
    res.end(JSON.stringify(body));
  };

  try {
    if (url.pathname === '/health') {
      return send(200, { ok: true, bridge: bridge.status(), tools: registry.list().length });
    }

    if (url.pathname === '/tools') {
      const profile = getProfile(url.searchParams.get('profile') ?? 'commander');
      return send(200, {
        profile: profile.name,
        tools: registry.toAnthropicTools(profile.allow),
      });
    }

    if (url.pathname === '/brief') return send(200, buildBrief());

    /**
     * Everything a runner needs to start an agent: system prompt, tool schemas,
     * and the primed message history with live state already delivered. One call,
     * so the runner stays trivial and can itself be a small script.
     */
    if (url.pathname === '/prime') {
      const profile = getProfile(url.searchParams.get('profile') ?? 'commander');
      const messages = buildPriming({
        registry,
        allow: profile.allow,
        brief: render(buildBrief()),
      });
      return send(200, {
        profile: profile.name,
        model: profile.model,
        maxSteps: profile.maxSteps,
        system: profile.system,
        tools: registry.toAnthropicTools(profile.allow),
        messages,
      });
    }

    if (url.pathname === '/invoke' && req.method === 'POST') {
      const body = await readBody(req);
      const { profile: profileName = 'commander', tool, args } = JSON.parse(body || '{}');
      const profile = getProfile(profileName);

      // Two independent gates: the allowlist (which tools exist for this agent)
      // and the danger ceiling (how much damage the profile may do at all). Both
      // are enforced here rather than trusted to the prompt, because a prompt is
      // a request and this is a rule.
      const def = registry.get(tool);
      if (!profile.allow.includes(tool)) {
        // Distinguish "you typo'd" from "that is not yours". A model that
        // misspelled a tool needs the spelling; telling it about permissions
        // sends it looking for an authority problem it does not have.
        const unknown = !def;
        return send(200, {
          ok: false,
          error: unknown
            ? `No tool named "${tool}".`
            : `Profile "${profile.name}" may not call ${tool}.`,
          fix: `Available to you: ${profile.allow.join(', ')}`,
        });
      }
      if (def && !permits(profile, def.danger))
        return send(200, { ok: false, error: `${tool} is ${def.danger}; ${profile.name} is limited to ${profile.maxDanger}.`,
                           fix: 'Hand this up to the commander instead of attempting it.' });

      const result = await registry.invoke(tool, args, {
        agent: profile.name, callId: `c${++callSeq}`, log,
      });
      log(`invoke ${tool} by ${profile.name}`, { ok: result.ok });
      return send(200, result);
    }

    if (url.pathname === '/lua/manifest') return send(200, await luaManifest());

    if (url.pathname.startsWith('/lua/file/')) {
      const rel = decodeURIComponent(url.pathname.slice('/lua/file/'.length));
      // Path containment: the sync client is in-world and not to be trusted with
      // arbitrary paths on the host.
      const full = join(LUA_DIR, rel);
      if (!full.startsWith(LUA_DIR)) return send(400, 'bad path', 'text/plain');
      await stat(full);
      return send(200, await readFile(full, 'utf8'), 'text/plain');
    }

    // ── /map — the operator's eyes ─────────────────────────────────────────
    //
    // Deliberately NOT routed through /invoke. That endpoint enforces the profile allowlist and
    // danger ceiling, which exist to constrain a language model deciding what to do; a browser
    // rendering read-only state is not that actor, and making the page carry a profile name would
    // imply it is one. It calls the registry directly, which still gives it schema validation and
    // the ok/error envelope -- just without pretending a renderer needs an agent identity.
    if (url.pathname === '/map' || url.pathname === '/map/') {
      return send(200, await readFile(join(PUBLIC_DIR, 'map.html'), 'utf8'), 'text/html; charset=utf-8');
    }

    if (url.pathname.startsWith('/map/vendor/')) {
      const rel = decodeURIComponent(url.pathname.slice('/map/vendor/'.length));
      const full = join(PUBLIC_DIR, 'vendor', rel);
      // Same containment rule as /lua/file, for the same reason: a path from a request is input.
      if (!full.startsWith(join(PUBLIC_DIR, 'vendor'))) return send(400, 'bad path', 'text/plain');
      const body = await readFile(full);
      // Three.js is 670KB and never changes without an image rebuild, so let the browser keep it.
      // Without this every 3s poll of the page's own tab reload would re-ship the whole library.
      res.writeHead(200, {
        'content-type': 'text/javascript; charset=utf-8',
        'cache-control': 'public, max-age=604800, immutable',
      });
      return res.end(body);
    }

    if (url.pathname === '/map/voxels') {
      // Occupancy and identity in one response, because the renderer cannot colour a cell without
      // both and fetching them separately would let it draw a frame with one and not the other.
      const [voxels, blocks] = await Promise.all([
        mapCall('world.voxels', { raw: true }),
        mapCall('world.blocks', { raw: true }),
      ]);
      return sendCompact(200, { voxels, blocks });
    }

    /**
     * Everything that changes, in ONE request. The page polls this every few seconds; issuing five
     * separate fetches would put five independent rednet round-trips on the bridge per tick and
     * give the page five chances to render a half-updated world. Each source is settled
     * independently so that one failing tool (a cave scan timing out, say) costs its own panel and
     * not the whole view -- the alternative is a blank page whenever the slowest call blinks.
     */
    if (url.pathname === '/map/state') {
      // SLOW, MAP-WIDE QUERIES ARE CACHED. THE FAST ONES ARE NOT.
      //
      // caves and find each walk the entire world inside MapServer -- at 269,000 cells that is the
      // most expensive thing the module does -- and this endpoint was asking for three of them on
      // EVERY poll of the map page. MapServer spent its life recomputing answers that change on the
      // timescale of mining, not of a browser refresh, and had nothing left for pathfinding: the
      // Bridge logged "call MapServer.FindBlocks FAILED (lookup=111)" continuously, a module found
      // and then silent.
      //
      // Fleet, tasks and stock stay live: they are cheap, they change constantly, and they are what
      // the page is actually for.
      const [fleet, tasks, nodes, stock] = await Promise.all([
        mapCall('fleet.status', {}),
        mapCall('fleet.tasks', {}),
        mapCall('hive.nodes', {}),
        mapCall('storage.stock', {}),
      ]);
      const caves = await slowCached('caves', () => mapCall('world.caves', { min: 4 }));
      const ore   = await slowCached('ore',   () => mapCall('world.find', { match: 'ore', limit: 200 }));
      const dirt  = await slowCached('dirt',  () => mapCall('world.find', { match: 'dirt', limit: 200 }));
      return sendCompact(200, {
        at: Date.now(),
        bridge: bridge.status(),
        fleet, tasks, nodes, caves, ore, dirt, stock,
      });
    }

    send(404, { error: 'not found' });
  } catch (err) {
    log('request failed', (err as Error).message);
    send(500, { error: (err as Error).message });
  }
});

/**
 * One tool call on behalf of the map page.
 *
 * Returns the registry envelope untouched, failures included, so the page can draw what it has and
 * label what it could not get. A 500 here would tell the operator only that "the map broke", when
 * the useful fact is which of five things broke.
 *
 * The log is deliberately swallowed: the page polls every few seconds forever, and letting that
 * into the same stream as `invoke` lines would bury the agent's actual decisions under a metronome.
 */
function mapCall(tool: string, args: unknown) {
  return registry.invoke(tool, args, { agent: 'map', callId: `m${++callSeq}`, log: () => {} });
}

function readBody(req: import('node:http').IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => (data += c));
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

bridge.attach(server, '/bridge');

server.listen(PORT, '0.0.0.0', () => {
  log(`HQ listening on :${PORT}`);
  log(`  tools registered: ${registry.list().length}`);
  startSupplyLoop();
  log(`  lua tree: ${LUA_DIR}`);
});
