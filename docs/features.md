# Feature reference

[Back to the README](../README.md)

## Features

**Craft**
- **Every recipe ranked by profit**, Concentration included, for the expansion the profession window has open
- **A craft card beside the profession window**: the best quality to aim for, the cheapest reagent mix for it, an on/off Concentrate switch, and one click to queue it
- **Where an estimate breaks**: break-even sale price, a downside scenario, what Concentration adds per point, and what each sales estimate rests on
- **Your options side by side**: craft it, sell the reagents you hold, buy out the item and relist it, or keep what you have. All are measured the same way: gold gained against keeping what you hold, at today's prices after the AH cut, for one craft's worth. When the profession scan is over 12 hours old or the item has no price, the card says to refresh first.
- **Batch odds**: the chance a week's sales pay back 10, 30 or 100 crafts, the gold that comes back and the stock left, from 1,000 simulated weeks that draw each craft's Multicraft and Resourcefulness procs, one price shock and the week's sales
- **Work orders worth taking**: commission, rewards and knowledge points against what the reagents cost you
- **Specialization presets and a tree calculator**: a build for each thing a profession sells (Light or Void potions, Flasks, Disenchanting...), tested against your own prices, and nodes you can click to try points of your own

**Queue**
- **A craft queue and shopping list** for every character, with stock targets that cover a week of sales

**Markets** (in Accounting)
- **Market trends**: trend, volatility and liquidity for every item in your groups and for each group, with each item's daily price charted
- **Risk**: for what you hold and have up, how far its price could fall while it sells (from its volatility) and the gold exposed and at risk
- **Capital allocation**: where your gold earns the most gold a day for the gold tied up, across profitable crafts, with your gold split best return first
- **Ready to post**: what you hold across the Warband, what's already up and how many to post under each group's rules. You post through TSM.
- **Your TSM setup, read back**: for an item or a TSM group, the Auctioning, Crafting and Shopping operation that applies, whether the group sets it or inherits it, every setting as TSM saved it and what it comes to for the item now, which other groups use the same operation, and what AuctionIQ can't read reliably (`/aiq tsm`)
- **Tune TSM suggestions**: for each TSM group, the one change to its operation with the strongest evidence from your last 30 days (post cap, duration, auctioning minimum, shopping maximum, or cancel and repost), with the numbers behind it, a value to copy into TSM, and its effect marked as projected (`/aiq tune`). Its thresholds are yours to change in Settings, Tune TSM
- **What you changed, and what it did**: each suggestion is recorded; a change you make in TSM is seen at the next load, and the days after it are compared with as many days before on net profit, units sold, expirations, gold tied up and posting sessions, observed beside projected (`/aiq tune log`, `/aiq tune compare <n>`)

**Accounting**
- **Income statement, balance sheet and cash flow** from TSM's records, with every line opening the transactions behind it on the statement's own period. The cash flow reconciles opening gold to closing gold: what the ledger classifies, plus the unclassified rest (transfers, mail and anything TSM didn't log), labelled as such
- **Performance**: eight weeks of profit and what drove the change, item by item, each opening the sales or Profit drivers behind it on the same period and character (Accounting > Statements > Performance)
- **By profession**: each profession's sales, profit, margin and the crafted stock it has made, with days to turn it, and your inventory turnover (Accounting > Statements > Performance > Profession)
- **Companion app**: a Python script on your PC that keeps a year of your daily scanned prices, from every WoW account, and loads the last 180 days back into the game for Market trends and Risk
- **Forecast against actual**: what each craft was expected to make and what it really sold for, so items that keep falling short drop down the rankings

| | The question it answers | Inside |
|---|---|---|
| <img src="../Media/readme/Tab-Dashboard.png" width="28" height="28" alt=""> **Overview** | What should I do next? | The gold trend, then gold, stock value and net worth, what changed the gold, and the Next moves that matter most |
| <img src="../Media/readme/Tab-Operations.png" width="28" height="28" alt=""> **Crafting** | What should I craft, and how many? | Craft (Compare crafts, Specialization), Queue (queue, shopping, restock) |
| <img src="../Media/readme/Tab-Accounting.png" width="28" height="28" alt=""> **Accounting** | What happened, and what should I learn from it? | Statements (P&L, balance, cash flow, performance), Ledger, Markets (trends, risk, capital, ready to post) |

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
   folder in `AuctionIQ\Professions` (`AuctionIQ_Alchemy` and so on, and `AuctionIQ_Paths`) up into `AddOns`; the release zip
   already has them there.
3. Restart the game completely (a `/reload` doesn't pick up new addon files).

## Your first 10 minutes

1. **Open each profession window once** on each crafter, so AuctionIQ learns your recipes, stats and specialization. It reads every recipe the profession has a few milliseconds a frame, and not again for five minutes, so opening the window doesn't stall.
2. **Visit the Auction House** and let TSM (or your own searches) look at prices. AuctionIQ keeps what the AH shows you and uses it beside TSM's numbers.
3. **Rank your recipes.** With a profession open, type `/aiq scan`. Every recipe is listed by gold a day, with and without Concentration.
4. **Read the craft card.** Pick a recipe and the card beside the profession window shows the quality to aim for, the reagents to use, the profit and where that estimate could go wrong. Flip the Concentrate switch to compare.
5. **Queue it.** Add the craft to the queue. The shopping list fills in with the reagents you're missing.
6. **Buy and post at the AH.** Buy the shopping list with TSM's Shopping tab. Post what you've made with TSM's Post scan.
7. **Check the Overview** (`/aiq`) whenever you log in: it lists what deserves your attention, ranked by what acting now is expected to add.

## Chat commands

`/aiq` - open or close the window<br>
`/aiq overview` (or `dashboard`), `crafting` (or `craft`, `operations`, `trade`, `shopping`), `accounting` - open a tab<br>
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
`/aiq orders` - what the advisor makes of each crafting order, kept in the saved variables for a bug report<br>
`/aiq tsm <item link, item ID or TSM group>` - how TSM is set up for it, e.g. `/aiq tsm Alchemy/Flasks`<br>
`/aiq tune` - the strongest suggested change for each TSM group, e.g. `/aiq tune 10` for ten; `/aiq tune log`, `compare <n>`, `changed <n>`, `drop <n>` for the record<br>
`/aiq perf` - memory and time per event, for reporting slowness

## FAQ

**The recipe list is empty.** Open the profession window (not just the spellbook), then `/aiq scan`. Each profession's data loads only on characters that have it.

**Prices look wrong or missing.** Check that TSM is installed and has seen prices recently (visit the AH). Open the item in Ready to post and look at its Sources line: if the AH, TSM and Oribos disagree, the AH scan is the one you saw yourself.

**Profits look too high.** Try the Replacement basis, and look at the craft card's break-even and downside lines. A high profit on an item that rarely sells shows a low chance to sell.

**I updated and nothing changed.** Restart the game completely; `/reload` doesn't load new addon files.

**It feels slow.** Type `/aiq perf` and include what it prints when you [open an issue](https://github.com/Courtizy/AuctionIQ/issues). The costliest 20 timings are also saved at logout or `/reload`, under `debug.perf` in `WTF/Account/<account>/SavedVariables/AuctionIQ.lua`.
