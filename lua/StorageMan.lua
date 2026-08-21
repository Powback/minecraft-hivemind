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
    local m = peripheral.wrap("top")
    if m and m.write then return m end
    return peripheral.find("monitor")
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
local function inventories()
    local s_Chests, s_Furnaces = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
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

function OnStock(p_ID, p_Message)
    Rescan()
    local s_Kinds, s_Items, s_Slots = 0, 0, 0
    for _, e in pairs(m_Index) do s_Kinds = s_Kinds + 1 s_Items = s_Items + e.total end
    for _, f in pairs(m_Free) do s_Slots = s_Slots + f end
    return true, {message = string.format("%d kinds, %d items, %d chests, %d free slots, %d furnaces",
        s_Kinds, s_Items, #m_Chests, s_Slots, #m_Furnaces),
        kinds = s_Kinds, items = s_Items, free = s_Slots}
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

function ServiceFurnaces()
    if not DATA["smelting"] then return 0 end
    Rescan()
    local s_Moved = 0
    for _, fname in ipairs(m_Furnaces) do
        local ok, fur = pcall(peripheral.wrap, fname)
        if ok and fur then
            local ok2, items = pcall(fur.list)
            if ok2 then
                -- Pull finished output first, so a full output slot never stalls the furnace.
                if items[3] then
                    for _, cname in ipairs(m_Chests) do
                        if (m_Free[cname] or 0) > 0 then
                            local okp = pcall(fur.pushItems, cname, 3)
                            if okp then s_Moved = s_Moved + 1 end
                            break
                        end
                    end
                end
                -- Then top up fuel and input from storage.
                if items[2] == nil or items[2].count < 8 then
                    for _, fuel in ipairs(FUEL) do
                        local e = m_Index[fuel]
                        if e and e.at[1] then
                            pcall(fur.pullItems, e.at[1].where, e.at[1].slot, 16, 2)
                            break
                        end
                    end
                end
                -- Un-jam: anything in the input slot that cannot smelt would sit there forever,
                -- because the refill below only fires when slot 1 is empty. Push it back to
                -- storage instead of leaving the furnace dead.
                if items[1] and not isSmeltable(items[1].name) then
                    for _, cname in ipairs(m_Chests) do
                        if (m_Free[cname] or 0) > 0 then
                            local okj = pcall(fur.pushItems, cname, 1)
                            if okj then
                                print("unjammed " .. fname .. ": " .. tostring(items[1].name))
                                items[1] = nil
                                s_Moved = s_Moved + 1
                            end
                            break
                        end
                    end
                end
                if items[1] == nil then
                    for name, e in pairs(m_Index) do
                        if isSmeltable(name) and e.at[1] then
                            pcall(fur.pullItems, e.at[1].where, e.at[1].slot, 32, 1)
                            s_Moved = s_Moved + 1
                            break
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
