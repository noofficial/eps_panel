if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local ServerSetup = {}
local initialized = false

local Modules = include("eps/core/modules.lua")
local Hooks = include("eps/hooks/init_hooks.lua")

local function registerNetworkStrings()
    if not util or not util.AddNetworkString or not EPS.NET then return end
    util.AddNetworkString(EPS.NET.Open)
    util.AddNetworkString(EPS.NET.Update)
    util.AddNetworkString(EPS.NET.FullState)
end

function ServerSetup.Initialize()
    if initialized then return end
    initialized = true

    local modules = Modules.Get()

    registerNetworkStrings()

    Hooks.RegisterAll(modules)
end

return ServerSetup
