<p align="center">
  <img src="Media/Logo-Branded.png" width="320" alt="AuctionIQ">
</p>

<p align="center"><b>Economic intelligence for the Auction House.</b><br>
AuctionIQ helps you decide what to do, then keeps the books on what actually happened.</p>

<p align="center">
  <img src="https://img.shields.io/badge/Status-In%20development-e0a83a?style=for-the-badge" alt="Status: in development">
  <img src="https://img.shields.io/badge/WoW-Retail-34c77b?style=for-the-badge&logo=battledotnet&logoColor=white" alt="WoW Retail">
  <a href="https://github.com/Courtizy/AuctionIQ/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/Courtizy/AuctionIQ/test.yml?branch=main&style=for-the-badge&label=Tests" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Courtizy/AuctionIQ?style=for-the-badge&color=263a63" alt="License"></a>
</p>

A World of Warcraft addon that puts crafting and auction advice in one place: what to craft, buy,
post and cancel, what it costs, and what it really sells for. It reads prices from TradeSkillMaster
and Oribos Exchange, checks them against what the Auction House actually shows you, and over time
makes you a better goblin.

---

One window, four tabs. Open it with `/aiq`, the minimap button or the addon compartment.

## <img src="Media/readme/Tab-Dashboard.png" width="28" height="28" alt=""> Dashboard

What needs attention now.

- Four figures across the top: available gold, inventory value, queued crafts (with how many are
  ready or short of reagents) and professions at full Concentration. Each one opens its page.
- The gold chart.
- A ranked **Do next** list: full Concentration, ready cooldowns, post-now windows, mail, restock,
  items below their stock target and reposts. Click a card to go where the work is.

## <img src="Media/readme/Tab-Research.png" width="28" height="28" alt=""> Research

What to do, and why. Three sub-tabs across the top.

**Markets**
- **Compare prices**: every item you hold, sold this month, need for the queue or searched at the AH
  today, priced three ways side by side: your last AH scan (saved whenever you, AuctionIQ or TSM search
  the AH), TSM's realm value and Oribos Exchange's. 15% under reads *cheap now*, 15% over reads
  *pricey now*, and TSM and Oribos more than 25% apart reads *disagree*.
- **Market prices**: now, the 7-day average, the trend and listings for what you hold or sold.
- **Competition**: who undercuts you and how often, from your post scans.
- **When it sells**: the day and hours your sales cluster in, and when to post by.

