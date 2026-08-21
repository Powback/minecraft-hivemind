// Pull every spatial fact the world can tell me, through the HQ bridge.
const BASE = "http://hive.pow";

function invoke(tool, args, profile = "commander") {
  return new Promise((res, rej) => {
    const req = require("http").request(BASE.replace("http://", "http://") + "/invoke", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    }, r => { let b = ""; r.on("data", c => b += c); r.on("end", () => {
      try { res(JSON.parse(b)); } catch (e) { rej(new Error(b)); }
    }); });
    req.on("error", rej);
    req.end(JSON.stringify({ profile, tool, args }));
  });
}

async function main() {
  const out = {};

  // Drones
  const brief = await (await fetch(BASE + "/brief")).json();
  out.drones = brief.fleet.drones.map(d => ({
    name: d.name, id: d.id, pos: d.pos, status: d.status, fuel: d.fuel,
  }));

  // Caves
  const caves = await invoke("world.caves", {});
  out.caves = caves.data.caves;

  // Storage
  const stock = await invoke("storage.stock", {});
  out.storage = stock.data;

  // Faults
  const faults = await invoke("fleet.faults", {});
  out.faults = faults.data;

  // Surveyed blocks — sand, glass, sandstone, stone
  for (const m of ["sand", "glass", "stone", "ore"]) {
    const f = await invoke("world.find", { match: m, limit: 10 });
    out["find_" + m] = f.data;
  }

  console.log(JSON.stringify(out, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
