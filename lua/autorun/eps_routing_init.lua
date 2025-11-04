if SERVER then
AddCSLuaFile("eps_routing/config.lua")
AddCSLuaFile("eps_routing/sh_state.lua")
AddCSLuaFile("autorun/client/eps_routing_cl.lua")
end


include("eps_routing/config.lua")
include("eps_routing/sh_state.lua")


if SERVER then
include("autorun/server/eps_routing_sv.lua")
else
include("autorun/client/eps_routing_cl.lua")
end