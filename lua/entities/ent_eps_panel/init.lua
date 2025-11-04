AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

-- Same wall prop we used on the old console. Swap it if you have something prettier.
local DEFAULT_MODEL = "models/props/engineering/engineering_wallprop_01.mdl"
local USE_COOLDOWN = 1.0 -- seconds between legit uses; keeps the spam-clickers honest

function ENT:Initialize()
    self:SetModel(self.ModelOverride or DEFAULT_MODEL)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end

    self:SetUseType(SIMPLE_USE)
    self._nextUse = 0 -- remember the last E press so we can throttle a bit
    -- Tie this panel into the shared EPS pool as soon as it spins up.
    if EPS and EPS.RegisterPanel then
        EPS.RegisterPanel(self)
    end
end

function ENT:Use(activator, caller)
    if (self._nextUse or 0) > CurTime() then return end
    self._nextUse = CurTime() + USE_COOLDOWN
    if not IsValid(activator) or not activator:IsPlayer() then return end

    -- Ask the routing addon for a fresh state push. If it isn't loaded yet, no big deal.
    if EPS and EPS.BroadcastState then
        EPS.BroadcastState(activator)
    end

    -- Fire the same console command players type manually. Nice and predictable.
    if activator.SendLua then
        activator:SendLua("RunConsoleCommand('eps_open')")
    else
        activator:ConCommand("eps_open\n")
    end

    activator:EmitSound("buttons/button14.wav", 60, 100) -- little bit of feedback so folks know it worked
end

function ENT:OnRemove()
    -- Drop our handle so stale panels don't hang onto the power tally.
    if EPS and EPS.UnregisterPanel then
        EPS.UnregisterPanel(self)
    end
end

-- Let duplicator/advdupe2 snapshot this without extra wiring.
duplicator.RegisterEntityClass("ent_eps_panel", function(ply, data)
    local ent = ents.Create("ent_eps_panel")
    if not IsValid(ent) then return end
    ent:SetPos(data.Pos)
    ent:SetAngles(data.Angle)
    ent:Spawn()
    ent:Activate()
    return ent
end, {"Pos","Angle"})
