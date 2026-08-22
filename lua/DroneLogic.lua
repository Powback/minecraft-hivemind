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
            -- REGISTER ANYWAY.
            --
            -- Returning here left the drone with no name, no registration and no way to say so:
            -- invisible to DroneMan, absent from every tool, and indistinguishable from a turtle
            -- that had been destroyed. A drone that cannot work out WHERE it is still knows THAT
            -- it is, and that is the one fact a rescue needs.
            print("no GPS -- registering without a position so someone can come and find me")
            Distress("no GPS fix", "registered without a position; needs coverage extending to it")
        end
        local s_Fuel = turtle.getFuelLevel()
        local s_Data = {id = os.getComputerID(),
                        pos = (x and {x = x, y = y, z = z}) or nil, fuel = s_Fuel,
                        role = Role(), noGps = (x == nil) or nil}
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
    -- WAIT FOR THE ANSWER.
    --
    -- This was fire-and-forget, which meant a drone could not tell a healthy fleet from being out
    -- of radio range: it shouted into the dark on a timer and carried on working. Out of range is
    -- precisely when a drone most needs to know, because it is the one condition it can still fix
    -- by itself -- by going back the way it came until someone answers.
    --
    -- Short timeout: this runs on a loop and a slow DroneMan should cost a missed beat, not a
    -- stalled drone.
    -- Five seconds, not two. DroneMan services the whole fleet from one receive loop, so a reply
    -- can legitimately take a while; a tight timeout turns "busy" into "missing".
    local s_Reply = PowNet.sendAndWaitForResponse("DroneMan", s_Message, PowNet.SERVER_PROTOCOL, 5)
    return s_Reply ~= false and s_Reply ~= nil
end

-- WALK BACK UNTIL SOMEONE ANSWERS.
--
-- The route the drone walked in on is the one route it KNOWS is passable, and the link worked
-- somewhere along it. So losing contact is recoverable without any help: retrace the trail, testing
-- after every crumb, and stop the moment the fleet replies.
--
-- This is the only situation where moving on an unverified position is right. The guard that
-- normally forbids it exists because drift walked a drone out of the world -- but out of range that
-- same guard freezes it exactly where it must not stay, turning a recoverable drone into a lost
-- one. Retracing is safe because it is going back, not reasoning about somewhere new.
local RECOVER_MAX_CRUMBS = 120

function RecoverLink()
    local s_Was = m_Status
    m_Status = "recovering"
    pgps.setRecovering(true)
    print("link lost -- retracing " .. tostring(pgps.trailLength()) .. " crumbs")

    local s_Steps = 0
    while s_Steps < RECOVER_MAX_CRUMBS do
        local bx, by, bz = pgps.trailBack()
        if bx == nil then break end
        s_Steps = s_Steps + 1
        pgps.flyTo(bx, by, bz, 32)
        if SendHeartBeat() then
            pgps.setRecovering(false)
            m_Status = s_Was
            print("link regained after " .. s_Steps .. " crumbs")
            Distress("link lost and regained", "retraced " .. s_Steps .. " crumbs")
            return true
        end
    end

    pgps.setRecovering(false)
    m_Status = "stuck"
    -- Out of trail and still alone. Say so on the terminal and in the fault file: nobody is
    -- listening on rednet by definition, so this is the only place it can be recorded.
    Distress("link lost", "retraced " .. s_Steps .. " crumbs without regaining contact")
    return false
end

-- Cheap liveness. The registry cannot tell a docked drone from one that no longer exists:
-- heartbeats only fire at boot and shutdown, so a drone that is mined out of the world stays
-- "idle" forever and keeps being handed work. D2 was dug up by D1 and was still being offered
-- jobs afterwards.
function OnPing(p_ID, p_Message)
    return true, {alive = true, status = m_Status, fuel = turtle.getFuelLevel()}
end

function OnReboot(p_ID, p_Message)
    os.reboot()
end

-- A CC terminal cannot be read from outside the game, so a handler that misbehaves is completely
-- opaque -- which is exactly why "the drone accepts GoTo and does not move" was unfalsifiable.
-- Truncating, not growing. The Bridge learned this the hard way: an append-only log reached the
-- 8MB computer_space_limit and then killed the module with "Out of space" -- a diagnostic that
-- destroys the thing it is meant to explain.
local TRACE_LIMIT = 32 * 1024
local function trace(p_What)
    pcall(function()
        if fs.exists("/drone.log") and fs.getSize("/drone.log") > TRACE_LIMIT then
            fs.delete("/drone.log")
        end
        local h = fs.open("/drone.log", "a")
        if h then h.writeLine(("%s %s"):format(tostring(os.clock()), tostring(p_What))) h.close() end
    end)
end

function OnGoTo(p_ID, p_Message)
    trace("GoTo received from " .. tostring(p_ID))
    local d = p_Message and p_Message.data
    if d == nil or d.pos == nil then
        trace("GoTo REFUSED: no pos")
        return false, "no pos specified"
    end

    -- Re-fix cheaply instead of setLocationFromGPS, which STEPS THE TURTLE forward and back to
    -- work out its heading. That is fine once at boot and wrong here: it is a move, so it can be
    -- blocked, and when it is the heading comes back nil and every later moveTo has no idea which
    -- way the drone is facing.
    pgps.verifyPosition()
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then
        trace("GoTo REFUSED: no position fix")
        return false, "no position fix"
    end
    x, y, z = cx, cy, cz

    m_Status = "moving"
    TaskStart()
    trace(("GoTo %s,%s,%s -> %s,%s,%s"):format(cx, cy, cz, tostring(d.pos.x), tostring(d.pos.y), tostring(d.pos.z)))
    local s_Status, s_Message = pgps.moveTo(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z))
    if s_Status == false then
        -- Fall back to flying it directly. A recall is most needed exactly where the map is
        -- thinnest, so refusing to move because the SERVER cannot plot a route is backwards.
        trace("GoTo: no mapped route (" .. tostring(s_Message) .. ") -- flying direct")
        s_Status, s_Message = pgps.flyTo(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z))
    end
    TaskEnd()
    m_Status = "idle"

    if(s_Status == false) then
        trace("GoTo FAILED: " .. tostring(s_Message))
        Distress("GoTo failed", tostring(s_Message))
        return false, tostring(s_Message or "could not reach position")
    end

    if d.heading ~= nil then
        m_Status = "rotation"
        pgps.turnTo(d.heading)
        m_Status = "idle"
    end
    trace("GoTo done")
    return true, {arrived = {x = d.pos.x, y = d.pos.y, z = d.pos.z}}
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

-- Step forward, climbing over whatever is in the way -- and then COMING BACK DOWN.
--
-- The descent is the whole point. Without it every obstacle ratcheted the drone permanently
-- upward: a survey walks hundreds of forward steps, each dune or wall added a few blocks of
-- altitude, nothing ever gave any back, and the scout ended up at y=117 diligently scanning empty
-- sky. It looked like the scanner was broken or the grid was wrong; it was neither. A scout that
-- drifts above the terrain is not surveying anything, it is just burning fuel politely.
local function stepForward(p_MaxClimb)
    local s_Climbs = 0
    while true do
        local s_Ok, s_Why = pgps.forward()
        if s_Ok then break end

        -- CLIMBING ONLY HELPS OVER A BLOCK.
        --
        -- forward() refuses for two quite different reasons: something is in the way, or we are
        -- not allowed to go there (the operating bounds, or no position fix). Treating the second
        -- as an obstacle makes the drone climb against the boundary -- and since the boundary is
        -- vertical, it never clears it. D3 rode the map edge all the way to y=200 doing exactly
        -- this, scanning empty sky the whole way. Going up cannot fix a refusal that is not about
        -- height.
        if s_Why == "out of bounds" or s_Why == "position unverified" then
            return false, s_Why
        end

        if s_Climbs >= p_MaxClimb then return false, "obstacle taller than " .. p_MaxClimb end
        if not pgps.up() then return false, "blocked above" end
        s_Climbs = s_Climbs + 1
    end

    -- Give back exactly what was taken, and only into open air -- never dig down to get there,
    -- and never descend further than we climbed, so this cannot walk a drone into a ravine.
    for _ = 1, s_Climbs do
        if turtle.detectDown() then break end
        if not pgps.down() then break end
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
-- A scan reports only the blocks that EXIST. Recording just those teaches the map where walls are
-- and never where space is -- and a_star cannot route through a cell it has not been told is empty,
-- so "unknown" is impassable. The result was a world model that could not answer the one question
-- navigation asks. D3 flew to y=200 scanning the whole way and the server still had no path back
-- down, because the sky it had flown through was unknown rather than air.
--
-- The emptiness is free information: the scanner already guarantees it returned every non-air block
-- in the cube, so anything it did NOT return is air, definitionally.
--
-- Air is filled in over a SMALLER cube than the solids are read from. A radius-8 scan is 4,913
-- cells and marking them all would put thousands of observations per scan onto rednet every 2.2s,
-- which is a lot of traffic to describe an empty sky. Radius 4 is 729 cells -- enough to give the
-- pathfinder a genuinely navigable corridor around wherever the drone has been -- while solids keep
-- the full radius, because knowing about a distant wall is worth more than knowing about distant
-- nothing.
local AIR_RADIUS = 4

