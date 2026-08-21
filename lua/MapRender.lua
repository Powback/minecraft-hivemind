-- MapRender — draws PowGPSServer's surveyed world as an overview map.
--
-- Nothing about the output size is hardcoded. It takes whatever monitor is attached (any array
-- size, or the terminal if there is none) and fits the surveyed bounds to it, so the map is
-- usable at 1x1 and gets better as the wall grows. The surveyed area also grows over time, so
-- the scale is recomputed from the data every rebuild rather than fixed.
--
-- RESOLUTION. CC:T's characters 0x80-0x9F are 2x3 sub-pixel blocks, so a character cell holds six
-- pixels, not one — an 8x6 monitor at textScale 0.5 is ~242x183 pixels instead of ~121x61. Only
-- five of the six are directly encodable: the sixth (bottom-right) is expressed by inverting the
-- other five and swapping foreground with background, which is what toChar() below does.
--
-- COLOUR. Sixteen palette slots, redefined per mode with setPaletteColour. That is the whole
-- reason to insist on ADVANCED monitors — a normal one is stuck with the default sixteen and a
-- height ramp built from those looks like a fault rather than terrain.

local MODES = {"height", "relief", "material", "coverage"}

local m_Mode   = 1
local m_Height, m_Air, m_Bounds, m_Count = nil, {}, nil, 0

----------------------------------------------------------------------------------------------
-- Palettes. Index 1..14 is the ramp; 15/16 are reserved for chrome and unknown.
----------------------------------------------------------------------------------------------
local RAMP_SLOTS = {
    colors.red, colors.orange, colors.yellow, colors.lime, colors.green,
    colors.cyan, colors.lightBlue, colors.blue, colors.purple, colors.magenta,
    colors.pink, colors.brown, colors.lightGray, colors.gray,
}
local UNKNOWN = colors.black
local CHROME  = colors.white

-- A terrain ramp: deep water -> shallow -> sand -> grass -> forest -> rock -> snow.
local TERRAIN = {
    {0.03,0.09,0.28}, {0.05,0.16,0.42}, {0.07,0.28,0.55}, {0.13,0.42,0.62},
    {0.55,0.52,0.35}, {0.36,0.52,0.24}, {0.28,0.46,0.19}, {0.22,0.40,0.16},
    {0.35,0.38,0.22}, {0.45,0.40,0.28}, {0.52,0.46,0.38}, {0.62,0.58,0.52},
    {0.78,0.76,0.73}, {0.94,0.94,0.96},
}

local function applyPalette(dev, tint)
    if not dev.setPaletteColour then return false end
    for i, slot in ipairs(RAMP_SLOTS) do
        local c = TERRAIN[i]
        local r, g, b = c[1], c[2], c[3]
        if tint then r, g, b = tint(r, g, b, i) end
        dev.setPaletteColour(slot, r, g, b)
    end
    dev.setPaletteColour(UNKNOWN, 0.05, 0.05, 0.07)
    dev.setPaletteColour(CHROME, 0.95, 0.95, 0.95)
    return true
end

----------------------------------------------------------------------------------------------
-- Sub-pixel encoding
----------------------------------------------------------------------------------------------
-- p is six booleans: top-left, top-right, mid-left, mid-right, bottom-left, bottom-right.
-- Returns char, swapped. When swapped, the caller must exchange fg and bg.
local function toChar(p)
    local mask = 0
    for i = 1, 5 do
        if p[i] then mask = mask + 2 ^ (i - 1) end
    end
    if p[6] then
        return string.char(128 + (31 - mask)), true
    end
    return string.char(128 + mask), false
end

