"""Build a TSM group import string covering every item worth selling in Classic (WoW: Forever).

Reads the game's own item and spell tables (DB2 exports from wago.tools for the classic_era
product) and writes TSM's plain import text: "group:Path`Sub,i:123,i:456,group:...".

Usage: python tools/tsm_groups_classic.py <db2_csv_dir> <out.txt>
  The directory holds Item, ItemSparse, ItemClass, ItemSubClass, SkillLineAbility, SpellEffect,
  SpellReagents and SkillLine as <Table>.csv (https://wago.tools/db2/<Table>/csv?product=wow_classic_era).

Which items: tradeable (not soulbound on pickup or quest items), common to epic, vanilla IDs, no
test or deprecated items, no white weapons or armour (vendor gear), no class spell books.

Layout (TSM keeps an item in one group, so the first match wins):
  Crafted`<Profession>          what a profession makes (Mining: bars)
  Materials`Herbs, Ore and stone, Cloth, Leather, Enchanting, Meat and fish, Other
                                reagents professions use and don't make
  <Class>`<Subclass>            everything else, by the game's item class (Weapon`Daggers...)
"""
import collections
import csv
import re
import sys
from pathlib import Path

PROFESSIONS = {164: "Blacksmithing", 165: "Leatherworking", 171: "Alchemy", 197: "Tailoring",
               202: "Engineering", 333: "Enchanting", 185: "Cooking", 129: "First Aid", 186: "Mining"}
CREATE_ITEM = "24"
SKIP_CLASS = {"3", "8", "10", "12", "13", "14", "18"}  # obsolete, money, quest, key, token
BAD_NAME = re.compile(r"^(deprecated|monster|test|qa|old |\[ph\]|ph |zz|unused|npc )|\btest\b|deprecated|unused|\bOLD\b|\(old\)", re.I)
HERB_WORDS = ("Peacebloom", "Silverleaf", "Earthroot", "Mageroyal", "Briarthorn", "Swiftthistle", "Bruiseweed",
              "Stranglekelp", "Wild Steelbloom", "Grave Moss", "Kingsblood", "Liferoot", "Fadeleaf", "Goldthorn",
              "Khadgar's Whisker", "Wintersbite", "Firebloom", "Purple Lotus", "Arthas' Tears", "Sungrass",
              "Blindweed", "Ghost Mushroom", "Gromsblood", "Golden Sansam", "Dreamfoil", "Mountain Silversage",
              "Plaguebloom", "Icecap", "Black Lotus", "Wildvine", "Bloodvine")


def rows(d, t):
    return list(csv.DictReader(open(Path(d) / f"{t}.csv", encoding="utf-8")))


def build(d):
    cls = {r["ClassID"]: r["ClassName_lang"].replace("(OBSOLETE)", "") for r in rows(d, "ItemClass")}
    sub = {(r["ClassID"], r["SubClassID"]): (r["VerboseName_lang"] or r["DisplayName_lang"]) for r in rows(d, "ItemSubClass")}
    item = {r["ID"]: r for r in rows(d, "Item")}
    sparse = {r["ID"]: r for r in rows(d, "ItemSparse")}

    def keep(i):
        s, it = sparse.get(i), item.get(i)
        if not s or not it or int(i) >= 25000:
            return False
        if s["Bonding"] not in ("0", "2", "3"):
            return False
        q = int(s["OverallQualityID"])
        if q < 1 or q > 4 or it["ClassID"] in SKIP_CLASS:
            return False
        if it["ClassID"] in ("2", "4") and q == 1:
            return False
        if it["ClassID"] == "9" and it["SubclassID"] == "0":  # class spell books
            return False
        name = s["Display_lang"]
        return bool(name) and not BAD_NAME.search(name)

    spell_prof = {}
    for r in rows(d, "SkillLineAbility"):
        p = PROFESSIONS.get(int(r["SkillLine"]))
        if p:
            spell_prof[r["Spell"]] = p
    makes = collections.defaultdict(set)  # item -> professions making it
    for r in rows(d, "SpellEffect"):
        if r["Effect"] == CREATE_ITEM and r["SpellID"] in spell_prof and r["EffectItemType"] != "0":
            makes[r["EffectItemType"]].add(spell_prof[r["SpellID"]])
    used = collections.defaultdict(collections.Counter)  # reagent -> profession -> recipes
    for r in rows(d, "SpellReagents"):
        p = spell_prof.get(r["SpellID"])
        if p:
            for k in range(8):
                g = r[f"Reagent_{k}"]
                if g and g != "0":
                    used[g][p] += 1

    order = ["Mining", "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering", "First Aid", "Leatherworking", "Tailoring"]  # bars stay with Mining, not transmutes

    def material(i):
        name = sparse[i]["Display_lang"]
        profs = used[i]
        if item[i]["ClassID"] == "7" and any(h in name for h in HERB_WORDS):
            return "Herbs"
        if "Mining" in profs or name.endswith(" Ore") or name.endswith(" Stone") and item[i]["ClassID"] == "7" and "Sharpening" not in name and "Weightstone" not in name:
            return "Ore and stone"
        if re.search(r"cloth$", name, re.I) and "Bolt" not in name and item[i]["ClassID"] == "7":
            return "Cloth"
        if re.search(r"Leather|Hide|Scale", name) and item[i]["ClassID"] == "7":
            return "Leather"
        if re.search(r"Dust|Essence|Shard|Nexus Crystal", name) and "Enchanting" in profs:
            return "Enchanting"
        if profs and set(profs) == {"Cooking"}:
            return "Meat and fish"
        if profs:
            return "Other"
        return None

    groups = collections.OrderedDict()
    def add(path, i):
        groups.setdefault(path, []).append(int(i))
    for i in sorted(sparse, key=int):
        if not keep(i):
            continue
        if i in makes:
            p = sorted(makes[i], key=order.index)[0]
            add(f"Crafted`{p}", i)
            continue
        m = material(i)
        if m:
            add(f"Materials`{m}", i)
            continue
        c, sc = item[i]["ClassID"], item[i]["SubclassID"]
        cn, sn = cls[c], sub.get((c, sc), "Other")
        add(cn if sn == cn else f"{cn}`{sn}", i)
    return collections.OrderedDict(sorted(groups.items())), sparse


def text(groups):
    parts = []
    for path, items in groups.items():
        parts.append("group:" + path)
        parts += [f"i:{i}" for i in items]
    return ",".join(parts)


if __name__ == "__main__":
    groups, _ = build(sys.argv[1])
    Path(sys.argv[2]).write_text(text(groups))
    for path, items in groups.items():
        print(f"{len(items):5}  {path}")
    print(sum(len(v) for v in groups.values()), "items in", len(groups), "groups")
