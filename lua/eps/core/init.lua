EPS = EPS or {}
EPS.Core = EPS.Core or {}

local core = EPS.Core

if SERVER then
    AddCSLuaFile("eps/core/constants.lua")
    AddCSLuaFile("eps/core/util.lua")
end

local constants = include("eps/core/constants.lua")
local util = include("eps/core/util.lua")

core.Constants = constants
core.Util = util

if SERVER then
    EPS._playerLayouts = EPS._playerLayouts or setmetatable({}, { __mode = "k" })
    EPS._panelRefs = EPS._panelRefs or setmetatable({}, { __mode = "k" })
    EPS._damageStates = EPS._damageStates or {}
    EPS._recentPanelByLocation = EPS._recentPanelByLocation or setmetatable({}, { __mode = "v" })
    EPS._lastPanelPerPlayer = EPS._lastPanelPerPlayer or setmetatable({}, { __mode = "kv" })
    EPS._maintenanceLocks = EPS._maintenanceLocks or {}
    EPS._maintenanceScanAttempts = EPS._maintenanceScanAttempts or setmetatable({}, { __mode = "k" })
    EPS._panelTelemetry = EPS._panelTelemetry or setmetatable({}, { __mode = "k" })
end

return core
