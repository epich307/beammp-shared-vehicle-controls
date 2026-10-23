-- mpInteract.lua
--
-- Lets every player in a BeamMP lobby use the BeamNG 0.40 mouse-click vehicle
-- interactions (hazards, handbrake, engine on/off, doors, hood, tailgate,
-- locks, winches, basically anything resolved through *.interaction.json /
-- the common vehicle interaction map) on OTHER PLAYERS' cars, not just their
-- own.
--
-- How it works (see the explanation given alongside this file for the full
-- reasoning):
--   1. Every clickable interaction in BeamNG, regardless of which vehicle or
--      which action, funnels through one hook: core_vehicleTriggers fires
--      "onVehicleTriggersExecuteLink" right before it runs the action's code
--      on the targeted vehicle. We listen for that hook globally.
--   2. If the targeted vehicle isn't ours (MPVehicleGE.isOwn() is false), we
--      don't try to run/force anything locally. We just package up exactly
--      which action was clicked and relay it, via a custom BeamMP event, to
--      the player who actually owns that vehicle.
--   3. A tiny server-side plugin (MPInteractRelay) just forwards that packet
--      to the right owner - it parses the owner's playerID straight out of
--      the BeamMP serverVehicleID string ("ownerID-vehicleIndex"), so it
--      doesn't need any ownership bookkeeping of its own.
--   4. The owner's client receives the relayed packet and replays the exact
--      same action, directly, on their own authoritative copy of the
--      vehicle - the same code path BeamNG itself would use if they'd
--      clicked it themselves. BeamMP's normal electrics/node/controller sync
--      then broadcasts the resulting state to everyone, same as always.
--
-- No action names are hardcoded anywhere in this file - whatever interaction
-- BeamNG resolves locally is exactly what gets relayed and replayed, so new
-- vehicles, new mods, and new interaction types from future BeamNG updates
-- are covered automatically without this file needing an update.

local M = {}

local RELAY_EVENT  = "mpInteractRelay"   -- client -> server -> owner
local EXECUTE_EVENT = "mpInteractExecute" -- server -> owner client

local handlerRegistered = false

-------------------------------------------------------------------------
-- Sender side: someone clicked a vehicle that isn't theirs
-------------------------------------------------------------------------

--- Fires for every resolved vehicle-interaction click, on every vehicle,
--- owned or not. This is BeamNG's own extension hook, not something we
--- install by patching anything.
-- @param lnk table The resolved triggerEventLinks2 entry for the thing that
--                   was clicked (has .version, .namespace, .inputAction,
--                   .commonLua, .triggerId, .targetEvent, .isInverted, ...).
-- @param actionValue number The raw action value (1 = down, 0 = up, etc.)
--                   before any per-link inversion is applied.
-- @param vehicleId number The LOCAL game object ID of the targeted vehicle
--                   (this ID is only valid on this client - every client in
--                   the lobby has its own local numbering for every car).
-- @param player number Local input player index (almost always 0).
function M.onVehicleTriggersExecuteLink(lnk, actionValue, vehicleId, player)
  if not lnk or not vehicleId then return end

  -- The whole gameplay_seatOccupants system (sitting down, switching
  -- seats, standing back up) funnels through this exact same hook, but
  -- none of it is a simple state toggle like hazards/doors/etc - replaying
  -- any of it on someone else's client makes THEM physically move (these
  -- calls act on the executing player, which on their machine is
  -- themselves). mpSeatSync handles seat entry/exit/switch end to end with
  -- its own protocol, so this mod must never touch any seat action.
  --
  -- Found two different ways: clicking the main door trigger to sit down
  -- the first time resolves to "enterSeat" - excluding only that name
  -- fixed the owner being yanked into their OWN seat on first entry. But
  -- once already seated, clicking a *different* seat trigger to switch
  -- resolves to a different action name, "switchSeat" - that one slipped
  -- through the first fix and kept pulling the owner into whichever seat
  -- a guest clicked next. Exiting the seat system entirely resolves to
  -- "exitSeat"/"toggleUnseated". Excluding the whole family here, rather
  -- than one name at a time, so any future BeamNG seat action is covered
  -- automatically instead of needing another log-driven patch.
  local actionName = lnk.inputAction or lnk.targetEvent
  local SEAT_ACTIONS = {
    enterSeat = true,
    switchSeat = true,
    exitSeat = true,
    toggleUnseated = true,
    requestEnterSeat = true,
    requestEnterBestSeat = true,
    requestUnseatedPresence = true,
  }
  if actionName and SEAT_ACTIONS[actionName] then return end

  -- SOLO SELF-TEST LINE: fires on every click, on every vehicle, including
  -- your own, regardless of MP state. If you see this in beamng.log when
  -- clicking your own car's hazards/handbrake/etc, the hook is wired up
  -- correctly and the extension loaded. Safe to delete once confirmed.
  log('I', 'mpInteract', 'SELFTEST hook fired: vehicleId='..tostring(vehicleId)..' action='..tostring(lnk.inputAction or lnk.targetEvent)..' trigger='..tostring(lnk.triggerId)..' value='..tostring(actionValue))

  -- Not in a BeamMP session at all -> nothing to do, behave like vanilla.
  if not MPGameNetwork or not MPGameNetwork.launcherConnected or not MPGameNetwork.launcherConnected() then
    log('I', 'mpInteract', 'SELFTEST not in a BeamMP session, stopping here')
    return
  end

  if not MPVehicleGE or not MPVehicleGE.isOwn or not MPVehicleGE.getServerVehicleID then
    log('W', 'mpInteract', 'SELFTEST MPVehicleGE API missing - is BeamMP actually loaded?')
    return
  end

  -- It's our own vehicle - BeamMP already syncs our own actions normally,
  -- nothing extra to do.
  if MPVehicleGE.isOwn(vehicleId) then
    log('I', 'mpInteract', 'SELFTEST vehicle '..tostring(vehicleId)..' is ours, nothing to relay (this is expected and correct)')
    return
  end

  local serverVehicleID = MPVehicleGE.getServerVehicleID(vehicleId)
  if not serverVehicleID then return end

  -- Replicate the exact same inversion executeLink() would have applied,
  -- so the value we relay is the one that should actually be fed into the
  -- action, verbatim, on the owner's side.
  local value = actionValue
  if lnk.isInverted then value = -value end

  local payload = {
    sv  = serverVehicleID,       -- "ownerPlayerID-vehicleIndex"
    t   = lnk.triggerId,         -- which clickable element was hit
    a   = lnk.inputAction or lnk.targetEvent, -- action name (new or old style)
    ns  = lnk.namespace,         -- "vehicle" / "common" / nil (old style)
    cl  = lnk.commonLua and true or false,
    ver = lnk.version,
    v   = value,
  }

  local ok, encoded = pcall(jsonEncode, payload)
  if not ok or not encoded then return end

  log('I', 'mpInteract', 'relaying click on foreign vehicle '..tostring(serverVehicleID)..' action='..tostring(payload.a)..' trigger='..tostring(payload.t)..' value='..tostring(value))
  TriggerServerEvent(RELAY_EVENT, encoded)
