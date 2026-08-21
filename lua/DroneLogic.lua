-- TankStation
os.loadAPI("pgps")
local x,y,z
local m_Status = "idle"
local executing = false

print("I AM ALIVE!")

function TaskStart()
    executing = true
end
function TaskEnd()
    executing = false
    pgps.StartExec() -- Task has ended, allow force allow execution agian.
end

function Init()
    pgps.startGPS()

    -- Bounds BEFORE the first move. setLocationFromGPS steps the turtle to find its heading, so
    -- fetching these afterwards would leave the very first movement of a drone's life unchecked.
    if PowNet.WaitForService("MapServer", 30) then
        local s_B = PowNet.sendAndWaitForResponse("MapServer",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetBounds", {}), PowNet.SERVER_PROTOCOL)
        if type(s_B) == "table" and s_B.bounds then pgps.setBounds(s_B.bounds) end
    end

    x,y,z = pgps.setLocationFromGPS()

    -- SELF-HEALING REGISTRATION
    --
    -- Having a label used to mean "registered", full stop. But a registry reset, a rebuilt
    -- DroneMan, or a restored backup leaves drones holding names nobody recognises: they skip
    -- registration forever because they have a label, and DroneMan rejects their heartbeats
    -- because it has no record of them. Both sides look healthy and the fleet is entirely
    -- disconnected -- and the only fix was editing turtle NBT by hand, which races the shutdown
    -- that has to happen first.
    --
    -- So ask instead of assume: a heartbeat that comes back "unregistered" means our name is
    -- meaningless, and we drop it and register again.
    if(os.getComputerLabel() ~= nil) then
        -- Wait for DroneMan to exist before asking it anything. Without this the probe fires into
        -- a fleet that is still booting, times out, and the drone keeps a name nobody issued.
        if PowNet.WaitForService("DroneMan", 90) then
            local s_Probe = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Heartbeat",
                {pos = (x and {x = x, y = y, z = z}) or nil, status = "idle",
                 fuel = turtle.getFuelLevel(), role = Role()})
            local s_Res, s_Answered = PowNet.AskInsisting("DroneMan", s_Probe, 3)
            if(not s_Answered) then
                -- Never heard back. Say so rather than guessing: guessing "registered" is what
                -- produced a fleet that looked healthy and was not.
                Distress("DroneMan unreachable at boot", "kept label " .. tostring(os.getComputerLabel()))
            elseif(s_Res == "unregistered") then
                print("DroneMan does not know me -- re-registering")
                os.setComputerLabel(nil)
            end
        else
            Distress("DroneMan never appeared", "cannot verify registration")
        end
    end

    if(os.getComputerLabel() == nil) then
        print("Who am i...?")
        if(x == nil or y == nil or z == nil) then
            print("I have no GPS, my battery is low and it’s getting dark...")
            return
        end
        local s_Fuel = turtle.getFuelLevel()
        local s_Data = {id = os.getComputerID(), pos = {x = x, y = y, z = z}, fuel = s_Fuel,
                        role = Role()}
        PowNet.WaitForService("DroneMan", 90)
        local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "RegisterDrone", s_Data)
        local s_Response = PowNet.AskInsisting("DroneMan", s_Message, 3)
        if(not s_Response) then
            print("Failed to call home.")
            return false
        end
        if(type(s_Response) ~= "table") then
            -- tostring, because the common case here is s_Response == false (DroneMan did not
            -- answer within the timeout) and concatenating a boolean is an error. That error
            -- crashed DroneLogic, DroneBoot rebooted the turtle, and it registered all over
            -- again -- turning one slow reply into a registration loop.
            print("response: " .. tostring(s_Response))
            return false
        end
        print(s_Response)
        os.setComputerLabel(s_Response.name)
        print("I am " .. s_Response.name .. ", and I am here to serve.")

        if(s_Response.go) then
            print("Docking!")
            print(s_Response.go.x)
            print(s_Response.go.y)
            print(s_Response.go.z)
            print(s_Response.heading)
            print(pgps.moveTo(s_Response.go.x, s_Response.go.y, s_Response.go.z))
            print(pgps.turnTo(s_Response.heading))
        end
    end

    SendHeartBeat()
