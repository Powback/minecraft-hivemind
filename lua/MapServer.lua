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
        -- Matches the force-loaded region. Deliberately a little inside it, so a drone stops
        -- before the edge rather than exactly on it.
        DATA["bounds"] = {minx = -180, maxx = -25, miny = 0, maxy = 200, minz = -110, maxz = 15}
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
    local s_Known = {
        -- The original surface constellation, deliberately non-coplanar.
        {x = -92, y = 95, z = -52}, {x = -78, y = 95, z = -52},
        {x = -92, y = 95, z = -38}, {x = -85, y = 99, z = -45},
        -- EIGHTEEN HOSTS, PLACED WHERE THE FLEET ACTUALLY IS.
        --
        -- Coverage was chased in the wrong direction for a long time. Hosts were added ring by
        -- ring, then a 40-host lattice, then a searched 60-host one -- and the fleet got WORSE at
        -- every step, ending with twelve of fourteen drones unable to fix their position while
        -- sitting inside nominally perfect coverage.
        --
        -- Two things were wrong. gps.locate broadcasts and collects every reply inside its timeout,
        -- so sixty-four hosts answering at once overflows the event queue and the replies it needed
        -- are among those dropped -- GPS in CC:T does not scale with host count, and past a point
        -- more hosts is strictly worse. And the geometry was never the real problem: the drones had
        -- simply WANDERED, three of them past the edge of the force-loaded region entirely, so no
        -- constellation centred on the base was ever going to reach them.
        --
        -- So this was placed against measured drone positions rather than a model of where they
        -- ought to be, and checked: every drone in the fleet hears at least four. Spread in Y
        -- because four hosts on a plane cannot resolve altitude.
        {x = -105, y = 28, z = -70}, {x = -70,  y = 22, z = -66},
        {x = -100, y = 40, z = -25}, {x = -62,  y = 34, z = -30},
        {x = -85,  y = 46, z = -55}, {x = -125, y = 30, z = -45},
        {x = -150, y = 72, z = -60}, {x = -145, y = 44, z = -30},
        {x = -168, y = 62, z = -70}, {x = -132, y = 56, z = -12},
        {x = -175, y = 84, z = -66}, {x = -158, y = 90, z = -84},
        {x = -80,  y = 30, z = -95}, {x = -108, y = 42, z = -92},
        -- Southeast, added when the fleet expanded past the previous edge. Coverage follows the
        -- drones; it is checked against their measured positions, not assumed from the base.
        {x = -45,  y = 80, z = -100}, {x = -60,  y = 88, z = -105},
        {x = -38,  y = 70, z = -85},  {x = -55,  y = 92, z = -80},
    }
    DATA["gpsHosts"] = DATA["gpsHosts"] or {}
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
    if s_Offset == 0 or m_PageKeys == nil then
        m_PageKeys = {}
        for key in pairs(s_World) do m_PageKeys[#m_PageKeys + 1] = key end
    end

    -- Report what the SERVING path sees. The load logs 230,629 cells and the caller gets zero, so
    -- one of those two views of cachedWorld is wrong and only the server can say which.
    if s_Offset == 0 and _G.Log then
        local s_Live = 0
        for _ in pairs(s_World) do s_Live = s_Live + 1 end
        _G.Log(("LoadWorld: live=%d keys=%d"):format(s_Live, #m_PageKeys))
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
    local e = DATA["blockIndex"][p_Name]
    if e == nil then return end
    e.count = math.max(0, (e.count or 1) - 1)
    if e.at then
        for i = #e.at, 1, -1 do
            local q = e.at[i]
            if q and (q.x .. ":" .. q.y .. ":" .. q.z) == p_Key then table.remove(e.at, i) break end
        end
    end
    if e.count == 0 and (e.at == nil or #e.at == 0) then DATA["blockIndex"][p_Name] = nil end
end

-- Record what is at a position NOW. p_Name nil means "air / nothing there any more".
function ObserveBlock(p_Key, p_Name)
    if DATA["blockIndex"] == nil then DATA["blockIndex"] = {} end
    if DATA["blockAt"] == nil then DATA["blockAt"] = {} end

    local s_Was = DATA["blockAt"][p_Key]
    if s_Was == p_Name then return false end          -- nothing changed
    if s_Was then idxRemovePos(s_Was, p_Key) end

    if p_Name == nil then
        DATA["blockAt"][p_Key] = nil
        return true
    end

    local e = DATA["blockIndex"][p_Name]
    if e == nil then e = {count = 0, at = {}} DATA["blockIndex"][p_Name] = e end
    e.count = (e.count or 0) + 1
    if #e.at < INDEX_MAX_POSITIONS then
        local x, y, z = parseKey(p_Key)
        if x then e.at[#e.at + 1] = {x = x, y = y, z = z} end
    end
    DATA["blockAt"][p_Key] = p_Name
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
    if DATA["blockAt"] ~= nil then return 0 end       -- already migrated
    DATA["blockAt"] = {}
    local s_N = 0
    local s_Walked = 0
    for name, e in pairs(DATA["blockIndex"] or {}) do
        -- Same reason as IndexNames: this runs at boot over whatever the index has accumulated.
        s_Walked = s_Walked + 1
        if s_Walked % 500 == 0 then os.sleep(0) end
        for _, q in ipairs(e.at or {}) do
            if q and q.x then
                DATA["blockAt"][q.x .. ":" .. q.y .. ":" .. q.z] = name
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
        local s_Name
        if type(info) == "table" then
            local s_Data = info.data
            if type(s_Data) == "table" and type(s_Data[2]) == "table" then s_Name = s_Data[2].name end
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
    local s_Changed = 0
    for key, v in pairs(p_World) do
        if v == 0 and DATA["blockAt"] and DATA["blockAt"][key] then
            if ObserveBlock(key, nil) then s_Changed = s_Changed + 1 end
        end
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
    local s_Index = DATA["blockIndex"] or {}
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
    local s_At = DATA["blockAt"] or {}

    -- pairs() order is not stable across calls in general, but this table is only mutated by
    -- observations, so a page walk between polls is close enough for a display. Sorting 1,900 keys
    -- on every request to guarantee it would cost more than the imprecision is worth.
    local s_Page, s_N, s_Sent = {}, 0, 0
    for key, name in pairs(s_At) do
        if s_N >= s_Offset and s_Sent < s_Limit then
            s_Page[key] = name
            s_Sent = s_Sent + 1
        end
        s_N = s_N + 1
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

function OnFindCaves(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_MinSize = tonumber(d.min) or 8
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
        if s_Walk % 2000 == 0 then os.sleep(0) end
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
        if s_Walk % 2000 == 0 then os.sleep(0) end
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
                    if s_Fill % 2000 == 0 then os.sleep(0) end
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
    return true, {message = #s_Caves .. " cave pocket(s) of >= " .. s_MinSize .. " cells",
                  count = #s_Caves, caves = s_Caves}
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
PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents, Render)

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
local function RenderLoop()
    local s_First = true
    while true do
        -- First pass immediately after the serving loop is up, then only when following.
        if s_First or MapRender.following() then
            s_First = false
            pcall(Render)
        end
        os.sleep(2)
    end
end

parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, RenderLoop)
PowGPSServer.saveAll()
print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
