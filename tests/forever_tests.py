"""Loads AuctionIQ the way WoW: Forever does (AuctionIQ_Camelot.toc, WOW_PROJECT_ID 18) and checks
that the Forever build starts, detects the game and opens its window without errors.
Run: python3 tests/forever_tests.py   (needs `pip install lupa`)"""
import sys
from pathlib import Path

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
toc = (ROOT / "AuctionIQ_Camelot.toc").read_text().splitlines()
files = [l.strip().replace("\\", "/") for l in toc if l.strip().endswith(".lua")]
L = LuaRuntime(unpack_returned_tuples=True)
L.execute((ROOT / "tests" / "wow_stub.lua").read_text())
L.execute("WOW_PROJECT_ID = 18; WOW_PROJECT_MAINLINE = 1")
ns = L.table()
for f in files:
    chunk = L.eval("function(src, name) return assert(loadstring(src, name)) end")((ROOT / f).read_text(), f)
    chunk("AuctionIQ", ns)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)

run = L.execute
check("interface 16001 in the Forever TOC", "## Interface: 16001" in toc)
check("no retail-only files in the Forever TOC",
      not any(x in f for f in files for x in ("Orders.lua", "Concentration", "Spec", "Professions/")))
check("every file in the Forever TOC exists", all((ROOT / f).exists() for f in files))
run('STUB.Fire("ADDON_LOADED", "AuctionIQ"); STUB.Fire("PLAYER_LOGIN")')
A0 = L.globals().AuctionIQ
check("saved data reaches the current version without the retail modules", A0.db.version == A0.DB_VERSION)
A = L.globals().AuctionIQ
check("game detected as forever", A.Game == "forever" and A.IsForever() and not A.IsRetail())
check("other project IDs", (A.DetectGame(1), A.DetectGame(18), A.DetectGame(5)) == ("retail", "forever", "other"))
check("saved data set up", A.db is not None and A.db.settings is not None)
tabs = [A.Shell.Tabs()[i][2] for i in range(1, len(A.Shell.Tabs()) + 1)]
check("Forever tabs are Craft and Analytics", tabs == ["Craft", "Analytics"])
rt = A.Shell.Tabs("retail")
check("retail tabs add Work Orders in the middle", [rt[i][2] for i in range(1, len(rt) + 1)] == ["Craft", "Work Orders", "Analytics"])
run('SlashCmdList.AUCTIONIQ("")')
check("/aiq opens the window on Craft", A.Shell.IsShown() and A.Shell.current == "craft")
run('SlashCmdList.AUCTIONIQ("sales")')
check("/aiq sales opens Analytics", A.Shell.current == "analytics")
run('SlashCmdList.AUCTIONIQ("orders")')
check("/aiq orders isn't a Forever tab", A.Shell.current == "analytics")
run('SlashCmdList.AUCTIONIQ("")')
check("/aiq again closes it", not A.Shell.IsShown())
run('SlashCmdList.AUCTIONIQ("scan")')
check("an older command doesn't error on Forever", True)
run('AuctionIQ_OnAddonCompartmentClick()')
check("the addon compartment opens it", A.Shell.IsShown())

# realm: Forever answers the ruleset name at load, then an empty string
check("realm read at load is kept when GetRealmName goes blank", (run('GetRealmName = function() return "" end') or True) and A.RealmName() == "Emerald Dream")
run('AuctionIQ.db.characters = { ["Seyko-"] = { name = "Seyko", realm = "", gold = 5 } }')
me = A.Me()
check("a record saved under a blank realm moves to the right key",
      A.db.characters["Seyko-Emerald Dream"] is not None and A.db.characters["Seyko-"] is None and me.gold == 5 and me.realm == "Emerald Dream")

# sortable tables
rows = L.eval("""{ { name = "B", profit = 5 }, { name = "A", profit = 9 }, { name = "C", profit = 5 },
  { name = "X", profit = 99, last = true }, { name = "D" } }""")
A.Table.Sort(rows, "profit", "desc")
check("sort desc, ties by name, missing values after, pinned rows last",
      [rows[i].name for i in range(1, 6)] == ["A", "B", "C", "D", "X"])
A.Table.Sort(rows, "profit", "asc")
check("sort asc keeps missing values after and pinned rows last",
      [rows[i].name for i in range(1, 6)] == ["B", "C", "A", "D", "X"])
cols = L.eval("""{ { key = "name", label = "Item", width = 200, default = "asc" },
  { key = "profit", label = "Profit", width = 80, align = "RIGHT" } }""")
w = A.Table.New(L.globals().UIParent, "winners", cols, L.eval('{ "profit", "desc" }'))
lo = A.Table.New(L.globals().UIParent, "losers", cols, L.eval('{ "profit", "desc" }'))
A.Table.Link(w, lo)
A.Table.SetRows(w, L.eval('{ { name = "a", profit = 1 }, { name = "b", profit = 3 } }'), 10)
A.Table.SetRows(lo, L.eval('{ { name = "c", profit = -1 }, { name = "d", profit = -3 } }'), 10)
check("table starts on its default sort", w.rows[1].name == "b" and w.heads[2].text.t.endswith("\u25bc"))
A.Table.Click(w, "name")
check("a header click sorts linked tables together, in the column's default direction",
      w.rows[1].name == "a" and lo.rows[1].name == "c" and lo.sort[1] == "name" and lo.sort[2] == "asc")
A.Table.Click(lo, "name")
check("clicking the same header again flips both", w.rows[1].name == "b" and lo.rows[1].name == "d")
check("the sort is saved per table", A.db.settings.sort.winners[2] == "desc" and A.db.settings.sort.losers[1] == "name")

# header badge and settings
check("badge says Vendor without TSM or Oribos Exchange", (run("TSM_API = nil; OEMarketInfo = nil") or True) and A.Sources.Active().key == "vendor")
run("OEMarketInfo = function() end")
check("Oribos Exchange is next", A.Sources.Active().key == "oe")
run('TSM_API = { GetCustomPriceValue = function(src, item) return nil end }')
check("TSM without market data falls to Oribos Exchange", A.Sources.Active().key == "oe")
run('TSM_API = { GetCustomPriceValue = function(src, item) if src == "DBMarket" then return 1000 end end }')
check("TSM with market data is the source", A.Sources.Active().key == "tsm" and A.Sources.Active().ok)
run('SlashCmdList.AUCTIONIQ("settings")')
check("/aiq settings opens Settings on General", A.Shell.settings.IsShown and A.Shell.settingsPage == "General")
run('AuctionIQ.Shell.OpenSettings("About")')
check("Settings pages switch", A.Shell.settingsPage == "About")

print(f"\n{len(fails)} failed" if fails else "\nall Forever checks passed")
sys.exit(1 if fails else 0)