end

function SendHeartBeat()
    -- Read the position, do not re-derive it. This used to call setLocationFromGPS, which steps
    -- the turtle forward and back to work out its heading -- acceptable once during Init, and the
    -- reason a "heartbeat" could never actually beat: on a timer it would shuffle every docked
    -- drone out of its slot and back for ever.
    local hx, hy, hz = pgps.getCachedPosition()

    local s_Pos = nil
    if(hx == nil or hy == nil or hz == nil) then
        print("No cached position yet.")
    else
        s_Pos = {x = hx, y = hy, z = hz}
        x, y, z = hx, hy, hz
    end
    local s_Fuel = turtle.getFuelLevel()

    local s_Data = {pos = s_Pos, status = m_Status, fuel = s_Fuel, role = Role(), stuck = m_Stuck, hosting = m_Hosting}
    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Heartbeat", s_Data)
    PowNet.SendToServer("DroneMan", s_Message)
    print("Sent heartbeat")
end

function OnReboot(p_ID, p_Message)
    os.reboot()
end

function OnGoTo(p_ID, p_Message)
    print(os.time())
    x,y,z = pgps.setLocationFromGPS()
    if(p_Message.data.pos == nil) then
        print("No pos specified")
        return
    end
    m_Status = "moving"

    TaskStart()
    local s_Status, s_message = pgps.moveTo(p_Message.data.pos.x, p_Message.data.pos.y, p_Message.data.pos.z)
    TaskEnd()
    m_Status = "idle"
    if(s_Status == false) then
        print("Failed to move to position")
        return false, "Failed to move to position"
    end
    if(p_Message.data.heading == nil) then
        print("No heading specified")
    else
        m_Status = "rotation"
        print(pgps.turnTo(p_Message.data.heading))
        m_Status = "idle"
    end
end


-- Survey: fly a lawnmower pattern, hugging the ground, and let detectAll do the mapping.
--
-- Every pgps move already calls detectAll(), so surveying is not a separate act of measurement --
-- it is just going somewhere and having gone there recorded. What matters is the flight profile.
--
-- Flying at a fixed altitude would be useless: detectDown only reports the single block beneath
-- the turtle, so a high pass records one flat plane and no heights at all. Probing the full column
-- at every cell is the other extreme -- a 32x32 area with 20-block probes is ~40,000 moves, twice
-- the drone's entire fuel tank.
--
-- So it follows the terrain: step forward, climb if something blocks the way, sink if the ground
-- falls away. One or two moves per cell, and the block below is the surface at every step, which
-- is exactly the height field the map wants.
local function settle(p_MaxDrop)
    local s_Drops = 0
    while s_Drops < p_MaxDrop and not turtle.detectDown() do
        if not pgps.down() then break end
        s_Drops = s_Drops + 1
    end
    return s_Drops
end

local function stepForward(p_MaxClimb)
    local s_Climbs = 0
    while not pgps.forward() do
        if s_Climbs >= p_MaxClimb then return false end
        if not pgps.up() then return false end
        s_Climbs = s_Climbs + 1
    end
    return true
end

-- A scout carries a geo scanner instead of a pickaxe -- a turtle has only two upgrade slots and
-- the wireless modem is not negotiable, so seeing further costs the ability to dig.
--
-- It is worth it by a wide margin. scan(r) returns every non-air block within radius r in ONE
-- call: radius 8 is free (AdvancedPeripherals scanBlocksMaxFreeRadius), covers a 17x17x17 cube,
-- and is limited only by a 2s cooldown. detectAll manages three blocks per move. Verified in
-- world: scan(4) returned 62 blocks, relative coordinates, air already filtered out.
function Scanner()
    return peripheral.find("geo_scanner") or peripheral.find("geoScanner")
