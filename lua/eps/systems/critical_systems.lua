if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Critical = {}

local function toVector(value)
    if not value then return nil end
    if isvector(value) then
        return Vector(value.x, value.y, value.z)
    end
    if istable(value) then
        local x = tonumber(value.x or value[1] or 0) or 0
        local y = tonumber(value.y or value[2] or 0) or 0
        local z = tonumber(value.z or value[3] or 0) or 0
        return Vector(x, y, z)
    end
    if isstring(value) then
        local x, y, z = string.match(value, "([%-%d%.]+)[,%s]+([%-%d%.]+)[,%s]+([%-%d%.]+)")
        if x and y and z then
            return Vector(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
        end
    end
    return nil
end

local function getSystemConfig(id)
    local cfg = EPS.Config and EPS.Config.CriticalSystems or {}
    return cfg[id] or {}
end

local function resolveFireOffset(id, fallback)
    local cfg = getSystemConfig(id)
    local offset = cfg.fireOffset and toVector(cfg.fireOffset)
    if offset then return offset end
    if fallback then
        return toVector(fallback) or fallback
    end
    return nil
end

local function resolveDamageRate(id, fallback)
    local cfg = getSystemConfig(id)
    local rate = tonumber(cfg.damageRate)
    if rate and rate > 0 then
        return rate
    end
    return fallback or 0.01
end

local function lifeSupportShutdown()
    if not StarTrekEntities or not StarTrekEntities.LifeSupport then return end
    if StarTrekEntities.LifeSupport.Shutdown then
        StarTrekEntities.LifeSupport:Shutdown()
    end
end

local function lifeSupportEnable()
    if not StarTrekEntities or not StarTrekEntities.LifeSupport then return end
    if StarTrekEntities.LifeSupport.Enable then
        StarTrekEntities.LifeSupport:Enable()
    end
end

local function commsShutdown()
    if not StarTrekEntities or not StarTrekEntities.Comms then return end
    if StarTrekEntities.Comms.Shutdown then
        StarTrekEntities.Comms:Shutdown()
    elseif StarTrekEntities.Comms.SetPower then
        StarTrekEntities.Comms:SetPower(false)
    end
end

local function commsEnable()
    if not StarTrekEntities or not StarTrekEntities.Comms then return end
    if StarTrekEntities.Comms.Enable then
        StarTrekEntities.Comms:Enable()
    elseif StarTrekEntities.Comms.SetPower then
        StarTrekEntities.Comms:SetPower(true)
    end
end

local function gravityShutdown()
    if not StarTrekEntities or not StarTrekEntities.Gravity then return end
    if StarTrekEntities.Gravity.Shutdown then
        StarTrekEntities.Gravity:Shutdown()
    end
end

local function gravityEnable()
    if not StarTrekEntities or not StarTrekEntities.Gravity then return end
    if StarTrekEntities.Gravity.Restart then
        StarTrekEntities.Gravity:Restart()
    elseif StarTrekEntities.Gravity.Reset then
        StarTrekEntities.Gravity:Reset()
    end
end

local ControlledSystems = {
    life_support = {
        id = "life_support",
        offThreshold = 0,
        fireOffset = Vector(0, 0, 64),
        damageRate = 0.0125,
        getEntity = function()
            if not StarTrekEntities or not StarTrekEntities.LifeSupport then return nil end
            return StarTrekEntities.LifeSupport:GetCore()
        end,
        getHealth = function(ent)
            if not IsValid(ent) then return 0 end
            if ent.GetLifeSupportHealth then
                return ent:GetLifeSupportHealth()
            end
            return ent:Health()
        end,
        getMaxHealth = function(ent)
            if not IsValid(ent) then return 0 end
            if ent.GetLifeSupportMaxHealth then
                return ent:GetLifeSupportMaxHealth()
            end
            return ent:GetMaxHealth() or 0
        end,
        setHealth = function(ent, value)
            if not IsValid(ent) then return end
            local maxhp = (ent.GetLifeSupportMaxHealth and ent:GetLifeSupportMaxHealth()) or ent:GetMaxHealth() or 0
            local clamped = math.Clamp(math.floor(value or 0), 0, math.max(maxhp, 0))
            if ent.SetCoreHealthValue then
                ent:SetCoreHealthValue(clamped)
            elseif ent.SetLifeSupportHealth then
                ent:SetLifeSupportHealth(clamped)
            else
                ent:SetHealth(clamped)
            end
        end,
        shutdown = lifeSupportShutdown,
        enable = lifeSupportEnable,
    },
    communications = {
        id = "communications",
        offThreshold = 0,
        fireOffset = Vector(0, 0, 42),
        damageRate = 0.02,
        getEntity = function()
            if not StarTrekEntities or not StarTrekEntities.Comms then return nil end
            return StarTrekEntities.Comms:GetRepairEntity()
        end,
        getHealth = function(ent)
            if not IsValid(ent) then return 0 end
            if ent.GetCommsHealth then
                return ent:GetCommsHealth()
            end
            return ent:Health()
        end,
        getMaxHealth = function(ent)
            if not IsValid(ent) then return 0 end
            if ent.GetCommsMaxHealth then
                return ent:GetCommsMaxHealth()
            end
            return ent:GetMaxHealth() or 0
        end,
        setHealth = function(ent, value)
            if not IsValid(ent) then return end
            local maxhp = (ent.GetCommsMaxHealth and ent:GetCommsMaxHealth()) or ent:GetMaxHealth() or 0
            local clamped = math.Clamp(math.floor(value or 0), 0, math.max(maxhp, 0))
            ent.CommsHealth = clamped
            if ent.SetHealth then
                ent:SetHealth(clamped)
            end
            if StarTrekEntities and StarTrekEntities.Comms and StarTrekEntities.Comms.SyncScrambleFromHealth then
                StarTrekEntities.Comms:SyncScrambleFromHealth()
            end
        end,
        shutdown = commsShutdown,
        enable = commsEnable,
    },
    gravity = {
        id = "gravity",
        offThreshold = 0,
        fireOffset = Vector(0, 0, 72),
        damageRate = 0.018,
        getEntity = function()
            if not StarTrekEntities or not StarTrekEntities.Gravity then return nil end
            return StarTrekEntities.Gravity:GetGenerator()
        end,
        getHealth = function(ent)
            if not IsValid(ent) then return 0 end
            if ent.Health then
                return ent:Health()
            end
            return 0
        end,
        getMaxHealth = function(ent)
            if not IsValid(ent) then return 0 end
            if ent.GetMaxHealth then
                return ent:GetMaxHealth()
            end
            return 0
        end,
        setHealth = function(ent, value)
            if not IsValid(ent) or not ent.SetHealth then return end
            local maxhp = (ent.GetMaxHealth and ent:GetMaxHealth()) or 0
            local clamped = math.Clamp(math.floor(value or 0), 0, math.max(maxhp, 0))
            ent:SetHealth(clamped)
        end,
        shutdown = gravityShutdown,
        enable = gravityEnable,
    },
}

local systemState = {}

local function getState(id)
    local state = systemState[id]
    if not state then
        state = { powered = nil, fires = {} }
        systemState[id] = state
    end
    return state
end

local function ensurePowerState(id, allocations)
    local control = ControlledSystems[id]
    if not control then return end
    local value = math.max(0, (allocations and allocations[id]) or 0)
    local threshold = control.offThreshold or 0
    local shouldBeOnline = value > threshold
    local state = getState(id)
    if shouldBeOnline then
        if state.powered ~= true then
            state.powered = true
            if control.enable then
                control.enable()
            end
        end
    else
        if state.powered ~= false then
            state.powered = false
            if control.shutdown then
                control.shutdown()
            end
        end
    end
end

local function applyOverloadDamage(id, severity)
    local control = ControlledSystems[id]
    if not control or not control.getEntity then return end
    local ent = control.getEntity()
    if not IsValid(ent) then return end
    local getHealth = control.getHealth
    local getMaxHealth = control.getMaxHealth
    if not getHealth or not getMaxHealth then return end
    local maxhp = math.max(getMaxHealth(ent) or 0, 0)
    if maxhp <= 0 then
        maxhp = 100
    end
    local current = math.max(getHealth(ent) or maxhp, 0)
    if current <= 0 then return end
    local rate = resolveDamageRate(id, control.damageRate)
    if rate <= 0 then return end
    local scaledSeverity = math.max(severity or 0, 0.2)
    local delta = math.max(1, math.floor(maxhp * rate * scaledSeverity))
    if delta <= 0 then return end
    local newValue = math.max(0, current - delta)
    if control.setHealth then
        control.setHealth(ent, newValue)
    end
end

local function spawnFireForState(id, damageState)
    local control = ControlledSystems[id]
    if not control or not control.getEntity then return end
    local ent = control.getEntity()
    if not IsValid(ent) then return end
    local state = getState(id)
    state.fires = state.fires or {}
    local key = (damageState and damageState.key) or id
    if IsValid(state.fires[key]) then return end

    local offset = resolveFireOffset(id, control.fireOffset)
    local pos
    if offset then
        pos = ent:LocalToWorld(offset)
    else
        pos = ent:WorldSpaceCenter()
    end

    local fire = ents.Create("env_fire")
    if not IsValid(fire) then return end
    fire:SetPos(pos)
    fire:SetKeyValue("spawnflags", "128")
    fire:SetKeyValue("firesize", "56")
    fire:SetKeyValue("fireattack", "4")
    fire:SetKeyValue("health", "999")
    fire:SetKeyValue("damagescale", "1")
    fire:SetParent(ent)
    fire:Spawn()
    fire:Activate()
    fire:Fire("StartFire", "", 0)

    state.fires[key] = fire
    fire:CallOnRemove("EPS_CriticalSystemFireCleanup", function()
        local active = systemState[id]
        if active and active.fires then
            active.fires[key] = nil
        end
    end)
end

local function extinguishFire(id, damageState)
    local state = systemState[id]
    if not state or not state.fires then return end
    local key = (damageState and damageState.key) or id
    local fire = state.fires[key]
    if IsValid(fire) then
        fire:Fire("Extinguish", "", 0)
        fire:Remove()
    end
    state.fires[key] = nil
end

function Critical.HandlePowerChanged(allocations)
    for id in pairs(ControlledSystems) do
        ensurePowerState(id, allocations)
    end
end

function Critical.HandleIgnite(state)
    if not state or not state.id then return end
    if not ControlledSystems[state.id] then return end
    spawnFireForState(state.id, state)
end

function Critical.HandleRepair(state)
    if not state or not state.id then return end
    if not ControlledSystems[state.id] then return end
    extinguishFire(state.id, state)
end

function Critical.HandleSpark(state, panel, severity)
    if not state or not state.id then return end
    if not ControlledSystems[state.id] then return end
    applyOverloadDamage(state.id, severity or state.lockedSeverity or state.severity or 0)
end

local function setupHooks()
    if Critical._setup then return end
    Critical._setup = true

    hook.Add("EPS_PowerChanged", "EPS_CriticalSystems_Power", function(allocations)
        Critical.HandlePowerChanged(allocations)
    end)

    hook.Add("EPS_SubsystemDamageIgnite", "EPS_CriticalSystems_Fire", function(state, panel, severity)
        Critical.HandleIgnite(state)
    end)

    hook.Add("EPS_SubsystemDamageRepaired", "EPS_CriticalSystems_Repair", function(state)
        Critical.HandleRepair(state)
    end)

    hook.Add("EPS_SubsystemDamageSpark", "EPS_CriticalSystems_Damage", function(state, panel, severity)
        Critical.HandleSpark(state, panel, severity)
    end)
end

setupHooks()

return Critical
