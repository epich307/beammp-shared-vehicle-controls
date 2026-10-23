-- MPSeatSync server plugin
--
-- The one authoritative record of "who's sitting in which seat of which
-- vehicle" for the whole lobby. Clients tell us when their own local
-- player sits down or gets up (mpSeatClaim); we're the tie-breaker when
-- two people claim the same seat at nearly the same instant, and we relay
-- accepted enter/exit events to every OTHER connected player so their
-- clients can mirror the seat visually (see mpSeatSync.lua client side).
--
-- IMPORTANT: unlike GE/VE Lua inside the game, BeamMP's server-side Lua
-- runtime has no jsonEncode/jsonDecode globals - those only exist in
-- BeamNG's own engine Lua. Every claim was being dropped as "malformed"
-- because jsonDecode doesn't exist server-side (pcall just caught the
-- "attempt to call a nil value" error). So every payload here is a flat,
-- known shape of plain strings and is parsed/built with plain string
-- patterns instead - no JSON library needed or assumed.
--
-- seatClaims[serverVehicleID][seatId] = playerID currently holding it
-- driveClaims[serverVehicleID] = playerID currently driving it (a guest,
-- never the owner - the owner is always free to drive their own car)

local seatClaims = {}
local driveClaims = {}

local function ownerIdOf(serverVehicleID)
  local idStr = string.match(serverVehicleID, "^(%d+)%-")
  return idStr and tonumber(idStr)
end

-- Pulls a quoted string field "name":"value" out of a flat JSON object
-- string. Every field we ever send is a plain string (sv, seat, action),
-- so this is all the parsing we need - no general JSON parser required.
local function extractField(jsonStr, fieldName)
  return string.match(jsonStr, '"' .. fieldName .. '"%s*:%s*"([^"]*)"')
end

local function buildSeatPayload(sv, seat, action)
  return string.format('{"sv":"%s","seat":"%s","action":"%s"}', sv, seat, action)
end

local function buildDrivePayload(sv, action)
  return string.format('{"sv":"%s","action":"%s"}', sv, action)
end

