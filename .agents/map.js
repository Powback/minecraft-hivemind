// Assemble a top-down (XZ) map of the base from all the spatial data.
// X = east-west (+X east), Z = north-south (+Z south), Y = up.

// Fixed infrastructure (from memory + MapServer.lua Init)
const items = {
  // Computers (y=81)
  "112": { x: -95, z: -44, y: 81, label: "TaskMan",    kind: "computer" },
  "111": { x: -93, z: -44, y: 81, label: "MapServer",  kind: "computer" },
  "110": { x: -91, z: -44, y: 81, label: "DockingMan", kind: "computer" },
  "91":  { x: -87, z: -44, y: 81, label: "DroneMan",   kind: "computer" },
  "78":  { x: -85, z: -44, y: 81, label: "MainFrame",  kind: "computer" },
  "90":  { x: -83, z: -44, y: 81, label: "relay",      kind: "computer" },
  "81":  { x: -84, z: -43, y: 81, label: "turtle-81",  kind: "computer" },
  "79":  { x: -85, z: -46, y: 81, label: "mining-1",   kind: "computer" },
  "80":  { x: -87, z: -46, y: 81, label: "mining-2",   kind: "computer" },
  // Disk drive on MainFrame
  "dd":  { x: -84, z: -44, y: 81, label: "disk drive", kind: "drive" },
  // Docking tower
  "dock1": { x: -95, z: -45, y: 83, label: "dock1",    kind: "tower" },
  // GPS hosts (y=95/99)
  "gps1": { x: -92, z: -52, y: 95, label: "gps-100",   kind: "gps" },
  "gps2": { x: -78, z: -52, y: 95, label: "gps-101",   kind: "gps" },
  "gps3": { x: -92, z: -38, y: 95, label: "gps-102",   kind: "gps" },
  "gps4": { x: -85, z: -45, y: 99, label: "gps-103",   kind: "gps" },
  // Drones (live)
  "D1":  { x: -64, z: -58, y: 65, label: "D1 #121",    kind: "drone", status: "idle" },
  "D3":  { x: -89, z: -53, y: 85, label: "D3 #123",    kind: "drone", status: "idle" },
  "D2":  { x: -62, z: -56, y: 73, label: "D2 #122",    kind: "drone", status: "offline" },
  "D5":  { x: -89, z: -51, y: 86, label: "D5 #125",    kind: "drone", status: "idle" },
  "D4":  { x: -90, z: -52, y: 85, label: "D4 #120",    kind: "drone", status: "idle" },
  // Caves (9 pockets)
  "cave1": { x: -60, z: -55, y: 68, size: 112 },
  "cave2": { x: -68, z: -55, y: 67, size: 90 },
  "cave3": { x: -68, z: -55, y: 65, size: 56 },
  "cave4": { x: -60, z: -55, y: 66, size: 56 },
  "cave5": { x: -96, z: -44, y: 80, size: 35 },
  "cave6": { x: -68, z: -53, y: 70, size: 30 },
  "cave7": { x: -60, z: -55, y: 71, size: 29 },
  "cave8": { x: -90, z: -45, y: 77, size: 22 },
  "cave9": { x: -89, z: -52, y: 78, size: 8 },
};

// Build a top-down grid. X columns left(-100) to right(-55), Z rows top(-60) to bottom(-40).
const XMIN = -100, XMAX = -55, ZMIN = -60, ZMAX = -40;
const grid = {};
for (const [id, it] of Object.entries(items)) {
  if (it.kind === "cave") continue; // caves are 3D, show separately
  grid[`${it.x},${it.z}`] = grid[`${it.x},${it.z}`] || [];
  grid[`${it.x},${it.z}`].push(id);
}

let out = "";
out += "TOP-DOWN (XZ) — x → east, z ↓ south; y noted per object\n";
out += "       " + Array.from({length: XMAX - XMIN + 1}, (_, i) => (XMIN + i).toString().slice(-2)).join("  ") + "\n";
out += "  +------------------------------------------------------------\n";
for (let z = ZMIN; z <= ZMAX; z++) {
  let row = `z${z >= 0 ? " " : ""}${z} |`;
  for (let x = XMIN; x <= XMAX; x++) {
    const ids = grid[`${x},${z}`];
    row += ids ? ids.join(" ") : "·";
    row += " ";
  }
  out += row + "\n";
}
out += "\nLEGEND\n";
out += "  112=TaskMan  111=MapServer  110=DockingMan  91=DroneMan  78=MainFrame  90=relay\n";
out += "  81=turtle-81  79=mining-1  80=mining-2  dd=disk drive  T=dock1 tower\n";
out += "  G=GPS host (y95/99)  D1-D5=drones\n";
out += "\nVERTICAL STACK (y) at the base\n";
out += "  y=99  gps-103 (-85,-45)\n";
out += "  y=95  gps-100 (-92,-52)   gps-101 (-78,-52)   gps-102 (-92,-38)\n";
out += "  y=83  dock1 tower (-95,-45)\n";
out += "  y=81  main row: 112(-95) 111(-93) 110(-91) 91(-87) 78(-85) dd(-84) 90(-83)\n";
out += "        behind: 79(-85,-46) 80(-87,-46)    front: 81(-84,-43)\n";
out += "  y=85-86  D3(-89,-53) D5(-89,-51) D4(-90,-52)\n";
out += "  y=73  D2(-62,-56) [offline]\n";
out += "  y=65  D1(-64,-58)\n";
out += "\nCAVES (9 pockets, from MapServer survey)\n";
for (const [id, c] of Object.entries(items)) {
  if (c.size) out += `  ${id}  ${c.size} cells  @ (${c.x},${c.y},${c.z})\n`;
}
out += "\nSTORAGE (wired network)\n";
out += "  1 chest · 2 furnaces · 9 free slots · 770 items\n";
out += "  sandstone 258 · sand 255 · glass 254 · turtle 1 · wireless_modem 1 · wired_modem 1\n";
out += "\nFAULTS: 0 across all 5 modules\n";
out += "SURVEY: world.find returns 0 for sand/glass/stone/ore — occupancy grid is sparse\n";

console.log(out);