end

local SCAN_COOLDOWN = 2.2   -- config says 2000ms; a little margin beats a failed call

-- Record one scan into the pending delta. Coordinates come back relative, so they are offset by
-- wherever pgps thinks we are -- which is why this needs a GPS fix to be worth anything.
local function absorbScan(p_Scanner, p_Radius)
    local s_Blocks, s_Err = p_Scanner.scan(p_Radius)
    if not s_Blocks then
        return 0, tostring(s_Err)
    end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then
        return 0, "no position fix"
    end
    for _, b in ipairs(s_Blocks) do
        -- Detail shaped like {turtle.inspect()} so it matches what detectAll writes and what the
        -- renderer reads: entry [2] is the block table with .name.
        pgps.noteObservation((cx + b.x) .. ":" .. (cy + b.y) .. ":" .. (cz + b.z),
                             1, {true, {name = b.name}})
    end
    return #s_Blocks
end

-- What this drone is equipped to do. A turtle has two upgrade slots and the wireless modem takes
-- one, so the other slot decides its trade: a geo scanner makes it a scout, anything else (in
-- practice a pickaxe) makes it a miner. Reported rather than assumed, because DroneMan cannot see
-- a drone's upgrades -- it previously hardcoded every drone as "peasant".
function Role()
    if Scanner() then return "scout" end
    -- A chunky turtle keeps its own chunk ticking. Verified in world: it exposes peripheral type
    -- "chunky". That makes it the fleet's freedom of movement -- drones outside a forceloaded
    -- chunk simply stop, silently, wherever they happened to be.
    if peripheral.find("chunky") then return "loader" end
    return "miner"
end

-- SAVE / UPDATE / RESUME
--
-- An update is a reboot, and a reboot used to mean a drone forgot what it was doing. A survey
-- halfway through simply stopped, its unsent observations went with it, and nothing anywhere
-- recorded that the work had been abandoned -- the task still looked assigned.
--
-- So before standing down: flush observations to MapServer, write down the job, tell DroneMan.
-- After booting: pick the job back up. The file lives in the computer's own directory, which
-- survives reboots, so it does not depend on any server being reachable at the wrong moment.
local RESUME_FILE = "/resume.txt"
m_Job = nil          -- {verb, data} for whatever is currently running

local function saveResume()
    if m_Job == nil then
        if fs.exists(RESUME_FILE) then fs.delete(RESUME_FILE) end
        return
    end
    local h = fs.open(RESUME_FILE, "w")
    if h then h.write(textutils.serialize(m_Job)) h.close() end
end

local function loadResume()
    if not fs.exists(RESUME_FILE) then return nil end
    local h = fs.open(RESUME_FILE, "r")
    if not h then return nil end
    local s = h.readAll()
    h.close()
    fs.delete(RESUME_FILE)
    return textutils.unserialize(s)
end

function OnShutdown(p_Reason)
    -- Observations first: they are the expensive thing to re-gather, and a scout can have
    -- thousands of blocks pending between 30s upload cycles.
    pcall(UploadWorld)
    saveResume()
    m_Status = "updating"
    pcall(SendHeartBeat)
    print("standing down for " .. tostring(p_Reason) .. (m_Job and (", will resume " .. tostring(m_Job.verb)) or ""))
end

-- Re-run whatever we were doing before the update, once the fleet is back up.
local function resumeJob()
    local s_Job = loadResume()
    if s_Job == nil then return end
    print("resuming " .. tostring(s_Job.verb))
    os.sleep(5)                 -- let the servers finish coming up before talking to them
    if s_Job.verb == "Survey" then
        pcall(OnSurvey, 0, {data = s_Job.data})
    elseif s_Job.verb == "Scan" then
        pcall(OnScan, 0, {data = s_Job.data})
    elseif s_Job.verb == "Dig" then
        pcall(OnDig, 0, {data = s_Job.data})
    end
