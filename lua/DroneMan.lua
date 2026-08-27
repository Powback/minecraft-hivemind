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
        s_Drone.lastSeen = os.epoch("utc")   -- seen right now, by definition
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

    -- Send the position. DockingMan now hands out the NEAREST free slot rather than the next one in
    -- sequence, and it cannot do that without knowing where the asker is.
    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "AllocateDocking",
                                        {id = s_DroneID, pos = p_Pos})
    local s_Response = PowNet.sendAndWaitForResponse("DockingMan", s_Message)
    -- A DRONE WITHOUT A BERTH IS STILL A DRONE.
    --
    -- This refused the whole registration when docking could not be allocated, and the drone reads
    -- that as "failed to call home" and returns -- so it never enters its loops, never sends a
    -- heartbeat, and never appears in the fleet. A running turtle that nothing knows exists, whose
    -- only symptom is a drone count that stays at zero.
    --
    -- In a fresh world that is guaranteed. No docking tower has been built yet, so the FIRST drone
    -- can never register, so nothing can ever build the tower that would have let it register. The
    -- fleet could not be started at all, and it failed silently.
    --
    -- Registration and berthing are separate concerns: somewhere to park is a convenience, being
    -- known is what makes a drone dispatchable, rescuable and visible. DroneLogic already takes this
    -- view about GPS -- it registers without a position rather than vanishing -- and this is the same
    -- judgement about docks.
    if (not s_Response) or (type(s_Response) ~= "table") then
        print("registered " .. s_DroneName .. " with no dock")
        PowNet.MarkDirty()
        return true, {name = s_DroneName}
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
        -- NOT detail. Two meanings collided on one field: it began life as the distress DETAIL
        -- ("walled in at -70,88,12") and is now also the job description ("craft oak_planks x8"),
        -- so clearing the distress wiped the description of a perfectly healthy drone on its very
        -- next heartbeat -- which is why the panel showed "-" for a drone that was plainly busy.
        DATA["drones"][s_ID].stuckDetail = nil
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
            -- TWO ids exist for every drone and they are not interchangeable:
            --
            --   droneID  the registry key -- a sequence, "1", "2", "3" -- and what "D3" is named after
            --   id       the COMPUTER id, e.g. 123, which is what rednet actually addresses
            --
            -- This looked up the registry key only. Every caller that sensibly passed the computer
            -- id (which is what GetDrones, fleet.status and `computercraft dump` all show) got
            -- "Could not find drone", and because that comes back as a plain string on the wire it
            -- read as a successful reply -- so orders were reported sent and silently went nowhere.
            --
            -- Accept either. The ambiguity is real and unavoidable in the data; making callers
            -- guess which one a given endpoint wants is not.
            local s_Rec = DATA["drones"][tostring(p_Message.data.id)]
            if(s_Rec == nil) then
                local s_Want = tonumber(p_Message.data.id)
                for _, v in pairs(DATA["drones"]) do
                    if v.id == s_Want then s_Rec = v break end
                end
            end
            if(s_Rec == nil) then
                return false, "Could not find drone with ID: " .. tostring(p_Message.data.id)
            end
            table.insert(s_Drones, s_Rec.id)
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
    s_Drone.stuck       = d.reason or "unknown"
    s_Drone.stuckDetail = d.detail
    -- What it is carrying. Stock the fleet cannot see is stock the fleet does not have: the crafter
    -- failed for want of logs that were sitting inside another drone the whole time.
    if type(d.inv) == "table" then s_Drone.inv = d.inv end
    -- A FAILED TASK IS NOT A STUCK DRONE.
    --
    -- This marked every distress as "stuck", and stuck is what the rescue pass hunts for. A craft
    -- that could not get its ingredients therefore reported the CRAFTER as stuck: TaskMan queued a
    -- rescue for a drone sitting on its dock with 19,000 fuel, and pulled the only miner off real
    -- work to go and dig out a drone that was not buried.
    --
    -- mobility=false means "the job failed, I am fine" -- record the reason, leave the status
    -- alone, and let the drone ask for its next task like anything else.
    if d.mobility ~= false then
        s_Drone.status = "stuck"
    end
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
            stuck = v.stuck, stuckDetail = v.stuckDetail, detail = v.detail, inv = v.inv,
            -- offline and lastSeen travel with the drone. Without them a caller can only infer
            -- liveness from `status`, and "offline" then reads as "busy doing something", which
            -- stalled the supply loop on a drone that no longer exists.
            offline = v.offline, lastSeen = v.lastSeen,
            -- WHAT CODE IT IS RUNNING. This reply is an explicit allowlist, so a field the drone
            -- reports but nobody copies here is dropped in silence -- the same failure shape as
            -- PowNet dropping undeclared params, one layer up. `build` arrived in the heartbeat,
            -- OnHeartbeat stored it, and it never reached HQ because of this list.
            --
            -- It exists because fourteen of twenty computers ran a stale pgps for hours with
            -- nothing reporting it: the drift bug the update had fixed came back on exactly the
            -- machines that had not received it, and it was only found by md5-ing files on the
            -- host by hand.
            build = v.build,
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

