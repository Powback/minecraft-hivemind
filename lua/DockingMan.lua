--DroneMan
--Goal: Handle drones and their status

-- Find the monitor at render time, not once at load, and tolerate not having one.
--
-- This was `peripheral.wrap("top")` evaluated once when the module loaded, and every Render call
-- dereferenced the result. When the monitor block went missing the handle went nil and the whole
-- server died -- DroneMan, the thing that hands out drone identities and answers heartbeats, was
-- taken down by a display block disappearing. A monitor is cosmetic; it must never be load-bearing.
--
-- Re-finding also means a monitor placed AFTER boot starts working without a reboot.
local function monitor()
    return PowNet.Monitor("top")
end


Log("Starting...")
function Init()
    if DATA["towers"] == nil then
        DATA["towers"] = {}
    end
    if DATA["nameLookup"] == nil then
        DATA["nameLookup"] = {}
    end
    if(DATA["nextTower"] == nil) then
        DATA["nextTower"] = 1
    end
    if DATA["occupants"] == nil then
        DATA["occupants"] = {}
    end
    -- The compass constants that used to be declared here were UNUSED, and wrong: they read
    -- `North, West, East, South = 0, 1, 2, 3`, swapping East and South against pgps, PowGPSServer
    -- and DroneLogic. Nothing in this file ever read them, so it never fired -- but this is the
    -- module that hands out dock berths and their orientations, and one future reference would have
    -- turned every approach ninety degrees. Deleted rather than corrected: the canonical set lives
    -- in pgps (pgps.HEADINGS), and a copy that agrees today is still a copy that can drift.
end

-- CANONICAL COMPASS: N, W, S, E = 0, 1, 2, 3, and north is MINUS z.
--
-- This read 0=n, 1=e, 2=s, 3=w -- the clockwise convention the vendored LAMA library uses, not the
-- anticlockwise one every first-party module has agreed on since the compass was unified. It also
-- had the SIGN wrong: it returned z = +1 for north, and north is -z.
--
-- So a berth on heading 1 was placed to the east when the fleet meant west, and a berth on heading
-- 0 was placed south of the tower instead of north. This is the module that hands out dock berths
-- AND their approach orientation, so both the slot position and the direction a drone faces to
-- reach it were wrong.
--
-- The dead constants in Init() had exactly this fault and were deleted for it. This one is live,
-- and was missed because deleting the unused copy looked like finishing the job.
function GetXZFromHeading( p_Heading )
    if p_Heading == 0 then return {x =  0, z = -1} end   -- north
    if p_Heading == 1 then return {x = -1, z =  0} end   -- west
    if p_Heading == 2 then return {x =  0, z =  1} end   -- south
    if p_Heading == 3 then return {x =  1, z =  0} end   -- east
    return false
end
function GetTowerPos( p_Index )
    local s_Pos = DATA["towers"][p_Index].pos
    return {x= s_Pos.x, y = s_Pos.y, z = s_Pos.z}
end
function GetSlotDirection(p_Slot)
    return p_Slot % 4
end
function GetSlotHeading(p_Slot)
    local s_Slot = p_Slot % 4
    if(s_Slot == 0) then
        return 2
    end
    if(s_Slot == 1) then
        return 3
    end
    if(s_Slot == 2) then
        return 0
    end
    if(s_Slot == 3) then
        return 1
    else
        return 0
    end
end

function GetXYZFromSlot( p_Tower, p_Slot)
    local s_Direction = (p_Slot % 4)
    local s_TowerPos = GetTowerPos(p_Tower)
    local s_Offset = GetXZFromHeading(s_Direction)
    local s_Ret = s_TowerPos
    local s_yLevel = math.floor(p_Slot / 4)

    s_Ret.x = s_TowerPos.x + s_Offset.x
    s_Ret.z = s_TowerPos.z + s_Offset.z
    s_Ret.y = s_yLevel + s_TowerPos.y
    return s_Ret
end

function GetSlotPosition(p_Tower, p_Slot)
    local s_SlotHeading = p_Slot % 4
    print(s_SlotHeading)
end

