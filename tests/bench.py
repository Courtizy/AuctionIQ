"""Harness benchmarks: AuctionIQ loaded in TOC order under the stubbed game (Lua 5.1 via lupa),
timed with os.clock. Seeded, so runs are comparable. These are HARNESS numbers: relative costs and
growth, not in-game frame times (WoW's Lua is faster and its API calls cost more).

Run: python3 tests/bench.py [--quick]"""
import json
import sys
from pathlib import Path

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
QUICK = "--quick" in sys.argv


def load():
    files = [l.strip().replace("\\", "/") for l in (ROOT / "AuctionIQ.toc").read_text().splitlines() if l.strip().endswith(".lua")]
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute((ROOT / "tests" / "wow_stub.lua").read_text())
    # the profession data addons (Professions/AuctionIQ_*), loaded on demand through C_AddOns.LoadAddOn
    _af = {}
    for _d in sorted((ROOT / "Professions").glob("AuctionIQ_*")):
        _fs = [l.strip() for l in (_d / (_d.name + ".toc")).read_text().splitlines() if l.strip().endswith(".lua")]
        _af[_d.name] = L.table_from([L.table_from([_f, (_d / _f).read_text()]) for _f in _fs])
    L.globals().STUB.addonFiles = L.table_from(_af)
    ns = L.table()
    for f in files:
        L.eval("function(src, name) return assert(loadstring(src, name)) end")((ROOT / f).read_text(), f)("AuctionIQ", ns)
    L.execute('STUB.Fire("ADDON_LOADED", "AuctionIQ"); STUB.Fire("PLAYER_LOGIN"); STUB.Fire("TRADE_SKILL_SHOW"); for i = 1, 5 do STUB.RunTimers() end')
    L.execute("""
      math.randomseed(42)
      debugprofilestop = function() return os.clock() * 1000 end
      AuctionIQ.Prices.background = false
      function BENCH_MEM() collectgarbage("collect"); return collectgarbage("count") / 1024 end
      -- clone a stub recipe under new IDs: id >= 10000 behaves like base (10 or 11)
      local ui = C_TradeSkillUI
      local info0, sch0, op0 = ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetCraftingOperationInfo
      local function base(id) if id and id >= 10000 then return (id % 2 == 0) and 10 or 11 end return id end
      ui.GetRecipeInfo = function(id) local i = info0(base(id)); if i and id ~= base(id) then local c = {}; for k, v in pairs(i) do c[k] = v end; c.name = "Clone " .. id; c.recipeID = id; return c end; return i end
      ui.GetRecipeSchematic = function(id, ...) local s = sch0(base(id), ...); if s and id ~= base(id) then local c = {}; for k, v in pairs(s) do c[k] = v end; c.recipeID = id; return c end; return s end
      ui.GetCraftingOperationInfo = function(id, ...) return op0(base(id), ...) end
    """)
    return L


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else 0


rows = []


def rec(area, workload, size, metric, value, unit="ms"):
    rows.append({"area": area, "workload": workload, "size": size, "metric": metric, "value": round(value, 2), "unit": unit})
    print(f"{area:<22} {workload:<10} {size:<28} {metric:<26} {value:>10.2f} {unit}")


L = load()
scan_sizes = [("normal", 5), ("large", 200), ("upper", 1000)] if not QUICK else [("normal", 5), ("large", 100)]

# 1. Profession scan: total time, frames, worst and p95 frame, memory, cold vs warm
for name, n in scan_sizes:
    ids = "{1,2,3,10,11}" if n == 5 else "{" + ",".join(str(10000 + i) for i in range(n)) + "}"
    r = L.eval(f"""(function()
      STUB.recipeIDs = {ids}
      local out = {{}}
      for pass = 1, 2 do
        AuctionIQ.Scan.models = {{}}
        if pass == 1 and AuctionIQ.AdvisorUI.InvalidateKnown then AuctionIQ.AdvisorUI.InvalidateKnown() end
        local m0 = BENCH_MEM()
        local frames, t0 = {{}}, os.clock()
        local started = AuctionIQ.Scan.Run()
        frames[1] = (os.clock() - t0) * 1000 -- the first frame runs inside Run()
        assert(started, "scan didn't start")
        while AuctionIQ.Scan.IsRunning() do
          local f0 = os.clock(); STUB.RunTimers(); frames[#frames + 1] = (os.clock() - f0) * 1000
          if #frames > 200000 then break end
        end
        out[pass] = {{ total = (os.clock() - t0) * 1000, frames = frames, m0 = m0, m1 = BENCH_MEM(),
          rows = #((AuctionIQ.Scan.Results(AuctionIQ.OpenProfessionID()) or {{}}).rows or {{}}) }}
      end
      STUB.recipeIDs = nil
      return out
    end)()""")
    for pass_, label in ((1, "cold"), (2, "warm")):
        p = r[pass_]
        frames = list(p.frames.values())
        size = f"{n} recipes, {p.rows} rows"
        rec("scan", name, size, f"{label} total", p.total)
        rec("scan", name, size, f"{label} frames", len(frames), "frames")
        rec("scan", name, size, f"{label} worst frame", max(frames))
        rec("scan", name, size, f"{label} p95 frame", pct(frames, 0.95))
        rec("scan", name, size, f"{label} Lua memory after", p.m1, "MB")

