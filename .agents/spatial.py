import json, urllib.request

BASE = "http://hive.pow"

def get(path):
    with urllib.request.urlopen(BASE + path) as r:
        return json.load(r)

def invoke(tool, args, profile="commander"):
    req = urllib.request.Request(
        BASE + "/invoke",
        data=json.dumps({"profile": profile, "tool": tool, "args": args}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        return json.load(r)

out = {}

# Drones
b = get("/brief")
out["drones"] = [
    {"name": d["name"], "id": d["id"], "pos": d["pos"], "status": d["status"], "fuel": d["fuel"]}
    for d in b["fleet"]["drones"]
]

# Caves
c = invoke("world.caves", {})
out["caves"] = c["data"]["caves"]

# Storage
s = invoke("storage.stock", {})
out["storage"] = s["data"]

# Faults
f = invoke("fleet.faults", {})
out["faults"] = f["data"]

# World find: sand, glass, sandstone
for match in ["sand", "glass", "stone"]:
    w = invoke("world.find", {"match": match, "limit": 5})
    out["find_" + match] = w["data"]

print(json.dumps(out, indent=2))