end

-------------------------------------------------------------------------
-- Receiver side: the server relayed a click on OUR vehicle back to us
-------------------------------------------------------------------------

local function onMpInteractExecute(dataStr)
  local ok, data = pcall(jsonDecode, dataStr)
  if not ok or not data or not data.sv then
    log('W', 'mpInteract', 'received malformed execute payload: '..tostring(dataStr))
    return
  end

  if not MPVehicleGE or not MPVehicleGE.getGameVehicleID or not MPVehicleGE.isOwn then return end

  local gameVehicleID = MPVehicleGE.getGameVehicleID(data.sv)
  if not gameVehicleID then
    log('W', 'mpInteract', 'could not resolve game vehicle id for serverVehicleID '..tostring(data.sv))
    return
  end

  -- Safety net: only ever act on a vehicle that really is ours. A malicious
  -- or buggy sender can't make us run code on someone else's car this way.
  if not MPVehicleGE.isOwn(gameVehicleID) then
    log('W', 'mpInteract', 'refused to execute: '..tostring(data.sv)..' is not ours')
    return
  end

  local vehData = extensions.core_vehicle_manager and extensions.core_vehicle_manager.getVehicleData(gameVehicleID)
  if not vehData or not vehData.vdata then return end

  log('I', 'mpInteract', 'executing relayed click on own vehicle '..tostring(data.sv)..' action='..tostring(data.a)..' trigger='..tostring(data.t))

  local value = tonumber(data.v) or 0
  local player = tonumber(data.p) or 0

  -- Mirrors executeLink()'s three branches in core/vehicleTriggers.lua,
  -- but calling straight into core_input_actions so nothing is
  -- re-evaluated or re-hooked (this does NOT re-fire
  -- onVehicleTriggersExecuteLink, so there's no relay loop).
  if data.ver == 2 and data.ns == 'vehicle' then
    local actionCode = vehData.vdata.inputActions and vehData.vdata.inputActions[data.a]
    if actionCode and extensions.core_input_actions then
      extensions.core_input_actions.executeCommand(actionCode, value, gameVehicleID, player, data.t)
    end
  elseif data.ver == 2 and data.ns == 'common' then
    if data.cl then
      local actionCode = vehData.vdata.inputActions and vehData.vdata.inputActions[data.a]
      if actionCode and extensions.core_input_actions then
        extensions.core_input_actions.executeCommand(actionCode, value, gameVehicleID, player, data.t)
      end
    else
      -- native C++ action-map binding, resolved by name
      if ActionMap and ActionMap.triggerBindingByNameDigital then
        ActionMap.triggerBindingByNameDigital(data.a, value > 0.9, os.clockhp(), gameVehicleID)
      end
    end
  else
    -- old-style link: data.a is actually the raw targetEvent string
    if data.a and extensions.core_input_actions then
      extensions.core_input_actions.executeCommand(data.a, value, gameVehicleID, player, data.t)
    end
  end
end

-------------------------------------------------------------------------
-- Registration (deferred - BeamMP's globals may not exist yet the exact
-- frame this extension loads, so we just keep trying until they do).
-------------------------------------------------------------------------

function M.onUpdate()
  if handlerRegistered then return end
  if type(AddEventHandler) == 'function' then
    AddEventHandler(EXECUTE_EVENT, onMpInteractExecute, "mpInteract")
    handlerRegistered = true
  end
end

function M.onExtensionLoaded()
  if type(AddEventHandler) == 'function' then
    AddEventHandler(EXECUTE_EVENT, onMpInteractExecute, "mpInteract")
    handlerRegistered = true
  end
end

return M
