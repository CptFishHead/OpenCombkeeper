import unittest
from pathlib import Path

from lupa.lua52 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r"""
function makeTopologyEnvironment()
  local files,saved,names,stacks,requests,proxies,all={},{},{},{},{},{},{}
  local control={hide=nil,names=names,stacks=stacks,requests=requests,files=files}
  local function addTransposer(id,inventoryNames,upgrades)
    names[id]=inventoryNames; stacks[id]={}; if upgrades then stacks[id][1]=upgrades end
    proxies[id]={getInventoryName=function(side) return names[id][side] end,
      getInventorySize=function(side) return names[id][side] and 9 or nil end,
      getStackInSlot=function(side,slot) local x=stacks[id][side]; return x and x[slot] or nil end}
    all[#all+1]={address=id,kind='transposer',methods={},proxy=proxies[id]}
  end
  local databaseSlots={}
  proxies.db={get=function(slot) return databaseSlots[slot] end,
    clear=function(slot) databaseSlots[slot]=nil; return true end}
  local function addInterface(number,transposerId)
    local id='i'..number; requests[id]={}
    proxies[id]={getInterfaceConfiguration=function(slot) return requests[id][slot] end,
      setInterfaceConfiguration=function(slot,databaseAddress,databaseSlot,count)
        requests[id][slot]=databaseAddress and {database=databaseAddress,slot=databaseSlot,count=count} or nil
        stacks[transposerId][0]=stacks[transposerId][0] or {}
        stacks[transposerId][0][1]=databaseAddress and {name='minecraft:cobblestone',size=1} or nil
        return true
      end,
      store=function(filter,databaseAddress,databaseSlot,count)
        databaseSlots[databaseSlot]={name='minecraft:cobblestone',size=1}; return true end}
    all[#all+1]={address=id,kind='me_interface',
      methods={setInterfaceConfiguration=false,getInterfaceConfiguration=false},proxy=proxies[id]}
  end
  local labels={[5]='Jungle Emulation Upgrade',[6]='Desert Emulation Upgrade',
    [7]='Winter Emulation Upgrade',[8]='Hell Emulation Upgrade'}
  for n=1,8 do
    local id='t'..string.format('%02d',n)
    local upgrades=labels[n] and {[3]={name='gendustry:upgrade',label=labels[n],size=1}} or nil
    addTransposer(id,{[0]='appliedenergistics2:interface',[1]='gendustry:industrial_apiary',
      [2]='gendustry:mutatron',[3]='gendustry:imprinter',[4]='minecraft:chest'},upgrades)
    addInterface(n,id)
  end
  for n=9,12 do
    local id='t'..string.format('%02d',n)
    addTransposer(id,{[0]='appliedenergistics2:interface',[1]='gendustry:mutatron_advanced'})
    addInterface(n,id)
  end
  addTransposer('t13',{[0]='appliedenergistics2:interface',[1]='minecraft:chest'}); addInterface(13,'t13')
  all[#all+1]={address='db',kind='database',methods={computeHash=false,get=false,indexOf=false},proxy=proxies.db}
  local env={path='/data/topology',pendingPath='/data/bind-pending'}
  env.components=function() local result={} for _,row in ipairs(all) do
    if row.address~=control.hide then result[#result+1]=row end end return result end
  env.proxy=function(address) return assert(proxies[address]) end
  env.readText=function(path) return files[path] end; env.writeText=function(path,text) files[path]=text end
  env.exists=function(path) return files[path]~=nil or path=='/data' end
  env.remove=function(path) files[path]=nil; return true end
  env.rename=function(source,target) files[target]=files[source]; files[source]=nil; return true end
  env.mkdir=function(path) files[path]=files[path] or ''; return true end
  env.serialize=function(value) saved.value=value; return 'SERIALIZED' end
  env.unserialize=function(text) if text=='SERIALIZED' then return saved.value end error('bad serialization') end
  env.sleep=function() end; env.print=function() end; env.chooseRole=function() return 1 end
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
        self.assertIsNone(topology); self.assertEqual("missing", reason)

    def test_bind_discovers_exact_installation_and_climates(self):
        topology = self.engine.bind(self.engine, False)
        self.assertEqual("OCTOPOLOGY2", topology["schema"])
        self.assertEqual(13, len(topology["modules"])); self.assertEqual(8, len(topology["productionModules"]))
        self.assertEqual(4, len(topology["advancedMutatrons"]))
        climates = [topology["productionModules"][i]["climate"] for i in range(1, 9)]
        self.assertEqual(["plains"] * 4 + ["jungle", "desert", "winter", "hell"], climates)
        self.assertEqual("t13", topology["producerOutput"]["transposer"])
        self.assertEqual(0, len(self.engine.verify(self.engine, self.engine.load(self.engine))))

    def test_changed_machine_requests_rebind(self):
        topology = self.engine.bind(self.engine, False); self.control["names"]["t09"][1] = "minecraft:chest"
        self.assertIn("changed", self.issue_kinds(self.engine.verify(self.engine, topology)))

    def test_changed_emulator_requests_rebind(self):
        topology = self.engine.bind(self.engine, False)
        self.control["stacks"]["t05"][1][3]["label"] = "Desert Emulation Upgrade"
        self.assertIn("changed", self.issue_kinds(self.engine.verify(self.engine, topology)))

    def test_temporarily_missing_component_is_unavailable(self):
        topology = self.engine.bind(self.engine, False); self.control["hide"] = "t01"
        self.assertIn("unavailable", self.issue_kinds(self.engine.verify(self.engine, topology)))

    def test_ensure_creates_missing_topology_on_first_interactive_run(self):
        topology = self.engine.ensure(self.engine, True)
        self.assertEqual("OCTOPOLOGY2", topology["schema"])
        self.assertIsNotNone(self.control["files"]["/data/topology"])

    def test_noninteractive_check_never_creates_missing_topology(self):
        with self.assertRaises(Exception): self.engine.ensure(self.engine, False)
        self.assertIsNone(self.control["files"]["/data/topology"])

    def test_retry_after_temporary_component_outage(self):
        self.engine.bind(self.engine, False); self.control["hide"] = "t01"
        self.env["readLine"] = self.lua.eval(
            "function(control) return function() control.hide=nil; return 'c' end end")(self.control)
        topology = self.engine.ensure(self.engine, True)
        self.assertEqual(0, len(self.engine.verify(self.engine, topology)))

    def test_busy_interface_blocks_without_overwrite(self):
        self.engine.bind(self.engine, False); self.control["requests"]["i1"][1] = self.lua.table_from({"existing": True})
        self.env["readLine"] = self.lua.eval("function() error('must not prompt') end")
        with self.assertRaises(Exception): self.engine.ensure(self.engine, True)
        self.assertTrue(self.control["requests"]["i1"][1]["existing"])

    def test_bind_refuses_incomplete_production_module(self):
        self.control["names"]["t01"][3] = None
        with self.assertRaises(Exception): self.engine.bind(self.engine, False)

    def test_invalid_saved_topology_is_preserved(self):
        self.control["files"]["/data/topology"] = "CORRUPT"
        topology, reason = self.engine.load(self.engine)
        self.assertIsNone(topology); self.assertIn("preserve", reason)
        self.assertEqual("CORRUPT", self.control["files"]["/data/topology"])

    def test_damaged_topology_requires_explicit_rebind_choice(self):
        self.control["files"]["/data/topology"] = "CORRUPT"
        self.env["readLine"] = self.lua.eval("function() return 'r' end")
        topology = self.engine.ensure(self.engine, True)
        self.assertEqual("OCTOPOLOGY2", topology["schema"])
        self.assertEqual("CORRUPT", self.control["files"]["/data/topology.bak"])

    def test_all_lua_sources_compile_as_lua_52(self):
        loader = self.lua.eval("load")
        for path in list((ROOT / "src").glob("*.lua")) + [ROOT / "opencombkeeper.lua", ROOT / "install.lua"]:
            compiled = loader(path.read_text())
            if isinstance(compiled, tuple): compiled, reason = compiled; self.assertIsNotNone(compiled, reason)
            else: self.assertIsNotNone(compiled, path.name)

if __name__ == "__main__":
    unittest.main()
