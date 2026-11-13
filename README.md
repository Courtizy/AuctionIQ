<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Media/Logo-Readme-Dark.png">
    <img src="Media/Logo-Readme-Light.png" width="600" alt="AUCTIONIQ: intelligence for the Auction House">
  </picture>
</p>

<p align="center">AuctionIQ helps you decide what to do, then keeps the books on what actually happened.</p>

<p align="center">
  <img src="https://img.shields.io/badge/Status-In%20development-3fc7eb?style=for-the-badge" alt="Status: in development">
  <img src="https://img.shields.io/badge/WoW-Retail-34c77b?style=for-the-badge&logo=battledotnet&logoColor=white" alt="WoW Retail">
  <a href="https://github.com/Courtizy/AuctionIQ/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/Courtizy/AuctionIQ/test.yml?branch=main&style=for-the-badge&label=Tests" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Courtizy/AuctionIQ?style=for-the-badge&color=1a1a1a" alt="License"></a>
</p>

A World of Warcraft addon that puts crafting and auction advice in one place: what to craft, buy,
post and cancel, what it costs, and what it really sells for. It reads prices from TradeSkillMaster
and Oribos Exchange, checks them against what the Auction House actually shows you, and over time
makes you a better goblin.

---

## Features

**Craft**
- **Every recipe ranked by profit**, Concentration included, for the expansion the profession window has open
- **A craft card beside the profession window**: the best quality to aim for, the cheapest reagent mix for it, an on/off Concentrate switch, and one click to queue it
- **Where an estimate breaks**: break-even sale price, a downside scenario, what Concentration adds per point, and what each sales estimate rests on
- **Batch odds**: the chance a week's sales pay back 10, 30 or 100 crafts, the gold that comes back and the stock left
- **Work orders worth taking**: commission, rewards and knowledge points against what the reagents cost you
- **Specialization presets and a tree calculator**: a build for each thing a profession sells (Light or Void potions, Flasks, Disenchanting...), tested against your own prices, and nodes you can click to try points of your own

**Trade**
- **Ready to post**: what you hold across the Warband, what's already up and how many to post under each group's rules
- **Post, cancel and shop** beside the Auction House, one click at a time, never undercutting your own characters
- **A craft queue and shopping list** for every character, with stock targets that cover a week of sales

**Accounting**
- **Income statement, balance sheet and cash flow** from TSM's records, with every line opening the sales behind it
- **Forecast against actual**: what each craft was expected to make and what it really sold for, so items that keep falling short drop down the rankings

| | The question it answers | Inside |
|---|---|---|
| <img src="Media/readme/Tab-Dashboard.png" width="28" height="28" alt=""> **Dashboard** | What should I do next? | Next Move, Concentration, stock and work that needs you |
| <img src="Media/readme/Tab-Operations.png" width="28" height="28" alt=""> **Operations** | What should I craft, buy or post? | Craft (Compare crafts, Specialization), Trade (Ready to post, rules), Queue (queue, shopping, restock) |
| <img src="Media/readme/Tab-Accounting.png" width="28" height="28" alt=""> **Accounting** | What happened, and what should I learn from it? | Statements (P&L, balance, cash flow, performance), Ledger |

## Requirements

