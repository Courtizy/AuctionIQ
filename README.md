# Clearinghouse

A World of Warcraft addon that puts crafting and auction advice in one place: what to craft, what
it costs, and what it really sells for. It reads prices from TradeSkillMaster, and over time it
takes over the jobs that today need both TSM and CraftSim.

## What it does

- **Tooltips on every item:** the Clearinghouse value after the 5% auction cut, the price to buy it
  as a reagent, and the profit or loss of crafting it, with coin icons.
- **Briefing window** (`/ch`, the minimap button, or the addon compartment): gold on every
  character, Concentration on every profession with when it will be full, and each profession's
  best crafts.
- **Crafting advisor**, docked to the right of the profession window (drag it off to float it,
  Dock puts it back): for the selected recipe, every result quality with its cheapest reagents, the
  profit, and with Concentration the cost in points and the gold each point earns. It marks the best
  profit and the best use of Concentration, worked out the same way CraftSim does.
- **Craft queue and shopping list** (`/ch queue`, or Queue on the advisor): click an advisor row to
  queue one, shift-click to queue as many as you can make. Fill queues the open profession's five best
  crafts. Craft makes the queued crafts with the advisor's reagents and Concentration, and finished
  crafts come off the queue. The shopping list totals the reagents for the whole warband's queue
  against what you have and prices what's left to buy.
- Learns your characters and professions as you play. Open each profession window once.

| Command | Does |
|---|---|
| `/ch` | open or close the briefing |
| `/ch tooltip` | tooltip lines on or off |
| `/ch coins` | coin icons or g/s/c text |
| `/ch minimap` | hide or show the minimap button |
| `/ch advisor` | crafting advisor on or off |
| `/ch queue` | craft queue and shopping list |

## Prices

Two prices, the same everywhere:

| Name | Means | TSM formula |
|---|---|---|
| `chmat` | what a reagent costs to buy today | `max(first(dbminbuyout,dbmarket,dbregionmarketavg),80%first(dbmarket,dbregionmarketavg))` |
| `chvalue` | what a crafted item sells for | `min(chmat, max(first(dbregionsaleavg,dbregionmarketavg),min(dbmarket,400%first(dbregionsaleavg,dbregionmarketavg))))` |

Add them to TSM as custom sources (`/tsm` > Settings > Custom Sources) to use them in your own
operations. If you don't, Clearinghouse passes the formulas to TSM itself, so the numbers match.
Craft cost is TSM's own `crafting` price.

## Requirements

TradeSkillMaster, for prices. Without it the briefing still tracks gold and Concentration.

## Roadmap

1. Shared price source (done)
2. Core addon: briefing and tooltips (this version)
3. Crafting advisor in the profession window
4. Craft queue and shopping list
5. Flip finder
6. Inventory and sales tracking
7. Posting and cancelling

## Development

Plain Lua, no libraries. `python3 tests/run_tests.py` (needs `pip install lupa`) loads the addon in
a stubbed WoW environment and checks prices, tooltips, profession tracking and the briefing. Tagging
`v*` builds a release with the BigWigs packager.

MIT licence.