local function absorbScan(p_Scanner, p_Radius)
    local s_Blocks, s_Err = p_Scanner.scan(p_Radius)
    if not s_Blocks then
        return 0, tostring(s_Err)
    end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then
        return 0, "no position fix"
    end

    -- Index the solids first so the air pass can skip them.
    local s_Solid = {}
    for _, b in ipairs(s_Blocks) do
        local idx = (cx + b.x) .. ":" .. (cy + b.y) .. ":" .. (cz + b.z)
        s_Solid[idx] = true
        -- Detail shaped like {turtle.inspect()} so it matches what detectAll writes and what the
        -- renderer reads: entry [2] is the block table with .name.
        pgps.noteObservation(idx, 1, {true, {name = b.name}})
    end

    -- Only claim emptiness from a CONFIRMED position. Solids are additive and a drifted one is
    -- corrected by the next scan; air is subtractive -- it prunes the block index -- so writing 729
    -- of them from a position the drone only believes it is at would erase real map data over a
    -- wide area. Drift is not hypothetical: D3 was found 24 blocks from where it reported.
    if not pgps.positionVerified() then
        return #s_Blocks
    end

    local s_R = math.min(AIR_RADIUS, p_Radius)
    for dx = -s_R, s_R do
        for dy = -s_R, s_R do
            for dz = -s_R, s_R do
                local idx = (cx + dx) .. ":" .. (cy + dy) .. ":" .. (cz + dz)
                if not s_Solid[idx] then
                    pgps.noteObservation(idx, 0)
                end
            end
        end
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
    -- A crafting table is an upgrade like any other, and it is what makes a drone able to PRODUCE
    -- rather than only extract. Reported so TaskMan can route craft work to a drone that can
    -- actually do it, instead of discovering the hard way that turtle.craft is nil.
    if IsCrafter() then return "crafter" end
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

-- Report how a job ended when the job is NOT one of the RunJob verbs.
--
-- RunJob reports for the four that use it. Survey predates it and does not, so a survey that
-- failed left its task at zero progress for ever: the queue reclaimed it, handed it straight back
-- to the only scout, the scout failed again, and round it went. From outside the queue looked full
-- and the fleet looked idle -- which is exactly what it was, in a loop.
local function reportTask(p_Data, p_Ok, p_Reason, p_Result)
    if p_Data == nil or p_Data.taskId == nil then return end
    pcall(function()
        PowNet.SendToServer("TaskMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "TaskDone",
            {id = p_Data.taskId, ok = p_Ok and true or false,
             reason = (not p_Ok) and tostring(p_Reason) or nil,
             result = p_Ok and p_Result or nil}))
    end)
end

function OnSurvey(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_W    = tonumber(d.w)    or 16
    local s_H    = tonumber(d.h)    or 16
    -- Generous, because the entire value of a scan is being NEAR the ground. Twenty-four is not
    -- enough to come down from cruising height over low terrain, and a drone that stops short spends
    -- the rest of the sweep scanning sky.
    local s_Drop = tonumber(d.drop) or 64
    local s_Climb= tonumber(d.climb) or 8

    if executing then
        -- Busy is NOT a failure of the task -- it will be offered again -- so it is not reported.
        return false, "busy"
    end

    -- Go where the survey was ORDERED, not wherever the scout happens to be parked.
    --
    -- Without this a scan always started at the dock, which is why surveying could never find iron:
    -- the scanner reaches 8 blocks and the ore is fifty below. Sending the scout down a shaft a
    -- miner has already cut is the whole point of pairing them.
    if d.pos and d.pos.x then
        m_Status = "moving"
        if pgps.moveTo(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z)) == false then
            m_Status = "idle"
            trace("Survey FAILED: could not reach " .. tostring(d.pos.x) .. "," ..
                  tostring(d.pos.y) .. "," .. tostring(d.pos.z))
            reportTask(d, false, "could not reach the survey start")
            return false, "could not reach the survey start"
        end
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
                -- A scan is thousands of blocks recorded relative to where we think we are, so a
                -- drifted position poisons the map wholesale rather than one cell at a time. Fix
                -- first, scan second.
                pgps.verifyPosition()
                -- SCAN THE GROUND, NOT THE SKY.
                --
                -- The scanner reads a SPHERE of radius r around the drone, so where the drone is standing
                -- decides what the scan is worth. From cruising height almost all of it is air: at y=95
                -- with r=8 it covers y=87..103, and over terrain twenty blocks below that is thousands of
                -- cells of nothing, recorded diligently.
                --
                -- The WALKING survey below already settles before every step. This branch -- the one a
                -- scout with a scanner actually takes -- never did, so the better-equipped drone did the
                -- worse survey. Dropping to the surface re-centres the sphere so half of it is underground,
                -- which is where the ore is and the entire reason for scanning.
                settle(s_Drop)
                
                local n = absorbScan(s_Sc, s_R)
                s_Total, s_Scans = s_Total + n, s_Scans + 1
                UploadWorld()
                if col < s_W then
                    for _ = 1, s_Step do
                        if not executing then break end
                        if not stepForward(s_Climb) then break end
                    end
                    settle(s_Drop)   -- follow the ground DOWN too; stepForward only gives back what it climbed
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
                settle(s_Drop)   -- follow the ground DOWN too; stepForward only gives back what it climbed
                s_Turn()
                os.sleep(SCAN_COOLDOWN)
            end
        end
        TaskEnd()
        m_Status = "idle"
        UploadWorld()
        m_Job = nil saveResume()
        reportTask(d, true, nil, {scanned = s_Total, sweeps = s_Scans})
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
    reportTask(d, true, nil, {cells = s_Cells, blocked = s_Blocked})
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
-- Never break the fleet's own infrastructure. EVERY dig in every job funnels through digHard, so
-- this is the one place the rule needs to exist -- and the only place it cannot be forgotten when
-- a new job type is added.
--
-- D1 mined D2 out of the world: a turtle became an item in a chest while the registry went on
-- listing it as idle. Refusing the whole SITE would be the wrong fix -- sites legitimately contain
-- things, and a job that will not start is worse than one that digs around an obstacle. So check
-- the block that is actually about to be broken, and leave it standing.
local PROTECTED = {
    ["minecraft:chest"]         = true,
    ["minecraft:trapped_chest"] = true,
    ["minecraft:barrel"]        = true,
    ["minecraft:furnace"]       = true,
    ["minecraft:blast_furnace"] = true,
    ["minecraft:smoker"]        = true,
    ["minecraft:hopper"]        = true,
    ["minecraft:shulker_box"]   = true,
}

function IsProtected(p_Name)
    if p_Name == nil then return false end
    if PROTECTED[p_Name] then return true end
    -- Anything from the CC mod is fleet infrastructure by definition: turtles, computers, modems,
    -- cable, disk drives, monitors. Matching the namespace covers blocks nobody has added yet.
    return string.sub(p_Name, 1, 14) == "computercraft:"
end

