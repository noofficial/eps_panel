EPS = EPS or {}
EPS.Constants = EPS.Constants or {}

local CONST = EPS.Constants

-- Routing overload thresholds
CONST.OVERPOWER_THRESHOLD = 0.25       -- fraction of extra headroom before the panel starts taking damage
CONST.OVERPOWER_DAMAGE_DELAY_MIN = 40  -- fastest seconds above threshold before damage kicks in (worst overload)
CONST.OVERPOWER_DAMAGE_DELAY_MAX = 240 -- slowest seconds above threshold before damage kicks in (light overload)

-- Damage cadence & recovery
CONST.DAMAGE_SPARK_INTERVAL_MIN = 0.8  -- seconds between sparks when the subsystem is pegged at max
CONST.DAMAGE_SPARK_INTERVAL_MAX = 4.0  -- seconds between sparks when the overload is barely above threshold
CONST.DAMAGE_REPAIR_TIME = 5           -- cumulative seconds of sonic-driver contact to clear damage
CONST.DAMAGE_FIRE_DELAY_MIN = 25       -- shortest delay before the console ignites (after damage onset)
CONST.DAMAGE_FIRE_DELAY_MAX = 120      -- longest delay before ignition when overload is mild
CONST.DAMAGE_RESPAWN_ACCEL = 0.6       -- multiplier applied to respawn delay after each repair while overload persists
CONST.DAMAGE_RESPAWN_MIN_MULT = 0.1    -- never let the respawn delay drop below 10% of the base severity delay
CONST.DAMAGE_RESPAWN_MIN_DELAY = 5     -- absolute seconds floor so sparks never respawn instantly

-- Maintenance windows & scanner tuning
CONST.MAINTENANCE_LOCK_DURATION = 600  -- seconds before an unattended maintenance lock naturally expires
CONST.ODN_SCAN_RANGE = 160             -- hammerhead scanner interaction range in Hammer units
CONST.MAINTENANCE_SCAN_TIME = 15       -- seconds the ODN scanner must dwell before the flush triggers
CONST.MAINTENANCE_SCAN_INTERVAL = 0.1  -- polling interval while confirming the ODN scan
CONST.MAINTENANCE_AIM_TOLERANCE = 8    -- distance tolerance (Hammer units) when re-confirming the aimed panel
CONST.REENERGIZE_REQUIRED_TIME = 10    -- seconds of hyperspanner contact to bring the conduit back online
CONST.REENERGIZE_STEP = 0.25           -- progress gain per hyperspanner pulse
CONST.REENERGIZE_DECAY = 1.0           -- seconds before unattended progress falls back to zero
CONST.MAINTENANCE_OVERRIDE_HOLD_TIME = 10      -- seconds to hold secondary fire to bypass safety interlocks
CONST.MAINTENANCE_OVERRIDE_DAMAGE_MULT = 0.5    -- multiplier for damage delays while override is active and powered
CONST.SONIC_RESET_REQUIRED_TIME = 10   -- seconds of sonic-driver contact to re-engage safety protocols
CONST.SONIC_RESET_DECAY = 1.0          -- seconds before unattended reset progress collapses

return CONST
