# Clearinghouse app

The AuctionIQ companion, in the spirit of TSM's desktop app. It pulls Blizzard's Auction House data
for your realm and the region's commodities about once an hour, keeps the price history on your PC,
and writes it into `Interface\AddOns\Clearinghouse\Data.lua`, which the Clearinghouse addon loads for
AuctionIQ at login or `/reload`.

It only writes into the Clearinghouse addon folder: never WoW's SavedVariables and never TSM's files.

## Install

Download `Clearinghouse-Setup.exe` from the newest `companion-v*` release on GitHub and run it. No admin
prompt; it installs for you alone. The app checks for new releases when it starts and offers
**Update and restart** at the top of the window.

## Setup

The first time it opens, Clearinghouse asks for three things, like TSM's app:

1. **Log in** with your Clearinghouse user name and password. They are checked by the key server
   (`server/` in this repo), which keeps the Blizzard API keys, so nothing secret is in the download.
   The app keeps only a device token, in Windows Credential Manager.
2. **Pick your region and realm** from Blizzard's realm list.
3. That's it. World of Warcraft is found from the registry (you can set its folder in Settings), and
   the first sync starts right away.

## The window

| Page | Shows |
|---|---|
| Overview | Sync status, last and next sync, items priced, days of history, and the week's biggest moves on your realm or in region commodities |
| Markets | A 30-day chart (market and lowest listing) for any mover, with its volatility |
| Settings | Account, region and realm, WoW folder, how often, wait while WoW runs, start with Windows, updates, log |

Closing the window keeps the app in the tray. The tray menu has Open, Sync now, Pause, Start with
Windows, Open log and Quit. Settings, history (`history.sqlite`) and the log live in
`%APPDATA%\Clearinghouse`. Item names come from AuctionIQ's saved names, read only.

## History

Blizzard's API only gives the auction house as it is now, so the app's history starts the day it
first runs: hourly snapshots for 14 days, daily averages for 400 days. TSM's historical and region
prices stay in AuctionIQ for the long view.

## Build and test

`pip install -r requirements-dev.txt && python -m pytest -q tests`. The window is plain HTML, CSS and JS
in `clearinghouse_app/ui/`; open `index.html` in a browser to preview it with demo data
(`index.html#setup` for the first-run screens).

The "Clearinghouse app" workflow builds the program (PyInstaller) and the installer (Inno Setup) on
every change. To release, bump `__version__` in `clearinghouse_app/__init__.py` and push a matching
tag, for example `companion-v0.2.0` (or publish a release with that tag on GitHub); the workflow adds the installer and the addon zip to it.

Developers can skip the server: set `"use_own_keys": true` in settings.json and store your own keys
with `python -c "from clearinghouse_app import config; config.set_keys('ID', 'SECRET')"`.
