--[[ Bridge — the in-world end of the link to HQ.

     Runs on ONE dedicated CC computer sitting next to MainFrame. It does two
     things and nothing else:

        rednet  <──>  Bridge  <──websocket──>  HQ (outside the game)

     Deliberately dumb. All judgement lives in HQ; this relays, correlates and
     survives. The less logic here, the less there is to redeploy into a running
     world when it changes.

     Things this handles that you do not want to think about again:
       * Reconnect with backoff. The websocket WILL drop — HQ restarts, the world
         reloads, the chunk unloads. It reconnects instead of dying silently.
       * Idempotency. A retried CALL must not apply twice. Seen keys are kept and
         replayed from cache, so "dig here" sent twice digs once.
       * Correlation. Replies carry the request id back; late replies are dropped
         rather than answering the wrong question.
       * Heartbeat. PING on an interval so a half-open socket is detected rather
         than quietly swallowing every order.

     Deploy through MainFrame's existing updater, same as any other module.
--]]

local HQ_URL          = "ws://hive.pow/bridge"   -- Traefik route on PowStation
local PROTOCOL        = 1
local PING_INTERVAL   = 20      -- seconds
local RECONNECT_MIN   = 2
local RECONNECT_MAX   = 60
local IDEM_KEEP       = 200     -- remembered idempotency keys

-- PowNet is ALREADY loaded by the module bootloader (`startup` does os.loadAPI("PowNet")
-- before running us), exactly as it is for DroneMan, TaskMan and the rest -- none of which
-- load it themselves.
--
-- This used to be os.loadAPI("disk/PowNet"), from when Bridge ran standalone on the computer
-- sitting next to the disk drive. As a module fetched from MainFrame there is no /disk mount,
-- so that call died with "Failed to load API PowNet due to File not found" -- while PowNet was
-- plainly present in the computer's own root.

local m_Socket
local m_Tasks    = {}           -- in-flight handleCall coroutines, resumed by pumpTasks
local m_Backoff  = RECONNECT_MIN
local m_Idem     = {}           -- idem key -> cached reply
local m_IdemAge  = {}           -- insertion order, for trimming

-- Also to a file. A CC terminal cannot be read from outside the game, so a Bridge that is
-- misbehaving is otherwise completely opaque -- which cost real time when DroneMan calls were
-- timing out and there was no way to see whether the call had even arrived.
local LOG_FILE = "bridge.log"
local function log(msg)
  print(("[bridge] %s"):format(msg))
  local ok, h = pcall(fs.open, LOG_FILE, "a")
  if ok and h then
    h.writeLine(("%s %s"):format(tostring(os.clock()), msg))
    h.close()
  end
end

--=====================================================================
-- Connection
--=====================================================================

-- Set while a dial is in flight. Without it socketLoop dials on EVERY event while disconnected --
-- and events arrive constantly from rednet and timers -- so dozens of websockets open at once and
-- CC:T eventually refuses with "Too many websockets already open", after which the Bridge can
-- never reconnect. That is what took the fleet off HQ.
local m_Dialing = false

local function closeSocket()
  if m_Socket then
    pcall(function() m_Socket.close() end)   -- dropping the reference does NOT free the socket
    m_Socket = nil
  end
end

local function connect()
  if m_Dialing then return true end          -- one dial at a time
  closeSocket()
  m_Dialing = true
  log("connecting to " .. HQ_URL)
  -- pcall, because this THROWS rather than returning on "Too many websockets already open".
  -- Unguarded it propagated out of socketLoop, ended parallel.waitForAny, and stopped the bridge
  -- dead -- turning a recoverable resource problem into the fleet losing HQ entirely.
  local s_Called, ok, err = pcall(http.websocketAsync, HQ_URL)
  if not s_Called then
    m_Dialing = false
    log("dial threw: " .. tostring(ok) .. " -- backing off")
    sleep(m_Backoff)
    m_Backoff = math.min(m_Backoff * 2, RECONNECT_MAX)
    return false
  end
  if not ok then
    m_Dialing = false
    log("dial failed: " .. tostring(err))
    return false
  end
  return true
end

