"""Memory when the Paths page loads: a synthetic profession the size of a real Midnight tree (3 tabs,
36 nodes with perks, 60 recipes), the page opened with presets worked out in the background, as in
the game. Reports what the page allocates (garbage the collector has to catch up with) and what it
keeps once collected. HARNESS numbers under lupa (Lua 5.1): compare runs, not the game's figures.

Run: python3 tests/paths_mem.py"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lupa.lua51 import LuaRuntime  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def load():
    files = [l.strip().replace("\\", "/") for l in (ROOT / "AuctionIQ.toc").read_text().splitlines() if l.strip().endswith(".lua")]
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute((ROOT / "tests" / "wow_stub.lua").read_text())
    _af = {}
    for _d in sorted((ROOT / "Professions").glob("AuctionIQ_*")):
        _fs = [l.strip() for l in (_d / (_d.name + ".toc")).read_text().splitlines() if l.strip().endswith(".lua")]
        _af[_d.name] = L.table_from([L.table_from([_f, (_d / _f).read_text()]) for _f in _fs])
    L.globals().STUB.addonFiles = L.table_from(_af)
    ns = L.table()
    for f in files:
        L.eval("function(src, name) return assert(loadstring(src, name)) end")((ROOT / f).read_text(), f)("AuctionIQ", ns)
    L.execute('STUB.Fire("ADDON_LOADED", "AuctionIQ"); STUB.Fire("PLAYER_LOGIN"); STUB.Fire("TRADE_SKILL_SHOW"); for i = 1, 5 do STUB.RunTimers() end')
    return L


L = load()
L.execute("""
  local CH = AuctionIQ
  CH.Prices.background = false
  CH.OpenProfessionID = function() return 2906 end
  -- recipes: clones of the stub's 10 and 11 under new ids
  local ui = C_TradeSkillUI
  local info0, sch0, op0 = ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetCraftingOperationInfo
  local function base(id) if id and id >= 10000 then return (id % 2 == 0) and 10 or 11 end return id end
  ui.GetRecipeInfo = function(id) local i = info0(base(id)); if i and id ~= base(id) then local c = {}; for k, v in pairs(i) do c[k] = v end; c.name = "Clone " .. id; c.recipeID = id; return c end; return i end
  ui.GetRecipeSchematic = function(id, ...) local s = sch0(base(id), ...); if s and id ~= base(id) then local c = {}; for k, v in pairs(s) do c[k] = v end; c.recipeID = id; return c end; return s end
  ui.GetCraftingOperationInfo = function(id, ...) return op0(base(id), ...) end
  local ids = {}
  for i = 1, 60 do ids[i] = 10000 + i end
  STUB.recipeIDs = ids
  -- the tree: 3 tabs, each a root with 3 children and 2 grandchildren under each child (12 nodes a tab)
  local nodes, recipes, kids, roots = {}, {}, {}, {}
  local perk = 50000
  local function node(id, parent, stat)
    nodes[id] = { nodeID = id, maxRank = 30, base = true, stats = { [stat] = (stat == "skill") and 1 or 3 } }
    for _, th in ipairs({ 5, 15, 25 }) do
      perk = perk + 1
      nodes[perk] = { nodeID = id, maxRank = 1, unlock = th, stats = { skill = 3 } }
    end
    STUB.ranks[id] = parent and -1 or 5
    if parent then kids[parent] = kids[parent] or {}; table.insert(kids[parent], id) end
  end
  local stats = { "skill", "multicraft", "resourcefulness", "ingenuity" }
  local tabNodes = {}
  for t = 1, 3 do
    local root = 1000 * t
    roots[t] = root
    node(root, nil, "skill")
    tabNodes[t] = { root }
    for c = 1, 3 do
      local child = root + c * 10
      node(child, root, stats[(c % 4) + 1])
      table.insert(tabNodes[t], child)
      for g = 1, 2 do
        local gc = child + g
        node(gc, child, stats[((c + g) % 4) + 1])
        table.insert(tabNodes[t], gc)
      end
      -- 2 more leaves to reach 12 a tab
    end
    for x = 1, 2 do local leaf = root + 900 + x; node(leaf, root, "skill"); table.insert(tabNodes[t], leaf) end
  end
  -- each recipe: its tab's root, one child branch with its grandchildren, and their perks
  for i, id in ipairs(ids) do
    local t = (i % 3) + 1
    local child = 1000 * t + ((i % 3) + 1) * 10
    local list = {}
    for _, n in ipairs({ 1000 * t, child, child + 1, child + 2 }) do
      table.insert(list, n)
      for p, d in pairs(nodes) do if not d.base and d.nodeID == n then table.insert(list, p) end end
    end
    recipes[id] = list
  end
  CH.SpecData[2906] = { name = "Alchemy", recipes = recipes, nodes = nodes }
  C_ProfSpecs.GetSpecTabIDsForSkillLine = function() return { 1, 2, 3 } end
  C_ProfSpecs.GetRootPathForTab = function(tab) return roots[tab] end
  C_ProfSpecs.GetChildrenForPath = function(id) return kids[id] or {} end
  C_ProfSpecs.GetUnlockRankForPerk = function(id) return nodes[id] and nodes[id].unlock or 0 end
  C_ProfSpecs.GetCurrencyInfoForSkillLine = function() return { numAvailable = 40, currencyName = "Knowledge" } end
  STUB.Fire("TRAIT_NODE_CHANGED")
  -- prices for the clones: every recipe sells
  CH.Scan.DailyUnits = function() return 5 end
  for i = 1, 3 do STUB.RunTimers() end
  CH.db.presets = {}
  CH.db.settings.presetsAuto = true
  MEM = { evals = 0 }
  local ev = CH.Advisor.Evaluate
  MEM.evalKB = 0
  CH.Advisor.Evaluate = function(...)
    MEM.evals = MEM.evals + 1
    local a = collectgarbage("count")
    local r = ev(...)
    MEM.evalKB = MEM.evalKB + collectgarbage("count") - a
    return r
  end
  function MEM.kb() return collectgarbage("count") end
""")

kb = L.eval("MEM.kb")
run = L.execute
run('collectgarbage("collect")')
base = kb()
run('collectgarbage("stop")')
a0 = kb()
run('AuctionIQ.PathsUI.Open()')
# the game runs a frame at a time: run the timers until the presets are done, counting frames
frames = L.eval("""function()
  local n = 0
  while AuctionIQ.Presets.Running() and n < 200000 do STUB.RunTimers(); n = n + 1 end
  for i = 1, 3 do STUB.RunTimers() end
  return n
end""")()
alloc = kb() - a0
run('collectgarbage("restart"); collectgarbage("collect")')
kept = kb() - base
n = len(list(L.eval("AuctionIQ.Presets.List(2906)")[0].values()))
evals = L.eval("MEM.evals")
print(f"presets built: {n}, frames: {frames}")
print(f"allocated while the page loads: {alloc / 1024:8.1f} MB")
print(f"kept after a full collect:      {kept:8.1f} KB")
print(f"advisor evaluations:            {evals}  ({L.eval('MEM.evalKB') / 1024:.1f} MB of the allocation)")

# a single plan, synchronously, for the planner on its own
run('collectgarbage("collect"); collectgarbage("stop")')
a0 = kb()
run('AuctionIQ.Paths.Plan({ prof = 2906, goal = "gold", points = 60, sync = true })')
print(f"one plan (60 points, everything): {(kb() - a0) / 1024:8.1f} MB allocated")
run('collectgarbage("restart")')
