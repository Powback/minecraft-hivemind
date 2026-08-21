-- This library provide high level turtle movement functions.
--
-- Before being able to use them, you should start the GPS with egps.startGPS()
--    then get your current location with egps.setLocationFromGPS().
-- egps.forward(), egps.back(), egps.up(), egps.down(), egps.turnLeft(), egps.turnRight()
--    replace the standard turtle functions.
-- If you need to use the standard functions, you
--    should call egps.setLocationFromGPS() again before using any egps functions.

-- Gist at: https://gist.github.com/SquidLord/4741746

-- The MIT License (MIT)

-- Copyright (c) 2012 Alexander Williams

-- Permission is hereby granted, free of charge, to anexclusionsy person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--[[

-------------------MODIFIED BY 1wsx10---------------------------
 instructions:
 1. install it as an api
 2. look at comments above each function to see what they do
 3. write code
 4. complain about shit instructions





 recently added: support for LAMA
 exclusion zone file - turtle wont pathfind through an excluded block.
 exclusions are similar to waypoints but instead of name it has index "x:y:z" and does not store direction
 a_star has boolean "priority" - will ignore exclusion zone
--------------------------------------------------------------

-----------------MODIFIED BY POWBACK ---------------------------
 Modified this modification to add PowNet support for eGPS.
 It features a client/server design, where the server sends the path the client should use,
 and the client updates the server with it's mapping data.
 This means that the server can sync mapping data across all turtles.
 Resulting in a (potentially) really fast and efficient pathfinding method.
 Blocked paths will automatically trigger the server to update existing data, so future visitors can get there fast.

Functions:
    RequestPath(x,y,z) // Returns paths[]
        runs standard A* method

    RequestPath(x,y,z, {pathdata: updated local pathdata, with the !updated! paths })
        returns same as PrequestPath(x,y,z)

    SavePath(pathData) // void
        Turtle completed move, update age on the path the turtle took.


--------------------------------------------------------------

--]]

-- OPERATING BOUNDS
--
-- A turtle that leaves the loaded region does not fail -- it stops ticking, mid-task, and is
-- simply gone. It reports nothing, appears in no dump, and looks destroyed. A scout hop-scanning
-- in 16-block steps walked 35 blocks past the edge and was lost until the region was widened.
--
-- Force-loading more chunks treats the symptom. The fix belongs here, in the movement layer,
-- because this is the only place that sees every single step -- moveTo, a survey lawnmower, a dig
-- serpentine and a manual nudge all funnel through forward/up/down.
--
-- No bounds set means unrestricted, so this is inert until someone supplies them.
-- A LIST of boxes, not one. Coverage is the static force-loaded region PLUS a box around every
-- parked chunk-loader drone -- so sending a loader somewhere genuinely extends where the fleet may
-- go, and recalling it genuinely shrinks it. One box could never express that.
-- Two independent coverages, and a drone needs BOTH.
--
--   chunks : is this ground ticking?  Outside it the turtle simply stops -- no error, no dump
--            entry, indistinguishable from having been destroyed.
--   gps    : can it work out where it is?  Outside it the turtle ticks perfectly well and cannot
--            navigate, because setLocationFromGPS needs four hosts in modem range.
--
-- They are very different sizes. With modem_range 64 and modem_high_altitude_range 384, hosts at
-- y=95 reach roughly 196 blocks; a chunky turtle covers its own chunk, 16. So GPS is the cheap
-- wide bubble and chunk loading is the expensive island inside it -- which is why this is an
-- INTERSECTION and not a union. Being in one without the other is useless.
local m_Chunks, m_Gps

local function inAny(p_List, x, y, z)
    if p_List == nil then return true end          -- unspecified means unrestricted
    for _, b in ipairs(p_List) do
        if x >= b.minx and x <= b.maxx
           and y >= b.miny and y <= b.maxy
           and z >= b.minz and z <= b.maxz then
            return true
        end
    end
    return false
end

