-- OpenCombkeeper 0.3.2 OpenOS entry point.
local function loadFile(path)
  local chunk,reason=loadfile(path)
  assert(chunk,reason)
  return chunk()
end

local root='/home/.opencombkeeper'
local dataRoot='/home/.opencombkeeper-data'
local component=require('component')
local filesystem=require('filesystem')
local serialization=require('serialization')

local function readText(path)
  local file=io.open(path,'r'); if not file then return nil end
  local text=file:read('*a'); file:close(); return text
end

local function writeText(path,text)
  local file=assert(io.open(path,'w')); assert(file:write(text)); assert(file:flush())
  local closed,reason=file:close(); assert(closed~=false,reason)
end

local function components()
  local rows={}
  for address,kind in component.list() do
    local okMethods,methods=pcall(component.methods,address)
    local okProxy,proxy=pcall(component.proxy,address)
    if okMethods and okProxy and type(methods)=='table' and proxy then
      rows[#rows+1]={address=address,kind=kind,methods=methods,proxy=proxy}
    end
  end
  return rows
end

local topologyEngine=loadFile(root..'/topology.lua').new({
  path=dataRoot..'/topology',pendingPath=dataRoot..'/bind-pending',components=components,
  proxy=component.proxy,readText=readText,writeText=writeText,exists=filesystem.exists,
  remove=filesystem.remove,rename=filesystem.rename,mkdir=filesystem.makeDirectory,
  serialize=serialization.serialize,unserialize=serialization.unserialize,sleep=os.sleep,
  readLine=io.read,print=print
})

local command=(...) or 'run'

local function execute()
if command=='scan' then topologyEngine:scan(); return true end
if command=='bind' or command=='rebind' then topologyEngine:bind(false); return true end
if command=='bind-reset' then topologyEngine:bind(true); return true end
if command=='topology' or command=='modules' then
  local saved,reason=topologyEngine:load()
  if not saved then print(reason=='missing' and 'No saved topology. Run opencombkeeper bind.' or reason); return false end
  topologyEngine:display(saved); return true
end

if command=='topology-check' then topologyEngine:ensure(false); return true end

local topology=topologyEngine:ensure(command=='run')
local plan=loadFile(root..'/plan.lua')
local executor=loadFile(root..'/executor.lua')

-- The entry point intentionally refuses to move items without an installed
-- hardware adapter. Planning and state transitions stay testable off-game.
local adapterPath=root..'/hardware.lua'
local file=io.open(adapterPath,'r')
assert(file,'Missing '..adapterPath..'; run the hardware binding installer')
file:close()
local hardware=loadFile(adapterPath)
if hardware.configure then hardware.configure(topology) end
local state=hardware.load and hardware.load() or nil
local engine=executor.new(plan,hardware,state)

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
      print('WAIT '..action.task..' -> '..tostring(action.result))
      if action.parents then print('PARENTS '..table.concat(action.parents,' + ')) end
      print('Return the result to ME, then run: opencombkeeper check')
      break
    end
    assert(hardware.perform,'Hardware adapter has no perform(action)')
    local result=hardware.perform(action)
    assert(result,'Hardware adapter returned no result')
    engine:complete(action,result)
  end
  local summary=engine:summary(); print('Status: '..summary.status)
else
  error('Usage: opencombkeeper scan|bind|rebind|bind-reset|topology|topology-check|check|status|run')
end
return true
end

local ok,result=pcall(execute)
if not ok then print('OpenCombkeeper stopped: '..tostring(result)); return false end
return result
