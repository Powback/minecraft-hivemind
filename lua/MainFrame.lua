--Mainframe
-- Goal: Handle communications and updates between servers
os.loadAPI("disk/PowNet")

local function trace(p_Step)
    local h = fs.open("/mf-boot.txt", "a")
    if h then h.write(tostring(p_Step) .. "\n") h.close() end
end
trace("loaded PowNet")

local m_LoadedCallable = {}

--===== LOAD VFS =====--
if not VFS then
    if not os.loadAPI("disk/VFS") then
        error("could not load API: VFS")
    end
end
VFS.Init("MainFrame")

Log("Loading...")

--===== HOST AS SERVER =====--
print("Starting MainFrame")
rednet.host(PowNet.SERVER_PROTOCOL, "MAINFRAME")
trace("hosted")

local m_Notified = false
--===== UTILS =====--

local receivedMessages = {}
local receivedMessageTimeouts = {}


local function newMessage(messageType, messageID, dataKey, data)
    return {
        type = messageType,
        ID = messageID,
        dataKey = dataKey,
        data = data,
    }
end

--===== REPEATED MESSAGE HANDLING =====--
local function clearOldMessages()
    while true do
        local event, timer = os.pullEvent("timer")
        local messageID = receivedMessageTimeouts[timer]
        if messageID then
            receivedMessageTimeouts[timer] = nil
            receivedMessages[messageID] = nil
        end
    end
end
local function Connect()
    -- Initialize our data for faster lookup
    local s_Message = newMessage(PowNet.MESSAGE_TYPE.INIT, 0,"MAINFRAME")
    rednet.broadcast(s_Message, PowNet.SERVER_PROTOCOL)
    trace("broadcast INIT id=0")
    print("Dispatched server boot")
    Log("Connected!", colors.green)
end



--===== MAIN =====--
local function main()
    while true do
        if(m_Notified == false) then
            Connect()
            m_Notified = true
        end
        local senderID, message = rednet.receive(PowNet.SERVER_PROTOCOL)
        if type(message) == "table" then
            if message.type == PowNet.MESSAGE_TYPE.GET then
                local data = VFS.getData(message.dataKey)
                local replyMessage = newMessage(PowNet.MESSAGE_TYPE.GET, message.ID, message.dataKey, data)
                rednet.send(senderID, replyMessage, PowNet.SERVER_PROTOCOL)


            elseif message.type == PowNet.MESSAGE_TYPE.SET then
                if not receivedMessages[message.ID] then
                    if(message.data ~= nil ) then
                        VFS.setData(message.dataKey, message.data)
                        VFS.saveData(message.dataKey)
                    else
                        print("NO DATA")
                    end
                    receivedMessages[message.ID] = true
                    receivedMessageTimeouts[os.startTimer(15)] = message.ID
                end
                local replyMessage = newMessage(PowNet.MESSAGE_TYPE.SET, message.ID, message.dataKey, true)
                rednet.send(senderID, replyMessage, PowNet.SERVER_PROTOCOL)
                print("saved: " .. tostring(message.dataKey))
            elseif message.type == PowNet.MESSAGE_TYPE.INIT then
                if(message.dataKey == nil) then
                    return
                end
                local s_EnvData = VFS.Init(message.dataKey)
                local replyMessage = newMessage(PowNet.MESSAGE_TYPE.INIT, message.ID, message.dataKey, s_EnvData)
                rednet.send(senderID, replyMessage, PowNet.SERVER_PROTOCOL)

            elseif message.type == PowNet.MESSAGE_TYPE.UPDATE then
                if (fs.exists("disk/" .. message.dataKey) == false) then
                    local replyMessage = newMessage(PowNet.MESSAGE_TYPE.UPDATE, message.ID, message.dataKey, "InvalidName")
                    rednet.send(senderID, replyMessage, PowNet.SERVER_PROTOCOL)
                else
                    local file = fs.open("disk/" .. message.dataKey,"r")
                    local data = file.readAll()
                    file.close()
                    local replyMessage = newMessage(PowNet.MESSAGE_TYPE.UPDATE, message.ID, message.dataKey, data)
                    rednet.send(senderID, replyMessage, PowNet.SERVER_PROTOCOL)

                end
            elseif message.type == PowNet.MESSAGE_TYPE.REGISTER then
                if(message.dataKey == "RegisterCallable") then
                    if(m_LoadedCallable[message.data.module] == nil) then
                        m_LoadedCallable[message.data.module] = {}
                    end
                    m_LoadedCallable[message.data.module][message.data.name] = message.data
                end
                if(message.dataKey == "GetCallable") then
                    for k,v in pairs(m_LoadedCallable) do
                        print(k)
                    end
                    local replyMessage = newMessage(PowNet.MESSAGE_TYPE.REGISTER, message.ID, message.dataKey, m_LoadedCallable)
                    rednet.send(senderID, replyMessage, PowNet.SERVER_PROTOCOL)
                end
            end
        end
    end
end



Connect()