function setBounds(p_B)
    if p_B == nil then m_Chunks, m_Gps = nil, nil return end
    if p_B.chunks or p_B.gps then
        m_Chunks, m_Gps = p_B.chunks, p_B.gps
    else
        -- A bare box or list still means "chunk coverage", so older callers keep working.
        m_Chunks = p_B.minx and {p_B} or p_B
        m_Gps = nil
    end
    print(("coverage: %d chunk region(s), %d gps region(s)"):format(
        m_Chunks and #m_Chunks or 0, m_Gps and #m_Gps or 0))
end

function getBounds() return {chunks = m_Chunks, gps = m_Gps} end

function inBounds(x, y, z)
    return inAny(m_Chunks, x, y, z) and inAny(m_Gps, x, y, z)
end

-- Which of the two refused, so the fix is obvious rather than guessed at.
function boundsReason(x, y, z)
    if not inAny(m_Chunks, x, y, z) then return "unloaded chunk" end
    if not inAny(m_Gps, x, y, z)    then return "no gps coverage" end
    return nil
end

-- How many refusals we have made, so a caller can tell "blocked by terrain" from "blocked by
-- policy" -- they look identical otherwise and lead to opposite fixes.
m_BoundsStops = 0
function boundsStops() return m_BoundsStops end

-- Cache of the current turtle position and direction
local cachedX, cachedY, cachedZ, cachedDir

-- Read the cached position WITHOUT moving.
--
-- setLocationFromGPS is the only other way to answer "where am I", and it deduces heading by
-- stepping the turtle forward and back again. That is fine once at boot and ruinous on a timer:
-- a periodic heartbeat built on it would walk every docked drone out of its slot and back,
-- forever, burning fuel to re-derive a heading that has not changed. It is very likely why the
-- heartbeat was only ever sent once.
--
-- The cache is already maintained by every move and turn in this file, so the position is known
-- without asking anything. Returns nils before the first fix, so callers must handle that.
function getCachedPosition()
    return cachedX, cachedY, cachedZ, cachedDir
end

-- Observations made since the last call, and then forgotten.
--
-- detectAll() has always written what the turtle sees into cachedWorld/cachedWorldDetail, and
-- MapServer has always had handlers to merge exactly that. Nothing ever carried it across: no
-- code anywhere sent the data, so every drone accumulated a private map that died with it and
-- the server's world stayed literally `{}`.
--
-- Deltas rather than the whole cache, because this goes over rednet on a timer: a drone that has
-- surveyed for an hour holds thousands of entries, and re-serialising all of them every cycle
-- would cost more than the survey. Entries are handed over and dropped locally -- the server is
-- the map, the drone only needs enough to path with.
local pendingWorld, pendingDetail = {}, {}

function noteObservation(idx, solid, detail)
    pendingWorld[idx] = solid
    if detail ~= nil then pendingDetail[idx] = detail end
end

function takeWorldDelta()
    local w, d, n = pendingWorld, pendingDetail, 0
    for _ in pairs(w) do n = n + 1 end
    pendingWorld, pendingDetail = {}, {}
    return w, d, n
end

-- Directions
North, West, South, East, Up, Down = 0, 1, 2, 3, 4, 5
local shortNames = {[North] = "N", [West] = "W", [South] = "S",
                    [East] = "E", [Up] = "U", [Down] = "D" }
local deltas = {[North] = {0, 0, -1}, [West] = {-1, 0, 0}, [South] = {0, 0, 1},
                [East] = {1, 0, 0}, [Up] = {0, 1, 0}, [Down] = {0, -1, 0}}

-- cache world geometry
cachedWorld = {}
-- cached wrld with block names
cachedWorldDetail = {}




-- compatibility with LAMA
local isLama = false
if fs.isDir("/.lama") then
    isLama = true
    lama.overwrite() --replaces turtle.forward() etc. with lama.forward()
    print("lama detected, using lama movement...")
end

----------------------------------------
-- printWorld
--
-- function: for debugging, prints raw world data to screen
--

function printWorld()
    print(textutils.serialize(cachedWorld))
end



----------------------------------------TODO: worldDetail support
-- detectAll
--
-- function: Detect up, forward, down and writes it to cachedWorld
--

function detectAll()
    local F, U, D = deltas[cachedDir], deltas[Up], deltas[Down]
    local block, idx

    -- Every write is mirrored into the pending delta so it can be shipped to MapServer. Without
    -- this the observations only ever existed in this turtle's memory.
    idx = cachedX..":"..cachedY..":"..cachedZ
    cachedWorld[idx] = 0
    noteObservation(idx, 0)

    block = 0
    if turtle.detect()      then block = 1 end
    idx = (cachedX + F[1])..":"..(cachedY + F[2])..":"..(cachedZ + F[3])
    cachedWorld[idx] = block
    cachedWorldDetail[idx] = {turtle.inspect()}
    noteObservation(idx, block, cachedWorldDetail[idx])

    block = 0
    if turtle.detectUp()    then block = 1 end
    idx = (cachedX + U[1])..":"..(cachedY + U[2])..":"..(cachedZ + U[3])
    cachedWorld[idx] = block
    cachedWorldDetail[idx] = {turtle.inspectUp()}
    noteObservation(idx, block, cachedWorldDetail[idx])

    block = 0
    if turtle.detectDown()  then block = 1 end
    idx = (cachedX + D[1])..":"..(cachedY + D[2])..":"..(cachedZ + D[3])
    cachedWorld[idx] = block
    cachedWorldDetail[idx] = {turtle.inspectDown()}
    noteObservation(idx, block, cachedWorldDetail[idx])
end


-- POSITION CONFIRMATION
--
-- Everything a drone reports about the world is stamped with where the drone THINKS it is. That
-- belief is dead reckoning: it survives only as long as every move is counted correctly, and a
-- blocked move, a chunk unload or a reboot mid-step silently shifts it. Until now a drifted
-- position only produced a slightly wrong map, which pathing tolerated.
--
-- It is no longer harmless. Air observations now DELETE entries from the server's block index, so
-- a drone one block out of position deletes the wrong block -- and a deletion cannot be noticed
-- the way a bad addition can, because what it leaves behind is an absence. Four coal blocks that
-- are still in the ground were removed from the index exactly this way.
--
-- So: a cheap position-only fix (gps.locate does NOT move the turtle, unlike the direction-finding
-- in setLocationFromGPS), and destructive observations are only shipped while a recent fix agrees.
-- With no GPS the index simply stops being pruned, which is the old, stale-but-safe behaviour.
-- Stale can be corrected by looking again. Wrong cannot.
local m_LastFix   = nil
local m_Drift     = 0        -- how far off the last check found us; diagnostics
local m_Suppressed = 0       -- observations withheld for want of a fix
local FIX_MAX_AGE = 60       -- seconds

-- How far a drone may travel on belief alone before it has to prove where it is.
--
-- Not zero: gps.locate costs a round trip and calling it every single step would halve the fleet's
-- speed for no benefit over short hops. Not unbounded either, which is what cost us D3. 24 blocks
-- of undetected drift is what walking a long survey leg without a single confirmation buys.
--
-- These MUST be declared before any function that reads them. A Lua local is only visible to
-- closures created after its declaration; putting them lower down would silently bind fixStatus to
-- nil globals and report nothing while looking correct.
local MOVES_PER_FIX   = 16
local m_MovesSinceFix = 0
local m_NoFixStops    = 0

function verifyPosition()
    if not startGPS() then return nil, "no modem for gps" end
    local x, y, z = gps.locate(2, false)
    if x == nil then return nil, "no gps fix" end
    if cachedX ~= nil then
        m_Drift = math.abs(x - cachedX) + math.abs(y - cachedY) + math.abs(z - cachedZ)
        if m_Drift > 0 then
            print(("position corrected by %d: %d,%d,%d -> %d,%d,%d")
                :format(m_Drift, cachedX, cachedY, cachedZ, x, y, z))
        end
    end
    cachedX, cachedY, cachedZ = x, y, z
    m_LastFix = os.clock()
    return true, m_Drift
end

function positionVerified()
    return m_LastFix ~= nil and (os.clock() - m_LastFix) <= FIX_MAX_AGE
end

function fixStatus()
    return {verified = positionVerified(), drift = m_Drift, suppressed = m_Suppressed,
            movesSinceFix = m_MovesSinceFix, stalled = m_NoFixStops,
            ageSeconds = m_LastFix and (os.clock() - m_LastFix) or nil}
end

-- True if it is safe to take another step. Re-fixes when the budget runs out, and REFUSES when no
-- fix can be had -- a drone that stops inside the world is recoverable, one that wanders out of it
-- is not. That is the whole trade, and it is not close.
function requireFix()
    if m_MovesSinceFix < MOVES_PER_FIX and positionVerified() then
        m_MovesSinceFix = m_MovesSinceFix + 1
        return true
    end
    if verifyPosition() then
        m_MovesSinceFix = 1
        return true
    end
    m_NoFixStops = m_NoFixStops + 1
    return false
end

-- Record that the cell in p_Which ("forward" | "up" | "down") is now AIR.
--
-- Digging is the one way the world changes that the survey never learned about. detectAll only
-- reports what a drone is standing next to, and a gather job mines a whole vein without entering
-- most of it, so mined-out ore stayed in the server's index for ever and the supply loop kept
-- dispatching drones to coordinates that were already air. This is the observation that makes the
-- index self-correcting: the drone that removed the block is the one that reports it gone.
--
-- Must live below `deltas`, which is a local declared after noteObservation.
function noteCleared(p_Which)
    local d
    if p_Which == "up"        then d = deltas[Up]
    elseif p_Which == "down"  then d = deltas[Down]
    else                           d = deltas[cachedDir] end
    if d == nil then return nil end

    local idx = (cachedX + d[1])..":"..(cachedY + d[2])..":"..(cachedZ + d[3])
    -- Always update our OWN cache: pathing needs to know it just cleared a way through, and a
    -- wrong local cache costs at most a replan.
    cachedWorld[idx] = 0
    cachedWorldDetail[idx] = nil
    -- Only tell the SERVER while a recent fix agrees on where we are. See the note above.
    if positionVerified() then
        noteObservation(idx, 0)
    else
        m_Suppressed = m_Suppressed + 1
    end
    return idx
end

----------------------------------------
-- forward
--
-- function: Move the turtle forward if possible and put the result in cache
-- return: boolean "success"
--

function forward()
    -- A bounds check is only as good as the position it is checking.
    --
    -- D3 was found 24 blocks OUTSIDE the force-loaded region, frozen and invisible to the server,
    -- while reporting a position exactly on the boundary. Nothing was wrong with inBounds: it was
    -- asked about coordinates the drone had drifted away from, answered honestly, and waved the
    -- drone across a line it had already crossed. Dead reckoning cannot be allowed to run
    -- indefinitely between confirmations -- the whole safety system is downstream of the position.
    if not requireFix() then
        return false, "position unverified"
    end

    -- Refuse rather than step out of the world we can operate in.
    if cachedDir and cachedX then
        local F = deltas[cachedDir]
        if not inBounds(cachedX + F[1], cachedY + F[2], cachedZ + F[3]) then
            m_BoundsStops = m_BoundsStops + 1
            return false, "out of bounds"
        end
    end
    local D = deltas[cachedDir]--if north, D = {0, 0, -1}
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]--adds corisponding delta to direction
    local idx_pos = x..":"..y..":"..z

    if turtle.forward() then
        cachedX, cachedY, cachedZ = x, y, z
        detectAll()
        return true
    else
        -- Something stopped us: record it and put it in the DELTA, not just the local cache.
        --
        -- A blocked move is a real observation -- often a better one than a scan, because it is
        -- ground truth from a drone that tried. Writing straight to cachedWorld kept it local
        -- until the next full SavePath, so other drones re-planned into the same wall.
        --
        -- 0.5 was used for "blocked but detect() says nothing" (a mob, another turtle). That reads
        -- back as neither 1 nor 0, i.e. UNKNOWN, throwing away the one thing we just learned. It
        -- is recorded as solid instead: transiently wrong if a mob wanders off, and a scan will
        -- correct it, which is much cheaper than pathing into it repeatedly.
        local s_Solid = 1
        cachedWorld[idx_pos] = s_Solid
        noteObservation(idx_pos, s_Solid, cachedWorldDetail[idx_pos])
        return false
    end
end

----------------------------------------
-- back
--
-- function: Move the turtle backward if possible and put the result in cache
-- return: boolean "success"
--

function back()
    local D = deltas[cachedDir]
    local x, y, z = cachedX - D[1], cachedY - D[2], cachedZ - D[3]
    local idx_pos = x..":"..y..":"..z

    if turtle.back() then
        cachedX, cachedY, cachedZ = x, y, z
        detectAll()
        return true
    else
        cachedWorld[idx_pos] = 0.5
        return false
    end
end

----------------------------------------
-- up
--
-- function: Move the turtle up if possible and put the result in cache
-- return: boolean "success"
--

function up()
    if cachedY and not inBounds(cachedX, cachedY + (1), cachedZ) then
        m_BoundsStops = m_BoundsStops + 1
        return false, "out of bounds"
    end
    local D = deltas[Up]
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]
    local idx_pos = x..":"..y..":"..z

    if turtle.up() then
        cachedX, cachedY, cachedZ = x, y, z
        detectAll()
        return true
    else
        cachedWorld[idx_pos] = (turtle.detectUp() and 1 or 0.5)
        return false
    end
