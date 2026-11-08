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
- **One window with tabs** (Advisor, Scan, Paths, Queue, Results), docked to the right of the
  profession window (drag it off to float it, Dock on the tab row puts it back). Only one tab shows
  at a time, so nothing piles up. Pop out the queue to keep it under the tabs while you work.
- **Crafting advisor**: for the selected recipe, every result quality with its cheapest reagents, the
  profit, and with Concentration the cost in points and the gold each point earns. It marks the best
  profit and the best use of Concentration, worked out the same way CraftSim does:
  - profit is the average per craft, counting Multicraft's extra items and the reagents
    Resourcefulness saves
  - Concentration's cost counts Ingenuity refunds, with your specialization's bonuses to them
  - finishing reagents: every combination is tried and the best is used
  - crafting orders (commission and patron rewards against your reagents, the customer's minimum
    quality) and recrafts (the better item less the one you have)
  - top gear: whether another profession tool or accessory in your bags would earn more, with an
    Equip button
  - Simulate: see the numbers with more skill, or with a knowledge point plan from Paths
- **Recipe scan** (`/ch scan`, or the Scan tab): every learned recipe ranked by profit per
  craft, gold per Concentration point, or gold a day (profit x what the region sells, up to your cap).
- **Profession paths** (`/ch plan potions`, or the Paths tab): type what you want to sell and
  get a knowledge point plan for the open profession, node by node, with the gold a day each step
  adds and which recipes it improves. The plan is drawn on the profession's own trees (the game's
  layout and icons) in the Paths tab, and marked with step badges on the game's Specializations tab.
  Alchemy, Enchanting, Jewelcrafting and Inscription for now.
- **Craft results** (`/ch results`): what your crafts really gave (Multicraft, Resourcefulness,
  Ingenuity) against what the advisor expected.
- **Cooldowns** across the warband, in the briefing.
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
| `/ch scan` | rank every recipe of the open profession |
| `/ch plan <goal>` | knowledge point plan, e.g. `/ch plan potions` |
| `/ch results` | what your crafts really gave |
| `/ch cap <n>` | most of one item you'd sell a day, for gold a day (default 10) |

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
2. Core addon: briefing and tooltips (done)
3. Crafting advisor in the profession window (done)
4. Craft queue and shopping list (done), then CraftSim's remaining features and profession paths
   (this version)
5. Flip finder
6. Inventory and sales tracking
7. Posting and cancelling

## Development

Plain Lua, no libraries. `python3 tests/run_tests.py` (needs `pip install lupa`) loads the addon in
a stubbed WoW environment and checks prices, tooltips, profession tracking and the briefing. Tagging
`v*` builds a release with the BigWigs packager.

MIT licence.
