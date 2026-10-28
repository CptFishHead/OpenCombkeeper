import unittest
from pathlib import Path

from lupa.lua52 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


HARNESS = r"""
function runEntrypoint(source,command)
  local calls={}
  local topology={}
  function topology:scan() calls.scan=(calls.scan or 0)+1 end
  function topology:bind(recover) calls.bind=recover and 'reset' or 'bind'; return {schema='OCTOPOLOGY2'} end
  function topology:load() return {schema='OCTOPOLOGY2'} end
  function topology:display() calls.display=(calls.display or 0)+1 end
  function topology:ensure(interactive) calls.ensure=interactive; return {schema='OCTOPOLOGY2'} end
  local engine={}
  function engine:summary() return {status='ready'} end
  function engine:checkAllTasks() calls.manualCheck=(calls.manualCheck or 0)+1; return 1,2 end
  function engine:nextAction() return nil end
  local executor={new=function() calls.executorLoaded=true; return engine end}
  local hardware={configure=function(value) calls.configured=value.schema end,load=function() return nil end,
    check=function(plan) calls.hardwareCheck=plan.schema; return true end,
    resetEmpty=function() calls.hardwareReset=true; return true end,
    loadPendingState=function() calls.pendingLoaded=true; return nil end,
    recoverCompleted=function(pendingEngine) calls.hardwareRecovered=pendingEngine==engine; return true end}
  local fakeComponent={list=function() return function() end end,proxy=function() return {} end,methods=function() return {} end}
  local fakeFilesystem={exists=function() return true end,remove=function() return true end,
    rename=function() return true end,makeDirectory=function() return true end}
  local fakeSerialization={serialize=function() return '{}' end,unserialize=function() return {} end}
  local oldRequire,oldLoadfile,oldOpen,oldPrint=require,loadfile,io.open,print
  require=function(name)
    if name=='component' then return fakeComponent end
    if name=='filesystem' then return fakeFilesystem end
    if name=='serialization' then return fakeSerialization end
    return oldRequire(name)
  end
  loadfile=function(path)
    if path:match('topology%.lua$') then return function() return {new=function() return topology end} end end
    if path:match('plan%.lua$') then return function() return {schema=1} end end
    if path:match('executor%.lua$') then return function() return executor end end
    if path:match('hardware%.lua$') then return function() return hardware end end
    return nil,'unexpected path '..path
  end
  io.open=function() return {read=function() return nil end,close=function() return true end} end
  print=function() end
  local chunk,reason=load(source)
  assert(chunk,reason)
  local ok,result=pcall(chunk,command)
  require,loadfile,io.open,print=oldRequire,oldLoadfile,oldOpen,oldPrint
  assert(ok,result)
  return result,calls
end
"""


class EntrypointTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.source = (ROOT / "opencombkeeper.lua").read_text()

    def run_entrypoint(self, command):
        return self.lua.globals().runEntrypoint(self.source, command)

    def test_check_validates_topology_and_checks_manual_tasks(self):
        result, calls = self.run_entrypoint("check")
        self.assertTrue(result)
        self.assertFalse(calls["ensure"])
        self.assertEqual(1, calls["manualCheck"])
        self.assertTrue(calls["executorLoaded"])

    def test_topology_check_does_not_load_executor_or_hardware(self):
        result, calls = self.run_entrypoint("topology-check")
        self.assertTrue(result)
        self.assertFalse(calls["ensure"])
        self.assertIsNone(calls["executorLoaded"])

    def test_run_uses_interactive_topology_check(self):
        result, calls = self.run_entrypoint("run")
        self.assertTrue(result)
        self.assertTrue(calls["ensure"])
        self.assertEqual("OCTOPOLOGY2", calls["configured"])

    def test_hardware_check_is_read_only_and_uses_runtime_plan(self):
        result, calls = self.run_entrypoint("hardware-check")
        self.assertTrue(result)
        self.assertEqual(1, calls["hardwareCheck"])
        self.assertIsNone(calls["executorLoaded"])

    def test_completed_hardware_operation_can_be_recovered(self):
        result, calls = self.run_entrypoint("hardware-recover")
        self.assertTrue(result)
        self.assertTrue(calls["pendingLoaded"])
        self.assertTrue(calls["hardwareRecovered"])


if __name__ == "__main__":
    unittest.main()
