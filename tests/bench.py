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
      AuctionIQ.Demand.Clear()
      t0 = os.clock(); AuctionIQ.Demand.Warm(now); out.demandCold = (os.clock() - t0) * 1000
      t0 = os.clock(); for i = 1, 1000 do AuctionIQ.Demand.Estimate(300 + i % 400, now) end; out.demandWarm = (os.clock() - t0) * 1000
      AuctionIQ.db.batchForecasts = {{}}
      for i = 1, 200 do AuctionIQ.db.batchForecasts[i] = {{ at = now - (8 + i % 60) * 86400, item = 300 + (i % 400), p10 = 1, p50 = 2, p90 = 3 }} end
      t0 = os.clock(); AuctionIQ.Decide.Calibration(now); out.calib = (os.clock() - t0) * 1000
      AuctionIQ.db.batchForecasts = nil
      AuctionIQ.UI.SetRange("1M")
      -- the first open with nothing warmed (the Dashboard opened before login's warm-up ran)
      if AuctionIQ.db.ledger then AuctionIQ.db.ledger.days = {{}} end
      t0 = os.clock(); AuctionIQ.UI.DashboardData(now); out.dashFirst = (os.clock() - t0) * 1000
      -- login's warm-up, frame by frame, from freshly parsed records; then the first open
      AuctionIQ.Ledger.ClearStats(); if AuctionIQ.db.ledger then AuctionIQ.db.ledger.days = {{}} end
      local wworst, wframes, wdone = 0, 0, false
      AuctionIQ.Ledger.WarmAll(function() wdone = true end)
      while not wdone and wframes < 10000 do local t1 = os.clock(); STUB.RunTimers(); wworst = math.max(wworst, (os.clock() - t1) * 1000); wframes = wframes + 1 end
      out.warmWorst, out.warmFrames = wworst, wframes
      -- the same warm-up's own steps (time order, archive, demand), with the records parsed
      AuctionIQ.Ledger.ClearStats(); if AuctionIQ.db.ledger then AuctionIQ.db.ledger.days = {{}} end
      for _, k in ipairs(AuctionIQ.Ledger.KINDS) do AuctionIQ.Ledger.Records(k) end
      wworst, wframes, wdone = 0, 0, false
      AuctionIQ.Ledger.WarmAll(function() wdone = true end)
      while not wdone and wframes < 10000 do local t1 = os.clock(); STUB.RunTimers(); wworst = math.max(wworst, (os.clock() - t1) * 1000); wframes = wframes + 1 end
      out.stepWorst, out.stepFrames = wworst, wframes
      t0 = os.clock(); AuctionIQ.UI.DashboardData(now); out.dashCold = (os.clock() - t0) * 1000
      t0 = os.clock(); for i = 1, 10 do AuctionIQ.UI.DashboardData(now) end; out.dashWarm = (os.clock() - t0) * 100
      local m1 = BENCH_MEM()
      for i = 1, 10 do AuctionIQ.UI.DashboardData(now) end
      out.dashGrowth = BENCH_MEM() - m1
      t0 = os.clock(); AuctionIQ.Next.List(); out.nextFirst = (os.clock() - t0) * 1000
      t0 = os.clock(); for i = 1, 5 do AuctionIQ.Next.List() end; out.nextWarm = (os.clock() - t0) * 200
      AuctionIQ.Next.ClearAlternatives()
      t0 = os.clock(); AuctionIQ.Next.Ranked(now); out.rankedFirst = (os.clock() - t0) * 1000
      t0 = os.clock(); AuctionIQ.Next.Ranked(now); out.rankedWarm = (os.clock() - t0) * 1000
      t0 = os.clock(); AuctionIQ.Next.List(now); out.listAgain = (os.clock() - t0) * 1000
      -- Clean up: let go of the caches, then the rebuild in the background, then the same Dashboard
      local before = AuctionIQ.UI.DashboardData(now)
      local cdone, measured = false, nil
      t0 = os.clock(); AuctionIQ.Cleanup.Temporary(function(r) measured = r end, function() cdone = true end); out.cleanTime = (os.clock() - t0) * 1000
      wworst, wframes = 0, 0
      while not measured and wframes < 10000 do local t1 = os.clock(); STUB.RunTimers(); wworst = math.max(wworst, (os.clock() - t1) * 1000); wframes = wframes + 1 end
      out.gcWorst, out.gcFrames = wworst, wframes
      out.cleanFreed = (measured.before - measured.after) / 1024
      wworst, wframes = 0, 0
      while not cdone and wframes < 10000 do local t1 = os.clock(); STUB.RunTimers(); wworst = math.max(wworst, (os.clock() - t1) * 1000); wframes = wframes + 1 end
      out.cleanWorst, out.cleanFrames = wworst, wframes
      local after = AuctionIQ.UI.DashboardData(now)
      out.cleanSame = (before.summary.sales == after.summary.sales and before.gold == after.gold and before.summary.sold == after.summary.sold) and 1 or 0
      return out
    end)()""")
    size = f"{n} sales, 5 chars, {r.bytes // 1024} KB csv"
    rec("ledger", name, size, "parse cold", r.parseCold)
    rec("ledger", name, size, "login background parse, worst frame", r.bgWorst)
    rec("ledger", name, size, "login background parse, frames", r.bgFrames, "frames")
    rec("ledger", name, size, "parse warm (cached)", r.parseWarm)
    rec("ledger", name, size, "parsed records memory", r.mem, "MB")
    rec("ledger", name, size, "recent sales totals", r.recent)
    rec("ledger", name, size, "demand index, cold", r.demandCold)
    rec("ledger", name, size, "demand, 1000 estimates warm", r.demandWarm)
    rec("ledger", name, size, "calibration, 200 forecasts", r.calib)
    rec("ledger", name, size, "login warm-up, worst frame", r.warmWorst)
    rec("ledger", name, size, "login warm-up, frames", r.warmFrames, "frames")
    rec("ledger", name, size, "warm-up after parse, worst frame", r.stepWorst)
    rec("ledger", name, size, "warm-up after parse, frames", r.stepFrames, "frames")
    rec("ledger", name, size, "dashboard first open, nothing warmed", r.dashFirst)
    rec("ledger", name, size, "dashboard refresh cold", r.dashCold)
    rec("ledger", name, size, "dashboard refresh warm", r.dashWarm)
    rec("ledger", name, size, "recommendations list, first", r.nextFirst)
    rec("ledger", name, size, "recommendations list, warm", r.nextWarm)
    rec("ledger", name, size, "recommendation cards, grouped with options", r.rankedFirst)
    rec("ledger", name, size, "recommendation cards, again", r.rankedWarm)
    rec("ledger", name, size, "recommendations list, again", r.listAgain)
    rec("ledger", name, size, "memory growth, 10 refreshes", r.dashGrowth, "MB")
    rec("ledger", name, size, "clean up, time", r.cleanTime)
    rec("ledger", name, size, "clean up, collector worst frame", r.gcWorst)
    rec("ledger", name, size, "clean up, collector frames", r.gcFrames, "frames")
    rec("ledger", name, size, "clean up, memory freed (as reported)", r.cleanFreed, "MB")
    rec("ledger", name, size, "rebuild after clean up, worst frame", r.cleanWorst)
    rec("ledger", name, size, "rebuild after clean up, frames", r.cleanFrames, "frames")
    rec("ledger", name, size, "dashboard same after clean up", r.cleanSame, "yes=1")

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

# 5b. How many to make: Suggest plus the explore sizes, which the Craft card's first draw pays (then kept)
r = L.eval("""(function()
  local res = AuctionIQ.Advisor.Analyze(11, { professionID = AuctionIQ.OpenProfessionID() })
  local inp = AuctionIQ.Decide.BatchInputs(res, res.best)
  if not inp then return { none = true } end
  local D = AuctionIQ.Decide
  local t0 = os.clock(); local sug = D.Suggest(inp, { held = 0 }); D.Quantity(inp, { gold = 1e9, suggest = sug, canMake = 50 })
  return { one = (os.clock() - t0) * 1000 }
end)()""")
if not r["none"]:
    rec("quantity decision", "normal", "suggest + 5/10/20 explore", "card first draw", r.one)

# 5c. Deals over a full scan's worth of items (20k browse rows, 1 in 50 under value)
for name, n in (("normal", 2000), ("large", 20000)):
    r = L.eval(f"""(function()
      local S, G = AuctionIQ.Scans, 10000
      local keep = AuctionIQ.db.scans
      AuctionIQ.db.scans = {{}}
      for i = 1, {n} do
        local id = 500000 + i
        STUB.prices["i:" .. id] = {{ formula_value = 100 * G, mat = 100 * G, sold = 3 }}
        S.RecordBrowse(id, (i % 50 == 0) and 40 * G or 95 * G, 5)
      end
      AuctionIQ.Prices.ClearCache(); AuctionIQ.Deals.Clear()
      local t0 = os.clock(); local list = AuctionIQ.Deals.List(); local one = (os.clock() - t0) * 1000
      AuctionIQ.Deals.Clear(); AuctionIQ.Prices.ClearCache()
      AuctionIQ.Demand.Warm() -- as login's warm-up leaves it
      local job, worst, frames, done = AuctionIQ.Deals.Job(), 0, 0, nil
      while not done and frames < 100000 do local t1 = os.clock(); done = job.step(4); worst = math.max(worst, (os.clock() - t1) * 1000); frames = frames + 1 end
      for i = 1, {n} do STUB.prices["i:" .. (500000 + i)] = nil end
      AuctionIQ.db.scans = keep; AuctionIQ.Deals.Clear(); AuctionIQ.Prices.ClearCache()
      return {{ one = one, worst = worst, frames = frames, found = #list }}
    end)()""")
    size = f"{n} items scanned"
    rec("deals", name, size, "list, in one go", r.one)
    rec("deals", name, size, "background, worst frame", r.worst)
    rec("deals", name, size, "background, frames", r.frames, "frames")
    rec("deals", name, size, "deals found (capped at 50)", r.found, "deals")

# 5d. Market trends over the items in your groups, each with 30 days of daily prices
for name, n in (("normal", 500), ("large", 5000)):
    r = L.eval(f"""(function()
      local G = 10000
      local keep, oldMembers = AuctionIQ.db.scans, AuctionIQ.Groups.Members
      AuctionIQ.db.scans = {{}}
      local members, today = {{}}, math.floor(STUB.now / 86400)
      for i = 1, {n} do
        local id = 600000 + i
        STUB.prices["i:" .. id] = {{ formula_value = 100 * G, sold = 3 }}
        local daily = {{}}
        for d = 29, 0, -1 do daily[#daily + 1] = {{ today - d, G * (90 + (i * 7 + d * 13) % 20), 1 }} end
        AuctionIQ.db.scans[id] = {{ at = STUB.now, min = 100 * G, market = 100 * G, qty = 5, daily = daily }}
        members[id] = "Bench/Group " .. (i % 20)
      end
      AuctionIQ.Groups.Members = function() return members end
      local oldPath = AuctionIQ.Groups.Path
      AuctionIQ.Groups.Path = function(id) return members[id] end
      AuctionIQ.Prices.ClearCache(); AuctionIQ.Demand.Warm(); AuctionIQ.Market.Clear(); AuctionIQ.Market.background = false
      local ctx = {{ now = STUB.now, keepName = function() return true end }}
      local t0 = os.clock(); local rows = AuctionIQ.MarketsUI.VIEWS.markets.rows(ctx); local items = (os.clock() - t0) * 1000
      t0 = os.clock(); AuctionIQ.MarketsUI.VIEWS.markets.rows(ctx); local again = (os.clock() - t0) * 1000
      t0 = os.clock(); local groups = AuctionIQ.MarketsUI.VIEWS.marketgroups.rows(ctx); local g = (os.clock() - t0) * 1000
      AuctionIQ.Market.Clear()
      for i = 1, {n} do STUB.prices["i:" .. (600000 + i)] = nil end
      AuctionIQ.Market.Clear(); AuctionIQ.Prices.ClearCache()
      local job, worst, frames, done = AuctionIQ.Market.Job(), 0, 0, nil
      while not done and frames < 100000 do local t1 = os.clock(); done = job.step(4); worst = math.max(worst, (os.clock() - t1) * 1000); frames = frames + 1 end
      AuctionIQ.Market.Clear()
      AuctionIQ.db.scans, AuctionIQ.Groups.Members, AuctionIQ.Groups.Path = keep, oldMembers, oldPath; AuctionIQ.Prices.ClearCache()
      return {{ tItems = items, tAgain = again, tGroups = g, n = #rows, ng = #groups, worst = worst, frames = frames }}
    end)()""")
    size = f"{n} grouped items, 30 days each"
    rec("market", name, size, "Market trends rows, first", r.tItems)
    rec("market", name, size, "Market trends rows, redrawn", r.tAgain)
    rec("market", name, size, "Market by group rows (items kept)", r.tGroups)
    rec("market", name, size, "background, worst frame", r.worst)
    rec("market", name, size, "background, frames", r.frames, "frames")

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
