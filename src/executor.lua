-- Pure state machine for OpenOS. Hardware callbacks perform physical actions.
local M={}

local function copy(value,seen)
  if type(value)~='table' then return value end
  seen=seen or {}; if seen[value] then return seen[value] end
  local result={}; seen[value]=result
  for key,row in pairs(value) do result[copy(key,seen)]=copy(row,seen) end
  return result
end

local function indexMutations(plan)
  local result={}
  for _,mutation in ipairs(plan.mutations or {}) do result[mutation.result]=mutation end
  return result
end

local function taskIndex(tasks)
  local result={}
  for _,task in ipairs(tasks) do
    assert(type(task.id)=='string' and not result[task.id],'Duplicate manual task')
    result[task.id]=task
  end
  return result
end

function M.new(plan,hardware,persisted)
  assert(type(plan)=='table' and plan.schema==1,'Unsupported plan')
  hardware=hardware or {}
  local self={plan=plan,hardware=hardware,mutations=indexMutations(plan)}
  if persisted then
    assert(persisted.schema==1,'Unsupported executor state')
    self.state=copy(persisted)
  else
    self.state={schema=1,status='ready',lines={},tasks=copy(plan.manualTasks or {}),history={}}
    for _,line in ipairs(plan.lines or {}) do
      self.state.lines[#self.state.lines+1]={id=line.id,role=line.role,target=line.target,
        profile=line.moduleProfile or 'plains',moduleSlot=line.moduleSlot or 1,
        route=copy(line.species),position=1,form='princess',status='waiting_input'}
    end
  end
  for _,line in ipairs(self.state.lines or {}) do
    line.form=line.form or 'princess'
  end
  self.tasks=taskIndex(self.state.tasks)
  -- Releases before managed advanced mutatrons marked tasks as prepared without
  -- physically loading parents. Re-queue those persisted tasks once.
  for _,task in ipairs(self.state.tasks) do
    if task.type=='advanced_mutation' and task.prepared and task.station==nil then
      task.prepared=nil; task.preparing=nil
    end
  end
  return setmetatable(self,{__index=M})
end

function M:save()
  if self.hardware.save then self.hardware.save(copy(self.state)) end
end

