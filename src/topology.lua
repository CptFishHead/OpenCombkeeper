-- OpenCombkeeper hardware discovery and crash-safe ME interface binding.
-- The marker protocol follows OpenBeekeeper: interface UUIDs are correlated
-- with transposer sides by requesting one harmless cobblestone.
local M={}

local SCHEMA='OCTOPOLOGY2'
local PENDING_SCHEMA='OCBIND1'
local BIND_TIMEOUT=20
local interfaceName='appliedenergistics2:interface'
local machineKinds={
  ['gendustry:mutatron']='mutatron',
  ['gendustry:imprinter']='imprinter',
  ['gendustry:industrial_apiary']='apiary'
}
local ignoredMachines={
  ['gendustry:mutatron_advanced']=true,
  ['gendustry:sampler']=true,
  ['forestry:analyzer']=true
}
local emulatorProfiles={
  ['Jungle Emulation Upgrade']='jungle',
  ['Desert Emulation Upgrade']='desert',
  ['Winter Emulation Upgrade']='winter',
  ['Hell Emulation Upgrade']='hell'
}
local sideNames={[0]='down','up','north','south','west','east'}

local function alive(value)
  return type(value)=='table' and (tonumber(value.size) or 0)>0
    and value.name~='minecraft:air' and value.name~='air'
end

local function copy(value,seen)
  if type(value)~='table' then return value end
  seen=seen or {}; if seen[value] then return seen[value] end
  local result={}; seen[value]=result
  for key,row in pairs(value) do result[copy(key,seen)]=copy(row,seen) end
  return result
end

local function endpointKey(endpoint)
  return tostring(endpoint.transposer)..':'..tostring(endpoint.side)
end

