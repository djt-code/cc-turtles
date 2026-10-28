-- sim/autocompost_no_chest.lua
--
-- autocompost.lua with no chest in front (nowhere to reject cobblestone)
-- and a composter whose output backs up: it should end idle, waiting for
-- new items ("stopped: IDLE"), not spin until the simulator gives up
-- ("STUCK").
local PROJ = ...
package.path = PROJ .. "/sim/lib/?.lua;" .. package.path
local C = require("composter")

C.HAS_CHEST = false
C.HOPPER_STOPS_AT = 200
C.GIVE_UP_AT = 2000
C.inv = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:cobblestone", count = 10 },
          { name = "minecraft:carrot", count = 20 }, nil, { name = "minecraft:wheat_seeds", count = 64 } }
C.run(PROJ)