end

-- waitForAny ends the moment ANY branch returns, so this branch must never return -- otherwise a
-- drone with nothing to resume would shut its own module down the instant it booted.
local function resumeBranch()
    pcall(resumeJob)
    while true do os.sleep(3600) end
end

-- DISTRESS
--
-- A wedged drone is the normal failure of this whole system: a miner walls itself in, a hauler
-- meets another in a one-wide shaft, a builder runs out of the block it was placing. Silence is
-- the worst possible response -- the fleet looks busy while nothing moves, and finding the one
-- that stopped means checking each in turn.
--
-- So a drone that gives up says where it is, what it was doing, and why. m_Stuck also rides on
-- every heartbeat, so the fleet view shows it even if this message is lost.
m_Stuck = nil

function Distress(p_Reason, p_Detail)
    local hx, hy, hz = pgps.getCachedPosition()
    m_Stuck = p_Reason
    m_Status = "stuck"
    local s_Data = {
        reason = p_Reason,
        detail = p_Detail,
        pos = (hx and {x = hx, y = hy, z = hz}) or nil,
        fuel = turtle.getFuelLevel(),
    }
    print("DISTRESS: " .. tostring(p_Reason) .. " " .. tostring(p_Detail))
    PowNet.SendToServer("DroneMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Distress", s_Data))
end

function ClearDistress()
    m_Stuck = nil
end

-- Get unstuck without help where possible: straight up is almost always free, and a drone that
-- can climb out of a hole it dug does not need rescuing.
function OnRescue(p_ID, p_Message)
    local s_Up = tonumber((p_Message.data or {}).up) or 6
    local s_Climbed = 0
    for _ = 1, s_Up do
        if not pgps.up() then break end
        s_Climbed = s_Climbed + 1
    end
    ClearDistress()
    m_Status = "idle"
    SendHeartBeat()
    return true, {message = "climbed " .. s_Climbed .. " and cleared distress"}
end

function OnScan(p_ID, p_Message)
    local s_Sc = Scanner()
    if not s_Sc then return false, "no geo scanner on this drone" end
    local s_R = tonumber((p_Message.data or {}).radius) or 8
    local s_N, s_Err = absorbScan(s_Sc, s_R)
    if s_N == 0 and s_Err then return false, s_Err end
    UploadWorld()
    return true, {message = "scanned " .. s_N .. " blocks at radius " .. s_R}
end

