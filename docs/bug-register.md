# Bug register

Status: **open**, **fixed** (in the PR named), **needs live** (can't be settled without the game),
**stale** (the lead no longer applies to current code).

Evidence: **verified** = reproduced in the harness or seen in the live client's records;
**code** = read in the code, not yet reproduced.

## Crafting and Queue

| ID | Problem | Repro | Evidence | Status |
|---|---|---|---|---|
| CQ-01 | The Crafting window re-prices every recipe in one frame after any bag, Concentration or skill change, and every craft causes one | Open the Crafting window on a profession with a few hundred scanned recipes, craft anything | verified: live `/aiq perf` worst 438.6 ms; harness 189 ms (200 rows), 418 ms (1000 rows) | **fixed** (this PR): 5.5 ms and 8.5 ms worst frame |
| CQ-02 | A refused click on another recipe's Craft button mid-batch moves the batch's remaining results to that recipe, with no forecast | `acceptance.py` failure 9.1 | verified | **fixed** (this PR) |
| CQ-03 | A refused second click on the same recipe mid-batch cancels the batch's request: the queue stops counting it (2 left after 3 crafted, so it would be crafted again) and the log keeps 1 of 3 forecasts | failure 9.2 | verified | **fixed** (this PR) |
| CQ-04 | One cast's `UNIT_SPELLCAST_SUCCEEDED` reported twice takes two crafts off the queue | failure 9.4 | verified (harness); whether the game ever repeats a cast GUID is unknown | **fixed** (this PR): one count per `Cast-` GUID |
| CQ-05 | `TRADE_SKILL_ITEM_CRAFTED_RESULT` reported twice for one craft counts two crafts | probe P3 | verified (harness); whether the game does it is unknown (audit hypothesis 9) | **needs live**: L-03 |
| CQ-06 | A result that lands before its cast's success event | failure 9.3 | verified it works | **fixed**: covered by a test |
| CQ-07 | After an interrupt, the log's `Pending()` still shows the old batch | probe P4 | verified, no effect on results since this PR (results follow requests) | open, cosmetic |
| CQ-08 | Enchanting work orders: the advisor misreads orders on the board | `/aiq orders` at the board, then `/reload` | the report isn't in saved variables yet | **needs live**: L-01 |
| CQ-09 | The Crafting window's side card and details add about 100 ms on top of the rows (438 total, 338 rows) | live `/aiq perf` | verified (live) | open: next perf PR |
| CQ-10 | `TRADE_SKILL_SHOW` takes up to 113 ms; the profession craft card up to 105 ms | live `/aiq perf` | verified (live) | open |
| CQ-11 | Claiming an order (`CRAFTINGORDERS_CLAIM_ORDER_RESPONSE`) takes up to 95 ms | live `/aiq perf` | verified (live) | open |
| CQ-12 | A work order that expired, was taken by someone else or was cancelled stayed in the queue for good: it kept a Claim button, its reagents stayed on the shopping list and its profit in the totals | acceptance lifecycle 10 | verified (harness) | fixed: marked Expired or No longer listed, left out of shopping and totals, removed on click |
| CQ-13 | A claim that timed out while you were offline (no release event fires then) left the entry at Craft after a `/reload` | acceptance lifecycle 10 | verified (harness) | fixed: a full fetch of the board puts it back to Claim |

## Accounting and Overview

| ID | Problem | Evidence | Status |
|---|---|---|---|
| AC-01 | Sales attribution credited bought or held stock to crafted batches | audit risk 4 | **stale**: fixed on main in `bedb7d1` (credit a batch only with units you crafted) |
| AC-02 | Do Next ranked unlike values | audit risk 2 | **stale**: fixed on main in `8758ae3` (one expected-gain number) |
| AC-03 | Sell-through counted units as trials | audit risk 3 | **stale**: fixed on main in `7c0af86` (days of evidence, not units) |
| AC-04 | Cost basis differs by stage | audit risk 5 | **stale**: fixed on main in `36a1386` (one labelled cost basis per stage) |
| AC-05 | `ledger.days`, `ledger.worth` and `competition[*].by` grow without bound | audit §5 | open: needs a versioned archive migration |

## Packaging

| ID | Problem | Evidence | Status |
|---|---|---|---|
| PK-01 | Old files left in the install folder (see baseline) | verified on the device | open: harmless, user can delete |
| PK-02 | Nothing checked that the TOC lists every file | code | **fixed** (this PR): `toc:` checks in the harness |
