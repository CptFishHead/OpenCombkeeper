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

  local function copy(value,seen)
    if type(value)~='table' then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local result={}; seen[value]=result
    for key,row in pairs(value) do result[copy(key,seen)]=copy(row,seen) end
    return result
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
    local args={...}
    for attempt=1,201 do
      local ok,value,reason=pcall(method,table.unpack(args))
      assert(ok,tostring(value))
      if value~=false or tostring(reason)~='cooldown' then
        assert(value~=false,tostring(reason or 'Component operation rejected'))
        return value,reason
      end
      if attempt==201 then error('Component cooldown did not clear within 20 seconds') end
      sleep(0.1)
    end
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
    M.databaseReserved=M.databaseReserved or {}
    for _,database in ipairs(M.databases) do
      for slot=1,81 do
        local ok,value=pcall(database.proxy.get,slot)
        if not ok then break end
        local key=database.address..':'..slot
        if value==nil and not M.databaseReserved[key] then
          M.databaseReserved[key]=true; return database,slot
        end
      end
    end
    error('No free OC database entry')
  end

  local function operationKey(action)
    if action.profile and action.moduleSlot then return action.profile..'-'..tostring(action.moduleSlot) end
    return 'output'
  end

  local function journalPath(action) return JOURNAL..'-'..operationKey(action) end

  local function saveJournal(operation)
    assert(operation and operation.path,'No hardware operation to journal')
    atomic(operation.path,operation)
  end

  local function phase(operation,name,details)
    operation.phase=name
    if details then for key,value in pairs(details) do operation[key]=value end end
    saveJournal(operation)
  end

  local function begin(action)
    local path=journalPath(action)
    assert(not fs.exists(path),'Unfinished hardware operation for '..operationKey(action))
    local operation={schema=2,action=action,phase='starting',started=computer.uptime(),path=path}
    saveJournal(operation)
    return operation
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
      if M.databaseReserved then M.databaseReserved[database.address..':'..slot]=nil end
    end
  end

  local function readME()
    local now=computer.uptime()
    if M.meSnapshot and M.meSnapshotAt and now-M.meSnapshotAt<20 then return M.meSnapshot end
    local items,reason=call(M.network.getItemsInNetwork)
    assert(type(items)=='table',reason or 'Cannot read ME network')
    M.meSnapshot=copy(items); M.meSnapshotAt=computer.uptime(); return M.meSnapshot
  end

  local function adjustSnapshot(value,delta)
    if not M.meSnapshot or not alive(value) then return end
    local uid,kind=bee(value); local found
    for _,row in pairs(M.meSnapshot) do
      local rowUid,rowKind=bee(row)
      if rowUid==uid and rowKind==kind and row.name==value.name then
        row.size=math.max(0,(tonumber(row.size) or 0)+delta); found=true; break
      end
    end
    if not found and delta>0 then
      local row=copy(value); row.size=delta; M.meSnapshot[#M.meSnapshot+1]=row
    end
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

  local function requestBee(operation,module,species,kind,endpoint,destinationSlot)
    assert(emptyBuffer(module),'ME interface buffer is occupied at '..module.address)
    assert(call(module.interface.getInterfaceConfiguration,REQUEST_SLOT)==nil,
      'ME request slot '..REQUEST_SLOT..' is already configured at '..module.interfaceAddress)
    if destinationSlot then assertMachineSlotEmpty(module,endpoint,destinationSlot,endpoint.name) end
    local chosen=findBee(species,kind)
    assert(chosen,'ME needs '..species..' / '..kind)
    local database,slot=freeDatabaseSlot()
    phase(operation,'requesting',{species=species,kind=kind,interface=module.interfaceAddress,
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
    phase(operation,'transferring',{sourceSlot=sourceSlot})
    local moved
    if destinationSlot then
      moved=call(module.t.transferItem,module.source,endpoint.side,1,sourceSlot,destinationSlot)
    else
      moved=call(module.t.transferItem,module.source,endpoint.side,1,sourceSlot)
    end
    assert(moved==1,'Bee transfer was rejected by '..endpoint.name)
    clearRequest(module,database,slot)
    waitBufferEmpty(module)
    adjustSnapshot(chosen,-1)
    phase(operation,'loaded')
    return true
  end

  local function returnSlot(module,endpoint,slot,count)
    local value=inventory(module.t,endpoint.side,slot)
    if not alive(value) then return 0 end
    local snapshotValue=copy(value)
    assert(emptyBuffer(module),'Cannot return output while ME interface buffer is occupied')
    local wanted=math.min(tonumber(value.size) or 1,count or tonumber(value.size) or 1)
    local moved=call(module.t.transferItem,endpoint.side,module.source,wanted,slot)
    assert(type(moved)=='number' and moved>0,'ME interface rejected output from '..endpoint.name..' slot '..slot)
    waitBufferEmpty(module)
    adjustSnapshot(snapshotValue,moved)
    return moved,value
  end

  local function localBee(module,species,kind)
    for slot=1,call(module.t.getInventorySize,module.chest.side) do
      local uid,physicalKind=bee(inventory(module.t,module.chest.side,slot))
      if uid==species and physicalKind==kind then return slot end
    end
  end

  local function localBeeAnywhere(species,kind,preferred)
    if preferred then
      local slot=localBee(preferred,species,kind)
      if slot then return preferred,slot end
    end
    for _,list in pairs(M.production) do
      for _,module in ipairs(list) do
        if module~=preferred then
          local slot=localBee(module,species,kind)
          if slot then return module,slot end
        end
      end
    end
  end

  local function ownedFinalQueen(module,species)
    local exact=localBee(module,species,'queen')
    if exact then return exact end
    local candidates={}
    for slot=1,call(module.t.getInventorySize,module.chest.side) do
      local uid,kind=bee(inventory(module.t,module.chest.side,slot))
      if kind=='queen' then candidates[#candidates+1]={slot=slot,uid=uid} end
    end
    if #candidates==1 then
      output('WARN queen UID unavailable/mismatched in owned module chest; using its only queen for '..species)
      return candidates[1].slot
    end
    if #candidates>1 then
      local found={}; for _,row in ipairs(candidates) do found[#found+1]=tostring(row.uid or '?')..'@'..row.slot end
      error('Several queens in owned module chest; cannot choose '..species..': '..table.concat(found,', '))
    end
  end

  local function storeSlot(module,endpoint,slot,count)
    local value=inventory(module.t,endpoint.side,slot)
    if not alive(value) then return 0 end
    local wanted=math.min(tonumber(value.size) or 1,count or tonumber(value.size) or 1)
    local moved=call(module.t.transferItem,endpoint.side,module.chest.side,wanted,slot)
    assert(type(moved)=='number' and moved>0,'Local chest rejected output from '..endpoint.name)
    return moved,value
  end

  local function loadBee(operation,module,species,kind,endpoint,destinationSlot)
    local slot=localBee(module,species,kind)
    if slot then
      local moved=call(module.t.transferItem,module.chest.side,endpoint.side,1,slot,destinationSlot)
      assert(moved==1,'Cannot load local '..species..' / '..kind)
      return true
    end
    return requestBee(operation,module,species,kind,endpoint,destinationSlot)
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

  local function imprintBee(operation,module,species,kind)
    assertMachineSlotEmpty(module,module.imprinter,3,'Imprinter input')
    assertMachineSlotEmpty(module,module.imprinter,4,'Imprinter output')
    ensureTemplate(module)
    loadBee(operation,module,species,kind,module.imprinter,3)
    phase(operation,'processing',{processor='imprinter',module=module.address,species=species,kind=kind})
    for elapsed=0,PROCESS_TIMEOUT do
      local result=inventory(module.t,module.imprinter.side,4)
      if alive(result) then
        local waste=result.name=='gendustry:waste'
        local uid,physicalKind=bee(result)
        if waste then returnSlot(module,module.imprinter,4,1) else storeSlot(module,module.imprinter,4,1) end
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
        storeSlot(module,endpoint,3,1)
        return {kind='queen',species=uid,expected=expected}
      end
      if elapsed==PROCESS_TIMEOUT then error('Mutatron did not finish within '..PROCESS_TIMEOUT..' seconds') end
      if elapsed>0 and elapsed%30==0 then output('WAIT mutatron '..module.address..' / '..expected) end
      sleep(1)
    end
  end

  local function mutate(operation,action)
    local module=M.production[action.profile] and M.production[action.profile][action.moduleSlot]
    assert(module,'No production module '..tostring(action.profile)..'/'..tostring(action.moduleSlot))
    for _,slot in ipairs({1,2,3}) do assertMachineSlotEmpty(module,module.mutatron,slot,'Mutatron') end
    assert(localBee(module,assert(action.carrier),'princess') or findBee(action.carrier,'princess'),
      'Module/ME needs '..action.carrier..' / princess')
    assert(localBee(module,assert(action.drone),'drone') or findBee(action.drone,'drone'),
      'Module/ME needs '..action.drone..' / drone')
    local droneReady=false
    for attempt=1,16 do
      if imprintBee(operation,module,action.drone,'drone') then droneReady=true; break end
      output('IMPRINTER WASTE drone '..action.drone..' attempt '..attempt..'/16')
    end
    assert(droneReady,'Imprinter discarded 16 '..action.drone..' drones; mutation was not started')
    if not imprintBee(operation,module,action.carrier,'princess') then
      return {kind='genetic_waste'}
    end
    loadBee(operation,module,action.drone,'drone',module.mutatron,2)
    loadBee(operation,module,action.carrier,'princess',module.mutatron,1)
    phase(operation,'processing',{processor='mutatron',module=module.address})
    return waitMutatron(module,action.result)
  end

  local function incubate(operation,action)
    local module=M.production[action.profile] and M.production[action.profile][action.moduleSlot]
    assert(module,'No production module '..tostring(action.profile)..'/'..tostring(action.moduleSlot))
    for _,slot in ipairs({1,2}) do assertMachineSlotEmpty(module,module.apiary,slot,'Industrial apiary') end
    for slot=7,15 do assertMachineSlotEmpty(module,module.apiary,slot,'Industrial apiary output') end
    loadBee(operation,module,action.species,'queen',module.apiary,1)
    phase(operation,'processing',{processor='apiary',module=module.address})
    local princess=false
    for elapsed=0,PROCESS_TIMEOUT do
      for slot=7,15 do
        local value=inventory(module.t,module.apiary.side,slot)
        if alive(value) then
          local uid,kind=bee(value)
          if kind=='princess' then
            assert(uid==action.species,'Apiary returned a different princess: '..tostring(uid))
            princess=true
            storeSlot(module,module.apiary,slot)
          else
            -- Drones are shared dependencies for other lines and modules.
            returnSlot(module,module.apiary,slot)
          end
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

  local function deliverProducer(operation,action)
    local assigned=assert(M.production[action.profile] and M.production[action.profile][action.moduleSlot],
      'Missing producer source module')
    local source,sourceSlot=assigned,ownedFinalQueen(assigned,action.species)
    if not sourceSlot then source,sourceSlot=localBeeAnywhere(action.species,'queen') end
    if sourceSlot then
      local sourceQueen=copy(inventory(source.t,source.chest.side,sourceSlot))
      assert(emptyBuffer(source),'Source ME interface buffer is occupied')
      local moved=call(source.t.transferItem,source.chest.side,source.source,1,sourceSlot)
      assert(moved==1,'Cannot export final queen from local chest')
      waitBufferEmpty(source)
      adjustSnapshot(sourceQueen,1)
    else
      assert(findBee(action.species,'queen'),
        'Final queen is absent from all module chests and ME: '..action.species)
    end
    local module=M.output
    assert(emptyBuffer(module),'Final-output ME interface buffer is occupied')
    requestBee(operation,module,action.species,'queen',module.chest,nil)
    local found=false
    for slot=1,call(module.t.getInventorySize,module.chest.side) do
      local uid,kind=bee(inventory(module.t,module.chest.side,slot))
      if uid==action.species and kind=='queen' then found=true; break end
    end
    assert(found,'Final queen was not found in producer output chest')
    return {accepted=true}
  end

  local function storeDroneSource(action)
    local module=assert(M.production[action.profile] and M.production[action.profile][action.moduleSlot])
    local moved=0
    for slot=call(module.t.getInventorySize,module.chest.side),1,-1 do
      local uid,kind=bee(inventory(module.t,module.chest.side,slot))
      if uid==action.species and (kind=='drone' or kind=='princess') then
        local value=copy(inventory(module.t,module.chest.side,slot))
        local count=call(module.t.transferItem,module.chest.side,module.source,64,slot)
        moved=moved+(tonumber(count) or 0); waitBufferEmpty(module); adjustSnapshot(value,tonumber(count) or 0)
      end
    end
    assert(moved>0,'No '..action.species..' bees in local chest')
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
    for profile,list in pairs(M.production) do
      for slot=1,#list do
        local row=parse(JOURNAL..'-'..profile..'-'..slot)
        if row then
          error('Unfinished hardware operation '..profile..'/'..slot..' ('..tostring(row.phase)
            ..'). Run opencombkeeper hardware-recover when completed, otherwise inspect the module.')
        end
      end
    end
    local outputPending=parse(JOURNAL..'-output')
    if outputPending then error('Unfinished output operation ('..tostring(outputPending.phase)..')') end
    local state=parse(STATE)
    if state then assert(state.schema==1,'Unsupported executor state') end
    return state
  end

  function M.loadPendingState()
    local state=parse(STATE)
    if state then assert(state.schema==1,'Unsupported executor state') end
    return state
  end

  function M.save(state)
    assert(type(state)=='table' and state.schema==1,'Invalid executor state')
    atomic(STATE,state)
  end

  function M.countQueens(species) return countBee(species,'queen') end
  function M.countDrones(species) return countBee(species,'drone') end
  function M.availableDrones()
    local result={}
    for _,value in pairs(readME()) do
      local uid,kind=bee(value)
      if uid and kind=='drone' then
        result[uid]=(result[uid] or 0)+(tonumber(value.size) or 0)
      end
    end
    return result
  end
  function M.manualCapacity() return 4 end

  function M.perform(action)
    assert(type(action)=='table' and type(action.type)=='string','Hardware action required')
    local operation=begin(action)
    local ok,result=pcall(function()
      if action.type=='mutation' then return mutate(operation,action)
      elseif action.type=='incubate' then return incubate(operation,action)
      elseif action.type=='deliver_producer' then return deliverProducer(operation,action)
      elseif action.type=='store_drone_source' then return storeDroneSource(action) end
      error('Unsupported hardware action: '..action.type)
    end)
    if not ok then
      phase(operation,'blocked',{failure=tostring(result)})
      error(tostring(result))
    end
    phase(operation,'completed',{result=result})
    return result
  end

  function M.ack(action)
    local path=journalPath(action)
    local pending=parse(path)
    assert(pending and pending.phase=='completed','Operation is not complete: '..operationKey(action))
    assert(fs.remove(path),'Cannot clear completed operation journal: '..path)
    return true
  end

  function M.recoverCompleted(engine)
    local pending={}
    local legacy=parse(JOURNAL); if legacy then pending[#pending+1]=legacy end
    for profile,list in pairs(M.production) do for slot=1,#list do
      local row=parse(JOURNAL..'-'..profile..'-'..slot); if row then pending[#pending+1]=row end
    end end
    local outputRow=parse(JOURNAL..'-output'); if outputRow then pending[#pending+1]=outputRow end
    assert(#pending>0,'No hardware operations to recover')
    for _,row in ipairs(pending) do
      assert(row.phase=='completed' and type(row.action)=='table' and type(row.result)=='table',
        'Operation '..operationKey(row.action)..' is not completed; inspect its module')
      local expectedKind=row.action.type=='mutation'
          and (row.result.kind=='genetic_waste' and 'line_lost'
            or row.result.species==row.action.result and 'mutation_done' or 'wrong_species')
        or row.action.type=='incubate' and 'incubation_done'
        or (row.action.type=='deliver_producer' or row.action.type=='store_drone_source') and 'line_delivered'
      local recorded=false
      for _,history in ipairs(engine.state.history or {}) do
        if history.kind==expectedKind and history.data and history.data.line==row.action.line then recorded=true; break end
      end
      if not recorded then engine:complete(row.action,row.result) end
      local path=row.path or JOURNAL
      assert(fs.remove(path),'Cannot clear recovered journal '..path)
      output('Recovered completed '..tostring(row.action.type)..' on '..operationKey(row.action))
    end
    return true
  end

  function M.retrySafeBlocked(engine)
    local retried=0
    for profile,list in pairs(M.production) do for slot=1,#list do
      local path=JOURNAL..'-'..profile..'-'..slot
      local row=parse(path)
      if row then
        assert(row.phase=='blocked' and row.action and row.action.type=='deliver_producer'
          and tostring(row.failure):find('Final queen is absent',1,true),
          'Blocked operation is not safe for automatic retry: '..profile..'/'..slot)
        engine:retry(row.action)
        assert(fs.remove(path),'Cannot clear retry journal '..path)
        retried=retried+1
      end
    end end
    assert(retried>0,'No safely retryable final-delivery operation found')
    output('Re-queued '..retried..' final delivery operation(s); local module bees were preserved.')
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
    for profile,list in pairs(M.production) do for slot=1,#list do
      local path=JOURNAL..'-'..profile..'-'..slot
      local row=parse(path)
      assert(not row or row.phase~='completed','Completed operation must be recovered: '..profile..'/'..slot)
      if fs.exists(path) then assert(fs.remove(path),'Cannot clear '..path) end
    end end
    local outputPath=JOURNAL..'-output'; local outputRow=parse(outputPath)
    assert(not outputRow or outputRow.phase~='completed','Completed output operation must be recovered')
    if fs.exists(outputPath) then assert(fs.remove(outputPath),'Cannot clear '..outputPath) end
    output('Hardware journals cleared after verifying empty owned slots.')
    return true
  end

  function M.resetState()
    assert(not fs.exists(JOURNAL),'Legacy hardware operation exists; recover or reset hardware first')
    for profile,list in pairs(M.production) do for slot=1,#list do
      assert(not fs.exists(JOURNAL..'-'..profile..'-'..slot),
        'Hardware operation exists on '..profile..'/'..slot..'; recover or reset hardware first')
    end end
    assert(not fs.exists(JOURNAL..'-output'),'Output operation exists; recover or reset hardware first')
    if fs.exists(STATE) then assert(fs.remove(STATE),'Cannot remove executor state') end
    output('Executor plan state cleared. Physical bees and module chests were not changed.')
    return true
  end

  return M
end

local injected=rawget(_G,'OPENCOMBKEEPER_HARDWARE_ENV')
local instance=new(injected or {component=require('component'),filesystem=require('filesystem'),
  serialization=require('serialization'),computer=require('computer'),sleep=os.sleep,print=print})
instance._newForTest=new
return instance