function OnSurvey(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_W    = tonumber(d.w)    or 16
    local s_H    = tonumber(d.h)    or 16
    local s_Drop = tonumber(d.drop) or 24
    local s_Climb= tonumber(d.climb) or 8

    if executing then
        return false, "busy"
    end
    m_Job = {verb = "Survey", data = d}
    saveResume()

    -- A scout surveys by hopping and scanning rather than crawling and touching. Same command,
    -- same grid, roughly three orders of magnitude more blocks per move.
    local s_Sc = Scanner()
    if s_Sc then
        local s_R = tonumber(d.radius) or 8
        m_Status = "scanning"
        TaskStart()
        local s_Step, s_Total, s_Scans = s_R * 2, 0, 0
        for row = 1, s_H do
            for col = 1, s_W do
                if not executing then break end
                local n = absorbScan(s_Sc, s_R)
                s_Total, s_Scans = s_Total + n, s_Scans + 1
                UploadWorld()
                if col < s_W then
                    for _ = 1, s_Step do
                        if not executing then break end
                        if not stepForward(s_Climb) then break end
                    end
                    os.sleep(SCAN_COOLDOWN)
                end
            end
            if not executing then break end
            if row < s_H then
                local s_Turn = (row % 2 == 1) and pgps.turnRight or pgps.turnLeft
                s_Turn()
                for _ = 1, s_Step do
                    if not executing then break end
                    if not stepForward(s_Climb) then break end
                end
                s_Turn()
                os.sleep(SCAN_COOLDOWN)
            end
        end
        TaskEnd()
        m_Status = "idle"
        UploadWorld()
        m_Job = nil saveResume()
        return true, {message = "scanned " .. s_Total .. " blocks in " .. s_Scans .. " sweeps"}
    end

    m_Status = "surveying"
    TaskStart()

    -- Get to the surface once up front; after that `settle` keeps it there.
    settle(s_Drop)

    local s_Cells, s_Blocked = 0, 0
    for row = 1, s_H do
        for col = 1, s_W - 1 do
            if not executing then break end          -- Abort landed
            if stepForward(s_Climb) then
                settle(s_Drop)
                s_Cells = s_Cells + 1
            else
                s_Blocked = s_Blocked + 1
                -- Blocked on every climb attempt means something is above as well as ahead;
                -- that is a drone in a hole, not a hill in the way.
                if s_Blocked >= 3 then
                    Distress("blocked", "survey stalled after " .. s_Cells .. " cells")
                    TaskEnd()
                    return false, "stuck after " .. s_Cells .. " cells"
                end
                break                                 -- wall: give up this row, not the survey
            end
        end
        if not executing then break end
        if row < s_H then
            -- Turn onto the next lane, alternating so it sweeps rather than returns.
            local s_Turn = (row % 2 == 1) and pgps.turnRight or pgps.turnLeft
            s_Turn()
            if stepForward(s_Climb) then settle(s_Drop) end
            s_Turn()
        end
    end

    TaskEnd()
    m_Status = "idle"
    UploadWorld()
    m_Job = nil saveResume()
    return true, {message = "surveyed " .. s_Cells .. " cells, " .. s_Blocked .. " blocked"}
end


-- ===== DIG AND HAUL =================================================================
-- DroneWork.lua shipped entirely commented out, so nothing on the drone side could ever mine.
-- This is that half.

-- A turtle has 16 slots and silently stops picking things up when they are all full -- ore just
-- stays in the ground and the drone keeps working, which looks like success. Leave one slot of
-- headroom so a stack that splits mid-dig does not overflow.
function FreeSlots()
    local n = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) == 0 then n = n + 1 end
    end
    return n
end

-- Gravel and sand fall into the space you just cleared, so a single dig is not enough. Bounded,
-- because a dig that keeps succeeding forever means we are standing under a gravel column and
-- should give up rather than mine the sky.
local function digHard(p_Dig, p_Detect)
    local s_Tries = 0
    while p_Detect() do
        if not p_Dig() then return false end
        s_Tries = s_Tries + 1
        if s_Tries > 24 then return false end
        os.sleep(0.4)
    end
    return true
end

function DigForward() return digHard(turtle.dig,     turtle.detect)     end
function DigUp()      return digHard(turtle.digUp,   turtle.detectUp)   end
function DigDown()    return digHard(turtle.digDown, turtle.detectDown) end