local function digHard(p_Dig, p_Detect, p_Inspect, p_Which)
    local s_Tries = 0
    while p_Detect() do
        if p_Inspect then
            local s_Ok, s_Blk = p_Inspect()
            if s_Ok and s_Blk and IsProtected(s_Blk.name) then
                print("refusing to mine " .. tostring(s_Blk.name))
                return false, s_Blk.name
            end
        end
        if not p_Dig() then return false end
        s_Tries = s_Tries + 1
        if s_Tries > 24 then return false end
        os.sleep(0.4)
    end
    -- Every dig in the fleet funnels through here, so this is the one place that has to tell the
    -- map the block is gone -- and it reports the cell even when the loop never ran, because
    -- "nothing to dig" is itself the observation that the cell is air.
    pgps.noteCleared(p_Which)
    return true
end

function DigForward() return digHard(turtle.dig,     turtle.detect,     turtle.inspect,     "forward") end
function DigUp()      return digHard(turtle.digUp,   turtle.detectUp,   turtle.inspectUp,   "up")      end
function DigDown()    return digHard(turtle.digDown, turtle.detectDown, turtle.inspectDown, "down")    end

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
----------------------------------------------------------------------------------------------
-- Job framework
----------------------------------------------------------------------------------------------
-- Every job verb used to repeat the same twelve lines of lifecycle -- busy check, m_Job,
-- saveResume, status, TaskStart/TaskEnd, deposit, UploadWorld -- and they had already drifted
-- apart: some forgot to clear m_Job, some never saved resume state, and OnDig and OnLumber each
-- had to be patched SEPARATELY to travel to the ordered site. The one that was missed dug up the
-- base for weeks.
--
-- A new job type is now just a body function; the scaffolding cannot be forgotten because it is
-- not written again.
--
--   opts.status   drone status while running          (default "working")
--   opts.travel   move to data.pos first              (default true)
--   opts.settle   descend to the ground first         (default true)
--   opts.deposit  unload at the end if carrying       (default true)
--   opts.upload   push observations at the end        (default true)
function RunJob(p_Name, p_Data, p_Opts, p_Body)
    local d = p_Data or {}
    local o = p_Opts or {}
    if executing then
        trace(("JOB %s REFUSED: busy"):format(p_Name))
        return false, "busy"
    end

    trace(("JOB %s start %s"):format(p_Name, textutils.serialiseJSON and
        (pcall(textutils.serialiseJSON, d) and textutils.serialiseJSON(d) or "?") or "?"))
    m_Job = {verb = p_Name, data = d}
    saveResume()
    m_Status = o.status or "working"
    TaskStart()

    local function finish(p_Ok, p_Res)
        if o.deposit ~= false and FreeSlots() < 16 then Deposit() end
        TaskEnd()
        m_Status = "idle"
        m_Job = nil
        saveResume()
        if o.upload ~= false then pcall(UploadWorld) end

        -- Tell TaskMan how it ended. Without this progress stays at 0 for ever, and once stalled
        -- assignments started being reclaimed that turned into a loop: the crafter repeated a
        -- finished chest order every ninety seconds, correctly reporting it was short of the
        -- planks it had already made into chests.
        if d.taskId ~= nil then
            pcall(function()
                PowNet.SendToServer("TaskMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL,
                    "TaskDone", {id = d.taskId, ok = p_Ok and true or false,
                                 reason = (not p_Ok) and tostring(p_Res) or nil,
                                 result = p_Ok and p_Res or nil}))
            end)
        end
        return p_Ok, p_Res
    end

    -- Go to the ordered site, or refuse. Digging "somewhere" is worse than digging nowhere.
    if o.travel ~= false and d.pos and d.pos.x and d.pos.z then
        local s_Ty = tonumber(d.pos.y)
        local s_Arrived = pgps.moveTo(tonumber(d.pos.x), s_Ty and (s_Ty + 1) or nil, tonumber(d.pos.z))
        if s_Arrived == false then
            Distress("cannot reach site",
                tostring(d.pos.x) .. "," .. tostring(d.pos.y) .. "," .. tostring(d.pos.z))
            return finish(false, "cannot reach site")
        end
    end

    if o.settle ~= false then settle(tonumber(d.drop) or 24) end

    -- table.pack, NOT `local ok, res = pcall(...)`.
    --
    -- Two locals keep the first return value and throw the rest away, so a body ending in the
    -- ordinary Lua idiom `return nil, "reason"` handed back res=nil and the reason vanished --
    -- and, because pcall itself succeeded, RunJob reported the job DONE. Every "short of planks",
    -- "could not reach the chest" and "no item to craft" was silently converted into success. A
    -- job that fails quietly is worse than one that crashes: the fleet moves on believing the work
    -- happened, and the shortfall surfaces much later as something inexplicable.
    --
    -- So both conventions are honoured: throwing reports, and returning nil/false reports.
    local s_Ret = table.pack(pcall(p_Body, d))
    if not s_Ret[1] then
        -- A job that throws must report, not vanish: the drone is left somewhere unexpected and
        -- somebody has to know why.
        trace(("JOB %s THREW %s"):format(p_Name, tostring(s_Ret[2])))
        Distress(p_Name .. " failed", tostring(s_Ret[2]))
        return finish(false, tostring(s_Ret[2]))
    end

    local s_Res, s_Why = s_Ret[2], s_Ret[3]
    if s_Res == nil or s_Res == false then
        local s_Reason = tostring(s_Why or "job returned no result and gave no reason")
        trace(("JOB %s FAILED %s"):format(p_Name, s_Reason))
        Distress(p_Name .. " failed", s_Reason)
        return finish(false, s_Reason)
    end
    trace(("JOB %s done"):format(p_Name))
    return finish(true, s_Res)
end

-- The w x l boustrophedon walk, previously written out four times with the same turn parity and
-- the same off-by-one. p_OnCell returns false to abandon the current row; p_Advance moves to the
-- next row and returns false to abandon the job.
function Serpentine(p_W, p_L, p_OnCell, p_Advance)
    p_Advance = p_Advance or function() return pgps.forward() end
    for row = 1, p_L do
        if not executing then return row - 1 end
        for col = 1, p_W - 1 do
            if not executing then return row - 1 end
            if p_OnCell(row, col) == false then break end
        end
        if row < p_L then
            local s_Turn = (row % 2 == 1) and pgps.turnRight or pgps.turnLeft
            s_Turn()
            if p_Advance() == false then return row end
            s_Turn()
        end
    end
    return p_L
end

function OnDig(p_ID, p_Message)
    return RunJob("Dig", p_Message.data, {status = "mining"}, function(d)
        local s_W     = tonumber(d.w)     or 8
        local s_L     = tonumber(d.l)     or 8
        local s_Depth = tonumber(d.depth) or 4

        -- Refuse to quarry air. A drone that has just flown somewhere is airborne, and the first
        -- real run dug a clean 3x3x2 of nothing at y=84: seventeen fuel spent, every dig hitting
        -- nothing, empty inventory, and a job that reported success.
        if not turtle.detectDown() then
            Distress("nothing to dig", "no ground within " .. (tonumber(d.drop) or 24) .. " blocks")
            error("no ground beneath")
        end

        local s_Dug, s_Layers = 0, 0
        for layer = 1, s_Depth do
            if not executing then break end
            Serpentine(s_W, s_L, function()
                if not depositIfFull() then return false end
                DigForward()
                -- Something unbreakable (bedrock, a claim, a machine). Abandon the row, not the
                -- job: the rest of the box is still worth having.
                if not pgps.forward() then return false end
                s_Dug = s_Dug + 1
            end, function()
                DigForward()
                return pgps.forward()
            end)
            s_Layers = s_Layers + 1
            if layer < s_Depth then
                if not DigDown() then break end
                if not pgps.down() then break end
            end
        end

        return {message = "dug " .. s_Dug .. " blocks over " .. s_Layers .. " layers",
                dug = s_Dug, layers = s_Layers}
    end)
end

