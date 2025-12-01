EPS = EPS or {}

include("eps/core/init.lua")

local Panels = include("eps/systems/panels.lua")
local Maintenance = include("eps/systems/maintenance.lua")

local Util = EPS.Util or {}
local CONST = EPS.Constants or {}

local Damage = {}

local normalizeLocKey = Util.NormalizeLocKey or function(locKey)
    if not locKey or locKey == "" then return "global" end
    return string.lower(locKey)
end

local rememberPanelForLocation = Panels.RememberPanelForLocation
local collectPanelInfos = Panels.CollectPanelInfos
local panelSupportsSubsystem = Panels.PanelSupportsSubsystem

local getMaintenanceState = Maintenance.GetState
local setMaintenanceState = Maintenance.SetState
local isOverrideActive = Maintenance.IsOverrideActive

local OVERPOWER_THRESHOLD = CONST.OVERPOWER_THRESHOLD or 0.25
local OVERPOWER_DAMAGE_DELAY_MIN = CONST.OVERPOWER_DAMAGE_DELAY_MIN or 40
local OVERPOWER_DAMAGE_DELAY_MAX = CONST.OVERPOWER_DAMAGE_DELAY_MAX or 240
local DAMAGE_SPARK_INTERVAL_MIN = CONST.DAMAGE_SPARK_INTERVAL_MIN or 0.8
local DAMAGE_SPARK_INTERVAL_MAX = CONST.DAMAGE_SPARK_INTERVAL_MAX or 4.0
local DAMAGE_REPAIR_TIME = CONST.DAMAGE_REPAIR_TIME or 5
local DAMAGE_FIRE_DELAY_MIN = CONST.DAMAGE_FIRE_DELAY_MIN or 25
local DAMAGE_FIRE_DELAY_MAX = CONST.DAMAGE_FIRE_DELAY_MAX or 120
local DAMAGE_RESPAWN_ACCEL = CONST.DAMAGE_RESPAWN_ACCEL or 0.6
local DAMAGE_RESPAWN_MIN_MULT = CONST.DAMAGE_RESPAWN_MIN_MULT or 0.1
local DAMAGE_RESPAWN_MIN_DELAY = CONST.DAMAGE_RESPAWN_MIN_DELAY or 5
local MAINTENANCE_OVERRIDE_DAMAGE_MULT = CONST.MAINTENANCE_OVERRIDE_DAMAGE_MULT or 0.5
local DAMAGE_SHAKE_MAX_DURATION = CONST.DAMAGE_SHAKE_MAX_DURATION or 10
local DAMAGE_RUMBLE_START_DELAY = CONST.DAMAGE_RUMBLE_START_DELAY or 1.25
local DAMAGE_RUMBLE_INTERVAL_MIN = CONST.DAMAGE_RUMBLE_INTERVAL_MIN or 0.8
local DAMAGE_RUMBLE_INTERVAL_MAX = CONST.DAMAGE_RUMBLE_INTERVAL_MAX or 3.5
local DAMAGE_EXPLOSION_DURATION = CONST.DAMAGE_EXPLOSION_DURATION or 0.35

local function toVector(value)
    if not value then return nil end
    if isvector(value) then return value end
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

local function evaluateShakeSpec(spec, severity, fallback)
    if spec == nil then return fallback end
    if istable(spec) then
        local minVal = spec.min or spec.low or spec[1] or spec.base or fallback or 0
        local maxVal = spec.max or spec.high or spec[2] or minVal
        return Lerp(severity, minVal, maxVal)
    end
    if isnumber(spec) then
        return spec
    end
    return fallback
end

local function resolveShakeOrigin(panel, cfg)
    if cfg then
        if cfg.origin then
            local absolute = toVector(cfg.origin)
            if absolute then
                return absolute
            end
        end
        if cfg.originOffset and IsValid(panel) then
            local offset = toVector(cfg.originOffset)
            if offset then
                return panel:LocalToWorld(offset)
            end
        end
    end
    if IsValid(panel) then
        return panel:GetPos()
    end
end

