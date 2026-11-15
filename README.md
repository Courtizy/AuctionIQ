<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Media/Logo-Readme-Dark.png">
    <img src="Media/Logo-Readme-Light.png" width="600" alt="AUCTIONIQ: intelligence for the Auction House">
  </picture>
</p>

<p align="center">Decide what to craft, how much to make, and whether it paid off.</p>

<p align="center">
  <img src="https://img.shields.io/badge/Status-In%20development-3fc7eb?style=for-the-badge" alt="Status: in development">
  <img src="https://img.shields.io/badge/WoW-Retail-34c77b?style=for-the-badge&logo=battledotnet&logoColor=white" alt="WoW Retail">
  <a href="https://github.com/Courtizy/AuctionIQ/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/Courtizy/AuctionIQ/test.yml?branch=main&style=for-the-badge&label=Tests" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Courtizy/AuctionIQ?style=for-the-badge&color=1a1a1a" alt="License"></a>
</p>

AuctionIQ is an addon for **World of Warcraft Retail** that connects crafting decisions to your own sales history. Compare reagent mixes and Concentration, queue the craft you choose, and see how the forecast held up after selling. AuctionIQ uses TradeSkillMaster for prices and transaction history. Post and cancel through TSM.

[Download a release](https://github.com/Courtizy/AuctionIQ/releases) · [Get started](#get-started) · [Report a bug](https://github.com/Courtizy/AuctionIQ/issues)

<!-- Screenshot: the Craft Advisor with a recipe selected, its reagent cost, what Concentration adds, and the Queue button.
<p align="center"><img src="Media/readme/Craft-Advisor.png" width="800" alt="The Craft Advisor beside the profession window"></p>
-->

## Get started

1. Install **TradeSkillMaster** and extract the AuctionIQ release ZIP into `World of Warcraft\_retail_\Interface\AddOns`. Keep the packaged addon folders as siblings. Restart WoW after installing or updating.
2. Open a profession on your crafter and run `/aiq scan`. Pick a recipe to compare quality, reagent cost, break-even price, and what Concentration adds.
3. Queue the batch and review the shopping list. Post the output through TSM. After sales appear in TSM, open **Accounting** to see how the batch performed.

## Inside AuctionIQ

| Tab | What you can do |
|---|---|
| **Dashboard** | See your gold trend, inventory, and the next actions most worth reviewing. |
| **Operations** | Compare recipes and batch sizes, check work orders, manage the craft queue and shopping list, and review how much stock to list. |
| **Accounting** | Open the Income Statement, Balance Sheet, Cash Flow, or Ledger. Drill into results by item, profession, or batch. |

<!-- Screenshot: Accounting showing the same batch after some of its output has sold.
<p align="center"><img src="Media/readme/Accounting-Batch.png" width="800" alt="A batch's results in Accounting after part of it sold"></p>
-->

Every feature, the full command list and the FAQ are in the [feature reference](docs/features.md).

## What the profit figures mean

- **Forecast** uses the selected material cost basis, expected yield, and selling assumptions at the time of the decision.
- **Craft result** records what was made and values the output and materials at craft-time prices.
- **Realized result** uses observed sales and allocated costs. Unsold output stays visible as stock. Matching sales to batches is an estimate when identical units came from multiple sources.

AuctionIQ estimates sales pace from days you had an item listed and uses regional data when personal history is sparse. Treat a batch recommendation with thin evidence as a trial size. For details on cost bases, sell-through, and attribution, see [How the numbers work](docs/methodology.md).

## Requirements and compatibility

- **WoW Retail (Midnight)** and **TSM** for meaningful prices and accounting data.
- **Oribos Exchange** is optional for additional price context. AuctionIQ supports ElvUI and ToxiUI styling.
- AuctionIQ stores its data locally and reads TSM data without writing to it.

<details>
<summary>Source ZIP installation</summary>

Rename the extracted root folder to `AuctionIQ`. Move the profession addons and `AuctionIQ_Paths` from `AuctionIQ\Professions` into `AddOns` alongside it. See the [package manifest](https://github.com/Courtizy/AuctionIQ/blob/main/.pkgmeta) for the release folder layout.

</details>

## Commands and development

| Command | Action |
|---|---|
| `/aiq` | Open AuctionIQ |
| `/aiq scan` | Rank recipes in the open profession |
| `/aiq queue` | Open the queue and shopping list |
| `/aiq results` | View craft results |
| `/aiq perf` | Show diagnostics for a performance report |

All commands: [feature reference](docs/features.md#chat-commands).

Run `python3 tests/run_tests.py` with Lupa installed. Run `python3 tests/bench.py --quick` for local benchmarks. Code layout, tests and releases are in [Development](docs/development.md). See the [roadmap](https://github.com/Courtizy/AuctionIQ/milestones) and [MIT license](https://github.com/Courtizy/AuctionIQ/blob/main/LICENSE).

