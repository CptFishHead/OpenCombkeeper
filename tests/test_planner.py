import json
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from opencombkeeper.cli import main
from opencombkeeper.planner import Planner, production_attempts
from build_comb_catalog import comb_id


def species(uid, combs=()):
    return {"uid": uid, "name": uid, "requirements": {}, "combs": list(combs)}


def comb(uid, chance):
    return {"id": uid, "chance": chance, "kind": "product"}


class PlannerUnitTest(unittest.TestCase):
    def test_comb_item_normalization(self):
        self.assertEqual("forestry:comb/mossy", comb_id("ItemHoneyComb.VanillaComb.MOSSY.get()"))
        self.assertEqual("extrabees:comb/uranium", comb_id("EnumHoneyComb.URANIUM.get(1)"))
        self.assertEqual("gendustry:comb/black", comb_id("HoneyComb:black"))

    def test_production_attempts(self):
        self.assertEqual(1, production_attempts(1, 0.99))
        self.assertEqual(44, production_attempts(0.1, 0.99))
        self.assertIsNone(production_attempts(0, 0.99))
        with self.assertRaises(ValueError):
            production_attempts(0.5, 1)

    def test_best_uses_probability_then_depth(self):
        catalog = {"species": [species("root"), species("near", [comb("c", 0.2)]),
                               species("far", [comb("c", 0.3)])],
                   "mutations": [{"result": "near", "parents": ["root", "root"], "chance": 10},
                                 {"result": "far", "parents": ["near", "root"], "chance": 10}]}
        plan = Planner(catalog, {"mode": "best", "startingSpecies": {"root": 4}}).build()
        self.assertEqual("far", plan["combs"][0]["producer"])

    def test_collect_reuses_line_when_target_is_on_later_path(self):
        catalog = {"species": [species("root"), species("a", [comb("a-comb", 0.3)]),
                               species("b", [comb("b-comb", 0.3)])],
                   "mutations": [{"result": "a", "parents": ["root", "root"], "chance": 10},
                                 {"result": "b", "parents": ["a", "root"], "chance": 10}]}
        plan = Planner(catalog, {"mode": "collect", "startingSpecies": {"root": 1}}).build()
        self.assertEqual(1, plan["counts"]["princessLines"])
        self.assertEqual(["root", "a", "b"], plan["lines"][0]["species"])

    def test_ambiguous_recipe_creates_per_line_manual_task(self):
        catalog = {"species": [species("root"), species("wanted", [comb("c", 0.3)]), species("other")],
                   "mutations": [{"result": "wanted", "parents": ["root", "root"], "chance": 10},
                                 {"result": "other", "parents": ["root", "root"], "chance": 10}]}
        plan = Planner(catalog, {"mode": "best", "startingSpecies": {"root": 1}}).build()
        tasks = [row for row in plan["manualTasks"] if row["type"] == "advanced_mutation"]
        self.assertEqual(1, len(tasks))
        self.assertEqual("mutation:1:1", tasks[0]["id"])

    def test_shortage_is_reported(self):
        catalog = {"species": [species("root"), species("a", [comb("a", 1)]), species("b", [comb("b", 1)])],
                   "mutations": [{"result": "a", "parents": ["root", "root"], "chance": 10},
                                 {"result": "b", "parents": ["root", "root"], "chance": 10}]}
        plan = Planner(catalog, {"mode": "best", "startingSpecies": {"root": 1}})
        self.assertEqual({"root": 1}, plan.build()["startingShortages"])

    def test_carrier_priority_selects_common_root_through_intermediate_parent(self):
        catalog = {"species": [species("rare"), species("forest"), species("middle"),
                               species("wanted", [comb("c", 1)])],
                   "mutations": [{"result": "middle", "parents": ["forest", "forest"], "chance": 10},
                                 {"result": "wanted", "parents": ["rare", "middle"], "chance": 10}]}
        config = {"mode": "best", "startingSpecies": {"rare": 2, "forest": 2},
                  "carrierPriority": ["forest"]}
        plan = Planner(catalog, config).build()
        self.assertEqual(["forest", "middle", "wanted"], plan["lines"][0]["species"])

    def test_starting_drone_source_does_not_consume_princess(self):
        catalog = {"species": [species("forest"), species("drone"),
                               species("wanted", [comb("c", 1)])],
                   "mutations": [{"result": "wanted", "parents": ["forest", "drone"], "chance": 10}]}
        config = {"mode": "best", "startingSpecies": {"forest": 2, "drone": 2},
                  "carrierPriority": ["forest"]}
        plan = Planner(catalog, config).build()
        self.assertEqual({"forest": 1}, plan["startingPrincesses"])
        self.assertEqual([], [line for line in plan["lines"] if line["role"] == "drone_source"])

    def test_equivalent_preferred_carriers_are_balanced(self):
        catalog = {"species": [species("forest"), species("meadows"), species("rare"), species("common"),
                               species("a", [comb("a", 1)]), species("b", [comb("b", 1)])],
                   "mutations": [{"result": "common", "parents": ["forest", "meadows"], "chance": 10},
                                 {"result": "a", "parents": ["common", "rare"], "chance": 10},
                                 {"result": "b", "parents": ["common", "rare"], "chance": 10}]}
        config = {"mode": "best", "startingSpecies": {"forest": 4, "meadows": 4, "rare": 4},
                  "carrierPriority": ["forest", "meadows"]}
        plan = Planner(catalog, config).build()
        self.assertEqual({"forest": 1, "meadows": 1}, plan["startingPrincesses"])
        self.assertEqual({"forest", "meadows"}, {line["species"][0] for line in plan["lines"]})

    def test_line_is_assigned_to_climate_profile(self):
        hot = species("hot", [comb("c", 1)])
        hot["requirements"] = {"temperature": "HOT", "humidity": "ARID"}
        catalog = {"species": [species("root"), hot],
                   "mutations": [{"result": "hot", "parents": ["root", "root"], "chance": 10}]}
        plan = Planner(catalog, {"mode": "best", "startingSpecies": {"root": 1}}).build()
        self.assertEqual("desert", plan["lines"][0]["moduleProfile"])
        self.assertEqual(1, plan["lines"][0]["moduleSlot"])

    def test_only_calendar_condition_reaches_mutatron_scheduler(self):
        catalog = {"species": [species("root"), species("a", [comb("c", 1)])],
                   "mutations": [{"result": "a", "parents": ["root", "root"], "chance": 10,
                                  "conditions": ["restrictBiomeType(PLAINS)",
                                                 "restrictDateRange(12, 21, 12, 27)"]}]}
        mutation = Planner(catalog, {"mode": "best", "startingSpecies": {"root": 1}}).build()["mutations"][0]
        self.assertEqual(["restrictDateRange(12, 21, 12, 27)"], mutation["calendarConditions"])
        self.assertEqual(["restrictBiomeType(PLAINS)"], mutation["ignoredMutatronConditions"])


class RealCatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((ROOT / "data/comb-catalog.json").read_text())
        cls.config = json.loads((ROOT / "examples/mcskill.json").read_text())

    def test_catalog_integrity(self):
        species_ids = {row["uid"] for row in self.catalog["species"]}
        self.assertEqual(176, len(species_ids))
        self.assertEqual(105, len({comb["id"] for row in self.catalog["species"] for comb in row["combs"]}))
        for mutation in self.catalog["mutations"]:
            self.assertIn(mutation["result"], species_ids)
            self.assertTrue(set(mutation["parents"]).issubset(species_ids))
            self.assertNotIn(mutation["result"], mutation["parents"])

    def test_all_client_combs_are_reachable_from_declared_roots(self):
        plan = Planner(self.catalog, self.config).build()
        self.assertEqual([], plan["unreachableCombs"])
        self.assertEqual(105, plan["counts"]["reachableCombs"])
        self.assertFalse(plan["startingShortages"])

    def test_cli_writes_json_and_lua(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "plan.json"
            lua = Path(directory) / "plan.lua"
            code = main(["plan", "--catalog", str(ROOT / "data/comb-catalog.json"),
                         "--config", str(ROOT / "examples/mcskill.json"),
                         "--output", str(output), "--lua-output", str(lua)])
            self.assertEqual(0, code)
            self.assertEqual(1, json.loads(output.read_text())["schema"])
            self.assertTrue(lua.read_text().startswith("return {"))
            self.assertNotIn("sourceCatalog", lua.read_text())


if __name__ == "__main__":
    unittest.main()
