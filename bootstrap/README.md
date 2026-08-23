# Bootstrap manifests

A fresh world has no fleet, so the first structures have to be placed by command. That is the thing
this project is not supposed to do -- the last world ended up with 22 GPS hosts cheated in and a
settlement that had never learned to build its own infrastructure.

So cheating writes the recipe. Every placement goes through `hq/src/world/place.ts`, which emits both
the rcon commands that build it now and the manifest that reproduces it later. There is one
description, so the two cannot drift.

A manifest is origin-relative and ordered exactly as a turtle would walk it:

    { name, origin: {x,y,z}, steps: [ {dx,dy,dz,item,heading?}, ... ] }

`heading` is the direction the drone must face while placing -- Minecraft takes a directional block's
orientation from whoever placed it, so stairs and funnels are wrong without it.

The blocks come from the generator in `hq/src/world/tower.ts`, not from hand-written lists, so
building a floor is also a test of the code that designs floors.

| manifest | what | verified |
|---|---|---|
| `tower-L0-shell.json` | Ground floor: slab, wall, service skin, gallery stair, atrium parapet, core column with the fuel draw point | 103/103 wall cells present in world, notch clear, atrium open |

## Site

    centre  (-480, 64)      ground y=63, flat to within 1 block across r=20
    biome   forest          soil 7/9, water 32 blocks north for water wheels
