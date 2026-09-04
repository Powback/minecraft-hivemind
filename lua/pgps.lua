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

-- SAY IT SOMEWHERE SOMEBODY CAN READ IT.
--
-- Every diagnostic in this file was a bare print(), which in CC goes to the turtle's SCREEN and
-- nowhere else. This is the module where drones get lost, and its twenty-nine most useful facts --
-- "position corrected by 90", "heading re-established: E", "moved but could not deduce heading" --
-- were visible only to somebody standing in the world in front of that specific turtle.
--
-- That is not a small inconvenience. A drone whose heading was silently wrong walked a hundred and
-- twenty-one blocks in the wrong direction while `drone.log` recorded, truthfully and uselessly,
-- that it was closing the gap. verifyPosition had ALREADY computed and printed the drift each time.
-- The information existed; it just never left the turtle.
--
-- Appends to the same /drone.log DroneLogic writes, prefixed so the source is obvious. Keeps the
-- print() too, because the screen is still worth having when you are standing there.
local TRACE_LIMIT = 96 * 1024
local m_TraceLines = 0
-- SAME RATE LIMIT AS DroneLogic's trace(), AND FOR THE SAME REASON.
--
-- These two write to the SAME file, /drone.log, so collapsing repeats in one of them only fixes
-- half the noise -- and the half left uncovered was 17% of every log on its own:
-- "MOVE REFUSED: Out of fuel", written once per attempted step by a drone that cannot move. The log
-- wraps at TRACE_LIMIT, so those copies were evicting the lines that explain how the drone got
-- there. Two writers, one file, one rule.
local PT_WINDOW = 60      -- seconds a message stays suppressed after being written
local PT_KEYS   = 64      -- cap the table; a drone must not leak memory through its logger
local m_PtAt, m_PtN, m_PtCount = {}, {}, 0

local function ptRepeat(p_Text)
    local s_Now, s_Last = os.clock(), m_PtAt[p_Text]
    if s_Last ~= nil and (s_Now - s_Last) < PT_WINDOW then
        m_PtN[p_Text] = (m_PtN[p_Text] or 0) + 1
        return nil
    end
    if m_PtCount >= PT_KEYS then m_PtAt, m_PtN, m_PtCount = {}, {}, 0 end
    if m_PtAt[p_Text] == nil then m_PtCount = m_PtCount + 1 end
    m_PtAt[p_Text] = s_Now
    local s_N = m_PtN[p_Text]
    m_PtN[p_Text] = nil
    if s_N and s_N > 0 then
        return ("%s  [x%d more in the last %ds]"):format(p_Text, s_N, PT_WINDOW)
    end
    return p_Text
end

function ptrace(p_Text)
    p_Text = ptRepeat(tostring(p_Text))
    if p_Text == nil then return end
    local s_Line = ("%s pgps: %s"):format(tostring(os.clock()), tostring(p_Text))
    print(p_Text)
    m_TraceLines = m_TraceLines + 1
    -- Checked every hundredth line rather than every line: fs.getSize on each write is a syscall in
    -- the movement hot path, and the log only has to be bounded, not exact.
    if (m_TraceLines % 100) == 1 then
        if fs.exists("/drone.log") and fs.getSize("/drone.log") > TRACE_LIMIT then
            fs.delete("/drone.log")
        end
    end
    -- close() is what persists in CC -- these handles have no flush(). A guarded `if h.flush then`
    -- once silenced logging fleet-wide because the field simply does not exist.
    local h = fs.open("/drone.log", "a")
    if h then h.writeLine(s_Line) h.close() end
end

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
-- A MOVE THAT FAILS TELLS YOU WHY. DO NOT THROW IT AWAY.
--
-- turtle.forward() returns `false, "<reason>"`, and every mover here discarded the second value.
-- So "Cannot enter protected area" -- a server configuration fault that no amount of retrying can
-- ever fix -- arrived at the caller as a bare `false`, indistinguishable from a rock. TravelTo then
-- did what it does for a rock: climbed out, dug through, flew over, re-planned through MapServer.
-- All five failed identically and silently, and the fleet sat frozen for hours reporting "no mapped
-- route" while the very first call had said exactly what was wrong.
--
-- HARD means no fallback will ever help: the answer is the same from every square, in every
-- direction, until a human changes something. It must stop the attempt and be reported, loudly.
-- SOFT is an ordinary obstruction, which is what the fallbacks are actually for.
-- "lava" joins these because it is unfixable BY RETRYING, which is what hard means here. Retrying a
-- step into lava is not merely futile; it is the one mistake that ends with no drone.
local HARD_MOVE_ERRORS = { "protected", "fuel", "lava" }

-- LAVA IS THE ONE THING A TURTLE CANNOT SURVIVE, AND NOTHING IN THIS CODEBASE HAS EVER LOOKED FOR IT.
--
-- A grep for "lava" across the whole of DroneLogic and pgps found exactly one hit: lava_bucket, in
-- the list of things that can be burned as fuel. Every move primitive stepped wherever it was told.
--
-- That cost nothing while the fleet worked at y=40 and above, where there is essentially none. It
-- becomes the deciding risk the moment anything mines deep -- and it has to, because redstone gates
-- the wired modems that make a chest visible to StorageMan, and redstone's dense band is around
-- y=-50. The fleet has never been below about y=-10.
--
-- With three drones left, losing one to lava costs more than the redstone is worth, so the check
-- comes first and the depth change second.
local LETHAL_BLOCKS = { ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true }

-- p_Inspect is turtle.inspect / inspectUp / inspectDown. It returns false for air, and a table for
-- any block including fluids, so lava is genuinely visible here.
local function lavaAt(p_Inspect)
    local s_Ok, s_Block = p_Inspect()
    if not s_Ok or type(s_Block) ~= "table" then return false end
    return LETHAL_BLOCKS[s_Block.name] == true
end

local m_LastMoveError = nil
-- Seconds between forced re-fixes triggered by a surprising move failure. See forward().
local REFIX_COOLDOWN = 20
local m_LastRefixAt = nil

local function classifyMove(p_Err)
    if type(p_Err) ~= "string" then return nil end
    local s_Low = p_Err:lower()
    for _, pat in ipairs(HARD_MOVE_ERRORS) do
        if s_Low:find(pat, 1, true) then return "hard" end
    end
    return "soft"
end

-- Record the reason and hand it back, so callers can both SEE it and decide on it.
local function moveFailed(p_Err)
    local s_Kind = classifyMove(p_Err)
    if s_Kind == "hard" then
        m_LastMoveError = p_Err
        -- Printed as well as returned: a hard error means the drone is going nowhere at all, and
        -- that deserves to be visible without anyone having to ask the right question first.
        ptrace("MOVE REFUSED: " .. tostring(p_Err))

        -- YIELD. A DRONE THAT CANNOT MOVE MUST NOT SPIN LEARNING THAT.
        --
        -- Every other way a step ends goes through turtle.forward/up/down, which is a server round
        -- trip and therefore yields on its own. This branch does not: pgps refuses the move itself,
        -- before any turtle call, so the caller's retry loop is pure Lua with nothing in it that
        -- ever gives up the coroutine. CC:T kills a coroutine that runs ~10s without yielding, and
        -- the kill is uncatchable -- the computer ends up OFF with a clean-looking last-run.
        --
        -- Measured on D14 at zero fuel: "MOVE REFUSED: Out of fuel [x211 more in the last 60s]",
        -- and then gather:gold_ore failing with "/pgps:2359: Too long without yielding". The line
        -- number pointed at a file write, because that is merely where the axe happened to fall.
        --
        -- os.sleep(0) rather than the queueEvent/pullEvent trick used elsewhere: that one resumes in
        -- the SAME tick, which keeps CC happy but leaves the drone spinning at full tick rate over a
        -- condition only another drone can fix. A hard refusal cannot clear faster than a tick, so
        -- waiting one costs nothing and turns a busy loop into an idle one.
        --
        -- lua-hygiene: allow (the tick IS the point here. That rule exists for hot loops that need
        -- to satisfy the watchdog without paying a tick per iteration; this is the opposite case --
        -- a refusal only another drone can clear, where spinning at full tick rate is the bug.)
        os.sleep(0)
    end
    return false, p_Err
end

-- The last unfixable movement refusal, or nil. Cleared by whoever handles it.
function lastMoveError() return m_LastMoveError end
function clearMoveError() m_LastMoveError = nil end

local m_Chunks, m_Gps

-- THE RADIO RANGE IS A SPHERE. THE REGION WAS A SQUARE.
--
-- Every drone must stay within modem range of the mast, or it cannot reach StorageMan, cannot ask
-- where to refuel, and starves wherever it happens to be standing. A square region of reach 56
-- around a mast 22 blocks up puts the EDGES about 60 blocks out -- fine -- and the CORNERS about
-- 82, which is well past the 64-block range. So the corners were a trap: legal to walk into,
-- impossible to work from, impossible to call home from.
--
-- D2 died in one. It reached -534,69,26, logged "refuel: storage would not give a point" -- nobody
-- was listening -- and sat at zero fuel repeating that every twenty seconds while the fleet listed
-- it as lost. D1 was lost the same way, one corner over.
--
-- A radius costs a fifth of the area and removes the trap entirely.
local m_Reach = nil          -- horizontal radius from the settlement centre, if one was given
local m_Centre = nil
-- Moves, turns and distinct cells since the last motionReset() -- the heartbeat's jitter watch
-- reads them (DroneLogic.JitterWatch). A drone that made 20 moves over 3 cells is bouncing.
local m_Motion = {steps = 0, turns = 0, cells = {}, distinct = 0, callers = {}}
function motionWindow() return m_Motion.steps, m_Motion.turns, m_Motion.distinct end
function motionReset() m_Motion = {steps = 0, turns = 0, cells = {}, distinct = 0, callers = {}} end
-- Who has been moving the drone: the first frame outside this file, tallied per step. Cheap
-- enough per move, and the only way a "325 moves over 2 cells" report names the loop instead of
-- leaving it to guesswork.
local function motionCaller()
    for lvl = 3, 12 do
        local info = debug and debug.getinfo and debug.getinfo(lvl, "Sl")
        if info == nil then return "?" end
        if not tostring(info.short_src):find("pgps", 1, true) then
            return tostring(info.short_src):match("[^/]+$") .. ":" .. tostring(info.currentline)
        end
    end
    return "deep"
