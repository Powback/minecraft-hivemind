/**
 * The bridge — HQ's end of the link into the world.
 *
 * Direction matters: CC:T can only OPEN websockets, never accept them, so HQ is
 * the server and the in-world Bridge computer dials out. That is also the right
 * shape operationally — the game server can restart freely and reconnect without
 * HQ knowing or caring.
 *
 * What this layer owes the rest of the system, and why each part exists:
 *
 *   - CORRELATION. Calls into the world are async and the world is slow. Every
 *     request carries an id and resolves a promise; late replies to a dead call
 *     are dropped rather than mistaken for the current one. (PowNet V2 got this
 *     right with `reply.ID == message.ID` — same rule, same reason.)
 *   - TIMEOUTS. A drone can be destroyed mid-call. Without a timeout the promise
 *     leaks and the agent hangs forever waiting on a turtle that no longer exists.
 *   - IDEMPOTENCY. Retries are inevitable on a lossy link, so mutating calls carry
 *     a key and the Lua side refuses to apply the same key twice. Otherwise a
 *     retried "dig here" digs twice.
 *   - BACKPRESSURE. Scans are large and rednet is slow. We bound the queue and
 *     shed the oldest low-priority traffic rather than growing without limit.
 *
 * None of this is exposed to the agent. From above, calling into the world looks
 * like awaiting a function. That is the entire point of building it now.
 */
import { WebSocketServer, WebSocket } from 'ws';
import type { IncomingMessage } from 'node:http';
import type { Server } from 'node:http';
import { state } from '../world/state.js';

export const PROTOCOL_VERSION = 1;

export type Envelope =
  | { v: number; type: 'HELLO'; bridge: string; computerId: number }
  | { v: number; type: 'PING'; t: number }
  | { v: number; type: 'PONG'; t: number }
  /** world → HQ, unsolicited: heartbeats, scans, order progress, failures. */
  | { v: number; type: 'EVENT'; key: string; data: any }
  /** HQ → world, expects REPLY with the same id. */
  | { v: number; type: 'CALL'; id: string; module: string; key: string; data: any; idem?: string }
  | { v: number; type: 'REPLY'; id: string; ok: boolean; data?: any; error?: string };

interface Pending {
  resolve: (v: any) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
  sentAt: number;
}

export class Bridge {
  private ws?: WebSocket;
  private pending = new Map<string, Pending>();
  private seq = 0;
  /** Buffered while disconnected; bounded, oldest dropped first. */
  private outbox: Envelope[] = [];
  private maxOutbox = 200;
  private log: (m: string, d?: unknown) => void;

  constructor(log = (m: string, d?: unknown) => console.log('[bridge]', m, d ?? '')) {
    this.log = log;
  }

  get connected() { return this.ws?.readyState === WebSocket.OPEN; }

  attach(server: Server, path = '/bridge') {
    const wss = new WebSocketServer({ server, path });
    wss.on('connection', (sock: WebSocket, req: IncomingMessage) => {
      // Single bridge by design. A second in-world bridge would duplicate every
      // order — the same "never two refreshers" rule that governs the auth fleet.
      if (this.connected) {
        this.log('rejecting second bridge connection', req.socket.remoteAddress);
        sock.close(1013, 'bridge already connected');
        return;
      }
      this.log('bridge connected', req.socket.remoteAddress);
      this.ws = sock;
      this.flush();

      sock.on('message', (raw) => this.onMessage(raw.toString()));
      sock.on('close', (code) => {
        this.log(`bridge disconnected (${code})`);
        this.ws = undefined;
        // Fail everything in flight immediately. Silently waiting out each
        // timeout would leave the agent staring at a frozen world for a minute.
        for (const [id, p] of this.pending) {
          clearTimeout(p.timer);
          p.reject(new Error('bridge disconnected before reply'));
          this.pending.delete(id);
        }
      });
      sock.on('error', (e) => this.log('socket error', e.message));
    });
    this.log(`listening for in-world bridge on ${path}`);
  }

