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

os.loadAPI("disk/PowNet")

local m_Socket
local m_Backoff  = RECONNECT_MIN
local m_Idem     = {}           -- idem key -> cached reply
local m_IdemAge  = {}           -- insertion order, for trimming

local function log(msg)
  print(("[bridge] %s"):format(msg))
end

--=====================================================================
-- Connection
--=====================================================================

local function connect()
  log("connecting to " .. HQ_URL)
  local ok, err = http.websocketAsync(HQ_URL)
  if not ok then
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
    m_Socket = nil          -- force the reconnect path
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
    local response = PowNet.sendAndWaitForResponse(msg.module, message, PowNet.SERVER_PROTOCOL)
    if response == false or response == nil then
      reply = { ok = false, error = ("no response from %s.%s"):format(msg.module, msg.key) }
    else
      reply = { ok = true, data = response }
    end
  end

  rememberIdem(msg.idem, reply)
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
    -- Run in its own coroutine so a slow rednet round-trip cannot stall the
    -- socket loop; otherwise one unresponsive module deafens the whole bridge.
    local co = coroutine.create(handleCall)
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
    local event, url, param = os.pullEvent()

    if event == "websocket_success" and url == HQ_URL then
      m_Socket = param
      m_Backoff = RECONNECT_MIN                 -- reset only on real success
      log("connected")
      send({ v = PROTOCOL, type = "HELLO", bridge = os.getComputerLabel() or "bridge",
             computerId = os.getComputerID() })

    elseif event == "websocket_failure" and url == HQ_URL then
      log(("connect failed (%s) — retrying in %ds"):format(tostring(param), m_Backoff))
      sleep(m_Backoff)
      -- Exponential backoff, capped. Hammering a downed HQ helps nobody and
      -- burns the game server's HTTP budget.
      m_Backoff = math.min(m_Backoff * 2, RECONNECT_MAX)

    elseif event == "websocket_message" and url == HQ_URL then
      onFrame(param)

    elseif event == "websocket_closed" and url == HQ_URL then
      log("closed — will reconnect")
      m_Socket = nil
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
