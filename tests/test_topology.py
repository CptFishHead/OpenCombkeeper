import unittest
from pathlib import Path

from lupa.lua52 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


HARNESS = r"""
function makeTopologyEnvironment()
  local files, saved = {}, {}
  local names = {
    t1={[0]='appliedenergistics2:interface',[1]='gendustry:mutatron',
      [2]='gendustry:mutatron_advanced',[3]='gendustry:imprinter',
      [4]='minecraft:chest',[5]='minecraft:chest'},
    t2={[0]='appliedenergistics2:interface',[1]='minecraft:chest'}
  }
  local stacks={t1={},t2={}}
  local requests={i1={},i2={}}
  local control={hide=nil,names=names,stacks=stacks,requests=requests,files=files}

  local function transposer(id)
    return {
      getInventoryName=function(side) return names[id][side] end,
      getInventorySize=function(side) return names[id][side] and 9 or nil end,
      getStackInSlot=function(side,slot)
        local inventory=stacks[id][side]; return inventory and inventory[slot] or nil
      end
    }
  end
  local databaseSlots={}
  local database={
    get=function(slot) return databaseSlots[slot] end,
    clear=function(slot) databaseSlots[slot]=nil; return true end
  }
  local function interface(id,transposerId)
    return {
      getInterfaceConfiguration=function(slot) return requests[id][slot] end,
      setInterfaceConfiguration=function(slot,databaseAddress,databaseSlot,count)
        requests[id][slot]=databaseAddress and {database=databaseAddress,slot=databaseSlot,count=count} or nil
        stacks[transposerId][0]=stacks[transposerId][0] or {}
        stacks[transposerId][0][1]=databaseAddress and {name='minecraft:cobblestone',size=1} or nil
        return true
      end,
      store=function(filter,databaseAddress,databaseSlot,count)
        databaseSlots[databaseSlot]={name='minecraft:cobblestone',size=1}; return true
      end
    }
  end
  local proxies={t1=transposer('t1'),t2=transposer('t2'),db=database}
  proxies.i1=interface('i1','t1'); proxies.i2=interface('i2','t2')
  local all={
    {address='t1',kind='transposer',methods={},proxy=proxies.t1},
    {address='t2',kind='transposer',methods={},proxy=proxies.t2},
    {address='i1',kind='me_interface',methods={setInterfaceConfiguration=false,getInterfaceConfiguration=false},proxy=proxies.i1},
    {address='i2',kind='me_interface',methods={setInterfaceConfiguration=false,getInterfaceConfiguration=false},proxy=proxies.i2},
    {address='db',kind='database',methods={computeHash=false,get=false,indexOf=false},proxy=proxies.db}
  }
  local env={path='/data/topology',pendingPath='/data/bind-pending'}
  env.components=function()
    local result={}
    for _,row in ipairs(all) do if row.address~=control.hide then result[#result+1]=row end end
    return result
  end
  env.proxy=function(address) return assert(proxies[address]) end
  env.readText=function(path) return files[path] end
  env.writeText=function(path,text) files[path]=text end
  env.exists=function(path) return files[path]~=nil or path=='/data' end
  env.remove=function(path) files[path]=nil; return true end
  env.rename=function(source,target) files[target]=files[source]; files[source]=nil; return true end
  env.mkdir=function(path) files[path]=files[path] or ''; return true end
  env.serialize=function(value) saved.value=value; return 'SERIALIZED' end
  env.unserialize=function(text)
    if text=='SERIALIZED' then return saved.value end
    error('bad serialization')
  end
  env.sleep=function() end
  env.print=function() end
  env.chooseRole=function() return 1 end
  return env,control
end
"""


class TopologyTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.module = self.lua.execute((ROOT / "src/topology.lua").read_text())
        self.lua.execute(HARNESS)
        self.env, self.control = self.lua.globals().makeTopologyEnvironment()
        self.engine = self.module.new(self.env)

    def issue_kinds(self, issues):
        return [issues[index]["kind"] for index in range(1, len(issues) + 1)]

    def test_missing_topology_is_reported_without_creating_it(self):
        topology, reason = self.engine.load(self.engine)
        self.assertIsNone(topology)
        self.assertEqual("missing", reason)

    def test_bind_discovers_modules_assigns_roles_and_saves(self):
        topology = self.engine.bind(self.engine, False)
        self.assertEqual("OCTOPOLOGY1", topology["schema"])
        self.assertEqual(2, len(topology["modules"]))
        self.assertEqual(1, len(topology["roles"]["mutatrons"]))
        self.assertEqual(1, len(topology["roles"]["advancedMutatrons"]))
        self.assertEqual(1, len(topology["roles"]["imprinters"]))
        self.assertEqual("t1", topology["roles"]["manualReturn"]["transposer"])
        self.assertEqual(4, topology["roles"]["manualReturn"]["side"])
        loaded = self.engine.load(self.engine)
        self.assertEqual("OCTOPOLOGY1", loaded["schema"])
        self.assertEqual(0, len(self.engine.verify(self.engine, loaded)))

    def test_changed_machine_requests_rebind(self):
        topology = self.engine.bind(self.engine, False)
        self.control["names"]["t1"][2] = "minecraft:chest"
        self.assertIn("changed", self.issue_kinds(self.engine.verify(self.engine, topology)))

    def test_temporarily_missing_component_is_unavailable(self):
        topology = self.engine.bind(self.engine, False)
        self.control["hide"] = "t1"
        self.assertIn("unavailable", self.issue_kinds(self.engine.verify(self.engine, topology)))

    def test_manual_result_does_not_block_task_check_startup(self):
        topology = self.engine.bind(self.engine, False)
        self.control["stacks"]["t1"][4] = self.lua.table_from({1: self.lua.table_from({"name": "forestry:bee_queen_ge", "size": 1})})
        kinds = self.issue_kinds(self.engine.verify(self.engine, topology))
        self.assertNotIn("busy", kinds)
        self.assertNotIn("changed", kinds)

    def test_ensure_creates_missing_topology_on_first_interactive_run(self):
        topology = self.engine.ensure(self.engine, True)
        self.assertEqual("OCTOPOLOGY1", topology["schema"])
        self.assertIsNotNone(self.control["files"]["/data/topology"])

    def test_noninteractive_check_never_creates_missing_topology(self):
        with self.assertRaises(Exception):
            self.engine.ensure(self.engine, False)
        self.assertIsNone(self.control["files"]["/data/topology"])

    def test_retry_after_temporary_component_outage(self):
        self.engine.bind(self.engine, False)
        self.control["hide"] = "t1"
        restore_and_retry = self.lua.eval("function(control) return function() control.hide=nil; return 'c' end end")
        self.env["readLine"] = restore_and_retry(self.control)
        topology = self.engine.ensure(self.engine, True)
        self.assertEqual(0, len(self.engine.verify(self.engine, topology)))

    def test_player_can_choose_rebind_after_detected_change(self):
        self.engine.bind(self.engine, False)
        self.control["names"]["t1"][2] = "minecraft:chest"
        restore_and_rebind = self.lua.eval(
            "function(control) return function() control.names.t1[2]='gendustry:mutatron_advanced'; return 'r' end end"
        )
        self.env["readLine"] = restore_and_rebind(self.control)
        topology = self.engine.ensure(self.engine, True)
        self.assertEqual(0, len(self.engine.verify(self.engine, topology)))

    def test_busy_interface_blocks_without_offering_rebind(self):
        self.engine.bind(self.engine, False)
        self.control["requests"]["i1"][1] = self.lua.table_from({"existing": True})
        self.env["readLine"] = self.lua.eval("function() error('must not prompt') end")
        with self.assertRaises(Exception):
            self.engine.ensure(self.engine, True)
        self.assertTrue(self.control["requests"]["i1"][1]["existing"])

    def test_all_lua_sources_compile_as_lua_52(self):
        loader = self.lua.eval("load")
        for path in (ROOT / "src").glob("*.lua"):
            compiled = loader(path.read_text())
            if isinstance(compiled, tuple):
                compiled, reason = compiled
                self.assertIsNotNone(compiled, f"{path.name}: {reason}")
            else:
                self.assertIsNotNone(compiled, path.name)
        compiled = loader((ROOT / "opencombkeeper.lua").read_text())
        if isinstance(compiled, tuple):
            compiled, reason = compiled
            self.assertIsNotNone(compiled, f"opencombkeeper.lua: {reason}")
        else:
            self.assertIsNotNone(compiled)

    def test_existing_interface_request_is_busy_and_not_overwritten_by_bind(self):
        self.control["requests"]["i1"][1] = self.lua.table_from({"existing": True})
        with self.assertRaises(Exception):
            self.engine.bind(self.engine, False)
        self.assertTrue(self.control["requests"]["i1"][1]["existing"])

    def test_invalid_saved_topology_is_preserved(self):
        self.control["files"]["/data/topology"] = "CORRUPT"
        topology, reason = self.engine.load(self.engine)
        self.assertIsNone(topology)
        self.assertIn("preserve", reason)
        self.assertEqual("CORRUPT", self.control["files"]["/data/topology"])

    def test_damaged_topology_requires_explicit_rebind_choice(self):
        self.control["files"]["/data/topology"] = "CORRUPT"
        self.env["readLine"] = self.lua.eval("function() return 'r' end")
        topology = self.engine.ensure(self.engine, True)
        self.assertEqual("OCTOPOLOGY1", topology["schema"])
        self.assertEqual("CORRUPT", self.control["files"]["/data/topology.bak"])

    def test_damaged_topology_is_not_replaced_when_player_quits(self):
        self.control["files"]["/data/topology"] = "CORRUPT"
        self.env["readLine"] = self.lua.eval("function() return 'q' end")
        with self.assertRaises(Exception):
            self.engine.ensure(self.engine, True)
        self.assertEqual("CORRUPT", self.control["files"]["/data/topology"])


if __name__ == "__main__":
    unittest.main()
