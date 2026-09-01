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
        -- The other half of the scan, and it runs BEFORE the chest loop -- getType plus a wrap for
        -- every peripheral on the wired network, each one a crossing into Java. Together these two
        -- loops are what ran computer #14 over its budget by 22 seconds and left it powered off.
        os.queueEvent("scan") os.pullEvent("scan")
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
        -- BREATHE BETWEEN CHESTS, OR THE HEART OF THE SETTLEMENT GETS KILLED MID-BEAT.
        --
        -- Every chest costs a peripheral.wrap plus a list() and a size(), and each of those crosses
        -- into Java. Rescan runs on every tick AND on every query, so this loop is the single
        -- hottest thing StorageMan does -- and it had no yield in it at all.
        --
        -- CC:T terminates a coroutine that runs ~10s without yielding, uncatchably. Measured in the
        -- server log: "Terminating computer #14 due to timeout (ran over by 22.328 seconds)"
        -- followed by InterruptedException. StorageMan died mid-scan, its bootloader never reached
        -- os.reboot(), and the computer sat POWERED OFF -- taking stock, smelting and every
        -- storage query in the settlement with it, while last-run.txt still read ok=true.
        --
        -- queueEvent/pullEvent rather than sleep(0): it satisfies the watchdog and resumes in the
        -- SAME tick, so a full rescan still costs no wall clock.
        os.queueEvent("rescan") os.pullEvent("rescan")
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
        -- A Provide can walk the whole index and push from several chests per requested item.
        os.queueEvent("provide") os.pullEvent("provide")
        local s_Name  = req.name
        local s_Need  = tonumber(req.count) or 0
        local s_Moved = 0

        for name, e in pairs(m_Index) do
            if s_Moved >= s_Need then break end
            os.queueEvent("provide") os.pullEvent("provide")
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


----------------------------------------------------------------------------------------------
-- Routes: the conveyor, in software
----------------------------------------------------------------------------------------------
-- A wired modem joins any inventory to the network, and any two things on that network can hand
-- items to each other directly. So the fleet does not need belts, chutes or turtles ferrying
-- crates between buildings -- it needs to know WHICH items should flow WHERE, and to do it on a
-- tick. That is all a conveyor is.
--
-- This runs at server speed and costs no fuel. A drone hauling a stack across the base is minutes
-- of flying and a drone that cannot do anything else meanwhile; the same move here is one call.
--
-- Deliberately rule-based rather than a graph: "everything called _ore in the mine chest goes to
-- the smelter feed" is a sentence someone can read and check. A routing graph nobody can read is
-- how items end up circulating forever between two chests that each think the other wants them.

function ServiceRoutes()
    local s_Routes = DATA["routes"]
    if type(s_Routes) ~= "table" or #s_Routes == 0 then return 0 end
    Rescan()

    local s_Moved, s_Tried = 0, 0
    for _, r in ipairs(s_Routes) do
        -- Each route is a wrap plus a pushItems. Same rule as every other loop in this file that
        -- crosses into Java: breathe, or the watchdog eventually catches this one instead.
        os.queueEvent("route") os.pullEvent("route")
        if r.enabled ~= false and r.from and r.to and r.from ~= r.to then
            local src = peripheral.wrap(r.from)
            if src == nil then
                Log("route source not on the network: " .. tostring(r.from))
            elseif src.list == nil or src.pushItems == nil then
                Log("route source is not an inventory: " .. tostring(r.from))
            else
                local ok, items = pcall(src.list)
                if ok and items then
                    -- `keep` is a TOTAL reserve, not a per-slot one.
                    --
                    -- Applied per slot it silently does nothing in the common case: a chest holds
                    -- full 64-stacks, so `keep = 64` computes 64 - 64 = 0 for every slot and the
                    -- route never moves an item while looking perfectly configured. What an
                    -- operator means by "leave 64 behind" is 64 in total.
                    local s_Have = 0
                    for _, it in pairs(items) do
                        if (r.item == nil) or string.find(it.name, r.item, 1, true) ~= nil then
                            s_Have = s_Have + it.count
                        end
                    end
                    local s_Budget = s_Have - (tonumber(r.keep) or 0)

                    for slot, it in pairs(items) do
                        -- Substring match so one rule can carry a family: "_ore" moves every ore
                        -- without needing a line per ore type.
                        local s_Match = (r.item == nil) or string.find(it.name, r.item, 1, true) ~= nil
                        if s_Match and s_Budget > 0 then
                            local s_Take = math.min(it.count, s_Budget)
                            if s_Take > 0 then
                                s_Tried = s_Tried + 1
                                local ok2, n = pcall(src.pushItems, r.to, slot, s_Take)
                                if ok2 and type(n) == "number" then
                                    s_Moved = s_Moved + n
                                    s_Budget = s_Budget - n
                                else
                                    -- Say WHY. A route that silently moves nothing is
                                    -- indistinguishable from one that was never configured.
                                    Log("route " .. tostring(r.from) .. "->" .. tostring(r.to) ..
                                        " failed: " .. tostring(n))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if s_Tried > 0 then
        Log(("routes: %d attempt(s), %d item(s) moved"):format(s_Tried, s_Moved))
    end
    return s_Moved
end

