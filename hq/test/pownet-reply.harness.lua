-- Loads the REAL lua/PowNet under stubs and exercises its reply decoding.
--
-- Not a reimplementation and not a grep: the file itself is loaded, so a future edit to
-- sendAndWaitForResponse is what this checks. Everything CC provides is stubbed just far enough
-- for the module to finish loading.

local POWNET = ...

local scripted   -- the reply rednet.receive will hand back, or nil for silence
local sent = {}

local env = setmetatable({}, {__index = _G})

env.redstone = { getSides = function() return {"top"} end }
env.peripheral = {
    getType = function() return "modem" end,
    find = function() return nil end,
}
env.rednet = {
    open = function() end,
    isOpen = function() return true end,
    host = function() end,
    lookup = function(_, name) return name == "DroneMan" and 11 or nil end,
    send = function(id, msg, proto) sent[#sent + 1] = {id = id, msg = msg, proto = proto} end,
    broadcast = function() end,
    receive = function()
        if scripted == nil then return nil end
        local r = scripted
        scripted = nil          -- one reply only; further waits time out
        return r.from, r.msg
    end,
}
env.os = setmetatable({
    getComputerLabel = function() return "TestHarness" end,
    getComputerID = function() return 99 end,
    clock = function() return 0 end,
    startTimer = function() return 1 end,
    pullEvent = function() return "timer" end,
    epoch = function() return 0 end,
    time = function() return 0 end,
    queueEvent = function() end,
    sleep = function() end,
}, {__index = os})
env.fs = { open = function() return nil end }
env.printError = function() end
env.print = function() end
env.textutils = { serialize = function(x) return tostring(x) end }
env.sleep = function() end
env.colors = setmetatable({}, {__index = function() return 1 end})
env._ENV = env

local chunk = assert(loadfile(POWNET, "t", env))
chunk()

-- The module addresses itself as `PowNet` in places; os.loadAPI provides that in world.
env.PowNet = env

local function call(reply)
    scripted = reply
    return env.sendAndWaitForResponse("DroneMan", {ID = "abc"}, "PowNet:Server", 0.01)
end

local results = {}

-- THE BUG. A handler that ends `return true` produces status=true with NO data. That must not be
-- reported as the same thing as nobody answering.
results.payloadless =
    call({from = 11, msg = {ID = "abc", status = true, data = nil, reply = true}})

-- Silence really is silence.
results.silence = call(nil)

-- A handler that returns real data still returns exactly that data, untouched.
local withData =
    call({from = 11, msg = {ID = "abc", status = true, data = {stock = 7}, reply = true}})
results.withData = type(withData) == "table" and withData.stock or withData

-- A refusal that carries a reason still surfaces the reason, not a bare false.
results.refusal =
    call({from = 11, msg = {ID = "abc", status = false, data = "unregistered", reply = true}})

-- A refusal with no reason must be false, not nil -- callers branch on `== false`.
results.bareRefusal =
    call({from = 11, msg = {ID = "abc", status = false, data = nil, reply = true}})

for k, v in pairs(results) do
    print(k .. "=" .. type(v) .. ":" .. tostring(v))
end