# 2. Heavy reagent combinations: one recipe, 3 quality slots x 3 ranks, 2 finishing slots x 3 options
for name, qty in (("normal", (4, 5)), ("large", (10, 8)), ("upper", (20, 16))):
    r = L.eval(f"""(function()
      local ui = C_TradeSkillUI
      local old = ui.GetRecipeSchematic
      ui.GetRecipeSchematic = function(id, ...)
        if id ~= 11 then return old(id, ...) end
        return {{ recipeID = 11, outputItemID = 311, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {{
          {{ reagentType = 1, required = true, dataSlotIndex = 1, quantityRequired = {qty[0]}, reagents = {{ {{ itemID = 201 }}, {{ itemID = 202 }}, {{ itemID = 211 }} }} }},
          {{ reagentType = 1, required = true, dataSlotIndex = 2, quantityRequired = {qty[1]}, reagents = {{ {{ itemID = 203 }}, {{ itemID = 204 }}, {{ itemID = 212 }} }} }},
          {{ reagentType = 1, required = true, dataSlotIndex = 3, quantityRequired = {qty[1]}, reagents = {{ {{ itemID = 205 }}, {{ itemID = 221 }}, {{ itemID = 222 }} }} }},
          {{ reagentType = 2, required = false, dataSlotIndex = 5, quantityRequired = 1, reagents = {{ {{ itemID = 221 }}, {{ itemID = 222 }}, {{ itemID = 212 }} }} }},
          {{ reagentType = 2, required = false, dataSlotIndex = 6, quantityRequired = 1, reagents = {{ {{ itemID = 201 }}, {{ itemID = 203 }}, {{ itemID = 205 }} }} }},
        }} }}
      end
      local t0 = os.clock()
      local res = AuctionIQ.Advisor.Analyze(11, {{ professionID = AuctionIQ.OpenProfessionID() }})
      local cold = (os.clock() - t0) * 1000
      t0 = os.clock()
      for i = 1, 5 do AuctionIQ.Advisor.Analyze(11, {{ professionID = AuctionIQ.OpenProfessionID() }}) end
      local warm = (os.clock() - t0) * 1000 / 5
      ui.GetRecipeSchematic = old
      return {{ cold = cold, warm = warm, rows = res and #res.rows or 0 }}
    end)()""")
    size = f"3 slots x3 ranks, qty {qty[0]}/{qty[1]}/{qty[1]}, 2 finishing"
    rec("advisor combos", name, size, "analyze cold", r.cold)
    rec("advisor combos", name, size, "analyze repeat (avg of 5)", r.warm)

# 3. Ledger: TSM accounting with N sales over a year, 5 characters
for name, n in (("normal", 2000), ("large", 50000), ("upper", 200000 if not QUICK else 60000)):
    r = L.eval(f"""(function()
      local now = STUB.now
      local chars = {{ "Courtizy", "Luxaren", "Verathis", "Seyko", "Serynko" }}
      local t = {{ "itemString,stackSize,quantity,price,otherPlayer,player,time,source" }}
      for i = 1, {n} do
        t[#t + 1] = string.format("i:%d,1,%d,%d,Buyer,%s,%d,Auction", 300 + (i % 400), 1 + i % 5, 10000 + (i * 7919) % 5000000, chars[1 + i % 5], now - (i * 31536000 / {n}))
      end
      local sales = table.concat(t, "\\n")
      TradeSkillMasterDB = {{ ["r@" .. GetRealmName() .. "@internalData@csvSales"] = sales,
        ["r@" .. GetRealmName() .. "@internalData@csvBuys"] = "itemString,stackSize,quantity,price,otherPlayer,player,time,source",
        ["s@Courtizy - Alliance - " .. GetRealmName() .. "@internalData@money"] = 1000000 }}
      local m0 = BENCH_MEM()
      local out = {{ bytes = #sales }}
      local t0 = os.clock(); AuctionIQ.Ledger.Records("Sales"); out.parseCold = (os.clock() - t0) * 1000
      AuctionIQ.Ledger.ClearStats()
      local worst, frames, fin = 0, 0, false
      local t1 = os.clock(); AuctionIQ.Ledger.Warm({{ "Sales" }}, function() fin = true end); worst = (os.clock() - t1) * 1000; frames = 1
      while not fin do t1 = os.clock(); STUB.RunTimers(); worst = math.max(worst, (os.clock() - t1) * 1000); frames = frames + 1 end
      out.bgWorst, out.bgFrames = worst, frames
      t0 = os.clock(); AuctionIQ.Ledger.Records("Sales"); out.parseWarm = (os.clock() - t0) * 1000
      out.mem = BENCH_MEM() - m0
      t0 = os.clock(); AuctionIQ.Prices.RecentSales(now, true); out.recent = (os.clock() - t0) * 1000
      AuctionIQ.db.batchForecasts = {{}}
      for i = 1, 200 do AuctionIQ.db.batchForecasts[i] = {{ at = now - (8 + i % 60) * 86400, item = 300 + (i % 400), p10 = 1, p50 = 2, p90 = 3 }} end
      t0 = os.clock(); AuctionIQ.Decide.Calibration(now); out.calib = (os.clock() - t0) * 1000
      AuctionIQ.db.batchForecasts = nil
      AuctionIQ.UI.SetRange("1M")
      t0 = os.clock(); AuctionIQ.UI.DashboardData(now); out.dashCold = (os.clock() - t0) * 1000
      t0 = os.clock(); for i = 1, 10 do AuctionIQ.UI.DashboardData(now) end; out.dashWarm = (os.clock() - t0) * 100
      local m1 = BENCH_MEM()
      for i = 1, 10 do AuctionIQ.UI.DashboardData(now) end
      out.dashGrowth = BENCH_MEM() - m1
      return out
    end)()""")
    size = f"{n} sales, 5 chars, {r.bytes // 1024} KB csv"
    rec("ledger", name, size, "parse cold", r.parseCold)
    rec("ledger", name, size, "login background parse, worst frame", r.bgWorst)
    rec("ledger", name, size, "login background parse, frames", r.bgFrames, "frames")
    rec("ledger", name, size, "parse warm (cached)", r.parseWarm)
    rec("ledger", name, size, "parsed records memory", r.mem, "MB")
    rec("ledger", name, size, "recent sales totals", r.recent)
    rec("ledger", name, size, "calibration, 200 forecasts", r.calib)
    rec("ledger", name, size, "dashboard refresh cold", r.dashCold)
    rec("ledger", name, size, "dashboard refresh warm", r.dashWarm)
    rec("ledger", name, size, "memory growth, 10 refreshes", r.dashGrowth, "MB")

