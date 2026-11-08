# Clearinghouse app

The AuctionIQ companion, in the spirit of TSM's desktop app. It pulls Blizzard's Auction House data
for your realm and the region's commodities about once an hour, keeps the price history on your PC,
and writes it into `Interface\AddOns\Clearinghouse\Data.lua`, which the Clearinghouse addon loads for
AuctionIQ at login or `/reload`.

It only writes into the Clearinghouse addon folder: never WoW's SavedVariables and never TSM's files.

## Controls (tray icon)

| Menu | Does |
|---|---|
| Status... | Last and next sync, items in the data file, days of history, where it writes |
| Sync now | One update right away (works while paused too) |
| Pause | No syncs until you resume; the data file stays as it is |
| Settings... | Region, realm, WoW folder, how often, Blizzard keys, wait while WoW runs |
| Start with Windows | On or off |
| Open log | The app's log file |
| Quit | Closes it fully |

Blizzard keys come from develop.battle.net and are kept in Windows Credential Manager. Settings,
history (`history.sqlite`) and the log live in `%APPDATA%\Clearinghouse`.

## History

Blizzard's API only gives the auction house as it is now, so the app's history starts the day it
first runs: hourly snapshots for 14 days, daily averages for 400 days. TSM's historical and region
prices stay in AuctionIQ for the long view.

## Build and test

`pip install -r requirements-dev.txt && python -m pytest -q tests`. The Windows program is built by
the "Clearinghouse app" GitHub workflow (PyInstaller), with the addon folder next to it.
