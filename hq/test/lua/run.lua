-- Behavioural tests for the in-world Lua, run under a real Lua with a stub ComputerCraft world.
--
--   lua5.4 hq/test/lua/run.lua            (hq/test/lua-behaviour.test.ts drives it)
--
-- Each module is loaded into its own environment (cc_stubs.makeEnv) so its globals do not collide
-- with another module's. Locals worth testing are exported by the module itself through the
-- HiveMindTest hook it fills in when that global exists -- production code never sees it set.
-- Output is one JSON line per test: {"name":..., "ok":..., "msg":...}.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/../../.."
package.path = here .. "/?.lua;" .. package.path
local stubs = require("cc_stubs")

local results = {}
local function report(name, ok, msg)
    results[#results + 1] = { name = name, ok = ok, msg = msg }
    io.write(stubs.toJSON({ name = name, ok = ok, msg = msg }), "\n")
end

local function test(name, fn)
    local ok, err = pcall(fn)
    report(name, ok and true or false, ok and "" or tostring(err))
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(what or "value", tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, what) if not v then error((what or "value") .. " should be truthy, got " .. tostring(v), 2) end end
local function falsy(v, what) if v then error((what or "value") .. " should be falsy, got " .. tostring(v), 2) end end
local function contains(s, sub, what)
    if type(s) ~= "string" or not s:find(sub, 1, true) then
        error(("%s: expected to contain %q, got %s"):format(what or "string", sub, tostring(s)), 2)
    end
end

-- Load a module in a fresh environment and return the env (its globals) plus its test hook.
local function loadModule(path, opts)
    local env = stubs.makeEnv(opts)
    local chunk, err = loadfile(root .. "/lua/" .. path, "t", env)
    if not chunk then error("cannot load " .. path .. ": " .. tostring(err)) end
    local ok, runErr = pcall(chunk)
    if not ok then error(path .. " failed while loading: " .. tostring(runErr)) end
    return env, env.HiveMindTest[path:gsub("%.lua$", "")] or {}
end

-- ================================================================================================
-- TaskMan
-- ================================================================================================
local function taskManWithFleet(drones, storageDetail)
    local env, T = loadModule("TaskMan.lua")
    env.__world.replies.DroneMan = { GetDrones = { drones = drones } }
    env.__world.replies.StorageMan = { GetStock = { detail = storageDetail or {} } }
    return env, T
end

test("TaskMan loads under the stub world", function()
    local env, T = loadModule("TaskMan.lua")
    truthy(env.OnStartTask, "OnStartTask defined")
    truthy(T.jobMinFuel, "test hook exports jobMinFuel")
end)

test("TaskMan.jobMinFuel prices the work plus a margin, per verb", function()
    local _, T = loadModule("TaskMan.lua")
    eq(T.workCost({ work = { lumber = { w = 8, l = 8 } } }), 8 * 8 * 2 + 60, "lumber 8x8 work")
    eq(T.jobMinFuel({ work = { lumber = { w = 8, l = 8 } } }), 8 * 8 * 2 + 60 + 100, "lumber 8x8 minimum")
    eq(T.jobMinFuel({ work = { haul = { pos = { x = 0, y = 64, z = 0 } } } }), 40 + 100, "haul minimum")
    eq(T.jobMinFuel({ work = { plant = { spots = { {}, {}, {}, {} } } } }), 4 * 8 + 40 + 100, "plant of 4 minimum")
    eq(T.jobMinFuel({ work = { rescue = { fuel = true } } }), 300, "a fuel relief keeps the relief floor")
end)

test("TaskMan.workPos knows where every kind of work happens", function()
    local _, T = loadModule("TaskMan.lua")
    eq(T.workPos({ work = { lumber = { start = { x = 1, y = 2, z = 3 } } } }).x, 1, "lumber start")
    eq(T.workPos({ work = { haul = { pos = { x = 4, y = 5, z = 6 } } } }).z, 6, "haul pos")
    eq(T.workPos({ work = { plant = { pos = { x = 7, y = 8, z = 9 } } } }).y, 8, "plant pos")
    eq(T.workPos({ work = { build = { origin = { x = 1, y = 1, z = 1 } } } }).x, 1, "build origin")
    local mid = T.workPos({ work = { dig = { min = { x = 0, y = 0, z = 0 }, max = { x = 10, y = 4, z = 6 } } } })
    eq(mid.x, 5, "dig midpoint x") eq(mid.z, 3, "dig midpoint z")
    eq(T.workPos({ work = { craft = {} } }), nil, "a craft has no site")
end)

test("TaskMan.RoleForWork: planting and hauling need no upgrade", function()
    local env = loadModule("TaskMan.lua")
    eq(env.RoleForWork({ plant = {} }), "any", "plant")
    eq(env.RoleForWork({ haul = {} }), "any", "haul")
    eq(env.RoleForWork({ craft = {} }), "crafter", "craft")
    eq(env.RoleForWork({ lumber = {} }), "miner", "lumber")
end)

test("TaskMan.pickDrone refuses a drone that cannot afford the round trip, and says so", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 400, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone, busy, poor, need = T.pickDrone("miner", { x = 50, y = 64, z = 0 }, nil, 288)
    eq(drone, nil, "no drone picked")
    eq(busy, nil, "nobody is busy")
    truthy(poor, "the idle-but-poor drone is reported")
    eq(need, 288 + 6 * 50, "the need charges the round trip per block")
    local why = T.noDroneReason("miner", busy, poor, need)
    contains(why, "can afford it", "reason")
    contains(why, "588", "reason names the number")
end)

test("TaskMan.pickDrone treats a docked drone as free", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D4", role = "miner", status = "docking", fuel = 1200, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone, busy = T.pickDrone("miner", { x = 10, y = 64, z = 0 }, nil, 100)
    truthy(drone, "picked") eq(drone and drone.name, "D4", "the docked drone") eq(busy, nil, "not busy")
end)

test("TaskMan.pickDrone prices work with no site as no trip, so a crafter can afford a craft", function()
    local _, T = taskManWithFleet({
        { id = 2, name = "D4", role = "crafter", status = "docking", fuel = 1200, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone, _, poor, need = T.pickDrone("crafter", nil, nil, 100)
    truthy(drone, "picked: " .. tostring(need)) eq(drone and drone.name, "D4", "the crafter")
    eq(poor, nil, "not reported as poor")
end)

test("TaskMan.anyoneForBuild prices the build for the fallback drone too", function()
    local _, T = taskManWithFleet({
        { id = 3, name = "D39", role = "scout", status = "idle", fuel = 290, fuelFloor = 120, pos = { x = 0, y = 64, z = 0 } },
    })
    local build = { id = 9, name = "tower-L0-p1", work = { build = { origin = { x = 14, y = 64, z = 0 } } } }
    eq(T.anyoneForBuild(build, { x = 14, y = 64, z = 0 }, 300), nil, "a 384-fuel build is not handed to a 290-fuel scout")
    local _, T2 = taskManWithFleet({
        { id = 3, name = "D39", role = "scout", status = "idle", fuel = 1200, fuelFloor = 120, pos = { x = 0, y = 64, z = 0 } },
    })
    local d = T2.anyoneForBuild(build, { x = 14, y = 64, z = 0 }, 300)
    eq(d and d.name, "D39", "a scout that can afford it builds")
end)

test("TaskMan.heldForNothing: a busy drone that has not moved for three minutes is stalled", function()
    local env, T = taskManWithFleet({})
    local d = { id = 58, name = "D40", role = "miner", status = "busy", fuel = 1700, pos = { x = -480, y = 64, z = 65 } }
    eq(T.heldForNothing(d), nil, "first sighting: not stalled")
    env.__world.clock = env.__world.clock + 200                 -- os.epoch follows the stub clock (ms = s * 1000)
    truthy(T.heldForNothing(d), "still there 200 s later: stalled")
    d.pos = { x = -470, y = 64, z = 65 }
    eq(T.heldForNothing(d), nil, "it moved: not stalled")
end)

test("TaskMan: a haul goes to a free scout before a free miner", function()
    local env, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 1500, pos = { x = -468, y = 64, z = 43 } },
        { id = 2, name = "D9", role = "scout", status = "idle", fuel = 1500, pos = { x = -475, y = 64, z = 50 } },
    })
    env.DATA.tasks = { [7] = { id = 7, name = "haul:-469,64,41", work = { haul = { pos = { x = -469, y = 64, z = 41 } } }, progress = 0, priority = 1 } }
    local ok, r = env.OnStartTask(0, { data = { id = 7 } })
    truthy(ok, "placed: " .. tostring(r and (r.message or r) or "?"))
    eq(env.DATA.tasks[7].assignedTo, 2, "the scout took it, though the miner was nearer")
end)

test("TaskMan: a haul from an underground cache goes to a miner, never a scout", function()
    local env, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 1500, pos = { x = -480, y = 64, z = 80 } },
        { id = 2, name = "D9", role = "scout", status = "idle", fuel = 1500, pos = { x = -480, y = 64, z = 84 } },
    })
    env.DATA.tasks = { [8] = { id = 8, name = "haul:-480,8,87", work = { haul = { pos = { x = -480, y = 8, z = 87 } } }, progress = 0, priority = 1 } }
    local ok = env.OnStartTask(0, { data = { id = 8 } })
    truthy(ok, "placed")
    eq(env.DATA.tasks[8].assignedTo, 1, "the miner, though the scout was nearer: a scout cannot dig its way out")
end)

test("TaskMan.pickDrone offers the job to a drone that can afford it", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 1000, pos = { x = 0, y = 64, z = 0 } },
        { id = 2, name = "D2", role = "miner", status = "working", fuel = 1000, pos = { x = 0, y = 64, z = 0 } },
    })
    local drone = T.pickDrone("miner", { x = 50, y = 64, z = 0 }, nil, 288)
    truthy(drone, "a drone is picked")
    eq(drone.name, "D1", "the idle one")
end)

test("TaskMan: while the fleet is low, a haul and a plant are still placeable", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 300, pos = { x = 0, y = 64, z = 0 } },
    }, {})
    falsy(T.notPlaceableNow({ id = 1, name = "haul:0,64,0", work = { haul = { pos = {} } } }, "any", {}), "haul")
    falsy(T.notPlaceableNow({ id = 2, name = "plant:grove-01", work = { plant = { spots = {} } } }, "any", {}), "plant")
    falsy(T.notPlaceableNow({ id = 3, name = "lumber:oak_log", work = { lumber = {} } }, "miner", {}), "lumber is fuel work")
end)

test("TaskMan: while the fleet is low, a crafter's job is placeable and a miner's non-fuel job is held", function()
    local _, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 300, pos = { x = 0, y = 64, z = 0 } },
        { id = 2, name = "D4", role = "crafter", status = "docking", fuel = 1200, pos = { x = 0, y = 64, z = 0 } },
    }, {})
    falsy(T.notPlaceableNow({ id = 4, name = "craft-stone_bricks", work = { craft = {} } }, "crafter", {}), "a craft costs no fuel anyone else could use")
    truthy(T.notPlaceableNow({ id = 5, name = "dig:stone", work = { mine = { pos = {} } } }, "miner", {}), "a miner's dig waits for fuel work")
    falsy(T.notPlaceableNow({ id = 6, name = "tower-L0-3", work = { build = { origin = {} } } }, "miner", {}), "a build of stocked bricks is placeable; anyoneForBuild hands it on")
end)

test("TaskMan: outside an emergency, a third fuel job waits while two miners already fell or mine", function()
    local env, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "working", fuel = 1500, pos = { x = 0, y = 64, z = 0 } },
        { id = 2, name = "D2", role = "miner", status = "working", fuel = 1500, pos = { x = 0, y = 64, z = 0 } },
        { id = 3, name = "D3", role = "miner", status = "idle", fuel = 1500, pos = { x = 0, y = 64, z = 0 } },
    }, { { name = "minecraft:coal", count = 500 } })
    env.DATA.tasks = {
        [1] = { id = 1, name = "lumber:oak_log", work = { lumber = {} }, assignedTo = 1, progress = 0 },
        [2] = { id = 2, name = "gather:coal_ore", work = { gather = {} }, assignedTo = 2, progress = 0 },
    }
    truthy(T.notPlaceableNow({ id = 3, name = "lumber:oak_log", work = { lumber = {} } }, "miner", {}), "third fuel job waits")
    falsy(T.notPlaceableNow({ id = 4, name = "tower-L2-p1", work = { build = { origin = {} } } }, "miner", {}), "the build goes")
end)

-- ================================================================================================
-- StorageMan
-- ================================================================================================
local function storageWithChests()
    local env, S = loadModule("StorageMan.lua")
    local w = env.__world
    -- Two networked chests and a furnace on the wire; one cache chest off it.
    w.addInventory("minecraft:chest_0", "minecraft:chest", { [1] = { name = "minecraft:coal", count = 7 } }, 27)
    w.addInventory("minecraft:chest_1", "minecraft:chest", { [1] = { name = "minecraft:oak_log", count = 5 } }, 27)
    w.addInventory("minecraft:furnace_0", "minecraft:furnace", {}, 3)
    env.DATA.deposits = {
        { pos = { x = -476, y = 64, z = 78 }, peripheral = "minecraft:chest_0" },
        { pos = { x = -476, y = 64, z = 78 } },                                    -- the unbound twin
        { pos = { x = -475, y = 64, z = 78 }, peripheral = "minecraft:chest_1" },
        { pos = { x = -520, y = 63, z = 34 } },                                    -- a field cache
    }
    env.DATA.chestAt = {
        ["-520:63:34"] = { pos = { x = -520, y = 63, z = 34 }, items = {}, used = 0, size = 27 },
    }
    return env, S
end

