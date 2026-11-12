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

- **One window, three tabs**: everything a gold-maker needs, from the first scan to the final tally
- **Know what's worth crafting**: every recipe ranked by profit, Concentration included, for the expansion the profession window has open
- **A craft card beside the profession window**: the best quality to aim for, an on/off Concentrate switch, work orders and the queue
- **Compare reagent costs**: the advisor looks for the cheapest mix for each quality, priced from the AH listings you've seen, the same way the shopping list prices them
- **Know where an estimate breaks**: break-even sale price per item, a downside scenario, what Concentration adds over the plain craft per point, and what each sales estimate rests on
- **Analyze a batch**: the chance a week's sales pay back 10, 30 or 100 crafts, the cash that comes back and the stock left
- **Work orders worth taking**: commission, rewards and knowledge points at a glance
- **Specialization presets**: a ready-made build for each thing a profession sells (Light or Void potions, Flasks, Disenchanting...), tested in market simulations on your own prices
- **A tree calculator**: click nodes to try points of your own and see what they bring, with the weekly knowledge checklist one click away
- **Plan crafting, shopping and auctions** across your warband
- **Track sales, costs and estimated profit**: statements and a full ledger
- **Light on memory**: each profession's data loads only on characters that have it, and saved data nothing uses is cleared at logout

| | The question it answers | Inside |
|---|---|---|
| <img src="Media/readme/Tab-Dashboard.png" width="28" height="28" alt=""> **Dashboard** | What should I do next? | Next Move, Concentration, stock and work that needs you |
| <img src="Media/readme/Tab-Operations.png" width="28" height="28" alt=""> **Operations** | What should I craft, buy or post? | Craft (Compare crafts, Specialization), Trade (Ready to post, rules), Queue (queue, shopping, restock) |
| <img src="Media/readme/Tab-Accounting.png" width="28" height="28" alt=""> **Accounting** | What happened, and what should I learn from it? | Statements (P&L, balance, cash flow, performance), Ledger |

## AddOns

AuctionIQ loads on its own. Install [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)
for pricing and sales history; [Oribos Exchange](https://www.curseforge.com/wow/addons/oribos-exchange) is optional.

## Install

1. Download the zip from [Releases](https://github.com/Courtizy/AuctionIQ/releases), or for now
   **Code > Download ZIP** on this page.
2. Unzip it into `World of Warcraft\_retail_\Interface\AddOns` and make sure the folder is named
   `AuctionIQ` (rename `AuctionIQ-main` if that's what you got). From the code zip, also move each
   folder in `AuctionIQ\Professions` (`AuctionIQ_Alchemy` and so on) up into `AddOns`; the release zip
   already has them there.
3. Log in and open each profession window once, so AuctionIQ learns your recipes.
4. Type `/aiq` to open AuctionIQ. For crafting, open a profession and type `/aiq scan` to get started.

## Chat Commands

`/aiq` - open or close the window<br>
`/aiq dashboard`, `operations` (or `craft`, `trade`, `shopping`), `accounting` - open a tab<br>
`/aiq advisor` - crafting advisor on or off<br>
`/aiq queue` - craft queue and shopping list<br>
`/aiq scan` - rank every recipe of the open profession<br>
`/aiq basis` - cost reagents at replacement (chmat), TSM's material cost or what you paid<br>
`/aiq plan <goal>` - knowledge point plan, e.g. `/aiq plan potions`<br>
`/aiq settings` - open Settings<br>
`/aiq cleanup` - clear saved data nothing uses (it also runs at logout)<br>
`/aiq perf` - memory and time per event, for reporting slowness<br>
`/aiq minimap` - hide or show the minimap button

## Roadmap

See the [milestones](https://github.com/Courtizy/AuctionIQ/milestones).

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

**Releases:** tagging `v*` builds a release with the BigWigs packager.

</details>

## License

MIT. See [LICENSE](LICENSE).