- **World of Warcraft Retail** (Midnight). Recipe ranking works for any expansion the profession window has open; specialization presets and the tree calculator cover the eight Midnight crafting professions.
- **[TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)**. AuctionIQ loads without it, but prices, sales history and the ledger all come from TSM, so most of it is empty until TSM is installed and has seen a few days of data.
- **[Oribos Exchange](https://www.curseforge.com/wow/addons/oribos-exchange)** is optional. When it's there, its realm and region prices are shown beside TSM's.
- Works alongside ElvUI and ToxiUI, and can use ElvUI's colours (Settings).

## Install

1. Download the zip from [Releases](https://github.com/Courtizy/AuctionIQ/releases), or for now
   **Code > Download ZIP** on this page.
2. Unzip it into `World of Warcraft\_retail_\Interface\AddOns` and make sure the folder is named
   `AuctionIQ` (rename `AuctionIQ-main` if that's what you got). From the code zip, also move each
   folder in `AuctionIQ\Professions` (`AuctionIQ_Alchemy` and so on) up into `AddOns`; the release zip
   already has them there.
3. Restart the game completely (a `/reload` doesn't pick up new addon files).

## Your first 10 minutes

1. **Open each profession window once** on each crafter, so AuctionIQ learns your recipes, stats and specialization.
2. **Visit the Auction House** and let TSM (or your own searches) look at prices. AuctionIQ keeps what the AH shows you and uses it beside TSM's numbers.
3. **Rank your recipes.** With a profession open, type `/aiq scan`. Every recipe is listed by gold a day, with and without Concentration.
4. **Read the craft card.** Pick a recipe and the card beside the profession window shows the quality to aim for, the reagents to use, the profit and where that estimate could go wrong. Flip the Concentrate switch to compare.
5. **Queue it.** Add the craft to the queue. The shopping list fills in with the reagents you're missing.
6. **Buy and post at the AH.** The panel beside the Auction House buys the shopping list, then posts what you've made, one click each.
7. **Check the Dashboard** (`/aiq`) whenever you log in: it lists what deserves your attention, ranked by what acting now is expected to add.

## How the numbers work

**Prices.** AuctionIQ reads prices through TSM, with two formulas of its own:

- *Reagent cost (chmat)*: what buying it costs today, the cheapest listing but never below 80% of market value.
- *Sale value (chvalue)*: the lower of that and the price TSM would post it at.

When you've searched an item at the AH in the last 15 minutes, a reagent is priced from the real listings instead: buying 200 walks up the order book, so it costs what those 200 really cost, not 200 times the cheapest one. Each item in Ready to post shows the AH, TSM and Oribos Exchange prices side by side.

**Cost basis.** How reagents you already hold are counted (Settings, or `/aiq basis`):

| Basis | Reagents cost |
|---|---|
| Held (default) | What the ones you hold would sell for after the cut, and today's price for the rest |
| Replacement | Today's price to buy them all again |
| TSM | TSM's material cost, as you set it up in TSM |
| Paid | What you paid on average over the last 30 days, else today's price |

**Profit per craft.** Multicraft, Resourcefulness, Ingenuity and Concentration use the same formulas as [CraftSim](https://github.com/derfloh205/CraftSim): the extra items Multicraft gives on average, the reagents Resourcefulness hands back, and the Concentration Ingenuity refunds. Revenue is after the 5% AH cut, less the deposits you expect to lose to expired auctions and the cost of gold sitting on the AH while it sells.

**Will it sell?** Each item's chance of selling starts from the region's sale rate (TSM) and moves toward your own record as you sell and expire.

**How many a day?** Batch sizes, gold a day, posting quantities and restocks all rest on how many you can expect to sell a day. AuctionIQ works it out from your own sales, but only on the days you had the item listed, since a day with nothing up says nothing about demand. A listed day is a day you sold, expired or cancelled one, or a day AuctionIQ saw it among your auctions. While you have only a few listed days, the estimate leans on TSM's region sold a day instead. That figure is every realm in the region, so it counts at most 10 a day (`/aiq cap 20` to change). After a few weeks of listing, your own pace takes over. Wherever the number appears it says which it is ("your sales", "your sales + region" or "region") and whether the cap applied.

**How often it sells.** The chance a listing sells, behind expected proceeds, Learn and the advisor's sell rate, starts at TSM's region sale rate and moves toward your own last 30 days. Your share is by units (of the auction units that sold or expired, how many sold), but it counts once for each day with a sale or an expiry, not once per unit: the units in one stack sell or expire together, so an expired stack of 20 is one day against the item, not 20 failures, and it doesn't matter how many rows TSM splits a stack into. Vendor and trade sales don't count, since they were never listed. Hovers say what it rests on ("12 sold, 8 expired over 5 days").

**Batch results count only what you crafted.** When a batch's sales are matched, stock you already held before the craft, and stock you bought afterwards, are counted as selling first. Which unit really sold can't be known, so this is the cautious reading: a resold stack never makes a batch look better, or moves the advisor's price shading. The batch's hover says how many sales went to that other stock. Batches crafted before this change have no record of what you held, so for them only later purchases count.

**How many to make?** The Craft card's Suggested row keeps three numbers apart: how many you can make, how many you can afford, and how many AuctionIQ suggests. The suggestion is only as specific as the evidence. With a few weeks of your own sales it gives a size ("Make 12"). With thin evidence it says so and offers a small trial covering about two days of sales ("Try 4"). When your stock already covers the next few days it says "Hold off", and how many days your stock covers. Hover the row to see what it rests on, your expected week at 5, 10 and 20 (and at the quantity you set), the assumptions, and what would change the suggestion. It is optional: set any quantity with the stepper and queue it. When you queue a different number, AuctionIQ saves both. Accounting > Reports > Performance > Batch results then judges the batch against what you chose, and its hover says "You chose 20 (suggested 8)" with what the suggested size would have brought in by now (modeled), so you can see whether going your own way paid off. The Craft pane in Compare crafts uses the same suggestion and shows it beside a Dashboard hand-off's quantity when the two differ.

**Dashboard ranking.** Recommendations cards rank by one number: the expected gain from acting now over the next week, after the AH cut and expected deposits (shown as `+250g exp.`). Spending Concentration counts what the points add over the plain craft, not the whole craft's profit. Posting counts what Trade would post, at what a listing is worth to you. Restocking counts the last scan's profit for the crafts it takes. Past sales, reagent costs and stock values are shown on hover as evidence, labelled, but never ranked against a gain. A card with no estimate (no scan yet, say) shows no gold and ranks by urgency. Hover a card to see what its gain rests on.

**Learning from results.** Every craft saves what was expected. Later sales are matched to it, and items that keep selling under the forecast are shaded down in the rankings.

**Presets.** Each specialization preset is the knowledge point planner run for one focus, then tested in 200 market simulations: each draws selling prices, reagent costs and sales from how much the item's price has moved over the last 30 days. Every preset gets the same draws, so "wins" is a fair head to head.

## Saved data

Everything stays on your PC in `WTF\Account\<account>\SavedVariables\AuctionIQ.lua`. AuctionIQ reads TSM's saved data but never writes to it, and sends nothing anywhere.

A TSM full scan shows AuctionIQ twenty thousand items, so cleanup runs on its own every time you log out or `/reload`. It keeps what you hold, sold in the last 30 days, craft, queue, alert on or searched yourself, and drops the rest (they come back the next time the AH shows them). It also drops a character's data for professions it no longer has. The days each item was listed are kept for 60 days, one small number per item per day.

**Clean up** (Settings, Saved data, or `/aiq cleanup`) also lets go of what AuctionIQ keeps only for speed: cached prices, auction depth, TSM's parsed records and their time order, demand, forecasts and the advisor's worked-out results. The game's collector then runs a few milliseconds a frame, and the chat line gives addon memory before and after. The figure counts every addon, and any garbage that was already waiting. TSM's records then come back in the background, so the next Dashboard isn't a cold one. Clean up never touches your queue, settings, groups, crafting records, decisions or history.

**Prune history** follows TSM's rule for old data (TSM Settings, Accounting, Clear Old Data). You choose the age, 365 days to start, and it lists what will go and asks before removing anything. It covers AuctionIQ's own day-by-day sales totals, net worth days and competition notes. Days you prune stay gone even while TSM still has their records. Your TSM data is left alone; clear it in TSM if you want it gone there too. Crafting records follow CraftSim's rule instead: they have no age limit and go only when the profession does. AuctionIQ keeps the newest 5,000 craft batches, so the saved file stays a safe size. `/aiq prune 365` does the same from chat.

## FAQ

**The recipe list is empty.** Open the profession window (not just the spellbook), then `/aiq scan`. Each profession's data loads only on characters that have it.

**Prices look wrong or missing.** Check that TSM is installed and has seen prices recently (visit the AH). Open the item in Ready to post and look at its Sources line: if the AH, TSM and Oribos disagree, the AH scan is the one you saw yourself.

**Profits look too high.** Try the Replacement basis, and look at the craft card's break-even and downside lines. A high profit on an item that rarely sells shows a low chance to sell.

**I updated and nothing changed.** Restart the game completely; `/reload` doesn't load new addon files.

**It feels slow.** Type `/aiq perf` and include what it prints when you [open an issue](https://github.com/Courtizy/AuctionIQ/issues).

## Chat Commands

`/aiq` - open or close the window<br>
`/aiq dashboard`, `operations` (or `craft`, `trade`, `shopping`), `accounting` - open a tab<br>
`/aiq settings` - open Settings<br>
`/aiq scan` - rank every recipe of the open profession<br>
`/aiq advisor` - crafting advisor on or off<br>
`/aiq queue` - craft queue and shopping list<br>
`/aiq plan <goal>` - knowledge point plan, e.g. `/aiq plan potions`<br>
`/aiq results` - your craft results log<br>
`/aiq basis` - cost reagents at what you hold, replacement, TSM's material cost or what you paid<br>
`/aiq cap <n>` - most of the region's sold a day counted per item, until your own sales take over (default 10)<br>
`/aiq alerts` - chat alerts on or off<br>
`/aiq minimap` - hide or show the minimap button<br>
`/aiq cleanup` - let go of speed caches and run the saved data cleanup now (the saved part also runs at every logout)<br>
`/aiq prune 365` - remove AuctionIQ history older than 365 days, after showing what goes and asking<br>
`/aiq perf` - memory and time per event, for reporting slowness

## Roadmap

- **[Release](https://github.com/Courtizy/AuctionIQ/milestone/6)**: fix enchanting crafting orders, screenshots, and publishing on CurseForge and Wago.
- **Operations upgrades**: a deal scan for listings well under value, moving items by group to the Warband bank, and buying vendor reagents and selling junk.
- **Deeper analytics**: market charts, where gold earns the most for the gold tied up, risk on stock you hold, and cash flow by profession.
- **Later**: a companion app with a daily price history.

See all [milestones](https://github.com/Courtizy/AuctionIQ/milestones).

## Development

<details>
<summary>Code layout, tests and releases</summary>

Plain Lua, no libraries. The folders follow the tabs: `Dashboard`; `Operations` with `Craft` (advisor,
scans, specializations, plans), `Trade` (posting, groups, markets) and `Queue` (queue, work orders,
shopping, cooldowns); and `Accounting` (statements, ledger, craft results, performance). `Core` (startup,
settings, theme, windows, cleanup, where each view is filed) and `Data` (prices, TSM ledger, forecasts,
statistics) sit underneath them. `Professions` holds one load-on-demand addon per profession
(`AuctionIQ_Alchemy` and so on) with its specialization data.

**Tests:** `python3 tests/run_tests.py` (needs `pip install lupa`) runs the addon in a stubbed WoW
environment, on every pull request.

**Benchmarks:** `python3 tests/bench.py --quick` times scans, the advisor, the ledger and the Dashboard
in the same harness (relative costs, not in-game frame times). TSM's records are read through a
time-ordered view kept until they change (`Ledger.ByTime`, `Ledger.From`), so a range reads only the
records in it. Login's warm-up (`Ledger.WarmAll`) parses them, orders them, builds the day archive and
the indexes a few milliseconds a frame, so the Dashboard's first open finds them ready.

**Releases:** tagging `v*` builds a release with the BigWigs packager.

</details>

## License

MIT. See [LICENSE](LICENSE).
