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
    if DATA["lastDrone"] == nil then
        DATA["lastDrone"] = 1
    end
    if DATA["drones"] == nil then
        DATA["drones"] = {}
    end
    if DATA["ids"] == nil then
        DATA["ids"] = {}
    end
end

function GetDroneIDByCCID(p_ID)
    return DATA["ids"][p_ID]
end

function RegisterDrone(p_ID, p_Pos, p_Heading, p_Role)
    -- A RETRY IS NOT A NEW DRONE.
    --
    -- sendAndWaitForResponse re-sends after a 1s silence, three times over, and this call chain
    -- -- DroneMan -> DockingMan -> MapServer, each with its own 1s budget -- routinely takes
    -- longer than the drone is willing to wait. So a single drone booting a single time arrived
    -- here four times and walked away with four names and four docking slots, while the drone
    -- itself saw only timeouts. lastDrone hit 5 for one turtle.
    --
    -- Replaying the original answer makes the retry harmless: the drone gets the same name and
    -- the same slot however many times it asks, and only a genuinely new computer id allocates.
    local s_Existing = GetDroneIDByCCID(p_ID)
    if(s_Existing ~= nil and DATA["drones"][s_Existing] ~= nil) then
        local s_Drone = DATA["drones"][s_Existing]
        print("Drone " .. tostring(p_ID) .. " is already " .. tostring(s_Drone.name) .. ", replaying")
        local s_Dock = s_Drone.dock or {}
        return true, {name = s_Drone.name, go = s_Dock.pos, heading = s_Dock.heading}
    end

    local s_DroneName = "D" .. DATA["lastDrone"]
    local s_DroneID = tostring(DATA["lastDrone"])

    DATA["lastDrone"] = DATA["lastDrone"] + 1
    DATA["drones"][s_DroneID] = {
        droneID = s_DroneID,
        id = p_ID,
        pos = p_Pos,
        status = "idle",
        name = s_DroneName,
        -- Was hardcoded "peasant" for every drone, which made the field useless for dispatch.
        -- The drone reports what its upgrades actually make it; heartbeats keep it current.
        role = p_Role or "miner"
    }
    DATA["ids"][p_ID] = s_DroneID

    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "AllocateDocking", {id = s_DroneID})
    local s_Response = PowNet.sendAndWaitForResponse("DockingMan", s_Message)
    if(not s_Response) then
        print("Failed to get docking")
        return false, "Failed to get docking"
    end
    if(type(s_Response) ~= "table") then
        print("wtf")
        return false, s_Response
    end
    -- Kept so a retry can be answered identically without asking DockingMan for a second slot.
    DATA["drones"][s_DroneID].dock = {pos = s_Response.pos, heading = s_Response.heading}
    -- The drone is about to write this name into its own label, which survives a restart even
    -- though our registry does not. Persist so the two cannot disagree.
    PowNet.MarkDirty()
    return true, {name = s_DroneName, go = s_Response.pos, heading = s_Response.heading}
end

function OnHeartbeat(p_ID, p_Message)
    local s_ID = GetDroneIDByCCID(p_ID)
    -- A heartbeat from a drone we do not know about used to kill this server outright:
    -- GetDroneIDByCCID returns nil, and DATA["drones"][nil][k] = v is an index-nil error.
    -- It is not a rare case -- any drone that already has a label skips registration in
    -- DroneLogic.Init() but still calls SendHeartBeat(), so one pre-labelled turtle in the
    -- world was enough to crash-loop DroneMan forever and keep drones = {} empty.
    -- Answering "you are not registered" instead lets the drone recover on its own.
    if(s_ID == nil or DATA["drones"][s_ID] == nil) then
        print("Heartbeat from unregistered drone " .. tostring(p_ID))
        return false, "unregistered"
    end
    for k,v in pairs(p_Message.data) do
        DATA["drones"][s_ID][k] = v
    end
    -- WHEN we last heard from it, which is the only way to tell a docked drone from one that no
    -- longer exists. Drones heartbeat every 30s; nothing was recording the arrival, so a drone
    -- that stopped answering stayed "idle" forever. D1 mined D2 out of the world and the registry
    -- kept offering D2 work afterwards.
    DATA["drones"][s_ID].lastSeen = os.epoch("utc")
    if DATA["drones"][s_ID].offline then
        DATA["drones"][s_ID].offline = nil
        print(tostring(DATA["drones"][s_ID].name) .. " is back")
    end
    -- A heartbeat reporting no stuck reason means it recovered; drop the stale flag rather than
    -- leaving a drone marked in trouble forever because it once was.
    if p_Message.data.stuck == nil then
        DATA["drones"][s_ID].stuck = nil
        DATA["drones"][s_ID].detail = nil
    end

    return true
