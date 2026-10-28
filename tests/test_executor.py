import unittest
from pathlib import Path

from lupa.lua52 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def table(lua, value):
    if isinstance(value, dict):
        result = lua.table()
        for key, row in value.items():
            result[key] = table(lua, row)
        return result
    if isinstance(value, list):
        result = lua.table()
        for index, row in enumerate(value, 1):
            result[index] = table(lua, row)
        return result
    return value


class ExecutorTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.module = self.lua.execute((ROOT / "src/executor.lua").read_text())

    def plan(self, manual=False):
        tasks = ([{"id": "mutation:1:1", "type": "advanced_mutation", "line": 1, "step": 1,
                   "result": "result", "parents": ["root", "root"], "status": "waiting_player"}]
                 if manual else [])
        return table(self.lua, {"schema": 1,
            "mutations": [{"result": "result", "parents": ["root", "root"], "conditions": []}],
            "lines": [{"id": 1, "role": "producer", "target": "result", "species": ["root", "result"]}],
            "manualTasks": tasks})

    def test_automatic_mutation_and_delivery(self):
        engine = self.module.new(self.plan(), table(self.lua, {}), None)
        action = engine.nextAction(engine)
        self.assertEqual("mutation", action["type"])
        self.assertTrue(engine.complete(engine, action, table(self.lua, {"kind": "queen", "species": "result"})))
        delivery = engine.nextAction(engine)
        self.assertEqual("deliver_producer", delivery["type"])
        engine.complete(engine, delivery, table(self.lua, {"accepted": True}))
        self.assertIsNone(engine.nextAction(engine))
        self.assertEqual("done", engine.summary(engine)["status"])

    def test_wrong_species_blocks_without_advancing(self):
        engine = self.module.new(self.plan(), table(self.lua, {}), None)
        action = engine.nextAction(engine)
        self.assertFalse(engine.complete(engine, action, table(self.lua, {"kind": "queen", "species": "other"})))
        self.assertEqual("blocked", engine.summary(engine)["status"])

    def test_genetic_waste_loses_line_and_blocks(self):
        engine = self.module.new(self.plan(), table(self.lua, {}), None)
        self.assertFalse(engine.complete(engine, engine.nextAction(engine), table(self.lua, {"kind": "genetic_waste"})))
        summary = engine.summary(engine)
        self.assertEqual(1, summary["lost"])
        self.assertEqual("blocked", summary["status"])

    def test_manual_task_requires_new_queen_above_baseline(self):
        counts = {"value": 0}
        hardware = self.lua.table()
        hardware["countQueens"] = lambda uid=None: counts["value"]
        engine = self.module.new(self.plan(manual=True), hardware, None)
        action = engine.nextAction(engine)
        self.assertEqual("prepare_manual_mutation", action["type"])
        self.assertTrue(engine.complete(engine, action, table(self.lua, {"accepted": True})))
        wait = engine.nextAction(engine)
        self.assertEqual("manual_task", wait["type"])
        self.assertFalse(engine.checkTask(engine, wait["task"]))
        counts["value"] = 1
        self.assertTrue(engine.checkTask(engine, wait["task"]))
        self.assertEqual("deliver_producer", engine.nextAction(engine)["type"])

    def test_existing_queen_becomes_me_baseline(self):
        hardware = self.lua.table()
        hardware["countQueens"] = lambda uid=None: 1
        engine = self.module.new(self.plan(manual=True), hardware, None)
        action = engine.nextAction(engine)
        self.assertEqual("prepare_manual_mutation", action["type"])
        task = engine.tasks[action["task"]]
        self.assertEqual(1, task["baseline"])

    def test_manual_queue_prepares_up_to_hardware_capacity(self):
        plan = table(self.lua, {"schema": 1,
            "mutations": [
                {"result": "a", "parents": ["root", "root"], "conditions": []},
                {"result": "b", "parents": ["root", "root"], "conditions": []}],
            "lines": [
                {"id": 1, "role": "producer", "target": "a", "species": ["root", "a"]},
                {"id": 2, "role": "producer", "target": "b", "species": ["root", "b"]}],
            "manualTasks": [
                {"id": "mutation:1:1", "type": "advanced_mutation", "line": 1, "step": 1,
                 "result": "a", "parents": ["root", "root"], "status": "waiting_player"},
                {"id": "mutation:2:1", "type": "advanced_mutation", "line": 2, "step": 1,
                 "result": "b", "parents": ["root", "root"], "status": "waiting_player"}]})
        hardware = self.lua.table()
        hardware["countQueens"] = lambda uid=None: 0
        hardware["manualCapacity"] = lambda: 2
        engine = self.module.new(plan, hardware, None)
        first = engine.nextAction(engine)
        engine.complete(engine, first, table(self.lua, {"accepted": True}))
        second = engine.nextAction(engine)
        self.assertEqual("prepare_manual_mutation", second["type"])
        self.assertNotEqual(first["task"], second["task"])

    def test_same_result_tasks_get_distinct_thresholds(self):
        plan = table(self.lua, {"schema": 1,
            "mutations": [{"result": "a", "parents": ["root", "root"], "conditions": []}],
            "lines": [
                {"id": 1, "role": "producer", "target": "a", "species": ["root", "a"]},
                {"id": 2, "role": "producer", "target": "a", "species": ["root", "a"]}],
            "manualTasks": [
                {"id": "mutation:1:1", "type": "advanced_mutation", "line": 1, "step": 1,
                 "result": "a", "parents": ["root", "root"], "status": "waiting_player"},
                {"id": "mutation:2:1", "type": "advanced_mutation", "line": 2, "step": 1,
                 "result": "a", "parents": ["root", "root"], "status": "waiting_player"}]})
        hardware = self.lua.table()
        hardware["countQueens"] = lambda uid=None: 3
        hardware["manualCapacity"] = lambda: 2
        engine = self.module.new(plan, hardware, None)
        first = engine.nextAction(engine)
        engine.complete(engine, first, table(self.lua, {"accepted": True}))
        second = engine.nextAction(engine)
        self.assertEqual(3, engine.tasks[first["task"]]["baseline"])
        self.assertEqual(4, engine.tasks[second["task"]]["baseline"])

    def test_queued_manual_task_does_not_capture_early_baseline(self):
        plan = table(self.lua, {"schema": 1,
            "mutations": [{"result": "a", "parents": ["root", "root"]},
                          {"result": "b", "parents": ["root", "root"]}],
            "lines": [{"id": 1, "role": "producer", "target": "a", "species": ["root", "a"]},
                      {"id": 2, "role": "producer", "target": "b", "species": ["root", "b"]}],
            "manualTasks": [
                {"id": "mutation:1:1", "type": "advanced_mutation", "line": 1, "step": 1,
                 "result": "a", "status": "waiting_player"},
                {"id": "mutation:2:1", "type": "advanced_mutation", "line": 2, "step": 1,
                 "result": "b", "status": "waiting_player"}]})
        hardware = self.lua.table(); hardware["countQueens"] = lambda uid=None: 0
        hardware["manualCapacity"] = lambda: 1
        engine = self.module.new(plan, hardware, None)
        first = engine.nextAction(engine); engine.complete(engine, first, table(self.lua, {"accepted": True}))
        self.assertEqual("manual_task", engine.nextAction(engine)["type"])
        self.assertIsNone(engine.tasks["mutation:2:1"]["baseline"])

    def test_check_all_does_not_activate_future_manual_tasks(self):
        hardware = self.lua.table()
        hardware["countQueens"] = lambda uid=None: 0
        engine = self.module.new(self.plan(manual=True), hardware, None)
        done, total = engine.checkAllTasks(engine)
        self.assertEqual((0, 1), (done, total))
        self.assertIsNone(engine.tasks["mutation:1:1"]["baseline"])


if __name__ == "__main__":
    unittest.main()
