from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .planner import Planner


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def lua_value(value, level=0):
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    indent = "  " * level
    child = "  " * (level + 1)
    if isinstance(value, list):
        return "{\n" + ",\n".join(child + lua_value(row, level + 1) for row in value) + "\n" + indent + "}"
    if isinstance(value, dict):
        rows = []
        for key, row in value.items():
            key_text = key if key.isidentifier() else "[" + json.dumps(key, ensure_ascii=False) + "]"
            rows.append(child + key_text + "=" + lua_value(row, level + 1))
        return "{\n" + ",\n".join(rows) + "\n" + indent + "}"
    raise TypeError(type(value))


def runtime_plan(plan):
    """Keep only fields consumed by the OpenOS executor."""
    mutation_keys = ("result", "parents", "calendarConditions")
    line_keys = ("id", "role", "target", "moduleProfile", "moduleSlot", "species")
    task_keys = ("id", "type", "line", "step", "result", "species", "count", "status")
    return {
        "schema": plan["schema"],
        "startingPrincesses": plan["startingPrincesses"],
        "mutations": [{key: row[key] for key in mutation_keys if key in row} for row in plan["mutations"]],
        "lines": [{key: row[key] for key in line_keys if key in row} for row in plan["lines"]],
        "manualTasks": [{key: row[key] for key in task_keys if key in row} for row in plan["manualTasks"]],
    }


def plan_command(options):
    plan = Planner(read_json(options.catalog), read_json(options.config)).build()
    options.output.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if options.lua_output:
        options.lua_output.write_text("return " + lua_value(runtime_plan(plan)) + "\n", encoding="utf-8")
    counts = plan["counts"]
    print(f"Соты: {counts['reachableCombs']}/{counts['catalogCombs']}")
    print(f"Производители: {counts['selectedProducers']}")
    print(f"Принцессы: {counts['princessLines']}")
    print(f"Мутации: {counts['mutationOperations']}; глубина: {counts['criticalDepth']}")
    print(f"Ручные задачи: {counts['manualTasks']}")
    if plan["startingShortages"]:
        print("Не хватает стартовых принцесс:", file=sys.stderr)
        for uid, count in plan["startingShortages"].items():
            print(f"  {uid}: {count}", file=sys.stderr)
        return 2
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="opencombkeeper")
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan")
    plan.add_argument("--catalog", type=Path, required=True)
    plan.add_argument("--config", type=Path, required=True)
    plan.add_argument("--output", type=Path, required=True)
    plan.add_argument("--lua-output", type=Path)
    options = parser.parse_args(argv)
    if options.command == "plan":
        return plan_command(options)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