end

function GetDroneByID(p_Id)
    return DATA["drones"][(tostring(p_Id))]
end

function GetDronesByRange(p_Min, p_Max)
    local s_Drones = {}
    for i = tonumber(p_Min), tonumber(p_Max), 1 do
        if(DATA["drones"][tostring(i)] ~= nil) then
            table.insert(s_Drones, DATA["drones"][tostring(i)].id)
        end
    end
end

function ParseMessage(p_Message)
    if(p_Message.data.pos == nil and p_Message.data.gps ~= nil) then
        p_Message.data.pos = p_Message.data.gps
    end

    local s_Drones = {}
    if(p_Message.data.id) then
        if(tostring(p_Message.data.id) == "-1") then
            for k,v in pairs (DATA["drones"]) do
                table.insert(s_Drones, v.id)
            end
        else
            if(DATA["drones"][tostring(p_Message.data.id)] == nil) then
                return false, "Could not find drone with ID: " .. tostring(p_Message.data.id)
            end
            table.insert(s_Drones, DATA["drones"][tostring(p_Message.data.id)].id)
        end
    end

    if(p_Message.data.range) then
        for i = tonumber(p_Message.data.range[1]), tonumber(p_Message.data.range[2]), 1 do
            if(DATA["drones"][tostring(i)] ~= nil) then
                table.insert(s_Drones, DATA["drones"][tostring(i)].id)
            end
        end
    end
    p_Message.data.drones = s_Drones
    return true, p_Message
end



function OnRegisterDrone(p_ID, p_Message)
    print("New Drone")
    local s_Result, s_Data = RegisterDrone(p_ID, p_Message.data.pos, p_Message, p_Message.data.role)
    return s_Result, s_Data
end

function OnRestartDrones(p_ID, p_Message)
    print("Restarting drones")
    if(p_Message.range ~= nil) then

    else

    end

    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Reboot", {})
    local s_Response = PowNet.SendToAllDrones(s_Message)
    return true, "Dispatched restart"
end

function OnDockDrones(p_ID, p_Message)
    print("Docking drones")
    if(p_Message.data.id == nil and p_Message.data.range == nil) then
        return false, "Missing id/range"
    end

    local p_Message = ParseMessage(p_Message)

    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetDroneInfo", {})
    local s_Response = PowNet.sendAndWaitForResponse("DockingMan", s_Message)
    if(type(s_Response) == "table") then
        local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GoTo", {pos = v.pos, heading = v.heading})
        local s_Response = PowNet.SendToDrone(k, s_Message)
    end

    return true
end

-- Report the fleet, for anything that needs to draw or reason about it.
--
-- There was no way to ask DroneMan what it knew: every event either mutated state or dispatched
-- an order, so the registry was write-only from outside. MapServer needs positions to put drone
-- markers on the map, and heartbeats already keep these current.
-- A drone in trouble reports here. Recorded rather than just printed, because the terminal of a
-- server nobody is looking at is the same as no report at all.
function OnDistress(p_ID, p_Message)
    local s_ID = GetDroneIDByCCID(p_ID)
    if(s_ID == nil or DATA["drones"][s_ID] == nil) then
        print("Distress from unregistered drone " .. tostring(p_ID))
        return false, "unregistered"
    end
    local d = p_Message.data or {}
    local s_Drone = DATA["drones"][s_ID]
    s_Drone.stuck  = d.reason or "unknown"
    s_Drone.detail = d.detail
    s_Drone.status = "stuck"
    if d.pos then s_Drone.pos = d.pos end
    if d.fuel then s_Drone.fuel = d.fuel end
    print("DISTRESS " .. tostring(s_Drone.name) .. ": " .. tostring(s_Drone.stuck))
    -- Worth persisting: this is exactly the state you want to survive the server restart that
    -- someone does while trying to work out what went wrong.
    PowNet.MarkDirty()
    return true