**Professions**
- **Knowledge**: the weekly knowledge plan, what's coming up, best crafts and Concentration.
- **Plan comparison**: each recipe's quality, profit and gold a day now against your saved plans.
- The crafting tools dock to the right of the profession window (drag one off to float it, Dock puts
  it back):
  - **Advisor**: every result quality with its cheapest reagents and its average profit, worked out
    the way CraftSim does (Multicraft, Resourcefulness, Ingenuity and Concentration included, every
    finishing reagent combination tried). It covers crafting orders (commission and patron rewards
    against your reagents, the customer's minimum quality), recrafts, and whether other profession
    gear in your bags would earn more. Simulate shows the numbers with more skill or with a plan.
  - **Scan**: every learned recipe ranked by profit per craft, gold per Concentration point or gold a
    day; every work order the game has shown you, priced, with knowledge-point rewards marked
    **1KP**; and the first crafts that still give a knowledge point, with what the point costs.
  - **Paths**: type what you want to sell (`/aiq plan potions`) and get a knowledge point plan, node
    by node, drawn on the profession's own trees, for all eight crafting professions. Enchanting's
    **Disenchanting** goal uses what your own disenchants really give.

**Performance**
- Profit by line and character against the period before, and what moved it (price, volume or cost).
- Forecast accuracy, capital efficiency, and crafting efficiency (gold per Concentration point and
  per crafting hour, procs against expected).
- Scenarios: reagents up, prices down and break-even, both settable (`/aiq scenario 10 10`).
- Gold per hour and craft results (what each character's crafts really gave against the advisor).

## <img src="Media/readme/Tab-Operations.png" width="28" height="28" alt=""> Operations

The work planned or underway. Three sub-tabs across the top.

**Work queue**
- **Execution plan**: every craft, post and mail trip waiting, with its status and where to do it.
- **Craft queue**: on every character, with what holds each craft up. Click an advisor row to queue
  one, shift-click to queue as many as you can make. Craft uses the advisor's reagents and
  Concentration, and finished crafts come off the queue. Orders go claim, craft, turn in, one click
  at a time.
- **Shopping list**: the warband's queue against what you hold, priced by walking the AH listings
  (200 of a reagent costs what the cheapest 200 listed cost). At the AH, **Shop queue** searches each
  reagent and skips any more than 25% over its usual price.

**Inventory**
- **Ready to post**, with EV (what one is worth to you at this price) and RZ (what you have really sold it for) beside the price.
- **Stock targets**: a week of demand at a 90% service level, both settable.
- **Dead stock**: what isn't selling.

**Rules & routes**
- **To mail**: what goes to which character, including reagents for crafts queued elsewhere. At the
  mailbox, Send mails each crafter only what they're short.
- **Groups and rules**: which items AuctionIQ posts, buys or mails, and how.

## <img src="Media/readme/Tab-Accounting.png" width="28" height="28" alt=""> Accounting

The books, in plum and parchment. It reads TradeSkillMaster's accounting and never writes to it.

- The **Report**: the last 7, 30 and 90 days side by side (sales after the cut, purchases, overhead,
  cash profit, net worth change), the top sellers, crafted profit by product line, and the daily
  rundown. `/aiq report` opens it.
- Inventory, revenue, expenses, and failed auctions with the deposits they cost.
- Profit by product, holdings and overhead.
- **Export** turns the table you're looking at, with its filters, into CSV text to copy out.

## Prices

Two prices, the same everywhere:

| Name | Means | TSM formula |
|---|---|---|
| `chmat` | what a reagent costs to buy today | `max(first(dbminbuyout,dbmarket,dbregionmarketavg),80%first(dbmarket,dbregionmarketavg))` |
| `chvalue` | what a crafted item sells for | `min(chmat, max(first(dbregionsaleavg,dbregionmarketavg),min(dbmarket,400%first(dbregionsaleavg,dbregionmarketavg))))` |

Add them to TSM as custom sources (`/tsm` > Settings > Custom Sources) to use them in your own
operations. If you don't, AuctionIQ passes the formulas to TSM itself, so the numbers match. Craft
cost is TSM's own `crafting` price.

## Required AddOns

None.

## Supported AddOns

- [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master): prices and accounting.
  Without it, AuctionIQ still tracks gold, Concentration and your own AH scans, but item values,
  profits and the books are off.
- [Oribos Exchange](https://www.curseforge.com/wow/addons/oribos-exchange): a second opinion on realm
  and region prices in Compare prices and the tooltip.

## Install

1. Download the zip: from [Releases](https://github.com/Courtizy/AuctionIQ/releases) once there is one,
   or for now **Code > Download ZIP** on this page.
2. Unzip it into `World of Warcraft\_retail_\Interface\AddOns` and name the folder `AuctionIQ`
   (a Download ZIP folder is called `AuctionIQ-main`; rename it).
3. Log in and open each profession window once, so AuctionIQ learns your recipes.
4. Type `/aiq` to open the window.

## Chat Commands

`/aiq` - open or close the main window<br>
`/aiq dashboard`, `research`, `operations`, `accounting` - open a tab<br>
`/aiq report` - open the Report<br>
`/aiq advisor` - crafting advisor on or off<br>
`/aiq queue` - craft queue and shopping list<br>
`/aiq scan` - rank every recipe of the open profession<br>
`/aiq plan <goal>` - knowledge point plan, e.g. `/aiq plan potions`<br>
`/aiq results` - what your crafts really gave (`/aiq results clear` empties this character's log)<br>
`/aiq scenario <reagents%> <price%>` - set the Scenarios view<br>
`/aiq cap <n>` - most of one item you'd sell a day, for gold a day _(default 10)_<br>
`/aiq de` - what Disenchanting plans count a day; `/aiq de 40 8 2` sets it by hand, `/aiq de auto` uses what you really disenchant _(the default)_<br>
`/aiq tooltip` - tooltip lines on or off<br>
`/aiq coins` - coin icons or g/s/c text<br>
`/aiq minimap` - hide or show the minimap button

---

## Roadmap

The plan lives in [GitHub milestones](https://github.com/Courtizy/AuctionIQ/milestones), one per phase
(Phase 0: prove what's built, through Phase 5: release), with an issue per item labelled by component.

## Development

Plain Lua, no libraries. `AuctionIQ.toc` sets the load order: Core and Data first, then the tabs that use them. The look is described in [THEME.md](THEME.md).

### Code layout

One folder per tab, plus Core and Data underneath them:

| Folder | What it owns |
| --- | --- |
| `Core/` | Start-up, settings, theme, window, tab bar, minimap button, tooltips, alerts |
| `Data/` | Price sources, AH scans, order book, TSM-syntax formulas, the sales ledger, item stats |
| `Dashboard/` | The opening page: what to do next |
| `Research/` | The Research tab and the crafting brain behind it: markets, scan, advisor, specs (`Research/Specs/`), knowledge planner, profession paths, professions, gear, forecasts, the Performance views, craft log |
| `Operations/` | The Operations tab: work queue and shopping, crafting orders, cooldowns, groups and operations, posting and cancelling, mail, stock targets |
| `Accounting/` | The Accounting tab (the ledger) and reports |

Media/ holds the icon, logo and tab art (Media/readme has PNG copies of the tab symbols for this page); tests/ and tools/ are for development and aren't packaged.

## Tests

`python3 tests/run_tests.py` (needs `pip install lupa`) loads the addon in a stubbed WoW environment
and checks prices, tooltips, profession tracking, the views and the layout (nothing spills out of its
panel or gets cut off). It runs on every pull request.

## Releases

Tagging `v*` builds a release with the BigWigs packager. `tests/`, `tools/` and the README are left
out of the package.

## License

MIT. See [LICENSE](LICENSE).
