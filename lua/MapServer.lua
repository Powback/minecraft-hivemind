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
    PowGPSServer.loadAll()
    if DATA["bounds"] == nil then
        -- Matches the force-loaded region. Deliberately a little inside it, so a drone stops
        -- before the edge rather than exactly on it.
        DATA["bounds"] = {minx = -155, maxx = -25, miny = 0, maxy = 200, minz = -105, maxz = 15}
    end
    if DATA["gpsHosts"] == nil then
        -- The constellation actually built: #100-103, deliberately non-coplanar.
        DATA["gpsHosts"] = {
            {x = -92, y = 95, z = -52}, {x = -78, y = 95, z = -52},
            {x = -92, y = 95, z = -38}, {x = -85, y = 99, z = -45},
        }
    end
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
    PowGPSServer.saveAll()
    MapRender.invalidate()
    return true, true
end

function OnLoadWorld(p_ID, p_Message)
    -- Registered in m_ServerEvents but never written, so the entry pointed at nil. PowNet prints
    -- "Event registered, but pointing to nothing" and carries on, which is why it went unnoticed.
    return true, {cachedWorld = PowGPSServer.getCachedWorld()}
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
    local s_Path = PowGPSServer.a_star(x1, y1, z1, x2, y2, z2, discover, priority)
    if(s_Path == false) then
        return false, {message = "failed to find path"}
    end
    print(#s_Path)
    return true, {path = s_Path}
end

function OnUpdatePath(p_ID, p_Message)
    PowGPSServer.UpdateCachedWorld(p_Message.data.cachedWorld, p_ID)
    PowGPSServer.UpdateCachedWorldDetail(p_Message.data.cachedWorldDetail, p_ID)
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
local function gpsReach(p_Y)
    local s_Lo, s_Hi = 64, 384
    local t = (p_Y + 64) / 384                 -- world spans y=-64..320
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return math.floor(s_Lo + t * (s_Hi - s_Lo))
end

function Coverage()
    local s_Chunks, s_Gps = {}, {}
    if DATA["bounds"] then s_Chunks[#s_Chunks + 1] = DATA["bounds"] end

    -- Every GPS host projects a bubble. Four are needed for a fix, but they are placed as a
    -- cluster, so the intersection of their bubbles is close enough to any one of them -- and
    -- being generous here is safe, since failing to get a fix is not dangerous, only useless.
    for _, h in ipairs(DATA["gpsHosts"] or {}) do
        local r = gpsReach(h.y)
        s_Gps[#s_Gps + 1] = {
            minx = h.x - r, maxx = h.x + r,
            miny = 0,       maxy = 250,
            minz = h.z - r, maxz = h.z + r,
        }
    end

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
    local s_Dev = peripheral.find("monitor") or term
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

Render()
-- Follow mode eases the view a step per redraw, so it needs a heartbeat of its own -- Render is
-- otherwise only called when a message arrives, and a quiet minute would freeze the pan halfway.
local function RenderLoop()
    while true do
        os.sleep(2)
        if MapRender.following() then pcall(Render) end
    end
end

parallel.waitForAny(PowNet.main, PowNet.droneMain, PowNet.control, RenderLoop)
PowGPSServer.saveAll()
print("Unhosting")
rednet.unhost(PowNet.SERVER_PROTOCOL)