end

----------------------------------------
-- down
--
-- function: Move the turtle down if possible and put the result in cache
-- return: boolean "success"
--

function down()
    if cachedY and not inBounds(cachedX, cachedY + (-1), cachedZ) then
        m_BoundsStops = m_BoundsStops + 1
        return false, "out of bounds"
    end
    local D = deltas[Down]
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]
    local idx_pos = x..":"..y..":"..z

    if turtle.down() then
        cachedX, cachedY, cachedZ = x, y, z
        detectAll()
        return true
    else
        detectAll()
        cachedWorld[idx_pos] = (turtle.detectDown() and 1 or 0.5)
        return false
    end
end

----------------------------------------
-- turnLeft
--
-- function: Turn the turtle to the left and put the result in cache
-- return: boolean "success"
--

function turnLeft()
    cachedDir = (cachedDir + 1) % 4
    turtle.turnLeft()
    detectAll()
    return true
end

----------------------------------------
-- turnRight
--
-- function: Turn the turtle to the right and put the result in cache
-- return: boolean "success"
--

function turnRight()
    cachedDir = (cachedDir + 3) % 4
    turtle.turnRight()
    detectAll()
    return true
end

----------------------------------------
-- turnTo
--
-- function: Turn the turtle to the choosen direction and put the result in cache
-- input: number _targetDir
-- return: boolean "success"
--

