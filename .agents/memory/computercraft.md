# ComputerCraft computers from the console — what actually works

> Moved from `minecraft-create121` on 2026-08-21. The fleet is an application; the server repo is
> just the server. Fleet source now lives in `HiveMind/lua/`, tooling in `HiveMind/bin/`.

Verified 2026-08-20 against CC:T `cc-tweaked-1.21.1-forge-1.119.0` on this server.

**Use `bin/cc-computer.sh`. Do not do this by hand.** It is mounted into the mc container at
`/opt/mc-tools`, so from an agent:

```
project_exec(service="mc", command="/opt/mc-tools/cc-computer.sh list")
project_exec(service="mc", command="/opt/mc-tools/cc-computer.sh ensure -85 81 -44 hivemind-1 /opt/mc-tools/lua/hello-startup.lua")
```

`ensure` is idempotent on position — run it twice and you get the same computer back, not a
second one. That matters more than it sounds: working this out by hand produced computer #77
purely because every failed attempt created another block.

## The sequence, and why each step is there

1. `setblock <x> <y> <z> computercraft:computer_normal` — places a block. **This does not create
   a computer.** The block entity has no `ComputerId`, so `computercraft dump` does not list it
   and `computercraft turn-on` cannot address it.

2. `data merge block <x> <y> <z> {ComputerId:<N>,Label:"<name>"}` — **this is the step that
   creates the computer.** It is also where the label goes, and the label is not cosmetic: an
   unlabelled computer's filesystem is discarded, so it would never persist.

3. `computercraft turn-on <N>` — only possible now that it has an id. This is the chicken-and-egg
   that makes step 2 non-obvious.

4. The computer's directory `<world>/computercraft/computer/<N>/` appears **only once the
   computer WRITES something.** A freshly booted computer with an empty filesystem writes
   nothing, so a labelled, running computer can still leave no trace on disk. Give it a
   `startup.lua` that writes a file — `bin/lua/hello-startup.lua` does exactly this and nothing
   else. That directory is also where HiveMind's lua would be delivered.

## Dead ends — don't repeat these

- **Redstone does not boot it.** Placing a `redstone_block` adjacent and waiting does nothing; the
  computer stays `On: 0b` and unregistered. The NBT write in step 2 is what brings it into
  existence, not power.
- **`computercraft dump` on a fresh block shows nothing**, which reads as "the mod is broken". It
  is not — there is genuinely no computer yet.
- **Force-loading the chunk is necessary but not sufficient.** `forceload add` keeps it ticking
  with no players online (this world already force-loads `[-6,-3]` and `[0,0]`), but a
  force-loaded chunk still will not create a computer on its own.
- **`save-all flush` does not create the directory.** Only a write from inside the computer does.

## Two traps that cost real time

- **`rcon-cli` eats negative coordinates as its own flags.** `rcon-cli data merge block -85 81 -44
  {...}` makes rcon-cli read `-85` as an option and the command never reaches the server — and it
  fails *silently*, so a script reports success while doing nothing. Pass the whole Minecraft
  command as ONE argument: `rcon-cli 'data merge block -85 81 -44 {...}'`. `cc-computer.sh`
  handles this; anything else calling rcon-cli must too.
- **This box is often saturated.** With the agent fleet building images, the server runs 100+ ticks
  behind and warns `Can't keep up!`. A few seconds of wall clock can be almost no game time, so a
  step can look like it failed when it simply has not ticked yet. Check `computercraft dump`
  again after a minute before concluding anything is broken.

## Wireless modems

A modem must **face** the block it serves. `setblock` uses a default facing, and a modem that
faces the wrong way is not attached to anything — the computer reports `no peripherals`, which
reads as the modem being broken rather than aimed wrong. Cost an attempt to find.

    cc-computer.sh modem -86 81 -44 -85 81 -44     # place at the first, facing the second

Then reboot the computer it serves; peripherals are picked up at boot. Confirmed working: computer
#78 reports `right = modem`.

## Turtles

A turtle is a computer, so id and label work identically — and the same rule applies: unlabelled
means it never persists. Two extras decide whether a "working" turtle actually works:

- **Fuel.** `Fuel: 0` out of the box, and a turtle with no fuel cannot move at all.
- **Upgrades.** `LeftUpgrade` / `RightUpgrade`. A mining turtle is
  `LeftUpgrade: "minecraft:diamond_pickaxe"`; wireless is
  `RightUpgrade: "computercraft:wireless_modem_normal"`.

Only three turtle upgrades ship as data files in the jar (speaker, wireless_modem_normal,
wireless_modem_advanced) — tool upgrades are generated from vanilla items at runtime, so
`minecraft:diamond_pickaxe` is a valid upgrade id even though it appears nowhere in
`data/computercraft/computercraft/turtle_upgrade/`. Searching the jar for it finds nothing, which
is misleading; it works.

    cc-computer.sh turtle -85 81 -46 mining-1 --wireless

Confirmed: turtle #79 `mining-1` reports fuel 2000, `right=modem`, wireless true, can dig true —
by writing that report itself from inside the game.

## Disks — how `disk/PowNet` becomes a real path

HiveMind's `Bridge.lua` and `Sync.lua` do `os.loadAPI("disk/PowNet")`. That is a path on a MOUNTED
FLOPPY, not a folder someone creates. Three parts:

1. A `computercraft:disk_drive` adjacent to the computer. No facing needed, unlike a modem.
2. A floppy IN it — a bare drive mounts nothing:
   `item replace block <x> <y> <z> container.0 with computercraft:disk`
3. **A reboot of the computer.** Peripherals attach at BOOT.

    cc-computer.sh drive -84 81 -44 78

Step 3 is the one that will waste your afternoon, and it fails in the most misleading way
possible: before the reboot, `fs.open("/disk/x","w")` still SUCCEEDS. It creates a plain local
directory called `disk` inside the computer's own filesystem, which then shadows the real mount
when it finally appears. Everything looks right and the files are in the wrong place — I hit
exactly this and only caught it by asking the drive itself:

    peripheral.find('drive').getMountPath()   -- "disk"
    peripheral.find('drive').getDiskID()      -- 0
    peripheral.find('drive').hasData()        -- true

Ask the drive, don't infer from the filesystem.

Host paths:
- disk contents: `data/world/computercraft/disk/<diskID>/`
- computer contents: `data/world/computercraft/computer/<id>/`

Both are ordinary directories, so files can be delivered from outside the game — which is how
HQ's lua sync would put PowNet there.

## Controlling turtles from outside the game

`/computercraft queue <id> <args>` only delivers to a **command computer**
(`computercraft:computer_command`). Queuing at a normal computer or turtle silently does nothing —
no error, no event, the program just never wakes. That cost an hour of thinking the listener was
broken.

So the control plane is two hops, and the wireless modems are what make the second one work:

    rcon: computercraft queue 90 81 fwd
      -> command computer #90 `relay` receives computer_command
      -> rednet.send(81, "fwd")
      -> turtle #81 receives and runs turtle.forward()

Verified end to end. The turtle logged `rednet from 90: fwd` and `fwd -> false fuel=1000` — false
because it is walled in, which is the correct answer rather than a failure of the chain.

Programs live in `bin/lua/` and are copied onto the floppy or the machine:
- `relay.lua` — on the command computer; forwards queued commands over rednet
- `turtle-agent.lua` — on the turtle; listens on rednet and acts
- `bootloader.lua` — on the floppy; see below

A relay needs a wireless modem beside it, and a turtle needs
`RightUpgrade: "computercraft:wireless_modem_normal"` — without it the agent logs `rednet=false`
and sits there deaf. That is exactly what happened to #81 first time.

## The floppy as a bootloader

This is what the disk is FOR: place a machine next to the drive, boot it, and it initialises
itself.

**A disk's startup runs INSTEAD of the host's own.** That is what makes a floppy a bootstrap
medium, and it is also the trap: while a machine sits beside the drive, the floppy owns its boot,
so a program installed at `/startup.lua` never runs. The bootloader therefore ends by handing
control to `/main.lua` — without that last step a machine initialises and then just sits at a
prompt.

Verified with a deliberately unlabelled turtle:

    booted id=81 label=turtle-81 turtle=true
    installed: HELLO.txt, PowNetStub.lua, main.lua

