EPS = EPS or {}

include("eps/core/init.lua")

local Util = EPS.Util or {}

local Maintenance = {}

local enterMaintenance
local exitMaintenance

-- Localize constants (fall back to hard-coded defaults if EPS.Constants isn't available)
local CONST = EPS.Constants or {}
local function constNumber(value, fallback)
    local numeric = tonumber(value)
    if numeric == nil then
        return fallback
    end
    return numeric
end

local ODN_SCAN_RANGE = constNumber(CONST.ODN_SCAN_RANGE, 160)
local MAINTENANCE_SCAN_TIME = constNumber(CONST.MAINTENANCE_SCAN_TIME, 15)
local MAINTENANCE_SCAN_INTERVAL = constNumber(CONST.MAINTENANCE_SCAN_INTERVAL, 0.1)
local MAINTENANCE_AIM_TOLERANCE = constNumber(CONST.MAINTENANCE_AIM_TOLERANCE, 8)
local MAINTENANCE_OVERRIDE_HOLD_TIME = constNumber(CONST.MAINTENANCE_OVERRIDE_HOLD_TIME, 10)
local SONIC_RESET_REQUIRED_TIME = constNumber(CONST.SONIC_RESET_REQUIRED_TIME, 10)
local SONIC_RESET_DECAY = constNumber(CONST.SONIC_RESET_DECAY, 1.0)
local REENERGIZE_REQUIRED_TIME = constNumber(CONST.REENERGIZE_REQUIRED_TIME, 10)
local REENERGIZE_STEP = constNumber(CONST.REENERGIZE_STEP, 0.25)
local REENERGIZE_DECAY = constNumber(CONST.REENERGIZE_DECAY, 1.0)
local MAINTENANCE_LOCK_DURATION = constNumber(CONST.MAINTENANCE_LOCK_DURATION, 600)

if MAINTENANCE_SCAN_INTERVAL <= 0 then MAINTENANCE_SCAN_INTERVAL = 0.1 end
if MAINTENANCE_OVERRIDE_HOLD_TIME <= 0 then MAINTENANCE_OVERRIDE_HOLD_TIME = 10 end
if SONIC_RESET_DECAY <= 0 then SONIC_RESET_DECAY = 1.0 end
if REENERGIZE_STEP <= 0 then REENERGIZE_STEP = 0.25 end
if REENERGIZE_DECAY <= 0 then REENERGIZE_DECAY = 1.0 end
if MAINTENANCE_LOCK_DURATION <= 0 then MAINTENANCE_LOCK_DURATION = 600 end
if ODN_SCAN_RANGE <= 0 then ODN_SCAN_RANGE = 160 end
if MAINTENANCE_SCAN_TIME <= 0 then MAINTENANCE_SCAN_TIME = 15 end
if MAINTENANCE_AIM_TOLERANCE <= 0 then MAINTENANCE_AIM_TOLERANCE = 8 end
if SONIC_RESET_REQUIRED_TIME <= 0 then SONIC_RESET_REQUIRED_TIME = 10 end
if REENERGIZE_REQUIRED_TIME <= 0 then REENERGIZE_REQUIRED_TIME = 10 end

local function defaultBuildTimerName(prefix, locKey)
    local key = locKey or "global"
    if key == "" or key == nil then
        key = "global"
    end
    key = string.lower(key)
    key = string.gsub(key, "[^%w_]", "_")
    return string.format("%s_%s", prefix or "EPS_Timer", key)
end

local deps = {
    getPanelInfo = nil,
    sendTricorderReport = nil,
    buildPanelPowerReport = nil,
    buildMaintenanceReport = nil,
    buildTimerName = Util.BuildTimerName,
}

local buildPanelPowerReport
local buildMaintenanceReport

local normalizeLocKey = Util.NormalizeLocKey or function(locKey)
    if not locKey or locKey == "" then return "global" end
    return string.lower(locKey)
end

local function buildTimerName(prefix, locKey)
    local builder = deps.buildTimerName
    if builder then
        return builder(prefix, locKey)
    end
    if Util.BuildTimerName then
        return Util.BuildTimerName(prefix, locKey)
    end
    return defaultBuildTimerName(prefix, locKey)
end

local function snapshotDemand(normalized)
    local saved = {}
    if not EPS.IterSubsystems then return saved end
    for _, sub in EPS.IterSubsystems() do
        if sub and sub.id then
            local demand = EPS.GetDemand and EPS.GetDemand(normalized, sub.id) or 0
            if demand == nil then demand = 0 end
            saved[sub.id] = demand
        end
    end
    return saved
end

local function snapshotAllocations(normalized)
    local saved = {}
    if not EPS.IterSubsystems then return saved end
    for _, sub in EPS.IterSubsystems() do
        if sub and sub.id then
            local alloc = EPS.GetAllocation and EPS.GetAllocation(normalized, sub.id) or 0
            if alloc == nil then alloc = 0 end
            saved[sub.id] = alloc
        end
    end
    return saved
end

local function applyAllocations(normalized, values)
    if not EPS.IterSubsystems or not EPS.SetAllocation then return false end
    local changed = false
    for _, sub in EPS.IterSubsystems() do
        local id = sub and sub.id
        if id then
            local target = 0
            if values and values[id] ~= nil then
                target = values[id]
            end
            local current = EPS.GetAllocation and EPS.GetAllocation(normalized, id) or 0
            if current ~= target then
                EPS.SetAllocation(normalized, id, target)
                changed = true
            end
        end
    end
    if changed and EPS._RunChangeHookIfNeeded then
        EPS._RunChangeHookIfNeeded(normalized)
    end
    return changed
end

local function applyDemands(normalized, values)
    if not EPS.IterSubsystems or not EPS.SetDemand then return false end
    local changed = false
    for _, sub in EPS.IterSubsystems() do
        local id = sub and sub.id
        if id then
            local target = 0
            if values and values[id] ~= nil then
                target = values[id]
            end
            local current = EPS.GetDemand and EPS.GetDemand(normalized, id) or 0
            if current ~= target then
                EPS.SetDemand(normalized, id, target)
                changed = true
            elseif values == nil then
                -- force a zero entry so demand stays clamped during maintenance
                EPS.SetDemand(normalized, id, target)
            end
        end
    end
    return changed
end

local function buildMaintenanceReportLines(info, normalized, savedDemand, telemetry)
    local lines, traced = buildMaintenanceReport(info, normalized, savedDemand, telemetry)
    if lines then
        return lines, traced
    end
    local summary = "Summary: EPS diagnostics available; maintenance clamp engaged."
    local fallback = buildPanelPowerReport(info, normalized, summary, "[Tricorder] EPS Diagnostic Scan")
    if fallback and #fallback > 0 then
        return fallback, traced
    end
    return {
        "[Tricorder] EPS Diagnostic Scan",
        "",
        "Summary: EPS diagnostics available; maintenance clamp engaged.",
    }, traced
end

local function buildReenergizeReportLines(info, normalized)
    local summary = "Summary: EPS conduit nominal; manual controls restored."
    local lines = buildPanelPowerReport(info, normalized, summary, "[Tricorder] EPS Power Reinitialization")
    if lines and #lines > 0 then
        return lines
    end
    return {
        "[Tricorder] EPS Power Reinitialization",
        "",
        summary,
    }
end

local function resetOverrideState(record)
    record.overrideActive = false
    record.overrideBy = nil
    record.overrideSince = 0
    record.overrideClearedAt = 0
    record.overridePowerActive = false
    record.overridePowered = false
    record.overrideWarnedUntil = 0
    record.overrideResetProgress = 0
    record.overrideResetStart = nil
    record.overrideResetLast = 0
    record.overrideResetHUD = 0
    record.overrideResetBy = nil
    record.overrideResetExpires = 0
end

local function resetReenergizeState(record)
    record.reenergizeDuration = REENERGIZE_REQUIRED_TIME
    record.reenergizeProgress = 0
    record.lastReenergizeHit = 0
end

local function pruneExpired(bucket, target, state)
    if not state then return nil end
    if state.expires and state.expires > 0 and state.expires < CurTime() then
        bucket[target] = nil
        return nil
    end
    if state.panel and not IsValid(state.panel) then
        bucket[target] = nil
        return nil
    end
    return state
end

function Maintenance.GetState(locKey, panel)
    EPS._maintenanceLocks = EPS._maintenanceLocks or {}
    local key = normalizeLocKey(locKey)
    local bucket = EPS._maintenanceLocks[key]
    if not bucket then return nil end

    if panel ~= nil then
        local target = IsValid(panel) and panel or "_global"
        return pruneExpired(bucket, target, bucket[target])
    end

    local globalState = pruneExpired(bucket, "_global", bucket["_global"])
    if globalState then
        return globalState
    end

    for target, state in pairs(bucket) do
        if target ~= "_global" then
            local kept = pruneExpired(bucket, target, state)
            if kept then
                return kept
            end
        end
    end

    if next(bucket) == nil then
        EPS._maintenanceLocks[key] = nil
    end

    return nil
end

function Maintenance.SetState(locKey, state, panel)
    EPS._maintenanceLocks = EPS._maintenanceLocks or {}
    local key = normalizeLocKey(locKey)
    EPS._maintenanceLocks[key] = EPS._maintenanceLocks[key] or setmetatable({}, { __mode = "k" })
    local bucket = EPS._maintenanceLocks[key]

    local target = IsValid(panel) and panel or "_global"
    if state then
        bucket[target] = state
    else
        bucket[target] = nil
        if next(bucket) == nil then
            EPS._maintenanceLocks[key] = nil
        end
    end
end

function Maintenance.IsOverrideActive(record)
    return record and record.active == true and record.overrideActive == true
end

function Maintenance.UpdateOverridePowerFlags(record, locKey)
    if not record or not record.active then return end
    local normalized = normalizeLocKey(locKey or record.locationKey)
    local hasPower = false
    if EPS.IterSubsystems then
        for _, sub in EPS.IterSubsystems() do
            local id = sub and sub.id
            if id then
                local alloc = EPS.GetAllocation and EPS.GetAllocation(normalized, id)
                if (alloc or 0) > 0 then
                    hasPower = true
                    break
                end
            end
        end
    end
    if not hasPower and EPS.GetTotalAllocation then
        hasPower = (EPS.GetTotalAllocation(normalized) or 0) > 0
    end
    record.overridePowerActive = hasPower
    if hasPower then
        record.overridePowered = true
    else
        record.overridePowerActive = false
    end
end

function Maintenance.IsLocationLocked(locKey, panel)
    local state = Maintenance.GetState(locKey, panel)
    return state ~= nil and state.active == true
end

EPS.IsLocationMaintenanceLocked = Maintenance.IsLocationLocked

function Maintenance.SetupInteractions(options)
    options = options or {}
    if options.getPanelInfo then
        deps.getPanelInfo = options.getPanelInfo
    end
    if options.sendTricorderReport then
        deps.sendTricorderReport = options.sendTricorderReport
    end
    if options.buildPanelPowerReport then
        deps.buildPanelPowerReport = options.buildPanelPowerReport
    end
    if options.buildMaintenanceReport then
        deps.buildMaintenanceReport = options.buildMaintenanceReport
    end
    if options.buildTimerName then
        deps.buildTimerName = options.buildTimerName
    end
end

function Maintenance.CancelMaintenanceAttempt(ply)
    cancelMaintenanceAttempt(ply)
end

function Maintenance.CancelOverrideAttempt(ply)
    cancelOverrideAttempt(ply)
end

function Maintenance.CancelAttempts(ply)
    cancelMaintenanceAttempt(ply)
    cancelOverrideAttempt(ply)
end

local function sendTricorderReport(ply, ent, report)
    if deps.sendTricorderReport then
        deps.sendTricorderReport(ply, ent, report)
    end
end

buildPanelPowerReport = function(info, normalized, summary, title)
    if deps.buildPanelPowerReport then
        return deps.buildPanelPowerReport(info, normalized, summary, title)
    end
    return nil
end

buildMaintenanceReport = function(info, normalized, savedDemand, telemetry)
    if deps.buildMaintenanceReport then
        return deps.buildMaintenanceReport(info, normalized, savedDemand, telemetry)
    end
    return nil
end

local function getPanelInfo(ent)
    if deps.getPanelInfo then
        return deps.getPanelInfo(ent)
    end
    return nil
end

local function cancelMaintenanceAttempt(ply, message)
    local attempts = EPS._maintenanceScanAttempts
    if not attempts then return end
    local attempt = attempts[ply]
    if not attempt then return end
    attempts[ply] = nil
    if attempt.timerId then
        timer.Remove(attempt.timerId)
    end
    if IsValid(ply) and message and message ~= "" then
        ply:PrintMessage(HUD_PRINTCENTER, message)
    end
end

local function cancelOverrideAttempt(ply, message)
    local attempts = EPS._maintenanceOverrideAttempts
    if not attempts then return end
    local attempt = attempts[ply]
    if not attempt then return end
    attempts[ply] = nil
    if attempt.timerId then
        timer.Remove(attempt.timerId)
    end
    if IsValid(ply) and message and message ~= "" then
        ply:PrintMessage(HUD_PRINTCENTER, message)
    end
end

local function startMaintenanceAttempt(ply, ent, info, normalized)
    EPS._maintenanceScanAttempts = EPS._maintenanceScanAttempts or setmetatable({}, { __mode = "k" })
    local attempts = EPS._maintenanceScanAttempts
    local attempt = {
        panel = ent,
        info = info,
        normalized = normalized,
        started = CurTime(),
        lastProgressMsg = 0,
    }
    attempts[ply] = attempt

    local timerId = string.format("EPS_MaintScan_%d", ply:EntIndex())
    attempt.timerId = timerId

    local function abort(msg)
        cancelMaintenanceAttempt(ply, msg or "EPS maintenance scan aborted.")
    end

    local function finalize()
        cancelMaintenanceAttempt(ply)
    local ok, data, report = enterMaintenance(ent, ply)
        if ok then
            if report then
                sendTricorderReport(ply, ent, report)
            end
            return
        end
        if type(data) == "string" and data ~= "" and IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] " .. data)
        end
        local fallback = buildPanelPowerReport(info, normalized, "Summary: EPS diagnostics available; maintenance clamp not engaged.", "[Tricorder] EPS Diagnostic Scan")
        sendTricorderReport(ply, ent, fallback)
    end

    timer.Create(timerId, MAINTENANCE_SCAN_INTERVAL, 0, function()
        if not IsValid(ply) or not ply:IsPlayer() then
            abort()
            return
        end
        if not ply:KeyDown(IN_ATTACK) then
            abort("EPS maintenance scan aborted.")
            return
        end
        local weapon = ply:GetActiveWeapon()
        if not IsValid(weapon) or weapon:GetClass() ~= "odn_scanner" then
            abort("EPS maintenance scan aborted.")
            return
        end

        local startPos = ply:GetShootPos()
        local dir = ply:GetAimVector()
        local trace = util.TraceLine({
            start = startPos,
            endpos = startPos + dir * ODN_SCAN_RANGE,
            filter = ply,
            mask = MASK_SHOT,
        })

        if not IsValid(trace.Entity) or trace.Entity ~= ent then
            abort("EPS maintenance alignment lost.")
            return
        end

        attempt.anchor = attempt.anchor or trace.HitPos
        if attempt.anchor and trace.HitPos and attempt.anchor:DistToSqr(trace.HitPos) > (MAINTENANCE_AIM_TOLERANCE * MAINTENANCE_AIM_TOLERANCE) then
            abort("EPS maintenance alignment lost.")
            return
        end

        local elapsed = CurTime() - attempt.started
        local progress = math.Clamp(elapsed / MAINTENANCE_SCAN_TIME, 0, 1)

        if CurTime() - (attempt.lastProgressMsg or 0) >= 0.35 then
            attempt.lastProgressMsg = CurTime()
            ply:PrintMessage(HUD_PRINTCENTER, string.format("Channeling plasma purge... %d%%", math.floor(progress * 100)))
        end

        if elapsed >= MAINTENANCE_SCAN_TIME then
            timer.Remove(timerId)
            finalize()
        end
    end)
