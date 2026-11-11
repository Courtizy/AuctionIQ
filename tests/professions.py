# Every crafting profession's specialization data, checked the same way: the tree holds together,
# every recipe's perks exist, and a fully specced tree gives at least what an empty one does.
# Run from run_tests.py (shares L, check).

# the real data files, loaded fresh: earlier tests swap in small fixture trees
fresh = L.eval("{ }")
for f in sorted((ROOT / "Operations" / "Craft" / "Specs").glob("Spec*.lua")):
    L.eval("function(src, name) return assert(loadstring(src, name)) end")(f.read_text(), f.name)("AuctionIQ", fresh)
L.globals().STUB.freshSpec = fresh.SpecData
pf = L.eval("""(function()
  local out = {}
  local realData = AuctionIQ.SpecData
  AuctionIQ.SpecData = STUB.freshSpec
  for pid, data in pairs(STUB.freshSpec or {}) do
    local r = { name = data.name, nodes = 0, bases = 0, recipes = 0, badPerk = 0, badNode = 0, worse = 0, neg = 0, errs = 0, maxSkill = 0 }
    -- a tree with every node unlocked: once at 0 points, once at max
    local zero, full = { nodes = {} }, { nodes = {} }
    local nodeMax = {}
    for perkID, n in pairs(data.nodes) do
      r.nodes = r.nodes + 1
      if n.base then r.bases = r.bases + 1 end
      if not n.nodeID then r.badNode = r.badNode + 1 end
      if n.nodeID then
        nodeMax[n.nodeID] = math.max(nodeMax[n.nodeID] or 0, n.maxRank or 0, n.unlock or 0)
      end
    end
    for nodeID, mx in pairs(nodeMax) do
      local perks = {}
      for perkID, n in pairs(data.nodes) do if n.nodeID == nodeID and not n.base then perks[perkID] = n.unlock or 0 end end
      zero.nodes[nodeID] = { rank = 0, perks = perks }
      full.nodes[nodeID] = { rank = mx, perks = perks }
    end
    for recipeID, perks in pairs(data.recipes) do
      r.recipes = r.recipes + 1
      for _, perkID in ipairs(perks) do if not data.nodes[perkID] then r.badPerk = r.badPerk + 1 end end
      local ok0, s0 = pcall(AuctionIQ.Spec.RecipeStats, pid, zero, AuctionIQ.Spec.Ranks(zero), recipeID)
      local ok1, s1 = pcall(AuctionIQ.Spec.RecipeStats, pid, full, AuctionIQ.Spec.Ranks(full), recipeID)
      if not (ok0 and ok1) then r.errs = r.errs + 1
      else
        for _, k in ipairs({ "skill", "multicraft", "resourcefulness", "ingenuity", "mcExtra", "resExtra", "refundExtra", "concReduce" }) do
          if (s1[k] or 0) < (s0[k] or 0) then r.worse = r.worse + 1 end
          if (s1[k] or 0) < 0 then r.neg = r.neg + 1 end
        end
        if (s1.skill or 0) > r.maxSkill then r.maxSkill = s1.skill end
      end
    end
    out[pid] = r
  end
  AuctionIQ.SpecData = realData
  return out
end)()""")
names = {}
for pid, r in pf.items():
    names[r.name] = r
    print(f"  {r.name:<15} {pid}: {r.nodes} perks ({r.bases} base), {r.recipes} recipes, best spec skill +{r.maxSkill}")
check("professions: all eight Midnight crafting professions have specialization data",
      sorted(names) == ["Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Inscription", "Jewelcrafting", "Leatherworking", "Tailoring"])
check("professions: every recipe's perks exist in its tree, and every perk names its node",
      all(r.badPerk == 0 and r.badNode == 0 for r in pf.values()))
check("professions: every recipe's spec stats work out without error, never negative",
      all(r.errs == 0 and r.neg == 0 for r in pf.values()))
check("professions: a fully specced tree gives every recipe at least what an empty one does",
      all(r.worse == 0 for r in pf.values()))
check("professions: a full tree adds skill to some recipe in every profession", all(r.maxSkill > 0 for r in pf.values()))

# Enchant scroll table: two or three ranks per enchant, all distinct item IDs
es = L.eval("""(function()
  local n, bad, dup = 0, 0, 0
  for cd, q in pairs(AuctionIQ.EnchantScrolls or {}) do
    n = n + 1
    if #q < 1 or #q > 3 then bad = bad + 1 end
    local ids = {}
    for _, id in ipairs(q) do if ids[id] then dup = dup + 1 end; ids[id] = true end
  end
  return { n = n, bad = bad, dup = dup }
end)()""")
check("enchanting: the scroll table has 148 enchants with 1 to 3 distinct ranks each (two enchants may share a scroll, as in the game data)", es.n == 148 and es.bad == 0 and es.dup == 0)