-- OCCUPANCY IS THE OCCUPANTS TABLE, NOT A COUNTER.
--
-- freeSlot was a number that only ever went up. RegisterSlot incremented it, nothing ever decremented
-- it, and there is no release path anywhere in this module -- so slots were handed out in sequence
-- and never returned. A tower went permanently full while standing physically empty, and every drone
-- reboot burned another slot, which on a day of fleet-wide restarts is most of them. The occupants
-- table was written on every allocation and then never consulted for one.
--
-- So ask the table. A slot is free if nobody is recorded in it; the count of used slots is however
-- many entries it holds. freeSlot survives only as a display number.
local function slotTaken(p_Tower, p_Slot)
    local t = DATA["towers"][p_Tower]
    return t ~= nil and t.occupants ~= nil and t.occupants[tostring(p_Slot)] ~= nil
end

local function slotDistance(p_Tower, p_Slot, p_Pos)
    if p_Pos == nil then return 0 end
    local s = GetXYZFromSlot(p_Tower, p_Slot)
    local dx, dy, dz = (s.x - (p_Pos.x or 0)), (s.y - (p_Pos.y or 0)), (s.z - (p_Pos.z or 0))
    return dx * dx + dy * dy + dz * dz
end

-- NEAREST FREE SLOT, NOT THE NEXT ONE IN SEQUENCE.
--
-- The tower is one column of docks running its whole height, so "the next slot" can be seventy
-- blocks below the drone asking for it. A drone finishing on the top floor should dock on the top
-- floor. Distance is squared and left that way -- it is only ever compared, never read.
function GetFreeSlot(p_Pos)
    local s_Best, s_BestD = nil, nil
    for k, v in pairs(DATA["towers"]) do
        for slot = 0, (v.slots or 0) - 1 do
            if not slotTaken(k, slot) then
                local d = slotDistance(k, slot, p_Pos)
                if s_BestD == nil or d < s_BestD then
                    s_Best, s_BestD = {tower = k, slot = slot}, d
                end
            end
        end
    end
    return s_Best
end

function RegisterSlot( p_Id, p_Tower, p_Slot )
    DATA["towers"][p_Tower].occupants[tostring(p_Slot)] = tostring(p_Id)
    local s_Used = 0
    for _ in pairs(DATA["towers"][p_Tower].occupants) do s_Used = s_Used + 1 end
    DATA["towers"][p_Tower].freeSlot = s_Used
end

-- Give the slot back. Without this nothing ever did.
function ReleaseSlot( p_Id )
    local s_Held = DATA["occupants"][p_Id]
    if s_Held == nil then return false end
    local t = DATA["towers"][s_Held.tower]
    if t and t.occupants then
        t.occupants[tostring(s_Held.slot)] = nil
        local s_Used = 0
        for _ in pairs(t.occupants) do s_Used = s_Used + 1 end
        t.freeSlot = s_Used
    end
    DATA["occupants"][p_Id] = nil
    PowNet.MarkDirty()
    return true
end

function OnAllocateDocking(p_Id, p_Message)
    local s_Id = p_Message.data.id
    -- Already holding one: hand back the same slot rather than consuming another. A drone asks
    -- again after every reboot, and with 23 drones restarting repeatedly that is what emptied the
    -- tower of slots without a single drone actually parking.
    if DATA["occupants"][s_Id] ~= nil then
        return true, DATA["occupants"][s_Id]
    end
    local s_Slot = GetFreeSlot(p_Message.data.pos)
    if(s_Slot == nil) then
        print("No registered docking stations")
        return false, "No registered docking stations"
    end
    local s_DockingPos = GetXYZFromSlot(s_Slot.tower, s_Slot.slot)
    local s_DockingHeading = GetSlotHeading(s_Slot.slot)
    RegisterSlot(p_Message.data.id, s_Slot.tower, s_Slot.slot)

    DATA["occupants"][s_Id] = {tower = s_Slot.tower, slot = s_Slot.slot, pos = s_DockingPos, heading = s_DockingHeading}
    -- A slot is consumed here (freeSlot advanced in RegisterSlot); if that is lost on a restart
    -- the next drone is handed a slot that is already physically occupied.
    PowNet.MarkDirty()
    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "SetDronePos", {id = s_Id, pos = s_DockingPos})
    local s_Response = PowNet.sendAndWaitForResponse("MapServer", s_Message, PowNet.SERVER_PROTOCOL)
    print(s_Response)
    -- Ignore the response, we just want to wait for it
    return true, DATA["occupants"][s_Id]
end

function OnFreeDocking(p_ID, p_Message)
    local s_Id = p_Message.data and p_Message.data.id
    if s_Id == nil then return false, "Missing id" end
    if ReleaseSlot(s_Id) then
        return true, {id = s_Id, released = true}
    end
    -- Not an error worth failing on: a drone that never docked asking to undock is harmless, and
    -- refusing would make the caller retry something that is already true.
    return true, {id = s_Id, released = false, message = "was not holding a slot"}
