-- Contract for the machine-specific OpenOS adapter.
-- Copy to /home/.opencombkeeper/hardware.lua only after binding real devices.
local M={}

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
  -- Count matching queens in the dedicated manual-result container. If species
  -- is nil, count all queens so the executor can require an empty container.
  return 0
end

function M.countDrones(species)
  -- Count matching drones in the configured ME network.
  return 0
end

function M.perform(action)
  -- Supported actions:
  -- prepare_manual_mutation: load both parents into the advanced mutatron and
  --                          return {accepted=true} after slot verification.
  -- mutation: move the carrier princess and requested drone through the normal
  --           mutatron, then return {kind='queen',species='...'} or
  --           {kind='genetic_waste'}.
  -- deliver_producer: move the final queen to the beekeeper chest and return
  --                   {accepted=true} only after physical verification.
  -- store_drone_source: preserve the line and return {accepted=true}.
  error('hardware.perform is not configured for '..tostring(action.type))
end

return M
