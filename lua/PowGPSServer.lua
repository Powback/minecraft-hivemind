

-- waypoint locations
waypoints = {}

-- exclusion locations (will not pathfind through area)
exclusions = {}

-- cache world geometry
cachedWorld = {}
-- cached wrld with block names
cachedWorldDetail = {}

aged = {}


-- A* parameters
local stopAt, nilCost = 1500, 1000


-- Directions
North, West, South, East, Up, Down = 0, 1, 2, 3, 4, 5
local shortNames = {[North] = "N", [West] = "W", [South] = "S",
                    [East] = "E", [Up] = "U", [Down] = "D" }
local deltas = {[North] = {0, 0, -1}, [West] = {-1, 0, 0}, [South] = {0, 0, 1},
                [East] = {1, 0, 0}, [Up] = {0, 1, 0}, [Down] = {0, -1, 0}}

----------------------------------------
-- getBlock
--
-- function: tests to see if there is a block or space.
-- return: bool (true if there is a block)
-- return: nil if there is no information on the block
--

-- YIELD, OR CC KILLS THE COROUTINE MID-WALK.
--
-- CC:T terminates anything that runs ~10s without yielding, uncatchably, and the computer is left
-- POWERED OFF with a clean-looking last-run. queueEvent/pullEvent satisfies the watchdog and
-- resumes in the SAME tick, so a full walk still costs no wall clock -- os.sleep(0) costs a tick
-- per iteration and is refused by lua-hygiene for that reason. 7 hand-written copies before this.
local function breathe(p_Tag)
    -- dup: allow (three modules need this and CC has no shared library here -- giving them one
    -- means a new os.loadAPI file deployed to every computer, which is a deployment change,
    -- not a refactor. Two lines each is the cheaper of the two honest options.)
    os.queueEvent(p_Tag) os.pullEvent(p_Tag)
end

function getBlock(bX, bY, bZ)
    local idx_block = bX..":"..bY..":"..bZ
    if cachedWorld[idx_block] == nil then
        return nil
    elseif cachedWorld[idx_block] == 1 then
        return true, cachedWorldDetail[idx_block]
    elseif cachedWorld[idx_block] == 0 then
        return false
    else
        return nil
    end
end

----------------------------------------
-- drawMap()
--
-- function: draws a map of the current coordinates
-- input x, y, z
-- input optional: characters to replace the ones it uses to draw
--

function drawMap(ox, oy, oz, block, empty, floor, none)
    local resx, resy = term.getSize()
    ox = ox - math.floor(resx/2)--west = negx
    oz = oz - math.floor(resy/2)--north = negz
    block = block or "@"
    empty = empty or " "
    floor = floor or "#"
    none = none or "'"
    --term.clear()
    for i=1, resy do
        for j=1, resx do
            term.setCursorPos(j, i)
            if getBlock(ox+j, oy, oz+i) == nil then
                --draw empty
                term.write(none)
            elseif getBlock(ox+j, oy, oz+i) then
                --draw block
                term.write(block)
            elseif getBlock(ox+j, oy-1, oz+i) == true then
                --draw floor
                term.write(floor)
            else
                term.write(empty)
            end
        end
    end
    --drawTurtleOnMap(ox, oy, oz, cachedX, cachedY, cachedZ, cachedDir)
end

----------------------------------------
-- drawTurtleOnMap
--
-- function: for use with drawMap, draws a turtle on the map
-- input ox, oy, oz - x, y, z values used to draw the map
-- input x, y, z, d - location and direction of turtle
--

function drawTurtleOnMap(ox, oy, oz, x, y, z, d)
    local resx, resy = term.getSize()
    term.setCursorPos(math.floor(resx/2) + (x - ox), math.floor(resy/2) + (z - oz))
    if(d == 0) then
        term.write("^")--north
    elseif(d == 1) then
        term.write("<")--west
    elseif(d == 2) then
        term.write("v")--south
    elseif(d == 3) then
        term.write(">")
    else
        term.write("#")
    end
end


----------------------------------------
-- printWorld
--
-- function: for debugging, prints raw world data to screen
--

function printWorld()
    print(textutils.serialize(cachedWorld))
end

----------------------------------------
-- getCachedWorld
--
-- return: cached world as table
--

function getCachedWorld()
    return cachedWorld
end

--- The live detail map, via a FUNCTION rather than the API table.
---
--- os.loadAPI snapshots this file's globals into the PowGPSServer table when it is loaded. loadDetail
--- then does `cachedWorldDetail = {}` and fills the new table -- so the snapshot still points at the
--- empty one, for ever. MapServer's index rebuild read PowGPSServer.cachedWorldDetail, got that
--- empty table, and indexed nothing: world.find answered "nothing surveyed matches" for coal, iron,
--- copper and zinc that were all sitting in the saved map, correctly recorded.
---
--- A function is evaluated inside this file's environment at call time, so it returns the real one.
--- getCachedWorld already worked for exactly this reason, which is why the occupancy grid was fine
--- and only the names were missing.
function getCachedWorldDetail()
    return cachedWorldDetail
end


----------------------------------------
-- worldSize
--
-- return: size of the world map (number of blocks)
--

function worldSize()--TODO: this does not work.. fix it
    local count = 0
    for _ in pairs(cachedWorld) do
        count = count + 1
    end
    return count
end



----------------------------------------
--
--
--
--
--
--

function getFile(name)
    if fs.exists("/egpsData/"..name) then
        local file = fs.open("/egpsData/"..name,"r")
        local data = file.readAll()
        file.close()
        return data
    else
        print("file not found: "..name)
        return ""
    end
end

----------------------------------------
--
--
--
--
--
--

function setFile(name, data)
    if fs.isDir("/egpsData") then
        local file = fs.open("/egpsData/"..name,"w")
        file.write(textutils.serialize(data))
        file.close()
        return true
    else
        print("creating "..name.." file...")
        fs.makeDir("/egpsData")
        return setFile(name)
    end
    print("a black hole happened")
    return false
end


function loadAll()
    load()
    loadDetail()
    loadWaypoints()
    loadExclusions()
end

function saveAll()
    save()
    saveDetail()
    saveWaypoints()
    saveExclusions()
end

----------------------------------------
-- THE MAP FORMAT, AND WHY IT IS NOT textutils.serialize
--
-- The map stopped growing at 23,792 cells and nobody could see why: MapServer reported 111,684
-- cells in memory, the disk held a fifth of that, and the shortfall came back after every reload.
-- It was not a paging bug and it was not a leak. Every single save was failing:
--
--     module=MapServer ok=false err=/PowGPSServer:179: Out of space
--
-- textutils.serialize pretty-prints, and each cell was carrying a `discoverer`, a `discovered`
-- {day,time} and a `lastUpdated` {day,time} alongside the one thing anybody reads -- the block
-- name. That is 330 bytes per cell to record "sandstone". At 111k cells the serialized detail map
-- is about 36 MB against a computer_space_limit of 8 MB, so the write died part way, took
-- MapServer down with it, and the reboot reloaded the last file small enough to have been written.
-- The map could never exceed what fitted, and everything above it was discarded on every cycle.
--
-- Three changes, in order of how much they win:
--
--   1. Do not persist the metadata. Nothing reads `discoverer` or `discovered` at all, and
--      `lastUpdated` is only consulted through the `aged` list, which keeps its own copy and is
--      rebuilt in memory on every merge. Three hundred of those 330 bytes were dead weight.
--   2. Intern the block names. A map is tens of thousands of cells drawn from a few dozen distinct
--      blocks, so the names belong in a header and the cells should hold an index. No information
--      is lost -- the renderer still gets "minecraft:sandstone", it is just not spelled out 3,791
--      times.
--   3. Stream it. Building the whole file as one Lua string first is what makes a large map fail
--      as a memory problem instead of merely a slow write.
--
-- Together that is roughly 330 bytes per cell down to about 22, so the same 8 MB now holds a map
-- several times larger than the one we were losing.
--
-- Old files are still read. The format is detected from the first byte rather than assumed,
-- because the alternative is a silent upgrade that throws away every cell surveyed so far.

