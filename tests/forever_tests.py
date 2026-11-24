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

print(f"\n{len(fails)} failed" if fails else "\nall Forever checks passed")
sys.exit(1 if fails else 0)
