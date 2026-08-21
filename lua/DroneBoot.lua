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

-- pcall around the module for the same reason the bootloader guards its write-back: whatever
-- happens in there, this turtle must come back, or it is simply lost until noticed by hand.
local s_Ok, s_Err = pcall(shell.run, "DroneLogic.lua")
if not s_Ok then print("DroneLogic error: " .. tostring(s_Err)) end

print("EXITED")
os.sleep(3)
os.reboot()