-- Empty into storage, then come back and carry on. Asking StorageMan where to go (rather than
-- hardcoding a chest) is what lets storage move or grow without touching drone code.
function Deposit()
    local s_Res = PowNet.sendAndWaitForResponse("StorageMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "DepositPoint", {}), PowNet.SERVER_PROTOCOL)
    if type(s_Res) ~= "table" or s_Res.pos == nil then
        Distress("nowhere to deposit", tostring(type(s_Res) == "table" and s_Res.message or s_Res))
        return false
    end
    local hx, hy, hz = pgps.getCachedPosition()
    m_Status = "hauling"
    SendHeartBeat()

    local ok = pgps.moveTo(s_Res.pos.x, s_Res.pos.y + 1, s_Res.pos.z)
    if ok == false then
        Distress("cannot reach storage", s_Res.pos.x .. "," .. s_Res.pos.y .. "," .. s_Res.pos.z)
        return false
    end
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            turtle.dropDown()
        end
    end
    turtle.select(1)
    -- Back to where we were, so a dig resumes at the face instead of starting over.
    if hx then pgps.moveTo(hx, hy, hz) end
    m_Status = "mining"
    return true
end

local function depositIfFull()
    if FreeSlots() > 1 then return true end
    return Deposit()
end

-- Dig a box. Serpentine within each layer, then drop a level -- so the drone is always adjacent
-- to the next cell and never has to path back across ground it already cleared.
function OnDig(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_W = tonumber(d.w) or 8
    local s_L = tonumber(d.l) or 8
    local s_Depth = tonumber(d.depth) or 4
    if executing then return false, "busy" end

    m_Job = {verb = "Dig", data = d}
    saveResume()
    m_Status = "mining"
    TaskStart()

    -- Get to the ground first.
    --
    -- Dig used to start wherever the drone happened to be, and a drone that has just flown
    -- somewhere is in the air. The first real run did exactly that: a clean 3x3x2 serpentine at
    -- y=84, seventeen fuel spent, every turtle.dig() hitting nothing, and an empty inventory at
    -- the end. It looked like a successful mining run and moved no stone whatsoever.
    --
    -- settle() is the same descent the survey uses; the difference is only that a survey wants
    -- to hug the surface and a dig wants to start at it.
    local s_Dropped = settle(tonumber(d.drop) or 24)
    if s_Dropped > 0 then print("descended " .. s_Dropped .. " to the surface") end
    if not turtle.detectDown() then
        -- Still nothing underneath after descending: we are over a void or a very deep drop, and
        -- quarrying air would silently "succeed" again.
        TaskEnd()
        m_Status = "idle"
        m_Job = nil saveResume()
        Distress("nothing to dig", "no ground within " .. (tonumber(d.drop) or 24) .. " blocks")
        return false, "no ground beneath"
    end

    local s_Dug, s_Layers = 0, 0
    for layer = 1, s_Depth do
        if not executing then break end
        for row = 1, s_L do
            if not executing then break end
            for col = 1, s_W - 1 do
                if not executing then break end
                if not depositIfFull() then break end
                DigForward()
                if not pgps.forward() then
                    -- Something we cannot break (bedrock, a claim, a machine). Abandon the row
                    -- rather than the job; the rest of the box is still worth having.
                    break
                end
                s_Dug = s_Dug + 1
            end
            if row < s_L then
                local s_Turn = (row % 2 == 1) and pgps.turnRight or pgps.turnLeft
                s_Turn()
                DigForward()
                if not pgps.forward() then break end
                s_Turn()
            end
        end
        s_Layers = s_Layers + 1
        if layer < s_Depth then
            if not DigDown() then break end
            if not pgps.down() then break end
        end
    end

    -- Bring back whatever is in the hold; ore left in a parked drone is ore nobody can use.
    if FreeSlots() < 16 then Deposit() end

    TaskEnd()
    m_Status = "idle"
    m_Job = nil saveResume()
    UploadWorld()
    return true, {message = "dug " .. s_Dug .. " blocks over " .. s_Layers .. " layers"}
end

-- Fetch from a point and take it to storage. The hauler half of the loop: miners stay at the
-- face, haulers commute. Later this is what item conduits replace on fixed routes.
function OnHaul(p_ID, p_Message)
    local d = p_Message.data or {}
    if d.pos == nil then return false, "Missing pos" end
    if executing then return false, "busy" end
    m_Status = "hauling"
    TaskStart()
    local ok = pgps.moveTo(tonumber(d.pos.x), tonumber(d.pos.y) + 1, tonumber(d.pos.z))
    if ok == false then
        TaskEnd() m_Status = "idle"
        Distress("cannot reach pickup", tostring(d.pos.x))
        return false, "unreachable"
    end
    for i = 1, 16 do
        turtle.select(i)
        turtle.suckDown()
    end
    turtle.select(1)
    local s_Ok = Deposit()
    TaskEnd()
    m_Status = "idle"
    return s_Ok, {message = s_Ok and "hauled" or "haul failed"}
end

function OnAbort()
    if(not executing) then
        return false
    end
    print("Aborting...")
    -- Clear the flag as well as breaking pgps. BreakExec stops a pgps path mid-flight, but the
    -- survey loop is our own and only watches `executing` -- without this an abort would stop the
    -- current move and the lawnmower would calmly carry on to the next cell. This runs on the
    -- server thread, which is precisely why it can interrupt work happening on the drone thread.
    executing = false
    pgps.BreakExec()
    return true, "Aborted"
end


function OnStartTask(p_ID, p_Message)

end

function OnAbortTask(p_ID, p_Message)

end



local m_DroneEvents = {
    Reboot = {
        func = OnReboot,
    },
    GoTo = {
        func = OnGoTo,
    },
    Survey = {
        func = OnSurvey,
    },
    Scan = {
        func = OnScan,
    },
    Rescue = {
        func = OnRescue,
    },
    Dig = {
        func = OnDig,
    },
    Haul = {
        func = OnHaul,
    }
}


local m_ServerEvents = { -- Runs on a different thread so that we can interrupt drones while they execute work on the Drone message thread.
    Abort = {
        func = OnAbort,
    },
    StartTask = {
        func = OnStartTask
    },
    AbortTask = {
        func = OnAbortTask
    },
}

if Init() == false then
    return
end


PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents)

-- Make the heartbeat actually beat.
--
-- Init() sent exactly one, at boot, and nothing ever sent another -- so DroneMan's view of a
-- drone froze at the moment it registered. D1 sat docked at -95,83,-45 while the registry still
-- reported it at its spawn point, with the fuel level it had before it flew there. Position,
-- fuel and status were all write-once.
--
-- Safe to loop now only because SendHeartBeat no longer moves the turtle; see the note there.
-- Ship what this drone has seen to MapServer.
--
-- detectAll() has always recorded observations locally and MapServer has always had a handler to
-- merge them; the two were never connected, so the server's world was `{}` no matter how far the
-- fleet flew. This is the missing wire.
function UploadWorld()
    local s_World, s_Detail, s_Count = pgps.takeWorldDelta()
    if(s_Count == 0) then
        return true
    end
    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "SaveWorld",
        {cachedWorld = s_World, cachedWorldDetail = s_Detail})
    local s_Ok = PowNet.sendAndWaitForResponse("MapServer", s_Message, PowNet.SERVER_PROTOCOL)
    if(not s_Ok) then
        -- Put them back rather than lose them: an unreachable MapServer should cost a retry, not
        -- a hole in the map that nothing will ever revisit.
        for k,v in pairs(s_World) do pgps.noteObservation(k, v, s_Detail[k]) end
        print("MapServer did not take " .. s_Count .. " observations, keeping them")
        return false
    end
    print("Uploaded " .. s_Count .. " observations")
    return true
