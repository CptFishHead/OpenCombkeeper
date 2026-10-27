-- OpenCombkeeper 0.1.0 OpenOS entry point.
local function loadFile(path)
  local chunk,reason=loadfile(path)
  assert(chunk,reason)
  return chunk()
end

local root='/home/.opencombkeeper'
local plan=loadFile(root..'/plan.lua')
local executor=loadFile(root..'/executor.lua')

-- The entry point intentionally refuses to move items without an installed
-- hardware adapter. Planning and state transitions stay testable off-game.
local adapterPath=root..'/hardware.lua'
local file=io.open(adapterPath,'r')
assert(file,'Missing '..adapterPath..'; run the hardware binding installer')
file:close()
local hardware=loadFile(adapterPath)
local state=hardware.load and hardware.load() or nil
local engine=executor.new(plan,hardware,state)

local command=(...)
if command=='status' then
  local summary=engine:summary()
  for key,value in pairs(summary) do print(key..': '..tostring(value)) end
elseif command=='check' then
  local done,total=engine:checkAllTasks(); print('Manual tasks: '..done..'/'..total)
elseif command=='run' then
  while true do
    local action=engine:nextAction()
    if not action then break end
    if action.type=='manual_task' then
      print('WAIT '..action.task..' (run: opencombkeeper check)')
      break
    end
    assert(hardware.perform,'Hardware adapter has no perform(action)')
    local result=hardware.perform(action)
    assert(result,'Hardware adapter returned no result')
    engine:complete(action,result)
  end
  local summary=engine:summary(); print('Status: '..summary.status)
else
  error('Usage: opencombkeeper status|check|run')
end
