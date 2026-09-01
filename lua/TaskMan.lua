--DroneMan
--Goal: Handle drones and their status

-- Find the monitor at render time, not once at load, and tolerate not having one.
--
-- This was `peripheral.wrap("left")` evaluated once when the module loaded, and every Render call
-- dereferenced the result. When the monitor block went missing the handle went nil and the whole
-- server died -- DroneMan, the thing that hands out drone identities and answers heartbeats, was
-- taken down by a display block disappearing. A monitor is cosmetic; it must never be load-bearing.
--
-- Re-finding also means a monitor placed AFTER boot starts working without a reboot.
local function monitor()
    local m = peripheral.wrap("left")
    if m and m.write then return m end
    return PowNet.Monitor()
end
-- dig.lua, with the extension. os.loadAPI strips .lua when it names the API, so this still binds
-- as `dig` -- and asking for the real filename removes a hidden deploy step: the old world only
-- worked because something renamed dig.lua to dig on the way in, and a fresh deploy of the repo as
-- it stands died with "Failed to load API dig due to File not found".
print(os.loadAPI("ServerTasks/dig.lua"))
Log("Starting...")

function Init()
    if DATA["tasks"] == nil then
        DATA["tasks"] = {}
    end
    if DATA["lastTask"] == nil then
        DATA["lastTask"] = 1
    end
end






function OnAbort()
    if(not executing) then
        return false
    end
    print("Aborting...")
    pgps.BreakExec()
    return true, "Aborted"
end

function OnAddTask(p_ID, p_Message)
    local s_TaskID = DATA["lastTask"]
    DATA["lastTask"] = DATA["lastTask"] + 1

    local s_Task = {
        id = s_TaskID,
        name = p_Message.data.name,
        -- Unset means least urgent. Kept as -1 rather than 9 so tasks stored by older code read
        -- back the same; priorityOf normalises both to "last".
        priority = p_Message.data.priority or -1,
        -- Percentage of the blocker at which this task becomes workable. nil means "wait for done",
        -- which is right for a real prerequisite and wrong for collaborative work -- see
        -- dependencyMet.
        after = tonumber(p_Message.data.after),
    }

    local s_Work = p_Message.data.work or {}
    -- Only plan a dig for work that HAS a dig. This called PrepareTask unconditionally, so any
    -- non-mining task -- a survey, say -- handed nil to the dig planner and took the whole module
    -- down with "attempt to index local 'p_Params'". TaskMan assumed every task was a dig, which
    -- is exactly what a task manager must not assume.
    local s_Path = nil
    if s_Work["dig"] then
        local ok, res = pcall(dig.PrepareTask, s_Work["dig"])
        -- Log, not print: a CC terminal cannot be read from outside the game.
        if ok then s_Path = res else Log("dig planning failed: " .. tostring(res)) end
    end
    -- ONE TABLE, NOT TWO. The second `local s_Task` shadowed the first and rebuilt it field by
    -- field -- dropping `priority` and `after` on the floor for every task ever created. Priority
    -- was therefore always nil, so the queue had no ordering at all, and `after` (the threshold
    -- dependency that lets a scan start when its shaft is 95% done rather than 100%) never once
    -- reached a task. Both were being set carefully by callers and discarded here.
    s_Task.work = s_Work
    s_Task.dependsOn = p_Message.data.dependsOn
    s_Task.progress = 0
    s_Task.enabled = true
    s_Task.paused = false

    -- REFUSE WORK THAT IS ALREADY WAITING TO BE DONE.
    --
    -- There was no dedup here at all: every Add stored a new task unconditionally. The supply loop
    -- carries its own `queued` set and its comment says TaskMan "dedupes by name", which was simply
    -- not true -- so every other source (cave surveys, support requests, find-*) piled up freely.
    -- Measured on the live queue: 26 of 38 tasks were duplicates, five copies each of
    -- find-diamond_ore, cave--514,23,4 and gather:redstone_ore, all queued and none assigned.
    --
    -- The test is deliberately narrow: refuse only when an identical name is QUEUED AND UNASSIGNED.
    -- A second copy of work that is already being done by somebody is legitimate parallelism -- two
    -- miners on redstone is the point -- but a second copy of work nobody has started is pure
    -- queue noise, and it crowds out the work that matters behind it.
    for _, v in pairs(DATA["tasks"] or {}) do
        if v.name == s_Task.name and v.assignedTo == nil
           and (v.progress or 0) < 100 and v.enabled ~= false then
            -- SAME NAME, NEW ORDERS: TAKE THE NEW ORDERS.
            --
            -- Refusing the duplicate is right -- it is the same job -- but the WORK was silently
            -- thrown away with it, so re-issuing a job with different parameters quietly kept the
            -- old ones and reported success.
            --
            -- Measured: the ore-depth fix moved the redstone shaft from y=12 to y=-50 and
            -- order.prospect was re-issued at the new depth. It answered ok with depth -50 and
            -- shaftTask 7305 -- the EXISTING task, still carrying depth 50. The drone dutifully
            -- reported "shaft: down to y=50 (target 50)". Every layer had been fixed and checked,
            -- and the one that decides what the drone is actually told had kept yesterday's number.
            --
            -- Safe because this branch only ever runs for a task nobody has started: an assigned
            -- task is not a duplicate by the test above, so no drone's orders change mid-job.
            if s_Task.work ~= nil then
                v.work = s_Task.work
                v.priority = s_Task.priority or v.priority
                PowNet.MarkDirty()
                Log(("duplicate task %s -- kept the queued one and took the new parameters")
                    :format(tostring(s_Task.name)))
            else
                Log(("refused duplicate task %s -- one is already queued and unassigned")
                    :format(tostring(s_Task.name)))
            end
            return true, {id = v.id, duplicate = true}
        end
    end

    DATA["tasks"][s_Task.id] = s_Task
    return true, {id = s_Task.id}
end


-- ROLE-AWARE ASSIGNMENT
--
-- OnStartTask, OnPauseTask and OnAbortTask were all empty bodies, and nothing in this file ever
-- called SendToDrone -- tasks were stored and drawn and never given to anybody. This is the half
-- that was missing.
--
-- A drone's role is decided by its hardware: two upgrade slots, one taken by the wireless modem,
-- so the other makes it a scout (geo scanner) or a miner (pickaxe). A scout cannot dig and a
-- miner cannot see past its own nose, so work has to be matched to capability rather than handed
-- to whoever answers first.
local m_Fleet, m_FleetAt = nil, 0
local function fleet(p_Force)
    local s_Now = os.clock()
    -- Cached longer now the fleet is 23 drones: GetDrones returns every record, and
    -- TaskMan asks for it repeatedly within a single tick.
    if not p_Force and m_Fleet and (s_Now - m_FleetAt) < 15 then return m_Fleet end
    local s_Msg = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetDrones", {})
    -- FIVE seconds, not the default one.
    --
    -- DroneMan answers the whole fleet's heartbeats from a single receive loop, and HQ polls it
    -- constantly for the map and the status page. A one-second budget therefore fails often -- and
    -- when it does, this keeps its previous list, so TaskMan plans against a stale or empty view of
    -- who exists. It then assigns nothing, reclaims nothing, and the queue fills with work while
    -- idle drones sit in front of it. That is exactly what "lots of tasks and nothing executing"
    -- looked like from outside.
    local s_Res = PowNet.sendAndWaitForResponse("DroneMan", s_Msg, PowNet.SERVER_PROTOCOL, 5)
    if type(s_Res) == "table" and s_Res.drones then
        m_Fleet, m_FleetAt = s_Res.drones, s_Now
    elseif m_Fleet == nil then
        -- Never had a list at all. Say so: an empty fleet and an unreachable DroneMan look
        -- identical from here and mean completely different things.
        -- Log, not print. THIS is the message that explains an idle fleet with a full queue, and
        -- it was being written to a screen nobody can read.
        Log("TaskMan cannot reach DroneMan -- no fleet to assign work to")
    end
    return m_Fleet or {}
end

-- The role that means "any drone will do".
--
-- A GLOBAL, and declared ABOVE RoleForWork and every matcher that reads it. A `local` used above
-- its declaration is a nil global in Lua, silently -- and here that would make RoleForWork return
-- nil, which compares equal to nothing, so fuel relief would go from assignable-to-one-role to
-- assignable-to-none. That is the failure this constant exists to fix, arriving by the back door.
--
-- A string rather than nil because the value is also reported to HQ as a task's `role` and used as
-- a table key in the start loop (s_NoDrone[s_Role]); both want something printable.
ANY_ROLE = "any"

-- Does this drone satisfy the role a piece of work asks for?
--
-- Every site that matched roles did it inline as `(d.role or "miner") == p_Role`, in three places,
-- which is how a fourth place would have got it subtly wrong. The "miner" default is preserved:
-- a drone with no role recorded is a general worker, not a drone that can do nothing.
function RoleFits(p_Drone, p_Role)
    if p_Role == ANY_ROLE then return true end
    return ((p_Drone.role or "miner") == p_Role)
end

-- What kind of drone does this work need? Digging needs a tool; surveying needs a scanner.
function RoleForWork(p_Work)
    if p_Work == nil then return "miner" end
    -- Digging someone out is miner work by definition: a scout carries a geo scanner where a
    -- pickaxe would go, so the drone that is trapped is precisely the one that cannot free itself.
    --
    -- A FUEL relief is not that job, and pinning it to "miner" is a deadlock. Handing coal to a dry
    -- drone is fly-there-and-HandTo: no pickaxe, no upgrade, any turtle can do it. But whatever
    -- strands one miner -- an empty larder -- has almost always stranded every other miner at the
    -- same moment, so demanding a miner to rescue a miner asks the fleet for the one thing the
    -- emergency guarantees it does not have.
    --
    -- Measured: D9, D12 and D21 sat at ZERO fuel with fuel-D9/D12/D21 queued and permanently
    -- unassignable, while D4 -- a crafter holding 2,254 fuel and an empty inventory, parked at
    -- base, idle -- was excluded because its role did not match. The settlement had the fuel, the
    -- casualties, and the task, and could not put the three together.
    if p_Work["rescue"] then
        if p_Work["rescue"].fuel then return ANY_ROLE end
        return "miner"
    end
    if p_Work["survey"] or p_Work["scan"] then return "scout" end
    -- Crafting needs a crafting-table upgrade, which is a different turtle entirely: turtle.craft
    -- simply does not exist on a miner, so routing a craft to one wastes the trip and fails at the
    -- last step rather than the first.
    if p_Work["craft"] then return "crafter" end
    if p_Work["mine"] then return "miner" end
    -- Any turtle can place a block; miners are the general workers.
    if p_Work["build"] then return "miner" end
    if p_Work["gather"] then return "miner" end
    -- Lumber goes to a miner: roles are derived from HARDWARE (geoscanner -> scout, chunky ->
    -- loader, otherwise miner) and there is no wood-specific upgrade. A turtle digs wood with
    -- whatever tool it has.
    return "miner"
end

-- Is this drone already holding work we handed it?
--
-- `status` comes from heartbeats and therefore LAGS. Two tasks started in the same tick both saw
-- the drone as idle, both were sent, and the drone refused the second as "busy" -- but the task was
-- already marked assigned, so it never ran and never retried. Four chests stalled behind that
-- forever while the planks for them sat finished in storage.
local function committed(p_DroneId)
    for _, t in pairs(DATA["tasks"] or {}) do
        if t.assignedTo == p_DroneId and (t.progress or 0) < 100 and t.enabled ~= false then
            return true
        end
    end
    return false
end

-- WHERE IS THIS WORK? Assignment has to know, or it cannot be sensible about who goes.
local function workPos(p_Task)
    local w = p_Task and p_Task.work
    if type(w) ~= "table" then return nil end
    if w.mine and w.mine.pos then return w.mine.pos end
    if w.build and w.build.origin then return w.build.origin end
    if w.gather and w.gather.pos then return w.gather.pos end
    if w.rescue and w.rescue.pos then return w.rescue.pos end
    if w.survey then
        if w.survey.pos then return w.survey.pos end
        if w.survey.min and w.survey.max then
            return {x = (w.survey.min.x + w.survey.max.x) / 2,
                    y = (w.survey.min.y + w.survey.max.y) / 2,
                    z = (w.survey.min.z + w.survey.max.z) / 2}
        end
    end
    if w.dig and w.dig.min and w.dig.max then
        return {x = (w.dig.min.x + w.dig.max.x) / 2,
                y = (w.dig.min.y + w.dig.max.y) / 2,
                z = (w.dig.min.z + w.dig.max.z) / 2}
    end
    return nil
end

local function distTo(p_Drone, p_Pos)
    if p_Pos == nil or p_Drone == nil or p_Drone.pos == nil or p_Drone.pos.x == nil then
        return math.huge
    end
    return math.abs(p_Drone.pos.x - p_Pos.x) + math.abs(p_Drone.pos.y - p_Pos.y)
         + math.abs(p_Drone.pos.z - p_Pos.z)
end

-- NEAREST FREE DRONE, not the first one in the list.
--
-- This returned whichever matching drone happened to come first out of the registry, which is
-- insertion order and therefore meaningless. So a scout parked beside the miners kept being passed
-- over while one a hundred and sixty blocks away was sent instead -- it would spend several minutes
-- flying, arrive, and by then the work it was meant to support had moved on. The map is the same
-- either way; the difference is entirely wasted travel.
--
-- A drone with no known position sorts last rather than being excluded: it can still take work, it
-- is just the worst candidate for work with a location.
-- p_Avoid is the drone that last failed this task. It stays eligible -- a fleet of one must retry --
-- but only once nobody else can take it, so a task with three attempts spends them on three
-- different drones instead of three times on the same one.
-- A DRONE WITH NO FUEL IS NOT AN IDLE DRONE.
--
-- Nothing in TaskMan has ever looked at fuel. D2 ran itself to exactly zero, could not move a
-- single block, reported "idle" because that is what a drone with no job says -- and was promptly
-- assigned find-zinc_ore. The queue showed the work assigned, the fleet showed a drone on the job,
-- and the drone was a paperweight forty blocks up. Every tick it looked healthier than it was.
--
-- The floor matches the drone's own FUEL_RESERVE: below that DroneLogic breaks off whatever it is
-- doing to go and refuel, so dispatching to it cannot produce work -- the drone abandons the task
-- the moment it receives it, which reads as a mysteriously failing task rather than as an empty
-- tank. A drone under the floor needs fuel, not orders.
-- "Enough to be given work at all" -- and it must agree with what the DRONE thinks that means.
--
-- This was 600 while DroneLogic's FUEL_RESERVE was 900, so it was the looser of the two and never
-- bound anything. FUEL_RESERVE is now 300 (the y=110 flyover it was sized for is gone), which
-- inverted the relationship: TaskMan began refusing work to drones that were perfectly able to do
-- it. D9 sat idle at ~560 fuel while gather:coal_ore and gather:oak_log went unplaced and the log
-- blamed "every miner is busy (D14)" -- D14 being a drone that has been silent for three days.
--
-- Two numbers for one idea is how they drift apart. They mean the same thing, so they are the same
-- number: below this a drone cannot be sure of getting home, and above it, it can work.
local DISPATCH_FUEL_FLOOR = 300

local function hasFuel(d)
    -- Absent means unknown, not empty: an older DroneMan record with no fuel field must not take
    -- the whole fleet out of service.
    local f = tonumber(d.fuel)
    return f == nil or f >= DISPATCH_FUEL_FLOOR
end

-- A RESCUER NEEDS FAR MORE THAN THE DISPATCH FLOOR.
--
-- DISPATCH_FUEL_FLOOR is "enough to be given work at all". A fuel relief is a round trip -- reach
-- storage, load, cross to the casualty, and still be able to get home -- so a drone barely over the
-- floor is the worst possible choice. fuel-D2 was handed to D3 at 714 fuel: itself nearly dry, 60
-- blocks out, and certain to strand next to the drone it was sent to save. Two casualties instead
-- of one.
-- The BASE cost of a relief, before the journey. Covers reaching storage, loading coal, the search
-- at the far end and a margin -- the parts that do not depend on how far away the casualty is.
-- pickDrone adds RELIEF_PER_BLOCK for every block of the trip the chosen candidate would fly.
local RELIEF_FUEL_FLOOR = 300

-- Three fuel out and three back, matching the rate the drones' own FuelFloorNow charges for the
-- journey home. A round trip is the whole point of the reserve: a rescuer that arrives and cannot
-- leave has turned one casualty into two.
local RELIEF_PER_BLOCK = 6