function turnTo(_targetDir)
    --print(string.format("target dir: {0}\ncachedDir: {1}", _targetDir, cachedDir))
    if _targetDir == cachedDir then
        return true
    elseif ((_targetDir - cachedDir + 4) % 4) == 1 then--moveTo caused exception
        turnLeft()
    elseif ((cachedDir - _targetDir + 4) % 4) == 1 then
        turnRight()
    else
        turnLeft()
        turnLeft()
    end
    return true
end

----------------------------------------
-- clearWorld
--
-- function: Clear the world cache
--

function clearWorld()
    cachedWorld = {}
    detectAll()
end

function BreakExec()
    breakExec = true
end
function StartExec()
    breakExec = false
end
-- moveTo
--
-- function: Move the turtle to the choosen coordinates in the world
-- input: X, Y, Z and direction of the goal
-- return: boolean "success"
--

function SavePath()

    local s_Request = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "UpdatePath", {id = os.getComputerID(), cachedWorld = cachedWorld, cachedWorldDetail = cachedWorldDetail})
    local s_Response = PowNet.sendAndWaitForResponse("MapServer", s_Request)
    cachedWorld = {}
end

-- BOUNDED. This loop used to be `while not there do replan; walk; end` with no way out, so a
-- target that cannot be reached -- one buried in solid rock, behind a claim, past the edge of the
-- map -- hung the drone permanently. It looked alive the whole time: heartbeats kept arriving from
-- their own coroutine, so DroneMan showed it "mining" at a fixed position with fuel that never
-- moved. D1 hung exactly this way on a Gather boundary candidate embedded in stone.
--
-- Give up on two conditions: too many replans, or several replans in a row that did not get us
-- closer. Distance is the honest progress signal -- a path can legitimately go sideways for a few
-- steps, so it takes repeated non-improvement to count as stuck.
local MOVE_MAX_REPLANS = 40
local MOVE_MAX_STALLS  = 4

