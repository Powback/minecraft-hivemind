-- TankStation
os.loadAPI("pgps")
local x,y,z
-- FORWARD-DECLARED FIRST, ABOVE EVERYTHING.
--
-- trace() is called from Init, from the heartbeat, and from every job. Declared partway down the
-- file it is invisible to everything above it -- the name compiles to a global, which is nil, and
-- the caller dies with "attempt to call a nil value". That has happened here before, and it
-- happened again the moment I added a trace call to the boot path.
--
-- Nothing is above this. Assigned further down, once the file has the helpers it needs.
local trace
-- Say() is forward-declared for the same reason and caught by the same rule: it is used from the
-- boot path, hundreds of lines above where it can be defined, and a `local` declared below its use
-- compiles to a nil GLOBAL lookup -- no error, no warning, the call simply throws at runtime.
local Say

local m_Status = "idle"
-- What the drone is doing, in words, e.g. "craft oak_planks x8". Sent alongside status so the
-- fleet view can say what a busy drone is busy WITH. Cleared whenever it goes idle.
local m_Detail = nil
-- Declared HERE, above the heartbeat that reads it, not next to SetHauling that writes it. A local
-- declared below a function that uses it is a nil global in this language, silently -- the mistake
-- that has cost this codebase nine outages. See hq/test/lua-hygiene.test.ts.
local m_Haul = nil
-- A pending "please move" from another drone. Set by the message handler, ACTED ON by whoever owns
-- movement -- never by the handler itself. See OnMakeWay.
local m_YieldAt = nil
-- The single accepted-but-not-yet-started job. One slot, not a list: a drone does one thing at a
-- time, and `executing` is claimed at accept time so a second cannot land. See RunJob / jobLoop.
local m_JobQueue = nil
-- True while Deposit() is running. A deposit is real work but is not a TASK, so without this the
-- status sweep clears its "hauling" on every heartbeat and the drone reports idle mid-journey.
local m_Depositing = false
-- The last block we refused to mine because it is protected. Set by digHard, consumed by hardStop:
-- it is a permanent obstruction, not a retryable one. See the note in digHard.
local m_RefusedBlock = nil
-- Set when docking is refused, so a full tower is not retried every fifteen seconds. See idleDockLoop.
local m_DockBlockedUntil = nil
-- Last time a refused-to-mine observation was pushed to MapServer. See digHard.
local m_BlockedUploadAt = nil
-- Where storage is, remembered from the last time we asked, so a nearly-empty drone does not have
-- to complete a network round trip before it is allowed to worry about the distance home.
--
-- DECLARED HERE, above Deposit(), which is what assigns it. Declared next to FuelFloorNow -- where
-- it reads more naturally -- it was below Deposit, so Deposit's assignment compiled to a GLOBAL
-- while FuelFloorNow read the local, which stayed nil for ever and silently reverted the fuel floor
-- to the flat constant this change exists to replace. Seventh time in this codebase.
local m_HomePos = nil

-- FORWARD-DECLARED, because OnGoTo calls it 465 lines before it is defined.
--
-- As a plain `local function` further down, the name inside OnGoTo compiled to a GLOBAL lookup --
-- nil -- so every GoTo threw "attempt to call a nil value" on its first line. PowNet pcalls handlers
-- and prints the error to the turtle's screen, which nothing reads, so from outside the message
-- simply never arrived: TaskMan logged "dispatch GoTo -> D3", the drone logged nothing at all, and
-- the task was reclaimed as "never started". A rescue is dispatched as a GoTo, so this also broke
-- every rescue in the fleet.
--
-- Caught by test/lua-hygiene.test.ts, which exists because this is the eighth time.
local reachableTarget
local executing = false
-- REFUELLING MUST LOOK BUSY, BECAUSE IT IS.
--
-- The fuel watchdog stops the running job by clearing `executing` -- and `executing` is the exact
-- flag every job-accept gate tests for "am I free". So the instant a drone broke off to refuel it
-- advertised itself as available, was handed the next survey, and flew off on it: D2 logged "fuel
-- at 343 -- breaking off to refuel" and was airborne on a new survey ninety seconds later, having
-- refuelled nothing, and carried on down to 185. The watchdog fired perfectly every time and was
-- undone by the very line it used to interrupt the job.
local m_Refuelling = false

-- ONE ANSWER TO "CAN THIS DRONE TAKE WORK".
--
-- Three places decided this. RunJob and OnSurvey both refused while m_Refuelling; SendHeartBeat --
-- which produces the status the SCHEDULER reads -- did not know about m_Refuelling at all. So a
-- refuelling drone advertised itself as idle, TaskMan picked it, dispatched fire-and-forget,
-- recorded the assignment, and the drone answered "JOB Lumber REFUSED: busy" to nobody. The task
-- then belonged to a drone that was never going to run it, while the queue read as fully staffed
-- and the fleet view showed the drone standing idle.
--
-- Caught on D31 holding lumber:oak_log -- the one job between this settlement and renewable fuel --
-- assigned and refused on a loop for minutes. Exactly the duplicated-concept shape this codebase
-- keeps paying for: one question, answered in three places, one of which had drifted.
--
-- Returns the REASON rather than a boolean, because "busy" and "refuelling" want different
-- responses and the log has to name which one it was.
local function unavailableReason()
    if m_Refuelling then return "refuelling" end
    if executing then return "busy" end
    return nil
end

-- The status the SCHEDULER is allowed to see. Lives next to the predicate it defers to, because
-- the whole fault was these two drifting apart: keeping them adjacent is the cheap part.
local function reportableStatus(p_Status)
    if p_Status ~= "idle" then return p_Status end
    return unavailableReason() or p_Status
end
-- Forward declaration. reportTask is defined much further down, but OnGoTo -- which sits above it --
-- has to call it now that a rescue is dispatched as a GoTo. Declared the obvious way, the name in
-- OnGoTo would compile to a GLOBAL lookup and be nil at call time, so the drone would arrive and
-- then die with "attempt to call a nil value" instead of reporting. Same trap as m_DroneEvents
-- below, and as pgps.mayStep before it.
local reportTask
-- Blueprint headings arrive as names because a blueprint is data that a human reads and edits.
-- pgps numbers them: North=0, West=1, South=2, East=3.
-- One definition of the compass, and it is pgps's. This was a private copy that happened to agree
-- with pgps -- luck, not design, given DockingMan's copy did not. Resolved at CALL time, never at
-- file scope: pgps is an os.loadAPI module and may not be loaded when this line runs.
local function HEADINGS_() return pgps.HEADINGS end

-- A DOCK IS BORROWED, NOT OWNED.
--
-- Docking used to be a home berth: DroneMan allocated a slot the first time a drone registered, the
-- drone flew to it once at boot, and it held that slot for the rest of its life. Nothing ever gave
-- one back -- DockingMan had no release path at all -- so slots were consumed in sequence and never
-- returned, and a tower went permanently full while standing physically empty. Every reboot burned
-- another, which on a day of fleet-wide restarts is most of them.
--
-- Reserved on the way in, released on the way out. That turns one berth per drone into a pool, so
-- the tower needs as many slots as drones docked at once rather than drones in existence -- and it
-- means the slot a drone gets is near where it actually is, instead of wherever it first booted.
local m_Docked = false
local m_DockingSince = nil

print("I AM ALIVE!")

function TaskStart()
    executing = true
end
function TaskEnd()
    executing = false
    pgps.StartExec() -- Task has ended, allow force allow execution agian.
end

function Init()
    pgps.startGPS()

    -- Bounds BEFORE the first move. setLocationFromGPS steps the turtle to find its heading, so
    -- fetching these afterwards would leave the very first movement of a drone's life unchecked.
    if PowNet.WaitForService("MapServer", 30) then
        local s_B = PowNet.sendAndWaitForResponse("MapServer",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "GetBounds", {}), PowNet.SERVER_PROTOCOL)
        if type(s_B) == "table" and s_B.bounds then pgps.setBounds(s_B.bounds) end
    end
    -- Out of radio range there is nobody to ask -- and that is exactly when knowing the region
    -- matters, because it is the only thing that will send the drone back toward the mast.
    pcall(pgps.loadRegion)

    x,y,z = pgps.setLocationFromGPS()

    -- SELF-HEALING REGISTRATION
    --
    -- Having a label used to mean "registered", full stop. But a registry reset, a rebuilt
    -- DroneMan, or a restored backup leaves drones holding names nobody recognises: they skip
    -- registration forever because they have a label, and DroneMan rejects their heartbeats
    -- because it has no record of them. Both sides look healthy and the fleet is entirely
    -- disconnected -- and the only fix was editing turtle NBT by hand, which races the shutdown
    -- that has to happen first.
    --
    -- So ask instead of assume: a heartbeat that comes back "unregistered" means our name is
    -- meaningless, and we drop it and register again.
    if(os.getComputerLabel() ~= nil) then
        -- Wait for DroneMan to exist before asking it anything. Without this the probe fires into
        -- a fleet that is still booting, times out, and the drone keeps a name nobody issued.
        if PowNet.WaitForService("DroneMan", 90) then
            local s_Probe = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Heartbeat",
                {pos = (x and {x = x, y = y, z = z}) or nil, status = "idle",
                 fuel = turtle.getFuelLevel(), role = Role()})
            local s_Res, s_Answered = PowNet.AskInsisting("DroneMan", s_Probe, 3)
            if(not s_Answered) then
                -- Never heard back. Say so rather than guessing: guessing "registered" is what
                -- produced a fleet that looked healthy and was not.
                Distress("DroneMan unreachable at boot", "kept label " .. tostring(os.getComputerLabel()))
            elseif(s_Res == "unregistered") then
                print("DroneMan does not know me -- re-registering")
                os.setComputerLabel(nil)
            end
        else
            Distress("DroneMan never appeared", "cannot verify registration")
        end
    end

    if(os.getComputerLabel() == nil) then
        print("Who am i...?")
        if(x == nil or y == nil or z == nil) then
            -- REGISTER ANYWAY.
            --
            -- Returning here left the drone with no name, no registration and no way to say so:
            -- invisible to DroneMan, absent from every tool, and indistinguishable from a turtle
            -- that had been destroyed. A drone that cannot work out WHERE it is still knows THAT
            -- it is, and that is the one fact a rescue needs.
            print("no GPS -- registering without a position so someone can come and find me")
            Distress("no GPS fix", "registered without a position; needs coverage extending to it")
        end
        local s_Fuel = turtle.getFuelLevel()
        local s_Data = {id = os.getComputerID(),
                        pos = (x and {x = x, y = y, z = z}) or nil, fuel = s_Fuel,
                        role = Role(), noGps = (x == nil) or nil}
        PowNet.WaitForService("DroneMan", 90)
        local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "RegisterDrone", s_Data)
        local s_Response = PowNet.AskInsisting("DroneMan", s_Message, 3)
        if(not s_Response) then
            print("Failed to call home.")
            return false
        end
        if(type(s_Response) ~= "table") then
            -- tostring, because the common case here is s_Response == false (DroneMan did not
            -- answer within the timeout) and concatenating a boolean is an error. That error
            -- crashed DroneLogic, DroneBoot rebooted the turtle, and it registered all over
            -- again -- turning one slow reply into a registration loop.
            Say("response: " .. tostring(s_Response))
            return false
        end
        print(s_Response)
        os.setComputerLabel(s_Response.name)
        Say("I am " .. s_Response.name .. ", and I am here to serve.")

        if(s_Response.go) then
            -- Through TravelTo like every other journey. A bare moveTo here fails on unsurveyed
            -- ground -- which is most of a fresh world -- and the drone then believed it was
            -- docked while standing wherever it had spawned, holding a berth it was not in.
            local g = s_Response.go
            trace(("boot: docking at %s,%s,%s"):format(tostring(g.x), tostring(g.y), tostring(g.z)))
            if TravelTo(g.x, g.y, g.z, (tonumber(g.y) or 64) + 4) then
                m_Docked = true
                pgps.turnTo(s_Response.heading)
            else
                trace("boot: could not reach the assigned berth -- staying undocked")
            end
        end
    end

    SendHeartBeat()
end


-- WHAT CODE IS THIS DRONE ACTUALLY RUNNING?
--
-- UpdateModule fetches each module from MainFrame on boot and writes it carefully -- but it has no
-- concept of a hash. It never asks whether the copy on disk is already current, and never verifies
-- that what landed matches the source. So a drone that could not reach MainFrame on boot simply
-- kept whatever it had, silently, for ever.
--
-- That is not theoretical. FOURTEEN OF TWENTY computers sat on a stale pgps for hours after a fix
-- was deployed, and nothing anywhere reported it: the drift bug the fix had cured came straight
-- back, measured at zero on the six updated machines and still firing on the fourteen that were
-- not. It was only found by md5-ing files on the host by hand. The loop is vicious -- the drones
-- that most need a fix are the ones out of contact, which is exactly why they cannot pull it.
--
-- A checksum in the heartbeat turns that from invisible into obvious: every drone says what it is
-- running, and one glance across the fleet shows who is stale. Cheap and additive rather than
-- cryptographic -- this needs to detect DIFFERENCE between copies of our own files, not resist an
-- adversary, and it must run on a turtle without breaking the 10s coroutine budget.
local function fileStamp(p_Path)
    if not fs.exists(p_Path) then return 0 end
    local h = fs.open(p_Path, "r")
    if not h then return 0 end
    local s_Text = h.readAll() or ""
    h.close()
    local s_Sum, s_Len = 0, #s_Text
    -- Sample rather than sum every byte: a full pass over a 300KB module on every heartbeat is
    -- exactly the sort of thing that trips CC's coroutine budget. Stride sampling plus the length
    -- distinguishes our own versions reliably.
    for i = 1, s_Len, 61 do
        s_Sum = (s_Sum * 31 + s_Text:byte(i)) % 16777213
    end
    return (s_Sum * 8191 + s_Len) % 16777213
end

-- "UNREGISTERED" IS AN ANSWER, NOT A MISS.
--
-- DroneMan replies "unregistered" when it holds no record of us. Init() handles that at BOOT --
-- drop the label, register again -- but a drone already RUNNING when DroneMan loses its registry
-- never re-checks. It heartbeats into a rejection, counts each one as a missed link, and goes lost
-- permanently while powered on, in range, and working.
--
-- Measured: replacing DroneMan's computer gave it an empty registry (its state restores from
-- MainFrame's VFS), and six of eleven drones were orphaned for over ten minutes -- every one
-- powered ON with the mast repeater up. Nothing but a reboot would ever have recovered them.
--
-- Init()'s comment describes this exact failure ("a wiped DroneMan, or a restored backup leaves
-- drones holding names nobody recognises: they skip registration forever") and the fix was wired
-- only into the boot path. This is where a RUNNING drone finds out.
--
-- Reboot rather than re-register inline: Init() owns registration and does it correctly, and a
-- reboot re-pulls modules too. Split out to keep SendHeartBeat inside the complexity gate.
local function reregisterIfDisowned(p_Reply)
    if p_Reply ~= "unregistered" then return false end
    trace("DroneMan does not know me -- dropping my name and rebooting to re-register")
    pcall(os.setComputerLabel, nil)
    os.sleep(1)
    os.reboot()
    return true
end

function SendHeartBeat()
    -- Read the position, do not re-derive it. This used to call setLocationFromGPS, which steps
    -- the turtle forward and back to work out its heading -- acceptable once during Init, and the
    -- reason a "heartbeat" could never actually beat: on a timer it would shuffle every docked
    -- drone out of its slot and back for ever.
    local hx, hy, hz = pgps.getCachedPosition()

    local s_Pos = nil
    if(hx == nil or hy == nil or hz == nil) then
        print("No cached position yet.")
    else
        s_Pos = {x = hx, y = hy, z = hz}
        x, y, z = hx, hy, hz
    end
    local s_Fuel = turtle.getFuelLevel()

    -- IDLE MEANS AVAILABLE. Say "blocked" when it is not.
    --
    -- A drone missing its position or its heading cannot move, so it cannot do any job it is given
    -- -- but it reported "idle", which is the word the scheduler reads as "ready for work". It was
    -- then offered jobs it could only fail, and an operator looking at the fleet saw a healthy
    -- drone standing around. Availability and health are different, and this field is about
    -- availability.
    -- A STATUS MUST NOT OUTLIVE THE JOB THAT SET IT.
    --
    -- m_Status is set by a job ("moving", "scanning", "mining") and cleared when it finishes. If the
    -- job throws, or is aborted between the two, the label is simply left behind -- and a drone
    -- reporting "moving" is reported as BUSY, so TaskMan never offers it work and it stands there
    -- for ever looking productive. D7 was in exactly this state: `status=moving executing=false`,
    -- flying around an unsurveyed area scanning nothing, because as far as the fleet was concerned
    -- it was already in the middle of something.
    --
    -- `executing` is the authority -- it is set and cleared by the job machinery itself -- so when
    -- nothing is executing, the drone is idle by definition, whatever the last label happened to be.
    -- DOCKING IS NOT EXEMPT FROM THE SWEEP, IT JUST GETS LONGER.
    --
    -- Excluding "docking" outright meant a drone whose dock attempt failed silently stayed
    -- "docking" for ever -- and a docking drone is never picked for work, so it was retired without
    -- anyone deciding to retire it. D1 finished its mine job, logged "JOB Mine done", and sat in
    -- docking with nothing running. The state is legitimately long-lived, so it gets a grace
    -- period rather than an exemption.
    if m_Status == "docking" and not executing then
        m_DockingSince = m_DockingSince or os.clock()
        if (os.clock() - m_DockingSince) > 90 then
            trace("docking for 90s with no job running -- clearing to idle")
            m_Status = "idle"
            m_DockingSince = nil
        end
    elseif m_Status ~= "docking" then
        m_DockingSince = nil
    end

    -- AN IDLE DRONE IS NOT STILL DOING THE LAST THING.
    --
    -- The detail was only cleared on the path THROUGH finish(), so every other route to idle -- a
    -- crashed job, a reclaimed task, the sweep below -- left the old line showing indefinitely. The
    -- panel reported "D4 idle -- hauling oak_logx26" for half an hour, which reads as a drone stuck
    -- mid-haul rather than one with nothing to do, and sends whoever is looking at the wrong
    -- problem. Cleared where idle is actually DECIDED, not where one particular path happens to
    -- pass through.
    if not executing and m_Status == "idle" and (m_Detail ~= nil or m_Haul ~= nil) and not m_Depositing then
        m_Detail = nil
        m_Haul = nil
    end

    -- A DEPOSIT IS WORK, EVEN THOUGH IT IS NOT A TASK.
    --
    -- The sweep below clears any non-idle status when no JOB is executing -- and a deposit triggered
    -- by the idle rule (never park holding cargo) is not a job. So a drone hauling 760 items
    -- thirty-five blocks across the map had its "hauling" wiped on every heartbeat and reported
    -- itself idle the entire way, which reads as a drone doing nothing while carrying the fleet's
    -- ore. m_Depositing marks the interval so the sweep leaves it alone.
    if not executing and m_Depositing and m_Status ~= "idle" then
        -- genuinely working; nothing to clear
    elseif not executing and m_Status ~= "idle" and m_Status ~= "docking" then
        trace(("status %s left behind with no job running -- clearing to idle"):format(tostring(m_Status)))
        m_Detail = nil
        m_Haul = nil
        m_Status = "idle"
    end

    local s_Report = m_Status

    -- IDLE MEANS AVAILABLE, so it must be the same answer RunJob would give. A drone that will
    -- refuse the job must not advertise itself as ready for one.
    s_Report = reportableStatus(s_Report)

    -- SAY WHAT IS IN THE CRATE. "hauling" names an activity and not a cargo, so a drone fetching
    -- logs for a blocked craft and one carrying cobblestone to a dump looked identical on the
    -- panel -- and the interesting question is always which one it is.
    if m_Haul and m_Status == "hauling" then
        m_Detail = ("hauling %s"):format(m_Haul)
    end
    -- SAY WHY. "blocked" on its own sends whoever reads it looking in the wrong place.
    --
    -- These are three genuinely different faults with three different fixes -- extend GPS coverage,
    -- re-derive heading, send a chunk loader -- and they were all reported with the same word and
    -- no detail, so the only way to tell them apart was to read the drone's log by hand.
    local s_Why = m_Stuck
    if s_Report == "idle" then
        local px, py, pz, pd = pgps.getCachedPosition()

        -- Re-acquiring a lost fix belongs OUTSIDE the heartbeat. See refixLoop.
        --
        -- Doing it here was a mistake with a nasty shape: gps.locate blocks for five seconds, so
        -- every drone without a fix delayed its own heartbeat by five seconds, every time. DroneMan
        -- marks a drone offline after three missed beats, so the drones that most needed help were
        -- precisely the ones that got marked dead -- and once offline they were excluded from
        -- assignment, which guaranteed they stayed that way. Nine of fourteen went stranded within
        -- two minutes of adding it.

        if px == nil then
            -- Do not assert a cause that has not been checked. The previous wording claimed the
            -- drone could not hear four hosts, which sent me looking at the constellation for an
            -- hour while the actual fault was that nothing ever retried.
            s_Report, s_Why = "blocked", "no position fix (re-fix attempted and failed)"
        elseif pd == nil then
            -- AN UNKNOWN HEADING IS NOT A BLOCKED DRONE, AND CALLING IT ONE IS A DEADLOCK.
            --
            -- Heading is derived by stepping one block and re-reading GPS, so a drone can only learn
            -- which way it faces by MOVING. Reporting "blocked" marks it stranded, a stranded drone
            -- is never given work, a drone with no work never moves -- and so it never derives the
            -- heading that would have cleared the report. Three freshly placed drones sat in exactly
            -- this loop, in open air, with a working GPS fix and full fuel.
            --
            -- It is worth SAYING, because a drone that does not know its heading will refuse a
            -- precise move and that is worth knowing when one behaves oddly. But it stays idle --
            -- which means dispatchable -- and the first order it accepts fixes it.
            s_Why = "heading not yet derived; will re-establish on the next move"
        elseif not pgps.mayStep(px, py, pz) then
            -- Standing somewhere it is not allowed to be, which is the one that stranded D3, D7
            -- and D8. boundsReason names which constraint refused.
            s_Report = "blocked"
            s_Why = "outside coverage: " .. tostring(pgps.boundsReason(px, py, pz) or "unknown")
        end
    end

    -- A crash recorded by the bootloader is reported to the fleet, once, on the way back up.
    -- Otherwise a drone that dies on its first line every three seconds shows as "idle" for ever,
    -- because the last heartbeat DroneMan received was the healthy one before it broke.
    -- Read the crash record ONCE, report it, then clear it.
    --
    -- The bootloader only deletes it on a clean exit, and a healthy drone does not exit -- so a
    -- record from a crash that was fixed hours ago sat on disk looking current, and every check
    -- reported a working fleet as broken. Having survived long enough to send a heartbeat is the
    -- evidence that the crash is over.
    if m_LastCrash == nil then
        m_LastCrash = false
        if fs.exists("/last-run.txt") then
            local h = fs.open("/last-run.txt", "r")
            if h then m_LastCrash = (h.readAll() or ""):gsub("%s+$", "") h.close() end
            pcall(fs.delete, "/last-run.txt")
        end
    end

    -- WHAT THE DRONE IS CARRYING, IN THE HEARTBEAT.
    --
    -- A drone's inventory was invisible to everything: sixteen logs in D3's hands were, as far as
    -- the fleet was concerned, nowhere. The crafter would sit failing "storage has none of the
    -- ingredients" while the wood it needed was two blocks away inside another drone, and nothing
    -- anywhere could notice -- not the stock view, not the planner, not a human reading the panel.
    --
    -- Aggregated by name, so it is a handful of entries rather than sixteen slots.
    local s_Inv = {}
    for i = 1, 16 do
        local n = turtle.getItemCount(i)
        if n > 0 then
            local det = turtle.getItemDetail(i)
            if det and det.name then s_Inv[det.name] = (s_Inv[det.name] or 0) + n end
        end
    end

    local s_Data = {pos = s_Pos, status = s_Report, detail = m_Detail, fuel = s_Fuel, role = Role(),
                    inv = s_Inv,
                    -- What code this drone is running, so a stale fleet is visible instead of
                    -- silently reintroducing bugs that were already fixed. See fileStamp.
                    build = {pgps = fileStamp("/pgps"), logic = fileStamp("/DroneLogic.lua")},
                    stuck = s_Why, hosting = m_Hosting,
                    crash = (m_LastCrash ~= false and m_LastCrash ~= "") and m_LastCrash or nil}
    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Heartbeat", s_Data)
    -- WAIT FOR THE ANSWER.
    --
    -- This was fire-and-forget, which meant a drone could not tell a healthy fleet from being out
    -- of radio range: it shouted into the dark on a timer and carried on working. Out of range is
    -- precisely when a drone most needs to know, because it is the one condition it can still fix
    -- by itself -- by going back the way it came until someone answers.
    --
    -- Short timeout: this runs on a loop and a slow DroneMan should cost a missed beat, not a
    -- stalled drone.
    -- Five seconds, not two. DroneMan services the whole fleet from one receive loop, so a reply
    -- can legitimately take a while; a tight timeout turns "busy" into "missing".
    -- ONE attempt, SHORT timeout. A heartbeat is periodic: if this one is not answered the next is
    -- three seconds away, so retrying buys nothing and costs DroneMan three times the traffic at
    -- precisely the moment it is already behind. Link loss is decided by LINK_LOST_AFTER consecutive
    -- misses, not by a single one, so nothing downstream needs the retries either.
    local s_Reply = PowNet.sendAndWaitForResponse("DroneMan", s_Message, PowNet.SERVER_PROTOCOL, 2, 1)

    -- "UNREGISTERED" IS AN ANSWER, NOT A MISS.
    --
    -- DroneMan replies "unregistered" when it has no record of us. Init() already handles that at
    -- BOOT -- drop the label, register again -- but a drone that is already RUNNING when DroneMan
    -- loses its registry never re-checks. It keeps heartbeating into a rejection, counts each one
    -- as a missed link, and goes lost permanently while sitting powered on, in range, and working.
    --
    -- That is not hypothetical: replacing DroneMan's computer gave it an empty registry (its state
    -- restores from MainFrame's VFS), and six of eleven drones were orphaned for over ten minutes,
    -- every one of them powered ON with the mast repeater up. Nothing would ever have recovered
    -- them but a reboot.
    --
    -- The comment in Init() describes this exact failure -- "a wiped DroneMan, or a restored backup
    -- leaves drones holding names nobody recognises: they skip registration forever" -- and the fix
    -- was only ever wired into the boot path. It belongs here too, because this is where a running
    -- drone finds out.
    --
    -- Rebooting rather than re-registering inline: Init() owns registration and does it correctly,
    -- and a reboot also re-pulls modules. The current job is already on disk -- saveResume() runs
    -- when a job STARTS, not here: it is declared far below this function, so calling it would pass
    -- nil to pcall and silently do nothing. That is the local-declared-below trap this codebase has
    -- been bitten by nine times, and the hygiene lint caught it in this very edit.
    reregisterIfDisowned(s_Reply)

    if s_Reply ~= false and s_Reply ~= nil then return true end

    -- THE TOWER CANNOT HEAR US. TRY THE FLEET.
    --
    -- This is the whole reason the mesh exists. A drone mining at y=47 is out of modem range of
    -- every module, so its heartbeat vanishes, DroneMan marks it offline, and the fleet concludes it
    -- is trapped and sends someone to dig it out -- while it works away perfectly well. The drone
    -- is not out of reach of the FLEET, though: there are usually several drones strung out between
    -- it and the surface, and each of them is a radio.
    --
    -- So hand the heartbeat to the neighbour closest to base and let it walk out hop by hop. One
    -- addressed message per hop, never a broadcast. If nobody is in earshot either, we really are
    -- alone and silence is the honest outcome.
    -- `type(...) == "function"`, not a bare call. A Lua chunk assigns `function MeshReady()` only
    -- when execution REACHES that line -- and it sits four thousand lines below this one, while
    -- SendHeartBeat is called during boot before the chunk gets there. So the global is genuinely
    -- nil at that moment and the bare call took down every drone in the fleet with
    -- "attempt to call global 'MeshReady' (a nil value)". Defined-later is not the same as
    -- defined-above, and only the first heartbeats are affected -- by the time the mesh matters,
    -- the loops are running and this resolves normally.
    -- BOTH, because they are defined fourteen lines apart and a heartbeat can land between them.
    if type(MeshReady) == "function" and type(meshForward) == "function" and MeshReady() then
        local s_Sent = meshForward({
            eid  = os.getComputerID() .. ":" .. tostring(os.epoch("utc")),
            to   = "DroneMan",
            msg  = s_Message,
            hops = 0,
        }, nil)
        if s_Sent then
            -- RELAYED IS NOT DELIVERED, AND MUST NOT COUNT AS A LIVE LINK.
            --
            -- Returning true here told the heartbeat loop the link was fine, so m_Missed never rose
            -- and RecoverLink() -- the thing that walks a drone back into radio range -- stopped
            -- firing entirely. Four drones sat holding 1,600 items between them, retrying a deposit
            -- they could not perform because they could not reach StorageMan, every 45 seconds,
            -- indefinitely. Before the mesh they would simply have walked home.
            --
            -- A neighbour accepting the envelope means the telemetry has a chance of arriving. It
            -- says nothing about whether DroneMan got it, and nothing about whether THIS drone can
            -- be given orders -- which is what being in range actually means. So: report the relay,
            -- and still report the link as down.
            trace("heartbeat: tower unreachable -- handed to the fleet, still counting as a miss")
        end
    end
    return false
end

-- WALK BACK UNTIL SOMEONE ANSWERS.
--
-- The route the drone walked in on is the one route it KNOWS is passable, and the link worked
-- somewhere along it. So losing contact is recoverable without any help: retrace the trail, testing
-- after every crumb, and stop the moment the fleet replies.
--
-- This is the only situation where moving on an unverified position is right. The guard that
-- normally forbids it exists because drift walked a drone out of the world -- but out of range that
-- same guard freezes it exactly where it must not stay, turning a recoverable drone into a lost
-- one. Retracing is safe because it is going back, not reasoning about somewhere new.
local RECOVER_MAX_CRUMBS = 120

function RecoverLink()
    local s_Was = m_Status
    m_Status = "recovering"
    pgps.setRecovering(true)
    Say("link lost -- retracing " .. tostring(pgps.trailLength()) .. " crumbs")

    local s_Steps = 0
    while s_Steps < RECOVER_MAX_CRUMBS do
        local bx, by, bz = pgps.trailBack()
        if bx == nil then break end
        s_Steps = s_Steps + 1
        pgps.flyTo(bx, by, bz, 32)
        if SendHeartBeat() then
            pgps.setRecovering(false)
            m_Status = s_Was
            Say("link regained after " .. s_Steps .. " crumbs")
            Distress("link lost and regained", "retraced " .. s_Steps .. " crumbs")
            return true
        end
    end

    -- NO CRUMBS? THEN HEAD FOR HOME ON THE MAP.
    --
    -- The breadcrumb trail lives in memory, so a drone that has REBOOTED has none -- trailBack()
    -- returns nil on the first call, the loop above exits without moving, and "recovery" does
    -- nothing at all. That is precisely the drone that needs it: four of them sat 87-93 blocks out,
    -- holding 1,600 items between them, rebooting into a recovery routine that was a no-op every
    -- single time.
    --
    -- The region centre is known without any network and survives a reboot in pgps-region.txt, so
    -- there is always a direction to walk even with no trail and no contact. Walking toward it is
    -- what the crumbs were approximating anyway; this is the same idea with a worse map, which
    -- beats standing still with no map.
    -- Guarded: HomeXYZ is defined far below this function, and while recovery only ever runs long
    -- after load, a nil call HERE would strand the drone permanently -- which is the exact failure
    -- this code exists to end. Cheap insurance on the one path that has no second chance.
    local hx, hy, hz
    if type(HomeXYZ) == "function" then hx, hy, hz = HomeXYZ() end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx ~= nil and hx ~= nil then
        trace(("link lost with no trail -- walking home toward %d,%d,%d"):format(hx, hy, hz))
        for _ = 1, 12 do
            -- Short hops, testing after each: the moment anyone answers we stop and resume work,
            -- rather than trekking all the way back for nothing.
            local tx = cx + math.max(-16, math.min(16, hx - cx))
            local tz = cz + math.max(-16, math.min(16, hz - cz))
            if pgps.flyTo(tx, hy, tz, 64) == false then
                if CanDig() then pgps.digTo(tx, hy, tz) end
            end
            cx, cy, cz = pgps.getCachedPosition()
            if cx == nil then break end
            if SendHeartBeat() then
                pgps.setRecovering(false)
                m_Status = s_Was
                trace(("link regained on the way home at %d,%d,%d"):format(cx, cy, cz))
                return true
            end
            if math.abs(cx - hx) + math.abs(cz - hz) < 8 then break end
        end
    end

    pgps.setRecovering(false)
    m_Status = "stuck"
    -- Out of trail and still alone. Say so on the terminal and in the fault file: nobody is
    -- listening on rednet by definition, so this is the only place it can be recorded.
    Distress("link lost", "retraced " .. s_Steps .. " crumbs without regaining contact")
    return false
end

-- Cheap liveness. The registry cannot tell a docked drone from one that no longer exists:
-- heartbeats only fire at boot and shutdown, so a drone that is mined out of the world stays
-- "idle" forever and keeps being handed work. D2 was dug up by D1 and was still being offered
-- jobs afterwards.
function OnPing(p_ID, p_Message)
    return true, {alive = true, status = m_Status, fuel = turtle.getFuelLevel()}
end

function OnReboot(p_ID, p_Message)
    os.reboot()
end

-- A CC terminal cannot be read from outside the game, so a handler that misbehaves is completely
-- opaque -- which is exactly why "the drone accepts GoTo and does not move" was unfalsifiable.
-- Truncating, not growing. The Bridge learned this the hard way: an append-only log reached the
-- 8MB computer_space_limit and then killed the module with "Out of space" -- a diagnostic that
-- destroys the thing it is meant to explain.
local TRACE_LIMIT = 32 * 1024
-- KEEP THE HANDLE OPEN. THE LOG WAS COSTING MORE THAN THE WORK IT DESCRIBED.
--
-- This did FIVE filesystem calls per line -- exists, getSize, open, writeLine, close -- and there
-- are 131 trace sites, several of them inside per-candidate loops. A gather over 192 targets was
-- paying hundreds of open/close cycles, which in CC are far more expensive than any of the string
-- building people usually suspect first.
--
-- One handle, held open, flushed after each line: the log stays as current as it was (a flush is
-- what actually puts bytes on disk, and it is what made close() feel necessary), while the four
-- other syscalls disappear. The size check moves to every hundredth line, because a log cannot
-- plausibly cross the limit in between.
local m_LogHandle, m_LogLines = nil, 0

-- Kept (and still called from OnShutdown) so nothing dangles if a future change reintroduces a
-- held-open handle. With close-per-line there is nothing to close, and that is the point.
--
-- GLOBAL, because OnShutdown is defined four hundred lines above this and calls it. A `local` here
-- would be a nil global there -- silently, which is the mistake this codebase makes most often.
function CloseTrace()
    if m_LogHandle then pcall(m_LogHandle.close) m_LogHandle = nil end
end

-- SAY A PERSISTING CONDITION ONCE, NOT ONCE PER RETRY.
--
-- The log is the fleet's primary debugging surface and it WRAPS -- it is deleted at TRACE_LIMIT and
-- started again. So a message that repeats while nothing changes does not just add noise, it
-- actively destroys evidence: it evicts the lines that say what actually happened.
--
-- Measured across the fleet: 6,586 lines, of which 1,482 (22.5%) were "tower unreachable" and 1,132
-- (17.2%) were "MOVE REFUSED: Out of fuel". Forty per cent of the entire debugging surface spent
-- restating two conditions that had not changed. A drone at zero fuel says so a thousand times; it
-- is the same fact every time, and the thousandth copy pushed out the line explaining how it got
-- there.
--
-- The fix belongs HERE rather than at the two call sites, because the pattern is not about those
-- two messages -- any condition that persists produces it. Identical text inside the window is
-- counted rather than written, and the count is reported when the message is finally let through,
-- so nothing is silently lost: "x412 in the last 60s" is strictly more informative than 412 copies.
local REPEAT_WINDOW = 60          -- seconds a message stays suppressed after being written
local REPEAT_KEYS   = 64          -- cap the table; a drone must not leak memory through its logger
local m_SeenAt, m_SeenN, m_SeenCount = {}, {}, 0

-- Returns the text to write, or nil to suppress. Split out so trace() itself stays simple.
local function repeatFilter(p_What)
    local s_Now  = os.clock()
    local s_Last = m_SeenAt[p_What]
    if s_Last ~= nil and (s_Now - s_Last) < REPEAT_WINDOW then
        m_SeenN[p_What] = (m_SeenN[p_What] or 0) + 1
        return nil
    end
    -- Forget everything rather than evict cleverly: the table is a rate limiter, not a record, and
    -- the worst case of a reset is one extra line.
    if m_SeenCount >= REPEAT_KEYS then
        m_SeenAt, m_SeenN, m_SeenCount = {}, {}, 0
    end
    if m_SeenAt[p_What] == nil then m_SeenCount = m_SeenCount + 1 end
    m_SeenAt[p_What] = s_Now
    local s_N = m_SeenN[p_What]
    m_SeenN[p_What] = nil
    if s_N and s_N > 0 then
        return ("%s  [x%d more in the last %ds]"):format(p_What, s_N, REPEAT_WINDOW)
    end
    return p_What
end

trace = function(p_What)
    pcall(function()
        p_What = repeatFilter(tostring(p_What))
        if p_What == nil then return end
        -- CLOSE IS WHAT PERSISTS. DO NOT HOLD THE HANDLE OPEN.
        --
        -- I tried keeping one handle open and flushing per line, to save four syscalls. CC's write
        -- handles do not expose flush() -- and because I guarded the call with `if h.flush then`,
        -- the absence was silent: every drone kept "logging" into a buffer that never reached disk,
        -- and the fleet's primary debugging surface went dark across sixteen drones at once, which
        -- I then spent several minutes misreading as a failed reboot.
        --
        -- So the write goes back to open/append/close, which is the only thing here that actually
        -- persists. The safe half of the optimisation stays: the two stat calls that policed the
        -- size limit ran on EVERY line and only matter occasionally, so they now run every 100th.
        -- Three syscalls a line instead of five, and the log is real.
        m_LogLines = m_LogLines + 1
        if (m_LogLines % 100) == 1 then
            if fs.exists("/drone.log") and fs.getSize("/drone.log") > TRACE_LIMIT then
                fs.delete("/drone.log")
            end
        end
        local h = fs.open("/drone.log", "a")
        if h then
            h.writeLine(("%s %s"):format(tostring(os.clock()), tostring(p_What)))
            h.close()
        end
    end)
end

-- SCREEN AND LOG, NOT ONE OR THE OTHER.
--
-- trace() writes to /drone.log and does not print; print() shows on the turtle and is not kept.
-- Nineteen genuine diagnostics here -- drift, missed heartbeats, fuel gained, trail length -- used
-- the second kind, so the numbers you most want after the fact existed only on a screen nobody was
-- looking at. A drone with a silently wrong heading walked 121 blocks the wrong way while the log
-- recorded only that it was closing the gap.
--
-- Say() is for a fact worth both: a person standing there sees it, and it survives for whoever
-- reads the log afterwards. Enforced by lua-hygiene -- a print carrying an interpolated value fails
-- the build.
Say = function(p_What)
    print(p_What)
    trace(p_What)
end


function OnGoTo(p_ID, p_Message)
    trace("GoTo received from " .. tostring(p_ID))
    local d = p_Message and p_Message.data
    if d == nil or d.pos == nil then
        trace("GoTo REFUSED: no pos")
        return false, "no pos specified"
    end

    -- Re-fix cheaply instead of setLocationFromGPS, which STEPS THE TURTLE forward and back to
    -- work out its heading. That is fine once at boot and wrong here: it is a move, so it can be
    -- blocked, and when it is the heading comes back nil and every later moveTo has no idea which
    -- way the drone is facing.
    pgps.verifyPosition()
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then
        trace("GoTo REFUSED: no position fix")
        return false, "no position fix"
    end
    x, y, z = cx, cy, cz

    m_Status = "moving"
    TaskStart()
    trace(("GoTo %s,%s,%s -> %s,%s,%s"):format(cx, cy, cz, tostring(d.pos.x), tostring(d.pos.y), tostring(d.pos.z)))
    -- The third travel path, and the one I forgot. Survey and Mine check the destination; GoTo did
    -- not -- and GoTo is what a rescue is dispatched as, so an out-of-region rescue target sent the
    -- rescuer out of region too.
    local s_Reach, s_ReachWhy = reachableTarget(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z))
    if not s_Reach then
        trace("GoTo REFUSED: " .. tostring(s_ReachWhy))
        reportTask(d, false, s_ReachWhy)
        return false, s_ReachWhy
    end
    local s_Status, s_Message = pgps.moveTo(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z))
    if s_Status == false then
        -- Fall back to flying it directly. A recall is most needed exactly where the map is
        -- thinnest, so refusing to move because the SERVER cannot plot a route is backwards.
        trace("GoTo: no mapped route (" .. tostring(s_Message) .. ") -- flying direct")
        s_Status, s_Message = pgps.flyTo(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z))
    end
    if s_Status == false and CanDig() then
        -- Last resort, and only for a drone that carries a pickaxe: cut a tunnel to the target.
        --
        -- This is the answer to the case both of the above lose: rock between here and there. The
        -- path search says "no path" because none exists yet, and flying says "wedged" because it
        -- cannot climb out. A miner is not stuck in that situation -- it is simply being asked the
        -- wrong question. The tunnel it leaves gets surveyed on the way through, so the route
        -- exists for everyone afterwards and the next drone does not have to dig it again.
        trace("GoTo: cannot fly either (" .. tostring(s_Message) .. ") -- digging a path")
        s_Status, s_Message = pgps.digTo(tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z))
    end
    TaskEnd()
    m_Status = "idle"

    -- REPORT BACK WHEN THIS IS A TASK.
    --
    -- GoTo never told TaskMan anything. That was harmless while GoTo was only ever a manual "go
    -- stand over there", and became a real fault the moment a rescue was dispatched as one: D13 dug
    -- through solid rock to D3's exact position, arrived, and went idle -- while the task stayed at
    -- 0%, still assigned, holding one of the three rescue slots against every other trapped drone
    -- in the fleet. The work was done and nothing knew it.
    --
    -- reportTask is a no-op when there is no taskId, so a hand-typed GoTo is unaffected.
    if(s_Status == false) then
        trace("GoTo FAILED: " .. tostring(s_Message))
        Distress("GoTo failed", tostring(s_Message))
        reportTask(d, false, tostring(s_Message or "could not reach position"))
        return false, tostring(s_Message or "could not reach position")
    end

    if d.heading ~= nil then
        m_Status = "rotation"
        pgps.turnTo(d.heading)
        m_Status = "idle"
    end
    trace("GoTo done")
    local s_Arrived = {x = d.pos.x, y = d.pos.y, z = d.pos.z}
    reportTask(d, true, nil, {arrived = s_Arrived})
    return true, {arrived = s_Arrived}
end


-- Survey: fly a lawnmower pattern, hugging the ground, and let detectAll do the mapping.
--
-- Every pgps move already calls detectAll(), so surveying is not a separate act of measurement --
-- it is just going somewhere and having gone there recorded. What matters is the flight profile.
--
-- Flying at a fixed altitude would be useless: detectDown only reports the single block beneath
-- the turtle, so a high pass records one flat plane and no heights at all. Probing the full column
-- at every cell is the other extreme -- a 32x32 area with 20-block probes is ~40,000 moves, twice
-- the drone's entire fuel tank.
--
-- So it follows the terrain: step forward, climb if something blocks the way, sink if the ground
-- falls away. One or two moves per cell, and the block below is the surface at every step, which
-- is exactly the height field the map wants.
-- HOVER, DON'T HUG.
--
-- settle() used to descend until the block below was solid, which put the drone directly on the
-- surface. That is the worst altitude to travel at: every bump, dune and tree in the way has to be
-- climbed and then dropped off again, and a scout crossing broken ground spent most of its moves
-- going up and down rather than forward.
--
-- The scan does not need it. A geo scanner reads a sphere of radius 8, so from three blocks up
-- there are still five blocks of rock inside the sphere -- essentially the same reading, for a
-- fraction of the manoeuvring. Anything that genuinely must touch down (a miner starting a shaft)
-- passes 0 and gets the old behaviour.
local HOVER = 3

-- IDEMPOTENT, which the first version was not.
--
-- Hovering three blocks up means detectDown is FALSE, so a second call would happily descend to the
-- ground again and climb straight back -- six moves, zero net displacement, repeated on every scan
-- cell. Watching a drone bob up and down on the spot for ever is exactly what that looks like, and
-- it is the same shape as the earlier bug where a post-move settle fought stepForward's climb.
--
-- Remembering where we settled is the fix: if the drone has not moved since, there is nothing to do.
local m_Settled = nil

local function settle(p_MaxDrop, p_Hover)
    local s_Hover = p_Hover or HOVER

    local cx, cy, cz = pgps.getCachedPosition()
    if cx ~= nil and m_Settled ~= nil
       and m_Settled.x == cx and m_Settled.y == cy and m_Settled.z == cz then
        return 0        -- already settled here; moving would only undo it
    end

    local s_Drops = 0
    while s_Drops < p_MaxDrop and not turtle.detectDown() do
        if not pgps.down() then break end
        s_Drops = s_Drops + 1
    end
    -- Back off to the hover height. Only as far as it actually goes -- if something is in the way
    -- above, sitting lower is fine and far better than refusing to scan at all.
    for _ = 1, s_Hover do
        if turtle.detectUp() or not pgps.up() then break end
        s_Drops = s_Drops - 1
    end

    local nx, ny, nz = pgps.getCachedPosition()
    if nx ~= nil then m_Settled = {x = nx, y = ny, z = nz} end
    return s_Drops
end

-- Step forward, climbing over whatever is in the way -- and then COMING BACK DOWN.
--
-- The descent is the whole point. Without it every obstacle ratcheted the drone permanently
-- upward: a survey walks hundreds of forward steps, each dune or wall added a few blocks of
-- altitude, nothing ever gave any back, and the scout ended up at y=117 diligently scanning empty
-- sky. It looked like the scanner was broken or the grid was wrong; it was neither. A scout that
-- drifts above the terrain is not surveying anything, it is just burning fuel politely.
local function stepForward(p_MaxClimb)
    local s_Climbs = 0
    while true do
        local s_Ok, s_Why = pgps.forward()
        if s_Ok then break end

        -- CLIMBING ONLY HELPS OVER A BLOCK.
        --
        -- forward() refuses for two quite different reasons: something is in the way, or we are
        -- not allowed to go there (the operating bounds, or no position fix). Treating the second
        -- as an obstacle makes the drone climb against the boundary -- and since the boundary is
        -- vertical, it never clears it. D3 rode the map edge all the way to y=200 doing exactly
        -- this, scanning empty sky the whole way. Going up cannot fix a refusal that is not about
        -- height.
        if s_Why == "out of bounds" or s_Why == "position unverified" then
            return false, s_Why
        end

        if s_Climbs >= p_MaxClimb then return false, "obstacle taller than " .. p_MaxClimb end
        if not pgps.up() then return false, "blocked above" end
        s_Climbs = s_Climbs + 1
    end

    -- Give back exactly what was taken, and only into open air -- never dig down to get there,
    -- and never descend further than we climbed, so this cannot walk a drone into a ravine.
    for _ = 1, s_Climbs do
        if turtle.detectDown() then break end
        if not pgps.down() then break end
    end
    return true
end

-- A scout carries a geo scanner instead of a pickaxe -- a turtle has only two upgrade slots and
-- the wireless modem is not negotiable, so seeing further costs the ability to dig.
--
-- It is worth it by a wide margin. scan(r) returns every non-air block within radius r in ONE
-- call: radius 8 is free (AdvancedPeripherals scanBlocksMaxFreeRadius), covers a 17x17x17 cube,
-- and is limited only by a 2s cooldown. detectAll manages three blocks per move. Verified in
-- world: scan(4) returned 62 blocks, relative coordinates, air already filtered out.
function Scanner()
    return peripheral.find("geo_scanner") or peripheral.find("geoScanner")
end

local SCAN_COOLDOWN = 2.2   -- config says 2000ms; a little margin beats a failed call

-- Record one scan into the pending delta. Coordinates come back relative, so they are offset by
-- wherever pgps thinks we are -- which is why this needs a GPS fix to be worth anything.
-- A scan reports only the blocks that EXIST. Recording just those teaches the map where walls are
-- and never where space is -- and a_star cannot route through a cell it has not been told is empty,
-- so "unknown" is impassable. The result was a world model that could not answer the one question
-- navigation asks. D3 flew to y=200 scanning the whole way and the server still had no path back
-- down, because the sky it had flown through was unknown rather than air.
--
-- The emptiness is free information: the scanner already guarantees it returned every non-air block
-- in the cube, so anything it did NOT return is air, definitionally.
--
-- Air is filled in over a SMALLER cube than the solids are read from. A radius-8 scan is 4,913
-- cells and marking them all would put thousands of observations per scan onto rednet every 2.2s,
-- which is a lot of traffic to describe an empty sky. Radius 4 is 729 cells -- enough to give the
-- pathfinder a genuinely navigable corridor around wherever the drone has been -- while solids keep
-- the full radius, because knowing about a distant wall is worth more than knowing about distant
-- nothing.
local function absorbScan(p_Scanner, p_Radius)
    local s_Blocks, s_Err = p_Scanner.scan(p_Radius)
    if not s_Blocks then
        return 0, tostring(s_Err)
    end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then
        return 0, "no position fix"
    end

    -- DRONES ARE NOT TERRAIN.
    --
    -- The scanner returns every non-air block, which includes the other turtles -- so each drone
    -- recorded its neighbours into the world map as permanent blocks. They then moved, and the
    -- record stayed: 189 turtle blocks in a map of a fleet of five, drawn on the /map page as white
    -- cubes floating in mid-air at every spot a drone once happened to be standing.
    --
    -- Worse than cosmetic: a_star routes around them, so the fleet was pathing around ghosts of
    -- itself. Skipped entirely -- a moving thing has no business in a map of static ground, and
    -- fleet.status already says where the drones are.
    local function isDrone(p_Name)
        return type(p_Name) == "string" and p_Name:find("turtle", 1, true) ~= nil
    end

    -- Index the solids first so the air pass can skip them.
    local s_Solid = {}
    for _, b in ipairs(s_Blocks) do
        if isDrone(b.name) then goto skipblock end
        local idx = (cx + b.x) .. ":" .. (cy + b.y) .. ":" .. (cz + b.z)
        s_Solid[idx] = true
        -- Detail shaped like {turtle.inspect()} so it matches what detectAll writes and what the
        -- renderer reads: entry [2] is the block table with .name.
        pgps.noteObservation(idx, 1, {true, {name = b.name}})
        ::skipblock::
    end

    -- Only claim emptiness from a CONFIRMED position. Solids are additive and a drifted one is
    -- corrected by the next scan; air is subtractive -- it prunes the block index -- so writing 729
    -- of them from a position the drone only believes it is at would erase real map data over a
    -- wide area. Drift is not hypothetical: D3 was found 24 blocks from where it reported.
    if not pgps.positionVerified() then
        return #s_Blocks
    end

    -- MATCH THE SCAN RADIUS. RECORDING SOLIDS WIDER THAN AIR ONLY EVER ADDS BLOCKS.
    --
    -- This cleared air within 4 while the scanner reports solids within 8. The shell between them
    -- is write-only: a cell out there can be marked solid by a scan and can NEVER be cleared by
    -- one, so every phantom in that band is permanent no matter how many times a scout flies past.
    -- Eight-cubed against four-cubed is eight times more volume gaining blocks than shedding them,
    -- which is why re-surveying visibly failed to repair the map -- it was structurally incapable
    -- of it.
    --
    -- Air is subtractive and therefore only written from a CONFIRMED position (checked above), so
    -- widening it is safe in the way that matters: it cannot erase real data on a drifted guess.
    -- It costs more observations per scan -- 17 cubed rather than 9 -- and that is the honest price
    -- of a map that can be corrected as well as extended.
    local s_R = p_Radius
    for dx = -s_R, s_R do
        for dy = -s_R, s_R do
            for dz = -s_R, s_R do
                local idx = (cx + dx) .. ":" .. (cy + dy) .. ":" .. (cz + dz)
                if not s_Solid[idx] then
                    pgps.noteObservation(idx, 0)
                end
            end
        end
    end

    return #s_Blocks
end

-- What this drone is equipped to do. A turtle has two upgrade slots and the wireless modem takes
-- one, so the other slot decides its trade: a geo scanner makes it a scout, anything else (in
-- practice a pickaxe) makes it a miner. Reported rather than assumed, because DroneMan cannot see
-- a drone's upgrades -- it previously hardcoded every drone as "peasant".
function Role()
    if Scanner() then return "scout" end
    -- A chunky turtle keeps its own chunk ticking. Verified in world: it exposes peripheral type
    -- "chunky". That makes it the fleet's freedom of movement -- drones outside a forceloaded
    -- chunk simply stop, silently, wherever they happened to be.
    if peripheral.find("chunky") then return "loader" end
    -- A crafting table is an upgrade like any other, and it is what makes a drone able to PRODUCE
    -- rather than only extract. Reported so TaskMan can route craft work to a drone that can
    -- actually do it, instead of discovering the hard way that turtle.craft is nil.
    if IsCrafter() then return "crafter" end
    return "miner"
end

-- How much FUEL a gather may burn on candidates that return nothing, before giving up.
--
-- This was a COUNT — three consecutive unreachable candidates ended the job — and the reasoning was
-- that candidates are sorted nearest-first, so consecutive misses mean the rest are further and
-- certainly worse. That holds for ore buried in rock. It is simply false for anything on the
-- SURFACE: trees are scattered, and reachability does not decrease with distance. A log high in a
-- canopy fails while one at ground level twenty blocks further is trivial.
--
-- The consequence was total. The first miss collapsed the check budget to three, so a gather that
-- happened to start on two awkward targets abandoned the job with twenty good ones still queued.
-- oak_log sat at 2 in storage for an entire session — with 1,071 logs mapped and 19 of the 40
-- nearest inside the operating circle — while `gather:oak_log` was dispatched over and over and
-- returned "took nothing from 2 candidates (2 unreachable)" every time. That is what starved the
-- charcoal chain, which is the settlement's only renewable fuel.
--
-- What the original comment actually cared about is right here in its own words: "several hundred
-- fuel spent to gather zero ore, and the drone then goes dry". So bound THAT, directly. A miss that
-- cost nothing (a surface target the drone could not path to from where it stood) may be skipped
-- freely; a miss that burned a digTo budget through rock counts heavily against the allowance. Same
-- protection against the fuel spiral, without assuming the world is sorted.
local GATHER_MISS_FUEL_BUDGET = 600

-- Candidates that must be attempted before the miss budget may end a gather. The map contains
-- ghosts -- entries recorded while a drone was 53 to 76 blocks from where it believed it was --
-- so the first pick failing is ordinary, not a signal. Sampled against the server: four of six
-- oak_log targets real, two air.
local GATHER_MIN_CHECKS = 3

-- Account for one unreachable candidate and decide whether the gather should stop.
--
-- Returns the updated miss-spend total and the updated check cap. Written as a helper taking and
-- returning both so the CALL SITE gains no branches: the gather body is the largest function in
-- this file and sits directly on the complexity gate, and the accounting has to live somewhere.
--
-- Stopping is expressed by returning s_Checked as the new cap, which trips the loop's existing
-- `s_Checked < s_MaxChecks` guard -- no second exit condition to keep in sync.
-- Record what we can actually SEE of the column at x,z while hovering one block above y.
--
-- Called after arriving at a gather target that turned out to be wrong. Three cells are genuinely
-- observable from that position and each is a real reading:
--   y+1  our own cell -- we are standing in it, so it is air by definition
--   y+2  inspectUp
--   y    inspectDown is the caller's business (it already noted it); we skip it here
--
-- A GLOBAL because the gather body sits far below and this file's convention for anything crossing
-- that distance is a global -- a `local` moved above its declaration by a later edit becomes a
-- silent nil lookup, which has cost nine outages here.
--
-- Every branch lives in here rather than at the call site: the gather body is the largest function
-- in the file and sits on the complexity gate.
-- RECORD THE CELLS WE ACTUALLY LOOKED AT, WHICH DEPENDS ON WHICH SIDE WE CAME FROM.
--
-- This assumed the drone was always hovering at p_Y + 1 looking down, because every gather approach
-- targeted t.y + 1. That is no longer true: a canopy log has leaves above it, so wood is now
-- approached from BELOW, and calling this from down there would write two lies into the map --
-- "air" at p_Y + 1, a cell it never looked at and which is usually the leaves that forced the
-- approach in the first place, and inspectUp's reading (the TARGET) filed at p_Y + 2.
--
-- Both would be indistinguishable from real observations, and this map is already carrying ghosts
-- from the era when drones were 53 to 76 blocks out. The whole point of this function is to PRUNE
-- ghosts; a version that invents them is worse than no version at all.
function NoteSeenColumn(p_X, p_Y, p_Z, p_FromBelow)
    -- Our own cell: we are occupying it, so it is air. The cheapest true fact available, and
    -- exactly the one a felled trunk leaves behind as a ghost.
    local s_Own  = p_FromBelow and (p_Y - 1) or (p_Y + 1)
    -- The cell on the far side of us, seen by looking away from the target.
    local s_Far  = p_FromBelow and (p_Y - 2) or (p_Y + 2)
    local s_Look = p_FromBelow and turtle.inspectDown or turtle.inspectUp

    pcall(pgps.noteObservation, p_X .. ":" .. s_Own .. ":" .. p_Z, 0)

    local s_Ok, s_Blk = s_Look()
    local s_Key = p_X .. ":" .. s_Far .. ":" .. p_Z
    if s_Ok and s_Blk and s_Blk.name then
        pcall(pgps.noteObservation, s_Key, 1, {true, {name = s_Blk.name}})
    else
        pcall(pgps.noteObservation, s_Key, 0)
    end
end

-- The inspect and the dig that match the face we approached on.
--
-- Kept together deliberately: reading one face and breaking another is a silent way to mine the
-- wrong block, and holding the choice in one place makes that impossible to get half-right.
function FaceTools(p_FromBelow, p_FromSide)
    if p_FromSide  then return turtle.inspect,     DigForward end
    if p_FromBelow then return turtle.inspectUp,   DigUp end
    return turtle.inspectDown, DigDown
end

-- Stand beside a target and face back at it. Returns the move result, or false.
--
-- Above and below together cannot touch a mid-trunk log: the block over it is more trunk and the
-- block under it is trunk or the dirt the tree stands in. Only the four horizontal neighbours are
-- air. That is not an edge case -- of the wood this settlement has indexed, 52% sits at y=62-70,
-- which is trunk at ground level, against 45% canopy. Approaching only vertically wrote off half
-- the forest, and wood is the settlement's only renewable fuel.
--
-- The heading is the opposite of the offset: standing one block EAST means looking WEST to see it.
--
-- Its own function because the gather loop is the largest thing in this file and the complexity
-- gate is right to refuse to let it grow.
local SIDE_APPROACHES = {
    {dx =  1, dz =  0, face = "west"},
    {dx = -1, dz =  0, face = "east"},
    {dx =  0, dz =  1, face = "north"},
    {dx =  0, dz = -1, face = "south"},
}

function ApproachFromSide(p_Target, p_FlyBudget)
    for _, s_Side in ipairs(SIDE_APPROACHES) do
        local x, z = p_Target.x + s_Side.dx, p_Target.z + s_Side.dz
        local s_Try = pgps.moveTo(x, p_Target.y, z)
        if s_Try == false then s_Try = pgps.flyTo(x, p_Target.y, z, p_FlyBudget or 64) end
        if s_Try ~= false then
            pgps.turnTo(pgps.HEADINGS[s_Side.face])
            return s_Try
        end
    end
    return false
end

function GatherMissBudget(p_FuelBefore, p_Spent, p_Checked, p_MaxChecks)
    local s_Now = turtle.getFuelLevel()
    local s_Cost = 0
    if type(p_FuelBefore) == "number" and type(s_Now) == "number" and p_FuelBefore > s_Now then
        s_Cost = p_FuelBefore - s_Now
    end
    local s_Total = (p_Spent or 0) + s_Cost
    -- ONE BAD CANDIDATE MUST NOT END A JOB WITH 191 OTHERS IN IT.
    --
    -- The budget stops the sweep once misses have cost GATHER_MISS_FUEL_BUDGET, which is right --
    -- a gather that is only burning fuel should stop. But it was checked with no floor on how many
    -- candidates had been TRIED, so a single expensive miss consumed the whole allowance and
    -- collapsed the cap to one:
    --
    --   gather: 1/192 checked, 0 taken, 0 unreachable
    --   gather: could not reach -483,75,57
    --   JOB Gather FAILED took nothing from 1 candidates (1 unreachable)
    --
    -- 191 untried targets abandoned because the first pick was bad -- and it was bad in a way that
    -- is expected here: -483,75,57 is AIR. The map holds ghosts, recorded while drones believed
    -- they were 53 to 76 blocks from where they actually were, so a share of every target list is
    -- fiction. Sampled by hand against the server: four of six oak_log entries real, two air.
    --
    -- With two thirds of targets genuine, trying a handful finds wood; trying one is a coin flip
    -- the settlement loses. So the budget cannot end the sweep until GATHER_MIN_CHECKS candidates
    -- have actually been attempted. The fuel ceiling still applies after that.
    if s_Total >= GATHER_MISS_FUEL_BUDGET and (p_Checked or 0) >= GATHER_MIN_CHECKS then
        return s_Total, p_Checked
    end
    return s_Total, p_MaxChecks
end

-- SAVE / UPDATE / RESUME
--
-- An update is a reboot, and a reboot used to mean a drone forgot what it was doing. A survey
-- halfway through simply stopped, its unsent observations went with it, and nothing anywhere
-- recorded that the work had been abandoned -- the task still looked assigned.
--
-- So before standing down: flush observations to MapServer, write down the job, tell DroneMan.
-- After booting: pick the job back up. The file lives in the computer's own directory, which
-- survives reboots, so it does not depend on any server being reachable at the wrong moment.
local RESUME_FILE = "/resume.txt"
-- CRUISE_Y (110) WAS HERE, AND IS GONE ON PURPOSE. DO NOT PUT IT BACK.
--
-- It existed so a drone that could not reach a target could fly to y=110, cross above the terrain,
-- and drop down. That is what you do when you have no map. This settlement HAS a map -- MapServer
-- holds 262,000 named blocks and runs A* over them -- so the climb was never buying a route, it was
-- buying a way to ignore the router.
--
-- It is also the most expensive move a drone can make: ~90 fuel for the round trip before a single
-- block of horizontal progress, the GPS fix lost on the way up (four audible hosts do not follow it
-- to 110), and the descent dead-reckoned. D15 left base with 634 fuel for a tree NINETEEN blocks
-- away, logged "boxed in -- climbing to 110 to cross", and was found at y=102 with 322 fuel and no
-- logs. That trip costs under 150 at ground level.
--
-- The only climbing left is climbForFix, which gains height for a reason that height actually
-- solves -- a GPS fix needs four audible hosts and rock does not carry radio -- and which is
-- bounded by SKY_FIX_CEILING and refuses outright when the fuel will not pay for the return.
m_Job = nil          -- {verb, data} for whatever is currently running
-- Forward declaration. resumeJob above dispatches through this table, and the table itself is
-- defined near the bottom of the file once every handler exists. Without the declaration here the
-- name in resumeJob would compile to a GLOBAL lookup and read nil -- the same scoping trap that
-- made pgps.mayStep refuse every direction for every stranded drone.
local m_DroneEvents

local function saveResume()
    if m_Job == nil then
        if fs.exists(RESUME_FILE) then fs.delete(RESUME_FILE) end
        return
    end
    local h = fs.open(RESUME_FILE, "w")
    if h then h.write(textutils.serialize(m_Job)) h.close() end
end

-- RESUMING A JOB IS NOT THE SAME AS RESTARTING IT.
--
-- The resume record held {verb, data} -- the ORIGINAL order -- so a drone that came back up re-ran
-- the job from the beginning. For a gather that means re-walking a list of forty candidates it had
-- already worked through: "0/96 checked, 0 taken" again, on ground it had already stripped. A
-- MainFrame restart broadcasts INIT, which stands the whole fleet down, so every deploy threw away
-- the fleet's in-flight progress and started it over. That is why the log gather kept going back to
-- zero, and how sixteen already-cut logs were lost.
--
-- Jobs that can say where they got to now record it here. It rides along in the same file and is
-- handed back to the handler as d.resume, so a job resumes mid-list instead of mid-nothing.
--
-- Throttled: this writes a file, and a gather calls it once per candidate.
local m_ProgressAt = 0
function SaveProgress(p_Progress, p_Force)
    if m_Job == nil then return end
    m_Job.progress = p_Progress
    local s_Now = os.clock()
    if not p_Force and (s_Now - m_ProgressAt) < 10 then return end
    m_ProgressAt = s_Now
    saveResume()

    -- AND TELL TASKMAN. This wrote progress to the drone's own resume file and nowhere else, so
    -- every task in the queue read 0% until the moment it completed -- there was no such thing as a
    -- half-finished task from outside. That is why nothing could depend on PARTIAL progress: a scan
    -- at y=12 had to wait for the whole shaft to finish rather than for the dig to pass y=12, which
    -- serialises two jobs that should overlap and leaves a scout idle for the length of a dig.
    if m_Job.data and m_Job.data.taskId then
        pcall(function()
            PowNet.SendToServer("TaskMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL,
                "TaskProgress", {id = m_Job.data.taskId, progress = p_Progress}))
        end)
    end
end

local function loadResume()
    if not fs.exists(RESUME_FILE) then return nil end
    local h = fs.open(RESUME_FILE, "r")
    if not h then return nil end
    local s = h.readAll()
    h.close()
    fs.delete(RESUME_FILE)
    return textutils.unserialize(s)
end

function OnShutdown(p_Reason)
    -- Observations first: they are the expensive thing to re-gather, and a scout can have
    -- thousands of blocks pending between 30s upload cycles.
    pcall(UploadWorld)
    saveResume()
    m_Status = "updating"
    pcall(SendHeartBeat)
    Say("standing down for " .. tostring(p_Reason) .. (m_Job and (", will resume " .. tostring(m_Job.verb)) or ""))
    -- Close the log handle we now hold open (see trace). Each line is flushed as it is written, so
    -- nothing is lost either way -- but leaving a write handle dangling across a reboot is the kind
    -- of thing that bites much later, in a way that looks like a corrupt log rather than a leak.
    CloseTrace()
end

-- WORK ALREADY DONE, REMEMBERED ACROSS A REBOOT. FOR EVERY JOB, NOT ONE.
--
-- MainFrame broadcasts INIT on every boot, which stands the whole fleet down -- so any deploy
-- interrupts whatever every drone is doing. Resuming the JOB was not enough: the job restarted from
-- its original order and re-walked work it had already finished. A gather went back to "0/96
-- checked, 0 taken" on ground it had already stripped, every single time.
--
-- The obvious fix is to teach the gather to remember. That is the trap this codebase keeps falling
-- into: fix it in the one place it was noticed, leave Dig, Build, Lumber, Haul and Mine to be
-- discovered separately later. So the memory lives here instead, as one small thing any job adopts
-- in two lines, and the next job written gets it without knowing it exists.
--
-- Works for a fixed list and for a growing worklist alike: it is a set of keys, not an index.
function Resumable(p_Data)
    local s_Seen, s_Extra = {}, nil
    if type(p_Data) == "table" and type(p_Data.resume) == "table" then
        for k in pairs(p_Data.resume.seen or {}) do s_Seen[k] = true end
        s_Extra = p_Data.resume.extra
    end
    local s_Self = {}
    function s_Self.done(p_Key) return s_Seen[p_Key] == true end
    function s_Self.mark(p_Key, p_ExtraNow)
        s_Seen[p_Key] = true
        s_Extra = p_ExtraNow ~= nil and p_ExtraNow or s_Extra
        SaveProgress({seen = s_Seen, extra = s_Extra})
    end
    function s_Self.extra() return s_Extra end
    function s_Self.count()
        local n = 0
        for _ in pairs(s_Seen) do n = n + 1 end
        return n
    end
    function s_Self.announce(p_What)
        local n = s_Self.count()
        if n > 0 then trace(("%s: resuming -- %d item(s) already done"):format(p_What, n)) end
        return n
    end
    return s_Self
end

-- Re-run whatever we were doing before the update, once the fleet is back up.
local function resumeJob()
    local s_Job = loadResume()
    if s_Job == nil then return end
    Say("resuming " .. tostring(s_Job.verb))
    os.sleep(5)                 -- let the servers finish coming up before talking to them
    -- DISPATCH THROUGH THE HANDLER TABLE, NOT AN IF-CHAIN.
    --
    -- This listed Survey, Scan and Dig. The drone accepts fourteen verbs, so Mine, Gather, Haul,
    -- Craft, Build, Lumber, Relay, GoTo and Rescue were all saved to the resume file on stand-down
    -- and then silently thrown away on the way back up -- no error, no log line, just a drone that
    -- woke with nothing to do.
    --
    -- That is not a rare path. MainFrame broadcasts INIT on every boot and every module reload, and
    -- INIT is a fleet-wide stand-down: ALL 23 drones save a resume and reboot. So one MainFrame
    -- restart quietly cancelled most of the fleet's work, which is what "why is everything idle"
    -- has been. D21's log is the whole story repeated verbatim: "status updating left behind with
    -- no job running -- clearing to idle".
    --
    -- Reading the verb out of m_DroneEvents means resume can never fall behind the handler list
    -- again, because there is no second list to keep in sync.
    local s_Entry = m_DroneEvents and m_DroneEvents[s_Job.verb]
    if s_Entry and s_Entry.func then
        -- Hand back whatever the job recorded about how far it got. Handlers that do not use it
        -- simply ignore the field and restart as before.
        local s_Data = s_Job.data or {}
        s_Data.resume = s_Job.progress
        pcall(s_Entry.func, 0, {data = s_Data})
    else
        trace(("resume: no handler for verb %s -- dropping the job"):format(tostring(s_Job.verb)))
    end
end

-- waitForAny ends the moment ANY branch returns, so this branch must never return -- otherwise a
-- drone with nothing to resume would shut its own module down the instant it booted.
local function resumeBranch()
    pcall(resumeJob)
    while true do os.sleep(3600) end
end

-- DISTRESS
--
-- A wedged drone is the normal failure of this whole system: a miner walls itself in, a hauler
-- meets another in a one-wide shaft, a builder runs out of the block it was placing. Silence is
-- the worst possible response -- the fleet looks busy while nothing moves, and finding the one
-- that stopped means checking each in turn.
--
-- So a drone that gives up says where it is, what it was doing, and why. m_Stuck also rides on
-- every heartbeat, so the fleet view shows it even if this message is lost.
m_Stuck = nil

-- REPORTING A PROBLEM IS NOT THE SAME AS BEING OUT OF SERVICE.
--
-- This set m_Status = "stuck" and nothing ever cleared it except an explicit abort. So a drone that
-- merely failed ONE order -- arriving a single block short of a target, say -- was marked
-- permanently unavailable: TaskMan will not offer work to a drone that is not idle, so it sat out
-- every subsequent job while being in perfect health, parked at its dock with full fuel.
--
-- D3 did exactly that. It completed a 60-block recall, stopped one block from the mark, reported
-- "GoTo failed", and was thereby retired.
--
-- The reason is worth recording and travels on the heartbeat as m_Stuck. Availability is a separate
-- question, and the answer to it is "is this drone doing something right now" -- which callers set
-- around their own work.
-- DISTRESS MEANS "I CANNOT MOVE", NOT "THAT DID NOT WORK".
--
-- Distress marks the drone stuck, and stuck is what the rescue pass looks for. RunJob called it on
-- ANY job failure -- so a craft that could not get its ingredients reported the CRAFTER as stuck,
-- and TaskMan dutifully queued a rescue for a drone sitting perfectly healthy on its dock with
-- 19,000 fuel. A miner was then pulled off real work to go dig out a drone that was not buried.
--
-- The distinction is mobility, not success: a walled-in drone, one with no position fix, or one out
-- of fuel needs another drone to come to it. A task that cannot be satisfied needs a different
-- task. p_Mobility says which this is; only the first marks the drone stuck.
function Distress(p_Reason, p_Detail, p_Mobility)
    local hx, hy, hz = pgps.getCachedPosition()
    if p_Mobility ~= false then m_Stuck = p_Reason end
    local s_Data = {
        reason = p_Reason,
        detail = p_Detail,
        pos = (hx and {x = hx, y = hy, z = hz}) or nil,
        fuel = turtle.getFuelLevel(),
        -- Tell the server which kind this is, or it marks the drone stuck on our behalf and the
        -- distinction we just made here is thrown away one hop later.
        mobility = (p_Mobility ~= false),
    }
    Say("DISTRESS: " .. tostring(p_Reason) .. " " .. tostring(p_Detail))
    PowNet.SendToServer("DroneMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Distress", s_Data))
end

function ClearDistress()
    m_Stuck = nil
end

-- Get unstuck without help where possible: straight up is almost always free, and a drone that
-- can climb out of a hole it dug does not need rescuing.
function OnRescue(p_ID, p_Message)
    local s_Up = tonumber((p_Message.data or {}).up) or 6
    local s_Climbed = 0
    for _ = 1, s_Up do
        if not pgps.up() then break end
        s_Climbed = s_Climbed + 1
    end
    ClearDistress()
    m_Status = "idle"
    SendHeartBeat()
    return true, {message = "climbed " .. s_Climbed .. " and cleared distress"}
end

function OnScan(p_ID, p_Message)
    local s_Sc = Scanner()
    if not s_Sc then return false, "no geo scanner on this drone" end
    local s_R = tonumber((p_Message.data or {}).radius) or 8
    local s_N, s_Err = absorbScan(s_Sc, s_R)
    if s_N == 0 and s_Err then return false, s_Err end
    UploadWorld()
    return true, {message = "scanned " .. s_N .. " blocks at radius " .. s_R}
end

-- Report how a job ended when the job is NOT one of the RunJob verbs.
--
-- RunJob reports for the four that use it. Survey predates it and does not, so a survey that
-- failed left its task at zero progress for ever: the queue reclaimed it, handed it straight back
-- to the only scout, the scout failed again, and round it went. From outside the queue looked full
-- and the fleet looked idle -- which is exactly what it was, in a loop.
-- Give the slot back. Called when the drone leaves to work, which is the moment it stops occupying
-- the berth -- not when it feels like it, and not never, which is what happened before.
local function undock()
    if not m_Docked then return end
    m_Docked = false
    pcall(function()
        PowNet.SendToServer("DockingMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "FreeDocking",
            {id = tostring(os.getComputerLabel() or os.getComputerID())}))
    end)
    trace("undocked -- slot released")
end

-- Take a slot, nearest to wherever we are now, and go and sit in it facing the column so the refuel
-- routine's turtle.suck() reaches the fuel inside.
local function dockNow()
    local cx, cy, cz = pgps.getCachedPosition()
    local s_Res = PowNet.sendAndWaitForResponse("DockingMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "AllocateDocking",
            {id = tostring(os.getComputerLabel() or os.getComputerID()),
             pos = (cx ~= nil) and {x = cx, y = cy, z = cz} or nil}),
        PowNet.SERVER_PROTOCOL, 5)
    if type(s_Res) ~= "table" or s_Res.pos == nil then
        trace("dock refused: " .. tostring(type(s_Res) == "table" and s_Res.message or s_Res))
        return false, "no slot"
    end
    m_Status = "docking"
    if pgps.moveTo(s_Res.pos.x, s_Res.pos.y, s_Res.pos.z) == false then
        if pgps.flyTo(s_Res.pos.x, s_Res.pos.y, s_Res.pos.z) == false then
            -- Could not get there, so do not hold a berth we are not standing in.
            m_Docked = true ; undock()
            m_Status = "idle"
            return false, "could not reach the dock"
        end
    end
    if s_Res.heading ~= nil then pgps.turnTo(s_Res.heading) end
    m_Docked = true
    trace(("docked at %s,%s,%s"):format(tostring(s_Res.pos.x), tostring(s_Res.pos.y), tostring(s_Res.pos.z)))
    return true, {pos = s_Res.pos}
end

function OnDock(p_ID, p_Message)
    local ok, res = dockNow()
    if not ok then return false, res end
    -- Refuel while we are here. Sitting in a berth facing an inventory full of coal and not taking
    -- any is the whole reason the plus pattern exists.
    pcall(TryRefuel)
    m_Status = "docking"
    SendHeartBeat()
    return true, res
end

-- REFUSE AN IMPOSSIBLE DESTINATION BEFORE SETTING OFF, NOT AFTER.
--
-- A survey task left over from the previous world still pointed at -35,50,-90. D2 accepted it and
-- flew toward it until it reached the edge of the operating region, then sat at the boundary 76
-- blocks from the modules -- out of radio range, unable to report, reading as lost. The task was
-- impossible the moment it was handed over, and nothing checked.
--
-- Checking costs one comparison and turns a lost drone into a failed task, which TaskMan already
-- knows how to retire: three attempts and it gives up.
reachableTarget = function(x, y, z)
    if x == nil or z == nil then return true end          -- an omitted axis means "wherever I am"
    local s_B = pgps.getBounds()
    local s_C = s_B and s_B.chunks
    if type(s_C) ~= "table" then return true end          -- no bounds known: do not invent a refusal
    for _, r in ipairs(s_C) do
        if x >= r.minx and x <= r.maxx and z >= r.minz and z <= r.maxz then return true end
    end
    return false, ("target %s,%s,%s is outside the operating region"):format(
        tostring(x), tostring(y), tostring(z))
end

reportTask = function(p_Data, p_Ok, p_Reason, p_Result)
    if p_Data == nil or p_Data.taskId == nil then return end
    pcall(function()
        PowNet.SendToServer("TaskMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "TaskDone",
            {id = p_Data.taskId, ok = p_Ok and true or false,
             reason = (not p_Ok) and tostring(p_Reason) or nil,
             result = p_Ok and p_Result or nil}))
    end)
end

function OnSurvey(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_W    = tonumber(d.w)    or 16
    local s_H    = tonumber(d.h)    or 16
    -- Generous, because the entire value of a scan is being NEAR the ground. Twenty-four is not
    -- enough to come down from cruising height over low terrain, and a drone that stops short spends
    -- the rest of the sweep scanning sky.
    local s_Drop = tonumber(d.drop) or 64
    local s_Climb= tonumber(d.climb) or 8

    if unavailableReason() then
        -- Busy is NOT a failure of the task -- it will be offered again -- so it is not reported.
        return false, "busy"
    end

    -- Go where the survey was ORDERED, not wherever the scout happens to be parked.
    --
    -- Without this a scan always started at the dock, which is why surveying could never find iron:
    -- the scanner reaches 8 blocks and the ore is fifty below. Sending the scout down a shaft a
    -- miner has already cut is the whole point of pairing them.
    if d.pos and d.pos.x then
        -- MARK THE JOB AS RUNNING BEFORE THE TRAVEL, not after it.
        --
        -- TaskStart was only called once the scanning began, so `executing` was false for the whole
        -- flight to the site -- which is most of the job. Two things then went wrong at once: the
        -- stale-status guard saw a "moving" label with nothing executing and helpfully cleared it to
        -- idle, so a scout in mid-flight advertised itself as available; and TaskMan, seeing an idle
        -- drone holding a task, reclaimed and reassigned it. The scout was doing exactly what it was
        -- told and was continuously interrupted for looking like it wasn't.
        TaskStart()
        m_Status = "moving"
        -- An omitted Y means "come across at whatever height you are already at", which is both
        -- reachable and close to the ground the scan actually wants. settle() drops to the surface
        -- on arrival, so there is nothing to gain by naming an altitude here and a long, often
        -- unpathable climb to lose.
        local s_Ty = tonumber(d.pos.y)
        if s_Ty == nil then
            local _, cy = pgps.getCachedPosition()
            s_Ty = cy
        end
        -- AND IF WE STILL HAVE NO ALTITUDE, SAY SO RATHER THAN TRAVEL TO nil.
        --
        -- The fallback above borrows the drone's own y -- which is nil for a drone that has no
        -- position at all, and a scout sent to scan at y=12 is exactly that: underground, out of GPS
        -- coverage, dead-reckoning lost. So s_Ty stayed nil, every mover was handed nil, and the
        -- task failed with "could not reach -484,nil,60" and was immediately requeued. D19 and D20
        -- burned eighteen minutes each repeating that, reporting "working" throughout.
        --
        -- One attempt to re-fix, because surfacing is the only thing that can supply the answer, and
        -- then an honest failure. A task that cannot state where it is going must not be retried.
        if s_Ty == nil then
            pgps.verifyPosition(true)
            local _, cy2 = pgps.getCachedPosition()
            s_Ty = cy2
        end
        if s_Ty == nil then
            TaskEnd()
            m_Status = "idle"
            trace("survey: no altitude to aim at and no position fix to borrow one from -- refusing")
            Distress("survey without a position", "cannot resolve a target altitude")
            reportTask(d, false, "no position fix, so no survey altitude")
            return false, "no position fix, so no survey altitude"
        end

        -- moveTo, then FLY. Travelling at the drone's own altitude is right when it is in the open
        -- and wrong when it is underground: the destination at y=49 is solid rock, there is no path
        -- to it, and a scout carries a scanner instead of a pickaxe so it cannot make one. Scouts
        -- descend into shafts to do their job, so this is the normal case, not the exception --
        -- three of them failed the same survey over and over ("could not reach -113,nil,-24"), were
        -- reclaimed after ninety seconds, reassigned, and failed it again.
        --
        -- flyTo is greedy and climbs over what it cannot go through, which is exactly what is needed
        -- to get out of a hole and across to somewhere else. GoTo has had this fallback for a while;
        -- the survey never did.
        -- Report the Y actually being flown to, not the raw one. "could not reach -460,nil,84" has
        -- been in these logs for a long time and reads as a nil-Y bug that was in fact already
        -- handled four lines up -- so the message sent everyone looking in the wrong place.
        local s_Reach, s_ReachWhy = reachableTarget(tonumber(d.pos.x), s_Ty, tonumber(d.pos.z))
        if not s_Reach then
            TaskEnd()
            m_Status = "idle"
            trace(("survey: %s (target %s,%s,%s)"):format(
                tostring(s_ReachWhy), tostring(d.pos.x), tostring(s_Ty), tostring(d.pos.z)))
            reportTask(d, false, s_ReachWhy)
            return false, s_ReachWhy
        end
        -- ALREADY CLOSE ENOUGH? THEN SCAN, DO NOT TRAVEL.
        --
        -- Checked BEFORE the travel, not after it. The same test existed as a last resort behind
        -- moveTo, flyTo and the climb-out -- and a scout never got that far: it spent its life
        -- inside flyTo trying to reach a point in solid rock, so the fallback that would have saved
        -- it was unreachable in practice. D19 and D20 sat like that for twenty-seven minutes each
        -- while the check that resolves it was already deployed, four calls too late.
        --
        -- The scanner reaches eight blocks in every direction, so being near the region is worth
        -- most of being at its centre. If we are already in range there is nothing to travel FOR.
        local s_At = false
        do
            local cx4, _, cz4 = pgps.getCachedPosition()
            local s_R4 = tonumber(d.radius) or 8
            if cx4 then
                -- Same threshold the fallback below already used (three scan radii): "close enough
                -- that scanning here still covers ground the task cares about". A strict one-radius
                -- test would not have fired for D19, which sat twelve blocks from a target it could
                -- never occupy -- inside the useful range, outside the pedantic one.
                local s_Off = math.abs(cx4 - tonumber(d.pos.x)) + math.abs(cz4 - tonumber(d.pos.z))
                if s_Off <= s_R4 * 3 then
                    trace(("survey: already within %d blocks of the start -- scanning from here"):format(s_Off))
                    s_At = true
                end
            end
        end

        if s_At == false then
            s_At = pgps.moveTo(tonumber(d.pos.x), s_Ty, tonumber(d.pos.z))
        end
        if s_At == false then
            trace("survey: no mapped route to the start -- flying")
            s_At = pgps.flyTo(tonumber(d.pos.x), s_Ty, tonumber(d.pos.z))
        end
        -- DO NOT GO OVER THE TOP. THE SETTLEMENT HAS A PATHFINDER.
        --
        -- The old last resort was: climb out to y=110, cross above the terrain, drop down. The
        -- reasoning was that a straight line at the drone's own altitude fails when a hill is in the
        -- way, and a scout carries a scanner where a pickaxe would go, so it cannot cut through.
        -- All true, and none of it argues for the sky -- it argues for asking the router, which is
        -- the thing that knows where the hill is.
        --
        -- This used to answer an unreachable target by flying to CRUISE_Y, crossing at 110, and
        -- dropping down. It is the single most expensive thing a drone can do and it buys nothing
        -- that A* over the surveyed map does not do better: MapServer holds 262,000 named blocks
        -- and computes a direct route; going to space is what you do when you have no map.
        --
        -- The cost is not marginal. A surface drone climbing to 110 and back spends ~90 fuel before
        -- it has travelled a single block horizontally, loses its GPS fix on the way up (four
        -- audible hosts do not follow it), and dead-reckons the descent -- so it arrives with less
        -- fuel, a worse position, and often outside the operating circle. Measured: D15 left base
        -- with 634 fuel to cut a tree NINETEEN blocks away, logged "boxed in -- climbing to 110 to
        -- cross", and was found at y=102 holding 322 fuel and no logs. The trip costs under 150 at
        -- ground level. It never reached the tree; no wood arrived; no charcoal was made; storage
        -- stayed empty and the fleet went on starving -- one pointless climb at a time.
        --
        -- So a route that A* could not supply is now reported as what it is. Distress puts the drone
        -- into "stuck", which is what TaskMan's rescue pass looks for, and the task goes back to the
        -- queue for a drone that can dig. Failing in ten fuel and saying so beats succeeding at
        -- ninety, and beats "succeeding" into the sky.
        if s_At == false then
            Distress("no route", "pathfinder found no way to the survey start; needs a miner to dig through")
        end
        if s_At == false then
            -- SCAN FROM WHERE YOU CAN STAND. THE SCANNER HAS A RADIUS.
            --
            -- A scan start is a convenient centre, not a requirement: the geo scanner reaches eight
            -- blocks in every direction, so standing near the region is worth most of standing in
            -- it. Treating the centre as mandatory made whole tasks impossible -- the supply loop
            -- builds "assist" surveys as a box around a working miner, and at depth the centre of
            -- that box is SOLID ROCK, which a scout can never occupy because it carries a scanner
            -- where a pickaxe would go. D19 and D20 spent eighteen minutes each failing to reach a
            -- point no scout could ever reach, and the task was requeued every time.
            --
            -- So if we are close enough for the scan to overlap the region, scan here and report it.
            -- Useless coverage is still better than none, and it ends the retry loop honestly.
            local cx3, cy3, cz3 = pgps.getCachedPosition()
            local s_Near = cx3 and (math.abs(cx3 - tonumber(d.pos.x)) + math.abs(cz3 - tonumber(d.pos.z)))
            if s_Near and s_Near <= (tonumber(d.radius) or 8) * 3 then
                trace(("survey: cannot stand at the start -- scanning from here (%d blocks off)")
                    :format(s_Near))
                s_At = true          -- carry on and scan from the current position
            end
        end
        if s_At == false then
            TaskEnd()
            m_Status = "idle"
            trace("Survey FAILED: could not reach " .. tostring(d.pos.x) .. "," ..
                  tostring(d.pos.y) .. "," .. tostring(d.pos.z))
            reportTask(d, false, "could not reach the survey start")
            return false, "could not reach the survey start"
        end
    end

    m_Job = {verb = "Survey", data = d}
    saveResume()

    -- A scout surveys by hopping and scanning rather than crawling and touching. Same command,
    -- same grid, roughly three orders of magnitude more blocks per move.
    local s_Sc = Scanner()
    if s_Sc then
        local s_R = tonumber(d.radius) or 8
        m_Status = "scanning"
        TaskStart()
        local s_Step, s_Total, s_Scans = s_R * 2, 0, 0
        local s_Walled = 0
        for row = 1, s_H do
            for col = 1, s_W do
                if not executing then break end
                -- A scan is thousands of blocks recorded relative to where we think we are, so a
                -- drifted position poisons the map wholesale rather than one cell at a time. Fix
                -- first, scan second.
                pgps.verifyPosition()
                -- SCAN THE GROUND, NOT THE SKY.
                --
                -- The scanner reads a SPHERE of radius r around the drone, so where the drone is standing
                -- decides what the scan is worth. From cruising height almost all of it is air: at y=95
                -- with r=8 it covers y=87..103, and over terrain twenty blocks below that is thousands of
                -- cells of nothing, recorded diligently.
                --
                -- The WALKING survey below already settles before every step. This branch -- the one a
                -- scout with a scanner actually takes -- never did, so the better-equipped drone did the
                -- worse survey. Dropping to the surface re-centres the sphere so half of it is underground,
                -- which is where the ore is and the entire reason for scanning.
                settle(s_Drop)
                
                local n = absorbScan(s_Sc, s_R)
                s_Total, s_Scans = s_Total + n, s_Scans + 1
                UploadWorld()
                if col < s_W then
                    local s_MovedThisLane = 0
                    for _ = 1, s_Step do
                        if not executing then break end
                        if not stepForward(s_Climb) then break end
                        s_MovedThisLane = s_MovedThisLane + 1
                    end
                    -- A BLOCKED LANE ENDS, it is not retried for ever.
                    --
                    -- stepForward climbs an obstacle and gives the height back on the way past. Following it
                    -- with settle() undid that climb at once, so against a wall the drone rose, was dropped,
                    -- rose again -- oscillating in place, reporting "scanning", achieving nothing. The settle
                    -- was mine and it fought the climb. With it gone, a step that cannot be made means this
                    -- lane is finished; turn onto the next rather than grinding at the wall.
                    if s_MovedThisLane == 0 then
                        s_Walled = s_Walled + 1
                        if s_Walled >= 3 then
                            trace("survey: walled in after " .. s_Scans .. " scans")
                            break
                        end
                    else
                        s_Walled = 0
                    end
                    os.sleep(SCAN_COOLDOWN)
                end
            end
            if not executing then break end
            if row < s_H then
                local s_Turn = (row % 2 == 1) and pgps.turnRight or pgps.turnLeft
                s_Turn()
                for _ = 1, s_Step do
                    if not executing then break end
                    if not stepForward(s_Climb) then break end
                end
                settle(s_Drop)   -- follow the ground DOWN too; stepForward only gives back what it climbed
                s_Turn()
                os.sleep(SCAN_COOLDOWN)
            end
        end
        TaskEnd()
        m_Status = "idle"
        UploadWorld(true)      -- job over: flush, do not hold for the throttle
        m_Job = nil saveResume()
        reportTask(d, true, nil, {scanned = s_Total, sweeps = s_Scans})
        return true, {message = "scanned " .. s_Total .. " blocks in " .. s_Scans .. " sweeps"}
    end

    m_Status = "surveying"
    TaskStart()

    -- Get to the surface once up front; after that `settle` keeps it there.
    settle(s_Drop)

    local s_Cells, s_Blocked = 0, 0
    for row = 1, s_H do
        for col = 1, s_W - 1 do
            if not executing then break end          -- Abort landed
            if stepForward(s_Climb) then
                settle(s_Drop)
                s_Cells = s_Cells + 1
            else
                s_Blocked = s_Blocked + 1
                -- Blocked on every climb attempt means something is above as well as ahead;
                -- that is a drone in a hole, not a hill in the way.
                if s_Blocked >= 3 then
                    Distress("blocked", "survey stalled after " .. s_Cells .. " cells")
                    TaskEnd()
                    return false, "stuck after " .. s_Cells .. " cells"
                end
                break                                 -- wall: give up this row, not the survey
            end
        end
        if not executing then break end
        if row < s_H then
            -- Turn onto the next lane, alternating so it sweeps rather than returns.
            local s_Turn = (row % 2 == 1) and pgps.turnRight or pgps.turnLeft
            s_Turn()
            if stepForward(s_Climb) then settle(s_Drop) end
            s_Turn()
        end
    end

    TaskEnd()
    m_Status = "idle"
    UploadWorld(true)      -- job over: flush, do not hold for the throttle
    m_Job = nil saveResume()
    reportTask(d, true, nil, {cells = s_Cells, blocked = s_Blocked})
    return true, {message = "surveyed " .. s_Cells .. " cells, " .. s_Blocked .. " blocked"}
end


-- ===== DIG AND HAUL =================================================================
-- DroneWork.lua shipped entirely commented out, so nothing on the drone side could ever mine.
-- This is that half.

-- A turtle has 16 slots and silently stops picking things up when they are all full -- ore just
-- stays in the ground and the drone keeps working, which looks like success. Leave one slot of
-- headroom so a stack that splits mid-dig does not overflow.
function FreeSlots()
    local n = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) == 0 then n = n + 1 end
    end
    return n
end

-- Gravel and sand fall into the space you just cleared, so a single dig is not enough. Bounded,
-- because a dig that keeps succeeding forever means we are standing under a gravel column and
-- should give up rather than mine the sky.
-- Never break the fleet's own infrastructure. EVERY dig in every job funnels through digHard, so
-- this is the one place the rule needs to exist -- and the only place it cannot be forgotten when
-- a new job type is added.
--
-- D1 mined D2 out of the world: a turtle became an item in a chest while the registry went on
-- listing it as idle. Refusing the whole SITE would be the wrong fix -- sites legitimately contain
-- things, and a job that will not start is worse than one that digs around an obstacle. So check
-- the block that is actually about to be broken, and leave it standing.

-- ONE LIST, IN ONE PLACE. This kept its own copy of the protected-block table alongside the one in
-- pgps -- two lists that had to be edited together and silently disagreed the moment they were not.
-- DroneLogic already loads pgps as an API, so there is no reason for a second copy to exist; and the
-- pathfinder needs no copy at all, because a refusal is recorded in the MAP as "forbidden" rather
-- than re-derived from names on the far side.
function IsProtected(p_Name)
    return pgps.isProtectedBlock(p_Name)
end

local function digHard(p_Dig, p_Detect, p_Inspect, p_Which)
    local s_Tries = 0
    while p_Detect() do
        if p_Inspect then
            local s_Ok, s_Blk = p_Inspect()
            if s_Ok and s_Blk and IsProtected(s_Blk.name) then
                -- RECORD IT, DO NOT JUST ANNOUNCE IT.
                --
                -- This printed a line and returned false, so the map went on believing the cell was
                -- passable -- and the pathfinder went on planning through it, every time, for ever.
                -- The drone had the answer and told nobody, not even itself. Writing it as solid is
                -- what makes the refusal permanent instead of a loop, and it goes to the SHARED map
                -- so the other drones do not each rediscover it.
                pgps.noteBlocked(p_Which, s_Blk.name)
                -- PUBLISH IT NOW, NOT AT THE END OF THE JOB.
                --
                -- Recording the refusal locally is not enough: MapServer plans the routes, and the
                -- observation sits in an unsent delta until the job finishes -- so the pathfinder
                -- goes on offering the same route through the same chest, and the drone goes on
                -- discovering the wall on arrival. Anything we refuse to mine is solid, and the
                -- whole fleet needs to know that immediately or they each rediscover it in turn.
                --
                -- Throttled, because a drone working along a wall of infrastructure would otherwise
                -- upload once per block.
                local s_Now = os.clock()
                if m_BlockedUploadAt == nil or (s_Now - m_BlockedUploadAt) > 15 then
                    m_BlockedUploadAt = s_Now
                    pcall(UploadWorld)
                end
                trace(("refusing to mine %s -- recorded as impassable so nothing routes through it")
                    :format(tostring(s_Blk.name)))
                -- AND STOP THE TRAVEL, DO NOT JUST FAIL THIS DIG.
                --
                -- Recording it stops the PATHFINDER routing through it, but the travel ladder was
                -- still free to fall through to the next fallback and come straight back: refuse the
                -- modem, try another way, fail, refuse the modem again. D4 did that indefinitely.
                -- A protected block is exactly as permanent as a protected area -- no fallback will
                -- ever get past it -- so it belongs in the same bucket, and hardStop reads this.
                m_RefusedBlock = s_Blk.name
                return false, s_Blk.name
            end
        end
        if not p_Dig() then return false end
        s_Tries = s_Tries + 1
        if s_Tries > 24 then return false end
        os.sleep(0.4)
    end
    -- Every dig in the fleet funnels through here, so this is the one place that has to tell the
    -- map the block is gone -- and it reports the cell even when the loop never ran, because
    -- "nothing to dig" is itself the observation that the cell is air.
    pgps.noteCleared(p_Which)
    return true
end

function DigForward() return digHard(turtle.dig,     turtle.detect,     turtle.inspect,     "forward") end
function DigUp()      return digHard(turtle.digUp,   turtle.detectUp,   turtle.inspectUp,   "up")      end
function DigDown()    return digHard(turtle.digDown, turtle.detectDown, turtle.inspectDown, "down")    end

-- Empty into storage, then come back and carry on. Asking StorageMan where to go (rather than
-- hardcoding a chest) is what lets storage move or grow without touching drone code.
-- THE TRAVEL CHAIN, INCLUDING THE WAY OUT OF A HOLE.
--
-- Written out separately in Mine, Survey, GoTo, Gather and Deposit, and MISSING from three of them
-- until today -- which is what stalled the whole material economy. Anything new travels through
-- here so the next job cannot be written without it.
--
-- The climb comes first because a buried drone travels badly: digTo works its axes horizontally
-- first, so from mining depth it bores sideways for its entire budget instead of going up thirty
-- blocks into open air where moveTo and flyTo both work.
-- Tell StorageMan what physically moved. Its own peripheral scan cannot see these chests -- the
-- wired modems were never attached -- so a drone's account of what it dropped or took is the only
-- stock information the settlement has. Best effort: a lost report costs accuracy, never the load.
-- REPORT WHAT IS ACTUALLY IN THE CHEST, NOT WHAT WE THINK WE CHANGED.
--
-- Deposits and withdrawals were reported as deltas and StorageMan added them up. Bookkeeping
-- drifts: one unreported return and the totals are wrong for ever. It happened immediately -- the
-- crafter withdrew 22 logs, the craft failed, it put them back, the return went unreported, and
-- the ledger showed zero logs while 22 sat in the chest it had just used. It then sent the next
-- craft to the wrong chest entirely.
--
-- A drone standing on a chest can simply read it. Observed contents replace the guess, and the
-- error cannot accumulate because nothing is being accumulated.
-- WHO IS IN THE WAY, AND ASK THEM TO MOVE.
--
-- Movement failure was reported as "could not reach storage" -- a routing verdict with no cause. So
-- the single most common obstruction in this settlement, ANOTHER DRONE, was invisible: D7 spent 42
-- minutes failing to deliver the logs D4 was waiting for, because D4 was standing on the chest's
-- only access square, and neither the log, nor Distress, nor the plan ever contained the word
-- "drone". A blocker nobody can name is a blocker nobody can clear.
--
-- Drones already yield for fuel and hand items to each other, so asking one to take a step is not a
-- new kind of cooperation -- it is the same kind, applied to the thing that actually stops work.
-- Broadcast rather than addressed: the mover knows the POSITION that is blocked, not whose it is.
function AskToMakeWay(p_X, p_Y, p_Z)
    -- SendToAllDrones, not Broadcast. There is no PowNet.Broadcast; calling it is a nil global,
    -- which inside this pcall would have failed silently for ever -- the exact shape of bug this
    -- whole mechanism exists to expose.
    pcall(function()
        PowNet.SendToAllDrones(PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "MakeWay",
            {pos = {x = p_X, y = p_Y, z = p_Z}, from = os.getComputerID()}))
    end)
end

-- Is the thing at the target another drone? Returns its position when it is, so the caller can both
-- SAY SO and do something about it.
function DroneInTheWay(p_X, p_Y, p_Z)
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return nil end
    -- Only worth inspecting when the target is the square we would step into next.
    local s_Checks = {
        {cx, cy + 1, cz, turtle.inspectUp},
        {cx, cy - 1, cz, turtle.inspectDown},
    }
    for _, c in ipairs(s_Checks) do
        if c[1] == p_X and c[2] == p_Y and c[3] == p_Z then
            local ok, blk = c[4]()
            if ok and type(blk) == "table" and blk.name and blk.name:find("turtle", 1, true) then
                return {x = p_X, y = p_Y, z = p_Z}
            end
            return nil
        end
    end
    local ok, blk = turtle.inspect()
    if ok and type(blk) == "table" and blk.name and blk.name:find("turtle", 1, true) then
        return {x = p_X, y = p_Y, z = p_Z}
    end
    return nil
end

-- The receiving half. Step aside if the square being complained about is the one we are sitting on.
function OnMakeWay(p_ID, p_Message)
    local d = p_Message.data or {}
    if type(d.pos) ~= "table" or d.pos.x == nil then return false, "no position" end
    -- NEVER TAKE ORDERS FROM YOURSELF.
    --
    -- The request is a broadcast, and the drone that sends it is very often standing on or beside
    -- the square it is asking about -- it is the one that just arrived there. Without this guard a
    -- drone that ever hears its own broadcast tells itself to move off the square it deliberately
    -- travelled to, which is both pointless work and an unexplained step in the log.
    if d.from ~= nil and tonumber(d.from) == os.getComputerID() then return false, "own request" end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return false, "no fix" end
    -- EXACTLY THE SQUARE, NOT THE NEIGHBOURHOOD.
    --
    -- A one-block tolerance meant a 3x3x3 cube around the contested square, so a broadcast pulled in
    -- every drone working nearby -- and right after a fleet reboot, when they all restore a pose in
    -- the bay, that was most of them at once. They logged make-way requests for squares they were
    -- not on, stepped aside for no reason, and lost their place in whatever they were doing.
    --
    -- Only the drone actually standing there is in the way. Requests for anywhere else are not ours.
    if cx ~= d.pos.x or cz ~= d.pos.z or math.abs(cy - d.pos.y) > 0 then
        return false, "not me"
    end
    -- A yield we cannot act on is worse than none: it interrupts and achieves nothing.
    if not pgps.positionVerified() then return false, "position unverified" end
    -- NEVER MOVE THE TURTLE FROM THE MESSAGE HANDLER.
    --
    -- The first version stepped aside right here, and it hung the entire fleet. Message handling and
    -- the job run in different coroutines, and the turtle movement API is not reentrant: a job
    -- already inside a move plus a handler starting another means one of them blocks for ever. Every
    -- drone's log ended on the line "asked to make way -- stepping aside" and then stopped -- D3's
    -- clock froze at 119s while ten minutes passed. Five drones, wedged, by the very mechanism added
    -- to unwedge them.
    --
    -- So record the request and let whoever owns movement act on it at a point where it is safe.
    -- The asker waits a couple of seconds and retries regardless, so a slightly late step is fine
    -- and a deadlocked drone is not.
    m_YieldAt = {x = d.pos.x, y = d.pos.y, z = d.pos.z, at = os.clock()}
    trace(("asked to make way at %d,%d,%d -- will step aside at the next safe point")
        :format(d.pos.x, d.pos.y, d.pos.z))
    return true, "queued"
end

function ReportChest()
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return end
    local c = peripheral.wrap("bottom")
    if not c or not c.list then return end
    local ok, l = pcall(c.list)
    if not ok or type(l) ~= "table" then return end

    local s_Items, s_Used = {}, 0
    for _, it in pairs(l) do
        if it and it.name then
            s_Items[it.name] = (s_Items[it.name] or 0) + (it.count or 0)
            s_Used = s_Used + 1
        end
    end
    -- SLOTS, NOT JUST ITEMS. "Full" is a slot count, and the item totals cannot express it: a chest
    -- holding 27 single items is completely full while looking nearly empty by weight. Deposit
    -- points were chosen on the item total, so drones were routed to chests with no room at all --
    -- they arrived, could not unload, stayed full, and every gather they were carrying died on the
    -- spot because the drone had nowhere to put what it dug.
    local s_Size = 27
    if c.size then local ok2, sz = pcall(c.size) if ok2 and tonumber(sz) then s_Size = tonumber(sz) end end

    pcall(function()
        PowNet.sendAndWaitForResponse("StorageMan",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "ChestContents",
                {at = {x = cx, y = cy - 1, z = cz}, items = s_Items,
                 used = s_Used, size = s_Size}),
            PowNet.SERVER_PROTOCOL, 3)
    end)
end

-- WHAT WE ARE CARRYING AND WHY, IN A FORM A HUMAN CAN READ ON THE PANEL.
--
-- Takes the want-map a fetch was issued for -- {["minecraft:oak_log"] = 8} -- and renders
-- "oak_log x8". Pass nil when the haul is over, or the panel goes on claiming it for ever.
-- SAY WHAT IS HAPPENING NOW, NOT WHAT THE JOB SET OUT TO DO.
--
-- The panel showed "hauling oak_logx26" while the drone was in fact circling the bay unable to
-- reach a stack in slot 20, and had been for minutes. The detail was written once when the job
-- started and never touched again, so every intermediate state -- searching, blocked, short --
-- was invisible from outside and the only way to know anything was to read drone.log by hand.
function Doing(p_Text)
    m_Detail = p_Text
    -- Clear the haul label too, or the heartbeat rewrites m_Detail back to "hauling <items>" on its
    -- next tick and this line never reaches the panel at all.
    m_Haul = nil
end

function SetHauling(p_Want)
    if p_Want == nil then m_Haul = nil return end
    local s_Bits = {}
    for name, n in pairs(p_Want) do
        s_Bits[#s_Bits + 1] = tostring(name):gsub("^minecraft:", "") .. (n and n > 1 and ("x" .. n) or "")
    end
    table.sort(s_Bits)
    m_Haul = #s_Bits > 0 and table.concat(s_Bits, " ") or nil
end

function ReportStorage(p_Verb, p_Items)
    local s_Any = false
    for _ in pairs(p_Items or {}) do s_Any = true break end
    if not s_Any then return end
    -- WHERE, as well as what. The drone is standing on the chest it just used, so it is the only
    -- thing that knows which one -- and without it the ledger can say "22 oak_log" but not which of
    -- four chests they are in, which is a search the fleet cannot afford.
    local cx, cy, cz = pgps.getCachedPosition()
    local s_At = nil
    if cx ~= nil then s_At = {x = cx, y = cy - 1, z = cz} end   -- the chest is the block below us
    pcall(function()
        PowNet.sendAndWaitForResponse("StorageMan",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, p_Verb, {items = p_Items, at = s_At}),
            PowNet.SERVER_PROTOCOL, 3)
    end)
end

-- Beyond this, a mapped route is worth waiting for. Below it, it never is.
local SHORT_HOP = 32

-- A refusal no fallback can fix must STOP the attempt and be reported, not be retried five ways.
--
-- Every travel path here is a ladder of fallbacks -- mapped route, climb out, dig through, fly over
-- -- and that is right for an obstruction. It is exactly wrong for "Cannot enter protected area",
-- which is the same answer from every square in every direction until a human changes a server
-- setting. The fleet spent hours climbing, digging and flying against a wall that was not there,
-- reporting "no mapped route", because the one call that knew the truth returned it as `false`.
-- ASK FOR A MINER WHEN THE THING IN THE WAY IS A BLOCK YOU CANNOT DIG.
--
-- A crafter carries a crafting table and a modem -- there is no room for a pickaxe -- so a single
-- block placed over a chest strands it permanently. It cannot dig through, it cannot route around
-- (the access square is one block), and every fallback in TravelTo is a way of getting past
-- terrain, which is exactly what it has no tool for. The drone would sit there for ever reporting a
-- routing failure, when what it actually needs is thirty seconds of another drone's time.
--
-- The fleet already knows how to preempt the nearest drone for a blocker; it just had no way to
-- learn that this was one. So say it: name the block, name the position, and queue clearing it at
-- high priority. Deduplicated by name so repeated attempts do not pile up identical tasks.
-- CAN THIS DRONE DIG AT ALL?
--
-- `turtle.dig` is a FUNCTION on every turtle, with or without a tool -- it simply returns
-- false, "No tool to dig with" when there is nothing equipped. So `if turtle.dig == nil` is always
-- false, and every guard written that way silently does nothing: the crafter-asks-for-a-miner path
-- added earlier could never once have run. Verified by probe on D4: dig=function, left=modem,
-- right=workbench, and no pickaxe anywhere.
--
-- A turtle has exactly two upgrade slots. Peripherals (modem, workbench, geo scanner) report a type;
-- tools report nil. So if BOTH slots hold a peripheral there is no room for a tool, and this drone
-- cannot dig -- which is the honest, checkable version of the question.
function CanDig()
    local l = peripheral.getType("left")
    local r = peripheral.getType("right")
    return not (l ~= nil and r ~= nil)
end

function RequestClearance(p_X, p_Y, p_Z)
    local s_What = "something"
    local cx, cy, cz = pgps.getCachedPosition()
    if cx ~= nil and cx == p_X and cz == p_Z then
        local ok, blk = (p_Y > cy) and turtle.inspectUp() or turtle.inspectDown()
        if ok and type(blk) == "table" and blk.name then s_What = blk.name end
    end

    -- A DRONE IS NOT A BLOCK. DO NOT SEND A MINER TO DIG ONE.
    --
    -- This queued a clear- task for whatever was in the way, and "whatever" is very often another
    -- drone -- the bay is the most congested airspace in the settlement and a crafter has no
    -- pickaxe, so it asks for help constantly. The miner then arrives and correctly refuses:
    -- "refusing to dig computercraft:turtle_normal". The task cannot complete, cannot fail, and
    -- sits at PRIORITY 1 for ever.
    --
    -- Eighteen of them accumulated at once -- more than every other kind of task combined -- all
    -- unresolvable, all outranking the tower build they were starving. The queue looked busy and
    -- the fleet was clearing each other out of the way instead of working.
    --
    -- The right answer for a drone in the way already exists and costs one message: ask it to move.
    if s_What:find("turtle", 1, true) or s_What:find("drone", 1, true) then
        trace(("blocked by a DRONE at %d,%d,%d -- asking it to move rather than queuing a dig")
            :format(p_X, p_Y, p_Z))
        if type(AskToMakeWay) == "function" then AskToMakeWay(p_X, p_Y, p_Z) end
        return
    end

    -- DO NOT SEND A MINER TO DIG SOMETHING YOU CANNOT NAME.
    --
    -- s_What is only ever identified when the obstruction is directly above or below us -- that is
    -- the only case turtle.inspectUp/Down can see. Every other time it stays the literal string
    -- "something", which is not in the protected list, so an unknown blocker got a PRIORITY-1 dig
    -- task queued against it.
    --
    -- Measured: eight of them at once, all at -474..-480, 65, 78 -- the airspace directly above the
    -- chest row. That is where drones queue to deposit, so the "obstruction" was invariably another
    -- drone, the dig could never succeed, and eight unresolvable priority-1 tasks sat ahead of
    -- gather:coal_ore while the settlement ran out of fuel.
    --
    -- An unidentified blocker in a busy bay is a drone until proven otherwise. Ask it to move --
    -- that costs one message and works -- and let travel retry. A dig is for something we have
    -- looked at and know to be diggable.
    if s_What == "something" then
        trace(("blocked by something unidentified at %d,%d,%d -- asking it to move, not queuing a dig")
            :format(p_X, p_Y, p_Z))
        if type(AskToMakeWay) == "function" then AskToMakeWay(p_X, p_Y, p_Z) end
        return
    end

    -- NEVER ASK ANYONE TO DIG THE SETTLEMENT.
    --
    -- The turtle case above was only half of it. IsProtected is the list of things no drone may
    -- ever dig -- chests, computers, modems, the machines this fleet is built out of -- and a clear-
    -- task for one of those is unresolvable by construction: the miner arrives, correctly refuses,
    -- and the task sits at PRIORITY 1 for ever, outranking real work.
    --
    -- Found live: clear--472:64:76 was a standing request to DIG THE BRIDGE COMPUTER. Eighteen such
    -- tasks were queued at once, ahead of the tower build they were starving, and the queue looked
    -- fully occupied the entire time.
    --
    -- Reusing IsProtected rather than listing names here, because that list is the one place this
    -- rule belongs -- every component that must not dig something asks it, and a second copy would
    -- be wrong the first time somebody added a machine to one and not the other.
    if IsProtected(s_What) then
        trace(("blocked by %s at %d,%d,%d -- protected, so no dig will ever clear it; routing round")
            :format(s_What, p_X, p_Y, p_Z))
        Distress("blocked by protected infrastructure",
                 ("%s at %d,%d,%d"):format(s_What, p_X, p_Y, p_Z))
        return
    end

    trace(("blocked by %s at %d,%d,%d and I have no pickaxe -- asking for a miner")
        :format(s_What, p_X, p_Y, p_Z))
    Distress("blocked, needs a miner", ("%s at %d,%d,%d"):format(s_What, p_X, p_Y, p_Z))

    pcall(function()
        PowNet.SendToServer("TaskMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Add", {
            name = ("clear-%d:%d:%d"):format(p_X, p_Y, p_Z),
            -- Above every ordinary job: something is STOPPED until this is done, and the whole
            -- point is that the drone waiting cannot fix it itself.
            priority = 1,
            work = {dig = {start = {x = p_X, y = p_Y + 1, z = p_Z}, w = 1, l = 1, depth = 1}},
        }))
    end)
end

local function hardStop(p_What)
    -- A PROTECTED BLOCK IS NOT A HARD STOP. YOU CAN FLY OVER A CHEST.
    --
    -- I put the refused-block case in here, reasoning that "no fallback will ever help" -- which is
    -- true of spawn protection and false of a chest. The effect was to abort the travel BEFORE
    -- flyTo, the one fallback that actually works: D3 sat below the storage row trying to reach the
    -- access square directly above a chest, digTo rose into the chest, refused correctly, and then
    -- this cancelled the fly-over that would have gone straight over the top.
    --
    -- The recording still happens in digHard, which is what stops the pathfinder offering the same
    -- route again. Remembering an obstacle and refusing to route around it are different things,
    -- and only the first was wanted.
    m_RefusedBlock = nil
    local e = pgps.lastMoveError and pgps.lastMoveError()
    if e == nil then return false end
    pgps.clearMoveError()
    trace(("MOVEMENT REFUSED: %s -- no route around this, stopping %s"):format(tostring(e), p_What))
    Distress("movement refused", tostring(e))
    return true
end

function TravelTo(p_X, p_Y, p_Z, p_Ceiling)
    -- DO NOT ASK THE PATHFINDER TO CROSS THE ROOM.
    --
    -- moveTo is an A* request to MapServer, which is holding 207,574 cells: a 1,331-cell region
    -- query measured at 5.8 SECONDS and a full-region one does not answer at all. Every drone's
    -- every leg queued behind that, so the fleet spent its life waiting on a search rather than
    -- moving -- D3 sat 900 seconds trying to travel TWELVE BLOCKS to the mine head, with clear air
    -- on all four sides, while three other drones queued behind it for the same service.
    --
    -- A mapped route earns its cost when there is something to route around. For a short hop it is
    -- pure latency: digTo and flyTo go straight there, need nobody's help, and cannot be starved by
    -- another drone's search. So the order is reversed below SHORT_HOP -- direct first, A* only as
    -- the fallback it should always have been for this case.
    local cx, cy, cz = pgps.getCachedPosition()

    if cx ~= nil then
        local s_D = math.abs(cx - p_X) + math.abs(cy - p_Y) + math.abs(cz - p_Z)
        if s_D <= SHORT_HOP then
            if CanDig() and pgps.digTo(p_X, p_Y, p_Z) ~= false then return true end
            if hardStop("travel") then return false end
            trace(("travel: short hop of %d failed direct -- falling back to the map"):format(s_D))
        end
    end

    if pgps.moveTo(p_X, p_Y, p_Z) ~= false then return true end
    if hardStop("travel") then return false end

    if CanDig() and p_Ceiling then
        local _, s_Cy = pgps.getCachedPosition()
        if s_Cy and s_Cy < p_Ceiling then
            local s_Rose = 0
            while s_Rose < 128 do
                local _, cy = pgps.getCachedPosition()
                if cy == nil or cy >= p_Ceiling then break end
                DigUp()
                if not pgps.up() then break end
                s_Rose = s_Rose + 1
            end
            trace(("travel: rose %d to get out of the ground"):format(s_Rose))
            if pgps.moveTo(p_X, p_Y, p_Z) ~= false then return true end
        end
    end

    if CanDig() and pgps.digTo(p_X, p_Y, p_Z) ~= false then return true end
    if hardStop("travel") then return false end

    -- NO FLIGHT RUNG. THE PATHFINDER IS THE TRAVEL MECHANISM.
    --
    -- This ended with pgps.flyTo, a greedy axis-walker that reads no map, cannot dig, and whose
    -- escape hatch when every horizontal axis is blocked is to go UP. It was measured over a full
    -- night of logs: reached as a travel rung TWICE, and reported "flyTo is wedged" THREE times. It
    -- rescued nothing, and its failure mode is the one we spent the night chasing -- a drone at
    -- y=100+ that climbed over an obstacle instead of routing round it, burning fuel and leaving
    -- GPS range on the way.
    --
    -- moveTo and digTo are the same A* with digging allowed or forbidden. If neither can find a
    -- route, the honest answer is that there is no route, and the next line says so to somebody who
    -- can do something about it. Climbing over the problem is not a third opinion.

    -- Out of routes. If we could dig we would have by now, so the only remaining answer is somebody
    -- else's. See RequestClearance -- and CanDig, because `turtle.dig == nil` is never true.
    if not CanDig() then RequestClearance(p_X, p_Y, p_Z) end
    return false
end

-- TRAVEL, THEN CHECK YOU ACTUALLY GOT THERE.
--
-- TravelTo reports success when the drone BELIEVES it has arrived, and underground that belief is
-- dead reckoning: D3 was found three blocks from where it reported, which is enough to be standing
-- beside the storage chest rather than on it. It then sucked from whatever happened to be below,
-- got nothing, and reported "storage had nothing burnable" while a chest three blocks away held
-- three stacks of coal. Every fuel-relief run failed this way.
--
-- Storage is at ground level, where GPS works, so the arrival can simply be CHECKED -- and if the
-- drone is not where it thought, the corrected position makes the second attempt a short hop.
-- THE CHEAP, DETERMINISTIC WAY HOME. Used when fuel is the constraint.
--
-- TravelTo is the clever route: A* through the surveyed map, then a climb, then A* again, then
-- digTo's 256-step budget, then flyTo's 512. Good when the goal is a nice tunnel. Ruinous when the
-- goal is arriving before the tank empties -- D1 spent 570 seconds and 575 fuel on a sixty-block
-- trip to storage, which is roughly ten times what the journey is worth, and arrived with less
-- than half of what it set out with.
--
-- Straight up into open air, straight across, straight down. Every leg is bounded and none of them
-- searches. Storage is at ground level under open sky, which is exactly the case this suits.
function FlyHome(p_X, p_Y, p_Z, p_Ceiling)
    local s_Ceiling = p_Ceiling or (p_Y + 4)
    local s_Rose = 0
    while s_Rose < 128 do
        local _, cy = pgps.getCachedPosition()
        if cy == nil or cy >= s_Ceiling then break end
        if CanDig() then DigUp() end
        if not pgps.up() then break end
        s_Rose = s_Rose + 1
    end
    -- Cross at altitude, then settle. flyTo is greedy and goes over what it meets, which above the
    -- treeline is nothing.
    local _, cy = pgps.getCachedPosition()
    if cy and pgps.flyTo(p_X, cy, p_Z, 256) == false then return false end
    return pgps.flyTo(p_X, p_Y, p_Z, 64) ~= false
end

function ArriveAt(p_X, p_Y, p_Z, p_Ceiling)
    if not TravelTo(p_X, p_Y, p_Z, p_Ceiling) then
        -- ASK BEFORE GIVING UP. THE OBSTRUCTION IS USUALLY A DRONE.
        --
        -- Yielding was wired only into Deposit, so it covered one caller out of many -- and the
        -- deadlock that actually happened did not involve a deposit at all: three drones stacked in
        -- one column above the bay's busiest chest, each inside a job, each unable to move because
        -- the other two were in the way, all reporting healthy. D3 sat "working" and unmoved for
        -- three minutes with the mine head twelve blocks away.
        --
        -- Every travel goes through here, so this is the one place that covers all of them. One
        -- broadcast, one retry; if the square was never the problem the retry costs a few seconds.
        trace(("travel: could not reach %d,%d,%d -- asking anyone in the way to move"):format(p_X, p_Y, p_Z))
        AskToMakeWay(p_X, p_Y, p_Z)

        -- YIELD BACK, EVEN MID-JOB. Otherwise two drones deadlock politely.
        --
        -- Honouring a make-way request only when idle means two BUSY drones facing each other never
        -- move: each asks, neither is free to answer, and they dance until something reclaims the
        -- task. D14 and D15 did exactly that. This is the job's own coroutine, which owns movement,
        -- so stepping aside here is safe -- the same step from the message handler is what hung the
        -- fleet earlier.
        if m_YieldAt ~= nil then
            local y = m_YieldAt
            m_YieldAt = nil
            local cx2, cy2, cz2 = pgps.getCachedPosition()
            if cx2 ~= nil and cx2 == y.x and cz2 == y.z and math.abs(cy2 - y.y) <= 0 then
                trace("travel: standing where somebody needs to be -- stepping aside first")
                for _ = 1, 4 do
                    if pgps.forward() then break end
                    pgps.turnRight()
                end
            end
        end
        os.sleep(2)
        if not TravelTo(p_X, p_Y, p_Z, p_Ceiling) then return false end
    end
    pgps.verifyPosition(true)
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return true end                    -- no fix available: believe the reckoning
    if cx == p_X and cy == p_Y and cz == p_Z then return true end
    trace(("arrive: thought I was at %d,%d,%d, actually %d,%d,%d -- going again")
        :format(p_X, p_Y, p_Z, cx, cy, cz))
    return TravelTo(p_X, p_Y, p_Z, p_Ceiling)
end

-- ONE PLACE THAT KNOWS HOW TO TAKE THINGS OUT OF A CHEST.
--
-- This logic was written four times -- stageFromChest, CollectFuel, RefuelAtStorage, and the craft
-- self-fetch -- and each copy had to learn the same trap independently, in production, hours apart:
--
--   Pull a stack, decide it is not what you wanted, drop it back -- and it goes straight back into
--   the slot you just freed. Suck again and you get the same stack. A drone can cycle one stack of
--   cobblestone indefinitely and never reach the coal behind it: RefuelAtStorage flew home with
--   641 fuel from a chest holding three stacks of coal, doing exactly that.
--
--   The fix is not to reason about which slot the chest hands over -- select() controls where items
--   LAND in the turtle, not where they come from, and guessing the source order is how the last
--   version of this went wrong. It is simply to take everything into free slots FIRST, so nothing
--   can be handed back mid-search, and sort afterwards.
--
-- The rule is: empty the leading stacks into your OWN inventory first, so you can see past them,
-- then keep what matches and put the rest back. Anything that takes from a chest goes through here,
-- so the next thing that needs to does not get to relearn it.
--
-- p_Want(name) returns true for items to keep. Returns a table of kept name -> count.
-- DROPPING IS NOT DEPOSITING, AND turtle.dropDown CANNOT TELL THE DIFFERENCE.
--
-- With a container below, dropDown puts the stack in it. With anything else below -- including
-- being one block off the chest -- it throws the stack ON THE GROUND, returns true, and the items
-- despawn five minutes later. There is no error and no way to tell afterwards.
--
-- Every job that sorts its haul calls this: gather, craft staging, fuel collection, deposit. So a
-- drone that arrived slightly wrong quietly binned its cargo and reported success. That is where
-- sixteen freshly cut logs went -- not lost to a reboot, which a turtle's inventory survives, but
-- tipped onto the floor by a drone standing next to the chest instead of on it.
--
-- Checking what is underneath costs one inspect and turns silent loss into a refusal the caller
-- can act on.
local CONTAINERS = {
    ["minecraft:chest"] = true, ["minecraft:trapped_chest"] = true, ["minecraft:barrel"] = true,
    ["minecraft:hopper"] = true, ["minecraft:dropper"] = true, ["minecraft:dispenser"] = true,
    ["minecraft:furnace"] = true, ["minecraft:blast_furnace"] = true, ["minecraft:smoker"] = true,
    ["minecraft:shulker_box"] = true,
}

function ContainerBelow()
    local ok, blk = turtle.inspectDown()
    if not ok or type(blk) ~= "table" or blk.name == nil then return false end
    if CONTAINERS[blk.name] then return true end
    -- Any shulker colour, and anything a mod calls a chest/barrel.
    return blk.name:find("shulker_box") ~= nil
        or blk.name:find("_chest") ~= nil
        or blk.name:find("_barrel") ~= nil
end

-- Returns true only if the items actually went into something. Callers keep what it refuses.
function PutDown(p_Count)
    if not ContainerBelow() then return false end
    if p_Count then return turtle.dropDown(p_Count) end
    return turtle.dropDown()
end

-- HAND ITEMS TO ANOTHER DRONE, WITHOUT A CHEST IN BETWEEN.
--
-- Everything the fleet owns has to pass through a chest, which makes the chest a single point of
-- failure and a bottleneck: a crafter blocked for want of wood cannot be helped by the miner
-- standing next to it holding sixteen logs. Early on there may be no chest at all.
--
-- The fuel relief already solved this shape -- fly above the drone, drop, let it pick the items up
-- -- so this is the same manoeuvre generalised past fuel. PutDown deliberately refuses to drop
-- without a container underneath (that guard exists because ten call sites were quietly tipping
-- cargo onto the floor); a handover is the one case where the thing underneath is a drone, so it
-- gets its own function rather than a hole in the guard.
function HandTo()
    local ok, blk = turtle.inspectDown()
    if not ok or type(blk) ~= "table" or blk.name == nil then return false end
    if blk.name:find("turtle") == nil then return false end
    -- lua-hygiene: allow (the thing below is a DRONE, verified on the line above -- this is the
    -- one legitimate drop that is not into a container, and PutDown correctly refuses it)
    return turtle.dropDown()
end

-- Pick up anything lying on us or beside us. The receiving half of a handover, and cheap enough to
-- try before concluding a job cannot be done.
function CollectNearby()
    local s_Before = 0
    for i = 1, 16 do s_Before = s_Before + turtle.getItemCount(i) end
    -- lua-hygiene: allow (picks up items handed over by another drone or lying in the world --
    -- there is no chest here, so the leading-stacks reasoning in TakeFromChest does not apply)
    for _, suck in ipairs({turtle.suckDown, turtle.suckUp, turtle.suck}) do
        for _ = 1, 4 do
            if FreeSlots() <= 1 then break end
            if not suck(64) then break end
        end
    end
    local s_After = 0
    for i = 1, 16 do s_After = s_After + turtle.getItemCount(i) end
    return s_After - s_Before
end

function TakeFromChest(p_Want)
    local s_Before = {}
    for i = 1, 16 do
        local d = turtle.getItemDetail(i)
        if d and d.name then s_Before[d.name] = (s_Before[d.name] or 0) + turtle.getItemCount(i) end
    end

    -- ASK THE CHEST WHAT IS IN IT, INSTEAD OF EMPTYING IT TO FIND OUT.
    --
    -- A turtle can wrap the inventory beneath it and call list(), which returns slot -> {name,
    -- count}. That is the difference between surgical and the thing this used to do: vacuum sixteen
    -- slots, keep what happened to match, and put the rest back. With 272 cobblestone, dirt,
    -- gravel, copper and coal in the way, the drone came back full of gravel and reported "nothing
    -- available for: minecraft:oak_log" while twenty-two logs sat four stacks further in.
    --
    -- suckDown still only takes the chest's leading slot, so getting at slot N means clearing what
    -- is ahead of it -- but knowing the contents first means we only do that when the item is
    -- actually there, and we stop the moment we have enough. If wrap is unavailable we fall back to
    -- the old sweep rather than refusing to work.
    turtle.select(1)
    local s_Kept = {}

    -- UNLOAD BEFORE READING THE LAYOUT, NOT AFTER.
    --
    -- Putting our cargo down changes the chest: the stacks land in whatever slots are free and
    -- shift what sits where. Reading list() first and unloading second meant acting on a layout
    -- that no longer existed -- "target is in slot 16" computed before adding nine stacks of
    -- cobblestone to the same chest. The pull then counted to the wrong place and came back
    -- without the logs, every time.
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then turtle.select(i) PutDown() end
    end
    turtle.select(1)

    local s_Chest = peripheral.wrap("bottom")
    local s_List = nil
    if s_Chest and s_Chest.list then
        local ok, l = pcall(s_Chest.list)
        if ok and type(l) == "table" then s_List = l end
    end

    if s_List then
        -- Is any of it even here? If not, take nothing and say so -- no flight wasted sorting.
        local s_Ahead, s_TargetSlot, s_WantName = 0, nil, nil
        for slot = 1, 128 do
            local it = s_List[slot]
            if it and it.name then
                if p_Want(it.name) then s_TargetSlot, s_WantName = slot, it.name break end
                s_Ahead = s_Ahead + 1
            end
        end
        if s_TargetSlot == nil then
            trace("chest: nothing matching is in there")
            return {}, {}
        end
        trace(("chest: target is in slot %d, %d stack(s) ahead of it"):format(s_TargetSlot, s_Ahead))

        -- PAST SLOT 16 IS UNREACHABLE BY SUCKING. ASK STORAGE TO MOVE IT.
        --
        -- suckDown only ever hands over the chest's first occupied slot, so reaching slot N costs
        -- N-1 stacks of turtle inventory -- and there are only 16 slots. The logs sat in slot 20 and
        -- the crafter could not have got them out if it had tried all night; it pulled 16 stacks of
        -- cobblestone, ran out of room, put them back, and reported the logs missing. StorageMan is
        -- on the wired network and can simply move the stack forward.
        if s_TargetSlot > 16 then
            trace(("chest: slot %d is out of a turtle's reach -- asking storage to bring it forward")
                :format(s_TargetSlot))
            local s_Moved = PowNet.sendAndWaitForResponse("StorageMan",
                PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "BringToFront",
                    {match = tostring(s_WantName or "")}), PowNet.SERVER_PROTOCOL, 8)
            if type(s_Moved) == "table" and s_Moved.slot then
                trace(("chest: storage moved it to slot %d"):format(s_Moved.slot))
                local ok3, l3 = pcall(s_Chest.list)
                if ok3 and type(l3) == "table" then
                    s_List = l3
                    s_Ahead, s_TargetSlot = 0, nil
                    for slot = 1, 128 do
                        local it = s_List[slot]
                        if it and it.name then
                            if p_Want(it.name) then s_TargetSlot = slot break end
                            s_Ahead = s_Ahead + 1
                        end
                    end
                end
            else
                trace("chest: storage could not bring it forward -- " .. tostring(s_Moved))
            end
            if s_TargetSlot == nil or s_TargetSlot > 16 then
                trace("chest: still out of reach after asking")
                Doing(("%s is stuck in slot %s -- storage could not surface it")
                    :format(tostring(s_WantName):gsub("^minecraft:", ""), tostring(s_TargetSlot)))
                return {}, {}
            end
        end
        -- EMPTY THE TURTLE FIRST, AND USE EVERY SLOT.
        --
        -- Reaching slot 16 takes sixteen pulls, and the guard stopped at one free slot -- fifteen
        -- pulls, one short, every time. The logs were always the last thing in the chest and so
        -- always exactly out of reach: "target is in slot 16, 15 stacks ahead", then "nothing
        -- available for: minecraft:oak_log".
        --
        -- The turtle was emptied above, before the layout was read, so every slot is free and the
        -- indices below are the ones actually in the chest right now.
        for _ = 1, math.min(16, s_Ahead + 1) do
            if FreeSlots() < 1 then break end
            if not turtle.suckDown(64) then break end
        end
    else
        for _ = 1, 16 do
            if FreeSlots() <= 1 then break end
            if not turtle.suckDown(64) then break end
        end
    end

    for i = 1, 16 do
        local n = turtle.getItemCount(i)
        if n > 0 then
            turtle.select(i)
            local d = turtle.getItemDetail(i)
            local nm = d and d.name
            if nm and p_Want(nm, i) then
                s_Kept[nm] = (s_Kept[nm] or 0) + n
            else
                PutDown()
            end
        end
    end
    turtle.select(1)

    -- Report only what actually LEFT the chest: what we kept, less what we were already carrying.
    local s_Net = {}
    for nm, n in pairs(s_Kept) do
        local net = n - (s_Before[nm] or 0)
        if net > 0 then s_Net[nm] = net end
    end
    ReportStorage("Withdrawn", s_Net)
    ReportChest()                 -- and the truth, which cannot drift
    return s_Kept, s_Net
end

-- GO GET THESE ITEMS. ONE IMPLEMENTATION, FOR EVERY JOB THAT NEEDS MATERIALS.
--
-- Craft, build and haul each grew their own version of "ask StorageMan where it is, fly there, pull
-- it out", and each one treated a wrong answer as the end of the job. That is what stalled the
-- entire construction pipeline: 22 oak logs sat in the chest at -476 while StorageMan pointed at
-- -474, and the crafter dutifully flew to -474, found an empty chest, failed the task, and was
-- redispatched to the same wrong place for hours. Nothing in the loop could ever discover that the
-- index was wrong, because nothing ever looked anywhere else.
--
-- An index that cannot be wrong is not achievable here -- reports get missed, drones reboot
-- mid-haul, and items move without anyone being told. An index that REPAIRS itself when found wrong
-- is achievable, and this is where it happens: the lookup is still the fast path and still the first
-- thing tried, but being wrong now costs one sweep of the bay instead of the pipeline. Every chest
-- opened on the way reports its real contents, so the sweep leaves the index better than it found
-- it, and the same lookup succeeds next time.
--
-- Returns kept, shortfall -- shortfall is nil when everything asked for was found.
-- p_Min: the least that is still worth having, per item. Defaults to p_Want (all or nothing).
function FetchItems(p_Want, p_Min)
    local s_Match = function(nm)
        for w in pairs(p_Want) do if SameItem(w, nm) then return true end end
        return false
    end
    local function tally()
        local got = {}
        for i = 1, 16 do
            local d = turtle.getItemDetail(i)
            if d and d.name then
                for w in pairs(p_Want) do
                    if SameItem(w, d.name) then got[w] = (got[w] or 0) + turtle.getItemCount(i) break end
                end
            end
        end
        return got
    end
    local function short(got)
        for w, n in pairs(p_Want) do if (got[w] or 0) < n then return w end end
        return nil
    end
    -- ENOUGH TO DO USEFUL WORK IS A STOPPING CONDITION.
    --
    -- "Short of the full order" and "cannot do anything at all" are different states, and treating
    -- them the same is what sent the crafter blind-sweeping the bay. It held 6 logs against an order
    -- of 8, which is six planks-worth of work it could have got on with; instead it went looking for
    -- the missing two -- which did not exist anywhere -- at several minutes per chest, in the most
    -- congested airspace in the settlement. The craft scales its run count to the materials on hand,
    -- so anything at or above the minimum is progress.
    local function belowMinimum(got)
        for w, n in pairs(p_Min or p_Want) do if (got[w] or 0) < n then return w end end
        return nil
    end

    -- Already carrying it? Then there is nothing to fetch. A drone that collected the ingredients
    -- and then rebooted still has them; flying to a chest to "get" what is already in slot 3 is how
    -- the logs ended up back in storage with the craft still reporting itself short.
    local s_Got = tally()
    if short(s_Got) == nil then return s_Got, nil end

    local s_First = nil
    for w in pairs(p_Want) do s_First = w break end

    -- LOOK IN THE CHEST YOU ARE STANDING ON BEFORE FLYING ANYWHERE.
    --
    -- Reading the container below costs nothing and needs no route, and drones spend most of their
    -- lives parked on top of one. The crafter was sitting on the chest holding the logs, with two
    -- other drones stacked in the column directly above it so it could not rise at all, and it spent
    -- six minutes per attempt trying to travel to other chests to look for what was already beneath
    -- it. The bay is the busiest airspace in the settlement precisely because it is where the chests
    -- are, so "do not move" is the cheapest and most reliable option available here, not a shortcut.
    if ContainerBelow() then
        Doing(("looking for %s in the chest below"):format(tostring(s_First):gsub("^minecraft:", "")))
        TakeFromChest(s_Match)
        s_Got = tally()
        if short(s_Got) == nil then
            trace("fetch: it was in the chest we were already standing on")
            return s_Got, nil
        end
    end

    -- The fast path: one lookup, one flight.
    local s_Tried = {}
    local function tryChest(pos)
        if type(pos) ~= "table" or pos.x == nil then return false end
        local k = ("%d:%d:%d"):format(pos.x, pos.y, pos.z)
        if s_Tried[k] then return false end
        s_Tried[k] = true
        if not ArriveAt(pos.x, pos.y + 1, pos.z, (pos.y or 64) + 4) then return false end
        TakeFromChest(s_Match)     -- reports its own contents, repairing the index
        return true
    end

    local s_Where = PowNet.sendAndWaitForResponse("StorageMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "WhereIs", {match = tostring(s_First or "")}),
        PowNet.SERVER_PROTOCOL)
    if type(s_Where) == "table" and s_Where.pos then
        tryChest(s_Where.pos)
        s_Got = tally()
        if short(s_Got) == nil then return s_Got, nil end
        trace(("fetch: not at %d,%d,%d after all -- sweeping the bay")
            :format(s_Where.pos.x, s_Where.pos.y, s_Where.pos.z))
    end

    -- The index was wrong or silent. Look, and record what is actually there.
    local s_Points = PowNet.sendAndWaitForResponse("StorageMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "DepositPoints", {}), PowNet.SERVER_PROTOCOL)
    local s_List = (type(s_Points) == "table" and s_Points.points) or {}
    -- Chests we have looked inside and know do NOT hold this are not worth flying to. A chest with
    -- no observation on record still is -- unknown is not the same as empty, and skipping the
    -- unknown ones is how the item stays lost.
    local s_Order = {}
    for _, pt in ipairs(s_List) do
        local seen = pt.items
        local skip = false
        if type(seen) == "table" then
            skip = true
            for nm, n in pairs(seen) do
                if (tonumber(n) or 0) > 0 and s_Match(nm) then skip = false break end
            end
        end
        if not skip then s_Order[#s_Order + 1] = pt end
    end
    if #s_Order < #s_List then
        trace(("fetch: %d of %d chests are known not to hold it -- skipping them")
            :format(#s_List - #s_Order, #s_List))
    end
    Doing(("searching %d chest(s) for %s"):format(#s_Order, tostring(s_First):gsub("^minecraft:", "")))
    for _, pt in ipairs(s_Order) do
        local pos = pt.pos or pt
        -- Once we hold enough to be useful, only chests we have actually SEEN the item in are worth
        -- the flight. An unobserved chest is a gamble, and the bay is too busy to gamble in.
        if belowMinimum(s_Got) ~= nil or type(pt.items) == "table" then
            if tryChest(pos) then
                s_Got = tally()
                if short(s_Got) == nil then
                    trace(("fetch: found it at %d,%d,%d"):format(pos.x, pos.y, pos.z))
                    return s_Got, nil
                end
            end
        end
    end

    if belowMinimum(s_Got) == nil then
        trace("fetch: short of the full order, but holding enough to make a start")
        return s_Got, nil
    end
    Doing(("cannot find %s anywhere in storage"):format(tostring(short(s_Got)):gsub("^minecraft:", "")))
    return s_Got, short(s_Got)
end

-- Put everything down into the container below. Returns what moved, or nil if there is none.
-- Split out because "unload here" is the same six lines in three places and the interesting part --
-- reporting what ACTUALLY moved rather than what we intended to move -- was written differently in
-- each of them.
local function unloadHere()
    if not ContainerBelow() then return nil end
    local s_Put = {}
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            local det = turtle.getItemDetail(i)
            local before = turtle.getItemCount(i)
            PutDown()
            local moved = before - turtle.getItemCount(i)
            if det and det.name and moved > 0 then
                s_Put[det.name] = (s_Put[det.name] or 0) + moved
            end
        end
    end
    turtle.select(1)
    return s_Put
end

-- MOVE THE LOAD OUT OF THE DRONE, REPORT IT, AND SAY HOW MUCH WENT.
--
-- unloadHere does the moving; this adds the two reports that must follow it. DepositNow carried its
-- own copy of the sixteen-slot loop TWICE more, and the copies had already drifted apart -- one
-- counted what actually moved, the other assumed PutDown emptied the slot. Stock here is OBSERVED,
-- so a deposit that reports more than it moved poisons every planning decision downstream until the
-- next chest reading corrects it.
--
-- Going through unloadHere also means the ContainerBelow() guard applies on every path. The inline
-- copies had no such guard: they ran the full loop into thin air and reported a successful deposit.
function UnloadInto()
    local s_Put = unloadHere()
    if s_Put == nil then
        trace("deposit: nothing below to unload into")
        return 0
    end
    ReportStorage("Deposited", s_Put)
    ReportChest()
    local n = 0
    for _, c in pairs(s_Put) do n = n + c end
    return n
end

-- HIGH ENOUGH TO ACTUALLY REACH FOUR HOSTS, WHICH 84 WAS NOT.
--
-- CC:T scales wireless range with altitude -- max(modem_range, high_altitude_range * y/maxHeight),
-- here max(64, 384 * y/320) -- so 84 buys about 100 blocks and 110 buys about 132. Measured: all
-- five stranded drones surfaced to y=87, raised fewer than the four hosts gps.locate needs, and
-- reported no fix. They were 77-109 blocks out, and the constellation sits at y=81-94 spread around
-- the base, so at that distance only two or three could hear them.
--
-- Climbing the extra twenty-odd blocks is nearly free once the drone is already in open air -- it
-- is moving, not digging -- and it is the difference between a fix and dead reckoning.
local SKY_FIX_Y = 110
-- The highest this recovery will ever climb. Range keeps growing with altitude in theory, but the
-- GPS hosts sit at y=81-94 and THEIR range is the binding constraint on the reply -- so climbing
-- past this buys nothing and costs fuel, air, and the risk of an unbounded ascent.
local SKY_FIX_CEILING = 140

-- Declared above SurfaceForFix, which is now the first thing to need them. A `local` used above
-- its declaration is a nil GLOBAL lookup in Lua -- silent, and the comparison would simply throw.
--
-- 900 -> 300, AND THE 900 IS WHY THE FLEET KEPT STOPPING.
--
-- The flat reserve was sized for the worst case of pathfinder thrash: "moveTo, then digTo (256
-- steps), then flyTo (512)" -- a drone could burn 768 fuel going nowhere, so it had to hold more
-- than that before it was allowed to start. That reasoning was sound when it was written. The
-- 512-fuel half of it was the climb to CRUISE_Y, and that flyover has been deleted: a route A*
-- cannot supply is now reported instead of flown around at altitude. The worst case it was
-- defending against no longer exists, so the number defending against it should not either.
--
-- What it cost while it stayed: the floor is FUEL_RESERVE + 3/block home, so a drone sitting AT
-- base needs ~900 before it may do anything at all. D4 was found holding 946 against a floor of
-- ~950 -- a FOUR fuel shortfall -- and that was enough to put it in permanent distress, which makes
-- it report "stuck", which makes pickDrone skip it, which left every one of eight queued tasks
-- unassigned while 64 coal sat in a chest it would not walk to. The entire settlement was blocked
-- on a rounding error. D15 did the same thing at 829, refusing a lumber run costing under 150.
--
-- 300 still covers a local search plus a bounded walk home on top of the distance term, and the
-- system is now far better at recovering when it is wrong: relief can be carried by any drone, a
-- write-off expires, and the floor collapses entirely when storage is known dry.
local FUEL_RESERVE = 300
local FUEL_PER_BLOCK_HOME = 3

-- NEVER SPEND THE LAST OF THE FUEL GAINING ALTITUDE.
--
-- Climbing to find GPS is worth doing and is NOT worth being stranded for. Every failed deposit
-- calls SurfaceForFix, so a drone that cannot reach storage climbs again and again -- and each
-- climb is thirty to forty blocks of fuel it may not be able to spend twice.
--
-- Measured: D3 was found at y=96 with zero fuel, D14 at 68 and D17 at 72, all above a base at y=64,
-- all dry. They had not run out working; they had run out CLIMBING. A drone stranded at ninety-six
-- is far worse off than one merely unsure of itself at ground level -- it cannot even be reached by
-- the fuel relief, because the relief has to fly up to it.
--
-- The climb must be affordable twice over: once up, once back down to the bay.
local function climbForFixIfAffordable(p_Cy)
    local s_Target = math.min(math.max(SKY_FIX_Y, (p_Cy or 64) + 8), SKY_FIX_CEILING)
    if (p_Cy or 0) >= s_Target then return false end
    local s_Rise = math.max(0, s_Target - (p_Cy or 64))
    local s_Fuel = turtle.getFuelLevel()
    if s_Fuel ~= "unlimited" and s_Fuel < (s_Rise * 2 + FUEL_RESERVE) then
        trace(("skipping the climb to y=%d: %d fuel will not pay for %d blocks up and back")
            :format(s_Target, s_Fuel, s_Rise))
        return false
    end
    ClimbToOpenAir(s_Target)
    return true
end

-- WHEN YOU DO NOT KNOW WHERE YOU ARE, GET TO OPEN SKY BEFORE YOU DECIDE WHICH WAY TO GO.
--
-- Fixing the unchecked turtle.back() in pgps stops position error ACCUMULATING, but it cannot undo
-- error already recorded. Five drones came out of that bug believing they were 18 to 66 blocks from
-- base when they were 60 to 117 -- and every recovery path they have reasons from that number.
-- Walking "home" from a position that is wrong by 65 blocks walks the wrong way, which is precisely
-- how D13 travelled from z=103 to z=174 while trying to come back.
--
-- Dead reckoning cannot detect its own error; only a fix can. GPS does not reach underground, so
-- the drone has to go and get one, and going UP is the only direction guaranteed to help: modem
-- range grows with altitude and the mast is above ground. This is what a lost person does -- climb
-- until you can see a landmark -- and it is cheap, about 26 digs from mining depth.
--
-- Returns true if the position is trustworthy afterwards.
-- WALK UNTIL THE SKY ANSWERS. THE LAST RESORT FOR A DRONE NOTHING CAN PLACE.
--
-- A drone far enough out has no GPS (fewer than four hosts in earshot) and no peers (nobody else is
-- that far from base), so every method that DERIVES a position has nothing to work from. D6 sat in
-- exactly that state: 122 blocks out, holding 475 items, its saved pose wrong by 82 blocks, quietly
-- correct to hold still and completely unable to ever stop holding still.
--
-- But there is one fact available to it that needs no fix, no peers and no map: whether a fix is
-- OBTAINABLE HERE. That is a measurement, not an inference. Walk a little and take it again --
-- toward the constellation it improves, away from it, it does not. So try a direction, test, and
-- keep whichever direction starts answering.
--
-- This is what a person does when their phone has no signal: walk a bit and look again. It cannot
-- be fooled by a wrong position or a wrong heading, because it never consults either -- it only
-- needs the moves to be REVERSIBLE, so a wrong guess costs a walk back and nothing else.
--
-- Bounded hard: four directions, SEEK_LEG blocks each, returning to the start between attempts. The
-- worst case is a few hundred moves, which is cheap against a drone that is otherwise lost for good.
local SEEK_LEG  = 32          -- how far to probe down one direction
local SEEK_STEP = 8           -- test for a fix this often along the way
function SeekCoverage()
    if pgps.positionVerified() then return true end
    trace("no fix and no peers -- walking to find out where the GPS is")

    for _ = 1, 4 do
        local s_Went = 0
        while s_Went < SEEK_LEG do
            local s_Step = 0
            while s_Step < SEEK_STEP do
                if CanDig() then DigForward() end
                if not pgps.forward() then break end
                s_Step = s_Step + 1
            end
            s_Went = s_Went + s_Step
            if s_Step == 0 then break end                  -- blocked; this direction is no good

            if pgps.verifyPosition(true) then
                trace(("found GPS after %d block(s) -- we are placed again"):format(s_Went))
                return true
            end
        end

        -- Nothing this way. Go back the way we came so the next probe starts from the same spot,
        -- rather than compounding four wrong guesses into one long walk to nowhere.
        if s_Went > 0 then
            pgps.turnRight() pgps.turnRight()
            for _ = 1, s_Went do
                if CanDig() then DigForward() end
                if not pgps.forward() then break end
            end
            pgps.turnRight() pgps.turnRight()
        end
        pgps.turnRight()                                   -- next direction
    end

    trace("walked all four ways and found no GPS -- staying put for a rescuer")
    return false
end

-- RE-DERIVE THE HEADING WHILE THERE IS STILL A FIX TO COMPARE AGAINST.
--
-- verifyPosition repairs where we are and says nothing about which way we face, and nothing else
-- ever re-checks a heading once it is set -- so a drone just told it is 90 blocks from where it
-- thought will set off in the same wrong direction that put it there.
--
-- Traced, not printed. pgps announces the new heading with print(), which reaches the turtle's
-- screen and nowhere else, so the one fact that would have identified this bug days ago was being
-- written where only somebody standing in the world could read it.
function ConfirmHeading()
    local _, _, _, s_Was = pgps.getCachedPosition()
    local s_Ok = pcall(pgps.ensureHeading, true)
    local _, _, _, s_Now = pgps.getCachedPosition()
    if not s_Ok then
        trace("could not re-check heading -- keeping the old one")
    elseif s_Was ~= s_Now then
        trace(("HEADING WAS WRONG: we thought %s, we actually face %s")
            :format(tostring(s_Was), tostring(s_Now)))
    else
        trace(("heading confirmed as %s"):format(tostring(s_Now)))
    end
end

function SurfaceForFix()
    if pgps.positionVerified() then return true end
    local _, cy = pgps.getCachedPosition()
    trace(("position unverified at y=%s -- surfacing for a GPS fix"):format(tostring(cy)))
    -- AN ABSOLUTE CEILING, NOT A RELATIVE ONE. THIS RATCHETED.
    --
    -- This read `max(cy + 24, SKY_FIX_Y)` -- twenty-four blocks above wherever we happen to be. It
    -- looked like "climb a bit higher if already high", and it is unbounded: every retry lifts the
    -- target another twenty-four, so a drone that cannot get a fix climbs for ever. D8 was found at
    -- y=217 doing exactly that, on its way to the build limit, still failing to raise four hosts and
    -- still climbing, having turned a recovery into an ascent.
    --
    -- Height buys modem range only up to a point, and past SKY_FIX_Y the extra blocks buy nothing a
    -- fix was going to come from. If we are already above it, we are as high as this helps.
    -- NEVER SPEND THE LAST OF THE FUEL GAINING ALTITUDE.
    --
    -- Climbing to find GPS is worth doing and is NOT worth being stranded for. Every failed deposit
    -- calls this, so a drone that cannot reach storage climbs again and again -- and each climb is
    -- thirty to forty blocks of fuel it may not be able to spend twice.
    --
    -- Measured: D3 was found at y=96 with zero fuel, D14 at 68 and D17 at 72, all above a base at
    -- y=64, all dry. They had not run out working; they had run out CLIMBING, and a drone stranded
    -- at ninety-six is far worse off than one that is merely unsure of itself at ground level -- it
    -- cannot even fall back on the fuel relief, because the relief has to fly up to reach it.
    --
    -- The climb must be affordable twice over: once to get up, once to get back down to the bay.
    climbForFixIfAffordable(cy)
    local s_Ok, s_Drift = pgps.verifyPosition(true)
    if s_Ok then
        trace(("position re-fixed, we were out by %s block(s)"):format(tostring(s_Drift or 0)))
        -- A CORRECT POSITION WITH A WRONG HEADING STILL WALKS THE WRONG WAY.
        --
        -- verifyPosition repairs where we are and says nothing about which way we face, and nothing
        -- else ever re-checks a heading once it is set -- so the drone that has just been told it is
        -- 90 blocks from where it thought will now set off in the same wrong direction that put it
        -- there. Re-derive while we still have the fix to compare against; it is two moves.
        --
        ConfirmHeading()
        return true
    end

    -- ASK THE FLEET. THIS IS WHAT THE MESH IS FOR.
    --
    -- gps.locate needs FOUR hosts in earshot, and out at 80-110 blocks a drone typically raises two
    -- or three -- so it gets nothing, from a constellation that is working perfectly. But its peers
    -- are right there: the same drones already relaying its heartbeat home, several of them holding
    -- real GPS fixes. Four of those with a measured distance is the same maths gps.locate does, and
    -- the modem hands us the distance on every message for free.
    --
    -- This is the point of a mesh -- position is a thing the fleet knows collectively even when no
    -- single drone can see enough of the constellation to work it out alone.
    if type(TrilaterateFromPeers) == "function" then
        local tx, ty, tz, terr = TrilaterateFromPeers()
        if tx then
            trace(("no GPS out here -- the fleet places us at %d,%d,%d (anchors agree to %d)")
                :format(tx, ty, tz, math.floor(terr or 0)))
            pcall(pgps.setLocation, tx, ty, tz, nil)
            return true
        end
    end

    -- LAST RESORT, AND THE MOST IMPORTANT ONE: GET THE HEADING RIGHT EVEN IF THE POSITION IS NOT.
    --
    -- A position that is off by twenty blocks still points home well enough from eighty blocks out,
    -- and it repairs itself the moment the drone gets back into GPS range. A heading that is off by
    -- ninety or a hundred and eighty degrees never repairs itself at all, because the drone never
    -- arrives anywhere that could tell it. So when we cannot pin down WHERE we are, it is still
    -- worth establishing WHICH WAY WE FACE -- that alone converts "lost" into "slow".
    --
    -- Returns false regardless: the caller must not walk on a position this vague. But the heading
    -- is now correct for whoever does move next, including the next attempt after peers come and go.
    if type(HeadingFromPeers) == "function" then
        local s_Dir, s_Err = HeadingFromPeers()
        local _, _, _, s_Have = pgps.getCachedPosition()
        if s_Dir ~= nil and s_Dir ~= s_Have then
            trace(("HEADING WAS WRONG: thought %s, the neighbours say %s (fit %.2f)")
                :format(tostring(s_Have), tostring(s_Dir), s_Err or 0))
            pcall(pgps.setHeading, s_Dir)
        elseif s_Dir ~= nil then
            trace("no fix, but the neighbours confirm which way we face")
        end
    end

    -- Everything that DERIVES a position has failed. The one thing left is to go and find the
    -- coverage rather than wait for it to arrive, which for a drone this far out it never will.
    if type(SeekCoverage) == "function" and SeekCoverage() then return true end

    trace("still no fix after surfacing, and too few peers to triangulate against")
    return false
end

-- A DRONE THAT CANNOT REACH STORAGE IS NOT STUCK, IT IS TOO FAR AWAY.
--
-- DepositNow opened by asking StorageMan where to unload, and treated no answer as a dead end:
-- Distress, return false, and the idle loop tried again in sixty-five seconds with nothing changed.
-- Five drones did exactly that for between three and four hours, holding 1,922 items between them,
-- while the mesh sat right there relaying their heartbeats home the whole time.
--
-- The tower is unreachable because of DISTANCE, and distance is the one thing the drone can fix by
-- itself. Walking back toward base restores the link that answers the question -- so a failed
-- lookup schedules a step home instead of a retry in place. It converges; retrying does not.
function DepositTarget()
    local s_Res = PowNet.sendAndWaitForResponse("StorageMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "DepositPoint", {}), PowNet.SERVER_PROTOCOL)
    if type(s_Res) == "table" and s_Res.pos ~= nil then
        m_HomePos = s_Res.pos
        return s_Res.pos
    end

    -- A BEARING IS ONLY AS GOOD AS THE POSITION IT STARTS FROM. NO FIX, NO WALK.
    --
    -- This called SurfaceForFix and then walked home REGARDLESS of whether it got a fix, which is
    -- the same mistake in a new place: a bearing computed from a position that is wrong by 65 blocks
    -- points somewhere that is not home. Measured directly -- the five stranded drones surfaced to
    -- y=87 as intended, failed to raise four GPS hosts at that distance, walked anyway, and every
    -- one of them ended FURTHER from base than it started. D6 went from 85 blocks out to 109, D9
    -- from 77 to 92, each step logged cheerfully as "closing the gap".
    --
    -- Standing still is not giving up. The drone is now in open air at altitude, which is the best
    -- place it can be for both GPS and the mesh, and the fleet moves around it: peers pass, relays
    -- come up, and the next attempt may well get the fix this one could not. Moving on a position
    -- known to be wrong is the only option here with no upside.
    if not SurfaceForFix() then
        trace("holding position: no fix, and walking on a guess is what stranded us")
        return nil
    end

    local hx, hy, hz
    if type(HomeXYZ) == "function" then hx, hy, hz = HomeXYZ() end
    local cx, cy, cz = pgps.getCachedPosition()
    if hx == nil or cx == nil then
        Distress("nowhere to deposit", tostring(type(s_Res) == "table" and s_Res.message or s_Res))
        return nil
    end

    local s_Away = math.sqrt((hx - cx) ^ 2 + (hz - cz) ^ 2)
    trace(("deposit: storage unreachable and we are %d block(s) out -- closing the gap first")
        :format(math.floor(s_Away)))
    -- One bounded leg per attempt, not a march. The idle loop calls this again, and each call ends
    -- nearer the mast, so the link comes back on its own without a long uninterruptible journey
    -- that a fresh order could not interrupt.
    local tx = cx + math.max(-24, math.min(24, hx - cx))
    local tz = cz + math.max(-24, math.min(24, hz - cz))
    local ty = math.max(cy or hy, hy)
    -- Pathfind the leg home. This flew it, which is how a drone that could not route simply rose
    -- over the obstacle and carried on -- ending higher, further out, and still not home.
    if pgps.moveTo(tx, ty, tz) == false and CanDig() then pgps.digTo(tx, ty, tz) end
    return nil
end

-- CUT STRAIGHT UP INSTEAD OF TUNNELLING SIDEWAYS OUT OF A HOLE.
--
-- digTo works its axes horizontally first and vertically last, which is right when cutting a
-- walkable tunnel and wrong when the job is "get out of this hole and go home": from y=38 it bores
-- sideways through stone for its entire 256-step budget and gives up 550 seconds later, having
-- travelled most of the way to nowhere. Twenty-six digs upward puts the drone in open air, where
-- moveTo and flyTo both work properly.
function ClimbToOpenAir(p_Ceiling)
    local s_Rose = 0
    while true do
        local _, cy = pgps.getCachedPosition()
        if cy == nil or cy >= p_Ceiling then break end
        DigUp()
        if not pgps.up() then break end
        s_Rose = s_Rose + 1
        if s_Rose > 128 then break end                  -- bounded: never an unbounded climb
    end
    local _, cy = pgps.getCachedPosition()
    trace(("deposit: rose %d block(s) to y=%s"):format(s_Rose, tostring(cy)))
    return s_Rose
end

-- ANY CHEST WILL DO. A BLOCKED ONE IS NOT A REASON TO GIVE UP.
--
-- Deposit gave up the moment the NOMINATED point was unreachable, and the settlement deadlocked on
-- it: the crafter was parked on the access square of the one chest everything was aimed at, so the
-- miner carrying the logs the crafter was waiting for could not land, failed its deposit, and
-- failed the whole gather -- 42 minutes, one of 192 targets checked, nothing delivered. Neither
-- drone was faulty and neither could make progress.
function UnloadAtAnyOtherChest(p_Skip)
    local s_All = PowNet.sendAndWaitForResponse("StorageMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "DepositPoints", {}), PowNet.SERVER_PROTOCOL)
    for _, pt in ipairs((type(s_All) == "table" and s_All.points) or {}) do
        local q = pt.pos or pt
        local s_Same = type(q) == "table" and q.x == p_Skip.x and q.y == p_Skip.y and q.z == p_Skip.z
        if type(q) == "table" and q.x ~= nil and not s_Same then
            trace(("deposit: %d,%d,%d is blocked -- trying %d,%d,%d instead")
                :format(p_Skip.x, p_Skip.y, p_Skip.z, q.x, q.y, q.z))
            if ArriveAt(q.x, q.y + 1, q.z, (q.y or 64) + 4) then
                local n = UnloadInto()
                if n > 0 then
                    trace(("deposit: unloaded %d item(s) at the alternate chest"):format(n))
                    return true
                end
            end
        end
    end
    return false
end

-- ARRIVE, AND IF A DRONE IS SITTING ON THE SQUARE, ASK IT TO MOVE AND TRY ONCE MORE.
--
-- The access square of a chest is a single block, and the drone occupying it is usually one that has
-- just finished using the chest -- so the obstruction is not congestion in general, it is one
-- specific drone that no longer needs to be there. Asking costs one message.
--
-- Ask ONLY when actually blocked. This used to broadcast a make-way before every trip, so five
-- drones cycling deposits produced a continuous stream of requests that every drone had to receive
-- and evaluate, almost all about squares nobody was standing on. A guess dressed up as an
-- optimisation.
function ArriveOrAskToMove(p_X, p_Y, p_Z, p_Ceiling, p_What)
    local s_Arrived = ArriveAt(p_X, p_Y, p_Z, p_Ceiling)
    if s_Arrived then return true end

    -- SAY SO. Callers guard on `== false`, so an ArriveAt returning nil rather than false walked
    -- past every fallback and out of the function without a word. Three deposits vanished that way,
    -- each leaving exactly one "heading to" line and no outcome.
    trace(p_What .. ": could not arrive -- trying the fallback routes")

    local s_Blocker = DroneInTheWay(p_X, p_Y, p_Z)
    if not s_Blocker then return false end
    trace(("%s: a DRONE is on the access square at %d,%d,%d -- asking it to move")
        :format(p_What, s_Blocker.x, s_Blocker.y, s_Blocker.z))
    AskToMakeWay(s_Blocker.x, s_Blocker.y, s_Blocker.z)
    os.sleep(2)                                          -- let it take its step
    if ArriveAt(p_X, p_Y, p_Z, p_Ceiling) then
        trace(p_What .. ": the square cleared")
        return true
    end
    return false
end

-- ONE LADDER, NOT ONE PER CALLER.
--
-- moveTo alone routes only through surveyed, passable cells. A miner calls it from the far end of a
-- tunnel it has just cut, which by definition nobody has surveyed -- so it fails, and every caller
-- that wanted "just get there" grew its own moveTo -> climb -> digTo -> flyTo chain to cope. They
-- were not the same chain: some omitted the climb, some omitted the pickaxe check, one omitted the
-- trace, and the deposit path was the only one that had all four. The result was that the same
-- journey succeeded or failed depending on which function asked for it.
--
-- The consequence of the missing rungs was never a missed trip, it was a stalled economy:
-- depositIfFull() returns Deposit()'s result and Gather breaks out of its loop the moment it is
-- false, so every gather ended at its first candidate with "took nothing" -- for hours, while two
-- drones sat at zero fuel waiting for the coal it was going to bring back.
function ReachByAnyMeans(p_X, p_Y, p_Z, p_Ceiling, p_What)
    local s_What = p_What or "travel"
    local ok = pgps.moveTo(p_X, p_Y, p_Z)
    if ok ~= false then return ok end

    if CanDig() then
        local _, s_Cy = pgps.getCachedPosition()
        local s_Ceiling = p_Ceiling or ((p_Y or 64) + 4)
        if s_Cy and s_Cy < s_Ceiling then
            trace(("%s: buried at y=%d -- cutting up to y=%d"):format(s_What, s_Cy, s_Ceiling))
            ClimbToOpenAir(s_Ceiling)
            ok = pgps.moveTo(p_X, p_Y, p_Z)
        end
    end
    if ok == false and CanDig() then
        trace(s_What .. ": still no route -- digging out")
        ok = pgps.digTo(p_X, p_Y, p_Z)
    end
    -- No flyTo rung here either, for the reason spelled out in TravelTo: it reads no map, cannot
    -- dig, climbs over whatever blocks it, and measured across a night of logs it wedged more often
    -- than it was even reached.
    return ok
end

-- Wraps the real deposit so the in-progress flag is set and cleared on EVERY exit path -- there are
-- eight returns in here, and a flag left set would freeze the drone's reported status for ever.
function Deposit()
    m_Depositing = true
    local ok, a, b = pcall(DepositNow)
    m_Depositing = false
    if not ok then
        trace("deposit threw: " .. tostring(a))
        return false
    end
    return a, b
end

function DepositNow()
    -- THE CHEST YOU ARE STANDING ON IS A DEPOSIT POINT.
    --
    -- This always flew to whichever chest StorageMan nominated, even when the drone was parked on a
    -- perfectly good one -- and that flight is where deposits died. The crafter finished 32 oak
    -- planks while sitting on the chest at -476, was sent to -474 two blocks away, could not get
    -- there because the bay was crowded with three other drones, and came back still holding them.
    -- Three times, and each time the only evidence was a "heading to" line with nothing after it.
    --
    -- A crafter has no pickaxe, so it cannot dig its way out of a blocked route the way a miner can;
    -- for it, "the bay is busy" is permanent. Using what is already underneath removes the flight,
    -- the contention and the failure together.
    do
        local s_Here = unloadHere()
        if s_Here ~= nil then
            local n = 0
            for _, c in pairs(s_Here) do n = n + c end
            if n > 0 then
                trace(("deposit: unloaded %d item(s) into the chest below"):format(n))
                ReportStorage("Deposited", s_Here)
                ReportChest()
                return true
            end
        end
    end

    local s_Point = DepositTarget()
    if s_Point == nil then return false end
    local s_Res = { pos = s_Point }
    local hx, hy, hz = pgps.getCachedPosition()
    m_Status = "hauling"
    SendHeartBeat()

    -- THE SAME moveTo -> digTo -> flyTo CHAIN EVERY OTHER TRAVEL PATH NEEDED.
    --
    -- moveTo alone routes only through surveyed, passable cells. A miner calls this from the far
    -- end of a tunnel it has just cut, which by definition nobody has surveyed -- so the deposit
    -- fails, and it fails SILENTLY as far as the log is concerned because Deposit traces nothing.
    --
    -- The consequence was not a missed deposit, it was a stalled economy. depositIfFull() returns
    -- Deposit()'s result, and Gather breaks out of its loop the moment it is false. So every gather
    -- ended at its first candidate with "took nothing", the task was requeued, reassigned, and
    -- failed identically -- for hours, while two drones sat at zero fuel waiting for the coal it
    -- was going to bring back. A miner is carrying the tool that solves this.
    trace(("deposit: heading to %d,%d,%d"):format(s_Res.pos.x, s_Res.pos.y, s_Res.pos.z))
    -- Same arrival check as CollectFuel, for the same reason: dropping a load one block off the
    -- chest scatters it on the floor, and the drone reports a successful deposit either way.
    local s_Arrived = ArriveOrAskToMove(
        s_Res.pos.x, s_Res.pos.y + 1, s_Res.pos.z, (s_Res.pos.y or 64) + 4, "deposit")
    if s_Arrived then
        trace("deposit: arrived, unloading")
        UnloadInto()
        if hx then
            if pgps.moveTo(hx, hy, hz) == false and CanDig() then pgps.digTo(hx, hy, hz) end
        end
        m_Status = "mining"
        return true
    end
    local ok = ReachByAnyMeans(
        s_Res.pos.x, s_Res.pos.y + 1, s_Res.pos.z, (s_Res.pos.y or 64) + 4, "deposit")
    if ok == false then
        -- ANY CHEST WILL DO. A BLOCKED ONE IS NOT A REASON TO GIVE UP.
        --
        -- This gave up the moment the NOMINATED point was unreachable, and the settlement deadlocked
        -- on it: the crafter was parked on the access square of the one chest everything was aimed
        -- at, so the miner carrying the logs the crafter was waiting for could not land, failed its
        -- deposit, and failed the whole gather -- 42 minutes, one of 192 targets checked, nothing
        -- delivered. Neither drone was faulty and neither could make progress.
        --
        -- There are four chests. Storage does not care which one the wood goes in, and the fetch
        -- side now finds items wherever they actually are, so spreading the load costs nothing.
        if UnloadAtAnyOtherChest(s_Res.pos) then return true end
        trace("deposit: could not reach storage")
        Distress("cannot reach any storage point", s_Res.pos.x .. "," .. s_Res.pos.y .. "," .. s_Res.pos.z)
        return false
    end
    trace("deposit: arrived, unloading")
    UnloadInto()
    -- Back to where we were, so a dig resumes at the face instead of starting over. Best effort:
    -- failing to get back is not a failed deposit -- the load is already in the chest.
    if hx then
        if pgps.moveTo(hx, hy, hz) == false and CanDig() then pgps.digTo(hx, hy, hz) end
    end
    m_Status = "mining"
    return true
end

-- REFUEL WHILE WORKING, NOT ONLY WHEN IDLE.
--
-- TryRefuel ran only when a drone was idle AND not executing, so a miner burned steadily to zero
-- mid-shaft and never touched the coal it was carrying -- D1 reached fuel 0 holding a gather job for
-- coal ore. At zero it cannot move, cannot reach the dock where the fuel is, and cannot be rescued
-- except by another drone digging to it.
--
-- This runs on every bore step, which is the natural place: it is already the per-step housekeeping
-- hook, and a miner is exactly the drone most likely to be carrying something burnable.

-- COME HOME WHILE YOU STILL CAN.
--
-- Refuelling mid-job only helps if the drone is CARRYING something burnable, and a miner that has
-- deposited its coal is not. D1 hit fuel 0 twice: at zero it cannot move, cannot reach the barrel
-- that has the fuel in it, and cannot be recovered except by another drone digging to it. Running
-- out is not an emergency to survive, it is one to avoid.
--
-- So there is a floor. Below it the drone stops working and docks -- while it still has the fuel to
-- get there -- and the dock is where the coal is. Returning early costs a trip; running dry costs
-- the drone.
local FUEL_TOPUP  = 2000

-- When we last went to storage for fuel and found none, and how long that answer is trusted.
--
-- See RefuelAtStorage: without this a drone under its floor breaks off work, walks to empty
-- chests, finds nothing and immediately does it again, while every other drone does the same --
-- gridlocking the bay so thoroughly that a one-block hop fails and a gather spends 264s on a
-- single candidate. The fuel it needs can only come from a gather that this behaviour prevents.
--
-- 180s because the fix for an empty larder is a gather or a smelt, and neither finishes faster
-- than that. Re-checking sooner cannot find anything and costs another trip through the bay.
local m_StorageDryAt = nil
local STORAGE_DRY_TRUST = 180

-- Fuel level below which an empty larder stops being a reason to keep working.
--
-- The point of ignoring the floor is to keep drones out of the bay while there is nothing to
-- collect. It is NOT to let one strand itself: at this level the trip is still affordable, and a
-- drone parked near storage with a little fuel can be relieved, whereas one that ran to zero in
-- the field cannot. Well under the ~1,038 distance-scaled floor that was causing the thrash.
local FUEL_STRANDING_RISK = 400

-- Should we skip breaking off to refuel because storage was empty a moment ago?
--
-- A GLOBAL, and declared here above the fuel watchdog that calls it: a `local` used above its
-- declaration is a nil global in Lua, silently, which is the most expensive mistake in this file.
function StorageKnownDry(p_Fuel)
    if m_StorageDryAt == nil then return false end
    if (os.clock() - m_StorageDryAt) > STORAGE_DRY_TRUST then return false end
    -- Genuinely low beats a stale "it was empty": go and look again rather than strand.
    if type(p_Fuel) == "number" and p_Fuel < FUEL_STRANDING_RISK then return false end
    return true
end
-- THE RESERVE HAS TO COVER THE TRIP HOME, AND THE TRIP HOME IS NOT A CONSTANT.
--
-- 600 flat was not a reserve, it was a coincidence. The journey it has to pay for is moveTo, then
-- digTo (256 steps), then flyTo (512) -- so a drone that fails the first two can spend 768 fuel
-- thrashing before it has gone anywhere, which is more than the reserve that triggered the trip.
-- All three drones did exactly that: the watchdog fired correctly at ~600, they set off for
-- storage, and they hit zero on the way -- nine blocks from a chest holding 192 coal, unable to
-- move, with the fuel-relief tasks for each other sitting unassigned because nobody could carry
-- anything.
--
-- So the floor scales with how far away home is. Three fuel per block of Manhattan distance covers
-- a route that is not a straight line, plus a flat allowance for the search itself.

-- Where storage is, remembered from the last time we asked. A drone that is nearly out of fuel
-- should not have to complete a network round trip before it is allowed to worry about it.
-- What this drone must keep in the tank RIGHT NOW to be sure of reaching storage from where it is
-- standing. Falls back to the flat reserve until it has learned where home is.
--
-- A GLOBAL, deliberately. depositIfFull is defined above the fuel watchdog and both need this; a
-- `local function` here would be invisible to everything declared before it, which is the single
-- most expensive mistake in this codebase -- six outages and counting.
-- AN EMPTY LARDER MAKES THE RESERVE WORTHLESS, AND THE RESERVE MAKES THE LARDER PERMANENT.
--
-- FUEL_RESERVE is 900 flat, on top of the distance term. The 900 buys one thing: certainty that the
-- drone can reach STORAGE AND REFUEL THERE. When storage has no fuel in it, that purchase is void
-- -- arriving changes nothing -- and the only thing the 900 still does is forbid work.
--
-- That is a deadlock, not an inefficiency, because the work it forbids is the work that ENDS the
-- shortage. Measured: D15 holding 829 fuel, twenty blocks from base, with a verified oak tree 33
-- blocks away and a round trip that costs under 150. It declared "DISTRESS: low fuel level 829,
-- nothing to refuel with at the dock", refused the lumber job, flew to an empty chest, found
-- nothing, and did it again -- while the settlement's entire fuel income depended on that one
-- gather. Charcoal is made from logs; logs are cut by a drone; the drone would not go because it
-- was saving fuel to visit a chest that could not help it.
--
-- So when storage is KNOWN dry, the floor collapses to what it is actually for: getting home, plus
-- a margin for the search at the far end. The full reserve returns the moment there is fuel to
-- reserve for. StorageKnownDry already refuses to answer true below FUEL_STRANDING_RISK, so a
-- genuinely nearly-empty drone still gets the big floor and still goes to look -- this relaxes the
-- floor for drones with hundreds of fuel in the tank, which is exactly who was being paralysed.
--
-- A GLOBAL, deliberately. depositIfFull is defined above the fuel watchdog and both need this; a
-- `local function` here would be invisible to everything declared before it, which is the single
-- most expensive mistake in this codebase -- six outages and counting.
local FUEL_DRY_MARGIN = 120
function FuelFloorNow()
    if m_HomePos == nil then return FUEL_RESERVE end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return FUEL_RESERVE end
    local d = math.abs(m_HomePos.x - cx) + math.abs(m_HomePos.y - cy) + math.abs(m_HomePos.z - cz)
    local s_Trip = d * FUEL_PER_BLOCK_HOME
    if StorageKnownDry(turtle.getFuelLevel()) then return s_Trip + FUEL_DRY_MARGIN end
    return FUEL_RESERVE + s_Trip
end

local function depositIfFull()
    local s_Fuel = turtle.getFuelLevel()
    if s_Fuel ~= "unlimited" then
        if s_Fuel < FUEL_TOPUP then pcall(TryRefuel) end
        s_Fuel = turtle.getFuelLevel()
        if s_Fuel ~= "unlimited" and s_Fuel < FuelFloorNow() then
            -- Straight to the fuel, for the same reason as the watchdog: deposit-then-dock is two
            -- journeys the drone cannot currently afford, and neither of them puts fuel in it.
            trace(("fuel down to %d -- breaking off to refuel before it runs out"):format(s_Fuel))
            pcall(RefuelAtStorage)
            return false            -- end this job; the next assignment starts fuelled
        end
    end
    -- HEADROOM, NOT "COMPLETELY FULL".
    --
    -- Waiting for one free slot means the drone spends most of its life at fifteen-sixteenths full:
    -- it cannot pick up a vein it just cut, TakeFromChest has nowhere to pull into, and a handover
    -- has nowhere to land. D3 ground on with 266 cobblestone, 96 coal and 41 dirt aboard --
    -- technically not full, practically unable to do anything -- while the fleet waited on the wood
    -- it had no room to carry.
    --
    -- Four slots is enough to work with and still worth the trip.
    if FreeSlots() > 4 then return true end
    return Deposit()
end

-- Dig a box. Serpentine within each layer, then drop a level -- so the drone is always adjacent
-- to the next cell and never has to path back across ground it already cleared.
----------------------------------------------------------------------------------------------
-- Job framework
----------------------------------------------------------------------------------------------
-- Every job verb used to repeat the same twelve lines of lifecycle -- busy check, m_Job,
-- saveResume, status, TaskStart/TaskEnd, deposit, UploadWorld -- and they had already drifted
-- apart: some forgot to clear m_Job, some never saved resume state, and OnDig and OnLumber each
-- had to be patched SEPARATELY to travel to the ordered site. The one that was missed dug up the
-- base for weeks.
--
-- A new job type is now just a body function; the scaffolding cannot be forgotten because it is
-- not written again.
--
--   opts.status   drone status while running          (default "working")
--   opts.travel   move to data.pos first              (default true)
--   opts.settle   descend to the ground first         (default true)
--   opts.deposit  unload at the end if carrying       (default true)
--   opts.upload   push observations at the end        (default true)
-- One line of "what, specifically". Reads whatever the payload happens to carry, because the
-- shapes differ per verb and a switch here would silently omit the next one added.
function DescribeJob(p_Name, d)
    d = d or {}
    local s_Bits = {}
    local function add(v) if v ~= nil and v ~= "" then s_Bits[#s_Bits + 1] = tostring(v) end end

    if d.item then add(d.item:gsub("^minecraft:", "")) end          -- craft
    if d.match then add(tostring(d.match):gsub("^minecraft:", "")) end -- gather
    if d.drone then add("for " .. tostring(d.drone)) end            -- relieve / rescue
    if d.runs and tonumber(d.runs) and tonumber(d.runs) > 1 then add("x" .. d.runs) end
    if d.blueprint then add(d.blueprint) end                        -- build
    if #s_Bits == 0 and d.pos and d.pos.x then
        add(("%s,%s,%s"):format(tostring(d.pos.x), tostring(d.pos.y), tostring(d.pos.z)))
    end
    if #s_Bits == 0 and d.targets then
        local n = 0
        for _ in pairs(d.targets) do n = n + 1 end
        if n > 0 then add(n .. " target(s)") end
    end
    if #s_Bits == 0 then return tostring(p_Name):lower() end
    return tostring(p_Name):lower() .. " " .. table.concat(s_Bits, " ")
end

-- ACCEPT THE JOB HERE, RUN IT SOMEWHERE ELSE.
--
-- Jobs used to execute inside the rednet message handler that received them, which meant a working
-- drone could not hear anything at all -- for the entire duration of the job. Everything downstream
-- of that is broken by it:
--
--   * A drone blocking the storage chest could not receive "please move" BECAUSE it was busy. The
--     yielding protocol could only ever reach drones that were not in the way.
--   * fleet.probe -- the tool for finding out what a drone is actually doing -- only landed on IDLE
--     drones. So the only inspectable state was the one that already means the fleet has stopped
--     working, and every genuinely stuck drone was a black box.
--   * A slow job made the drone look unresponsive to DroneMan, which reads as stranded.
--
-- So the handler now only ACCEPTS: it claims the drone and returns immediately. jobLoop, an ordinary
-- background loop beside the heartbeat and the fuel watchdog, does the work. The drone stays
-- reachable while working, which is the normal state it is supposed to be in.
function RunJob(p_Name, p_Data, p_Opts, p_Body)
    local s_Why = unavailableReason()
    if s_Why then
        trace(("JOB %s REFUSED: %s"):format(p_Name, s_Why))
        -- SAY NO TO THE SCHEDULER, NOT JUST TO THE LOG.
        --
        -- TaskMan dispatches with SendToDrone, which is fire-and-forget, and records the assignment
        -- regardless -- so a refusal was invisible to the only thing that needed to hear it. The
        -- task then belonged to a drone that was never going to run it, and stayed that way: the
        -- stalled-assignment sweep only releases tasks held by drones reporting IDLE, and a drone
        -- that refused because it is busy is, by definition, not idle.
        --
        -- Thirteen tower-floor tasks sat assigned and untouched on that exact hole -- six drones
        -- holding work they had already declined, while the queue looked fully staffed.
        --
        -- Fire-and-forget going back, too: this must never block the message handler. Losing the
        -- refusal costs a timeout-based release later, which is the behaviour we already have.
        if p_Data and p_Data.taskId then
            pcall(function()
                PowNet.SendToServer("TaskMan", PowNet.newMessage(
                    PowNet.MESSAGE_TYPE.CALL, "TaskRefused",
                    {taskId = p_Data.taskId, drone = os.getComputerID(), why = s_Why}))
            end)
        end
        return false, "busy"
    end
    -- Claimed at ACCEPT time, not when the worker gets to it: two dispatches arriving back to back
    -- must not both be accepted just because the first has not started yet.
    executing = true
    m_JobQueue = {name = p_Name, data = p_Data, opts = p_Opts, body = p_Body}
    return true, {accepted = p_Name}
end

-- A JOB PAYLOAD IS NOT A LOG LINE. CAP IT.
--
-- RunJobNow serialised the whole payload, which is fine for a gather and ruinous for a build: one
-- tower task carries 192 blocks and printed 42 KILOBYTES on a single line. drone.log is capped at
-- 96KB and DELETED when it exceeds that, so two of those wiped the file -- and drone.log is the
-- primary debugging surface for this entire system. The one line describing the job destroyed every
-- line that would have explained what happened next.
--
-- Two hundred characters identify a job, which is all that line was ever for.
local function describePayload(p_Data)
    if not textutils.serialiseJSON then return "?" end
    local ok, j = pcall(textutils.serialiseJSON, p_Data)
    if not ok or type(j) ~= "string" then return "?" end
    if #j <= 200 then return j end
    return j:sub(1, 200) .. ("... (%d bytes)"):format(#j)
end

local function RunJobNow(p_Name, p_Data, p_Opts, p_Body)
    local d = p_Data or {}
    local o = p_Opts or {}

    trace(("JOB %s start %s"):format(p_Name, describePayload(d)))
    m_Job = {verb = p_Name, data = d}
    -- Leaving the berth is exactly here: a job has been accepted and the drone is about to move.
    undock()
    saveResume()
    -- SAY WHAT IT IS DOING, NOT JUST THAT IT IS DOING SOMETHING.
    --
    -- "crafting" and "hauling" are verbs without objects: the panel showed a crafter busy for
    -- twenty minutes and could not say on what, so a crafter stuck on an impossible recipe looked
    -- identical to one working normally. The payload has always carried the answer.
    --
    -- Derived HERE rather than in each job, so a new verb describes itself without anyone
    -- remembering to add it -- and so there is one place to fix when it is wrong.
    m_Detail = DescribeJob(p_Name, d)
    m_Status = o.status or "working"
    TaskStart()

    local function finish(p_Ok, p_Res)
        -- The description dies with the job. Left set, the panel shows a drone sitting idle
        -- "crafting chest x16" for ever, which reads as a stuck job rather than a finished one.
        m_Detail = nil
        SetHauling(nil)
        if o.deposit ~= false and FreeSlots() < 16 then Deposit() end

        -- GET OFF THE CHEST. THE ACCESS SQUARE IS SHARED INFRASTRUCTURE.
        --
        -- Every chest has exactly one square a drone can work it from, and a job that touched
        -- storage ends standing on precisely that square. A crafter whose task is being re-dispatched
        -- the instant it fails never accumulates the 45 seconds of idle that would send it to a dock,
        -- so it camps there indefinitely -- and it camped on the ONE chest holding anything, so the
        -- miner carrying the logs it was waiting for could not land, failed its deposit, failed its
        -- gather, and delivered nothing for 42 minutes. Neither drone was faulty. The square was.
        --
        -- One step is enough to clear it, and it is cheap enough to do after every job.
        if ContainerBelow() then
            local moved = false
            for _ = 1, 4 do
                if pgps.forward() then moved = true break end
                pgps.turnRight()
            end
            if moved then trace("stepped off the chest so others can use it") end
        end

        TaskEnd()
        m_Status = "idle"
        m_Job = nil
        saveResume()
        if o.upload ~= false then pcall(UploadWorld) end

        -- Tell TaskMan how it ended. Without this progress stays at 0 for ever, and once stalled
        -- assignments started being reclaimed that turned into a loop: the crafter repeated a
        -- finished chest order every ninety seconds, correctly reporting it was short of the
        -- planks it had already made into chests.
        if d.taskId ~= nil then
            pcall(function()
                PowNet.SendToServer("TaskMan", PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL,
                    "TaskDone", {id = d.taskId, ok = p_Ok and true or false,
                                 reason = (not p_Ok) and tostring(p_Res) or nil,
                                 result = p_Ok and p_Res or nil}))
            end)
        end
        return p_Ok, p_Res
    end

    -- Go to the ordered site, or refuse. Digging "somewhere" is worse than digging nowhere.
    if o.travel ~= false and d.pos and d.pos.x and d.pos.z then
        local s_Ty = tonumber(d.pos.y)
        local s_Arrived = pgps.moveTo(tonumber(d.pos.x), s_Ty and (s_Ty + 1) or nil, tonumber(d.pos.z))
        -- A miner that cannot find a route to its own shaft head should make one, not give up. The
        -- site is a place the fleet chose deliberately; refusing to reach it strands the whole job
        -- over ground that a pickaxe removes in a few seconds.
        if s_Arrived == false and CanDig() then
            trace("site unreachable by path -- digging in")
            s_Arrived = pgps.digTo(tonumber(d.pos.x), s_Ty and (s_Ty + 1) or nil, tonumber(d.pos.z))
        end
        if s_Arrived == false then
            Distress("cannot reach site",
                tostring(d.pos.x) .. "," .. tostring(d.pos.y) .. "," .. tostring(d.pos.z))
            return finish(false, "cannot reach site")
        end
    end

    -- Hover 0: a miner about to sink a shaft has to be standing on the ground it is cutting.
    if o.settle ~= false then settle(tonumber(d.drop) or 24, 0) end

    -- table.pack, NOT `local ok, res = pcall(...)`.
    --
    -- Two locals keep the first return value and throw the rest away, so a body ending in the
    -- ordinary Lua idiom `return nil, "reason"` handed back res=nil and the reason vanished --
    -- and, because pcall itself succeeded, RunJob reported the job DONE. Every "short of planks",
    -- "could not reach the chest" and "no item to craft" was silently converted into success. A
    -- job that fails quietly is worse than one that crashes: the fleet moves on believing the work
    -- happened, and the shortfall surfaces much later as something inexplicable.
    --
    -- So both conventions are honoured: throwing reports, and returning nil/false reports.
    local s_Ret = table.pack(pcall(p_Body, d))
    if not s_Ret[1] then
        -- A job that throws must report, not vanish: the drone is left somewhere unexpected and
        -- somebody has to know why.
        trace(("JOB %s THREW %s"):format(p_Name, tostring(s_Ret[2])))
        -- The TASK failed. The drone is fine and is about to ask for more work.
        Distress(p_Name .. " failed", tostring(s_Ret[2]), false)
        return finish(false, tostring(s_Ret[2]))
    end

    local s_Res, s_Why = s_Ret[2], s_Ret[3]
    if s_Res == nil or s_Res == false then
        local s_Reason = tostring(s_Why or "job returned no result and gave no reason")
        trace(("JOB %s FAILED %s"):format(p_Name, s_Reason))
        Distress(p_Name .. " failed", s_Reason, false)
        return finish(false, s_Reason)
    end
    trace(("JOB %s done"):format(p_Name))
    return finish(true, s_Res)
end

-- The w x l boustrophedon walk, previously written out four times with the same turn parity and
-- the same off-by-one. p_OnCell returns false to abandon the current row; p_Advance moves to the
-- next row and returns false to abandon the job.
function Serpentine(p_W, p_L, p_OnCell, p_Advance)
    p_Advance = p_Advance or function() return pgps.forward() end
    for row = 1, p_L do
        if not executing then return row - 1 end
        for col = 1, p_W - 1 do
            if not executing then return row - 1 end
            if p_OnCell(row, col) == false then break end
        end
        if row < p_L then
            local s_Turn = (row % 2 == 1) and pgps.turnRight or pgps.turnLeft
            s_Turn()
            if p_Advance() == false then return row end
            s_Turn()
        end
    end
    return p_L
end

function OnDig(p_ID, p_Message)
    return RunJob("Dig", p_Message.data, {status = "mining"}, function(d)
        local s_W     = tonumber(d.w)     or 8
        local s_L     = tonumber(d.l)     or 8
        local s_Depth = tonumber(d.depth) or 4

        -- Refuse to quarry air. A drone that has just flown somewhere is airborne, and the first
        -- real run dug a clean 3x3x2 of nothing at y=84: seventeen fuel spent, every dig hitting
        -- nothing, empty inventory, and a job that reported success.
        if not turtle.detectDown() then
            Distress("nothing to dig", "no ground within " .. (tonumber(d.drop) or 24) .. " blocks")
            error("no ground beneath")
        end

        local s_Dug, s_Layers = 0, 0
        for layer = 1, s_Depth do
            if not executing then break end
            Serpentine(s_W, s_L, function()
                if not depositIfFull() then return false end
                DigForward()
                -- Something unbreakable (bedrock, a claim, a machine). Abandon the row, not the
                -- job: the rest of the box is still worth having.
                if not pgps.forward() then return false end
                s_Dug = s_Dug + 1
            end, function()
                DigForward()
                return pgps.forward()
            end)
            s_Layers = s_Layers + 1
            if layer < s_Depth then
                if not DigDown() then break end
                if not pgps.down() then break end
            end
        end

        return {message = "dug " .. s_Dug .. " blocks over " .. s_Layers .. " layers",
                dug = s_Dug, layers = s_Layers}
    end)
end

-- Fetch from a point and take it to storage. The hauler half of the loop: miners stay at the
-- face, haulers commute. Later this is what item conduits replace on fixed routes.
----------------------------------------------------------------------------------------------
-- Lumber
----------------------------------------------------------------------------------------------
-- Wood is the gate in front of everything else the fleet wants to build: chests for field caches,
-- planks and sticks for crafting, and therefore any factory at all. Nothing else in the fleet
-- produces it, so until this exists the swarm cannot build its own infrastructure.
--
-- Leaves are cleared as the trunk is climbed, on purpose. Felling only the trunk leaves the canopy
-- to decay on Minecraft's own schedule, which may be minutes -- and saplings come from leaf decay,
-- so a drone that only takes logs walks away with no way to replant and the forest shrinks every
-- pass. Breaking leaves makes the sapling drop now, while we are standing there to pick it up.
-- ASK WoodFamily. It is the one place that knows what wood is.
--
-- This used to test "_log"/"_stem" itself while WoodFamily tested "_log"/"_wood" and isFuelSelected
-- tested "_log"/"_planks"/"_wood" -- three functions, one question, three different answers, none
-- of which covered the same set.
local function isLog(p_Name)
    return WoodFamily(p_Name) == "log"
end
local function isLeaf(p_Name)     return p_Name ~= nil and string.find(p_Name, "_leaves", 1, true) end
local function isSapling(p_Name)  return p_Name ~= nil and string.find(p_Name, "_sapling", 1, true) end

local function selectMatching(p_Pred)
    for i = 1, 16 do
        local it = turtle.getItemDetail(i)
        if it and p_Pred(it.name) then turtle.select(i) return true end
    end
    return false
end

-- Drops land on the ground and in the air around a felled trunk; sweep all three planes.
local function suckAround()
    pcall(turtle.suck)
    pcall(turtle.suckUp)
    pcall(turtle.suckDown)   -- lua-hygiene: allow (a dropped ITEM, not a chest)
end

-- Fell the tree whose trunk is directly in FRONT. Returns how many log blocks were taken.
local function fellTree()
    if not DigForward() then return 0 end
    if not pgps.forward() then return 0 end

    local s_Logs, s_Climbed = 1, 0
    while true do
        local ok, blk = turtle.inspectUp()
        if not (ok and isLog(blk.name)) then break end
        if not DigUp() then break end
        if not pgps.up() then break end
        s_Climbed = s_Climbed + 1
        s_Logs = s_Logs + 1

        -- Clear the canopy at this level so saplings drop while we are here to collect them.
        for _ = 1, 4 do
            local okf, b = turtle.inspect()
            if okf and isLeaf(b.name) then DigForward() end
            pgps.turnRight()
        end
        suckAround()
    end

    for _ = 1, s_Climbed do pgps.down() end
    suckAround()

    -- Replant. The turtle is standing IN the old trunk base, so it has to step back before the
    -- sapling has somewhere to go: placeDown would target the dirt block it is standing on.
    if pgps.back() then
        if selectMatching(isSapling) then
            pcall(turtle.place)
        end
    end
    turtle.select(1)
    return s_Logs
end

-- Go and get SPECIFIC blocks, and take the WHOLE cluster.
--
-- Dig sweeps a volume, which is right for bulk stone and wrong for everything the survey already
-- located: 6 coal ore at known coordinates do not need an 8x8x4 hole. The seeds come from
-- MapServer's block index, so this is the consuming half of surveying -- without it the index is
-- a report nobody acts on.
--
-- Seeds are only a starting point. Ore generates in VEINS, and the index holds at most a dozen
-- sample positions per block type, so mining just the samples would leave most of the vein in the
-- ground and require re-surveying to find what was always there. Each seed is therefore flood
-- filled: mine it, then consider its neighbours, and keep going while they match. `limit` bounds
-- the whole job so one enormous vein cannot consume a drone indefinitely.
--
-- Blocks are approached from ABOVE and dug downward: a turtle cannot occupy the target, and the
-- space above it is the one position reachable for anything with air over it.
function OnGather(p_ID, p_Message)
    return RunJob("Gather", p_Message.data,
        {status = "mining", travel = false, settle = false}, function(d)
        local s_Match  = d.match
        local s_Limit  = tonumber(d.limit) or 64
        local s_Queue  = {}
        local s_Seen   = {}
        local s_Got, s_Missed = 0, 0
        -- Fuel burned on candidates that returned nothing. See GATHER_MISS_FUEL_BUDGET: this
        -- replaced a consecutive-miss counter, which assumed reachability falls off with distance
        -- and so aborted surface gathers -- wood above all -- after two awkward targets.
        local s_MissFuel = 0
        local s_FuelBeforeCandidate = turtle.getFuelLevel()

        local function key(x, y, z) return x .. ":" .. y .. ":" .. z end
        local function push(x, y, z)
            if x and y and z and not s_Seen[key(x, y, z)] then
                -- THE VEIN DOES NOT RESPECT THE REGION. THIS HAS TO.
                --
                -- order.gather reach-filters the SEED targets, and then this pushed the six
                -- neighbours of every block it cut without checking anything -- so following a seam
                -- outward walks the drone straight past the boundary, one block at a time, with no
                -- single step ever looking wrong. D6 followed gravel to -412 and ended up parked at
                -- -402: 78 blocks out, beyond the 64-block modem range, unable to hear an order
                -- again. D1 and D2 were lost the same way and never came back.
                if not pgps.isWithinReach(x, z) then return end
                s_Queue[#s_Queue + 1] = {x = x, y = y, z = z}
            end
        end
        local function wanted(p_Name)
            if p_Name == nil then return false end
            if IsProtected(p_Name) then return false end
            if s_Match == nil then return true end
            return string.find(p_Name, s_Match, 1, true) ~= nil
        end

        for _, t in ipairs(d.targets or {}) do
            push(tonumber(t.x), tonumber(t.y), tonumber(t.z))
        end

        -- Two lines, and this job survives a reboot. See Resumable.
        local s_Done = Resumable(d)
        s_Done.announce("gather")
        local s_Carry = s_Done.extra()
        if type(s_Carry) == "table" then
            s_Got    = tonumber(s_Carry.got) or 0
            s_Missed = tonumber(s_Carry.missed) or 0
        end

        -- Cap CANDIDATES as well as blocks taken. The limit above bounds what we mine, but a
        -- vein sitting in solid rock has a boundary of non-matching neighbours, each costing a
        -- flight to inspect -- so an exhausted vein could cost dozens of trips for nothing.
        local s_Checked, s_MaxChecks = 0, math.max(24, s_Limit * 3)
        -- TRACE IT. This job ran for twenty-five minutes writing not one line, which made a drone
        -- blocked on GPS timeouts indistinguishable from one mining happily. Throttled, because one
        -- line per candidate would be hundreds.
        local s_LastTrace = 0
        while #s_Queue > 0 and s_Got < s_Limit and s_Checked < s_MaxChecks and executing do
            s_Checked = s_Checked + 1

            -- NEAREST FIRST, not last-pushed.
            -- table.remove takes the END of the queue, which is whatever was appended most
            -- recently -- fine while following a vein, arbitrary at the start. Combined with
            -- digging to reach targets, an arbitrary order means tunnelling right across the site
            -- and back. Nearest-first cuts in once and then works outward through the seam, which
            -- is what the neighbour pushes below are for.
            local s_Cx, s_Cy, s_Cz = pgps.getCachedPosition()
            local s_Idx = #s_Queue
            if s_Cx then
                local s_BestD
                for i = 1, #s_Queue do
                    local q = s_Queue[i]
                    local dd = math.abs(q.x - s_Cx) + math.abs(q.y - s_Cy) + math.abs(q.z - s_Cz)
                    if s_BestD == nil or dd < s_BestD then s_BestD, s_Idx = dd, i end
                end
            end
            local t = table.remove(s_Queue, s_Idx)
            -- Re-read per candidate: the miss budget charges what THIS attempt cost, so the mark
            -- has to move with the loop. Read once at job start it would charge every miss with all
            -- the fuel spent successfully mining beforehand, and the first miss would end the job.
            s_FuelBeforeCandidate = turtle.getFuelLevel()

            -- WORK A VEIN, DO NOT TOUR THE SITE.
            --
            -- The target list is every known deposit in the whole operating region -- 40 of them,
            -- spread over 100 blocks in every direction. Taken in order, the drone digs its way
            -- across the entire settlement one block of ore at a time: D3 spent four minutes per
            -- candidate and travelled 60 blocks to reach its fifth, with two drones sitting at zero
            -- fuel waiting for the coal it was supposed to be bringing back.
            --
            -- Once something has been taken, a far-away candidate is not worth the trip: the
            -- neighbour pushes will have queued the rest of THIS vein, and whatever is left over
            -- stays in the index for the next task, dispatched from wherever that drone happens to
            -- be. Coming back with a load beats theoretically-complete coverage that never returns.
            -- A BUDGET FOR FINDING THE FIRST ONE -- BUT PRUNING IS NOT FAILING.
            --
            -- The budget exists so a drone does not spend 192 cross-site journeys finding nothing.
            -- But it counted a STALE INDEX ENTRY as a failure, and stale entries are exactly what
            -- sits nearest the base: the fleet works outward, so the closest known logs are the
            -- ones it already cut. Nearest-first then spent the whole budget rediscovering its own
            -- clearings, gave up, and the next attempt did it again -- while 653 real oaks sat
            -- further out, untouched, for hours.
            --
            -- Arriving to find air is useful work: the observation is written back and that entry
            -- is gone for good (the index has already dropped from 936 to 844 this way). So a
            -- vanished block gets a much larger allowance than a genuinely unreachable one, which
            -- teaches nothing and is the case the tight budget was really for.
            if s_Got == 0 and s_Missed > 8 then
                trace("gather: too many unreachable candidates -- giving up on this list")
                break
            end
            if s_Got == 0 and s_Checked > 60 then
                trace(("gather: %d candidates checked, nothing taken -- giving up on this list")
                    :format(s_Checked))
                break
            end

            if s_Got > 0 and s_Cx then
                local s_Far = math.abs(t.x - s_Cx) + math.abs(t.y - s_Cy) + math.abs(t.z - s_Cz)
                if s_Far > 48 then
                    trace(("gather: nearest remaining target is %d blocks away -- taking the %d "
                        .. "already cut home instead"):format(s_Far, s_Got))
                    break
                end
            end


            if (os.clock() - s_LastTrace) > 15 then
                s_LastTrace = os.clock()
                trace(("gather: %d/%d checked, %d taken, %d unreachable, %d queued")
                    :format(s_Checked, s_MaxChecks, s_Got, s_Missed, #s_Queue))
            end
            local k = key(t.x, t.y, t.z)
            if not (s_Seen[k] or s_Done.done(k)) then
                s_Seen[k] = true
                s_Done.mark(k, {got = s_Got, missed = s_Missed})
                if not depositIfFull() then break end
                -- Re-fix before each dig. Cheap (no movement) and this is the job that edits the
                -- map destructively, so it is the one that must know where it is.
                pgps.verifyPosition()

                -- A MINER THAT CANNOT WALK TO THE ORE SHOULD DIG TO IT.
                --
                -- This called moveTo and nothing else. moveTo only routes through cells someone has
                -- already surveyed as passable -- and ore, by definition, is BURIED. There is never
                -- a mapped route to the inside of a seam, so every target failed, s_Missed counted
                -- it, and the loop moved on. Every gather task in the fleet's history returned
                -- "gathered 0 (N unreachable)" for exactly this reason.
                --
                -- Worse, it returned that as a RESULT TABLE, which RunJob reads as success. So the
                -- task completed, the supply loop saw the ore still missing and queued another one,
                -- and the fleet mined no ore at all while looking fully occupied. With 509 coal
                -- positions known and two drones sitting at zero fuel, this is what kept them there.
                --
                -- Mine, Survey and GoTo all learned the moveTo -> digTo -> flyTo chain. Gather --
                -- the one job whose whole purpose is to reach buried blocks -- never did.
                -- DO NOT ASK THE PATHFINDER ABOUT THE NEXT BLOCK ALONG.
                --
                -- This called moveTo -- a full A* request to MapServer -- for EVERY candidate, and
                -- a gather carries up to 192 of them. Multiply by eighteen drones and MapServer
                -- stops answering entirely, which is exactly what happened: TaskMan and MapServer
                -- both went unreachable, every moveTo then failed instantly, and the drones fell
                -- through to digTo and flyTo, climbing and descending on the spot. The "stuck moving
                -- up and down" was a saturated pathfinder, not a broken drone.
                --
                -- Vein candidates are metres apart. Digging straight there needs nobody's help and
                -- cannot be starved by another drone's search; A* is only worth its cost when there
                -- is something substantial to route around.
                local s_Near = 0
                if s_Cx then
                    s_Near = math.abs(t.x - s_Cx) + math.abs(t.y - s_Cy) + math.abs(t.z - s_Cz)
                end
                local s_At = false
                -- Which face we ended up on, so the inspect and the dig agree with the approach.
                local s_FromBelow = false
                local s_FromSide  = false
                if s_Cx == nil or s_Near > SHORT_HOP then
                    s_At = pgps.moveTo(t.x, t.y + 1, t.z)
                end
                if s_At == false and CanDig() then
                    -- BUDGET THE DIG BY DISTANCE.
                    --
                    -- digTo's default is 256 steps, and every step is a block broken and a move
                    -- paid for. Spent per target across a scattered list, that is a drone boring
                    -- across the whole site and back for one piece of ore -- D3 burned 2,600 fuel
                    -- in twenty minutes and delivered nothing. A budget of twice the straight-line
                    -- distance plus slack is enough to cut in through rock and no more; a target
                    -- that needs more than that is not worth reaching by pickaxe, and skipping it
                    -- costs one candidate out of hundreds.
                    local s_D = 64
                    if s_Cx then
                        s_D = math.abs(t.x - s_Cx) + math.abs(t.y - s_Cy) + math.abs(t.z - s_Cz)
                    end
                    s_At = pgps.digTo(t.x, t.y + 1, t.z, math.min(96, s_D * 2 + 16))
                end
                if s_At == false then
                    -- BUDGET THE FLIGHT TOO. A CANDIDATE IS OPTIONAL; 400 SECONDS IS NOT.
                    --
                    -- digTo is budgeted by distance and moveTo now gives up quickly on a starved
                    -- pathfinder, but flyTo was unbounded -- so one awkward target could absorb the
                    -- whole job. Measured: a single "could not reach" cost 396 seconds, and with 192
                    -- candidates a drone never reaches the ore it CAN get to. D5 and D8 spent nine
                    -- minutes each that way while their gathers showed "0 taken".
                    --
                    -- There are hundreds of candidates and they are sorted nearest-first, so giving
                    -- up on a hard one is nearly free and trying forever is what costs the fleet.
                    local s_FlyBudget = 64
                    if s_Cx then
                        s_FlyBudget = math.min(128, (math.abs(t.x - s_Cx) + math.abs(t.y - s_Cy)
                                                   + math.abs(t.z - s_Cz)) * 3 + 16)
                    end
                    s_At = pgps.flyTo(t.x, t.y + 1, t.z, s_FlyBudget)
                end

                -- IF ABOVE IS SOLID, COME AT IT FROM UNDERNEATH.
                --
                -- Every approach above aims at t.y + 1 and then digs DOWN. That is right for ore:
                -- a vein sits in rock with a shaft over it. It is wrong for a tree, and trees are
                -- the settlement's only renewable fuel. A canopy log has LEAVES above it, so the
                -- stand-above cell is solid and all three approaches fail -- which is why coal ore
                -- at y=40 is reachable and oak_log at y=75 has never once been reached.
                --
                -- Measured on a real target, -484,75,58: oak_leaves on all four sides AND above,
                -- and -484,74,58 directly beneath it is AIR, with a clear air column all the way
                -- down to y=64. The tree was never unreachable; it was only unreachable from above.
                --
                -- hive.plan stated the consequence plainly: gather:oak_log "took nothing from 3
                -- candidates (3 unreachable)", with craft-oak_planks blocked behind it and, behind
                -- that, every chest, crafting table and building the settlement will ever make.
                if s_At == false then
                    s_FromBelow = true
                    s_At = pgps.moveTo(t.x, t.y - 1, t.z)
                    if s_At == false then
                        s_At = pgps.flyTo(t.x, t.y - 1, t.z, s_FlyBudget or 64)
                    end
                    if s_At == false then s_FromBelow = false end
                end

                -- AND FROM THE SIDE, WHICH IS THE ONLY WAY TO REACH A TRUNK.
                --
                -- Above and below together still cannot touch a mid-trunk log: the block over it is
                -- more trunk and the block under it is trunk or the dirt the tree stands in. Only
                -- the four horizontal neighbours are air. That is not an edge case -- of the wood
                -- this settlement has indexed, 52% sits at y=62-70, which is trunk at ground level,
                -- against 45% canopy. Approaching only vertically wrote off half the forest.
                --
                -- Stand beside it and face back at it. The heading is the opposite of the offset:
                -- standing one block EAST means looking WEST to see the target.
                if s_At == false then
                    s_At = ApproachFromSide(t, s_FlyBudget)
                    s_FromSide = (s_At ~= false)
                end

                if s_At ~= false then
                    local s_Look, s_Cut = FaceTools(s_FromBelow, s_FromSide)
                    local s_Ok, s_Blk = s_Look()
                    -- One line per candidate. There are only ever a few dozen, and without this the
                    -- counters say "checked 4, took 0, missed 0" without ever saying what was found
                    -- instead -- which is the only fact that distinguishes a stale index from a
                    -- drone standing in the wrong place.
                    local ax, ay, az = pgps.getCachedPosition()
                    trace(("gather: at %s,%s,%s for %d,%d,%d -> %s"):format(
                        tostring(ax), tostring(ay), tostring(az), t.x, t.y, t.z,
                        s_Ok and tostring(s_Blk and s_Blk.name) or "air"))

                    -- TELL THE MAP WHAT IS ACTUALLY THERE.
                    --
                    -- Arriving to find something other than the ore the index promised is the only
                    -- direct evidence anyone ever gets that an index entry is wrong -- and it was
                    -- thrown away. The entry stayed, the supply loop kept building gather tasks
                    -- from it, and drones kept tunnelling across the site to re-discover the same
                    -- absence. Writing the observation back is what makes the index self-correcting
                    -- instead of accumulating ghosts for ever.
                    if not (s_Ok and s_Blk and wanted(s_Blk.name)) then
                        local s_Idx = t.x .. ":" .. t.y .. ":" .. t.z
                        -- EARN THE FIX FIRST, OR THE CORRECTION IS THROWN AWAY.
                        --
                        -- noteObservation refuses anything recorded on an unverified position --
                        -- correctly, that gate is what stopped drift from polluting the map. But a
                        -- drone that has just dug or flown to a remote candidate is exactly the
                        -- drone WITHOUT a fresh fix, so every ghost report was silently suppressed
                        -- at the one moment it could be made.
                        --
                        -- The index therefore never self-corrected. Seen live:
                        --   gather: at -489,71,56 for -489,70,56 -> air
                        -- ore that had already been mined, still in the index, still generating
                        -- gather tasks, still costing a full approach to re-discover the same
                        -- absence. Coal stayed flat at 583 for nine minutes while drones spent
                        -- their fuel visiting deposits that were not there.
                        --
                        -- One cheap attempt to re-verify before reporting. Underground it will
                        -- often fail and we skip, which is the old behaviour and no worse; above
                        -- ground it succeeds and the ghost is pruned for the whole fleet.
                        pcall(pgps.verifyPosition)
                        if s_Ok and s_Blk then
                            pcall(pgps.noteObservation, s_Idx, 1, {true, {name = s_Blk.name}})
                        else
                            pcall(pgps.noteObservation, s_Idx, 0)   -- air: it is simply gone
                        end
                        -- PRUNE THE WHOLE COLUMN WE CAN SEE, NOT ONE CELL.
                        --
                        -- A felled tree leaves a COLUMN of ghosts -- four to six log cells stacked
                        -- at one x,z -- and this pruned exactly one of them per visit. Each of the
                        -- others then costs its own approach to re-discover the same absence, and
                        -- candidates are sorted nearest-first, so the drone works through its own
                        -- old clearings before ever reaching a standing tree.
                        --
                        -- Measured: 1,071 oak_log entries indexed, oak_log stuck at 2 in storage
                        -- for a whole session, and a single gather that ran 657 SECONDS to check
                        -- three candidates and returned "took nothing (1 unreachable)" -- meaning
                        -- two were reached and simply were not there.
                        --
                        -- The drone is hovering at t.y+1 looking down, so three cells are directly
                        -- observable right now: the target below it, its own cell (occupied by the
                        -- drone, therefore air), and whatever is above. All three are real readings,
                        -- not inferences -- nothing is fabricated for cells it cannot see.
                        -- Only from a vertical approach. Standing beside the target, the
                        -- cells above and below it are ones this drone never looked at,
                        -- and inventing them is how the map got its ghosts.
                        if not s_FromSide then
                            pcall(NoteSeenColumn, t.x, t.y, t.z, s_FromBelow)
                        end
                    end

                    if s_Ok and s_Blk and wanted(s_Blk.name) then
                        if s_Cut() then
                            s_Got = s_Got + 1
                            -- The vein continues through the faces of what we just took.
                            push(t.x + 1, t.y, t.z)
                            push(t.x - 1, t.y, t.z)
                            push(t.x, t.y, t.z + 1)
                            push(t.x, t.y, t.z - 1)
                            push(t.x, t.y - 1, t.z)
                            push(t.x, t.y + 1, t.z)
                        end
                    end
                else
                    trace(("gather: could not reach %d,%d,%d"):format(t.x, t.y, t.z))
                    s_Missed = s_Missed + 1
                    -- STOP PAYING FOR CANDIDATES WE CANNOT REACH.
                    --
                    -- Each miss is not free. A failed candidate costs a digTo budget (up to 96
                    -- steps, every one a block broken AND a move) plus a flyTo budget (up to 128),
                    -- and returns nothing. Measured live, repeatedly:
                    --
                    --   JOB Gather FAILED took nothing from 7 candidates (6 unreachable)
                    --
                    -- Six misses is on the order of several hundred fuel spent to gather zero ore,
                    -- and the drone then goes dry -- which shortens its reach, which makes the next
                    -- run miss more. That is the fuel spiral, and it is self-reinforcing.
                    --
                    -- Candidates are sorted NEAREST-FIRST, so consecutive misses are strong
                    -- evidence that the rest are worse, not better: if the closest few are out of
                    -- reach the far ones certainly are. Give up and let the drone keep the fuel to
                    -- reach a chest, rather than spending it proving the same point five more times.
                    --
                    -- Consecutive, not total: a run that is succeeding and hits one awkward target
                    -- should carry on, which is why this resets on every success below.
                    -- CHARGE THE MISS TO A FUEL BUDGET, NOT TO A COUNTER.
                    --
                    -- See GATHER_MISS_FUEL_BUDGET. A miss that cost nothing does not move us any
                    -- closer to giving up; one that burned through rock does. The helper returns
                    -- s_Checked as the new cap when the budget is gone, which trips the loop's
                    -- existing guard.
                    s_MissFuel, s_MaxChecks =
                        GatherMissBudget(s_FuelBeforeCandidate, s_MissFuel, s_Checked, s_MaxChecks)
                end
            end
        end

        -- REACHING NOTHING IS A FAILURE, NOT A QUIET SUCCESS.
        --
        -- Nothing gathered and nothing even reached means the drone never got to a single target.
        -- Reported as success that becomes a task marked done, an ore count that never moves, and a
        -- supply loop queueing the identical task for ever. Say so, so the attempt is counted and
        -- the task is eventually given up on with a reason attached.
        --
        -- Nothing gathered but everything REACHED is different and genuinely fine: the seam was
        -- already mined out and the index was stale. That is a real, complete answer.
        -- ...AND THE CODE HAS TO AGREE WITH THAT. It failed the case the comment above calls fine.
        --
        -- s_Missed == 0 means every candidate was REACHED and inspected. Taking nothing from them is
        -- then a complete and correct answer: the ore was already gone, and the drone has just
        -- written that back, so the index is now right where it was wrong. Reporting failure made
        -- the task retry a phantom for ever -- gather:iron_ore sat "failing -- took nothing from 1
        -- candidates (0 unreachable)" across attempt after attempt, having done exactly the right
        -- thing every time. Nothing it could do differently would have changed the outcome, which is
        -- the definition of a task that should not be retried.
        --
        -- Nothing reached is still a failure: that drone never got anywhere and the attempt means
        -- nothing.
        if s_Got == 0 and s_Checked > 0 and s_Missed > 0 then
            return nil, ("took nothing from %d candidates (%d unreachable) matching %s")
                :format(s_Checked, s_Missed, tostring(s_Match))
        end
        if s_Got == 0 and s_Checked > 0 then
            trace(("gather: all %d candidate(s) inspected, the %s was already gone -- map corrected")
                :format(s_Checked, tostring(s_Match)))
            return {message = ("no %s left at any of the %d known site(s); map corrected")
                :format(tostring(s_Match), s_Checked), got = 0, checked = s_Checked, exhausted = true}
        end

        return {message = ("gathered %d (limit %d, %d unreachable)")
                    :format(s_Got, s_Limit, s_Missed),
                got = s_Got, missed = s_Missed}
    end)
end

-- CRAFTING
--
-- The gate everything else was behind. The fleet could dig, carry and smelt, so it could obtain
-- raw material and it could not turn any of it into a single useful object -- no planks, so no
-- chests, so no field caches; no crafting table, so no second crafty turtle; no sticks, so no
-- tools. A settlement that cannot make anything is a quarry with extra steps.
--
-- Needs a turtle with a crafting-table upgrade. turtle.craft simply does not exist otherwise, so
-- this refuses loudly on the wrong drone rather than failing in some subtler way further in.

-- The 3x3 grid maps onto a 4x4 inventory, so it is NOT slots 1-9: the fourth column is outside the
-- grid and anything left there makes the craft fail with no explanation.
local CRAFT_SLOTS = {1, 2, 3, 5, 6, 7, 9, 10, 11}

function IsCrafter()
    return type(turtle.craft) == "function"
end

-- Staging slots, outside the crafting grid.
--
-- turtle.suck takes whatever the chest offers next -- there is no "suck the planks". So items are
-- pulled in bulk, consolidated by kind into these slots, and only then dealt into the grid. Four
-- is enough for every recipe in the graph (none has more than two distinct inputs) and the code
-- says so rather than silently mis-crafting if that ever stops being true.
local STAGE_SLOTS = {13, 14, 15, 16}

local function emptyInventory()
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            PutDown()
        end
    end
    -- A WRITE THAT IS NOT REPORTED IS DRIFT. Every path that puts items into a chest has to say so,
    -- or the index goes stale in exactly the way the observed-contents scheme exists to prevent --
    -- and stale here is worse than absent, because a chest recorded as empty gets SKIPPED by the
    -- fetch sweep. Six oak logs were put back by the grid clean-up, not reported, and the crafter
    -- then refused to look in the chest it had just put them in.
    ReportChest()
end

--- Pull from the chest below, keep only the wanted kinds, and put everything else straight back.
--- Returns name -> staging slot.
---
--- The "put everything else back" half is not tidiness. turtle.suck cannot ask for a named item,
--- so a drone drawing from the fleet's MAIN store hoovers up sandstone, glass and everything else
--- along with the logs. Two things go wrong if that is left alone: the base is quietly emptied into
--- a turtle, and -- worse -- the junk sits in slots 1-11, which ARE the crafting grid, so the craft
--- either produces the wrong item or silently nothing.
local function stageFromChest(p_Wanted)
    local s_Where = {}

    -- PULL IN BULK FIRST, sort afterwards.
    --
    -- turtle.suckDown always takes the chest's FIRST occupied slot. Sucking one stack, deciding it
    -- is not wanted and dropping it straight back puts it right back in that first slot -- so the
    -- drone cycles the same stack of glass for ever and never reaches the logs four slots further
    -- in. Staging came back empty every time while the chest plainly held 64 logs.
    --
    -- Filling all twelve non-staging slots before returning anything means the leading stacks stay
    -- OUT of the chest while we look past them, which is the only way to see what is behind them.
    local s_Pulled = 0
    for i = 1, 12 do
        turtle.select(i)
        if turtle.getItemCount(i) == 0 then
            if not turtle.suckDown() then break end
            s_Pulled = s_Pulled + 1
        end
    end
    if s_Pulled == 0 then return nil, "the pickup chest gave up nothing" end

    -- Keep what the recipe asked for...
    for i = 1, 12 do
        local d = turtle.getItemDetail(i)
        -- Family match, not name match: the recipe table says oak because something had to be
        -- written down, but a spruce log makes spruce planks and a spruce plank makes the same
        -- chest. Discarding them here is how a fleet surrounded by trees reports no wood.
        local s_Key = nil
        if d and d.name then
            if p_Wanted[d.name] then s_Key = d.name
            else
                for w in pairs(p_Wanted) do
                    if SameItem(w, d.name) then s_Key = w break end
                end
            end
        end
        if s_Key then
            d = {name = s_Key, actual = d.name}
            local s_Slot = s_Where[d.name]
            if s_Slot == nil then
                for _, cand in ipairs(STAGE_SLOTS) do
                    local cd = turtle.getItemDetail(cand)
                    if cd == nil or cd.name == d.name then s_Slot = cand break end
                end
                if s_Slot == nil then
                    for j = 1, 12 do
                        if turtle.getItemCount(j) > 0 then turtle.select(j) PutDown() end
                    end
                    return nil, "more ingredient kinds than staging slots"
                end
                s_Where[d.name] = s_Slot
            end
            turtle.select(i)
            turtle.transferTo(s_Slot)
        end
    end

    -- ...and hand everything else straight back. The fleet's whole store passes through this
    -- turtle; none of it may stay there, and anything left in slots 1-11 is IN the crafting grid
    -- and would change what turtle.craft believes it is making.
    for i = 1, 12 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            PutDown()
        end
    end
    ReportChest()          -- everything just handed back changed this chest (see emptyInventory)

    return s_Where
end

--- Deal p_Count of the item staged at p_From into grid slot p_To.
local function dealInto(p_From, p_To, p_Count)
    if p_From == nil then return 0 end
    -- ALREADY THERE IS NOT A FAILURE.
    --
    -- transferTo(n) from slot n moves nothing and returns nothing, so this reported 0 of 8 dealt and
    -- raised "short of minecraft:oak_log" while the eight logs sat in the destination slot the whole
    -- time. It only shows up once staging starts finding items already in the grid -- which is
    -- exactly what happens when the drone fetched them itself.
    if p_From == p_To then return math.min(turtle.getItemCount(p_To), p_Count) end
    local s_Before = turtle.getItemCount(p_To)
    turtle.select(p_From)
    turtle.transferTo(p_To, p_Count)
    return turtle.getItemCount(p_To) - s_Before
end

-- lua-hygiene: allow (a craft is transactional -- it either produced the item or it did not, and
-- ingredients are re-collected from the chest on the way in. Resuming half a craft would mean
-- reasoning about a grid the drone can no longer see, so starting over is the correct behaviour
-- rather than an oversight.)
function OnCraft(p_ID, p_Message)
    return RunJob("Craft", p_Message.data, {status = "crafting", travel = false}, function(d)
        if not IsCrafter() then
            -- Named, not generic: "cannot craft" sends someone looking for a software bug, when
            -- the actual fix is to put a crafting table on a turtle.
            error("this drone has no crafting table upgrade -- it physically cannot craft", 0)
        end

        local s_Item  = d.item
        local s_Runs  = math.max(1, tonumber(d.runs) or 1)
        local s_Grid  = d.grid                       -- may be nil for shapeless recipes
        local s_Inputs= d.inputs or {}
        if s_Item == nil then error("no item to craft", 0) end

        -- 1. Ask storage to put the ingredients somewhere we can reach.
        local s_Req = {}
        for name, per in pairs(s_Inputs) do
            s_Req[#s_Req + 1] = {name = name, count = per * s_Runs}
        end
        if #s_Req == 0 then error("recipe has no inputs", 0) end

        -- FETCH THEM YOURSELF IF STORAGE CANNOT PUSH THEM.
        --
        -- Provide moves items between inventories through peripherals, and this settlement has
        -- none: the wired modems were placed by setblock, which cannot attach them, so StorageMan
        -- can neither see nor touch the chests. Every craft therefore died on "storage would not
        -- hand over ingredients" -- which is what stopped the very first build, four oak planks,
        -- and with it every factory behind it.
        --
        -- A turtle does not need any of that. It can fly to the chest and suckDown, exactly as
        -- CollectFuel does for coal. Asking politely first keeps the fast path when a real storage
        -- network exists; helping itself is what makes the fleet work today.
        -- SAY WHICH STEP. A craft is four distinct phases -- ask storage, fetch, stage, assemble --
        -- and every one of them can be where it is stuck. Reporting only "crafting oak_planks" for
        -- the whole job means the only way to tell "waiting on storage" from "cannot reach the
        -- chest" from "the recipe is wrong" is to read the drone's log by hand, which is what
        -- watching this fleet has mostly consisted of.
        Doing(("craft %s: asking storage for ingredients"):format(tostring(s_Item):gsub("^minecraft:", "")))
        local s_Hand = PowNet.sendAndWaitForResponse("StorageMan",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Provide", {items = s_Req}),
            PowNet.SERVER_PROTOCOL)

        if type(s_Hand) ~= "table" or s_Hand.pos == nil then
            -- ONE PRIMITIVE, AND A WRONG ANSWER IS NO LONGER FATAL. FetchItems asks StorageMan
            -- where the ingredients are, flies there, and -- if they are not actually there --
            -- sweeps the bay, recording what each chest really holds as it goes. That sweep is
            -- what was missing: the index said -474, the logs were at -476, and every craft
            -- failed at the empty chest without ever looking in the next one along.
            local s_Want = {}
            for _, r in ipairs(s_Req) do s_Want[r.name] = r.count end
            -- One run's worth is the least that is still worth fetching: below that there is nothing
            -- to make, at or above it the run count scales down and the drone gets on with it.
            local s_MinWant = {}
            for name, per in pairs(s_Inputs) do s_MinWant[name] = math.max(1, tonumber(per) or 1) end
            m_Status = "hauling"
            SetHauling(s_Want)
            local s_Got, s_Short = FetchItems(s_Want, s_MinWant)

            -- Somebody may have flown it to us rather than to a chest. Cheap to check, and it is
            -- the difference between "blocked for ever" and "took the delivery and carried on".
            if s_Short and CollectNearby() > 0 then
                trace("craft: picked up a delivery -- checking it covers the recipe")
                s_Got, s_Short = {}, nil
                for i = 1, 16 do
                    local det = turtle.getItemDetail(i)
                    if det and det.name then
                        for w in pairs(s_Want) do
                            if SameItem(w, det.name) then
                                s_Got[w] = (s_Got[w] or 0) + turtle.getItemCount(i) break
                            end
                        end
                    end
                end
                for w, n in pairs(s_Want) do if (s_Got[w] or 0) < n then s_Short = w break end end
            end
            SetHauling(nil)

            -- MAKE WHAT THE MATERIALS ALLOW, NOT ALL OR NOTHING.
            --
            -- The order was 32 runs and storage held 22 logs, so this refused outright -- and would
            -- have gone on refusing until somebody happened to gather exactly enough. Eighty-eight
            -- planks the fleet could have had sat unmade because ten were missing. Scaling the run
            -- count down is what turns a blocked chain into a slower one.
            local s_Fit = nil
            for w, per in pairs(s_Inputs) do
                local canDo = math.floor((s_Got[w] or 0) / (tonumber(per) or 1))
                if s_Fit == nil or canDo < s_Fit then s_Fit = canDo end
            end
            if s_Fit == nil or s_Fit < 1 then
                error("nothing available for: " .. tostring(s_Short or (s_Req[1] and s_Req[1].name)), 0)
            end
            if s_Fit < s_Runs then
                trace(("craft: materials cover %d of %d runs -- making %d"):format(s_Fit, s_Runs, s_Fit))
                -- Only s_Runs. s_Wanted is derived from it further down, and is declared below
                -- this point -- assigning it here would write a global and silently do nothing.
                s_Runs = s_Fit
            end
            trace("craft: ingredients aboard")
            local cx, cy, cz = pgps.getCachedPosition()
            s_Hand = {pos = {x = cx or 0, y = (cy or 64) - 1, z = cz or 0}, self = true}
        end

        if type(s_Hand) ~= "table" or s_Hand.pos == nil then
            error("storage would not hand over ingredients", 0)
        end
        if s_Hand.complete == false then
            -- Stop rather than craft a partial batch. A short craft silently produces fewer items
            -- than the plan counted on, and the shortfall surfaces much later as a mystery.
            local s_Miss = ""
            for _, m in ipairs(s_Hand.short or {}) do s_Miss = s_Miss .. m.name .. " x" .. m.count .. " " end
            error("short of " .. s_Miss, 0)
        end

        -- How many of each kind this batch needs, so staging stops as soon as it has enough
        -- instead of pulling the whole store through the turtle.
        local s_Wanted = {}
        for name, per in pairs(s_Inputs) do s_Wanted[name] = per * s_Runs end

        -- 2. Get to the ingredients -- unless we are already holding them.
        --
        -- DO NOT FLY OFF, AND DO NOT EMPTY THE INVENTORY, WHEN WE FETCHED THEM OURSELVES.
        --
        -- This unconditionally flew to the pickup chest and then called emptyInventory(), which
        -- puts EVERY slot down. When the drone had collected the ingredients itself -- the normal
        -- path here, since StorageMan cannot push -- that dropped the ingredients back into the
        -- chest one line before staging tried to find them in the inventory. The log read
        -- "collected ingredients from storage" and then "craft staged: [] wanted oak_log x8", with
        -- the logs going in and straight back out of the same chest, for hours.
        if not (s_Hand and s_Hand.self) then
            -- ArriveOrAskToMove, not a bare ArriveAt: the pickup chest is reached from wherever
            -- the crafter was -- routinely ground nobody has surveyed -- AND its access square is
            -- one block, usually occupied by a drone that has just finished using the same chest.
            -- A parked drone is not a wall: moveTo will not route through it and digTo will not dig
            -- it, so a bare arrival simply fails and the whole craft fails with it. Asking costs
            -- one message. This is the same primitive Deposit uses, for the same reason.
            if not ArriveOrAskToMove(s_Hand.pos.x, s_Hand.pos.y + 1, s_Hand.pos.z,
                                     (s_Hand.pos.y or 64) + 4, "pickup") then
                error("could not reach the pickup chest", 0)
            end
            -- 3. Load the grid. Layout IS the recipe: turtle.craft reads the slots and infers the
            --    result, so a misplaced ingredient yields the wrong item or nothing at all.
            Doing(("craft %s: clearing the grid at the pickup chest"):format(tostring(s_Item):gsub("^minecraft:", "")))
            emptyInventory()               -- leftovers change what the grid means
        else
            -- Same requirement -- the grid must hold nothing but the recipe -- met without
            -- discarding what we came here with. Only the slots that are NOT ingredients go down.
            for i = 1, 16 do
                if turtle.getItemCount(i) > 0 then
                    local det = turtle.getItemDetail(i)
                    local keep = false
                    if det and det.name then
                        for w in pairs(s_Wanted) do
                            if SameItem(w, det.name) then keep = true break end
                        end
                    end
                    if not keep then turtle.select(i) PutDown() end
                end
            end
            turtle.select(1)
        end
        -- ALREADY ABOARD? THEN STAGE FROM THE INVENTORY, NOT THE CHEST.
        --
        -- When storage cannot push, the drone collects the ingredients itself -- and then this went
        -- straight back to the chest to stage them, where they are no longer sitting, because the
        -- drone is holding them. "collected ingredients from storage" followed immediately by
        -- "craft staged: [] wanted minecraft:oak_logx8" and "short of minecraft:oak_log", with the
        -- logs in its own inventory the whole time.
        Doing(("craft %s: staging the grid"):format(tostring(s_Item):gsub("^minecraft:", "")))
        local s_Stage, s_StageErr
        if s_Hand and s_Hand.self then
            s_Stage = {}
            for i = 1, 16 do
                local det = turtle.getItemDetail(i)
                if det and det.name then
                    for want in pairs(s_Wanted) do
                        if s_Stage[want] == nil and SameItem(want, det.name) then
                            s_Stage[want] = i
                        end
                    end
                end
            end
            local s_Missing = nil
            for want in pairs(s_Wanted) do
                if s_Stage[want] == nil then s_Missing = want break end
            end
            if s_Missing then
                s_Stage, s_StageErr = nil, "collected but not holding " .. tostring(s_Missing)
            end
        else
            s_Stage, s_StageErr = stageFromChest(s_Wanted)
        end
        if s_Stage == nil then error(s_StageErr, 0) end
        do
            local s_Rep = ""
            for n, sl in pairs(s_Stage) do
                s_Rep = s_Rep .. n .. "@" .. sl .. "x" .. turtle.getItemCount(sl) .. " "
            end
            trace("craft staged: [" .. s_Rep .. "] wanted " ..
                  (function() local t = "" for n, c in pairs(s_Wanted) do t = t .. n .. "x" .. c .. " " end return t end)())
        end

        -- Alias every requested name onto whatever of the same family actually got staged, so the
        -- grid lookups below succeed with spruce when the recipe says oak.
        for _, wantName in ipairs((function()
                local t = {} for n in pairs(s_Wanted) do t[#t + 1] = n end
                if s_Grid then for i = 1, 9 do if type(s_Grid[i]) == "string" then t[#t + 1] = s_Grid[i] end end end
                return t end)()) do
            if s_Stage[wantName] == nil then
                for got, slot in pairs(s_Stage) do
                    if SameItem(wantName, got) then s_Stage[wantName] = slot break end
                end
            end
        end

        -- Slot -> exactly how many it must hold when turtle.craft() is called. Recorded as the grid
        -- is dealt, because the clean-up below needs to know the difference between an ingredient
        -- and a surplus of the same item in the same slot.
        local s_Need = {}
        if s_Grid then
            for i = 1, 9 do
                local want = s_Grid[i]
                -- textutils/JSON turns a nil hole into false or a sentinel depending on transport,
                -- so an empty cell is anything that is not a string.
                if type(want) == "string" then
                    local n = dealInto(s_Stage[want], CRAFT_SLOTS[i], s_Runs)
                    if n < s_Runs then
                        error(("only %d/%d of %s reached slot %d"):format(n, s_Runs, want, i), 0)
                    end
                    s_Need[CRAFT_SLOTS[i]] = (s_Need[CRAFT_SLOTS[i]] or 0) + s_Runs
                end
            end
        else
            local s_At = 1
            for name, per in pairs(s_Inputs) do
                local n = dealInto(s_Stage[name], CRAFT_SLOTS[s_At], per * s_Runs)
                if n < per * s_Runs then error("short of " .. name, 0) end
                s_Need[CRAFT_SLOTS[s_At]] = (s_Need[CRAFT_SLOTS[s_At]] or 0) + per * s_Runs
                s_At = s_At + 1
            end
        end

        -- EVERY OTHER SLOT MUST BE EMPTY -- INCLUDING THE ONES OUTSIDE THE GRID.
        --
        -- CC:T matches the recipe against the WHOLE inventory, not just slots 1-3/5-7/9-11. Fourteen
        -- surplus logs left in slot 16 -- the remainder of the stack the drone had just fetched --
        -- turned a correct 3x3 layout into "No matching recipes". The grid was right and the craft
        -- was refused anyway, which reads as a broken recipe and is not one.
        --
        -- The surplus is not discarded: the drone is standing on the chest it fetched from, so it
        -- goes back where it came from and stays available for the next run.
        for i = 1, 16 do
            local have = turtle.getItemCount(i)
            local want = s_Need[i] or 0
            if have > want then
                turtle.select(i)
                if not PutDown(have - want) then
                    error(("cannot clear slot %d for the craft -- no container below"):format(i), 0)
                end
            end
        end
        turtle.select(1)
        ReportChest()          -- the surplus went back into that chest; say so (see emptyInventory)

        -- 4. Craft, then put the result away.
        Doing(("craft %s: assembling x%d"):format(tostring(s_Item):gsub("^minecraft:", ""), s_Runs))
        local s_Ok, s_Err = turtle.craft()
        if not s_Ok then
            error("craft refused: " .. tostring(s_Err) ..
                  " (layout wrong, or this is not a valid recipe)", 0)
        end

        local s_Made = 0
        for i = 1, 16 do s_Made = s_Made + turtle.getItemCount(i) end
        Doing(("craft %s: made it, depositing"):format(tostring(s_Item):gsub("^minecraft:", "")))
        Deposit()
        return {message = ("crafted %s x%d"):format(s_Item, s_Runs), item = s_Item, runs = s_Runs,
                held = s_Made}
    end)
end


-- BRANCH MINING: how the fleet finds ore it has never seen.
--
-- Everything before this could only mine ore the map already knew about, and the map could only
-- learn about ore a SCOUT had scanned. That loop cannot close for iron: a turtle carries two
-- upgrades and the wireless modem takes one, so a scout has a geo scanner and no pickaxe while a
-- miner has a pickaxe and cannot see through rock. The scanner reaches 8 blocks, so surveying the
-- surface at y=85 can never reveal iron at y=30. "We are short of iron" was therefore unanswerable
-- by any combination of drones -- not because of a bug, but because nothing in the system ever went
-- underground to look.
--
-- A miner does not need to see through rock. It needs to EXPOSE rock and look at what it exposed,
-- which is exactly what a human does: sink a shaft, drive tunnels, and check the faces you open.
--
-- Cost model, because every move counts: inspecting forward, up and down costs nothing extra --
-- the turtle is already facing forward and inspectUp/inspectDown need no turning. Checking the
-- side walls needs two turns plus two back, four wasted steps per block, so it is done on an
-- interval instead. Ore missed in a side wall is picked up by the neighbouring branch.
local ORE_HINTS = {"_ore", "ancient_debris", "raw_"}

local function looksValuable(p_Name)
    if p_Name == nil then return false end
    if IsProtected(p_Name) then return false end
    for _, hint in ipairs(ORE_HINTS) do
        if string.find(p_Name, hint, 1, true) then return true end
    end
    return false
end

-- Record what we just looked at, so exposing a face TEACHES THE MAP even when we leave the block
-- alone. A tunnel is a survey the fleet paid for anyway; throwing the observations away would mean
-- digging the same ground again later to learn the same thing.
local function noteFace(p_Dx, p_Dy, p_Dz, p_Ok, p_Blk)
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return end
    local idx = (cx + p_Dx) .. ":" .. (cy + p_Dy) .. ":" .. (cz + p_Dz)
    if p_Ok and p_Blk then
        pgps.noteObservation(idx, 1, {true, {name = p_Blk.name}})
    else
        pgps.noteObservation(idx, 0)
    end
end

--- FOLLOW THE VEIN, AND LOOK AT EVERY WALL.
--
-- The tunnel loop checked forward, up and down on each step but the SIDE walls only every sixth
-- step, so five blocks in six went past with their walls never inspected -- and when something was
-- found, exactly one block of it was taken and the rest of the vein left in the ground. Watching a
-- miner drive a corridor straight past exposed iron is what that looks like from the surface, and
-- it is the single most expensive thing the fleet was doing: the tunnel is already paid for, the
-- ore beside it is free, and turning costs time but no fuel.
--
-- Bounded rather than exhaustive. A budget and a depth limit mean a miner that breaks into a large
-- deposit takes a useful bite and returns to its tunnel, instead of wandering off through the rock
-- and losing the grid it was cutting.
local VEIN_BUDGET = 32   -- blocks per strike
local VEIN_DEPTH  = 6    -- how far from the tunnel a vein may pull us

--- Dig into an adjacent ore block, recurse from inside it, then step back out.
local function veinFrom(p_Budget, p_Depth)
    if p_Depth > VEIN_DEPTH or p_Budget[1] <= 0 or not executing then return 0 end
    local s_Got = 0

    -- Vertical faces first: they need no turning.
    local s_Vert = {
        {turtle.inspectUp,   DigUp,   pgps.up,   pgps.down},
        {turtle.inspectDown, DigDown, pgps.down, pgps.up},
    }
    for _, v in ipairs(s_Vert) do
        if p_Budget[1] <= 0 or not executing then break end
        local ok, blk = v[1]()
        if ok and blk and looksValuable(blk.name) then
            if v[2]() then
                p_Budget[1] = p_Budget[1] - 1
                s_Got = s_Got + 1
                -- Step in to see what the block was hiding, then come straight back out so the
                -- caller's position is unchanged whatever the vein does.
                if v[3]() then
                    s_Got = s_Got + veinFrom(p_Budget, p_Depth + 1)
                    v[4]()
                end
            end
        end
    end

    -- Then the four horizontals. Four right turns end on the original heading, so the drone is
    -- facing the way it started whether or not anything was found.
    for _ = 1, 4 do
        if p_Budget[1] <= 0 or not executing then break end
        local ok, blk = turtle.inspect()
        if ok and blk and looksValuable(blk.name) then
            if DigForward() then
                p_Budget[1] = p_Budget[1] - 1
                s_Got = s_Got + 1
                if pgps.forward() then
                    s_Got = s_Got + veinFrom(p_Budget, p_Depth + 1)
                    pgps.back()
                end
            end
        end
        pgps.turnRight()
    end

    return s_Got
end

--- Check the two SIDE walls only, and only when the map cannot already rule them out.
---
--- The first version turned right four times on every step. That inspects forward -- which
--- boreForward has already done -- and backward, which is the tunnel we just dug, so half the
--- spinning was re-examining known blocks and it made the miners look demented. Only left and
--- right are new information.
---
--- Better still is not turning at all. A turn costs no fuel but it costs TIME, and time is the
--- whole budget of a mining run. The scouts scan eight blocks through solid rock, so the map very
--- often already knows what is beside the tunnel -- and this is exactly the collaboration the
--- fleet is supposed to have: the scout looks through the wall so the miner does not have to turn
--- around to find out. When the map says stone, we walk on. When it says ore, or says nothing at
--- all, we look.
local function sideKnownWorthless(p_Dx, p_Dz)
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return false end
    local idx = (cx + p_Dx) .. ":" .. (cy) .. ":" .. (cz + p_Dz)

    -- Air is nothing to mine.
    if pgps.cachedWorld and pgps.cachedWorld[idx] == 0 then return true end

    local s_Det = pgps.cachedWorldDetail and pgps.cachedWorldDetail[idx]
    if type(s_Det) == "table" and type(s_Det[2]) == "table" and s_Det[2].name then
        return not looksValuable(s_Det[2].name)
    end
    return false      -- unknown: worth a look
end

local function harvestAround()
    local s_Budget = {VEIN_BUDGET}
    local s_Got = 0

    -- Which way is left and right, in world terms, from the current heading.
    local _, _, _, s_Dir = pgps.getCachedPosition()
    local s_Side = {
        [0] = {{-1, 0}, {1, 0}},   -- facing north: left is -x, right is +x
        [1] = {{0, 1}, {0, -1}},   -- west
        [2] = {{1, 0}, {-1, 0}},   -- south
        [3] = {{0, -1}, {0, 1}},   -- east
    }
    local s_LR = s_Dir and s_Side[s_Dir]

    local s_Left  = (not s_LR) or (not sideKnownWorthless(s_LR[1][1], s_LR[1][2]))
    local s_Right = (not s_LR) or (not sideKnownWorthless(s_LR[2][1], s_LR[2][2]))

    -- Nothing worth turning for: walk on. This is the case the scouts are meant to create.
    if not s_Left and not s_Right then return 0 end

    if s_Left then
        pgps.turnLeft()
        local ok, blk = turtle.inspect()
        if ok and blk and looksValuable(blk.name) and DigForward() then
            s_Budget[1] = s_Budget[1] - 1
            s_Got = s_Got + 1
            if pgps.forward() then
                s_Got = s_Got + veinFrom(s_Budget, 2)
                pgps.back()
            end
        end
        pgps.turnRight()
    end

    if s_Right then
        pgps.turnRight()
        local ok, blk = turtle.inspect()
        if ok and blk and looksValuable(blk.name) and DigForward() then
            s_Budget[1] = s_Budget[1] - 1
            s_Got = s_Got + 1
            if pgps.forward() then
                s_Got = s_Got + veinFrom(s_Budget, 2)
                pgps.back()
            end
        end
        pgps.turnLeft()
    end

    return s_Got
end

-- Look at the three faces a turtle can see without turning, and take anything worth taking.
local function workFace(p_Inspect, p_Dig, p_Dx, p_Dy, p_Dz)
    local s_Ok, s_Blk = p_Inspect()
    noteFace(p_Dx, p_Dy, p_Dz, s_Ok, s_Blk)
    if s_Ok and s_Blk and looksValuable(s_Blk.name) then
        if p_Dig() then return 1 end
    end
    return 0
end

function OnMine(p_ID, p_Message)
    return RunJob("Mine", p_Message.data, {status = "mining", travel = false}, function(d)
        local s_Depth   = tonumber(d.depth)    or 35    -- target Y for the grid
        local s_Length  = tonumber(d.length)   or 32    -- how far each tunnel runs
        local s_Lines   = tonumber(d.branches) or 4     -- tunnels in the grid
        -- SPACED FOR THE SCANNER, not for the pickaxe.
        --
        -- A geo scanner reaches 8 blocks, so tunnels 16 apart let the scan spheres tile the rock
        -- between them with nothing missed. Digging densely to find ore by touch is the expensive
        -- way round: cut a sparse grid, then let one scan read thousands of cells of the rock it
        -- opens up. The tunnels are scaffolding for the SCOUT, not the search itself.
        local s_Spacing = tonumber(d.spacing)  or 16
        local s_WallEvery = tonumber(d.wallEvery) or 6

        local s_Got, s_Steps = 0, 0

        -- Two lines. A shaft interrupted by a fleet stand-down does not re-cut the lines it already
        -- drove; sinking is self-healing because it descends through the air it already made, but
        -- the grid is not -- each line is another 24 blocks of tunnel.
        local s_MineDone = Resumable(d)
        s_MineDone.announce("mine")

        -- Cut a tunnel a person can walk down: floor, plus two blocks of air.
        --
        -- The turtle rides at floor level and clears the block ahead and the one above it before
        -- stepping in. That is two digs per block instead of one, and digs are FREE -- they cost
        -- time, not fuel -- while the move is what actually costs. So headroom is nearly free, and
        -- a one-high tunnel nobody can walk through is a worse artefact for the same fuel.
        -- SAY WHICH HALF FAILED.
        --
        -- This returned a bare nil whether the DIG failed or the MOVE failed, and those want
        -- opposite fixes -- one is bedrock or something protected, the other is a refused step. The
        -- log said "bore blocked on line 2 step 2" for hours without ever saying blocked BY WHAT.
        local function boreForward()
            local s_Ore = 0
            s_Ore = s_Ore + workFace(turtle.inspect,   DigForward, 0, 0, 0)
            local s_Dug, s_DigWhy = DigForward()
            if not s_Dug then return nil, "dig: " .. tostring(s_DigWhy or "refused") end
            s_Ore = s_Ore + workFace(turtle.inspectUp, DigUp,      0, 1, 0)
            DigUp()                                   -- headroom, whether or not it held ore
            local s_Moved, s_MoveWhy = pgps.forward()
            if not s_Moved then return nil, "move: " .. tostring(s_MoveWhy or "refused") end
            -- Now standing in the new block: clear the head-height block ahead of us too, so the
            -- corridor stays two high the whole way rather than only where it happened to be air.
            s_Ore = s_Ore + workFace(turtle.inspectUp, DigUp, 0, 1, 0)
            DigUp()
            return s_Ore
        end

        -- 1. Sink the access shaft.
        if d.pos and d.pos.x then
            -- Traced on BOTH sides. The mine loop logged nothing at all while drones visibly bobbed
            -- up and down, which narrowed it to this line: the job had not started, it was still
            -- travelling. A long silent call is indistinguishable from a hung one without this.
            local sx, sy, sz = pgps.getCachedPosition()
            -- Print the coordinate actually being travelled to, not the plot coordinate. The trace
            -- said "-> -478,63,66" for hours while every mover was refusing that exact block for
            -- being solid; had it printed the real target the mismatch would have been obvious.
            trace(("mine: travelling %s,%s,%s -> %s,%s,%s (head at y=%s)"):format(
                tostring(sx), tostring(sy), tostring(sz),
                tostring(d.pos.x), tostring((tonumber(d.pos.y) or 0) + 1), tostring(d.pos.z),
                tostring(d.pos.y)))
            local s_Reach, s_ReachWhy = reachableTarget(tonumber(d.pos.x), (tonumber(d.pos.y) or 0) + 1, tonumber(d.pos.z))
            if not s_Reach then
                trace("mine: " .. tostring(s_ReachWhy))
                error(tostring(s_ReachWhy), 0)
            end
            -- STAND ON THE SHAFT HEAD, DO NOT TRY TO STAND INSIDE IT.
            --
            -- The head is a point in the GROUND -- the comment below has said so for a long time --
            -- and every travel call here aimed at exactly that block. Nothing can arrive there:
            -- moveTo asks the server to path into a solid cell and is told there is no route,
            -- flyTo cannot enter a solid block and wanders its whole 512-step budget looking for a
            -- way in, and digTo burns 256 steps trying to tunnel to a target it is already
            -- adjacent to. All three then reported failure, RunJob threw, TaskMan handed the same
            -- task straight back, and the drone did it again. mine_head-01 is the plot directly
            -- under the tower, so the centre of the settlement was the one place that could never
            -- be excavated -- for hours, with clear air the whole way and a miner nine blocks off.
            --
            -- The sink loop immediately below already assumes this: it DigDown()s and then steps
            -- down, which only makes sense standing on top of the head. Every other job travels to
            -- y+1 for the same reason. This one place did not.
            local s_HeadY = tonumber(d.pos.y)
            local s_StandY = s_HeadY and (s_HeadY + 1) or nil
            local s_At, s_Why = pgps.moveTo(tonumber(d.pos.x), s_StandY, tonumber(d.pos.z))
            -- A MINER THAT CANNOT WALK TO ITS OWN SHAFT SHOULD DIG TO IT.
            --
            -- This gave up the moment moveTo could not find a mapped route, which on a barely
            -- surveyed world is most of the time -- the map is built BY going places, so requiring a
            -- known route before travelling is circular. GoTo and Survey both learned the
            -- moveTo -> flyTo -> digTo chain; the mine job never did, so miners threw
            -- "could not reach the shaft head" seven blocks from it while carrying a pickaxe.
            -- DIG BEFORE FLYING. The order matters, and the other way round wastes minutes.
            --
            -- A shaft head is a point in the GROUND, so the destination is solid by definition and
            -- flyTo cannot enter it -- it wanders up to 512 steps looking for a way into a block
            -- that has no way in, and only then gives up. A miner is carrying the tool that solves
            -- this. Scouts keep flyTo first because they cannot dig at all.
            if s_At == false and CanDig() then
                trace("mine: no mapped route (" .. tostring(s_Why) .. ") -- digging a path")
                s_At, s_Why = pgps.digTo(tonumber(d.pos.x), s_StandY, tonumber(d.pos.z))
            end
            if s_At == false then
                trace("mine: cannot dig there either (" .. tostring(s_Why) .. ") -- flying")
                s_At, s_Why = pgps.flyTo(tonumber(d.pos.x), s_StandY, tonumber(d.pos.z))
            end
            if s_At == false then
                trace("mine: could not reach shaft head -- " .. tostring(s_Why))
                error("could not reach the shaft head: " .. tostring(s_Why), 0)
            end
            trace("mine: arrived at shaft head")
        end

        local _, cy = pgps.getCachedPosition()
        local s_StartY = cy
        trace(("mine: sinking shaft from y=%s to y=%s"):format(tostring(cy), tostring(s_Depth)))
        -- Report the descent as it happens, so anything waiting on a DEPTH -- the scans do -- can
        -- start as soon as the shaft passes it, instead of waiting for the whole dig to end.
        local s_Top = cy
        while cy and cy > s_Depth do
            if not executing then break end
            if not depositIfFull() then break end
            s_Got = s_Got + workFace(turtle.inspectDown, DigDown, 0, -1, 0)
            if not DigDown() then break end
            if not pgps.down() then break end
            _, cy = pgps.getCachedPosition()
            s_Steps = s_Steps + 1
            if s_Top and s_Top > s_Depth and cy then
                Doing(("shaft: down to y=%d (target %d)"):format(cy, s_Depth))
                SaveProgress(math.floor((s_Top - cy) / (s_Top - s_Depth) * 100))

                -- PUBLISH THE SHAFT WHILE DIGGING IT, NOT AFTER.
                --
                -- A shaft is infrastructure the moment it exists: it is the only way a SCOUT can get
                -- underground, since it carries a scanner where a pickaxe would go and cannot cut
                -- its own way down. But observations were only uploaded when the whole mine job
                -- finished -- branches and all -- so for the entire dig the map still showed solid
                -- rock, a_star refused to route down it, and the scan tasks waiting on that depth
                -- sat in the shaft unable to reach a target nine blocks below them. D19 and D20
                -- burned eighteen minutes each on exactly that.
                --
                -- Throttled to once every 15 blocks: enough for a follower to keep up, cheap enough
                -- not to add to MapServer's load.
                if (s_Steps % 15) == 0 then pcall(UploadWorld) end
            end
        end

        -- A SHAFT THAT DID NOT REACH DEPTH IS A FAILED SHAFT.
        --
        -- This used to carry on to the grid and then return a result table regardless, so the task
        -- was marked DONE whatever happened underground. That matters far beyond the tidiness of
        -- the report: order.prospect pairs every shaft with a scan task at the SAME depth and makes
        -- it dependsOn the shaft, precisely so nobody is sent to a place that has not been opened
        -- yet. Reporting a shaft that never sank as complete satisfied that dependency and released
        -- the scan.
        --
        -- The result was scouts dispatched to points dozens of blocks inside solid rock, carrying a
        -- geo scanner where a pickaxe would go. D2 spent its fuel climbing to y=110 and back trying
        -- to find a way into y=35 at a mine head that had never been dug, failing, being requeued,
        -- and doing it again -- while the queue held four more scans just like it.
        if cy and s_Depth and cy > s_Depth then
            local s_Why = ("shaft stopped at y=%d, short of the target y=%d"):format(cy, s_Depth)
            trace("mine: " .. s_Why)
            if FreeSlots() < 16 then pcall(Deposit) end
            UploadWorld()
            return nil, s_Why
        end

        -- 2. Cut the grid, serpentine, so no leg is walked empty.
        for line = 1, s_Lines do
            if not executing then break end
            if s_MineDone.done("line" .. line) then
                trace(("mine: line %d already cut -- skipping"):format(line))
                goto nextline
            end

            for step = 1, s_Length do
                if not executing then break end
                if not depositIfFull() then break end

                local s_Ore, s_BoreWhy = boreForward()
                if s_Ore == nil then
                    trace(("mine: bore blocked on line %d step %d -- %s")
                        :format(line, step, tostring(s_BoreWhy)))
                    break
                end
                s_Got = s_Got + s_Ore
                s_Steps = s_Steps + 1

                -- Every wall, every step, and follow whatever turns up. See harvestAround: the
                -- old code sampled the side walls once every s_WallEvery steps and took a single
                -- block when it hit, which is how a corridor gets driven straight past a vein.
                s_Got = s_Got + harvestAround()
            end

            -- Step across to the next line of the grid, cutting the crosscut as we go so the whole
            -- thing stays connected and walkable rather than being a set of dead-end corridors.
            if line < s_Lines then
                pgps.turnRight()
                for _ = 1, s_Spacing do
                    if not executing then break end
                    if boreForward() == nil then break end
                    s_Steps = s_Steps + 1
                end
                pgps.turnRight()
                -- Face back along the next line; the serpentine reverses direction each pass.
                s_Length = s_Length          -- unchanged; direction comes from the two turns above
            end
            s_MineDone.mark("line" .. line)
            ::nextline::
        end

        UploadWorld()
        -- UNLOAD BEFORE REPORTING DONE.
        --
        -- The job only deposited when the inventory was nearly full, so a shaft that ended with
        -- fifteen slots of stone simply kept it: D3 finished holding roughly 200 cobblestone while
        -- storage sat unchanged at 47 items, and the fleet looked unproductive while carrying the
        -- proof that it was not. Whatever was cut belongs in the chest before the drone takes its
        -- next order.
        if FreeSlots() < 16 then pcall(Deposit) end

        -- The depth REACHED, not the depth requested. This reported the target either way, so a
        -- shaft that stalled 20 blocks up still announced "at y=40".
        local _, s_EndY = pgps.getCachedPosition()
        return {message = ("cut %d tunnel blocks at y=%s (from y=%s), took %d ore")
                    :format(s_Steps, tostring(s_EndY or s_Depth), tostring(s_StartY), s_Got),
                got = s_Got, steps = s_Steps, depth = s_EndY or s_Depth}
    end)
end


-- BUILDING: turning material into infrastructure.
--
-- The fleet could dig, carry, smelt and craft, and everything it made went straight into a chest.
-- Nothing could PLACE a block, so the settlement could accumulate chests forever and never own a
-- single structure -- no field caches, no smelter banks, nothing that makes the next job cheaper.
--
-- The layout arrives as data rather than being computed here on purpose. HQ has already costed it,
-- checked it against the plot registry, and ordered the blocks bottom-up; a builder that worked out
-- its own geometry could not have any of that checked before it started swinging.

--- Find a slot holding p_Name and select it.
local function selectItem(p_Name)
    for i = 1, 16 do
        local d = turtle.getItemDetail(i)
        if d and d.name == p_Name then
            turtle.select(i)
            return true
        end
    end
    return false
end

function OnBuild(p_ID, p_Message)
    return RunJob("Build", p_Message.data, {status = "building", travel = false}, function(d)
        local s_Origin = d.origin
        local s_Blocks = d.blocks
        if type(s_Origin) ~= "table" or s_Origin.x == nil then error("no origin", 0) end
        if type(s_Blocks) ~= "table" or #s_Blocks == 0 then error("nothing to build", 0) end

        -- Two lines. A build interrupted by a fleet stand-down resumes where it stopped instead of
        -- re-walking every block it already placed.
        local s_BuildDone = Resumable(d)
        s_BuildDone.announce("build")

        -- 1. Collect the materials. Same handover chest crafting uses.
        local s_Need = {}
        for _, b in ipairs(s_Blocks) do
            if b.item then s_Need[b.item] = (s_Need[b.item] or 0) + 1 end
        end
        local s_Req = {}
        for name, count in pairs(s_Need) do s_Req[#s_Req + 1] = {name = name, count = count} end

        local s_Hand = PowNet.sendAndWaitForResponse("StorageMan",
            PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "Provide", {items = s_Req}),
            PowNet.SERVER_PROTOCOL, 8)
        if type(s_Hand) ~= "table" or s_Hand.pos == nil then
            error("storage would not hand over materials", 0)
        end
        if s_Hand.complete == false then
            local s_Miss = ""
            for _, m in ipairs(s_Hand.short or {}) do s_Miss = s_Miss .. m.name .. " x" .. m.count .. " " end
            error("short of " .. s_Miss, 0)
        end

        -- ArriveOrAskToMove, not a bare ArriveAt -- see the note on the crafting pickup above.
        -- The bay is the most congested airspace in the settlement and the access square is one
        -- block, so "a drone is standing there" is the ORDINARY reason a pickup fails, not an
        -- exceptional one. build-chest-row failed on exactly this while the settlement sat at zero
        -- free slots waiting for the chests it was trying to collect.
        if not ArriveOrAskToMove(s_Hand.pos.x, s_Hand.pos.y + 1, s_Hand.pos.z,
                                 (s_Hand.pos.y or 64) + 4, "pickup") then
            error("could not reach the pickup chest", 0)
        end
        emptyInventory()
        local s_Stage, s_StageErr = stageFromChest(s_Need)
        if s_Stage == nil then error(s_StageErr, 0) end

        -- Materials live in the staging slots; spread them into the main inventory so placeDown
        -- has something in the selected slot regardless of which kind is wanted next.
        for _, slot in ipairs(STAGE_SLOTS) do
            local dd = turtle.getItemDetail(slot)
            if dd then
                turtle.select(slot)
                for i = 1, 12 do
                    if turtle.getItemCount(i) == 0 then turtle.transferTo(i) break end
                end
            end
        end

        -- 2. Place. The drone stands ABOVE each target and places downwards.
        --
        -- IT NOW TURNS FIRST, WHEN THE BLOCK CARES.
        --
        -- "the one placement that needs no knowledge of which way it is facing" was true of the
        -- placement and false of the RESULT: Minecraft takes a directional block's orientation from
        -- whoever placed it, so every stair, furnace, funnel and chute this fleet has ever built came
        -- out pointing wherever the drone happened to be looking when it arrived. For a planked pad
        -- that is invisible. For a factory it is the difference between a machine and an ornament,
        -- and for a staircase it is the difference between stairs and a pile of steps.
        --
        -- b.heading is the direction the DRONE must face while placing -- not the direction the block
        -- ends up pointing, which varies by block type. Saying it the drone's way keeps the one thing
        -- the drone can actually guarantee in the blueprint, and leaves the per-block convention with
        -- the blueprint, which is where it can be written down and checked.
        local s_Placed, s_Skipped = 0, 0
        for _, b in ipairs(s_Blocks) do
            if not executing then break end
            local bx = s_Origin.x + (tonumber(b.dx) or 0)
            local by = s_Origin.y + (tonumber(b.dy) or 0)
            local bz = s_Origin.z + (tonumber(b.dz) or 0)

            -- A BLOCK SKIPPED FOR WANT OF A ROUTE IS NOT A BLOCK THAT DID NOT NEED PLACING.
            -- A bare moveTo fails on unsurveyed ground, and this counted that as "skipped" -- so a
            -- build came out full of holes and still reported success.
            -- Same two lines as every other job: already-placed blocks are not placed twice.
            local s_BK = bx .. ":" .. by .. ":" .. bz
            if s_BuildDone.done(s_BK) then
                -- already placed before the last stand-down
            elseif not TravelTo(bx, by + 1, bz, (by or 64) + 4) then
                s_Skipped = s_Skipped + 1
            else
                s_BuildDone.mark(s_BK)
                -- Something already here. Leave it: overwriting is how a build eats whatever was
                -- standing on the site, and the plot check cannot see blocks that arrived after it
                -- ran. Refusing costs one block; the alternative destroyed a drone once already.
                local s_Occupied, s_What = turtle.inspectDown()
                if s_Occupied then
                    if s_What and s_What.name == b.item then
                        s_Placed = s_Placed + 1        -- already correct; count it as done
                    else
                        s_Skipped = s_Skipped + 1
                    end
                elseif not selectItem(b.item) then
                    error("ran out of " .. tostring(b.item) .. " partway through", 0)
                elseif (b.heading == nil or pgps.turnTo(HEADINGS_()[b.heading]) ~= false)
                        and turtle.placeDown() then
                    s_Placed = s_Placed + 1
                    pgps.noteObservation(bx .. ":" .. by .. ":" .. bz, 1, {true, {name = b.item}})
                else
                    s_Skipped = s_Skipped + 1
                end
            end
        end

        Deposit()          -- leftovers go back rather than riding around in a turtle
        UploadWorld()
        return {message = ("built %d of %d blocks (%d skipped)")
                    :format(s_Placed, #s_Blocks, s_Skipped),
                placed = s_Placed, skipped = s_Skipped, total = #s_Blocks}
    end)
end

function OnLumber(p_ID, p_Message)
    return RunJob("Lumber", p_Message.data, {status = "logging"}, function(d)
        local s_W = tonumber(d.w) or 8
        local s_L = tonumber(d.l) or 8
        local s_Logs, s_Trees = 0, 0

        Serpentine(s_W, s_L, function()
            if not depositIfFull() then return false end
            local ok, blk = turtle.inspect()
            if ok and isLog(blk.name) then
                local n = fellTree()
                if n > 0 then s_Trees = s_Trees + 1 s_Logs = s_Logs + n end
            elseif ok and isLeaf(blk.name) then
                DigForward()
                pgps.forward()
            elseif not stepForward(2) then
                return false
            end
        end, function() return stepForward(2) end)

        return {message = ("felled %d trees, %d logs"):format(s_Trees, s_Logs),
                trees = s_Trees, logs = s_Logs}
    end)
end

-- FUEL RELIEF: THE PART OF A RESCUE THAT WAS MISSING.
--
-- A rescue party carries a chunk loader, a GPS relay and a pickaxe -- the three things a drone that
-- cannot move might be missing. None of them is fuel, and an empty tank is the one failure a tunnel
-- cannot fix. Two drones sat at exactly zero while rescues were queued for them, arrived, dug to a
-- drone that was not walled in, and left it precisely as immobile as they found it.
--
-- The casualty does not have to know this is happening: TryRefuel already sucks from above, below
-- and in front before it burns anything, and its fuel watchdog runs whether or not the drone can
-- move. So delivery is simply "stand on top of it and drop the coal" -- items dropped downward come
-- to rest in the block the deliverer is occupying, which is exactly where suckUp looks.
-- IS THE SELECTED ITEM FUEL?
--
-- turtle.refuel(0) is documented to answer this without consuming anything, and CollectFuel was
-- built on it. It does not answer it reliably here: every relief run dropped the coal it was
-- holding during the unload pass, picked it up again, dropped it again, and reported "storage had
-- nothing burnable" while standing on a chest containing three stacks of coal.
--
-- So the name is the primary test and refuel(0) is only a bonus. Getting this wrong in the
-- pessimistic direction costs a wasted trip; getting it wrong the other way throws the fleet's
-- fuel into a chest it is standing on, which is what happened.
local FUEL_NAMES = {
    ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
    ["minecraft:blaze_rod"] = true, ["minecraft:lava_bucket"] = true, ["minecraft:dried_kelp_block"] = true,
}
local function isFuelSelected(p_Slot)
    local d = turtle.getItemDetail(p_Slot)
    local n = d and d.name
    if n then
        if FUEL_NAMES[n] then return true end
        -- Logs and planks burn too, and there are dozens of wood types.
        -- Anything WoodFamily recognises burns: logs, planks and the nether stems alike.
        if WoodFamily(n) ~= nil then return true end
    end
    local ok, is = pcall(turtle.refuel, 0)
    return ok and is == true
end

-- LOOK FOR THE COAL WHERE THE COAL IS.
--
-- This asked StorageMan for a DEPOSIT POINT and then tried to withdraw fuel from it. A deposit
-- point is the chest with the MOST FREE SPACE -- which is, by construction, the chest least likely
-- to be holding anything, let alone the specific thing we came for. So the relief drone flew to the
-- emptiest chest in the bay, found no coal in it, and reported "storage had nothing burnable" while
-- 407 coal sat in the chest next door. fuel-D5 failed on that, over and over, with a drone at zero
-- fuel waiting for it.
--
-- FetchItems is the primitive for "go and get these materials": it asks where the item actually is,
-- sweeps the other chests when the answer is wrong, and stops as soon as it holds enough to be
-- useful. It exists precisely because this logic kept being rewritten, and this was the fifth copy
-- -- the one that looked in the wrong place.
local function CollectFuel()
    -- UNLOAD BEFORE LOADING.
    --
    -- A miner arrives from a shaft with sixteen slots of cobblestone, so there is nowhere to put the
    -- coal: the withdrawal collects nothing and reports "storage empty" while standing on a chest
    -- holding three stacks. Cargo goes in the chest, fuel stays aboard.
    local s_Below = ContainerBelow()
    if s_Below then
        local s_Put = {}
        for i = 1, 16 do
            if turtle.getItemCount(i) > 0 then
                turtle.select(i)
                if not isFuelSelected(i) then                     -- cargo belongs in the chest
                    local det = turtle.getItemDetail(i)
                    local before = turtle.getItemCount(i)
                    PutDown()
                    local moved = before - turtle.getItemCount(i)
                    if det and det.name and moved > 0 then
                        s_Put[det.name] = (s_Put[det.name] or 0) + moved
                    end
                end
            end
        end
        turtle.select(1)
        ReportStorage("Deposited", s_Put)
        ReportChest()
    end

    -- Coal first, charcoal second -- as separate asks, not one. FetchItems requires EVERY item in
    -- the request, so asking for both at once fails whenever the settlement has only one of them,
    -- which is the normal case.
    local s_Fuel = 0
    for _, s_Name in ipairs({"minecraft:coal", "minecraft:charcoal"}) do
        -- p_Min is a TABLE of per-item minimums, not a scalar. Passing the number 8 here made
        -- FetchItems do `pairs(8)` and throw "bad argument (table expected, got number)" -- which
        -- failed fuel-D3 outright, in the very function that was rewritten to stop fuel failing.
        local s_Got = FetchItems({[s_Name] = 64}, {[s_Name] = 8})
        for _, n in pairs(s_Got or {}) do s_Fuel = s_Fuel + n end
        if s_Fuel > 0 then break end
    end
    if s_Fuel == 0 then return 0, "storage had nothing burnable" end

    -- Top the DELIVERER up too, or it strands next to the drone it came to save.
    pcall(TryRefuel)
    return s_Fuel
end

-- ANY WOOD IS WOOD.
--
-- The recipe table names oak specifically -- oak_log to oak_planks, oak_planks into chests -- but
-- Minecraft does not care: every log species makes its own planks, and every planks species makes
-- the same chest, stick and crafting table. Requiring oak means a fleet standing in a birch forest
-- reports "storage has none of the ingredients: minecraft:oak_log" and never builds anything, which
-- is a self-inflicted shortage.
--
-- Matching by family rather than by name costs nothing and removes a whole class of stall.
function WoodFamily(p_Name)
    if type(p_Name) ~= "string" then return nil end
    if p_Name:find("_planks", 1, true) then return "planks" end
    -- "_stem" is the nether woods (crimson, warped). isLog knew about them and this did not, which
    -- is the drift this consolidation exists to end: three functions in this file each had their
    -- own idea of what wood is, and they did not agree on the nether.
    if p_Name:find("_log", 1, true) or p_Name:find("_wood", 1, true)
       or p_Name:find("_stem", 1, true) then return "log" end
    return nil
end

function SameItem(p_Want, p_Have)
    if p_Want == p_Have then return true end
    local a, b = WoodFamily(p_Want), WoodFamily(p_Have)
    return a ~= nil and a == b
end

-- The general case of OnRelieve: carry a named item to a drone that needs it, instead of fuel.
-- "Go and unload." Its own verb, because a flag on GoTo is a flag nothing reads.
--
-- storage.recall asked drones to deposit by setting deposit=true on a GoTo. OnGoTo does not look
-- at that field, so the order arrived, the drone travelled, and carried on mining with 266
-- cobblestone still aboard -- the tool reported success and nothing happened, which is the exact
-- failure mode this codebase keeps producing.
-- ANSWER A QUESTION ABOUT THE WORLD IN SECONDS INSTEAD OF A DEPLOY CYCLE.
--
-- Every semantic mistake in this file was answerable by asking the game once: does dropDown
-- deposit or does it litter, does refuel(0) report fuel, can a turtle wrap the chest beneath it
-- (it can -- and not knowing produced three wrong implementations of the same function). None of
-- those were hard questions. They were expensive ones, because the only way to ask was edit, sync,
-- reboot, wait three minutes, read a log.
--
-- A slow feedback loop makes the cheap check worth MORE, not less. This is that check: run a
-- snippet on a real drone in the real world and get the value back. Read-only by convention, and
-- pcall'd so a bad probe cannot take the drone down.
function OnProbe(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Src = tostring(d.code or "")
    if s_Src == "" then return false, "no code" end
    local s_Fn, s_Err = load("return " .. s_Src, "probe", "t", _ENV)
    if s_Fn == nil then
        s_Fn, s_Err = load(s_Src, "probe", "t", _ENV)
    end
    if s_Fn == nil then return false, "compile: " .. tostring(s_Err) end

    local ok, res = pcall(s_Fn)
    -- Traced as well as returned: the dispatch path is fire-and-forget, so the log is where the
    -- answer can actually be read.
    if not ok then
        trace(("probe [%s] ERROR %s"):format(s_Src, tostring(res)))
        return true, {ok = false, error = tostring(res)}
    end
    -- Serialise rather than return raw: the answer travels over rednet and a table of peripheral
    -- methods does not survive that.
    local okS, text = pcall(textutils.serialise, res)
    local s_Val = okS and text or tostring(res)
    trace(("probe [%s] = (%s) %s"):format(s_Src, type(res), tostring(s_Val):sub(1, 300)))
    return true, {ok = true, type = type(res), value = s_Val}
end

function OnUnload(p_ID, p_Message)
    return RunJob("Unload", p_Message.data,
        {status = "hauling", travel = false, settle = false, deposit = false}, function(d)
        local s_Held = 0
        for i = 1, 16 do s_Held = s_Held + turtle.getItemCount(i) end
        if s_Held == 0 then return {message = "nothing to unload", moved = 0} end
        if not Deposit() then return nil, "could not reach storage to unload" end
        local s_Left = 0
        for i = 1, 16 do s_Left = s_Left + turtle.getItemCount(i) end
        return {message = ("unloaded %d item(s)"):format(s_Held - s_Left), moved = s_Held - s_Left}
    end)
end

function OnHandover(p_ID, p_Message)
    return RunJob("Handover", p_Message.data,
        {status = "hauling", travel = false, settle = false, deposit = false}, function(d)
        if not (d.pos and d.pos.x) then return nil, "no recipient position" end
        local s_Match = tostring(d.match or "")
        if s_Match == "" then return nil, "nothing named to hand over" end

        -- What we can actually give.
        local s_Have = 0
        for i = 1, 16 do
            local det = turtle.getItemDetail(i)
            if det and det.name and det.name:find(s_Match, 1, true) then
                s_Have = s_Have + turtle.getItemCount(i)
            end
        end
        if s_Have == 0 then return nil, "not carrying anything matching " .. s_Match end

        local s_X, s_Y, s_Z = tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z)
        trace(("handover: taking %d %s to %s at %d,%d,%d")
            :format(s_Have, s_Match, tostring(d.drone or "?"), s_X, s_Y, s_Z))
        -- Directly above: its own block is occupied by the recipient.
        if not TravelTo(s_X, s_Y + 1, s_Z, (s_Y or 64) + 4) then
            return nil, "could not reach " .. tostring(d.drone or "the recipient")
        end

        local s_Given = 0
        for i = 1, 16 do
            local n = turtle.getItemCount(i)
            if n > 0 then
                turtle.select(i)
                local det = turtle.getItemDetail(i)
                if det and det.name and det.name:find(s_Match, 1, true) and HandTo() then
                    s_Given = s_Given + n
                end
            end
        end
        turtle.select(1)
        if s_Given == 0 then return nil, "arrived but could not hand anything over" end

        -- Step aside so the recipient is not boxed in by the drone that just helped it.
        pgps.up()
        trace(("handover: gave %d %s to %s"):format(s_Given, s_Match, tostring(d.drone or "?")))
        return {message = ("handed over %d %s"):format(s_Given, s_Match), given = s_Given}
    end)
end

-- ARRIVING AT THE COORDINATE IS NOT THE SAME AS ARRIVING AT THE DRONE.
--
-- Where to look when the casualty is not directly below: its own block first, then the ring around
-- it, then one level down. Nearest-first, so the common one-block miss costs a single move rather
-- than a survey, and the whole search is bounded -- a rescuer that wanders is a second casualty.
-- THE ERROR IS MOSTLY VERTICAL, BECAUSE THE DRONES WE RESCUE ARE MOSTLY IN HOLES.
--
-- A first version searched a flat ring and one level down, which is the right shape for a casualty
-- on the surface and the wrong one for every casualty we actually have. A drone that runs dry does
-- it in a shaft or a mine, GPS does not reach underground, so its height is dead-reckoned and its
-- height is what drifts. D20 sat at zero fuel reporting -486,71,95 against a recorded -486,67,95:
-- four blocks out in y, nothing in x or z, and the rescuer hovered over empty air four times.
--
-- So: the exact spot, then straight up and down the column -- a shaft is vertical and so is the
-- doubt -- and only then the horizontal ring for the surface case.
local RELIEF_SEARCH = {
    {0,0,0},
    {0,1,0}, {0,-1,0}, {0,2,0}, {0,-2,0}, {0,3,0}, {0,-3,0}, {0,4,0}, {0,-4,0},
    {1,0,0}, {-1,0,0}, {0,0,1}, {0,0,-1},
    {1,0,1}, {1,0,-1}, {-1,0,1}, {-1,0,-1},
}

-- A turtle is the only thing we are willing to hand fuel to. PutDown refuses to drop into thin air
-- -- correctly, since loose items are lost -- so this is the test that decides whether the trip
-- succeeded, and it must be asked BEFORE the drop rather than inferred from its failure.
function FuelRecipientBelow()
    local s_Ok, s_Det = turtle.inspectDown()
    return s_Ok and type(s_Det) == "table" and type(s_Det.name) == "string"
        and s_Det.name:find("turtle", 1, true) ~= nil
end

-- Hunt for a casualty that is close to, but not exactly at, its last reported position.
--
-- Every rescue in the fleet's history failed as "arrived but dropped nothing": the reliever flew to
-- the recorded coordinate, found air beneath it, and correctly declined to throw coal on the floor.
-- The recorded coordinate was usually WRONG rather than stale -- a drone reports the position it
-- believes, and a wrong heading makes that belief drift -- so the rescue depended on the casualty's
-- own broken navigation being accurate. It never was.
-- A RESCUER MUST NOT BECOME A CASUALTY.
--
-- Widening this search from ten candidates to seventeen made every FAILED rescue proportionally
-- more expensive, and the failures are the common case for exactly the drones worth rescuing. D15
-- refuelled to 2,540, spent the entire tank quartering the air around a casualty it could not find,
-- and hit zero itself -- converting one stranded drone into two and handing the next rescuer a
-- longer trip. A search with no fuel bound is a way of losing the fleet one drone at a time.
--
-- So the search stops while the rescuer can still get home. FuelFloorNow is the same reserve the
-- fuel watchdog enforces, and giving up with fuel in the tank is strictly better than arriving
-- empty: the casualty is no worse off, and the rescuer lives to try again once it has topped up.
function FindCasualtyNearby(p_X, p_Y, p_Z)
    for _, o in ipairs(RELIEF_SEARCH) do
        local s_Fuel = turtle.getFuelLevel()
        if s_Fuel ~= "unlimited" and s_Fuel < FuelFloorNow() then
            trace(("relief search broken off at %d fuel -- not enough left to get home"):format(s_Fuel))
            return false
        end
        local x, y, z = p_X + o[1], p_Y + o[2], p_Z + o[3]
        if TravelTo(x, y + 1, z, y + 4) and FuelRecipientBelow() then
            return true, x, y, z
        end
    end
    return false
end

function OnRelieve(p_ID, p_Message)
    return RunJob("Relieve", p_Message.data,
        {status = "hauling", travel = false, settle = false, deposit = false}, function(d)
        if not (d.pos and d.pos.x) then return nil, "no casualty position" end

        local s_Got, s_Why = CollectFuel()
        if s_Got == 0 then return nil, "no fuel to deliver: " .. tostring(s_Why or "storage empty") end
        trace(("relieve: carrying %d fuel to %s,%s,%s"):format(
            s_Got, tostring(d.pos.x), tostring(d.pos.y), tostring(d.pos.z)))

        -- Directly ABOVE the casualty. Its own block is occupied -- by the casualty.
        local s_X, s_Y, s_Z = tonumber(d.pos.x), tonumber(d.pos.y), tonumber(d.pos.z)
        if not TravelTo(s_X, s_Y + 1, s_Z, (s_Y or 64) + 4) then
            return nil, "could not reach the stranded drone"
        end

        -- SAY THE CASUALTY IS MISSING, DO NOT SAY THE DROP FAILED.
        --
        -- "arrived but dropped nothing" described the symptom and hid the cause, so four identical
        -- round trips read as a broken PutDown rather than a drone that was not there. Look around
        -- before giving up, and if it really is absent, name that -- the fix for a missing casualty
        -- is a fresh position, which is a different repair entirely.
        -- No "is it already below?" test here on purpose: RELIEF_SEARCH starts at {0,0,0}, so the
        -- search answers that on its first step. The extra branch bought nothing and this is one of
        -- the largest functions in the file -- see the complexity gate.
        if not FindCasualtyNearby(s_X, s_Y, s_Z) then
            return nil, ("no drone at or around %d,%d,%d -- %s is not where it was last seen")
                :format(s_X, s_Y, s_Z, tostring(d.drone or "the casualty"))
        end

        local s_Dropped = 0
        for i = 1, 16 do
            local s_N = turtle.getItemCount(i)
            if s_N > 0 then
                turtle.select(i)
                -- HandTo, NOT PutDown. PutDown refuses to drop unless ContainerBelow() says there
                -- is a chest or barrel underneath -- and what is underneath a rescue is a DRONE, so
                -- it returned false every single time. Fuel relief has therefore never delivered
                -- anything in the history of this fleet: the rescuer flew out with 64 coal, hovered
                -- over the casualty, refused its own handover, and flew home still carrying it,
                -- reporting "arrived but dropped nothing" -- which read as a navigation fault and
                -- sent us looking at positions for hours.
                --
                -- HandTo exists for exactly this case and its own comment claims "the fuel relief
                -- already solved this shape". It did not; HandTo was generalised from a manoeuvre
                -- that was broken. This is the call site that was supposed to be using it.
                if isFuelSelected(i) and HandTo() then s_Dropped = s_Dropped + s_N end
            end
        end
        turtle.select(1)
        if s_Dropped == 0 then return nil, "arrived but dropped nothing" end

        trace(("relieve: dropped %d fuel onto %s"):format(s_Dropped, tostring(d.drone or "?")))
        -- Step aside so the casualty is not boxed in by its rescuer once it can move again.
        pgps.up()
        return {message = ("delivered %d fuel"):format(s_Dropped), dropped = s_Dropped}
    end)
end

function OnHaul(p_ID, p_Message)
    local d = p_Message.data or {}
    if d.pos == nil then return false, "Missing pos" end
    if executing then return false, "busy" end
    m_Status = "hauling"
    TaskStart()
    local ok = TravelTo(tonumber(d.pos.x), tonumber(d.pos.y) + 1, tonumber(d.pos.z), (tonumber(d.pos.y) or 64) + 4)
    if ok == false then
        TaskEnd() m_Status = "idle"
        Distress("cannot reach pickup", tostring(d.pos.x))
        return false, "unreachable"
    end
    -- Take everything, through the primitive: it fills free slots before judging, which is
    -- what gets the leading stacks out of the chest instead of cycling the same one.
    TakeFromChest(function() return true end)
    local s_Ok = Deposit()
    TaskEnd()
    m_Status = "idle"
    return s_Ok, {message = s_Ok and "hauled" or "haul failed"}
end

function OnAbort()
    -- ALWAYS CLEAR, even when nothing is running.
    --
    -- This used to refuse whenever `executing` was false -- which is precisely the state abort is
    -- most needed for. A drone can hold a stale status with no job behind it: a body that ended
    -- abnormally, or a task cancelled server-side that never reached the machine. It then reports
    -- "working" for ever, TaskMan never offers it anything because it is not idle, and the supply
    -- loop correctly concludes there is nobody free and does nothing at all.
    --
    -- Two drones sat like that and the whole fleet looked like it had stopped working, while every
    -- component was behaving exactly as designed.
    local s_Was = executing
    Say("Aborting (was executing: " .. tostring(s_Was) .. ")")
    -- Clear the flag as well as breaking pgps. BreakExec stops a pgps path mid-flight, but the
    -- survey loop is our own and only watches `executing` -- without this an abort would stop the
    -- current move and the lawnmower would calmly carry on to the next cell. This runs on the
    -- server thread, which is precisely why it can interrupt work happening on the drone thread.
    executing = false
    pgps.BreakExec()
    m_Status = "idle"
    m_Job = nil
    pcall(saveResume)
    -- Say so immediately rather than waiting up to 30s for the next beat: the whole point is to
    -- get this drone back into the pool.
    pcall(SendHeartBeat)
    return true, s_Was and "Aborted" or "was already idle; stale status cleared"
end


function OnStartTask(p_ID, p_Message)

end

function OnAbortTask(p_ID, p_Message)

end



m_DroneEvents = {
    Reboot = {
        func = OnReboot,
    },
    -- The verb the whole recipe graph is for. Only a turtle with a crafting-table upgrade can
    -- serve it; OnCraft says so plainly rather than failing somewhere less obvious.
    Craft = {
        func = OnCraft,
    },
    -- Prospecting. The only job that can find ore nobody has scanned.
    Mine = {
        func = OnMine,
    },
    -- Anchor here and answer GPS pings, so a rescue party can extend coverage to a drone that has
    -- lost its position.
    Relay = {
        func = OnRelay,
    },
    -- Placing blocks: the difference between a fleet that accumulates chests and one that owns
    -- infrastructure.
    Build = {
        func = OnBuild,
    },
    Ping = {
        func = OnPing,
    },
    GoTo = {
        func = OnGoTo,
    },
    Survey = {
        func = OnSurvey,
    },
    Scan = {
        func = OnScan,
    },
    Rescue = {
        func = OnRescue,
    },
    -- Sent to the RESCUER, where Rescue above is sent to the casualty.
    Relieve = {
        func = OnRelieve,
    },
    -- The same idea past fuel: carry an item to a drone that is blocked without it.
    Handover = {
        func = OnHandover,
    },
    Unload = {
        func = OnUnload,
    },
    Probe = {
        func = OnProbe,
    },
    -- Yield the square. See AskToMakeWay: the commonest obstruction in this settlement is another
    -- drone, and until now nothing could either name it or ask it to move.
    MakeWay = {
        func = OnMakeWay,
    },
    Dig = {
        func = OnDig,
    },
    Haul = {
        func = OnHaul,
    },
    Lumber = {
        func = OnLumber,
    },
    Gather = {
        func = OnGather,
    },
    -- Ask for a berth and go and sit in it. The counterpart is not a verb: undocking happens by
    -- itself the moment the drone takes a job, because that is when it stops occupying the slot.
    Dock = {
        func = OnDock,
    }
}


local m_ServerEvents = { -- Runs on a different thread so that we can interrupt drones while they execute work on the Drone message thread.
    Abort = {
        func = OnAbort,
    },
    StartTask = {
        func = OnStartTask
    },
    AbortTask = {
        func = OnAbortTask
    },
}

if Init() == false then
    return
end


PowNet.RegisterEvents(m_ServerEvents, m_DroneEvents)

-- Make the heartbeat actually beat.
--
-- Init() sent exactly one, at boot, and nothing ever sent another -- so DroneMan's view of a
-- drone froze at the moment it registered. D1 sat docked at -95,83,-45 while the registry still
-- reported it at its spawn point, with the fuel level it had before it flew there. Position,
-- fuel and status were all write-once.
--
-- Safe to loop now only because SendHeartBeat no longer moves the turtle; see the note there.
-- Ship what this drone has seen to MapServer.
--
-- detectAll() has always recorded observations locally and MapServer has always had a handler to
-- merge them; the two were never connected, so the server's world was `{}` no matter how far the
-- fleet flew. This is the missing wire.
-- BATCH, DO NOT TRICKLE. MapServer is one single-threaded computer serving the whole fleet.
--
-- UploadWorld is called from NINE places -- after every scan column in a survey, after every job,
-- after every mining line -- so with a dozen drones running it produced a continuous drip of tiny
-- SaveWorld calls. Measured with `computercraft track`: MapServer handled 2,063 events in sixty
-- seconds, 12.6 SECONDS of CPU (21% of wall clock) and four times the event count of any other
-- module, while DroneMan and StorageMan sat at 0.4ms average doing nothing.
--
-- A CC computer answers one thing at a time, so a saturated MapServer stops answering its own
-- status poll and reads as DOWN -- which is what put MainFrame, DroneMan and MapServer all in the
-- alert at once, none of them actually broken. Drones saw the same saturation as "pathfinder did
-- not answer" 69 times in one window, and a drone that cannot path cannot work.
--
-- The observations themselves are cheap; the per-call overhead is not. Holding them for a few
-- seconds costs nothing -- the map does not care whether a block was reported now or twelve
-- seconds from now -- and it collapses many small calls into one larger one.
--
-- Nothing is dropped: takeWorldDelta is NOT called while throttled, so the delta stays queued in
-- pgps and rides out on the next permitted upload. p_Force exists for the paths that must flush
-- before the drone stops (job end, standing down), where a delay would mean losing them to a
-- reboot rather than merely postponing them.
local UPLOAD_MIN_GAP = 12
local m_LastUpload   = 0

function UploadWorld(p_Force)
    if not p_Force and (os.clock() - m_LastUpload) < UPLOAD_MIN_GAP then
        return true            -- still queued in pgps; not an error
    end
    local s_World, s_Detail, s_Count = pgps.takeWorldDelta()
    if(s_Count == 0) then
        m_LastUpload = os.clock()
        return true
    end
    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "SaveWorld",
        {cachedWorld = s_World, cachedWorldDetail = s_Detail})
    -- One attempt: observations are re-queued on failure (below), so a retry here only duplicates
    -- traffic against a MapServer that is already the busiest module in the fleet.
    local s_Ok = PowNet.sendAndWaitForResponse("MapServer", s_Message, PowNet.SERVER_PROTOCOL, 5, 1)
    if(not s_Ok) then
        -- Put them back rather than lose them: an unreachable MapServer should cost a retry, not
        -- a hole in the map that nothing will ever revisit.
        -- requeue, not noteObservation: these were verified when they were taken, and the gate in
        -- noteObservation would now discard them if our fix has lapsed in the meantime. A refused
        -- upload is a MapServer problem, not a position one.
        pgps.requeueObservations(s_World, s_Detail)
        Say("MapServer did not take " .. s_Count .. " observations, keeping them")
        return false
    end
    m_LastUpload = os.clock()
    Say("Uploaded " .. s_Count .. " observations")
    return true
end

-- REFUEL AT THE DOCK
--
-- A drone that runs dry stops wherever it is, which is usually the least convenient place, and
-- pgps cannot move it even one block to recover. Topping up while parked is the cheapest possible
-- insurance: the drone is already stationary and next to the tower.
--
-- It pulls from whatever container is adjacent rather than a configured position, so a fuel chest
-- can be moved or added without touching drone code. Charcoal works as well as coal, which is why
-- the tree farm doubles as the power plant.
local FUEL_LOW = 4000
-- What a drone tops itself up TO before it starts banking the surplus for everyone else. Well above
-- FUEL_RESERVE (600), so it never refuels itself into another emergency, and well below FUEL_LOW,
-- so there is something left over to carry to storage.
local FUEL_KEEP = 2500

function TryRefuel()
    local s_Level = turtle.getFuelLevel()
    if s_Level == "unlimited" then return false end
    if s_Level >= FUEL_LOW then return false end

    -- lua-hygiene: allow (collects delivered fuel lying in the world, not a chest)
    for _, suck in ipairs({turtle.suckDown, turtle.suckUp, turtle.suck}) do
        for _ = 1, 4 do
            if not suck(8) then break end
        end
    end

    -- BURN WHAT IS NEEDED. KEEP THE REST.
    --
    -- turtle.refuel() with no argument burns the WHOLE STACK, and this ran it on every slot
    -- whenever the drone was under FUEL_LOW -- which is 4,000, more than a drone normally holds. So
    -- the first miner to touch coal ate all of it, every time, and not one lump ever reached a
    -- chest. The fleet could mine coal indefinitely and never accumulate any: D3 gathered coal for
    -- an hour while storage stayed empty and two drones sat at zero, waiting for exactly that coal.
    --
    -- refuel(1) burns a single item, so the drone can stop the moment it has enough and carry the
    -- remainder home. A fuel economy needs a surplus, and a surplus needs somebody to stop eating.
    local s_Before = turtle.getFuelLevel()
    for i = 1, 16 do
        if turtle.getFuelLevel() >= FUEL_KEEP then break end
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            -- refuel(1) silently ignores anything that is not fuel, so this is safe to try on
            -- every slot rather than needing to identify fuel items first.
            while turtle.getItemCount(i) > 0 and turtle.getFuelLevel() < FUEL_KEEP do
                if not turtle.refuel(1) then break end   -- not fuel: leave the slot alone
            end
        end
    end
    turtle.select(1)
    local s_Gained = turtle.getFuelLevel() - s_Before
    if s_Gained > 0 then
        Say("refuelled +" .. s_Gained)
        return true
    end
    -- Nothing to burn and running low: say so, because a fleet quietly grinding to a halt for
    -- want of coal looks exactly like a fleet with nothing to do.
    --
    -- BUT "LOW" HAS TO MEAN "CANNOT WORK", NOT AN ARBITRARY FRACTION OF AN UNRELATED CONSTANT.
    --
    -- This fired below FUEL_LOW/4 -- a flat 1,000 chosen against nothing. Distress sets the drone's
    -- status to "stuck", and TaskMan's pickDrone only ever considers a drone reporting "idle", so
    -- raising it takes the drone out of service entirely. That turns a top-up that found no coal --
    -- an optimisation failing -- into a drone declaring itself broken.
    --
    -- Measured: D4 holding 944 fuel, at base, with a floor of ~310 and every job in the settlement
    -- affordable to it, raising this distress every fifteen seconds. All eight queued tasks sat
    -- unassigned because the only fuelled drone in the fleet had marked itself unusable. Nothing
    -- was wrong with it, and nothing in the log said "944 is fine" because nothing believed it.
    --
    -- FuelFloorNow IS the line. Below it the drone cannot be sure of getting home, which is the only
    -- honest definition of too low to work -- and it already collapses when storage is known dry, so
    -- this stops crying wolf during exactly the shortage it is meant to report.
    if s_Before < FuelFloorNow() then
        Distress("low fuel", "level " .. s_Before .. ", nothing to refuel with at the dock")
    end
    return false
end

-- GPS RELAY
--
-- A parked loader is the ideal GPS host: hosting needs only the modem, and the chunky upgrade
-- occupies the other slot anyway. So the same drone that keeps ground ticking also extends
-- positioning coverage -- which is what makes expansion a matter of flying a drone somewhere
-- rather than hand-building another constellation.
--
-- Two rules, both non-negotiable:
--   * only while STATIONARY. A moving host broadcasts stale coordinates and quietly corrupts
--     the fix of every drone that hears it -- far worse than no coverage at all.
--   * only from a fix we actually trust, i.e. one obtained from the existing constellation.
--     Hosting from dead-reckoned position compounds error outward.
--
-- Note four hosts are still required for a fix, so a lone relay does not create coverage by
-- itself; it adds to the pool, letting a drone combine two originals with two relays.
m_Hosting = false

-- Become a GPS host on command, whatever role this drone is.
--
-- The automatic relay only runs on loaders, which is right for standing coverage and useless for a
-- rescue: a fix needs FOUR hosts, so extending the constellation to somewhere it does not reach
-- takes a party, not one chunk loader. This lets every member of a rescue party anchor itself and
-- answer pings, which is the actual mechanism by which a stranded drone gets its position back.
function OnRelay(p_ID, p_Message)
    local d = p_Message.data or {}
    local s_Modem = peripheral.find("modem")
    if s_Modem == nil then return false, "no modem" end

    if d.on == false then
        pcall(s_Modem.close, gps.CHANNEL_GPS)
        m_Hosting, m_HostPos = false, nil
        return true, {hosting = false}
    end

    -- Anchor on a REAL fix before broadcasting. Publishing a dead-reckoned position would hand the
    -- casualty a confidently wrong fix, which is worse than no fix at all -- it would navigate on it.
    local fx, fy, fz = gps.locate(4, false)
    if fx == nil then
        return false, "cannot relay without a fix of my own"
    end
    s_Modem.open(gps.CHANNEL_GPS)
    m_Hosting = true
    m_HostPos = {x = fx, y = fy, z = fz}
    Say("relaying GPS at " .. fx .. "," .. fy .. "," .. fz)
    SendHeartBeat()
    return true, {hosting = true, pos = m_HostPos}
end

-- THE FLEET AS A MESH.
--
-- The constellation is four computers and a modem reaches 64 blocks below y=192, so GPS is a
-- 64-block bubble around the base -- and a drone needs FOUR hosts to fix at all. Every drone that
-- flies past that edge loses its position, and a drone with no position cannot navigate, so it
-- cannot get back. That is how two of them stranded.
--
-- But the fleet is already a set of machines with wireless modems that mostly know where they are.
-- Any drone parked with a confirmed fix can answer pings exactly as a host computer does, so
-- coverage stops being a fixed bubble and becomes something the fleet EXTENDS by being spread out.
-- A chain of parked drones reaches anywhere one of them can reach.
--
-- This was already written and limited to loaders, which is one drone. Every idle drone can do it.
--
-- THE THING THAT MUST NOT HAPPEN: a relay publishing a position it is not sure of. GPS has no way
-- to say "roughly" -- a host that answers with a wrong position hands every drone in range a
-- confidently wrong fix, and they will navigate on it. D4 is sitting 24 blocks from where it
-- believes it is right now; if it relayed that, it would corrupt the position of every drone that
-- trusted it. So a relay proves itself against a REAL fix before hosting, re-proves it on every
-- cycle, and stands down the instant it moves, drifts, or loses the fix.
local RELAY_DRIFT_LIMIT = 1     -- blocks; a host that has moved at all is no longer where it says

-- A PARKED RELAY repeats rednet traffic. A BUSY drone does not, and does not even listen.
--
-- rednet.send already copies every message to CHANNEL_REPEAT so anything in earshot can pass it on,
-- and that is genuinely how a drone past the 64-block modem range gets heard -- D8 sat at
-- -148,65,-33, powered on, running fine, and completely inaudible.
--
-- Getting the COST of this right took two failures worth recording, because both looked free:
--
--  1. Running it on every drone unconditionally. Fourteen drones rebroadcasting every message on
--     two channels turns one send into hundreds of modem_message events. CC's event queue is
--     finite, and what gets dropped on overflow is the rednet replies the JOB coroutine is waiting
--     for. The entire fleet froze -- reporting "mining" and "scanning", clocks ticking, relay loop
--     logging every ten seconds -- and moved zero blocks in sixty seconds, confirmed twice against
--     `computercraft dump`.
--  2. Gating it, but waking the loop on a 2-second timer to re-check the gate. That creates a timer
--     per received event, which fills the same queue with timers instead of messages. Movement went
--     from 35 blocks a minute to 1.
--
-- So: no timer, and the gate is enforced by whether the channel is OPEN at all -- gpsRelay opens it
-- when the drone parks as a relay and closes it when it stops. A busy drone is not handed these
-- events by the modem in the first place, which is the only version of "cheap" that survived
-- contact with the event queue.
local REPEAT_MEMORY = 30       -- seconds to remember a message id
local REPEAT_MAX_PER_SEC = 20  -- ceiling, so a storm cannot start even if the gate is ever wrong

-- THE FLEET AS A POSITION-AWARE MESH.
--
-- GPS solves the surface and nothing else: the constellation is above ground, a modem reaches ~64
-- blocks, and a drone at y=47 hears none of it. Everything downstream inherits that blind spot --
-- it cannot be heard, so it looks offline, so it gets "rescued" by a drone that has to tunnel to
-- it, so two drones are lost to one non-problem. Refusing to rescue deep drones (which I did first)
-- treats the symptom.
--
-- The fleet already has what it needs to fix it properly. Every drone tracks its own position by
-- dead reckoning once GPS is gone, and every drone is a radio. So:
--
--   * each drone beacons {id, position, whether that position is a REAL fix} to its neighbours;
--   * CC gives the distance to the sender on every wireless modem_message, so a drone that has lost
--     GPS can trilaterate from peers that still have real fixes -- the same maths the GPS
--     constellation uses, with drones as the satellites;
--   * a message that needs to reach the tower is handed to the neighbour CLOSER TO BASE, hop by
--     hop, instead of being shouted at a tower that cannot hear it.
--
-- Confidence is carried explicitly and never laundered: a position derived from peers is marked
-- derived, and a derived position is never offered as a trilateration anchor. That is the failure
-- that made GPS relaying unsafe (RELAY_DISABLED) -- a fix built on a fix built on a guess, with a
-- corroboration check that compares against the same polluted source. Anchors must be REAL fixes.
-- Where "toward the tower" points. The region centre is the settlement's own definition of home and
-- survives a reboot on disk, so a drone with no GPS and no contact still knows which way out is.
-- m_HomePos (the last deposit point) is the fallback, and the bare base coordinate the last resort.
function HomeXYZ()
    local c = pgps.centre and pgps.centre()
    if c and c.x then return c.x, c.y or 64, c.z end
    if m_HomePos and m_HomePos.x then return m_HomePos.x, m_HomePos.y or 64, m_HomePos.z end
    return -480, 64, 64
end

-- How often a peer-derived position may be adopted. A trilaterated fix is good to roughly ten
-- blocks, so taking one every beacon is no more accurate than dead reckoning between them -- and it
-- overwrites a climb in progress. See peerBeacon.
local PEER_FIX_EVERY = 60
local m_PeerFixAt    = nil

local PEER_CHANNEL   = 65100     -- distinct from GPS and rednet's own channels
local PEER_BEACON_S  = 8         -- how often to announce ourselves
-- How far a peer-derived position may miss its own anchors before it is thrown away.
--
-- A peer beacons its position every PEER_BEACON_S and may have moved since, so the anchor is stale
-- by up to a few blocks of travel -- that is honest noise. Twelve covers it with room to spare and
-- still rejects the 239-block answer that started this.
local TRILATERATION_TOLERANCE = 12
local PEER_STALE_S   = 45        -- a peer unheard this long is no longer a neighbour
local m_Peers        = {}        -- id -> {x,y,z, fix=bool, dist=number, at=clock}

-- Neighbours heard recently, nearest-to-base first. The routing table, such as it is.
local function peersByHomeward()
    local s_Now, s_Out = os.clock(), {}
    for id, p in pairs(m_Peers) do
        if (s_Now - p.at) <= PEER_STALE_S then s_Out[#s_Out + 1] = {id = id, p = p} end
    end
    local hx, hy, hz = HomeXYZ()
    table.sort(s_Out, function(a, b)
        local da = math.abs(a.p.x - hx) + math.abs(a.p.y - hy) + math.abs(a.p.z - hz)
        local db = math.abs(b.p.x - hx) + math.abs(b.p.y - hy) + math.abs(b.p.z - hz)
        return da < db
    end)
    return s_Out
end

-- Solve our own position from peers that have REAL fixes, using the distance CC reports with each
-- message. Three anchors pin a point in 3D up to a mirror; four remove the ambiguity, which is why
-- the vanilla constellation needs four and so do we.
-- Gaussian elimination on a 3x3, with partial pivoting. Small enough to write out.
--
-- Returns nil when the system is singular, which underground means the anchors are coplanar -- a
-- normal outcome, not an error: four drones strung along one tunnel cannot pin a point in space.
local function solve3x3(M, rhs)
    for col = 1, 3 do
        local piv, best = col, math.abs(M[col][col])
        for r = col + 1, 3 do
            if math.abs(M[r][col]) > best then piv, best = r, math.abs(M[r][col]) end
        end
        if best < 1e-6 then return nil end
        M[col], M[piv] = M[piv], M[col]
        rhs[col], rhs[piv] = rhs[piv], rhs[col]
        for r = col + 1, 3 do
            local f = M[r][col] / M[col][col]
            for c = col, 3 do M[r][c] = M[r][c] - f * M[col][c] end
            rhs[r] = rhs[r] - f * rhs[col]
        end
    end
    local s = {0, 0, 0}
    for r = 3, 1, -1 do
        local acc = rhs[r]
        for c = r + 1, 3 do acc = acc - M[r][c] * s[c] end
        s[r] = acc / M[r][r]
    end
    if s[1] ~= s[1] or s[2] ~= s[2] or s[3] ~= s[3] then return nil end   -- NaN guard
    return s
end

-- How badly a candidate position disagrees with the ranges it was derived from, worst anchor first.
-- Separate from the solver because "it solved" and "it is right" are unrelated statements, and only
-- the first was ever being checked.
local function anchorResidual(s, s_A)
    local s_Worst = 0
    for i = 1, #s_A do
        local a = s_A[i]
        local d = math.sqrt((s[1] - a.x) ^ 2 + (s[2] - a.y) ^ 2 + (s[3] - a.z) ^ 2)
        s_Worst = math.max(s_Worst, math.abs(d - a.dist))
    end
    return s_Worst
end

-- GLOBAL, so SurfaceForFix can reach it. It is defined far below that function, and a `local`
-- declared below its use is a nil GLOBAL lookup in Lua -- silent, and the branch simply never runs.
-- Calling a global function is safe here because the whole file loads before anything runs.
function TrilaterateFromPeers()
    local s_Now, s_A = os.clock(), {}
    for _, p in pairs(m_Peers) do
        if p.fix and p.dist and (s_Now - p.at) <= PEER_STALE_S then
            s_A[#s_A + 1] = p
            if #s_A >= 4 then break end
        end
    end
    if #s_A < 4 then return nil end

    -- Linearise: subtracting the first sphere's equation from the others leaves a linear system.
    local a1 = s_A[1]
    local M, rhs = {}, {}
    for i = 2, 4 do
        local ai = s_A[i]
        M[#M + 1] = {2 * (ai.x - a1.x), 2 * (ai.y - a1.y), 2 * (ai.z - a1.z)}
        rhs[#rhs + 1] = (a1.dist ^ 2 - ai.dist ^ 2)
                      + (ai.x ^ 2 - a1.x ^ 2) + (ai.y ^ 2 - a1.y ^ 2) + (ai.z ^ 2 - a1.z ^ 2)
    end

    local s = solve3x3(M, rhs)
    if s == nil then return nil end

    -- CHECK THE ANSWER AGAINST THE QUESTION. A LINEAR SOLVER ALWAYS RETURNS SOMETHING.
    --
    -- Linearising four spheres gives a 3x3 that has a solution for almost any input, including
    -- inputs that no point in space actually satisfies -- so "it solved" and "it is right" are
    -- unrelated statements, and only the first one was being checked. Measured against ground
    -- truth: two solutions landed within 15-38 blocks, and one put a drone at -257,14,40 while it
    -- was standing at -496,65,96. That is 239 blocks, and setLocation wrote it straight into the
    -- position cache, because a derived fix was trusted exactly as much as a computed one.
    --
    -- A WRONG FIX IS WORSE THAN NO FIX. No fix makes the drone hold still; a wrong one sends it
    -- somewhere with confidence -- which is the exact failure this whole recovery path exists to
    -- undo.
    --
    -- The residual is free to compute: put the solution back into each sphere and see whether the
    -- distances come out as measured. Peers move between beaconing and being heard, so some slack
    -- is real -- PEER_BEACON_S of travel, plus rounding -- but a solution that misses by more than
    -- that is not a noisy fix, it is a different point.
    local s_Worst = anchorResidual(s, s_A)
    if s_Worst > TRILATERATION_TOLERANCE then
        trace(("mesh: rejecting a peer fix that misses its own anchors by %d block(s)")
            :format(math.floor(s_Worst)))
        return nil
    end

    return math.floor(s[1] + 0.5), math.floor(s[2] + 0.5), math.floor(s[3] + 0.5), s_Worst
end

-- ASK THE NEIGHBOURS WHERE THEY ARE, RIGHT NOW.
--
-- Beacons arrive every PEER_BEACON_S, which is useless for measuring a single step. A ping gets a
-- reply carrying the responder's position, and CC attaches the EXACT euclidean distance to every
-- modem message -- so the reply is a precise range measurement, taken at a moment of our choosing.
-- That exactness is the whole reason this works: trilaterated positions are noisy to tens of
-- blocks, but the individual ranges are not noisy at all.
local function pingPeers(p_Nonce, p_WaitS)
    local s_Modem = peripheral.find("modem")
    if not s_Modem then return {} end
    pcall(s_Modem.open, PEER_CHANNEL)
    pcall(s_Modem.transmit, PEER_CHANNEL, PEER_CHANNEL,
          {ping = os.getComputerID(), nonce = p_Nonce})

    local s_Seen, s_Deadline = {}, os.clock() + (p_WaitS or 2)
    while os.clock() < s_Deadline do
        -- A timer, not a bare pullEvent: with no peers in earshot this would otherwise block for
        -- ever inside a loop that owns the drone, and CC kills a coroutine that goes 10s without
        -- yielding -- uncatchably.
        local s_Timer = os.startTimer(math.max(0.2, s_Deadline - os.clock()))
        local e, a, ch, _, msg, dist = os.pullEvent()
        if e == "timer" and a == s_Timer then break end
        if e == "modem_message" and ch == PEER_CHANNEL and type(msg) == "table"
           and msg.echo == p_Nonce and type(msg.x) == "number" and tonumber(dist) then
            s_Seen[tostring(msg.peer)] = {x = msg.x, y = msg.y, z = msg.z, dist = tonumber(dist)}
        end
    end
    return s_Seen
end

-- How well does each of the four headings explain the range changes we just measured?
--
-- Returns the best heading, its mean error, and the RUNNER-UP's -- the caller needs the gap, not
-- just the winner, because "north fits best" means nothing when west fits equally well.
--
-- Compares the CHANGE in range, never the absolute range. The change is what the step caused; the
-- absolute value is contaminated by however wrong our position is, and being wrong about position
-- is precisely the situation this runs in.
--
-- HEADINGS_(), not pgps's bare North/West/... -- those are globals inside the pgps API table, so an
-- unqualified `North` here is nil, and `[nil]` as a table key is a runtime error, not a quiet miss.
local function scoreHeadings(cx, cy, cz, p_Before, p_After)
    local H = HEADINGS_()
    local s_Deltas = {[H.north] = {0, 0, -1}, [H.west]  = {-1, 0, 0},
                      [H.south] = {0, 0, 1},  [H.east]  = {1, 0, 0}}
    local s_Best, s_BestErr, s_NextErr = nil, nil, nil
    for dir, v in pairs(s_Deltas) do
        local s_Err, s_Used = 0, 0
        for id, b in pairs(p_Before) do
            local a = p_After[id]
            if a then
                local d0p = math.sqrt((cx - b.x) ^ 2 + (cy - b.y) ^ 2 + (cz - b.z) ^ 2)
                local d1 = math.sqrt((cx + v[1] - b.x) ^ 2 + (cy + v[2] - b.y) ^ 2
                                   + (cz + v[3] - b.z) ^ 2)
                s_Err = s_Err + math.abs((a.dist - b.dist) - (d1 - d0p))
                s_Used = s_Used + 1
            end
        end
        if s_Used > 0 then
            s_Err = s_Err / s_Used
            if s_BestErr == nil or s_Err < s_BestErr then
                s_Best, s_NextErr, s_BestErr = dir, s_BestErr, s_Err
            elseif s_NextErr == nil or s_Err < s_NextErr then
                s_NextErr = s_Err
            end
        end
    end
    return s_Best, s_BestErr, s_NextErr
end

-- WHICH WAY ARE WE ACTUALLY FACING? ASK THE FLEET, NOT THE SKY.
--
-- A wrong heading is the single most destructive state a drone can be in, and it is the one thing
-- GPS cannot fix: verifyPosition repairs WHERE you are and says nothing about which way you point,
-- so a drone kept walking backwards while being politely corrected every time it surfaced. Proven
-- in the log -- "HEADING WAS WRONG: we thought 0, we actually face 2" is a full 180 degrees.
--
-- It also survives restarts, which is worse. loadPose() restores cachedDir off disk and
-- ensureHeading returns early whenever cachedDir is set, so a heading that was wrong when the
-- server went down is still wrong afterwards, for ever, and nothing ever asks again.
--
-- The trick: step one block and watch how the range to each neighbour changes. Stepping toward a
-- peer shortens the range by almost exactly one; stepping away lengthens it by one; stepping across
-- barely changes it. Four candidate headings predict four different sets of changes, and with peers
-- spread around the settlement the right one wins clearly. No GPS involved at any point -- only the
-- distances the modem hands us for free.
--
-- Needs a roughly-correct POSITION to predict bearings from, which is the normal case: position is
-- what GPS keeps repairing, heading is what nothing did.
local HEADING_MARGIN = 0.6      -- how much the best candidate must beat the runner-up by
function HeadingFromPeers()
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return nil end

    local s_Nonce = tostring(os.getComputerID()) .. ":" .. tostring(os.clock())
    local s_Before = pingPeers(s_Nonce, 2)
    local n = 0
    for _ in pairs(s_Before) do n = n + 1 end
    if n < 2 then return nil end            -- one range cannot distinguish four directions

    -- Step, measure, step back. Raw moves, because pgps.forward() would apply the very heading we
    -- are trying to check -- and it is put back exactly as ensureHeading does it, with the return
    -- move CHECKED, because an unchecked back() is what started this whole class of bug.
    -- lua-hygiene: allow (this step is CANCELLED by the turtle.back() below, so the net
    -- displacement is zero and there is nothing to report. The case where the return move fails is
    -- the case that moved us, and that branch calls noteExternalStep.)
    local s_Fwd = turtle.forward()
    if not s_Fwd then return nil end
    local s_After = pingPeers(s_Nonce .. "b", 2)
    local s_Back, s_BackErr = turtle.back()
    if not s_Back then
        -- We are one block forward of where the caller thinks. Say so, WITH the reason, and let the
        -- position layer deal with it rather than silently carrying an error -- an unchecked back()
        -- in exactly this shape is what drifted the fleet in the first place.
        trace(("heading probe could not step back (%s) -- we are one block forward of the cache")
            :format(tostring(s_BackErr)))
        -- Saying it in the log is not the same as recording it. The drone really is one block
        -- forward; put that in the position layer so the next fix does not read it as drift.
        -- cachedDir may be the wrong heading -- that is what this probe is testing -- but the
        -- audit's job is to compare INTENT against reality, and this is honestly our intent.
        local hx, hy, hz = pgps.headingDelta()
        if hx then pgps.noteExternalStep(hx, hy, hz) end
    end

    local s_Best, s_BestErr, s_NextErr = scoreHeadings(cx, cy, cz, s_Before, s_After)

    -- AMBIGUOUS IS NOT AN ANSWER. Peers all off one side, or all far away, make several headings
    -- look equally good -- and adopting a coin-flip heading is exactly the failure being fixed.
    if s_Best == nil or s_NextErr == nil then return nil end
    if (s_NextErr - s_BestErr) < HEADING_MARGIN then
        trace(("heading from peers was ambiguous (%.2f vs %.2f) -- not guessing")
            :format(s_BestErr, s_NextErr))
        return nil
    end
    return s_Best, s_BestErr
end

-- Announce ourselves, and adopt a peer-derived position when GPS has nothing to offer.
local function peerBeacon()
    local s_Modem = peripheral.find("modem")
    if not s_Modem then return end
    pcall(s_Modem.open, PEER_CHANNEL)

    while true do
        os.sleep(PEER_BEACON_S)
        local x, y, z = pgps.getCachedPosition()
        -- `fix` is the honest part: true only when GPS itself confirmed us recently. Peers use it to
        -- decide whether we are safe to trilaterate against.
        local s_Fix = pgps.positionVerified and pgps.positionVerified() or false
        if x ~= nil then
            pcall(s_Modem.transmit, PEER_CHANNEL, PEER_CHANNEL, {
                peer = os.getComputerID(), x = x, y = y, z = z, fix = s_Fix and true or false,
            })
        end

        -- A WRONG POSITION IS NOT BETTER THAN NO POSITION, AND THIS ONLY HELPED THE SECOND CASE.
        --
        -- The trilateration ran only when the cache was nil -- so the drones that needed it most
        -- never got it. A drone deep in a cave has a position: the one it dead-reckoned on the way
        -- in, quietly wrong by however much it has drifted since. Five of them were out by 20 to 71
        -- blocks, still confident, and this branch sat unreachable behind an `else` the whole time
        -- while their beacons were being relayed home by the very peers that could have fixed them.
        --
        -- Unverified is the condition to act on, not absent.
        -- DO NOT FIGHT A MOVE IN PROGRESS.
        --
        -- This runs every PEER_BEACON_S and writes straight into the position cache, so a drone that
        -- is climbing gets reset to where the mesh last saw it -- every eight seconds, for ever.
        -- Caught in the log: "rose 129 block(s) to y=22". It really did climb a hundred and
        -- twenty-nine blocks; the beacon loop kept putting it back, and it burned the fuel again on
        -- the next attempt. A peer fix is worth having when the drone is LOST, and actively harmful
        -- while it is busy getting itself un-lost.
        --
        -- Two guards. Not while a job owns movement, and not more than once a minute -- a
        -- trilaterated position is good to about ten blocks, so re-adopting it constantly buys
        -- nothing and costs the dead reckoning that is more accurate between fixes.
        local s_Now = os.clock()
        if not s_Fix and not executing
           and (m_PeerFixAt == nil or (s_Now - m_PeerFixAt) > PEER_FIX_EVERY) then
            local tx, ty, tz, terr = TrilaterateFromPeers()
            if tx then
                m_PeerFixAt = s_Now
                trace(("mesh: no GPS fix -- the fleet places us at %d,%d,%d (anchors agree to %d)")
                    :format(tx, ty, tz, math.floor(terr or 0)))
                pcall(pgps.setLocation, tx, ty, tz, nil)
            end
        end
    end
end

-- ANSWER A PING AT ONCE.
--
-- Beacons go out every PEER_BEACON_S, which is far too slow to measure a single step against -- and
-- the step is the whole experiment. A ping/echo pair gives the asker a range measured NOW, on both
-- sides of one block of movement, which is what makes heading recoverable without GPS.
local function answerPing(p_Modem, p_Msg)
    if type(p_Msg) ~= "table" or not p_Msg.ping then return end
    if p_Msg.ping == os.getComputerID() then return end
    local px, py, pz = pgps.getCachedPosition()
    if px == nil then return end
    local s_Fix = pgps.positionVerified and pgps.positionVerified() or false
    pcall(p_Modem.transmit, PEER_CHANNEL, PEER_CHANNEL, {
        peer = os.getComputerID(), x = px, y = py, z = pz,
        fix = s_Fix and true or false, echo = p_Msg.nonce,
    })
end

-- Receive beacons and keep the neighbour table. Separate from the repeater so a burst of relay
-- traffic cannot starve our picture of who is nearby.
local function peerListen()
    local s_Modem = peripheral.find("modem")
    if not s_Modem then return end
    pcall(s_Modem.open, PEER_CHANNEL)

    while true do
        local _, _, s_Ch, _, s_Msg, s_Dist = os.pullEvent("modem_message")
        if s_Ch == PEER_CHANNEL then answerPing(s_Modem, s_Msg) end
        if s_Ch == PEER_CHANNEL and type(s_Msg) == "table" and s_Msg.peer
           and s_Msg.peer ~= os.getComputerID() and type(s_Msg.x) == "number" then
            m_Peers[tostring(s_Msg.peer)] = {
                x = s_Msg.x, y = s_Msg.y, z = s_Msg.z,
                fix = s_Msg.fix == true,
                -- Distance is what makes the peers usable as anchors. Wireless modems report it;
                -- wired ones do not, and a nil distance simply makes this peer routing-only.
                dist = tonumber(s_Dist),
                at = os.clock(),
            }
        end
    end
end

-- POINT-TO-POINT FORWARDING TOWARD THE TOWER.
--
-- One addressed hop at a time, never a broadcast: the drone picks the single neighbour closest to
-- base and sends to it, that neighbour repeats the decision, and the chain walks itself out of the
-- ground. Traffic is proportional to the LENGTH OF THE CHAIN, not to the size of the fleet, which
-- is the difference between a mesh and a storm.
--
-- Loop safety without flooding: every forwarded envelope carries the id of the drone that
-- originated it and a hop budget. A drone refuses to forward a message it has already seen, refuses
-- to send it back to where it came from, and drops it when the budget runs out.
local MESH_MAX_HOPS  = 6
local MESH_SEEN_S    = 30
local m_MeshSeen     = {}        -- envelope id -> expiry

-- GLOBAL, deliberately: SendHeartBeat calls this and lives four thousand lines above it. A `local`
-- here would be a nil global at that call site -- silently, which is this codebase's most expensive
-- recurring mistake and the reason hq/test/lua-hygiene.test.ts exists.
function MeshReady()
    for _, p in pairs(m_Peers) do
        if (os.clock() - p.at) <= PEER_STALE_S then return true end
    end
    return false
end

function meshForward(p_Envelope, p_FromId)
    local s_Now = os.clock()
    for k, v in pairs(m_MeshSeen) do if v < s_Now then m_MeshSeen[k] = nil end end
    if p_Envelope.eid and m_MeshSeen[p_Envelope.eid] then return false end
    if p_Envelope.eid then m_MeshSeen[p_Envelope.eid] = s_Now + MESH_SEEN_S end

    p_Envelope.hops = (tonumber(p_Envelope.hops) or 0) + 1
    if p_Envelope.hops > MESH_MAX_HOPS then
        trace("mesh: hop budget exhausted -- dropping")
        return false
    end

    -- Are we close enough to just deliver it ourselves? If the tower answers us, the chain ends here.
    local s_Direct = PowNet.SendToServer(p_Envelope.to or "DroneMan", p_Envelope.msg)
    if s_Direct then return true end

    local hx, hy, hz = HomeXYZ()
    local cx, cy, cz = pgps.getCachedPosition()
    local s_Mine = cx and (math.abs(cx - hx) + math.abs(cy - hy) + math.abs(cz - hz)) or math.huge

    local s_Modem = peripheral.find("modem")
    if not s_Modem then return false end

    for _, e in ipairs(peersByHomeward()) do
        local d = math.abs(e.p.x - hx) + math.abs(e.p.y - hy) + math.abs(e.p.z - hz)
        -- Strictly closer to base than us, and not the peer that just handed it to us. Both
        -- conditions are what stop two drones passing the same message back and forth for ever.
        if d < s_Mine and tostring(e.id) ~= tostring(p_FromId) then
            pcall(s_Modem.transmit, PEER_CHANNEL, PEER_CHANNEL,
                  {relay = true, dest = e.id, from = os.getComputerID(), env = p_Envelope})
            trace(("mesh: forwarded via peer %s (%d blocks from base, we are %d)")
                :format(tostring(e.id), d, s_Mine))
            return true
        end
    end
    return false
end

-- Accept a forwarded envelope addressed to us and carry it one hop further.
local function meshRelayListen()
    local s_Modem = peripheral.find("modem")
    if not s_Modem then return end
    pcall(s_Modem.open, PEER_CHANNEL)

    while true do
        local _, _, s_Ch, _, s_Msg = os.pullEvent("modem_message")
        if s_Ch == PEER_CHANNEL and type(s_Msg) == "table" and s_Msg.relay
           and tostring(s_Msg.dest) == tostring(os.getComputerID())
           and type(s_Msg.env) == "table" then
            meshForward(s_Msg.env, s_Msg.from)
        end
    end
end

local function meshRepeat()
    local s_Modem = peripheral.find("modem")
    if not s_Modem then return end

    -- OPEN THE CHANNEL, OR NONE OF THIS RUNS.
    --
    -- CHANNEL_REPEAT was opened in exactly one place: inside gpsRelay, which returns immediately
    -- because GPS relaying is disabled. So the modem was never listening on it and this loop sat on
    -- an event that could not arrive -- the relay was dead twice over, once by the m_Hosting gate
    -- and once by a channel nobody opened. Opening it here ties the channel to the thing that
    -- actually uses it.
    pcall(s_Modem.open, rednet.CHANNEL_REPEAT)

    local s_Seen = {}
    local s_Window, s_Count = 0, 0

    while true do
        local _, _, s_Channel, s_Reply, s_Message = os.pullEvent("modem_message")

        -- BROADCAST REPEATING STAYS OFF. THIS IS NOT THE MESH.
        --
        -- I briefly ungated this so every drone rebroadcast every repeatable packet, which is a
        -- flood: seventeen radios amplifying each other, and the dedupe only bounds the loop, not
        -- the volume. That approach has already been tried here and it storms.
        --
        -- The mesh below is point-to-point instead: a drone that cannot reach the tower picks ONE
        -- neighbour closer to base and sends to it directly. Each hop is a single addressed message,
        -- so traffic grows with the length of the chain rather than with the size of the fleet.
        if s_Channel == rednet.CHANNEL_REPEAT and m_Hosting and not executing
           and type(s_Message) == "table"
           and s_Message.nMessageID and type(s_Message.nRecipient) == "number" then

            local s_Now = os.clock()
            if s_Now - s_Window >= 1 then s_Window, s_Count = s_Now, 0 end

            if s_Count < REPEAT_MAX_PER_SEC and not s_Seen[s_Message.nMessageID] then
                for k, v in pairs(s_Seen) do
                    if v < s_Now then s_Seen[k] = nil end
                end
                s_Seen[s_Message.nMessageID] = s_Now + REPEAT_MEMORY
                s_Count = s_Count + 1

                -- A computer id is not a channel; rednet.send maps one to the other, and a repeater
                -- that skips the mapping transmits where nobody is listening.
                local s_Ch = s_Message.nRecipient
                if s_Ch ~= rednet.CHANNEL_BROADCAST then s_Ch = s_Ch % rednet.MAX_ID_CHANNELS end
                pcall(s_Modem.transmit, s_Ch, s_Reply, s_Message)
                pcall(s_Modem.transmit, rednet.CHANNEL_REPEAT, s_Reply, s_Message)
            end
        end
    end
end

-- SCAN WHILE TRAVELLING, NOT ONLY ON ARRIVAL.
--
-- A scout crossing forty blocks to reach its survey site learned nothing on the way: the scanner
-- only ran at the grid points of a Survey job, so every recall, reposition and rescue flight was
-- dead mileage over unmapped ground. The trip is already being paid for and the scanner is already
-- fitted, and the unmapped ground between two places is exactly what makes the next path search
-- fail.
--
-- Fires on DISTANCE, not on a timer: a parked drone rescans nothing and a fast one skips nothing.
local SCAN_EVERY = 12          -- blocks travelled between opportunistic scans

local function scanOnTheMove()
    local s_LastX, s_LastY, s_LastZ

    while true do
        os.sleep(2)

        local s_Sc = Scanner()
        if s_Sc and m_Status ~= "scanning" then
            local cx, cy, cz = pgps.getCachedPosition()
            if cx ~= nil then
                if s_LastX == nil then
                    s_LastX, s_LastY, s_LastZ = cx, cy, cz
                else
                    local s_Moved = math.abs(cx - s_LastX) + math.abs(cy - s_LastY)
                                  + math.abs(cz - s_LastZ)
                    if s_Moved >= SCAN_EVERY then
                        s_LastX, s_LastY, s_LastZ = cx, cy, cz
                        -- pcall: the scanner shares a cooldown with the survey job and a refusal
                        -- here is routine. It must never take the drone down.
                        pcall(absorbScan, s_Sc, 8)
                    end
                end
            end
        end
    end
end

-- KEEP TRYING TO FIND OURSELVES, on our own thread.
--
-- A drone with no cached position cannot move at all -- mayStep refuses every step without one --
-- so it cannot travel somewhere with better reception, and with no job running nothing calls
-- verifyPosition either. Left alone it sits for ever, inside perfectly good coverage, reporting
-- that it does not know where it is.
--
-- On its own coroutine because gps.locate BLOCKS for its full timeout when it fails, and anything
-- sharing a thread with it inherits that delay. Rate-limited because a drone genuinely out of range
-- would otherwise spend its entire life in gps.locate.
local REFIX_EVERY = 45

-- A LOST DRONE MUST CLIMB, NOT JUST ASK AGAIN.
--
-- This retried gps.locate on a timer and never moved. Underground that can only ever fail: every
-- host is above the surface, and no amount of asking from y=48 reaches four of them. So a drone that
-- lost its fix down a shaft -- or simply REBOOTED down one, which happens on every code deploy --
-- sat re-asking for ever, reporting "no position fix (re-fix attempted and failed)" and unable to
-- move at all, because every movement path needs a position first.
--
-- Digging out is the answer, and the drone is usually holding the tool for it. Climb a block at a
-- time and ask again after each. Raw turtle calls rather than pgps ones on purpose: pgps movement
-- wants a known position, which is precisely what is missing.
-- EIGHTY BLOCKS WAS NEVER A SEARCH, IT WAS A FLIGHT.
--
-- Reported from the world, three drones at once: "D3 is 13 blocks above the surveyed ground",
-- "D14 is 22 blocks above", "D17 is 63 blocks above -- climbing, not surveying?". That is exactly
-- what it was: a fix-recovery climb with an eighty-block budget, spending a fuel per block and
-- leaving the ground it was supposed to be working.
--
-- The absolute ceiling added earlier (SKY_FIX_CEILING) does not catch this, because a drone
-- starting at y=70 can rise sixty-three blocks and still sit under 140. The binding limit has to be
-- how far it climbs, not how high it ends up.
--
-- Twenty-four is chosen from the constellation, not by feel: the GPS hosts sit at y=70..99, and a
-- drone that cannot hear four of them after rising twenty-four blocks is not going to hear them at
-- eighty -- it is out of RANGE, not under a ceiling, and more altitude cannot fix range. Past that
-- point the climb stops being a search and becomes the reason the drone is stranded: it is further
-- from home, higher than the region it may work in, and burning the fuel it needs to get back.
local RECOVERY_CLIMB = 24

local function climbForFix()
    for i = 1, RECOVERY_CLIMB do
        if turtle.detectUp() then
            local ok, blk = turtle.inspectUp()
            if ok and blk and pgps.isProtectedBlock(blk.name) then
                trace("refix: something of ours overhead -- not digging through it")
                return false
            end
            if not turtle.digUp() then
                trace(("refix: blocked overhead after %d blocks"):format(i - 1))
                return false
            end
        end
        -- STOP AT THE CEILING. Raw turtle.up() bypasses mayStep, so nothing else bounds this.
        --
        -- SKY_FIX_CEILING existed but only climbForFixIfAffordable ever consulted it -- this loop,
        -- the one that actually runs when a drone has lost its fix, would climb RECOVERY_CLIMB=80
        -- blocks from wherever it started with no altitude limit at all. Found live: D8 at y=182,
        -- forty-two blocks above the ceiling, a hundred blocks from a base whose operating circle
        -- is fifty-six, holding fuel and labour the settlement could not reach.
        --
        -- Above the ceiling another block buys nothing: GPS range stops improving, the drone is
        -- leaving the region it is allowed to work in, and every block costs fuel it will need to
        -- get home. cachedY is dead-reckoned but noteExternalStep below keeps it honest during the
        -- climb, which is exactly what makes this check possible.
        local _, s_Cy = pgps.getCachedPosition()
        if s_Cy ~= nil and s_Cy >= SKY_FIX_CEILING then
            trace(("refix: at y=%d, the ceiling -- climbing further will not find GPS"):format(s_Cy))
            return false
        end
        local s_Up, s_UpErr = turtle.up()
        if not s_Up then
            -- Name the cause. "could not rise" reads as terrain and sent everyone looking for a
            -- ceiling; "Cannot enter protected area" is a server setting and no climb will fix it.
            trace(("refix: could not rise after %d blocks%s"):format(
                i - 1, s_UpErr and (" -- " .. tostring(s_UpErr)) or ""))
            return false
        end
        -- The climb is real; the position layer has to hear about it. verifyPosition below fails on
        -- every pass here -- no fix is the whole reason we are climbing -- so without this the
        -- entire ascent stayed invisible and surfaced later as phantom drift. See noteExternalStep.
        pgps.noteExternalStep(0, 1, 0)
        if pgps.verifyPosition(true) then          -- just climbed: the old failure is out of date
            trace(("refix: regained a position after climbing %d"):format(i))
            return true
        end
    end
    trace(("refix: climbed %d and still no fix"):format(RECOVERY_CLIMB))
    return false
end

-- WALK HOME IF YOU END UP OUTSIDE.
--
-- Movement only happens while a job is running, and a drone outside the operating region is never
-- given a job -- so nothing ever moved it back. D3 sat at x=-412, twelve blocks past the edge,
-- heartbeating perfectly, holding a valid position, for an hour. Every individual part was working:
-- it knew where it was, it could be heard, it simply had no reason to move and no way to be given
-- one.
--
-- mayStep already permits steps that reduce the distance outside; this is the thing that decides to
-- take them.
local function returnToRegion()
    local px, py, pz = pgps.getCachedPosition()
    if px == nil then return false end
    local s_B = pgps.getBounds()
    local s_C = s_B and s_B.chunks
    if type(s_C) ~= "table" or #s_C == 0 then return false end

    -- Nearest point inside the first region, clamped per axis.
    local r = s_C[1]
    local tx = math.max(r.minx + 2, math.min(r.maxx - 2, px))
    local tz = math.max(r.minz + 2, math.min(r.maxz - 2, pz))
    if tx == px and tz == pz then return false end          -- already inside

    trace(("outside the region at %d,%d,%d -- returning to %d,%d"):format(px, py, pz, tx, tz))
    m_Status = "moving"

    -- CHECK WHICH WAY YOU ARE FACING BEFORE WALKING HOME.
    --
    -- Every movement primitive resolves "west" through cachedDir, so a stale or wrong heading turns
    -- a return into a departure -- and this is the one code path where that is unrecoverable,
    -- because it runs when the drone is ALREADY outside radio range and nobody can correct it.
    -- D6 announced "outside the region at -412,63,60 -- returning to -426,60" and was next seen at
    -- -402: ten blocks the wrong way, 78 from base, silent. D1 and D2 were lost exactly like this.
    --
    -- Re-deriving costs one step out and back, and it is the cheapest insurance the fleet has: the
    -- alternative is a drone walking confidently over the horizon.
    pgps.verifyPosition(true)
    local s_Hdg, s_HdgWhy = pgps.ensureHeading()
    if not s_Hdg then
        trace(("return: cannot establish heading (%s) -- refusing to walk blind"):format(tostring(s_HdgWhy)))
        Distress("outside the region with no heading", ("at %d,%d,%d"):format(px, py, pz))
        m_Status = "idle"
        return false
    end
    px, py, pz = pgps.getCachedPosition()
    if px == nil then m_Status = "idle" return false end

    local ok = pgps.moveTo(tx, py, tz)
    if ok == false then ok = pgps.flyTo(tx, py, tz) end
    if ok == false and CanDig() then ok = pgps.digTo(tx, py, tz) end
    m_Status = "idle"
    if ok ~= false then trace("back inside the region") return true end
    trace("could not get back inside the region")
    return false
end

-- A FUEL FLOOR THAT COVERS EVERY JOB, NOT JUST MINING.
--
-- The reserve check lived in depositIfFull, which only the mine loop calls -- so a scout on an
-- explore and a miner on a gather still ran themselves to zero. Two of three drones were sitting at
-- fuel 0, both reporting "working". At zero a drone cannot move, cannot reach the barrel the fuel is
-- in, and can only be recovered by another drone digging to it.
--
-- A watchdog is the right shape because it does not care what the drone is doing: burn anything
-- carried, and if that is not enough, stop the job and dock while there is still fuel to get there.
-- Aborting a job costs one dispatch. Running dry costs the drone.
local FUEL_WATCH_EVERY = 20

-- TAKE FUEL FROM THE PLACE FUEL ACTUALLY IS.
--
-- TryRefuel can only burn what the drone is already carrying, and dockNow only parks it. Neither
-- puts fuel INTO a drone that has none, so the whole refuelling path came down to "hope it is
-- holding coal". For a miner that is often true. For a SCOUT it never is: it carries a geo scanner
-- where a pickaxe would go, mines nothing, burns fuel flying to survey sites, and has no way
-- whatsoever to top up. D2 crossed below the reserve, the watchdog fired correctly, and there was
-- simply nothing for it to do about it -- it went on flying at 457 fuel and falling, heading for a
-- dead stop somewhere out in the world where a rescue party carrying loaders, relays and a pickaxe
-- would not have helped either, because none of them carry fuel.
--
-- The miners already deposit coal into the storage chest, so that chest IS the fleet's fuel depot.
-- Standing on it and sucking is the same manoeuvre Deposit already makes, in reverse.
-- A GLOBAL, because depositIfFull is defined ~1,800 lines above this and needs it. A `local
-- function` here is invisible up there -- the trap that has cost this codebase seven outages.
function RefuelAtStorage()
    trace("refuel: heading to storage")
    local s_Res = PowNet.sendAndWaitForResponse("StorageMan",
        PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, "DepositPoint", {}), PowNet.SERVER_PROTOCOL)
    if type(s_Res) == "table" and s_Res.pos ~= nil then m_HomePos = s_Res.pos end
    -- THE SIXTH COPY OF "LOOK FOR THE COAL WHERE THE COAL IS".
    --
    -- CollectFuel carries that fix. This function never got it, and it is the one every drone uses
    -- to feed ITSELF. It asked StorageMan for the DEPOSIT point -- the chest with the most FREE
    -- SPACE, so by construction the one least likely to hold what we came for -- flew there, sucked
    -- at it, and reported "storage had nothing burnable". D19 did exactly that five blocks from the
    -- bay while 563 coal sat in the other five chests: it ran itself to zero making the trip, then
    -- logged "MOVE REFUSED: Out of fuel" 113 times in a single minute. Three more drones went the
    -- same way within the hour, and the settlement starved on top of a full larder.
    --
    -- The deposit point is still worth asking for, but ONLY to keep m_HomePos fresh -- FuelFloorNow
    -- scales the reserve by the distance to it. The withdrawal itself goes through the primitive
    -- that asks where the coal actually is and sweeps the other chests when the answer is wrong.
    m_Status = "hauling"
    SendHeartBeat()

    local s_Before = turtle.getFuelLevel()
    local s_Got, s_Why = CollectFuel()
    pcall(TryRefuel)

    local s_Gained = turtle.getFuelLevel() - s_Before
    trace(("refuel at storage: %+d fuel (now %d, collected %d)")
        :format(s_Gained, turtle.getFuelLevel(), s_Got or 0))
    if s_Gained <= 0 then
        -- REMEMBER THAT THE LARDER WAS EMPTY.
        --
        -- Without this the drone breaks off work again the moment it drops below its floor, walks
        -- back to the same empty chests, finds nothing, and repeats -- and every other drone is
        -- doing it at the same time. Seven of them converged on the bay, which is the most
        -- congested airspace in the settlement, and gridlocked it: a gather logged "short hop of 1
        -- failed direct" and took 264 SECONDS to attempt a single candidate before giving up.
        --
        -- That is a deadlock, not a shortage. Storage is empty because nobody is gathering, and
        -- nobody is gathering because they are all queuing for fuel that does not exist. The tanks
        -- were not even low -- 2,300 to 5,300 each -- they were merely under a distance-scaled
        -- floor of ~1,038.
        m_StorageDryAt = os.clock()
        Distress("no fuel in storage",
            "level " .. turtle.getFuelLevel() .. ", " .. tostring(s_Why or "storage had nothing burnable"))
        return false
    end
    m_StorageDryAt = nil
    return true
end

-- AN IDLE DRONE BELONGS ON A DOCK, NOT WHEREVER IT HAPPENED TO STOP.
--
-- A drone that finishes a job just stands there, and where it stops is usually somewhere it was
-- working -- which is exactly where the next drone needs to be. D4 finished a craft and parked on
-- -476,65,78: the single block a drone must stand on to reach the deposit chest. D3 arrived with
-- sixteen logs, could not take the spot, and the whole build chain stalled behind a drone doing
-- nothing at all.
--
-- Docking is safe to interrupt and needs no special handling: RunJob calls undock() the moment a
-- job is accepted, and `executing` stays false while parked, so a docked drone is fully available.
-- The worst case is a short walk back out, which is much cheaper than blocking the storage point.
--
-- Only when there is fuel to spare: a drone below its floor has a more urgent errand, and the fuel
-- watchdog owns it.
local IDLE_BEFORE_DOCK = 45

-- THE ACCESS SQUARE IS A COLUMN, NOT A BLOCK.
--
-- The old check was ContainerBelow() alone, so a drone hovering three blocks above a chest never
-- moved -- and it blocks the approach just as completely, because everything arriving at that chest
-- has to come down through it.
--
-- Counted in the bay: six idle drones stacked at y=65..68 over the four chests at y=64. Every
-- deposit and every build pickup failed with "could not reach the pickup chest", the tower never
-- placed a block, and drones burned their fuel flying back and forth retrying until they went dry.
-- They were queueing for the thing they were standing on.
--
-- Vacating deliberately does NOT need DockingMan. It has been down for a day, so idle drones have
-- no berth to go to -- which is precisely when they must not be occupying the storage column.
local function inStorageColumn()
    if ContainerBelow() then return true end
    if not (m_HomePos and m_HomePos.x) then return false end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil or cy == nil then return false end
    if math.abs(cx - m_HomePos.x) > 1 or math.abs(cz - m_HomePos.z) > 1 then return false end
    return cy > m_HomePos.y and (cy - m_HomePos.y) <= 8
end

local function idleDockLoop()
    local s_IdleSince = nil
    while true do
        os.sleep(15)

        -- NEVER REST ON A CONTAINER. THE ACCESS SQUARE IS NOT A PARKING SPACE.
        --
        -- Stepping off at the end of a job is not enough, because a drone does not have to finish a
        -- job to end up sitting on a chest: it can be idle, it can be waiting for work, or it can be
        -- stuck in "docking" after a failed dock attempt -- and none of those paths ever move it.
        -- D3 sat on the bay's busiest chest reporting "docking" while doing nothing at all, and
        -- every drone that needed that chest queued behind it.
        --
        -- Checked continuously rather than at a transition, because the wrong state is the thing
        -- that matters, not how it was reached. Guarded on `executing` so a drone legitimately
        -- working a chest is left alone.
        -- Somebody asked us to move. This loop owns movement while nothing else does, so it is a
        -- safe point; doing it in the handler that received the request is what hung the fleet.
        if m_YieldAt ~= nil and (not executing) and (not m_Refuelling) then
            local y = m_YieldAt
            m_YieldAt = nil
            local cx, cy, cz = pgps.getCachedPosition()
            if cx ~= nil and math.abs(cx - y.x) <= 1 and math.abs(cy - y.y) <= 1
               and math.abs(cz - y.z) <= 1 then
                trace(("making way from %d,%d,%d"):format(cx, cy, cz))
                for _ = 1, 4 do
                    if pgps.forward() then break end
                    pgps.turnRight()
                end
            end
        end

        -- THE ACCESS SQUARE IS A COLUMN, NOT A BLOCK.
        --
        -- This only fired when a container was directly underneath, so a drone hovering three
        -- blocks above a chest never moved -- and it blocks the approach just as completely, because
        -- everything arriving at that chest has to come down through it.
        --
        -- Counted in the bay: six idle drones stacked at y=65..68 over the four chests at y=64.
        -- Every deposit and every build pickup failed with "could not reach the pickup chest", the
        -- tower never placed a block, and drones burned their fuel flying back and forth retrying
        -- until they went dry. They were queueing for the thing they were standing on.
        --
        -- Vacating does not need DockingMan. It has been down for a day, so idle drones have no
        -- berth to go to -- which is exactly when they must not be occupying the storage column.
        if (not executing) and (not m_Refuelling) and inStorageColumn() then
            trace("idling in a storage access column -- stepping aside")
            for _ = 1, 4 do
                if pgps.forward() then break end
                pgps.turnRight()
            end
        end

        local s_Free = (not executing) and (not m_Refuelling) and (m_Status == "idle") and (not m_Docked)
        if not s_Free then
            s_IdleSince = nil
        else
            s_IdleSince = s_IdleSince or os.clock()
            if (os.clock() - s_IdleSince) >= IDLE_BEFORE_DOCK then
                -- NEVER GO IDLE HOLDING CARGO.
                --
                -- Stock inside a drone is invisible to every planning decision: the crafter sat on a
                -- dock holding 32 oak planks -- the entire output of the craft the whole build queue
                -- was waiting on -- while storage reported none and the next task blocked for want
                -- of them. Whatever put the drone in this state, carrying it into a park is always
                -- wrong, and here is the one place every idle drone passes through.
                local s_Cargo = 0
                for i = 1, 16 do s_Cargo = s_Cargo + turtle.getItemCount(i) end
                if s_Cargo > 0 then
                    trace(("idle while holding %d item(s) -- depositing before parking"):format(s_Cargo))
                    pcall(Deposit)
                    s_IdleSince = nil
                end

                local f = turtle.getFuelLevel()
                -- DO NOT HAMMER A FULL TOWER.
                --
                -- Every idle tick tried to dock, and with more drones than berths that is a request
                -- that can never succeed -- so the drone shuffled toward the tower, was refused, and
                -- did it again every fifteen seconds indefinitely. From outside it looks exactly
                -- like a drone jumping up and down for no reason, which is what D20 was doing with
                -- 18 drones sharing a 16-slot tower.
                --
                -- Being unable to park is not an error worth retrying hard: the drone is idle, it is
                -- already clear of the chests, and standing still costs nothing. Back off and let
                -- the next free berth find it.
                if s_Cargo == 0 and (f == "unlimited" or f > FuelFloorNow())
                   and (m_DockBlockedUntil == nil or os.clock() > m_DockBlockedUntil) then
                    trace("idle -- parking on a dock so the working spots stay clear")
                    local s_Ok = pcall(dockNow)
                    if not s_Ok or not m_Docked then
                        m_DockBlockedUntil = os.clock() + 300
                        trace("no berth available -- holding position for 5 minutes before trying again")
                    end
                end
                s_IdleSince = nil
            end
        end
    end
end

local function fuelLoop()
    while true do
        os.sleep(FUEL_WATCH_EVERY)
        local s_Fuel = turtle.getFuelLevel()
        if s_Fuel ~= "unlimited" and s_Fuel < FUEL_TOPUP then
            pcall(TryRefuel)                       -- free if it is carrying coal
            s_Fuel = turtle.getFuelLevel()
        end
        local s_Floor = FuelFloorNow()
        if s_Fuel ~= "unlimited" and s_Fuel < s_Floor and not StorageKnownDry(s_Fuel) then
            trace(("fuel at %d (floor %d for this position) -- breaking off to refuel")
                :format(s_Fuel, s_Floor))
            executing = false                      -- stop whatever job is running
            m_Refuelling = true                    -- ...and stay unavailable until fuel is aboard
            -- And actually STOP MOVING. Clearing `executing` only stops the job loop between
            -- steps; a drone already inside flyTo keeps flying until that call returns on its own
            -- terms, which for a climb to cruising height is minutes. This is the fuel watchdog --
            -- minutes is the whole tank.
            pgps.BreakExec()
            -- Yield long enough for the mover to SEE the flag and unwind. Clearing it in the next
            -- statement would be a race the flight usually wins: it is in another coroutine, and if
            -- it has not been scheduled yet it never observes the abort at all.
            os.sleep(2)
            pgps.StartExec()                       -- abort landed; the trip to fuel may now move

            -- STOP AS SOON AS THE TANK IS FULL, AT EVERY STEP.
            --
            -- This ran the whole sequence -- deposit, travel to storage, dock -- and only released
            -- the busy flag at the very end. Each of those steps can block for minutes, so a drone
            -- that had ALREADY refuelled went on refusing work the entire time: D3 sat idle with
            -- 2,480 fuel answering "REFUSED: refuelling" to the fuel-relief task for D2, which was
            -- the one job that needed doing and the one drone that could do it.
            --
            -- Burning what it already carries comes first because it is free and instant, and each
            -- later step is skipped the moment the drone is fuelled again.
            local function fuelled()
                local f = turtle.getFuelLevel()
                return f == "unlimited" or f >= FuelFloorNow()
            end

            -- FUEL FIRST. NOT DEPOSIT, NOT DOCKING.
            --
            -- This ran three separate journeys in order -- deposit the load, go to storage, then
            -- find a berth -- and each is a full moveTo/digTo/flyTo attempt that can thrash. A
            -- drone breaking off at its floor with ~1,000 fuel spent all of it on the first two and
            -- arrived at the third with none: the log is a run of "refuel sequence finished at 0
            -- fuel", over and over, from a fleet standing on a chest full of coal.
            --
            -- Only one of those three trips keeps the drone alive. The cargo can wait -- and
            -- RefuelAtStorage puts non-fuel back in the chest anyway, so the load usually gets
            -- delivered as a side effect. Docking a drone that has no fuel just parks the problem.
            pcall(TryRefuel)                       -- free: burn what is already aboard
            if not fuelled() then
                local s_Try, s_Why = pcall(RefuelAtStorage)
                if not s_Try then trace("refuel at storage threw: " .. tostring(s_Why)) end
            end
            -- Only once it can afford the trip: a deposit is worth doing, but never at the cost of
            -- stranding the drone that would make the next one.
            if fuelled() and FreeSlots() < 8 then pcall(Deposit) end

            m_Refuelling = false
            m_Status = "idle" m_Detail = nil
            SendHeartBeat()
            trace(("refuel sequence finished at %s fuel"):format(tostring(turtle.getFuelLevel())))
        end
    end
end

-- How far a scheduled fix may correct us before the HEADING becomes the suspect rather than the
-- position. One or two blocks is ordinary dead-reckoning noise between fixes; four is a pattern.
local HEADING_SUSPECT_DRIFT = 4

-- A BIG DRIFT IS EVIDENCE THE HEADING IS WRONG, AND THE SCHEDULED FIX IS THE ONLY THING THAT EVER
-- LEARNS IT.
--
-- Failed moves do not drift -- forward() only advances the cache when turtle.forward() returned
-- true. A SUCCESSFUL move with a wrong cachedDir does: the drone goes one way and the cache goes
-- another, so belief and reality separate at TWICE the distance travelled. D14 was 118 blocks out
-- in x, which is about fifty-nine blocks flown backwards.
--
-- Nothing questioned the heading during ordinary work. Every ensureHeading() call is the unforced
-- one, which returns the instant cachedDir is set, and the forced re-derivation lived only in
-- SurfaceForFix -- the recovery path. A wrong heading carries a drone AWAY from GPS, so it never
-- arrived there. Self-reinforcing, and invisible until somebody read the coordinates by hand.
--
-- GPS has just confirmed a position when this runs, which is the one moment the probe can check
-- itself against something true.
local function noteCorrection(p_Drift)
    trace(("position was %d blocks out -- corrected"):format(p_Drift))
    SendHeartBeat()
    if p_Drift >= HEADING_SUSPECT_DRIFT then
        trace(("drift of %d is too big for dead reckoning -- re-checking the heading"):format(p_Drift))
        ConfirmHeading()
    end
end

local function refixLoop()
    local s_Failures = 0
    while true do
        os.sleep(REFIX_EVERY)
        local px, py, pz, pd = pgps.getCachedPosition()

        -- A WRONG POSITION IS NOT A MISSING ONE, AND ONLY ONE OF THEM WAS EVER RE-CHECKED.
        --
        -- Every branch below fires on px == nil, or on a missing heading. A drone that HAS a
        -- position simply kept it, however wrong -- the only other thing that re-verifies is
        -- requireFix, which runs every few MOVES, and a drone that cannot move never moves.
        --
        -- D1 sat at zero fuel reporting a position 31 BLOCKS from where it actually was. The fuel
        -- relief worked exactly as designed and delivered 122 coal to empty air at the phantom
        -- coordinate. Rescue, relief, the map and every gather target are only as good as this
        -- number.
        --
        -- FIRST, not as a fallthrough. Written as the else-branch it never ran at all for the drone
        -- that needed it: at zero fuel D1 could not take the step that derives a heading, so the
        -- heading branch matched every single tick and shadowed it. The one drone whose position
        -- could not self-correct was the one drone excluded from the correction.
        if px ~= nil and not executing then
            -- FORCED, past the no-coverage backoff.
            --
            -- The backoff exists so tight loops do not each pay a 5-second GPS timeout underground.
            -- But every failure refreshes it, and a stranded drone's fuel watchdog retries every 20
            -- seconds -- so the backoff was permanently fresh and this 45-second check, the only
            -- thing that can correct a drifted position, never actually ran. This is the scheduled
            -- check; it is exactly the caller that should ignore the backoff.
            local s_Ok, s_Drift = pgps.verifyPosition(true)
            if s_Ok and type(s_Drift) == "number" and s_Drift > 0 then
                noteCorrection(s_Drift)

                px, py, pz, pd = pgps.getCachedPosition()
            end
        end

        if px == nil and not executing then
            if pgps.verifyPosition() then
                trace("re-acquired a position after losing it")
                s_Failures = 0
            else
                s_Failures = s_Failures + 1
                -- Two quiet retries first. A fix blinks out near the edge of coverage, and
                -- tunnelling upward through a floor to fix that would be worse than the problem.
                if s_Failures >= 3 then
                    trace("no fix after 3 tries -- climbing to find the sky")
                    if climbForFix() then s_Failures = 0 end
                end
            end
        elseif px ~= nil and not executing and not pgps.mayStep(px, py, pz) then
            -- Standing somewhere it is not allowed to be. Walk back before anything else.
            s_Failures = 0
            returnToRegion()
        elseif px ~= nil and pd == nil and not executing then
            s_Failures = 0
            -- Heading recovery, moved off the heartbeat: it steps the turtle, can rise, and can
            -- dig, so it belongs on a thread where taking a minute costs nothing.
            if pgps.ensureHeading() then trace("re-established heading") end
        else
            s_Failures = 0
        end
    end
end

-- DRONES NO LONGER HOST GPS.
--
-- A relay publishes its position to every drone in range, so a relay with a bad fix does not make
-- one bad reading -- it makes every listener's position wrong, and every observation those
-- listeners record is then filed at the wrong coordinates. D10 logged the whole failure in three
-- lines: it computed a fix of -55,117,-91 while standing at -34,84,-39, refused to host it,
-- computed another, and hosted -56,126,-88 anyway. Fifty blocks out, offered to the fleet as fact.
--
-- The corroboration check was meant to prevent exactly this and cannot: it compares the fix against
-- the drone's own cached position, which was itself derived from GPS, so once the constellation is
-- polluted the check agrees with the pollution. It is a feedback loop, not a guard.
--
-- This existed when there were four GPS hosts and drones ranged far past them. There are now
-- twenty-two static hosts covering the whole working volume, placed against measured drone
-- positions -- so relaying buys nothing and risks the fleet's entire coordinate system.
local RELAY_DISABLED = true

local function gpsRelay()
    if RELAY_DISABLED then
        -- Close the channel if a previous version left it open, then stand down.
        local s_M = peripheral.find("modem")
        if s_M then pcall(s_M.close, gps.CHANNEL_GPS) end
        m_Hosting, m_HostPos = false, nil
        while true do os.sleep(300) end
    end
    while true do
        os.sleep(10)

        local s_Eligible = (m_Status == "idle") and not executing
        local s_Modem = peripheral.find("modem")

        if s_Eligible and s_Modem then
            -- Anchor on a fix of our OWN, every cycle. Dead reckoning is good enough to navigate
            -- with and never good enough to publish.
            local fx, fy, fz = gps.locate(5, false)
            -- Floor before hosting. A relay publishes its position to every drone in range, so a
            -- fractional fix here is not one bad cell -- it is every cell every listener records
            -- from now on, filed under keys nothing can look up.
            if fx then fx, fy, fz = math.floor(fx), math.floor(fy), math.floor(fz) end

            if fx == nil then
                trace("relay: no fix of my own (status=" .. tostring(m_Status) .. ")")
                if m_Hosting then
                    pcall(s_Modem.close, gps.CHANNEL_GPS)
                    pcall(s_Modem.close, rednet.CHANNEL_REPEAT)
                    m_Hosting, m_HostPos = false, nil
                    print("GPS relay stopped (lost my own fix)")
                end
            elseif m_Hosting and m_HostPos then
                -- Still here? A host that has drifted is worse than no host at all.
                local s_Drift = math.abs(fx - m_HostPos.x) + math.abs(fy - m_HostPos.y)
                             + math.abs(fz - m_HostPos.z)
                if s_Drift > RELAY_DRIFT_LIMIT then
                    m_HostPos = {x = fx, y = fy, z = fz}
                    Say("GPS relay re-anchored (moved " .. s_Drift .. ")")
                end
            else
                -- A RELAY MUST BE ABLE TO CHECK ITS OWN FIX.
                --
                -- Anchoring on a real gps.locate is not enough. The fix itself is computed from
                -- whatever hosts answered, and if any of those were relays publishing a bad
                -- position, the result is wrong -- confidently. A drone that then hosts it turns
                -- one bad position into a spreading one.
                --
                -- D4 did exactly this: with no position of its own it accepted a fix of
                -- -138,75,-51 while sitting at -80,85,12, and began broadcasting it. Eighty-five
                -- blocks of error, offered to every drone in range as fact.
                --
                -- So a relay must have a position it already believed, and the fix must agree with
                -- it. A drone that does not know where it is has nothing to check against and is
                -- therefore exactly the wrong machine to be a reference for anyone else.
                local cx, cy, cz = pgps.getCachedPosition()
                if cx == nil then
                    trace("relay: refusing to host -- no position of my own to check the fix against")
                elseif (math.abs(fx - cx) + math.abs(fy - cy) + math.abs(fz - cz)) > 8 then
                    trace(("relay: refusing to host -- fix %d,%d,%d disagrees with my position %d,%d,%d")
                        :format(fx, fy, fz, cx, cy, cz))
                else
                s_Modem.open(gps.CHANNEL_GPS)
                -- Listen for traffic to pass along only while parked as a relay. See meshRepeat.
                pcall(s_Modem.open, rednet.CHANNEL_REPEAT)
                m_Hosting = true
                m_HostPos = {x = fx, y = fy, z = fz}
                trace(("relay: hosting at %d,%d,%d"):format(fx, fy, fz))
                Say("GPS relay hosting at " .. fx .. "," .. fy .. "," .. fz)
                SendHeartBeat()
                end
            end

        elseif not s_Eligible then
            trace("relay: not eligible (status=" .. tostring(m_Status) ..
                  " executing=" .. tostring(executing) .. " modem=" .. tostring(s_Modem ~= nil) .. ")")
        end
        if m_Hosting and not s_Eligible then
            -- About to move, or busy: stop answering rather than lie.
            if s_Modem then pcall(s_Modem.close, gps.CHANNEL_GPS) end
            m_Hosting, m_HostPos = false, nil
            print("GPS relay stopped (working)")
        end
    end
end

-- Answer GPS pings the same way a stationary host computer does.
local function gpsServe()
    while true do
        local ev, side, ch, reply, msg = os.pullEvent("modem_message")
        if m_Hosting and m_HostPos and ch == gps.CHANNEL_GPS and msg == "PING" then
            local s_Modem = peripheral.wrap(side)
            if s_Modem then
                s_Modem.transmit(reply, gps.CHANNEL_GPS,
                    {m_HostPos.x, m_HostPos.y, m_HostPos.z})
            end
        end
    end
end

local HEARTBEAT_SECONDS = 30
-- Consecutive unanswered beats before we conclude the link is gone rather than merely busy.
-- Three, because one missed reply is normal (DroneMan servicing another call) and waiting for
-- three costs at most a minute while avoiding a drone that abandons its job over a hiccup.
local LINK_LOST_AFTER = 5

-- Runs of LINK_LOST_AFTER misses before recovery happens REGARDLESS of what a lookup says. Four
-- runs is roughly ten minutes of heartbeats that never arrived -- far past any plausible congestion,
-- and the point at which "the server is busy" stops being a credible explanation for silence.
local LINK_GIVE_UP_RUN = 4

-- Manhattan distance from the mast inside which loss-of-range is not a possible explanation for
-- silence, so RecoverLink must not fire. CC:T wireless range is max(64, 384*y/319) — never below
-- 64 — and this is Manhattan rather than euclidean, so 48 is comfortably conservative: every point
-- it admits is genuinely in range, and a drone just outside it still gets the old behaviour.
local LINK_IN_RANGE_RADIUS = 48

-- Are we close enough to the mast that being out of range is not a possible explanation?
--
-- A GLOBAL function rather than a local, deliberately: the heartbeat loop that calls it is defined
-- far below, and a `local function` here would still be in scope — but this file's convention for
-- anything crossing that distance is a global, because a local moved ABOVE its declaration by a
-- later edit becomes a silent nil lookup. That mistake has cost nine outages here.
--
-- Extracted rather than inlined at the call site so the branches live here instead of inside the
-- heartbeat function, which is already one of the largest in the file and sits against the
-- complexity gate.
function NearMast()
    if m_HomePos == nil then return false end
    local cx, cy, cz = pgps.getCachedPosition()
    if cx == nil then return false end
    local d = math.abs(m_HomePos.x - cx) + math.abs(m_HomePos.y - cy) + math.abs(m_HomePos.z - cz)
    return d <= LINK_IN_RANGE_RADIUS
end
-- Consecutive link-loss episodes where the lookup still answered. Reset on recovery and on any
-- successful heartbeat.
local m_MissRun = 0
local m_Missed = 0

-- Should we stay where we are instead of walking the breadcrumbs home?
--
-- Returns the reason to SAY when staying put, or nil to mean "recover". Owns m_MissRun so the
-- caller does not have to, which keeps the whole decision — and its branches — out of the
-- heartbeat loop; that function is already among the largest here and sits on the complexity gate.
--
-- Two reasons to stay, in priority order:
--   1. We are close enough to the mast that range cannot explain the silence. Walking home from
--      here is a no-op that costs the current job. This one also clears the run counter, because
--      congestion this close is not evidence of anything cumulative.
--   2. A lookup still answers and we have not been failing for too long. This is the pre-existing
--      rule and it keeps its ceiling: a lookup only proves something relayed a broadcast, so it
--      must not be able to veto recovery for ever.
local function linkStayPutReason()
    if NearMast() then
        m_MissRun = 0
        return ("DroneMan silent but we are inside %d blocks of the mast -- congestion, not range")
            :format(LINK_IN_RANGE_RADIUS)
    end
    if PowNet.Lookup("DroneMan") ~= nil and m_MissRun < LINK_GIVE_UP_RUN then
        return "DroneMan is slow, not gone -- staying put (" .. m_MissRun .. ")"
    end
    return nil
end

local function heartbeat()
    while true do
        os.sleep(HEARTBEAT_SECONDS)

        -- KEEP TRYING TO WORK OUT WHERE WE ARE.
        --
        -- Init establishes position once. A drone that boots while GPS happens to be unreachable
        -- therefore has NO position for the rest of its life -- it cannot navigate, so it cannot
        -- move somewhere with coverage, so it never gets one. It still heartbeats, so DroneMan goes
        -- on reporting the last position it ever knew and the drone looks fine while being unable
        -- to accept any work at all. D3 sat like that with all four GPS hosts up and in range.
        -- A stale distress reason keeps a healthy drone looking troubled. If it is idle, not
        -- executing, and knows where it is, whatever went wrong is over.
        if m_Stuck ~= nil and not executing and m_Status == "idle" and pgps.getCachedPosition() ~= nil then
            Say("clearing stale distress: " .. tostring(m_Stuck))
            ClearDistress()
            SendHeartBeat()
        end

        -- HEADING RECOVERY DOES NOT BELONG HERE. See refixLoop.
        --
        -- ensureHeading was called from this loop, and it is no longer cheap: it steps the turtle to
        -- work out which way it faces, and after being taught to escape a box it will also rise up
        -- to four blocks, probe four directions at each level with a five-second GPS fix apiece, and
        -- dig. That is minutes of blocking work on the one coroutine whose entire job is to report
        -- in every thirty seconds -- so the drones that needed help most were exactly the ones that
        -- stopped heartbeating, and DroneMan marked twenty-three live, working drones as lost.
        --
        -- The heartbeat must stay cheap. Recovery happens on its own thread where blocking is free.

        if false then
            local ok = pgps.verifyPosition()
            if ok then
                print("position re-established")
                SendHeartBeat()
            elseif pgps.trailLength() > 0 then
                -- WALK BACK ALONG WHERE WE CAME FROM.
                --
                -- A drone with no position cannot navigate ANYWHERE -- it has no idea where it is,
                -- so it cannot compute a route out of the dead zone it is sitting in. The one thing
                -- it still knows is the sequence of moves it made getting here, and the coverage it
                -- lost was working somewhere back along that trail.
                --
                -- This is the only escape that does not require knowing your position, which is
                -- exactly the thing that is missing.
                Say("no position -- retracing " .. pgps.trailLength() .. " crumbs to find coverage")
                m_Status = "recovering"
                pgps.setRecovering(true)
                local s_Steps = 0
                while s_Steps < 80 do
                    local bx, by, bz = pgps.trailBack()
                    if bx == nil then break end
                    s_Steps = s_Steps + 1
                    pgps.flyTo(bx, by, bz, 24)
                    if pgps.verifyPosition(true) then
                        Say("coverage regained after " .. s_Steps .. " crumbs")
                        break
                    end
                end
                pgps.setRecovering(false)
                m_Status = "idle"
                SendHeartBeat()
            else
                -- NO POSITION AND NO TRAIL: search for coverage.
                --
                -- Breadcrumbs live in memory, so a drone that reboots while stranded has nothing to
                -- retrace and cannot compute a route either -- it does not know where it is. The
                -- only move left is the one a real robot would make: go somewhere, anywhere, and
                -- keep asking. Coverage is a 64-block bubble, so a drone that fell out of it is
                -- usually just past the edge and a short walk gets back in.
                --
                -- Bounded and reported, because a machine wandering blind is only acceptable as a
                -- deliberate, finite last resort.
                print("no position and no trail -- searching for GPS coverage")
                m_Status = "recovering"
                pgps.setRecovering(true)
                -- DO NOT WALK BLIND. CLIMB.
                --
                -- This searched for coverage by walking a square on the ground -- and recovery mode
                -- switches the region check OFF, because a drone with no position cannot evaluate
                -- it. So the one manoeuvre performed by the drones least able to judge it was the
                -- one manoeuvre that could carry them out of the force-loaded chunks. D1 did
                -- exactly that: it reached -411,64,120 with the region ending at x=-424, could not
                -- get back, and then vanished from the computer registry altogether -- outside the
                -- loaded chunks a turtle stops ticking, and a turtle that does not tick is gone.
                -- No amount of squaring the search off fixes that; the search itself was wrong.
                --
                -- Climbing cannot leave a chunk: it is the same x and z the whole way. It is also
                -- strictly better at the actual job, because coverage is lost by being under rock
                -- far more often than by being beside it. If the sky does not help, the honest move
                -- is to stand still and say so -- a drone waiting in a known chunk can be rescued;
                -- one wandering blind cannot be found.
                local s_Found = climbForFix()
                if not s_Found then
                    print("no coverage overhead -- holding position for relief")
                end
                pgps.setRecovering(false)
                m_Status = "idle"
                if s_Found then
                    SendHeartBeat()
                else
                    -- Loud, because from outside this is indistinguishable from a drone that is
                    -- simply idle, and it is the reason it will refuse every job it is offered.
                    Distress("no position", "searched for coverage and found none; needs a relay")
                end
            end
        end
        if SendHeartBeat() then
            m_Missed = 0
            -- Contact restored: the run of failed episodes is over, so a drone that has trouble
            -- again next week starts counting from scratch rather than recovering on its first miss.
            m_MissRun = 0
        else
            m_Missed = m_Missed + 1
            Say("no answer from DroneMan (" .. m_Missed .. "/" .. LINK_LOST_AFTER .. ")")
            if m_Missed >= LINK_LOST_AFTER then
                m_Missed = 0
                -- IS THE RADIO ACTUALLY DEAD, OR IS DRONEMAN JUST BUSY?
                --
                -- These look identical from here and demand opposite responses. Unanswered
                -- heartbeats alone are not evidence of being out of range: DroneMan answers the
                -- whole fleet from a single loop, and treating slowness as loss made drones sitting
                -- ON THEIR DOCKS abandon their work and declare themselves stranded -- which is
                -- worse than the problem, because it takes healthy drones out of service.
                --
                -- A lookup is the discriminator. It is a broadcast on the same radio: if anything
                -- answers, the link is fine and the silence is congestion.
                -- ...BUT CONGESTION DOES NOT LAST FOR EVER, AND RANGE LOSS DOES.
                --
                -- The lookup is a broadcast, and the mast repeater relays it -- so a drone sixty
                -- blocks out gets an answer and concludes "DroneMan is merely slow", every time,
                -- while not one of its heartbeats has ever arrived. Four drones sat 87-93 blocks
                -- from base doing exactly that, holding 1,600 items between them, for hours:
                -- permanently "staying put" on the strength of a reply that proves only that
                -- SOMETHING relayed a lookup, not that anyone can hear this drone.
                --
                -- So the lookup keeps its job -- it stops a docked drone abandoning work over a
                -- busy tick -- but it can no longer veto recovery indefinitely. A run of misses
                -- this long is not a busy server; it is a drone that needs to walk back.
                m_MissRun = (m_MissRun or 0) + 1
                -- WALKING HOME IS NOT A REMEDY WHEN YOU ARE ALREADY HOME.
                --
                -- RecoverLink retraces the breadcrumb trail to get back into radio range. That is
                -- the right answer for a drone that has genuinely wandered out of range, and a pure
                -- waste for one sitting next to the mast: it abandons the job, walks a trail that
                -- ends where it already is, and comes back having achieved nothing except taking
                -- itself out of service for the duration.
                --
                -- Measured on this fleet: D20 and D21 were both marked lost at y=65 within a dozen
                -- blocks of DroneMan, holding 2,000+ fuel, while fourteen tasks sat unassigned and
                -- only ONE drone was still working. Their heartbeats were being lost to congestion
                -- -- twenty-one radios share this channel, six of them GPS hosts -- not to range.
                --
                -- Distance is the discriminator the lookup cannot be. A lookup only proves that
                -- SOMETHING relayed a broadcast; the drone's own position against the mast proves
                -- whether range is even a plausible explanation. CC:T modem range is
                -- max(64, 384*y/319), so anything inside 64 blocks is unconditionally in range and
                -- silence there can only be congestion.
                -- Say it every time it happens: from outside, a drone staying put is
                -- indistinguishable from one that is merely idle, and the repetition is the
                -- evidence that the channel — not the range — is the problem.
                local s_Stay = linkStayPutReason()
                if s_Stay then
                    Say(s_Stay)
                else
                    m_MissRun = 0
                    -- Stop whatever we are doing first. Carrying on digging while out of contact is
                    -- how a drone ends up deep in unmapped ground with nobody able to reach it.
                    executing = false
                    RecoverLink()
                end
            end
        end
        UploadWorld()
        -- Only when idle: a drone mid-task is not at the dock and sucking from whatever happens
        -- to be next to it would steal from a chest it is standing over.
        if m_Status == "idle" and not executing then
            TryRefuel()
        end
    end
end

PowNet.SetShutdownHook(OnShutdown)

-- Name the nil instead of dying on "bad argument #9".
--
-- parallel.waitForAny reports a missing entry by POSITION, and position tells you nothing when the
-- list is nine long -- you get "DroneLogic:2286: bad argument #9" on a turtle screen and no way to
-- know which function is missing or why. That is what a whole fleet crash-looping looked like from
-- outside, and counting arguments by hand to find the culprit is not a debugging strategy.
--
-- A local function referenced before its definition -- or deleted by an edit above -- is nil here
-- and nowhere else, so this is the one place the check is worth anything.
-- Runs accepted jobs off the message path. See RunJob for why this exists.
local function jobLoop()
    while true do
        local j = m_JobQueue
        if j == nil then
            os.sleep(0.2)
        else
            m_JobQueue = nil
            -- RunJobNow owns the whole lifecycle including clearing `executing` via TaskEnd, so a
            -- job that throws cannot leave the drone claimed for ever -- pcall here as well, since
            -- this loop dying would take the drone down with it.
            local ok, err = pcall(RunJobNow, j.name, j.data, j.opts, j.body)
            if not ok then
                trace(("JOB %s crashed the worker: %s"):format(tostring(j.name), tostring(err)))
                executing = false
                m_Status = "idle"
            end
        end
    end
end

local s_Loops = {
    {"PowNet.main", PowNet.main}, {"PowNet.droneMain", PowNet.droneMain},
    {"PowNet.control", PowNet.control}, {"heartbeat", heartbeat},
    {"fuelLoop", fuelLoop}, {"idleDockLoop", idleDockLoop}, {"jobLoop", jobLoop},
    {"resumeBranch", resumeBranch}, {"gpsRelay", gpsRelay}, {"gpsServe", gpsServe},
    {"meshRepeat", meshRepeat}, {"scanOnTheMove", scanOnTheMove}, {"refixLoop", refixLoop},
    -- The mesh: announce ourselves, learn the neighbours, and carry other drones' traffic one
    -- addressed hop closer to base. See peerBeacon / meshForward.
    {"peerBeacon", peerBeacon}, {"peerListen", peerListen}, {"meshRelayListen", meshRelayListen},
}
local s_Fns = {}
for _, e in ipairs(s_Loops) do
    if type(e[2]) ~= "function" then
        error(("background loop %q is %s, not a function -- DroneLogic cannot start")
            :format(e[1], type(e[2])), 0)
    end
    s_Fns[#s_Fns + 1] = e[2]
end
parallel.waitForAny(table.unpack(s_Fns))