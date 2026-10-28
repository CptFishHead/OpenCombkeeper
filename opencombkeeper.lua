-- OpenCombkeeper 0.4.10 OpenOS entry point.
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
local argument=select(2,...)

local effectRules={
  {key='radiation',label='Радиация (разрушает блоки)',default=false,
    species={'forestry.speciesVindictive','forestry.speciesVengeful','forestry.speciesAvenging'}},
  {key='entityRadiation',label='Нестабильность (урон существам)',species={'extrabees.species.unstable','extrabees.species.nuclear','extrabees.species.radioactive','extrabees.species.yellorium','extrabees.species.cyanite','extrabees.species.blutonium'}},
  {key='acid',label='Кислота (меняет камень и землю)',species={'extrabees.species.corrosive','extrabees.species.caustic','extrabees.species.acidic'}},
  {key='ectoplasm',label='Эктоплазма (ставит блоки)',species={'extrabees.species.viscous','extrabees.species.glutinous','extrabees.species.sticky'}},
  {key='creepers',label='Появление криперов',species={'extrabees.species.creeper'}},
  {key='lightning',label='Молнии',species={'extrabees.species.excited','extrabees.species.energetic'}},
  {key='meteor',label='Метеоры и огненные шары',species={'extrabees.species.tempered','extrabees.species.volcanic'}},
  {key='explosions',label='Взрывы',species={'forestry.speciesAustere','extrabees.species.hazardous'}},
  {key='ignition',label='Поджигание существ',species={'forestry.speciesDemonic'}},
  {key='freezing',label='Замерзание воды',species={'forestry.speciesWintry','forestry.speciesIcy','forestry.speciesGlacial'}},
  {key='aggressive',label='Агрессивность',species={'forestry.speciesSinister','forestry.speciesFiendish','extrabees.species.basalt','extrabees.species.glowstone'}},
  {key='poison',label='Яд',species={'forestry.speciesTropical','forestry.speciesExotic','extrabees.species.malicious','extrabees.species.infectious','extrabees.species.virulent'}}
}
local effectsPath=dataRoot..'/effects'
local function effectOptions()
  local text=readText(effectsPath)
  local value=text and serialization.unserialize(text) or {schema='EFFECTS1',effects={}}
  assert(type(value)=='table' and value.schema=='EFFECTS1' and type(value.effects)=='table','Invalid effects configuration')
  for _,rule in ipairs(effectRules) do if value.effects[rule.key]==nil then value.effects[rule.key]=rule.default~=false end end
  return value
end
local function saveEffects(value)
  if not filesystem.exists(dataRoot) then assert(filesystem.makeDirectory(dataRoot)) end
  local temporary=effectsPath..'.new'; writeText(temporary,serialization.serialize(value))
  if filesystem.exists(effectsPath) then assert(filesystem.remove(effectsPath)) end
  assert(filesystem.rename(temporary,effectsPath))
end
local function effectsMenu()
  local options=effectOptions()
  if argument then
    local found
    for _,rule in ipairs(effectRules) do if rule.key==argument then
      options.effects[rule.key]=not options.effects[rule.key]; found=true
    end end
    assert(found,'Unknown effect: '..tostring(argument)); saveEffects(options)
  end
  print('Опасные эффекты: разрешено [x] / запрещено [ ]')
  for _,rule in ipairs(effectRules) do print((options.effects[rule.key] and '[x] ' or '[ ] ')..rule.key..' — '..rule.label) end
  print('Переключить: opencombkeeper effects <key>')
  return true
end