function moveTo(_targetX, _targetY, _targetZ, _targetDir, changeDir, discover)
    changeDir = changeDir or false
    local s_Replans, s_Stalls, s_LastDist = 0, 0, nil
    while cachedX ~= _targetX or cachedY ~= _targetY or cachedZ ~= _targetZ do
        s_Replans = s_Replans + 1
        if s_Replans > MOVE_MAX_REPLANS then
            print("moveTo: giving up after " .. s_Replans .. " replans")
            return false, "unreachable"
        end
        local s_Dist = math.abs(cachedX - _targetX)
                     + math.abs(cachedY - _targetY)
                     + math.abs(cachedZ - _targetZ)
        if s_LastDist ~= nil and s_Dist >= s_LastDist then
            s_Stalls = s_Stalls + 1
            if s_Stalls >= MOVE_MAX_STALLS then
                print("moveTo: no progress toward " .. _targetX .. "," .. _targetY .. "," .. _targetZ)
                return false, "no progress"
            end
        else
            s_Stalls = 0
        end
        s_LastDist = s_Dist
        --TODO: NETWORK
        local s_Request = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetPath", {cachedX, cachedY, cachedZ, _targetX, _targetY, _targetZ, discover})
        local s_Response = PowNet.sendAndWaitForResponse("MapServer", s_Request)
        if (not s_Response) then
            print("Failed to get path")
            print(s_Response)
            return false
        end
        if(type(s_Response) == "table" and s_Response.message ~= nil) then
            print(s_Response.message)
            return false
        end
        local path = s_Response.path

        --[[
        local path = a_star(cachedX, cachedY, cachedZ, _targetX, _targetY, _targetZ, discover)
        if (#path == 0) then
            return false
        end
        --]]
        --print(textutils.serialize(table))
        for i, dir in ipairs(path) do
            if(breakExec) then
                breakExec = false
                print("Stopped exec")
                return false, "aborted"
            end
            if dir == Up then
                if not up() then
                    SavePath()
                    break
                end
            elseif dir == Down then
                if not down() then
                    SavePath()
                    break
                end
            else
                turnTo(dir)
                if not forward() then
                    SavePath()
                    break
                end
            end
        end
    end

    if changeDir then
        turnTo(_targetDir)
    end
    local x,y,z = setLocationFromGPS()
    if(x ~= _targetX or y ~= _targetY or z ~= _targetZ) then
        return false
    end
    return true
end

----------------------------------------
-- setLocation
--
-- function: Set the current X, Y, Z and direction of the turtle
-- d can be the direction name or number
--

function setLocation(x, y, z, d)
    cachedX, cachedY, cachedZ = x, y, z
    if d == 0 then
        d = "north"
        cachedDir = North
    elseif string.lower(d) == "north" then
        d = "north"
        cachedDir = North
    elseif d == 1 then
        d = "west"
        cachedDir = West
    elseif string.lower(d) == "west" then
        d = "west"
        cachedDir = West
    elseif d == 2 then
        d = "south"
        cachedDir = South
    elseif string.lower(d) == "south" then
        d = "south"
        cachedDir = South
    elseif d == 3 then
        d = "east"
        cachedDir = East
    elseif string.lower(d) == "east" then
        d = "east"
        cachedDir = East
    else
        print("unknown direction")
        return false
    end
    if isLama then
        lama.setPosition(x, y, z, d)
    end
    return cachedX, cachedY, cachedZ, cachedDir
end

----------------------------------------
-- startGPS
--
-- function: Open the rednet network
-- return: boolean "success"
--

function startGPS()
    local netOpen, modemSide = false, nil

    for _, side in pairs(rs.getSides()) do    -- for all sides
        if peripheral.getType(side) == "modem" then  -- find the modem
            modemSide = side
            if rednet.isOpen(side) then  -- check its status
                netOpen = true
                break
            end
        end
    end

    if not netOpen then  -- if the rednet network is not open
        if modemSide then  -- and we found a modem, open the rednet network
            rednet.open(modemSide)
        else
            print("No modem found")
            return false
        end
    end
    return true
end

-- setLocationFromGPS
--
-- function: Retrieve the turtle GPS position and direction (if possible)
-- return: current X, Y, Z and direction of the turtle (or false if it failed)
--

function setLocationFromGPS()
    if startGPS() then
        -- get the current position
        cachedX, cachedY, cachedZ  = gps.locate(4, false)
        local d = cachedDir or nil
        cachedDir = nil

        -- determine the current direction
        for tries = 0, 3 do  -- try to move in one direction
            if(turtle.getFuelLevel() == 0) then
                print("Out of fuel")
                return
            end
            if turtle.forward() then
                local newX, _, newZ = gps.locate(4, false) -- get the new position
                turtle.back()              -- and go back

                -- deduce the curent direction
                if newZ < cachedZ then
                    cachedDir = North
                    d = "north"
                elseif newZ > cachedZ then
                    cachedDir = South
                    d = "south"
                elseif newX < cachedX then
                    cachedDir = West
                    d = "west"
                elseif newX > cachedX then
                    cachedDir = East
                    d = "east"
                end

                -- Cancel out the tries
                turnTo((cachedDir - tries + 4) % 4)

                -- exit the loop
                break

            else -- try in another direction
                tries = tries + 1
                turtle.turnLeft()
            end
        end

        if cachedDir == nil then
            print("Could not determine direction")
            if isLama then--TODO: put lama direction
            else
                return false
            end
        end


        -- Return the current turtle position
        if isLama then
            lama.setPosition(cachedX, cachedY, cachedZ, d)
        end
        return cachedX, cachedY, cachedZ, cachedDir
    else
        print("no GPS signal")
        return false
    end
end

----------------------------------------
-- setLocationFromLAMA
--
-- function: Retrieve the turtle position and direction from LAMA
-- return: current X, Y, Z and direction of the turtle (or false if it failed)
--

function setLocationFromLAMA()
    if isLama then
        cachedX, cachedY, cachedZ, d = lama.getPosition() --last resort if gps fails, get direction from Lama
        if d == "north" then
            cachedDir = North
        elseif d == "south" then
            cachedDir = South
        elseif d == "east" then
            cachedDir = East
        elseif d == "west" then
            cachedDir = West
        else
            print("could not get direction from lama")
            return false
        end
        return true
    else
        print("no lama")
        return false
    end
end

----------------------------------------
-- locate
--
-- function: Retrieve the cached turtle position and direction
-- return: cached X, Y, Z and direction of the turtle
--

function locate()
    if isLama then
        local x, y, z, f = lama.getPosition()
        local d
        if f == "north" then
            d = North
        elseif f == "west" then
            d = West
        elseif f == "south" then
            d = South
        elseif f == "east" then
            d = East
        else
            return cachedX, cachedY, cachedZ, cachedDir
        end
        cachedX, cachedY, cachedZ, cachedDir = x, y, z, d
        return x, y, z, d
    else
        return cachedX, cachedY, cachedZ, cachedDir
    end
end