# Data

`AuctionIQ_<Profession>/Spec.lua` (specialization nodes, perks and the recipes each one applies to, for all eight Midnight
crafting professions) are built by `tools/build_specs.py` from Blizzard's own game tables (DB2), as
[wago.tools](https://wago.tools) publishes them. It downloads the tables it reads into `tools/db2/` (not kept in git).

To refresh after a patch: `python3 tools/build_specs.py` (or `--offline` to rebuild from the saved
tables).

`Data/ConcentrationCurves.lua` (Concentration cost curves) and `AuctionIQ_Enchanting/EnchantScrolls.lua` (each enchant's scroll
item per quality) are built by `tools/build_crafting_data.py` from the same game tables:
`CraftingData`, `CraftingDifficulty` and `CurvePoint` for the curves, and `CraftingDataEnchantQuality`
for the scrolls. Refresh after a patch with `python3 tools/build_crafting_data.py` (or `--offline`).

The rating each crafting stat needs per 1% is measured in game: every crafting operation reports a
stat's rating and the chance it gives, and `Data/Stats.lua` keeps the latest reading.

What a Resourcefulness proc returns, what Ingenuity refunds and the Multicraft constant per base
yield are measured from your own crafts (`Data/Mechanics.lua`): each proc the game reports adds a
sample, with the craft's perk bonuses taken out, and the measured value takes over once it rests on
20 procs. `/aiq mechanics` shows each value and what it rests on.