end

-- Everything currently in trouble, in one answer.
function OnListStuck(p_ID, p_Message)
    local s_Msg, s_N = "", 0
    for k,v in pairs(DATA["drones"]) do
        if v.stuck or v.status == "stuck" then
            s_N = s_N + 1
            local p = v.pos or {}
            s_Msg = s_Msg .. string.format("%s(%s) at %s,%s,%s fuel %s; ",
                tostring(v.name), tostring(v.stuck),
                tostring(p.x), tostring(p.y), tostring(p.z), tostring(v.fuel))
        end
    end
    if s_N == 0 then s_Msg = "nothing stuck" end
    return true, {message = s_Msg, count = s_N}
end

-- Tell a stuck drone to climb out. Straight up is almost always free.
function OnRescueDrones(p_ID, p_Message)
    if(p_Message.data.id == nil and p_Message.data.range == nil) then
        return false, "Missing id/range"
    end
    local s_Status, s_Parsed = ParseMessage(p_Message)
    if(s_Status == false) then return s_Status, s_Parsed end
    local s_N = 0
    for k,v in pairs(s_Parsed.data.drones) do
        PowNet.SendToDrone(v, PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Rescue",
            {up = p_Message.data.up}))
        s_N = s_N + 1
    end
    return true, {message = "rescue sent to " .. s_N .. " drone(s)"}
end

-- Send a loader somewhere so workers may follow.
--
-- The orchestration the fleet was missing: a worker refused out-of-bounds work and there was no
-- way to say "then make it in bounds". Now a loader is dispatched, parks, and its chunk becomes
-- safe ground that MapServer folds into coverage.
function OnEscort(p_ID, p_Message)
    local d = p_Message.data or {}
    local p = d.pos or d.gps
    if p == nil then return false, "Missing pos" end
    local s_Pos = {x = tonumber(p[1] or p.x), y = tonumber(p[2] or p.y), z = tonumber(p[3] or p.z)}

    local s_Loader
    for k, v in pairs(DATA["drones"]) do
        if v.role == "loader" and (v.status == "idle" or s_Loader == nil) then
            s_Loader = v
            if v.status == "idle" then break end
        end
    end
    if s_Loader == nil then
        return false, "no loader in the fleet -- one drone needs a chunky turtle upgrade"
    end
    PowNet.SendToDrone(s_Loader.id,
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GoTo", {pos = s_Pos}))
    return true, {message = "sent " .. tostring(s_Loader.name) .. " to hold " ..
                  s_Pos.x .. "," .. s_Pos.y .. "," .. s_Pos.z, loader = s_Loader.name}
end

function OnGetDrones(p_ID, p_Message)
    local s_List = {}
    for k,v in pairs(DATA["drones"]) do
        s_List[#s_List + 1] = {
            droneID = v.droneID, name = v.name, id = v.id,
            pos = v.pos, status = v.status, fuel = v.fuel, role = v.role,
            stuck = v.stuck, detail = v.detail,
        }
    end
    return true, {drones = s_List, count = #s_List}
end

function OnSurveyDrones(p_ID, p_Message)
    if(p_Message.data.id == nil and p_Message.data.range == nil) then
        return false, "Missing id/range"
    end
    local s_Status, s_Parsed = ParseMessage(p_Message)
    if(s_Status == false) then
        return s_Status, s_Parsed
    end
    local s_Sent = 0
    for k,v in pairs(s_Parsed.data.drones) do
        local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Survey", {
            w = p_Message.data.w, h = p_Message.data.h,
            drop = p_Message.data.drop, climb = p_Message.data.climb})
        PowNet.SendToDrone(v, s_Message)
        s_Sent = s_Sent + 1
    end
    return true, {message = "survey dispatched to " .. s_Sent .. " drone(s)"}
end