It named itself, pulled the payload off the floppy, and started running it. Updating the fleet is
then just editing the floppy and rebooting each machine beside it.

## Current computers

- `#78` at `-85 81 -44` — **MainFrame** (was `hivemind-1`, intended as the Bridge; repurposed).
  Do NOT label this `Bridge`: it serves module source to the entire fleet and relabelling it takes
  everything down. There is currently no Bridge computer — one must be placed.
- `#79 mining-1` at `-85 81 -46` — wireless mining turtle, fuel 2000.
- `#80 mining-2` at `-87 81 -46` — second wireless mining turtle.
- disk drive at `-84 81 -44` with floppy `diskID 0`, mounted on #78 as `/disk`, verified writable
  by the computer itself. The floppy holds `startup.lua` (bootloader) + `main.lua` (payload).
- `#90 relay` at `-83 81 -44` — a COMMAND computer with a modem, the only kind that can receive
  `computercraft queue`. This is the entry point for driving anything from outside the game.
- `#81 turtle-81` at `-84 81 -43` — bootstrapped entirely by the floppy, wireless, under remote
  control. It is walled in by terrain, so movement commands correctly return false.

## PowNet V2 — the actual bring-up

Source of truth is the floppy at `data/world/computercraft/disk/0/`, which is a plain host
directory — edit it with normal file tools, no rcon needed. MainFrame runs with
`shell.setDir("disk")` and serves those files to every module via `UpdateModule`, so editing the
floppy IS deploying. Modules pick up changes on reboot.

**The label IS the module.** A computer labelled `DroneMan` boots, fetches `DroneMan.lua` from
MainFrame, and becomes DroneMan. Nothing else selects the role.

### Two different bootloaders, and the trap between them

- `disk/startup` — the MODULE bootloader. Refuses to act without a label: it copies itself plus
  `PowNet` and prints "set the label to the module you want".
- `DroneBoot.lua` — the DRONE bootloader. Never reads the label at all.

A drone MUST run the second, because `DroneLogic.Init()` only registers when the label is nil,
and DroneMan is what assigns the real name (`D1`) in its reply. Label a drone up front and it
skips registration forever *while still sending heartbeats*. Use `bin/pownet-drone.sh`.

A floppy's startup takes precedence over the host's own, so a drone parked next to the drive gets
the module bootloader instead and just sits there. Drones are seeded from the host and placed
away from the drive.

### The registration chain — every link is required

    drone → DroneMan.RegisterDrone → DockingMan.AllocateDocking → MapServer.SetDronePos

`RegisterDrone` returns `false, "Failed to get docking"` if DockingMan does not answer, so **no
drone can ever register until DockingMan is up** — that alone kept `drones = {}` empty. DockingMan
in turn needs a registered tower (`GetFreeSlot` nil → "No registered docking stations") and calls
MapServer. `REDNET_TIMEOUT` is 1s with 3 tries, so a missing link does not just fail its own hop,
it eats the caller's budget too.

`DockingMan.lua` wraps `peripheral.wrap("top")` and `Render()` dereferences it — it needs a real
monitor or it dies on first render. MapServer wraps `"left"` but its `Render()` is a no-op, so it
does not.

### A PowNet change needs TWO reboots

The bootloader does `os.loadAPI("PowNet")` and only later `PowNet.UpdateModule("PowNet")`. So a
module fetches the new PowNet to disk while still running the OLD one in memory — the new code
takes effect on the reboot after the one that downloaded it.

This fails in a thoroughly confusing way: the module pulls its own new `.lua` (which calls a
brand-new PowNet function) and runs it against the previous PowNet, so it dies on
`attempt to call field 'MarkDirty' (a nil value)` while the PowNet file on disk plainly contains
`MarkDirty`. Two machines rebooted together can also disagree, depending on what each had on disk
beforehand. **After editing PowNet, reboot every module twice.**

### "left" is the VIEWER's left, and TaskMan needs one

