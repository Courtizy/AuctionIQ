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

## Features

- **One window, four tabs**: everything a gold-maker needs, from the first scan to the final tally
- **Know what's worth crafting**: every recipe ranked by profit, Concentration included
- **Never overpay for reagents**: the advisor finds the cheapest mix for every quality
- **Work orders worth taking**: commission, rewards and knowledge points at a glance
- **A plan for every knowledge point**, drawn right on your profession trees
- **One queue for your whole warband**: craft, buy, post and mail, one click at a time
- **Prices you can trust**: your own AH scans checked against TSM and Oribos Exchange
- **Books that balance**: real profit by item, with 7, 30 and 90 day reports
- ...and more!

| | |
|---|---|
| <img src="Media/readme/Tab-Dashboard.png" width="28" height="28" alt=""> **Dashboard** | What needs you right now |
| <img src="Media/readme/Tab-Research.png" width="28" height="28" alt=""> **Research** | What's worth doing |
| <img src="Media/readme/Tab-Operations.png" width="28" height="28" alt=""> **Operations** | Getting it done |
| <img src="Media/readme/Tab-Accounting.png" width="28" height="28" alt=""> **Accounting** | What actually happened |

## Required AddOns

None.

## Supported AddOns

- [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) for prices and sales
  history. Strongly recommended: without it, AuctionIQ can't value items.
- [Oribos Exchange](https://www.curseforge.com/wow/addons/oribos-exchange) for a second opinion on prices.

## Install

1. Download the zip from [Releases](https://github.com/Courtizy/AuctionIQ/releases), or for now
   **Code > Download ZIP** on this page.
2. Unzip it into `World of Warcraft\_retail_\Interface\AddOns` and make sure the folder is named
   `AuctionIQ` (rename `AuctionIQ-main` if that's what you got).
3. Log in and open each profession window once, so AuctionIQ learns your recipes.

## Chat Commands

`/aiq` - open or close the window<br>
`/aiq dashboard`, `research`, `operations`, `accounting` - open a tab<br>
`/aiq advisor` - crafting advisor on or off<br>
`/aiq queue` - craft queue and shopping list<br>
`/aiq scan` - rank every recipe of the open profession<br>
`/aiq plan <goal>` - knowledge point plan, e.g. `/aiq plan potions`<br>
`/aiq minimap` - hide or show the minimap button

## Roadmap

See the [milestones](https://github.com/Courtizy/AuctionIQ/milestones).

## Development

Plain Lua, no libraries. One folder per tab (`Dashboard`, `Research`, `Operations`, `Accounting`),
plus `Core` and `Data` underneath them. The look is described in [THEME.md](THEME.md).

### Tests

`python3 tests/run_tests.py` (needs `pip install lupa`) runs the addon in a stubbed WoW environment.
It runs on every pull request.

### Releases

Tagging `v*` builds a release with the BigWigs packager.

## License

MIT. See [LICENSE](LICENSE).