----------------------------------------------------------------------------------------------
-- Build a top-down height field from the sparse voxel cache
----------------------------------------------------------------------------------------------
-- cachedWorld is keyed "x:y:z" -> 1 solid / 0 air. The column height is the highest solid y.
-- Air matters too: a column that is known-but-empty is explored, and coverage mode needs to tell
-- that apart from never-visited.
function rebuild(world)
    local h, air, n = {}, {}, 0
    local minx, maxx, minz, maxz, miny, maxy

    for idx, v in pairs(world) do
        -- `%-` not `-`: a bare - is Lua's lazy quantifier, so "(-?%d+)" silently matches nothing
        -- for negative coordinates, which is most of this world.
        local sx, sy, sz = string.match(idx, "^(%-?%d+):(%-?%d+):(%-?%d+)$")
        if sx then
            local x, y, z = tonumber(sx), tonumber(sy), tonumber(sz)
            local key = x .. ":" .. z
            if v == 1 then
                if h[key] == nil or y > h[key] then h[key] = y end
                if miny == nil or y < miny then miny = y end
                if maxy == nil or y > maxy then maxy = y end
            else
                air[key] = true
            end
            if minx == nil or x < minx then minx = x end
            if maxx == nil or x > maxx then maxx = x end
            if minz == nil or z < minz then minz = z end
            if maxz == nil or z > maxz then maxz = z end
            n = n + 1
        end
    end

    m_Height = h
    m_Air    = air
    m_Count  = n
    if minx == nil then
        m_Bounds = nil
    else
        m_Bounds = {minx = minx, maxx = maxx, minz = minz, maxz = maxz,
                    miny = miny or 0, maxy = maxy or 0}
    end
    return n
end

----------------------------------------------------------------------------------------------
-- FOLLOW MODE
----------------------------------------------------------------------------------------------
-- Frame whatever is actually moving, instead of the whole surveyed world.
--
-- Drones report every 30s, which is far too coarse to follow anything smoothly -- but framing the
-- camera does not need block accuracy, only "who moved recently and roughly where". Reporting
-- every move instead would put ~2.5 messages per second per drone on the wire and drown the
-- protocol the fleet actually depends on.
--
-- The view is EASED toward the target rather than snapped to it. Snapping makes the map jump
-- every time a drone stops or a new one starts, which is unreadable; easing turns the same data
-- into a pan.
local m_Follow = false
local m_LastSeen = {}          -- name -> {x, z, at}
local m_View = nil             -- {cx, cz, span} being eased toward the target
local ACTIVE_SECS = 45
local EASE = 0.35              -- fraction of the remaining distance per redraw

function setFollow(p_On)
    m_Follow = p_On and true or false
    if not m_Follow then m_View = nil end
    return m_Follow
end
function following() return m_Follow end

-- "Recently active" is decided by movement, not by status: a drone whose reported position has
-- changed is doing something, whatever it claims to be doing.
local function activeBox(drones)
    if drones == nil then return nil end
    local now = os.clock()
    local minx, maxx, minz, maxz
    for _, d in ipairs(drones) do
        if d.pos and d.pos.x then
            local prev = m_LastSeen[d.name]
            if prev == nil or prev.x ~= d.pos.x or prev.z ~= d.pos.z then
                m_LastSeen[d.name] = {x = d.pos.x, z = d.pos.z, at = now}
            end
            local seen = m_LastSeen[d.name]
            -- Stuck drones are always framed: it is the one thing you must not have to hunt for.
            if (now - seen.at) < ACTIVE_SECS or d.stuck then
                if minx == nil or d.pos.x < minx then minx = d.pos.x end
                if maxx == nil or d.pos.x > maxx then maxx = d.pos.x end
                if minz == nil or d.pos.z < minz then minz = d.pos.z end
                if maxz == nil or d.pos.z > maxz then maxz = d.pos.z end
            end
        end
    end
    if minx == nil then return nil end
    return minx, maxx, minz, maxz
end