end

local function startOverrideAttempt(ply, ent, info, normalized)
    EPS._maintenanceOverrideAttempts = EPS._maintenanceOverrideAttempts or setmetatable({}, { __mode = "k" })
    local attempts = EPS._maintenanceOverrideAttempts
    local attempt = {
        panel = ent,
        info = info,
        normalized = normalized,
        started = CurTime(),
        lastProgressMsg = 0,
    }
    attempts[ply] = attempt

    local timerId = string.format("EPS_OverrideScan_%d", ply:EntIndex())
    attempt.timerId = timerId

    local function abort(msg)
        cancelOverrideAttempt(ply, msg or "EPS override aborted.")
    end

    timer.Create(timerId, MAINTENANCE_SCAN_INTERVAL, 0, function()
        if not IsValid(ply) or not ply:IsPlayer() then
            abort()
            return
        end
        if not ply:KeyDown(IN_ATTACK2) then
            abort("EPS override aborted.")
            return
        end
        local weapon = ply:GetActiveWeapon()
        if not IsValid(weapon) or weapon:GetClass() ~= "odn_scanner" then
            abort("EPS override aborted.")
            return
        end

        local startPos = ply:GetShootPos()
        local dir = ply:GetAimVector()
        local trace = util.TraceLine({
            start = startPos,
            endpos = startPos + dir * ODN_SCAN_RANGE,
            filter = ply,
            mask = MASK_SHOT,
        })

        if not IsValid(trace.Entity) or trace.Entity ~= ent then
            abort("EPS override alignment lost.")
            return
        end

        attempt.anchor = attempt.anchor or trace.HitPos
        if attempt.anchor and trace.HitPos and attempt.anchor:DistToSqr(trace.HitPos) > (MAINTENANCE_AIM_TOLERANCE * MAINTENANCE_AIM_TOLERANCE) then
            abort("EPS override alignment lost.")
            return
        end

        local state = Maintenance.GetState(normalized, ent)
        if not Maintenance.IsOverrideActive(state) and (not state or not state.active) then
            abort("EPS conduit is not in maintenance mode.")
            return
        end
        if state and state.active and state.overrideActive then
            abort("EPS safety interlocks already bypassed.")
            return
        end

        local elapsed = CurTime() - attempt.started
        local progress = math.Clamp(elapsed / MAINTENANCE_OVERRIDE_HOLD_TIME, 0, 1)

        if CurTime() - (attempt.lastProgressMsg or 0) >= 0.35 then
            attempt.lastProgressMsg = CurTime()
            ply:PrintMessage(HUD_PRINTCENTER, string.format("Bypassing EPS safeties... %d%%", math.floor(progress * 100)))
        end

        if elapsed >= MAINTENANCE_OVERRIDE_HOLD_TIME then
            cancelOverrideAttempt(ply)
            if IsValid(ply) then
                ply:PrintMessage(HUD_PRINTCENTER, "Bypassing EPS safeties... 100%")
            end
            local active = Maintenance.GetState(normalized, ent)
            if not active or not active.active then
                if IsValid(ply) and ply.ChatPrint then
                    ply:ChatPrint("[EPS] Conduit maintenance not detected; override cancelled.")
                end
                return
            end
            if active.overrideActive then
                if IsValid(ply) and ply.ChatPrint then
                    ply:ChatPrint("[EPS] Safety interlocks already bypassed.")
                end
                return
            end

            active.overrideActive = true
            active.overrideBy = IsValid(ply) and ply or nil
            active.overrideSince = CurTime()
            active.overrideClearedAt = 0
            active.overrideResetProgress = 0
            active.overrideResetStart = nil
            active.overrideResetLast = 0
            active.overrideResetHUD = 0
            active.overrideResetBy = nil
            active.overrideResetExpires = 0
            Maintenance.UpdateOverridePowerFlags(active, normalized)
            Maintenance.SetState(normalized, active, ent)

            if IsValid(ply) and ply.ChatPrint then
                ply:ChatPrint("[EPS] Safety interlocks bypassed; manual controls restored.")
            end
            if IsValid(ply) and EPS and EPS.BroadcastState then
                EPS.BroadcastState(ply, false)
            end
            if IsValid(ply) then
                ply:PrintMessage(HUD_PRINTCENTER, "EPS safety interlocks bypassed.")
                timer.Simple(2, function()
                    if IsValid(ply) then
                        ply:PrintMessage(HUD_PRINTCENTER, "")
                    end
                end)
            end
        end
    end)
