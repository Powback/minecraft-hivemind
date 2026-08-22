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
    -- m_Gps is now hosts+radius rather than a list of boxes, so describe whichever arrived.
    local s_Gps = "none"
    if m_Gps and m_Gps.hosts then
        s_Gps = ("%d host(s) within %d"):format(#m_Gps.hosts, m_Gps.range or 64)
    elseif m_Gps then
        s_Gps = ("%d box(es)"):format(#m_Gps)
    end
    print(("coverage: %d chunk region(s), gps %s"):format(m_Chunks and #m_Chunks or 0, s_Gps))
end

function getBounds() return {chunks = m_Chunks, gps = m_Gps} end

-- How far outside a set of boxes a point is. Zero when inside.
local function distanceOutside(p_List, x, y, z)
    if p_List == nil then return 0 end
    local s_Best = nil
    for _, b in ipairs(p_List) do
        local dx = math.max(b.minx - x, 0, x - b.maxx)
        local dy = math.max(b.miny - y, 0, y - b.maxy)
        local dz = math.max(b.minz - z, 0, z - b.maxz)
        local d = dx + dy + dz
        if s_Best == nil or d < s_Best then s_Best = d end
    end
    return s_Best or 0
end

-- Can a position hear enough GPS hosts to get a fix?
--
-- Radio range is a SPHERE and a fix needs four hosts. Testing an axis-aligned box instead said yes
-- at the corners, which are half again as far as the range allows, and with only one host audible.
-- A margin on top, because a drone that turns back exactly at the limit has already lost the link
-- it needs to be told to turn back.
local GPS_MARGIN = 8

local function gpsOk(p_Gps, x, y, z)
    if p_Gps == nil then return true end                 -- unspecified means unrestricted
    if p_Gps.hosts == nil then return inAny(p_Gps, x, y, z) end   -- old box form, still honoured

    local s_Range = (p_Gps.range or 64) - GPS_MARGIN
    local s_Need  = p_Gps.need or 4
    local s_Heard = 0
    for _, h in ipairs(p_Gps.hosts) do
        local dx, dy, dz = h.x - x, h.y - y, h.z - z
        if (dx * dx + dy * dy + dz * dz) <= (s_Range * s_Range) then
            s_Heard = s_Heard + 1
            if s_Heard >= s_Need then return true end
        end
    end
    return false
end

function inBounds(x, y, z)
    return inAny(m_Chunks, x, y, z) and gpsOk(m_Gps, x, y, z)
end

-- May we take this step?
--
-- Being outside the operating region must not be a life sentence. The bounds check is there to stop
-- a drone LEAVING coverage -- but applied to a drone that is already outside, it forbids every move
-- including the ones that would bring it home. Two drones sat unable to take a single step for
-- exactly this reason, and the cause was my own correction of the GPS reach: honest coverage put
-- them outside a region they were already standing in.
--
-- So: inside, the rule is unchanged. Outside, a step is allowed if it gets CLOSER to the region.
function mayStep(x, y, z)
    if inBounds(x, y, z) then return true end

    -- getCachedPosition(), NOT cachedX.
    --
    -- `local cachedX, cachedY, cachedZ, cachedDir` is declared BELOW this function, so the name
    -- `cachedX` here does not refer to it -- it compiles to a global lookup, and that global is
    -- never assigned. cx was therefore nil on every single call, this returned false immediately,
    -- and the entire "a step that gets closer to home is allowed" escape hatch was dead code from
    -- the moment it was written.
    --
    -- That is the whole reason drones outside coverage could not move. D3, D7 and D8 each reported
    -- the same three failures in a row -- no mapped route, flyTo wedged, digTo wedged -- all at
    -- their exact current position, having never taken a step. It was never terrain and never the
    -- pathfinder: every direction was refused by policy, including the ones leading home, and the
    -- one rule written to prevent that could not see where the drone was standing.
    --
    -- Calling the accessor works because global FUNCTION lookups resolve when called, not when
    -- compiled, so it finds the real one defined further down.
    local cx, cy, cz = getCachedPosition()
    if cx == nil then return false end

    -- How far outside coverage each position is. For GPS that is distance to the nearest host,
    -- which is what "closer to home" means when the constraint is radio range.
    local function gpsMiss(px, py, pz)
        if m_Gps == nil or m_Gps.hosts == nil then return distanceOutside(m_Gps, px, py, pz) end
        local s_Best = nil
        for _, h in ipairs(m_Gps.hosts) do
            local d = math.abs(h.x - px) + math.abs(h.y - py) + math.abs(h.z - pz)
            if s_Best == nil or d < s_Best then s_Best = d end
        end
        return s_Best or 0
    end

    local s_Now  = distanceOutside(m_Chunks, cx, cy, cz) + gpsMiss(cx, cy, cz)
    local s_Next = distanceOutside(m_Chunks, x, y, z)    + gpsMiss(x, y, z)
    if s_Next < s_Now then return true end
    return false, "out of bounds"
end

-- Which of the two refused, so the fix is obvious rather than guessed at.
function boundsReason(x, y, z)
    if not inAny(m_Chunks, x, y, z) then return "unloaded chunk" end
    -- gpsOk, not inAny: coverage stopped being a list of boxes when it became hosts-and-radius, and
    -- inAny on the new shape iterates a list of hosts as though they were boxes and always says no.
    -- A diagnostic that blames the wrong constraint is worse than none.
    if not gpsOk(m_Gps, x, y, z)    then return "no gps coverage" end
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
    -- OBSERVATIONS NEED A POSITION TO BE ABOUT. Without one there is nothing to record and every
    -- index built here is a concatenation with nil, which kills the drone outright -- detectAll is
    -- called after EVERY move and turn, so an unknown position turns into a crash loop rather than
    -- a missed reading. Skipping is correct and lossless: the next move with a known position
    -- re-observes the same cells.
    if cachedX == nil or cachedY == nil or cachedZ == nil then return end
    local F, U, D = deltas[cachedDir], deltas[Up], deltas[Down]
    -- Heading unknown: still record what is above, below and underfoot, just not what is ahead --
    -- "ahead" is meaningless without a direction, and deltas[nil] is nil.
    local block, idx

    -- Every write is mirrored into the pending delta so it can be shipped to MapServer. Without
    -- this the observations only ever existed in this turtle's memory.
    idx = cachedX..":"..cachedY..":"..cachedZ
    cachedWorld[idx] = 0
    noteObservation(idx, 0)

    if F then
        block = 0
        if turtle.detect()      then block = 1 end
        idx = (cachedX + F[1])..":"..(cachedY + F[2])..":"..(cachedZ + F[3])
        cachedWorld[idx] = block
        cachedWorldDetail[idx] = {turtle.inspect()}
        noteObservation(idx, block, cachedWorldDetail[idx])
    end

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
    -- Five seconds, not two. The hosts are ordinary computers serving the whole fleet, and a
    -- tight timeout turns "busy" into "out of coverage" -- which then freezes the drone, because
    -- movement is gated on having a fix. D3 sat unable to move with all four hosts up and 50-65
    -- blocks away, well inside range.
    local x, y, z = gps.locate(5, false)
    if x == nil then return nil, "no gps fix" end
    -- A BLOCK COORDINATE IS AN INTEGER. ALWAYS.
    --
    -- gps.locate trilaterates from whatever hosts answered, and the answer is only as round as its
    -- inputs. Once drones became GPS relays, a relay that anchored on a slightly-off fix began
    -- publishing it, and the error spread: 3,708 of 12,484 cells in the saved map were filed under
    -- keys like "-103.58:34.36:-48.22". Thirty per cent of the world, scanned correctly, recorded
    -- carefully, and completely unreachable -- because every lookup asks for "-103:34:-48" and no
    -- string comparison will ever match. The base looked unsurveyed while sitting in the map.
    --
    -- Flooring here rather than at each use, because this is where a position enters the system.
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
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

-- BREADCRUMBS: the way back.
--
-- A drone that loses contact has, by definition, no way to be told what to do about it. The one
-- thing it always knows is where it has just BEEN -- and the route it walked in on is guaranteed
-- to be passable, which is more than can be said for any route it might compute. So every
-- successful move drops a crumb, and losing the link becomes "retrace until someone answers"
-- rather than "stop and hope".
local m_Trail = {}
local TRAIL_MAX = 160

local function breadcrumb()
    if cachedX == nil then return end
    m_Trail[#m_Trail + 1] = {cachedX, cachedY, cachedZ}
    if #m_Trail > TRAIL_MAX then table.remove(m_Trail, 1) end
end

function trailBack()
    local n = #m_Trail
    if n == 0 then return nil end
    local crumb = m_Trail[n]
    m_Trail[n] = nil
    return crumb[1], crumb[2], crumb[3]
end

function trailLength() return #m_Trail end

-- Retracing is the ONE case where moving without a confirmed position is correct.
--
-- The guard that stops a drone travelling on an unverified position exists because drift walked D3
-- out of the loaded world. But out there, out of GPS range, that same guard freezes it in the one
-- place it must not stay -- it can no longer move back into range, so a recoverable drone becomes
-- a lost one. Retracing a recorded trail is safe precisely because the drone is going back the way
-- it came, not somewhere it has reasoned about.
local m_Recovering = false
function setRecovering(p_On) m_Recovering = p_On and true or false end
function isRecovering() return m_Recovering end

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
-- Consecutive refusals before we accept that staying put is worse than moving on dead reckoning.
local NO_FIX_GRACE = 3

function requireFix()
    if m_Recovering then return true end          -- see setRecovering
    if m_MovesSinceFix < MOVES_PER_FIX and positionVerified() then
        m_MovesSinceFix = m_MovesSinceFix + 1
        return true
    end
    if verifyPosition() then
        m_MovesSinceFix = 1
        return true
    end
    m_NoFixStops = m_NoFixStops + 1

    -- DO NOT FREEZE FOREVER.
    --
    -- Refusing to move without a fix protects the map from a drifted drone writing nonsense. Taken
    -- absolutely it also strands the drone: the places where a fix fails are exactly the places it
    -- must move OUT of, and it cannot, so it sits reporting "working" and holding a task while the
    -- fleet waits for it. That is a worse failure than a little uncertainty.
    --
    -- So after a few refusals it moves anyway, on the last known position. Observations stay
    -- suppressed while unverified (see noteCleared), so it can travel back into coverage without
    -- being trusted to describe what it sees on the way.
    if m_NoFixStops >= NO_FIX_GRACE then
        print("no GPS after " .. m_NoFixStops .. " tries -- moving on dead reckoning to regain coverage")
        m_NoFixStops = 0
        m_MovesSinceFix = 0
        return true
    end
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

-- WORK OUT WHICH WAY WE ARE FACING.
--
-- Position and heading are separate, and only setLocationFromGPS establishes heading -- by actually
-- moving and comparing fixes. Once that was made to bail safely on a missing fix, a drone could end
-- up knowing exactly where it is and not which way it points.
--
-- That is not a degraded state, it is a fatal one: deltas[nil] is nil, so the very next line of
-- forward() indexed nil and THREW. The error killed moveTo, which killed the GoTo, and the drone
-- sat reporting "moving" while standing perfectly still. Two of them did, for an hour.
function ensureHeading()
    if cachedDir ~= nil then return true end
    if cachedX == nil then return false, "no position, so no way to deduce heading" end

    -- Step, look, step back. The only way to learn which way you face is to move and see what
    -- changed -- there is no API for it.
    local function probe()
        for _ = 1, 4 do
            if turtle.forward() then
                local nx, _, nz = gps.locate(5, false)
                turtle.back()
                if nx ~= nil and nz ~= nil then
                    if     nz < cachedZ then cachedDir = North
                    elseif nz > cachedZ then cachedDir = South
                    elseif nx < cachedX then cachedDir = West
                    elseif nx > cachedX then cachedDir = East end
                end
                if cachedDir ~= nil then
                    print("heading re-established: " .. tostring(shortNames[cachedDir]))
                    return true
                end
            end
            turtle.turnLeft()   -- blocked that way; try another
        end
        return false
    end

    if probe() then return true end

    -- BEING BOXED IN MUST NOT BE TERMINAL.
    --
    -- Four blocked horizontals used to end the function, and a drone with no heading cannot move at
    -- all -- forward() refuses, so it can never reach anywhere less enclosed. It reports "heading
    -- unknown -- boxed in, cannot step to derive it" for ever. That is the state three drones were
    -- in at once, and every one of them was sitting in a shaft IT HAD DUG ITSELF: four stone walls
    -- is the normal shape of a mine, not an exceptional accident.
    --
    -- There are two ways out of a box and the drone usually has both. Rise into the open and probe
    -- from there -- a shaft is enclosed sideways, not upwards -- and put the drone back afterwards
    -- so nothing else has to know this happened.
    local s_Risen = 0
    for _ = 1, 4 do
        if not turtle.up() then break end
        s_Risen = s_Risen + 1
        cachedY = cachedY + 1
        if probe() then
            for _ = 1, s_Risen do if turtle.down() then cachedY = cachedY - 1 end end
            return true
        end
    end
    for _ = 1, s_Risen do if turtle.down() then cachedY = cachedY - 1 end end

    -- Still boxed: dig a peephole. Only a drone with a pickaxe can do this, which is fine -- it is
    -- also the only kind of drone that can bury itself in the first place.
    if turtle.dig then
        for _ = 1, 4 do
            if turtle.detect() then turtle.dig() end
            if probe() then return true end
            turtle.turnLeft()
        end
    end

    return false, "could not determine heading"
end

function forward()
    -- Facing is as necessary as position, and is NOT implied by it.
    if cachedDir == nil then
        local ok, why = ensureHeading()
        if not ok then return false, why or "no heading" end
    end

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
        if not mayStep(cachedX + F[1], cachedY + F[2], cachedZ + F[3]) then
            m_BoundsStops = m_BoundsStops + 1
            return false, "out of bounds"
        end
    end
    local D = deltas[cachedDir]--if north, D = {0, 0, -1}
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]--adds corisponding delta to direction
    local idx_pos = x..":"..y..":"..z

    if turtle.forward() then
        cachedX, cachedY, cachedZ = x, y, z
        breadcrumb()
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
        breadcrumb()
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
    if cachedY and not mayStep(cachedX, cachedY + (1), cachedZ) then
        m_BoundsStops = m_BoundsStops + 1
        return false, "out of bounds"
    end
    local D = deltas[Up]
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]
    local idx_pos = x..":"..y..":"..z

    if turtle.up() then
        cachedX, cachedY, cachedZ = x, y, z
        breadcrumb()
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
    if cachedY and not mayStep(cachedX, cachedY + (-1), cachedZ) then
        m_BoundsStops = m_BoundsStops + 1
        return false, "out of bounds"
    end
    local D = deltas[Down]
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]
    local idx_pos = x..":"..y..":"..z

    if turtle.down() then
        cachedX, cachedY, cachedZ = x, y, z
        breadcrumb()
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
    -- A turn with no known heading is arithmetic on nil, and it killed the drone --
    -- miners crash-looped on "attempt to perform arithmetic on upvalue 'cachedDir'".
    -- Turning is still useful without a heading (it is how one is derived), so do the
    -- turn and leave the cache unknown rather than throwing.
    if cachedDir == nil then turtle.turnLeft() detectAll() return true end
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
    -- A turn with no known heading is arithmetic on nil, and it killed the drone --
    -- miners crash-looped on "attempt to perform arithmetic on upvalue 'cachedDir'".
    -- Turning is still useful without a heading (it is how one is derived), so do the
    -- turn and leave the cache unknown rather than throwing.
    if cachedDir == nil then turtle.turnRight() detectAll() return true end
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
    -- Work out which way we face BEFORE doing arithmetic with it. turnTo is reached from digTo,
    -- the mine loop and the survey, and every one of those crashed the drone outright when the
    -- heading was unknown -- "attempt to perform arithmetic on upvalue 'cachedDir'". Deriving the
    -- heading is exactly what ensureHeading is for, and it can now dig or rise out of a box to do
    -- it; if even that fails, turning blind still beats dying.
    if cachedDir == nil then
        ensureHeading()
        if cachedDir == nil then
            turtle.turnLeft()
            return false, "no heading"
        end
    end
    if _targetDir == nil then return false, "no target heading" end
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
    -- Pathfinding is the most expensive call in the fleet; give it room. The default 1s made
        -- every long route look like "no path".
        local s_Response = PowNet.sendAndWaitForResponse("MapServer", s_Request, nil, 15)
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

-- Path ONE short hop. Renamed from moveTo: this asks MapServer to plan the entire route in a
-- single a_star, which is fine over a chunk and hopeless over a hundred blocks -- see moveTo below.
local function moveLeg(_targetX, _targetY, _targetZ, _targetDir, changeDir, discover)
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
            -- Say WHY. A bare `false` here surfaced as "GoTo FAILED: nil", which is the least
            -- useful thing a failing recall can report.
            return false, "MapServer did not answer the path request"
        end
        if(type(s_Response) == "table" and s_Response.message ~= nil) then
            return false, "no path: " .. tostring(s_Response.message)
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

-- Fly straight at a target without asking anyone for a path.
--
-- moveTo delegates pathfinding to MapServer's a_star, which can only route through cells the
-- fleet has actually surveyed. That is right for work inside the base and useless for RECOVERY:
-- a drone stranded at y=200 is stranded precisely because it is somewhere nobody has mapped, so
-- every recall failed with "no path" and left it there. D3 rode the ceiling for hours behind this.
--
-- Greedy and dumb on purpose. Altitude first, because open sky is the cheap axis and getting to
-- the target height usually removes the horizontal obstacles too.
function flyTo(_tx, _ty, _tz, _maxSteps)
    -- Same guard digTo carries. An omitted axis means "stay where you are on it", not "fly to nil":
    -- unguarded, the first comparison is `cachedY < nil` and the drone dies with "attempt to compare
    -- nil with number". The survey passes a nil Y deliberately, so this is a normal call shape.
    if cachedX == nil then return false, "no position fix" end
    _tx, _ty, _tz = _tx or cachedX, _ty or cachedY, _tz or cachedZ
    local s_Max = _maxSteps or 512
    local s_Steps = 0
    while cachedX ~= _tx or cachedY ~= _ty or cachedZ ~= _tz do
        s_Steps = s_Steps + 1
        if s_Steps > s_Max then return false, "flyTo gave up after " .. s_Max .. " steps" end

        local s_Moved = false
        if cachedY < _ty then s_Moved = up()
        elseif cachedY > _ty then s_Moved = down() end

        if not s_Moved and cachedX ~= _tx then
            turnTo(cachedX < _tx and East or West)
            s_Moved = forward()
        end
        if not s_Moved and cachedZ ~= _tz then
            turnTo(cachedZ < _tz and South or North)
            s_Moved = forward()
        end

        -- Every useful axis is blocked: go over it. If we cannot even rise, we are genuinely
        -- wedged and saying so beats grinding against a wall until the step budget runs out.
        if not s_Moved then
            if not up() then return false, "flyTo is wedged at " .. cachedX .. "," .. cachedY .. "," .. cachedZ end
        end
    end
    return true
end


-- Make a path where there is none.
--
-- moveTo can only route through cells someone has surveyed, and flyTo can only go OVER things.
-- Neither helps a miner facing solid rock between it and the target: a_star answers "no path" and
-- flyTo answers by climbing to the ceiling, which is how drones end up stranded in the sky. A
-- turtle with a pickaxe has a third option nothing else in the fleet has, and it should use it.
--
-- Deliberately NOT a replacement for moveTo. Digging is destructive and slow, so it is the last
-- resort after a real path search has failed -- but it is a far better last resort than flying,
-- because the tunnel it leaves behind is mapped, reusable, and on the ground.
--
-- The tunnel is two blocks high because a hole a human cannot walk down is a hole in the base.
--
-- Gravel and sand fall into the space just cleared, so every dig is a short loop rather than one
-- call; the cap stops a drone under a gravel column from digging for ever.
local DIG_RETRY = 12

local function clearAhead()
    local s_Tries = 0
    while turtle.detect() do
        if not turtle.dig() then return false end       -- bedrock, or nothing that can be broken
        s_Tries = s_Tries + 1
        if s_Tries > DIG_RETRY then return false end
        os.sleep(0.05)                                   -- let falling blocks settle before retrying
    end
    return true
end

function digTo(_tx, _ty, _tz, _maxSteps)
    if cachedX == nil then return false, "no position fix" end
    if not turtle.dig then return false, "no pickaxe: this drone cannot make a path" end
    -- An omitted axis means "stay where you are on it", not "travel to nil". Left unguarded the
    -- comparison below is always true and the drone digs until its step budget runs out.
    _tx, _ty, _tz = _tx or cachedX, _ty or cachedY, _tz or cachedZ
    local s_Max = _maxSteps or 256
    local s_Steps = 0

    while cachedX ~= _tx or cachedY ~= _ty or cachedZ ~= _tz do
        s_Steps = s_Steps + 1
        if s_Steps > s_Max then return false, "digTo gave up after " .. s_Max .. " steps" end

        -- Horizontal first, the opposite of flyTo. Altitude is the cheap axis when you are flying
        -- and the expensive one when you are digging, because every block of vertical shaft is a
        -- block that has to come out. Level tunnels are also what makes the result walkable.
        local s_Moved = false
        for _, s_Axis in ipairs({ "x", "z", "y" }) do
            if s_Moved then break end
            local s_Dx, s_Dy, s_Dz = 0, 0, 0
            if s_Axis == "x" and cachedX ~= _tx then s_Dx = cachedX < _tx and 1 or -1
            elseif s_Axis == "z" and cachedZ ~= _tz then s_Dz = cachedZ < _tz and 1 or -1
            elseif s_Axis == "y" and cachedY ~= _ty then s_Dy = cachedY < _ty and 1 or -1 end
            if s_Dx == 0 and s_Dy == 0 and s_Dz == 0 then goto continue end

            -- Check the destination cell BEFORE breaking anything. forward()/up()/down() each
            -- refuse to leave the loaded region, but they refuse AFTER we would already have dug
            -- the wall down -- which would quietly mine a hole through the boundary every time.
            if not mayStep(cachedX + s_Dx, cachedY + s_Dy, cachedZ + s_Dz) then goto continue end

            if s_Dy > 0 then
                if turtle.detectUp() then turtle.digUp() end
                s_Moved = up()
            elseif s_Dy < 0 then
                if turtle.detectDown() then turtle.digDown() end
                s_Moved = down()
            else
                turnTo(s_Dx ~= 0 and (s_Dx > 0 and East or West) or (s_Dz > 0 and South or North))
                if clearAhead() then
                    s_Moved = forward()
                    -- Head room, so what we leave behind is a corridor and not a crawlspace.
                    if s_Moved and turtle.detectUp() then turtle.digUp() end
                end
            end
            ::continue::
        end

        if not s_Moved then
            return false, "digTo is wedged at " .. cachedX .. "," .. cachedY .. "," .. cachedZ
        end
    end
    return true
end


-- Travel any distance by planning ONE CHUNK AT A TIME.
--
-- a_star's cost is superlinear in the distance searched: the open set is scanned linearly on every
-- iteration, and over unmapped ground the frontier expands in three dimensions. A 200-block recall
-- never returned at all -- not because the route did not exist, but because the search could not
-- finish before the caller gave up, and every retry started it again from scratch.
--
-- Sixteen blocks is one chunk, and a chunk-sized search is small enough to answer immediately. The
-- same journey becomes a dozen cheap questions instead of one impossible one, and each leg is
-- planned with the map as it stands AFTER the previous leg -- so what the drone learned on the way
-- is used, rather than committing to a route computed before it set off.
-- Legs start at one chunk and GROW when the drone stops getting closer.
--
-- A fixed short leg is greedy: each hop aims straight at the destination with no view of anything
-- further out, which is exactly the shape that walks into a dead end. A drone in a cave whose exit
-- leads AWAY from the target will keep choosing the deeper passage, because from sixteen blocks up
-- the road that is the better-looking move -- and it cannot backtrack, because backtracking looks
-- like going the wrong way.
--
-- Widening the horizon is what lets it escape: a_star over a 64-block box CAN see the way out and
-- will happily route backwards to take it. So the horizon is adaptive -- cheap searches while
-- things are going well, expensive ones only when the drone is in trouble, which is the only time
-- they are worth paying for.
local MOVE_LEG_MIN = 16      -- one chunk
local MOVE_LEG_MAX = 96      -- wide enough to see out of most dead ends
local MOVE_STUCK   = 4       -- legs without progress before giving up

function moveTo(_targetX, _targetY, _targetZ, _targetDir, changeDir, discover)
    if cachedX == nil then return false, "no position fix" end
    if _targetX == nil or _targetY == nil or _targetZ == nil then
        return false, "incomplete destination"
    end

    local function remaining()
        return math.abs(_targetX - cachedX) + math.abs(_targetY - cachedY) + math.abs(_targetZ - cachedZ)
    end

    local s_Legs, s_Leg, s_NoProgress = 0, MOVE_LEG_MIN, 0
    local s_Best = remaining()

    while cachedX ~= _targetX or cachedY ~= _targetY or cachedZ ~= _targetZ do
        s_Legs = s_Legs + 1
        if s_Legs > 96 then return false, "gave up after " .. s_Legs .. " legs" end

        local s_Before = remaining()
        if s_Before <= s_Leg then
            local s_Ok, s_Why = moveLeg(_targetX, _targetY, _targetZ, _targetDir, changeDir, discover)
            if s_Ok then return true end
            -- Even the final hop can be blocked; fall through and let the horizon widen.
            s_Why = s_Why or "blocked"
        else
            local dx, dy, dz = _targetX - cachedX, _targetY - cachedY, _targetZ - cachedZ
            local wx, wy, wz = cachedX, cachedY, cachedZ
            if math.abs(dx) >= math.abs(dy) and math.abs(dx) >= math.abs(dz) then
                wx = cachedX + (dx > 0 and math.min(s_Leg, dx) or -math.min(s_Leg, -dx))
            elseif math.abs(dz) >= math.abs(dy) then
                wz = cachedZ + (dz > 0 and math.min(s_Leg, dz) or -math.min(s_Leg, -dz))
            else
                wy = cachedY + (dy > 0 and math.min(s_Leg, dy) or -math.min(s_Leg, -dy))
            end
            local s_Ok = moveLeg(wx, wy, wz, nil, false, discover)
            if not s_Ok then
                -- A waypoint on a straight line can land inside rock, and there is no plan to a
                -- solid cell. Fly it directly; the next leg replans from wherever that ended up.
                flyTo(wx, wy, wz, s_Leg * 8)
            end
        end

        -- Did any of that actually help?
        local s_After = remaining()
        if s_After < s_Best then
            s_Best = s_After
            s_NoProgress = 0
            s_Leg = MOVE_LEG_MIN                 -- back to cheap searches
        else
            s_NoProgress = s_NoProgress + 1
            -- Look further before trying again. This is the escape hatch from a dead end.
            s_Leg = math.min(MOVE_LEG_MAX, s_Leg * 2)
            if s_NoProgress >= MOVE_STUCK then
                return false, ("stuck at %d,%d,%d -- %d blocks from target, no progress over %d legs (horizon %d)")
                    :format(cachedX, cachedY, cachedZ, s_After, s_NoProgress, s_Leg)
            end
        end
    end

    if _targetDir ~= nil and changeDir then turnTo(_targetDir) end
    return true
end

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
        -- Integer block coordinates -- see the note in verifyPosition.
        if cachedX then
            cachedX, cachedY, cachedZ = math.floor(cachedX), math.floor(cachedY), math.floor(cachedZ)
        end

        -- NO FIX IS AN ANSWER, NOT A CRASH.
        --
        -- Without this the code below compared `newZ < cachedZ` against nil and threw. DroneLogic
        -- died, DroneBoot caught it and rebooted, and the drone looped for ever -- re-fetching its
        -- modules on every pass, so it looked like a perfectly healthy machine that simply never
        -- registered. D3 sat in that loop for hours and nothing anywhere said "no GPS".
        if cachedX == nil then
            print("no GPS fix -- cannot establish position")
            return nil, nil, nil
        end

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

                -- The fix can vanish between the two calls -- a drone at the edge of coverage gets
                -- one and not the next. Bail rather than compare against nil.
                if newX == nil or newZ == nil then
                    print("lost GPS while establishing heading")
                    return cachedX, cachedY, cachedZ
                end

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

                -- Cancel out the tries. cachedDir can still be nil here if the drone moved but
                -- the coordinates did not change in any axis we test, and arithmetic on nil throws
                -- from inside the one routine every drone runs at boot.
                if cachedDir == nil then
                    print("moved but could not deduce heading")
                    break
                end
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