test("StorageMan loads under the stub world and indexes the wire", function()
    local env = storageWithChests()
    truthy(env.Rescan(), "Rescan succeeds")
    eq(env.m_Index["minecraft:coal"].total, 7, "coal indexed")
    eq(env.m_Free["minecraft:chest_0"], 26, "free slots counted")
end)

test("StorageMan.dedupeDeposits drops a bound chest's unbound twin", function()
    local env, S = storageWithChests()
    S.dedupeDeposits()
    eq(#env.DATA.deposits, 3, "one twin dropped, networked and cache entries kept")
    for _, d in ipairs(env.DATA.deposits) do
        if d.pos.x == -476 then truthy(d.peripheral, "the surviving -476 entry is the bound one") end
    end
end)

test("StorageMan.OnDepositPoint: no site -> a networked chest, never the emptier cache", function()
    local env = storageWithChests()
    local ok, r = env.OnDepositPoint(1, { data = {} })
    truthy(ok, "answered")
    truthy(r.peripheral, "a networked chest: " .. stubs.toJSON(r))
end)

test("StorageMan.OnDepositPoint: a site near the cache does not change that", function()
    local env = storageWithChests()
    local ok, r = env.OnDepositPoint(1, { data = { near = { x = -518, y = 64, z = 34 } } })
    truthy(ok, "answered")
    truthy(r.peripheral, "still a networked chest: " .. stubs.toJSON(r))
end)

test("StorageMan.OnWhereIs answers from the wire before any memory", function()
    local env = storageWithChests()
    env.DATA.chestAt["-520:63:34"].items = { ["minecraft:coal"] = 64 }   -- a stale memory of coal far away
    local ok, r = env.OnWhereIs(1, { data = { match = "coal" } })
    truthy(ok, "found")
    eq(r.source, "peripheral", "source")
    eq(r.pos.x, -476, "the networked chest holding the coal")
end)

test("StorageMan.OnWhereIs lists every holder, most-held first, so the drone need not sweep the bay", function()
    local env = storageWithChests()
    -- Bricks smeared across two chests -- one order's worth split, more in chest_1 than chest_0.
    env.__world.peripherals["minecraft:chest_0"].api.__inv.items[1] = { name = "minecraft:stone_bricks", count = 20 }
    env.__world.peripherals["minecraft:chest_1"].api.__inv.items[1] = { name = "minecraft:stone_bricks", count = 51 }
    env.Rescan()
    local ok, r = env.OnWhereIs(1, { data = { match = "stone_bricks" } })
    truthy(ok, "found")
    truthy(type(r.places) == "table" and #r.places >= 2, "lists both holders, not just one (" .. #(r.places or {}) .. ")")
    eq(r.places[1].count, 51, "most-held chest first so the order fills in the fewest stops")
    truthy(r.places[1].count >= r.places[2].count, "descending by count")
end)

test("StorageMan.ServiceSort consolidates each item into one home chest -- one item per chest", function()
    local env, S = storageWithChests()
    env.SORT_ENABLED = true              -- the sorter is off by default during the bootstrap; this tests the sorter itself
    -- chest_0 holds the bulk of the bricks; chest_1 has a few bricks IN FRONT of its coal -- exactly
    -- the buried-item shape that made a fetch return one stack.
    env.__world.peripherals["minecraft:chest_0"].api.__inv.items = {
        [1] = { name = "minecraft:stone_bricks", count = 64 } }
    env.__world.peripherals["minecraft:chest_1"].api.__inv.items = {
        [1] = { name = "minecraft:stone_bricks", count = 20 }, [2] = { name = "minecraft:coal", count = 64 } }
    env.Rescan()
    S.ServiceSort()
    local kinds = function(l) local k = {} for _, it in pairs(l) do k[it.name] = (k[it.name] or 0) + it.count end return k end
    local k0 = kinds(env.__world.peripherals["minecraft:chest_0"].api.list())
    local k1 = kinds(env.__world.peripherals["minecraft:chest_1"].api.list())
    truthy(k0["minecraft:coal"] == nil, "no coal in the brick chest")
    truthy(k1["minecraft:stone_bricks"] == nil, "no bricks in the coal chest")
    eq(k0["minecraft:stone_bricks"], 84, "all bricks consolidated into their home chest")
    eq(k1["minecraft:coal"], 64, "coal alone in its own chest")
end)

test("StorageMan.ServiceSort leaves the pickup/handover chest alone so Provide's push survives", function()
    local env, S = storageWithChests()
    -- Bricks smeared: bulk in chest_0, a handover load pushed into chest_1. Without the guard the
    -- sort drags chest_1's bricks into chest_0's home before the drone collects -> "short".
    env.__world.peripherals["minecraft:chest_0"].api.__inv.items = { [1] = { name = "minecraft:stone_bricks", count = 64 } }
    env.__world.peripherals["minecraft:chest_1"].api.__inv.items = { [1] = { name = "minecraft:stone_bricks", count = 20 } }
    env.DATA.pickup = { pos = { x = -475, y = 64, z = 78 }, peripheral = "minecraft:chest_1" }
    env.Rescan()
    S.ServiceSort()
    local kinds = function(l) local k = {} for _, it in pairs(l) do k[it.name] = (k[it.name] or 0) + it.count end return k end
    local k1 = kinds(env.__world.peripherals["minecraft:chest_1"].api.list())
    eq(k1["minecraft:stone_bricks"], 20, "the pickup keeps its handover load -- sort must not empty it")
end)

test("StorageMan.assignHomes gives each item its own chest -- the bigger item keeps a contested one", function()
    local env, S = storageWithChests()
    -- Both items have their majority in chest_0; only the larger may keep it.
    env.m_Index = {
        ["minecraft:stone_bricks"] = { total = 100, at = { { where = "minecraft:chest_0", slot = 1, count = 100 } } },
        ["minecraft:coal"]         = { total = 40,  at = { { where = "minecraft:chest_0", slot = 2, count = 40 } } },
    }
    local home = S.assignHomes()
    eq(home["minecraft:stone_bricks"], "minecraft:chest_0", "the bigger item keeps the contested chest")
    truthy(home["minecraft:coal"] ~= "minecraft:chest_0", "the smaller item does not share it")
end)

test("StorageMan.OnChestContents binds a one-item chest by type even when the count has drifted", function()
    local env = loadModule("StorageMan.lua")
    local w = env.__world
    w.addInventory("minecraft:chest_0", "minecraft:chest", { [1] = { name = "minecraft:stone_bricks", count = 164 } }, 27)
    w.addInventory("minecraft:chest_1", "minecraft:chest", { [1] = { name = "minecraft:coal", count = 40 } }, 27)
    env.DATA.deposits, env.DATA.chestName = {}, {}
    env.Rescan()
    -- The drone read the same chest a few ticks earlier, before the sort topped it up: 100 vs 164.
    -- Exact-count matching bound nothing here and left every build throwing "would not hand over".
    env.OnChestContents(5, { data = { at = { x = -478, y = 64, z = 78 }, items = { ["minecraft:stone_bricks"] = 100 } } })
    eq(env.DATA.chestName["-478:64:78"], "minecraft:chest_0", "bound to the only brick chest despite the drift")
    local bound
    for _, d in ipairs(env.DATA.deposits) do if d.peripheral == "minecraft:chest_0" then bound = d end end
    truthy(bound and bound.pos.x == -478, "a deposit point carrying the network name was registered")
end)

test("StorageMan.OnChestContents will NOT bind by type while the item is smeared across two chests", function()
    local env = loadModule("StorageMan.lua")
    local w = env.__world
    w.addInventory("minecraft:chest_0", "minecraft:chest", { [1] = { name = "minecraft:stone_bricks", count = 64 } }, 27)
    w.addInventory("minecraft:chest_1", "minecraft:chest", { [1] = { name = "minecraft:stone_bricks", count = 30 } }, 27)
    env.DATA.deposits, env.DATA.chestName = {}, {}
    env.Rescan()
    env.OnChestContents(5, { data = { at = { x = -478, y = 64, z = 78 }, items = { ["minecraft:stone_bricks"] = 100 } } })
    truthy(env.DATA.chestName["-478:64:78"] == nil, "ambiguous type set -> no binding until the sort makes them one")
end)

test("StorageMan: fuel before furniture -- wood smelts while fuel is short", function()
    local env, S = storageWithChests()
    env.Rescan()
    -- 7 coal on the shelf is under SMELT_FUEL_RESERVE (32): the crafting reserve yields.
    eq(S.smeltAllowance("minecraft:oak_log", env.m_Index["minecraft:oak_log"]), 5, "all five logs allowed")
    falsy(S.reservedForCrafting("minecraft:oak_log", env.m_Index["minecraft:oak_log"]), "not reserved")
    -- With plenty of fuel the sixteen-log crafting reserve is back.
    env.__world.peripherals["minecraft:chest_0"].api.__inv.items[1].count = 64
    env.Rescan(true)   -- contents changed under a fresh scan: a caller that just moved stacks forces it
    eq(S.smeltAllowance("minecraft:oak_log", env.m_Index["minecraft:oak_log"]), 0, "5 - 16 reserve -> nothing to smelt")
end)

test("StorageMan.fillFor: the fuel face takes wood when there is no dense fuel", function()
    local env, S = storageWithChests()
    env.__world.peripherals["minecraft:chest_0"].api.__inv.items[1] = nil     -- no coal anywhere
    env.Rescan()
    local e, batch = S.fillFor(false)
    truthy(e, "something to burn")
    eq(e.at[1].where, "minecraft:chest_1", "the logs")
    eq(batch, 2, "two logs, not a stack")
end)

test("StorageMan.fillFor: dense fuel first when it exists", function()
    local env, S = storageWithChests()
    env.Rescan()
    local e, batch = S.fillFor(false)
    eq(e.at[1].where, "minecraft:chest_0", "the coal")
    eq(batch, 16, "a normal batch")
end)

test("StorageMan.OnDepositPoint spreads seven askers over the roomy chests instead of one", function()
    local env = storageWithChests()
    local picks = {}
    for id = 40, 46 do
        local ok, r = env.OnDepositPoint(id, { data = {} })
        truthy(ok, "asker " .. id .. " got a point")
        local k = r.peripheral or tostring(r.pos.x)
        picks[k] = (picks[k] or 0) + 1
    end
    local distinct = 0
    for _ in pairs(picks) do distinct = distinct + 1 end
    truthy(distinct >= 2, "two networked chests with room, seven askers: both get used (" .. distinct .. ")")
end)

-- ================================================================================================
-- DroneLogic
-- ================================================================================================
test("DroneLogic loads under the stub world", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    truthy(env.TravelTo, "TravelTo defined")
    truthy(env.FuelFloorNow, "FuelFloorNow defined")
    truthy(D.setHome, "test hook exports setHome")
end)

test("DroneLogic: wood families -- logs and planks burn, saplings never", function()
    local env = loadModule("DroneLogic.lua")
    eq(env.WoodFamily("minecraft:birch_sapling"), "sapling", "sapling family")
    truthy(env.IsBurnableWood("minecraft:oak_log"), "log burns")
    truthy(env.IsBurnableWood("minecraft:spruce_planks"), "planks burn")
    falsy(env.IsBurnableWood("minecraft:oak_sapling"), "sapling does not")
    falsy(env.IsBurnableWood("minecraft:coal"), "coal is not wood")
    truthy(env.SameItem("minecraft:oak_sapling", "minecraft:birch_sapling"), "any sapling matches a sapling")
end)

test("DroneLogic.FuelFloorNow is the trip home plus a margin and nothing else", function()
    local env, D = loadModule("DroneLogic.lua", { pos = { x = 30, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })
    eq(env.FuelFloorNow(), 30 * 3 + 120, "30 blocks out")
    env.__world.pos = { x = 0, y = 64, z = 0 }
    eq(env.FuelFloorNow(), 120, "at home")
end)

test("DroneLogic.BurnAboard burns dense fuel up to the target and keeps the rest", function()
    local env = loadModule("DroneLogic.lua", { fuel = 500 })
    env.__world.turtle.inv[1] = { name = "minecraft:coal", count = 20 }
    local gained = env.BurnAboard()
    eq(gained, 14 * 80, "fourteen coal to pass 1,600")
    eq(env.turtle.getFuelLevel(), 500 + 14 * 80, "tank")
    eq(env.turtle.getItemCount(1), 6, "six coal kept for storage")
end)

test("DroneLogic.BurnAboard does not eat wood unless the drone would strand", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })                    -- floor 150: 500 is comfortably above it
    env.__world.turtle.inv[1] = { name = "minecraft:oak_log", count = 20 }
    eq(env.BurnAboard(), 0, "logs kept for the furnace")
    env.__world.turtle.fuel = 100                          -- below the floor: survival
    truthy(env.BurnAboard() > 0, "now it burns")
end)

test("DroneLogic.BurnAboard leaves a relief payload alone above the floor", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 800, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })
    env.__world.turtle.inv[1] = { name = "minecraft:coal", count = 28 }
    D.setRelieving(true)
    eq(env.BurnAboard(), 0, "the payload is not lunch")
    env.__world.turtle.fuel = 50
    truthy(env.BurnAboard() > 0, "but it will not strand itself over it")
end)

test("DroneLogic.TravelTo: one coroutine owns the turtle; the other is told busy", function()
    local env = loadModule("DroneLogic.lua")
    falsy(env.TravelIsBusy(), "nobody travelling")
    -- A coroutine that starts a journey and parks mid-way.
    local owner = coroutine.create(function()
        env.TravelOwner = coroutine.running()
        coroutine.yield()
    end)
    coroutine.resume(owner)
    truthy(env.TravelIsBusy(), "busy from the outside")
    local ok, why = env.TravelTo(1, 64, 1)
    eq(ok, false, "refused")
    eq(why, "travel busy", "reason")
    coroutine.resume(owner)                                -- finish it
    env.TravelOwner = nil
    falsy(env.TravelIsBusy(), "free again")
end)

