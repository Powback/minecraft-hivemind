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
local LOG_FILE  = "bridge.log"
local LOG_LIMIT = 64 * 1024     -- bytes; diagnostics, not an audit trail

-- Truncate rather than grow.
--
-- Every relayed call was appended here and nothing ever removed a line. Over a few hours that
-- reached 8.1MB -- exactly computer_space_limit -- and the bridge then died on its own logging
-- with "Out of space", taking HQ's entire view of the fleet with it. A diagnostic that kills the
-- thing it is diagnosing is worse than no diagnostic; the last few hundred lines are what anyone
-- actually reads.
--
-- pcall around the size check as well as the write: once the disk is full, fs.open for append
-- throws, and an unguarded log call inside the reconnect path would make recovery impossible.
local function log(msg)
  print(("[bridge] %s"):format(msg))
  -- The note above is the reason this must not throw: an unguarded log call in the reconnect path
  -- makes recovery impossible once the disk is full.
  -- silent: allow (this IS the logger -- reporting its own failure through itself is circular, and the print above already delivered the message)
  pcall(function()
    if fs.exists(LOG_FILE) and fs.getSize(LOG_FILE) > LOG_LIMIT then fs.delete(LOG_FILE) end
    local h = fs.open(LOG_FILE, "a")
    if h then
      h.writeLine(("%s %s"):format(tostring(os.clock()), msg))
      h.close()
    end
  end)
end

--=====================================================================
-- Connection
--=====================================================================

-- Set while a dial is in flight. Without it socketLoop dials on EVERY event while disconnected --
-- and events arrive constantly from rednet and timers -- so dozens of websockets open at once and
-- CC:T eventually refuses with "Too many websockets already open", after which the Bridge can
-- never reconnect. That is what took the fleet off HQ.
local m_Dialing = false

-- CC:T COUNTS HANDLES, NOT VARIABLES -- so a close that did not happen is a leak, and a leak is
-- what took the fleet off HQ ("Too many websockets already open", after which it can never
-- reconnect). The pcall stays, because closing an already-dead socket throws and that case is
-- routine; discarding its result did not, because the one outcome worth knowing about is the
-- handle that is still open after this returns.
local function closeSocket()
  if m_Socket then
    local s_Ok, s_Err = pcall(function() m_Socket.close() end)   -- dropping the reference does NOT free the socket
    m_Socket = nil
    if not s_Ok then
      -- log(), not print(): print goes to the in-game terminal only, and a leaked handle is
      -- diagnosed from outside the game or not at all.
      log(("socket close FAILED: %s -- the handle may still be open"):format(tostring(s_Err)))
    end
    return s_Ok
  end
  return true
end

-- Close the handle we are about to drop, and say whether it actually closed.
--
-- Its own function so socketLoop does not carry the branch: CC:T counts handles, not variables, so
-- the reporting is not optional -- the old line announced "closed a leaked socket on reconnect"
-- unconditionally, which is the one sentence that would stop anyone looking for the leak that took
-- the fleet off HQ.
local function closeLeaked()
  if closeSocket() then
    log("closed a leaked socket on reconnect")
  else
    log("a leaked socket could NOT be closed on reconnect -- the handle count is still up")
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

-- CC:T refuses to send a websocket frame over its size limit, and an unguarded oversized reply
-- takes the whole link down: the send throws, the socket is closed, and every in-flight call is
-- lost along with it. One big answer -- a block index, a status with logs attached -- therefore
-- disconnected the fleet from HQ, repeatedly, and looked like a flaky bridge.
--
-- A reply that will not fit is a REPLY, not a disconnection. Say so and keep the socket.
local MAX_FRAME = 60 * 1024

local function send(tbl)
  if not m_Socket then return false end

  local okSer, payload = pcall(textutils.serialiseJSON, tbl)
  if not okSer then
    log("could not serialise a " .. tostring(tbl and tbl.type) .. " frame")
    return false
  end

  if #payload > MAX_FRAME then
    log(("reply too large (%d bytes) for %s"):format(#payload, tostring(tbl and tbl.id)))
    -- Answer the CALLER rather than dying. A tool that asked for too much can ask for less; a
    -- dropped socket gives it nothing to act on and costs everyone else their answers too.
    if tbl and tbl.type == "REPLY" and tbl.id then
      local s_Small = textutils.serialiseJSON({
        v = PROTOCOL, type = "REPLY", id = tbl.id, ok = false,
        error = ("reply too large (%d bytes, limit %d) -- ask for less"):format(#payload, MAX_FRAME),
      })
      local okSmall = pcall(function() m_Socket.send(s_Small) end)
      if okSmall then return false end
    end
    return false
  end

  local ok, err = pcall(function() m_Socket.send(payload) end)
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
    local response = PowNet.sendAndWaitForResponse(msg.module, message, PowNet.SERVER_PROTOCOL)
    if response == false or response == nil then
      log(("call %s.%s FAILED (lookup=%s)"):format(tostring(msg.module), tostring(msg.key), tostring(target)))
    end
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
      -- closeSocket(), not a fourth hand-rolled copy of it: it is the one place that knows a
      -- dropped reference does not free the handle, and it now reports a close that failed. The
      -- old line here logged "closed a leaked socket" unconditionally, so the exact failure this
      -- branch exists to prevent -- a handle left open on reconnect -- was announced as fixed.
      if m_Socket and m_Socket ~= param then closeLeaked() end
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

-- JOIN THE FLEET RELOAD.
--
-- Every other module runs PowNet.main, which handles MainFrame's INIT broadcast by standing down
-- so the bootloader can pull new code. The Bridge does not run main -- it has its own loops -- so
-- it never heard a single deploy and went on running whatever version it booted with, for hours.
-- Three separate fixes to this file appeared to do nothing, and it had to be restored by hand
-- twice, because the one component that carries every deploy could not receive one.
local function reloadLoop()
  while true do
    local id, msg = rednet.receive(PowNet.SERVER_PROTOCOL)
    if type(msg) == "table" and msg.type == PowNet.MESSAGE_TYPE.INIT then
      log("fleet reload from #" .. tostring(id) .. " -- rebooting to pull new code")
      closeSocket()          -- hand the socket back rather than leaking it across the reboot
      os.sleep(1)
      os.reboot()
    end
  end
end

log("starting; HQ = " .. HQ_URL)
if not PowNet.Connect() then
  log("WARNING: MainFrame not reachable — relaying HQ traffic only")
end

parallel.waitForAny(socketLoop, pingLoop, rednetLoop, reloadLoop, PowNet.control)
log("stopped")
