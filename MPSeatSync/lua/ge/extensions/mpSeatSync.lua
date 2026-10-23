-- mpSeatSync.lua
--
-- Lets every player in a BeamMP lobby walk up to and sit in ANY vehicle's
-- seats in BeamNG 0.40 - including other players' cars - makes sure a seat
-- that's already occupied can't be double-sat, AND lets whoever sits in the
-- DRIVER's seat of a car they don't own actually drive it (steering,
-- throttle, brake, clutch, parking brake, gears), with the real owner's
-- client still doing the actual physics simulation.
--
-- ===========================================================================
-- PART 1: seat occupancy mirroring (unchanged from the first version)
-- ===========================================================================
-- gameplay_seatOccupants (confirmed by reading
-- lua/ge/extensions/gameplay/seatOccupants.lua directly) is a PURELY LOCAL
-- Lua table on each client with zero concept of other networked players.
-- Sitting shows the car's own built-in occupant mesh and fakes body weight
-- via a cargo-container volume trick - no coupler/attachment involved.
-- onSeatOccupantEnter/Exit(player, vehId) fire for the local player's own
-- seat changes; setDummyOccupant/clearDummyOccupant(vehId, seatId, weight)
-- let every OTHER client mirror that visually with zero control granted.
--
-- ===========================================================================
-- PART 2: actually driving someone else's car (new)
-- ===========================================================================
-- Confirmed by reading BeamMP's own shipped vehicle-side Lua
-- (lua/vehicle/extensions/BeamMP/MPInputsVE.lua and lua/vehicle/input.lua):
--   - Every vehicle has a VE-side flag v.mpVehicleType: 'L' if this client
--     owns it (full local physics driven by local input), 'R' otherwise
--     (physics mostly driven by network state from the real owner).
--   - input.lua's event(itype, ivalue, filter, angle, lockType, osClockHP,
--     source) records EVERY call into input.lastInputs[source][itype],
--     unconditionally, even for a source that's been disabled via
--     input.setAllowedInputSource(itype, source, false). BeamMP itself
--     disables the "local" source on 'R' vehicles to stop your own
--     keypresses from fighting the real owner's broadcast state - but
--     input.lastInputs["local"] keeps reflecting your real, intended input
--     regardless. That's our clean read point for "what is the guest
--     actually trying to do", with no risk of fighting local physics.
--   - input.event(...) is how you INJECT a value as if a real input source
--     produced it. BeamMP's own code calls this on 'R' vehicles purely for
--     cosmetic animation; we call the exact same function on an 'L'
--     (actually owned) vehicle to really drive it.
--   - MPVehicleGE loads its whole VE extension folder into every spawned
--     vehicle via veh:queueLuaCommand("extensions.loadModulesInDirectory(
--     'lua/vehicle/extensions/BeamMP')"). We do the identical thing for our
--     own folder to get mpSeatSyncVE.lua loaded into every vehicle too.
--
-- So: the real owner's client remains the one and only physics authority
-- the whole time (nothing about BeamMP's ownership/sync model is touched).
-- The guest's client just reads their own raw input intent every tick and
-- streams it to the server, which forwards it to the owner; the owner's
-- client injects it into their own, already-owned vehicle via input.event,
-- after disabling their own local input for that car so the two don't
-- fight. Gear shifts are relayed the same way BeamMP's own code shifts a
-- remote vehicle's gearbox (controller.mainController / setGearIndex).

local M = {}

local CLAIM_EVENT = "mpSeatClaim"       -- client -> server: I entered/left a seat
local SYNC_EVENT = "mpSeatSync"         -- server -> other clients: mirror this seat
local DENY_EVENT = "mpSeatDenied"       -- server -> sender: someone beat you to it

local DRIVE_CLAIM_EVENT = "mpDriveClaim" -- client -> server -> owner: take/release the wheel
local DRIVE_SYNC_EVENT = "mpDriveSync"   -- server -> owner: a guest is now driving/stopped
local DRIVE_INPUT_EVENT = "mpDriveInput" -- guest -> server -> owner: continuous control stream
local VE_EXTENSION_DIR = 'lua/vehicle/extensions/mpSeatSync'

local handlerRegistered = false

-- serverVehicleID -> seatId we currently THINK we hold (used to detect which
-- seat we just left, since onSeatOccupantExit only gives us the vehicle).
local lastKnownSeat = {}

-- serverVehicleID of the car we're currently guest-driving (nil if none).
local guestDriveServerVehicleID = nil
local guestDriveGameVehicleID = nil

-------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------

local function inBeamMPSession()
  return MPGameNetwork and MPGameNetwork.launcherConnected and MPGameNetwork.launcherConnected()
end

local function findMySeat(vehId, player)
  if not gameplay_seatOccupants or not gameplay_seatOccupants.getSeats then return nil end
  for _, seat in ipairs(gameplay_seatOccupants.getSeats(vehId)) do
    if seat.occupied and seat.player == player then
      return seat
    end
  end
  return nil
end

local function sendClaim(serverVehicleID, seatId, action)
  local ok, encoded = pcall(jsonEncode, {sv = serverVehicleID, seat = seatId, action = action})
  if not ok or not encoded then return end
  TriggerServerEvent(CLAIM_EVENT, encoded)
end

local function veh(vehId)
  return scenetree.findObjectById(vehId)
end

-------------------------------------------------------------------------
-- Make sure every vehicle has our VE controller loaded (mirrors exactly
-- how BeamMP's own mod loads its lua/vehicle/extensions/BeamMP folder).
-------------------------------------------------------------------------

-- onSeatOccupantEnter only ever gets dispatched from the "real" seat
-- transition code paths (completeSeatTransition and similar) - the ones
-- that run when a player WALKS UP and CLICKS into a seat. Confirmed by
-- reading seatOccupants.lua directly: spawning your own vehicle and
-- being auto-seated into it apparently never runs through any of those
-- paths, so the hook never fires - no claim is ever sent for that very
-- first auto-entry, which is exactly why nobody else ever saw anything
-- for it (not even a failed/queued attempt - there was nothing to
-- receive), and why switching seats or re-entering through a REAL click
-- afterward "fixed" it: that's the first moment the hook ever actually
-- fired. Rather than trust the hook for this case, poll for a few
-- seconds after every spawn whether WE ended up seated in it, and if so,
-- drive the exact same claim logic ourselves.
local pendingSpawnSeatCheck = {} -- vehId -> secondsWaited
local SPAWN_SEAT_CHECK_TIMEOUT = 5

function M.onVehicleSpawned(vehId)
  local v = veh(vehId)
  if not v then return end
  v:queueLuaCommand("extensions.loadModulesInDirectory('" .. VE_EXTENSION_DIR .. "')")
  pendingSpawnSeatCheck[vehId] = 0
end

local function checkPendingSpawnSeats(dtReal)
  dtReal = dtReal or 0
  for vehId, age in pairs(pendingSpawnSeatCheck) do
    if not veh(vehId) then
      pendingSpawnSeatCheck[vehId] = nil
    else
      local seat = findMySeat(vehId, 0)
      if seat then
        log('I', 'mpSeatSync', 'caught auto-seated entry on spawn (no hook fired) for vehicle ' .. tostring(vehId))
        pendingSpawnSeatCheck[vehId] = nil
        M.onSeatOccupantEnter(0, vehId)
      else
        age = age + dtReal
        if age > SPAWN_SEAT_CHECK_TIMEOUT then
          pendingSpawnSeatCheck[vehId] = nil -- not us - someone else's vehicle, or we never got in
        else
          pendingSpawnSeatCheck[vehId] = age
        end
      end
    end
  end
end

-------------------------------------------------------------------------
-- Local player's own seat changed -> tell the server, and start/stop
-- driving if it was the driver's seat of a car we don't own.
-------------------------------------------------------------------------

local function stopGuestDriving()
  if not guestDriveServerVehicleID then return end
  local ok, encoded = pcall(jsonEncode, {sv = guestDriveServerVehicleID, action = "exit"})
  if ok then TriggerServerEvent(DRIVE_CLAIM_EVENT, encoded) end
  local v = guestDriveGameVehicleID and veh(guestDriveGameVehicleID)
  if v then v:queueLuaCommand("if mpSeatSyncVE then mpSeatSyncVE.setGuestDriving(false) end") end
  guestDriveServerVehicleID = nil
  guestDriveGameVehicleID = nil
end

function M.onSeatOccupantEnter(player, vehId)
  player = player or 0
  if player ~= 0 then return end -- only the local client's own player index matters here
  if not vehId then return end
  if not inBeamMPSession() then return end
  if not MPVehicleGE or not MPVehicleGE.getServerVehicleID then return end

  local serverVehicleID = MPVehicleGE.getServerVehicleID(vehId)
  if not serverVehicleID then return end

  local seat = findMySeat(vehId, player)
  if not seat then return end

  -- BeamNG's native seat-entry hook genuinely fires more than once per
  -- sit-down - once provisionally the instant you click, again when the
  -- transition actually completes (confirmed by the server log: every
  -- single seat claim showed up twice, back to back, for every entry).
  -- Without this guard we'd re-send an identical claim, which the
  -- server re-broadcasts and every other client re-mirrors for no
  -- reason, and on a seat someone else already holds, the second fire
  -- would still go on to request a drive claim for a seat we don't
  -- actually have (seen in the log as "is now driving" immediately
  -- followed by "stopped driving"). A seat switch or a genuine re-entry
  -- after exiting still goes through fine, since lastKnownSeat gets
  -- cleared on exit and updated to the new seat on a real switch.
  if lastKnownSeat[serverVehicleID] == seat.seatId then return end

  lastKnownSeat[serverVehicleID] = seat.seatId
  log('I', 'mpSeatSync', 'claiming seat ' .. tostring(seat.seatId) .. ' on ' .. tostring(serverVehicleID))
  sendClaim(serverVehicleID, seat.seatId, "enter")

  local wantsToDrive = seat.isDriver and not MPVehicleGE.isOwn(vehId)

  -- Switching seats within the same vehicle doesn't fire onSeatOccupantExit
  -- (confirmed in seatOccupants.lua: only a vehicle change does), so a
  -- driver who moves to a passenger seat in the SAME car needs to be
  -- dropped here, not just when they leave the vehicle entirely.
  if guestDriveServerVehicleID == serverVehicleID and not wantsToDrive then
    stopGuestDriving()
  end

  -- Driver's seat of a car that isn't ours -> ask to actually drive it.
  if wantsToDrive and guestDriveServerVehicleID ~= serverVehicleID then
    if guestDriveServerVehicleID then
      stopGuestDriving()
    end
    guestDriveServerVehicleID = serverVehicleID
    guestDriveGameVehicleID = vehId
    log('I', 'mpSeatSync', 'requesting to drive ' .. tostring(serverVehicleID))
    local ok, encoded = pcall(jsonEncode, {sv = serverVehicleID, action = "enter"})
    if ok then TriggerServerEvent(DRIVE_CLAIM_EVENT, encoded) end
    local v = veh(vehId)
    if v then v:queueLuaCommand("if mpSeatSyncVE then mpSeatSyncVE.setGuestDriving(true) end") end
  end
end

-- Catches the one case onSeatOccupantEnter/Exit don't: moving between two
-- seats of the SAME vehicle (e.g. passenger -> driver, or driver ->
-- passenger). seatOccupants.lua fires this hook for every presence change,
-- including that one, via setPlayerPresence.
function M.onPlayerVehiclePresenceChanged(player, old, new)
  player = player or 0
  if player ~= 0 then return end
  if not old or not new then return end
  if old.vehicleId ~= new.vehicleId then return end -- cross-vehicle: already handled above
  if old.seatId == new.seatId then return end
  M.onSeatOccupantEnter(player, new.vehicleId)
end

function M.onSeatOccupantExit(player, vehId)
  player = player or 0
  if player ~= 0 then return end
  if not vehId then return end
  if not inBeamMPSession() then return end
  if not MPVehicleGE or not MPVehicleGE.getServerVehicleID then return end

  local serverVehicleID = MPVehicleGE.getServerVehicleID(vehId)
  if not serverVehicleID then return end

  local seatId = lastKnownSeat[serverVehicleID]
  lastKnownSeat[serverVehicleID] = nil
  if seatId then
    log('I', 'mpSeatSync', 'releasing seat ' .. tostring(seatId) .. ' on ' .. tostring(serverVehicleID))
    sendClaim(serverVehicleID, seatId, "exit")
  end

  if guestDriveServerVehicleID == serverVehicleID then
    stopGuestDriving()
  end
end

-------------------------------------------------------------------------
-- Guest side: relay our own raw input intent, sampled every tick by
-- mpSeatSyncVE.lua on OUR OWN local copy of the foreign vehicle, straight
-- to the server for forwarding to the owner.
-------------------------------------------------------------------------

function M.onGuestInputSample(vehId, dataStr)
  if guestDriveGameVehicleID ~= vehId or not guestDriveServerVehicleID then return end
  local ok, encoded = pcall(jsonEncode, {sv = guestDriveServerVehicleID, data = dataStr})
  if not ok then return end
  TriggerServerEvent(DRIVE_INPUT_EVENT, encoded)
end

-------------------------------------------------------------------------
-- Receiver side: mirror another player's seat, get bounced out of one we
-- lost a race for, start/stop accepting relayed input on our OWN vehicle,
-- or apply a relayed input sample to it.
-------------------------------------------------------------------------

-- Two separate reasons a mirrored seat can fail to show up the first time,
-- both only noticeable on a FRESHLY SPAWNED vehicle:
--   1. A fresh spawn + instant auto-enter of the driver's seat happen
--      back-to-back on the spawning player's client, so the "enter" claim
--      can reach us before BeamMP has even finished syncing the new
--      vehicle object itself - getGameVehicleID comes back nil.
--   2. Even once the vehicle OBJECT resolves, setDummyOccupant still talks
--      to that vehicle's own Lua VM (its node/mesh/physics state) - and
--      that VM can still be mid-load for a bit after the object exists in
--      the scene tree. A command sent in that window seems to get
--      silently dropped rather than queued (nothing errors, it just never
--      takes), which fits exactly why switching seats or re-entering -
--      ANY later real seat-system event - "fixes" it: by then the vehicle
--      has finished loading and that later call lands properly.
-- Both get the same answer: don't trust one attempt. Keep re-sending the
-- most recent desired state (enter seat X / cleared) for a few seconds
-- after every claim, not just once, whether or not the vehicle resolved
-- immediately.
-- A 3-second retry window turned out not to be enough - this server has
-- some heavy custom vehicle mods, and a fresh spawn's Lua VM can plausibly
-- still be mid-load well past that. Widened substantially (a minute of
-- coverage) rather than guess at a shorter number again; re-sending an
-- already-correct state is harmless, so there's little cost to erring
-- long here.
local mirrorRetries = {} -- sv -> seatId -> { action=, gameVehicleID=nil, retriesLeft=, nextRetryIn=, age= }
local MIRROR_RETRY_INTERVAL = 1.0   -- seconds between re-sends once the vehicle resolves
local MIRROR_RETRY_COUNT = 60       -- re-sends after the first attempt (~60s of coverage)
local MIRROR_UNRESOLVED_TIMEOUT = 60 -- give up if the vehicle itself never resolves at all

-- setDummyOccupant/clearDummyOccupant return false + a reason string
-- ("occupied", "reserved", "invalidSeat", "invalidVehicle", "notDummy")
-- when they refuse to do anything - confirmed by logging it (see below)
-- that this is EXACTLY what was happening: BeamNG's own click-handling
-- sits our LOCAL character down the instant we click a seat, before our
-- claim has even reached the server - so occupancy[vehId][seat] gets a
-- REAL (non-dummy) {player=0,...} record from US on OUR OWN client
-- whenever we tried (and lost) a seat, and it was never actually cleaned
-- up afterwards. That stale record then permanently blocks
-- setDummyOccupant for that exact seat ("occupied"), and permanently
-- blocks clearDummyOccupant too ("notDummy", since it's not a dummy to
-- begin with) - confirmed by seeing it reject every single retry, never
-- once succeeding, which ruled out this ever being a timing issue.
-- On a vehicle we're not driving, ANY occupancy entry under our own
-- local player index is necessarily stale leftover, never a legitimate
-- occupant - so clear it and retry once immediately.
--
-- Every call into gameplay_seatOccupants below is wrapped in pcall. This
-- is core BeamNG engine code, not ours, and it can throw a genuine
-- engine-side Fatal Lua Error (seen in practice: isUnicycle() calling
-- :getJBeamFilename() on a vehicle handle that's valid userdata but not
-- a real vehicle object, e.g. mid-despawn during a disconnect) that is
-- NOT wrapped in pcall anywhere upstream of us - left uncaught, it takes
-- the whole client down, not just this mod. Catching it here means a
-- single bad/transitional vehicle handle just fails this one mirror
-- attempt (it'll get picked up by the retry loop or the next real seat
-- event instead) rather than crashing the game.
local function safeSeatCall(fn, ...)
  if not fn then return false, "unavailable" end
  local ok, success, reason = pcall(fn, ...)
  if not ok then
    -- pcall failed: `success` here is actually the error message.
    return false, "threw: " .. tostring(success)
  end
  return success, reason
end

-- Returns true/false so the retry loop below can stop as soon as an
-- attempt actually works, instead of blindly burning through its whole
-- retry budget regardless of outcome (see flushMirrorRetries).
local function applySeatSyncOp(gameVehicleID, seat, action)
  if action == "enter" then
    local success, reason = safeSeatCall(gameplay_seatOccupants.setDummyOccupant, gameVehicleID, seat, 89)
    if not success and reason == "occupied" and gameplay_seatOccupants.clearOccupied then
      log('W', 'mpSeatSync', 'seat ' .. tostring(seat) .. ' on vehicle ' .. tostring(gameVehicleID) ..
        ' had a stale non-dummy occupant blocking us - clearing it and retrying')
      safeSeatCall(gameplay_seatOccupants.clearOccupied, gameVehicleID, seat)
      success, reason = safeSeatCall(gameplay_seatOccupants.setDummyOccupant, gameVehicleID, seat, 89)
    end
    log('I', 'mpSeatSync', 'mirroring remote seat ' .. tostring(seat) .. ' on vehicle ' .. tostring(gameVehicleID) ..
      ' -> ' .. tostring(success) .. (reason and (' (' .. tostring(reason) .. ')') or ''))
    return success == true
  elseif action == "exit" then
    local success, reason = safeSeatCall(gameplay_seatOccupants.clearDummyOccupant, gameVehicleID, seat)
    if not success and reason == "notDummy" and gameplay_seatOccupants.clearOccupied then
      log('W', 'mpSeatSync', 'seat ' .. tostring(seat) .. ' on vehicle ' .. tostring(gameVehicleID) ..
        ' had a stale non-dummy occupant instead of our dummy - clearing it directly')
      safeSeatCall(gameplay_seatOccupants.clearOccupied, gameVehicleID, seat)
      success, reason = true, nil
    end
    log('I', 'mpSeatSync', 'clearing mirrored seat ' .. tostring(seat) .. ' on vehicle ' .. tostring(gameVehicleID) ..
      ' -> ' .. tostring(success) .. (reason and (' (' .. tostring(reason) .. ')') or ''))
    return success == true
  end
  return false
end

local function onMpSeatSync(dataStr)
  local ok, data = pcall(jsonDecode, dataStr)
  if not ok or not data or not data.sv or not data.seat then return end
  if not MPVehicleGE or not MPVehicleGE.getGameVehicleID then return end
  if not gameplay_seatOccupants then return end

  mirrorRetries[data.sv] = mirrorRetries[data.sv] or {}
  -- A newer claim for this exact seat replaces whatever we were still
  -- retrying for it (e.g. someone sat down and immediately switched out).
  mirrorRetries[data.sv][data.seat] = {
    action = data.action,
    gameVehicleID = MPVehicleGE.getGameVehicleID(data.sv), -- may still be nil, that's fine
    retriesLeft = MIRROR_RETRY_COUNT,
    nextRetryIn = 0, -- apply immediately on the next tick
    age = 0,
  }
end

local function flushMirrorRetries(dtReal)
  if not MPVehicleGE or not MPVehicleGE.getGameVehicleID or not gameplay_seatOccupants then return end
  dtReal = dtReal or 0
  for sv, seats in pairs(mirrorRetries) do
    for seatId, state in pairs(seats) do
      if not state.gameVehicleID then
        state.gameVehicleID = MPVehicleGE.getGameVehicleID(sv)
      end

      if state.gameVehicleID then
        state.nextRetryIn = state.nextRetryIn - dtReal
        if state.nextRetryIn <= 0 then
          log('I', 'mpSeatSync', 'retry ' .. tostring(MIRROR_RETRY_COUNT - state.retriesLeft + 1) ..
            '/' .. tostring(MIRROR_RETRY_COUNT) .. ' applying ' .. tostring(state.action) ..
            ' seat ' .. tostring(seatId) .. ' on ' .. tostring(sv))
          local applied = applySeatSyncOp(state.gameVehicleID, seatId, state.action)
          if applied then
            -- It worked - stop here. Without this, a successful attempt
            -- kept getting reapplied every second anyway until the full
            -- 60-retry budget ran out (confirmed in a client log:
            -- "mirroring remote seat FL -> true" repeating every ~1s
            -- for nearly a minute straight on an already-correct seat).
            -- Each reapplication tears down and recreates the seat
            -- occupant mesh, which is what was showing up as the
            -- character flickering/disappearing.
            seats[seatId] = nil
          else
            state.retriesLeft = state.retriesLeft - 1
            state.nextRetryIn = MIRROR_RETRY_INTERVAL
            if state.retriesLeft <= 0 then
              log('W', 'mpSeatSync', 'exhausted all retries for seat ' .. tostring(seatId) .. ' on ' .. tostring(sv) ..
                ' - if it still never showed, the problem is not timing')
              seats[seatId] = nil
            end
          end
        end
      else
        state.age = state.age + dtReal
        if state.age > MIRROR_UNRESOLVED_TIMEOUT then
          log('W', 'mpSeatSync', 'giving up waiting for vehicle ' .. tostring(sv) .. ' to sync, dropping seat ' .. tostring(seatId))
          seats[seatId] = nil
        end
      end
    end
    if next(seats) == nil then
      mirrorRetries[sv] = nil
    end
  end
end

local function onMpSeatDenied(dataStr)
  local ok, data = pcall(jsonDecode, dataStr)
  if not ok or not data or not data.sv then return end
  log('I', 'mpSeatSync', 'our claim on ' .. tostring(data.sv) .. ' seat ' .. tostring(data.seat) ..
    ' was denied (someone else got there first) - vacating')
  lastKnownSeat[data.sv] = nil
  if guestDriveServerVehicleID == data.sv then
    stopGuestDriving()
  end

  -- BeamNG's own click-handling sits us down LOCALLY the instant we click,
  -- before our claim has even reached the server - clicking is what wrote
  -- occupancy[vehId][seat] = {player=0,...} in the first place. By the
  -- time this denial comes back, requestUnseatedPresence alone only moves
  -- our camera/presence back out; it was leaving that raw occupancy
  -- record behind as a REAL (non-dummy) entry forever, which then
  -- permanently blocked setDummyOccupant from ever mirroring anyone
  -- else's claim on that exact seat with "occupied" - found by it showing
  -- up on every retry after a denied claim, never once a vehicle-sync
  -- timing issue. clearOccupied actually removes that record.
  local gameVehicleID = MPVehicleGE and MPVehicleGE.getGameVehicleID and MPVehicleGE.getGameVehicleID(data.sv)
  if gameVehicleID and gameplay_seatOccupants and gameplay_seatOccupants.clearOccupied then
    gameplay_seatOccupants.clearOccupied(gameVehicleID, data.seat)
  end

  if gameplay_seatOccupants and gameplay_seatOccupants.requestUnseatedPresence and be then
    local vehId = be:getPlayerVehicleID(0)
    if vehId and vehId ~= -1 then
      gameplay_seatOccupants.requestUnseatedPresence(0, vehId, "unrestricted")
    end
  end

  guihooks.trigger("Message", {
    msg = "That seat is already taken.",
    ttl = 3,
    category = "mpSeatSync",
    icon = "warning",
  })
end

-- We're the owner: the server says a guest just started/stopped driving
-- our vehicle. Tell our OWN VE controller to accept/stop accepting
-- relayed input.
local function onMpDriveSync(dataStr)
  local ok, data = pcall(jsonDecode, dataStr)
  if not ok or not data or not data.sv then return end
  if not MPVehicleGE or not MPVehicleGE.getGameVehicleID then return end

  local gameVehicleID = MPVehicleGE.getGameVehicleID(data.sv)
  local v = gameVehicleID and veh(gameVehicleID)
  if not v then return end

  if data.action == "enter" then
    log('I', 'mpSeatSync', 'a guest is now driving our vehicle ' .. tostring(data.sv))
    v:queueLuaCommand("if mpSeatSyncVE then mpSeatSyncVE.setRemoteDriverActive(true) end")
  elseif data.action == "exit" then
    log('I', 'mpSeatSync', 'guest stopped driving our vehicle ' .. tostring(data.sv))
    v:queueLuaCommand("if mpSeatSyncVE then mpSeatSyncVE.setRemoteDriverActive(false) end")
  end
end

-- We're the owner: a relayed input sample arrived from whoever's driving.
local function onMpDriveInput(dataStr)
  local ok, data = pcall(jsonDecode, dataStr)
  if not ok or not data or not data.sv or not data.data then return end
  if not MPVehicleGE or not MPVehicleGE.getGameVehicleID then return end

  local gameVehicleID = MPVehicleGE.getGameVehicleID(data.sv)
  local v = gameVehicleID and veh(gameVehicleID)
  if not v then return end

  -- data.data is already a JSON string encoded by the guest's VE
  -- controller; pass it straight through to avoid a decode/re-encode
  -- round trip on every single input change.
  local escaped = data.data:gsub("\\", "\\\\"):gsub("'", "\\'")
  v:queueLuaCommand("if mpSeatSyncVE then mpSeatSyncVE.applyGuestInput('" .. escaped .. "') end")
end

-------------------------------------------------------------------------
-- Registration
-------------------------------------------------------------------------

local function registerHandlers()
  if handlerRegistered then return end
  if type(AddEventHandler) ~= 'function' then return end
  AddEventHandler(SYNC_EVENT, onMpSeatSync, "mpSeatSync")
  AddEventHandler(DENY_EVENT, onMpSeatDenied, "mpSeatSync")
  AddEventHandler(DRIVE_SYNC_EVENT, onMpDriveSync, "mpSeatSync")
  AddEventHandler(DRIVE_INPUT_EVENT, onMpDriveInput, "mpSeatSync")
  handlerRegistered = true
end

-- The spawn-check above and the hook itself both only cover specific
-- moments (right after a spawn, or a real click). Every edge case we've
-- hit so far - auto-seat on spawn, a player who was already seated
-- before we even joined, spawning a car after having none - is really
-- the same underlying gap: there's no single moment that's GUARANTEED to
-- tell us "I am sitting here" for every way a player can end up seated.
-- Rather than keep chasing each new way to miss it one at a time, just
-- periodically ask ourselves the one question that's always true if
-- we're seated at all - "what vehicle does the game say I'm
-- controlling?" - and reconfirm our claim on it IF IT DISAGREES with
-- what we last told the server. This "if it disagrees" check is
-- important, not just an optimization: resending unconditionally every
-- 3 seconds forever (confirmed in a server log - "player 0 took seat
-- FL" / "player 1 took seat FR" repeating nonstop even while parked)
-- meant every connected client was re-running setDummyOccupant on every
-- occupied seat every 3 seconds forever, which is almost certainly what
-- exposed a Fatal Lua Error crash (core engine's isUnicycle() throwing
-- on a transient/invalid vehicle handle - see the pcall wrapper in
-- applySeatSyncOp below, which is the other half of this fix). Checking
-- only on an actual mismatch keeps the self-healing behavior for the
-- cases that matter while leaving an already-correct state alone.
local selfCheckTimer = 0
local SELF_CHECK_INTERVAL = 3

local function periodicSelfSeatCheck(dtReal)
  selfCheckTimer = selfCheckTimer + (dtReal or 0)
  if selfCheckTimer < SELF_CHECK_INTERVAL then return end
  selfCheckTimer = 0

  if not be or not be.getPlayerVehicleID then return end
  if not inBeamMPSession() then return end
  if not MPVehicleGE or not MPVehicleGE.getServerVehicleID then return end

  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId == -1 then return end

  local serverVehicleID = MPVehicleGE.getServerVehicleID(vehId)
  if not serverVehicleID then return end

  local seat = findMySeat(vehId, 0)
  local seatId = seat and seat.seatId or nil

  -- Nothing to reconcile - the server already has what we're actually
  -- sitting in right now, so resending would just be noise.
  if lastKnownSeat[serverVehicleID] == seatId then return end

  if seatId then
    M.onSeatOccupantEnter(0, vehId)
  end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  registerHandlers()
  flushMirrorRetries(dtReal)
  checkPendingSpawnSeats(dtReal)
  periodicSelfSeatCheck(dtReal)
end

function M.onExtensionLoaded()
  registerHandlers()
end

return M
