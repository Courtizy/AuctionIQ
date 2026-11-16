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

## L-07: work orders after a `/reload` and after time away

1. Queue two work orders from the Crafting tab. Claim one.
2. `/reload` while the claimed order's craft is casting.
3. Log out until one queued order expires or someone else takes it (a public order is quickest).
4. Log back in, open the profession and its Crafting Orders tab so the board is fetched.

Passing: after step 2 the claimed order's row shows Turn in (or Craft if the cast didn't finish).
After step 4 the gone order's row says Expired or No longer listed, its reagents are off the shopping
list, Next skips it, and its button takes it off the queue. An order still on the board is untouched,
and a claim that timed out is back at Claim. Then type `/aiq orders` and check that the listed orders
show an expiry time (the game's `expirationTime`); if they don't, tell me, since the Expired label
depends on it.

## L-08: TSM setup read back (Tune TSM)

1. `/reload` so TSM writes its saved data.
2. Pick three items you post: one in a group that sets its own Auctioning operation, one in a
   sub-group that inherits it, and one in a group with two operations where one is ignored for some
   characters.
3. Shift-click each into `/aiq tsm ` and compare the lines with TSM's Groups and Operations windows.
4. Try `/aiq tsm <group path>` for one group, typed as TSM shows it (for example `Alchemy/Flasks`).

Passing: the operation, where it is set (its own or from which parent), the groups sharing it and
each saved setting match what TSM shows, and every price shown is the one TSM's operation tooltip
gives. Anything listed under "Can't read reliably" is a real gap, not noise. Tell me any line that
doesn't match.

## L-09: Tune TSM suggestions

1. `/reload`, then `/aiq tune 10`.
2. For two of the suggestions, open the group in TSM and check the "now" value matches the operation.
3. Open Accounting > Ledger on the last 30 days, filtered to one suggested group's items, and check
   the evidence counts (sold, expired, cancelled, bought) against the lines.

Passing: every current value matches TSM, the evidence counts match the ledger within a unit or two
(TSM can split one stack into several rows), and no suggestion asks for a change you think would lose
gold. Tell me any that looks wrong and why, since that's what the thresholds get tuned on.
