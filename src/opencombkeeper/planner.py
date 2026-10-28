from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from math import ceil, log
from typing import Any, Iterable


@dataclass(frozen=True)
class Mutation:
    result: str
    parents: tuple[str, str]
    chance: float
    conditions: tuple[str, ...]

    @property
    def pair(self) -> tuple[str, str]:
        return tuple(sorted(self.parents))


def production_attempts(chance: float, confidence: float) -> int | None:
    """Independent rolls needed to observe a product with given confidence."""
    if chance <= 0:
        return None
    if chance >= 1:
        return 1
    if not 0 < confidence < 1:
        raise ValueError("successProbability must be between 0 and 1")
    return ceil(log(1 - confidence) / log(1 - chance))


class Planner:
    def __init__(self, catalog: dict[str, Any], config: dict[str, Any]):
        self.catalog = catalog
        self.config = config
        self.mode = config.get("mode", "best")
        if self.mode not in {"best", "collect"}:
            raise ValueError("mode must be 'best' or 'collect'")
        self.confidence = float(config.get("successProbability", 0.99))
        if not 0 < self.confidence < 1:
            raise ValueError("successProbability must be between 0 and 1")
        self.allow_conditional = bool(config.get("allowConditionalMutations", True))
        self.starting_counts = {str(uid): int(count) for uid, count in config.get("startingSpecies", {}).items()}
        if not self.starting_counts or any(count < 0 for count in self.starting_counts.values()):
            raise ValueError("startingSpecies must contain non-negative princess counts")
        self.species = {row["uid"]: row for row in catalog["species"]}
        unknown = set(self.starting_counts) - set(self.species)
        if unknown:
            raise ValueError("unknown starting species: " + ", ".join(sorted(unknown)))
        self.carrier_priority = [str(uid) for uid in config.get("carrierPriority", ())]
        unknown_priority = set(self.carrier_priority) - set(self.starting_counts)
        if unknown_priority:
            raise ValueError("carrierPriority must reference starting species: " +
                             ", ".join(sorted(unknown_priority)))
        self.carrier_rank = {uid: rank for rank, uid in enumerate(self.carrier_priority)}
        self.mutations = [Mutation(row["result"], tuple(row["parents"]), float(row["chance"]),
                                   tuple(row.get("conditions", ()))) for row in catalog["mutations"]]
        self.mutations = [m for m in self.mutations if self.allow_conditional or not m.conditions]
        self.by_result: dict[str, list[Mutation]] = defaultdict(list)
        self.by_pair: dict[tuple[str, str], set[str]] = defaultdict(set)
        for mutation in self.mutations:
            self.by_result[mutation.result].append(mutation)
            self.by_pair[mutation.pair].add(mutation.result)

    def _reachability(self):
        depth = {uid: 0 for uid, count in self.starting_counts.items() if count > 0}
        carrier = {
            uid: (self.carrier_rank.get(uid, len(self.carrier_rank)),
                  uid not in self.carrier_rank)
            for uid in depth
        }
        recipe: dict[str, Mutation] = {}
        changed = True
        while changed:
            changed = False
            for mutation in self.mutations:
                if not all(parent in depth for parent in mutation.parents):
                    continue
                candidate_depth = max(depth[parent] for parent in mutation.parents) + 1
                candidate_carrier = min(carrier[parent] for parent in mutation.parents)
                candidate_parent_carriers = tuple(sorted(carrier[parent] for parent in mutation.parents))
                candidate_score = (
                    candidate_carrier, candidate_parent_carriers, candidate_depth,
                    len(mutation.conditions),
                    len(self.by_pair[mutation.pair]) > 1,
                    mutation.pair,
                    mutation.result,
                )
                current = recipe.get(mutation.result)
                if current is None:
                    current_score = ((10**9, True), ((10**9, True),),
                                     10**9, 10**9, True, ("", ""), "")
                else:
                    current_score = (
                        carrier[mutation.result], tuple(sorted(carrier[parent] for parent in current.parents)),
                        depth[mutation.result], len(current.conditions),
                        len(self.by_pair[current.pair]) > 1, current.pair, current.result,
                    )
                if candidate_score < current_score:
                    depth[mutation.result] = candidate_depth
                    carrier[mutation.result] = candidate_carrier
                    recipe[mutation.result] = mutation
                    changed = True
        return depth, recipe

    def _producers(self, depth: dict[str, int]):
        producers: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for uid, species in self.species.items():
            if uid not in depth:
                continue
            for comb in species.get("combs", ()):
                row = {"species": uid, "name": species.get("name", uid), "depth": depth[uid], **comb}
                producers[comb["id"]].append(row)
        return producers

    @staticmethod
    def _producer_key(row: dict[str, Any]):
        return (-float(row["chance"]), int(row["depth"]), len(row.get("conditions", ())), row["species"])

    def _select_best(self, producers):
        selected: dict[str, dict[str, Any]] = {}
        for comb, rows in producers.items():
            selected[comb] = min(rows, key=self._producer_key)
        return selected

    def _select_collect(self, producers):
        by_species: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
        for comb, rows in producers.items():
            for row in rows:
                current = by_species[row["species"]].get(comb)
                if current is None or self._producer_key(row) < self._producer_key(current):
                    by_species[row["species"]][comb] = row
        uncovered = set(producers)
        selected: dict[str, dict[str, Any]] = {}
        while uncovered:
            candidates = []
            for uid, combs in by_species.items():
                new = uncovered & set(combs)
                if not new:
                    continue
                total_chance = sum(float(combs[comb]["chance"]) for comb in new)
                depth = min(int(combs[comb]["depth"]) for comb in new)
                candidates.append((-len(new), -total_chance, depth, uid, new))
            if not candidates:
                break
            _, _, _, uid, covered = min(candidates)
            for comb in covered:
                selected[comb] = by_species[uid][comb]
            uncovered -= covered
        return selected

    def _closure(self, targets: Iterable[str], recipe: dict[str, Mutation]):
        required: set[str] = set()

        def visit(uid: str):
            if uid in required:
                return
            required.add(uid)
            mutation = recipe.get(uid)
            if mutation:
                for parent in mutation.parents:
                    visit(parent)

        for target in targets:
            visit(target)
        return required

    def _carrier_path(self, target: str, depth: dict[str, int], recipe: dict[str, Mutation], preferred=frozenset()):
        def route(uid: str, seen: frozenset[str]):
            if uid in seen:
                raise ValueError(f"cycle in selected recipes at {uid}")
            if self.starting_counts.get(uid, 0) > 0:
                return [uid]
            mutation = recipe.get(uid)
            if mutation is None:
                raise ValueError(f"no carrier path for {target}")
            candidates = [route(parent, seen | {uid}) for parent in mutation.parents]

            def key(path):
                root = path[0]
                parent = path[-1]
                return (self.carrier_rank.get(root, len(self.carrier_rank)),
                        root not in self.carrier_rank,
                        parent not in preferred, len(path), depth[parent], root, parent)

            return min(candidates, key=key) + [uid]

        return route(target, frozenset())

    def _line_paths(self, targets: set[str], required: set[str], depth, recipe):
        paths: list[dict[str, Any]] = []
        covered: set[str] = set()
        ordered_targets = sorted(targets, key=lambda uid: (-depth[uid], uid))
        for target in ordered_targets:
            if self.mode == "collect" and target in covered:
                continue
            preferred = targets if self.mode == "collect" else frozenset()
            path = self._carrier_path(target, depth, recipe, preferred)
            paths.append({"role": "producer", "target": target, "species": path,
                          "moduleProfile": self._module_profile(target),
                          "targetRequirements": self.species[target].get("requirements", {})})
            covered.update(path)
        for dependency in sorted(required - covered, key=lambda uid: (-depth[uid], uid)):
            if dependency in covered:
                continue
            if self.starting_counts.get(dependency, 0) > 0:
                continue
            path = self._carrier_path(dependency, depth, recipe)
            paths.append({"role": "drone_source", "target": dependency, "species": path,
                          "moduleProfile": self._module_profile(dependency),
                          "targetRequirements": self.species[dependency].get("requirements", {})})
            covered.update(path)
        profile_counts: Counter[str] = Counter()
        profile_capacity = {"plains": 4, "jungle": 1, "desert": 1, "winter": 1, "hell": 1}
        for number, path in enumerate(paths, 1):
            path["id"] = number
            profile = path["moduleProfile"]
            path["moduleSlot"] = profile_counts[profile] % profile_capacity[profile] + 1
            profile_counts[profile] += 1
        return paths

    def _module_profile(self, uid: str) -> str:
        """Choose one of the physically installed apiary climate profiles."""
        temperature = str(self.species[uid].get("requirements", {}).get("temperature", "NORMAL"))
        if temperature == "HELLISH":
            return "hell"
        if temperature == "HOT":
            return "desert"
        if temperature == "WARM":
            return "jungle"
        if temperature in {"ICY", "COLD"}:
            return "winter"
        return "plains"

    def _balance_carriers(self, paths, recipe):
        """Share equivalent first steps between preferred starting princesses."""
        if len(self.carrier_priority) < 2:
            return
        loads: Counter[str] = Counter()
        for path in paths:
            route = path["species"]
            if len(route) == 1:
                loads[route[0]] += 1
        for path in paths:
            route = path["species"]
            if len(route) < 2:
                continue
            mutation = recipe[route[1]]
            candidates = [uid for uid in self.carrier_priority
                          if uid in mutation.parents and self.starting_counts.get(uid, 0) > 0]
            if route[0] in candidates:
                route[0] = min(candidates, key=lambda uid: (loads[uid], self.carrier_rank[uid]))
            loads[route[0]] += 1

    def build(self) -> dict[str, Any]:
        depth, recipe = self._reachability()
        producers = self._producers(depth)
        all_combs = {comb for species in self.species.values() for comb in (row["id"] for row in species.get("combs", ()))}
        selected = self._select_best(producers) if self.mode == "best" else self._select_collect(producers)
        targets = {row["species"] for row in selected.values()}
        required = self._closure(targets, recipe)
        paths = self._line_paths(targets, required, depth, recipe)
        self._balance_carriers(paths, recipe)
        starting = Counter(path["species"][0] for path in paths)
        shortages = {uid: need - self.starting_counts.get(uid, 0) for uid, need in starting.items()
                     if need > self.starting_counts.get(uid, 0)}
        selected_mutations = []
        for uid in sorted(required, key=lambda item: (depth[item], item)):
            mutation = recipe.get(uid)
            if not mutation:
                continue
            ambiguous = len(self.by_pair[mutation.pair]) > 1
            calendar = [condition for condition in mutation.conditions if condition.startswith("restrictDateRange(")]
            row = {"result": uid, "parents": list(mutation.parents), "chance": mutation.chance,
                   "conditions": list(mutation.conditions), "calendarConditions": calendar,
                   "ignoredMutatronConditions": [condition for condition in mutation.conditions
                                                  if condition not in calendar],
                   "depth": depth[uid], "manual": ambiguous}
            selected_mutations.append(row)
        manual_tasks = []
        final_drone_uses: Counter[str] = Counter()
        for line in paths:
            route = line["species"]
            for step, (carrier, result) in enumerate(zip(route, route[1:]), 1):
                mutation = recipe[result]
                if len(self.by_pair[mutation.pair]) > 1:
                    manual_tasks.append({"id": f"mutation:{line['id']}:{step}", "type": "advanced_mutation",
                                         "line": line["id"], "step": step, "result": result,
                                         "parents": list(mutation.parents), "status": "waiting_player"})
                other_parents = list(mutation.parents)
                other_parents.remove(carrier)
                for parent in other_parents:
                    if parent in targets:
                        final_drone_uses[parent] += 1
        parent_uses = final_drone_uses
        for uid, count in sorted(parent_uses.items()):
            manual_tasks.append({"id": f"drones:{uid}", "type": "provide_drones", "species": uid,
                                 "count": count, "status": "waiting_player"})
        comb_plan = []
        for comb, producer in sorted(selected.items()):
            comb_plan.append({"comb": comb, "producer": producer["species"], "producerName": producer["name"],
                              "chance": producer["chance"], "kind": producer.get("kind", "product"),
                              "attemptsForConfidence": production_attempts(float(producer["chance"]), self.confidence)})
        mutation_operations = sum(max(0, len(path["species"]) - 1) for path in paths)
        critical_depth = max((depth[target] for target in targets), default=0)
        return {
            "schema": 1,
            "mode": self.mode,
            "sourceCatalog": self.catalog.get("sources", {}),
            "successProbability": self.confidence,
            "counts": {
                "catalogCombs": len(all_combs),
                "reachableCombs": len(producers),
                "selectedProducers": len(targets),
                "princessLines": len(paths),
                "mutationOperations": mutation_operations,
                "criticalDepth": critical_depth,
                "manualTasks": len(manual_tasks),
            },
            "unreachableCombs": sorted(all_combs - set(producers)),
            "startingPrincesses": dict(sorted(starting.items())),
            "startingShortages": shortages,
            "combs": comb_plan,
            "targets": sorted(targets),
            "requiredSpecies": sorted(required),
            "mutations": selected_mutations,
            "lines": paths,
            "manualTasks": manual_tasks,
        }