-- Fetch from a point and take it to storage. The hauler half of the loop: miners stay at the
-- face, haulers commute. Later this is what item conduits replace on fixed routes.
----------------------------------------------------------------------------------------------
-- Lumber
----------------------------------------------------------------------------------------------
-- Wood is the gate in front of everything else the fleet wants to build: chests for field caches,
-- planks and sticks for crafting, and therefore any factory at all. Nothing else in the fleet
-- produces it, so until this exists the swarm cannot build its own infrastructure.
--
-- Leaves are cleared as the trunk is climbed, on purpose. Felling only the trunk leaves the canopy
-- to decay on Minecraft's own schedule, which may be minutes -- and saplings come from leaf decay,
-- so a drone that only takes logs walks away with no way to replant and the forest shrinks every
-- pass. Breaking leaves makes the sapling drop now, while we are standing there to pick it up.
local function isLog(p_Name)
    return p_Name ~= nil and (string.find(p_Name, "_log", 1, true)
                           or string.find(p_Name, "_stem", 1, true))
end
local function isLeaf(p_Name)     return p_Name ~= nil and string.find(p_Name, "_leaves", 1, true) end
local function isSapling(p_Name)  return p_Name ~= nil and string.find(p_Name, "_sapling", 1, true) end

local function selectMatching(p_Pred)
    for i = 1, 16 do
        local it = turtle.getItemDetail(i)
        if it and p_Pred(it.name) then turtle.select(i) return true end
    end
    return false
end

-- Drops land on the ground and in the air around a felled trunk; sweep all three planes.
local function suckAround()
    pcall(turtle.suck)
    pcall(turtle.suckUp)
    pcall(turtle.suckDown)
end

-- Fell the tree whose trunk is directly in FRONT. Returns how many log blocks were taken.
local function fellTree()
    if not DigForward() then return 0 end
    if not pgps.forward() then return 0 end

    local s_Logs, s_Climbed = 1, 0
    while true do
        local ok, blk = turtle.inspectUp()
        if not (ok and isLog(blk.name)) then break end
        if not DigUp() then break end
        if not pgps.up() then break end
        s_Climbed = s_Climbed + 1
        s_Logs = s_Logs + 1

        -- Clear the canopy at this level so saplings drop while we are here to collect them.
        for _ = 1, 4 do
            local okf, b = turtle.inspect()
            if okf and isLeaf(b.name) then DigForward() end
            pgps.turnRight()
        end
        suckAround()
    end

    for _ = 1, s_Climbed do pgps.down() end
    suckAround()

    -- Replant. The turtle is standing IN the old trunk base, so it has to step back before the
    -- sapling has somewhere to go: placeDown would target the dirt block it is standing on.
    if pgps.back() then
        if selectMatching(isSapling) then
            pcall(turtle.place)
        end
    end
    turtle.select(1)
    return s_Logs
end

