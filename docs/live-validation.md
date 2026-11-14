# Live validation

Some checks can only be done in the game. Each one below says what to do, what to send back, and
what passing looks like. Nothing on this list has been run yet.

After each session, `/reload` (or log out) so the saved variables are written. AuctionIQ reads its
own reports back from `WTF\Account\<account>\SavedVariables\AuctionIQ.lua`.

## Setup for every measured run

Keep these the same across before and after runs, and write them down once:

- Character, realm, and which profession window is open
- Addons enabled (TSM, its AppHelper, ElvUI and the rest, as in `AddOns.txt`)
- Graphics preset, resolution, frame-rate cap (turn the cap off for frame-time runs)
- Same place in the world (for example, the same spot by the profession tables)
- TSM's data: same day's AppHelper download, if possible

## L-01: enchanting work orders (CQ-08)

1. On the enchanter, open the Crafting Orders board and let it list the orders.
2. `/aiq orders`
3. `/reload`

It passes when the report (`AuctionIQDB.debug.orders`) is in the saved variables. Then the bug can be
reproduced in the harness from it.

## L-02: frame pacing baseline

Addon timings come from `/aiq perf`. Whole-client frame times need the game's own counter. Run these
the same way for the build before and the build after a change.

1. `/aiq perf reset`, then do one workload from the list below for about 2 minutes.
2. `/aiq perf` to print it (it's saved too), then `/reload`.

Workloads: login, `/reload`, logout, first open of each tab, switching tabs 10 times, clicking 20
recipes in a row, a profession scan, a full scan, queue and shopping list refresh, crafting a
batch of 10 with the Crafting window open, Accounting with a year of history, and a 30-minute
normal session.

Passing: no AuctionIQ entry over the budget in [benchmarks.md](benchmarks.md) for the workload.

## L-03: one craft, one result? (CQ-05)

1. Turn on the event log: `/etrace`, filtered to `TRADE_SKILL_ITEM_CRAFTED_RESULT` and
   `UNIT_SPELLCAST_SUCCEEDED`.
2. Craft 5 of something that can Multicraft, and 1 salvage.
3. Count the events.

Passing: one result event and one success per craft, so the log's craft count equals what you made.
If a craft gives more than one result, the log needs a per-cast match (CQ-05 stays open).

## L-04: commodity batch through a partial sale (Luxaren, Alchemy)

1. In the Crafting tab, queue 10 of a potion or flask the advisor suggests. Note the forecast:
   batch size, cash needed, break-even, expected net, stock left.
2. Craft them from the Queue. Press Craft twice quickly once. Move during one cast.
3. Post them with TSM and let at least some sell.
4. `/reload`, then open Accounting and the batch's results.

Passing: the queue ends at 0 with exactly 10 crafted. The log has 10 crafts and the forecast you
noted. Accounting shows the sold units' cash, the rest as stock, and where the result missed the
forecast.

## L-05: Concentration enchant through a partial sale (Serynko, Enchanting)

The same steps as L-04, with an enchant crafted onto Enchanting Vellum with Concentration, and a
batch bigger than one stack of vellum.

Passing: it stops at one stack and says why. Vellum is on the shopping list and in the cost.
Concentration spent matches the forecast to within Ingenuity refunds.

## L-06: partially supplied work order

1. Pick an order where the customer supplies some reagents.
2. Claim it from the Crafting tab, craft it, turn it in. Also try one claim the game refuses (a
   claim limit or an order someone took) and one release.

Passing: each step moves on only after the game confirms it. The craft sends only your reagents and
reaches the rank asked. A refused or released order goes back to Claim.
