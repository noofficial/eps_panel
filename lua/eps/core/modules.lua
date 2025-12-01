if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Modules = {}
local loaded = false

local function loadOnce()
    if loaded then return end
    Modules.Maintenance = include("eps/systems/maintenance.lua")
    Modules.Access = include("eps/systems/access.lua")
    Modules.State = include("eps/systems/state.lua")
    Modules.Telemetry = include("eps/systems/telemetry.lua")
    Modules.Panels = include("eps/systems/panels.lua")
    Modules.Damage = include("eps/systems/damage.lua")
    Modules.CriticalSystems = include("eps/systems/critical_systems.lua")
    Modules.Deflectors = include("eps/systems/deflectors.lua")
    Modules.Spikes = include("eps/systems/spikes.lua")
    Modules.Interactions = include("eps/systems/interactions.lua")
    Modules.Commands = include("eps/systems/commands.lua")
    Modules.Allocations = include("eps/systems/allocations.lua")
    Modules.Bootstrap = include("eps/systems/bootstrap.lua")
    Modules.RoutingNet = include("eps/net/routing.lua")
    loaded = true
end

function Modules.Get(name)
    loadOnce()
    if name then
        return Modules[name]
    end
    return Modules
end

return Modules