test("DroneLogic.FellTrunkAt fells the whole column from the side and climbs it", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000, pos = { x = 0, y = 64, z = 0 } })
    D.setExecuting(true)                                  -- felling happens inside a job
    local t = env.__world.turtle
    -- A trunk: one log in front that disappears when dug, then a column of three above the base.
    -- Height matters: the block overhead is the one at y+1 for the drone's CURRENT y, so digging up
    -- once removes one log and the next is only reachable after moving up -- as in the world.
    local front, y = true, 64
    local column = { [65] = true, [66] = true, [67] = true }
    t.detect = function() return front end
    t.inspect = function() if front then return true, { name = "minecraft:oak_log" } end return false end
    t.dig = function() front = false return true end
    t.detectUp = function() return column[y + 1] == true end
    t.inspectUp = function() if column[y + 1] then return true, { name = "minecraft:oak_log" } end return false end
    t.digUp = function() column[y + 1] = nil return true end
    env.pgps.up = function() y = y + 1 return true end
    env.pgps.down = function() y = y - 1 return true end
    local logs, why = env.FellTrunkAt({ x = 5, y = 64, z = 5 })
    eq(why, nil, "no failure reason")
    eq(logs, 4, "the base log plus three overhead")
end)

test("DroneLogic.FellTrunkAt reports a trunk that is gone and observes the air", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    D.setExecuting(true)                                  -- felling happens inside a job
    local observed = {}
    env.pgps.noteObservation = function(idx, solid) observed[#observed + 1] = idx .. "=" .. tostring(solid) end
    local logs, why = env.FellTrunkAt({ x = 5, y = 64, z = 5 })
    eq(logs, 0, "nothing felled")
    eq(why, "gone", "reason")
    eq(#observed, 3, "the foot and the two cells above it were recorded as air")
    eq(observed[1], "5:64:5=0", "first observation")
end)

-- The dig-coverage plateau (2026-09-07): OnDig serpentines a layer trusting row/col COUNTERS, but a
-- mid-dig deposit flies the drone to storage and does not bring it back, so every cell after the
-- first pack-fill was cut from wherever storage left it -- the room hollowed only ~57%, as scattered
-- single cells. DepositKeepingPlace is the fix: deposit, then return to the exact cell + heading.
-- getFuelLevel -> "unlimited" makes depositIfFull skip its own position reads, so the two
-- getCachedPosition calls the helper makes are deterministically calls 1 (before) and 2 (after).
test("DroneLogic.DepositKeepingPlace digs back to the exact cell + heading after a deposit flies the drone off", function()
    local env = loadModule("DroneLogic.lua", { fuel = 5000 })
    env.__world.turtle.getFuelLevel = function() return "unlimited" end
    local n, origin, moved = 0, { -488, 62, 56, 1 }, { -476, 64, 78, 3 }
    env.pgps.getCachedPosition = function()
        n = n + 1
        local q = (n == 1) and origin or moved            -- as if Deposit() flew us to a chest
        return q[1], q[2], q[3], q[4]
    end
    local digTos, turns = {}, {}
    env.pgps.digTo = function(x, y, z) digTos[#digTos + 1] = { x, y, z } return true end
    env.pgps.turnTo = function(d) turns[#turns + 1] = d return true end
    truthy(env.DepositKeepingPlace(), "deposit reported success")
    eq(#digTos, 1, "dug back to the abandoned cell exactly once")
    eq(digTos[1][1], -488, "returned to origin x")
    eq(digTos[1][2], 62, "returned to origin y")
    eq(digTos[1][3], 56, "returned to origin z")
    eq(turns[1], 1, "restored the original heading")
end)

test("DroneLogic.DepositKeepingPlace does not travel when the pack never filled (no phantom dig-back)", function()
    local env = loadModule("DroneLogic.lua", { fuel = 5000 })
    env.__world.turtle.getFuelLevel = function() return "unlimited" end
    local digTos = 0
    env.pgps.digTo = function() digTos = digTos + 1 return true end
    truthy(env.DepositKeepingPlace(), "reported success")
    eq(digTos, 0, "no dig-back when the drone never left its cell")
end)

-- The basement never got dug (2026-09-07): its box is fully BURIED (surface y63, box top y62), so the
-- cell ReachSite lands on (pos.y+1 = ground) is solid and every face around it is rock. ApproachFromSide
-- then flailed for an open face that cannot exist and JitterWatch aborted the job at the dock. A dig job
-- must dig straight in; the planner's cost still prefers open air for the descent.
test("DroneLogic.ReachSite digs straight into a buried dig site instead of flailing at its faces", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 5000, pos = { x = -490, y = 75, z = 66 } })
    D.setExecuting(true)
    env.peripheral.getType = function() return nil end       -- a miner (both slots free) -> CanDig()
    local moves = 0
    env.pgps.moveTo = function() moves = moves + 1 return false end   -- the cell above the box is solid ground
    local digTo = nil
    env.pgps.digTo = function(x, y, z) digTo = { x, y, z } return true end
    local at = env.ReachSite(-488, 62, 56, true)             -- digIn = true (a dig job)
    truthy(at, "reached the buried site")
    -- Two moveTo calls: the cell above the box, then the fly-over of its column (both solid here).
    -- Neither is a face-by-face flail.
    eq(moves, 2, "tried the open route and the column fly-over, then did NOT flail across the faces")
    truthy(digTo, "dug straight in")
    eq(digTo[1], -488, "dug to the box corner x")
    eq(digTo[2], 63, "dug to the cell on top of the box (pos.y+1)")
    eq(digTo[3], 56, "dug to the box corner z")
end)

test("DroneLogic.PlantSaplingAt plants on soil from one above, and not on stone", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local t = env.__world.turtle
    t.inv[1] = { name = "minecraft:oak_sapling", count = 4 }
    t.inspectDown = function() return true, { name = "minecraft:grass_block" } end
    local placed = 0
    t.placeDown = function() placed = placed + 1 t.inv[1].count = t.inv[1].count - 1 return true end
    truthy(env.PlantSaplingAt({ x = 3, y = 64, z = 3 }), "planted on grass")
    eq(placed, 1, "one sapling placed")
    t.inspectDown = function() return true, { name = "minecraft:stone" } end
    falsy(env.PlantSaplingAt({ x = 4, y = 64, z = 3 }), "not on stone")
    eq(placed, 1, "nothing more placed")
end)

-- ================================================================================================
-- pgps
-- ================================================================================================
test("pgps loads under the stub world", function()
    local env = loadModule("pgps.lua")
    truthy(env.setLocation, "setLocation defined")
    truthy(env.moveTo, "moveTo defined")
end)

test("pgps.savedHeading reads the last facing off the pose file", function()
    local env = loadModule("pgps.lua")
    local h = env.fs.open("/pgps-pose.txt", "w") h.write("10 64 20 2") h.close()
    eq(env.savedHeading(), 2, "heading read back from disk")
    env.fs.delete("/pgps-pose.txt")
    eq(env.savedHeading(), nil, "no file -> nil")
end)

test("pgps.setLocationFromGPS keeps the saved heading when boxed in -- it must not boot with heading nil", function()
    local env = loadModule("pgps.lua")
    -- A GPS fix gives position, but the drone is walled in on every side so it cannot step out to
    -- re-derive its facing. Without the saved-pose fallback it came out of boot with heading nil,
    -- unable to turn toward anything -- the "blocked by something unidentified" wedge on D4 alone.
    env.__world.gps = { x = 10, y = 64, z = 20 }
    env.turtle.forward = function() return false end
    local h = env.fs.open("/pgps-pose.txt", "w") h.write("10 64 20 2") h.close()
    env.setLocationFromGPS()
    local x, _, _, d = env.getCachedPosition()
    eq(x, 10, "position came from the GPS fix")
    truthy(d ~= nil, "heading is NOT nil -- it was kept from the saved pose")
    eq(d, 2, "and it is the facing we last wrote down")
end)

test("pgps.setLocation with no heading keeps the heading it has", function()
    local env = loadModule("pgps.lua")
    env.setLocation(1, 2, 3, "north")
    local x, y, z, d = env.getCachedPosition()
    eq(x, 1, "x") eq(d, env.HEADINGS.north, "heading set")
    local rx, ry, rz, rd = env.setLocation(10, 20, 30, nil)
    eq(rx, 10, "position moved") eq(rd, env.HEADINGS.north, "heading kept")
    local _, _, _, d2 = env.getCachedPosition()
    eq(d2, env.HEADINGS.north, "still north")
end)

test("pgps.verifyPosition adopts a one-block disagreement at once -- there is no GPS noise to filter", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 1, y = 64, z = 0 }
    local ok, drift = env.verifyPosition(true)
    truthy(ok, "fix") eq(drift, 1, "drift")
    eq((env.getCachedPosition()), 1, "adopted on the first fix")
end)

test("pgps.verifyPosition discards a fix taken while something else moved the turtle", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    -- The hosts answer while another coroutine steps us one block south: the race D54 lived in.
    local realLocate = env.gps.locate
    env.gps.locate = function(...) env.noteExternalStep(0, 0, 1) return realLocate(...) end
    local ok, why = env.verifyPosition(true)
    eq(ok, nil, "not a fix") eq(why, "moved during the fix", "and it says so")
    local x, y, z = env.getCachedPosition()
    eq(z, 1, "the step that really happened is kept; the stale fix is not adopted")
    truthy(not env.positionVerified(), "a discarded fix does not count as a fix")
    env.gps.locate = realLocate
    env.__world.gps = { x = 0, y = 64, z = 1 }
    truthy(env.verifyPosition(true), "the next undisturbed fix is accepted")
    truthy(env.positionVerified(), "and counts")
end)

test("pgps.flyTo defers a blocked line to the router when told not to climb -- the wall-rubbing fix", function()
    local env, T = loadModule("pgps.lua")
    -- A wall on every horizontal face: forward never advances. Vertical is open.
    local ups
    env.turtle.forward = function() return false end
    env.turtle.up = function() ups = ups + 1 return true end
    env.turtle.down = function() return true end

    -- Without _noClimb, flyTo climbs over the wall and bounces up/down until the step budget runs
    -- out -- the behaviour that rubbed the tower for a whole replan.
    env.setLocation(0, 64, 0, "north")
    ups = 0
    local ok1 = T.flyTo(5, 64, 0, 12, false)
    eq(ok1, false, "cannot reach through a wall")
    truthy(ups >= 5, "climbing flyTo went up the wall many times (" .. ups .. ")")

    -- With _noClimb (what localHop passes), the first blocked step bails at once, so moveLegRaw asks
    -- the shared pathfinder for a route AROUND the wall instead of grinding against it.
    env.setLocation(0, 64, 0, "north")
    ups = 0
    local ok2, why2 = T.flyTo(5, 64, 0, 12, true)
    eq(ok2, false, "still cannot walk through the wall")
    eq(ups, 0, "but it never climbed -- it deferred to the router")
    truthy(tostring(why2):find("router"), "and says why: " .. tostring(why2))
end)

test("pgps.localHop hands a blocked short hop to the router rather than climbing blind", function()
    local env, T = loadModule("pgps.lua")
    local ups = 0
    env.turtle.forward = function() return false end
    env.turtle.up = function() ups = ups + 1 return true end
    env.setLocation(0, 64, 0, "north")
    -- Within PATH_LOCAL_RADIUS but blocked: localHop must NOT climb (that is the wall-rubber). It
    -- returns false so moveLegRaw falls through to the GetPath request.
    local ok = T.localHop(3, 64, 0, 3)
    eq(ok, false, "a blocked local hop fails instead of climbing")
    eq(ups, 0, "and never climbed the wall")
end)

test("pgps.verifyPosition refuses a fix while a move is in flight, whoever asks", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    local inner
    -- turtle.forward() puts the turtle in the next block and only then yields for eight ticks; the
    -- refix loop's fix lands in that window. Here the stub is the window.
    env.turtle.forward = function()
        env.__world.gps = { x = 0, y = 64, z = -1 }
        inner = { env.verifyPosition(true) }
        return true
    end
    truthy(env.forward(), "tracked step")
    eq(inner[1], nil, "the mid-move fix is refused") eq(inner[2], "moving", "and says why")
    local _, _, z = env.getCachedPosition()
    eq(z, -1, "the step is committed once, by the mover")
    local ok, drift = env.verifyPosition(true)
    truthy(ok, "a fix between moves is accepted") eq(drift, 0, "and agrees with the bookkeeping")
end)

test("pgps: a step commits its own delta, so another routine's step in flight is not lost", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    -- While our forward step is in flight, another coroutine commits a step east.
    env.turtle.forward = function() env.noteExternalStep(1, 0, 0) return true end
    truthy(env.forward(), "our step")
    local x, _, z = env.getCachedPosition()
    eq(x, 1, "the other routine's step is kept") eq(z, -1, "and so is ours")
end)

test("pgps: the travel audit does not rotate the heading after a run that turned", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 0, y = 64, z = 0 }
    truthy(env.verifyPosition(true), "anchor the audit")
    env.turtle.forward = function() return true end
    truthy(env.forward(), "one north")                        -- intent (0,0,-1)
    truthy(env.turnRight(), "turn")                           -- now east
    truthy(env.forward(), "one east")                         -- intent (1,0,-1)
    env.__world.gps = { x = 1, y = 64, z = 0 }                -- GPS says the north step never happened
    env.verifyPosition(true)
    local _, _, _, d = env.getCachedPosition()
    eq(d, env.HEADINGS.east, "the heading is kept: a turned run cannot be inverted")
end)

test("pgps.ensureHeading reads the heading from a clean probe step and refuses one disturbed by another mover", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.__world.gps = { x = 1, y = 64, z = 0 }                 -- the step out lands one block east
    truthy(env.ensureHeading(true), "clean probe")
    local _, _, _, d = env.getCachedPosition()
    eq(d, env.HEADINGS.east, "heading read from the step")
    local realLocate = env.gps.locate
    env.gps.locate = function(...) env.noteExternalStep(0, 1, 0) return realLocate(...) end
    local ok, why = env.ensureHeading(true)
    eq(ok, false, "disturbed probe refused") eq(why, "moved during the probe", "and it says why")
    local _, _, _, d2 = env.getCachedPosition()
    eq(d2, env.HEADINGS.east, "the heading we had is kept")
end)

test("TaskMan.noDroneReason survives a fractional fuel need", function()
    local env, T = loadModule("TaskMan.lua")
    local why = T.noDroneReason("miner", nil, { name = "D31", fuel = 190 }, 255.5)
    truthy(why:find("~255"), "the need is reported whole: " .. why)
    truthy(why:find(env.UNAFFORDABLE, 1, true), "and named as unaffordable")
    local far = T.noDroneReason("miner", nil, { name = "D31", fuel = 190 }, math.huge)
    truthy(far:find("unknown", 1, true), "an infinite need (no position) is said in words: " .. far)
    local nan = T.noDroneReason("miner", nil, { name = "D31", fuel = 190 }, 0/0)
    truthy(nan:find("unknown", 1, true), "so is a NaN: " .. nan)
end)

test("DroneLogic.RefuelAtStorage asks storage over the network and does not fly to an empty shelf", function()
    local env = loadModule("DroneLogic.lua", { fuel = 300 })
    env.__world.replies.StorageMan = env.__world.replies.StorageMan or {}
    env.__world.replies.StorageMan.GetStock = { detail = { { name = "minecraft:stone", count = 800 } } }
    env.__world.replies.StorageMan.DepositPoint = { pos = { x = 0, y = 64, z = 0 } }
    local moves = 0
    local counted = function() moves = moves + 1 return true end
    env.pgps.moveTo, env.pgps.flyTo, env.pgps.digTo, env.pgps.forward = counted, counted, counted, counted
    env.RefuelAtStorage()
    eq(moves, 0, "no flight to a shelf the network says is dry")
    truthy(env.StorageKnownDry(nil), "and the shelf is marked dry for the others")
end)

test("DroneLogic.CollectFuel: a shelf at or below its reserve gives a working tank, not a full one, and nothing to a full drone", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000, pos = { x = 0, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })
    env.__world.replies.StorageMan = env.__world.replies.StorageMan or {}
    env.__world.replies.StorageMan.GetStock = { detail = { { name = "minecraft:coal", count = 100 } } }
    local got, why = D.collectFuel()
    eq(got, 0, "a drone at 1000 takes nothing") truthy(why:find("reserve", 1, true), "and is told why: " .. why)
    eq(env.ShelfAllowance(100), 0, "allowance 0 at 1000 fuel")
    env.__world.turtle.fuel = 300                            -- above its floor, below a working tank
    eq(env.ShelfAllowance(100), 4, "300 -> 600 is four coal")
    env.__world.turtle.fuel = 50                             -- below the floor: unlimited
    eq(env.ShelfAllowance(100), nil, "survival is not rationed")
    env.__world.turtle.fuel = 1000
    D.setRelieving(true)
    eq(env.ShelfAllowance(100), nil, "a reliever is not rationed")
    D.setRelieving(false)
    eq(env.ShelfAllowance(500), nil, "above the reserve nobody is rationed")
end)