end

function Maintenance.HandleSonicDriverOverride(ply, ent)
    local info = getPanelInfo(ent)
    if not info then return false end

    local locKey = info.locationKey or info.locationKeyLower or "global"
    local normalized = normalizeLocKey(locKey)
    local record = Maintenance.GetState(normalized, ent)
    if not record or not record.active then return false end
    if not record.overrideActive then return false end

    Maintenance.UpdateOverridePowerFlags(record, normalized)
    Maintenance.SetState(normalized, record, ent)

    if record.overridePowerActive then
        record.overrideResetProgress = 0
        record.overrideResetStart = nil
        record.overrideResetLast = 0
        record.overrideResetBy = nil
        record.overrideResetHUD = 0
        record.overrideResetExpires = 0
        record.overrideWarnedUntil = record.overrideWarnedUntil or 0
        if CurTime() >= record.overrideWarnedUntil then
            record.overrideWarnedUntil = CurTime() + 2.0
            if IsValid(ply) and ply.ChatPrint then
                ply:ChatPrint("[EPS] Reduce allocations to zero before restoring safety interlocks.")
            end
        end
        Maintenance.SetState(normalized, record, ent)
        return true
    end

    local now = CurTime()
    local previousOperator = record.overrideResetBy
    if previousOperator ~= ply then
        record.overrideResetStart = nil
    end
    record.overrideResetBy = IsValid(ply) and ply or nil
    if not record.overrideResetStart then
        record.overrideResetStart = now
    end
    record.overrideResetLast = now
    record.overrideResetExpires = now + SONIC_RESET_DECAY
    record.overrideResetProgress = math.Clamp(now - (record.overrideResetStart or now), 0, SONIC_RESET_REQUIRED_TIME)

    if IsValid(ply) then
        record.overrideResetHUD = record.overrideResetHUD or 0
        if now >= record.overrideResetHUD then
            record.overrideResetHUD = now + 0.25
            local percent = math.Clamp(math.floor((record.overrideResetProgress / SONIC_RESET_REQUIRED_TIME) * 100), 0, 100)
            ply:PrintMessage(HUD_PRINTCENTER, string.format("Restoring safety interlocks... %d%%", percent))
        end
    end

    local panelRef = ent
    local timerId = buildTimerName("EPS_SonicReset", normalized)
    timer.Create(timerId, SONIC_RESET_DECAY, 1, function()
        local active = Maintenance.GetState(normalized, panelRef)
        if not active or not active.active then return end
        if (active.overrideResetExpires or 0) > CurTime() then return end
        active.overrideResetProgress = 0
        active.overrideResetStart = nil
        active.overrideResetLast = 0
        active.overrideResetHUD = 0
        local target = active.overrideResetBy
        active.overrideResetBy = nil
        active.overrideResetExpires = 0
        if IsValid(target) then
            target:PrintMessage(HUD_PRINTCENTER, "")
        end
        Maintenance.SetState(normalized, active, panelRef)
    end)

    if record.overrideResetProgress < SONIC_RESET_REQUIRED_TIME then
        Maintenance.SetState(normalized, record, ent)
        return true
    end

    record.overrideActive = false
    record.overrideBy = nil
    record.overrideSince = 0
    record.overrideClearedAt = CurTime()
    record.overridePowerActive = false
    record.overridePowered = false
    record.overrideWarnedUntil = 0
    record.overrideResetProgress = 0
    record.overrideResetStart = nil
    record.overrideResetLast = 0
    record.overrideResetHUD = 0
    record.overrideResetBy = nil
    record.overrideResetExpires = 0
    Maintenance.SetState(normalized, record, ent)

    if IsValid(ply) and ply.ChatPrint then
        ply:ChatPrint("[EPS] EPS safety interlocks restored.")
    end
    if IsValid(ply) then
        ply:PrintMessage(HUD_PRINTCENTER, "EPS safety interlocks restored.")
        timer.Simple(2, function()
            if IsValid(ply) then
                ply:PrintMessage(HUD_PRINTCENTER, "")
            end
        end)
    end
    if IsValid(ply) and EPS and EPS.BroadcastState then
        EPS.BroadcastState(ply, false)
    end
    return true
