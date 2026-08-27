local s_Label = os.getComputerLabel()
if(s_Label ~= nil or s_Label == "DroneMan") then
    shell.run("/startup")
    return
end
print("Initializing Drone...")


shell.run('copy /disk/droneData/* /*')
while(turtle.getFuelLevel() == 0) do
    turtle.suckDown(5)
    turtle.refuel()
end
print("Done copying! Rebooting.")
-- lua-hygiene: allow (steps off the disk drive so the drive is free for the next drone; this runs
-- before pgps exists and before the drone has any position at all, so there is nothing to record.
-- The first real fix comes from GPS after the reboot below.)
turtle.forward()
os.reboot()