test("DroneLogic: an executing flag with no job and no movement is cleared by the heartbeat", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500 })
    D.setExecuting(true)                                       -- a GoTo that never reached TaskEnd
    env.SendHeartBeat()
    truthy(D.isExecuting(), "first sighting: kept")
    env.__world.clock = env.__world.clock + 400
    env.SendHeartBeat()
    truthy(not D.isExecuting(), "still there 400 s later with no job: cleared")
end)

test("DroneLogic.FetchSkip: searches reachable chests (networked or near bay), skips far caches", function()
    local env = loadModule("DroneLogic.lua")
    local wantsCoal = function(nm) return nm == "minecraft:coal" end
    truthy(env.FetchSkip({ pos = { x = -480, y = 8, z = 87 } }, wantsCoal), "a FAR position-only cache (~79 blocks out) is skipped -- no stranding")
    falsy(env.FetchSkip({ pos = { x = -478, y = 64, z = 74 } }, wantsCoal), "a NEAR position-only bay chest (unknown contents) IS searched -- its network binding may have gone stale")
    truthy(env.FetchSkip({ pos = {}, peripheral = "minecraft:chest_0", items = { ["minecraft:stone"] = 64 } }, wantsCoal), "a chest known to hold none is skipped")
    falsy(env.FetchSkip({ pos = {}, peripheral = "minecraft:chest_1" }, wantsCoal), "a networked chest of unknown contents is searched")
    falsy(env.FetchSkip({ pos = {}, peripheral = "minecraft:chest_2", items = { ["minecraft:coal"] = 3 } }, wantsCoal), "a chest known to hold it is searched")
end)

test("DroneLogic.FuelAllowsAnotherTarget: a gather leaves when the tank is the trip home plus one approach", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })                    -- floor 150 here
    truthy(env.FuelAllowsAnotherTarget(), "500 > 150 + 60")
    env.__world.turtle.fuel = 200
    falsy(env.FuelAllowsAnotherTarget(), "200 is not 150 + 60")
end)

test("DroneLogic.FellTargets stops at an abort and when the tank is the trip home", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 10, y = 64, z = 0 } })
    D.setHome({ x = 0, y = 64, z = 0 })                    -- floor 150 here
    local calls = 0
    env.FellTrunkAt = function() calls = calls + 1 return 1 end
    local targets = { { x = 1, y = 64, z = 1 }, { x = 2, y = 64, z = 2 }, { x = 3, y = 64, z = 3 } }
    D.setExecuting(false)
    env.FellTargets(targets)
    eq(calls, 0, "an aborted job fells nothing more")
    D.setExecuting(true)
    env.FellTargets(targets)
    eq(calls, 3, "a live job with fuel works the list")
    env.__world.turtle.fuel = 160                          -- floor 150 + 40 for the next approach: short
    env.FellTargets(targets)
    eq(calls, 3, "the trip-home tank is not spent on another target")
end)

test("DroneLogic.ApproachFromSide gives up after the fuel cap instead of trying every side", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 500, pos = { x = 0, y = 64, z = 0 } })
    D.setExecuting(true)
    local movers = 0
    local burn = function() movers = movers + 1 env.__world.turtle.fuel = env.__world.turtle.fuel - 30 return false end
    env.pgps.moveTo, env.pgps.flyTo, env.pgps.digTo = burn, burn, burn
    local ok, why = env.ApproachFromSide({ x = 5, y = 70, z = 5 })
    eq(ok, false, "unreachable") eq(why, "too costly", "and it says why")
    truthy(movers <= 6, "one side's movers, not four sides' (" .. movers .. ")")
    truthy(500 - env.__world.turtle.fuel <= 200, "bounded burn")
    D.setExecuting(false)
    movers = 0
    local ok2, why2 = env.ApproachFromSide({ x = 5, y = 70, z = 5 })
    eq(ok2, false, "aborted") eq(why2, "aborted", "an abort ends it before the first mover") eq(movers, 0, "no movers")
end)

test("DroneLogic.ConfirmHeading does not step the turtle while another coroutine owns travel", function()
    local env = loadModule("DroneLogic.lua")
    local probes = 0
    env.pgps.ensureHeading = function() probes = probes + 1 return true end
    env.TravelOwner = coroutine.create(function() coroutine.yield() end)   -- alive, not us
    eq(env.ConfirmHeading(), false, "refused under a traveller")
    eq(probes, 0, "no probe step")
    env.TravelOwner = nil
    env.ConfirmHeading()
    eq(probes, 1, "probes once the drone is ours to move")
end)

-- ================================================================================================
local failed = 0
for _, r in ipairs(results) do if not r.ok then failed = failed + 1 end end

-- PowGPSServer: the planner's dig cost
test("PowGPSServer: with digging allowed the planner still walks around a wall it could cut through", function()
    local env = loadModule("PowGPSServer.lua")
    -- A wall on x=1, three tall and seven wide, between the start (0,64,0) and the goal (2,64,0).
    -- Cutting through is 3 steps; going over is about 8. It must go over.
    for z = -3, 3 do for y = 63, 65 do env.cachedWorld["1:" .. y .. ":" .. z] = 1 end end
    local s_Path = env.a_star(0, 64, 0, 2, 64, 0, 1, false, 99, true)
    truthy(type(s_Path) == "table", "a path came back: " .. tostring(s_Path))
    local x, y, z = 0, 64, 0
    local s_Deltas = { [0] = {0, 0, -1}, [1] = {-1, 0, 0}, [2] = {0, 0, 1}, [3] = {1, 0, 0}, [4] = {0, 1, 0}, [5] = {0, -1, 0} }
    local s_Cut = 0
    for _, dir in ipairs(s_Path) do
        local d = s_Deltas[dir]
        x, y, z = x + d[1], y + d[2], z + d[3]
        if env.cachedWorld[x .. ":" .. y .. ":" .. z] == 1 then s_Cut = s_Cut + 1 end
    end
    eq(s_Cut, 0, "no wall cell on the route")
    eq(x .. "," .. y .. "," .. z, "2,64,0", "and it arrives")
end)

test("PowGPSServer: when nothing but rock leads to the goal the planner does dig", function()
    local env = loadModule("PowGPSServer.lua")
    -- Encase the goal completely: the only way in is through a cell of rock.
    for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
        if not (dx == 0 and dy == 0 and dz == 0) then env.cachedWorld[(5 + dx) .. ":" .. (64 + dy) .. ":" .. dz] = 1 end
    end end end
    local s_Path = env.a_star(0, 64, 0, 5, 64, 0, 1, false, 99, true)
    truthy(type(s_Path) == "table", "a digging path came back: " .. tostring(s_Path))
    local s_Blocked = env.a_star(0, 64, 0, 5, 64, 0, 1, false, 99, false)
    truthy(s_Blocked == false or s_Blocked == nil, "without digging there is no route")
end)

