-- modScript.lua
--
-- Same fix needed for every GE extension shipped inside a BeamMP mod zip:
-- without this file, lua/ge/extensions/mpSeatSync.lua is mounted into the
-- virtual filesystem but never actually load()-ed. See mpInteract's
-- modScript.lua for the fuller explanation; this is the identical pattern.

load("mpSeatSync")
setExtensionUnloadMode("mpSeatSync", "manual")