# 4. Queue and shopping list
for name, n in (("normal", 10), ("large", 200), ("upper", 1000)):
    r = L.eval(f"""(function()
      local Q = AuctionIQ.Queue
      Q.Clear()
      local res = AuctionIQ.Advisor.Analyze(11, {{ professionID = AuctionIQ.OpenProfessionID() }})
      for i = 1, {n} do
        local e = Q.FromRow(res, res.best); e.recipeID = 10000 + i * 2 + 1; Q.AddEntry(e, 1 + i % 4)
      end
      local t0 = os.clock(); Q.ShoppingList(); local shop = (os.clock() - t0) * 1000
      t0 = os.clock(); local ok = pcall(Q.Budget); local budget = (os.clock() - t0) * 1000
      t0 = os.clock(); pcall(Q.Readiness); local ready = (os.clock() - t0) * 1000
      local m1 = BENCH_MEM()
      for i = 1, 20 do Q.ShoppingList() end
      local growth = BENCH_MEM() - m1
      Q.Clear()
      return {{ shop = shop, budget = budget, ready = ready, growth = growth }}
    end)()""")
    size = f"{n} entries"
    rec("queue", name, size, "shopping list", r.shop)
    rec("queue", name, size, "budget", r.budget)
    rec("queue", name, size, "readiness", r.ready)
    rec("queue", name, size, "memory growth, 20 lists", r.growth, "MB")

# 5. Batch simulation, repeated
r = L.eval("""(function()
  local res = AuctionIQ.Advisor.Analyze(11, { professionID = AuctionIQ.OpenProfessionID() })
  local inp = AuctionIQ.Decide.BatchInputs(res, res.best)
  if not inp then return { none = true } end
  local t0 = os.clock(); AuctionIQ.Decide.Batch(inp); local one = (os.clock() - t0) * 1000
  t0 = os.clock(); for i = 1, 20 do AuctionIQ.Decide.Batch(inp) end; local avg = (os.clock() - t0) * 1000 / 20
  return { one = one, avg = avg }
end)()""")
if not r["none"]:
    rec("batch simulation", "normal", "default sizes and runs", "first run", r.one)
    rec("batch simulation", "normal", "default sizes and runs", "repeat (avg of 20)", r.avg)

# 6. SavedVariables size (AuctionIQDB as it stands after the runs above)
size = L.eval("""(function()
  local seen, n = {}, 0
  local function walk(v)
    local t = type(v)
    if t == "table" then if seen[v] then return end; seen[v] = true; n = n + 2
      for k, x in pairs(v) do walk(k); walk(x); n = n + 4 end
    elseif t == "string" then n = n + #v + 2 else n = n + 8 end
  end
  walk(AuctionIQ.db)
  return n
end)()""")
rec("saved variables", "after runs", "AuctionIQDB, approx serialized", "size", size / 1024, "KB")

(ROOT / "tests" / "bench-results.json").write_text(json.dumps(rows, indent=1))