function M:record(kind,data)
  self.state.history[#self.state.history+1]={kind=kind,data=copy(data)}
  self:save()
end

function M:activateTask(id)
  local task=assert(self.tasks[id],'Unknown task')
  if task.status=='done' then return false end
  if task.type=='advanced_mutation' then
    local current=(self.hardware.countQueens and self.hardware.countQueens(task.result)) or 0
    task.baseline=current
    -- Several advanced mutatrons may target the same species concurrently.
    -- Give every task its own strictly increasing ME-count threshold so one
    -- returned queen cannot complete more than one task.
    for _,other in ipairs(self.state.tasks) do
      if other~=task and other.type=='advanced_mutation' and other.result==task.result
          and other.status~='done' and other.baseline~=nil then
        task.baseline=math.max(task.baseline,other.baseline+1)
      end
    end
  elseif task.type=='provide_drones' then
    task.baseline=0
  else
    error('Unsupported task type: '..tostring(task.type))
  end
  task.status='waiting_player'; self:record('task_activated',{id=id,baseline=task.baseline})
  return true
end

function M:checkTask(id)
  local task=assert(self.tasks[id],'Unknown task')
  if task.status=='done' then return true end
  if task.baseline==nil then return false end
  local ready=false
  if task.type=='advanced_mutation' then
    local count=(self.hardware.countQueens and self.hardware.countQueens(task.result)) or 0
    ready=count>task.baseline
  elseif task.type=='provide_drones' then
    local count=(self.hardware.countDrones and self.hardware.countDrones(task.species)) or 0
    ready=count>=task.count
  end
  if ready then
    if task.type=='advanced_mutation' then
      local line
      for _,candidate in ipairs(self.state.lines) do if candidate.id==task.line then line=candidate end end
      assert(line and line.position==task.step,'Stale advanced mutation task')
      assert(line.route[line.position+1]==task.result,'Advanced mutation result does not match line')
      line.position=line.position+1; line.form='queen'; line.status='waiting_input'
    end
    task.status='done'; self:record('task_done',{id=id})
  end
  return ready
end

function M:checkAllTasks()
  local done,total=0,0
  for _,task in ipairs(self.state.tasks) do
    total=total+1
    if task.status=='done' then done=done+1
    elseif task.baseline~=nil and self:checkTask(task.id) then done=done+1 end
  end
  return done,total
end

local function manualTaskFor(state,lineId,step)
  local id='mutation:'..lineId..':'..step
  for _,task in ipairs(state.tasks) do if task.id==id then return task end end
end

function M:nextAction()
  if self.state.status=='blocked' or self.state.status=='done' then return nil end
  local capacity=4
  if self.hardware.manualCapacity then capacity=math.max(0,tonumber(self.hardware.manualCapacity()) or 0) end
  local prepared=0
  for _,task in ipairs(self.state.tasks) do
    if task.type=='advanced_mutation' and task.status~='done' and (task.prepared or task.preparing) then prepared=prepared+1 end
  end
  local waiting
  local missingDrones={}
  local availableDrones=self.hardware.availableDrones and self.hardware.availableDrones() or nil
  local busy={}
  local outputBusy=false
  for _,line in ipairs(self.state.lines) do
    if line.status=='running' then
      busy[line.profile..':'..line.moduleSlot]=true
      if line.role=='producer' and line.position==#line.route then outputBusy=true end
    end
  end
  for _,line in ipairs(self.state.lines) do
    local moduleKey=line.profile..':'..line.moduleSlot
    -- Genetic waste consumes only this precomputed attempt. Other independent
    -- lines must keep all remaining modules busy.
    if line.status~='lost' and line.status~='running' and not busy[moduleKey]
        and line.form=='queen' and (line.position<#line.route or line.role=='drone_source') then
      return {type='incubate',line=line.id,profile=line.profile,moduleSlot=line.moduleSlot,
        species=line.route[line.position]}
    end
    if line.status~='lost' and line.status~='running' and not busy[moduleKey] and line.position<#line.route then
      local result=line.route[line.position+1]
      local mutation=assert(self.mutations[result],'Missing mutation for '..result)
      local task=manualTaskFor(self.state,line.id,line.position)
      if task and task.status~='done' then
        if not task.prepared and not task.preparing and prepared<capacity then
          if task.baseline==nil then self:activateTask(task.id) end
          local drone
          for _,parent in ipairs(mutation.parents or {}) do
            if parent~=line.route[line.position] then drone=parent; break end
          end
          return {type='prepare_manual',task=task.id,line=line.id,profile=line.profile,
            moduleSlot=line.moduleSlot,carrier=line.route[line.position],drone=drone or line.route[line.position],
            result=result,parents=copy(mutation.parents)}
        end
        waiting=waiting or {type='manual_task',task=task.id,line=line.id,result=result,
          parents=copy(mutation.parents),calendarConditions=copy(mutation.calendarConditions or {})}
      else
        local drone
        for _,parent in ipairs(mutation.parents or {}) do
          if parent~=line.route[line.position] then drone=parent; break end
        end
        drone=drone or line.route[line.position]
        local available=availableDrones and (availableDrones[drone] or 0)>0
          or not availableDrones and (not self.hardware.countDrones or self.hardware.countDrones(drone)>0)
        if available then
          return {type='mutation',line=line.id,step=line.position,profile=line.profile,moduleSlot=line.moduleSlot,
            carrier=line.route[line.position],drone=drone,result=result,parents=copy(mutation.parents),
            calendarConditions=copy(mutation.calendarConditions or {})}
        end
        missingDrones[drone]=true
      end
    elseif line.status~='lost' and line.status~='running' and not busy[moduleKey] and line.status~='delivered'
        and (line.role~='producer' or not outputBusy) then
      return {type=line.role=='producer' and 'deliver_producer' or 'store_drone_source',
        line=line.id,profile=line.profile,moduleSlot=line.moduleSlot,species=line.target,kind=line.form}
    end
  end
  if waiting then return waiting end
  if next(missingDrones) then
    local species={}; for uid in pairs(missingDrones) do species[#species+1]=uid end; table.sort(species)
    return {type='blocked_resources',missingDrones=species}
  end
  for _,task in ipairs(self.state.tasks) do
    if task.status~='done' then
      if task.baseline==nil then self:activateTask(task.id) end
      return {type='manual_task',task=task.id}
    end
  end
  for _,line in ipairs(self.state.lines) do
    if line.status=='lost' then self.state.status='blocked'; self:record('plan_incomplete',{}); return nil end
  end
  self.state.status='done'; self:record('plan_done',{}); return nil
end

function M:reserve(action)
  assert(type(action)=='table' and action.line,'Reservable line action required')
  local line
  for _,candidate in ipairs(self.state.lines) do if candidate.id==action.line then line=candidate end end
  assert(line and line.status~='running' and line.status~='delivered','Line is not reservable')
  line.status='running'; self:record('action_started',{line=line.id,type=action.type})
  if action.type=='prepare_manual' then self.tasks[action.task].preparing=true end
  return true
end

function M:retry(action)
  assert(type(action)=='table' and action.line,'Retryable line action required')
  local line
  for _,candidate in ipairs(self.state.lines) do if candidate.id==action.line then line=candidate end end
  assert(line and (line.status=='running' or line.status=='waiting_input'),'Line is not retryable')
  line.status='waiting_input'; self:record('action_retry',{line=line.id,type=action.type})
  if action.type=='prepare_manual' and self.tasks[action.task] then self.tasks[action.task].preparing=nil end
  return true
end

function M:complete(action,result)
  assert(type(action)=='table' and type(result)=='table','Action and result required')
  local line
  for _,candidate in ipairs(self.state.lines) do if candidate.id==action.line then line=candidate end end
  if action.type=='prepare_manual' then
    local task=assert(self.tasks[action.task],'Unknown manual task')
    assert(line and line.position==task.step,'Stale manual preparation')
    if result.kind=='genetic_waste' then
      task.preparing=nil; line.status='lost'
      self:record('line_lost',{line=line.id,expected=action.result}); return false
    end
    assert(result.accepted==true,'Advanced mutatron did not accept parents')
    task.preparing=nil; task.prepared=true; task.station=result.station
    line.status='waiting_input'
    self:record('manual_task_queued',{task=task.id,line=line.id,result=task.result,station=result.station})
    return true
  elseif action.type=='mutation' then
    assert(line and line.position==action.step,'Stale mutation action')
    if result.kind=='genetic_waste' then
      line.status='lost'
      self:record('line_lost',{line=line.id,expected=action.result}); return false
    end
    assert(result.kind=='queen' and result.species,'Mutation result must be a queen')
    if result.species~=action.result then
      line.status='blocked'; self.state.status='blocked'
      self:record('wrong_species',{line=line.id,expected=action.result,actual=result.species}); return false
    end
    line.position=line.position+1; line.form='queen'; line.status='waiting_input'
    self:record('mutation_done',{line=line.id,species=result.species}); return true
  elseif action.type=='incubate' then
    assert(line and line.route[line.position]==action.species and line.form=='queen',
      'Stale incubation action')
    assert(result.accepted==true,'Apiary did not return the princess line')
    line.form='princess'; line.status='waiting_input'
    self:record('incubation_done',{line=line.id,species=action.species}); return true
  elseif action.type=='deliver_producer' or action.type=='store_drone_source' then
    assert(line and line.target==action.species,'Stale delivery action')
    if action.type=='deliver_producer' then
      assert(action.kind==line.form and (line.form=='queen' or line.form=='princess'),
        'Producer output form changed')
    else assert(line.form=='princess','Drone source must finish an apiary cycle') end
    assert(result.accepted==true,'Destination did not accept line')
    line.status='delivered'; self:record('line_delivered',{line=line.id,species=line.target}); return true
  end
  error('Unsupported action completion: '..tostring(action.type))
end

function M:summary()
  local counts={waiting=0,delivered=0,lost=0,tasks=0,tasksDone=0}
  for _,line in ipairs(self.state.lines) do
    if line.status=='delivered' then counts.delivered=counts.delivered+1
    elseif line.status=='lost' then counts.lost=counts.lost+1
    else counts.waiting=counts.waiting+1 end
  end
  for _,task in ipairs(self.state.tasks) do
    counts.tasks=counts.tasks+1; if task.status=='done' then counts.tasksDone=counts.tasksDone+1 end
  end
  counts.status=self.state.status; return counts
end

return M