end

function Maintenance.TryStartMaintenanceFromScan(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    local startPos = ply:GetShootPos()
    local dir = ply:GetAimVector()
    local trace = util.TraceLine({
        start = startPos,
        endpos = startPos + dir * ODN_SCAN_RANGE,
        filter = ply,
        mask = MASK_SHOT,
    })

    local ent = trace.Entity
    if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end

    local info = getPanelInfo(ent)
    if not info then return end

    local locKey = info.locationKey or info.locationKeyLower or "global"
    local normalized = normalizeLocKey(locKey)
    local lockRecord = Maintenance.GetState(normalized, ent)

    if lockRecord and lockRecord.active then
        local savedDemand = lockRecord.savedDemand or {}
        local reportLines

        if lockRecord.telemetry then
            reportLines = buildMaintenanceReport(info, normalized, savedDemand, lockRecord.telemetry)
        else
            local cachedLines
            if EPS.GetPanelTelemetry then
                cachedLines = EPS.GetPanelTelemetry(ent)
            end
            if istable(cachedLines) and #cachedLines > 0 then
                reportLines = cachedLines
            end
        end

        if not reportLines then
            reportLines = buildMaintenanceReport(info, normalized, savedDemand)
        end

        if not reportLines then
            reportLines = buildPanelPowerReport(info, normalized, nil, nil)
        end

        if reportLines then
            sendTricorderReport(ply, ent, reportLines)
        end
        return
    end

    local attempts = EPS._maintenanceScanAttempts
    if attempts then
        local existing = attempts[ply]
        if existing and (not IsValid(existing.panel) or existing.panel ~= ent) then
            cancelMaintenanceAttempt(ply)
        end
        if existing and existing.panel == ent then
            return
        end
    end

    startMaintenanceAttempt(ply, ent, info, normalized)
end

function Maintenance.TryStartOverrideFromScan(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    local startPos = ply:GetShootPos()
    local dir = ply:GetAimVector()
    local trace = util.TraceLine({
        start = startPos,
        endpos = startPos + dir * ODN_SCAN_RANGE,
        filter = ply,
        mask = MASK_SHOT,
    })

    local ent = trace.Entity
    if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end

    local info = getPanelInfo(ent)
    if not info then return end

    local locKey = info.locationKey or info.locationKeyLower or "global"
    local normalized = normalizeLocKey(locKey)
    local record = Maintenance.GetState(normalized, ent)
    if not record or not record.active then
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] Conduit must be secured for maintenance before bypassing safeties.")
        end
        return
    end

    if record.overrideActive then
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] Safety interlocks already bypassed.")
        end
        return
    end

    local attempts = EPS._maintenanceOverrideAttempts
    if attempts then
        local existing = attempts[ply]
        if existing and (not IsValid(existing.panel) or existing.panel ~= ent) then
            cancelOverrideAttempt(ply)
            attempts = EPS._maintenanceOverrideAttempts
        end
        if attempts and attempts[ply] and attempts[ply].panel == ent then
            return
        end
    end

    startOverrideAttempt(ply, ent, info, normalized)
