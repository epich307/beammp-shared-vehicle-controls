-- mpSeatSyncVE.lua
--
-- Vehicle-side (VE) half of mpSeatSync's driving-control feature. Loaded
-- into EVERY vehicle (see mpSeatSync.lua's onVehicleSpawned, which queues
-- extensions.loadModulesInDirectory on this same folder - identical to how
-- BeamMP loads its own lua/vehicle/extensions/BeamMP folder).
--
-- Two roles, never both at once for the same vehicle on the same client:
--
--   GUEST  (this vehicle is someone else's, v.mpVehicleType == 'R', and we
--           just sat in its driver's seat): every tick, read our own real,
--           intended input from input.lastInputs["local"] - this keeps
--           reflecting what we're actually pressing even though BeamMP has
--           disabled the "local" source for this foreign vehicle to stop
--           us from fighting the real owner's broadcast state (confirmed
--           in lua/vehicle/input.lua: input.event() records into
--           lastInputs[source] unconditionally, before the allowed-source
--           check). We send changed values up to the GE side, which
--           relays them to the real owner.
--
--   OWNER  (this is our own vehicle, v.mpVehicleType == 'L', and the GE
--           side just told us a guest is driving it): disable our own
--           local input source the same way BeamMP disables it for
--           cosmetic remote vehicles, and instead feed the relayed values
--           in via input.event(..., source="mpSeatSync") every time one
--           arrives - this really drives the car, because we're the one
--           client actually simulating its physics.

local M = {}

local INPUTS = {"steering", "throttle", "brake", "clutch", "parkingbrake"}
local SHORT = {steering = "s", throttle = "t", brake = "b", clutch = "c", parkingbrake = "p"}
local LONG = {s = "steering", t = "throttle", b = "brake", c = "clutch", p = "parkingbrake"}
local INPUT_SOURCE = "mpSeatSync"

local guestDriving = false
local remoteDriverActive = false

local lastSent = {}
local lastSentGear
local gearSyncTimer = 0

-------------------------------------------------------------------------
-- Gear shifting, adapted from BeamMP's own MPInputsVE.lua applyGear() -
-- that's a tested, working reference for "set this vehicle's gearbox to
-- gear X regardless of gearbox type", just pointed the other direction.
-------------------------------------------------------------------------

local translationTable = {["R"] = -1, ["N"] = 0, ["P"] = 1, ["D"] = 2, ["S"] = 3, ["2"] = 4, ["1"] = 5, ["M"] = 6}
local gearBoxHandler = {
  ["manualGearbox"] = 1, ["sequentialGearbox"] = 1,
  ["dctGearbox"] = 2, ["cvtGearbox"] = 2, ["automaticGearbox"] = 2, ["electricMotor"] = 2,
}

local function applyGear(data)
  if not electrics.values.gearIndex or electrics.values.gear == data then return end
  local powertrainDevice = powertrain.getDevice("gearbox") or powertrain.getDevice("frontMotor")
    or powertrain.getDevice("rearMotor") or powertrain.getDevice("mainMotor")
  if not powertrainDevice then return end

  if gearBoxHandler[powertrainDevice.type] == 1 then
    local index = tonumber(data)
    if index then powertrainDevice:setGearIndex(index) end
  elseif gearBoxHandler[powertrainDevice.type] == 2 then
    if electrics.values.isShifting then return end
    local remoteGearMode = string.sub(data, 1, 1)
    local localGearMode = string.sub(electrics.values.gear, 1, 1)
    local remoteIndex = tonumber(string.sub(data, 2))
    if remoteGearMode == 'M' and localGearMode == 'M' and remoteIndex then
      if electrics.values.gearIndex < remoteIndex then
        controller.mainController.shiftUpOnDown()
      elseif electrics.values.gearIndex > remoteIndex then
        controller.mainController.shiftDownOnDown()
      end
    elseif translationTable[remoteGearMode] then
      controller.mainController.shiftToGearIndex(translationTable[remoteGearMode])
    end
  end
end

-------------------------------------------------------------------------
-- Guest role
-------------------------------------------------------------------------

function M.setGuestDriving(active)
  guestDriving = active
  lastSent = {}
  lastSentGear = nil
end

local function sampleAndSendGuestInput()
  local changed = {}
  local any = false
  local sources = input.lastInputs and input.lastInputs["local"]
  if sources then
    for _, name in ipairs(INPUTS) do
      local val = sources[name]
      if val ~= nil then
        val = math.floor(val * 10000 + 0.5) / 10000
        if lastSent[name] ~= val then
          lastSent[name] = val
          changed[SHORT[name]] = val
          any = true
        end
      end
    end
  end

  -- Best-effort gear relay: a gear-shift keypress is dispatched straight
  -- into our local copy of this (foreign) vehicle's gearbox before any
  -- network correction overwrites it, so electrics.values.gear briefly
  -- reflects our real intent right after we press it - same polling
  -- technique BeamMP's own code uses, just read in the opposite direction.
  gearSyncTimer = gearSyncTimer + 1
  if electrics.values.gear and electrics.values.gear ~= lastSentGear then
    lastSentGear = electrics.values.gear
    changed.g = lastSentGear
    any = true
  end

  if not any then return end
  local ok, encoded = pcall(jsonEncode, changed)
  if not ok then return end
  obj:queueGameEngineLua("mpSeatSync.onGuestInputSample(" .. obj:getID() .. ", '" .. encoded .. "')")
end

-------------------------------------------------------------------------
-- Owner role
-------------------------------------------------------------------------

function M.setRemoteDriverActive(active)
  remoteDriverActive = active
  for _, name in ipairs(INPUTS) do
    input.setAllowedInputSource(name, "local", not active)
    input.setAllowedInputSource(name, INPUT_SOURCE, true)
  end
  if not active then
    -- Hand control back cleanly instead of leaving throttle/brake stuck.
    for _, name in ipairs(INPUTS) do
      input.event(name, 0, FILTER_DIRECT, nil, nil, nil, INPUT_SOURCE)
    end
  end
end

function M.applyGuestInput(dataStr)
  local ok, data = pcall(jsonDecode, dataStr)
  if not ok or not data then return end
  for shortName, value in pairs(data) do
    if shortName == "g" then
      applyGear(value)
    else
      local longName = LONG[shortName]
      if longName then
        input.event(longName, tonumber(value) or 0, FILTER_DIRECT, nil, nil, nil, INPUT_SOURCE)
      end
    end
  end
end

-------------------------------------------------------------------------

function M.updateGFX(dt)
  if guestDriving then
    sampleAndSendGuestInput()
  end
end

function M.onReset()
  lastSent = {}
  lastSentGear = nil
  if remoteDriverActive then
    M.setRemoteDriverActive(false)
  end
end

return M