-- ===== FLEET UPDATE ==================================================================
-- One command that takes the whole fleet to the current code, safely.
--
-- The broadcast already existed -- MainFrame sends INIT id=0 on boot and every module drops out
-- of main, writes its DATA back, reboots and pulls new source. But the only way to trigger it was
-- to reboot MainFrame itself, so in practice updates were pushed by rcon-rebooting each machine
-- by hand: racy, easy to miss one, and silent when it failed. A drone left on old code looks
-- perfectly healthy.
--
-- Now it is in-band. Modules get the chance to run their shutdown hook first, so a drone flushes
-- pending observations and writes down the job it was on before it goes.
local function broadcastUpdate()
    local s_Message = newMessage(PowNet.MESSAGE_TYPE.INIT, 0, "MAINFRAME")
    rednet.broadcast(s_Message, PowNet.SERVER_PROTOCOL)
    print("Update broadcast: fleet standing down to reload")
end

-- ===== HUB DASHBOARD =================================================================
-- What the system is doing, on one screen.
--
-- MainFrame is the wrong place to DRIVE work -- TaskMan owns the queue and now ticks it -- but
-- it is the right place to SHOW it: every module already talks to MainFrame for its VFS, so it
-- is the one node that legitimately knows everyone.
--
-- It polls rather than requiring modules to push. Liveness comes free from rednet.lookup (a
-- module that is hosting is up), and the two modules with interesting internal state answer for
-- themselves. That way DockingMan and MapServer needed no changes at all to appear here.
local MODULES = {"DroneMan", "DockingMan", "MapServer", "TaskMan", "StorageMan"}

local function ask(p_Module, p_Key)
    local s_Msg = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, p_Key, {})
    local s_Ok, s_Res = pcall(PowNet.sendAndWaitForResponse, p_Module, s_Msg, PowNet.SERVER_PROTOCOL)
    if s_Ok and type(s_Res) == "table" then return s_Res end
    return nil
end

local function dashboard()
    local mon = peripheral.find("monitor")
    if not mon then return end
    pcall(mon.setTextScale, 0.5)
    mon.setBackgroundColour(colors.black)
    mon.clear()
    local w, h = mon.getSize()
    local line = 1
    local function put(txt, col)
        if line > h then return end
        mon.setCursorPos(1, line)
        mon.setTextColour(col or colors.white)
        mon.write(string.sub(txt, 1, w))
        line = line + 1
    end

    put("POWNET  hub " .. os.getComputerID(), colors.cyan)
    line = line + 1

    -- Modules: hosting on the server protocol is the definition of up.
    put("MODULES", colors.lightBlue)
    for _, m in ipairs(MODULES) do
        local id = rednet.lookup(PowNet.SERVER_PROTOCOL, m)
        if id then put("  " .. m .. "  #" .. id, colors.lime)
        else       put("  " .. m .. "  --", colors.gray) end
    end
    line = line + 1

    -- Fleet: who exists, what they are, what they are doing.
    local s_Fleet = ask("DroneMan", "GetDrones")
    put("FLEET", colors.lightBlue)
    if s_Fleet and s_Fleet.drones then
        local s_Stuck = 0
        for _, d in ipairs(s_Fleet.drones) do
            local c = colors.white
            if d.stuck or d.status == "stuck" then c = colors.red s_Stuck = s_Stuck + 1
            elseif d.status ~= "idle" then c = colors.yellow end
            local p = d.pos or {}
            put(string.format("  %-4s %-6s %-9s f%-6s %s,%s,%s",
                tostring(d.name), tostring(d.role or "?"), tostring(d.status or "?"),
                tostring(d.fuel or "?"), tostring(p.x), tostring(p.y), tostring(p.z)), c)
            if d.stuck then put("       ! " .. tostring(d.stuck) .. " " .. tostring(d.detail or ""), colors.red) end
        end
        if #s_Fleet.drones == 0 then put("  (none registered)", colors.gray) end
        if s_Stuck > 0 then put("  " .. s_Stuck .. " STUCK -- p DroneMan rescue -id N", colors.red) end
    else
        put("  DroneMan not answering", colors.gray)
    end
    line = line + 1

    -- Queue: what is waiting, what is running, who has it.
    local s_Tasks = ask("TaskMan", "GetTasks")
    put("TASKS", colors.lightBlue)
    if s_Tasks and s_Tasks.tasks then
        if #s_Tasks.tasks == 0 then put("  (queue empty)", colors.gray) end
        for _, t in ipairs(s_Tasks.tasks) do
            local state = t.paused and "paused" or (t.assigned and ("-> " .. tostring(t.assigned)) or "queued")
            put(string.format("  #%-3s %-16s %-10s %s%%",
                tostring(t.id), tostring(t.name), state, tostring(t.progress or 0)),
                t.assigned and colors.yellow or colors.white)
        end
    else
        put("  TaskMan not answering", colors.gray)
    end
end

local function renderLoop()
    while true do
        pcall(dashboard)
        os.sleep(5)
    end
end

-- Any module can ask for a fleet reload by sending this; TaskMan or a remote can trigger it.
local function updateListener()
    while true do
        local id, msg = rednet.receive("PowNet:Update")
        if msg then
            print("Update requested by " .. tostring(id))
            broadcastUpdate()
        end
    end
end

trace("entering parallel")
parallel.waitForAny(main, clearOldMessages, PowNet.control, renderLoop, updateListener)

rednet.unhost(PowNet.SERVER_PROTOCOL)