end

function Maintenance.ProcessReenergizeContact(ply, ent, info, normalized)
    local record = Maintenance.GetState(normalized, ent)
    if not record or not record.active then
        return false, buildPanelPowerReport(info, normalized, "Summary: EPS manifold already reading within nominal tolerances.", "[Tricorder] EPS Power Diagnostics"), "inactive"
    end

    if record.overrideActive then
        Maintenance.UpdateOverridePowerFlags(record, normalized)
        Maintenance.SetState(normalized, record, ent)
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] Restore safety interlocks with the sonic driver before re-energizing.")
        end
        return false, buildPanelPowerReport(info, normalized, "Summary: Safety override engaged; re-enable interlocks with sonic driver prior to re-energizing.", "[Tricorder] EPS Power Diagnostics"), "override"
    end

    record.reenergizeDuration = record.reenergizeDuration or REENERGIZE_REQUIRED_TIME
    record.reenergizeProgress = math.max(record.reenergizeProgress or 0, 0)
    record.lastReenergizeHit = CurTime()
    record.reenergizeProgress = math.min(record.reenergizeProgress + REENERGIZE_STEP, record.reenergizeDuration)
    Maintenance.SetState(normalized, record, ent)

    local percent = math.floor((record.reenergizeProgress / record.reenergizeDuration) * 100)
    if IsValid(ply) then
        ply:PrintMessage(HUD_PRINTCENTER, string.format("Re-energizing EPS manifold... %d%%", percent))
    end

    local panelRef = ent
    local timerId = buildTimerName("EPS_ReenergizeDecay", normalized)
    timer.Create(timerId, REENERGIZE_DECAY, 1, function()
        local active = Maintenance.GetState(normalized, panelRef)
        if not active or not active.active then return end
        if CurTime() - (active.lastReenergizeHit or 0) >= REENERGIZE_DECAY then
            active.reenergizeProgress = 0
            Maintenance.SetState(normalized, active, panelRef)
        end
    end)

    if record.reenergizeProgress >= record.reenergizeDuration then
        local ok, exitRecord, report = exitMaintenance(ent, ply)
        return ok, report, exitRecord
    end

    return false, nil, "progress"
