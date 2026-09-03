os.loadAPI("PowNet")
print("Updating...")
-- OPEN REDNET
for _, side in ipairs({"left", "right"}) do
    if peripheral.getType(side) == "modem" then
        rednet.open(side)
    end
end
if not rednet.isOpen() then
    printError("Could not open rednet")
    return
end
-- BOOT BURNS ONLY WHAT A STRANDED DRONE NEEDS.
--
-- turtle.refuel(64) burned the whole selected stack on every boot, so a redeploy that caught a
-- reliever carrying 64 coal burned all of it: D35 rebooted at 770 and came up at 5,833 with its
-- casualty still dry, and every redeploy of the evening did the same to whatever was in transit.
-- DroneLogic's own watchdog tops the tank up properly once it runs; this is only the net for a
-- drone that cannot get that far, so it burns one item at a time and stops the moment it can move.
local BOOT_FUEL_MIN = 200
if turtle.getFuelLevel() ~= "unlimited" then
    for i = 1, 16 do
        if turtle.getFuelLevel() >= BOOT_FUEL_MIN then break end
        turtle.select(i)
        while turtle.getFuelLevel() < BOOT_FUEL_MIN and turtle.refuel(1) do end
    end
    turtle.select(1)
end
-- Wait for MainFrame rather than spinning on Connect. The blind retry loop hammered rednet with
-- lookups during every fleet reload -- visible on the wire as a flood of dns traffic -- and gave
-- no indication whether it was making progress or would never succeed.
-- A DRONE MUST BE ABLE TO COME HOME WITHOUT THE NETWORK.
--
-- This waited for MainFrame and then span on Connect for ever. Out of modem range that never
-- succeeds -- and the code that walks a stray drone back into range lives in DroneLogic, which this
-- loop never reaches. So a drone that drifted outside the settlement was permanently lost the
-- moment it rebooted: it could not phone home, therefore it never ran, therefore it never moved
-- back into somewhere it could phone home from. D1 was found 56 blocks outside the region with
-- 2,219 fuel, perfectly healthy, and no way to use any of it.
--
-- After a bounded wait, boot anyway on the local copy. Everything downstream already copes: pgps
-- knows the region, refixLoop walks an out-of-bounds drone back toward it, and the moment it is in
-- range again the normal update and registration happen on the next cycle. Running yesterday's code
-- is a small risk; being unreachable for ever is not a risk, it is the loss of the drone.
PowNet.WaitForService("MAINFRAME", 120)
s_Connected, DATA = PowNet.Connect("Drone")
local s_Tries = 0
while not s_Connected and s_Tries < 10 do
    os.sleep(3)
    s_Tries = s_Tries + 1
    s_Connected, DATA = PowNet.Connect("Drone")
end
if not s_Connected then
    printError("No MainFrame -- booting on the local copy to walk back into range")
    local h = fs.open("/offline-boot.txt", "w")
    if h then h.write("booted without MainFrame; running local DroneLogic to return to the region\n") h.close() end
end

-- Only when there is somebody to update FROM. Offline these are pointless and can block.
if s_Connected then
    PowNet.UpdateModule("PowNet")
    PowNet.UpdateModule('DroneBoot.lua', '/startup')
    PowNet.UpdateModule('DroneLogic.lua', '/DroneLogic.lua')
    PowNet.UpdateModule('pgps.lua', '/pgps')
end

-- RECORD WHY IT STOPPED, AND MAKE THE NEXT RUN SAY SO.
--
-- shell.run catches the program's own error and returns false, so this pcall always succeeded and
-- always reported nothing -- a drone crash-looping on its first line was indistinguishable from one
-- running perfectly. That is exactly what happened when DroneLogic's parallel list gained a nil
-- entry: fourteen drones died at startup, rebooted, died again, and the fleet view showed them all
-- as "idle" at their last known position because DroneMan was still holding the final heartbeat
-- from before the crash. The error was on the turtle's screen and nowhere else.
--
-- loadfile + pcall surfaces the real message; writing it down is what lets DroneLogic report it to
-- the fleet on the next boot instead of it being visible only to somebody standing in front of the
-- turtle. The same fix was made in the module bootloader for the same reason.
local s_Fn, s_LoadErr = loadfile("DroneLogic.lua", nil, _ENV)
local s_Ok, s_Err
if s_Fn then s_Ok, s_Err = pcall(s_Fn)
else s_Ok, s_Err = false, "loadfile: " .. tostring(s_LoadErr) end

if not s_Ok then
    print("DroneLogic error: " .. tostring(s_Err))
    local h = fs.open("/last-run.txt", "w")
    if h then h.write(tostring(s_Err) .. "\n") h.close() end
else
    -- A clean exit must clear the marker, or one old crash is reported for ever.
    if fs.exists("/last-run.txt") then fs.delete("/last-run.txt") end
end

print("EXITED")
os.sleep(3)
os.reboot()