local function send(tbl)
  if not m_Socket then return false end
  local ok, err = pcall(function() m_Socket.send(textutils.serialiseJSON(tbl)) end)
  if not ok then
    log("send failed: " .. tostring(err))
    closeSocket()           -- close it, do not merely forget it, or the handle leaks
    return false
  end
  return true
end

-- Events flow world -> HQ constantly (heartbeats, scans, progress). Fire and
-- forget: HQ tolerates gaps by ageing its own state, so a dropped heartbeat is
-- not worth blocking a drone over.
local function sendEvent(key, data)
  return send({ v = PROTOCOL, type = "EVENT", key = key, data = data })
end

--=====================================================================
-- Handling calls from HQ
--=====================================================================

local function rememberIdem(key, reply)
  if not key then return end
  m_Idem[key] = reply
  table.insert(m_IdemAge, key)
  while #m_IdemAge > IDEM_KEEP do
    local old = table.remove(m_IdemAge, 1)
    m_Idem[old] = nil
  end
end

--- Relay a CALL from HQ onto the rednet side and answer with the result.
local function handleCall(msg)
  -- Idempotency first: if we already did this exact work, replay the answer
  -- without doing it again. This is the whole reason retries are safe.
  if msg.idem and m_Idem[msg.idem] then
    log("idem hit " .. msg.idem .. " — replaying cached reply")
    local cached = m_Idem[msg.idem]
    send({ v = PROTOCOL, type = "REPLY", id = msg.id, ok = cached.ok, data = cached.data, error = cached.error })
    return
  end

  local reply
  if msg.module == "BRIDGE" then
    -- Introspection that must work even when the rest of the world does not.
    if msg.key == "ping" then
      reply = { ok = true, data = { up = os.clock(), id = os.getComputerID() } }
    else
      reply = { ok = false, error = "unknown bridge key: " .. tostring(msg.key) }
    end
  else
    -- Everything else is a PowNet call to a module (TaskMan, DroneMan, ...).
    local message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, msg.key, msg.data)
    local target = PowNet.Lookup(msg.module)
    log(("call %s.%s -> lookup=%s"):format(tostring(msg.module), tostring(msg.key), tostring(target)))
    local response = PowNet.sendAndWaitForResponse(msg.module, message, PowNet.SERVER_PROTOCOL)
    log(("call %s.%s -> response=%s"):format(tostring(msg.module), tostring(msg.key), tostring(response)))
    if response == false or response == nil then
      reply = { ok = false, error = ("no response from %s.%s"):format(msg.module, msg.key) }
    else
      reply = { ok = true, data = response }
    end
  end

  -- Cache SUCCESSES only. Caching a failure makes the failure permanent for that key: a retry
  -- replays the cached error instead of trying again, so a transient timeout becomes a wall.
  -- Idempotency exists to stop work happening twice, not to stop it happening at all.
  if reply.ok then rememberIdem(msg.idem, reply) end
  send({ v = PROTOCOL, type = "REPLY", id = msg.id, ok = reply.ok, data = reply.data, error = reply.error })
end