`DockingMan.lua` wraps `"top"`, but `MapServer.lua` and `TaskMan.lua` wrap `"left"` — and only
TaskMan actually dereferences it (`MapServer`'s `Render()` is a no-op, so it survives without).

Left is the left of someone looking AT the screen, not the computer's own left. Derived rather
than guessed: `#78` faces north and reaches its disk drive — at `+X` — as `"left"`. So for a
north-facing computer, left is `+X`. Place these with an explicit `[facing=north]` so the
convention holds.

### TaskMan could not bootstrap itself, twice over

Line 5 is `os.loadAPI("ServerTasks/dig")` and the download that would provide it is at the BOTTOM
of the same file. `os.loadAPI` throws rather than returning false, so it died before ever reaching
the fetch — an unbreakable cycle. Seed `ServerTasks/dig` onto the computer from the host (note:
no `.lua`; the API name is the path).

Then it still failed, because upstream's `ServerTasks/dig.lua` ends in a scratch harness —
hardcoded start/stop coordinates, a top-level `PrepareTask(params)` call, and a write to a file
called `out`. `os.loadAPI` executes the chunk, so that ran on load and died on
`attempt to index local 'max' (a nil value)`, 170 lines away from anything TaskMan does. The
giveaway was an unexplained `out` file appearing on the computer. Trimmed on the floppy; the
module is a library.

### Labels and upgrades are RUNTIME state — edit them with the computer OFF

`data merge`/`data remove` on a running computer or turtle appears to work and is then silently
undone: CC:T holds the label and the turtle's upgrades in the live object and writes them back
over the block NBT on shutdown. Removing a drone's label while it ran, then rebooting it, left
the label exactly where it was — and it looked like the drone had re-registered when it had not.

Shut it down, edit, turn it on. Confirmed both ways: adding a pickaxe to a stopped D1 stuck.

### The heartbeat never beat

`SendHeartBeat()` was called once, at the end of `Init()`, and never again — no timer anywhere.
DroneMan's view of a drone therefore froze at registration: D1 sat docked while the registry
still reported its spawn coordinates and its pre-flight fuel. Position, fuel and status were all
write-once.

It could not simply be looped, and that is almost certainly why it never was:
`pgps.setLocationFromGPS()` deduces heading by stepping the turtle FORWARD AND BACK. On a timer
that walks every docked drone out of its slot and back for ever, burning fuel to re-derive a
heading that has not changed.

Fixed by reading rather than re-deriving: `pgps.getCachedPosition()` returns the cache that every
move and turn in pgps already maintains, `SendHeartBeat` uses it, and a 30s loop joins
`parallel.waitForAny`. Verified by the registry converging — `pos` moved from spawn to dock and a
`fuel` field appeared that had never existed before.

Heartbeats deliberately do NOT `MarkDirty`. Telemetry is re-sent within 30s of any restart, so
persisting every beat would rewrite the whole registry constantly to save nothing. The persisted
file lags on `pos`/`fuel`/`status` and converges on clean module exit; that is intended.

### Retries are not new drones

`sendAndWaitForResponse` re-sends after 1s of silence, three times. The registration chain
(DroneMan → DockingMan → MapServer, each with its own 1s budget) regularly takes longer than
that, so one turtle booting once registered FOUR times — four names, four docking slots,
`lastDrone = 5` — while the drone itself saw nothing but timeouts and, on each timeout, crashed
in `"response: " .. s_Response` (concatenating `false` is an error), rebooted, and did it again.

`RegisterDrone` is now idempotent per computer id: it stores the docking reply on the drone
record and replays it, so a retry returns the same name and slot. Anything else added to this
protocol needs the same treatment — the retry is invisible from the handler's side.

### Two bugs found and fixed here

- **`OnHeartbeat` crash-looped DroneMan.** A heartbeat from an unregistered drone made
  `GetDroneIDByCCID` return nil and `DATA["drones"][nil][k] = v` error. One pre-labelled turtle in
  the world (`mining-1`) was enough to kill DroneMan on a loop forever. It now answers
  "unregistered" instead.
- **Nothing persisted while running.** `Update()` is the *render* hook, not a save; the only
  write-back was the bootloader's, after a module exits. A server stop, chunk unload, or MainFrame
  reboot (which returns every module through the INIT id=0 path) dropped every registration —
  worse than it sounds, because registration is not idempotent: `lastDrone` and `freeSlot` keep
  counting, so a surviving drone holds a name and slot the servers no longer know about. PowNet
  now has `MarkDirty()`/`Save()`, and `Update()` writes back AFTER the reply is sent (saving
  inside a handler spends a round-trip before replying and times the caller out).

### GPS is a hard prerequisite

`DroneLogic.Init()` → `pgps.setLocationFromGPS()` → `gps.locate(4, false)`, which needs **4
non-coplanar hosts** in modem range. Vanilla CC GPS, nothing PowNet-specific. Hosts #100-103 sit
at y=95/99 above the base, each a computer with a modem on top and
`shell.run("gps","host",x,y,z)` as startup.

**Force-load first.** The first four hosts were placed in chunk `(-6,-4)`, which was not
force-loaded — they never ticked, never appeared in `computercraft dump`, and looked like failed
placements. `forceload add -100 -60 -70 -30` fixed it, and the identical commands then worked.

`setLocationFromGPS` MOVES the turtle to work out its heading, so a drone needs open air around
it — a walled-in turtle reports `fwd -> false` and gets stuck.

### Current PowNet fleet

- `#78 MainFrame` at `-85 81 -44` — drive left, modem right. VFS at `computer/78/data/<Module>`.
- `#91 DroneMan` at `-87 81 -44` — monitor top, modem front.
- `#110 DockingMan` at `-91 81 -44` — monitor top, modem below.
- `#111 MapServer` at `-93 81 -44` — modem below; also pulls `PowGPSServer`.
- `#112 TaskMan` at `-95 81 -44` — monitor on its LEFT at `-94 81 -44`, modem below.
- `#100-103` — GPS constellation, y=95/99.
- `#114 D1` — first cleanly registered drone; spawned unlabelled at `-88 85 -50`, was named by
  DroneMan and flew itself to docking slot 0 of tower `dock1` at `-95 83 -45`.

### Calling `callable` server events — `PowNetRemote.lua`

Don't go looking for a command interface in PowNet itself; `PowNet.control()` is only a
quit-on-keypress loop. The client is `PowNetRemote.lua`, which installs itself as `/p`:

    p DockingMan add -name dock2 -height 4 -pos <x> <y> <z>

Arguments are `-param value`, matched against the `params` table each module declares alongside
`callable = true`. It fills in `params.gps` from its own position automatically, which is why
`OnAddDockingTower` accepts `gps` as a stand-in for `pos`.

The floppy was missing nine V2 files, `PowNetRemote.lua` and `ServerTasks/dig.lua` among them —
worth diffing `TurtleHQ/lua/V2/` in the repo against `disk/0/` before concluding something was
never written. Tower `dock1` was seeded straight into `computer/78/data/DockingMan` before this
was found; either route works, but `/p` is the intended one.

Scripts: `bin/pownet-build.sh` (servers), `bin/pownet-drone.sh` (drones).

**A module that is running has no `last-run.txt`** — that file is only written when a module
exits. An empty/absent one means healthy; a stale one means it crashed at that timestamp. Compare
its mtime against the module's own to tell "crashed just now" from "crashed before the fix".

## HiveMind — the other project that drives this fleet

`~/Projects/HiveMind` is an out-of-world HQ service (`hq/`, TypeScript) that commands this fleet
through a Bridge computer over websocket. It is a SEPARATE repo and its agent does not see this
file unless pointed at it.

**Boundary, so the two never diverge again:** in-world Lua lives ONLY in `pownet/` (this repo).
HiveMind owns `hq/` only. `Bridge.lua` and `Sync.lua` now live on the floppy here and are served by
MainFrame like any other module.

This was not true until 2026-08-21. HiveMind had hand-written its own 92-line `lua/PowNet` stub
declaring `SERVER_PROTOCOL = "pownet-server"` while MainFrame hosts on `"PowNet:Server"` — an
exact-match rednet string, so its Bridge could never have reached MainFrame and would have failed
silently. Nothing was ever deployed, so the fleet was never damaged. Stubs deleted.

Orientation for that side lives in `HiveMind/.agents/memory/the-live-pownet-system.md`.