-- Go and get SPECIFIC blocks, and take the WHOLE cluster.
--
-- Dig sweeps a volume, which is right for bulk stone and wrong for everything the survey already
-- located: 6 coal ore at known coordinates do not need an 8x8x4 hole. The seeds come from
-- MapServer's block index, so this is the consuming half of surveying -- without it the index is
-- a report nobody acts on.
--
-- Seeds are only a starting point. Ore generates in VEINS, and the index holds at most a dozen
-- sample positions per block type, so mining just the samples would leave most of the vein in the
-- ground and require re-surveying to find what was always there. Each seed is therefore flood
-- filled: mine it, then consider its neighbours, and keep going while they match. `limit` bounds
-- the whole job so one enormous vein cannot consume a drone indefinitely.
--
-- Blocks are approached from ABOVE and dug downward: a turtle cannot occupy the target, and the
-- space above it is the one position reachable for anything with air over it.
function OnGather(p_ID, p_Message)
    return RunJob("Gather", p_Message.data,
        {status = "mining", travel = false, settle = false}, function(d)
        local s_Match  = d.match
        local s_Limit  = tonumber(d.limit) or 64
        local s_Queue  = {}
        local s_Seen   = {}
        local s_Got, s_Missed = 0, 0

        local function key(x, y, z) return x .. ":" .. y .. ":" .. z end
        local function push(x, y, z)
            if x and y and z and not s_Seen[key(x, y, z)] then
                s_Queue[#s_Queue + 1] = {x = x, y = y, z = z}
            end
        end
        local function wanted(p_Name)
            if p_Name == nil then return false end
            if IsProtected(p_Name) then return false end
            if s_Match == nil then return true end
            return string.find(p_Name, s_Match, 1, true) ~= nil
        end

        for _, t in ipairs(d.targets or {}) do
            push(tonumber(t.x), tonumber(t.y), tonumber(t.z))
        end

        -- Cap CANDIDATES as well as blocks taken. The limit above bounds what we mine, but a
        -- vein sitting in solid rock has a boundary of non-matching neighbours, each costing a
        -- flight to inspect -- so an exhausted vein could cost dozens of trips for nothing.
        local s_Checked, s_MaxChecks = 0, math.max(24, s_Limit * 3)
        while #s_Queue > 0 and s_Got < s_Limit and s_Checked < s_MaxChecks and executing do
            s_Checked = s_Checked + 1
            local t = table.remove(s_Queue)
            local k = key(t.x, t.y, t.z)
            if not s_Seen[k] then
                s_Seen[k] = true
                if not depositIfFull() then break end
                -- Re-fix before each dig. Cheap (no movement) and this is the job that edits the
                -- map destructively, so it is the one that must know where it is.
                pgps.verifyPosition()
                if pgps.moveTo(t.x, t.y + 1, t.z) ~= false then
                    local s_Ok, s_Blk = turtle.inspectDown()
                    if s_Ok and s_Blk and wanted(s_Blk.name) then
                        if DigDown() then
                            s_Got = s_Got + 1
                            -- The vein continues through the faces of what we just took.
                            push(t.x + 1, t.y, t.z)
                            push(t.x - 1, t.y, t.z)
                            push(t.x, t.y, t.z + 1)
                            push(t.x, t.y, t.z - 1)
                            push(t.x, t.y - 1, t.z)
                            push(t.x, t.y + 1, t.z)
                        end
                    end
                else
                    s_Missed = s_Missed + 1
                end
            end
        end

        return {message = ("gathered %d (limit %d, %d unreachable)")
                    :format(s_Got, s_Limit, s_Missed),
                got = s_Got, missed = s_Missed}
    end)
end

-- CRAFTING
--
-- The gate everything else was behind. The fleet could dig, carry and smelt, so it could obtain
-- raw material and it could not turn any of it into a single useful object -- no planks, so no
-- chests, so no field caches; no crafting table, so no second crafty turtle; no sticks, so no
-- tools. A settlement that cannot make anything is a quarry with extra steps.
--
-- Needs a turtle with a crafting-table upgrade. turtle.craft simply does not exist otherwise, so
-- this refuses loudly on the wrong drone rather than failing in some subtler way further in.

-- The 3x3 grid maps onto a 4x4 inventory, so it is NOT slots 1-9: the fourth column is outside the
-- grid and anything left there makes the craft fail with no explanation.
local CRAFT_SLOTS = {1, 2, 3, 5, 6, 7, 9, 10, 11}

function IsCrafter()
    return type(turtle.craft) == "function"
end

-- Staging slots, outside the crafting grid.
--
-- turtle.suck takes whatever the chest offers next -- there is no "suck the planks". So items are
-- pulled in bulk, consolidated by kind into these slots, and only then dealt into the grid. Four
-- is enough for every recipe in the graph (none has more than two distinct inputs) and the code
-- says so rather than silently mis-crafting if that ever stops being true.
local STAGE_SLOTS = {13, 14, 15, 16}

local function emptyInventory()
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            turtle.dropDown()
        end
    end
end

--- Pull from the chest below, keep only the wanted kinds, and put everything else straight back.
--- Returns name -> staging slot.
---
--- The "put everything else back" half is not tidiness. turtle.suck cannot ask for a named item,
--- so a drone drawing from the fleet's MAIN store hoovers up sandstone, glass and everything else
--- along with the logs. Two things go wrong if that is left alone: the base is quietly emptied into
--- a turtle, and -- worse -- the junk sits in slots 1-11, which ARE the crafting grid, so the craft
--- either produces the wrong item or silently nothing.
local function stageFromChest(p_Wanted)
    local s_Where = {}

    -- PULL IN BULK FIRST, sort afterwards.
    --
    -- turtle.suckDown always takes the chest's FIRST occupied slot. Sucking one stack, deciding it
    -- is not wanted and dropping it straight back puts it right back in that first slot -- so the
    -- drone cycles the same stack of glass for ever and never reaches the logs four slots further
    -- in. Staging came back empty every time while the chest plainly held 64 logs.
    --
    -- Filling all twelve non-staging slots before returning anything means the leading stacks stay
    -- OUT of the chest while we look past them, which is the only way to see what is behind them.
    local s_Pulled = 0
    for i = 1, 12 do
        turtle.select(i)
        if turtle.getItemCount(i) == 0 then
            if not turtle.suckDown() then break end
            s_Pulled = s_Pulled + 1
        end
    end
    if s_Pulled == 0 then return nil, "the pickup chest gave up nothing" end

    -- Keep what the recipe asked for...
    for i = 1, 12 do
        local d = turtle.getItemDetail(i)
        if d and p_Wanted[d.name] then
            local s_Slot = s_Where[d.name]
            if s_Slot == nil then
                for _, cand in ipairs(STAGE_SLOTS) do
                    local cd = turtle.getItemDetail(cand)
                    if cd == nil or cd.name == d.name then s_Slot = cand break end
                end
                if s_Slot == nil then
                    for j = 1, 12 do
                        if turtle.getItemCount(j) > 0 then turtle.select(j) turtle.dropDown() end
                    end
                    return nil, "more ingredient kinds than staging slots"
                end
                s_Where[d.name] = s_Slot
            end
            turtle.select(i)
            turtle.transferTo(s_Slot)
        end
    end

    -- ...and hand everything else straight back. The fleet's whole store passes through this
    -- turtle; none of it may stay there, and anything left in slots 1-11 is IN the crafting grid
    -- and would change what turtle.craft believes it is making.
    for i = 1, 12 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            turtle.dropDown()
        end
    end

    return s_Where
end

--- Deal p_Count of the item staged at p_From into grid slot p_To.
local function dealInto(p_From, p_To, p_Count)
    if p_From == nil then return 0 end
    local s_Before = turtle.getItemCount(p_To)
    turtle.select(p_From)
    turtle.transferTo(p_To, p_Count)
    return turtle.getItemCount(p_To) - s_Before
end

function OnCraft(p_ID, p_Message)
    return RunJob("Craft", p_Message.data, {status = "crafting", travel = false}, function(d)
        if not IsCrafter() then
            -- Named, not generic: "cannot craft" sends someone looking for a software bug, when
            -- the actual fix is to put a crafting table on a turtle.
            error("this drone has no crafting table upgrade -- it physically cannot craft", 0)
        end

        local s_Item  = d.item
        local s_Runs  = math.max(1, tonumber(d.runs) or 1)
        local s_Grid  = d.grid                       -- may be nil for shapeless recipes
        local s_Inputs= d.inputs or {}
        if s_Item == nil then error("no item to craft", 0) end

        -- 1. Ask storage to put the ingredients somewhere we can reach.
        local s_Req = {}
        for name, per in pairs(s_Inputs) do
            s_Req[#s_Req + 1] = {name = name, count = per * s_Runs}
        end
        if #s_Req == 0 then error("recipe has no inputs", 0) end

        local s_Hand = PowNet.sendAndWaitForResponse("StorageMan",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Provide", {items = s_Req}),
            PowNet.SERVER_PROTOCOL)
        if type(s_Hand) ~= "table" or s_Hand.pos == nil then
            error("storage would not hand over ingredients", 0)
        end
        if s_Hand.complete == false then
            -- Stop rather than craft a partial batch. A short craft silently produces fewer items
            -- than the plan counted on, and the shortfall surfaces much later as a mystery.
            local s_Miss = ""
            for _, m in ipairs(s_Hand.short or {}) do s_Miss = s_Miss .. m.name .. " x" .. m.count .. " " end
            error("short of " .. s_Miss, 0)
        end

        -- 2. Go to the pickup chest and face it.
        if pgps.moveTo(s_Hand.pos.x, s_Hand.pos.y + 1, s_Hand.pos.z) == false then
            error("could not reach the pickup chest", 0)
        end

        -- 3. Load the grid. Layout IS the recipe: turtle.craft reads the slots and infers the
        --    result, so a misplaced ingredient yields the wrong item or nothing at all.
        emptyInventory()                   -- leftovers change what the grid means

        -- How many of each kind this batch needs, so staging stops as soon as it has enough
        -- instead of pulling the whole store through the turtle.
        local s_Wanted = {}
        for name, per in pairs(s_Inputs) do s_Wanted[name] = per * s_Runs end
        local s_Stage, s_StageErr = stageFromChest(s_Wanted)
        if s_Stage == nil then error(s_StageErr, 0) end
        do
            local s_Rep = ""
            for n, sl in pairs(s_Stage) do
                s_Rep = s_Rep .. n .. "@" .. sl .. "x" .. turtle.getItemCount(sl) .. " "
            end
            trace("craft staged: [" .. s_Rep .. "] wanted " ..
                  (function() local t = "" for n, c in pairs(s_Wanted) do t = t .. n .. "x" .. c .. " " end return t end)())
        end

        if s_Grid then
            for i = 1, 9 do
                local want = s_Grid[i]
                -- textutils/JSON turns a nil hole into false or a sentinel depending on transport,
                -- so an empty cell is anything that is not a string.
                if type(want) == "string" then
                    local n = dealInto(s_Stage[want], CRAFT_SLOTS[i], s_Runs)
                    if n < s_Runs then
                        error(("only %d/%d of %s reached slot %d"):format(n, s_Runs, want, i), 0)
                    end
                end
            end
        else
            local s_At = 1
            for name, per in pairs(s_Inputs) do
                local n = dealInto(s_Stage[name], CRAFT_SLOTS[s_At], per * s_Runs)
                if n < per * s_Runs then error("short of " .. name, 0) end
                s_At = s_At + 1
            end
        end

        -- 4. Craft, then put the result away.
        local s_Ok, s_Err = turtle.craft()
        if not s_Ok then
            error("craft refused: " .. tostring(s_Err) ..
                  " (layout wrong, or this is not a valid recipe)", 0)
        end

        local s_Made = 0
        for i = 1, 16 do s_Made = s_Made + turtle.getItemCount(i) end
        Deposit()
        return {message = ("crafted %s x%d"):format(s_Item, s_Runs), item = s_Item, runs = s_Runs,
                held = s_Made}
    end)
end


-- BRANCH MINING: how the fleet finds ore it has never seen.
--
-- Everything before this could only mine ore the map already knew about, and the map could only
-- learn about ore a SCOUT had scanned. That loop cannot close for iron: a turtle carries two
-- upgrades and the wireless modem takes one, so a scout has a geo scanner and no pickaxe while a
-- miner has a pickaxe and cannot see through rock. The scanner reaches 8 blocks, so surveying the
-- surface at y=85 can never reveal iron at y=30. "We are short of iron" was therefore unanswerable
-- by any combination of drones -- not because of a bug, but because nothing in the system ever went
-- underground to look.
--
-- A miner does not need to see through rock. It needs to EXPOSE rock and look at what it exposed,
-- which is exactly what a human does: sink a shaft, drive tunnels, and check the faces you open.
--
-- Cost model, because every move counts: inspecting forward, up and down costs nothing extra --
-- the turtle is already facing forward and inspectUp/inspectDown need no turning. Checking the
-- side walls needs two turns plus two back, four wasted steps per block, so it is done on an
-- interval instead. Ore missed in a side wall is picked up by the neighbouring branch.
local ORE_HINTS = {"_ore", "ancient_debris", "raw_"}

local function looksValuable(p_Name)
    if p_Name == nil then return false end
    if IsProtected(p_Name) then return false end
    for _, hint in ipairs(ORE_HINTS) do
        if string.find(p_Name, hint, 1, true) then return true end
    end
    return false
end

-- Record what we just looked at, so exposing a face TEACHES THE MAP even when we leave the block
-- alone. A tunnel is a survey the fleet paid for anyway; throwing the observations away would mean
-- digging the same ground again later to learn the same thing.
local function noteFace(p_Dx, p_Dy, p_Dz, p_Ok, p_Blk)
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return end
    local idx = (cx + p_Dx) .. ":" .. (cy + p_Dy) .. ":" .. (cz + p_Dz)
    if p_Ok and p_Blk then
        pgps.noteObservation(idx, 1, {true, {name = p_Blk.name}})
    else
        pgps.noteObservation(idx, 0)
    end
end

--- Look at the three faces a turtle can see without turning, and take anything worth taking.
local function workFace(p_Inspect, p_Dig, p_Dx, p_Dy, p_Dz)
    local s_Ok, s_Blk = p_Inspect()
    noteFace(p_Dx, p_Dy, p_Dz, s_Ok, s_Blk)
    if s_Ok and s_Blk and looksValuable(s_Blk.name) then
        if p_Dig() then return 1 end
    end
    return 0
end

function OnMine(p_ID, p_Message)
    return RunJob("Mine", p_Message.data, {status = "mining", travel = false}, function(d)
        local s_Depth   = tonumber(d.depth)    or 35    -- target Y for the grid
        local s_Length  = tonumber(d.length)   or 32    -- how far each tunnel runs
        local s_Lines   = tonumber(d.branches) or 4     -- tunnels in the grid
        -- SPACED FOR THE SCANNER, not for the pickaxe.
        --
        -- A geo scanner reaches 8 blocks, so tunnels 16 apart let the scan spheres tile the rock
        -- between them with nothing missed. Digging densely to find ore by touch is the expensive
        -- way round: cut a sparse grid, then let one scan read thousands of cells of the rock it
        -- opens up. The tunnels are scaffolding for the SCOUT, not the search itself.
        local s_Spacing = tonumber(d.spacing)  or 16
        local s_WallEvery = tonumber(d.wallEvery) or 6

        local s_Got, s_Steps = 0, 0

        -- Cut a tunnel a person can walk down: floor, plus two blocks of air.
        --
        -- The turtle rides at floor level and clears the block ahead and the one above it before
        -- stepping in. That is two digs per block instead of one, and digs are FREE -- they cost
        -- time, not fuel -- while the move is what actually costs. So headroom is nearly free, and
        -- a one-high tunnel nobody can walk through is a worse artefact for the same fuel.
        local function boreForward()
            local s_Ore = 0
            s_Ore = s_Ore + workFace(turtle.inspect,   DigForward, 0, 0, 0)
            if not DigForward() then return nil end
            s_Ore = s_Ore + workFace(turtle.inspectUp, DigUp,      0, 1, 0)
            DigUp()                                   -- headroom, whether or not it held ore
            if not pgps.forward() then return nil end
            -- Now standing in the new block: clear the head-height block ahead of us too, so the
            -- corridor stays two high the whole way rather than only where it happened to be air.
            s_Ore = s_Ore + workFace(turtle.inspectUp, DigUp, 0, 1, 0)
            DigUp()
            return s_Ore
        end

        -- 1. Sink the access shaft.
        if d.pos and d.pos.x then
            if pgps.moveTo(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z)) == false then
                error("could not reach the shaft head", 0)
            end
        end

        local _, cy = pgps.getCachedPosition()
        while cy and cy > s_Depth do
            if not executing then break end
            if not depositIfFull() then break end
            s_Got = s_Got + workFace(turtle.inspectDown, DigDown, 0, -1, 0)
            if not DigDown() then break end
            if not pgps.down() then break end
            _, cy = pgps.getCachedPosition()
            s_Steps = s_Steps + 1
        end

        -- 2. Cut the grid, serpentine, so no leg is walked empty.
        for line = 1, s_Lines do
            if not executing then break end

            for step = 1, s_Length do
                if not executing then break end
                if not depositIfFull() then break end

                local s_Ore = boreForward()
                if s_Ore == nil then break end
                s_Got = s_Got + s_Ore
                s_Steps = s_Steps + 1

                s_Got = s_Got + workFace(turtle.inspectDown, DigDown, 0, -1, 0)

                -- Side walls cost two turns each way. Occasional, because the SCOUT is what is
                -- meant to see through these walls -- this is only a cheap second opinion.
                if step % s_WallEvery == 0 then
                    pgps.turnRight()
                    s_Got = s_Got + workFace(turtle.inspect, DigForward, 0, 0, 0)
                    pgps.turnLeft() pgps.turnLeft()
                    s_Got = s_Got + workFace(turtle.inspect, DigForward, 0, 0, 0)
                    pgps.turnRight()
                end
            end

            -- Step across to the next line of the grid, cutting the crosscut as we go so the whole
            -- thing stays connected and walkable rather than being a set of dead-end corridors.
            if line < s_Lines then
                pgps.turnRight()
                for _ = 1, s_Spacing do
                    if not executing then break end
                    if boreForward() == nil then break end
                    s_Steps = s_Steps + 1
                end
                pgps.turnRight()
                -- Face back along the next line; the serpentine reverses direction each pass.
                s_Length = s_Length          -- unchanged; direction comes from the two turns above
            end
        end

        UploadWorld()
        return {message = ("cut %d tunnel blocks at y=%d, took %d ore")
                    :format(s_Steps, s_Depth, s_Got),
                got = s_Got, steps = s_Steps, depth = s_Depth}
    end)
end


-- BUILDING: turning material into infrastructure.
--
-- The fleet could dig, carry, smelt and craft, and everything it made went straight into a chest.
-- Nothing could PLACE a block, so the settlement could accumulate chests forever and never own a
-- single structure -- no field caches, no smelter banks, nothing that makes the next job cheaper.
--
-- The layout arrives as data rather than being computed here on purpose. HQ has already costed it,
-- checked it against the plot registry, and ordered the blocks bottom-up; a builder that worked out
-- its own geometry could not have any of that checked before it started swinging.

--- Find a slot holding p_Name and select it.
local function selectItem(p_Name)
    for i = 1, 16 do
        local d = turtle.getItemDetail(i)
        if d and d.name == p_Name then
            turtle.select(i)
            return true
        end
    end
    return false
end

function OnBuild(p_ID, p_Message)
    return RunJob("Build", p_Message.data, {status = "building", travel = false}, function(d)
        local s_Origin = d.origin
        local s_Blocks = d.blocks
        if type(s_Origin) ~= "table" or s_Origin.x == nil then error("no origin", 0) end
        if type(s_Blocks) ~= "table" or #s_Blocks == 0 then error("nothing to build", 0) end

        -- 1. Collect the materials. Same handover chest crafting uses.
        local s_Need = {}
        for _, b in ipairs(s_Blocks) do
            if b.item then s_Need[b.item] = (s_Need[b.item] or 0) + 1 end
        end
        local s_Req = {}
        for name, count in pairs(s_Need) do s_Req[#s_Req + 1] = {name = name, count = count} end

        local s_Hand = PowNet.sendAndWaitForResponse("StorageMan",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Provide", {items = s_Req}),
            PowNet.SERVER_PROTOCOL, 8)
        if type(s_Hand) ~= "table" or s_Hand.pos == nil then
            error("storage would not hand over materials", 0)
        end
        if s_Hand.complete == false then
            local s_Miss = ""
            for _, m in ipairs(s_Hand.short or {}) do s_Miss = s_Miss .. m.name .. " x" .. m.count .. " " end
            error("short of " .. s_Miss, 0)
        end

        if pgps.moveTo(s_Hand.pos.x, s_Hand.pos.y + 1, s_Hand.pos.z) == false then
            error("could not reach the pickup chest", 0)
        end
        emptyInventory()
        local s_Stage, s_StageErr = stageFromChest(s_Need)
        if s_Stage == nil then error(s_StageErr, 0) end

        -- Materials live in the staging slots; spread them into the main inventory so placeDown
        -- has something in the selected slot regardless of which kind is wanted next.
        for _, slot in ipairs(STAGE_SLOTS) do
            local dd = turtle.getItemDetail(slot)
            if dd then
                turtle.select(slot)
                for i = 1, 12 do
                    if turtle.getItemCount(i) == 0 then turtle.transferTo(i) break end
                end
            end
        end

        -- 2. Place. The drone stands ABOVE each target and places downwards, which is the one
        --    placement that needs no knowledge of which way it is facing.
        local s_Placed, s_Skipped = 0, 0
        for _, b in ipairs(s_Blocks) do
            if not executing then break end
            local bx = s_Origin.x + (tonumber(b.dx) or 0)
            local by = s_Origin.y + (tonumber(b.dy) or 0)
            local bz = s_Origin.z + (tonumber(b.dz) or 0)

            if pgps.moveTo(bx, by + 1, bz) == false then
                s_Skipped = s_Skipped + 1
            else
                -- Something already here. Leave it: overwriting is how a build eats whatever was
                -- standing on the site, and the plot check cannot see blocks that arrived after it
                -- ran. Refusing costs one block; the alternative destroyed a drone once already.
                local s_Occupied, s_What = turtle.inspectDown()
                if s_Occupied then
                    if s_What and s_What.name == b.item then
                        s_Placed = s_Placed + 1        -- already correct; count it as done
                    else
                        s_Skipped = s_Skipped + 1
                    end
                elseif not selectItem(b.item) then
                    error("ran out of " .. tostring(b.item) .. " partway through", 0)
                elseif turtle.placeDown() then
                    s_Placed = s_Placed + 1
                    pgps.noteObservation(bx .. ":" .. by .. ":" .. bz, 1, {true, {name = b.item}})
                else
                    s_Skipped = s_Skipped + 1
                end
            end
        end

        Deposit()          -- leftovers go back rather than riding around in a turtle
        UploadWorld()
        return {message = ("built %d of %d blocks (%d skipped)")
                    :format(s_Placed, #s_Blocks, s_Skipped),
                placed = s_Placed, skipped = s_Skipped, total = #s_Blocks}
    end)
end

function OnLumber(p_ID, p_Message)
    return RunJob("Lumber", p_Message.data, {status = "logging"}, function(d)
        local s_W = tonumber(d.w) or 8
        local s_L = tonumber(d.l) or 8
        local s_Logs, s_Trees = 0, 0

        Serpentine(s_W, s_L, function()
            if not depositIfFull() then return false end
            local ok, blk = turtle.inspect()
            if ok and isLog(blk.name) then
                local n = fellTree()
                if n > 0 then s_Trees = s_Trees + 1 s_Logs = s_Logs + n end
            elseif ok and isLeaf(blk.name) then
                DigForward()
                pgps.forward()
            elseif not stepForward(2) then
                return false
            end
        end, function() return stepForward(2) end)

        return {message = ("felled %d trees, %d logs"):format(s_Trees, s_Logs),
                trees = s_Trees, logs = s_Logs}
    end)
end

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
    -- ALWAYS CLEAR, even when nothing is running.
    --
    -- This used to refuse whenever `executing` was false -- which is precisely the state abort is
    -- most needed for. A drone can hold a stale status with no job behind it: a body that ended
    -- abnormally, or a task cancelled server-side that never reached the machine. It then reports
    -- "working" for ever, TaskMan never offers it anything because it is not idle, and the supply
    -- loop correctly concludes there is nobody free and does nothing at all.
    --
    -- Two drones sat like that and the whole fleet looked like it had stopped working, while every
    -- component was behaving exactly as designed.
    local s_Was = executing
    print("Aborting (was executing: " .. tostring(s_Was) .. ")")
    -- Clear the flag as well as breaking pgps. BreakExec stops a pgps path mid-flight, but the
    -- survey loop is our own and only watches `executing` -- without this an abort would stop the
    -- current move and the lawnmower would calmly carry on to the next cell. This runs on the
    -- server thread, which is precisely why it can interrupt work happening on the drone thread.
    executing = false
    pgps.BreakExec()
    m_Status = "idle"
    m_Job = nil
    pcall(saveResume)
    -- Say so immediately rather than waiting up to 30s for the next beat: the whole point is to
    -- get this drone back into the pool.
    pcall(SendHeartBeat)
    return true, s_Was and "Aborted" or "was already idle; stale status cleared"
end


function OnStartTask(p_ID, p_Message)

end

function OnAbortTask(p_ID, p_Message)

end



local m_DroneEvents = {
    Reboot = {
        func = OnReboot,
    },
    -- The verb the whole recipe graph is for. Only a turtle with a crafting-table upgrade can
    -- serve it; OnCraft says so plainly rather than failing somewhere less obvious.
    Craft = {
        func = OnCraft,
    },
    -- Prospecting. The only job that can find ore nobody has scanned.
    Mine = {
        func = OnMine,
    },
    -- Anchor here and answer GPS pings, so a rescue party can extend coverage to a drone that has
    -- lost its position.
    Relay = {
        func = OnRelay,
    },
    -- Placing blocks: the difference between a fleet that accumulates chests and one that owns
    -- infrastructure.
    Build = {
        func = OnBuild,
    },
    Ping = {
        func = OnPing,
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
    },
    Lumber = {
        func = OnLumber,
    },
    Gather = {
        func = OnGather,
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

-- Become a GPS host on command, whatever role this drone is.
--
-- The automatic relay only runs on loaders, which is right for standing coverage and useless for a
-- rescue: a fix needs FOUR hosts, so extending the constellation to somewhere it does not reach
-- takes a party, not one chunk loader. This lets every member of a rescue party anchor itself and
-- answer pings, which is the actual mechanism by which a stranded drone gets its position back.
function OnRelay(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Modem = peripheral.find("modem")
    if s_Modem == nil then return false, "no modem" end

    if d.on == false then
        pcall(s_Modem.close, gps.CHANNEL_GPS)
        m_Hosting, m_HostPos = false, nil
        return true, {hosting = false}
    end

    -- Anchor on a REAL fix before broadcasting. Publishing a dead-reckoned position would hand the
    -- casualty a confidently wrong fix, which is worse than no fix at all -- it would navigate on it.
    local fx, fy, fz = gps.locate(4, false)
    if fx == nil then
        return false, "cannot relay without a fix of my own"
    end
    s_Modem.open(gps.CHANNEL_GPS)
    m_Hosting = true
    m_HostPos = {x = fx, y = fy, z = fz}
    print("relaying GPS at " .. fx .. "," .. fy .. "," .. fz)
    SendHeartBeat()
    return true, {hosting = true, pos = m_HostPos}
end

-- THE FLEET AS A MESH.
--
-- The constellation is four computers and a modem reaches 64 blocks below y=192, so GPS is a
-- 64-block bubble around the base -- and a drone needs FOUR hosts to fix at all. Every drone that
-- flies past that edge loses its position, and a drone with no position cannot navigate, so it
-- cannot get back. That is how two of them stranded.
--
-- But the fleet is already a set of machines with wireless modems that mostly know where they are.
-- Any drone parked with a confirmed fix can answer pings exactly as a host computer does, so
-- coverage stops being a fixed bubble and becomes something the fleet EXTENDS by being spread out.
-- A chain of parked drones reaches anywhere one of them can reach.
--
-- This was already written and limited to loaders, which is one drone. Every idle drone can do it.
--
-- THE THING THAT MUST NOT HAPPEN: a relay publishing a position it is not sure of. GPS has no way
-- to say "roughly" -- a host that answers with a wrong position hands every drone in range a
-- confidently wrong fix, and they will navigate on it. D4 is sitting 24 blocks from where it
-- believes it is right now; if it relayed that, it would corrupt the position of every drone that
-- trusted it. So a relay proves itself against a REAL fix before hosting, re-proves it on every
-- cycle, and stands down the instant it moves, drifts, or loses the fix.
local RELAY_DRIFT_LIMIT = 1     -- blocks; a host that has moved at all is no longer where it says

local function gpsRelay()
    while true do
        os.sleep(10)

        local s_Eligible = (m_Status == "idle") and not executing
        local s_Modem = peripheral.find("modem")

        if s_Eligible and s_Modem then
            -- Anchor on a fix of our OWN, every cycle. Dead reckoning is good enough to navigate
            -- with and never good enough to publish.
            local fx, fy, fz = gps.locate(5, false)

            if fx == nil then
                trace("relay: no fix of my own (status=" .. tostring(m_Status) .. ")")
                if m_Hosting then
                    pcall(s_Modem.close, gps.CHANNEL_GPS)
                    m_Hosting, m_HostPos = false, nil
                    print("GPS relay stopped (lost my own fix)")
                end
            elseif m_Hosting and m_HostPos then
                -- Still here? A host that has drifted is worse than no host at all.
                local s_Drift = math.abs(fx - m_HostPos.x) + math.abs(fy - m_HostPos.y)
                             + math.abs(fz - m_HostPos.z)
                if s_Drift > RELAY_DRIFT_LIMIT then
                    m_HostPos = {x = fx, y = fy, z = fz}
                    print("GPS relay re-anchored (moved " .. s_Drift .. ")")
                end
            else
                -- A RELAY MUST BE ABLE TO CHECK ITS OWN FIX.
                --
                -- Anchoring on a real gps.locate is not enough. The fix itself is computed from
                -- whatever hosts answered, and if any of those were relays publishing a bad
                -- position, the result is wrong -- confidently. A drone that then hosts it turns
                -- one bad position into a spreading one.
                --
                -- D4 did exactly this: with no position of its own it accepted a fix of
                -- -138,75,-51 while sitting at -80,85,12, and began broadcasting it. Eighty-five
                -- blocks of error, offered to every drone in range as fact.
                --
                -- So a relay must have a position it already believed, and the fix must agree with
                -- it. A drone that does not know where it is has nothing to check against and is
                -- therefore exactly the wrong machine to be a reference for anyone else.
                local cx, cy, cz = pgps.getCachedPosition()
                if cx == nil then
                    trace("relay: refusing to host -- no position of my own to check the fix against")
                elseif (math.abs(fx - cx) + math.abs(fy - cy) + math.abs(fz - cz)) > 8 then
                    trace(("relay: refusing to host -- fix %d,%d,%d disagrees with my position %d,%d,%d")
                        :format(fx, fy, fz, cx, cy, cz))
                else
                s_Modem.open(gps.CHANNEL_GPS)
                m_Hosting = true
                m_HostPos = {x = fx, y = fy, z = fz}
                trace(("relay: hosting at %d,%d,%d"):format(fx, fy, fz))
                print("GPS relay hosting at " .. fx .. "," .. fy .. "," .. fz)
                SendHeartBeat()
                end
            end

        elseif not s_Eligible then
            trace("relay: not eligible (status=" .. tostring(m_Status) ..
                  " executing=" .. tostring(executing) .. " modem=" .. tostring(s_Modem ~= nil) .. ")")
        end
        if m_Hosting and not s_Eligible then
            -- About to move, or busy: stop answering rather than lie.
            if s_Modem then pcall(s_Modem.close, gps.CHANNEL_GPS) end
            m_Hosting, m_HostPos = false, nil
            print("GPS relay stopped (working)")
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
-- Consecutive unanswered beats before we conclude the link is gone rather than merely busy.
-- Three, because one missed reply is normal (DroneMan servicing another call) and waiting for
-- three costs at most a minute while avoiding a drone that abandons its job over a hiccup.
local LINK_LOST_AFTER = 5
local m_Missed = 0

local function heartbeat()
    while true do
        os.sleep(HEARTBEAT_SECONDS)

        -- KEEP TRYING TO WORK OUT WHERE WE ARE.
        --
        -- Init establishes position once. A drone that boots while GPS happens to be unreachable
        -- therefore has NO position for the rest of its life -- it cannot navigate, so it cannot
        -- move somewhere with coverage, so it never gets one. It still heartbeats, so DroneMan goes
        -- on reporting the last position it ever knew and the drone looks fine while being unable
        -- to accept any work at all. D3 sat like that with all four GPS hosts up and in range.
        -- Heading can be missing even when position is not, and a drone without it cannot move at
        -- all -- see ensureHeading. Cheap to check, fatal to ignore.
        do
            local _, _, _, s_Dir = pgps.getCachedPosition()
            if s_Dir == nil and pgps.getCachedPosition() ~= nil then
                if pgps.ensureHeading() then SendHeartBeat() end
            end
        end

        if pgps.getCachedPosition() == nil then
            local ok = pgps.verifyPosition()
            if ok then
                print("position re-established")
                SendHeartBeat()
            elseif pgps.trailLength() > 0 then
                -- WALK BACK ALONG WHERE WE CAME FROM.
                --
                -- A drone with no position cannot navigate ANYWHERE -- it has no idea where it is,
                -- so it cannot compute a route out of the dead zone it is sitting in. The one thing
                -- it still knows is the sequence of moves it made getting here, and the coverage it
                -- lost was working somewhere back along that trail.
                --
                -- This is the only escape that does not require knowing your position, which is
                -- exactly the thing that is missing.
                print("no position -- retracing " .. pgps.trailLength() .. " crumbs to find coverage")
                m_Status = "recovering"
                pgps.setRecovering(true)
                local s_Steps = 0
                while s_Steps < 80 do
                    local bx, by, bz = pgps.trailBack()
                    if bx == nil then break end
                    s_Steps = s_Steps + 1
                    pgps.flyTo(bx, by, bz, 24)
                    if pgps.verifyPosition() then
                        print("coverage regained after " .. s_Steps .. " crumbs")
                        break
                    end
                end
                pgps.setRecovering(false)
                m_Status = "idle"
                SendHeartBeat()
            else
                -- NO POSITION AND NO TRAIL: search for coverage.
                --
                -- Breadcrumbs live in memory, so a drone that reboots while stranded has nothing to
                -- retrace and cannot compute a route either -- it does not know where it is. The
                -- only move left is the one a real robot would make: go somewhere, anywhere, and
                -- keep asking. Coverage is a 64-block bubble, so a drone that fell out of it is
                -- usually just past the edge and a short walk gets back in.
                --
                -- Bounded and reported, because a machine wandering blind is only acceptable as a
                -- deliberate, finite last resort.
                print("no position and no trail -- searching for GPS coverage")
                m_Status = "recovering"
                pgps.setRecovering(true)
                local s_Found = false
                for leg = 1, 4 do
                    if s_Found then break end
                    for step = 1, 16 do
                        if not pgps.forward() then break end
                        if step % 4 == 0 and pgps.verifyPosition() then
                            print("coverage found after " .. ((leg - 1) * 16 + step) .. " blocks")
                            s_Found = true
                            break
                        end
                    end
                    if not s_Found then pgps.turnRight() end
                end
                pgps.setRecovering(false)
                m_Status = "idle"
                if s_Found then
                    SendHeartBeat()
                else
                    -- Loud, because from outside this is indistinguishable from a drone that is
                    -- simply idle, and it is the reason it will refuse every job it is offered.
                    Distress("no position", "searched for coverage and found none; needs a relay")
                end
            end
        end
        if SendHeartBeat() then
            m_Missed = 0
        else
            m_Missed = m_Missed + 1
            print("no answer from DroneMan (" .. m_Missed .. "/" .. LINK_LOST_AFTER .. ")")
            if m_Missed >= LINK_LOST_AFTER then
                m_Missed = 0
                -- IS THE RADIO ACTUALLY DEAD, OR IS DRONEMAN JUST BUSY?
                --
                -- These look identical from here and demand opposite responses. Unanswered
                -- heartbeats alone are not evidence of being out of range: DroneMan answers the
                -- whole fleet from a single loop, and treating slowness as loss made drones sitting
                -- ON THEIR DOCKS abandon their work and declare themselves stranded -- which is
                -- worse than the problem, because it takes healthy drones out of service.
                --
                -- A lookup is the discriminator. It is a broadcast on the same radio: if anything
                -- answers, the link is fine and the silence is congestion.
                if PowNet.Lookup("DroneMan") ~= nil then
                    print("DroneMan is slow, not gone -- staying put")
                else
                    -- Stop whatever we are doing first. Carrying on digging while out of contact is
                    -- how a drone ends up deep in unmapped ground with nobody able to reach it.
                    executing = false
                    RecoverLink()
                end
            end
        end
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