end

function OnListDockingTowers(p_Id, p_Message)
    local s_List = {}
    local s_Message = ""
    for _,l_Tower in pairs(DATA["towers"]) do
        print(_)
        s_List[l_Tower.id] = l_Tower.name
        s_Message = s_Message .. l_Tower.id .. ", "
    end
    if s_Message == "" then
        s_Message = "No towers registered."
    end
    return true, {message = s_Message, list = s_List}
end

function OnDelDockingTower(p_Id, p_Message)
    if(p_Message.data == nil or p_Message.data.id == nil) then
        return false, "No ID specified"
    end
    local s_ID = p_Message.data.id

    if(DATA["towers"][s_ID] == nil) then
        return false, "Tower " .. s_ID .. " does not exist."
    end
    local s_Tower = DATA["towers"][s_ID]
    local name = tostring(s_Tower.name)

    -- REMOVE FIRST, TELL AFTERWARDS -- AND YIELD WHILE TELLING.
    --
    -- This notified every occupant before deleting anything, in a tight loop with no yield. CC kills
    -- a coroutine that runs more than ten seconds without yielding, uncatchably, so on a tower whose
    -- sixteen berths were held by drones that no longer exist the handler died partway through the
    -- notifications -- the caller saw "no response from DockingMan.rm", and because the delete came
    -- AFTER the loop the tower was never removed. Retrying could not help: every attempt died in the
    -- same place, so a full tower became permanently unremovable.
    --
    -- That mattered because a full tower is precisely the one you need to remove: freeSlot had
    -- walked past the end (16 of 16 slots, all ghosts), every dock request answered "No registered
    -- docking stations", and idle drones hovered over the storage bay instead of parking -- which is
    -- the congestion that was failing pickups and stalling builds.
    --
    -- The state change is what matters and it is now durable before anything can kill us. The
    -- notifications are a courtesy to drones that may not even exist.
    DATA["towers"][s_ID] = nil
    PowNet.MarkDirty()

    for _, l_DroneID in pairs(s_Tower.occupants or {}) do
        local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "DroneHomeless", {id = l_DroneID})
        -- silent: allow (the tower is already deleted and durable; a drone that misses this re-docks on its next request, which reads the live tower list)
        pcall(PowNet.send, "DroneMan", s_Message)
        -- queueEvent + pullEvent, NOT os.sleep(0). A zero-delay timer does not fire in the same
        -- tick, so sleep(0) is a stall rather than a yield; this satisfies the watchdog and resumes
        -- immediately, because the event is already queued when we ask for it. See lua-hygiene.
        os.queueEvent("dockRm") os.pullEvent("dockRm")
    end
    return true, {message = "Destroyed tower. ID: " .. s_ID .. ", name: " .. name, id = s_ID}
end


function OnAddDockingTower(p_Id, p_Message)
    -- Fix defaults
    if(p_Message.data.gps ~= nil and p_Message.data.pos == nil) then
        p_Message.data.pos = p_Message.data.gps
    end
    if(p_Message.data.height == nil) then
        return false, "Missing height"
    end
    if (p_Message.data.pos == nil) then
        return false, "Missing pos"
    end
    -- ACCEPT THE ARRAY FORM, BECAUSE CALLERS SEND IT.
    --
    -- The in-game command passes three arguments and everything else passes a table, so pos arrives
    -- as either {x=,y=,z=} or {[1],[2],[3]}. Storing whichever turned up meant a caller using the
    -- array form wrote a tower whose x, y and z were all nil -- valid enough to persist, fatal on
    -- the next render, and unfixable afterwards because the module could not stay up to be told to
    -- delete it. Normalise here, where it is cheap, rather than at every read.
    local s_P = p_Message.data.pos
    if s_P.x == nil and s_P[1] ~= nil then
        p_Message.data.pos = {x = tonumber(s_P[1]), y = tonumber(s_P[2]), z = tonumber(s_P[3])}
        s_P = p_Message.data.pos
    end
    if s_P.x == nil or s_P.y == nil or s_P.z == nil then
        return false, "pos needs x, y and z"
    end
    if (p_Message.data.name == nil) then
        return false, "Missing name"
    end

    local s_Tower = {
        id = tostring(DATA["nextTower"]),
        name = p_Message.data.name,
        pos = p_Message.data.pos,
        height = p_Message.data.height,
        freeSlot = 0,
        slots = p_Message.data.height * 4,
        occupants = {}
    }

    DATA["towers"][s_Tower.id] = s_Tower
    DATA["nextTower"] = DATA["nextTower"] + 1
    DATA["nameLookup"][p_Message.data.name] = s_Tower.id

    print("Added Docking Tower")
    PowNet.MarkDirty()
    return true, {message = "Created tower. ID: " .. s_Tower.id, id = s_Tower.id}