end

enterMaintenance = function(panel, ply)
    if not IsValid(panel) or panel:GetClass() ~= "ent_eps_panel" then
        return false, "EPS maintenance can only be engaged on a valid EPS panel."
    end

    local info = getPanelInfo(panel)
    if not info then
        return false, "Unable to resolve EPS panel configuration."
    end

    local locKey = info.locationKey or info.locationKeyLower or "global"
    local normalized = normalizeLocKey(locKey)

    local existing = Maintenance.GetState(normalized, panel)
    if existing and existing.active then
        local saved = existing.savedDemand or {}
        local lines = buildMaintenanceReportLines(info, normalized, saved, existing.telemetry)
        return true, existing, lines
    end

    local savedDemand = snapshotDemand(normalized)
    local savedAllocations = snapshotAllocations(normalized)
    local lines, telemetry = buildMaintenanceReportLines(info, normalized, savedDemand)

    applyDemands(normalized, nil)
    applyAllocations(normalized, nil)

    local record = existing or {}
    record.active = true
    record.panel = panel
    record.panelId = panel:EntIndex()
    record.locationKey = normalized
    record.rawLocationKey = locKey
    record.savedDemand = savedDemand
    record.savedAllocations = savedAllocations
    record.telemetry = telemetry or record.telemetry
    record.enteredAt = CurTime()
    record.operator = IsValid(ply) and ply or record.operator
    record.operatorName = IsValid(ply) and ply:Nick() or record.operatorName
    record.expires = CurTime() + MAINTENANCE_LOCK_DURATION
    record.allocationsLocked = true
    record.allocationsLockedAt = CurTime()

    resetOverrideState(record)
    resetReenergizeState(record)

    Maintenance.UpdateOverridePowerFlags(record, normalized)

    timer.Remove(buildTimerName("EPS_SonicReset", normalized))
    timer.Remove(buildTimerName("EPS_ReenergizeDecay", normalized))

    Maintenance.SetState(normalized, record, panel)
    Maintenance.SetState(normalized, record)

    if IsValid(panel) then
        panel:SetNWBool("eps_maintenance_lock", true)
    end

    if EPS._SyncPanels then
        EPS._SyncPanels(normalized)
    end

    if IsValid(ply) and EPS.BroadcastState then
        EPS.BroadcastState(ply, false)
    end

    return true, record, lines