function OnGoTo(p_ID, p_Message)
    if(p_Message.data.pos == nil and p_Message.data.gps == nil) then
        return false, "Missing pos"
    end
    if(p_Message.data.id == nil and p_Message.data.range == nil) then
        return false, "Missing id/range"
    end

    local s_Status, s_Mesage = ParseMessage(p_Message)
    if(s_Status == false) then
        return s_Status, s_Mesage
    end
    for k,v in pairs(s_Mesage.data.drones) do

        local s_AbortMessage = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {})
        local s_AbortResponse = PowNet.sendAndWaitForResponse(v, s_AbortMessage, PowNet.SERVER_PROTOCOL) -- Override the current drone action
        if(s_AbortResponse) then
           os.sleep(1) -- Wait for abortion to complete. Takes 1 tick.
        end

        local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GoTo", {pos = p_Message.data.pos})
        local s_GoToResponse = PowNet.SendToDrone(v, s_Message)
        print(s_GoToResponse)
        print("Sent to: " .. v)
    end

    return true
end

local m_DroneEvents = {
    Heartbeat = OnHeartbeat,
}

local m_ServerEvents = {
    RegisterDrone = OnRegisterDrone,
    Heartbeat = OnHeartbeat,

    RestartDrone = {
        func = OnRestartDrones,
        callable = true,
        params = {
            id = {
                optional = true,
                type = "number"
            },
            range = {
                optional = true,
                type = "vec2"
            }
        }
    },
    DockDrones = {
        func = OnDockDrones,
        callable = true,
        params = {
            range = {
                optional = true,
                type = "vec2"
            }
        }
    },
    GetDrones = {
        func = OnGetDrones
    },
    Distress = {
        func = OnDistress
    },
    escort = {
        func = OnEscort, callable = true,
        params = { pos = { length = 3 } }
    },
    stuck = {
        func = OnListStuck,
        callable = true,
        params = {}
    },
    rescue = {
        func = OnRescueDrones,
        callable = true,
        params = {
            id    = { optional = true, length = 1, type = "number" },
            range = { optional = true, length = 2, type = "vec2" },
            up    = { optional = true },
        }
    },
    drones = {
        func = OnGetDrones,
        callable = true,
        params = {}
    },
    survey = {
        func = OnSurveyDrones,
        callable = true,
        params = {
            id    = { optional = true, length = 1, type = "number" },
            range = { optional = true, length = 2, type = "vec2" },
            w     = { optional = true },
            h     = { optional = true },
            drop  = { optional = true },
            climb = { optional = true },
        }
    },
    GoTo = {
        func = OnGoTo,
        callable = true,
        params = {
            id = {
                optional = true,
                length = 1,
                type = "number"
            },
            range = {
                optional = true,
                length = 2,
                type = "vec2"
            }
        }
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
    m_Monitor.write("DroneMan!")
    local i = 1
    local left = true
    for k,v in pairs(DATA["drones"]) do
        local s_Turtle = DATA["drones"][k]
        if(left) then
            m_Monitor.setCursorPos(1,i)
            left = false
        else
            m_Monitor.setCursorPos(45,i)
            left = true
            i = i + 1
        end
        local s_Fuel = s_Turtle.fuel
        if s_Fuel == nil then
            s_Fuel = "?"
        end
        m_Monitor.write("[" .. s_Turtle.name .. "] | " .. s_Turtle.status .." | " .. s_Fuel .. " - (" .. s_Turtle.pos.x .. ", " .. s_Turtle.pos.y .. ", " .. s_Turtle.pos.z ..")")

    end
end


Init()
PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents, Render)

SetStatus("Connected!", colors.green)

Render()
-- Mark drones offline when they go quiet.
--
-- Three missed heartbeats, not one: a drone mid-job can be slow, and flapping a drone in and out
-- of the fleet is worse than noticing a little late. Offline drones keep their last known
-- position and fuel so a rescue has somewhere to start looking -- the record is stale, not wrong.
local OFFLINE_AFTER_MS = 3 * 30 * 1000

local function Tick()
    while true do
        os.sleep(20)
        local s_Now = os.epoch("utc")
        local s_Changed = false
        for _, d in pairs(DATA["drones"] or {}) do
            if d.lastSeen and not d.offline and (s_Now - d.lastSeen) > OFFLINE_AFTER_MS then
                d.offline = true
                d.status  = "offline"
                s_Changed = true
                print(tostring(d.name) .. " went silent -- marked offline")
            end
        end
        if s_Changed then PowNet.MarkDirty() end
    end
end

parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, Tick)

print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
