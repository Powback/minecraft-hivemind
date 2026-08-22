--StorageMan
--Goal: know what we own, where it is, and where new things should go.
--
-- Reads inventories DIRECTLY over a wired modem network rather than trusting drones to report
-- what they carried. Drone-reported stock drifts the instant anything is hand-moved, dropped on
-- the floor, or destroyed -- and every consumer of this data (a builder asking "have we got 64
-- planks", a crafter asking "where is the iron") is wrong in a way that is very hard to see.
-- peripheral.call(chest,"list") is always exactly true.
--
-- The same mechanism gives smelting for free. A furnace on the network exposes slot 1 input,
-- 2 fuel, 3 output, so ore in and ingots out is pushItems/pullItems -- no drone ever touches it.

local function monitor()
    return PowNet.Monitor("top")
end

Log("Starting...")

function Init()
    if DATA["deposits"] == nil then DATA["deposits"] = {} end   -- where drones fly to drop off
    if DATA["smelting"] == nil then DATA["smelting"] = false end
end

----------------------------------------------------------------------------------------------
-- The network
----------------------------------------------------------------------------------------------
-- Anything on the wired network that can list its contents is storage. Furnaces answer the same
-- interface, so they are found the same way and told apart by their peripheral type.
-- The six direct-adjacency side names. Everything reachable this way is ALSO reachable by its
-- network name once it has a wired modem, so counting both double-counts every chest -- and worse,
-- a side name is meaningless to any other peripheral: pushItems/pullItems require BOTH inventories
-- to be on wired modems joined by cable, so passing "front" fails with
-- "Source 'front' does not exist". Network names only.
local SIDE_NAMES = {top = true, bottom = true, left = true, right = true, front = true, back = true}

local function inventories()
    local s_Chests, s_Furnaces = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
        if not SIDE_NAMES[name] then
            local s_Type = peripheral.getType(name)
            if s_Type and string.find(s_Type, "furnace") then
                s_Furnaces[#s_Furnaces + 1] = name
            else
                local ok, m = pcall(peripheral.wrap, name)
                if ok and m and m.list and m.size then
                    s_Chests[#s_Chests + 1] = name
                end
            end
        end
    end
    return s_Chests, s_Furnaces
end

-- item name -> {total, {where = peripheral, slot = n, count = n}, ...}
function BuildIndex()
    local s_Index, s_Free = {}, {}
    -- Once, not twice: this walks every peripheral on the network and is the expensive part.
    local s_Chests, s_Furnaces = inventories()
    for _, name in ipairs(s_Chests) do
        local ok, inv = pcall(peripheral.wrap, name)
        if ok and inv then
            local ok2, items = pcall(inv.list)
            local ok3, size  = pcall(inv.size)
            if ok2 and items then
                local used = 0
                for slot, it in pairs(items) do
                    used = used + 1
                    local e = s_Index[it.name]
                    if e == nil then e = {total = 0, at = {}} s_Index[it.name] = e end
                    e.total = e.total + it.count
                    e.at[#e.at + 1] = {where = name, slot = slot, count = it.count}
                end
                if ok3 and size then s_Free[name] = size - used end
            end
        end
    end
    return s_Index, s_Free, s_Chests, s_Furnaces
end

m_Index, m_Free, m_Chests, m_Furnaces = {}, {}, {}, {}
m_WarnedSided = {}   -- furnace name -> already warned about sided access

function Rescan()
    local ok, a, b, c, d = pcall(BuildIndex)
    if ok then
        m_Index, m_Free, m_Chests, m_Furnaces = a, b, c, d
        return true
    end
    print("rescan failed: " .. tostring(a))
    return false
end

----------------------------------------------------------------------------------------------
-- Queries
----------------------------------------------------------------------------------------------
function OnFind(p_ID, p_Message)
    Rescan()
    local s_Name = p_Message.data and p_Message.data.item
    if s_Name == nil then return false, "Missing item" end
    -- Substring match, so "iron" finds minecraft:iron_ingot without callers needing exact ids.
    local s_Hits, s_Total = {}, 0
    for name, e in pairs(m_Index) do
        if string.find(name, s_Name, 1, true) then
            s_Total = s_Total + e.total
            s_Hits[#s_Hits + 1] = {item = name, count = e.total, at = e.at}
        end
    end
    if #s_Hits == 0 then return true, {message = "no " .. s_Name, count = 0, hits = {}} end
    local s_Msg = ""
    for _, h in ipairs(s_Hits) do s_Msg = s_Msg .. h.item .. " x" .. h.count .. "; " end
    return true, {message = s_Msg, count = s_Total, hits = s_Hits}
end

-- Gather requested items into the pickup chest so a drone can collect them.
--
-- Storage has been one-way since it was built: drones could deposit, nothing could take. That was
-- survivable while every job CONSUMED the world and produced items, and it becomes the blocker the
-- moment anything needs INPUTS -- crafting, refuelling, building. A recipe plan is worthless if
-- the planks cannot get from the chest into the turtle.
--
-- Items are pushed to a physical chest rather than handed over directly, because a turtle is not a
-- network inventory unless it is wired to the modem network, and these drones are mobile. The
-- deposit chest is somewhere a drone can already fly to and reach, so this reuses infrastructure
-- that is known to work rather than inventing a second delivery mechanism.
function OnProvide(p_ID, p_Message)
    Rescan()
    local s_Want = p_Message.data and p_Message.data.items
    if type(s_Want) ~= "table" or #s_Want == 0 then return false, "Missing items" end

    -- The pickup chest. Deliberately the SAME chest drones already unload into: one physical
    -- rendezvous point, one thing to keep clear, one place to look when something goes missing.
    local s_Point = DATA["pickup"]
    if s_Point == nil then
        for _, d in ipairs(DATA["deposits"] or {}) do s_Point = d break end
    end
    if s_Point == nil then
        return false, "no pickup point -- set one with StorageMan.SetPickup {pos, peripheral}"
    end

    -- A deposit may be recorded as a POSITION ONLY -- `deposit -pos x y z` does not require the
    -- network name, and the one the base actually has was added that way. pushItems needs a name,
    -- and pushing to nil silently moves nothing: every request came back "short of oak_log" while
    -- 64 logs sat in the very chest the drone was about to fly to.
    local s_Dest = s_Point.peripheral
    if s_Dest == nil then
        if #m_Chests == 1 then
            s_Dest = m_Chests[1]                  -- unambiguous: there is only one chest
        else
            return false, ("deposit at %d,%d,%d has no peripheral name and there are %d chests" ..
                " -- re-add it with: p StorageMan deposit -pos x y z -peripheral <name>")
                :format(s_Point.pos.x, s_Point.pos.y, s_Point.pos.z, #m_Chests)
        end
    end

    local s_Given, s_Short = {}, {}
    for _, req in ipairs(s_Want) do
        local s_Name  = req.name
        local s_Need  = tonumber(req.count) or 0
        local s_Moved = 0

        for name, e in pairs(m_Index) do
            if s_Moved >= s_Need then break end
            -- Exact match here, NOT the substring matching Find uses. "iron" finding iron_ingot is
            -- helpful when a human is looking; a crafting grid filled with raw_iron because the
            -- recipe asked for iron_ingot produces nothing and wastes the trip.
            if name == s_Name then
                for _, at in ipairs(e.at or {}) do
                    if s_Moved >= s_Need then break end
                    if at.where == s_Dest then
                        -- ALREADY at the handover point. Pushing a chest's contents into itself
                        -- moves nothing and returns 0, so counting only what was pushed reported
                        -- "short of oak_log x4" while 64 logs sat in the very chest the drone was
                        -- about to fly to. With a single-chest base that is the ONLY case.
                        s_Moved = s_Moved + math.min(at.count or 0, s_Need - s_Moved)
                    else
                        local src = peripheral.wrap(at.where)
                        if src and src.pushItems then
                            local ok, n = pcall(src.pushItems, s_Dest, at.slot, s_Need - s_Moved)
                            if ok and type(n) == "number" then s_Moved = s_Moved + n end
                        end
                    end
                end
            end
        end

        if s_Moved > 0 then s_Given[#s_Given + 1] = {name = s_Name, count = s_Moved} end
        if s_Moved < s_Need then
            s_Short[#s_Short + 1] = {name = s_Name, count = s_Need - s_Moved}
        end
    end

    Rescan()
    return true, {
        pos = s_Point.pos, peripheral = s_Dest,
        provided = s_Given, short = s_Short,
        complete = (#s_Short == 0),
        message = ("handed over %d kinds at %d,%d,%d"):format(#s_Given, s_Point.pos.x, s_Point.pos.y, s_Point.pos.z),
    }
end

-- Where Provide hands items over.
--
-- This must NOT be the bulk store. A turtle has twelve usable slots and turtle.suck always takes
-- the chest's first occupied slot, so pulling from a chest holding nineteen stacks can never reach
-- the ones behind the first twelve -- the crafter sat above 64 logs reporting "short of oak_log"
-- because glass, sandstone and sand were in front of them. A handover chest that contains only
-- what was asked for makes the drone's job trivial and deterministic.
function OnSetPickup(p_ID, p_Message)
    local d = p_Message.data or {}
    local p = d.pos or d.gps
    if p == nil or p.x == nil then return false, "Missing pos" end
    if d.peripheral == nil then return false, "Missing peripheral -- see storage.stock for names" end
    DATA["pickup"] = {pos = {x = p.x, y = p.y, z = p.z}, peripheral = d.peripheral}
    PowNet.MarkDirty()
    return true, {message = ("pickup set to %s at %d,%d,%d"):format(d.peripheral, p.x, p.y, p.z),
                  pickup = DATA["pickup"]}
end

function OnStock(p_ID, p_Message)
    Rescan()
    local s_Kinds, s_Items, s_Slots = 0, 0, 0
    -- Report WHAT is held, not just how much. "4 kinds, 168 items" cannot answer "do we have fuel",
    -- which is the question that actually blocks work -- and it hid a furnace sitting idle next to
    -- a chest full of coal.
    local s_Detail = {}
    for name, e in pairs(m_Index) do
        s_Kinds = s_Kinds + 1
        s_Items = s_Items + e.total
        s_Detail[#s_Detail + 1] = {name = name, count = e.total}
    end
    table.sort(s_Detail, function(a, b) return a.count > b.count end)
    for _, f in pairs(m_Free) do s_Slots = s_Slots + f end
    -- Chest NAMES and their free space, so a handover point can be chosen deliberately. Without
    -- this the network names are invisible from outside the world and `pickup` is unconfigurable.
    local s_Chests = {}
    for _, name in ipairs(m_Chests) do
        s_Chests[#s_Chests + 1] = {name = name, free = m_Free[name]}
    end
    return true, {chests = s_Chests, message = string.format("%d kinds, %d items, %d chests, %d free slots, %d furnaces",
        s_Kinds, s_Items, #m_Chests, s_Slots, #m_Furnaces),
        kinds = s_Kinds, items = s_Items, free = s_Slots, detail = s_Detail}
end

-- Where a full drone should fly to unload. Deposit points are physical positions a drone can
-- reach and drop into; the network name alone is no use to something that has to fly there.
function OnDepositPoint(p_ID, p_Message)
    Rescan()
    for _, d in ipairs(DATA["deposits"]) do
        local f = m_Free[d.peripheral]
        if f == nil or f > 0 then
            return true, {pos = d.pos, peripheral = d.peripheral, free = f,
                          message = "drop at " .. d.pos.x .. "," .. d.pos.y .. "," .. d.pos.z}
        end
    end
    return false, "no deposit point with free space -- add one with: p StorageMan deposit -pos x y z"
end

function OnAddDeposit(p_ID, p_Message)
    local d = p_Message.data or {}
    local p = d.pos or d.gps
    if p == nil then return false, "Missing pos" end
    local s_Pos = {x = tonumber(p[1] or p.x), y = tonumber(p[2] or p.y), z = tonumber(p[3] or p.z)}
    if s_Pos.x == nil then return false, "Bad pos" end
    DATA["deposits"][#DATA["deposits"] + 1] = {pos = s_Pos, peripheral = d.peripheral}
    PowNet.MarkDirty()
    return true, {message = "deposit point at " .. s_Pos.x .. "," .. s_Pos.y .. "," .. s_Pos.z}
end

----------------------------------------------------------------------------------------------
-- Smelting
----------------------------------------------------------------------------------------------
-- Vanilla furnace slots: 1 input, 2 fuel, 3 output. Because the furnace is on the wired network
-- this needs no drone at all -- ore goes in and ingots come out entirely inside the network.
-- Matching is EXACT, plus an anchored "_ore" suffix. It used to be plain substring matching,
-- which quietly matched things that do not smelt: "sand" also matches soul_sand, and
-- "cobblestone" also matches cobblestone_stairs and mossy_cobblestone. Since input is only
-- reloaded when slot 1 is empty (below), one such item sits in the input slot forever and that
-- furnace is dead until a human notices.
local SMELTABLE = {
    ["minecraft:sand"]        = true,
    ["minecraft:red_sand"]    = true,
    ["minecraft:cobblestone"] = true,
    ["minecraft:raw_iron"]    = true,
    ["minecraft:raw_copper"]  = true,
    ["minecraft:raw_gold"]    = true,
    ["minecraft:clay_ball"]   = true,
    ["minecraft:netherrack"]  = true,
}
local FUEL      = {"minecraft:coal", "minecraft:charcoal", "minecraft:coal_block"}

local function isSmeltable(p_Name)
    if SMELTABLE[p_Name] then return true end
    -- Every vanilla ore smelts, including the deepslate_ variants. Anchored so it cannot match
    -- something that merely contains "ore".
    return string.match(p_Name, "_ore$") ~= nil
end

-- A vanilla furnace is a SIDED container. CC:T exposes only the slots belonging to the face a
-- modem is attached to, so ONE furnace appears as several small peripherals and never as a single
-- 3-slot inventory: top = input (1 slot), side = fuel (1 slot), bottom = output AND fuel (2 slots).
-- The original code assumed slots 1/2/3 on one peripheral, so toSlot 2 and 3 were out of range and
-- every transfer silently moved zero while appearing to succeed.
--
-- Do NOT try to label each face "input"/"fuel"/"output". That was tried and is wrong: the bottom
-- face accepts fuel as well as holding output, so a probe that offers it coal labels it "fuel" and
-- nothing ever drains the finished goods sitting in its other slot.
--
-- Instead, act on slot CONTENTS, which needs no geometry:
--   * a slot holding something neither smeltable nor fuel is finished product -> push it to storage
--   * an empty slot gets offered smeltable first, then fuel; the face itself rejects what it
--     cannot take, so the right thing lands in the right place with no knowledge of which face
--     this is.
local function isFuel(p_Name)
    for _, f in ipairs(FUEL) do if f == p_Name then return true end end
    return false
end

local function firstInStorage(p_Pred)
    for name, e in pairs(m_Index) do
        if e.at[1] and p_Pred(name) then return e end
    end
end

local function isSmeltableInput(p_Name) return isSmeltable(p_Name) and not isFuel(p_Name) end

local function drainTo(p_Fur, p_Slot)
    for _, cname in ipairs(m_Chests) do
        if (m_Free[cname] or 0) > 0 then
            local ok, moved = pcall(p_Fur.pushItems, cname, p_Slot)
            return ok and (moved or 0) or 0
        end
    end
    return 0
end

function ServiceFurnaces()
    if not DATA["smelting"] then return 0 end
    Rescan()
    local s_Moved = 0
    for _, fname in ipairs(m_Furnaces) do
        local ok, fur = pcall(peripheral.wrap, fname)
        if ok and fur then
            local okS, s_Size = pcall(fur.size)
            local ok2, items = pcall(fur.list)
            if okS and ok2 and s_Size then
                -- 1. Take finished product out first: a full output slot stalls the furnace.
                for slot = 1, s_Size do
                    local it = items[slot]
                    if it and not isSmeltable(it.name) and not isFuel(it.name) then
                        local moved = drainTo(fur, slot)
                        if moved > 0 then
                            s_Moved = s_Moved + 1
                            Log(("drained %s x%d from %s"):format(it.name, moved, fname))
                        end
                    end
                end

                -- 2. Fill whatever is empty. The face rejects what it cannot hold, so offering
                --    input then fuel is enough -- no need to know which face this is.
                local ok3, fresh = pcall(fur.list)
                if ok3 then
                    for slot = 1, s_Size do
                        if fresh[slot] == nil then
                            local moved = 0
                            local e = firstInStorage(isSmeltableInput)
                            if e then
                                local okp, r = pcall(fur.pullItems, e.at[1].where, e.at[1].slot, 32, slot)
                                moved = (okp and (r or 0)) or 0
                            end
                            if moved == 0 then
                                local f = firstInStorage(isFuel)
                                if f then
                                    local okp, r = pcall(fur.pullItems, f.at[1].where, f.at[1].slot, 16, slot)
                                    moved = (okp and (r or 0)) or 0
                                end
                            end
                            if moved > 0 then s_Moved = s_Moved + 1 end
                        end
                    end
                end
            end
        end
    end
    return s_Moved
end

function OnSmelt(p_ID, p_Message)
    local d = p_Message.data or {}
    if d.off then DATA["smelting"] = false else DATA["smelting"] = true end
    PowNet.MarkDirty()
    return true, {message = "smelting " .. (DATA["smelting"] and "on" or "off") ..
                  " (" .. #m_Furnaces .. " furnaces)"}
end

----------------------------------------------------------------------------------------------
local m_DroneEvents = {}

local m_ServerEvents = {
    FindItem     = { func = OnFind },
    DepositPoint = { func = OnDepositPoint },
    GetStock     = { func = OnStock },
    -- The other direction. Storage was deposit-only, which blocked every job that needs inputs.
    Provide      = { func = OnProvide },
    SetPickup    = { func = OnSetPickup },
    GetPickup    = { func = function() return true, {pickup = DATA["pickup"]} end },

    find = {
        func = OnFind, callable = true,
        params = { item = { optional = false } }
    },
    stock = { func = OnStock, callable = true, params = {} },
    deposit = {
        func = OnAddDeposit, callable = true,
        params = { pos = { length = 3 }, peripheral = { optional = true } }
    },
    smelt = {
        func = OnSmelt, callable = true,
        params = { off = { length = 0, optional = true } }
    },
}

function Render()
    local m = monitor()
    if not m then return end
    pcall(m.setTextScale, 0.5)
    m.setBackgroundColour(colors.black)
    m.clear()
    m.setCursorPos(1, 1)
    m.setTextColour(colors.cyan)
    m.write("StorageMan")
    local w, h = m.getSize()
    local line = 3
    local n = 0
    for name, e in pairs(m_Index) do
        if line > h then break end
        n = n + 1
        m.setCursorPos(1, line)
        m.setTextColour(colors.white)
        m.write(string.sub(string.format("%-30s %d", (string.gsub(name, "^.*:", "")), e.total), 1, w))
        line = line + 1
    end
    if n == 0 then
        m.setCursorPos(1, 3)
        m.setTextColour(colors.gray)
        m.write("no inventories on the wired network")
    end
end

-- Keep the index warm and run the furnaces. Nothing else ticks here: a query rescans anyway, so
-- this exists for smelting and for the display being right when nobody has asked recently.
local function Tick()
    while true do
        os.sleep(10)
        pcall(Rescan)
        pcall(ServiceFurnaces)
        pcall(Render)
    end
end

Init()
Rescan()
PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents, Render)
SetStatus("Connected!", colors.green)
Render()

parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, Tick)

print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
