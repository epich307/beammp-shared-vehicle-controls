-- MPInteractRelay/main.lua
--
-- Pairs with the mpInteract.lua client mod. All this does is forward a
-- "someone clicked your car" packet to whichever player actually owns the
-- targeted vehicle - it never needs to understand WHAT was clicked, only
-- WHO to send it to, which it reads straight out of the client's own
-- "ownerPlayerID-vehicleIndex" vehicle ID string. No action list to
-- maintain here, no ownership bookkeeping, nothing to update when new
-- vehicles or mods add new interactions.

-- Must be a GLOBAL function: MP.RegisterEvent looks it up by name, not by
-- the closure value, so "local function" here would silently never fire.
function onMpInteractRelay(player_id, data)
  if type(data) ~= "string" then
    print("[MPInteractRelay] dropped: payload from player "..tostring(player_id).." was not a string")
    return
  end

  -- data is a JSON string produced by the client, e.g.:
  --   {"sv":"3-0","t":"door_FR","a":"door_R","ns":"vehicle","cl":false,"ver":2,"v":1}
  -- We only need the "sv" field's owner-ID prefix, so a plain string match
  -- is enough - no JSON library needed server-side.
  local ownerID = string.match(data, '"sv"%s*:%s*"(%d+)%-')
  if not ownerID then
    print("[MPInteractRelay] dropped: couldn't find 'sv' owner prefix in: "..data)
    return
  end
  ownerID = tonumber(ownerID)
  if not ownerID then return end

  if ownerID == player_id then
    print("[MPInteractRelay] skipped: player "..tostring(player_id).." clicked their own vehicle")
    return
  end
  if not MP.IsPlayerConnected(ownerID) then
    print("[MPInteractRelay] dropped: owner "..tostring(ownerID).." is not connected")
    return
  end

  print("[MPInteractRelay] relaying click from player "..tostring(player_id).." to owner "..tostring(ownerID)..": "..data)
  MP.TriggerClientEvent(ownerID, "mpInteractExecute", data)
end

MP.RegisterEvent("mpInteractRelay", "onMpInteractRelay")

print("[MPInteractRelay] loaded - relaying vehicle-interaction clicks to vehicle owners")
