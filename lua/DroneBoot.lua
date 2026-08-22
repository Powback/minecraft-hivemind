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
turtle.refuel(64)
-- Wait for MainFrame rather than spinning on Connect. The blind retry loop hammered rednet with
-- lookups during every fleet reload -- visible on the wire as a flood of dns traffic -- and gave
-- no indication whether it was making progress or would never succeed.
PowNet.WaitForService("MAINFRAME", 120)
s_Connected, DATA = PowNet.Connect("Drone")
while not s_Connected do
    os.sleep(3)
    s_Connected, DATA = PowNet.Connect("Drone")
end

PowNet.UpdateModule("PowNet")
PowNet.UpdateModule('DroneBoot.lua', '/startup')
PowNet.UpdateModule('DroneLogic.lua', '/DroneLogic.lua')
PowNet.UpdateModule('pgps.lua', '/pgps')

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