-- Contract for the machine-specific OpenOS adapter.
-- Copy to /home/.opencombkeeper/hardware.lua only after binding real devices.
local M={}

function M.configure(topology)
  -- Called after the saved topology passes read-only startup validation.
  -- Keep the topology reference and resolve role endpoints from topology.roles.
  M.topology=assert(topology)
end

local function productionModule(profile,slot)
  local matches={}
  for _,module in ipairs(assert(M.topology).productionModules) do
    if module.climate==profile then matches[#matches+1]=module end
  end
  return assert(matches[slot],string.format('No production module %s/%s',tostring(profile),tostring(slot)))
end

function M.load()
  -- Return the previously persisted executor state, or nil for a new run.
  return nil
end

function M.save(state)
  -- Atomically persist state before returning. A real adapter must use .new/.bak
  -- or an equivalent crash-safe scheme.
  error('hardware.save is not configured')
end

function M.countQueens(species)
  -- Count matching queens in the shared ME network. Manual results are returned
  -- to ME; the executor records a per-species baseline before loading parents.
  return 0
end

function M.manualCapacity()
  -- Four physical advanced mutatrons are operated entirely by the player.
  return 4
end

function M.countDrones(species)
  -- Count matching drones in the configured ME network.
  return 0
end

function M.perform(action)
  -- For production actions use productionModule(action.profile,
  -- action.moduleSlot). The planner pins every line to this exact module.
  -- Supported actions:
  -- mutation: move the carrier princess and requested drone through the normal
  --           mutatron, then return {kind='queen',species='...'} or
  --           {kind='genetic_waste'}.
  -- deliver_producer: move the final queen to the beekeeper chest and return
  --                   {accepted=true} only after physical verification.
  -- store_drone_source: preserve the line and return {accepted=true}.
  error('hardware.perform is not configured for '..tostring(action.type))
end

return M