-- Forward a relay command to drones. Same shape as GoTo: the Bridge can only address MODULES, so
-- anything aimed at a drone has to be relayed by the module that owns the registry.
-- Tell a drone to STOP.
--
-- Cancelling a task in the queue does not reach the drone: it carries on executing whatever it was
-- given, never returns to idle, and therefore can never be assigned anything again. Two drones sat
-- "working" on cancelled orders while the supply loop correctly reported there was nobody free --
-- which from outside looks exactly like autonomy having died.
-- WRITE OFF A DRONE THAT CANNOT BE RECOVERED.
--
-- There was no way to do this, and the absence cost the fleet more than the drone did. A lost
-- drone keeps its registry entry, so TaskMan keeps seeing a casualty and keeps queuing rescues to
-- its LAST REPORTED position -- which for a drone that went quiet is exactly the position most
-- likely to be wrong. D1 drifted outside the operating region and stopped ticking while its record
-- still read -443,64,66, well inside it; every tick sent the one healthy miner to an empty patch
-- of ground, and D2 sat at zero fuel waiting for relief that never got a rescuer. One unrecoverable
-- drone was consuming the entire fleet, indefinitely, and nothing could say "it is gone".
--
-- Retiring is deliberately not deletion of the computer: the turtle still exists and may come back.
-- It is removal from the REGISTRY, so the fleet stops planning around it. If it ever heartbeats
-- again it registers from scratch, which is exactly the self-healing path Init already has.
function OnRetireDrone(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Id = d.id
    if s_Id == nil then return false, "Missing id" end

    -- Match on any of the three things a caller might reasonably have: the registry key, the
    -- COMPUTER id (which is what fleet.status shows and therefore what a human will type), or the
    -- name. The registry is keyed by an internal droneID, so id alone missed every time.
    local s_Key = nil
    for k, v in pairs(DATA["drones"] or {}) do
        if tostring(k) == tostring(s_Id)
                or tostring(v.id) == tostring(s_Id)
                or tostring(v.name) == tostring(s_Id) then
            s_Key = k break
        end
    end
    if s_Key == nil then return false, "no such drone: " .. tostring(s_Id) end

    local s_Rec  = DATA["drones"][s_Key]
    local s_Name = s_Rec.name
    DATA["drones"][s_Key] = nil
    -- The reverse index too, or a heartbeat from the retired drone resolves to a record that is no
    -- longer there and the fleet ends up with a half-forgotten drone.
    if DATA["ids"] and s_Rec.id ~= nil then DATA["ids"][s_Rec.id] = nil end
    PowNet.MarkDirty()
    print("retired " .. tostring(s_Name) .. " -- removed from the registry")
    return true, {retired = tostring(s_Name), id = tostring(s_Key)}
end

function OnStopDrone(p_ID, p_Message)
    if(p_Message.data.id == nil and p_Message.data.range == nil) then
        return false, "Missing id/range"
    end
    local s_Status, s_Parsed = ParseMessage(p_Message)
    if(s_Status == false) then return s_Status, s_Parsed end

    local s_Done = {}
    for _, v in pairs(s_Parsed.data.drones) do
        local s_Msg = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {})
        local s_Res = PowNet.sendAndWaitForResponse(v, s_Msg, PowNet.SERVER_PROTOCOL, 5)
        s_Done[#s_Done + 1] = {id = v, aborted = (s_Res ~= false and s_Res ~= nil)}
        -- Believe the drone's own next heartbeat rather than assuming: clearing the registry entry
        -- here would report idle for a drone that never got the message.
    end
    if #s_Done == 0 then return false, "no drone matched" end
    return true, {stopped = s_Done}
end

function OnRelayCmd(p_ID, p_Message)
    if(p_Message.data.id == nil and p_Message.data.range == nil) then
        return false, "Missing id/range"
    end
    local s_Status, s_Parsed = ParseMessage(p_Message)
    if(s_Status == false) then return s_Status, s_Parsed end

    local s_On = p_Message.data.on
    if s_On == nil then s_On = true end

    local s_Done = {}
    for _, v in pairs(s_Parsed.data.drones) do
        local s_Msg = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Relay", {on = s_On})
        -- THREE SECONDS, NOT EIGHT, AND THE REASON IS NOT IMPATIENCE.
        --
        -- This module is single-threaded: every second spent blocked in here is a second it is not
        -- answering heartbeats, GetDrones, or anything else. Eight seconds PER DRONE, sequentially,
        -- stalls the fleet's registry for up to a minute on a call that is only ever asking "will
        -- you please act as an anchor" -- and it overran HQ's own patience, so the caller reported
        -- "no response from DroneMan.Relay" while DroneMan was sitting right there, working.
        --
        -- A drone that cannot answer in three seconds is not going to be a useful GPS anchor
        -- anyway. Failing fast here is strictly better than blocking the registry to find out.
        local s_Res = PowNet.sendAndWaitForResponse(v, s_Msg, PowNet.DRONE_PROTOCOL, 3)
        s_Done[#s_Done + 1] = {id = v, ok = (s_Res ~= false and s_Res ~= nil), result = s_Res}
    end
    if #s_Done == 0 then return false, "no drone matched" end
    return true, {relays = s_Done}
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
    local s_Sent = {}
    for k,v in pairs(s_Mesage.data.drones) do

        -- Fire the abort, do not WAIT for it.
        --
        -- This blocked on an acknowledgement with a 1s budget and three retries, so a single GoTo
        -- could spend seconds here before the move was even sent -- and the caller, waiting on the
        -- whole exchange, timed out and reported "no response" for an order that was in fact being
        -- carried out. That misreport fooled me three separate times.
        --
        -- Waiting bought nothing anyway: OnAbort is idempotent and always clears, and the GoTo that
        -- follows is what the drone acts on.
        PowNet.Send(v, PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}), PowNet.SERVER_PROTOCOL)
        os.sleep(0.2)   -- let the abort land before the new order arrives

        -- The verb is a parameter now, not a constant.
        --
        -- Everything that needed to send a drone somewhere had to be a GoTo, so a job that means
        -- "go there AND do this on arrival" -- handing wood to a blocked crafter, for instance --
        -- had nowhere to live. The travel half is identical; only the verb and payload differ.
        local s_Verb = p_Message.data.verb or "GoTo"
        Log(("dispatch %s -> #%s"):format(s_Verb, tostring(v)))
        local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, s_Verb,
            {pos = p_Message.data.pos, heading = p_Message.data.heading,
             drone = p_Message.data.drone, match = p_Message.data.match,
             deposit = p_Message.data.deposit, code = p_Message.data.code})
        local s_GoToResponse = PowNet.SendToDrone(v, s_Message)
        print("Sent " .. s_Verb .. " to #" .. tostring(v) .. " -> " .. tostring(s_GoToResponse))
        if s_GoToResponse then s_Sent[#s_Sent + 1] = v end
    end

    -- Say WHICH computers were actually addressed, rather than a bare `true`.
    --
    -- A caller cannot otherwise tell "the order went to the drone" from "the order matched no
    -- drone and did nothing" -- and that is exactly how a broken GoTo went unnoticed: it reported
    -- success every time, including when it had resolved to an empty list.
    if #s_Sent == 0 then
        return false, "no drone matched -- nothing was sent"
    end
    return true, {sent = s_Sent, count = #s_Sent}
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
    Stop = {
        func = OnStopDrone,
    },
    RetireDrone = {
        func = OnRetireDrone,
        callable = true,
        params = { id = { optional = true } }
    },
    Relay = {
        func = OnRelayCmd,
        callable = true,
        params = { id = { optional = true }, on = { optional = true } }
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
            },
            -- DECLARED, OR SILENTLY DROPPED.
            --
            -- The validator only passes through what is described here, so an undeclared field
            -- simply never reaches the handler -- no error, no log line, the call returns fine and
            -- the drone is never told. That is what swallowed the MapServer bounds push earlier
            -- ("bounds=false" and nothing else), and it is what swallowed every Handover and Unload:
            -- the tool reported success, DroneMan reported success, and D5 sat on twenty-two logs.
            pos     = { optional = true },
            heading = { optional = true },
            verb    = { optional = true },
            drone   = { optional = true },
            match   = { optional = true },
            deposit = { optional = true },
            code    = { optional = true }
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
        -- A DRONE WITH NO POSITION MUST NOT KILL THE MODULE THAT TRACKS DRONES.
        --
        -- pos is nil for exactly the drones that most need tracking: one that registered before it
        -- had a GPS fix, one underground, one that has just been placed. This indexed it blind, so
        -- the first such drone crashed DroneMan on its next render -- and DroneMan crashing means
        -- every drone loses its registry, so they all re-register, so it crashes again. One
        -- positionless turtle took down the whole fleet's bookkeeping in a loop.
        --
        -- The status line is a convenience. Knowing where a drone ISN'T is still worth printing.
        local p = s_Turtle.pos
        local s_Where = p and ("(" .. tostring(p.x) .. ", " .. tostring(p.y) .. ", " .. tostring(p.z) .. ")")
                          or "(no fix)"
        m_Monitor.write("[" .. tostring(s_Turtle.name) .. "] | " .. tostring(s_Turtle.status)
                        .. " | " .. s_Fuel .. " - " .. s_Where)

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

-- LOADERS PLACE THEMSELVES OVER THE WORK.
--
-- A chunky turtle keeps the chunk it is standing in ticking. A drone whose chunk stops ticking does
-- not fail, it simply stops -- mid-job, reporting nothing, indistinguishable from destroyed. So the
-- fleet's working area has to stay loaded, and until now that was arranged by hand: loaders sat at
-- their spawn point until a rescue happened to send one somewhere.
--
-- The demand is already known. Every drone reports its position on every heartbeat, so DroneMan can
-- see where the fleet actually is and park the loaders on top of it. This runs IN-WORLD rather than
-- in HQ on purpose: losing coverage freezes drones, and it must not depend on the Bridge being up.
--
-- Chunk loading is column-wide, which makes this much safer than it first looks -- a loader covers
-- a miner at y=35 while itself sitting at y=87. It never has to descend into the workings, so it
-- cannot get walled in down there, and its own travel stays at open altitude.
local CHUNK = 16

local function chunkOf(p_Pos)
    return math.floor(p_Pos.x / CHUNK), math.floor(p_Pos.z / CHUNK)
end

local function Coverage()
    while true do
        os.sleep(30)

        local s_Ok, s_Err = pcall(function()
            -- Where is the work? Loaders are excluded -- covering each other is a feedback loop
            -- that parks the whole set on top of itself and leaves the miners dark.
            local s_Demand, s_Loaders = {}, {}
            for _, d in pairs(DATA["drones"] or {}) do
                if not d.offline and d.pos and d.pos.x then
                    if d.role == "loader" then
                        -- Only IDLE loaders are movable. One on a rescue is already somewhere it
                        -- was deliberately sent, and yanking it away mid-recovery would strand the
                        -- drone it was sent to save.
                        if d.status == "idle" then s_Loaders[#s_Loaders + 1] = d end
                    elseif d.status ~= "idle" and d.status ~= "offline" then
                        local cx, cz = chunkOf(d.pos)
                        local k = cx .. ":" .. cz
                        s_Demand[k] = s_Demand[k] or {cx = cx, cz = cz, n = 0}
                        s_Demand[k].n = s_Demand[k].n + 1
                    end
                end
            end

            if #s_Loaders == 0 then return end

            -- Busiest chunks first, so with fewer loaders than hotspots the ones that matter win.
            local s_Wanted = {}
            for _, v in pairs(s_Demand) do s_Wanted[#s_Wanted + 1] = v end
            table.sort(s_Wanted, function(a, b) return a.n > b.n end)
            if #s_Wanted == 0 then return end

            -- A loader ALREADY covering a wanted chunk stays put. Without this the assignment is
            -- recomputed from scratch every 30s and loaders trade places forever, spending their
            -- whole lives in transit and covering nothing while they fly.
            local s_Covered, s_Free = {}, {}
            for _, l in ipairs(s_Loaders) do
                local lx, lz = chunkOf(l.pos)
                local k = lx .. ":" .. lz
                if s_Demand[k] and not s_Covered[k] then
                    s_Covered[k] = true
                else
                    s_Free[#s_Free + 1] = l
                end
            end

            for _, want in ipairs(s_Wanted) do
                if #s_Free == 0 then break end
                local k = want.cx .. ":" .. want.cz
                if not s_Covered[k] then
                    -- Nearest free loader, so the fleet is covered as soon as possible rather than
                    -- optimally-eventually.
                    local s_Best, s_BestD, s_BestI = nil, nil, nil
                    local s_Tx = want.cx * CHUNK + CHUNK / 2
                    local s_Tz = want.cz * CHUNK + CHUNK / 2
                    for i, l in ipairs(s_Free) do
                        local d = math.abs(l.pos.x - s_Tx) + math.abs(l.pos.z - s_Tz)
                        if s_BestD == nil or d < s_BestD then s_Best, s_BestD, s_BestI = l, d, i end
                    end

                    -- Keep the loader's own altitude. The chunk is loaded as a column, so there is
                    -- nothing to gain by descending and a great deal to lose.
                    -- FIRE AND FORGET. SendToDrone waits for a reply, and a drone answers GoTo
                    -- only once the whole move is finished -- which can be minutes. DroneMan is
                    -- single-threaded and already serving thirteen heartbeats, TaskMan's fleet
                    -- polls and HQ's status polls from one receive loop; parking a coroutine on a
                    -- multi-minute round trip is how it stopped answering Status at all and every
                    -- drone was marked offline while running perfectly well.
                    --
                    -- Nothing here needs the answer: if the loader does not go, the next sweep in
                    -- thirty seconds notices it is still in the wrong chunk and asks again.
                    PowNet.Send(s_Best.id,
                        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}),
                        PowNet.SERVER_PROTOCOL)
                    os.sleep(0.2)
                    PowNet.Send(s_Best.id, PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GoTo",
                        {pos = {x = s_Tx, y = s_Best.pos.y, z = s_Tz}}), PowNet.DRONE_PROTOCOL)
                    print(("coverage: %s -> chunk %d,%d (%d drone(s) working there)")
                        :format(tostring(s_Best.name), want.cx, want.cz, want.n))

                    s_Covered[k] = true
                    table.remove(s_Free, s_BestI)
                end
            end
        end)

        if not s_Ok then print("coverage failed: " .. tostring(s_Err)) end
    end
end

local function Tick()
    while true do
        os.sleep(20)
        local s_Now = os.epoch("utc")
        local s_Changed = false
        for _, d in pairs(DATA["drones"] or {}) do
            -- A MISSING lastSeen means offline too. Guarding on `d.lastSeen and ...` skipped
            -- exactly the drones most likely to be dead: anything that stopped answering before
            -- this sweep existed has no timestamp at all, so D2 -- mined out of the world by D1 --
            -- stayed "idle" forever precisely because it had never checked in.
            -- Registration stamps lastSeen, so nil now means "has not been heard from since".
            local s_Silent = (d.lastSeen == nil) or ((s_Now - d.lastSeen) > OFFLINE_AFTER_MS)
            if s_Silent and not d.offline then
                d.offline = true
                d.status  = "offline"
                s_Changed = true
                print(tostring(d.name) .. " went silent -- marked offline")
            end
        end
        if s_Changed then PowNet.MarkDirty() end
    end
end

parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, Tick, Coverage)

print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