local function onFrame(raw)
  local msg = textutils.unserialiseJSON(raw)
  if type(msg) ~= "table" then
    log("unparseable frame")
    return
  end
  if msg.v ~= PROTOCOL then
    log(("protocol mismatch: HQ v%s, bridge v%d"):format(tostring(msg.v), PROTOCOL))
    return
  end

  if msg.type == "CALL" then
    -- Run in its own coroutine so a slow rednet round-trip cannot stall the socket loop;
    -- otherwise one unresponsive module deafens the whole bridge.
    --
    -- It must then be RESUMED on every subsequent event, which is the entire job of
    -- m_Tasks + pumpTasks below. Creating the coroutine and resuming it once -- which is
    -- what this did originally -- abandons it at its first yield. handleCall yields almost
    -- immediately (PowNet.Lookup -> rednet.lookup), so every single call was dropped before
    -- it reached even its first log line, and HQ saw nothing but timeouts.
    local co = coroutine.create(handleCall)
    m_Tasks[#m_Tasks + 1] = co
    coroutine.resume(co, msg)
  elseif msg.type == "PONG" then
    -- liveness confirmed; nothing to do
  else
    log("unhandled frame type: " .. tostring(msg.type))
  end
end

--=====================================================================
-- Loops
--=====================================================================

--- Owns the socket lifecycle: connect, pump frames, back off, retry forever.
local function socketLoop()
  while true do
    if not m_Socket then
      connect()
    end
    -- table.pack, NOT three named locals. Events carry different arities: a websocket event is
    -- (event, url, param) but a rednet_message is (event, senderId, message, protocol). Forwarding
    -- only the first three silently truncates every rednet event, so rednet.receive/lookup inside
    -- an in-flight call never matches and every module lookup returns nil.
    local s_Ev = table.pack(os.pullEvent())
    local event, url, param = s_Ev[1], s_Ev[2], s_Ev[3]

    -- Feed every event to in-flight calls before handling it ourselves. A coroutine blocked
    -- in rednet.receive is waiting for exactly these events; without this it waits forever.
    local s_Live = {}
    for _, co in ipairs(m_Tasks) do
      if coroutine.status(co) == "suspended" then
        local ok, err = coroutine.resume(co, table.unpack(s_Ev, 1, s_Ev.n))
        if not ok then log("call coroutine died: " .. tostring(err)) end
      end
      if coroutine.status(co) ~= "dead" then s_Live[#s_Live + 1] = co end
    end
    m_Tasks = s_Live

    if event == "websocket_success" and url == HQ_URL then
      -- Close whatever we were already holding BEFORE overwriting the reference.
      --
      -- This is the leak that kept killing the bridge with "Too many websockets already open".
      -- m_Dialing stops us starting two dials at once, but it cannot stop two dials COMPLETING:
      -- a websocket_closed for the old socket clears m_Dialing while a new dial is still in
      -- flight, both then succeed, and this line used to drop the first handle on the floor
      -- without closing it. CC:T counts handles, not variables. Every HQ restart leaked one, and
      -- HQ was restarting repeatedly while the map work was being rebuilt -- so the bridge died
      -- and took the fleet's whole view of itself with it.
      if m_Socket and m_Socket ~= param then
        pcall(function() m_Socket.close() end)
        log("closed a leaked socket on reconnect")
      end
      m_Socket = param
      m_Dialing = false
      m_Backoff = RECONNECT_MIN                 -- reset only on real success
      log("connected")
      send({ v = PROTOCOL, type = "HELLO", bridge = os.getComputerLabel() or "bridge",
             computerId = os.getComputerID() })

    elseif event == "websocket_failure" and url == HQ_URL then
      m_Dialing = false
      log(("connect failed (%s) — retrying in %ds"):format(tostring(param), m_Backoff))
      sleep(m_Backoff)
      -- Exponential backoff, capped. Hammering a downed HQ helps nobody and
      -- burns the game server's HTTP budget.
      m_Backoff = math.min(m_Backoff * 2, RECONNECT_MAX)

    elseif event == "websocket_message" and url == HQ_URL then
      onFrame(param)

    elseif event == "websocket_closed" and url == HQ_URL then
      log("closed — will reconnect")
      m_Dialing = false
      closeSocket()
      sleep(m_Backoff)
      m_Backoff = math.min(m_Backoff * 2, RECONNECT_MAX)
    end
  end
end

--- Detects half-open sockets, which otherwise look identical to a quiet world.
local function pingLoop()
  while true do
    sleep(PING_INTERVAL)
    if m_Socket then
      send({ v = PROTOCOL, type = "PING", t = os.epoch("utc") })
    end
  end
end

--- Forwards drone traffic from rednet up to HQ.
local function rednetLoop()
  while true do
    local id, message = rednet.receive(PowNet.DRONE_PROTOCOL)
    if type(message) == "table" and message.dataKey then
      sendEvent(message.dataKey, message.data)
    end
  end
end

--=====================================================================

log("starting; HQ = " .. HQ_URL)
if not PowNet.Connect() then
  log("WARNING: MainFrame not reachable — relaying HQ traffic only")
end

parallel.waitForAny(socketLoop, pingLoop, rednetLoop, PowNet.control)
log("stopped")