local function getAllConnectedPlayerIDs()
  -- Prefer the modern API if present; fall back to scanning IDs otherwise.
  if type(MP.GetPlayerIDs) == "function" then
    local ok, ids = pcall(MP.GetPlayerIDs)
    if ok and type(ids) == "table" then return ids end
  end
  local ids = {}
  local count = (type(MP.GetPlayerCount) == "function") and MP.GetPlayerCount() or 0
  -- IDs aren't guaranteed contiguous, so just probe a generous range.
  for id = 0, math.max(count * 4, 64) do
    if MP.IsPlayerConnected(id) then ids[#ids + 1] = id end
  end
  return ids
end

local function broadcastToOthers(exceptPlayerID, event, payload)
  for _, id in ipairs(getAllConnectedPlayerIDs()) do
    if id ~= exceptPlayerID and MP.IsPlayerConnected(id) then
      MP.TriggerClientEvent(id, event, payload)
    end
  end
end

local function clearPlayerClaims(playerID)
  for serverVehicleID, seats in pairs(seatClaims) do
    for seatId, holder in pairs(seats) do
      if holder == playerID then
        seats[seatId] = nil
        broadcastToOthers(playerID, "mpSeatSync", buildSeatPayload(serverVehicleID, seatId, "exit"))
      end
    end
    if next(seats) == nil then
      seatClaims[serverVehicleID] = nil
    end
  end

  for serverVehicleID, driverID in pairs(driveClaims) do
    if driverID == playerID then
      driveClaims[serverVehicleID] = nil
      local ownerID = ownerIdOf(serverVehicleID)
      if ownerID and MP.IsPlayerConnected(ownerID) then
        MP.TriggerClientEvent(ownerID, "mpDriveSync", buildDrivePayload(serverVehicleID, "exit"))
      end
    end
  end
end

function onMpSeatClaim(player_id, data)
  if type(data) ~= "string" then return end
  local sv = extractField(data, "sv")
  local seat = extractField(data, "seat")
  local action = extractField(data, "action")
  if not sv or not seat or not action then
    print("[MPSeatSync] dropped malformed claim from player " .. tostring(player_id) .. ": " .. tostring(data))
    return
  end

  if action == "exit" then
    local seats = seatClaims[sv]
    if seats and seats[seat] == player_id then
      seats[seat] = nil
      if next(seats) == nil then seatClaims[sv] = nil end
      print("[MPSeatSync] player " .. tostring(player_id) .. " left seat " .. seat .. " of " .. sv)
      broadcastToOthers(player_id, "mpSeatSync", data)
    end
    return
  end

  if action == "enter" then
    seatClaims[sv] = seatClaims[sv] or {}
    local currentHolder = seatClaims[sv][seat]

    if currentHolder ~= nil and currentHolder ~= player_id and MP.IsPlayerConnected(currentHolder) then
      -- Someone else already legitimately holds this seat - deny the
      -- late claim and tell that client to vacate what it optimistically
      -- sat down in.
      print("[MPSeatSync] denied player " .. tostring(player_id) .. " seat " .. seat .. " of " .. sv ..
        " (held by " .. tostring(currentHolder) .. ")")
      MP.TriggerClientEvent(player_id, "mpSeatDenied", buildSeatPayload(sv, seat, "denied"))
      return
    end

    -- Free, or a stale/disconnected claim - grant it. If this player was
    -- already sitting somewhere else, that old seat is implicitly
    -- abandoned; clear it so it doesn't stay stuck as "occupied".
    for otherVehicleID, seats in pairs(seatClaims) do
      for otherSeat, holder in pairs(seats) do
        if holder == player_id and (otherVehicleID ~= sv or otherSeat ~= seat) then
          seats[otherSeat] = nil
          broadcastToOthers(player_id, "mpSeatSync", buildSeatPayload(otherVehicleID, otherSeat, "exit"))
        end
      end
    end

    seatClaims[sv][seat] = player_id
    print("[MPSeatSync] player " .. tostring(player_id) .. " took seat " .. seat .. " of " .. sv)
    broadcastToOthers(player_id, "mpSeatSync", data)
  end
end

-- A guest wants to start/stop actually driving someone else's car. Unlike
-- seat claims (broadcast to everyone for visual mirroring), this only
-- ever needs to reach the one client that owns the vehicle - they're the
-- only one whose input-injection matters.
function onMpDriveClaim(player_id, data)
  if type(data) ~= "string" then return end
  local sv = extractField(data, "sv")
  local action = extractField(data, "action")
  if not sv or not action then return end
  local ownerID = ownerIdOf(sv)
  if not ownerID or not MP.IsPlayerConnected(ownerID) then return end
  if ownerID == player_id then return end -- you already drive your own car

  if action == "enter" then
    driveClaims[sv] = player_id
    print("[MPSeatSync] player " .. tostring(player_id) .. " is now driving " .. sv ..
      " (owned by " .. tostring(ownerID) .. ")")
  elseif action == "exit" then
    if driveClaims[sv] == player_id then driveClaims[sv] = nil end
    print("[MPSeatSync] player " .. tostring(player_id) .. " stopped driving " .. sv)
  else
    return
  end

  MP.TriggerClientEvent(ownerID, "mpDriveSync", data)
end

-- Continuous control stream from whoever is currently driving a vehicle,
-- forwarded straight to its owner. Kept minimal - no validation beyond
-- "there's an active claim from this exact player" - since this fires
-- many times a second and every extra millisecond here is latency the
-- driver will feel. We never need to parse the inner input payload here,
-- just the outer "sv" field, so this stays cheap.
function onMpDriveInput(player_id, data)
  if type(data) ~= "string" then return end
  local sv = extractField(data, "sv")
  if not sv then return end
  if driveClaims[sv] ~= player_id then return end
  local ownerID = ownerIdOf(sv)
  if not ownerID or not MP.IsPlayerConnected(ownerID) then return end
  MP.TriggerClientEvent(ownerID, "mpDriveInput", data)
end

function onPlayerDisconnect(player_id)
  clearPlayerClaims(player_id)
end

-- Every claim/exit above only ever gets broadcast to whoever happens to be
-- connected AT THAT MOMENT. A player who connects later, or reconnects,
-- never gets told about seats someone else is ALREADY sitting in - they'd
-- only find out the next time that occupant's seat changes again, which
-- could be minutes away or never. This is the "character doesn't show up
-- right away" symptom: it's not a sync delay, it's a one-time missing
-- catch-up state. Fired once a player has finished loading mods and is
-- ready to receive custom events, so it's safe to push state immediately.
function onPlayerJoin(player_id)
  for serverVehicleID, seats in pairs(seatClaims) do
    for seatId, holder in pairs(seats) do
      if holder ~= player_id and MP.IsPlayerConnected(holder) then
        MP.TriggerClientEvent(player_id, "mpSeatSync", buildSeatPayload(serverVehicleID, seatId, "enter"))
      end
    end
  end
end

MP.RegisterEvent("mpSeatClaim", "onMpSeatClaim")
MP.RegisterEvent("mpDriveClaim", "onMpDriveClaim")
MP.RegisterEvent("mpDriveInput", "onMpDriveInput")
MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
-- Without this, onPlayerDisconnect below is defined but never actually
-- called by the server - so clearPlayerClaims never runs when someone
-- leaves, and their seat claim (plus the dummy-occupant mesh mirroring
-- it on every other client) is left stuck forever. This was the cause
-- of a disconnected player's character staying visibly seated in the car.
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
print("[MPSeatSync] loaded - tracking and syncing who is sitting where, and who is driving what")
