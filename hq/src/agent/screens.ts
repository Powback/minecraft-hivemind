/**
 * WHAT THE STATION MONITORS SHOW.
 *
 * Each module computer on the ground-floor ring has a 3x4 advanced monitor beside it. HQ composes a
 * short status page per module from what it already knows -- the queue, the fleet, the map, storage,
 * the docks, the bridge, the benchmark -- pushes it to the module over PowNet ("Screen", handled by
 * PowNet itself so every module has it), and serves the same text at GET /monitors for the world
 * viewer, which has no other way to read a terminal: the block entity saves size and index only.
 *
 * One composer, two sinks. Nothing here is a source of truth; it is the settlement's own numbers,
 * arranged for a wall.
 */
import { bridge } from '../bridge/ws.js';
import { registry } from '../tools/registry.js';
import { luaList, field } from '../lua-table.js';
import { stations, type Station } from '../world/settlement.js';
import { boot, structure, excavations, currentStage } from './bootstrap.js';

export interface Screen extends Station {
  title: string;
  lines: string[];
  bg: string;
  fg: string;
  updated: number;
}

const COLS = 42;   // an advanced 3x4 monitor at text scale 0.5
const ROWS = 40;
const screens = new Map<string, Screen>();

async function tool(name: string, args: unknown): Promise<any> {
  const r: any = await registry.invoke(name, args, { agent: 'screens', callId: `scr-${Date.now()}`, log: () => {} });
  return r && typeof r === 'object' && 'ok' in r ? (r.ok ? r.data : null) : r;
}
const clip = (s: string) => (s.length > COLS ? s.slice(0, COLS - 1) + '~' : s);
const pad2 = (n: number) => String(n).padStart(2, '0');
const hhmm = (ms: number) => { const d = new Date(ms); return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`; };

async function compose(): Promise<Record<string, { title: string; lines: string[] }>> {
  const out: Record<string, { title: string; lines: string[] }> = {};
  const now = Date.now();

  const fleet: any = await tool('fleet.status', {});
  const drones: any[] = fleet?.drones ?? [];
  const tasks: any = await tool('fleet.tasks', {});
  const nodes: any = await tool('hive.nodes', {});
  const docks: any = await tool('dock.list', {});
  let stock: any = null;
  try { stock = await tool('storage.stock', {}); } catch { /* silent: allow (no storage yet: the page says so) */ }

  // MainFrame: the benchmark.
  {
    const s = structure(), e = excavations();
    const stage = currentStage(boot.built, boot.dug);
    const el = boot.startedAt ? Math.round(((boot.finishedAt ?? now) - boot.startedAt) / 1000) : 0;
    const lines = [
      `stage   ${stage}`,
      `built   ${boot.built}/${s.length}`,
      `dug     ${boot.dug}/${e.length} chunks`,
      `elapsed ${Math.floor(el / 60)}m${pad2(el % 60)}s ${boot.active ? '' : '(paused)'}`,
      '',
      ...Object.entries(boot.stageDone).map(([k, v]) => `${k.padEnd(13)} +${Math.round(((v as number) - (boot.startedAt ?? 0)) / 1000)}s`),
      '',
      ...boot.log.slice(-8).map((l) => clip(l)),
    ];
    out.MainFrame = { title: 'HIVEMIND  bootstrap benchmark', lines };
  }
  // DroneMan: the fleet.
  out.DroneMan = {
    title: `FLEET  ${drones.length} drone(s)`,
    lines: drones.flatMap((d) => [
      clip(`${d.name}  ${d.role}  ${d.status}${d.healthy === false ? '  !' : ''}`),
      clip(`  at ${d.pos?.x},${d.pos?.y},${d.pos?.z}  fuel ${d.fuel}`),
      clip(`  ${d.detail ?? '-'}`),
      clip(`  carrying ${Object.entries(d.carrying ?? {}).map(([k, v]) => `${String(k).replace(/^minecraft:/, '')} ${v}`).join(', ') || '-'}`),
    ]),
  };
  // TaskMan: the queue.
  {
    const live = (tasks?.tasks ?? []).filter((t: any) => (t.progress ?? 0) < 100);
    out.TaskMan = {
      title: `TASKS  ${tasks?.live ?? 0} live`,
      lines: live.length ? live.slice(0, 12).flatMap((t: any) => [
        clip(`#${t.id} ${t.name}`),
        clip(`  ${t.verb ?? ''} ${t.assigned ? '-> ' + t.assigned : 'unassigned'} ${t.progress ?? 0}%`),
      ]) : ['queue empty'],
    };
  }
  // MapServer: coverage and the shaft.
  {
    let known = '-';
    try {
      const q: any = await tool('world.query', { min: { x: 43, y: 40, z: 11 }, max: { x: 85, y: 80, z: 53 } });
      known = q ? `${q.percent ?? '?'}% of the footprint volume observed` : '-';
    } catch { /* silent: allow (an unanswered map query leaves the coverage line as '-') */ }
    out.MapServer = { title: 'MAP', lines: [clip(known), '', ...Object.entries((nodes?.nodes ?? []).find((n: any) => n.label === 'MapServer') ?? {}).slice(0, 4).map(([k, v]) => clip(`${k} ${v}`))] };
  }
  // StorageMan: the shelf.
  {
    const detail: any[] = luaList<any>(field(stock, 'detail')) ?? stock?.detail ?? [];
    const lines = Array.isArray(detail) && detail.length
      ? detail.slice(0, 30).map((it: any) => clip(`${String(it.name ?? it.item ?? '?').replace(/^minecraft:/, '').padEnd(24)} ${it.count ?? it.n ?? ''}`))
      : ['no storage on the network', 'spoils chest: 61,68,32'];
    out.StorageMan = { title: 'STORAGE', lines };
  }
  // DockingMan: the berths.
  {
    const list = docks?.list ?? {};
    const lines = Object.entries(list).flatMap(([id, t]: [string, any]) => [
      clip(`tower ${id}  ${t.name ?? ''}  at ${(t.pos ?? []).join(',')}`),
      ...((t.slots ?? []).map((s: any, i: number) => clip(`  slot ${i}  ${s?.drone ?? s ?? 'free'}`))),
    ]);
    out.DockingMan = { title: 'DOCKS', lines: lines.length ? lines : ['no towers registered'] };
  }
  // Bridge: HQ link and modules.
  out.Bridge = {
    title: `HQ LINK  ${bridge.connected ? 'connected' : 'OFFLINE'}`,
    lines: [
      clip(`modules up ${nodes?.up ?? '?'}/${nodes?.count ?? '?'}`),
      ...((nodes?.nodes ?? []).map((n: any) => clip(`  ${String(n.label ?? n.name ?? '?').padEnd(12)} #${n.id ?? '?'}`))),
      '',
      clip(`hq time ${hhmm(now)}`),
    ],
  };
  return out;
}

export async function refreshScreens(): Promise<void> {
  if (!bridge.connected) return;
  const pages = await compose();
  for (const st of stations()) {
    const page = pages[st.label] ?? { title: st.label, lines: ['no status composed'] };
    const lines = page.lines.slice(0, ROWS - 1).map(clip);
    screens.set(st.label, { ...st, title: page.title, lines, bg: '#111111', fg: '#f0f0f0', updated: Date.now() });
    try {
      await bridge.call(st.label, 'Screen', { title: page.title, lines }, { timeoutMs: 4000 });
    } catch { /* silent: allow (a module that is down keeps its last screen; the feed still updates) */ }
  }
}

/** The feed for the world viewer. */
export function monitorsFeed() {
  return { monitors: [...screens.values()].map((s) => ({
    x: s.origin.x, y: s.origin.y, z: s.origin.z, facing: s.facing, width: s.width, height: s.height,
    label: s.label, title: s.title, lines: [s.title, ...s.lines], bg: s.bg, fg: s.fg, updated: s.updated,
  })) };
}

export function startScreens(intervalMs = 3_000) {
  setInterval(() => { refreshScreens().catch(() => { /* next tick */ }); }, intervalMs).unref();
}
