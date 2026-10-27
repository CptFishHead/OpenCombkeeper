#!/usr/bin/env python3
"""Project the full OpenBeekeeper client catalogue to comb planning data."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def comb_id(item: str) -> str | None:
    forestry = re.search(r"beeComb\.get\(EnumHoneyComb\.([A-Z0-9_]+)", item)
    if forestry:
        return "forestry:comb/" + forestry.group(1).lower()
    vanilla = re.search(r"ItemHoneyComb\.VanillaComb\.([A-Z0-9_]+)\.get", item)
    if vanilla:
        return "forestry:comb/" + vanilla.group(1).lower()
    extra = re.search(r"EnumHoneyComb\.([A-Z0-9_]+)\.get", item)
    if extra:
        return "extrabees:comb/" + extra.group(1).lower()
    gendustry = re.fullmatch(r"HoneyComb:([a-z0-9_]+)", item)
    if gendustry:
        return "gendustry:comb/" + gendustry.group(1)
    return None


def build(source: dict) -> dict:
    species = []
    known = {row["uid"] for row in source["species"]}
    for row in source["species"]:
        combs = []
        for drop in row.get("drops", ()):
            uid = comb_id(drop["item"])
            if uid:
                combs.append({"id": uid, "chance": drop["chance"], "kind": drop["kind"]})
        species.append({"uid": row["uid"], "name": row.get("name", row["uid"]),
                        "requirements": row.get("requirements", {}), "combs": combs})
    mutations = []
    for row in source["mutations"]:
        if row["result"] not in known or not set(row["parents"]).issubset(known):
            raise ValueError("mutation references unknown species: " + repr(row))
        mutations.append({"result": row["result"], "parents": row["parents"],
                          "chance": row["chance"], "conditions": row.get("conditions", [])})
    return {"schema": 1, "scope": source.get("scope", "client"), "sources": source.get("sources", {}),
            "species": species, "mutations": mutations}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    payload = build(json.loads(options.source.read_text(encoding="utf-8")))
    options.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    combs = {comb["id"] for row in payload["species"] for comb in row["combs"]}
    print(f"wrote {len(payload['species'])} species, {len(combs)} combs, {len(payload['mutations'])} mutations")


if __name__ == "__main__":
    main()
