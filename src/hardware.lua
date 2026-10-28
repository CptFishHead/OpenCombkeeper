-- OpenComputers transport adapter for the bound OpenCombkeeper topology.
-- Every physical operation is journaled before the first item can move.
local function new(environment)
  local component=assert(environment.component)
  local fs=assert(environment.filesystem)
  local serialization=assert(environment.serialization)
  local computer=assert(environment.computer)
  local sleep=environment.sleep or os.sleep
  local output=environment.print or print
  local M={}

  local DATA='/home/.opencombkeeper-data'
  local STATE=DATA..'/executor-state'
  local JOURNAL=DATA..'/hardware-operation'
  local REQUEST_SLOT=9
  local DELIVERY_TIMEOUT=20
  local PROCESS_TIMEOUT=7200

  local function alive(value)
    return type(value)=='table' and (tonumber(value.size) or 0)>0
      and value.name~='minecraft:air' and value.name~='air'
  end

  local function bee(value)
    if not alive(value) then return nil end
    local name=tostring(value.name or '')
    local kind
    if name:find('bee_princess',1,true) then kind='princess'
    elseif name:find('bee_drone',1,true) then kind='drone'
    elseif name:find('bee_queen',1,true) then kind='queen' end
    local individual=type(value.individual)=='table' and value.individual or {}
    return individual.ident,kind
  end

  local function call(method,...)
    assert(method~=nil,'Component method unavailable')
    local ok,value,reason=pcall(method,...)
    assert(ok,tostring(value))
    assert(value~=false,tostring(reason or 'Component operation rejected'))
    return value,reason
  end

  local function defaultReadText(path)
    local file=io.open(path,'r'); if not file then return nil end
    local text=file:read('*a'); file:close(); return text
  end

  local function defaultWriteText(path,text)
    local file=assert(io.open(path,'w')); assert(file:write(text)); assert(file:flush())
    local closed,reason=file:close(); assert(closed~=false,reason or 'Cannot close '..path)
  end
  local readText=environment.readText or defaultReadText
  local writeText=environment.writeText or defaultWriteText

  local function ensureData()
    if not fs.exists(DATA) then assert(fs.makeDirectory(DATA),'Cannot create '..DATA) end
  end

  local function atomic(path,value)
    ensureData()
    local text=serialization.serialize(value)
    local temporary=path..'.new'; local backup=path..'.bak'
    if fs.exists(temporary) then assert(fs.remove(temporary),'Cannot remove '..temporary) end
    writeText(temporary,text); assert(readText(temporary)==text,'Write verification failed: '..temporary)
    if fs.exists(path) then
      local old=assert(readText(path),'Cannot read '..path)
      writeText(backup,old); assert(readText(backup)==old,'Backup verification failed: '..backup)
      assert(fs.remove(path),'Cannot replace '..path)
    end
    assert(fs.rename(temporary,path),'Cannot publish '..path)
  end

  local function parse(path)
    local text=readText(path); if not text then return nil end
    local ok,value=pcall(serialization.unserialize,text)
    assert(ok and type(value)=='table','Invalid saved file; preserve '..path)
    return value
  end

  local function inventory(proxy,side,slot)
    return call(proxy.getStackInSlot,side,slot)
  end

  local function emptyBuffer(module)
    for slot=1,9 do if alive(inventory(module.t,module.source,slot)) then return false end end
    return true
  end

  local function waitBufferEmpty(module)
    for attempt=0,DELIVERY_TIMEOUT do
      if emptyBuffer(module) then return true end
      if attempt<DELIVERY_TIMEOUT then sleep(1) end
    end
    error('ME interface buffer did not empty at '..module.address)
  end

  local function resolveModule(row)
    local module={address=row.transposer,source=row.interfaceSide,interfaceAddress=row.interface}
    module.t=call(component.proxy,row.transposer)
    module.interface=call(component.proxy,row.interface)
    assert(call(module.t.getInventoryName,module.source)=='appliedenergistics2:interface',
      'Bound ME interface side changed: '..row.transposer)
    return module
  end

  local function findDatabase()
    local candidates={}
    for address,kind in component.list() do
      local okMethods,methods=pcall(component.methods,address)
      if okMethods and type(methods)=='table'
          and (kind=='database' or methods.get~=nil and methods.clear~=nil and methods.indexOf~=nil) then
        candidates[#candidates+1]={address=address,proxy=call(component.proxy,address)}
      end
    end
    table.sort(candidates,function(a,b) return a.address<b.address end)
    assert(#candidates>0,'One OC database is required for exact ME requests')
    return candidates
  end

  local function freeDatabaseSlot()
    for _,database in ipairs(M.databases) do
      for slot=1,81 do
        local ok,value=pcall(database.proxy.get,slot)
        if not ok then break end
        if value==nil then return database,slot end
      end
    end
    error('No free OC database entry')
  end

  local function saveJournal()
    assert(M.operation,'No hardware operation to journal')
    atomic(JOURNAL,M.operation)
  end

  local function phase(name,details)
    M.operation.phase=name
    if details then for key,value in pairs(details) do M.operation[key]=value end end
    saveJournal()
  end

  local function begin(action)
    assert(not fs.exists(JOURNAL),'Unfinished hardware operation. Inspect machines, empty owned slots, then run opencombkeeper hardware-reset')
    M.operation={schema=1,action=action,phase='starting',started=computer.uptime()}
    saveJournal()
  end

  local function clearRequest(module,database,slot)
    if call(module.interface.getInterfaceConfiguration,REQUEST_SLOT)~=nil then
      call(module.interface.setInterfaceConfiguration,REQUEST_SLOT)
      assert(call(module.interface.getInterfaceConfiguration,REQUEST_SLOT)==nil,
        'ME request remains configured at '..module.interfaceAddress)
    end
    if database and slot then
      local value=call(database.proxy.get,slot)
      if value~=nil then
        call(database.proxy.clear,slot)
        assert(call(database.proxy.get,slot)==nil,'Temporary database descriptor remains')
      end
    end
  end

  local function readME()
    local items,reason=call(M.network.getItemsInNetwork)
    assert(type(items)=='table',reason or 'Cannot read ME network')
    return items
  end

  local function findBee(species,kind)
    local best
    for _,value in pairs(readME()) do
      local uid,physicalKind=bee(value)
      if uid==species and physicalKind==kind and alive(value) then
        if not best or value.size>best.size then best=value end
      end
    end
    return best
  end

  local function countBee(species,kind)
    local count=0
    for _,value in pairs(readME()) do
      local uid,physicalKind=bee(value)
      if uid==species and physicalKind==kind then count=count+(tonumber(value.size) or 0) end
    end
    return count
  end

  local function assertMachineSlotEmpty(module,endpoint,slot,label)
    assert(not alive(inventory(module.t,endpoint.side,slot)),label..' slot '..slot..' is occupied')
  end

  local function requestBee(module,species,kind,endpoint,destinationSlot)
    assert(emptyBuffer(module),'ME interface buffer is occupied at '..module.address)
    assert(call(module.interface.getInterfaceConfiguration,REQUEST_SLOT)==nil,
      'ME request slot '..REQUEST_SLOT..' is already configured at '..module.interfaceAddress)
    if destinationSlot then assertMachineSlotEmpty(module,endpoint,destinationSlot,endpoint.name) end
    local chosen=findBee(species,kind)
    assert(chosen,'ME needs '..species..' / '..kind)
    local database,slot=freeDatabaseSlot()
    phase('requesting',{species=species,kind=kind,interface=module.interfaceAddress,
      database=database.address,databaseSlot=slot,destination=endpoint.name,destinationSlot=destinationSlot})
    local filter={name=chosen.name,label=chosen.label,size=chosen.size}
    assert(call(module.interface.store,filter,database.address,slot,1),'Cannot store ME bee descriptor')
    local descriptor=call(database.proxy.get,slot)
    local descriptorSpecies,descriptorKind=bee(descriptor)
    assert(descriptorSpecies==species and descriptorKind==kind,'ME selected a different bee variant')
    call(module.interface.setInterfaceConfiguration,REQUEST_SLOT,database.address,slot,1)
    local sourceSlot
    for attempt=0,DELIVERY_TIMEOUT do
      for candidate=1,9 do
        local value=inventory(module.t,module.source,candidate)
        if alive(value) then
          local uid,physicalKind=bee(value)
          assert(not sourceSlot and uid==species and physicalKind==kind,
            'Unexpected item in ME interface staging buffer')
          sourceSlot=candidate
        end
      end
      if sourceSlot then break end
      if attempt<DELIVERY_TIMEOUT then sleep(1) end
    end
    if not sourceSlot then
      clearRequest(module,database,slot)
      error('ME did not deliver '..species..' / '..kind..' within '..DELIVERY_TIMEOUT..' seconds')
    end
    phase('transferring',{sourceSlot=sourceSlot})
    local moved
    if destinationSlot then
      moved=call(module.t.transferItem,module.source,endpoint.side,1,sourceSlot,destinationSlot)
    else
      moved=call(module.t.transferItem,module.source,endpoint.side,1,sourceSlot)
    end
    assert(moved==1,'Bee transfer was rejected by '..endpoint.name)
    clearRequest(module,database,slot)
    waitBufferEmpty(module)
    phase('loaded')
    return true
  end

  local function returnSlot(module,endpoint,slot,count)
    local value=inventory(module.t,endpoint.side,slot)
    if not alive(value) then return 0 end
    assert(emptyBuffer(module),'Cannot return output while ME interface buffer is occupied')
    local wanted=math.min(tonumber(value.size) or 1,count or tonumber(value.size) or 1)
    local moved=call(module.t.transferItem,endpoint.side,module.source,wanted,slot)
    assert(type(moved)=='number' and moved>0,'ME interface rejected output from '..endpoint.name..' slot '..slot)
    waitBufferEmpty(module)
    return moved,value
  end

  local function fluidPresent(module,endpoint)
    if module.t.getFluidInTank==nil then return true end
    local ok,value=pcall(module.t.getFluidInTank,endpoint.side)
    if not ok or type(value)~='table' then return true end
    local amount=tonumber(value.amount)
    for _,tank in pairs(value) do
      if type(tank)=='table' and tonumber(tank.amount) then amount=(amount or 0)+tank.amount end
    end
    return amount==nil or amount>0
  end

  local function ensureLabware(module,endpoint,slot)
    local present=inventory(module.t,endpoint.side,slot)
    if alive(present) then
      assert(present.label=='Genetics Labware',endpoint.name..' slot '..slot..' must contain Genetics Labware')
      return true
    end
    for chestSlot=1,call(module.t.getInventorySize,module.chest.side) do
      local value=inventory(module.t,module.chest.side,chestSlot)
      if alive(value) and value.label=='Genetics Labware' then
        local moved=call(module.t.transferItem,module.chest.side,endpoint.side,value.size,chestSlot,slot)
        assert(type(moved)=='number' and moved>0,'Cannot load Genetics Labware from module chest')
        return true
      end
    end
    error('Put Genetics Labware in the local chest of module '..module.address)
  end

  local function ensureTemplate(module)
    local template=inventory(module.t,module.imprinter.side,1)
    if alive(template) then
      assert(template.name=='gendustry:gene_template','Imprinter slot 1 must contain a Gene Template')
      return true
    end
    for chestSlot=1,call(module.t.getInventorySize,module.chest.side) do
      local value=inventory(module.t,module.chest.side,chestSlot)
      if alive(value) and value.name=='gendustry:gene_template' then
        local moved=call(module.t.transferItem,module.chest.side,module.imprinter.side,1,chestSlot,1)
        assert(moved==1,'Cannot load Gene Template from module chest')
        return true
      end
    end
    error('Put the standard Gene Template in the imprinter or local chest of module '..module.address)
  end

  local function imprintBee(module,species,kind)
    assertMachineSlotEmpty(module,module.imprinter,3,'Imprinter input')
    assertMachineSlotEmpty(module,module.imprinter,4,'Imprinter output')
    ensureTemplate(module); ensureLabware(module,module.imprinter,2)
    requestBee(module,species,kind,module.imprinter,3)
    phase('processing',{processor='imprinter',module=module.address,species=species,kind=kind})
    for elapsed=0,PROCESS_TIMEOUT do
      local result=inventory(module.t,module.imprinter.side,4)
      if alive(result) then
        local waste=result.name=='gendustry:waste'
        local uid,physicalKind=bee(result)
        returnSlot(module,module.imprinter,4,1)
        if waste then return false end
        assert(uid==species and physicalKind==kind,
          'Imprinter template changed bee identity: expected '..species..'/'..kind
            ..', found '..tostring(uid)..'/'..tostring(physicalKind))
        return true
      end
      if elapsed==PROCESS_TIMEOUT then error('Imprinter did not finish within '..PROCESS_TIMEOUT..' seconds') end
      if elapsed>0 and elapsed%30==0 then output('WAIT imprinter '..module.address..' / '..species..' '..kind) end
      sleep(1)
    end
  end

  local function waitMutatron(module,expected)
    local endpoint=module.mutatron
    for elapsed=0,PROCESS_TIMEOUT do
      local result=inventory(module.t,endpoint.side,3)
      if alive(result) then
        if result.name=='gendustry:waste' then
          returnSlot(module,endpoint,3,1)
          return {kind='genetic_waste'}
        end
        local uid,kind=bee(result)
        assert(kind=='queen' and type(uid)=='string','Mutatron output is not an identifiable queen')
        returnSlot(module,endpoint,3,1)
        return {kind='queen',species=uid,expected=expected}
      end
      if elapsed==PROCESS_TIMEOUT then error('Mutatron did not finish within '..PROCESS_TIMEOUT..' seconds') end
      if elapsed>0 and elapsed%30==0 then output('WAIT mutatron '..module.address..' / '..expected) end
      sleep(1)
    end
  end

  local function mutate(action)
    local module=M.production[action.profile] and M.production[action.profile][action.moduleSlot]
    assert(module,'No production module '..tostring(action.profile)..'/'..tostring(action.moduleSlot))
    for _,slot in ipairs({1,2,3}) do assertMachineSlotEmpty(module,module.mutatron,slot,'Mutatron') end
    assert(fluidPresent(module,module.mutatron),'Mutatron needs mutagen at module '..module.address)
    assert(findBee(assert(action.carrier),'princess'),'ME needs '..action.carrier..' / princess')
    assert(findBee(assert(action.drone),'drone'),'ME needs '..action.drone..' / drone')
    local droneReady=false
    for attempt=1,16 do
      if imprintBee(module,action.drone,'drone') then droneReady=true; break end
      output('IMPRINTER WASTE drone '..action.drone..' attempt '..attempt..'/16')
    end
    assert(droneReady,'Imprinter discarded 16 '..action.drone..' drones; mutation was not started')
    if not imprintBee(module,action.carrier,'princess') then
      return {kind='genetic_waste'}
    end
    ensureLabware(module,module.mutatron,4)
    requestBee(module,action.drone,'drone',module.mutatron,2)
    requestBee(module,action.carrier,'princess',module.mutatron,1)
    phase('processing',{processor='mutatron',module=module.address})
    return waitMutatron(module,action.result)
  end

  local function incubate(action)
    local module=M.production[action.profile] and M.production[action.profile][action.moduleSlot]
    assert(module,'No production module '..tostring(action.profile)..'/'..tostring(action.moduleSlot))
    for _,slot in ipairs({1,2}) do assertMachineSlotEmpty(module,module.apiary,slot,'Industrial apiary') end
    for slot=7,15 do assertMachineSlotEmpty(module,module.apiary,slot,'Industrial apiary output') end
    requestBee(module,action.species,'queen',module.apiary,1)
    phase('processing',{processor='apiary',module=module.address})
    local princess=false
    for elapsed=0,PROCESS_TIMEOUT do
      for slot=7,15 do
        local value=inventory(module.t,module.apiary.side,slot)
        if alive(value) then
          local uid,kind=bee(value)
          if kind=='princess' then
            assert(uid==action.species,'Apiary returned a different princess: '..tostring(uid))
            princess=true
          end
          returnSlot(module,module.apiary,slot)
        end
      end
      local queen=inventory(module.t,module.apiary.side,1)
      if princess and not alive(queen) then
        for slot=7,15 do
          assert(not alive(inventory(module.t,module.apiary.side,slot)),'Apiary output remains occupied')
        end
        return {accepted=true}
      end
      if elapsed==PROCESS_TIMEOUT then error('Industrial apiary did not finish within '..PROCESS_TIMEOUT..' seconds') end
      if elapsed>0 and elapsed%30==0 then output('WAIT apiary '..module.address..' / '..action.species) end
      sleep(1)
    end
  end

  local function deliverProducer(action)
    local module=M.output
    assert(emptyBuffer(module),'Final-output ME interface buffer is occupied')
    requestBee(module,action.species,'queen',module.chest,nil)
    local found=false
    for slot=1,call(module.t.getInventorySize,module.chest.side) do
      local uid,kind=bee(inventory(module.t,module.chest.side,slot))
      if uid==action.species and kind=='queen' then found=true; break end
    end
    assert(found,'Final queen was not found in producer output chest')
    return {accepted=true}
  end

  local function storeDroneSource(action)
    assert(countBee(action.species,'drone')>0,'No '..action.species..' drones returned to ME')
    assert(countBee(action.species,'princess')>0,'No '..action.species..' princess returned to ME')
    return {accepted=true}
  end

  function M.configure(topology)
    assert(type(topology)=='table' and topology.schema=='OCTOPOLOGY2','Bound topology required')
    M.topology=topology; M.production={}
    local byAddress={}
    for _,row in ipairs(topology.modules) do byAddress[row.transposer]=resolveModule(row) end
    for _,row in ipairs(topology.productionModules) do
      local module=assert(byAddress[row.transposer]); module.apiary=row.apiary
      module.mutatron=row.mutatron; module.imprinter=row.imprinter; module.chest=row.chest
      M.production[row.climate]=M.production[row.climate] or {}
      M.production[row.climate][#M.production[row.climate]+1]=module
    end
    for _,list in pairs(M.production) do table.sort(list,function(a,b) return a.address<b.address end) end
    local outputRow
    for _,row in ipairs(topology.modules) do
      if row.transposer==topology.producerOutput.transposer then outputRow=row; break end
    end
    M.output=assert(byAddress[assert(outputRow).transposer]); M.output.chest=topology.producerOutput
    M.network=assert(M.production.plains and M.production.plains[1]).interface
    assert(M.network.getItemsInNetwork~=nil,'Bound ME interface cannot list network items')
    M.databases=findDatabase()
  end

  function M.load()
    assert(M.topology,'hardware.configure must run first')
    local pending=parse(JOURNAL)
    if pending then
      if pending.phase=='completed' then
        error('Completed hardware operation awaits commit. Run opencombkeeper hardware-recover')
      end
      error('Unfinished hardware operation ('..tostring(pending.phase)
        ..'). Inspect machines, empty owned slots, then run opencombkeeper hardware-reset')
    end
    local state=parse(STATE)
    if state then assert(state.schema==1,'Unsupported executor state') end
    return state
  end

  function M.loadPendingState()
    local pending=parse(JOURNAL)
    assert(pending and pending.phase=='completed','No completed hardware operation to recover')
    local state=parse(STATE)
    if state then assert(state.schema==1,'Unsupported executor state') end
    return state
  end

  function M.save(state)
    assert(type(state)=='table' and state.schema==1,'Invalid executor state')
    atomic(STATE,state)
    if M.operation then
      assert(M.operation.phase=='completed','Refusing to clear an incomplete hardware journal')
      assert(fs.remove(JOURNAL),'Cannot clear completed hardware journal')
      M.operation=nil
    end
  end

  function M.countQueens(species) return countBee(species,'queen') end
  function M.countDrones(species) return countBee(species,'drone') end
  function M.manualCapacity() return 4 end

  function M.perform(action)
    assert(type(action)=='table' and type(action.type)=='string','Hardware action required')
    begin(action)
    local ok,result=pcall(function()
      if action.type=='mutation' then return mutate(action)
      elseif action.type=='incubate' then return incubate(action)
      elseif action.type=='deliver_producer' then return deliverProducer(action)
      elseif action.type=='store_drone_source' then return storeDroneSource(action) end
      error('Unsupported hardware action: '..action.type)
    end)
    if not ok then
      phase('blocked',{failure=tostring(result)})
      error(tostring(result))
    end
    phase('completed',{result=result})
    return result
  end

  function M.recoverCompleted(engine)
    local pending=parse(JOURNAL)
    assert(pending and pending.phase=='completed' and type(pending.action)=='table'
      and type(pending.result)=='table','No completed hardware operation to recover')
    local action=pending.action
    local expectedKind=action.type=='mutation' and (pending.result.kind=='genetic_waste' and 'line_lost'
        or pending.result.species==action.result and 'mutation_done' or 'wrong_species')
      or action.type=='incubate' and 'incubation_done'
      or (action.type=='deliver_producer' or action.type=='store_drone_source') and 'line_delivered'
    local recorded=false
    for _,row in ipairs(engine.state.history or {}) do
      if row.kind==expectedKind and type(row.data)=='table' and row.data.line==action.line then
        recorded=true; break
      end
    end
    M.operation=pending
    if recorded then M.save(engine.state)
    else engine:complete(action,pending.result) end
    output((recorded and 'Cleared already committed ' or 'Recovered completed ')
      ..tostring(action.type)..' operation into executor state.')
    return true
  end

  function M.check(plan)
    assert(M.topology,'hardware.configure must run first')
    local free=false
    for _,database in ipairs(M.databases) do
      for slot=1,81 do
        local ok,value=pcall(database.proxy.get,slot)
        if not ok then break end
        if value==nil then free=true; break end
      end
      if free then break end
    end
    assert(free,'No free OC database entry')
    for profile,list in pairs(M.production) do
      for slot,module in ipairs(list) do
        assert(emptyBuffer(module),'ME interface buffer is occupied at '..module.address)
        assert(call(module.interface.getInterfaceConfiguration,REQUEST_SLOT)==nil,
          'ME request slot is occupied at '..module.interfaceAddress)
        for _,machineSlot in ipairs({1,2,3}) do
          assertMachineSlotEmpty(module,module.mutatron,machineSlot,'Mutatron preflight')
        end
        for _,machineSlot in ipairs({3,4}) do
          assertMachineSlotEmpty(module,module.imprinter,machineSlot,'Imprinter preflight')
        end
        for _,machineSlot in ipairs({1,2}) do
          assertMachineSlotEmpty(module,module.apiary,machineSlot,'Apiary preflight')
        end
        for machineSlot=7,15 do
          assertMachineSlotEmpty(module,module.apiary,machineSlot,'Apiary output preflight')
        end
        local label=profile..'/'..slot..' ('..module.address..')'
        assert(fluidPresent(module,module.mutatron),'Mutatron needs mutagen at module '..label)
        local template=inventory(module.t,module.imprinter.side,1)
        for chestSlot=1,call(module.t.getInventorySize,module.chest.side) do
          local value=inventory(module.t,module.chest.side,chestSlot)
          if alive(value) and value.name=='gendustry:gene_template' then template=template or value end
        end
        assert(alive(template) and template.name=='gendustry:gene_template',
          'Module '..label..' needs the standard Gene Template')
      end
    end
    assert(emptyBuffer(M.output),'Final-output ME interface buffer is occupied')
    assert(call(M.output.interface.getInterfaceConfiguration,REQUEST_SLOT)==nil,
      'Final-output ME request slot is occupied')
    local freeOutput=false
    for slot=1,call(M.output.t.getInventorySize,M.output.chest.side) do
      if not alive(inventory(M.output.t,M.output.chest.side,slot)) then freeOutput=true; break end
    end
    assert(freeOutput,'Final producer output chest is full')
    local princesses={}
    local drones={}
    for _,value in pairs(readME()) do
      local uid,kind=bee(value)
      if uid and kind=='princess' then princesses[uid]=(princesses[uid] or 0)+(tonumber(value.size) or 0) end
      if uid and kind=='drone' then drones[uid]=(drones[uid] or 0)+(tonumber(value.size) or 0) end
    end
    local princessShortages={}
    for uid,count in pairs(plan and plan.startingPrincesses or {}) do
      if (princesses[uid] or 0)<count then
        princessShortages[#princessShortages+1]=uid..': need '..count..', found '..(princesses[uid] or 0)
      end
    end
    local droneShortages={}
    for uid,count in pairs(plan and plan.startingDrones or {}) do
      if (drones[uid] or 0)<count then
        droneShortages[#droneShortages+1]=uid..': need '..count..', found '..(drones[uid] or 0)
      end
    end
    table.sort(princessShortages); table.sort(droneShortages)
    local sections={}
    if #princessShortages>0 then sections[#sections+1]='Missing starting princesses:\n  '
      ..table.concat(princessShortages,'\n  ') end
    if #droneShortages>0 then sections[#sections+1]='Missing starting drones:\n  '
      ..table.concat(droneShortages,'\n  ') end
    assert(#sections==0,table.concat(sections,'\n'))
    output('HARDWARE OK: production modules, output chest, ME network, OC database and starting bees')
    return true
  end

  function M.resetEmpty()
    assert(M.topology,'hardware.configure must run first')
    local pending=parse(JOURNAL)
    assert(not pending or pending.phase~='completed',
      'Completed operation must be committed with opencombkeeper hardware-recover, not reset')
    local modules={M.output}
    for _,list in pairs(M.production) do for _,module in ipairs(list) do modules[#modules+1]=module end end
    for _,module in ipairs(modules) do
      if call(module.interface.getInterfaceConfiguration,REQUEST_SLOT)~=nil then
        call(module.interface.setInterfaceConfiguration,REQUEST_SLOT)
      end
      assert(emptyBuffer(module),'Cannot reset: interface buffer is occupied at '..module.address)
      if module.mutatron then
        for _,slot in ipairs({1,2,3}) do assertMachineSlotEmpty(module,module.mutatron,slot,'Cannot reset mutatron') end
      end
      if module.imprinter then
        for _,slot in ipairs({3,4}) do assertMachineSlotEmpty(module,module.imprinter,slot,'Cannot reset imprinter') end
      end
      if module.apiary then
        for _,slot in ipairs({1,2}) do assertMachineSlotEmpty(module,module.apiary,slot,'Cannot reset apiary') end
        for slot=7,15 do assertMachineSlotEmpty(module,module.apiary,slot,'Cannot reset apiary output') end
      end
    end
    if pending and pending.database and pending.databaseSlot then
      local proxy=call(component.proxy,pending.database)
      if call(proxy.get,pending.databaseSlot)~=nil then call(proxy.clear,pending.databaseSlot) end
    end
    if fs.exists(JOURNAL) then assert(fs.remove(JOURNAL),'Cannot clear hardware journal') end
    M.operation=nil; output('Hardware journal cleared after verifying empty owned slots.')
    return true
  end

  return M
end

local injected=rawget(_G,'OPENCOMBKEEPER_HARDWARE_ENV')
local instance=new(injected or {component=require('component'),filesystem=require('filesystem'),
  serialization=require('serialization'),computer=require('computer'),sleep=os.sleep,print=print})
instance._newForTest=new
return instance