local function climateOfApiary(proxy,side)
  local profile,signature='plains',{}
  for slot=3,6 do
    local ok,value=pcall(proxy.getStackInSlot,side,slot)
    assert(ok,'Cannot inspect apiary upgrades at side '..side..', slot '..slot)
    if alive(value) then
      signature[#signature+1]=slot..':'..tostring(value.name)..':'..tostring(value.damage)..':'
        ..tostring(value.label)..':'..tostring(value.size)
      local selected=emulatorProfiles[value.label]
      if selected then
        assert(profile=='plains','Several biome emulators in apiary at side '..side)
        profile=selected
      end
    end
  end
  return profile,table.concat(signature,'|')
end

function M.new(env)
  assert(type(env)=='table','Topology environment required')
  for _,name in ipairs({'components','proxy','readText','writeText','exists','remove','rename','mkdir','serialize','unserialize'}) do
    assert(type(env[name])=='function','Missing topology environment callback: '..name)
  end
  local self={env=env,path=assert(env.path,'Topology path required')}
  self.pendingPath=env.pendingPath or self.path..'-bind-pending'
  return setmetatable(self,{__index=M})
end

function M:print(...)
  return (self.env.print or print)(...)
end

function M:call(method,...)
  assert(method~=nil,'Component method unavailable')
  local ok,value,reason=pcall(method,...)
  assert(ok,tostring(value))
  assert(value~=false,tostring(reason or 'Component operation rejected'))
  return value,reason
end

function M:componentSnapshot()
  local rows=assert(self.env.components())
  table.sort(rows,function(a,b) return a.address<b.address end)
  local byAddress={}
  for _,row in ipairs(rows) do byAddress[row.address]=row end
  return rows,byAddress
end

function M:discover()
  local entries=self:componentSnapshot()
  local transposers,interfaces,databases={},{},{}
  for _,entry in ipairs(entries) do
    local methods=entry.methods or {}
    if entry.kind=='transposer' then transposers[#transposers+1]=entry end
    if methods.setInterfaceConfiguration~=nil and methods.getInterfaceConfiguration~=nil then
      interfaces[#interfaces+1]=entry
    end
    if entry.kind=='database' or methods.computeHash~=nil and methods.get~=nil and methods.indexOf~=nil then
      databases[#databases+1]=entry
    end
  end
  local modules={}
  for _,entry in ipairs(transposers) do
    local module={entry=entry,interfaceSides={},inventories={}}
    for side=0,5 do
      local ok,name=pcall(entry.proxy.getInventoryName,side)
      if ok and type(name)=='string' then
        local sizeOk,size=pcall(entry.proxy.getInventorySize,side)
        local inventory={side=side,name=name,size=sizeOk and tonumber(size) or nil}
        module.inventories[#module.inventories+1]=inventory
        if name==interfaceName then module.interfaceSides[#module.interfaceSides+1]=side end
      end
    end
    if #module.inventories>0 then modules[#modules+1]=module end
  end
  return {entries=entries,transposers=transposers,interfaces=interfaces,databases=databases,modules=modules}
end

function M:scan()
  local found=self:discover()
  self:print('OpenCombkeeper 0.3.3 - read-only discovery')
  self:print('Transposers: '..#found.transposers)
  for _,module in ipairs(found.modules) do
    self:print('TRANSPOSER '..module.entry.address)
    for _,inventory in ipairs(module.inventories) do
      self:print(string.format('  SIDE %d (%s): %s [%s]',inventory.side,
        sideNames[inventory.side] or '?',inventory.name,tostring(inventory.size or '?')))
    end
  end
  self:print('Configurable ME interfaces: '..#found.interfaces)
  for _,entry in ipairs(found.interfaces) do self:print('  '..entry.address) end
  self:print('OC databases: '..#found.databases)
  for _,entry in ipairs(found.databases) do self:print('  '..entry.address) end
  return found
end

local function validateEndpoint(endpoint,label)
  assert(type(endpoint)=='table',label..' endpoint missing')
  assert(type(endpoint.transposer)=='string' and endpoint.transposer~='',label..' transposer missing')
  assert(type(endpoint.side)=='number' and endpoint.side%1==0 and endpoint.side>=0 and endpoint.side<=5,
    label..' side invalid')
  assert(type(endpoint.name)=='string' and endpoint.name~='',label..' inventory name missing')
end

function M:validate(topology)
  assert(type(topology)=='table' and topology.schema==SCHEMA,'Unsupported topology schema')
  assert(type(topology.modules)=='table' and #topology.modules>0,'Topology has no bound modules')
  local modules,interfaces={},{}
  for index,module in ipairs(topology.modules) do
    assert(type(module.transposer)=='string' and module.transposer~='','Module '..index..' transposer missing')
    assert(not modules[module.transposer],'Duplicate module transposer '..module.transposer)
    modules[module.transposer]=true
    assert(type(module.interface)=='string' and module.interface~='','Module '..index..' interface missing')
    assert(not interfaces[module.interface],'Duplicate module interface '..module.interface)
    interfaces[module.interface]=true
    assert(type(module.interfaceSide)=='number' and module.interfaceSide%1==0
      and module.interfaceSide>=0 and module.interfaceSide<=5,'Module '..index..' interface side invalid')
  end
  local used={}
  assert(type(topology.productionModules)=='table' and #topology.productionModules==8,
    'Exactly 8 production modules are required')
  local climates={plains=0,jungle=0,desert=0,winter=0,hell=0}
  for index,module in ipairs(topology.productionModules) do
    assert(type(module)=='table' and module.id==index,'Production module IDs must be consecutive')
    assert(modules[module.transposer],'Production module is outside bound modules')
    assert(climates[module.climate]~=nil,'Unknown production climate: '..tostring(module.climate))
    climates[module.climate]=climates[module.climate]+1
    for _,role in ipairs({'apiary','mutatron','imprinter','chest'}) do
      local endpoint=module[role]; validateEndpoint(endpoint,'production '..index..' '..role)
      assert(endpoint.transposer==module.transposer,'Production devices must share one transposer')
      local key=endpointKey(endpoint); assert(not used[key],'Duplicate role endpoint '..key); used[key]=role
    end
  end
  assert(climates.plains==4 and climates.jungle==1 and climates.desert==1
    and climates.winter==1 and climates.hell==1,
    'Climate layout must be 4 plains + jungle + desert + winter + hell')
  validateEndpoint(topology.producerOutput,'producer output')
  assert(modules[topology.producerOutput.transposer],'Producer output is outside bound modules')
  local key=endpointKey(topology.producerOutput)
  assert(not used[key],'Producer output must use a separate inventory: '..key)
  return topology
end

function M:load()
  local source=self.path
  if not self.env.exists(source) then
    if self.env.exists(self.path..'.bak') then source=self.path..'.bak'
    else return nil,'missing' end
  end
  local text=self.env.readText(source)
  if type(text)~='string' then return nil,'cannot read '..source end
  local ok,value=pcall(self.env.unserialize,text)
  if not ok then return nil,'invalid topology; preserve '..source..': '..tostring(value) end
  local valid,reason=pcall(self.validate,self,value)
  if not valid then return nil,'invalid topology; preserve '..source..': '..tostring(reason) end
  if source~=self.path then self:print('WARNING: using topology backup '..source) end
  return value
end

function M:save(topology)
  self:validate(topology)
  local directory=self.path:match('^(.*)/[^/]+$')
  if directory and not self.env.exists(directory) then assert(self.env.mkdir(directory),'Cannot create '..directory) end
  local temporary=self.path..'.new'
  if self.env.exists(temporary) then assert(self.env.remove(temporary),'Cannot remove stale '..temporary) end
  local text=self.env.serialize(topology)
  self.env.writeText(temporary,text)
  assert(self.env.readText(temporary)==text,'Topology write verification failed')
  local parsed=assert(self.env.unserialize(text)); self:validate(parsed)
  if self.env.exists(self.path) then
    local old=assert(self.env.readText(self.path),'Cannot read previous topology')
    self.env.writeText(self.path..'.bak',old)
    assert(self.env.readText(self.path..'.bak')==old,'Topology backup verification failed')
    assert(self.env.remove(self.path),'Cannot replace previous topology')
  end
  assert(self.env.rename(temporary,self.path),'Cannot publish topology')
  return topology
end

local function issue(list,kind,code,message)
  list[#list+1]={kind=kind,code=code,message=message}
end

function M:verify(topology)
  self:validate(topology)
  local _,byAddress=self:componentSnapshot()
  local issues={}
  local checkedInterfaces={}
  for _,module in ipairs(topology.modules) do
    local transposer=byAddress[module.transposer]
    if not transposer or transposer.kind~='transposer' then
      issue(issues,'unavailable','transposer_missing','Transposer unavailable: '..module.transposer)
    else
      local ok,name=pcall(transposer.proxy.getInventoryName,module.interfaceSide)
      if not ok then
        issue(issues,'unavailable','interface_side_unreadable','Cannot read interface side '..module.transposer..':'..module.interfaceSide)
      elseif name==nil then
        issue(issues,'unavailable','interface_side_absent','Interface side is temporarily unavailable at '..module.transposer..':'..module.interfaceSide)
      elseif name~=interfaceName then
        issue(issues,'changed','interface_side_changed','Expected '..interfaceName..' at '..module.transposer..':'..module.interfaceSide..', found '..tostring(name))
      end
      for slot=1,9 do
        local stackOk,stack=pcall(transposer.proxy.getStackInSlot,module.interfaceSide,slot)
        if not stackOk then
          issue(issues,'unavailable','interface_buffer_unreadable','Cannot read interface buffer at '..module.transposer..':'..module.interfaceSide)
          break
        elseif alive(stack) then
          issue(issues,'busy','interface_buffer_busy','Interface buffer is not empty at '..module.transposer..':'..module.interfaceSide)
          break
        end
      end
    end
    local interface=byAddress[module.interface]
    if not interface then
      issue(issues,'unavailable','interface_component_missing','ME interface component unavailable: '..module.interface)
    elseif not checkedInterfaces[module.interface] then
      checkedInterfaces[module.interface]=true
      local methods=interface.methods or {}
      if methods.getInterfaceConfiguration==nil or methods.setInterfaceConfiguration==nil then
        issue(issues,'changed','interface_api_changed','Component is no longer a configurable ME interface: '..module.interface)
      else
        for slot=1,9 do
          local ok,value=pcall(interface.proxy.getInterfaceConfiguration,slot)
          if not ok then
            issue(issues,'unavailable','interface_config_unreadable','Cannot read ME interface configuration: '..module.interface)
            break
          elseif value~=nil then
            issue(issues,'busy','interface_request_busy','ME interface has a configured request: '..module.interface..' slot '..slot)
            break
          end
        end
      end
    end
  end
  local function checkEndpoint(endpoint,role)
    local transposer=byAddress[endpoint.transposer]
    if not transposer or transposer.kind~='transposer' then return end
    local ok,name=pcall(transposer.proxy.getInventoryName,endpoint.side)
    if not ok then
      issue(issues,'unavailable','role_unreadable','Cannot read '..role..' at '..endpointKey(endpoint))
    elseif name==nil then
      issue(issues,'unavailable','role_absent',role..' is temporarily unavailable at '..endpointKey(endpoint))
    elseif name~=endpoint.name then
      issue(issues,'changed','role_changed','Expected '..endpoint.name..' for '..role..' at '..endpointKey(endpoint)..', found '..tostring(name))
    end
  end
  for _,module in ipairs(topology.productionModules) do
    checkEndpoint(module.apiary,'industrial apiary')
    checkEndpoint(module.mutatron,'normal mutatron')
    checkEndpoint(module.imprinter,'imprinter')
    checkEndpoint(module.chest,'module chest')
    local transposer=byAddress[module.transposer]
    if transposer and transposer.kind=='transposer' then
      local ok,profile,signature=pcall(climateOfApiary,transposer.proxy,module.apiary.side)
      if not ok then
        issue(issues,'unavailable','climate_unreadable','Cannot inspect climate at '..endpointKey(module.apiary))
      elseif profile~=module.climate or signature~=module.climateSignature then
        issue(issues,'changed','climate_changed','Apiary upgrades changed at '..endpointKey(module.apiary)
          ..'; expected '..module.climate..', found '..tostring(profile))
      end
    end
  end
  checkEndpoint(topology.producerOutput,'producer output')
  table.sort(issues,function(a,b) return a.kind==b.kind and a.message<b.message or a.kind<b.kind end)
  return issues
end

function M:printIssues(issues)
  if #issues==0 then self:print('TOPOLOGY OK'); return end
  self:print('TOPOLOGY CHECK: '..#issues..' issue(s)')
  for _,row in ipairs(issues) do self:print('  '..row.kind:upper()..' '..row.message) end
end

function M:ensure(interactive)
  local topology,reason=self:load()
  if not topology then
    if reason=='missing' and interactive then
      self:print('No saved topology. Starting first-time binding.')
      topology=self:bind(false)
    elseif interactive then
      self:print(reason)
      self:print('[R] Rebind and archive the damaged file  [Q] Quit')
      local answer=tostring((self.env.readLine or io.read)() or ''):lower()
      if answer=='r' then topology=self:bind(false)
      else error('Stopped without replacing the damaged topology') end
    else error(reason=='missing' and 'No saved topology. Run opencombkeeper bind.' or reason) end
  end
  while true do
    local issues=self:verify(topology)
    self:printIssues(issues)
    if #issues==0 then return topology end
    local busy,structural=false,false
    for _,row in ipairs(issues) do
      if row.kind=='busy' then busy=true else structural=true end
    end
    if busy and not structural then
      error('Topology is busy; clear the reported interface buffers or requests and start again')
    end
    if not interactive then error('Topology check failed; use opencombkeeper rebind if equipment changed') end
    self:print('[C] Check again  [R] Rebind  [Q] Quit')
    local answer=tostring((self.env.readLine or io.read)() or ''):lower()
    if answer=='r' then topology=self:bind(false)
    elseif answer=='q' then error('Stopped without changing topology')
    elseif answer~='c' then self:print('Choose C, R or Q') end
  end
end

function M:display(topology)
  self:print('OpenCombkeeper topology '..topology.schema)
  for index,module in ipairs(topology.modules) do
    self:print(string.format('MODULE %d transposer=%s interface-side=%d interface=%s',index,
      module.transposer,module.interfaceSide,module.interface))
  end
  local function show(role,endpoint)
    self:print(string.format('ROLE %s = %s side %d (%s)',role,endpoint.transposer,endpoint.side,endpoint.name))
  end
  for _,module in ipairs(topology.productionModules) do
    self:print(string.format('PRODUCTION %d climate=%s transposer=%s',module.id,module.climate,module.transposer))
    show('apiary',module.apiary); show('mutatron',module.mutatron)
    show('imprinter',module.imprinter); show('local-chest',module.chest)
  end
  show('producer-output',topology.producerOutput)
end

function M:cleanupBinding()
  local text=self.env.readText(self.pendingPath)
  if not text then return false end
  local address,databaseAddress,slot=text:match('^'..PENDING_SCHEMA..'\n(%S+) (%S+) (%d+)\n$')
  assert(address and databaseAddress,'Invalid binding journal; preserve '..self.pendingPath)
  slot=tonumber(slot)
  local interface=self.env.proxy(address)
  local database=self.env.proxy(databaseAddress)
  local configured=self:call(interface.getInterfaceConfiguration,9)
  if configured~=nil then
    self:call(interface.setInterfaceConfiguration,9)
    assert(self:call(interface.getInterfaceConfiguration,9)==nil,'Request 9 remains configured')
  end
  local value=self:call(database.get,slot)
  assert(not alive(value) or value.name=='minecraft:cobblestone','Reserved database entry changed')
  -- Some OC/AE2 builds discard the descriptor when the request is cleared.
  -- Clearing an already empty database slot returns false there, so skip it.
  if alive(value) then
    self:call(database.clear,slot)
    assert(self:call(database.get,slot)==nil,'Temporary database entry not cleared')
  end
  assert(self.env.remove(self.pendingPath),'Cannot remove binding journal')
  return true
end

function M:waitEmpty(module)
  for attempt=0,BIND_TIMEOUT do
    local empty=true
    for slot=1,9 do if alive(self:call(module.entry.proxy.getStackInSlot,module.side,slot)) then empty=false end end
    if empty then return end
    if attempt<BIND_TIMEOUT then (self.env.sleep or os.sleep)(1) end
  end
  error('Interface did not empty; check ME storage space and run opencombkeeper bind-reset')
end

function M:chooseContainer(role,label,candidates,used)
  local available={}
  for _,endpoint in ipairs(candidates) do if not used[endpointKey(endpoint)] then available[#available+1]=endpoint end end
  assert(#available>0,'No unassigned inventory for '..role)
  self:print(label..':')
  for index,endpoint in ipairs(available) do
    self:print(string.format('  [%d] %s side %d (%s)',index,endpoint.transposer,endpoint.side,endpoint.name))
  end
  local selected
  if self.env.chooseRole then selected=self.env.chooseRole(role,copy(available))
  else
    self:print('Select 1-'..#available..':')
    selected=tonumber((self.env.readLine or io.read)())
  end
  assert(type(selected)=='number' and selected%1==0 and available[selected],
    'Invalid selection for '..role..'; previous topology preserved')
  local endpoint=available[selected]; used[endpointKey(endpoint)]=role
  return endpoint
end

function M:bind(recover)
  if recover then
    local cleaned=self:cleanupBinding()
    local found=self:discover()
    for _,module in ipairs(found.modules) do
      local useful=false
      for _,inventory in ipairs(module.inventories) do
        if inventory.name~=interfaceName and not ignoredMachines[inventory.name] then useful=true end
      end
      if useful and #module.interfaceSides==1 then module.side=module.interfaceSides[1]; self:waitEmpty(module) end
    end
    self:print(cleaned and 'Binding request cleared. No machine inventory was changed.' or 'No pending binding request.')
    return
  end
  assert(not self.env.exists(self.pendingPath),'Unfinished binding. Run opencombkeeper bind-reset first')
  local found=self:discover()
  local modules,probes={},{}
  for _,candidate in ipairs(found.modules) do
    local others,useful={},false
    for _,inventory in ipairs(candidate.inventories) do
      if inventory.name~=interfaceName then
        others[#others+1]=inventory
        if not ignoredMachines[inventory.name] then useful=true end
      end
    end
    if useful then
      assert(#candidate.interfaceSides<=1,'Several interfaces touch transposer '..candidate.entry.address)
    end
    if #candidate.interfaceSides==1 then
      candidate.side=candidate.interfaceSides[1]; candidate.others=others
      candidate.managed=useful; probes[#probes+1]=candidate
      if useful then modules[#modules+1]=candidate end
    end
  end
  assert(#modules>0,'No module with an adjacent ME interface found')
  assert(#modules==9,'Need exactly 9 managed modules (8 production + final output); found '..#modules
    ..'. Run opencombkeeper scan and check OC connections to every transposer')
  assert(#found.interfaces>=#modules,'Need one configurable interface per module: modules='..#modules..', interfaces='..#found.interfaces)
  assert(#found.databases>0,'One OC database is required')
  local interfaces={}
  for _,entry in ipairs(found.interfaces) do
    local empty=true
    for slot=1,9 do if self:call(entry.proxy.getInterfaceConfiguration,slot)~=nil then empty=false end end
    if empty then interfaces[#interfaces+1]=entry else self:print('SKIP existing requests: '..entry.address) end
  end
  assert(#interfaces>=#modules,'Not enough interfaces without existing requests')
  -- Manual advanced mutatron assemblies are not topology modules, but their
  -- interface buffers must still be watched while correlating component UUIDs.
  -- Otherwise a marker delivered there looks like a failed ME request and costs
  -- the full timeout even though delivery succeeded.
  for _,module in ipairs(probes) do
    for slot=1,9 do
      assert(not alive(self:call(module.entry.proxy.getStackInSlot,module.side,slot)),
        'Interface inventory must be empty during binding: '..module.entry.address)
    end
  end
  local database,databaseSlot
  for _,entry in ipairs(found.databases) do
    for slot=1,81 do
      local ok,value=pcall(entry.proxy.get,slot)
      if not ok then break end
      if value==nil then database,databaseSlot=entry,slot; break end
    end
    if database then break end
  end
  assert(database,'No free OC database entry')
  local directory=self.pendingPath:match('^(.*)/[^/]+$')
  if directory and not self.env.exists(directory) then assert(self.env.mkdir(directory),'Cannot create '..directory) end
  self:print('Binding '..#modules..' modules using '..#interfaces..' empty-configuration candidates')
  local mapped,used,bound={},{},{}
  local ok,reason=pcall(function()
    for index,interface in ipairs(interfaces) do
      self.env.writeText(self.pendingPath,PENDING_SCHEMA..'\n'..interface.address..' '..database.address..' '..databaseSlot..'\n')
      -- Refresh for every interface. On this server the descriptor may vanish
      -- when the previous interface request is removed.
      assert(self:call(interface.proxy.store,{name='minecraft:cobblestone'},database.address,databaseSlot,1),
        'No cobblestone available through ME interface '..interface.address)
      local marker=self:call(database.proxy.get,databaseSlot)
      assert(marker and marker.name=='minecraft:cobblestone','Marker descriptor missing after store')
      assert(self:call(interface.proxy.setInterfaceConfiguration,9,database.address,databaseSlot,1),'Interface request rejected')
      local match
      for attempt=0,BIND_TIMEOUT do
        match=nil
        for _,module in ipairs(probes) do
          local present=false
          for slot=1,9 do
            local value=self:call(module.entry.proxy.getStackInSlot,module.side,slot)
            if alive(value) then
              assert(value.name=='minecraft:cobblestone' and value.size==1,'Unexpected item in interface during binding')
              assert(not present,'Multiple marker stacks in an interface'); present=true
            end
          end
          if present then assert(not match,'Marker visible at multiple modules'); match=module end
        end
        if match then break end
        if attempt<BIND_TIMEOUT then (self.env.sleep or os.sleep)(1) end
      end
      self:call(interface.proxy.setInterfaceConfiguration,9)
      assert(self:call(interface.proxy.getInterfaceConfiguration,9)==nil,'Cannot clear marker request')
      if match then
        assert(not mapped[match.entry.address],'Several interfaces map to one transposer')
        mapped[match.entry.address]=true; self:waitEmpty(match)
        if match.managed then
          assert(not used[match.entry.address],'Several interfaces map to one module')
          used[match.entry.address]=true; match.interface=interface.address; bound[#bound+1]=match
          self:print('BOUND '..#bound..'/'..#modules..': '..match.entry.address..' -> '..interface.address)
        else
          self:print('SKIP manual/unmanaged transposer '..match.entry.address..' -> '..interface.address)
        end
      else self:print('SKIP no marker delivered within '..BIND_TIMEOUT..' seconds: '..interface.address) end
      if #bound==#modules then break end
    end
    self:cleanupBinding()
    assert(#bound==#modules,'Incomplete binding: bound='..#bound..', modules='..#modules..'; previous topology preserved')
  end)
  if not ok then
    local cleaned,cleanupReason=pcall(self.cleanupBinding,self)
    if not cleaned then self:print('Cleanup pending: '..tostring(cleanupReason)) end
    error(tostring(reason))
  end
  local topology={schema=SCHEMA,modules={},productionModules={}}
  local outputCandidates={}
  table.sort(bound,function(a,b) return a.entry.address<b.entry.address end)
  for _,module in ipairs(bound) do
    topology.modules[#topology.modules+1]={transposer=module.entry.address,interfaceSide=module.side,interface=module.interface}
    local roles={apiaries={},mutatrons={},imprinters={},containers={}}
    for _,inventory in ipairs(module.others) do
      local endpoint={transposer=module.entry.address,side=inventory.side,name=inventory.name}
      local kind=machineKinds[inventory.name]
      if kind=='apiary' then roles.apiaries[#roles.apiaries+1]=endpoint
      elseif kind=='mutatron' then roles.mutatrons[#roles.mutatrons+1]=endpoint
      elseif kind=='imprinter' then roles.imprinters[#roles.imprinters+1]=endpoint
      elseif not ignoredMachines[inventory.name] then roles.containers[#roles.containers+1]=endpoint end
    end
    local production=#roles.apiaries+#roles.mutatrons+#roles.imprinters>0
    if production then
      assert(#roles.apiaries==1 and #roles.mutatrons==1 and #roles.imprinters==1 and #roles.containers==1,
        'Incomplete production module '..module.entry.address
          ..': need exactly one apiary, mutatron, imprinter and chest')
      local climate,signature=climateOfApiary(module.entry.proxy,roles.apiaries[1].side)
      topology.productionModules[#topology.productionModules+1]={
        id=#topology.productionModules+1,transposer=module.entry.address,climate=climate,
        climateSignature=signature,apiary=roles.apiaries[1],mutatron=roles.mutatrons[1],
        imprinter=roles.imprinters[1],chest=roles.containers[1]}
    else
      for _,endpoint in ipairs(roles.containers) do outputCandidates[#outputCandidates+1]=endpoint end
    end
  end
  assert(#topology.productionModules==8,'Need exactly 8 complete production modules; found '..#topology.productionModules)
  assert(#outputCandidates>0,'No standalone final-producer chest found')
  topology.producerOutput=self:chooseContainer('producerOutput','Final producer output',outputCandidates,{})
  self:save(topology)
  self:print('Saved '..#bound..' bindings: 8 production modules and 1 output chest.')
  self:print('No bees moved; only apiary upgrade slots were read.')
  self:display(topology)
  return topology
end

return M