-- A RESCUE MUST AIM AT WHERE THE CASUALTY IS NOW, NOT WHERE IT WAS WHEN THE TASK WAS WRITTEN.
--
-- The rescue task records the casualty's position at creation time and the dispatch passed that
-- snapshot through unchanged. But a stranded drone's BELIEF about itself keeps changing even when
-- the drone cannot move an inch: it re-fixes against GPS and corrects, so the recorded coordinate
-- goes stale without anything physical happening. D4, sitting at zero fuel and incapable of moving,
-- was recorded at -478,7,66 while reporting -476,11,64 -- four blocks out in y alone. Every rescuer
-- flew to the old number, found air beneath it, and came home with the coal still aboard.
--
-- The live fleet entry is the freshest belief anyone has. This runs on every re-dispatch, so each
-- retry aims better than the last instead of repeating the same miss.
local function livePos(p_Drone, p_Fallback)
    if p_Drone == nil then return p_Fallback end
    for _, d in ipairs(fleet()) do
        if (d.name == p_Drone or d.id == p_Drone) and d.pos ~= nil and d.pos.x ~= nil then
            return {x = d.pos.x, y = d.pos.y, z = d.pos.z}
        end
    end
    return p_Fallback
end

-- DO NOT SPEND THE ONLY DRONE THAT CAN DO A THING ON A JOB ANY DRONE COULD DO.
--
-- Fuel relief accepts ANY_ROLE deliberately -- a stranded drone does not care who brings the coal,
-- and restricting relief to miners is what left casualties sitting while idle crafters watched. But
-- "any role will do" was read as "all roles are equally spendable", and the nearest drone to a
-- casualty is frequently the crafter parked at the bay.
--
-- Measured: D4 is the settlement's ONLY crafter. It was pulled off craft-chest onto Relieve for D14
-- three times in a row, so chest stayed at 0 while storage ran down to 31 free slots and every
-- deposit began to fail for want of anywhere to go. The relief was correct; taking the one drone
-- that could end the shortage to perform it was not.
--
-- So a sole-of-its-role drone is ranked behind every substitutable candidate, whatever the
-- distance, and is still chosen when nothing else fits -- the casualty is not abandoned to protect
-- a work queue. For a role-specific task every candidate carries the same penalty and nothing
-- changes; it only ever reorders a mixed field, which is exactly the ANY_ROLE case.
local SOLE_ROLE_PENALTY = 100000

local function roleCounts()
    local t = {}
    for _, d in ipairs(fleet()) do
        local r = tostring(d.role or "miner")
        t[r] = (t[r] or 0) + 1
    end
    return t
end

-- Distance, plus the cost of losing a unique capability. Its own function so pickDrone does not
-- grow a branch for it.
local function pickCost(p_Drone, p_Pos, p_Counts)
    local s_D = distTo(p_Drone, p_Pos)
    if (p_Counts[tostring(p_Drone.role or "miner")] or 1) <= 1 then return s_D + SOLE_ROLE_PENALTY end
    return s_D
end

local function pickDrone(p_Role, p_Pos, p_Avoid, p_MinFuel)
    local s_Counts = roleCounts()
    local s_Busy, s_Best, s_BestD = nil, nil, nil
    local s_Fallback = nil
    for _, d in ipairs(fleet()) do
        local s_Enough = hasFuel(d)
        if s_Enough and p_MinFuel then
            local f = tonumber(d.fuel)
            -- SCALE THE REQUIREMENT TO THE TRIP THIS CANDIDATE WOULD ACTUALLY MAKE.
            --
            -- p_MinFuel used to be a flat number, and it was set from RELIEF_FUEL_FLOOR = 1800 --
            -- sized for the worst relief anyone had seen, a casualty sixty blocks out. Applied to
            -- every casualty regardless of distance, it means a drone twenty blocks from the
            -- stranded one is refused for want of fuel it would never spend.
            --
            -- That is the same shape of bug as the 900 flat fuel reserve, one layer up, and it had
            -- the same effect: the best drone in the settlement held 942, nothing reached 1800, so
            -- NO drone could relieve anyone and every fuel- task sat unplaceable for ever. The fleet
            -- reported "every any is busy" while four drones stood idle.
            --
            -- So p_MinFuel is now the BASE and the distance is charged on top, at 6 per block: three
            -- out and three back, the same rate the drones' own floor uses. A rescuer twenty blocks
            -- away needs ~420; one two hundred blocks away needs ~1,500 and is still correctly
            -- refused. The original worry stands and is now priced properly -- fuel-D2 went to D3 at
            -- 714 fuel, sixty blocks out, and stranded beside the drone it was sent to save.
            local s_Need = p_MinFuel + RELIEF_PER_BLOCK * distTo(d, p_Pos)
            s_Enough = (f == nil) or (f >= s_Need)
        end
        if RoleFits(d, p_Role) then
            if d.status == "idle" and not committed(d.id) and s_Enough then
                if p_Avoid ~= nil and d.id == p_Avoid then
                    s_Fallback = s_Fallback or d
                else
                    local s_D = pickCost(d, p_Pos, s_Counts)
                    if s_BestD == nil or s_D < s_BestD then s_Best, s_BestD = d, s_D end
                end
            else
                s_Busy = s_Busy or d
            end
        end
    end
    if s_Best then return s_Best end
    if s_Fallback then return s_Fallback end
    return nil, s_Busy
end

-- Every idle drone of a role that ACTUALLY ANSWERS, so a site can be worked by the whole shift
-- instead of one drone while the rest sit on their docks.
--
-- The liveness check is not optional. The registry cannot distinguish a docked drone from one
-- that no longer exists -- heartbeats fire only at boot and shutdown -- so a drone that is mined
-- out of the world stays "idle" forever. D1 dug up D2, and D2 was still being offered work
-- afterwards: a slab of the site would simply never be dug and the task would never complete.
-- PLACING A BLOCK NEEDS NO SPECIAL HARDWARE.
--
-- Digging needs a pickaxe and scanning needs a geo scanner, so those jobs genuinely belong to one
-- role. Building needs neither -- every turtle can place -- and routing it to "miner" left a build
-- queued indefinitely while a crafter and a loader sat idle on their docks.
--
-- Its own function so it reads as the sibling of anyoneForRescue below, which is what it is: both
-- are "prefer that role, but do not make it a requirement".
local function anyoneForBuild(p_Task, p_Where)
    if p_Task.work == nil or p_Task.work.build == nil then return nil end
    for _, alt in ipairs({"crafter", "loader", "scout"}) do
        local d = pickDrone(alt, p_Where)
        if d ~= nil then
            Log("build going to a " .. alt .. " -- no miner free")
            return d
        end
    end
    return nil
end

-- A RESCUE THAT ONLY A MINER MAY PERFORM IS NO RESCUE WHEN THE MINERS ARE THE CASUALTIES.
--
-- A dig-out is named for the casualty's own role, so rescue-D31 comes out role=miner. That is the
-- right PREFERENCE -- freeing a buried drone needs a pickaxe and a crafter has none. It is the
-- wrong REQUIREMENT, because the situation in which no miner is available is usually the situation
-- in which the miners are the ones needing rescue.
--
-- Measured, and it deadlocked the settlement: rescue-D31 and rescue-D36 both sat unassigned at
-- role=miner while all three miners read fuel 0 and D4, a crafter, idled at 6,363 fuel beside 238
-- charcoal in storage. Nothing moved for nine minutes. The one drone able to help was refused on a
-- technicality about which tool it carries.
--
-- This file already argues the same point about the other half of the guess: "calling a TRAPPED
-- drone dry sends someone with coal, which any drone can carry -- if that was the wrong guess the
-- attempt fails cheaply and rescueTries escalates." A crafter cannot dig anyone out, but most
-- casualties are not buried, and arriving with fuel fixes the common case.
--
-- Returns nil for anything that is not a rescue, so the caller can use it as a plain fallback.
-- Below this far under the settlement floor, reaching a casualty means going through rock.
local UNDERGROUND_BELOW = 8

local function anyoneForRescue(p_Task, p_Where, p_MinFuel, p_Role)
    local w = p_Task.work and p_Task.work.rescue
    if w == nil then return nil end

    -- DO NOT SEND SOMETHING THAT CANNOT DIG DOWN A HOLE.
    --
    -- The any-role fallback is right on the surface: most casualties want fuel, and a crafter can
    -- carry coal even though it cannot cut rock. Underground it inverts. Reaching a drone in a shaft
    -- means digging, a crafter carries a workbench where a pickaxe would go, and a drone that cannot
    -- dig cannot get itself out either -- so the rescue risks adding a second casualty in the worst
    -- possible place.
    --
    -- Measured: D4, the settlement's ONLY crafter and the only drone with fuel at the time (8,689),
    -- was sent after a casualty at y=59 and ended up at y=46 -- twenty blocks under the floor, no
    -- pickaxe, unable to cut its way back. Losing it would have ended chest and plank production
    -- outright, which is worse than the casualty it went for.
    --
    -- Miners still take these; only the fallback is restricted. If every miner is dry and the
    -- casualty is underground, no rescue is the correct answer -- it is what "it needs a human"
    -- already means elsewhere in this file.
    -- The settlement floor, from the region if pgps is loaded here and 63 if it is not -- which is
    -- what world.bounds reports for this base's centre. Guarded rather than assumed: TaskMan is a
    -- computer, not a turtle, and a nil global would take the whole placement pass down with it.
    local s_Home = pgps and pgps.centre and pgps.centre()
    local s_Floor = (s_Home and tonumber(s_Home.y)) or 63
    if w.pos and tonumber(w.pos.y) and tonumber(w.pos.y) < (s_Floor - UNDERGROUND_BELOW) then
        return nil
    end

    local d = pickDrone(ANY_ROLE, p_Where, w.id, p_MinFuel)
    if d == nil then return nil end
    Log(("rescue for %s going to %s (a %s) -- no %s free, and most casualties want fuel rather "
         .. "than a tunnel"):format(tostring(w.drone), tostring(d.name), tostring(d.role),
                                    tostring(p_Role)))
    return d
end

local function pickDrones(p_Role)
    local s_Free, s_Busy = {}, nil
    for _, d in ipairs(fleet()) do
        if RoleFits(d, p_Role) then
            -- TRUST THE HEARTBEAT. DO NOT PING EVERY CANDIDATE.
            --
            -- This pinged each idle drone of the role with a FOUR SECOND timeout before considering
            -- it. That is one blocking network round trip per candidate, inside the dispatch path,
            -- and it scales with the fleet: at fourteen idle scouts a single pickDrones call can
            -- spend the better part of a minute waiting. TaskMan's tick then never finishes,
            -- GetTasks times out, nothing is assigned, and every drone sits idle -- which looks
            -- exactly like a scheduler that has given up. Adding ten scouts is what pushed it over.
            --
            -- The ping was belt-and-braces from when the registry could not tell a docked drone
            -- from a destroyed one. It can now: DroneMan marks a drone offline after three missed
            -- heartbeats, so `offline` already answers the question the ping was asking, for free
            -- and without blocking anything. The worst case is dispatching to a drone that died in
            -- the last ninety seconds -- and that task is reclaimed on the next sweep anyway.
            if d.status == "idle" and not d.offline and hasFuel(d) then
                s_Free[#s_Free + 1] = d
            else
                s_Busy = s_Busy or d
            end
        end
    end
    return s_Free, s_Busy
end

function OnStartTask(p_ID, p_Message)
    local s_Id = p_Message.data and p_Message.data.id
    if s_Id == nil then return false, "Missing id" end
    local s_Task = DATA["tasks"][s_Id] or DATA["tasks"][tostring(s_Id)] or DATA["tasks"][tonumber(s_Id)]
    if s_Task == nil then return false, "No task " .. tostring(s_Id) end

    local s_Role = RoleForWork(s_Task.work)

    -- A dig is the one job that splits cleanly across workers, so give it everyone who is free.
    -- dig.SplitRegion cuts the box into disjoint slabs oriented to minimise TURNS (a turn costs a
    -- full step), and disjoint is what stops miners digging each other -- D1 mined D2 out of the
    -- world because its box contained D2's parking spot.
    if s_Role == "miner" and s_Task.work and s_Task.work.dig
       and s_Task.work.dig.start and s_Task.work.dig.stop then
        local s_Free, s_Busy2 = pickDrones(s_Role)
        if #s_Free == 0 then
            return false, "every miner is busy (" .. tostring(s_Busy2 and s_Busy2.name) .. ")"
        end
        local w = s_Task.work.dig

        -- NOT refused for containing a drone. That check lived here and was the wrong level:
        -- sites legitimately contain things, and a job that will not start is worse than one that
        -- digs around an obstacle. The rule belongs at the block being broken -- see IsProtected
        -- in DroneLogic, which every dig funnels through.
        local s_Depth = tonumber(w.depth) or (math.abs((w.stop.y or 0) - (w.start.y or 0)) + 1)
        local s_Slabs = dig.SplitRegion(w.start, w.stop, #s_Free, s_Depth)

        local s_Names = {}
        for i, slab in ipairs(s_Slabs) do
            local d = s_Free[i]
            PowNet.SendToDrone(d.id, PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Dig",
                {w = slab.w, l = slab.l, depth = slab.depth, pos = slab.pos}))
            s_Names[#s_Names + 1] = tostring(d.name) .. "(" .. slab.cost .. ")"
        end

        s_Task.assigned   = table.concat(s_Names, ",")
        s_Task.assignedTo = s_Free[1].id
        s_Task.assignedAt = os.epoch("utc")
        s_Task.paused     = false
        PowNet.MarkDirty()
        return true, {message = ("task %s -> %d miner(s): %s"):format(
            tostring(s_Id), #s_Slabs, table.concat(s_Names, " ")), workers = #s_Slabs}
    end

    local s_Where = workPos(s_Task)
    -- A fuel relief needs a rescuer that can complete the round trip, not merely one allowed to
    -- take orders. See RELIEF_FUEL_FLOOR.
    local s_MinFuel = nil
    if s_Task.work and s_Task.work.rescue and s_Task.work.rescue.fuel then
        s_MinFuel = RELIEF_FUEL_FLOOR
    end
    local s_Drone, s_Busy = pickDrone(s_Role, s_Where, s_Task.lastFailedBy, s_MinFuel)

    -- A DRONE MUST NOT BE SENT TO RESCUE ITSELF.
    --
    -- The earlier reasoning was that pickDrone only ever picks an idle drone and a drone needing
    -- rescue is not idle -- which is true at any instant and false over time. A stranded drone
    -- oscillates: it reports idle between failed attempts, gets picked in that window, and is
    -- dispatched to its own coordinates. D3 was sent to -412,109,39 twice, which is where it already
    -- was, so it "arrived" instantly, achieved nothing, and remained stranded outside the region.
    if s_Drone ~= nil and s_Task.work and s_Task.work.rescue
       and s_Drone.id == s_Task.work.rescue.id then
        return false, "the only free " .. s_Role .. " is the drone that needs rescuing"
    end

    -- PLACING A BLOCK NEEDS NO SPECIAL HARDWARE.
    --
    -- Digging needs a pickaxe and scanning needs a geo scanner, so those jobs genuinely belong to
    -- one role. Building needs neither -- every turtle can place -- and routing it to "miner" left
    -- a build queued indefinitely while a crafter and a loader sat idle on their docks. Prefer a
    -- miner, then take whoever is free.
    s_Drone = s_Drone or anyoneForBuild(s_Task, s_Where)

    -- A rescue prefers a miner but must not REQUIRE one -- see anyoneForRescue.
    s_Drone = s_Drone or anyoneForRescue(s_Task, s_Where, s_MinFuel, s_Role)
    if s_Drone == nil then
        if s_Busy then
            return false, "every " .. s_Role .. " is busy (" .. tostring(s_Busy.name) .. ")"
        end
        -- Naming the missing capability beats "no drone available": the fix is to fit a scanner
        -- or a pickaxe to something, and that is not guessable from a generic failure.
        return false, "no " .. s_Role .. " in the fleet -- one drone needs a " ..
               (s_Role == "scout" and "geo scanner" or "pickaxe")
    end

    -- Dig, not GoTo. GoTo only moves a drone to a coordinate -- dispatching mining work with it
    -- sent a miner to stand next to the ore and do nothing.
    local s_Verb, s_Payload
    if s_Role == "scout" then
        local w = s_Task.work.survey or {}
        local s_Pos, s_W, s_H = w.pos, w.w, w.h
        local s_R = tonumber(w.radius) or 8

        -- A REGION IS NOT A DESTINATION UNTIL SOMEBODY TURNS IT INTO ONE.
        --
        -- order.issue{kind="explore"} records a region -- {min, max} -- and nothing else. This
        -- passed w.pos straight through, so `pos` was nil, and OnSurvey only travels `if d.pos`.
        -- Every explore order therefore told a scout to survey a box on the other side of the base
        -- and the scout scanned where it was already standing, indefinitely, reporting "scanning"
        -- the whole time. Four scouts sat in four unrelated places rescanning ground they had
        -- already covered while nine tiles over the base went untouched.
        --
        -- The region has everything needed to fix that: start in a corner, one scan-diameter in so
        -- the first sphere lands inside the box, and take as many steps as it takes to tile it.
        if s_Pos == nil and w.min and w.max then
            -- NO Y. The scout supplies its own.
            --
            -- Aiming at w.max.y sends it to the top of the box -- y=95, well into open sky -- which
            -- is wrong twice over. It burns a long vertical climb to reach a height the survey
            -- immediately gives back by settling to the ground, and over unmapped terrain the climb
            -- often cannot be pathed at all, so the task fails with "could not reach the survey
            -- start", requeues, and the next scout repeats it. Scouts going idle in place is what
            -- that looks like from outside.
            --
            -- The scout already knows a workable altitude: the one it is flying at. Travel across
            -- at that height and let settle() find the ground once it arrives.
            s_Pos = {x = w.min.x + s_R, z = w.min.z + s_R}
            local s_Step = s_R * 2
            s_W = s_W or math.max(1, math.ceil((w.max.x - w.min.x) / s_Step))
            s_H = s_H or math.max(1, math.ceil((w.max.z - w.min.z) / s_Step))
        end

        s_Verb, s_Payload = "Survey", {w = s_W, h = s_H, radius = w.radius, pos = s_Pos,
                                       taskId = s_Task.id}
    elseif s_Task.work.build then
        -- The layout arrives as data. HQ costed it, checked it against the plot registry and
        -- ordered it bottom-up before any of this was dispatched.
        local w = s_Task.work.build
        s_Verb, s_Payload = "Build", {origin = w.origin, blocks = w.blocks, taskId = s_Task.id}
    elseif s_Task.work.mine then
        -- Prospecting: sink a shaft and drive branches, inspecting what gets exposed. The only job
        -- that can find ore the map has never seen.
        local w = s_Task.work.mine
        s_Verb, s_Payload = "Mine", {pos = w.pos, depth = w.depth, length = w.length,
                                     branches = w.branches, spacing = w.spacing, taskId = s_Task.id}
    elseif s_Task.work.craft then
        -- The output of the recipe planner, executed. grid and inputs travel with the task because
        -- the drone has no recipe book: turtle.craft reads the inventory layout and infers what is
        -- being made, so the layout has to arrive with the order.
        local w = s_Task.work.craft
        s_Verb, s_Payload = "Craft", {item = w.item, runs = w.runs, grid = w.grid, inputs = w.inputs, taskId = s_Task.id}
    elseif s_Task.work.gather then
        -- Targeted collection: the survey already knows where these blocks are.
        local w = s_Task.work.gather
        s_Verb, s_Payload = "Gather", {targets = w.targets, match = w.match, limit = w.limit, taskId = s_Task.id}
    elseif s_Task.work.rescue then
        -- A RESCUE IS A GoTo. THAT IS THE WHOLE TRICK.
        --
        -- OnGoTo already falls back moveTo -> flyTo -> digTo, and digTo carves a two-high walkable
        -- tunnel. So a miner told to go and stand where a trapped scout is standing will cut its way
        -- there through whatever is in between -- and the tunnel it leaves behind is the way out.
        -- Nothing new has to know how to dig; the rescue is just a destination that happens to have
        -- a drone sitting at it.
        local w = s_Task.work.rescue
        if w.fuel then
            -- Not a destination job. The rescuer has to load coal from storage FIRST, so it cannot
            -- just be pointed at the casualty the way a dig-out can.
            s_Verb, s_Payload = "Relieve",
                {pos = livePos(w.drone, w.pos), drone = w.drone, taskId = s_Task.id}
        else
            -- Same staleness, same fix: a dig-out aimed at the old coordinate tunnels to an empty
            -- pocket of rock next to the drone it was sent to free.
            s_Verb, s_Payload = "GoTo", {pos = livePos(w.drone, w.pos), taskId = s_Task.id}
        end
    elseif s_Task.work.lumber then
        -- Wood gates chests, planks and sticks, and therefore every factory the fleet might
        -- build. Nothing else produces it.
        local w = s_Task.work.lumber
        s_Verb, s_Payload = "Lumber", {w = w.w, l = w.l, drop = w.drop, pos = w.start, taskId = s_Task.id}
    else
        local w = s_Task.work.dig or {}
        s_Verb, s_Payload = "Dig", {w = w.w, l = w.l, depth = w.depth, pos = w.start, taskId = s_Task.id}
    end
    -- Say what was sent and to whom. "reclaiming task N -- never started" is the only symptom of a
    -- dispatch that did not arrive, and it says nothing about which verb went where.
    Log(("dispatch %s -> %s (task %s)"):format(tostring(s_Verb), tostring(s_Drone.name or s_Drone.id),
        tostring(s_Task.id)))
    PowNet.SendToDrone(s_Drone.id, PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, s_Verb, s_Payload))

    s_Task.assigned = s_Drone.name
    s_Task.assignedTo = s_Drone.id
    s_Task.assignedAt = os.epoch("utc")
    s_Task.paused = false
    PowNet.MarkDirty()
    return true, {message = "task " .. tostring(s_Id) .. " -> " .. tostring(s_Drone.name) ..
                  " (" .. s_Role .. ")", drone = s_Drone.name}
end

function OnPauseTask(p_ID, p_Message)
    local s_Id = p_Message.data and p_Message.data.id
    local s_Task = s_Id and (DATA["tasks"][s_Id] or DATA["tasks"][tostring(s_Id)])
    if s_Task == nil then return false, "No task " .. tostring(s_Id) end
    s_Task.paused = true
    if s_Task.assignedTo then
        PowNet.sendAndWaitForResponse(s_Task.assignedTo,
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}), PowNet.SERVER_PROTOCOL)
    end
    PowNet.MarkDirty()
    return true, {message = "paused " .. tostring(s_Id)}
end

function OnAbortTask(p_ID, p_Message)
    local s_Id = p_Message.data and p_Message.data.id
    local s_Task = s_Id and (DATA["tasks"][s_Id] or DATA["tasks"][tostring(s_Id)])
    if s_Task == nil then return false, "No task " .. tostring(s_Id) end
    if s_Task.assignedTo then
        PowNet.sendAndWaitForResponse(s_Task.assignedTo,
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}), PowNet.SERVER_PROTOCOL)
    end
    s_Task.enabled = false
    s_Task.assigned, s_Task.assignedTo = nil, nil
    PowNet.MarkDirty()
    return true, {message = "aborted " .. tostring(s_Id)}
