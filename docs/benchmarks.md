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