-- THE MAP IS STORED IN CHUNKS, THE WAY MINECRAFT STORES ITS WORLD.
--
-- It used to be one flat table written out whole on every save. That is fine at twenty thousand
-- cells and ruinous at a hundred and fifty thousand: 3.4MB rewritten through a Lua loop, during
-- which MapServer answers nothing -- `hive.nodes` reported it unreachable, path requests timed out,
-- and drones sat in moveTo with executing=true and no movement for minutes. The fleet was not
-- stuck, it was queued behind a file write.
--
-- Sixteen-by-sixteen columns per file, matching Minecraft's chunks and CC's own chunk loading, so
-- the unit the map is stored in is the same unit the world is loaded in and the same unit the
-- drones already path by. A save then writes only the chunks that actually changed -- typically one
-- or two, a few kilobytes -- instead of the entire world.
--
-- It is also the seam for splitting the map across several computers later: a chunk key is all a
-- router needs to decide which MapServer owns a cell, and the 8MB disk limit becomes per-shard
-- rather than a ceiling on the whole world.
local CHUNK = 16
local CHUNK_DIR = "/egpsData/chunks"

--- Which chunk file does this cell key live in?
local function chunkOfKey(p_Key)
    local x, _, z = p_Key:match("^(-?%d+):(-?%d+):(-?%d+)$")
    if x == nil then return nil end
    return math.floor(tonumber(x) / CHUNK) .. "_" .. math.floor(tonumber(z) / CHUNK)
end

-- Chunks touched since the last save. Everything that writes to the map marks its chunk here;
-- anything that forgets simply does not get persisted, which is why the marking lives inside the
-- merge functions rather than at each call site.
local m_Dirty = {}

-- HOW MUCH IS WAITING TO REACH DISK.
--
-- Exposed because the caller decides how often to save, and it was deciding on a fixed timer with
-- no idea whether there was a backlog. save() writes at most CHUNKS_PER_SAVE chunks a pass -- which
-- is right, an unbounded write takes the module past CC's ten-second kill -- so a survey that
-- dirties two hundred chunks needs many passes, and a sixty-second gap between them means most of
-- it is still in memory when the module next restarts.
--
-- That is not hypothetical: it is where the redstone went. The scout descended to y=24, scanned the
-- band, and the six redstone_ore entries were in the index and gone again after the next redeploy,
-- while the rest of the band -- written in earlier passes -- survived.
function dirtyChunks()
    local n = 0
    for _ in pairs(m_Dirty) do n = n + 1 end
    return n
end

-- ONE DICTIONARY FOR THE WHOLE MAP, not one per chunk.
--
-- Interning names per chunk was the first cut and it is wasteful in the way that matters: the same
-- forty-odd block names get spelled out again in every one of a hundred chunk files, and a name
-- means something different depending on which file you read it in -- so a chunk is not portable
-- and two chunks cannot be compared without decoding both.
--
-- A single append-only dictionary fixes both. An id is stable across the entire map and for the
-- life of the world, chunk rows are pure integers, and moving a chunk to another computer only
-- requires that computer to have the same dictionary -- which is one small file.
--
-- Append-only on purpose: ids are referenced by every chunk on disk, so an id must never be reused
-- or renumbered. Names are only ever added.
local m_Names = {}      -- id -> name
local m_NameId = {}     -- name -> id
local m_DictDirty = false   -- a name was added since the dictionary was last written