end


function OnEditDockingTower(p_Id, p_Message)

end

function OnGetDroneInfo(p_ID, p_Message)
    return true, {drones = DATA["occupants"]}
end

local m_DroneEvents = {

}

local m_ServerEvents = {
    add = {
        callable = true,
        params = {
            name = {
                required = true
            },
            height = {
            },
            pos = {
                length = 3
            },
                    -- DECLARED, OR IT NEVER ARRIVES. PowNet filters the payload to the fields named
            -- here the moment a params block exists, silently, and the call still returns
            -- success -- which is how order.build's dependsOn was dropped for months while
            -- every call reported fine. See hq/test/wiring.test.ts.
            gps = {
                optional = true
            },
            x = {
                optional = true
            },
            y = {
                optional = true
            },
            z = {
                optional = true
            },
},
        func = OnAddDockingTower
    },

    rm = {
        callable = true,
        params = {
            id = {
                required = true
            }
        },
        func = OnDelDockingTower
    },
    ls = {
        callable = true,
        params = {
            pos  ={
                length = 0,
                optional = true
            },
            height  ={
                length = 0,
                optional = true
            },
            free  ={
                length = 0,
                optional = true
            },
            slots = {
                length = 0,
                optional = true
            }
        },
        func = OnListDockingTowers
    },
    edit = {
        callable = true,
        params = {
            id = {

            },
            name = {

            },
            height = {

            },
            pos = {
                length = 3
            },
        },
        func = OnEditDockingTower
    },

    AllocateDocking = {
        callable = false,
        params = {
            id = {
            },
            Tower = {
            },
            -- DECLARED, OR IT NEVER ARRIVES. PowNet filters the payload to the fields named
            -- here the moment a params block exists, silently, and the call still returns
            -- success -- which is how order.build's dependsOn was dropped for months while
            -- every call reported fine. See hq/test/wiring.test.ts.
            pos = { optional = true },
        },
        func = OnAllocateDocking
    },
    -- The other half of AllocateDocking, which never existed. A drone leaving its dock had no way to
    -- say so, so the slot stayed occupied forever and the tower filled up with drones that were not
    -- there.
    FreeDocking = {
        callable = true,
        params = {
            id = {
            },
        },
        func = OnFreeDocking
    },
    GetDroneInfo = {
        callable = false,
        params = {
            id = {
            },
        },
        func = OnGetDroneInfo
    }
}

function Render()
    local m_Monitor = monitor()
    if not m_Monitor then return end
    print("Render!")
    m_Monitor.clear()
    m_Monitor.setCursorPos(1,1)
    m_Monitor.setTextScale(0.5)
    -- Header
    m_Monitor.write("DockingMan!")
    local i = 1
    for k,v in pairs(DATA["towers"]) do
        i = i + 1
        m_Monitor.setCursorPos(1,i)
        -- A MALFORMED TOWER MUST NOT KILL THE MODULE THAT OWNS TOWERS.
        --
        -- This indexed v.pos.x/.y/.z blind, so one tower registered with a position in the wrong
        -- shape crashed DockingMan on its next render -- and it crashes on every boot afterwards,
        -- because the bad record is persisted. The module cannot be repaired through its own rm
        -- endpoint, because it is never up long enough to answer one. A single bad write bricks it.
        --
        -- It happened immediately: an HQ tool sent pos as an ARRAY, [x, y, z], where DockingMan
        -- reads pos.x -- so every field was nil and the display was the first thing to touch them.
        local p = v.pos or {}
        local s_Where = (p.x ~= nil) and ("(" .. tostring(p.x) .. ", " .. tostring(p.y) .. ", " .. tostring(p.z) .. ")")
                        or "(bad pos)"
        m_Monitor.write("[" .. tostring(v.id) .. "] " .. tostring(v.name) .. " - ["
                        .. tostring(v.freeSlot) .. "/" .. tostring(v.slots) .. "] -  " .. s_Where)
    end
end


Init()
PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents, Render)

SetStatus("Connected!", colors.green)

Render()
parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control)

print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
