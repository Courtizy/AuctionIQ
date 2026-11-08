# AuctionIQ

Economic intelligence for the Auction House. **AuctionIQ helps you decide what to do; Clearinghouse,
its ledger, tells you what actually happened.**

A World of Warcraft addon that puts crafting and auction advice in one place: what to craft, buy,
post and cancel, what it costs, and what it really sells for. It reads prices from TradeSkillMaster, and over time it
takes over the jobs that today need both TSM and CraftSim.

## The window

One window, six tabs:

| Tab | What it answers |
|-----|-----------------|
| Today | Where to focus now: the gold chart and a ranked **Do next** list (full Concentration, ready cooldowns, post-now windows, mail, restock, below stock target, reposts). Click a card to go where the work is. The activity log is one click away. |
| Markets | Compare prices (your AH scans against TSM and Oribos Exchange), market prices, competition, when items sell. |
| Crafting | Concentration, best crafts, buy instead of craft, the weekly knowledge plan, and buttons for Scan, Paths, Queue, Results and the advisor. |
| Trading | Groups, operations and mail routes. |
| Analytics | Stock targets (a week of demand at a 90% service level, both settable), dead stock, gold per hour. |
| Clearinghouse | The books: the Report (7/30/90 days and the daily rundown), inventory, revenue, expenses, failed auctions (with the deposits they cost), profit by product, holdings, overhead, CSV export. |

`/aiq today`, `markets`, `crafting`, `trading`, `analytics` and `ledger` open a tab; `/aiq report` opens the Report.

## What it does

- **Tooltips on every item:** the AuctionIQ value after the 5% auction cut, the price to buy it
  as a reagent, and the profit or loss of crafting it, with coin icons.
- **Main window** (`/aiq`, the minimap button, or the addon compartment): gold on every
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
  - an item is valued at what you can expect to get for it: the price after the cut, less the
    deposits you'll lose to expiries before it sells and the cost of gold tied up meanwhile (1% a
    day by default). How often it sells starts from the region's sale rate and moves toward your
    own record as you post
  - Concentration's cost counts Ingenuity refunds, with your specialization's bonuses to them
  - finishing reagents: every combination is tried and the best is used
  - crafting orders (commission and patron rewards against your reagents, the customer's minimum
    quality) and recrafts (the better item less the one you have)
  - top gear: whether another profession tool or accessory in your bags would earn more, with an
    Equip button
  - Simulate: see the numbers with more skill, or with a knowledge point plan from Paths
- **Recipe scan** (`/aiq scan`, or the Scan tab): every learned recipe ranked by profit per
  craft, gold per Concentration point, or gold a day (profit x what the region sells, up to your cap).
- **Profession paths** (`/aiq plan potions`, or the Paths tab): type what you want to sell and
  get a knowledge point plan for the open profession, node by node, with the gold a day each step
  adds and which recipes it improves. The plan is drawn on the profession's own trees (the game's
  layout and icons) in the Paths tab, and marked with step badges on the game's Specializations tab.
  Alchemy, Enchanting, Jewelcrafting and Inscription for now.
- **Craft results** (`/aiq results`): what your crafts really gave (Multicraft, Resourcefulness,
  Ingenuity) against what the advisor expected.
- **Cooldowns** across the warband, in the report.
- **Craft queue and shopping list** (`/aiq queue`, or Queue on the advisor): click an advisor row to
  queue one, shift-click to queue as many as you can make. Fill queues the open profession's five best
  crafts. Craft makes the queued crafts with the advisor's reagents and Concentration, and finished
  crafts come off the queue. The shopping list totals the reagents for the whole warband's queue
  against what you have and prices what's left to buy by walking the listings: buying 200 of a
  reagent costs what the cheapest 200 listed cost, not 200 times the cheapest one. It uses your AH
  search from the last 15 minutes, else the last AH scan it saved for that item, else `chmat`.
  Hover a cost to see how far above the cheapest listing it is.
- **Compare prices** (Markets): every item you hold, sold this month, need for the queue or searched
  at the AH today, priced three ways side by side: your last AH scan (Blizzard's live data, saved
  whenever you, AuctionIQ or TSM search the AH), TSM's realm value and Oribos Exchange's. Gap is the
  scan against the other two; 15% under reads *cheap now*, 15% over *pricey now*, and TSM and
  Oribos more than 25% apart reads *disagree*. Region averages are shown for reference.
- Learns your characters and professions as you play. Open each profession window once.

| Command | Does |
|---|---|
| `/aiq` (or `/ch`) | open or close the main window |
| `/aiq tooltip` | tooltip lines on or off |
| `/aiq coins` | coin icons or g/s/c text |
| `/aiq minimap` | hide or show the minimap button |
| `/aiq advisor` | crafting advisor on or off |
| `/aiq queue` | craft queue and shopping list |
| `/aiq scan` | rank every recipe of the open profession |
| `/aiq plan <goal>` | knowledge point plan, e.g. `/aiq plan potions` |
| `/aiq results` | what your crafts really gave |
| `/aiq cap <n>` | most of one item you'd sell a day, for gold a day (default 10) |

## Clearinghouse, the ledger

The Clearinghouse tab is the books: sales, purchases, income, expenses, expired and cancelled
auctions, inventory, and the Goblin CFO views (profit by product, par, dead stock, holdings, when it
sells, rivals, overhead). It reads TradeSkillMaster's accounting and never writes to it.

## Moving from Clearinghouse

The addon used to be called Clearinghouse. Install the AuctionIQ folder and keep the old Clearinghouse
folder for one login with only the stub `migration/Clearinghouse.toc` in it: AuctionIQ copies the old saved data
over on first login and says so. After that, delete the Clearinghouse folder.

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

TradeSkillMaster, for prices. Without it the report still tracks gold and Concentration.

## Roadmap

The plan lives in GitHub milestones, one per phase (Phase 0: prove what's built, through Phase 5:
release), with an issue per item labelled by component.

## Development

Plain Lua, no libraries. `python3 tests/run_tests.py` (needs `pip install lupa`) loads the addon in
a stubbed WoW environment and checks prices, tooltips, profession tracking and the briefing. Tagging
`v*` builds a release with the BigWigs packager.

The code is split into one folder per component, each with its own `comp:` label on GitHub:

| Folder | What it owns |
| --- | --- |
| `Core/` | Start-up, settings, theme, window, tab bar, minimap button, tooltips, alerts |
| `Data/` | Price sources, TSM-syntax formulas, the sales ledger, item stats |
| `Today/` | The opening page: what to do next |
| `Crafting/` | Scan, advisor, paths, specs (`Crafting/Specs/`), queue, planner, professions, gear, cooldowns, orders, craft log |
| `Trading/` | Groups and operations, posting and cancelling, mail |
| `Analytics/` | Stock targets (Par.lua); forecast vs actual lands here |
| `Clearinghouse/` | The ledger tab and reports |
| `Markets/` | The Markets tab: compare prices, market prices, competition, when it sells |

`AuctionIQ.toc` sets the load order: Core and Data first, then the components that use them.

MIT licence.

## Report and export

The Report (first in the Clearinghouse tab) opens with the books for the last 7, 30 and 90 days side by side (sales after the
cut, purchases, overhead, cash profit, net worth change), the top sellers and crafted profit by
product line, then the daily rundown (last 24 hours, mail, what to post, restock, cooldowns). `/aiq report` opens it. The Ledger's Export button turns the
table you're looking at (with its filters) into CSV text to copy out.