-- DroneLogic: travel asks for an open route before a digging one
test("DroneLogic: TravelTo never asks for a digging plan when an open route exists", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_Calls = {}
    env.pgps.moveTo = function() s_Calls[#s_Calls + 1] = "moveTo" return true end
    env.pgps.digTo = function() s_Calls[#s_Calls + 1] = "digTo" return true end
    local px, py, pz = env.pgps.getCachedPosition()
    truthy(env.TravelToBody(px + 12, py, pz + 5), "arrived")
    eq(table.concat(s_Calls, ","), "moveTo", "one open-route plan, no digging plan")
end)

test("DroneLogic: TravelTo digs only after the open-route plans have failed", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.TravelDigAllowed = true        -- inside a dig job; outside one travel never digs (see the gate test)
    local s_Calls = {}
    env.pgps.moveTo = function() s_Calls[#s_Calls + 1] = "moveTo" return false end
    env.pgps.digTo = function() s_Calls[#s_Calls + 1] = "digTo" return true end
    local px, py, pz = env.pgps.getCachedPosition()
    truthy(env.TravelToBody(px + 12, py, pz + 5), "arrived by digging in the end")
    truthy(s_Calls[1] == "moveTo", "the first ask was for an open route: " .. table.concat(s_Calls, ","))
    local s_FirstDig
    for i, c in ipairs(s_Calls) do if c == "digTo" and s_FirstDig == nil then s_FirstDig = i end end
    truthy(s_FirstDig ~= nil and s_FirstDig > 1, "digging came after the open-route attempts")
end)

-- DroneLogic: the jitter watch
test("DroneLogic: a drone that moves a lot over a few cells gets its trip broken after one window", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_Broken = 0
    env.pgps.motionWindow = function() return 44, 4, 3 end
    env.pgps.BreakExec = function() s_Broken = s_Broken + 1 end
    env.executing = false
    -- the module's own start-up already ran one heartbeat, so the window closes within 2 calls
    local s_Fired = false
    for _ = 1, 2 do if env.JitterWatch() then s_Fired = true end end
    truthy(s_Fired, "the window closed on jitter")
    eq(s_Broken, 1, "the trip was broken once")
end)

test("DroneLogic: a drone covering ground is never called jittery", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.pgps.motionWindow = function() return 40, 12, 38, 60 end
    local s_Fired = false
    for _ = 1, 8 do if env.JitterWatch() then s_Fired = true end end
    truthy(not s_Fired, "40 moves over 38 cells spanning 60 blocks is travel")
    env.pgps.motionWindow = function() return 64, 0, 12, 6 end
    for _ = 1, 4 do if env.JitterWatch() then s_Fired = true end end
    truthy(s_Fired, "64 moves that never left a 6-block box is a back-and-forth")
end)


-- A dry drone does not try
test("pgps.moveTo at zero fuel refuses before turning or asking for a path", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.turtle.fuel = 0
    local s_Turns = 0
    env.turtle.turnLeft = function() s_Turns = s_Turns + 1 return true end
    env.turtle.turnRight = function() s_Turns = s_Turns + 1 return true end
    local ok, why = env.moveTo(5, 64, 5)
    eq(ok, false, "refused")
    eq(why, "out of fuel", "and said why")
    eq(s_Turns, 0, "without a single turn")
end)

test("DroneLogic: RefuelAtStorage at zero fuel raises a distress and makes no trip", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.fuel = 0
    local s_Asked = false
    env.__world.replies.StorageMan = { DepositPoint = function() s_Asked = true return { pos = { x = 0, y = 64, z = 0 } } end }
    local ok = env.RefuelAtStorage()
    eq(ok, false, "no refuel")
    truthy(not s_Asked, "StorageMan was not asked for a deposit point")
end)


test("DroneLogic: a crafter shuttling between the bay's chests is work, not jitter", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.pgps.motionWindow = function() return 255, 6, 6, 8 end
    local s_Broken = 0
    env.pgps.BreakExec = function() s_Broken = s_Broken + 1 end
    env.executing = false
    env.HiveMindTest.DroneLogic.setStatus("crafting")
    for _ = 1, 8 do env.JitterWatch() end
    eq(s_Broken, 0, "a crafter's chest-hopping is never a loop")
end)


test("DroneLogic: a deposit that unloads nothing backs off instead of retrying every tick", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.NoteDepositOutcome(327, 100)
    eq(env.DepositBackoffUntil, 0, "unloading some is progress -- no backoff")
    env.NoteDepositOutcome(327, 327)
    truthy(env.DepositBackoffUntil > env.os.clock(), "unloading nothing sets a backoff")
end)

test("DroneLogic: a job body waits for the travel lock and fails honestly when it stays held", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.TRAVEL_WAIT_S = 0
    local s_Ran = false
    eq(env.RunBodyWhenFree(function() s_Ran = true return "ok" end, {}), "ok", "free: the body runs")
    truthy(s_Ran, "ran")
    env.TravelOwner = coroutine.create(function() coroutine.yield() end)   -- alive, not us
    env.TravelSince = env.os.clock()
    local ok, err = pcall(env.RunBodyWhenFree, function() return "ok" end, {})
    eq(ok, false, "held: the body does not run")
    truthy(tostring(err):find("kept the drone moving", 1, true) ~= nil, "and the reason names the lock: " .. tostring(err))
end)


test("DroneLogic: a short straight hop never digs -- a blocked step falls through to the planner", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_Digs = 0
    env.turtle.digUp = function() s_Digs = s_Digs + 1 return true end
    env.turtle.digDown = function() s_Digs = s_Digs + 1 return true end
    env.turtle.dig = function() s_Digs = s_Digs + 1 return true end
    env.turtle.detectUp = function() return true end
    env.pgps.up = function() return false end            -- something solid overhead
    local s_Planned = false
    env.pgps.moveTo = function() s_Planned = true return true end
    local px, py, pz = env.pgps.getCachedPosition()
    truthy(env.TravelToBody(px, py + 2, pz), "arrived")
    eq(s_Digs, 0, "nothing was dug on the way")
    truthy(s_Planned, "the planner was asked instead")
end)


test("DroneLogic: a mid-job deposit that unloads nothing into a full inventory fails and backs off", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.FreeSlots = function() return 0 end
    truthy(env.RoomAfterUnload(12), "unloading something is progress")
    eq(env.RoomAfterUnload(0), false, "nothing unloaded, no free slot: no room")
    truthy(env.DepositBackoffUntil > env.os.clock(), "and the next deposit waits")
    env.FreeSlots = function() return 3 end
    truthy(env.RoomAfterUnload(0), "nothing unloaded but room aboard: the job can go on")
end)


test("DroneLogic: a build that placed nothing fails with its reasons; a walled-in build stops after six unreachable squares", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local ok, err = pcall(env.FailIfNothingPlaced, 0, 4, { ["short of minecraft:chest"] = 4 })
    eq(ok, false, "nothing placed is a failure")
    truthy(tostring(err):find("short of minecraft:chest x4", 1, true) ~= nil, "with the reason: " .. tostring(err))
    truthy(pcall(env.FailIfNothingPlaced, 1, 4, { ["no route to the square"] = 3 }), "one block placed is progress")
    local run = 0
    for _ = 1, 5 do run = env.NoteNoRoute(run) end
    eq(run, 5, "five unreachable squares are tolerated")
    local ok2, err2 = pcall(env.NoteNoRoute, run)
    eq(ok2, false, "the sixth stops the build")
    truthy(tostring(err2):find("walled in", 1, true) ~= nil, tostring(err2))
end)


test("DroneLogic: a drone with no fix but a known home walks home by reckoning instead of searching", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = -657, y = 121, z = 62 }
    env.pgps.positionVerified = function() return false end
    local s_Legs = {}
    env.pgps.flyTo = function(x, y, z) s_Legs[#s_Legs + 1] = { x = x, y = y, z = z }; env.__world.pos.x = x; env.__world.pos.z = z; return true end
    local s_Fixes = 0
    env.pgps.verifyPosition = function() s_Fixes = s_Fixes + 1 return s_Fixes >= 3 end
    truthy(env.SeekCoverage(), "placed again")
    eq(#s_Legs, 3, "three legs toward home before the fix came")
    truthy(s_Legs[1].x > -657, "the first leg went toward home (east)")
    truthy(s_Legs[1].y >= 121, "and did not descend")
end)


test("DroneLogic: an idle top-up that brings nothing back backs off instead of flying every heartbeat", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.StorageKnownDry = function() return false end
    local s_Trips = 0
    env.RefuelAtStorage = function() s_Trips = s_Trips + 1; env.turtle.fuel = env.turtle.fuel - 20; return false end
    truthy(env.TopUpWhileIdle(), "the first trip is made")
    eq(env.TopUpWhileIdle(), false, "the next heartbeat does not fly again")
    eq(s_Trips, 1, "one trip")
    truthy(env.TopUpBackoffUntil > env.os.clock(), "a backoff is set")
    env.TopUpBackoffUntil = 0
    env.RefuelAtStorage = function() s_Trips = s_Trips + 1; env.turtle.fuel = env.turtle.fuel + 300; return true end
    truthy(env.TopUpWhileIdle(), "a trip that gains fuel")
    eq(env.TopUpBackoffUntil, 0, "sets no backoff")
end)


test("pgps: a trip stalls against the best distance so far, not the last step, and has a step budget", function()
    local env, P = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    local t = P.newTrip(10, 64, 0)
    eq(t.budget, 4 * 10 + 32, "budget: four steps per block plus the margin")
    eq(P.tripStalled(t, 10), nil, "first look sets the best")
    eq(P.tripStalled(t, 8), nil, "closer: progress")
    eq(P.tripStalled(t, 9), nil, "further than the best: stall 1")
    eq(P.tripStalled(t, 8), nil, "back to the best, not beyond it: stall 2 -- the last step improved but the best did not")
    eq(P.tripStalled(t, 9), nil, "stall 3")
    eq(P.tripStalled(t, 8), "no progress", "stall 4: over")
    local t2 = P.newTrip(3, 64, 0)
    for _ = 1, 40 do env.__world.pos.x = env.__world.pos.x + 1 end
    -- forty real steps recorded by the motion counter blow a 44-step budget only when they exceed it
    truthy(P.tripStalled(t2, 3) == nil, "under budget")
end)


test("DroneLogic: with no map to ask, a blind leg home rises, faces home and flies sixteen blocks", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = -657, y = 121, z = 62 }
    local s_Faced, s_Fwd, s_Up = nil, 0, 0
    env.pgps.turnTo = function(h) s_Faced = h return true end
    env.pgps.forward = function() s_Fwd = s_Fwd + 1 return true end
    env.pgps.up = function() s_Up = s_Up + 1 return true end
    truthy(env.BlindLegHome(-480, 63, 64), "moved")
    eq(s_Faced, env.pgps.HEADINGS.east, "home is east")
    eq(s_Fwd, 16, "sixteen blocks forward")
    eq(s_Up, 0, "already above cruise height: no climb")
end)


test("DroneLogic: the blind leg's second axis is the shorter way home", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    eq(env.headingAcross(-657, 62, -480, 64), env.pgps.HEADINGS.south, "x is the long axis, so across is +z: south")
    eq(env.headingAcross(-480, 20, -480, 64), nil, "no second axis when x already matches")
end)


test("pgps: one driver at a time -- a second coroutine's turn waits until the first coroutine's move is over", function()
    local env = loadModule("pgps.lua")
    env.setLocation(0, 64, 0, "north")
    env.os.sleep = function() coroutine.yield("waiting") end
    local s_Log = {}
    local s_RawForward = env.turtle.forward
    env.turtle.forward = function() s_Log[#s_Log + 1] = "step"; coroutine.yield("mid-step"); return s_RawForward() end
    env.turtle.turnLeft = function() s_Log[#s_Log + 1] = "turn"; return true end
    local A = coroutine.create(function() return env.forward() end)
    local B = coroutine.create(function() return env.turnLeft() end)
    coroutine.resume(A)                       -- A takes the drive and yields mid-step
    truthy(env.isDriving(), "seen from the main coroutine, somebody else is driving")
    coroutine.resume(B)                       -- B wants to turn: must wait
    eq(#s_Log, 1, "B did not turn while A was mid-step")
    coroutine.resume(A)                       -- A finishes its step and releases
    coroutine.resume(B)                       -- B wakes, drives, turns
    eq(table.concat(s_Log, ","), "step,turn", "the turn came after the step, never between")
    truthy(not env.isDriving(), "nobody is driving afterwards")
end)

test("DroneLogic: travel counts as busy while any coroutine drives through pgps", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.pgps.isDriving = function() return true end
    truthy(env.TravelIsBusy(), "busy")
    env.pgps.isDriving = function() return false end
    truthy(not env.TravelIsBusy(), "free")
end)


test("TaskMan: a build does not take a miner while lumber or a gather is waiting; a scout takes it", function()
    local env, T = taskManWithFleet({
        { id = 1, name = "D1", role = "miner", status = "idle", fuel = 1500, pos = { x = -480, y = 64, z = 80 } },
        { id = 2, name = "D9", role = "scout", status = "idle", fuel = 1500, pos = { x = -480, y = 64, z = 90 } },
    })
    env.DATA.tasks = {
        [8] = { id = 8, name = "tower-L0-p01", work = { build = { origin = { x = -480, y = 63, z = 80 }, blocks = {} } }, progress = 0, priority = 1 },
        [9] = { id = 9, name = "lumber:oak_log", work = { lumber = { w = 8, l = 8 } }, progress = 0, priority = 1 },
    }
    truthy(env.OnStartTask(0, { data = { id = 8 } }), "the build was placed")
    eq(env.DATA.tasks[8].assignedTo, 2, "on the scout, though the miner was nearer: wood is waiting")
end)



test("TaskMan: with the shelf full, the storage chain outranks other work of the same priority", function()
    local _, T = loadModule("TaskMan.lua")
    T.setFreeSlots(2)
    eq(T.storageRank("lumber:oak_log"), 1, "lumber")
    eq(T.storageRank("craft-oak_planks"), 1, "planks")
    eq(T.storageRank("craft-chest"), 1, "chests")
    eq(T.storageRank("build-chest-row-storage-01"), 1, "the row")
    eq(T.storageRank("tower-L0-p04"), 0, "a tower patch does not")
    T.setFreeSlots(40)
    eq(T.storageRank("lumber:oak_log"), 0, "with room on the shelf nothing is special")
end)


test("StorageMan: holders rotate per request and a furnace is never the answer while a chest holds it", function()
    local _, S = loadModule("StorageMan.lua")
    local holders = { { where = "minecraft:furnace_3" }, { where = "minecraft:chest_1" }, { where = "minecraft:chest_2" } }
    eq(S.pickHolder(holders, 1).where, "minecraft:chest_2", "turn 1")
    eq(S.pickHolder(holders, 2).where, "minecraft:chest_1", "turn 2 -- a different chest")
    eq(S.pickHolder(holders, 3).where, "minecraft:chest_2", "and round again, never the furnace")
    eq(S.pickHolder({ { where = "minecraft:furnace_3" } }, 7).where, "minecraft:furnace_3", "a furnace only when nothing else holds it")
    eq(S.pickHolder({}, 1), nil, "nothing")
end)


test("TaskMan: a craft whose inputs are not on the shelf is held, one that has them is not", function()
    local _, T = loadModule("TaskMan.lua")
    T.setStock({ ["minecraft:stone"] = 500 })
    local planks = { name = "craft-oak_planks", work = { craft = { item = "minecraft:oak_planks", runs = 8, inputs = { ["minecraft:oak_log"] = 1 } } } }
    local bricks = { name = "craft-stone_bricks", work = { craft = { item = "minecraft:stone_bricks", runs = 32, inputs = { ["minecraft:stone"] = 4 } } } }
    eq(T.craftShortIn(planks), "minecraft:oak_log", "no logs: held")
    eq(T.craftShortIn(bricks), nil, "stone is there: goes")
    T.setStock(nil)
    eq(T.craftShortIn(planks), nil, "unknown stock is not a reason to hold")
end)


test("StorageMan: furnaces are never deposit points, whatever the registry says", function()
    local env = loadModule("StorageMan.lua")
    env.DATA.deposits = {
        { peripheral = "minecraft:chest_0", pos = { x = -476, y = 64, z = 78 } },
        { peripheral = "minecraft:furnace_2", pos = { x = -520, y = 63, z = 34 } },
        { pos = { x = -479, y = 63, z = 32 } },
    }
    local ok, res = env.OnDepositPoints(1, { data = {} })
    truthy(ok, "points came back")
    eq(res.count, 2, "the furnace is gone, the chest and the unnamed cache stay")
    for _, p in ipairs(res.points) do truthy(not env.isFurnace(p.peripheral), "no furnace among them") end
end)


test("DroneLogic: a covered square is laid from a neighbour cell, facing the gap", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "minecraft:stone_bricks", count = 10 }
    local s_Trips, s_Faced, s_Placed = {}, nil, 0
    env.TravelTo = function(x, y, z) s_Trips[#s_Trips + 1] = x .. "," .. y .. "," .. z; env.__world.pos = { x = x, y = y, z = z }; return true end
    env.pgps.turnTo = function(h) s_Faced = h return true end
    env.turtle.inspect = function() return false end
    env.turtle.place = function() s_Placed = s_Placed + 1 return true end
    eq(env.LayCovered(-480, 63, 70, { item = "minecraft:stone_bricks" }), "placed", "laid sideways")
    eq(s_Trips[1], "-479,63,70", "from the east neighbour at the square's own height")
    eq(s_Faced, env.pgps.HEADINGS.west, "facing the gap")
    eq(s_Placed, 1, "one block")
    eq(env.LayCovered(-480, 63, 70, { item = "minecraft:stone_brick_stairs", heading = "north" }), "no route", "stairs keep their heading rule")
end)

test("DroneLogic: when no neighbour is reachable a floor square is laid from below", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "minecraft:stone_bricks", count = 10 }
    local s_Up = 0
    env.TravelTo = function(x, y, z) return y == 62 end       -- only the cell below is reachable
    env.turtle.inspectUp = function() return false end
    env.turtle.placeUp = function() s_Up = s_Up + 1 return true end
    eq(env.LayCovered(-480, 63, 70, { item = "minecraft:stone_bricks" }), "placed", "laid from below")
    eq(s_Up, 1, "placeUp once")
    local marked = {}
    local memo = { mark = function(k) marked[#marked + 1] = k end }
    local run, placed, skipped = env.CountCovered("placed", memo, "-480:63:70", {}, 3, 5, 2)
    eq(run .. "/" .. placed .. "/" .. skipped, "0/6/2", "a placed square resets the no-route run and counts")
    eq(marked[1], "-480:63:70", "and is remembered as done")
    run, placed, skipped = env.CountCovered("no route", memo, "k", {}, 0, 0, 0)
    eq(run .. "/" .. placed .. "/" .. skipped, "1/0/1", "an unreachable one counts toward walled-in")
end)

test("DroneLogic: a covered square walled in on the map returns no route without pathing into a wall", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "minecraft:stone_bricks", count = 10 }
    -- Every neighbour at the square's height and the cell directly below are recorded solid: the
    -- covered floor square the y63 thrash was grinding under. No approach is open.
    env.pgps.cachedWorld = {
        ["-479:63:70"] = 1, ["-481:63:70"] = 1, ["-480:63:71"] = 1, ["-480:63:69"] = 1,
        ["-480:62:70"] = 1,
    }
    local s_Trips = 0
    env.TravelTo = function() s_Trips = s_Trips + 1 return true end
    eq(env.LayCovered(-480, 63, 70, { item = "minecraft:stone_bricks" }), "no route", "no open approach")
    eq(s_Trips, 0, "never pathed into a cell the map already calls a wall")
end)

test("DroneLogic: a covered square short of material skips cleanly -- it does not throw the whole build", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inspect = function() return false end            -- the gap is open
    env.turtle.place = function() return true end
    -- Inventory holds none of the item, so selectItem fails. This used to error("ran out ... partway")
    -- and abort the whole patch; it must now report "short" and let the loop carry on.
    local ok, verdict = pcall(env.LayAhead, env.turtle.inspect, env.turtle.place, "minecraft:stone_bricks")
    truthy(ok, "LayAhead did not throw")
    eq(verdict, "short", "it reports short of material")
    -- A shortage is a skip, and NOT a step toward the walled-in cutoff (which is about routes).
    local run, placed, skipped = env.CountCovered("short", { mark = function() end }, "k", {}, 3, 5, 2)
    eq(run, 3, "the walled-in run is untouched by a material shortage")
    eq(placed .. "/" .. skipped, "5/3", "no placement, counted as one skip")
end)


test("StorageMan: the pickup point is an empty chest, else a holder with room, never a furnace", function()
    local env = loadModule("StorageMan.lua")
    env.DATA.deposits = {
        { peripheral = "minecraft:chest_0", pos = { x = -476, y = 64, z = 78 } },
        { peripheral = "minecraft:chest_1", pos = { x = -480, y = 64, z = 78 } },
        { peripheral = "minecraft:furnace_2", pos = { x = -479, y = 65, z = 77 } },
    }
    env.m_Chests = { "minecraft:chest_0", "minecraft:chest_1", "minecraft:furnace_2" }
    env.m_Free = { ["minecraft:chest_0"] = 10, ["minecraft:chest_1"] = 10, ["minecraft:furnace_2"] = 2 }
    env.m_Index = { ["minecraft:stone_bricks"] = { total = 90, at = {
        { where = "minecraft:chest_0", slot = 1, count = 20 },
        { where = "minecraft:chest_1", slot = 3, count = 60 },
        { where = "minecraft:furnace_2", slot = 1, count = 10 } } } }
    -- both holders have room: askers spread across them, never the furnace
    local seen = {}
    for asker = 1, 6 do local p = env.pickupFor("minecraft:stone_bricks", asker); truthy(p ~= nil, "a pickup"); truthy(p.peripheral ~= "minecraft:furnace_2", "never the furnace"); seen[p.peripheral] = true end
    truthy(seen["minecraft:chest_0"] and seen["minecraft:chest_1"], "spread across both chests, not one")
    -- an EMPTY chest beats every holder: the whole order is pushed into it and sucked out front to back
    env.DATA.deposits[#env.DATA.deposits + 1] = { peripheral = "minecraft:chest_9", pos = { x = -470, y = 64, z = 78 } }
    env.m_Chests[#env.m_Chests + 1] = "minecraft:chest_9"
    env.m_Free["minecraft:chest_9"] = 27
    eq(env.pickupFor("minecraft:stone_bricks", 1).peripheral, "minecraft:chest_9", "the empty chest is the pickup")
    -- full holders lose to any stranger with room (the cable sat in a full chest, 2026-09-08)
    env.m_Free["minecraft:chest_9"] = 0
    env.m_Free["minecraft:chest_0"], env.m_Free["minecraft:chest_1"] = 0, 0
    env.DATA.deposits[#env.DATA.deposits + 1] = { peripheral = "minecraft:chest_5", pos = { x = -471, y = 64, z = 78 } }
    env.m_Chests[#env.m_Chests + 1] = "minecraft:chest_5"
    env.m_Free["minecraft:chest_5"] = 5
    eq(env.pickupFor("minecraft:stone_bricks", 2).peripheral, "minecraft:chest_5", "a stranger with room beats full holders (asker 1 still holds its reservation on chest_9)")
    eq(env.pickupFor("minecraft:glass", 1), nil, "nothing holds glass")
end)


test("DroneLogic: a fetched stack is kept only up to the cap, the rest goes back", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local k, b = env.KeepUpTo(64, 4)
    eq(k .. "/" .. b, "4/60", "four kept, sixty back")
    k, b = env.KeepUpTo(30, nil)
    eq(k .. "/" .. b, "30/0", "no cap: keep it all")
    k, b = env.KeepUpTo(30, 100)
    eq(k .. "/" .. b, "30/0", "cap above the stack: keep it all")
    k, b = env.KeepUpTo(30, 0)
    eq(k .. "/" .. b, "0/30", "nothing more wanted: all back")
end)


test("DroneLogic: a straight hop that stops closing the distance bails to the planner", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = -476, y = 66, z = 47 }
    -- up() works, but the target y=67 cell "moves" -- simulate arrival never matching by making
    -- the drone oscillate: up goes to 67, but the target is 68 and 68 is blocked so up fails there;
    -- here we just prove it bails rather than looping 12 times when distance does not fall.
    local s_Moves = 0
    env.pgps.up = function() s_Moves = s_Moves + 1; env.__world.pos.y = 67; return true end   -- lands at 67, never 68
    env.pgps.down = function() s_Moves = s_Moves + 1; env.__world.pos.y = 66; return true end
    -- target 68: from 66 dist 2, step up -> 67 dist 1 (progress), step up again stays 67 dist 1 (no progress) -> bail
    env.pgps.moveTo = function() return false end
    env.riseToCeiling = function() return false end
    env.CanDig = function() return false end
    env.hardStop = function() return true end
    local ok = env.TravelToBody(-476, 68, 47)
    -- TravelToBody will then try moveTo; stub it to fail so the whole call returns false quickly
    truthy(s_Moves <= 3, "it did not bounce: at most a couple of moves before bailing, got " .. s_Moves)
end)


test("StorageMan: a chest name recorded at several positions collapses to its last one", function()
    local env, S = loadModule("StorageMan.lua")
    env.DATA.deposits = {
        { peripheral = "minecraft:chest_6", pos = { x = -477, y = 64, z = 78 } },
        { peripheral = "minecraft:chest_0", pos = { x = -476, y = 64, z = 78 } },
        { peripheral = "minecraft:chest_6", pos = { x = -476, y = 64, z = 79 } },   -- newer position of chest_6
        { pos = { x = -479, y = 63, z = 32 } },                                     -- a cache, unnamed, kept
    }
    S.dedupeDeposits()
    local byName = {}
    for _, d in ipairs(env.DATA.deposits) do byName[d.peripheral or "?"] = (byName[d.peripheral or "?"] or 0) + 1 end
    eq(byName["minecraft:chest_6"], 1, "chest_6 appears once")
    for _, d in ipairs(env.DATA.deposits) do
        if d.peripheral == "minecraft:chest_6" then eq(d.pos.z, 79, "kept the last position") end
    end
    eq(byName["?"], 1, "the cache stays")
end)


test("DroneLogic: a build patch is ordered lowest course first, then nearest-neighbour", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = 0, y = 64, z = 0 }
    local o = { x = 0, y = 64, z = 0 }
    -- scattered, mixed heights: a top block near, a bottom block far, a bottom block near
    local blocks = {
        { dx = 10, dy = 2, dz = 0, item = "b" },   -- high, near-ish
        { dx = 8,  dy = 0, dz = 0, item = "b" },    -- low, far
        { dx = 1,  dy = 0, dz = 0, item = "b" },    -- low, near
        { dx = 2,  dy = 0, dz = 0, item = "b" },    -- low, near+1
    }
    local out = env.OrderBuildBlocks(blocks, o)
    eq(out[1].dy, 0, "a lowest-course block first")
    eq(out[#out].dy, 2, "the high block last")
    eq(out[1].dx, 1, "nearest low block first")
    eq(out[2].dx, 2, "then the next-nearest low block")
    eq(out[3].dx, 8, "then the far low block, before climbing")
end)


test("DroneLogic: Tried reports a Lua code error to HQ once, but not a plain domain failure", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_Distress = {}
    env.Distress = function(reason, detail) s_Distress[#s_Distress + 1] = reason .. "|" .. tostring(detail) end
    env.Tried("reach the chest", function() error("could not reach", 0) end)   -- domain: no file:line
    env.Tried("top up", function() error("DroneLogic.lua:7304: bad argument (number expected, got nil)", 0) end)
    env.Tried("top up", function() error("DroneLogic.lua:7304: bad argument (number expected, got nil)", 0) end)
    eq(#s_Distress, 1, "the code error surfaced once; the domain failure did not, the repeat did not")
    truthy(s_Distress[1]:find("code error", 1, true), "reported as a code error")
end)


test("DroneLogic: a Tried action that keeps failing surfaces once; a success clears the count", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    local s_D = {}
    env.Distress = function(reason, detail) s_D[#s_D + 1] = reason end
    for _ = 1, 4 do env.Tried("reach the chest", function() error("no route", 0) end) end
    eq(#s_D, 0, "four failures are still quiet")
    env.Tried("reach the chest", function() error("no route", 0) end)          -- the fifth
    eq(#s_D, 1, "the fifth in a row surfaces as stuck retrying")
    eq(s_D[1], "stuck retrying", "reported so")
    truthy(env.Tried("reach the chest", function() return true end), "a success")
    for _ = 1, 4 do env.Tried("reach the chest", function() error("no route", 0) end) end
    eq(#s_D, 1, "the count reset on the success, so four more are quiet again")
end)


test("DroneLogic: DescendToAccess enters a chest from a staging height straight down its own column", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.HomeXYZ = function() return -480, 64, 64 end
    env.__world.pos = { x = 0, y = 64, z = 0 }
    local s_Legs, s_Downs = {}, 0
    env.TravelTo = function(x, y, z) s_Legs[#s_Legs + 1] = y; env.__world.pos = { x = x, y = y, z = z }; return true end
    env.pgps.down = function() env.__world.pos.y = env.__world.pos.y - 1; s_Downs = s_Downs + 1; return true end
    truthy(env.DescendToAccess(-476, 65, 78, "pickup"), "arrived on the access square")
    truthy(s_Legs[1] >= 74, "went to a staging height above the base first (got " .. tostring(s_Legs[1]) .. ")")
    truthy(s_Downs >= 1, "descended straight down its column")
end)

test("DroneLogic: DescendToAccess holds (fails) when the access square below is occupied", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.HomeXYZ = function() return -480, 64, 64 end
    env.__world.pos = { x = 0, y = 64, z = 0 }
    env.TravelTo = function(x, y, z) env.__world.pos = { x = x, y = y, z = z }; return true end
    env.pgps.down = function() return false end          -- something on the square below
    eq(env.DescendToAccess(-476, 65, 78, "pickup"), false, "did not force in; holds high for a retry")
end)


test("DroneLogic: only bay chests get vertical staging, not deep caches", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.HomeXYZ = function() return -480, 64, 64 end
    truthy(env.IsBayChest(-476, 65, 78), "a bay chest near home at working height")
    truthy(not env.IsBayChest(-480, 8, 87), "a deep cache is not a bay chest")
    truthy(not env.IsBayChest(-540, 64, 52), "a far chest is not a bay chest")
    eq(env.DescendToAccess(-480, 8, 87, "haul"), false, "no staging for the deep cache -- falls through")
end)


test("StorageMan: a reserved chest is excluded from another drone's candidates until it expires", function()
    local env, S = loadModule("StorageMan.lua")
    S.reserveChest("minecraft:chest_1", 7)
    truthy(S.reservedByOther("minecraft:chest_1", 9), "chest_1 is taken by drone 7, so drone 9 must go elsewhere")
    truthy(not S.reservedByOther("minecraft:chest_1", 7), "the holder itself is not blocked")
    truthy(not S.reservedByOther("minecraft:chest_2", 9), "an unreserved chest is free")
    S.reserveChest("minecraft:chest_2", 7)   -- a drone holds at most one: chest_1 is released
    truthy(not S.reservedByOther("minecraft:chest_1", 9), "reserving a new chest freed the old")
end)


test("DroneLogic: a build replaces a wrong block, keeps a right one, spares a protected one", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    -- right block: alreadyThatBlock true
    truthy(env.alreadyThatBlock({ name = "minecraft:stone_bricks" }, "minecraft:stone_bricks"), "right block recognised")
    truthy(not env.alreadyThatBlock({ name = "minecraft:cobblestone" }, "minecraft:stone_bricks"), "wrong block recognised")
    -- the replace helper digs a wrong, unprotected block and places the design block
    env.turtle.inv[1] = { name = "minecraft:stone_bricks", count = 64 }
    local s_Dug, s_Placed, s_Cleared = 0, 0, false
    env.turtle.detectDown = function() return not s_Cleared end          -- solid until we dig it
    env.turtle.inspectDown = function() return not s_Cleared, { name = "minecraft:cobblestone" } end
    env.turtle.digDown = function() s_Dug = s_Dug + 1; s_Cleared = true; return true end
    env.turtle.placeDown = function() s_Placed = s_Placed + 1 return true end
    truthy(env.ReplaceWrongBlock({ name = "minecraft:cobblestone" }, { item = "minecraft:stone_bricks" }, "0:0:0"),
        "a wrong unprotected block is dug and replaced")
    truthy(s_Dug >= 1 and s_Placed == 1, "dug the old, placed the new")
end)


test("DroneLogic: RequestClearance faces a sideways blocker, marks a wall solid and routes round, asks only a real drone to move", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = -467, y = 71, z = 78 }
    -- a stone_bricks wall one block west
    local s_Marked, s_Asked = nil, 0
    env.pgps.getCachedPosition = function() return -467, 71, 78, env.pgps.HEADINGS.north end
    env.pgps.turnTo = function() return true end
    env.pgps.noteObservation = function(idx, solid) s_Marked = idx .. "=" .. tostring(solid) end
    env.turtle.inspect = function() return true, { name = "minecraft:stone_bricks" } end
    env.AskToMakeWay = function() s_Asked = s_Asked + 1 end
    env.RequestClearance(-468, 71, 78)
    eq(s_Marked, "-468:71:78=1", "the wall was faced, identified, and marked solid for the planner")
    eq(s_Asked, 0, "a wall is not asked to move")
    -- now a real drone beside it
    env.turtle.inspect = function() return true, { name = "computercraft:turtle_normal" } end
    env.RequestClearance(-468, 71, 78)
    eq(s_Asked, 1, "a drone IS asked to move")
end)


test("DroneLogic: the straight hop bails to the planner instead of stepping into a known wall", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = 0, y = 64, z = 0 }
    env.pgps.cachedWorld = { ["1:64:0"] = 1 }          -- a wall one block east, target is past it
    local s_Fwd = 0
    env.pgps.forward = function() s_Fwd = s_Fwd + 1 return true end
    -- target east at 3,64,0: first straight step would enter 1,64,0 which is solid
    local ok = env.TravelToBody and true or false
    -- call stepStraightTo indirectly is awkward; assert nextStraightCell + the peek via a tiny run:
    env.pgps.getCachedPosition = function() return 0, 64, 0, env.pgps.HEADINGS and env.pgps.HEADINGS.north or 0 end
    local moved = env.pgps.moveTo
    -- if the hop refused to step into the wall, forward is never called for that cell
    -- (we can only check via TravelToBody falling through to moveTo)
    local planned = false
    env.pgps.moveTo = function() planned = true return true end
    env.TravelToBody(3, 64, 0)
    truthy(planned, "it used the planner instead of walking into the known wall")
    eq(s_Fwd, 0, "it never stepped forward into the solid cell")
end)


test("DroneLogic.DepositTarget: storage answers 'no deposit point' -> stay put, keep the cargo", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = 58, y = 67, z = 23 }
    env.__world.replies.StorageMan = { DepositPoint = { message = "no deposit point with free space" } }
    local moved = 0
    env.pgps.moveTo = function() moved = moved + 1 return true end
    env.pgps.digTo = function() moved = moved + 1 return true end
    eq(D.depositTarget(), nil, "no target")
    eq(moved, 0, "an answered 'nowhere' must not fly anywhere")
end)

test("pgps.flyTo holds the height it climbed for until a sideways step succeeds -- no up/down bounce", function()
    local env = loadModule("pgps.lua")
    -- A wall column at x=1 from the ground up to y=68; start at 0,66,0 and fly to 3,64,0.
    -- The old loop: down to 65, blocked, up to 66, down to 65, blocked ... for the whole budget.
    local function solid(x, y, z) return x == 1 and y <= 68 end
    local w = env.__world
    w.pos = { x = 0, y = 66, z = 0 }
    env.setLocation(0, 66, 0, env.East)
    local moves = 0
    local function step(dx, dy, dz)
        local x, y, z = env.getCachedPosition()
        if solid(x + dx, y + dy, z + dz) then return false end
        moves = moves + 1
        w.pos = { x = x + dx, y = y + dy, z = z + dz }
        return true
    end
    env.turtle.up = function() return step(0, 1, 0) end
    env.turtle.down = function() return step(0, -1, 0) end
    env.turtle.forward = function()
        local _, _, _, d = env.getCachedPosition()
        if d == env.East then return step(1, 0, 0) elseif d == env.West then return step(-1, 0, 0)
        elseif d == env.South then return step(0, 0, 1) else return step(0, 0, -1) end
    end
    local ok, why = env.flyTo(3, 64, 0, 60)
    truthy(ok, "arrives: " .. tostring(why))
    local x, y, z = env.getCachedPosition()
    eq(x .. "," .. y .. "," .. z, "3,64,0", "at the target")
    -- 15: one wasted down+up before the hold engages, then climb 3, over 2, down 5, forward 1. The
    -- old loop spent the whole 60-step budget bouncing between y65 and y66 and never arrived.
    truthy(moves <= 16, "no bounce: took " .. moves .. " moves")
end)

test("DroneLogic.ReachSite reaches a buried dig box down its own column, never along a planned tunnel", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    local w = env.__world
    w.pos = { x = 64, y = 68, z = 31 }         -- at the dock; box top y43 under 24 blocks of rock
    D.setExecuting(true)
    env.peripheral.getType = function() return nil end       -- a miner (both slots free) -> CanDig()
    local planned = 0
    env.pgps.moveTo = function(x, y, z)
        if y == 44 then return false end       -- the cell above the box is inside rock: no path
        w.pos = { x = x, y = y, z = z } return true
    end
    env.pgps.digTo = function() planned = planned + 1 return true end
    env.pgps.down = function() w.pos.y = w.pos.y - 1 return true end
    local dug = 0
    env.turtle.detectDown = function() return true end
    env.turtle.inspectDown = function() return true, { name = "minecraft:stone" } end
    env.turtle.digDown = function() dug = dug + 1 return true end
    truthy(env.ReachSite(63, 43, 31, true), "arrives")
    eq(w.pos.x .. "," .. w.pos.y .. "," .. w.pos.z, "63,44,31", "directly above the box top")
    eq(dug, 24, "one block dug per block of descent -- a column, not a tunnel")
    eq(planned, 0, "the planner was never asked for a digging route")
end)

test("DroneLogic.DescendDigging stops above a chest instead of digging through it", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    local w = env.__world
    w.pos = { x = 0, y = 70, z = 0 }
    D.setExecuting(true)
    env.pgps.down = function() w.pos.y = w.pos.y - 1 return true end
    env.turtle.detectDown = function() return true end
    env.turtle.inspectDown = function() return true, { name = w.pos.y == 68 and "minecraft:chest" or "minecraft:dirt" } end
    local ok, why = D.descendDigging(60)
    falsy(ok, "refused")
    contains(tostring(why), "chest", "names the block")
    eq(w.pos.y, 68, "stopped on top of it")
end)

test("DroneLogic.DigStartInBox refuses a start seven blocks off the box even at the right height", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    local d = { pos = { x = 63, y = 43, z = 31 }, w = 3, l = 3, depth = 4 }
    truthy(D.digStartInBox(d, 64, 44, 32), "inside the footprint, one above the top: fine")
    truthy(D.digStartInBox(d, 63, 40, 33), "inside, at the bottom layer: fine (a re-dig)")
    local ok, why = D.digStartInBox(d, 71, 40, 39)
    falsy(ok, "seven blocks off the footprint is not the box")
    contains(tostring(why), "outside the box footprint", "says which check failed")
    ok, why = D.digStartInBox(d, 64, 60, 32)
    falsy(ok, "far above the box is not the box")
    contains(tostring(why), "not within the box", "says which check failed")
end)

test("DroneLogic.TravelToBody never digs outside a dig job -- a blocked trip fails instead of tunnelling", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.pos = { x = 0, y = 68, z = 0 }
    env.peripheral.getType = function() return nil end       -- a miner: CanDig()
    env.pgps.moveTo = function() return false end
    local dug = 0
    env.pgps.digTo = function() dug = dug + 1 return true end
    falsy(D.travelToBody(30, 68, 0), "no open route and no licence to dig: the trip fails")
    eq(dug, 0, "did not tunnel")
    env.TravelDigAllowed = true                               -- what RunJob sets for a dig job
    truthy(D.travelToBody(30, 68, 0), "a dig job may bore in")
    eq(dug, 1, "one digging plan")
end)

test("DroneLogic.LayAhead digs dirt out of a wall cell and lays the cobble; leaves a protected block", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "minecraft:cobblestone", count = 10 }
    local dug, placed = 0, 0
    local ahead = { name = "minecraft:dirt" }
    local inspect = function() return ahead ~= nil, ahead end
    local dig = function() dug = dug + 1 ahead = nil return true end
    local place = function() placed = placed + 1 return true end
    eq(D.layAhead(inspect, place, "minecraft:cobblestone", dig), "placed", "dirt gives way to the wall")
    eq(dug, 1, "one dig") eq(placed, 1, "one place")
    ahead = { name = "computercraft:monitor_advanced" }
    eq(D.layAhead(inspect, place, "minecraft:cobblestone", dig), "occupied", "a station is not dug")
    eq(dug, 1, "no further dig")
end)

test("DroneLogic.StandOnStructure sinks through a buried wall column, digging only the build's own cells", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    local w = env.__world
    w.pos = { x = 0, y = 70, z = 0 }
    D.setExecuting(true)
    local flewTo
    env.TravelTo = function(x, y, z) flewTo = { x, y, z } w.pos = { x = x, y = y, z = z } return true end
    env.pgps.down = function() w.pos.y = w.pos.y - 1 return true end
    local dug = {}
    env.turtle.detectDown = function() return true end                        -- hillside: solid all the way
    env.turtle.inspectDown = function() return true, { name = "minecraft:dirt" } end
    env.turtle.digDown = function() dug[#dug + 1] = w.pos.y - 1 return true end
    falsy(D.standOnStructure(5, 66, 5, {}), "a cell outside the build is not touched")
    eq(#dug, 0, "nothing dug")
    -- wall cells dy 1..5 and the roof at dy 6 above the target at y66: the column runs to y72
    local cells = {}
    for y = 67, 72 do cells["5:" .. y .. ":5"] = true end
    truthy(D.standOnStructure(5, 66, 5, cells), "reaches the standing cell")
    eq(flewTo[2], 73, "flew to the open air above the column (y72 is the roof)")
    eq(#dug, 6, "dug the six structure cells y72..y67 on the way down")
    eq(w.pos.y, 67, "standing at by+1")
end)

-- A stub world for the dig sweep: turnTo sets the heading, a cell callback moves one step along it
-- and records the cell. The sweep must visit exactly the box, whichever corner it starts from.
local function sweepWorld(env, x0, z0, w, l)
    local pos = { x = x0, z = z0 }
    local H = env.pgps.HEADINGS
    local dir = H.east
    local seen = {}
    env.pgps.getCachedPosition = function() return pos.x, 60, pos.z, dir end
    env.pgps.turnTo = function(d) dir = d return true end
    local step = function()
        if dir == H.east then pos.x = pos.x + 1 elseif dir == H.west then pos.x = pos.x - 1
        elseif dir == H.south then pos.z = pos.z + 1 else pos.z = pos.z - 1 end
        seen[pos.x .. ":" .. pos.z] = true
        return true
    end
    return pos, seen, step
end
for _, shape in ipairs({ {3, 3}, {3, 2}, {5, 1}, {2, 4} }) do
    local w, l = shape[1], shape[2]
    test(("DroneLogic.DigLayer sweeps exactly a %dx%d box on two consecutive layers, from either corner"):format(w, l), function()
        local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
        local pos, seen, step = sweepWorld(env, 10, 20, w, l)
        seen["10:20"] = true
        truthy(D.digLayer(10, 20, w, l, step), "layer 1 sweeps")
        eq(#(function() local n = {} for k in pairs(seen) do n[#n + 1] = k end return n end)(), w * l, "layer 1 covers every cell once")
        -- layer 2 starts where layer 1 ended, on whatever corner that is
        local seen2 = {}
        env.pgps.turnTo = env.pgps.turnTo
        local step2 = function() local ok = step() seen2[pos.x .. ":" .. pos.z] = true return ok end
        seen2[pos.x .. ":" .. pos.z] = true
        truthy(D.digLayer(10, 20, w, l, step2), "layer 2 sweeps")
        local n = 0 for k in pairs(seen2) do n = n + 1
            local x, z = k:match("^(-?%d+):(-?%d+)$"); x, z = tonumber(x), tonumber(z)
            truthy(x >= 10 and x <= 10 + w - 1 and z >= 20 and z <= 20 + l - 1, "layer 2 stays inside the box: " .. k)
        end
        eq(n, w * l, "layer 2 covers every cell once")
    end)
end

test("DroneLogic.unloadHere keeps up to four stacks of cobblestone aboard and deposits the rest", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    local w = env.__world
    w.addInventory("minecraft:chest_9", "minecraft:chest", {}, 27)
    env.turtle.inspectDown = function() return true, { name = "minecraft:chest" } end
    env.turtle.dropDown = function() env.turtle.inv[env.turtle.selected] = nil return true end   -- the stub's drop moves nothing
    env.turtle.inv[1] = { name = "minecraft:cobblestone", count = 64 }
    env.turtle.inv[2] = { name = "minecraft:cobblestone", count = 64 }
    env.turtle.inv[3] = { name = "minecraft:cobblestone", count = 64 }
    env.turtle.inv[4] = { name = "minecraft:cobblestone", count = 50 }
    env.turtle.inv[5] = { name = "minecraft:gravel", count = 40 }   -- dirt itself never leaves the drone (DEPOSIT_NEVER)
    local put = D.unloadHere()
    truthy(put, "unloaded into the chest below")
    eq(put["minecraft:gravel"], 40, "the spoils go")
    eq(put["minecraft:cobblestone"] or 0, 0, "cobble under four stacks all stays aboard")
    local aboard = 0
    for i = 1, 16 do local it = env.turtle.inv[i] if it and it.name == "minecraft:cobblestone" then aboard = aboard + it.count end end
    eq(aboard, 242, "the build material stays aboard for the next batch")
end)

test("DroneLogic.reportTask keeps an unacknowledged TaskDone and delivers it once TaskMan answers", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.replies.TaskMan = {}                       -- out of range: no reply
    D.reportTask({ taskId = 146 }, true, nil, { dug = 288 })
    eq(#env.PendingReports, 1, "kept for later")
    eq(env.PendingReports[1].id, 146, "the right task")
    local got
    env.__world.replies.TaskMan = { TaskDone = function(d) got = d return { id = d.id } end }
    eq(D.flushPendingReports(), 1, "delivered on the next chance")
    eq(#env.PendingReports, 0, "queue drained")
    eq(got.id, 146, "TaskMan received the report") eq(got.ok, true, "with its verdict")
end)

test("DroneLogic.DigLayer descends through a layer its own map already knows as air without sweeping it", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    local w = env.__world
    w.pos = { x = 10, y = 60, z = 20 }
    env.pgps.cachedWorld = {}
    for dx = 0, 2 do for dz = 0, 2 do env.pgps.cachedWorld[(10 + dx) .. ":60:" .. (20 + dz)] = 0 end end
    local steps = 0
    local ok = D.digLayer(10, 20, 3, 3, function() steps = steps + 1 return true end)
    truthy(ok, "layer counts as done")
    eq(steps, 0, "not one cell walked")
    env.pgps.cachedWorld["11:60:21"] = 1                           -- one block left in the middle
    falsy(D.layerKnownAir(10, 20, 3, 3, 60), "a single solid cell means the layer is swept")
end)

test("DroneLogic.NaturalBlock: leaves, logs and dirt yes; cobblestone, computers, chests no", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    truthy(D.naturalBlock("minecraft:oak_leaves"), "leaves") truthy(D.naturalBlock("minecraft:oak_log"), "logs")
    truthy(D.naturalBlock("minecraft:dirt"), "dirt") truthy(D.naturalBlock("minecraft:stone"), "stone")
    falsy(D.naturalBlock("minecraft:cobblestone"), "placed cobble") falsy(D.naturalBlock("minecraft:chest"), "a chest")
    falsy(D.naturalBlock("computercraft:monitor_advanced"), "a station") falsy(D.naturalBlock("create:veridium"), "another mod's block")
end)

test("DroneLogic.DigLayer skips a row the SHARED map knows as air and walks the rest", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    local w = env.__world
    local pos, seen, step = sweepWorld(env, 10, 20, 3, 3)
    -- MapServer knows the middle row (z=21) is air; the drone's own map knows nothing.
    env.__world.replies.MapServer = { KnownAir = function(d)
        local air = {} for i, p in ipairs(d.positions) do if p.z == 21 then air[#air + 1] = i end end return { air = air }
    end }
    local steps = 0
    local counted = function() steps = steps + 1 return step() end
    truthy(D.digLayer(10, 20, 3, 3, counted), "sweeps")
    -- rows 0 and 2 walked (2 steps each) plus two row changes: 6, not 8
    eq(steps, 6, "the known-air row is crossed, not walked")
end)

-- ================================================================================================
-- Build materials come from the drone first; storage is only asked for the shortfall
-- ================================================================================================
test("DroneLogic.SecureBuildMaterials: everything aboard -> no storage call", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "minecraft:cobblestone", count = 40 }
    local asked = false
    env.__world.replies.StorageMan = { Provide = function() asked = true return nil end }
    truthy(D.secureBuildMaterials({ ["minecraft:cobblestone"] = 30 }), "returns true")
    falsy(asked, "storage was not asked when the drone already carries the bill of materials")
end)

test("DroneLogic.SecureBuildMaterials: partly aboard, no storage -> build with what is aboard", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "minecraft:cobblestone", count = 10 }
    local askedFor
    env.__world.replies.StorageMan = { Provide = function(d) askedFor = d.items[1].count return nil end }
    truthy(D.secureBuildMaterials({ ["minecraft:cobblestone"] = 30 }), "returns true")
    eq(askedFor, 20, "storage was asked for the shortfall only")
end)

test("DroneLogic.SecureBuildMaterials: storage names where the unpushed item lies -> the drone goes there", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.replies.StorageMan = { Provide = function()
        return { pos = { x = 1, y = 2, z = 3 }, peripheral = "minecraft:chest_1", complete = false,
                 provided = {}, short = { { name = "minecraft:chest", count = 20 } },
                 points = { { name = "minecraft:chest", count = 20, pos = { x = 5, y = 2, z = 3 }, peripheral = "minecraft:chest_2" } } }
    end }
    truthy(D.secureBuildMaterials({ ["minecraft:chest"] = 20 }), "returns true")
    local went = false
    for _, body in pairs(env.__world.files) do if type(body) == "string" and body:find("pickup: 20 minecraft:chest more at 5,2,3", 1, true) then went = true end end
    truthy(went, "the drone set out for the chest storage named instead of sweeping every deposit point")
end)

test("StorageMan.Rescan: a scan younger than RESCAN_MIN_S is reused; a forced one is not", function()
    local env = loadModule("StorageMan.lua")
    local built = 0
    env.BuildIndex = function() built = built + 1 return {}, {}, {}, {} end
    env.Rescan(true) env.Rescan() env.Rescan() env.Rescan()
    eq(built, 1, "one build serves the burst")
    env.Rescan(true)
    eq(built, 2, "a write path forces a fresh scan")
    env.__world.addInventory("minecraft:chest_77", "minecraft:chest", {})
    env.Rescan()
    eq(built, 3, "a new peripheral on the wire forces one too")
end)

test("StorageMan.holderPointFor: the registered chest holding the most, never the handover chest", function()
    local env = loadModule("StorageMan.lua")
    env.DATA.deposits = {
        { peripheral = "minecraft:chest_0", pos = { x = 1, y = 61, z = 1 } },
        { peripheral = "minecraft:chest_1", pos = { x = 3, y = 61, z = 1 } },
    }
    env.m_Index = { ["minecraft:chest"] = { total = 77, at = {
        { where = "minecraft:chest_0", slot = 1, count = 54 },
        { where = "minecraft:chest_1", slot = 3, count = 20 },
        { where = "minecraft:chest_7", slot = 1, count = 3 } } } }   -- chest_7 has no registered position
    eq(env.holderPointFor("minecraft:chest", nil).peripheral, "minecraft:chest_0", "the biggest holder")
    eq(env.holderPointFor("minecraft:chest", "minecraft:chest_0").peripheral, "minecraft:chest_1", "not the handover chest itself")
    eq(env.holderPointFor("minecraft:chest", "minecraft:chest_0").pos.x, 3, "with its position")
    eq(env.holderPointFor("minecraft:cable", nil), nil, "nothing held -> nil")
end)

test("DroneLogic.TakeFromChest: unloads spoils on arrival but keeps what it came for and the KEEP allowance", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "minecraft:chest", count = 20 }      -- taken for this order on the last stop
    env.turtle.inv[2] = { name = "minecraft:dirt", count = 64 }       -- spoils
    env.turtle.inv[3] = { name = "minecraft:cobblestone", count = 64 }   -- within the KEEP_ABOARD allowance
    env.turtle.inspectDown = function() return true, { name = "minecraft:chest" } end
    local dropped = {}
    env.turtle.dropDown = function() local it = env.turtle.inv[env.turtle.selected] dropped[#dropped + 1] = it.name env.turtle.inv[env.turtle.selected] = nil return true end
    env.__world.addInventory("bottom", "minecraft:chest", { [1] = { name = "computercraft:wired_modem_full", count = 20 } })
    local want = function(n) return n == "minecraft:chest" or n == "computercraft:wired_modem_full" end
    D.takeFromChest(want, function() return 20 end)
    eq(tostring(env.KEEP_ABOARD and env.KEEP_ABOARD["minecraft:cobblestone"]), "256", "allowance visible")
    eq(table.concat(dropped, ","), "minecraft:dirt", "only the spoils went down")
    eq(dropped[1], "minecraft:dirt", "the spoils")
    truthy(env.turtle.inv[1] and env.turtle.inv[1].name == "minecraft:chest", "the chests stayed aboard")
    truthy(env.turtle.inv[3] and env.turtle.inv[3].name == "minecraft:cobblestone", "the cobble allowance stayed aboard")
end)

test("DroneLogic.TakeFromChest: the order's other kinds stay aboard once KeepOrderAboard ran", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.turtle.inv[1] = { name = "computercraft:cable", count = 21 }   -- taken at the previous stop
    env.turtle.inspectDown = function() return true, { name = "minecraft:chest" } end
    local dropped = {}
    env.turtle.dropDown = function() local it = env.turtle.inv[env.turtle.selected] dropped[#dropped + 1] = it.name env.turtle.inv[env.turtle.selected] = nil return true end
    env.__world.addInventory("bottom", "minecraft:chest", { [1] = { name = "computercraft:wired_modem_full", count = 20 } })
    env.KeepOrderAboard({ ["computercraft:cable"] = 21, ["computercraft:wired_modem_full"] = 20 })
    D.takeFromChest(function(n) return n == "computercraft:wired_modem_full" end, function() return 20 end)
    eq(#dropped, 0, "the cable was not put back into the modem chest")
end)

test("DroneLogic.MarkMapSolidDone: a solid cell counts as done only when the map names the design block", function()
    local env = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.pgps.cachedWorld = { ["0:0:0"] = 1, ["0:1:0"] = 1, ["0:2:0"] = 1, ["0:3:0"] = 1 }
    env.pgps.cachedWorldDetail = {
        ["0:0:0"] = { true, { name = "minecraft:cobblestone" } },   -- a floor slab where cable must go
        ["0:1:0"] = { true, { name = "computercraft:cable" } },      -- cable already laid
    }
    local marked = {}
    local memo = { done = function(k) return marked[k] == true end, mark = function(k) marked[k] = true end }
    local blocks = {
        { dx = 0, dy = 0, dz = 0, item = "computercraft:cable" },        -- wrong block, solid: visit
        { dx = 0, dy = 1, dz = 0, item = "computercraft:cable" },        -- right block: done
        { dx = 0, dy = 2, dz = 0, item = "computercraft:cable" },        -- solid, unnamed infra: visit
        { dx = 0, dy = 3, dz = 0, item = "minecraft:cobblestone" },      -- solid, unnamed plain: done
    }
    local n = env.MarkMapSolidDone(memo, blocks, { x = 0, y = 0, z = 0 })
    eq(n, 2, "two cells pre-marked")
    truthy(marked["0:1:0"], "laid cable is done")
    truthy(marked["0:3:0"], "unnamed solid cobble is done")
    truthy(not marked["0:0:0"], "cable over a cobble slab is visited")
    truthy(not marked["0:2:0"], "unnamed solid infra cell is visited")
end)

test("DroneLogic.SecureBuildMaterials: nothing aboard, no storage -> the one real error", function()
    local env, D = loadModule("DroneLogic.lua", { fuel = 1000 })
    env.__world.replies.StorageMan = { Provide = function() return nil end }
    local ok, err = pcall(D.secureBuildMaterials, { ["minecraft:cobblestone"] = 30 })
    falsy(ok, "throws")
    contains(tostring(err), "storage would not hand over", "the storage error, not a nil index")
end)


io.stderr:write(("%d test(s), %d failed\n"):format(#results, failed))
os.exit(failed == 0 and 0 or 1)