local function applyEffectPolicy(plan)
  local options=effectOptions(); local blocked={}
  for _,rule in ipairs(effectRules) do if not options.effects[rule.key] then
    for _,uid in ipairs(rule.species) do blocked[uid]=rule.key end
  end end
  local mutations={}; for _,row in ipairs(plan.mutations or {}) do mutations[row.result]=row end
  local rejected,changed={},true
  while changed do
    changed=false
    for _,line in ipairs(plan.lines or {}) do if not rejected[line.id] then
      local reason
      for _,uid in ipairs(line.species or {}) do reason=reason or blocked[uid] end
      for step=2,#(line.species or {}) do
        local mutation=mutations[line.species[step]]
        for _,uid in ipairs(mutation and mutation.parents or {}) do reason=reason or blocked[uid] end
      end
      if reason then rejected[line.id]=reason; blocked[line.target]=reason; changed=true end
    end end
  end
  local lines,kept={},{}
  for _,line in ipairs(plan.lines or {}) do if not rejected[line.id] then lines[#lines+1]=line; kept[line.id]=true end end
  local tasks={}
  for _,task in ipairs(plan.manualTasks or {}) do
    if (not task.line or kept[task.line]) and not (task.species and blocked[task.species]) then tasks[#tasks+1]=task end
  end
  plan.lines=lines; plan.manualTasks=tasks
  local princesses,drones={},{}
  local rootDrones=plan.startingDrones or {}
  for _,line in ipairs(lines) do
    local route=line.species; princesses[route[1]]=(princesses[route[1]] or 0)+1
    for step=2,#route do
      local parents={table.unpack(mutations[route[step]].parents)}
      for index,uid in ipairs(parents) do if uid==route[step-1] then table.remove(parents,index); break end end
      local uid=parents[1] or route[step-1]
      if rootDrones[uid] then drones[uid]=(drones[uid] or 0)+1 end
    end
  end
  plan.startingPrincesses=princesses; plan.startingDrones=drones
  local count=0; for _ in pairs(rejected) do count=count+1 end
  if count>0 then print('EFFECT POLICY: skipped '..count..' unsafe lines') end
  return plan
end

local function execute()
if command=='scan' then topologyEngine:scan(); return true end
if command=='effects' then return effectsMenu() end
if command=='bind' or command=='rebind' then topologyEngine:bind(false); return true end
if command=='bind-reset' then topologyEngine:bind(true); return true end
if command=='topology' or command=='modules' then
  local saved,reason=topologyEngine:load()
  if not saved then print(reason=='missing' and 'No saved topology. Run opencombkeeper bind.' or reason); return false end
  topologyEngine:display(saved); return true
end

if command=='topology-check' then topologyEngine:ensure(false); return true end

local topology=topologyEngine:ensure(command=='run')
local plan=applyEffectPolicy(loadFile(root..'/plan.lua'))
local executor=loadFile(root..'/executor.lua')

-- The entry point intentionally refuses to move items without an installed
-- hardware adapter. Planning and state transitions stay testable off-game.
local adapterPath=root..'/hardware.lua'
local file=io.open(adapterPath,'r')
assert(file,'Missing '..adapterPath..'; run the hardware binding installer')
file:close()
local hardware=loadFile(adapterPath)
if hardware.configure then hardware.configure(topology) end
if command=='hardware-check' then return hardware.check(plan) end
if command=='hardware-reset' then return hardware.resetEmpty() end
if command=='hardware-recover' then
  local pendingState=hardware.loadPendingState()
  local pendingEngine=executor.new(plan,hardware,pendingState)
  return hardware.recoverCompleted(pendingEngine)
end
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
    if action.type=='blocked_resources' then
      print('WAIT missing drones: '..table.concat(action.missingDrones or {},', '))
      print('No executable predecessor line can currently produce them.')
      break
    end
    assert(hardware.perform,'Hardware adapter has no perform(action)')
    print('ACTION '..action.type..' '..tostring(action.species or action.result or action.carrier or ''))
    local result=hardware.perform(action)
    assert(result,'Hardware adapter returned no result')
    engine:complete(action,result)
  end
  local summary=engine:summary(); print('Status: '..summary.status)
else
  error('Usage: opencombkeeper scan|bind|rebind|bind-reset|topology|topology-check|effects|hardware-check|hardware-reset|hardware-recover|check|status|run')
end
return true
end

local ok,result=pcall(execute)
if not ok then print('OpenCombkeeper stopped: '..tostring(result)); return false end
return result
