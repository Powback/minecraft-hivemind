--DroneMan
--Goal: Handle drones and their status

local m_Monitor = peripheral.wrap("left")

Log("Starting...")
--===== LOAD VFS =====--
if not PowGPSServer then
    if not os.loadAPI("PowGPSServer") then
        return false, "could not load API: PowGPSServer"
    end
end
if not MapRender then
    if not os.loadAPI("MapRender") then
        return false, "could not load API: MapRender"
    end
end

-- Extra line under the map: who is flying, when there is anything to say.
m_Overlay = nil

function Init()
    -- Log each boot step. These go to MapServer.log, unlike print(), which goes to a terminal
    -- nobody is looking at -- and MapServer spent several boots hung with no way to tell WHICH
    -- step it was hung in. A boot that can be observed is a boot that can be fixed.
    Log("boot: loading map")
    PowGPSServer.loadAll()
    Log("boot: map loaded")
    if DATA["bounds"] == nil then
        -- THE THIRD PLACE THE OLD WORLD WAS HARDCODED.
        --
        -- This defaulted to the previous settlement's force-loaded region, so a fresh world came up
        -- with every drone hundreds of blocks OUTSIDE the bounds it had never been told about.
        -- pgps.mayStep refuses to leave coverage -- correctly, because stepping into an unloaded
        -- chunk is how a drone stops ticking and is lost -- so all three reported "outside coverage:
        -- unloaded chunk" and would not move. Nothing had failed. The map simply described somewhere
        -- else, and every component downstream believed it.
        --
        -- Derived from the settlement now, and settable through the bounds endpoint. BASE is the one
        -- fact that changes when a world is re-founded, and it should appear once.
        local s_Bx, s_By, s_Bz = -480, 63, 64
        local s_Reach = 96
        DATA["bounds"] = {minx = s_Bx - s_Reach, maxx = s_Bx + s_Reach,
                          miny = -64,            maxy = 200,
                          minz = s_Bz - s_Reach, maxz = s_Bz + s_Reach}
        Log(("boot: no bounds stored -- defaulting to %d..%d x %d..%d around the settlement")
            :format(DATA["bounds"].minx, DATA["bounds"].maxx,
                    DATA["bounds"].minz, DATA["bounds"].maxz))
    end
    -- TWO CONSTELLATIONS, AND THIS MERGES RATHER THAN ONLY INITIALISING.
    --
    -- #100-103 sit at y=95-99, which is right for surface work and useless underground: a fix needs
    -- FOUR hosts in range, and a miner at y=44 could hear only three of them. The drones reported
    -- it precisely -- "outside coverage: no gps coverage" -- while standing in a shaft they had dug
    -- themselves. So #220-223 were added lower down, positioned to cover the mining depths.
    --
    -- Merged, not assigned, because `if DATA["gpsHosts"] == nil` only ever runs on a world with no
    -- saved state. Every existing deployment would have kept the old four-host list for ever and
    -- the new satellites would have been invisible to the coverage check -- physically present,
    -- answering pings, and still refused as "no coverage".
    -- THE CONSTELLATION IS NOT A CONSTANT. IT WAS TWENTY-TWO OF THEM.
    --
    -- This held the previous settlement's 22 hosts and MERGED them in on every boot, so a brand-new
    -- world inherited a phantom constellation hundreds of blocks away. Coverage is computed from
    -- these, so every drone in the real world sat outside GPS coverage and refused to move, while
    -- MapServer reported a healthy 22-host network that did not exist.
    --
    -- The bootstrap default is the constellation bootstrap/gps.sh actually places. Anything else
    -- arrives through the gpshost endpoint, which is how a host built by the fleet registers itself.
    local s_Known = {
        {x = -478, y = 78,  z = 90},
        {x = -464, y = 93,  z = 83},
        {x = -504, y = 82,  z = 58},
        {x = -465, y = 82,  z = 40},
    }
    DATA["gpsHosts"] = DATA["gpsHosts"] or {}

    -- A HOST OUTSIDE THE OPERATING REGION BELONGS TO A DIFFERENT SETTLEMENT.
    --
    -- It cannot serve this one -- it is far past modem range by definition -- so keeping it does
    -- nothing but inflate the host count and make coverage look better than it is. Dropping them
    -- means a re-founded settlement heals itself on the next boot instead of inheriting ghosts.
    local s_B = DATA["bounds"]
    if s_B then
        local s_Keep, s_Dropped = {}, 0
        for _, e in ipairs(DATA["gpsHosts"]) do
            if e.x >= s_B.minx and e.x <= s_B.maxx and e.z >= s_B.minz and e.z <= s_B.maxz then
                s_Keep[#s_Keep + 1] = e
            else
                s_Dropped = s_Dropped + 1
            end
        end
        if s_Dropped > 0 then
            Log(("boot: dropped %d gps host(s) outside the operating region"):format(s_Dropped))
        end
        DATA["gpsHosts"] = s_Keep
    end

    for _, h in ipairs(s_Known) do
        local s_Have = false
        for _, e in ipairs(DATA["gpsHosts"]) do
            if e.x == h.x and e.y == h.y and e.z == h.z then s_Have = true break end
        end
        if not s_Have then DATA["gpsHosts"][#DATA["gpsHosts"] + 1] = h end
    end
    -- Called by global name on purpose: it is defined further down, after locals this function
    -- cannot see. Globals resolve at call time, so this works and a direct reference would not.
    Log("boot: backfilling blockAt")
    BackfillBlockAt()
    Log("boot: indexing names")

    -- REBUILD THE ORE INDEX FROM THE MAP ON DISK.
    --
    -- IndexNames was only ever fed by INCOMING uploads, so the index of what-is-where lived purely
    -- in memory and every MapServer restart silently forgot every ore the fleet had ever found. The
    -- detail map on disk still held it -- coal, iron, copper, zinc, all correctly recorded -- and
    -- world.find answered "nothing surveyed matches" for all of them.
    --
    -- The consequence was not cosmetic. The supply loop dispatches `gather` only for materials the
    -- map can locate, so with an empty index it fell through to "none known -> survey dispatched"
    -- every single cycle: scouts were sent out to find ore that had already been found, again and
    -- again, while miners tunnelled past it. Rebuilding here is what makes a survey worth anything
    -- once the module has been restarted.
    local s_N = IndexNames(PowGPSServer.getCachedWorldDetail())
    Log("boot: ready, indexed " .. tostring(s_N) .. " named blocks")
end

-- THE BLOCK INDEX IS DERIVED AND MUST NOT LIVE IN DATA.
--
-- It used to be m_BlockAt and m_BlockIndex, and DATA is what gets shipped to MainFrame
-- -- both periodically via MarkDirty/Save and on shutdown. The index for this map is 162,149 named
-- blocks and serialises to about 7 MB, so MapServer spent its life trying to push seven megabytes
-- through a rednet message. It answered nothing while doing so, and the write eventually failed and
-- left a ZERO BYTE DATA file behind, after which it could never boot again.
--
-- Nothing about it needs persisting: Init() rebuilds it from the chunk files on disk, which carry
-- block names through the interned dictionary. That rebuild takes four seconds. Keeping it in
-- module-local tables costs one boot-time rebuild and removes the whole failure mode.
local m_BlockAt, m_BlockIndex = {}, {}
-- Pinned key ordering for BlockAt's paginator; rebuilt whenever a walk starts at offset 0.
local m_BlockKeys = nil

function OnSaveWorld(p_ID, p_Message)
    -- Was `mergeData(p_Message.data)`, and mergeData is defined nowhere in this codebase -- so
    -- the one endpoint named after saving the world crashed on "attempt to call a nil value" the
    -- first time anything used it. Nothing ever did: no drone sent SaveWorld either, so the whole
    -- survey pipeline was two disconnected halves that had never been run end to end.
    --
    -- OnUpdatePath below already did the real work, so this now does the same thing.
    if(p_Message.data == nil) then
        return false, "no data"
    end
    if(p_Message.data.cachedWorld) then
        PowGPSServer.UpdateCachedWorld(p_Message.data.cachedWorld, p_ID)
    end
    if(p_Message.data.cachedWorldDetail) then
        PowGPSServer.UpdateCachedWorldDetail(p_Message.data.cachedWorldDetail, p_ID)
    end
    -- Index the names as they ARRIVE, rather than scanning the detail map on demand.
    --
    -- That map is now 1.2MB and 1000+ entries. blockData (96KB) still loads, which is why
    -- world.caves works and world.find returned zero for everything -- the detail table was never
    -- in memory to search. Indexing incrementally keeps the answer small and costs nothing at
    -- query time; it also survives the detail map growing without bound.
    IndexNames(p_Message.data.cachedWorldDetail)
    -- ...and index the OCCUPANCY too. A mined block reports itself only here, as a 0; it never
    -- appears in the detail map again. Reading names alone is what made the index append-only.
    IndexOccupancy(p_Message.data.cachedWorld)
    -- THROTTLED. Persisting the whole map on every upload is what made MapServer stop answering.
    --
    -- Six drones uploading scans every few seconds each triggered a full rewrite of every cell the
    -- fleet has ever seen. At twenty thousand cells that is a long, blocking write, and MapServer
    -- spent more time saving the map than serving it -- Status timed out, `hive.nodes` reported the
    -- module unreachable, and drones queued up behind a module that was not stuck at all, just busy
    -- writing the same file over and over.
    --
    -- Every thirty seconds is enough. The cost of a crash between saves is at most half a minute of
    -- observations, which the next scan re-derives; the cost of saving continuously is a map server
    -- that nobody can talk to.
    -- FIVE MINUTES, not thirty seconds -- the map got twenty times bigger.
    --
    -- Thirty seconds was right for a 20,000-cell map. At 153,000 cells the save is 3.4MB written
    -- through a Lua loop, and MapServer answers nothing at all while it runs: `hive.nodes` reported
    -- it unreachable, path requests timed out, and drones sat in moveTo with executing=true and no
    -- movement for minutes at a time. The fleet was not stuck, it was queued behind a file write.
    --
    -- Losing five minutes of observations to a crash costs nothing -- the next scan re-derives them.
    -- A map server nobody can reach costs the whole fleet.
    -- SIXTY SECONDS. The five-minute throttle was set when a save meant rewriting the entire map
    -- and blocking the module for the duration. Chunked dirty saves cost a few kilobytes, so the
    -- reason for the long interval is gone -- and the cost of it is not: `computercraft shutdown`
    -- powers the computer off without running the module's exit save, so every restart threw away
    -- up to five minutes of observations. The map went 294,713 -> 227,461 cells across one deploy
    -- for exactly that reason.
    m_LastSave = m_LastSave or 0
    if os.clock() - m_LastSave > 60 then
        m_LastSave = os.clock()
        PowGPSServer.saveAll()
    end
    MapRender.invalidate()
    return true, true
end

-- PAGED. The survey is ~490KB of JSON and a websocket frame caps far below that, so returning it
-- whole meant the map could render NOTHING -- the reply was refused entirely rather than trimmed.
-- Paging is the difference between a size limit costing latency and costing the whole feature.
local WORLD_PAGE = 2000
m_PageKeys = nil   -- key list for a paged walk; rebuilt when a walk starts

function OnLoadWorld(p_ID, p_Message)
    -- Registered in m_ServerEvents but never written, so the entry pointed at nil. PowNet prints
    -- "Event registered, but pointing to nothing" and carries on, which is why it went unnoticed.
    local d = p_Message and p_Message.data or {}
    local s_Offset = tonumber(d.offset) or 0
    local s_Limit  = math.min(tonumber(d.limit) or WORLD_PAGE, WORLD_PAGE)
    local s_World  = PowGPSServer.getCachedWorld() or {}

    -- NO WHOLE-MAP REPLY. There is no caller that wants one and no transport that can carry it.
    --
    -- This existed so that "anything in-world that already depends on this keeps working" -- but
    -- nothing does: the only caller is HQ, and it has always paged. What it actually was is a
    -- landmine. At 227,000 cells the reply is megabytes, which exceeds the websocket frame limit
    -- outright and would flood rednet for every other module sharing the channel. The fleet has
    -- already been taken down once by a drone putting its whole map on the wire (SavePath); leaving
    -- a second way to do it, triggered by simply omitting an argument, is asking for the same
    -- outage from a different direction.
    --
    -- An unpaged request now means "start at the beginning", which is what a caller that forgets
    -- to page almost certainly wanted anyway.
    local s_Unpaged = (d.offset == nil and d.limit == nil)

    -- BUILD THE KEY LIST ONCE, then serve slices of it.
    --
    -- This walked the ENTIRE world on every page request to find its slice: 111,000 iterations per
    -- call, fifty-six calls, six million iterations to read the map once. The later pages ran long
    -- enough for CC to kill them, the caller read a failed page as the end of the map, and the
    -- whole thing silently returned 16,476 cells of 111,684 -- as a success.
    --
    -- The cache is rebuilt whenever a walk starts from offset 0, so a paged read is consistent and
    -- fresh observations are picked up on the next full pass.
    --
    -- IT YIELDS. Building the list is one pass over every cell in the world, and at 269,650 cells
    -- that pass runs past CC's ten-second limit -- at which point the coroutine is killed, and that
    -- kill is not catchable. This is exactly what was wrong: MapServer logged
    -- "LoadWorld: live=269650 keys=269650" ONCE and never logged again, because building the list
    -- was the last thing it ever did. Every call after that -- Status, BlockAt, FindBlocks,
    -- FindCaves -- failed against a module that was still resident, still had a modem, and still
    -- resolved through rednet.lookup. A module found and then silent.
    if s_Offset == 0 or m_PageKeys == nil then
        m_PageKeys = {}
        local s_Since = 0
        for key in pairs(s_World) do
            m_PageKeys[#m_PageKeys + 1] = key
            s_Since = s_Since + 1
            if s_Since >= 2000 then s_Since = 0 ; os.queueEvent("mapPage") ; os.pullEvent("mapPage") end
        end
    end

    -- One number, taken from the list just built. The count used to be its own second walk of all
    -- 269,650 cells, doubling the cost of the very handler that was being killed for taking too
    -- long -- and it existed to answer a question ("does the serving path see the same world the
    -- loader logged?") that it already answered: it does, live and keys were equal.
    if s_Offset == 0 and _G.Log then
        _G.Log(("LoadWorld: %d cells"):format(#m_PageKeys))
    end

    local s_N = #m_PageKeys
    local s_Page, s_Sent = {}, 0
    for i = s_Offset + 1, math.min(s_Offset + s_Limit, s_N) do
        local key = m_PageKeys[i]
        local v = s_World[key]
        if v ~= nil then
            s_Page[key] = v
            s_Sent = s_Sent + 1
        end
    end

    local s_Next = s_Offset + math.min(s_Limit, math.max(0, s_N - s_Offset))
    return true, {cachedWorld = s_Page, count = s_N, offset = s_Offset, sent = s_Sent,
                  next = (s_Next < s_N) and s_Next or nil}
end

function OnGetPath(p_ID, p_Message)
    print(p_ID)
    print("Get Path")
    local x1 = p_Message.data[1]
    local y1 = p_Message.data[2]
    local z1 = p_Message.data[3]
    local x2 = p_Message.data[4]
    local y2 = p_Message.data[5]
    local z2 = p_Message.data[6]
    local discover = p_Message.data[7]
    local priority =p_Message.data[8]
    local s_Path, s_Why = PowGPSServer.a_star(x1, y1, z1, x2, y2, z2, discover, priority)
    if(s_Path == false) then
        -- Pass the SEARCH's reason through. "failed to find path" is the same string whether the
        -- goal was solid, the budget ran out, or there is genuinely no route -- three problems
        -- with three different fixes, reported identically.
        return false, {message = tostring(s_Why or "failed to find path")}
    end
    print(#s_Path)
    return true, {path = s_Path}
end

function OnUpdatePath(p_ID, p_Message)
    PowGPSServer.UpdateCachedWorld(p_Message.data.cachedWorld, p_ID)
    PowGPSServer.UpdateCachedWorldDetail(p_Message.data.cachedWorldDetail, p_ID)
    -- This -- not OnSaveWorld -- is the endpoint drones actually use, so it is the one that has to
    -- keep the index honest. Indexing only in OnSaveWorld would have looked correct in the source
    -- and done nothing whatsoever in the world.
    IndexNames(p_Message.data.cachedWorldDetail)
    IndexOccupancy(p_Message.data.cachedWorld)
    MapRender.invalidate()
    return true, true
end

function OnSetDronePos(p_ID, p_Message)
    print(p_Message.data)
    for k,v in pairs(p_Message.data.pos) do
        print(k)
        print(p_Message.data.pos[k])
    end
    local x,y,z = p_Message.data.pos.x,p_Message.data.pos.y,p_Message.data.pos.z
    PowGPSServer.SetDronePos(x,y,z)
    return true, true
end

function OnMapMode(p_ID, p_Message)
    local s_Name = p_Message.data and p_Message.data.mode
    local s_Ok, s_Res
    if s_Name then
        s_Ok, s_Res = MapRender.setMode(s_Name)
        if not s_Ok then return false, s_Res end
    else
        s_Res = MapRender.nextMode()
    end
    Render()
    return true, {message = "map mode: " .. s_Res, mode = s_Res}
end

-- The region drones are allowed to operate in.
--
-- Held here rather than on each drone because it is a property of the world (which chunks are
-- kept loaded), not of any turtle, and it changes when the base grows. Serving it means a drone
-- picks up a new boundary on its next boot instead of needing to be reconfigured.
-- Coverage = the static force-loaded region, plus a box around each parked chunk-loader.
--
-- A chunky turtle keeps its own chunk ticking, so a loader is a mobile piece of safe ground.
-- Composing them here means "send a loader out there" is all it takes to open new territory --
-- the workers pick the wider coverage up on their next boot and simply stop refusing to go.
local LOADER_REACH = 16     -- chunkyTurtleRadius is 0, i.e. its own chunk; 16 blocks is honest

-- Modem range rises with altitude: modem_range 64 at the bottom, modem_high_altitude_range 384
-- at build height, interpolated. Hosts sitting at y=95 therefore reach roughly 196 blocks, which
-- is why the constellation was put up there rather than at ground level.
-- CC:T does NOT interpolate. modem_high_altitude_range applies above world height / 2 -- about
-- y=192 in the overworld -- and below that the range is a flat modem_range, 64 blocks.
--
-- The old formula interpolated and reported ~191 blocks of reach for hosts at y=95, so Coverage()
-- claimed GPS across the whole operating region and inBounds cheerfully let drones fly out of it.
-- Two of them stranded that way at z=12, roughly 60 blocks from the constellation: unable to fix,
-- therefore unable to navigate, therefore unable to move back into coverage.
--
-- Raising the constellation would not help either, because GPS is a round trip -- the DRONE's own
-- transmitter has the same 64-block range, so it must be near the hosts regardless of how high they
-- are. Coverage is a 64-block bubble and the honest thing is to say so.
local GPS_HIGH_ALTITUDE_Y = 192

local function gpsReach(p_Y)
    if p_Y and p_Y > GPS_HIGH_ALTITUDE_Y then return 384 end
    return 64
end

function Coverage()
    local s_Chunks, s_Gps = {}, {}
    if DATA["bounds"] then s_Chunks[#s_Chunks + 1] = DATA["bounds"] end

    -- Every GPS host projects a bubble. Four are needed for a fix, but they are placed as a
    -- cluster, so the intersection of their bubbles is close enough to any one of them -- and
    -- being generous here is safe, since failing to get a fix is not dangerous, only useless.
    -- HOSTS AND A RADIUS, not boxes.
    --
    -- A box of +/-64 per axis has corners 110 blocks from its centre, so "inside the box" was true
    -- far outside real radio range -- and a fix needs FOUR hosts, not one. D8 walked to a corner at
    -- -147,-48 where exactly one host was reachable, lost its position, and stranded. The bounds
    -- check said yes the whole way.
    --
    -- Sent as positions so the drone can do the only test that matters: how many hosts can I
    -- actually hear from where I am about to stand.
    local s_Hosts = {}
    for _, h in ipairs(DATA["gpsHosts"] or {}) do
        s_Hosts[#s_Hosts + 1] = {x = h.x, y = h.y, z = h.z}
    end
    s_Gps = {hosts = s_Hosts, range = gpsReach(85), need = 4}

    -- Loaders are mobile ticking ground: sending one out genuinely opens territory, recalling it
    -- genuinely closes it.
    local s_Res = PowNet.sendAndWaitForResponse("DroneMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetDrones", {}), PowNet.SERVER_PROTOCOL)
    if type(s_Res) == "table" and s_Res.drones then
        for _, d in ipairs(s_Res.drones) do
            if (d.role == "loader") and d.pos and d.pos.x then
                s_Chunks[#s_Chunks + 1] = {
                    minx = d.pos.x - LOADER_REACH, maxx = d.pos.x + LOADER_REACH,
                    miny = 0,                      maxy = 250,
                    minz = d.pos.z - LOADER_REACH, maxz = d.pos.z + LOADER_REACH,
                }
            end
        end
    end
    return s_Chunks, s_Gps
end

function OnGetBounds(p_ID, p_Message)
    local s_Chunks, s_Gps = Coverage()
    return true, {bounds = {chunks = s_Chunks, gps = s_Gps},
                  message = #s_Chunks .. " chunk region(s), " .. #s_Gps .. " gps region(s)"}
end

-- Where the GPS hosts are. Registering them is what lets the fleet reason about positioning
-- coverage at all -- before this, a drone that flew out of modem range just stopped being able
-- to navigate, with nothing anywhere modelling why.
function OnAddGpsHost(p_ID, p_Message)
    local d = p_Message.data or {}
    local p = d.pos or d.gps
    if p == nil then return false, "Missing pos" end
    DATA["gpsHosts"] = DATA["gpsHosts"] or {}
    DATA["gpsHosts"][#DATA["gpsHosts"] + 1] =
        {x = tonumber(p[1] or p.x), y = tonumber(p[2] or p.y), z = tonumber(p[3] or p.z)}
    PowNet.MarkDirty()
    return true, {message = #DATA["gpsHosts"] .. " gps hosts registered"}
end

function OnSetBounds(p_ID, p_Message)
    local d = p_Message.data or {}
    if d.minx == nil then return false, "need minx maxx miny maxy minz maxz" end
    DATA["bounds"] = {
        minx = tonumber(d.minx), maxx = tonumber(d.maxx),
        miny = tonumber(d.miny), maxy = tonumber(d.maxy),
        minz = tonumber(d.minz), maxz = tonumber(d.maxz),
    }
    PowNet.MarkDirty()
    return true, {message = "bounds set", bounds = DATA["bounds"]}
end

function OnMapFollow(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_On = MapRender.setFollow(not d.off)
    Render()
    return true, {message = "follow " .. (s_On and "on" or "off"), follow = s_On}
end

function OnMapInfo(p_ID, p_Message)
    return true, {message = string.format("mode=%s observations=%d",
        MapRender.currentMode(), MapRender.observationCount())}
end
local m_DroneEvents = {

}

----------------------------------------------------------------------------------------------
-- Asking the map questions
----------------------------------------------------------------------------------------------
-- The survey is already a 3D occupancy grid -- cachedWorld[x:y:z] is 1 solid / 0 air / nil unknown,
-- with block names in cachedWorldDetail. Everything below is reading data the scouts already
-- gathered, so it needs no drone, no fuel and no expedition: "where is dirt", "where is iron",
-- "where are the caves" are all answerable from the base.
--
-- This matters because the base sits in a desert. Guessing where to dig wasted a whole dig job on
-- sand; asking the map first is free.

local function parseKey(p_Key)
    -- Anchored, and the sign is matched explicitly. A bare "-" inside a character class is Lua's
    -- lazy quantifier, which silently fails on negative coordinates -- and every coordinate here
    -- is negative.
    local x, y, z = string.match(p_Key, "^(%-?%d+):(%-?%d+):(%-?%d+)$")
    if x == nil then return nil end
    return tonumber(x), tonumber(y), tonumber(z)
end

-- The block index: name -> { count, at = { positions } }, plus a reverse map so it can be
-- CORRECTED rather than only appended to.
--
-- The first version only ever incremented. Nothing decremented it when a block was mined, so the
-- six coal positions stayed listed after a drone had taken them and the supply loop kept
-- dispatching miners to empty coordinates -- an index that is confidently wrong is worse than no
-- index, because the autonomy now trusts it.
--
-- blockAt is what makes correction possible: knowing what USED to be at a position is the only
-- way to decrement the right name when it changes. It costs roughly what cachedWorld already
-- costs, since it holds one entry per known position.
local INDEX_MAX_POSITIONS = 256   -- per name; ores are few, stone is not worth enumerating

local function idxRemovePos(p_Name, p_Key)
    local e = m_BlockIndex[p_Name]
    if e == nil then return end
    e.count = math.max(0, (e.count or 1) - 1)
    if e.at then
        for i = #e.at, 1, -1 do
            local q = e.at[i]
            if q and (q.x .. ":" .. q.y .. ":" .. q.z) == p_Key then table.remove(e.at, i) break end
        end
    end
    if e.count == 0 and (e.at == nil or #e.at == 0) then m_BlockIndex[p_Name] = nil end
end

-- Record what is at a position NOW. p_Name nil means "air / nothing there any more".
function ObserveBlock(p_Key, p_Name)
    if m_BlockIndex == nil then m_BlockIndex = {} end
    if m_BlockAt == nil then m_BlockAt = {} end

    local s_Was = m_BlockAt[p_Key]
    if s_Was == p_Name then return false end          -- nothing changed
    if s_Was then idxRemovePos(s_Was, p_Key) end

    if p_Name == nil then
        m_BlockAt[p_Key] = nil
        return true
    end

    local e = m_BlockIndex[p_Name]
    if e == nil then e = {count = 0, at = {}} m_BlockIndex[p_Name] = e end
    e.count = (e.count or 0) + 1
    if #e.at < INDEX_MAX_POSITIONS then
        local x, y, z = parseKey(p_Key)
        if x then e.at[#e.at + 1] = {x = x, y = y, z = z} end
    end
    m_BlockAt[p_Key] = p_Name
    return true
end

-- The index that already exists on disk was built by the append-only version, so it has counts and
-- sample positions but no blockAt -- and without blockAt nothing can be decremented, which would
-- leave exactly the stale entries this change exists to remove.
--
-- Rebuilding from cachedWorldDetail is not an option: that map is the 1.2MB file this computer
-- cannot load, which is the whole reason the index exists. So seed from the samples instead. They
-- are the positions gather actually digs at, so they are the ones that must be able to go stale.
function BackfillBlockAt()
    if m_BlockAt ~= nil then return 0 end       -- already migrated
    m_BlockAt = {}
    local s_N = 0
    local s_Walked = 0
    for name, e in pairs(m_BlockIndex or {}) do
        -- Same reason as IndexNames: this runs at boot over whatever the index has accumulated.
        s_Walked = s_Walked + 1
        if s_Walked % 500 == 0 then os.sleep(0) end
        for _, q in ipairs(e.at or {}) do
            if q and q.x then
                m_BlockAt[q.x .. ":" .. q.y .. ":" .. q.z] = name
                s_N = s_N + 1
            end
        end
    end
    if s_N > 0 then PowNet.MarkDirty() end
    print(("blockAt backfilled from %d sampled positions"):format(s_N))
    return s_N
end

-- Names arriving from a scan.
function IndexNames(p_Detail)
    if type(p_Detail) ~= "table" then return 0 end
    local s_Changed = 0
    -- YIELD. This is called at boot over the ENTIRE saved map -- 227,000 cells -- and CC terminates
    -- any coroutine that runs ten seconds without yielding. MapServer died roughly 27 seconds into
    -- every boot and restarted, 103 times, with the map frozen the whole while. It is also called
    -- per-upload with a handful of cells, where the yield costs nothing.
    local s_Seen = 0
    for key, info in pairs(p_Detail) do
        s_Seen = s_Seen + 1
        if s_Seen % 2000 == 0 then os.sleep(0) end
        -- THE SHAPE EVERY MOVING DRONE ACTUALLY SENDS WAS THE ONE SHAPE THIS DID NOT ACCEPT.
        --
        -- pgps.detectAll records `{turtle.inspect()}`, which is {true, {name = "..."}} -- a plain
        -- array. This read info.data[2].name and info.name, so that shape matched neither and every
        -- name observed while travelling was dropped without a word. The map ended up with 33,432
        -- occupancy cells and TEN names: the fleet was reporting what it saw and the server was
        -- discarding the useful half.
        --
        -- Downstream that is most of what the map is for. world.find could never locate ore, the
        -- supply loop concluded "none known" for every material and fell back to blind prospecting,
        -- and the operator view showed terrain with no idea what any of it was made of.
        local s_Name
        if type(info) == "table" then
            local s_Data = info.data
            if type(s_Data) == "table" and type(s_Data[2]) == "table" then s_Name = s_Data[2].name end
            -- {ok, block} straight from turtle.inspect
            if not s_Name and info[1] == true and type(info[2]) == "table" then s_Name = info[2].name end
            s_Name = s_Name or info.name
        end
        if s_Name and ObserveBlock(key, s_Name) then s_Changed = s_Changed + 1 end
    end
    if s_Changed > 0 then PowNet.MarkDirty() end
    return s_Changed
end

-- Occupancy arriving from a drone: 0 means the cell is AIR, which is how a mined block reports
-- itself. This is the half that was missing -- scans could add, but nothing could take away.
function IndexOccupancy(p_World)
    if type(p_World) ~= "table" then return 0 end
    -- Yields, like every other walk in here. This one normally sees a small delta -- drones send
    -- takeWorldDelta() now, not their whole map -- but "normally" is doing the work in that
    -- sentence: a drone that has never reported, or one reconnecting after a long blind dig, hands
    -- over everything it has seen. That is a request handler walking an unbounded table, which is
    -- the shape that has killed this module repeatedly.
    local s_Changed, s_Walk = 0, 0
    for key, v in pairs(p_World) do
        if v == 0 and m_BlockAt and m_BlockAt[key] then
            if ObserveBlock(key, nil) then s_Changed = s_Changed + 1 end
        end
        s_Walk = s_Walk + 1
        if s_Walk % 2000 == 0 then os.queueEvent("caveStep") os.pullEvent("caveStep") end
    end
    if s_Changed > 0 then PowNet.MarkDirty() end
    return s_Changed
end

-- Find surveyed blocks whose name contains p_Match. Substring, so "ore" finds every ore and
-- "dirt" finds dirt/coarse_dirt/rooted_dirt.
function OnFindBlocks(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Match = d.match or d.item
    if s_Match == nil then return false, "Missing match" end
    local s_Limit = tonumber(d.limit) or 40

    -- Served from the incremental index, NOT by walking the detail map: that map is over 1.2MB
    -- and does not load on an in-world computer, so scanning it returned zero for every query.
    local s_Index = m_BlockIndex or {}
    local s_Hits, s_Counts, s_Total = {}, {}, 0
    for s_Name, e in pairs(s_Index) do
        if string.find(s_Name, s_Match, 1, true) then
            s_Total = s_Total + e.count
            s_Counts[s_Name] = e.count
            for _, p in ipairs(e.at or {}) do
                if #s_Hits >= s_Limit then break end
                s_Hits[#s_Hits + 1] = {name = s_Name, x = p.x, y = p.y, z = p.z}
            end
        end
    end

    local s_Msg = s_Total .. " matching '" .. s_Match .. "'"
    if s_Total == 0 then s_Msg = s_Msg .. " -- nothing surveyed matches; survey more first" end
    return true, {message = s_Msg, total = s_Total, counts = s_Counts, hits = s_Hits}
end

-- The whole position -> block name map, for anything that wants to DRAW the world rather than
-- query it.
--
-- cachedWorld already answers "is this cell solid", which is all a pathfinder needs and all the
-- map page could show: terrain as one undifferentiated mass of grey cubes. What it cannot say is
-- WHAT is solid, and that is the difference between a picture of the terrain and a picture of the
-- terrain worth mining.
--
-- The obvious source, cachedWorldDetail, is the 1.2MB file this computer cannot load -- the same
-- wall OnFindBlocks hit. blockAt is the compact form that exists precisely because the index
-- needed a reverse map, so serving it costs nothing extra.
--
-- IT IS NOT THE WHOLE WORLD. blockAt only holds positions a drone actually observed and reported
-- a name for, which is a small subset of the cells cachedWorld knows the occupancy of. A caller
-- must treat a missing key as "solid but unidentified", never as air -- cachedWorld remains the
-- authority on what is solid.
-- PAGED, because the whole map does not fit in a websocket frame.
--
-- This returned every known position in one reply. At 1,900 entries that is 427KB of JSON, and
-- CC:T refuses to send a frame that size -- so the send threw, the Bridge closed the socket, and
-- the entire fleet dropped off HQ every time the map page asked for terrain. One oversized answer
-- was taking down the link for everything else.
local BLOCKAT_PAGE = 400

function OnBlockAt(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Offset = tonumber(d.offset) or 0
    local s_Limit  = math.min(tonumber(d.limit) or BLOCKAT_PAGE, BLOCKAT_PAGE)
    local s_At = m_BlockAt or {}

    -- INDEX THE KEYS ONCE, then serve slices -- exactly as LoadWorld does, and for the same reason.
    -- This walked all 172,296 named blocks on EVERY page to find its 2000, so reading the index end
    -- to end came to 86 pages x 172,296 = fifteen million iterations, none of them yielding. Page
    -- nine ran past CC's ten-second limit and was killed, HQ read the dead page as the end of the
    -- map, and 16,000 identified blocks got cached as though that were all of them. That is the
    -- "blocks missing from /map" report: not lost survey data, a paginator that could not reach past
    -- its eighth page.
    --
    -- The comment this replaces argued the imprecision of an unstable pairs() order was cheaper than
    -- sorting "1,900 keys". The table is ninety times that size now, and the cost was never the
    -- ordering -- it was re-walking the whole index per page. Pinning the order at offset 0 fixes
    -- both: one walk per full read, and pages that cannot skip or repeat entries while scans arrive.
    if s_Offset == 0 or m_BlockKeys == nil then
        m_BlockKeys = {}
        local s_Since = 0
        for key in pairs(s_At) do
            m_BlockKeys[#m_BlockKeys + 1] = key
            s_Since = s_Since + 1
            if s_Since >= 2000 then s_Since = 0 ; os.queueEvent("blockPage") ; os.pullEvent("blockPage") end
        end
    end

    local s_N = #m_BlockKeys
    local s_Page, s_Sent = {}, 0
    for i = s_Offset + 1, math.min(s_Offset + s_Limit, s_N) do
        local name = s_At[m_BlockKeys[i]]
        if name then s_Page[m_BlockKeys[i]] = name end
        s_Sent = s_Sent + 1
    end

    local s_Next = s_Offset + s_Sent
    return true, {
        blockAt = s_Page, count = s_N, offset = s_Offset, sent = s_Sent,
        next = (s_Next < s_N) and s_Next or nil,
    }
end

-- Connected pockets of surveyed AIR. A cave is air that is enclosed -- so ignore anything at or
-- above the highest solid block in its column, which is open sky rather than a cave.
-- HOW MUCH OF A REGION DO WE ACTUALLY KNOW?
--
-- Needed because "the drone said it finished" and "the area is surveyed" turned out to be
-- completely different claims. A scout reports done when it has walked its scan grid; whether that
-- grid covered the region nobody ever checked, so tasks read 100% over ground that was still blank
-- on the map. Progress that cannot be contradicted by the world is not progress, it is a rumour.
--
-- Counts the KNOWN cells in the box rather than sampling, because the box is bounded by the caller
-- and the map is a hash -- walking the box is cheap and exact, and an estimate here would put us
-- straight back to guessing.
function OnRegionKnown(p_ID, p_Message)
    local d = p_Message.data or {}
    if not (d.min and d.max) then return false, "need min and max" end

    local s_World = PowGPSServer.getCachedWorld()
    local s_Known, s_Total = 0, 0
    for x = math.floor(d.min.x), math.floor(d.max.x) do
        for y = math.floor(d.min.y), math.floor(d.max.y) do
            for z = math.floor(d.min.z), math.floor(d.max.z) do
                s_Total = s_Total + 1
                if s_World[x .. ":" .. y .. ":" .. z] ~= nil then s_Known = s_Known + 1 end
            end
        end
        -- The box can be tens of thousands of cells. Yielding keeps MapServer answering everything
        -- else while it counts, which is the difference between a slow reply and a dead module.
        -- Yield every column, not every eighth. This walk can be twenty thousand cells and
        -- MapServer must keep answering path requests while it runs.
        os.sleep(0)
    end

    -- STALENESS, alongside coverage. "Known" and "known recently" are different questions, and a
    -- fleet that only asks the first re-walks ground it covered an hour ago while somewhere it has
    -- not looked at all since the world started stays dark. The age is per chunk -- see
    -- PowGPSServer.ChunkAge -- which is the granularity the answer is actually wanted at.
    local s_Oldest, s_Newest = nil, nil
    for x = math.floor(d.min.x), math.floor(d.max.x), 16 do
        for z = math.floor(d.min.z), math.floor(d.max.z), 16 do
            local age = PowGPSServer.ChunkAge(x, z)
            if age == nil then
                s_Oldest = math.huge          -- never looked at at all
            else
                if s_Oldest == nil or age > s_Oldest then s_Oldest = age end
                if s_Newest == nil or age < s_Newest then s_Newest = age end
            end
        end
    end

    return true, {known = s_Known, total = s_Total,
                  percent = s_Total > 0 and math.floor(s_Known / s_Total * 100) or 0,
                  oldestMs = (s_Oldest ~= math.huge) and s_Oldest or nil,
                  neverSeen = s_Oldest == math.huge,
                  newestMs = s_Newest}
end

local ADJACENT = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}

-- CAVES ARE COMPUTED IN THE BACKGROUND, NOT WHILE A CALLER WAITS.
--
-- This is two full walks of the world plus a flood fill, and it yields roughly every 2000 cells --
-- but a yield in CC costs a whole tick, so at 274,750 cells the yields ALONE are about fourteen
-- seconds before any actual work. No caller will ever wait that long: world.caves timed out at 60s
-- and the next call in was refused too, because MapServer was still finishing the fill.
--
-- It does not need to be live. Caves change when drones dig, on the timescale of minutes, and every
-- consumer (the map page, the survey dispatcher) is looking at a picture of the world rather than
-- steering off it. So it runs on a loop and the handler serves the last answer, instantly.
local m_Caves, m_CavesAt, m_CavesMin = nil, 0, 8

local function ComputeCaves(s_MinSize)
    local s_World = PowGPSServer.getCachedWorld() or {}

    -- Surface height per column, so open air can be told from enclosed air.
    --
    -- YIELD. This walks the entire map twice -- once here, once for the flood fill below -- and at
    -- 237,000 cells each pass is far past the ten seconds CC allows without yielding. So cave
    -- detection did not merely return nothing: it aborted MapServer every time anything asked.
    -- world.caves has been answering "no response" since the map got large, which is why nothing
    -- has ever dispatched a cave survey and why the scouts had nothing to spelunk.
    local s_Top = {}
    local s_Walk = 0
    for key, v in pairs(s_World) do
        s_Walk = s_Walk + 1
        if s_Walk % 2000 == 0 then os.queueEvent("caveStep") os.pullEvent("caveStep") end
        if v == 1 then
            local x, y, z = parseKey(key)
            if x then
                local col = x .. ":" .. z
                if s_Top[col] == nil or y > s_Top[col] then s_Top[col] = y end
            end
        end
    end

    local s_Seen, s_Caves = {}, {}
    s_Walk = 0
    for key, v in pairs(s_World) do
        s_Walk = s_Walk + 1
        if s_Walk % 2000 == 0 then os.queueEvent("caveStep") os.pullEvent("caveStep") end
        if v == 0 and not s_Seen[key] then
            local x0, y0, z0 = parseKey(key)
            local col = x0 and (x0 .. ":" .. z0)
            if x0 and s_Top[col] and y0 < s_Top[col] then
                -- flood fill this pocket
                local s_Stack, s_Cells = {{x0, y0, z0}}, {}
                s_Seen[key] = true
                -- Yield here too, and hoist the neighbour table out of the loop.
                --
                -- A single connected air pocket can be tens of thousands of cells -- the fleet has
                -- mined kilometres of tunnel, and tunnels are one enormous connected pocket. So
                -- this loop, not just the two walks above, is what blew the ten-second budget.
                -- Rebuilding a six-element table on every iteration was pure waste on top.
                local s_Fill = 0
                while #s_Stack > 0 do
                    s_Fill = s_Fill + 1
                    if s_Fill % 2000 == 0 then os.queueEvent("caveStep") os.pullEvent("caveStep") end
                    local c = table.remove(s_Stack)
                    s_Cells[#s_Cells + 1] = c
                    for _, o in ipairs(ADJACENT) do
                        local nx, ny, nz = c[1]+o[1], c[2]+o[2], c[3]+o[3]
                        local nk = nx .. ":" .. ny .. ":" .. nz
                        if s_World[nk] == 0 and not s_Seen[nk] then
                            local ncol = nx .. ":" .. nz
                            if s_Top[ncol] and ny < s_Top[ncol] then
                                s_Seen[nk] = true
                                s_Stack[#s_Stack + 1] = {nx, ny, nz}
                            end
                        end
                    end
                end
                if #s_Cells >= s_MinSize then
                    local minx, miny, minz = math.huge, math.huge, math.huge
                    local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
                    for _, c in ipairs(s_Cells) do
                        if c[1] < minx then minx = c[1] end
                        if c[2] < miny then miny = c[2] end
                        if c[3] < minz then minz = c[3] end
                        if c[1] > maxx then maxx = c[1] end
                        if c[2] > maxy then maxy = c[2] end
                        if c[3] > maxz then maxz = c[3] end
                    end
                    s_Caves[#s_Caves + 1] = {size = #s_Cells,
                        min = {x = minx, y = miny, z = minz},
                        max = {x = maxx, y = maxy, z = maxz},
                        entrance = {x = x0, y = y0, z = z0}}
                end
            end
        end
    end
    table.sort(s_Caves, function(a, b) return a.size > b.size end)
    return s_Caves
end

-- Serve the cache. Never compute here.
function OnFindCaves(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_MinSize = tonumber(d.min) or 8
    -- A different threshold than the one last computed is worth honouring, but on the NEXT pass --
    -- the loop picks it up. Answering "here is the map I have" beats answering nothing.
    m_CavesMin = s_MinSize
    if m_Caves == nil then
        return true, {message = "cave scan has not finished its first pass yet",
                      count = 0, caves = {}, ready = false}
    end
    local s_Age = math.floor(os.clock() - m_CavesAt)
    return true, {message = #m_Caves .. " cave pocket(s) of >= " .. m_CavesMin
                      .. " cells, scanned " .. s_Age .. "s ago",
                  count = #m_Caves, caves = m_Caves, ready = true, age = s_Age}
end

-- Rescan on a slow loop. The first pass runs shortly after boot so the answer is there before
-- anything asks; after that, once a minute is far more often than caves actually change.
local function CaveLoop()
    os.sleep(20)
    while true do
        local ok, s_Result = pcall(ComputeCaves, m_CavesMin)
        if ok then
            m_Caves, m_CavesAt = s_Result, os.clock()
        else
            Log("cave scan failed: " .. tostring(s_Result))
        end
        os.sleep(60)
    end
end

local m_ServerEvents = {
    UpdatePath = {
        func = OnUpdatePath
    },
    SaveWorld = {
        func = OnSaveWorld
    },
    LoadWorld = {
        func = OnLoadWorld
    },
    GetPath = {
        func = OnGetPath
    },
    SetDronePos = {
        func = OnSetDronePos
    },
    GetBounds = { func = OnGetBounds },
    FindBlocks = { func = OnFindBlocks },
    FindCaves  = { func = OnFindCaves },
    RegionKnown = { func = OnRegionKnown },
    BlockAt    = { func = OnBlockAt },
    gpshost = {
        func = OnAddGpsHost, callable = true,
        params = { pos = { length = 3 } }
    },
    bounds = {
        func = OnSetBounds, callable = true,
        params = { minx={}, maxx={}, miny={}, maxy={}, minz={}, maxz={} }
    },
    map = {
        func = OnMapMode,
        callable = true,
        params = {
            mode = {
                optional = true
            }
        }
    },
    follow = {
        func = OnMapFollow,
        callable = true,
        params = { off = { length = 0, optional = true } }
    },
    mapinfo = {
        func = OnMapInfo,
        callable = true,
        params = {}
    },
}

-- Ask DroneMan where the fleet is. Cached briefly: Render runs after every message the server
-- handles, and a rednet round-trip per redraw would make a busy survey slower than the survey.
local m_Drones, m_DronesAt = nil, 0
local function fleet()
    local s_Now = os.clock()
    if m_Drones and (s_Now - m_DronesAt) < 5 then
        return m_Drones
    end
    local s_Msg = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetDrones", {})
    local s_Res = PowNet.sendAndWaitForResponse("DroneMan", s_Msg, PowNet.SERVER_PROTOCOL)
    if type(s_Res) == "table" and s_Res.drones then
        m_Drones, m_DronesAt = s_Res.drones, s_Now
    end
    return m_Drones
end

function Render()
    -- Whatever display exists: a monitor of any size if one is attached, otherwise this computer's
    -- own screen. MapRender fits the surveyed bounds to it, so nothing here needs to know the
    -- dimensions and the same code works before and after a monitor wall gets built.
    local s_Dev = PowNet.Monitor()
    local s_Fleet = nil
    pcall(function() s_Fleet = fleet() end)
    local s_Ok, s_Err = pcall(MapRender.draw, s_Dev,
        PowGPSServer.getCachedWorld(), PowGPSServer.cachedWorldDetail, m_Overlay, s_Fleet)
    if not s_Ok then
        print("Render failed: " .. tostring(s_Err))
    end
end




Init()

-- DO NOT PERSIST THE BLOCK INDEX. IT IS DERIVED.
--
-- blockAt and blockIndex live in DATA, and DATA is written back to MainFrame over rednet when a
-- module stands down. They had grown to 7.1 MB -- blockAt alone accounted for 6.8 MB -- so every
-- shutdown tried to push seven megabytes through a rednet message, and MapServer simply never
-- finished: it exited cleanly, hung in the write-back, and never reached the reboot. From outside
-- it looked like a module that had died without a reason, which is exactly what it looked like for
-- hours.
--
-- Neither table needs persisting. Init() rebuilds both from the chunk files on disk, which already
-- carry block names through the interned dictionary -- that is what "indexed N named blocks" is
-- reporting. Dropping them before the write-back costs one boot-time rebuild and saves shipping
-- the entire index across the network every time anything restarts.
PowNet.SetShutdownHook(function(p_Reason)
    m_BlockAt, m_BlockIndex = nil, nil
    print("dropped the derived block index before write-back (" .. tostring(p_Reason) .. ")")
end)

-- RENDER IS NOT THE POST-MESSAGE HOOK.
--
-- The third argument to RegisterEvents is what PowNet.main runs after EVERY message it handles --
-- and this was Render, which walks all 274,750 cells to build a height field and makes a rednet
-- round-trip to DroneMan on the way. So MapServer answered exactly one request and then spent
-- longer than CC's ten-second limit drawing a monitor nobody was looking at, over and over, once
-- per message. That is the whole of "a module found and then silent": it hosted its name, resolved
-- for every caller, served the first thing it was asked, and starved from then on. Making RenderLoop
-- follow-mode-only fixed the timer but left this path untouched, which is why the symptom survived.
--
-- Same gate as the loop, plus a floor between redraws: the picture only changes on its own in follow
-- mode, and no monitor needs redrawing several times a second.
local m_LastRender = 0
local function RenderIfWatched()
    if not MapRender.following() then return end
    local s_Now = os.clock()
    if s_Now - m_LastRender < 5 then return end
    m_LastRender = s_Now
    pcall(Render)
end

PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents, RenderIfWatched)

SetStatus("Connected!", colors.green)

-- DO NOT RENDER BEFORE THE SERVER IS SERVING.
--
-- Render() was called right here, unconditionally, and MapRender.draw walks every cell in the map.
-- At 230,000 cells that takes longer than anything else in the boot -- and it happens BEFORE
-- parallel.waitForAny, so PowNet.main had not started yet. MapServer therefore hosted its name
-- (InitServer does that earlier, in the bootloader), resolved correctly for every caller, and
-- answered nothing at all: the Bridge logged "call MapServer.LoadWorld FAILED (lookup=111)" -- a
-- module found and then silent. It looked like a busy server or a network fault and was neither.
--
-- The map is a display. It can wait two seconds for the loop below to draw it; the fleet cannot
-- wait for pathfinding.
-- RENDER ONLY WHEN SOMEONE IS ACTUALLY WATCHING.
--
-- Render walks every cell in the map to build a height field, and calls fleet() -- a rednet round
-- trip to DroneMan -- on the way. At 259,000 cells that is the most expensive thing this module
-- does, and it was running on the first pass of this loop whether or not anyone was looking at the
-- monitor. MapServer resolved for every caller and answered none of them: the Bridge logged
-- "call MapServer.FindBlocks FAILED (lookup=111)" over and over, a module found and then silent.
--
-- The monitor is a nicety. Pathfinding is not. Render now happens only in follow mode, which is
-- the only time the picture changes on its own, and the map is redrawn on message arrival anyway.
local function RenderLoop()
    while true do
        os.sleep(2)
        RenderIfWatched()
    end
end

parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, RenderLoop, CaveLoop)
PowGPSServer.saveAll()
print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
