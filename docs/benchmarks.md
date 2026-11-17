# Benchmarks

Harness numbers come from `python3 tests/bench.py` (Lua 5.1 under lupa, seeded and stubbed). They
show relative costs and growth, not in-game frame times. Live numbers come from `/aiq perf`, see
[live-validation.md](live-validation.md) L-02.

## Budgets

The budgets are draft until L-02 gives a live baseline.

| Kind of work | Budget |
|---|---|
| Any one frame of AuctionIQ work, interactive | ≤ 8 ms worst, ≤ 4 ms p95 |
| Background jobs | ≤ 6 ms a frame, and each one can be cancelled |
| Login and reload | no single frame over 16 ms |

## Before and after

| Workload | Metric | Before (`da083f2`) | After (this PR) |
|---|---|---:|---:|
| Crafting window, 200 rows, redraw after a bag change | worst frame | 189.3 ms | 5.5 ms |
| | frames | 1 | 13 |
| Crafting window, 1000 rows, same | worst frame | 417.6 ms | 8.5 ms |
| | frames | 1 | 78 |
| Live: craft window redraw (`/aiq perf`, last session) | worst | 438.6 ms | needs L-02 |

Every other row of `bench.py` is unchanged by this PR (same code paths).

## Item tooltip, first hover after login

Live (`/aiq perf`, 2026-11-16, about 3 minutes of play): the item tooltip's worst call was 72.9 ms,
33 calls and 99 ms in all. The first hover read every item in TSM's groups and built the per-item
sales stats in one go. The tooltip now leaves out the sell chance and posting lines until login's
warm-up has read both, a few milliseconds a frame. It says it is waiting and nudges the warm-up.

| Harness workload | Metric | Before | After |
|---|---|---:|---:|
| First tooltip, 30,000 TSM grouped items, 50,000 sales | time | 78–89 ms | 0.1 ms |
| Reading TSM's groups at login (same) | worst frame | 68–97 ms (one frame) | 4.5 ms over 13 frames |

Needs a live check: `/aiq perf reset` after login, hover items for a minute, then `/aiq perf`. The
item tooltip's worst should be under 8 ms.

## Profession window, first redraw

Live (`/aiq perf`, 2026-11-16, build `e5ff013`, about 3 minutes): opening a profession froze the game
for 614 ms (TRADE_SKILL_DATA_SOURCE_CHANGED, craft window redraw, "rows (worked out)" 612 ms), and
the background row job hit 224 ms in one frame against its 4 ms budget. Each row is checked against
the budget before it starts, so one slow row overran it. The likely slow row is the Concentration
craft with your own reagents: for a recipe whose best mix needs a rank you don't hold, the row ran a
full advisor analysis inside the redraw. That analysis now runs in the background, a few
milliseconds a frame, behind any other background job, and the row is drawn again when it's in.

`/aiq perf` now also shows "craft redraw: one row" (its worst is the slowest single row) and "craft
redraw: own reagents (background, wall time)", so the next live run confirms or rules this out.
Live check: open a profession, then `/aiq perf`. The craft window redraw's worst should be under
16 ms. If "one row" is still high, the cause is elsewhere in the row and the perf line says so.