# Recipe kinds across professions, through advisor -> queue -> shopping list
kinds = L.eval("""(function()
  local ui = C_TradeSkillUI
  local oldInfo, oldSch, oldIDs = ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetAllRecipeIDs
  STUB.prices["i:400"] = { formula_value = 30 * 10000, sold = 20 }
  ui.GetRecipeInfo = function(id)
    -- 13: no qualities at all (Cooking, or a pattern with one result)
    if id == 13 then return { learned = true, name = "Plain Stew", supportsQualities = false } end
    if id == 14 then return { learned = true, name = "Prospecting", isSalvageRecipe = true } end
    if id == 15 then return { learned = true, name = "Recraft", isRecraft = true } end
    if id == 16 then return { learned = true, name = "Mining", isGatheringRecipe = true } end
    return oldInfo(id)
  end
  ui.GetRecipeSchematic = function(id, ...)
    if id == 13 then return { recipeID = 13, outputItemID = 400, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {
      { reagentType = 1, required = true, dataSlotIndex = 1, quantityRequired = 2, reagents = { { itemID = 205 } } } } } end
    return oldSch(id, ...)
  end
  ui.GetAllRecipeIDs = function() return { 10, 11, 12, 13, 14, 15, 16 } end
  local out = {}
  local recipes = {}
  for _, id in ipairs(AuctionIQ.Scan.Recipes()) do recipes[id] = true end
  out.excluded = not recipes[14] and not recipes[15] and not recipes[16]
  out.included = recipes[10] and recipes[11] and recipes[12] and recipes[13]
  local function flow(id)
    local ok, res = pcall(AuctionIQ.Advisor.Analyze, id, { professionID = AuctionIQ.OpenProfessionID() })
    if not ok then return "error: " .. tostring(res) end
    if not (res and res.best) then return "no option" end
    local e = AuctionIQ.Queue.FromRow(res, res.best)
    e.qty = 2
    local shop = AuctionIQ.Queue.ShoppingList({ e })
    if #shop == 0 then return "empty shopping list" end
    return "ok"
  end
  out.plain = flow(13)
  out.quality = flow(11)
  local oldGII = C_Item.GetItemInfo
  C_Item.GetItemInfo = function(id) if id == 320 then return "Test Rod", nil, 3, 200 end return oldGII and oldGII(id) end
  out.gear = flow(12)
  C_Item.GetItemInfo = oldGII
  ui.GetRecipeInfo, ui.GetRecipeSchematic, ui.GetAllRecipeIDs = oldInfo, oldSch, oldIDs
  return out
end)()""")
check("recipe kinds: the scan skips salvage (prospecting, milling), recrafts and gathering, keeps crafts with and without qualities",
      kinds.excluded and kinds.included)
check("recipe kinds: no-quality, quality and gear (item level) recipes each go advisor -> queue -> shopping list",
      kinds.plain == "ok" and kinds.quality == "ok" and kinds.gear == "ok")
if not (kinds.plain == "ok" and kinds.gear == "ok"): print("  ", kinds.plain, kinds.quality, kinds.gear)

# Theme: pixel-perfect at two UI scales (and a resized main window). Every plain panel border is one
# screen pixel; the windows sit on whole pixels per unit.
px = L.eval("""(function()
  local out = {}
  if not AuctionIQ.UI.IsShown() then AuctionIQ.UI.Toggle() end
  if AuctionIQ.AdvisorUI and AuctionIQ.AdvisorUI.Show then pcall(AuctionIQ.AdvisorUI.Show) end
  for _, case in ipairs({ { 0.64, 1440, 1 }, { 1.0, 1080, 1 }, { 0.71, 1440, 1.15 }, { 0.53333, 1440, 1 } }) do
    STUB.uiScale, STUB.screenH = case[1], case[2]
    STUB.Fire("UI_SCALE_CHANGED")
    AuctionIQ.UI.SetScale(case[3])
    local n, off, worst = 0, 0, 0
    for _, f in ipairs(STUB.frames) do
      local e = rawget(f, "aiqEdge")
      -- only frames that are on screen: their parents lead to UIParent (test fixtures made with no
      -- parent are never drawn)
      local r = f
      while type(rawget(r, "parent")) == "table" and rawget(r, "parent") ~= UIParent do r = rawget(r, "parent") end
      if type(e) == "number" and rawget(r, "parent") == UIParent then
        n = n + 1
        local pxl = e * f:GetEffectiveScale() * case[2] / 768
        if math.abs(pxl - 1) > 0.01 then off = off + 1; worst = math.max(worst, math.abs(pxl - 1)) end
      end
    end
    local ppu = {}
    for _, name in ipairs({ "AuctionIQAdvisor", "AuctionIQTabs" }) do
      local f = _G[name]
      if f and f.GetEffectiveScale then
        local v = f:GetEffectiveScale() * case[2] / 768
        ppu[#ppu + 1] = math.abs(v - math.floor(v + 0.5)) < 0.01
      end
    end
    out[#out + 1] = { scale = case[1], h = case[2], user = case[3], panels = n, off = off, worst = worst,
      whole = (ppu[1] ~= false and ppu[2] ~= false) }
  end
  STUB.uiScale, STUB.screenH = nil, nil
  STUB.Fire("UI_SCALE_CHANGED")
  AuctionIQ.UI.SetScale(1)
  return out
end)()""")
for c in px.values():
    print(f"  UI scale {c.scale} at {c.h}p, window size {c.user}: {c.panels} panels, {c.off} borders off one pixel (worst {c.worst:.2f}), whole pixels per unit: {c.whole}")
check("theme: at UI scales 0.53, 0.64, 0.71 and 1.0 (and a resized window) every panel border is exactly one screen pixel",
      all(c.panels > 0 and c.off == 0 for c in px.values()))
check("theme: the advisor and the tab strip sit on whole screen pixels per unit at every UI scale", all(c.whole for c in px.values()))
