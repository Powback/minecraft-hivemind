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

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://hq');
  const send = (code: number, body: unknown, type = 'application/json') => {
    const payload = type === 'application/json' ? JSON.stringify(body, null, 2) : String(body);
    res.writeHead(code, { 'content-type': type });
    res.end(payload);
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

    send(404, { error: 'not found' });
  } catch (err) {
    log('request failed', (err as Error).message);
    send(500, { error: (err as Error).message });
  }
});

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