end

-- The queue, for anything that wants to show it. MainFrame draws it on the hub monitor.
--
-- `work` and `assignedTo` now travel with each task, and they are the whole point for anything
-- drawing a map. Without them a task is a name and a percentage -- you can see that D3 is busy,
-- but not that it is surveying a box thirty blocks north, which is the only form of the answer
-- that lets an operator tell "working correctly" from "working somewhere useless". The verb and
-- its bounds are the INTENT; everything else here is bookkeeping about the intent.
--
-- assignedTo is the drone id. `assigned` is a comma-joined list of NAMES, which is fine for a
-- monitor line and useless for joining against the fleet registry.
-- ANSWER WITHIN A FRAME, OR DO NOT ANSWER AT ALL.
--
-- This returned every task, whole, including v.work. That was fine at twenty tasks and fatal at
-- three hundred: the reply reached 63,792 bytes against a 61,440-byte websocket frame limit, the
-- call failed outright, and HQ lost the task list entirely. "fleet.tasks failed" reads exactly like
-- "the queue is empty" from outside -- which is the opposite of what was wrong. The queue was
-- overflowing, because the supply loop creates work faster than the fleet retires it.
--
-- Live work comes first, and finished tasks are a tail. A caller wanting more can page with offset.
-- Forty, not 120. Each entry carries v.work whole -- the dig region, the survey bounds, the gather
-- target list -- which averages about 530 bytes, so even a capped 120 came to 63,795 bytes and
-- failed against the same 61,440-byte frame limit as the uncapped reply did. The cap has to be set
-- against the BYTES, not the count.
local GETTASKS_MAX = 40

