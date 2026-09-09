/**
 * A minimal Source-RCON client, for the one thing drones cannot do: flip the `peripheral` state on a
 * wired modem after they have placed it (CC:Tweaked attaches a peripheral only on right-click). Kept
 * deliberately small: TCP, auth packet (type 3), command packet (type 2), one command per connection.
 * Never used to place or remove blocks -- the drones build; this only toggles state on what they built.
 */
import { createConnection } from 'node:net';

function packet(id: number, type: number, body: string): Buffer {
  const payload = Buffer.from(body, 'utf8');
  const buf = Buffer.alloc(14 + payload.length);
  buf.writeInt32LE(10 + payload.length, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  payload.copy(buf, 12);
  buf.writeInt16LE(0, 12 + payload.length);
  return buf;
}

export async function rcon(command: string, opts: { host?: string; port?: number; password?: string; timeoutMs?: number } = {}): Promise<string> {
  const host = opts.host ?? process.env.RCON_HOST ?? 'mc-create121';
  const port = opts.port ?? Number(process.env.RCON_PORT ?? 25575);
  const password = opts.password ?? process.env.RCON_PASSWORD ?? '';
  if (!password) throw new Error('RCON_PASSWORD is not set for HQ');
  return new Promise<string>((resolve, reject) => {
    const sock = createConnection({ host, port });
    const chunks: Buffer[] = [];
    let authed = false;
    const timer = setTimeout(() => { sock.destroy(); reject(new Error(`rcon timeout: ${command}`)); }, opts.timeoutMs ?? 8000);
    sock.on('connect', () => sock.write(packet(1, 3, password)));
    sock.on('data', (d) => {
      chunks.push(d);
      const all = Buffer.concat(chunks);
      let off = 0;
      while (off + 4 <= all.length) {
        const len = all.readInt32LE(off);
        if (off + 4 + len > all.length) break;
        const id = all.readInt32LE(off + 4);
        const type = all.readInt32LE(off + 8);
        const body = all.subarray(off + 12, off + 4 + len - 2).toString('utf8');
        off += 4 + len;
        if (!authed) {
          if (type === 2 && id === -1) { clearTimeout(timer); sock.destroy(); reject(new Error('rcon auth failed')); return; }
          if (type === 2) { authed = true; sock.write(packet(2, 2, command)); }
        } else if (type === 0 && id === 2) {
          clearTimeout(timer); sock.end(); resolve(body); return;
        }
      }
      chunks.length = 0; if (off < all.length) chunks.push(all.subarray(off));
    });
    sock.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}
