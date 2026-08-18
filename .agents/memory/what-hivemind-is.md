# What HiveMind Is

HiveMind extends **PowNet V2** (prior art: `Powback/CC-PowNet`) into an autonomous Minecraft turtle "drone army" commanded by Claude. Substrate: Minecraft 1.21.1 NeoForge with CC:T, Advanced Peripherals, Create + Sable, AE2.

Core idea: drones stay dumb (mine, build, craft, scout, recover; execute and report); intelligence moves out of world into **HQ** — a Docker service on PowStation (`hive.pow`) holding the voxel world model (L2, staleness decay), planner, fleet state, and HTTP/WS + MCP API. Claude talks to HQ via typed tools mirrored from PowNet's callable registry.

Layout: `lua/` = in-world code (new `Bridge.lua` websocket relay + PowNet V2 modules, deployed via MainFrame's `UPDATE`); `hq/` = out-of-world service.

Key principles: keep working V2 pieces (drone registration, TaskMan, MapServer, docking, fuel-aware dispatch); HQ must not be a single point of failure; orders are auditable, bounded, abortable; scouts feed L2 rather than the commander reading BlueMap's god view.

Roadmap gates: Phase 0 = run §9 probes (Sable carrier behavior); Phases 1–3 = integration (HQ + Bridge, world model, tools); Phase 4+ = recovery, building, crafting, carriers.