function OnAddRoute(p_ID, p_Message)
    local d = p_Message.data or {}
    if d.from == nil or d.to == nil then return false, "need from and to peripheral names" end
    if d.from == d.to then return false, "a route to itself would loop forever" end
    if DATA["routes"] == nil then DATA["routes"] = {} end

    for i, r in ipairs(DATA["routes"]) do
        if r.from == d.from and r.to == d.to and r.item == d.item then
            DATA["routes"][i] = {from = d.from, to = d.to, item = d.item,
                                 keep = d.keep, enabled = d.enabled ~= false}
            PowNet.MarkDirty()
            return true, {updated = true, route = DATA["routes"][i], count = #DATA["routes"]}
        end
    end

    DATA["routes"][#DATA["routes"] + 1] = {from = d.from, to = d.to, item = d.item,
                                           keep = d.keep, enabled = d.enabled ~= false}
    PowNet.MarkDirty()
    return true, {route = DATA["routes"][#DATA["routes"]], count = #DATA["routes"]}
end

function OnGetRoutes(p_ID, p_Message)
    return true, {routes = DATA["routes"] or {}, count = #(DATA["routes"] or {})}
end

function OnClearRoutes(p_ID, p_Message)
    DATA["routes"] = {}
    PowNet.MarkDirty()
    return true, {cleared = true}
end

-- STOCK THE FLEET CAN ACTUALLY SEE.
--
-- Everything here counts items by walking peripherals -- peripheral.getNames() over the wired
-- network. That network does not exist and cannot be made to exist by this fleet: a wired modem
-- only attaches the chest beside it when somebody RIGHT-CLICKS it, and setblock can create the
-- block but not the attachment. Every modem in the bay reads peripheral=false.
--
-- So stock reported 0 kinds, 0 items, 0 chests while those chests physically held coal, copper,
-- iron and zinc, and the blindness propagated all the way up: with stock at zero every supply rule
-- evaluates as "short", so the fleet gathers raw ore for ever and can never conclude it has enough
-- of anything to smelt, craft or build. That is the whole reason nothing has ever been built.
--
-- The drones already know what they put in the chest -- Deposit() walks its own inventory to drop
-- it -- and that knowledge was being thrown away. Reporting it gives a real ledger with no
-- peripheral access whatsoever. If the wired network is ever formed, the peripheral scan is
-- authoritative again and this becomes a fallback; until then it is the only truth available.
local function ledger()
    if DATA["ledger"] == nil then DATA["ledger"] = {} end
    return DATA["ledger"]
end

local function ledgerAdd(p_Name, p_Count)
    if type(p_Name) ~= "string" or type(p_Count) ~= "number" then return end
    local L = ledger()
    L[p_Name] = math.max(0, (L[p_Name] or 0) + p_Count)
    if L[p_Name] == 0 then L[p_Name] = nil end
end

-- Drones report both directions: what they dropped, and what they took back out for fuel.
-- Counting only deposits would make the ledger drift upward for ever, which is a different lie.
-- WHERE, NOT JUST HOW MUCH.
--
-- The ledger counted totals and threw the location away, so "we have 22 oak_log" could not answer
-- "which chest". With deposits spread across the bay so drones stop jamming on one block, that is
-- the question that actually matters: the crafter stood on its own assigned chest asking for wood
-- that was two chests along, and reported "storage would not hand over ingredients" for hours.
--
-- The drone already knows where it put things -- it is standing on the chest. Recording that turns
-- a search of the bay into a lookup.
local function whereAdd(p_Name, p_Pos)
    if type(p_Name) ~= "string" or type(p_Pos) ~= "table" or p_Pos.x == nil then return end
    if DATA["where"] == nil then DATA["where"] = {} end
    DATA["where"][p_Name] = {x = p_Pos.x, y = p_Pos.y, z = p_Pos.z}
end

function OnDeposited(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_N = 0
    for name, count in pairs(d.items or {}) do
        ledgerAdd(name, tonumber(count) or 0)
        if d.at then whereAdd(name, d.at) end
        s_N = s_N + (tonumber(count) or 0)
    end
    if s_N ~= 0 then PowNet.MarkDirty() end
    return true, {counted = s_N}
end

-- Which chest was the last to receive this. Substring match, so "oak_log" finds
-- "minecraft:oak_log" and "_log" finds whichever wood was put down most recently.
-- OBSERVED CONTENTS OF ONE CHEST, REPLACING WHATEVER WE BELIEVED ABOUT IT.
--
-- The ledger added up reported deltas, which drifts the moment one report is missed -- and one was,
-- immediately: 22 logs withdrawn, the craft failed, they were put back unreported, and stock showed
-- zero while the chest held 22. Deltas cannot self-correct; a reading can.
--
-- Drones can read a chest they are standing on, so this is ground truth. Keyed by position, so a
-- fleet spread across four chests builds a real per-chest picture rather than one blurred total.
function OnChestContents(p_ID, p_Message)
    local d = p_Message.data or {}
    if type(d.at) ~= "table" or d.at.x == nil then return false, "no position" end
    if type(d.items) ~= "table" then return false, "no contents" end

    if DATA["chestAt"] == nil then DATA["chestAt"] = {} end
    local s_Key = ("%d:%d:%d"):format(d.at.x, d.at.y, d.at.z)

    -- BIND THE POSITION TO THE NETWORK NAME, BY MATCHING WHAT IS INSIDE.
    --
    -- A wired peripheral has a name and no coordinates; a drone has coordinates and no name. So
    -- StorageMan could see seven chests on the network and only send drones to the four somebody
    -- had registered by hand -- two of which were full, while chest_3 and chest_4 sat with 54 free
    -- slots each and no way to route anything to them. Drones went idle holding cargo they could
    -- not deposit, and the fetch sweep searched 2 chests out of 7 and reported the wood missing.
    --
    -- The drone is standing ON the chest and has just read it. Whichever networked inventory holds
    -- exactly that is the same chest -- so the two halves identify each other, and the mapping
    -- builds itself as drones go about their work. No registration step to forget.
    local function sameContents(p_List, p_Items)
        local a = {}
        for _, it in pairs(p_List or {}) do
            if it and it.name then a[it.name] = (a[it.name] or 0) + (it.count or 0) end
        end
        local n1, n2 = 0, 0
        for k, v in pairs(a) do n1 = n1 + 1 if (p_Items[k] or 0) ~= v then return false end end
        for _ in pairs(p_Items) do n2 = n2 + 1 end
        return n1 == n2
    end
    if DATA["chestName"] == nil then DATA["chestName"] = {} end
    if DATA["chestName"][s_Key] == nil then
        for _, name in ipairs(peripheral.getNames()) do
            os.queueEvent("scan") os.pullEvent("scan")
            local ok, inv = pcall(peripheral.wrap, name)
            if ok and inv and inv.list then
                local ok2, l = pcall(inv.list)
                if ok2 and sameContents(l, d.items) then
                    DATA["chestName"][s_Key] = name
                    -- Register it as a deposit point too, if nobody had.
                    local known = false
                    for _, dep in ipairs(DATA["deposits"] or {}) do
                        if dep.pos and dep.pos.x == d.at.x and dep.pos.y == d.at.y
                           and dep.pos.z == d.at.z then known = true dep.peripheral = name break end
                    end
                    if not known then
                        DATA["deposits"][#DATA["deposits"] + 1] = {pos = d.at, peripheral = name}
                        Log(("learned chest %s at %d,%d,%d"):format(name, d.at.x, d.at.y, d.at.z))
                    end
                    break
                end
            end
        end
    end
    local s_N = 0
    for _, c in pairs(d.items) do s_N = s_N + (tonumber(c) or 0) end
    DATA["chestAt"][s_Key] = {pos = d.at, items = d.items, at = os.epoch("utc"),
                              used = tonumber(d.used), size = tonumber(d.size)}
    PowNet.MarkDirty()
    return true, {recorded = s_Key, kinds = (function() local n=0 for _ in pairs(d.items) do n=n+1 end return n end)(), items = s_N}
end

-- MOVE A DEEP STACK WITHIN ITS CHEST SO A TURTLE CAN ACTUALLY REACH IT.
--
-- A turtle takes from a chest with suckDown, which only ever hands over the chest's FIRST occupied
-- slot. Reaching slot N therefore means pulling N-1 stacks out first -- and a turtle has SIXTEEN
-- slots. Anything past slot 16 of a 27-slot chest is unreachable no matter how many times it tries:
-- the crafter found its oak logs in slot 20, pulled sixteen stacks of cobblestone, ran out of room,
-- put it all back and reported "nothing available for: minecraft:oak_log". Then did it again, in
-- every chest, for ever. From outside it looks like a drone wandering the bay doing nothing.
--
-- StorageMan can do what the turtle cannot, now that the modems are attached: address the chest
-- over the wired network and rearrange it. One pushItems into a low slot turns an unreachable stack
-- into the first thing suckDown hands over.
-- Clear slot 1 of a chest by pushing whatever is in it anywhere else on the network.
--
-- Returns true if slot 1 is now free. Only used when the chest has no free slot of its own -- see
-- the call site for why that happens and what it costs.
local function evictLowSlot(p_Inv, p_Names, p_Self)
    for _, other in ipairs(p_Names) do
        os.queueEvent("scan") os.pullEvent("scan")
        if other ~= p_Self then
            local s_Ok, s_Moved = pcall(p_Inv.pushItems, other, 1, 64)
            if s_Ok and (tonumber(s_Moved) or 0) > 0 then
                Log(("cleared slot 1 into %s to make room at the front"):format(other))
                return true
            end
        end
    end
    return false
end

function OnBringToFront(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Match = tostring(d.match or "")
    if #s_Match < 2 then return false, "need something to look for" end
    Rescan()

    -- SEARCH THE NETWORK, NOT THE REGISTRY.
    --
    -- This walked DATA["deposits"] and wrapped dep.peripheral -- and those entries were written when
    -- the modems were unattached, so their peripheral field is nil and the loop matched nothing. It
    -- answered "no chest holds: minecraft:oak_log" to a turtle that was standing on the chest and
    -- had just read the logs out of slot 20 itself. The network is the authority on what exists;
    -- the registry only records where a drone should fly to.
    local s_Names = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ok, t = pcall(peripheral.getType, name)
        if ok and t and (t == "minecraft:chest" or tostring(t):find("chest", 1, true)
                         or tostring(t):find("barrel", 1, true)) then
            s_Names[#s_Names + 1] = name
        end
    end
    -- Position for the reply, when we know it: the drone needs somewhere to fly to.
    local function posOf(p_Name)
        for _, dep in ipairs(DATA["deposits"] or {}) do
            if dep.peripheral == p_Name then return dep.pos end
        end
        return nil
    end

    for _, s_PName in ipairs(s_Names) do
        os.queueEvent("scan") os.pullEvent("scan")
        do
            local dep = {peripheral = s_PName, pos = posOf(s_PName)}
            local ok, inv = pcall(peripheral.wrap, dep.peripheral)
            if ok and inv and inv.list then
                local ok2, l = pcall(inv.list)
                if ok2 and type(l) == "table" then
                    local s_Slot, s_Name
                    for slot, it in pairs(l) do
                        if it and it.name and it.name:find(s_Match, 1, true) then
                            s_Slot, s_Name = slot, it.name break
                        end
                    end
                    if s_Slot then
                        -- Already within reach of sixteen sucks: nothing to do.
                        if s_Slot <= 16 then
                            return true, {pos = dep.pos, slot = s_Slot, item = s_Name, moved = false}
                        end
                        -- Find a free low slot to bring it to.
                        local s_Free
                        for i = 1, 16 do if l[i] == nil then s_Free = i break end end
                        if s_Free == nil then
                            -- Every low slot is occupied: shove one to the back to make room.
                            local s_Tail
                            local s_Size = (inv.size and select(2, pcall(inv.size))) or 27
                            for i = 17, (tonumber(s_Size) or 27) do if l[i] == nil then s_Tail = i break end end
                            if s_Tail then
                                pcall(inv.pushItems, dep.peripheral, 1, 64, s_Tail)
                                s_Free = 1
                            elseif evictLowSlot(inv, s_Names, dep.peripheral) then
                                -- THE BACK OF THIS CHEST IS FULL TOO. USE SOMEBODY ELSE'S.
                                --
                                -- The shuffle above needs a free slot at the BACK of this chest, and
                                -- with every chest in the bay packed there is not one. So the stack
                                -- the drone came for sits in slot 23 for ever, unreachable, and the
                                -- drone reports "charcoal is stuck in slot 23 -- storage could not
                                -- surface it" -- which is exactly what happened while two drones sat
                                -- at zero fuel waiting for that charcoal.
                                --
                                -- The wired network is the whole point: a low slot can be cleared by
                                -- pushing its contents into ANY inventory with room, not only into
                                -- the back of this one. There were 29 free slots across six chests
                                -- at the time, and none of them were reachable to this code.
                                s_Free = 1
                            end
                        end

                        -- A FULL CHEST IS NOT A DEAD END -- THERE ARE OTHER CHESTS.
                        --
                        -- With 27 of 27 slots occupied there is nowhere to shuffle WITHIN the chest,
                        -- and this gave up: "chest is full -- nowhere to move it", leaving the logs
                        -- permanently unreachable in slot 20 and the crafter circling the bay. But
                        -- pushItems moves between inventories, which is the whole point of the wired
                        -- network -- so send the stack somewhere with room and point the drone there.
                        if s_Free == nil then
                            for _, other in ipairs(s_Names) do
                                os.queueEvent("scan") os.pullEvent("scan")
                                if other ~= dep.peripheral then
                                    local ok4, oinv = pcall(peripheral.wrap, other)
                                    if ok4 and oinv and oinv.list then
                                        local ok5, ol = pcall(oinv.list)
                                        local osize = 27
                                        if oinv.size then local o6, sz = pcall(oinv.size) if o6 then osize = tonumber(sz) or 27 end end
                                        local ofree
                                        if ok5 and type(ol) == "table" then
                                            for i = 1, math.min(16, osize) do if ol[i] == nil then ofree = i break end end
                                        end
                                        if ofree then
                                            local ok7, movedN = pcall(inv.pushItems, other, s_Slot, 64, ofree)
                                            if ok7 and (tonumber(movedN) or 0) > 0 then
                                                Log(("brought %s forward into %s slot %d (from a full chest)")
                                                    :format(tostring(s_Name), other, ofree))
                                                return true, {pos = posOf(other), slot = ofree,
                                                              item = s_Name, moved = true,
                                                              from = s_Slot, chest = other}
                                            end
                                        end
                                    end
                                end
                            end
                            return false, "every chest is full -- cannot surface " .. tostring(s_Name)
                        end
                        local ok3, moved = pcall(inv.pushItems, dep.peripheral, s_Slot, 64, s_Free)
                        if not ok3 or (tonumber(moved) or 0) == 0 then
                            return false, ("could not move %s from slot %d"):format(tostring(s_Name), s_Slot)
                        end
                        return true, {pos = dep.pos, slot = s_Free, item = s_Name,
                                      moved = true, from = s_Slot}
                    end
                end
            end
        end
    end
    return false, "no chest holds: " .. s_Match
end

function OnWhereIs(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Match = tostring(d.match or "")
    if #s_Match < 2 then return false, "need something to look for" end
    -- Observed chests first: a reading beats a running total that may have missed an event.
    for _, c in pairs(DATA["chestAt"] or {}) do
        for name, count in pairs(c.items or {}) do
            if (tonumber(count) or 0) > 0 and name:find(s_Match, 1, true) then
                return true, {pos = c.pos, item = name, count = count, source = "observed"}
            end
        end
    end
    local L = ledger()
    for name, pos in pairs(DATA["where"] or {}) do
        if name:find(s_Match, 1, true) and (L[name] or 0) > 0 then
            return true, {pos = pos, item = name, count = L[name], source = "ledger"}
        end
    end
    return false, "not recorded anywhere: " .. s_Match
end

function OnWithdrawn(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_N = 0
    for name, count in pairs(d.items or {}) do
        ledgerAdd(name, -(tonumber(count) or 0))
        -- Emptied: forget where it was, or the next lookup sends a drone to a chest that no longer
        -- has any -- which is exactly the wasted trip this index exists to prevent.
        if DATA["where"] and (ledger()[name] or 0) <= 0 then DATA["where"][name] = nil end
        s_N = s_N + (tonumber(count) or 0)
    end
    if s_N ~= 0 then PowNet.MarkDirty() end
    return true, {counted = s_N}
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

    -- No chest is visible as a peripheral, so fall back to what the drones say they delivered.
    -- Flagged as `source`, because a ledger and a census are different kinds of answer and a
    -- planner should be able to tell which one it is holding.
    local s_Source = "peripherals"
    if #m_Chests == 0 then
        s_Source = "ledger"
        s_Kinds, s_Items, s_Detail = 0, 0, {}
        for name, count in pairs(ledger()) do
            s_Kinds = s_Kinds + 1
            s_Items = s_Items + count
            s_Detail[#s_Detail + 1] = {name = name, count = count}
        end
        table.sort(s_Detail, function(a, b) return a.count > b.count end)
    end

    return true, {chests = s_Chests, source = s_Source,
        message = string.format("%d kinds, %d items, %d chests, %d free slots, %d furnaces (%s)",
        s_Kinds, s_Items, #m_Chests, s_Slots, #m_Furnaces, s_Source),
        kinds = s_Kinds, items = s_Items, free = s_Slots, detail = s_Detail}
end

-- Where a full drone should fly to unload. Deposit points are physical positions a drone can
-- reach and drop into; the network name alone is no use to something that has to fly there.
-- SPREAD THE FLEET ACROSS THE BAY INSTEAD OF QUEUEING IT ON ONE BLOCK.
--
-- This always returned the FIRST deposit point, so every drone in the fleet was sent to the same
-- single square of ground. Turtles are solid to each other, so they do not queue -- they jam: D4
-- parked on the spot, D3 hovered directly above it grinding at a drone it is forbidden to dig,
-- D7 shuffled beside them, and all three reported themselves busy while nothing moved. With five
-- drones and one access point that is not an edge case, it is the normal state.
--
-- The bay has four chests. Handing each drone a different one costs nothing and removes the
-- contention entirely -- and asking drones to be polite about a shared block would have been a
-- much worse answer than simply not sharing it.
--
-- Keyed on the asker so a given drone keeps going to the same chest: stable is easier to reason
-- about than round-robin, and it keeps each drone's route short and predictable.
-- EVERY drop-off point, for a drone that needs to FIND something.
--
-- DepositPoint hands each drone its own chest so they stop jamming on one block -- correct for
-- putting things down, wrong for picking them up. Nothing indexes which chest holds what (there is
-- no peripheral network here), so a drone looking for logs has to be able to walk the bay: keyed to
-- chest 4 of 4, the crafter stood on an empty chest asking for wood that was two chests along, and
-- reported "storage would not hand over ingredients" for hours.
-- What a chest ACTUALLY holds, from the index Rescan just built off the wired network.
--
-- Returns nil for a chest that is not on the network -- unknown, which is not the same as empty and
-- must stay distinguishable, because "unknown" is the only answer that makes a drone go and look.
local function liveContents(p_Peripheral)
    if p_Peripheral == nil then return nil end
    if m_Free[p_Peripheral] == nil then return nil end     -- not on the network: we cannot say
    local s_Items = {}
    for name, e in pairs(m_Index) do
        for _, at in ipairs(e.at or {}) do
            if at.where == p_Peripheral then
                s_Items[name] = (s_Items[name] or 0) + (at.count or 0)
            end
        end
    end
    return s_Items                                          -- possibly empty, and that is a FACT
end

function OnDepositPoints(p_ID, p_Message)
    Rescan()
    local s_Out = {}
    for _, d in ipairs(DATA["deposits"] or {}) do
        -- Ship the last OBSERVED contents alongside each point, so a drone sweeping for an item can
        -- skip the chests already known not to hold it. Without this the sweep is a blind tour of
        -- the whole bay every time -- which, with four other drones in the way and a crafter that
        -- has no pickaxe to clear its own route, took longer than the craft it was serving.
        -- THE LIVE READ WINS. THE DRONE REPORT IS THE FALLBACK.
        --
        -- This shipped DATA["chestAt"] -- what a DRONE last reported seeing -- while the Rescan on
        -- the first line of this function had just read every chest on the wired network directly.
        -- Two sources of truth for the same question, and the fetch path was handed the weaker one.
        --
        -- The drone then trusts it hard: it skips every chest "known not to hold it", so a stale
        -- snapshot does not merely slow the sweep, it removes the right chest from it entirely.
        -- Measured: 48 coal sitting in the pickup chest, visible in storage.stock, while the fetch
        -- logged "12 of 12 chests are known not to hold it -- skipping them" and CollectFuel
        -- returned "storage had nothing burnable". Three fuel reliefs for D15 ran and completed on
        -- that error; D15 stayed at zero through all of them, and so did D12 and D21.
        --
        -- ReportChest keeps its purpose -- chests off the network have no other observer -- so the
        -- drone report is still used where the live read cannot answer.
        -- LIVE READ, OR NOTHING. A STALE REPORT IS WORSE THAN NO REPORT.
        --
        -- The first version of this fix kept DATA["chestAt"] as a fallback when the live read
        -- returned nil, on the reasoning that a drone's observation beats nothing for a chest off
        -- the wired network. That reasoning is wrong for THIS field, and the bug came straight back.
        --
        -- The consumer treats `items` as authoritative and SKIPS any chest "known not to hold it".
        -- So the two answers are not "some information" versus "none" -- they are:
        --   nil        -> unknown, so the drone goes and looks. Costs one hop across the bay.
        --   stale {}   -> definite, so the drone never looks again. Costs the fleet.
        --
        -- Measured after the first fix had already shipped and was verified deployed: D24 holding
        -- 828 fuel, 64 coal sitting in storage, "12 of 12 chests are known not to hold it --
        -- skipping them", then "no fuel in storage level 828, storage had nothing burnable". The
        -- drone reports twelve deposit points and the network only has six chests, so six of them
        -- have no peripheral name, fell through to this fallback, and answered from memory.
        --
        -- ReportChest still has its purpose -- stock accounting for chests nothing else can see --
        -- it just no longer gets to tell a drone not to bother looking.
        local seen = liveContents(d.peripheral)
        s_Out[#s_Out + 1] = {pos = d.pos, peripheral = d.peripheral,
                             free = m_Free[d.peripheral], items = seen}
    end
    if #s_Out == 0 then return false, "no deposit points configured" end
    return true, {points = s_Out, count = #s_Out}
end

-- How much further than the closest deposit point is still "the same place". Inside this, the
-- emptiest chest wins and drones spread out; beyond it, the closer chest wins and a miner stops
-- flying its spoil fifty blocks up a shaft.
local DEPOSIT_NEAR = 16

-- LOCALITY FIRST, THEN EMPTIEST. A CACHE AT THE WORK SITE IS THE POINT OF HAVING ONE.
--
-- Ranking purely on free slots is right for a bay where every chest is a few blocks apart. It is
-- badly wrong the moment a deposit point exists somewhere else: a freshly placed cache is by
-- definition the emptiest chest in the settlement, so EVERY drone would be sent to it -- a crafter
-- at the surface told to fly down a mineshaft to put away eight planks.
--
-- So: among points close to the ASKING drone, keep the old emptiest-wins rule and everything the
-- comment at the call site argues for. Only when nothing is close does distance decide, which is
-- what sends a miner at the shaft face to the chest at the shaft face instead of home.
--
-- p_Near is the caller's position. Absent -- an older drone, or one with no fix -- every point
-- counts as near and the behaviour is exactly what it was.
--
-- Its own function because OnDepositPoint is already over the complexity gate, and because
-- "which chest should this drone use" is a question worth being able to read in one place.
local function pickDeposit(p_Usable, p_Near, p_FreeOf)
    local function dist(d)
        if p_Near == nil or d.pos == nil then return 0 end
        return math.abs(d.pos.x - p_Near.x) + math.abs(d.pos.y - p_Near.y)
             + math.abs(d.pos.z - p_Near.z)
    end
    local s_Closest = nil
    for _, d in ipairs(p_Usable) do
        local dd = dist(d)
        if s_Closest == nil or dd < s_Closest then s_Closest = dd end
    end
    local s_Pick, s_Best = nil, nil
    for _, d in ipairs(p_Usable) do
        local f = p_FreeOf(d)
        -- "Close" means within a short walk of the nearest option, not a fixed radius of base: the
        -- drone may legitimately be working a long way from anything.
        if f ~= nil and f > 0 and dist(d) <= (s_Closest + DEPOSIT_NEAR)
           and (s_Best == nil or f > s_Best) then
            s_Pick, s_Best = d, f
        end
    end
    return s_Pick
end

function OnDepositPoint(p_ID, p_Message)
    Rescan()
    local s_Usable = {}
    for _, d in ipairs(DATA["deposits"]) do
        local f = m_Free[d.peripheral]
        if f == nil or f > 0 then s_Usable[#s_Usable + 1] = d end
    end
    if #s_Usable == 0 then
        return false, "no deposit point with free space -- add one with: p StorageMan deposit -pos x y z"
    end

    -- SEND THEM TO THE EMPTIEST CHEST, NOT TO A FIXED ONE PER DRONE.
    --
    -- Spreading by drone id looks like load balancing and is not: the id never changes, so each
    -- drone returns to the SAME chest for its entire life regardless of what is in it. D7 was posted
    -- to -476 permanently -- the fullest chest in the bay at 25 of 27 slots, and the one the crafter
    -- was camped on -- while -474 sat completely empty two blocks away. Every one of its deposits
    -- queued for the single busiest square in the settlement, and its gathers failed behind them.
    --
    -- Observed contents make the honest choice available: fewest items wins. It self-balances,
    -- it keeps drones off each other's squares, and it degrades to the old behaviour for any chest
    -- nobody has looked in yet.
    -- Rank on FREE SLOTS, and never offer a chest with none.
    --
    -- Ranking on the item total sent drones to chests that were slot-full but light, where they
    -- could not unload at all -- and a miner that cannot unload cannot gather either, so its task
    -- failed on arrival every time. m_Free is authoritative when the peripheral is known; the
    -- observed slot count covers the chests whose deposit entries predate the modems working and
    -- therefore have no peripheral name at all.
    local function freeOf(d)
        if d.peripheral and m_Free[d.peripheral] ~= nil then return m_Free[d.peripheral] end
        if d.pos == nil or DATA["chestAt"] == nil then return nil end
        local rec = DATA["chestAt"][("%d:%d:%d"):format(d.pos.x, d.pos.y, d.pos.z)]
        if rec == nil or rec.used == nil then return nil end
        return math.max(0, (tonumber(rec.size) or 27) - tonumber(rec.used))
    end
    local s_Pick = pickDeposit(s_Usable, p_Message.data and p_Message.data.near, freeOf)
    -- Nothing with known free space: fall back to a point of unknown fullness rather than refuse,
    -- but skip the ones we KNOW are full.
    if s_Pick == nil then
        for _, d in ipairs(s_Usable) do
            if freeOf(d) == nil then s_Pick = d break end
        end
    end
    -- Nothing observed yet: fall back to the id spread, which is at least deterministic.
    if s_Pick == nil then
        s_Pick = s_Usable[(math.abs(tonumber(p_ID) or 0) % #s_Usable) + 1]
    end
    return true, {pos = s_Pick.pos, peripheral = s_Pick.peripheral,
                  free = m_Free[s_Pick.peripheral], points = #s_Usable,
                  message = "drop at " .. s_Pick.pos.x .. "," .. s_Pick.pos.y .. "," .. s_Pick.pos.z}
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

-- WHAT KIND OF SMELT IS THIS? One classifier, so nothing downstream can disagree with it.
--
-- "Can this be smelted" and "how badly do we want it smelted" were answered by two functions that
-- each re-derived the categories from item names. They drifted, and the drift was silent:
-- isSmeltable did not recognise a log, while smeltRank ranked logs FIRST as the only fuel-positive
-- smelt in the settlement. The ranking was dead code for the exact case it existed for, and the
-- furnaces burned ore while 255 logs sat in storage and charcoal stayed at zero.
--
-- Order matters: raw_iron and raw_copper are in SMELTABLE and are ORE, so the ore test runs first.
local function smeltCategory(p_Name)
    if string.match(p_Name, "_log$") or string.match(p_Name, "_wood$") then return "wood" end
    if string.match(p_Name, "_ore$") or string.find(p_Name, "raw_", 1, true) then return "ore" end
    if SMELTABLE[p_Name] then
        -- 2,700 in stock and no demand: worth smelting only when there is fuel to spare.
        if string.find(p_Name, "cobble", 1, true) then return "bulk" end
        return "other"
    end
    return nil
end

local function isSmeltable(p_Name)
    return smeltCategory(p_Name) ~= nil
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

-- SMELT WHAT PAYS FOR ITSELF FIRST.
--
-- firstInStorage walks `pairs(m_Index)`, and table order in Lua is arbitrary. The very first tick
-- after the furnace input face was wired, that arbitrary order handed the settlement's LAST fuel to
-- cobblestone: "drained minecraft:stone x2 from minecraft:furnace_0", with 2,410 cobblestone in
-- front of 657 raw_copper. Storage had zero coal and zero charcoal at the time, so those were
-- literally the last smelts available and they produced a decorative block.
--
-- Rank, lowest first:
--   1  logs. The ONLY fuel-positive smelt: one coal smelts eight logs into eight charcoal, so this
--      is the smelt that grows the fuel supply instead of consuming it. When fuel is the binding
--      constraint -- and here it always is -- nothing else should ever go in ahead of a log.
--   2  raw ore. What the settlement is actually mining for, and what building needs.
--   9  cobblestone and deepslate. 2,585 in stock, no demand, and a furnace-hour each.
-- Lowest smelts first. wood: the ONLY fuel-positive smelt -- one coal turns eight logs into eight
-- charcoal -- so it is the one smelt that grows the fuel supply rather than spending it. ore: what
-- the settlement is mining for. bulk: cobblestone, of which there is no shortage and no demand.
local SMELT_RANK = { wood = 1, ore = 2, other = 5, bulk = 9 }

-- LEAVE ENOUGH WOOD TO BUILD WITH. THE FURNACES WILL TAKE EVERY LOG OTHERWISE.
--
-- Wood is smelt rank 1 -- the fuel-positive smelt, and rightly, since logs to charcoal is the only
-- conversion that grows the fuel supply. But rank 1 with no floor means EVERY log that reaches
-- storage goes into a furnace the moment it lands, and oak_log can never rise above zero.
--
-- Measured, with the lumber sweep finally running and delivering: charcoal climbing 32 -> 47 -> 51
-- while oak_log sat at 0 and the crafter reported "craft oak_planks x32" it could not start. Planks
-- are eight logs. They were never going to exist.
--
-- That matters far beyond planks. Planks gate chests, chests gate storage, and order.build queues
-- the crafting a blueprint needs before the build itself -- so with no planks, every build ever
-- ordered stalled at its craft step. Eighteen storage plots and two crafting plots sit in
-- 'clearing' for exactly this reason. The settlement was smelting its own construction material.
--
-- So: keep a floor of wood back. Above the floor the furnaces get it and the fuel chain runs as
-- before; at or below it the wood is left alone for crafting. Only wood, because only wood is both
-- the fuel input AND a building material -- ore has no competing use.
local WOOD_CRAFT_RESERVE = 16

local function reservedForCrafting(p_Name, p_Entry)
    if smeltCategory(p_Name) ~= "wood" then return false end
    return (tonumber(p_Entry.total) or 0) <= WOOD_CRAFT_RESERVE
end

local function smeltRank(p_Name)
    return SMELT_RANK[smeltCategory(p_Name) or ""] or 5
end

-- The best thing waiting to be smelted, or nil if there is nothing. Same contract as
-- firstInStorage(isSmeltableInput), which is what this replaces at both call sites.
-- Burnable units in storage, counted so the furnaces can tell "we have fuel to spend" from "we are
-- spending the settlement's last fuel".
local function fuelInStorage()
    local s_Units = 0
    for name, e in pairs(m_Index) do
        if isFuel(name) then s_Units = s_Units + (e.total or 0) end
    end
    return s_Units
end

-- Below this, the furnaces smelt ONLY what makes more fuel.
--
-- 32 coal is four stacks of smelting -- enough to convert a delivery of logs into charcoal and get
-- the fleet moving again, which is the only thing worth spending the last of it on.
local SMELT_FUEL_RESERVE = 32

local function bestSmeltInput()
    -- DO NOT SPEND THE LAST FUEL ON SOMETHING THAT DOES NOT MAKE FUEL.
    --
    -- The ranking already prefers logs, but preference is not a limit: with no logs in stock it
    -- happily fell through to raw ore and burned every coal in the settlement on it. That is what
    -- happened to two 64-coal bootstraps in a row -- storage went to 0 burnable while copper_ingot
    -- climbed to 681, with three drones at zero fuel and no way to fetch more. The settlement
    -- converted the one thing it could not make into 681 ingots it has no use for.
    --
    -- Smelting ore is worth doing when there is fuel to spare and is never worth the LAST of it, for
    -- the same reason the supply loop refuses to gather dirt during a fuel emergency: everything
    -- else the settlement wants is downstream of being able to move.
    local s_Scarce = fuelInStorage() < SMELT_FUEL_RESERVE
    local s_Best, s_Rank = nil, nil
    for name, e in pairs(m_Index) do
        if e.at[1] and isSmeltableInput(name) and not reservedForCrafting(name, e) then
            local r = smeltRank(name)
            -- Rank 1 is the fuel-positive smelt (logs -> charcoal). When fuel is scarce that is the
            -- only thing allowed in, so a furnace either grows the supply or stays cold.
            if (not s_Scarce) or r == 1 then
                if s_Rank == nil or r < s_Rank then s_Best, s_Rank = e, r end
            end
        end
    end
    return s_Best
end

local function drainTo(p_Fur, p_Slot)
    for _, cname in ipairs(m_Chests) do
        os.queueEvent("scan") os.pullEvent("scan")
        if (m_Free[cname] or 0) > 0 then
            local ok, moved = pcall(p_Fur.pushItems, cname, p_Slot)
            return ok and (moved or 0) or 0
        end
    end
    return 0
end

-- Last thing ServiceFurnaces reported, so the tick can stay quiet while nothing changes.
local m_LastFurnaceNote = nil

-- SAY WHAT THE FURNACES ARE DOING, OR SMELTING FAILS INVISIBLY.
--
-- This function wrote nothing, ever, and the tick calls it inside a pcall -- so a throw, a furnace
-- that cannot be wrapped, or simply never finding an input all look identical from outside:
-- storage sits on 657 raw_copper next to two working furnaces with coal available and no ingot
-- ever appears. There is no way to tell "smelting is off" from "smelting is on and doing nothing",
-- which is the difference between flipping a flag and debugging a peripheral.
--
-- Deduplicated against the last message so a healthy idle tick costs one line, not one every 10s.
local function furnaceNote(p_Msg)
    if p_Msg == m_LastFurnaceNote then return end
    m_LastFurnaceNote = p_Msg
    Log("smelt: " .. p_Msg)
end

-- One line describing why a tick moved what it moved.
--
-- Separated from ServiceFurnaces so the branches live here: that function sits on the complexity
-- gate, and the whole point of this diagnostic is that it must not be the thing that gets cut.
-- "moved=0 input=NONE" and "moved=0 input=minecraft:raw_copper" are completely different faults --
-- the first is an empty larder, the second is a furnace that will not accept what it is offered --
-- and without this they are the same silence.
local function furnaceSummary(p_Moved)
    local s_In = bestSmeltInput()
    local s_Fu = firstInStorage(isFuel)
    local s_Sizes = {}
    for _, fname in ipairs(m_Furnaces) do
        os.queueEvent("scan") os.pullEvent("scan")
        local ok, fur = pcall(peripheral.wrap, fname)
        local okS, s_Size = false, nil
        if ok and fur then okS, s_Size = pcall(fur.size) end
        s_Sizes[#s_Sizes + 1] = fname .. ":" .. ((okS and tostring(s_Size)) or "unreadable")
    end
    return ("%d furnace(s) [%s] moved=%d input=%s fuel=%s"):format(
        #m_Furnaces, table.concat(s_Sizes, " "), p_Moved,
        (s_In and (s_In.name or "yes")) or "NONE",
        (s_Fu and (s_Fu.name or "yes")) or "NONE")
end

-- Does this item belong on this face at all?
--
-- The input face takes exactly one kind of thing and will physically accept anything, so it needs
-- the stricter test; the output/fuel face keeps fuel AND finished product, so only genuinely
-- finished goods come off it. Split out because ServiceFurnaces sits on the complexity gate and
-- this is the decision most worth being able to read on its own.
-- What may stay in a furnace's fuel slot. Coal only: charcoal is the PRODUCT of the smelt that
-- matters most here, and leaving it in the furnace strands the settlement's renewable fuel inside
-- the machine that made it.
local KEEP_AS_FUEL = { ["minecraft:coal"] = true, ["minecraft:coal_block"] = true }

local function wrongForFace(p_Item, p_IsInputFace, p_Slot, p_Size)
    if p_Item == nil then return false end
    if p_IsInputFace then return not isSmeltableInput(p_Item.name) end
    -- THE OUTPUT SLOT MUST BE EMPTIED EVEN WHEN WHAT IS IN IT IS FUEL.
    --
    -- The bottom face exposes TWO slots -- fuel and output -- and this treated them alike: "leave
    -- anything that is fuel". Right for the fuel slot, wrong for the output slot, and catastrophic
    -- for the one product that is both. CHARCOAL is fuel, so the drain skipped it, and it piled up
    -- in the output slot until the furnace jammed on its own success.
    --
    -- Measured: logs falling 247 -> 135 as the furnaces consumed them, charcoal visible in both
    -- output slots in the world, and charcoal in STORAGE flat at 0 the whole time. The settlement
    -- was finally making its renewable fuel and could not collect any of it.
    --
    -- SLOT ORDER IS NOT WHAT YOU THINK, SO DO NOT DEPEND ON IT.
    --
    -- I first wrote this as "the last exposed slot is the output". Vanilla's SLOTS_FOR_DOWN is
    -- {2, 1} -- OUTPUT first, fuel second -- so that drained the FUEL slot and left the product.
    -- Observed: storage coal falling 64 -> 48 while both furnaces sat on a FULL 64-stack of
    -- charcoal with CookTime 0 and BurnTime 0, stalled on their own output.
    --
    -- So decide by CONTENT, which needs no knowledge of the layout. On this face everything is
    -- product except the fuel we are deliberately keeping there. Charcoal is fuel AND product, and
    -- it belongs in storage where the whole fleet can reach it -- a furnace holding its own
    -- charcoal is 64 charcoal nobody can burn.
    return not KEEP_AS_FUEL[p_Item.name]
end

-- The one thing this face is for.
local function fillFor(p_IsInputFace)
    if p_IsInputFace then return bestSmeltInput(), 32 end
    return firstInStorage(isFuel), 16
end

function ServiceFurnaces()
    if not DATA["smelting"] then return 0 end
    Rescan()
    -- No early return for "no furnaces": the loop below simply does not run, and the summary at
    -- the end reports `0 furnace(s)` -- which is the diagnostic that case needed anyway.
    local s_Moved = 0
    for _, fname in ipairs(m_Furnaces) do
        -- Same reason as the chest loop: each furnace is a wrap, a size, two lists and up to four
        -- item transfers, all crossing into Java, and this runs every tick.
        os.queueEvent("smelt") os.pullEvent("smelt")
        local ok, fur = pcall(peripheral.wrap, fname)
        if ok and fur then
            local okS, s_Size = pcall(fur.size)
            local ok2, items = pcall(fur.list)
            if okS and ok2 and s_Size then
                -- WHICH FACE THIS IS DECIDES WHAT MAY GO IN. THE FACE WILL NOT DECIDE IT FOR US.
                --
                -- This used to offer input to any empty slot and then fall back to offering FUEL,
                -- on the stated reasoning that "the face rejects what it cannot hold". That is true
                -- of the fuel and output faces and FALSE of the input face: a vanilla furnace's top
                -- slot accepts any item pushed into it, smeltable or not.
                --
                -- So coal went into the INPUT slot, where nothing can ever consume it, and the
                -- furnace stalled with a full input slot that no log could displace. Read out of the
                -- world after wood was finally in stock:
                --
                --   Items: [{count: 6, Slot: 0b, coal}, {count: 16, Slot: 1b, coal}]
                --   BurnTime: 0, CookTime: 0
                --
                -- while StorageMan reported "input=yes fuel=yes moved=0" and charcoal stayed at 0.
                -- Both furnaces, jammed the same way, by the servicing code that was meant to feed
                -- them. Note the peripheral size tells us the face: 1 = top (input only),
                -- 2 = bottom (output and fuel). We already log it; now we act on it.
                local s_IsInputFace = (s_Size == 1)

                -- 1. Clear what does not belong on this face. On the output/fuel face that means
                --    finished product; on the INPUT face it means anything that is not a valid
                --    smelt input -- which is how the jammed coal gets out.
                for slot = 1, s_Size do
                    local it = items[slot]
                    if wrongForFace(it, s_IsInputFace, slot, s_Size) then
                        local moved = drainTo(fur, slot)
                        if moved > 0 then
                            s_Moved = s_Moved + 1
                            Log(("drained %s x%d from %s"):format(it.name, moved, fname))
                        end
                    end
                end

                -- 2. Fill what is empty, with the ONE thing this face is for.
                local ok3, fresh = pcall(fur.list)
                if ok3 then
                    for slot = 1, s_Size do
                        if fresh[slot] == nil then
                            local e, s_Max = fillFor(s_IsInputFace)
                            local moved = 0
                            if e then
                                local okp, r = pcall(fur.pullItems, e.at[1].where, e.at[1].slot,
                                                     s_Max, slot)
                                moved = (okp and (r or 0)) or 0
                            end
                            if moved > 0 then s_Moved = s_Moved + 1 end
                        end
                    end
                end
            end
        end
    end
    furnaceNote(furnaceSummary(s_Moved))
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
    DepositPoints = { func = OnDepositPoints },
    GetStock     = { func = OnStock },
    Deposited    = { func = OnDeposited },
    ChestContents = { func = OnChestContents },
    WhereIs      = { func = OnWhereIs },
    BringToFront = { func = OnBringToFront },
    Withdrawn    = { func = OnWithdrawn },
    -- The other direction. Storage was deposit-only, which blocked every job that needs inputs.
    Provide      = { func = OnProvide },
    AddRoute     = { func = OnAddRoute },
    GetRoutes    = { func = OnGetRoutes },
    ClearRoutes  = { func = OnClearRoutes },
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
        -- Routes ride the same tick as smelting: both are just moving items between things on the
        -- wired network, and neither needs a drone to do it.
        pcall(ServiceRoutes)
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