end
function motionCallers()
    local s_List = {}
    for site, n in pairs(m_Motion.callers) do s_List[#s_List + 1] = {site = site, n = n} end
    table.sort(s_List, function(a, b) return a.n > b.n or (a.n == b.n and a.site < b.site) end)
    local s_Out = {}
    for i = 1, math.min(3, #s_List) do s_Out[#s_Out + 1] = s_List[i].site .. " x" .. s_List[i].n end
    return table.concat(s_Out, ", ")
end
local function motionStep(p_X, p_Y, p_Z)
    m_Motion.steps = m_Motion.steps + 1
    local k = p_X .. ":" .. p_Y .. ":" .. p_Z
    if not m_Motion.cells[k] then
        m_Motion.cells[k] = true
        m_Motion.distinct = m_Motion.distinct + 1
    end
    local s_Site = motionCaller()
    m_Motion.callers[s_Site] = (m_Motion.callers[s_Site] or 0) + 1
end

local function withinReach(x, z)
    if m_Reach == nil or m_Centre == nil then return true end
    local dx, dz = x - m_Centre.x, z - m_Centre.z
    return (dx * dx + dz * dz) <= (m_Reach * m_Reach)
end

-- Exposed because the gather's vein-following needs it: seeds are filtered by the caller, but
-- following a seam outward is a decision made ON the drone, one block at a time, and it is exactly
-- how drones walk out of radio coverage without any single step looking wrong.
function isWithinReach(x, z) return withinReach(x, z) end

-- Where the settlement is. Exposed because the mesh routes messages TOWARD it: each hop picks the
-- neighbour closer to base, so every node needs the same reference point. It comes from the region
-- push and survives a reboot in pgps-region.txt, so a drone deep underground still knows which way
-- home is even with no GPS and no contact.
function centre() return m_Centre end

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

-- THE REGION MUST SURVIVE A BOOT WITHOUT THE NETWORK.
--
-- Bounds arrive from MapServer over rednet, and the drone that most needs them is the one that has
-- drifted out of radio range -- which is precisely the drone that cannot ask. With no bounds,
-- inAny() and withinReach() both answer "unrestricted", so mayStep permits everything and the
-- drone never learns it is outside the region, never walks back, and stays lost. D2 rebooted at
-- -534,69,26 with a full tank and no idea it was standing somewhere it could not call home from.
--
-- Same treatment as the pose: written down when learned, read back at boot.
local REGION_FILE = "/pgps-region.txt"

local function saveRegion()
    local h = fs.open(REGION_FILE, "w")
    if not h then return end
    h.write(textutils.serialize({reach = m_Reach, centre = m_Centre, chunks = m_Chunks}))
    h.close()
end

function loadRegion()
    if m_Chunks ~= nil or m_Reach ~= nil then return false end   -- the network already told us
    if not fs.exists(REGION_FILE) then return false end
    local h = fs.open(REGION_FILE, "r")
    if not h then return false end
    local s_Text = h.readAll()
    h.close()
    local ok, r = pcall(textutils.unserialize, s_Text)
    if not ok or type(r) ~= "table" then return false end
    m_Chunks, m_Reach, m_Centre = r.chunks, r.reach, r.centre
    ptrace(("restored region from disk: reach %s"):format(tostring(m_Reach)))
    return true
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
    m_Reach  = tonumber(p_B.reach)
    m_Centre = p_B.centre
    -- m_Gps is now hosts+radius rather than a list of boxes, so describe whichever arrived.
    local s_Gps = "none"
    if m_Gps and m_Gps.hosts then
        s_Gps = ("%d host(s) within %d"):format(#m_Gps.hosts, m_Gps.range or 64)
    elseif m_Gps then
        s_Gps = ("%d box(es)"):format(#m_Gps)
    end
    ptrace(("coverage: %d chunk region(s), gps %s, reach %s"):format(
        m_Chunks and #m_Chunks or 0, s_Gps, m_Reach and tostring(m_Reach) or "unbounded"))
    -- THE BOUNDS ARE WHAT STOP A DRONE WALKING OUT OF THE LOADED REGION, AND THIS IS WHAT KEEPS
    -- THEM ACROSS A REBOOT.
    --
    -- Bare pcall: a failed write left the new coverage live in memory and absent from disk, so the
    -- drone behaved correctly until it rebooted and then came back holding whatever the last
    -- successful save contained -- older bounds, or none. Two drones have already been lost past
    -- the edge of the region. A push that did not persist is worth saying out loud, because the
    -- symptom appears hours later, on a reboot, looking like a brand-new fault.
    local s_Saved, s_Err = pcall(saveRegion)
    if not s_Saved then
        ptrace("coverage NOT saved: " .. tostring(s_Err) .. " -- it will be lost on reboot")
    end
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
    return inAny(m_Chunks, x, y, z) and withinReach(x, z) and gpsOk(m_Gps, x, y, z)
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

    -- GPS COVERAGE GATES RE-FIXING, NOT MOVING.
    --
    -- inBounds requires both loaded chunks AND four audible GPS hosts, and the hosts are all above
    -- ground -- so every step DOWNWARD out of coverage was refused. A miner could dig the block in
    -- front of it and then not move into the hole: "bore blocked on line 1 step 5", four lines in a
    -- row, and the shaft finished having produced almost nothing. The fleet could not mine
    -- underground at all, which is the one thing the shaft exists for, since redstone, gold and
    -- diamond are all below y=16 and GPS reaches none of it.
    --
    -- Losing the fix underground is normal and expected. What matters is whether the drone still
    -- KNOWS where it is: pgps tracks position through every move, so with a verified position dead
    -- reckoning is sound and descending is safe. Without one, the drone is genuinely lost and must
    -- head back toward coverage rather than deeper -- which is the behaviour below, now correctly
    -- reserved for that case.
    --
    -- The chunk bound stays hard either way. Stepping out of a loaded chunk is how a drone stops
    -- ticking and is never seen again.
    -- Inside the loaded chunks but out of GPS: fine, as long as we still know where we are.
    --
    -- KNOWN, not RECENTLY VERIFIED. positionVerified() is false once a fix is 60 seconds old, and
    -- underground a fix can never be refreshed -- so a miner got about a minute of digging and then
    -- froze. That is precisely the "bore blocked on line 2 step 2" pattern, repeating on every line:
    -- the shaft sinks, the clock runs out, and every horizontal step is refused from then on.
    --
    -- The age limit guards against drift from displacement the drone did not notice, which is a real
    -- but slow risk. Being unable to mine at all is not slow. pgps tracks position through every
    -- move, and re-verifies the moment coverage returns, so a known position inside the loaded
    -- region is good enough to keep working on.
    --
    -- getCachedPosition(), NOT cachedX -- FOR THE SAME REASON SPELLED OUT SIXTY LINES BELOW.
    --
    -- `local cachedX, cachedY, cachedZ, cachedDir` is declared at line 298, and mayStep is defined
    -- above it, so the bare name `cachedX` here compiled to a GLOBAL lookup that is never assigned.
    -- It was nil on every call, so this branch -- the one that permits a drone to keep working
    -- underground on dead reckoning -- never returned true even once.
    --
    -- Every horizontal step below the GPS ceiling therefore fell through to the tie-break at the
    -- bottom, which only allows steps that move CLOSER to a host. The hosts are all above ground,
    -- so boring a level tunnel always moves away from them: "bore blocked on line 1 step 21 --
    -- move: out of bounds", then step 1 on every line after. The shaft sank correctly and the grid
    -- could never be cut. The comment below this one already documents this exact trap for its own
    -- line; the same mistake was sitting three lines above it, unnoticed, doing far more damage.
    local kx = getCachedPosition()
    if inAny(m_Chunks, x, y, z) and withinReach(x, z) and kx ~= nil then return true end

    -- OUTSIDE THE REGION, THE ONLY LEGAL MOVE IS BACK TOWARD IT.
    --
    -- Returning a flat false here meant a drone that ended up outside could never move again --
    -- every step refused, including the ones leading home. D3 sat at x=-412, twelve blocks past the
    -- edge, heartbeating perfectly and completely immobile. Getting out of bounds must not be a
    -- one-way door; the check below already knows how to walk a drone back, and it needs to be
    -- reachable.

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

    -- BEING OUTSIDE THE REGION IS THE PRIMARY VIOLATION, AND IT DECIDES ALONE.
    --
    -- These two terms were summed, so GPS proximity could veto a step that was clearly heading home.
    -- D3 was stranded twelve blocks outside the region and parked directly above a host: moving
    -- toward the boundary took it AWAY from that host, the gps term grew faster than the chunk term
    -- shrank, and every step home was refused. It managed two blocks in an hour.
    --
    -- If we are outside the chunk region, only that matters -- a drone in an unloaded chunk stops
    -- ticking, which is worse than any amount of dead reckoning. GPS proximity only decides the
    -- tie-break once we are inside.
    -- How far outside we are, counting BOTH the chunk box and the reach circle -- otherwise a drone
    -- sitting in a corner reads as perfectly in-bounds and never walks back toward the mast.
    local function outBy(px, py, pz)
        local d = distanceOutside(m_Chunks, px, py, pz)
        if m_Reach and m_Centre then
            local dx, dz = px - m_Centre.x, pz - m_Centre.z
            local r = math.sqrt(dx * dx + dz * dz) - m_Reach
            if r > 0 then d = d + r end
        end
        return d
    end
    local s_OutNow  = outBy(cx, cy, cz)
    local s_OutNext = outBy(x, y, z)
    if s_OutNow > 0 then
        if s_OutNext < s_OutNow then return true end
        return false, "outside the region, and that step does not head back"
    end

    local s_Now  = s_OutNow  + gpsMiss(cx, cy, cz)
    local s_Next = s_OutNext + gpsMiss(x, y, z)
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
    -- THE REACH CIRCLE, WHICH IS THE CONSTRAINT THAT ACTUALLY REFUSES MOST OFTEN.
    --
    -- mayStep tests three things -- loaded chunk, gps coverage, and withinReach -- and this named
    -- only the first two. So a drone stopped by the reach circle got "outside coverage: unknown",
    -- which is the useless half of the message the comment above is about: a diagnostic that blames
    -- nothing is no better than one that blames the wrong thing.
    --
    -- Measured on D31, blocked at -525,78,30 with 1,896 fuel, reporting "outside coverage: unknown"
    -- while the chunk was loaded and GPS was fine. It was 64 blocks out against a reach of 56, and
    -- nothing anywhere said so -- TaskMan queued a dig-out rescue for a drone that was not buried,
    -- could move perfectly well, and only needed telling to come back.
    if not withinReach(x, z) then
        local dx, dz = x - m_Centre.x, z - m_Centre.z
        return ("%d blocks from base, past the reach of %d")
            :format(math.floor(math.sqrt(dx * dx + dz * dz)), m_Reach)
    end
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

-- Observations withheld for want of a fix. Declared HERE, above noteObservation, because a `local`
-- used above its declaration is a nil GLOBAL lookup in Lua -- silently. It lived below the gate
-- until now, which is exactly why the gate could not be written at the choke point.
local m_Suppressed = 0

-- AN OBSERVATION IS ONLY WORTH WHAT ITS COORDINATES ARE WORTH.
--
-- Every cell here is keyed by the drone's BELIEVED position plus an offset. If that belief is wrong
-- the block is real, the reading is honest, and the coordinate is fiction -- so the map learns a
-- solid block at a place that is empty, and pathfinding routes around a wall that does not exist.
--
-- This ran unconditionally, which was survivable only while position was reliable. It is not: a
-- drone out of GPS range dead-reckons, a drone recovering adopts a peer-trilaterated fix good to
-- tens of blocks, and SeekCoverage deliberately walks while unverified. All three used to file
-- observations, and the result is exactly what it sounds like -- slabs of phantom terrain scattered
-- wherever a lost drone happened to travel.
--
-- The rule is simple and there is no good exception: if we cannot say where we are, we do not get
-- to say what is there. Losing the observations of an unverified drone costs a re-scan later; a
-- poisoned map costs every routing decision made from it, for as long as it survives on disk.
-- ...BUT A CLEAR AND AN ADD ARE NOT THE SAME RISK, AND GATING THEM ALIKE IS WHAT KILLED THE FLEET.
--
-- The rule above is right about ADDING: a solid block filed at a fictional coordinate is a wall the
-- pathfinder routes around for as long as the map survives on disk, and nothing ever contradicts it.
--
-- Removing is the opposite in every respect. `solid == 0` is the ONLY way a cell is ever taken out
-- of the map -- IndexOccupancy turns it into ObserveBlock(key, nil), which is the single removal
-- path in the entire system. And a wrong removal is SELF-HEALING: the block is still there, so the
-- next drone to pass re-observes it. A suppressed removal is not, because nothing re-observes air --
-- there is nothing there to see.
--
-- So the two failure modes are not comparable:
--
--   wrong ADD, suppressed   -> costs a re-scan            (the comment above says exactly this)
--   wrong CLEAR, allowed    -> costs a re-scan
--   correct CLEAR, suppressed -> the stale block is in the map FOR EVER
--
-- Losing a fix while working is normal -- underground, mid-dig, out of range -- and felling a tree
-- is precisely the moment a drone is doing that. So every tree the fleet cut stayed in the index at
-- full height, the share of the map that was fiction rose with every harvest, and the lumber picker
-- faithfully chose the densest cluster of trees that no longer existed. Verified: the chosen site
-- -530,69,55 had three logs recorded and none in the world. Sweeps flew to ghosts, felled nothing
-- and reported success; wood income reached zero, charcoal starved behind it, and the settlement
-- burned its last fuel with every job completing normally.
--
-- The same mechanism starves ore -- `gather: 1/768 checked, 0 taken` is this, one resource over.
function noteObservation(idx, solid, detail)
    if not positionVerified() and solid ~= 0 then
        m_Suppressed = m_Suppressed + 1
        return false
    end
    pendingWorld[idx] = solid
    if detail ~= nil then pendingDetail[idx] = detail end
    return true
end

-- PUT BACK OBSERVATIONS THAT WERE ALREADY VERIFIED WHEN TAKEN.
--
-- UploadWorld re-queues its delta when MapServer refuses it, and routing that through
-- noteObservation would now silently DROP it -- the fix may have lapsed in the seconds since, and
-- the gate cannot tell a stale reading from a fresh one. These coordinates were checked at the
-- moment they were recorded; a failed upload is a network problem, not a position problem.
function requeueObservations(p_World, p_Detail)
    for k, v in pairs(p_World or {}) do
        pendingWorld[k] = v
        if p_Detail and p_Detail[k] ~= nil then pendingDetail[k] = p_Detail[k] end
    end
end

-- How many observations were thrown away for want of a fix. Reported so "the map stopped growing"
-- has a visible reason rather than looking like a broken scanner.
function droppedObservations() return m_Suppressed end

-- Most observations a single upload may carry.
--
-- This used to hand over EVERYTHING pending, and a drone that has been surveying for a while
-- accumulates thousands. Measured on this fleet: batches of 9,736 and 13,214 observations in one
-- rednet message, against 34-143 from the drones that had not been out long.
--
-- A message that size is not just slow to send: MapServer is single-threaded, so it is occupied
-- parsing and indexing the whole batch, and the radio is occupied carrying it. Every heartbeat in
-- that window is lost. The drones then hit LINK_LOST_AFTER, declared the link dead and ABORTED
-- whatever they were doing -- 55 aborts across the fleet, with `Aborting (was executing: true)`
-- landing in the middle of gathers. That is why lumber never completed: the job was killed by the
-- map upload of a different drone before it could finish.
--
-- Bounded, and the remainder simply waits for the next cycle. Nothing is dropped -- the survey is
-- worth keeping, it just must not arrive all at once. 256 is comfortably under the size where a
-- single message starts costing MapServer a visible pause, and at one upload per 12s a genuine
-- backlog still drains in minutes.
local UPLOAD_MAX_BATCH = 256

function takeWorldDelta()
    local w, d, n = {}, {}, 0
    -- Partial drain. Keys are copied out one at a time and REMOVED from pending, so the next call
    -- continues where this one stopped; there is no cursor to keep in sync and no risk of sending
    -- the same cell twice.
    for k, v in pairs(pendingWorld) do
        if n >= UPLOAD_MAX_BATCH then break end
        w[k] = v
        if pendingDetail[k] ~= nil then d[k] = pendingDetail[k] end
        pendingWorld[k], pendingDetail[k] = nil, nil
        n = n + 1
    end
    return w, d, n
end

-- How many observations are still queued behind the batch cap. Lets a caller tell "nothing to
-- send" from "sending as fast as the cap allows", which otherwise look identical from outside.
function pendingObservations()
    local n = 0
    for _ in pairs(pendingWorld) do n = n + 1 end
    return n
end

-- DIRECTIONS. THE ORDER IS ANTICLOCKWISE, AND IT IS NOT NEGOTIABLE.
--
-- N, W, S, E = 0, 1, 2, 3. Every first-party module must use exactly this, and lua-hygiene fails
-- the build on any file that spells it differently -- because six copies of this line existed and
-- they did not all agree. DockingMan had `North, West, East, South = 0, 1, 2, 3`, swapping East and
-- South, in the module that assigns dock berths and orientations. It was dead code, so it never
-- fired; it was one reference away from turning every dock approach ninety degrees.
--
-- The numbering is arbitrary but the CONSEQUENCE of disagreeing is not: a heading is how pgps turns
-- "forward" into a change of coordinates, so an off-by-one here does not produce a wrong answer, it
-- produces a drone that walks the opposite way while its log insists it is heading home. That cost
-- a night and five stranded drones.
--
-- The vendored /lua/libs/lama uses the opposite rotation (north, east, south, west) and is left
-- alone -- it is upstream code. Nothing may hand it a raw number: convert at the seam, by NAME.
North, West, South, East, Up, Down = 0, 1, 2, 3, 4, 5
local shortNames = {[North] = "N", [West] = "W", [South] = "S",
                    [East] = "E", [Up] = "U", [Down] = "D" }
-- LAMA takes the spelled-out name, not the letter. Kept separate from shortNames because passing
-- "N" where "north" is expected fails silently -- LAMA simply does not update, and the drone's
-- persistent position quietly stops tracking reality.
local longNames  = {[North] = "north", [West] = "west", [South] = "south", [East] = "east"}
-- Exported name -> number, so callers stop writing their own copy of the mapping. DroneLogic had
-- one; it happened to agree, which is luck, not design.
HEADINGS = {north = North, west = West, south = South, east = East}
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
    -- lua-hygiene: allow (a full dump of the world cache is a developer aid typed at the turtle;
    -- putting thousands of serialised cells into drone.log would evict everything useful within a
    -- single call, which is the opposite of the point of having the log).
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
-- THREE, NOT SIXTEEN. A GPS FIX COSTS NOTHING HERE AND DRIFT COSTS EVERYTHING.
--
-- Sixteen moves of dead reckoning between fixes is sixteen blocks of possible error, and a heading
-- that is wrong by a quarter turn -- which happens after any reboot that restores a stale pose --
-- turns that into a drone that is simply somewhere else. Measured live on D40, carrying bricks to
-- a build:
--
--   cached position: -462,69,65   (positionVerified = false)
--   gps.locate:      -467,65,78   returned in 0.0s
--
-- Thirteen blocks out in z, with a perfect fix available for free. Everything downstream of that
-- number failed all evening: travel could not reach squares that were plainly air, pickups reported
-- empty access columns as blocked, and builds skipped two thirds of their blocks because the drone
-- refused to place on a position it could not trust.
--
-- Sixteen was the right number when a fix was assumed to be expensive. It is not: twenty hosts sit
-- within range of the settlement and the call returns in nought seconds. Ask more often, drift
-- less, and every consumer of position gets better answers for free.
local MOVES_PER_FIX   = 3
local m_MovesSinceFix = 0
local m_NoFixStops    = 0

-- BACK OFF WHEN THERE IS DEMONSTRABLY NO COVERAGE.
--
-- gps.locate blocks for its full timeout when nothing answers, and underground nothing ever
-- answers -- the hosts are all above ground and a fix needs four of them. So every call from below
-- the surface costs five seconds of doing nothing, and callers in a loop pay it per iteration.
--
-- The gather job calls this before every candidate block. With 192 candidates that is sixteen
-- minutes of a drone standing in a tunnel waiting for a fix it cannot get, per job. D3 spent
-- twenty-five minutes on one gather and moved a single block; it looked wedged and was in fact
-- simply queueing for GPS over and over.
--
-- After a failed attempt, further attempts are refused cheaply for a while. The drone keeps its
-- dead-reckoned position, which mayStep already accepts underground, and the moment it climbs back
-- into coverage the backoff expires and fixes resume.
local GPS_RETRY_AFTER = 30
local m_FixFailedAt = nil

-- p_Force skips the backoff. For code that has just DONE something to change the answer -- climbed
-- out of a shaft, retraced a breadcrumb, walked a leg looking for coverage -- the previous failure
-- says nothing about the new position, and waiting out the backoff there would be the old bug in
-- reverse: a drone standing in coverage refusing to look.
-- Which way did we just step? Compares a fresh GPS reading against the position we held BEFORE the
-- step, so the caller must not have updated the cache in between.
--
-- Its own function because the same four comparisons were written inline in ensureHeading and again
-- in setLocationFromGPS, and the copies are the reason a heading bug had two places to hide.
local function dirFromStep(nx, nz)
    if nx == nil or nz == nil then return nil end
    if     nz < cachedZ then return North
    elseif nz > cachedZ then return South
    elseif nx < cachedX then return West
    elseif nx > cachedX then return East end
    return nil
end

-- WATCH THE HEADING FOR FREE, WHILE THE DRONE IS MOVING ANYWAY.
--
-- Heading is the one thing that never self-corrects. A FAILED move is handled -- the cache only
-- advances when turtle.forward() returned true. A SUCCESSFUL move on a wrong cachedDir is the
-- problem: it advances the cache by the wrong delta, so belief and reality separate at twice the
-- distance travelled. D14 ended 118 blocks out in x, which is about fifty-nine blocks flown
-- backwards while its log reported progress the whole way.
--
-- The first fix for this triggered a PROBE -- step out, read GPS, step back -- but only once drift
-- had already reached four blocks. That is both late and expensive: it costs two moves, needs open
-- space, and needs the drone to be idle, so it can only run in the recovery path a drifting drone
-- struggles to reach.
--
-- None of that is necessary. Between two fixes the drone recorded what it INTENDED to do, and GPS
-- says what it ACTUALLY did. If those disagree the heading is wrong -- proven, on the first fix
-- after the very first bad move, at a cost of nothing. And when the drone happens to have flown
-- straight without turning, the actual displacement IS the true heading, so it can be corrected
-- outright rather than merely suspected.
local m_FixAtX, m_FixAtY, m_FixAtZ = nil, nil, nil   -- where the last fix put us
local m_IntDX, m_IntDY, m_IntDZ    = 0, 0, 0         -- displacement we believe we made since
local m_TurnsSinceFix              = 0
local m_StraightFwd                = 0               -- forward steps, if nothing else happened
local m_HeadingSuspect             = false
-- EVERY CHANGE TO WHERE WE THINK WE ARE BUMPS THIS. verifyPosition and the heading probe run in
-- coroutines of their own (refixLoop, the fuel watchdog, heartbeats), and gps.locate yields while
-- the hosts answer. If the travel coroutine steps the turtle meanwhile, the hosts measured a turtle
-- that was in two places during one fix, and the cache moved on besides -- and the difference was
-- logged as "position corrected by N" and ADOPTED; then "drift too big -- re-checking the heading"
-- sent a probe step under the traveller's feet, and the drone was re-established to N, E, S and W
-- in turn, 45 s apart, while flying straight (D54, 2026-09-04). Measured the same night on three
-- stationary drones: identical fixes 12 of 12 times, cache == GPS == the server's own dump.
-- GPS does not drift. Races do.
local m_MoveSeq = 0

-- A FIX TAKEN WHILE A MOVE IS IN FLIGHT IS A FIX OF A TURTLE THAT IS IN TWO PLACES. turtle.forward()
-- puts the turtle in the next block at once and returns only when the eight-tick animation ends, so
-- for that window the world says "there" and the cache still says "here". A fix landing in it read
-- as one block of drift and was ADOPTED, and the mover then committed its own step on top -- which is
-- the "audit matched (0,0,2) yet the fix moved us 1 -- both cannot be right" line, 18 times in ten
-- minutes on D58 after the sequence guard above alone had shipped. The sequence catches a step that
-- COMMITTED during the fix; this catches one that was under way. Every move here, tracked or probe,
-- goes through timedMove; DroneLogic's own raw probe brackets itself with holdFixes/releaseFixes.
local m_Moving, m_MovingSince = 0, nil
local MOVE_HOLD_MAX_S = 60                      -- a hold older than this is a leak, not a move
function holdFixes()
    if m_Moving == 0 then m_MovingSince = os.clock() end
    m_Moving = m_Moving + 1
end
function releaseFixes() m_Moving = math.max(0, m_Moving - 1) end
local function timedMove(p_Fn)
    holdFixes()
    local ok, a, b = pcall(p_Fn)
    releaseFixes()
    if not ok then error(a, 0) end
    return a, b
end


function headingSuspect() return m_HeadingSuspect end

-- Called by every move that advances the cache, and by the turns. Cheap: three adds.
function notePlannedStep(dx, dy, dz, p_Straight)
    m_MoveSeq = m_MoveSeq + 1
    m_IntDX, m_IntDY, m_IntDZ = m_IntDX + dx, m_IntDY + dy, m_IntDZ + dz
    if p_Straight then m_StraightFwd = m_StraightFwd + 1 else m_StraightFwd = -1 end
end
function noteTurn() m_TurnsSinceFix = m_TurnsSinceFix + 1 m_StraightFwd = -1 m_Motion.turns = m_Motion.turns + 1 end

local function resetAudit(x, y, z)
    m_FixAtX, m_FixAtY, m_FixAtZ = x, y, z
    m_IntDX, m_IntDY, m_IntDZ = 0, 0, 0
    m_TurnsSinceFix, m_StraightFwd = 0, 0
end

-- MEASURE THE ERROR AS A ROTATION, AND TURN THE CACHE BY IT.
--
-- The audit gives two vectors: where we INTENDED to go since the last fix, and where GPS says we
-- ACTUALLY went. If both point along a single horizontal axis, the angle between them is exactly
-- how wrong the heading is -- and it can simply be added to cachedDir. No probe, no stepping out
-- and back, no open space required, no fuel: the drone was flying anyway and the fix was going to
-- happen anyway.
--
-- Measured live, and this is what made it obvious: "wanted 0,-1,-2 got -2,-1,0", "wanted 0,-1,2 got
-- 2,-1,0", "wanted -1,0,-3 got -3,0,1". The y component matches every time; x and z are rotated a
-- quarter turn, the same quarter turn, on every drone. That is not drift -- drift is random. It is a
-- heading that is systematically one step out, which no amount of correcting the POSITION fixes.
--
-- The earlier version of this only acted on a run with no turns in it, which almost never happens,
-- and it asked dirFromStep to compare against cachedX/cachedZ -- the dead-reckoned position, not
-- the position the run started from. Working out the rotation needs neither.
local AXIS_INDEX = {}   -- unit vector -> the compass number that points that way
AXIS_INDEX["0,-1"] = North
AXIS_INDEX["-1,0"] = West
AXIS_INDEX["0,1"]  = South
AXIS_INDEX["1,0"]  = East

-- The compass number a displacement points along, or nil if it is not cleanly along one axis.
local function axisOf(dx, dz)
    if (dx == 0) == (dz == 0) then return nil end      -- both zero, or diagonal: no single answer
    local ux = dx == 0 and 0 or (dx > 0 and 1 or -1)
    local uz = dz == 0 and 0 or (dz > 0 and 1 or -1)
    return AXIS_INDEX[ux .. "," .. uz]
end

local function correctFromTravel(adx, adz)
    -- ONLY A STRAIGHT RUN CAN BE INVERTED. After a turn the intent vector is a sum over two
    -- headings and its axis means nothing; rotating a correct heading by it produced "heading was
    -- E, we actually travelled E -- rotating 3 quarter-turn(s) to S" in the bay, where every deposit
    -- dance turns, and each false rotation sent the next leg the wrong way (2026-09-04, D38).
    if m_TurnsSinceFix > 0 then return false end
    local want = axisOf(m_IntDX, m_IntDZ)
    local got  = axisOf(adx, adz)
    if want == nil or got == nil or want == got then return false end
    if cachedDir == nil then return false end
    -- Compass numbering is anticlockwise (N,W,S,E = 0,1,2,3), so a difference in index IS the
    -- rotation, and applying it to cachedDir is the whole correction.
    local s_Turn = (got - want) % 4
    local s_New  = (cachedDir + s_Turn) % 4
    ptrace(("heading was %s, we actually travelled %s -- rotating %d quarter-turn(s) to %s, no probe")
        :format(tostring(shortNames[cachedDir]), tostring(shortNames[got]),
                s_Turn, tostring(shortNames[s_New])))
    cachedDir = s_New
    savePose(true)
    m_HeadingSuspect = false
    return true
end

-- Compare intent against reality. Returns nothing; corrects or flags as a side effect.
local function auditHeading(x, y, z)
    if m_FixAtX == nil then return end
    local adx, ady, adz = x - m_FixAtX, y - m_FixAtY, z - m_FixAtZ
    if adx == m_IntDX and ady == m_IntDY and adz == m_IntDZ then
        m_HeadingSuspect = false
        -- Deliberately loud while this is being trusted: a MATCH that coincides with a non-zero
        -- drift would mean the two measurements disagree about what "wrong" means, and that has to
        -- be visible rather than inferred. Quiet when there was nothing to compare.
        if m_Drift and m_Drift > 0 then
            ptrace(("audit matched (%d,%d,%d) yet the fix moved us %d -- both cannot be right")
                :format(m_IntDX, m_IntDY, m_IntDZ, m_Drift))
        end
        return
    end
    -- ALL THREE AXES, not just the two that name a heading.
    --
    -- The first version compared x and z only, reasoning that up and down say nothing about which
    -- way the drone faces. True, and it made the check blind to the commonest disagreement there
    -- is: drones were being corrected by two to six blocks on every scheduled fix and the audit sat
    -- silent, because the error was VERTICAL. Bookkeeping that is wrong about y is wrong -- it puts
    -- the drone on the wrong floor, which is how one ends up boring through a chest or surfacing
    -- inside rock -- and a check that cannot see it is not auditing the bookkeeping, only part of it.
    --
    -- The heading INFERENCE below still uses x/z alone, because only those can name a direction.
    if adx == 0 and ady == 0 and adz == 0 and m_IntDX == 0 and m_IntDY == 0 and m_IntDZ == 0 then
        return                                        -- stood still: nothing to check
    end

    m_HeadingSuspect = true
    if not correctFromTravel(adx, adz) then
        ptrace(("bookkeeping disagrees with GPS since the last fix: wanted %d,%d,%d got %d,%d,%d")
            :format(m_IntDX, m_IntDY, m_IntDZ, adx, ady, adz))
    end
end

-- How many consecutive fixes must disagree with the bookkeeping by exactly one block before the
-- fix wins. See verifyPosition. Declared above it: a `local` below its use is a nil global.
function verifyPosition(p_Force)
    if not p_Force and m_FixFailedAt and (os.clock() - m_FixFailedAt) < GPS_RETRY_AFTER then
        return nil, "no gps fix (backing off)"
    end
    if not startGPS() then return nil, "no modem for gps" end
    if m_Moving > 0 then
        if m_MovingSince and (os.clock() - m_MovingSince) > MOVE_HOLD_MAX_S then
            ptrace(("a move has been in flight for %ds -- that is a leaked hold, releasing it")
                :format(math.floor(os.clock() - m_MovingSince)))
            m_Moving, m_MovingSince = 0, nil
        else
            return nil, "moving"
        end
    end
    -- Five seconds, not two. The hosts are ordinary computers serving the whole fleet, and a
    -- tight timeout turns "busy" into "out of coverage" -- which then freezes the drone, because
    -- movement is gated on having a fix. D3 sat unable to move with all four hosts up and 50-65
    -- blocks away, well inside range.
    local s_Seq = m_MoveSeq
    local x, y, z = gps.locate(5, false)
    if m_MoveSeq ~= s_Seq or m_Moving > 0 then
        -- ANOTHER COROUTINE MOVED THE TURTLE WHILE THE HOSTS WERE ANSWERING. The fix describes a
        -- turtle that was between two blocks (the hosts' distances were not even measured at one
        -- place) and the cache describes where it is now; comparing them manufactures drift, and
        -- adopting it moved the bookkeeping BEHIND the drone by however far it travelled during
        -- the locate. Not a GPS failure, so no back-off: the mover re-fixes itself between steps
        -- (moveLeg), where nothing can move under it.
        ptrace("fix discarded: we moved while the hosts were answering")
        return nil, "moved during the fix"
    end
    if x == nil then
        m_FixFailedAt = os.clock()
        return nil, "no gps fix"
    end
    m_FixFailedAt = nil
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
        -- A DISAGREEMENT IS ADOPTED AT ONCE, ONE BLOCK OR TEN. There is no GPS noise to filter: the
        -- hosts are fixed computers at exact coordinates and the distances are exact, so a
        -- stationary turtle reads the same block every time (12 of 12 on three drones, 2026-09-04).
        -- The "six fixes read -496, -496, -496, -496, -497, -497" that once justified a three-fix
        -- hysteresis here were taken on a drone that was STEPPING for a heading probe. What looked
        -- like sensor noise was the race guarded against above, and the hysteresis only hid it.
        if m_Drift > 0 then
            ptrace(("position corrected by %d: %d,%d,%d -> %d,%d,%d")
                :format(m_Drift, cachedX, cachedY, cachedZ, x, y, z))
        end
    end
    -- BEFORE overwriting the cache: the audit needs the position GPS just reported, compared
    -- against where our own bookkeeping thought we had gone since the previous fix.
    auditHeading(x, y, z)
    cachedX, cachedY, cachedZ = x, y, z
    resetAudit(x, y, z)
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

-- The unit vector the drone is currently facing, or nil if the heading is unknown. `deltas` is a
-- local, so a caller outside this file cannot reach it -- and a caller that has just driven the
-- turtle forward by hand needs exactly this to say which way it went.
function headingDelta()
    if cachedDir == nil then return nil end
    local D = deltas[cachedDir]
    if D == nil then return nil end
    return D[1], D[2], D[3]
end

-- A MOVE PGPS DID NOT MAKE IS STILL A MOVE.
--
-- Some callers genuinely have to drive the turtle directly: the heading probe cannot use forward()
-- because forward() applies the very heading being tested, and SurfaceForFix climbs precisely when
-- there is no fix, which is the one condition forward() refuses to move under. Both are correct to
-- go raw. Both were wrong to stay silent about it.
--
-- SurfaceForFix was the expensive one. It climbs up to RECOVERY_CLIMB blocks with turtle.up(),
-- calling verifyPosition after each -- and that call FAILS every time, because no fix is exactly
-- why the drone is climbing. So the whole ascent went unrecorded: the cache kept its old y, the
-- audit recorded no intent for it, and when a fix finally arrived it read as sudden drift with
-- the horizontal intent still matching. Caught live on D16, on the FIXED build:
--
--   position corrected by 10: -493,84,76 -> -488,79,76
--   audit matched (6,-3,0) yet the fix moved us 10 -- both cannot be right
--
-- Both were right again. The audit was measuring a journey with ten blocks missing from it, and
-- the phantom drift went on to trip the heading re-check -- so the climb that was supposed to
-- RECOVER a position was manufacturing the drift that made everyone think it was lost.
--
-- Tell the truth about the step instead: move the cache, record the intent, drop a crumb. The
-- caller keeps its raw move; the bookkeeping stops lying about it.
-- DECLARED HERE, ABOVE noteExternalStep, WHICH IS THE FIRST THING TO USE IT.
-- It used to live 1,300 lines further down, next to savePose. A `local` used above its
-- declaration is a nil GLOBAL in Lua -- silent -- so the invalidation below would have called
-- fs.exists(nil) and thrown inside the one path that runs when a drone is already lost.
local POSE_FILE = "/pgps-pose.txt"

function noteExternalStep(dx, dy, dz)
    -- MOVING WITH NO POSITION MUST INVALIDATE THE SAVED ONE.
    --
    -- Returning false here is honest -- with no cachedX there is nothing to add a step to -- but it
    -- was silent, and the caller that hits this is climbForFix: the drone is climbing PRECISELY
    -- because it has lost its fix. So the ascent is neither tracked nor saved, and the pose file
    -- still holds wherever it was standing before it took off.
    --
    -- A reboot then restores that file and the drone asserts a position it has physically left.
    -- Measured: D9 believed -480,65,68 while the server had it at y≈97, and the GPS correction that
    -- followed moved it 39 blocks -- "bookkeeping disagrees with GPS since the last fix: wanted
    -- 2,0,0 got -2,0,2", i.e. the reckoning was self-consistent and the ANCHOR was thirty-four
    -- blocks wrong. It then flew 31 blocks back down, and every one of those blocks was fuel the
    -- settlement did not have. All sixteen GPS hosts were verified correct against the server, so
    -- the fix was right and the belief was wrong.
    --
    -- Deleting the pose is strictly better than keeping a stale one: pgps already knows how to
    -- start with no position (it re-fixes, and refuses to dead-reckon until it has), whereas a
    -- confidently wrong altitude is acted on.
    if cachedX == nil then
        if fs.exists(POSE_FILE) then pcall(fs.delete, POSE_FILE) end
        return false
    end
    cachedX, cachedY, cachedZ = cachedX + dx, cachedY + dy, cachedZ + dz
    notePlannedStep(dx, dy, dz, false)   -- never "straight": these are one-off steps, not a run
    breadcrumb()
    savePose()
    return true
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

    -- DEAD RECKONING IS ALLOWED IMMEDIATELY, NOT AFTER THREE REFUSALS.
    --
    -- mayStep learned this and forward() has its own gate that did not: requireFix refused three
    -- times before conceding, and a bore breaks on the FIRST refusal. So every branch line died at
    -- step 1 or 2 with "move: position unverified" -- underground, where a fix can never be
    -- refreshed, that refusal is guaranteed and permanent.
    --
    -- A known position is enough to keep moving on. The counter still runs, so refixLoop can decide
    -- to surface and re-acquire; it just no longer stops the drone working while it does.
    if cachedX ~= nil then
        m_MovesSinceFix = 0
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
        ptrace("no GPS after " .. m_NoFixStops .. " tries -- moving on dead reckoning to regain coverage")
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
-- THE INVERSE OF noteCleared: a cell we now know we CANNOT pass.
--
-- Refusing to mine a protected block recorded nothing at all -- it printed a line and returned
-- false, leaving the map believing the cell was passable. So the pathfinder planned straight back
-- through it, the drone refused again, and the pair of them did that indefinitely. "Continuously
-- pathfinds to the same obstruction" is the exact shape of an observation that was made and thrown
-- away: the drone learned the truth and told nobody, including itself.
function noteBlocked(p_Which, p_Name)
    local d
    if p_Which == "up"        then d = deltas[Up]
    elseif p_Which == "down"  then d = deltas[Down]
    else
        -- A GUESS AT WHICH WAY WE FACE WRITES A WALL THAT IS NOT THERE.
        --
        -- The horizontal cell is derived from cachedDir, so a stale or missing heading records the
        -- WRONG neighbour as permanently solid -- in the SHARED map, where every drone then plans
        -- around an obstacle that does not exist. That is strictly worse than recording nothing:
        -- a missed observation costs one rediscovery, a phantom wall costs every route past it,
        -- for ever, and looks exactly like the 190 imaginary turtle blocks we spent a day purging.
        --
        -- Up and down need no heading and are always safe. Horizontal needs one we have actually
        -- established, so establish it or say nothing.
        if cachedDir == nil then
            local ok = ensureHeading()
            if not ok then return nil end
        end
        if not positionVerified() then return nil end
        d = deltas[cachedDir]
    end
    if d == nil then return nil end

    local idx = (cachedX + d[1])..":"..(cachedY + d[2])..":"..(cachedZ + d[3])
    local s_Detail = p_Name and {true, {name = p_Name}} or nil
    -- 3, not 1: "solid AND we are forbidden to break it". A digging drone routes through ordinary
    -- solid rock quite happily, so recording a chest as merely solid tells the pathfinder nothing
    -- it will act on. See a_star: 0 air, 1 solid, 2 turtle, 3 forbidden.
    cachedWorld[idx] = 3
    if s_Detail then cachedWorldDetail[idx] = s_Detail end
    -- noteObservation gates and counts this now; it used to be checked here and in noteCleared and
    -- nowhere else, which is how the scan paths poisoned the map unnoticed.
    noteObservation(idx, 3, s_Detail)
    return idx
end

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
    -- Only tell the SERVER while a recent fix agrees on where we are -- enforced inside
    -- noteObservation, so every caller gets it and not just the two that remembered.
    noteObservation(idx, 0)
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
-- DEFINED ABOVE ITS FIRST USE, WHICH IS THE ONLY PLACE IT CAN LIVE.
--
-- This sat next to clearAhead at line 1144, four hundred lines BELOW the call in ensureHeading. A
-- local is only in scope after its definition, so that call compiled to a global lookup and read
-- nil: "attempt to call global 'digGuarded'". Every Gather job died on it the moment a drone had to
-- dig its way anywhere -- and the guard that was supposed to stop drones mining each other silently
-- was not protecting that path at all.
--
-- Fourth time today this exact trap has bitten: mayStep, m_DroneEvents, reportTask, and now this.
-- NEVER BREAK THE SETTLEMENT, OR EACH OTHER.
--
-- digTo carves a corridor with raw turtle.dig, and D1 was standing in one. A miner tunnelled through
-- a fellow drone, which dropped as an item, and then a haul carried it to storage -- so the fleet
-- mined one of its own members and filed it. D1 read as "lost" and was in a chest, with its pickaxe,
-- its modem and 19,651 fuel still attached.
--
-- DroneLogic's digHard already refused protected blocks. pgps did not, and pgps is the layer that
-- actually digs during travel, which is where a drone is most likely to meet another one. The guard
-- belongs here, at the bottom, not only in the caller that happened to have it.
--
-- Anything computercraft: covers every turtle, computer, modem, drive and cable; the rest is the
-- infrastructure a settlement would be sad to lose to a passing tunnel.
local PROTECT = {
    ["minecraft:chest"] = true, ["minecraft:trapped_chest"] = true, ["minecraft:barrel"] = true,
    ["minecraft:furnace"] = true, ["minecraft:blast_furnace"] = true, ["minecraft:smoker"] = true,
    ["minecraft:hopper"] = true, ["minecraft:dropper"] = true, ["minecraft:dispenser"] = true,
}

function isProtectedBlock(p_Name)
    if p_Name == nil then return false end
    if PROTECT[p_Name] then return true end
    return string.sub(p_Name, 1, 14) == "computercraft:"
end

-- Dig, unless what is there is ours. Returns false and the block name when it refuses, so a caller
-- can route around rather than retry into the same wall.
-- Cells we have refused to dig because the block in them is protected. REMEMBERED, because a
-- refusal that is not written down is a refusal that will be repeated.
--
-- Kept as a fast local guard even though routing now handles this properly: a refusal recorded here
-- is skipped without a round trip, and it covers the window between meeting a block and the shared
-- map learning about it. Historically this was the ONLY protection, because digTo was a greedy
-- axis-walker that consulted no map at all -- D7 spent its life tunnelling at the storage modems,
-- refusing and re-planning the identical route. digTo is now moveTo with a passability flag, so the
-- pathfinder simply never routes through a cell recorded as forbidden.
local m_ProtectedCells = {}

-- CAN THIS TURTLE DIG? `turtle.dig` is a function on every turtle, tool or not -- it just fails with
-- "No tool to dig with". So every `if turtle.dig then` guard in this codebase is always true, and a
-- crafter with a modem and a workbench (no room for a pickaxe) ran the full 256-step digTo loop
-- failing on every step instead of skipping it. Two upgrade slots: if both hold a PERIPHERAL there
-- is no tool, because tools report no peripheral type.
function canDig()
    local l = peripheral.getType("left")
    local r = peripheral.getType("right")
    return not (l ~= nil and r ~= nil)
end

function protectedCell(idx) return m_ProtectedCells[idx] == true end

local function digGuarded(p_Dig, p_Detect, p_Inspect, p_Idx)
    if not p_Detect() then return true end
    local s_Ok, s_Blk = p_Inspect()
    if s_Ok and s_Blk and isProtectedBlock(s_Blk.name) then
        ptrace("refusing to dig " .. tostring(s_Blk.name))
        if p_Idx then
            m_ProtectedCells[p_Idx] = true
            -- Tell the shared map as well, so the other drones never plan through it either -- as 3,
            -- "forbidden", because a digger treats plain solid as passable.
            cachedWorld[p_Idx] = 3
            if positionVerified() then noteObservation(p_Idx, 3, {true, {name = s_Blk.name}}) end
        end
        return false, s_Blk.name
    end
    return p_Dig()
end


-- p_Force re-derives a heading we ALREADY have, instead of trusting it.
--
-- A WRONG HEADING IS PERMANENT, AND IT IS WORSE THAN A WRONG POSITION.
--
-- This returned true the instant cachedDir was set, so a heading, once wrong, was never questioned
-- again by anything -- and verifyPosition corrects the POSITION only, so GPS could not repair it
-- either. The two together produce a drone that walks confidently in the wrong direction for ever:
-- every step updates the cache by the bad heading, so its believed position moves TOWARD home while
-- the drone moves away from it, and each GPS fix silently resets the position without touching the
-- cause.
--
-- Measured on D11: it believed it was at -480,112,64 -- horizontally exactly home -- while sitting
-- at -426,112,172, a hundred and twenty-one blocks out, having travelled EAST for the entire
-- journey home while its log reported the gap closing at every leg.
--
-- Re-deriving costs one step out and back and needs a GPS fix to compare against, so callers should
-- force it just after a confirmed fix. The probe only ever ASSIGNS cachedDir, never clears it, so a
-- failed re-derivation leaves the old heading in place rather than immobilising the drone.
function ensureHeading(p_Force)
    if cachedDir ~= nil and not p_Force then return true end
    if cachedX == nil then return false, "no position, so no way to deduce heading" end

    -- Step, look, step back. The only way to learn which way you face is to move and see what
    -- changed -- there is no API for it.
    -- SAY WHY THE STEP FAILED. This swallowed the reason, and the reason was the whole story: with
    -- spawn protection covering the settlement every turtle.forward() here returned
    -- "Cannot enter protected area", all four directions, so the heading could never be derived --
    -- and a drone with no heading refuses every subsequent move. The fleet reported "boxed in" while
    -- standing in a scanned-empty 9x9 of open air. One propagated string would have said it outright.
    local function probe()
        for _ = 1, 4 do
            local s_Seq = m_MoveSeq
            local s_Ok, s_Err = timedMove(turtle.forward)
            if not s_Ok and classifyMove(s_Err) == "hard" then
                moveFailed(s_Err)
                return false, s_Err
            end
            if s_Ok then
                local nx, ny, nz = gps.locate(5, false)
                -- NEVER MOVE WITHOUT RECORDING IT. THIS IS WHERE DRONES GET LOST.
                --
                -- The step out and back is deliberately raw -- pgps.forward() needs a heading, which
                -- is the very thing we are deriving -- so nothing here updates the cached position.
                -- That is only safe while BOTH moves succeed. `turtle.back()` was unchecked, so any
                -- time something sat behind the drone it stayed one block forward while believing it
                -- had not moved at all.
                --
                -- One block per occurrence, and this runs every time the heading is unknown, which
                -- for a drone out of GPS range is constantly. It compounds silently: two drones were
                -- found 28 and 45 blocks from where their own saved pose said they were, still
                -- convinced they were inside the region -- so the region-return never fired, the
                -- walk-home had a false starting point, and every recovery path was reasoning from
                -- fiction. That drift is not weather; it is this line.
                --
                -- If we cannot come back, adopt the position we actually reached.
                local s_Back = timedMove(turtle.back)
                if not s_Back then
                    if nx ~= nil then
                        cachedX, cachedY, cachedZ = math.floor(nx), math.floor(ny), math.floor(nz)
                    elseif cachedDir and cachedX then
                        local F = deltas[cachedDir]
                        cachedX, cachedY, cachedZ = cachedX + F[1], cachedY + F[2], cachedZ + F[3]
                    end
                    -- Re-anchor, for the reason spelled out in setLocation. This site is the worst
                    -- of the four: the steps above are deliberately raw, so nothing recorded them
                    -- as intent, and adopting the position without moving the anchor books the
                    -- whole un-returned step as drift. Drift is what calls this probe. It fed
                    -- itself -- a failed probe guaranteed the next one.
                    resetAudit(cachedX, cachedY, cachedZ)
                    savePose()
                end
                if m_MoveSeq ~= s_Seq then
                    -- The traveller stepped, or was stepped, while our probe was out: the GPS delta
                    -- is theirs plus ours and a heading read off it is a coin toss. Keep what we had.
                    ptrace("heading probe: something else moved us during the probe -- not trusting the step")
                    return false, "moved during the probe"
                end
                cachedDir = dirFromStep(nx, nz) or cachedDir
                if cachedDir ~= nil then
                    ptrace("heading re-established: " .. tostring(shortNames[cachedDir]))
                    return true
                end
            end
            -- "cachedDir is nil here BY DEFINITION" was the old exemption on this line, and it was
            -- false: ensureHeading(p_Force) skips its early return when forced, so probe() runs with
            -- a PERFECTLY GOOD cachedDir whenever a drift check re-derives the heading. Every raw
            -- turn taken here then rotated the drone without rotating the cache. The loop only comes
            -- out even if it runs all four times; the hard-error return above leaves it k
            -- quarter-turns out, permanently, and this path runs constantly because it is what a
            -- drone does whenever it loses GPS.
            --
            -- That is the "heading error that appears MID-run" in the logs: "wanted -4,0,0 got
            -- -2,0,2" -- two steps west, then this turn fired, then two steps south, all booked as
            -- west. D14 walked all four ways looking for GPS and ended 76 blocks from where its own
            -- pose said it was, which is why the relief sent to it arrived nowhere near it.
            --
            -- pgps.turnLeft already does the raw turn when cachedDir is nil (see its first line), so
            -- it is correct for BOTH callers: derivation keeps its unchecked turn, and the forced
            -- re-derivation keeps its cache in step.
            turnLeft()   -- blocked that way; try another
        end
        return false
    end

    local s_Probed, s_ProbeErr = probe()
    if s_Probed then return true end
    if s_ProbeErr then return false, s_ProbeErr end

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
        local s_Up, s_UpErr = timedMove(turtle.up)
        if not s_Up then
            if classifyMove(s_UpErr) == "hard" then moveFailed(s_UpErr) return false, s_UpErr end
            break
        end
        s_Risen = s_Risen + 1
        -- noteExternalStep, NOT `cachedY = cachedY + 1`.
        --
        -- Poking the cache keeps the POSITION right and leaves the AUDIT blind, and that gap is
        -- the whole bug. probe() is called from inside this climb and re-anchors the audit at the
        -- RAISED position; the unwind below then descends without telling it, so the anchor is left
        -- N blocks above where the drone actually is and every later fix reads as drift that
        -- nothing can explain. Measured on a drone running the fixed build:
        --
        --   audit matched (7,12,2) yet the fix moved us 24 -- both cannot be right
        --   drift of 24 is too big for dead reckoning -- re-checking the heading
        --
        -- Twenty-four blocks is enough that a reliever sent to a stranded drone arrives nowhere
        -- near it and "drops nothing", which is what stopped fuel relief from ever completing.
        --
        -- The old exemptions argued cachedY is only touched when the step really happened. True,
        -- and beside the point: the pose was never what broke.
        noteExternalStep(0, 1, 0)
        if probe() then
            -- lua-hygiene: allow (unwinding our own climb: a refused descent needs no reason, it
            -- just means we stay higher -- and noteExternalStep only records the step when
            -- turtle.down() actually returned true, so cache and audit stay together either way)
            for _ = 1, s_Risen do if timedMove(turtle.down) then noteExternalStep(0, -1, 0) end end
            return true
        end
    end
    -- lua-hygiene: allow (unwinding our own climb, as above)
    for _ = 1, s_Risen do if timedMove(turtle.down) then noteExternalStep(0, -1, 0) end end

    -- Still boxed: dig a peephole. Only a drone with a pickaxe can do this, which is fine -- it is
    -- also the only kind of drone that can bury itself in the first place.
    if canDig() then
        for _ = 1, 4 do
            digGuarded(turtle.dig, turtle.detect, turtle.inspect)
            if probe() then return true end
            -- Same fix as the turn inside probe(): "the heading is unknown here" is only true on the
            -- unforced path. turnLeft() degrades to a raw turn when cachedDir is nil, so the
            -- boxed-in spin still works with no heading and stops desyncing one that exists.
            turnLeft()
        end
    end

    return false, "could not determine heading"
end

-- EVERY REASON A STEP CAN BE REFUSED BEFORE IT IS ATTEMPTED, IN ONE PLACE.
--
-- Policy first, because it is free -- coordinates only. Then the world, which costs an inspect.
-- Its own function so forward(), already the most complex thing here, does not carry four decisions
-- that are not about moving.
--
-- "out of bounds" is not in HARD_MOVE_ERRORS, so routing it through moveFailed is the same
-- false, "out of bounds" it returned before -- no log, no yield.
local function stepRefusal(p_Dir, p_X, p_Y, p_Z)
    if p_Dir ~= nil and p_X ~= nil then
        local F = deltas[p_Dir]
        if not mayStep(p_X + F[1], p_Y + F[2], p_Z + F[3]) then
            m_BoundsStops = m_BoundsStops + 1
            return "out of bounds"
        end
    end
    -- NO LAVA REFUSAL. A DRONE CAN BE IN LAVA.
    --
    -- This refused to step into lava on the belief that it destroys the turtle. That belief was
    -- never tested: across every drone log in this world the refusal has fired ZERO times, so it
    -- has never once protected anything -- while making lava an impassable wall that forces
    -- detours and can strand a miner in a cave system it could simply have crossed.
    --
    -- CLAUDE.md has this exact lesson already, from the wired modems that "could not be attached"
    -- and always could: an environment invariant nobody has re-tested is just an old assumption,
    -- and this one cost routing rather than a redesign. If a drone is ever actually lost to lava,
    -- that is evidence, and evidence is what should put the check back.

    -- nil is the PERMIT, not a swallowed failure: this function returns the REASON a step must be
    -- refused, so "no reason" is the only way to say yes. Spelled out because a bare `return nil`
    -- is indistinguishable at a glance from the silent-failure shape that has cost this project
    -- more than any other single mistake -- see the recurring-defect section in CLAUDE.md.
    return nil          -- no reason to refuse: the step may proceed
end

-- THE FOUR THINGS THAT MUST FOLLOW A MOVE THAT ACTUALLY HAPPENED.
--
-- forward, back, up and down each carried their own copy, and the order is not arbitrary: the cache
-- advances FIRST so breadcrumb/detectAll/savePose all describe the cell the drone is now in, and
-- notePlannedStep must see the step the audit will later be asked about. A copy that forgets
-- savePose loses the pose across a reboot; one that forgets detectAll leaves the map describing the
-- cell we left. p_Straight says whether this step is evidence about FACING -- see auditHeading;
-- only forward() is, which is why back and the verticals pass false.
local m_StepMismatches, m_StepMismatchAt = 0, 0
local function stepTaken(p_X, p_Y, p_Z, p_Dx, p_Dy, p_Dz, p_Straight)
    -- COMMIT THE DELTA, NOT THE TARGET. The caller computed p_X from the cache BEFORE its move and
    -- yielded for the animation; if another coroutine (a make-way step, the dock loop) committed a
    -- step meanwhile, writing p_X here threw that step away -- the intent kept both, the cache kept
    -- one, and the next fix read "audit matched (V) yet the fix moved us 1 -- both cannot be right",
    -- fifty-five times in ten minutes in the bay (2026-09-04). The delta is what this step did.
    -- Counted, not printed per step: it fired 206 times in five minutes once the path executor was
    -- following nodes computed before a mid-path fix moved the cache -- which is exactly the case the
    -- delta commit exists for, and not news. One line a minute with the count is.
    if cachedX ~= nil and (cachedX + p_Dx ~= p_X or cachedY + p_Dy ~= p_Y or cachedZ + p_Dz ~= p_Z) then
        m_StepMismatches = m_StepMismatches + 1
        if os.clock() - m_StepMismatchAt >= 60 then
            ptrace(("%d step(s) landed on a cache that had moved since their target was computed -- deltas kept")
                :format(m_StepMismatches))
            m_StepMismatches, m_StepMismatchAt = 0, os.clock()
        end
    end
    cachedX, cachedY, cachedZ = (cachedX or p_X - p_Dx) + p_Dx, (cachedY or p_Y - p_Dy) + p_Dy, (cachedZ or p_Z - p_Dz) + p_Dz
    motionStep(cachedX, cachedY, cachedZ)
    notePlannedStep(p_Dx, p_Dy, p_Dz, p_Straight)
    breadcrumb()
    detectAll()
    savePose()
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

    -- Refuse rather than step out of the world we can operate in, or into something lethal.
    local s_Refusal = stepRefusal(cachedDir, cachedX, cachedY, cachedZ)
    if s_Refusal then return moveFailed(s_Refusal) end
    local D = deltas[cachedDir]--if north, D = {0, 0, -1}
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]--adds corisponding delta to direction
    local idx_pos = x..":"..y..":"..z

    local s_Moved, s_MoveErr = timedMove(turtle.forward)
    if s_Moved then
        stepTaken(x, y, z, D[1], D[2], D[3], true)   -- see auditHeading
        return true
    else
        -- Something stopped us: record it and put it in the DELTA, not just the local cache.
        --
        -- A blocked move is a real observation -- often a better one than a scan, because it is
        -- ground truth from a drone that tried. Writing straight to cachedWorld kept it local
        -- until the next full SavePath, so other drones re-planned into the same wall.
        --
        -- ASK WHAT ACTUALLY STOPPED US. A failed move is not evidence of a block.
        --
        -- This recorded solid unconditionally, reasoning that a wrong entry would be corrected by a
        -- later scan and that re-pathing into the obstacle was the worse cost. That was wrong in a
        -- way that got much worse as the fleet grew: with fourteen drones flying the same corridors,
        -- most failed moves are one drone bumping another, and every one of them wrote a permanent
        -- solid block into the SHARED map at a spot where there is nothing at all. The result is a
        -- map full of blocks hanging in mid-air that do not exist in the world -- visible on /map,
        -- and worse, pathfinding routes around them for ever.
        --
        -- A scan does not reliably correct it either: scans record what they SEE, and a cell that
        -- is genuinely air is only rewritten if a drone happens to scan that exact spot again.
        --
        -- detect() answers the question honestly. A block is a block; anything else is an entity
        -- standing somewhere passable, and the right record for that cell is air.
        local s_PriorBelief = cachedWorld[idx_pos]
        local s_Solid = turtle.detect() and 1 or 0
        cachedWorld[idx_pos] = s_Solid
        noteObservation(idx_pos, s_Solid, s_Solid == 1 and cachedWorldDetail[idx_pos] or nil)

        -- A BLOCKED MOVE IS ALSO EVIDENCE ABOUT OUR OWN POSITION.
        --
        -- If detect() says the cell ahead is EMPTY and the step still failed, the two facts only
        -- reconcile one way: we are not where we think we are. The fleet froze exactly here -- five
        -- drones in provably open air (a whole 9x9 slice of the bay scanned as air, one turtle in
        -- it) reporting forward=false with no reason, while a drone's cached y was one block off
        -- what the server had. Every route it planned, every neighbour it reasoned about and every
        -- deposit square it aimed for was computed from a position that was wrong, so it walked
        -- into things that were not where it thought they were and concluded the world was solid.
        --
        -- Re-fixing costs a GPS round trip and only happens on this contradiction, so it cannot run
        -- hot. Whatever the caller does next is then planned from a position that has been checked.
        -- Re-fix on ANY surprise, not just an empty cell.
        --
        -- Two things contradict our idea of the world: a step into a cell we believe is empty that
        -- fails, and a step into a cell the MAP called air that turns out solid. Both are equally
        -- good evidence that the drone is not where it thinks it is -- which is the one error that
        -- makes every subsequent route, neighbour check and deposit square wrong. Only the first was
        -- checked; the second is the commoner one underground, where dead reckoning runs longest.
        --
        -- A hard refusal is still excluded: it says nothing about position, and re-fixing on it
        -- would burn a GPS round trip per attempt while getting no closer to the real problem.
        -- RATE-LIMITED, OR THE CURE IS WORSE THAN THE DISEASE.
        --
        -- Forcing a fix on EVERY surprising failure looked cheap and was not: a digging drone fails
        -- moves constantly, each forced verifyPosition is a blocking five-second gps.locate, and the
        -- hosts are ordinary computers serving the whole fleet. Six drones doing that in parallel
        -- saturated GPS, the locates began timing out, requireFix() then refused every subsequent
        -- move, and the entire fleet reported itself blocked -- stranded, all at once, by the very
        -- check meant to keep their positions honest.
        --
        -- Once every REFIX_COOLDOWN seconds is enough: drift accumulates over many moves, not one.
        local s_MapSaidAir = (s_PriorBelief == 0)
        local s_MayRefix = (m_LastRefixAt == nil) or ((os.clock() - m_LastRefixAt) > REFIX_COOLDOWN)
        if s_MayRefix and classifyMove(s_MoveErr) ~= "hard" and (s_Solid == 0 or s_MapSaidAir) then
            m_LastRefixAt = os.clock()
            -- verifyPosition returns (true, drift) or (nil, reason) -- NOT coordinates. Reading it
            -- as x,y,z formatted a boolean with %d and threw
            -- "bad argument (number expected, got boolean)" on every failed step into an empty
            -- cell, which crashed the job, requeued the task and left drones shuffling back and
            -- forth. The corrected position is read from the cache afterwards, which is where
            -- verifyPosition actually puts it.
            local s_Ok, s_Drift = verifyPosition(true)
            if s_Ok and type(s_Drift) == "number" and s_Drift > 0 then
                local nx, ny, nz = cachedX, cachedY, cachedZ
                ptrace(("pose was wrong by %d: corrected to %s,%s,%s")
                    :format(s_Drift, tostring(nx), tostring(ny), tostring(nz)))
            end
        end
        return moveFailed(s_MoveErr)
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

    local s_Moved, s_MoveErr = timedMove(turtle.back)
    if s_Moved then
        -- D, not (x - cachedX): the cache is assigned inside stepTaken from the same x,y,z, so that
        -- difference is always zero and back() recorded NO intent while the cache advanced -- the
        -- audit then had a self-inconsistent picture and could neither trust nor blame it. back()
        -- moves opposite to the way we face, so the delta is simply -D.
        stepTaken(x, y, z, -D[1], -D[2], -D[3], false)
        return true
    else
        cachedWorld[idx_pos] = 0.5
        return moveFailed(s_MoveErr)
    end
end

----------------------------------------
-- up
--
-- function: Move the turtle up if possible and put the result in cache
-- return: boolean "success"
--

-- UP AND DOWN ARE THE SAME MOVE, and they had already drifted.
--
-- down() calls detectAll() when the step fails; up() does not. Nothing records which is right, so
-- it is a PARAMETER here rather than silently unified -- picking one would be guessing at a fix
-- under cover of a refactor, and this file is where a wrong guess strands drones.
local function verticalStep(p_Dy, p_Move, p_Inspect, p_Detect, p_LavaWhy, p_DetectAllOnFail)
    if cachedY and not mayStep(cachedX, cachedY + p_Dy, cachedZ) then
        m_BoundsStops = m_BoundsStops + 1
        return false, "out of bounds"
    end
    local D = deltas[p_Dy > 0 and Up or Down]
    local x, y, z = cachedX + D[1], cachedY + D[2], cachedZ + D[3]
    local idx_pos = x..":"..y..":"..z

    -- No lava refusal here either -- see the note in the forward guard. A drone can be in lava, the
    -- check never fired in this world's entire history, and treating lava as a wall is what turned
    -- a crossable hazard into a dead end for anything descending a shaft.
    local s_Moved, s_MoveErr = p_Move()
    if s_Moved then
        stepTaken(x, y, z, 0, p_Dy, 0, false)  -- vertical: says nothing about facing, but counts
        return true
    else
        if p_DetectAllOnFail then detectAll() end
        cachedWorld[idx_pos] = (p_Detect() and 1 or 0.5)
        return moveFailed(s_MoveErr)
    end
end

function up()
    -- BOTH REFRESH NOW, AND THE UPWARD CASE IS THE ONE THAT NEEDED IT MOST.
    --
    -- These two drifted: down() refreshed the block cache when a step failed and up() never did.
    -- That difference was almost certainly nobody's decision -- one of them got the fix.
    --
    -- Blocked upward is the state this fleet gets stuck in. A buried drone's whole recovery is
    -- "climb toward the surface", and it decides whether it is walled in from what it believes is
    -- overhead. Refusing to look, on the one step that just failed, is how a drone reports "walled
    -- in with a pickaxe and still rose 0" while a probe of turtle.digUp() answers true -- measured
    -- on D57, entombed at y=50 for an hour.
    --
    -- A detectAll() costs one tick and only happens when a move ALREADY failed, so the cost lands
    -- exactly where the information is worth most.
    return verticalStep(1, turtle.up, turtle.inspectUp, turtle.detectUp, "lava above", true)
end

----------------------------------------
-- down
--
-- function: Move the turtle down if possible and put the result in cache
-- return: boolean "success"
--

function down()
    -- The one that matters most: a shaft descends, and a lava lake is a floor you fall into.
    -- true: down() has always called detectAll() on a failed step. See verticalStep.
    return verticalStep(-1, turtle.down, turtle.inspectDown, turtle.detectDown, "lava below", true)
end

----------------------------------------
-- turnLeft
--
-- function: Turn the turtle to the left and put the result in cache
-- return: boolean "success"
--

-- ONE TURN, TWO DIRECTIONS. p_Delta is what the heading gains: +1 left, +3 right.
--
-- turnLeft and turnRight were the same eleven lines twice over, differing only in which turtle call
-- and which delta -- and heading is the ONE quantity that never self-corrects, so a fix landing in
-- one of them and not the other is the expensive kind of drift. See the note in turnLeft.
local function turnAndTrack(p_Turn, p_Delta)
    -- A turn with no known heading is arithmetic on nil, and it killed the drone --
    -- miners crash-looped on "attempt to perform arithmetic on upvalue 'cachedDir'".
    -- Turning is still useful without a heading (it is how one is derived), so do the
    -- turn and leave the cache unknown rather than throwing.
    if cachedDir == nil then p_Turn() detectAll() return true end
    local s_Turned, s_Err = p_Turn()
    if not s_Turned then
        detectAll()
        return false, s_Err or "turn refused"
    end
    cachedDir = (cachedDir + p_Delta) % 4
    noteTurn()          -- the audit can only invert a run that never turned; see auditHeading
    detectAll()
    savePose(true)   -- heading changed: worth writing immediately
    return true
end

function turnLeft()
    -- TURN FIRST, THEN BELIEVE IT.
    --
    -- This updated cachedDir BEFORE calling turtle.turnLeft() and threw the result away, so a turn
    -- that did not happen left the heading permanently 90 degrees wrong -- and savePose wrote that
    -- belief to disk on the way out, so a reboot could not clear it either. forward() has always
    -- got this right ("the cache only advances when turtle.forward() returned true", line 761); the
    -- turns never did, which left the ONE quantity that never self-corrects as the only one updated
    -- on faith.
    --
    -- D14's log is what this looks like from outside: "bookkeeping disagrees with GPS since the
    -- last fix: wanted -1,0,-47 got 48,0,-2" -- forty-eight moves flown at ninety degrees to the
    -- intended course, ending 83 blocks out, reporting progress the whole way. Every job it was
    -- given ended "tower unreachable", so TaskMan reclaimed the task, gave it to the next drone,
    -- and the fleet churned instead of working.
    return turnAndTrack(turtle.turnLeft, 1)
end

----------------------------------------
-- turnRight
--
-- function: Turn the turtle to the right and put the result in cache
-- return: boolean "success"
--

function turnRight()
    -- TURN FIRST, THEN BELIEVE IT. See the note in turnLeft -- same bug, same fix.
    return turnAndTrack(turtle.turnRight, 3)
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
            -- lua-hygiene: allow (ensureHeading has just failed, so cachedDir is still nil and
            -- stays nil -- "turning blind beats dying", and there is no belief to falsify.)
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

-- ABORT WHATEVER MOVEMENT IS RUNNING.
--
-- Set by anything that needs the drone to stop travelling RIGHT NOW -- above all the fuel
-- watchdog, which is useless if it cannot interrupt the flight that is draining the tank. Cleared
-- by StartExec, which TaskEnd already calls at the end of every task, so a stray break cannot
-- leave a drone permanently unable to move.
local breakExec = false

function BreakExec()
    breakExec = true
end
function StartExec()
    breakExec = false
end
-- Checked by every long-running mover, and SELF-CLEARING.
--
-- I made this non-clearing so that one abort could not be swallowed by moveTo while the digTo after
-- it carried on. That trade was wrong, and it bricked drones: any path that sets the flag and then
-- fails to clear it -- an error between BreakExec and StartExec, a job that unwinds a different way
-- -- leaves every mover returning "aborted" instantly, for ever. D3 cut itself thirty blocks up to
-- open sky and then could not travel one block, because moveTo, digTo and flyTo all refused before
-- taking a step. A drone that cannot move is a far worse failure than an abort that arrives one
-- call late, and the fuel watchdog -- the only real user of this -- re-checks every 20 seconds
-- anyway, so a missed abort costs one cycle and a wedged flag costs the drone.
local function aborted()
    if breakExec then
        breakExec = false
        return true
    end
    return false
end
-- moveTo
--
-- function: Move the turtle to the choosen coordinates in the world
-- input: X, Y, Z and direction of the goal
-- return: boolean "success"
--

-- SEND WHAT CHANGED, NOT THE WHOLE MAP.
--
-- This shipped the drone's ENTIRE cachedWorld and cachedWorldDetail to MapServer, with a fifteen
-- second budget and three retries, every time a move was blocked -- which for a mining drone is
-- constantly. One drone doing that is wasteful; twenty-three of them saturates the shared rednet
-- channel, and messages start being dropped. That is why drones parked AT THE BASE were showing
-- 200+ seconds silent: not out of range, not crashed, just unable to get a heartbeat through the
-- traffic their own path-saving was generating.
--
-- takeWorldDelta already exists and is what UploadWorld uses: the cells observed since the last
-- push, typically a handful. The delta is drained on read, so nothing is sent twice.
--
-- It also used to do `cachedWorld = {}` at the end, throwing away everything the drone knew about
-- its surroundings on every blocked move. That is why drones re-path into the same wall, and it
-- defeats the map check the miners now use to decide whether a side wall is worth turning for.
function SavePath()
    local s_World, s_Detail, s_Count = takeWorldDelta()
    if s_Count == 0 then return true end

    local s_Request = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "UpdatePath",
        {id = os.getComputerID(), cachedWorld = s_World, cachedWorldDetail = s_Detail})
    -- One attempt, short budget. These are observations, not a request anyone is waiting on, and
    -- retrying them is what turns a busy MapServer into an unreachable one.
    local s_Ok = PowNet.sendAndWaitForResponse("MapServer", s_Request, nil, 3, 1)
    if not s_Ok then
        -- Keep them rather than lose them; the next push carries them.
        for k, v in pairs(s_World) do noteObservation(k, v, s_Detail[k]) end
        return false
    end
    return true
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

-- Manhattan distance within which moveTo walks it locally instead of asking MapServer for a path.
--
-- Sized to the base: the storage row, the dock tower and the craft spots all sit within a dozen
-- blocks of each other, and that traffic is almost all of the pathfinder's load — the same few
-- short hops, re-requested by eight drones, continuously. Beyond this a real route may need the
-- surveyed map (round an unmapped hill, down a shaft), so the server keeps that work.
--
-- Deliberately modest. flyTo is greedy: it gains altitude to clear obstacles, which is cheap over
-- a few blocks and wasteful over fifty. If the hop turns out to be harder than it looked, flyTo
-- fails inside PATH_LOCAL_STEPS and the original GetPath runs anyway.
local PATH_LOCAL_RADIUS = 12
local PATH_LOCAL_STEPS  = 48

-- Try to cover a short hop locally. True if we arrived; false means "ask MapServer after all".
--
-- A function rather than two lines inline because moveTo is already one of the largest things in
-- this file and every branch there is charged against the complexity gate. Declared here, above
-- moveTo, because a `local` used above its declaration is a nil GLOBAL in Lua -- silently -- which
-- is the single most expensive mistake in this codebase.
local function localHop(p_X, p_Y, p_Z, p_Dist)
    if p_Dist > PATH_LOCAL_RADIUS then return false end
    return flyTo(p_X, p_Y, p_Z, PATH_LOCAL_STEPS) ~= false
end

-- Path ONE short hop. Renamed from moveTo: this asks MapServer to plan the entire route in a
-- single a_star, which is fine over a chunk and hopeless over a hundred blocks -- see moveTo below.
-- p_Dig: may this leg cut through ordinary rock? The route still comes from the pathfinder either
-- way -- digging is a PASSABILITY MODE, not a different way of travelling. digTo used to be a
-- separate greedy axis-walker that consulted no map at all, which is why a drone could walk into the
-- same chest for ever no matter how many times the fleet recorded it.
-- GAME SECONDS, NOT REAL ONES: rednet's timeout is a tick timer. At /tick rate 200 six game seconds
-- are 0.6 real seconds and "did not answer" came back (36 in ten minutes, 2026-09-04 02:46) while
-- MapServer answered every request it heard in 0-2 ms. Twenty game seconds is two real seconds at
-- 10x and twenty at 1x -- long enough either way, and a drone waiting is a drone not burning fuel.
local PATH_REPLY_S = 20
local function moveLeg(_targetX, _targetY, _targetZ, _targetDir, changeDir, discover, p_Dig)
    changeDir = changeDir or false
    local s_Replans, s_Stalls, s_BestDist = 0, 0, nil
    while cachedX ~= _targetX or cachedY ~= _targetY or cachedZ ~= _targetZ do
        if cachedX == nil then return false, "lost the position fix part-way" end
        s_Replans = s_Replans + 1
        if s_Replans > MOVE_MAX_REPLANS then
            ptrace("moveTo: giving up after " .. s_Replans .. " replans")
            return false, "unreachable"
        end
        local s_Dist = math.abs(cachedX - _targetX)
                     + math.abs(cachedY - _targetY)
                     + math.abs(cachedZ - _targetZ)
        -- PROGRESS IS MEASURED AGAINST THE BEST WE HAVE DONE, NOT AGAINST THE LAST STEP.
        --
        -- This compared each replan with the one before it, so a drone bouncing between two cells
        -- -- step to B (closer: counter reset), blocked, replan, step back to A (further: one
        -- stall), step to B (closer: reset again) -- never accumulated the four stalls that end
        -- the leg, and ran all forty replans instead. Each replan is a GetPath round trip plus one
        -- move, so from outside it is a drone pacing one block forward and back every two seconds.
        -- Traced on D40 for forty seconds straight with nothing in its log but distress lines, and
        -- it is where the "twenty fuel every thirty seconds, going nowhere" of every distressed
        -- drone went. Against the best distance so far the same bounce is four stalls and a fast,
        -- honest "no progress" -- the caller then widens or gives up instead of spending a tank here.
        if s_BestDist ~= nil and s_Dist >= s_BestDist then
            s_Stalls = s_Stalls + 1
            if s_Stalls >= MOVE_MAX_STALLS then
                ptrace("moveTo: no progress toward " .. _targetX .. "," .. _targetY .. "," .. _targetZ)
                return false, "no progress"
            end
        else
            s_Stalls = 0
            s_BestDist = s_Dist
        end
        -- DO NOT ASK A SERVER HOW TO TAKE A STEP YOU CAN SEE.
        --
        -- Every iteration of this loop was a GetPath round trip to MapServer, and MapServer is one
        -- single-threaded computer holding 425,267 cells and 261,824 named blocks for the whole
        -- fleet. Eight drones replanning short hops around the bay saturated it: 153 timeouts were
        -- logged in a single session, bursting at 17 a minute, each one costing the full request
        -- timeout and then surfacing as "could not reach -479,65,78" — an EMPTY block four steps
        -- away, verified air by rcon at the time.
        --
        -- Everything downstream followed from that. Drones could not reach storage, so they could
        -- not deposit; not depositing meant not refuelling; gathers never started, so wood never
        -- arrived and the charcoal chain stayed at 2 logs all session. It also explains why the
        -- fleet always worked for a few minutes after a reboot and then decayed — drones start
        -- scattered with short paths and then converge on the bay, where every request contends.
        --
        -- A* over a surveyed map earns its cost across a settlement. It earns nothing for a hop the
        -- drone could walk blind: flyTo is greedy, local, and asks nobody. So try that first for
        -- anything close, and keep MapServer for the routes that actually need routing. On failure
        -- we fall through to the request exactly as before, so nothing that used to work stops.
        if localHop(_targetX, _targetY, _targetZ, s_Dist) then return true end

        --TODO: NETWORK
        -- Slot 8 is `priority`, which this caller does not use; slot 9 is the dig mode. Positional
        -- because that is the shape OnGetPath already reads.
        local s_Request = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetPath",
            {cachedX, cachedY, cachedZ, _targetX, _targetY, _targetZ, discover, nil, p_Dig and true or nil})
        -- SIX SECONDS, NOT ONE. PowNet's default reply window is REDNET_TIMEOUT = 1 s of real time.
        -- A* on MapServer yields every 200 nodes and may expand 20,000, i.e. up to a hundred ticks of
        -- yields before it answers, behind whatever else the one computer is doing for six other
        -- drones. Nineteen "did not answer" in ten minutes were requests that were still being worked
        -- when the drone gave up and flew blind instead (2026-09-04). Waiting costs nothing; the
        -- blind flight cost the fuel.
        local s_Response = PowNet.sendAndWaitForResponse("MapServer", s_Request, nil, PATH_REPLY_S)
        if (not s_Response) then
            -- SAY IT OUT LOUD, AND DO NOT KEEP GRINDING.
            --
            -- A bare `false` here surfaced as "GoTo FAILED: nil", which is the least useful thing a
            -- failing recall can report. Worse, the caller treats it as an ordinary blocked leg:
            -- moveTo widens its horizon and tries again, up to 96 legs, each paying the request
            -- timeout -- so a MapServer that is merely BUSY turns into a drone that stands in open
            -- air, silent, for minutes. D3 froze exactly that way with clear air on all six sides,
            -- and it reads as a wedged drone rather than a starved service.
            --
            -- Printing marks it in the drone's own log; the distinct reason lets moveTo give up
            -- immediately instead of mistaking congestion for terrain.
            ptrace("pathfinder did not answer -- MapServer may be overloaded")
            return false, "pathfinder unavailable"
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
            if aborted() then
                ptrace("Stopped exec")
                return false, "aborted"
            end
            -- The path was planned through cells the router believes are diggable, so meeting rock
            -- is expected rather than a failure. Cut it and take the step; anything we are NOT
            -- allowed to break is never on the route in the first place, because the map records it
            -- as forbidden and a_star will not plan through that at any passability.
            if dir == Up then
                if not up() then
                    if p_Dig and digGuarded(turtle.digUp, turtle.detectUp, turtle.inspectUp,
                                            cachedX..":"..(cachedY+1)..":"..cachedZ) and up() then
                        -- cut through and carried on
                    else
                        SavePath()
                        break
                    end
                end
            elseif dir == Down then
                if not down() then
                    if p_Dig and digGuarded(turtle.digDown, turtle.detectDown, turtle.inspectDown,
                                            cachedX..":"..(cachedY-1)..":"..cachedZ) and down() then
                        -- cut through and carried on
                    else
                        SavePath()
                        break
                    end
                end
            else
                turnTo(dir)
                if not forward() then
                    local D = deltas[cachedDir]
                    local s_Ahead = D and ((cachedX+D[1])..":"..(cachedY+D[2])..":"..(cachedZ+D[3]))
                    if p_Dig and digGuarded(turtle.dig, turtle.detect, turtle.inspect, s_Ahead)
                       and forward() then
                        -- cut through and carried on
                    else
                        SavePath()
                        break
                    end
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
        -- flyTo never checked this, and flyTo is where the fuel goes. A scout that broke off to
        -- refuel while climbing to cruising height kept climbing for another 143 seconds, failed
        -- the survey it had already abandoned, and only then went for fuel -- by which point it had
        -- none. The watchdog fired correctly at 343 and again at 90; neither could stop the flight.
        if aborted() then return false, "aborted" end

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
        -- Guarded: bedrock, or something of ours that must not be broken.
        if not digGuarded(turtle.dig, turtle.detect, turtle.inspect) then return false end
        s_Tries = s_Tries + 1
        if s_Tries > DIG_RETRY then return false end
        os.sleep(0.05)                                   -- let falling blocks settle before retrying
    end
    return true
end

-- digTo is moveTo with a different PASSABILITY RULE. It is not a different way of travelling.
--
-- It used to be a separate greedy axis-walker -- horizontal first, then vertical, consulting no map
-- at all -- and that single fact caused most of a day's failures: a drone under the storage bay rose
-- into the chest above it, refused to mine it (correctly), and tried again, for ever, no matter how
-- many times the fleet had recorded that chest. The map knew. The mover never asked.
--
-- Now there is ONE implementation of "get from here to there": plan a route, follow it, replan when
-- it fails. Digging only changes which cells the planner may route through -- ordinary rock yes,
-- anything recorded as forbidden never. A new movement rule is a new flag on the planner, not a
-- fourth copy of the walking loop.
--
-- _maxSteps is accepted for compatibility with the old signature and ignored: the leg and replan
-- limits inside moveTo already bound the work, and they bound it by PROGRESS rather than by digs.
function digTo(_tx, _ty, _tz, _maxSteps)
    if cachedX == nil then return false, "no position fix" end
    if not canDig() then return false, "no pickaxe: this drone cannot make a path" end
    _tx, _ty, _tz = _tx or cachedX, _ty or cachedY, _tz or cachedZ
    return moveTo(_tx, _ty, _tz, nil, false, nil, true)
end

-- HOW FAR AHEAD TO PLAN, AND WHEN TO GIVE UP.
--
-- a_star over a short horizon is cheap and usually right, but a short horizon is also blind: a drone
-- in a cave whose exit leads AWAY from the target keeps choosing the deeper passage, because from
-- sixteen blocks up the road that is the better-looking move -- and it cannot backtrack, because
-- backtracking looks like going the wrong way.
--
-- Widening the horizon is what lets it escape: a_star over a 64-block box CAN see the way out and
-- will happily route backwards to take it. So the horizon is adaptive -- cheap searches while things
-- are going well, expensive ones only when the drone is in trouble, which is the only time they are
-- worth paying for.
local MOVE_LEG_MIN = 16      -- one chunk
local MOVE_LEG_MAX = 96      -- wide enough to see out of most dead ends
local MOVE_STUCK   = 4       -- legs without progress before giving up

-- THE one implementation of "get from here to there". p_Dig only changes which cells the PLANNER is
-- allowed to route through; the travelling itself is identical, which is the entire point.
function moveTo(_targetX, _targetY, _targetZ, _targetDir, changeDir, discover, p_Dig)
    -- A DRY DRONE DOES NOT TRY. Every leg used to plan, turn to face the first step, have the step
    -- refused ("MOVE REFUSED: Out of fuel", 50-90 times a minute), replan and turn again: D31 spent
    -- a window of 42 turns and 0 moves spinning at the bay. Turning is free, so nothing stopped it.
    -- There is no route around an empty tank; say so before the first turn and let relief come.
    if turtle.getFuelLevel() == 0 then return false, "out of fuel" end
    if cachedX == nil then return false, "no position fix" end
    if _targetX == nil or _targetY == nil or _targetZ == nil then
        return false, "incomplete destination"
    end

    local function remaining()
        -- LOSING THE FIX MID-JOURNEY IS ROUTINE, NOT A CRASH.
        --
        -- The nil check at the top of moveTo only covers the moment it is called. cachedX can go
        -- nil part-way -- descending out of GPS coverage does exactly that -- and this then did
        -- arithmetic on nil and threw. A gather job holding 32 located copper targets died on
        -- "attempt to perform arithmetic on upvalue 'cachedX' (a nil value)", which reads like a
        -- corrupted drone rather than what it is: an expected loss of signal, unhandled.
        if cachedX == nil or cachedY == nil or cachedZ == nil then return nil end
        return math.abs(_targetX - cachedX) + math.abs(_targetY - cachedY) + math.abs(_targetZ - cachedZ)
    end

    local s_Legs, s_Leg, s_NoProgress = 0, MOVE_LEG_MIN, 0
    local s_Best = remaining() or math.huge

    while cachedX ~= _targetX or cachedY ~= _targetY or cachedZ ~= _targetZ do
        s_Legs = s_Legs + 1
        if s_Legs > 96 then return false, "gave up after " .. s_Legs .. " legs" end

        -- remaining() returns nil once the fix is gone, and every use of it is a comparison --
        -- which is how "attempt to compare nil with number" replaced the arithmetic crash it was
        -- meant to fix. Losing the fix part-way is an ordinary outcome and gets an ordinary return.
        local s_Before = remaining()
        if s_Before == nil then return false, "lost the position fix part-way" end
        if s_Before <= s_Leg then
            local s_Ok, s_Why = moveLeg(_targetX, _targetY, _targetZ, _targetDir, changeDir, discover, p_Dig)
            if s_Ok then return true end
            -- A STARVED PATHFINDER IS NOT A DEAD END, AND WIDENING THE SEARCH CANNOT HELP.
            --
            -- Every failure here was treated as terrain: widen the horizon, try again, up to 96
            -- legs. When the cause is a MapServer too busy to answer, that is 96 timeouts spent
            -- standing still and saying nothing -- which is what a drone frozen in open air looks
            -- like from outside. Give up at once and let the caller decide; the fallbacks above
            -- TravelTo can still fly or dig, and they need no server at all.
            if s_Why == "pathfinder unavailable" then return false, s_Why end
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
            local s_Ok = moveLeg(wx, wy, wz, nil, false, discover, p_Dig)
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

-- Correct the heading ALONE, leaving the position untouched.
--
-- setLocation() is the only other way in and it demands x/y/z, so a caller that has learned which
-- way the drone faces but not where it is had no way to record it -- and that is precisely the
-- situation out of GPS range, where the mesh can settle the heading from range deltas long before
-- it can pin the position. Heading is also the half that never self-corrects, so it is the half
-- worth writing down the moment it is known.
function setHeading(p_Dir)
    if type(p_Dir) ~= "number" or p_Dir < 0 or p_Dir > 3 then return false end
    cachedDir = p_Dir
    savePose(true)            -- forced: this is exactly the fact that must survive a restart
    ptrace("heading set to " .. tostring(shortNames[p_Dir]) .. " by the mesh")
    return true
end

function setLocation(x, y, z, d)
    m_MoveSeq = m_MoveSeq + 1
    -- AN ASSERTION IS NOT A MOVE, AND THE AUDIT MUST BE TOLD.
    --
    -- The audit measures "displacement we believe we made SINCE THE LAST FIX" against what GPS
    -- later says we actually made. setLocation teleports the cache and left both anchors alone, so
    -- every subsequent comparison ran from a position the drone no longer claimed. The mesh writes
    -- here every time a drone is out of GPS range -- a trilaterated fix good to about ten blocks --
    -- and ten blocks of unaccounted jump is far more than the audit's tolerance.
    --
    -- The result was in every long-range log, hundreds of times: "audit matched (-17,-5,1) yet the
    -- fix moved us 5 -- both cannot be right". Both WERE right. The heading was fine and the step
    -- accounting was fine; the anchor they were measured from had been moved out from under them.
    --
    -- It did not stop at a confusing line. That phantom drift is what trips "drift is too big for
    -- dead reckoning -- re-checking the heading", which steps the turtle forward and back to re-
    -- derive a heading that was never wrong. Out of range that fired continuously: the fuel went on
    -- probe moves provoked by our own bookkeeping, and a blocked or interrupted probe left the
    -- drone worse off than before it started.
    --
    -- Reset the anchor to what we are now asserting. m_LastFix is deliberately NOT set: a mesh
    -- position is not a verified one, and must not open the gate on map observations.
    resetAudit(x, y, z)
    cachedX, cachedY, cachedZ = x, y, z
    -- THE MESH KNOWS WHERE, NOT WHICH WAY.
    --
    -- Every out-of-range recovery calls this with d = nil on purpose -- a trilaterated fix has a
    -- position and no heading -- and the ladder below ran string.lower(nil) on it. So the one path
    -- that gives a drone underground its position back threw "bad argument (string expected, got
    -- nil)" every time it was tried, logged as "FAILED to adopt the meshed position", and the drone
    -- carried on with the dead-reckoned position it had just been told was wrong. A missing heading
    -- means "keep the one you have", which is what every other caller means by it too.
    if d == nil then
        if isLama and cachedDir ~= nil then lama.setPosition(x, y, z, longNames[cachedDir]) end
        return cachedX, cachedY, cachedZ, cachedDir
    end
    -- d arrives as either the numeric constant or the spelled-out name, in any case. longNames and
    -- HEADINGS above ARE that mapping -- HEADINGS' own comment says it exists "so callers stop
    -- writing their own copy" -- and this was an eight-branch ladder answering it a fourth time,
    -- alongside the ones in setLocationFromLAMA and locate. Heading is the one quantity that never
    -- self-corrects, so a ladder that drifts from the others walks a drone ninety degrees off course
    -- while every reading looks healthy. HEADINGS[name] can be 0 (North), which is TRUTHY in Lua,
    -- so the `and` below is safe.
    local s_Name = longNames[d] or (HEADINGS[string.lower(d)] and string.lower(d))
    if s_Name == nil then
        ptrace("unknown direction")
        return false
    end
    d = s_Name
    cachedDir = HEADINGS[s_Name]
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
            ptrace("No modem found")
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

-- REMEMBER WHERE WE WERE FACING, BECAUSE UNDERGROUND IT CANNOT BE REDERIVED.
--
-- Heading is worked out by stepping one block and comparing GPS readings, so below ground it cannot
-- be worked out at all. A drone that reboots down a shaft -- which happens on every code deploy --
-- comes up with no heading and cannot move: "bore blocked on line 1 step 1 -- move: could not
-- determine heading". Position has the same problem and the climb-for-fix loop solves it by
-- surfacing, which costs the whole descent.
--
-- Neither needs rederiving if they were never forgotten. pgps already tracks both through every move
-- and turn; writing them down makes that survive a reboot. Throttled, because a file write per step
-- is a real cost and the pose only has to be good enough to resume from -- a stale entry is
-- corrected by the first GPS fix the drone gets.
local m_PoseDirty = 0

function savePose(p_Force)
    if cachedX == nil or cachedDir == nil then return end
    m_PoseDirty = m_PoseDirty + 1
    if not p_Force and m_PoseDirty < 8 then return end
    m_PoseDirty = 0
    local h = fs.open(POSE_FILE, "w")
    if not h then return end
    h.write(("%d %d %d %d"):format(cachedX, cachedY, cachedZ, cachedDir))
    h.close()
end

function loadPose()
    if not fs.exists(POSE_FILE) then return false end
    local h = fs.open(POSE_FILE, "r")
    if not h then return false end
    local s_Line = h.readLine()
    h.close()
    if type(s_Line) ~= "string" then return false end
    local x, y, z, d = s_Line:match("(-?%d+) (-?%d+) (-?%d+) (%d+)")
    if x == nil then return false end
    cachedX, cachedY, cachedZ = tonumber(x), tonumber(y), tonumber(z)
    cachedDir = tonumber(d)
    -- Same rule as setLocation: this asserts a position rather than moving to one, so the audit
    -- anchor starts here. A restored pose with a stale anchor would charge the drone for a journey
    -- taken before the reboot.
    resetAudit(cachedX, cachedY, cachedZ)
    ptrace(("restored pose %d,%d,%d facing %s"):format(cachedX, cachedY, cachedZ,
        tostring(shortNames[cachedDir])))
    return true
end

function setLocationFromGPS()
    if startGPS() then
        -- get the current position
        cachedX, cachedY, cachedZ  = gps.locate(4, false)
        -- Integer block coordinates -- see the note in verifyPosition.
        if cachedX then
            cachedX, cachedY, cachedZ = math.floor(cachedX), math.floor(cachedY), math.floor(cachedZ)
            -- Anchor here, BEFORE the two probe steps below. Those steps call notePlannedStep, so
            -- the intent they record is measured from this fix -- which is the whole point of the
            -- audit. Leaving the previous anchor in place made the probe itself look like drift.
            resetAudit(cachedX, cachedY, cachedZ)
        end

        -- NO FIX IS AN ANSWER, NOT A CRASH.
        --
        -- Without this the code below compared `newZ < cachedZ` against nil and threw. DroneLogic
        -- died, DroneBoot caught it and rebooted, and the drone looped for ever -- re-fetching its
        -- modules on every pass, so it looked like a perfectly healthy machine that simply never
        -- registered. D3 sat in that loop for hours and nothing anywhere said "no GPS".
        if cachedX == nil then
            -- Underground, or out of coverage. If we wrote a pose down before, resume from it
            -- rather than declaring ourselves lost -- it is exactly the situation it exists for.
            if loadPose() then
                ptrace("no GPS fix -- resuming from the saved pose")
                return cachedX, cachedY, cachedZ, cachedDir
            end
            ptrace("no GPS fix -- cannot establish position")
            return nil, nil, nil
        end

        -- DO NOT THROW AWAY A HEADING YOU MIGHT NOT BE ABLE TO REBUILD.
        --
        -- This cleared cachedDir and then tried to re-derive it by stepping and comparing GPS
        -- readings -- which underground cannot work, because there is no GPS to compare. So a drone
        -- that already KNEW which way it was facing came out of this not knowing, and then could not
        -- move at all: "bore blocked on line 1 step 1 -- move: could not determine heading".
        --
        -- Keep the old value and put it back if the derivation fails. Deriving is an improvement,
        -- not a prerequisite, and pgps tracks heading through every turn anyway.
        local s_PrevDir = cachedDir
        local d = cachedDir or nil
        cachedDir = nil
        local s_Turns = 0                 -- raw left turns made below, so a kept heading can be corrected

        -- determine the current direction
        for tries = 0, 3 do  -- try to move in one direction
            if(turtle.getFuelLevel() == 0) then
                ptrace("Out of fuel")
                return
            end
            local s_Fwd, s_FwdErr = timedMove(turtle.forward)
            if not s_Fwd and classifyMove(s_FwdErr) == "hard" then
                -- Same lesson as ensureHeading: a refusal that applies everywhere must be named,
                -- not retried in the other three directions and then reported as "boxed in".
                moveFailed(s_FwdErr)
                return cachedX, cachedY, cachedZ
            end
            if s_Fwd then
                local newX, newY, newZ = gps.locate(4, false) -- get the new position
                -- Checked, for the reason spelled out in ensureHeading: an unchecked back() leaves
                -- the drone one block from where it believes it is, every time something is behind
                -- it, and the error accumulates until the drone is tens of blocks adrift and still
                -- confident. This copy runs at BOOT, so it drifts a fresh block on every restart.
                local s_Back = timedMove(turtle.back)
                if not s_Back then
                    if newX ~= nil then
                        cachedX, cachedY, cachedZ = math.floor(newX), math.floor(newY), math.floor(newZ)
                    end
                    savePose()
                end

                -- The fix can vanish between the two calls -- a drone at the edge of coverage gets
                -- one and not the next. Bail rather than compare against nil.
                if newX == nil or newZ == nil then
                    ptrace("lost GPS while establishing heading")
                    return cachedX, cachedY, cachedZ
                end

                -- deduce the current direction -- same four comparisons as ensureHeading, so it is
                -- the same function now. They had already drifted apart once.
                cachedDir = dirFromStep(newX, newZ) or cachedDir
                d = longNames[cachedDir] or d

                -- Cancel out the tries. cachedDir can still be nil here if the drone moved but
                -- the coordinates did not change in any axis we test, and arithmetic on nil throws
                -- from inside the one routine every drone runs at boot.
                if cachedDir == nil then
                    ptrace("moved but could not deduce heading")
                    break
                end
                turnTo((cachedDir - tries + 4) % 4)

                -- exit the loop
                break

            else -- try in another direction
                -- No `tries = tries + 1` here. A numeric-for control variable is a fresh local on
                -- every iteration, so assigning to it does nothing at all in CC's Lua -- and it is
                -- an outright error under Lua 5.4, which is what any syntax check runs. It read as
                -- if it drove the loop; it never did. The loop counts 0..3 by itself, and `tries`
                -- is already the number of left turns taken, which is what line 1599 needs to undo
                -- them.
                --
                -- lua-hygiene: allow (cachedDir was cleared to nil above so this probe can re-derive
                -- it from GPS; the turns are counted by `tries` and undone by turnTo afterwards.)
                turtle.turnLeft()
                s_Turns = s_Turns + 1
            end
        end

        -- THE TURTLE HAS TURNED SINCE "THE ONE WE HAD". The comment above says the turns are undone
        -- by turnTo afterwards -- only on the SUCCESS path. When the loop broke out ("moved but could
        -- not deduce heading") after k raw turtle.turnLeft() calls, restoring s_PrevDir as-is left the
        -- drone facing k quarter-turns away from what it believed, and the next leg walked the wrong
        -- way until GPS caught it: "heading was W, we actually travelled E". A left turn is +1 in
        -- HEADINGS (north 0, west 1, south 2, east 3), the same as turnAndTrack.
        if cachedDir == nil and s_PrevDir ~= nil then
            cachedDir = (s_PrevDir + s_Turns) % 4
            ptrace(("could not re-derive heading -- keeping the one we had, corrected for %d raw turn(s)")
                :format(s_Turns))
        end

        if cachedDir == nil then
            -- KEEP THE POSITION. HEADING IS THE OTHER HALF OF THE JOB.
            --
            -- This returned a bare `false`, so a drone that knew exactly where it was but could not
            -- work out which way it faced threw the position away too. The caller does
            -- `x, y, z = pgps.setLocationFromGPS()`, so x became FALSE -- not nil, which matters,
            -- because every guard downstream tests `== nil` and false sails straight through them.
            -- The drone then registered with no position, reported itself stuck, and sat there with
            -- a working GPS fix it had already discarded.
            --
            -- Heading is recoverable later: ensureHeading retries on every move, and a drone that
            -- knows where it is can be dispatched, rescued and drawn on the map meanwhile. Position
            -- and heading fail independently and should be returned independently.
            ptrace("position established but heading unknown -- will re-derive on the next move")
            if isLama then--TODO: put lama direction
            else
                return cachedX, cachedY, cachedZ, nil
            end
        end


        -- Return the current turtle position
        if isLama then
            lama.setPosition(cachedX, cachedY, cachedZ, d)
        end
        return cachedX, cachedY, cachedZ, cachedDir
    else
        ptrace("no GPS signal")
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
        local d
        cachedX, cachedY, cachedZ, d = lama.getPosition() --last resort if gps fails, get direction from Lama
        -- By NAME, never by number: LAMA rotates the opposite way round. HEADINGS is the seam.
        cachedDir = HEADINGS[d]
        if cachedDir == nil then
            ptrace("could not get direction from lama")
            return false
        end
        return true
    else
        ptrace("no lama")
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
        local d = HEADINGS[f]      -- by NAME: LAMA rotates the other way round
        if d == nil then
            return cachedX, cachedY, cachedZ, cachedDir
        end
        cachedX, cachedY, cachedZ, cachedDir = x, y, z, d
        return x, y, z, d
    else
        return cachedX, cachedY, cachedZ, cachedDir
    end
end
-- TEST SEAM (as in TaskMan.lua): hq/test/lua/run.lua loads this file under a stub world with
-- HiveMindTest set and reads the motion counters through it. In the world HiveMindTest is nil and
-- this does nothing.
if HiveMindTest ~= nil then
    HiveMindTest.pgps = {motionWindow = motionWindow, motionReset = motionReset, motionCallers = motionCallers}
end
