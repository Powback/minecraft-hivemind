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
print(os.loadAPI("ServerTasks/dig"))
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
    if not p_Force and m_Fleet and (s_Now - m_FleetAt) < 5 then return m_Fleet end
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

local function pickDrone(p_Role)
    local s_Busy = nil
    for _, d in ipairs(fleet()) do
        if (d.role or "miner") == p_Role then
            if d.status == "idle" and not committed(d.id) then return d end
            s_Busy = s_Busy or d
        end
    end
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
            -- offline is set by DroneMan when a drone misses three heartbeats; the ping is the
            -- belt to that braces, catching a drone that died since the last sweep.
            if d.status == "idle" and not d.offline then
                local s_Msg = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Ping", {})
                -- Same reasoning as fleet(): a drone mid-move can take more than a second to
                -- answer, and treating that as "dead" removes a healthy drone from the pool.
                local s_Ok, s_Res = pcall(PowNet.sendAndWaitForResponse, d.id, s_Msg,
                                          PowNet.DRONE_PROTOCOL, 4)
                if s_Ok and s_Res then
                    s_Free[#s_Free + 1] = d
                else
                    print("skipping " .. tostring(d.name) .. ": no answer")
                end
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

    local s_Drone, s_Busy = pickDrone(s_Role)

    -- PLACING A BLOCK NEEDS NO SPECIAL HARDWARE.
    --
    -- Digging needs a pickaxe and scanning needs a geo scanner, so those jobs genuinely belong to
    -- one role. Building needs neither -- every turtle can place -- and routing it to "miner" left
    -- a build queued indefinitely while a crafter and a loader sat idle on their docks. Prefer a
    -- miner, then take whoever is free.
    if s_Drone == nil and s_Task.work and s_Task.work.build then
        for _, alt in ipairs({"crafter", "loader", "scout"}) do
            s_Drone = pickDrone(alt)
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
        s_Verb, s_Payload = "Survey", {w = w.w, h = w.h, radius = w.radius, pos = w.pos, taskId = s_Task.id}
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
function OnGetTasks(p_ID, p_Message)
    local s_List = {}
    for k,v in pairs(DATA["tasks"]) do
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
    return true, {tasks = s_List, count = #s_List}
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

function Tick()
    while true do
        os.sleep(TICK_SECONDS)
        local s_Ok, s_Err = pcall(function()
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
                        local s_Idle, s_Saw = false, "not in fleet list"
                        for _, d in ipairs(fleet()) do
                            if d.id == v.assignedTo then
                                s_Saw = tostring(d.status) .. (d.offline and " offline" or "")
                                if d.status == "idle" and not d.offline then s_Idle = true end
                            end
                        end
                        -- Log the DECISION, not just the action. A reclaim that silently declines
                        -- is indistinguishable from one that never ran, and the difference is where
                        -- the bug is.
                        Log(("reclaim? task %s held by %s: %s"):format(
                            tostring(v.id), tostring(v.assignedTo), s_Saw))
                        if s_Idle then
                            print("reclaiming task " .. tostring(v.id) .. " -- never started")
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
                    OnStartTask(0, {data = {id = v.id}})
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
        s_Task.progress = 100
        s_Task.result   = d.result
        s_Task.failure  = nil
    else
        -- Record the reason and STOP. Re-queuing a job that failed for a real reason -- short of
        -- material, site unreachable -- just repeats it; the reason is what a human or the planner
        -- needs in order to do something different.
        s_Task.progress = 100
        s_Task.failure  = tostring(d.reason or "failed")
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