end

exitMaintenance = function(panel, ply)
    if not IsValid(panel) or panel:GetClass() ~= "ent_eps_panel" then
        return false, "EPS maintenance can only be disengaged from a valid EPS panel."
    end

    local info = getPanelInfo(panel)
    if not info then
        return false, "Unable to resolve EPS panel configuration."
    end

    local locKey = info.locationKey or info.locationKeyLower or "global"
    local normalized = normalizeLocKey(locKey)
    local record = Maintenance.GetState(normalized, panel)
    if not record or not record.active then
        return false, "EPS maintenance lock is not active."
    end

    if record.overrideActive then
        return false, "Safety interlocks remain bypassed."
    end

    timer.Remove(buildTimerName("EPS_SonicReset", normalized))
    timer.Remove(buildTimerName("EPS_ReenergizeDecay", normalized))

    record.active = false
    record.completedAt = CurTime()
    record.expires = CurTime() + 5
    record.allocationsLocked = false
    record.allocationsLockedAt = nil
    resetOverrideState(record)
    resetReenergizeState(record)

    if record.savedDemand then
        applyDemands(normalized, record.savedDemand)
    end

    Maintenance.SetState(normalized, nil, panel)
    Maintenance.SetState(normalized, nil)

    if IsValid(panel) then
        panel:SetNWBool("eps_maintenance_lock", false)
    end

    if EPS._SyncPanels then
        EPS._SyncPanels(normalized)
    end

    if IsValid(ply) and EPS.BroadcastState then
        EPS.BroadcastState(ply, false)
    end

    local report = buildReenergizeReportLines(info, normalized)
    return true, record, report
end

EPS.EnterMaintenance = enterMaintenance
EPS.ExitMaintenance = exitMaintenance

Maintenance.EnterMaintenance = enterMaintenance
Maintenance.ExitMaintenance = exitMaintenance

if not EPS.GetMaintenanceState then
    EPS.GetMaintenanceState = function(locKey, panel)
        return Maintenance.GetState(locKey, panel)
    end
end

return Maintenance