local function nameId(p_Name)
    if p_Name == nil then return 0 end
    local id = m_NameId[p_Name]
    if id then return id end
    m_Names[#m_Names + 1] = p_Name
    id = #m_Names
    m_NameId[p_Name] = id
    m_DictDirty = true
    return id
end

local function saveNames()
    if not m_DictDirty then return end
    local h = fs.open("/egpsData/names", "w")
    if not h then return end
    for i = 1, #m_Names do h.writeLine(m_Names[i]) end
    h.close()
    m_DictDirty = false
end

local function loadNames()
    m_Names, m_NameId = {}, {}
    if not fs.exists("/egpsData/names") then return end
    local h = fs.open("/egpsData/names", "r")
    if not h then return end
    while true do
        local l = h.readLine()
        if l == nil then break end
        m_Names[#m_Names + 1] = l
        m_NameId[l] = #m_Names
    end
    h.close()
end

-- WHEN each chunk was last looked at, so staleness is answerable.
--
-- Per-CELL timestamps were what made the old format 330 bytes a cell, and they bought nothing:
-- nothing ever asked "when was this exact block last seen". What the fleet actually needs is
-- "which ground has nobody looked at recently", and that is a property of an area, not a block. One
-- number per chunk answers it for a hundredth of the cost.
local m_Seen = {}       -- chunk key -> epoch ms


function MarkChunkDirty(p_Key)
    local c = chunkOfKey(p_Key)
    if c then
        m_Dirty[c] = true
        m_Seen[c] = os.epoch("utc")
    end
end

--- How long ago (ms) was this area last observed? nil if never. Used to target re-surveys at ground
--- nobody has looked at instead of re-walking what was just covered.
function ChunkAge(p_X, p_Z)
    local c = math.floor(p_X / CHUNK) .. "_" .. math.floor(p_Z / CHUNK)
    if m_Seen[c] == nil then return nil end
    return os.epoch("utc") - m_Seen[c], m_Seen[c]
end

local MAP_MAGIC = "pgps1"

--- Write `p_Rows()` line by line. Streaming, so nothing ever holds the whole file in memory.
-- Directories, made ONCE per boot instead of once per chunk.
--
-- This ran fs.isDir + fs.makeDir on every call, and writeLines is called once per dirty chunk --
-- so a save of two hundred chunks was two hundred directory checks on top of two hundred
-- open/write/close cycles. Filesystem calls cross into Java and are the most expensive thing a CC
-- computer does; CC:T's own thread dump caught the shared worker sitting in
-- WritableFileMount.makeDirectory while it terminated an unrelated computer for running over time.
local m_DirsReady = {}
local function ensureDir(p_Path)
    if m_DirsReady[p_Path] then return end
    if not fs.isDir(p_Path) then fs.makeDir(p_Path) end
    m_DirsReady[p_Path] = true
end

local function writeLines(p_Name, p_Header, p_Rows)
    ensureDir("/egpsData")
    local s_Tmp = "/egpsData/" .. p_Name .. ".new"

    -- Stage, then move. A save that runs out of space part way through leaves a truncated file,
    -- and a truncated map file reads back as a SHORTER map rather than as an error -- which is how
    -- a failed write turns into quiet data loss instead of a loud one.
    local s_File = fs.open(s_Tmp, "w")
    if not s_File then return false, "could not open " .. s_Tmp end

    -- Buffer, then write in blocks. One writeLine per cell is tens of thousands of calls across
    -- the CC/JVM boundary and it made MapServer unresponsive for the whole save -- long enough
    -- that Status stopped answering and the module looked dead. The rows are handed a `line`
    -- function instead of the file handle so callers cannot bypass this.
    local s_Buf, s_Sink = {}, nil
    s_Sink = function(p_Line)
        s_Buf[#s_Buf + 1] = p_Line
        if #s_Buf >= 512 then
            s_File.write(table.concat(s_Buf, "\n") .. "\n")
            s_Buf = {}
            -- Same reason as the read side: a large write must let the module breathe, or CC
            -- terminates it mid-save and leaves a staging file behind. queueEvent rather than
            -- os.sleep(0), which costs a full game tick per 512 lines and does no work in it.
            breathe("save")
        end
    end

    local s_Ok, s_Err = pcall(function()
        s_Sink(MAP_MAGIC)
        for _, line in ipairs(p_Header or {}) do s_Sink(line) end
        s_Sink("=")
        p_Rows(s_Sink)
        if #s_Buf > 0 then s_File.write(table.concat(s_Buf, "\n") .. "\n") end
    end)
    s_File.close()

    if not s_Ok then
        fs.delete(s_Tmp)
        return false, tostring(s_Err)
    end
    if fs.exists("/egpsData/" .. p_Name) then fs.delete("/egpsData/" .. p_Name) end
    fs.move(s_Tmp, "/egpsData/" .. p_Name)
    return true
end

--- Read a streamed file back. Returns nil if it is not one, so the caller can try the old format.
local function readLines(p_Name)
    local s_Path = "/egpsData/" .. p_Name
    if not fs.exists(s_Path) then return nil end
    local s_File = fs.open(s_Path, "r")
    if not s_File then return nil end
    if s_File.readLine() ~= MAP_MAGIC then s_File.close() return nil end
    return s_File
end

----------------------------------------
-- load
--
-- function: load cachedWorld from a file
-- return: boolean "success"
--

function load()
    cachedWorld, cachedWorldDetail = {}, {}
    local s_Cells = 0

    -- Report what the load actually SEES. It returned an empty map in-world while parsing 229,895
    -- rows correctly off-world, and print() goes to a terminal nobody reads -- so there was no way
    -- to tell whether the directory was missing, the listing was empty, or the parse was failing.
    local function say(m) if _G.Log then _G.Log(m) else print(m) end end

    say("load: isDir(" .. CHUNK_DIR .. ")=" .. tostring(fs.isDir(CHUNK_DIR)))
    if fs.isDir(CHUNK_DIR) then
        loadNames()
        say("load: " .. #fs.list(CHUNK_DIR) .. " entries, " .. #m_Names .. " names")
        -- Counted ACROSS files, not within one.
        --
        -- This was declared inside the per-file loop, so it reset on every chunk -- and with 70
        -- chunks averaging ~3,000 rows, most files finished before the counter ever reached its
        -- threshold. The net effect was almost no yielding across a 227,000-row load, and CC hard
        -- kills a computer that runs ten seconds without yielding. That abort is NOT catchable by
        -- pcall, which is why the bootloader never recorded a reason: MapServer simply vanished and
        -- restarted, 104 times, with the map frozen throughout.
        -- READ EACH FILE WHOLE, PARSE IN LUA.
        --
        -- readLine() is one call across the CC/JVM boundary per line, and this load is 227,000
        -- lines: even with the crash loop fixed, MapServer spent minutes inside it and answered
        -- nothing the whole time. readAll plus gmatch is a single boundary crossing per FILE, and
        -- the parsing happens in Lua where it is cheap. Same lesson as the buffered writes.
        for _, name in ipairs(fs.list(CHUNK_DIR)) do
          if not name:match("%.new$") then
            local h = fs.open(CHUNK_DIR .. "/" .. name, "r")
            if h then
                local s_Body = h.readAll() or ""
                h.close()
                if s_Body:sub(1, #MAP_MAGIC) == MAP_MAGIC then
                    -- Header runs to the "=" terminator; the rest is rows.
                    local s_Split = s_Body:find("\n=\n", 1, true)
                    local s_Head = s_Split and s_Body:sub(1, s_Split) or ""
                    local s_Rows = s_Split and s_Body:sub(s_Split + 3) or ""

                    local t = s_Head:match("seen=(%d+)")
                    if t then m_Seen[name] = tonumber(t) end

                    -- Yield inside the ROW loop, not just once per file.
                    --
                    -- Yielding per file looked sufficient -- 72 files, 72 yields -- but a single
                    -- chunk holds a few thousand rows and the whole load is 230,000 table writes.
                    -- CC aborts any coroutine that runs ten seconds without yielding, and that
                    -- abort surfaces wherever execution happens to be: MapServer died at 19.9s
                    -- with "peripheral.lua:259: Too long without yielding", which reads like a
                    -- monitor fault and is actually the map loader starving the scheduler.
                    local s_Row = 0
                    for k, occ, nid in s_Rows:gmatch("([^\n=]+)=([^,\n]+),(%d+)") do
                        s_Row = s_Row + 1
                        if s_Row % 500 == 0 then breathe("walk") end
                        cachedWorld[k] = tonumber(occ)
                        local id = tonumber(nid)
                        if id and id > 0 and m_Names[id] then
                            cachedWorldDetail[k] = {data = {tonumber(occ) == 1, {name = m_Names[id]}}}
                        end
                        s_Cells = s_Cells + 1
                    end
                end
            end
            -- One yield per file rather than per row: 70 yields instead of 455, and the work
            -- between them is now bounded by one file rather than unbounded. queueEvent rather
            -- than os.sleep(0) -- 70 ticks of waiting was three and a half seconds of the boot.
            breathe("load")
          end
        end
        say("load: parsed " .. s_Cells .. " cells")
        print("loaded " .. s_Cells .. " cells from " .. #fs.list(CHUNK_DIR) .. " chunks")
        return true
    end

    -- MIGRATION. Read whichever older format is on disk and mark everything dirty, so the next
    -- save writes it out as chunks. Silently starting empty here would throw away the entire map.
    local s_File = readLines("blockData")
    if s_File then
        while true do
            local l = s_File.readLine()
            if l == nil then break end
            local k, v = l:match("^(.-)=(.+)$")
            if k then cachedWorld[k] = tonumber(v) MarkChunkDirty(k) s_Cells = s_Cells + 1 end
        end
        s_File.close()
        print("migrating " .. s_Cells .. " cells to chunk storage")
        return true
    end

    local data = getFile("blockData")
    if data ~= "" then
        local t = textutils.unserialize(data)
        if t ~= nil then
            for k, v in pairs(t) do cachedWorld[k] = v MarkChunkDirty(k) s_Cells = s_Cells + 1 end
            print("migrating " .. s_Cells .. " cells from the legacy format")
            return true
        end
    end
    print("no world data")
    return false
end

----------------------------------------
-- save
--
-- function: save cachedWorld to a file
-- return: boolean "success"
--

function save()
    -- Only the chunks that changed. This is the entire point of the chunk layout: a save used to be
    -- the whole map and is now a handful of kilobytes.
    if next(m_Dirty) == nil then return true end
    if not fs.isDir(CHUNK_DIR) then fs.makeDir(CHUNK_DIR) end

    -- Group the dirty cells by chunk in one pass. Walking the whole map once per dirty chunk would
    -- reintroduce exactly the cost this change exists to remove.
    local s_Buckets = {}
    local s_Seen2 = 0
    for k in pairs(cachedWorld) do
        s_Seen2 = s_Seen2 + 1
        if s_Seen2 % 5000 == 0 then breathe("walk") end
        local c = chunkOfKey(k)
        if c and m_Dirty[c] then
            local b = s_Buckets[c]
            if b == nil then b = {} s_Buckets[c] = b end
            b[#b + 1] = k
        end
    end

    -- A SAVE MUST NOT BE ABLE TO HOG THE COMPUTER THREAD, HOWEVER MUCH IS DIRTY.
    --
    -- Yielding once per chunk keeps THIS computer inside its own time budget, but CC:T runs every
    -- computer in the world on a shared worker pool -- so an unbounded run of open/write/close
    -- starves the others even while yielding politely. When the monitor then finds a computer over
    -- budget it terminates it AND interrupts the shared worker, and any computer that happens to be
    -- starting on that worker dies with `InterruptedException at ComputerExecutor.turnOn`. It then
    -- cannot be started again: `computercraft turn-on 12` answers "Turned on 1/1" while the block
    -- stays On:0b for ever.
    --
    -- That is not a hypothetical either. The server log has all three steps in sequence:
    --   Terminating computer #10 due to timeout (ran over by 3.008 seconds)
    --     Thread ComputerCraft-Computer-Worker-0 ... at WritableFileMount.makeDirectory
    --   Error running task on computer #12: java.lang.InterruptedException at ...turnOn
    -- MainFrame died, TaskMan became unstartable, and with MainFrame gone every remaining module sat
    -- in WaitForService("MAINFRAME") -- the whole settlement dark, from one oversized save.
    --
    -- So bound the pass. Whatever is left stays in m_Dirty and is written by the next one; the map
    -- is a cache of observations that are re-uploaded constantly, so a chunk reaching disk a minute
    -- later costs nothing, and taking the fleet's scheduler down costs everything.
    local CHUNKS_PER_SAVE = 24

    local s_Failed, s_Wrote = nil, 0
    for c, keys in pairs(s_Buckets) do
        if s_Wrote >= CHUNKS_PER_SAVE then break end
        s_Wrote = s_Wrote + 1
        -- YIELD ONCE PER CHUNK, NOT ONLY EVERY 512 LINES.
        --
        -- The sink inside writeLines yields every 512 buffered lines, which covers a big chunk and
        -- does NOTHING for a small one: a chunk holding two hundred cells never reaches the
        -- threshold, so it is written start to finish without a single yield. A save touching many
        -- small dirty chunks is therefore a long run of fs.open / write / close with no yield
        -- anywhere in it, and CC:T terminates a coroutine that goes ~10s without one.
        --
        -- That is not theoretical. MapServer died exactly here:
        --
        --   last-run.txt: module=MapServer ok=false
        --   err=/PowGPSServer:372: Too long without yielding
        --
        -- line 372 being `fs.open` -- CC blames wherever execution happened to be, which is why it
        -- reads like a file error rather than a scheduling one. The module then stayed POWERED OFF,
        -- and `hive.nodes` still reported 7/7 up because its probe does not reach the module. With
        -- MapServer gone the fleet lost pathfinding: drones logged "pathfinder did not answer",
        -- could not reach storage four blocks away, could not deposit, could not refuel, and the
        -- whole settlement wound down. Every symptom chased for hours traced back to this yield.
        --
        -- queueEvent/pullEvent, not os.sleep(0): it satisfies the watchdog and resumes in the SAME
        -- tick, so a save of hundreds of chunks costs no wall clock. The same pair is used for this
        -- reason everywhere this codebase walks a large structure.
        breathe("mapsave")
        -- Header carries WHEN this ground was last observed, so staleness is readable straight off
        -- the file without decoding a single cell.
        local s_Header = {"seen=" .. tostring(m_Seen[c] or 0)}
        local ok, err = writeLines("chunks/" .. c, s_Header, function(line)
            for _, k in ipairs(keys) do
                local d = cachedWorldDetail[k]
                local n = type(d) == "table" and type(d.data) == "table"
                          and type(d.data[2]) == "table" and d.data[2].name
                line(k .. "=" .. tostring(cachedWorld[k]) .. "," .. nameId(n or nil))
            end
        end)
        if ok then m_Dirty[c] = nil else s_Failed = err end
    end

    -- The dictionary must reach disk BEFORE anything that references it is trusted on reload --
    -- a chunk row pointing at an id the dictionary does not have is an unreadable block name.
    saveNames()

    if s_Failed then print("map save failed: " .. tostring(s_Failed)) end
    return s_Failed == nil
end

----------------------------------------
-- loadDetail
--
-- function: load cachedWorlddetail from a file
-- return: boolean "success"
--

function loadDetail()
    -- Detail is stored inside the chunk files alongside occupancy, so load() has already populated
    -- it. This only has to migrate an older standalone detail file, once.
    if fs.isDir(CHUNK_DIR) then return true end

    local s_File = readLines("blockDataDetail")
    if s_File then
        local s_Names = {}
        while true do
            local l = s_File.readLine()
            if l == nil or l == "=" then break end
            s_Names[#s_Names + 1] = l
        end
        local n = 0
        while true do
            local l = s_File.readLine()
            if l == nil then break end
            local k, solid, nid = l:match("^(.-)=(%-?[%d.]+),(%d+)$")
            if k then
                local id = tonumber(nid)
                local e = {data = {solid == "1"}}
                if id and id > 0 and s_Names[id] then e.data[2] = {name = s_Names[id]} end
                cachedWorldDetail[k] = e
                MarkChunkDirty(k)
                n = n + 1
            end
        end
        s_File.close()
        print("migrating " .. n .. " named blocks to chunk storage")
        return true
    end

    local data = getFile("blockDataDetail")
    if data ~= "" then
        local t = textutils.unserialize(data)
        if t ~= nil then
            for k, v in pairs(t) do cachedWorldDetail[k] = v MarkChunkDirty(k) end
            print("migrating named blocks from the legacy format")
            return true
        end
    end
    return false
end

----------------------------------------
-- saveDetail
--
-- function: save cachedWorldDetail to a file
-- return: boolean "success"
--

function saveDetail()
    -- Folded into save(): a chunk file carries occupancy and names together, so writing them
    -- separately would write every chunk twice and halve the benefit of chunking at all.
    return true
end


----------------------------------------
-- empty
--
-- funtion: test if the cachedWorld is empty
-- return: boolean cachedWorld is empty
--

function empty(table)
    table = table or cachedWorld
    for _, value in pairs(table) do
        if value ~= nil then
            return false
        end
    end
    return true
end


----------------------------------------
-- delCache
--
-- function: remove ALL data from cache
-- input: boolean are you sure?
-- return: boolean "success"
--

function delCache(sure)
    if sure then
        cachedX, cachedY, cachedZ, cachedDir = nil, nil, nil, nil
        cachedWorld, waypoints, exclusions = {}, {}, {}
        print("all data deleted from cache")
        return true
    else
        return false
    end
end


----------------------------------------
-- loadWaypoints
--
-- function: load waypoints from the file
-- return: boolean "success"
--

function loadWaypoints()
    local data = getFile("waypoints")
    if data ~= {} then
        waypoints = textutils.unserialize(data)
        if waypoints ~= nil then
            return true
        else
            -- print("could not read waypoints file: \n"..data)
            waypoints = {}
            return false
        end
    else
        print("no waypoint data")
        return false
    end
end

----------------------------------------
-- saveWaypoints
--
-- function: save waypoints to a file
-- return: boolean "success"
--

function saveWaypoints()
    setFile("waypoints", waypoints)
end

----------------------------------------
-- setWaypoint
--
-- function: save a waypoint to cache
-- input: name of waypoint, coordinates
-- returns: boolean "success"
--

function setWaypoint(name, x, y, z, d)
    d = d or 0
    x = x or nil
    y = y or nil
    z = z or nil
    if x == nil and y == nil and z == nil then
        waypoints[name] = nil
        print("waypoint deleted")
        return true
    end
    waypoints[name] = {x, y, z, d}
    if waypoints[name] ~= nil then
        return true
    else
        return false
    end
end

----------------------------------------
-- getWaypoint
--
-- function: get a waypoint from cache
-- input: name of waypoint
-- returns: waypoint coordinates and direction
-- returns: false if its not found
--

function getWaypoint(name)
    local x, y, z, d
    if waypoints[name] ~= nil then
        x = waypoints[name][1]
        y = waypoints[name][2]
        z = waypoints[name][3]
        d = waypoints[name][4]
        return x, y, z, d
    else
        print("waypoint "..name.." not found")
        return nil, nil, nil, nil
    end
end

----------------------------------------
-- loadExclusions
--
-- function: load exclusions from the file
-- return: boolean "success"
--

function loadExclusions()
    local data = getFile("exclusions")
    if data ~= {} then
        exclusions = textutils.unserialize(data)
        if exclusions ~= nil then
            return true
        else
            print("could not read exclusions file: \n"..data)
            exclusions = {}
            return false
        end
    else
        print("no exclusion data")
        return false
    end
end

----------------------------------------
-- saveExclusions
--
-- function: save exclusions to a file
-- return: boolean "success"
--

function saveExclusions()
    setFile("exclusions", exclusions)
end

----------------------------------------
-- setDronePos
--
-- function: save an drone Pos to cache
-- input: exclusions coordinates
-- returns: boolean "success"
--

-- ACCEPT EITHER "x:y:z" OR x, y, z, AND HAND BACK BOTH.
--
-- Every cell accessor here takes both shapes, and each one carried its own copy of this -- four of
-- them, each having to get the same three patterns right. They address the SHARED world cache, so a
-- key rebuilt from the wrong pieces does not error, it silently reads or writes a different cell.
-- Returns the canonical key first, because that is what the callers index with.
local function coordsOrKey(idx, y, z)
    local x
    if y == nil and z == nil then
        x = tonumber(string.match(idx, "(.*):"))
        y = tonumber(string.match(idx, ":(.*):"))
        z = tonumber(string.match(idx, ":(.*)"))
    else
        x = idx
        idx = x..":"..y..":"..z
    end
    return idx, x, y, z
end

function SetDronePos(idx, y, z)
    idx = coordsOrKey(idx, y, z)
    if cachedWorld[idx] == nil then noteWorldKey(idx) end
    cachedWorld[idx] = 2
    return true
end

----------------------------------------
-- setExclusion
--
-- function: save an exclusion to cache
-- input: exclusions coordinates
-- returns: boolean "success"
--

function setExclusion(idx, y, z)
    local x
    idx, x, y, z = coordsOrKey(idx, y, z)
    exclusions[idx] = {x, y, z}
    if exclusions[idx] ~= nil then
        return true
    else
        return false
    end
end

----------------------------------------
-- excludeZone
--
-- function: exclude a cuboid
-- input: 2 opposite corners (x, y, z, x2, y2, z2)
-- option: boolean to include the zone
--

function excludeZone(x, y, z, x2, y2, z2, include)
    local temp, temp2
    temp, temp2 = x, x2
    x = math.min(temp, temp2)
    x2 = math.max(temp, temp2)
    temp, temp2 = y, y2
    y = math.min(temp, temp2)
    y2 = math.max(temp, temp2)
    temp, temp2 = z, z2
    z = math.min(temp, temp2)
    z2 = math.max(temp, temp2)

    for i = x, x2 do
        for j = y, y2 do
            for k = z, z2 do
                if include then
                    delExclusion(i, j, k)
                else
                    setExclusion(i, j, k)
                end
            end
        end
    end
end

----------------------------------------
-- getExclusion
--
-- function: get an exclusion from cache
-- input: index of exclusion: "x:y:z"
-- returns: exclusion coordinates (or nil, nil, nil)
--

function getExclusion(idx, y, z)
    local x
    idx, x, y, z = coordsOrKey(idx, y, z)
    if exclusions[idx] ~= nil then
        x = exclusions[idx][1]
        y = exclusions[idx][2]
        z = exclusions[idx][3]
        return x, y, z
    else
        print("exclusion "..idx.." not found")
        return nil, nil, nil
    end
end

----------------------------------------
-- delExclusion
--
-- function: remove an exclusion from cache
-- input: index of exclusion: "x:y:z" OR x, y, z
-- returns: boolean "success"
--

function delExclusion(idx, y, z)
    idx = coordsOrKey(idx, y, z)
    exclusions[idx] = nil
    print("exclusion deleted")
    return true
end

----------------------------------------
-- heuristic_cost_estimate
--
-- function: A* heuristic
-- input: X, Y, Z of the 2 points
-- return: Manhattan distance between the 2 points
--

local function heuristic_cost_estimate(x1, y1, z1, x2, y2, z2)
    return math.abs(x2 - x1) + math.abs(y2 - y1) + math.abs(z2 - z1)
end

----------------------------------------
-- reconstruct_path
--
-- function: A* path reconstruction
-- input: A* visited nodes and goal
-- return: List of movement to be executed
--

-- Iterative, not recursive. One stack frame per step of the path was survivable while searches
-- were too slow to produce long ones; now that they are not, a few hundred frames on a CC
-- computer is a stack overflow at exactly the moment the pathfinder finally succeeds.
local function reconstruct_path(_cameFrom, _currentNode)
    local s_Rev, s_At = {}, _currentNode
    while _cameFrom[s_At] ~= nil do
        local dir, prev = _cameFrom[s_At][1], _cameFrom[s_At][2]
        s_Rev[#s_Rev + 1] = dir
        s_At = prev
    end
    local s_Path = {}
    for i = #s_Rev, 1, -1 do s_Path[#s_Path + 1] = s_Rev[i] end
    return s_Path
end


local function isAged(p_Day, p_Time)
    if(os.day() > p_Day) then
        return true
    end
    if(os.time() > p_Time + 1) then
        print(os.time())
        print(p_Time)

        return true
    end
    return false
end


-- Normalise a cell key to integer block coordinates, or reject it.
--
-- Belt and braces alongside the flooring in pgps: this is the one place every observation from
-- every drone passes through, so a drone running an old copy -- or a future one with a new way of
-- being wrong -- cannot poison the map. A key that will not parse is dropped rather than stored,
-- because an unparseable key is not a cell, it is a cell nobody can ever look up again.
-- NO PATTERN ENGINE HERE EITHER. This is the hottest key parse in the system: it runs once per
-- uploaded CELL, in both merge paths, for every observation every drone sends -- seventeen drones
-- reporting continuously. The anchored float pattern was doing real work per cell to answer a
-- question two plain finds answer for nothing.
--
-- The fast path also skips the rebuild entirely when the key is already integral, which is the
-- overwhelmingly common case: drones send integer cells, and only the rare fractional one (a fix
-- that arrived mid-move) needs flooring and reassembly. That turns most calls into two finds, three
-- tonumbers and a return of the ORIGINAL string -- no allocation at all.
local function cellKey(p_Key)
    if type(p_Key) ~= "string" then return nil end
    local a = string.find(p_Key, ":", 1, true)
    if a == nil then return nil end
    local b = string.find(p_Key, ":", a + 1, true)
    if b == nil then return nil end
    local x = tonumber(string.sub(p_Key, 1, a - 1))
    local y = tonumber(string.sub(p_Key, a + 1, b - 1))
    local z = tonumber(string.sub(p_Key, b + 1))
    if x == nil or y == nil or z == nil then return nil end
    local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
    -- REUSE THE STRING ONLY IF IT IS ALREADY CANONICAL AS TEXT, not merely integral as a number.
    -- "-478.0:64.0:78.0" is integral and would have been returned unchanged, filing that cell under
    -- a second key that no lookup for "-478:64:78" will ever find. This function exists precisely to
    -- stop that, so the fast path has to check the TEXT -- a single plain find for a dot.
    if fx == x and fy == y and fz == z and string.find(p_Key, ".", 1, true) == nil then
        return p_Key
    end
    return fx .. ":" .. fy .. ":" .. fz
end

local function mergeCachedWorldDetail(newData, p_ID)
    local s_Clean = {}
    for k, v in pairs(newData) do
        local s_K = cellKey(k)
        if s_K then s_Clean[s_K] = v MarkChunkDirty(s_K) end
    end
    newData = s_Clean
    for k,v in pairs(newData) do
        if(cachedWorldDetail[k] == nil) then
            cachedWorldDetail[k] = {}
            cachedWorldDetail[k].discoverer = p_ID
            cachedWorldDetail[k].discovered = {day = os.day(), time = os.time()}
        end
        cachedWorldDetail[k].lastUpdated = {day = os.day(), time = os.time()}
        cachedWorldDetail[k].data = v

        -- TWO BUGS ON TWO LINES, AND BETWEEN THEM THE MAP COULD NEVER FORGET ANYTHING.
        --
        --     if(type(v[2]) == table) then                                   -- always FALSE
        --         if(v[2].name == "...Advanced" or "...Turtle") then         -- always TRUE
        --
        -- `table` unquoted is the standard library, so `type(x) == table` compares a string to a
        -- table and is false for every value -- the branch never ran. And `a == "x" or "y"` is
        -- Lua's classic truthy-or: it parses as `(a == "x") or "y"`, so it would have matched
        -- everything if it had ever been reached.
        --
        -- This insert is the ONLY thing that feeds `aged`, and `ClearAged` -- the only code in the
        -- system that removes a map record -- iterates `aged`. So `aged` was permanently empty,
        -- ClearAged permanently cleared nothing, and the world map became append-only: a cell that
        -- once held a block keeps that block for ever, because the scanner reports only NON-AIR
        -- blocks and this merge only ever adds keys.
        --
        -- That is the cause of the settlement's death by fuel. Every tree the fleet fells stays in
        -- the index at full height, so the share of the index that is fiction rises with every
        -- harvest. The lumber picker chooses the densest cluster, which is therefore a grove that
        -- was cut down hours ago -- verified: the chosen site -530,69,55 has three logs recorded
        -- and NONE in the world. Every sweep flew to a ghost, felled nothing, and reported success;
        -- wood income reached zero, the charcoal line starved behind it, and the fleet burned its
        -- reserve to nothing with every job completing normally.
        --
        -- Fixing these two lines restores aging for the case it was written for. It does NOT make
        -- the map forget felled trees -- nothing tracks those -- and that remains the open hole.
        if(type(v[2]) == "table") then
            local n = tostring(v[2].name or "")
            if(n == "ComputerCraft:CC-TurtleAdvanced" or n == "ComputerCraft:CC-Turtle") then
                table.insert(aged, {coords = k, lastUpdated = cachedWorldDetail[k].lastUpdated})
            end
        end
    end
end

-- Bumped whenever the SET of known cells changes. Consumers that build an index over the whole map
-- (MapServer's page-key list) use this to know when their index is stale, instead of rebuilding it
-- every time somebody asks -- which was a full walk of 208,625 cells per map-page refresh and the
-- single most expensive thing the module did.
--
-- Only additions and removals matter. Overwriting a cell's VALUE leaves the key set identical, so
-- it deliberately does not bump: a drone re-reporting known ground must not invalidate anything.
local m_WorldGen = 0
function worldGeneration() return m_WorldGen end
function bumpWorldGeneration() m_WorldGen = m_WorldGen + 1 end

-- THE LIST OF CELL KEYS, MAINTAINED INCREMENTALLY INSTEAD OF REBUILT.
--
-- MapServer needs an ordered key list to page the map to the browser, and it built one by walking
-- every cell. That walk was gated first on the world generation and then, when that proved useless,
-- on a thirty-second timer -- but seventeen drones add cells continuously, so the generation is
-- ALWAYS stale and the timer just meant the walk happened every thirty seconds instead of every
-- refresh. The map has since grown to 324,000 cells, and the walk now takes longer than the gap
-- between walks.
--
-- The result was not a slow map, it was NO PATHFINDING: 181 "pathfinder did not answer" across the
-- fleet in one night, MapServer reported unreachable, and every drone's routing silently degraded
-- to whatever it could manage without a route. The module was not overloaded by the fleet; it was
-- overloaded by its own index.
--
-- Nothing here needs a walk. The only moment the list changes is when a key is FIRST seen, and
-- mergeCachedWorld already tests exactly that to bump the generation. So append there, build once
-- lazily, and the per-refresh cost becomes a table lookup.
--
-- Removals leave holes rather than shuffling a quarter-million-entry array: the pager already skips
-- keys whose cell is gone, and the list is compacted when the holes get expensive.
local m_KeyList  = nil
local m_KeyHoles = 0

function noteWorldKey(p_Key)
    if m_KeyList ~= nil then m_KeyList[#m_KeyList + 1] = p_Key end
end

function forgetWorldKey()
    if m_KeyList ~= nil then m_KeyHoles = m_KeyHoles + 1 end
end

function worldKeyList()
    -- Rebuild only when there has never been a list, or when a quarter of it is holes -- at which
    -- point the pager is walking past more dead keys than live ones and the walk pays for itself.
    if m_KeyList == nil or (m_KeyHoles > 0 and m_KeyHoles * 4 > #m_KeyList) then
        m_KeyList, m_KeyHoles = {}, 0
        local s_Since = 0
        for k in pairs(cachedWorld) do
            m_KeyList[#m_KeyList + 1] = k
            -- Yield periodically: CC kills a coroutine that runs 10s without yielding, uncatchably,
            -- and this is the one place that still touches every cell.
            s_Since = s_Since + 1
            if s_Since >= 2000 then
                s_Since = 0
                breathe("worldKeys")
            end
        end
    end
    return m_KeyList
end

local function mergeCachedWorld(newData)
    for k,v in pairs(newData) do
        local s_K = cellKey(k)
        if s_K then
            if cachedWorld[s_K] == nil then
                m_WorldGen = m_WorldGen + 1
                noteWorldKey(s_K)
            end
            cachedWorld[s_K] = v MarkChunkDirty(s_K)
        end
    end
end

--- Drop every key that is not an integer cell. Used once, to clean out what is already stored.
function PruneBadKeys()
    local s_Dropped = 0
    for _, t in ipairs({cachedWorld, cachedWorldDetail}) do
        local s_Bad = {}
        for k in pairs(t) do
            if cellKey(k) ~= k then s_Bad[#s_Bad + 1] = k end
        end
        for _, k in ipairs(s_Bad) do t[k] = nil s_Dropped = s_Dropped + 1 end
    end
    return s_Dropped
end

function UpdateCachedWorld(newData, p_ID)
    mergeCachedWorld(newData, p_ID)
end
function UpdateCachedWorldDetail(newData, p_ID)
    mergeCachedWorldDetail(newData, p_ID)
end

-- CachedWorldDetail is our primary resource for the actual state of the world.
-- CachedWorld is the stuff we use for pathfinding.
function ClearAged()
    local s_Aged = {}
    for k,v in pairs(aged) do
        print(k)
        if(isAged(v.lastUpdated.day, v.lastUpdated.time)) then
            print("cleared as too old")
            cachedWorld[k] = nil
            forgetWorldKey()
            table.insert(s_Aged, k)
        end
    end

    for k,v in pairs(s_Aged) do
        aged[k] = nil
    end
end

----------------------------------------
-- a_star
--
-- function: A* path finding
-- input: start and goal coordinates
-- return: List of movement to be executed
--


-- PRIORITY QUEUE, not a linear scan.
--
-- The old search did two full passes over the open set on EVERY iteration -- one to find the
-- lowest f, one in empty() to ask whether anything was left -- which makes the whole search
-- O(n^2) in the size of the frontier. Over open or unmapped ground that frontier grows in three
-- dimensions, so a route of a couple of hundred blocks did not merely take a while: it never
-- finished, and CC:T eventually killed it for not yielding. The caller saw "no path" and concluded
-- the route did not exist.
--
-- A binary heap makes each pop O(log n). Stale entries are skipped on pop rather than removed
-- (lazy deletion), which is cheaper than finding and repairing them on every improvement.
local function heapPush(h, f, idx, node)
    local i = #h + 1
    h[i] = {f = f, idx = idx, node = node}
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].f <= h[i].f then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end

local function heapPop(h)
    local n = #h
    if n == 0 then return nil end
    local top = h[1]
    h[1] = h[n]
    h[n] = nil
    n = n - 1
    local i = 1
    while true do
        local l, r, m = i * 2, i * 2 + 1, i
        if l <= n and h[l].f < h[m].f then m = l end
        if r <= n and h[r].f < h[m].f then m = r end
        if m == i then break end
        h[i], h[m] = h[m], h[i]
        i = m
    end
    return top
end

-- Weighted A*: f = g + W*h.
--
-- W above 1 trades a guarantee of the shortest path for a large reduction in nodes expanded. That
-- is the right trade here: a turtle walking three blocks further costs three fuel, while a search
-- that does not return costs the drone entirely. Kept modest so paths stay sensible.
local ASTAR_WEIGHT = 1.35
-- WHAT A DUG CELL COSTS. Until 2026-09-04 nothing: a cell the drone would have to cut through
-- scored the same single step as open air, so with digging allowed the shortest route to anything
-- behind a wall or under a floor was straight through it -- and TravelTo asked for a digging plan
-- FIRST on every hop under 32 blocks. Floor 0 of the tower ended up "swiss cheese" (the user's
-- words). A tunnel cell now costs as much as a detour of this many open cells, so the planner
-- walks around through any opening within that trade and digs only where nothing else reaches.
local DIG_STEP_COST = 12
-- What one step into a known cell costs, by what the map says is there: open air 1, a cell a drone
-- walked lately (2) is free, rock that must be cut pays the tunnel price. Unknown cells cost
-- `discover`, set per request.
local STEP_COST = {[0] = 1, [1] = 1 + DIG_STEP_COST, [2] = 0, [3] = 1}

-- How far outside the start/goal box the search may wander. Without this an unreachable goal makes
-- the frontier expand in every direction until the node limit, which is slow AND useless -- if the
-- way through is not roughly between the two ends, it is not a path worth walking.
local ASTAR_MARGIN = 24
-- 6,000, NOT 20,000, AND 2,500 WHEN DIGGING. A failed search costs its whole budget: at 20,000 nodes
-- that was 500-600 ms of a computer the entire fleet shares, and once the dig flag reached the
-- planner (every solid cell passable) requests through rock hit it every time -- 28 requests a minute
-- of which 14 "gave up after N nodes", uploads refused, HQ's own FindBlocks "no response" (2026-09-04
-- 03:10). Through rock the straight line is nearly always the answer, so the digging search is
-- small and greedy; a normal search that needs more than 6,000 nodes in a 24-block margin box is a
-- route that does not exist.
local ASTAR_MAX_NODES = 6000
local ASTAR_MAX_NODES_DIG = 5000
local ASTAR_WEIGHT_DIG = 2.0

-- WHERE THE OTHER DRONES ARE, RIGHT NOW.
--
-- The pathfinder knew the terrain and nothing about the fleet, so it happily routed one drone
-- straight through another -- which is not a wall, so nothing was ever recorded, so it planned the
-- identical route again on the next attempt. That is the make-way dance: two drones facing each
-- other, each following a path that says the other is not there. Recording drones as TERRAIN was
-- tried and was worse (190 phantom blocks that outlived the drones and were routed around for ever).
--
-- The distinction that makes it work is TIME. A drone's position is true for seconds, not for ever,
-- so it is held separately from the map with a timestamp and expires on its own. Planning around it
-- is what the coordination was supposed to buy.
local m_DroneAt = {}
local DRONE_STALE = 15          -- seconds after which a reported position means nothing

function noteDroneAt(p_Id, x, y, z)
    if p_Id == nil or x == nil then return end
    m_DroneAt[tostring(p_Id)] = {key = x..":"..y..":"..z, at = os.clock()}
end

-- The set of cells currently occupied by drones OTHER than the one asking.
local function occupiedByOthers(p_Asker)
    local out, now = {}, os.clock()
    for id, rec in pairs(m_DroneAt) do
        if id ~= tostring(p_Asker) and (now - rec.at) <= DRONE_STALE then
            out[rec.key] = true
        end
    end
    return out
end

-- Is this cell one a DIGGING drone may route through?
--
-- Solid is not the same as impassable. Stone is solid and cutting it is the job; a chest is solid
-- and breaking it is forbidden. digTo used to be a separate greedy axis-walker that consulted no map
-- at all, so it walked into the same protected blocks for ever no matter how many times the fleet
-- recorded them. Making it a PASSABILITY MODE of the one pathfinder is the whole fix: one map, one
-- search, and "we are not allowed through there" is a fact the router already has.
-- Heuristic weight and node budget for a search: small and greedy through rock, wider in the open.
local function searchLimits(p_Dig)
    if p_Dig then return ASTAR_WEIGHT_DIG, ASTAR_MAX_NODES_DIG end
    return ASTAR_WEIGHT, ASTAR_MAX_NODES
end
-- A digging drone may be sent INTO rock: the cell above an ore is dirt, and that is the point.
local function goalOpen(p_Cell, p_Dig)
    return p_Dig or p_Cell == nil or p_Cell == 0 or p_Cell == 2
end
function a_star(x1, y1, z1, x2, y2, z2, discover, priority, asker, dig)
    discover = discover or 1
    local s_Busy = occupiedByOthers(asker)
    local idx_start = x1..":"..y1..":"..z1
    local idx_goal  = x2..":"..y2..":"..z2
    priority = priority or false

    if exclusions == nil then
        loadExclusions()
    end
    if exclusions[idx_goal] ~= nil and not priority then
        return false, "goal is in an exclusion zone"
    end

    -- Goal must be somewhere a turtle can BE: air, unknown, or occupied by another turtle.
    local s_GoalCell = cachedWorld[idx_goal]
    if not goalOpen(s_GoalCell, dig) then
        return false, "goal is solid"
    end

    local s_MinX, s_MaxX = math.min(x1, x2) - ASTAR_MARGIN, math.max(x1, x2) + ASTAR_MARGIN
    local s_MinY, s_MaxY = math.min(y1, y2) - ASTAR_MARGIN, math.max(y1, y2) + ASTAR_MARGIN
    local s_MinZ, s_MaxZ = math.min(z1, z2) - ASTAR_MARGIN, math.max(z1, z2) + ASTAR_MARGIN

    local closedset, cameFrom, g_score = {}, {}, {}
    local heap = {}
    local s_Nodes = 0
    local s_W, s_MaxNodes = searchLimits(dig)

    g_score[idx_start] = 0
    heapPush(heap, s_W * heuristic_cost_estimate(x1, y1, z1, x2, y2, z2), idx_start, {x1, y1, z1})

    while #heap > 0 do
        s_Nodes = s_Nodes + 1
        -- Yield periodically. CC:T terminates a coroutine that runs too long without one, so an
        -- unyielding search is not slow -- it is killed, and the caller gets no answer at all.
        --
        -- BUT NOT WITH os.sleep(0). THAT IS NOT A FREE YIELD, IT IS A TICK.
        --
        -- os.sleep(0) is startTimer(0) plus a pullEvent, and a zero-delay timer does not fire until
        -- the NEXT GAME TICK -- fifty milliseconds. Every 200 nodes, so a search that spends its
        -- full 20,000-node budget costs a hundred sleeps: five seconds of wall clock, almost all of
        -- it waiting rather than searching. MapServer answers one drone at a time, so with
        -- seventeen drones asking that is a queue nobody reaches the front of, and the fleet logged
        -- 54 "pathfinder did not answer" in two minutes while MapServer sat there idle-waiting.
        --
        -- queueEvent/pullEvent yields to the scheduler and resumes in the SAME tick, because the
        -- event is already in the queue when we ask for it. The watchdog is satisfied -- it wants a
        -- yield, not a delay -- and the search runs at the speed of the search. The same pair is
        -- used for exactly this reason wherever this codebase walks a large structure.
        if s_Nodes % 200 == 0 then
            breathe("astar")
        end
        if s_Nodes > s_MaxNodes then
            return false, ("gave up after %d nodes"):format(s_Nodes)
        end

        local top = heapPop(heap)
        local idx_current, current = top.idx, top.node
        if idx_current == idx_goal then
            return reconstruct_path(cameFrom, idx_goal)
        end
        if not closedset[idx_current] then
            closedset[idx_current] = true

            local x3, y3, z3 = current[1], current[2], current[3]
            for dir = 0, 5 do
                local D = deltas[dir]
                local x4, y4, z4 = x3 + D[1], y3 + D[2], z3 + D[3]
                if x4 >= s_MinX and x4 <= s_MaxX and y4 >= s_MinY and y4 <= s_MaxY
                   and z4 >= s_MinZ and z4 <= s_MaxZ then
                    local idx_neighbor = x4..":"..y4..":"..z4
                    local s_Cell = cachedWorld[idx_neighbor]
                    -- Free, unknown, or the goal itself. Unknown is PASSABLE and merely priced at
                    -- `discover` -- exploring is allowed, it is just not free.
                    -- ...and not through a drone that is standing there. Skipped for the goal
                    -- itself: "go to where that drone is" is a legitimate order (a handover, a
                    -- rescue), and by the time we arrive it has usually moved.
                    -- In dig mode a solid cell is passable if we are allowed to break what is in
                    -- it. Everything else is unchanged, so a non-digging drone still routes only
                    -- through air and no caller has to know which mode it is in.
                    -- THE MAP CARRIES THE MEANING, SO NOTHING HERE NEEDS A LIST OF BLOCK NAMES.
                    --
                    -- 0 air, 1 solid, 2 a turtle, 3 solid AND FORBIDDEN -- something the fleet is not
                    -- allowed to break. The drone is the only thing that knows which blocks are
                    -- protected and it already refuses them; recording that refusal as its own value
                    -- means the router simply reads it. The alternative was a third copy of the
                    -- protected-names list living on the server, out of step with the other two the
                    -- moment anybody edited one.
                    --
                    -- So: air is passable to everyone, ordinary solid is passable to a digger, and
                    -- forbidden is passable to nobody, ever.
                    local s_Passable = ((s_Cell or 0) == 0) or idx_neighbor == idx_goal
                    if not s_Passable and dig and s_Cell == 1 then s_Passable = true end
                    if s_Cell == 3 then s_Passable = false end
                    if (exclusions[idx_neighbor] == nil or priority)
                       and s_Passable
                       and (s_Busy[idx_neighbor] == nil or idx_neighbor == idx_goal)
                       and not closedset[idx_neighbor] then
                        local s_Step = (s_Cell == nil) and discover or STEP_COST[s_Cell]
                        local tentative = g_score[idx_current] + s_Step
                        if g_score[idx_neighbor] == nil or tentative < g_score[idx_neighbor] then
                            cameFrom[idx_neighbor] = {dir, idx_current}
                            g_score[idx_neighbor] = tentative
                            heapPush(heap, tentative +
                                s_W * heuristic_cost_estimate(x4, y4, z4, x2, y2, z2),
                                idx_neighbor, {x4, y4, z4})
                        end
                    end
                end
            end
        end
    end

    return false, ("no path after %d nodes"):format(s_Nodes)
end

----------------------------------------


------------------------------------------
-- progressBar
--
-- function: write a progress bar at cursor position (12 characters)
-- input: %
--

function progressBar(percent)
    term.write("[")
    for i=1, 10 do
        if math.floor(percent/10) >= i then
            term.write("|")
        elseif math.ceil(percent/10) == i then
            term.write(":")
        else
            term.write(" ")
        end
    end
    term.write("]")
end

------------------------------------------
-- explore v2.0
--
-- function: map out an area
-- inputs:
-- int _range: size of the cuboid to check (radius excluding center)
-- bool limitY: if true, height of cuboid is 3
-- bool drawMap: if true, draws a map as it goes along so you can see progress
--

function explore(_range, limitY, drawAMap)--TODO: flag to explore previously explored blocks
    local ox, oy, oz, od = locate()
    local x, y, z, d = 0, 0, 0, 0
    --local i = 0
    --local total = 0
    local toCheck = {}
    local count = 0
    local maxCount
    local idx
    local dist
    local skip
    local yVal = _range
    drawMap = drawMap or false
    limitY = limitY or false

    if limitY then
        yVal = 1
    end

    for dx = -_range, _range do
        for dy = -yVal, yVal do
            for dz = -_range, _range do
                idx = ox+dx..":"..oy+dy..":"..oz+dz
                toCheck[idx] = {ox+dx, oy+dy, oz+dz}--set up the toCheck table
                count = count + 1
            end
        end
    end

    maxCount = count
    while count > 1 do--go through all entries in table
        x, y, z, d = locate()
        term.clear()
        term.setCursorPos(1, 1)
        if drawAMap then
            drawMap(ox, oy, oz)
            drawTurtleOnMap(ox, oy, oz, x, y, z, d)
            term.setCursorPos(1, 1)
        end
        progressBar(100*(maxCount - count)/(maxCount))
        dist = 500
        skip = false

        for k, v in pairs(toCheck) do--find closest block to check
            if v[1] == x and v[2] == y and v[3] == z then--if on the block then remove from list
                toCheck[k] = nil
                skip = true--and run again
                count = count - 1
                maxCount = maxCount - 1
                break
            elseif (math.abs(x - v[1]) + math.abs(y - v[2]) + math.abs(z - v[3])) < dist then
                dist = math.abs(x - v[1]) + math.abs(y - v[2]) + math.abs(z - v[3])--TODO: pathfind to the location and use number of instructions instead of huristic distance
                idx = k
                if dist == 1 then
                    break
                end
            end
        end

        if not skip then
            count = count - 1
            moveTo(toCheck[idx][1], toCheck[idx][2], toCheck[idx][3], d, false, nilCost)--still not sure about nilcost
            toCheck[idx] = nil
        end
        sleep(0)--yield... remove this if possible
    end


    term.clear()
    term.setCursorPos(1, 1)
    progressBar(100)
    -- Go back to the starting point
    print(string.format("\nreturning..."))
    moveTo(ox, oy, oz, od, false, nilCost)
end