-- A TASK LIST IS A DESCRIPTION, NOT A PAYLOAD.
--
-- OnGetTasks sent `work` whole, deliberately: the shapes differ per verb and a summariser that
-- knows about each one silently omits the next one somebody adds. That reasoning is right and the
-- consequence still bit -- a build task carries its BLOCK LIST, and thirteen tower tasks of 192
-- blocks each took one reply to 131,940 bytes against a 61,440 limit. fleet.tasks failed outright
-- and hive.plan quietly returned nothing, so the operator's two views of the queue both went dark
-- at the moment the queue got interesting.
--
-- So: keep sending every field, and truncate only the thing that is bulk by nature -- a long array.
-- No verb names appear here, so a new verb with a long list is covered the day it is added. A
-- dashboard wants to know a build has 192 blocks; it has never wanted to know their coordinates.
-- gather's target list gets the same treatment and has been quietly close to the limit for weeks.
local WORK_ARRAY_MAX = 8
local function summariseWork(p_Work, p_Depth)
    if type(p_Work) ~= "table" then return p_Work end
    if (p_Depth or 0) > 4 then return p_Work end
    local out = {}
    for k, v in pairs(p_Work) do
        if type(v) == "table" and #v > WORK_ARRAY_MAX then
            out[k] = {count = #v, truncated = true}
        elseif type(v) == "table" then
            out[k] = summariseWork(v, (p_Depth or 0) + 1)
        else
            out[k] = v
        end
    end
    return out
end

function OnGetTasks(p_ID, p_Message)
    local d = p_Message and p_Message.data or {}
    local s_Offset = tonumber(d.offset) or 0
    local s_Limit  = math.min(tonumber(d.limit) or GETTASKS_MAX, GETTASKS_MAX)

    -- Split first so a long backlog of finished tasks can never crowd out the live ones.
    local s_Live, s_Done, s_Total = {}, {}, 0
    for k,v in pairs(DATA["tasks"]) do
        s_Total = s_Total + 1
        if (v.progress or 0) < 100 then s_Live[#s_Live + 1] = v else s_Done[#s_Done + 1] = v end
    end
    local s_Ordered = {}
    for _, v in ipairs(s_Live) do s_Ordered[#s_Ordered + 1] = v end
    for _, v in ipairs(s_Done) do s_Ordered[#s_Ordered + 1] = v end

    local s_List = {}
    for i = s_Offset + 1, math.min(s_Offset + s_Limit, #s_Ordered) do
        local v = s_Ordered[i]
        s_List[#s_List + 1] = {
            id = v.id, name = v.name, progress = v.progress,
            enabled = v.enabled, paused = v.paused,
            assigned = v.assigned, assignedTo = v.assignedTo,
            role = RoleForWork(v.work),
            -- THE FIELD THAT DECIDES THE ORDER WAS THE ONE FIELD NOBODY COULD SEE.
            --
            -- priority governs which task a freed drone is offered next, and this serialisation --
            -- the only way anything outside the world learns about a task -- omitted it. So "why is
            -- the shaft never picked up" could be answered only by reading source and reasoning
            -- about a number that could not be observed from anywhere. It produced two wrong
            -- theories in one session, including "it is never stored at all", which it is not.
            priority = v.priority,
            -- THE REASON A TASK IS STUCK IS THE MOST USEFUL FIELD ON IT, AND IT WAS NOT SENT.
            --
            -- dependsOn is what makes the queue a TREE rather than a list: order.build queues the
            -- crafts it needs and waits on them, and those crafts wait on the wood. None of that
            -- reached the dashboard, so a blocked build was indistinguishable from an idle fleet --
            -- "why is the crafter doing nothing" had no answer anywhere in the UI, and the honest
            -- answer ("waiting on planks, which are waiting on logs, which nobody has gathered")
            -- was sitting right here the whole time.
            dependsOn = v.dependsOn,
            failure = v.failure,
            attempts = v.attempts,
            lastFailedBy = v.lastFailedBy,
            -- Sent whole rather than summarised. The shapes differ per verb -- dig has
            -- start/stop, survey has min/max, gather has a target list, lumber has width and
            -- length -- and a summariser here would have to be updated every time a verb is
            -- added, silently omitting the new one until someone noticed.
            work = summariseWork(v.work),
        }
    end
    -- EVERY LIVE NAME, ALWAYS, EVEN THOUGH THE TASK LIST IS PAGED.
    --
    -- The supply loop dedups against the names it can see, and capping this reply at 40 tasks meant
    -- it could only see a page -- so a shortage that already had eight outstanding searches looked
    -- untouched and got a ninth. The queue reached 159 live tasks with 2 assigned, nine copies of
    -- find-iron_ore among them, and the fleet spent its time being handed work it had already been
    -- handed. The cap was mine, and so was the regression.
    --
    -- Names are short. All 159 of them cost about three kilobytes, nowhere near the frame limit,
    -- and they are the one thing a caller needs in full to avoid asking twice.
    local s_Names = {}
    for _, v in ipairs(s_Live) do
        if type(v.name) == "string" then s_Names[#s_Names + 1] = v.name end
    end

    local s_Next = s_Offset + #s_List
    return true, {tasks = s_List, count = #s_List, total = s_Total, live = #s_Live,
                  liveNames = s_Names,
                  offset = s_Offset, next = (s_Next < #s_Ordered) and s_Next or nil}
end

-- THE LOOP.
--
-- Until now nothing had initiative: tasks sat in the queue until a human typed `start`. Every
-- module in this system reacts to messages and none of them tick, so a fleet of idle drones and
-- a queue of pending work would happily coexist forever.
--
-- TaskMan is the right owner because it is the only module that knows both halves -- what needs
-- doing and (via DroneMan) who is free. It runs as a fourth branch of the module's parallel set.
local TICK_SECONDS = 15
local RECLAIM_AFTER_MS = 90 * 1000
local m_OrphanSince = {}

-- How many tasks to start in one pass. Small on purpose: assigning is expensive (a liveness ping
-- per candidate) and the tick comes round every 15 seconds anyway, so there is no need to place the
-- whole queue at once -- only to place SOMETHING, reliably, every pass.
local START_PER_TICK = 3

-- FORGET FINISHED WORK.
--
-- Nothing ever removed a completed task, so the queue was 149 entries of which 22 were live. Every
-- tick walked all of them, every fleet.tasks call shipped all of them, and the operator view was
-- mostly a list of surveys that finished hours ago -- which is why "there are a bunch of survey
-- find-ore at 100%, why are they still visible" is the obvious question to ask about it.
--
-- Kept briefly rather than dropped instantly: a task that has just finished is exactly the one
-- someone is about to ask about, and its failure reason is the record of why something did not
-- happen. Five minutes covers that; an hour just fills the operator view with surveys that finished
-- long ago and buries the handful of things actually running.
local KEEP_FINISHED_MS = 5 * 60 * 1000

local function pruneFinished()
    local s_Now, s_Gone = os.epoch("utc"), 0
    for k, v in pairs(DATA["tasks"] or {}) do
        if (v.progress or 0) >= 100 and v.finishedAt and (s_Now - v.finishedAt) > KEEP_FINISHED_MS then
            DATA["tasks"][k] = nil
            s_Gone = s_Gone + 1
        end
    end
    if s_Gone > 0 then
        print("pruned " .. s_Gone .. " finished tasks")
        PowNet.MarkDirty()
    end
end

-- SEND A MINER TO DIG THE TRAPPED ONES OUT.
--
-- A scout that reports "could not reach" is usually not lost -- it is walled in. It went down a
-- shaft to scan, the shaft it came down is no longer walkable, and it carries a geo scanner where a
-- pickaxe would go. So it fails, is reclaimed, is reassigned, and fails again, forever, while its
-- fuel burns; three of them did exactly this for hours. Drones have been sending Distress to
-- DroneMan the whole time and nothing has ever read it.
--
-- The rescue itself is just a destination (see the GoTo dispatch above). This pass is only the
-- bookkeeping: who needs one, and has someone already been sent.
local RESCUE_STATES = {stuck = true, stranded = true, lost = true, blocked = true}

-- Below this altitude a wireless modem cannot reach the tower, so a working drone goes quiet and
-- STAYS quiet until it surfaces. Measured, not chosen: the modules sit at y=64 and the mast repeater
-- at y=85, and drones reliably drop out of contact in the fifties. Anything below this is expected
-- to be silent, so silence there must not be read as distress -- see the rescue pass.
local RADIO_FLOOR_Y = 58

-- How long a freshly dispatched task is protected from being reclaimed as "never started".
-- Comfortably longer than one reclaim tick plus a heartbeat, so the drone gets a real chance to
-- receive the order, begin it, and say so.
local RECLAIM_GRACE_MS = 45000

-- Is this task's dependency satisfied yet?
--
-- "Done" is the wrong bar for collaborative work. A scan at y=12 does not need the shaft FINISHED,
-- it needs the shaft to have got past y=12 -- and making it wait for completion serialises two jobs
-- that should overlap, leaving a scout idle for as long as the dig takes. `after` is the percentage
-- of the blocker at which this task becomes workable; absent, it means 100 and behaves as before.
--
-- DECLARED HERE, above every caller. It was originally written down beside blockers() -- 250 lines
-- BELOW the first place that calls it -- which in this language is a nil global that silently
-- evaluates as "no dependency check at all". The hygiene suite caught it; nothing at runtime would
-- have, because the failure looks exactly like a dependency that was already satisfied.
local function dependencyMet(p_Task)
    if p_Task.dependsOn == nil then return true end
    local dep
    for _, v in pairs(DATA["tasks"] or {}) do
        if tostring(v.id) == tostring(p_Task.dependsOn) then dep = v break end
    end
    if dep == nil then return true end            -- the blocker is gone; nothing to wait for
    return (dep.progress or 0) >= (tonumber(p_Task.after) or 100)
end

-- Placement attempts per role per pass before concluding nothing of that role can be placed.
local TRIES_PER_ROLE = 4

-- Total fleet fuel below which only fuel work is placed. Matches HQ's FUEL_PRIORITY_BELOW, and is
-- deliberately generous: the fleet burns roughly 120 fuel a minute working, so this leaves well
-- over half an hour to find, cut and carry coal home before anything is actually at risk.
local FLEET_FUEL_LOW = 4000

-- Does this task make fuel? Declared ABOVE the placement loop that asks -- a local used above its
-- declaration is a silent nil global in Lua, and here that would make EVERY task look like non-fuel
-- work and stop the fleet dead the moment fuel ran low.
--
-- THE SUBSTRING "coal" WAS THE WHOLE TEST, AND IT IS WHY THE SETTLEMENT HAS NO RENEWABLE FUEL.
--
-- Below FLEET_FUEL_LOW the placement loop refuses everything that is not fuel work. Correct policy.
-- But it recognised fuel work by looking for "coal" in the task NAME, so `gather:oak_log` failed the
-- test -- and a log is fuel twice over: a turtle burns it directly, and one coal smelts eight of
-- them into eight charcoal, which is the only smelt in the settlement that ends with more fuel than
-- it started with.
--
-- So the rule read: when fuel is short, permit only the fuel that is buried thirty blocks down in
-- caves where three drones have already stranded, and forbid the fuel growing on the surface
-- nineteen blocks from base. The fleet sat idle at 0 coal with `gather:oak_log` unassigned in the
-- queue and drones reporting idle beside it, which is exactly what it looks like from outside: a
-- scheduler that has given up.
--
-- HQ already had this right -- supply.ts `producesFuel()` permits wood explicitly, "the reachable
-- half of the fuel supply". This was a second, dumber copy of the same idea, and the two disagreed.
local function taskProducesFuel(p_Name)
    local s_Name = tostring(p_Name)
    -- "charcoal" contains "coal", so it is covered. "log" catches gather:oak_log and find-oak_log.
    return s_Name:find("coal") ~= nil or s_Name:find("log") ~= nil or s_Name:find("wood") ~= nil
end

-- IS THERE ANY FUEL IN STORAGE TO CARRY?
--
-- A fuel rescue sends a drone to storage, has it pick up coal, and flies it to a stranded one. With
-- an empty store there is nothing to pick up, so the rescuer flies out, finds it has nothing to
-- give, and flies back -- spending the last mobile drone's fuel to accomplish precisely nothing.
--
-- Worse than nothing, in fact. Measured: storage held 0 coal, 0 charcoal and 0 logs, D14 sat at
-- fuel 0, and D31 -- the only miner that could still move -- was pinned to rescue-D14 while
-- lumber:oak_log went unplaced tick after tick with "every miner is busy". The one job that could
-- have ENDED the shortage was blocked by a rescue that the shortage made impossible. A deadlock
-- the fleet could not leave on its own.
--
-- So ask before queueing. nil means StorageMan did not answer, and unknown must not block a rescue:
-- an unanswered query is not evidence that the store is empty, and stranding a drone on silence is
-- the worse mistake. Only a definite zero stops it.
--
-- Deliberately reuses taskProducesFuel rather than growing a second answer to "what counts as
-- fuel" -- that question has already been answered three different ways in this file, and the
-- predicate is a plain string test that reads item names as happily as task names.
-- Burnable items in storage above which the settlement is not in a fuel emergency and fuel work
-- stops outranking everything else. 64 charcoal is a little over 5,000 fuel -- two full tanks --
-- which is enough that interrupting a gather cannot strand anybody.
local FUEL_COMFORTABLE = 64

local FUEL_STOCK_TTL = 30
local m_FuelStock, m_FuelStockAt = nil, -1000

local function storageFuelCount()
    if m_FuelStock ~= nil and (os.clock() - m_FuelStockAt) < FUEL_STOCK_TTL then return m_FuelStock end
    local s_Res = PowNet.sendAndWaitForResponse("StorageMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetStock", {}), PowNet.SERVER_PROTOCOL, 5)
    if type(s_Res) ~= "table" or type(s_Res.detail) ~= "table" then return nil end
    local s_Total = 0
    for _, e in ipairs(s_Res.detail) do
        if taskProducesFuel(e.name) then s_Total = s_Total + (tonumber(e.count) or 0) end
    end
    m_FuelStock, m_FuelStockAt = s_Total, os.clock()
    return s_Total
end

-- Does this drone still need rescuing, given what the settlement can actually send?
--
-- A fuel rescue with no fuel to carry is worse than no rescue: it occupies the last drone that can
-- still move, and the job it displaces is the one that would have ended the shortage. See
-- storageFuelCount for the deadlock this was measured in.
--
-- Its own function for the same reason expireAbandonment is one -- rescueNeeded is the most complex
-- thing in this file and the complexity gate is right to refuse to let it grow.
local m_ToldDry = {}

local function stillTrapped(p_Drone, p_Trapped, p_Dry)
    if not p_Trapped or not p_Dry then return p_Trapped end
    if storageFuelCount() ~= 0 then
        m_ToldDry[tostring(p_Drone.id)] = nil
        return p_Trapped
    end
    -- Once per drone, not once per tick. This condition persists for as long as the shortage does,
    -- and TaskMan's log is read to find out what changed.
    if not m_ToldDry[tostring(p_Drone.id)] then
        m_ToldDry[tostring(p_Drone.id)] = true
        Log(("%s is dry but storage has no fuel to bring it -- leaving it parked until there is, "
             .. "rather than spending a working drone on an empty delivery"):format(tostring(p_Drone.name)))
    end
    return false
end

-- How badly the settlement wants this fuel, not merely whether it is fuel.
--
-- taskProducesFuel answers yes for coal AND for wood, so ordering by it alone left the tie to be
-- broken by task id -- and gather:coal_ore (#6950) is older than gather:oak_log (#6968), so every
-- freed miner went underground and the lumber job was never once picked up.
--
-- These two are not equivalent. Coal is finite, sits thirty blocks down, and the shafts to it have
-- stranded three drones this session. Wood is on the surface nineteen blocks from base, regrows,
-- and one coal smelts eight logs into eight charcoal -- so wood is the only input that ENDS the
-- fuel problem rather than postponing it. When both are queued, wood goes first.
local function fuelRank(p_Name)
    local s_Name = tostring(p_Name)
    -- ASK taskProducesFuel WHETHER IT IS FUEL AT ALL. Do not re-decide it here.
    --
    -- These two both used to test for "coal" and "log" independently, which is how a settlement
    -- ends up with three different answers to "what counts as fuel" -- the state this file was in
    -- earlier today, when the emergency filter, the queue ordering and the preempt guard each had
    -- their own version and two of them had never heard of wood.
    --
    -- The ranking's only job is preference AMONG fuels; membership belongs to one function.
    if not taskProducesFuel(s_Name) then return 0 end
    -- Wood outranks coal: coal is finite and thirty blocks underground where drones strand, while
    -- wood is on the surface, regrows, and one coal turns eight logs into eight charcoal.
    if s_Name:find("log") or s_Name:find("wood") then return 2 end
    return 1
end

local function fleetFuelLow()
    local s_Total, s_Known = 0, false
    for _, d in ipairs(fleet()) do
        local f = tonumber(d.fuel)
        -- Unknown fuel must not read as zero: that would put the whole fleet into fuel-only mode
        -- on a single missing field.
        if f ~= nil then s_Total, s_Known = s_Total + f, true end
    end
    return s_Known and s_Total < FLEET_FUEL_LOW
end

-- GIVING UP MUST BE VISIBLE, NOT JUST LOGGED.
--
-- The rescue pass wrote "it needs a human" to a log nobody reads, cleared the flag, and the drone
-- vanished from every view that matters -- it still appears in the fleet list looking merely idle.
-- D6 sat in that state for FIVE HOURS AND TWELVE MINUTES holding 475 items, having walked out of
-- the loaded region entirely, and nothing anywhere said so. The give-up decision was right; three
-- rescues aimed at a position 82 blocks wrong were never going to arrive. Only the silence was wrong.
--
-- Recorded on DATA so it survives a restart and can be read back through the Abandoned endpoint,
-- which is what puts it on the map. Cleared automatically when the drone reports in again.
-- How long a written-off drone stays written off before the fleet tries again.
--
-- Long enough that a hopeless rescue is not retried every tick -- the reason the cap exists -- and
-- short enough that a drone is not lost for the night over a shortage that cleared in ten minutes.
local ABANDON_RETRY_MS = 15 * 60 * 1000

-- Let a written-off drone be tried again once the write-off is old enough.
--
-- Declared ABOVE rescueNeeded, which calls it: a local used above its declaration is a silent nil
-- global here. Kept as its own function rather than inlined because rescueNeeded is the most
-- complex thing in this file and the complexity gate is right to refuse to let it grow.
local function expireAbandonment(p_Drone, p_Key)
    local s_Ab = (DATA["abandoned"] or {})[p_Key]
    if s_Ab == nil then return end
    if (os.epoch("utc") - (s_Ab.epoch or 0)) <= ABANDON_RETRY_MS then return end
    DATA["abandoned"][p_Key] = nil
    if DATA["rescueTries"] then DATA["rescueTries"][p_Key] = nil end
    Log(("%s was written off %d min ago -- trying again, because conditions change")
        :format(tostring(p_Drone.name), math.floor(ABANDON_RETRY_MS / 60000)))
    PowNet.MarkDirty()
end

local function abandonDrone(p_Drone, p_Tries)
    local s_Key = tostring(p_Drone.id)
    DATA["abandoned"] = DATA["abandoned"] or {}
    if DATA["abandoned"][s_Key] == nil then
        DATA["abandoned"][s_Key] = {
            id = p_Drone.id, name = p_Drone.name, tries = p_Tries,
            pos = p_Drone.pos and {x = p_Drone.pos.x, y = p_Drone.pos.y, z = p_Drone.pos.z} or nil,
            reason = "three rescues reached it and it never recovered -- its reported position is "
                  .. "probably wrong, or it has left the loaded region",
            at = os.time(),
            -- A REAL CLOCK, because the abandonment expires and os.time() cannot measure elapsed
            -- time: it is the in-game clock, 0-24, and wraps every Minecraft day, so any "how long
            -- ago" built on it is wrong twice a day.
            epoch = os.epoch("utc"),
        }
        PowNet.MarkDirty()
    end
    Log(("%s has had %d rescues with no recovery -- ABANDONED, it needs a human")
        :format(tostring(p_Drone.name), p_Tries))
end

-- TELL THE DRONE, NOT JUST THE QUEUE.
--
-- Deleting a task alone leaves whoever was doing it flying to work that no longer exists: it stays
-- "working", holds nothing anyone can see, and pickDrone skips it for ever because that only
-- chooses idle drones. Both miners were in exactly that state -- busy with cancelled work, invisible
-- to the scheduler -- while four miner tasks sat unassigned.
--
-- One function because this exact pcall was written out SEVEN times, and a cancellation path that
-- forgets it is indistinguishable from one that works right up until the fleet quietly runs out of
-- drones.
local function abortAssigned(p_Task)
    if p_Task == nil or p_Task.assignedTo == nil then return end
    pcall(function()
        PowNet.sendAndWaitForResponse(p_Task.assignedTo,
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}),
            PowNet.SERVER_PROTOCOL, 3)
    end)
end

-- Drop rescues whose casualty is no longer in the fleet at all.
--
-- The "has it recovered" test can only be answered about a drone that is still listed. A RETIRED one
-- is not, so its rescue was never healthy, never cancelled and never expired: task.stop reported
-- success, the task stayed, and it held the fleet's only miner indefinitely. D1 and D2 were both
-- written off and their rescues went on consuming D3 afterwards.
local function dropRescuesForUnknownDrones(p_Known)
    local n = 0
    for k, v in pairs(DATA["tasks"] or {}) do
        local w = v.work and v.work.rescue
        if w and w.id ~= nil and not p_Known[tostring(w.id)] then
            abortAssigned(v)
            Log(("rescue for %s dropped -- that drone is no longer in the fleet")
                :format(tostring(w.drone)))
            DATA["tasks"][k] = nil
            n = n + 1
        end
    end
    return n
end

-- CANCEL A RESCUE THE MOMENT IT IS NOT NEEDED.
--
-- Distress is a flicker, not a state: a drone reports blocked, a rescue is queued, and two ticks
-- later it has recovered by itself -- but the rescue outlives it. Rescues are placed BEFORE all
-- other work by design, so stale ones crowd out everything real: two of the fleet's three assigned
-- tasks were rescues for drones that were both working perfectly at the time.
local function cancelRecoveredRescues(p_Healthy)
    local n = 0
    for k, v in pairs(DATA["tasks"] or {}) do
        local w = v.work and v.work.rescue
        if w and (v.progress or 0) < 100 and p_Healthy[tostring(w.id)] then
            abortAssigned(v)
            Log(("rescue for %s cancelled -- it recovered on its own"):format(tostring(w.drone)))
            DATA["tasks"][k] = nil
            n = n + 1
        end
    end
    return n
end

-- DROP A RESCUE THE SETTLEMENT CANNOT PERFORM.
--
-- stillTrapped stops a pointless fuel rescue being QUEUED, but says nothing about one already in
-- the queue -- and the store can empty after the task exists, which is exactly the order it happens
-- in: the rescue is queued while there is still coal, the coal is burned, and now the fleet's only
-- mobile drone is committed to delivering something that no longer exists.
--
-- It also repairs the mislabelled ones. Both rescue-D14 tasks were named "rescue-" rather than
-- "fuel-" because the drone's reported fuel was STALE when they were queued -- the heartbeat bug --
-- so nothing that keys off the task name could ever recognise them. This asks about the drone as it
-- is now, which is the only thing that was ever true.
local function dropUnfulfillableRescues(p_Dry)
    if storageFuelCount() ~= 0 then return 0 end
    local n = 0
    for k, v in pairs(DATA["tasks"] or {}) do
        local w = v.work and v.work.rescue
        if w and w.id ~= nil and p_Dry[tostring(w.id)] then
            abortAssigned(v)
            Log(("rescue for %s dropped -- it is dry and storage has no fuel to bring it, and the "
                 .. "drone this holds is the one that could go and make some"):format(tostring(w.drone)))
            DATA["tasks"][k] = nil
            n = n + 1
        end
    end
    return n
end

-- A FLICKER IS NOT A FAULT. LET IT SETTLE FIRST.
--
-- Distress oscillates. D14 alternated blocked / moving on every single pass, so a rescue was queued
-- and cancelled every fifteen seconds, indefinitely:
--
--   rescue queued for D14 (blocked) at -534,69,26
--   rescue for D14 cancelled -- it recovered on its own
--   rescue queued for D14 (blocked) at -534,69,26
--
-- Each pair costs a placement pass, churns the task table, and -- because rescues are placed BEFORE
-- all other work by design -- puts itself in front of every real job for the fifteen seconds it
-- exists. cancelRecoveredRescues was written to clean these up and does so correctly; not creating
-- them is cheaper than cancelling them.
--
-- Three consecutive passes, because a drone that is genuinely stuck stays stuck and one that is
-- merely between attempts does not. Forty-five seconds of delay on a real rescue is nothing set
-- against a drone that has already been immobile for minutes -- and rescueTries, which escalates to
-- writing a drone off, only counts attempts that were actually made.
local RESCUE_SETTLE = 3

local function settledTrapped(p_Drone, p_Trapped)
    local s_Key = tostring(p_Drone.id)
    DATA["blockedFor"] = DATA["blockedFor"] or {}
    if not p_Trapped then
        DATA["blockedFor"][s_Key] = nil
        return false
    end
    local s_N = (DATA["blockedFor"][s_Key] or 0) + 1
    DATA["blockedFor"][s_Key] = s_N
    return s_N >= RESCUE_SETTLE
end

local function rescueNeeded()
    -- One live rescue per drone. Without this the pass creates a fresh task every fifteen seconds
    -- for a drone that stays stuck -- which it will, right up until the miner arrives.
    local s_Pending = {}
    for _, v in pairs(DATA["tasks"] or {}) do
        local w = v.work and v.work.rescue
        if w and (v.progress or 0) < 100 and v.enabled ~= false and dependencyMet(v) then
            s_Pending[tostring(w.id)] = true
        end
    end

    -- No miner, no rescue. Queuing work that nothing in the fleet can perform just grows a backlog
    -- and hides the real problem, which in that case is "the fleet has no miner".
    local s_HasMiner = false
    for _, d in ipairs(fleet()) do
        if (d.role or "miner") == "miner" and not d.offline then s_HasMiner = true break end
    end
    if not s_HasMiner then return 0 end

    -- OFFLINE COUNTS TOO.
    --
    -- A drone that has stopped answering is not necessarily gone: the commonest way to go quiet here
    -- is to be somewhere a modem cannot reach out of, which is the same hole a rescue is for. We
    -- still know where it was, and a tunnel to that spot is strictly better than leaving it there.
    -- The climb-out order at the end will not reach it while it is silent, which costs nothing --
    -- the tunnel is the part that matters, and the drone rejoins on its own once it can talk again.
    --
    -- Capped, because rescues are miner work and miners are also the only thing that mines. Three at
    -- a time keeps the fleet digging its way out of a bad patch without stopping everything else.
    -- TRAPPED MINERS GET THEIR OWN BUDGET.
    --
    -- A single cap does not work here. Three scout rescues fill it, and then the two stranded miners
    -- -- the only drones that can perform a rescue at all -- can never be queued for one, so the
    -- fleet's digging capacity only ever falls. Ordering the candidates does not help either: the
    -- slots are already held. Miners therefore have a separate allowance, because freeing one adds
    -- a rescuer and freeing a scout does not.
    local s_LiveMiner, s_LiveOther = 0, 0
    for _, v in pairs(DATA["tasks"] or {}) do
        local w = v.work and v.work.rescue
        if w and (v.progress or 0) < 100 and v.enabled ~= false and dependencyMet(v) then
            if w.role == "miner" then s_LiveMiner = s_LiveMiner + 1
            else s_LiveOther = s_LiveOther + 1 end
        end
    end

    -- Miners first, so their allowance is spent on them before anything else is considered.
    local s_Order = {}
    for _, d in ipairs(fleet()) do
        if (d.role or "miner") == "miner" then s_Order[#s_Order + 1] = d end
    end
    for _, d in ipairs(fleet()) do
        if (d.role or "miner") ~= "miner" then s_Order[#s_Order + 1] = d end
    end

    -- CANCEL A RESCUE THE MOMENT IT IS NOT NEEDED.
    --
    -- Distress is a flicker, not a state: a drone reports blocked, a rescue is queued, and two ticks
    -- later it has recovered by itself -- but the rescue outlives it. Rescues are placed BEFORE all
    -- other work by design, so stale ones crowd out everything real: two of the fleet's three
    -- assigned tasks were rescues for drones that were both working perfectly at the time.
    --
    -- A rescue that has already reached its target is not cancelled -- it is finished, and its
    -- completion is what tells the rescued drone to climb out.
    local s_Healthy, s_Cancelled = {}, 0
    -- A RESCUE FOR A DRONE THAT NO LONGER EXISTS MUST DIE WITH IT.
    --
    -- The cancel test below asks "has the casualty recovered", which can only be answered about a
    -- drone that is still in the fleet list. A RETIRED drone is not in it at all -- so its rescue
    -- was never healthy, never cancelled, and never expired: task.stop reported success, the task
    -- stayed, and it held the fleet's only miner indefinitely. D1 and D2 were both written off and
    -- their rescues went on consuming D3 afterwards, which defeats the entire point of retiring
    -- them.
    local s_Known = {}
    local s_DryNow = {}
    for _, d in ipairs(fleet()) do s_Known[tostring(d.id)] = true end
    s_Cancelled = s_Cancelled + dropRescuesForUnknownDrones(s_Known)

    for _, d in ipairs(fleet()) do
        -- AN EMPTY TANK IS NOT "RECOVERED ON ITS OWN".
        --
        -- Health was judged purely on the reported status, and a drone with no fuel reports "idle"
        -- -- because idle is what a drone with no job says, and it has no job precisely because it
        -- cannot move. So the moment relief was queued for D1 this pass saw a healthy idle drone
        -- and cancelled it, freeing the only fuelled drone to go back to mining while D1 sat at
        -- zero. The relief was dispatched correctly and withdrawn before it could be performed.
        local f = tonumber(d.fuel)
        local s_Dry = f ~= nil and f < DISPATCH_FUEL_FLOOR
        -- Recorded for every drone, not just the dry ones: false is falsy and reads the same at
        -- the only place that asks, and a branch here would grow the file's largest function.
        s_DryNow[tostring(d.id)] = s_Dry
        if not (RESCUE_STATES[tostring(d.status)] or d.offline or s_Dry) then
            s_Healthy[tostring(d.id)] = true
            -- Back on its feet: forget the failed attempts, so a drone that gets into trouble again
            -- next week still gets helped. The abandonment goes with them -- a drone that is talking
            -- to us is by definition no longer the thing a human was being asked to go and find.
            if DATA["rescueTries"] then DATA["rescueTries"][tostring(d.id)] = nil end
            if DATA["abandoned"] and DATA["abandoned"][tostring(d.id)] then
                DATA["abandoned"][tostring(d.id)] = nil
                Log(("%s came back on its own -- no longer abandoned"):format(tostring(d.name)))
                PowNet.MarkDirty()
            end
        end
    end
    s_Cancelled = s_Cancelled + cancelRecoveredRescues(s_Healthy)
    s_Cancelled = s_Cancelled + dropUnfulfillableRescues(s_DryNow)
    if s_Cancelled > 0 then PowNet.MarkDirty() end

    local s_Made = 0
    for _, d in ipairs(s_Order) do
        local s_IsMiner = (d.role or "miner") == "miner"
        if s_IsMiner then
            if s_LiveMiner >= 2 then goto continue end
        else
            if s_LiveOther >= 3 then goto continue end
        end
        -- SILENCE AT DEPTH IS NOT DISTRESS.
        --
        -- `offline` means "we have not heard from it", and a drone mining at y=47 is silent for an
        -- entirely ordinary reason: a wireless modem does not reach that far down. Treating that as
        -- trapped sends a rescue to a drone that is working perfectly -- and the rescue cannot even
        -- arrive, because the target is buried under fifteen blocks of rock the rescuer has to dig
        -- through. D14 spent thirty-six minutes failing to reach D9, which was mining lapis the
        -- whole time, and TaskMan re-dispatched it after every failure.
        --
        -- A drone that is genuinely in trouble SAYS SO -- Distress sets its status, and that still
        -- counts. What no longer counts is silence alone from somewhere we know a radio cannot
        -- reach. If it is stuck down there it will report it the moment it surfaces into range.
        local s_Deep = d.pos and tonumber(d.pos.y) and tonumber(d.pos.y) < RADIO_FLOOR_Y
        local s_Trapped = RESCUE_STATES[tostring(d.status)] or (d.offline and not s_Deep)

        -- AN EMPTY TANK IS NOT AN ENTOMBMENT, AND A RESCUE PARTY CANNOT FIX IT.
        --
        -- The party carries a chunk loader, a GPS relay and a pickaxe -- the three things a drone
        -- that cannot MOVE might be missing. None of them is fuel. Sent to a drone that simply ran
        -- dry, it arrives, digs a tunnel to a drone that is not walled in, and leaves it exactly as
        -- immobile as it found it.
        --
        -- That is not merely useless, it is actively harmful, and it livelocked this fleet: with
        -- two of three drones dry, the rescue pass generated a rescue for each of them and handed
        -- it to the ONLY drone that still had fuel -- the same drone that would otherwise have gone
        -- and mined the coal that fixes the actual problem. Cancel one and it queued the other
        -- within a minute. The fleet had exactly one way out and rescue kept spending it.
        --
        -- So a fuel casualty is not a rescue candidate. It still shows as stuck, it still reports
        -- Distress, and refuelling is a job for the fuel path -- not for a tunnel.
        -- A DRY DRONE NEEDS FUEL, NOT A TUNNEL -- SO SEND IT FUEL.
        --
        -- This used to skip fuel casualties entirely, because a rescue party carries a chunk
        -- loader, a relay and a pickaxe and none of them is fuel: sending one arrived, dug to a
        -- drone that was not walled in, and left it exactly as immobile as it found it, while
        -- consuming the only drone still able to move. Skipping them stopped the livelock but left
        -- them stranded for ever.
        --
        -- Relief is the missing third kind of rescue. The rescuer loads coal from storage, stands
        -- on top of the casualty and drops it; the casualty's own fuel watchdog sucks it up and
        -- burns it without needing to know a rescue happened. See OnRelieve.
        local s_Fuel = tonumber(d.fuel)
        -- TRUST A LOW FUEL READING. DO NOT TRUST A HIGH ONE.
        --
        -- d.fuel is replayed from the last heartbeat that reached base, so it is stalest for exactly
        -- the drones in trouble -- a stale HIGH reading is the NORMAL case for a casualty. D21 was
        -- on the books at 2,534 fuel while a probe of the turtle itself returned 0. Requiring
        -- s_Trapped on top of that made it stricter again.
        --
        -- Getting this wrong is not symmetric, which is what makes the old test dangerous:
        --   * calling a DRY drone "trapped" names the task rescue-, which pins it to a MINER -- and
        --     the thing that empties one miner's tank is an empty larder, which empties all of them
        --     at once. The task is then unassignable precisely when it is needed. Measured just now:
        --     rescue-D9, rescue-D20 and rescue-D21 all queued, all role=miner, all unassigned, with
        --     D15 and D12 sitting at a probed ZERO and the only fuelled drone in the settlement a
        --     crafter holding 948.
        --   * calling a TRAPPED drone "dry" sends someone with coal, which any drone can carry. If
        --     that was the wrong guess the attempt fails cheaply and rescueTries escalates.
        --
        -- So: unknown fuel counts as dry, and being trapped is no longer a precondition for it.
        local s_Dry = (s_Fuel == nil) or (s_Fuel < DISPATCH_FUEL_FLOOR)
        -- STRANDED MINERS GET RESCUED TOO.
        --
        -- This skipped them on the theory that a miner can dig itself out. It can, right up until it
        -- cannot -- out of fuel, wedged, or with no position fix to steer by -- and then it sits
        -- there exactly as helplessly as a scout does, with the added cost that it is one of the few
        -- drones that could have freed anyone else. D1 and D5 were both stranded underground while
        -- the pass that exists to unstick drones deliberately looked past them.
        --
        -- There is no risk of a drone being sent to rescue itself: pickDrone only ever chooses a
        -- drone whose status is "idle", and a drone that needs rescuing is by definition not.
        -- A RESCUE THAT HAS ALREADY FAILED REPEATEDLY IS NOT WORTH A FOURTH DRONE-HOUR.
        --
        -- Rescues are queued from a drone's LAST REPORTED position, and a drone that has gone quiet
        -- is exactly the drone whose reported position is most likely to be stale. D1 drifted
        -- outside the operating region and stopped ticking; its record still said -443,64,66, well
        -- inside. So every tick queued a rescue to an empty patch of ground, handed it to the only
        -- healthy miner, and repeated -- while D2 sat at zero fuel waiting for relief that never
        -- got a rescuer. Three attempts is enough to conclude the position is wrong; after that it
        -- is a fault for a human to look at, not work to keep spending drones on.
        DATA["rescueTries"] = DATA["rescueTries"] or {}
        local s_Key = tostring(d.id)

        -- ABANDONMENT MUST EXPIRE. "IT NEEDS A HUMAN" CANNOT BE A TERMINAL STATE IN A SETTLEMENT
        -- WHOSE ENTIRE PURPOSE IS RUNNING WITHOUT ONE.
        --
        -- Three failed rescues means three attempts failed under the conditions of that moment -- an
        -- empty larder, a role gate, a position that was wrong, a bug since fixed. None of those are
        -- permanent. The counter was: it is cleared only when the drone reports healthy, and a drone
        -- at zero fuel cannot become healthy without the relief that abandonment is blocking. That
        -- circle is closed by hand or not at all.
        --
        -- Measured: D12, D14 and D15 all ABANDONED, all at a probed ZERO fuel, with 64 coal sitting
        -- in storage and a working relief path that had never once been tried on them -- because
        -- their three strikes were spent on the role-pinning and stale-fuel bugs that are now fixed.
        -- The fleet had written off every miner it owned over failures that no longer existed.
        --
        -- So the write-off decays. It still stops the tick spending drones on a hopeless position
        -- for the next quarter of an hour, which is what it is for; it just stops being forever.
        expireAbandonment(d, s_Key)

        local s_Tries = DATA["rescueTries"][s_Key] or 0
        if s_Trapped and s_Tries >= 3 and not s_Pending[s_Key] then
            -- GIVING UP MUST BE VISIBLE, NOT JUST LOGGED.
            --
            -- This wrote "it needs a human" to a log nobody reads, cleared the flag, and the drone
            -- vanished from every view that matters -- it still appears in the fleet list looking
            -- merely idle. D6 sat in that state for FIVE HOURS AND TWELVE MINUTES holding 475
            -- items, having walked out of the loaded region entirely, and nothing anywhere said so.
            -- The give-up decision was correct; three rescues aimed at a position that was 82
            -- blocks wrong were never going to arrive. Only the silence about it was wrong.
            --
            -- Recorded on DATA so it survives a restart and can be read back through Abandoned,
            -- which is what puts it on the map. Cleared automatically when the drone reports in
            -- again -- see the healthy sweep above, which already forgets rescueTries.
            abandonDrone(d, s_Tries)
            s_Trapped = false
        end

        -- A DISTRESS THAT CLEARS BY ITSELF NEXT TICK IS NOT ONE -- see settledTrapped.
        s_Trapped = settledTrapped(d, s_Trapped)

        -- A FUEL RESCUE WITH NO FUEL TO CARRY IS WORSE THAN NO RESCUE -- see stillTrapped.
        s_Trapped = stillTrapped(d, s_Trapped, s_Dry)

        if s_Trapped and d.pos and d.pos.x and d.pos.y and d.pos.z
                and not s_Pending[tostring(d.id)] then
            DATA["rescueTries"][s_Key] = s_Tries + 1
            local s_TaskID = DATA["lastTask"]
            DATA["lastTask"] = DATA["lastTask"] + 1
            DATA["tasks"][s_TaskID] = {
                id = s_TaskID,
                name = (s_Dry and "fuel-" or "rescue-") .. tostring(d.name),
                work = {rescue = {id = d.id, drone = d.name, role = (d.role or "miner"),
                                  fuel = s_Dry or nil,
                                  pos = {x = d.pos.x, y = d.pos.y, z = d.pos.z}}},
                progress = 0, enabled = true, paused = false,
            }
            s_Pending[tostring(d.id)] = true
            s_Made = s_Made + 1
            if s_IsMiner then s_LiveMiner = s_LiveMiner + 1 else s_LiveOther = s_LiveOther + 1 end
            Log(("rescue queued for %s (%s%s) at %s,%s,%s"):format(
                tostring(d.name), tostring(d.status),
                (d.offline and tostring(d.status) ~= "offline") and ", offline" or "",
                tostring(d.pos.x), tostring(d.pos.y), tostring(d.pos.z)))
        end
        ::continue::
    end
    if s_Made > 0 then PowNet.MarkDirty() end
    return s_Made
end

-- Place rescues BEFORE anything else.
--
-- The general placement pass gives up on a whole role the moment one task of that role cannot be
-- placed (s_NoDrone), so a rescue could sit behind an unplaceable mining task indefinitely. A drone
-- that cannot move is burning fuel it cannot replace, so this gets its own pass and its own budget.
-- A TASK OTHERS ARE WAITING ON OUTRANKS ANYTHING SPECULATIVE.
--
-- The queue is a tree -- build waits on crafts, crafts wait on materials -- but placement walked it
-- as a flat list, so the fleet round-robined speculative gathers (coal, iron, zinc, lapis) while
-- the ONE task the whole chain was waiting on went unassigned. Two miners on coal and iron, nobody
-- on the wood, and craft-oak_planks stalled at "no crafter free" behind the very task it was
-- blocking.
--
-- A blocker is any unassigned task that some other live task dependsOn. Those go first, and they
-- may interrupt: an ordinary gather can be resumed (see Resumable), a blocked pipeline cannot make
-- progress at all. The drone chosen is the one that can get there in the fewest steps, which is
-- what pickDrone already does -- a miner inside the base beats one forty blocks out, even if the
-- distant one happens to be idle and the near one is busy.
-- Drones the rescue pass has stopped trying to save. Read-only, and deliberately its own endpoint
-- rather than a field on the task list: an abandoned drone has NO task -- that is the whole point --
-- so every view built on the queue shows it as an ordinary idle drone. D6 looked idle for five
-- hours while sitting outside the loaded region with 475 items aboard.
function OnAbandoned(p_ID, p_Message)
    local s_Out = {}
    for _, v in pairs(DATA["abandoned"] or {}) do s_Out[#s_Out + 1] = v end
    return true, {abandoned = s_Out}
end

-- A DRONE THAT SAYS NO MUST BE BELIEVED IMMEDIATELY.
--
-- Dispatch is fire-and-forget -- SendToDrone does not wait -- and the assignment was recorded no
-- matter what the drone did with it. A drone already working refuses ("JOB Build REFUSED: busy"),
-- and nothing here ever heard it, so the task stayed bound to a drone that would never run it.
--
-- It cannot be caught by the stalled-assignment sweep either: that releases work held by drones
-- reporting IDLE, and a drone that refused because it was busy is precisely not idle. Thirteen
-- tower-floor tasks sat in that state at once, six of them "assigned", none of them started, and
-- the queue looked fully staffed the whole time.
--
-- Releasing costs nothing when the refusal is stale: the task simply goes back to a queue that will
-- offer it to whoever is genuinely free on the next pass.
function OnTaskRefused(p_ID, p_Message)
    local d = p_Message and p_Message.data or {}
    local t = DATA["tasks"] and DATA["tasks"][tonumber(d.taskId)]
    if t == nil then return true, {released = false, reason = "no such task"} end
    -- Only the drone we actually gave it to may hand it back, or a late refusal from a previous
    -- assignment would cancel whoever is doing the work now.
    if d.drone ~= nil and t.assignedTo ~= nil and tonumber(d.drone) ~= tonumber(t.assignedTo) then
        return true, {released = false, reason = "refusal from a drone that does not hold it"}
    end
    Log(("%s refused by %s (%s) -- back in the queue")
        :format(tostring(t.name), tostring(t.assigned or d.drone), tostring(d.why)))
    t.assigned, t.assignedTo, t.assignedAt = nil, nil, nil
    PowNet.MarkDirty()
    return true, {released = true}
end

function OnTaskProgress(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Id = tostring(d.id or "")
    local s_P = tonumber(d.progress)
    if s_Id == "" or s_P == nil then return false, "need id and progress" end
    for _, v in pairs(DATA["tasks"] or {}) do
        if tostring(v.id) == s_Id then
            -- Capped below 100: only TaskDone may complete a task, or a progress report would
            -- retire work that has not actually finished.
            v.progress = math.max(0, math.min(99, math.floor(s_P)))
            PowNet.MarkDirty()
            return true, {id = v.id, progress = v.progress}
        end
    end
    return false, "no such task"
end

local function blockers()
    local s_Needed = {}
    for _, v in pairs(DATA["tasks"] or {}) do
        if v.dependsOn ~= nil and (v.progress or 0) < 100 and v.enabled ~= false
           and not dependencyMet(v) then
            s_Needed[tostring(v.dependsOn)] = true
        end
    end
    local s_Out = {}
    for _, v in pairs(DATA["tasks"] or {}) do
        if s_Needed[tostring(v.id)] and v.assigned == nil
                and (v.progress or 0) < 100 and v.enabled ~= false and not v.paused then
            s_Out[#s_Out + 1] = v
        end
    end
    return s_Out
end

-- May this task be interrupted so its drone can go and relieve a dry one?
--
-- The whole condition lives here rather than inline so the preempt loop stays inside the
-- complexity gate, and so the rule can be read in one place: it must be THIS drone's task, still
-- unfinished, not itself a rescue -- and not the coal gather, because relief with no coal in
-- storage fails and requeues, and preempting the gather means it can never succeed.
local function preemptable(p_Task, p_DroneId)
    if p_Task.assignedTo ~= p_DroneId then return false end
    if (p_Task.progress or 0) >= 100 then return false end
    if p_Task.work and p_Task.work.rescue then return false end
    -- taskProducesFuel, NOT a local copy. There was one here that matched only "coal" and
    -- "charcoal", so gather:oak_log read as ordinary work and was preempted for rescue duty every
    -- pass. Caught in D15's log mid-run:
    --
    --   JOB Gather start {"taskId":6968, ... oak_log ...}
    --   GoTo received from 12
    --   Aborting (was executing: true)
    --
    -- which is the deadlock this guard exists to prevent, arriving through the guard itself: relief
    -- with nothing burnable in storage fails and requeues, and the task it keeps interrupting is the
    -- only one that would end the shortage. Wood is fuel -- a log burns, and one coal turns eight of
    -- them into eight charcoal.
    --
    -- That is now THREE copies of "what counts as fuel" this file has had to be corrected on today
    -- (the emergency filter, the queue ordering, and this). One function, used everywhere.
    --
    -- WHILE THE LARDER IS EMPTY. The exemption was unconditional, and that turned a guard against
    -- one deadlock into the cause of another.
    --
    -- There is ALWAYS a fuel gather running -- wood and coal are both wanted permanently, and both
    -- match taskProducesFuel -- so with the exemption always on, a fuel task can never be preempted
    -- and therefore a blocker can never take a drone off one. placeBlockers has no other way to
    -- find a body when every drone is busy.
    --
    -- Measured: shaft-mine_head-01, the ONLY route to redstone and therefore to wired modems,
    -- storage and everything above it, sat "queued: no miner free" for hours across four fleet
    -- configurations, while D35 ran gather:oak_log and D31 ran gather:coal_ore. Neither could be
    -- interrupted, both restart the moment they finish, and the shaft never once reached a drone.
    -- It never even appeared in this log, because blockers do not go through the placement loop
    -- that reports "could not place".
    --
    -- So the exemption applies when it means something: fuel work is protected while the settlement
    -- is short of fuel, and is ordinary work when it is not. An unanswered StorageMan reads as
    -- short, which keeps the protective behaviour on silence.
    if taskProducesFuel(p_Task.name) then
        return (storageFuelCount() or 0) >= FUEL_COMFORTABLE
    end
    return true
end

local function placeBlockers()
    local s_List = blockers()
    if #s_List == 0 then return 0 end

    local s_Placed = 0
    for _, v in ipairs(s_List) do
        if OnStartTask(0, {data = {id = v.id}}) then
            Log(("blocker %s placed -- other work is waiting on it"):format(tostring(v.name)))
            s_Placed = s_Placed + 1
        else
            -- Nobody free. Take the nearest drone off work that nothing is waiting on.
            local s_Role = RoleForWork(v.work)
            local s_Where = workPos(v)
            local s_Best, s_BestD, s_BestTask = nil, nil, nil
            for _, d in ipairs(fleet()) do
                if RoleFits(d, s_Role) and not d.offline and hasFuel(d) then
                    for _, t in pairs(DATA["tasks"] or {}) do
                        -- THE SAME QUESTION THE RESCUE PREEMPT ASKS, SO IT GETS THE SAME ANSWER.
                        --
                        -- This had its own looser copy of the condition -- this drone's task,
                        -- unfinished, not a rescue -- and no fuel exemption at all. So the guard
                        -- that stops relief interrupting the lumber run did nothing here, and
                        -- gather:oak_log was interrupted to clear a blocker instead. Same abort,
                        -- different caller: "JOB Gather start ... oak_log" then "Aborting (was
                        -- executing: true)" ninety seconds later, over and over.
                        --
                        -- Interrupting the only job that ends the fuel shortage is self-defeating
                        -- whoever does it, so both paths now ask preemptable().
                        if preemptable(t, d.id) then
                            -- Never preempt another blocker; that just moves the problem.
                            local s_IsBlocker = false
                            for _, w in ipairs(s_List) do
                                if tostring(w.id) == tostring(t.id) then s_IsBlocker = true break end
                            end
                            if not s_IsBlocker then
                                local s_D = distTo(d, s_Where)
                                if s_BestD == nil or s_D < s_BestD then
                                    s_Best, s_BestD, s_BestTask = d, s_D, t
                                end
                            end
                        end
                    end
                end
            end
            if s_Best then
                Log(("interrupting %s on %s -- %s is blocking other work")
                    :format(tostring(s_Best.name), tostring(s_BestTask.name), tostring(v.name)))
                pcall(function()
                    PowNet.sendAndWaitForResponse(s_Best.id,
                        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}),
                        PowNet.SERVER_PROTOCOL, 3)
                end)
                s_BestTask.assigned, s_BestTask.assignedTo, s_BestTask.assignedAt = nil, nil, nil
                PowNet.MarkDirty()
                return s_Placed          -- place it on the next tick, once the drone is idle
            end

            -- SAY WHY A BLOCKER IS GOING NOWHERE. THIS PATH WAS ENTIRELY SILENT.
            --
            -- The ordinary placement loop reports "could not place X (role): reason" every tick.
            -- Blockers bypass it, and when placeBlockers could neither start nor preempt it simply
            -- fell through and tried again next tick, for ever, saying nothing.
            --
            -- shaft-mine_head-01 -- the only route to redstone -- sat unplaced for hours and never
            -- appeared in this log ONCE. Every diagnosis of it was therefore guesswork against
            -- hive.plan's "no miner free", which is HQ describing the fleet, not TaskMan explaining
            -- its own decision. Two separate wrong theories came out of that gap.
            Log(("blocker %s could not be placed: no free %s, and nothing preemptable on %d drone(s)")
                :format(tostring(v.name), tostring(s_Role), #fleet()))
        end
    end
    return s_Placed
end

local function placeRescues()
    -- TRAPPED MINERS FIRST.
    --
    -- Only a miner can perform a rescue, so every stranded miner is both a drone that needs freeing
    -- and a rescuer the fleet has lost -- and with five miners in a fleet of twenty-three, two of
    -- them stuck underground is most of the digging capacity gone. Freeing those first is what stops
    -- this deadlocking: each one recovered can go and get the next.
    local s_Mine, s_Rest = {}, {}
    for _, v in pairs(DATA["tasks"] or {}) do
        if v.work and v.work.rescue and v.assigned == nil
                and (v.progress or 0) < 100 and v.enabled ~= false then
            if v.work.rescue.role == "miner" then s_Mine[#s_Mine + 1] = v
            else s_Rest[#s_Rest + 1] = v end
        end
    end

    local s_Placed, s_Tried = 0, 0
    for _, list in ipairs({s_Mine, s_Rest}) do
        for _, v in ipairs(list) do
            -- Try the next one rather than giving up on the whole set. A rescue can fail to place
            -- for a reason specific to it, and stopping there would leave every rescue behind it
            -- unplaced for reasons that had nothing to do with them.
            if OnStartTask(0, {data = {id = v.id}}) then
                s_Placed = s_Placed + 1
                if s_Placed >= 2 then return s_Placed end
            end
            s_Tried = s_Tried + 1
            if s_Tried >= 4 then break end             -- no free miner; the rest wait a tick
        end
        if s_Tried >= 4 then break end
    end

-- Does this task, if left alone, end the fuel shortage? Used to keep it safe from preemption.

    -- A DRY DRONE OUTRANKS A GATHER. PREEMPT FOR IT.
    --
    -- Placement only ever considers IDLE drones, and a busy fleet is never idle at the instant this
    -- pass runs -- D3 went straight from one gather to the next for half an hour while fuel-D1 and
    -- fuel-D2 sat unassigned and both drones sat at zero. Waiting for a natural gap is not a plan
    -- when the drones that would create the gap are the ones that need rescuing.
    --
    -- Only fuel relief preempts, and only ordinary work is preempted -- never another rescue. The
    -- aborted task keeps its progress and goes straight back in the queue, so the cost is one
    -- interrupted trip against a drone that is otherwise stranded indefinitely.
    if s_Placed == 0 then
        local s_Wanted = nil
        for _, list in ipairs({s_Mine, s_Rest}) do
            for _, v in ipairs(list) do
                if v.work.rescue.fuel then s_Wanted = v break end
            end
            if s_Wanted then break end
        end

        if s_Wanted then
            for _, d in ipairs(fleet()) do
                local f = tonumber(d.fuel)
                if (f == nil or f >= RELIEF_FUEL_FLOOR) and not d.offline and d.status ~= "idle" then
                    for _, t in pairs(DATA["tasks"] or {}) do
                        -- NEVER PREEMPT THE WORK THAT PRODUCES THE FUEL.
                        --
                        -- Relief needs coal in storage to deliver. When storage is empty the relief
                        -- FAILS -- "no fuel to deliver: storage had nothing burnable" -- requeues,
                        -- and preempts again on the next pass. If the task it keeps preempting is
                        -- the coal gather, the settlement can never restock, and this loop is what
                        -- stops it: it needs coal to get coal.
                        --
                        -- Seen in TaskMan's own log, over and over:
                        --   task 5274 failed (no fuel to deliver: storage had nothing burnable)
                        --   preempting gather:oak_log on D16 -- D3 is out of fuel and needs relief
                        --   dispatch Relieve -> D16 (task 5274)
                        -- while storage coal sat at 0 and four drones sat dry.
                        --
                        -- A dry drone still outranks an ordinary gather -- that is why this preempt
                        -- exists and it is right. It does not outrank the only task that can end
                        -- the shortage for everybody, including itself.
                        if preemptable(t, d.id) then
                            Log(("preempting %s on %s -- %s is out of fuel and needs relief")
                                :format(tostring(t.name), tostring(d.name), tostring(s_Wanted.work.rescue.drone)))
                            pcall(function()
                                PowNet.sendAndWaitForResponse(d.id,
                                    PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}),
                                    PowNet.SERVER_PROTOCOL, 3)
                            end)
                            t.assigned, t.assignedTo, t.assignedAt = nil, nil, nil
                            PowNet.MarkDirty()
                            -- Place it on the next tick, once the drone has actually gone idle.
                            return s_Placed
                        end
                    end
                end
            end
        end
    end

    return s_Placed
end

-- COLLAPSE DUPLICATE WORK.
--
-- Two identical unassigned tasks are not twice the work, they are the same work queued twice -- and
-- a queue full of them starves everything else, because the placement pass walks tasks in arbitrary
-- order and keeps finding another copy of a job it cannot place. The queue reached 158 live with two
-- assigned: nine copies of find-iron_ore, eight of find-copper_ore, and one scout.
--
-- Dedup at the source stops it happening again; this clears what is already there. Only UNASSIGNED
-- duplicates are dropped -- one already given to a drone is real work in progress, and the drone
-- holding it would report against a task that had vanished.
local function dedupeQueue()
    local s_Seen, s_Dropped = {}, 0
    for k, v in pairs(DATA["tasks"] or {}) do
        local s_Name = v.name
        if type(s_Name) == "string" and (v.progress or 0) < 100 and v.enabled ~= false then
            if v.assigned ~= nil then
                s_Seen[s_Name] = true             -- the assigned copy is the one that survives
            elseif s_Seen[s_Name] then
                DATA["tasks"][k] = nil
                s_Dropped = s_Dropped + 1
            else
                s_Seen[s_Name] = true
            end
        end
    end
    if s_Dropped > 0 then
        Log(("dropped %d duplicate task(s) already queued under the same name"):format(s_Dropped))
        PowNet.MarkDirty()
    end
end

-- A DRONE BUSY WITH NOTHING IS THE MIRROR OF A TASK HELD BY NOBODY.
--
-- The reclaim pass walks TASKS and asks who holds them, so it can only ever find a task with a bad
-- drone. It cannot see the opposite: a drone still executing work whose task no longer exists.
-- That happens whenever a task is deleted out from under a drone -- a cancelled rescue, a pruned
-- duplicate -- and the result is a drone that reports "working" for ever, holds nothing anyone can
-- see, and is skipped by pickDrone permanently, because pickDrone only chooses idle drones. Both
-- miners sat like that while four miner tasks went unassigned.
--
-- Aborting is safe: if it really were mid-job the task would still exist and it would not be here.
-- THE SAME DISAGREEMENT THE OTHER WAY ROUND.
--
-- freeOrphanedDrones handles a drone that is BUSY WITH NO TASK. This handles a TASK ASSIGNED TO A
-- DRONE THAT IS IDLE, which nothing did -- and it is the more expensive of the two, because it
-- wedges both sides at once. The task never progresses, because nobody is doing it; the drone never
-- gets other work, because committed() skips anyone holding an assignment. Neither is faulty and
-- neither can move.
--
-- Measured live: four tasks in that state -- gather:oak_log on D12, shaft-mine_head-01 on D8,
-- rescue-D7 on D14, gather:copper_ore on D13 -- while four tasks sat unassigned and six drones sat
-- idle. Half the fleet unavailable, and the queue looked busy the whole time.
--
-- Sustained, never momentary, and for the same reason as the orphan pass: there is a real window
-- between dispatch and the drone reporting itself working, and clearing inside it would cancel work
-- that was about to start. `status` comes from heartbeats and therefore lags.
local m_IdleAssignedSince = nil
local function releaseStalledAssignments()
    local s_By = {}
    for _, d in ipairs(fleet()) do s_By[tostring(d.id)] = d end
    m_IdleAssignedSince = m_IdleAssignedSince or {}
    local s_Freed = 0

    for _, v in pairs(DATA["tasks"] or {}) do
        local s_Key = tostring(v.id)
        local d = v.assignedTo ~= nil and s_By[tostring(v.assignedTo)] or nil
        local s_Stalled = d ~= nil and not d.offline and d.status == "idle"
                          and (v.progress or 0) < 100 and v.enabled ~= false
        if s_Stalled then
            m_IdleAssignedSince[s_Key] = m_IdleAssignedSince[s_Key] or os.epoch("utc")
            if (os.epoch("utc") - m_IdleAssignedSince[s_Key]) > 60000 then
                Log(("%s is assigned to %s which reports idle -- putting it back in the queue")
                    :format(tostring(v.name), tostring(d.name or d.id)))
                v.assignedTo = nil
                m_IdleAssignedSince[s_Key] = nil
                s_Freed = s_Freed + 1
            end
        else
            m_IdleAssignedSince[s_Key] = nil
        end
    end
    if s_Freed > 0 then PowNet.MarkDirty() end
    return s_Freed
end

local function freeOrphanedDrones()
    local s_Held = {}
    for _, v in pairs(DATA["tasks"] or {}) do
        if v.assignedTo ~= nil and (v.progress or 0) < 100 then s_Held[tostring(v.assignedTo)] = true end
    end
    for _, d in ipairs(fleet()) do
        -- DOCKING IS NOT AN ORPHAN. IT IS A DRONE PARKING ITSELF.
        --
        -- This pass frees a drone that is "busy" while holding no task. Since idle drones now go
        -- and sit on a dock -- so they stop squatting the storage point, which is what stalled the
        -- whole build chain -- "docking with no task" is the normal, correct state, and aborting it
        -- every sixty seconds just fights the drone: "D3 is docking with no task -- aborting so it
        -- can be given work", over and over, while the queue was empty and there was no work to
        -- give. A docked drone is already available; RunJob undocks it the instant it accepts a job.
        local s_Busy = d.status ~= nil and d.status ~= "idle" and d.status ~= "offline"
            and d.status ~= "docking"
        -- NOT THE ONES THAT HAVE NO FUEL.
        --
        -- The whole point of this pass is to make a drone available for work. A drone below the
        -- dispatch floor cannot be given work -- pickDrone refuses it -- so aborting it achieves
        -- nothing except clearing the distress that marks it as needing rescue. D2 was aborted once
        -- a minute for exactly that reason, flipping between "stuck" and "idle" and destabilising
        -- the rescue bookkeeping that was trying to get fuel to it.
        local f = tonumber(d.fuel)
        if f ~= nil and f < DISPATCH_FUEL_FLOOR then s_Busy = false end
        if s_Busy and not d.offline and not s_Held[tostring(d.id)] then
            m_OrphanSince = m_OrphanSince or {}
            local s_Key = tostring(d.id)
            m_OrphanSince[s_Key] = m_OrphanSince[s_Key] or os.epoch("utc")
            -- Sustained, not momentary: there is a real window between a drone accepting work and
            -- the assignment being recorded, and aborting inside it would cancel live work.
            if (os.epoch("utc") - m_OrphanSince[s_Key]) > 60000 then
                Log(("%s is %s with no task -- aborting so it can be given work")
                    :format(tostring(d.name), tostring(d.status)))
                pcall(function()
                    PowNet.sendAndWaitForResponse(d.id,
                        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Abort", {}),
                        PowNet.SERVER_PROTOCOL, 3)
                end)
                m_OrphanSince[s_Key] = nil
            end
        elseif m_OrphanSince then
            m_OrphanSince[tostring(d.id)] = nil
        end
    end
end

-- THE ORDER TASKS ARE OFFERED IN, WHICH UNTIL NOW WAS WHATEVER pairs() FELT LIKE.
--
-- The placement loop walked DATA["tasks"] with pairs(), i.e. hash order, i.e. arbitrary -- so which
-- job the one free miner received was a coin flip. Caught in the act: gather:coal_ore took the only
-- fuelled miner in the settlement, sending it after ore thirty blocks underground where three
-- drones have already stranded, while gather:oak_log -- surface, nineteen blocks out, and the ONLY
-- renewable fuel this settlement has -- sat unassigned right beside it.
--
-- `priority` has been stored on every task since it was created and read by absolutely nothing.
--
-- Fuel work outranks everything else at equal priority, for the reason the supply loop already
-- states: every other thing the settlement wants is downstream of being able to move. Ties then go
-- to the oldest task, so nothing starves behind a stream of new arrivals -- which is a real risk
-- here, because rescues are generated continuously.
-- LOWER IS MORE URGENT. THE SORT HAD IT THE OTHER WAY UP.
--
-- Every definition of priority in this system says one is the top: order.issue documents "1 is
-- highest -- issuing at 1 pushes existing work down", and the supply loop's own comments say
-- support work is "queued at priority 1, AHEAD of exploration" and that "these tasks sit at
-- priority 1, so a stale one outranks" the rest. The sort below compared them the other way, so
-- every priority anybody set did the exact opposite of what it says on the tin.
--
-- Measured: the redstone shaft is created at priority 2 and the wood gathers at 3, so the gathers
-- won -- permanently. shaft-mine_head-01 sat "queued: no miner free" through four miners working,
-- and redstone stayed at 0, which is the one item gating wired modems, therefore storage, therefore
-- everything. Reading priority at all is recent (the comment above says it was stored and read by
-- nothing for most of this project's life), so this was wrong from the moment it started mattering.
--
-- Anything unset, or stored under the old `or -1` default, sorts LAST -- under the old comparison
-- -1 meant "least urgent", and it has to keep meaning that or every legacy task jumps the queue.
local function priorityOf(p_Task)
    local n = tonumber(p_Task.priority)
    if n == nil or n < 1 then return 9 end
    return n
end

local function orderedTasks()
    local s_List = {}
    for k, v in pairs(DATA["tasks"] or {}) do
        s_List[#s_List + 1] = {key = k, task = v}
    end
    table.sort(s_List, function(a, b)
        local pa = priorityOf(a.task)
        local pb = priorityOf(b.task)
        if pa ~= pb then return pa < pb end
        local fa = fuelRank(a.task.name)
        local fb = fuelRank(b.task.name)
        if fa ~= fb then return fa > fb end
        return (tonumber(a.task.id) or 0) < (tonumber(b.task.id) or 0)
    end)
    return s_List
end

function Tick()
    while true do
        os.sleep(TICK_SECONDS)
        pcall(pruneFinished)
        pcall(dedupeQueue)
        pcall(freeOrphanedDrones)
        pcall(releaseStalledAssignments)
        pcall(rescueNeeded)
        pcall(placeRescues)
        -- Straight after rescues: a drone that cannot move is the only thing more urgent than a
        -- pipeline that cannot progress.
        pcall(placeBlockers)
        local s_Ok, s_Err = pcall(function()
            local s_NoDrone, s_Started = {}, 0
            -- How many tasks of a role may fail to place before the role is written off for this
            -- pass. See the note at the failure branch below.
            local s_Fails = {}
            for _, s_Entry in ipairs(orderedTasks()) do
                local k, v = s_Entry.key, s_Entry.task
                -- Unassigned, enabled, not paused, not finished: try to place it. pickDrone
                -- returns nothing when every drone of that role is busy, so this quietly
                -- retries next tick rather than failing loudly every 15 seconds.
                -- RECLAIM A DEAD ASSIGNMENT.
                --
                -- Dispatch is fire-and-forget, so a drone that refuses the order ("busy") leaves
                -- the task marked assigned and it is never looked at again -- which is how a chest
                -- task sat forever behind planks that had already been made. If the drone we gave
                -- it to has gone idle again and the task still shows no progress, the order did
                -- not take; put it back in the queue rather than leaving it stranded.
                if v.assigned ~= nil and (v.progress or 0) < 100 and v.enabled ~= false then
                    -- No stamp means the task was assigned before assignments were stamped -- i.e. long ago.
                    -- Defaulting that to 0 reads as "just assigned" and makes exactly the oldest,
                    -- most definitely-stuck tasks the only ones that can never be reclaimed.
                    local s_Age = v.assignedAt and (os.epoch("utc") - v.assignedAt) or math.huge
                    if s_Age > RECLAIM_AFTER_MS then
                        -- RECLAIM FROM A STUCK DRONE TOO, NOT ONLY AN IDLE ONE.
                        --
                        -- This asked for `idle` and nothing else, which quietly excluded the exact
                        -- case the reclaim exists for. D7 and D8 sat wedged for hours reporting
                        -- "stuck", and every fifteen seconds TaskMan logged
                        --
                        --     reclaim? task 54 held by 210: stuck
                        --
                        -- and then declined, because stuck is not idle. The task stayed assigned to
                        -- a drone that could not move, so it was never given to one that could, and
                        -- the drone stayed "on a job" so nothing else would recall it. Two drones
                        -- and two tasks, deadlocked on a word.
                        --
                        -- Idle means "took the order and finished or refused it". Stuck, blocked and
                        -- offline all mean "will not finish it". For a task that has already outlived
                        -- the reclaim window, they are the same thing and should be treated alike.
                        local s_Free, s_Saw = false, "not in fleet list"
                        for _, d in ipairs(fleet()) do
                            if d.id == v.assignedTo then
                                s_Saw = tostring(d.status) .. (d.offline and " offline" or "")
                                -- Idle means it took the order and finished or refused it. Safe --
                                -- BUT ONLY ONCE IT HAS HAD TIME TO TAKE IT.
                                --
                                -- Dispatch is fire-and-forget over rednet, and the drone's status
                                -- only changes once it has received the message, started the job
                                -- AND heartbeated. Freeing the task the moment the drone still
                                -- reads "idle" reclaims work that is one tick from starting -- and
                                -- then re-dispatches it, and reclaims it again. fuel-D2 went round
                                -- that loop for half an hour: "dispatch Relieve -> D3", "reclaiming
                                -- task 1511 -- never started", over and over, while D2 sat at zero
                                -- fuel and D3 sat idle a few blocks from the coal that would have
                                -- fixed it.
                                --
                                -- One grace window is enough. A drone that is genuinely not going
                                -- to start is still freed on the next pass.
                                local s_Age = v.assignedAt and (os.epoch("utc") - v.assignedAt) or math.huge
                                if d.status == "idle" and not d.offline and s_Age > RECLAIM_GRACE_MS then
                                    s_Free = true
                                end

                                -- STUCK MUST BE SUSTAINED, NOT MOMENTARY.
                                --
                                -- Reclaiming on a single stuck/blocked report was too eager: a
                                -- drone reports "blocked" transiently while travelling -- one
                                -- refused step is enough -- and reclaiming there took the job off a
                                -- drone that was on its way to do it. TaskMan then reassigned it,
                                -- DroneMan sent Abort + a fresh order, and the drone started over.
                                -- D1's log shows "JOB Mine start" for task 80 three times in two
                                -- minutes, travelling from scratch each time. From outside that is
                                -- a drone twitching back and forth achieving nothing.
                                --
                                -- So a stuck drone must STAY stuck for a full reclaim window before
                                -- its work is taken. Genuinely wedged drones still lose the task;
                                -- drones having a bad second keep it.
                                -- IDLE COUNTS AS STALLED. A drone holding a task and reporting
                                -- "idle" is not working on it -- it has dropped the job and is
                                -- sitting still -- but idle was not in this list, and the else
                                -- branch below actively cleared the timer every pass. So the task
                                -- was held forever by a drone that would never finish it.
                                --
                                -- The log had been saying so for hours: 61 lines of
                                -- "reclaim? task N held by X: idle", every one of them a decision
                                -- to do nothing. Five scouts sat idle holding assignments while 58
                                -- tasks waited unassigned and ten drones had nothing to do.
                                --
                                -- It goes through the same sustained window as stuck rather than
                                -- freeing immediately, because a drone does report idle for a
                                -- moment between the legs of a job, and reclaiming on that made
                                -- drones start over from scratch repeatedly.
                                if d.status == "stuck" or d.status == "blocked"
                                        or d.status == "lost" or d.status == "idle" then
                                    v.stuckSince = v.stuckSince or os.epoch("utc")
                                    if (os.epoch("utc") - v.stuckSince) > RECLAIM_AFTER_MS then
                                        s_Free = true
                                    end
                                elseif d.offline then
                                    s_Free = true
                                else
                                    v.stuckSince = nil    -- moving again: forget it ever stalled
                                end
                            end
                        end
                        -- A drone nobody can even see is the strongest case of all: it is not
                        -- coming back to finish this, and holding the task for it helps no one.
                        if s_Saw == "not in fleet list" then s_Free = true end
                        local s_Idle = s_Free
                        if s_Idle then v.stuckSince = nil end
                        -- Log the DECISION, not just the action. A reclaim that silently declines
                        -- is indistinguishable from one that never ran, and the difference is where
                        -- the bug is.
                        Log(("reclaim? task %s held by %s: %s"):format(
                            tostring(v.id), tostring(v.assignedTo), s_Saw))
                        if s_Idle then
                            Log("reclaiming task " .. tostring(v.id) .. " from " .. tostring(v.assignedTo) .. " -- never started")
                            v.assigned, v.assignedTo, v.assignedAt = nil, nil, nil
                            PowNet.MarkDirty()
                        end
                    end
                end

                -- A task can WAIT FOR ANOTHER.
                --
                -- Some work is only possible once other work has happened, and the fleet had no way
                -- to say so. A scout cannot scan at y=35 because it carries a geo scanner instead
                -- of a pickaxe and cannot dig down to get there -- but it can walk down a shaft a
                -- miner has already sunk. Expressing "after the shaft exists" is what turns two
                -- drones that each cannot prospect into a pair that can.
                local s_Blocked = false
                if v.dependsOn ~= nil then
                    local dep = DATA["tasks"][v.dependsOn] or DATA["tasks"][tostring(v.dependsOn)]
                                or DATA["tasks"][tonumber(v.dependsOn)]
                    -- A dependency that no longer exists is treated as met rather than blocking
                    -- for ever: a task nobody can ever run is worse than one that runs early.
                    if dep ~= nil and (dep.progress or 0) < 100 then s_Blocked = true end
                end

                if v.enabled ~= false and not v.paused and v.assigned == nil
                   and not s_Blocked and (v.progress or 0) < 100 then
                    -- ONE ROLE, ONCE. Do not re-ask for a role that has already said "nobody free"
                    -- this pass.
                    --
                    -- This tried EVERY unassigned task on every tick, and picking a drone for a dig
                    -- or gather pings each candidate with a four-second timeout to prove it is
                    -- alive. With forty-six queued tasks that is minutes of pinging per pass, so the
                    -- tick never reached the end of the list and nothing was ever assigned -- while
                    -- three miners and a crafter sat idle in front of a full queue.
                    -- WHEN THE FLEET IS RUNNING OUT OF FUEL, ONLY FUEL WORK GETS PLACED.
                    --
                    -- HQ stops CREATING non-coal work when fuel is low, but the backlog it already
                    -- built is still handed out -- so the fleet went on being dispatched to
                    -- find-gold_ore and gather:copper_ore all the way down from 7,556 fuel to
                    -- 3,166, with 129 coal sitting in a chest it never went to. Not creating the
                    -- work is only half of it; the queue has to stop being worked too.
                    --
                    -- Rescues are exempt: relief is how a drone that has already run dry gets
                    -- moving again, and it is fuel work by definition.
                    local s_FuelOnly = fleetFuelLow()
                    local s_IsFuelWork = (v.work and v.work.rescue ~= nil)
                        or taskProducesFuel(v.name)
                    local s_Role = RoleForWork(v.work)
                    if s_FuelOnly and not s_IsFuelWork then
                        -- skip: the fleet cannot afford this right now
                    elseif not s_NoDrone[s_Role] then
                        local s_Ok, s_Why = OnStartTask(0, {data = {id = v.id}})
                        if s_Ok then
                            s_Started = s_Started + 1
                            -- That drone is now busy; give the next tick a chance rather than
                            -- burning this one discovering the same thing for every other task.
                            if s_Started >= START_PER_TICK then break end
                        else
                            -- ONE TASK FAILING IS NOT THE ROLE BEING BUSY.
                            --
                            -- This marked the whole ROLE unavailable on the first refusal, and
                            -- OnStartTask refuses for reasons that belong to the TASK as often as
                            -- to the fleet -- a build whose materials are not ready, a site that
                            -- cannot be reached. So one unplaceable task poisoned every other task
                            -- of its role for the entire pass, every pass.
                            --
                            -- build-claim-post-docks-01 is a miner task that cannot start until its
                            -- crafts finish. It sat at the front of the miner queue and blocked
                            -- ord-1:lumber -- also miner -- for ever. The fleet had an idle miner,
                            -- an idle crafter, wood twenty blocks away, and dispatched nothing at
                            -- all. placeRescues already learned this and tries the next one.
                            --
                            -- Bounded, because the original concern was real: choosing a drone is
                            -- not free, and retrying forty tasks per tick is how the tick stops
                            -- finishing. A few attempts per role finds a placeable task without
                            -- turning the pass into a scan.
                            -- SAY WHY NOTHING WAS PLACED.
                            --
                            -- This counted refusals and recorded not one of them, so "nine tasks
                            -- queued, four drones reporting idle, nothing dispatched" had no
                            -- explanation anywhere: not in TaskMan.log, not in fleet.tasks, not in
                            -- hive.plan. Diagnosing an idle fleet had to start by reading this
                            -- function's source and re-deriving what OnStartTask refuses on -- which
                            -- is the most expensive possible way to learn a one-line answer, and it
                            -- was paid repeatedly.
                            --
                            -- One line per role per pass: enough to name the blocker, not enough to
                            -- turn a busy fleet's log into a wall of refusals.
                            s_Fails[s_Role] = (s_Fails[s_Role] or 0) + 1
                            if s_Fails[s_Role] == 1 then
                                Log(("could not place %s (%s): %s"):format(
                                    tostring(v.name), tostring(s_Role),
                                    tostring(s_Why or "OnStartTask gave no reason")))
                            end
                            if s_Fails[s_Role] >= TRIES_PER_ROLE then s_NoDrone[s_Role] = true end
                        end
                    end
                end
            end
        end)
        -- Log, NOT print. print goes to the CC terminal, which cannot be read from outside the game
        -- -- so the one message explaining why nothing is being dispatched was written to a screen
        -- nobody can see. The whole placement pass runs inside that pcall, so if it throws, the
        -- fleet simply stops being given work and every external view shows the same thing: idle
        -- drones, a full queue, and no reason anywhere. Measured: nine tasks unassigned with a
        -- healthy fuelled crafter and miner reporting idle, and not one line in TaskMan.log about it.
        if not s_Ok then Log("Tick error: " .. tostring(s_Err)) end
    end
end

-- A drone telling us how its job ended.
--
-- Nothing reported completion before, so progress sat at 0 for ever. That was invisible while
-- assignments were permanent; the moment stalled assignments began to be reclaimed it became a
-- loop -- the crafter redid a finished chest order every ninety seconds, correctly reporting it
-- was short of the planks it had already turned into chests.
-- A FAILURE THAT SAYS NOTHING ABOUT THE TASK MUST NOT SPEND ONE OF ITS THREE ATTEMPTS.
--
-- "busy", "executing" and "refused" were already excluded, for exactly the right reason: the drone
-- declined to start, so nothing was learned about whether the work is possible. A SHORTAGE is the
-- same shape and was not excluded -- and it is the worse case, because it clears by itself.
--
-- Measured: fuel-D31 failed three times with "no fuel to deliver: storage had nothing burnable",
-- which was TRUE at the time -- storage held 0 coal, 0 charcoal and 0 logs. The task was then
-- marked finished for good. Twenty minutes later storage held 270 charcoal, D31 sat at zero fuel,
-- and all that remained in the queue was rescue-D31: a dig-out, role=miner, that neither miner
-- could take -- one being the casualty, the other busy. The settlement had the fuel, had a drone
-- that could carry it, and no path from one to the other, because a temporary shortage had been
-- written down as a permanent verdict.
--
-- Retrying forever is not the risk it looks like: stillTrapped already refuses to queue a fuel
-- rescue while storage has nothing burnable, so the shortage is gated upstream. This only stops a
-- shortage that has since ended from counting against the task.
local function saysNothingAboutTheTask(p_Reason)
    return (p_Reason:find("busy") or p_Reason:find("executing") or p_Reason:find("refused")
            or p_Reason:find("nothing burnable") or p_Reason:find("no fuel to deliver")) ~= nil
end

function OnTaskDone(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Task = DATA["tasks"][d.id] or DATA["tasks"][tostring(d.id)] or DATA["tasks"][tonumber(d.id or -1)]
    if s_Task == nil then return false, "No task " .. tostring(d.id) end

    if d.ok then
        -- VERIFY A SURVEY AGAINST THE MAP INSTEAD OF BELIEVING IT.
        --
        -- A scout reports success when it has walked its scan grid, which is a claim about the
        -- drone, not about the region. Tasks were reading 100% over ground that was still blank --
        -- "it says 100% but it didn't scan the entire area" is exactly right, and the queue had no
        -- way to know because nothing ever compared the two.
        --
        -- So ask MapServer what it now knows about the box that was ordered. A survey that left
        -- most of its region unknown is not finished, and going round again is far cheaper than a
        -- map with holes in it that nobody can see.
        local w = s_Task.work and s_Task.work.survey
        if w and w.min and w.max then
            -- THREE SECONDS, NOT FIFTEEN, and no retry.
            --
            -- Verifying a survey against the map is worth doing and not worth blocking the whole
            -- scheduler for. This ran with a fifteen-second budget on a single-threaded module that
            -- also answers GetTasks, GetDrones and every dispatch -- so while MapServer counted
            -- cells, TaskMan answered nothing, HQ's GetTasks timed out, and no work was assigned to
            -- anybody. Every completed survey bought another stall, and surveys complete constantly.
            --
            -- If the check does not come back promptly the task is simply accepted as done: an
            -- unverified survey is a small loss, a scheduler that stops scheduling is not.
            local s_Ok, s_Cov = pcall(function()
                return PowNet.sendAndWaitForResponse(
                    PowNet.Lookup("MapServer"),
                    PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "RegionKnown",
                                      {min = w.min, max = w.max}),
                    PowNet.SERVER_PROTOCOL, 3)
            end)
            local s_Pct = s_Ok and type(s_Cov) == "table" and tonumber(s_Cov.percent) or nil
            if s_Pct then
                s_Task.coverage = s_Pct
                s_Task.attempts = (s_Task.attempts or 0) + 1
                -- A geo scanner sees a sphere, so a swept region is never 100% cells-known --
                -- the corners between spheres stay dark. Sixty per cent means it genuinely
                -- covered the ground; single digits mean it scanned somewhere else entirely.
                if s_Pct < 60 and s_Task.attempts < 3 then
                    s_Task.assigned, s_Task.assignedTo, s_Task.assignedAt = nil, nil, nil
                    s_Task.failure = ("only %d%% of the region is known -- resurveying"):format(s_Pct)
                    PowNet.MarkDirty()
                    print(("task %s reported done at %d%% coverage -- requeued")
                        :format(tostring(d.id), s_Pct))
                    return true, {id = d.id, requeued = true, coverage = s_Pct}
                end
            end
        end
        s_Task.progress = 100
        s_Task.result   = d.result
        s_Task.failure  = nil
        -- THE TUNNEL IS NOT THE RESCUE. GETTING THE DRONE TO USE IT IS.
        --
        -- The miner has arrived, so there is now a walkable two-high tunnel from the surface to
        -- wherever the trapped drone is standing. But that drone is still sitting in "stuck" with a
        -- distress flag set, and a drone in distress is never picked for work -- so without this it
        -- would sit in a corridor it could now walk out of, indefinitely.
        --
        -- OnRescue is the existing self-rescue handler: it climbs, clears the distress and returns
        -- the drone to idle, which is exactly the right sequence now that there is somewhere to
        -- climb to.
        local s_R = s_Task.work and s_Task.work.rescue
        if s_R and s_R.id and s_R.fuel then
            -- A RELIEVED DRONE MUST EAT, NOT CLIMB.
            --
            -- The climb order below is right for a dig-out and wrong here: the casualty has coal
            -- lying in its own block and no fuel yet to move with, so every step fails -- and if
            -- any of them succeeded it would walk off the delivery. Its own fuel watchdog picks the
            -- coal up within twenty seconds and burns it, which is the whole point of dropping it
            -- there. Saying nothing is the correct instruction.
            Log(("fuel delivered to %s -- leaving it to refuel"):format(tostring(s_R.drone)))
        elseif s_R and s_R.id then
            Log(("rescue reached %s -- telling it to climb out"):format(tostring(s_R.drone)))
            pcall(function()
                PowNet.SendToDrone(s_R.id,
                    PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Rescue", {up = 8}))
            end)
        end
    else
        -- A FAILURE IS NOT A COMPLETION.
        --
        -- This set progress = 100 on failure, which made a refused job indistinguishable from a
        -- finished one: the queue showed "done, unassigned" and nothing ever went back for it. Nine
        -- survey tiles were issued over the base, four scouts took one each, and the other five
        -- were handed to drones that were already busy -- so five tiles were marked complete
        -- without a single drone ever visiting them. The map stayed blank over the base and the
        -- idle scouts had nothing to pick up, which is exactly what it looked like from outside:
        -- drones standing around while work "finished" itself.
        --
        -- The original instinct was right, though, and worth keeping: re-queuing a job that failed
        -- for a REAL reason just repeats it. So the two cases are separated.
        --
        -- A refusal ("busy", "already executing") says nothing about the task -- only about when we
        -- asked. That is a free retry. A real failure ("no path", "short of material") counts, and
        -- after a few of those the task is genuinely given up on, with the reason kept.
        local s_Reason = tostring(d.reason or "failed")

        -- ABANDONED IS NOT FAILED. IT IS FINISHED.
        --
        -- task.stop reports a failure, and a failure goes through the retry path below -- so an
        -- operator explicitly giving up on a task merely spent one of its three attempts and put it
        -- straight back in the queue. "stopped: true" and the task carries on being dispatched,
        -- three times over. Clearing a fourteen-task backlog that way is impossible, and a rescue
        -- for a drone that no longer exists came back every time it was cancelled.
        if d.abandon then
            s_Task.progress   = 100
            s_Task.finishedAt = os.epoch("utc")
            s_Task.failure    = s_Reason
            s_Task.assigned, s_Task.assignedTo, s_Task.assignedAt = nil, nil, nil
            Log(("task %s ABANDONED: %s"):format(tostring(d.id), s_Reason))
            PowNet.MarkDirty()
            return true, {id = d.id, abandoned = true}
        end

        s_Task.failure  = s_Reason
        s_Task.attempts = (s_Task.attempts or 0) + (saysNothingAboutTheTask(s_Reason) and 0 or 1)

        if s_Task.attempts >= 3 then
            -- Out of attempts: this one really is finished, unsuccessfully, and says why.
            s_Task.progress   = 100
            s_Task.finishedAt = os.epoch("utc")
            Log(("task %s GIVING UP after %d attempts: %s")
                :format(tostring(d.id), s_Task.attempts, s_Reason))
        else
            -- Back in the queue for someone else. Progress deliberately untouched.
            Log(("task %s failed (%s) -- requeued, attempt %d")
                :format(tostring(d.id), s_Reason, s_Task.attempts))
        end
        -- REMEMBER WHO COULD NOT DO IT.
        --
        -- pickDrone chooses the NEAREST idle drone, and the nearest idle drone to a task that just
        -- failed is invariably the one that just failed it -- sitting exactly where it gave up. So
        -- all three attempts were spent on the same drone failing the same way, the task was then
        -- dropped, the supply loop made another one for the same place, and it went to the same
        -- drone again. Scouts logged "Survey FAILED: could not reach" for hours while other scouts
        -- stood idle, and from outside the whole fleet just looked lazy.
        s_Task.lastFailedBy = s_Task.assignedTo
        s_Task.assigned, s_Task.assignedTo, s_Task.assignedAt = nil, nil, nil
        PowNet.MarkDirty()
        return true, {id = d.id, requeued = s_Task.progress ~= 100}
    end
    s_Task.finishedAt = os.epoch("utc")
    s_Task.assigned, s_Task.assignedTo, s_Task.assignedAt = nil, nil, nil
    PowNet.MarkDirty()
    print(("task %s %s"):format(tostring(d.id), d.ok and "done" or ("failed: " .. tostring(s_Task.failure))))
    return true, {id = d.id}
end

function OnListFleet(p_ID, p_Message)
    local s_Msg, s_N = "", 0
    for _, d in ipairs(fleet(true)) do
        s_N = s_N + 1
        s_Msg = s_Msg .. string.format("%s[%s/%s] ", tostring(d.name), tostring(d.role or "?"),
                                       tostring(d.status or "?"))
    end
    if s_N == 0 then s_Msg = "no drones registered" end
    return true, {message = s_Msg, count = s_N}
end





local m_DroneEvents = {
    Reboot = {
        func = OnReboot,
    },
    GoTo = {
        func = OnGoTo,
    }
}


local m_ServerEvents = { -- Runs on a different thread so that we can interrupt drones while they execute work on the Drone message thread.
    start = {
        func = OnStartTask,
        callable = true,
        params = { id = { optional = false } }
    },
    pause = {
        func = OnPauseTask,
        callable = true,
        params = { id = { optional = false } }
    },
    stop = {
        func = OnAbortTask,
        callable = true,
        params = { id = { optional = false } }
    },
    -- "who have I got, and what can each of them actually do" -- the question you ask before
    -- wondering why a task will not start.
    fleet = {
        func = OnListFleet,
        callable = true,
        params = {}
    },
    GetTasks = { func = OnGetTasks },
    Abandoned = { func = OnAbandoned, callable = true, params = {} },
    TaskDone = { func = OnTaskDone },
    TaskProgress = { func = OnTaskProgress },
    TaskRefused = { func = OnTaskRefused },
    StartTask = { func = OnStartTask },
    PauseTask = { func = OnPauseTask },
    AbortTask = { func = OnAbortTask },
    Abort = {
        callable = true,
        params = {
            name = {
            },
            id = {
            }
        },
        func = OnAbort,
    },
    Add = {
        callable = true,
        installer = true,
        params = {
            message = "Which task would you like to add?:",
            type = "list",
            name = {
                optional = false,
                description = true,
                type = "string"
            },
            priority = {
                optional = true,
                description = true,
                type = "int"
            },
            work = {
                optional = false,
                type = "option", -- single decision
                dig = {
                    type = "list",
                    min = {
                        type = "vec3",
                        optional = false
                    },
                    max = {
                        type = "vec3",
                        optional = false
                    }
                }
            },
        },
        func = OnAddTask
    },
    Start = {
        callable = true,
        params = {
            name = {
            },
            id = {
            }
        },
        func = OnStartTask
    },
    Pause = {
        callable = true,
        params = {
            name = {
            },
            id = {
            }
        },
        func = OnPauseTask
    },
    Abort = {
        callable = true,
        params = {
            name = {
            },
            id = {
            }
        },
        func = OnAbortTask
    },
}


function Render()
    local m_Monitor = monitor()
    if not m_Monitor then return end
    print("Render!")
    m_Monitor.clear()
    m_Monitor.setCursorPos(1,1)
    m_Monitor.setTextScale(0.5)
    -- Header
    m_Monitor.write("TaskMan!")
    local i = 1
    for k,v in pairs(DATA["tasks"]) do
        i = i + 1
        m_Monitor.setCursorPos(1,i)
        m_Monitor.write(v.id .. "| " .. v.name)
    end
end

PowNet.UpdateModule("ServerTasks/dig.lua", "ServerTasks/dig")
Init()
PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents, Render)
SetStatus("Connected!", colors.green)
Render()


parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, Tick)

print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
