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
    return peripheral.find("monitor")
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
    local s_Res = PowNet.sendAndWaitForResponse("DroneMan", s_Msg, PowNet.SERVER_PROTOCOL)
    if type(s_Res) == "table" and s_Res.drones then
        m_Fleet, m_FleetAt = s_Res.drones, s_Now
    end
    return m_Fleet or {}
end

-- What kind of drone does this work need? Digging needs a tool; surveying needs a scanner.
function RoleForWork(p_Work)
    if p_Work == nil then return "miner" end
    if p_Work["survey"] or p_Work["scan"] then return "scout" end
    return "miner"
end

local function pickDrone(p_Role)
    local s_Busy = nil
    for _, d in ipairs(fleet()) do
        if (d.role or "miner") == p_Role then
            if d.status == "idle" then return d end
            s_Busy = s_Busy or d
        end
    end
    return nil, s_Busy
end

function OnStartTask(p_ID, p_Message)
    local s_Id = p_Message.data and p_Message.data.id
    if s_Id == nil then return false, "Missing id" end
    local s_Task = DATA["tasks"][s_Id] or DATA["tasks"][tostring(s_Id)] or DATA["tasks"][tonumber(s_Id)]
    if s_Task == nil then return false, "No task " .. tostring(s_Id) end

    local s_Role = RoleForWork(s_Task.work)
    local s_Drone, s_Busy = pickDrone(s_Role)
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
        s_Verb, s_Payload = "Survey", {w = w.w, h = w.h, radius = w.radius}
    else
        local w = s_Task.work.dig or {}
        s_Verb, s_Payload = "Dig", {w = w.w, l = w.l, depth = w.depth, pos = w.start}
    end
    PowNet.SendToDrone(s_Drone.id, PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, s_Verb, s_Payload))

    s_Task.assigned = s_Drone.name
    s_Task.assignedTo = s_Drone.id
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
function OnGetTasks(p_ID, p_Message)
    local s_List = {}
    for k,v in pairs(DATA["tasks"]) do
        s_List[#s_List + 1] = {
            id = v.id, name = v.name, progress = v.progress,
            enabled = v.enabled, paused = v.paused,
            assigned = v.assigned, role = RoleForWork(v.work),
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
function Tick()
    while true do
        os.sleep(TICK_SECONDS)
        local s_Ok, s_Err = pcall(function()
            for k,v in pairs(DATA["tasks"]) do
                -- Unassigned, enabled, not paused, not finished: try to place it. pickDrone
                -- returns nothing when every drone of that role is busy, so this quietly
                -- retries next tick rather than failing loudly every 15 seconds.
                if v.enabled ~= false and not v.paused and v.assigned == nil
                   and (v.progress or 0) < 100 then
                    OnStartTask(0, {data = {id = v.id}})
                end
            end
        end)
        if not s_Ok then print("Tick error: " .. tostring(s_Err)) end
    end
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