local function applyDamageShake(subId, panel, severity, overrides)
    if not util or not util.ScreenShake then return end
    local shakeCfg = EPS.Config and EPS.Config.DamageShake
    overrides = overrides or {}
    local cfg = shakeCfg and (shakeCfg[subId] or shakeCfg._default)
    if not cfg and not overrides then return end
    cfg = cfg or {}

    local origin = resolveShakeOrigin(panel, cfg)
    if not origin then return end

    local t = math.Clamp(severity or 0, 0, 1)
    local amplitude = overrides.amplitude or evaluateShakeSpec(cfg.amplitude, t, overrides.defaultAmplitude or 0.3)
    local frequency = overrides.frequency or evaluateShakeSpec(cfg.frequency, t, overrides.defaultFrequency or 0.3)
    local duration = overrides.duration or evaluateShakeSpec(cfg.duration, t, overrides.defaultDuration or 1.5)
    duration = math.min(duration, overrides.maxDuration or DAMAGE_SHAKE_MAX_DURATION)
    local radius = overrides.radius or evaluateShakeSpec(cfg.radius, t, overrides.defaultRadius or 700)

    if amplitude <= 0 or duration <= 0 or radius <= 0 then return end

    util.ScreenShake(origin, amplitude, frequency, duration, radius)
end

local function scheduleNextRumble(state, severity)
    if not state then return end
    local scaled = math.Clamp(severity or 0, 0, 1)
    local delay = Lerp(scaled, DAMAGE_RUMBLE_INTERVAL_MAX, DAMAGE_RUMBLE_INTERVAL_MIN)
    state.nextRumble = CurTime() + delay
end

local function triggerDamageExplosion(state)
    if not state then return end
    applyDamageShake(state.id, state.panel, 1, {
        amplitude = 1.5,
        frequency = 1.5,
        duration = DAMAGE_EXPLOSION_DURATION,
        maxDuration = DAMAGE_EXPLOSION_DURATION,
    })
end

local function triggerDamageRumble(state)
    if not state then return end
    local panel = state.panel
    if not IsValid(panel) then return end
    local now = CurTime()
    local elapsed = now - (state.started or now)
    local ramp = math.Clamp(elapsed / DAMAGE_SHAKE_MAX_DURATION, 0, 1)
    local liveSeverity = math.Clamp(state.liveSeverity or state.severity or 0, 0, 1)
    local severity = math.Clamp(math.max(liveSeverity, ramp), 0, 1)
    applyDamageShake(state.id, panel, severity, { maxDuration = DAMAGE_SHAKE_MAX_DURATION })
    scheduleNextRumble(state, severity)
end

local function ensureState()
    EPS._damageStates = EPS._damageStates or {}
    EPS._overpowerWatch = EPS._overpowerWatch or {}
end

local function hasActivePanels()
    if not EPS._panelRefs then return false end
    for panel in pairs(EPS._panelRefs) do
        if IsValid(panel) then
            return true
        end
    end
    return false
end

local function makeDamageKey(locKey, subId)
    return string.format("%s::%s", normalizeLocKey(locKey), subId or "unknown")
end

