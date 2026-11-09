# Data

`Spec*.lua` (specialization nodes, perks and the recipes each one applies to, for all eight Midnight
crafting professions) are built by `tools/build_specs.py` from Blizzard's own game tables (DB2), as
[wago.tools](https://wago.tools) publishes them. It downloads the tables it reads into `tools/db2/` (not kept in git).

To refresh after a patch: `python3 tools/build_specs.py` (or `--offline` to rebuild from the saved
tables).

`ConcentrationCurves.lua` (Concentration cost curves) still comes from
[CraftSim](https://github.com/derfloh205/CraftSim) (converted from its data files), MIT licence,
copyright (c) derfloh205. The profit, Multicraft, Resourcefulness, Ingenuity and Concentration
formulas in `Data/Stats.lua` follow CraftSim's.