----------------------------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------------------------
local function rampIndex(y, miny, maxy)
    if maxy <= miny then return 7 end
    local t = (y - miny) / (maxy - miny)
    local i = math.floor(t * (#RAMP_SLOTS - 1)) + 1
    if i < 1 then i = 1 end
    if i > #RAMP_SLOTS then i = #RAMP_SLOTS end
    return i
end

-- Colour for one world column, per mode.
local function columnColour(mode, wx, wz, detail)
    local key = wx .. ":" .. wz
    local y = m_Height[key]

    if y == nil then
        if mode == "coverage" and m_Air[key] then return colors.blue end
        return UNKNOWN
    end

    local b = m_Bounds
    if mode == "coverage" then
        return colors.lightGray
    end

    if mode == "material" and detail then
        local d = detail[key]
        local name = d and d[2] and d[2].name
        if name then
            if string.find(name, "water")  then return colors.blue end
            if string.find(name, "lava")   then return colors.orange end
            if string.find(name, "sand")   then return colors.yellow end
            if string.find(name, "grass")  then return colors.lime end
            if string.find(name, "dirt")   then return colors.brown end
            if string.find(name, "leaves") then return colors.green end
            if string.find(name, "log")    then return colors.brown end
            if string.find(name, "ore")    then return colors.pink end
            if string.find(name, "stone") or string.find(name, "deepslate") then
                return colors.gray
            end
            return colors.lightGray
        end
        return colors.lightGray
    end

    local i = rampIndex(y, b.miny, b.maxy)

    if mode == "relief" then
        -- Fake a sun from the north-west: compare against the neighbour it would shadow. This is
        -- what stops a heightmap reading as flat colour bands.
        local nw = m_Height[(wx - 1) .. ":" .. (wz - 1)]
        if nw then
            local d = y - nw
            if d > 0 and i < #RAMP_SLOTS then i = i + 1
            elseif d < 0 and i > 1 then i = i - 1 end
        end
    end

    return RAMP_SLOTS[i]
end

-- Draw the map. dev is a monitor or term; everything scales to its actual size.
function draw(dev, world, detail, overlay, drones)
    local mode = MODES[m_Mode]
    if m_Height == nil then rebuild(world) end

    if dev.setTextScale then pcall(dev.setTextScale, 0.5) end
    applyPalette(dev)

    local cw, ch = dev.getSize()
    dev.setBackgroundColour(UNKNOWN)
    dev.clear()

    if m_Bounds == nil then
        dev.setCursorPos(1, 1)
        dev.setTextColour(CHROME)
        dev.write("MapServer: nothing surveyed yet")
        dev.setCursorPos(1, 2)
        dev.write("waiting for drones to report observations")
        return
    end

    -- One character row is reserved for the status line.
    local pw, ph = cw * 2, (ch - 1) * 3
    local b = m_Bounds
    local vminx, vmaxx, vminz, vmaxz = b.minx, b.maxx, b.minz, b.maxz

    if m_Follow then
        local ax, bx, az, bz = activeBox(drones)
        if ax then
            -- Pad so drones are not pinned to the edge, and keep a floor on the span so a single
            -- stationary drone does not zoom to a meaningless couple of blocks.
            local pad = 24
            local tcx, tcz = (ax + bx) / 2, (az + bz) / 2
            local tspan = math.max((bx - ax), (bz - az)) + pad * 2
            if tspan < 48 then tspan = 48 end
            if m_View == nil then
                m_View = {cx = tcx, cz = tcz, span = tspan}
            else
                m_View.cx   = m_View.cx   + (tcx  - m_View.cx)   * EASE
                m_View.cz   = m_View.cz   + (tcz  - m_View.cz)   * EASE
                m_View.span = m_View.span + (tspan - m_View.span) * EASE
            end
            local half = m_View.span / 2
            vminx, vmaxx = m_View.cx - half, m_View.cx + half
            vminz, vmaxz = m_View.cz - half, m_View.cz + half
        end
    end

    local spanx, spanz = (vmaxx - vminx) + 1, (vmaxz - vminz) + 1
    -- Preserve aspect: one scale for both axes.
    local scale = math.max(spanx / pw, spanz / ph)
    if scale <= 0 then scale = 1 end

    local ox = math.floor(vminx - (pw * scale - spanx) / 2)
    local oz = math.floor(vminz - (ph * scale - spanz) / 2)

    local px = {}
    for cy = 1, ch - 1 do
        local line, fgs, bgs = {}, {}, {}
        for cx = 1, cw do
            -- Six samples for this cell, in sub-pixel order.
            local cols, k = {}, 0
            for sy = 0, 2 do
                for sx = 0, 1 do
                    k = k + 1
                    local wx = ox + math.floor(((cx - 1) * 2 + sx) * scale)
                    local wz = oz + math.floor(((cy - 1) * 3 + sy) * scale)
                    cols[k] = columnColour(mode, wx, wz, detail)
                end
            end
            -- Two most common colours become fg/bg; the rest snap to the nearer of the two.
            local a, bcol = cols[1], nil
            for i = 2, 6 do
                if cols[i] ~= a then bcol = cols[i] break end
            end
            if bcol == nil then bcol = a end
            local bits = {}
            for i = 1, 6 do bits[i] = (cols[i] == a) end
            local chr, swapped = toChar(bits)
            line[#line + 1] = chr
            if swapped then
                fgs[#fgs + 1] = colors.toBlit(bcol)
                bgs[#bgs + 1] = colors.toBlit(a)
            else
                fgs[#fgs + 1] = colors.toBlit(a)
                bgs[#bgs + 1] = colors.toBlit(bcol)
            end
        end
        dev.setCursorPos(1, cy)
        dev.blit(table.concat(line), table.concat(fgs), table.concat(bgs))
    end

    -- Drones, drawn as their NUMBER rather than a marker.
    --
    -- A dot tells you something is there; a digit tells you which one, and that is the question
    -- you actually have when four of them are out surveying. Numbers live at character
    -- resolution, not sub-pixel, so this is a second pass over the finished map rather than part
    -- of the pixel loop -- it deliberately paints over the terrain underneath.
    if drones then
        for _, d in ipairs(drones) do
            if d.pos and d.pos.x and d.pos.z then
                local cx = math.floor((d.pos.x - ox) / scale / 2) + 1
                local cy = math.floor((d.pos.z - oz) / scale / 3) + 1
                if cx >= 1 and cx <= cw and cy >= 1 and cy <= ch - 1 then
                    -- Strip the "D" so "D12" prints as 12; the D is the same for all of them.
                    local s_Tag = tostring(d.name or "?"):gsub("^[Dd]", "")
                    dev.setCursorPos(cx, cy)
                    dev.setBackgroundColour(colors.black)
                    -- Three states, no legend needed: red is in trouble, yellow is working,
                    -- white is parked. A stuck drone is the one thing on this map you must not
                    -- have to hunt for.
                    if d.stuck or d.status == "stuck" then
                        dev.setBackgroundColour(colors.red)
                        dev.setTextColour(colors.white)
                    elseif d.status == "surveying" or d.status == "scanning" or d.status == "moving" then
                        dev.setTextColour(colors.yellow)
                    else
                        dev.setTextColour(CHROME)
                    end
                    dev.write(string.sub(s_Tag, 1, math.max(0, cw - cx + 1)))
                end
            end
        end
    end

    -- Status line: what you are looking at, and how much of it is real.
    dev.setCursorPos(1, ch)
    dev.setBackgroundColour(colors.black)
    dev.setTextColour(CHROME)
    local info = string.format("%s%s  x%d..%d z%d..%d  y%d..%d  %d obs  1px=%.1fm",
        mode, m_Follow and " FOLLOW" or "",
        b.minx, b.maxx, b.minz, b.maxz, b.miny, b.maxy, m_Count, scale)
    if drones then
        local s_Stuck = 0
        for _, d in ipairs(drones) do
            if d.stuck or d.status == "stuck" then s_Stuck = s_Stuck + 1 end
        end
        if s_Stuck > 0 then info = info .. "  !" .. s_Stuck .. " STUCK" end
    end
    if overlay then info = info .. "  " .. overlay end
    dev.write(string.sub(info, 1, cw))
end

function setMode(name)
    for i, m in ipairs(MODES) do
        if m == name then m_Mode = i return true, m end
    end
    return false, "modes: height, relief, material, coverage"
end

function nextMode()
    m_Mode = (m_Mode % #MODES) + 1
    return MODES[m_Mode]
end

function currentMode() return MODES[m_Mode] end
function modes() return MODES end
function invalidate() m_Height = nil end
function observationCount() return m_Count end
