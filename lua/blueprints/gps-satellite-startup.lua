-- Self-locating GPS satellite.
--
-- Placed by a builder drone as: computer + wireless modem + disk drive + this floppy. It works out
-- where it is from the CURRENT constellation, then joins it as a host -- so coverage grows outward
-- ring by ring with no configuration step, and nothing has to be told its own coordinates.
--
-- A turtle can place blocks but cannot right-click to configure them, so self-configuration from
-- a floppy is the only way a drone can commission one of these unaided. It is the same disk-drive
-- bootstrap the rest of this fleet already uses.
local function findModem()
    for _, side in ipairs({"left","right","top","bottom","front","back"}) do
        if peripheral.getType(side) == "modem" then return side end
    end
end

local s_Side = findModem()
if not s_Side then
    print("No modem: a GPS satellite needs one to hear pings and to locate itself.")
    return
end

-- Needs four existing hosts in range. That is the constraint that makes the network grow
-- OUTWARD from what already works, rather than being placeable anywhere.
print("Locating from the existing constellation...")
local x, y, z = gps.locate(10, false)
if not x then
    print("No fix -- out of range of four hosts. Move closer and reboot.")
    return
end

print(("Hosting GPS at %d %d %d"):format(x, y, z))
-- Persist it, so a reboot does not depend on the constellation still being reachable. Once a
-- satellite knows its position that fact never changes; it is bolted to the world.
local h = fs.open("/gps-pos.txt", "w")
if h then h.write(textutils.serialize({x = x, y = y, z = z})) h.close() end
shell.run("gps", "host", tostring(x), tostring(y), tostring(z))
