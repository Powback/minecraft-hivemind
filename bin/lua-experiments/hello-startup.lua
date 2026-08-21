-- Minimal startup: proves the computer is alive and makes it PERSIST.
--
-- A computer's directory under <world>/computercraft/computer/<id>/ is created when the computer
-- first WRITES something. A freshly booted computer with an empty filesystem writes nothing, so
-- it leaves no trace on disk even though it is labelled and running. Writing one file is what
-- turns "exists in this session" into "exists after a restart".
local id = os.getComputerID()
local label = os.getComputerLabel() or "<unlabelled>"
local f = fs.open("/booted.txt", "w")
f.write(("computer %d (%s) booted\n"):format(id, label))
f.close()
print(("ready: #%d %s"):format(id, label))
