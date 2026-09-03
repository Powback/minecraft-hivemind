--[[ Sync — pulls the Lua tree from HQ onto MainFrame's disk.

     The problem this solves: CC computers have no shell we can reach from
     outside and no shared filesystem. Without this, every Lua change is retyped
     by hand into an in-game terminal, which makes iteration so expensive that
     the code stops improving.

     The chain, and note that only the FIRST hop is new:

        repo lua/  ──http (this)──►  MainFrame disk  ──PowNet UPDATE──►  drones

     MainFrame already serves module source to drones on request; that mechanism
     works and stays. Sync only has to get files onto MainFrame's disk.

     Hash-diffed, so a sync with no changes costs one small HTTP request rather
     than re-downloading the tree. Run it on demand, or on a timer, or right
     after a deploy.

     Usage:  sync            pull changed files
             sync --force    pull everything
             sync --watch    poll every 30s
--]]

local HQ         = "http://hive.pow"
local TARGET     = "disk"          -- MainFrame serves modules from here
local STATE_FILE = ".sync-state"   -- path -> sha1 of what we last wrote
local POLL       = 30

local args = { ... }
local force = false
local watch = false
for _, a in ipairs(args) do
  if a == "--force" then force = true end
  if a == "--watch" then watch = true end
end

local function log(msg) print(("[sync] %s"):format(msg)) end

--- What we believe is already on disk. Kept separately from the files
--- themselves so a hand-edited file is detected as drift and replaced.
local function loadState()
  if not fs.exists(STATE_FILE) then return {} end
  local f = fs.open(STATE_FILE, "r")
  local data = textutils.unserialise(f.readAll() or "") or {}
  f.close()
  return data
end

local function saveState(state)
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialise(state))
  f.close()
end

local function fetch(url)
  local res, err = http.get(url)
  if not res then return nil, tostring(err) end
  local body = res.readAll()
  res.close()
  return body
end

-- Tell the modules something moved, and say whether they were actually told.
--
-- Its own function so `pull` does not carry the branch, and because the branch is the whole point:
-- the log line used to go out BEFORE the broadcast and regardless of it, so a failed notify read
-- exactly like a successful one -- files updated on MainFrame's disk, "notifying modules to
-- re-fetch" in the log, and every module still running the old code because nothing ever told them
-- to pull. That is how 17 of 20 computers ran stale code for hours while the deploy reported
-- success, and stale code is the hardest fault to diagnose: the source in front of you is not the
-- source that is running.
local function broadcastReinit()
  os.loadAPI("disk/PowNet")
  rednet.broadcast({ type = PowNet.MESSAGE_TYPE.INIT, ID = 0, dataKey = "MAINFRAME" },
                   PowNet.SERVER_PROTOCOL)
end

local function notifyModules()
  local s_Told, s_Err = pcall(broadcastReinit)
  if s_Told then
    log("notified modules to re-fetch")
  else
    log(("COULD NOT notify modules to re-fetch: %s -- they are still running the OLD code; "
         .. "reboot them or re-run the sync"):format(tostring(s_Err)))
  end
end

local function pull()
  local raw, err = fetch(HQ .. "/lua/manifest")
  if not raw then
    log("cannot reach HQ: " .. tostring(err))
    return false
  end

  local manifest = textutils.unserialiseJSON(raw)
  if not manifest or not manifest.files then
    log("bad manifest")
    return false
  end

  local state    = force and {} or loadState()
  local changed  = 0
  local failed   = 0

  for path, meta in pairs(manifest.files) do
    if state[path] ~= meta.sha1 then
      local body, ferr = fetch(HQ .. "/lua/file/" .. textutils.urlEncode(path))
      if not body then
        log(("FAIL %s (%s)"):format(path, tostring(ferr)))
        failed = failed + 1
      else
        local dest = fs.combine(TARGET, path)
        local dir = fs.getDir(dest)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

        -- Write to a temp file then move, so a connection dropped mid-download
        -- cannot leave a half-written module that MainFrame will happily serve
        -- to every drone in the fleet.
        local tmp = dest .. ".part"
        local f = fs.open(tmp, "w")
        f.write(body)
        f.close()
        if fs.exists(dest) then fs.delete(dest) end
        fs.move(tmp, dest)

        state[path] = meta.sha1
        changed = changed + 1
        log(("updated %s (%d bytes)"):format(path, meta.bytes))
      end
    end
  end

  saveState(state)

  if changed == 0 and failed == 0 then
    log("up to date")
  else
    log(("%d updated, %d failed"):format(changed, failed))
    if changed > 0 then
      -- Drones pull their own modules from MainFrame on next boot, so we only
      -- have to tell them something moved. MainFrame's INIT broadcast already
      -- means "re-initialise"; reuse it rather than inventing a second signal.
      -- It logs whether they were actually told -- see notifyModules.
      notifyModules()
    end
  end
  return true
end

if watch then
  log("watching " .. HQ .. " every " .. POLL .. "s")
  while true do
    pull()
    sleep(POLL)
  end
else
  pull()
end
