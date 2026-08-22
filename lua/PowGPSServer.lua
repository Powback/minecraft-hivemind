

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
    resx, resy = term.getSize()
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

local MAP_MAGIC = "pgps1"

--- Write `p_Rows()` line by line. Streaming, so nothing ever holds the whole file in memory.
local function writeLines(p_Name, p_Header, p_Rows)
    if not fs.isDir("/egpsData") then fs.makeDir("/egpsData") end
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
    local s_File = readLines("blockData")
    if s_File then
        cachedWorld = {}
        local s_Count = 0
        while true do
            local s_Line = s_File.readLine()
            if s_Line == nil then break end
            local s_Key, s_Val = s_Line:match("^(.-)=(.+)$")
            if s_Key then
                cachedWorld[s_Key] = tonumber(s_Val)
                s_Count = s_Count + 1
            end
        end
        s_File.close()
        print("loaded " .. s_Count .. " cells")
        return true
    end

    -- Fall back to the pretty-printed format so an existing map is not thrown away on upgrade.
    local data = getFile("blockData")
    if data ~= "" then
        cachedWorld = textutils.unserialize(data)
        if cachedWorld ~= nil then
            return true
        else
            -- print("could not read blockData file: \n"..data)
            cachedWorld = {}
            return false
        end
    else
        print("no world data")
        return false
    end
end

----------------------------------------
-- save
--
-- function: save cachedWorld to a file
-- return: boolean "success"
--

function save()
    local ok, err = writeLines("blockData", nil, function(line)
        for k, v in pairs(cachedWorld) do
            line(k .. "=" .. tostring(v))
        end
    end)
    if not ok then print("map save failed: " .. tostring(err)) end
    return ok
end

----------------------------------------
-- loadDetail
--
-- function: load cachedWorlddetail from a file
-- return: boolean "success"
--

