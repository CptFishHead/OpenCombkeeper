import unittest
from pathlib import Path

from lupa.lua52 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]

HARNESS = r"""
function makeHardwareEnvironment()
  local files,serialized,proxies,kinds,methods={},{},{},{},{}
  local sequence,clock=0,0
  local network={}
  local control={files=files,network=network,mutationResult='result'}

  local function clone(value)
    if type(value)~='table' then return value end
    local result={}; for key,row in pairs(value) do result[key]=clone(row) end; return result
  end
  local function bee(uid,kind,size)
    return {name='forestry:bee_'..kind..'_ge',label=uid..' '..kind,size=size or 1,
      individual={ident=uid}}
  end
  function control.add(uid,kind,size) network[#network+1]=bee(uid,kind,size) end
  local function physicalKind(value)
    local name=tostring(value.name or '')
    if name:find('bee_princess',1,true) then return 'princess' end
    if name:find('bee_drone',1,true) then return 'drone' end
    if name:find('bee_queen',1,true) then return 'queen' end
  end
  local function take(uid,kind)
    for index,value in pairs(network) do
      if value.individual and value.individual.ident==uid and physicalKind(value)==kind and value.size>0 then
        value.size=value.size-1; local result=clone(value); result.size=1
        if value.size==0 then network[index]=nil end
        return result
      end
    end
  end
  local function put(value)
    for _,current in pairs(network) do
      local currentId=current.individual and current.individual.ident
      local valueId=value.individual and value.individual.ident
      if current.name==value.name and currentId==valueId then
        current.size=current.size+value.size; return
      end
    end
    network[#network+1]=clone(value)
  end

  local dbSlots={}
  proxies.db={get=function(slot) return dbSlots[slot] end,
    clear=function(slot) dbSlots[slot]=nil; return true end,
    indexOf=function() return 0 end}
  kinds.db='database'; methods.db={get=false,clear=false,indexOf=false}

  local stacks,names={prod={},out={}},{prod={[0]='appliedenergistics2:interface',
    [1]='gendustry:industrial_apiary',[2]='gendustry:mutatron',[3]='gendustry:imprinter',
    [4]='ironchest:iron_chest'},out={[0]='appliedenergistics2:interface',[1]='ironchest:iron_chest'}}
  for _,id in ipairs({'prod','out'}) do for side=0,5 do stacks[id][side]={} end end
  stacks.prod[2][4]={name='gendustry:labware',label='Genetics Labware',size=16}
  stacks.prod[3][1]={name='gendustry:gene_template',label='Gene Template',size=1}
  stacks.prod[3][2]={name='gendustry:labware',label='Genetics Labware',size=16}

  local function transposer(id)
    return {
      getInventoryName=function(side) return names[id][side] end,
      getInventorySize=function(side) return names[id][side] and (side==1 and id=='out' and 108 or 15) end,
      getStackInSlot=function(side,slot) return stacks[id][side][slot] end,
      transferItem=function(fromSide,toSide,count,fromSlot,toSlot)
        local value=stacks[id][fromSide][fromSlot]
        if not value or value.size<=0 then return 0 end
        local moved=math.min(count,value.size); local part=clone(value); part.size=moved
        value.size=value.size-moved; if value.size==0 then stacks[id][fromSide][fromSlot]=nil end
        if names[id][toSide]=='appliedenergistics2:interface' then put(part)
        else
          if not toSlot then
            for slot=1,108 do if not stacks[id][toSide][slot] then toSlot=slot; break end end
          end
          if stacks[id][toSide][toSlot] then return 0 end
          stacks[id][toSide][toSlot]=part
          if id=='prod' and toSide==2 and stacks.prod[2][1] and stacks.prod[2][2] then
            stacks.prod[2][1]=nil; stacks.prod[2][2]=nil
            stacks.prod[2][3]=bee(control.mutationResult,'queen',1)
          elseif id=='prod' and toSide==3 and toSlot==3 then
            stacks.prod[3][3]=nil
            if control.imprinterWasteKind==physicalKind(part) then
              control.imprinterWasteKind=nil
              stacks.prod[3][4]={name='gendustry:waste',label='Genetic Waste',size=1}
            else stacks.prod[3][4]=part end
          elseif id=='prod' and toSide==1 and toSlot==1 and physicalKind(part)=='queen' then
            stacks.prod[1][1]=nil
            stacks.prod[1][7]=bee(part.individual.ident,'princess',1)
            stacks.prod[1][8]=bee(part.individual.ident,'drone',2)
          end
        end
        return moved
      end,
      getFluidInTank=function() return {amount=1000} end
    }
  end
  proxies.prod=transposer('prod'); proxies.out=transposer('out')
  kinds.prod='transposer'; kinds.out='transposer'; methods.prod={}; methods.out={}

  local requests={}
  local function interface(id,transposerId)
    requests[id]={}
    return {
      getItemsInNetwork=function() return network end,
      store=function(filter,databaseAddress,slot)
        for _,value in pairs(network) do
          if value.name==filter.name and value.label==filter.label and value.size>0 then
            dbSlots[slot]=clone(value); dbSlots[slot].size=1; return true
          end
        end
        return false,'missing'
      end,
      getInterfaceConfiguration=function(slot) return requests[id][slot] end,
      setInterfaceConfiguration=function(slot,databaseAddress,databaseSlot,count)
        requests[id][slot]=databaseAddress and {database=databaseAddress,slot=databaseSlot,count=count} or nil
        if databaseAddress then
          local descriptor=dbSlots[databaseSlot]
          local uid=descriptor.individual.ident; local kind=physicalKind(descriptor)
          stacks[transposerId][0][1]=assert(take(uid,kind))
        end
        return true
      end
    }
  end
  proxies.iprod=interface('iprod','prod'); proxies.iout=interface('iout','out')
  kinds.iprod='me_interface'; kinds.iout='me_interface'
  methods.iprod={getItemsInNetwork=false}; methods.iout={getItemsInNetwork=false}

  local component={}
  component.proxy=function(address) return assert(proxies[address]) end
  component.methods=function(address) return assert(methods[address]) end
  component.list=function() return next,kinds,nil end
  local filesystem={exists=function(path) return files[path]~=nil or path=='/home/.opencombkeeper-data' end,
    makeDirectory=function() return true end,
    remove=function(path) files[path]=nil; return true end,
    rename=function(source,target) files[target]=files[source]; files[source]=nil; return true end}
  local serialization={serialize=function(value)
      sequence=sequence+1; local key='S'..sequence; serialized[key]=clone(value); return key end,
    unserialize=function(text) return clone(assert(serialized[text])) end}
  local computer={uptime=function() clock=clock+1; return clock end}
  local environment={component=component,filesystem=filesystem,serialization=serialization,
    computer=computer,sleep=function() clock=clock+1 end,print=function() end,
    readText=function(path) return files[path] end,
    writeText=function(path,text) files[path]=text end}
  local topology={schema='OCTOPOLOGY2',modules={
      {transposer='prod',interfaceSide=0,interface='iprod'},
      {transposer='out',interfaceSide=0,interface='iout'}},
    productionModules={{id=1,transposer='prod',climate='plains',
      apiary={transposer='prod',side=1,name='gendustry:industrial_apiary'},
      mutatron={transposer='prod',side=2,name='gendustry:mutatron'},
      imprinter={transposer='prod',side=3,name='gendustry:imprinter'},
      chest={transposer='prod',side=4,name='ironchest:iron_chest'}}},
    producerOutput={transposer='out',side=1,name='ironchest:iron_chest'}}
  control.add('root','princess',1); control.add('donor','drone',1)
  return environment,topology,control,stacks
end
"""


class HardwareTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.env, self.topology, self.control, self.stacks = self.lua.globals().makeHardwareEnvironment()
        self.lua.globals().OPENCOMBKEEPER_HARDWARE_ENV = self.env
        self.module = self.lua.execute((ROOT / "src/hardware.lua").read_text())
        self.module.configure(self.topology)

    def action(self, source):
        return self.lua.eval(source)

    def state(self):
        return self.lua.eval("{schema=1,status='ready',lines={},tasks={},history={}}")

    def test_mutation_returns_identified_queen_and_persists_state(self):
        action = self.action("{type='mutation',profile='plains',moduleSlot=1,"
                             "carrier='root',drone='donor',result='result'}")
        result = self.module.perform(action)
        self.assertEqual("queen", result["kind"])
        self.assertEqual("result", result["species"])
        self.assertEqual("result", self.stacks["prod"][4][1]["individual"]["ident"])
        self.module.save(self.state())
        self.assertIsNotNone(self.control["files"]["/home/.opencombkeeper-data/executor-state"])
        self.assertIsNone(self.control["files"]["/home/.opencombkeeper-data/hardware-operation"])

    def test_princess_imprinter_waste_stops_before_mutatron(self):
        self.control["imprinterWasteKind"] = "princess"
        result = self.module.perform(self.action(
            "{type='mutation',profile='plains',moduleSlot=1,carrier='root',"
            "drone='donor',result='result'}"))
        self.assertEqual("genetic_waste", result["kind"])
        self.assertIsNone(self.stacks["prod"][2][1])
        self.assertIsNone(self.stacks["prod"][2][2])
        self.module.save(self.state())

    def test_incubation_keeps_princess_local_and_publishes_drones(self):
        self.control.add("result", "queen", 1)
        result = self.module.perform(self.action(
            "{type='incubate',profile='plains',moduleSlot=1,species='result'}"))
        self.assertTrue(result["accepted"])
        self.assertIn("princess", self.stacks["prod"][4][1]["name"])
        self.assertEqual(2, self.module.countDrones("result"))
        self.module.save(self.state())

    def test_final_queen_is_moved_to_output_chest(self):
        self.stacks["prod"][4][1] = self.lua.eval(
            "{name='forestry:bee_queen_ge',size=1,individual={ident='result'}}")
        result = self.module.perform(self.action(
            "{type='deliver_producer',profile='plains',moduleSlot=1,species='result'}"))
        self.assertTrue(result["accepted"])
        self.assertEqual("result", self.stacks["out"][1][1]["individual"]["ident"])
        self.module.save(self.state())

    def test_manual_or_legacy_final_queen_can_be_delivered_from_me(self):
        self.control.add("result", "queen", 1)
        result = self.module.perform(self.action(
            "{type='deliver_producer',profile='plains',moduleSlot=1,species='result'}"))
        self.assertTrue(result["accepted"])
        self.assertEqual("result", self.stacks["out"][1][1]["individual"]["ident"])

    def test_uncommitted_completed_operation_blocks_restart(self):
        self.stacks["prod"][4][1] = self.lua.eval(
            "{name='forestry:bee_queen_ge',size=1,individual={ident='result'}}")
        self.module.perform(self.action(
            "{type='deliver_producer',profile='plains',moduleSlot=1,species='result'}"))
        restarted = self.module._newForTest(self.env)
        restarted.configure(self.topology)
        with self.assertRaises(Exception):
            restarted.load()
        with self.assertRaises(Exception):
            restarted.resetEmpty()

    def test_completed_operation_can_be_committed_after_restart(self):
        self.stacks["prod"][4][1] = self.lua.eval(
            "{name='forestry:bee_queen_ge',size=1,individual={ident='result'}}")
        self.module.perform(self.action(
            "{type='deliver_producer',profile='plains',moduleSlot=1,species='result'}"))
        restarted = self.module._newForTest(self.env)
        restarted.configure(self.topology)
        engine = self.lua.eval(
            "function(h) return {state={history={}},complete=function(self,action,result) "
            "h.save({schema=1,status='ready',lines={},tasks={},history={}}); return true end} end"
        )(restarted)
        self.assertTrue(restarted.recoverCompleted(engine))
        self.assertIsNone(self.control["files"]["/home/.opencombkeeper-data/hardware-operation-plains-1"])

    def test_hardware_check_validates_starting_princesses(self):
        self.assertTrue(self.module.check(self.action(
            "{startingPrincesses={root=1}}")))
        with self.assertRaises(Exception):
            self.module.check(self.action("{startingPrincesses={root=2}}"))

    def test_hardware_check_validates_starting_drones(self):
        self.assertTrue(self.module.check(self.action(
            "{startingPrincesses={root=1},startingDrones={donor=1}}")))
        with self.assertRaises(Exception):
            self.module.check(self.action(
                "{startingPrincesses={root=1},startingDrones={donor=2}}"))

    def test_empty_reset_clears_failed_operation(self):
        with self.assertRaises(Exception):
            self.module.perform(self.action(
                "{type='mutation',profile='plains',moduleSlot=1,carrier='missing',"
                "drone='donor',result='result'}"))
        self.module.resetEmpty()
        self.assertIsNone(self.control["files"]["/home/.opencombkeeper-data/hardware-operation"])


if __name__ == "__main__":
    unittest.main()