  private onMessage(raw: string) {
    let msg: Envelope;
    try { msg = JSON.parse(raw); } catch { return this.log('unparseable frame', raw.slice(0, 120)); }
    if (msg.v !== PROTOCOL_VERSION)
      return this.log(`protocol mismatch: bridge v${msg.v}, HQ v${PROTOCOL_VERSION}`);

    switch (msg.type) {
      case 'HELLO':
        this.log(`hello from ${msg.bridge} (computer #${msg.computerId})`);
        break;
      case 'PING':
        this.send({ v: PROTOCOL_VERSION, type: 'PONG', t: msg.t });
        break;
      case 'REPLY': {
        const p = this.pending.get(msg.id);
        if (!p) return; // late reply to an abandoned call — correct to ignore
        clearTimeout(p.timer);
        this.pending.delete(msg.id);
        msg.ok ? p.resolve(msg.data) : p.reject(new Error(msg.error ?? 'world-side failure'));
        break;
      }
      case 'EVENT':
        this.onEvent(msg.key, msg.data);
        break;
    }
  }

  /**
   * Unsolicited world events. These keep HQ's model current without polling —
   * polling a swarm over rednet would saturate the link with questions whose
   * answers mostly did not change.
   */
  private onEvent(key: string, data: any) {
    switch (key) {
      case 'drone.heartbeat':
        state.upsertDrone({
          id: data.id, name: data.name, pos: data.pos, fuel: data.fuel,
          status: data.status, order: data.order, lastSeen: Date.now(),
        });
        break;
      case 'drone.register':
        this.log(`drone #${data.id} registered as ${data.name}`);
        state.upsertDrone({ id: data.id, name: data.name, role: data.role ?? 'worker', lastSeen: Date.now() });
        break;
      case 'scan.blocks': {
        const changed = state.ingestScan(data.by, data.blocks ?? [], data.at ?? Date.now());
        this.log(`scan from #${data.by}: ${data.blocks?.length ?? 0} cells, ${changed} changed`);
        break;
      }
      case 'order.progress': {
        const o = state.getOrder(data.id);
        if (o) { o.progress = data.progress; o.status = data.status ?? o.status; }
        break;
      }
      case 'order.failed': {
        const o = state.getOrder(data.id);
        // Keep the reason verbatim — it is the input the agent replans from,
        // and paraphrasing it loses the detail that made it actionable.
        if (o) { o.status = 'failed'; o.failure = data.reason; }
        this.log(`order ${data.id} failed: ${data.reason}`);
        break;
      }
      default:
        this.log(`unhandled event ${key}`);
    }
  }

  /** Call into the world. Rejects on timeout or disconnect; never hangs. */
  call(module: string, key: string, data: unknown, opts: { timeoutMs?: number; idem?: string } = {}) {
    const id = `hq-${++this.seq}`;
    const env: Envelope = { v: PROTOCOL_VERSION, type: 'CALL', id, module, key, data, idem: opts.idem };
    return new Promise<any>((resolve, reject) => {
      const timeout = opts.timeoutMs ?? 15_000;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${module}.${key} timed out after ${timeout}ms`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer, sentAt: Date.now() });
      this.send(env);
    });
  }

  private send(env: Envelope) {
    if (!this.connected) {
      // CALLs are pointless to buffer — they carry a timeout that will expire
      // before a human notices the bridge is down. Events are worth keeping.
      if (env.type === 'CALL') return;
      this.outbox.push(env);
      if (this.outbox.length > this.maxOutbox) this.outbox.shift();
      return;
    }
    this.ws!.send(JSON.stringify(env));
  }

  private flush() {
    const queued = this.outbox.splice(0);
    for (const e of queued) this.send(e);
    if (queued.length) this.log(`flushed ${queued.length} buffered frames`);
  }

  status() {
    return {
      connected: this.connected,
      inFlight: this.pending.size,
      buffered: this.outbox.length,
      protocol: PROTOCOL_VERSION,
    };
  }
}

export const bridge = new Bridge();
