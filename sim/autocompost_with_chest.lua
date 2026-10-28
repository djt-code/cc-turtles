-- sim/autocompost_with_chest.lua
--
-- autocompost.lua on a composter with a chest in front: composts what it
-- can and rejects the rest (cobblestone) into the chest.
local PROJ = ...
package.path = PROJ .. "/sim/lib/?.lua;" .. package.path
local C = require("composter")

C.HAS_CHEST = true
C.inv = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:cobblestone", count = 10 },
          { name = "minecraft:carrot", count = 20 }, nil, { name = "minecraft:wheat_seeds", count = 64 } }
C.run(PROJ)
