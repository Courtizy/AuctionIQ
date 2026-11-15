# Development

[Back to the README](../README.md)

Plain Lua, no libraries. The folders follow the tabs: `Dashboard`; `Operations` with `Craft` (advisor,
scans, specializations, plans), `Trade` (posting, groups, markets) and `Queue` (queue, work orders,
shopping, cooldowns); and `Accounting` (statements, ledger, craft results, performance). `Core` (startup,
settings, theme, windows, cleanup, where each view is filed) and `Data` (prices, TSM ledger, forecasts,
statistics) sit underneath them. `Professions` holds one load-on-demand addon per profession
(`AuctionIQ_Alchemy` and so on) with its specialization data, and `AuctionIQ_Paths`: the knowledge point
planner, its presets and the Paths page, loaded the first time Paths opens.

**Tests:** `python3 tests/run_tests.py` (needs `pip install lupa`) runs the addon in a stubbed WoW
environment, on every pull request.

**Benchmarks:** `python3 tests/bench.py --quick` times scans, the advisor, the ledger and the Dashboard
in the same harness (relative costs, not in-game frame times). TSM's records are read through a
time-ordered view kept until they change (`Ledger.ByTime`, `Ledger.From`), so a range reads only the
records in it. Login's warm-up (`Ledger.WarmAll`) parses them, orders them, builds the day archive,
each item's sell-through stats (`Ledger.StatsJob`), when each item sells over 30 days
(`Ledger.SaleTimesJob`) and the indexes a few milliseconds a frame, so the Dashboard's first open finds
them ready. Each is kept until TSM's records change or a record it counted ages out of its window. Stock
targets read only the last two weeks of the time-ordered sales, and the Recommendations list looks up
each item's best scan row from one index per refresh. Background work aims for 4 ms a frame
(`Ledger.FRAME_MS`), so that with the check between steps and the collector catching up it stays near
the 6 ms a frame it may take; the parse reuses one table for each line's fields to leave less garbage.

**Releases:** tagging `v*` builds a release with the BigWigs packager.