end

-- REFUEL AT THE DOCK
--
-- A drone that runs dry stops wherever it is, which is usually the least convenient place, and
-- pgps cannot move it even one block to recover. Topping up while parked is the cheapest possible
-- insurance: the drone is already stationary and next to the tower.
--
-- It pulls from whatever container is adjacent rather than a configured position, so a fuel chest
-- can be moved or added without touching drone code. Charcoal works as well as coal, which is why
-- the tree farm doubles as the power plant.
local FUEL_LOW = 4000

function TryRefuel()
    local s_Level = turtle.getFuelLevel()
    if s_Level == "unlimited" then return false end
    if s_Level >= FUEL_LOW then return false end

    for _, suck in ipairs({turtle.suckDown, turtle.suckUp, turtle.suck}) do
        for _ = 1, 4 do
            if not suck(8) then break end
        end
    end

    local s_Before = turtle.getFuelLevel()
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            -- refuel() silently ignores anything that is not fuel, so this is safe to try on
            -- every slot rather than needing to identify fuel items first.
            turtle.refuel()
        end
    end
    turtle.select(1)
    local s_Gained = turtle.getFuelLevel() - s_Before
    if s_Gained > 0 then
        print("refuelled +" .. s_Gained)
        return true
    end
    -- Nothing to burn and running low: say so, because a fleet quietly grinding to a halt for
    -- want of coal looks exactly like a fleet with nothing to do.
    if s_Before < (FUEL_LOW / 4) then
        Distress("low fuel", "level " .. s_Before .. ", nothing to refuel with at the dock")
    end
    return false
