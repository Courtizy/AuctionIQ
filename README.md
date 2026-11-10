<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Media/Logo-Readme-Dark.png">
    <img src="Media/Logo-Readme-Light.png" width="600" alt="AUCTIONIQ: economic intelligence for the Auction House">
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

- **One window, four tabs**: everything a gold-maker needs, from the first scan to the final tally
- **Know what's worth crafting**: every recipe ranked by profit, Concentration included
- **Compare reagent costs**: the advisor looks for the cheapest mix for each quality
- **Know where an estimate breaks**: break-even sale price per item, a downside scenario, what Concentration adds over the plain craft per point, and what each sales estimate rests on
- **Analyze a batch**: the chance a week's sales pay back 10, 30 or 100 crafts, the cash that comes back and the stock left
- **Work orders worth taking**: commission, rewards and knowledge points at a glance
- **A plan for every knowledge point**, drawn right on your profession trees
- **Plan crafting, shopping, auctions and mail** across your warband
- **Compare price sources**: your own AH scans side by side with TSM and Oribos Exchange
- **Track sales, costs and estimated profit**, with 7, 30 and 90 day reports

| | The question it answers | Inside |
|---|---|---|
| <img src="Media/readme/Tab-Dashboard.png" width="28" height="28" alt=""> **Dashboard** | What should I do next? | Next Move, Concentration, stock and work that needs you |
| <img src="Media/readme/Tab-Operations.png" width="28" height="28" alt=""> **Operations** | What should I craft, buy or post? | Professions, Markets, Queue, Stock |
| <img src="Media/readme/Tab-Accounting.png" width="28" height="28" alt=""> **Accounting** | What happened, and what should I learn from it? | Overview, Revenue, Expenses, Profit, Performance |

## Look and branding

AuctionIQ is styled after [ToxiUI](https://toxiui.com)'s Dark look: graphite panels, black borders,
soft shadows and Montserrat titles. Every title bar carries the brand, **AUCTIONIQ**,
with the IQ in the theme colour.

| You run | Theme colour (IQ, accent, active tab, selection) | Progress bars |
|---|---|---|
| ToxiUI | ToxiUI's theme colour, so it changes with your class as you swap characters (pink on a Paladin, blue on a Mage) | ToxiUI's class gradient, from its own settings |
| ElvUI | ElvUI's value colour | A shade of that colour into it |
| Neither | AuctionIQ blue `#3fc7eb` | AuctionIQ blue's gradient, `#0080d7` to `#00d8ff` |

The Accounting tab keeps its plum and parchment, with the brand's IQ still in the theme colour.
`/aiq theme` also takes ElvUI's backdrop and border colours. The full palette is in [THEME.md](THEME.md).

## AddOns

AuctionIQ loads on its own. Install [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)
for pricing and sales history; [Oribos Exchange](https://www.curseforge.com/wow/addons/oribos-exchange) is optional.

## Install

1. Download the zip from [Releases](https://github.com/Courtizy/AuctionIQ/releases), or for now
   **Code > Download ZIP** on this page.
2. Unzip it into `World of Warcraft\_retail_\Interface\AddOns` and make sure the folder is named
   `AuctionIQ` (rename `AuctionIQ-main` if that's what you got).
3. Log in and open each profession window once, so AuctionIQ learns your recipes.
4. Type `/aiq` to open AuctionIQ. For crafting, open a profession and type `/aiq scan` to get started.

## Chat Commands

`/aiq` - open or close the window<br>
`/aiq dashboard`, `research`, `operations`, `accounting` - open a tab<br>
`/aiq advisor` - crafting advisor on or off<br>
`/aiq queue` - craft queue and shopping list<br>
`/aiq scan` - rank every recipe of the open profession<br>
`/aiq basis` - cost reagents at replacement (chmat), TSM's material cost or what you paid<br>
`/aiq plan <goal>` - knowledge point plan, e.g. `/aiq plan potions`<br>
`/aiq minimap` - hide or show the minimap button

## Roadmap

See the [milestones](https://github.com/Courtizy/AuctionIQ/milestones).

## Development

<details>
<summary>Code layout, tests and releases</summary>

Plain Lua, no libraries. Folders `Dashboard`, `Operations` and `Accounting` follow the tabs; `Research`
holds the crafting advisor, scans, specializations and the views that fill Operations › Professions and
Markets and Accounting › Performance. `Core` and `Data` sit underneath them. The look is described in [THEME.md](THEME.md).

**Tests:** `python3 tests/run_tests.py` (needs `pip install lupa`) runs the addon in a stubbed WoW
environment, on every pull request.

**Releases:** tagging `v*` builds a release with the BigWigs packager.

</details>

## License

MIT. See [LICENSE](LICENSE).
