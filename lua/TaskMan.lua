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
        priority = p_Message.data.priority or -1
    }

    local s_Work = p_Message.data.work or {}
    -- Only plan a dig for work that HAS a dig. This called PrepareTask unconditionally, so any
    -- non-mining task -- a survey, say -- handed nil to the dig planner and took the whole module
    -- down with "attempt to index local 'p_Params'". TaskMan assumed every task was a dig, which
    -- is exactly what a task manager must not assume.
    local s_Path = nil
    if s_Work["dig"] then
        local ok, res = pcall(dig.PrepareTask, s_Work["dig"])
        if ok then s_Path = res else print("dig planning failed: " .. tostring(res)) end
    end
    local s_Task = {
        name = s_Task.name,
        id = s_Task.id,
        work = s_Work,
        dependsOn = p_Message.data.dependsOn,
        progress = 0,
        enabled = true,
        paused = false
    }

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
        print("TaskMan cannot reach DroneMan -- no fleet to assign work to")
    end
    return m_Fleet or {}
end

-- What kind of drone does this work need? Digging needs a tool; surveying needs a scanner.
function RoleForWork(p_Work)
    if p_Work == nil then return "miner" end
    -- Digging someone out is miner work by definition: a scout carries a geo scanner where a
    -- pickaxe would go, so the drone that is trapped is precisely the one that cannot free itself.
    if p_Work["rescue"] then return "miner" end
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
local function pickDrone(p_Role, p_Pos, p_Avoid)
    local s_Busy, s_Best, s_BestD = nil, nil, nil
    local s_Fallback = nil
    for _, d in ipairs(fleet()) do
        if (d.role or "miner") == p_Role then
            if d.status == "idle" and not committed(d.id) then
                if p_Avoid ~= nil and d.id == p_Avoid then
                    s_Fallback = s_Fallback or d
                else
                    local s_D = distTo(d, p_Pos)
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
local function pickDrones(p_Role)
    local s_Free, s_Busy = {}, nil
    for _, d in ipairs(fleet()) do
        if (d.role or "miner") == p_Role then
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
            if d.status == "idle" and not d.offline then
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
    local s_Drone, s_Busy = pickDrone(s_Role, s_Where, s_Task.lastFailedBy)

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
    if s_Drone == nil and s_Task.work and s_Task.work.build then
        for _, alt in ipairs({"crafter", "loader", "scout"}) do
            s_Drone = pickDrone(alt, s_Where)
            if s_Drone ~= nil then
                print("build going to a " .. alt .. " -- no miner free")
                break
            end
        end
    end
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
        s_Verb, s_Payload = "GoTo", {pos = w.pos, taskId = s_Task.id}
    elseif s_Task.work.lumber then
        -- Wood gates chests, planks and sticks, and therefore every factory the fleet might
        -- build. Nothing else produces it.
        local w = s_Task.work.lumber
        s_Verb, s_Payload = "Lumber", {w = w.w, l = w.l, drop = w.drop, pos = w.start, taskId = s_Task.id}
    else
        local w = s_Task.work.dig or {}
        s_Verb, s_Payload = "Dig", {w = w.w, l = w.l, depth = w.depth, pos = w.start, taskId = s_Task.id}
    end
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
            -- Sent whole rather than summarised. The shapes differ per verb -- dig has
            -- start/stop, survey has min/max, gather has a target list, lumber has width and
            -- length -- and a summariser here would have to be updated every time a verb is
            -- added, silently omitting the new one until someone noticed.
            work = v.work,
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

local function rescueNeeded()
    -- One live rescue per drone. Without this the pass creates a fresh task every fifteen seconds
    -- for a drone that stays stuck -- which it will, right up until the miner arrives.
    local s_Pending = {}
    for _, v in pairs(DATA["tasks"] or {}) do
        local w = v.work and v.work.rescue
        if w and (v.progress or 0) < 100 and v.enabled ~= false then
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
        if w and (v.progress or 0) < 100 and v.enabled ~= false then
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

    local s_Made = 0
    for _, d in ipairs(s_Order) do
        local s_IsMiner = (d.role or "miner") == "miner"
        if s_IsMiner then
            if s_LiveMiner >= 2 then goto continue end
        else
            if s_LiveOther >= 3 then goto continue end
        end
        local s_Trapped = RESCUE_STATES[tostring(d.status)] or d.offline
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
        if s_Trapped and d.pos and d.pos.x and d.pos.y and d.pos.z
                and not s_Pending[tostring(d.id)] then
            local s_TaskID = DATA["lastTask"]
            DATA["lastTask"] = DATA["lastTask"] + 1
            DATA["tasks"][s_TaskID] = {
                id = s_TaskID,
                name = "rescue-" .. tostring(d.name),
                work = {rescue = {id = d.id, drone = d.name, role = (d.role or "miner"),
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
            if s_Tried >= 4 then return s_Placed end   -- no free miner; the rest wait a tick
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

function Tick()
    while true do
        os.sleep(TICK_SECONDS)
        pcall(pruneFinished)
        pcall(dedupeQueue)
        pcall(rescueNeeded)
        pcall(placeRescues)
        local s_Ok, s_Err = pcall(function()
            local s_NoDrone, s_Started = {}, 0
            for k,v in pairs(DATA["tasks"]) do
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
                                -- Idle means it took the order and finished or refused it. Safe.
                                if d.status == "idle" and not d.offline then s_Free = true end

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
                    local s_Role = RoleForWork(v.work)
                    if not s_NoDrone[s_Role] then
                        local s_Ok = OnStartTask(0, {data = {id = v.id}})
                        if s_Ok then
                            s_Started = s_Started + 1
                            -- That drone is now busy; give the next tick a chance rather than
                            -- burning this one discovering the same thing for every other task.
                            if s_Started >= START_PER_TICK then break end
                        else
                            s_NoDrone[s_Role] = true
                        end
                    end
                end
            end
        end)
        if not s_Ok then print("Tick error: " .. tostring(s_Err)) end
    end
end

-- A drone telling us how its job ended.
--
-- Nothing reported completion before, so progress sat at 0 for ever. That was invisible while
-- assignments were permanent; the moment stalled assignments began to be reclaimed it became a
-- loop -- the crafter redid a finished chest order every ninety seconds, correctly reporting it
-- was short of the planks it had already turned into chests.
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
        if s_R and s_R.id then
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
        local s_Busy   = s_Reason:find("busy") or s_Reason:find("executing") or s_Reason:find("refused")

        s_Task.failure  = s_Reason
        s_Task.attempts = (s_Task.attempts or 0) + (s_Busy and 0 or 1)

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
    TaskDone = { func = OnTaskDone },
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