function loadDetail()
    local s_File = readLines("blockDataDetail")
    if s_File then
        cachedWorldDetail = {}
        -- Header first: one block name per line until the "=" terminator, indexed by line order.
        local s_Names = {}
        while true do
            local s_Line = s_File.readLine()
            if s_Line == nil or s_Line == "=" then break end
            s_Names[#s_Names + 1] = s_Line
        end
        local s_Count = 0
        while true do
            local s_Line = s_File.readLine()
            if s_Line == nil then break end
            local s_Key, s_Solid, s_Name = s_Line:match("^(.-)=(%-?[%d.]+),(%d+)$")
            if s_Key then
                local s_Entry = {data = {s_Solid == "1"}}
                local s_Id = tonumber(s_Name)
                if s_Id and s_Id > 0 and s_Names[s_Id] then
                    s_Entry.data[2] = {name = s_Names[s_Id]}
                end
                cachedWorldDetail[s_Key] = s_Entry
                s_Count = s_Count + 1
            end
        end
        s_File.close()
        print("loaded " .. s_Count .. " named blocks")
        return true
    end

    -- Fall back to the pretty-printed format so an existing map is not thrown away on upgrade.
    local data = getFile("blockDataDetail")
    if data ~= {} then
        cachedWorldDetail = textutils.unserialize(data)
        if cachedWorldDetail ~= nil then
            return true
        else
            -- print("could not read blockDataDetail file: \n"..data)
            cachedWorldDetail = {}
            return false
        end
    else
        print("no detailed world data")
        saveDetail()
        return false
    end
end

----------------------------------------
-- saveDetail
--
-- function: save cachedWorldDetail to a file
-- return: boolean "success"
--

function saveDetail()
    -- Build the name table first. It is a few dozen strings however large the map gets, which is
    -- the whole point: the names go in the header once instead of into every cell.
    local s_Names, s_Index = {}, {}
    for _, v in pairs(cachedWorldDetail) do
        local s_Name = type(v.data) == "table" and type(v.data[2]) == "table" and v.data[2].name
        if s_Name and not s_Index[s_Name] then
            s_Names[#s_Names + 1] = s_Name
            s_Index[s_Name] = #s_Names
        end
    end

    local ok, err = writeLines("blockDataDetail", s_Names, function(line)
        for k, v in pairs(cachedWorldDetail) do
            if type(v.data) == "table" then
                local s_Name = type(v.data[2]) == "table" and v.data[2].name
                line(k .. "=" .. (v.data[1] and "1" or "0")
                       .. "," .. (s_Name and s_Index[s_Name] or 0))
            end
        end
    end)
    if not ok then print("detail save failed: " .. tostring(err)) end
    return ok
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

function SetDronePos(idx, y, z)
    local x

    if y == nil and z == nil then
        x = tonumber(string.match(idx, "(.*):"))
        y = tonumber(string.match(idx, ":(.*):"))
        z = tonumber(string.match(idx, ":(.*)"))
    else
        x = idx
        idx = x..":"..y..":"..z
    end
    d = d or 0
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

    if y == nil and z == nil then
        x = tonumber(string.match(idx, "(.*):"))
        y = tonumber(string.match(idx, ":(.*):"))
        z = tonumber(string.match(idx, ":(.*)"))
    else
        x = idx
        idx = x..":"..y..":"..z
    end
    d = d or 0
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
    if y == nil and z == nil then
        x = tonumber(string.match(idx, "(.*):"))
        y = tonumber(string.match(idx, ":(.*):"))
        z = tonumber(string.match(idx, ":(.*)"))
    else
        x = idx
        idx = x..":"..y..":"..z
    end
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
    local x
    if y == nil and z == nil then
        x = tonumber(string.match(idx, "(.*):"))
        y = tonumber(string.match(idx, ":(.*):"))
        z = tonumber(string.match(idx, ":(.*)"))
    else
        x = idx
        idx = x..":"..y..":"..z
    end
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
local function cellKey(p_Key)
    if type(p_Key) ~= "string" then return nil end
    local x, y, z = p_Key:match("^(-?%d+%.?%d*):(-?%d+%.?%d*):(-?%d+%.?%d*)$")
    if x == nil then return nil end
    return math.floor(tonumber(x)) .. ":" .. math.floor(tonumber(y)) .. ":" .. math.floor(tonumber(z))
end

local function mergeCachedWorldDetail(newData, p_ID)
    local s_Clean = {}
    for k, v in pairs(newData) do
        local s_K = cellKey(k)
        if s_K then s_Clean[s_K] = v end
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

        if(type(v[2]) == table) then
            if(v[2].name == "ComputerCraft:CC-TurtleAdvanced" or "ComputerCraft:CC-Turtle") then
                table.insert(aged, {coords = k, lastUpdated = cachedWorldDetail[k].lastUpdated})
            end
        end
    end
end

local function mergeCachedWorld(newData)
    for k,v in pairs(newData) do
        local s_K = cellKey(k)
        if s_K then cachedWorld[s_K] = v end
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

-- How far outside the start/goal box the search may wander. Without this an unreachable goal makes
-- the frontier expand in every direction until the node limit, which is slow AND useless -- if the
-- way through is not roughly between the two ends, it is not a path worth walking.
local ASTAR_MARGIN = 24
local ASTAR_MAX_NODES = 20000

function a_star(x1, y1, z1, x2, y2, z2, discover, priority)
    discover = discover or 1
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
    if not (s_GoalCell == nil or s_GoalCell == 0 or s_GoalCell == 2) then
        return false, "goal is solid"
    end

    local s_MinX, s_MaxX = math.min(x1, x2) - ASTAR_MARGIN, math.max(x1, x2) + ASTAR_MARGIN
    local s_MinY, s_MaxY = math.min(y1, y2) - ASTAR_MARGIN, math.max(y1, y2) + ASTAR_MARGIN
    local s_MinZ, s_MaxZ = math.min(z1, z2) - ASTAR_MARGIN, math.max(z1, z2) + ASTAR_MARGIN

    local closedset, cameFrom, g_score = {}, {}, {}
    local heap = {}
    local s_Nodes = 0

    g_score[idx_start] = 0
    heapPush(heap, ASTAR_WEIGHT * heuristic_cost_estimate(x1, y1, z1, x2, y2, z2), idx_start, {x1, y1, z1})

    while #heap > 0 do
        s_Nodes = s_Nodes + 1
        -- Yield periodically. CC:T terminates a coroutine that runs too long without one, so an
        -- unyielding search is not slow -- it is killed, and the caller gets no answer at all.
        if s_Nodes % 200 == 0 then os.sleep(0) end
        if s_Nodes > ASTAR_MAX_NODES then
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
                    if (exclusions[idx_neighbor] == nil or priority)
                       and (((s_Cell or 0) == 0) or idx_neighbor == idx_goal)
                       and not closedset[idx_neighbor] then
                        local s_Step = (s_Cell == nil) and discover or 1
                        if s_Cell == 2 then s_Step = s_Step - 1 end
                        local tentative = g_score[idx_current] + s_Step
                        if g_score[idx_neighbor] == nil or tentative < g_score[idx_neighbor] then
                            cameFrom[idx_neighbor] = {dir, idx_current}
                            g_score[idx_neighbor] = tentative
                            heapPush(heap, tentative +
                                ASTAR_WEIGHT * heuristic_cost_estimate(x4, y4, z4, x2, y2, z2),
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