local function pickPanelEntityForSubsystem(subsystemId, targetLocKey)
    local normalizedTarget = targetLocKey and string.lower(targetLocKey) or nil
    local preferredKey = normalizedTarget or "global"
    local recent = EPS._recentPanelByLocation and EPS._recentPanelByLocation[preferredKey]
    if IsValid(recent) then
        local info = EPS._panelRefs and EPS._panelRefs[recent]
        if info and panelSupportsSubsystem(info, subsystemId) then
            return recent
        elseif EPS._recentPanelByLocation then
            EPS._recentPanelByLocation[preferredKey] = nil
        end
    end

    local infos = collectPanelInfos(targetLocKey)
    if #infos == 0 then return nil end

    local matches = {}
    for _, info in ipairs(infos) do
        if panelSupportsSubsystem(info, subsystemId) and IsValid(info.entity) then
            matches[#matches + 1] = info.entity
        end
    end

    if #matches == 0 then return nil end
    return matches[math.random(#matches)]
end

local function cleanupDamageEffects(state)
    if not state then return end
    if IsValid(state.fireEnt) then
        state.fireEnt:Fire("Extinguish", "", 0)
        state.fireEnt:Remove()
    end
    state.fireEnt = nil
    state.fireSpawned = false
    local panel = state and state.panel
    hook.Run("EPS_SubsystemDamageExtinguished", state, IsValid(panel) and panel or nil)
end

local function spawnDamageFire(state)
    if not state or state.fireSpawned then return end
    local panel = state.panel
    if not IsValid(panel) then return end

    local fire = ents.Create("env_fire")
    if not IsValid(fire) then return end
    local offset = panel.GetFireOffset and panel:GetFireOffset() or (panel.GetSparkOffset and panel:GetSparkOffset()) or Vector(0, 0, 26)
    fire:SetPos(panel:LocalToWorld(offset))
    fire:SetKeyValue("spawnflags", "128")
    fire:SetKeyValue("firesize", "64")
    fire:SetKeyValue("fireattack", "4")
    fire:SetKeyValue("health", "999")
    fire:SetKeyValue("damagescale", "2")
    fire:SetParent(panel)
    fire:Spawn()
    fire:Activate()
    fire:Fire("StartFire", "", 0)

    state.fireSpawned = true
    state.fireEnt = fire
    hook.Run("EPS_SubsystemDamageIgnite", state, panel, fire)
end

local function startSubsystemDamage(locKey, subId, severity)
    ensureState()

    local damageKey = makeDamageKey(locKey, subId)
    if EPS._damageStates[damageKey] then return EPS._damageStates[damageKey] end

    local panel = pickPanelEntityForSubsystem(subId, locKey)
    if not IsValid(panel) then return nil end
    rememberPanelForLocation(panel, locKey)

    local now = CurTime()
    local clampedSeverity = math.Clamp(severity or 0, 0, 1)
    local state = {
        id = subId,
        key = damageKey,
        locKey = normalizeLocKey(locKey),
        panel = panel,
        started = now,
        lastSpark = 0,
        progress = 0,
        repairTime = DAMAGE_REPAIR_TIME,
        fireSpawned = false,
        severity = clampedSeverity,
        lockedSeverity = clampedSeverity,
    }

    EPS._damageStates[damageKey] = state

    panel._epsDamage = panel._epsDamage or {}
    panel._epsDamage[damageKey] = state

    panel:TriggerOverpowerSparks()
    hook.Run("EPS_SubsystemDamageSpark", state, panel, clampedSeverity)
    panel:EmitSound("ambient/energy/zap1.wav", 70, 100, 0.65)

    hook.Run("EPS_SubsystemDamageStarted", state, panel, clampedSeverity)

    triggerDamageExplosion(state)
    state.nextRumble = now + DAMAGE_RUMBLE_START_DELAY
    return state
end

local function completeDamageRepair(state, repairedBy, opts)
    ensureState()
    if not state or state.repaired then return end
    opts = opts or {}
    state.repaired = true
    cleanupDamageEffects(state)

    local panel = state.panel
    if IsValid(panel) and panel._epsDamage then
        panel._epsDamage[state.key] = nil
        if next(panel._epsDamage) == nil then
            panel._epsDamage = nil
        end
        if not opts.silent then
            panel:EmitSound("buttons/button19.wav", 65, 110, 0.6)
        end
    end

    EPS._damageStates[state.key] = nil

    local watch = EPS._overpowerWatch and EPS._overpowerWatch[state.key]
    if watch then
        watch.since = 0
        local currentMult = watch.respawnMultiplier or 1
        local nextMult = math.max(currentMult * DAMAGE_RESPAWN_ACCEL, DAMAGE_RESPAWN_MIN_MULT)
        watch.respawnMultiplier = nextMult
    end

    state.nextRumble = nil
    hook.Run("EPS_SubsystemDamageRepaired", state, panel, repairedBy, opts)
end

local function computeSeverityFromRatio(ratio)
    ratio = math.Clamp(ratio or 0, 0, 1)
    if ratio <= OVERPOWER_THRESHOLD then return 0 end
    local span = 1 - OVERPOWER_THRESHOLD
    if span <= 0 then return 1 end
    return math.Clamp((ratio - OVERPOWER_THRESHOLD) / span, 0, 1)
end

local function severityLerp(severity, minValue, maxValue)
    severity = math.Clamp(severity or 0, 0, 1)
    return Lerp(severity, maxValue, minValue)
end

local function processOverpower()
    ensureState()
    if not EPS.State or not EPS.State.locations then return end
    if not hasActivePanels() then return end

    local now = CurTime()
    local dt = FrameTime()

    for locKey, state in pairs(EPS.State.locations or {}) do
        local normalizedLoc = normalizeLocKey(locKey)
        local maintenanceRecord = getMaintenanceState(normalizedLoc)
        local overrideActive = isOverrideActive(maintenanceRecord)
        if overrideActive and maintenanceRecord then
            maintenanceRecord.overridePowerActive = false
        end

        for subId, alloc in pairs(state.allocations or {}) do
            local demand = EPS.GetDemand(normalizedLoc, subId) or 0
            local overdrive = EPS.GetSubsystemOverdrive and EPS.GetSubsystemOverdrive(subId) or demand
            local extraCap = math.max(overdrive - demand, 0)
            local extraAlloc = math.max(alloc - demand, 0)
            local ratio = extraCap > 0 and (extraAlloc / extraCap) or 0
            local severity = computeSeverityFromRatio(ratio)
            local forcedOverrideDamage = overrideActive and (alloc or 0) > 0

            if overrideActive and maintenanceRecord and (alloc or 0) > 0 then
                maintenanceRecord.overridePowerActive = true
                maintenanceRecord.overridePowered = true
            end

            if forcedOverrideDamage then
                severity = 1
            end

            local watchKey = makeDamageKey(normalizedLoc, subId)
            local entry = EPS._overpowerWatch[watchKey]
            if not entry then
                entry = { since = 0 }
                EPS._overpowerWatch[watchKey] = entry
            end
            entry.since = entry.since or 0
            entry.severity = severity
            entry.respawnMultiplier = entry.respawnMultiplier or 1
            local baseDelay = severityLerp(severity, OVERPOWER_DAMAGE_DELAY_MIN, OVERPOWER_DAMAGE_DELAY_MAX)
            local delayMultiplier = forcedOverrideDamage and MAINTENANCE_OVERRIDE_DAMAGE_MULT or 1
            entry.baseDelay = baseDelay
            local scaledDelay = math.max(baseDelay * (entry.respawnMultiplier or 1) * delayMultiplier, DAMAGE_RESPAWN_MIN_DELAY * delayMultiplier)
            entry.delay = scaledDelay

            local damageState = EPS._damageStates[watchKey]
            if damageState then
                damageState.liveSeverity = severity
                if forcedOverrideDamage then
                    damageState.lockedSeverity = math.max(damageState.lockedSeverity or 0, 1)
                end
            end

            if not damageState then
                if ratio >= OVERPOWER_THRESHOLD or forcedOverrideDamage then
                    if entry.since == 0 then
                        entry.since = now
                    end
                    if now - entry.since >= (entry.delay or OVERPOWER_DAMAGE_DELAY_MAX) then
                        local newState = startSubsystemDamage(normalizedLoc, subId, severity)
                        if forcedOverrideDamage and newState then
                            newState.lockedSeverity = 1
                        end
                        entry.since = now
                    end
                else
                    entry.since = 0
                    entry.respawnMultiplier = 1
                end
            else
                entry.since = now
            end
        end

        if maintenanceRecord and maintenanceRecord.active then
            setMaintenanceState(normalizedLoc, maintenanceRecord, maintenanceRecord.panel)
        end
    end

    for key, state in pairs(EPS._damageStates) do
        if not state or state.repaired then
            EPS._damageStates[key] = nil
        else
            local panel = state.panel
            if not IsValid(panel) then
                completeDamageRepair(state, nil, { silent = true })
            else
                local severity = math.Clamp(state.lockedSeverity or state.severity or 0, 0, 1)
                local sparkInterval = severityLerp(severity, DAMAGE_SPARK_INTERVAL_MIN, DAMAGE_SPARK_INTERVAL_MAX)
                if now >= (state.lastSpark or 0) + sparkInterval then
                    panel:TriggerOverpowerSparks()
                    hook.Run("EPS_SubsystemDamageSpark", state, panel, severity)
                    state.lastSpark = now
                end

                local fireDelay = severityLerp(severity, DAMAGE_FIRE_DELAY_MIN, DAMAGE_FIRE_DELAY_MAX)
                if not state.fireSpawned and now - state.started >= fireDelay then
                    spawnDamageFire(state)
                end

                if state.progress and state.progress > 0 then
                    local last = state.lastRepair or 0
                    if now - last > 0.4 then
                        state.progress = math.max(0, state.progress - dt * 2)
                    end
                end

                if state.nextRumble and now >= state.nextRumble then
                    triggerDamageRumble(state)
                end
            end
        end
    end
end

hook.Add("Think", "EPS_OverpowerSparkLoop", processOverpower)

function Damage.StartSubsystemDamage(locKey, subId, severity)
    return startSubsystemDamage(locKey, subId, severity)
end

function Damage.CompleteDamageRepair(state, repairedBy, opts)
    return completeDamageRepair(state, repairedBy, opts)
end

function Damage.MakeDamageKey(locKey, subId)
    return makeDamageKey(locKey, subId)
end

EPS._CompleteDamageRepair = completeDamageRepair
EPS.StartSubsystemDamage = Damage.StartSubsystemDamage

return Damage
