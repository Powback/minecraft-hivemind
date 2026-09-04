-- A stub ComputerCraft world, good enough to LOAD the in-world modules and call their functions.
--
-- Nothing here moves a turtle or opens a modem. It models the little that the modules read at
-- load time and the little the tests need to control: a turtle inventory with fuel values, a
-- registry of fake peripherals with inventories, an in-memory filesystem, a PowNet whose replies
-- the test chooses, and a pgps that always knows where it is. Each module is loaded into its own
-- environment (see run.lua) so two modules defining the same global do not collide.
local M = {}

local FUEL_VALUE = {
    ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
    ["minecraft:oak_log"] = 15, ["minecraft:birch_log"] = 15, ["minecraft:oak_planks"] = 15,
    ["minecraft:oak_sapling"] = 5,
}

local function noop() end
local function yes() return true end
local function no() return false end

local function serialise(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        local key = type(k) == "string" and ("[" .. string.format("%q", k) .. "]") or ("[" .. tostring(k) .. "]")
        parts[#parts + 1] = indent .. "  " .. key .. " = " .. serialise(val, indent .. "  ")
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function toJSON(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if v == nil then return "null" end
    if #v > 0 then
        local out = {}
        for _, x in ipairs(v) do out[#out + 1] = toJSON(x) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local out = {}
    for k, x in pairs(v) do out[#out + 1] = string.format("%q", tostring(k)) .. ":" .. toJSON(x) end
    return "{" .. table.concat(out, ",") .. "}"
end
M.toJSON = toJSON

function M.makeEnv(p_Opts)
    p_Opts = p_Opts or {}
    local env = {}
    local world = {
        logs = {}, clock = 0, files = {}, peripherals = {}, replies = {},
        pos = p_Opts.pos or {x = 0, y = 64, z = 0}, gps = p_Opts.gps,
    }
    env.__world = world

    -- ---- turtle -------------------------------------------------------------------------------
    local turtle = { fuel = p_Opts.fuel or 1000, selected = 1, inv = {} }
    world.turtle = turtle
    function turtle.getFuelLevel() return turtle.fuel end
    function turtle.select(s) turtle.selected = s return true end
    function turtle.getSelectedSlot() return turtle.selected end
    function turtle.getItemCount(s) local it = turtle.inv[s or turtle.selected] return it and it.count or 0 end
    function turtle.getItemDetail(s)
        local it = turtle.inv[s or turtle.selected]
        if not it then return nil end
        return {name = it.name, count = it.count}
    end
    function turtle.getItemSpace(s) local it = turtle.inv[s or turtle.selected] return 64 - (it and it.count or 0) end
    function turtle.refuel(n)
        local it = turtle.inv[turtle.selected]
        if not it then return false end
        local v = FUEL_VALUE[it.name]
        if not v then return false end
        if n == 0 then return true end
        n = math.min(n or it.count, it.count)
        turtle.fuel = turtle.fuel + v * n
        it.count = it.count - n
        if it.count <= 0 then turtle.inv[turtle.selected] = nil end
        return true
    end
    local function move() turtle.fuel = turtle.fuel - 1 return true end
    turtle.forward, turtle.back, turtle.up, turtle.down = move, move, move, move
    turtle.turnLeft, turtle.turnRight = yes, yes
    turtle.detect, turtle.detectUp, turtle.detectDown = no, no, no
    turtle.inspect, turtle.inspectUp, turtle.inspectDown = no, no, no
    turtle.dig, turtle.digUp, turtle.digDown = yes, yes, yes
    turtle.place, turtle.placeUp, turtle.placeDown = yes, yes, yes
    turtle.drop, turtle.dropUp, turtle.dropDown = yes, yes, yes
    turtle.suck, turtle.suckUp, turtle.suckDown = no, no, no
    turtle.transferTo, turtle.craft, turtle.equipLeft, turtle.equipRight = yes, no, yes, yes
    turtle.compare, turtle.compareTo = no, no
    env.turtle = turtle

    -- ---- peripherals --------------------------------------------------------------------------
    local peripheral = {}
    function peripheral.getNames()
        local out = {}
        for name in pairs(world.peripherals) do out[#out + 1] = name end
        table.sort(out)
        return out
    end
    function peripheral.getType(name) local p = world.peripherals[name] return p and p.type or nil end
    function peripheral.isPresent(name) return world.peripherals[name] ~= nil end
    function peripheral.wrap(name)
        local p = world.peripherals[name]
        if not p then return nil end
        return p.api
    end
    function peripheral.find() return nil end
    function peripheral.call(name, method, ...)
        local p = world.peripherals[name]
        if not p or not p.api[method] then error("no such method " .. tostring(method)) end
        return p.api[method](...)
    end
    env.peripheral = peripheral
    -- A fake inventory peripheral: items is slot -> {name, count}.
    function world.addInventory(name, p_Type, items, size)
        local inv = { items = items or {}, size = size or 27 }
        local api = {}
        function api.list() local out = {} for s, it in pairs(inv.items) do out[s] = {name = it.name, count = it.count} end return out end
        function api.size() return inv.size end
        function api.getItemDetail(s) return inv.items[s] end
        function api.pullItems(from, fromSlot, limit, toSlot)
            local src = world.peripherals[from]
            if not src then return 0 end
            local it = src.api.__inv.items[fromSlot]
            if not it then return 0 end
            local n = math.min(limit or it.count, it.count)
            toSlot = toSlot or 1
            inv.items[toSlot] = {name = it.name, count = (inv.items[toSlot] and inv.items[toSlot].count or 0) + n}
            it.count = it.count - n
            if it.count <= 0 then src.api.__inv.items[fromSlot] = nil end
            return n
        end
        function api.pushItems(to, fromSlot, limit, toSlot)
            local dst = world.peripherals[to]
            if not dst then return 0 end
            return dst.api.pullItems(name, fromSlot, limit, toSlot)
        end
        api.__inv = inv
        world.peripherals[name] = { type = p_Type, api = api }
        return inv
    end

    -- ---- rednet / gps -------------------------------------------------------------------------
    env.rednet = {
        open = noop, close = noop, isOpen = yes, send = yes, broadcast = noop, receive = function() return nil end,
        host = noop, unhost = noop, lookup = function() return nil end,
        CHANNEL_BROADCAST = 65535, CHANNEL_REPEAT = 65533, MAX_ID_CHANNELS = 65500,
    }
    env.gps = {
        CHANNEL_GPS = 65534,
        locate = function() if world.gps then return world.gps.x, world.gps.y, world.gps.z end return nil end,
    }

    -- ---- fs (in memory) -----------------------------------------------------------------------
    local fs = {}
    function fs.exists(p) return world.files[p] ~= nil end
    function fs.isDir(p) return false end
    function fs.list() return {} end
    function fs.makeDir() end
    function fs.delete(p) world.files[p] = nil end
    function fs.getSize(p) return world.files[p] and #world.files[p] or 0 end
    function fs.combine(a, b) return a .. "/" .. b end
    function fs.getName(p) return p:match("([^/]+)$") or p end
    function fs.open(p, mode)
        if mode == "r" then
            local data = world.files[p]
            if data == nil then return nil end
            local pos = 1
            local h = {}
            function h.readAll() local s = data:sub(pos) pos = #data + 1 return s end
            function h.readLine()
                if pos > #data then return nil end
                local nl = data:find("\n", pos, true)
                local line = data:sub(pos, (nl or (#data + 1)) - 1)
                pos = (nl or #data) + 1
                return line
            end
            function h.close() end
            return h
        end
        local buf = (mode == "a" and world.files[p]) or ""
        local h = {}
        function h.write(s) buf = buf .. tostring(s) end
        function h.writeLine(s) buf = buf .. tostring(s) .. "\n" end
        function h.flush() world.files[p] = buf end
        function h.close() world.files[p] = buf end
        return h
    end
    env.fs = fs

    -- ---- os -----------------------------------------------------------------------------------
    env.os = {
        clock = function() return world.clock end,
        epoch = function() return math.floor(world.clock * 1000) end,
        time = function() return world.clock end,
        sleep = function(s) world.clock = world.clock + (s or 0) end,
        pullEvent = function() world.clock = world.clock + 0.05 return "timer", 1 end,
        pullEventRaw = function() world.clock = world.clock + 0.05 return "timer", 1 end,
        queueEvent = noop, startTimer = function() return 1 end, cancelTimer = noop,
        getComputerID = function() return p_Opts.id or 52 end,
        getComputerLabel = function() return p_Opts.label or "TEST" end,
        setComputerLabel = noop,
        loadAPI = function() return true end,
        reboot = function() error("reboot requested", 0) end,
        shutdown = function() error("shutdown requested", 0) end,
        version = function() return "CraftOS-stub" end,
        date = os.date, getenv = os.getenv,
    }
    env.sleep = env.os.sleep

    -- ---- misc CC globals ----------------------------------------------------------------------
    env.textutils = {
        serialise = serialise, serialize = serialise,
        unserialise = function(s) local f = load("return " .. s) return f and f() end,
        serialiseJSON = toJSON, serializeJSON = toJSON,
        unserialiseJSON = function() return nil end,
        formatTime = function() return "" end, tabulate = noop, pagedTabulate = noop, pagedPrint = noop,
    }
    env.textutils.unserialize = env.textutils.unserialise
    env.parallel = { waitForAny = noop, waitForAll = noop }
    env.term = setmetatable({}, { __index = function() return noop end })
    env.term.getSize = function() return 51, 19 end
    env.term.isColour = no
    env.term.isColor = no
    env.colors = setmetatable({}, { __index = function(_, k) return 1 end })
    env.colours = env.colors
    env.keys = setmetatable({}, { __index = function() return 0 end })
    env.shell = { run = yes, getRunningProgram = function() return "test" end }
    env.settings = { get = function() return nil end, set = noop }
    env.redstone = setmetatable({
        getSides = function() return { "left", "right", "top", "bottom", "front", "back" } end,
    }, { __index = function() return noop end })
    env.rs = env.redstone
    -- A wireless modem on the left, so startGPS finds one and gps.locate has something to speak through.
    world.peripherals["left"] = { type = "modem", api = { isWireless = yes, isOpen = yes, open = noop, close = noop } }
    env.http = { get = function() return nil end, post = function() return nil end }
    env.print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end world.logs[#world.logs + 1] = table.concat(t, "\t") end
    env.printError = env.print
    env.write = noop
    env.read = function() return "" end
    env.Log = function(msg) world.logs[#world.logs + 1] = tostring(msg) end
    env.SetStatus = noop
    env.DATA = {}

    -- ---- PowNet -------------------------------------------------------------------------------
    local PowNet = {
        SERVER_PROTOCOL = "PowNet",
        MESSAGE_TYPE = { CALL = "call", RESPONSE = "response", REGISTER = "register", INIT = "init", EVENT = "event" },
    }
    for _, n in ipairs({ "Lookup", "Forget", "Fault", "GetFaults", "ClearFaults", "Status", "RegisterEvents",
                         "UpdateModule", "MarkDirty", "Save", "Update", "SetShutdownHook", "RunShutdownHook",
                         "WaitForService", "AskInsisting", "main", "droneMain", "control", "Send", "SendToServer",
                         "SendToDrone", "SendToAllDrones", "dump", "InitServer" }) do
        PowNet[n] = noop
    end
    function PowNet.Monitor() return nil end
    function PowNet.Connect() return true, env.DATA end
    function PowNet.newMessage(messageType, dataKey, data) return { type = messageType, dataKey = dataKey, data = data } end
    function PowNet.Try(fn, ...) return pcall(fn, ...) end
    function PowNet.WatchPass(_, _, fn) local ok, err = pcall(fn) return ok, err end
    -- The test decides what every module answers: world.replies[recipient][dataKey] = table | function(data)
    function PowNet.sendAndWaitForResponse(recipient, message)
        local byKey = world.replies[recipient]
        local r = byKey and byKey[message.dataKey]
        if type(r) == "function" then return r(message.data) end
        return r
    end
    env.PowNet = PowNet

    -- ---- pgps (for DroneLogic) ----------------------------------------------------------------
    local pgps = {
        HEADINGS = { north = 0, west = 1, south = 2, east = 3 },
        getCachedPosition = function() return world.pos.x, world.pos.y, world.pos.z, 0 end,
        isWithinReach = yes, positionVerified = yes, verifyPosition = function() return true, 0 end,
        forward = yes, back = yes, up = yes, down = yes, turnLeft = noop, turnRight = noop, turnTo = noop,
        moveTo = yes, digTo = yes, flyTo = yes, mayStep = yes, boundsReason = function() return nil end,
        BreakExec = noop, StartExec = noop,
        motionWindow = function() return 0, 0, 0 end, motionReset = noop, motionCallers = function() return "" end, setRecovering = noop, startGPS = yes,
        noteObservation = noop, noteBlocked = noop, noteCleared = noop, noteExternalStep = noop,
        requeueObservations = noop, takeWorldDelta = function() return {}, {} end,
        cachedWorld = {}, cachedWorldDetail = {}, centre = function() return world.centre end,
        getBounds = function() return nil end, setBounds = noop, loadRegion = noop,
        setLocation = yes, setLocationFromGPS = yes, setHeading = yes, ensureHeading = yes,
        headingDelta = function() return 0 end, holdFixes = noop, releaseFixes = noop, isProtectedBlock = no, clearMoveError = noop,
        lastMoveError = function() return nil end, trailBack = function() return nil end, trailLength = function() return 0 end,
    }
    env.pgps = pgps

    env.HiveMindTest = {}
    setmetatable(env, { __index = _G })
    return env
end

return M