end

-- GPS RELAY
--
-- A parked loader is the ideal GPS host: hosting needs only the modem, and the chunky upgrade
-- occupies the other slot anyway. So the same drone that keeps ground ticking also extends
-- positioning coverage -- which is what makes expansion a matter of flying a drone somewhere
-- rather than hand-building another constellation.
--
-- Two rules, both non-negotiable:
--   * only while STATIONARY. A moving host broadcasts stale coordinates and quietly corrupts
--     the fix of every drone that hears it -- far worse than no coverage at all.
--   * only from a fix we actually trust, i.e. one obtained from the existing constellation.
--     Hosting from dead-reckoned position compounds error outward.
--
-- Note four hosts are still required for a fix, so a lone relay does not create coverage by
-- itself; it adds to the pool, letting a drone combine two originals with two relays.
m_Hosting = false

local function gpsRelay()
    while true do
        os.sleep(10)
        if Role() == "loader" and m_Status == "idle" and not executing then
            local hx, hy, hz = pgps.getCachedPosition()
            if hx and not m_Hosting then
                local s_Modem = peripheral.find("modem")
                if s_Modem then
                    -- Re-anchor before broadcasting: dead reckoning is good enough to navigate
                    -- with and not good enough to publish.
                    local fx, fy, fz = gps.locate(4, false)
                    if fx then
                        s_Modem.open(gps.CHANNEL_GPS)
                        m_Hosting = true
                        m_HostPos = {x = fx, y = fy, z = fz}
                        print("GPS relay hosting at " .. fx .. "," .. fy .. "," .. fz)
                        SendHeartBeat()
                    end
                end
            end
        elseif m_Hosting and (m_Status ~= "idle" or executing) then
            -- About to move: stop answering rather than lie.
            local s_Modem = peripheral.find("modem")
            if s_Modem then pcall(s_Modem.close, gps.CHANNEL_GPS) end
            m_Hosting = false
            m_HostPos = nil
            print("GPS relay stopped (moving)")
        end
    end
end

-- Answer GPS pings the same way a stationary host computer does.
local function gpsServe()
    while true do
        local ev, side, ch, reply, msg = os.pullEvent("modem_message")
        if m_Hosting and m_HostPos and ch == gps.CHANNEL_GPS and msg == "PING" then
            local s_Modem = peripheral.wrap(side)
            if s_Modem then
                s_Modem.transmit(reply, gps.CHANNEL_GPS,
                    {m_HostPos.x, m_HostPos.y, m_HostPos.z})
            end
        end
    end
end

local HEARTBEAT_SECONDS = 30
local function heartbeat()
    while true do
        os.sleep(HEARTBEAT_SECONDS)
        SendHeartBeat()
        UploadWorld()
        -- Only when idle: a drone mid-task is not at the dock and sucking from whatever happens
        -- to be next to it would steal from a chest it is standing over.
        if m_Status == "idle" and not executing then
            TryRefuel()
        end
    end
end

PowNet.SetShutdownHook(OnShutdown)

parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, heartbeat, resumeBranch, gpsRelay, gpsServe)