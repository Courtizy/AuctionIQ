# Feature coverage

Tracked against the 2026-11-14 brief. ✓ done and tested, ◐ partly there, ○ not started,
🎮 needs the live client.

## 1. Crafting and Queue

| Item | State | Where |
|---|---|---|
| Live profession-window Advisor kept | ✓ | `Crafting/Craft/AdvisorUI.lua` |
| Crafting tab: recipe scans, work orders, specialization, compact queue | ◐ | The tab is Crafting and the code lives in `Crafting/`; `/aiq operations` still opens it. A compact queue is still to do |
| Saved results labelled with character, age, price source | ◐ | The Crafting panel's note shows it (red when over a day old). Queue rows and the Overview still to do |
| Craft vs sell materials vs wait, when meaningful | ◐ | `Plan.Batch` choices: craft, sell the reagents you hold, wait (stock covers or numbers stale). The panel's verdict still shows only craft vs sell |
| Batch size, cash now, break-even, expected net, stock left, gain per Concentration point vs a feasible plain craft | ✓ | Crafting panel rows from `Plan.Batch`; EXTRA/PT compares against the plain craft only when you can make it; tests "crafting plan panel:" |
| One craft plan across Advisor, Scan, forecast, shopping, Queue | ✓ | `Crafting/Craft/Plan.lua`: one shape from the advisor or a saved scan; tests "craft plan:" |
| Last good scan kept after a failed refresh | ✓ | tests "scan: when every recipe errors..." |
| Enchant scroll IDs by rank; vellum in cost, shopping, execution | ✓ | `EnchantScrolls.lua`, tests "enchant:", acceptance 2 |
| Work orders: final allocation and minimum quality after customer reagents | ✓ | `Q.OrderAllocation`, acceptance 2 |
| Show material changes before executing a revised plan | ✓ | second-press confirm in `Q.Craft` |
| Preflight the exact batch: how many can be made, what blocks the rest | ✓ | `Q.Preflight` |
| Track each in-flight request and reconcile confirmed results | ✓ | this PR: one request per click (CQ-02 to CQ-04) |
| Repeat clicks, partial batches, delayed and duplicate events, failed claim and turn-in, interruption, reload, expired orders | ✓ | `acceptance.py`, failure 3 to 9 and lifecycle 10. Duplicate results: 🎮 L-03. Order expiry and the board check: 🎮 L-07 |
| Proofs: commodity, Concentration enchant, partly supplied order | 🎮 | L-04, L-05, L-06 |

## 2. Overview and Accounting

| Item | State |
|---|---|
| Overview: gold trend, cash, stock value, net worth, What changed, Next moves | ◐ (the Dashboard has them; rename and stated horizons are to do) |
| Next moves carry item, character, action, quantity and unit | ✓ (typed handoffs, #134) |
| Accounting: Income Statement, Balance Sheet, Cash Flow, Ledger | ✓ |
| Reports › Performance: weekly profit, contributors, item, profession and batch drill-downs | ◐ |
| Filters carried into transaction detail; opening and closing gold reconciled | ○ |
| Forecast saved at decision time; idempotent TSM import; documented costing; one attribution per sale | ◐ (decisions and batch results exist; the costing method isn't documented) |
| Trade tab retired (decision 2026-11-14): Market trends and stock advice move into Accounting detail; AH panel and Deals removed | ◐ | The AH buying panel and the deal scan are gone (TSM's Shopping covers both). Market trends and stock advice still to move |

## 3. Tune TSM

| Item | State |
|---|---|
| Read effective operations, scope, groups sharing one | ● (`TSMSetup.lua`, `/aiq tsm`) |
| Post cap, duration, floor, shopping max, cancel and repost levers | ● (`Tune.lua`, `/aiq tune`) |
| Record suggestion and change; like-period comparison | ● (`TuneLog.lua`, `/aiq tune log`, `/aiq tune compare`) |
| One documented trial | ○ |

## 4. Architecture and docs

| Item | State |
|---|---|
| Versioned SavedVariables migrations | ◐ (`AuctionIQ.Migrate`, `db.version = 1`) |
| TOC checked in CI | ✓ (this PR) |
| Extracted release package tested | ○ |
| Docs: baseline, bug register, benchmarks, live validation, coverage | ✓ (this PR) |
| Docs: boundaries, lifecycles, storage, costing, allocation, tuning assumptions, TSM interfaces | ○ |

## 5. Frame pacing

| Item | State |
|---|---|
| Live baseline | 🎮 L-02 |
| Crafting window redraw sliced | ✓ (this PR) |
| Side card, `TRADE_SKILL_SHOW`, order claim (CQ-09 to CQ-11) | ○ |
